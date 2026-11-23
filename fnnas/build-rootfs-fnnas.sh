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
#   4. 强制 mediasrv 为软解版（飞牛原版依赖 RK MPP，MT6771 上必崩）
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

# 飞牛构建素材统一从 GitHub source release 下载（CI / 本地一致）：
#   https://github.com/kesry/mainline-linux-mt6771/releases/download/source/
# 参数仍可显式覆盖（本地已有文件时传本地路径即可）。
SOURCE_BASE="https://github.com/kesry/mainline-linux-mt6771/releases/download/source"
TRIMFS_URL="${TRIMFS_URL:-$SOURCE_BASE/trimfs.tgz}"
# TRIMLIB_URL="${TRIMLIB_URL:-$SOURCE_BASE/trim-media-lib.zip}"

ISO="${1:-}"          # 兼容旧参数：本地 ISO（保留为空则从 URL 下载 trimfs.tgz）
# TRIMLIB="${2:-}"      # 兼容旧参数：本地 trim-media-lib.zip
IMG_SIZE_G="${3:-8}"
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
say "=== 1/5 获取并解包 trimfs.tgz ==="
mkdir -p "$WORK" "$OUT"
if [ -n "$ISO" ] && [ -f "$ISO" ]; then
    # 旧用法：从本地 ISO 提取
    if [ ! -f "$WORK/trimfs.tgz" ]; then
        7z e -y -o"$WORK" "$ISO" "trimfs.tgz"
    fi
elif [ ! -f "$WORK/trimfs.tgz" ]; then
    # 新用法：从 GitHub source release 下载（1.9GB，易中断，带校验重试）
    say "  下载 $TRIMFS_URL"
    for attempt in 1 2 3; do
        say "  下载尝试 $attempt/3"
        rm -f "$WORK/trimfs.tgz"
        # -C - 断点续传；--retry 内部也重试；长超时防大文件中断
        curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 \
             --max-time 900 -o "$WORK/trimfs.tgz" "$TRIMFS_URL" && \
            gzip -t "$WORK/trimfs.tgz" 2>/dev/null && break
        say "  下载不完整或校验失败，重试..."
    done
fi
[ -f "$WORK/trimfs.tgz" ] || { echo "trimfs.tgz 获取失败" >&2; exit 1; }
gzip -t "$WORK/trimfs.tgz" 2>/dev/null || { echo "trimfs.tgz 校验失败" >&2; exit 1; }

# trim-media-lib.zip（软解媒体服务）：未传本地文件时也从 release 下载
# mediasrv依赖在飞牛上存在
# if [ -z "$TRIMLIB" ] || [ ! -f "$TRIMLIB" ]; then
#     TRIMLIB="$WORK/trim-media-lib.zip"
#     if [ ! -f "$TRIMLIB" ]; then
#         say "  下载 $TRIMLIB_URL"
#         curl -fsSL --retry 3 -o "$TRIMLIB" "$TRIMLIB_URL"
#     fi
# fi
ROOT="$WORK/rootfs"
if [ ! -f "$ROOT/etc/fstab" ]; then
    rm -rf "$ROOT" && mkdir -p "$ROOT"
    # 直接解压（不再用 pv 限速管道，它在 CI 上会报 gzip unexpected EOF 且慢）
    # tgz 已通过 gzip -t 校验，直接 tar 解压即可。
    tar xzf "$WORK/trimfs.tgz" -C "$ROOT"
    [ -f "$ROOT/etc/fstab" ] || { echo "rootfs 解压不完整（缺 etc/fstab）" >&2; exit 1; }
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
install -m 0755 "$SCRIPT_DIR/ld-hooks/fakecompat.so" "$ROOT/opt/fnnas/hook/"

# --- 2.1 飞牛私有 syscall 兼容 hook（伪 dirfd faccessat）---
# 飞牛 libnperm 用 faccessat(-21586, struct_ptr, R/W_OK, 0) 做权限判定：
#   飞牛内核会解引用 struct 取真实路径；主线内核把 struct 当路径 -> EBADF,
#   后果是音乐/影视授权报"所选文件夹无写入权限"。
# 本 hook 在用户态解引用 struct 并转为标准 AT_FDCWD 调用，已在实机验证有效。
install -m 0755 "$SCRIPT_DIR/ld-hooks/fnacl_faccessat_hook.so" \
    "$ROOT/opt/fnnas/fnacl_faccessat_hook.so"

# 给需要 libnperm 的飞牛服务注入 LD_PRELOAD（开机生效）。
#
# 注意：drop-in 目录名必须和服务 unit 名一致，不能用二进制名（历史 bug）：
#   trim      -> trim_main.service     （filemanager 由 trim exec，继承环境）
#   uploadsrv -> trim_upload.service   （is_vol_path_writeable 在这里）
# filemanager 自身不单独配，它由 trim_main exec 继承。
# --- 4.x sshfs 默认 umask（远程挂载复制后目录 0 权限）---
# 飞牛 mountmgr 调 sshfs 不指定权限选项，远端条目常返回 mode 000；
# 飞牛复制/移动会原样保留该 mode → 复制出来的目录 0 权限，点进去报"没有权限"。
# sshfs 3.7.3 只支持 -o umask=M（没有 file_mode/dir_mode，写了会报
# "unknown option(s)" 直接挂载失败）。umask=022 → 目录 755、文件 644。
cat > "$ROOT/usr/bin/sshfs.new" <<'SSHFSWRAP'
#!/bin/bash
ARGS=(); HAS_UMASK=0
for a in "$@"; do
    case "$a" in
        *umask*) HAS_UMASK=1 ;;
    esac
    ARGS+=("$a")
done
EXTRA=()
[ "$HAS_UMASK" = 0 ] && EXTRA+=("-o" "umask=022")
exec /usr/bin/sshfs.real "${EXTRA[@]}" "${ARGS[@]}"
SSHFSWRAP
if [ -f "$ROOT/usr/bin/sshfs" ]; then
    if [ ! -e "$ROOT/usr/bin/sshfs.real" ]; then
        cp -a "$ROOT/usr/bin/sshfs" "$ROOT/usr/bin/sshfs.real"
    fi
    chmod 755 "$ROOT/usr/bin/sshfs.new"
    mv -f "$ROOT/usr/bin/sshfs.new" "$ROOT/usr/bin/sshfs"
fi

cat > "$ROOT/usr/local/sbin/a3-fnperm-hook-setup" <<'FNPERM'
#!/bin/sh
# 为依赖 libnperm 伪 dirfd 的飞牛服务生成 LD_PRELOAD drop-in
HOOK=/opt/fnnas/fnacl_faccessat_hook.so
[ -f "$HOOK" ] || exit 0
# 需要 libnperm 伪 dirfd 兼容的飞牛服务（unit:二进制）
# 覆盖：授权检查(open_gateway/app_center)、上传(is_vol_path_writeable)、
#       文件管理器(filemanager 由 trim_main 继承)、存储/共享等
for pair in \
    "trim_main:trim" \
    "trim_upload:uploadsrv" \
    "trim_open_gateway:trim_open_gateway" \
    "trim_app_center:trim_app_center" \
    "filestor_service:filestor_service" \
    "finder_service:finder_service" \
    "sysinfo_service:sysinfo_service" \
    "share_service:share_service" \
    "backup_service:backup_service" \
    "dlcenter:dlcenter" \
    "imagesrv:imagesrv" \
    "multiple-downloads:multiple-downloads" \
    "trim_sharelink:trim-sharelink" \
    "webdav:webdav" ; do
    unit=${pair%%:*}
    bin=${pair##*:}
    [ -x "/usr/trim/bin/$bin" ] || continue
    d="/etc/systemd/system/${unit}.service.d"
    mkdir -p "$d"
    printf '[Service]\nEnvironment="LD_PRELOAD=%s"\n' "$HOOK" > "$d/a3-fnacl.conf"
done

# 生成本机可用的 trim.key.enc（否则 uploadsrv 报 Invalid trim-key 并退出）
python3 /usr/local/sbin/a3-trim-keygen 2>/dev/null || true
FNPERM
chmod 755 "$ROOT/usr/local/sbin/a3-fnperm-hook-setup"

# --- 5.x trim.key.enc 生成 ---
# 飞牛用 master_key = HMAC-SHA256(SMBIOS UUID 字符串, /etc/machine-id 前32字节)
# 加密 256 字节随机 trim_key，AES-GCM 存成 IV(12)+CT(256)+TAG(16)=284 字节。
# 主线内核在 MT6771 上没有 SMBIOS，get_smbios_uuid() 回退常量
#   "00000000-0000-0000-0000-000000000000"
# 于是 rootfs 里带的 key 必然解不开，必须在目标机上重算一次。
cat > "$ROOT/usr/local/sbin/a3-trim-keygen" <<'KEYGEN'
#!/usr/bin/env python3
import hashlib, hmac, os, sys
try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except Exception:
    sys.exit(0)

KEYFILE = "/usr/trim/etc/trim.key.enc"
UUID = b"00000000-0000-0000-0000-000000000000"

try:
    mid = open("/etc/machine-id", "rb").read(32)
except Exception:
    sys.exit(0)
if len(mid) < 32:
    sys.exit(0)

master = hmac.new(UUID, mid, hashlib.sha256).digest()

# 已有 key 能解开就保留（避免每次重启换 key 导致令牌失效）
if os.path.exists(KEYFILE):
    try:
        blob = open(KEYFILE, "rb").read()
        if len(blob) == 284:
            AESGCM(master).decrypt(blob[:12], blob[12:], None)
            sys.exit(0)
    except Exception:
        pass

trim_key = os.urandom(256)
iv = os.urandom(12)
blob = iv + AESGCM(master).encrypt(iv, trim_key, None)
os.makedirs(os.path.dirname(KEYFILE), exist_ok=True)
with open(KEYFILE, "wb") as f:
    f.write(blob)
os.chmod(KEYFILE, 0o600)
KEYGEN
chmod 755 "$ROOT/usr/local/sbin/a3-trim-keygen"

# --- 5.x trim_acl_shim.ko（飞牛私有 system.trim_acl xattr + /dev/trim-trashbin）---
# 关键：ko 的 vermagic 必须匹配 boot.img 内核。CI 用同一次编译的干净内核树
# 编出 ko，通过 TRIM_ACL_KO 环境变量传入；本地构建可不传（保持兼容）。
if [ -n "${TRIM_ACL_KO:-}" ] && [ -f "$TRIM_ACL_KO" ]; then
    say "  注入 trim_acl_shim.ko ($TRIM_ACL_KO)"
    mkdir -p "$ROOT/opt/fnnas"
    install -m 0644 "$TRIM_ACL_KO" "$ROOT/opt/fnnas/trim_acl_shim.ko"
    mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"
    cat > "$ROOT/etc/systemd/system/a3-trimacl-shim.service" <<'TRIMUNIT'
[Unit]
Description=A3 trim_acl_shim + trim.key self-heal (fnOS on mainline kernel)
After=local-fs.target
Before=trim_main.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/local/sbin/a3-trim-keygen
ExecStart=/sbin/insmod /opt/fnnas/trim_acl_shim.ko mounts=/vol1
ExecStop=/sbin/rmmod trim_acl_shim
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
TRIMUNIT
    ln -sf /etc/systemd/system/a3-trimacl-shim.service \
        "$ROOT/etc/systemd/system/multi-user.target.wants/a3-trimacl-shim.service"
    say "  a3-trimacl-shim.service 已启用"
else
    echo "  提示: 未注入 trim_acl_shim.ko（TRIM_ACL_KO 未设置）；授权功能需另装 ko" >&2
fi

# --- 5.y mediasrv socket 权限 ---
# 重要：mediasrv 与 trim-media（影视 app）必须各用各的 socket，不能互相软链：
#   /var/run/mediasrv.socket  <- 软解 mediasrv（音乐 media.* API + 转码，返回 JSON）
#   /var/run/trim_media.sock  <- 飞牛影视 app（nginx /v 反向代理，返回 HTML/媒体）
# 之前把 mediasrv.socket 软链到 trim_media.sock，导致音乐连到影视 app 拿到 HTML，
# 报 "invalid character '<'" 扫不了码。已改为各自独立。
# mkdir -p "$ROOT/etc/systemd/system/mediasrv.service.d"
# cat > "$ROOT/etc/systemd/system/mediasrv.service.d/a3-socket-alias.conf" <<'MSALIAS'
# [Service]
# ExecStartPost=/bin/sh -c 'for i in 1 2 3 4 5; do [ -S /var/run/mediasrv.socket ] && break; sleep 1; done; chmod 666 /var/run/mediasrv.socket 2>/dev/null || true'
# MSALIAS



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

# --- 可选：RNDIS -> ECM 自动切换（由 A3_USBNET_AUTO_ECM=1 开启）---
# 默认不打；需要设备放到只认 CDC-ECM 的 NAS 时，构建时设 A3_USBNET_AUTO_ECM=1
if [ "${A3_USBNET_AUTO_ECM:-0}" = "1" ]; then
    say "  注入自动切 ECM（A3_USBNET_AUTO_ECM=1）"
    bash "$SCRIPT_DIR/../script/a3-usbnet-install.sh" \
        "$ROOT" "$SCRIPT_DIR/../script" "a3-gadget"
fi

# ------------------------------------------------------------
# 4. 强制 mediasrv 软解
# ------------------------------------------------------------
say "=== 4/5 强制 mediasrv 软解 ==="
# TIMEDIA="$WORK/trimmedia"
# if [ ! -x "$TIMEDIA/bin/mediasrv" ]; then
#     rm -rf "$TIMEDIA" && mkdir -p "$TIMEDIA"
#     7z x -y -o"$TIMEDIA" "$TRIMLIB" >/dev/null
# fi
mkdir -p "$ROOT/opt/trimmedia"
# cp -a "$TIMEDIA"/. "$ROOT/opt/trimmedia/"
# chmod +x "$ROOT/opt/trimmedia/bin/mediasrv"

# 
mkdir -p "$ROOT/etc/systemd/system/mediasrv.service.d"
cat > "$ROOT/etc/systemd/system/mediasrv.service.d/override.conf" <<'UNIT'
[Service]
Type=simple
ExecStart=/usr/trim/bin/mediasrv -o /usr/trim/logs/mediasrv.log -a /var/run/mediasrv.socket
Environment=LD_LIBRARY_PATH=/usr/trim/lib/mediasrv/lib:/usr/trim/lib
Restart=always
RestartSec=5
Environment=LD_PRELOAD=/opt/fnnas/hook/nodri.so:/opt/fnnas/hook/nodmaheap.so:/opt/fnnas/hook/fakecompat.so
UNIT
say "  强制 mediasrv 软件依赖已安装（LD_PRELOAD 三件套 hook 已写进启动 unit），socket ACL drop-in 已配置"

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

# 把这个 setup 挂到已有的 a3-fnnas-fixes.service 里（它在 early boot 跑）
# 在 fixes 脚本开头增加调用（幂等）
python3 - "$ROOT/usr/local/sbin/a3-fnnas-fixes" <<'PY2'
import sys
p=sys.argv[1]
s=open(p).read()
line='/usr/local/sbin/a3-fnperm-hook-setup 2>/dev/null || true'
if line not in s:
    marker='# 1. mdadm wrapper'
    s=s.replace(marker, line+'\\n'+marker, 1)
    open(p,'w').write(s)
PY2


cat > "$ROOT/etc/systemd/system/a3-fnnas-fixes.service" <<'UNIT'
[Unit]
Description=A3 fnNAS mainline-kernel compatibility fixes
DefaultDependencies=no
After=local-fs.target
Before=postgresql.service pgbouncer.service trim_main.service filestor_service.service trim_app_center.service

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

# 打包 ext4：用 mke2fs -d 直接从目录生成，无需 loop 设备
# （GitHub Actions runner 不允许 losetup：Permission denied）
truncate -s "${IMG_SIZE_G}G" "$IMG"
mke2fs -q -t ext4 -F -d "$ROOT" -L fnos-root "$IMG"
e2fsck -fy "$IMG" >/dev/null 2>&1 || true

# 生成 fastboot 可写的 sparse image（simg）
# fastboot flash userdata 只接受 sparse 镜像；原始 img 保留供校验/再加工。
SIMG="${IMG%.img}.simg"
if command -v img2simg >/dev/null 2>&1; then
    say "=== 生成 simg（fastboot 可写）==="
    rm -f "$SIMG"
    img2simg "$IMG" "$SIMG"
    ls -lh "$SIMG"
    md5sum "$SIMG"
else
    echo "警告: 找不到 img2simg，跳过 simg 生成（fastboot 需 raw img）" >&2
fi

say "=== 完成 ==="
ls -lh "$IMG"
md5sum "$IMG"
