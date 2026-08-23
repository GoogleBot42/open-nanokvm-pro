/* axvenctrace.c - LD_PRELOAD ioctl/mmap tracer for /dev/ax_venc + /dev/ax_jenc
 * Filters ioctls to magic 'k' (0x6b). Dumps mmap'd VCMD pools around each
 * 'k' ioctl (PRE = before real ioctl, POST = after). Read-only: never writes
 * device memory.
 *
 * Uses raw syscalls (not dlsym) so interposition works even when python's
 * early startup calls open/mmap before this lib's constructor runs.
 * Compile natively on device: gcc -O2 -fPIC -shared -o axvenctrace.so axvenctrace.c
 *
 * Env: AXLOG=<path>  AXDUMP=<bytes-per-region>  (AXDUMP=0 => no pool dumps)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/syscall.h>

#define MAXFD 8192
static char *fdpath[MAXFD];

struct region { void *addr; size_t len; off_t off; char dev; int fd; int active; };
static struct region regs[128];
static int nreg = 0;

static FILE *logf;
static int  dump_cap = 0;
static int  memfd = -1;
static int  ready = 0;

static long s_openat(const char *p,int fl,int mode){ return syscall(SYS_openat,AT_FDCWD,p,fl,mode); }
static long s_ioctl(int fd,unsigned long req,void*arg){ return syscall(SYS_ioctl,fd,req,arg); }
static void* s_mmap(void*a,size_t l,int pr,int fl,int fd,off_t off){
    return (void*)syscall(SYS_mmap,a,l,pr,fl,fd,off);
}

static char devclass(const char *p){
    if(!p) return 0;
    if(strstr(p,"ax_venc")) return 'V';
    if(strstr(p,"ax_jenc")) return 'J';
    if(strstr(p,"/dev/mem")) return 'M';   /* mmap offset == phys addr */
    if(strstr(p,"ax_cmm"))   return 'C';
    if(strstr(p,"ax_sys"))   return 'S';
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
    logf = fopen(p?p:"/tmp/axwork/venc.log","a");
    if(!logf) logf = stderr;
    setvbuf(logf,0,_IONBF,0);
    char *c = getenv("AXDUMP");
    if(c) dump_cap = atoi(c);
    memfd = (int)s_openat("/proc/self/mem",O_RDONLY,0);
    ready = 1;
    fprintf(logf,"=== axvenctrace loaded (dump_cap=%d memfd=%d) ===\n",dump_cap,memfd);
}

static void reg_open(int fd, const char *path){
    if(fd<0||fd>=MAXFD) return;
    if(fdpath[fd]){ free(fdpath[fd]); fdpath[fd]=0; }
    char cc = devclass(path);
    if(cc && logf){ fdpath[fd]=strdup(path); fprintf(logf,"OPEN fd=%d %s (%c)\n",fd,path,cc); }
}

int open(const char *path, int flags, ...){
    va_list a; va_start(a,flags); int m=va_arg(a,int); va_end(a);
    int fd = (int)s_openat(path,flags,m);
    if(fd>=0 && ready) reg_open(fd,path);
    return fd;
}
int open64(const char *path, int flags, ...){
    va_list a; va_start(a,flags); int m=va_arg(a,int); va_end(a);
    int fd = (int)s_openat(path,flags,m);
    if(fd>=0 && ready) reg_open(fd,path);
    return fd;
}

static void record_mmap(void *r, size_t len, off_t off, int prot, int fd){
    if(!ready || r==MAP_FAILED) return;
    char dev = (fd>=0&&fd<MAXFD&&fdpath[fd]) ? devclass(fdpath[fd]) : 0;
    if(dev){
        if(nreg<128){
            regs[nreg].addr=r; regs[nreg].len=len; regs[nreg].off=off;
            regs[nreg].dev=dev; regs[nreg].fd=fd; regs[nreg].active=1; nreg++;
        }
        fprintf(logf,"MMAP %c region#%d addr=%p len=%zu off=0x%lx prot=%d fd=%d\n",
                dev,nreg-1,r,len,(long)off,prot,fd);
    }
}
void* mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off){
    void *r = s_mmap(addr,len,prot,flags,fd,off);
    record_mmap(r,len,off,prot,fd);
    return r;
}
void* mmap64(void *addr, size_t len, int prot, int flags, int fd, off_t off){
    void *r = s_mmap(addr,len,prot,flags,fd,off);
    record_mmap(r,len,off,prot,fd);
    return r;
}

static void dump_pools(char dev, const char *tag, unsigned nr){
    if(dump_cap<=0) return;
    for(int i=0;i<nreg;i++){
        if(!regs[i].active || regs[i].dev!=dev) continue;
        size_t n = regs[i].len; if((int)n>dump_cap) n=dump_cap;
        unsigned char buf[64];
        fprintf(logf,"  POOL %s nr=%u region#%d off=0x%lx dump=%zu\n",
                tag,nr,i,(long)regs[i].off,n);
        for(size_t o=0;o<n;o+=32){
            size_t chunk = (n-o)>32?32:(n-o);
            size_t got = saferead((char*)regs[i].addr+o,buf,chunk);
            fprintf(logf,"    %04zx: ",o);
            for(size_t j=0;j<got;j++) fprintf(logf,"%02x",buf[j]);
            fprintf(logf,"\n");
        }
    }
}

int ioctl(int fd, unsigned long req, ...){
    va_list a; va_start(a,req); void *arg=va_arg(a,void*); va_end(a);
    char dev = (ready && fd>=0 && fd<MAXFD && fdpath[fd]) ? devclass(fdpath[fd]) : 0;
    unsigned type=(req>>8)&0xff, nr=req&0xff, size=(req>>16)&0x3fff, dir=(req>>30)&0x3;
    int isk = (dev && type==0x6b);

    if(isk) dump_pools(dev,"PRE",nr);
    int rc = (int)s_ioctl(fd,req,arg);
    if(isk){
        fprintf(logf,"IOCTL %c req=0x%08lx dir=%u type=0x%02x nr=%u size=%u rc=%d arg=%p\n",
                dev,req,dir,type,nr,size,rc,arg);
        if(arg && size){
            unsigned n = size>256?256:size;
            unsigned char buf[256];
            size_t got = saferead(arg,buf,n);
            fprintf(logf,"  ARG(%u) got=%zu:",size,got);
            for(size_t i=0;i<got;i++) fprintf(logf,"%02x",buf[i]);
            fprintf(logf,"\n");
        }
        dump_pools(dev,"POST",nr);
    }
    return rc;
}
