// SPDX-License-Identifier: GPL-2.0
/*
 * Axera AX630C (AX620E family) DWC3 glue -- issue #82, epic #26.
 *
 * The controller is an unmodified Synopsys DWC3 and mainline's dwc3 core
 * drives it. Everything this file adds lives OUTSIDE the controller's own
 * register window, in the "flash" system syscon at 0x1003_0000, which the
 * clock controller (drivers/clk/axera) already owns as a regmap:
 *
 *   +0x00 [8:6]    the flash-domain AXI bus mux, which is also USB's bus clock
 *   +0x04 bit 12   usb2 reference clock gate (24 MHz)
 *   +0x04 bit 14   usb2 alternate reference clock gate
 *   +0x08 bit 5    usb2 AXI bus clock gate
 *   +0x14 bit 24   USB2 PHY software reset, active high
 *   +0x14 bit 25   USB2 VCC software reset, active high
 *   +0x40 bit 6    VBUSVALID
 *
 * The clocks and the two resets are DT phandles into that clock controller
 * (#80), so the only register this file touches directly is VBUSVALID.
 *
 * VBUSVALID is why a glue driver exists at all. This SoC's USB2 port has no
 * VBUS comparator wired to the controller: software has to tell the core
 * whether VBUS is present. In peripheral mode the bit must be SET or the
 * gadget never pulls up D+ and the host never sees a device; in host mode it
 * must be CLEAR, because then the port drives VBUS itself. Nothing in the
 * mainline dwc3 core or in dwc3-of-simple can express that, and getting it
 * wrong produces a controller that probes perfectly and enumerates nothing.
 *
 * Written from a behavioural description of the vendor glue's register effects
 * (offsets, bits and the probe-time write order) -- not from its code.
 *
 * NOT here, deliberately:
 *
 *  - No PHY node. This is a UTMI+ high-speed-only port whose entire PHY
 *    control surface is the one reset bit above; there is no register file for
 *    a generic PHY driver to own.
 *  - No pin state. The pinctrl driver's "usb" group is MICN_R_D / MICP_R_D
 *    muxed to USB_OVRCUR / USB_POWER_EN, which are HOST-mode overcurrent and
 *    VBUS-enable signals. The vendor board dts never claims them and this
 *    board is a peripheral, so claiming them here would mux two pads away from
 *    whatever else the board does with them for no gain.
 *  - No extcon or role switch. The vendor board dts wires OTG ID detection to
 *    a raw GPIO (GPIO1_A4) through linux,extcon-usb-gpio, and there is no GPIO
 *    controller node until #81. See the dwc3 node in dts/ax630c.dtsi.
 */

#include <linux/bits.h>
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/mfd/syscon.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/reset.h>
#include <linux/string.h>

/* flash syscon (0x1003_0000) offsets */
#define AX630C_FLASH_USB2_CTRL		0x40
#define  AX630C_USB2_VBUSVALID		BIT(6)

/*
 * The reset pulse width. The vendor glue writes the set alias and then the
 * clear alias back to back with no delay at all, which on this hardware is
 * two AXI writes apart; a couple of microseconds is the same thing with a
 * number attached, and matches what every other dwc3 glue in the tree does.
 */
#define AX630C_USB_RESET_US		2

/*
 * No driver state outlives probe(). The clocks and resets are devm-managed and
 * nothing here reconfigures them afterwards; VBUSVALID is written once. A
 * struct to hold copies of them would be state nothing reads.
 */
static void ax630c_dwc3_assert(void *data)
{
	reset_control_assert(data);
}

/*
 * dr_mode lives on the CHILD (the snps,dwc3 core node), because that is the
 * node the dwc3 binding puts it on. Read it as a string rather than through
 * usb_get_dr_mode(), which takes a struct device and there is no device for
 * the child until of_platform_populate() below has run.
 */
static bool ax630c_dwc3_is_host(struct device_node *np)
{
	struct device_node *child;
	const char *mode = NULL;
	bool host;

	child = of_get_compatible_child(np, "snps,dwc3");
	if (!child)
		return false;

	of_property_read_string(child, "dr_mode", &mode);
	host = mode && !strcmp(mode, "host");
	of_node_put(child);

	return host;
}

static int ax630c_dwc3_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *np = dev->of_node;
	struct reset_control *resets;
	struct clk_bulk_data *clks;
	struct regmap *syscon;
	int num_clks, ret;
	bool host;

	syscon = syscon_regmap_lookup_by_phandle(np, "axera,flash-syscon");
	if (IS_ERR(syscon))
		return dev_err_probe(dev, PTR_ERR(syscon),
				     "no axera,flash-syscon regmap\n");

	/*
	 * Clocks before resets, in the vendor's order. A reset released into a
	 * block with no clock running leaves the block's synchronous state
	 * undefined until the clock arrives; releasing into a clocked block is
	 * the sequence this hardware has always been brought up with.
	 */
	num_clks = devm_clk_bulk_get_all_enabled(dev, &clks);
	if (num_clks < 0)
		return dev_err_probe(dev, num_clks,
				     "failed to get the USB clocks\n");

	resets = devm_reset_control_array_get_optional_exclusive(dev);
	if (IS_ERR(resets))
		return dev_err_probe(dev, PTR_ERR(resets),
				     "failed to get the USB resets\n");

	/*
	 * Pulse, do not merely deassert. These two lines are active high and
	 * not self-clearing, and firmware leaves them released -- so a
	 * deassert-only bring-up would never reset the PHY at all, which is the
	 * one thing the reset exists for. Asserting first is also the first
	 * real exercise of the #80 reset controller's .assert path.
	 */
	ret = reset_control_assert(resets);
	if (ret)
		return dev_err_probe(dev, ret, "failed to assert the USB resets\n");

	udelay(AX630C_USB_RESET_US);

	ret = reset_control_deassert(resets);
	if (ret)
		return dev_err_probe(dev, ret, "failed to release the USB resets\n");

	ret = devm_add_action_or_reset(dev, ax630c_dwc3_assert, resets);
	if (ret)
		return ret;

	/*
	 * VBUSVALID, before the core node is populated: the dwc3 core starts
	 * the gadget from its own probe, and a gadget that starts while the
	 * core believes VBUS is absent stays disconnected.
	 */
	host = ax630c_dwc3_is_host(np);
	ret = regmap_update_bits(syscon, AX630C_FLASH_USB2_CTRL,
				 AX630C_USB2_VBUSVALID,
				 host ? 0 : AX630C_USB2_VBUSVALID);
	if (ret)
		return dev_err_probe(dev, ret, "failed to set VBUSVALID\n");

	/*
	 * Logged, not silent. This bit and the clock count are the two facts
	 * that decide whether the port will enumerate, and a board that probes
	 * cleanly and enumerates nothing gives no other clue which one was
	 * wrong -- the same lesson #77 learned about the RGMII tx mux.
	 */
	dev_info(dev, "%d clocks, VBUSVALID %s (%s mode)\n", num_clks,
		 host ? "cleared" : "set", host ? "host" : "peripheral");

	/*
	 * devm, so the core node is depopulated before the clocks are disabled
	 * and the resets re-asserted -- the ordering an open-coded remove()
	 * gets wrong most often.
	 */
	return devm_of_platform_populate(dev);
}

static const struct of_device_id ax630c_dwc3_match[] = {
	{ .compatible = "axera,ax630c-dwc3" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ax630c_dwc3_match);

/*
 * No dev_pm_ops. Nothing on this board suspends -- there is no PSCI
 * SYSTEM_SUSPEND on this TF-A and the appliance never sleeps -- and untested
 * suspend callbacks that gate the flash-domain clocks are a liability, not a
 * feature. When suspend is real, the vendor sequence to reproduce is: assert
 * both resets and gate all three clocks on the way down, and the reverse plus
 * a fresh VBUSVALID write on the way up.
 */
static struct platform_driver ax630c_dwc3_driver = {
	.probe = ax630c_dwc3_probe,
	.driver = {
		.name = "axera-dwc3",
		.of_match_table = ax630c_dwc3_match,
	},
};
module_platform_driver(ax630c_dwc3_driver);

MODULE_DESCRIPTION("Axera AX630C DWC3 glue driver");
MODULE_LICENSE("GPL");
