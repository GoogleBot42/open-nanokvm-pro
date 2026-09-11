// SPDX-License-Identifier: GPL-2.0+
/*
 * FB driver for the Jadard JD9853 LCD controller.
 *
 * Ported (#84) from the GPL `fb_jd9853.c` that ships in Sipeed's AX620E SDK
 * kernel tree (Linux 4.19.125, author iawak9lkm), which is what drives the
 * NanoKVM-Pro's 172x320 mini-display on the shipped firmware. The register
 * sequences below are that driver's, unchanged and device-proven; everything
 * else was rewritten, because the parts that moved are exactly the parts that
 * were broken.
 *
 * What is deliberately NOT carried over, and why:
 *
 *  - **The tearing-effect (TE) pin, and with it the private state, the
 *    workqueue, the 5 s liveness timer and the double buffer.** The vendor
 *    driver snapshots the whole framebuffer on each deferred-io tick and
 *    blasts it from a work item triggered by the panel's TE falling edge.
 *    It is optional by the vendor's own construction -- a missing `te-gpios`
 *    is a dev_warn and the driver falls straight through to the stock fbtft
 *    writer, and the SDK's sibling fb_gc9307.c drives the same geometry with
 *    no TE at all. What it buys is tearing immunity on a status screen that
 *    redraws every two seconds. What it costs is the whole mechanism behind
 *    the trap this project has carried since 2026-08-15: unloading the
 *    vendor module hard-hangs the board.
 *
 *    That hang is now understood, and it is not the timer. The vendor's
 *    init_display() does `dev_set_drvdata(&par->spi->dev, panel)`, which
 *    overwrites the `struct fb_info *` that fbtft_register_framebuffer() put
 *    there -- so fbtft_driver_remove_spi() reads a jd9853_priv_data* as a
 *    fb_info*, `info->par` is slab garbage well past the end of that object,
 *    and fbtft_remove_common() makes an indirect call through it. (The SDK's
 *    own fb_jd9853_hkc_2_01.c is the repaired copy: it uses par->extra and
 *    orders its teardown the other way round.) This driver keeps no private
 *    state at all, so there is nothing to clobber -- but the operational rule
 *    stands regardless, because it is cheap: the module is loaded at boot and
 *    never unloaded (docs/mini-display.md).
 *
 *  - **memcpy_reverse32().** It is not a panel requirement. It cancels the
 *    32-bit endian swap the vendor's own SPI master performs in DMA
 *    (drivers/spi/spi-axera-dma.c encodes a dma_endian into slave_id), and
 *    against mainline's spi-dw-mmio it would scramble every pixel.
 *
 *  - **`rgb;`** in the device tree. fbtft only ever reads `bgr`, in both
 *    trees, so the property was decorative and par->bgr is false either way.
 *
 * Two polarity facts the port turns on, because 4.19 fbtft used the RAW gpio
 * API and mainline uses the LOGICAL one:
 *
 *  - `dc-gpios` must be GPIO_ACTIVE_HIGH here where the vendor DT says
 *    active-low. fbtft_write_reg8_bus8() calls gpiod_set_value(dc, 1) for
 *    data and 0 for command; under the vendor's gpio_set_value() the flag was
 *    ignored, so the pad saw high-for-data. Getting this wrong sends every
 *    command byte as data: a blank panel and not one error message.
 *  - `reset-gpios` STAYS active-low. fbtft_reset() asserts then deasserts
 *    logically, which with the active-low flag is the same low-then-high the
 *    vendor's raw writes produced.
 *
 * Copyright (c) 2026 the open-nanokvm-pro contributors.
 */

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <video/mipi_display.h>

#include "fbtft.h"

#define DRVNAME		"fb_jd9853"

/*
 * MADCTL bits (0x36). Named here rather than in a header because fbtft has no
 * shared set and every sibling driver spells its own out.
 */
#define MADCTL_MV	BIT(5)
#define MADCTL_MX	BIT(6)
#define MADCTL_MY	BIT(7)
#define MADCTL_BGR	BIT(3)

/*
 * The panel is a 172-column window on a 240-column controller array: columns
 * 0x22..0xCD inclusive is exactly 172, and rows 0x000..0x13F is exactly 320.
 * The vendor driver hardcodes this window and ignores set_addr_win()'s
 * arguments entirely, which is why write_vmem below must send whole frames.
 */
#define JD9853_COL_START	0x0022
#define JD9853_COL_END		0x00cd
#define JD9853_ROW_START	0x0000
#define JD9853_ROW_END		0x013f

static int set_var(struct fbtft_par *par)
{
	u8 madctl_par = 0;

	if (par->bgr)
		madctl_par |= MADCTL_BGR;

	switch (par->info->var.rotate) {
	case 0:
		break;
	case 90:
		madctl_par |= MADCTL_MV | MADCTL_MY;
		break;
	case 180:
		madctl_par |= MADCTL_MX | MADCTL_MY;
		break;
	case 270:
		madctl_par |= MADCTL_MV | MADCTL_MX;
		break;
	default:
		return -EINVAL;
	}

	write_reg(par, MIPI_DCS_SET_ADDRESS_MODE, madctl_par);
	return 0;
}

/*
 * The window is fixed, so the arguments are ignored -- see JD9853_COL_START.
 * The pair of writes after it is the vendor's: TEAR_ON (V-blank only, which
 * makes the panel drive its TE pad whether or not anything listens) and then
 * RAMWR, which arms the controller for the pixel stream write_vmem sends.
 */
static void set_addr_win(struct fbtft_par *par, int xs, int ys, int xe, int ye)
{
	u8 col_cmd = MIPI_DCS_SET_COLUMN_ADDRESS;
	u8 row_cmd = MIPI_DCS_SET_PAGE_ADDRESS;

	switch (par->info->var.rotate) {
	case 0:
	case 180:
		break;
	case 90:
	case 270:
		swap(col_cmd, row_cmd);
		break;
	default:
		return;
	}

	write_reg(par, col_cmd,
		  JD9853_COL_START >> 8, JD9853_COL_START & 0xff,
		  JD9853_COL_END >> 8, JD9853_COL_END & 0xff);
	write_reg(par, row_cmd,
		  JD9853_ROW_START >> 8, JD9853_ROW_START & 0xff,
		  JD9853_ROW_END >> 8, JD9853_ROW_END & 0xff);

	write_reg(par, MIPI_DCS_SET_TEAR_ON, 0x00);
	write_reg(par, MIPI_DCS_WRITE_MEMORY_START);
}

/*
 * WHOLE FRAMES, ALWAYS. fbtft's deferred io calls set_addr_win() with the
 * dirty line range and then write_vmem() with the matching byte range -- but
 * set_addr_win() above cannot express a range, so a partial update would land
 * the dirty rows at the top of the panel. The vendor driver has the same
 * constraint and resolves it the same way: its write_vmem ignores offset and
 * len and pushes the entire 110 080-byte framebuffer.
 *
 * That is ~17 ms of SPI at the 52 MHz this bus actually runs (208 MHz SSI
 * clock, /4), and the two consumers -- the status daemon at 0.5 Hz and the
 * live HDMI preview at ~10 Hz -- both write whole frames anyway.
 */
static int write_vmem_full(struct fbtft_par *par, size_t offset, size_t len)
{
	return fbtft_write_vmem16_bus8(par, 0, par->info->fix.smem_len);
}

/*
 * Fixed relative to the vendor driver, which issues SET_DISPLAY_ON for both
 * values of `on` and so cannot blank at all.
 */
static int blank(struct fbtft_par *par, bool on)
{
	write_reg(par, on ? MIPI_DCS_SET_DISPLAY_OFF : MIPI_DCS_SET_DISPLAY_ON);
	return 0;
}

/*
 * The vendor's power-on sequence, verbatim -- including the fact that it runs
 * TWICE. Do not "clean that up": it is what has been bringing this panel up on
 * shipped hardware, the controller is a vendor-programmed part with no public
 * datasheet, and the second pass costs 560 ms once at boot.
 *
 * 0xDF 98 53 is the vendor command unlock; 0xC8 is the 32-entry gamma table
 * (which is why set_gamma is absent and display.gamma_num is 0); 0xDE selects
 * the register page; 0x3A 0x55 is 16-bit RGB565.
 */
static int init_display(struct fbtft_par *par)
{
	int i;

	for (i = 0; i < 2; i++) {
		mdelay(100);
		par->fbtftops.reset(par);
		mdelay(50);

		write_reg(par, 0xDF, 0x98, 0x53);
		write_reg(par, 0xB2, 0x23);
		write_reg(par, 0xB7, 0x00, 0x47, 0x00, 0x6F);
		write_reg(par, 0xBB, 0x1C, 0x1A, 0x55, 0x73, 0x63, 0xF0);
		write_reg(par, 0xC0, 0x44, 0xA4);

		write_reg(par, 0xC1, 0x12);
		write_reg(par, 0xC3, 0x7D, 0x07, 0x14, 0x06, 0xCF, 0x71, 0x72,
			  0x77);
		write_reg(par, 0xC4, 0x00, 0x00, 0xA0, 0x79, 0x0B, 0x0A, 0x16,
			  0x79, 0x0B, 0x0A, 0x16, 0x82);
		write_reg(par, 0xC8, 0x3F, 0x32, 0x29, 0x29, 0x27, 0x2B, 0x27,
			  0x28, 0x28, 0x26, 0x25, 0x17, 0x12, 0x0D, 0x04, 0x00,
			  0x3F, 0x32, 0x29, 0x29, 0x27, 0x2B, 0x27, 0x28, 0x28,
			  0x26, 0x25, 0x17, 0x12, 0x0D, 0x04, 0x00);
		write_reg(par, 0xD0, 0x04, 0x06, 0x6B, 0x0F, 0x00);

		write_reg(par, 0xD7, 0x00, 0x30);
		write_reg(par, 0xE6, 0x14);
		write_reg(par, 0xDE, 0x01);
		write_reg(par, 0xB7, 0x03, 0x13, 0xEF, 0x35, 0x35);
		write_reg(par, 0xC1, 0x14, 0x15, 0xC0);

		write_reg(par, 0xC2, 0x06, 0x3A);
		write_reg(par, 0xC4, 0x72, 0x12);
		write_reg(par, 0xBE, 0x00);
		write_reg(par, 0xDE, 0x02);
		write_reg(par, 0xE5, 0x00, 0x02, 0x00);

		write_reg(par, 0xE5, 0x01, 0x02, 0x00);
		write_reg(par, 0xDE, 0x00);
		write_reg(par, MIPI_DCS_SET_TEAR_OFF);
		write_reg(par, 0x44, 0x00, 0x00);
		write_reg(par, MIPI_DCS_SET_TEAR_ON, 0x00);

		write_reg(par, 0x44, 0x00, 0x00);

		write_reg(par, MIPI_DCS_SET_PIXEL_FORMAT, 0x55);	/* RGB565 */

		set_var(par);
		set_addr_win(par, 0, 0, 0, 0);

		write_reg(par, MIPI_DCS_EXIT_SLEEP_MODE);
		mdelay(120);

		write_reg(par, 0xDE, 0x02);
		write_reg(par, 0xE5, 0x00, 0x02, 0x00);
		write_reg(par, 0xDE, 0x00);
		write_reg(par, MIPI_DCS_SET_DISPLAY_ON);

		mdelay(10);
	}

	return 0;
}

static struct fbtft_display display = {
	.regwidth = 8,
	.width = 172,
	.height = 320,
	.gamma_num = 0,
	.gamma_len = 0,
	.gamma = "",
	.fbtftops = {
		.init_display = init_display,
		.set_var = set_var,
		.set_addr_win = set_addr_win,
		.write_vmem = write_vmem_full,
		.blank = blank,
	},
};

FBTFT_REGISTER_SPI_DRIVER(DRVNAME, "jadard", "jd9853", &display);

MODULE_ALIAS("spi:" DRVNAME);
MODULE_ALIAS("spi:jd9853");

MODULE_DESCRIPTION("FB driver for the Jadard JD9853 LCD Controller");
MODULE_AUTHOR("iawak9lkm");
MODULE_LICENSE("GPL");
