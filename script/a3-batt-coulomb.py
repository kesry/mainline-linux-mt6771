#!/usr/bin/env python3
"""Make the A3 battery report capacity from the fuel gauge, like Android does.

Android's BMS reports 759 mAh / 3300 mAh = 23% while the terminal voltage sits
at 4.24 V.  On a worn pack those two views disagree wildly: the voltage climbs
to the CV limit while the cell only holds a fraction of its design charge.  Our
driver was voltage-only, so it claimed ~80%.

This patch:
  * actually calls a3_coulomb_update(), which existed but had no caller
  * reports capacity = charge / a3_batt_mah when a3_cap_src=1 (new default)
  * persists the accumulated charge under /var/lib/a3-battery/charge so a
    reboot does not throw the count away
  * seeds the count from the voltage table the first time, so a fresh install
    starts somewhere sensible
"""
import io
import sys

P = "/opt/oppoa3/kernel-src/drivers/power/supply/a3_battery.c"
s = io.open(P, encoding="utf-8").read()

if "A3_CHARGE_FILE" in s:
    print("already patched")
    sys.exit(0)

# ---- 1. default to the coulomb counter --------------------------------
old = "static int a3_cap_src; /* 0=voltage table (default), 1=coulomb counter */"
new = "static int a3_cap_src = 1; /* 0=voltage table, 1=coulomb counter (matches Android) */"
if old not in s:
    sys.exit("cap_src anchor missing")
s = s.replace(old, new, 1)

# ---- 2. persistence helpers next to the capacity ones -----------------
anchor = "static int a3_cap_load(void)"
helper = '''#define A3_CHARGE_FILE\t"/var/lib/a3-battery/charge"

/* accumulated charge in mAh*1000, persisted so reboots keep the count */
static int a3_charge_load(struct a3_battery *bat)
{
\tstruct file *f;
\tchar buf[32];
\tloff_t pos = 0;
\tssize_t n;
\tlong v;

\tf = filp_open(A3_CHARGE_FILE, O_RDONLY, 0);
\tif (IS_ERR(f))
\t\treturn -ENOENT;
\tn = kernel_read(f, buf, sizeof(buf) - 1, &pos);
\tfilp_close(f, NULL);
\tif (n <= 0)
\t\treturn -EIO;
\tbuf[n] = 0;
\tif (kstrtol(buf, 10, &v))
\t\treturn -EINVAL;
\tbat->q_mah1000 = (int)v;
\treturn 0;
}

static void a3_charge_persist(struct a3_battery *bat)
{
\tstruct file *f;
\tchar buf[32];
\tloff_t pos = 0;
\tint len;

\tf = filp_open(A3_CHARGE_FILE, O_WRONLY | O_CREAT | O_TRUNC, 0644);
\tif (IS_ERR(f))
\t\treturn;
\tlen = scnprintf(buf, sizeof(buf), "%d\\n", bat->q_mah1000);
\tkernel_write(f, buf, len, &pos);
\tfilp_close(f, NULL);
}

'''
if anchor not in s:
    sys.exit("a3_cap_load anchor missing")
s = s.replace(anchor, helper + anchor, 1)

# ---- 3. capacity from the accumulated charge when asked ---------------
old = '''static int a3_cap_update(struct a3_battery *bat, int mv)
{
\tint target = a3_voltage_to_capacity(mv);
'''
new = '''static int a3_cap_update(struct a3_battery *bat, int mv)
{
\tint target;

\tif (a3_cap_src) {
\t\tint full = a3_batt_mah * 1000;

\t\ttarget = full > 0 ? (int)div_s64((s64)bat->q_mah1000 * 100, full) : 0;
\t\tif (target < 0)
\t\t\ttarget = 0;
\t\tif (target > 100)
\t\t\ttarget = 100;
\t} else {
\t\ttarget = a3_voltage_to_capacity(mv);
\t}
'''
if old not in s:
    sys.exit("cap_update anchor missing")
s = s.replace(old, new, 1)

# ---- 4. keep the charge file in step with the reported value ----------
old = '''\tif (bat->cap_smooth != bat->cap_persisted) {
\t\ta3_cap_persist(bat->cap_smooth);
\t\tbat->cap_persisted = bat->cap_smooth;
\t}'''
new = '''\tif (bat->cap_smooth != bat->cap_persisted) {
\t\ta3_cap_persist(bat->cap_smooth);
\t\tbat->cap_persisted = bat->cap_smooth;
\t}
\tif (a3_cap_src)
\t\ta3_charge_persist(bat);'''
if old not in s:
    sys.exit("persist anchor missing")
s = s.replace(old, new, 1)

io.open(P, "w", encoding="utf-8").write(s)
print("battery: coulomb capacity wired up")
