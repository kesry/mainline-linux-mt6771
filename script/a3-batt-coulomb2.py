#!/usr/bin/env python3
"""Second half of the battery work: wire the calls and seed the counter."""
import io
import sys

P = "/opt/oppoa3/kernel-src/drivers/power/supply/a3_battery.c"
s = io.open(P, encoding="utf-8").read()

if "a3_seed_charge" in s:
    print("already patched")
    sys.exit(0)

# ---- 1. includes needed by the persistence helpers --------------------
old = "#include <linux/power_supply.h>"
if old in s:
    s = s.replace(old, old + "\n#include <linux/fs.h>\n#include <linux/string.h>", 1)
else:
    print("  note: power_supply.h include not found, relying on existing ones")

# ---- 2. drop the duplicate (shadowing) declaration -------------------
dup = "static int a3_cap_src;      /* 0 = voltage table, 1 = coulomb counter */\n"
if dup in s:
    s = s.replace(dup, "", 1)
    print("  removed duplicate a3_cap_src declaration")

# ---- 3. seeding helper + call it from probe --------------------------
anchor = "static int a3_st_debounce(struct a3_battery *bat, int raw)"
seed = '''/* first run: derive a starting charge from the voltage table */
static void a3_seed_charge(struct a3_battery *bat)
{
\tint raw, mv, cap;

\tif (!a3_cap_src)
\t\treturn;
\tif (!a3_charge_load(bat))
\t\treturn;			/* resumed from the persisted value */

\tif (!a3_v_read_raw(bat, &raw)) {
\t\tmv = a3_raw_to_mv(raw);
\t\tcap = a3_voltage_to_capacity(mv);
\t\tswitch (cap) {
\t\tdefault:
\t\t\tbat->q_mah1000 = (int)div_s64((s64)cap * a3_batt_mah * 1000, 100);
\t\t\tbreak;
\t\t}
\t} else {
\t\tbat->q_mah1000 = a3_batt_mah * 1000 / 2;
\t}
\ta3_charge_persist(bat);
\tpr_info("a3-battery: seeded charge %d mAh*1000 (%d%%)\\n",
\t\tbat->q_mah1000, bat->q_mah1000 / (a3_batt_mah * 10 ? a3_batt_mah * 10 : 1));
}

'''
if anchor not in s:
    sys.exit("debounce anchor missing")
s = s.replace(anchor, seed + anchor, 1)

# ---- 4. call the integrator whenever userspace reads a property ------
old = "static int a3_battery_get_property(struct power_supply *psy,"
idx = s.index(old)
brace = s.index("{", idx)
s = s[:brace + 1] + "\n\ta3_coulomb_update(bat);" + s[brace + 1:]

# ---- 5. seed during probe -------------------------------------------
old = "\tbat->st_last = -1;\n"
if old not in s:
    sys.exit("probe anchor missing")
s = s.replace(old, old + "\ta3_seed_charge(bat);\n", 1)

io.open(P, "w", encoding="utf-8").write(s)
print("battery: coulomb calls wired")
