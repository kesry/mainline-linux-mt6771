#!/bin/sh
# install-a3-usbnet - 可选：安装 USB 网络模式切换服务
#
# 这不是 rootfs 的默认组件。默认 rootfs 只启用 a3-usb-gadget.service
# （RNDIS + ACM），Windows 和普通 Linux 都能用。
#
# 只有在需要接"精简内核、没有 rndis_host 驱动"的 NAS 时才装这个服务。
#
# 用法（在设备上执行）：
#   install-a3-usbnet            安装并启用（开机进 180 秒 RNDIS 窗口）
#   install-a3-usbnet --remove   卸载，恢复默认行为
#
# 安装后的行为：
#   开机 → RNDIS + ACM 可用，同时开始 180 秒计时
#        → 期间执行 a3-usbnet keep 保持 RNDIS
#        → 超时后自动切 ECM（此时 Windows 上会失联，正常）

set -u

SBIN=/usr/local/sbin
SYSD=/etc/systemd/system
SRC_DIR=$(dirname "$0")

say() { echo "$*"; }
die() { echo "错误: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "需要 root"

do_remove() {
    say "=== 卸载 a3-usbnet ==="
    systemctl disable --now a3-usbnet.service 2>/dev/null
    rm -f "$SYSD/a3-usbnet.service"
    systemctl daemon-reload
    rm -f "$SBIN/a3-usbnet-window"
    rm -f /etc/a3-usbnet.conf
    say "已移除服务、窗口脚本和配置（a3-gadget-ecm 保留，可单独使用）"
    say "注意：如果当前正处在 ECM 模式，需要重启才能回到 RNDIS"
}

do_install() {
    say "=== 检查前置条件 ==="

    # 窗口脚本
    for cand in "$SRC_DIR/a3-usbnet-window.sh" "$SRC_DIR/a3-usbnet-window"; do
        if [ -f "$cand" ]; then
            install -m 0755 "$cand" "$SBIN/a3-usbnet-window" || die "安装 a3-usbnet-window 失败"
            say "  脚本  $SBIN/a3-usbnet-window"
            break
        fi
    done
    [ -x "$SBIN/a3-usbnet-window" ] || die "找不到 a3-usbnet-window.sh（应与本脚本同目录）"

    # ECM 切换脚本（窗口脚本依赖它）
    for cand in "$SRC_DIR/a3-gadget-ecm.sh" "$SRC_DIR/a3-gadget-ecm"; do
        if [ -f "$cand" ]; then
            install -m 0755 "$cand" "$SBIN/a3-gadget-ecm" || die "安装 a3-gadget-ecm 失败"
            say "  脚本  $SBIN/a3-gadget-ecm"
            break
        fi
    done
    [ -x "$SBIN/a3-gadget-ecm" ] || die "找不到 a3-gadget-ecm.sh（应与本脚本同目录）"

    # 依赖检查
    [ -x "$SBIN/a3-usb-gadget" ] || die "缺少 $SBIN/a3-usb-gadget（rootfs 默认组件）"
    say "  依赖  $SBIN/a3-usb-gadget 存在"

    [ -d /sys/kernel/config/usb_gadget ] || die "configfs gadget 不可用"
    say "  configfs 可用"

    # 服务单元
    cat > "$SYSD/a3-usbnet.service" <<'UNIT'
[Unit]
Description=A3 USB network mode (RNDIS window then ECM)
After=a3-usb-gadget.service
Wants=a3-usb-gadget.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/a3-usbnet-window window
Restart=no

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable a3-usbnet.service || die "enable 失败"
    say "  服务  已启用"

    # 配置文件不预置内容：没有 KEEP 行 = 超时后切 ECM
    if [ ! -f /etc/a3-usbnet.conf ]; then
        {
            echo "# a3-usbnet: 开机 RNDIS 窗口配置"
            echo "#   KEEP=rndis   保持 RNDIS（不切 ECM）"
            echo "#   KEEP=ecm     切 ECM"
            echo "#   没有 KEEP 行 = 180 秒后自动切 ECM"
        } > /etc/a3-usbnet.conf
        say "  配置  /etc/a3-usbnet.conf 已创建（无 KEEP 行）"
    else
        say "  配置  /etc/a3-usbnet.conf 已存在，保留"
    fi

    say ""
    say "=== 安装完成 ==="
    say "下次开机会先起 RNDIS+ACM，180 秒后若没执行 'a3-usbnet-window keep' 就切 ECM。"
    say "立即启动（不重启）：systemctl start a3-usbnet.service"
    say "查看状态：a3-usbnet-window status"
}

case "${1:-install}" in
    --remove|remove) do_remove ;;
    install|"")      do_install ;;
    *)               echo "用法: $0 [--remove]" >&2; exit 1 ;;
esac