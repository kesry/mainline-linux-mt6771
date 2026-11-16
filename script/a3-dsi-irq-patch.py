#!/usr/bin/env python3
"""Do not let the DSI interrupt fire before its clocks are running.

mtk_dsi_probe() requests the DSI interrupt while the device is runtime-suspended,
i.e. with the engine/digital clocks *off*.  LK boots the kernel with the DSI
controller already running, so an interrupt can already be pending; the handler
then reads DSI registers over an unclocked bus, which wedges the interconnect and
shows up as an RCU stall a few seconds later.

Observed:
    a3t03 (DSI still deferred -> no IRQ requested)  -> boots
    a3t04+ (DSI probes, IRQ requested)              -> RCU stall at ~10 s

Fix: request the IRQ with IRQF_NO_AUTOEN and only enable it in mtk_dsi_poweron()
(after the clocks are up), disabling it again in mtk_dsi_poweroff() before the
clocks are turned off.
"""
import io
import sys

P = "/opt/oppoa3/kernel-src/drivers/gpu/drm/mediatek/mtk_dsi.c"
s = io.open(P, encoding="utf-8").read()

if "IRQF_NO_AUTOEN" in s:
    print("already patched")
    sys.exit(0)

# ---- 1. struct: remember the irq number ---------------------------------
old = "\tstruct phy *phy;\n"
new = "\tstruct phy *phy;\n\tint irq;\t\t\t/* A3: enabled only while powered */\n"
if old not in s:
    sys.exit("struct phy anchor missing")
s = s.replace(old, new, 1)

# ---- 2. probe: store irq, request it disabled ---------------------------
old = """\tret = devm_request_irq(&pdev->dev, irq_num, mtk_dsi_irq,
\t\t\t       IRQF_TRIGGER_NONE, dev_name(&pdev->dev), dsi);"""
new = """\tdsi->irq = irq_num;
\t/*
\t * A3: do not auto-enable.  LK leaves the DSI running, so an interrupt can
\t * already be pending here while our clocks are still off; letting the
\t * handler run would read unclocked registers and hang the bus.
\t */
\tret = devm_request_irq(&pdev->dev, irq_num, mtk_dsi_irq,
\t\t\t       IRQF_TRIGGER_NONE | IRQF_NO_AUTOEN,
\t\t\t       dev_name(&pdev->dev), dsi);"""
if old not in s:
    sys.exit("request_irq anchor missing")
s = s.replace(old, new, 1)

# ---- 3. poweron: enable the irq once clocks are running -----------------
old = "\tmtk_dsi_set_interrupt_enable(dsi);\n\n\treturn 0;"
new = ("\tmtk_dsi_set_interrupt_enable(dsi);\n\n"
       "\t/* A3: clocks are up, it is now safe for the handler to run */\n"
       "\tenable_irq(dsi->irq);\n\n"
       "\treturn 0;")
if old not in s:
    sys.exit("poweron anchor missing")
s = s.replace(old, new, 1)

# ---- 4. poweroff: mask the irq before the clocks go away ----------------
old = """\tif (--dsi->refcount != 0)
\t\treturn;
"""
new = """\tif (--dsi->refcount != 0)
\t\treturn;

\t/* A3: mask the irq while we still have clocks to service it */
\tdisable_irq(dsi->irq);
"""
if old not in s:
    sys.exit("poweroff anchor missing")
s = s.replace(old, new, 1)

io.open(P, "w", encoding="utf-8").write(s)
print("mtk_dsi: IRQ deferred to poweron")
