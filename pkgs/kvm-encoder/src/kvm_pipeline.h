/*
 * kvm_pipeline.h -- reusable NanoKVM-Pro (AX630C) capture+encode pipeline.
 *
 * Extracted from the proven capture_venc.c PoC so it can back BOTH:
 *   - the standalone streaming daemon (stream_daemon.c), and
 *   - the drop-in libkvm.so (libkvm.c, kvm_vision.h ABI).
 *
 * Capture path (documented Axera MPI only, zero Sipeed code):
 *   LT6911UXC HDMI->CSI-2  =>  MIPI_RX(DPHY 4-lane MODE_0 600Mbps map[0,1,3,4]/clk[2,5])
 *      =>  VIN dev (MIPI_RAW/RAW16/BGGR, CSI DT 0x1E)
 *      =>  VIN pipe (ISP_BYPASS_MODE, dummy sensor)
 *      =>  VIN chn (frames emerge as YUV422 interleaved YUYV, fmt 0xD)
 *      =>  AX_VENC (H.264 chn7 / MJPEG chn6)
 */
#ifndef KVM_PIPELINE_H_
#define KVM_PIPELINE_H_

#include "ax_base_type.h"
#include "ax_global_type.h"
#include "ax_venc_comm.h"
#include "ax_vin_api.h"   /* AX_IMG_INFO_T */

/* ---- capture config (resolved on live hardware, authoritative) ---- */
#define KVM_VIN_DEV   0
#define KVM_VIN_PIPE  0
#define KVM_RX_DEV    0
#define KVM_MIPI_RATE 600   /* Mbps/lane */
#define KVM_MIPI_LANES 4
#define KVM_PIPE_MODE 12    /* AX_VIN_PIPE_ISP_BYPASS_MODE */

/* Spare VENC channels (Sipeed uses others on-demand). */
#define KVM_VENC_H264_CHN 7
#define KVM_VENC_MJPEG_CHN 6

/* Opaque-ish capture context; all teardown flags live here for safe cleanup. */
typedef struct {
    int w, h, fps;
    void *snsLib;
    AX_BOOL sysInit, poolInit;
    AX_BOOL mipiInit, vinInit, mipiStarted;
    AX_BOOL devCreated, pipeCreated, snsReg, ispCreated, ispOpened;
    AX_BOOL chnEnabled, pipeStarted, ispStarted, devEnabled, streamOn;
    AX_U32  nv12Sz;
} kvm_cap_ctx;

/* SYS + common VB pool. Call once. */
int  kvm_sys_init(kvm_cap_ctx *c, int w, int h);
void kvm_sys_deinit(kvm_cap_ctx *c);

/* Bring up MIPI->VIN->ISP-bypass so VIN chn delivers YUYV frames. */
int  kvm_cap_start(kvm_cap_ctx *c, int w, int h, int fps);
void kvm_cap_stop(kvm_cap_ctx *c);

/* Grab / release one captured YUYV frame. */
int  kvm_cap_get(AX_IMG_INFO_T *img, int timeout_ms);
void kvm_cap_release(AX_IMG_INFO_T *img);

/* VENC channel helpers. type = PT_H264 or PT_MJPEG.
 * qlty: H264 -> bitrate kbps; MJPEG -> ~[50,100] quality (mapped to QP). */
int  kvm_venc_create(int chn, AX_PAYLOAD_TYPE_E type, int w, int h,
                     int fps, int gop, int qlty, int rc_mode /*0=CBR,1=VBR*/);
void kvm_venc_destroy(int chn);
void kvm_venc_module_deinit(void);
int  kvm_venc_send(int chn, AX_VIDEO_FRAME_INFO_T *frame);
int  kvm_venc_get(int chn, AX_VENC_STREAM_T *st, int timeout_ms);
void kvm_venc_release(int chn, AX_VENC_STREAM_T *st);
int  kvm_venc_set_fps(int chn, AX_PAYLOAD_TYPE_E type, int fps);
int  kvm_venc_set_gop(int chn, int gop);

/* Poll /proc/lt6911_info. Returns 0 on success, fills w/h/fps and
 * whether the HDMI RX is locked ("access"). status buf optional. */
int  kvm_read_source(int *w, int *h, int *fps, int *locked);

#endif /* KVM_PIPELINE_H_ */
