/* replay -- replay selected ranges of our own vendor-live ISP register-file
 * snapshot (regfile-vendor-live.bin, /dev/mem observation) into the live ISP
 * file on a base-only boot, with the WDMA chn8 address pointed at OUR buffer,
 * then poll for frame-done and inspect the buffer.  Experiment tool only.
 *
 *   replay <golden.bin> <bufphys> [outfile]
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define FILE_LEN 0xd4008

int main(int argc, char **argv)
{
	if (argc < 3) { fprintf(stderr, "usage: replay golden.bin bufphys [out]\n"); return 1; }
	FILE *f = fopen(argv[1], "rb");
	if (!f) { perror("golden"); return 1; }
	uint32_t *g = malloc(FILE_LEN);
	if (fread(g, 1, FILE_LEN, f) != FILE_LEN) { fprintf(stderr, "short golden\n"); return 1; }
	fclose(f);
	unsigned long buf = strtoul(argv[2], 0, 0);

	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { perror("/dev/mem"); return 1; }
	volatile uint32_t *isp = mmap(0, 0x100000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0x02400000);
	if (isp == MAP_FAILED) { perror("mmap isp"); return 1; }

	/* zero our buffer first so any nonzero byte afterwards is DMA-written */
	{
		unsigned long blen0 = 3840UL * 2160 * 2;
		volatile uint32_t *z = mmap(0, blen0, PROT_READ | PROT_WRITE, MAP_SHARED, fd, buf);
		if (z == MAP_FAILED) { perror("mmap buf rw"); return 1; }
		/* word loop, NOT memset: glibc memset uses DC ZVA which SIGBUSes on a Device mapping */
		for (unsigned long i = 0; i < blen0 / 4; i++) z[i] = 0;
		munmap((void *)z, blen0);
	}

	/* ranges to replay (file offsets), in this order */
	struct { uint32_t lo, hi; } R[] = {
		{ 0x150, 0x200 },	/* ISP top config (mask regs + 0x160..0x1c0) */
		{ 0x1000, 0x1100 },	/* top block 1 */
		{ 0xd1000, 0xd2000 },	/* AXI/DMA-looking block (0x024d1xxx) */
		{ 0xc0000, 0xc1000 },	/* YUV top (mask/int regs) */
		{ 0x80000, 0x81000 },	/* ITP top (int regs) */
		{ 0x1b000, 0x22000 },	/* LUT/table blocks */
		{ 0x6000, 0x7000 },	/* SIF */
		{ 0x14000, 0x15000 },	/* IFE + WDMA */
	};
	int n = 0, skipped = 0;
	for (unsigned r = 0; r < sizeof(R) / sizeof(R[0]); r++) {
		for (uint32_t off = R[r].lo; off < R[r].hi; off += 4) {
			uint32_t v = g[off / 4];
			if (off == 0x140d4) v = (uint32_t)(buf >> 3);	/* our buffer */
			if (off == 0x6404 || off == 0x6408) { skipped++; continue; } /* SIF start/stop strobes: last */
			if (v == 0 && isp[off / 4] == 0) continue;
			isp[off / 4] = v;
			n++;
		}
	}
	/* verify a few */
	printf("replayed %d words (skipped %d). rb: 0x150=%08x wdma addr=%08x en=%08x go=%08x sif win=%08x\n",
	       n, skipped, isp[0x150 / 4], isp[0x140d4 / 4], isp[0x140dc / 4], isp[0x146dc / 4], isp[0x6518 / 4]);
	/* int: disable all enables, clear all, then read raw later */
	for (int k = 0; k < 10; k++) { isp[(0x10 * k + 0x10) / 4] = 0; isp[(0x10 * k + 0x14) / 4] = 0xffffffff; }
	/* SIF start (spec: STOP then START then CTRL arm) */
	isp[0x6408 / 4] = 1; isp[0x6404 / 4] = 1;
	/* poll raw frame-done grp4 bit9 and FSOF grp1 bit0 */
	uint32_t raw4 = 0, raw1 = 0;
	for (int i = 0; i < 100; i++) {
		raw4 |= isp[(0x10 * 4 + 0x18) / 4];
		raw1 |= isp[(0x10 * 1 + 0x18) / 4];
		usleep(10000);
	}
	printf("after 1s: raw grp1=%08x grp4=%08x  wdma addr now=%08x shadow=%08x\n", raw1, raw4,
	       isp[0x140d4 / 4], isp[0x140d8 / 4]);

	/* inspect buffer: 3840x2160 YUYV = 0xFD2000 bytes */
	unsigned long blen = 3840UL * 2160 * 2;
	volatile uint8_t *b = mmap(0, blen, PROT_READ, MAP_SHARED, fd, buf);
	if (b == MAP_FAILED) { perror("mmap buf"); return 1; }
	unsigned long nz = 0;
	for (unsigned long i = 0; i < blen; i += 64) if (b[i]) nz++;
	printf("buffer @%lx: %lu of %lu sampled bytes nonzero; first 32: ", buf, nz, blen / 64);
	for (int i = 0; i < 32; i++) printf("%02x", b[i]);
	printf("\n");
	if (argc > 3) {	/* decimated Y plane 480x270 */
		FILE *o = fopen(argv[3], "wb");
		for (int y = 0; y < 2160; y += 8)
			for (int x = 0; x < 3840; x += 8)
				fputc(b[(unsigned long)y * 7680 + x * 2], o);
		fclose(o);
	}
	return 0;
}
