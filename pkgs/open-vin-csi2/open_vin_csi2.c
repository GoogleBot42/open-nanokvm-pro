// SPDX-License-Identifier: GPL-2.0
/*
 * open_vin_csi2 -- open V4L2 CSI-2 receiver subdev for the Axera AX630C MIPI
 * CSI-2 host (replaces vendor ax_mipi_rx). Epic #55 / issue #57 (M1).
 *
 * SCAFFOLD PLACEHOLDER: replaced by the clean-room driver written from
 * docs/reference/deblob-scope/specs/spec-mipi-rx.md. This stub only proves the
 * V4L2 subdev build environment (headers + vermagic) before the real code lands.
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <media/v4l2-device.h>
#include <media/v4l2-subdev.h>

static int __init open_vin_csi2_init(void) { pr_info("open_vin_csi2: scaffold placeholder\n"); return 0; }
static void __exit open_vin_csi2_exit(void) {}
module_init(open_vin_csi2_init);
module_exit(open_vin_csi2_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Open V4L2 CSI-2 receiver subdev for AX630C (ax_mipi_rx replacement, #57)");
