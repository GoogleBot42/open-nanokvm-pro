/*
 * kvm_venc_open.c -- BLOB-FREE H.264 encode backend for the AX630C (#25).
 *
 * Drop-in replacement for the VENC half of kvm_pipeline.c (kvm_venc_create /
 * kvm_venc_destroy / kvm_venc_module_deinit / kvm_venc_send / kvm_venc_get /
 * kvm_venc_release / kvm_venc_set_fps / kvm_venc_set_gop). Compiled ONLY when
 * KVM_OPEN_VENC is defined; otherwise kvm_pipeline.c provides the vendor
 * AX_VENC versions. The public kvm_vision.h ABI and libkvm.c are unchanged.
 *
 * HOW IT WORKS. This is the device-proven open VC8000E path (#44 driver +
 * #45 EWL + the #25 IPPP session work, docs/blob-replacement.md) folded into
 * the library: open(/dev/es_venc) -> VCMD/cmdbuf params -> framebuf ALLOC of
 * the relocated captured layout (recon/aux/output; from-source CMM allocator)
 * -> per-frame from-source cmdbuf (fixed-QP(32) register program + Stage-0-
 * derived P overlay + recon/aux bank ping-pong) with swreg12 pointed STRAIGHT
 * AT the capture pool frame (packed YUYV 4:2:2, the encoder's exact input
 * format -- zero-copy, no conversion) -> RESERVE/LINK/WAIT -> slice readback
 * -> from-source SPS/PPS prepended at each IDR. No vendor library, no
 * ax_venc.ko/ax_jenc.ko (the open ax630c_venc_vcmd.ko drives the hardware).
 *
 * The register-program / cmdbuf / SPS-PPS sources are shared verbatim with
 * the standalone prover (pkgs/vcenc-ewl: vcmd_abi.h, vcenc_cmdbuf.h,
 * vcenc_encode.h, vcenc_header.h, img_qp32_payload.h) -- one source of truth.
 *
 * v1 LIMITS (fixed-QP stage; the #46 seams -- per-frame QP input and
 * per-frame emitted-size readback -- are already in the builder API):
 *  - H.264 only: PT_MJPEG create fails (no open JPEG path yet; the server
 *    treats it as IMG_VENC_ERROR and H.264 streaming is unaffected).
 *  - 1920x1080 only: the register program is 1080p-specific. Other source
 *    geometries fail create until the geometry registers are derived.
 *  - Rate control: fixed QP32. fps/bitrate/rc-mode knobs are accepted and
 *    ignored (quality-priority mode); gop is honored (IDR period).
 *
 * The vendor AX_VENC_STREAM_T/NALU structs are used purely as the internal
 * hand-off shape libkvm.c already speaks (SDK headers, no vendor code).
 */
#ifdef KVM_OPEN_VENC

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include "ax_base_type.h"
#include "ax_global_type.h"
#include "ax_venc_comm.h"
#include "kvm_pipeline.h"

#include "vcmd_abi.h"
#include "vcenc_cmdbuf.h"
#include "vcenc_encode.h"
#include "vcenc_header.h"

/* ---------------- session state (one H.264 session) ---------------- */
static struct {
    int      fd;                 /* /dev/es_venc; -1 when down */
    int      chn;                /* the kvm channel id we were created as */
    uint32_t *cmd_pool;
    uint8_t  *status_pool;
    struct cmdbuf_mem_parameter mem;
    uint64_t fb_bus;             /* framebuf block (relocated layout) */
    uint8_t  *fb_map;
    uint32_t delta;              /* fb_bus - ENC_LAYOUT_BASE */
    uint32_t gop;                /* IDR period; 0 = IDR only at start */
    uint32_t n;                  /* session frame counter */
    int      stride_warned;
    /* one finished frame, packed for kvm_venc_get */
    uint8_t  *pack;              /* SPS+PPS+slice (IDR) or slice (P) */
    uint32_t pack_len;
    int      pack_ready;
    AX_VENC_PICTURE_CODING_TYPE_E pack_coding;
    AX_VENC_NALU_INFO_T nalu[3];
    uint32_t nalu_num;
} V = { .fd = -1, .chn = -1 };

static void venc_open_down(void)
{
    if (V.fb_map)      { munmap(V.fb_map, ENC_LAYOUT_SPAN); V.fb_map = NULL; }
    if (V.cmd_pool)    { munmap(V.cmd_pool, V.mem.cmd_total_size); V.cmd_pool = NULL; }
    if (V.status_pool) { munmap(V.status_pool, V.mem.status_total_size); V.status_pool = NULL; }
    if (V.fd >= 0)     { close(V.fd); V.fd = -1; }   /* framebuf freed on close */
    free(V.pack); V.pack = NULL;
    V.pack_ready = 0; V.chn = -1;
}

int kvm_venc_create(int chn, AX_PAYLOAD_TYPE_E type, int w, int h,
                    int fps, int gop, int qlty, int rc_mode)
{
    (void)fps; (void)rc_mode;
    if (type != PT_H264) {
        fprintf(stderr, "[openvenc][FAIL] payload type %d unsupported "
                        "(open encoder is H.264-only; no MJPEG path)\n", (int)type);
        return -1;
    }
    if ((uint32_t)w != ENC_WIDTH || (uint32_t)h != ENC_HEIGHT) {
        fprintf(stderr, "[openvenc][FAIL] %dx%d unsupported (register program "
                        "is 1080p-only for now)\n", w, h);
        return -1;
    }
    if (V.fd >= 0) venc_open_down();

    V.fd = open(VCMD_DEV_NODE, O_RDWR);
    if (V.fd < 0) {
        fprintf(stderr, "[openvenc][FAIL] open(%s): %s (is ax630c_venc_vcmd.ko loaded?)\n",
                VCMD_DEV_NODE, strerror(errno));
        return -1;
    }

    struct config_parameter cfg = { .module_type = VCMD_TYPE_ENCODER };
    if (ioctl(V.fd, HANTRO_IOCH_GET_VCMD_PARAMETER, &cfg) < 0) goto fail;
    memset(&V.mem, 0, sizeof V.mem);
    if (ioctl(V.fd, HANTRO_IOCH_GET_CMDBUF_PARAMETER, &V.mem) < 0) goto fail;

    V.cmd_pool = mmap(NULL, V.mem.cmd_total_size, PROT_READ | PROT_WRITE,
                      MAP_SHARED, V.fd, (off_t)V.mem.cmd_phy_addr);
    V.status_pool = mmap(NULL, V.mem.status_total_size, PROT_READ | PROT_WRITE,
                         MAP_SHARED, V.fd, (off_t)V.mem.status_phy_addr);
    if (V.cmd_pool == MAP_FAILED || V.status_pool == MAP_FAILED) {
        if (V.cmd_pool == MAP_FAILED) V.cmd_pool = NULL;
        if (V.status_pool == MAP_FAILED) V.status_pool = NULL;
        goto fail;
    }

    struct framebuf_parameter fbp = { .size = ENC_LAYOUT_SPAN };
    if (ioctl(V.fd, HANTRO_IOCH_ALLOC_FRAMEBUF, &fbp) < 0) goto fail;
    V.fb_bus = fbp.bus_addr;
    V.delta  = (uint32_t)(fbp.bus_addr - ENC_LAYOUT_BASE);
    V.fb_map = mmap(NULL, ENC_LAYOUT_SPAN, PROT_READ | PROT_WRITE,
                    MAP_SHARED, V.fd, (off_t)fbp.bus_addr);
    if (V.fb_map == MAP_FAILED) { V.fb_map = NULL; goto fail; }

    V.pack = malloc(ENC_OUT_LIMIT + 256);   /* SPS+PPS headroom over the HW limit */
    if (!V.pack) goto fail;

    V.gop = (gop > 0 && gop <= 1024) ? (uint32_t)gop : 30;
    V.n = 0;
    V.chn = chn;
    V.pack_ready = 0;
    V.stride_warned = 0;
    fprintf(stderr, "[openvenc] up: hwid=0x%08x framebuf 0x%llx+0x%x (delta 0x%x) "
                    "fixed-QP%u gop=%u qlty-req=%d (ignored)\n",
            cfg.vcmd_hw_version_id, (unsigned long long)V.fb_bus,
            ENC_LAYOUT_SPAN, V.delta, ENC_QP_FIXED, V.gop, qlty);
    return 0;
fail:
    fprintf(stderr, "[openvenc][FAIL] session bring-up: %s\n", strerror(errno));
    venc_open_down();
    return -1;
}

void kvm_venc_destroy(int chn)
{
    (void)chn;
    venc_open_down();
}

void kvm_venc_module_deinit(void) { venc_open_down(); }

int kvm_venc_send(int chn, AX_VIDEO_FRAME_INFO_T *frame)
{
    if (V.fd < 0 || chn != V.chn) return -1;
    AX_VIDEO_FRAME_T *vf = &frame->stVFrame;
    if (!vf->u64PhyAddr[0]) return -1;
    if (vf->u32PicStride[0] && vf->u32PicStride[0] != ENC_WIDTH && !V.stride_warned) {
        /* the register program bakes the 1920-px stride; a mismatched frame
         * would encode sheared -- refuse loudly, once per session */
        fprintf(stderr, "[openvenc][FAIL] frame stride %u != %u\n",
                vf->u32PicStride[0], ENC_WIDTH);
        V.stride_warned = 1;
        return -1;
    }

    uint32_t gopn = V.gop ? V.n % V.gop : V.n;
    int is_idr = (gopn == 0);

    struct exchange_parameter ex;
    memset(&ex, 0, sizeof ex);
    ex.module_type = VCMD_TYPE_ENCODER;
    if (ioctl(V.fd, HANTRO_IOCH_RESERVE_CMDBUF, &ex) < 0) return -1;
    uint16_t id = ex.cmdbuf_id;

    uint64_t core_dst = V.mem.status_hw_addr + (uint64_t)id * 0x2000
                      + (SUBMODULE_MAIN_ADDR / 2);
    memset(V.status_pool + STATUS_SLOT_REG_OFF(id, 0), 0, 512 * 4);

    struct vcenc_frame fr = {
        .frame_num  = gopn,
        .qp         = ENC_QP_FIXED,
        .input_phys = (uint32_t)vf->u64PhyAddr[0],
    };
    uint32_t *slot = V.cmd_pool + (uint32_t)id * (V.mem.cmd_unit_size / 4);
    ex.cmdbuf_size = vcenc_build_encode_cmdbuf(slot, V.delta, core_dst, &fr);
    ex.numa_id = 0;

    int rc = -1;
    uint16_t wid = id;
    if (ioctl(V.fd, HANTRO_IOCH_LINK_RUN_CMDBUF, &ex) < 0) goto out;
    if (ioctl(V.fd, HANTRO_IOCH_WAIT_CMDBUF, &wid) < 0) goto out;

    volatile uint32_t *rr = (volatile uint32_t *)
        (V.status_pool + STATUS_SLOT_REG_OFF(id, 0));
    uint32_t bytes = rr[9], cycles = rr[82];
    if (wid != CMDBUF_EXE_STATUS_OK || !cycles || !bytes || bytes > ENC_OUT_LIMIT) {
        fprintf(stderr, "[openvenc][FAIL] frame %u: wait=%u bytes=%u cycles=%u\n",
                V.n, wid, bytes, cycles);
        goto out;
    }

    /* assemble the pack libkvm.c already knows how to serve: SPS+PPS+slice
     * at every IDR (in-band parameter sets, same as the vendor encoder),
     * bare slice otherwise */
    uint32_t off = 0;
    V.nalu_num = 0;
    if (is_idr) {
        uint32_t sps = vcenc_write_sps(V.pack, ENC_WIDTH, ENC_HEIGHT);
        uint32_t pps = vcenc_write_pps(V.pack + sps, ENC_QP_FIXED);
        V.nalu[0] = (AX_VENC_NALU_INFO_T){ .u32NaluOffset = 0, .u32NaluLength = sps };
        V.nalu[0].unNaluType.enH264EType = AX_H264E_NALU_SPS;
        V.nalu[1] = (AX_VENC_NALU_INFO_T){ .u32NaluOffset = sps, .u32NaluLength = pps };
        V.nalu[1].unNaluType.enH264EType = AX_H264E_NALU_PPS;
        off = sps + pps;
        V.nalu_num = 2;
    }
    volatile uint8_t *sb = (volatile uint8_t *)V.fb_map + ENC_OUT_PAGE_OFF
                         + ENC_STREAM_SUBOFF;
    for (uint32_t i = 0; i < bytes; i++) V.pack[off + i] = sb[i];
    V.nalu[V.nalu_num] = (AX_VENC_NALU_INFO_T){ .u32NaluOffset = off,
                                                .u32NaluLength = bytes };
    V.nalu[V.nalu_num].unNaluType.enH264EType =
        is_idr ? AX_H264E_NALU_IDRSLICE : AX_H264E_NALU_PSLICE;
    V.nalu_num++;
    V.pack_len = off + bytes;
    V.pack_coding = is_idr ? AX_VENC_INTRA_FRAME : AX_VENC_PREDICTED_FRAME;
    V.pack_ready = 1;
    V.n++;
    rc = 0;
out:
    { uint16_t rid = id; ioctl(V.fd, HANTRO_IOCH_RELEASE_CMDBUF, &rid); }
    return rc;
}

int kvm_venc_get(int chn, AX_VENC_STREAM_T *st, int timeout_ms)
{
    (void)timeout_ms;   /* encode is synchronous in kvm_venc_send */
    if (V.fd < 0 || chn != V.chn || !V.pack_ready) return -1;
    memset(st, 0, sizeof *st);
    st->stPack.pu8Addr      = V.pack;
    st->stPack.u32Len       = V.pack_len;
    st->stPack.enCodingType = V.pack_coding;
    st->stPack.u32NaluNum   = V.nalu_num;
    memcpy(st->stPack.stNaluInfo, V.nalu, V.nalu_num * sizeof(V.nalu[0]));
    V.pack_ready = 0;
    return 0;
}

void kvm_venc_release(int chn, AX_VENC_STREAM_T *st)
{
    (void)chn; (void)st;   /* pack buffer is session-owned */
}

int kvm_venc_set_fps(int chn, AX_PAYLOAD_TYPE_E type, int fps)
{
    (void)chn; (void)type; (void)fps;   /* fixed-QP: nothing rate-shaped yet */
    return 0;
}

int kvm_venc_set_gop(int chn, int gop)
{
    if (V.fd < 0 || chn != V.chn) return -1;
    V.gop = (gop > 0 && gop <= 1024) ? (uint32_t)gop : V.gop;
    V.n = 0;   /* restart the GOP: next frame is an IDR (cheap keyframe hook) */
    return 0;
}

#endif /* KVM_OPEN_VENC */
