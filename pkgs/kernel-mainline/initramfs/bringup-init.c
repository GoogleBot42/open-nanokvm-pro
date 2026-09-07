// SPDX-License-Identifier: GPL-2.0
/*
 * NanoKVM-Pro mainline bring-up init (#75, #76, #77, #82; epic #26).
 *
 * PID 1 of the initramfs baked into `.#kernel-mainline`. It is not a boot
 * loader for anything: there is no mainline root filesystem to switch to yet
 * (#78). Its job is to be OBSERVABLE from the vendor system that boots after
 * it -- and, since #77, to be reachable while it runs.
 *
 * #77 added, in order: bring eth0 up with the MAC harvested off the vendor
 * rootfs #76 already mounts, take a DHCP lease (the same lease, because the
 * same MAC), prove a round trip, and start dropbear with root's password hash
 * harvested from the same place. So tools/kvmssh reaches the mainline system
 * at the address and password it already knows, and no credential of any kind
 * is built into the image.
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

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <sys/wait.h>
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
#define MS_BLKDEV		(1u << 16)	/* #76: the eMMC produced a partitioned block device */
#define MS_ROOTFS_RO		(1u << 17)	/* #76: ext4 on it mounted read-only and read */
#define MS_NET_LINK		(1u << 18)	/* #77: eth0 exists and the PHY negotiated carrier */
#define MS_NET_ADDR		(1u << 19)	/* #77: a DHCP lease was taken and configured */
#define MS_NET_PING		(1u << 20)	/* #77: ICMP round trip to another host on the LAN */
#define MS_SSHD			(1u << 21)	/* #77: dropbear started */
#define MS_UDC			(1u << 22)	/* #82: a USB device controller registered */
#define MS_GADGET		(1u << 23)	/* #82: a HID gadget was built and bound to it */
#define MS_USB_ATTACHED		(1u << 24)	/* #82: a host enumerated and configured it */

/*
 * Storage probe (#76). Read-only throughout: the eMMC carries the running
 * vendor system, and this excursion must leave it exactly as it found it.
 *
 * Note the partition is located by NAME out of /proc/partitions rather than by
 * assuming a minor number. Nothing guarantees a mainline kernel enumerates the
 * three SD4HC instances in the vendor's order, and mknod()ing a guessed minor
 * would either fail confusingly or -- much worse -- succeed against the wrong
 * device.
 */
#define ROOT_PART_NAME		"mmcblk0p17"
#define PROBE_DEV		"/dev/probe-root"
#define PROBE_MNT		"/mnt"
#define BLKDEV_WAIT_SECONDS	10
#define BLKDEV_POLL_MS		200

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

/*
 * Network bring-up (#77). The interface name is the kernel's own: there is no
 * udev in here, so the one stmmac netdev is eth0.
 */
#define NET_IFACE		"eth0"
#define NET_CARRIER_SECONDS	20
#define DHCP_RESULT		"/run/dhcp.result"
#define SSH_HOST_KEY		"/etc/dropbear/host_key_ed25519"

/*
 * USB gadget (#82). Three questions, deliberately separated, because they fail
 * for completely different reasons and only the third depends on anything
 * outside this board:
 *
 *   MS_UDC          the dwc3 glue probed, the core bound, and a device
 *                   controller registered. Pure kernel-side.
 *   MS_GADGET       every function driver usbdev.sh needs is present, a HID
 *                   keyboard gadget was assembled through configfs, and
 *                   writing the controller's name to g0/UDC succeeded --
 *                   which is what starts the gadget and pulls up D+.
 *   MS_USB_ATTACHED the UDC reached state "configured": a host on the other
 *                   end of the cable enumerated us and selected a
 *                   configuration.
 *
 * That last one is the only one a bad cable can take away, and the physical
 * USB link on this unit has been unreliable since 2026-09-05 (#42 was a
 * physical fault). So a run with 22 and 23 set and 24 clear says "the port
 * works, look at the cable", not "USB is broken".
 */
#define CONFIGFS_MNT		"/sys/kernel/config"
#define GADGET_DIR		CONFIGFS_MNT "/usb_gadget/g0"
#define UDC_CLASS_DIR		"/sys/class/udc"
#define UDC_WAIT_SECONDS	10
#define UDC_POLL_MS		200
/* How long to give a host to enumerate once the gadget is bound. */
#define USB_ATTACH_SECONDS	15

/*
 * Linux Foundation's own gadget vendor/product pair, the one every configfs
 * example uses. Deliberately not a Sipeed id: this gadget is not the vendor's
 * and must not claim to be. `lsusb` on the attached host shows it as "Linux
 * Foundation Multifunction Composite Gadget", and the product string below
 * makes it unmistakable.
 */
#define GADGET_VID		"0x1d6b"
#define GADGET_PID		"0x0104"
#define GADGET_PRODUCT		"NanoKVM-Pro mainline bring-up"
#define GADGET_MANUFACTURER	"open-nanokvm-pro"

/*
 * Identity is HARVESTED, never built in. The vendor rootfs on the eMMC carries
 * both facts this program needs, and #76's probe already mounts it read-only:
 *
 *   /etc/network/interfaces  "hwaddress ether ..."  -- eth0's provisioned MAC
 *   /etc/shadow              root's password hash
 *
 * Taking the vendor MAC means the DHCP server hands back the same lease, so
 * the mainline system answers on the address tools/kvmssh already knows;
 * taking the hash means it answers to the same password. Neither ever touches
 * the build, the Nix store or this repository.
 */
#define VENDOR_IFACES_FILE	PROBE_MNT "/etc/network/interfaces"
#define VENDOR_SHADOW_FILE	PROBE_MNT "/etc/shadow"

/*
 * How long to stay alive before rebooting, blinking throughout.
 *
 * This is the watchdog test, not a courtesy to whoever is watching the LED.
 * U-Boot arms wdt0 at 30 s per stage, so anything under a minute proves only
 * that the board can boot -- it says nothing about whether the driver adopted
 * the running dog and the watchdog core is petting it. Outliving the
 * bootloader's arm by 2x is the evidence. #77 lengthened it from 120 s because
 * the dwell is now also the window in which a human logs in over SSH.
 *
 * Touching KEEPALIVE_FILE from that shell extends the dwell to the hard cap,
 * which exists so that a forgotten session still lands the board back on slot
 * A rather than leaving it on a rootfs-less kernel indefinitely.
 */
#define DWELL_SECONDS		300
#define DWELL_MAX_SECONDS	3600
#define KEEPALIVE_FILE		"/run/keepalive"

/* One liveness line to the log every this many seconds of the dwell. */
#define HEARTBEAT_SECONDS	10

static int kmsg_fd = -1;

/* Harvested off the vendor rootfs by probe_storage(); see VENDOR_*_FILE. */
static char harvest_mac[24];
static char harvest_shadow[512];

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

/*
 * Read the first line of a file into buf, NUL-terminated, newline stripped.
 * Returns 0 on success. Used only for the two watchdog sysfs attributes, so a
 * failure is reported in the log rather than treated as fatal.
 */
static int read_line(const char *path, char *buf, size_t len)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	ssize_t n;

	if (fd < 0)
		return -1;
	n = read(fd, buf, len - 1);
	close(fd);
	if (n <= 0)
		return -1;
	while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r'))
		n--;
	buf[n] = '\0';

	return 0;
}

/*
 * Read a whole (small) file into buf, NUL-terminated. Returns the byte count,
 * or -1. Used for the two vendor-rootfs files and the DHCP result.
 */
static ssize_t slurp(const char *path, char *buf, size_t len)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	ssize_t total = 0, n;

	if (fd < 0)
		return -1;
	while ((size_t)total < len - 1) {
		n = read(fd, buf + total, len - 1 - (size_t)total);
		if (n <= 0)
			break;
		total += n;
	}
	close(fd);
	buf[total] = '\0';

	return total;
}

/* Copy one whitespace-delimited token out of s into out. */
static void copy_token(const char *s, char *out, size_t len)
{
	size_t i = 0;

	while (*s == ' ' || *s == '\t')
		s++;
	while (i < len - 1 && *s && *s != ' ' && *s != '\t' && *s != '\n' &&
	       *s != '\r')
		out[i++] = *s++;
	out[i] = '\0';
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

/*
 * Copy the kernel log into the reserved-DRAM stash, replacing whatever was
 * there. Reading /dev/kmsg from offset 0 replays the ring buffer from its
 * oldest surviving record, so this captures the boot from the first printk --
 * earlier than pstore's console, which only starts at its own registration.
 *
 * Callable more than once: each call rewrites the header and the length, so a
 * later call simply supersedes an earlier one with a longer log.
 */
static uint32_t stash_klog(volatile uint8_t *stash)
{
	uint32_t used = 0;
	int fd = open("/dev/kmsg", O_RDONLY | O_NONBLOCK | O_CLOEXEC);
	ssize_t i;

	for (i = 0; i < LOG_STASH_HDR; i++)
		stash[i] = 0;
	for (i = 0; LOG_STASH_MAGIC[i]; i++)
		stash[i] = (uint8_t)LOG_STASH_MAGIC[i];

	if (fd >= 0) {
		char rec[8192];
		ssize_t n;

		(void)lseek(fd, 0, SEEK_SET);
		while (used + LOG_STASH_HDR < LOG_STASH_SIZE) {
			n = read(fd, rec, sizeof(rec));
			if (n <= 0)
				break;	/* EAGAIN = caught up */
			if (used + LOG_STASH_HDR + (uint32_t)n > LOG_STASH_SIZE)
				n = (ssize_t)(LOG_STASH_SIZE - LOG_STASH_HDR -
					      used);
			for (i = 0; i < n; i++)
				stash[LOG_STASH_HDR + used + i] =
					(uint8_t)rec[i];
			used += (uint32_t)n;
		}
		close(fd);
	}

	wr32(stash + 24, used);

	/*
	 * The mapping is write-combining (arm64 gives O_SYNC /dev/mem over
	 * mapped RAM Normal-NonCacheable), so the stores are not held in a
	 * dirty cache line -- but they can sit in a write buffer. Drain it here
	 * rather than trusting the reboot path, which on this SoC may be a raw
	 * chip reset.
	 */
	__sync_synchronize();
	(void)msync((void *)stash, LOG_STASH_SIZE, MS_SYNC);

	return used;
}

/* --- storage probe (#76) ------------------------------------------------- */

/*
 * Emit /proc/partitions to the kernel log one record per line. This is the
 * primary evidence that the mmc host bound, the card enumerated and the
 * partition scanner ran -- all three, in one artifact, readable from the stash
 * two boots later.
 */
static void log_partitions(void)
{
	char buf[4096];
	ssize_t n;
	int fd = open("/proc/partitions", O_RDONLY | O_CLOEXEC);
	ssize_t i, start;

	if (fd < 0) {
		kmsg("openkvm: storage: /proc/partitions unreadable\n");
		return;
	}
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0) {
		kmsg("openkvm: storage: /proc/partitions empty\n");
		return;
	}
	buf[n] = '\0';

	/*
	 * ONE write() per line, prefix included. Three writes would be three
	 * kmsg records, and the prefix would arrive as its own empty-looking
	 * line with the data orphaned in the record after it -- which is
	 * exactly how the first #76 run reported a working eMMC as four blank
	 * "part:" lines.
	 */
	for (start = 0, i = 0; i < n; i++) {
		char line[256];
		size_t len, pfx;

		if (buf[i] != '\n')
			continue;
		if (i > start) {
			static const char prefix[] = "openkvm: part:";
			pfx = sizeof(prefix) - 1;
			len = (size_t)(i - start);
			if (len > sizeof(line) - pfx - 2)
				len = sizeof(line) - pfx - 2;
			memcpy(line, prefix, pfx);
			memcpy(line + pfx, buf + start, len);
			line[pfx + len] = '\n';
			if (kmsg_fd >= 0)
				(void)write(kmsg_fd, line, pfx + len + 1);
		}
		start = i + 1;
	}
}

/*
 * Find a partition by name in /proc/partitions. Returns 0 and fills maj/min on
 * success. The file's columns are "major minor #blocks name".
 */
static int find_partition(const char *want, unsigned *maj, unsigned *min)
{
	char buf[4096];
	ssize_t n;
	int fd = open("/proc/partitions", O_RDONLY | O_CLOEXEC);
	char *p;

	if (fd < 0)
		return -1;
	n = read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return -1;
	buf[n] = '\0';

	for (p = buf; *p; ) {
		char *eol = strchr(p, '\n');
		unsigned a = 0, b = 0;
		char name[64];

		if (!eol)
			break;
		*eol = '\0';
		if (sscanf(p, " %u %u %*u %63s", &a, &b, name) == 3 &&
		    strcmp(name, want) == 0) {
			*maj = a;
			*min = b;
			return 0;
		}
		p = eol + 1;
	}

	return -1;
}

/*
 * Take the board's two identity facts off the mounted vendor rootfs (#77).
 * Called with PROBE_MNT still mounted, read-only.
 *
 * The MAC is a provisioning-time literal in /etc/network/interfaces -- it is
 * NOT derived from the SoC UID at boot, whatever the vendor's USB-gadget
 * scripts do for their own NCM/RNDIS addresses. So reading the file is not a
 * shortcut around a computation; it is the only place the value exists.
 *
 * The hash is logged by length only. Nothing here ever prints it.
 */
static void harvest_identity(void)
{
	static char buf[16384];
	char *p;

	if (slurp(VENDOR_IFACES_FILE, buf, sizeof(buf)) > 0) {
		p = strstr(buf, "hwaddress ether");
		if (p) {
			copy_token(p + sizeof("hwaddress ether") - 1,
				   harvest_mac, sizeof(harvest_mac));
			kmsg_hex("openkvm: net: harvested MAC, length: ",
				 (uint32_t)strlen(harvest_mac));
		}
	}
	if (!harvest_mac[0])
		kmsg("openkvm: net: WARNING no hwaddress in the vendor "
		     "interfaces file; the lease will not be the usual one\n");

	if (slurp(VENDOR_SHADOW_FILE, buf, sizeof(buf)) > 0) {
		for (p = buf; p && *p; ) {
			char *eol = strchr(p, '\n');

			if (strncmp(p, "root:", 5) == 0) {
				size_t n = eol ? (size_t)(eol - p)
					       : strlen(p);

				if (n < sizeof(harvest_shadow) - 2) {
					memcpy(harvest_shadow, p, n);
					harvest_shadow[n] = '\n';
					harvest_shadow[n + 1] = '\0';
				}
				break;
			}
			p = eol ? eol + 1 : NULL;
		}
		kmsg_hex("openkvm: net: harvested root shadow entry, length: ",
			 (uint32_t)strlen(harvest_shadow));
	}
	if (!harvest_shadow[0])
		kmsg("openkvm: net: WARNING no root entry in the vendor "
		     "shadow file; SSH password login will fail\n");
}

/*
 * Wait for the eMMC rootfs partition, then mount it read-only and read it.
 *
 * Everything here is deliberately non-fatal: this is a bring-up probe, and a
 * board that cannot mount its rootfs must still complete the dwell so that the
 * watchdog evidence from #75 stays valid. Failures are logged and the milestone
 * bit simply stays clear, which is a result, not a crash.
 */
static void probe_storage(volatile uint8_t *chipmode)
{
	unsigned maj = 0, min = 0;
	int waited_ms = 0;
	int rc;
	DIR *d;
	int entries = 0;

	/*
	 * MMC probing is asynchronous and card identification takes tens of
	 * milliseconds, so the partition is not there the instant /init runs.
	 * Poll rather than sleep a fixed time: the elapsed figure in the log is
	 * itself diagnostic if a later kernel gets slower.
	 */
	while (waited_ms < BLKDEV_WAIT_SECONDS * 1000) {
		if (find_partition(ROOT_PART_NAME, &maj, &min) == 0)
			break;
		nap(0, BLKDEV_POLL_MS * 1000000L);
		waited_ms += BLKDEV_POLL_MS;
	}

	log_partitions();

	if (find_partition(ROOT_PART_NAME, &maj, &min) != 0) {
		kmsg("openkvm: storage: FAIL -- " ROOT_PART_NAME
		     " never appeared\n");
		return;
	}
	kmsg_hex("openkvm: storage: " ROOT_PART_NAME " found after ms: ",
		 (uint32_t)waited_ms);
	kmsg_hex("openkvm: storage: major: ", maj);
	kmsg_hex("openkvm: storage: minor: ", min);
	if (chipmode)
		wr32(chipmode + BACKUP0_SET_OFF, MS_BLKDEV);

	(void)unlink(PROBE_DEV);
	if (mknod(PROBE_DEV, S_IFBLK | 0600, makedev(maj, min)) != 0) {
		kmsg_hex("openkvm: storage: mknod failed, errno: ",
			 (uint32_t)errno);
		return;
	}

	/*
	 * MS_RDONLY, and if the journal needs replaying, "noload" so we still
	 * do not write. A clean shutdown precedes every run of this test, so
	 * the fallback should never fire -- if it does, that is worth knowing.
	 */
	rc = mount(PROBE_DEV, PROBE_MNT, "ext4", MS_RDONLY, NULL);
	if (rc != 0) {
		kmsg_hex("openkvm: storage: ro mount failed, errno: ",
			 (uint32_t)errno);
		rc = mount(PROBE_DEV, PROBE_MNT, "ext4", MS_RDONLY, "noload");
		if (rc == 0)
			kmsg("openkvm: storage: mounted with noload "
			     "(journal was dirty)\n");
	}
	if (rc != 0) {
		kmsg_hex("openkvm: storage: FAIL -- mount errno: ",
			 (uint32_t)errno);
		return;
	}

	/*
	 * Count directory entries rather than reading a named file. Nothing
	 * here should depend on the vendor rootfs layout, and a non-zero count
	 * already proves the block layer, the driver, ext4 and real DMA reads
	 * from the card all work.
	 */
	d = opendir(PROBE_MNT);
	if (d) {
		while (readdir(d))
			entries++;
		closedir(d);
	}
	kmsg_hex("openkvm: storage: OK -- root entries: ", (uint32_t)entries);
	if (entries > 2 && chipmode)
		wr32(chipmode + BACKUP0_SET_OFF, MS_ROOTFS_RO);

	harvest_identity();

	/* Leave nothing mounted: the next thing this board does is reboot. */
	(void)umount(PROBE_MNT);
}

/* --- network + shell (#77) ------------------------------------------------ */

/*
 * fork/exec/wait, with the child's stdout and stderr pointed at the kernel log
 * so that udhcpc's and dropbear's own diagnostics end up in the stash and the
 * ramoops console alongside everything else. Returns the child's exit status,
 * or -1.
 */
static int run(const char *path, char *const argv[])
{
	int status = 0;
	pid_t pid = fork();

	if (pid < 0)
		return -1;

	if (pid == 0) {
		/*
		 * The kernel could not open an initial console for /init (no
		 * /dev/console on this board: "unable to open an initial
		 * console" is in every boot log), so fds 0-2 are NOT open and
		 * kmsg_fd may well BE fd 0. Hence the order: point 1 and 2 at
		 * the kernel log FIRST, then give the child a real stdin from
		 * /dev/null. Doing it the other way round would overwrite
		 * kmsg_fd with /dev/null before it had been duplicated.
		 */
		int null_fd;

		if (kmsg_fd >= 0) {
			(void)dup2(kmsg_fd, STDOUT_FILENO);
			(void)dup2(kmsg_fd, STDERR_FILENO);
		}
		null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
		if (null_fd >= 0 && null_fd != STDIN_FILENO)
			(void)dup2(null_fd, STDIN_FILENO);
		execv(path, argv);
		_exit(127);
	}

	if (waitpid(pid, &status, 0) != pid)
		return -1;

	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

/*
 * Give eth0 the vendor MAC and bring it up.
 *
 * The MAC has to be set while the interface is DOWN, which it is: nothing in
 * here has touched it and there is no udev or systemd to have done so.
 */
static int net_configure_link(void)
{
	unsigned int m[6];
	struct ifreq ifr;
	int s, i;

	s = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
	if (s < 0) {
		kmsg_hex("openkvm: net: socket failed, errno: ",
			 (uint32_t)errno);
		return -1;
	}

	if (harvest_mac[0] &&
	    sscanf(harvest_mac, "%x:%x:%x:%x:%x:%x",
		   &m[0], &m[1], &m[2], &m[3], &m[4], &m[5]) == 6) {
		memset(&ifr, 0, sizeof(ifr));
		strncpy(ifr.ifr_name, NET_IFACE, IFNAMSIZ - 1);
		ifr.ifr_hwaddr.sa_family = ARPHRD_ETHER;
		for (i = 0; i < 6; i++)
			ifr.ifr_hwaddr.sa_data[i] = (char)(m[i] & 0xff);
		if (ioctl(s, SIOCSIFHWADDR, &ifr) != 0)
			kmsg_hex("openkvm: net: SIOCSIFHWADDR errno: ",
				 (uint32_t)errno);
	}

	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, NET_IFACE, IFNAMSIZ - 1);
	if (ioctl(s, SIOCGIFFLAGS, &ifr) != 0) {
		kmsg_hex("openkvm: net: no " NET_IFACE ", errno: ",
			 (uint32_t)errno);
		close(s);
		return -1;
	}
	ifr.ifr_flags |= IFF_UP;
	if (ioctl(s, SIOCSIFFLAGS, &ifr) != 0) {
		kmsg_hex("openkvm: net: SIOCSIFFLAGS errno: ",
			 (uint32_t)errno);
		close(s);
		return -1;
	}
	close(s);

	return 0;
}

/* Milliseconds waited for carrier, or -1 if it never came up. */
static int net_wait_carrier(void)
{
	int waited = 0;
	char v[8];

	while (waited < NET_CARRIER_SECONDS * 1000) {
		if (read_line("/sys/class/net/" NET_IFACE "/carrier", v,
			      sizeof(v)) == 0 && v[0] == '1')
			return waited;
		nap(0, 200000000L);
		waited += 200;
	}

	return -1;
}

/*
 * The whole network step. Returns 0 once there is an address; the milestone
 * bits record how far it actually got, because "carrier but no lease" and "no
 * carrier at all" are completely different faults and the register is the only
 * channel that survives a board that then wedges.
 */
static void bring_up_network(volatile uint8_t *chipmode)
{
	char *const dhcp_argv[] = {
		"busybox", "udhcpc", "-i", (char *)NET_IFACE,
		"-s", "/etc/udhcpc.script", "-f", "-q", "-n",
		"-t", "8", "-T", "2", NULL
	};
	char result[128], router[64];
	int carrier_ms, rc;
	char *p;

	if (net_configure_link() != 0)
		return;

	carrier_ms = net_wait_carrier();
	if (carrier_ms < 0) {
		kmsg("openkvm: net: FAIL -- no carrier on " NET_IFACE "\n");
		return;
	}
	kmsg_hex("openkvm: net: carrier up after ms: ",
		 (uint32_t)carrier_ms);
	{
		char msg[128], speed[16], duplex[16];

		if (read_line("/sys/class/net/" NET_IFACE "/speed", speed,
			      sizeof(speed)) != 0)
			strcpy(speed, "?");
		if (read_line("/sys/class/net/" NET_IFACE "/duplex", duplex,
			      sizeof(duplex)) != 0)
			strcpy(duplex, "?");
		snprintf(msg, sizeof(msg),
			 "openkvm: net: link %s Mbit/s %s duplex\n",
			 speed, duplex);
		kmsg(msg);
	}
	if (chipmode)
		wr32(chipmode + BACKUP0_SET_OFF, MS_NET_LINK);

	(void)unlink(DHCP_RESULT);
	rc = run("/bin/busybox", dhcp_argv);
	if (rc != 0)
		kmsg_hex("openkvm: net: udhcpc exit: ", (uint32_t)rc);

	if (slurp(DHCP_RESULT, result, sizeof(result)) <= 0) {
		kmsg("openkvm: net: FAIL -- no DHCP lease\n");
		return;
	}
	{
		char msg[192];

		snprintf(msg, sizeof(msg),
			 "openkvm: net: lease (address netmask router): %s",
			 result);
		kmsg(msg);
	}
	if (chipmode)
		wr32(chipmode + BACKUP0_SET_OFF, MS_NET_ADDR);

	/*
	 * Prove a packet actually went out and came back. The DHCP exchange is
	 * already that proof at the UDP level, but an ICMP round trip to the
	 * router also exercises ARP, the route, and the receive path with a
	 * unicast frame -- which is what "the MAC works", rather than "the MAC
	 * transmits", actually means.
	 */
	router[0] = '\0';
	p = strchr(result, ' ');
	if (p)
		p = strchr(p + 1, ' ');
	if (p)
		copy_token(p, router, sizeof(router));
	if (router[0] && strcmp(router, "none") != 0) {
		char *const ping_argv[] = {
			"busybox", "ping", "-c", "3", "-W", "2", router, NULL
		};

		rc = run("/bin/busybox", ping_argv);
		kmsg_hex("openkvm: net: ping the router, exit: ",
			 (uint32_t)rc);
		if (rc == 0 && chipmode)
			wr32(chipmode + BACKUP0_SET_OFF, MS_NET_PING);
	}
}

/*
 * Write the account files dropbear authenticates against. /etc/passwd and
 * /etc/group ship in the cpio; the hash does not, and is written here from
 * what harvest_identity() read off the eMMC.
 */
static void write_shadow(void)
{
	int fd;

	if (!harvest_shadow[0])
		return;

	fd = open("/etc/shadow", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
		  0600);
	if (fd < 0) {
		kmsg_hex("openkvm: net: cannot write /etc/shadow, errno: ",
			 (uint32_t)errno);
		return;
	}
	(void)write(fd, harvest_shadow, strlen(harvest_shadow));
	close(fd);
}

static void start_sshd(volatile uint8_t *chipmode)
{
	char *const key_argv[] = {
		"dropbearkey", "-t", "ed25519", "-f",
		(char *)SSH_HOST_KEY, NULL
	};
	/*
	 * No -F: dropbear daemonises itself and run() reaps the parent, which
	 * is what makes this call return. The daemon is reparented to us, and
	 * the dwell loop below reaps its session children.
	 */
	char *const argv[] = {
		"dropbear", "-r", (char *)SSH_HOST_KEY, "-E", "-p", "22", NULL
	};
	int rc;

	write_shadow();

	rc = run("/bin/dropbearkey", key_argv);
	if (rc != 0) {
		kmsg_hex("openkvm: sshd: dropbearkey exit: ", (uint32_t)rc);
		return;
	}

	rc = run("/bin/dropbear", argv);
	kmsg_hex("openkvm: sshd: dropbear exit: ", (uint32_t)rc);
	if (rc == 0 && chipmode)
		wr32(chipmode + BACKUP0_SET_OFF, MS_SSHD);
}

/* --- USB gadget (#82) ---------------------------------------------------- */

/*
 * The USB HID boot-protocol keyboard report descriptor, verbatim from
 * Documentation/usb/gadget_hid.rst. 63 bytes: an 8-bit modifier bitmap, one
 * reserved byte, 5 LED output bits plus 3 bits of padding, and six key codes.
 * It is the same shape as usbdev.sh's hid.GS0 because there is only one shape
 * a boot keyboard can have -- this copy comes from the kernel's own
 * documentation, not from the vendor script.
 */
static const unsigned char hid_keyboard_report[] = {
	0x05, 0x01,		/* USAGE_PAGE (Generic Desktop)		*/
	0x09, 0x06,		/* USAGE (Keyboard)			*/
	0xa1, 0x01,		/* COLLECTION (Application)		*/
	0x05, 0x07,		/*   USAGE_PAGE (Keyboard)		*/
	0x19, 0xe0,		/*   USAGE_MINIMUM (LeftControl)	*/
	0x29, 0xe7,		/*   USAGE_MAXIMUM (Right GUI)		*/
	0x15, 0x00,		/*   LOGICAL_MINIMUM (0)		*/
	0x25, 0x01,		/*   LOGICAL_MAXIMUM (1)		*/
	0x75, 0x01,		/*   REPORT_SIZE (1)			*/
	0x95, 0x08,		/*   REPORT_COUNT (8)			*/
	0x81, 0x02,		/*   INPUT (Data,Var,Abs)		*/
	0x95, 0x01,		/*   REPORT_COUNT (1)			*/
	0x75, 0x08,		/*   REPORT_SIZE (8)			*/
	0x81, 0x03,		/*   INPUT (Cnst,Var,Abs)		*/
	0x95, 0x05,		/*   REPORT_COUNT (5)			*/
	0x75, 0x01,		/*   REPORT_SIZE (1)			*/
	0x05, 0x08,		/*   USAGE_PAGE (LEDs)			*/
	0x19, 0x01,		/*   USAGE_MINIMUM (Num Lock)		*/
	0x29, 0x05,		/*   USAGE_MAXIMUM (Kana)		*/
	0x91, 0x02,		/*   OUTPUT (Data,Var,Abs)		*/
	0x95, 0x01,		/*   REPORT_COUNT (1)			*/
	0x75, 0x03,		/*   REPORT_SIZE (3)			*/
	0x91, 0x03,		/*   OUTPUT (Cnst,Var,Abs)		*/
	0x95, 0x06,		/*   REPORT_COUNT (6)			*/
	0x75, 0x08,		/*   REPORT_SIZE (8)			*/
	0x15, 0x00,		/*   LOGICAL_MINIMUM (0)		*/
	0x25, 0x65,		/*   LOGICAL_MAXIMUM (101)		*/
	0x05, 0x07,		/*   USAGE_PAGE (Keyboard)		*/
	0x19, 0x00,		/*   USAGE_MINIMUM (Reserved)		*/
	0x29, 0x65,		/*   USAGE_MAXIMUM (Application)	*/
	0x81, 0x00,		/*   INPUT (Data,Ary,Abs)		*/
	0xc0			/* END_COLLECTION			*/
};

/*
 * Write @len bytes to @path, creating nothing. Every configfs attribute below
 * goes through here; returns 0 on success. Failures are logged with errno by
 * the caller, because in configfs an EINVAL on one attribute and an ENODEV on
 * another mean entirely different things.
 */
static int write_all(const char *path, const void *buf, size_t len)
{
	int fd = open(path, O_WRONLY | O_CLOEXEC);
	ssize_t n;

	if (fd < 0)
		return -1;
	n = write(fd, buf, len);
	close(fd);

	return (n == (ssize_t)len) ? 0 : -1;
}

static int write_str(const char *path, const char *s)
{
	return write_all(path, s, strlen(s));
}

/* Build "<GADGET_DIR>/<tail>" into buf and return it, for the calls below. */
static const char *gpath(char *buf, size_t len, const char *tail)
{
	snprintf(buf, len, GADGET_DIR "/%s", tail);
	return buf;
}

/*
 * Find the one USB device controller. dwc3 registers it from its own probe, so
 * it is normally there before this runs -- but the glue populates the core
 * node asynchronously and a poll costs nothing. Returns 0 and fills @name.
 */
static int find_udc(char *name, size_t len)
{
	int waited;

	for (waited = 0; waited < UDC_WAIT_SECONDS * 1000;
	     waited += UDC_POLL_MS) {
		DIR *d = opendir(UDC_CLASS_DIR);
		struct dirent *e;

		if (d) {
			while ((e = readdir(d))) {
				if (e->d_name[0] == '.')
					continue;
				snprintf(name, len, "%s", e->d_name);
				closedir(d);
				return 0;
			}
			closedir(d);
		}
		nap(0, UDC_POLL_MS * 1000000L);
	}

	return -1;
}

/*
 * Create and immediately remove each function directory usbdev.sh will want.
 * This is a presence test for the function drivers, not a configuration: a
 * mkdir under functions/ instantiates the driver, so a name that is not
 * compiled in fails with ENOENT right here rather than three months later on
 * an appliance whose mouse does not work. Returns the number found.
 */
static int probe_gadget_functions(void)
{
	static const char *const want[] = {
		"hid.probe", "mass_storage.probe", "ncm.probe",
		"uac2.probe", "acm.probe",
	};
	char path[256];
	size_t i;
	int found = 0;

	for (i = 0; i < sizeof(want) / sizeof(want[0]); i++) {
		char tail[64];

		snprintf(tail, sizeof(tail), "functions/%s", want[i]);
		gpath(path, sizeof(path), tail);

		if (mkdir(path, 0755) == 0) {
			found++;
			(void)rmdir(path);
		} else {
			char msg[192];

			snprintf(msg, sizeof(msg),
				 "openkvm: usb: function %s unavailable, errno %d\n",
				 want[i], errno);
			kmsg(msg);
		}
	}

	return found;
}

/*
 * The whole USB step. Everything here is best-effort: a board that cannot
 * build a gadget must still reach the dwell, because the dwell is the
 * watchdog evidence and #75's proof has to survive every later addition.
 */
static void bring_up_gadget(volatile uint8_t *chipmode)
{
	char udc[64], path[256], msg[256], state[64];
	int found, waited;

	(void)mkdir(CONFIGFS_MNT, 0755);
	if (mount("configfs", CONFIGFS_MNT, "configfs", 0, NULL) != 0 &&
	    errno != EBUSY) {
		kmsg_hex("openkvm: usb: configfs mount failed, errno: ",
			 (uint32_t)errno);
		return;
	}

	if (find_udc(udc, sizeof(udc)) != 0) {
		kmsg("openkvm: usb: no UDC in " UDC_CLASS_DIR
		     " -- the dwc3 glue or core did not bind\n");
		return;
	}

	snprintf(msg, sizeof(msg), "openkvm: usb: UDC is %s\n", udc);
	kmsg(msg);
	if (chipmode)
		wr32(chipmode + BACKUP0_SET_OFF, MS_UDC);

	if (mkdir(GADGET_DIR, 0755) != 0) {
		kmsg_hex("openkvm: usb: cannot create the gadget, errno: ",
			 (uint32_t)errno);
		return;
	}

	found = probe_gadget_functions();
	snprintf(msg, sizeof(msg),
		 "openkvm: usb: %d of 5 usbdev.sh function drivers present\n",
		 found);
	kmsg(msg);

	/* Device descriptor. */
	(void)write_str(gpath(path, sizeof(path), "idVendor"), GADGET_VID);
	(void)write_str(gpath(path, sizeof(path), "idProduct"), GADGET_PID);
	(void)write_str(gpath(path, sizeof(path), "bcdUSB"), "0x0200");
	(void)write_str(gpath(path, sizeof(path), "bcdDevice"), "0x0100");

	/* English (0x409) strings. The serial is the slot the kernel booted. */
	(void)mkdir(gpath(path, sizeof(path), "strings"), 0755);
	if (mkdir(gpath(path, sizeof(path), "strings/0x409"), 0755) == 0) {
		(void)write_str(gpath(path, sizeof(path),
				      "strings/0x409/manufacturer"),
				GADGET_MANUFACTURER);
		(void)write_str(gpath(path, sizeof(path),
				      "strings/0x409/product"),
				GADGET_PRODUCT);
		(void)write_str(gpath(path, sizeof(path),
				      "strings/0x409/serialnumber"), "slotb");
	}

	/*
	 * One HID keyboard, boot protocol. Not the full three-interface set
	 * usbdev.sh builds: this is the enumeration oracle, and one interface
	 * that either appears on the host or does not is a cleaner answer than
	 * five that might each fail differently. The presence test above
	 * already covers the other four function drivers.
	 */
	if (mkdir(gpath(path, sizeof(path), "functions/hid.GS0"), 0755) != 0) {
		kmsg_hex("openkvm: usb: cannot create hid.GS0, errno: ",
			 (uint32_t)errno);
		return;
	}
	(void)write_str(gpath(path, sizeof(path), "functions/hid.GS0/protocol"),
			"1");
	(void)write_str(gpath(path, sizeof(path), "functions/hid.GS0/subclass"),
			"1");
	(void)write_str(gpath(path, sizeof(path),
			      "functions/hid.GS0/report_length"), "8");
	if (write_all(gpath(path, sizeof(path),
			    "functions/hid.GS0/report_desc"),
		      hid_keyboard_report, sizeof(hid_keyboard_report)) != 0) {
		kmsg_hex("openkvm: usb: report_desc write failed, errno: ",
			 (uint32_t)errno);
		return;
	}

	(void)mkdir(gpath(path, sizeof(path), "configs"), 0755);
	if (mkdir(gpath(path, sizeof(path), "configs/c.1"), 0755) != 0) {
		kmsg_hex("openkvm: usb: cannot create configs/c.1, errno: ",
			 (uint32_t)errno);
		return;
	}
	(void)mkdir(gpath(path, sizeof(path), "configs/c.1/strings"), 0755);
	if (mkdir(gpath(path, sizeof(path), "configs/c.1/strings/0x409"),
		  0755) == 0)
		(void)write_str(gpath(path, sizeof(path),
				      "configs/c.1/strings/0x409/configuration"),
				"HID");
	(void)write_str(gpath(path, sizeof(path), "configs/c.1/MaxPower"),
			"100");

	if (symlink(GADGET_DIR "/functions/hid.GS0",
		    gpath(path, sizeof(path), "configs/c.1/hid.GS0")) != 0) {
		kmsg_hex("openkvm: usb: cannot link the function, errno: ",
			 (uint32_t)errno);
		return;
	}

	/*
	 * Binding. Writing the controller's name here is what starts the
	 * gadget: the composite core builds the descriptors, dwc3 enables the
	 * pullup and, if VBUSVALID is set, the host sees a device appear. An
	 * EINVAL at this line and nowhere else means the descriptors are bad;
	 * an ENODEV means the UDC went away.
	 */
	if (write_str(gpath(path, sizeof(path), "UDC"), udc) != 0) {
		kmsg_hex("openkvm: usb: binding to the UDC failed, errno: ",
			 (uint32_t)errno);
		return;
	}

	kmsg("openkvm: usb: HID keyboard gadget bound\n");
	if (chipmode)
		wr32(chipmode + BACKUP0_SET_OFF, MS_GADGET);

	/*
	 * Whether a host is on the other end. This is the ONLY step here that
	 * depends on the cable, so it gets its own bit and its own timeout,
	 * and it never fails the run.
	 */
	snprintf(path, sizeof(path), UDC_CLASS_DIR "/%s/state", udc);
	for (waited = 0; waited < USB_ATTACH_SECONDS * 1000; waited += 500) {
		if (read_line(path, state, sizeof(state)) == 0 &&
		    !strcmp(state, "configured")) {
			kmsg("openkvm: usb: host enumerated and configured us\n");
			if (chipmode)
				wr32(chipmode + BACKUP0_SET_OFF,
				     MS_USB_ATTACHED);
			return;
		}
		nap(0, 500000000L);
	}

	if (read_line(path, state, sizeof(state)) != 0)
		strcpy(state, "?");
	snprintf(msg, sizeof(msg),
		 "openkvm: usb: no host after %ds, UDC state=%s (check the cable)\n",
		 USB_ATTACH_SECONDS, state);
	kmsg(msg);
}

/* ------------------------------------------------------------------------- */

int main(void)
{
	volatile uint8_t *chipmode = NULL, *gpio0 = NULL, *stash = NULL;
	int memfd, i;

	/*
	 * devtmpfs first, for everything dropbear needs (/dev/ptmx,
	 * /dev/urandom, /dev/null) -- an initramfs gets no automatic mount of
	 * it. Then mknod the two nodes this program itself cannot do without,
	 * which succeeds whether or not devtmpfs is there and costs nothing
	 * when it is (EEXIST). Both are fixed majors/minors, so the fallback
	 * works on the barest possible kernel.
	 */
	(void)mkdir("/dev", 0755);
	(void)mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	(void)mkdir("/dev/pts", 0755);
	(void)mount("devpts", "/dev/pts", "devpts", 0,
		    "gid=5,mode=620,ptmxmode=0666");
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
		int fd;

		/*
		 * Lift the /dev/kmsg write ratelimit first. Its default is
		 * "ratelimit": ten records per five seconds per open file,
		 * after which writes are silently discarded. On a normal
		 * system systemd sets this to "on" at boot and nobody ever
		 * notices; an initramfs with no systemd inherits the default,
		 * and the first bring-up boot lost two milestone lines to it
		 * before anyone worked out where they had gone.
		 */
		fd = open("/proc/sys/kernel/printk_devkmsg",
			  O_WRONLY | O_CLOEXEC);
		if (fd >= 0) {
			(void)write(fd, "on\n", 3);
			close(fd);
		}

		for (k = 0; k < sizeof(echo) / sizeof(echo[0]); k++) {
			ssize_t n;
			size_t pre;

			/*
			 * One write per file, not four: each write() to
			 * /dev/kmsg is a separate record, so building the line
			 * here keeps the log readable and costs three fewer
			 * records against the ratelimit above.
			 */
			pre = (size_t)snprintf(buf, sizeof(buf), "openkvm: %s: ",
					       echo[k]);
			fd = open(echo[k], O_RDONLY | O_CLOEXEC);
			if (fd < 0)
				continue;
			n = read(fd, buf + pre, sizeof(buf) - pre - 2);
			close(fd);
			if (n <= 0)
				continue;
			if (buf[pre + n - 1] != '\n')
				buf[pre + n++] = '\n';
			(void)write(kmsg_fd, buf, pre + (size_t)n);
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
		uint32_t used = stash_klog(stash);

		kmsg_hex("openkvm: kernel log stashed, bytes: ", used);
		if (chipmode)
			wr32(chipmode + BACKUP0_SET_OFF, MS_LOG_STASHED);
	} else {
		kmsg("openkvm: WARNING: cannot map the log stash window\n");
	}

	/*
	 * Milestone 2b (#76): storage. Deliberately AFTER the first stash --
	 * this is the first step in the bring-up sequence that touches a
	 * peripheral which could wedge, and #75's evidence must survive that.
	 * The stash is rewritten below so the storage lines land in it too;
	 * if this call never returns, the ramoops console zone still has
	 * everything and the earlier stash is intact.
	 */
	probe_storage(chipmode);

	/*
	 * Milestone 2c (#77): the network, then a shell on it. /sys is mounted
	 * here rather than in the dwell block below because the carrier and
	 * link-speed reads need it -- the watchdog readout that used to mount
	 * it just inherits the mount.
	 */
	if (mount("sysfs", "/sys", "sysfs", 0, NULL) != 0)
		kmsg("openkvm: WARNING: /sys mount failed; no carrier or "
		     "watchdog readout\n");
	bring_up_network(chipmode);
	start_sshd(chipmode);

	/*
	 * Milestone 2d (#82): the USB gadget. After the network on purpose --
	 * this is the step that can sit for USB_ATTACH_SECONDS waiting on a
	 * host that may not be there, and a shell on the board is a much better
	 * place to debug that from than a milestone bit two boots later.
	 */
	bring_up_gadget(chipmode);

	if (stash) {
		uint32_t used = stash_klog(stash);

		kmsg_hex("openkvm: kernel log re-stashed, bytes: ", used);
	}

	/*
	 * Milestone 3: outlive the bootloader's watchdog, blinking a
	 * distinctive three-short-one-long pattern the whole time so a human
	 * can tell this apart from the vendor system's steady heartbeat.
	 *
	 * The blinking is the human-facing half. The real content is the
	 * liveness line every HEARTBEAT_SECONDS, which carries the watchdog's
	 * own countdown straight out of sysfs: if the driver has adopted the
	 * running dog and the core is petting it, timeleft keeps jumping back
	 * up. If it never does, the board reboots mid-dwell and the log stops
	 * at the last line -- which says exactly when.
	 */
	{
		volatile void *led = gpio0 ? gpio0 + GPIO0_LED_OFF : NULL;
		uint32_t base = led ? rd32(led) & ~(GPIO_DR | GPIO_DDR) : 0;
		long elapsed = 0, next_beat = 0, limit = DWELL_SECONDS * 1000L;
		char msg[256], left[32], state[32];

		if (!led)
			kmsg("openkvm: WARNING: cannot map GPIO0; no LED\n");

		while (elapsed < limit) {
			/*
			 * PID 1 reaps. dropbear's session children are ours
			 * once its daemon was reparented here.
			 */
			while (waitpid(-1, NULL, WNOHANG) > 0)
				;

			/*
			 * An SSH session that wants more than the default
			 * dwell says so by creating this file. The cap is
			 * absolute: a forgotten session still ends with the
			 * board back on slot A.
			 */
			if (limit < DWELL_MAX_SECONDS * 1000L &&
			    access(KEEPALIVE_FILE, F_OK) == 0) {
				limit = DWELL_MAX_SECONDS * 1000L;
				kmsg("openkvm: dwell extended to the cap by "
				     KEEPALIVE_FILE "\n");
			}

			if (elapsed >= next_beat) {
				if (read_line("/sys/class/watchdog/watchdog0/timeleft",
					      left, sizeof(left)) != 0)
					strcpy(left, "?");
				if (read_line("/sys/class/watchdog/watchdog0/state",
					      state, sizeof(state)) != 0)
					strcpy(state, "?");
				snprintf(msg, sizeof(msg),
					 "openkvm: alive %lds/%lds, watchdog0 state=%s timeleft=%s\n",
					 elapsed / 1000, limit / 1000, state,
					 left);
				kmsg(msg);
				next_beat += HEARTBEAT_SECONDS * 1000;
			}

			for (i = 0; i < 3; i++) {
				if (led)
					wr32(led, base | GPIO_DDR | GPIO_DR);
				nap(0, 120000000L);
				if (led)
					wr32(led, base | GPIO_DDR);
				nap(0, 180000000L);
				elapsed += 300;
			}
			if (led)
				wr32(led, base | GPIO_DDR | GPIO_DR);
			nap(0, 700000000L);
			if (led)
				wr32(led, base | GPIO_DDR);
			nap(0, 400000000L);
			elapsed += 1100;
		}

		if (led)
			wr32(led, base | GPIO_DDR);
		if (chipmode)
			wr32(chipmode + BACKUP0_SET_OFF, MS_LED);
	}


	/*
	 * Milestone 4, then reboot. reboot(2) is itself a test: PSCI on this
	 * ATF implements no SYSTEM_RESET, so the reset can only come from the
	 * watchdog driver's restart handler. If that handler is broken the call
	 * hangs -- and the watchdog, no longer petted once the ping worker
	 * stops, resets the SoC anyway within its timeout. Either way the next
	 * boot is slot A.
	 */
	/*
	 * Last stash, so that everything the dwell produced -- the watchdog
	 * countdowns, dropbear's session log, anything a shell provoked --
	 * is in DRAM before the reset. The ramoops console zone has it too,
	 * but that zone is 16 KiB and this one is 32.
	 */
	if (stash)
		kmsg_hex("openkvm: kernel log final stash, bytes: ",
			 stash_klog(stash));

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
