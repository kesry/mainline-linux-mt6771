#!/usr/bin/env python3
"""Port the vendor LCM init table into the mainline panel driver.

The stock driver drivers/misc/mediatek/lcm/oppo_dpt_jdi_nt36672_1080p_dsi_vdo
contains lcm_initialization_video_setting[], the exact DSI command sequence this
panel needs.  Our mainline driver has been sending nothing at all and relying on
whatever state LK left behind - which works for a static image but is not a real
panel bring-up, and it means the panel (and, being incell, its touch block) is
never initialised by Linux.

This script parses that table and rewrites the prepare/enable/disable paths of
drivers/gpu/drm/panel/panel-a3-nt36672.c to replay it.
"""
import io
import re
import sys

VENDOR = ("/opt/oppoa3/A3-8.1-kernel-source-master/drivers/misc/mediatek/lcm/"
          "oppo_dpt_jdi_nt36672_1080p_dsi_vdo/"
          "oppo_dpt_jdi_nt36672_1080p_dsi_vdo.c")
TARGET = "/opt/oppoa3/kernel-src/drivers/gpu/drm/panel/panel-a3-nt36672.c"

src = io.open(VENDOR, encoding="utf-8", errors="replace").read()
m = re.search(r"lcm_initialization_video_setting\[\]\s*=\s*\{(.*?)\n\};", src, re.S)
if not m:
    sys.exit("init table not found in vendor driver")
table = m.group(1)

entries = []          # (cmd, [params]) or ("delay", ms)
for raw in table.splitlines():
    line = raw.strip()
    if not line.startswith("{"):
        continue
    if "REGFLAG_END_OF_TABLE" in line:
        break
    if "REGFLAG_DELAY" in line:
        ms = int(re.search(r"REGFLAG_DELAY\s*,\s*(\d+)", line).group(1))
        entries.append(("delay", ms))
        continue
    mm = re.match(r"\{\s*0x([0-9A-Fa-f]+)\s*,\s*(\d+)\s*,\s*\{([^}]*)\}", line)
    if not mm:
        continue
    cmd = int(mm.group(1), 16)
    cnt = int(mm.group(2))
    params = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]+)", mm.group(3))]
    if len(params) != cnt:
        sys.exit("param count mismatch on: %s" % line)
    entries.append((cmd, params))

if not entries:
    sys.exit("no entries parsed")

lines = []
for e in entries:
    if e[0] == "delay":
        lines.append("\t{ .len = 0xff, .delay_ms = %d }," % e[1])
    else:
        cmd, params = e
        body = ", ".join("0x%02x" % x for x in params)
        lines.append("\t{ .cmd = 0x%02x, .len = %d, .data = { %s } },"
                     % (cmd, len(params), body))
seq = "\n".join(lines)
print("parsed %d entries (%d commands, %d delays)" % (
    len(entries), sum(1 for e in entries if e[0] != "delay"),
    sum(1 for e in entries if e[0] == "delay")))

driver = u'''// SPDX-License-Identifier: GPL-2.0
/*
 * JDI nt36672 1080x2280 DSI video-mode panel as used on the OPPO A3 (P7771).
 *
 * The panel is a TDDI part: display and touch share one die, so this driver is
 * also what has to power the touch block up.  The command sequence below is
 * ported verbatim from the vendor LCM driver
 *   drivers/misc/mediatek/lcm/oppo_dpt_jdi_nt36672_1080p_dsi_vdo
 * which is the only authoritative description of this panel's init.
 *
 * Timings, same source:
 *   VSA=2 VBP=10 VFP=25 VACT=2280 / HSA=2 HBP=30 HFP=40 HACT=1080
 *   4 lanes, BURST_VDO, RGB888, 1029 Mbps/lane
 * mtk_dsi derives the per-lane rate as pixelclock * bpp / lanes, so the pixel
 * clock is 171.5 MHz.
 */
#include <linux/backlight.h>
#include <linux/delay.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>

#include <drm/drm_mipi_dsi.h>
#include <drm/drm_modes.h>
#include <drm/drm_panel.h>
#include <video/mipi_display.h>
#include <video/videomode.h>

#define A3_PANEL_WIDTH   1080
#define A3_PANEL_HEIGHT  2280
#define A3_PANEL_CLOCK   171500000
#define A3_PANEL_LANES   4

struct a3_seq {
\tu8 cmd;
\tu8 len;
\tu8 data[4];
\tu16 delay_ms;\t\t/* delay after this command */
};


/*
 * Replayed in order from a3_panel_prepare().  A3_SEQ_DELAY entries only sleep,
 * which is how the vendor table expresses the mandatory waits around sleep-out
 * and display-on.
 */
static const struct a3_seq a3_init_seq[] = {
%(seq)s
};

struct a3_panel {
\tstruct drm_panel panel;
\tstruct mipi_dsi_device *dsi;
};

static inline struct a3_panel *to_a3_panel(struct drm_panel *panel)
{
\treturn container_of(panel, struct a3_panel, panel);
}

static int a3_panel_prepare(struct drm_panel *panel)
{
	/*
	 * Deliberately empty: drm_atomic_bridge_chain_pre_enable() walks the chain
	 * backwards, so this runs *before* mtk_dsi_poweron().  Sending DCS
	 * commands here times out with -ETIME because the command channel is not
	 * up yet; the init sequence therefore lives in a3_panel_enable().
	 */
	return 0;
}

static int a3_panel_enable(struct drm_panel *panel)
{
\tstruct a3_panel *ctx = to_a3_panel(panel);
\tstruct mipi_dsi_device *dsi = ctx->dsi;
\tu8 buf[5];
\tint i, ret;

\tfor (i = 0; i < ARRAY_SIZE(a3_init_seq); i++) {
\t\tconst struct a3_seq *s = &a3_init_seq[i];

\t\tif (s->len == 0xff) {
\t\t\tmsleep(s->delay_ms);
\t\t\tcontinue;
\t\t}

\t\tbuf[0] = s->cmd;
\t\tmemcpy(&buf[1], s->data, s->len);
\t\tret = mipi_dsi_dcs_write_buffer(dsi, buf, s->len + 1);
\t\tif (ret < 0) {
\t\t\tdev_err(&dsi->dev, "init cmd 0x%%02x failed: %%d\\n",
\t\t\t\ts->cmd, ret);
\t\t\treturn ret;
\t\t}
\t}

\tdev_info(&dsi->dev, "panel init sequence sent (%%zu entries)\\n",
\t\t ARRAY_SIZE(a3_init_seq));
\treturn 0;
}

static int a3_panel_disable(struct drm_panel *panel)
{
\tstruct a3_panel *ctx = to_a3_panel(panel);

\tmipi_dsi_dcs_write_seq(ctx->dsi, MIPI_DCS_SET_DISPLAY_OFF);
\tmsleep(20);
\tmipi_dsi_dcs_write_seq(ctx->dsi, MIPI_DCS_ENTER_SLEEP_MODE);
\tmsleep(120);
\treturn 0;
}

static int a3_panel_unprepare(struct drm_panel *panel)
{
\treturn 0;
}

static int a3_panel_get_modes(struct drm_panel *panel,
\t\t\t      struct drm_connector *connector)
{
\tstruct drm_display_mode *mode;
\tstruct videomode vm = {
\t\t.pixelclock = A3_PANEL_CLOCK,
\t\t.hactive = A3_PANEL_WIDTH,
\t\t.hfront_porch = 40,
\t\t.hback_porch = 30,
\t\t.hsync_len = 2,
\t\t.vactive = A3_PANEL_HEIGHT,
\t\t.vfront_porch = 25,
\t\t.vback_porch = 10,
\t\t.vsync_len = 2,
\t};

\tmode = drm_mode_create(connector->dev);
\tif (!mode) {
\t\tdev_err(panel->dev, "drm_mode_create failed\\n");
\t\treturn 0;
\t}
\tdrm_display_mode_from_videomode(&vm, mode);
\tmode->type = DRM_MODE_TYPE_DRIVER | DRM_MODE_TYPE_PREFERRED;
\tdrm_mode_set_name(mode);
\tdrm_mode_probed_add(connector, mode);

\tdev_info(panel->dev, "added mode %%s %%ux%%u clock=%%u\\n", mode->name,
\t\t mode->hdisplay, mode->vdisplay, mode->clock);

\tconnector->display_info.width_mm = 68;
\tconnector->display_info.height_mm = 143;
\tconnector->display_info.bpc = 8;

\treturn 1;
}

static const struct drm_panel_funcs a3_panel_funcs = {
\t.prepare = a3_panel_prepare,
\t.enable = a3_panel_enable,
\t.disable = a3_panel_disable,
\t.unprepare = a3_panel_unprepare,
\t.get_modes = a3_panel_get_modes,
};

static int a3_panel_probe(struct mipi_dsi_device *dsi)
{
\tstruct device *dev = &dsi->dev;
\tstruct a3_panel *ctx;
\tint ret;

\tctx = devm_kzalloc(dev, sizeof(*ctx), GFP_KERNEL);
\tif (!ctx)
\t\treturn -ENOMEM;

\tctx->dsi = dsi;
\tmipi_dsi_set_drvdata(dsi, ctx);

\tdsi->lanes = A3_PANEL_LANES;
\tdsi->format = MIPI_DSI_FMT_RGB888;
\tdsi->mode_flags = MIPI_DSI_MODE_VIDEO | MIPI_DSI_MODE_VIDEO_BURST |
\t\t\t  MIPI_DSI_MODE_LPM | MIPI_DSI_MODE_NO_EOT_PACKET;

\tdrm_panel_init(&ctx->panel, dev, &a3_panel_funcs,
\t\t       DRM_MODE_CONNECTOR_DSI);

\tret = drm_panel_of_backlight(&ctx->panel);
\tif (ret)
\t\tdev_info(dev, "no backlight, continuing\\n");

\tdrm_panel_add(&ctx->panel);

\t/* this is what makes mtk_dsi register its DRM component */
\tret = mipi_dsi_attach(dsi);
\tif (ret < 0) {
\t\tdev_err(dev, "failed to attach to DSI host: %%d\\n", ret);
\t\tdrm_panel_remove(&ctx->panel);
\t\treturn ret;
\t}

\tdev_info(dev, "nt36672 1080x2280 panel attached (4 lanes, video burst)\\n");
\treturn 0;
}

static void a3_panel_remove(struct mipi_dsi_device *dsi)
{
\tstruct a3_panel *ctx = mipi_dsi_get_drvdata(dsi);

\tmipi_dsi_detach(dsi);
\tdrm_panel_remove(&ctx->panel);
}

static const struct of_device_id a3_panel_of_match[] = {
\t{ .compatible = "oppo,a3-nt36672" },
\t{ }
};
MODULE_DEVICE_TABLE(of, a3_panel_of_match);

static struct mipi_dsi_driver a3_panel_driver = {
\t.probe = a3_panel_probe,
\t.remove = a3_panel_remove,
\t.driver = {
\t\t.name = "panel-a3-nt36672",
\t\t.of_match_table = a3_panel_of_match,
\t},
};
module_mipi_dsi_driver(a3_panel_driver);

MODULE_DESCRIPTION("JDI nt36672 DSI panel for the OPPO A3");
MODULE_LICENSE("GPL");
''' % {"seq": seq}

io.open(TARGET, "w", encoding="utf-8").write(driver)
print("wrote", TARGET)
