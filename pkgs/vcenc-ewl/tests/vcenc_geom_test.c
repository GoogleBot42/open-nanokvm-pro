// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * vcenc_geom_test -- the geometry-law proof for the open encoder (#17).
 *
 * Three properties, all host-checkable:
 *
 * 1. GOLDEN VECTORS: for every one of the 25 geometries the VENDOR encoder
 *    was driven at on the real device (the 2026-08-31 17-geometry probe plus
 *    the nine 2026-09-04 E3 geometries, eight of them above 1920 wide), our
 *    vcenc_geom laws must reproduce the vendor's programmed register values
 *    and buffer pitches exactly (vcenc_geom_vectors.h is auto-generated from
 *    the decoded cmdbuf WREG programs -- no transcription).
 *
 * 2. TEMPLATE IDENTITY: at 1920x1080 the full cmdbuf builder must reproduce
 *    the device-proven img_qp32 register program bit-for-bit for every
 *    register EXCEPT the DMA addresses (which moved from the relocated
 *    captured layout to the computed floorplan -- coded bits provably do not
 *    depend on buffer placement, and the on-device NAL regression covers it).
 *    This is the ENC_RC_LEGACY qp-32 program, i.e. what the device ships.
 *
 * 3. FIXQP IDENTITY: in ENC_RC_FIXQP the builder must reproduce the VENDOR's
 *    own fixed-QP 1080p program for every QP of the E2 ladder (16..51 plus
 *    the I28/P34 run), IDR and P, in all 511 registers bar the addresses and
 *    two documented residuals (fixqp_residual() below).
 */
#include <stdio.h>
#include <string.h>
#include "../vcenc_encode.h"
#include "vcenc_geom_vectors.h"
#include "vcenc_fixqp_vectors.h"
#include "vcenc_hevc_vectors.h"

static int fails;

#define CHECK(geom, name, want, got) do {                                  \
    if ((uint32_t)(want) != (uint32_t)(got)) {                             \
        printf("FAIL %4dx%-4d %-10s want=0x%08x got=0x%08x\n",             \
               (geom)->w, (geom)->h, name, (uint32_t)(want),               \
               (uint32_t)(got));                                           \
        fails++;                                                           \
    }                                                                      \
} while (0)

static void golden(void)
{
    for (unsigned i = 0; i < sizeof VG / sizeof VG[0]; i++) {
        vcenc_geom g;
        if (vcenc_geom_build(&g, VG[i].w, VG[i].h)) {
            printf("FAIL %dx%d rejected by envelope\n", VG[i].w, VG[i].h);
            fails++;
            continue;
        }
        CHECK(&VG[i], "sw5_idr", VG[i].sw5_idr, g.sw5 | 0x02u);
        CHECK(&VG[i], "sw38", VG[i].sw38, g.sw38);
        CHECK(&VG[i], "sw134", VG[i].sw134, g.sw134);
        CHECK(&VG[i], "sw193_idr", VG[i].sw193_idr, g.sw193_idr);
        if (VG[i].sw193_p)
            CHECK(&VG[i], "sw193_p", VG[i].sw193_p, g.sw193_p);
        CHECK(&VG[i], "sw210", VG[i].sw210, g.sw210);
        CHECK(&VG[i], "sw212", VG[i].sw212, g.sw212);
        CHECK(&VG[i], "sw213", VG[i].sw213, g.sw213);
        CHECK(&VG[i], "sw237", VG[i].sw237, g.sw237);
        CHECK(&VG[i], "sw245", VG[i].sw245, g.sw245);
        CHECK(&VG[i], "sw246", VG[i].sw246, g.sw246);
        CHECK(&VG[i], "sw261", VG[i].sw261, g.sw261);
        if (VG[i].lupitch) {
            CHECK(&VG[i], "lupitch", VG[i].lupitch,
                  g.off_luma[1] - g.off_luma[0]);
            CHECK(&VG[i], "chpitch", VG[i].chpitch,
                  g.off_chroma[1] - g.off_chroma[0]);
            CHECK(&VG[i], "s62off", VG[i].s62off, g.s62off);
            CHECK(&VG[i], "s239pitch", VG[i].s239pitch,
                  g.off_s239[1] - g.off_s239[0]);
            CHECK(&VG[i], "s114pitch", VG[i].s114pitch,
                  g.off_s114[1] - g.off_s114[0]);
        }
    }
    printf("golden vectors: %u geometries checked\n",
           (unsigned)(sizeof VG / sizeof VG[0]));
}

/* DMA-address registers: placement moved to the computed floorplan. */
static int is_addr_reg(int r)
{
    static const int a[] = { 8, 10, 12, 13, 14, 15, 16, 18, 19, 27, 46,
                             60, 62, 64, 66, 72, 74, 114, 239, 241 };
    for (unsigned i = 0; i < sizeof a / sizeof a[0]; i++)
        if (a[i] == r)
            return 1;
    return 0;
}

static void template_identity(void)
{
    static uint32_t buf[ENC_CMDBUF_WORDS];
    vcenc_geom g;
    struct vcenc_frame fr = { .frame_num = 0, .qp = 32,
                              .rc_mode = ENC_RC_LEGACY };
    if (vcenc_geom_build(&g, 1920, 1080)) {
        printf("FAIL 1080p rejected\n");
        fails++;
        return;
    }
    if (vcenc_build_encode_cmdbuf(buf, 0x70000000u, &g, 0, &fr)
        != ENC_CMDBUF_BYTES) {
        printf("FAIL builder returned wrong size\n");
        fails++;
        return;
    }
    const uint32_t *sw1 = buf + 5;
    int diffs = 0;
    for (int r = 1; r <= ENC_BULK_NREGS; r++) {
        if (is_addr_reg(r))
            continue;
        if (sw1[r - 1] != img_qp32[r - 1]) {
            printf("FAIL 1080p template swreg%d want=0x%08x got=0x%08x\n",
                   r, img_qp32[r - 1], sw1[r - 1]);
            fails++;
            diffs++;
        }
    }
    printf("1080p template identity: %d non-address registers differ\n", diffs);
}

static void envelope(void)
{
    vcenc_geom g;
    static const struct { int w, h, ok; } E[] = {
        { 1920, 1200, 1 }, { 64, 64, 1 }, { 1366, 768, 1 },
        { 3840, 2160, 1 }, { 3840, 2400, 1 }, { 3842, 2160, 0 },
        { 3840, 2402, 0 }, { 62, 64, 0 },
        { 1365, 768, 0 }, { 1280, 719, 0 },
    };
    for (unsigned i = 0; i < sizeof E / sizeof E[0]; i++) {
        int r = vcenc_geom_build(&g, E[i].w, E[i].h);
        if ((r == 0) != (E[i].ok != 0)) {
            printf("FAIL envelope %dx%d expected %s\n", E[i].w, E[i].h,
                   E[i].ok ? "accept" : "reject");
            fails++;
        }
    }
    printf("envelope: accept/reject checked\n");
}

/*
 * Registers our ENC_RC_FIXQP program legitimately differs from the vendor's:
 *
 *  sw9   the output byte limit. The vendor's law is 2WH + 0x10000 - (SPS+PPS
 *        bytes) at an IDR (so it tracks the header length: 0x4047d8 at QP32,
 *        0x4047d7 wherever the PPS pic_init_qp is one bit longer) and
 *        2WH + 0x10000 at a P frame. We reserve a fixed 40-byte slot and emit
 *        our own headers from vcenc_header.h, so ours is 2WH + 0xffd8 always.
 *  sw105 P frames only: the per-frame RC bit-budget state the hardware
 *        rewrites every frame (0x35c6..0x3af5 across the ladder, content- and
 *        history-dependent). We program the vendor's IDR constant, 15000.
 */
static int fixqp_residual(int reg, int is_p)
{
    return reg == 9 || (is_p && reg == 105);
}

static void fixqp_identity(void)
{
    static uint32_t buf[ENC_CMDBUF_WORDS];
    static uint32_t want[ENC_BULK_NREGS + 1];
    vcenc_geom g;
    int total = 0;

    if (vcenc_geom_build(&g, 1920, 1080)) {
        printf("FAIL 1080p rejected\n");
        fails++;
        return;
    }
    for (unsigned v = 0; v < sizeof VFQ / sizeof VFQ[0]; v++) {
        struct vcenc_frame fr = {
            .frame_num   = VFQ[v].is_p ? 1u : 0u,
            .qp          = VFQ[v].qp,
            .rc_mode     = ENC_RC_FIXQP,
            .pic_init_qp = VFQ[v].pic_init_qp,
        };
        if (vcenc_build_encode_cmdbuf(buf, 0x70000000u, &g, 0, &fr)
            != ENC_CMDBUF_BYTES) {
            printf("FAIL %s: builder rejected qp %u\n", VFQ[v].tag, VFQ[v].qp);
            fails++;
            continue;
        }
        memset(want, 0, sizeof want);
        for (unsigned k = 0; k < VFQ[v].n; k++)
            want[VFQ[v].regs[k].reg] = VFQ[v].regs[k].val;

        const uint32_t *sw1 = buf + 5;
        int diffs = 0;
        /* swreg5 is decoded from the vendor's KICK word, which carries the
         * |1 start bit the builder writes separately. */
        if ((sw1[5 - 1] | 1u) != want[5]) {
            printf("FAIL %s swreg5 want=0x%08x got=0x%08x\n",
                   VFQ[v].tag, want[5], sw1[5 - 1] | 1u);
            fails++;
        }
        for (int r = 1; r <= ENC_BULK_NREGS; r++) {
            if (r == 5 || is_addr_reg(r) || fixqp_residual(r, VFQ[v].is_p))
                continue;
            if (sw1[r - 1] != want[r]) {
                printf("FAIL %s swreg%d want=0x%08x got=0x%08x\n",
                       VFQ[v].tag, r, want[r], sw1[r - 1]);
                fails++;
                diffs++;
            }
        }
        total += diffs;
    }
    printf("fixqp identity: %u vendor programs, %d non-address diffs\n",
           (unsigned)(sizeof VFQ / sizeof VFQ[0]), total);
}

/*
 * 4. HEVC IDENTITY (#64): with codec = ENC_CODEC_HEVC and ENC_RC_FIXQP the
 *    builder must reproduce the VENDOR's H.265 fixed-QP programs -- the 1080p
 *    ladder and fixed-QP32 at six more geometries up to 3840x2400 -- bar the
 *    address registers and the same two residuals as fixqp_identity()
 *    (sw9: our fixed header slot vs the vendor's VPS+SPS+PPS length; P-frame
 *    sw105: per-frame RC state).
 */
static void hevc_identity(void)
{
    static uint32_t buf[ENC_CMDBUF_WORDS];
    static uint32_t want[ENC_BULK_NREGS + 1];
    int total = 0;

    for (unsigned v = 0; v < sizeof VHQ / sizeof VHQ[0]; v++) {
        vcenc_geom g;
        if (vcenc_geom_build(&g, VHQ[v].w, VHQ[v].h)) {
            printf("FAIL %s: %dx%d rejected\n", VHQ[v].tag, VHQ[v].w, VHQ[v].h);
            fails++;
            continue;
        }
        struct vcenc_frame fr = {
            .frame_num   = VHQ[v].is_p ? 1u : 0u,
            .qp          = VHQ[v].qp,
            .rc_mode     = ENC_RC_FIXQP,
            .codec       = ENC_CODEC_HEVC,
            .pic_init_qp = VHQ[v].pic_init_qp,
        };
        if (vcenc_build_encode_cmdbuf(buf, 0x70000000u, &g, 0, &fr)
            != ENC_CMDBUF_BYTES) {
            printf("FAIL %s: builder rejected qp %u\n", VHQ[v].tag, VHQ[v].qp);
            fails++;
            continue;
        }
        memset(want, 0, sizeof want);
        for (unsigned k = 0; k < VHQ[v].n; k++)
            want[VHQ[v].regs[k].reg] = VHQ[v].regs[k].val;

        const uint32_t *sw1 = buf + 5;
        int diffs = 0;
        if ((sw1[5 - 1] | 1u) != want[5]) {
            printf("FAIL %s swreg5 want=0x%08x got=0x%08x\n",
                   VHQ[v].tag, want[5], sw1[5 - 1] | 1u);
            fails++;
        }
        for (int r = 1; r <= ENC_BULK_NREGS; r++) {
            if (r == 5 || is_addr_reg(r) || fixqp_residual(r, VHQ[v].is_p))
                continue;
            if (sw1[r - 1] != want[r]) {
                printf("FAIL %s swreg%d want=0x%08x got=0x%08x\n",
                       VHQ[v].tag, r, want[r], sw1[r - 1]);
                fails++;
                diffs++;
            }
        }
        total += diffs;
    }
    printf("hevc identity: %u vendor programs, %d non-address diffs\n",
           (unsigned)(sizeof VHQ / sizeof VHQ[0]), total);
}

/* The QP block must saturate exactly where the vendor's does. */
static void qp_clamp(void)
{
    uint32_t a[8], b[8], s37a, s37b, q;
    for (uint32_t qp = 36; qp <= 51; qp++) {
        vcenc_qp_regs(36, 0, &q, &s37a, a);
        vcenc_qp_regs(qp, 0, &q, &s37b, b);
        if (s37a != s37b || memcmp(a, b, sizeof a)) {
            printf("FAIL I QP%u block != QP36 block\n", qp);
            fails++;
        }
    }
    for (uint32_t qp = 35; qp <= 51; qp++) {
        vcenc_qp_regs(35, 1, &q, &s37a, a);
        vcenc_qp_regs(qp, 1, &q, &s37b, b);
        if (s37a != s37b || memcmp(a, b, sizeof a)) {
            printf("FAIL P QP%u block != QP35 block\n", qp);
            fails++;
        }
    }
    if (!vcenc_qp_regs(15, 0, &q, &s37a, a)
        || !vcenc_qp_regs(52, 0, &q, &s37a, a)) {
        printf("FAIL QP range check accepted an out-of-range QP\n");
        fails++;
    }
    printf("qp tables: clamp + range checked\n");
}

int main(void)
{
    golden();
    template_identity();
    fixqp_identity();
    hevc_identity();
    qp_clamp();
    envelope();
    if (fails) {
        printf("RESULT: FAIL (%d)\n", fails);
        return 1;
    }
    printf("RESULT: PASS\n");
    return 0;
}
