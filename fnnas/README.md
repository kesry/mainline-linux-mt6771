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

## 2. 为什么需要 LD 拦截 强制软解 mediasrv

飞牛 `mediasrv` 依赖 Rockchip MPP 硬件编解码（`librockchip_mpp.so.1`），
启动时会读 `/proc/device-tree/compatible` 匹配 SoC。MT6771 不在支持列表：

```
mpp_platform: can not found match soc name: mediatek,mt6771
→ mediasrv 退出 → /var/run/trim_media.sock 不存在
→ 飞牛影视 / 飞牛音乐 502
```

**不要用 fakecompat 伪装成 rk3588**：那会让 MPP 真的去调用不存在的 VPU 硬件
（/dev/dri、dma-heap），导致不稳定。用户明确要求走软解。

**采用的方案**：用 [kesry/trimmedia-linux-arm](https://github.com/kesry/trimmedia-linux-arm)
提供的拦截库：

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

### 6.6 网页上传失败（403 / errno 9）的完整修复

飞牛网页上传要过四道关，主线内核上每一道都可能断：

1. **`file.checkUpload` → errno 9**
   `filemanager` 的 `check_parent_writable()` 走 libnperm 的伪 dirfd
   `faccessat(-21586, struct...)`，主线内核返回 EBADF(9) → 前端"失败出错"，
   请求根本到不了 `/upload`。
   → 修：`fnacl_faccessat_hook.so` 注入 **trim_main**（`filemanager` 由 trim
   exec，继承环境变量）。

2. **ZFS 缺失**：`checkSpaceAndQuota` 要跑 `zpool status -j`。
   主线内核没有 ZFS 模块 → 报错。
   → 修：把 OpenZFS 2.2.7 用 `copy-builtin` 编进内核（`CONFIG_ZFS=y`）。
   `zpool list` 在无池时返回 `no pools available` 且 rc=0 即正确。

3. **`Invalid trim-key`**
   `uploadsrv` 启动时用 `load_trim_key()` 解密 `/usr/trim/etc/trim.key.enc`：
   - `master_key = HMAC-SHA256(SMBIOS UUID 字符串, /etc/machine-id 前 32 字节)`
   - `trim.key.enc = IV(12) + AES-256-GCM(256B 随机 key) + TAG(16) = 284 字节`
   MT6771 无 SMBIOS，`get_smbios_uuid()` 回退常量
   `00000000-0000-0000-0000-000000000000`，所以镜像里带的 key 必然解不开。
   → 修：`/usr/local/sbin/a3-trim-keygen` 在目标机上按本机 machine-id 重算
   （`a3-fnperm-hook-setup` 开机调用；key 能解开就保留，避免重启换 key）。

4. **`begin_upload` → 403（"权限不足"）**
   `uploadsrv` 的 `is_vol_path_writeable()` 同样走 libnperm 伪 dirfd 判权限
   → 主线内核返回不可写 → 403。
   → 修：`fnacl_faccessat_hook.so` 注入 **trim_upload**。

5. **长效令牌 `osrt`**（前端要求）
   登录时必须勾选"保持登录"（stay），服务端才会下发 `osrt` cookie；
   nginx 的 `trim-cookie-v2-to-v1-map.conf` 把它映射成 `fnos-long-token`，
   uploadsrv 的 token 校验才通过。不勾选只有 `ost`，上传仍会 403。

验证：上传一个 28MB FLAC，文件正确落在 `/vol1/1000/music/`，无 `*.~#*` 残留。

### 6.7 一键构建（内核 + boot.img + rootfs + 模块注入）

```sh
# 全流程：编内核/模块 → boot.img → 飞牛 rootfs → 注入模块
./script/a3-fnnas-all.sh <fnos-arm.iso> <trim-media-lib.zip> [rootfs大小G]

# 只重打 boot.img（内核已编好）
./script/a3-fnnas-all.sh --boot-only

# 只重做 rootfs 并注入模块
./script/a3-fnnas-all.sh --rootfs-only <iso> <trimlib> [size]
```

关键点：

- **必须用 `A3_DTB=vendor/a3-v186-tgpio.dtb`**（脚本已默认）。`a3-v186-good.dtb`
  没有 `panel@0` 节点 → `mediatek-drm` 不 probe → 屏幕停在第一屏，脚本会直接拒绝。
- **`=m` 的内核模块必须进 rootfs**，否则 `CONFIG_PWM_MTK_DISP=m` 等驱动缺失。
  脚本会 `modules_install` 到暂存目录，连同 `trim_acl_shim.ko` 一起打成
  `out/kernel-modules-<ver>.tar.gz`，再解进 rootfs 的 `/lib/modules/<ver>/`
  并跑 `depmod`。
- 模块与内核**必须同一次编译**：vermagic 里带 git 描述符，内核一改就对不上。

### 6.8 内核配置必须落在 defconfig 里（否则 CI 会丢）

CI（`.github/workflows/verify-kernel.yml`）流程是：

```
patch -p1 < patch/*.patch   →   make a3_defconfig   →   make Image
```

所以**只改 `qdiag/.config` 是没用的**——CI 从 `a3_defconfig` 重新生成。
新增内核选项的正确做法：

```sh
# 1. 在已编译的树上开选项
./kernel-src/scripts/config --file qdiag/.config -e ZFS
make -C kernel-src O=$PWD/qdiag ARCH=arm64 olddefconfig

# 2. 固化成 defconfig
make -C kernel-src O=$PWD/qdiag ARCH=arm64 savedefconfig
cp qdiag/defconfig kernel-src/arch/arm64/configs/a3_defconfig

# 3. 生成 patch（相对上一版 defconfig 的 diff）
#    patch/0007-arm64-configs-a3-enable-ZFS-BTRFS-quota-MD-DM.patch
```

`patch/0007` 把飞牛需要但原来缺失的选项补齐：

```
SCSI / BLK_DEV_SD / CHR_DEV_SG        （U 盘、移动硬盘）
MD / MD_LINEAR=m / BLK_DEV_DM         （飞牛存储池 mdadm + LVM）
DM_CRYPT / DM_SNAPSHOT / DM_THIN_PROVISIONING / DM_MIRROR / DM_RAID
TARGET_CORE
BTRFS_FS / BTRFS_FS_POSIX_ACL
QFMT_V1 / QFMT_V2                     （prjquota 必需）
ZFS=y                                 （checkSpaceAndQuota 会跑 zpool）
```

验证方式（等价于 CI）：

```sh
make -C kernel-src O=/tmp/cfgtest ARCH=arm64 a3_defconfig
grep -E '^CONFIG_(ZFS|BTRFS_FS|QFMT_V2|MD|BLK_DEV_DM|EFI|DMI)=' /tmp/cfgtest/.config
```

### 6.9 伪 dirfd 系列系统调用（删除/上传目录/改名都靠它）

`fnacl_faccessat_hook.so` 不只 hook `faccessat`，还覆盖 `*at` 家族——
飞牛把私有语义塞进**负数 dirfd**：

| 调用 | 伪 dirfd | 用途 |
| --- | --- | --- |
| `faccessat` | -21586 … -21575 | 权限判定（11 个 trim_syscall） |
| `unlinkat` | -7125 | 删除文件 |
| `renameat2` / `statx` / `utimensat` | -7125 等 | 改名 / 取属性 / 改时间 |

主线内核把这些当真实 fd → `EBADF(9)`，于是删除、上传目录全部失败。

hook 的处理：

1. 负数 dirfd（排除 `AT_FDCWD`）→ 取真实路径
   - 以 `/` 开头直接用
   - 像路径串（`vol1/1000/...`）→ 根相对，补 `/` 前缀
   - 否则当成 libnperm 的 struct，解引用首字段
2. 用 `AT_FDCWD` 调真正的函数
3. **`faccessat` 的 mode/flags 要清洗**：飞牛在 `mode` 里夹带 `0x8` 这类私有位，
   直接透传会让 `faccessat2` 返回 `EINVAL(22)`
   （`mode &= 7`，`flags &= AT_SYMLINK_NOFOLLOW|AT_EACCESS|AT_EMPTY_PATH`）

排查时可开日志：

```sh
Environment="FNACL_LOG=1"      # 写到 /tmp/fnacl.log
```

### 6.10 回收站（`/dev/trim-trashbin`）—— 部分可用

`trim_acl_shim.ko` 现在除了 `system.trim_acl` xattr，还注册一个 misc 字符
设备 `/dev/trim-trashbin`（`trimafs` 私有补丁的一部分），让 `trim_trashbind`
服务能 `open()` 成功，不再因为 `ENOENT` 每 5 秒崩溃重启（历史上重启计数到过 300+）。

**已验证**：模块加载后 `/dev/trim-trashbin` 存在，`trashbind` 能打开它。

**限制**：完整的回收站还需要内核在 rename/unlink 路径上生成
`trim_trashbin_request_t` 事件（32 字节头 + 路径，`read()` 阻塞等待）。
`trashbind` 打开设备后执行 `read(6, buf, 262144)` 并解析 `size` 字段
（`trim_trashbin_request_t`，`process_packet()` 分发搬运动作）。
当前 shim 的 `read()` 返回 0（EOF），所以 `trashbind` 正常退出而不会常驻。
要完整支持需要把内核 `trim_do_trashbin` 挂到 VFS 上，属于下一步工作。

因此当前策略是 `systemctl stop trim_trashbind`（避免 `Restart=always`
造成无效重启循环）；**永久删除、上传、上传目录、改名、远程复制都不受影响**。

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
