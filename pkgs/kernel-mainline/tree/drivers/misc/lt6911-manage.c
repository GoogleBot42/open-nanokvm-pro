// SPDX-License-Identifier: GPL-2.0
/*
 * Lontium LT6911UXC HDMI-to-CSI-2 bridge management, Sipeed NanoKVM-Pro.
 *
 * This is deliberately not a media driver. The bridge's CSI-2 output is
 * consumed by the SoC capture path; what this driver owns is everything
 * around it -- the bridge's power rail, the LT86102UXE splitter's rail, the
 * HDMI loop-out switch, the two connector-presence pins, the bridge's
 * interrupt line, and the serial flash behind the bridge that holds the EDID
 * the attached host actually sees.
 *
 * It publishes that state through /proc/lt6911_info/, a 15-file ABI that the
 * NanoKVM userspace already speaks: libkvm scanf()s width/height/fps and
 * string-matches hdmi_rx_status, and the Go server exact-matches "on" on the
 * three power files, reads byte 12 of edid_snapshot to name the loaded EDID,
 * writes a whole 256-byte EDID to edid in one syscall, and parses version for
 * an ATX/Desk token. Every payload string and write grammar below is fixed by
 * those consumers. Do not tidy them.
 *
 * Ported from the vendor's 4.19 drivers/misc/lt6911_manage.c v0.0.32
 * (GPL-2.0), which this replaces. The port is scoped to the LT6911UXC: the
 * vendor file also carries LT6911C and LT6911D register maps and an AX-Pi
 * board variant, all reached through a board-version check that its own
 * header compiles to a constant (CHECK_BOARD_VERSION is commented out, so
 * board_version is always BOARD_VERSION_NanoKVM_PRO). This board has one
 * bridge and it is a UXC, so the other two chips and the probe-by-I2C-poke
 * that would pick between them are gone.
 *
 * Differences from the vendor driver that are fixes, not preferences, are
 * marked "vendor bug" at the point where they matter.
 *
 * Copyright (c) 2026 the open-nanokvm-pro contributors.
 */

#include <linux/atomic.h>
#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/gpio/consumer.h>
#include <linux/i2c.h>
#include <linux/interrupt.h>
#include <linux/ktime.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/moduleparam.h>
#include <linux/mutex.h>
#include <linux/poll.h>
#include <linux/proc_fs.h>
#include <linux/slab.h>
#include <linux/sprintf.h>
#include <linux/stdarg.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/wait.h>
#include <linux/workqueue.h>

/* --- register banks ------------------------------------------------------ */

/*
 * The LT6911UXC presents one 8-bit register window per bank and switches
 * banks through register 0xff. Every access here writes the bank byte first,
 * unconditionally.
 *
 * The vendor caches the last bank written and skips the select when it has
 * not changed -- but it never invalidates that cache across the chip power
 * cycles its own EDID paths perform, so the first access after a power cycle
 * can land in whatever bank the chip resets to while the driver believes it
 * is somewhere else. That is a vendor bug, and it is latent rather than fatal
 * only because the paths that power-cycle happen to re-select a bank early.
 * One extra byte per transfer buys the whole class of problem away.
 */
#define LT6911_REG_BANK			0xff

#define LT6911_BANK_SYS			0x80	/* control + flash bridge */
#define LT6911_BANK_SYS3		0x81	/* chip ID, flash handshake */
#define LT6911_BANK_CSI			0x85	/* CSI-side timing info */
#define LT6911_BANK_HDMI		0x86	/* HDMI-side signal info */
#define LT6911_BANK_SYS2		0x90	/* watchdog */
#define LT6911_BANK_AUDIO		0xb0	/* audio info */
#define LT6911_BANK_CSI_TOTAL		0xd4	/* CSI H/V totals */

/* Bank 0x80. */
#define LT6911_SYS_ENABLE		0xee	/* 1 = registers live */

/* Bank 0x81. */
#define LT6911_SYS3_CHIP_ID		0x00	/* 0x00..0x02 = 17 04 83 */
#define LT6911_SYS3_FLASH_ACK		0x08

/* Bank 0x86. */
#define LT6911_HDMI_ENABLE		0xee
#define LT6911_HDMI_SIGNAL		0xa3
#define LT6911_HDMI_SIGNAL_STABLE	0x55
#define LT6911_HDMI_SIGNAL_GONE		0x88
#define LT6911_HDMI_HDCP		0xab

/* Bank 0x85. */
#define LT6911_CSI_MEASURE		0x40
#define LT6911_CSI_MEASURE_START	0x21
#define LT6911_CSI_HALF_PCLK		0x48	/* 0x48..0x4a, big endian */
#define LT6911_CSI_VACTIVE		0xf0	/* 0xf0..0xf1, big endian */
#define LT6911_CSI_HACTIVE		0xea	/* 0xea..0xeb, big endian */

/* Bank 0x90. */
#define LT6911_SYS2_WATCHDOG		0x10

/* Bank 0xb0. */
#define LT6911_AUDIO_SIGNAL		0xa5
#define LT6911_AUDIO_SIGNAL_GONE	0x88
#define LT6911_AUDIO_SIGNAL_HI		0x55
#define LT6911_AUDIO_SIGNAL_LO		0xaa
#define LT6911_AUDIO_SIGNAL_ALT1	0x01	/* undocumented, but present */
#define LT6911_AUDIO_SIGNAL_ALT2	0x03
#define LT6911_AUDIO_SAMPLE_RATE	0xab

/* Bank 0xd4. */
#define LT6911_TOTAL_HTOTAL		0x26	/* 0x26..0x27, big endian */
#define LT6911_TOTAL_VTOTAL		0x32	/* 0x32..0x33, big endian */

/* HDCP mode, bank 0x86 register 0xab. */
#define LT6911_HDCP_NONE		0x00
#define LT6911_HDCP_14			0x01
#define LT6911_HDCP_22			0x02

#define LT6911_EDID_SIZE		256
#define LT6911_FLASH_PAGE		32	/* also I2C_SMBUS_BLOCK_MAX */
#define LT6911_VERSION_SIZE		LT6911_FLASH_PAGE

/*
 * The chip asserts its interrupt for a signal change; the connector-presence
 * pins bounce mechanically. 50 ms, from the vendor.
 */
#define LT6911_DETECT_DEBOUNCE_MS	50

/* The chip is left alone for this long between back-to-back EDID reads. */
#define LT6911_EDID_READ_INTERVAL_MS	500

/* --- state --------------------------------------------------------------- */

/*
 * A /proc payload plus its length. Reads are served with
 * simple_read_from_buffer() so that offset semantics -- and therefore Go's
 * os.ReadFile(), which reads until EOF -- behave exactly as before.
 */
struct lt6911_text {
	char buf[24];
	size_t len;
};

enum lt6911_res {
	LT6911_RES_NORMAL,	/* known mode, unchanged since last poll */
	LT6911_RES_NEW,		/* known mode, changed */
	LT6911_RES_UNSUPPORTED,	/* on the explicit reject list */
	LT6911_RES_UNKNOWN,	/* not on either list */
	LT6911_RES_ERROR,
};

enum lt6911_video {
	LT6911_VIDEO_GONE,
	LT6911_VIDEO_STABLE,
	LT6911_VIDEO_UNKNOWN,
};

/* Per-fd poll state for the three pollable files. */
struct lt6911_pollctx {
	int status_gen;
	int rx_gen;
	int tx_gen;
};

struct lt6911 {
	struct i2c_client *client;
	struct device *dev;

	struct gpio_desc *int_gpio;
	struct gpio_desc *pwr_gpio;
	struct gpio_desc *hdmi_pwr_gpio;
	struct gpio_descs *loopout_gpios;
	struct gpio_desc *rx_det_gpio;
	struct gpio_desc *tx_det_gpio;

	int int_irq;
	int rx_irq;
	int tx_irq;

	struct work_struct info_work;
	struct delayed_work detect_work;

	/*
	 * chip_lock serialises everything that touches the bridge: the bank
	 * register is chip-global state, so two interleaved transfers land in
	 * each other's bank. The vendor has no locking at all -- its info
	 * work and its EDID write can and do run concurrently.
	 *
	 * buf_lock serialises the /proc payloads. Same story: the vendor
	 * snprintf()s straight into a buffer a reader may be halfway through,
	 * so a read can return a torn string.
	 *
	 * Lock order is chip_lock then buf_lock, never the reverse.
	 */
	struct mutex chip_lock;	/* serialises all bridge register access */
	struct mutex buf_lock;	/* serialises the /proc payloads */

	struct proc_dir_entry *proc_dir;

	struct lt6911_text status;
	struct lt6911_text width;
	struct lt6911_text height;
	struct lt6911_text fps;
	struct lt6911_text hdcp;
	struct lt6911_text asr;
	struct lt6911_text power;
	struct lt6911_text hdmi_power;
	struct lt6911_text loopout_power;
	struct lt6911_text rx_status;
	struct lt6911_text tx_status;

	u8 edid[LT6911_EDID_SIZE];
	size_t edid_len;
	u8 edid_snapshot[LT6911_EDID_SIZE];
	size_t edid_snapshot_len;
	/* +1 so a flash image with no free byte still NUL-terminates. */
	char version[LT6911_VERSION_SIZE + 1];

	ktime_t edid_read_ts;

	/* Last geometry check_res() saw, for the new-versus-unchanged test. */
	u16 last_width;
	u16 last_height;

	wait_queue_head_t wq;
	atomic_t status_gen;
	atomic_t rx_gen;
	atomic_t tx_gen;
};

/*
 * /proc/lt6911_info is a global name, so this driver is a singleton by
 * construction and a second instance is refused. The pointer exists only for
 * the module parameters, whose .set callbacks have no device to work from;
 * the /proc handlers reach their instance through pde_data() instead.
 */
static DEFINE_MUTEX(lt6911_instance_lock);
static struct lt6911 *lt6911_instance;

/* --- module parameters --------------------------------------------------- */

static int force_width = -1;
static int force_height = -1;
static int force_fps = -1;

static void lt6911_force_resolution(struct lt6911 *lt, u16 width, u16 height,
				    int fps);

/*
 * Writing -1 over a previously forced value hands control back to the
 * hardware by re-running detection; anything else with both dimensions set
 * pins the reported mode. Setting a parameter before the device has probed
 * (insmod-time arguments) just records the value -- detection at the end of
 * probe picks it up.
 */
static int lt6911_force_param_set(const char *val,
				  const struct kernel_param *kp)
{
	int old = *(int *)kp->arg;
	int ret;

	ret = param_set_int(val, kp);
	if (ret)
		return ret;

	mutex_lock(&lt6911_instance_lock);
	if (!lt6911_instance)
		goto out;

	if (old != -1 && *(int *)kp->arg == -1)
		schedule_work(&lt6911_instance->info_work);
	else if (force_width > 0 && force_height > 0)
		lt6911_force_resolution(lt6911_instance, force_width,
					force_height, force_fps);
out:
	mutex_unlock(&lt6911_instance_lock);
	return 0;
}

static const struct kernel_param_ops lt6911_force_param_ops = {
	.set = lt6911_force_param_set,
	.get = param_get_int,
};

module_param_cb(force_width, &lt6911_force_param_ops, &force_width, 0644);
MODULE_PARM_DESC(force_width, "Force HDMI width, -1 to detect");
module_param_cb(force_height, &lt6911_force_param_ops, &force_height, 0644);
MODULE_PARM_DESC(force_height, "Force HDMI height, -1 to detect");
module_param_cb(force_fps, &lt6911_force_param_ops, &force_fps, 0644);
MODULE_PARM_DESC(force_fps, "Force HDMI fps, -1 to detect");

/* --- supported modes ----------------------------------------------------- */

/* Transcribed from the vendor's hdmi_res_list[]. */
static const u16 lt6911_res_list[][2] = {
	{ 3840, 2400 }, { 3840, 2160 }, { 3440, 1440 }, { 2560, 1600 },
	{ 2560, 1440 }, { 2560, 1080 }, { 2048, 1536 }, { 2048, 1152 },
	{ 1920, 1440 }, { 1920, 1200 }, { 1920, 1080 }, { 1680, 1050 },
	{ 1600, 1200 }, { 1600,  900 }, { 1440, 1080 }, { 1440,  900 },
	{ 1440, 1050 }, { 1368,  768 }, { 1280, 1024 }, { 1280,  960 },
	{ 1280,  800 }, { 1280,  720 }, { 1152,  864 }, { 1024,  768 },
	{  800,  600 },
};

/* And its hdmi_unsupported_res_list[]: modes seen but explicitly rejected. */
static const u16 lt6911_unsupported_res_list[][2] = {
	{ 1366, 768 },
};

/* --- text payload helpers ------------------------------------------------ */

/* Caller holds lt->buf_lock. */
static __printf(2, 3) void lt6911_set_text(struct lt6911_text *t,
					   const char *fmt, ...)
{
	va_list args;

	va_start(args, fmt);
	t->len = vscnprintf(t->buf, sizeof(t->buf), fmt, args);
	va_end(args);
}

static ssize_t lt6911_text_read(struct lt6911 *lt, struct lt6911_text *t,
				char __user *ubuf, size_t count, loff_t *ppos)
{
	char snapshot[sizeof(t->buf)];
	size_t len;

	/*
	 * Copy under the lock, hand to userspace outside it: copy_to_user()
	 * can fault, and faulting with a driver mutex held is how a page
	 * fault handler ends up waiting on an I2C transfer.
	 */
	mutex_lock(&lt->buf_lock);
	len = t->len;
	memcpy(snapshot, t->buf, len);
	mutex_unlock(&lt->buf_lock);

	return simple_read_from_buffer(ubuf, count, ppos, snapshot, len);
}

#define LT6911_TEXT_READ_OP(name, field)				\
static ssize_t lt6911_##name##_read(struct file *file, char __user *ubuf, \
				    size_t count, loff_t *ppos)		\
{									\
	struct lt6911 *lt = pde_data(file_inode(file));			\
									\
	return lt6911_text_read(lt, &lt->field, ubuf, count, ppos);	\
}

/*
 * "on"/"1" and "off"/"0", prefix-matched exactly as the vendor does so that
 * a trailing newline (or its absence -- libkvm writes a bare "on") is
 * accepted either way. 15 bytes is the vendor's limit and stays the limit.
 */
static int lt6911_parse_onoff(const char __user *ubuf, size_t count, bool *on)
{
	char buf[16];

	if (count > sizeof(buf) - 1)
		return -EINVAL;
	if (copy_from_user(buf, ubuf, count))
		return -EFAULT;
	buf[count] = '\0';

	if (!strncmp(buf, "on", 2) || !strncmp(buf, "1", 1))
		*on = true;
	else if (!strncmp(buf, "off", 3) || !strncmp(buf, "0", 1))
		*on = false;
	else
		return -EINVAL;

	return 0;
}

/* --- chip access --------------------------------------------------------- */

/* All of these require lt->chip_lock. */

static int lt6911_write(struct lt6911 *lt, u8 bank, u8 reg, u8 val)
{
	int ret;

	ret = i2c_smbus_write_byte_data(lt->client, LT6911_REG_BANK, bank);
	if (ret < 0)
		goto err;

	ret = i2c_smbus_write_byte_data(lt->client, reg, val);
	if (ret < 0)
		goto err;

	return 0;
err:
	dev_err(lt->dev, "write %02x:%02x = %02x failed: %d\n", bank, reg,
		val, ret);
	return ret;
}

static int lt6911_read(struct lt6911 *lt, u8 bank, u8 reg, u8 *val)
{
	int ret;

	ret = i2c_smbus_write_byte_data(lt->client, LT6911_REG_BANK, bank);
	if (ret < 0)
		goto err;

	ret = i2c_smbus_read_byte_data(lt->client, reg);
	if (ret < 0)
		goto err;

	*val = ret;
	return 0;
err:
	dev_err(lt->dev, "read %02x:%02x failed: %d\n", bank, reg, ret);
	return ret;
}

/* Read a big-endian 16-bit value from two consecutive registers. */
static int lt6911_read_be16(struct lt6911 *lt, u8 bank, u8 reg, u16 *val)
{
	u8 hi, lo;
	int ret;

	ret = lt6911_read(lt, bank, reg, &hi);
	if (ret)
		return ret;
	ret = lt6911_read(lt, bank, reg + 1, &lo);
	if (ret)
		return ret;

	*val = (hi << 8) | lo;
	return 0;
}

static int lt6911_write_block(struct lt6911 *lt, u8 bank, u8 reg,
			      const u8 *data, u8 len)
{
	int ret;

	ret = i2c_smbus_write_byte_data(lt->client, LT6911_REG_BANK, bank);
	if (ret < 0)
		goto err;

	ret = i2c_smbus_write_i2c_block_data(lt->client, reg, len, data);
	if (ret < 0)
		goto err;

	return 0;
err:
	dev_err(lt->dev, "block write %02x:%02x failed: %d\n", bank, reg, ret);
	return ret;
}

static int lt6911_read_block(struct lt6911 *lt, u8 bank, u8 reg, u8 *data,
			     u8 len)
{
	int ret;

	ret = i2c_smbus_write_byte_data(lt->client, LT6911_REG_BANK, bank);
	if (ret < 0)
		goto err;

	ret = i2c_smbus_read_i2c_block_data(lt->client, reg, len, data);
	if (ret < 0)
		goto err;

	return 0;
err:
	dev_err(lt->dev, "block read %02x:%02x failed: %d\n", bank, reg, ret);
	return ret;
}

struct lt6911_regval {
	u8 reg;
	u8 val;
};

/* Play a register sequence into bank 0x80. */
static int lt6911_write_sys_seq(struct lt6911 *lt,
				const struct lt6911_regval *seq, size_t n)
{
	size_t i;
	int ret;

	for (i = 0; i < n; i++) {
		ret = lt6911_write(lt, LT6911_BANK_SYS, seq[i].reg,
				   seq[i].val);
		if (ret)
			return ret;
	}

	return 0;
}

static int lt6911_enable(struct lt6911 *lt)
{
	return lt6911_write(lt, LT6911_BANK_SYS, LT6911_SYS_ENABLE, 0x01);
}

static int lt6911_disable(struct lt6911 *lt)
{
	return lt6911_write(lt, LT6911_BANK_SYS, LT6911_SYS_ENABLE, 0x00);
}

/*
 * The bridge has its own watchdog that reloads its firmware if the host stops
 * talking to it. Reading the info registers takes long enough to trip it, so
 * the vendor turns it off before every poll and never turns it back on.
 */
static int lt6911_disable_watchdog(struct lt6911 *lt)
{
	return lt6911_write(lt, LT6911_BANK_SYS2, LT6911_SYS2_WATCHDOG, 0x00);
}

static int lt6911_check_chip_id(struct lt6911 *lt)
{
	unsigned int i;
	u8 id[3];
	int ret;

	ret = lt6911_enable(lt);
	if (ret)
		return ret;

	for (i = 0; i < ARRAY_SIZE(id); i++) {
		ret = lt6911_read(lt, LT6911_BANK_SYS3,
				  LT6911_SYS3_CHIP_ID + i, &id[i]);
		if (ret)
			return ret;
	}

	if (id[0] != 0x17 || id[1] != 0x04 || id[2] != 0x83) {
		dev_err(lt->dev, "not an LT6911UXC: ID %02x %02x %02x\n",
			id[0], id[1], id[2]);
		return -ENODEV;
	}

	dev_info(lt->dev, "LT6911UXC found\n");
	return 0;
}

/* --- GPIO ---------------------------------------------------------------- */

/*
 * Polarity lives in DT, never here. Every descriptor is used through the
 * logical-value API, so throughout this driver 1 means asserted: the bridge
 * and splitter rails are on, loop-out is enabled, a connector has a cable in
 * it, and the bridge's interrupt line is claiming attention. The two
 * connector-presence pins and both loop-out control lines read low in that
 * state in hardware and must carry GPIO_ACTIVE_LOW in DT; the rails are
 * active high.
 */

static int lt6911_set_power(struct lt6911 *lt, bool on)
{
	int ret;

	ret = gpiod_set_value_cansleep(lt->pwr_gpio, on);
	if (ret) {
		dev_err(lt->dev, "failed to switch bridge power: %d\n", ret);
		return ret;
	}

	mutex_lock(&lt->buf_lock);
	lt6911_set_text(&lt->power, on ? "on\n" : "off\n");
	mutex_unlock(&lt->buf_lock);

	return 0;
}

static int lt6911_set_hdmi_power(struct lt6911 *lt, bool on)
{
	int ret;

	ret = gpiod_set_value_cansleep(lt->hdmi_pwr_gpio, on);
	if (ret) {
		dev_err(lt->dev, "failed to switch splitter power: %d\n", ret);
		return ret;
	}

	mutex_lock(&lt->buf_lock);
	lt6911_set_text(&lt->hdmi_power, on ? "on\n" : "off\n");
	mutex_unlock(&lt->buf_lock);

	return 0;
}

/*
 * Loop-out is gated by two lines that are always driven together -- one on
 * the splitter, one on the connector mux -- so DT hands them over as an
 * array and they move as one.
 */
static int lt6911_set_loopout(struct lt6911 *lt, bool on)
{
	unsigned long values = on ? GENMASK(lt->loopout_gpios->ndescs - 1, 0)
				  : 0;
	int ret;

	ret = gpiod_set_array_value_cansleep(lt->loopout_gpios->ndescs,
					     lt->loopout_gpios->desc,
					     lt->loopout_gpios->info, &values);
	if (ret) {
		dev_err(lt->dev, "failed to switch loop-out: %d\n", ret);
		return ret;
	}

	mutex_lock(&lt->buf_lock);
	lt6911_set_text(&lt->loopout_power, on ? "on\n" : "off\n");
	mutex_unlock(&lt->buf_lock);

	return 0;
}

/*
 * Publish both connector-presence pins and wake their pollers. The vendor's
 * third payload, "unsupport\n", existed for the AX-Pi variant that has no
 * such pins; here both descriptors are mandatory, so it cannot occur.
 */
static void lt6911_update_detect(struct lt6911 *lt)
{
	bool rx = gpiod_get_value_cansleep(lt->rx_det_gpio) > 0;
	bool tx = gpiod_get_value_cansleep(lt->tx_det_gpio) > 0;

	mutex_lock(&lt->buf_lock);
	lt6911_set_text(&lt->rx_status, rx ? "access\n" : "extract\n");
	lt6911_set_text(&lt->tx_status, tx ? "access\n" : "extract\n");
	mutex_unlock(&lt->buf_lock);

	atomic_inc(&lt->rx_gen);
	atomic_inc(&lt->tx_gen);
	wake_up_interruptible(&lt->wq);
}

/*
 * Power-cycle the bridge. Used after every flash write and after the
 * rate-limited EDID read, because the bridge only re-reads its flash out of
 * reset -- and because dropping the rail drops HPD, which is what makes the
 * attached host re-read the EDID that was just programmed.
 */
static int lt6911_power_cycle(struct lt6911 *lt)
{
	int ret;

	ret = lt6911_set_power(lt, false);
	if (ret)
		return ret;

	msleep(100);

	return lt6911_set_power(lt, true);
}

/* --- signal state -------------------------------------------------------- */

/* Caller holds lt->chip_lock. */
static int lt6911_get_signal_state(struct lt6911 *lt, enum lt6911_video *video,
				   bool *audio)
{
	u8 val;
	int ret;

	ret = lt6911_write(lt, LT6911_BANK_HDMI, LT6911_HDMI_ENABLE, 0x00);
	if (ret)
		return ret;

	ret = lt6911_read(lt, LT6911_BANK_HDMI, LT6911_HDMI_SIGNAL, &val);
	if (ret)
		return ret;

	switch (val) {
	case LT6911_HDMI_SIGNAL_STABLE:
		*video = LT6911_VIDEO_STABLE;
		break;
	case LT6911_HDMI_SIGNAL_GONE:
		*video = LT6911_VIDEO_GONE;
		break;
	default:
		/*
		 * The vendor logs this and then treats it as signal-gone, so
		 * its "unknown\n" status string -- part of the documented
		 * /proc ABI -- is unreachable in its own driver. Route the
		 * unrecognised value there instead: strictly more
		 * informative, and no consumer distinguishes the two.
		 */
		dev_dbg(lt->dev, "unknown HDMI signal state 0x%02x\n", val);
		*video = LT6911_VIDEO_UNKNOWN;
		break;
	}

	ret = lt6911_read(lt, LT6911_BANK_AUDIO, LT6911_AUDIO_SIGNAL, &val);
	if (ret)
		return ret;

	switch (val) {
	case LT6911_AUDIO_SIGNAL_HI:
	case LT6911_AUDIO_SIGNAL_LO:
	case LT6911_AUDIO_SIGNAL_ALT1:
	case LT6911_AUDIO_SIGNAL_ALT2:
		/*
		 * The vendor also derives a "sample rate went up or down"
		 * hint from which of these it saw and then never reads it
		 * back. Presence is the only thing that reaches /proc.
		 */
		*audio = true;
		break;
	case LT6911_AUDIO_SIGNAL_GONE:
		*audio = false;
		break;
	default:
		dev_dbg(lt->dev, "unknown audio signal state 0x%02x\n", val);
		*audio = false;
		break;
	}

	return 0;
}

static enum lt6911_res lt6911_check_res(struct lt6911 *lt, u16 width,
					u16 height)
{
	unsigned int i;

	/*
	 * The vendor computes an ERROR_RES class, publishes "error res" for
	 * it, and can never produce it -- its classifier only ever returns
	 * the other four. A locked-but-blank geometry is the case that
	 * deserves the string: reporting 0x0 as "new res" tells userspace to
	 * go and configure a zero-width capture.
	 */
	if (!width || !height)
		return LT6911_RES_ERROR;

	for (i = 0; i < ARRAY_SIZE(lt6911_res_list); i++) {
		if (width != lt6911_res_list[i][0] ||
		    height != lt6911_res_list[i][1])
			continue;

		if (lt->last_width != width || lt->last_height != height) {
			lt->last_width = width;
			lt->last_height = height;
			return LT6911_RES_NEW;
		}
		return LT6911_RES_NORMAL;
	}

	for (i = 0; i < ARRAY_SIZE(lt6911_unsupported_res_list); i++) {
		if (width == lt6911_unsupported_res_list[i][0] &&
		    height == lt6911_unsupported_res_list[i][1])
			return LT6911_RES_UNSUPPORTED;
	}

	return LT6911_RES_UNKNOWN;
}

/* Caller holds lt->chip_lock. */
static int lt6911_get_res(struct lt6911 *lt, u16 *width, u16 *height)
{
	int ret;

	ret = lt6911_read_be16(lt, LT6911_BANK_CSI, LT6911_CSI_VACTIVE,
			       height);
	if (ret)
		return ret;

	return lt6911_read_be16(lt, LT6911_BANK_CSI, LT6911_CSI_HACTIVE,
				width);
}

/*
 * Frame rate is computed, not read. The bridge exposes a pixel-clock counter
 * rather than a frame counter, so: latch H and V totals, kick a measurement,
 * read back half the pixel clock in units of 1 kHz, and divide. The vendor's
 * comment records why it does not use the datasheet's method -- "there was a
 * significant deviation between the manual scheme and the actual frame rate".
 *
 * Caller holds lt->chip_lock.
 */
static int lt6911_get_fps(struct lt6911 *lt, u16 *fps)
{
	u16 htotal, vtotal;
	unsigned int i;
	u8 val[3];
	u32 clk;
	int ret;

	ret = lt6911_read_be16(lt, LT6911_BANK_CSI_TOTAL, LT6911_TOTAL_HTOTAL,
			       &htotal);
	if (ret)
		return ret;
	ret = lt6911_read_be16(lt, LT6911_BANK_CSI_TOTAL, LT6911_TOTAL_VTOTAL,
			       &vtotal);
	if (ret)
		return ret;

	msleep(20);

	ret = lt6911_write(lt, LT6911_BANK_CSI, LT6911_CSI_MEASURE,
			   LT6911_CSI_MEASURE_START);
	if (ret)
		return ret;

	/* The vendor's msleep(10); a short sleep wants a bounded one. */
	usleep_range(10000, 15000);

	for (i = 0; i < ARRAY_SIZE(val); i++) {
		ret = lt6911_read(lt, LT6911_BANK_CSI,
				  LT6911_CSI_HALF_PCLK + i, &val[i]);
		if (ret)
			return ret;
	}

	/* Top nibble of the first byte is not part of the count. */
	clk = ((val[0] & 0x0f) << 16) | (val[1] << 8) | val[2];

	/*
	 * A bridge that has not locked reports zero totals, and the vendor
	 * divides by them anyway. clk is 20 bits and each total is 16, so the
	 * products below cannot overflow u32.
	 */
	if (!htotal || !vtotal) {
		dev_dbg(lt->dev, "no timing yet (H %u, V %u)\n", htotal,
			vtotal);
		*fps = 0;
		return 0;
	}

	*fps = (clk * 2000U) / ((u32)htotal * vtotal);
	return 0;
}

/* --- serial flash: EDID and version string ------------------------------- */

/*
 * The LT6911UXC keeps the EDID it presents to the attached host, plus a
 * 32-byte free-form string the NanoKVM uses as a hardware version, in an
 * attached serial flash reached through a register window at 0x58..0x5f in
 * bank 0x80. Page 0x80xx holds the 256-byte EDID; page 0x8100 holds the
 * string.
 *
 * The register semantics are not public. Every sequence below is a
 * transcription of the vendor driver's, reorganised into the shared prologues
 * and per-page bodies it open-codes but not otherwise altered. Do not
 * "simplify" one on the strength of what a bit looks like it does.
 *
 * The vendor's opening write of 0x80 to the bank register while already on
 * bank 0x80 is kept as the first entry of each prologue: a bank select is
 * idempotent and this stays a transcription.
 */

/* Erase the flash. Shared by the EDID and version writers verbatim. */
static const struct lt6911_regval lt6911_flash_erase_seq[] = {
	{ 0xff, 0x80 }, { LT6911_SYS_ENABLE, 0x01 },
	{ 0x5e, 0xdf }, { 0x58, 0x00 }, { 0x59, 0x51 }, { 0x5a, 0x10 },
	{ 0x5a, 0x00 }, { 0x58, 0x21 },
	{ 0xff, 0x80 }, { LT6911_SYS_ENABLE, 0x01 },
	{ 0x5a, 0x80 }, { 0x5a, 0x84 }, { 0x5a, 0x80 }, { 0x5b, 0x01 },
	{ 0x5c, 0x80 }, { 0x5d, 0x00 }, { 0x5a, 0x81 }, { 0x5a, 0x80 },
};

/* Prologue before programming pages. */
static const struct lt6911_regval lt6911_flash_prog_seq[] = {
	{ 0xff, 0x80 }, { LT6911_SYS_ENABLE, 0x01 },
	{ 0x5a, 0x84 }, { 0x5a, 0x80 }, { 0x5a, 0x84 }, { 0x5a, 0x80 },
};

/* Prologue before reading pages. */
static const struct lt6911_regval lt6911_flash_read_seq[] = {
	{ 0xff, 0x80 }, { LT6911_SYS_ENABLE, 0x01 },
	{ 0x5a, 0x84 }, { 0x5a, 0x80 },
};

/*
 * Handshake through bank 0x81 register 0x08, run after the erase and again
 * after the last programmed page. The register must read back 0xee; the
 * 0xae/0xee pair that follows is a toggle whose purpose is undocumented.
 *
 * Vendor bug: it writes this as `if (i2c_read_byte(...));` -- an if with an
 * empty body -- so a failed read leaves chip_data[] holding stack garbage
 * that is then compared against 0xee. The read is checked here.
 */
static int lt6911_flash_ack(struct lt6911 *lt)
{
	u8 val;
	int ret;

	ret = lt6911_read(lt, LT6911_BANK_SYS3, LT6911_SYS3_FLASH_ACK, &val);
	if (ret)
		return ret;

	if (val != 0xee) {
		dev_err(lt->dev, "flash handshake read %02x, want ee\n", val);
		return -EIO;
	}

	ret = lt6911_write(lt, LT6911_BANK_SYS3, LT6911_SYS3_FLASH_ACK, 0xae);
	if (ret)
		return ret;

	return lt6911_write(lt, LT6911_BANK_SYS3, LT6911_SYS3_FLASH_ACK, 0xee);
}

/* Program one page. @last marks the final page of the whole transaction. */
static int lt6911_flash_write_page(struct lt6911 *lt, const u8 *data, u8 len,
				   u8 page_hi, u8 page_lo, bool last)
{
	static const struct lt6911_regval pre[] = {
		{ 0x5e, 0xdf }, { 0x5a, 0x20 }, { 0x5a, 0x00 }, { 0x58, 0x21 },
	};
	int ret;

	ret = lt6911_write_sys_seq(lt, pre, ARRAY_SIZE(pre));
	if (ret)
		return ret;

	ret = lt6911_write_block(lt, LT6911_BANK_SYS, 0x59, data, len);
	if (ret)
		return ret;

	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5b, 0x01);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5c, page_hi);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5d, page_lo);
	if (ret)
		return ret;

	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5e, 0xc0);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5a, 0x90);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5a, 0x80);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5a, last ? 0x88 : 0x84);
	if (ret)
		return ret;

	return lt6911_write(lt, LT6911_BANK_SYS, 0x5a, 0x80);
}

static int lt6911_flash_read_page(struct lt6911 *lt, u8 *data, u8 len,
				  u8 page_hi, u8 page_lo)
{
	int ret;

	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5e, 0x5f);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5a, 0xa0);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5a, 0x80);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5b, 0x01);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5c, page_hi);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5d, page_lo);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5a, 0x90);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x5a, 0x80);
	if (ret)
		return ret;
	ret = lt6911_write(lt, LT6911_BANK_SYS, 0x58, 0x21);
	if (ret)
		return ret;

	return lt6911_read_block(lt, LT6911_BANK_SYS, 0x5f, data, len);
}

/*
 * Read the 32-byte version string. Erased flash reads back as 0xff, which is
 * turned into NUL so the result is an ordinary C string.
 *
 * @str must hold LT6911_VERSION_SIZE + 1 bytes: the vendor passes a bare
 * 32-byte buffer, fills all 32, and then strlen()s it, which runs off the end
 * for a full-length string. Caller holds lt->chip_lock.
 */
static int lt6911_version_read(struct lt6911 *lt, char *str)
{
	int ret, i;

	ret = lt6911_write_sys_seq(lt, lt6911_flash_read_seq,
				   ARRAY_SIZE(lt6911_flash_read_seq));
	if (ret)
		return ret;

	ret = lt6911_flash_read_page(lt, (u8 *)str, LT6911_VERSION_SIZE,
				     0x81, 0x00);
	if (ret)
		return ret;

	for (i = 0; i < LT6911_VERSION_SIZE; i++) {
		if (str[i] == (char)0xff)
			str[i] = '\0';
	}
	str[LT6911_VERSION_SIZE] = '\0';

	return 0;
}

/*
 * Write the version string. Write-once: the erase that would be needed to
 * replace a populated string would take the EDID with it, so a chip that
 * already carries a version is refused. Caller holds lt->chip_lock.
 */
static int lt6911_version_write(struct lt6911 *lt, const u8 *str, u8 len)
{
	char current_str[LT6911_VERSION_SIZE + 1];
	int ret, i;

	if (len > LT6911_VERSION_SIZE)
		return -EINVAL;

	ret = lt6911_version_read(lt, current_str);
	if (ret)
		return ret;

	for (i = 0; i < LT6911_VERSION_SIZE; i++) {
		if (current_str[i]) {
			dev_err(lt->dev, "version string already written\n");
			return -EIO;
		}
	}

	ret = lt6911_write_sys_seq(lt, lt6911_flash_erase_seq,
				   ARRAY_SIZE(lt6911_flash_erase_seq));
	if (ret)
		return ret;

	msleep(500);

	ret = lt6911_flash_ack(lt);
	if (ret)
		return ret;

	ret = lt6911_write_sys_seq(lt, lt6911_flash_prog_seq,
				   ARRAY_SIZE(lt6911_flash_prog_seq));
	if (ret)
		return ret;

	ret = lt6911_flash_write_page(lt, str, len, 0x81, 0x00, true);
	if (ret)
		return ret;

	return lt6911_flash_ack(lt);
}

/* Caller holds lt->chip_lock. */
static int lt6911_edid_read(struct lt6911 *lt, u8 *edid)
{
	int ret, i;

	ret = lt6911_write_sys_seq(lt, lt6911_flash_read_seq,
				   ARRAY_SIZE(lt6911_flash_read_seq));
	if (ret)
		return ret;

	for (i = 0; i < LT6911_EDID_SIZE / LT6911_FLASH_PAGE; i++) {
		ret = lt6911_flash_read_page(lt,
					     edid + i * LT6911_FLASH_PAGE,
					     LT6911_FLASH_PAGE, 0x80,
					     i * LT6911_FLASH_PAGE);
		if (ret)
			return ret;
	}

	return 0;
}

/*
 * Program a 256-byte EDID.
 *
 * The erase takes the version string with it, so the string is read out
 * first and written back as the transaction's final page. Caller holds
 * lt->chip_lock.
 */
static int lt6911_edid_write(struct lt6911 *lt, const u8 *edid)
{
	char version[LT6911_VERSION_SIZE + 1];
	int ret, i;

	ret = lt6911_version_read(lt, version);
	if (ret)
		return ret;

	ret = lt6911_write_sys_seq(lt, lt6911_flash_erase_seq,
				   ARRAY_SIZE(lt6911_flash_erase_seq));
	if (ret)
		return ret;

	msleep(500);

	ret = lt6911_flash_ack(lt);
	if (ret)
		return ret;

	ret = lt6911_write_sys_seq(lt, lt6911_flash_prog_seq,
				   ARRAY_SIZE(lt6911_flash_prog_seq));
	if (ret)
		return ret;

	for (i = 0; i < LT6911_EDID_SIZE / LT6911_FLASH_PAGE; i++) {
		ret = lt6911_flash_write_page(lt,
					      edid + i * LT6911_FLASH_PAGE,
					      LT6911_FLASH_PAGE, 0x80,
					      i * LT6911_FLASH_PAGE, false);
		if (ret)
			return ret;
	}

	ret = lt6911_flash_write_page(lt, (const u8 *)version,
				      LT6911_VERSION_SIZE, 0x81, 0x00, true);
	if (ret)
		return ret;

	return lt6911_flash_ack(lt);
}

/* Header and both block checksums, exactly the vendor's check_edid(). */
static int lt6911_check_edid(struct lt6911 *lt, const u8 *edid, size_t len)
{
	static const u8 header[8] = { 0x00, 0xff, 0xff, 0xff,
				      0xff, 0xff, 0xff, 0x00 };
	u8 sum;
	int i;

	if (len != LT6911_EDID_SIZE) {
		dev_err(lt->dev, "EDID is %zu bytes, want %d\n", len,
			LT6911_EDID_SIZE);
		return -EINVAL;
	}

	if (memcmp(edid, header, sizeof(header))) {
		dev_err(lt->dev, "bad EDID header\n");
		return -EINVAL;
	}

	for (sum = 0, i = 0; i < 127; i++)
		sum += edid[i];
	if ((u8)(0x100 - sum) != edid[127]) {
		dev_err(lt->dev, "bad EDID block 0 checksum\n");
		return -EINVAL;
	}

	for (sum = 0, i = 128; i < 255; i++)
		sum += edid[i];
	if ((u8)(0x100 - sum) != edid[255]) {
		dev_err(lt->dev, "bad EDID block 1 checksum\n");
		return -EINVAL;
	}

	return 0;
}

/* --- signal change processing -------------------------------------------- */

static void lt6911_bump_status(struct lt6911 *lt)
{
	atomic_inc(&lt->status_gen);
	wake_up_interruptible(&lt->wq);
}

static void lt6911_force_resolution(struct lt6911 *lt, u16 width, u16 height,
				    int fps)
{
	mutex_lock(&lt->buf_lock);
	lt6911_set_text(&lt->status, "new res\n");
	lt6911_set_text(&lt->width, "%d\n", width);
	lt6911_set_text(&lt->height, "%d\n", height);
	lt6911_set_text(&lt->fps, "%d\n", fps > 0 ? fps : 30);
	mutex_unlock(&lt->buf_lock);

	lt6911_bump_status(lt);
}

/* Caller holds lt->chip_lock. */
static int lt6911_video_stable(struct lt6911 *lt)
{
	u16 width = 0, height = 0, fps = 0;
	enum lt6911_res res;
	u8 hdcp = 0;
	int ret;

	ret = lt6911_get_res(lt, &width, &height);
	if (ret)
		return ret;

	res = lt6911_check_res(lt, width, height);
	if (res == LT6911_RES_ERROR) {
		mutex_lock(&lt->buf_lock);
		lt6911_set_text(&lt->status, "error res\n");
		lt6911_set_text(&lt->width, "%d\n", 0);
		lt6911_set_text(&lt->height, "%d\n", 0);
		mutex_unlock(&lt->buf_lock);
		dev_err(lt->dev, "bad resolution %ux%u\n", width, height);
		return -EIO;
	}

	/*
	 * All four surviving classes report "new res". The vendor collapsed
	 * them deliberately -- its changelog entry is "0.0.15 - delete
	 * 'unknown res', 'unsupport res'" -- and userspace acknowledges by
	 * writing "ok" to status, which is what moves it to "stable". The
	 * classification is kept because it is the only place the supported
	 * mode list is consulted, and because restoring distinct strings
	 * later should be a one-line change.
	 */
	mutex_lock(&lt->buf_lock);
	lt6911_set_text(&lt->status, "new res\n");
	lt6911_set_text(&lt->width, "%d\n", width);
	lt6911_set_text(&lt->height, "%d\n", height);
	mutex_unlock(&lt->buf_lock);

	ret = lt6911_read(lt, LT6911_BANK_HDMI, LT6911_HDMI_HDCP, &hdcp);
	if (ret)
		return ret;

	mutex_lock(&lt->buf_lock);
	switch (hdcp) {
	case LT6911_HDCP_NONE:
		lt6911_set_text(&lt->hdcp, "no hdcp\n");
		break;
	case LT6911_HDCP_14:
		lt6911_set_text(&lt->hdcp, "hdcp 1.4\n");
		break;
	case LT6911_HDCP_22:
		lt6911_set_text(&lt->hdcp, "hdcp 2.2\n");
		break;
	default:
		lt6911_set_text(&lt->hdcp, "unknown hdcp\n");
		break;
	}
	mutex_unlock(&lt->buf_lock);

	ret = lt6911_get_fps(lt, &fps);
	if (ret)
		return ret;

	mutex_lock(&lt->buf_lock);
	lt6911_set_text(&lt->fps, "%d\n", fps);
	mutex_unlock(&lt->buf_lock);

	dev_dbg(lt->dev, "%ux%u@%u, hdcp %02x\n", width, height, fps, hdcp);
	lt6911_bump_status(lt);

	return 0;
}

static void lt6911_video_lost(struct lt6911 *lt, bool known)
{
	mutex_lock(&lt->buf_lock);
	lt6911_set_text(&lt->status, known ? "disappear\n" : "unknown\n");
	lt6911_set_text(&lt->width, "%d\n", 0);
	lt6911_set_text(&lt->height, "%d\n", 0);
	lt6911_set_text(&lt->fps, "%d\n", 0);
	lt6911_set_text(&lt->hdcp, known ? "no hdcp\n" : "unknown hdcp\n");
	mutex_unlock(&lt->buf_lock);

	lt6911_bump_status(lt);
}

/*
 * Sample rate is published as the raw register value, not in Hz. The vendor
 * never converts it and libkvm never reads it, so converting now would be an
 * ABI change for no gain.
 *
 * Caller holds lt->chip_lock.
 */
static void lt6911_audio_update(struct lt6911 *lt, bool present)
{
	u8 val;

	if (!present) {
		mutex_lock(&lt->buf_lock);
		lt6911_set_text(&lt->asr, "disappear\n");
		mutex_unlock(&lt->buf_lock);
		return;
	}

	if (lt6911_read(lt, LT6911_BANK_AUDIO, LT6911_AUDIO_SAMPLE_RATE,
			&val)) {
		mutex_lock(&lt->buf_lock);
		lt6911_set_text(&lt->asr, "unknown\n");
		mutex_unlock(&lt->buf_lock);
		return;
	}

	mutex_lock(&lt->buf_lock);
	lt6911_set_text(&lt->asr, "%d\n", val);
	mutex_unlock(&lt->buf_lock);
}

static void lt6911_info_work_fn(struct work_struct *work)
{
	struct lt6911 *lt = container_of(work, struct lt6911, info_work);
	enum lt6911_video video;
	bool audio;

	mutex_lock(&lt->chip_lock);

	if (lt6911_enable(lt))
		goto out;
	if (lt6911_disable_watchdog(lt))
		goto disable;
	if (lt6911_get_signal_state(lt, &video, &audio))
		goto disable;

	switch (video) {
	case LT6911_VIDEO_STABLE:
		/*
		 * A forced geometry wins over what the bridge reports, so a
		 * host whose mode the bridge misreads can still be captured.
		 */
		if (force_width > 0 && force_height > 0)
			lt6911_force_resolution(lt, force_width, force_height,
						force_fps);
		else if (lt6911_video_stable(lt))
			goto disable;
		break;
	case LT6911_VIDEO_GONE:
		lt6911_video_lost(lt, true);
		break;
	case LT6911_VIDEO_UNKNOWN:
		lt6911_video_lost(lt, false);
		break;
	}

	lt6911_audio_update(lt, audio);

disable:
	lt6911_disable(lt);
out:
	mutex_unlock(&lt->chip_lock);
}

static void lt6911_detect_work_fn(struct work_struct *work)
{
	struct lt6911 *lt = container_of(work, struct lt6911,
					 detect_work.work);

	lt6911_update_detect(lt);
}

/* --- interrupts ---------------------------------------------------------- */

/*
 * Threaded because it reads the line back: whether the interrupt is asserted
 * is what decides if there is anything to poll for, and reading a descriptor
 * is allowed to sleep.
 */
static irqreturn_t lt6911_int_thread(int irq, void *data)
{
	struct lt6911 *lt = data;

	if (gpiod_get_value_cansleep(lt->int_gpio) > 0)
		schedule_work(&lt->info_work);

	return IRQ_HANDLED;
}

/*
 * Connector presence. mod_delayed_work() rather than the vendor's
 * schedule_delayed_work(): the latter is a no-op when the work is already
 * queued, so it delays the first edge of a bounce instead of debouncing the
 * whole burst.
 */
static irqreturn_t lt6911_detect_irq(int irq, void *data)
{
	struct lt6911 *lt = data;

	mod_delayed_work(system_wq, &lt->detect_work,
			 msecs_to_jiffies(LT6911_DETECT_DEBOUNCE_MS));

	return IRQ_HANDLED;
}

/* --- /proc: simple readers ----------------------------------------------- */

LT6911_TEXT_READ_OP(width, width)
LT6911_TEXT_READ_OP(height, height)
LT6911_TEXT_READ_OP(fps, fps)
LT6911_TEXT_READ_OP(hdcp, hdcp)
LT6911_TEXT_READ_OP(asr, asr)
LT6911_TEXT_READ_OP(power, power)
LT6911_TEXT_READ_OP(hdmi_power, hdmi_power)
LT6911_TEXT_READ_OP(loopout_power, loopout_power)

static ssize_t lt6911_chip_id_read(struct file *file, char __user *ubuf,
				   size_t count, loff_t *ppos)
{
	static const char id[] = "lt6911uxc\n";

	return simple_read_from_buffer(ubuf, count, ppos, id, strlen(id));
}

/* --- /proc: power control ------------------------------------------------ */

static ssize_t lt6911_power_write(struct file *file, const char __user *ubuf,
				  size_t count, loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	bool on;
	int ret;

	ret = lt6911_parse_onoff(ubuf, count, &on);
	if (ret)
		return ret;

	ret = lt6911_set_power(lt, on);
	if (ret)
		return -EIO;

	/*
	 * Cutting the rail means there is no signal by definition, and
	 * pollers have to hear about it now -- nothing else will tell them.
	 */
	if (!on) {
		mutex_lock(&lt->buf_lock);
		lt6911_set_text(&lt->status, "disappear\n");
		mutex_unlock(&lt->buf_lock);
		lt6911_bump_status(lt);
	}

	return count;
}

static ssize_t lt6911_hdmi_power_write(struct file *file,
				       const char __user *ubuf, size_t count,
				       loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	bool on;
	int ret;

	ret = lt6911_parse_onoff(ubuf, count, &on);
	if (ret)
		return ret;

	if (lt6911_set_hdmi_power(lt, on))
		return -EIO;

	return count;
}

static ssize_t lt6911_loopout_power_write(struct file *file,
					  const char __user *ubuf,
					  size_t count, loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	bool on;
	int ret;

	ret = lt6911_parse_onoff(ubuf, count, &on);
	if (ret)
		return ret;

	if (lt6911_set_loopout(lt, on))
		return -EIO;

	return count;
}

/* --- /proc: pollable files ----------------------------------------------- */

/*
 * A poller compares its own generation counter against the driver's and gets
 * EPOLLPRI when they differ; reading resynchronises it. No module reference
 * is taken here -- procfs holds every in-flight call off against
 * proc_remove(), which is why struct proc_ops has no .owner.
 */
static int lt6911_poll_open(struct inode *inode, struct file *file)
{
	struct lt6911 *lt = pde_data(inode);
	struct lt6911_pollctx *p;

	p = kzalloc(sizeof(*p), GFP_KERNEL);
	if (!p)
		return -ENOMEM;

	p->status_gen = atomic_read(&lt->status_gen);
	p->rx_gen = atomic_read(&lt->rx_gen);
	p->tx_gen = atomic_read(&lt->tx_gen);
	file->private_data = p;

	return 0;
}

static int lt6911_poll_release(struct inode *inode, struct file *file)
{
	kfree(file->private_data);
	file->private_data = NULL;

	return 0;
}

static ssize_t lt6911_status_read(struct file *file, char __user *ubuf,
				  size_t count, loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	struct lt6911_pollctx *p = file->private_data;
	ssize_t ret;

	ret = lt6911_text_read(lt, &lt->status, ubuf, count, ppos);
	if (ret > 0 && p)
		p->status_gen = atomic_read(&lt->status_gen);

	return ret;
}

/*
 * "ok" acknowledges a reported mode change and moves status to "stable".
 * Anything else is swallowed: the vendor accepts and ignores it, and at
 * least one shipped script relies on that.
 */
static ssize_t lt6911_status_write(struct file *file, const char __user *ubuf,
				   size_t count, loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	bool changed = false;
	char buf[16];

	if (count > sizeof(buf) - 1)
		return -EINVAL;
	if (copy_from_user(buf, ubuf, count))
		return -EFAULT;
	buf[count] = '\0';

	if (strncmp(buf, "ok", 2))
		return count;

	mutex_lock(&lt->buf_lock);
	if (!strncmp(lt->status.buf, "new res", 7) ||
	    !strncmp(lt->status.buf, "error res", 9)) {
		lt6911_set_text(&lt->status, "stable\n");
		changed = true;
	}
	mutex_unlock(&lt->buf_lock);

	if (changed)
		lt6911_bump_status(lt);

	return count;
}

static __poll_t lt6911_status_poll(struct file *file, poll_table *wait)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	struct lt6911_pollctx *p = file->private_data;

	poll_wait(file, &lt->wq, wait);

	if (!p)
		return EPOLLERR;

	return atomic_read(&lt->status_gen) != p->status_gen ? EPOLLPRI : 0;
}

static ssize_t lt6911_rx_status_read(struct file *file, char __user *ubuf,
				     size_t count, loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	struct lt6911_pollctx *p = file->private_data;
	ssize_t ret;

	ret = lt6911_text_read(lt, &lt->rx_status, ubuf, count, ppos);
	if (ret > 0 && p)
		p->rx_gen = atomic_read(&lt->rx_gen);

	return ret;
}

static __poll_t lt6911_rx_status_poll(struct file *file, poll_table *wait)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	struct lt6911_pollctx *p = file->private_data;

	poll_wait(file, &lt->wq, wait);

	if (!p)
		return EPOLLERR;

	return atomic_read(&lt->rx_gen) != p->rx_gen ? EPOLLPRI : 0;
}

static ssize_t lt6911_tx_status_read(struct file *file, char __user *ubuf,
				     size_t count, loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	struct lt6911_pollctx *p = file->private_data;
	ssize_t ret;

	ret = lt6911_text_read(lt, &lt->tx_status, ubuf, count, ppos);
	if (ret > 0 && p)
		p->tx_gen = atomic_read(&lt->tx_gen);

	return ret;
}

/*
 * Loop-out control through the status file. This is legacy -- loopout_power
 * is the file that means it -- and it is kept because shipped userspace still
 * writes here.
 *
 * Vendor bug: it passes the raw __user pointer straight to strncmp(), which
 * dereferences user memory in kernel context. Copy first.
 */
static ssize_t lt6911_tx_status_write(struct file *file,
				      const char __user *ubuf, size_t count,
				      loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	bool on;
	int ret;

	ret = lt6911_parse_onoff(ubuf, count, &on);
	if (ret)
		return ret;

	if (lt6911_set_loopout(lt, on))
		return -EIO;

	return count;
}

static __poll_t lt6911_tx_status_poll(struct file *file, poll_table *wait)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	struct lt6911_pollctx *p = file->private_data;

	poll_wait(file, &lt->wq, wait);

	if (!p)
		return EPOLLERR;

	return atomic_read(&lt->tx_gen) != p->tx_gen ? EPOLLPRI : 0;
}

/* --- /proc: EDID and version --------------------------------------------- */

/*
 * Reading refreshes from the chip at most twice a second, because the refresh
 * ends in a power cycle: a caller that polls this file would otherwise hold
 * the bridge in permanent reset and there would be no video at all.
 */
static ssize_t lt6911_edid_proc_read(struct file *file, char __user *ubuf,
				     size_t count, loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	u8 snapshot[LT6911_EDID_SIZE];
	ktime_t now = ktime_get();
	size_t len;
	s64 age;
	int ret;

	mutex_lock(&lt->chip_lock);

	age = ktime_to_ms(ktime_sub(now, lt->edid_read_ts));
	if (!lt->edid_read_ts || age > LT6911_EDID_READ_INTERVAL_MS) {
		ret = lt6911_set_power(lt, true);
		if (ret)
			goto out;

		ret = lt6911_edid_read(lt, lt->edid);
		if (ret)
			goto out;

		mutex_lock(&lt->buf_lock);
		lt->edid_len = LT6911_EDID_SIZE;
		memcpy(lt->edid_snapshot, lt->edid, LT6911_EDID_SIZE);
		lt->edid_snapshot_len = LT6911_EDID_SIZE;
		mutex_unlock(&lt->buf_lock);

		ret = lt6911_power_cycle(lt);
		if (ret)
			goto out;
	}

	lt->edid_read_ts = now;

	mutex_lock(&lt->buf_lock);
	len = lt->edid_len;
	memcpy(snapshot, lt->edid, len);
	mutex_unlock(&lt->buf_lock);

	mutex_unlock(&lt->chip_lock);

	return simple_read_from_buffer(ubuf, count, ppos, snapshot, len);

out:
	mutex_unlock(&lt->chip_lock);
	return ret;
}

static ssize_t lt6911_edid_proc_write(struct file *file,
				      const char __user *ubuf, size_t count,
				      loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	u8 *wbuf, *rbuf;
	int ret;

	/*
	 * The Go server writes the whole 256-byte image in one syscall, and
	 * a partial EDID is not a thing worth programming, so short writes
	 * are refused rather than buffered.
	 *
	 * Vendor bug: it declares two VLAs of the caller's length on the
	 * kernel stack before validating anything, so a large write is a
	 * stack overflow reachable from any process that can open the file
	 * (mode 0666). These are bounded kmalloc()s.
	 */
	if (count != LT6911_EDID_SIZE)
		return -EINVAL;

	wbuf = kmalloc(2 * LT6911_EDID_SIZE, GFP_KERNEL);
	if (!wbuf)
		return -ENOMEM;
	rbuf = wbuf + LT6911_EDID_SIZE;

	if (copy_from_user(wbuf, ubuf, LT6911_EDID_SIZE)) {
		ret = -EFAULT;
		goto out;
	}

	ret = lt6911_check_edid(lt, wbuf, LT6911_EDID_SIZE);
	if (ret)
		goto out;

	mutex_lock(&lt->chip_lock);

	ret = lt6911_set_power(lt, true);
	if (ret)
		goto out_unlock;

	ret = lt6911_edid_write(lt, wbuf);
	if (ret)
		goto out_unlock;

	ret = lt6911_edid_read(lt, rbuf);
	if (ret)
		goto out_unlock;

	mutex_lock(&lt->buf_lock);
	memcpy(lt->edid_snapshot, rbuf, LT6911_EDID_SIZE);
	lt->edid_snapshot_len = LT6911_EDID_SIZE;
	mutex_unlock(&lt->buf_lock);

	if (memcmp(wbuf, rbuf, LT6911_EDID_SIZE)) {
		dev_err(lt->dev, "EDID write verification failed\n");
		ret = -EIO;
		goto out_unlock;
	}

	ret = lt6911_power_cycle(lt);
	if (ret)
		goto out_unlock;

	mutex_unlock(&lt->chip_lock);
	kfree(wbuf);

	return count;

out_unlock:
	mutex_unlock(&lt->chip_lock);
out:
	kfree(wbuf);
	return ret;
}

/*
 * The snapshot is whatever the last chip read produced.
 *
 * Vendor bug: it snprintf()s "unknown\n" over the first nine bytes on every
 * read whenever the buffer is full-length -- that is, whenever the contents
 * are valid -- and then still returns 256 bytes, so the served image is
 * corrupt from the first read onwards. The real bytes are returned here. The
 * only consumer reads byte 12 to identify the loaded EDID, so this is
 * strictly a repair.
 */
static ssize_t lt6911_edid_snapshot_read(struct file *file, char __user *ubuf,
					 size_t count, loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	u8 snapshot[LT6911_EDID_SIZE];
	size_t len;

	mutex_lock(&lt->buf_lock);
	len = lt->edid_snapshot_len;
	memcpy(snapshot, lt->edid_snapshot, len);
	mutex_unlock(&lt->buf_lock);

	return simple_read_from_buffer(ubuf, count, ppos, snapshot, len);
}

static ssize_t lt6911_version_proc_read(struct file *file, char __user *ubuf,
					size_t count, loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	char snapshot[sizeof(lt->version)];
	size_t len;

	mutex_lock(&lt->buf_lock);
	strscpy(snapshot, lt->version, sizeof(snapshot));
	mutex_unlock(&lt->buf_lock);

	if (!snapshot[0])
		strscpy(snapshot, "unknown\n", sizeof(snapshot));
	len = strlen(snapshot);

	return simple_read_from_buffer(ubuf, count, ppos, snapshot, len);
}

static ssize_t lt6911_version_proc_write(struct file *file,
					 const char __user *ubuf, size_t count,
					 loff_t *ppos)
{
	struct lt6911 *lt = pde_data(file_inode(file));
	char readback[LT6911_VERSION_SIZE + 1];
	u8 *wbuf;
	int ret;

	/* Same VLA fix as the EDID writer, same reason. */
	if (!count || count > LT6911_VERSION_SIZE)
		return -EINVAL;

	wbuf = kzalloc(LT6911_VERSION_SIZE, GFP_KERNEL);
	if (!wbuf)
		return -ENOMEM;

	if (copy_from_user(wbuf, ubuf, count)) {
		ret = -EFAULT;
		goto out;
	}

	mutex_lock(&lt->chip_lock);

	ret = lt6911_set_power(lt, true);
	if (ret)
		goto out_unlock;

	ret = lt6911_version_write(lt, wbuf, count);
	if (ret)
		goto out_unlock;

	ret = lt6911_version_read(lt, readback);
	if (ret)
		goto out_unlock;

	mutex_lock(&lt->buf_lock);
	memcpy(lt->version, readback, sizeof(lt->version));
	mutex_unlock(&lt->buf_lock);

	if (memcmp(wbuf, readback, count)) {
		dev_err(lt->dev, "version write verification failed\n");
		ret = -EIO;
		goto out_unlock;
	}

	ret = lt6911_power_cycle(lt);
	if (ret)
		goto out_unlock;

	mutex_unlock(&lt->chip_lock);
	kfree(wbuf);

	return count;

out_unlock:
	mutex_unlock(&lt->chip_lock);
out:
	kfree(wbuf);
	return ret;
}

/* --- /proc: tables ------------------------------------------------------- */

/*
 * .proc_lseek is mandatory for anything served by simple_read_from_buffer():
 * without it procfs refuses to seek and a second read cannot resume where the
 * first stopped, which breaks any reader that does not consume the file in
 * one call.
 */
static const struct proc_ops lt6911_chip_id_ops = {
	.proc_read = lt6911_chip_id_read,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_power_ops = {
	.proc_read = lt6911_power_read,
	.proc_write = lt6911_power_write,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_hdmi_power_ops = {
	.proc_read = lt6911_hdmi_power_read,
	.proc_write = lt6911_hdmi_power_write,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_loopout_power_ops = {
	.proc_read = lt6911_loopout_power_read,
	.proc_write = lt6911_loopout_power_write,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_status_ops = {
	.proc_open = lt6911_poll_open,
	.proc_release = lt6911_poll_release,
	.proc_read = lt6911_status_read,
	.proc_write = lt6911_status_write,
	.proc_poll = lt6911_status_poll,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_width_ops = {
	.proc_read = lt6911_width_read,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_height_ops = {
	.proc_read = lt6911_height_read,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_fps_ops = {
	.proc_read = lt6911_fps_read,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_hdcp_ops = {
	.proc_read = lt6911_hdcp_read,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_asr_ops = {
	.proc_read = lt6911_asr_read,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_rx_status_ops = {
	.proc_open = lt6911_poll_open,
	.proc_release = lt6911_poll_release,
	.proc_read = lt6911_rx_status_read,
	.proc_poll = lt6911_rx_status_poll,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_tx_status_ops = {
	.proc_open = lt6911_poll_open,
	.proc_release = lt6911_poll_release,
	.proc_read = lt6911_tx_status_read,
	.proc_write = lt6911_tx_status_write,
	.proc_poll = lt6911_tx_status_poll,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_edid_ops = {
	.proc_read = lt6911_edid_proc_read,
	.proc_write = lt6911_edid_proc_write,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_edid_snapshot_ops = {
	.proc_read = lt6911_edid_snapshot_read,
	.proc_lseek = default_llseek,
};

static const struct proc_ops lt6911_version_ops = {
	.proc_read = lt6911_version_proc_read,
	.proc_write = lt6911_version_proc_write,
	.proc_lseek = default_llseek,
};

static const struct {
	const char *name;
	umode_t mode;
	const struct proc_ops *ops;
} lt6911_proc_files[] = {
	{ "chip_id",		0444, &lt6911_chip_id_ops },
	{ "power",		0666, &lt6911_power_ops },
	{ "hdmi_power",		0666, &lt6911_hdmi_power_ops },
	{ "loopout_power",	0666, &lt6911_loopout_power_ops },
	{ "status",		0666, &lt6911_status_ops },
	{ "width",		0444, &lt6911_width_ops },
	{ "height",		0444, &lt6911_height_ops },
	{ "fps",		0444, &lt6911_fps_ops },
	{ "hdcp",		0444, &lt6911_hdcp_ops },
	{ "asr",		0444, &lt6911_asr_ops },
	{ "hdmi_rx_status",	0444, &lt6911_rx_status_ops },
	{ "hdmi_tx_status",	0666, &lt6911_tx_status_ops },
	{ "edid",		0666, &lt6911_edid_ops },
	{ "edid_snapshot",	0444, &lt6911_edid_snapshot_ops },
	{ "version",		0666, &lt6911_version_ops },
};

static int lt6911_proc_init(struct lt6911 *lt)
{
	unsigned int i;

	lt->proc_dir = proc_mkdir("lt6911_info", NULL);
	if (!lt->proc_dir)
		return -ENOMEM;

	for (i = 0; i < ARRAY_SIZE(lt6911_proc_files); i++) {
		if (!proc_create_data(lt6911_proc_files[i].name,
				      lt6911_proc_files[i].mode,
				      lt->proc_dir,
				      lt6911_proc_files[i].ops, lt)) {
			proc_remove(lt->proc_dir);
			lt->proc_dir = NULL;
			return -ENOMEM;
		}
	}

	return 0;
}

static void lt6911_proc_exit(struct lt6911 *lt)
{
	if (!lt->proc_dir)
		return;

	/*
	 * One call takes the directory and everything under it, and procfs
	 * waits for in-flight handlers on the way out.
	 */
	proc_remove(lt->proc_dir);
	lt->proc_dir = NULL;
}

/* --- probe --------------------------------------------------------------- */

static void lt6911_init_text(struct lt6911 *lt)
{
	mutex_lock(&lt->buf_lock);
	lt6911_set_text(&lt->status, "disappear\n");
	lt6911_set_text(&lt->width, "%d\n", 0);
	lt6911_set_text(&lt->height, "%d\n", 0);
	lt6911_set_text(&lt->fps, "%d\n", 0);
	lt6911_set_text(&lt->hdcp, "no hdcp\n");
	lt6911_set_text(&lt->asr, "disappear\n");
	mutex_unlock(&lt->buf_lock);
}

static int lt6911_get_gpios(struct lt6911 *lt)
{
	struct device *dev = lt->dev;

	/*
	 * The vendor drives seven hardcoded global GPIO numbers and then
	 * ioremap()s four pad-mux register blocks to program the pins itself,
	 * because its GPIO driver stubs .request and never reaches pinctrl.
	 * Nothing here needs to: gpiod_get() runs the pin controller's
	 * gpio_request_enable() for each line, which programs the mux from
	 * the gpio-ranges in DT. That is why there is no ioremap in this
	 * file, and there must not be one.
	 */
	lt->int_gpio = devm_gpiod_get(dev, "interrupt", GPIOD_IN);
	if (IS_ERR(lt->int_gpio))
		return dev_err_probe(dev, PTR_ERR(lt->int_gpio),
				     "no interrupt GPIO\n");

	lt->pwr_gpio = devm_gpiod_get(dev, "power", GPIOD_OUT_LOW);
	if (IS_ERR(lt->pwr_gpio))
		return dev_err_probe(dev, PTR_ERR(lt->pwr_gpio),
				     "no power GPIO\n");

	lt->hdmi_pwr_gpio = devm_gpiod_get(dev, "hdmi-power", GPIOD_OUT_LOW);
	if (IS_ERR(lt->hdmi_pwr_gpio))
		return dev_err_probe(dev, PTR_ERR(lt->hdmi_pwr_gpio),
				     "no hdmi-power GPIO\n");

	lt->loopout_gpios = devm_gpiod_get_array(dev, "loopout",
						 GPIOD_OUT_LOW);
	if (IS_ERR(lt->loopout_gpios))
		return dev_err_probe(dev, PTR_ERR(lt->loopout_gpios),
				     "no loopout GPIOs\n");

	lt->rx_det_gpio = devm_gpiod_get(dev, "hdmi-rx-detect", GPIOD_IN);
	if (IS_ERR(lt->rx_det_gpio))
		return dev_err_probe(dev, PTR_ERR(lt->rx_det_gpio),
				     "no hdmi-rx-detect GPIO\n");

	lt->tx_det_gpio = devm_gpiod_get(dev, "hdmi-tx-detect", GPIOD_IN);
	if (IS_ERR(lt->tx_det_gpio))
		return dev_err_probe(dev, PTR_ERR(lt->tx_det_gpio),
				     "no hdmi-tx-detect GPIO\n");

	return 0;
}

static int lt6911_request_irqs(struct lt6911 *lt)
{
	struct device *dev = lt->dev;
	int ret;

	/*
	 * Both edges on all three lines. The handlers read the pin rather
	 * than trusting the edge, so a missed or coalesced transition
	 * resynchronises on the next one.
	 *
	 * These are deliberately not devm_: devm frees IRQs after remove()
	 * returns, which would leave a window where a late interrupt requeues
	 * work that remove() has already cancelled.
	 */
	lt->int_irq = gpiod_to_irq(lt->int_gpio);
	if (lt->int_irq < 0)
		return dev_err_probe(dev, lt->int_irq,
				     "interrupt GPIO has no IRQ\n");

	ret = request_threaded_irq(lt->int_irq, NULL, lt6911_int_thread,
				   IRQF_TRIGGER_RISING |
				   IRQF_TRIGGER_FALLING | IRQF_ONESHOT,
				   "lt6911-int", lt);
	if (ret)
		return dev_err_probe(dev, ret, "cannot request IRQ\n");

	lt->rx_irq = gpiod_to_irq(lt->rx_det_gpio);
	if (lt->rx_irq < 0) {
		ret = dev_err_probe(dev, lt->rx_irq,
				    "hdmi-rx-detect has no IRQ\n");
		goto err_int;
	}

	ret = request_irq(lt->rx_irq, lt6911_detect_irq,
			  IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING,
			  "lt6911-rx-detect", lt);
	if (ret) {
		dev_err_probe(dev, ret, "cannot request rx-detect IRQ\n");
		goto err_int;
	}

	lt->tx_irq = gpiod_to_irq(lt->tx_det_gpio);
	if (lt->tx_irq < 0) {
		ret = dev_err_probe(dev, lt->tx_irq,
				    "hdmi-tx-detect has no IRQ\n");
		goto err_rx;
	}

	ret = request_irq(lt->tx_irq, lt6911_detect_irq,
			  IRQF_TRIGGER_RISING | IRQF_TRIGGER_FALLING,
			  "lt6911-tx-detect", lt);
	if (ret) {
		dev_err_probe(dev, ret, "cannot request tx-detect IRQ\n");
		goto err_rx;
	}

	return 0;

err_rx:
	free_irq(lt->rx_irq, lt);
err_int:
	free_irq(lt->int_irq, lt);
	return ret;
}

static void lt6911_free_irqs(struct lt6911 *lt)
{
	free_irq(lt->tx_irq, lt);
	free_irq(lt->rx_irq, lt);
	free_irq(lt->int_irq, lt);
}

static int lt6911_probe(struct i2c_client *client)
{
	struct device *dev = &client->dev;
	struct lt6911 *lt;
	int ret;

	if (!i2c_check_functionality(client->adapter,
				     I2C_FUNC_SMBUS_BYTE_DATA |
				     I2C_FUNC_SMBUS_I2C_BLOCK))
		return dev_err_probe(dev, -EOPNOTSUPP,
				     "adapter lacks SMBus byte and block\n");

	lt = devm_kzalloc(dev, sizeof(*lt), GFP_KERNEL);
	if (!lt)
		return -ENOMEM;

	lt->client = client;
	lt->dev = dev;
	lt->last_width = 0xffff;
	lt->last_height = 0xffff;
	mutex_init(&lt->chip_lock);
	mutex_init(&lt->buf_lock);
	init_waitqueue_head(&lt->wq);
	atomic_set(&lt->status_gen, 0);
	atomic_set(&lt->rx_gen, 0);
	atomic_set(&lt->tx_gen, 0);
	i2c_set_clientdata(client, lt);

	ret = lt6911_get_gpios(lt);
	if (ret)
		return ret;

	/*
	 * Work items before interrupts, always: the vendor requests its
	 * interrupt inside gpio_init() and only calls INIT_WORK() on the info
	 * work near the end of module init, so an interrupt arriving in
	 * between schedules a work_struct that has never been initialised.
	 */
	INIT_WORK(&lt->info_work, lt6911_info_work_fn);
	INIT_DELAYED_WORK(&lt->detect_work, lt6911_detect_work_fn);

	lt6911_init_text(lt);

	ret = lt6911_set_hdmi_power(lt, true);
	if (ret)
		return ret;
	ret = lt6911_set_power(lt, true);
	if (ret)
		goto err_power;

	/* Loop-out defaults on, as it does on the vendor image. */
	ret = lt6911_set_loopout(lt, true);
	if (ret)
		goto err_power;

	/*
	 * The vendor reads the chip ID immediately after raising the rail.
	 * Give the bridge the same 100 ms it gives it everywhere else before
	 * expecting it to answer.
	 */
	msleep(100);

	mutex_lock(&lt->chip_lock);
	ret = lt6911_check_chip_id(lt);
	mutex_unlock(&lt->chip_lock);
	if (ret)
		goto err_power;

	lt6911_update_detect(lt);

	/*
	 * Publish the instance for the module parameters now: the work items
	 * exist and the chip has answered, so a parameter write from here on
	 * is safe, and doing it before the interrupts means nothing can
	 * arrive that finds a half-built driver.
	 */
	mutex_lock(&lt6911_instance_lock);
	if (lt6911_instance) {
		mutex_unlock(&lt6911_instance_lock);
		dev_err(dev, "a second LT6911UXC cannot share /proc\n");
		ret = -EBUSY;
		goto err_power;
	}
	lt6911_instance = lt;
	mutex_unlock(&lt6911_instance_lock);

	ret = lt6911_request_irqs(lt);
	if (ret)
		goto err_power;

	/*
	 * Seed the version string and the EDID snapshot before the files that
	 * serve them exist, so nothing can read a half-filled buffer.
	 *
	 * A failure here is not fatal: the bridge has already answered its
	 * ID, so I2C works, and /proc/lt6911_info/edid is the only way to
	 * reprogram a chip whose flash sequence is stumbling. The vendor
	 * fails module init instead -- and leaks every GPIO, IRQ and proc
	 * entry doing it.
	 */
	mutex_lock(&lt->chip_lock);
	ret = lt6911_version_read(lt, lt->version);
	if (ret) {
		dev_warn(dev, "cannot read version string: %d\n", ret);
		lt->version[0] = '\0';
	}

	ret = lt6911_edid_read(lt, lt->edid_snapshot);
	if (ret)
		dev_warn(dev, "cannot read EDID: %d\n", ret);
	else
		lt->edid_snapshot_len = LT6911_EDID_SIZE;
	mutex_unlock(&lt->chip_lock);

	ret = lt6911_proc_init(lt);
	if (ret) {
		dev_err(dev, "cannot create /proc/lt6911_info\n");
		goto err_irq;
	}

	/*
	 * Power-cycle both rails to finish. This is not tidying: it is what
	 * makes the bridge assert its interrupt for whatever is already
	 * plugged in, and therefore what populates the info files without
	 * waiting for the host to change mode. The vendor's changelog calls
	 * it "0.0.11 - fix no HDMI input issue when insmod".
	 *
	 * Note the order reverses between down and up -- splitter last off,
	 * bridge first on -- exactly as the vendor sequences it.
	 */
	ret = lt6911_set_hdmi_power(lt, false);
	if (ret)
		goto err_proc;
	ret = lt6911_set_power(lt, false);
	if (ret)
		goto err_proc;
	msleep(100);
	ret = lt6911_set_power(lt, true);
	if (ret)
		goto err_proc;
	msleep(100);
	ret = lt6911_set_hdmi_power(lt, true);
	if (ret)
		goto err_proc;

	dev_info(dev, "ready\n");

	return 0;

err_proc:
	lt6911_proc_exit(lt);
err_irq:
	lt6911_free_irqs(lt);
	cancel_work_sync(&lt->info_work);
	cancel_delayed_work_sync(&lt->detect_work);
err_power:
	mutex_lock(&lt6911_instance_lock);
	if (lt6911_instance == lt)
		lt6911_instance = NULL;
	mutex_unlock(&lt6911_instance_lock);
	lt6911_set_power(lt, false);
	lt6911_set_hdmi_power(lt, false);
	return ret;
}

static void lt6911_remove(struct i2c_client *client)
{
	struct lt6911 *lt = i2c_get_clientdata(client);

	mutex_lock(&lt6911_instance_lock);
	if (lt6911_instance == lt)
		lt6911_instance = NULL;
	mutex_unlock(&lt6911_instance_lock);

	/*
	 * Interrupts first, then the work they queue, then the files that can
	 * reach the chip. Any other order leaves something able to run after
	 * the thing it touches is gone.
	 */
	lt6911_free_irqs(lt);
	cancel_work_sync(&lt->info_work);
	cancel_delayed_work_sync(&lt->detect_work);
	lt6911_proc_exit(lt);

	/*
	 * The rails are left as they are. Unbinding this driver should not
	 * blank a host that is being captured through the splitter, and probe
	 * raises both again.
	 */
}

static const struct of_device_id lt6911_of_match[] = {
	{ .compatible = "lontium,lt6911uxc" },
	{ }
};
MODULE_DEVICE_TABLE(of, lt6911_of_match);

static const struct i2c_device_id lt6911_i2c_id[] = {
	{ "lt6911uxc" },
	{ }
};
MODULE_DEVICE_TABLE(i2c, lt6911_i2c_id);

static struct i2c_driver lt6911_driver = {
	.probe = lt6911_probe,
	.remove = lt6911_remove,
	.id_table = lt6911_i2c_id,
	.driver = {
		.name = "lt6911-manage",
		.of_match_table = lt6911_of_match,
	},
};
module_i2c_driver(lt6911_driver);

MODULE_DESCRIPTION("Lontium LT6911UXC management for NanoKVM-Pro");
MODULE_LICENSE("GPL");
