/* SPDX-License-Identifier: GPL-2.0 OR MIT */
/*
 * Full VC8000E fixed-QP 1080p IDR command-buffer builder (#45 Stage B).
 *
 * Reproduces the exact opcode structure of the device-captured IDR cmdbuf
 * (docs/reference/vcenc-open/stage1/slot8k.bin, 570 words = 0x8e8 bytes),
 * carrying the committed fixed-QP register program (img_qp32_payload.h,
 * swreg1..511, byte-identical to that capture's bulk payload) with the 16
 * per-run ADDRESS registers relocated by a caller-supplied delta.
 *
 * Layout (word indices), with driver LINK-patch sites noted (see vcenc_cmdbuf.h):
 *   0        RREG(1,0x68)                 head; driver patches [1],[2]
 *   1..3     0,0, pad
 *   4        WREG(511,0x1004)             bulk swreg1..511 opcode
 *   5..515   swreg1..swreg511             the register program (addrs relocated)
 *   516..517 WREG(1,0x2800), 0x44         secondary-bank poke (undecoded, replayed)
 *   518..549 16x [WREG(1,0x2014+i*0x20),0] secondary-bank pokes (all 0)
 *   550..551 WREG(1,0x1014), KICK         swreg5 written LAST = the encode trigger
 *   552..553 STALL, 0                     wait-for-core
 *   554..557 RREG(512,0x1000), dstlo,dsthi,0  core reg readback -> caller status dst
 *   558..561 CLRINT 0x1014/~1, CLRINT 0x1004/~0
 *   562..565 RREG(27,0), 0,0, pad         tail; driver patches [563],[564]
 *   566..569 JMP|IE, 0,0,0                terminator; driver patches target
 *
 * The kick word uses the captured value 0x3c044303 (slot8k), which differs from
 * bulk swreg5 (0x3c044302) in an undecoded low nibble -- we replay the capture.
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
#define ENC_KICK_VALUE     0x3c044303u              /* slot8k captured kick */
#define ENC_SECBANK_2800   0x44u

/* The 16 per-run registers gen_hook.c preserves. All are DMA addresses to
 * relocate EXCEPT swreg9, which is the output byte-limit (kept as-is). */
static const int ENC_KEEP_ADDR[] = {8,10,12,13,14,15,16,27,46,60,62,72,114,239,241};
#define ENC_KEEP_ADDR_N ((int)(sizeof(ENC_KEEP_ADDR)/sizeof(ENC_KEEP_ADDR[0])))

/* swreg indices that carry an input/output/recon/aux DMA pointer (for the
 * caller to know which buffers to place). swreg9 excluded (it's a size). */

/*
 * Build the encode cmdbuf into `buf`.
 *   buf            : cmdbuf slot (cmd_pool + id*0x2000), >= 0x8e8 bytes
 *   delta          : added to every ENC_KEEP_ADDR register (page-aligned, so
 *                    the embedded sub-page offsets in swreg8/10 are preserved)
 *   core_status_dst: hw/bus addr where the RREG(512,0x1000) core readback lands
 *                    (read swreg9=NAL size back from here after WAIT)
 * Returns the cmdbuf byte size (ENC_CMDBUF_BYTES).
 */
static inline uint16_t vcenc_build_encode_cmdbuf(uint32_t *buf, uint32_t delta,
						 uint64_t core_status_dst)
{
	int i, w = 0;

	memset(buf, 0, ENC_CMDBUF_BYTES);

	/* head: RREG reg26 (driver patches dest words [1],[2]) */
	buf[w++] = RREG_HDR(1, VCMD_EXEC_ID_REG * 4); /* 0xB0010068 */
	buf[w++] = 0; buf[w++] = 0; buf[w++] = 0;     /* dstlo,dsthi(driver), pad */

	/* bulk WREG of swreg1..511 @ 0x1004 */
	buf[w++] = WREG_BURST(ENC_BULK_NREGS, SWREG_ADDR(1)); /* 0x09FF1004 */
	for (i = 0; i < ENC_BULK_NREGS; i++)
		buf[w++] = img_qp32[i];
	/* relocate the address registers in the just-copied payload */
	{
		uint32_t *sw1 = buf + 5; /* sw1[k-1] == swreg k */
		for (i = 0; i < ENC_KEEP_ADDR_N; i++) {
			int k = ENC_KEEP_ADDR[i];
			if (sw1[k - 1]) /* leave a zeroed (unused) pointer at 0 */
				sw1[k - 1] += delta;
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

	/* KICK: rewrite swreg5 @0x1014 LAST -> triggers the encode */
	buf[w++] = WREG_BURST(1, SWREG_ADDR(5)); /* 0x08011014 */
	buf[w++] = ENC_KICK_VALUE;

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
