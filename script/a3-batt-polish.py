#!/usr/bin/env python3
"""Battery polish:

  * expose CHARGE_COUNTER (uAh) and CHARGE_FULL so userspace sees the same
    numbers Android's BMS does (Android: 759000 uAh / capacity 23%)
  * apply /var/lib/a3-battery/seed at runtime, not only at first read, so the
    count can be aligned to Android without a reboot
"""
import io
import sys

P = "/opt/oppoa3/kernel-src/drivers/power/supply/a3_battery.c"
s = io.open(P, encoding="utf-8").read()

if "a3_apply_seed_runtime" in s:
    print("already patched")
    sys.exit(0)

# ---- 1. helper: re-apply the seed file whenever it appears -----------
anchor = "static int a3_cap_update(struct a3_battery *bat, int mv)"
helper = '''/* userspace can drop a value here to re-align the counter at any time */
static void a3_apply_seed_runtime(struct a3_battery *bat)
{
\tstruct file *sf;
\tchar buf[32];
\tloff_t pos = 0;
\tssize_t n;
\tlong v;

\tsf = filp_open(A3_SEED_FILE, O_RDONLY, 0);
\tif (IS_ERR(sf))
\t\treturn;
\tn = kernel_read(sf, buf, sizeof(buf) - 1, &pos);
\tfilp_close(sf, NULL);
\tif (n <= 0 || kstrtol(buf, 10, &v))
\t\treturn;

\tbat->q_mah1000 = (int)v;
\ta3_charge_persist(bat);
\tbat->cap_valid = 0;\t\t/* let the smoothing restart from the new value */
\tvfs_unlink(&nop_mnt_idmap, NULL, NULL, NULL);
\tpr_info("a3-battery: runtime seed applied (%d)\\n", bat->q_mah1000);
}

'''
if anchor not in s:
    sys.exit("cap_update anchor missing")
s = s.replace(anchor, helper + anchor, 1)

# ---- 2. call it from the throttled capacity update -------------------
old = "\tint target;\n\n\tif (a3_cap_src) {"
new = "\tint target;\n\n\tif (a3_cap_src)\n\t\ta3_apply_seed_runtime(bat);\n\n\tif (a3_cap_src) {"
if old not in s:
    sys.exit("target anchor missing")
s = s.replace(old, new, 1)

# ---- 3. expose CHARGE_COUNTER / CHARGE_FULL --------------------------
old = "\tcase POWER_SUPPLY_PROP_CAPACITY:"
new = ('''\tcase POWER_SUPPLY_PROP_CHARGE_COUNTER:
\t\tval->intval = bat->q_mah1000;\t/* uAh, same unit as Android */
\t\treturn 0;
\tcase POWER_SUPPLY_PROP_CHARGE_FULL:
\t\tval->intval = a3_batt_mah * 1000;
\t\treturn 0;
''' + old)
if old not in s:
    sys.exit("capacity case anchor missing")
s = s.replace(old, new, 1)

io.open(P, "w", encoding="utf-8").write(s)
print("battery polish applied")
