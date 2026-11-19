# 飞牛 FnNAS on OPPO A3 (MT6771)

主线 Linux 6.12 + 飞牛 ARM rootfs 的移植记录。

## 目录结构

```
fnnas/
├── README.md                       本文
├── build-rootfs-fnnas.sh           飞牛 rootfs 打包脚本（与 build-rootfs.sh 独立）
├── a3-gadget                       USB gadget 脚本（RNDIS 网络 + ACM 串口）
└── ld-hooks/
    ├── fakecompat.c                伪造 /proc/device-tree/compatible（可选）
    ├── nodri.c                     屏蔽 /dev/dri
    ├── nodmaheap.c                 屏蔽 /dev/dma_heap
    └── build-hooks.sh              aarch64 交叉编译这三个 so
```

> **与 Debian rootfs 完全分开**：`script/build-rootfs.sh` 是 Debian 的，
> 本目录是飞牛的，两者不共用脚本、不互相调用。

## 1. 内核需要的配置（飞牛专属）

飞牛的 `libtrim_machine` 通过 SMBIOS/DMI 识别机器，非 UEFI 设备上必须显式开启：

```
CONFIG_EFI=y                        # arm64 上 CONFIG_DMI depends on EFI
CONFIG_DMI=y                        # default y，但依赖 EFI
CONFIG_DMIID=y                      # /sys/class/dmi/id/
CONFIG_DMI_SYSFS=y                  # /sys/firmware/dmi/tables/
CONFIG_FW_CFG_SYSFS=y
CONFIG_FW_CFG_SYSFS_CMDLINE=y
CONFIG_PCI=y                        # libpci 需要 /proc/bus/pci
CONFIG_PCI_MSI=y
```

这些已写入 `arch/arm64/configs/a3_defconfig`（在 0005 patch 里）。

**踩坑**：只在 `.config` 里开不够，必须写进 `a3_defconfig` 再重新导出 patch，
否则 CI 编译出来的内核没有这些选项，飞牛服务会连环崩溃：

```
sysinfo_service 崩（can not probe trim dev）
→ trim_license 崩（dial unix sysinfo 失败）
→ Web API 全 502 → 无法登录
```

## 2. 为什么需要 LD 拦截 / 软解 mediasrv

飞牛原版 `mediasrv` 依赖 Rockchip MPP 硬件编解码（`librockchip_mpp.so.1`），
启动时会读 `/proc/device-tree/compatible` 匹配 SoC。MT6771 不在支持列表：

```
mpp_platform: can not found match soc name: mediatek,mt6771
→ mediasrv 退出 → /var/run/trim_media.sock 不存在
→ 飞牛影视 / 飞牛音乐 502
```

**不要用 fakecompat 伪装成 rk3588**：那会让 MPP 真的去调用不存在的 VPU 硬件
（/dev/dri、dma-heap），导致不稳定。用户明确要求走软解。

**采用的方案**：用 [kesry/trimmedia-linux-arm](https://github.com/kesry/trimmedia-linux-arm)
提供的 Go 软解版 mediasrv + 拦截库：

```
nodri.so      屏蔽 /dev/dri 探测     → 让程序不去找不存在的 GPU 节点
nodmaheap.so  屏蔽 /dev/dma_heap     → MT6771 无 dma-buf heap
fakecompat.so 伪造 compatible        → 可选，软解方案默认不注入
```

通过 systemd drop-in 改 `mediasrv.service` 的 `ExecStart` 指向软解版，
**原版二进制不动**，删掉 override.conf 即可回退。

一个关键细节：`ExecStartPost` 必须给 socket 加 ACL：

```
setfacl -m u:www-data:rw /var/run/trim_media.sock
```

因为 nginx worker 是 www-data，软解版创建的 socket 默认不允许它访问，
不加这条会 502（Permission denied）。

## 3. USB 网络与串口（非 UEFI 设备必须自己建）

飞牛 rootfs 不会自动建立 USB gadget。本脚本注入：

```
a3-gadget.service  → 开机建 RNDIS + ACM
  网络  RNDIS  dev MAC 02:00:a3:00:00:02 / host MAC 02:00:a3:00:00:01
        usb0  10.42.1.2/24（systemd-networkd）
  串口  ACM    ttyGS0，serial-getty@ttyGS0
```

Windows 侧把 RNDIS 网卡配成 `10.42.1.1/24`，即可 SSH/Web 访问 10.42.1.2。

**顺序关键**：先建 RNDIS 网络，再建 ACM 串口；反过来主机会在第二个功能出现时重枚举，串口掉线。

## 4. 打包流程

```bash
bash build-rootfs-fnnas.sh <飞牛ARM.iso> <trim-media-lib.zip> [镜像大小G=16]
```

脚本做 5 件事：

1. 7z 从 ISO 提取 `trimfs.tgz`，限速解压（每 2 秒清缓存，避免构建机 OOM）
2. 编译并安装 LD 拦截库到 `/opt/fnnas/hook/`
3. 注入 USB gadget（RNDIS+ACM）+ 网络 + getty
4. 安装软解 mediasrv 到 `/opt/trimmedia/` + systemd drop-in
5. 改 fstab（根分区用 PARTUUID），loop 挂载打包成 ext4 镜像

产物：`out/fnnas-rootfs.img`

**注意**：data 分区（90G）**绝不写进 fstab**，留给飞牛 WebUI 初始化成存储池。

## 5. 分区布局（userdata 20G + data 90G）

见 `docs/partition-userdata-split.md`。要点：

```
userdata (p44) 20G  root=PARTUUID=6fce83a6-...  ← 保住这个 GUID
data     (p47) 90G  裸盘，飞牛 WebUI 初始化
```

重建 userdata 分区时必须 `-u 6FCE83A6-5273-4748-1145-C205EBB4B8AD`，
否则 `root=PARTUUID` 失效、系统起不来。

## 6. 已知限制

- 飞牛存储管理对 mmcblk 分区的支持有限：需要分区带 `msftdata` 标志
  （跟 otp 分区一样），否则 WebUI 扫描不到
- 内核仍需主线 boot；飞牛自己的 6.18.18 内核在 MT6771 上跑不起来
  （缺 ARMv8.1 的 GIC 系统寄存器）
- 软解媒体服务无硬件转码（4K 硬解不可用），但播放/刮削正常
