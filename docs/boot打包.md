# boot 镜像打包文档

本文说明如何把编译出的内核 `Image` 和指定的设备树打包成设备可启动的 boot 镜像，
以及刷入方法和验证方式。

## 1. 前提

```
构建机       /opt/oppoa3
内核源码     /opt/oppoa3/kernel-src        （独立 git 仓库）
编译输出     /opt/oppoa3/qdiag             O= 指定的输出目录
原始 boot    /opt/oppoa3/images/stock-boot-orig.img   （打包脚本依赖这个文件）
打包脚本     /opt/oppoa3/a3-mkboot.sh
产物目录     /opt/oppoa3/images/
```

`stock-boot-orig.img` 是**原厂 boot 镜像**，打包脚本以它为模板保留 Android boot 头、
cmdline、AVB 尾部等结构，只替换内核与设备树。所以这个文件不能丢。

## 2. 编译内核

增量编译即可，不要删除 `.o` 强行全编。

```sh
K=/opt/oppoa3/kernel-src
O=/opt/oppoa3/qdiag
make -C $K O=$O ARCH=arm64 -j8 Image
```

产物：`$O/arch/arm64/boot/Image`

改配置用 `scripts/config`，改完必须 `olddefconfig`：

```sh
cd $K && ./scripts/config --file $O/.config --set-val 某个选项 y
make -C $K O=$O olddefconfig
```

## 3. 打包

```sh
cd /opt/oppoa3
A3_DTB=/opt/oppoa3/images/a3-v186-tgpio.dtb ./a3-mkboot.sh a3t64
```

- 第一个参数是镜像名，产物为 `/opt/oppoa3/images/a3t64.img`
- 脚本会打印 `打包完成: a3t64.img <md5>`
- 不指定 `A3_DTB` 时使用默认设备树，**建议每次都显式指定**，避免用到旧 DTB

### 设备树变体的含义

设备树是显示、i2c、触摸能不能工作的关键，历史上不同组合放在不同文件里：

| 文件 | 内容 | 用途 |
| --- | --- | --- |
| `a3-v186-good.dtb` | 最早能启动的基线 | 只作回归对照，不要改动 |
| `a3-v186-alli2c.dtb` | 打开 13 个 i2c 控制器、去掉 hs_only、改 clock-div | 显示 + 硬件 i2c 调试期使用 |
| `a3-v186-tgpio.dtb` | 在上面的基础上加 `i2c-touch`（i2c-gpio 挂在 82/83） | **触摸可用版本使用这个** |
| `a3-v186-keys.dtb` | 再加音量键 `gpio-keys-polled` | 按键实验，未验证通过 |

设备树由 `script/` 下的脚本从上游 DTB 逐层生成，生成顺序见
`workflow/manual-build.md`。

> 注意：LK 会在启动时用自己内置的 dtbo 覆盖我们设备树的一部分节点
> （触摸节点 `nova_nt36672@62`、面板节点等来自 LK，不在我们的 DTB 里）。
> 所以**改 DTB 里不存在的节点是无效的**，要么用 LK 的节点名，要么自己新增节点。

## 4. 刷入

每次刷机前先确认分区可写。boot 分区在从 fastboot 启动后会处于上电写保护状态，
此时 `dd` 会报 I/O error，只能走 fastboot。

### 4.1 判断是否可写

```sh
dmesg -c > /dev/null
dd if=/dev/zero of=/dev/mmcblk0p35 bs=512 count=1
sync; sleep 1
dmesg | grep -c 'I/O error'      # 0 = 可写；2 = 写保护
```

### 4.2 可写时直接 dd（快，不用重启到 fastboot）

```sh
dd if=/root/a3t64.img of=/dev/mmcblk0p35
sync
```

刷完**必须校验**，用 `iflag=direct` 绕过缓存：

```sh
dd if=/dev/mmcblk0p35 iflag=direct 2>/dev/null | head -c 33554432 | md5sum
md5sum /root/a3t64.img
```

### 4.3 写保护时用 fastboot

```sh
fastboot flash boot a3t64.img
fastboot reboot
```

> 经验：从 fastboot 刷入之后，boot 分区会保持写保护直到下次从 dd 方式刷写。
> 所以更省事的做法是：用 fastboot 刷一次，之后迭代都用 dd。

## 5. 启动后自检

```sh
# 内核版本
uname -r

# 显示
cat /sys/class/drm/card0-DSI-1/dpms
cat /sys/class/drm/card0-DSI-1/enabled

# 触摸
grep -E '^N:|^H:' /proc/bus/input/devices
dmesg | grep -i nova-nt36672

# 桌面
systemctl is-active phosh.service
```

## 6. 常见打包/启动问题

```
现象：启动后黑屏，但内核起来了
原因：设备树里显示链路节点不匹配（mmsys/dsi/panel），或 CMA 太小
      （曾因 CMA 32MB 报 "failed to allocate 99d000 byte dma buffer"）
处理：CONFIG_CMA_SIZE_MBYTES=256，并确认 DTB 里 dsi0/panel 节点正确

现象：面板初始化报 "init cmd 0xff failed: -62"
原因：初始化序列在 DSI 上电前下发
处理：序列必须放在 panel 的 enable() 里，不能在 prepare() 里

现象：刷完起不来、串口也没有输出
处理：先刷回已验证的稳定镜像（images/ 里保留一份），再二分定位
```

## 7. 保留稳定镜像

每次验证通过的镜像要保留在 `images/` 里并记录 md5，出问题时先刷回它。
当前记录的稳定镜像是 `a3t54.img`（md5 `45972b4775d9048248b70e00d26919aa`）。
