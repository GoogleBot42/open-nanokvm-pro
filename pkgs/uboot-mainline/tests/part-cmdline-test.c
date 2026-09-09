// SPDX-License-Identifier: GPL-2.0+
/*
 * Host-side test for U-Boot's blkdevparts= partition driver (#89).
 *
 * It compiles the SHIPPED driver source -- pkgs/uboot-mainline.nix installs
 * the patched disk/part_cmdline.c and this file #includes it -- against a
 * shim that supplies the handful of U-Boot types and helpers it uses. So the
 * thing under test is the code that goes into the firmware, not a model of it.
 *
 * The table it is checked against (expected.h) is GENERATED from
 * nixos/emmc-partitions.nix, which in turn parses the blkdevparts= clause out
 * of dts/ax630c-nanokvm-pro.dts. Three independent parsers of one string --
 * Nix's, U-Boot's, and Linux's at boot -- and this asserts the first two agree.
 */

#include <shim.h>

const char *shim_env_blkdevparts;
const char *shim_env_bootargs;

#include "part_cmdline.c"

#include "expected.h"

#define BLKSZ 512

static int failures;

static void check(int ok, const char *what, ...)
{
	va_list ap;

	if (ok)
		return;

	failures++;
	fputs("FAIL: ", stderr);
	va_start(ap, what);
	vfprintf(stderr, what, ap);
	va_end(ap);
	fputc('\n', stderr);
}

static struct blk_desc mmc0 = {
	.uclass_id = UCLASS_MMC,
	.devnum = 0,
	.blksz = BLKSZ,
	.lba = EXPECTED_DEVICE_BYTES / BLKSZ,
};

static void test_layout(void)
{
	struct disk_partition info;
	int i;

	check(!part_driver_cmdline.test(&mmc0),
	      "the driver did not claim mmcblk0");

	for (i = 0; i < EXPECTED_COUNT; i++) {
		const struct expected_part *e = &expected_parts[i];
		int part = i + 1;

		if (part_driver_cmdline.get_info(&mmc0, part, &info)) {
			check(0, "p%d (%s) not returned", part, e->name);
			continue;
		}

		check(!strcmp((char *)info.name, e->name),
		      "p%d name is \"%s\", expected \"%s\"",
		      part, (char *)info.name, e->name);
		check(info.start * BLKSZ == e->offset,
		      "p%d (%s) starts at %llu, expected %llu",
		      part, e->name,
		      (unsigned long long)info.start * BLKSZ,
		      (unsigned long long)e->offset);

		if (e->size)
			check(info.size * BLKSZ == e->size,
			      "p%d (%s) is %llu bytes, expected %llu",
			      part, e->name,
			      (unsigned long long)info.size * BLKSZ,
			      (unsigned long long)e->size);
		else
			check(info.size * BLKSZ ==
			      EXPECTED_DEVICE_BYTES - e->offset,
			      "p%d (%s) does not run to the end of the device",
			      part, e->name);
	}

	check(part_driver_cmdline.get_info(&mmc0, EXPECTED_COUNT + 1, &info),
	      "p%d was returned, but the clause has %d partitions",
	      EXPECTED_COUNT + 1, EXPECTED_COUNT);
	check(part_driver_cmdline.get_info(&mmc0, 0, &info),
	      "p0 was returned; partitions are 1-based");
}

/*
 * The two partitions everything downstream addresses by number.
 *
 * Under the GPT layout (#89 rung 4) the blkdevparts= clause carves the raw
 * eMMC into `spl` and `disk` and nothing else: `boot` and `rootfs` are GPT
 * partitions on a loop device over `disk`, and .#checks.uboot-gpt is what
 * proves those. EXPECTED_BOOT_PART = 0 means "not in this table".
 */
static void test_named(void)
{
	struct disk_partition info;

	if (!EXPECTED_BOOT_PART && !EXPECTED_ROOT_PART)
		return;

	if (part_driver_cmdline.get_info(&mmc0, EXPECTED_BOOT_PART, &info))
		check(0, "the boot partition p%d is missing",
		      EXPECTED_BOOT_PART);
	else
		check(!strcmp((char *)info.name, "boot"),
		      "p%d is \"%s\", expected \"boot\"",
		      EXPECTED_BOOT_PART, (char *)info.name);

	if (part_driver_cmdline.get_info(&mmc0, EXPECTED_ROOT_PART, &info))
		check(0, "the root partition p%d is missing",
		      EXPECTED_ROOT_PART);
	else
		check(!strcmp((char *)info.name, "rootfs"),
		      "p%d is \"%s\", expected \"rootfs\"",
		      EXPECTED_ROOT_PART, (char *)info.name);
}

static void test_other_device(void)
{
	struct blk_desc mmc1 = mmc0;
	struct blk_desc scsi0 = mmc0;

	mmc1.devnum = 1;
	scsi0.uclass_id = UCLASS_SCSI;

	check(part_driver_cmdline.test(&mmc1),
	      "the driver claimed mmcblk1, which the clause does not name");
	check(part_driver_cmdline.test(&scsi0),
	      "the driver claimed a non-MMC device");
}

/* The environment wins over the built-in clause, which is what fw_setenv needs. */
static void test_env_override(void)
{
	struct disk_partition info;

	shim_env_blkdevparts = "mmcblk0:1M(first),2M@0x300000(second),-(rest)ro";

	check(!part_driver_cmdline.test(&mmc0), "env clause not claimed");

	check(!part_driver_cmdline.get_info(&mmc0, 1, &info) &&
	      !strcmp((char *)info.name, "first") &&
	      info.start == 0 && info.size == (1 << 20) / BLKSZ,
	      "env p1 wrong");

	/* @offset skips a hole, and the next partition continues after it. */
	check(!part_driver_cmdline.get_info(&mmc0, 2, &info) &&
	      !strcmp((char *)info.name, "second") &&
	      info.start == 0x300000 / BLKSZ &&
	      info.size == (2 << 20) / BLKSZ,
	      "env p2 wrong");

	check(!part_driver_cmdline.get_info(&mmc0, 3, &info) &&
	      !strcmp((char *)info.name, "rest") &&
	      info.start == 0x500000 / BLKSZ,
	      "env p3 wrong");

	shim_env_blkdevparts = NULL;
}

/* A clause carried inside bootargs, the way the kernel command line has it. */
static void test_bootargs(void)
{
	struct disk_partition info;

	shim_env_bootargs =
		"console=ttyS0,115200n8 blkdevparts=mmcblk0:4M(one),-(two) rw";

	check(!part_driver_cmdline.get_info(&mmc0, 2, &info) &&
	      !strcmp((char *)info.name, "two") &&
	      info.start == (4 << 20) / BLKSZ,
	      "bootargs clause not parsed");

	/* A token that merely ENDS in blkdevparts= must not match. */
	shim_env_bootargs = "root=/dev/sda x_blkdevparts=mmcblk0:4M(one)";
	check(!part_driver_cmdline.get_info(&mmc0, 1, &info) &&
	      !strcmp((char *)info.name, expected_parts[0].name),
	      "a mid-word blkdevparts= was accepted");

	shim_env_bootargs = NULL;
}

static void test_malformed(void)
{
	struct disk_partition info;
	static const char * const bad[] = {
		"mmcblk0:1M",			/* no name */
		"mmcblk0:1M(unterminated",	/* no closing paren */
		"mmcblk0:(noname)",		/* no size */
		"mmcblk0:0(zero)",		/* zero-length partition */
		"mmcblk0:1M(a)!2M(b)",		/* junk between entries */
	};
	int i;

	for (i = 0; i < (int)(sizeof(bad) / sizeof(bad[0])); i++) {
		shim_env_blkdevparts = bad[i];
		check(part_driver_cmdline.test(&mmc0) ||
		      part_driver_cmdline.get_info(&mmc0, 1, &info),
		      "malformed clause accepted: %s", bad[i]);
	}

	shim_env_blkdevparts = NULL;
}

int main(void)
{
	test_layout();
	test_named();
	test_other_device();
	test_env_override();
	test_bootargs();
	test_malformed();

	if (failures) {
		fprintf(stderr, "part_cmdline: %d check(s) failed\n", failures);
		return 1;
	}

	printf("part_cmdline: %d partitions, p%d=boot p%d=rootfs, all checks passed\n",
	       EXPECTED_COUNT, EXPECTED_BOOT_PART, EXPECTED_ROOT_PART);

	return 0;
}
