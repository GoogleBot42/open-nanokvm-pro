/* stage1trace.c - LD_PRELOAD ioctl tracer for /dev/ax_venc, Stage 1.
 * Derives the exact VCMD ioctl arg STRUCT bytes (not just the pointer): for every
 * magic-'k' ioctl it dereferences the pointer arg and dumps ARGBUF bytes at it
 * PRE (before the real ioctl, catches input fields) and POST (after, catches
 * kernel-written output fields like cmdbuf_id). Read-only: never writes device mem.
 * Compile on device: gcc -O2 -fPIC -shared -o stage1trace.so stage1trace.c
 * Env: AXLOG=<path>  ARGBYTES=<n> (default 64)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/syscall.h>

#define MAXFD 8192
static char *fdpath[MAXFD];
static FILE *logf;
static int  memfd = -1;
static int  ready = 0;
static int  argbytes = 64;

static long s_openat(const char *p,int fl,int mode){ return syscall(SYS_openat,AT_FDCWD,p,fl,mode); }
static long s_ioctl(int fd,unsigned long req,void*arg){ return syscall(SYS_ioctl,fd,req,arg); }

static char devclass(const char *p){
    if(!p) return 0;
    if(strstr(p,"ax_venc")) return 'V';
    if(strstr(p,"ax_jenc")) return 'J';
    return 0;
}
static size_t saferead(void *addr, unsigned char *buf, size_t n){
    if(memfd<0) return 0;
    ssize_t r = pread(memfd,buf,n,(off_t)(uintptr_t)addr);
    return r>0 ? (size_t)r : 0;
}
__attribute__((constructor))
static void axinit(void){
    char *p = getenv("AXLOG");
    logf = fopen(p?p:"/tmp/axwork/stage1_trace.log","a");
    if(!logf) logf = stderr;
    setvbuf(logf,0,_IONBF,0);
    char *c = getenv("ARGBYTES"); if(c) argbytes = atoi(c);
    if(argbytes>256) argbytes=256;
    memfd = (int)s_openat("/proc/self/mem",O_RDONLY,0);
    ready = 1;
    fprintf(logf,"=== stage1trace loaded (argbytes=%d memfd=%d) ===\n",argbytes,memfd);
}
static void reg_open(int fd, const char *path){
    if(fd<0||fd>=MAXFD) return;
    if(fdpath[fd]){ free(fdpath[fd]); fdpath[fd]=0; }
    char cc = devclass(path);
    if(cc && logf){ fdpath[fd]=strdup(path); fprintf(logf,"OPEN fd=%d %s (%c)\n",fd,path,cc); }
}
int open(const char *path, int flags, ...){
    va_list a; va_start(a,flags); int m=va_arg(a,int); va_end(a);
    int fd=(int)s_openat(path,flags,m);
    if(fd>=0&&ready) reg_open(fd,path);
    return fd;
}
int open64(const char *path, int flags, ...){
    va_list a; va_start(a,flags); int m=va_arg(a,int); va_end(a);
    int fd=(int)s_openat(path,flags,m);
    if(fd>=0&&ready) reg_open(fd,path);
    return fd;
}
static void dumparg(const char *tag, void *arg){
    if(!arg) return;
    unsigned char buf[256];
    size_t got = saferead(arg,buf,argbytes);
    fprintf(logf,"  %s arg=%p got=%zu: ",tag,arg,got);
    for(size_t i=0;i<got;i++) fprintf(logf,"%02x",buf[i]);
    fprintf(logf,"\n");
}
int ioctl(int fd, unsigned long req, ...){
    va_list a; va_start(a,req); void *arg=va_arg(a,void*); va_end(a);
    char dev=(ready&&fd>=0&&fd<MAXFD&&fdpath[fd])?devclass(fdpath[fd]):0;
    unsigned type=(req>>8)&0xff, nr=req&0xff, size=(req>>16)&0x3fff, dir=(req>>30)&0x3;
    int isk=(dev&&type==0x6b);
    if(isk) dumparg("PRE",arg);
    int rc=(int)s_ioctl(fd,req,arg);
    if(isk){
        fprintf(logf,"IOCTL %c req=0x%08lx dir=%u type=0x%02x nr=%u size=%u rc=%d fd=%d\n",
                dev,req,dir,type,nr,size,rc,fd);
        dumparg("POST",arg);
    }
    return rc;
}
