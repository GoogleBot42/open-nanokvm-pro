/* LD_PRELOAD ioctl tracer for the vendor capture path at 4K (#17 follow-on).
 * Logs every ioctl: fd (with path, once), request decode (_IOC_* fields),
 * return code, and a hexdump of the arg payload at the exact _IOC_SIZE for
 * both directions (before for writes, after for reads). Output: $TRACE_OUT
 * (default /tmp/ioctl.trace). Same method as the proven Stage-3/5 tracers. */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/ioctl.h>

static int (*real_ioctl)(int, unsigned long, ...);
static FILE *out;
static pthread_mutex_t lk = PTHREAD_MUTEX_INITIALIZER;
static char seen_fd[4096];

static void hexdump(const char *pfx, const void *p, unsigned n)
{
	const unsigned char *b = p;
	if (n > 1024) n = 1024;
	for (unsigned i = 0; i < n; i += 16) {
		fprintf(out, "%s %04x:", pfx, i);
		for (unsigned j = i; j < i + 16 && j < n; j++)
			fprintf(out, " %02x", b[j]);
		fputc('\n', out);
	}
}

int ioctl(int fd, unsigned long req, ...)
{
	va_list ap;
	void *arg;
	va_start(ap, req);
	arg = va_arg(ap, void *);
	va_end(ap);

	if (!real_ioctl)
		real_ioctl = dlsym(RTLD_NEXT, "ioctl");
	if (!out) {
		const char *f = getenv("TRACE_OUT");
		out = fopen(f ? f : "/tmp/ioctl.trace", "w");
		if (!out) out = stderr;
		setvbuf(out, NULL, _IOLBF, 0);
	}

	unsigned dir = _IOC_DIR(req), type = _IOC_TYPE(req);
	unsigned nr = _IOC_NR(req), size = _IOC_SIZE(req);

	pthread_mutex_lock(&lk);
	if (fd >= 0 && fd < (int)sizeof seen_fd && !seen_fd[fd]) {
		char lnk[64], path[256] = "?";
		snprintf(lnk, sizeof lnk, "/proc/self/fd/%d", fd);
		ssize_t r = readlink(lnk, path, sizeof path - 1);
		if (r > 0) path[r] = 0;
		fprintf(out, "FD %d = %s\n", fd, path);
		seen_fd[fd] = 1;
	}
	fprintf(out, "IOCTL fd=%d req=0x%08lx dir=%u type=0x%02x('%c') nr=%u size=%u\n",
		fd, req, dir, type, type >= 32 && type < 127 ? type : '.', nr, size);
	if (arg && size && (dir & _IOC_WRITE))
		hexdump("  W", arg, size);
	pthread_mutex_unlock(&lk);

	int rc = real_ioctl(fd, req, arg);

	pthread_mutex_lock(&lk);
	fprintf(out, "  rc=%d\n", rc);
	if (arg && size && (dir & _IOC_READ))
		hexdump("  R", arg, size);
	pthread_mutex_unlock(&lk);
	return rc;
}
