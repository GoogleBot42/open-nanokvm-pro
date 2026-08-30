// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * ewl_encode -- the open VC8000E EWL (#45, Stages B-D): drive one real 1080p
 * fixed-QP H.264 IDR through the open driver, blob-free, and emit a complete
 * decodable .h264 (from-source SPS+PPS + the hardware slice).
 *
 * No vendor library, no ax_venc.ko, no /dev/mem. Frame buffers come from the
 * driver's from-source CMM allocator (framebuf_alloc.c) as one block holding
 * the relocated device-captured layout; the register program is the committed
 * fixed-QP(32) IDR image (img_qp32_payload.h); the cmdbuf structure is rebuilt
 * from source (vcenc_encode.h); SPS/PPS are written from the H.264 spec
 * (vcenc_header.h). Verified per run:
 *   - WAIT returns OK
 *   - swreg82 (HW cycle counter) advanced from 0  => the core really ran
 *   - swreg9 (output byte count) within the programmed limit
 *   - the output holds an IDR slice NAL; with [out.h264] the SPS+PPS+IDR
 *     stream decodes clean in a host ffmpeg (proven, Stage C)
 *
 * Usage: ewl_encode [out.h264] [gradient|yuyv|nv12]
 *
 * The pattern modes settled the input-pixel-format question (Stage C,
 * device-proven): the real input format is PACKED YUYV 4:2:2, 2 B/px at sw12
 * -- the yuyv test card (8 vertical bars, white top-left square, black
 * bottom-right square) decodes pixel-perfect, the nv12 hypothesis shows
 * packed-422 aliasing, and sw13-sw12 = 0x3f4800 = 2*W*H exactly (packed modes
 * ignore the sw13/sw14 chroma bases). sw17=0x30's "NV12" label was wrong.
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
#include "vcenc_header.h"

/* Buffer relocation: allocate the whole captured buffer layout as ONE block
 * from the driver's from-source CMM allocator (HANTRO_IOCH_ALLOC_FRAMEBUF) and
 * relocate every address register by (block_bus - LAYOUT_BASE). One block
 * preserves every gap/alignment the vendor used, which sidesteps the
 * (undecoded) per-buffer sizes; the delta stays page-aligned because both the
 * allocator and the captured bases are page-aligned, so sub-page offsets
 * embedded in swreg8/10 survive. Userspace touches only the INPUT (fill) and
 * OUTPUT (read) regions inside the driver's writecombine mmap of the block;
 * recon/aux are DMA'd by the encoder internally. */
#define LAYOUT_BASE 0x73c45000u   /* min captured address reg (sw12, input Y) */
#define LAYOUT_SPAN 0x02b00000u   /* to max reg base (sw27 0x76306300) + 4MB slack */

#define IN_FILL_LEN 0x007e9000u                  /* (sw14 + W*H) - sw12: Y/Cb/Cr extent */
#define OUT_OFF    ((0x749ce028u & ~0xfffu) - LAYOUT_BASE)  /* sw8 page - sw12 */
#define OUT_MAP_LEN 0x00500000u                  /* 5MB window, covers sw9 limit */
#define OUT_LIMIT  0x004047d8u                   /* swreg9 (output byte limit) */
#define STREAM_OFF (0x749ce028u & 0xfffu)        /* stream start in the sw8 page */

#define ENC_QP     32u                           /* the img_qp32 program's sw7 QP */
#define ENC_W      1920u
#define ENC_H      1080u

/* 32-bit aligned stores (kept from the /dev/mem days; also fine on the
 * driver's writecombine mapping). */
static void dev_clear(volatile uint32_t *p, size_t bytes)
{
	for (size_t i = 0; i < bytes / 4; i++) p[i] = 0;
}

static void *map_pool(int fd, uint64_t phys, uint32_t size)
{
	void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
	return p == MAP_FAILED ? NULL : p;
}

/* Test-card luma at pixel (x,y): 8 vertical bars 16..233, white 100x100
 * square top-left, black 100x100 square bottom-right. Orientation- and
 * stride-sensitive on purpose. */
static uint8_t card_luma(uint32_t x, uint32_t y)
{
	if (x < 100 && y < 100) return 235;
	if (x >= ENC_W - 100 && y >= ENC_H - 100) return 16;
	return (uint8_t)(16 + (x / 240) * 31);
}

int main(int argc, char **argv)
{
	const char *outfile = argc > 1 ? argv[1] : NULL;
	const char *mode = argc > 2 ? argv[2] : "gradient";
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

	/* Allocate the whole relocated layout from the driver's from-source CMM
	 * allocator and mmap it (writecombine) through the driver -- no /dev/mem. */
	struct framebuf_parameter fbp = { .size = LAYOUT_SPAN };
	if (ioctl(fd, HANTRO_IOCH_ALLOC_FRAMEBUF, &fbp) < 0) {
		perror("ALLOC_FRAMEBUF"); return 1;
	}
	uint32_t buf_delta = (uint32_t)(fbp.bus_addr - LAYOUT_BASE);
	uint8_t *fb_map = mmap(NULL, LAYOUT_SPAN, PROT_READ | PROT_WRITE,
			       MAP_SHARED, fd, (off_t)fbp.bus_addr);
	if (fb_map == MAP_FAILED) { perror("mmap(framebuf)"); return 1; }
	uint8_t *in_map = fb_map;                    /* layout base == input Y (sw12) */
	volatile uint32_t *out_map = (volatile uint32_t *)(fb_map + OUT_OFF);
	printf("FRAMEBUF: alloc 0x%08lx+0x%x (delta 0x%x)  in +0  out +0x%x\n",
	       fbp.bus_addr, LAYOUT_SPAN, buf_delta, OUT_OFF);

	/* Fill the input under the selected format hypothesis (byte stores are
	 * Device-mem-safe). Everything beyond the format's own extent gets
	 * neutral 0x80 so no stale bytes leak into the encode. */
	uint32_t in_bytes = IN_FILL_LEN;
	printf("INPUT: %s test pattern\n", mode);
	if (strcmp(mode, "yuyv") == 0) {
		/* Packed 4:2:2 [Y U Y V], 2 B/px at sw12. */
		for (uint32_t o = 0; o < in_bytes; o++) {
			uint32_t p = o / 2;
			in_map[o] = (o & 1) ? 0x80
				: (p < ENC_W * ENC_H ? card_luma(p % ENC_W, p / ENC_W) : 0x80);
		}
	} else if (strcmp(mode, "nv12") == 0) {
		/* Planar Y at sw12; CbCr (at sw13 = sw12 + 0x3f4800) and
		 * everything else neutral. */
		for (uint32_t o = 0; o < in_bytes; o++)
			in_map[o] = o < ENC_W * ENC_H
				? card_luma(o % ENC_W, o / ENC_W) : 0x80;
	} else {
		for (uint32_t o = 0; o < in_bytes; o++)
			in_map[o] = (uint8_t)((o >> 6) ^ (o >> 12));
	}

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
	uint16_t size = vcenc_build_encode_cmdbuf(slot, buf_delta, core_dst);
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

	if (ok && outfile && swreg9 + STREAM_OFF <= OUT_MAP_LEN) {
		/* Emit a complete decodable stream: from-source SPS+PPS (the HW
		 * emits slice data only), then the slice -- swreg9 bytes starting
		 * at the stream base (buffer offset STREAM_OFF, where the HW put
		 * the 4-byte start code). */
		uint8_t hdr[128];
		uint32_t hlen = vcenc_write_sps(hdr, ENC_W, ENC_H);
		hlen += vcenc_write_pps(hdr + hlen, ENC_QP);
		uint8_t *slice = malloc(swreg9);
		volatile uint8_t *sb = (volatile uint8_t *)out_map + STREAM_OFF;
		for (uint32_t i = 0; i < swreg9; i++) slice[i] = sb[i];
		FILE *f = fopen(outfile, "wb");
		if (f) {
			fwrite(hdr, 1, hlen, f);
			fwrite(slice, 1, swreg9, f);
			fclose(f);
			printf("wrote SPS+PPS+IDR stream (%u bytes) to %s\n", hlen + swreg9, outfile);
		}
		free(slice);
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
