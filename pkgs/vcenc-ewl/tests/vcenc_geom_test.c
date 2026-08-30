// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * vcenc_geom_test -- the geometry-law proof for the open encoder (#17).
 *
 * Two properties, both host-checkable:
 *
 * 1. GOLDEN VECTORS: for every one of the 17 geometries the VENDOR encoder
 *    was driven at on the real device (2026-08-31 differential probe), our
 *    vcenc_geom laws must reproduce the vendor's programmed register values
 *    and buffer pitches exactly (vcenc_geom_vectors.h is auto-generated from
 *    the decoded cmdbuf WREG programs -- no transcription).
 *
 * 2. TEMPLATE IDENTITY: at 1920x1080 the full cmdbuf builder must reproduce
 *    the device-proven img_qp32 register program bit-for-bit for every
 *    register EXCEPT the DMA addresses (which moved from the relocated
 *    captured layout to the computed floorplan -- coded bits provably do not
 *    depend on buffer placement, and the on-device NAL regression covers it).
 */
#include <stdio.h>
#include <string.h>
#include "../vcenc_encode.h"
#include "vcenc_geom_vectors.h"

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
    struct vcenc_frame fr = { .frame_num = 0, .qp = 32 };
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
        { 1922, 1080, 0 }, { 1920, 1202, 0 }, { 62, 64, 0 },
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

int main(void)
{
    golden();
    template_identity();
    envelope();
    if (fails) {
        printf("RESULT: FAIL (%d)\n", fails);
        return 1;
    }
    printf("RESULT: PASS\n");
    return 0;
}
