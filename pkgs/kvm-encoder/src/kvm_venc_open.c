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
 * MJPEG (#51) is a from-source SOFTWARE path: the captured frame is packed
 * YUYV -- exactly JPEG's YCbCr 4:2:2 -- so each session frame is mapped for
 * CPU read (kvm_frame_map), de-interleaved row-wise into planar iMCU rows and
 * handed to libjpeg-turbo's jpeg_write_raw_data (no color conversion, no
 * scaling, any geometry). The VCMD hardware is not involved; the whole JPEG
 * is served as one pack, which is what libkvm.c expects for MJPEG.
 *
 * v1 LIMITS (fixed-QP stage; the #46 seams -- per-frame QP input and
 * per-frame emitted-size readback -- are already in the builder API):
 *  - H.264: 1920x1080 only; the register program is 1080p-specific. Other
 *    source geometries fail create until the geometry registers are derived.
 *    (MJPEG is parametric already.)
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
#include <setjmp.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include <jpeglib.h>

#include "ax_base_type.h"
#include "ax_global_type.h"
#include "ax_venc_comm.h"
#include "kvm_pipeline.h"
#include "kvm_preview.h"   /* kvm_frame_map: CPU view of a captured frame */

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

/* ---------------- MJPEG session (from-source soft-JPEG, #51) --------------
 * libjpeg's default error handler exit()s the process; route errors through
 * setjmp instead so a bad frame costs one frame, not the server. */
struct mj_err { struct jpeg_error_mgr pub; jmp_buf env; };

static void mj_error_exit(j_common_ptr ci)
{
    struct mj_err *e = (struct mj_err *)ci->err;
    (*ci->err->output_message)(ci);
    longjmp(e->env, 1);
}

static struct {
    int      active;
    int      chn;
    uint32_t w, h;
    struct jpeg_compress_struct cj;
    struct mj_err jerr;
    /* jpeg_mem_dest buffer. The lib swaps in a malloc'd replacement when a
     * frame outgrows it (WITHOUT freeing ours -- jdatadst.c frees only its
     * own intermediates), so the send path adopts the replacement. jsz is a
     * struct field, not a local, to keep it off the setjmp-clobber list. */
    unsigned char *jout;
    unsigned long  jout_cap, jsz;
    uint32_t jout_len;
    int      ready;
    uint8_t *rows;   /* 1 cached copy row + 8-row planar Y/Cb/Cr staging */
} M;

static void mj_down(void)
{
    if (!M.active) return;
    jpeg_destroy_compress(&M.cj);
    free(M.rows);
    free(M.jout);
    memset(&M, 0, sizeof M);
}

static int mj_create(int chn, int w, int h, int qlty)
{
    if (w <= 0 || h <= 0 || (w & 1)) {
        fprintf(stderr, "[openvenc][FAIL] MJPEG %dx%d unsupported "
                        "(YUYV needs an even width)\n", w, h);
        return -1;
    }
    memset(&M, 0, sizeof M);
    M.w = (uint32_t)w; M.h = (uint32_t)h;

    /* copy row (w*2) + 8 Y rows (8w) + 8 Cb + 8 Cr rows (4w each) */
    M.rows = malloc((size_t)M.w * 18);
    M.jout_cap = 1u << 20;
    M.jout = malloc(M.jout_cap);
    if (!M.rows || !M.jout) goto fail;

    M.cj.err = jpeg_std_error(&M.jerr.pub);
    M.jerr.pub.error_exit = mj_error_exit;
    if (setjmp(M.jerr.env)) {           /* create-time libjpeg failure */
        jpeg_destroy_compress(&M.cj);
        goto fail;
    }
    jpeg_create_compress(&M.cj);
    M.cj.image_width      = M.w;
    M.cj.image_height     = M.h;
    M.cj.input_components = 3;
    M.cj.in_color_space   = JCS_YCbCr;
    jpeg_set_defaults(&M.cj);
    /* qlty is the server's MJPEG quality knob, already ~[50,100] */
    jpeg_set_quality(&M.cj, qlty < 1 ? 80 : (qlty > 100 ? 100 : qlty), TRUE);
    M.cj.raw_data_in = TRUE;
    /* YUYV == YCbCr 4:2:2: Y sampled 2x horizontally, chroma at full height */
    M.cj.comp_info[0].h_samp_factor = 2; M.cj.comp_info[0].v_samp_factor = 1;
    M.cj.comp_info[1].h_samp_factor = 1; M.cj.comp_info[1].v_samp_factor = 1;
    M.cj.comp_info[2].h_samp_factor = 1; M.cj.comp_info[2].v_samp_factor = 1;

    M.active = 1; M.chn = chn;
    fprintf(stderr, "[openvenc] MJPEG up: %ux%u from-source soft-JPEG q=%d\n",
            M.w, M.h, qlty);
    return 0;
fail:
    free(M.rows); free(M.jout);
    memset(&M, 0, sizeof M);
    fprintf(stderr, "[openvenc][FAIL] MJPEG session bring-up\n");
    return -1;
}

static int mj_send(AX_VIDEO_FRAME_INFO_T *frame)
{
    AX_VIDEO_FRAME_T *vf = &frame->stVFrame;
    if (!vf->u64PhyAddr[0]) return -1;
    uint32_t stride = vf->u32PicStride[0] ? vf->u32PicStride[0] : M.w;
    if (stride & 1) stride = M.w;       /* YUYV macropixels need even stride */
    uint32_t fsz = vf->u32FrameSize ? vf->u32FrameSize : stride * 2 * M.h;
    const uint8_t *src = kvm_frame_map(vf->u64PhyAddr[0], fsz);
    if (!src) return -1;

    unsigned char *old = M.jout;        /* set before setjmp, never changed */
    M.jsz = M.jout_cap;
    if (setjmp(M.jerr.env)) {           /* mid-encode libjpeg failure */
        jpeg_abort_compress(&M.cj);     /* session stays usable */
        if (M.jout != old) { free(old); M.jout_cap = M.jsz; }
        M.ready = 0;
        return -1;
    }
    jpeg_mem_dest(&M.cj, &M.jout, &M.jsz);
    jpeg_start_compress(&M.cj, TRUE);

    uint8_t *tmp = M.rows;
    uint8_t *py  = tmp + (size_t)M.w * 2;
    uint8_t *pcb = py  + (size_t)M.w * 8;
    uint8_t *pcr = pcb + (size_t)(M.w / 2) * 8;
    JSAMPROW yr[8], cbr[8], crr[8];
    for (int i = 0; i < 8; i++) {
        yr[i]  = py  + (size_t)M.w * i;
        cbr[i] = pcb + (size_t)(M.w / 2) * i;
        crr[i] = pcr + (size_t)(M.w / 2) * i;
    }
    JSAMPARRAY planes[3] = { yr, cbr, crr };

    while (M.cj.next_scanline < M.cj.image_height) {
        for (uint32_t i = 0; i < 8; i++) {
            uint32_t sy = M.cj.next_scanline + i;
            if (sy >= M.h) sy = M.h - 1;          /* replicate the last row */
            /* one bulk copy out of the uncached CMM mapping, then
             * de-interleave from cache */
            memcpy(tmp, src + (size_t)sy * stride * 2, (size_t)M.w * 2);
            const uint8_t *p = tmp;
            uint8_t *y = yr[i], *cb = cbr[i], *cr = crr[i];
            for (uint32_t x = 0; x < M.w / 2; x++, p += 4) {
                *y++  = p[0]; *y++ = p[2];
                *cb++ = p[1]; *cr++ = p[3];
            }
        }
        jpeg_write_raw_data(&M.cj, planes, 8);
    }
    jpeg_finish_compress(&M.cj);
    if (M.jout != old) { free(old); M.jout_cap = M.jsz; }  /* adopt regrown */
    M.jout_len = (uint32_t)M.jsz;       /* term_destination: bytes written */
    M.ready = 1;
    return 0;
}

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
    if (V.fd >= 0) venc_open_down();
    if (M.active)  mj_down();
    if (type == PT_MJPEG) return mj_create(chn, w, h, qlty);
    if (type != PT_H264) {
        fprintf(stderr, "[openvenc][FAIL] payload type %d unsupported\n", (int)type);
        return -1;
    }
    if ((uint32_t)w != ENC_WIDTH || (uint32_t)h != ENC_HEIGHT) {
        fprintf(stderr, "[openvenc][FAIL] %dx%d unsupported (register program "
                        "is 1080p-only for now)\n", w, h);
        return -1;
    }

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
    mj_down();
}

void kvm_venc_module_deinit(void) { venc_open_down(); mj_down(); }

int kvm_venc_send(int chn, AX_VIDEO_FRAME_INFO_T *frame)
{
    if (M.active) return (chn == M.chn) ? mj_send(frame) : -1;
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
    if (M.active) {     /* MJPEG: the whole JPEG is one pack, no NALs */
        if (chn != M.chn || !M.ready) return -1;
        memset(st, 0, sizeof *st);
        st->stPack.pu8Addr      = M.jout;
        st->stPack.u32Len       = M.jout_len;
        st->stPack.enCodingType = AX_VENC_INTRA_FRAME;
        M.ready = 0;
        return 0;
    }
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
