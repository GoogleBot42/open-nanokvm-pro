// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * ewl_encode -- Stage B of the open VC8000E EWL (#45): drive one real 1080p
 * fixed-QP H.264 IDR through the open driver, blob-free, and read the encoded
 * NAL back.
 *
 * No vendor library, no ax_venc.ko. Frame buffers are placed in the spare CMM
 * region (outside kernel-managed DRAM, /dev/mem-mappable, exactly as the vendor
 * stack used it) by relocating the device-captured buffer layout by a fixed
 * page-aligned delta -- which preserves every gap/alignment the vendor used and
 * so sidesteps the (undecoded) aux-buffer sizes. The register program is the
 * committed fixed-QP(32) IDR image (img_qp32_payload.h); the cmdbuf structure
 * is rebuilt from source (vcenc_encode.h).
 *
 * Milestone (what this proves): the open submission path drives the encoder
 * core to EXECUTE and emit a bitstream --
 *   - WAIT returns OK
 *   - swreg82 (HW cycle counter) advanced from 0  => the core really ran
 *   - swreg9 (output byte count) is a plausible NAL size
 *   - the output buffer holds H.264 slice bytes
 * Pixel-correctness (a cleanly decodable image) depends on the input pixel
 * format, which the RE records leave unresolved -- that is refinement, not this
 * milestone. The synthetic input here just gives the core something to encode.
 *
 * Usage: ewl_encode [out.h264]
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
#include "vcenc_encode.h"

/* Buffer relocation: place the captured buffer layout in spare CMM by adding a
 * fixed page-aligned delta. Userspace only touches the INPUT (fill) and OUTPUT
 * (read) regions; recon/aux buffers are DMA'd by the encoder internally, so we
 * never map them -- they just need to be valid unused CMM, which they are. */
#define VENDOR_BUF_BASE 0x73c00000u          /* below captured min (sw12=0x73c45000) */
#define MY_BUF_BASE     0x78000000u          /* spare CMM, clear of ax_cmm + our VCMD carveout */
#define BUF_DELTA       (MY_BUF_BASE - VENDOR_BUF_BASE)  /* 0x4400000, page-aligned */

/* captured plane bases (img_qp32) relocated. */
#define IN_Y_BASE  (0x73c45000u + BUF_DELTA)               /* swreg12 */
#define IN_END     (0x74233c00u + BUF_DELTA + 0x1fa400u)   /* swreg14 + W*H */
#define IN_MAP_LEN 0x00900000u                             /* 9MB, covers Y/Cb/Cr */
#define OUT_BASE   ((0x749ce028u & ~0xfffu) + BUF_DELTA)   /* relocated swreg8 base */
#define OUT_MAP_LEN 0x00500000u                            /* 5MB, covers sw9 limit */
#define OUT_LIMIT  0x004047d8u                             /* swreg9 */

/* NOTE: /dev/mem O_SYNC gives Device memory -- libc memset (DC ZVA) FAULTS on
 * it. Use only explicit aligned loads/stores on these mappings. */
static void *map_dev_mem(uint64_t phys, size_t len)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { perror("open(/dev/mem)"); return NULL; }
	void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
	close(fd);
	if (p == MAP_FAILED) { perror("mmap(/dev/mem)"); return NULL; }
	return p;
}

/* Device-memory-safe clear: 32-bit aligned stores, no DC ZVA. */
static void dev_clear(volatile uint32_t *p, size_t bytes)
{
	for (size_t i = 0; i < bytes / 4; i++) p[i] = 0;
}

static void *map_pool(int fd, uint64_t phys, uint32_t size)
{
	void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
	return p == MAP_FAILED ? NULL : p;
}

int main(int argc, char **argv)
{
	const char *outfile = argc > 1 ? argv[1] : NULL;
	setvbuf(stdout, NULL, _IONBF, 0);

	int fd = open(VCMD_DEV_NODE, O_RDWR);
	if (fd < 0) { fprintf(stderr, "open(%s): %s\n", VCMD_DEV_NODE, strerror(errno)); return 1; }

	struct config_parameter cfg = { .module_type = VCMD_TYPE_ENCODER };
	if (ioctl(fd, HANTRO_IOCH_GET_VCMD_PARAMETER, &cfg) < 0) { perror("GET_VCMD_PARAMETER"); return 1; }
	printf("VCMD: hwid=0x%08x main_addr=0x%x\n", cfg.vcmd_hw_version_id, cfg.submodule_main_addr);

	struct cmdbuf_mem_parameter mem;
	memset(&mem, 0, sizeof mem);
	if (ioctl(fd, HANTRO_IOCH_GET_CMDBUF_PARAMETER, &mem) < 0) { perror("GET_CMDBUF_PARAMETER"); return 1; }

	uint32_t *cmd_pool = map_pool(fd, mem.cmd_phy_addr, mem.cmd_total_size);
	uint8_t *status_pool = map_pool(fd, mem.status_phy_addr, mem.status_total_size);
	if (!cmd_pool || !status_pool) { fprintf(stderr, "pool mmap failed\n"); return 1; }

	/* Map only the input (fill) and output (read) regions in spare CMM. */
	uint8_t *in_map = map_dev_mem(IN_Y_BASE, IN_MAP_LEN);
	volatile uint32_t *out_map = map_dev_mem(OUT_BASE, OUT_MAP_LEN);
	if (!in_map || !out_map) return 1;
	printf("FRAMEBUF: in 0x%08x+0x%x  out 0x%08x+0x%x  (delta 0x%x)\n",
	       IN_Y_BASE, IN_MAP_LEN, OUT_BASE, OUT_MAP_LEN, BUF_DELTA);

	/* Lay a gradient into the input span (byte stores are Device-mem-safe) so
	 * the core has non-trivial content to encode. */
	uint32_t in_bytes = (IN_END > IN_Y_BASE) ? (IN_END - IN_Y_BASE) : 0;
	if (in_bytes > IN_MAP_LEN) in_bytes = IN_MAP_LEN;
	for (uint32_t o = 0; o < in_bytes; o++)
		in_map[o] = (uint8_t)((o >> 6) ^ (o >> 12));

	/* Clear the output region so we can see what the encoder wrote. */
	dev_clear(out_map, OUT_MAP_LEN);

	/* RESERVE a cmdbuf slot. */
	struct exchange_parameter ex;
	memset(&ex, 0, sizeof ex);
	ex.module_type = VCMD_TYPE_ENCODER;
	if (ioctl(fd, HANTRO_IOCH_RESERVE_CMDBUF, &ex) < 0) { perror("RESERVE_CMDBUF"); return 1; }
	uint16_t id = ex.cmdbuf_id;

	/* Core register readback lands in our status slot (same spot Stage A used);
	 * swreg9/swreg82 are read back from here after WAIT. */
	uint64_t core_dst = mem.status_hw_addr + (uint64_t)id * 0x2000 + (SUBMODULE_MAIN_ADDR / 2);
	memset(status_pool + STATUS_SLOT_REG_OFF(id, 0), 0, 512 * 4);

	uint32_t *slot = cmd_pool + (uint32_t)id * (mem.cmd_unit_size / 4);
	uint16_t size = vcenc_build_encode_cmdbuf(slot, BUF_DELTA, core_dst);
	ex.cmdbuf_size = size;
	ex.numa_id = 0;
	printf("RESERVE: id=%u  cmdbuf=%u bytes\n", id, size);

	if (ioctl(fd, HANTRO_IOCH_LINK_RUN_CMDBUF, &ex) < 0) { perror("LINK_RUN_CMDBUF"); return 1; }

	uint16_t wid = id;
	if (ioctl(fd, HANTRO_IOCH_WAIT_CMDBUF, &wid) < 0) { perror("WAIT_CMDBUF"); return 1; }
	printf("WAIT: status=%u (%s)\n", wid, wid == CMDBUF_EXE_STATUS_OK ? "OK" : "ERR");

	/* Read core registers back out of the status slot. */
	volatile uint32_t *rr = (volatile uint32_t *)(status_pool + STATUS_SLOT_REG_OFF(id, 0));
	uint32_t swreg0 = rr[0], swreg1 = rr[1], swreg9 = rr[9], swreg82 = rr[82];
	printf("READBACK: swreg0=0x%08x swreg1=0x%08x swreg9(NALbytes)=%u swreg82(cycles)=%u\n",
	       swreg0, swreg1, swreg9, swreg82);

	/* Copy the output region into a heap buffer (aligned Device-mem reads),
	 * then scan for the H.264 start code and validate the NAL type. */
	volatile uint8_t *out = (volatile uint8_t *)out_map;
	uint32_t scan = (swreg9 && swreg9 < OUT_MAP_LEN) ? swreg9 + 8 : 256;
	uint8_t *nal = malloc(scan);
	for (uint32_t i = 0; i < scan; i++) nal[i] = out[i];

	int sc = -1, nut = -1;
	for (uint32_t i = 0; i + 4 < scan; i++) {
		if (nal[i] == 0 && nal[i+1] == 0 && nal[i+2] == 1) { sc = i; nut = nal[i+3] & 0x1f; break; }
	}
	if (sc >= 0)
		printf("NAL: start code @+0x%x  nal_unit_type=%d (%s)\n", sc, nut,
		       nut == 5 ? "IDR slice" : nut == 1 ? "non-IDR slice" : "other");
	else
		printf("NAL: no start code found in %u bytes\n", scan);

	int nal_ok = (swreg9 > 0 && swreg9 <= OUT_LIMIT);
	int ran = (swreg82 > 0);
	int idr = (nut == 5);
	int ok = (wid == CMDBUF_EXE_STATUS_OK) && ran && nal_ok && idr;

	if (ok && outfile && sc >= 0 && swreg9 <= OUT_MAP_LEN) {
		/* Write the raw slice NAL from the start code onward. A decodable
		 * stream needs SPS+PPS prepended (HW emits slice data only) -- that
		 * is the next refinement; here we save the proven slice. */
		FILE *f = fopen(outfile, "wb");
		if (f) { fwrite(nal + sc, 1, (swreg9 > (uint32_t)sc) ? swreg9 - sc : 0, f);
			fclose(f); printf("wrote slice NAL to %s\n", outfile); }
	}
	free(nal);

	uint16_t rid = id;
	if (ioctl(fd, HANTRO_IOCH_RELEASE_CMDBUF, &rid) < 0) perror("RELEASE_CMDBUF (non-fatal)");
	close(fd);

	printf("\nRESULT: %s -- core %s, %u-byte %s NAL emitted blob-free\n",
	       ok ? "PASS" : "FAIL",
	       ran ? "executed (cycles>0)" : "did NOT run (cycles=0)", swreg9,
	       idr ? "IDR" : "(non-IDR/invalid)");
	return ok ? 0 : 2;
}
