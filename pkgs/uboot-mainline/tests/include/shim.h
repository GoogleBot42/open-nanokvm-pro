/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * Just enough U-Boot to compile disk/part_cmdline.c on the build host.
 *
 * The point of this file is that the parser under test is the VERBATIM driver
 * source that goes into the firmware -- pkgs/uboot-mainline.nix installs the
 * patched disk/part_cmdline.c and the test #includes it -- so the test cannot
 * drift from the shipped code the way a re-implementation would. Everything
 * here is API surface, not behaviour: types, three string helpers and an
 * environment the test drives.
 */

#ifndef __UBOOT_PART_SHIM_H
#define __UBOOT_PART_SHIM_H

#include <ctype.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint64_t u64;
typedef uint32_t u32;
typedef unsigned char uchar;
typedef unsigned long ulong;
typedef unsigned long long lbaint_t;

#define LBAF "%llu"

enum uclass_id {
	UCLASS_MMC,
	UCLASS_SCSI,
	UCLASS_USB,
};

struct blk_desc {
	enum uclass_id uclass_id;
	int devnum;
	ulong blksz;
	lbaint_t lba;
};

#define PART_NAME_LEN 32
#define PART_TYPE_LEN 32

struct disk_partition {
	lbaint_t start;
	lbaint_t size;
	ulong blksz;
	uchar name[PART_NAME_LEN];
	uchar type[PART_TYPE_LEN];
	int bootable;
};

struct part_driver {
	const char *name;
	int part_type;
	const int max_entries;
	int (*get_info)(struct blk_desc *desc, int part,
			struct disk_partition *info);
	void (*print)(struct blk_desc *desc);
	int (*test)(struct blk_desc *desc);
};

#define PART_TYPE_CMDLINE 0x08

/* The driver's registration macro becomes a plain definition. */
#define U_BOOT_PART_TYPE(name) struct part_driver part_driver_##name

#define log_debug(...) do { } while (0)

#define min_t(type, a, b) ((type)(a) < (type)(b) ? (type)(a) : (type)(b))

static inline unsigned long long simple_strtoull(const char *cp, char **endp,
						 unsigned int base)
{
	return strtoull(cp, endp, base);
}

static inline size_t ub_strlcpy(char *dest, const char *src, size_t size)
{
	size_t len = strlen(src);

	if (size) {
		size_t n = len < size - 1 ? len : size - 1;

		memcpy(dest, src, n);
		dest[n] = '\0';
	}

	return len;
}
#define strlcpy ub_strlcpy

/* A two-slot environment, driven by the test. */
extern const char *shim_env_blkdevparts;
extern const char *shim_env_bootargs;

static inline const char *env_get(const char *name)
{
	if (!strcmp(name, "blkdevparts"))
		return shim_env_blkdevparts;
	if (!strcmp(name, "bootargs"))
		return shim_env_bootargs;

	return NULL;
}

#endif /* __UBOOT_PART_SHIM_H */
