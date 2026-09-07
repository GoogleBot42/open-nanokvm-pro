// SPDX-License-Identifier: GPL-2.0
/*
 * Axera AX630C (AX620E family) reset controller.
 *
 * The reset lines live in the same syscon windows as the clocks -- one bit per
 * line in a value word next to the clock gates -- so they are provided by the
 * clock-controller nodes rather than by nodes of their own. Two DT nodes over
 * one window would mean two regmaps, two locks and a read-modify-write race
 * against the clock driver for no gain.
 *
 * Written from docs/reference/mainline/reset-model-20260906.md, a behavioural
 * specification derived from the vendor GPL device tree and bootloaders. Issue
 * #80. The tables are in clk-ax630c-tables.c with the clock tables.
 *
 * Semantics, all established in that document:
 *
 *  - Active high and not self-clearing: a 1 in the bit HOLDS the block in
 *    reset until a 0 is written back.
 *  - Nothing is programmed at probe. Firmware leaves every line where the boot
 *    chain left it and a line moves only when a consumer asks, which is what
 *    the vendor driver does and what a mainline driver must do -- this window
 *    holds the resets of blocks that are already running.
 */

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/device.h>
#include <linux/of.h>
#include <linux/regmap.h>
#include <linux/reset-controller.h>

#include "clk-ax630c.h"

/*
 * The only assert width anywhere in the vendor stack: U-Boot holds the gzip
 * engine in reset for 10 us between its set and clear writes.
 */
#define AX630C_RESET_PULSE_US	10

struct ax630c_reset {
	struct reset_controller_dev rcdev;
	struct regmap *regmap;
	const struct ax630c_clk_desc *desc;
};

#define to_ax630c_reset(_rcdev) \
	container_of(_rcdev, struct ax630c_reset, rcdev)

static int ax630c_reset_set(struct reset_controller_dev *rcdev,
			    unsigned long id, bool assert)
{
	struct ax630c_reset *rst = to_ax630c_reset(rcdev);
	const struct ax630c_reset_line *line = &rst->desc->resets->lines[id];

	return ax630c_write_bits_regmap(rst->regmap, rst->desc, line->reg,
					BIT(line->bit),
					assert ? BIT(line->bit) : 0);
}

static int ax630c_reset_assert(struct reset_controller_dev *rcdev,
			       unsigned long id)
{
	return ax630c_reset_set(rcdev, id, true);
}

static int ax630c_reset_deassert(struct reset_controller_dev *rcdev,
				 unsigned long id)
{
	return ax630c_reset_set(rcdev, id, false);
}

static int ax630c_reset_reset(struct reset_controller_dev *rcdev,
			      unsigned long id)
{
	int ret;

	ret = ax630c_reset_set(rcdev, id, true);
	if (ret)
		return ret;

	udelay(AX630C_RESET_PULSE_US);

	return ax630c_reset_set(rcdev, id, false);
}

/*
 * The value word reads back what was written, so status is a plain read. The
 * vendor provider implements neither this nor .reset; both are free here.
 */
static int ax630c_reset_status(struct reset_controller_dev *rcdev,
			       unsigned long id)
{
	struct ax630c_reset *rst = to_ax630c_reset(rcdev);
	const struct ax630c_reset_line *line = &rst->desc->resets->lines[id];
	unsigned int val;
	int ret;

	ret = regmap_read(rst->regmap, line->reg, &val);
	if (ret)
		return ret;

	return !!(val & BIT(line->bit));
}

static const struct reset_control_ops ax630c_reset_ops = {
	.assert = ax630c_reset_assert,
	.deassert = ax630c_reset_deassert,
	.reset = ax630c_reset_reset,
	.status = ax630c_reset_status,
};

int ax630c_reset_register(struct device *dev, struct regmap *regmap,
			  const struct ax630c_clk_desc *desc)
{
	struct ax630c_reset *rst;

	if (!desc->resets)
		return 0;

	/*
	 * A device tree that does not ask for reset lines does not get a
	 * provider. The property is what makes the node a reset controller;
	 * registering without it would advertise a phandle nothing can name.
	 */
	if (!of_property_present(dev->of_node, "#reset-cells"))
		return 0;

	rst = devm_kzalloc(dev, sizeof(*rst), GFP_KERNEL);
	if (!rst)
		return -ENOMEM;

	rst->regmap = regmap;
	rst->desc = desc;
	rst->rcdev.owner = THIS_MODULE;
	rst->rcdev.ops = &ax630c_reset_ops;
	rst->rcdev.of_node = dev->of_node;
	rst->rcdev.nr_resets = desc->resets->num_lines;
	/*
	 * Set here, at registration, so the core's args_count check passes.
	 * The vendor provider filled this in from inside of_xlate instead and
	 * had to comment the check out of drivers/reset/core.c to make its
	 * first lookup succeed.
	 */
	rst->rcdev.of_reset_n_cells = 1;

	return devm_reset_controller_register(dev, &rst->rcdev);
}
