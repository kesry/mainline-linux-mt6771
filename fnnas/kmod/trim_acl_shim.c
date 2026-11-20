// SPDX-License-Identifier: GPL-2.0
/*
 * trim_acl_shim.c — 主线内核补齐飞牛私有的 system.trim_acl xattr
 *
 * 背景
 * ----
 * 飞牛 FilesACL（CONFIG_FS_TRIM_ACL）在 ext4/btrfs 里注册了 prefix="system."
 * 的 xattr handler，使 `system.trim_acl` 可用。上游内核没有这个 handler，
 * getxattr("system.trim_acl") 返回 -EOPNOTSUPP，导致：
 *   - libtrimacl 的 trimacl_get_file() 失败
 *   - 飞牛判定"无写入权限" → 音乐/影视库授权失败
 *   - 文件回收站、多用户权限不可用
 *
 * 做法
 * ----
 * 注册一个只匹配 "system.trim_acl" 的 xattr_handler，把目标 sb 的
 * s_xattr 数组替换成「原数组 + 本 handler」。读写转发到 "user.trim_acl"
 * （利用现有 user.* 存储机制，ext4/btrfs/tmpfs 都支持）。
 *
 * 依据
 * ----
 * fs/xattr.c 的 xattr_permission()：
 *     if (!strncmp(name, XATTR_SYSTEM_PREFIX, XATTR_SYSTEM_PREFIX_LEN))
 *             return 0;     // system.* 不做 VFS 限制
 * 所以只要 sb->s_xattr 里有匹配 handler，xattr 即可用。
 *
 * 编译
 * ----
 *   make -C /opt/oppoa3/kernel-src O=/opt/oppoa3/qdiag ARCH=arm64 M=$PWD modules
 * 加载
 * ----
 *   insmod trim_acl_shim.ko mounts=/vol1,/vol2
 *   不传参数则只处理 /vol1
 * 卸载
 * ----
 *   rmmod trim_acl_shim
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/fs.h>
#include <linux/xattr.h>
#include <linux/namei.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/string.h>

#define XATTR_TRIM_ACL   "system.trim_acl"
#define XATTR_BACKEND    "user.trim_acl"

static char *mounts = "/vol1";
module_param(mounts, charp, 0644);
MODULE_PARM_DESC(mounts, "挂载点列表，逗号分隔，默认 /vol1");

/* 已打补丁的 sb 记录 */
struct sb_patch {
	struct list_head list;
	struct super_block *sb;
	const struct xattr_handler * const *orig;
	const struct xattr_handler **replacement;
};

static LIST_HEAD(g_patched);
static DEFINE_MUTEX(g_lock);

/* ---------------- xattr handler 实现 ---------------- */

static bool trim_list(struct dentry *dentry)
{
	return true;
}

static int trim_get(const struct xattr_handler *handler,
		    struct dentry *dentry, struct inode *inode,
		    const char *name, void *buffer, size_t size)
{
	int ret;

	/*
	 * handler->prefix 为 NULL、name 精确匹配，VFS 已把 name 置为空串。
	 * 转发到后端 user.trim_acl。
	 */
	ret = __vfs_getxattr(dentry, inode, XATTR_BACKEND, buffer, size);
	pr_info("trim_acl_shim: get(%s) size=%zu -> %d\n",
		dentry->d_name.name, size, ret);
	return ret;
}

static int trim_set(const struct xattr_handler *handler,
		    struct mnt_idmap *idmap,
		    struct dentry *dentry, struct inode *inode,
		    const char *name, const void *value,
		    size_t size, int flags)
{
	int ret;

	ret = __vfs_setxattr(idmap, dentry, inode, XATTR_BACKEND,
			     value, size, flags);
	pr_info("trim_acl_shim: set(%s) size=%zu -> %d\n",
		dentry->d_name.name, size, ret);
	return ret;
}

/*
 * 注意 prefix 与 name 的配合规则（fs/xattr.c xattr_resolve_name）：
 *
 *   n = strcmp_prefix(name, xattr_prefix(handler));
 *   if (n) {
 *       if (!handler->prefix ^ !*n) {     // prefix 为空 XOR 剩余为空
 *           if (*n) continue;
 *           return ERR_PTR(-EINVAL);      // 两者都"边界"时才算不匹配
 *       }
 *       *name = n;
 *   }
 *
 * 也就是说：
 *   - prefix 非空 + 匹配后剩余为空  → EINVAL（_不会_选中该 handler）
 *   - prefix 为 NULL + name 精确相等 → 剩余为空，但 !prefix 为真，
 *                                      与 !*n 异或得 false，跳过 EINVAL，
 *                                      然后 *name = ""，正常调用 handler
 *
 * 因此这里用 .name 精确匹配，prefix 留 NULL。
 */
static const struct xattr_handler trim_acl_handler = {
	.name   = XATTR_TRIM_ACL,
	.prefix = NULL,
	.list   = trim_list,
	.get    = trim_get,
	.set    = trim_set,
};

/* ---------------- 给某个 sb 打补丁 ---------------- */

static int patch_sb(struct super_block *sb)
{
	struct sb_patch *p;
	const struct xattr_handler * const *orig;
	const struct xattr_handler **arr;
	size_t n = 0, i;

	if (!sb)
		return -EINVAL;

	orig = sb->s_xattr;
	if (!orig) {
		pr_warn("trim_acl_shim: %s has no s_xattr, skip\n", sb->s_id);
		return -EOPNOTSUPP;
	}

	/* 幂等：已含本 handler 就跳过 */
	for (i = 0; orig[i]; i++)
		if (orig[i] == &trim_acl_handler)
			return 0;
	n = i;

	arr = kcalloc(n + 2, sizeof(*arr), GFP_KERNEL);
	if (!arr)
		return -ENOMEM;
	for (i = 0; i < n; i++)
		arr[i] = orig[i];
	arr[n] = &trim_acl_handler;
	arr[n + 1] = NULL;

	p = kzalloc(sizeof(*p), GFP_KERNEL);
	if (!p) {
		kfree(arr);
		return -ENOMEM;
	}
	p->sb = sb;
	p->orig = orig;
	p->replacement = arr;
	list_add(&p->list, &g_patched);

	sb->s_xattr = (const struct xattr_handler * const *)arr;

	pr_info("trim_acl_shim: patched %s (%s), xattr %zu -> %zu\n",
		sb->s_id, sb->s_type->name, n, n + 1);
	return 0;
}

static void unpatch_all(void)
{
	struct sb_patch *p, *tmp;

	list_for_each_entry_safe(p, tmp, &g_patched, list) {
		if (p->sb && p->sb->s_xattr ==
		    (const struct xattr_handler * const *)p->replacement)
			p->sb->s_xattr = p->orig;
		list_del(&p->list);
		kfree(p->replacement);
		kfree(p);
	}
}

/* 通过挂载点路径找到 sb 并打补丁 */
static int patch_by_path(const char *path)
{
	struct path p;
	struct super_block *sb;
	int ret;

	ret = kern_path(path, LOOKUP_FOLLOW, &p);
	if (ret) {
		pr_err("trim_acl_shim: kern_path(%s) failed: %d\n", path, ret);
		return ret;
	}

	sb = p.dentry->d_sb;
	ret = patch_sb(sb);
	path_put(&p);
	return ret;
}

/* ---------------- 模块入口/出口 ---------------- */

static int __init trim_acl_shim_init(void)
{
	char *buf, *tok, *save = NULL;
	int ok = 0, fail = 0;

	pr_info("trim_acl_shim: loading, mounts=%s\n", mounts);

	buf = kstrdup(mounts, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	mutex_lock(&g_lock);
	for (tok = strsep(&buf, ","); tok; tok = strsep(&buf, ",")) {
		/* 去空白 */
		while (*tok == ' ' || *tok == '\t')
			tok++;
		if (!*tok)
			continue;
		if (patch_by_path(tok) == 0)
			ok++;
		else
			fail++;
	}
	mutex_unlock(&g_lock);

	kfree(buf);

	pr_info("trim_acl_shim: done, %d patched, %d failed\n", ok, fail);
	if (!ok) {
		pr_err("trim_acl_shim: no superblock patched, aborting\n");
		mutex_lock(&g_lock);
		unpatch_all();
		mutex_unlock(&g_lock);
		return -ENODEV;
	}
	return 0;
}

static void __exit trim_acl_shim_exit(void)
{
	mutex_lock(&g_lock);
	unpatch_all();
	mutex_unlock(&g_lock);
	pr_info("trim_acl_shim: unloaded\n");
}

module_init(trim_acl_shim_init);
module_exit(trim_acl_shim_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Provide fnOS private system.trim_acl xattr on mainline kernel");
MODULE_AUTHOR("a3-port");
