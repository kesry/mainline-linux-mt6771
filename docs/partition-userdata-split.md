# 分区调整记录：userdata 拆分出 data

**日期**：2026-11-19
**设备**：OPPO A3 (PADT00)，MT6771
**目的**：把 110.5 GiB 的 userdata 拆成 userdata（20 GiB，系统盘）+ data（90.5 GiB，飞牛数据盘）

---

## 1. 调整前的分区表

```
Disk /dev/mmcblk0: 244277248 sectors, 116.5 GiB
Sector size: 512/512
First usable sector: 34
Last usable sector: 244277214

Number  Start        End          Size       Code  Name
   1              64         2111   1024 KiB   0700  boot_para
   2            2112       133183   64 MiB     0700  recovery
   3          133184       134207   512 KiB    0700  para
   4          134208       138303   2 MiB      0700  reserve1
   5          138304       171071   16 MiB     0700  reserve2
   6          171072       175167   2 MiB      0700  reserve3
   7          175168       207935   16 MiB     0700  reserve4
   8          207936       212031   2 MiB      0700  reserve_exp1
   9          212032       214079   1024 KiB   0700  oppo_custom
  10          214080       255039   20 MiB     0700  expdb
  11          255040       257087   1024 KiB   0700  frp
  12          257088       322623   32 MiB     0700  nvcfg
  13          322624       453695   64 MiB     0700  nvdata
  14          453696       519231   32 MiB     0700  metadata
  15          519232       535615   8 MiB      0700  protect1
  16          535616       557055   10.5 MiB   0700  protect2
  17          557056       573439   8 MiB      0700  seccfg
  18          573440       671743   48 MiB     0700  persist
  19          671744       675839   2 MiB      0700  sec1
  20          675840       681983   3 MiB      0700  proinfo
  21          681984       886783   100 MiB    0700  md1img
  22          886784       888831   1024 KiB   0700  spmfw
  23          888832       901119   6 MiB      0700  scp1
  24          901120       913407   6 MiB      0700  scp2
  25          913408       915455   1024 KiB   0700  sspm_1
  26          915456       917503   1024 KiB   0700  sspm_2
  27          917504       948223   15 MiB     0700  cam_vpu1
  28          948224       978943   15 MiB     0700  cam_vpu2
  29          978944      1009663   15 MiB     0700  cam_vpu3
  30         1009664      1042431   16 MiB     0700  gz1
  31         1042432      1075199   16 MiB     0700  gz2
  32         1075200      1206271   64 MiB     0700  nvram
  33         1206272      1216511   5 MiB      0700  lk
  34         1216512      1226751   5 MiB      0700  lk2
  35         1226752      1292287   32 MiB     0700  boot
  36         1292288      1325055   16 MiB     0700  logo
  37         1325056      1357823   16 MiB     0700  odmdtbo
  38         1357824      1368063   5 MiB      0700  tee1
  39         1368064      1392639   12 MiB     0700  tee2
  40         1392640      1916927   256 MiB    0700  odm
  41         1916928      4636671   1.3 GiB    0700  vendor
  42         4636672     11583487   3.3 GiB    0700  system
  43        11583488     12468223   432 MiB    0700  cache
  44        12468224    244156382   110.5 GiB  0700  userdata
  45       244156383    244244446   43 MiB     0700  otp
  46       244244447    244277214   16 MiB     0700  flashinfo
```

**关键约束**：userdata 后面紧邻 `otp`（244156383），没有空隙，
所以只能在 userdata 内部切分，不能往后追加。

**userdata 原始信息**：

```
Partition unique GUID: 6FCE83A6-5273-4748-1145-C205EBB4B8AD
First sector: 12468224
Last sector:  244156382
```

这个 GUID 就是内核 cmdline 里的 `root=PARTUUID=6fce83a6-5273-4748-1145-c205ebb4b8ad`。
**重建分区时必须用 `-u` 保留它**，否则系统找不到根分区无法启动。

---

## 2. 调整后的分区表

```
Number  Start        End          Size       Code  Name
  43        11583488     12468223   432 MiB    0700  cache
  44        12468224     54411263   20.0 GiB   8300  userdata      ← 缩小
  45       244156383    244244446   43 MiB     0700  otp           ← 未动
  46       244244447    244277214   16 MiB     0700  flashinfo     ← 未动
  47        54411264    244156382   90.5 GiB   8300  data          ← 新建
```

**userdata 新信息**（GUID 保持不变）：

```
Partition GUID code:   0FC63DAF-8483-4772-8E79-3D69D8477DE4 (Linux filesystem)
Partition unique GUID: 6FCE83A6-5273-4748-1145-C205EBB4B8AD   ← 与原来一致
First sector: 12468224
Last sector:  54411263
Size:         41943040 sectors (20.0 GiB)
```

**data 新信息**：

```
Partition GUID code:   0FC63DAF-8483-4772-8E79-3D69D8477DE4 (Linux filesystem)
Partition unique GUID: B8DD452E-C6E5-2CC2-7B2E-8FBE26679A09
First sector: 54411264    ← 8 MiB 对齐
Last sector:  244156382
Size:         189745119 sectors (90.5 GiB)
```

`data` 只标记为 Linux 块设备类型，**未格式化**（按要求）。

**userdata 已格式化**：

```
mke2fs -F -b 4096 -I 256 -L a3root /dev/mmcblk0p44
Filesystem label=a3root
Block size=4096
1310720 inodes, 5242880 blocks (20 GiB)
```

---

## 3. 扇区计算过程

```
原始 userdata:  12468224 ~ 244156382
总扇区:         231688159 (110.48 GiB)

目标 userdata 20 GiB:
  20 GiB / 512 = 41943040 扇区
  新结束扇区 = 12468224 + 41943040 - 1 = 54411263

data 起始 = 54411264
data 结束 = 244156382（沿用原 userdata 尾部）
data 大小 = 244156382 - 54411264 + 1 = 189745119 扇区 (90.48 GiB)
```

**对齐验证**：`54411264 % 16384 = 0`（16384 扇区 = 8 MiB），已对齐，无需调整。

---

## 4. 实际执行的命令

通过 USB ACM 串口（COM8，115200 8N1）在救援 initramfs 里执行：

```sh
# 1. 备份 GPT 到内存（重启会丢，仅作应急）
sgdisk -b /tmp/gpt-backup.bin /dev/mmcblk0

# 2. 记录 userdata 详情（必须记下 unique GUID）
sgdisk -i 44 /dev/mmcblk0

# 3. 删除 userdata
sgdisk -d 44 /dev/mmcblk0

# 4. 重建 userdata 为 20 GiB，保留原 GUID
sgdisk -n 44:12468224:54411263 \
       -t 44:8300 \
       -c 44:userdata \
       -u 44:6FCE83A6-5273-4748-1145-C205EBB4B8AD \
       /dev/mmcblk0

# 5. 新建 data 分区（占满剩余空间）
sgdisk -n 0:54411264:244156382 -t 0:8300 -c 0:data /dev/mmcblk0

# 6. 让内核重读分区表
partprobe /dev/mmcblk0

# 7. 格式化 userdata（busybox mke2fs 不支持 -t ext4）
mke2fs -F -b 4096 -I 256 -L a3root /dev/mmcblk0p44

# 8. 验证
sgdisk -p /dev/mmcblk0
sgdisk -i 44 /dev/mmcblk0
sgdisk -i 47 /dev/mmcblk0
```

### 关于 `Warning! Unable to generate a proper UUID!`

执行 `sgdisk -n` 时会看到这个警告。**这是正常的，可以忽略。**

原因：我们把 gdisk 交叉编译成静态二进制时，用一个最小桩头文件绕过了 libuuid
（见 `tools/a3-gpt-rescue-build.md`），所以 `GUIDData::Randomize()` 走了
内置的 `rand()` 回退路径。

**影响范围**：
- 手工用 `-u` 指定的 UUID 不受影响（所以 userdata 的 GUID 保住了）
- 自动生成 UUID 的分区（如 data）会得到一个"不合规"的随机值
- 对 Linux 使用毫无影响；只有在 Windows 上挂载这类分区才可能有兼容问题

如果以后需要严格的 RFC 4122 UUID，重新编译时链接 libuuid 即可。

---

## 5. 救援 initramfs 的构成

`vendor/a3-gpt-rescue.cpio.gz`（2.3 MB），内容：

```
/bin/busybox                  1.9 MB  静态 aarch64，272 个 applet
/bin/mke2fs                   -> busybox
/sbin/sgdisk                  1.9 MB  静态 aarch64（gdisk 1.0.10）
/sbin/parted                  1.1 MB  静态 aarch64（parted 3.3）
/bin/cttyhack                 -> busybox
/init                         启动脚本
```

**启动脚本的关键点**（踩过多次坑）：

```sh
# 1. devtmpfs 挂到 /dev 会隐藏镜像里预建的节点，挂载后要重建
mount -t devtmpfs devtmpfs /dev
[ -c /dev/console ] || mknod /dev/console c 5 1

# 2. 起 USB 串口 gadget（ACM），否则主机上没有 COM 口
#    不设 bDeviceClass（复合设备保持 0）

# 3. 启动信息打到 /dev/console（屏幕）
exec 0</dev/console 1>/dev/console 2>&1

# 4. 最后 exec 到 ttyGS0 上的 shell
#    关键：用 <> 同时读写打开，不要经过 setsid / cttyhack 的复杂组合
exec sh -i <>/dev/ttyGS0 >/dev/ttyGS0 2>&1
```

**不要这样写**（会报 `can't access tty` 或者串口完全没反应）：

```sh
# 错误1：exec 到 shell 前把 stdio 锁死在 /dev/console
exec 0</dev/console 1>/dev/console 2>&1
exec /bin/cttyhack /bin/sh -i      # cttyhack 拿不到 ttyGS0，串口收不到东西

# 错误2：setsid 组合在 busybox 下不可靠
setsid sh -c 'exec sh -i <>/dev/ttyGS0 2>&1' &
```

---

## 6. 重新打包救援 boot

```sh
cd /opt/oppoa3

# 1. 准备 initramfs 目录
W=/opt/oppoa3/wv/gptinit
mkdir -p $W/{bin,sbin,proc,sys,dev,tmp,etc}

# 2. 放工具
cp /opt/oppoa3/wv/busybox-aarch64          $W/bin/busybox
cp /opt/oppoa3/wv/gptbuild/gptfdisk-1.0.10/sgdisk $W/sbin/sgdisk
cp /path/to/parted                          $W/sbin/parted
chmod 755 $W/bin/busybox $W/sbin/*

# 3. 建 applet 软链
cd $W
for a in sh ls cat echo mount mkdir rm cp mv ln sync sleep dmesg \
         dd vi grep sed awk cut tr poweroff reboot halt test \
         mke2fs cttyhack; do
    ln -sf busybox bin/$a
done
ln -sf ../sbin/sgdisk bin/sgdisk

# 4. 写 init（见上一节）

# 5. 打包
find . -print0 | cpio --null -ov --format=newc | gzip -9 \
    > /opt/oppoa3/vendor/a3-gpt-rescue.cpio.gz

# 6. 打 boot.img（用 A3_RAMDISK 覆盖默认的空 ramdisk）
export A3_ROOT=$PWD A3_OUT=$PWD/qdiag A3_IMG=$PWD/vendor
export A3_SCRIPTS=$PWD/script
export A3_DTB=$PWD/vendor/a3-v186-tgpio.dtb
export A3_RAMDISK=$PWD/vendor/a3-gpt-rescue.cpio.gz
bash script/a3-mkboot.sh gptrescue
```

打包脚本需要 `A3_RAMDISK` 支持（已加）：

```sh
RAMDISK="${A3_RAMDISK:-$IMG/a3-empty.cpio.gz}"
[[ -f "$RAMDISK" ]] || die "找不到 ramdisk: $RAMDISK"
...
    --ramdisk  "$RAMDISK" \
```

结构校验里空 ramdisk 的检查也放宽了：

```python
import os
_allow_big = os.environ.get("A3_RAMDISK") is not None
if _allow_big:
    chk(rs > 0, "ramdisk 非空（%d B，自定义 rescue initramfs）" % rs)
else:
    chk(rs < 4096, "ramdisk 是空的（%d B，不抢 root=）" % rs)
```

---

## 7. 刷入与进入

```powershell
fastboot flash boot gptrescue.img
fastboot reboot
```

启动后：

```
屏幕   显示横幅 + 分区表
串口   主机出现 COM 口（COM8，115200 8N1），shell 挂在这上面
```

**注意波特率**：USB ACM 是 115200；如果走物理 UART（ttyS0）则是 **921600**
（内核 cmdline 是 `console=ttyS0,921600n8`）。

---

## 8. 为什么不走 `fastboot boot`

`fastboot boot` 只临时启动，不改分区。但**执行过一次之后 boot 分区会被写保护**，
后续 `fastboot flash boot` 会失败。所以调整分区这种需要反复刷 boot 的操作，
应该一直用 `fastboot flash boot`。

---

## 9. 后续：恢复可用系统

`userdata` 已经格式化成空的 ext4（label `a3root`），需要重装 Debian：

```sh
# 1. 刷回正常的内核 boot（不带 rescue initramfs）
export A3_RAMDISK=   # 不设，用默认的空 ramdisk
bash script/a3-mkboot.sh normal
fastboot flash boot normal.img

# 2. 写入 rootfs（用 CI 或本地构建的 rootfs.img）
#    之前的方式是通过 USB 网络 dd 到 /dev/mmcblk0p44
```

**注意**：`data` 分区（`/dev/mmcblk0p47`）需要在系统里格式化后才能用：

```sh
mkfs.ext4 -L fnosdata /dev/mmcblk0p47
```

然后加到 `/etc/fstab`：

```
LABEL=fnosdata  /mnt/data  ext4  defaults,noatime  0 2
```

---

## 10. 完整备份（下次务必导出）

本次 GPT 备份只存在内存 `/tmp` 里，重启就没了。**下次做这类操作应该先导出**：

```sh
# 在救援 shell 里备份到 data 分区（不会被清）
sgdisk -b /dev/mmcblk0p47 ... # 不行，data 未格式化

# 更好的做法：备份后用串口把二进制传出来（base64）
sgdisk -b /tmp/gpt.bin /dev/mmcblk0
base64 /tmp/gpt.bin
# 把输出贴到本地保存，重启后可还原：
# base64 -d > /tmp/gpt.bin 然后 sgdisk -l /tmp/gpt.bin /dev/mmcblk0
```

或者直接记录 `sgdisk -p` 和每个分区的 `sgdisk -i N` 输出（本文档第 1 节就是）。

---

## 11. 回滚方法

如果新分区布局有问题，想恢复原来的单个 110.5 GiB userdata：

```sh
# 在救援 shell 里
sgdisk -d 47 /dev/mmcblk0                                    # 删 data
sgdisk -d 44 /dev/mmcblk0                                    # 删 userdata
sgdisk -n 44:12468224:244156382 \
       -t 44:8300 -c 44:userdata \
       -u 44:6FCE83A6-5273-4748-1145-C205EBB4B8AD \
       /dev/mmcblk0                                          # 恢复原样
partprobe /dev/mmcblk0
mke2fs -F -b 4096 -I 256 -L a3root /dev/mmcblk0p44
```

---

## 12. 经验总结

1. **重建分区必须用 `-u` 保留 unique GUID**，否则 `root=PARTUUID` 失效、系统起不来
2. **userdata 后面被 otp/flashinfo 挡住**，只能内部切分，不能追加
3. **缩小分区前必须先缩文件系统**。本次因为选择格式化重来所以跳过了，
   但正常情况下顺序必须是：`e2fsck -f` → `resize2fs` → 改 GPT
4. **busybox mke2fs 不支持 `-t ext4`**，用 `-b 4096 -I 256` 代替
5. **救援 initramfs 里必须有 USB 串口**，否则只能盯着屏幕手打命令
6. **`exec sh -i <>/dev/ttyGS0`** 是最可靠的串口 shell 启动方式
7. **`fastboot boot` 会触发 boot 写保护**，需要反复刷时用 `fastboot flash boot`
8. **GPT 备份要导出到设备外**，`/tmp` 是 tmpfs，重启即失