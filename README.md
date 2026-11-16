# mainline-linux-mt6771

OPPO A3（PADT00，联发科 MT6771 + MT6631）移植主线 Linux 6.12 的项目仓库。

这里存放**与主线内核的差异补丁**、**构建与打包脚本**、**文档**和**工作流说明**。
内核源码树、打包产物、厂商源码体积过大，不进本仓库，见「不纳入仓库的内容」。

## 目录结构

```
patch/      内核相对主线 6.12.115 的全部差异补丁（git format-patch 产物）
script/     解包、打包、编译用到的脚本
workflow/   手动编译内核与 rootfs、上传到设备的操作步骤
docs/       文档：boot 打包、rootfs 构建、仓库工作流
```

## 目标设备

```
机型      OPPO A3 / PADT00
SoC       MediaTek MT6771（4×Cortex-A73 + 4×Cortex-A53，Mali-G72 MP3）
WiFi/BT   MT6631（CONSYS）
内存      4 GB
存储      eMMC，boot = /dev/mmcblk0p35，rootfs 在 userdata = /dev/mmcblk0p44
显示      1080×2280 MIPI-DSI，Novatek NT36672A（incell，触摸与显示同颗）
系统      Debian 13 (trixie)，桌面 phosh（手机桌面）+ squeekboard 屏幕键盘
```

## 内核补丁的基线约定（重要）

分支会移动，补丁会失效，所以**基线一律用标签**，并且标签一经创建不再移动：

```
base-6.12.115   上游 Linux 6.12.115 的提交，全部补丁相对它生成
a3-wip-<日期>   我们当前工作的快照标签，每整理一次打一个
```

重新生成补丁：

```sh
cd kernel-src
git format-patch --no-signature -o ../patch base-6.12.115..a3-wip-20261116
```

从标签还原某个可用状态：

```sh
cd kernel-src
git checkout a3-wip-20261116          # 只读查看
git switch -c work a3-wip-20261116    # 继续开发
```

> 不要用分支名当补丁基线。分支被后续提交推进后，`format-patch` 的结果会变，
> 别人就复现不出同一套补丁了。

## 不纳入仓库的内容

以下内容体积大或涉及版权，**不提交**（已在 `.gitignore` 中排除）：

```
kernel-src/                        内核源码树（3.3 GB，本身是独立 git 仓库）
qdiag/ ccache/ build/ out/         编译输出与缓存
images/ *.img *.dtb *.dtbo *.ko    打包产物
A3-8.1-kernel-source-master/       厂商 8.1 内核源码（885 MB，含版权代码）
firmware/                          厂商固件
```

## 当前功能状态

```
✅ 显示        MIPI-DSI 面板自写上电序列，1080×2280 正常输出
✅ 触摸        Novatek NT36672A，走 i2c-gpio（硬件 i2c0 在本机型不驱引脚）
✅ GPU         panfrost / Mali-G72 已加载
✅ 电池        库仑计 + 电压表回退，容量可用
✅ 桌面        phosh 0.46 + squeekboard + Noto CJK 中文字体
⚠️ 实体按键    音量键 GPIO 已定位（20/94），驱动未完成
⚠️ 熄屏再亮屏  面板断电后触摸需要重新初始化，自愈逻辑未定稿
⚠️ WiFi/BT     厂商 BTIF 代码已并入，未打通
```

详细结论与踩坑记录见 `docs/`。

## 构建：GitHub Actions

仓库带一个工作流 `.github/workflows/verify-kernel.yml`，两种触发方式：

```
1. 手动：Actions 页面 → 「构建 A3 内核与镜像」→ Run workflow
   勾选要构建的产物（boot.img / rootfs-minimal.img / rootfs-phosh.img）
2. 自动：push 改动 patch/ 或工作流本身时触发
```

产物（artifact `a3-images`）：

```
boot.img              内核 + 设备树，fastboot flash boot 直接可用
rootfs-minimal.img    Debian 13 最小系统 + SSH，1 GB，先验证内核用
rootfs-phosh.img      最小系统 + phosh 手机桌面 + 中文字体，3 GB
Image / System.map    裸内核与符号表
```

产物内容说明：

```
· rootfs 从零用 debootstrap 构建，不继承任何手工改动
· 固件只放能驱动的设备：触摸（NT36672A）。WiFi/BT 还没打通，固件不放入
· 已预置：usb0 静态地址 10.42.1.2/24、sshd、用户 kesry（默认密码见构建脚本（script/build-rootfs.sh），免密 sudo）
· 预置 a3-growroot.service：首次启动自动把根分区扩到整个 userdata
```

`vendor/` 里放了打包必需的三个文件：原厂 `stock-boot-orig.img`（打包时要嫁接 AVB
并读取内核头常量）、`a3-v186-good.dtb`（已验证可开机的基线设备树）、
`a3-v186-tgpio.dtb`（触摸可用版本）、`a3-empty.cpio.gz`（空 ramdisk）。
