#!/usr/bin/env python3
"""Give the MIPI DPHY a 26 MHz fixed clock instead of apmixedsys.

phy-mtk-mipi-tx requires a parent clock (upstream uses
CLK_APMIXED_MIPID0_26M from apmixedsys).  Binding our apmixed node to the
mainline apmixedsys driver turned out to break boot (logo + reboot loop), most
likely because it re-registers the global PLL set that topckgen already
resolved by name.

A fixed 26 MHz clock is exactly the rate that gate provides, so the DPHY can
lock its PLL from it and nothing else in the clock tree is disturbed.

Usage: a3-dphyclk-dts.py [SRC_DTB] [OUT_DTB]
"""
import io
import re
import subprocess
import sys

IMG = "/opt/oppoa3/images/"
src = sys.argv[1] if len(sys.argv) > 1 else IMG + "a3-test-panel.dtb"
out = sys.argv[2] if len(sys.argv) > 2 else IMG + "a3-v186-dphy.dtb"
dts = "/tmp/a3-dphy.dts"

BS0 = "\\0"
TAB = "\t"

subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, src], check=True)
s = io.open(dts, encoding="utf-8").read()

# ---- 1. reserve a phandle for the fixed clock ----------------------------
used = [int(x, 16) for x in re.findall(r"phandle = <(0x[0-9a-f]+)>;", s)]
clk_ph = "0x%x" % ((max(used) + 1) if used else 1)

# ---- 2. append the provider at root level -------------------------------
osc = """
\tosc26m: osc26m {
\t\tcompatible = "fixed-clock";
\t\t#clock-cells = <0x00>;
\t\tclock-frequency = <0x18cba80>;
\t\tclock-output-names = "osc26m";
\t\tphandle = <%(ph)s>;
\t};
""" % {"ph": clk_ph}

s = s.rstrip()
if not s.endswith("};"):
    sys.exit("unexpected dts tail")
s = s[:-2] + osc + "};\n"

# ---- 3. mipi_tx0 takes that clock ---------------------------------------
m = re.search(r"(\tmipi_tx0@11e50000 \{)(.*?)(\n\t\};)", s, re.S)
if not m:
    sys.exit("mipi_tx0 node not found")
body = m.group(2)
body = re.sub(r"\n\t\tclocks = [^;]*;", "", body)
body = body.rstrip() + "\n" + TAB * 2 + "clocks = <%s>;" % clk_ph
s = s[:m.start(2)] + body + s[m.end(2):]

io.open(dts, "w", encoding="utf-8").write(s)
r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", out, dts],
                   capture_output=True, text=True)
errs = [l for l in r.stderr.splitlines() if l and "Warning" not in l]
if errs:
    print("\n".join(errs[:8]))
    sys.exit(1)
print("osc26m phandle =", clk_ph)
print("wrote", out)
