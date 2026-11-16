#!/usr/bin/env python3
"""Fix the mmsys compatible in the A3 device tree.

The display stack in 6.12 expects the mmsys node to be owned *only* by
mtk-mmsys.c, which then spawns the "clk-mtXXXX-mm" and "mediatek-drm" child
devices.  A dual compatible (mt8183-mmsys + mt6765-mmsys) makes two drivers
race for the same node and neither the clocks nor DRM come up.

Usage: a3-mmsys-dts.py [SRC_DTB] [OUT_DTB]
"""
import io
import re
import subprocess
import sys

IMG = "/opt/oppoa3/images/"
src = sys.argv[1] if len(sys.argv) > 1 else IMG + "a3-v186-apmixed.dtb"
out = sys.argv[2] if len(sys.argv) > 2 else IMG + "a3-v186-mmsys.dtb"
dts = "/tmp/a3-mmsys.dts"

BS0 = "\\0"

subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, src], check=True)
s = io.open(dts, encoding="utf-8").read()

m = re.search(r"(\tmmsys_config@14000000 \{)(.*?)(\n\t\};)", s, re.S)
if not m:
    sys.exit("mmsys node not found")
body = m.group(2)

# collapse whatever compatible it has now into a single mt6765-mmsys.
# note: dtc prints multi-string properties as ONE quoted string containing \0
# escapes, so the escape must stay inside the quotes.
new_compat = '"mediatek,mt6765-mmsys' + BS0 + 'syscon"'
body2 = re.sub(r'compatible = "[^;]*";', 'compatible = %s;' % new_compat, body, count=1)
if body2 == body:
    sys.exit("compatible not replaced")
s = s[:m.start(2)] + body2 + s[m.end(2):]

io.open(dts, "w", encoding="utf-8").write(s)
r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", out, dts],
                   capture_output=True, text=True)
errs = [l for l in r.stderr.splitlines() if l and "Warning" not in l]
if errs:
    print("\n".join(errs[:8]))
    sys.exit(1)
print("wrote", out)
