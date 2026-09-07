// SPDX-License-Identifier: GPL-2.0
/*
 * Axera AX630C (AX620E family) APB GPIO controller.
 *
 * DesignWare in its register *names* only. Where a dw-apb-gpio has one
 * SWPORTA_DR word carrying 32 line bits, this block has one 32-bit word per
 * line at base + (n + 1) * 4, with direction, output data, interrupt setup and
 * debounce as bit fields inside that line's own word. The port-level registers
 * that dw-apb-gpio puts at low offsets are relocated above the 32 line words.
 * So gpio-dwapb cannot bind, and this driver exists.
 *
 * Written from docs/reference/mainline/gpio-devmem-20260906.md, a behavioural
 * specification derived from the vendor GPL sources (drivers/gpio/gpio-axera.c
 * and the SDK's U-Boot drivers/gpio/axera_gpio.c, which define the same field
 * set independently) and checked against a live device. Issue #81.
 *
 * The structural safety property, worth stating because everything else
 * follows from it: one line is one word, and that word carries no other line's
 * state. A correct-address write can only ever affect the line it names.
 *
 * Two things here are deliberately unlike the vendor driver:
 *
 *  - chip.request goes through pinctrl. The vendor stubs it, which is why
 *    exporting a GPIO never reprogrammed the pad and the "ATX reset works but
 *    power does not" bug survived for the life of the product: capture init
 *    re-muxed VI_D7 away from GPIO0_A7 and nothing put it back, while the
 *    GPIO value register happily echoed the output latch. With gpio-ranges in
 *    DT, gpiochip_generic_request() reaches the pin controller's
 *    gpio_request_enable(), which programs the mux, and .strict = true there
 *    means a peripheral state can no longer steal the pad afterwards.
 *
 *  - Clocks and resets come from DT rather than from a private ioremap of the
 *    peripheral syscon. The vendor driver pokes 0x4870000 by hand from the
 *    first controller to probe.
 *
 * Copyright (c) 2026 the open-nanokvm-pro contributors.
 */

#include <linux/bitops.h>
#include <linux/clk.h>
#include <linux/gpio/driver.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/pinctrl/pinconf-generic.h>
#include <linux/platform_device.h>
#include <linux/reset.h>
#include <linux/spinlock.h>

#define AX630C_GPIO_LINES		32

/* Per-line control word. Spec section 3.1. */
#define AX630C_GPIO_LINE(n)		(((n) + 1) * 4)

/*
 * Per-line bit fields. Spec section 3.2; every one of them is cited from both
 * vendor drivers. Bit 2 (SOFT_HAR_MODE, a software/hardware output source
 * select) is declared by both and written by neither, so it is not named here:
 * this driver preserves it like every other bit it does not own.
 */
#define AX630C_GPIO_DR			BIT(0)	/* output data */
#define AX630C_GPIO_DDR			BIT(1)	/* 1 = output driver enabled */
#define AX630C_GPIO_INTEN		BIT(3)
#define AX630C_GPIO_INTMASK		BIT(4)	/* 1 = masked */
#define AX630C_GPIO_INTTYPE_EDGE	BIT(5)	/* 1 = edge, 0 = level */
#define AX630C_GPIO_INT_POLARITY	BIT(6)	/* 1 = high/rising */
#define AX630C_GPIO_DEBOUNCE		BIT(7)
#define AX630C_GPIO_EOI			BIT(8)	/* a manual pulse, not W1C */
#define AX630C_GPIO_INT_BOTHEDGE	BIT(9)

/* Port-level registers, relocated above the line words. Spec section 3.3. */
#define AX630C_GPIO_NSECURE_MODE	0x00
#define AX630C_GPIO_INTSTATUS_S		0x84
#define AX630C_GPIO_RAW_INTSTATUS_S	0x88
#define AX630C_GPIO_EXT_PORT		0x8c
#define AX630C_GPIO_ID_CODE		0x90
#define AX630C_GPIO_VER_ID_CODE		0x98
#define AX630C_GPIO_INTSTATUS		0xa4	/* non-secure view */
#define AX630C_GPIO_RAW_INTSTATUS	0xa8

struct ax630c_gpio {
	struct gpio_chip gc;
	void __iomem *base;
	/*
	 * Every write to a line word is a read-modify-write -- this block,
	 * unlike the pad-mux block, has no set/clear aliases (spec 3.2). Two
	 * paths can touch one word: gpiod_set_value() and the irq_chip. So one
	 * lock, and it is raw because irq_ack() runs in hardirq context.
	 */
	raw_spinlock_t lock;
};

static void ax630c_gpio_update(struct ax630c_gpio *gpio, unsigned int offset,
			       u32 mask, u32 val)
{
	void __iomem *reg = gpio->base + AX630C_GPIO_LINE(offset);
	unsigned long flags;
	u32 cur;

	raw_spin_lock_irqsave(&gpio->lock, flags);
	cur = readl(reg);
	writel((cur & ~mask) | (val & mask), reg);
	raw_spin_unlock_irqrestore(&gpio->lock, flags);
}

static u32 ax630c_gpio_line_read(struct ax630c_gpio *gpio, unsigned int offset)
{
	return readl(gpio->base + AX630C_GPIO_LINE(offset));
}

/* --- gpio_chip ops ------------------------------------------------------ */

static int ax630c_gpio_get_direction(struct gpio_chip *gc, unsigned int offset)
{
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);

	return (ax630c_gpio_line_read(gpio, offset) & AX630C_GPIO_DDR) ?
		GPIO_LINE_DIRECTION_OUT : GPIO_LINE_DIRECTION_IN;
}

static int ax630c_gpio_direction_input(struct gpio_chip *gc,
				       unsigned int offset)
{
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);

	ax630c_gpio_update(gpio, offset, AX630C_GPIO_DDR, 0);

	return 0;
}

static int ax630c_gpio_direction_output(struct gpio_chip *gc,
					unsigned int offset, int value)
{
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);

	/*
	 * Data and direction in one store, so the pad never drives the old
	 * latch value for a window before taking the new one. The vendor's
	 * set() does the same thing for the same reason.
	 */
	ax630c_gpio_update(gpio, offset, AX630C_GPIO_DR | AX630C_GPIO_DDR,
			   (value ? AX630C_GPIO_DR : 0) | AX630C_GPIO_DDR);

	return 0;
}

/*
 * An input reads the pad through EXT_PORT; an output reads back its own latch.
 *
 * Reading EXT_PORT for an output would be the more truthful answer if this
 * silicon loops a driven output back into it -- and whether it does is an open
 * question in the spec (section 3.3, GAP 3), not something to guess at in a
 * driver. Both vendor implementations answer from the latch, so this is also
 * what every consumer of this hardware has ever seen. A latch read proves
 * nothing about the ball; see the SW_PWR trap in docs/mini-display.md.
 */
static int ax630c_gpio_get(struct gpio_chip *gc, unsigned int offset)
{
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);
	u32 line = ax630c_gpio_line_read(gpio, offset);

	if (line & AX630C_GPIO_DDR)
		return !!(line & AX630C_GPIO_DR);

	return !!(readl(gpio->base + AX630C_GPIO_EXT_PORT) & BIT(offset));
}

static int ax630c_gpio_set(struct gpio_chip *gc, unsigned int offset, int value)
{
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);

	ax630c_gpio_update(gpio, offset, AX630C_GPIO_DR,
			   value ? AX630C_GPIO_DR : 0);

	return 0;
}

/*
 * The debounce filter is one bit per line and its period is not programmable
 * from here: the filter clock is the block's functional clock, whose source is
 * a single chip-wide mux between the 32 kHz RTC output and 24 MHz. So any
 * non-zero period request enables the filter and the caller gets the period
 * the board is wired for, which is the honest answer -- refusing outright
 * would deny a debounce that does exist.
 */
static int ax630c_gpio_set_config(struct gpio_chip *gc, unsigned int offset,
				  unsigned long config)
{
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);

	if (pinconf_to_config_param(config) != PIN_CONFIG_INPUT_DEBOUNCE)
		return -ENOTSUPP;

	ax630c_gpio_update(gpio, offset, AX630C_GPIO_DEBOUNCE,
			   pinconf_to_config_argument(config) ?
			   AX630C_GPIO_DEBOUNCE : 0);

	return 0;
}

/* --- irq_chip ----------------------------------------------------------- */

static void ax630c_gpio_irq_ack(struct irq_data *d)
{
	struct gpio_chip *gc = irq_data_get_irq_chip_data(d);
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);
	irq_hw_number_t hwirq = irqd_to_hwirq(d);

	/*
	 * EOI is a manual pulse rather than write-1-to-clear: the vendor sets
	 * it and then clears it again. Leaving it set would hold the
	 * acknowledge asserted and swallow the next interrupt.
	 */
	ax630c_gpio_update(gpio, hwirq, AX630C_GPIO_EOI, AX630C_GPIO_EOI);
	ax630c_gpio_update(gpio, hwirq, AX630C_GPIO_EOI, 0);
}

static void ax630c_gpio_irq_mask(struct irq_data *d)
{
	struct gpio_chip *gc = irq_data_get_irq_chip_data(d);
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);

	ax630c_gpio_update(gpio, irqd_to_hwirq(d), AX630C_GPIO_INTMASK,
			   AX630C_GPIO_INTMASK);
	gpiochip_disable_irq(gc, irqd_to_hwirq(d));
}

static void ax630c_gpio_irq_unmask(struct irq_data *d)
{
	struct gpio_chip *gc = irq_data_get_irq_chip_data(d);
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);

	gpiochip_enable_irq(gc, irqd_to_hwirq(d));
	ax630c_gpio_update(gpio, irqd_to_hwirq(d), AX630C_GPIO_INTMASK, 0);
}

static void ax630c_gpio_irq_enable(struct irq_data *d)
{
	struct gpio_chip *gc = irq_data_get_irq_chip_data(d);
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);

	ax630c_gpio_update(gpio, irqd_to_hwirq(d),
			   AX630C_GPIO_INTEN | AX630C_GPIO_INTMASK,
			   AX630C_GPIO_INTEN);
}

static void ax630c_gpio_irq_disable(struct irq_data *d)
{
	struct gpio_chip *gc = irq_data_get_irq_chip_data(d);
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);

	ax630c_gpio_update(gpio, irqd_to_hwirq(d), AX630C_GPIO_INTEN, 0);
}

static int ax630c_gpio_irq_set_type(struct irq_data *d, unsigned int type)
{
	struct gpio_chip *gc = irq_data_get_irq_chip_data(d);
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);
	u32 mask = AX630C_GPIO_INTTYPE_EDGE | AX630C_GPIO_INT_POLARITY |
		   AX630C_GPIO_INT_BOTHEDGE;
	u32 val;

	/*
	 * Unlike a plain DesignWare block, this one has a both-edge bit, so
	 * there is no polarity-flipping trick to maintain and no window in
	 * which an edge can be lost between the two.
	 */
	switch (type) {
	case IRQ_TYPE_EDGE_BOTH:
		val = AX630C_GPIO_INTTYPE_EDGE | AX630C_GPIO_INT_BOTHEDGE;
		break;
	case IRQ_TYPE_EDGE_RISING:
		val = AX630C_GPIO_INTTYPE_EDGE | AX630C_GPIO_INT_POLARITY;
		break;
	case IRQ_TYPE_EDGE_FALLING:
		val = AX630C_GPIO_INTTYPE_EDGE;
		break;
	case IRQ_TYPE_LEVEL_HIGH:
		val = AX630C_GPIO_INT_POLARITY;
		break;
	case IRQ_TYPE_LEVEL_LOW:
		val = 0;
		break;
	default:
		return -EINVAL;
	}

	ax630c_gpio_update(gpio, irqd_to_hwirq(d), mask, val);

	if (type & IRQ_TYPE_LEVEL_MASK)
		irq_set_handler_locked(d, handle_level_irq);
	else
		irq_set_handler_locked(d, handle_edge_irq);

	return 0;
}

static const struct irq_chip ax630c_gpio_irq_chip = {
	.name = "ax630c-gpio",
	.irq_ack = ax630c_gpio_irq_ack,
	.irq_mask = ax630c_gpio_irq_mask,
	.irq_unmask = ax630c_gpio_irq_unmask,
	.irq_enable = ax630c_gpio_irq_enable,
	.irq_disable = ax630c_gpio_irq_disable,
	.irq_set_type = ax630c_gpio_irq_set_type,
	.flags = IRQCHIP_IMMUTABLE,
	GPIOCHIP_IRQ_RESOURCE_HELPERS,
};

static void ax630c_gpio_irq_handler(struct irq_desc *desc)
{
	struct gpio_chip *gc = irq_desc_get_handler_data(desc);
	struct ax630c_gpio *gpio = gpiochip_get_data(gc);
	struct irq_chip *chip = irq_desc_get_chip(desc);
	unsigned long status;
	unsigned int hwirq;

	chained_irq_enter(chip, desc);

	/*
	 * The non-secure masked-status view, which is the one the block
	 * presents once its mode word selects non-secure (see probe).
	 */
	status = readl(gpio->base + AX630C_GPIO_INTSTATUS);
	for_each_set_bit(hwirq, &status, AX630C_GPIO_LINES)
		generic_handle_domain_irq(gc->irq.domain, hwirq);

	chained_irq_exit(chip, desc);
}

/* --- probe -------------------------------------------------------------- */

static int ax630c_gpio_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct gpio_irq_chip *girq;
	struct ax630c_gpio *gpio;
	struct reset_control *rst;
	struct clk *clk;
	u32 mode;
	int irq;
	int ret;

	gpio = devm_kzalloc(dev, sizeof(*gpio), GFP_KERNEL);
	if (!gpio)
		return -ENOMEM;

	raw_spin_lock_init(&gpio->lock);

	gpio->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(gpio->base))
		return dev_err_probe(dev, PTR_ERR(gpio->base),
				     "failed to map registers\n");

	/*
	 * The APB clock is the register interface and the functional clock
	 * drives the debounce filter and the interrupt synchroniser. Both are
	 * already on -- the boot chain drives a GPIO0 line itself, from a
	 * U-Boot driver that programs no clock at all -- so these calls
	 * mostly claim what is running, which is exactly what keeps
	 * clk_disable_unused() from turning it off later.
	 */
	clk = devm_clk_get_enabled(dev, "apb");
	if (IS_ERR(clk))
		return dev_err_probe(dev, PTR_ERR(clk),
				     "failed to enable the APB clock\n");

	clk = devm_clk_get_enabled(dev, "gpio");
	if (IS_ERR(clk))
		return dev_err_probe(dev, PTR_ERR(clk),
				     "failed to enable the GPIO clock\n");

	/*
	 * Two reset lines per controller, both left deasserted by firmware.
	 * Deassert is the only operation that is safe to perform here: by the
	 * time Linux runs, lines on this block are already driving things
	 * that must not glitch -- the host's ATX power button among them --
	 * so a reset pulse at probe would be a keystroke nobody pressed.
	 *
	 * The status read is not decoration. It is the cheapest possible
	 * check that the reset provider addresses the bits it claims, and the
	 * value is logged so a boot log is enough to tell "firmware left this
	 * released" from "we released it".
	 */
	rst = devm_reset_control_get_exclusive(dev, "apb");
	if (IS_ERR(rst))
		return dev_err_probe(dev, PTR_ERR(rst),
				     "failed to get the APB reset\n");

	ret = reset_control_status(rst);
	if (ret < 0)
		return dev_err_probe(dev, ret, "failed to read the APB reset\n");
	dev_dbg(dev, "APB reset was %s at probe\n",
		ret ? "ASSERTED" : "deasserted");

	ret = reset_control_deassert(rst);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to deassert the APB reset\n");

	rst = devm_reset_control_get_exclusive(dev, "gpio");
	if (IS_ERR(rst))
		return dev_err_probe(dev, PTR_ERR(rst),
				     "failed to get the GPIO reset\n");

	ret = reset_control_status(rst);
	if (ret < 0)
		return dev_err_probe(dev, ret, "failed to read the GPIO reset\n");
	dev_dbg(dev, "GPIO reset was %s at probe\n",
		ret ? "ASSERTED" : "deasserted");

	ret = reset_control_deassert(rst);
	if (ret)
		return dev_err_probe(dev, ret,
				     "failed to deassert the GPIO reset\n");

	/*
	 * Select the non-secure interrupt view, which is the one the handler
	 * above reads. The vendor driver writes this word unconditionally at
	 * probe; the SDK's U-Boot driver never writes it and still drives
	 * lines, so the block is usable in whatever mode the boot chain
	 * leaves and this is about the interrupt status pair, not access.
	 * A firmware that left it non-zero would be a surprise, so say so.
	 */
	mode = readl(gpio->base + AX630C_GPIO_NSECURE_MODE);
	if (mode)
		dev_info(dev, "secure-mode word was 0x%08x, selecting non-secure\n",
			 mode);
	writel(0, gpio->base + AX630C_GPIO_NSECURE_MODE);

	gpio->gc.label = dev_name(dev);
	gpio->gc.parent = dev;
	gpio->gc.owner = THIS_MODULE;
	gpio->gc.base = -1;
	gpio->gc.ngpio = AX630C_GPIO_LINES;
	gpio->gc.can_sleep = false;
	gpio->gc.get_direction = ax630c_gpio_get_direction;
	gpio->gc.direction_input = ax630c_gpio_direction_input;
	gpio->gc.direction_output = ax630c_gpio_direction_output;
	gpio->gc.get = ax630c_gpio_get;
	gpio->gc.set = ax630c_gpio_set;
	gpio->gc.set_config = ax630c_gpio_set_config;
	/*
	 * The whole point of the exercise: a GPIO request reaches the pin
	 * controller, which programs the pad's mux and then refuses to let a
	 * peripheral state take it back.
	 */
	gpio->gc.request = gpiochip_generic_request;
	gpio->gc.free = gpiochip_generic_free;

	irq = platform_get_irq_optional(pdev, 0);
	if (irq > 0) {
		girq = &gpio->gc.irq;
		gpio_irq_chip_set_chip(girq, &ax630c_gpio_irq_chip);
		girq->parent_handler = ax630c_gpio_irq_handler;
		girq->num_parents = 1;
		girq->parents = devm_kcalloc(dev, 1, sizeof(*girq->parents),
					     GFP_KERNEL);
		if (!girq->parents)
			return -ENOMEM;
		girq->parents[0] = irq;
		girq->default_type = IRQ_TYPE_NONE;
		girq->handler = handle_bad_irq;
	} else if (irq != -ENXIO) {
		return dev_err_probe(dev, irq, "failed to get the interrupt\n");
	}

	ret = devm_gpiochip_add_data(dev, &gpio->gc, gpio);
	if (ret)
		return dev_err_probe(dev, ret, "failed to add the gpiochip\n");

	/*
	 * Read-only identity words. Non-zero and stable is the cheapest proof
	 * that the block is clocked and out of reset, which is worth one line
	 * of a boot log on a board with no console.
	 */
	dev_dbg(dev, "%u lines, id 0x%08x version 0x%08x\n",
		gpio->gc.ngpio, readl(gpio->base + AX630C_GPIO_ID_CODE),
		readl(gpio->base + AX630C_GPIO_VER_ID_CODE));

	return 0;
}

static const struct of_device_id ax630c_gpio_of_match[] = {
	{ .compatible = "axera,ax630c-gpio" },
	{ }
};
MODULE_DEVICE_TABLE(of, ax630c_gpio_of_match);

static struct platform_driver ax630c_gpio_driver = {
	.probe = ax630c_gpio_probe,
	.driver = {
		.name = "ax630c-gpio",
		.of_match_table = ax630c_gpio_of_match,
		.suppress_bind_attrs = true,
	},
};
builtin_platform_driver(ax630c_gpio_driver);
