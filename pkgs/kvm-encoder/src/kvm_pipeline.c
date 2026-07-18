/* kvm_pipeline.c -- see kvm_pipeline.h. Documented Axera MPI only. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>

#include "ax_base_type.h"
#include "ax_global_type.h"
#include "ax_pool_type.h"
#include "ax_sys_api.h"
#include "ax_buffer_tool.h"
#include "ax_mipi_rx_api.h"
#include "ax_vin_api.h"
#include "ax_isp_api.h"
#include "ax_sensor_struct.h"
#include "ax_venc_api.h"
#include "ax_venc_comm.h"
#include "ax_venc_rc.h"
#include "kvm_pipeline.h"

#define KLOG(expr, msg)                                                      \
    do {                                                                     \
        AX_S32 __r = (expr);                                                 \
        if (__r != 0) {                                                      \
            fprintf(stderr, "[kvm][FAIL] %-28s ret=0x%X\n", msg, __r);       \
            return __r;                                                      \
        }                                                                    \
    } while (0)

/* ---------------- SYS + VB pool ----------------
 *
 * RIGHT-SIZED POOL (Phase 1 fix). The old config allocated TWO common pools of
 * 12 blocks each (NV12 + RAW16 == ~87 MB), of which the RAW16 pool was never
 * consumed: the VIN dev runs ONLINE (AX_VIN_DEV_ONLINE) into an ISP-bypass pipe,
 * so raw frames stream on-chip and are never buffered in DRAM. Only the VIN
 * output channel draws from the common pool, and it emits YUYV422 (fmt 0xD,
 * 2 bytes/pixel == rawSz). We therefore keep exactly ONE common pool sized for
 * the YUYV frame and cut BlkCnt to (chn depth + 1). This matches Sipeed's own
 * kvm_vin, which runs a single 6-block common pool with ~3 blocks in flight.
 *
 * KVM_POOL_BLKCNT must be >= the VIN channel nDepth (KVM_CHN_DEPTH) or
 * AX_VIN_GetYuvFrame starves. +1 gives one spare for the in-flight frame the
 * caller is currently encoding.
 */
#define KVM_CHN_DEPTH   3
#define KVM_POOL_BLKCNT (KVM_CHN_DEPTH + 1)   /* 4 blocks ~= 16.6 MB at 1080p */

int kvm_sys_init(kvm_cap_ctx *c, int w, int h)
{
    memset(c, 0, sizeof(*c));
    c->w = w; c->h = h;
    KLOG(AX_SYS_Init(), "AX_SYS_Init");
    c->sysInit = AX_TRUE;

    AX_FRAME_COMPRESS_INFO_T noComp = { AX_COMPRESS_MODE_NONE, 0 };
    AX_U32 nv12Sz = AX_VIN_GetImgBufferSize(h, w, AX_FORMAT_YUV420_SEMIPLANAR, &noComp, 0);
    AX_U32 rawSz  = AX_VIN_GetImgBufferSize(h, w, AX_FORMAT_BAYER_RAW_16BPP, &noComp, 0);
    /* VIN bypass delivers 2-bytes/pixel YUYV; size the block for the larger of
     * the NV12 request and the RAW16/YUYV footprint so the frame always fits. */
    AX_U32 blkSz  = (rawSz > nv12Sz) ? rawSz : nv12Sz;
    c->nv12Sz = blkSz;

    AX_POOL_FLOORPLAN_T floor;
    memset(&floor, 0, sizeof(floor));
    floor.CommPool[0].MetaSize  = 4096;
    floor.CommPool[0].BlkSize   = blkSz;
    floor.CommPool[0].BlkCnt    = KVM_POOL_BLKCNT;
    floor.CommPool[0].CacheMode = AX_POOL_CACHE_MODE_NONCACHE;
    strcpy((char *)floor.CommPool[0].PartitionName, "anonymous");

    KLOG(AX_POOL_SetConfig(&floor), "AX_POOL_SetConfig");
    KLOG(AX_POOL_Init(), "AX_POOL_Init");
    c->poolInit = AX_TRUE;
    fprintf(stderr, "[kvm] pool: 1 comm pool, blk=%u B x %d (%.1f MB), nv12=%u raw=%u\n",
            blkSz, KVM_POOL_BLKCNT, (blkSz * (double)KVM_POOL_BLKCNT) / (1024*1024),
            nv12Sz, rawSz);
    return 0;
}

void kvm_sys_deinit(kvm_cap_ctx *c)
{
    if (c->poolInit) {
        /* AX_POOL_Exit frees the common pool CMM. It FAILS (leaving CMM pinned,
         * which then wedges the next AX_POOL_Init with 0x800B0118) if any block
         * is still checked out -- so callers must destroy VENC and stop VIN,
         * returning every block, BEFORE we get here. Log the result so a leak is
         * visible instead of silent. */
        AX_S32 r = AX_POOL_Exit();
        if (r != 0)
            fprintf(stderr, "[kvm][WARN] AX_POOL_Exit ret=0x%X -- CMM may be pinned; "
                            "blocks still checked out?\n", r);
        else
            fprintf(stderr, "[kvm] AX_POOL_Exit OK (common pool CMM released)\n");
        c->poolInit = AX_FALSE;
    }
    if (c->sysInit)  { AX_SYS_Deinit(); c->sysInit = AX_FALSE; }
}

/* ---------------- capture bring-up ---------------- */
int kvm_cap_start(kvm_cap_ctx *c, int w, int h, int fps)
{
    c->w = w; c->h = h; c->fps = fps;
    AX_FRAME_COMPRESS_INFO_T noComp = { AX_COMPRESS_MODE_NONE, 0 };

    KLOG(AX_MIPI_RX_Init(), "AX_MIPI_RX_Init");
    c->mipiInit = AX_TRUE;
    KLOG(AX_VIN_Init(), "AX_VIN_Init");
    c->vinInit = AX_TRUE;

    AX_MIPI_RX_DEV_T mipi;
    memset(&mipi, 0, sizeof(mipi));
    mipi.eInputMode           = AX_INPUT_MODE_MIPI;
    mipi.tMipiAttr.ePhyMode   = AX_MIPI_PHY_TYPE_DPHY;
    mipi.tMipiAttr.eLaneNum   = AX_MIPI_DATA_LANE_4;
    mipi.tMipiAttr.nDataRate  = KVM_MIPI_RATE;
    mipi.tMipiAttr.nDataLaneMap[0] = 0;
    mipi.tMipiAttr.nDataLaneMap[1] = 1;
    mipi.tMipiAttr.nDataLaneMap[2] = 3;
    mipi.tMipiAttr.nDataLaneMap[3] = 4;
    mipi.tMipiAttr.nClkLane[0] = 2;
    mipi.tMipiAttr.nClkLane[1] = 5;
    AX_MIPI_RX_SetLaneCombo(AX_LANE_COMBO_MODE_0);
    KLOG(AX_MIPI_RX_SetAttr(KVM_RX_DEV, &mipi), "AX_MIPI_RX_SetAttr");
    KLOG(AX_MIPI_RX_Reset(KVM_RX_DEV), "AX_MIPI_RX_Reset");
    KLOG(AX_MIPI_RX_Start(KVM_RX_DEV), "AX_MIPI_RX_Start");
    c->mipiStarted = AX_TRUE;

    AX_VIN_DEV_ATTR_T dev;
    memset(&dev, 0, sizeof(dev));
    dev.bImgDataEnable    = AX_TRUE;
    dev.bNonImgDataEnable = AX_FALSE;
    dev.eDevMode          = AX_VIN_DEV_ONLINE;
    dev.eSnsIntfType      = AX_SNS_INTF_TYPE_MIPI_RAW;
    dev.eSnsMode          = AX_SNS_LINEAR_MODE;
    dev.eBayerPattern     = AX_BP_BGGR;
    dev.ePixelFmt         = AX_FORMAT_BAYER_RAW_16BPP;
    dev.tDevImgRgn[0].nStartX = 0; dev.tDevImgRgn[0].nStartY = 0;
    dev.tDevImgRgn[0].nWidth  = w; dev.tDevImgRgn[0].nHeight = h;
    dev.eSnsOutputMode    = AX_SNS_NORMAL;
    dev.tCompressInfo     = noComp;
    dev.tMipiIntfAttr.szImgVc[0] = 0;
    dev.tMipiIntfAttr.szImgDt[0] = AX_MIPI_CSI_DT_YUV422_8BIT;
    KLOG(AX_VIN_CreateDev(KVM_VIN_DEV, &dev), "AX_VIN_CreateDev");
    c->devCreated = AX_TRUE;
    KLOG(AX_VIN_SetDevAttr(KVM_VIN_DEV, &dev), "AX_VIN_SetDevAttr");

    AX_VIN_DEV_BIND_PIPE_T bind;
    memset(&bind, 0, sizeof(bind));
    bind.nNum = 1; bind.nPipeId[0] = KVM_VIN_PIPE;
    KLOG(AX_VIN_SetDevBindPipe(KVM_VIN_DEV, &bind), "AX_VIN_SetDevBindPipe");
    KLOG(AX_VIN_SetDevBindMipi(KVM_VIN_DEV, KVM_RX_DEV), "AX_VIN_SetDevBindMipi");

    AX_VIN_PIPE_ATTR_T pipe;
    memset(&pipe, 0, sizeof(pipe));
    pipe.ePipeWorkMode = (AX_VIN_PIPE_WORK_MODE_E)KVM_PIPE_MODE;
    pipe.tPipeImgRgn.nStartX = 0; pipe.tPipeImgRgn.nStartY = 0;
    pipe.tPipeImgRgn.nWidth  = w; pipe.tPipeImgRgn.nHeight = h;
    pipe.nWidthStride  = w;
    pipe.eBayerPattern = AX_BP_BGGR;
    pipe.ePixelFmt     = AX_FORMAT_BAYER_RAW_16BPP;
    pipe.eSnsMode      = AX_SNS_LINEAR_MODE;
    pipe.tCompressInfo = noComp;
    KLOG(AX_VIN_CreatePipe(KVM_VIN_PIPE, &pipe), "AX_VIN_CreatePipe");
    c->pipeCreated = AX_TRUE;
    KLOG(AX_VIN_SetPipeAttr(KVM_VIN_PIPE, &pipe), "AX_VIN_SetPipeAttr");

    c->snsLib = dlopen("libsns_dummy.so", RTLD_LAZY | RTLD_GLOBAL);
    if (!c->snsLib) { fprintf(stderr, "[kvm][FAIL] dlopen libsns_dummy.so: %s\n", dlerror()); return -1; }
    AX_SENSOR_REGISTER_FUNC_T *snsObj = (AX_SENSOR_REGISTER_FUNC_T *)dlsym(c->snsLib, "gSnsdummyObj");
    if (!snsObj) { fprintf(stderr, "[kvm][FAIL] dlsym gSnsdummyObj\n"); return -1; }

    KLOG(AX_ISP_RegisterSensor(KVM_VIN_PIPE, snsObj), "AX_ISP_RegisterSensor");
    c->snsReg = AX_TRUE;

    AX_SNS_ATTR_T sns;
    memset(&sns, 0, sizeof(sns));
    sns.nWidth = w; sns.nHeight = h;
    sns.fFrameRate = (AX_F32)fps;
    sns.eSnsMode = AX_SNS_LINEAR_MODE;
    sns.eRawType = AX_RT_RAW16;
    sns.eBayerPattern = AX_BP_BGGR;
    sns.bTestPatternEnable = AX_FALSE;
    KLOG(AX_ISP_SetSnsAttr(KVM_VIN_PIPE, &sns), "AX_ISP_SetSnsAttr");

    KLOG(AX_ISP_Create(KVM_VIN_PIPE), "AX_ISP_Create");
    c->ispCreated = AX_TRUE;
    KLOG(AX_ISP_Open(KVM_VIN_PIPE), "AX_ISP_Open");
    c->ispOpened = AX_TRUE;

    AX_VIN_CHN_ATTR_T chn;
    memset(&chn, 0, sizeof(chn));
    chn.nWidth = w; chn.nHeight = h; chn.nWidthStride = w;
    chn.eImgFormat = AX_FORMAT_YUV420_SEMIPLANAR;
    chn.nDepth = KVM_CHN_DEPTH;   /* keep in lock-step with the common pool BlkCnt */
    chn.tCompressInfo = noComp;
    KLOG(AX_VIN_SetChnAttr(KVM_VIN_PIPE, AX_VIN_CHN_ID_MAIN, &chn), "AX_VIN_SetChnAttr");
    KLOG(AX_VIN_EnableChn(KVM_VIN_PIPE, AX_VIN_CHN_ID_MAIN), "AX_VIN_EnableChn");
    c->chnEnabled = AX_TRUE;

    KLOG(AX_VIN_StartPipe(KVM_VIN_PIPE), "AX_VIN_StartPipe");
    c->pipeStarted = AX_TRUE;
    KLOG(AX_ISP_Start(KVM_VIN_PIPE), "AX_ISP_Start");
    c->ispStarted = AX_TRUE;
    KLOG(AX_VIN_EnableDev(KVM_VIN_DEV), "AX_VIN_EnableDev");
    c->devEnabled = AX_TRUE;
    KLOG(AX_ISP_StreamOn(KVM_VIN_PIPE), "AX_ISP_StreamOn");
    c->streamOn = AX_TRUE;
    return 0;
}

void kvm_cap_stop(kvm_cap_ctx *c)
{
    if (c->streamOn)    { AX_ISP_StreamOff(KVM_VIN_PIPE); c->streamOn = AX_FALSE; }
    if (c->devEnabled)  { AX_VIN_DisableDev(KVM_VIN_DEV); c->devEnabled = AX_FALSE; }
    if (c->ispStarted)  { AX_ISP_Stop(KVM_VIN_PIPE); c->ispStarted = AX_FALSE; }
    if (c->pipeStarted) { AX_VIN_StopPipe(KVM_VIN_PIPE); c->pipeStarted = AX_FALSE; }
    if (c->chnEnabled)  { AX_VIN_DisableChn(KVM_VIN_PIPE, AX_VIN_CHN_ID_MAIN); c->chnEnabled = AX_FALSE; }
    if (c->ispOpened)   { AX_ISP_Close(KVM_VIN_PIPE); c->ispOpened = AX_FALSE; }
    if (c->ispCreated)  { AX_ISP_Destroy(KVM_VIN_PIPE); c->ispCreated = AX_FALSE; }
    if (c->snsReg)      { AX_ISP_UnRegisterSensor(KVM_VIN_PIPE); c->snsReg = AX_FALSE; }
    if (c->pipeCreated) { AX_VIN_DestroyPipe(KVM_VIN_PIPE); c->pipeCreated = AX_FALSE; }
    if (c->devCreated)  { AX_VIN_DestroyDev(KVM_VIN_DEV); c->devCreated = AX_FALSE; }
    if (c->mipiStarted) { AX_MIPI_RX_Stop(KVM_RX_DEV); c->mipiStarted = AX_FALSE; }
    if (c->snsLib)      { dlclose(c->snsLib); c->snsLib = NULL; }
    if (c->mipiInit)    { AX_MIPI_RX_DeInit(); c->mipiInit = AX_FALSE; }
    if (c->vinInit)     { AX_VIN_Deinit(); c->vinInit = AX_FALSE; }
}

int  kvm_cap_get(AX_IMG_INFO_T *img, int timeout_ms)
{
    memset(img, 0, sizeof(*img));
    return AX_VIN_GetYuvFrame(KVM_VIN_PIPE, AX_VIN_CHN_ID_MAIN, img, timeout_ms);
}
void kvm_cap_release(AX_IMG_INFO_T *img)
{
    AX_VIN_ReleaseYuvFrame(KVM_VIN_PIPE, AX_VIN_CHN_ID_MAIN, img);
}

/* ---------------- VENC ---------------- */
static AX_BOOL g_vencInit = AX_FALSE;

int kvm_venc_create(int chn, AX_PAYLOAD_TYPE_E type, int w, int h,
                    int fps, int gop, int qlty, int rc_mode)
{
    if (!g_vencInit) {
        AX_VENC_MOD_ATTR_T modAttr;
        memset(&modAttr, 0, sizeof(modAttr));
        modAttr.enVencType = AX_VENC_MULTI_ENCODER;
        modAttr.stModThdAttr.u32TotalThreadNum = 1;
        modAttr.stModThdAttr.bExplicitSched    = AX_FALSE;
        KLOG(AX_VENC_Init(&modAttr), "AX_VENC_Init");
        g_vencInit = AX_TRUE;
    }

    AX_FRAME_COMPRESS_INFO_T noComp = { AX_COMPRESS_MODE_NONE, 0 };
    AX_U32 bufSz = AX_VIN_GetImgBufferSize(h, w, AX_FORMAT_YUV420_SEMIPLANAR, &noComp, 0);

    AX_VENC_CHN_ATTR_T va;
    memset(&va, 0, sizeof(va));
    va.stVencAttr.enType          = type;
    va.stVencAttr.u32MaxPicWidth  = w;
    va.stVencAttr.u32MaxPicHeight = h;
    va.stVencAttr.u32PicWidthSrc  = w;
    va.stVencAttr.u32PicHeightSrc = h;
    va.stVencAttr.enMemSource     = AX_MEMORY_SOURCE_CMM;
    va.stVencAttr.enLinkMode      = AX_UNLINK_MODE;
    /* VENC draws its own CMM (enMemSource CMM, u32BufSize each) for the in/out
     * FIFOs -- depth 4 pinned up to 8*bufSize (~32 MB) of CMM. Depth 2 is ample
     * for our synchronous send->get loop and halves the encoder's CMM peak. */
    va.stVencAttr.u8InFifoDepth   = 2;
    va.stVencAttr.u8OutFifoDepth  = 2;
    va.stVencAttr.u32BufSize      = bufSz;

    if (type == PT_H264) {
        va.stVencAttr.enProfile = AX_VENC_H264_MAIN_PROFILE;
        va.stVencAttr.enLevel   = AX_VENC_H264_LEVEL_5_1;
        va.stRcAttr.stFrameRate.fSrcFrameRate = fps;
        va.stRcAttr.stFrameRate.fDstFrameRate = fps;
        if (rc_mode == 1) { /* VBR */
            va.stRcAttr.enRcMode = AX_VENC_RC_MODE_H264VBR;
            va.stRcAttr.stH264Vbr.u32Gop        = gop;
            va.stRcAttr.stH264Vbr.u32StatTime   = 1;
            va.stRcAttr.stH264Vbr.u32MaxBitRate = qlty ? qlty : 8000;
            va.stRcAttr.stH264Vbr.u32MinQp      = 10;
            va.stRcAttr.stH264Vbr.u32MaxQp      = 51;
            va.stRcAttr.stH264Vbr.u32MinIQp     = 10;
            va.stRcAttr.stH264Vbr.u32MaxIQp     = 51;
        } else { /* CBR */
            va.stRcAttr.enRcMode = AX_VENC_RC_MODE_H264CBR;
            va.stRcAttr.stH264Cbr.u32Gop        = gop;
            va.stRcAttr.stH264Cbr.u32StatTime   = 1;
            va.stRcAttr.stH264Cbr.u32BitRate    = qlty ? qlty : 8000;
            va.stRcAttr.stH264Cbr.u32MinQp      = 10;
            va.stRcAttr.stH264Cbr.u32MaxQp      = 51;
            va.stRcAttr.stH264Cbr.u32MinIQp     = 10;
            va.stRcAttr.stH264Cbr.u32MaxIQp     = 51;
            va.stRcAttr.stH264Cbr.u32MaxIprop   = 40;
            va.stRcAttr.stH264Cbr.u32MinIprop   = 10;
            va.stRcAttr.stH264Cbr.u32IdrQpDeltaRange = 2;
        }
        va.stRcAttr.s32FirstFrameStartQp = -1;
        va.stGopAttr.enGopMode = AX_VENC_GOPMODE_NORMALP;
    } else { /* PT_MJPEG */
        /* Map quality [50,100] -> fixed QP [51..0] (lower QP = better). */
        int q = qlty; if (q < 50) q = 50; if (q > 100) q = 100;
        int fixedQp = (100 - q) * 51 / 50;      /* q=100->0, q=50->51 */
        if (fixedQp < 1) fixedQp = 1;
        va.stRcAttr.enRcMode = AX_VENC_RC_MODE_MJPEGFIXQP;
        va.stRcAttr.stFrameRate.fSrcFrameRate = fps;
        va.stRcAttr.stFrameRate.fDstFrameRate = fps;
        va.stRcAttr.stMjpegFixQp.s32FixedQp   = fixedQp;
    }

    KLOG(AX_VENC_CreateChn(chn, &va), "AX_VENC_CreateChn");
    AX_VENC_RECV_PIC_PARAM_T recv;
    recv.s32RecvPicNum = -1;
    KLOG(AX_VENC_StartRecvFrame(chn, &recv), "AX_VENC_StartRecvFrame");
    return 0;
}

void kvm_venc_destroy(int chn)
{
    AX_VENC_StopRecvFrame(chn);
    AX_VENC_DestroyChn(chn);
}

/* Called once at final teardown to release the VENC module. */
void kvm_venc_module_deinit(void)
{
    if (g_vencInit) { AX_VENC_Deinit(); g_vencInit = AX_FALSE; }
}

int  kvm_venc_send(int chn, AX_VIDEO_FRAME_INFO_T *frame)
{ return AX_VENC_SendFrame(chn, frame, -1); }

int  kvm_venc_get(int chn, AX_VENC_STREAM_T *st, int timeout_ms)
{ memset(st, 0, sizeof(*st)); return AX_VENC_GetStream(chn, st, timeout_ms); }

void kvm_venc_release(int chn, AX_VENC_STREAM_T *st)
{ AX_VENC_ReleaseStream(chn, st); }

int kvm_venc_set_fps(int chn, AX_PAYLOAD_TYPE_E type, int fps)
{
    AX_VENC_RC_PARAM_T rc;
    if (AX_VENC_GetRcParam(chn, &rc) != 0) return -1;
    rc.stFrameRate.fSrcFrameRate = fps;
    rc.stFrameRate.fDstFrameRate = fps;
    (void)type;
    return AX_VENC_SetRcParam(chn, &rc);
}

int kvm_venc_set_gop(int chn, int gop)
{
    AX_VENC_RC_PARAM_T rc;
    if (AX_VENC_GetRcParam(chn, &rc) != 0) return -1;
    /* gop lives in the per-codec union; H264 CBR/VBR share u32Gop as first field */
    rc.stH264Cbr.u32Gop = gop;
    return AX_VENC_SetRcParam(chn, &rc);
}

/* ---------------- lt6911 source poll ---------------- */
static int read_int_file(const char *path, int *out)
{
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int v = -1, n = fscanf(f, "%d", &v);
    fclose(f);
    if (n != 1) return -1;
    *out = v;
    return 0;
}

int kvm_read_source(int *w, int *h, int *fps, int *locked)
{
    int ww=0, hh=0, ff=0;
    if (read_int_file("/proc/lt6911_info/width", &ww)) return -1;
    if (read_int_file("/proc/lt6911_info/height", &hh)) return -1;
    read_int_file("/proc/lt6911_info/fps", &ff);
    if (w) *w = ww;
    if (h) *h = hh;
    if (fps) *fps = ff;
    if (locked) {
        char buf[64] = {0};
        FILE *f = fopen("/proc/lt6911_info/hdmi_rx_status", "r");
        *locked = 0;
        if (f) { if (fgets(buf, sizeof(buf), f)) *locked = (strncmp(buf, "access", 6) == 0); fclose(f); }
    }
    return 0;
}
