/* SPDX-License-Identifier: GPL-2.0 */
/*
 * From-source frame-buffer allocator for the AX630C VC8000E VCMD driver (#45).
 *
 * Manages a physically-contiguous CMM carveout (outside kernel-managed DRAM)
 * and hands userspace bus addresses for encoder frame buffers, replacing the
 * fixed-address /dev/mem placement of Stage B. The kernel never maps the
 * memory: only the encoder DMAs it and userspace mmaps it (writecombine)
 * through the driver, so the allocator is pure address-space bookkeeping.
 *
 * ABI (added to the Hantro ioctl surface; 36/37 are unused upstream):
 *   HANTRO_IOCH_ALLOC_FRAMEBUF  in: size          out: bus_addr
 *   HANTRO_IOCH_FREE_FRAMEBUF   in: bus_addr      (owner-checked)
 * Allocations are owned by the open file and freed automatically on close.
 * mmap offset = bus_addr, length <= allocation size.
 */
#ifndef FRAMEBUF_ALLOC_H
#define FRAMEBUF_ALLOC_H

#include <linux/ioctl.h>

struct framebuf_parameter {
	unsigned long size;      /* in: bytes (page-rounded internally) */
	unsigned long bus_addr;  /* out (alloc) / in (free) */
};

#define HANTRO_IOCH_ALLOC_FRAMEBUF _IOWR('k', 36, struct framebuf_parameter)
#define HANTRO_IOCH_FREE_FRAMEBUF  _IOWR('k', 37, struct framebuf_parameter)

#ifdef __KERNEL__
struct file;

int vcmd_fb_alloc(struct file *filp, unsigned long size, unsigned long *bus);
int vcmd_fb_free(struct file *filp, unsigned long bus);
/* free everything owned by filp (device close) */
void vcmd_fb_release_filp(struct file *filp);
/* mmap support: 0 + size out if phy is an allocation's base */
int vcmd_fb_lookup(unsigned long phy, unsigned long *size);
#endif

#endif /* FRAMEBUF_ALLOC_H */
