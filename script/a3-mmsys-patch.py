#!/usr/bin/env python3
"""Wire MT6771/MT6765 into the mainline MediaTek display stack.

Architecture in 6.12 (this is the part that is easy to get wrong):

    mmsys node (compatible "mediatek,mtXXXX-mmsys")
        |
        +-- mtk-mmsys.c binds it and creates two *child platform devices*:
              "clk-mtXXXX-mm"   (clock driver, matched by NAME)
              "mediatek-drm"    (DRM master, matched by NAME)
        |
        +-- mtk_drm_probe() looks the parent's compatible up in
            mtk_drm_of_ids[] to obtain the DDP pipeline description.

So DRM never binds the mmsys node itself; giving mmsys a dual compatible is
wrong and just makes two drivers fight over one device.

This patch therefore:
  * adds mt6765_mmsys_driver_data to mtk-mmsys.c, reusing the MT8183 routing
    table and reset layout (MT6771 is the same 12 nm generation, same MMSYS
    register map -- see a3-display.md)
  * registers "mediatek,mt6765-mmsys" in both mtk-mmsys.c and mtk_drm_drv.c
"""
import io
import sys

SOC = "/opt/oppoa3/kernel-src/drivers/soc/mediatek/mtk-mmsys.c"
DRM = "/opt/oppoa3/kernel-src/drivers/gpu/drm/mediatek/mtk_drm_drv.c"

# ---------------------------------------------------------------- mtk-mmsys
s = io.open(SOC, encoding="utf-8").read()
if "mt6765_mmsys_driver_data" in s:
    print("mtk-mmsys: already patched")
else:
    anchor = "static const struct mtk_mmsys_driver_data mt8183_mmsys_driver_data = {"
    idx = s.index(anchor)
    end = s.index("\n};", idx) + 3
    entry = '''
/*
 * MT6771 (Helio P60) shares the MT8183 MMSYS layout: same block addresses and
 * the same DDP pipeline, only the clock driver name differs.
 */
static const struct mtk_mmsys_driver_data mt6765_mmsys_driver_data = {
\t.clk_driver = "clk-mt6765-mm",
\t.routes = mmsys_mt8183_routing_table,
\t.num_routes = ARRAY_SIZE(mmsys_mt8183_routing_table),
\t.sw0_rst_offset = MT8183_MMSYS_SW0_RST_B,
\t.num_resets = 32,
};
'''
    s = s[:end] + entry + s[end:]

    anchor2 = '\t{ .compatible = "mediatek,mt8183-mmsys", .data = &mt8183_mmsys_driver_data },'
    if anchor2 not in s:
        sys.exit("mtk-mmsys of_match anchor missing")
    s = s.replace(anchor2,
                  anchor2 + '\n\t{ .compatible = "mediatek,mt6765-mmsys", .data = &mt6765_mmsys_driver_data },', 1)
    io.open(SOC, "w", encoding="utf-8").write(s)
    print("mtk-mmsys: added mt6765 entry")

# ------------------------------------------------------------------ mtk-drm
d = io.open(DRM, encoding="utf-8").read()
if '"mediatek,mt6765-mmsys"' in d:
    print("mtk-drm: already patched")
else:
    anchor3 = '''\t{ .compatible = "mediatek,mt8183-mmsys",
\t  .data = &mt8183_mmsys_driver_data},'''
    if anchor3 not in d:
        # tolerate different whitespace
        import re
        m = re.search(r'\t\{ \.compatible = "mediatek,mt8183-mmsys",\s*\n\s*\.data = &mt8183_mmsys_driver_data\},', d)
        if not m:
            sys.exit("mtk-drm of_match anchor missing")
        anchor3 = m.group(0)
    add = anchor3 + '''
\t{ .compatible = "mediatek,mt6765-mmsys",
\t  .data = &mt8183_mmsys_driver_data},'''
    d = d.replace(anchor3, add, 1)
    io.open(DRM, "w", encoding="utf-8").write(d)
    print("mtk-drm: added mt6765 entry")
