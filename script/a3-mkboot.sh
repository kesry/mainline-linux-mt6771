#!/bin/bash
# A3 boot.img 一键打包脚本
#
# 用法：
#   ./a3-mkboot.sh                 # 打包，输出 images/boot-<日期>-<序号>.img
#   ./a3-mkboot.sh myname          # 指定名字
#   ./a3-mkboot.sh myname --flash  # 打包后传一份到设备 /root/ 并 dd 刷入
#
# 每一步都来自实测踩坑，改动前先读 linux/docs/boot-packaging.md。
set -euo pipefail

A3=/opt/oppoa3
SRC=$A3/kernel-src
OUT=$A3/qdiag
IMG=$A3/images
STAGE=$A3/wv

NAME="${1:-boot-$(date +%m%d-%H%M)}"
FLASH=0
[[ "${2:-}" == "--flash" ]] && FLASH=1

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
say()   { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
die()   { red "FATAL: $*"; exit 1; }

# ---------------------------------------------------------------- 0. 前置检查
say "0/6 前置检查"

[[ -f $OUT/arch/arm64/boot/Image ]]   || die "找不到 $OUT/arch/arm64/boot/Image，先编内核"
[[ -f $OUT/System.map ]]              || die "找不到 System.map（mk104 需要它定位 primary_entry）"
[[ -f $IMG/a3-empty.cpio.gz ]]        || die "找不到 a3-empty.cpio.gz（必须用空 ramdisk，让内核按 root=PARTUUID 直接挂载 userdata）"
[[ -f $IMG/a3-v186-good.dtb ]]        || die "找不到 a3-v186-good.dtb"
[[ -f $IMG/stock-boot-orig.img ]]     || die "找不到 stock-boot-orig.img（要从中嫁接 AVB）"
[[ -f $A3/a3-prep-kernel.py ]]        || die "找不到 a3-prep-kernel.py"
[[ -f $A3/mk104.py ]]                 || die "找不到 mk104.py"

# 关键：DTB 必须是 a3-v186-good.dtb。
# 它的 msdc@11230000 是 "mediatek,mt6771-mmc"（主线 mtk-sd 认）；
# stock-a3-fb4352.dtb 是 "mediatek,msdc"（主线不认）→ 卡 Waiting for root device。
DTB_MD5=$(md5sum "$IMG/a3-v186-good.dtb" | cut -d' ' -f1)
[[ "$DTB_MD5" == "21a2f20cc9602235102ae2c057c81e6e" ]] \
    || die "a3-v186-good.dtb md5 变了（$DTB_MD5），这个 DTB 是唯一验证能开机的，别换"

# 内核必须是 48-bit VA（MT6771 是 ARMv8.0，不支持 52-bit/LPA2）
if [[ -n "${A3_DTB:-}" ]]; then
    [[ -f "$A3_DTB" ]] || die "A3_DTB not found: $A3_DTB"
    echo "  A3_DTB override: $A3_DTB (md5 $(md5sum "$A3_DTB" | cut -d' ' -f1))"
fi

for opt in CONFIG_ARM64_VA_BITS_48 CONFIG_ARM64_PA_BITS_48; do
    grep -q "^$opt=y" "$OUT/.config" || die "$opt 未开启，内核会死在 __no_granule_support"
done
grep -q "^CONFIG_ARM64_VA_BITS_52=y" "$OUT/.config" && die "CONFIG_ARM64_VA_BITS_52 必须关闭"

# cmdline 必须带 root=PARTUUID（否则挂不到 userdata）
grep -q 'root=PARTUUID=6fce83a6-5273-4748-1145-c205ebb4b8ad' "$OUT/.config" \
    || die "CONFIG_CMDLINE 里没有 root=PARTUUID=<userdata>，内核会卡在等 root device"
grep -q '^CONFIG_CMDLINE_FORCE=y' "$OUT/.config" \
    || echo "  WARN: CONFIG_CMDLINE_FORCE 未开，boot header 的 cmdline 会覆盖内核的"

green "  前置检查通过（DTB $DTB_MD5）"

# ------------------------------------------------- 1. 修 Image 头（不改 code0 跳板）
say "1/6 修 arm64 Image 头（text_offset / image_size / flags / code0=b+4）"
# 注意：绝不能用 --probe。PROBE_STUB 用 x0，会破坏 LK 传进来的 DTB 指针 → 卡 logo。
python3 "$A3/a3-prep-kernel.py" "$OUT/arch/arm64/boot/Image" \
        "$IMG/stock-boot-orig.img" /tmp/a3_k1.gz | sed 's/^/  /'
python3 - <<'PY'
import gzip
open("/tmp/a3_Image-hdr","wb").write(gzip.open("/tmp/a3_k1.gz","rb").read())
PY
green "  裸 Image 已解出 /tmp/a3_Image-hdr"

# ------------------------------------------------- 2. 看门狗跳板（必需）
say "2/6 注入 TopRGU 看门狗关闭跳板（不注入 = 60 秒周期重启）"
# mk104.py 用 x8/x9（保留 x0=DTB），结尾 b primary_entry（地址取自 System.map）
python3 "$A3/mk104.py" /tmp/a3_Image-hdr "$IMG/stock-boot-orig.img" \
        /tmp/a3_k2.gz "$OUT/System.map" | sed 's/^/  /'
green "  跳板已注入"

# ------------------------------------------------- 3. 组装 boot.img
say "3/6 组装 boot.img（空 ramdisk + v186 DTB + AVB 嫁接）"
TARGET="$IMG/$NAME.img"
python3 "$A3/mkbootimg-a3.py" \
    --kernel   /tmp/a3_k2.gz \
    --ramdisk  "$IMG/a3-empty.cpio.gz" \
    --dtb      "${A3_DTB:-$IMG/a3-v186-good.dtb}" \
    --stock-vbmeta "$IMG/stock-boot-orig.img" \
    --output   "$TARGET" | sed 's/^/  /'

# ------------------------------------------------- 4. 结构校验
say "4/6 结构校验"
SZ=$(stat -c%s "$TARGET")
[[ $SZ -eq 33554432 ]] || die "镜像大小 $SZ != 32 MiB"

python3 - "$TARGET" <<PYEOF
import gzip, io, struct, sys
p = sys.argv[1]
d = open(p, "rb").read()
ps  = struct.unpack_from("<I", d, 0x24)[0]
ks  = struct.unpack_from("<I", d, 0x08)[0]
rs  = struct.unpack_from("<I", d, 0x10)[0]
dsz = struct.unpack_from("<I", d, 0x670)[0]
ok = True
def chk(cond, msg):
    global ok
    print(("  OK   " if cond else "  FAIL ") + msg)
    if not cond: ok = False

chk(ps == 2048,                "page_size == 2048")
chk(d[ps] == 0x1f and d[ps+1] == 0x8b, "kernel 段是 gzip")
chk(rs < 4096,                 "ramdisk 是空的（%d B，不抢 root=）" % rs)
chk(dsz > 100000,              "dtb_size 合理（%d）" % dsz)

# AVB 结构：AVB0 紧跟在 kernel 段之后（不在文件末尾），AVBf 在最后 64B
i0 = d.rfind(b"AVB0")
chk(i0 > 0,                    "AVB0 vbmeta 存在 @ 0x%x" % i0)
chk(d[-64:].find(b"AVBf") >= 0 or d.rfind(b"AVBf") > i0, "AVBf footer 存在")

# code0 在【解压后】的 Image 起始处（boot 里的 kernel 段是 gzip）
try:
    raw = gzip.GzipFile(fileobj=io.BytesIO(d[ps:ps+ks])).read(16)
except Exception as e:
    chk(False, "kernel 段解压失败: %s" % e); sys.exit(1)
w = struct.unpack_from("<I", raw, 0)[0]
chk((w & 0xFC000000) == 0x14000000, "code0 是分支指令（看门狗跳板）: 0x%08x" % w)
# 跳板目标应为 0x40
imm26 = w & 0x03FFFFFF
chk(imm26 * 4 == 0x40,         "跳板指向 0x40 (imm26*4=%d)" % (imm26 * 4))
sys.exit(0 if ok else 1)
PYEOF
[[ $? -eq 0 ]] || die "结构校验失败"

# ------------------------------------------------- 5. 落地
say "5/6 落地"
MD5=$(md5sum "$TARGET" | cut -d' ' -f1)
cp -f "$TARGET" "$STAGE/$NAME.img"
echo "  镜像 : $TARGET"
echo "  备份 : $STAGE/$NAME.img"
echo "  md5  : $MD5"
echo "  大小 : $SZ"

# ------------------------------------------------- 6. 可选：刷入
if [[ $FLASH -eq 1 ]]; then
    say "6/6 dd 刷入设备"
    # 坑：eMMC 大块写会静默失败。必须用默认 bs=512，不加 oflag/dsync。
    scp -q "$TARGET" "root@10.42.1.1:/root/$NAME.img" || die "scp 到设备失败"
    ssh root@10.42.1.1 "
        dd if=/root/$NAME.img of=/dev/mmcblk0p35 2>&1 | tail -1
        sync
        echo -n '  verify: '
        dd if=/dev/mmcblk0p35 iflag=direct 2>/dev/null | head -c $SZ | md5sum
    "
    echo "  期望  : $MD5"
    echo
    echo "  重启生效: ssh root@10.42.1.1 'sync; reboot'"
else
    say "6/6 刷入（未执行，需要时手动）"
    cat <<EOF
  # 方式 A：设备在 Linux 下用 dd（推荐，不必进 fastboot）
  #   坑：eMMC 大块写会静默失败 → 必须默认 bs=512，不加 oflag/dsync
  pscp $TARGET root@10.42.1.1:/root/$NAME.img
  ssh root@10.42.1.1 'dd if=/root/$NAME.img of=/dev/mmcblk0p35; sync'

  # 校验（必须 iflag=direct 绕过页缓存）
  ssh root@10.42.1.1 'dd if=/dev/mmcblk0p35 iflag=direct 2>/dev/null | head -c 33554432 | md5sum'
  # 期望: $MD5

  # 方式 B：fastboot（设备需在 fastboot）
  fastboot flash boot $TARGET

  # 重新打包并直接刷入
  $0 $NAME --flash
EOF
fi

green "打包完成: $NAME.img  $MD5"
