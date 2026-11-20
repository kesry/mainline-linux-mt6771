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

## 6. 主线内核兼容补丁（存储池能不能用的关键）

飞牛存储池依赖两个**私有内核特性**，上游主线没有，导致存储池建不起来或挂不上。
本脚本注入 `a3-fnnas-fixes.service`，**每次开机重新应用**（防止被系统更新覆盖）。

### 6.1 mdadm wrapper：`--bitmap=lockless` → `--bitmap=internal`

飞牛创建存储池时硬编码：

```
mdadm --create /dev/md0 --metadata=1.2 --run --force --level=1 \
      --raid-devices=1 --bitmap=lockless /dev/mmcblk0pXX
```

`lockless` write-intent bitmap 需要内核 `ll_bitmap` sysfs 属性，这是飞牛 6.18
私有补丁（实测飞牛 `md-mod.ko` 里有 `ll_bitmap`，上游 6.12/6.14/master 都没有）。
后果：

| mdadm 版本 | 行为 |
|---|---|
| 4.5 / 4.6（新） | 调 `sysfs_set_llbitmap()` 失败 → 阵列建不起来，留下空壳 md0 → 后续重试全因 EEXIST 失败 |
| 4.2（老） | 不认识该参数 → 直接拒绝 |

**两种都失败。** wrapper 把参数换成 `internal`：单盘 RAID1 上功能等效
（都是 write-intent bitmap，只是加锁粒度不同），飞牛存储池功能不受影响。

### 6.2 mount wrapper：过滤 `trimacl`

飞牛挂载存储池时带私有参数：

```
mount -t ext4 -o trimacl,prjquota /dev/dm-0 /vol00
```

`trimacl` 是飞牛 `CONFIG_FS_TRIM_ACL` 私有补丁（Windows ACL 机制，用于回收站和
多用户文件权限）。主线内核报 `ext4: Unknown parameter 'trimacl'` 并拒绝挂载。

wrapper 只过滤 `trimacl`，保留 `prjquota` 等标准参数。

> 代价：飞牛的**文件回收站**和**多用户文件权限管理**不可用（社区 issue #640 已确认
> 这两个功能依赖 FilesACL 内核模块）。基本存储、共享、Docker 不受影响。

### 6.3 固定 `/etc/resolv.conf`

`/etc/resolv.conf` 若没有 `nameserver` 行，pgbouncer 启动时报
`evdns_base_new failed` 然后 **SEGV 崩溃**，连锁导致：

```
pgbouncer 崩 → /run/pgbouncer/.s.PGSQL.6432 消失
  → cloud_storage_dav / ai_manager 连不上数据库
  → 存储池无法登记、无法挂载
  → 飞牛 Web 全挂
```

脚本固定写入 DNS 并在 NetworkManager 里设 `dns=none`，防止被覆盖。

### 6.5 飞牛私有 syscall：`system.trim_acl` 与伪 dirfd（音乐/影视授权的关键）

飞牛 `CONFIG_FS_TRIM_ACL` 是私有 VFS 补丁，主线内核没有。它有两层：

1. **xattr：`system.trim_acl`**
   - 飞牛 libtrimacl 通过标准 `getxattr/setxattr("system.trim_acl")` 读写 ACL。
   - 主线内核无此 handler → 返回 `EOPNOTSUPP(95)` → 判定"无写入权限"。
   - 解决：`fnnas/kmod/trim_acl_shim.ko`（内核模块）替换 sb->s_xattr，
     注册精确匹配 `system.trim_acl` 的 handler，读写转发到 `user.trim_acl`。
     关键：xattr_handler 必须用 `.name` 精确匹配、`.prefix=NULL`，否则
     `xattr_resolve_name()` 会返回 EINVAL（见源码注释）。

2. **权限判定：伪 dirfd `faccessat`**
   - 飞牛 `libnperm.so` 用 `faccessat(-21586, struct_ptr, R_OK|W_OK, 0)` 判定权限。
     飞牛内核会解引用 struct 取真实路径；主线内核把 struct 当路径串 → EBADF。
   - 解决：`fnnas/ld-hooks/fnacl_faccessat_hook.so`（LD_PRELOAD）
     拦截 faccessat，识别伪 dirfd（-21586..-21575），解引用 struct 首字段
     取真实路径，转成标准 `AT_FDCWD` 调用。
   - 构建脚本通过 `a3-fnperm-hook-setup` 给所有链接 libnperm 的飞牛服务
     自动生成 systemd drop-in 注入（开机生效）。

> 实机验证（2026-11-20）：加这两层后，飞牛音乐"添加音乐库/文件夹授权"
> 从"所选文件夹无写入权限"变为成功。

> 注意：**不要手工启动飞牛的应用**（如 trim-music）。必须由 app-center
> 自己拉起，否则应用缺少 `TRIM_API_TOKEN`，会报 `authed-dir/list` 未知错误。

### 6.4 内核需要的内核配置

除第 1 节外，存储栈还需要：

```
CONFIG_QUOTA=y
CONFIG_QFMT_V1=y
CONFIG_QFMT_V2=y          # 缺这个 ext4 带 quota 特性时拒绝挂载
CONFIG_QUOTA_TREE=y
CONFIG_QUOTACTL=y
CONFIG_BLK_DEV_DM=y + DM_*   # LVM
CONFIG_MD=y + MD_RAID1=y
CONFIG_BTRFS_FS=y
```

**踩坑**：飞牛格式化 ext4 时会启用 `quota` 特性，若内核缺 `CONFIG_QFMT_V2`，
挂载报 `EXT4-fs (dm-0): The kernel was not built with CONFIG_QUOTA and CONFIG_QFMT_V2`。

## 7. 存储池创建的完整链路

飞牛建存储池的步骤（缺任何一环都会停住）：

```
1. mdadm --create      → 建 RAID1（受 6.1 lockless 影响）
2. pvcreate /dev/md0   → LVM 物理卷
3. vgcreate trim_<uuid> → 卷组
4. lvcreate -l +100%FREE -n 0  → 逻辑卷
5. mkfs.ext4（或 btrfs）       → 格式化
6. mount -o trimacl,...        → 挂载（受 6.2 trimacl 影响）
7. 写数据库登记                 → 受 6.3 pgbouncer 影响
```

排查时逐条手工跑一遍，就能定位卡在哪一步。

## 8. 已知限制

- 飞牛存储管理对 mmcblk 分区的支持有限：需要分区带 `msftdata` 标志
  （跟 otp 分区一样），否则 WebUI 扫描不到
- 内核仍需主线 boot；飞牛自己的 6.18.18 内核在 MT6771 上跑不起来
  （缺 ARMv8.1 的 GIC 系统寄存器）
- 软解媒体服务无硬件转码（4K 硬解不可用），但播放/刮削正常
