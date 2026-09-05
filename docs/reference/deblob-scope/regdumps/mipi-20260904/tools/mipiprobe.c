/* mipiprobe.c -- drive the VENDOR MIPI RX through its public MPI API
 * (AX_SYS_Init -> AX_MIPI_RX_Init -> SetLaneCombo -> SetAttr -> [Reset] ->
 * Start -> Stop -> DeInit) and snapshot the CSI-2 controller / D-PHY /
 * isp_sys_glb / common_glb register banks via read-only /dev/mem mmap
 * (word loops only) at each stage.  Read-only on hardware except through
 * the MPI.  Run with nanokvm stopped.
 *
 * usage: mipiprobe tag=NAME lanes=4 rate=600 reset=0 combo=0 out=/tmp/axwork/mipi
 * Output: <out>/<tag>-<stage>-<base>.bin  and  <out>/<tag>.txt
 * stages: pre (after Init+SetLaneCombo), attr (after SetAttr), [rst], start, stop */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>
#include "ax_sys_api.h"
#include "ax_mipi_rx_api.h"

static const char *TAG="run", *OUT="/tmp/axwork/mipi";
static int LANES=4, RATE=600, RESET=0, COMBO=0, DELAY=300, ORDER=0;
static FILE *LOG;
#define P(...) do{ printf(__VA_ARGS__); printf("\n"); fflush(stdout); if(LOG){fprintf(LOG,__VA_ARGS__); fprintf(LOG,"\n"); fflush(LOG);} }while(0)

static int memfd=-1;
struct bank { const char *name; unsigned long base, len; volatile uint32_t *map; };
static struct bank banks[] = {
    {"02600000", 0x02600000, 0x4000, 0},
    {"023f0000", 0x023f0000, 0x1000, 0},
    {"02500000", 0x02500000, 0x800,  0},
    {"02340000", 0x02340000, 0x1000, 0},
};
#define NB (sizeof(banks)/sizeof(banks[0]))

static int map_banks(void){
    memfd = open("/dev/mem", O_RDONLY|O_SYNC);
    if(memfd<0){perror("open /dev/mem"); return -1;}
    for(unsigned i=0;i<NB;i++){
        void *m = mmap(0, banks[i].len, PROT_READ, MAP_SHARED, memfd, banks[i].base);
        if(m==MAP_FAILED){perror("mmap"); return -1;}
        banks[i].map = (volatile uint32_t*)m;
    }
    return 0;
}
static uint32_t rd(unsigned long base, unsigned long off){
    for(unsigned i=0;i<NB;i++) if(banks[i].base==base) return banks[i].map[off/4];
    return 0xffffffff;
}
static void dump_stage(const char *stage){
    char path[256];
    for(unsigned i=0;i<NB;i++){
        snprintf(path,sizeof path,"%s/%s-%s-%s.bin",OUT,TAG,stage,banks[i].name);
        FILE *f=fopen(path,"wb"); if(!f){perror(path); continue;}
        unsigned long n=banks[i].len/4;
        uint32_t *buf=malloc(banks[i].len);
        for(unsigned long k=0;k<n;k++) buf[k]=banks[i].map[k];   /* word loop, never memcpy */
        fwrite(buf,4,n,f); fclose(f); free(buf);
    }
    /* key words */
    char w[64]="?",h[64]="?",fps[64]="?"; FILE *f;
    if((f=fopen("/proc/lt6911_info/width","r"))){ if(fgets(w,sizeof w,f)) w[strcspn(w,"\n")]=0; fclose(f);}
    if((f=fopen("/proc/lt6911_info/height","r"))){ if(fgets(h,sizeof h,f)) h[strcspn(h,"\n")]=0; fclose(f);}
    if((f=fopen("/proc/lt6911_info/fps","r"))){ if(fgets(fps,sizeof fps,f)) fps[strcspn(fps,"\n")]=0; fclose(f);}
    P("[%s] csi+0x00=%08x csi+0x04=%08x csi+0x28=%08x csi+0x2c=%08x csi+0x40=%08x csi+0x4c=%08x csi+0x100=%08x csi+0x110=%08x csi+0x118=%08x | dphy+0x110=%08x dphy+0x34=%08x | glb+0x00=%08x deskew[1:0]=%u | lt6911 %sx%s@%s",
      stage, rd(0x02600000,0x00), rd(0x02600000,0x04), rd(0x02600000,0x28), rd(0x02600000,0x2c), rd(0x02600000,0x40),
      rd(0x02600000,0x4c), rd(0x02600000,0x100), rd(0x02600000,0x110), rd(0x02600000,0x118),
      rd(0x023f0000,0x110), rd(0x023f0000,0x34), rd(0x02500000,0x00), rd(0x02500000,0x00)&3, w,h,fps);
}
static void msleep(int ms){ struct timespec t={ms/1000,(ms%1000)*1000000L}; nanosleep(&t,0); }

/* ---- transition poller: tight read loop on a few words, log every change ---- */
#include <pthread.h>
static int POLL=0; static volatile int poll_stop=0; static pthread_t pth;
#define NPW 12
static const struct { unsigned long base, off; const char *name; } pw[NPW] = {
    {0x02600000,0x04,"csi+04"},{0x02600000,0x28,"csi+28"},{0x02600000,0x2c,"csi+2c"},{0x02600000,0x40,"csi+40"},
    {0x02600000,0x4c,"csi+4c"},{0x02600000,0x50,"csi+50"},{0x02600000,0x100,"csi+100"},{0x02600000,0x110,"csi+110"},
    {0x02600000,0x118,"csi+118"},{0x023f0000,0x34,"dphy+34"},{0x023f0000,0x110,"dphy+110"},{0x02500000,0x00,"glb+00"},
};
#define MAXEV 4000
static struct { uint64_t ns; uint32_t v[NPW]; } ev[MAXEV]; static int nev=0;
static uint64_t now_ns(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (uint64_t)t.tv_sec*1000000000ull+t.tv_nsec; }
static void *poller(void *a){
    uint32_t prev[NPW]; for(int i=0;i<NPW;i++) prev[i]=0xfeedface;
    while(!poll_stop){
        uint32_t cur[NPW]; int ch=0;
        for(int i=0;i<NPW;i++){ cur[i]=rd(pw[i].base,pw[i].off); if(cur[i]!=prev[i]) ch=1; }
        if(ch && nev<MAXEV){ ev[nev].ns=now_ns(); for(int i=0;i<NPW;i++) ev[nev].v[i]=cur[i]; nev++; }
        for(int i=0;i<NPW;i++) prev[i]=cur[i];
    }
    return a;
}
static void poll_flush(void){
    char path[256]; snprintf(path,sizeof path,"%s/%s-poll.txt",OUT,TAG);
    FILE *f=fopen(path,"w"); if(!f) return;
    fprintf(f,"# transitions of watched words during Start..Stop (t0 = first sample); %d events\n# t_us", nev);
    for(int i=0;i<NPW;i++) fprintf(f," %s",pw[i].name); fprintf(f,"\n");
    for(int e=0;e<nev;e++){ fprintf(f,"%8.1f",(ev[e].ns-ev[0].ns)/1000.0); for(int i=0;i<NPW;i++) fprintf(f," %08x",ev[e].v[i]); fprintf(f,"\n"); }
    fclose(f); P("poll: %d transition events -> %s", nev, path);
}

int main(int argc,char**argv){
    for(int i=1;i<argc;i++){
        char *k=argv[i], *v=strchr(k,'='); if(!v) continue; *v++=0;
        if(!strcmp(k,"tag")) TAG=v; else if(!strcmp(k,"out")) OUT=v;
        else if(!strcmp(k,"lanes")) LANES=atoi(v); else if(!strcmp(k,"rate")) RATE=atoi(v);
        else if(!strcmp(k,"reset")) RESET=atoi(v); else if(!strcmp(k,"combo")) COMBO=atoi(v);
        else if(!strcmp(k,"delay")) DELAY=atoi(v); else if(!strcmp(k,"order")) ORDER=atoi(v); else if(!strcmp(k,"poll")) POLL=atoi(v);
    }
    char lp[256]; snprintf(lp,sizeof lp,"%s/%s.txt",OUT,TAG); LOG=fopen(lp,"w");
    P("mipiprobe tag=%s lanes=%d rate=%d reset=%d combo=%d delay=%d", TAG,LANES,RATE,RESET,COMBO,DELAY);
    if(map_banks()) return 1;
    AX_S32 r;
    r=AX_SYS_Init();            P("AX_SYS_Init=%d",r);
    r=AX_MIPI_RX_Init();        P("AX_MIPI_RX_Init=%d",r);
    if(!ORDER){ r=AX_MIPI_RX_SetLaneCombo((AX_LANE_COMBO_MODE_E)COMBO); P("AX_MIPI_RX_SetLaneCombo(%d)=%d",COMBO,r); }
    dump_stage("pre");
    AX_MIPI_RX_DEV_T dev; memset(&dev,0,sizeof dev);
    dev.eInputMode = AX_INPUT_MODE_MIPI;
    dev.tMipiAttr.ePhyMode = AX_MIPI_PHY_TYPE_DPHY;
    dev.tMipiAttr.eLaneNum = (AX_MIPI_LANE_NUM_E)LANES;
    dev.tMipiAttr.nDataRate = RATE;
    dev.tMipiAttr.nDataLaneMap[0]=0; dev.tMipiAttr.nDataLaneMap[1]=1;
    dev.tMipiAttr.nDataLaneMap[2]=3; dev.tMipiAttr.nDataLaneMap[3]=4;
    dev.tMipiAttr.nClkLane[0]=2; dev.tMipiAttr.nClkLane[1]=5;
    P("sizeof(AX_MIPI_RX_DEV_T)=%zu", sizeof dev);
    r=AX_MIPI_RX_SetAttr(0,&dev); P("AX_MIPI_RX_SetAttr(0,{lanes=%d,rate=%d})=%d (0x%x)",LANES,RATE,r,(unsigned)r);
    AX_MIPI_RX_DEV_T got; memset(&got,0,sizeof got);
    r=AX_MIPI_RX_GetAttr(0,&got); P("AX_MIPI_RX_GetAttr=%d -> mode=%d phy=%d lanes=%d rate=%u map=%d,%d,%d,%d clk=%d,%d", r, got.eInputMode, got.tMipiAttr.ePhyMode, got.tMipiAttr.eLaneNum, got.tMipiAttr.nDataRate, got.tMipiAttr.nDataLaneMap[0],got.tMipiAttr.nDataLaneMap[1],got.tMipiAttr.nDataLaneMap[2],got.tMipiAttr.nDataLaneMap[3],got.tMipiAttr.nClkLane[0],got.tMipiAttr.nClkLane[1]);
    if(ORDER){ r=AX_MIPI_RX_SetLaneCombo((AX_LANE_COMBO_MODE_E)COMBO); P("AX_MIPI_RX_SetLaneCombo(%d)=%d (after SetAttr)",COMBO,r); }
    dump_stage("attr");
    if(POLL){ pthread_create(&pth,0,poller,0); msleep(20); }
    if(RESET){ r=AX_MIPI_RX_Reset(0); P("AX_MIPI_RX_Reset(0)=%d",r); msleep(50); dump_stage("rst"); }
    r=AX_MIPI_RX_Start(0);      P("AX_MIPI_RX_Start(0)=%d (0x%x)",r,(unsigned)r);
    msleep(DELAY);
    dump_stage("start");
    msleep(DELAY);
    dump_stage("start2");
    r=AX_MIPI_RX_Stop(0);       P("AX_MIPI_RX_Stop(0)=%d",r);
    msleep(100);
    dump_stage("stop");
    if(POLL){ poll_stop=1; pthread_join(pth,0); poll_flush(); }
    r=AX_MIPI_RX_DeInit();      P("AX_MIPI_RX_DeInit=%d",r);
    r=AX_SYS_Deinit();          P("AX_SYS_Deinit=%d",r);
    P("DONE");
    return 0;
}
