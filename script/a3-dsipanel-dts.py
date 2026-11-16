#!/usr/bin/env python3
"""Move the panel under dsi0 and switch it to the real DSI panel driver.

A MIPI-DSI peripheral has to be a *child of the DSI host node* (like an i2c
device), otherwise of_mipi_dsi_device_add() never creates it and the host's
attach callback - which is where mtk_dsi calls component_add() - never runs.

So the previous root-level "panel-dpi" node is removed and replaced by
    dsi0 { panel@0 { compatible = "oppo,a3-nt36672"; reg = <0>; port {...} } }
with the two endpoints pointing at each other.

Usage: a3-dsipanel-dts.py [SRC_DTB] [OUT_DTB]
"""
import io
import re
import subprocess
import sys

IMG = "/opt/oppoa3/images/"
src = sys.argv[1] if len(sys.argv) > 1 else IMG + "a3-v186-dphy2.dtb"
out = sys.argv[2] if len(sys.argv) > 2 else IMG + "a3-v186-dsipanel.dtb"
dts = "/tmp/a3-dsipanel.dts"

TAB = "\t"

subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", dts, src], check=True)
s = io.open(dts, encoding="utf-8").read()


def next_phandle(text):
    used = [int(x, 16) for x in re.findall(r"phandle = <(0x[0-9a-f]+)>;", text)]
    return (max(used) + 1) if used else 1


# ---- 1. drop the old root-level panel@0 ---------------------------------
old_panel = re.search(r"\n\tpanel@0 \{.*?\n\t\};\n", s, re.S)
if old_panel:
    s = s[:old_panel.start()] + "\n" + s[old_panel.end():]
    print("removed old root-level panel-dpi node")

# ---- 2. reserve phandles ------------------------------------------------
base = next_phandle(s)
ph_panel_in = "0x%x" % base
ph_dsi_out = "0x%x" % (base + 1)

# ---- 3. dsi0: rebuild its port with a fixed phandle --------------------
m = re.search(r"(\tdsi0@14014000 \{)(.*?)(\n\t\};)", s, re.S)
if not m:
    sys.exit("dsi0 node not found")
body = m.group(2)
# strip any existing port block
body = re.sub(r"\n\n\t\tport \{.*?\n\t\t\};", "", body, flags=re.S)

ph = re.search(r"phandle = <(0x[0-9a-f]+)>;", body)
dsi_ph = ph.group(1) if ph else "0x%x" % next_phandle(s)

panel_block = (
    "\n\n" + TAB * 2 + "port {"
    "\n" + TAB * 3 + "dsi_out: endpoint {"
    "\n" + TAB * 4 + "remote-endpoint = <%s>;" % ph_panel_in +
    "\n" + TAB * 4 + "phandle = <%s>;" % ph_dsi_out +
    "\n" + TAB * 3 + "};"
    "\n" + TAB * 2 + "};"

    # the DSI peripheral itself, a child of the host
    "\n\n" + TAB * 2 + "panel@0 {"
    "\n" + TAB * 3 + 'compatible = "oppo,a3-nt36672";'
    "\n" + TAB * 3 + "reg = <0x00>;"
    "\n" + TAB * 3 + 'status = "okay";'
    "\n\n" + TAB * 3 + "port {"
    "\n" + TAB * 4 + "panel_in: endpoint {"
    "\n" + TAB * 5 + "remote-endpoint = <%s>;" % ph_dsi_out +
    "\n" + TAB * 5 + "phandle = <%s>;" % ph_panel_in +
    "\n" + TAB * 4 + "};"
    "\n" + TAB * 3 + "};"
    "\n" + TAB * 2 + "};"
)
body = body.rstrip() + panel_block
s = s[:m.start(2)] + body + s[m.end(2):]

io.open(dts, "w", encoding="utf-8").write(s)
r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", out, dts],
                   capture_output=True, text=True)
errs = [l for l in r.stderr.splitlines() if l and "Warning" not in l]
if errs:
    print("\n".join(errs[:8]))
    sys.exit(1)
print("panel_in=%s dsi_out=%s dsi=%s" % (ph_panel_in, ph_dsi_out, dsi_ph))
print("wrote", out)
