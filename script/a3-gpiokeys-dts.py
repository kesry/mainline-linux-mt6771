#!/usr/bin/env python3
"""Add hardware volume keys to the device tree.

The vendor DTS routes the volume keys to plain GPIOs:

    keypad,volume-up   = <&pio 20 0x00>;
    keypad,volume-down = <&pio 94 0x00>;

so they can be handled by the standard gpio-keys driver instead of the MTK
keypad/KPD driver.  Our pinctrl gpiochip does not implement .to_irq(), so the
node asks for polled operation rather than edge interrupts.

The power key is *not* here: it arrives through the PMIC (MT6357 PWRKEY), and
that path needs the PMIC interrupt which the vendor device tree describes with
a four-cell specifier mainline cannot translate.

Usage: a3-gpiokeys-dts.py [SRC] [OUT]
"""
import io
import re
import subprocess
import sys

IMG = "/opt/oppoa3/images/"
src = sys.argv[1] if len(sys.argv) > 1 else IMG + "a3-v186-tgpio.dtb"
out = sys.argv[2] if len(sys.argv) > 2 else IMG + "a3-v186-keys.dtb"
dts = "/tmp/a3-keys.dts"

TAB = "\t"
KEY_VOLUMEUP = 115
KEY_VOLUMEDOWN = 114

subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, src], check=True)
s = io.open(dts, encoding="utf-8").read()

if "gpio-keys-volume" in s:
    print("already present")
    sys.exit(0)

# reuse the gpio controller phandle already used by the i2c-gpio bus
m = re.search(r"sda-gpios = <(0x[0-9a-f]+) 0x[0-9a-f]+ (0x[0-9a-f]+)>", s)
if not m:
    sys.exit("cannot find the gpio phandle")
ph, flags = m.group(1), m.group(2)
print("gpio phandle %s flags %s" % (ph, flags))

node = (
    "\n\tgpio-keys-volume {\n"
    + TAB * 2 + 'compatible = "gpio-keys-polled";\n'
    + TAB * 2 + 'label = "volume-keys";\n'
    + TAB * 2 + "poll-interval = <0x14>;\n"
    + TAB * 2 + "vol-up {\n"
    + TAB * 3 + 'label = "Volume Up";\n'
    + TAB * 3 + "gpios = <%s 0x14 %s>;\n" % (ph, flags)
    + TAB * 3 + "linux,code = <0x%x>;\n" % KEY_VOLUMEUP
        + TAB * 2 + "};\n"
    + TAB * 2 + "vol-down {\n"
    + TAB * 3 + 'label = "Volume Down";\n'
    + TAB * 3 + "gpios = <%s 0x5e %s>;\n" % (ph, flags)
    + TAB * 3 + "linux,code = <0x%x>;\n" % KEY_VOLUMEDOWN
        + TAB * 2 + "};\n"
    + "\t};\n"
)

# append at the end of the root node
idx = s.rstrip().rfind("\n};")
s = s[:idx] + node + s[idx:]

io.open(dts, "w", encoding="utf-8").write(s)
r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", out, dts],
                   capture_output=True, text=True)
errs = [l for l in r.stderr.splitlines() if l and "Warning" not in l]
if errs:
    print("\n".join(errs[:8]))
    sys.exit(1)
print("wrote", out)
