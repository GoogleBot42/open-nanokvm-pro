/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Axera AX630C (AX620E family) clock controller -- shared types.
 *
 * Written from docs/reference/mainline/clk-model-20260906.md, a behavioural
 * specification derived from the vendor GPL sources and checked against a
 * live device. Issue #80.
 */

#ifndef _CLK_AX630C_H
#define _CLK_AX630C_H

#include <linux/clk-provider.h>
#include <linux/regmap.h>
#include <linux/types.h>

/*
 * Each controller exposes every writable control word three ways: a plain
 * read/write word and two aliases, write-1-to-set and write-1-to-clear. The
 * alias layout differs per controller, and for four of the nine it is simply
 * not known (dispc, mm, vpu, isp -- their registered offsets are a flat 4-byte
 * stride, so they cannot be using the +4/+8 triplet the others use).
 *
 * Where the aliases are known we use them: a write to an alias touches exactly
 * the bits we name, so it cannot race the direct pokes that firmware and the
 * reset driver still perform on the same words. Where they are not, we fall
 * back to regmap_update_bits(), which is at least serialised against every
 * other user of the same syscon regmap.
 *
 * has_alias == false means "RMW the value word".
 */
struct ax630c_alias {
	bool has_alias;
	u32 set_stride;	/* value_offset + set_stride = write-1-to-set alias */
	u32 clr_stride;	/* value_offset + clr_stride = write-1-to-clear alias */
};

enum ax630c_clk_type {
	AX630C_FIXED_RATE,
	AX630C_FIXED_FACTOR,
	AX630C_MUX,
	AX630C_DIV,
	AX630C_GATE,
	AX630C_PLL,
};

/*
 * One row per clock. The union keeps the 246-row tables readable; the
 * per-type initialisers below are what the tables actually use.
 */
struct ax630c_clk {
	u16 id;
	enum ax630c_clk_type type;
	const char *name;
	const char *parent;		/* NULL for roots and muxes */
	const char * const *parents;	/* muxes only */
	u8 num_parents;
	unsigned long flags;

	union {
		struct {
			unsigned long rate;
		} fixed_rate;
		struct {
			u8 div;
			u8 mult;
		} fixed_factor;
		struct {
			u32 offset;
			u8 shift;
			u8 width;
			/*
			 * Whether clk_set_rate() on this mux (or on a
			 * CLK_SET_RATE_PARENT descendant of it) may switch its
			 * parent. Off by default: most of these muxes select
			 * between clock domains that firmware fixed, and a
			 * consumer's rate request must not silently move one.
			 */
			bool reparent;
		} mux;
		struct {
			u32 offset;
			u8 shift;
			u8 width;
			u8 update_bit;
		} div;
		struct {
			u32 offset;
			u8 bit;
		} gate;
	};
};

/* Per-controller description, selected by of_device_id match data. */
struct ax630c_clk_desc {
	const struct ax630c_clk *clks;
	unsigned int num_clks;
	unsigned int max_id;
	struct ax630c_alias alias;
	/*
	 * periph does not use a single alias stride: each value word has its
	 * own set/clear pair. When present this overrides desc->alias and is
	 * indexed by the value-word offset.
	 */
	const struct ax630c_alias_map *alias_map;
	unsigned int num_alias_map;
};

struct ax630c_alias_map {
	u32 offset;	/* the value word */
	u32 set;
	u32 clr;
};

/* --- table helpers ------------------------------------------------------ */

#define AX630C_FIXED(_id, _name, _rate)					\
	{ .id = (_id), .type = AX630C_FIXED_RATE, .name = (_name),	\
	  .fixed_rate = { .rate = (_rate) } }

#define AX630C_FACTOR(_id, _name, _parent, _div)			\
	{ .id = (_id), .type = AX630C_FIXED_FACTOR, .name = (_name),	\
	  .parent = (_parent), .fixed_factor = { .div = (_div), .mult = 1 } }

#define AX630C_FACTOR_F(_id, _name, _parent, _div, _flags)		\
	{ .id = (_id), .type = AX630C_FIXED_FACTOR, .name = (_name),	\
	  .parent = (_parent), .flags = (_flags),			\
	  .fixed_factor = { .div = (_div), .mult = 1 } }

#define AX630C_MUX_C(_id, _name, _parents, _off, _shift, _width)	\
	{ .id = (_id), .type = AX630C_MUX, .name = (_name),		\
	  .parents = (_parents), .num_parents = ARRAY_SIZE(_parents),	\
	  .flags = CLK_SET_RATE_PARENT,					\
	  .mux = { .offset = (_off), .shift = (_shift), .width = (_width) } }

/*
 * A mux a consumer is allowed to re-point with clk_set_rate(). Deliberately
 * WITHOUT CLK_SET_RATE_PARENT: the choice this mux makes is between parents
 * that are themselves fixed, so the rate request stops here and turns into a
 * parent switch rather than propagating further up and changing a PLL.
 */
#define AX630C_MUX_RC(_id, _name, _parents, _off, _shift, _width)	\
	{ .id = (_id), .type = AX630C_MUX, .name = (_name),		\
	  .parents = (_parents), .num_parents = ARRAY_SIZE(_parents),	\
	  .mux = { .offset = (_off), .shift = (_shift),			\
		   .width = (_width), .reparent = true } }

#define AX630C_DIV_C(_id, _name, _parent, _off, _shift, _width, _upd)	\
	{ .id = (_id), .type = AX630C_DIV, .name = (_name),		\
	  .parent = (_parent), .flags = CLK_SET_RATE_PARENT,		\
	  .div = { .offset = (_off), .shift = (_shift),			\
		   .width = (_width), .update_bit = (_upd) } }

#define AX630C_GATE_C(_id, _name, _parent, _off, _bit, _flags)		\
	{ .id = (_id), .type = AX630C_GATE, .name = (_name),		\
	  .parent = (_parent), .flags = (_flags),			\
	  .gate = { .offset = (_off), .bit = (_bit) } }

#define AX630C_PLL_C(_id, _name, _parent)				\
	{ .id = (_id), .type = AX630C_PLL, .name = (_name),		\
	  .parent = (_parent) }

/* Per-controller tables (clk-ax630c-tables.c). */
extern const struct ax630c_clk_desc ax630c_pllc_desc;
extern const struct ax630c_clk_desc ax630c_cpu_desc;
extern const struct ax630c_clk_desc ax630c_common_desc;
extern const struct ax630c_clk_desc ax630c_dispc_desc;
extern const struct ax630c_clk_desc ax630c_flash_desc;
extern const struct ax630c_clk_desc ax630c_mm_desc;
extern const struct ax630c_clk_desc ax630c_periph_desc;
extern const struct ax630c_clk_desc ax630c_vpu_desc;

#endif /* _CLK_AX630C_H */
