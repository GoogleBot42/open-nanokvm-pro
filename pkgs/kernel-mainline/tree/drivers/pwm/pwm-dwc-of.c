// SPDX-License-Identifier: GPL-2.0
/*
 * DesignWare PWM Controller driver -- OF/platform front end (#84).
 *
 * Upstream ships `pwm-dwc-core.c` (the register logic) behind `pwm-dwc.c`,
 * which is a PCI driver for Intel Elkhart Lake, and a device-tree binding --
 * Documentation/devicetree/bindings/pwm/snps,dw-apb-timers-pwm2.yaml, from
 * SiFive -- that NO driver in the tree matches. This file is that driver.
 *
 * The same IP is memory-mapped on the Axera AX630C, where the vendor calls it
 * `axera,ax620e-pwm`: its register map (LOADCOUNT at n*0x14, CONTROLREG at
 * 0x8 + n*0x14, LOADCOUNT2 at 0xB0 + n*4) is `pwm-dwc.h`'s byte for byte, and
 * the vendor's own device tree names the block's clock gates as bits in the
 * peripheral syscon that the CCF now hands out as clocks. On the NanoKVM-Pro
 * it drives the mini-display's backlight.
 *
 * Two things the PCI front end never has to think about:
 *
 *  - **The input clock is not 100 MHz.** `dwc_pwm_alloc()` hardcodes
 *    `clk_ns = 10`; here it comes from `clk_get_rate()` of the "timer" clock,
 *    which on this SoC is 24 MHz -> 42 ns. The rounding is 0.8 % on the
 *    period and nothing else; threading a rate through the core's arithmetic
 *    is a bigger upstream change than any board needs.
 *
 *  - **Clocks and resets.** The binding makes "bus" and "timer" mandatory.
 *    Resets are not in the binding at all, so they are optional here -- the
 *    AX630C holds a block reset and four per-channel ones over this block.
 *
 * `snps,pwm-number` is deliberately not honoured: `dwc_pwm_alloc()` allocates
 * DWC_TIMERS_TOTAL (8) channels and making the count settable means changing
 * an exported symbol's signature for the PCI driver too. The AX630C block
 * implements four; nothing requests the other four.
 */

#include <linux/clk.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/pwm.h>
#include <linux/reset.h>

#include "pwm-dwc.h"

static int dwc_pwm_of_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct reset_control *rstc;
	struct clk *bus, *timer;
	struct pwm_chip *chip;
	struct dwc_pwm *dwc;
	void __iomem *base;
	unsigned long rate;
	int ret;

	base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(base))
		return PTR_ERR(base);

	/*
	 * Every reset line the node names, deasserted together and left that
	 * way. On this SoC they are the block reset and the per-channel ones;
	 * firmware leaves them deasserted, so this is ownership rather than a
	 * pulse -- and a pulse would be the wrong thing, because on a board
	 * where this drives a backlight it would blink it at every probe.
	 */
	rstc = devm_reset_control_array_get_optional_exclusive(dev);
	if (IS_ERR(rstc))
		return dev_err_probe(dev, PTR_ERR(rstc), "cannot get resets\n");

	ret = reset_control_deassert(rstc);
	if (ret)
		return dev_err_probe(dev, ret, "cannot deassert resets\n");

	bus = devm_clk_get_enabled(dev, "bus");
	if (IS_ERR(bus))
		return dev_err_probe(dev, PTR_ERR(bus), "cannot get the bus clock\n");

	timer = devm_clk_get_enabled(dev, "timer");
	if (IS_ERR(timer))
		return dev_err_probe(dev, PTR_ERR(timer), "cannot get the timer clock\n");

	rate = clk_get_rate(timer);
	if (!rate)
		return dev_err_probe(dev, -EINVAL, "the timer clock reports no rate\n");

	chip = dwc_pwm_alloc(dev);
	if (IS_ERR(chip))
		return PTR_ERR(chip);

	dwc = to_dwc_pwm(chip);
	dwc->base = base;
	dwc->clk_ns = DIV_ROUND_CLOSEST(NSEC_PER_SEC, rate);

	dev_info(dev, "DesignWare PWM, timer clock %lu Hz (%u ns/tick)\n",
		 rate, dwc->clk_ns);

	return devm_pwmchip_add(dev, chip);
}

static const struct of_device_id dwc_pwm_of_match[] = {
	{ .compatible = "snps,dw-apb-timers-pwm2" },
	{ }
};
MODULE_DEVICE_TABLE(of, dwc_pwm_of_match);

static struct platform_driver dwc_pwm_of_driver = {
	.driver = {
		.name = "dwc-pwm-of",
		.of_match_table = dwc_pwm_of_match,
	},
	.probe = dwc_pwm_of_probe,
};
module_platform_driver(dwc_pwm_of_driver);

MODULE_DESCRIPTION("DesignWare PWM Controller (OF)");
MODULE_LICENSE("GPL");
