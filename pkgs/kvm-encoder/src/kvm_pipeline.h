/*
 * kvm_pipeline.h -- the NanoKVM-Pro (AX630C) capture+encode pipeline, as
 * libkvm.c drives it.
 *
 * Capture path, all open (#60/#83):
 *   LT6911UXC HDMI->CSI-2  =>  open_vin_csi2 (D-PHY receiver)
 *      =>  open_vin_capture => /dev/videoN, YUYV 4:2:2 frames over V4L2
 *      =>  the open VC8000E encoder (kvm_venc_open.c) over /dev/es_venc
 * Two implementations sit behind it: kvm_capture_v4l2.c (capture) and
 * kvm_venc_open.c (encode); this header is the only thing between them and
 * libkvm.c. The source-geometry poll lives in kvm_pipeline.c.
 */
#ifndef KVM_PIPELINE_H_
#define KVM_PIPELINE_H_

#include "kvm_types.h"

/* Channel ids. These are libkvm's own handles -- one codec at a time is
 * live, and the number only distinguishes which. */
#define KVM_VENC_H264_CHN 7
#define KVM_VENC_H265_CHN 8   /* H.265/HEVC (#64) */
#define KVM_VENC_MJPEG_CHN 6

/* Capture context. Owned by libkvm.c, filled by the capture backend; the
 * flags exist so a failed bring-up tears down exactly what came up. */
typedef struct {
    int w, h, fps;      /* negotiated geometry and the source's frame rate */
    int sysInit;        /* the capture device is open and the format set */
    int streamOn;       /* VIDIOC_STREAMON succeeded; buffers are queued */
} kvm_cap_ctx;

/* The capture envelope (#98). The backend owns it -- it has to match the
 * kernel driver's OVC_MAX_* -- and kvm_sys_init enforces it, but libkvm.c
 * asks FIRST so that a source outside the range is reported as its own thing
 * ("this mode is not supported") rather than as a generic bring-up failure.
 * kvm_cap_envelope fills the maximum; kvm_cap_geom_ok is 1 when (w,h) is
 * inside it. */
void kvm_cap_envelope(int *max_w, int *max_h);
int  kvm_cap_geom_ok(int w, int h);

/* Open the capture node and negotiate WxH. Call once per pipeline. */
int  kvm_sys_init(kvm_cap_ctx *c, int w, int h);
void kvm_sys_deinit(kvm_cap_ctx *c);

/* Allocate/map/export the buffers and start streaming. */
int  kvm_cap_start(kvm_cap_ctx *c, int w, int h, int fps);
void kvm_cap_stop(kvm_cap_ctx *c);

/* Grab / release one captured YUYV frame. A frame is valid until released. */
int  kvm_cap_get(kvm_frame *f, int timeout_ms);
void kvm_cap_release(kvm_frame *f);

/* VENC channel helpers.
 * qlty: H.264/H.265 -> bitrate kbps; MJPEG -> ~[50,100] quality. */
int  kvm_venc_create(int chn, kvm_codec codec, int w, int h,
                     int fps, int gop, int qlty, int rc_mode /*0=CBR,1=VBR*/);
void kvm_venc_destroy(int chn);
void kvm_venc_module_deinit(void);
int  kvm_venc_send(int chn, const kvm_frame *f);
int  kvm_venc_get(int chn, kvm_pack *pk, int timeout_ms);
void kvm_venc_release(int chn, kvm_pack *pk);
int  kvm_venc_set_fps(int chn, kvm_codec codec, int fps);
int  kvm_venc_set_gop(int chn, int gop);
/* Retarget a running H.264/H.265 channel to a new bitrate (kbps) without
 * rebuilding it. Returns 0 when the backend applied it (the open encoder's
 * controller picks it up at the next frame, #46), -1 when the caller must
 * fall back to destroy + create. */
int  kvm_venc_set_bitrate(int chn, int kbps);

/* Poll /proc/lt6911_info (drivers/misc/lt6911-manage.c). Returns 0 on
 * success, fills w/h/fps and whether the HDMI RX is locked ("access"). */
int  kvm_read_source(int *w, int *h, int *fps, int *locked);

#endif /* KVM_PIPELINE_H_ */
