// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * ewl_encode -- the open VC8000E EWL (#45 Stages B-D, now a multi-frame GOP
 * session for #25): drive fixed-QP 1080p H.264 IDR + P frames through the
 * open driver, blob-free, and emit a complete decodable .h264.
 *
 * No vendor library, no ax_venc.ko, no /dev/mem. Frame buffers come from the
 * driver's from-source CMM allocator (framebuf_alloc.c) as one block holding
 * the relocated device-captured layout; the per-frame register program is
 * built by vcenc_encode.h (fixed-QP(32) base image + the Stage-0-derived
 * P-frame overlay and recon/aux bank ping-pong); SPS/PPS are written from
 * the H.264 spec (vcenc_header.h). Verified per frame:
 *   - WAIT returns OK
 *   - swreg82 (HW cycle counter) advanced from 0  => the core really ran
 *   - swreg9 (output byte count) within the programmed limit
 *   - the emitted NAL type matches the frame type (5 = IDR, 1 = P)
 *
 * Usage: ewl_encode [out.h264] [nframes] [gop] [mode]
 *   nframes  total frames to encode (default 1)
 *   gop      IDR period; 0 = IDR only at frame 0 (default)
 *   mode     yuyv (default; moving test card -- frame 0 is bit-compatible
 *            with the Stage C/D static card), gradient, nv12 (static
 *            format-hypothesis fills kept for regression)
 * Env knobs (P-frame experiment fallbacks, see vcenc_encode.h):
 *   EWL_P17=<hex>   override the P-frame swreg17 value
 *   EWL_PINTER=1    replay the captured warmed-up inter-state registers
 *
 * The input format is PACKED YUYV 4:2:2, 2 B/px at sw12 (Stage C,
 * device-proven; sw13-sw12 = 2*W*H exactly, packed modes ignore the
 * chroma base registers).
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

#define IN_FILL_LEN 0x007e9000u                  /* (sw14 + W*H) - sw12: full input extent */
#define OUT_OFF    ((0x749ce028u & ~0xfffu) - LAYOUT_BASE)  /* sw8 page - sw12 */
#define OUT_MAP_LEN 0x00500000u                  /* 5MB window, covers sw9 limit */
#define OUT_LIMIT  0x004047d8u                   /* swreg9 (output byte limit) */
#define STREAM_OFF (0x749ce028u & 0xfffu)        /* stream start in the sw8 page */

#define ENC_QP     32u                           /* the img_qp32 program's sw7 QP */
#define ENC_W      1920u
#define ENC_H      1080u

/* 32-bit aligned stores (kept from the /dev/mem days; also fine on the
 * driver's writecombine mapping). */
static void dev_fill32(volatile uint32_t *p, size_t bytes, uint32_t val)
{
	for (size_t i = 0; i < bytes / 4; i++) p[i] = val;
}

static void *map_pool(int fd, uint64_t phys, uint32_t size)
{
	void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
	return p == MAP_FAILED ? NULL : p;
}

/* Test-card luma at pixel (x,y) for frame n: 8 vertical bars 16..233, a
 * white 100x100 square gliding right/down from the top-left corner (16px/
 * frame horizontally, 8px vertically -- real motion for the P frames; n=0
 * matches the Stage C/D static card), black 100x100 square bottom-right. */
static uint8_t card_luma(uint32_t x, uint32_t y, uint32_t n)
{
	uint32_t sx = (16 * n) % (ENC_W - 100), sy = (8 * n) % (ENC_H - 100);
	if (x - sx < 100 && y - sy < 100) return 235;
	if (x >= ENC_W - 100 && y >= ENC_H - 100) return 16;
	return (uint8_t)(16 + (x / 240) * 31);
}

/* Fill the packed-YUYV region for frame n: one 32-bit store per pixel pair
 * [Y0 U Y1 V], neutral chroma. */
static void fill_yuyv(volatile uint32_t *in, uint32_t n)
{
	for (uint32_t y = 0; y < ENC_H; y++)
		for (uint32_t x = 0; x < ENC_W; x += 2)
			in[(y * ENC_W + x) / 2] =
				(uint32_t)card_luma(x, y, n)
				| 0x8000u
				| ((uint32_t)card_luma(x + 1, y, n) << 16)
				| 0x80000000u;
}

int main(int argc, char **argv)
{
	const char *outfile = argc > 1 ? argv[1] : NULL;
	uint32_t nframes = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 1;
	uint32_t gop = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : 0;
	const char *mode = argc > 4 ? argv[4] : "yuyv";
	uint32_t p17 = getenv("EWL_P17") ? (uint32_t)strtoul(getenv("EWL_P17"), NULL, 16) : 0;
	int pinter = getenv("EWL_PINTER") ? atoi(getenv("EWL_PINTER")) : 0;
	setvbuf(stdout, NULL, _IONBF, 0);

	if (!nframes) nframes = 1;
	if (p17 || pinter)
		printf("P-KNOBS: p17=0x%08x pinter=%d\n", p17 ? p17 : ENC_SW17_P, pinter);

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
	volatile uint32_t *in_map = (volatile uint32_t *)fb_map; /* layout base == input Y (sw12) */
	volatile uint32_t *out_map = (volatile uint32_t *)(fb_map + OUT_OFF);
	printf("FRAMEBUF: alloc 0x%08lx+0x%x (delta 0x%x)  in +0  out +0x%x\n",
	       fbp.bus_addr, LAYOUT_SPAN, buf_delta, OUT_OFF);

	/* Neutral 0x80 across the whole input extent once (covers the packed
	 * region between frames of the static modes and the tail always). */
	dev_fill32(in_map, IN_FILL_LEN, 0x80808080u);

	/* Static fills for the format-regression modes (once). */
	if (strcmp(mode, "nv12") == 0) {
		volatile uint8_t *in8 = (volatile uint8_t *)in_map;
		for (uint32_t o = 0; o < ENC_W * ENC_H; o++)
			in8[o] = card_luma(o % ENC_W, o / ENC_W, 0);
	} else if (strcmp(mode, "gradient") == 0) {
		volatile uint8_t *in8 = (volatile uint8_t *)in_map;
		for (uint32_t o = 0; o < IN_FILL_LEN; o++)
			in8[o] = (uint8_t)((o >> 6) ^ (o >> 12));
	}

	/* Clear the output region once so we can see what the encoder wrote. */
	dev_fill32(out_map, OUT_MAP_LEN, 0);

	FILE *f = NULL;
	if (outfile) {
		f = fopen(outfile, "wb");
		if (!f) { perror("fopen(out)"); return 1; }
	}

	uint32_t pass = 0, total_bytes = 0, p_bytes = 0, p_n = 0;
	for (uint32_t n = 0; n < nframes; n++) {
		uint32_t gopn = gop ? n % gop : n;
		int is_idr = (gopn == 0);

		if (strcmp(mode, "yuyv") == 0)
			fill_yuyv(in_map, n);

		struct exchange_parameter ex;
		memset(&ex, 0, sizeof ex);
		ex.module_type = VCMD_TYPE_ENCODER;
		if (ioctl(fd, HANTRO_IOCH_RESERVE_CMDBUF, &ex) < 0) { perror("RESERVE_CMDBUF"); break; }
		uint16_t id = ex.cmdbuf_id;

		/* Core register readback lands in our status slot; swreg9/82
		 * are read back from here after WAIT. */
		uint64_t core_dst = mem.status_hw_addr + (uint64_t)id * 0x2000 + (SUBMODULE_MAIN_ADDR / 2);
		memset(status_pool + STATUS_SLOT_REG_OFF(id, 0), 0, 512 * 4);

		struct vcenc_frame fr = {
			.frame_num = gopn, .qp = ENC_QP, .p17 = p17, .pinter = pinter,
		};
		uint32_t *slot = cmd_pool + (uint32_t)id * (mem.cmd_unit_size / 4);
		ex.cmdbuf_size = vcenc_build_encode_cmdbuf(slot, buf_delta, core_dst, &fr);
		ex.numa_id = 0;

		if (ioctl(fd, HANTRO_IOCH_LINK_RUN_CMDBUF, &ex) < 0) { perror("LINK_RUN_CMDBUF"); break; }
		uint16_t wid = id;
		if (ioctl(fd, HANTRO_IOCH_WAIT_CMDBUF, &wid) < 0) { perror("WAIT_CMDBUF"); break; }

		volatile uint32_t *rr = (volatile uint32_t *)(status_pool + STATUS_SLOT_REG_OFF(id, 0));
		uint32_t swreg9 = rr[9], swreg82 = rr[82];

		/* The HW writes the 4-byte start code at the stream base; the
		 * NAL header follows it. */
		volatile uint8_t *sb = (volatile uint8_t *)out_map + STREAM_OFF;
		int nut = sb[4] & 0x1f;

		int frame_ok = (wid == CMDBUF_EXE_STATUS_OK) && swreg82 > 0
			&& swreg9 > 0 && swreg9 <= OUT_LIMIT
			&& nut == (is_idr ? 5 : 1);
		printf("frame %3u: %s wait=%u bytes=%-6u cycles=%-8u nal=%d %s\n",
		       n, is_idr ? "IDR" : "P  ", wid, swreg9, swreg82, nut,
		       frame_ok ? "ok" : "FAIL");

		if (frame_ok && f) {
			if (is_idr) {
				uint8_t hdr[128];
				uint32_t hlen = vcenc_write_sps(hdr, ENC_W, ENC_H);
				hlen += vcenc_write_pps(hdr + hlen, ENC_QP);
				fwrite(hdr, 1, hlen, f);
				total_bytes += hlen;
			}
			uint8_t *slice = malloc(swreg9);
			for (uint32_t i = 0; i < swreg9; i++) slice[i] = sb[i];
			fwrite(slice, 1, swreg9, f);
			free(slice);
			total_bytes += swreg9;
		}
		if (frame_ok) {
			pass++;
			if (!is_idr) { p_bytes += swreg9; p_n++; }
		}

		uint16_t rid = id;
		if (ioctl(fd, HANTRO_IOCH_RELEASE_CMDBUF, &rid) < 0) perror("RELEASE_CMDBUF (non-fatal)");
		if (!frame_ok) break;
	}
	if (f) fclose(f);
	close(fd);

	int ok = (pass == nframes);
	printf("\nRESULT: %s -- %u/%u frames blob-free (%u stream bytes%s",
	       ok ? "PASS" : "FAIL", pass, nframes, total_bytes,
	       outfile && ok ? ", written" : "");
	if (p_n)
		printf("; avg P = %u bytes", p_bytes / p_n);
	printf(")\n");
	return ok ? 0 : 2;
}
