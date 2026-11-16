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
trap 'rm -rf "$ROOT"' EXIT

say() { printf "\n\033[1;32m== %s\033[0m\n" "$*"; }

say "阶段 1：解压基础系统（--foreign，不在 x86 上执行 arm64 代码）"
debootstrap --arch=arm64 --foreign --variant=minbase \
    --include=ca-certificates \
    "$RELEASE" "$ROOT" "$MIRROR"

say "阶段 2：放入 qemu 并在 chroot 里完成第二段"
install -m 0755 /usr/bin/qemu-aarch64-static "$ROOT/usr/bin/qemu-aarch64-static" 2>/dev/null || \
    install -m 0755 "$(command -v qemu-aarch64-static)" "$ROOT/usr/bin/qemu-aarch64-static"

cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
chroot "$ROOT" /debootstrap/debootstrap --second-stage

say "阶段 3：配置 apt 源"
cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $RELEASE main contrib non-free-firmware
deb $MIRROR ${RELEASE}-updates main contrib non-free-firmware
deb $SECMIRROR ${RELEASE}-security main contrib non-free-firmware
EOF

say "阶段 4：安装基础软件包"
PKGS="systemd systemd-sysv udev kmod iproute2 iputils-ping net-tools \
      openssh-server sudo less vim-tiny procps rsync \
      util-linux mount e2fsprogs dosfstools \
      libpam-systemd dbus"

chroot "$ROOT" /bin/sh -c "export DEBIAN_FRONTEND=noninteractive; apt-get update"
chroot "$ROOT" /bin/sh -c "export DEBIAN_FRONTEND=noninteractive; apt-get install -y --no-install-recommends $PKGS"

if [ "$VARIANT" = "phosh" ]; then
    say "阶段 5：安装 phosh 手机桌面"
    chroot "$ROOT" /bin/sh -c "export DEBIAN_FRONTEND=noninteractive; \
        apt-get install -y --no-install-recommends \
        phosh squeekboard phosh-mobile-settings kbd \
        fonts-noto-cjk fonts-noto-cjk-extra \
        gnome-settings-daemon upower"
fi

say "阶段 6：创建用户与权限"
chroot "$ROOT" /bin/sh -c "
    set -e
    id -u kesry >/dev/null 2>&1 || useradd -m -s /bin/bash -G video,render,input,audio,sudo kesry
    echo 'kesry:kesry' | chpasswd
    passwd -d root 2>/dev/null || true
"
# 允许 sudo 免密，方便调试
echo 'kesry ALL=(ALL) NOPASSWD:ALL' > "$ROOT/etc/sudoers.d/kesry"
chmod 0440 "$ROOT/etc/sudoers.d/kesry"

say "阶段 7：网络（USB RNDIS usb0）"
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
chroot "$ROOT" /bin/sh -c "systemctl enable systemd-networkd"

say "阶段 8：SSH 与主机名"
chroot "$ROOT" /bin/sh -c "
    systemctl enable ssh
    echo PADT00 > /etc/hostname
    echo 'root/kesry 用密码登录（调试用，发布前应改成密钥）' >/dev/null
"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$ROOT/etc/ssh/sshd_config"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$ROOT/etc/ssh/sshd_config"

say "阶段 9：桌面会话与开机服务"
if [ "$VARIANT" = "phosh" ]; then
    chroot "$ROOT" /bin/sh -c "
        systemctl disable gdm 2>/dev/null || true
        systemctl enable phosh.service 2>/dev/null || true
        systemctl set-default graphical.target
    "
    # 关掉自动熄屏（技术债 D2：面板断电后触摸需要重新初始化）
    mkdir -p "$ROOT/home/kesry/.config/dconf"
    cat > "$ROOT/etc/dconf/db/local.d/00-a3-idle" <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 0
[org/gnome/desktop/screensaver]
idle-activation-enabled=false
EOF
    chroot "$ROOT" /bin/sh -c "command -v dconf >/dev/null && dconf update || true"
else
    chroot "$ROOT" /bin/sh -c "systemctl set-default multi-user.target"
fi

say "阶段 10：触摸固件（只放能驱动的设备）"
mkdir -p "$ROOT/lib/firmware/tp/17175"
if [ -d vendor/firmware ]; then
    cp -a vendor/firmware/. "$ROOT/lib/firmware/" 2>/dev/null || true
fi
if [ -f vendor/FW_NT36672A_JDI.bin ]; then
    cp vendor/FW_NT36672A_JDI.bin "$ROOT/lib/firmware/tp/17175/"
fi

say "阶段 11：一次性扩容服务"
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
chroot "$ROOT" /bin/sh -c "systemctl enable a3-growroot.service"

say "阶段 12：清理"
chroot "$ROOT" /bin/sh -c "apt-get clean; rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*"
rm -f "$ROOT/usr/bin/qemu-aarch64-static"

say "阶段 13：生成 ext4 镜像（$SIZE）"
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
mke2fs -t ext4 -F -d "$ROOT" -L a3-rootfs "$OUT"
e2fsck -f -y "$OUT" >/dev/null 2>&1 || true

say "完成：$OUT"
ls -lh "$OUT"
echo "变体：$VARIANT"
