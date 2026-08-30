// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * vcenc_geom.h -- parametric geometry for the open VC8000E encode path (#17).
 *
 * The fixed-QP register program (img_qp32_payload.h) was captured at 1080p.
 * Every geometry-dependent register in it obeys a closed-form law in (W,H),
 * derived by differential observation of the VENDOR encoder driven at 17
 * distinct geometries on the real device (2026-08-31; the probe harness and
 * per-register fits live in docs/reference/vcenc-open/geom-probe/). At
 * 1920x1080 every law below reproduces the device-proven template value
 * EXACTLY, so the builder applies them unconditionally -- no 1080p special
 * case. vcenc_geom_test.c pins all 17 probed geometries as golden vectors.
 *
 * The captured-layout relocation (one block mirroring the vendor's 1080p
 * buffer addresses) is replaced by a COMPUTED floorplan: every DMA buffer the
 * program references gets a page-aligned offset in one framebuf block, sized
 * by the vendor's own per-geometry allocation laws (or a proven upper bound
 * where the vendor's packing rule did not fit a closed form; over-sizing is
 * always safe -- the vendor packs the next buffer at the pitch, so the HW
 * write extent is <= pitch).
 *
 * Field semantics worth naming (all device-derived, no vendor code):
 *   sw5   [31:20] align16(W)/2, [19:8] align16(H)+3, [1:0] frame-type bits
 *   sw9   output byte limit = 2*W*H + 0xffd8
 *   sw38  0x20000000 | (W*64 + ((16-W%16)%8)*8 + ((16-H%16)%8)*2)
 *   sw134 0x0a000000 | floor(2^28 / (Wp*Hp))            (padded recon dims)
 *   sw193 template | 0x40 if align16(W)-W >= 8 | 0x10 if align16(H)-H >= 8
 *   sw210 (W/16)<<16 | (W%16)<<12 | 0xff8               (whole + partial MBs)
 *   sw212/213/237 hi16 = ceil(mbw/4)*16                 (4-MB row pitch /4)
 *   sw245 0x20000000 | round(2^16/mbw)*4
 *   sw246 round(2^18/mbw)<<14 | 0x1028
 *   sw261 hi16 = align16(W) (the CODED width; the input is read at lines of
 *         the TRUE width W -- proven by the 1366 shear experiment)
 * Recon buffer laws: width padded to 4 MBs (Wp), height to 64 (Hp);
 *   luma pitch = Wp*Hp + align4k(WpHp/256*16)  (16 B per padded MB tail)
 *   chroma pitch = align4k(Wp*Hp/2)
 *   sw62 = sw60 + align64(Wp/16*Hp/16/2); sw239 pitch = align4k(padded MBs)
 */
#ifndef VCENC_GEOM_H
#define VCENC_GEOM_H

#include <stdint.h>

#define VCENC_GEOM_MIN_W 64
#define VCENC_GEOM_MIN_H 64
#define VCENC_GEOM_MAX_W 1920
#define VCENC_GEOM_MAX_H 1200

typedef struct {
	uint32_t w, h;          /* true source size (even, envelope-checked) */
	uint32_t mbw, mbh;      /* ceil(w/16), ceil(h/16) */
	uint32_t stride;        /* input line stride, PIXELS == w (the HW reads
	                         * lines packed at the true width -- proven by the
	                         * 1366 shear experiment; == the capture stride) */
	uint32_t wp, hp;        /* recon dims: 4-MB-padded width, 64-padded h */

	/* geometry-class register values (frame-type bits NOT included in sw5;
	 * sw193 given per frame type) */
	uint32_t sw5, sw9, sw38, sw134, sw193_idr, sw193_p;
	uint32_t sw210, sw212, sw213, sw237, sw245, sw246, sw261;
	uint32_t targetpicsize; /* sw105..107: QP32 anchor scaled by pixels */

	/* computed floorplan: byte offsets from the framebuf block base.
	 * Sub-page offsets that the device-proven program carries (sw8 +0x28,
	 * sw10 +0x8, sw27 +0x300) are applied by the builder, not stored here. */
	uint32_t off_out;                    /* stream output (sw8)            */
	uint32_t off_s10;                    /* sw10 side buffer               */
	uint32_t off_in;                     /* fallback input (prover only)   */
	uint32_t off_luma[2], off_chroma[2]; /* recon banks A/B (sw15/16/18/19)*/
	uint32_t off_s46;
	uint32_t off_s72[2];                 /* colmv class banks (luma pitch) */
	uint32_t off_s60[2];                 /* aux banks; sw62 = sw60 + s62off*/
	uint32_t s62off;
	uint32_t off_s239[2];                /* even/odd swap pair (sw239/241) */
	uint32_t off_s114[2];
	uint32_t off_s27;
	uint32_t span;                       /* total framebuf block size      */
	uint32_t out_limit;                  /* == sw9 */
} vcenc_geom;

static inline uint32_t vcg_align(uint32_t v, uint32_t a)
{
	return (v + a - 1) / a * a;
}

/* 0 if the open encoder can drive (w,h); -1 with *why otherwise. */
static inline int vcenc_geom_check(int w, int h, const char **why)
{
	const char *r = 0;
	if (w < VCENC_GEOM_MIN_W || h < VCENC_GEOM_MIN_H)
		r = "below 64x64 minimum";
	else if (w > VCENC_GEOM_MAX_W || h > VCENC_GEOM_MAX_H)
		r = "above 1920x1200 envelope";
	else if ((w | h) & 1)
		r = "odd width/height (YUYV macropixel)";
	if (why)
		*why = r;
	return r ? -1 : 0;
}

static inline int vcenc_geom_build(vcenc_geom *g, int w, int h)
{
	if (vcenc_geom_check(w, h, 0))
		return -1;
	uint32_t W = (uint32_t)w, H = (uint32_t)h;
	uint32_t mbw = (W + 15) / 16, mbh = (H + 15) / 16;
	uint32_t w4 = vcg_align(mbw, 4);          /* recon width in MBs */
	uint32_t wp = w4 * 16, hp = vcg_align(H, 64), mbhp = hp / 16;
	uint32_t p4 = vcg_align(mbw, 4) * 4;      /* sw212/213/237 hi field */

	g->w = W; g->h = H; g->mbw = mbw; g->mbh = mbh;
	g->stride = W;
	g->wp = wp; g->hp = hp;

	g->sw5   = ((mbw * 16 / 2) << 20) | ((mbh * 16 + 3) << 8);
	g->out_limit = 2 * W * H + 0xffd8;
	g->sw9   = g->out_limit;
	g->sw38  = 0x20000000u | (W * 64 + ((16 - W % 16) % 8) * 8
	                                 + ((16 - H % 16) % 8) * 2);
	g->sw134 = 0x0a000000u | (0x10000000u / (wp * hp));
	g->sw193_idr = 0x0010010du;
	g->sw193_p   = 0x00200109u;
	if (mbw * 16 - W >= 8) { g->sw193_idr |= 0x40; g->sw193_p |= 0x40; }
	if (mbh * 16 - H >= 8) { g->sw193_idr |= 0x10; g->sw193_p |= 0x10; }
	g->sw210 = ((W / 16) << 16) | ((W % 16) << 12) | 0xff8;
	g->sw212 = (p4 << 16) | 0x0ff8;
	g->sw213 = (p4 << 16) | 0x3fe0;
	g->sw237 = (p4 << 16) | 0x0044;
	g->sw245 = 0x20000000u | (((2 * 0x10000u / mbw + 1) / 2) * 4);
	g->sw246 = (((2 * 0x40000u / mbw + 1) / 2) << 14) | 0x1028;
	g->sw261 = ((mbw * 16) << 16) | 0x0400;
	/* QP32/8Mbps TARGETPICSIZE anchor (1760000 at 1080p), pixel-scaled */
	g->targetpicsize =
	    (uint32_t)(1760000ull * W * H / (1920ull * 1080ull));

	/* floorplan (page-aligned; sizes are vendor allocation laws, or a
	 * proven upper bound where noted) */
	uint32_t lupitch = wp * hp + vcg_align(w4 * mbhp * 16, 4096);
	uint32_t chpitch = vcg_align(wp * hp / 2, 4096);
	uint32_t s60sz   = vcg_align(w4 * mbhp * 4, 4096);  /* bound: >= vendor */
	uint32_t s239sz  = vcg_align(w4 * mbhp, 4096);
	uint32_t s114sz  = vcg_align(mbhp * 64, 4096);
	uint32_t s10sz   = vcg_align(W * H / 8, 4096);      /* bound: >= vendor */
	uint32_t o = 0;
	g->off_out = o;       o += vcg_align(g->out_limit + 0x1000, 4096);
	g->off_s10 = o;       o += s10sz;
	g->off_in = o;        o += vcg_align(4 * W * H, 4096);
	g->off_luma[0] = o;   o += lupitch;
	g->off_luma[1] = o;   o += lupitch;
	g->off_chroma[0] = o; o += chpitch;
	g->off_chroma[1] = o; o += chpitch;
	g->off_s46 = o;       o += 0x12000;
	g->off_s72[0] = o;    o += lupitch;
	g->off_s72[1] = o;    o += lupitch;
	g->off_s60[0] = o;    o += s60sz;
	g->off_s60[1] = o;    o += s60sz;
	g->s62off = vcg_align(w4 * mbhp / 2, 64);
	g->off_s239[0] = o;   o += s239sz;
	g->off_s239[1] = o;   o += s239sz;
	g->off_s114[0] = o;   o += s114sz;
	g->off_s114[1] = o;   o += s114sz;
	g->off_s27 = o;       o += 0x10000;
	g->span = o + 0x4000;
	return 0;
}

/* level_idc: smallest H.264 level fitting the MB count at 60 fps. */
static inline uint32_t vcenc_level_idc(uint32_t mbw, uint32_t mbh)
{
	static const struct { uint32_t fs, mbps, idc; } lvl[] = {
		{ 1620,  40500, 30 }, { 1620, 108000, 31 }, { 3600, 216000, 32 },
		{ 5120, 245760, 40 }, { 8192, 245760, 40 }, { 8704, 522240, 42 },
		{ 22080, 589824, 50 }, { 36864, 983040, 51 },
	};
	uint32_t fs = mbw * mbh, mbps = fs * 60;
	for (unsigned i = 0; i < sizeof lvl / sizeof lvl[0]; i++)
		if (fs <= lvl[i].fs && mbps <= lvl[i].mbps)
			return lvl[i].idc;
	return 51;
}

#endif /* VCENC_GEOM_H */
