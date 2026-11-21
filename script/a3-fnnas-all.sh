#!/bin/bash
# a3-fnnas-all.sh — 一键：内核(+模块) → boot.img → 飞牛 rootfs（含全部兼容修复）
#
# 为什么需要这个脚本
# ------------------
# 飞牛跑在 OPPO A3（MT6771，主线内核 6.12）上要打很多补丁，散落在：
#   - 内核配置（EFI/DMI/PCI/ZFS/BTRFS/QUOTA/MD-DM…）   → patch/0007
#   - boot.img 打包（必须用 a3-v186-tgpio.dtb，否则显示不亮）
#   - rootfs 内的兼容层（faccessat 伪 dirfd hook、trim.key 生成、
#     mdadm lockless、mount trimacl、DNS、软解 mediasrv、USB gadget）
#   - 内核 =m 模块必须进 rootfs 的 /lib/modules
# 本脚本把这些串成一条命令，避免漏步骤。
#
# 用法
# ----
#   ./a3-fnnas-all.sh <fnos-arm.iso> <trim-media-lib.zip> [rootfs大小G]
#
#   # 只重打 boot.img（内核已编好）
#   ./a3-fnnas-all.sh --boot-only
#
#   # 只重做 rootfs（内核已编好）
#   ./a3-fnnas-all.sh --rootfs-only <iso> <trimlib> [size]
#
# 环境变量
# -------
#   A3_ROOT   仓库根目录（默认脚本上一级）
#   A3_OUT    内核构建目录（默认 $A3_ROOT/qdiag）
#   A3_IMG    资源目录（默认 $A3_ROOT/vendor）
#   A3_DTB    设备树（默认 $A3_IMG/a3-v186-tgpio.dtb —— 显示/触摸可用版本）
#   JOBS      并行数
#
# 产物
# ----
#   $A3_ROOT/vendor/a3-fnnas-<时间戳>.img     boot.img（32 MiB）
#   $A3_ROOT/out/kernel-modules-<ver>.tar.gz   内核模块
#   $A3_ROOT/out/fnnas-rootfs-<时间戳>.img     飞牛 rootfs
#
# 刷入（设备进 fastboot）
# ----------------------
#   fastboot flash boot  vendor/a3-fnnas-<ts>.img
#   fastboot flash userdata out/fnnas-rootfs-<ts>.img     # 会清空用户数据

set -euo pipefail

A3_ROOT="${A3_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="${A3_SRC:-$A3_ROOT/kernel-src}"
A3_OUT="${A3_OUT:-$A3_ROOT/qdiag}"
A3_IMG="${A3_IMG:-$A3_ROOT/vendor}"
A3_DTB="${A3_DTB:-$A3_IMG/a3-v186-tgpio.dtb}"
JOBS="${JOBS:-$(nproc)}"
CROSS="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH=arm64

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die()  { printf '\033[31mFATAL: %s\033[0m\n' "$*" >&2; exit 1; }
ts()   { date +%m%d-%H%M; }

MODE=all
case "${1:-}" in
    --boot-only)   MODE=boot;   shift ;;
    --rootfs-only) MODE=rootfs; shift ;;
    -h|--help)     sed -n '2,45p' "$0"; exit 0 ;;
esac

ISO="${1:-}"
TRIMLIB="${2:-}"
IMG_SIZE_G="${3:-8}"

[ -f "$SRC/Makefile" ] || die "找不到内核源码：$SRC"

kver() { make -s -C "$SRC" O="$A3_OUT" ARCH=$ARCH kernelrelease 2>/dev/null; }

# ---------------------------------------------------------------- 1. 内核 + 模块
build_kernel() {
    say "1/5 编译内核 Image + 模块"
    [ -f "$A3_OUT/.config" ] || {
        info "没有 .config，用 a3_defconfig 生成"
        make -C "$SRC" O="$A3_OUT" ARCH=$ARCH a3_defconfig
    }
    make -C "$SRC" O="$A3_OUT" ARCH=$ARCH CROSS_COMPILE="$CROSS" -j"$JOBS" Image
    make -C "$SRC" O="$A3_OUT" ARCH=$ARCH CROSS_COMPILE="$CROSS" -j"$JOBS" modules
    local v; v="$(kver)"
    info "内核版本: $v"
    info "Image: $(ls -lh "$A3_OUT/arch/arm64/boot/Image" | awk '{print $5}')"
    info "模块数: $(find "$A3_OUT" -name '*.ko' | wc -l)"
}

# ---------------------------------------------------------------- 2. 模块打包
pack_modules() {
    say "2/5 打包内核模块（=m 的驱动，含 PWM_MTK_DISP 等）"
    local v stage; v="$(kver)"
    stage="$(mktemp -d)"
    make -s -C "$SRC" O="$A3_OUT" ARCH=$ARCH INSTALL_MOD_PATH="$stage" modules_install
    local md="$stage/lib/modules/$v"
    mkdir -p "$md/extra"
    # 飞牛私有 trimacl xattr 兼容模块
    if [ -f "$A3_ROOT/fnnas/kmod/trim_acl_shim.ko" ]; then
        cp -f "$A3_ROOT/fnnas/kmod/trim_acl_shim.ko" "$md/extra/" || true
        info "已加入 trim_acl_shim.ko"
    fi
    depmod -b "$stage" "$v" 2>/dev/null || true
    mkdir -p "$A3_ROOT/out"
    tar czf "$A3_ROOT/out/kernel-modules-$v.tar.gz" -C "$stage" "lib/modules/$v"
    rm -rf "$stage"
    info "产物: out/kernel-modules-$v.tar.gz ($(ls -lh "$A3_ROOT/out/kernel-modules-$v.tar.gz" | awk '{print $5}'))"
}

# ---------------------------------------------------------------- 3. boot.img
pack_boot() {
    say "3/5 打包 boot.img"
    [ -f "$A3_OUT/arch/arm64/boot/Image" ] || die "没有 Image，先编内核"
    [ -f "$A3_DTB" ] || die "找不到 dtb: $A3_DTB"
    case "$A3_DTB" in
        *good.dtb) die "不能用 a3-v186-good.dtb：它没有 panel 节点，显示会停在第一屏" ;;
    esac
    local name="a3-fnnas-$(ts)"
    A3_ROOT="$A3_ROOT" A3_OUT="$A3_OUT" A3_IMG="$A3_IMG" A3_DTB="$A3_DTB" \
        bash "$A3_ROOT/script/a3-mkboot.sh" "$name"
    info "产物: $A3_IMG/$name.img"
}

# ---------------------------------------------------------------- 4. rootfs
build_rootfs() {
    say "4/5 制作飞牛 rootfs（含全部兼容修复）"
    [ -n "$ISO" ]     || die "需要飞牛 ARM ISO 路径"
    [ -f "$ISO" ]     || die "ISO 不存在: $ISO"
    [ -n "$TRIMLIB" ] || die "需要 trim-media-lib.zip"
    [ -f "$TRIMLIB" ] || die "trimlib 不存在: $TRIMLIB"
    local name="fnnas-rootfs-$(ts).img"
    OUT="$A3_ROOT/out" bash "$A3_ROOT/fnnas/build-rootfs-fnnas.sh" \
        "$ISO" "$TRIMLIB" "$IMG_SIZE_G"
    # build-rootfs-fnnas.sh 固定输出 out/fnnas-rootfs.img
    if [ -f "$A3_ROOT/out/fnnas-rootfs.img" ]; then
        mv -f "$A3_ROOT/out/fnnas-rootfs.img" "$A3_ROOT/out/$name"
        info "产物: out/$name"
    fi
}

# ---------------------------------------------------------------- 5. 模块注入 rootfs
inject_modules() {
    local img="$1" v; v="$(kver)"
    local tgz="$A3_ROOT/out/kernel-modules-$v.tar.gz"
    [ -f "$img" ] || die "rootfs 不存在: $img"
    [ -f "$tgz" ] || { info "没有模块包，跳过注入"; return; }

    say "5/5 把内核模块注入 rootfs"
    local mnt; mnt="$(mktemp -d)"
    mount -o loop,rw "$img" "$mnt" || die "loop 挂载失败: $img"
    mkdir -p "$mnt/lib/modules"
    tar xzf "$tgz" -C "$mnt"
    depmod -b "$mnt" "$v" 2>/dev/null || true
    # 模块随内核走，保证开机可 modprobe
    cat > "$mnt/etc/modules-load.d/a3.conf" <<'EOF'
# A3: 显示背光 PWM（CONFIG_PWM_MTK_DISP=m）
pwm-mtk-disp
EOF
    local n; n=$(tar tzf "$tgz" | grep -c '\.ko$' || true)
    sync
    umount "$mnt"; rmdir "$mnt"
    info "已注入 /lib/modules/$v（$n 个模块）"
    info "rootfs: $img"
}

# ---------------------------------------------------------------- main
case "$MODE" in
    all)
        build_kernel
        pack_modules
        pack_boot
        build_rootfs
        inject_modules "$(ls -t "$A3_ROOT"/out/fnnas-rootfs-*.img 2>/dev/null | head -1)"
        ;;
    boot)
        pack_boot
        ;;
    rootfs)
        pack_modules
        build_rootfs
        inject_modules "$(ls -t "$A3_ROOT"/out/fnnas-rootfs-*.img 2>/dev/null | head -1)"
        ;;
esac

say "完成"
info "boot.img  : $(ls -t "$A3_IMG"/a3-fnnas-*.img 2>/dev/null | head -1)"
info "rootfs    : $(ls -t "$A3_ROOT"/out/fnnas-rootfs-*.img 2>/dev/null | head -1)"
info "modules   : $A3_ROOT/out/kernel-modules-$(kver).tar.gz"
cat <<'EOF'

刷入（设备进 fastboot 后）：
  fastboot flash boot     <上面的 boot.img>
  fastboot flash userdata <上面的 rootfs.img>   # 注意：会清空用户数据
EOF
