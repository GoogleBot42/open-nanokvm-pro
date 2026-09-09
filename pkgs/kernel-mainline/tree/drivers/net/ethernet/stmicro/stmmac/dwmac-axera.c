// SPDX-License-Identifier: GPL-2.0
/*
 * Axera AX630C (AX620E family) DWMAC 4.10a glue -- issue #77, epic #26.
 *
 * The MAC is an unmodified Synopsys DWMAC 4.10a and mainline stmmac drives it.
 * Everything this file adds lives OUTSIDE the MAC's own register window, in the
 * "flash" system syscon at 0x1003_0000, which the clock controller
 * (drivers/clk/axera) already owns as a regmap:
 *
 *   +0x00 [5:4]   RGMII transmit clock mux (10/100/1000 Mbit) -- driven
 *                 through the clock framework, not from here
 *   +0x14 bit 8   EMAC block software reset, active high
 *   +0x28 [10:9]  PHY interface select: bit 9 = RGMII (vs RMII),
 *                 bit 10 = drive the external pads (vs the on-chip EPHY).
 *                 The MAC samples this at the release of the block reset, so
 *                 it must be written BEFORE the reset -- see the probe.
 *
 * The board wires an external JLSemi JL2101 in RGMII mode, so the on-chip EPHY
 * is irrelevant here: firmware leaves it held in reset (+0x14 bit 9 set) and
 * shut down (+0x20 bit 0 set), and this driver touches neither. Measured on the
 * running device 2026-09-06; see docs/reference/mainline/ethernet-boot-20260906/.
 *
 * Written from a behavioural description of the vendor glue's register effects
 * plus register reads from the live board.
 */

#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/mfd/syscon.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/phy.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>

#include "stmmac_platform.h"

/* flash syscon (0x1003_0000) offsets */
#define AX630C_FLASH_SW_RST		0x14
#define  AX630C_EMAC_SW_RST		BIT(8)
#define AX630C_FLASH_EMAC0		0x28
#define  AX630C_EMAC_PHY_IF		GENMASK(10, 9)
#define   AX630C_EMAC_PHY_IF_RGMII	(BIT(10) | BIT(9))

/*
 * The external PHY's RSTn is GPIO1_A27 (pad EPHY_RSTN) and is no longer this
 * driver's business: #81 gave the SoC a GPIO controller, so the line is
 * reset-gpios on the PHY node and the MDIO core pulses it, with the same 15 ms
 * assert and 75 ms settle, before it reads the PHY's ID. Firmware does not
 * drive it -- on a cold or chip reset every GPIO line comes up an input -- so
 * the pulse still has to happen; it just happens somewhere generic.
 */

struct ax630c_dwmac {
	struct device *dev;
	struct regmap *syscon;
};

/*
 * The RGMII transmit clock mux does not feed TXC directly: the block halves it.
 * epll_5m / epll_50m / epll_250m are the three mux inputs and they select
 * 10 / 100 / 1000 Mbit, i.e. exactly twice rgmii_clock(). So this cannot be the
 * generic stmmac_set_clk_tx_rate() -- that would ask for 125 MHz, get epll_50m
 * as the closest input at or below it, and run a gigabit link off a 100 Mbit
 * transmit clock.
 */
static int ax630c_dwmac_set_clk_tx_rate(void *bsp_priv, struct clk *clk_tx_i,
					phy_interface_t interface, int speed)
{
	struct ax630c_dwmac *dwmac = bsp_priv;
	long rate = rgmii_clock(speed);
	int ret;

	if (rate < 0)
		return 0;

	ret = clk_set_rate(clk_tx_i, rate * 2);

	/*
	 * Logged, not silent: this mux is the one clock on the board a
	 * consumer moves at runtime, and a board that links but passes no
	 * traffic is exactly what a mux that did not move looks like.
	 */
	dev_info(dwmac->dev, "%d Mbit/s: RGMII tx clock %lu Hz (asked %ld)\n",
		 speed, clk_get_rate(clk_tx_i), rate * 2);

	return ret;
}

/*
 * Pulse the MAC's block reset. stmmac issues its own DMA software reset, but
 * that does not reach the block-level state this bit clears, and the bit's
 * reset value is not established -- so assert and release rather than assume
 * firmware left it released.
 */
static int ax630c_dwmac_reset(struct ax630c_dwmac *dwmac)
{
	int ret;

	ret = regmap_update_bits(dwmac->syscon, AX630C_FLASH_SW_RST,
				 AX630C_EMAC_SW_RST, AX630C_EMAC_SW_RST);
	if (ret)
		return ret;

	usleep_range(5000, 6000);

	return regmap_update_bits(dwmac->syscon, AX630C_FLASH_SW_RST,
				  AX630C_EMAC_SW_RST, 0);
}

static int ax630c_dwmac_set_interface(struct ax630c_dwmac *dwmac,
				      phy_interface_t interface)
{
	if (!phy_interface_mode_is_rgmii(interface)) {
		dev_err(dwmac->dev, "unsupported phy-mode %s\n",
			phy_modes(interface));
		return -EINVAL;
	}

	return regmap_update_bits(dwmac->syscon, AX630C_FLASH_EMAC0,
				  AX630C_EMAC_PHY_IF,
				  AX630C_EMAC_PHY_IF_RGMII);
}

static int ax630c_dwmac_probe(struct platform_device *pdev)
{
	struct plat_stmmacenet_data *plat_dat;
	struct stmmac_resources stmmac_res;
	struct device *dev = &pdev->dev;
	struct ax630c_dwmac *dwmac;
	struct clk *ephy_clk;
	int ret;

	ret = stmmac_get_platform_resources(pdev, &stmmac_res);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to get platform resources\n");

	plat_dat = devm_stmmac_probe_config_dt(pdev, stmmac_res.mac);
	if (IS_ERR(plat_dat))
		return dev_err_probe(dev, PTR_ERR(plat_dat),
				     "failed to parse DT parameters\n");

	dwmac = devm_kzalloc(dev, sizeof(*dwmac), GFP_KERNEL);
	if (!dwmac)
		return -ENOMEM;

	dwmac->dev = dev;
	dwmac->syscon = syscon_regmap_lookup_by_phandle(dev->of_node,
						       "axera,flash-syscon");
	if (IS_ERR(dwmac->syscon))
		return dev_err_probe(dev, PTR_ERR(dwmac->syscon),
				     "no axera,flash-syscon regmap\n");

	/*
	 * The 25 MHz reference the external PHY runs from. stmmac has no
	 * concept of it, so it is simply held enabled for the driver's life.
	 * Its mux (+0x00 [23:22]) selects 25 MHz at reset and nothing changes
	 * it, so no rate is requested here.
	 */
	ephy_clk = devm_clk_get_optional_enabled(dev, "ephy");
	if (IS_ERR(ephy_clk))
		return dev_err_probe(dev, PTR_ERR(ephy_clk),
				     "failed to get the ephy clock\n");

	plat_dat->clk_tx_i = devm_clk_get_enabled(dev, "tx");
	if (IS_ERR(plat_dat->clk_tx_i))
		return dev_err_probe(dev, PTR_ERR(plat_dat->clk_tx_i),
				     "failed to get the tx clock\n");

	plat_dat->set_clk_tx_rate = ax630c_dwmac_set_clk_tx_rate;
	plat_dat->bsp_priv = dwmac;

	/*
	 * SELECT THE INTERFACE, THEN RESET. Not the other way round: the MAC
	 * SAMPLES the select at the release of its block reset and reports
	 * what it sampled in the DMA HW feature register, which is what stmmac
	 * prints as "Active PHY interface". Writing the select afterwards
	 * changes the pad routing but not the MAC's idea of what it is talking
	 * to, and the MDIO bus then finds nothing:
	 *
	 *   axera-dwmac 104c0000.ethernet: Active PHY interface: RMII (4)
	 *   mdio_bus stmmac-0: MDIO device at address 1 is missing.
	 *
	 * The old order worked for a year because the vendor-derived U-Boot
	 * leaves the select at RGMII already (+0x28 = 0x600) and the write was
	 * a no-op. Mainline U-Boot has no ethernet driver and leaves it at 0,
	 * so on that loader the same kernel booted to userspace with no
	 * network at all -- which, on a board whose only channel is SSH, is
	 * indistinguishable from a kernel that never started (#89 rung 2q).
	 */
	ret = ax630c_dwmac_set_interface(dwmac, plat_dat->phy_interface);
	if (ret)
		return dev_err_probe(dev, ret, "PHY interface select failed\n");

	ret = ax630c_dwmac_reset(dwmac);
	if (ret)
		return dev_err_probe(dev, ret, "EMAC block reset failed\n");

	/*
	 * Pad select and block reset are done, so the PHY now leaves reset
	 * into a MAC that is already out of reset and already told which pads
	 * to drive. That ordering is why the reset-gpios pulse belongs to the
	 * MDIO core: it happens inside stmmac_dvr_probe(), when the bus
	 * registers, and therefore strictly after both writes above.
	 */
	return stmmac_dvr_probe(dev, plat_dat, &stmmac_res);
}

static const struct of_device_id ax630c_dwmac_match[] = {
	{ .compatible = "axera,ax630c-dwmac" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ax630c_dwmac_match);

static struct platform_driver ax630c_dwmac_driver = {
	.probe = ax630c_dwmac_probe,
	.remove = stmmac_pltfr_remove,
	.driver = {
		.name = "axera-dwmac",
		.pm = &stmmac_pltfr_pm_ops,
		.of_match_table = ax630c_dwmac_match,
	},
};
module_platform_driver(ax630c_dwmac_driver);

MODULE_DESCRIPTION("Axera AX630C DWMAC glue driver");
MODULE_LICENSE("GPL");
