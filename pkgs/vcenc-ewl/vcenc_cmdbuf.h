/* SPDX-License-Identifier: GPL-2.0 OR MIT */
/*
 * VCMD cmdbuf construction for the open VC8000E submitter.
 *
 * The open driver (vc8000_vcmd_driver.c) patches a fixed head and tail into
 * every cmdbuf at LINK time; userspace must lay the opcode stream out so those
 * patch sites land exactly where the driver writes. This header builds the
 * two shapes we need, matching the driver's own create_read_all_registers_cmdbuf
 * (drv:3396-3612) word-for-word so a userspace-built buffer is byte-compatible
 * with what the kernel expects.
 *
 * Driver patch sites (mmu_enable==0, sizeof(size_t)==8 branch), for a cmdbuf at
 * virtual base `b` with byte length `S` and W = b + S/4:
 *   head: b[1] = low32(vcmd_reg_bus + 27*4)   b[2] = high32(...)   (drv:1758-1764)
 *   tail: W[-7]= low32(vcmd_reg_bus)           W[-6]= high32(...)   (drv:1777-1781)
 *         W[-4..-1] JMP target/id patched at link (drv:3086-3118)
 * Userspace therefore supplies:
 *   b[0]  = RREG(1, reg26)            -- head dump opcode
 *   b[3]  = 0 pad
 *   ... body ...
 *   W[-8] = RREG(27, 0)              -- tail VCMD-reg dump opcode
 *   W[-5] = 0 pad
 *   W[-4] = JMP | IE                 -- validated opcode (drv:1703)
 *   W[-3..-1] = 0                    -- patched at link
 * and, crucially, the MIDDLE RREG that dumps the core register file into the
 * status pool -- its destination is user-owned (we know status phys + our id).
 */
#ifndef VCENC_CMDBUF_H
#define VCENC_CMDBUF_H

#include <stdint.h>
#include <string.h>
#include "vcmd_abi.h"

/* EXECUTING_CMDBUF_ID_ADDR = 26 (drv:319); its ASIC byte addr = 26*4 = 0x68. */
#define VCMD_EXEC_ID_REG   26
/* Number of VCMD registers dumped by the tail RREG (drv:3538, "27"). */
#define VCMD_TAIL_RREG_NUM 27
/* Encoder core register count dumped into the status slot (ENCODER_REGISTER_SIZE). */
#define ENC_REG_COUNT      543

/*
 * Build a pure register-readback cmdbuf (no encode): the exact shape of the
 * driver's init self-test (drv:3396-3612), which is the minimal known-good
 * program for this hardware. After WAIT, encoder swreg[N] is readable from the
 * status pool at STATUS_SLOT_REG_OFF(id, N).
 *
 *   buf            : dword-addressable cmdbuf slot (cmd_pool + id*0x2000)
 *   id             : this cmdbuf's id (from RESERVE)
 *   status_hw_addr : status pool base hw/bus address (GET_CMDBUF_PARAMETER)
 * Returns the cmdbuf byte size to put in exchange_parameter.cmdbuf_size.
 */
static inline uint16_t vcenc_build_readback_cmdbuf(uint32_t *buf, uint16_t id,
						   uint64_t status_hw_addr)
{
	/* Destination in the status pool for the core-register dump: this
	 * module's slot, at submodule_main_addr/2 (drv:3411). User-owned. */
	uint64_t core_dst = status_hw_addr + (uint64_t)id * 0x2000
			  + (SUBMODULE_MAIN_ADDR / 2);
	int i = 0;

	memset(buf, 0, 16 * sizeof(uint32_t));

	/* head: RREG 1 reg @ 0x68 (reg26); dest words [1],[2] patched by driver */
	buf[i++] = RREG_HDR(1, VCMD_EXEC_ID_REG * 4); /* 0xB0010068 */
	buf[i++] = 0;                                 /* dest lo  (driver) */
	buf[i++] = 0;                                 /* dest hi  (driver) */
	buf[i++] = 0;                                 /* pad */

	/* body: RREG all encoder core regs @ 0x1000 into our status slot */
	buf[i++] = RREG_HDR(ENC_REG_COUNT, SUBMODULE_MAIN_ADDR); /* 0xB21F1000 */
	buf[i++] = (uint32_t)core_dst;                           /* dest lo (ours) */
	buf[i++] = (uint32_t)(core_dst >> 32);                   /* dest hi (ours) */
	buf[i++] = 0;                                            /* pad */

	/* tail: RREG 27 VCMD regs @ 0; dest words patched by driver */
	buf[i++] = RREG_HDR(VCMD_TAIL_RREG_NUM, 0); /* 0xB01B0000 */
	buf[i++] = 0;                               /* dest lo (driver) */
	buf[i++] = 0;                               /* dest hi (driver) */
	buf[i++] = 0;                               /* pad */

	/* JMP terminator: opcode validated (drv:1703), IE set so WAIT wakes */
	buf[i++] = JMP_TAIL_WORD; /* 0xCA000000 */
	buf[i++] = 0;             /* target lo (driver) */
	buf[i++] = 0;             /* target hi (driver) */
	buf[i++] = id;            /* target cmdbuf id (driver overwrites on link) */

	return (uint16_t)(i * 4); /* 64 bytes */
}

#endif /* VCENC_CMDBUF_H */
