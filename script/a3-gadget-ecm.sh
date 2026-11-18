#!/bin/sh
# a3-gadget-ecm - 在 RNDIS 与 CDC-ECM 之间切换 USB 网络功能
#
# 背景：
#   Windows 只认 RNDIS，Linux（如某些 NAS 的精简内核）可能只认 CDC-ECM。
#   默认开机用 RNDIS+ACM；需要接 NAS 时手工切到 ECM。
#
# 用法：
#   a3-gadget-ecm start    切换到 ECM（自动配好 IP 和链路）
#   a3-gadget-ecm stop     切回 RNDIS（调用原 a3-usb-gadget）
#   a3-gadget-ecm status   查看当前状态
#
# 关键点（踩过的坑）：
#   · ECM 接口创建后必须 `ip link set up`，否则主机侧看到 NO-CARRIER，
#     包根本发不出来（ping 报 Destination Host Unreachable）
#   · 接口名不确定（usb0 / usb1 / enx...），要按 MAC 或 driver 找
#   · gadget 切换会重置 USB，SSH 会断，操作前建议有串口或屏幕可用

set -u

GECM=/sys/kernel/config/usb_gadget/a3ecm
IP_DEV=10.42.1.2/24
HOST_MAC=02:00:a3:00:01:01
DEV_MAC=02:00:a3:00:01:02

die() { echo "错误: $*" >&2; }

# 同时输出到手机屏幕（/dev/console → 帧缓冲控制台）
# 这样插在 NAS 上、没有 SSH 时也能从屏幕看到进展。
CONSOLE=/dev/console
sayscreen() {
    echo "$*"
    [ -w "$CONSOLE" ] && echo ">>> $*" > "$CONSOLE" 2>/dev/null
    return 0
}

# 找到 ECM 对应的网络接口（按 MAC 匹配最可靠）
find_ecm_iface() {
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        [ "$n" = "lo" ] && continue
        mac=$(cat "$i/address" 2>/dev/null)
        [ "$mac" = "$DEV_MAC" ] && { echo "$n"; return 0; }
    done
    # 退路：找 usb 类型的非 rndis 接口
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        [ -e "$i/device/driver" ] || continue
        drv=$(basename "$(readlink -f "$i/device/driver" 2>/dev/null)" 2>/dev/null)
        case "$drv" in
            cdc_ether|usbnet) echo "$n"; return 0 ;;
        esac
    done
    return 1
}

# 让接口 up 并配 IP —— 这一步决定有没有 carrier
configure_iface() {
    IF="$1"
    echo "配置 $IF ..."
    ip link set "$IF" up 2>/dev/null
    # 等 carrier 起来（最多 5 秒）
    i=0
    while [ $i -lt 50 ]; do
        c=$(cat "/sys/class/net/$IF/carrier" 2>/dev/null)
        [ "$c" = "1" ] && break
        sleep 0.1
        i=$((i+1))
    done
    # 清掉旧 IP 再加（避免多个地址）
    ip -4 addr flush dev "$IF" 2>/dev/null
    ip addr add "$IP_DEV" dev "$IF" 2>/dev/null
    ip4=$(ip -4 -o addr show "$IF" 2>/dev/null | awk '{print $4}')
    car=$(cat "/sys/class/net/$IF/carrier" 2>/dev/null)
    st=$(cat "/sys/class/net/$IF/operstate" 2>/dev/null)
    echo "  IP:     $ip4"
    echo "  carrier: $car"
    echo "  state:   $st"
    sayscreen "ECM 接口 $IF  carrier=$car  state=$st  IP=$ip4"
    [ "$car" = "1" ] || sayscreen "警告: carrier=0，NAS 会看到 NO-CARRIER"
}

do_status() {
    sayscreen "========== USB 网络状态 =========="
    echo "=== gadget ==="
    for g in /sys/kernel/config/usb_gadget/*; do
        [ -d "$g" ] || continue
        echo "  $(basename "$g"): UDC=$(cat "$g/UDC" 2>/dev/null) funcs=$(ls "$g/functions" 2>/dev/null | tr '\n' ' ')"
    done

    echo "=== 网络接口 ==="
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        [ "$n" = "lo" ] && continue
        mac=$(cat "$i/address" 2>/dev/null)
        echo "  $n"
        ip4=$(ip -4 -o addr show "$n" 2>/dev/null | awk '{print $4}')
        echo "     mac=$mac  state=$(cat "$i/operstate" 2>/dev/null) carrier=$(cat "$i/carrier" 2>/dev/null)"
        echo "     IP=$ip4"
        sayscreen "  $n  carrier=$(cat "$i/carrier" 2>/dev/null)  IP=${ip4:-无}"
    done
}

do_start() {
    [ "$(id -u)" = 0 ] || die "需要 root"
    mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config 2>/dev/null

    echo "=== 卸载现有 gadget ==="
    for g in /sys/kernel/config/usb_gadget/*; do
        [ -d "$g" ] || continue
        [ -e "$g/UDC" ] && echo "" > "$g/UDC" 2>/dev/null
    done
    sleep 1

    echo "=== 创建 ECM gadget ==="
    mkdir -p "$GECM" || die "创建 $GECM 失败"
    echo 0x1d6b > "$GECM/idVendor"
    echo 0x0105 > "$GECM/idProduct"
    echo 0x0100 > "$GECM/bcdDevice"
    echo 0x0200 > "$GECM/bcdUSB"
    echo 0x02 > "$GECM/bDeviceClass"
    echo 0x00 > "$GECM/bDeviceSubClass"
    echo 0x00 > "$GECM/bDeviceProtocol"

    mkdir -p "$GECM/strings/0x409"
    echo PADT00 > "$GECM/strings/0x409/serialnumber"
    echo OPPO > "$GECM/strings/0x409/manufacturer"
    echo "A3 ECM" > "$GECM/strings/0x409/product"

    mkdir -p "$GECM/configs/c.1/strings/0x409"
    echo "ECM" > "$GECM/configs/c.1/strings/0x409/configuration"
    echo 120 > "$GECM/configs/c.1/MaxPower" 2>/dev/null

    mkdir -p "$GECM/functions/ecm.usb0"
    echo "$DEV_MAC" > "$GECM/functions/ecm.usb0/dev_addr"
    echo "$HOST_MAC" > "$GECM/functions/ecm.usb0/host_addr"
    ln -sf "$GECM/functions/ecm.usb0" "$GECM/configs/c.1/ecm.usb0"

    UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
    [ -n "$UDC" ] || die "没有 UDC"
    echo "$UDC" > "$GECM/UDC" || die "绑定 UDC 失败"
    echo "已绑定 $UDC"
    sleep 2

    echo "=== 配置网络接口（关键：必须 up 才有 carrier）==="
    IF=$(find_ecm_iface)
    if [ -n "$IF" ]; then
        configure_iface "$IF"
    else
        echo "  未找到 ECM 接口，稍后手工执行："
        echo "    ip link set <iface> up && ip addr add $IP_DEV dev <iface>"
    fi

    echo
    echo "=== 完成 ==="
    echo "NAS 上执行："
    echo "  ip link set <NAS侧接口> up"
    echo "  ip addr add 10.42.1.1/24 dev <NAS侧接口>"
    echo "  ping -c3 10.42.1.2"
    sayscreen "========== ECM 已启动 =========="
    sayscreen "NAS 上请执行:"
    sayscreen "  ip link set <接口> up"
    sayscreen "  ip addr add 10.42.1.1/24 dev <接口>"
    sayscreen "  ping -c3 10.42.1.2"
}

do_stop() {
    echo "=== 卸载 ECM，恢复 RNDIS+ACM ==="
    for g in /sys/kernel/config/usb_gadget/*; do
        [ -d "$g" ] || continue
        [ -e "$g/UDC" ] && echo "" > "$g/UDC" 2>/dev/null
    done
    sleep 1
    # 清理 ACM/ECM gadget
    for g in /sys/kernel/config/usb_gadget/a3ecm /sys/kernel/config/usb_gadget/a3; do
        [ -d "$g" ] || continue
        for f in "$g"/configs/c.1/*; do [ -L "$f" ] && rm -f "$f"; done
        rmdir "$g"/configs/c.1/strings/0x409 2>/dev/null
        rmdir "$g"/configs/c.1 2>/dev/null
        for f in "$g"/functions/*; do [ -d "$f" ] && rmdir "$f" 2>/dev/null; done
        rmdir "$g"/strings/0x409 2>/dev/null
        rmdir "$g" 2>/dev/null
    done

    if [ -x /usr/local/sbin/a3-usb-gadget ]; then
        echo "调用 a3-usb-gadget 恢复 RNDIS"
        /usr/local/sbin/a3-usb-gadget
    else
        echo "警告: 找不到 /usr/local/sbin/a3-usb-gadget"
    fi

    sleep 2
    echo "=== 结果 ==="
    IF=$(find_ecm_iface 2>/dev/null || true)
    for i in /sys/class/net/*; do
        n=$(basename "$i")
        case "$n" in usb*|enx*)
            echo "  $n: IP=$(ip -4 -o addr show "$n" 2>/dev/null | awk '{print $4}') carrier=$(cat "$i/carrier" 2>/dev/null)"
            ;;
        esac
    done
}

[ "$(id -u)" = 0 ] || die "需要 root"
case "${1:-status}" in
    start)  do_start ;;
    stop)   do_stop ;;
    status) do_status ;;
    *)      die "用法: $0 {start|stop|status}" ;;
esac