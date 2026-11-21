# A3 USB 网络模式（RNDIS / CDC-ECM）自动切换

> 这份文档整理自 Debian rootfs 那一套实现，供移植到飞牛 rootfs 时参考。

## 1. 为什么要两套

| 主机 | 认什么 |
| --- | --- |
| Windows | 只认 **RNDIS**（ECM 的 NDIS 适配器会报"设备无法启动 (代码 10)"） |
| 部分精简 Linux / NAS | 只有 `cdc_ether`，**只认 CDC-ECM** |

A3 默认开机是 **RNDIS + ACM（串口）**，接 Windows 即插即用。
要接只认 ECM 的 NAS 时，需要在 RNDIS 和 ECM 之间切换。

## 2. 三个脚本的分工

```
a3-usb-gadget              （rootfs 内置，开机建 RNDIS+ACM gadget）
        │
        ├─ a3-gadget-ecm      start/stop/status：真正在 RNDIS ↔ ECM 之间重建 gadget
        │
        └─ a3-usbnet-window   开机 180 秒决策窗口（systemd 调用）
                 └─ 超时 → 调 a3-gadget-ecm start
```

关键设计：**切换动作只在一个地方实现**（`a3-gadget-ecm`），
窗口脚本只做"决策 + 调用"，避免两份 gadget 创建逻辑走岔。

### 2.1 `a3-usb-gadget`（基础，RNDIS+ACM）

- 建 `/sys/kernel/config/usb_gadget/a3`
- **RNDIS 必须先于 ACM 加入 config**，否则主机会重新枚举、串口掉线
- 固定 MAC：host `02:00:a3:00:00:01`，dev `02:00:a3:00:00:02`
- 最后 `echo $UDC > $G/UDC` 绑定

### 2.2 `a3-gadget-ecm`（切换器）

```
a3-gadget-ecm start    →  卸载现有 gadget，建 a3ecm（纯 ECM），配 IP
a3-gadget-ecm stop     →  卸载 ECM，调 a3-usb-gadget 恢复 RNDIS+ACM
a3-gadget-ecm status   →  打印接口/carrier/IP/串口
```

ECM gadget 参数：

```
GECM=/sys/kernel/config/usb_gadget/a3ecm
bDeviceClass=0x02 (CDC)
serialnumber=PADT00  manufacturer=OPPO  product="A3 ECM"
functions/ecm.usb0   dev_addr =02:00:a3:00:01:02
                     host_addr=02:00:a3:00:01:01
IP_DEV=10.42.1.2/24     （NAS 侧自己配 10.42.1.1/24）
```

### 2.3 `a3-usbnet-window`（决策窗口）

```
开机 → a3-usb-gadget 建 RNDIS+ACM
     → a3-usbnet-window window 开始 180 秒计时（每 5 秒读一次 /etc/a3-usbnet.conf）

   期间 KEEP=rndis  → 保持 RNDIS，退出
   期间 KEEP=ecm    → 立即切 ECM
   180 秒无写入     → 自动切 ECM（并写 KEEP=ecm 记录）
```

## 3. 状态文件与命令

配置文件 `/etc/a3-usbnet.conf`：

```
KEEP=rndis     # 保持 RNDIS（开机不再自动切 ECM）
KEEP=ecm       # 已切到 ECM（记录用）
(无 KEEP 行)   # 下次开机仍走 180 秒窗口
```

```sh
a3-usbnet-window keep      # 窗口期内：保持 RNDIS
a3-usbnet-window now       # 立即切 ECM
a3-usbnet-window rndis     # 切回 RNDIS
a3-usbnet-window status    # 看 gadget / 接口 / IP / 串口 / 服务状态

a3-gadget-ecm start|stop|status     # 底层切换器
```

## 4. systemd 单元

`a3-usbnet.service`（可选安装，`install-a3-usbnet.sh` 装它）：

```ini
[Unit]
Description=A3 USB network mode (RNDIS window then ECM)
After=a3-usb-gadget.service
Wants=a3-usb-gadget.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/a3-usbnet-window window
Restart=no

[Install]
WantedBy=multi-user.target
```

`a3-usb-gadget.service` 是 `RemainAfterExit=yes` 的 oneshot；
窗口脚本切 ECM 前会 **先 `systemctl stop a3-usb-gadget.service`**，
否则它的 active 状态会影响后续 `systemctl restart`。

## 5. 踩过的坑（重要）

1. **ECM 接口建好后必须 `ip link set up`**
   否则主机侧看到 `NO-CARRIER`，ping 报 `Destination Host Unreachable`。

2. **接口名不固定**（`usb0` / `usb1` / `enx...`）
   按 **MAC 匹配**最可靠：
   ```sh
   for i in /sys/class/net/*; do
       [ "$(cat $i/address)" = "02:00:a3:00:01:02" ] && echo $(basename $i)
   done
   ```

3. **RNDIS 必须排在 ACM 前面**
   否则主机重新枚举，`/dev/ttyGS0` 掉线。

4. **切换 gadget 会重置 USB，SSH 必断**
   所以脚本把关键提示同时写到 `/dev/console`（手机屏幕），
   接在 NAS 上没有 SSH 时也能看到进度。

5. **RNDIS 与 ECM 的 MAC 要分开**
   RNDIS 用 `02:00:a3:00:00:0x`，ECM 用 `02:00:a3:00:01:0x`，
   主机侧不会把两套当成同一块网卡。

## 6. 移植到飞牛 rootfs

飞牛 rootfs 目前只有 **RNDIS+ACM**（`fnnas/build-rootfs-fnnas.sh` 的 USB gadget 段），
没有 ECM 切换。要移植的话：

1. 把 `script/a3-gadget-ecm.sh`、`script/a3-usbnet-window.sh` 装到
   `/usr/local/sbin/`（去掉 `.sh` 后缀，`chmod 755`）
2. 装 `a3-usbnet.service`（`After=a3-usb-gadget.service`）
3. 注意飞牛 `/dev/console` 是 systemd 管理的，`sayscreen` 写入可能无输出，
   可改成写 `/dev/tty0` 或 `logger`
4. 飞牛的 USB gadget 服务名可能不同，`do_switch_ecm` 里的
   `systemctl stop a3-usb-gadget.service` 要换成实际单元名
