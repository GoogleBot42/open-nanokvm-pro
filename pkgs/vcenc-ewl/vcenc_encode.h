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
#include "img_qp32_payload.h"

#define ENC_CMDBUF_WORDS   570
#define ENC_CMDBUF_BYTES   (ENC_CMDBUF_WORDS * 4)   /* 0x8e8 */
#define ENC_BULK_NREGS     511
#define ENC_SECBANK_2800   0x44u

/* Captured-layout geometry, shared by every open-EWL consumer (the ewl_encode
 * test tool and libkvm's KVM_OPEN_VENC backend). The whole captured buffer
 * layout is allocated as ONE block and every address register relocated by
 * (block_bus - ENC_LAYOUT_BASE); the sub-page offsets in swreg8/10 survive
 * because both the allocator and the captured bases are page-aligned. */
#define ENC_LAYOUT_BASE   0x73c45000u  /* min captured address reg (sw12) */
#define ENC_LAYOUT_SPAN   0x02b00000u  /* to max reg base (sw27) + 4MB slack */
#define ENC_OUT_PAGE_OFF  ((0x749ce028u & ~0xfffu) - ENC_LAYOUT_BASE) /* sw8 page */
#define ENC_STREAM_SUBOFF (0x749ce028u & 0xfffu)  /* HW start code in that page */
#define ENC_OUT_LIMIT     0x004047d8u  /* programmed swreg9 output byte limit */
#define ENC_WIDTH         1920u        /* the register program is 1080p-only */
#define ENC_HEIGHT        1080u
#define ENC_QP_FIXED      32u          /* the img_qp32 program's sw7 QP */

/* Frame-type register values (captured; see header comment). */
#define ENC_SW5_IDR        0x3c044302u
#define ENC_SW5_P          0x3c044300u
#define ENC_SW17_P         0xffd0007cu   /* keeps the 0x30 format bits */
#define ENC_SW170_P        0x00199a00u
#define ENC_SW171_P        0x00287a00u
#define ENC_SW173_P        0x0000066au
#define ENC_SW191_P        0x04000000u
#define ENC_SW193_P        0x00200119u

/* Per-run DMA address registers to relocate. All are addresses EXCEPT
 * swreg9 (output byte-limit, kept as-is). Zero-valued entries (the
 * reference regs at an IDR) are left at 0. */
static const int ENC_KEEP_ADDR[] = {8,10,12,13,14,15,16,18,19,27,46,
				    60,62,64,66,72,74,114,239,241};
#define ENC_KEEP_ADDR_N ((int)(sizeof(ENC_KEEP_ADDR)/sizeof(ENC_KEEP_ADDR[0])))

/* Double-buffered per-frame banks (captured-layout addresses; relocated with
 * everything else). Bank A = what the frame-0 img_qp32 program uses. */
struct enc_ppreg { int cur, ref; uint32_t a, b; };
static const struct enc_ppreg ENC_PP[] = {
	{ 15, 18, 0x74de5000u, 0x75003000u },  /* recon luma */
	{ 16, 19, 0x75221000u, 0x75320000u },  /* recon chroma */
	{ 60, 64, 0x75429000u, 0x7542f000u },  /* aux recon (compressed-ref class) */
	{ 62, 66, 0x7542a000u, 0x75430000u },
	{ 72, 74, 0x74fe3000u, 0x75201000u },  /* aux (colmv class) */
};
#define ENC_PP_N ((int)(sizeof(ENC_PP)/sizeof(ENC_PP[0])))
#define ENC_SW114_A 0x75435000u
#define ENC_SW114_B 0x75436000u
#define ENC_SW239_EVEN 0x75427000u  /* 241 = previous frame's 239 */
#define ENC_SW239_ODD  0x75425000u

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
	uint32_t input_phys; /* 0 => the relocated layout's own input region;
	                      * else an absolute bus address of a packed-YUYV
	                      * 1080p frame (e.g. straight out of the capture
	                      * pool -- zero-copy). Page alignment not required;
	                      * sw13/14 keep their captured relative offsets. */
};

/*
 * Build one frame's encode cmdbuf into `buf`.
 *   buf            : cmdbuf slot (cmd_pool + id*0x2000), >= 0x8e8 bytes
 *   delta          : added to every nonzero ENC_KEEP_ADDR register
 *                    (page-aligned, preserving sub-page offsets in swreg8/10)
 *   core_status_dst: hw/bus addr where the RREG(512,0x1000) readback lands
 *   fr             : frame parameters (frame_num selects IDR/P + bank parity)
 * Returns the cmdbuf byte size, or 0 on unsupported parameters.
 */
static inline uint16_t vcenc_build_encode_cmdbuf(uint32_t *buf, uint32_t delta,
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

	/* frame_num / POC (slice-header inputs; u(16) in our SPS) */
	sw1[11 - 1]  = fr->frame_num & 0xffffu;
	sw1[192 - 1] = fr->frame_num & 0xffffu;

	if (!is_idr) {
		/* frame-type constants */
		sw1[5 - 1]   = ENC_SW5_P;
		sw1[17 - 1]  = fr->p17 ? fr->p17 : ENC_SW17_P;
		sw1[170 - 1] = ENC_SW170_P;
		sw1[171 - 1] = ENC_SW171_P;
		sw1[173 - 1] = ENC_SW173_P;
		sw1[191 - 1] = ENC_SW191_P;
		sw1[193 - 1] = ENC_SW193_P;
		/* current/reference bank selection */
		for (i = 0; i < ENC_PP_N; i++) {
			sw1[ENC_PP[i].cur - 1] = parity ? ENC_PP[i].b : ENC_PP[i].a;
			sw1[ENC_PP[i].ref - 1] = parity ? ENC_PP[i].a : ENC_PP[i].b;
		}
		if (fr->pinter)
			for (i = 0; i < ENC_PINTER_N; i++)
				sw1[ENC_PINTER[i].reg - 1] = ENC_PINTER[i].val;
	}
	/* per-frame scratch + swapped pair (also alternate at IDR parity) */
	sw1[114 - 1] = parity ? ENC_SW114_B : ENC_SW114_A;
	sw1[239 - 1] = parity ? ENC_SW239_ODD  : ENC_SW239_EVEN;
	sw1[241 - 1] = parity ? ENC_SW239_EVEN : ENC_SW239_ODD;

	/* relocate the nonzero address registers */
	for (i = 0; i < ENC_KEEP_ADDR_N; i++) {
		int k = ENC_KEEP_ADDR[i];
		if (sw1[k - 1])
			sw1[k - 1] += delta;
	}

	/* external input frame: absolute bus address, sw13/14 mirroring the
	 * captured relative offsets (sw13-sw12 = 2*W*H exactly, sw14 = sw13 +
	 * W*H; packed YUYV ignores the chroma bases but the regs must be sane) */
	if (fr->input_phys) {
		sw1[12 - 1] = fr->input_phys;
		sw1[13 - 1] = fr->input_phys + 0x3f4800u;
		sw1[14 - 1] = fr->input_phys + 0x3f4800u + 0x1fa400u;
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
