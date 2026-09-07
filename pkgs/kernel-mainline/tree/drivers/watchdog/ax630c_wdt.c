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
#include <linux/clk.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/platform_device.h>
#include <linux/reset.h>
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

/* --- the counter clock ---------------------------------------------------- */

/*
 * The block's two clocks, its two resets and its clock-source mux all live in
 * the peripheral clock controller, which provides them as ordinary clocks and
 * resets. The DT selects the counter's source with assigned-clock-parents and
 * this driver simply asks what rate it got.
 *
 * Both source rates were measured on hardware 2026-09-06, by widening TORR so
 * the count could not wrap and timing WDT_CCVR over three seconds: 24.007 MHz
 * with the mux bit set and 32.79 kHz with it clear -- the 32768 Hz RTC output,
 * so the vendor driver's hard-coded 32000 is 2.3 % off. Reading the rate from
 * CCF rather than assuming one means the timeout is right whichever source the
 * DT picks, and a board that omits assigned-clock-parents still gets correct
 * arithmetic for whatever firmware left selected.
 *
 * A reparent is not glitch-free, and the core performs it before probe, while
 * U-Boot's dog is still armed. That is safe here and stays safe as long as the
 * DT does not select a source FASTER than firmware's: U-Boot leaves the 24 MHz
 * source selected and clk_set_parent() is a no-op when the parent already
 * matches, so nothing is written at all on this board. Selecting a slower
 * source would only stretch the remaining count.
 */
#define AX630C_WDT_RATE_FALLBACK	24000000U

struct ax630c_wdt {
	struct watchdog_device wdd;
	void __iomem *base;
	unsigned long rate;
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

static u32 ax630c_wdt_torr_for(struct ax630c_wdt *wdt, unsigned int timeout_s)
{
	u64 ticks = (u64)timeout_s * wdt->rate / AX630C_WDT_STAGES;

	return min_t(u64, ticks >> AX630C_WDT_TICK_SHIFT, AX630C_WDT_TORR_MAX);
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

	ax630c_wdt_load(wdt, ax630c_wdt_torr_for(wdt, timeout));
	wdd->timeout = timeout;

	return 0;
}

static int ax630c_wdt_start(struct watchdog_device *wdd)
{
	struct ax630c_wdt *wdt = watchdog_get_drvdata(wdd);

	ax630c_wdt_load(wdt, ax630c_wdt_torr_for(wdt, wdd->timeout));
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

	return readl(wdt->base + AX630C_WDT_CCVR) / wdt->rate;
}

/*
 * Last-resort reboot. Runs from an atomic notifier with interrupts off and the
 * other CPU stopped: no sleeping, and it should not come back.
 *
 * A reload of 0 expires within a tick, so both stages elapse in microseconds
 * (30 us even on the slow source). No clock work is done here: touching CCF
 * from an atomic notifier could sleep, and probe already left the counter
 * clocked and its source selected.
 *
 * The reset only reaches the SoC if COMM_ABORT_CFG bit 7 is set, which every
 * boot-chain stage does (read back as 0x2c0 on hardware). This driver does not
 * touch that register: a board where firmware left it clear cannot reboot by
 * any means the kernel has.
 */
static int ax630c_wdt_restart(struct watchdog_device *wdd,
			      unsigned long action, void *data)
{
	struct ax630c_wdt *wdt = watchdog_get_drvdata(wdd);

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
	struct reset_control *rst;
	struct ax630c_wdt *wdt;
	struct clk *counter;
	struct clk *apb;
	int ret;

	wdt = devm_kzalloc(dev, sizeof(*wdt), GFP_KERNEL);
	if (!wdt)
		return -ENOMEM;

	wdt->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(wdt->base))
		return PTR_ERR(wdt->base);

	/*
	 * Stop the dog first. U-Boot left it armed and counting, and everything
	 * below -- a deferred clock or reset lookup most of all -- must not race
	 * it. Every error return past this point re-arms it, so a failed probe
	 * still leaves a board that reboots rather than one that hangs with no
	 * console to say why.
	 */
	writel(0, wdt->base + AX630C_WDT_EN);

	/*
	 * Release both resets before the clocks. Firmware already leaves them
	 * released -- U-Boot could not have programmed the block otherwise --
	 * so this is two alias writes that remove a dependency on which
	 * bootloader ran. Optional, because a DT that omits them describes a
	 * board where firmware owns the lines, and the calls then no-op.
	 */
	rst = devm_reset_control_get_optional_exclusive(dev, "wdt");
	if (IS_ERR(rst)) {
		ret = dev_err_probe(dev, PTR_ERR(rst), "no counter reset\n");
		goto err_rearm;
	}
	ret = reset_control_deassert(rst);
	if (ret)
		goto err_rearm;

	rst = devm_reset_control_get_optional_exclusive(dev, "apb");
	if (IS_ERR(rst)) {
		ret = dev_err_probe(dev, PTR_ERR(rst), "no APB reset\n");
		goto err_rearm;
	}
	ret = reset_control_deassert(rst);
	if (ret)
		goto err_rearm;

	apb = devm_clk_get_enabled(dev, "apb");
	if (IS_ERR(apb)) {
		ret = dev_err_probe(dev, PTR_ERR(apb), "no APB clock\n");
		goto err_rearm;
	}

	counter = devm_clk_get_enabled(dev, "wdt");
	if (IS_ERR(counter)) {
		ret = dev_err_probe(dev, PTR_ERR(counter), "no counter clock\n");
		goto err_rearm;
	}

	/*
	 * Everything below divides by this. A provider that cannot state a rate
	 * would otherwise divide by zero in get_timeleft; fall back to the
	 * measured fast rate and say so, because a watchdog with a wrong period
	 * is still better than no watchdog on a board whose only other reboot
	 * path is this same block.
	 */
	wdt->rate = clk_get_rate(counter);
	if (!wdt->rate) {
		wdt->rate = AX630C_WDT_RATE_FALLBACK;
		dev_warn(dev, "counter clock reports no rate, assuming %lu Hz\n",
			 wdt->rate);
	}

	ax630c_wdt_kick(wdt);

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
				     wdt->rate);
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

	dev_info(dev, "counter at %lu Hz, timeout %us, max %us\n",
		 wdt->rate, wdt->wdd.timeout, wdt->wdd.max_timeout);

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
