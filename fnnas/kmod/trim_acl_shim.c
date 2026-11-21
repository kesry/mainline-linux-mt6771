// SPDX-License-Identifier: GPL-2.0
/*
 * trim_acl_shim.c — 主线内核补齐飞牛私有 trimacl 相关设施
 *
 * 两部分
 * ------
 * 1) system.trim_acl xattr
 *    飞牛 FilesACL（CONFIG_FS_TRIM_ACL）在 ext4/btrfs 注册 prefix="system."
 *    的 xattr handler，使 system.trim_acl 可用。上游内核没有该 handler，
 *    getxattr 返回 -EOPNOTSUPP，导致 libtrimacl 解析失败、音乐/影视库授权
 *    报"所选文件夹无写入权限"、文件回收站与多用户权限不可用。
 *    做法：注册精确匹配 "system.trim_acl" 的 handler，读写转发到
 *    "user.trim_acl"（复用了现有存储机制，ext4/btrfs 都支持 user.*）。
 *
 * 2) /dev/trim-trashbin 字符设备
 *    飞牛的 trashbind 服务启动时必定 open("/dev/trim-trashbin", O_RDWR)，
 *    失败就 exit(1) 并被 systemd 无限重启（重启计数能到几百）。
 *    该设备在飞牛内核里由 CONFIG_FS_TRIM_ACL 提供，用于登记/查询哪些目录
 *    在白名单内（回收站只在白名单目录启用）。
 *    trashbind 打开设备后并不发 ioctl（实测），真正的搬运是它自己用
 *    rename/mkdir/lsetxattr 完成的。所以这里提供一个「能打开、可读写、
 *    read 返回 0（EOF）」的最小 misc 设备，足以让服务正常启动。
 *
 * 编译
 * ----
 *   make -C /opt/oppoa3/kernel-src O=/opt/oppoa3/qdiag ARCH=arm64 M=$PWD modules
 *
 * 加载
 * ----
 *   insmod trim_acl_shim.ko mounts=/vol1
 * 卸载
 * ----
 *   rmmod trim_acl_shim        （同时恢复原始 s_xattr 数组）
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
#include <linux/miscdevice.h>
#include <linux/uaccess.h>

#define XATTR_TRIM_ACL   "system.trim_acl"
#define XATTR_BACKEND    "user.trim_acl"
#define TRASHBIN_NAME    "trim-trashbin"

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

	ret = __vfs_getxattr(dentry, inode, XATTR_BACKEND, buffer, size);
	pr_debug("trim_acl_shim: get(%s) size=%zu -> %d\n",
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
	pr_debug("trim_acl_shim: set(%s) size=%zu -> %d\n",
		 dentry->d_name.name, size, ret);
	return ret;
}

/*
 * prefix 与 name 的配合规则（fs/xattr.c xattr_resolve_name）：
 *
 *   n = strcmp_prefix(name, xattr_prefix(handler));
 *   if (n) {
 *       if (!handler->prefix ^ !*n) {
 *           if (*n) continue;
 *           return ERR_PTR(-EINVAL);
 *       }
 *       *name = n;
 *   }
 *
 *  - prefix 非空 + 匹配后剩余为空 → EINVAL（不会选中该 handler）
 *  - prefix 为 NULL + name 精确相等 → 剩余为空但 !prefix 为真，
 *    异或为假跳过 EINVAL，*name="" 后正常调用 handler
 *
 * 所以这里用 .name 精确匹配，prefix 留 NULL。
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
		pr_debug("trim_acl_shim: %s has no s_xattr, skip\n", sb->s_id);
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

/* ---------------- /dev/trim-trashbin ---------------- */

/*
 * 最小实现：能打开、可写、read 返回 0（EOF）。
 * trashbind 只要求 open 成功；不做 ioctl（实测）。
 */
static int trashbin_open(struct inode *inode, struct file *file)
{
	pr_info("trim_acl_shim: %s opened by %s (pid %d)\n",
		TRASHBIN_NAME, current->comm, current->pid);
	return 0;
}

static int trashbin_release(struct inode *inode, struct file *file)
{
	pr_debug("trim_acl_shim: %s released\n", TRASHBIN_NAME);
	return 0;
}

static ssize_t trashbin_read(struct file *file, char __user *buf,
			     size_t count, loff_t *ppos)
{
	/* 无内容可读：直接 EOF */
	return 0;
}

static ssize_t trashbin_write(struct file *file, const char __user *buf,
			      size_t count, loff_t *ppos)
{
	char kbuf[128];
	size_t n = min(count, sizeof(kbuf) - 1);

	if (copy_from_user(kbuf, buf, n))
		return -EFAULT;
	kbuf[n] = 0;
	pr_debug("trim_acl_shim: %s write: %s\n", TRASHBIN_NAME, kbuf);
	return count;
}

static const struct file_operations trashbin_fops = {
	.owner   = THIS_MODULE,
	.open    = trashbin_open,
	.release = trashbin_release,
	.read    = trashbin_read,
	.write   = trashbin_write,
	.llseek  = noop_llseek,
};

static struct miscdevice trashbin_miscdev = {
	.minor = MISC_DYNAMIC_MINOR,
	.name  = TRASHBIN_NAME,
	.fops  = &trashbin_fops,
	.mode  = 0600,
};

/* ---------------- 模块入口/出口 ---------------- */

static int __init trim_acl_shim_init(void)
{
	char *buf, *tok;
	int ok = 0, fail = 0, ret;

	pr_info("trim_acl_shim: loading, mounts=%s\n", mounts);

	/* 1. /dev/trim-trashbin */
	ret = misc_register(&trashbin_miscdev);
	if (ret)
		pr_warn("trim_acl_shim: misc_register(%s) failed: %d\n",
			TRASHBIN_NAME, ret);
	else
		pr_info("trim_acl_shim: /dev/%s registered (minor %d)\n",
			TRASHBIN_NAME, trashbin_miscdev.minor);

	/* 2. system.trim_acl xattr */
	buf = kstrdup(mounts, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	mutex_lock(&g_lock);
	for (tok = strsep(&buf, ","); tok; tok = strsep(&buf, ",")) {
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
		if (!ret)
			misc_deregister(&trashbin_miscdev);
		return -ENODEV;
	}
	return 0;
}

static void __exit trim_acl_shim_exit(void)
{
	mutex_lock(&g_lock);
	unpatch_all();
	mutex_unlock(&g_lock);
	misc_deregister(&trashbin_miscdev);
	pr_info("trim_acl_shim: unloaded\n");
}

module_init(trim_acl_shim_init);
module_exit(trim_acl_shim_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("fnOS trimacl: system.trim_acl xattr + /dev/trim-trashbin");
MODULE_AUTHOR("a3-port");