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
 * QP: the register program is QP32-specific (sw7 + embedded cost tables),
 * so qp must be 32 until per-QP programs are derived (#46 seam: qp is
 * already a per-frame input here; gen_qp28..48.regs hold the evidence).
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
	uint32_t qp;         /* per-frame QP seam (#46); must be 32 for now */
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

	if (fr->qp != 32)
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
