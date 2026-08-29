// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * ewl_probe -- Stage A of the open VC8000E EWL (#45): prove the blob-free
 * userspace submission path end-to-end on the open ax630c_venc_vcmd driver.
 *
 * It drives the full cmdbuf lifecycle from userspace -- with NO vendor library,
 * NO ax_venc.ko, NO frame buffers -- using the driver's own minimal known-good
 * program (a register readback, drv create_read_all_registers_cmdbuf):
 *
 *   open(/dev/es_venc)
 *   GET_VCMD_PARAMETER   -> confirm hwid 0x43421500, core reg base 0x1000
 *   GET_CMDBUF_PARAMETER -> pool phys/sizes
 *   mmap(cmd pool), mmap(status pool)   [/dev/mem fallback if driver mmap 404s]
 *   RESERVE_CMDBUF       -> slot id
 *   build readback cmdbuf into the slot
 *   LINK_RUN_CMDBUF / WAIT_CMDBUF / RELEASE_CMDBUF
 *   read encoder swreg0.. back out of the status pool
 *
 * Success = WAIT returns status OK and the status slot holds swreg0 ==
 * 0x90101010, the encoder core's read-only ASIC ID (the RREG dumped the core
 * register file at ASIC base 0x1000 into our status slot).
 * That proves the ABI, the mmap path, cmdbuf construction, hardware execution,
 * completion delivery, and status readback -- everything Stage B (a real IDR)
 * builds on. Stage B only adds CMM frame buffers + the encode register program.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

#include "vcmd_abi.h"
#include "vcenc_cmdbuf.h"

#define EXPECT_VCMD_HWID 0x43421500u /* VCMD engine hwid (GET_VCMD_PARAMETER) */
#define EXPECT_ENC_ASIC  0x90101010u /* encoder core swreg0 ASIC ID (readback @0x1000) */

static void *map_pool(int fd, uint64_t phys, uint32_t size, const char *what)
{
	/* Preferred: the driver's own dma_mmap_coherent, keyed on the pool phys
	 * as the mmap offset (drv:2264-2300). */
	void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
		       (off_t)phys);
	if (p != MAP_FAILED)
		return p;
	fprintf(stderr, "  driver mmap of %s @0x%llx failed (%s); trying /dev/mem\n",
		what, (unsigned long long)phys, strerror(errno));

	/* Fallback: the pools live in the declared coherent carveout (outside
	 * kernel-managed DRAM), so /dev/mem O_SYNC maps them uncached. */
	int mfd = open("/dev/mem", O_RDWR | O_SYNC);
	if (mfd < 0) {
		fprintf(stderr, "  open(/dev/mem): %s\n", strerror(errno));
		return NULL;
	}
	p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, mfd, (off_t)phys);
	close(mfd);
	if (p == MAP_FAILED) {
		fprintf(stderr, "  /dev/mem mmap of %s: %s\n", what, strerror(errno));
		return NULL;
	}
	return p;
}

int main(void)
{
	setvbuf(stdout, NULL, _IONBF, 0);

	int fd = open(VCMD_DEV_NODE, O_RDWR);
	if (fd < 0) {
		fprintf(stderr, "open(%s): %s\n", VCMD_DEV_NODE, strerror(errno));
		return 1;
	}

	struct config_parameter cfg = { .module_type = VCMD_TYPE_ENCODER };
	if (ioctl(fd, HANTRO_IOCH_GET_VCMD_PARAMETER, &cfg) < 0) {
		fprintf(stderr, "GET_VCMD_PARAMETER: %s\n", strerror(errno));
		return 1;
	}
	printf("VCMD: cores=%u main_addr=0x%x hwid=0x%08x status_cmdbuf_id=%u\n",
	       cfg.vcmd_core_num, cfg.submodule_main_addr, cfg.vcmd_hw_version_id,
	       cfg.config_status_cmdbuf_id);
	if (cfg.vcmd_hw_version_id != EXPECT_VCMD_HWID)
		fprintf(stderr, "  WARN: hwid 0x%08x != expected 0x%08x\n",
			cfg.vcmd_hw_version_id, EXPECT_VCMD_HWID);
	if (cfg.submodule_main_addr != SUBMODULE_MAIN_ADDR)
		fprintf(stderr, "  WARN: main_addr 0x%x != 0x%x\n",
			cfg.submodule_main_addr, SUBMODULE_MAIN_ADDR);

	struct cmdbuf_mem_parameter mem;
	memset(&mem, 0, sizeof mem);
	if (ioctl(fd, HANTRO_IOCH_GET_CMDBUF_PARAMETER, &mem) < 0) {
		fprintf(stderr, "GET_CMDBUF_PARAMETER: %s\n", strerror(errno));
		return 1;
	}
	printf("POOLS: cmd phys=0x%llx size=0x%x unit=0x%x | status phys=0x%llx size=0x%x\n",
	       (unsigned long long)mem.cmd_phy_addr, mem.cmd_total_size, mem.cmd_unit_size,
	       (unsigned long long)mem.status_phy_addr, mem.status_total_size);

	uint32_t *cmd_pool = map_pool(fd, mem.cmd_phy_addr, mem.cmd_total_size, "cmd pool");
	uint8_t *status_pool = map_pool(fd, mem.status_phy_addr, mem.status_total_size, "status pool");
	if (!cmd_pool || !status_pool)
		return 1;

	/* RESERVE a cmdbuf slot. */
	struct exchange_parameter ex;
	memset(&ex, 0, sizeof ex);
	ex.module_type = VCMD_TYPE_ENCODER;
	ex.executing_time = 0;
	ex.cmdbuf_size = 0;   /* reserve ignores; driver returns the slot cap */
	ex.priority = 0;
	if (ioctl(fd, HANTRO_IOCH_RESERVE_CMDBUF, &ex) < 0) {
		fprintf(stderr, "RESERVE_CMDBUF: %s\n", strerror(errno));
		return 1;
	}
	uint16_t id = ex.cmdbuf_id;
	printf("RESERVE: cmdbuf_id=%u\n", id);

	/* Build the readback program directly in the slot. */
	uint32_t *slot = cmd_pool + (uint32_t)id * (mem.cmd_unit_size / 4);
	uint16_t size = vcenc_build_readback_cmdbuf(slot, id, mem.status_hw_addr);
	ex.cmdbuf_size = size;   /* MUST set the real length before LINK */
	ex.numa_id = 0;          /* bind encoder core 0 */

	/* Zero our status slot's core region so a stale read can't fake success. */
	memset(status_pool + STATUS_SLOT_REG_OFF(id, 0), 0, ENC_REG_COUNT * 4);

	if (ioctl(fd, HANTRO_IOCH_LINK_RUN_CMDBUF, &ex) < 0) {
		fprintf(stderr, "LINK_RUN_CMDBUF: %s\n", strerror(errno));
		return 1;
	}
	printf("LINK_RUN: core_id=%u size=%u\n", ex.core_id, size);

	uint16_t wid = id;
	if (ioctl(fd, HANTRO_IOCH_WAIT_CMDBUF, &wid) < 0) {
		fprintf(stderr, "WAIT_CMDBUF: %s\n", strerror(errno));
		return 1;
	}
	printf("WAIT: status=%u (%s)\n", wid,
	       wid == CMDBUF_EXE_STATUS_OK ? "OK" :
	       wid == CMDBUF_EXE_STATUS_CMDERR ? "CMDERR" :
	       wid == CMDBUF_EXE_STATUS_BUSERR ? "BUSERR" : "?");

	/* Read encoder registers back out of the status pool. */
	volatile uint32_t *rr = (volatile uint32_t *)(status_pool + STATUS_SLOT_REG_OFF(id, 0));
	uint32_t swreg0 = rr[0], swreg1 = rr[1], swreg80 = rr[80], swreg82 = rr[82];
	printf("READBACK: swreg0=0x%08x swreg1=0x%08x swreg80=0x%08x swreg82(cycles)=%u\n",
	       swreg0, swreg1, swreg80, swreg82);

	uint16_t rid = id;
	if (ioctl(fd, HANTRO_IOCH_RELEASE_CMDBUF, &rid) < 0)
		fprintf(stderr, "RELEASE_CMDBUF: %s (non-fatal)\n", strerror(errno));

	close(fd);

	int ok = (wid == CMDBUF_EXE_STATUS_OK) && (swreg0 == EXPECT_ENC_ASIC);
	printf("\nRESULT: %s -- open userspace VCMD submission %s\n",
	       ok ? "PASS" : "FAIL",
	       ok ? "drove the hardware and read it back" : "did not verify");
	return ok ? 0 : 2;
}
