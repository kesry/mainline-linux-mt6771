#!/bin/bash
# install-trim-acl.sh — 一键安装 trim_acl_shim.ko（飞牛私有 ACL/xattr + /dev/trim-trashbin）
#
# 通常在设备上运行，配合 CI 产出的 trim-acl-shim.zip（内含本脚本 + .ko）：
#   unzip -o trim-acl-shim.zip -d /tmp/trim-acl
#   bash /tmp/trim-acl/install-trim-acl.sh
#
# 也可直接指定 ko 路径：
#   bash install-trim-acl.sh /path/to/trim_acl_shim.ko
set -eu

KO="${1:-$(dirname "$0")/trim_acl_shim.ko}"
DEST=/opt/fnnas/trim_acl_shim.ko
UNIT=/etc/systemd/system/a3-trimacl-shim.service

say() { echo "[trim-acl] $*"; }
die() { echo "[trim-acl] FATAL: $*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "需要 root"
[ -f "$KO" ] || die "找不到 $KO"

say "内核: $(uname -r)"
say "模块 vermagic: $(modinfo "$KO" 2>/dev/null | grep vermagic | awk '{print $2}' || echo '?')"

# 1. 安装 ko
mkdir -p /opt/fnnas
install -m 0644 "$KO" "$DEST"
say "已安装 $DEST"

# 2. systemd unit（含 trim.key 自愈）
cat > "$UNIT" <<'UNIT'
[Unit]
Description=A3 trim_acl_shim + trim.key self-heal (fnOS on mainline kernel)
After=local-fs.target
Before=trim_main.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/local/sbin/a3-trim-keygen
ExecStart=/sbin/insmod /opt/fnnas/trim_acl_shim.ko mounts=/vol1
ExecStop=/sbin/rmmod trim_acl_shim
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

# keygen 不存在时，创建一个最小可用版本（按 machine-id 生成 trim.key）
if [ ! -x /usr/local/sbin/a3-trim-keygen ]; then
cat > /usr/local/sbin/a3-trim-keygen <<'KEYGEN'
#!/bin/bash
# 生成/自愈 /usr/trim/etc/trim.key.enc（284B）
set -e
K=/usr/trim/etc/trim.key.enc
[ -s "$K" ] && [ "$(stat -c %s "$K")" = 284 ] && exit 0
mkdir -p "$(dirname "$K")"
python3 - "$K" <<'PY'
import sys, hmac, hashlib, os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
out=sys.argv[1]
uuid="00000000-0000-0000-0000-000000000000"
mid=""
try: mid=open("/etc/machine-id").read().strip()[:32]
except: pass
key=hmac.new(mid.encode(), uuid.encode(), hashlib.sha256).digest()
raw=os.urandom(256)
iv=os.urandom(12)
ct=AESGCM(key).encrypt(iv, raw, None)
open(out,"wb").write(iv+ct)
PY
KEYGEN
chmod 755 /usr/local/sbin/a3-trim-keygen
say "已创建 a3-trim-keygen"
fi

# 3. 加载
systemctl daemon-reload
systemctl enable a3-trimacl-shim.service >/dev/null 2>&1 || true
systemctl restart a3-trimacl-shim.service
sleep 2

# 4. 验证
if lsmod | grep -q trim_acl_shim; then
  say "✅ 模块已加载"
else
  say "❌ 模块加载失败，日志："
  journalctl -u a3-trimacl-shim --no-pager -n 10 2>/dev/null || true
  exit 1
fi
[ -e /dev/trim-trashbin ] && say "  /dev/trim-trashbin 已创建"
python3 - <<'PY' 2>/dev/null || true
import os
p='/vol1/1000/music'
if os.path.isdir(p):
    os.setxattr(p,'system.trim_acl',bytes(84))
    n=len(os.getxattr(p,'system.trim_acl'))
    os.removexattr(p,'system.trim_acl')
    print('[trim-acl]  system.trim_acl 读写 OK (%d bytes)' % n)
PY
say "完成。应用中心可重新给影视/音乐授权文件夹。"
