/* vdrive.c -- drive the VENDOR AX_VENC through its public MPI API with a
 * synthetic YUYV frame from a real AX_POOL block, snapshot the venc_ko CMM
 * pools (cmdbuf WREG programs) after chosen frames, log per-frame NAL sizes
 * and the API-reported QPs, save the bitstream.  Built against the published
 * SDK headers (.#axera-libs).  Read-only on hardware except through the MPI.
 *
 * 2026-09-05 (HEVC campaign, #64): codec=h264|h265 selects PT_H264/PT_H265 and
 * the matching RC enums; tier=, gopmode=normalp|oneltr|svct, ltrint=, ltrqpo=.
 * The H265 RC structs are typedef aliases of the H264 ones and live in the same
 * union, so the field writes below go through the stH264* members for both.
 *
 * usage: vdrive key=val ...   (see parse below).  Run with nanokvm stopped. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include "ax_sys_api.h"
#include "ax_venc_api.h"

static int W=1920,H=1080,FPS=60,DFPS=-1,GOP=30,BR=8000,IQP=32,PQP=32,PROFILE=-1,LEVEL=-1,TIER=0;
static int MINQP=10,MAXQP=51,MINIQP=10,MAXIQP=51,IQD=0,FIRSTQP=-1,MAXIPROP=40,MINIPROP=10,IDRRANGE=2,STATTIME=1,VQ=0;
static int NFRAMES=6,CHN=7,MOVE=0,SNAPALL=0,IR=0,IRMODE=0,SLICE=0,DEBREATH=0,SCD=-1,ROWQPD=-1;
static int SETRC=0; /* 1: also push the same RC via AX_VENC_SetRcParam after create */
static int SHARE=0, REFRING=0, DBQD=0, SCT=-1, CHGPOS=-1, STILLPCT=-1, STILLQP=-1;
static int H265=0, LTRINT=0, LTRQPO=0, VUI=-1, MODID=0x11, STRIDE=-1, FMT=-1;
static const char *RC="cbr", *TAG="run", *OUT="/tmp/axwork/run", *CODEC="h264", *GOPMODE="normalp";
static FILE *LOG;

#define P(...) do{ printf(__VA_ARGS__); printf("\n"); fflush(stdout); if(LOG){fprintf(LOG,__VA_ARGS__); fprintf(LOG,"\n"); fflush(LOG);} }while(0)

/* ---- venc_ko CMM pool scan + raw dump ---- */
struct blk { uint64_t base; uint64_t len; };
static int venc_blocks(struct blk *b, int max) {
    FILE *f = fopen("/proc/ax_proc/mem_cmm_info","r"); char line[512]; int n=0;
    if(!f) return 0;
    while(fgets(line,sizeof line,f)) {
        if(!strstr(line,"venc_ko")) continue;
        char *p = strstr(line,"phys(0x"); if(!p) continue;
        unsigned long lo, hi; if(sscanf(p,"phys(0x%lx, 0x%lx)",&lo,&hi)!=2) continue;
        if(n<max){ b[n].base=lo; b[n].len=hi-lo+1; n++; }
    }
    fclose(f); return n;
}
static void dump_phys(uint64_t base, uint64_t len, const char *fn) {
    int fd = open("/dev/mem", O_RDONLY|O_SYNC); if(fd<0){P("!! /dev/mem open failed");return;}
    uint64_t off = base & ~0xfffULL, delta = base-off, maplen = ((delta+len+0xfff)/0x1000)*0x1000;
    volatile uint32_t *m = mmap(NULL, maplen, PROT_READ, MAP_SHARED, fd, off);
    if(m==MAP_FAILED){P("!! mmap 0x%lx failed",(unsigned long)base); close(fd); return;}
    uint32_t *buf = malloc(len); /* word loop: no memcpy on Device memory */
    for(uint64_t i=0;i<len/4;i++) buf[i] = m[delta/4+i];
    FILE *f=fopen(fn,"wb"); fwrite(buf,1,len,f); fclose(f); free(buf);
    munmap((void*)m,maplen); close(fd);
}
static void snapshot(const char *phase) {
    struct blk b[8]; int n = venc_blocks(b,8); char fn[512];
    if(!n){P("!! no venc_ko blocks"); return;}
    for(int i=0;i<n;i++){
        snprintf(fn,sizeof fn,"%s/%s_%s_%s_0x%08lx.bin", OUT, i==0?"cmdpool":"vencblk", TAG, phase,(unsigned long)b[i].base);
        if(i==0 || SNAPALL<2) dump_phys(b[i].base,b[i].len,fn);
    }
    P("  snapshot %s: %d venc_ko blocks (pool0 0x%08lx len 0x%lx)", phase, n,(unsigned long)b[0].base,(unsigned long)b[0].len);
}

/* ---- test card ---- */
static void fill(uint8_t *dst, int i) {
    /* i<0 or MOVE=0: the exact 17-geometry probe card (static). MOVE: scrolls. */
    int sx = MOVE ? 8*i : 0;
    for(int y=0;y<H;y++){
        uint8_t *row = dst + (size_t)y*W*2;
        int sy = MOVE ? (y>>4)*4 : 0;
        for(int x=0;x<W;x++){
            int xx = x + sx + sy; int g = ((xx % W) * 255) / (W>1?W-1:1);
            int v = g ^ ((((x + (MOVE?4*i:0)) / 64) & 1) ? 0x40 : 0);
            if(MOVE && ((y/32 + i/2) & 1)) v ^= 0x20;
            row[2*x] = (uint8_t)v; row[2*x+1] = 0x80;
        }
    }
}

static int kv(const char *a, const char *k, const char **v){ size_t l=strlen(k); if(!strncmp(a,k,l)&&a[l]=='='){*v=a+l+1;return 1;} return 0; }

int main(int argc, char **argv){
    const char *v;
    for(int i=1;i<argc;i++){
        char *a=argv[i];
        if(kv(a,"w",&v)) W=atoi(v); else if(kv(a,"h",&v)) H=atoi(v); else if(kv(a,"fps",&v)) FPS=atoi(v);
        else if(kv(a,"dfps",&v)) DFPS=atoi(v); else if(kv(a,"gop",&v)) GOP=atoi(v); else if(kv(a,"br",&v)) BR=atoi(v);
        else if(kv(a,"rc",&v)) RC=v; else if(kv(a,"iqp",&v)) IQP=atoi(v); else if(kv(a,"pqp",&v)) PQP=atoi(v);
        else if(kv(a,"profile",&v)) PROFILE=atoi(v); else if(kv(a,"level",&v)) LEVEL=atoi(v); else if(kv(a,"tier",&v)) TIER=atoi(v);
        else if(kv(a,"codec",&v)) CODEC=v; else if(kv(a,"gopmode",&v)) GOPMODE=v;
        else if(kv(a,"modid",&v)) MODID=strtol(v,0,0); else if(kv(a,"stride",&v)) STRIDE=atoi(v); else if(kv(a,"fmt",&v)) FMT=strtol(v,0,0);
        else if(kv(a,"ltrint",&v)) LTRINT=atoi(v); else if(kv(a,"ltrqpo",&v)) LTRQPO=atoi(v); else if(kv(a,"vui",&v)) VUI=atoi(v);
        else if(kv(a,"minqp",&v)) MINQP=atoi(v); else if(kv(a,"maxqp",&v)) MAXQP=atoi(v);
        else if(kv(a,"miniqp",&v)) MINIQP=atoi(v); else if(kv(a,"maxiqp",&v)) MAXIQP=atoi(v);
        else if(kv(a,"iqd",&v)) IQD=atoi(v); else if(kv(a,"firstqp",&v)) FIRSTQP=atoi(v);
        else if(kv(a,"maxiprop",&v)) MAXIPROP=atoi(v); else if(kv(a,"miniprop",&v)) MINIPROP=atoi(v);
        else if(kv(a,"idrrange",&v)) IDRRANGE=atoi(v); else if(kv(a,"stattime",&v)) STATTIME=atoi(v);
        else if(kv(a,"vq",&v)) VQ=atoi(v); else if(kv(a,"nframes",&v)) NFRAMES=atoi(v); else if(kv(a,"chn",&v)) CHN=atoi(v);
        else if(kv(a,"move",&v)) MOVE=atoi(v); else if(kv(a,"snapall",&v)) SNAPALL=atoi(v);
        else if(kv(a,"ir",&v)) IR=atoi(v); else if(kv(a,"irmode",&v)) IRMODE=atoi(v); else if(kv(a,"slice",&v)) SLICE=atoi(v);
        else if(kv(a,"debreath",&v)) DEBREATH=atoi(v); else if(kv(a,"scd",&v)) SCD=atoi(v); else if(kv(a,"rowqpd",&v)) ROWQPD=atoi(v);
        else if(kv(a,"setrc",&v)) SETRC=atoi(v); else if(kv(a,"share",&v)) SHARE=atoi(v); else if(kv(a,"refring",&v)) REFRING=atoi(v);
        else if(kv(a,"dbqd",&v)) DBQD=atoi(v); else if(kv(a,"sct",&v)) SCT=atoi(v); else if(kv(a,"chgpos",&v)) CHGPOS=atoi(v);
        else if(kv(a,"stillpct",&v)) STILLPCT=atoi(v); else if(kv(a,"stillqp",&v)) STILLQP=atoi(v);
        else if(kv(a,"tag",&v)) TAG=v; else if(kv(a,"out",&v)) OUT=v;
        else { fprintf(stderr,"unknown arg %s\n",a); return 2; }
    }
    if(DFPS<0) DFPS=FPS;
    H265 = !strcmp(CODEC,"h265");
    if(PROFILE<0) PROFILE = H265 ? 0 : 10;      /* HEVC Main / H264 Main */
    if(LEVEL<0)   LEVEL   = H265 ? 153 : 51;    /* HEVC 5.1 (=5.1*30) / H264 5.1 */
    mkdir(OUT,0755); char fn[512];
    snprintf(fn,sizeof fn,"%s/%s.log",OUT,TAG); LOG=fopen(fn,"w");
    P("# vdrive tag=%s codec=%s %dx%d rc=%s br=%d fps=%d/%d gop=%d gopmode=%s ltrint=%d ltrqpo=%d iqp=%d pqp=%d profile=%d level=%d tier=%d qp[%d..%d] iqp[%d..%d] iqd=%d firstqp=%d iprop[%d..%d] idrrange=%d stattime=%d vq=%d ir=%d/%d slice=%d debreath=%d scd=%d rowqpd=%d vui=%d move=%d nframes=%d",
      TAG,CODEC,W,H,RC,BR,FPS,DFPS,GOP,GOPMODE,LTRINT,LTRQPO,IQP,PQP,PROFILE,LEVEL,TIER,MINQP,MAXQP,MINIQP,MAXIQP,IQD,FIRSTQP,MINIPROP,MAXIPROP,IDRRANGE,STATTIME,VQ,IR,IRMODE,SLICE,DEBREATH,SCD,ROWQPD,VUI,MOVE,NFRAMES);

    AX_S32 rc = AX_SYS_Init(); P("AX_SYS_Init rc=0x%x", rc);
    AX_VENC_MOD_ATTR_T mod; memset(&mod,0,sizeof mod);
    mod.enVencType = AX_VENC_MULTI_ENCODER; mod.stModThdAttr.u32TotalThreadNum=1; mod.stModThdAttr.bExplicitSched=AX_FALSE;
    rc = AX_VENC_Init(&mod); P("AX_VENC_Init rc=0x%x", rc);

    AX_VENC_CHN_ATTR_T va; memset(&va,0,sizeof va);
    va.stVencAttr.enType=H265?PT_H265:PT_H264; va.stVencAttr.u32MaxPicWidth=W; va.stVencAttr.u32MaxPicHeight=H;
    va.stVencAttr.u32PicWidthSrc=W; va.stVencAttr.u32PicHeightSrc=H;
    va.stVencAttr.enMemSource=AX_MEMORY_SOURCE_CMM; va.stVencAttr.enLinkMode=AX_UNLINK_MODE;
    va.stVencAttr.u8InFifoDepth=2; va.stVencAttr.u8OutFifoDepth=2;
    va.stVencAttr.u32BufSize=(AX_U32)W*H*2u;
    va.stVencAttr.enProfile=(AX_VENC_PROFILE_E)PROFILE; va.stVencAttr.enLevel=(AX_VENC_LEVEL_E)LEVEL;
    va.stVencAttr.enTier=(AX_VENC_TIER_E)TIER;
    va.stVencAttr.bDeBreathEffect = DEBREATH?AX_TRUE:AX_FALSE;
    va.stVencAttr.bRefRingbuf = REFRING?AX_TRUE:AX_FALSE;
    if(H265) va.stVencAttr.stAttrH265e.bRcnRefShareBuf = SHARE?AX_TRUE:AX_FALSE;
    else     va.stVencAttr.stAttrH264e.bRcnRefShareBuf = SHARE?AX_TRUE:AX_FALSE;
    AX_VENC_RC_ATTR_T *r=&va.stRcAttr;
    r->stFrameRate.fSrcFrameRate=FPS; r->stFrameRate.fDstFrameRate=DFPS; r->s32FirstFrameStartQp=FIRSTQP;
#define RCM(x) (H265 ? AX_VENC_RC_MODE_H265##x : AX_VENC_RC_MODE_H264##x)
    if(!strcmp(RC,"cbr")){ r->enRcMode=RCM(CBR); AX_VENC_H264_CBR_T *c=&r->stH264Cbr;
        c->u32Gop=GOP;c->u32StatTime=STATTIME;c->u32BitRate=BR;c->u32MinQp=MINQP;c->u32MaxQp=MAXQP;c->u32MinIQp=MINIQP;c->u32MaxIQp=MAXIQP;
        c->u32MaxIprop=MAXIPROP;c->u32MinIprop=MINIPROP;c->u32IdrQpDeltaRange=IDRRANGE;c->s32IntraQpDelta=IQD;c->s32DeBreathQpDelta=DBQD; }
    else if(!strcmp(RC,"vbr")){ r->enRcMode=RCM(VBR); AX_VENC_H264_VBR_T *c=&r->stH264Vbr;
        c->u32Gop=GOP;c->u32StatTime=STATTIME;c->u32MaxBitRate=BR;c->enVQ=(AX_VENC_VBR_QUALITY_LEVEL_E)VQ;c->u32MinQp=MINQP;c->u32MaxQp=MAXQP;c->u32MinIQp=MINIQP;c->u32MaxIQp=MAXIQP;
        c->u32IdrQpDeltaRange=IDRRANGE;c->s32IntraQpDelta=IQD;c->s32DeBreathQpDelta=DBQD; if(SCT>=0)c->u32SceneChgThr=SCT; if(CHGPOS>=0)c->u32ChangePos=CHGPOS; }
    else if(!strcmp(RC,"avbr")){ r->enRcMode=RCM(AVBR); AX_VENC_H264_AVBR_T *c=&r->stH264AVbr;
        c->u32Gop=GOP;c->u32StatTime=STATTIME;c->u32MaxBitRate=BR;c->u32MinQp=MINQP;c->u32MaxQp=MAXQP;c->u32MinIQp=MINIQP;c->u32MaxIQp=MAXIQP;
        c->u32IdrQpDeltaRange=IDRRANGE;c->s32IntraQpDelta=IQD;c->s32DeBreathQpDelta=DBQD; c->u32SceneChgThr=SCT>=0?SCT:5; c->u32ChangePos=CHGPOS>=0?CHGPOS:90;
        c->u32MinStillPercent=STILLPCT>=0?STILLPCT:25; c->u32MaxStillQp=STILLQP>=0?STILLQP:36; }
    else if(!strcmp(RC,"qvbr")){ r->enRcMode=RCM(QVBR); r->stH264QVbr.u32Gop=GOP; r->stH264QVbr.u32StatTime=STATTIME; r->stH264QVbr.u32TargetBitRate=BR; }
    else if(!strcmp(RC,"cvbr")){ r->enRcMode=RCM(CVBR); AX_VENC_H264_CVBR_T *c=&r->stH264CVbr;
        c->u32Gop=GOP;c->u32StatTime=STATTIME;c->u32MinQp=MINQP;c->u32MaxQp=MAXQP;c->u32MinIQp=MINIQP;c->u32MaxIQp=MAXIQP;c->u32MinQpDelta=0;c->u32MaxQpDelta=0;
        c->u32IdrQpDeltaRange=IDRRANGE;c->u32MaxIprop=MAXIPROP;c->u32MinIprop=MINIPROP;c->u32MaxBitRate=BR;c->u32ShortTermStatTime=1;c->u32LongTermStatTime=1;
        c->u32LongTermMaxBitrate=BR;c->u32LongTermMinBitrate=BR/2;c->s32IntraQpDelta=IQD;c->s32DeBreathQpDelta=DBQD; }
    else if(!strcmp(RC,"fixqp")){ r->enRcMode=RCM(FIXQP); r->stH264FixQp.u32Gop=GOP; r->stH264FixQp.u32IQp=IQP; r->stH264FixQp.u32PQp=PQP; r->stH264FixQp.u32BQp=PQP; }
    else if(!strcmp(RC,"qpmap")){ r->enRcMode=RCM(QPMAP); r->stH264QpMap.u32Gop=GOP; r->stH264QpMap.u32StatTime=STATTIME; r->stH264QpMap.u32TargetBitRate=BR;
        r->stH264QpMap.stQpmapInfo.enCtbRcMode=AX_VENC_RC_CTBRC_QUALITY_RATE; r->stH264QpMap.stQpmapInfo.enQpmapQpType=AX_VENC_QPMAP_QP_DELTA;
        r->stH264QpMap.stQpmapInfo.enQpmapBlockType=AX_VENC_QPMAP_BLOCK_DISABLE; r->stH264QpMap.stQpmapInfo.enQpmapBlockUnit=AX_VENC_QPMAP_BLOCK_UNIT_16x16; }
    else { P("bad rc"); return 2; }
    if(!strcmp(GOPMODE,"normalp")) va.stGopAttr.enGopMode=AX_VENC_GOPMODE_NORMALP;
    else if(!strcmp(GOPMODE,"oneltr")){ va.stGopAttr.enGopMode=AX_VENC_GOPMODE_ONELTR;
        va.stGopAttr.stOneLTR.stPicConfig.s32QpOffset=0; va.stGopAttr.stOneLTR.stPicConfig.f32QpFactor=0.5f;
        va.stGopAttr.stOneLTR.stPicSpecialConfig.s32QpOffset=LTRQPO; va.stGopAttr.stOneLTR.stPicSpecialConfig.f32QpFactor=0.5f;
        va.stGopAttr.stOneLTR.stPicSpecialConfig.s32Interval=LTRINT>0?LTRINT:4; }
    else if(!strcmp(GOPMODE,"svct")){ va.stGopAttr.enGopMode=AX_VENC_GOPMODE_SVC_T; va.stGopAttr.stSvcT.s8SvcTCfg=NULL; va.stGopAttr.stSvcT.u32GopSize=GOP; }
    else { P("bad gopmode"); return 2; }

    rc = AX_VENC_CreateChn(CHN,&va); P("AX_VENC_CreateChn(%d) rc=0x%x", CHN, rc);
    if(rc){ P("REFUSED create rc=0x%x", rc); AX_VENC_Deinit(); AX_SYS_Deinit(); return 3; }
    if(SETRC){ AX_VENC_RC_PARAM_T rp; memset(&rp,0,sizeof rp); rc=AX_VENC_GetRcParam(CHN,&rp); P("GetRcParam rc=0x%x rowqpd=%u firstqp=%d mode=%d scd=%d/%d",rc,rp.u32RowQpDelta,rp.s32FirstFrameStartQp,rp.enRcMode,rp.stSceneChangeDetect.bDetectSceneChange,rp.stSceneChangeDetect.bAdaptiveInsertIDRFrame);
        if(ROWQPD>=0) rp.u32RowQpDelta=ROWQPD; if(SCD>=0){rp.stSceneChangeDetect.bDetectSceneChange=SCD?AX_TRUE:AX_FALSE; rp.stSceneChangeDetect.bAdaptiveInsertIDRFrame=SCD>1?AX_TRUE:AX_FALSE;}
        rc=AX_VENC_SetRcParam(CHN,&rp); P("SetRcParam rc=0x%x",rc); }
    if(IR){ AX_VENC_INTRA_REFRESH_T ir; memset(&ir,0,sizeof ir); ir.bRefresh=AX_TRUE; ir.u32RefreshNum=IR; ir.u32ReqIQp=IQP; ir.enIntraRefreshMode=(AX_VENC_INTRA_REFRESH_MODE_E)IRMODE;
        rc=AX_VENC_SetIntraRefresh(CHN,&ir); P("SetIntraRefresh(%d,mode %d) rc=0x%x",IR,IRMODE,rc); }
    if(SLICE){ AX_VENC_SLICE_SPLIT_T ss; memset(&ss,0,sizeof ss); ss.bSplit=AX_TRUE; ss.u32LcuLineNum=SLICE; rc=AX_VENC_SetSliceSplit(CHN,&ss); P("SetSliceSplit(%d) rc=0x%x",SLICE,rc); }
#ifdef HAVE_VUI
    if(VUI>=0){ AX_VENC_VUI_PARAM_T vp; memset(&vp,0,sizeof vp); rc=AX_VENC_GetVuiParam(CHN,&vp); P("GetVuiParam rc=0x%x",rc);
        vp.stVuiTimeInfo.timing_info_present_flag=VUI?1:0; rc=AX_VENC_SetVuiParam(CHN,&vp); P("SetVuiParam(%d) rc=0x%x",VUI,rc); }
#endif
    AX_VENC_RECV_PIC_PARAM_T recv={.s32RecvPicNum=-1}; rc=AX_VENC_StartRecvFrame(CHN,&recv); P("StartRecvFrame rc=0x%x",rc);

    /* input frame from a real AX_POOL block */
    AX_U64 size=(AX_U64)W*H*2; AX_POOL_CONFIG_T pc; memset(&pc,0,sizeof pc);
    pc.MetaSize=4096; pc.BlkSize=size; pc.BlkCnt=2; pc.IsMergeMode=AX_FALSE; pc.CacheMode=AX_POOL_CACHE_MODE_NONCACHE;
    strcpy((char*)pc.PartitionName,"anonymous"); strcpy((char*)pc.PoolName,"vdrive");
    AX_POOL pool=AX_POOL_CreatePool(&pc); P("AX_POOL_CreatePool id=0x%x",pool);
    if(pool==AX_INVALID_POOLID){ AX_VENC_DestroyChn(CHN); AX_VENC_Deinit(); AX_SYS_Deinit(); return 4; }
    AX_BLK blk=AX_POOL_GetBlock(pool,size,NULL); AX_U64 phys=AX_POOL_Handle2PhysAddr(blk);
    uint8_t *virt=AX_SYS_Mmap(phys,(AX_U32)size); P("blk=0x%x phys=0x%llx virt=%p",blk,(unsigned long long)phys,virt);
    if(!virt){ P("mmap fail"); return 4; }
    uint8_t *card = malloc(size);

    AX_VIDEO_FRAME_INFO_T fi; memset(&fi,0,sizeof fi);
    fi.stVFrame.u32Width=W; fi.stVFrame.u32Height=H; fi.stVFrame.enImgFormat=AX_FORMAT_YUV422_INTERLEAVED_YUYV;
    fi.stVFrame.u32PicStride[0]=W; fi.stVFrame.u64PhyAddr[0]=phys; fi.stVFrame.u64VirAddr[0]=(AX_U64)(uintptr_t)virt;
    fi.stVFrame.u32BlkId[0]=blk; fi.stVFrame.u32FrameSize=(AX_U32)size; fi.enModId=(AX_MOD_ID_E)MODID;
    if(STRIDE>0) fi.stVFrame.u32PicStride[0]=STRIDE; if(FMT>=0) fi.stVFrame.enImgFormat=(AX_IMG_FORMAT_E)FMT;
    P("frame: modid=0x%x stride=%u fmt=0x%x", MODID, fi.stVFrame.u32PicStride[0], (unsigned)fi.stVFrame.enImgFormat);

    snprintf(fn,sizeof fn,"%s/%s.%s",OUT,TAG,H265?"h265":"h264"); FILE *bs=fopen(fn,"wb");
    snapshot("pre");
    int nidr=0, np=0;
    for(int i=0;i<NFRAMES;i++){
        if(i==0 || MOVE){ fill(card,i); for(size_t k=0;k<size;k+=8) *(uint64_t*)(virt+k)=*(uint64_t*)(card+k); }
        fi.stVFrame.u64PTS=(AX_U64)i*1000000ULL/FPS; fi.stVFrame.u64SeqNum=i+1;
        AX_S32 sr=AX_VENC_SendFrame(CHN,&fi,2000);
        AX_VENC_STREAM_T st; memset(&st,0,sizeof st);
        AX_S32 gr=AX_VENC_GetStream(CHN,&st,3000);
        if(gr==0){
            AX_VENC_PACK_T *pk=&st.stPack;
            char nal[256]=""; for(unsigned k=0;k<pk->u32NaluNum && k<AX_MAX_VENC_NALU_NUM;k++){ char t[32];
                int nt = H265 ? (int)pk->stNaluInfo[k].unNaluType.enH265EType : (int)pk->stNaluInfo[k].unNaluType.enH264EType;
                snprintf(t,sizeof t," n%d:%u",nt,pk->stNaluInfo[k].u32NaluLength); strncat(nal,t,sizeof nal-strlen(nal)-1);}
            unsigned sq = H265 ? st.stH265Info.u32StartQp : st.stH264Info.u32StartQp;
            unsigned mq = H265 ? st.stH265Info.u32MeanQp  : st.stH264Info.u32MeanQp;
            unsigned pb = H265 ? st.stH265Info.u32PicBytesNum : st.stH264Info.u32PicBytesNum;
            int ps = H265 ? st.stH265Info.bPSkip : st.stH264Info.bPSkip;
            P("frame %d: send=0x%x get=0x%x len=%u coding=%d startqp=%u meanqp=%u picbytes=%u pskip=%d nalus=%u%s", i,sr,gr,pk->u32Len,pk->enCodingType,sq,mq,pb,ps,pk->u32NaluNum,nal);
            if(H265) P("  cu: inter64=%u inter32=%u inter16=%u inter8=%u intra32=%u intra16=%u intra8=%u intra4=%u reftype=%d",
                st.stH265Info.u32Inter64x64CuNum,st.stH265Info.u32Inter32x32CuNum,st.stH265Info.u32Inter16x16CuNum,st.stH265Info.u32Inter8x8CuNum,
                st.stH265Info.u32Intra32x32CuNum,st.stH265Info.u32Intra16x16CuNum,st.stH265Info.u32Intra8x8CuNum,st.stH265Info.u32Intra4x4CuNum,(int)st.stH265Info.enRefType);
            if(bs && pk->pu8Addr && pk->u32Len) fwrite(pk->pu8Addr,1,pk->u32Len,bs);
            int isI = (pk->enCodingType==AX_VENC_INTRA_FRAME);
            if(SNAPALL) { char ph[32]; snprintf(ph,sizeof ph,"f%03d",i); snapshot(ph); }
            else if(isI && nidr==0){ snapshot("IDR"); nidr++; }
            else if(!isI && np==0){ snapshot("P"); np++; }
            AX_VENC_ReleaseStream(CHN,&st);
        } else P("frame %d: send=0x%x get=0x%x (no stream)", i,sr,gr);
    }
    if(bs) fclose(bs);
    { FILE *pf=fopen("/proc/ax_proc/venc","r"); if(pf){ char l[512]; P("---- /proc/ax_proc/venc ----"); while(fgets(l,sizeof l,pf)){ l[strcspn(l,"\n")]=0; P("%s",l);} fclose(pf);} }
    AX_VENC_StopRecvFrame(CHN); AX_VENC_DestroyChn(CHN);
    AX_SYS_Munmap(virt,(AX_U32)size); AX_POOL_ReleaseBlock(blk); AX_POOL_DestroyPool(pool);
    AX_VENC_Deinit(); AX_SYS_Deinit();
    P("done %s", TAG); fclose(LOG); return 0;
}
