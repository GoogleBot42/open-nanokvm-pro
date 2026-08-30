// SPDX-License-Identifier: GPL-2.0
/*
 * From-source frame-buffer allocator over a CMM carveout (#45).
 * See framebuf_alloc.h for the ABI and design notes.
 *
 * First-fit over a bus-address-sorted allocation list. The region defaults to
 * the spare middle of the 200MB CMM carveout: above the vendor boot blocks
 * (ax_cmm allocates bottom-up from 0x73800000; its boot allocations sit at
 * 0x738xxxxx) and below the 8MB coherent VCMD-pool region at 0x7F800000.
 * Both bounds are module parameters.
 */
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/list.h>
#include <linux/mutex.h>
#include <linux/fs.h>

#include "framebuf_alloc.h"

static unsigned long framebuf_base = 0x78000000UL;
static unsigned long framebuf_size = 0x07800000UL;   /* 120MB */
module_param(framebuf_base, ulong, 0444);
MODULE_PARM_DESC(framebuf_base, "phys base of the frame-buffer CMM carveout");
module_param(framebuf_size, ulong, 0444);
MODULE_PARM_DESC(framebuf_size, "size of the frame-buffer CMM carveout");

struct fb_alloc {
	struct list_head node;   /* sorted by bus, ascending */
	unsigned long bus;
	unsigned long size;
	struct file *owner;
};

static LIST_HEAD(fb_list);
static DEFINE_MUTEX(fb_lock);

int vcmd_fb_alloc(struct file *filp, unsigned long size, unsigned long *bus)
{
	struct fb_alloc *a, *n;
	unsigned long hole;

	size = PAGE_ALIGN(size);
	if (!size || size > framebuf_size)
		return -EINVAL;

	n = kzalloc(sizeof(*n), GFP_KERNEL);
	if (!n)
		return -ENOMEM;
	n->size = size;
	n->owner = filp;

	mutex_lock(&fb_lock);
	hole = framebuf_base;
	list_for_each_entry(a, &fb_list, node) {
		if (a->bus - hole >= size)
			break;
		hole = a->bus + a->size;
	}
	if (framebuf_base + framebuf_size - hole < size) {
		mutex_unlock(&fb_lock);
		kfree(n);
		return -ENOMEM;
	}
	n->bus = hole;
	/* insert sorted: before the first entry above the hole */
	list_for_each_entry(a, &fb_list, node)
		if (a->bus > hole)
			break;
	list_add_tail(&n->node, &a->node); /* works for head too (entry==head) */
	mutex_unlock(&fb_lock);

	*bus = n->bus;
	return 0;
}

int vcmd_fb_free(struct file *filp, unsigned long bus)
{
	struct fb_alloc *a;
	int ret = -ENOENT;

	mutex_lock(&fb_lock);
	list_for_each_entry(a, &fb_list, node) {
		if (a->bus == bus) {
			if (a->owner != filp) {
				ret = -EPERM;
				break;
			}
			list_del(&a->node);
			kfree(a);
			ret = 0;
			break;
		}
	}
	mutex_unlock(&fb_lock);
	return ret;
}

void vcmd_fb_release_filp(struct file *filp)
{
	struct fb_alloc *a, *tmp;

	mutex_lock(&fb_lock);
	list_for_each_entry_safe(a, tmp, &fb_list, node) {
		if (a->owner == filp) {
			list_del(&a->node);
			kfree(a);
		}
	}
	mutex_unlock(&fb_lock);
}

int vcmd_fb_lookup(unsigned long phy, unsigned long *size)
{
	struct fb_alloc *a;
	int ret = -ENOENT;

	mutex_lock(&fb_lock);
	list_for_each_entry(a, &fb_list, node) {
		if (a->bus == phy) {
			*size = a->size;
			ret = 0;
			break;
		}
	}
	mutex_unlock(&fb_lock);
	return ret;
}
