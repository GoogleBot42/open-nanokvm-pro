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

/*
 * Ethernet MAC (#77). Same shape as the SD host above: the IP is a stock
 * Synopsys DWMAC 4.10a and mainline stmmac drives it, but unlike the SD host
 * this one needs real glue -- the PHY interface select, the block reset and
 * the RGMII transmit clock mux all live in the flash syscon, outside the MAC's
 * window. So the vendor-prefixed compatible is the one the driver matches; the
 * generic "snps,dwmac-4.10a" second entry documents the IP for a reader.
 */
#define AX630C_DWMAC_COMPAT		"axera,ax630c-dwmac"

/*
 * GPIO (#81). Not a DesignWare block despite borrowing its register names:
 * one 32-bit word per line rather than one bit, so gpio-dwapb cannot bind and
 * there is no generic compatible to fall back on.
 */
#define AX630C_GPIO_COMPAT		"axera,ax630c-gpio"

/*
 * USB (#82). Same shape as the two above: the controller is a stock Synopsys
 * DWC3 and the mainline core node below it carries the plain "snps,dwc3". This
 * compatible is the OUTER glue node's -- an of-simple-class wrapper that owns
 * the clocks, the two software resets and VBUSVALID, all of which live in the
 * flash syscon outside the core's window.
 */
#define AX630C_DWC3_COMPAT		"axera,ax630c-dwc3"

/*
 * Video (#83). Three of ours and one syscon.
 *
 * The vendor names -- "axera,mipi", "axera,proton" and "axera, venc-encoder"
 * (the space in that last one is real) -- are deliberately NOT carried
 * forward. They name vendor blobs, not hardware; these are the compatibles of
 * the open drivers in drivers/media/platform/axera, so a kernel that binds
 * them is a kernel with the open stack and nothing else.
 *
 * The ISP syscon at 0x2500000 is the ninth clock window the #80 model dropped
 * for having no implementation anywhere. It carries the CSI receiver's clock
 * gates, its soft resets and the deskew-lock status word, so the video
 * drivers reach it as a plain syscon and write single-bit SET/CLR strobes --
 * no CCF or reset-controller model exists for these bits, in the vendor
 * kernel or ours.
 */
#define AX630C_ISP_SYSCON_COMPAT	"axera,ax630c-isp-syscon"
#define AX630C_CSI2RX_COMPAT		"axera,ax630c-csi2-rx"
#define AX630C_VIN_COMPAT		"axera,ax630c-vin"
#define AX630C_VC8000E_COMPAT		"axera,ax630c-vc8000e"

#endif /* _DTS_AX630C_COMPAT_H */
