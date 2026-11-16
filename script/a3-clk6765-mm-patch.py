#!/usr/bin/env python3
"""Make clk-mt6765-mm match the mmsys *child device* by name.

Mainline mtk-mmsys.c registers the clock driver as a child platform device
called "clk-mt6765-mm" (no of_node).  The upstream mm clock drivers therefore
match with a platform_device_id table and use mtk_clk_pdev_probe(), which takes
its descriptor from the id table.

Our clk-mt6765-mm still matched the mmsys DT node by compatible, which made it
compete with mtk-mmsys for that node.  This patch converts it to the upstream
name-matching form so that:

    mmsys DT node -> mtk-mmsys -> child "clk-mt6765-mm" -> this driver

Compares with clk-mt8183-mm.c, which already looks like this.
"""
import io
import sys

P = "/opt/oppoa3/kernel-src/drivers/clk/mediatek/clk-mt6765-mm.c"
s = io.open(P, encoding="utf-8").read()

if "clk_mt6765_mm_id_table" in s:
    print("already patched")
    sys.exit(0)

old_of = '''static const struct of_device_id of_match_clk_mt6765_mm[] = {
\t{
\t\t.compatible = "mediatek,mt6765-mmsys",
\t\t.data = &mm_desc,
\t}, {
\t\t/* sentinel */
\t}
};
MODULE_DEVICE_TABLE(of, of_match_clk_mt6765_mm);

static struct platform_driver clk_mt6765_mm_drv = {
\t.probe = mtk_clk_simple_probe,
\t.remove = mtk_clk_simple_remove,
\t.driver = {
\t\t.name = "clk-mt6765-mm",
\t\t.of_match_table = of_match_clk_mt6765_mm,
\t},
};'''

new_of = '''/*
 * Not an of_match on purpose: mtk-mmsys creates this as a child platform
 * device named "clk-mt6765-mm" (the mmsys DT node belongs to mtk-mmsys), so
 * matching is by name and the descriptor comes from the id table.  This is
 * the same shape as clk-mt8183-mm.c.
 */
static const struct platform_device_id clk_mt6765_mm_id_table[] = {
\t{ .name = "clk-mt6765-mm", .driver_data = (kernel_ulong_t)&mm_desc },
\t{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(platform, clk_mt6765_mm_id_table);

static struct platform_driver clk_mt6765_mm_drv = {
\t.probe = mtk_clk_pdev_probe,
\t.remove = mtk_clk_pdev_remove,
\t.driver = {
\t\t.name = "clk-mt6765-mm",
\t},
\t.id_table = clk_mt6765_mm_id_table,
};'''

if old_of not in s:
    # tolerate whitespace differences by rebuilding from the known markers
    start = s.index("static const struct of_device_id of_match_clk_mt6765_mm[]")
    end = s.index("};", s.index("static struct platform_driver clk_mt6765_mm_drv")) + 2
    s = s[:start] + new_of + s[end:]
else:
    s = s.replace(old_of, new_of, 1)

io.open(P, "w", encoding="utf-8").write(s)
print("clk-mt6765-mm converted to name matching")
