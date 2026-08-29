// SPDX-License-Identifier: GPL-2.0
/*
 * AX630C platform glue for the VeriSilicon VC8000E VCMD command-engine driver.
 *
 * The eswin EIC7X copy of the VeriSilicon VCMD driver (eswin/vc8000_vcmd_driver.c,
 * dual MIT/GPL) is split into a portable command-engine core and a
 * platform-specific probe layer (eswin's vc8000e_driver.c). That eswin probe
 * layer is bound to the EIC7700 device tree (vcmd-core/axife-core bindings),
 * its SMMU dynamic-SID scheme, and its clk/reset/TBU/pm-runtime plumbing, none
 * of which exist on the Axera AX630C. This file is the AX630C replacement for
 * that probe layer: it defines the handful of symbols the VCMD core imports from
 * the platform layer and stands up a minimal char-device instance.
 *
 * This is open-source driver-replacement work: it re-implements the AX630C's own
 * VCMD kernel driver from the public VeriSilicon lineage so the device can run a
 * blob-free encode-submission path in place of the vendor ax_venc.ko.
 *
 * Status: builds cleanly as an out-of-tree .ko against the from-source AX630C
 * 4.19.125 kernel. Runtime bring-up on hardware (DMA carveout wiring, IRQ line,
 * clock/reset) is deliberately NOT wired here yet -- see PROVENANCE.md.
 */

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/init.h>
#include <linux/platform_device.h>
#include <linux/dma-mapping.h>
#include <linux/slab.h>

#include "vc8000_driver.h"      /* struct vcmd_config, extern venc_pdev, ABI */

/*
 * AX630C VC8000E VCMD command-engine base. Recovered by device tracing
 * (docs/blob-replacement.md, docs/reference/vcenc-open/): /proc/iomem shows the
 * encoder command engine at vsi_vcx@0x4010000, the encoder core sits at
 * VCMD_base + 0x1000 (submodule_main_addr below matches the Stage-0 finding that
 * the encoder-core register file begins at ASIC byte 0x1000), and the engine
 * reports hw_version_id = 0x43421500 (VCMD v1.5.0).
 */
#define AX630C_VENC_VCMD_BASE       (0x04010000UL)
#define AX630C_VENC_VCMD_IRQ        (-1)   /* not wired yet; -1 disables request_irq */

/* --- symbols the VCMD core (eswin/vc8000_vcmd_driver.c) imports --- */
struct platform_device *venc_pdev = NULL;
struct platform_device *venc_pdev_d1 = NULL;   /* AX630C is single-die: always NULL */
EXPORT_SYMBOL(venc_pdev);
EXPORT_SYMBOL(venc_pdev_d1);

extern int venc_vcmd_core_num;                 /* defined in the VCMD core */
extern struct vcmd_config vc8000e_vcmd_core_array[];  /* defined via vc8000_vcmd_cfg.h */

int vc8000e_vcmd_init(void);                    /* vcmd_mem_init() + hantroenc_vcmd_init() */
int vc8000e_vcmd_cleanup(void);

/*
 * PM / reset hooks. On the AX630C the VCMD block's clock/reset/power is handled
 * by the standard DT clk/reset framework (docs: "clock/reset/power -- no gap").
 * Until that is wired to a real DT node these are no-ops -- correct for a build
 * and for a first bring-up where firmware/U-Boot leaves the block clocked.
 */
int enc_pm_runtime_get(u32 core_id) { (void)core_id; return 0; }
int enc_pm_runtime_put(u32 core_id) { (void)core_id; return 0; }
int enc_reset_system(u32 core_id)   { (void)core_id; return 0; }
EXPORT_SYMBOL(enc_pm_runtime_get);
EXPORT_SYMBOL(enc_pm_runtime_put);
EXPORT_SYMBOL(enc_reset_system);

static int __init ax630c_vcmd_init(void)
{
	int ret;

	/*
	 * Stand up a bare platform_device to own the three coherent VCMD pools
	 * (command / status / register) that vcmd_mem_init() allocates with
	 * dma_alloc_attrs(&venc_pdev->dev, ...). A real port binds this to the
	 * AX630C DT node + its reserved-memory carveout; register_simple is
	 * enough to give the core a device with a valid DMA mask to build/link
	 * and to allocate from the default coherent pool.
	 */
	venc_pdev = platform_device_register_simple("ax630c-venc-vcmd", -1, NULL, 0);
	if (IS_ERR(venc_pdev)) {
		ret = PTR_ERR(venc_pdev);
		venc_pdev = NULL;
		pr_err("ax630c-venc-vcmd: platform_device_register_simple failed: %d\n", ret);
		return ret;
	}
	dma_coerce_mask_and_coherent(&venc_pdev->dev, DMA_BIT_MASK(32));

	/* Single VC8000E encoder core (JPEG/jenc is a separate device on AX630C). */
	venc_vcmd_core_num = 1;
	vc8000e_vcmd_core_array[0].vcmd_base_addr = AX630C_VENC_VCMD_BASE;
	vc8000e_vcmd_core_array[0].vcmd_irq       = AX630C_VENC_VCMD_IRQ;

	ret = vc8000e_vcmd_init();
	if (ret) {
		pr_err("ax630c-venc-vcmd: vc8000e_vcmd_init failed: %d\n", ret);
		platform_device_unregister(venc_pdev);
		venc_pdev = NULL;
		return ret;
	}
	pr_info("ax630c-venc-vcmd: VC8000E VCMD driver initialised (base 0x%lx)\n",
		AX630C_VENC_VCMD_BASE);
	return 0;
}

static void __exit ax630c_vcmd_exit(void)
{
	vc8000e_vcmd_cleanup();
	if (venc_pdev) {
		platform_device_unregister(venc_pdev);
		venc_pdev = NULL;
	}
}

module_init(ax630c_vcmd_init);
module_exit(ax630c_vcmd_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("open-nanokvm-pro");
MODULE_DESCRIPTION("AX630C platform glue for the VeriSilicon VC8000E VCMD driver");
