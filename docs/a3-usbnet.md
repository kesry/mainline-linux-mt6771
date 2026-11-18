# USB 网络模式（RNDIS / ECM）

> **这是可选组件，不在默认 rootfs 里。**
> 默认 rootfs 只启用 `a3-usb-gadget.service`（RNDIS + ACM），Windows 和普通
> Linux 都能用。只有需要接「精简内核、没有 `rndis_host` 驱动」的 NAS 时，
> 才需要安装本文描述的服务。
>
> 安装：在设备上执行 `install-a3-usbnet`
> 卸载：`install-a3-usbnet --remove`

本文说明 OPPO A3 的 USB 网络实现、开机自动切换策略、以及手动干预方式。

## 1. 为什么需要两种模式

设备的 USB 网络由 **configfs gadget** 实现。问题在于主机侧驱动差异：

| 协议 | Windows | Linux / NAS |
| --- | --- | --- |
| **RNDIS** | ✅ 原生支持（“远程 NDIS 兼容设备”） | ⚠️ 需内核带 `rndis_host`，精简内核常常没编 |
| **CDC-ECM** | ❌ 无驱动，枚举失败 | ✅ 标准协议，几乎都带 `cdc_ether` |

实测结果：

```
Windows：
  RNDIS  → 出现「以太网 21」，能 ping 通
  ECM    → 设备管理器报错，网卡和串口一起消失

某些 NAS（精简内核）：
  RNDIS  → 完全不出现网络接口
  ECM    → 出现 enx0200a3000101，能通
```

## 2. 开机策略：RNDIS 窗口 + 超时切 ECM

这是当前默认行为。

```
开机
 └─ a3-usb-gadget.service 建立 RNDIS + ACM
     └─ a3-usbnet.service 开始 180 秒计时
         ├─ 期间写入 KEEP=rndis  → 保持 RNDIS，退出
         ├─ 期间写入 KEEP=ecm    → 立即切 ECM
         └─ 180 秒无动作         → 自动切 ECM
```

意义：

```
插到 Windows 调试 → 3 分钟内执行 a3-usbnet-window keep → 一直是 RNDIS
插到 NAS         → 什么都不做                  → 3 分钟后自动 ECM
```

每次开机计时都会重置（脚本会先删掉配置里旧的 `KEEP=` 行）。

## 3. 配置文件

`/etc/a3-usbnet.conf`

```sh
KEEP=rndis     # 保持 RNDIS，不切 ECM
KEEP=ecm       # 切 ECM
```

文件**不存在**或**没有 KEEP 行** = 等满 3 分钟后自动切 ECM。

## 4. 命令行

```sh
a3-usbnet-window keep   # 保持 RNDIS（写 KEEP=rndis，服务立刻识别并退出）
a3-usbnet-window now    # 立即切 ECM（写 KEEP=ecm 并执行切换）
a3-usbnet-window rndis  # 从 ECM 切回 RNDIS
a3-usbnet-window status # 查看状态
```

所有输出同时写到 `/dev/console`，所以**没有 SSH 也能从手机屏幕看到结果**。

## 5. Windows 上通过串口操作

**前提**：串口只在 RNDIS 模式下存在。

```
设备管理器 → 端口 → USB 串行设备 (COM5)
```

用 PuTTY 连 COM5（115200, 8-N-1，无流控），按回车出 login，`root/root` 登录，然后执行上面的命令。

## 6. 网络参数

```
设备侧 IP       10.42.1.2/24
设备侧 MAC      RNDIS: 02:00:a3:00:00:02
                ECM:   02:00:a3:00:01:02
主机侧期望 MAC  RNDIS: 02:00:a3:00:00:01
                ECM:   02:00:a3:00:01:01
```

### NAS 侧（以 ECM 为例）

```sh
# 接口名由 MAC 生成
ip link set enx0200a3000101 up
ip addr add 10.42.1.1/24 dev enx0200a3000101
ping -c3 10.42.1.2
```

**必须 `ip link set up`**，否则接口是 `NO-CARRIER`，包发不出去
（表现为 `Destination Host Unreachable`）。

持久化：

```ini
auto enx0200a3000101
iface enx0200a3000101 inet static
    address 10.42.1.1/24
```

### Windows 侧

RNDIS 模式下通常自动获取。手动配置：

```powershell
New-NetIPAddress -InterfaceAlias "以太网 21" -IPAddress 10.42.1.1 -PrefixLength 24
```

## 7. 组件

默认 rootfs 自带（必需）：

```
/usr/local/sbin/a3-usb-gadget               建立 RNDIS + ACM
/etc/systemd/system/a3-usb-gadget.service   开机建立 gadget
```

可选安装后才有：

```
/usr/local/sbin/a3-usbnet-window            窗口计时 + 调用 ECM 切换
/etc/a3-usbnet.conf                         KEEP 配置
/etc/systemd/system/a3-usbnet.service       开机起 180 秒窗口
```

服务关系：

```
a3-usb-gadget.service  enabled   → 先跑，建立 RNDIS+ACM
a3-usbnet.service      enabled   → After=a3-usb-gadget，再跑计时
```

## 8. 已验证的 ECM 配置（重要）

ECM gadget 的创建逻辑直接调用 `/usr/local/sbin/a3-gadget-ecm`，
**不要重写它**。这套参数是实测能枚举成功的：

```sh
idVendor        0x1d6b
idProduct       0x0105
bDeviceClass    0x02      # 必须设
bDeviceSubClass 0x00
bDeviceProtocol 0x00
dev_addr        02:00:a3:00:01:02
host_addr       02:00:a3:00:01:01
functions       只有 ecm.usb0（不放 acm）
```

切换时的正确做法（关键）：

```sh
# 只解绑 UDC，不删除 gadget 目录
for g in /sys/kernel/config/usb_gadget/*; do
    [ -e "$g/UDC" ] && echo "" > "$g/UDC"
done
sleep 1
# 然后 mkdir 新 gadget 并绑定
```

**反例（我踩过）**：先 `rmdir` 逐个删除旧 gadget 的所有目录再创建新的。
这会让 UDC 处于不干净状态，结果新 gadget 绑定失败，主机侧连
"未知设备"都不出现。

验证记录：

```
2026-11-19 04:48 测试结果
窗口 180 秒到期后：
  a3     UDC=（已解绑）
  a3ecm  UDC=11201000.usb3      ← 绑定成功
Windows 侧：
  窗口期内  以太网 21 (NDIS) + COM5 都在
  切换之后  A3 ECM 出现（Status=Error，Windows 无驱动）
            串口消失（ECM 配置不含 ACM）
```

## 9. 踩过的坑（重要）

### 坑 1：ECM 配置里加 ACM 串口救不了命

一度尝试在 ECM gadget 里同时放 `ecm.usb0` + `acm.usb0`，期望“NAS 用网络、
Windows 用串口”。**实测失败**：

```
Windows 对 ECM 无驱动 → 整个复合设备枚举失败
                     → 连累同一配置里的 ACM 一起消失
```

所以 **ECM 配置里不放 ACM**，切过去就是彻底没有串口。这就是为什么需要
3 分钟窗口——给你留出阻止切换的时间。

### 坑 2：设 bDeviceClass 会毁掉复合枚举

早期脚本设了：

```sh
echo 0x02 > "$G/bDeviceClass"    # 错
```

复合设备必须保持在接口层定义（`bDeviceClass=0`），设成 `0x02` 会让 Windows
认为整机是单一 CDC 功能，枚举失败。原 `a3-usb-gadget` 脚本不设这几项，是对的。

### 坑 3：服务阻塞 network-pre.target

早期 unit 写成：

```ini
Before=network-pre.target
Type=oneshot
TimeoutStartSec=300
ExecStart=... sleep 180
```

180 秒的 oneshot 卡住 `network-pre.target`，`systemd-networkd` 起不来，
**连 RNDIS 都没有 IP**。现在改成 `Type=simple` + 后台计时，不阻塞网络。

### 坑 4：ECM 接口必须 up 才有 carrier

```sh
cat /sys/class/net/<iface>/carrier
```

`0` 就说明没 up。脚本里会循环等 `carrier=1` 最多 6 秒，然后才配 IP。

### 坑 5：串口看起来“卡死”

`serial-getty@ttyGS0` 在等输入，主机侧工具不发回车就看着像卡死。
按一下回车应该出 `PADT00 login:`。

## 10. 排查

### 看状态

```sh
a3-usbnet-window status
```

```
=== 配置 ===
  /etc/a3-usbnet.conf
    KEEP=rndis
=== gadget ===
  a3  UDC=11201000.usb3  funcs=acm.usb0 rndis.usb0
=== 网络接口 ===
  usb0 mac=02:00:a3:00:00:02 carrier=1 IP=10.42.1.2/24
=== 串口 ===
  /dev/ttyGS0 存在
```

### Windows 看不到网卡

```sh
# 串口上执行
a3-usbnet-window status    # 确认是不是在 ECM 模式
a3-usbnet-window rndis     # 切回 RNDIS
```

### NAS 看不到网卡

```sh
# NAS 上确认驱动
lsmod | grep -E "rndis_host|cdc_ether"
```

两个都没有 → 需要另想办法。

### 恢复出厂状态（重刷后）

重刷 rootfs 后 gadget 配置回到 `a3-usb-gadget`（RNDIS+ACM），
`a3-usbnet.service` 需要重新安装。

## 11. 安装与卸载

### 安装

把 `a3-usbnet-window.sh`、`a3-gadget-ecm.sh` 和 `install-a3-usbnet.sh`
放到同一目录，然后：

```sh
sh install-a3-usbnet.sh
```

或者直接：

```sh
install-a3-usbnet
```

脚本会：

```
① 检查 a3-usb-gadget 是否存在（依赖）
② 检查 configfs 是否可用
③ 安装 /usr/local/sbin/a3-usbnet
④ 写入服务单元并 enable
⑤ 创建 /etc/a3-usbnet.conf（不含 KEEP 行）
```

不会立即改动当前 gadget 状态，只影响下次开机。
想立即生效：`systemctl start a3-usbnet.service`。

### 卸载

```sh
install-a3-usbnet --remove
```

移除服务、脚本和配置。如果当前处在 ECM 模式，需要重启才能回到 RNDIS。

### 为什么做成可选

```
· 大多数场景（开发机是 Windows）用不到 ECM
· 这个服务会改变开机行为，默认不该带
· 切到 ECM 后 Windows 上完全失联，误装有风险
```

## 12. 已知限制

```
· RNDIS 和 ECM 不能同时存在（一个 gadget 只能绑一种网络功能）
· 切到 ECM 后 Windows 上没有任何通道（网卡和串口都没），
  只能靠 3 分钟窗口期阻止，或从 NAS 侧 SSH 进去切回
· 切换会触发 USB 重新枚举，SSH 会断（正常现象）
· 3 分钟窗口对插 NAS 的场景有延迟，想省掉就设 KEEP=ecm 并重启
```