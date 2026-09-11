/*
 * kvm_types.h -- the seam types libkvm's own modules exchange (#102).
 *
 * libkvm used to borrow the vendor SDK's frame and stream structs
 * (`ax_*.h`, supplied by the retired `axera-libs`) as its internal
 * vocabulary. Nothing outside this process ever saw them: the capture side
 * talks plain V4L2 to our open driver, the encoder talks the VCMD ioctl ABI
 * to our open VC8000E driver, and the Go server sees only kvm_vision.h. So
 * these are OUR types, written from what the open drivers deliver.
 *
 * LAYOUT IS NOT AN ABI HERE. Every struct below is passed by pointer between
 * translation units of one shared object; no kernel, library or ABI boundary
 * reads them. The real ABIs libkvm speaks are:
 *   - <linux/videodev2.h>          (drivers/media/platform/axera/open_vin_capture.c)
 *   - vcmd_abi.h                   (drivers/media/platform/axera/vc8000e/,
 *                                   the VCMD ioctls + dma-buf import)
 * and each field below that carries a value across one of those is annotated
 * with where it comes from. kvm_capture_v4l2.c -- which is where those two
 * UAPIs actually meet these structs -- holds the _Static_asserts that our
 * fields cannot truncate theirs.
 */
#ifndef KVM_TYPES_H_
#define KVM_TYPES_H_

#include <stdint.h>

/* ------------------------------------------------------------------ codec */
/* What the encoder backend was asked to produce. MJPEG is the from-source
 * software path (#51); H.264/H.265 are the open VC8000E programs (#25/#64). */
typedef enum {
    KVM_CODEC_MJPEG = 0,
    KVM_CODEC_H264  = 1,
    KVM_CODEC_H265  = 2,
} kvm_codec;

/* ------------------------------------------------------------------ frame */
/* The only pixel format in the pipeline: packed 4:2:2, the open capture
 * driver's single output format (V4L2_PIX_FMT_YUYV) and the VC8000E's native
 * input format, so nothing converts anywhere. Kept as an enum because the
 * preview scaler and the soft-JPEG encoder both assert on it. */
typedef enum {
    KVM_PIX_YUYV = 0,
} kvm_pixfmt;

/* One captured frame, dequeued and owned by the capture backend until it is
 * released. The encoder reads `bus`, the soft-JPEG and mini-display paths
 * read `cpu`. */
typedef struct {
    uint32_t   width;      /* v4l2_pix_format.width  (negotiated by S_FMT) */
    uint32_t   height;     /* v4l2_pix_format.height */
    kvm_pixfmt fmt;        /* always KVM_PIX_YUYV; see above */
    uint32_t   stride_px;  /* luma stride in PIXELS: v4l2_pix_format.bytesperline / 2.
                            * Pixels, not bytes, because that is what the VC8000E
                            * register program (vcenc_geom.stride) compares against. */
    uint32_t   size;       /* v4l2_pix_format.sizeimage: bytes in the buffer */
    uint64_t   bus;        /* dmabuf_import_parameter.bus_addr -- the encoder's
                            * swreg12 input address. 0 = no import (unusable). */
    void      *cpu;        /* the V4L2 MMAP view of the same buffer, or NULL */
    uint32_t   index;      /* v4l2_buffer.index of the buffer handed out */
    uint64_t   seq;        /* v4l2_buffer.sequence: the driver's frame counter */
} kvm_frame;

/* ----------------------------------------------------------------- stream */
/* What a NAL is, as far as libkvm's kvm_vision.h mapping cares: it needs to
 * tell parameter sets from slices and keyframes from inter frames, and for
 * H.265 it serves VPS+SPS as one "SPS" to the browser player. The encoder
 * backend tags each NAL it emits; libkvm never parses a NAL header. */
typedef enum {
    KVM_NAL_OTHER = 0,
    KVM_NAL_VPS,          /* H.265 only */
    KVM_NAL_SPS,
    KVM_NAL_PPS,
    KVM_NAL_IDR,          /* keyframe slice */
    KVM_NAL_P,            /* inter slice */
} kvm_nal_kind;

typedef struct {
    uint32_t     offset;  /* byte offset of the NAL inside kvm_pack.data */
    uint32_t     length;  /* its length, start code included */
    kvm_nal_kind kind;
} kvm_nalu;

/* An IDR carries at most VPS+SPS+PPS+slice; four is the real maximum the
 * open encoder emits. Sized to eight so a future GOP shape cannot overflow
 * the copy in libkvm.c's stash_pack(). */
#define KVM_MAX_NALU 8u

/* One finished access unit from the encoder backend. `data` is owned by the
 * backend and valid until the next kvm_venc_send()/kvm_venc_get() on that
 * channel; libkvm copies out of it immediately. MJPEG fills exactly one
 * whole-image pack with nalu_num = 0. */
typedef struct {
    uint8_t *data;
    uint32_t len;
    int      keyframe;            /* IDR / JPEG: a decoder can start here */
    uint32_t nalu_num;            /* 0 = not split; serve `data` as one unit */
    kvm_nalu nalu[KVM_MAX_NALU];
} kvm_pack;

#endif /* KVM_TYPES_H_ */
