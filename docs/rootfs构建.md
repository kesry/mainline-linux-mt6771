# rootfs 构建文档

本文说明设备上 Linux 根文件系统放在哪、怎么制作、怎么刷入和扩容。

## 1. 分区布局

```
boot        /dev/mmcblk0p35     内核 + 设备树（Android boot 格式）
userdata    /dev/mmcblk0p44     113 GB，Linux 根文件系统放在这里
vendor      /dev/mmcblk0p41     1328 MB，厂商固件来源（触摸/ WiFi 固件在这里）
```

根文件系统不在单独分区，而是整个 userdata 分区格式化成 ext4。
内核 cmdline 通过 PARTUUID 指定根分区：

```
root=PARTUUID=6fce83a6-5273-4748-1145-c205ebb4b8ad
```

**boot 和 rootfs 是两件独立的事**：只刷 boot 不刷 userdata，设备会进入
"内核启动但找不到根文件系统"的状态（表现为黑屏、卡住、无网络）。
切换到 Android 再切回来时，userdata 会被 Android 重写，必须重新刷 rootfs。

## 2. 基础镜像

可用基础镜像是从 Debian 13 (trixie) 最小系统做出来的 ext4：

```
文件名   a3-rootfs-wifi-ready.ext4
大小     536870912 字节（512 MB）
特点     刷入后由 a3-growroot.service 自动扩容到整个分区
```

刷入方式（**会清空 userdata 上的所有数据**）：

```sh
fastboot flash userdata a3-rootfs-wifi-ready.ext4
```

或者在 Linux 侧直接写：

```sh
dd if=/root/a3-rootfs-wifi-ready.ext4 of=/dev/mmcblk0p44
```

## 3. 自动扩容

首次启动由 `a3-growroot.service` 做一次性扩容：

```sh
[Unit]
ConditionPathExists=/etc/a3-growroot.once
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "rm -f /etc/a3-growroot.once; \
  i=0; while [ $i -lt 30 ]; do [ -b /dev/mmcblk0p44 ] && break; sleep 1; i=$((i+1)); done; \
  exec resize2fs /dev/mmcblk0p44"
```

- 条件文件 `/etc/a3-growroot.once` 存在时才执行，执行完自己删掉，不会重复
- 扩容后根分区为 109 GB 可用（`df -h /` 可验证）
- 制作新的基础镜像时**不要**把 `/etc/a3-growroot.once` 删掉，否则新镜像不会扩容

## 4. 系统组成（当前状态）

```
基础系统   Debian GNU/Linux 13 (trixie)
桌面       phosh 0.46（手机桌面）+ squeekboard（屏幕键盘）
字体       fonts-noto-cjk + fonts-noto-cjk-extra（80 个 CJK 字体）
网络       usb0（RNDIS）静态地址 10.42.1.2/24，网关 10.42.1.1，DNS 223.5.5.5
软件源     http://mirrors.ustc.edu.cn/debian（用 http 不用 https，USB 网卡上 TLS 很慢）
```

安装桌面的关键步骤与坑：

```sh
apt-get install -y --no-install-recommends phosh squeekboard phosh-mobile-settings kbd
usermod -aG video,render,input,audio kesry
systemctl stop gdm && systemctl disable gdm
systemctl enable --now phosh.service
```

```
坑 1：必须装 kbd。phosh.service 里有 ExecStartPost=chvt 7，
      缺 chvt 会 status=203/EXEC 让整个服务失败，日志看起来像 phosh 起不来。
坑 2：phosh.service 用 User=1000 + TTYPath=/dev/tty7，控制台直接启动，不需要 greeter。
坑 3：切换后如果会话立刻 Deactivated，日志出现
      "Transaction for gnome-session-wayland@phosh.target/start is destructive"，
      是上一个会话残留的 systemd 事务冲突，重启一次即可。
坑 4：apt 的包索引锁可能被 packagekitd 占用，先 systemctl stop packagekit。
```

## 5. 中文字体

```sh
apt-get install -y --no-install-recommends fonts-noto-cjk fonts-noto-cjk-extra
fc-list | grep -ci cjk                 # 应为 80 左右
fc-match "sans:lang=zh-cn"             # 应为 Noto Sans CJK SC
```

## 6. 桌面相关设置（用户 kesry）

必须带上正确的环境变量，否则 dconf 会因为找不到 `XDG_RUNTIME_DIR` 写不进去：

```sh
E="HOME=/home/kesry XDG_RUNTIME_DIR=/run/user/1000 \
   DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus"

runuser -u kesry -- env $E gsettings set org.gnome.desktop.session idle-delay 0
runuser -u kesry -- env $E gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
```

`idle-delay=0` 的作用是**临时规避**问题：面板断电后触摸需要重新初始化，
目前自愈逻辑还没定稿，所以先不让它自动熄屏。这是技术债，见
`docs/仓库工作流.md` 的技术债表。

## 7. 开机时间

```
改动前  内核 2.1 s + 用户态 37.6 s = 39.7 s
改动后  内核 2.0 s + 用户态  9.9 s = 12.0 s
```

原因是 `a3-bootstate.service` 里有一句 `ExecStartPre=/bin/sleep 30`，
压在桌面初始化期间抢 CPU/IO。已改成 `sleep 2`。

检查开机用时：

```sh
systemd-analyze
systemd-analyze blame | head
```

## 8. 从设备上备份当前 rootfs

在 Linux 里运行、且不能写正在使用的分区，所以要么从另一台机器写，
要么先重启进 fastboot 用 `fastboot getvar` 之类的只读手段确认大小后，
用 dd 从另一个系统的视角读取。简单可靠的做法是：

```sh
# 在设备上把根分区压成镜像（只读挂载或直接 dd 后压缩）
dd if=/dev/mmcblk0p44 bs=4M | gzip -1 > /root/rootfs-backup.img.gz
```

备份产物很大（实际占用 4~5 GB），只在需要时做，不要放进仓库。

## 9. 预置账号

CI 构建出的镜像里有两个账号，都带密码：

| 用户 | 密码 | 权限 |
| --- | --- | --- |
| `root` | `a3root` | 完整 root |
| `kesry` | `kesry` | 属于 video/render/input/audio/sudo，sudo 免密 |

sshd 已放开 `PermitRootLogin yes` 和 `PasswordAuthentication yes`，主机名 `PADT00`。

**坑：不要用 `passwd -d root`。** 它把 root 密码清成空，而 sshd 默认
`PermitEmptyPasswords no`，结果是 root 完全无法用 ssh 登录，日志只报
`Access denied`，看不出是空密码导致的。要清空密码必须同时改
`PermitEmptyPasswords yes`，但更安全的做法是直接设一个密码。
