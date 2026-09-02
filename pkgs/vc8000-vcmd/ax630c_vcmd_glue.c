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
#include <linux/clk.h>
#include <linux/reset.h>
#include <linux/of.h>
#include <linux/of_irq.h>

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

/*
 * Coherent-pool carveout (issue #49, the no-flash path). The shipping kernel
 * has no CMA, so vcmd_mem_init()'s three 2MB dma_alloc_attrs(FORCE_CONTIGUOUS)
 * pools cannot come from the page allocator. Instead we declare a fixed
 * physically-contiguous region for this device with
 * dma_declare_coherent_memory(); dma_alloc_attrs() consults the device's
 * declared region FIRST (include/linux/dma-mapping.h), so the pools allocate
 * from it with no kernel or DTB change.
 *
 * Region: the TOP coherent_size of the CMM pool. Since #53 this is a FORMAL
 * slice -- the curated boot loader (pkgs/rootfs/ax-load-drv.sh) derives the
 * whole DMA map from the board's pool geometry and passes coherent_base /
 * coherent_size (and framebuf_base/size, framebuf_alloc.c) here, lowering
 * ax_cmm's cmmpool= ceiling to match, so nothing else can ever allocate into
 * it. The defaults below are the 1G-board values that map computes (pool
 * 0x73800000-0x7FFFFFFF, so 0x7F800000 + 8MB) and exist only so an
 * unparameterized insmod still works there -- a different board/mem= puts the
 * pool elsewhere and the loader's parameters are then load-bearing.
 * See docs/vcmd-cma-unblock.md, "DMA memory map".
 */
static unsigned long coherent_base = 0x7F800000UL;
static unsigned long coherent_size = 0x00800000UL;   /* 8MB: 3x2MB pools + slack */
module_param(coherent_base, ulong, 0444);
MODULE_PARM_DESC(coherent_base, "phys base of the coherent DMA carveout");
module_param(coherent_size, ulong, 0444);
MODULE_PARM_DESC(coherent_size, "size of the coherent DMA carveout (0 = don't declare)");

/*
 * VENC block clock. The vendor DTS declares venc@4010000 with
 * clocks = <&vpu_clk AX620X_CLK_VENC_EB> ("clk_venc_eb"), served by the OPEN
 * in-tree clk driver (drivers/clk/axera/clk-ax620e.c). The vendor stack gates
 * this clock on/off around each encode from userspace; unclocked, the whole
 * 0x4010000 block reads the 0xDEADBEEF bus poison (hwid probe fails). We hold
 * it enabled for the driver's lifetime.
 *
 * RESET: the block also comes out of a cold boot in RESET, and clock alone is
 * not enough -- with the clock on but reset asserted the block STILL reads
 * 0xDEADBEEF (device-proven 2026-08-31: the first boot where vendor ax_venc
 * never loaded, vcmd_mem_init found hwid=0xdeadbeef and init failed). The
 * vendor ax_venc.ko deasserts venc_rst at its load; every prior open-driver
 * run rode on that. As the SHIPPED default (#25) no vendor venc loads first,
 * so we MUST deassert it ourselves via the open Axera reset driver
 * (CONFIG_AXERA_RESET_AX620E; DT `resets = <&vpu_reset_async ...>`,
 * reset-name "venc_rst").
 */
static struct clk *venc_clk;
static struct reset_control *venc_rst;

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

/*
 * Linux IRQ for the VCMD engine, resolved from the DT node (GIC_SPI 93 in the
 * vendor dtsi). Without it the core's initial self-test cmdbuf completes in
 * hardware but nothing wakes the wait queue and insmod hangs (proven on
 * device). of_irq_get() creates the GIC mapping even though the node is
 * status="disabled" and unbound.
 */
static int venc_irq = -1;

static int ax630c_venc_clk_on(void)
{
	/* Note the space in the vendor compatible string: "axera, venc-encoder". */
	struct device_node *np = of_find_compatible_node(NULL, NULL,
							 "axera, venc-encoder");
	if (!np) {
		pr_err("ax630c-venc-vcmd: no 'axera, venc-encoder' DT node\n");
		return -ENODEV;
	}
	venc_irq = of_irq_get(np, 0);
	if (venc_irq <= 0) {
		pr_warn("ax630c-venc-vcmd: of_irq_get failed (%d), running without IRQ\n",
			venc_irq);
		venc_irq = -1;
	}
	venc_clk = of_clk_get(np, 0);
	if (IS_ERR(venc_clk)) {
		pr_err("ax630c-venc-vcmd: of_clk_get failed: %ld\n",
		       PTR_ERR(venc_clk));
		venc_clk = NULL;
		of_node_put(np);
		return -ENODEV;
	}
	if (clk_prepare_enable(venc_clk)) {
		pr_err("ax630c-venc-vcmd: clk_prepare_enable failed\n");
		clk_put(venc_clk);
		venc_clk = NULL;
		of_node_put(np);
		return -EIO;
	}
	pr_info("ax630c-venc-vcmd: clk_venc_eb enabled\n");

	/* Deassert the VENC block reset (see the file header). Without this the
	 * clocked block reads 0xDEADBEEF on a boot where vendor ax_venc never ran.
	 * Non-fatal-but-loud if the reset can't be obtained: on a warm cycle after
	 * a vendor encode the block may already be deasserted, so still try init. */
	venc_rst = of_reset_control_get_exclusive(np, "venc_rst");
	of_node_put(np);
	if (IS_ERR(venc_rst)) {
		pr_warn("ax630c-venc-vcmd: reset_control_get(venc_rst) failed: %ld -- "
			"proceeding (block may already be out of reset)\n",
			PTR_ERR(venc_rst));
		venc_rst = NULL;
	} else if (reset_control_deassert(venc_rst)) {
		pr_warn("ax630c-venc-vcmd: reset_control_deassert(venc_rst) failed -- "
			"proceeding\n");
	} else {
		pr_info("ax630c-venc-vcmd: venc_rst deasserted\n");
	}
	return 0;
}

static void ax630c_venc_clk_off(void)
{
	if (venc_rst) {
		/* Leave the block DEASSERTED (same end-state as after a vendor
		 * encode) so a later vendor-venc or vcmd reload still finds live
		 * HW; just drop our reference. */
		reset_control_put(venc_rst);
		venc_rst = NULL;
	}
	if (venc_clk) {
		clk_disable_unprepare(venc_clk);
		clk_put(venc_clk);
		venc_clk = NULL;
	}
}

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

	if (coherent_size) {
		ret = dma_declare_coherent_memory(&venc_pdev->dev,
						  coherent_base, coherent_base,
						  coherent_size,
						  DMA_MEMORY_EXCLUSIVE);
		if (ret) {
			pr_err("ax630c-venc-vcmd: dma_declare_coherent_memory(0x%lx, 0x%lx) failed: %d\n",
			       coherent_base, coherent_size, ret);
			platform_device_unregister(venc_pdev);
			venc_pdev = NULL;
			return ret;
		}
		pr_info("ax630c-venc-vcmd: coherent carveout 0x%lx+0x%lx declared\n",
			coherent_base, coherent_size);
	}

	ret = ax630c_venc_clk_on();
	if (ret) {
		if (coherent_size)
			dma_release_declared_memory(&venc_pdev->dev);
		platform_device_unregister(venc_pdev);
		venc_pdev = NULL;
		return ret;
	}

	/* Single VC8000E encoder core (JPEG/jenc is a separate device on AX630C). */
	venc_vcmd_core_num = 1;
	vc8000e_vcmd_core_array[0].vcmd_base_addr = AX630C_VENC_VCMD_BASE;
	vc8000e_vcmd_core_array[0].vcmd_irq       = venc_irq;

	ret = vc8000e_vcmd_init();
	if (ret) {
		pr_err("ax630c-venc-vcmd: vc8000e_vcmd_init failed: %d\n", ret);
		ax630c_venc_clk_off();
		if (coherent_size)
			dma_release_declared_memory(&venc_pdev->dev);
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
	ax630c_venc_clk_off();
	if (venc_pdev) {
		if (coherent_size)
			dma_release_declared_memory(&venc_pdev->dev);
		platform_device_unregister(venc_pdev);
		venc_pdev = NULL;
	}
}

module_init(ax630c_vcmd_init);
module_exit(ax630c_vcmd_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("open-nanokvm-pro");
MODULE_DESCRIPTION("AX630C platform glue for the VeriSilicon VC8000E VCMD driver");
