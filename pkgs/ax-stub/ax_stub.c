// SPDX-License-Identifier: GPL-2.0
/*
 * ax_stub -- symbol-only stand-in for the vendor ax_npu / ax_gdc / ax_ivps /
 * ax_vpp blobs (issue #56, plan step 1 of the full-deblob epic #55).
 *
 * WHY THIS EXISTS
 * ---------------
 * Vendor ax_proton.ko link-imports exactly 26 symbols from those four modules.
 * Static scoping (docs/deblob-capture.md) says every one of them is reachable
 * only from camera-only ISP node modes -- AI noise reduction (NPU), dewarp
 * (GDC), the IVPS scaler/rotator, and the VPP tile path -- none of which the
 * KVM digital-YUV bypass capture topology ever enters. This module turns that
 * static claim into a RUNTIME PROOF: load it in place of the four blobs, run a
 * full capture session, and read dmesg.
 *
 *   silent  -> the 26 edges are genuinely dead; ~380 KB of blobs leave the image
 *   any hit -> a hidden call edge exists and the log names the exact symbol
 *
 * Each stub is pr_warn_once() + -ENODEV. -ENODEV is deliberately loud rather
 * than a quiet 0: the point of the experiment is to make a call edge fail
 * visibly, not to paper over it. If a particular edge turns out to be a
 * tolerated-failure init probe, that is a finding to record, not a reason to
 * soften the stub silently.
 *
 * Kernel symbol resolution between modules is by NAME only -- the module loader
 * matches undefined symbols against __ksymtab entries and never sees a C
 * prototype -- so these deliberately uniform `long (void)` signatures resolve
 * ax_proton's references correctly regardless of the real vendor signatures.
 * (MODVERSIONS is off in our defconfig, so no CRC gate applies either; see
 * pkgs/kernel.nix.) What DOES matter is FUNC-vs-OBJECT: all 26 are FUNC in the
 * vendor providers' symtabs (verified with llvm-readelf), so all 26 are
 * functions here.
 *
 * The stubs are __attribute__((used)) and noinline so nothing can be elided,
 * and each is its own symbol (no ICF/alias folding) so the log line identifies
 * the exact edge that was hit.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/errno.h>

#define AX_STUB(name)							\
	noinline long name(void);					\
	long name(void)							\
	{								\
		pr_warn_once("ax_stub: " #name				\
			     " called -- NODE-MODE EDGE HIT\n");	\
		return -ENODEV;						\
	}								\
	EXPORT_SYMBOL(name)

/* ---- ax_npu (9) -------------------------------------------------------- */
AX_STUB(AX_NPU_Kernel_create_task);
AX_STUB(AX_NPU_Kernel_cancel_task);
AX_STUB(AX_NPU_Kernel_destroy_handle);
AX_STUB(AX_NPU_Kernel_get_io_info);
AX_STUB(AX_NPU_Kernel_get_throttle);
AX_STUB(AX_NPU_kernel_set_throttle);	/* lowercase 'k' is the vendor spelling */
AX_STUB(AX_NPU_Kernel_set_isp_conf);
AX_STUB(AX_NPU_Hsk_status_clear);
AX_STUB(AX_NPU_Kernel_vnpu_reset);

/* ---- ax_gdc (7) -------------------------------------------------------- */
AX_STUB(AX_GDC_CallbackRegister);
AX_STUB(AX_GDC_CallbackUnRegister);
AX_STUB(AX_GDC_GrpAlloc);
AX_STUB(AX_GDC_GrpAttrSet);
AX_STUB(AX_GDC_GrpRelease);
AX_STUB(AX_GDC_SendFrame);
AX_STUB(AX_GDC_SetGrpCrop);

/* ---- ax_ivps (7) ------------------------------------------------------- */
AX_STUB(AX_IVPS_DrvSendFrame);
AX_STUB(AX_IVPS_DrvSendFrameEis);
AX_STUB(AX_IVPS_DrvSendFramePtn);
AX_STUB(AX_IVPS_DrvSetGrpCrop);
AX_STUB(AX_IVPS_DrvSetGrpGdcCfg);
AX_STUB(AX_IVPS_DrvSetMirrorFlip);
AX_STUB(AX_IVPS_DrvSetRotation);

/* ---- ax_vpp (3) -------------------------------------------------------- */
AX_STUB(AX_VPP_IspCallbackRegister);
AX_STUB(AX_VPP_IspCallbackUnRegister);
AX_STUB(AX_VPP_IspSendTileInfo);

static int __init ax_stub_init(void)
{
	pr_info("ax_stub: 26 stub symbols live (ax_npu 9 / ax_gdc 7 / ax_ivps 7 / ax_vpp 3).\n");
	pr_info("ax_stub: any 'NODE-MODE EDGE HIT' below is a real ax_proton call into a removed blob.\n");
	return 0;
}

static void __exit ax_stub_exit(void)
{
}

module_init(ax_stub_init);
module_exit(ax_stub_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("open-nanokvm-pro");
MODULE_DESCRIPTION("Logging stubs for the 26 ax_proton imports from ax_npu/ax_gdc/ax_ivps/ax_vpp (issue #56)");
MODULE_VERSION("0.1.0");
