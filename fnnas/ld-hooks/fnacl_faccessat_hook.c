#define _GNU_SOURCE
/*
 * fnacl_faccessat_hook.c — 飞牛私有 syscall 兼容层
 *
 * 飞牛的 libnperm.so 用伪 dirfd 调用 faccessat 做权限判定：
 *
 *   internal_check_perm(uid, path, mask):
 *     struct { char *path; u32 x; u32 uid; u32 y; } s;
 *     s.path = path;
 *     faccessat(-21586, &s, R_OK|W_OK, 0);
 *
 * 在飞牛内核里，-21586 会解引用 struct 取出真实路径再检查。
 * 主线内核把 struct 指针当路径字符串 → EBADF/EFAULT → 判定"无写入权限"。
 *
 * 本 hook 拦截 faccessat，识别伪 dirfd，从 struct 里取出真实路径，
 * 转成标准的 AT_FDCWD 调用，从而让飞牛的权限判定正常工作。
 *
 * 编译：
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -o fnacl_faccessat_hook.so fnacl_faccessat_hook.c -ldl
 *
 * 使用：
 *   LD_PRELOAD=/opt/fnnas/fnacl_faccessat_hook.so
 */

#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>

typedef int (*faccessat_fn)(int, const char *, int, int);

static faccessat_fn real_faccessat(void)
{
	static faccessat_fn fn;
	if (!fn)
		fn = (faccessat_fn)dlsym(RTLD_NEXT, "faccessat");
	return fn;
}

/*
 * 飞牛伪 dirfd 的范围：-21586 .. -21575
 * index = dfd + 21585，有效 0..10
 */
static int is_trim_dfd(int dfd)
{
	return dfd >= -21586 && dfd <= -21575;
}

/*
 * 从参数里取出真实路径：
 *  - 若 pathname 本身以 '/' 开头 → 直接是路径（普通调用）
 *  - 否则视为飞牛的 struct，struct[0] (offset 0) 是路径指针
 */
static const char *extract_real_path(const char *p)
{
	const char *inner;

	if (!p)
		return p;
	if (p[0] == '/')
		return p;

	inner = *(const char * const *)p;
	if (inner && inner[0] == '/')
		return inner;

	return p;
}

int faccessat(int dfd, const char *pathname, int mode, int flags)
{
	const char *real_path = pathname;

	if (is_trim_dfd(dfd)) {
		real_path = extract_real_path(pathname);
		/* 转成标准调用：忽略伪 dirfd，用 AT_FDCWD */
		return real_faccessat()(AT_FDCWD, real_path, mode, flags);
	}

	return real_faccessat()(dfd, pathname, mode, flags);
}
