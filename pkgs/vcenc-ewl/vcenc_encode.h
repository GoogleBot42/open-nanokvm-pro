/* SPDX-License-Identifier: GPL-2.0 OR MIT */
/*
 * Per-frame VC8000E fixed-QP command-buffer builder (#25: IDR + P frames).
 *
 * Reproduces the exact opcode structure of the device-captured IDR cmdbuf
 * (docs/reference/vcenc-open/stage1/slot8k.bin, 570 words = 0x8e8 bytes),
 * carrying the committed fixed-QP register program (img_qp32_payload.h,
 * swreg1..511) with the per-run ADDRESS registers relocated by a
 * caller-supplied delta and, for P frames, a register overlay derived from
 * our own Stage-0 7-frame ring capture (docs/reference/vcenc-open/stage0/,
 * regimg_P_m0..m6 reordered by swreg11):
 *
 *  - frame-type constants: swreg5 (0x3c044302 IDR / 0x3c044300 P, kick =
 *    value|1), swreg191 (0x14000000 / 0x04000000), swreg193 (0x0010011d
 *    first-IDR / 0x00200119 P), swreg17 (0x30 first-IDR / 0xffd0007c P),
 *    swreg170/171/173 (per-type constants, identical across the CBR and
 *    fixed-QP captures at like frames, so type- not RC-dependent).
 *  - swreg11 and swreg192 carry frame_num (0 at IDR, +1 per frame; the HW
 *    writes slice-header frame_num and pic_order_cnt_lsb from these; both
 *    u(16) in our SPS, so wrap at 0xffff).
 *  - double-buffered per-frame DMA banks, parity = frame_num & 1 (bank A is
 *    what the frame-0 img_qp32 program uses): current recon swreg15/16,
 *    reference (L0[0]) swreg18/19 = the OTHER bank = previous frame's recon;
 *    same discipline for the aux pairs 60/62 vs 64/66 (compressed-ref class)
 *    and 72 vs 74 (colmv class); swreg114 scratch alternates; the
 *    swreg239/241 pair swaps each frame (241 = previous frame's 239).
 *    At an IDR the reference regs stay 0 (img_qp32 default, device-proven).
 *  - everything the fixed-QP program zeroes stays ZERO for P too: the CBR
 *    run's lambda LUTs (215-223), bit-budget state (183, 243/244/247/248,
 *    318), and warmed-up inter state (111-113, 197/198) are all 0 in
 *    img_qp32 and the IDR encodes fine that way; `pinter` optionally
 *    replays the captured values of the last cluster as a fallback knob.
 *
 * QP and rate control. The captured program is a QP32 CBR program; the two
 * knobs that ride on it are now explicit per frame:
 *
 *  - fr->qp (16..51) programs the QP block (sw7 low field, sw37, sw125..132)
 *    from the vendor-mined tables in vcenc_qp.h.
 *  - fr->rc_mode picks WHICH register set carries it:
 *      ENC_RC_LEGACY  the shipping, device-proven program. The CBR cluster
 *                     (sw6[0], sw22, sw105..107 target, sw172/173, sw245/246,
 *                     the sw239/241 RC buffers) stays exactly as captured, and
 *                     the QP block is programmed from the I-frame table for
 *                     BOTH frame types -- which is what the captured IDR
 *                     program does when it is replayed on a P frame. At qp 32
 *                     the output is bit-identical to the pre-#46 builder.
 *      ENC_RC_FIXQP   the VENDOR's true fixed-QP program (E1 regdiff,
 *                     AX_VENC_RC_MODE_H264FIXQP): RC off in nine registers,
 *                     the RC buffers unallocated, and the QP block programmed
 *                     from the per-frame-type tables. tests/vcenc_geom_test.c
 *                     diffs this against the vendor's own 1080p ladder
 *                     programs at QP 16..51; only sw9 (our fixed 40-byte
 *                     header slot) and the P frame's sw105 (per-frame RC bit
 *                     state the HW rewrites) differ.
 *
 * Cmdbuf layout (word indices), driver LINK-patch sites per vcenc_cmdbuf.h:
 *   0        RREG(1,0x68)                 head; driver patches [1],[2]
 *   1..3     0,0, pad
 *   4        WREG(511,0x1004)             bulk swreg1..511 opcode
 *   5..515   swreg1..swreg511             the register program (see above)
 *   516..517 WREG(1,0x2800), 0x44         secondary-bank poke (undecoded, replayed)
 *   518..549 16x [WREG(1,0x2014+i*0x20),0] secondary-bank pokes (all 0)
 *   550..551 WREG(1,0x1014), KICK         swreg5|1 written LAST = the trigger
 *   552..553 STALL, 0                     wait-for-core
 *   554..557 RREG(512,0x1000), dstlo,dsthi,0  core reg readback -> caller status dst
 *   558..561 CLRINT 0x1014/~1, CLRINT 0x1004/~0
 *   562..565 RREG(27,0), 0,0, pad         tail; driver patches [563],[564]
 *   566..569 JMP|IE, 0,0,0                terminator; driver patches target
 */
#ifndef VCENC_ENCODE_H
#define VCENC_ENCODE_H

#include <stdint.h>
#include <string.h>
#include "vcmd_abi.h"
#include "vcenc_cmdbuf.h"
#include "vcenc_geom.h"
#include "vcenc_qp.h"
#include "img_qp32_payload.h"

#define ENC_CMDBUF_WORDS   570
#define ENC_CMDBUF_BYTES   (ENC_CMDBUF_WORDS * 4)   /* 0x8e8 */
#define ENC_BULK_NREGS     511
#define ENC_SECBANK_2800   0x44u

/* The buffer layout is a COMPUTED floorplan (vcenc_geom.h) in one framebuf
 * block; every address register is written as block_base + geom offset. The
 * device-proven program carries three sub-page offsets, preserved here. */
#define ENC_STREAM_SUBOFF 0x028u       /* sw8: HW start code in the out page */
#define ENC_S10_SUBOFF    0x008u       /* sw10 side-buffer write pointer     */
#define ENC_S27_SUBOFF    0x300u       /* sw27 (captured; content-zero OK)   */
#define ENC_QP_FIXED      32u          /* the img_qp32 program's sw7 QP */

/* Rate-control mode (fr->rc_mode). */
#define ENC_RC_LEGACY     0u   /* shipping program: CBR cluster as captured */
#define ENC_RC_FIXQP      1u   /* the vendor's AX_VENC_RC_MODE_H264FIXQP set */

/* Codec (fr->codec). ENC_CODEC_HEVC applies the H.265 overlay measured by the
 * 2026-09-05 vendor HEVC campaign (docs/reference/vcenc-open/
 * vendor-diff-hevc-20260905/REPORT.md, H1/H2/H3): the same cmdbuf, the same
 * floorplan and the same RC/QP laws, with 17 registers re-pinned at the IDR
 * (29 at a P frame) and three geometry laws switched from macroblock to
 * min-CB/CTB granularity. Fixed-QP HEVC at 1080p reproduces the vendor's
 * fixed-QP32 IDR and P programs bar the address registers (tests). */
#define ENC_CODEC_H264    0u
#define ENC_CODEC_HEVC    1u
#define ENC_HEVC_SW4      0x21900054u
#define ENC_HEVC_SW6      0x00200000u  /* bit21: every HEVC program */
#define ENC_HEVC_SW6_INTRA 0x00000008u /* bit3: intra picture */
#define ENC_HEVC_SW36     0x1c995f14u
#define ENC_HEVC_SW191_IDR 0x4c000000u
#define ENC_HEVC_SW193    0x00100101u  /* no CABAC/8x8/partial-MB bits */
#define ENC_HEVC_SW194    0x00100100u
#define ENC_HEVC_SW208    0x79e01ff0u
#define ENC_HEVC_SW277    0x83000000u
#define ENC_HEVC_SW170_P  0x00333300u
#define ENC_HEVC_SW171_P  0x00393e00u
/* sw202..207: constant HEVC block (write-only per H7; CU/TU cost thresholds) */
static const uint32_t ENC_HEVC_SW202[6] = {
	0x00020002u, 0x00020002u, 0x00020002u, 0x000c0003u, 0x0033000cu, 0x00cc0033u,
};

/* The nine registers the vendor changes when rate control is switched OFF
 * (docs/reference/vcenc-open/vendor-diff-20260904/E1/regdiff_{IDR,P}.md);
 * sw239/sw241 (the RC buffers) additionally go to 0 -- and so, on a P frame,
 * do sw243/sw247, which this builder never sets. */
#define ENC_FIXQP_SW6_MASK  (~1u)      /* sw6 bit0 = RC enable */
#define ENC_FIXQP_SW22      0x00000000u
#define ENC_FIXQP_SW105     15000u     /* 0x3a98, constant at every geometry */
#define ENC_FIXQP_SW172     0x0000000fu /* minQp field cleared */
#define ENC_FIXQP_SW173     0x0000066au /* bit3 set */
#define ENC_FIXQP_SW245     0x00000000u
#define ENC_FIXQP_SW246     0x00001000u
/* P-frame inter state the vendor programs in EVERY P program of the ladder
 * (constant across QP 16..51). ENC_RC_LEGACY leaves these 0 because the
 * shipping, device-proven program does. */
#define ENC_FIXQP_SW197_P   0xffc00000u
#define ENC_FIXQP_SW198_P   0x00000e00u

/* Frame-type register values (captured; see header comment). swreg5 itself
 * is geometry-dependent (vcenc_geom.sw5) with type bits |0x02 IDR / |0 P. */
#define ENC_SW17_P         0xffd0007cu   /* keeps the 0x30 format bits */
#define ENC_SW170_P        0x00199a00u
#define ENC_SW171_P        0x00287a00u
#define ENC_SW173_P        0x0000066au
#define ENC_SW191_P        0x04000000u
#define ENC_SW193_P        0x00200119u

/* Optional warmed-up inter-state fallback (captured f1 values; off by
 * default -- the fixed-QP program zeroes these and the primary hypothesis
 * is that they are adaptive state, not P-structural). */
static const struct { int reg; uint32_t val; } ENC_PINTER[] = {
	{ 111, 0x00a8c000u }, { 112, 0x06018000u }, { 113, 0x00011ae7u },
	{ 197, 0xffc00000u }, { 198, 0x00000e00u },
};
#define ENC_PINTER_N ((int)(sizeof(ENC_PINTER)/sizeof(ENC_PINTER[0])))

struct vcenc_frame {
	uint32_t frame_num;  /* within the GOP; 0 => IDR */
	uint32_t qp;         /* frame QP, VCENC_QP_MIN..VCENC_QP_MAX */
	uint32_t rc_mode;    /* ENC_RC_LEGACY (default) or ENC_RC_FIXQP */
	uint32_t codec;      /* ENC_CODEC_H264 (default) or ENC_CODEC_HEVC */
	uint32_t pic_init_qp;/* sw7 high field; 0 => same as qp (our PPS value) */
	uint32_t p17;        /* sw17 P value (0 => ENC_SW17_P) */
	int      pinter;     /* 1 => replay ENC_PINTER for P frames */
	uint32_t input_phys; /* 0 => the floorplan's own input region; else an
	                      * absolute bus address of a packed-YUYV frame at
	                      * the geom's size/stride (e.g. straight out of the
	                      * capture pool -- zero-copy). Page alignment not
	                      * required; sw13/14 = +2WH / +3WH. */
};

/*
 * Build one frame's encode cmdbuf into `buf`.
 *   buf            : cmdbuf slot (cmd_pool + id*0x2000), >= 0x8e8 bytes
 *   base           : bus address of the framebuf block holding g's floorplan
 *   g              : geometry (register laws + floorplan offsets)
 *   core_status_dst: hw/bus addr where the RREG(512,0x1000) readback lands
 *   fr             : frame parameters (frame_num selects IDR/P + bank parity)
 * Returns the cmdbuf byte size, or 0 on unsupported parameters.
 */
static inline uint16_t vcenc_build_encode_cmdbuf(uint32_t *buf, uint32_t base,
						 const vcenc_geom *g,
						 uint64_t core_status_dst,
						 const struct vcenc_frame *fr)
{
	int is_idr = (fr->frame_num == 0);
	uint32_t parity = fr->frame_num & 1;   /* 0 = bank A (img_qp32) */
	uint32_t *sw1;                          /* sw1[k-1] == swreg k */
	int i, w = 0;

	uint32_t sw7qp, sw37, blk[8];
	uint32_t init_qp = fr->pic_init_qp ? fr->pic_init_qp : fr->qp;
	/* ENC_RC_LEGACY keeps the captured program's habit of replaying the
	 * I-frame block on P frames; ENC_RC_FIXQP uses the vendor's per-type
	 * tables. */
	if (fr->codec == ENC_CODEC_HEVC) {
		/* H3: HEVC P frames index the I table at q = min(QP,35) (no -3)
		 * and carry four P-variant entries (F20 lo, F26 hi, F27 lo, F33 hi). */
		if (vcenc_qp_regs(fr->qp, 0, &sw7qp, &sw37, blk))
			return 0;
		if (!is_idr) {
			int q = vcenc_qp_index(fr->qp, 0);
			/* sw37 = L(q) carries F(2q-48).lo16: the P-variant F20 lo
			 * (0x0810) shows through at q = 34 (H3 I28/P34 run). */
			if (2 * q - 48 == 20)
				sw37 = (sw37 & 0xffff0000u) | 0x0810u;
			for (i = 0; i < 8; i++) {
				switch (q - 2 * i) {
				case 20: blk[i] = (blk[i] & 0xffff0000u) | 0x0810u; break;
				case 26: blk[i] = (blk[i] & 0x0000ffffu) | 0x04840000u; break;
				case 27: blk[i] = (blk[i] & 0xffff0000u) | 0x1210u; break;
				case 33: blk[i] = (blk[i] & 0x0000ffffu) | 0x0a200000u; break;
				default: break;
				}
			}
		}
	} else if (vcenc_qp_regs(fr->qp, fr->rc_mode == ENC_RC_FIXQP && !is_idr,
			  &sw7qp, &sw37, blk))
		return 0;
	if (init_qp > 51u)
		return 0;

	memset(buf, 0, ENC_CMDBUF_BYTES);

	/* head: RREG reg26 (driver patches dest words [1],[2]) */
	buf[w++] = RREG_HDR(1, VCMD_EXEC_ID_REG * 4); /* 0xB0010068 */
	buf[w++] = 0; buf[w++] = 0; buf[w++] = 0;     /* dstlo,dsthi(driver), pad */

	/* bulk WREG of swreg1..511 @ 0x1004 */
	buf[w++] = WREG_BURST(ENC_BULK_NREGS, SWREG_ADDR(1)); /* 0x09FF1004 */
	for (i = 0; i < ENC_BULK_NREGS; i++)
		buf[w++] = img_qp32[i];
	sw1 = buf + 5;

	/* geometry-law registers (identical to the template at 1920x1080;
	 * see vcenc_geom.h for the per-field derivations) */
	sw1[5 - 1]   = g->sw5 | 0x02u;         /* IDR type bits; kick adds |1 */
	sw1[9 - 1]   = g->sw9;
	sw1[38 - 1]  = g->sw38;
	sw1[105 - 1] = g->targetpicsize;
	sw1[106 - 1] = g->targetpicsize;
	sw1[107 - 1] = g->targetpicsize;
	sw1[134 - 1] = g->sw134;
	sw1[193 - 1] = g->sw193_idr;
	sw1[210 - 1] = g->sw210;
	sw1[212 - 1] = g->sw212;
	sw1[213 - 1] = g->sw213;
	sw1[237 - 1] = g->sw237;
	sw1[245 - 1] = g->sw245;
	sw1[246 - 1] = g->sw246;
	sw1[261 - 1] = g->sw261;

	/* QP block (vcenc_qp.h): sw7 = (pic_init_qp << 26) | (frame_qp << 8) */
	sw1[7 - 1] = ((init_qp & 0x3fu) << 26) | sw7qp;
	sw1[37 - 1] = sw37;
	for (i = 0; i < 8; i++)
		sw1[125 - 1 + i] = blk[i];

	/* frame_num / POC (slice-header inputs; u(16) in our SPS) */
	sw1[11 - 1]  = fr->frame_num & 0xffffu;
	sw1[192 - 1] = fr->frame_num & 0xffffu;

	/* DMA addresses from the computed floorplan */
	sw1[8 - 1]  = base + g->off_out + ENC_STREAM_SUBOFF;
	sw1[10 - 1] = base + g->off_s10 + ENC_S10_SUBOFF;
	sw1[27 - 1] = base + g->off_s27 + ENC_S27_SUBOFF;
	sw1[46 - 1] = base + g->off_s46;
	sw1[15 - 1] = base + g->off_luma[parity];
	sw1[16 - 1] = base + g->off_chroma[parity];
	sw1[60 - 1] = base + g->off_s60[parity];
	sw1[62 - 1] = base + g->off_s60[parity] + g->s62off;
	sw1[72 - 1] = base + g->off_s72[parity];
	sw1[114 - 1] = base + g->off_s114[parity];
	sw1[239 - 1] = base + g->off_s239[parity];
	sw1[241 - 1] = base + g->off_s239[!parity];

	if (!is_idr) {
		/* frame-type constants */
		sw1[5 - 1]   = g->sw5;         /* P type bits are 0 */
		sw1[17 - 1]  = fr->p17 ? fr->p17 : ENC_SW17_P;
		sw1[170 - 1] = ENC_SW170_P;
		sw1[171 - 1] = ENC_SW171_P;
		sw1[173 - 1] = ENC_SW173_P;
		sw1[191 - 1] = ENC_SW191_P;
		sw1[193 - 1] = g->sw193_p;
		/* reference (L0[0]) = the other bank = previous frame's recon;
		 * at an IDR these stay 0 (template default, device-proven) */
		sw1[18 - 1] = base + g->off_luma[!parity];
		sw1[19 - 1] = base + g->off_chroma[!parity];
		sw1[64 - 1] = base + g->off_s60[!parity];
		sw1[66 - 1] = base + g->off_s60[!parity] + g->s62off;
		sw1[74 - 1] = base + g->off_s72[!parity];
		if (fr->pinter)
			for (i = 0; i < ENC_PINTER_N; i++)
				sw1[ENC_PINTER[i].reg - 1] = ENC_PINTER[i].val;
	}

	/* input frame: external bus address (zero-copy from the capture pool)
	 * or the floorplan's own input region; sw13 = +2WH, sw14 = +3WH
	 * (packed YUYV ignores the chroma bases but the regs must be sane) */
	{
		uint32_t in = fr->input_phys ? fr->input_phys
		                             : base + g->off_in;
		sw1[12 - 1] = in;
		sw1[13 - 1] = in + 2u * g->w * g->h;
		sw1[14 - 1] = in + 3u * g->w * g->h;
	}

	/* Rate control OFF: the vendor's fixed-QP register set. Applied last so
	 * it overrides the geometry laws (sw105..107, sw245/246) and the
	 * floorplan's RC buffer addresses (sw239/241). */
	if (fr->rc_mode == ENC_RC_FIXQP) {
		sw1[6 - 1]  &= ENC_FIXQP_SW6_MASK;
		sw1[22 - 1]  = ENC_FIXQP_SW22;
		sw1[105 - 1] = ENC_FIXQP_SW105;
		sw1[106 - 1] = 0;
		sw1[107 - 1] = 0;
		sw1[172 - 1] = ENC_FIXQP_SW172;
		sw1[173 - 1] = ENC_FIXQP_SW173;
		sw1[239 - 1] = 0;
		sw1[241 - 1] = 0;
		sw1[245 - 1] = ENC_FIXQP_SW245;
		sw1[246 - 1] = ENC_FIXQP_SW246;
		if (!is_idr) {
			sw1[197 - 1] = ENC_FIXQP_SW197_P;
			sw1[198 - 1] = ENC_FIXQP_SW198_P;
		}
	}

	/* H.265 overlay (vendor-diff-hevc-20260905 H1/H2/H3/H6): applied last
	 * so it wins over the H.264 frame-type constants and geometry laws. */
	if (fr->codec == ENC_CODEC_HEVC) {
		uint32_t w8 = (g->w + 7) & ~7u, h8 = (g->h + 7) & ~7u;
		uint32_t ctbw = (g->w + 63) / 64;
		sw1[4 - 1]   = ENC_HEVC_SW4;
		/* sw5: min-CB (8) aligned dims, no +3; type bits as H.264 */
		sw1[5 - 1]   = ((w8 / 2) << 20) | (h8 << 8) | (is_idr ? 0x02u : 0u);
		sw1[6 - 1]  |= ENC_HEVC_SW6 | (is_idr ? ENC_HEVC_SW6_INTRA : 0u);
		sw1[36 - 1]  = ENC_HEVC_SW36;
		sw1[114 - 1] = 0;                       /* unused in HEVC */
		sw1[190 - 1] = 0;
		sw1[191 - 1] = is_idr ? ENC_HEVC_SW191_IDR : ENC_SW191_P;
		sw1[193 - 1] = ENC_HEVC_SW193;
		sw1[194 - 1] = ENC_HEVC_SW194;
		for (i = 0; i < 6; i++)
			sw1[202 - 1 + i] = ENC_HEVC_SW202[i];
		sw1[208 - 1] = ENC_HEVC_SW208;
		sw1[261 - 1] = (w8 << 16) | 0x0400u;    /* coded width = align8 */
		sw1[277 - 1] = ENC_HEVC_SW277;
		if (fr->rc_mode != ENC_RC_FIXQP) {      /* per-CTB-row RC coefficients */
			sw1[245 - 1] = 0x20000000u | (((2 * 0x10000u / ctbw + 1) / 2) * 4);
			sw1[246 - 1] = (((2 * 0x40000u / ctbw + 1) / 2) << 14) | 0x1010u;
		}
		if (!is_idr) {
			sw1[170 - 1] = ENC_HEVC_SW170_P;
			sw1[171 - 1] = ENC_HEVC_SW171_P;
			sw1[192 - 1] = 0;                   /* poc_lsb comes from sw11 */
			sw1[198 - 1] = 0;
		}
	}

	/* secondary bank @0x2800 = 0x44 (undecoded; replayed) */
	buf[w++] = WREG_BURST(1, 0x2800);
	buf[w++] = ENC_SECBANK_2800;
	/* secondary bank: 16x WREG(1, 0x2014 + i*0x20) = 0 */
	for (i = 0; i < 16; i++) {
		buf[w++] = WREG_BURST(1, 0x2014 + i * 0x20);
		buf[w++] = 0;
	}

	/* KICK: rewrite swreg5|1 @0x1014 LAST -> triggers the encode
	 * (captured IDR kick 0x3c044303 = bulk swreg5 | 1) */
	buf[w++] = WREG_BURST(1, SWREG_ADDR(5)); /* 0x08011014 */
	buf[w++] = sw1[5 - 1] | 1u;

	/* STALL (wait for core), 2 words */
	buf[w++] = STALL_WORD(1);
	buf[w++] = 0;

	/* core register readback: RREG(512,0x1000) -> caller status dst */
	buf[w++] = RREG_HDR(512, SUBMODULE_MAIN_ADDR); /* 0xB2001000 */
	buf[w++] = (uint32_t)core_status_dst;
	buf[w++] = (uint32_t)(core_status_dst >> 32);
	buf[w++] = 0; /* pad */

	/* CLRINT x2 (ack core interrupts) */
	buf[w++] = CLRINT_WORD(0x1014); buf[w++] = 0xfffffffe;
	buf[w++] = CLRINT_WORD(0x1004); buf[w++] = 0xffffffff;

	/* tail: RREG(27,0) (driver patches dest words [563],[564]) */
	buf[w++] = RREG_HDR(VCMD_TAIL_RREG_NUM, 0); /* 0xB01B0000 */
	buf[w++] = 0; buf[w++] = 0; buf[w++] = 0;    /* dstlo,dsthi(driver), pad */

	/* JMP terminator (IE set; driver patches target words [567..569]) */
	buf[w++] = JMP_TAIL_WORD; /* 0xCA000000 */
	buf[w++] = 0; buf[w++] = 0; buf[w++] = 0;

	/* must be exactly the captured length so the driver's tail patch lands. */
	return (uint16_t)ENC_CMDBUF_BYTES; /* w == 570 by construction */
}

#endif /* VCENC_ENCODE_H */
