/* stage1hook.c - LD_PRELOAD ioctl hook for Path B (LINK-time cmdbuf hijack).
 * Lets libkvm run a fully-normal encode; at the moment libkvm calls
 * LINK_RUN_CMDBUF (nr30, req 0x80086b1e, magic 'k') on /dev/ax_venc, we edit the
 * cmdbuf slot in place BEFORE the real ioctl, so libkvm's own working LINK runs
 * OUR register program. Read-only except: 32-bit word writes into the vendor cmdbuf
 * slot (permitted). No MMIO/register writes, no firmware writes.
 *
 * Modes (env HOOK_MODE): copy (B0 self-copy), qp (B1 force PIC_INIT_QP), asm (B2).
 * env: HOOK_MODE, HOOK_QP (default 40), HOOK_LOG, HOOK_ASM (path to assembled slot bin),
 *      HOOK_POOL (override cmdbuf pool base; else parsed from mem_cmm_info).
 * Build on device: gcc -O2 -fPIC -shared -o stage1hook.so stage1hook.c
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
static int    ready=0;
static int    mode=0;         /* 0 copy, 1 qp, 2 asm, 3 generic edits */
static int    forced_qp=40;
/* generic edits: image swreg idx, AND mask, OR bits -> sw[idx]=(old&andm)|orb */
#define MAXED 32
static int    ed_n=0; static int ed_idx[MAXED]; static uint32_t ed_and[MAXED], ed_or[MAXED];
static unsigned long pool_base=0x7380A000UL;
static uint32_t *asmbuf=NULL; static long asm_words=0;
static int    memfd=-1;
static long   link_count=0;

static long s_openat(const char*p,int fl,int mode){return syscall(SYS_openat,AT_FDCWD,p,fl,mode);}
static long s_ioctl(int fd,unsigned long req,void*a){return syscall(SYS_ioctl,fd,req,a);}
static void* s_mmap(void*a,size_t l,int pr,int fl,int fd,off_t o){return (void*)syscall(SYS_mmap,a,l,pr,fl,fd,o);}

static unsigned long parse_pool(void){
    FILE*f=fopen("/proc/ax_proc/mem_cmm_info","r"); if(!f) return 0;
    char line[512]; unsigned long best=0;
    while(fgets(line,sizeof line,f)){
        if(!strstr(line,"venc_ko")) continue;
        char*p=strstr(line,"phys(0x"); if(!p) continue;
        unsigned long lo=strtoul(p+5,0,16);
        if(!best||lo<best) best=lo;   /* first/lowest venc_ko block = cmdbuf pool */
    }
    fclose(f); return best;
}

__attribute__((constructor))
static void init(void){
    char*p=getenv("HOOK_LOG"); logf=fopen(p?p:"/tmp/axwork/stage1hook.log","a");
    if(!logf) logf=stderr; setvbuf(logf,0,_IONBF,0);
    char*m=getenv("HOOK_MODE");
    if(m){ if(!strcmp(m,"qp"))mode=1; else if(!strcmp(m,"asm"))mode=2; else if(!strcmp(m,"edit"))mode=3; else mode=0; }
    char*q=getenv("HOOK_QP"); if(q) forced_qp=atoi(q);
    /* HOOK_EDITS="idx:andhex:orhex;idx:andhex:orhex;..." (image swreg idx) */
    char*ed=getenv("HOOK_EDITS");
    if(ed){ char buf[512]; strncpy(buf,ed,sizeof buf-1); buf[sizeof buf-1]=0;
        char*sv=0,*tok=strtok_r(buf,";",&sv);
        while(tok&&ed_n<MAXED){ int idx; unsigned long am,ob;
            if(sscanf(tok,"%d:%lx:%lx",&idx,&am,&ob)==3){ ed_idx[ed_n]=idx; ed_and[ed_n]=(uint32_t)am; ed_or[ed_n]=(uint32_t)ob; ed_n++; }
            tok=strtok_r(0,";",&sv); }
    }
    char*pb=getenv("HOOK_POOL"); if(pb) pool_base=strtoul(pb,0,16);
    else { unsigned long b=parse_pool(); if(b) pool_base=b; }
    memfd=(int)s_openat("/dev/mem",O_RDWR|O_SYNC,0);
    if(mode==2){
        char*ap=getenv("HOOK_ASM");
        if(ap){ FILE*af=fopen(ap,"rb"); if(af){ fseek(af,0,SEEK_END); long n=ftell(af); fseek(af,0,SEEK_SET);
            asmbuf=malloc(n); asm_words=n/4; fread(asmbuf,1,n,af); fclose(af); } }
    }
    ready=1;
    fprintf(logf,"=== stage1hook loaded mode=%d qp=%d pool=0x%lx memfd=%d asm_words=%ld ===\n",
            mode,forced_qp,pool_base,memfd,asm_words);
}

static void reg_open(int fd,const char*path){
    if(fd<0||fd>=MAXFD) return;
    is_venc[fd] = (path && strstr(path,"ax_venc"))?1:0;
    if(is_venc[fd]&&logf) fprintf(logf,"OPEN venc fd=%d %s\n",fd,path);
}
int open(const char*path,int flags,...){va_list a;va_start(a,flags);int m=va_arg(a,int);va_end(a);
    int fd=(int)s_openat(path,flags,m); if(fd>=0&&ready) reg_open(fd,path); return fd;}
int open64(const char*path,int flags,...){va_list a;va_start(a,flags);int m=va_arg(a,int);va_end(a);
    int fd=(int)s_openat(path,flags,m); if(fd>=0&&ready) reg_open(fd,path); return fd;}

/* map a cmdbuf slot page-range via /dev/mem RW; returns mapping + delta */
static uint32_t* map_slot(unsigned long phys,size_t len,size_t*maplen_out,size_t*delta_out){
    size_t ps=0x1000; unsigned long off=phys&~(ps-1); size_t delta=phys-off;
    size_t maplen=((delta+len+ps-1)/ps)*ps;
    void*m=s_mmap(0,maplen,PROT_READ|PROT_WRITE,MAP_SHARED,memfd,off);
    if(m==MAP_FAILED) return 0;
    *maplen_out=maplen; *delta_out=delta;
    return (uint32_t*)((char*)m+delta);
}

/* find bulk-WREG payload base (image swreg1) inside the slot: the WREG (top5==1)
 * whose low-16 addr == 0x1004. Returns pointer to swreg1 payload word, or NULL. */
static uint32_t* find_swreg_base(uint32_t*w,long nwords){
    for(long i=0;i<nwords && i<32;i++){
        uint32_t cw=w[i];
        if((cw>>27)==0x01 && (cw&0xffff)==0x1004) return &w[i+1];
    }
    return 0;
}

int ioctl(int fd,unsigned long req,...){
    va_list a; va_start(a,req); void*arg=va_arg(a,void*); va_end(a);
    if(ready && fd>=0 && fd<MAXFD && is_venc[fd] && req==LINK_REQ && arg){
        uint16_t cmdbuf_id=*(uint16_t*)((char*)arg+0x0a);
        uint16_t cmdbuf_size=*(uint16_t*)((char*)arg+0x06);
        unsigned long slot=pool_base+(unsigned long)cmdbuf_id*UNIT;
        size_t maplen,delta; uint32_t*w=map_slot(slot,UNIT,&maplen,&delta);
        link_count++;
        if(w){
            long nwords=cmdbuf_size/4; if(nwords<=0||nwords>(long)(UNIT/4)) nwords=UNIT/4;
            char*dp=getenv("HOOK_DUMP");
            if(dp && link_count==1){ FILE*df=fopen(dp,"wb"); if(df){ fwrite(w,4,nwords,df); fclose(df);
                fprintf(logf,"LINK#1 id=%u DUMPED %ld words (0x%x bytes) -> %s\n",cmdbuf_id,nwords,cmdbuf_size,dp); } }
            if(mode==0){
                /* B0: self-copy every word (proves write path, no semantic change) */
                for(long i=0;i<nwords;i++){ uint32_t v=w[i]; w[i]=v; }
                fprintf(logf,"LINK#%ld id=%u size=0x%x slot=0x%lx mode=copy (self-copy %ld words)\n",
                        link_count,cmdbuf_id,cmdbuf_size,slot,nwords);
            } else if(mode==1){
                /* B1: force PIC_INIT_QP = swreg7[31:26] */
                uint32_t*sw1=find_swreg_base(w,nwords);
                if(sw1){
                    uint32_t*sw7=sw1+6;               /* image swreg7 */
                    uint32_t old=*sw7;
                    uint32_t nv=(old&0x03FFFFFFu)|(((uint32_t)(forced_qp&0x3f))<<26);
                    *sw7=nv;
                    fprintf(logf,"LINK#%ld id=%u size=0x%x slot=0x%lx mode=qp swreg7 0x%08x->0x%08x (QP %u->%d)\n",
                            link_count,cmdbuf_id,cmdbuf_size,slot,old,nv,(old>>26)&0x3f,forced_qp);
                } else {
                    fprintf(logf,"LINK#%ld id=%u mode=qp: swreg1 base NOT found (word0=0x%08x)!\n",
                            link_count,cmdbuf_id,w[0]);
                }
            } else if(mode==3){
                /* generic: apply each image-swreg edit in the bulk-WREG payload */
                uint32_t*sw1=find_swreg_base(w,nwords);
                if(sw1){
                    for(int e=0;e<ed_n;e++){ uint32_t*p=sw1+(ed_idx[e]-1); uint32_t old=*p;
                        uint32_t nv=(old&ed_and[e])|ed_or[e]; *p=nv;
                        fprintf(logf,"LINK#%ld id=%u edit swreg%d 0x%08x->0x%08x\n",link_count,cmdbuf_id,ed_idx[e],old,nv); }
                } else fprintf(logf,"LINK#%ld id=%u mode=edit: swreg1 base NOT found\n",link_count,cmdbuf_id);
            } else if(mode==2 && asmbuf && link_count==1){
                /* B2: overwrite whole program with assembled slot bytes, but PRESERVE
                 * this-run's address/position registers (HOOK_KEEP="8,9,..." image idx)
                 * from libkvm's live program so DMA/output stay valid this run. */
                uint32_t*sw1_live=find_swreg_base(w,nwords);
                uint32_t*sw1_asm =find_swreg_base(asmbuf,asm_words);
                char*keep=getenv("HOOK_KEEP"); uint32_t saved[64]; int kidx[64]; int kn=0;
                if(keep && sw1_live){ char kb[256]; strncpy(kb,keep,255); kb[255]=0; char*sv=0,*t=strtok_r(kb,",",&sv);
                    while(t&&kn<64){ int id=atoi(t); kidx[kn]=id; saved[kn]=sw1_live[id-1]; kn++; t=strtok_r(0,",",&sv); } }
                long n=asm_words; if(n>(long)(UNIT/4)) n=UNIT/4;
                for(long i=0;i<n;i++) w[i]=asmbuf[i];
                if(sw1_asm && sw1_live){ long boff=sw1_live-w; /* restore keeps at same word offset */
                    for(int e=0;e<kn;e++){ long wi=boff+(kidx[e]-1); if(wi>=0&&wi<n) w[wi]=saved[e]; } }
                uint16_t nsz=(uint16_t)(n*4);
                *(uint16_t*)((char*)arg+0x06)=nsz;
                fprintf(logf,"LINK#%ld id=%u slot=0x%lx mode=asm wrote %ld words keep=%d, cmdbuf_size 0x%x->0x%x\n",
                        link_count,cmdbuf_id,slot,n,kn,cmdbuf_size,nsz);
            }
            munmap((char*)w-delta,maplen);
        } else {
            fprintf(logf,"LINK#%ld id=%u slot=0x%lx map FAILED\n",link_count,cmdbuf_id,slot);
        }
    }
    return (int)s_ioctl(fd,req,arg);
}
