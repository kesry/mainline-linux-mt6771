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
      libpam-systemd dbus"

in_root "apt-get update"
in_root "apt-get install -y --no-install-recommends $PKGS"

if [ "$VARIANT" = "phosh" ]; then
    say "阶段 6：安装 phosh 手机桌面"
    in_root "apt-get install -y --no-install-recommends \
        phosh squeekboard phosh-mobile-settings kbd dconf-cli \
        fonts-noto-cjk fonts-noto-cjk-extra \
        gnome-settings-daemon upower"
fi

say "阶段 7：创建用户与权限"
in_root "id -u kesry >/dev/null 2>&1 || useradd -m -s /bin/bash -G video,render,input,audio,sudo kesry"
in_root "echo 'kesry:kesry' | chpasswd"
in_root "passwd -d root 2>/dev/null || true"
mkdir -p "$ROOT/etc/sudoers.d"
echo 'kesry ALL=(ALL) NOPASSWD:ALL' > "$ROOT/etc/sudoers.d/kesry"
chmod 0440 "$ROOT/etc/sudoers.d/kesry"

say "阶段 8：网络（USB RNDIS usb0）"
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

say "阶段 9：SSH 与主机名"
in_root "systemctl enable ssh"
echo PADT00 > "$ROOT/etc/hostname"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' "$ROOT/etc/ssh/sshd_config"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$ROOT/etc/ssh/sshd_config"

say "阶段 10：桌面会话与开机服务"
if [ "$VARIANT" = "phosh" ]; then
    in_root "systemctl disable gdm 2>/dev/null || true"
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

say "阶段 11：触摸固件（只放能驱动的设备）"
mkdir -p "$ROOT/lib/firmware/tp/17175"
if [ -d vendor/firmware ]; then
    cp -a vendor/firmware/. "$ROOT/lib/firmware/" 2>/dev/null || true
fi
if [ -f vendor/FW_NT36672A_JDI.bin ]; then
    cp vendor/FW_NT36672A_JDI.bin "$ROOT/lib/firmware/tp/17175/"
fi

say "阶段 12：一次性扩容服务"
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

say "阶段 13：清理"
in_root "apt-get clean"
rm -rf "$ROOT/var/lib/apt/lists"/* "$ROOT/tmp"/* "$ROOT/var/tmp"/*
rm -f "$ROOT/usr/bin/qemu-aarch64-static"
for m in run dev/pts dev proc sys; do
    mountpoint -q "$ROOT/$m" 2>/dev/null && umount -lf "$ROOT/$m" 2>/dev/null || true
done

say "阶段 14：生成 ext4 镜像（$SIZE）"
rm -f "$OUT"
truncate -s "$SIZE" "$OUT"
mke2fs -t ext4 -F -d "$ROOT" -L a3-rootfs "$OUT"
e2fsck -f -y "$OUT" >/dev/null 2>&1 || true

say "完成：$OUT"
ls -lh "$OUT"
echo "变体：$VARIANT"