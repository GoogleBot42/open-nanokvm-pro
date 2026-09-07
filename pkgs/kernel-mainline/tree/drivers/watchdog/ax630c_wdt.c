// SPDX-License-Identifier: GPL-2.0
/*
 * Watchdog driver for the Axera AX630C (AX620E family).
 *
 * Written from docs/reference/mainline/wdt-model-20260906.md, a behavioural
 * specification of the block, and reconciled against read-only register
 * captures from a running board. Not derived from vendor driver code.
 *
 * This block is boot-critical on the NanoKVM-Pro for two reasons worth stating
 * up front, because they invert the usual watchdog assumptions:
 *
 *  - U-Boot ARMS IT ~30 s before `booti` and nothing else pets it. A kernel
 *    without this driver is hard-reset a minute into every boot.
 *  - The board's TF-A implements no PSCI SYSTEM_RESET, so the watchdog is also
 *    a reboot mechanism. (A syscon-reboot node handles the ordinary case at a
 *    higher notifier priority; this is the fallback behind it.)
 *
 * Despite the DesignWare-looking neighbours on this SoC the register interface
 * is NOT dw_wdt: different offsets, a magic-word kick, and a timeout register
 * linear in units of 64Ki ticks rather than a log2 index.
 */

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/mfd/syscon.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/watchdog.h>

/* --- the watchdog block itself ------------------------------------------- */

#define AX630C_WDT_EN			0x00
#define AX630C_WDT_EN_ENABLE		BIT(0)
#define AX630C_WDT_TORR			0x0c
#define AX630C_WDT_TORR_MAX		0xffffU
#define AX630C_WDT_TORR_LOAD		0x18
#define AX630C_WDT_TORR_LOAD_STROBE	BIT(0)
#define AX630C_WDT_CCVR			0x24
#define AX630C_WDT_CRR			0x30
#define AX630C_WDT_CRR_KICK		0x61696370
#define AX630C_WDT_INTR_CLR		0x3c
#define AX630C_WDT_INTR_EN		0x54

/*
 * WDT_TORR counts in units of 64Ki counter ticks, and the block interrupts on
 * the first expiry and only resets on the SECOND. One programmed stage is
 * therefore half the time to reset.
 */
#define AX630C_WDT_TICK_SHIFT		16
#define AX630C_WDT_STAGES		2

/*
 * WDT_CRR and WDT_TORR_LOAD are level-sensitive across a clock-domain
 * crossing, not write-1-to-pulse: assert, hold longer than one counter-clock
 * period, deassert. 1 us covers a 24 MHz counter with room to spare.
 */
#define AX630C_WDT_STROBE_US		1

/* --- the peripheral syscon ------------------------------------------------ */

/*
 * The block's counter clock, APB clock, two resets and its clock-source mux all
 * live in the peripheral syscon, as write-1-to-set / write-1-to-clear alias
 * pairs over the value registers. The vendor driver mapped that window a second
 * time; here it is a phandle, because the clock driver already owns it as a
 * syscon and two request_mem_region()s over one window cannot both succeed.
 *
 * TODO(#80): these five fields are exactly two clocks, two resets and an
 * assigned-clock-parent. Convert to clocks/resets phandles once the clock
 * driver registers the six WDT clock IDs -- it registers none of them today,
 * which is why this driver programs the bits itself rather than calling
 * clk_prepare_enable() and getting a silent no-op.
 */
#define AX630C_PERIPH_MUX0_SET		0xa8
#define AX630C_PERIPH_MUX0_CLR		0xac
#define AX630C_PERIPH_EB0_SET		0xb0
#define AX630C_PERIPH_EB0_CLR		0xb4
#define AX630C_PERIPH_EB3_SET		0xc8
#define AX630C_PERIPH_EB3_CLR		0xcc
#define AX630C_PERIPH_RST3_SET		0xf0
#define AX630C_PERIPH_RST3_CLR		0xf4

/*
 * Counter-clock rates, both measured on hardware 2026-09-06 by widening TORR so
 * the count could not wrap and timing WDT_CCVR over three seconds: 24.007 MHz
 * with the mux bit set, 32.79 kHz with it clear (the 32768 Hz RTC output; the
 * vendor driver's hard-coded 32000 is 2.3 % off).
 *
 * This driver always selects the fast source. That is the safe direction: if
 * the syscon write were ever to fail, computing for 24 MHz on a 32 kHz counter
 * yields timeouts 732x too LONG -- a dog that never bites -- where the converse
 * would be an immediate reboot loop with no console to explain it.
 */
#define AX630C_WDT_RATE_FAST		24000000U

struct ax630c_wdt_periph_bits {
	u32 mux_fast;		/* CLK_MUX0: 1 = 24 MHz, 0 = 32768 Hz */
	u32 counter_clk;	/* CLK_EB0 gate */
	u32 apb_clk;		/* CLK_EB3 gate */
	u32 counter_rst;	/* SW_RST3, 1 = held in reset */
	u32 apb_rst;		/* SW_RST3, 1 = held in reset */
};

/*
 * Instances 0 and 2. There is no instance 1 on this SoC; the NanoKVM-Pro
 * enables only wdt0, but the second row costs five constants.
 */
static const struct ax630c_wdt_periph_bits ax630c_wdt_periph[] = {
	[0] = { BIT(19), BIT(14), BIT(19), BIT(1), BIT(0) },
	[2] = { BIT(20), BIT(15), BIT(20), BIT(3), BIT(2) },
};

struct ax630c_wdt {
	struct watchdog_device wdd;
	void __iomem *base;
	struct regmap *periph;
	const struct ax630c_wdt_periph_bits *bits;
};

/* -------------------------------------------------------------------------- */

static void ax630c_wdt_kick(struct ax630c_wdt *wdt)
{
	writel(AX630C_WDT_CRR_KICK, wdt->base + AX630C_WDT_CRR);
	udelay(AX630C_WDT_STROBE_US);
	writel(0, wdt->base + AX630C_WDT_CRR);
}

/* Program the per-stage reload. The caller owns the timeout/2 arithmetic. */
static void ax630c_wdt_load(struct ax630c_wdt *wdt, u32 torr)
{
	writel(torr, wdt->base + AX630C_WDT_TORR);
	writel(AX630C_WDT_TORR_LOAD_STROBE, wdt->base + AX630C_WDT_TORR_LOAD);
	udelay(AX630C_WDT_STROBE_US);
	writel(0, wdt->base + AX630C_WDT_TORR_LOAD);
	ax630c_wdt_kick(wdt);
}

static u32 ax630c_wdt_torr_for(unsigned int timeout_s)
{
	u64 ticks = (u64)timeout_s * AX630C_WDT_RATE_FAST / AX630C_WDT_STAGES;

	return min_t(u64, ticks >> AX630C_WDT_TICK_SHIFT, AX630C_WDT_TORR_MAX);
}

/*
 * Select the fast counter clock. The gate is closed around the mux write
 * because a source switch on a running counter is not glitch-free; the reload
 * afterwards discards whatever partial tick that produced.
 */
static void ax630c_wdt_select_fast_clk(struct ax630c_wdt *wdt)
{
	regmap_write(wdt->periph, AX630C_PERIPH_EB0_CLR, wdt->bits->counter_clk);
	regmap_write(wdt->periph, AX630C_PERIPH_MUX0_SET, wdt->bits->mux_fast);
	regmap_write(wdt->periph, AX630C_PERIPH_EB0_SET, wdt->bits->counter_clk);
	udelay(AX630C_WDT_STROBE_US);
	ax630c_wdt_kick(wdt);
}

static int ax630c_wdt_ping(struct watchdog_device *wdd)
{
	ax630c_wdt_kick(watchdog_get_drvdata(wdd));

	return 0;
}

static int ax630c_wdt_set_timeout(struct watchdog_device *wdd,
				  unsigned int timeout)
{
	struct ax630c_wdt *wdt = watchdog_get_drvdata(wdd);

	ax630c_wdt_load(wdt, ax630c_wdt_torr_for(timeout));
	wdd->timeout = timeout;

	return 0;
}

static int ax630c_wdt_start(struct watchdog_device *wdd)
{
	struct ax630c_wdt *wdt = watchdog_get_drvdata(wdd);

	ax630c_wdt_load(wdt, ax630c_wdt_torr_for(wdd->timeout));
	writel(AX630C_WDT_EN_ENABLE, wdt->base + AX630C_WDT_EN);
	set_bit(WDOG_HW_RUNNING, &wdd->status);

	return 0;
}

static int ax630c_wdt_stop(struct watchdog_device *wdd)
{
	struct ax630c_wdt *wdt = watchdog_get_drvdata(wdd);

	writel(0, wdt->base + AX630C_WDT_EN);
	clear_bit(WDOG_HW_RUNNING, &wdd->status);

	return 0;
}

/*
 * Time to the next stage boundary, which is the interrupt, not the reset. The
 * reset is one further stage away, but the counter gives no way to tell which
 * stage is running, so the pessimistic figure is the honest one.
 */
static unsigned int ax630c_wdt_get_timeleft(struct watchdog_device *wdd)
{
	struct ax630c_wdt *wdt = watchdog_get_drvdata(wdd);

	return readl(wdt->base + AX630C_WDT_CCVR) / AX630C_WDT_RATE_FAST;
}

/*
 * Last-resort reboot. Runs from an atomic notifier with interrupts off and the
 * other CPU stopped: no sleeping, and it should not come back.
 *
 * A reload of 0 expires within a tick, so both stages elapse in microseconds.
 * The reset only reaches the SoC if COMM_ABORT_CFG bit 7 is set, which every
 * boot-chain stage does (read back as 0x2c0 on hardware). This driver does not
 * touch that register: a board where firmware left it clear cannot reboot by
 * any means the kernel has.
 */
static int ax630c_wdt_restart(struct watchdog_device *wdd,
			      unsigned long action, void *data)
{
	struct ax630c_wdt *wdt = watchdog_get_drvdata(wdd);

	ax630c_wdt_select_fast_clk(wdt);
	writel(AX630C_WDT_EN_ENABLE, wdt->base + AX630C_WDT_EN);
	ax630c_wdt_load(wdt, 0);

	mdelay(500);

	return 0;
}

static const struct watchdog_info ax630c_wdt_info = {
	.identity = "AX630C watchdog",
	.options = WDIOF_SETTIMEOUT | WDIOF_KEEPALIVEPING | WDIOF_MAGICCLOSE,
};

static const struct watchdog_ops ax630c_wdt_ops = {
	.owner = THIS_MODULE,
	.start = ax630c_wdt_start,
	.stop = ax630c_wdt_stop,
	.ping = ax630c_wdt_ping,
	.set_timeout = ax630c_wdt_set_timeout,
	.get_timeleft = ax630c_wdt_get_timeleft,
	.restart = ax630c_wdt_restart,
};

/* -------------------------------------------------------------------------- */

static unsigned int timeout;
module_param(timeout, uint, 0);
MODULE_PARM_DESC(timeout, "Watchdog timeout in seconds");

static bool nowayout = WATCHDOG_NOWAYOUT;
module_param(nowayout, bool, 0);
MODULE_PARM_DESC(nowayout, "Watchdog cannot be stopped once started");

static int ax630c_wdt_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct ax630c_wdt *wdt;
	unsigned int instance;
	int ret;

	wdt = devm_kzalloc(dev, sizeof(*wdt), GFP_KERNEL);
	if (!wdt)
		return -ENOMEM;

	wdt->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(wdt->base))
		return PTR_ERR(wdt->base);

	/*
	 * Stop the dog first. U-Boot left it armed and counting, and everything
	 * below -- a deferred syscon lookup most of all -- must not race it.
	 * Every error return past this point re-arms it, so a failed probe still
	 * leaves a board that reboots rather than one that hangs with no console
	 * to say why.
	 */
	writel(0, wdt->base + AX630C_WDT_EN);

	wdt->periph = syscon_regmap_lookup_by_phandle_args(dev->of_node,
							  "axera,periph-syscon",
							  1, &instance);
	if (IS_ERR(wdt->periph)) {
		ret = PTR_ERR(wdt->periph);
		dev_err_probe(dev, ret, "cannot reach the peripheral syscon\n");
		goto err_rearm;
	}

	if (instance >= ARRAY_SIZE(ax630c_wdt_periph) ||
	    !ax630c_wdt_periph[instance].mux_fast) {
		dev_err(dev, "no register bits known for instance %u\n",
			instance);
		ret = -EINVAL;
		goto err_rearm;
	}
	wdt->bits = &ax630c_wdt_periph[instance];

	/*
	 * Release both resets and open both gates before touching the block
	 * again. Firmware already leaves all four in this state; doing it anyway
	 * costs four alias writes and removes a dependency on which bootloader
	 * ran.
	 */
	regmap_write(wdt->periph, AX630C_PERIPH_RST3_CLR,
		     wdt->bits->counter_rst | wdt->bits->apb_rst);
	regmap_write(wdt->periph, AX630C_PERIPH_EB3_SET, wdt->bits->apb_clk);
	ax630c_wdt_select_fast_clk(wdt);

	/*
	 * No interrupt is claimed and the interrupt enable stays clear. The
	 * first expiry is a stage boundary whether or not anyone is listening,
	 * and a pretimeout that is structurally timeout/2 is not something the
	 * watchdog core can express.
	 */
	writel(0, wdt->base + AX630C_WDT_INTR_EN);
	writel(1, wdt->base + AX630C_WDT_INTR_CLR);

	wdt->wdd.info = &ax630c_wdt_info;
	wdt->wdd.ops = &ax630c_wdt_ops;
	wdt->wdd.parent = dev;
	wdt->wdd.min_timeout = 1;
	wdt->wdd.max_timeout = (u32)(((u64)AX630C_WDT_TORR_MAX <<
				      AX630C_WDT_TICK_SHIFT) * AX630C_WDT_STAGES /
				     AX630C_WDT_RATE_FAST);
	wdt->wdd.timeout = 60;

	/*
	 * Cap how long the hardware may go unpetted well below the timeout, so
	 * the core's worker pings every 5 s. The margin is deliberate: the
	 * two-stage model that puts the reset at 2x the programmed reload is
	 * inferred rather than measured, and a 5 s ping is safe even if the
	 * block turns out to reset at the first expiry instead.
	 */
	wdt->wdd.max_hw_heartbeat_ms = 10000;

	watchdog_set_drvdata(&wdt->wdd, wdt);
	watchdog_init_timeout(&wdt->wdd, timeout, dev);
	watchdog_set_nowayout(&wdt->wdd, nowayout);
	watchdog_set_restart_priority(&wdt->wdd, 128);

	/*
	 * Adopt the running dog rather than leaving a gap: program our timeout,
	 * re-enable, and let WDOG_HW_RUNNING make the core pet from kernel
	 * context until userspace opens /dev/watchdog. Deliberately NOT
	 * watchdog_stop_on_reboot() -- on this SoC that would disarm the only
	 * thing left that can reset the chip.
	 */
	ax630c_wdt_start(&wdt->wdd);

	ret = devm_watchdog_register_device(dev, &wdt->wdd);
	if (ret)
		goto err_rearm;

	dev_info(dev, "instance %u at %u Hz, timeout %us, max %us\n",
		 instance, AX630C_WDT_RATE_FAST, wdt->wdd.timeout,
		 wdt->wdd.max_timeout);

	return 0;

err_rearm:
	writel(AX630C_WDT_EN_ENABLE, wdt->base + AX630C_WDT_EN);
	return ret;
}

static const struct of_device_id ax630c_wdt_of_match[] = {
	{ .compatible = "axera,ax630c-wdt" },
	{ }
};
MODULE_DEVICE_TABLE(of, ax630c_wdt_of_match);

static struct platform_driver ax630c_wdt_driver = {
	.probe = ax630c_wdt_probe,
	.driver = {
		.name = "ax630c-wdt",
		.of_match_table = ax630c_wdt_of_match,
	},
};
module_platform_driver(ax630c_wdt_driver);

MODULE_DESCRIPTION("Axera AX630C watchdog driver");
MODULE_LICENSE("GPL");
