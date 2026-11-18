#!/bin/sh
# a3-usbnet-window - 开机 RNDIS 三分钟窗口，超时切 ECM
#
# 逻辑：
#   开机后 RNDIS+ACM 已由 a3-usb-gadget.service 建立。
#   本脚本开始 180 秒计时：
#     期间写入 KEEP=rndis  → 保持 RNDIS，退出
#     期间写入 KEEP=ecm    → 立即切 ECM
#     180 秒无写入         → 自动切 ECM
#
# 关键：切 ECM 直接调用已验证的 /usr/local/sbin/a3-gadget-ecm，
#       不重写它的 gadget 创建逻辑（那版实测能枚举出 A3 ECM）。
#
# 用法：
#   a3-usbnet-window keep     保持 RNDIS
#   a3-usbnet-window now      立即切 ECM
#   a3-usbnet-window rndis    切回 RNDIS
#   a3-usbnet-window status   查看状态
#   a3-usbnet-window window   由 systemd 调用，开始计时

set -u

CONF=/etc/a3-usbnet.conf
CONSOLE=/dev/console
WINDOW=180
ECM_SCRIPT=/usr/local/sbin/a3-gadget-ecm
RNDIS_SCRIPT=/usr/local/sbin/a3-usb-gadget

say() {
    echo "$*"
    [ -w "$CONSOLE" ] && echo ">>> $*" > "$CONSOLE" 2>/dev/null
    return 0
}

read_keep() {
    [ -f "$CONF" ] || { echo ""; return; }
    sed -n 's/^[[:space:]]*KEEP[[:space:]]*=[[:space:]]*//p' "$CONF" 2>/dev/null \
        | head -1 | tr -d '"'"'"' \r'
}

write_keep() {
    mkdir -p "$(dirname "$CONF")"
    if [ -f "$CONF" ] && grep -qE '^[[:space:]]*KEEP[[:space:]]*=' "$CONF" 2>/dev/null; then
        sed -i "s|^[[:space:]]*KEEP[[:space:]]*=.*|KEEP=$1|" "$CONF"
    else
        echo "KEEP=$1" >> "$CONF"
    fi
    say "已写入 $CONF: KEEP=$1"
}

clear_keep() {
    if [ -f "$CONF" ]; then
        sed -i '/^[[:space:]]*KEEP[[:space:]]*=/d' "$CONF" 2>/dev/null
    fi
}

do_switch_ecm() {
    [ -x "$ECM_SCRIPT" ] || { say "ERROR: 缺少 $ECM_SCRIPT"; return 1; }
    say "切换到 ECM（调用 a3-gadget-ecm start）"
    # 先停掉 RNDIS 服务，避免它 RemainAfterExit 的状态干扰
    systemctl stop a3-usb-gadget.service 2>/dev/null
    sleep 1
    "$ECM_SCRIPT" start 2>&1 | while read -r l; do say "  $l"; done
    return 0
}

do_switch_rndis() {
    say "切回 RNDIS"
    # 解绑 ECM
    if [ -d /sys/kernel/config/usb_gadget/a3ecm ]; then
        echo "" > /sys/kernel/config/usb_gadget/a3ecm/UDC 2>/dev/null
        sleep 1
        g=/sys/kernel/config/usb_gadget/a3ecm
        for f in "$g"/configs/c.*/*; do [ -L "$f" ] && rm -f "$f" 2>/dev/null; done
        for c in "$g"/configs/c.*; do
            [ -d "$c/strings/0x409" ] && rmdir "$c/strings/0x409" 2>/dev/null
            [ -d "$c" ] && rmdir "$c" 2>/dev/null
        done
        for f in "$g"/functions/*; do [ -d "$f" ] && rmdir "$f" 2>/dev/null; done
        [ -d "$g/strings/0x409" ] && rmdir "$g/strings/0x409" 2>/dev/null
        rmdir "$g" 2>/dev/null
    fi
    sleep 1
    [ -x "$RNDIS_SCRIPT" ] && "$RNDIS_SCRIPT" 2>&1 | tail -3
    sleep 2
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        case "$n" in
            usb*)
                mac=$(cat "$i/address" 2>/dev/null)
                if [ "$mac" = "02:00:a3:00:00:02" ]; then
                    ip link set "$n" up 2>/dev/null
                    ip -4 addr show "$n" 2>/dev/null | grep -q "10.42.1.2" || \
                        ip addr add 10.42.1.2/24 dev "$n" 2>/dev/null
                    say "$n carrier=$(cat "$i/carrier" 2>/dev/null) IP=$(ip -4 -o addr show "$n" 2>/dev/null | awk '{print $4}')"
                fi
                ;;
        esac
    done
    return 0
}

do_status() {
    say "=== 配置 ==="
    if [ -f "$CONF" ]; then
        k=$(read_keep)
        say "  KEEP=${k:-（无）}"
    else
        say "  $CONF 不存在（= 超时后切 ECM）"
    fi

    echo "=== gadget ==="
    for g in /sys/kernel/config/usb_gadget/*; do
        [ -d "$g" ] || continue
        n=$(basename "$g")
        u=$(cat "$g/UDC" 2>/dev/null)
        f=$(ls "$g/functions" 2>/dev/null | tr '\n' ' ')
        echo "  $n  UDC=${u:-未绑定}  funcs=$f"
    done

    echo "=== 网络 ==="
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        case "$n" in
            usb*)
                echo "  $n mac=$(cat "$i/address" 2>/dev/null) carrier=$(cat "$i/carrier" 2>/dev/null) IP=$(ip -4 -o addr show "$n" 2>/dev/null | awk '{print $4}')"
                ;;
        esac
    done

    echo "=== 串口 ==="
    [ -c /dev/ttyGS0 ] && echo "  /dev/ttyGS0 存在" || echo "  /dev/ttyGS0 不存在"

    echo "=== 服务 ==="
    echo "  a3-usb-gadget: $(systemctl is-active a3-usb-gadget.service 2>&1)"
    echo "  a3-usbnet:     $(systemctl is-active a3-usbnet.service 2>&1)"
}

[ "$(id -u)" = 0 ] || { echo "需要 root" >&2; exit 1; }

case "${1:-window}" in
    window)
        clear_keep
        say "RNDIS 窗口开始，${WINDOW} 秒内执行 'a3-usbnet-window keep' 可保持 RNDIS"
        i=0
        while [ $i -lt "$WINDOW" ]; do
            sleep 5
            i=$((i+5))
            k=$(read_keep)
            case "$k" in
                rndis)
                    say "检测到 KEEP=rndis，保持 RNDIS"
                    exit 0
                    ;;
                ecm)
                    say "检测到 KEEP=ecm，立即切换"
                    do_switch_ecm
                    exit 0
                    ;;
            esac
        done
        say "${WINDOW} 秒内无 KEEP 设置，自动切换到 ECM"
        write_keep ecm
        do_switch_ecm
        exit 0
        ;;
    keep)
        write_keep rndis
        say "保持 RNDIS，不再自动切 ECM"
        ;;
    now)
        write_keep ecm
        do_switch_ecm
        ;;
    rndis)
        clear_keep
        do_switch_rndis
        ;;
    status)
        do_status
        ;;
    *)
        echo "用法: $0 {window|keep|now|rndis|status}" >&2
        exit 1
        ;;
esac