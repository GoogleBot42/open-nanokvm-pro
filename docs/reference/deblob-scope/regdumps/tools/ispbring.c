/* ispbring -- AX630C ISP/VIN bring-up experiment tool (our own /dev/mem pokes,
 * base-only boot ONLY). Each subcommand is one step so a hang identifies it.
 *
 *   st                       status snapshot
 *   r <addr>                 read32
 *   w <addr> <val>           write32 (then read back)
 *   mux                      ISP clk-src mux codes 5/5/3 via 0xC8/0xCC (MUX_RD -> 0x5af)
 *   gates <a> <b>            0xD0 <- a, 0xD8 <- b (W1S)
 *   de0 <mask> | de1 <mask>  per-bit DEASSERT rst0 (0xE4) / rst1 (0xEC), one write per bit
 *   as0 <mask> | as1 <mask>  per-bit ASSERT rst0 (0xE0) / rst1 (0xE8)
 *   p0 <bit> | p1 <bit>      pulse one line: assert then deassert
 *   axiq                     AXI quiesce: 0xFFFFFFFF -> 3 ctrl regs, poll 3 status regs
 *   axiz                     zero the 3 AXI ctrl regs
 *   hold <v>                 write 0x0440306C
 *   sifw                     write/readback probe on SIF 0x02406408 and WDMA 0x024140d4
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

static int fd;
static volatile uint32_t *map(unsigned long phys, unsigned long len)
{
	void *m = mmap(0, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, phys);
	if (m == MAP_FAILED) { perror("mmap"); exit(1); }
	return (volatile uint32_t *)m;
}
static volatile uint32_t *isp, *glb, *comm, *hold;
#define ISP(off) isp[(off) / 4]
#define GLB(off) glb[(off) / 4]
#define COMM(off) comm[(off) / 4]

static uint32_t rd(unsigned long phys)
{
	unsigned long pg = phys & ~0xfffUL;
	volatile uint32_t *m = map(pg, 0x1000);
	uint32_t v = m[(phys - pg) / 4];
	munmap((void *)m, 0x1000);
	return v;
}
static void wr(unsigned long phys, uint32_t val)
{
	unsigned long pg = phys & ~0xfffUL;
	volatile uint32_t *m = map(pg, 0x1000);
	m[(phys - pg) / 4] = val;
	munmap((void *)m, 0x1000);
}

static void status(void)
{
	printf("ispfile 0x02400000=%08x  sif 0x02406408=%08x  wdma 0x024140d4=%08x  ife-axi-st 0x02400188=%08x\n",
	       ISP(0x0), ISP(0x6408), ISP(0x140d4), ISP(0x188));
	printf("glb mux=%08x gA=%08x gB=%08x rst0st=%08x rst1st=%08x 0x84=%08x 0x90=%08x 0xa8=%08x 0xb0=%08x c0=%08x c4=%08x\n",
	       GLB(0x0), GLB(0x4), GLB(0x8), GLB(0xc), GLB(0x10), GLB(0x84), GLB(0x90), GLB(0xa8), GLB(0xb0), GLB(0xc0), GLB(0xc4));
	printf("comm 0x24=%08x 0x1e8=%08x 0x1f4=%08x 0x3d8=%08x 0x3f0=%08x\n",
	       COMM(0x24), COMM(0x1e8), COMM(0x1f4), COMM(0x3d8), COMM(0x3f0));
	fflush(stdout);
}

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage\n"); return 1; }
	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { perror("/dev/mem"); return 1; }
	isp = map(0x02400000, 0x100000);
	glb = map(0x02500000, 0x1000);
	comm = map(0x02340000, 0x1000);

	const char *c = argv[1];
	unsigned long a = argc > 2 ? strtoul(argv[2], 0, 0) : 0;
	unsigned long b = argc > 3 ? strtoul(argv[3], 0, 0) : 0;
	int i;

	if (!strcmp(c, "st")) status();
	else if (!strcmp(c, "r")) printf("%08lx=%08x\n", a, rd(a));
	else if (!strcmp(c, "w")) { wr(a, b); printf("%08lx<-%08lx rb=%08x\n", a, b, rd(a)); }
	else if (!strcmp(c, "mux")) {
		static const int sh[3] = { 8, 5, 2 }, code[3] = { 5, 5, 3 };
		for (i = 0; i < 3; i++) { GLB(0xcc) = 7u << sh[i]; GLB(0xc8) = (uint32_t)code[i] << sh[i]; }
		printf("mux_rd=%08x\n", GLB(0x0));
	}
	else if (!strcmp(c, "gates")) { GLB(0xd0) = a; GLB(0xd8) = b; printf("gA=%08x gB=%08x\n", GLB(0x4), GLB(0x8)); }
	else if (!strcmp(c, "de0")) { for (i = 0; i < 32; i++) if (a & (1u << i)) { GLB(0xe4) = 1u << i; } printf("rst0st=%08x\n", GLB(0xc)); }
	else if (!strcmp(c, "de1")) { for (i = 0; i < 32; i++) if (a & (1u << i)) { GLB(0xec) = 1u << i; } printf("rst1st=%08x\n", GLB(0x10)); }
	else if (!strcmp(c, "as0")) { for (i = 0; i < 32; i++) if (a & (1u << i)) { GLB(0xe0) = 1u << i; } printf("rst0st=%08x\n", GLB(0xc)); }
	else if (!strcmp(c, "as1")) { for (i = 0; i < 32; i++) if (a & (1u << i)) { GLB(0xe8) = 1u << i; } printf("rst1st=%08x\n", GLB(0x10)); }
	else if (!strcmp(c, "p0")) { GLB(0xe0) = 1u << a; GLB(0xe4) = 1u << a; printf("p0 bit%lu rst0st=%08x\n", a, GLB(0xc)); }
	else if (!strcmp(c, "p1")) { GLB(0xe8) = 1u << a; GLB(0xec) = 1u << a; printf("p1 bit%lu rst1st=%08x\n", a, GLB(0x10)); }
	else if (!strcmp(c, "axiq")) {
		ISP(0x184) = 0xffffffff; ISP(0x80144) = 0xffffffff; ISP(0xc0148) = 0xffffffff;
		for (i = 0; i < 51; i++) { if (!ISP(0x188) && !ISP(0x80148) && !ISP(0xc014c)) break; usleep(200); }
		printf("axiq iter=%d st=%08x %08x %08x\n", i, ISP(0x188), ISP(0x80148), ISP(0xc014c));
	}
	else if (!strcmp(c, "axiz")) { ISP(0x184) = 0; ISP(0x80144) = 0; ISP(0xc0148) = 0; printf("axi ctrl zeroed\n"); }
	else if (!strcmp(c, "hold")) { hold = map(0x04403000, 0x1000); hold[0x6c / 4] = a; printf("hold=%08x\n", hold[0x6c / 4]); }
	else if (!strcmp(c, "sifw")) {
		uint32_t o1 = ISP(0x6408), o2 = ISP(0x140d4);
		ISP(0x6408) = 0x5; ISP(0x140d4) = 0x0e8fc000;
		printf("sif 0x6408: was %08x wrote 5 rb=%08x | wdma 0xd4: was %08x wrote 0e8fc000 rb=%08x\n", o1, ISP(0x6408), o2, ISP(0x140d4));
		ISP(0x6408) = o1 == 0xdeadbeef ? 0 : o1; ISP(0x140d4) = o2 == 0xdeadbeef ? 0 : o2;
	}
	else { fprintf(stderr, "unknown cmd\n"); return 1; }
	return 0;
}
