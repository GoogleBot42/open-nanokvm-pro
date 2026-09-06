// SPDX-License-Identifier: GPL-2.0
/*
 * Axera AX630C (AX620E family) pin controller.
 *
 * 111 pads, one 32-bit word each, holding a 3-bit function select plus the
 * pad's electrical configuration. The words live in two register windows that
 * form a single logical offset space.
 *
 * Written from docs/reference/mainline/pinctrl-model-20260906.md -- a
 * behavioural specification derived from the vendor GPL sources and checked
 * against a live device. Issue #80.
 *
 * Three things here are deliberately unlike the vendor driver:
 *
 *  - set_mux() rejects a function the pad does not implement. The vendor
 *    writes mux value 0 and returns success on a lookup miss, which silently
 *    muxes the pad to something unrelated. 337 of the 888 mux slots are
 *    unpopulated, so this is not a hypothetical.
 *
 *  - gpio_request_enable() programs the mux. This is what fixes the long-
 *    standing "ATX reset works but power does not" bug: exporting a GPIO never
 *    reprogrammed the pad, because the vendor GPIO driver stubs chip->request
 *    and so pinctrl_gpio_request() never ran. The GPIO value register would
 *    then read back the output latch and prove nothing about the ball.
 *
 *  - GPIO is not always function 6. It is function 0 on the three GPIO bank 3
 *    pads, and 14 pads have no GPIO function at all.
 *
 * Copyright (c) 2026 the open-nanokvm-pro contributors.
 */

#include <linux/bitfield.h>
#include <linux/io.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/spinlock.h>

#include <linux/pinctrl/pinconf.h>
#include <linux/pinctrl/pinconf-generic.h>
#include <linux/pinctrl/pinctrl.h>
#include <linux/pinctrl/pinmux.h>

#include "../core.h"
#include "../pinmux.h"
#include "pinctrl-ax630c.h"

/*
 * DPHY-TX pads cannot simply be muxed. Before a CDTX_* pad moves to a non-zero
 * function the D-PHY transmitter must be held in soft reset with its MIPI
 * enable cleared, both of which live outside this controller. The board points
 * at them with two syscon phandles; without them those six pads (LED sense and
 * the touch panel) are left alone rather than half-programmed.
 */
struct ax630c_dphytx {
	struct regmap *reset;
	u32 reset_reg;
	u32 reset_bit;
	struct regmap *mipien;
	u32 mipien_reg;
	bool present;
};

struct ax630c_pinctrl {
	struct device *dev;
	struct pinctrl_dev *pctl;
	void __iomem *base[2];
	struct ax630c_dphytx dphytx;
	/*
	 * The pad word is read-modify-written. Per-pad set/clear aliases very
	 * likely exist (the 0xC stride is a {VALUE, SET, CLR} slot), which
	 * would make each field write atomic and retire this lock -- but that
	 * has not been confirmed on hardware, so take the lock.
	 */
	spinlock_t lock;
	/* Function selected before a pad was taken for GPIO, to restore. */
	u8 saved_func[AX630C_NUM_PADS];
};

static void __iomem *ax630c_pad_reg(struct ax630c_pinctrl *pc, unsigned int pin)
{
	const struct ax630c_pad *pad = &ax630c_pads[pin];

	return pc->base[pad->window] + pad->offset;
}

static void ax630c_pad_update(struct ax630c_pinctrl *pc, unsigned int pin,
			      u32 mask, u32 val)
{
	void __iomem *reg = ax630c_pad_reg(pc, pin);
	unsigned long flags;
	u32 v;

	spin_lock_irqsave(&pc->lock, flags);
	v = readl(reg);
	v = (v & ~mask) | (val & mask);
	writel(v, reg);
	spin_unlock_irqrestore(&pc->lock, flags);
}

static u32 ax630c_pad_read(struct ax630c_pinctrl *pc, unsigned int pin)
{
	return readl(ax630c_pad_reg(pc, pin));
}

/* --- pinctrl ops -------------------------------------------------------- */

static const struct pinctrl_ops ax630c_pinctrl_ops = {
	.get_groups_count = pinctrl_generic_get_group_count,
	.get_group_name = pinctrl_generic_get_group_name,
	.get_group_pins = pinctrl_generic_get_group_pins,
	.dt_node_to_map = pinconf_generic_dt_node_to_map_all,
	.dt_free_map = pinconf_generic_dt_free_map,
};

/* --- pinmux ops --------------------------------------------------------- */

/* Which mux value on @pin selects function @func, or -EINVAL. */
static int ax630c_mux_value(unsigned int pin, unsigned int func)
{
	const struct ax630c_pad *pad = &ax630c_pads[pin];
	unsigned int v;

	for (v = 0; v < AX630C_MUX_VALUES; v++)
		if (pad->mux[v] != AX630C_MUX_RESERVED &&
		    pad->mux[v] == (s16)func)
			return v;

	return -EINVAL;
}

/*
 * Hold the D-PHY transmitter in reset with MIPI signalling disabled. The pad
 * write happens while it is parked like this; nothing here brings it back,
 * which matches the vendor and U-Boot sequences -- the D-PHY driver owns
 * bringing the transmitter up afterwards.
 */
static int ax630c_dphytx_park(struct ax630c_pinctrl *pc)
{
	int ret;

	if (!pc->dphytx.present) {
		dev_err(pc->dev,
			"a DPHY-TX pad needs axera,dphytx-reset and axera,dphytx-mipien\n");
		return -ENODEV;
	}

	ret = regmap_update_bits(pc->dphytx.reset, pc->dphytx.reset_reg,
				 BIT(pc->dphytx.reset_bit),
				 BIT(pc->dphytx.reset_bit));
	if (ret)
		return ret;

	return regmap_write(pc->dphytx.mipien, pc->dphytx.mipien_reg, 0);
}

static int ax630c_set_mux(struct pinctrl_dev *pctldev, unsigned int func,
			  unsigned int group)
{
	struct ax630c_pinctrl *pc = pinctrl_dev_get_drvdata(pctldev);
	const unsigned int *pins;
	unsigned int num_pins, i;
	int ret;

	ret = pinctrl_generic_get_group_pins(pctldev, group, &pins, &num_pins);
	if (ret)
		return ret;

	/*
	 * Resolve every pad before writing any of them. A group is meant to
	 * move as a unit, and a half-applied mux is harder to diagnose than a
	 * refused one.
	 */
	for (i = 0; i < num_pins; i++) {
		ret = ax630c_mux_value(pins[i], func);
		if (ret < 0) {
			dev_err(pc->dev,
				"pad %s has no function %s\n",
				ax630c_pin_descs[pins[i]].name,
				pinmux_generic_get_function_name(pctldev, func));
			return -EINVAL;
		}
	}

	for (i = 0; i < num_pins; i++) {
		unsigned int pin = pins[i];
		/* Validated in the loop above, so this cannot be negative. */
		u32 val = (u32)ax630c_mux_value(pin, func);

		if (ax630c_pads[pin].dphytx && val != 0) {
			ret = ax630c_dphytx_park(pc);
			if (ret)
				return ret;
		}

		ax630c_pad_update(pc, pin, AX630C_FUNC_MASK,
				  val << AX630C_FUNC_SHIFT);
	}

	return 0;
}

static int ax630c_gpio_request_enable(struct pinctrl_dev *pctldev,
				      struct pinctrl_gpio_range *range,
				      unsigned int pin)
{
	struct ax630c_pinctrl *pc = pinctrl_dev_get_drvdata(pctldev);
	const struct ax630c_pad *pad = &ax630c_pads[pin];
	u32 cur;

	if (pad->gpio_mux == AX630C_NO_GPIO) {
		dev_err(pc->dev, "pad %s has no GPIO function\n",
			ax630c_pin_descs[pin].name);
		return -ENOTSUPP;
	}

	cur = FIELD_GET(AX630C_FUNC_MASK, ax630c_pad_read(pc, pin));
	pc->saved_func[pin] = cur;

	ax630c_pad_update(pc, pin, AX630C_FUNC_MASK,
			  (u32)pad->gpio_mux << AX630C_FUNC_SHIFT);

	return 0;
}

static void ax630c_gpio_disable_free(struct pinctrl_dev *pctldev,
				     struct pinctrl_gpio_range *range,
				     unsigned int pin)
{
	struct ax630c_pinctrl *pc = pinctrl_dev_get_drvdata(pctldev);

	ax630c_pad_update(pc, pin, AX630C_FUNC_MASK,
			  (u32)pc->saved_func[pin] << AX630C_FUNC_SHIFT);
}

/*
 * Nothing to do: the pad word has no direction bit. Direction is a GPIO
 * controller register. Present so the core does not warn.
 */
static int ax630c_gpio_set_direction(struct pinctrl_dev *pctldev,
				     struct pinctrl_gpio_range *range,
				     unsigned int pin, bool input)
{
	return 0;
}

static const struct pinmux_ops ax630c_pinmux_ops = {
	.get_functions_count = pinmux_generic_get_function_count,
	.get_function_name = pinmux_generic_get_function_name,
	.get_function_groups = pinmux_generic_get_function_groups,
	.set_mux = ax630c_set_mux,
	.gpio_request_enable = ax630c_gpio_request_enable,
	.gpio_disable_free = ax630c_gpio_disable_free,
	.gpio_set_direction = ax630c_gpio_set_direction,
	/*
	 * A pad claimed as GPIO must not also be claimed by a peripheral
	 * state. This is what arbitrates the SW_PWR pad between the ATX GPIO
	 * and the capture pin group.
	 */
	.strict = true,
};

/* --- pinconf ops -------------------------------------------------------- */

static int ax630c_pinconf_get(struct pinctrl_dev *pctldev, unsigned int pin,
			      unsigned long *config)
{
	struct ax630c_pinctrl *pc = pinctrl_dev_get_drvdata(pctldev);
	enum pin_config_param param = pinconf_to_config_param(*config);
	const struct ax630c_pad *pad = &ax630c_pads[pin];
	u32 val = ax630c_pad_read(pc, pin);
	u32 pull = val & AX630C_PULL_MASK;
	u32 arg;

	switch (param) {
	case PIN_CONFIG_BIAS_DISABLE:
		if (pull)
			return -EINVAL;
		arg = 1;
		break;
	case PIN_CONFIG_BIAS_PULL_DOWN:
		if (pull != AX630C_PULL_DOWN)
			return -EINVAL;
		arg = 1;
		break;
	case PIN_CONFIG_BIAS_PULL_UP:
		if (pad->pull_enc == AX630C_PULL_ENSEL) {
			if (pull != AX630C_PULL_UP_ENSEL)
				return -EINVAL;
		} else if (pull != AX630C_PULL_UP_ONEHOT) {
			return -EINVAL;
		}
		arg = 1;
		break;
	case PIN_CONFIG_INPUT_SCHMITT_ENABLE:
		if (!(val & AX630C_SCHMITT_BIT))
			return -EINVAL;
		arg = 1;
		break;
	case PIN_CONFIG_DRIVE_STRENGTH:
		/* A raw 4-bit code, not milliamps. The mA mapping is unknown. */
		arg = FIELD_GET(AX630C_DRIVE_MASK, val);
		break;
	default:
		return -ENOTSUPP;
	}

	*config = pinconf_to_config_packed(param, arg);
	return 0;
}

static int ax630c_pinconf_set(struct pinctrl_dev *pctldev, unsigned int pin,
			      unsigned long *configs, unsigned int num_configs)
{
	struct ax630c_pinctrl *pc = pinctrl_dev_get_drvdata(pctldev);
	const struct ax630c_pad *pad = &ax630c_pads[pin];
	unsigned int i;

	for (i = 0; i < num_configs; i++) {
		enum pin_config_param param = pinconf_to_config_param(configs[i]);
		u32 arg = pinconf_to_config_argument(configs[i]);

		switch (param) {
		case PIN_CONFIG_BIAS_DISABLE:
			ax630c_pad_update(pc, pin, AX630C_PULL_MASK, 0);
			break;
		case PIN_CONFIG_BIAS_PULL_DOWN:
			ax630c_pad_update(pc, pin, AX630C_PULL_MASK,
					  AX630C_PULL_DOWN);
			break;
		case PIN_CONFIG_BIAS_PULL_UP:
			ax630c_pad_update(pc, pin, AX630C_PULL_MASK,
					  pad->pull_enc == AX630C_PULL_ENSEL ?
					  AX630C_PULL_UP_ENSEL :
					  AX630C_PULL_UP_ONEHOT);
			break;
		case PIN_CONFIG_INPUT_SCHMITT_ENABLE:
			ax630c_pad_update(pc, pin, AX630C_SCHMITT_BIT,
					  arg ? AX630C_SCHMITT_BIT : 0);
			break;
		case PIN_CONFIG_DRIVE_STRENGTH:
			if (arg > FIELD_MAX(AX630C_DRIVE_MASK))
				return -EINVAL;
			ax630c_pad_update(pc, pin, AX630C_DRIVE_MASK, arg);
			break;
		default:
			return -ENOTSUPP;
		}
	}

	return 0;
}

static const struct pinconf_ops ax630c_pinconf_ops = {
	.is_generic = true,
	.pin_config_get = ax630c_pinconf_get,
	.pin_config_set = ax630c_pinconf_set,
};

/* Not const: devm_pinctrl_register_and_init() takes a mutable descriptor. */
static struct pinctrl_desc ax630c_pinctrl_desc = {
	.name = "ax630c-pinctrl",
	.pins = ax630c_pin_descs,
	.npins = AX630C_NUM_PADS,
	.pctlops = &ax630c_pinctrl_ops,
	.pmxops = &ax630c_pinmux_ops,
	.confops = &ax630c_pinconf_ops,
	.owner = THIS_MODULE,
};

/* --- probe -------------------------------------------------------------- */

/*
 * axera,dphytx-reset  = <&syscon 0xB8 6>   (regmap, register, bit)
 * axera,dphytx-mipien = <&syscon 0x10C>    (regmap, register)
 *
 * Both optional: a board that never muxes a CDTX_* pad away from function 0
 * does not need them.
 */
static int ax630c_parse_dphytx(struct ax630c_pinctrl *pc)
{
	struct device_node *np = pc->dev->of_node;
	struct of_phandle_args args;
	int ret;

	ret = of_parse_phandle_with_fixed_args(np, "axera,dphytx-reset", 2, 0,
					       &args);
	if (ret)
		return 0;

	pc->dphytx.reset = syscon_node_to_regmap(args.np);
	pc->dphytx.reset_reg = args.args[0];
	pc->dphytx.reset_bit = args.args[1];
	of_node_put(args.np);
	if (IS_ERR(pc->dphytx.reset))
		return dev_err_probe(pc->dev, PTR_ERR(pc->dphytx.reset),
				     "bad axera,dphytx-reset syscon\n");

	ret = of_parse_phandle_with_fixed_args(np, "axera,dphytx-mipien", 1, 0,
					       &args);
	if (ret)
		return dev_err_probe(pc->dev, ret,
				     "axera,dphytx-reset without axera,dphytx-mipien\n");

	pc->dphytx.mipien = syscon_node_to_regmap(args.np);
	pc->dphytx.mipien_reg = args.args[0];
	of_node_put(args.np);
	if (IS_ERR(pc->dphytx.mipien))
		return dev_err_probe(pc->dev, PTR_ERR(pc->dphytx.mipien),
				     "bad axera,dphytx-mipien syscon\n");

	pc->dphytx.present = true;
	return 0;
}

static int ax630c_pinctrl_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct ax630c_pinctrl *pc;
	unsigned int i;
	int ret;

	pc = devm_kzalloc(dev, sizeof(*pc), GFP_KERNEL);
	if (!pc)
		return -ENOMEM;

	pc->dev = dev;
	spin_lock_init(&pc->lock);

	for (i = 0; i < ARRAY_SIZE(pc->base); i++) {
		pc->base[i] = devm_platform_ioremap_resource(pdev, i);
		if (IS_ERR(pc->base[i]))
			return dev_err_probe(dev, PTR_ERR(pc->base[i]),
					     "failed to map pinctrl window %u\n",
					     i);
	}

	ret = ax630c_parse_dphytx(pc);
	if (ret)
		return ret;

	/*
	 * Register the controller before adding groups and functions -- both
	 * generic helpers need a live pinctrl_dev -- then enable it.
	 */
	ret = devm_pinctrl_register_and_init(dev, &ax630c_pinctrl_desc, pc,
					     &pc->pctl);
	if (ret)
		return dev_err_probe(dev, ret, "failed to register pinctrl\n");

	for (i = 0; i < ax630c_num_groups; i++) {
		const struct ax630c_group *g = &ax630c_groups[i];

		ret = pinctrl_generic_add_group(pc->pctl, g->name, g->pins,
						g->num_pins, NULL);
		if (ret < 0)
			return dev_err_probe(dev, ret,
					     "failed to add group %s\n",
					     g->name);
	}

	for (i = 0; i < ax630c_num_functions; i++) {
		ret = pinmux_generic_add_pinfunction(pc->pctl,
						     &ax630c_functions[i],
						     NULL);
		if (ret < 0)
			return dev_err_probe(dev, ret,
					     "failed to add function %s\n",
					     ax630c_functions[i].name);
	}

	return pinctrl_enable(pc->pctl);
}

static const struct of_device_id ax630c_pinctrl_of_match[] = {
	{ .compatible = "axera,ax630c-pinctrl" },
	{ }
};
MODULE_DEVICE_TABLE(of, ax630c_pinctrl_of_match);

static struct platform_driver ax630c_pinctrl_driver = {
	.probe = ax630c_pinctrl_probe,
	.driver = {
		.name = "ax630c-pinctrl",
		.of_match_table = ax630c_pinctrl_of_match,
		.suppress_bind_attrs = true,
	},
};
builtin_platform_driver(ax630c_pinctrl_driver);
