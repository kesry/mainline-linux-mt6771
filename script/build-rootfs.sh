#!/bin/sh
# 从零构建 OPPO A3 的 Debian 13 根文件系统镜像。
#
# 用法：build-rootfs.sh <minimal|phosh> <输出文件> [镜像大小]
#   minimal  最小系统 + SSH，体积小，适合先验证内核
#   phosh    在 minimal 基础上加手机桌面 phosh + 屏幕键盘 + 中文字体
#
# 需要：debootstrap、qemu-user-static、binfmt-support、mke2fs
# 在 x86 上构建 arm64 根文件系统靠 qemu-aarch64-static 跑 postinst。
set -e

VARIANT="${1:?用法: build-rootfs.sh <minimal|phosh> <输出镜像> [大小]}"
OUT="${2:?缺少输出文件名}"
SIZE="${3:-2G}"

RELEASE=trixie
MIRROR=http://deb.debian.org/debian
SECMIRROR=http://security.debian.org/debian-security
ROOT="$(mktemp -d /tmp/a3-rootfs.XXXXXX)"
trap 'cleanup' EXIT INT TERM

say() { printf "\n\033[1;32m== %s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m!! %s\033[0m\n" "$*"; }

# 卸载 chroot 里的伪文件系统，否则 rm 可能删不掉
cleanup() {
    for m in dev/pts dev proc sys run; do
        mountpoint -q "$ROOT/$m" 2>/dev/null && umount -lf "$ROOT/$m" 2>/dev/null || true
    done
    rm -rf "$ROOT"
}

# 在 chroot 里执行命令，可带环境变量
in_root() {
    env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root LANG=C.UTF-8 \
        DEBIAN_FRONTEND=noninteractive \
        chroot "$ROOT" /bin/sh -c "$*"
}

mount_pseudo() {
    mount -t proc  proc  "$ROOT/proc"     2>/dev/null || true
    mount -t sysfs sysfs "$ROOT/sys"      2>/dev/null || true
    mount -o bind /dev    "$ROOT/dev"     2>/dev/null || true
    mount -t devpts devpts "$ROOT/dev/pts" 2>/dev/null || true
    mount -t tmpfs tmpfs  "$ROOT/run"     2>/dev/null || true
}

say "阶段 1：解压基础系统（--foreign，不在 x86 上执行 arm64 代码）"
debootstrap --arch=arm64 --foreign --variant=minbase \
    --include=ca-certificates \
    "$RELEASE" "$ROOT" "$MIRROR"

say "阶段 2：放入 qemu 并在 chroot 里完成第二段"
QEMU_BIN="$(command -v qemu-aarch64-static || echo /usr/bin/qemu-aarch64-static)"
if [ ! -f "$QEMU_BIN" ]; then
    echo "缺少 qemu-aarch64-static，请安装 qemu-user-static" >&2
    exit 1
fi
install -m 0755 "$QEMU_BIN" "$ROOT/usr/bin/qemu-aarch64-static"

cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
# --second-stage 之前必须能跑 arm64 代码，qemu 已就位
chroot "$ROOT" /debootstrap/debootstrap --second-stage

say "阶段 3：配置 apt 源"
cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $RELEASE main contrib non-free-firmware
deb $MIRROR ${RELEASE}-updates main contrib non-free-firmware
deb $SECMIRROR ${RELEASE}-security main contrib non-free-firmware
EOF

say "阶段 4：挂载伪文件系统（apt 和 systemctl 需要）"
mount_pseudo

say "阶段 5：安装基础软件包"
PKGS="systemd systemd-sysv udev kmod iproute2 iputils-ping net-tools \
      openssh-server sudo less vim-tiny procps rsync \
      util-linux mount e2fsprogs dosfstools \
      libpam-systemd dbus \
      systemd-timesyncd systemd-resolved tzdata ca-certificates"

in_root "apt-get update"
in_root "apt-get install -y --no-install-recommends $PKGS"

if [ "$VARIANT" = "phosh" ]; then
    say "阶段 6：安装 phosh 手机桌面"
    in_root "apt-get install -y --no-install-recommends \
        phosh squeekboard phosh-mobile-settings kbd dconf-cli \
        fonts-noto-cjk fonts-noto-cjk-extra \
        gnome-settings-daemon upower"
fi

say "阶段 7：账号"
# root/root     —— SSH 和串口管理
# debian/debian —— 桌面会话（Wayland 拒绝以 root 运行，桌面必须有普通用户）
# 不要用 passwd -d：清空密码后 sshd 默认 PermitEmptyPasswords no，
# 只报 Access denied，看不出是空密码导致的。
in_root "echo 'root:root' | chpasswd"

in_root "id -u debian >/dev/null 2>&1 || useradd -m -s /bin/bash -G video,render,input,audio debian"
in_root "echo 'debian:debian' | chpasswd"

say "阶段 8：复合 USB gadget（RNDIS 网络 + ACM 串口）"
# 这一块是设备唯一的管理通道：没有它就没有 usb0，也没法 ssh。
# RNDIS 而不是 CDC-ECM：Windows 对 ECM 的 NDIS 适配器会报错 10，
# 而 RNDIS 在 Windows 和 Linux(rndis_host) 都能用。
# RNDIS 必须排在 ACM 前面，否则主机会重新枚举，串口会掉。
install -d "$ROOT/usr/local/sbin"
cat > "$ROOT/usr/local/sbin/a3-usb-gadget" <<'GADGET'
#!/bin/sh
# 建立 configfs 复合 gadget：先 RNDIS（网络），后 ACM（串口）。
# 顺序不能换：先出现的功能会被主机记住。
set -u
G=/sys/kernel/config/usb_gadget/a3
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config 2>/dev/null

mkdir -p "$G" 2>/dev/null
echo 0x1d6b > "$G/idVendor" 2>/dev/null
echo 0x0104 > "$G/idProduct" 2>/dev/null
echo 0x0100 > "$G/bcdDevice" 2>/dev/null
echo 0x0200 > "$G/bcdUSB" 2>/dev/null
echo 0xEF > "$G/bDeviceClass" 2>/dev/null
echo 0x02 > "$G/bDeviceSubClass" 2>/dev/null
echo 0x01 > "$G/bDeviceProtocol" 2>/dev/null

mkdir -p "$G/strings/0x409" 2>/dev/null
echo PADT00       > "$G/strings/0x409/serialnumber"
echo OPPO         > "$G/strings/0x409/manufacturer"
echo "A3 console" > "$G/strings/0x409/product"

mkdir -p "$G/configs/c.1/strings/0x409" 2>/dev/null
echo "RNDIS+ACM" > "$G/configs/c.1/strings/0x409/configuration"
echo 120        > "$G/configs/c.1/MaxPower" 2>/dev/null

# STEP 1: RNDIS 网络，必须第一个
if mkdir -p "$G/functions/rndis.usb0" 2>/dev/null; then
    echo "02:00:a3:00:00:01" > "$G/functions/rndis.usb0/host_addr" 2>/dev/null
    echo "02:00:a3:00:00:02" > "$G/functions/rndis.usb0/dev_addr"  2>/dev/null
    ln -sf "$G/functions/rndis.usb0" "$G/configs/c.1/rndis.usb0" 2>/dev/null
    echo "a3-usb-gadget: RNDIS linked"
else
    echo "a3-usb-gadget: no RNDIS (CONFIG_USB_CONFIGFS_RNDIS?)"
fi

# STEP 2: ACM 串口
if mkdir -p "$G/functions/acm.usb0" 2>/dev/null; then
    ln -sf "$G/functions/acm.usb0" "$G/configs/c.1/acm.usb0" 2>/dev/null
    echo "a3-usb-gadget: ACM linked"
fi

UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
[ -n "$UDC" ] || { echo "a3-usb-gadget: no UDC"; exit 1; }
echo "$UDC" > "$G/UDC" || { echo "a3-usb-gadget: UDC bind failed"; exit 1; }
echo "a3-usb-gadget: bound to $UDC"
exit 0
GADGET
chmod 0755 "$ROOT/usr/local/sbin/a3-usb-gadget"

cat > "$ROOT/etc/systemd/system/a3-usb-gadget.service" <<'UNIT'
[Unit]
Description=OPPO A3 composite USB gadget (RNDIS network then ACM serial)
Before=network-pre.target
Wants=network-pre.target
DefaultDependencies=no
After=sysfs.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/a3-usb-gadget

[Install]
WantedBy=multi-user.target
UNIT
in_root "systemctl enable a3-usb-gadget.service"

# 可选：RNDIS -> ECM 自动切换（由 A3_USBNET_AUTO_ECM=1 开启）
if [ "${A3_USBNET_AUTO_ECM:-0}" = "1" ]; then
    say "阶段 X：注入自动切 ECM"
    bash "$(dirname "$0")/a3-usbnet-install.sh" "$ROOT" "$(dirname "$0")" "a3-usb-gadget"
fi

# ACM 串口还需要一个 getty 在 /dev/ttyGS0 上等登录，否则主机打开 COM 口
# 只能看到空白，命令打进去没有任何响应。
# 注意不能 enable serial-getty@ttyS0：那是 SoC 的 UART，本机没引出。
ln -sf /lib/systemd/system/serial-getty@.service \
       "$ROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service" 2>/dev/null || true
mkdir -p "$ROOT/etc/systemd/system/getty.target.wants"
ln -sf /lib/systemd/system/serial-getty@.service \
       "$ROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service"
in_root "systemctl enable serial-getty@ttyGS0.service" || \
    warn "serial-getty@ttyGS0 启用失败，可开机后手动 systemctl enable"

say "阶段 9：网络（USB RNDIS usb0）"
mkdir -p "$ROOT/etc/systemd/network"
cat > "$ROOT/etc/systemd/network/10-usb0.network" <<'EOF'
[Match]
Name=usb0

[Network]
Address=10.42.1.2/24
Gateway=10.42.1.1
DNS=223.5.5.5
DNS=8.8.8.8
EOF
in_root "systemctl enable systemd-networkd"

say "阶段 10：时区、时间同步与 DNS"

# 时区
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$ROOT/etc/localtime"
echo "Asia/Shanghai" > "$ROOT/etc/timezone"

# 硬件时钟用 UTC，systemd 负责同步
in_root "systemctl enable systemd-timesyncd" || warn "timesyncd 启用失败"
cat > "$ROOT/etc/systemd/timesyncd.conf" <<'EOF'
[Time]
NTP=ntp.aliyun.com ntp1.aliyun.com cn.pool.ntp.org
FallbackNTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org
EOF
# 允许 timesyncd 在有网后立刻校正（设备刚启动时 RTC 往往是错的）
mkdir -p "$ROOT/etc/systemd/system/systemd-timesyncd.service.d"
cat > "$ROOT/etc/systemd/system/systemd-timesyncd.service.d/override.conf" <<'EOF'
[Service]
Restart=on-failure
RestartSec=5s
EOF

# DNS：用 systemd-resolved 统一管理，resolv.conf 指向 stub
in_root "systemctl enable systemd-resolved" || warn "resolved 启用失败"
mkdir -p "$ROOT/etc/systemd/resolved.conf.d"
cat > "$ROOT/etc/systemd/resolved.conf.d/10-a3.conf" <<'EOF'
[Resolve]
DNS=223.5.5.5 8.8.8.8
FallbackDNS=1.1.1.1
Cache=yes
EOF
ln -sf /run/systemd/resolve/stub-resolv.conf "$ROOT/etc/resolv.conf"

# networkd 不要自己覆盖 resolv.conf（两者会打架）
mkdir -p "$ROOT/etc/systemd/networkd.conf.d"
cat > "$ROOT/etc/systemd/networkd.conf.d/10-a3.conf" <<'EOF'
[Network]
ManageForeignRoutes=no
EOF

say "阶段 11：SSH 与主机名"
in_root "systemctl enable ssh"
echo PADT00 > "$ROOT/etc/hostname"

# /etc/hosts 必须自己写：debootstrap 的 minbase 不生成它，
# 缺了会导致 hostname -f 解析不到 FQDN、sudo 报
# "unable to resolve host"、PVE 等依赖正反向解析的服务起不来。
cat > "$ROOT/etc/hosts" <<'HOSTS'
127.0.0.1       localhost.localdomain localhost
127.0.1.1       PADT00 oppoa3.pve
::1             localhost.localdomain localhost ip6-localhost ip6-loopback

ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
HOSTS
chmod 0644 "$ROOT/etc/hosts"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$ROOT/etc/ssh/sshd_config"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$ROOT/etc/ssh/sshd_config"

say "阶段 12：桌面会话与开机服务"
if [ "$VARIANT" = "phosh" ]; then
    in_root "systemctl disable gdm 2>/dev/null || true"
    # phosh.service 上游写死 User=1000 + TTYPath=/dev/tty7。
    # 桌面用 debian 用户（Wayland 不允许 root 跑桌面会话）。
    if [ -f "$ROOT/usr/lib/systemd/system/phosh.service" ]; then
        sed -i 's/^User=.*/User=debian/' "$ROOT/usr/lib/systemd/system/phosh.service"
        mkdir -p "$ROOT/etc/systemd/system"
        cp "$ROOT/usr/lib/systemd/system/phosh.service" \
           "$ROOT/etc/systemd/system/phosh.service"
    fi
    in_root "systemctl enable phosh.service 2>/dev/null || true"
    in_root "systemctl set-default graphical.target"

    # 关掉自动熄屏（技术债 D2：面板断电后触摸需要重新初始化）。
    # 注意目录可能不存在 —— dconf 只从这些路径读，必须自己建。
    mkdir -p "$ROOT/etc/dconf/db/local.d" "$ROOT/etc/dconf/profile"
    cat > "$ROOT/etc/dconf/profile/user" <<'EOF'
user-db:user
system-db:local
EOF
    cat > "$ROOT/etc/dconf/db/local.d/00-a3-idle" <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
idle-activation-enabled=false
EOF
    if in_root "command -v dconf >/dev/null 2>&1"; then
        in_root "dconf update" || warn "dconf update 失败，桌面启动后可用 gsettings 补设"
    else
        warn "镜像里没有 dconf 命令，跳过 dconf update"
    fi
else
    in_root "systemctl set-default multi-user.target"
fi

say "阶段 12.5：创建 /dev/block/by-name（Android 风格分区别名）"

# /dev/block/by-name 是 Android 的布局，主线内核 + udev 不会建它。
# 很多 Android 移植的脚本、刷机工具、fstab 都按这个名字找分区，
# 缺了会报 "No such file or directory"。
# 用 udev 规则从 PARTNAME 生成同样内容的软链。
mkdir -p "$ROOT/etc/udev/rules.d"
cat > "$ROOT/etc/udev/rules.d/60-a3-block-by-name.rules" <<'UDEV'
# 为每个有分区名的块设备创建 /dev/block/by-name/<PARTNAME>
SUBSYSTEM=="block", ENV{DEVTYPE}=="partition", ENV{PARTNAME}!="", \
  SYMLINK+="block/by-name/$env{PARTNAME}"
UDEV

# 开机时也重建一次，避免 udev 早于分区扫描
cat > "$ROOT/usr/local/sbin/a3-block-by-name" <<'SCRIPT'
#!/bin/sh
# 兜底：udev 偶尔不会给已有分区重新发事件，这里按 sysfs 补一遍。
mkdir -p /dev/block/by-name
for d in /sys/class/block/*; do
    [ -r "$d/partition" ] || continue
    name=$(cat "$d/uevent" 2>/dev/null | sed -n 's/^PARTNAME=//p')
    [ -n "$name" ] || continue
    dev=/dev/$(basename "$d")
    [ -e "$dev" ] || continue
    ln -sf "../../$(basename "$d")" "/dev/block/by-name/$name"
done
exit 0
SCRIPT
chmod 0755 "$ROOT/usr/local/sbin/a3-block-by-name"

cat > "$ROOT/etc/systemd/system/a3-block-by-name.service" <<'UNIT'
[Unit]
Description=Create /dev/block/by-name symlinks (Android layout)
DefaultDependencies=no
After=systemd-udev-settle.service local-fs.target
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/a3-block-by-name

[Install]
WantedBy=multi-user.target
UNIT
in_root "systemctl enable a3-block-by-name.service" || warn "a3-block-by-name 启用失败"

say "阶段 13：触摸固件（只放能驱动的设备）"
mkdir -p "$ROOT/lib/firmware/tp/17175"
if [ -d vendor/firmware ]; then
    cp -a vendor/firmware/. "$ROOT/lib/firmware/" 2>/dev/null || true
fi
if [ -f vendor/FW_NT36672A_JDI.bin ]; then
    cp vendor/FW_NT36672A_JDI.bin "$ROOT/lib/firmware/tp/17175/"
fi

say "阶段 14：一次性扩容服务"
cat > "$ROOT/etc/systemd/system/a3-growroot.service" <<'EOF'
[Unit]
Description=A3 grow root filesystem once
ConditionPathExists=/etc/a3-growroot.once
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "rm -f /etc/a3-growroot.once; i=0; while [ $i -lt 30 ]; do [ -b /dev/mmcblk0p44 ] && break; sleep 1; i=$((i+1)); done; exec resize2fs /dev/mmcblk0p44"

[Install]
WantedBy=multi-user.target
EOF
touch "$ROOT/etc/a3-growroot.once"
in_root "systemctl enable a3-growroot.service"

say "阶段 15：清理"
in_root "apt-get clean"
rm -rf "$ROOT/var/lib/apt/lists"/* "$ROOT/tmp"/* "$ROOT/var/tmp"/*
rm -f "$ROOT/usr/bin/qemu-aarch64-static"
for m in run dev/pts dev proc sys; do
    mountpoint -q "$ROOT/$m" 2>/dev/null && umount -lf "$ROOT/$m" 2>/dev/null || true
done

say "阶段 16：生成 ext4 镜像（$SIZE）"
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
mke2fs -t ext4 -F -d "$ROOT" -L a3-rootfs "$OUT"
e2fsck -f -y "$OUT" >/dev/null 2>&1 || true

say "完成：$OUT"
ls -lh "$OUT"
echo "变体：$VARIANT"