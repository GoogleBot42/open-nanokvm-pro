// SPDX-License-Identifier: GPL-3.0-only
/*
 * nanokvm-gpio -- drive the NanoKVM-Pro's ATX lines by device-tree name.
 *
 * WHY THIS EXISTS (issue #81, the mainline port)
 *
 * The shipped 4.19 stack pokes /sys/class/gpio: a boot-time unit exports
 * global numbers 7/35/74/75 and the Go server writes gpio7/value to press
 * power. Two things make that unusable on mainline.
 *
 *   1. Global GPIO numbers are not stable. They are handed out as gpiochips
 *      probe, so a driver-order change renumbers every line. The device tree
 *      names them instead (`gpio-line-names` in dts/ax630c-nanokvm-pro.dts:
 *      atx-power, atx-reset, atx-power-led, atx-hdd-led), and a name is a
 *      board fact that cannot drift. This tool only ever resolves by name --
 *      it walks every /dev/gpiochip* and asks each one for the offset.
 *
 *   2. Requesting the line is what programs the pad mux. SW_PWR is GPIO0_A7
 *      on pad VI_D7, which is also a capture data pad; the vendor's GPIO
 *      driver stubbed ->request, so nothing muxed the pad and the sysfs
 *      `value` file echoed a latch that reached no ball. That is the SW_PWR
 *      trap (docs/mini-display.md), and it is why the 4.19 image needs a
 *      `devmem 0x02300060 32 0x00060003` poke at boot AND a per-press pinmux
 *      re-assert inside the server. On mainline the pin controller sees the
 *      request through gpio-ranges -> gpio_request_enable, so the mux is
 *      programmed here, at request time, and strict mode stops a peripheral
 *      state stealing the pad while the line is held. Both vendor-era
 *      workarounds are deleted, not ported.
 *
 * POLARITY IS DECLARED, NOT CODED. atx-power-led is GPIO_ACTIVE_LOW in the
 * DT because the board pulls it low when the host is on. libgpiod returns
 * LOGICAL values, so `get atx-power-led` prints 1 for "host is on" with no
 * inversion anywhere in this file. Callers must not invert again.
 *
 * Built against libgpiod v2 (nixpkgs ships 2.2.4). The v2 API is the
 * request-object one: settings -> line config -> chip_request_lines.
 */

#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <gpiod.h>

#define CONSUMER "nanokvm-gpio"

/*
 * A press is a human-scale event; the server's default is 800 ms and a
 * force-off hold is ~5 s. Anything past a minute is a caller bug -- the Go
 * side takes the duration straight off the HTTP request and never bounded it
 * -- and holding a line that long from a one-shot process is worse than
 * refusing.
 */
#define MAX_PULSE_MS 60000

static void usage(void)
{
	fprintf(stderr,
		"usage: " CONSUMER " pulse <line-name> <milliseconds>\n"
		"       " CONSUMER " get   <line-name>\n"
		"       " CONSUMER " set   <line-name> <0|1>\n"
		"\n"
		"Lines are resolved by their device-tree gpio-line-names entry,\n"
		"never by number. Values are logical: DT active-low lines are\n"
		"already inverted by the kernel.\n");
}

/*
 * Find the chip carrying <name> and return it open, with *offset set.
 * Caller closes. NULL means no gpiochip on this system names that line.
 */
static struct gpiod_chip *find_line(const char *name, unsigned int *offset)
{
	struct dirent *ent;
	DIR *dir;

	dir = opendir("/dev");
	if (!dir) {
		fprintf(stderr, CONSUMER ": opendir /dev: %s\n", strerror(errno));
		return NULL;
	}

	while ((ent = readdir(dir)) != NULL) {
		char path[PATH_MAX];
		struct gpiod_chip *chip;
		int off;

		if (strncmp(ent->d_name, "gpiochip", 8) != 0)
			continue;

		snprintf(path, sizeof(path), "/dev/%s", ent->d_name);
		if (!gpiod_is_gpiochip_device(path))
			continue;

		chip = gpiod_chip_open(path);
		if (!chip)
			continue;	/* unreadable: not our line to claim */

		off = gpiod_chip_get_line_offset_from_name(chip, name);
		if (off >= 0) {
			*offset = (unsigned int)off;
			closedir(dir);
			return chip;
		}

		gpiod_chip_close(chip);
	}

	closedir(dir);
	return NULL;
}

/*
 * Request one line. For outputs `initial` is driven as part of the request
 * itself -- there is no window where the line sits high before we mean it,
 * which matters on a power button.
 */
static struct gpiod_line_request *request_line(struct gpiod_chip *chip,
					       unsigned int offset,
					       enum gpiod_line_direction dir,
					       enum gpiod_line_value initial)
{
	struct gpiod_request_config *rcfg = NULL;
	struct gpiod_line_settings *settings;
	struct gpiod_line_config *lcfg = NULL;
	struct gpiod_line_request *req = NULL;

	settings = gpiod_line_settings_new();
	if (!settings)
		goto out;

	if (gpiod_line_settings_set_direction(settings, dir))
		goto out;
	if (dir == GPIOD_LINE_DIRECTION_OUTPUT &&
	    gpiod_line_settings_set_output_value(settings, initial))
		goto out;

	lcfg = gpiod_line_config_new();
	if (!lcfg)
		goto out;
	if (gpiod_line_config_add_line_settings(lcfg, &offset, 1, settings))
		goto out;

	rcfg = gpiod_request_config_new();
	if (!rcfg)
		goto out;
	gpiod_request_config_set_consumer(rcfg, CONSUMER);

	req = gpiod_chip_request_lines(chip, rcfg, lcfg);

out:
	if (rcfg)
		gpiod_request_config_free(rcfg);
	if (lcfg)
		gpiod_line_config_free(lcfg);
	if (settings)
		gpiod_line_settings_free(settings);
	return req;
}

static int parse_uint(const char *s, long max, long *out)
{
	char *end;
	long v;

	errno = 0;
	v = strtol(s, &end, 10);
	if (errno != 0 || end == s || *end != '\0' || v < 0 || v > max)
		return -1;

	*out = v;
	return 0;
}

static void sleep_ms(long ms)
{
	struct timespec ts = {
		.tv_sec = ms / 1000,
		.tv_nsec = (ms % 1000) * 1000000L,
	};

	while (nanosleep(&ts, &ts) == -1 && errno == EINTR)
		;
}

static int cmd_pulse(const char *name, const char *ms_arg)
{
	struct gpiod_line_request *req;
	struct gpiod_chip *chip;
	unsigned int offset;
	int ret = 1;
	long ms;

	if (parse_uint(ms_arg, MAX_PULSE_MS, &ms) || ms == 0) {
		fprintf(stderr, CONSUMER ": bad duration '%s' (want 1..%d ms)\n",
			ms_arg, MAX_PULSE_MS);
		return 1;
	}

	chip = find_line(name, &offset);
	if (!chip) {
		fprintf(stderr, CONSUMER ": no gpiochip names line '%s'\n", name);
		return 1;
	}

	/* Start low: the request drives 0, so the press begins where we say. */
	req = request_line(chip, offset, GPIOD_LINE_DIRECTION_OUTPUT,
			   GPIOD_LINE_VALUE_INACTIVE);
	if (!req) {
		fprintf(stderr, CONSUMER ": request '%s' failed: %s\n",
			name, strerror(errno));
		goto out_chip;
	}

	if (gpiod_line_request_set_value(req, offset, GPIOD_LINE_VALUE_ACTIVE)) {
		fprintf(stderr, CONSUMER ": assert '%s' failed: %s\n",
			name, strerror(errno));
		goto out_req;
	}

	sleep_ms(ms);

	/*
	 * Releasing the request also drops the line, but say so explicitly and
	 * report a failure: a stuck-high power button is the one outcome here
	 * worth shouting about.
	 */
	if (gpiod_line_request_set_value(req, offset, GPIOD_LINE_VALUE_INACTIVE)) {
		fprintf(stderr, CONSUMER ": deassert '%s' failed: %s\n",
			name, strerror(errno));
		goto out_req;
	}

	ret = 0;

out_req:
	gpiod_line_request_release(req);
out_chip:
	gpiod_chip_close(chip);
	return ret;
}

static int cmd_get(const char *name)
{
	struct gpiod_line_request *req;
	struct gpiod_chip *chip;
	enum gpiod_line_value value;
	unsigned int offset;
	int ret = 1;

	chip = find_line(name, &offset);
	if (!chip) {
		fprintf(stderr, CONSUMER ": no gpiochip names line '%s'\n", name);
		return 1;
	}

	req = request_line(chip, offset, GPIOD_LINE_DIRECTION_INPUT,
			   GPIOD_LINE_VALUE_INACTIVE);
	if (!req) {
		fprintf(stderr, CONSUMER ": request '%s' failed: %s\n",
			name, strerror(errno));
		goto out_chip;
	}

	value = gpiod_line_request_get_value(req, offset);
	if (value == GPIOD_LINE_VALUE_ERROR) {
		fprintf(stderr, CONSUMER ": read '%s' failed: %s\n",
			name, strerror(errno));
		goto out_req;
	}

	/* Logical value: the DT's active-low flag is already applied. */
	printf("%d\n", value == GPIOD_LINE_VALUE_ACTIVE ? 1 : 0);
	ret = 0;

out_req:
	gpiod_line_request_release(req);
out_chip:
	gpiod_chip_close(chip);
	return ret;
}

/*
 * `set` requests the line as an output at <value> and releases it immediately.
 *
 * The output latch survives the release -- the kernel does not drive the line
 * back on free -- but NOTHING HOLDS THE PAD afterwards: the mux was programmed
 * by the request, and once the line is free the next consumer of that pad may
 * take it. So this is a bench tool for poking a line and watching a meter, not
 * a way to hold a level. The ATX path uses `pulse`, which owns the line for
 * the whole press.
 */
static int cmd_set(const char *name, const char *value_arg)
{
	struct gpiod_line_request *req;
	struct gpiod_chip *chip;
	unsigned int offset;
	long value;

	if (parse_uint(value_arg, 1, &value)) {
		fprintf(stderr, CONSUMER ": bad value '%s' (want 0 or 1)\n",
			value_arg);
		return 1;
	}

	chip = find_line(name, &offset);
	if (!chip) {
		fprintf(stderr, CONSUMER ": no gpiochip names line '%s'\n", name);
		return 1;
	}

	req = request_line(chip, offset, GPIOD_LINE_DIRECTION_OUTPUT,
			   value ? GPIOD_LINE_VALUE_ACTIVE
				 : GPIOD_LINE_VALUE_INACTIVE);
	if (!req) {
		fprintf(stderr, CONSUMER ": request '%s' failed: %s\n",
			name, strerror(errno));
		gpiod_chip_close(chip);
		return 1;
	}

	gpiod_line_request_release(req);
	gpiod_chip_close(chip);
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		usage();
		return 1;
	}

	if (strcmp(argv[1], "pulse") == 0 && argc == 4)
		return cmd_pulse(argv[2], argv[3]);
	if (strcmp(argv[1], "get") == 0 && argc == 3)
		return cmd_get(argv[2]);
	if (strcmp(argv[1], "set") == 0 && argc == 4)
		return cmd_set(argv[2], argv[3]);

	usage();
	return 1;
}
