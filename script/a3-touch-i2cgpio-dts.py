#!/usr/bin/env python3
"""Add a second bit-banged i2c bus on the touch pins (82/83).

The hardware controller cannot see any device on i2c0, while the same driver
talks happily to devices on i2c1/i2c3.  To separate "the controller's pin
configuration is wrong" from "the chip is dead", drive the very same two pads
with the kernel's i2c-gpio driver, which is well tested and does the
open-drain emulation the same way the existing charger bus does.

The existing i2c-gpio node shows the pattern to copy:
    sda-gpios = <&gpio 49 GPIO_ACTIVE_LOW>
    scl-gpios = <&gpio 48 GPIO_ACTIVE_LOW>
so this adds an identical node on pins 82 (SDA) and 83 (SCL).

Usage: a3-touch-i2cgpio-dts.py [SRC] [OUT]
"""
import io
import re
import subprocess
import sys

IMG = "/opt/oppoa3/images/"
src = sys.argv[1] if len(sys.argv) > 1 else IMG + "a3-v186-alli2c.dtb"
out = sys.argv[2] if len(sys.argv) > 2 else IMG + "a3-v186-tgpio.dtb"
dts = "/tmp/a3-tgpio.dts"

TAB = "\t"
subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, src], check=True)
s = io.open(dts, encoding="utf-8").read()

if "i2c-touch" in s:
    print("already present")
    sys.exit(0)

# find the gpio controller phandle used by the existing i2c-gpio node
m = re.search(r"\ti2c-gpio \{.*?\n\t\};", s, re.S)
if not m:
    sys.exit("existing i2c-gpio node not found")
blk = m.group(0)
ph = re.search(r"sda-gpios = <(0x[0-9a-f]+)", blk)
if not ph:
    sys.exit("cannot read sda-gpios phandle")
gpio_ph = ph.group(1)
flags = re.search(r"sda-gpios = <0x[0-9a-f]+ 0x[0-9a-f]+ (0x[0-9a-f]+)>", blk)
gpio_flags = flags.group(1) if flags else "0x02"
print("using gpio phandle %s flags %s" % (gpio_ph, gpio_flags))

node = (
    "\n\ti2c-touch {\n"
    + TAB * 2 + 'compatible = "i2c-gpio";\n'
    + TAB * 2 + "#address-cells = <0x01>;\n"
    + TAB * 2 + "#size-cells = <0x00>;\n"
    + TAB * 2 + "sda-gpios = <%s 0x52 %s>;\n" % (gpio_ph, gpio_flags)
    + TAB * 2 + "scl-gpios = <%s 0x53 %s>;\n" % (gpio_ph, gpio_flags)
    + TAB * 2 + "i2c-gpio,delay-us = <0x01>;\n"
    + TAB * 2 + 'status = "okay";\n'
    + TAB * 2 + "touch@62 {\n"
    + TAB * 3 + 'compatible = "nova-nt36672";\n'
    + TAB * 3 + "reg = <0x62>;\n"
    + TAB * 2 + "};\n"
    + "\t};\n"
)

# insert right after the existing i2c-gpio node
s = s[:m.end()] + node + s[m.end():]

io.open(dts, "w", encoding="utf-8").write(s)
r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", out, dts],
                   capture_output=True, text=True)
errs = [l for l in r.stderr.splitlines() if l and "Warning" not in l]
if errs:
    print("\n".join(errs[:8]))
    sys.exit(1)
print("wrote", out)
