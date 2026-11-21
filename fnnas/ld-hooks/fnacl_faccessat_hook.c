#define _GNU_SOURCE
/*
 * fnacl_faccessat_hook.c 鈥?椋炵墰绉佹湁 syscall 鍏煎灞? *
 * 鑳屾櫙
 * ----
 * 椋炵墰鍦?libnperm / filemanager 閲岀敤銆岃礋鏁颁吉 dirfd銆嶈皟 *at 绯诲垪绯荤粺璋冪敤锛? * 鎶婄鏈夎涔夊杩?dirfd锛? *   faccessat(-21586, struct_ptr, mode, flags)   // struct 棣栧瓧娈典负璺緞
 *   unlinkat(-7125, "vol1/1000/music/x", 0)      // 璺緞涓烘牴鐩稿涓? *   renameat2(-7125, ...) / statx(-7125, ...) / utimensat(-7125, ...)
 *
 * 椋炵墰鍐呮牳浼氳瘑鍒繖浜涗吉 dirfd 骞舵寜 trimacl 鍒ゅ畾锛涗富绾垮唴鏍告妸瀹冧滑褰撶湡瀹? * fd 鈫?EBADF(9)锛屼簬鏄垹闄?涓婁紶鐩綍/鏀瑰悕绛夊叏閮ㄥけ璐ャ€? *
 * 鍋氭硶
 * ----
 * 璇嗗埆璐?dirfd锛堜笖涓嶆槸 AT_FDCWD锛夛細
 *   1) 鍙栫湡瀹炶矾寰勶細浠?'/' 寮€澶?鈫?鐩存帴鐢紱鍍忚矾寰勪覆 鈫?鏍圭浉瀵癸紝琛?'/' 鍓嶇紑锛? *      鍚﹀垯褰撴垚鎸囬拡瑙ｅ紩鐢紙libnperm 鐨?struct锛? *   2) 鐢?AT_FDCWD 璋冪湡姝ｇ殑鍑芥暟
 *   3) faccessat 鐨?mode/flags 瑕佹竻娲楋紙椋炵墰澶瑰甫绉佹湁浣嶄細 EINVAL锛? *
 * 瑕嗙洊锛歠accessat / unlinkat / renameat2 / statx / utimensat
 *
 * 缂栬瘧
 * ----
 *   aarch64-linux-gnu-gcc -shared -fPIC -O2 -o fnacl_faccessat_hook.so \
 *       fnacl_faccessat_hook.c -ldl
 *
 * 鐢ㄦ硶
 * ----
 *   LD_PRELOAD=/opt/fnnas/fnacl_faccessat_hook.so
 *
 * 璋冭瘯
 * ----
 *   FNACL_LOG=1 鈫?姣忔浼?dirfd 璋冪敤鍐?/tmp/fnacl.log
 */

#include <dlfcn.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <time.h>

/* struct statx 鏉ヨ嚜鍐呮牳澶达紝閬垮厤渚濊禆 libc 鐗堟湰 */
#include <linux/stat.h>

#define FNACL_PATH_MAX 4096

typedef int (*faccessat_fn)(int, const char *, int, int);
typedef int (*unlinkat_fn)(int, const char *, int);
typedef int (*renameat2_fn)(int, const char *, int, const char *, unsigned int);
typedef int (*statx_fn)(int, const char *, int, unsigned int, struct statx *);
typedef int (*utimensat_fn)(int, const char *, const struct timespec *, int);

static int logging_enabled(void)
{
	static int cached = -1;
	if (cached < 0) {
		const char *v = getenv("FNACL_LOG");
		cached = (v && (v[0] == '1' || v[0] == 'y' || v[0] == 'Y'));
	}
	return cached;
}

static void dbg(const char *fn, int dfd, const char *real, int ret, int err)
{
	FILE *f;

	if (!logging_enabled())
		return;
	f = fopen("/tmp/fnacl.log", "a");
	if (!f)
		return;
	fprintf(f, "%s dfd=%d real=%s ret=%d errno=%d\n",
		fn, dfd, real ? real : "(null)", ret, err);
	fclose(f);
}

/* 璐?dirfd 瑙嗕负浼?dirfd锛圓T_FDCWD == -100 瑕佹帓闄わ級 */
static int is_fake_dfd(int dfd)
{
	return dfd < 0 && dfd != AT_FDCWD;
}

/*
 * 鍒ゅ畾涓€娈靛唴瀛樻槸涓嶆槸鍙鐨?C 瀛楃涓茶矾寰勶細
 *  - 鍓嶈嫢骞插瓧鑺傞兘鏄彲鎵撳嵃 ASCII
 *  - 涓斿惈鏈?'/'
 */
static int looks_like_path(const char *p)
{
	int i, slash = 0;

	if (!p)
		return 0;
	for (i = 0; i < 64; i++) {
		unsigned char c = (unsigned char)p[i];
		if (c == 0)
			return slash;
		if (c == '/')
			slash = 1;
		if (c < 0x20 || c > 0x7e)
			return 0;
	}
	return slash;
}

/*
 * 褰掍竴鍖栬矾寰勫埌绾跨▼灞€閮ㄧ紦鍐诧紙杩斿洖闈欐€佺紦鍐插尯锛屼粎鍗曠嚎绋嬪唴绔嬪嵆浣跨敤鏈夋晥锛? */
static const char *resolve_path(const char *p)
{
	static __thread char buf[FNACL_PATH_MAX];
	const char *s = p;

	if (!s)
		return s;

	/* 涓嶆槸璺緞涓?鈫?褰撲綔 libnperm 鐨?struct锛岄瀛楁涓鸿矾寰勬寚閽?*/
	if (!looks_like_path(s))
		s = *(const char * const *)s;

	if (!s)
		return NULL;

	/* 鏍圭浉瀵?鈫?琛?'/' */
	if (s[0] == '/')
		return s;

	if (strlen(s) + 2 > sizeof(buf))
		return s;
	buf[0] = '/';
	strncpy(buf + 1, s, sizeof(buf) - 2);
	buf[sizeof(buf) - 1] = 0;
	return buf;
}

/* ---------------- faccessat ---------------- */

int faccessat(int dfd, const char *pathname, int mode, int flags)
{
	static faccessat_fn real;
	const char *real_path;
	int ret, saved;

	if (!real)
		real = (faccessat_fn)dlsym(RTLD_NEXT, "faccessat");

	if (!is_fake_dfd(dfd))
		return real(dfd, pathname, mode, flags);

	real_path = resolve_path(pathname);

	/* 娓呮礂椋炵墰绉佹湁浣嶏細mode 鍙繚鐣欎綆 3 浣嶏紝flags 鍙繚鐣欐爣鍑嗕綅 */
	mode  &= 7;
	flags &= (AT_SYMLINK_NOFOLLOW | AT_EACCESS | AT_EMPTY_PATH);

	ret = real(AT_FDCWD, real_path, mode, flags);
	saved = errno;
	dbg("faccessat", dfd, real_path, ret, saved);
	errno = saved;
	return ret;
}

/* ---------------- unlinkat ---------------- */

int unlinkat(int dfd, const char *pathname, int flags)
{
	static unlinkat_fn real;
	const char *real_path;
	int ret, saved;

	if (!real)
		real = (unlinkat_fn)dlsym(RTLD_NEXT, "unlinkat");

	if (!is_fake_dfd(dfd))
		return real(dfd, pathname, flags);

	real_path = resolve_path(pathname);
	ret = real(AT_FDCWD, real_path, flags);
	saved = errno;
	dbg("unlinkat", dfd, real_path, ret, saved);
	errno = saved;
	return ret;
}

/* ---------------- renameat2 ---------------- */

int renameat2(int olddfd, const char *oldname,
	      int newdfd, const char *newname, unsigned int flags)
{
	static renameat2_fn real;
	const char *o, *n;
	char obuf[FNACL_PATH_MAX];
	int ret, saved;

	if (!real)
		real = (renameat2_fn)dlsym(RTLD_NEXT, "renameat2");

	if (!is_fake_dfd(olddfd) && !is_fake_dfd(newdfd))
		return real(olddfd, oldname, newdfd, newname, flags);

	o = resolve_path(oldname);
	snprintf(obuf, sizeof(obuf), "%s", o ? o : "");
	n = resolve_path(newname);

	ret = real(AT_FDCWD, obuf, AT_FDCWD, n, flags);
	saved = errno;
	dbg("renameat2", olddfd, n, ret, saved);
	errno = saved;
	return ret;
}

/* ---------------- statx ---------------- */

int statx(int dfd, const char *pathname, int flags, unsigned int mask,
	  struct statx *statxbuf)
{
	static statx_fn real;
	const char *real_path;
	int ret, saved;

	if (!real)
		real = (statx_fn)dlsym(RTLD_NEXT, "statx");

	if (!is_fake_dfd(dfd))
		return real(dfd, pathname, flags, mask, statxbuf);

	real_path = resolve_path(pathname);
	ret = real(AT_FDCWD, real_path, flags, mask, statxbuf);
	saved = errno;
	dbg("statx", dfd, real_path, ret, saved);
	errno = saved;
	return ret;
}

/* ---------------- utimensat ---------------- */

int utimensat(int dfd, const char *pathname, const struct timespec times[2],
	      int flags)
{
	static utimensat_fn real;
	const char *real_path;
	int ret, saved;

	if (!real)
		real = (utimensat_fn)dlsym(RTLD_NEXT, "utimensat");

	if (!is_fake_dfd(dfd))
		return real(dfd, pathname, times, flags);

	real_path = resolve_path(pathname);
	ret = real(AT_FDCWD, real_path, times, flags);
	saved = errno;
	dbg("utimensat", dfd, real_path, ret, saved);
	errno = saved;
	return ret;
}

