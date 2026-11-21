# 飞牛 FnNAS 在 OPPO A3（MT6771）上的移植现状总览

> 最后更新：2026-11-21
> 内核：`6.12.115-gf453fd39a8e8-dirty`（主线 + A3 设备树 + ZFS 内建）

## 一句话结论

飞牛 fnOS 已经能在 OPPO A3 的主线 6.12 内核上正常运行，**存储池、音乐库授权、网页上传/删除、远程挂载复制、显示、ZFS 都已打通**。
兼容性主要靠**用户态 LD_PRELOAD 兼容层 + 一个小型内核模块**实现，**不是完整的飞牛私有内核补丁逆向移植**（见文末“已知限制”）。

---

## 1. 分层架构

```
┌─────────────────────────────────────────────────┐
│ 飞牛用户态（trim / filemanager / uploadsrv / …） │
└────────────────┬────────────────────────────────┘
                 │ 依赖飞牛私有内核语义：
                 │  ① system.trim_acl xattr
                 │  ② 负数伪 dirfd 的 *at 系统调用
                 │  ③ /dev/trim-trashbin
┌────────────────┴────────────────────────────────┐
│ 兼容层（我们的实现）                              │
│  · trim_acl_shim.ko   → ① xattr handler + ③ 设备  │
│  · fnacl_faccessat_hook.so → ② *at 系列 hook      │
│    （LD_PRELOAD 注入 14 个服务）                   │
└────────────────┬────────────────────────────────┘
                 │ 标准 Linux 系统调用
┌────────────────┴────────────────────────────────┐
│ 主线内核 6.12 + ZFS(builtin) + DTB(tgpio)         │
└─────────────────────────────────────────────────┘
```

---

## 2. 已实现并验证的功能

| 功能 | 状态 | 实现 |
| --- | --- | --- |
| 显示（不再卡第一屏） | ✅ | `A3_DTB=a3-v186-tgpio.dtb`（含 `panel@0`），`mediatek-drm` 正常 probe |
| ZFS | ✅ | OpenZFS 2.2.7 `copy-builtin`（`CONFIG_ZFS=y`），`zpool` 正常 |
| 存储池创建/挂载 | ✅ | mdadm lockless wrapper + mount trimacl 过滤 + QUOTA/MD/DM 配置 |
| 音乐库授权 | ✅ | trim_acl_shim xattr + faccessat hook；重启后验证通过 |
| 网页上传单文件 | ✅ | uploadsrv 装 faccessat hook + trim.key 重生成 + 登录勾选“保持登录”(osrt) |
| 上传目录 | ✅ | hook 扩展 `unlinkat/renameat2/statx/utimensat` + mode/flags 清洗 |
| 删除文件 / 删除目录（含多选、中文路径） | ✅ | 同上；修掉“路径被当指针”的 SIGSEGV |
| SFTP 远程挂载复制 | ✅ | sshfs wrapper 注入 `umask=022`（sshfs 3.7.3 不支持 file_mode/dir_mode） |
| mediasrv（音乐/影视取流） | ✅ | 软解 mediasrv + `/var/run/mediasrv.socket` 别名自愈 |
| 内核 `=m` 模块 | ✅ | 441 个 `.ko` 打进 rootfs（`pwm-mtk-disp` 等） |
| CI 配置固化 | ✅ | `patch/0007` 把 ZFS/BTRFS/QFMT/MD/DM 写进 `a3_defconfig` |
| 一键构建 | ✅ | `script/a3-fnnas-all.sh`（全流程 / `--boot-only` / `--rootfs-only`） |
| 开机自启 | ✅ | `a3-trimacl-shim.service` + 14 个 drop-in + mediasrv alias drop-in |

---

## 3. 三个核心兼容组件

### 3.1 `fnnas/kmod/trim_acl_shim.c`（内核模块）

两个职责：

1. **`system.trim_acl` xattr handler**
   - 注册 `.name="system.trim_acl", .prefix=NULL` 的 handler（`prefix=NULL` 是关键，否则 `xattr_resolve_name()` 返回 EINVAL）
   - 读写转发到 `user.trim_acl`
   - 打补丁方式：替换目标 sb 的 `s_xattr` 数组（幂等、可卸载恢复）
   - 解决：音乐/影视库授权“无写入权限”、多用户 ACL 读取失败

2. **`/dev/trim-trashbin` misc 字符设备**
   - 让 `trim_trashbind` 能 `open()` 成功（此前 ENOENT 导致每 5 秒崩溃重启，计数到 300+）
   - `read()` 返回 0（EOF）——**没有事件流**，见已知限制

### 3.2 `fnnas/ld-hooks/fnacl_faccessat_hook.c`（LD_PRELOAD）

飞牛把私有语义塞进**负数伪 dirfd**；主线内核当真实 fd → `EBADF(9)`。

| 函数 | 伪 dirfd | 用途 |
| --- | --- | --- |
| `faccessat` | -21586…-21575 | 权限判定（libnperm，11 个 trim_syscall） |
| `unlinkat` | -7125 | 删除文件 |
| `renameat2`/`statx`/`utimensat` | -7125 等 | 改名/属性/时间戳 |

关键实现点（都是踩坑换来的）：

- **参数可能是 struct 指针，也可能就是路径串**：
  - 只有 `faccessat` 需要判断“首字段是否为路径指针”
  - 判据：用户态地址 `< 2^48`；任意 8 字节 ASCII ≥ `0x2020202020202020` ≫ 2^48，据此排除误判
  - 曾因把 `"vol1/100"` 当地址 `0x3030312f316c6f76` 解引用导致 `filemanager` SIGSEGV（多选删除卡住的真因）
- **`faccessat` 的 `mode/flags` 必须清洗**：飞牛夹带 `mode=0x8` 私有位，直接透传 `faccessat2` 返回 `EINVAL(22)`（上传目录 4352 的真因）
- 非 ASCII（中文）路径必须原样保留，不能做指针猜测
- `FNACL_LOG=1` 可开日志写到 `/tmp/fnacl.log`（调试完已关闭，避免拖慢）

### 3.3 `fnnas/ld-hooks/build-hooks.sh` / systemd drop-in

- 编译 `fnacl_faccessat_hook.so` 并部署到 `/opt/fnnas/`
- `a3-fnperm-hook-setup` 给 **14 个** 链接 `libnperm` 的服务生成 drop-in：
  `trim_main`(filemanager 继承)、`trim_upload`、`trim_open_gateway`、`trim_app_center`、`filestor_service`、`finder_service`、`sysinfo_service`、`share_service`、`backup_service`、`dlcenter`、`imagesrv`、`multiple-downloads`、`trim_sharelink`、`webdav`

---

## 4. 关键账号/会话注意事项

1. **登录必须勾选“保持登录”**：否则浏览器没有 `osrt`（长效令牌），上传会 403。
2. **重启 `trim_app_center` 后，已运行应用的 `TRIM_API_TOKEN` 会失配**，需要在应用中心重启对应应用（不要手工启动飞牛应用）。
3. `trim.key.enc` 由 `master=HMAC-SHA256("00000000-0000-0000-0000-000000000000", machine-id[:32])` 加密；MT6771 无 SMBIOS，回退 UUID 是固定值。`a3-trim-keygen` 按本机 machine-id 生成，**key 有效时保留不动**（避免令牌失效）。

---

## 5. 已知限制 / 未完成（如实记录）

### 5.1 回收站只有设备节点，没有事件流

`trim_trashbind` 打开 `/dev/trim-trashbin` 后执行 `read(fd, buf, 262144)`，
期望读到 `trim_trashbin_request_t` 事件包（`size[4] + 头部 + 路径`），
由 `process_packet()` 分发搬运动作。

当前 shim 的 `read()` 返回 0（EOF），服务会正常退出但不会常驻；
`Restart=always` 下会反复重启，因此当前是 `stop + mask trim_trashbind`。

**影响**：只有回收站不可用；永久删除、上传、上传目录、改名、远程复制都正常。

**要完整实现**：需要逆向飞牛内核 `trim_do_trashbin` / `trim_is_on_trashbin_whitelist`，
把内核补丁挂到 VFS 的 rename/unlink 路径上生成事件。
逆向素材已保存在构建机 `/opt/oppoa3/wv/trimkit/`：
- `vmlinuz-6.18.18.c1193-trim`（15MB）、解压后的 `Image.raw`（45MB）
- `System.map`（含 `trim_syscall_*` / `trim_do_trashbin` / `trim_permission` 等符号）
- 7 个私有头文件（`trim_acl.h` / `trimvfs.h` / `trim_flags.h` / `trim_acl_xattr_ds.h` 等）
- `Module.symvers`（27 个 `EXPORT_SYMBOL` 的 trim API）
- `libtrimacl.so`、`trimacl`、`trimafs2.ko`

### 5.2 影视应用未实测

音乐已完整验证；影视（trim.video）未做端到端测试。

### 5.3 用户态兼容层 ≠ 完整内核补丁

当前是**行为兼容**（hook 掉所有依赖点），不是把飞牛 `CONFIG_FS_TRIM_ACL` 的
VFS 改造逐行移植到 6.12。优点是改动小、可维护；缺点是：
- 每新增一个依赖私有语义的飞牛模块，可能要补一个 hook
- 内核态的 `trim_permission`（真正按 ACL 判定）没有移植；当前靠文件权限 777 + hook 放行

### 5.4 推送 GitHub 未完成

构建机无 GitHub 凭据（`could not read Username for 'https://github.com'`）。
需要配置 token 或 SSH key 后才能 `git push`。

---

## 6. 提交历史（本次移植）

```
1ccb4b8 fnnas: trim_acl_shim 提供 /dev/trim-trashbin
93b0c46 fnnas: sshfs wrapper 改用 umask=022
dae65b0 fnnas: 给 sshfs 补默认 file_mode/dir_mode（后被 93b0c46 修正）
1e34b05 fnnas: 修掉伪 dirfd hook 的段错误
b7e532f docs: 整理 A3 USB 网络模式（RNDIS/CDC-ECM）自动切换
73fc91f fnnas: 修复删除/上传目录的伪 dirfd；补 defconfig patch、模块打包与一键脚本
453731f fnnas: 补全 libnperm 兼容服务列表与 mediasrv socket 别名
28220cb fnnas: 忽略 kmod 编译中间文件；移除未采用的 fakedmi hook
302a18d fnnas: 打通网页上传与显示/ZFS，补齐主线内核兼容层
9e9f1a6 fnnas: 补齐飞牛私有 trimacl 补丁，音乐/影视库授权可用
```

## 7. 操作速查

```sh
# 一键构建
./script/a3-fnnas-all.sh <fnos.iso> <trimlib.zip> [size]
./script/a3-fnnas-all.sh --boot-only
./script/a3-fnnas-all.sh --rootfs-only <iso> <trimlib>

# 刷机（设备进 fastboot）
fastboot flash boot     vendor/a3-fnnas-<ts>.img
fastboot flash userdata out/fnnas-rootfs-<ts>.img   # 会清空用户数据

# 运行期检查
systemctl is-active a3-trimacl-shim trim_main trim_upload trim_app_center
lsmod | grep trim_acl_shim
ls -l /dev/trim-trashbin
lsmod | grep fnacl   # 用户态 hook 不在内核里，用 grep -rl 看 drop-in
mount | grep vol02
```
