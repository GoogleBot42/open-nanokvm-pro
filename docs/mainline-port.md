# Mainline port (#26): dependency inventory

The first deliverable of the #26 epic ("100 % NixOS on a mainline kernel",
staging decision 2026-09-04: straight to mainline, no 4.19 NixOS stage). This
document sizes the elephant [blob-replacement.md](blob-replacement.md) names in
passing — *the SoC has no mainline support* — peripheral by peripheral, and
fixes the boot-chain and rollback contract a mainline `Image` has to honour on
the existing vendor SPL/ATF/OP-TEE/U-Boot. Written 2026-09-05 from the repo, the
Nix-fetched vendor trees and the web; **no device reads** (the test unit was on
the vendor stack that day) — §9 lists the reads that would close the remaining
inferences.

- [Verdict](#verdict)
- [1. Upstream status](#1-upstream-status)
- [2. Hardware / driver inventory](#2-hardware--driver-inventory)
- [3. Our three open drivers on mainline](#3-our-three-open-drivers-on-mainline)
- [4. Memory map](#4-memory-map)
- [5. Boot-chain contract](#5-boot-chain-contract)
- [6. Rollback contract](#6-rollback-contract)
- [7. Minimum bring-up set and order of work](#7-minimum-bring-up-set-and-order-of-work)
- [8. Proposed child issues](#8-proposed-child-issues)
- [9. Device reads wanted](#9-device-reads-wanted)
- [10. Verified vs inferred; corrections to other docs](#10-verified-vs-inferred-corrections-to-other-docs)

Source trees referenced below: `[K]` = the Sipeed 4.19.125 kernel (flake input
`maix_ax620e_sdk_kernel`, `linux/linux-4.19.125/`), `[SDK]` = `maix_ax620e_sdk`
(boot chain, `build/projects/AX630C_emmc_arm64_k419_sipeed_nanokvm/`), `[UB]` =
`[SDK]/boot/uboot/u-boot-2020.04`.

---

## Verdict

**Mainline Linux has zero Axera support — but a vendor-submitted AX650 series
is live on LKML (v2, 2026-09-01), and every peripheral the appliance needs
below the video blocks is licensed IP with a driver already in mainline.** The
SoC skeleton is stock ARM (2× A53, GIC-400, arch timer, PSCI 1.0). UART, I2C,
SPI, USB, Ethernet, DMA and I2S are Synopsys DesignWare; eMMC/SD/SDIO is
Cadence SD4HC (`sdhci-cadence`). The genuinely Axera-custom drivers a port has
to write are **clk, reset, pinctrl, watchdog, GPIO, the `dma_per` peripheral
DMA engine, PWM glue, thermal/ADC, RTC** — each 0.3–1.7 kLOC of GPL 4.19
source in `[K]` to describe from; pinctrl's *data model* (551 single-group
functions, a 6855-line dtsi) is the largest single chunk. One SoC-wide catch
gates every "mainline driver binds" verdict: the vendor drivers bypass the
clock framework and gate their own clocks with raw writes into the periph
syscon (`0x4870000`; USB `0x10030000`), so the mainline drivers need a real
`clocks =` provider — at minimum a gate-only subset of the clk driver — before
anything U-Boot did not already clock (Ethernet, USB) comes up. The three
video drivers are ours already and were written for this move.

**Minimum set to boot NixOS on eMMC and reach SSH over Ethernet:** the mainline
core + `8250_dw` + `sdhci-cadence` + `stmmac` (+ a JLSemi PHY) + the **`ax_wdt`
port** (mandatory: U-Boot arms a 30 s hardware watchdog right before `booti`,
and PSCI on this ATF has no `SYSTEM_RESET` — reboot *is* the watchdog), with
clocks/resets/pinmux left as firmware configured them (`fixed-clock`s) for the
first boot.

**Biggest single risk:** the serial-less, `bootdelay=0` first boot of a kernel
that owns none of the SoC glue yet — every failure below Ethernet-up is
indistinguishable from "watchdog reset at 30 s" without UART0 on the hidden
pads. The A/B slot machinery makes it *safe* (a dead kernel falls back to slot
A) but not *observable*; §7 proposes the observability trick. Second risk:
the vendor DT prefix (`axera,` vs `axera-tech,`) is being decided on LKML right
now — do not upstream bindings until it settles.

---

## 1. Upstream status

Verified 2026-09-05 (URLs are the evidence).

### Linux

- **Nothing merged.** `torvalds/linux` at v7.3-rc1 has no
  `arch/arm64/boot/dts/axera/`, no `axera` in `vendor-prefixes.yaml`,
  `MAINTAINERS`, `drivers/soc/` or `drivers/` at all; neither does
  linux-next `next-20260904` nor `soc/soc.git for-next`.
  <https://github.com/torvalds/linux/tree/master/arch/arm64/boot/dts>,
  <https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/tree/arch/arm64/boot/dts>
- **A vendor series exists:** *"[PATCH v2 0/6] arm64: Introduce Axera AX650 SoC
  and AX650 Demo board"*, Leng Honglin `<lenghonglin@axera-tech.com>`,
  2026-09-01 (v1 2026-08-21). Adds the `axera` vendor prefix,
  `Documentation/devicetree/bindings/arm/axera.yaml`, `ARCH_AXERA`,
  `arch/arm64/boot/dts/axera/{ax650.dtsi,ax650-demo.dts}`, MAINTAINERS. The
  dtsi is 136 lines: 8× `arm,cortex-a55`, PSCI, `arm,gic-400`,
  `arm,armv8-timer`, one `snps,dw-apb-uart`. Boots to a shell with an
  embedded initramfs. Review is stalled: Krzysztof Kozlowski rejected v1's
  internal `Reviewed-by` tags and questioned the prefix (`axera.com` is not
  theirs); the author promised `axera-tech,` for v2 and then kept `axera,` —
  v2's only review reply (2026-09-03) is *"So how did you implement own
  comment?"*. No v3 yet.
  <https://lore.kernel.org/all/20260821-ax650-v1-v1-0-e1b013938e6b@axera-tech.com/>,
  <https://marc.info/?l=linux-kernel&m=178825452590736&w=2>
- **AX630C / AX620E / AX620Q: never mentioned on LKML or linux-arm-kernel.**
  All 19 Axera messages ever on LKML are the AX650 thread.

Consequence: if the AX650 series lands, `ARCH_AXERA` and the dts directory
exist and an `ax630c.dtsi` drops in beside `ax650.dtsi` with Axera-employed
maintainers already listed. If it dies, we would be first. Either way the
prefix spelling is unsettled — keep ours behind a single macro.

### U-Boot

Nothing, ever: u-boot v2026.07 has no `axera`/`ax6*` path, and the u-boot list
has no thread. <https://github.com/u-boot/u-boot>. The vendor U-Boot 2020.04
source *is* public (`[SDK]/boot/uboot/u-boot-2020.04/board/axera/ax620e_*`,
`arch/arm/mach-axera/`) and we already build and flash it from source
(`pkgs/boot.nix`), so U-Boot changes are ours to make (§5).

### Community

- **Axera itself publishes no GPL source.** `AXERA-TECH/ax620e_bsp_sdk` is
  app-layer only (`app/ build/ msp/`, BSD-3). The kernel/U-Boot GPL obligation
  is discharged only by OEMs.
  <https://github.com/AXERA-TECH/ax620e_bsp_sdk>
- **Sipeed publishes everything we build from**, including
  `model = "NanoKVM-Pro"` in `AX630C_emmc_arm64_k419_sipeed_nanokvm.dts`
  (last push 2026-09-02). <https://github.com/sipeed/maix_ax620e_sdk_kernel>,
  <https://github.com/sipeed/maix_ax620e_sdk>
- **M5Stack's tree is the cleaner reference for the vendor delta:**
  `dianjixz/module_LLM_linux` is pristine kernel.org 4.19.125 + a patch series
  (`patches/0001-linux-4.19.125-axera.patch`), so the Axera changes are
  isolated instead of pre-merged. U-Boot counterpart `dianjixz/module_LLM_uboot`.
  <https://github.com/dianjixz/module_LLM_linux>
- `scpcom/ax620e-bsp-build` builds U-Boot + kernel for NanoKVM-Pro from
  `nanokvmpro-4.19.y` / `nanokvmpro-2020.04` branches — still 4.19.
  <https://github.com/scpcom/ax620e-bsp-build>
- `onekvm/linux-6.18-ax620e` ("Linux 6.18 for NanoKVM Pro (AX630C) and NanoKVM
  Go (AX620Q)") is an **empty** repo created 2026-08-30 — declared intent,
  nothing started. <https://github.com/onekvm/linux-6.18-ax620e>
- No Armbian / Buildroot / OpenWrt / postmarketOS / Debian / Yocto entry for
  any Axera SoC. Chinese-language sources carry only product PR and NPU
  tutorials; no mainlining discussion anywhere.
- The **Radxa Fogwise Airbox is Sophgo SG2300X, not Axera** — there is no
  Radxa Axera board. Sipeed M4N-Dock (AX650N) ships the vendor stack.

Note both Sipeed's and M5Stack's trees carry files with an SPDX `GPL-2.0` tag
*and* an Axera "may not be copied or distributed" header — worth a legal skim
before vendoring text (describing-subagent specs sidestep it; see the
clean-room rule in CLAUDE.md).

### aic8800 (WiFi/BT)

No mainline driver, none in progress, not in `linux-firmware`. Best-maintained
out-of-tree GPL source: `radxa-pkg/aic8800` (pushed 2026-09-02; changelog "fix
building on kernels 7.1 and 7.2"; Armbian hard-skips ≥ 7.3 because cfg80211
changed `remain_on_channel`/`mgmt_tx` cookies and removed `probe_client`).
Debian/Ubuntu do not package it; Radxa's apt, Armbian, Gentoo (orphaned) and
AUR do. <https://github.com/radxa-pkg/aic8800>. The firmware blob is the one
closed item our policy permits; pin it by the per-file MD5s in
`radxa-pkg/aic8800/src/firmware_version.md`. WiFi is explicitly not a
constraint on #26 (issue text) — carry it as an out-of-tree module on a kernel
≤ 7.2, or drop it.

---

## 2. Hardware / driver inventory

Every DT node the NanoKVM-Pro board file leaves enabled, plus the SoC
essentials. Compatibles are verbatim from `[K]/arch/arm64/boot/dts/axera/AX620E.dtsi`
and the board dts (note the stray spaces in `"axera, venc-encoder"` etc.).
Vendor driver LOC is `wc -l`. "IP" column: what the register interface is, with
the evidence class — **V** = verified from driver source/registers, **I** =
inferred from names. Effort: S ≤ 1 day, M = days, L = weeks. Gates: **boot**
(no rootfs/SSH without it), **KVM** (the appliance function), **opt** (nice to
have / can be dropped).

### SoC core

| Block | DT | Vendor driver | IP / mainline | Port needs | Effort | Gates |
|---|---|---|---|---|---|---|
| CPUs | `arm,cortex-a53` ×2, `enable-method = "psci"`, OPP table | arch | standard | DT only | S | boot |
| PSCI | `arm,psci-1.0`, `method = "smc"` (TF-A 2.7 `plat/axera/ax620e`) | `drivers/firmware/psci` | standard — **but** the ATF implements no `system_off`/`system_reset` (`ax620e_pm.c` ops table, V) | reboot must come from the watchdog restart handler (below) | — | boot |
| GIC | `arm,gic-400` @`0x1850000` (GICv2) | `irq-gic` | standard | DT only | S | boot |
| Timer | `arm,armv7-timer`, 24 MHz, `arm,cpu-registers-not-fw-configured` | `arch_timer` | standard | DT only | S | boot |
| OP-TEE | `linaro,optee-tz` (OP-TEE 3.21, 32 MB `no-map` @`0x44200000`) | `drivers/tee/optee` (`CONFIG_OPTEE=y`) | standard; **nothing in the vendor stack uses it** (no `TEEC_*`, no `tee_*` imports in any blob, V) | keep the `no-map` reservation (ATF firewalls it); `CONFIG_OPTEE` optional | S | boot (the reservation) |
| Clocks | 9 provider nodes `axera,ax620x-{cpu,common,dispc,flash,isp,mm,periph,vpu,pllc}-clk` + `syscon` (`0x1900000`, `0x2340000`, `0x4600000`, `0x10030000`, `0x2500000`, `0x4430000`, `0x4870000`, `0x4030000`, `0x2210000`); 493 IDs in `dt-bindings/clock/ax620e-clock.h`, 247 registered | `drivers/clk/axera/clk-ax620e.c` 572 + `clk.c` 668 LOC (`clk.c` is a rename-fork of `drivers/clk/hisilicon/clk.c`) | Axera-custom: 86 gates (all one flag → `clk_hw_register_gate`), muxes/dividers, **one** runtime-programmed fractional-N PLL (CPUPLL); the other PLLs are bootloader-set and modelled as `fixed_factor` (V) | **new driver** (table-driven CCF, ~1.5–2 kLOC); a gate-only subset is enough for bring-up because the vendor peripheral drivers each gate their own clock via the periph syscon — mainline drivers will expect `clocks =` instead | M | boot |
| Resets | 18 provider nodes `axera,axera_reset_match` + `syscon`, `#reset-cells` = 3 (`<bit reg polarity>`), 4 (`<set_bit set_reg clr_bit clr_reg>`) or 10 (4-cell + a clock gate closed across the reset) — all data in consumer phandle args | `drivers/reset/axera_reset/axera_reset.c` 298 LOC | Axera-custom SET/CLR reset controller (V) | **new driver**; mainline wants `#reset-cells = <1>` + an in-driver table harvested from the ~60 consumers (`reset-simple` cannot express the vendor specifier) | S–M | boot |
| Pinctrl / pinmux | `axera,ax620e-pinctrl` @`0x2300000` (+`0x104f0000`); 6855-line `AX620E_pinctrl.dtsi` = 111 pins × 551 single-group functions / 563 states. **The board relies on a replayed table, not DT states:** `drivers/soc/axera/pinmux/ax_pinmux.c` self-registers at `arch_initcall` and writes the SDK `AX630C_DEMO_pinmux.h` `<addr,value>` pairs (~66 writes, incl. `0x02300060 = 0x00060003` VI_D7 → GPIO0_A7); U-Boot applies the same table first. The board dts `/delete-property/`s `pinctrl-0` on every I2C node | `drivers/pinctrl/axera/pinctrl-ax620e.c` 728 + `ax_pinmux.c` 225 LOC | Axera-custom, one word per pad, stride `0xC`, function `[18:16]`, pull `[7:6]`, drive `[3:0]` (V) | **new driver + remodelled DT** (~30 real multi-group functions, regenerated dtsi, I2C states restored). Not needed for first boot (U-Boot's table pass persists). This is also the **root of the SW_PWR trap**: the DEMO table muxes VI_D7 to GPIO at init, capture re-muxes it, nothing re-applies; `gpio-axera` overrides `chip.request` with a no-op so `pinctrl_gpio_request()` never runs — a correct mainline pinctrl+GPIO pair fixes it for free | **L** (data model) | KVM |
| GPIO | `axera,ax-apb-gpio` ×4 (`0x4800000`, `0x4801000`, `0x6000000`, `0x6001000`, SPI 114–117), 128 `gpio-ranges` | `drivers/gpio/gpio-axera.c` 538 LOC (defconfig also has `GPIO_DWAPB=y`, unused) | DesignWare *names* only: **one 32-bit register per GPIO** at `base + (n+1)*4` with DR/DDR/INTEN/… as bit fields, relocated port regs (`EXT_PORTA 0x8c`, secure/non-secure INTSTATUS `0x84/0xa4`), raw clock pokes at `0x4870000` (V) | **new driver** (~500 LOC); `gpio-dwapb` cannot bind | S–M | KVM (ATX, panel, LT6911 pins) |
| Watchdog | `axera,ax-wdt` @`0x4840000` (wdt0) + `0x6040000` (wdt2) | `drivers/watchdog/ax_wdt.c` 514 LOC (`CONFIG_AX_WATCHDOG=y`, `NOWAYOUT=y`) | **not** DesignWare: EN `+0x00`, TORR `+0x0c`, start `+0x18`, count `+0x24`, kick `+0x30` magic `0x61696370` (V) | **new driver, mandatory**: U-Boot arms wdt0 for 30 s before `booti`; the vendor kernel pets it from the WDT's own ISR and reboots through `ax_wdt_restart()` because PSCI reset is absent | S | **boot** |
| Thermal + ADC | `axera,ax620e-tsensor` @`0x2000000` (trips 80/105/120 °C) and `axera,ax620e-adc` (no `reg`; the driver `ioremap`s the *same* `0x2000000` block — one analog-monitor IP). `in_voltage0_raw` is the **board-id** the loader turns into DRAM size / pool geometry | `drivers/thermal/axera_thermal.c` 487 + `drivers/iio/adc/axera_adc.c` 307 LOC | Axera-custom 10-bit sensor block (V). **Thermal is decorative today**: no `cooling-maps` anywhere, `CPU_THERMAL` off, the 120 °C trip is typed `passive` — the SoC neither throttles nor shuts down | one new driver exposing `#thermal-sensor-cells` + `#io-channel-cells` (~200 LOC); DRAM size becomes a per-board DT fact | S | opt |
| UID / identity | `ax,ax_hwinfo` → `/proc/ax_proc/uid`, read by the initramfs for `device_key` → MAC + hostname | `drivers/soc/axera/ax_hwinfo/ax_hwinfo.c` 261 LOC | **not an efuse peripheral**: it `memcpy`s the `misc_info_t` the bootloader leaves in IRAM0 at `0x740` (`uid_l/uid_h` at `+0x48/+0x4c`; `include/linux/soc/axera/ax_boardinfo.h`) (V) | tiny `nvmem` (or `syscon`) over that IRAM window, **or** have our U-Boot derive `ethaddr` from the UID and let its existing `fdt_fixup_ethernet()` write `local-mac-address` (no kernel driver at all). Without either, every unit gets the same MAC | S | KVM (identity) |
| RTC | `axera,axi-top-rtc` | `drivers/rtc/rtc-axera.c` 479 LOC ("DesignWare Real Time Clock Driver", password `0x61696370`) | DW-*named*, no mainline DW RTC exists (V) | new driver, or none (no battery is known on the board) | S | opt |
| cpufreq | `AXERA_CPUFREQ=y`, `AX620E_opptable.dtsi` | `drivers/cpufreq/axera-cpufreq.c` | `cpufreq-dt` once the clk driver exists | DT + clk | S | opt |
| DMA | `axera,axi-dma-1.01a` @`0x48b0000` (SPI 113); **`axera,dma-per` @`0x48a0000`** (SPI 112, 16 ch); `axera,dma` @`0x10460000` | `drivers/dma/axera-axi-dmac/` 1547 LOC (**not built**; Synopsys/Paltsev header verbatim); `drivers/dma/axera-dma-per/` 1317 LOC (`=y`, custom); `soc/axera/dma/dma.c` has no Makefile entry (dead node) | AXI DMAC = stock `dw-axi-dmac` (V, header); **`dma_per` is Axera-custom and is the engine behind every UART/SPI/I2S DMA channel — incl. `i2s_slv0` 16/17 = HDMI audio** | AXI DMAC: rename the compatible. **`dma_per`: new dmaengine driver** if I2S audio must use DMA (designware-i2s has a PIO mode; try that first) | S / M | opt (audio) |
| ramoops | `ramoops` reserved-memory @`0x48000000` | pstore | standard | DT only | S | opt |
| Vendor SoC glue never needed | `axera,cmm`, `axera,sys`, `axera,ax_sysmap`, `axera,logctl`, `axera,bw_limiter`, `axera,ddr_dfs`, `axera,perf_bm`, `axera,firewall`, `axera,ax_gzipd`, `axera,hwspinlock-r1p0`, `axera,mailbox` (RISC-V companion), `ax,hrtimer`, `axera,wake-timer`, `axera, deb-gpio-lp`, `axera_memory_dump`, `axera_ddr_retrain`, `axera,avs` | `drivers/soc/axera/*` (11.7 kLOC total) | — | **drop** (the KVM stack was device-proven with the ax base stack rmmod'd, #55 M3) | — | — |

### Storage, network, USB

| Block | DT | Vendor driver | IP / mainline | Port needs | Effort | Gates |
|---|---|---|---|---|---|---|
| eMMC | `axera,sdhc` @`0x1B40000` (`mmc0`), HS400-ES, 8-bit, `cdns,phy-*` tuning props, 3 resets (`prst`/`arst`/`cardrst`), hw-reset GPIO2_A23 | `drivers/mmc/host/sdhci-axera.c` 1208 LOC | **Cadence SD4HC** — the vendor file is `sdhci-cadence.c` (Socionext header intact, `sdhci_cdns_*` names kept) with Axera additions; DT already uses the mainline `cdns,phy-*` properties (V) | `sdhci-cadence` (`cdns,sd4hc`) + `clocks =` (vendor gates by hand via `ax_set_mmc_clk`) + the three resets; `hw-reset = <&gpio>` is not a mainline binding (drop or `reset-gpios`); diff 1208 vs ~460 LOC for Axera-only tuning | S–M | **boot** |
| SD | `axera,sdhc` @`0x104E0000` (`mmc1`), UHS to SDR104, `broken-cd` | same | same | same | S | opt (test path) |
| SDIO | `axera,sdhc` @`0x104D0000` (`mmc2`), no-1.8V, WiFi | same | same | same | S | opt (WiFi) |
| Ethernet MAC | `axera,dwmac-4.10a` @`0x104C0000`, 5 clocks, 3 resets, `phy-mode = "rgmii"`, `snps,dwmac-mdio` | `drivers/net/ethernet/stmicro/stmmac/dwmac-axera-plat.c` 187 LOC glue over stmmac | **Synopsys DWMAC 4.10a** (V) | stmmac `dwmac-generic` or a ~100-line glue (clock names, PHY reset GPIO1_A27) | S–M | **boot** (SSH) |
| Ethernet PHY | `ethernet-phy-id937c.4030` (JLSemi **JL2101**), 20 `jl2xxx,*` tuning props | `drivers/net/phy/jlsemi.c` 561 + `jlsemi-core.c` 3043 LOC | no JLSemi driver in mainline (V); the generic C22 PHY driver drives RGMII PHYs fine unless RGMII delays must be set in-PHY | try genphy first; else a describing-subagent spec of the RGMII-delay/LED registers → small driver | S–M | **boot** (SSH) |
| WiFi/BT | `aicsemi,aic_bsp` (reset GPIO1_A29) + SDIO | `drivers/net/wireless/aic8800/` (`aic8800_bsp/btlpm/fdrv`, `=m`) | out-of-tree vendor GPL driver, see §1 | carry `radxa-pkg/aic8800` on a ≤ 7.2 kernel + the firmware blob; or drop | M | opt |
| USB | `axera,dwc3` glue → `snps,dwc3` @`0x8000000`, `dr_mode = "otg"`, `extcon` = `linux,extcon-usb-gpio` (GPIO1_A4), `phy_type = "utmi"`, high-speed only | `drivers/usb/dwc3/dwc3-axera.c` 531 LOC ("DesignWare USB3 OF Simple Glue Layer"); PHY handling is one `USB2_PHY_SW_RST` bit (V) | **Synopsys DWC3** (V) | `dwc3` + `dwc3-of-simple`-class glue (one reset bit + clocks); gadget functions the app uses (`hid`, `mass_storage`, `ncm`, `uac2`, `acm`) are all mainline configfs — only `f_udisp` (USB display) is vendor and unused | M | KVM (HID) |

### Board peripherals

| Block | DT | Vendor driver | IP / mainline | Port needs | Effort | Gates |
|---|---|---|---|---|---|---|
| UART0/1/2 | `axera,ax-apb-uart` @`0x4880000/0x4881000/0x4882000`, `reg-shift = 2`, `reg-io-width = 4`, 208 MHz | `drivers/tty/serial/8250/8250_axera.c` 542 LOC (a `8250_dw.c` fork) | **Synopsys DW APB UART** (V; `earlycon=uart8250,mmio32` already works) | `snps,dw-apb-uart` + `8250_dw`, `clock-frequency = <208000000>` | S | boot (debug only — hidden pads) |
| I2C0, I2C7 | `snps,designware-i2c` @`0x4850000`, `0x4857000` | mainline `i2c-designware` (unmodified compatible) | DW (V) | DT only. **I2C0 carries the LT6911UXC at `0x2b`** (hard-coded in `lt6911_manage.h`, no DT node); I2C7 carries the hynitron touch | S | KVM |
| HDMI-RX bridge | Lontium LT6911UXC — no DT node; `lt6911_manage.c` (2907 LOC, ours from source) opens I2C bus 0 @`0x2b` and raw GPIOs 60 (INT), 5 (PWR), 6, 82, 83, 21, 81; exposes `/proc/lt6911_info/*` | `drivers/misc/lt6911_manage.c` (`CONFIG_LT6911_MANAGE=m`) | mainline has `lt6911uxe` (6.14+) — a different chip, V4L2-subdev shaped | keep our driver out-of-tree with a DT node (`lontium,lt6911uxc`, i2c child of `i2c0`, GPIO phandles) and the `/proc` ABI libkvm reads; a V4L2-subdev rewrite is an upstreaming nicety, not a port need | S–M | KVM |
| SPI2 + panel | `snps,dw-apb-ssi` @`0x6072000`; `jadard,jd9853` @cs1, 80 MHz, dc/reset/te GPIOs | `spi-dw-mmio` (mainline) + `drivers/staging/fbtft/fb_jd9853.c` (GPL, in the SDK tree) | DW SSI (V); fbtft has no JD9853 upstream | DT only for SPI; port `fb_jd9853` onto current staging fbtft (S) or write a `drm/tiny` panel (M) | S–M | opt (mini-display) |
| Backlight | `pwm-backlight` ← `axera,ax620e-pwm` @`0x6060000` | `drivers/pwm/pwm-axera.c` 527 LOC | DW APB timer in PWM mode — offsets match mainline `pwm-dwc.h` (V per §1 research; `PWM_TIMERN_MODE 0x1E`) | `pwm-dwc-core` + platform/OF glue (mainline's `pwm-dwc` front-end is PCI; check whether the target kernel already has an OF variant) | S | opt |
| Knob / button / LED | `rotary-encoder`, `gpio-keys`, `gpio-leds` (heartbeat GPIO0_A23) | mainline | standard | DT only (needs GPIO) | S | opt |
| Touch | `hyn,8xxt` @I2C7 `0x15` | `drivers/input/touchscreen/hyn/` ~800 LOC | Hynitron; mainline `hynitron_cstxxx` is a different family (I) | not used by our display daemon → drop | — | — |
| SPI1 / SPI4 | `snps,dw-apb-ssi` @`0x6071000` (spidev), `snps,dwc-ssi-1.03a` @`0x1A00000` (`spi-nand`, unpopulated) | `spi-dw-mmio` | DW (V) | drop / DT only | S | — |
| Audio | `simple-audio-card` "Lontium Lt6911UXC" ← `i2s_slv0` `axera,dwc-i2s-slv` @`0x6051000` (`hdmi-i2s`) + `dummy-codec` | `sound/soc/axera/dwc-i2s.c` 993 LOC | Synopsys DW I2S — a fork of `sound/soc/dwc/dwc-i2s.c` (upstream author/path kept) (V); the 17 `i2s-*-sel` props pack into one 24-bit routing word written to reg[1] | `designware-i2s` + syscon glue for the routing word + mainline `snd-soc-dummy` instead of the Sipeed `dummy-codec` stub; **DMA needs the `dma_per` driver** (or PIO); libkvm's ALSA capture is unchanged | M | KVM (audio; optional) |
| Extcon | `linux,extcon-usb-gpio` | mainline | standard | DT only | S | KVM (OTG) |

### Video path (ours)

| Block | DT | Driver | Port needs | Effort | Gates |
|---|---|---|---|---|---|
| CSI-2 / D-PHY receiver | `axera,mipi` @`0x2600000`, IRQs `csictrl0/1` — no clocks/resets in the node | `pkgs/open-vin-csi2` (1078 LOC, ours, M1 #57). The controller half looks **Cadence CSI2RX-derived** (I: blob symbols `csi2rx_soft_reset/static_cfg`; lane map at `+0x08` and stream ctrl at `+0x100` match mainline `cdns-csi2rx`'s `STATIC_CFG_DLANE_MAP` / `STREAM_BASE(0)`) — worth a compare against `cdns-csi2rx.c` before upstreaming; the D-PHY glue stays Axera-custom | §3 | M | KVM |
| VIN/IFE bypass capture | `axera,proton` @`0x2400000`, `GIC_SPI 27/28`, clocks | `pkgs/open-vin-capture` (1664 LOC, ours, M2 #59) | §3 | M | KVM |
| VC8000E encoder (VCMD) | `"axera, venc-encoder"` @`0x4010000`, `GIC_SPI 93` | `pkgs/vc8000-vcmd` (eswin 6.6 VCMD core 4970 LOC + our 292+280 LOC glue, #25) | §3 | S–M | KVM |
| Unused video IP | `axera,jpeg-encoder` (we soft-JPEG), `"axera, video-decoder"`, `vpp`, `gdc`, `ive`, `tdp`, `npu`, `drm/crtc/vo/dsi/lvds/bt-dpi`, `mipi_switch`, `vfb` | vendor blobs (deleted, #54) | **drop** — never touched by the KVM path | — | — |

The vendor defconfig also lacks what NixOS' systemd needs (`# CONFIG_NAMESPACES
is not set`, no cgroup controllers, no `TMPFS_XATTR`/`OVERLAY_FS`) — moot on
mainline, where we write the config; recorded so nobody copies the vendor
defconfig forward.

---

## 3. Our three open drivers on mainline

They were designed for this move ([deblob-capture.md](deblob-capture.md)); the
concrete deltas, from the sources:

- **`v4l2_async_subdev` name matching is gone.** `open_vin_capture` binds
  `open_vin_csi2` by platform-device name (`csi2_devname = "2600000.mipi_rx"`)
  because the vendor DT has no port/endpoint graph and changing the dtb meant a
  slot flash. Mainline (6.6+) has only fwnode matching
  (`v4l2_async_connection`, `v4l2_async_nf_add_fwnode_remote`). The
  `TODO(mainline)` in `open_vin_capture.c` (fwnode graph +
  `v4l2_fwnode_endpoint`) is therefore **mandatory**, and the mainline DT must
  carry `ports { port { endpoint … } }` on both nodes — plus, for a complete
  graph, an LT6911UXC endpoint feeding the receiver.
- **Fixed-address `devm_ioremap` of shared glb blocks** (`open_vin_csi2.c`:
  `isp_sys_glb 0x02500000`, D-PHY `0x023f0000`, `common_glb 0x02340000`;
  `open_vin_capture.c`: `OVC_CLKRST_PHYS`). The `TODO(mainline)` says syscon
  phandles; do that (`syscon`/`regmap` for the SET/CLR shadow words), and add a
  real `reg` entry for the D-PHY file. The reset sweeps the capture driver does
  by hand at bring-up become `resets =` consumers once the reset driver exists.
- **Carveouts.** All three take `*_base/*_size` module parameters computed by
  the shell loader (§4) and call `dma_declare_coherent_memory()`. On mainline
  the same memory becomes `reserved-memory` nodes (`shared-dma-pool`,
  `no-map` or reusable CMA) referenced by `memory-region`, and
  `of_reserved_mem_device_init()` replaces the parameters; the VCMD glue's
  `platform_device_register_simple` + hand-set `coherent_dma_mask` (#63) is
  replaced by an ordinary DT-bound platform device. No IOMMU on this SoC
  (`CONFIG_IOMMU_SUPPORT` off, no SMMU node), so bus == phys stays true.
- **Private control IDs** (`OPENVIN_CID_BASE = V4L2_CID_USER_BASE + 0x10a0`)
  need an official range for submission — cosmetic for the port.
- **The VCMD core is already mainline-era code** (eswin `linux-6.6.18-EIC7X`,
  five `LINUX_VERSION_CODE` shims for 4.19); porting *removes* shims. Only the
  292-line glue and the 280-line framebuf allocator are 4.19-shaped.
- **The pinmux dependency is real but deferred:** the CSI receiver deliberately
  does not touch `0x02300000`; a cold boot of the purged image streams because
  U-Boot (and then the kernel's `ax_pinmux` `arch_initcall`) replay the SDK
  DEMO pad table. On mainline only U-Boot's pass remains until pinctrl exists,
  at which point the pads move into DT `pinctrl-0` states.
- `lt6911_manage.c` also **writes pinmux registers directly**
  (`0x104F006C`, `0x02300048`, `0x02300054`) — the same trap class as SW_PWR;
  those become pinctrl states too.
- `lt6911_manage.c` is the fourth driver to carry: 4.19 legacy GPIO numbers and
  `i2c_get_adapter(0)` → DT node with GPIO descriptors; `/proc/lt6911_info`
  ABI kept (libkvm and the display daemon read it).

---

## 4. Memory map

Today: the DT `memory@40000000` claims 3 GiB (`0xC0000000`) — wrong for the
1 GiB NanoKVM-Pro — and the kernel is bounded by `mem=` alone: U-Boot never
fixes up the memory node (`CONFIG_ARCH_FIXUP_FDT_MEMORY` off) but rewrites the
`mem=` clause from the board-id (`[UB]/arch/arm/mach-axera/ax620e/ax620e.c`
`board_late_init`; the device's live cmdline shows `mem=824M`,
`pkgs/sd-image.nix`). The shell loader then derives the pool from the same
board-id ADC read: pool `0x73800000–0x80000000` (200 MiB) split into encoder
frame buffers `0x73800000 +136 MiB`, capture `0x7C000000 +56 MiB`, VCMD
coherent `0x7F800000 +8 MiB` (`pkgs/rootfs/ax-load-drv.sh` `compute_mem_map`,
[vcmd-cma-unblock.md](vcmd-cma-unblock.md#dma-memory-map-53)).

Mainline shape: a per-board `memory@40000000` with the true size (the board
variants differ only here; the ADC board-id becomes a build-time DT choice or a
U-Boot memory fixup we add), `reserved-memory` nodes for the three carveouts
(`0x44200000 +32 MiB` OP-TEE and `0x40040000 +256 KiB` ATF stay `no-map`;
ramoops optional), and CMA *allowed* — the #49 "CMA is a blob ABI break" only
applied while vendor `.ko` shared struct layouts with our kernel. With the
mainline `vb2-dma-contig` path the capture carveout could even become plain CMA;
the encoder's 136 MiB is best kept a dedicated pool (bus-address stability for
the register program).

---

## 5. Boot-chain contract

Can a mainline `Image` + our DT boot from the existing SPL/ATF/OP-TEE/U-Boot
and slot layout? **Yes, with four traps.** Facts, all read from `[UB]` /
`[SDK]` source (key ones spot-checked at the cited files):

**How U-Boot boots today.** `bootcmd` is not compiled in; `board_late_init()`
→ `setup_boot_mode()` sets `bootcmd=axera_boot` on *every* boot
(`[UB]/cmd/axera/setup_boot/setup_boot.c`). `do_axera_boot()`
(`[UB]/cmd/axera/boot/axera_boot.c`) raw-reads the `kernel`/`kernel_b` and
`dtb`/`dtb_b` partitions by name into `0x5C500000`/`0x5C400000`, checks the
1 KB header (magic `0x55543322`, word checksum; RSA only if the
`SECURE_BOOT_EN` efuse is burned — it is not), decompresses the ax_gzip payload
with the gzipd hardware to `0x40200000` (kernel) / `0x40001000` (dtb), then
`booti 0x40200000 - 0x40001000`. Partition caps: kernel 64 MiB, dtb 1 MiB,
both compressed. Slot choice is `CONFIG_SUPPORT_AB` reading the same register
as the SPL (§6). No initramfs is passed — the vendor kernel embeds one. A
mainline `Image` is exactly what `booti` wants; `pkgs/slot-image.nix` already
packages arbitrary payloads into the header format.

**Trap 1 — `blkdevparts=` is U-Boot's partition table.** U-Boot never reads
GPT/MBR from eMMC: `get_part_info()` (`[UB]/cmd/axera/update/sparse_img.c`)
parses the `blkdevparts=mmcblk0:…` substring out of the `bootargs` env and
sums sizes. If `bootargs` lacks it, U-Boot **silently resets the env to the
vendor `BOOTARGS_EMMC`** (Sipeed edit, `sparse_img.c` "bootargs is a bad
value, will use default") — and that string then reaches the kernel. Any
cmdline we set must keep the full `blkdevparts=` clause (the mainline kernel
ignores it harmlessly; `CONFIG_BLK_CMDLINE_PARSER` can even honour it).

**Trap 2 — `/chosen/bootargs` comes from the env, and must fit.** `booti` →
`image_setup_libfdt()` → `fdt_chosen()` writes env `bootargs` over
`/chosen/bootargs` (the env *does* win — `pkgs/dtb.nix`'s header note saying
otherwise is stale; the SD boot showed the env string verbatim). `booti` skips
`BOOTM_STATE_FDT`, so the blob is never relocated/padded; `fdt_setprop` needs
free space in the blob or `fdt_chosen` fails and `boot_prep_linux()` calls
`hang()`. Today it works because the DT and env strings are the same length.
**Build the mainline dtb with slack** (`dtc -p 4096`, or a long placeholder
`bootargs`) — a one-line fix that otherwise costs a silent hang. Also: U-Boot
`board_late_init` dereferences `strstr(bootargs, "mem")` on the env value, so
never *delete* env `bootargs`, only rewrite it.

**Trap 3 — the 30 s watchdog.** `do_axera_boot()` calls `wdt0_enable(1)`
(`ax620e.c`: TORR = 30 s @ 24 MHz, response mode = system reset) immediately
before `booti`. The vendor kernel's `ax_wdt` probes early and pets the dog
from its own IRQ. **A mainline kernel without an `axera,ax-wdt` driver is
hard-reset ~30 s after `booti`, every boot** — indistinguishable from a
crash without serial. Options: port `ax_wdt` (preferred — it is also the
restart handler, next trap), or patch our U-Boot to not arm it, or disarm it
from an early platform quirk.

**Trap 4 — no PSCI reset.** The ATF's `plat_psci_ops` has no
`system_reset`/`system_off` (`ax620e_pm.c`, verified), and the vendor kernel
patches `arch/arm64/kernel/process.c` to `if (0) arm_pm_restart(...)` so that
`do_kernel_restart()` reaches `ax_wdt_restart()` (watchdog timeout 0). On
mainline, `psci_sys_reset` returns `NOT_SUPPORTED` and the restart notifier
chain falls through to a registered watchdog restart handler — so the
`ax_wdt` port with `watchdog_set_restart_priority()` gives us `reboot` for
free, and `poweroff` stays a hang (as today).

**`mem=`.** U-Boot rewrites `mem=` from the board-id; the kernel may keep
honouring it or carry a correct memory node and ignore it (§4).

**Initramfs contract.** The vendor `/init`
(`[SDK]/build/projects/…/initramfs/init`, carried verbatim by
`pkgs/initramfs.nix`) is documented in
[nixos-rootfs.md](nixos-rootfs.md#the-rootfs-contract). Mainline-specific
additions: it reads **`/proc/ax_proc/uid`** for `device_key` (a vendor
`ax_hwinfo` proc node — absent on mainline, so the derived MAC degenerates to
one constant for every unit); it greps `dmesg` for an ext4 message text; it
hard-codes `mmcblk0p17` for the resize check; `boot_key=` recovery is dead
code (nothing sets it; `/boot/rec` is the live trigger). NixOS brings its own
initrd (`boot.initrd.systemd`), so the vendor script is replaced, not ported —
but `/boot` (p16, vfat) must stay mounted and writable (the server writes
`usb.*` flag files there) and the identity derivation moves to an nvmem-backed
service.

**ATF as a BL33 host for a future mainline U-Boot:** BL33 is entered at EL1
with `x0 = hw_config`, standard TF-A `bl_params_t`, no signature check
(`TRUSTED_BOARD_BOOT` unset); the SPL passes `dtb_addr = 0`, so a mainline
U-Boot would need `OF_EMBED`/`OF_SEPARATE`, link at `0x5C000400`, fit 1536 KiB,
and carry an AX630C board port. Feasible, not needed for #26.

---

## 6. Rollback contract

**Mechanism (verified in `[SDK]/boot/bl1/core/boot/boot.c` `select_slot_ab`,
`[UB]` `set_slot_ab`, and the vendor `S99checkboot`):**
`TOP_CHIPMODE_GLB_BACKUP0 = 0x02390024` (`_SET +4`, `_CLR +8`) holds
`SLOTA BIT(2)`, `SLOTB BIT(3)`, `SLOTA_BOOTABLE BIT(4)`, `SLOTB_BOOTABLE BIT(5)`
(plus `BOOT_SD`, `BOOT_KERNEL_FAIL`, `BOOT_PANIC`, `BOOT_WDT_TIMEOUT`,
`OTA_*` flags). The SPL **consumes** the current slot's BOOTABLE bit on every
boot; a slot whose BOOTABLE bit is already clear means "failed once" → flip
to the other slot. U-Boot re-reads the register (`bootsystem=A|B`, uppercase,
`env_save()`d every boot) and picks `kernel`/`dtb` vs `_b`. Userspace re-arms
the current slot every boot (`devmem 0x2390028 32 0x10|0x20`). A dead kernel
never re-arms → watchdog reset → SPL flips. Hardware-proven for the kernel
half ([flashing-and-recovery.md](flashing-and-recovery.md#slot-b-kernel-testing-proven-procedure-2026-08-30)).

Three properties that shape the NixOS design:

1. **The register does not survive a power cycle.** `select_slot_ab`'s first
   branch (`slota == 0 && slotb == 0` → "power off boot, slot A") is the SPL's
   own statement of that. Every cold boot lands on A with `SLOTA_BOOTABLE`
   clear; the *next* reboot flips to B unless userspace re-armed. Rollback
   state is warm-reset-only.
2. **The vendor watchdog guards only the kernel.** It is petted from the
   watchdog's own ISR; nothing opens `/dev/watchdog`. A kernel that boots into
   a dead userspace never triggers failover — unless userspace is what re-arms
   the slot, which is exactly the lever: **re-arm only after a health check**
   (sshd + `nanokvm.service` up, link up) and the next reboot falls back on its
   own. Add systemd's `RuntimeWatchdogSec` on the ported `ax_wdt` so a hung
   userspace also reboots.
3. **`/etc/fw_env.config` is derivable from source** and closes the TODO in
   nixos-rootfs.md: `CONFIG_ENV_OFFSET = 0x4C0000` (sum of the six preceding
   partitions), `CONFIG_ENV_SIZE = 0x100000`, eMMC user area, non-redundant →
   `/dev/mmcblk0 0x4C0000 0x100000`. Verify with a hexdump before the first
   `fw_setenv`. Note U-Boot rewrites the env **twice per boot**
   (`set_slot_ab`, `update_cmdline`), so userspace `fw_setenv` must not race a
   reboot.

**Recommendation: keep the vendor A/B for kernel+dtb; NixOS generations own
userspace; health-gated re-arm makes rollback automatic.** Reasons:

- *(b) U-Boot bootcount + extlinux* (the stock NixOS ARM path,
  `boot.loader.generic-extlinux-compatible`) would need `DISTRO_DEFAULTS`,
  `CMD_SYSBOOT`, `HUSH_PARSER`, `CMD_PART`, `BOOTCOUNT_*` (all off) **and** a
  patch to `setup_boot_mode()`, which overwrites `bootcmd` every boot.
  Filesystem loads themselves work (`ext4load`/`fatload` exist; `sd_boot`
  already `ext4load`s), but U-Boot still has no eMMC partition table without
  `blkdevparts=`. More U-Boot surgery than (a), and it discards the SPL-level
  ATF/OP-TEE/U-Boot failover.
- *(c) mainline U-Boot as BL33* is feasible (§5) but orthogonal; do it later
  if we want `bootflow`/EFI.
- *(a)* needs nothing new in firmware: the kernel slot holds "the NixOS
  kernel" (mainline `Image` + initrd fit the 64 MiB cap trivially; the 1 MiB
  dtb cap is the only tight one), `switch-to-configuration` swaps the
  userspace generation atomically in the rootfs, `nanokvm-checkboot.service`
  (already scaffolded in `nixos/appliance.nix`, inert only for want of
  `fw_env.config`) becomes `After=nanokvm-healthy.target`. A kernel/dtb update
  writes the *other* slot and flips `bootsystem` via `systemB`/`systemA`
  semantics; if the new kernel dies, SPL falls back; if it boots but the system
  is unhealthy, nothing re-arms and the next reboot (forced by the systemd
  watchdog) falls back. The dual-slot write strategy in
  [updates.md](updates.md) already matches this model.

Open validation (unchanged from updates.md): the SPL→U-Boot slot-B failover
for ATF/OP-TEE/U-Boot has never been exercised on hardware; the kernel-slot
half has.

---

## 7. Minimum bring-up set and order of work

Minimum to boot NixOS from eMMC p17 and reach SSH over Ethernet, in the order
the kernel needs them:

1. Core: `ARCH_AXERA`-equivalent (or plain arm64 multiplatform), GIC-400,
   arch timer, PSCI — DT only.
2. `ax_wdt` port — pets the U-Boot-armed dog, provides reboot.
3. `8250_dw` on UART0 (console for the day someone solders the pads; also
   `earlycon`).
4. Resets (S) + a **gate-only clk driver** (the vendor peripheral drivers
   gate their own clocks, so mainline drivers will find Ethernet/USB clocks
   off unless someone enables them; `fixed-clock`s suffice only for what
   U-Boot already used — UART, eMMC) → then the full clk driver.
5. `sdhci-cadence` on eMMC.
6. `stmmac` DWMAC 4.10a + JL2101 PHY (genphy first; `phy-mode = "rgmii"`
   without `-id` means the vendor PHY driver programs the RGMII delay — a
   link that trains but corrupts is the failure signature if genphy is not
   enough).
7. NixOS stage 1/2 from p17; identity from nvmem (or a fixed MAC for the first
   boot).

Then the KVM function: pinctrl, GPIO (ATX + LT6911 pins), `dwc3` + gadget
(HID), the three video drivers + `lt6911_manage` (DT graph, syscon,
`reserved-memory`), I2S audio; then mini-display and WiFi.

**Order of work with the first hardware-risk step marked:**

1. Kernel build scaffolding in the flake (mainline stable pin, config
   fragment, in-repo `dts/`), packaged through the existing `slot-image.nix`
   into a `kernel_b` + `dtb_b` image. No hardware.
2. **First hardware-risk step: boot a mainline `Image` on slot B with the
   `ax_wdt` port, padded dtb, `blkdevparts=`-preserving cmdline, and a tiny
   embedded initramfs whose only job is to write `SLOTB_BOOTABLE` via
   `/dev/mem` (`0x2390028 ← 0x20`) and blink the heartbeat LED.** Outcome
   read without serial, exactly as the proven slot-B procedure: after the
   test reboot, `fw_printenv bootsystem` from the *following* boot tells us
   whether the mainline kernel reached userspace (`B` re-armed itself and
   stays) or died (`A`, SPL fell back). This isolates "does the core boot on
   this SoC" from every driver question. Risk is bounded — slot A and the
   rootfs are never written — but it is the first time a non-vendor kernel
   runs on the silicon.
3. Storage + Ethernet → SSH into a NixOS rootfs on SD first (non-destructive),
   then eMMC.
4. NixOS appliance module on mainline (`nixos/appliance.nix` moves to the
   unstable pin: systemd ≥ 258 is fine on ≥ 5.10), identity, `fw_env.config`,
   health-gated checkboot.
5. clk/reset/pinctrl real drivers.
6. USB HID; video stack; audio; display; WiFi.
7. Rollback + flake-based updates replace the custom OTA (one legacy OTA
   migrates devices; `updates.md` rewrite).
8. Upstreaming (bindings once the prefix settles; drivers).

---

## 8. Proposed child issues

Draft titles and two-line bodies, dependency order. Not filed — for the
coordinator's review.

1. **#26.1 Mainline kernel build scaffolding (flake, config, in-repo DT)** —
   Add `.#kernel-mainline` on a pinned stable (≤ 7.2 while aic8800 is wanted)
   with an AX630C config fragment and `dts/ax630c.dtsi` + `ax630c-nanokvm-pro.dts`
   in-repo; vendor-prefix behind one macro. Package via `slot-image.nix`
   (kernel ≤ 64 MiB, dtb ≤ 1 MiB, `dtc -p 4096`). Depends on: nothing.
2. **#26.2 `ax_wdt` port + boot-contract shims (first hardware step)** —
   Describing-subagent spec of `axera,ax-wdt` → watchdog + restart-handler
   driver; cmdline keeps `blkdevparts=`; minimal initramfs that re-arms
   `SLOTB_BOOTABLE` and drives the heartbeat LED. Boot on slot B, read the
   result via `bootsystem` on the following boot. Depends on: 26.1.
3. **#26.3 eMMC/SD via `sdhci-cadence` + reset driver + gate-only clk driver** —
   Spec + port of `axera_reset` (`#reset-cells = <1>` + table) and a CCF
   driver covering the 86 gates (PLLs as fixed-factor); `cdns,sd4hc` with
   the board's `cdns,phy-*` values; diff `sdhci-axera.c` against mainline
   for Axera-only tuning. Root on SD p2 first. Depends on: 26.2.
4. **#26.4 Ethernet: DWMAC 4.10a glue + JL2101 PHY** — stmmac
   `dwmac-generic`/tiny glue with the five clock names + PHY reset GPIO;
   genphy first, JLSemi RGMII-delay/LED spec only if link fails. Exit: SSH.
   Depends on: 26.3.
5. **#26.5 NixOS appliance on mainline (unstable pin), identity, env config** —
   Move `nixos/appliance.nix` off `nixpkgs-rootfs`; NixOS initrd replaces the
   vendor `/init`; `/boot` vfat contract; `device_key` → MAC/hostname from the
   bootloader's IRAM `misc_info` UID (nvmem node, or a U-Boot `ethaddr` fixup); ship `/etc/fw_env.config = /dev/mmcblk0 0x4C0000 0x100000`
   after a hexdump check. Depends on: 26.4.
6. **#26.6 Health-gated A/B re-arm + systemd watchdog (NixOS-native rollback)** —
   `nanokvm-checkboot` after `nanokvm-healthy.target`; `RuntimeWatchdogSec` on
   `/dev/watchdog0`; kernel/dtb updates write the other slot and flip
   `bootsystem`; document the cold-power-cycle caveat. Hardware-test the
   ATF/U-Boot slot failover that updates.md still lists as unexercised.
   Depends on: 26.5.
7. **#26.7 Full clock driver + pinctrl (data model + driver)** — Extend the
   gate-only CCF driver to the 247 registered clocks incl. the fractional-N
   CPUPLL (`cpufreq-dt` follows); pinctrl driver + a regenerated dtsi (~30
   multi-group functions instead of 551 single-group ones), restoring the
   I2C `pinctrl-0` states the board dts deletes and turning the DEMO pad
   table into DT states; `gpio_request_enable` wired (kills the SW_PWR mux
   trap at the root). Depends on: 26.4 (can start in parallel).
8. **#26.8 GPIO + ATX + LT6911 on mainline** — New ~500-LOC driver for
   `axera,ax-apb-gpio` (one register per line; `gpio-dwapb` cannot bind);
   `lt6911_manage` gets a DT node (I2C0 @0x2b, GPIO descriptors, its three
   pinmux pokes as pinctrl states) and keeps its `/proc` ABI; `nanokvm-gpio`
   moves to libgpiod/DT names. Depends on: 26.7.
9. **#26.9 USB: dwc3 glue + gadget HID** — `dwc3-of-simple`-class glue (one
   PHY reset bit + clocks), `extcon-usb-gpio`, configfs `hid/mass_storage/ncm/
   uac2` as today (`usbdev.sh` contract from nixos-rootfs.md gap 2).
   Depends on: 26.7.
10. **#26.10 Video stack on mainline (fwnode graph, syscon, reserved-memory)** —
    Port `open_vin_csi2`, `open_vin_capture`, `vc8000-vcmd` glue to the
    current V4L2/dma APIs; DT `ports/endpoints` incl. the LT6911 subdev;
    carveouts as `reserved-memory` + `memory-region`; drop module-param maps
    and `compute_mem_map`. libkvm unchanged. Depends on: 26.7, 26.8.
11. **#26.11 Mini-display + audio on mainline** — `spi-dw-mmio` + `fb_jd9853`
    (staging fbtft port or `drm/tiny/panel-mipi-dbi` with an init blob),
    `pwm-dwc` OF glue for the backlight, `gpio-keys`/`rotary-encoder` DT;
    `designware-i2s` slave glue (routing word via syscon, `snd-soc-dummy`) for
    the LT6911 audio card — PIO first, else a `dma_per` dmaengine driver.
    Depends on: 26.7, 26.8.
12. **#26.12 WiFi: aic8800 out-of-tree module + firmware pin** — Package
    `radxa-pkg/aic8800` (SDIO) against the pinned kernel, `aic_bsp` reset GPIO,
    firmware MD5-pinned; or record the drop decision. Depends on: 26.3.
13. **#26.13 Flake-based updates replace the custom OTA; legacy migration OTA** —
    `system.autoUpgrade`-style against the flake; one final legacy
    `update-package` that migrates a vendor-base device to the NixOS image;
    rewrite updates.md. Depends on: 26.6.
14. **#26.14 nixosModules split (product 1) and upstreaming** — Expose
    `nixosModules.nanokvm-pro-{kernel,video,display,atx,updates}`; submit
    bindings/drivers once the Axera prefix question resolves on LKML.
    Depends on: 26.10.

Recommended: 26.1 → 26.2 immediately (they need the device for one slot-B
boot each); 26.7 and 26.12 can start from source in parallel.

---

## 9. Device reads wanted

For the coordinator, once the device is back on the open stack. All read-only.

```bash
# live DT (authoritative over the .dts: shows what the boot chain actually passed)
dtc -I fs -O dts /proc/device-tree 2>/dev/null > /tmp/live.dts; wc -l /tmp/live.dts
cat /proc/device-tree/model; cat /proc/device-tree/chosen/bootargs; echo
cat /proc/cmdline
# memory / iomem / IRQ owners (confirms the inventory's IRQ + base addresses)
cat /proc/iomem; cat /proc/interrupts; dmesg | grep -iE 'Memory:|reserved|cma|mem='
# bound platform devices + drivers (what actually probes today)
ls /sys/bus/platform/devices | sort; ls /sys/bus/platform/drivers | sort
lsmod
# storage / net / usb identities
ls -l /sys/bus/mmc/devices; cat /sys/class/mmc_host/mmc*/mmc*/type 2>/dev/null
ethtool -i eth0; cat /sys/bus/mdio_bus/devices/*/phy_id; cat /sys/class/net/eth0/address
ls /sys/class/udc; ls /sys/kernel/config/usb_gadget/*/functions 2>/dev/null
cat /sys/bus/i2c/devices/*/name 2>/dev/null; ls /sys/bus/i2c/devices
# clocks / resets / gpio / pwm / wdt / thermal state left by firmware
mount | grep debugfs || mount -t debugfs none /sys/kernel/debug
cat /sys/kernel/debug/clk/clk_summary
cat /sys/kernel/debug/gpio
ls /sys/class/watchdog; cat /sys/class/watchdog/watchdog0/{identity,timeout,state} 2>/dev/null
cat /sys/class/thermal/thermal_zone*/temp; ls /sys/class/pwm
# A/B + env (verifies fw_env.config and the slot register semantics)
devmem 0x02390024; fw_printenv bootsystem; fw_printenv bootargs; cat /etc/fw_env.config
hexdump -C -s 0x4C0000 -n 64 /dev/mmcblk0          # expect the U-Boot env CRC header
# identity + board id
cat /proc/ax_proc/uid; cat /sys/bus/iio/devices/iio:device0/in_voltage0_raw
# kernel config as booted
zcat /proc/config.gz | grep -E 'CONFIG_(AX_WATCHDOG|WATCHDOG_NOWAYOUT|OPTEE|TEE|JLSEMI|AXERA_EPHY|IOMMU_SUPPORT|CMA)\b'
```

The `clk_summary` and `debug/gpio` dumps are the ones that most reduce the
port's inference: they show which clocks the firmware leaves running (what the
`fixed-clock` first boot can rely on) and which GPIO lines are claimed by
which driver today.

---

## 10. Verified vs inferred; corrections to other docs

**Verified from source this session:** every compatible string and LOC in §2;
the DW/Cadence lineage of UART, SDHC, DWC3, DWMAC, I2C, SPI, I2S (driver
headers/register names); the non-DW watchdog register map and kick magic; the
`if (0) arm_pm_restart` patch and `ax_wdt_restart`; the absent PSCI
reset/off ops; `wdt0_enable` 30 s before `booti`; `get_part_info` parsing
`blkdevparts=` from the env; `select_slot_ab` semantics incl. the power-off
branch; `lt6911_manage` bus 0 / `0x2b` / pin numbers; the AX650 LKML series
(fetched the v2 cover via marc.info); the empty state of mainline/linux-next/
U-Boot for Axera.

**Inferred (marked in §2):** that genphy suffices for the JL2101 (the vendor
driver programs RGMII delay and an errata patch — a "links but corrupts"
outcome is the tell); that the mainline `pwm-dwc` core matches (register
offsets compared, OF glue status on the target kernel unchecked); that the
CSI-2 controller is Cadence CSI2RX-derived (blob symbol names + two register
offsets); that designware-i2s PIO is enough for HDMI audio without a `dma_per`
driver; the `fdt_chosen` space trap (well-grounded reading of `booti`'s state
mask, untested); the IRAM physical address of `misc_info` (`0x740` offset is
verified, the IRAM0 base is not).

**Loose ends found while mining `[K]`** (none block the port; recorded so they
are not re-derived): the board dts spells `status = "disable"` eight times
(only `"okay"`/`"ok"` enable a node, so those are off by accident);
`hwlock@10420000` can never bind (driver matches `ax,hwspinlock-r1p0`, DT
says `axera,`); `spi4`, `dma@10460000`, `dmac@48b0000` have no driver in the
vendor build; `include/linux/platform_device.h` is patched with two Axera
pointer fields (an ABI-layout change to core structs — irrelevant once no
vendor `.ko` exists); `ax_sysmap` is an mmap-anything `/dev/mem` bypass and
must not be ported; `fs/proc/root.c` creates `/proc/ax_proc` unconditionally
and `kernel/printk/ax_printk.c` is a second printk — all vendor-core patches
that simply vanish on mainline. `0x04403000` (the AXI-hang address in
CLAUDE.md) is the VPP peripheral, not the mm reset syscon (`0x4430000`); the
explanation (unclocked MM domain) stands.

**Corrections the coordinator should apply elsewhere** (not edited here):

- `pkgs/dtb.nix` header, lines ~6–11: "on-hardware the eMMC root still reached
  the kernel, so env bootargs did not override chosen" is stale — the env does
  override (`pkgs/sd-image.nix` records the live SD cmdline verbatim). Baking
  `root=` into the DT is still harmless.
- `docs/updates.md` ("OP-TEE (p8/p9)"), `pkgs/boot.nix` and `pkgs/image.nix`
  comments: OP-TEE is **p10/p11**; p8/p9 are `logo`/`logo_b`
  (`partition_ab.mak`; the table in flashing-and-recovery.md is already right).
- `docs/nixos-rootfs.md` gap 3: the `fw_env.config` TODO is closeable —
  `/dev/mmcblk0 0x4C0000 0x100000` (verify by hexdump first). Its rootfs
  contract should also name `/proc/ax_proc/uid` as a mainline blocker.
- CLAUDE.md docs index: add this file (coordinator's job per the task brief).
