# WiFi / 蓝牙（MT6631 / CONSYS）文档

本文记录 OPPO A3 上无线部分的硬件结构、已经做的工作、当前状态和后续路线。

## 1. 硬件与软件结构

```
主控      MT6771
连接芯片  MT6631（WiFi 2.4/5G + BT + GPS + FM）
总线      CONSYS 子系统挂在 0x18070000，通过 BTIF / WMT 与主控通信
内存      保留区 consys-reserve-memory，2 MB，nomap 不可复用
```

CONSYS 不是一个普通外设，它是一整套子系统：

```
CONSYS（连接子系统）
 ├── 电源与时钟门控（CONN_PWR_CON / INFRA_CG / SPM）
 ├── BTIF  —— 主控与连接芯片之间的数据通道（DMA）
 ├── WMT   —— 控制通道，负责下发固件、切换模式（WiFi/BT/GPS）
 └── 各功能固件：WIFI_RAM_CODE_6759、BT 固件、GPS
```

**关键点：WiFi 不是"加载一个驱动就能出 wlan0"**。必须先把 CONSYS 上电、
解除时钟门控，再通过 WMT 把固件下载进 MT6631 的 RAM，之后 MAC 侧才能工作。
Linux 主线没有这套厂商栈，所以这部分要自己搭或者移植。

## 2. 设备树

```dts
consys@18070000 {
    compatible = "mediatek,mt6771-consys";
    /* 中断、时钟、reg 见实际 DTS */
};

reserved-memory {
    consys-reserve-memory {
        compatible = "mediatek,consys-reserve-memory";
        size = <0x200000>;      /* 2 MB */
        no-map;
    };
};
```

启动日志确认保留区已生效：

```
OF: reserved mem: 0x00000000bfc00000..0x00000000bfdfffff (2048 KiB)
    nomap non-reusable consys-reserve-memory
```

## 3. 我们已经完成的（内核侧）

我们自己的代码（都在仓库补丁里）：

| 文件 | 作用 |
| --- | --- |
| `arch/arm64/kernel/a3-consys-power.c` | 早期给 CONSYS 上电、等 PWR_ACK、解除时钟门控 |
| `drivers/net/wireless/mediatek/a3-consys.c` | CONSYS 设备节点与资源管理 |
| `drivers/net/wireless/mediatek/a3-wmac.c` | WiFi MAC 胶水层（netdev 注册、固件加载入口） |
| `drivers/net/wireless/mediatek/a3-wmt-bridge.c` | WMT 控制通道桥接 |
| `drivers/net/wireless/mediatek/a3-wmt-stubs.c` | 厂商栈缺失符号的桩实现 |

上电已经验证成功，启动日志：

```
A3 CONSYS: CONN_PWR_CON = 0x00000112
A3 CONSYS: PWR_ACK ok (ack=0x00dfffde ack_s=0x00d07fde)
A3 CONSYS: CONN_PWR_CON now 0x0000010d
A3 CONSYS: btifc=1 apdmac=1 (STA0=0x00000000 STA1=0x00000000)
A3 CONSYS: INFRA2_CG_STA now 0x00000000 (cqdma ungated=1)
```

也就是说：**供电与时钟门控这段是通的**。

## 4. 当前状态

```
✅ CONSYS 上电、PWR_ACK、时钟门控解除，全部在启动日志里可见
✅ 2 MB 保留内存正确
✅ WiFi 固件文件已就位：/lib/firmware/WIFI_RAM_CODE_6759、WMT_SOC.cfg
❌ 没有 wlan0 接口（ip link 只有 lo / sit0 / usb0）
❌ 固件尚未通过 WMT 下载到 MT6631
❌ BT 同样未打通
```

## 5. 为什么不把厂商无线代码放进仓库

厂商无线/BT 栈有 **909 个文件、约 32 MB**（`drivers/net/wireless/mediatek/btif`、
`mt66xx` 等），是联发科版权代码，不适合放在本仓库：

- 仓库会被撑到几十 MB，每次 clone 都慢
- 版权状态不清楚
- 与主线风格差异极大，放在 patch 里无法 review

例外：`mtk_wcn_cmb_stub.h` 和 `wmt_build_in_adapter.h` 两个小头文件**保留在仓库里**，
因为我们的 `a3-wmt-bridge.c` 直接 include 了它们；没有它们补丁无法编译。

因此 `kernel-src/.gitignore` 排除了这些目录（`gen3` `gen4m` `wmt` `wmt-adaptor`），
改为**用脚本从厂商源码树导入**：

```sh
# 从厂商 8.1 内核源码导入无线栈（只需做一次）
script/import-vendor-wireless.sh /opt/oppoa3/A3-8.1-kernel-source-master
```

导入后 `a3-wmac.c` 等胶水层才能链接到完整实现。

## 6. 后续路线（按可行性排序）

```
1. 先把 WMT 控制通道跑通：能读 WMT 版本号、能发命令
2. 通过 WMT 下载 WIFI_RAM_CODE_6759 到 MT6631，回读校验
3. 建立 BTIF DMA 通道，注册 netdev（wlan0）
4. 接 cfg80211/mac80211 或厂商 wext 接口，起 hostapd/wpa_supplicant
```

第 1、2 步是硬骨头，建议先用厂商栈验证（即导入 btif 代码并让它编译通过），
再逐步替换成主线风格实现。**不要一上来就自己写 WMT 协议**，这部分厂商代码
已经把时序和握手都写死了，照抄能省很多时间。

## 7. 已知固件位置

```
运行中的根文件系统： /lib/firmware/WIFI_RAM_CODE_6759
                     /lib/firmware/WMT_SOC.cfg
厂商 vendor 分区：   /vendor/firmware/ 下的 WIFI_RAM_CODE_6759、
                     WMT_SOC.cfg、WMT_SOC_17175.cfg
```

vendor 分区可以直接在 Linux 下挂载读取（约 1328 MB），不需要进 Android。
换机型或换面板批次时，注意 `WMT_SOC.cfg` 有 `17175` 和 `17331` 两种板型版本。
