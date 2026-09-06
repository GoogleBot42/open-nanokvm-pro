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

#endif /* _DTS_AX630C_COMPAT_H */
