// SPDX-License-Identifier: GPL-2.0
/*
 * Axera AX630C (AX620E family) clock controller -- per-controller tables.
 *
 * Transcribed row for row from docs/reference/mainline/clk-model-20260906.md,
 * a behavioural specification derived from the vendor GPL sources and
 * reconciled clock by clock against a running device. Issue #80. Section
 * numbers in the comments below refer to that document.
 *
 * 246 clocks over eight controllers: 1 PLL, 9 fixed-rate, 80 fixed-factor,
 * 50 muxes, 20 dividers, 86 gates.
 *
 * Two deliberate departures from the vendor table, both argued in section 6 of
 * the specification:
 *
 *  - CLK_IGNORE_UNUSED is dropped everywhere. The vendor sets it on 62 of the
 *    86 gates and on every mux and divider, which is a workaround for having
 *    no consumer bindings rather than a description of the hardware. Nothing
 *    on this SoC is marked CLK_IS_CRITICAL either, in the vendor table or
 *    here; a clock that genuinely must keep running should be marked as such
 *    once it is identified, not blanket-exempted from clk_disable_unused().
 *
 *  - The parent arrays the vendor duplicates (TOP6 twelve times, VPU6 three,
 *    MCLK13 six) are defined once and shared. The members were byte-identical
 *    in every copy.
 *
 * CLK_SET_RATE_PARENT is carried through exactly as specified: every mux,
 * divider and gate has it (it is baked into AX630C_MUX_C / AX630C_DIV_C), and
 * no fixed-rate or fixed-factor clock has it except the six cpupll_* taps.
 *
 * Copyright (c) 2026 the open-nanokvm-pro contributors.
 */

#include <dt-bindings/clock/ax630c-clock.h>

#include "clk-ax630c.h"

/* --- shared parent tables (spec 2.9) ------------------------------------ */

static const char * const ax630c_top6_parents[] = {
	"cpll_24m", "cpll_208m", "cpll_312m", "cpll_416m", "epll_500m",
	"npll_533m",
};

static const char * const ax630c_vpu6_parents[] = {
	"cpll_208m", "cpll_312m", "epll_375m", "cpll_416m", "epll_500m",
	"npll_533m",
};

static const char * const ax630c_vo0_parents[] = {
	"vpll0_108m", "vpll0_118p8m", "vpll0_198m", "vpll0_297m",
};

static const char * const ax630c_vo1_parents[] = {
	"vpll1_108m", "vpll1_118p8m", "vpll1_198m", "vpll1_297m",
};

/*
 * Index 1 is named cpll_19p2m in the vendor tree but is really a /5 of
 * cpll_249p6m, i.e. 49.92 MHz -- see the AX630C_CPLL_19P2M row below.
 */
static const char * const ax630c_mclk13_parents[] = {
	"cpll_12m", "cpll_49p92m", "hpll_20p48m", "cpll_24m", "hpll_24p576m",
	"epll_25m", "cpll_26m", "vpll0_27m", "vpll1_27m", "epll_50m",
	"vpll0_74p25m", "vpll1_74p25m", "epll_125m",
};

/* --- pllc_clk, 0x0221_0000 (spec 2.1, 3) -------------------------------- */

static const struct ax630c_clk ax630c_pllc_clks[] = {
	/*
	 * The only runtime-programmable PLL, and the driver keeps it
	 * read-only. The vendor pins its CCF rate range to [1.5 GHz, 1.5 GHz],
	 * which is the AX631 ceiling and wrong for this part -- the AX630C
	 * boots at and tops out at 1.2 GHz (spec 3.2, 4/#4). No range is set
	 * here because no rate is ever set.
	 */
	AX630C_PLL_C(AX630C_PLL_CPUPLL, "cpupll", "cpll_12m"),
};

const struct ax630c_clk_desc ax630c_pllc_desc = {
	.clks = ax630c_pllc_clks,
	.num_clks = ARRAY_SIZE(ax630c_pllc_clks),
	.max_id = AX630C_PLL_CPUPLL,
	/* V, spec 1.3 */
	.alias = { .has_alias = true, .set_stride = 0x4, .clr_stride = 0x8 },
};

/* --- cpu_clk, 0x0190_0000 (spec 2.3) ------------------------------------ */

static const char * const ax630c_clk_h_ssi_sel_parents[] = {
	"cpll_24m", "epll_125m", "cpll_208m", "cpll_312m", "npll_400m",
	"cpll_416m",
};

/* The clock cpufreq-dt drives; four of its five OPPs are pure reparents. */
static const char * const ax630c_clk_cpu_sel_parents[] = {
	"cpll_24m", "cpll_208m", "epll_500m", "npll_800m", "cpupll_1200m",
};

static const char * const ax630c_clk_bus_flash_sel_parents[] = {
	"cpll_24m", "epll_125m", "cpll_208m", "cpll_312m",
};

/*
 * eMMC card-clock mux, 0x00[6:5] (V). No vendor *source* names values 0-2 --
 * the vendor CCF skips this clock entirely and every writer hardcodes 3 -- but
 * the SDK's own "AX SDK 使用说明" manual documents the field in full
 * (section 12.3, "clk_emmc_card mux select"), and the same document's
 * clk_bus_flash table matches ax630c_clk_bus_flash_sel_parents[] below entry
 * for entry, which is what makes it trustworthy here. Hardware reads 3
 * (0x01900000 = 0x00000073, measured 2026-09-06).
 *
 * The SD and SDIO card muxes are NOT registered: that manual covers eMMC only,
 * and no artifact names their values 0-2. Their dividers parent straight onto
 * npll_400m instead -- see the flash table.
 */
static const char * const ax630c_clk_emmc_card_sel_parents[] = {
	"cpll_24m", "cpll_312m", "epll_375m", "npll_400m",
};

static const struct ax630c_clk ax630c_cpu_clks[] = {
	AX630C_MUX_C(AX630C_CLK_H_SSI_SEL, "clk_h_ssi_sel", ax630c_clk_h_ssi_sel_parents, 0x00, 7, 3),
	AX630C_MUX_C(AX630C_CLK_CPU_SEL, "clk_cpu_sel", ax630c_clk_cpu_sel_parents, 0x00, 2, 3),
	AX630C_MUX_C(AX630C_CLK_BUS_FLASH_SEL, "clk_bus_flash_sel", ax630c_clk_bus_flash_sel_parents, 0x00, 0, 2),
	AX630C_MUX_C(AX630C_CLK_EMMC_CARD_SEL, "clk_emmc_card_sel", ax630c_clk_emmc_card_sel_parents, 0x00, 5, 2),

	AX630C_GATE_C(AX630C_CLK_H_SSI_EB, "clk_h_ssi_eb", "clk_h_ssi_divn", 0x04, 3, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_CPU_24M_EB, "clk_cpu_24m_eb", "cpll_24m", 0x04, 1, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_CS_APB_EB, "clk_cs_apb_eb", "cpll_24m", 0x08, 3, CLK_SET_RATE_PARENT),

	/* eMMC (#76). The card clock is what the mmc node names. */
	AX630C_GATE_C(AX630C_CLK_EMMC_CARD_EB, "clk_emmc_card_eb", "clk_emmc_card_divn", 0x04, 2, CLK_SET_RATE_PARENT),
	/*
	 * The controller's own bus gate. It cannot be named in DT -- the
	 * cdns,sd4hc binding allows exactly one clock and that slot is the card
	 * clock -- so it must be CLK_IS_CRITICAL or clk_disable_unused() turns
	 * the boot device off at late_initcall. NULL parent: the source is
	 * genuinely unknown, and nothing reads this clock's rate.
	 */
	AX630C_GATE_C(AX630C_CLK_EMMC_EB, "clk_emmc_eb", NULL, 0x08, 4, CLK_IS_CRITICAL),

	AX630C_DIV_C(AX630C_CLK_H_SSI_DIVN, "clk_h_ssi_divn", "clk_h_ssi_sel", 0x0c, 7, 4, 11),
	/* Reads 1 -> divide by 2 -> 400/2 = 200 MHz, matching CAPS[15:8] (V). */
	AX630C_DIV_C(AX630C_CLK_EMMC_CARD_DIVN, "clk_emmc_card_divn", "clk_emmc_card_sel", 0x0c, 0, 6, 6),
};

const struct ax630c_clk_desc ax630c_cpu_desc = {
	.clks = ax630c_cpu_clks,
	.num_clks = ARRAY_SIZE(ax630c_cpu_clks),
	.max_id = AX630C_CLK_EMMC_CARD_DIVN,
	/* V, spec 1.3 (sdhci-axera.c) */
	.alias = { .has_alias = true, .set_stride = 0x1000, .clr_stride = 0x2000 },
};

/* --- common_clk, 0x0234_0000 (spec 2.2) --------------------------------- */

static const char * const ax630c_clk_vi_sel_parents[] = {
	"epll_100m", "cpll_208m", "cpll_312m",
};

/* Five parents in a three-bit field; every value seen on the device is in range. */
static const char * const ax630c_clk_isp_mm_sel_parents[] = {
	"epll_100m", "cpll_156m", "epll_250m", "cpll_312m", "cpll_416m",
};

static const char * const ax630c_clk_dbc_gpio_sel_parents[] = {
	"rtc_out_32k", "xtal_24m",
};

static const char * const ax630c_pclk_top_sel_parents[] = {
	"cpll_24m", "epll_100m", "cpll_156m", "cpll_208m",
};

static const struct ax630c_clk ax630c_common_clks[] = {
	/*
	 * Fixed-rate roots (spec 2.2.1). These rates are asserted by the
	 * driver, not read back: the bootloader brings every PLL up and Linux
	 * never programs one. xtal_24m is a leaf here rather than the root of
	 * the PLLs, which is how the vendor modelled it; rooting the PLLs on a
	 * real 24 MHz DT crystal is spec 4/#7's recommendation and a DT change,
	 * not a table change.
	 */
	AX630C_FIXED(AX630C_CLK_RTC_OUT_32K, "rtc_out_32k", 32768),
	AX630C_FIXED(AX630C_REF24M, "xtal_24m", 24000000),
	AX630C_FIXED(AX630C_CPLL, "cpll", 2496000000UL),
	AX630C_FIXED(AX630C_HPLL, "hpll", 1228800000UL),
	AX630C_FIXED(AX630C_NPLL, "npll", 1600000000UL),
	AX630C_FIXED(AX630C_VPLL0, "vpll0", 1188000000UL),
	AX630C_FIXED(AX630C_VPLL1, "vpll1", 1188000000UL),
	AX630C_FIXED(AX630C_EPLL, "epll", 1500000000UL),
	AX630C_FIXED(AX630C_DPLL, "dpll", 3200000000UL),

	/* Fixed-factor taps (spec 2.2.2). mult is 1 throughout. */
	AX630C_FACTOR(AX630C_CPLL_2496M, "cpll_2496m", "cpll", 1),
	AX630C_FACTOR(AX630C_CPLL_1248M, "cpll_1248m", "cpll_2496m", 2),
	AX630C_FACTOR(AX630C_CPLL_12M, "cpll_12m", "cpll_2496m", 208),
	AX630C_FACTOR(AX630C_CPLL_624M, "cpll_624m", "cpll_1248m", 2),
	AX630C_FACTOR(AX630C_CPLL_416M, "cpll_416m", "cpll_1248m", 3),
	AX630C_FACTOR(AX630C_CPLL_249P6M, "cpll_249p6m", "cpll_1248m", 5),
	AX630C_FACTOR(AX630C_CPLL_312M, "cpll_312m", "cpll_624m", 2),
	AX630C_FACTOR(AX630C_CPLL_208M, "cpll_208m", "cpll_624m", 3),
	/*
	 * Vendor defect, spec 4/#1: the vendor calls this cpll_19p2m but
	 * divides cpll_249p6m by 5, giving 49.92 MHz -- 19.2 MHz would need
	 * /13. The device agrees with the divisor, so the divisor is the
	 * hardware and the name is the mistake; changing the divisor would
	 * change what the SoC does. It is index 1 of every MCLK*_sel, so a
	 * sensor asking for "19.2 MHz" gets 49.92 MHz. Renamed here, ID kept.
	 */
	AX630C_FACTOR(AX630C_CPLL_19P2M, "cpll_49p92m", "cpll_249p6m", 5),
	AX630C_FACTOR(AX630C_CPLL_156M, "cpll_156m", "cpll_312m", 2),
	AX630C_FACTOR(AX630C_CPLL_24M, "cpll_24m", "cpll_312m", 13),
	AX630C_FACTOR(AX630C_CPLL_78M, "cpll_78m", "cpll_156m", 2),
	AX630C_FACTOR(AX630C_CPLL_39M, "cpll_39m", "cpll_78m", 2),
	AX630C_FACTOR(AX630C_CPLL_26M, "cpll_26m", "cpll_78m", 3),
	AX630C_FACTOR(AX630C_HPLL_1228P8M, "hpll_1228p8m", "hpll", 1),
	AX630C_FACTOR(AX630C_HPLL_245P76M, "hpll_245p76m", "hpll_1228p8m", 5),
	AX630C_FACTOR(AX630C_HPLL_49P152M, "hpll_49p152m", "hpll_245p76m", 5),
	AX630C_FACTOR(AX630C_HPLL_81P92M, "hpll_81p92m", "hpll_245p76m", 3),
	AX630C_FACTOR(AX630C_HPLL_24P576M, "hpll_24p576m", "hpll_49p152m", 2),
	AX630C_FACTOR(AX630C_HPLL_16P384M, "hpll_16p384m", "hpll_49p152m", 3),
	AX630C_FACTOR(AX630C_HPLL_40P96M, "hpll_40p96m", "hpll_81p92m", 2),
	AX630C_FACTOR(AX630C_HPLL_12P288M, "hpll_12p288m", "hpll_24p576m", 2),
	AX630C_FACTOR(AX630C_HPLL_20P48M, "hpll_20p48m", "hpll_40p96m", 2),
	AX630C_FACTOR(AX630C_HPLL_4096K, "hpll_4096k", "hpll_20p48m", 5),
	AX630C_FACTOR(AX630C_NPLL_1600M, "npll_1600m", "npll", 1),
	AX630C_FACTOR(AX630C_NPLL_800M, "npll_800m", "npll_1600m", 2),
	AX630C_FACTOR(AX630C_NPLL_400M, "npll_400m", "npll_800m", 2),
	AX630C_FACTOR(AX630C_NPLL_200M, "npll_200m", "npll_400m", 2),
	AX630C_FACTOR(AX630C_NPLL_100M, "npll_100m", "npll_200m", 2),
	AX630C_FACTOR(AX630C_NPLL_50M, "npll_50m", "npll_100m", 2),
	AX630C_FACTOR(AX630C_NPLL_25M, "npll_25m", "npll_50m", 2),
	AX630C_FACTOR(AX630C_NPLL_533M, "npll_533m", "npll_1600m", 3),
	AX630C_FACTOR(AX630C_VPLL0_1188M, "vpll0_1188m", "vpll0", 1),
	AX630C_FACTOR(AX630C_VPLL0_108M, "vpll0_108m", "vpll0_1188m", 11),
	AX630C_FACTOR(AX630C_VPLL0_594M, "vpll0_594m", "vpll0_1188m", 2),
	AX630C_FACTOR(AX630C_VPLL0_198M, "vpll0_198m", "vpll0_594m", 3),
	AX630C_FACTOR(AX630C_VPLL0_118P8M, "vpll0_118p8m", "vpll0_594m", 5),
	AX630C_FACTOR(AX630C_VPLL0_297M, "vpll0_297m", "vpll0_594m", 2),
	AX630C_FACTOR(AX630C_VPLL0_148P5M, "vpll0_148p5m", "vpll0_297m", 2),
	AX630C_FACTOR(AX630C_VPLL0_27M, "vpll0_27m", "vpll0_297m", 11),
	AX630C_FACTOR(AX630C_VPLL0_74P25M, "vpll0_74p25m", "vpll0_148p5m", 2),
	AX630C_FACTOR(AX630C_VPLL0_37P125M, "vpll0_37p125m", "vpll0_74p25m", 2),
	AX630C_FACTOR(AX630C_VPLL1_1188M, "vpll1_1188m", "vpll1", 1),
	AX630C_FACTOR(AX630C_VPLL1_108M, "vpll1_108m", "vpll1_1188m", 11),
	AX630C_FACTOR(AX630C_VPLL1_594M, "vpll1_594m", "vpll1_1188m", 2),
	AX630C_FACTOR(AX630C_VPLL1_198M, "vpll1_198m", "vpll1_594m", 3),
	AX630C_FACTOR(AX630C_VPLL1_118P8M, "vpll1_118p8m", "vpll1_594m", 5),
	AX630C_FACTOR(AX630C_VPLL1_297M, "vpll1_297m", "vpll1_594m", 2),
	/* Name says 148; the tap is /2 of 297 MHz, i.e. 148.5 MHz. */
	AX630C_FACTOR(AX630C_VPLL1_148M, "vpll1_148m", "vpll1_297m", 2),
	AX630C_FACTOR(AX630C_VPLL1_27M, "vpll1_27m", "vpll1_297m", 11),
	AX630C_FACTOR(AX630C_VPLL1_74P25M, "vpll1_74p25m", "vpll1_148m", 2),
	AX630C_FACTOR(AX630C_VPLL1_37P125M, "vpll1_37p125m", "vpll1_74p25m", 2),
	AX630C_FACTOR(AX630C_EPLL_1500M, "epll_1500m", "epll", 1),
	AX630C_FACTOR(AX630C_EPLL_500M, "epll_500m", "epll_1500m", 3),
	AX630C_FACTOR(AX630C_EPLL_750M, "epll_750m", "epll_1500m", 2),
	AX630C_FACTOR(AX630C_EPLL_250M, "epll_250m", "epll_500m", 2),
	AX630C_FACTOR(AX630C_EPLL_375M, "epll_375m", "epll_750m", 2),
	AX630C_FACTOR(AX630C_EPLL_100M, "epll_100m", "epll_500m", 5),
	AX630C_FACTOR(AX630C_EPLL_125M, "epll_125m", "epll_250m", 2),
	AX630C_FACTOR(AX630C_EPLL_20M, "epll_20m", "epll_100m", 5),
	AX630C_FACTOR(AX630C_EPLL_50M, "epll_50m", "epll_100m", 2),
	AX630C_FACTOR(AX630C_EPLL_62P5M, "epll_62p5m", "epll_125m", 2),
	AX630C_FACTOR(AX630C_EPLL_10M, "epll_10m", "epll_20m", 2),
	AX630C_FACTOR(AX630C_EPLL_25M, "epll_25m", "epll_50m", 2),
	AX630C_FACTOR(AX630C_EPLL_31P25M, "epll_31p25m", "epll_62p5m", 2),
	AX630C_FACTOR(AX630C_EPLL_5M, "epll_5m", "epll_25m", 5),
	AX630C_FACTOR(AX630C_DPLL_3200M, "dpll_3200m", "dpll", 1),
	AX630C_FACTOR(AX630C_DPLL_1600M, "dpll_1600m", "dpll_3200m", 2),
	AX630C_FACTOR(AX630C_DPLL_800M, "dpll_800m", "dpll_1600m", 2),
	AX630C_FACTOR(AX630C_DPLL_400M, "dpll_400m", "dpll_800m", 2),
	AX630C_FACTOR(AX630C_DPLL_200M, "dpll_200m", "dpll_400m", 2),
	AX630C_FACTOR(AX630C_DPLL_100M, "dpll_100m", "dpll_200m", 2),
	AX630C_FACTOR(AX630C_DPLL_50M, "dpll_50m", "dpll_100m", 2),
	AX630C_FACTOR(AX630C_DPLL_25M, "dpll_25m", "dpll_50m", 2),
	/* The six cpupll taps are the only fixed-factors with a flag set. */
	AX630C_FACTOR_F(AX630C_CPUPLL_1200M, "cpupll_1200m", "cpupll", 1, CLK_SET_RATE_PARENT),
	AX630C_FACTOR_F(AX630C_CPUPLL_600M, "cpupll_600m", "cpupll", 2, CLK_SET_RATE_PARENT),
	AX630C_FACTOR_F(AX630C_CPUPLL_300M, "cpupll_300m", "cpupll_600m", 2, CLK_SET_RATE_PARENT),
	AX630C_FACTOR_F(AX630C_CPUPLL_150M, "cpupll_150m", "cpupll_300m", 2, CLK_SET_RATE_PARENT),
	AX630C_FACTOR_F(AX630C_CPUPLL_75M, "cpupll_75m", "cpupll_150m", 2, CLK_SET_RATE_PARENT),
	AX630C_FACTOR_F(AX630C_CPUPLL_25M, "cpupll_25m", "cpupll_75m", 3, CLK_SET_RATE_PARENT),

	/* Muxes (spec 2.2.3). */
	AX630C_MUX_C(AX630C_ACLK_ISP_TOP_SEL, "aclk_isp_top_sel", ax630c_top6_parents, 0x00, 27, 3),
	AX630C_MUX_C(AX630C_ACLK_CPU_TOP_SEL, "aclk_cpu_top_sel", ax630c_top6_parents, 0x00, 24, 3),
	AX630C_MUX_C(AX630C_MCLK5_SEL, "MCLK5_sel", ax630c_mclk13_parents, 0x00, 20, 4),
	AX630C_MUX_C(AX630C_MCLK4_SEL, "MCLK4_sel", ax630c_mclk13_parents, 0x00, 16, 4),
	AX630C_MUX_C(AX630C_MCLK3_SEL, "MCLK3_sel", ax630c_mclk13_parents, 0x00, 12, 4),
	AX630C_MUX_C(AX630C_MCLK2_SEL, "MCLK2_sel", ax630c_mclk13_parents, 0x00, 8, 4),
	AX630C_MUX_C(AX630C_MCLK1_SEL, "MCLK1_sel", ax630c_mclk13_parents, 0x00, 4, 4),
	AX630C_MUX_C(AX630C_MCLK0_SEL, "MCLK0_sel", ax630c_mclk13_parents, 0x00, 0, 4),
	AX630C_MUX_C(AX630C_CLK_VI_SEL, "clk_vi_sel", ax630c_clk_vi_sel_parents, 0x0c, 28, 2),
	AX630C_MUX_C(AX630C_CLK_NX_VO1_COMM_SEL, "clk_nx_vo1_comm_sel", ax630c_vo1_parents, 0x0c, 22, 2),
	AX630C_MUX_C(AX630C_CLK_NX_VO0_COMM_SEL, "clk_nx_vo0_comm_sel", ax630c_vo0_parents, 0x0c, 20, 2),
	AX630C_MUX_C(AX630C_CLK_ISP_MM_SEL, "clk_isp_mm_sel", ax630c_clk_isp_mm_sel_parents, 0x0c, 17, 3),
	AX630C_MUX_C(AX630C_CLK_DBC_GPIO_SEL, "clk_dbc_gpio_sel", ax630c_clk_dbc_gpio_sel_parents, 0x0c, 16, 1),
	AX630C_MUX_C(AX630C_CLK_1X_VO1_COMM_SEL, "clk_1x_vo1_comm_sel", ax630c_vo1_parents, 0x0c, 14, 2),
	/*
	 * The vendor sizes this row's parent list with ARRAY_SIZE of the *vo1*
	 * array. Both lists are four entries so nothing broke, but the members
	 * belong to vo0.
	 */
	AX630C_MUX_C(AX630C_CLK_1X_VO0_COMM_SEL, "clk_1x_vo0_comm_sel", ax630c_vo0_parents, 0x0c, 12, 2),
	AX630C_MUX_C(AX630C_ACLK_VPU_TOP_SEL, "aclk_vpu_top_sel", ax630c_top6_parents, 0x0c, 9, 3),
	AX630C_MUX_C(AX630C_ACLK_OCM_TOP_SEL, "aclk_ocm_top_sel", ax630c_top6_parents, 0x0c, 6, 3),
	AX630C_MUX_C(AX630C_ACLK_NN_TOP_SEL, "aclk_nn_top_sel", ax630c_top6_parents, 0x0c, 3, 3),
	AX630C_MUX_C(AX630C_ACLK_MM_TOP_SEL, "aclk_mm_top_sel", ax630c_top6_parents, 0x0c, 0, 3),
	AX630C_MUX_C(AX630C_PCLK_TOP_SEL, "pclk_top_sel", ax630c_pclk_top_sel_parents, 0x18, 0, 2),

	/*
	 * Gates (spec 2.2.4), all in the 0x24 word.
	 *
	 * clk_vi_eb and clk_tmr_sync_eb name parents -- clk_vi, clk_tmr_sync --
	 * that no controller registers, so they enumerate as orphans with rate
	 * 0, exactly as they do on the vendor kernel (spec 4/#3). Transcribed
	 * rather than repaired: what those parents are is not in the spec.
	 */
	AX630C_GATE_C(AX630C_CLK_VI_EB, "clk_vi_eb", "clk_vi", 0x24, 17, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_TMR_SYNC_EB, "clk_tmr_sync_eb", "clk_tmr_sync", 0x24, 16, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_NX_VO1_COMM_EB, "clk_nx_vo1_comm_eb", "clk_nx_vo1_comm_divn", 0x24, 13, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_NX_VO0_COMM_EB, "clk_nx_vo0_comm_eb", "clk_nx_vo0_comm_divn", 0x24, 12, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_ISP_MM_EB, "clk_isp_mm_eb", "clk_isp_mm_sel", 0x24, 11, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_DPHYTX_TLB_EB, "clk_dphytx_tlb_eb", "cpll_24m", 0x24, 10, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_DPHYRX_TLB_EB, "clk_dphyrx_tlb_eb", "cpll_24m", 0x24, 9, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_AUDIO_TLB_EB, "clk_audio_tlb_eb", "cpll_24m", 0x24, 8, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_1X_VO1_COMM_EB, "clk_1x_vo1_comm_eb", "clk_1x_vo1_comm_divn", 0x24, 7, CLK_SET_RATE_PARENT),
	/*
	 * Vendor defect, spec 4/#2: the vendor names clk_1x_vo1_comm_divn
	 * here, so on the vendor kernel this gate hangs off the vo1 divider
	 * and clk_1x_vo0_comm_divn has no child at all. It is a copy-paste
	 * typo in a parent *string*, not something the hardware chose -- the
	 * vo0 gate is fed by the vo0 divider. Repaired, per spec 4/#2's
	 * "fix in mainline".
	 */
	AX630C_GATE_C(AX630C_CLK_1X_VO0_COMM_EB, "clk_1x_vo0_comm_eb", "clk_1x_vo0_comm_divn", 0x24, 6, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_MCLK5_EB, "MCLK5_eb", "MCLK5_divn", 0x24, 5, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_MCLK4_EB, "MCLK4_eb", "MCLK4_divn", 0x24, 4, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_MCLK3_EB, "MCLK3_eb", "MCLK3_divn", 0x24, 3, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_MCLK2_EB, "MCLK2_eb", "MCLK2_divn", 0x24, 2, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_MCLK1_EB, "MCLK1_eb", "MCLK1_divn", 0x24, 1, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_MCLK0_EB, "MCLK0_eb", "MCLK0_divn", 0x24, 0, CLK_SET_RATE_PARENT),

	/* Dividers (spec 2.2.5). */
	AX630C_DIV_C(AX630C_MCLK5_DIVN, "MCLK5_divn", "MCLK5_sel", 0x3c, 25, 4, 29),
	AX630C_DIV_C(AX630C_MCLK4_DIVN, "MCLK4_divn", "MCLK4_sel", 0x3c, 20, 4, 24),
	AX630C_DIV_C(AX630C_MCLK3_DIVN, "MCLK3_divn", "MCLK3_sel", 0x3c, 15, 4, 19),
	AX630C_DIV_C(AX630C_MCLK2_DIVN, "MCLK2_divn", "MCLK2_sel", 0x3c, 10, 4, 14),
	AX630C_DIV_C(AX630C_MCLK1_DIVN, "MCLK1_divn", "MCLK1_sel", 0x3c, 5, 4, 9),
	AX630C_DIV_C(AX630C_MCLK0_DIVN, "MCLK0_divn", "MCLK0_sel", 0x3c, 0, 4, 4),
	AX630C_DIV_C(AX630C_CLK_NX_VO1_DIVN, "clk_nx_vo1_comm_divn", "clk_nx_vo1_comm_sel", 0x48, 15, 4, 19),
	AX630C_DIV_C(AX630C_CLK_NX_VO0_DIVN, "clk_nx_vo0_comm_divn", "clk_nx_vo0_comm_sel", 0x48, 10, 4, 14),
	AX630C_DIV_C(AX630C_CLK_1X_VO1_DIVN, "clk_1x_vo1_comm_divn", "clk_1x_vo1_comm_sel", 0x48, 5, 4, 9),
	AX630C_DIV_C(AX630C_CLK_1X_VO0_DIVN, "clk_1x_vo0_comm_divn", "clk_1x_vo0_comm_sel", 0x48, 0, 4, 4),
};

const struct ax630c_clk_desc ax630c_common_desc = {
	.clks = ax630c_common_clks,
	.num_clks = ARRAY_SIZE(ax630c_common_clks),
	.max_id = AX630C_CLK_RTC_OUT_32K,
	/*
	 * I, spec 1.3: not directly cited, but the registered value words
	 * 0x00, 0x0c, 0x18, 0x24, 0x3c and 0x48 sit on an exact 0xc stride,
	 * which is the pllc triplet layout.
	 */
	.alias = { .has_alias = true, .set_stride = 0x4, .clr_stride = 0x8 },
};

/* --- dispc_clk, 0x0460_0000 (spec 2.4) ---------------------------------- */

static const char * const ax630c_clk_dphy_tx_esc_sel_parents[] = {
	"epll_10m", "epll_20m",
};

static const char * const ax630c_clk_dispc_glb_sel_parents[] = {
	"cpll_24m", "epll_100m", "cpll_208m", "cpll_312m", "cpll_416m",
};

static const struct ax630c_clk ax630c_dispc_clks[] = {
	AX630C_MUX_C(AX630C_CLK_DPHY_TX_ESC_SEL, "clk_dphy_tx_esc_sel", ax630c_clk_dphy_tx_esc_sel_parents, 0x00, 3, 1),
	AX630C_MUX_C(AX630C_CLK_DISPC_GLB_SEL, "clk_dispc_glb_sel", ax630c_clk_dispc_glb_sel_parents, 0x00, 0, 3),

	AX630C_GATE_C(AX630C_CLK_DPHY_TX_REF_EB, "clk_dphy_tx_ref_eb", "cpll_12m", 0x04, 1, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_DPHY_TX_ESC_EB, "clk_dphy_tx_esc_eb", "clk_dphy_tx_esc_sel", 0x04, 0, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_LVDS_TX_EB, "pclk_lvds_tx_eb", "clk_dispc_glb_sel", 0x08, 9, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_DSI_EB, "pclk_dsi_eb", "clk_dispc_glb_sel", 0x08, 8, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_CSI_EB, "pclk_csi_eb", "clk_dispc_glb_sel", 0x08, 7, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_DSI_TX_ESC_EB, "clk_dsi_tx_esc_eb", "clk_dphy_tx_esc_sel", 0x08, 6, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_DSI_SYS_EB, "clk_dsi_sys_eb", "clk_dispc_glb_sel", 0x08, 5, CLK_SET_RATE_PARENT),
	/*
	 * GAP (spec 2.4, 4/#3). The vendor left the literal placeholder
	 * "need_modify" in the parent-name field of these five gates and never
	 * filled it in. Their real sources are MIPI D-PHY TX PLL outputs, and
	 * that PLL is modelled nowhere -- not in the vendor tree, not in the
	 * specification -- so there is no name to put here that would be true.
	 *
	 * They are registered with no parent at all. CCF accepts a parentless
	 * clock and reports rate 0 for it, which is exactly what the device
	 * shows today; the placeholder string would have produced the same
	 * orphan while also inventing a clock name. CLK_SET_RATE_PARENT is
	 * dropped with the parent, having nothing left to propagate to.
	 *
	 * The spec offers two ways out -- root them on a clock the DSI PHY
	 * driver provides, or drop them from this driver entirely -- and picks
	 * neither. Either is a change of model, not a transcription.
	 */
	AX630C_GATE_C(AX630C_CLK_DPHY_TX_PLL_DIV7_CG_EB, "clk_dphy_tx_pll_div7_cg_eb", NULL, 0x08, 4, 0),
	AX630C_GATE_C(AX630C_CLK_DPHY_TX_PLL_CG_EB, "clk_dphy_tx_pll_cg_eb", NULL, 0x08, 3, 0),
	AX630C_GATE_C(AX630C_CLK_DPHY2DSI_HS_EB, "clk_dphy2dsi_hs_eb", NULL, 0x08, 2, 0),
	AX630C_GATE_C(AX630C_CLK_DPHY2CSI_HS_EB, "clk_dphy2csi_hs_eb", NULL, 0x08, 1, 0),
	AX630C_GATE_C(AX630C_CLK_CSI_TX_ESC_EB, "clk_csi_tx_esc_eb", NULL, 0x08, 0, 0),
};

const struct ax630c_clk_desc ax630c_dispc_desc = {
	.clks = ax630c_dispc_clks,
	.num_clks = ARRAY_SIZE(ax630c_dispc_clks),
	.max_id = AX630C_CLK_CSI_TX_ESC_EB,
	/*
	 * GAP, spec 1.3: the set/clear alias window for dispc is unknown. Its
	 * value words are a flat 4-byte stride, so it cannot be using the
	 * +4/+8 triplet. Read-modify-write under the syscon regmap lock until
	 * someone reads the hardware.
	 */
	.alias = { .has_alias = false },
};

/* --- flash_clk, 0x1003_0000 (spec 2.5) ---------------------------------- */

static const char * const ax630c_rgmii_ephy_clk_sel_parents[] = {
	"epll_25m", "epll_50m", "epll_125m",
};

static const char * const ax630c_clk_flash_glb_sel_parents[] = {
	"cpll_24m", "epll_100m", "cpll_156m", "cpll_208m", "epll_250m",
	"cpll_312m",
};

/*
 * Sits on epll_5m at reset and after the bootloader, which is correct for a
 * 10 Mbit/s RGMII link (2.5 MHz x 2) -- not a model defect, do not "fix" it
 * (spec 4/#9). The three inputs are the three link speeds, so this is the one
 * mux a consumer must be able to re-point: the DWMAC glue (#77) does it from
 * set_clk_tx_rate() at every link-up. Hence AX630C_MUX_RC below.
 *
 * The 2x is real hardware, not a modelling artefact: the field read 2
 * (epll_250m) on the running device while the vendor stack held a gigabit
 * link, whose TXC is 125 MHz (measured 2026-09-06). It is also why the glue
 * cannot use stmmac's generic set_clk_tx_rate helper.
 */
static const char * const ax630c_clk_emac_rgmii_tx_sel_parents[] = {
	"epll_5m", "epll_50m", "epll_250m",
};

static const struct ax630c_clk ax630c_flash_clks[] = {
	AX630C_MUX_C(AX630C_RGMII_EPHY_CLK_SEL, "rgmii_ephy_clk_sel", ax630c_rgmii_ephy_clk_sel_parents, 0x00, 22, 2),
	AX630C_MUX_C(AX630C_CLK_NX_VO1_SEL, "clk_nx_vo1_sel", ax630c_vo1_parents, 0x00, 14, 2),
	AX630C_MUX_C(AX630C_CLK_NX_VO0_SEL, "clk_nx_vo0_sel", ax630c_vo0_parents, 0x00, 12, 2),
	AX630C_MUX_C(AX630C_CLK_FLASH_GLB_SEL, "clk_flash_glb_sel", ax630c_clk_flash_glb_sel_parents, 0x00, 6, 3),
	AX630C_MUX_RC(AX630C_CLK_EMAC_RGMII_TX_SEL, "clk_emac_rgmii_tx_sel", ax630c_clk_emac_rgmii_tx_sel_parents, 0x00, 4, 2),
	AX630C_MUX_C(AX630C_CLK_1X_VO1_SEL, "clk_1x_vo1_sel", ax630c_vo1_parents, 0x00, 2, 2),
	AX630C_MUX_C(AX630C_CLK_1X_VO0_SEL, "clk_1x_vo0_sel", ax630c_vo0_parents, 0x00, 0, 2),

	AX630C_GATE_C(AX630C_EPHY_CLK_EB, "ephy_clk_eb", "rgmii_ephy_clk_sel", 0x04, 13, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_NX_VO1_EB, "clk_nx_vo1_eb", "clk_nx_vo1_divn_flash", 0x04, 8, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_NX_VO0_EB, "clk_nx_vo0_eb", "clk_nx_vo0_divn_flash", 0x04, 7, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_EMAC_RMII_PHY_EB, "clk_emac_rmii_phy_eb", "epll_50m", 0x04, 4, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_EMAC_RGMII_TX_EB, "clk_emac_rgmii_tx_eb", "clk_emac_rgmii_tx_sel", 0x04, 3, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_EMAC_PTP_REF_EB, "clk_emac_ptp_ref_eb", "epll_50m", 0x04, 2, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_1X_VO1_EB, "clk_1x_vo1_eb", "clk_1x_vo1_divn_flash", 0x04, 1, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_1X_VO0_EB, "clk_1x_vo0_eb", "clk_1x_vo0_divn_flash", 0x04, 0, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_LPC_FLASH_EB, "clk_lpc_flash_eb", "cpll_24m", 0x08, 11, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_ACLK_EMAC_EB, "aclk_emac_eb", "clk_flash_glb_sel", 0x08, 2, CLK_SET_RATE_PARENT),

	/*
	 * SD and SDIO (#76). Card clocks are what the two mmc nodes name; the
	 * APB/AXI gates below cannot be named (one clock per cdns,sd4hc node)
	 * and so are CLK_IS_CRITICAL, exactly as clk_emmc_eb is. NULL parents
	 * for the bus gates: their sources are not established in any artifact
	 * we have, nothing reads their rates, and a plausible-looking guess
	 * here would be indistinguishable from a measured fact later.
	 *
	 * The two card muxes at 0x00[17:16] and [19:18] are NOT registered.
	 * Both read 3 = npll_400m (V, measured 2026-09-06, 0x10030000 =
	 * 0x003F0B60) and every writer in the vendor SDK hardcodes 3, but
	 * nothing names values 0-2: the vendor CCF skips both clocks, and the
	 * SDK manual that documents the eMMC mux (see the cpu table) covers
	 * eMMC only. CCF cannot register a 2-bit mux without all four parents,
	 * and a plausible-looking invented name would be indistinguishable
	 * from a measured one later -- so the dividers parent straight onto
	 * npll_400m, which is a complete description of every state this
	 * hardware is ever in. Register the muxes when someone can name 0-2.
	 */
	AX630C_GATE_C(AX630C_CLK_SD_CARD_EB, "clk_sd_card_eb", "clk_sd_card_divn", 0x04, 9, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_SDIO_M_CARD_EB, "clk_sdio_m_card_eb", "clk_sdio_m_card_divn", 0x04, 10, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_ACLK_SD_M_EB, "aclk_sd_m_eb", NULL, 0x08, 3, CLK_IS_CRITICAL),
	AX630C_GATE_C(AX630C_ACLK_SDIO_M_EB, "aclk_sdio_m_eb", NULL, 0x08, 4, CLK_IS_CRITICAL),
	AX630C_GATE_C(AX630C_PCLK_SD_M_EB, "pclk_sd_m_eb", NULL, 0x08, 17, CLK_IS_CRITICAL),
	AX630C_GATE_C(AX630C_PCLK_SDIO_M_EB, "pclk_sdio_m_eb", NULL, 0x08, 18, CLK_IS_CRITICAL),
	/*
	 * The pinmux block's APB gate. No consumer names it yet -- the SD
	 * pad-voltage switch that needs it is deferred (the SD node carries
	 * no-1-8-v) and #80's pinctrl reaches its own window through a syscon
	 * regmap -- but it is on now and turning it off is not something a
	 * board with no console should discover the hard way. Critical until a
	 * consumer claims it.
	 */
	AX630C_GATE_C(AX630C_PCLK_PINMUX_EB, "pclk_pinmux_eb", NULL, 0x08, 16, CLK_IS_CRITICAL),

	AX630C_DIV_C(AX630C_CLK_NX_VO1_DIVN_FLASH, "clk_nx_vo1_divn_flash", "clk_nx_vo1_sel", 0x0c, 15, 4, 19),
	AX630C_DIV_C(AX630C_CLK_NX_VO0_DIVN_FLASH, "clk_nx_vo0_divn_flash", "clk_nx_vo0_sel", 0x0c, 10, 4, 14),
	AX630C_DIV_C(AX630C_CLK_1X_VO1_DIVN_FLASH, "clk_1x_vo1_divn_flash", "clk_1x_vo1_sel", 0x0c, 5, 4, 9),
	AX630C_DIV_C(AX630C_CLK_1X_VO0_DIVN_FLASH, "clk_1x_vo0_divn_flash", "clk_1x_vo0_sel", 0x0c, 0, 4, 4),
	/* Both read 1 -> divide by 2 -> 200 MHz (V). */
	AX630C_DIV_C(AX630C_CLK_SD_CARD_DIVN, "clk_sd_card_divn", "npll_400m", 0x0c, 20, 6, 26),
	AX630C_DIV_C(AX630C_CLK_SDIO_M_CARD_DIVN, "clk_sdio_m_card_divn", "npll_400m", 0x10, 0, 6, 6),
};

const struct ax630c_clk_desc ax630c_flash_desc = {
	.clks = ax630c_flash_clks,
	.num_clks = ARRAY_SIZE(ax630c_flash_clks),
	.max_id = AX630C_CLK_SDIO_M_CARD_DIVN,
	/* V, spec 1.3 (sdhci-axera.c) */
	.alias = { .has_alias = true, .set_stride = 0x4000, .clr_stride = 0x8000 },
};

/* --- mm_clk, 0x0443_0000 (spec 2.6) ------------------------------------- */

static const char * const ax630c_clk_csi_async_sel_parents[] = {
	"cpll_312m", "cpll_416m", "epll_500m", "npll_533m",
};

static const struct ax630c_clk ax630c_mm_clks[] = {
	AX630C_MUX_C(AX630C_CLK_VPP_SRC_SEL, "clk_vpp_src_sel", ax630c_top6_parents, 0x00, 27, 3),
	AX630C_MUX_C(AX630C_CLK_TDP_SRC_SEL, "clk_tdp_src_sel", ax630c_top6_parents, 0x00, 24, 3),
	AX630C_MUX_C(AX630C_CLK_MM_GLB_SEL, "clk_mm_glb_sel", ax630c_top6_parents, 0x00, 21, 3),
	AX630C_MUX_C(AX630C_CLK_IVE_SRC_SEL, "clk_ive_src_sel", ax630c_top6_parents, 0x00, 18, 3),
	AX630C_MUX_C(AX630C_CLK_GDC_SRC_SEL, "clk_gdc_src_sel", ax630c_top6_parents, 0x00, 15, 3),
	AX630C_MUX_C(AX630C_CLK_DPU_SRC_SEL, "clk_dpu_src_sel", ax630c_top6_parents, 0x00, 12, 3),
	AX630C_MUX_C(AX630C_CLK_DPU_OUT_SEL, "clk_dpu_out_sel", ax630c_vo0_parents, 0x00, 10, 2),
	AX630C_MUX_C(AX630C_CLK_DPU_LITE_SRC_SEL, "clk_dpu_lite_src_sel", ax630c_top6_parents, 0x00, 7, 3),
	AX630C_MUX_C(AX630C_CLK_DPU_LITE_OUT_SEL, "clk_dpu_lite_out_sel", ax630c_vo1_parents, 0x00, 5, 2),
	AX630C_MUX_C(AX630C_CLK_CSI_ASYNC_SEL, "clk_csi_async_sel", ax630c_clk_csi_async_sel_parents, 0x00, 3, 2),
	AX630C_MUX_C(AX630C_CLK_AXI2CSI_SRC_SEL, "clk_axi2csi_src_sel", ax630c_top6_parents, 0x00, 0, 3),

	AX630C_GATE_C(AX630C_CLK_DPU_OUT_EB, "clk_dpu_out_eb", "clk_dpu_out_divn", 0x04, 2, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_DPU_LITE_OUT_EB, "clk_dpu_lite_out_eb", "clk_dpu_lite_out_divn", 0x04, 1, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_CSI_ASYNC_EB, "clk_csi_async_eb", "clk_csi_async_sel", 0x04, 0, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_VPP_EB, "pclk_vpp_eb", "clk_vpp_src_sel", 0x08, 25, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_TDP_EB, "pclk_tdp_eb", "clk_tdp_src_sel", 0x08, 24, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_IVE_EB, "pclk_ive_eb", "clk_ive_src_sel", 0x08, 23, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_GDC_EB, "pclk_gdc_eb", "clk_gdc_src_sel", 0x08, 22, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_DPU_LITE_EB, "pclk_dpu_lite_eb", "clk_dpu_lite_src_sel", 0x08, 21, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_DPU_EB, "pclk_dpu_eb", "clk_dpu_src_sel", 0x08, 20, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_CMD_EB, "pclk_cmd_eb", "clk_mm_glb_sel", 0x08, 19, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_AXI2CSI_EB, "pclk_axi2csi_eb", "clk_axi2csi_src_sel", 0x08, 18, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_VPP_SCL4_EB, "clk_vpp_scl4_eb", "clk_vpp_src_sel", 0x08, 17, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_VPP_SCL3_EB, "clk_vpp_scl3_eb", "clk_vpp_src_sel", 0x08, 16, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_VPP_SCL2_EB, "clk_vpp_scl2_eb", "clk_vpp_src_sel", 0x08, 15, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_VPP_SCL1_EB, "clk_vpp_scl1_eb", "clk_vpp_src_sel", 0x08, 14, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_VPP_SCL0_EB, "clk_vpp_scl0_eb", "clk_vpp_src_sel", 0x08, 13, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_VPP_EB, "clk_vpp_eb", "clk_vpp_src_sel", 0x08, 12, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_TDP_EB, "clk_tdp_eb", "clk_tdp_src_sel", 0x08, 11, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_LPC_MM_EB, "clk_lpc_mm_eb", "cpll_24m", 0x08, 10, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_IVE_EB, "clk_ive_eb", "clk_ive_src_sel", 0x08, 9, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_GDC_EB, "clk_gdc_eb", "clk_gdc_src_sel", 0x08, 8, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_FBCD_EB, "clk_fbcd_eb", "clk_mm_glb_sel", 0x08, 7, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_FBC_EB, "clk_fbc_eb", "clk_mm_glb_sel", 0x08, 6, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_DPU_LITE_EB, "clk_dpu_lite_eb", "clk_dpu_lite_src_sel", 0x08, 5, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_DPU_EB, "clk_dpu_eb", "clk_dpu_src_sel", 0x08, 4, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_CMD_EB, "clk_cmd_eb", "clk_mm_glb_sel", 0x08, 3, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_AXI2CSI_EB, "clk_axi2csi_eb", "clk_axi2csi_src_sel", 0x08, 0, CLK_SET_RATE_PARENT),

	AX630C_DIV_C(AX630C_CLK_DPU_OUT_DIVN, "clk_dpu_out_divn", "clk_dpu_out_sel", 0x0c, 5, 4, 9),
	AX630C_DIV_C(AX630C_CLK_DPU_LITE_OUT_DIVN, "clk_dpu_lite_out_divn", "clk_dpu_lite_out_sel", 0x0c, 0, 4, 4),
};

const struct ax630c_clk_desc ax630c_mm_desc = {
	.clks = ax630c_mm_clks,
	.num_clks = ARRAY_SIZE(ax630c_mm_clks),
	.max_id = AX630C_CLK_DPU_LITE_OUT_DIVN,
	/* GAP, spec 1.3: alias window unknown. See ax630c_dispc_desc. */
	.alias = { .has_alias = false },
};

/* --- periph_clk, 0x0487_0000 (spec 2.7) --------------------------------- */

static const char * const ax630c_i2s_sclk_parents[] = {
	"hpll_16p384m", "hpll_20p48m", "hpll_24p576m",
};

static const char * const ax630c_clk_timer_sel_parents[] = {
	"rtc_out_32k", "cpll_24m",
};

static const char * const ax630c_clk_i2s_ref0_sel_parents[] = {
	"cpll_12m", "hpll_16p384m", "hpll_24p576m", "epll_25m",
};

static const struct ax630c_clk ax630c_periph_clks[] = {
	AX630C_MUX_C(AX630C_SCLK_I2S_TDM_SEL, "sclk_i2s_tdm_sel", ax630c_i2s_sclk_parents, 0x00, 23, 2),
	AX630C_MUX_C(AX630C_SCLK_I2S_M_SEL, "sclk_i2s_m_sel", ax630c_i2s_sclk_parents, 0x00, 21, 2),
	AX630C_MUX_C(AX630C_CLK_TIMER_SEL, "clk_timer_sel", ax630c_clk_timer_sel_parents, 0x00, 13, 1),
	AX630C_MUX_C(AX630C_CLK_I2S_REF0_SEL, "clk_i2s_ref0_sel", ax630c_clk_i2s_ref0_sel_parents, 0x00, 5, 2),

	/* pclk_top_sel below lives in common_clk; parents resolve by name. */
	AX630C_GATE_C(AX630C_SCLK_I2S_TDM_EB, "sclk_i2s_tdm_eb", "sclk_i2s_tdm_divn", 0x04, 17, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_SCLK_I2S_M_EB, "sclk_i2s_m_eb", "sclk_i2s_m_divn", 0x04, 16, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_TIMER_EB, "clk_timer_eb", "clk_timer_sel", 0x04, 9, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_I2S_REF0_EB, "clk_i2s_ref0_eb", "clk_i2s_ref0_divn", 0x04, 4, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_I2S_AUDIO_REF_EB, "clk_i2s_audio_ref_eb", "hpll_12p288m", 0x04, 3, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_TIMER0_EB, "clk_timer0_eb", "clk_timer_sel", 0x08, 31, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_LPC_PERI_EB, "clk_lpc_peri_eb", "cpll_24m", 0x08, 18, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_ACLK_AX_DMA_PER_EB, "aclk_ax_dma_per_eb", "pclk_top_sel", 0x08, 0, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_I2S_TDM_S_EB, "pclk_i2s_tdm_s_eb", "pclk_top_sel", 0x0c, 30, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_I2S_TDM_M_EB, "pclk_i2s_tdm_m_eb", "pclk_top_sel", 0x0c, 29, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_I2S_S_EB, "pclk_i2s_s_eb", "pclk_top_sel", 0x0c, 28, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_I2S_M_EB, "pclk_i2s_m_eb", "pclk_top_sel", 0x0c, 27, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_AX_DMA_PER_EB, "pclk_ax_dma_per_eb", "pclk_top_sel", 0x0c, 11, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_PCLK_TIMER0_EB, "pclk_timer0_eb", "pclk_top_sel", 0x10, 5, CLK_SET_RATE_PARENT),

	AX630C_DIV_C(AX630C_SCLK_I2S_TDM_DIVN, "sclk_i2s_tdm_divn", "sclk_i2s_tdm_sel", 0x14, 14, 6, 20),
	AX630C_DIV_C(AX630C_SCLK_I2S_M_DIVN, "sclk_i2s_m_divn", "sclk_i2s_m_sel", 0x14, 7, 6, 13),
	AX630C_DIV_C(AX630C_CLK_I2S_REF0_DIVN, "clk_i2s_ref0_divn", "clk_i2s_ref0_sel", 0x14, 0, 6, 6),
};

/*
 * periph is the one controller whose aliases are irregular: each value word
 * has its own set/clear pair rather than a fixed stride (spec 1.3). MUX0
 * through EB3 are cited from five vendor peripheral drivers; DIV0's pair is
 * inferred (I) by continuation of the pattern and has no direct citation. If
 * that inference is ever disproved the divider writes become RMW, which is
 * what the vendor did anyway.
 */
static const struct ax630c_alias_map ax630c_periph_alias_map[] = {
	{ .offset = 0x00, .set = 0xa8, .clr = 0xac },	/* MUX0 */
	{ .offset = 0x04, .set = 0xb0, .clr = 0xb4 },	/* EB0 */
	{ .offset = 0x08, .set = 0xb8, .clr = 0xbc },	/* EB1 */
	{ .offset = 0x0c, .set = 0xc0, .clr = 0xc4 },	/* EB2 */
	{ .offset = 0x10, .set = 0xc8, .clr = 0xcc },	/* EB3 */
	{ .offset = 0x14, .set = 0xd0, .clr = 0xd4 },	/* DIV0 -- I, uncited */
};

const struct ax630c_clk_desc ax630c_periph_desc = {
	.clks = ax630c_periph_clks,
	.num_clks = ARRAY_SIZE(ax630c_periph_clks),
	.max_id = AX630C_CLK_I2S_REF0_DIVN,
	.alias = { .has_alias = false },
	.alias_map = ax630c_periph_alias_map,
	.num_alias_map = ARRAY_SIZE(ax630c_periph_alias_map),
};

/* --- vpu_clk, 0x0403_0000 (spec 2.8) ------------------------------------ */

static const struct ax630c_clk ax630c_vpu_clks[] = {
	AX630C_MUX_C(AX630C_CLK_VPU_GLB_SEL, "clk_vpu_glb_sel", ax630c_vpu6_parents, 0x00, 6, 3),
	AX630C_MUX_C(AX630C_CLK_VDEC_SRC_SEL, "clk_vdec_src_sel", ax630c_vpu6_parents, 0x00, 3, 3),
	AX630C_MUX_C(AX630C_CLK_JENC_SRC_SEL, "clk_jenc_src_sel", ax630c_vpu6_parents, 0x00, 0, 3),

	AX630C_GATE_C(AX630C_CLK_VENC_EB, "clk_venc_eb", "clk_vpu_glb_sel", 0x08, 7, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_VDEC_EB, "clk_vdec_eb", "clk_vdec_src_sel", 0x08, 6, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_LPC_VPU_EB, "clk_lpc_vpu_eb", "cpll_24m", 0x08, 5, CLK_SET_RATE_PARENT),
	AX630C_GATE_C(AX630C_CLK_JENC_EB, "clk_jenc_eb", "clk_jenc_src_sel", 0x08, 4, CLK_SET_RATE_PARENT),
};

const struct ax630c_clk_desc ax630c_vpu_desc = {
	.clks = ax630c_vpu_clks,
	.num_clks = ARRAY_SIZE(ax630c_vpu_clks),
	.max_id = AX630C_CLK_JENC_EB,
	/* GAP, spec 1.3: alias window unknown. See ax630c_dispc_desc. */
	.alias = { .has_alias = false },
};
