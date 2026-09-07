// SPDX-License-Identifier: GPL-2.0
/*
 * NanoKVM-Pro mainline bring-up init (#75, epic #26).
 *
 * PID 1 of the initramfs baked into `.#kernel-mainline`. It is not a boot
 * loader for anything: the mainline kernel has no storage driver yet (#76), so
 * there is no root filesystem to switch to. Its only job is to be OBSERVABLE
 * from the vendor system that boots after it.
 *
 * There is no serial console on this unit (the UART0 pads are hidden), so a
 * first mainline boot has no live output at all. Three channels replace it,
 * all read back from the vendor rootfs on the FOLLOWING boot:
 *
 *   1. Milestone bits in TOP_CHIPMODE_GLB_BACKUP0, the same always-on register
 *      that carries the A/B slot state. Bits 12..15 are unused by every stage
 *      of the vendor boot chain and survive a warm reset -- proven on hardware
 *      2026-09-06. `devmem 0x02390024` from the vendor system reads them.
 *   2. A verbatim copy of the kernel log, stashed in reserved DRAM at
 *      LOG_STASH_PHYS. DRAM survives the reboot (same experiment), and this
 *      window is reserved by BOTH device trees, so nothing overwrites it.
 *   3. The heartbeat LED, for a human watching the board.
 *
 * Channel 2 is what channel 1 cannot be: the whole boot log, from the first
 * printk. It only exists if userspace ran. If it did not, the same window's
 * ramoops zones (dts/ax630c-nanokvm-pro.dts) hold the console and any panic.
 *
 * Then it reboots. The SPL consumed SLOTB_BOOTABLE on the way in and nothing
 * here re-arms it, so the next boot is slot A -- the vendor system -- whether
 * this program reaches its reboot() or dies anywhere before it. That is the
 * whole safety argument for the test: every path out of here lands on slot A.
 *
 * Freestanding-ish by design: static musl, no /proc or /sys dependency beyond
 * two optional reads, and it makes its own device nodes rather than requiring
 * CONFIG_DEVTMPFS. It must not need anything the mainline port has not built.
 */

#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

/* ---------------------------------------------------------------------------
 * Physical addresses. Every one of these is a hardware fact recorded in
 * docs/mainline-port.md or docs/reference/mainline/; none is discoverable at
 * runtime on a kernel with no drivers for the blocks involved.
 * ------------------------------------------------------------------------- */

/*
 * TOP_CHIPMODE_GLB_BACKUP0 -- the A/B slot register. +0x4 is a write-1-to-set
 * alias and +0x8 a write-1-to-clear alias, so a milestone never needs a
 * read-modify-write and can never disturb the slot bits.
 */
#define CHIPMODE_PAGE		0x02390000u
#define BACKUP0_OFF		0x24
#define BACKUP0_SET_OFF		0x28
#define BACKUP0_CLR_OFF		0x2c

/*
 * Milestone bits. The boot chain defines bits 0..11 (BOOT_INDEX, SLOT*,
 * BOOT_SD, BOOT_KERNEL_FAIL, BOOT_DOWNLOAD, BOOT_PANIC, BOOT_WDT_TIMEOUT,
 * BOOT_RECOVERY) and 30..31 (OTA_*); 12..29 are written by nothing in the SPL,
 * ATF, U-Boot, the RISC-V companion or the vendor kernel.
 */
#define MS_USERSPACE		(1u << 12)	/* this program started, and /dev/mem works */
#define MS_LOG_STASHED		(1u << 13)	/* the kernel log is in DRAM */
#define MS_LED			(1u << 14)	/* the LED loop completed */
#define MS_REBOOTING		(1u << 15)	/* reboot(2) is about to be called */

/*
 * GPIO0, one 32-bit word per line at base + (n + 1) * 4. GPIO0_A23 is the
 * "sys-heartbeat" LED, active high; bit 0 is the output value and bit 1 is the
 * direction (1 = output), which is also the output enable. The pad is already
 * muxed to GPIO0_A23 by the bootloader's pad table and the block's clock and
 * reset are already on, so no pinmux or clock write is needed.
 */
#define GPIO0_PAGE		0x04800000u
#define GPIO0_LED_OFF		(( 23 + 1) * 4)	/* 0x60 */
#define GPIO_DR			(1u << 0)
#define GPIO_DDR		(1u << 1)

/*
 * Kernel-log stash. Inside the reserved window both device trees keep, past
 * the ramoops zones. See dts/ax630c-nanokvm-pro.dts for the split.
 */
#define LOG_STASH_PHYS		0x480e8000u
#define LOG_STASH_SIZE		0x8000u
#define LOG_STASH_MAGIC		"OPENKVM-MAINLINE-LOG1"	/* 21 bytes + NUL */
#define LOG_STASH_HDR		32			/* magic, then a u32 length at +24 */

/* Blink for long enough that a human who looked away still catches it. */
#define BLINK_SECONDS		15

static int kmsg_fd = -1;

/* ------------------------------------------------------------------------- */

static void kmsg(const char *s)
{
	if (kmsg_fd >= 0)
		(void)write(kmsg_fd, s, strlen(s));
}

static void kmsg_hex(const char *label, uint32_t v)
{
	static const char hex[] = "0123456789abcdef";
	char buf[128];
	size_t n = 0;
	int i;

	while (*label && n < sizeof(buf) - 12)
		buf[n++] = *label++;
	buf[n++] = '0';
	buf[n++] = 'x';
	for (i = 28; i >= 0; i -= 4)
		buf[n++] = hex[(v >> i) & 0xf];
	buf[n++] = '\n';
	if (kmsg_fd >= 0)
		(void)write(kmsg_fd, buf, n);
}

static void nap(long sec, long nsec)
{
	struct timespec ts = { .tv_sec = sec, .tv_nsec = nsec };

	while (nanosleep(&ts, &ts) == -1)
		;
}

/*
 * Volatile word accesses only. glibc's memset/memcpy use DC ZVA, which SIGBUSes
 * on a Device-memory /dev/mem mapping; the stash is ordinary cached DRAM and
 * would tolerate them, but one accessor for both kinds of window is one fewer
 * thing to get wrong.
 */
static inline uint32_t rd32(volatile void *p)
{
	return *(volatile uint32_t *)p;
}

static inline void wr32(volatile void *p, uint32_t v)
{
	*(volatile uint32_t *)p = v;
}

static void *map_phys(int fd, uint32_t phys, size_t len)
{
	void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
		       (off_t)phys);

	return p == MAP_FAILED ? NULL : p;
}

/* ------------------------------------------------------------------------- */

int main(void)
{
	volatile uint8_t *chipmode = NULL, *gpio0 = NULL, *stash = NULL;
	int memfd, i;

	/*
	 * Make the two device nodes rather than requiring devtmpfs. Both are
	 * fixed majors/minors, so this works on the barest possible kernel.
	 */
	(void)mkdir("/dev", 0755);
	(void)mknod("/dev/kmsg", S_IFCHR | 0600, makedev(1, 11));
	(void)mknod("/dev/mem", S_IFCHR | 0600, makedev(1, 1));

	kmsg_fd = open("/dev/kmsg", O_WRONLY | O_CLOEXEC);
	kmsg("openkvm: mainline bring-up init (#75) running\n");

	/*
	 * /proc is not needed for anything below; it is mounted so the two
	 * facts a bring-up most wants -- the cmdline U-Boot actually passed and
	 * the kernel identity -- land in the log stash, which is the only place
	 * anyone will ever read them from.
	 */
	if (mount("proc", "/proc", "proc", 0, NULL) == 0) {
		static const char *echo[] = { "/proc/cmdline", "/proc/version" };
		char buf[1024];
		size_t k;

		for (k = 0; k < sizeof(echo) / sizeof(echo[0]); k++) {
			int fd = open(echo[k], O_RDONLY | O_CLOEXEC);
			ssize_t n;

			if (fd < 0)
				continue;
			n = read(fd, buf, sizeof(buf) - 1);
			close(fd);
			if (n <= 0)
				continue;
			buf[n] = '\0';
			kmsg("openkvm: ");
			kmsg(echo[k]);
			kmsg(": ");
			kmsg(buf);
			if (buf[n - 1] != '\n')
				kmsg("\n");
		}
	} else {
		kmsg("openkvm: WARNING: /proc mount failed\n");
	}

	memfd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
	if (memfd < 0) {
		/*
		 * Nothing below can run. Say so and reboot -- the boot still
		 * counts as a partial success if the log stash is empty but the
		 * ramoops console zone holds this line.
		 */
		kmsg("openkvm: FATAL: cannot open /dev/mem (CONFIG_DEVMEM? STRICT_DEVMEM?)\n");
		nap(2, 0);
		reboot(RB_AUTOBOOT);
		for (;;)
			nap(60, 0);
	}

	chipmode = map_phys(memfd, CHIPMODE_PAGE, 0x1000);
	gpio0 = map_phys(memfd, GPIO0_PAGE, 0x1000);
	stash = map_phys(memfd, LOG_STASH_PHYS, LOG_STASH_SIZE);

	/*
	 * Milestone 1. This is the single bit the whole test turns on: it can
	 * only be set by code running in userspace on this kernel, through a
	 * mapping this kernel set up, and it is still readable from the vendor
	 * system two boots later.
	 */
	if (chipmode) {
		wr32(chipmode + BACKUP0_SET_OFF, MS_USERSPACE);
		kmsg_hex("openkvm: BACKUP0 after milestone 1: ",
			 rd32(chipmode + BACKUP0_OFF));
	} else {
		kmsg("openkvm: FATAL: cannot map the chipmode window\n");
	}

	/*
	 * Milestone 2: copy the kernel log into the stash. Reading /dev/kmsg
	 * from offset 0 replays the ring buffer from its oldest surviving
	 * record, so this captures the boot from the first printk -- earlier
	 * than pstore's console, which only starts at its own registration.
	 */
	if (stash) {
		uint32_t used = 0;
		int fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK | O_CLOEXEC);

		for (i = 0; i < LOG_STASH_HDR; i++)
			((volatile uint8_t *)stash)[i] = 0;
		for (i = 0; LOG_STASH_MAGIC[i]; i++)
			((volatile uint8_t *)stash)[i] = (uint8_t)LOG_STASH_MAGIC[i];

		if (fd >= 0) {
			char rec[8192];
			ssize_t n;

			(void)lseek(fd, 0, SEEK_SET);
			while (used + LOG_STASH_HDR < LOG_STASH_SIZE) {
				n = read(fd, rec, sizeof(rec));
				if (n <= 0)
					break;	/* EAGAIN = caught up */
				if (used + LOG_STASH_HDR + (uint32_t)n >
				    LOG_STASH_SIZE)
					n = (ssize_t)(LOG_STASH_SIZE -
						      LOG_STASH_HDR - used);
				for (i = 0; i < n; i++)
					((volatile uint8_t *)stash)
						[LOG_STASH_HDR + used + i] =
							(uint8_t)rec[i];
				used += (uint32_t)n;
			}
			close(fd);
		}

		wr32(stash + 24, used);

		/*
		 * The mapping is write-combining (arm64 gives O_SYNC /dev/mem
		 * over mapped RAM Normal-NonCacheable), so the stores are not
		 * held in a dirty cache line -- but they can sit in a write
		 * buffer. Drain it here rather than trusting the reboot path,
		 * which on this SoC may be a raw chip reset.
		 */
		__sync_synchronize();
		(void)msync((void *)stash, LOG_STASH_SIZE, MS_SYNC);
		kmsg_hex("openkvm: kernel log stashed, bytes: ", used);
		if (chipmode)
			wr32(chipmode + BACKUP0_SET_OFF, MS_LOG_STASHED);
	} else {
		kmsg("openkvm: WARNING: cannot map the log stash window\n");
	}

	/* Milestone 3: a distinctive blink -- three short, one long, repeat. */
	if (gpio0) {
		volatile void *led = gpio0 + GPIO0_LED_OFF;
		uint32_t base = rd32(led) & ~(GPIO_DR | GPIO_DDR);
		long elapsed = 0;

		kmsg("openkvm: blinking sys-heartbeat (GPIO0_A23)\n");
		while (elapsed < BLINK_SECONDS * 1000) {
			for (i = 0; i < 3; i++) {
				wr32(led, base | GPIO_DDR | GPIO_DR);
				nap(0, 120000000L);
				wr32(led, base | GPIO_DDR);
				nap(0, 180000000L);
				elapsed += 300;
			}
			wr32(led, base | GPIO_DDR | GPIO_DR);
			nap(0, 700000000L);
			wr32(led, base | GPIO_DDR);
			nap(0, 400000000L);
			elapsed += 1100;
		}
		wr32(led, base | GPIO_DDR);
		if (chipmode)
			wr32(chipmode + BACKUP0_SET_OFF, MS_LED);
	} else {
		kmsg("openkvm: WARNING: cannot map GPIO0; no LED\n");
	}


	/*
	 * Milestone 4, then reboot. reboot(2) is itself a test: PSCI on this
	 * ATF implements no SYSTEM_RESET, so the reset can only come from the
	 * watchdog driver's restart handler. If that handler is broken the call
	 * hangs -- and the watchdog, no longer petted once the ping worker
	 * stops, resets the SoC anyway within its timeout. Either way the next
	 * boot is slot A.
	 */
	if (chipmode)
		wr32(chipmode + BACKUP0_SET_OFF, MS_REBOOTING);
	kmsg("openkvm: rebooting via the restart handler\n");
	sync();
	nap(1, 0);
	reboot(RB_AUTOBOOT);

	kmsg("openkvm: reboot(2) returned -- waiting for the watchdog\n");
	for (;;)
		nap(60, 0);
}
