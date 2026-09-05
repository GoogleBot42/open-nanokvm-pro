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
 * GEOMETRY: parametric (#17) over the capture envelope (64x64..3840x2400,
 * even dims; #52 lifted the 1920 ceiling and E3 the 2160 one) via the
 * vcenc_geom register laws + computed floorplan (derived from a 17-geometry
 * vendor differential, docs/reference/vcenc-open/geom-probe/).
 *
 * RATE CONTROL (#46). The app's bitrate (qlty, kbps), fps, gop and rc_mode
 * knobs drive the from-scratch frame-level controller in vcenc_rc.h for
 * BOTH codecs: every frame gets its QP from the controller, the register
 * program is the vendor's true fixed-QP set (ENC_RC_FIXQP, hardware RC
 * off), the PPS pic_init_qp is the session's seed QP and the hardware
 * writes slice_qp_delta. A bitrate change from the app (kvm_venc_set_bitrate,
 * reached from libkvm's per-read quality argument) or an fps change is
 * applied at the next frame -- no IDR, no channel rebuild. Default when the
 * app supplies a bitrate: CBR (rc_mode 0) or capped VBR (rc_mode 1).
 * Without a bitrate the pre-#46 fixed programs are used. ENV overrides:
 *      OPENKVM_VENC_RC=cbr|vbr    force a controller mode
 *      OPENKVM_VENC_RC=fixqp      the vendor's fixed-QP register set at a
 *                                 pinned QP (RC off)
 *      OPENKVM_VENC_RC=legacy     the pre-#46 shipping program (CBR register
 *                                 cluster as captured, QP block pinned) --
 *                                 byte-identical to what shipped at QP 32
 *      OPENKVM_VENC_QP=<16..51>   the pinned QP for fixqp/legacy
 *      OPENKVM_VENC_RC_LOG=1      one stderr line per frame (type, QP, bytes,
 *                                 running kbps) for bench validation
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
#include "vcenc_hevc_header.h"
#include "vcenc_rc.h"

/* controller selection (V.ctrl) */
#define CTRL_NONE 0u   /* pinned QP: ENC_RC_LEGACY or ENC_RC_FIXQP program */
#define CTRL_CBR  1u
#define CTRL_VBR  2u

/* ---------------- session state (one H.264/H.265 session) ---------------- */
static struct {
    int      fd;                 /* /dev/es_venc; -1 when down */
    int      chn;                /* the kvm channel id we were created as */
    uint32_t *cmd_pool;
    uint8_t  *status_pool;
    struct cmdbuf_mem_parameter mem;
    uint64_t fb_bus;             /* framebuf block (computed floorplan) */
    uint8_t  *fb_map;
    vcenc_geom g;                /* session geometry (#17) */
    uint32_t qp;                 /* pinned frame QP (CTRL_NONE) / PPS pic_init_qp */
    uint32_t rc_mode;            /* builder program: ENC_RC_LEGACY | ENC_RC_FIXQP */
    uint32_t ctrl;               /* CTRL_NONE | CTRL_CBR | CTRL_VBR (#46) */
    struct vcenc_rc rc;          /* the rate controller (CTRL_CBR/VBR) */
    uint32_t kbps, fps;          /* controller target */
    int      rc_log;             /* OPENKVM_VENC_RC_LOG */
    uint32_t codec;              /* ENC_CODEC_H264 | ENC_CODEC_HEVC (#64) */
    uint32_t gop;                /* IDR period; 0 = IDR only at start */
    uint32_t n;                  /* session frame counter */
    int      stride_warned;
    /* one finished frame, packed for kvm_venc_get */
    uint8_t  *pack;              /* SPS+PPS+slice (IDR) or slice (P) */
    uint32_t pack_len;
    int      pack_ready;
    AX_VENC_PICTURE_CODING_TYPE_E pack_coding;
    AX_VENC_NALU_INFO_T nalu[4]; /* VPS+SPS+PPS+slice at an HEVC IDR */
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
    if (!vf->u64PhyAddr[0] && !vf->u64VirAddr[0]) return -1;
    uint32_t stride = vf->u32PicStride[0] ? vf->u32PicStride[0] : M.w;
    if (stride & 1) stride = M.w;       /* YUYV macropixels need even stride */
    uint32_t fsz = vf->u32FrameSize ? vf->u32FrameSize : stride * 2 * M.h;
    /* CPU view: the capture backend's own mapping when it has one (V4L2
     * mmap), else a /dev/mem window over the frame's physical address. */
    const uint8_t *src = (const uint8_t *)(uintptr_t)vf->u64VirAddr[0];
    if (!src) src = kvm_frame_map(vf->u64PhyAddr[0], fsz);
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
    if (V.fb_map)      { munmap(V.fb_map, V.g.span); V.fb_map = NULL; }
    if (V.cmd_pool)    { munmap(V.cmd_pool, V.mem.cmd_total_size); V.cmd_pool = NULL; }
    if (V.status_pool) { munmap(V.status_pool, V.mem.status_total_size); V.status_pool = NULL; }
    if (V.fd >= 0)     { close(V.fd); V.fd = -1; }   /* framebuf freed on close */
    free(V.pack); V.pack = NULL;
    V.pack_ready = 0; V.chn = -1;
}

int kvm_venc_create(int chn, AX_PAYLOAD_TYPE_E type, int w, int h,
                    int fps, int gop, int qlty, int rc_mode)
{
    if (V.fd >= 0) venc_open_down();
    if (M.active)  mj_down();
    if (type == PT_MJPEG) return mj_create(chn, w, h, qlty);
    if (type != PT_H264 && type != PT_H265) {
        fprintf(stderr, "[openvenc][FAIL] payload type %d unsupported\n", (int)type);
        return -1;
    }
    V.codec = (type == PT_H265) ? ENC_CODEC_HEVC : ENC_CODEC_H264;
    {
        const char *why;
        if (vcenc_geom_check(w, h, &why) || vcenc_geom_build_ex(&V.g, w, h, 0)) {
            fprintf(stderr, "[openvenc][FAIL] %dx%d unsupported (%s)\n",
                    w, h, why ? why : "geometry");
            return -1;
        }
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

    struct framebuf_parameter fbp = { .size = V.g.span };
    if (ioctl(V.fd, HANTRO_IOCH_ALLOC_FRAMEBUF, &fbp) < 0) goto fail;
    V.fb_bus = fbp.bus_addr;
    V.fb_map = mmap(NULL, V.g.span, PROT_READ | PROT_WRITE,
                    MAP_SHARED, V.fd, (off_t)fbp.bus_addr);
    if (V.fb_map == MAP_FAILED) { V.fb_map = NULL; goto fail; }

    V.pack = malloc(V.g.out_limit + 256);   /* SPS+PPS headroom over the HW limit */
    if (!V.pack) goto fail;

    /* Rate control (#46). With a bitrate from the app the controller runs
     * over the vendor's fixed-QP register set; the app's rc_mode picks CBR
     * (0) or capped VBR (1). Without one, the pre-#46 pinned programs:
     * HEVC the vendor's fixed-QP set (device-proven for H.265), H.264 the
     * legacy CBR-cluster program it shipped with. ENV overrides on top. */
    V.gop = (gop > 0 && gop <= 1024) ? (uint32_t)gop : 30;
    V.fps = (fps > 0 && fps <= 240) ? (uint32_t)fps : 60;
    V.kbps = qlty > 0 ? (uint32_t)qlty : 0;
    V.qp = ENC_QP_FIXED;
    V.ctrl = V.kbps ? (rc_mode == 1 ? CTRL_VBR : CTRL_CBR) : CTRL_NONE;
    V.rc_mode = (V.ctrl != CTRL_NONE || V.codec == ENC_CODEC_HEVC)
              ? ENC_RC_FIXQP : ENC_RC_LEGACY;
    {
        const char *e = getenv("OPENKVM_VENC_RC");
        if (e && !strcmp(e, "cbr"))         { V.ctrl = CTRL_CBR;  V.rc_mode = ENC_RC_FIXQP; }
        else if (e && !strcmp(e, "vbr"))    { V.ctrl = CTRL_VBR;  V.rc_mode = ENC_RC_FIXQP; }
        else if (e && !strcmp(e, "fixqp"))  { V.ctrl = CTRL_NONE; V.rc_mode = ENC_RC_FIXQP; }
        else if (e && !strcmp(e, "legacy")) { V.ctrl = CTRL_NONE; V.rc_mode = ENC_RC_LEGACY; }
        else if (e)
            fprintf(stderr, "[openvenc] ignoring OPENKVM_VENC_RC=%s "
                            "(cbr|vbr|fixqp|legacy)\n", e);
        if (V.ctrl != CTRL_NONE && !V.kbps) V.kbps = 8000;
        e = getenv("OPENKVM_VENC_QP");
        if (e) {
            uint32_t q = (uint32_t)strtoul(e, NULL, 0);
            if (!vcenc_qp_valid(q))
                fprintf(stderr, "[openvenc] ignoring OPENKVM_VENC_QP=%s "
                                "(range %u..%u)\n", e, VCENC_QP_MIN,
                        VCENC_QP_MAX);
            else if (V.ctrl != CTRL_NONE)
                fprintf(stderr, "[openvenc] OPENKVM_VENC_QP ignored under "
                                "rate control (the controller owns the QP)\n");
            else
                V.qp = q;
        }
        V.rc_log = getenv("OPENKVM_VENC_RC_LOG") != NULL;
    }
    if (V.ctrl != CTRL_NONE) {
        vcenc_rc_init(&V.rc, V.codec, V.g.w, V.g.h, V.fps, V.kbps * 1000.0,
                      V.gop, V.ctrl == CTRL_VBR ? VCENC_RC_VBR : VCENC_RC_CBR);
        V.qp = V.rc.qp_seed;          /* PPS pic_init_qp for the session */
    }
    V.n = 0;
    V.chn = chn;
    V.pack_ready = 0;
    V.stride_warned = 0;
    fprintf(stderr, "[openvenc] up: hwid=0x%08x %s %ux%u framebuf 0x%llx+0x%x "
                    "rc=%s program=%s QP%u gop=%u\n",
            cfg.vcmd_hw_version_id,
            V.codec == ENC_CODEC_HEVC ? "H.265" : "H.264", V.g.w, V.g.h,
            (unsigned long long)V.fb_bus, V.g.span,
            V.ctrl == CTRL_CBR ? "cbr" : V.ctrl == CTRL_VBR ? "vbr" : "pinned",
            V.rc_mode == ENC_RC_FIXQP ? "fixqp" : "legacy",
            V.qp, V.gop);
    if (V.ctrl != CTRL_NONE)
        fprintf(stderr, "[openvenc] rc: %u kbps @ %u fps, seed QP %u (bpp %.4f)\n",
                V.kbps, V.fps, V.rc.qp_seed,
                V.kbps * 1000.0 / ((double)V.fps * V.g.w * V.g.h));
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
    if (vf->u32PicStride[0] && vf->u32PicStride[0] != V.g.stride && !V.stride_warned) {
        /* the register program's input stride is align16(w) px == the open
         * capture stride; a mismatched frame would encode sheared -- refuse
         * loudly, once per session */
        fprintf(stderr, "[openvenc][FAIL] frame stride %u != %u\n",
                vf->u32PicStride[0], V.g.stride);
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

    /* the frame QP: the controller's decision, or the pinned session QP.
     * Under rate control the PPS keeps pic_init_qp = seed and the hardware
     * writes slice_qp_delta (sw7 high field), as the vendor's CBR does. */
    uint32_t qp = V.ctrl != CTRL_NONE ? vcenc_rc_pick_qp(&V.rc, is_idr) : V.qp;
    struct vcenc_frame fr = {
        .frame_num   = gopn,
        .qp          = qp,
        .pic_init_qp = V.ctrl != CTRL_NONE ? V.qp : 0,
        .rc_mode     = V.rc_mode,
        .codec       = V.codec,
        .input_phys  = (uint32_t)vf->u64PhyAddr[0],
    };
    uint32_t *slot = V.cmd_pool + (uint32_t)id * (V.mem.cmd_unit_size / 4);
    ex.cmdbuf_size = vcenc_build_encode_cmdbuf(slot, (uint32_t)V.fb_bus, &V.g,
                                               core_dst, &fr);
    ex.numa_id = 0;

    int rc = -1;
    uint16_t wid = id;
    if (!ex.cmdbuf_size) {
        fprintf(stderr, "[openvenc][FAIL] cmdbuf build rejected qp=%u rc=%u\n",
                fr.qp, fr.rc_mode);
        goto out;
    }
    if (ioctl(V.fd, HANTRO_IOCH_LINK_RUN_CMDBUF, &ex) < 0) goto out;
    if (ioctl(V.fd, HANTRO_IOCH_WAIT_CMDBUF, &wid) < 0) goto out;

    volatile uint32_t *rr = (volatile uint32_t *)
        (V.status_pool + STATUS_SLOT_REG_OFF(id, 0));
    uint32_t bytes = rr[9], cycles = rr[82];
    if (wid != CMDBUF_EXE_STATUS_OK || !cycles || !bytes || bytes > V.g.out_limit) {
        fprintf(stderr, "[openvenc][FAIL] frame %u: wait=%u bytes=%u cycles=%u\n",
                V.n, wid, bytes, cycles);
        goto out;
    }

    /* assemble the pack libkvm.c already knows how to serve: SPS+PPS+slice
     * at every IDR (in-band parameter sets, same as the vendor encoder),
     * bare slice otherwise */
    uint32_t off = 0;
    V.nalu_num = 0;
    if (is_idr && V.codec == ENC_CODEC_HEVC) {
        /* VPS+SPS+PPS from vcenc_hevc_header.h (byte-identical to the
         * vendor's at 1080p); typed with the H265E NAL enums so libkvm can
         * map them onto IMG_H265_TYPE_{SPS,PPS}. */
        uint32_t lvl = vcenc_hevc_level_idc(V.g.w, V.g.h);
        uint32_t vps = vcenc_write_vps(V.pack, lvl);
        uint32_t sps = vcenc_write_hevc_sps(V.pack + vps, V.g.w, V.g.h, lvl);
        uint32_t pps = vcenc_write_hevc_pps(V.pack + vps + sps, V.qp);
        V.nalu[0] = (AX_VENC_NALU_INFO_T){ .u32NaluOffset = 0, .u32NaluLength = vps };
        V.nalu[0].unNaluType.enH265EType = AX_H265E_NALU_VPS;
        V.nalu[1] = (AX_VENC_NALU_INFO_T){ .u32NaluOffset = vps, .u32NaluLength = sps };
        V.nalu[1].unNaluType.enH265EType = AX_H265E_NALU_SPS;
        V.nalu[2] = (AX_VENC_NALU_INFO_T){ .u32NaluOffset = vps + sps, .u32NaluLength = pps };
        V.nalu[2].unNaluType.enH265EType = AX_H265E_NALU_PPS;
        off = vps + sps + pps;
        V.nalu_num = 3;
    } else if (is_idr) {
        uint32_t sps = vcenc_write_sps(V.pack, V.g.w, V.g.h);
        /* slice_qp_delta is 0 in the HW's slice header, so the PPS
         * pic_init_qp MUST equal the register program's frame QP. */
        uint32_t pps = vcenc_write_pps(V.pack + sps, V.qp);
        V.nalu[0] = (AX_VENC_NALU_INFO_T){ .u32NaluOffset = 0, .u32NaluLength = sps };
        V.nalu[0].unNaluType.enH264EType = AX_H264E_NALU_SPS;
        V.nalu[1] = (AX_VENC_NALU_INFO_T){ .u32NaluOffset = sps, .u32NaluLength = pps };
        V.nalu[1].unNaluType.enH264EType = AX_H264E_NALU_PPS;
        off = sps + pps;
        V.nalu_num = 2;
    }
    volatile uint8_t *sb = (volatile uint8_t *)V.fb_map + V.g.off_out
                         + ENC_STREAM_SUBOFF;
    for (uint32_t i = 0; i < bytes; i++) V.pack[off + i] = sb[i];
    V.nalu[V.nalu_num] = (AX_VENC_NALU_INFO_T){ .u32NaluOffset = off,
                                                .u32NaluLength = bytes };
    if (V.codec == ENC_CODEC_HEVC)
        V.nalu[V.nalu_num].unNaluType.enH265EType =
            is_idr ? AX_H265E_NALU_IDRSLICE : AX_H265E_NALU_PSLICE;
    else
        V.nalu[V.nalu_num].unNaluType.enH264EType =
            is_idr ? AX_H264E_NALU_IDRSLICE : AX_H264E_NALU_PSLICE;
    V.nalu_num++;
    V.pack_len = off + bytes;
    V.pack_coding = is_idr ? AX_VENC_INTRA_FRAME : AX_VENC_PREDICTED_FRAME;
    V.pack_ready = 1;
    if (V.ctrl != CTRL_NONE) {
        vcenc_rc_update(&V.rc, 8.0 * V.pack_len, qp);   /* wire bytes */
        if (V.rc_log)
            fprintf(stderr, "[openvenc][rc] f=%u %s qp=%u bytes=%u avg=%.0f kbps\n",
                    V.n, is_idr ? "IDR" : "P", qp, V.pack_len,
                    V.rc.total_bits / V.rc.frames * V.fps / 1000.0);
    }
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
    (void)type;
    if (V.fd < 0 || chn != V.chn) return -1;
    if (fps <= 0 || fps > 240) return -1;
    V.fps = (uint32_t)fps;
    if (V.ctrl != CTRL_NONE)             /* same bits, fewer/more frames */
        vcenc_rc_set_target(&V.rc, V.kbps * 1000.0, V.fps);
    return 0;
}

int kvm_venc_set_bitrate(int chn, int kbps)
{
    if (V.fd < 0 || chn != V.chn || V.ctrl == CTRL_NONE) return -1;
    if (kbps <= 0) return -1;
    V.kbps = (uint32_t)kbps;
    vcenc_rc_set_target(&V.rc, V.kbps * 1000.0, V.fps);   /* next frame */
    if (V.rc_log)
        fprintf(stderr, "[openvenc][rc] retarget %u kbps @ %u fps\n", V.kbps, V.fps);
    return 0;
}

int kvm_venc_set_gop(int chn, int gop)
{
    if (V.fd < 0 || chn != V.chn) return -1;
    V.gop = (gop > 0 && gop <= 1024) ? (uint32_t)gop : V.gop;
    if (V.ctrl != CTRL_NONE) vcenc_rc_set_gop(&V.rc, V.gop);
    V.n = 0;   /* restart the GOP: next frame is an IDR (cheap keyframe hook) */
    return 0;
}

#endif /* KVM_OPEN_VENC */
