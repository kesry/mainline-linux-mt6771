#!/usr/bin/env python3
"""Enable every MT6771 i2c controller so the touch bus can be found.

Only i2c@11017000 was switched to a mainline compatible so far (that is the bus
the charger sits on, and it is driven by i2c-gpio anyway).  The touch controller
from the vendor DTBO - himax_hx83112b @0x48 or nova_nt36672 @0x62 - lives on a
different controller, so bring them all up and let i2cdetect find it.

Every controller gets:
    compatible = "mediatek,mt8183-i2c"      (same I2C v2 IP as MT6771)
    clock-frequency = <400000>
    clocks point at the fixed 26 MHz clock

Usage: a3-alli2c-dts.py [SRC_DTB] [OUT_DTB]
"""
import io
import re
import subprocess
import sys

IMG = "/opt/oppoa3/images/"
src = sys.argv[1] if len(sys.argv) > 1 else IMG + "a3-v186-color.dtb"
out = sys.argv[2] if len(sys.argv) > 2 else IMG + "a3-v186-alli2c.dtb"
dts = "/tmp/a3-alli2c.dts"

BS0 = "\\0"
TAB = "\t"

subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, src], check=True)
s = io.open(dts, encoding="utf-8").read()

# reuse an existing fixed clock if the tree already has one
m = re.search(r"osc26m \{(.*?)\n\t\};", s, re.S)
if m and "phandle" in m.group(1):
    clk_ph = re.search(r"phandle = <(0x[0-9a-f]+)>;", m.group(1)).group(1)
    print("reusing osc26m phandle", clk_ph)
else:
    used = [int(x, 16) for x in re.findall(r"phandle = <(0x[0-9a-f]+)>;", s)]
    clk_ph = "0x%x" % ((max(used) + 1) if used else 1)
    osc = ("\n\tosc26m: osc26m {\n"
           + TAB * 2 + 'compatible = "fixed-clock";\n'
           + TAB * 2 + "#clock-cells = <0x00>;\n"
           + TAB * 2 + "clock-frequency = <0x18cba80>;\n"
           + TAB * 2 + 'clock-output-names = "osc26m";\n'
           + TAB * 2 + "phandle = <%s>;\n" % clk_ph
           + "\t};\n")
    s = s.rstrip()
    s = s[:-2] + osc + "};\n"
    print("added osc26m phandle", clk_ph)

count = 0
# collect first: replacing while iterating invalidates the later match offsets
matches = list(re.finditer(r"(\ti2c@1[0-9a-f]+ \{)(.*?)(\n\t\};)", s, re.S))
for m in reversed(matches):
    body = m.group(2)
    body = re.sub(r'compatible = "[^;]*";',
                  'compatible = "mediatek,mt8183-i2c";', body, count=1)
    body = re.sub(r"\n\t\tclocks = [^;]*;", "", body)
    body = re.sub(r"\n\t\tclock-names = [^;]*;", "", body)
    # A3: keep the bus in fast mode. Every vendor bus is marked hs_only, but the
    # HS timing path needs a high-speed clock source that mainline does not have
    # here (i2c_sel -> univpll3_d4, rate 0), so drop the flag and run 400 kHz.
    body = re.sub(r"\n\t\tmediatek,hs_only;", "", body)
    # clock-div was 5 for the vendor's ~156 MHz source; our source is 26 MHz
    # (osc26m), and mainline mt8183 uses 1, so 1 is the consistent value.
    body = re.sub(r"clock-div = <0x[0-9a-f]+>;", "clock-div = <0x01>;", body)
    if "clock-frequency" not in body:
        body = body.rstrip() + "\n" + TAB * 2 + "clock-frequency = <0x61a80>;"
    # mtk_i2c requires named "main" and "dma" clocks (arb is optional)
    body = body.rstrip() + "\n" + TAB * 2 + "clocks = <%s %s %s>;" % (
        clk_ph, clk_ph, clk_ph)
    body = body.rstrip() + "\n" + TAB * 2 + 'clock-names = "main", "dma", "arb";'
    s = s[:m.start(2)] + body + s[m.end(2):]
    count += 1

io.open(dts, "w", encoding="utf-8").write(s)
r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", out, dts],
                   capture_output=True, text=True)
errs = [l for l in r.stderr.splitlines() if l and "Warning" not in l]
if errs:
    print("\n".join(errs[:8]))
    sys.exit(1)
print("enabled %d i2c controllers" % count)
print("wrote", out)
