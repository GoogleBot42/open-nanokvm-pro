/* gen_hook.c - Path B LINK-time injector for gen_idr.py output.
 *
 * Overlays ONLY the encoder-core register image (swreg1..511, from HOOK_IMG, our
 * from-scratch gen_idr.py output) into the live vendor cmdbuf slot the instant
 * before libkvm's own LINK_RUN(nr30) ioctl fires. PRESERVES this-run's per-run
 * address registers (KEEP set) and leaves every VCMD structural word (readback DMA
 * dests etc.) exactly as libkvm wrote it -- so no invented phys address ever reaches
 * the silicon. Read-only except 32-bit word writes into the vendor cmdbuf slot.
 *
 * env: HOOK_IMG  = path to 511-word LE image .bin (required)
 *      HOOK_KEEP = comma image-swreg indices to preserve from live (default set below)
 *      HOOK_LOG, HOOK_POOL (else parsed from /proc/ax_proc/mem_cmm_info)
 *      HOOK_ONCE = if set, only inject on LINK #1 (default: every LINK)
 * Build on device: gcc -O2 -fPIC -shared -o gen_hook.so gen_hook.c
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

#define LINK_REQ 0x80086b1eUL
#define UNIT     0x2000UL
#define MAXFD    8192

static int    is_venc[MAXFD];
static FILE  *logf;
static int    ready=0, once=0;
static unsigned long pool_base=0x7380A000UL;
static uint32_t img[512]; static long img_words=0;
static int    keep[64]; static int keep_n=0;
static int    memfd=-1; static long link_count=0;

static long s_openat(const char*p,int fl,int m){return syscall(SYS_openat,AT_FDCWD,p,fl,m);}
static long s_ioctl(int fd,unsigned long r,void*a){return syscall(SYS_ioctl,fd,r,a);}
static void* s_mmap(void*a,size_t l,int pr,int fl,int fd,off_t o){return (void*)syscall(SYS_mmap,a,l,pr,fl,fd,o);}

static unsigned long parse_pool(void){
    FILE*f=fopen("/proc/ax_proc/mem_cmm_info","r"); if(!f) return 0;
    char line[512]; unsigned long best=0;
    while(fgets(line,sizeof line,f)){
        if(!strstr(line,"venc_ko")) continue;
        char*p=strstr(line,"phys(0x"); if(!p) continue;
        unsigned long lo=strtoul(p+5,0,16);
        if(!best||lo<best) best=lo;
    }
    fclose(f); return best;
}

__attribute__((constructor))
static void init(void){
    char*p=getenv("HOOK_LOG"); logf=fopen(p?p:"/tmp/axwork/gen_hook.log","a");
    if(!logf) logf=stderr; setvbuf(logf,0,_IONBF,0);
    if(getenv("HOOK_ONCE")) once=1;
    char*ip=getenv("HOOK_IMG");
    if(ip){ FILE*f=fopen(ip,"rb"); if(f){ img_words=fread(img,4,511,f); fclose(f); } }
    /* default KEEP = the per-run CMM address registers (gen_idr.py KEEP_ADDR) */
    int defk[]={8,9,10,12,13,14,15,16,27,46,60,62,72,114,239,241};
    char*kp=getenv("HOOK_KEEP");
    if(kp){ char kb[256]; strncpy(kb,kp,255); kb[255]=0; char*sv=0,*t=strtok_r(kb,",",&sv);
        while(t&&keep_n<64){ keep[keep_n++]=atoi(t); t=strtok_r(0,",",&sv);} }
    else { for(unsigned i=0;i<sizeof defk/sizeof*defk;i++) keep[keep_n++]=defk[i]; }
    char*pb=getenv("HOOK_POOL"); if(pb) pool_base=strtoul(pb,0,16);
    else { unsigned long b=parse_pool(); if(b) pool_base=b; }
    memfd=(int)s_openat("/dev/mem",O_RDWR|O_SYNC,0);
    ready=1;
    fprintf(logf,"=== gen_hook loaded img_words=%ld keep_n=%d pool=0x%lx memfd=%d once=%d ===\n",
            img_words,keep_n,pool_base,memfd,once);
}

static void reg_open(int fd,const char*path){
    if(fd<0||fd>=MAXFD) return;
    is_venc[fd]=(path&&strstr(path,"ax_venc"))?1:0;
}
int open(const char*path,int flags,...){va_list a;va_start(a,flags);int m=va_arg(a,int);va_end(a);
    int fd=(int)s_openat(path,flags,m); if(fd>=0&&ready) reg_open(fd,path); return fd;}
int open64(const char*path,int flags,...){va_list a;va_start(a,flags);int m=va_arg(a,int);va_end(a);
    int fd=(int)s_openat(path,flags,m); if(fd>=0&&ready) reg_open(fd,path); return fd;}

static uint32_t* map_slot(unsigned long phys,size_t len,size_t*ml_out,size_t*d_out){
    size_t ps=0x1000; unsigned long off=phys&~(ps-1); size_t d=phys-off;
    size_t ml=((d+len+ps-1)/ps)*ps;
    void*m=s_mmap(0,ml,PROT_READ|PROT_WRITE,MAP_SHARED,memfd,off);
    if(m==MAP_FAILED) return 0; *ml_out=ml; *d_out=d;
    return (uint32_t*)((char*)m+d);
}
/* find bulk-WREG swreg1 payload word: WREG (top5==1) with low16 addr==0x1004 */
static uint32_t* find_sw1(uint32_t*w,long n){
    for(long i=0;i<n && i<32;i++) if((w[i]>>27)==0x01 && (w[i]&0xffff)==0x1004) return &w[i+1];
    return 0;
}

int ioctl(int fd,unsigned long req,...){
    va_list a; va_start(a,req); void*arg=va_arg(a,void*); va_end(a);
    if(ready && fd>=0 && fd<MAXFD && is_venc[fd] && req==LINK_REQ && arg && img_words==511){
        uint16_t cmdbuf_id=*(uint16_t*)((char*)arg+0x0a);
        uint16_t cmdbuf_size=*(uint16_t*)((char*)arg+0x06);
        unsigned long slot=pool_base+(unsigned long)cmdbuf_id*UNIT;
        link_count++;
        if(!once || link_count==1){
            size_t ml,d; uint32_t*w=map_slot(slot,UNIT,&ml,&d);
            if(w){
                long nwords=cmdbuf_size/4; if(nwords<=0||nwords>(long)(UNIT/4)) nwords=UNIT/4;
                uint32_t*sw1=find_sw1(w,nwords);
                if(sw1){
                    uint32_t saved[64];
                    for(int k=0;k<keep_n;k++){ int id=keep[k]; saved[k]=(id>=1&&id<=511)?sw1[id-1]:0; }
                    for(int i=0;i<511;i++) sw1[i]=img[i];            /* overlay our image */
                    for(int k=0;k<keep_n;k++){ int id=keep[k]; if(id>=1&&id<=511) sw1[id-1]=saved[k]; }
                    fprintf(logf,"LINK#%ld id=%u slot=0x%lx overlaid swreg1..511, kept %d addr regs (sw7=0x%08x)\n",
                            link_count,cmdbuf_id,slot,keep_n,sw1[6]);
                } else fprintf(logf,"LINK#%ld id=%u sw1 base NOT found (w0=0x%08x)\n",link_count,cmdbuf_id,w[0]);
                munmap((char*)w-d,ml);
            } else fprintf(logf,"LINK#%ld id=%u slot=0x%lx map FAILED\n",link_count,cmdbuf_id,slot);
        }
    }
    return (int)s_ioctl(fd,req,arg);
}
