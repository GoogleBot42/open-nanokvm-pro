// SPDX-License-Identifier: GPL-2.0
/*
 * open_vin_capture -- open V4L2 VIN/IFE capture video node for the Axera
 * AX630C (replaces the vendor ax_proton bypass/IFE-WDMA path). Epic #55 /
 * issue #59 (M2). Digital YUV422 over MIPI CSI-2 -> IFE bypass -> WDMA -> DDR.
 *
 * SCAFFOLD PLACEHOLDER: replaced by the clean-room driver written from
 * docs/reference/deblob-scope/specs/spec-proton-bypass.md (+ spec-cdma.md).
 * This stub only proves the vb2/video-node build environment before real code.
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <media/v4l2-device.h>
#include <media/v4l2-ioctl.h>
#include <media/videobuf2-v4l2.h>

static int __init open_vin_capture_init(void) { pr_info("open_vin_capture: scaffold placeholder\n"); return 0; }
static void __exit open_vin_capture_exit(void) {}
module_init(open_vin_capture_init);
module_exit(open_vin_capture_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Open V4L2 VIN/IFE capture node for AX630C (ax_proton bypass replacement, #59)");
