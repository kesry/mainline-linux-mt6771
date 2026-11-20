#define _GNU_SOURCE
/*
 * fakedmi.c — 为无 DMI 的 ARM 设备伪造 /sys/class/dmi/id/product_uuid
 *
 * 背景
 * ----
 * 飞牛的 uploadsrv / trim 通过 get_smbios_uuid() 读
 *     /sys/class/dmi/id/product_uuid
 * 来派生 trim.key.enc 的解密 key。MT6771 走的是 DT 启动、没有 SMBIOS 表，
 * 所以该文件不存在 → "Warning: get_smbios_uuid failed." → 无法生成上传 token
 * → 前端 Trim-Token 为空 → tokensrv_query1 失败 → POST /upload 返回 403。
 *
 * 做法
 * ----
 * 拦截 open/openat/fopen/stat/access，把该路径重定向到本地固定 UUID 文件。
 * 值是固定的，保证每次启动一致（key 派生需要稳定）。
 *
 * 编译：
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -o fakedmi.so fakedmi.c -ldl
 * 使用：
 *   LD_PRELOAD=/opt/fnnas/fakedmi.so
 */

#include <dlfcn.h>
#include <stdarg.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#define FAKE_PATH "/opt/fnnas/product_uuid"
#define DMI_PATH  "/sys/class/dmi/id/product_uuid"

static const char *redirect(const char *path)
{
	if (path && strcmp(path, DMI_PATH) == 0)
		return FAKE_PATH;
	return path;
}

int open(const char *path, int flags, ...)
{
	static int (*real)(const char *, int, ...);
	va_list ap;
	mode_t mode = 0;

	if (!real)
		real = dlsym(RTLD_NEXT, "open");
	if (flags & O_CREAT) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
	}
	return real(redirect(path), flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
	static int (*real)(int, const char *, int, ...);
	va_list ap;
	mode_t mode = 0;

	if (!real)
		real = dlsym(RTLD_NEXT, "openat");
	if (flags & O_CREAT) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
	}
	return real(dirfd, redirect(path), flags, mode);
}

int open64(const char *path, int flags, ...)
{
	static int (*real)(const char *, int, ...);
	va_list ap;
	mode_t mode = 0;

	if (!real)
		real = dlsym(RTLD_NEXT, "open64");
	if (flags & O_CREAT) {
		va_start(ap, flags);
		mode = va_arg(ap, mode_t);
		va_end(ap);
	}
	return real(redirect(path), flags, mode);
}

FILE *fopen(const char *path, const char *mode)
{
	static FILE *(*real)(const char *, const char *);
	if (!real)
		real = dlsym(RTLD_NEXT, "fopen");
	return real(redirect(path), mode);
}

FILE *fopen64(const char *path, const char *mode)
{
	static FILE *(*real)(const char *, const char *);
	if (!real)
		real = dlsym(RTLD_NEXT, "fopen64");
	return real(redirect(path), mode);
}

int stat(const char *path, struct stat *buf)
{
	static int (*real)(const char *, struct stat *);
	if (!real)
		real = dlsym(RTLD_NEXT, "stat");
	return real(redirect(path), buf);
}

int lstat(const char *path, struct stat *buf)
{
	static int (*real)(const char *, struct stat *);
	if (!real)
		real = dlsym(RTLD_NEXT, "lstat");
	return real(redirect(path), buf);
}

int access(const char *path, int mode)
{
	static int (*real)(const char *, int);
	if (!real)
		real = dlsym(RTLD_NEXT, "access");
	return real(redirect(path), mode);
}
