# 手动编译内核与上传

本文是日常改内核时的操作步骤：编译、打包、刷机、验证。

## 0. 环境

```
构建机登录   ssh -p 36282 root@192.168.1.71
设备地址     10.42.1.2（USB 网卡 usb0，网关 10.42.1.1）
内核源码     /opt/oppoa3/kernel-src
编译输出     /opt/oppoa3/qdiag
镜像目录     /opt/oppoa3/images
```

## 1. 改代码

```sh
cd /opt/oppoa3/kernel-src
# 编辑源码...
```

要改内核配置时：

```sh
K=/opt/oppoa3/kernel-src
O=/opt/oppoa3/qdiag
cd $K && ./scripts/config --file $O/.config --set-val 选项名 y
make -C $K O=$O olddefconfig        # 必须跑，否则新选项不生效
```

## 2. 编译（增量，不要全编）

```sh
K=/opt/oppoa3/kernel-src
O=/opt/oppoa3/qdiag
make -C $K O=$O ARCH=arm64 -j8 Image 2>&1 | tail -5
```

**不要** `rm -f` 目标文件或 `make clean` 强制全编——全编在这台机器上要很久，
而且没有必要。改一个文件只会重编那一个。

产物：`$O/arch/arm64/boot/Image`

## 3. 打包

```sh
cd /opt/oppoa3
A3_DTB=/opt/oppoa3/images/a3-v186-tgpio.dtb ./a3-mkboot.sh a3tXX
```

输出：`/opt/oppoa3/images/a3tXX.img`，并打印 md5。

设备树选哪个见 `docs/boot打包.md` 的表格。**触摸可用的版本用 `a3-v186-tgpio.dtb`**。

## 4. 传到设备

构建机上的镜像要先落到能访问设备的机器，再传到设备。当前有两条路：

```sh
# 路 1：构建机 → Windows 中转 → 设备（适用于 fastboot 刷机）
#   构建机：镜像在 /opt/oppoa3/images/
#   Windows：pscp 拉下来，再用 fastboot flash boot

# 路 2：设备在线时，Windows 中转后 scp 到设备 /root/
pscp -pw root a3tXX.img root@10.42.1.2:/root/a3tXX.img
```

## 5. 刷机

### 5.1 先判断 boot 分区可写

```sh
dmesg -c > /dev/null
dd if=/dev/zero of=/dev/mmcblk0p35 bs=512 count=1
sync; sleep 1
dmesg | grep -c 'I/O error'         # 0 = 可写
```

### 5.2 可写 → dd

```sh
dd if=/root/a3tXX.img of=/dev/mmcblk0p35
sync
# 校验（必须做）
dd if=/dev/mmcblk0p35 iflag=direct 2>/dev/null | head -c 33554432 | md5sum
md5sum /root/a3tXX.img
```

两个 md5 一致后再重启：

```sh
sync; reboot
```

### 5.3 写保护 → fastboot

设备需要人工长按电源进 fastboot（这一步目前只能手动）：

```sh
fastboot flash boot a3tXX.img
fastboot reboot
```

## 6. 重启后验证

等 40~60 秒再连，设备网络需要时间起来：

```sh
ssh -o ConnectTimeout=15 root@10.42.1.2 hostname
```

逐项确认：

```sh
uname -r                                      # 内核版本号应变化
systemd-analyze | head -1                     # 开机耗时
cat /sys/class/drm/card0-DSI-1/dpms           # 显示是否 On
grep -E '^N:|^H:' /proc/bus/input/devices     # 触摸设备是否注册
systemctl is-active phosh.service             # 桌面
dmesg | grep -iE 'nova-nt36672|A3 CONSYS'     # 触摸/无线
```

## 7. 出问题了

```
1. 先刷回稳定镜像（images/ 里保留的那份），恢复可用状态
2. 记录现象：黑屏 / 无网络 / 卡死 / dmesg 里的报错行
3. 一次只改一个变量重试
4. 同一个失败出现两次就停下来，从最底层找最早出错的地方
```

**设备卡死后只能人工长按电源 15 秒**，所以刷机前一定要准备好可回退的镜像。

## 8. 当前可用的稳定镜像

```
a3t54.img   md5 45972b4775d9048248b70e00d26919aa
            phosh + 触摸可用 + 中文字体 + 不自动熄屏
a3t63.img   在 a3t54 基础上修了触摸解析越界和幻影过滤（未长期验证）
```
