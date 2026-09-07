// SPDX-License-Identifier: GPL-2.0
/*
 * Axera AX630C (AX620E family) clock controller.
 *
 * The SoC splits its clock tree across nine syscon windows. One platform
 * driver serves them all; of_device_id match data selects the table.
 *
 * Written from docs/reference/mainline/clk-model-20260906.md -- a behavioural
 * specification derived from the vendor GPL sources and reconciled clock by
 * clock against a running device. Issue #80.
 *
 * Two things here are not what a generic CCF driver would do, and both are
 * deliberate:
 *
 *  - Register access goes through the syscon regmap rather than a private
 *    ioremap. These windows carry reset and pinmux-adjacent registers too, so
 *    the reset driver writes the same words; sharing the regmap shares the
 *    lock. Where a controller documents write-1-to-set / write-1-to-clear
 *    aliases we use those instead of read-modify-write, so a bit update cannot
 *    clobber a neighbouring field that firmware or the reset driver just set.
 *
 *  - The dividers are not clk_divider. The encoding is val 0 => /1 and
 *    val n => /2n, and a write only takes effect after an update-bit pulse.
 *
 * Copyright (c) 2026 the open-nanokvm-pro contributors.
 */

#include <linux/bitfield.h>
#include <linux/clk-provider.h>
#include <linux/delay.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/regmap.h>
#include <linux/slab.h>

#include "clk-ax630c.h"

struct ax630c_clk_data {
	struct regmap *regmap;
	const struct ax630c_clk_desc *desc;
	struct clk_hw_onecell_data *onecell;
};

/* A registered register-backed clock (mux, divider or gate). */
struct ax630c_hw {
	struct clk_hw hw;
	struct regmap *regmap;
	const struct ax630c_clk_desc *desc;
	const struct ax630c_clk *info;
};

#define to_ax630c_hw(_hw) container_of(_hw, struct ax630c_hw, hw)

/*
 * The divider update pulse. The vendor holds the bit for 1 ms; nothing in the
 * hardware documentation justifies a specific figure, so keep it and stay on
 * the safe side. Only ever called from set_rate, which may sleep.
 */
#define AX630C_DIV_UPDATE_US	1000

/* --- register helpers --------------------------------------------------- */

static const struct ax630c_alias *ax630c_alias_for(const struct ax630c_clk_desc *desc,
						   u32 offset,
						   struct ax630c_alias *scratch)
{
	unsigned int i;

	/* periph gives each value word its own, irregular, alias pair. */
	for (i = 0; i < desc->num_alias_map; i++) {
		if (desc->alias_map[i].offset != offset)
			continue;
		scratch->has_alias = true;
		scratch->set_stride = desc->alias_map[i].set - offset;
		scratch->clr_stride = desc->alias_map[i].clr - offset;
		return scratch;
	}

	/*
	 * A controller with an alias_map lists every word it knows about. An
	 * offset that is not in the map has no alias, whatever desc->alias
	 * says.
	 */
	if (desc->num_alias_map) {
		scratch->has_alias = false;
		return scratch;
	}

	return &desc->alias;
}

/*
 * Update the bits of @mask in the value word at @offset to @val.
 *
 * With aliases this is two writes that touch only the named bits and never
 * read. Without them it is a locked read-modify-write, which is the best that
 * can be done on a word shared with other subsystems.
 *
 * The reset controller in reset-ax630c.c writes reset bits in the same windows
 * and calls this directly; that is why it takes a regmap and a descriptor
 * rather than a clock.
 */
int ax630c_write_bits_regmap(struct regmap *regmap,
			     const struct ax630c_clk_desc *desc,
			     u32 offset, u32 mask, u32 val)
{
	struct ax630c_alias scratch;
	const struct ax630c_alias *alias;
	int ret;

	alias = ax630c_alias_for(desc, offset, &scratch);
	if (!alias->has_alias)
		return regmap_update_bits(regmap, offset, mask, val);

	if (mask & ~val) {
		ret = regmap_write(regmap, offset + alias->clr_stride,
				   mask & ~val);
		if (ret)
			return ret;
	}
	if (val & mask)
		return regmap_write(regmap, offset + alias->set_stride,
				    val & mask);

	return 0;
}

static int ax630c_write_bits(struct ax630c_hw *c, u32 offset, u32 mask, u32 val)
{
	return ax630c_write_bits_regmap(c->regmap, c->desc, offset, mask, val);
}

static int ax630c_read_field(struct ax630c_hw *c, u32 offset, u8 shift, u8 width,
			     u32 *out)
{
	unsigned int v;
	int ret;

	ret = regmap_read(c->regmap, offset, &v);
	if (ret)
		return ret;

	*out = (v >> shift) & (BIT(width) - 1);
	return 0;
}

/* --- gate --------------------------------------------------------------- */

/*
 * Every one of the 86 gates is active-high with no inversion: set the bit to
 * enable, clear it to disable.
 */
static int ax630c_gate_enable(struct clk_hw *hw)
{
	struct ax630c_hw *c = to_ax630c_hw(hw);

	return ax630c_write_bits(c, c->info->gate.offset,
				 BIT(c->info->gate.bit), BIT(c->info->gate.bit));
}

static void ax630c_gate_disable(struct clk_hw *hw)
{
	struct ax630c_hw *c = to_ax630c_hw(hw);

	ax630c_write_bits(c, c->info->gate.offset, BIT(c->info->gate.bit), 0);
}

static int ax630c_gate_is_enabled(struct clk_hw *hw)
{
	struct ax630c_hw *c = to_ax630c_hw(hw);
	u32 v;

	if (ax630c_read_field(c, c->info->gate.offset, c->info->gate.bit, 1, &v))
		return 0;

	return v;
}

static const struct clk_ops ax630c_gate_ops = {
	.enable = ax630c_gate_enable,
	.disable = ax630c_gate_disable,
	.is_enabled = ax630c_gate_is_enabled,
};

/* --- mux ---------------------------------------------------------------- */

static u8 ax630c_mux_get_parent(struct clk_hw *hw)
{
	struct ax630c_hw *c = to_ax630c_hw(hw);
	u32 v;

	if (ax630c_read_field(c, c->info->mux.offset, c->info->mux.shift,
			      c->info->mux.width, &v))
		return 0;

	/*
	 * Several muxes have fewer parents than their field can encode. An
	 * out-of-range value is a hardware state we cannot describe; report
	 * parent 0 rather than letting the core index past the array.
	 */
	if (v >= clk_hw_get_num_parents(hw)) {
		pr_warn_once("%s: mux field reads %u, only %u parents\n",
			     clk_hw_get_name(hw), v, clk_hw_get_num_parents(hw));
		return 0;
	}

	return v;
}

static int ax630c_mux_set_parent(struct clk_hw *hw, u8 index)
{
	struct ax630c_hw *c = to_ax630c_hw(hw);
	u32 mask = (BIT(c->info->mux.width) - 1) << c->info->mux.shift;

	return ax630c_write_bits(c, c->info->mux.offset, mask,
				 (u32)index << c->info->mux.shift);
}

static const struct clk_ops ax630c_mux_ops = {
	.get_parent = ax630c_mux_get_parent,
	.set_parent = ax630c_mux_set_parent,
	.determine_rate = clk_hw_determine_rate_no_reparent,
};

/*
 * The same mux, for the rows that opt into being re-pointed by a rate request
 * (AX630C_MUX_RC). __clk_mux_determine_rate picks the parent whose rate is
 * closest to the request without exceeding it, and the core then performs the
 * switch. The RGMII transmit clock is the case this exists for: link speed
 * changes have to move that mux, and nothing else on the SoC may.
 */
static const struct clk_ops ax630c_mux_reparent_ops = {
	.get_parent = ax630c_mux_get_parent,
	.set_parent = ax630c_mux_set_parent,
	.determine_rate = __clk_mux_determine_rate,
};

/* --- divider ------------------------------------------------------------ */

/*
 * Field encoding: 0 => /1, n >= 1 => /2n. So the reachable divisors are
 * 1, 2, 4, 6, ... 2*(2^width - 1) -- one is odd and the rest are even.
 */
static unsigned int ax630c_div_from_val(u32 val)
{
	return val ? val * 2 : 1;
}

static u32 ax630c_val_from_div(unsigned int div, u8 width)
{
	u32 max = BIT(width) - 1;

	if (div <= 1)
		return 0;

	return min_t(u32, DIV_ROUND_CLOSEST(div, 2), max);
}

static unsigned long ax630c_div_recalc_rate(struct clk_hw *hw,
					    unsigned long parent_rate)
{
	struct ax630c_hw *c = to_ax630c_hw(hw);
	u32 v;

	if (ax630c_read_field(c, c->info->div.offset, c->info->div.shift,
			      c->info->div.width, &v))
		return parent_rate;

	return DIV_ROUND_UP_ULL((u64)parent_rate, ax630c_div_from_val(v));
}

/*
 * The vendor rounds to the closest reachable divisor rather than down, so this
 * is CLK_DIVIDER_ROUND_CLOSEST behaviour over the 1, 2, 4, 6, ... table.
 *
 * The parent rate is taken as given: only eMMC and SD ever change a divider,
 * and pushing a rate request up into the shared PLL taps to serve them would
 * move every other consumer hanging off the same tap.
 */
static int ax630c_div_determine_rate(struct clk_hw *hw,
				     struct clk_rate_request *req)
{
	struct ax630c_hw *c = to_ax630c_hw(hw);
	unsigned int div;
	u32 val;

	if (!req->rate)
		req->rate = 1;

	div = DIV_ROUND_CLOSEST_ULL((u64)req->best_parent_rate, req->rate);
	val = ax630c_val_from_div(div, c->info->div.width);
	req->rate = DIV_ROUND_UP_ULL((u64)req->best_parent_rate,
				     ax630c_div_from_val(val));

	return 0;
}

static int ax630c_div_set_rate(struct clk_hw *hw, unsigned long rate,
			       unsigned long parent_rate)
{
	struct ax630c_hw *c = to_ax630c_hw(hw);
	u32 mask, val, upd;
	unsigned int div;
	int ret;

	if (!rate)
		return -EINVAL;

	div = DIV_ROUND_CLOSEST_ULL((u64)parent_rate, rate);
	val = ax630c_val_from_div(div, c->info->div.width);
	mask = (BIT(c->info->div.width) - 1) << c->info->div.shift;

	ret = ax630c_write_bits(c, c->info->div.offset, mask,
				val << c->info->div.shift);
	if (ret)
		return ret;

	/*
	 * The new divisor is latched by a pulse on the update bit, which lives
	 * in the same word as the field.
	 */
	upd = BIT(c->info->div.update_bit);
	ret = ax630c_write_bits(c, c->info->div.offset, upd, upd);
	if (ret)
		return ret;

	fsleep(AX630C_DIV_UPDATE_US);

	return ax630c_write_bits(c, c->info->div.offset, upd, 0);
}

static const struct clk_ops ax630c_div_ops = {
	.recalc_rate = ax630c_div_recalc_rate,
	.determine_rate = ax630c_div_determine_rate,
	.set_rate = ax630c_div_set_rate,
};

/* --- CPUPLL ------------------------------------------------------------- */

/*
 * Offsets from the pllc window base.
 *
 * Read-only on purpose. The bootloader leaves CPUPLL locked at 1.2 GHz, which
 * is the AX630C's top OPP, and the other four OPPs are fed from fixed PLL taps
 * through clk_cpu_sel. Modelling the PLL as a fixed, already-locked source
 * therefore makes every OPP transition a pure mux reparent and costs no
 * frequency.
 *
 * That is worth more than it sounds. Relocking this PLL means stopping it, and
 * the CPU may be running from it at the time -- there is no hardware interlock
 * and no safe-parent switch in the silicon. Anyone adding .set_rate here owes
 * the tree a reparent of clk_cpu_sel to a fixed tap (npll_800m or cpll_24m)
 * before the PLL stops and back afterwards, most naturally as a clk notifier.
 * Until then the hazard simply does not exist.
 */
#define CPUPLL_CFG1		0x0d0
#define CPUPLL_CFG1_FBK_INT	GENMASK(8, 0)
#define CPUPLL_CFG1_POST_DIV	GENMASK(24, 23)

static unsigned long ax630c_pll_recalc_rate(struct clk_hw *hw,
					    unsigned long parent_rate)
{
	struct ax630c_hw *c = to_ax630c_hw(hw);
	unsigned int cfg1, fbk_int, post_div;

	if (regmap_read(c->regmap, CPUPLL_CFG1, &cfg1))
		return 0;

	fbk_int = FIELD_GET(CPUPLL_CFG1_FBK_INT, cfg1);
	post_div = FIELD_GET(CPUPLL_CFG1_POST_DIV, cfg1);

	if (!fbk_int)
		return 0;

	/*
	 * rate = fbk_int * (ref / 2^post_div). The fractional numerator in
	 * CFG0 is deliberately ignored: the vendor never writes it back, so
	 * every rate this PLL can be in is integer-N.
	 */
	return (unsigned long)fbk_int * (parent_rate >> post_div);
}

static const struct clk_ops ax630c_pll_ops = {
	.recalc_rate = ax630c_pll_recalc_rate,
};

/* --- registration ------------------------------------------------------- */

static struct clk_hw *ax630c_register_one(struct device *dev,
					  struct ax630c_clk_data *data,
					  const struct ax630c_clk *info)
{
	struct clk_init_data init = { };
	struct ax630c_hw *c;
	int ret;

	switch (info->type) {
	case AX630C_FIXED_RATE:
		return devm_clk_hw_register_fixed_rate(dev, info->name, NULL, 0,
						       info->fixed_rate.rate);
	case AX630C_FIXED_FACTOR:
		return devm_clk_hw_register_fixed_factor(dev, info->name,
							 info->parent,
							 info->flags,
							 info->fixed_factor.mult,
							 info->fixed_factor.div);
	default:
		break;
	}

	c = devm_kzalloc(dev, sizeof(*c), GFP_KERNEL);
	if (!c)
		return ERR_PTR(-ENOMEM);

	c->regmap = data->regmap;
	c->desc = data->desc;
	c->info = info;

	init.name = info->name;
	init.flags = info->flags;

	switch (info->type) {
	case AX630C_MUX:
		init.ops = info->mux.reparent ? &ax630c_mux_reparent_ops
					     : &ax630c_mux_ops;
		init.parent_names = info->parents;
		init.num_parents = info->num_parents;
		break;
	case AX630C_DIV:
		init.ops = &ax630c_div_ops;
		break;
	case AX630C_GATE:
		init.ops = &ax630c_gate_ops;
		break;
	case AX630C_PLL:
		init.ops = &ax630c_pll_ops;
		break;
	default:
		return ERR_PTR(-EINVAL);
	}

	/*
	 * A NULL parent means the source is genuinely unknown, not that the
	 * row is incomplete: five dispc gates are fed by a D-PHY clock that no
	 * provider on this SoC registers. Give them no parent rather than a
	 * placeholder name -- CCF is happy with a parentless clock (it simply
	 * reports rate 0), which is what the device shows today anyway, and it
	 * keeps a fictional clock name out of the tree.
	 */
	if (info->type != AX630C_MUX && info->parent) {
		init.parent_names = &info->parent;
		init.num_parents = 1;
	}

	c->hw.init = &init;

	ret = devm_clk_hw_register(dev, &c->hw);
	if (ret)
		return ERR_PTR(ret);

	return &c->hw;
}

static int ax630c_clk_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	const struct ax630c_clk_desc *desc;
	struct ax630c_clk_data *data;
	unsigned int i;
	int ret;

	desc = device_get_match_data(dev);
	if (!desc)
		return -EINVAL;

	data = devm_kzalloc(dev, sizeof(*data), GFP_KERNEL);
	if (!data)
		return -ENOMEM;

	data->desc = desc;

	/*
	 * The node is a syscon: the reset controller and several peripheral
	 * drivers map the same window. Take the shared regmap rather than an
	 * ioremap of our own.
	 */
	data->regmap = syscon_node_to_regmap(dev->of_node);
	if (IS_ERR(data->regmap))
		return dev_err_probe(dev, PTR_ERR(data->regmap),
				     "no syscon regmap for the clock window\n");

	data->onecell = devm_kzalloc(dev, struct_size(data->onecell, hws,
						      desc->max_id + 1),
				     GFP_KERNEL);
	if (!data->onecell)
		return -ENOMEM;

	data->onecell->num = desc->max_id + 1;
	for (i = 0; i <= desc->max_id; i++)
		data->onecell->hws[i] = ERR_PTR(-ENOENT);

	for (i = 0; i < desc->num_clks; i++) {
		const struct ax630c_clk *info = &desc->clks[i];
		struct clk_hw *hw;

		hw = ax630c_register_one(dev, data, info);
		if (IS_ERR(hw))
			return dev_err_probe(dev, PTR_ERR(hw),
					     "failed to register %s\n",
					     info->name);

		data->onecell->hws[info->id] = hw;
	}

	ret = devm_of_clk_add_hw_provider(dev, of_clk_hw_onecell_get,
					  data->onecell);
	if (ret)
		return ret;

	/*
	 * Same node, same regmap, same lock: the reset lines of this window are
	 * bits in the words next to its clock gates, so this driver hands them
	 * out too rather than leaving a second provider to race it.
	 */
	return ax630c_reset_register(dev, data->regmap, desc);
}

static const struct of_device_id ax630c_clk_of_match[] = {
	{ .compatible = "axera,ax630c-pllc-clk",   .data = &ax630c_pllc_desc },
	{ .compatible = "axera,ax630c-cpu-clk",    .data = &ax630c_cpu_desc },
	{ .compatible = "axera,ax630c-common-clk", .data = &ax630c_common_desc },
	{ .compatible = "axera,ax630c-dispc-clk",  .data = &ax630c_dispc_desc },
	{ .compatible = "axera,ax630c-flash-clk",  .data = &ax630c_flash_desc },
	{ .compatible = "axera,ax630c-mm-clk",     .data = &ax630c_mm_desc },
	{ .compatible = "axera,ax630c-periph-clk", .data = &ax630c_periph_desc },
	{ .compatible = "axera,ax630c-vpu-clk",    .data = &ax630c_vpu_desc },
	{ }
};
MODULE_DEVICE_TABLE(of, ax630c_clk_of_match);

static struct platform_driver ax630c_clk_driver = {
	.probe = ax630c_clk_probe,
	.driver = {
		.name = "ax630c-clk",
		.of_match_table = ax630c_clk_of_match,
		.suppress_bind_attrs = true,
	},
};
builtin_platform_driver(ax630c_clk_driver);
