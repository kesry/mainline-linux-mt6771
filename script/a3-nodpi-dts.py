#!/usr/bin/env python3
"""Stop mtk-drm from treating dpi0 as a required component.

mtk_drm_probe() adds a component match for *every* DT node whose compatible is
in mtk_ddp_comp_dt_ids[].  Our dpi0 node carries "mediatek,mt8183-dpi", so DRM
waits for it, but its probe fails with -ENOENT ("Failed to get engine clock")
because an MIPI-DSI panel does not use the parallel DPI output at all.

Giving dpi0 back its vendor compatible makes DRM ignore it, which is what we
want: the DSI path does not include DPI.

Usage: a3-nodpi-dts.py [SRC_DTB] [OUT_DTB]
"""
import io
import re
import subprocess
import sys

IMG = "/opt/oppoa3/images/"
src = sys.argv[1] if len(sys.argv) > 1 else IMG + "a3-v186-dphy.dtb"
out = sys.argv[2] if len(sys.argv) > 2 else IMG + "a3-v186-nodpi.dtb"
dts = "/tmp/a3-nodpi.dts"

subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, src], check=True)
s = io.open(dts, encoding="utf-8").read()

m = re.search(r"(\tdpi0@14015000 \{)(.*?)(\n\t\};)", s, re.S)
if not m:
    sys.exit("dpi0 node not found")
body = m.group(2)
if '"mediatek,mt8183-dpi"' not in body:
    print("dpi0 already non-matching")
else:
    body = body.replace('"mediatek,mt8183-dpi"', '"mediatek,dpi0"', 1)
    s = s[:m.start(2)] + body + s[m.end(2):]
    print("dpi0 -> mediatek,dpi0 (DRM will ignore it)")

io.open(dts, "w", encoding="utf-8").write(s)
r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", out, dts],
                   capture_output=True, text=True)
errs = [l for l in r.stderr.splitlines() if l and "Warning" not in l]
if errs:
    print("\n".join(errs[:8]))
    sys.exit(1)
print("wrote", out)
