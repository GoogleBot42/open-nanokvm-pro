/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Axera AX630C (AX620E family) pin controller -- shared types.
 *
 * Written from docs/reference/mainline/pinctrl-model-20260906.md, a
 * behavioural specification derived from the vendor GPL sources and checked
 * against a live device. Issue #80.
 */

#ifndef _PINCTRL_AX630C_H
#define _PINCTRL_AX630C_H

#include <linux/pinctrl/pinctrl.h>
#include <linux/types.h>

#define AX630C_NUM_PADS		111
#define AX630C_MUX_VALUES	8

/* Pad VALUE word. There is no direction, input-enable or slew-rate bit. */
#define AX630C_FUNC_MASK	GENMASK(18, 16)
#define AX630C_FUNC_SHIFT	16
#define AX630C_PULL_MASK	GENMASK(7, 6)
#define AX630C_SCHMITT_BIT	BIT(4)
#define AX630C_DRIVE_MASK	GENMASK(3, 0)

/*
 * Two pull encodings coexist. Most pads are one-hot (bit 7 = up, bit 6 =
 * down); the analog-capable groups G2, G5 and G7 instead use bit 6 as a pull
 * enable and bit 7 as the direction select. Both agree on pull-down (0x40) and
 * on disabled (0x00), and differ only for pull-up.
 *
 * The vendor picks the encoding by comparing the pad's numeric offset against
 * two ranges. That is carried here as a per-pad flag instead.
 */
enum ax630c_pull_enc {
	AX630C_PULL_ONEHOT = 0,	/* bit7 = up, bit6 = down */
	AX630C_PULL_ENSEL,	/* bit6 = enable, bit7 = 1 means up */
};

#define AX630C_PULL_UP_ONEHOT	BIT(7)
#define AX630C_PULL_UP_ENSEL	(BIT(7) | BIT(6))
#define AX630C_PULL_DOWN	BIT(6)

/* A pad's mux slot that carries no function. Writing it is undefined. */
#define AX630C_MUX_RESERVED	((s16)-1)
/* A pad with no GPIO function at all -- 14 of them. */
#define AX630C_NO_GPIO		((s8)-1)

/**
 * struct ax630c_pad - everything the driver needs to know about one pad
 * @window:	which of the two register windows holds it (0 or 1)
 * @offset:	byte offset of the VALUE word within that window
 * @gpio_mux:	mux value that selects GPIO, or AX630C_NO_GPIO
 * @pull_enc:	which of the two pull encodings this pad uses
 * @dphytx:	true for the DPHY-TX pads, which need a reset/enable sequence
 *		around any move to a non-zero function
 * @mux:	function index per mux value, AX630C_MUX_RESERVED where the
 *		slot is not populated (337 of the 888 slots are not)
 */
struct ax630c_pad {
	u8 window;
	u32 offset;
	s8 gpio_mux;
	u8 pull_enc;
	bool dphytx;
	s16 mux[AX630C_MUX_VALUES];
};

/**
 * struct ax630c_group - a named set of pads that move together
 *
 * Both the 56 real multi-pad groups and the 111 single-pad groups (which GPIO
 * consumers and hogs need) are described this way.
 */
struct ax630c_group {
	const char *name;
	const unsigned int *pins;
	unsigned int num_pins;
};

/* Tables (pinctrl-ax630c-pins.c). */
extern const struct pinctrl_pin_desc ax630c_pin_descs[AX630C_NUM_PADS];
extern const struct ax630c_pad ax630c_pads[AX630C_NUM_PADS];
extern const struct ax630c_group ax630c_groups[];
extern const unsigned int ax630c_num_groups;
extern const struct pinfunction ax630c_functions[];
extern const unsigned int ax630c_num_functions;

#endif /* _PINCTRL_AX630C_H */
