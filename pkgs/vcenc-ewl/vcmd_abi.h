/* SPDX-License-Identifier: GPL-2.0 OR MIT */
/*
 * Userspace view of the open VC8000E VCMD driver's ioctl/cmdbuf ABI
 * (pkgs/vc8000-vcmd/eswin/vc8000_driver.h + vc8000_vcmd_driver.c).
 *
 * Every constant here is transcribed from that driver as built for AX630C
 * (Makefile defines only -DHANTROVCMD_ENABLE_IP_SUPPORT). Load-bearing facts
 * for a from-scratch submitter, all verified against the driver source:
 *
 *  - device node  : /dev/es_venc, dynamic major
 *  - hwid gate    : VCMD reg0 = 0x43421500 (VCMD v1.5.0)
 *  - core reg file: submodule_main_addr = 0x1000 (ASIC byte addr of swreg0)
 *  - cmdbuf slot  : CMDBUF_MAX_SIZE = 0x2000 (8192B); pool 2MB / 256 slots;
 *                   slot 0 reserved (int vector != 0), slot 1 held by the
 *                   driver's init self-test -> 254 usable.
 *  - mmu_enable=0, base_ddr_addr=0  => hw addr == bus addr == dma_handle.
 *  - pools are DMA-coherent (non-cacheable): no manual cache maintenance.
 *
 * The driver patches a fixed head+tail into every cmdbuf; userspace must lay
 * out the opcode stream so those patch sites land where the driver expects
 * (see vcenc_cmdbuf.h). This header is only the syscall/opcode contract.
 */
#ifndef VCMD_ABI_H
#define VCMD_ABI_H

#include <linux/ioctl.h>
#include <stdint.h>

#define VCMD_DEV_NODE "/dev/es_venc"

/* ---- ioctl magic + numbers (vc8000_driver.h:106,136-149) ---------------- */
#define HANTRO_IOC_MAGIC 'k'
#define HANTRO_IOCH_GET_CMDBUF_PARAMETER  _IOWR(HANTRO_IOC_MAGIC, 25, struct cmdbuf_mem_parameter *)
#define HANTRO_IOCH_GET_VCMD_PARAMETER    _IOWR(HANTRO_IOC_MAGIC, 28, struct config_parameter *)
#define HANTRO_IOCH_RESERVE_CMDBUF        _IOWR(HANTRO_IOC_MAGIC, 29, struct exchange_parameter *)
#define HANTRO_IOCH_LINK_RUN_CMDBUF       _IOR(HANTRO_IOC_MAGIC, 30, uint16_t *)
#define HANTRO_IOCH_WAIT_CMDBUF           _IOR(HANTRO_IOC_MAGIC, 31, uint16_t *)
#define HANTRO_IOCH_RELEASE_CMDBUF        _IOR(HANTRO_IOC_MAGIC, 32, uint16_t *)
#define HANTRO_IOCH_POLLING_CMDBUF        _IOR(HANTRO_IOC_MAGIC, 33, uint16_t *)

/* AX630C additions (pkgs/vc8000-vcmd/framebuf_alloc.h): the from-source
 * frame-buffer allocator over the CMM carveout (#45). Allocations are owned
 * by the fd and freed on close; mmap the returned bus_addr on the same fd. */
#define HANTRO_IOCH_ALLOC_FRAMEBUF        _IOWR(HANTRO_IOC_MAGIC, 36, struct framebuf_parameter)
#define HANTRO_IOCH_FREE_FRAMEBUF         _IOWR(HANTRO_IOC_MAGIC, 37, struct framebuf_parameter)

struct framebuf_parameter {
	unsigned long size;      /* in: bytes */
	unsigned long bus_addr;  /* out (alloc) / in (free) */
};

/* dma-buf import (#60 M3, mirrors pkgs/vc8000-vcmd/framebuf_alloc.h): resolve
 * a dma-buf fd (a V4L2 EXPBUF export of an open capture buffer) to the bus
 * address the encoder register program consumes. Owned by the open file. */
struct dmabuf_import_parameter {
	int fd;                  /* in: dma-buf file descriptor */
	unsigned long bus_addr;  /* out (import) / in (release) */
	unsigned long size;      /* out: bytes */
};
#define HANTRO_IOCH_IMPORT_DMABUF         _IOWR(HANTRO_IOC_MAGIC, 38, struct dmabuf_import_parameter)
#define HANTRO_IOCH_RELEASE_DMABUF        _IOWR(HANTRO_IOC_MAGIC, 39, struct dmabuf_import_parameter)

/* module_type (vc8000_driver.h:256) */
#define VCMD_TYPE_ENCODER 0

/* ---- ABI structs (exact field order + sizes; ptr_t/dma_addr_t = 8B) ------ */

/* vc8000_driver.h:264-277. 72 bytes on arm64. Only the phys/hw-addr,
 * total-size and unit-size fields are filled by the driver; the two
 * virt-addr pointers are NOT written (kernel pointers anyway). */
struct cmdbuf_mem_parameter {
	uint32_t *cmd_virt_addr;     /* NOT written by driver */
	uint64_t  cmd_phy_addr;      /* command pool base (busAddress) */
	uint64_t  cmd_hw_addr;       /* == cmd_phy_addr - base_ddr_addr(0) */
	uint32_t  cmd_total_size;    /* 0x200000 */
	uint16_t  cmd_unit_size;     /* 0x2000 */
	uint32_t *status_virt_addr;  /* NOT written by driver */
	uint64_t  status_phy_addr;   /* status pool base (busAddress) */
	uint64_t  status_hw_addr;
	uint32_t  status_total_size; /* 0x200000 */
	uint16_t  status_unit_size;  /* 0x2000 */
	uint64_t  base_ddr_addr;     /* 0 */
};

/* vc8000_driver.h:279-290. 28 bytes on arm64. */
struct config_parameter {
	uint16_t module_type;             /* in */
	uint16_t vcmd_core_num;           /* out: 1 */
	uint16_t submodule_main_addr;     /* out: 0x1000 */
	uint16_t submodule_dec400_addr;   /* out: 0xFFFF */
	uint16_t submodule_L2Cache_addr;  /* out: 0xFFFF */
	uint16_t submodule_MMU_addr[2];   /* out: 0xFFFF,0xFFFF */
	uint16_t submodule_axife_addr[2]; /* out: 0x2000,0xFFFF */
	uint16_t config_status_cmdbuf_id; /* out: 1 */
	uint32_t vcmd_hw_version_id;      /* out: 0x43421500 */
};

/* vc8000_driver.h:293-301. 16 bytes. */
struct exchange_parameter {
	uint32_t executing_time; /* in: pass 0 (disables admission/coalesce weight) */
	uint16_t module_type;    /* in: VCMD_TYPE_ENCODER */
	uint16_t cmdbuf_size;    /* in(reserve): 0; the driver overwrites with 8192.
	                          * in(link):  MUST be set to the real byte size. */
	uint16_t priority;       /* in: 0 = normal */
	uint16_t cmdbuf_id;      /* out(reserve): allocated slot */
	uint16_t core_id;        /* out(link): chosen core */
	uint16_t numa_id;        /* in(link): 0 -> binds encoder core 0 */
};

/* ---- VCMD opcode encodings (vc8000_driver.h:162-176; decoder drv:823-861) */
/* opcode field is bits [31:27]. */
#define OPCODE_WREG     (0x01u << 27) /* 0x08000000 */
#define OPCODE_END      (0x02u << 27) /* 0x10000000 (unsupported as last op) */
#define OPCODE_NOP      (0x03u << 27) /* 0x18000000 */
#define OPCODE_RREG     (0x16u << 27) /* 0xB0000000 */
#define OPCODE_JMP      (0x19u << 27) /* 0xC8000000 */
#define OPCODE_STALL    (0x09u << 27) /* 0x48000000; bits[15:0]=sync value */
#define OPCODE_CLRINT   (0x1au << 27) /* 0xD0000000; bits[15:0]=ASIC byte addr */
#define JMP_IE_1        (1u << 25)    /* 0x02000000: interrupt on this JMP */
#define JMP_RDY_1       (1u << 26)    /* 0x04000000: set by driver at link */
#define WREG_FIX        (1u << 26)    /* write all N values to same address */

/* WREG a burst of `n` incrementing regs starting at ASIC byte addr `a`:
 *   word0 = WREG_BURST(n,a); then n data words; pad to even dword count. */
#define WREG_BURST(n, a) (OPCODE_WREG | (((uint32_t)(n) & 0x3FF) << 16) | ((uint32_t)(a) & 0xFFFF))
/* RREG `n` regs from ASIC byte addr `a` into the DDR addr in the next 2 words. */
#define RREG_HDR(n, a)   (OPCODE_RREG | (((uint32_t)(n) & 0x3FF) << 16) | ((uint32_t)(a) & 0xFFFF))
/* JMP tail word the driver validates (opcode must be OPCODE_JMP; set IE so a
 * normal completion interrupt fires -> WAIT wakes). */
#define JMP_TAIL_WORD    (OPCODE_JMP | JMP_IE_1) /* 0xCA000000, RDY=0 */

/* STALL: wait for the core to finish (captured value uses sync=1). */
#define STALL_WORD(v)   (OPCODE_STALL | ((uint32_t)(v) & 0xFFFF))
/* CLRINT: clear the core interrupt at ASIC byte addr `a` (next word = mask). */
#define CLRINT_WORD(a)  (OPCODE_CLRINT | ((uint32_t)(a) & 0xFFFF))

/* Core register file base inside the VCMD ASIC map (config_parameter). */
#define SUBMODULE_MAIN_ADDR 0x1000
/* ASIC byte address of encoder swreg[N]. */
#define SWREG_ADDR(n) (SUBMODULE_MAIN_ADDR + (uint32_t)(n) * 4)

/* WAIT return status (written back into the u16 arg; drv:325-327). */
#define CMDBUF_EXE_STATUS_OK     0
#define CMDBUF_EXE_STATUS_CMDERR 1
#define CMDBUF_EXE_STATUS_BUSERR 2

/* Status-pool readback: encoder swreg[N] for cmdbuf `id` lives at
 * status_pool_base + id*0x2000 + (SUBMODULE_MAIN_ADDR/2) + N*4.  (drv:1925) */
#define STATUS_SLOT_REG_OFF(id, n) \
	((size_t)(id) * 0x2000 + (SUBMODULE_MAIN_ADDR / 2) + (size_t)(n) * 4)

#endif /* VCMD_ABI_H */
