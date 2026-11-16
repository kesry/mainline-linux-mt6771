#!/bin/sh
# 从厂商 8.1 内核源码导入无线/BT 栈。
#
# 厂商无线代码共 909 个文件、约 32 MB，体积大且有版权，不进本仓库。
# 需要编译 WiFi/BT 时用这个脚本从厂商源码树复制进来。
#
# 用法：
#   script/import-vendor-wireless.sh [厂商源码树路径]
#
# 默认路径：/opt/oppoa3/A3-8.1-kernel-source-master
set -e

VENDOR="${1:-/opt/oppoa3/A3-8.1-kernel-source-master}"
KERNEL="${KERNEL_SRC:-/opt/oppoa3/kernel-src}"

if [ ! -d "$VENDOR" ]; then
	echo "厂商源码树不存在: $VENDOR" >&2
	exit 1
fi
if [ ! -d "$KERNEL" ]; then
	echo "内核源码树不存在: $KERNEL" >&2
	exit 1
fi

echo "厂商源码: $VENDOR"
echo "内核源码: $KERNEL"

# 厂商树里无线代码的相对路径（按实际存在的目录逐个尝试）
SRC_REL="drivers/net/wireless/mediatek"
DST="$KERNEL/drivers/net/wireless/mediatek"

if [ ! -d "$VENDOR/$SRC_REL" ]; then
	echo "在厂商树里没找到 $SRC_REL" >&2
	exit 1
fi

# 只复制厂商的实现在目录，不覆盖我们自己的胶水层
for d in gen3 gen4m wmt wmt-adaptor btif mt66xx; do
	if [ -d "$VENDOR/$SRC_REL/$d" ]; then
		echo "复制 $d ..."
		mkdir -p "$DST"
		rm -rf "$DST/$d"
		cp -a "$VENDOR/$SRC_REL/$d" "$DST/"
	fi
done

# 厂商树里的 BTIF 兼容层（如果存在）
for extra in "drivers/staging/btif"; do
	if [ -d "$VENDOR/$extra" ]; then
		echo "复制 $extra ..."
		mkdir -p "$KERNEL/$(dirname "$extra")"
		cp -a "$VENDOR/$extra" "$KERNEL/$extra"
	fi
done

echo
echo "完成。已导入到 $DST"
echo "这些文件在 .gitignore 里，不会被提交。"
echo "重新编译前建议确认 Kconfig/Makefile 里的引用路径与实际目录一致。"

# 厂商 btif 代码还需要两处 Kconfig/Makefile 挂钩，仓库里刻意没有它们
# （无条件 source 会让干净的 6.12.115 在 Kconfig 阶段就失败）。
# 导入完成后在这里补回去。
STAGING_KCONFIG="$KERNEL/drivers/staging/Kconfig"
if [ -d "$KERNEL/drivers/staging/btif" ] && ! grep -q 'staging/btif/Kconfig' "$STAGING_KCONFIG"; then
    echo 'source "drivers/staging/btif/Kconfig"' >> "$STAGING_KCONFIG"
    echo "已在 drivers/staging/Kconfig 末尾补回 source 行"
fi

STAGING_MAKEFILE="$KERNEL/drivers/staging/Makefile"
if [ -d "$KERNEL/drivers/staging/btif" ] && ! grep -q 'btif/' "$STAGING_MAKEFILE"; then
    echo 'obj-$(CONFIG_MTK_BTIF_DRV)	+= btif/' >> "$STAGING_MAKEFILE"
    echo "已在 drivers/staging/Makefile 末尾补回 obj- 行"
fi

echo
echo "注意：补回的两行只存在于本地工作树，不要提交它们，"
echo "     否则干净的 6.12.115 又会在 Kconfig 阶段失败。"
