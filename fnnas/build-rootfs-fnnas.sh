#!/bin/bash
# build-rootfs-fnnas.sh — 构建 OPPO A3 的飞牛 FnNAS rootfs 镜像
#
# 与 script/build-rootfs.sh（Debian rootfs）完全独立，不要混用：
#   build-rootfs.sh        → debootstrap 出来的 Debian 13 最小/桌面 rootfs
#   build-rootfs-fnnas.sh  → 从飞牛官方 ARM ISO 的 trimfs.tgz 提取的飞牛 rootfs
#
# 本脚本做六件事：
#   1. 从 trimfs.tgz 解出飞牛 rootfs
#   2. 注入 LD 拦截库（nodri/nodmaheap，软解媒体服务需要）
#   3. 注入 USB gadget（RNDIS 网络 + ACM 串口）—— 非 UEFI 设备必须自己建
#   4. 替换 mediasrv 为软解版（飞牛原版依赖 RK MPP，MT6771 上必崩）
#   5. 注入主线内核兼容补丁（mdadm lockless / mount trimacl / 固定 DNS）
#   6. 打包成 ext4 镜像（用 loop 挂载 + 限速解压，避免构建机 OOM）
#
# 前置条件：
#   - 构建机有 7z（p7zip-full）、parted/e2fsprogs、aarch64 交叉编译器
#   - 已下载：飞牛 ARM ISO、kesry/trimmedia-linux-arm 的 trim-media-lib.zip
#   - 内核已开 CONFIG_EFI/DMI/PCI（见 fnnas/README.md）
#
# 用法：
#   bash build-rootfs-fnnas.sh \
#       /path/to/fnos_arm.iso \
#       /path/to/trim-media-lib.zip
#   产物：out/fnnas-rootfs.img

set -e

ISO="${1:?用法: $0 <fnos-arm.iso> <trim-media-lib.zip> [输出镜像大小G]}"
TRIMLIB="${2:?需要 trim-media-lib.zip}"
IMG_SIZE_G="${3:-16}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/opt/oppoa3/wv/fnnas-build}"
OUT="${OUT:-/opt/oppoa3/out}"

# 飞牛系统的关键 PARTUUID（userdata 分区，见 docs/partition-userdata-split.md）
ROOT_PARTUUID="6fce83a6-5273-4748-1145-c205ebb4b8ad"

# RNDIS/ACM 固定 MAC（Windows 侧驱动已按这个配过）
RNDIS_DEV_MAC="02:00:a3:00:00:02"
RNDIS_HOST_MAC="02:00:a3:00:00:01"

say() { echo "$*"; }

# ------------------------------------------------------------
# 1. 解出飞牛 rootfs
# ------------------------------------------------------------
say "=== 1/5 从 ISO 提取并解包 trimfs.tgz ==="
mkdir -p "$WORK" "$OUT"
if [ ! -f "$WORK/trimfs.tgz" ]; then
    7z e -y -o"$WORK" "$ISO" "trimfs.tgz"
fi
ROOT="$WORK/rootfs"
if [ ! -f "$ROOT/etc/fstab" ]; then
    rm -rf "$ROOT" && mkdir -p "$ROOT"
    # 限速 + 清缓存，避免构建机大文件写入 OOM
    CLEANER_PID=""
    ( while true; do sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; sleep 2; done ) &
    CLEANER_PID=$!
    sysctl -w vm.dirty_ratio=5 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=1 >/dev/null 2>&1 || true
    pv -L 15m < "$WORK/trimfs.tgz" 2>/dev/null | tar xzf - -C "$ROOT" || \
        tar xzf "$WORK/trimfs.tgz" -C "$ROOT"
    kill "$CLEANER_PID" 2>/dev/null || true
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1 || true
    sysctl -w vm.dirty_background_ratio=10 >/dev/null 2>&1 || true
fi
say "  rootfs: $(du -sh "$ROOT" | cut -f1)"

# ------------------------------------------------------------
# 2. 编译并安装 LD 拦截库
# ------------------------------------------------------------
say "=== 2/5 编译 LD_PRELOAD 拦截库 ==="
( cd "$SCRIPT_DIR/ld-hooks" && bash build-hooks.sh )
mkdir -p "$ROOT/opt/fnnas/hook"
install -m 0755 "$SCRIPT_DIR/ld-hooks/nodri.so"     "$ROOT/opt/fnnas/hook/"
install -m 0755 "$SCRIPT_DIR/ld-hooks/nodmaheap.so" "$ROOT/opt/fnnas/hook/"
# fakecompat 可选，默认也放进去但不注入（见 README）
install -m 0755 "$SCRIPT_DIR/ld-hooks/fakecompat.so" "$ROOT/opt/fnnas/hook/" 2>/dev/null || true
say "  hook 库已安装到 /opt/fnnas/hook/"

# ------------------------------------------------------------
# 3. 注入 USB gadget（RNDIS 网络 + ACM 串口）
# ------------------------------------------------------------
say "=== 3/5 注入 USB gadget (RNDIS + ACM) ==="
mkdir -p "$ROOT/usr/local/sbin"
install -m 0755 "$SCRIPT_DIR/a3-gadget" "$ROOT/usr/local/sbin/a3-gadget"

cat > "$ROOT/etc/systemd/system/a3-gadget.service" <<'UNIT'
[Unit]
Description=A3 USB gadget (RNDIS network + ACM serial)
DefaultDependencies=no
After=sys-kernel-config.mount
Wants=sys-kernel-config.mount
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/a3-gadget

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/a3-gadget.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/a3-gadget.service"

# 网络配置（systemd-networkd）
mkdir -p "$ROOT/etc/systemd/network"
cat > "$ROOT/etc/systemd/network/10-usb0.network" <<NET
[Match]
Name=usb0

[Network]
Address=10.42.1.2/24
Gateway=10.42.1.1
DNS=223.5.5.5
DNS=8.8.8.8
NET
ln -sf /usr/lib/systemd/system/systemd-networkd.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" 2>/dev/null || true

# 串口 getty（ACM）
mkdir -p "$ROOT/etc/systemd/system/getty.target.wants"
ln -sf /usr/lib/systemd/system/serial-getty@.service \
    "$ROOT/etc/systemd/system/getty.target.wants/serial-getty@ttyGS0.service" 2>/dev/null || true
say "  RNDIS+ACM gadget、网络、getty 已配置"

# ------------------------------------------------------------
# 4. 替换 mediasrv 为软解版
# ------------------------------------------------------------
say "=== 4/5 安装软解媒体服务 ==="
TIMEDIA="$WORK/trimmedia"
if [ ! -x "$TIMEDIA/bin/mediasrv" ]; then
    rm -rf "$TIMEDIA" && mkdir -p "$TIMEDIA"
    7z x -y -o"$TIMEDIA" "$TRIMLIB" >/dev/null
fi
mkdir -p "$ROOT/opt/trimmedia"
cp -a "$TIMEDIA"/. "$ROOT/opt/trimmedia/"
chmod +x "$ROOT/opt/trimmedia/bin/mediasrv"

# systemd drop-in：不改动原版二进制，可回退（删掉 override.conf 即可）
mkdir -p "$ROOT/etc/systemd/system/mediasrv.service.d"
cat > "$ROOT/etc/systemd/system/mediasrv.service.d/override.conf" <<'UNIT'
[Service]
ExecStart=
ExecStart=/opt/trimmedia/bin/mediasrv -o /usr/trim/logs/mediasrv.log -a /var/run/trim_media.sock
ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5; do [ -S /var/run/trim_media.sock ] && break; sleep 1; done; setfacl -m u:www-data:rw /var/run/trim_media.sock 2>/dev/null || chmod 666 /var/run/trim_media.sock'
Environment=LD_LIBRARY_PATH=/opt/trimmedia/lib/mediasrv/lib:/opt/trimmedia/lib:/usr/trim/lib/mediasrv/lib:/usr/lib/aarch64-linux-gnu
Environment=PATH=/opt/trimmedia/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
UNIT
say "  软解 mediasrv 已安装，socket ACL drop-in 已配置"

# ------------------------------------------------------------
# 5. 注入主线内核兼容补丁（绕开飞牛私有内核特性）
# ------------------------------------------------------------
say "=== 5/6 注入主线内核兼容补丁 ==="

# --- 5.1 mdadm wrapper: --bitmap=lockless -> --bitmap=internal ---
# lockless write-intent bitmap 是飞牛私有内核补丁（ll_bitmap sysfs 属性），
# 上游主线 6.12/6.14/master 均无此实现。飞牛硬编码传该参数，
# mdadm 4.6 会调 sysfs_set_llbitmap() 失败 -> 阵列建不起来。
# internal bitmap 在单盘 RAID1 上功能等效。
mkdir -p "$ROOT/usr/local/sbin"
cat > "$ROOT/usr/local/sbin/mdadm-a3-wrapper" <<'MDADM_WRAPPER'
#!/bin/sh
REAL=/usr/sbin/mdadm.real
[ ! -x "$REAL" ] && { echo "mdadm wrapper: $REAL not found" >&2; exit 127; }
[ $# -eq 0 ] && exec "$REAL"
n=$#
i=1
while [ $i -le $n ]; do
    eval "arg=\${$i}"
    case "$arg" in
        --bitmap=lockless) set -- "$@" --bitmap=internal ;;
        *) set -- "$@" "$arg" ;;
    esac
    i=$((i + 1))
done
shift $n
exec "$REAL" "$@"
MDADM_WRAPPER
chmod 755 "$ROOT/usr/local/sbin/mdadm-a3-wrapper"

# 开机把它装成 /usr/sbin/mdadm（系统更新会覆盖，所以每次启动都重装）
cat > "$ROOT/usr/local/sbin/a3-fnnas-fixes" <<'FIXES'
#!/bin/sh
# 主线内核兼容修复：每次启动重新应用，防止被系统更新覆盖

# 1. mdadm wrapper
if [ -x /usr/sbin/mdadm ] && ! head -1 /usr/sbin/mdadm 2>/dev/null | grep -q '^#!'; then
    cp -f /usr/sbin/mdadm /usr/sbin/mdadm.real
    cp -f /usr/local/sbin/mdadm-a3-wrapper /usr/sbin/mdadm
    chmod 755 /usr/sbin/mdadm /usr/sbin/mdadm.real
fi

# 2. mount wrapper：过滤飞牛私有的 trimacl 参数
#    trimacl 是飞牛 CONFIG_FS_TRIM_ACL 私有补丁，主线内核不认，会拒绝挂载
if [ ! -e /usr/bin/mount.orig ]; then
    mv /usr/bin/mount /usr/bin/mount.orig
    cat > /usr/bin/mount <<'MW'
#!/bin/bash
ARGS=()
while (($#)); do
    if [[ "$1" == "-o" && $# -ge 2 ]]; then
        options="$2"; shift 2
        filtered=()
        IFS=',' read -ra items <<< "$options"
        for item in "${items[@]}"; do
            [[ "$item" != "trimacl" ]] && filtered+=("$item")
        done
        ((${#filtered[@]})) && ARGS+=("-o" "$(IFS=,; echo "${filtered[*]}")")
    else
        ARGS+=("$1"); shift
    fi
done
exec /usr/bin/mount.orig "${ARGS[@]}"
MW
    chmod 755 /usr/bin/mount
fi

# 3. 固定 DNS（空 resolv.conf 会让 pgbouncer evdns_base_new 失败并 SEGV）
if ! grep -q '^nameserver' /etc/resolv.conf 2>/dev/null; then
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf <<'DNS'
nameserver 223.5.5.5
nameserver 8.8.8.8
nameserver 10.42.1.1
DNS
    chmod 644 /etc/resolv.conf
fi
exit 0
FIXES
chmod 755 "$ROOT/usr/local/sbin/a3-fnnas-fixes"

cat > "$ROOT/etc/systemd/system/a3-fnnas-fixes.service" <<'UNIT'
[Unit]
Description=A3 fnNAS mainline-kernel compatibility fixes
DefaultDependencies=no
After=local-fs.target
Before=postgresql.service pgbouncer.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/a3-fnnas-fixes

[Install]
WantedBy=multi-user.target
UNIT
mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/a3-fnnas-fixes.service \
    "$ROOT/etc/systemd/system/multi-user.target.wants/a3-fnnas-fixes.service"

# --- 5.4 固定 DNS + 禁止 NetworkManager 覆盖 ---
rm -f "$ROOT/etc/resolv.conf"
cat > "$ROOT/etc/resolv.conf" <<'DNS'
nameserver 223.5.5.5
nameserver 8.8.8.8
nameserver 10.42.1.1
DNS
chmod 644 "$ROOT/etc/resolv.conf"
mkdir -p "$ROOT/etc/NetworkManager/conf.d"
cat > "$ROOT/etc/NetworkManager/conf.d/99-no-dns.conf" <<'NMCONF'
[main]
dns=none
NMCONF
say "  mdadm/mount wrapper、DNS 固定、启动自修复服务 已注入"

# ------------------------------------------------------------
# 6. 改 fstab + 打包 ext4 镜像
# ------------------------------------------------------------
say "=== 6/6 配置 fstab 并打包镜像 ==="
# 根分区用 PARTUUID；data 分区绝不写进 fstab（留给飞牛 WebUI 初始化成存储池）
cat > "$ROOT/etc/fstab" <<EOF
# OPPO A3 主线内核 + 飞牛 rootfs
PARTUUID=${ROOT_PARTUUID}  /  ext4  errors=remount-ro  0  1
tmpfs  /tmp  tmpfs  defaults,nosuid  0  0
EOF

echo PADT00 > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<'EOF'
127.0.0.1       localhost.localdomain localhost
127.0.1.1       PADT00 oppoa3.pve
::1             localhost.localdomain localhost ip6-localhost ip6-loopback
EOF

IMG="$OUT/fnnas-rootfs.img"
BLOCKS=$((IMG_SIZE_G * 1024 * 1024))   # 4K 块数
rm -f "$IMG"

# 低内存打包：mkfs 空镜像 → loop 挂载 → 限速 tar 拷贝 → 卸载
truncate -s "${IMG_SIZE_G}G" "$IMG"
mkfs.ext4 -q -F -L fnos-root "$IMG"

MNT="$WORK/mnt"
mkdir -p "$MNT"
umount "$MNT" 2>/dev/null || true
LOOP=$(losetup -f)
losetup "$LOOP" "$IMG"
mount -t ext4 "$LOOP" "$MNT"

CLEANER_PID=""
( while true; do sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null; sleep 2; done ) &
CLEANER_PID=$!
tar -C "$ROOT" -cf - . | pv -L 15m 2>/dev/null | tar -C "$MNT" -xf - || \
    tar -C "$ROOT" -cf - . | tar -C "$MNT" -xf -
kill "$CLEANER_PID" 2>/dev/null || true
sync
umount "$MNT"
losetup -d "$LOOP"
e2fsck -fy "$IMG" >/dev/null 2>&1 || true

say "=== 完成 ==="
ls -lh "$IMG"
md5sum "$IMG"
