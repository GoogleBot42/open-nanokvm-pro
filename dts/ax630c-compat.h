/* SPDX-License-Identifier: GPL-2.0 */
/*
 * AX630C compatible strings -- the ONE place the vendor prefix lives (#74).
 *
 * The Axera vendor prefix is not registered upstream, and #87 (upstreaming)
 * may have to change it. Every axera-prefixed compatible this DT emits is
 * defined here so that change is one edit, not a tree-wide sed.
 *
 * Whole strings rather than a bare prefix macro on purpose: dtc does not
 * concatenate adjacent string literals the way a C compiler does, so
 * `compatible = AX_PREFIX "ax630c";` would produce a TWO-entry compatible
 * list, not one string. cpp cannot paste string literals either.
 *
 * Standard-binding compatibles ("arm,gic-400", "snps,dw-apb-uart", ...) are
 * written inline: they are upstream names and will never be renamed.
 */

#ifndef _DTS_AX630C_COMPAT_H
#define _DTS_AX630C_COMPAT_H

/* SoC identity. AX620E is the family, AX630C the part on this board. */
#define AX630C_SOC_COMPAT		"axera,ax630c"
#define AX620E_FAMILY_COMPAT		"axera,ax620e"

/*
 * Watchdog. Boot-critical and unavoidably vendor-specific: U-Boot arms wdt0
 * for 30 s before `booti`, the ATF implements no PSCI system_reset, and the
 * register layout is not DesignWare (EN +0x00, TORR +0x0c, start +0x18,
 * count +0x24, kick +0x30 magic 0x61696370). Driver is #75.
 */
#define AX630C_WDT_COMPAT		"axera,ax630c-wdt"

/*
 * Clock controllers (#80). Nine windows in the vendor tree; eight here --
 * "axera,ax620x-isp-clk" is dropped because it never had an implementation,
 * in the vendor kernel or anywhere else. Each is also a "syscon": the windows
 * carry reset and pinmux-adjacent registers that other drivers need, so the
 * clock driver shares a regmap with them rather than mapping privately.
 */
#define AX630C_PLLC_CLK_COMPAT		"axera,ax630c-pllc-clk"
#define AX630C_CPU_CLK_COMPAT		"axera,ax630c-cpu-clk"
#define AX630C_COMMON_CLK_COMPAT	"axera,ax630c-common-clk"
#define AX630C_DISPC_CLK_COMPAT		"axera,ax630c-dispc-clk"
#define AX630C_FLASH_CLK_COMPAT		"axera,ax630c-flash-clk"
#define AX630C_MM_CLK_COMPAT		"axera,ax630c-mm-clk"
#define AX630C_PERIPH_CLK_COMPAT	"axera,ax630c-periph-clk"
#define AX630C_VPU_CLK_COMPAT		"axera,ax630c-vpu-clk"

/*
 * SD/eMMC host (#76). The IP is a stock Cadence SD4HC, so the SECOND
 * compatible is the real one and mainline sdhci-cadence is the driver; the
 * vendor-prefixed entry exists only to select SDHCI_QUIRK2_PRESET_VALUE_BROKEN
 * (pkgs/kernel-mainline/patches/0001-mmc-sdhci-cadence-add-axera-ax630c.patch).
 * A kernel without that patch still binds these nodes on "cdns,sd4hc" alone --
 * it just applies the controller's bogus presets.
 */
#define AX630C_SDHCI_COMPAT		"axera,ax630c-sd4hc"

#endif /* _DTS_AX630C_COMPAT_H */
