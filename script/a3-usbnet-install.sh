#!/bin/bash
# a3-usbnet-install.sh — 把 RNDIS→ECM 自动切换能力注入 rootfs（可选组件）
#
# 用法（在构建脚本里调用，操作的是 staged rootfs 目录）：
#   A3_USBNET_AUTO_ECM=1 bash a3-usbnet-install.sh <rootfs-dir> <scripts-dir> [rndis-script-name]
#
#   rootfs-dir      : staged rootfs（如 $ROOT）
#   scripts-dir     : 本仓库 script/ 目录（含 a3-gadget-ecm.sh / a3-usbnet-window.sh）
#   rndis-script-name: rootfs 里基础 RNDIS gadget 脚本名
#                      Debian rootfs = a3-usb-gadget（默认）
#                      飞牛 rootfs   = a3-gadget
#
# 行为：
#   安装 a3-gadget-ecm / a3-usbnet-window，创建 a3-usbnet.service 并 enable。
#   /etc/a3-usbnet.conf 默认【无 KEEP 行】→ 开机 180 秒后自动切 ECM。
#   如需临时保持 RNDIS：a3-usbnet-window keep
set -eu

ROOT="${1:?需要 rootfs 目录}"
SRCDIR="${2:?需要脚本目录}"
RNDIS_NAME="${3:-a3-usb-gadget}"

say() { echo "  [usbnet] $*"; }

# 1. 安装切换脚本
install -m 0755 "$SRCDIR/a3-gadget-ecm.sh"    "$ROOT/usr/local/sbin/a3-gadget-ecm"
install -m 0755 "$SRCDIR/a3-usbnet-window.sh" "$ROOT/usr/local/sbin/a3-usbnet-window"

# 2. 适配 RNDIS 脚本名：窗口脚本与 ECM 脚本里写死的是 a3-usb-gadget，
#    飞牛 rootfs 用的是 a3-gadget，替换掉
if [ "$RNDIS_NAME" != "a3-usb-gadget" ]; then
    sed -i "s|a3-usb-gadget|${RNDIS_NAME}|g" \
        "$ROOT/usr/local/sbin/a3-gadget-ecm" \
        "$ROOT/usr/local/sbin/a3-usbnet-window"
fi

# 3. systemd 服务
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
cat > "$ROOT/etc/systemd/system/a3-usbnet.service" <<'UNIT'
[Unit]
Description=A3 USB network mode (RNDIS window then ECM)
After=a3-gadget.service a3-usb-gadget.service
Wants=a3-gadget.service a3-usb-gadget.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/a3-usbnet-window window
Restart=no

[Install]
WantedBy=multi-user.target
UNIT
ln -sf /etc/systemd/system/a3-usbnet.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/a3-usbnet.service"

# 4. 配置：无 KEEP 行 = 180 秒后自动切 ECM
cat > "$ROOT/etc/a3-usbnet.conf" <<'EOF'
# a3-usbnet: 开机 RNDIS 窗口配置
#   KEEP=rndis   保持 RNDIS（不切 ECM）
#   KEEP=ecm     立即切 ECM
#   没有 KEEP 行 = 180 秒后自动切 ECM
#
# 默认无 KEEP 行：开机 180 秒后自动切 ECM。
# 调试时保持 RNDIS：a3-usbnet-window keep
EOF

say "已安装（RNDIS 脚本名=$RNDIS_NAME，默认 180s 后自动切 ECM）"
