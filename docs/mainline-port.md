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
- [8. Child issues](#8-child-issues)
- [9. Device reads wanted](#9-device-reads-wanted)
- [10. Verified vs inferred; corrections to other docs](#10-verified-vs-inferred-corrections-to-other-docs)
- [11. #89: mainline U-Boot and the minimal layout — investigation, 2026-09-07](#11-89-mainline-u-boot-and-the-minimal-layout--investigation-2026-09-07)

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
core + `8250_dw` + `sdhci-cadence` + `stmmac` (+ mainline's realtek PHY driver
— see #77 in §8; the DT's JLSemi compatible is wrong) + the **`ax_wdt`
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
| Clocks | 9 provider nodes `axera,ax620x-{cpu,common,dispc,flash,isp,mm,periph,vpu,pllc}-clk` + `syscon` (`0x1900000`, `0x2340000`, `0x4600000`, `0x10030000`, `0x2500000`, `0x4430000`, `0x4870000`, `0x4030000`, `0x2210000`); 493 IDs in `dt-bindings/clock/ax620e-clock.h`, **246 registered** (the 247th `clk_summary` row is `sysclk`, an unrelated DT `fixed-clock` -- corrected 2026-09-06 by clk-model-20260906.md) | `drivers/clk/axera/clk-ax620e.c` 572 + `clk.c` 668 LOC (`clk.c` is a rename-fork of `drivers/clk/hisilicon/clk.c`) | Axera-custom: 86 gates (all one flag → `clk_hw_register_gate`), muxes/dividers, **one** runtime-programmed fractional-N PLL (CPUPLL); the other PLLs are bootloader-set and modelled as `fixed_factor` (V) | **new driver** (table-driven CCF, ~1.5–2 kLOC); a gate-only subset is enough for bring-up because the vendor peripheral drivers each gate their own clock via the periph syscon — mainline drivers will expect `clocks =` instead | M | boot |
| Resets | 18 provider nodes `axera,axera_reset_match` + `syscon`, `#reset-cells` = 3 (`<bit reg polarity>`), 4 (`<set_bit set_reg clr_bit clr_reg>`) or 10 (4-cell + a clock gate closed across the reset) — all data in consumer phandle args | `drivers/reset/axera_reset/axera_reset.c` 298 LOC | Axera-custom SET/CLR reset controller (V) | **new driver**; mainline wants `#reset-cells = <1>` + an in-driver table harvested from the ~60 consumers (`reset-simple` cannot express the vendor specifier) | S–M | boot |
| Pinctrl / pinmux | `axera,ax620e-pinctrl` @`0x2300000` (+`0x104f0000`); 6855-line `AX620E_pinctrl.dtsi` = 111 pins × 551 single-group functions / 563 states. **The board relies on a replayed table, not DT states:** `drivers/soc/axera/pinmux/ax_pinmux.c` self-registers at `arch_initcall` and writes the SDK `AX630C_DEMO_pinmux.h` `<addr,value>` pairs (**133 writes** -- 22 group-MISC plus exactly one per pad; corrected 2026-09-06 by pinctrl-model-20260906.md -- incl. `0x02300060 = 0x00060003` VI_D7 → GPIO0_A7); U-Boot applies the same table first. The board dts `/delete-property/`s `pinctrl-0` on every I2C node | `drivers/pinctrl/axera/pinctrl-ax620e.c` 728 + `ax_pinmux.c` 225 LOC | Axera-custom, one word per pad, stride `0xC`, function `[18:16]`, pull `[7:6]`, drive `[3:0]` (V) | **new driver + remodelled DT** (**56** real multi-group functions, regenerated dtsi, I2C states restored). Not needed for first boot (U-Boot's table pass persists). This is also the **root of the SW_PWR trap**: the DEMO table muxes VI_D7 to GPIO at init, capture re-muxes it, nothing re-applies; `gpio-axera` overrides `chip.request` with a no-op so `pinctrl_gpio_request()` never runs — a correct mainline pinctrl+GPIO pair fixes it for free | **L** (data model) | KVM |
| GPIO | `axera,ax-apb-gpio` ×4 (`0x4800000`, `0x4801000`, `0x6000000`, `0x6001000`, SPI 114–117), **97** `gpio-ranges` (not 128; corrected 2026-09-06) | `drivers/gpio/gpio-axera.c` 538 LOC (defconfig also has `GPIO_DWAPB=y`, unused) | DesignWare *names* only: **one 32-bit register per GPIO** at `base + (n+1)*4` with DR/DDR/INTEN/… as bit fields, relocated port regs (`EXT_PORTA 0x8c`, secure/non-secure INTSTATUS `0x84/0xa4`), raw clock pokes at `0x4870000` (V) | **DONE (#81)**: `drivers/gpio/gpio-ax630c.c`, ~470 lines, four controllers with 97 `gpio-ranges`, an irqchip, and clocks and resets from DT rather than a private syscon mapping. `gpio-dwapb` cannot bind | S–M | KVM (ATX, panel, LT6911 pins) |
| Watchdog | `axera,ax-wdt` @`0x4840000` (wdt0) + `0x6040000` (wdt2) | `drivers/watchdog/ax_wdt.c` 514 LOC (`CONFIG_AX_WATCHDOG=y`, `NOWAYOUT=y`) | **not** DesignWare: EN `+0x00`, TORR `+0x0c`, start `+0x18`, count `+0x24`, kick `+0x30` magic `0x61696370` (V) | **new driver, mandatory**: U-Boot arms wdt0 for 30 s before `booti`; the vendor kernel pets it from the WDT's own ISR and reboots through `ax_wdt_restart()` because PSCI reset is absent | S | **boot** |
| Thermal + ADC | `axera,ax620e-tsensor` @`0x2000000` (trips 80/105/120 °C) and `axera,ax620e-adc` (no `reg`; the driver `ioremap`s the *same* `0x2000000` block — one analog-monitor IP). `in_voltage0_raw` is the **board-id** the loader turns into DRAM size / pool geometry | `drivers/thermal/axera_thermal.c` 487 + `drivers/iio/adc/axera_adc.c` 307 LOC | Axera-custom 10-bit sensor block (V). **Thermal is decorative today**: no `cooling-maps` anywhere, `CPU_THERMAL` off, the 120 °C trip is typed `passive` — the SoC neither throttles nor shuts down | one new driver exposing `#thermal-sensor-cells` + `#io-channel-cells` (~200 LOC); DRAM size becomes a per-board DT fact | S | opt |
| UID / identity | `ax,ax_hwinfo` → `/proc/ax_proc/uid`, read by the initramfs for `device_key` → MAC + hostname | `drivers/soc/axera/ax_hwinfo/ax_hwinfo.c` 261 LOC | **not an efuse peripheral**: it `memcpy`s the `misc_info_t` the bootloader leaves in IRAM0 at `0x740` (`uid_l/uid_h` at `+0x48/+0x4c`; `include/linux/soc/axera/ax_boardinfo.h`) (V) | **DONE (#78), with no kernel driver at all.** IRAM0 is at physical 0 — the vendor probe ioremaps the bare `0x740` with no base added — so `nanokvm-identity.service` reads `uid_l`/`uid_h` at `0x788`/`0x78c` through `/dev/mem` and reproduces the vendor MAC arithmetic exactly. A tiny `nvmem` node over that window, or a U-Boot `ethaddr` fixup feeding `fdt_fixup_ethernet()`, remain the upstreamable forms | S | KVM (identity) |
| RTC | `axera,axi-top-rtc` | `drivers/rtc/rtc-axera.c` 479 LOC ("DesignWare Real Time Clock Driver", password `0x61696370`) | DW-*named*, no mainline DW RTC exists (V) | new driver, or none (no battery is known on the board) | S | opt |
| cpufreq | `AXERA_CPUFREQ=y`, `AX620E_opptable.dtsi` | `drivers/cpufreq/axera-cpufreq.c` | `cpufreq-dt` once the clk driver exists | DT + clk | S | opt |
| DMA | `axera,axi-dma-1.01a` @`0x48b0000` (SPI 113); **`axera,dma-per` @`0x48a0000`** (SPI 112, 16 ch); `axera,dma` @`0x10460000` | `drivers/dma/axera-axi-dmac/` 1547 LOC (**not built**; Synopsys/Paltsev header verbatim); `drivers/dma/axera-dma-per/` 1317 LOC (`=y`, custom); `soc/axera/dma/dma.c` has no Makefile entry (dead node) | AXI DMAC = stock `dw-axi-dmac` (V, header); **`dma_per` is Axera-custom and is the engine behind every UART/SPI/I2S DMA channel — incl. `i2s_slv0` 16/17 = HDMI audio** | AXI DMAC: rename the compatible. **`dma_per`: new dmaengine driver** if I2S audio must use DMA (designware-i2s has a PIO mode; try that first) | S / M | opt (audio) |
| ramoops | `ramoops` reserved-memory @`0x48000000` | pstore | standard | DT only | S | opt |
| Vendor SoC glue never needed | `axera,cmm`, `axera,sys`, `axera,ax_sysmap`, `axera,logctl`, `axera,bw_limiter`, `axera,ddr_dfs`, `axera,perf_bm`, `axera,firewall`, `axera,ax_gzipd`, `axera,hwspinlock-r1p0`, `axera,mailbox` (RISC-V companion), `ax,hrtimer`, `axera,wake-timer`, `axera, deb-gpio-lp`, `axera_memory_dump`, `axera_ddr_retrain`, `axera,avs` | `drivers/soc/axera/*` (11.7 kLOC total) | — | **drop** (the KVM stack was device-proven with the ax base stack rmmod'd, #55 M3) | — | — |

### Storage, network, USB

| Block | DT | Vendor driver | IP / mainline | Port needs | Effort | Gates |
|---|---|---|---|---|---|---|
| eMMC | `axera,sdhc` @`0x1B40000` (`mmc0`), HS400-ES, 8-bit, `cdns,phy-*` tuning props, 3 resets (`prst`/`arst`/`cardrst`), hw-reset GPIO2_A23 | `drivers/mmc/host/sdhci-axera.c` 1208 LOC | **Cadence SD4HC** — the vendor file is `sdhci-cadence.c` (Socionext header intact, `sdhci_cdns_*` names kept) with Axera additions; DT already uses the mainline `cdns,phy-*` properties (V) | `sdhci-cadence` (`cdns,sd4hc`) + `clocks =` (vendor gates by hand via `ax_set_mmc_clk`) + **no `resets`** — mainline binds index 0 as the *card* `RST_n`, so listing the vendor's `prst` there makes error recovery assert the controller's own APB reset; use `reset-gpios = <&gpio2 23 GPIO_ACTIVE_LOW>` for the real card reset. Tuning is byte-identical to upstream; the 1208-vs-675 gap is clock/reset integration plus dead code, not Axera tuning. Stock `sdhci-cadence` drives this IP — the only code needed is a 15-line `drv_data` entry for `SDHCI_QUIRK2_PRESET_VALUE_BROKEN`. See [sdhci-model-20260906.md](reference/mainline/sdhci-model-20260906.md) | S–M | **boot** |
| SD | `axera,sdhc` @`0x104E0000` (`mmc1`), UHS to SDR104, `broken-cd` | same | same | same | S | opt (test path) |
| SDIO | `axera,sdhc` @`0x104D0000` (`mmc2`), no-1.8V, WiFi | same | same | same | S | opt (WiFi) |
| Ethernet MAC | `axera,dwmac-4.10a` @`0x104C0000`, 5 clocks, 3 resets, `phy-mode = "rgmii"`, `snps,dwmac-mdio` | `drivers/net/ethernet/stmicro/stmmac/dwmac-axera-plat.c` 187 LOC glue over stmmac | **Synopsys DWMAC 4.10a** (V) | **DONE (#77)**: `dwmac-axera.c`, ~230 lines over mainline stmmac — four of the five clocks, the PHY-interface select and block reset as flash-syscon bits, an RGMII tx-clock hook, and a register poke for PHY reset GPIO1_A27 until #81 | S–M | **boot** (SSH) |
| Ethernet PHY | `ethernet-phy-id937c.4030` (JLSemi **JL2101**), 20 `jl2xxx,*` tuning props | `drivers/net/phy/jlsemi.c` 561 + `jlsemi-core.c` 3043 LOC | **The part is a Realtek RTL8211F, not a JL2101** — PHYID 0x001cc916 read over MDIO 2026-09-06 (V). The vendor DT's `ethernet-phy-id*` compatible forces the MDIO core to skip the bus read, so the JLSemi driver binds to a Realtek chip and works only because it programs almost nothing | **DONE (#77)**: mainline's own realtek driver, with `phy-mode = "rgmii-id"` — the RTL8211F's two 2 ns delays are pin-strapped on and mainline's driver *writes* them to match phy-mode. No JLSemi driver is needed or wanted | S | **boot** (SSH) |
| WiFi/BT | `aicsemi,aic_bsp` (reset GPIO1_A29) + SDIO | `drivers/net/wireless/aic8800/` (`aic8800_bsp/btlpm/fdrv`, `=m`) | out-of-tree vendor GPL driver, see §1 | carry `radxa-pkg/aic8800` on a ≤ 7.2 kernel + the firmware blob; or drop | M | opt |
| USB | `axera,dwc3` glue → `snps,dwc3` @`0x8000000`, `dr_mode = "otg"`, `extcon` = `linux,extcon-usb-gpio` (GPIO1_A4), `phy_type = "utmi"`, high-speed only | `drivers/usb/dwc3/dwc3-axera.c` 531 LOC ("DesignWare USB3 OF Simple Glue Layer"); PHY handling is one `USB2_PHY_SW_RST` bit (V) | **Synopsys DWC3** (V) | **DONE (#82)**: `dwc3-axera.c`, ~210 lines of of-simple-class glue over the mainline core — three flash-syscon clock gates, the two software resets, and VBUSVALID, which is the one thing no generic glue can express. Gadget functions (`hid`, `mass_storage`, `ncm`, `uac2`, `acm`) are all mainline configfs and are built in; only `f_udisp` (USB display) is vendor and unused. `dr_mode = "peripheral"` until #81 gives OTG ID detection a GPIO | M | KVM (HID) |

### Board peripherals

| Block | DT | Vendor driver | IP / mainline | Port needs | Effort | Gates |
|---|---|---|---|---|---|---|
| UART0/1/2 | `axera,ax-apb-uart` @`0x4880000/0x4881000/0x4882000`, `reg-shift = 2`, `reg-io-width = 4`, 208 MHz | `drivers/tty/serial/8250/8250_axera.c` 542 LOC (a `8250_dw.c` fork) | **Synopsys DW APB UART** (V; `earlycon=uart8250,mmio32` already works) | `snps,dw-apb-uart` + `8250_dw`, `clock-frequency = <208000000>` | S | boot (debug only — hidden pads) |
| I2C0, I2C7 | `snps,designware-i2c` @`0x4850000`, `0x4857000` | mainline `i2c-designware` (unmodified compatible) | DW (V) | DT only. **i2c0 DONE (#81)**, carrying the LT6911UXC at `0x2b` as a DT child rather than the hard-coded bus and address of `lt6911_manage.h`; its APB gate is *named* `pclk` rather than marked critical, because a NULL `clk_get()` takes index 0 regardless of `clock-names`. i2c7 (hynitron touch) arrives with the touch panel | S | KVM |
| HDMI-RX bridge | Lontium LT6911UXC — no DT node; `lt6911_manage.c` (2907 LOC, ours from source) opens I2C bus 0 @`0x2b` and raw GPIOs 60 (INT), 5 (PWR), 6, 82, 83, 21, 81; exposes `/proc/lt6911_info/*` | `drivers/misc/lt6911_manage.c` (`CONFIG_LT6911_MANAGE=m`) | mainline has `lt6911uxe` (6.14+) — a different chip, V4L2-subdev shaped | **DONE (#81)**: `drivers/misc/lt6911-manage.c`, ~2400 lines, an i2c driver on `lontium,lt6911uxc` as a child of `i2c0` with GPIO descriptors and the `/proc` ABI intact, scoped to the UXC. A V4L2-subdev rewrite is an upstreaming nicety, not a port need | S–M | KVM |
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
- `lt6911_manage.c` also **writes pinmux registers directly** — the same trap
  class as SW_PWR. **Seven pads, not the three this line used to name**
  (corrected 2026-09-07 by #81): `0x104F006C` EPHY_LED0, `0x02300048` VI_D5,
  `0x02300054` VI_D6, `0x0230A06C` CDTX_L4N, `0x0230A078` CDTX_L4P,
  `0x02302090` TMS, `0x0230A060` CDTX_L3P. On mainline none of them is a
  pinctrl state: claiming the GPIO programs the mux (§8, #81).
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
[nixos-rootfs.md](nixos-rootfs.md#the-boot-contract). Mainline-specific
additions: it reads **`/proc/ax_proc/uid`** for `device_key` (a vendor
`ax_hwinfo` proc node, absent on mainline); it greps `dmesg` for an ext4 message
text; it hard-codes `mmcblk0p17` for the resize check; `boot_key=` recovery is
dead code (nothing sets it; `/boot/rec` is the live trigger). NixOS brings its
own initrd, so the vendor script is replaced, not ported — but `/boot` (p16,
vfat) must stay mounted and writable (the server writes `usb.*` flag files
there). **Settled in #78:** the initrd is the classic script stage 1, not
`boot.initrd.systemd`, and it is embedded in the kernel Image because `booti`
is called with no ramdisk and no partition holds one; the identity derivation
reads the UID out of `misc_info` at physical `0x740` through `/dev/mem` rather
than through an nvmem node, so the MAC does not degenerate to one constant.

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
   reboot. **Shipped in #78**, and not as a transcribed constant:
   `nixos/emmc-partitions.nix` computes that sum from the `blkdevparts=` clause
   itself and asserts it, so the file cannot drift from the layout U-Boot reads.

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
6. `stmmac` DWMAC 4.10a + the board's PHY. Settled by #77: the PHY is a
   Realtek RTL8211F (the vendor DT's JL2101 compatible is wrong), mainline's
   realtek driver claims it, and `phy-mode` must be `rgmii-id` — a link that
   trains but passes nothing is that property being wrong.
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

## 8. Child issues

Filed 2026-09-06 as #74–#87, plus **#89** (2026-09-07), in the dependency order
below; the index map also
lives as a comment on #26. **#74, #75, #76, #77, #80, #81 and #82 are done**
(see "What exists now" at the end of this section), and **#78 builds and boots
in QEMU** with its hardware half outstanding; everything else is open. What #80
still owes is the CPUPLL/cpufreq half and the dispc/mm/vpu reset alias windows.

1. **#74 Mainline kernel build scaffolding (flake, config, in-repo DT)** —
   Add `.#kernel-mainline` on a pinned stable (≤ 7.2 while aic8800 is wanted)
   with an AX630C config fragment and `dts/ax630c.dtsi` + `ax630c-nanokvm-pro.dts`
   in-repo; vendor-prefix behind one macro. Package via `slot-image.nix`
   (kernel ≤ 64 MiB, dtb ≤ 1 MiB, `dtc -p 4096`). Depends on: nothing.
2. **#75 `ax_wdt` port + boot-contract shims (first hardware step)** —
   DONE 2026-09-06, device-proven. Watchdog driver written from a
   describing-subagent spec, `syscon-reboot` for the ordinary reboot, and
   a bring-up initramfs that leaves boot evidence in the slot register, in
   reserved DRAM and on the heartbeat LED. The stated exit criterion
   (`bootsystem` = B on the next boot) was replaced: re-arming
   `SLOTB_BOOTABLE` would strand the device on a slot with no rootfs, so
   the milestone bits are the oracle and every exit path returns to slot A.
3. **#76 eMMC/SD via `sdhci-cadence` + reset driver + gate-only clk driver** —
   **eMMC half DONE 2026-09-06, device-proven** (see "What exists now (#76)").
   Most of the filed scope evaporated on contact: #80 had already shipped the
   full clock driver, so only the fifteen mmc clock rows the vendor CCF never
   registered were owed; and the controller turned out to be a stock Cadence
   SD4HC needing a 14-line quirk patch rather than a port. **The reset driver
   is specified but not written, and storage does not need it** — mainline
   reserves `resets` on an mmc node for the card's `RST_n`, and firmware
   leaves the SoC lines deasserted. It stays here because #81/#83/#84 all
   block on it: spec in
   [reset-model-20260906.md](reference/mainline/reset-model-20260906.md),
   which recommends folding `#reset-cells = <1>` into the existing
   `clock-controller` nodes rather than adding separate ones.
   **Still open: root on SD p2, blocked on there being no SD card in the
   device.** Depends on: #75.
4. **#77 Ethernet: DWMAC 4.10a glue + JL2101 PHY** — DONE 2026-09-06,
   device-proven: `dwmac-axera.c` over mainline stmmac, gigabit, and an SSH
   shell on the mainline kernel through `tools/kvmssh`. The PHY half of the
   filed scope evaporated — the part is a Realtek RTL8211F, not a JL2101, and
   mainline's own driver claims it once `phy-mode` says `rgmii-id`. See "What
   exists now" at the end of this section. Depends on: #76.
5. **#78 NixOS appliance on mainline (unstable pin), identity, env config** —
   Move `nixos/appliance.nix` off `nixpkgs-rootfs`; NixOS initrd replaces the
   vendor `/init`; `/boot` vfat contract; `device_key` → MAC/hostname from the
   bootloader's IRAM `misc_info` UID (nvmem node, or a U-Boot `ethaddr` fixup); ship `/etc/fw_env.config = /dev/mmcblk0 0x4C0000 0x100000`
   after a hexdump check. Depends on: #77.
6. **#79 Health-gated A/B re-arm + systemd watchdog (NixOS-native rollback)** —
   **SUPERSEDED by #89, 2026-09-07.** The filed plan was to re-arm the vendor
   slot register after a health check. #89 replaces the whole mechanism with
   mainline U-Boot's `bootcount`/`bootlimit`/`altbootcmd` over extlinux
   generations, which is strictly better on the three axes #79 cared about: it
   survives a cold power cycle, it is per-generation rather than per-slot, and
   it needs no A/B twins on the eMMC. What survives from #79 into #89 is the
   *policy* — `nanokvm-checkboot` (now `nanokvm-mark-good`) after
   `nanokvm-healthy.target`, and `RuntimeWatchdogSec` on `/dev/watchdog0`.
   The ATF/U-Boot slot failover it wanted hardware-tested turns out not to
   exist in this SPL build at all (§11.2). Depends on: #78.
7. **#80 Full clock driver + pinctrl (data model + driver)** — Extend the
   gate-only CCF driver to the 246 registered clocks incl. the fractional-N
   CPUPLL (`cpufreq-dt` follows); pinctrl driver + a regenerated dtsi (~30
   multi-group functions instead of 551 single-group ones), restoring the
   I2C `pinctrl-0` states the board dts deletes and turning the DEMO pad
   table into DT states; `gpio_request_enable` wired (kills the SW_PWR mux
   trap at the root). Depends on: #77 (can start in parallel).
8. **#81 GPIO + ATX + LT6911 on mainline** — DONE 2026-09-07, device-proven.
   `gpio-ax630c.c` for the four controllers, `lt6911-manage.c` replacing the
   vendor's 2907-line driver with the `/proc` ABI intact, an i2c0 node, the
   Ethernet PHY reset as `reset-gpios`, and `nanokvm-gpio` as a libgpiod
   program rather than the name of a sysfs-export unit. `gpio_request_enable()`
   got its first exercise on silicon and moved four pads the vendor re-muxed by
   hand. The filed scope said the LT6911 driver writes *three* pinmux
   registers; it writes seven, and on mainline none of them is a pinctrl state
   — claiming the GPIO programs the pad. See "What exists now" at the end of
   this section. Depends on: #80.
9. **#82 USB: dwc3 glue + gadget HID** — DONE 2026-09-07, device-proven: a
   host enumerated a mainline-kernel HID gadget from this board (see "What
   exists now (#82)" at the end of this section). `dwc3-axera.c` over the
   mainline dwc3 core, three new flash clock rows and two reset lines, the
   configfs gadget and all five `usbdev.sh` function drivers built in, and
   three new milestone bits that make enumeration readable without a serial
   console. `extcon-usb-gpio` is the one filed item deliberately NOT done:
   OTG ID detection is a raw GPIO, and although #81 has since landed the
   controller that would make it writable, nothing is ever plugged *into*
   this port, so peripheral is the shipped and tested mode.
   Depends on: #80.
10. **#83 Video stack on mainline (fwnode graph, syscon, reserved-memory)** —
    Port `open_vin_csi2`, `open_vin_capture`, `vc8000-vcmd` glue to the
    current V4L2/dma APIs; DT `ports/endpoints` incl. the LT6911 subdev;
    carveouts as `reserved-memory` + `memory-region`; drop module-param maps
    and `compute_mem_map`. libkvm unchanged. Depends on: #80, #81.
11. **#84 Mini-display + audio on mainline** — `spi-dw-mmio` + `fb_jd9853`
    (staging fbtft port or `drm/tiny/panel-mipi-dbi` with an init blob),
    `pwm-dwc` OF glue for the backlight, `gpio-keys`/`rotary-encoder` DT;
    `designware-i2s` slave glue (routing word via syscon, `snd-soc-dummy`) for
    the LT6911 audio card — PIO first, else a `dma_per` dmaengine driver.
    Depends on: #80, #81.
12. **#85 WiFi: aic8800 out-of-tree module + firmware pin** — Package
    `radxa-pkg/aic8800` (SDIO) against the pinned kernel, `aic_bsp` reset GPIO,
    firmware MD5-pinned; or record the drop decision. Depends on: #76.
13. **#86 Flake-based updates replace the custom OTA; legacy migration OTA** —
    `system.autoUpgrade`-style against the flake; one final legacy
    `update-package` that migrates a vendor-base device to the NixOS image;
    rewrite updates.md. Depends on: #79.
14. **#87 nixosModules split (product 1) and upstreaming** — Expose
    `nixosModules.nanokvm-pro-{kernel,video,display,atx,updates}`; submit
    bindings/drivers once the Axera prefix question resolves on LKML.
    Depends on: #83.
15. **#89 Mainline U-Boot + minimal partition layout; extlinux generations
    replace the vendor A/B scheme** — filed 2026-09-07, **supersedes #79**.
    Mainline U-Boot with an `axera/ax630c` board port as BL33, mainline TF-A
    with an AX630C platform as BL31, OP-TEE dropped, the vendor bl1 kept until a
    mainline SPL with the DDR init exists, and a seven-partition layout whose
    single definition feeds the `.axp` manifest, `blkdevparts=`, the SPL build's
    offsets and `fw_env.config`. Investigation done — **§11**. Depends on: #78.

Recommended: #74 → #75 immediately (#75 needs the device for one slot-B
boot); #80 and #85 can start from source in parallel.

### What exists now (#74, 2026-09-06)

`.#kernel-mainline` builds mainline Linux 7.1.3 for the AX630C from the
kernel.org tree our nixpkgs pin carries — no vendor SDK tree, no vendor
defconfig, no vermagic contract. `arm64 defconfig` is the base; the only
deltas are `pkgs/kernel-mainline/ax630c.config`, which pins the boot path
(initrd, `blkdevparts=` parsing, `8250_dw`), the watchdog and pstore core that
#75 needs, CMA (now allowed — #49's ABI break only applied while prebuilt
`ax_*.ko` shared struct layouts with our kernel), the systemd/NixOS floor the
vendor defconfig lacks, and no DWARF/BTF.

`.#dtb-mainline` compiles `dts/ax630c.dtsi` + `dts/ax630c-nanokvm-pro.dts` —
ours, in this repo — with `cpp` + `dtc -p 4096` against the dt-bindings headers
of that exact kernel. The DT is deliberately minimal: CPUs, PSCI, GIC-400, the
24 MHz arch timer, the two DesignWare UARTs, a disabled `wdt0` node, 1 GiB of
memory (the vendor DT claims 3 GiB and leans on `mem=`), and the ATF/OP-TEE/
ramoops reservations. Every other peripheral arrives with the issue that ports
its driver — a DT node without a driver is a DT that lies. All axera-prefixed
compatibles live in `dts/ax630c-compat.h` so #87 can rename them in one place.

`.#kernel-mainline-slot-image` and `.#dtb-mainline-slot-image` wrap those in the
vendor signed-header format for the **slot-B** partitions (p15 / p13, 64 MiB /
1 MiB caps), which is what makes #75's first boot a reversible flash.

The build asserts what a serial-less board cannot show you: the config fragment
survived `olddefconfig`, the release string is stable, the Image fits its
partition, the dtb carries real FDT slack (trap 2), the `blkdevparts=` clause
survived (trap 1), and the ATF/OP-TEE reservations are present.

This does not boot. U-Boot arms wdt0 for 30 s before `booti` and nothing here
pets it (trap 3) — that is #75.

### What exists now (#80, 2026-09-06)

The clock and pin-control drivers, in the kernel and building. Both were
written from data-model specifications rather than ported from the vendor
drivers: [clk-model-20260906.md](reference/mainline/clk-model-20260906.md) and
[pinctrl-model-20260906.md](reference/mainline/pinctrl-model-20260906.md), each
reconciled against read-only captures from a running device
(`reference/mainline/device-reads-20260906/`).

`pkgs/kernel-mainline/tree/` is a graft: files laid out at the path they would
occupy upstream, copied into the kernel tree at `postPatch` and hooked into
each subsystem's Kconfig and Makefile in the alphabetical slot upstream would
use. That is what makes #87's submission a `git add` instead of a re-layout.
Both drivers are built in, not modular — a clock provider and a pinctrl driver
are needed long before there is a rootfs.

When you add a file under `tree/`, `git add` it before building: the flake only
sees tracked paths, so a new driver that is merely written on disk fails
evaluation with "Path … is not tracked by Git" rather than being silently
skipped. Every later child issue that grafts a driver hits this.

`drivers/clk/axera/` registers **265** clocks over eight controllers (one
driver, match data selects the table) — 246 the vendor CCF registers, plus 19
it declares and leaves to its own drivers to poke by hand: thirteen for
eMMC/SD/SDIO (#76) and six for the watchdogs. It takes the syscon regmap rather
than a private `ioremap`, so the reset half of the same driver shares its lock.
**CPUPLL is read-only**: firmware leaves it at 1.2 GHz, this
part's ceiling, and with it fixed all five CPU OPPs are pure mux switches — which
removes the one real hazard in the tree, since relocking that PLL can stop the
clock feeding the running core and the silicon has no interlock.

`drivers/pinctrl/axera/` covers **111 pads / 56 functions / 167 groups**. Two
behaviours differ from the vendor deliberately: `set_mux()` refuses a function
the pad does not implement (the vendor writes mux 0 and returns success, and 337
of 888 slots are unpopulated), and `gpio_request_enable()` programs the mux,
which is the root fix for the SW_PWR trap.

Not booted at the time of writing; #75 booted it later the same day and both
drivers came up (see below). Pin states and the reset provider landed after
that — see "What exists now (#80, later)".

### What exists now (#75, 2026-09-06) — BOOTED

**A mainline kernel has run on this silicon.** `.#kernel-mainline` boots from
slot B, brings up both CPUs, probes the clock, pin-control and watchdog
drivers, reaches userspace, and reboots itself back to slot A. Log and
milestone evidence: [reference/mainline/first-boot-20260906/](reference/mainline/first-boot-20260906/).

Three pieces made that possible.

**The watchdog** (`drivers/watchdog/ax630c_wdt.c`, from
[wdt-model-20260906.md](reference/mainline/wdt-model-20260906.md)) is what
trap 3 in §5 predicted: U-Boot arms wdt0 immediately before `booti`, so #74's
kernel was hard-reset every time. The driver adopts the running dog instead of
restarting it — it programs the counter mux, its own reload and `WDOG_HW_RUNNING`
in one probe, so there is no window where the board is unprotected — and every
error path re-arms the block, because a failed probe that leaves the dog off
turns a diagnosable reboot loop into a silent hang. It caps
`max_hw_heartbeat_ms` at 10 s regardless of the advertised timeout, which makes
it safe whether the block resets at the first expiry or (as the spec infers)
the second.

**Reboot** does not come from the watchdog in the normal case. PSCI here
implements no `SYSTEM_RESET` — it still registers a priority-129 restart handler,
makes one SMC that returns NOT_SUPPORTED, and falls through — so the DT now
carries a mainline `syscon-reboot` node on `CHIP_RST_SW` (common syscon
`0x023400a8` bit 0), the same bit the vendor U-Boot's own reboot uses. The
watchdog's restart handler sits behind it at priority 128.

**Observability** is the other half, and on a board with no serial console it is
not optional. Three channels, all read back from slot A on the following boot:

| Channel | Holds | Survives |
|---|---|---|
| Milestone bits 12–15 of `TOP_CHIPMODE_GLB_BACKUP0` | reached userspace / stashed the log / completed the dwell / called `reboot` | warm reboot **and** raw chip reset (both measured) |
| Log stash at `0x480e8000` | the whole kernel log, verbatim, from the first printk | anything that leaves DRAM powered |
| ramoops at `0x480e0000` | console zone + panic dumps — the only channel when userspace never runs | ditto, and it is uncached so a watchdog reset cannot strand it in a dirty cache line |

Both regions sit in the 64 KiB tail of the window the vendor DT reserves for
its own pstore — specifically inside the *data* area of the vendor ramoops'
ftrace zone, which nothing writes unless pstore function tracing is on, and
whose zap at the vendor's probe rewrites only its own 12-byte header at
`0x480d0000`. **Do not move our zones to the head of that window:** the vendor
kernel zaps every zone it owns about 1.5 s into the boot that would have read
them, which was measured the hard way.

The `/init` is one static musl binary with no shell. It mounts `/proc` and
`/sys`, makes its own device nodes (devtmpfs is *not* auto-mounted on the
initramfs path), reaches the slot register, the heartbeat LED and its stash
through `/dev/mem`, then dwells 120 s — twice the bootloader's watchdog arm,
which is what makes the dwell a test rather than a courtesy — blinking a
three-short-one-long pattern and logging the watchdog's own `timeleft` every
10 s, before rebooting.

**Nothing re-arms `SLOTB_BOOTABLE`.** The SPL consumes it on the way in, so
every exit path — clean reboot, panic, hang, watchdog reset — lands the next
boot on slot A. That is the entire safety argument for the test, and it is why
the run is unattended: slot A and the rootfs are never written.

One trap worth carrying forward: `/dev/kmsg` writes are ratelimited to ten
records per five seconds per open file unless `printk_devkmsg` is `on`. A normal
system never notices because systemd sets it at boot; an initramfs inherits the
default and silently loses everything past the tenth line. The first boot lost
two milestone lines to it. `/init` now sets it before logging anything.

Still absent, by design: no storage, network, GPIO, USB or video driver. The
kernel reaches its initramfs and nothing further — #76 is the next step.

### What exists now (#76, 2026-09-06) — eMMC BOOTED, SD untested

**A mainline kernel enumerates this board's eMMC, parses the vendor partition
layout and reads the rootfs.** Milestone register `0x0003F014` on return; log
and analysis in
[reference/mainline/storage-boot-20260906/](reference/mainline/storage-boot-20260906/).

The issue's filed scope assumed this would be a driver port. It is not. The
controller is an **unmodified Cadence SD4HC** and mainline's own
`sdhci-cadence` drives it; the entire code delta is a 14-line patch adding a
compatible whose match data carries `SDHCI_QUIRK2_PRESET_VALUE_BROKEN`
(`pkgs/kernel-mainline/patches/`, kept in upstream-submission shape for #87).
The 1208-vs-675 line gap against the vendor fork is not Axera tuning — tuning
is byte-identical — it is clock/reset integration that belongs in DT, plus dead
code. Full accounting:
[sdhci-model-20260906.md](reference/mainline/sdhci-model-20260906.md).

Three decisions in the DT are worth carrying forward, because each would have
passed a first boot and failed later:

- **No `resets`, on any mmc node.** Mainline reserves that property for the
  card's `RST_n` and binds index 0 to `card_hw_reset`, so listing the
  controller's own APB reset there makes `mmc_hw_reset()` — an error-recovery
  path — reset the host. Firmware leaves all three SoC lines deasserted, so
  doing nothing is correct. The reset and sdhci specs reached this
  independently, in separate contexts.
- **No `sdhci-caps-mask`.** Redundant with the `cap-*` properties, and it
  leaves the eMMC on a 1.8 V-only OCR by accident rather than intent. It is
  *not* the probe-killer it first looked like — `CAPS0 = 0x176AC8B2` advertises
  all three voltages and the mask leaves `CAN_VDD_180`.
- **No `cdns,phy-input-delay-mmc-legacy`.** PHY address `0x06` has no entry in
  any driver's property table, the vendor's included, so that value has never
  been applied to this board.

Clocks were the hidden dependency. #80 registered the 246 clocks the *vendor*
CCF registered, and the vendor CCF models none of eMMC, SD, SDIO or UART — its
own drivers programmed those windows by hand. `sdhci-cadence` calls `clk_get()`,
so #76 added thirteen rows (counted out of the compiled table; the "fifteen"
this paragraph used to claim counted two IDs that are declared in the binding
header and deliberately never registered). The bus gates cannot be named in DT (the binding
allows one clock per node) and are `CLK_IS_CRITICAL` instead; `clk: Disabling
unused clocks` runs before the card enumerates and leaves them alone, which is
that marking working. **This generalises: anything calling `clk_get()` on a
block the vendor drove by hand will hit the same gap.**

The eMMC card mux is registered with all four parents, from the SDK's own
manual rather than from source — no vendor source names values 0–2. The SD and
SDIO card muxes are deliberately *not* registered: that manual covers eMMC
only, so their dividers parent straight onto `npll_400m`, which describes every
state the hardware is ever in.

Two things the run corrected:

- `CONFIG_BLK_CMDLINE_PARSER`, added in #74 to honour `blkdevparts=`, **does
  not exist in 7.x**. The eMMC has no on-disk partition table, so the first run
  came back with a perfectly healthy card and no partitions. The symbol is
  `CMDLINE_PARTITION`, gated behind `PARTITION_ADVANCED`. The build's
  "fragment survived `olddefconfig`" assertion was a hand-maintained list that
  did not include it — it is now generated from the fragment and checks every
  line, so a misspelled or unsatisfiable symbol fails the build.
- The card negotiates **HS200** from `CAPS1` SDR104, not from the DT properties
  this issue withheld. The read-gap tuning storm that the conservative
  `max-frequency = <50000000>` hedges against does not occur, so that hedge and
  the `mmc-hs400-*` properties can be restored.

**Not proven: the SD slot.** `mmc1` binds and the controller is healthy, but
there is no card in the device — so rooting a mainline system from SD, the half
of #76 that gives #77 a shell, is blocked on hardware.

### What exists now (#77, 2026-09-06) — ETHERNET UP, SSH ON MAINLINE

**`tools/kvmssh` reaches a mainline kernel on this board, over Ethernet, at the
same address and with the same password as the vendor system.** Gigabit, full
duplex, 111 MB/s over raw TCP, 0 % loss over 100 pings, zero interface errors
after 321 MiB. Evidence, both runs and the device reads that explain them:
[reference/mainline/ethernet-boot-20260906/](reference/mainline/ethernet-boot-20260906/).

The MAC needed no reverse engineering. It is a stock Synopsys DWMAC 4.10a,
mainline stmmac drives it, and `drivers/net/ethernet/stmicro/stmmac/dwmac-axera.c`
is ~230 lines whose whole job is three fields in the flash syscon at
`0x1003_0000` that live outside the MAC's own window: `+0x28[10:9]` selects RGMII
on the external pads, `+0x14` bit 8 is the block reset, and `+0x00[5:4]` is the
transmit-clock mux. Four things are worth carrying forward.

**The PHY is not what the device tree says it is.** The vendor DT declares
`compatible = "ethernet-phy-id937c.4030"` — a JLSemi JL2101 — on the PHY node,
and an `ethernet-phy-id*` compatible makes the MDIO core skip the bus read
entirely. Asked directly over MDIO, the part answers PHYID1 `0x001c`, PHYID2
`0xc916`: a **Realtek RTL8211F**. So the vendor has been binding a JLSemi driver
to a Realtek chip for the life of this product, and it works only because that
driver programs almost nothing. Mainline reads the real ID and binds its own
realtek driver. There is no JL2101 driver to write; that half of #77's filed
scope does not exist.

**`phy-mode` must be `rgmii-id`, and getting it wrong is invisible.** The
RTL8211F's two 2 ns delays come up enabled from pin-strapping — measured on the
running vendor system, page 0xd08 TXCR bit 8 and RXCR bit 3 both set — and
nothing in the vendor stack ever writes them. Mainline's realtek driver is not
so passive: `rtl8211f_config_rgmii_delay()` writes both bits to match
`phy-mode`, so `"rgmii"` *disables* the delays the board is built around. Run 1
had it: the link trained, reported `1Gbps/Full`, dropbear came up, and not one
DHCP packet completed a round trip. **A link that trains and passes nothing is
an RGMII delay problem, always.** The two runs differ in this property alone.

**One clock has to move at runtime, and #80's driver refused to move it.** The
RGMII transmit clock is a three-input mux (`epll_5m` / `epll_50m` / `epll_250m`
= 10 / 100 / 1000 Mbit), and the block halves it, so the gate carries exactly
twice `rgmii_clock()`. Two consequences: stmmac's generic
`stmmac_set_clk_tx_rate()` cannot be used (it would ask for 125 MHz and get
`epll_50m`, the nearest input at or below), and the mux must be able to
re-parent under `clk_set_rate()`. #80 registered every mux with
`clk_hw_determine_rate_no_reparent`, which is the right default — these muxes
mostly select between domains firmware fixed — so #77 adds an opt-in
`AX630C_MUX_RC` variant using `__clk_mux_determine_rate` and marks exactly one
row with it. The glue logs what it got (`RGMII tx clock 250000000 Hz (asked
250000000)`) because a mux that silently did not move looks precisely like the
delay bug above.

**Four clocks, not the vendor's five, and no `resets`.** `rmii_phy` drives the
on-chip EPHY, which this board does not use and which firmware leaves held in
reset (`+0x14` bit 9) and shut down (`+0x20` bit 0); naming it in DT would power
a block with nothing on the other end. The vendor's three reset lines go through
a controller mainline does not have — the MAC's own block reset is one syscon
bit, pulsed at probe, and the other two belong to that unused EPHY. The PHY's
own RSTn is GPIO1_A27 and there is no GPIO controller until #81, so the glue
takes the line's register address from DT (`axera,phy-reset-mmio`) and pokes it;
that property is a `TODO(#81)` that becomes `reset-gpios` on the PHY node.

The initramfs grew the other half of the answer. `/init` is still one static
musl binary, but the cpio now also carries static busybox and dropbear, and
after #76's storage probe mounts the eMMC rootfs read-only `/init` **harvests
two facts off it**: the MAC out of `/etc/network/interfaces` and root's password
hash out of `/etc/shadow`. Same MAC means the same DHCP lease, so the mainline
system answers on the address `tools/kvmssh` already knows; same hash means it
answers to the same password. No credential is built into the image, the Nix
store or this repository. (**Corrected by #78:** this entry originally called
the eth0 MAC a provisioning-time literal in that file. It is not — the vendor
`/init` recomputes it from `/proc/ax_proc/uid` on every boot and rewrites the
line. Harvesting the file still works, and is still the right thing for a
bring-up initramfs with no `/dev/mem` arithmetic in it, but the file is a cache
rather than the source.)
Static dropbear pulls in libxcrypt, which is what makes this work at all: the
vendor hashes root's password with yescrypt and musl's own `crypt()` cannot
verify that.

Milestone bits 18–21 are new — carrier up, address configured, ICMP round trip,
dropbear started — so the clear-mask became **`0x3FF000`** at the time and a
fully successful run read `0x003FF014` (#82 has since taken those to
`0x1FFF000` / `0x01FFF014`). The dwell is 300 s rather than 120, because
it is now also the window in which a human logs in; `touch /run/keepalive` from
that shell raises it to a one-hour cap, and nothing raises it past that. The
safety argument is unchanged and untouched: nothing re-arms `SLOTB_BOOTABLE`, so
every exit path still lands the next boot on slot A.

One #76 caveat this run turned up: on a mainline boot the flash syscon's SD and
SDIO **card muxes** (`0x1003_0000` bits [19:18] and [17:16]) read 0, not the 3
measured under the vendor stack — the vendor's own mmc driver writes that 3.
#76 deliberately leaves both muxes unregistered and parents their dividers
straight onto `npll_400m`, which describes the vendor's state and not the state
a mainline boot is actually in. Nothing depended on it (there is no SD card in
the device), but whoever does root-on-SD should check it first.

Not proven: PTP, wake-on-LAN, suspend/resume, and any MAC that is not harvested
from the vendor rootfs.

### What exists now (#80, later) — resets, WDT clocks, pin states — BOOTED

**Boot-tested on 2026-09-07** (slot B, kernel `7.1.3-nanokvm`, milestone register
`0x003FF014` on return — every bit). The watchdog resolved 24 MHz through CCF
with no fallback, was petted for a 3600 s dwell with `timeleft` never trending
down, and the board rebooted itself back to slot A; the pin states applied and
their pads came back owned by their drivers; eMMC and Ethernet were unaffected.
Evidence, including the peripheral-syscon words read back from the running
mainline kernel:
[reference/mainline/wdt-clocks-20260906/](reference/mainline/wdt-clocks-20260906/).

Two register words are the proof that the new rows address the bits they claim,
because they differ from what the **vendor** kernel leaves: `CLK_MUX0` bit 19 is
set because `assigned-clock-parents` asked for the 24 MHz source (the vendor
driver selects the slow one at probe), and `CLK_EB0` bit 15 is clear because
`clk_disable_unused()` gated wdt2's counter (the vendor leaves it running). Both
were predicted in the table comments before the boot.

The three things #75 and #76 left owed to this issue, now that the nodes they
attach to exist.

**A reset controller**, in `drivers/clk/axera/reset-ax630c.c`, registered by the
clock driver's own probe. The reset lines are bits in the words next to the
clock gates in the same eight syscon windows, so the seven clock-controller
nodes carry `#reset-cells = <1>` and there are no `reset-controller@` nodes: a
second DT node over one window means a second regmap and a second lock over
registers the clock half read-modify-writes. That is also upstream's house
style for this hardware shape (Rockchip CRU, sunxi CCU, Amlogic, MediaTek).

**148 lines** — the 144 the vendor DT binds to a consumer somewhere (cpu 4,
comm 5, vpu 3, mm 23, dispc 10, periph 82, flash 17) plus the four periph
`SW_RST3` lines the watchdog uses and no vendor DT node names. Active high, not
self-clearing; nothing is programmed at probe, because these are the resets of
blocks that are already running. The 10-cell "async" variant's clock cycle
around the release edge is deliberately absent: no current consumer needs it,
and it is a read-modify-write across two regmap operations that would race a
concurrent `clk_enable()`. It arrives with #83/#84 and the lock that makes it
safe.

**The watchdog no longer touches the syscon.** Its counter clock, APB clock,
two resets and counter-source mux are DT phandles now, and it takes its rate
from `clk_get_rate()` rather than a constant — so the timeout arithmetic is
right whichever source is selected, and a board whose firmware differs still
gets correct numbers. Six clock IDs made that possible: `CLK_WDT0/2_SEL`
(`CLK_MUX0` bits 19/20, one bit each, parents `rtc_out_32k` and `cpll_24m` —
both rates *measured*, 32.79 kHz and 24.007 MHz), `CLK_WDT0/2_EB` and
`PCLK_WDT0/2_EB`.

One ordering fact to keep: `assigned-clock-parents` is applied by the driver
core *before* probe, while U-Boot's dog is still armed and counting. Selecting a
faster source there would drain the remaining count 732× faster and reset the
board mid-boot. It is safe here because U-Boot already leaves the 24 MHz source
selected and `clk_set_parent()` is a no-op when the parent matches — nothing is
written at all. Never point that property at a source faster than firmware's.

**Pin states**, transcribed from the boot chain's own 133-write pad table:
`emmc`, `sd`, `sdio`, `uart0`, `uart1` attached to their nodes, and `i2c0` /
`i2c7` — the two the vendor board dts `/delete-property/`s — declared but
unreferenced until an I2C controller node exists. They are no-ops in value on
this board; the point is ownership, so a pad cannot be re-muxed out from under a
driver and a second claimant gets `-EBUSY` instead of a corrupted bus.

Three rules for anyone adding one:

- **Config properties must name `pins`, never `groups`.** The driver implements
  `pin_config_set` and not `pin_config_group_set`, and the core fails the whole
  state — taking the consumer's probe with it. On `&emmc` that is the rootfs.
- **The multi-pad groups are wider than they look.** `uart0` includes two RGMII
  pads as CTS/RTS; `uart1` includes `EMMC_PWR_EN` and `BOND2`, which this board
  uses for other things. Spell the pads out.
- **`drive-strength` is the pad's raw 4-bit code, not mA.** The mA mapping is
  not known for this SoC.

The §1.4 pull-encoding trap does not touch any of these states: all 27 pads are
one-hot-encoded. It applies to exactly one pad in the whole boot table —
`MICP_L_D`, whose `0x…83` is *no pull* in its group's EN/SE encoding, not the
pull-up a blind reading gives. That pad belongs to #81.

On the boot run 19 of those pads came back claimed by their drivers (11 eMMC, 6
SD, 2 UART0) with the bias and drive code the boot table specifies; the SDIO and
UART1 states are attached to disabled nodes and are correctly not applied.
`gmac` has no `pinctrl-0` yet — the node arrived with #77, after this was
written. Its RGMII pads are in the boot table, but a wrong state there takes out
the SSH path that makes a boot test readable, so it is a deliberate follow-up.

**A count this work corrected.** The clock driver registers **265** clocks, not
the 246 every comment in the tree claimed: #76 added thirteen rows for storage
and serial and left the counts behind. Measured out of the compiled tables in
`vmlinux`, not re-read from the source that generated them; per controller
common 135, mm 40, flash 30, periph 27, dispc 14, cpu 11, vpu 7, pllc 1. The
binding header names 267 IDs, two of which (the SD and SDIO card muxes) are
declared and deliberately never registered. The number is confirmed from a
third artifact by the boot run: `clk_summary` on the running kernel lists 265
clocks. #77 added no clock rows -- it converted one mux to the rate-changing
flavour and used rows the vendor table already had.

(#81 and #82 have since taken the tree to **282** clocks and **150** reset
lines: fourteen I2C/GPIO gates and muxes, three USB gates, and the two USB
software resets. Every figure here was re-derived the same way, from the table
sizes in the compiled `vmlinux` rather than from the source that generated
them; a `clk_summary` on a running kernel should list 283 names, those plus
the unrelated DT fixed-clock.)

### What exists now (#81, 2026-09-07) — GPIO, ATX AND THE HDMI RECEIVER

**Boot-tested on hardware, milestone register `0x003FF014` on return.** Two
slot-B runs; evidence, including the pad words that prove the pin controller
moved them:
[reference/mainline/gpio-lt6911-20260907/](reference/mainline/gpio-lt6911-20260907/).

`drivers/gpio/gpio-ax630c.c` drives the four 32-line controllers — DesignWare
in its register names only, one 32-bit word per line at `base + (n + 1) * 4`,
so `gpio-dwapb` cannot bind. The whole point of it is `chip.request`: with the
97 `gpio-ranges` in DT, a GPIO claim reaches #80's `gpio_request_enable()`,
which programs the pad's mux, and strict mux enforcement then stops a
peripheral state taking the pad back. **That is the SW_PWR trap fixed at the
root**, and it is measured rather than argued — four pad words differ from what
the boot chain's own table writes, in the mux field, because a driver asked for
those lines: `EPHY_LED0` `0x00000083` → `0x00060083`, and the three `CDTX_*`
pads `0x00000003` → `0x00060003`. Those four are exactly the pads the vendor's
LT6911 driver re-muxed by hand with a raw `iowrite32`.

The ranges are the vendor DT's 97 single-line entries collapsed into runs. The
mapping is not an identity — a lazy `<&pinctrl 0 0 32>` would mux the wrong
pads — so the build asserts the compiled blob still covers 97, and the run-for-
run expansion was diffed against the vendor source pair for pair.

`drivers/misc/lt6911-manage.c` replaces the vendor's 2907-line
`lt6911_manage.c`: an i2c driver bound as a child of i2c0 at `0x2b` instead of
`i2c_get_adapter(0)`, GPIO descriptors instead of seven global line numbers,
and nothing at all instead of seven blind pad-mux pokes. It is scoped to the
UXC — the vendor file also carries LT6911C and LT6911D register maps and an
AX-Pi pin set behind a board check its own header compiles to a constant.
`/proc/lt6911_info` keeps all fifteen files and every payload string, because
libkvm, the Go server and the display daemon all parse them; on the running
mainline kernel it reports the attached host at 4096×2160@29, `access`,
`no hdcp`, and a `version` string carrying the `Desk` token and device number
the server looks for.

Five vendor bugs did not survive the port: a write handler that `strncmp`s a
`__user` pointer, user-controlled VLAs that made `dd bs=1M of=…/edid` a kernel
stack overflow, a bank cache never invalidated across the chip power cycles its
own EDID paths perform, a snapshot buffer every read clobbered the first nine
bytes of, and no locking anywhere. Only the last of those is visible to a
consumer, and only as `edid_snapshot` now returning the EDID it holds.

Four more things landed with it.

- **Fourteen clock rows**, so 279 clocks rather than 265: an I2C and a GPIO
  source mux, their class gates, and one gate per instance. Every field sits
  where the binding header's descending-bit enumeration puts it, and each word
  is anchored by a clock the vendor CCF does register. The proof they address
  the right bits is a diff against #80's boot: `CLK_EB0` reads `0x00007DE3`
  where that run read `0x00007DE7`, and the single differing bit is the one
  newly registered as `clk_i2c_eb`.
- **i2c0 exists**, stock `snps,designware-i2c`, with the pin state #80 declared
  and could not attach. Its APB gate is *named* rather than marked
  `CLK_IS_CRITICAL` the way #76's mmc bus gates had to be: a NULL `clk_get()`
  ignores `clock-names` and takes index 0, so a binding that wants one unnamed
  clock and one called `pclk` can have both. The vendor's "gpio" bus-recovery
  state is deliberately not carried — it claimed GPIOs while its own pin states
  left the pads on the controller, so it bit-banged pads it did not own.
- **#77's raw PHY-reset poke is gone.** `EPHY_RSTN` is `reset-gpios` on the PHY
  node and the MDIO core pulses it, with the same 15 ms assert and 75 ms
  settle, before it reads the PHY's ID.
- **`nanokvm-gpio` is a program now**, not the name of a systemd unit that
  exported four global numbers through `/sys/class/gpio` and poked a pad
  register with `devmem`. It resolves a line by its DT name over libgpiod, and
  the request is what programs the mux. `nanokvm-server` gains a `gpioBackend`
  argument defaulting to `sysfs`, whose build is byte-identical to before — the
  shipped 4.19 image does not move — while the NixOS appliance takes the
  `libgpiod` build and drops the unit.

**The reset provider's `.status` got its first real use** and reports what the
syscon says: `SW_RST0` = `0x00000001`, every GPIO reset bit clear. `.assert`
and `.reset` are still untested on silicon, and deliberately so — lines on
these blocks drive the host's ATX power button and the HDMI receiver's rails,
so a reset pulse at probe would be a keystroke nobody pressed. The first
consumer that needs one will be #83 or #84.

Two gaps in `gpio-devmem-20260906.md` closed on the way. **EXT_PORT does loop
back a driven output** (measured on the heartbeat LED), so `.get()` reads the
pad rather than the output latch — the vendor answers from the latch, which is
precisely the read that hid the SW_PWR trap. And the identity words: `ID_CODE`
is 0 on this silicon, `VER_ID_CODE` is `0x41584552`, ASCII.

Still owed: `nanokvm-gpio` has never run on hardware — it targets the NixOS
appliance and there is no mainline userspace yet, so the ATX pulse is proven
kernel-side and not end to end. No ATX line was driven, because pressing
`atx-power` presses a button on someone's machine. The `edid` and `version`
write paths program the bridge's flash and are transcribed but untested. And
the eMMC's card reset stays a TODO on the mmc node: `cap-mmc-hw-reset` plus
`reset-gpios = <&gpio2 23 GPIO_ACTIVE_LOW>` would work now that a GPIO
controller exists, but the vendor DT calls that line active *high* and getting
the polarity wrong holds the rootfs device in reset.

### What exists now (#82, 2026-09-07) — USB GADGET ENUMERATED BY A HOST

**A machine on the other end of the cable enumerated a mainline-kernel gadget
from this board.** One slot-B run, milestone register `0x01FFF014` on return —
every bit — and the board rebooted itself back to slot A. The gadget bound at
`t = 12.63 s` and the host had it configured 1.0 s later, at high speed.
Evidence, including the clock rows and flash-syscon words read from the
running mainline kernel:
[reference/mainline/usb-gadget-20260907/](reference/mainline/usb-gadget-20260907/).

The controller needed no reverse engineering either. It is a stock Synopsys
DWC3 in a high-speed-only configuration, mainline's dwc3 core drives it, and
`drivers/usb/dwc3/dwc3-axera.c` is ~210 lines whose whole job lives outside
the core's own window, in the flash syscon at `0x1003_0000`: the gates at
`+0x04` bits 12/14 and `+0x08` bit 5, the two software resets at `+0x14` bits
24/25, and `+0x40` bit 6.

**That last bit is the only reason a glue driver exists.** `+0x40` bit 6 is
VBUSVALID, and this integration has no VBUS comparator wired to the
controller: software tells the core whether VBUS is present. In peripheral
mode the bit must be **set** or the gadget never pulls up D+ and the host
never sees a device; in host mode it must be **clear**, because then the port
drives VBUS itself. Neither the dwc3 core nor `dwc3-of-simple` can express
that, and getting it wrong produces a controller that probes perfectly, logs
nothing wrong, and enumerates nothing.

**Two nodes, and the split is not cosmetic.** The outer node is the glue and
holds the clocks, the resets and the syscon phandle; the inner one is the
core, `compatible = "snps,dwc3"`, and it names the 24 MHz reference as `ref`.
Mainline's `dwc3_ref_clk_period()` derives `GUCTL.REFCLKPER`,
`GFLADJ.REFCLK_FLADJ` and `GFLADJ.240MHZDECR` from `clk_get_rate()` on that
clock, and rate == 24000000 exactly reproduces the three constants the vendor
glue hardcodes: `0x29`, `0x7f0`, `0xa`. Handing the core
`snps,ref-clock-period-ns = <41>` instead sets the period right and the
frequency adjustment to **zero**, because 10⁹/41 is 24.39 MHz and the core
would conclude no adjustment is needed. Same register, silently 1.6 % off.

`clk_summary` on the running board shows `clk_usb_ref_eb` at **24000000**,
enabled, with consumer `8000000.usb` and connection id `ref` — the core node's
clock, not the glue's. Read that for what it is: the consumer binding is an
independent fact (the clock framework's own consumer list, and it is what
proves the DT split works), and 24000000 is the rate the core's GFLADJ
arithmetic actually ran on — but the *number* is the driver's own model
echoed back, not a measurement. The silicon evidence for 24 MHz is elsewhere:
#80 measured `cpll_24m` at 24.007 MHz, and the vendor glue's hardcoded
`0x7f0`/`0xa` are only reproducible from a rate of exactly 24000000. The glue
logs **2 clocks**, which is the design working and not a missing one.

**Three clock rows and two reset lines, confirmed by two artifacts that
agree.** The flash window's id-to-bit relation is arithmetic — every
registered id in the `0x04` word sits at bit `25 - id` and every one in `0x08`
at bit `45 - id` — and the vendor dwc3 glue independently names exactly the
`BIT()` positions that arithmetic predicts for the three ids the vendor clock
binding header declares (11, 13, 40). `bus_clk_usb_eb` hangs off
`clk_flash_glb_sel`, the AXI bus clock the whole flash domain shares with the
EMAC and both SD hosts, and is deliberately **not** `CLK_SET_RATE_PARENT`: the
vendor glue sets that mux to 312 MHz at USB probe, firmware already leaves it
there, and a rate request propagating from here would move the eMMC's and the
MAC's bus clock as a side effect. `usb_ref_alt_clk_eb` gets a NULL parent for
the reason #76's SD bus gates do — its source is not established in any
artifact we have.

**This is the reset controller's first real `.assert`.** #80 shipped the
provider and programmed nothing at probe, because every line it described
belonged to a block already running. These two do not: they are active high,
not self-clearing, and firmware leaves them released, so the glue asserts,
waits 2 µs and releases. A deassert-only bring-up — which is all the dwc3
core itself would do — never resets the PHY at all.

It behaved: both calls returned 0, probe carried on, and SW_RST0 (`+0x14`)
reads `0x3C0002E0` afterwards with bits 24 and 25 clear. Be precise about what
that shows — the `.assert` path ran and its regmap writes succeeded, which
nothing before this run had exercised, but a clear reading is also what
"nothing was written" looks like. Catching the asserted state needs a read
from inside a 2 µs pulse.

**`dr_mode = "peripheral"`, not the vendor's `"otg"`.** OTG on this board is
ID detection on a raw GPIO (GPIO1_A4) through `linux,extcon-usb-gpio`, and
there is no GPIO controller node until #81 — the same wall #77 hit with the
PHY reset line and #76 with the eMMC card reset. It is also what the appliance
actually wants: nothing is ever plugged *into* this port. The kernel keeps
`USB_DWC3_DUAL_ROLE`, so #81 turns this back on with a DT change and not a
rebuild. The TODO with the exact node text is in `dts/ax630c.dtsi`.

**No pin state, deliberately.** The pin controller's only `usb` group is
MICN_R_D / MICP_R_D muxed to USB_OVRCUR / USB_POWER_EN — host-side
overcurrent and VBUS-enable signals. The vendor board dts never claims them,
this board is a peripheral, and both pads use the EN/SE pull encoding of the
§1.4 trap. The data pads are analog and are in no pinmux table at all.

**The gadget is now a kernel config fact.** `USB_CONFIGFS` is built in (arm64
defconfig makes it a module, and there is no module path on this board until
#78) along with all five function drivers `/kvmapp/scripts/usbdev.sh` needs:
HID, mass storage, NCM, UAC2 and ACM. `SOUND` and `SND` come with UAC2, which
is a bool that `depends on SND` and cannot be satisfied by the modular
default; that is the only reason the sound core is compiled in, and the
board's real audio path is still #84.

**Three new milestone bits, and they fail independently.** Bit 22 is a UDC
registered — the glue probed and the core bound, pure kernel side. Bit 23 is
every one of the five function drivers present (each probed by a `mkdir` under
`functions/` that instantiates it, then removed) *and* a HID boot-keyboard
gadget assembled through configfs and bound by writing the controller's name
to `g0/UDC`, which is what starts the gadget and pulls up D+. Bit 24 is the
UDC reaching state `configured`: a host on the other end enumerated us and
selected a configuration.

Only bit 24 depends on anything outside the board, and the physical USB link
on this unit has been unreliable since 2026-09-05 (#42 was a physical fault).
So **22 and 23 set with 24 clear means "look at the cable", not "USB is
broken"** — that separation is the whole point of using three bits rather than
one. The clear-mask is now **`0x1FFF000`** and a fully successful run reads
`0x01FFF014`.

The gadget identifies itself as Linux Foundation `1d6b:0104` with product
string `NanoKVM-Pro mainline bring-up`. Deliberately not a Sipeed id: this
gadget is not the vendor's and must not claim to be, and the string makes it
unmistakable in `lsusb` on the attached bench host. Its report descriptor is
the boot-protocol keyboard one from `Documentation/usb/gadget_hid.rst` — the
same shape as `usbdev.sh`'s `hid.GS0` because there is only one shape a boot
keyboard can have, but copied from the kernel's own documentation.

#### How this was measured, and how to re-measure it

Standard slot-B loop (`.claude/skills/mainline-boot-test`), with the mask at
`0x1FFF000`. Two oracles, and they answer different questions:

- **Device-side, no host needed.** From the mainline shell during the dwell:
  `ls /sys/class/udc` names the controller (`8000000.usb`),
  `cat /sys/class/udc/*/state` says how far enumeration got, and
  `ls /sys/kernel/config/usb_gadget/g0/functions` shows the bound gadget.
  `dmesg | grep -i -e dwc3 -e axera-dwc3` carries the glue's own
  `2 clocks, VBUSVALID set (peripheral mode)` line. And
  `grep -e clk_usb_ref_eb -e bus_clk_usb_eb -e usb_ref_alt_clk_eb
  /sys/kernel/debug/clk/clk_summary` is the check that matters most: the ref
  row must read **24000000** and be enabled, because that number is what the
  core's GFLADJ arithmetic is built on and nothing else reports it. **Mount
  debugfs first** (`mount -t debugfs none /sys/kernel/debug`) -- the bring-up
  initramfs does not, and the grep silently returns nothing if you forget.
- **Host-side.** `lsusb -d 1d6b:0104` on the machine the KVM's USB-C is
  plugged into shows "NanoKVM-Pro mainline bring-up", with a `hidraw` node and
  an `input` device in its `dmesg`. **We have no shell on that machine**, so
  this run took the equivalent from the device instead: bit 24 and
  `/sys/class/udc/*/state = configured`, which is the same fact read from our
  end of the cable. Before arming slot B, check the vendor system's own
  `/sys/class/udc/8000000.dwc3/state` -- if that already reads `configured`, a
  host is attached and bit 24 coming back clear is a real failure rather than
  an unplugged cable.

Not proven, and not attempted: mass storage, NCM, UAC2 and ACM as *running*
functions (only their drivers' presence is checked, 5 of 5), any transfer over
the HID endpoint, suspend and resume, and host mode.

### What exists now (#78, 2026-09-07) — APPLIANCE BUILDS AND BOOTS, IN QEMU

**The NixOS appliance is off the vendor kernel and off the second nixpkgs pin,
and it boots to multi-user with zero failed units and NanoKVM-Server listening
on :80 and :443.** Under `qemu-system-aarch64 -M virt`, not on the board — the
device was #81's and then #82's while this was written. Evidence, both runs
and the two defects the first one found:
[reference/mainline/nixos-appliance-20260907/](reference/mainline/nixos-appliance-20260907/).

`nixpkgs-rootfs` is deleted from `flake.nix`. It existed only because systemd's
declared minimum kernel rose to 5.4 and then 5.10 while the `ax_*.ko` vermagic
contract held this board on 4.19.125; the image has carried no vendor kernel
module since #54 and the appliance now runs 7.1.3, so the pin, its EOL-security
cost and the "two glibcs, one loader" hazard go with it. So do the runtime
consequences of the vendor defconfig: user namespaces exist here, `PrivateUsers=`
works, and `pkgs.buildFHSEnv` is no longer impossible.

**The initrd rides inside the kernel Image, and that is not a shortcut.**
U-Boot's `do_axera_boot()` calls `booti` with `-` for the ramdisk argument and
there is no partition holding one, so `CONFIG_INITRAMFS_SOURCE` is the only
route an initrd has onto this board. `pkgs/kernel-mainline.nix` takes the cpio
as a parameter and builds two variants: `bringup` (the #75 evidence init,
uncompressed, byte-for-byte reproducible) and `appliance` (NixOS stage 1, zstd).
25 MB of cpio becomes 6.8 MB; the Image is 50.6 MB and the signed slot-B image
23.5 MB, against a 64 MiB partition. `boot.initrd.compressor = "cat"` on the
NixOS side, because a `*.cpio` source is embedded verbatim and then compressed
once — compressing it twice only makes the Image bigger.

**There is no `init=` on the command line, and there cannot be.** The cmdline
comes from the U-Boot environment, which `fdt_chosen()` writes over `/chosen`
at `booti` (trap 2, section 5) — the device tree's string is a documented
default, not the authority. NixOS stage 1 therefore falls back to its built-in
`stage2Init=/init`, so the image ships `/init` as a symlink to
`/nix/var/nix/profiles/system/init`. Updating that profile is the entire
generation switch: no bootloader, no config file, no partition write.
`boot.loader.external` owns "install" and is inert until #79 puts a health gate
in front of an A/B slot flip.

**The `/dev/console` trap, which only exists because the initrd is embedded.**
The kernel ALWAYS unpacks a built-in initramfs; with `INITRAMFS_SOURCE` empty it
unpacks `usr/default_cpio_list`, whose whole content is `/dev`, `/dev/console`
and `/root`. Setting `INITRAMFS_SOURCE` **replaces** that list — and a NixOS
initrd carries no device nodes, because on a machine where the bootloader hands
the initrd over separately it has never had to. PID 1 then starts with fd 0/1/2
closed and stage 1 dies on its first `exec 8>&1`, printing nothing. Read through
the #75 milestone channel that is `0x00000014`: exactly what a kernel that never
reached userspace leaves. `nixos/rootfs.nix` appends a three-entry cpio built
under `fakeroot`; the unpacker resets at each `TRAILER!!!`, which is how
concatenated initramfs images have always been supported.

**Identity, and the IRAM0 base this closes.** Section 2 recorded the `0x740`
offset as verified and the IRAM0 base as inferred. The vendor GPL driver settles
it: `ax_hwinfo_probe()` does `ioremap(MISC_INFO_ADDR, sizeof(misc_info_t))` with
`#define MISC_INFO_ADDR 0x740` and no base added, so IRAM0 is at physical 0 and
`misc_info` is at physical `0x740` — `uid_l` at `0x788`, `uid_h` at `0x78c`.

The derivation itself also needs correcting. #77's entry says the eth0 MAC is a
provisioning-time literal in `/etc/network/interfaces`. It is not: the vendor
`/init` (carried verbatim by `pkgs/initramfs.nix`, extractable from
`.#initramfs`) recomputes it from `/proc/ax_proc/uid` on **every** boot and
sed-writes that line. The file is a cache, not the source. The full chain, which
`nanokvm-identity.service` now reproduces byte for byte:

```
device_key = field 2 of /proc/ax_proc/uid, "0x" stripped, written with a newline
HHLL       = first 4 hex chars of sha512sum(/device_key)     # the hash is OF THE FILE
MAC        = 48:da:35:xx:HH:LL          hostname = kvm-HHLL
```

so a mainline boot keeps the MAC, the DHCP lease and the hostname the unit has
always had. The service prefers `/proc/ax_proc/uid` when it exists — which is
also how the arithmetic gets validated against a vendor boot — and otherwise
reads the two words with `busybox devmem`. `read(2)` on `/dev/mem` cannot reach
them: `xlate_dev_mem_ptr()` is a linear-map translation and `0x740` is not
System RAM, so it has to be an `mmap()`. That, `nanokvm-checkboot`'s slot-register
write and the whole vendor script layer are why `CONFIG_DEVMEM` stays on and
`STRICT_DEVMEM` stays off in the appliance — recorded as a decision, not an
inheritance. **Unproven on hardware.**

**`/etc/fw_env.config` ships, derived rather than captured.** The TODO in
`nixos-rootfs.md` asked for a device read. It was not needed:
`nixos/emmc-partitions.nix` parses the `blkdevparts=mmcblk0:` clause out of
`dts/ax630c-nanokvm-pro.dts` — the string U-Boot itself parses, and the only
definition this eMMC has of its own layout — sums the six partitions before
`env`, and asserts `/dev/mmcblk0 0x4C0000 0x100000` against the value section 6
derives independently. The same parse supplies p16, p17 and the A/B slot
partition numbers, so three hand-copied numbers collapse into one source, and
`nix flake check` gains `emmc-partition-map`, which prints all seventeen with
their offsets. That printout also settles the discrepancy section 10 flags —
`optee` is **p10/p11** at `0x11C0000`/`0x12C0000` and p8/p9 are `logo`/`logo_b`
— and narrows it: `pkgs/image.nix` was already right, and the two wrong places
were `pkgs/boot.nix`'s header (`p8 optee`) and `docs/updates.md`'s coverage
table (`logo (p10/11)`, inverted). Both fixed.
`nanokvm-checkboot` is live for the first time as a result — it was inert for
want of this file — and a hexdump check against the real environment is the one
thing still owed before the first `fw_setenv`.

**Two defects QEMU found that a build never would**, both inherited from the
4.19 scaffold and both certain to have fired on the device: `nanokvm.service`
had the tmpfs copy as an `ExecStartPre` under
`WorkingDirectory=/dev/shm/kvmapp/server`, and systemd applies `WorkingDirectory`
to every `Exec*` line — so the command that CREATES the directory was chdir'd
into it first and died `200/CHDIR` on every boot. With that split into
`nanokvm-appdir.service`, `NanoKVM-Server` wrote its default config, bound both
ports, and exited 1 on `open /etc/kvm/server.crt: no such file or directory`.
That was gap 1 in `nixos-rootfs.md` — the cert half of the vendor `nanokvm.sh`
supervisor, which exists only in the vendor rootfs. `nanokvm-cert.service`
generates a self-signed per-device pair if absent, and the server runs.

**Nothing closed, and the build proves it.** `nixos/rootfs.nix` fails if any
path in the system closure is `axera-libs`, `ax-ko-blobs` or `libsns-dummy`, and
it fired the first time: `pkgs/kvm-encoder.nix` sets libkvm's DT_RPATH to
`/opt/lib:<axera-libs>/lib` so one artifact serves both encoder configurations,
and on an overlay rootfs that store path is a dead string — in a Nix closure it
is a reference, and it dragged the entire closed library set into an image
meant to contain none of it. The appliance re-RPATHs **both** `libkvm.so` and
`libkvm.so.0` (two real files, not a symlink pair) at the three open libraries
it actually needs, and `/opt/lib` now holds only libopus, libasound and
libjpeg.so.8.

Still absent, by design: there is no `/lib/modules` tree at all, because every
driver this board has is built in — the first thing that needs one is #83.
`nanokvm-video` (#83) and `nanokvm-usb` (#82) are stubs that succeed and name
the issue owning what they cannot do, so the ordering edges stay real and a boot
log explains the missing pipeline instead of leaving a silent black stream. Both
sibling issues landed while this was being written, and each moved the line
differently:

- **#81 removed the GPIO stub outright.** There is no GPIO unit at all now.
  The appliance ships `nanokvm-gpio` on PATH and takes the
  `gpioBackend = "libgpiod"` server build, and the ATX lines are addressed by
  their device-tree names rather than exported through sysfs.
- **#82 moved the USB stub's reason.** The dwc3 glue is in-tree and the config
  builds `USB_CONFIGFS` plus all five function drivers, so the kernel half is
  done and a host has enumerated a gadget off this board. What the appliance
  still lacks is the *policy* — `usbdev.sh`, which exists only in the vendor
  rootfs (gap 2 in nixos-rootfs.md). The stub now says that, rather than
  claiming there is no glue.

In product terms this appliance serves the web UI and ATX, and nothing else
behind it: no video, no keyboard, no mouse.

Not proven: anything about the AX630C. QEMU supplied the device tree, the
clocks, the block device and the console. The hardware half is the loop-image
root — `.#nixos-appliance-loop` plus `.#kernel-mainline-appliance-loop-slot-image`,
a rootfs image FILE dropped on the vendor rootfs and loop-mounted by stage 1, so
the reversible slot-B harness stays reversible and rollback is `rm` plus a
slot-B restore. Root-on-SD is still blocked on there being no card in the unit.

### What exists now (#78, later the same day) — THE APPLIANCE BOOTS THE BOARD

**A NixOS 26.11 system on mainline Linux 7.1.3 boots the AX630C with the
device's own MAC, its own DHCP lease and its own derived hostname, zero failed
units, and NanoKVM-Server serving HTTPS — in 26.3 s.** Six slot-B runs; root was
an image FILE on the vendor rootfs throughout, so nothing on the eMMC was
overwritten and slot A, the boot chain and `p16` were never written. Full
account, including the four things that had to be fixed to get there:
[reference/mainline/nixos-appliance-20260907/HARDWARE.md](reference/mainline/nixos-appliance-20260907/HARDWARE.md).

**The eMMC is not reliably `mmcblk0`, and when it loses it has no partitions at
all.** This is the headline, and it is not #78's alone — it affects every
mainline boot of this board. The three SD4HC instances probe concurrently; the
eMMC's layout comes from the `blkdevparts=mmcblk0:...` clause, which has no
on-disk partition table behind it and binds the table to a device **name**. When
the eMMC enumerates as `mmcblk1` the table is applied to `mmcblk0` — the empty
SD slot — and the eMMC comes up with no partitions whatsoever:

```
lost:  mmcblk1: mmc1:0001 AT3SFB 29.1 GiB           (no pN children at all)
won:   mmcblk0: mmc0:0001 AT3SFB 29.1 GiB
        mmcblk0: p1(spl) p2(ddrinit) ... p16(boot) p17(rootfs)
```

Two boots in five lost it. #76 and #77 never saw it because they happened to
win, and #75's bring-up init hid the depth of it by locating its partition by
name out of `/proc/partitions` — which cannot help, because in the losing case
nothing is named. The fix is three lines of `dts/ax630c.dtsi`: `aliases { mmc0 =
&emmc; mmc1 = &sd; mmc2 = &sdio; }`, so `mmc_of_parse()` pins each host index.

**A slot-B appliance needs its own way out, and both halves now have one.** The
#75 `/init` always ended in `reboot(2)`; an appliance is supposed to stay up,
and the kernel pets U-Boot's watchdog for as long as userspace does not open
`/dev/watchdog`. So one earlier run came up without network and stranded the
board until someone pulled power. `nixos/loop-test.nix` closes both halves and
hardware exercised both: stage-1 `panicOnFail=1` turned a failed carrier mount
into a panic and a slot-A boot 37 s later (NixOS stage 1's `fail()` is
*interactive* — it blocks reading a console nobody can reach), and the userspace
deadman fired at its full 900 s dwell and brought the board back unprompted.
Nothing re-arms `SLOTB_BOOTABLE`, so every exit lands on slot A by itself.

The deadman needed hardware to get right: its first version used `date +%s`, and
the image boots with its clock at the build epoch until timesyncd jumps it
months forward the moment DHCP lands — so the deadline was instantly in the past
and it fired at 62 s. `/proc/uptime` now.

**Identity is proven end to end**, and needed three fixes that each looked
sufficient alone. `hostnamectl` must be `--transient` (the plain call writes
`/etc/hostname`, a read-only store symlink); `networking.hostName` must be
**empty**, because systemd-hostnamed refuses a transient hostname when a static
one exists ("static hostname is already set, so the specified transient hostname
will not be used") — the `--transient` fix by itself only turned an error into a
polite refusal; and `dhcpV4Config.ClientIdentifier` must be `mac`, because the
same MAC is *not* enough to get the same lease when networkd sends a DUID in
option 61 and the vendor's udhcpc sent the MAC. With all three, the board comes
up at the address, MAC and hostname it has always had, all derived from the SoC
UID read through `/dev/mem` at physical `0x788`/`0x78c`.

`/etc/fw_env.config` is confirmed by use rather than by hexdump: `fw_printenv`
on the appliance read `bootsystem=B` out of the live U-Boot environment at the
offset `nixos/emmc-partitions.nix` computed. The milestone channel survives the
reboot (`0x0E000018` live, `0x0E000014` from slot A) — and the arming clear-mask
is **`0xFFFF000`**, not `0x7FFF000`, which misses bit 27. #81's `nanokvm-gpio`
ran on hardware for the first time, resolving all four ATX lines by device-tree
name; no line was driven, because pressing `atx-power` presses a button on
someone's machine.

Not proven: video (#83), the USB gadget's policy half (#82), the mini-display
(#84), and root on the `p17` partition itself — every run used the loop-image
root, which is what kept them reversible. The `mmc` alias fix has one good boot
behind it rather than a series; it is correct by construction, but the race it
closes was only ever visible statistically.

---
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

**Inferred (marked in §2):** ~~that genphy suffices for the JL2101 (the vendor
driver programs RGMII delay and an errata patch — a "links but corrupts"
outcome is the tell)~~ — **settled and half wrong, #77, 2026-09-06**: there is
no JL2101 on this board (it is a Realtek RTL8211F, PHYID 0x001cc916 read over
MDIO) and the vendor driver programs *no* RGMII delay at all, because its
operation mode is a compile-time NONE. The "links but corrupts" outcome was the
tell, and it happened — for the opposite reason, mainline's realtek driver
clearing delays the vendor left strapped on. That the mainline `pwm-dwc` core matches (register
offsets compared, OF glue status on the target kernel unchecked); that the
CSI-2 controller is Cadence CSI2RX-derived (blob symbol names + two register
offsets); that designware-i2s PIO is enough for HDMI audio without a `dma_per`
driver; the `fdt_chosen` space trap (well-grounded reading of `booti`'s state
mask, untested); ~~the IRAM physical address of `misc_info` (`0x740` offset is
verified, the IRAM0 base is not)~~ — **settled from source, #78, 2026-09-07**:
`ax_hwinfo_probe()` ioremaps the bare constant `MISC_INFO_ADDR` (`0x740`) with
no base added, so IRAM0 is at physical 0 and `misc_info` is at physical `0x740`
(`uid_l` `0x788`, `uid_h` `0x78c`). Still unread on hardware.

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
- ~~`docs/updates.md` ("OP-TEE (p8/p9)"), `pkgs/boot.nix` and `pkgs/image.nix`
  comments: OP-TEE is **p10/p11**; p8/p9 are `logo`/`logo_b`~~ — **applied,
  #78**, and the sweep narrowed it: `pkgs/image.nix` was already right, the two
  wrong places were `pkgs/boot.nix`'s header (`p8 optee`) and `updates.md`'s
  coverage table (`logo (p10/11)`, inverted). Both fixed; the map now comes from
  `nixos/emmc-partitions.nix`, which parses it out of the `blkdevparts=` clause.
- ~~`docs/nixos-rootfs.md` gap 3: the `fw_env.config` TODO is closeable —
  `/dev/mmcblk0 0x4C0000 0x100000` (verify by hexdump first). Its rootfs
  contract should also name `/proc/ax_proc/uid` as a mainline blocker.~~ —
  **applied, #78**. The file ships, computed and asserted rather than
  transcribed; the hexdump check is still owed. `/proc/ax_proc/uid` is named in
  the boot contract, along with the `/dev/mem` path that replaces it.
- CLAUDE.md docs index: add this file (coordinator's job per the task brief).

---

## 11. #89: mainline U-Boot and the minimal layout — investigation, 2026-09-07

Source-only, no device (the board was being flashed). Three trees were diffed:
`[SDK]/boot/{uboot,atf,bl1}`, upstream U-Boot **2020.04** and **2026.07**, and
upstream TF-A **2.7.0** — all Nix-fetched and pinned
(`u-boot-2020.04.tar.bz2` sha `0jp4slxm…`, `u-boot-2026.07.tar.bz2` sha
`012vf57d…`, TF-A `v2.7.0.tar.gz` sha `02r5w91s…`). Two describing subagents
did the bulk reading; every load-bearing claim below was re-read at the cited
file and line before it was written down, and two of their conclusions were
narrowed as a result (the DDR-retrain hazard, §11.6; FDL2's relation to the
`uboot` partition, §11.2).

### 11.0 Verdict

**Both mainline stages are tractable, and the vendor SPL is a better host than
expected.** The SPL hands BL31 a *stock TF-A `bl_params_t` v2 chain* in `x0`
with the standard `ARM_BL31_PLAT_PARAM_VAL` cookie in `x3`
(`[SDK]/boot/bl1/driver/atf/atf.c:11-40`, `spl/spl_main.c:351`) — so a mainline
TF-A with a new `plat/axera/ax630c` consumes it verbatim, and a mainline U-Boot
is entered exactly as any TF-A BL33. The vendor TF-A fork is upstream 2.7 plus
**one platform directory and nothing else** (68 files, +4264/−8; the eight core
lines are a log level and a commented-out banner). The vendor U-Boot fork is
huge — 325 files, **+157 811/−1954**, 216 new files — but almost none of it is
load-bearing: two of its biggest "drivers" are verbatim forks of code mainline
already ships (`sdhci_ax620e.c` is `sdhci-cadence.c`; `axera_emac.c` is
`dwc_eth_qos.c`), ~6 000 lines are a display stack we do not need, ~10 000 are
flashing/OTA commands upstream already covers, and ~2 500 are dead code that is
in no Makefile. **The port is on the order of 600–800 LOC of glue plus device
tree.**

**OP-TEE can be dropped**, and doing so is a build flag, not surgery: nothing in
our stack calls it (`dts/ax630c-nanokvm-pro.dts:96`), the ATF firewall's *only*
region is the OP-TEE region and without it `firewall_config()` simply disables
all eight regions
(`plat/axera/ax620e/drivers/firewall/firewall.c:119-124, 186-213`), and the SPL
builds its BL32 `bl_params` node only `#ifdef OPTEE_BOOT`. It frees 32 MiB of
DRAM and two eMMC partitions.

**The layout cannot carry a GPT.** The BootROM's boot source is a `chip_mode`
strap (`[SDK]/boot/bl1/board/board.c:27-31`) and this board is strapped to
`FLASH_EMMC` = 0 = the eMMC *user area*, where the signed SPL sits at byte
offset 0. A GPT's primary header and entry array occupy LBA 1–33, i.e. bytes
512–17 408, which is inside the SPL image. A DOS/MBR table has the same problem
at LBA 0. So the eMMC stays table-less; the `blkdevparts=` string keeps being
the table, which on the Linux side is *upstream* (`block/partitions/cmdline.c`,
`CONFIG_BLK_CMDLINE_PARSER`) and on the U-Boot side is the one genuinely new
piece of code the layout needs (§11.6).

**Biggest risk:** the SPL locates every later stage by **compile-time byte
offsets** baked into its own binary, so *any* layout change forces an SPL
rebuild and a full AXDL reflash — and with A/B enabled a header or checksum
failure is an immediate `while(1)`, not a slot flip (`boot.c:649-652`,
`:806-808`; the watchdog-arming fallback at `boot.c:1018-1027` is compiled out
because `AX_BOOT_OPTIMIZATION_SUPPORT` is FALSE). Recovery is AXDL, which is
host-supplied end to end and cannot be bricked — but it needs Jeremy's hands.

---

### 11.1 The vendor U-Boot fork, measured

`diff -rN` of upstream 2020.04 against `[UB]`:

| | files | lines |
|---|---|---|
| new files | 216 | +155 598 |
| modified upstream files | 95 | +2 213 / −739 |
| deleted (CI/lint config only: `.travis.yml`, `.gitlab-ci.yml`, `.azure-pipelines.yml`, patman test fixtures) | 14 | −1 215 |
| **total** | **325** | **+157 811 / −1 954** |

Two thirds of the new lines are data, not logic: 62 defconfigs for boards we do
not build (many of them 1 300-line full `.config` dumps), `stb_image.h` +
`stb_image_resize.h` (10 662 lines), six compiled-in boot-logo pixel arrays
(44 580 lines), and `cmd/axera/riscv/rtthread.h` (24 393 lines, not linked).

**A trap that governs every "is it compiled?" answer:** the checked-in defconfig
is not what gets built. `[SDK]/boot/uboot/Makefile.uboot:55` runs
`build/tools/config2defconfig.py`, which harvests variables out of `project.mak`
via `make -p`, maps them through `configs/axera_config_maps.txt`, **rewrites the
defconfig in place**, configures, then restores the backup — so the effective
config never appears on disk. It injects `CONFIG_SUPPORT_AB=y`,
`CONFIG_AXERA_AX630C_DDR4_RETRAIN=y`, `CONFIG_ENV_SIZE=0x100000`,
`CONFIG_ENV_OFFSET=0x4c0000`, `CONFIG_AXERA_DTB_IMG_ADDR=0x40001000`,
`CONFIG_AXERA_KERNEL_IMG_ADDR=0x40200000` and
`CONFIG_AXERA_MEMORY_DUMP_EMMC=y`. Separately, Kconfig `default y` beats
defconfig silence: `CMD_AXERA_MEMTEST` and `CMD_AXERA_UPDATE` are on although
absent from the file.

#### Inventory, with a verdict per item

| Vendor piece | LOC | What it is | Mainline answer |
|---|---:|---|---|
| `arch/arm/mach-axera/ax620e/ax620e.c` | 765 | `mem_map`, `wdt0_enable`, `chip_rst_sw`, boot-reason latch, `board_late_init`; ~520 LOC is Sipeed `mem=`/CMM/autoboot policy | **board patch ~90 LOC** |
| `…/board.c`, `chip_config.c`, `timer.c` | 346 | board-name tables, ADC calibrate, EPHY LED polarity; `board_early_init_f` (system counter `0x01B30000` → 24 MHz, WDT off, pinmux, thermal-abort) | **board patch ~50 LOC** |
| `…/pll_config.c` | 106 | `pll_set()` has zero callers; the PLLs arrive locked from bl1 (`bl1/board/board.c:222-249`) | **drop** |
| `…/emmc_sd_phy.c`, `dphyrx.c` | 448 | in **no Makefile**; `dphyrx`'s only call site is `#ifdef`'d on an undefined macro *and* commented out | **drop (dead)** |
| `…/common/pwm_common.c` | 204 | compiled, zero callers, coefficients copied from an AX650 EVB | **drop** |
| `board/axera/ax620e_emmc/ax620e_emmc.c` | 377 | 155 LOC `#if 0` SPI-LCD experiment, 31 LOC HAPS; live part is two DM probes | **board patch ~45 LOC** |
| `board/axera/ax620e_emmc/pinmux.c` + `build/projects/…/pinmux/AX630C_DEMO_pinmux.h` | 116 + table | **133 `{addr,value}` pairs**, one word per pad at `group_base + 0x0C + n*0x0C`, bits [18:16] function / [7:0] pad config. The NanoKVM table differs from the generic vendor one in 40+ entries: the whole eMMC group (`0x02309000`, native eMMC vs SFC/SPI-NOR), the SDIO group (`0x104F2000`), every RGMII pad at pad-config `0x0F`, and `0x02300060 = 0x00060003` — the source-side confirmation of the SW_PWR/VI_D7 trap in CLAUDE.md. Vendor U-Boot has **no** pinctrl driver | **new, 150–250 LOC** (or reuse #80's `pinctrl-axera`) |
| `drivers/mmc/sdhci_ax620e.c` | 1 512 | a verbatim fork of `sdhci-cadence.c` with `sdhci.c` inlined — same `SDHCI_CDNS_HRS04/06` bits, same PHY delay indices, `SDHCI_CDNS_MAX_TUNING_LOOP 40`, even `U_BOOT_DRIVER(sdhci_cdns)`. ~110 LOC is genuinely vendor (200 MHz clock mux, SD 1.8 V switch, DLL reset pulse, 4-bit-from-ROM cap mask) | **mainline has it** — `sdhci-cadence.c` matches `cdns,sd4hc` (2026.07 `drivers/mmc/sdhci-cadence.c:300`) and reads 11 of the 12 `cdns,phy-*` properties; **board patch ~120 LOC** for clocks/reset |
| `drivers/net/axera_emac.{c,h}` | 1 937 | a fork of `dwc_eth_qos.c`; its own banner says "Synopsys Designware Ethernet QOS", `EQOS_MAC/MTL/DMA_REGS_BASE` are byte-identical to mainline's, and the DT compatible is literally `axera,ax620e-eqos` | **board patch ~190 LOC** — a `dwc_eth_qos_axera.c` shaped like `dwc_eth_qos_starfive.c` |
| `drivers/net/phy/realtek.c` +115 | 115 | makes plain `rgmii` *also* set TX delay (page `0xd08` reg `0x11` bit 8) and **never touches RX delay** (reg `0x15`), so the strapped RX delay survives; plus a "JL2101" entry whose ops are the RTL8211F ops | **mainline has it, and differs**: 2026.07 `realtek.c:236-254` writes **both** `0x11` and `0x15` and *clears* either when `phy-mode` says so. See risk 1 |
| `drivers/serial/ns16550.c` +16 | 16 | DesignWare DLF fractional divisor for the 208 MHz UART clock, plus an FDL2 baud bail-out | **drop** — integer divisor 113 is 0.14 % off at 115200 |
| `env/mmc.c` +29 | 29 | derives the env offset from the `blkdevparts=` string in `bootargs`, overriding `CONFIG_ENV_OFFSET` | **mainline has it** — fixed offset, or `u-boot,mmc-env-partition`; two defconfig lines |
| `common/board_f.c` +30/−28 | — | 26 of 30 lines are `debug()` → `ax_debug()`; no `init_sequence_f` change | **drop** |
| `common/board_r.c` +53 | 53 | moves `initr_mmc` ahead of NAND/OneNAND, adds `initr_display` and an I2C brute-probe of buses 0–14 | **drop** |
| `arch/arm/lib/crt0_64.S`, `cpu/armv8/start.S`, `armv8/Kconfig`, `interrupts_64.c` | 68 | fixed load at `0x5C000400`, skip relocation, `adr`→`adrp` reach, EL1 handoff, a debug backtrace | **mainline has it, 0 LOC** — `SKIP_RELOCATE`, `POSITION_INDEPENDENT`, `ARMV8_SWITCH_TO_EL1` |
| `drivers/usb/host/xhci-dwc3.c` +55, `drivers/usb/dwc3/dwc3-axera.c` | 179 | GFLADJ/GUCTL magic for a 24 MHz reference | mainline computes the same values from a 24 MHz `ref` clock in DT; **board patch ~170 LOC**, or drop if U-Boot needs no USB |
| `drivers/i2c/designware_i2c.c` +137/−103 | — | ~85 % whitespace; the real change reads `clk`/`reset` u32 arrays from DT by hand | **board patch, DT only** |
| `drivers/gpio/axera_gpio.c` | 211 | it *is* DesignWare APB GPIO, and `CONFIG_DWAPB_GPIO=y` is already set | **board patch ~20 LOC** (compatible) |
| `drivers/sysreset/sysreset_axera.c` | 35 | must preserve `0x02390024` bits 12-15 | **board patch ~35 LOC** |
| `drivers/video/axera/**` (12 `.c`, ~7 300 LOC) + `bootlogo/*.c` (44 580) | ~52 000 | two unrelated displays — see below | **drop** |
| `cmd/axera/{download,update,sd_update,sd_boot,tftp_update,usb_stor_update,ax_ext4_tools,memtest,memory_dump,cipher,gzipd,emmc_scan,riscv}` | ~40 000 | FDL2 + flashing/OTA/diagnostics | **drop** — `mmc`/`ext4load`/`tftpboot`/`usb`/`mtest`/ramoops cover it |
| `drivers/spi/axera_spi.c`, `drivers/ata/dwc_ahsata_axera.c`, `drivers/dma/**`, `pwm`, `adc` | ~2 900 | not built, or built with no callers, or unnecessary for a fixed-SKU appliance | **drop** (keep `axi_dma_hw_init()`, ~20 LOC, called unconditionally from `arch_cpu_init()` — verify on hardware whether it is needed) |
| `net/{net,tftp,bootp,eth-uclass}.c`, `common/fdt_support.c`, `image-fdt.c`, `stdio.c`, `autoboot.c` | ~110 | OTA > 2 GiB widening, TFTP retries, an **arm32-only** FDT-grow (`CONFIG_CPU_V7A` — dead here), `fdt_high`, the logo hook | **drop** |

**Boot policy.** `bootcmd` is not compiled in; `board_late_init()`
(`ax620e.c:638`) → `setup_boot_mode()` (`cmd/axera/setup_boot/setup_boot.c:227`)
sets `bootcmd=axera_boot` on every boot. `do_axera_boot()`
(`cmd/axera/boot/axera_boot.c:695-871`) then: reads `configs` off the FAT `boot`
partition to honour `maix_system_console`/`maix_kernel_loglevel`; shuts down the
EPHY; picks the slot from `bootsystem`; **arms the 30 s hardware watchdog
(`axera_boot.c:749`, `wdt0_enable(1)`, WDT0 `0x04840000`, TORR = 30 × 24 MHz)**;
raw-reads `kernel` → `0x5C500000` and `dtb` → `0x5C400000`, each behind a 1 KiB
`img_header`; runs the (efuse-gated, therefore no-op) signature check; gzipd-HW
decompresses to `0x40200000`/`0x40001000`; and `booti`s. The whole command is
**drop** — mainline `booti` with a DT cmdline replaces it — but three parts of
its *contract* must be reproduced: the watchdog, the load addresses, and the
partition table.

**Bootargs** are baked in at build time (`Makefile:1801-1819` →
`include/generated/ax_common_autogenerated.h`, from `partition_ab.mak:96-97`)
and then mutated at runtime in three places, each of which `env_save()`s — so
**the vendor U-Boot writes the eMMC environment on every boot**:
`update_cmdline()` patches the `boot_reason`/`board_id` digits in place by byte
index, `board_late_init` rewrites `mem=` from the board ID, and
`set_logo_mode()` appends ` logomode=vo0@dsi_dpi_video` (which is why that
sticky token shows up as an unknown parameter in mainline boot logs).

**`misc_info`, UID and MAC.** `misc_info` is not a partition: it is a fixed
struct at IRAM `0x740` written by bl1 from efuse
(`{pub_key_hash[8], aes_key[8], board_id, chip_type, uid_l, uid_h, thm_vref,
thm_temp, bgs, trim, phy_board_id}`). U-Boot reads it for thermal calibration,
the board name, EPHY LED polarity and the `board_id=` token — and **reads then
discards the chip UID**. There is no `mac-address` in the U-Boot DT, no
`.read_rom_hwaddr` in `eqos_ops`, and no `ethaddr` default, so
`net/eth-uclass.c:555` assigns a **random MAC on every boot** and does not save
it. Nothing about identity reaches Linux from U-Boot; #78's `/dev/mem` read of
the same efuse words is the whole story. A stable U-Boot MAC, if ever wanted, is
a ~30 LOC hash of `uid_l`/`uid_h` into a locally-administered address.

**Video and the boot logo — two different displays, and neither is needed.**
`drivers/video/axera/Makefile` is a bare `obj-y` under `ifdef CONFIG_VIDEO_AXERA`
with no per-file Kconfig, so all twelve `.c` files compile.
(a) `panel_spi.c` binds `compatible = "sipeed,for_jd9853"` on `spi2` and paints
the **172×320 front panel** from a compiled-in raw RGB565 C array — the six
`bootlogo/*.c` files are `#include`d, `sipeed_logo_len = 110080 = 172 × 320 × 2`
(`bootlogo/sipeed_logo.c:6883`), and they cost ~696 KiB of the 1536 KiB `uboot`
partition for six images of which one is ever shown.
(b) A **MIPI DSI VO path at 480×640** reads `logo.bmp` from the FAT `boot`
partition, falling back to a raw read of the 6 MiB `logo` partition, and drives
an ST7701-family panel inherited from MaixCAM2 — bare register programming over
`0x4407000`/`0x4620000`, with no DSI/VO/DRM node in the U-Boot device tree at
all. `common/axera_splash_source.c` and the `cmd/bmp.c` hunk are **not**
compiled (`CONFIG_AXERA_SPLASH_SOURCE` and `CMD_BMP` unset), and the
`video-uclass.c` hunks are gated on `AXERA_LOGO_BMP2YUV`, which is never
defined. `ax_jdec_hw.c` (693 LOC of hardware JPEG) compiles but never runs —
`logo_type` is pinned to BMP by a Sipeed edit. Mainline U-Boot has no Cadence
DSI driver; writing one would be 3 000+ LOC. **Drop the lot.** A pre-Linux
splash on the SPI panel, if ever wanted, is a ~300 LOC `panel-mipi-dbi`-shaped
driver, and the Linux-side `fb_jd9853` (#84) is the real display path anyway.

**axgzip.** The block lives at `0x10410000`, is clocked from NPLL_533M through
`0x10030000`, and is polled. The container is Axera's "axgzip"/z20e format: a
16-byte header `{magic "20", blk_num, osize, isize, icrc32}`, CRC-32/MPEG-2,
8 KiB tiles. Both the kernel and the dtb are stored compressed and decompressed
by this block; so are ATF, OP-TEE and U-Boot, decompressed by the **SPL**. With
a mainline U-Boot the kernel/dtb side simply goes away (the uncompressed `Image`
fits the 64 MiB slot with room to spare, and extlinux replaces the raw read
entirely) — but the **U-Boot binary itself must still be axgzip-compressed**,
because the SPL demands it (§11.2). `tools/ax_gzip_tool/ax_gzip` is a prebuilt
x86-64 host binary; that is why `pkgs/boot.nix` declares
`meta.platforms = ["x86_64-linux"]`. Rebuilding the SPL with
`SUPPPORT_GZIPD=FALSE` would remove the last prebuilt binary from the boot-chain
build and make it buildable on aarch64 — a real blob-policy win, and the same
SPL rebuild the new layout forces anyway.

**FDL2.** Not a separate defconfig for this board: with `SUPPPORT_GZIPD=TRUE`,
`Makefile.fdl2:120-133` signs the **raw** `u-boot.bin` as `fdl2_signed.bin` and
signs the axgzip'd copy as `u-boot_signed.bin` — one binary, two packagings. The
protocol is Spreadtrum-derived (frame `magic 0x5C6D8E9F | u16 len | u16 cmd |
data | u16 checksum`; the same constant appears as `PAC_MAGIC` in the SDK's own
`tools/mkaxp/make_pac.py`), and its USB transport is a raw DWC3 poke at
`0x8000000` on hard-coded endpoints 0x2/0x3 with no EP0 handling — it inherits a
pipe the mask ROM already enumerated. **Drop it.** AXDL recovery does not depend
on anything on the device: the `.axp` manifest supplies `INIT`, `EIP`
(`0x3000000`), `FDL1` (`0x3000000`) and `FDL2` (`0x5C000000`) from the host, so
even a destroyed SPL is recoverable. If a device-resident flasher is ever wanted,
mainline `ums`/`fastboot`/`dfu` is the answer.

**Blob-policy finding for `docs/provenance.md`:**
`cmd/axera/cipher/eip130_fw.h` is a **78 KB closed binary blob compiled into the
shipping U-Boot and FDL2** — `int const eip130_firmware[]`, 2 456 lines,
`#include`d by `eip130_drv.c` and DMA'd into the EIP-130 (Rambus SafeXcel)
crypto module at `eip130_drv.c:347`. `docs/provenance.md` already lists
`eip_ax620e.bin` as a *flash-time* artifact; the new fact is that the same
firmware also rides inside `u-boot.bin`. A mainline port must not carry it and
need not: secure boot is efuse-gated off, so every RSA path short-circuits and
only the header magic + checksums are ever checked. (A second blob,
`cmd/axera/riscv/rtthread.h`, 24 393 lines, is not linked.)

**Two gaps nobody asked about.** (1) There is **no clock, reset or pinctrl
provider in U-Boot at all** — `CONFIG_CLK=y`, `CONFIG_PINCTRL=y` and
`CONFIG_DM_THERMAL=y` enable uclasses with no providers, every `clocks =` in the
U-Boot dtsi is a `fixed-clock`, and every gate/mux/reset is a raw `writel()`
scattered through `mach-axera`. A mainline port inherits that problem; #80's
Linux CCF/reset/pinctrl drivers are the reuse candidate, and this is the largest
un-scoped item in the port. (2) An **undocumented IRAM struct ABI** at physical
`0x700` (`boot_mode_info`, magic `0x12345678`), `0x740` (`misc_info`) and
`0x800` (`ddr_info`), read by mach code, `setup_boot.c`, `sdhci_ax620e.c:972`
and `axera_emac.h:278` — no DT node, no binding, and the region must not be
clobbered early. A bootinfo shim is ~80 LOC.

---

### 11.2 What the SPL requires of BL31 and BL33

**Stage loading is by compile-time byte offset. Nothing is read from flash to
find anything.** `main()` (`[SDK]/boot/bl1/spl/spl_main.c:416`) loads, in this
order: DDRINIT, then **BL33 (U-Boot)**, then BL32 (OP-TEE), then BL31 (ATF) —
and jumps to BL31 immediately.

| Stage | Flash offset macro | Header staged at | **Load + entry** |
|---|---|---|---|
| ddrinit | `DDRINIT_HEADER_FLASH_BASE` | `0x03200000` (OCM) | `0x03200400` |
| BL33 U-Boot | `UBOOT_HEADER_FLASH_BASE` / `…_BAK_…` | `0x5C000000` | **`0x5C000400`** |
| BL32 OP-TEE | `OPTEE_HEADER_FLASH_BASE` / `…_BAK_…` | `0x441FFC00` | **`0x44200000`** |
| BL31 ATF | `ATF_HEADER_FLASH_BASE` / `…_BAK_…` | `0x4003FC00` | **`0x40040000`** (limit `+0x40000`) |

The `*_FLASH_BASE` macros come from `[SDK]/boot/bl1/spl/Makefile:102-129`, whose
values are `$(call calculate_flash_base,…)` over `FLASH_PARTITIONS` in
`build/projects/AX630C_emmc_arm64_k419_sipeed_nanokvm/partition_ab.mak:80-113`
— i.e. a running sum of the partition sizes. **Change the layout and the SPL
must be rebuilt.** Reads go to the eMMC *user area* by byte offset
(`emmc_part_boot = 0`, `boot/bl1/core/boot/boot.c:32`).

**The 1 KiB header does not carry a load address.** `entry = ram_ops +
sizeof(struct img_header)` (`boot.c:734`), where `ram_ops` is the compile-time
macro above; the only address in the header is `ocm_start_addr`, which the
*BootROM* uses for the SPL itself. At runtime the SPL always checks
`magic_data = 0x55543322`, the header checksum, `capability` and `img_size`;
`img_check_sum` when `IMG_CHECK_ENABLE` is set (it is); and the RSA modulus and
signature **only** when the `SECURE_BOOT_EN` efuse is burned (it is not).
One gotcha for our tooling: the SPL sums header words 2..255 (`boot.c:545`) while
`sec_boot_AX620E_sign.py:224` sums words 2..253 — the two agree **only because
the last eight bytes are zero**, so the trailing reserved words must stay zeroed.

**BL31 handoff is stock TF-A.** `boot/bl1/driver/atf/atf.c:11-40` builds

```
atf_bl_params { h.type = PARAM_BL_PARAMS(5), h.version = VERSION_2, head = &bl33 }
  bl33 { image_id = BL33_IMAGE_ID, ep_info = { pc = 0x5C000400,
                                               spsr = SPSR_64(MODE_EL1, MODE_SP_ELX, …) },
         next = &bl32 (only #ifdef OPTEE_BOOT) }
  bl32 { image_id = BL32_IMAGE_ID, ep_info = { pc = 0x44200000, … }, next = NULL }
```

and `spl_main.c:351` calls `atf_boot(&atf_bl_params, 0, dtb_addr,
ARM_BL31_PLAT_PARAM_VAL)` at EL3 with the MMU off — x0 = params, x1 = 0
(`soc_fw_config`), x2 = `dtb_addr` (**0** in this build; the fast-boot path that
would set it is compiled out), x3 = `0x0f1e2d3c4b5a6978`. The vendor
`ax620e_bl31_setup.c:155-201` is the ordinary non-`RESET_TO_BL31` arm-common
flow that walks that list; there is no `BL32_BASE` define anywhere in
`platform_def.h`. **So a mainline TF-A BL31 needs no SPL change at all.**

**BL33 can be a mainline U-Boot, wrapped in the same header**, subject to four
constraints: link at `0x5C000400`; fit 1536 KiB *after* axgzip; be axgzip'd and
signed (`pkgs/boot.nix` already does exactly this and asserts the magic); and
cope with being entered **at EL1h with `x0 = 0`** — no FDT pointer. `x0` is
zeroed twice over: the SPL leaves `ep_info.args` zero, and
`platform.mk:75`'s `ARM_LINUX_KERNEL_AS_BL33 := 1` makes BL31 overwrite `arg0`
with `hw_config` = x2 = 0. So mainline U-Boot needs `OF_SEPARATE`/`OF_EMBED`
(its default anyway), and Linux ends up booted from EL1 with no EL2 — as today.
Entering U-Boot at EL2 would mean patching `atf.c:26` and rebuilding the SPL;
not worth it for an appliance.

**OP-TEE is optional at build time and mandatory at runtime once built in.**
`SUPPORT_OPTEE` → `-DOPTEE_BOOT` (`spl/Makefile:124-129`). With it compiled in,
`spl_main.c:322-327` does `goto failed` → `while(1)` if the OP-TEE image does
not verify — an absent BL32 hangs the SPL, even though BL31 itself tolerates one
(`bl31_plat_get_next_image_ep_info` returns NULL for a zero `pc`). Turning
`SUPPORT_OPTEE=FALSE` removes the BL32 node entirely. Since the SPL must be
rebuilt for the new layout regardless, dropping OP-TEE costs nothing extra.

**ddrinit is read, but its absence is harmless.** `spl_main.c:450-456` calls
`flash_boot(…, DDRINIT, DDRINIT_HEADER_FLASH_BASE, …)` under
`#ifdef SUPPORT_DDRINIT_PART` and, on failure, prints
`"get ddrinit param in rom fail"` **and continues**. The payload is a cached DDR
vref table consumed by `mc20e_ddr_init` behind a frequency match *and* a vref
sanity check (`ddrmc_train_flow_lp4.c:1074-1076`), so garbage just means full
training runs. The shipped image is a signed header with an **empty** payload
(`spl/Makefile:321` `touch`es it). `SUPPORT_DDRINIT_PART` is already a build
flag in `project.mak:50`. **The partition can be dropped**, provided the SPL is
rebuilt with it dropped from `FLASH_PARTITIONS` — otherwise every downstream
`*_HEADER_FLASH_BASE` shifts by 0x80000 and nothing loads.

**axgzip is mandatory on this build.** `read_image_data` sends every image
except DDRINIT through `gzip_pipeline_flash_read` (`boot.c:768-789`), staging the
raw bytes at `0x58000000` and DMA-ing the decompressed output to
`ram_ops + 1024`. A raw payload fails the `"20"` magic check
(`driver/gzipd/ax_gzipd_drv.c:132-155`) and returns `BOOT_FLASH_READ_FAIL`. The
output address must be 8-byte aligned. Rebuilding with `SUPPPORT_GZIPD=FALSE`
switches to the plain `flash_read` at `boot.c:783`.

**A/B, and what happens on a bad image.** `select_slot_ab()`
(`boot.c:934-995`) reads `TOP_CHIPMODE_GLB_BACKUP0 = 0x02390024` and consumes
the current slot's BOOTABLE bit as a one-shot ticket; U-Boot only *reads* the
register. But with `support_ab` set, a bad header **returns immediately**
(`boot.c:649-652`) and a bad payload checksum likewise (`boot.c:806-808`) — the
`flash_addr_bk` retry loop only runs when A/B is off. The caller then does
`while(1)`, because the watchdog-arming fallback at `boot.c:1018-1027` is inside
`#ifdef AX_BOOT_OPTIMIZATION_SUPPORT`, which is FALSE here. **So the twins are
not a failover mechanism in this build; they are a mechanism the *register*
selects between.** A layout with no `_b` twins is fine only if the SPL is
rebuilt with the `_BAK` bases pointed at the A copies (or `AX_SUPPORT_AB_PART`
off) — keep the vendor SPL and drop the twins and the first boot that lands on
slot B reads whatever the new layout put at the old `_b` offsets, and hangs.

**What the SPL leaves configured for later stages:** DDR trained and running;
PLLs and clock muxes set (CPU on cpupll_1200m, bus/flash cpll_312m, NPU
npll_800m, `pclk_top` cpll_208m — `bl1/board/board.c:222-249`); VDDCORE set via
PWM11; the generic timer enabled at 24 MHz with `CNTFRQ_EL0` written; **UART0 at
`0x04880000`, 115200 8N1, pads muxed**; abort routing armed so WDT0/WDT2/thermal
cause a chip reset; the WDT *clock gate* on (but **no timeout ever programmed or
kicked**); the eMMC controller up at 8-bit HS 50 MHz; the gzipd block reset and
clocked; and the IRAM structs at `0x700`/`0x740`/`0x800` populated. **Not** done:
general pinmux (only the UART0 and SD/eMMC pads), GIC init, and anything at EL2.

---

### 11.3 TF-A: the fork is upstream 2.7 plus one platform

The vendor tree contains a **nested pristine copy** of upstream at
`boot/atf/arm-trusted-firmware-2.7/arm-trusted-firmware-2.7.0/`, which inflates
a naive diff to 667 k lines. Excluding it, `diff -rN` against upstream v2.7.0 is
**68 files, +4264/−8**:

- `plat/axera/ax620e/**` — 54 files, **4 156 lines**, entirely new.
- Seven upstream files touched, for **+8/−8 lines of nothing**: `LOG_LEVEL` 20 → 10
  in `Makefile`, two `NOTICE()` banners commented out in `bl31/bl31_main.c`, two
  stray `#include`s in `lib/psci/`, one comment, three deleted blank lines.
- Six `.rej` files — a debug-instrumentation patch that failed to apply and was
  left behind. Dead.

**Most of the platform is suspend/resume we do not need.**
`aarch64/ax620e_on_ram_func.S` (321), `drivers/{ddr_sys,cpu_sys,isp_sys,npu_sys,
vpu_sys,mm_sys,periph_sys,flash_sys,wakeup,timestamp,chip_top,pmu,soc}` (1 231)
and most of `ax620e_pm.c`'s 498 lines exist to sleep and wake the SoC. A BL31
that only boots and does PSCI CPU_ON/CPU_OFF is:

| Piece | ~LOC |
|---|---:|
| `platform_def.h` + `ax630c_def.h` + `platform.mk` | 140 |
| `bl31_setup.c` (console, GIC, mmap, `secure_config`) | 180 |
| `pm.c` (CPU on/off, PSCI ops) | 120 |
| `pwrc.c` (the PMU CPU power controller) | 118 |
| `topology.c`, `gicv2.c`, `helpers.S`, `sema.c` | 200 |
| **plus, new:** `.system_reset` via WDT0 | 20 |
| **total** | **~780** |

What it must know: **GIC-400** at `0x01850000` (GICD `+0x1000`, GICC `+0x2000`);
UART0 `0x04880000` at 208 MHz / 115200; 1 cluster × 2 × Cortex-A53
(`PLATFORM_CORE_COUNT 2`, `PLAT_MAX_PWR_LVL = AFFLVL2`); `SYS_COUNTER_FREQ`
24 MHz; BL31 at `0x40040000` in a 256 KiB window;
`COLD_BOOT_SINGLE_CPU := 1`, `ERRATA_A53_1530924 := 1`, no SVE,
`USE_COHERENT_MEM := 0`, `ARM_LINUX_KERNEL_AS_BL33 := 1`; a flat mmap of the
peripheral windows; and the second-core bring-up path in `ax620e_pwrc.c`
(`ax620e_pwrc_read_psysr` / `write_pponr` against the PMU at `0x02100000`).

**Secure init reduces to three things** (`plat_ax620e_secure_config()`,
`ax620e_bl31_setup.c:56-62`): the firewall, a semaphore block (31 LOC), and
`mmio_write_32(EFUSE_CTRL, 0)`. And the firewall's **only** region is the OP-TEE
one — `fw_region[]` is empty without `#ifdef OPTEE_BOOT`, and the `#else` branch
of `firewall_config()` simply disables all eight regions. So dropping OP-TEE
drops the firewall too, cleanly.

**Nothing we run uses OP-TEE.** The vendor 4.19 defconfig sets `CONFIG_TEE=y` /
`CONFIG_OPTEE=y` and both DTs carry a `firmware { optee { compatible =
"linaro,optee-tz"; } }` node, but no component in this repo references a `tee_`
or `TEEC_` symbol (`dts/ax630c-nanokvm-pro.dts:96`), and no mainline driver we
build would. **Confirmed droppable**, freeing the 32 MiB `0x44200000`
reserved-memory node and the two 1 MiB partitions.

**Missing from the vendor plat, and worth adding:** `plat_psci_ops` has no
`.system_reset` and no `.system_off` (`ax620e_pm.c:465-476`, verified). That is
the root of §5 trap 4 — mainline's `psci_sys_reset` returns `NOT_SUPPORTED` and
we needed a `syscon-reboot`/watchdog restart handler in Linux. A ~20 LOC
`.system_reset` that programs WDT0 with a zero timeout gives Linux `reboot` over
plain PSCI and retires that shim.

---

### 11.4 BootROM

- **Boot source is a strap, not a probe.** `get_boot_mode()`
  (`[SDK]/boot/bl1/board/board.c:27-31`) is `(chip_mode & FLASH_BOOT_MASK) >> 1`,
  selecting eMMC-UDA (0), three eMMC **boot-partition** modes (1/4/6), NAND
  (3/5), NOR (7), SPI-slave (2), or SD/USB-download (8/9)
  (`bl1/core/include/boot.h:17-26`). This board is on **mode 0, the user area**,
  and the mode is not software-selectable. On the NanoKVM-Pro the strap is the
  `User` button: normal power-on → eMMC, hold at power-on → SD, hold ~10 s →
  AXDL ([flashing-and-recovery.md](flashing-and-recovery.md#the-user-button)).
- **SPL location:** the `spl` partition is first in `FLASH_PARTITIONS` with
  `gap="0"`, i.e. **byte offset 0 of the eMMC user area**.
- **Container** (`build/tools/imgsign/spl_AX620E_sign.py:251-253, 341-357`),
  `PKG_SIZE = 0x20000`: header A at `0x00000`, SPL A at `0x00400` (loaded to
  `ocm_start_addr = 0x03000400`, entered at **EL3, MMU off**), EIP firmware A at
  `0x0CC00`; the same three again at `0x20000`/`0x20400`/`0x2CC00` as the ROM's
  own backup copy — total `0x40000`, inside the 768 KiB partition.
- **Max SPL size 51 200 B (50 KiB)**, hard-enforced at
  `spl_AX620E_sign.py:183, 221-223`; the linker window is `0x03000400` + 1 MiB
  (`board/arch/arm64/bl1.lds:16`). `pkgs/boot.nix` already guards this for the
  SD variant.
- **Behaviour on a missing or invalid SPL: unknown.** Nothing in `bl1/`, the
  linker scripts, the build system or the manifest states it, and the SDK's
  `docs/` are Chinese PDFs with no extractable text in this environment. The
  circumstantial evidence points at *strap-selected, not automatic*: the SDK
  README describes SD boot as "insert the SD card, hold down boot, then press
  rst", and `board.c:22` defines `USB_DL_SD_BOOT_MASK` on `chip_mode`. A ROM USB
  download protocol certainly exists (the manifest's first entry is
  `<Img name="INIT">…<Description>Handshake with romcode</Description>`), but
  whether a bad SPL falls into it on its own is **not determinable from source**.
  Treat "hold `User` ~10 s" as the only guaranteed way in.

---

### 11.5 The minimal layout

**No on-disk partition table is possible.** The SPL sits at byte 0 of the user
area; a GPT needs LBA 1–33 and an MBR needs LBA 0. Both are inside the SPL
image. (Moving the boot chain into the eMMC *boot* partitions would free the
user area for a GPT, and the ROM has modes for it — but selecting one is a
hardware strap, so it is not ours to change.) The eMMC therefore stays
table-less and `blkdevparts=` stays the table. On the Linux side that is
**upstream, not a vendor patch** (`block/partitions/cmdline.c`,
`CONFIG_BLK_CMDLINE_PARSER`). On the U-Boot side mainline has nothing: its only
partition drivers are amiga/dos/efi/iso/mac, and `blkdevparts` appears nowhere
in the 2026.07 tree.

**Proposal: seven partitions, from 17.**

| # | Name | Size | Why it exists | Change |
|---|---|---|---|---|
| 1 | `spl` | 768 K | BootROM reads it at offset 0; the signed container is 256 K | keep |
| 2 | `atf` | 256 K | BL31 window is `ATF_IMG_PKG_SIZE = 0x40000` and `BL31_LIMIT` is derived from it | keep, **no `_b`** |
| 3 | `uboot` | 1536 K | mainline U-Boot with ext4 + bootstd is well under this even before axgzip | keep, **no `_b`** |
| 4 | `env` | 256 K | `bootcount`, `bootsystem`-successor, `fw_setenv` from userspace; redundant pair of 64 K copies inside | shrink from 1 M |
| 5 | `boot` | 512 M | ext4; `extlinux/extlinux.conf`, `nixos/<gen>` kernels + initrds + dtbs, `logo.bmp`, and the server's `usb.*` flag files | grow from 128 M, **vfat → ext4** |
| 6 | `rootfs` | rest | `-(rootfs)` | keep |

Dropped: `ddrinit` (empty; `SUPPORT_DDRINIT_PART=FALSE`), `optee`/`optee_b`
(§11.3), `logo`/`logo_b` (the logo moves into `/boot`, where
`ax_bootlogo_show()` already looks first — and no mainline U-Boot reads it
anyway until someone writes a display driver), `dtb`/`dtb_b` and
`kernel`/`kernel_b` (extlinux carries them per generation), and every `_b` twin.
Boot chain shrinks from 20.5 MiB across 15 partitions to 2.75 MiB across four.

Whether to keep `atf_b` + `uboot_b` (1.75 MiB) as insurance is a judgement call:
in *this* SPL build they are not an automatic failover (§11.2), only a slot the
register can select, so they buy a manual recovery path that a rebuilt SPL and
an AXDL cable already provide. Recommendation: **drop them**, and set the SPL's
`*_BAK_FLASH_BASE` equal to the A bases, matching what `partition.mak` already
does for the non-A/B variant.

**One definition, five consumers.** Today `nixos/emmc-partitions.nix` *parses*
the `blkdevparts=` clause out of `dts/ax630c-nanokvm-pro.dts` and asserts what it
finds; five files consume it (`nixos/{axp-image,appliance,image-axp}.nix`,
`nixos/lib/make-axp-image.nix`, `flake.nix:613`). Under #89 it should be
inverted: a `nixos/layout.nix` holding the list, which **generates**

1. the `.axp` `<Partitions>` manifest and `<Block>` ids (already derived),
2. the `blkdevparts=mmcblk0:…` string injected into the kernel cmdline,
3. the same string as U-Boot's `CONFIG_BOOTARGS`, consumed by a new
   `disk/part_cmdline.c`,
4. a generated `partition.mak` fragment for the SPL build, so the SPL's
   `*_HEADER_FLASH_BASE` constants can never disagree with the manifest,
5. `/etc/fw_env.config` and the NixOS `fileSystems` entries.

Item 4 is the new one and it is the important one: today those constants come
from a hand-written vendor makefile inside the SDK snapshot, which is exactly
where a layout change silently goes wrong.

**`part_cmdline.c` — the one genuinely new U-Boot file.** ~150–200 LOC, modelled
on Linux's `block/partitions/cmdline.c`, registered through U-Boot's existing
`U_BOOT_PART_TYPE` mechanism so `ext4load mmc 0:5 …`, `bootstd` and
`bootmeth_extlinux` all just work. It reads the string from `CONFIG_BOOTARGS`
(or a DT property), which keeps U-Boot and Linux reading the *same* string, as
today. It is plausibly upstreamable — several SoC vendors carry the same Linux
convention — but if upstream declines it, it stays a carried patch, which the
issue explicitly allows.

**Distro boot gives #79 what it wanted, natively.** Mainline 2026.07 has
`bootmeth_extlinux`, `BOOTCOUNT_BOOTLIMIT` and `BOOTCOUNT_ALTBOOTCMD`
(`common/autoboot.c:482` runs `altbootcmd` when the limit is hit), with backends
including `BOOTCOUNT_ENV` and `DM_BOOTCOUNT_SYSCON`
(`u-boot,bootcount-syscon`). NixOS's `boot.loader.generic-extlinux-compatible`
writes `/boot/extlinux/extlinux.conf` with `DEFAULT nixos-default`, one `LABEL
nixos-<n>` per generation, and `LINUX ../nixos/<hash>-Image` / `INITRD` /
`APPEND init=/nix/store/<gen>/init …` / `FDTDIR` (kernels copied to
`/boot/nixos/`). Wiring:

- `bootcount` in the **env** (`BOOTCOUNT_ENV`), so userspace can clear it with
  `fw_setenv bootcount 0` — the standard RAUC/swupdate lever, and the reason to
  keep the `env` partition.
- `bootlimit=3`, `altbootcmd` = boot `/extlinux/extlinux-fallback.conf`.
- A `nanokvm-mark-good.service`, `After=nanokvm-healthy.target`, that clears
  `bootcount` **and** copies `extlinux.conf` → `extlinux-fallback.conf`. The
  fallback config is then by construction "the last generation that passed the
  health check", which is exactly #79's contract and strictly better than the
  slot register: it survives a cold power cycle, it is per-generation rather than
  per-slot, and it needs no eMMC A/B twins.
- `boot.loader.generic-extlinux-compatible.configurationLimit` caps `/boot`.
- Keep arming WDT0 in U-Boot before `booti` (a ~120 LOC U-Boot watchdog driver,
  mirroring #75's Linux one) so a kernel that never reaches userspace also
  increments `bootcount` instead of hanging silently. `RuntimeWatchdogSec` on
  `/dev/watchdog0` covers a hung userspace, as #79 already planned.

`/boot` moves from vfat to **ext4**: the kernel needs ext4 anyway, so this
retires the `CONFIG_VFAT_FS` + NLS-codepage trap documented in
[nixos-rootfs.md](nixos-rootfs.md#4-boot--p16-vfat-and-it-must-stay-writable)
(without those tables the mount fails `-EINVAL` and every USB-gadget flag
silently reads as absent). The flag-file contract is unchanged.

---

### 11.6 Two hazards this investigation surfaced

**1. `phy-mode` must be `rgmii-id` in U-Boot too, and the failure is worse
there.** The vendor `realtek.c` patch makes plain `"rgmii"` set the TX delay and
**never touches the RX delay register**, so the board's strapped-on RX delay
survives whatever the DT says. Mainline's driver writes **both** registers and
*clears* either one when `phy-mode` says so (2026.07
`drivers/net/phy/realtek.c:236-254`). So the #77 signature — link trains,
reports 1000/Full, passes not one packet — is reachable from U-Boot as well, and
the write there is unconditional. `rgmii-id` in both trees.

**2. A DDR retrain engine may be rewriting physical `0x40000000`, and nothing
reserves it.** bl1's `retrain_general_config()`
(`boot/bl1/driver/ddr/ddr_init.c:824-839`) writes
`D_DDRMC_RETRAIN_CFG0 = 0x116E3600` — whose low 24 bits are 24 000 000, a
one-second interval at 24 MHz — with `TRAIN_CTRL2 = 0`, commented in the vendor
source as *"start at the lowest address"*, then sets `rf_retrain_enable`. The
U-Boot side treats that as real: under `CONFIG_AXERA_AX630C_DDR4_RETRAIN` it
reports `ram_size = 0x7FFFF000` with bank 0 starting at **`0x40001000`**
(`board/axera/ax620e_emmc/ax620e_emmc.c:329-341`) and maps normal memory from
`0x40001000` (`arch/arm/mach-axera/ax620e/ax620e.c:22-33`).

Two things narrow this from the alarming version. `retrain_general_config()` is
called **only** from `ddrmc_train_flow_no_lp.c:285` — the DDR4/DDR3 path, not
the LPDDR4 one — so whether the engine is armed on *this* unit depends on the
DRAM part, which source does not settle. And `DDR_RETRAIN_START`/`SIZE` in
`partition_ab.mak:116-117` are declarations with no consumer anywhere in the
SDK: the reservation is convention, enforced in three separate headers. Both the
vendor 4.19 DT and ours declare `memory@40000000` with no carve-out, so if the
engine *is* armed the vendor kernel has been living with a once-per-second
single-page corruption too.

Cheap insurance, and the recommendation: mirror U-Boot — either
`memory@40001000` or a `no-map` `reserved-memory` node covering
`0x40000000 + 0x1000`. It costs one page. A device read (dump the DDRMC
`TMG16_F0` bit 30, or watch a poisoned page at `0x40000000`) would settle
whether it is needed; add it to §9.

---

### 11.7 The ladder

Every rung below the last is reversible, and the first three write nothing to
the eMMC.

| # | Rung | Proves | Serial-less evidence |
|---|---|---|---|
| 0 | `.#uboot-mainline` + `.#atf-mainline` build; `nix flake check` asserts the signed images fit 1536 K / 256 K and carry magic `0x55543322` | it compiles, links at `0x5C000400`/`0x40040000`, and fits | build output only |
| 1 | **SD card**: vendor SD-SPL + **mainline BL31** + vendor U-Boot + vendor kernel | the TF-A port: GIC, PSCI, second-core bring-up, BL33 handoff | the board reaches the vendor userspace → DHCP → SSH. Card removal reverts |
| 2 | **SD card**: vendor SD-SPL + mainline BL31 + **mainline U-Boot** + extlinux → mainline kernel + NixOS | the whole new chain end to end, including the board port, `part_cmdline`, sdhci-cadence and the `rgmii-id` PHY question | SSH on the mainline appliance (#77/#78 already prove that path); card removal reverts |
| 3 | **eMMC, existing 17-partition layout**: mainline BL31 → `atf`, mainline U-Boot → `uboot`, keeping the vendor kernel slots | the eMMC read path and the signed-header packaging, without touching the layout | as rung 1. Recovery: AXDL |
| 4 | **eMMC, new layout**, full `.axp` over AXDL: rebuilt SPL (no ddrinit, no OP-TEE, no twins, `SUPPPORT_GZIPD=FALSE`), mainline BL31, mainline U-Boot, ext4 `/boot`, extlinux | the layout, the regenerated SPL offsets, and NixOS generations | as above, plus `fw_printenv` and the milestone register |
| 5 | **Rollback drill**: install a deliberately broken generation, let `bootcount` reach `bootlimit` | health-gated fallback, i.e. #79's contract on the new mechanism | the board comes back on the previous generation, unattended |

The SD rungs are load-bearing and **there is no SD card in the device** — the
same blocker that still holds #76's root-on-SD half open (§8). Inserting one is
the human action this work needs first. Rung 3 can be reached without a card, at
the cost of skipping straight to an eMMC write.

**Observability, replacing the slot register.** #89 retires the SLOT/BOOTABLE
semantics of `0x02390024`, not the register. Three channels, in order of
cheapness:

1. **Milestone bits 12-15** stay exactly as #75 uses them. Vendor U-Boot never
   writes them and `chip_rst_sw()` clears only bits 7 and 8, so they survive a
   warm reboot; mainline U-Boot can write them from `preboot`/`bootcmd` with
   `mw` — zero new code — and Linux reads them back.
2. **`bootcount`** in the env is itself evidence: `fw_printenv bootcount` after
   a boot says how many attempts the bootloader made.
3. **`CONFIG_PRE_CONSOLE_BUFFER` + `PRE_CON_BUF_ADDR`** pointed into the spare
   tail of the vendor pstore window (the same place #75 banks a verbatim kernel
   log — and note the trap recorded there: the vendor kernel zaps every pstore
   zone it owns ~1.5 s into a boot, so never use `0x48000000`). That captures
   the earliest U-Boot output at a fixed address Linux can dump. Capturing the
   *whole* U-Boot log needs a ~40 LOC memory-backed stdio device;
   `CONFIG_CONSOLE_RECORD` will not do, because its buffers are malloc'd.

And one possibility worth testing rather than assuming: **UART1
(`0x04881000`) is on an exposed header pin** while UART0 is on hidden pads
([architecture.md](architecture.md#boot-chain)). The earlier UART1 experiment
failed *in the SPL*, because touching UART1 MMIO while its clock was still gated
hung it (`86b8c58`). Mainline U-Boot runs after bl1 has the clock tree up and
can ungate UART1 itself — so a real serial console from BL33 onward may be
available for the first time. Worth one rung-2 experiment; not worth assuming,
since whether that pad is muxed to UART1 on this board is a device question.

---

### 11.8 Open questions

- Does the BootROM enter USB download mode on its own when the SPL is invalid,
  or only on the `User`-button strap? Not determinable from source (§11.4).
- Is the DDR retrain engine armed on this unit — i.e. is the part DDR4 or
  LPDDR4? (§11.6)
- Is UART1 muxed out to the exposed header on this board, and does anything else
  claim those pads? (§11.7)
- `axi_dma_hw_init()` is called unconditionally from vendor `arch_cpu_init()`;
  is it needed before eMMC access, or vestigial?
- Whether `part_cmdline.c` is acceptable upstream, or stays a carried patch.

---

### 11.9 Rung 0: mainline BL31 — what exists

`.#atf-mainline` builds **upstream TF-A v2.15.0** with a new
`plat/axera/ax630c`, and packages it byte-for-byte the way the vendor
`atf_bl31_signed.bin` is packaged, so a later rung can `dd` it into `atf_b`.
`nix build .#checks.x86_64-linux.atf-mainline` asserts the result.
**Nothing here has run on hardware.**

The ladder was revised on 2026-09-08 (Jeremy): no SD rungs, and no AXDL where a
`dd` will do — the boot source is a `chip_mode` strap, so an SD boot needs
hands on the board every time and buys nothing over an eMMC write to a `_b`
slot. §11.7's table predates that; the rung-1 procedure below is the current
one.

Sources: `pkgs/atf-mainline.nix`, `pkgs/atf-mainline/patches/`,
`pkgs/atf-mainline/verify.py`. `pkgs/boot.nix` is untouched — the mainline
build calls the SDK's `ax_gzip` and `sec_boot_AX620E_sign.py` directly, with
the same arguments the vendor ATF Makefile uses.

**The patch series** (upstream-shaped, applied with `patch -p1`; the platform
is 715 lines across ten files, and no upstream file is modified except the
docs index):

| Patch | Files | LOC |
|---|---|---:|
| `0001-plat-axera-add-a-BL31-only-AX630C-platform` | `platform.mk` | 48 |
| | `include/platform_def.h` | 78 |
| | `include/ax630c_def.h` | 65 |
| | `include/ax630c_private.h` | 26 |
| | `include/plat_macros.S` | 17 |
| | `ax630c_bl31_setup.c` | 153 |
| | `ax630c_gicv2.c` | 50 |
| | `ax630c_pm.c` | 180 |
| | `ax630c_topology.c` | 48 |
| | `aarch64/ax630c_helpers.S` | 50 |
| `0002-docs-plat-document-the-Axera-AX630C-platform` | `docs/plat/ax630c.rst` (new) + one line in `docs/plat/index.rst` | 52 |
| **total** | | **767** |

Upstreaming needs one thing this series does not carry: a
`docs/about/maintainers.rst` entry, which needs a person's name.

That is close to §11.3's ~780-line estimate, and it drops the suspend/resume
half of the vendor platform entirely (`ax620e_on_ram_func.S` and the twelve
`drivers/*_sys` files, 1 552 lines, all of it sleep and wake).

**Constants, and where each came from.**

| Constant | Value | Source |
|---|---|---|
| BL31 entry / link address | `0x40040000` | `ATF_IMG_ADDR`, `[SDK]/build/projects/AX630C_…/partition_ab.mak:5`; the SPL enters `ram_ops + sizeof(img_header)` (§11.2) |
| BL31 window / `atf` partition | 256 KiB | `ATF_IMG_PKG_SIZE` = `0x40000` (`partition_ab.mak:6`), `ATF_PARTITION_SIZE = 256K` (`:23`), and the `blkdevparts=` clause |
| BL33 entry, EL1h, `x0 = 0` | `0x5C000400` | supplied by the SPL in the `bl_params_t` chain (`bl1/driver/atf/atf.c:11-40`); the platform passes it through and, under `ARM_LINUX_KERNEL_AS_BL33`, sets `x0 = hw_config` = the SPL's x2 = 0 |
| loader cookie in x3 | `0x0f1e2d3c4b5a6978` | `ARM_BL31_PLAT_PARAM_VAL`, `spl_main.c:351` |
| GIC-400 | `0x01850000`, GICD `+0x1000`, GICC `+0x2000` | vendor `plat/axera/ax620e/include/ax620e_def.h` |
| UART0 console | `0x04880000`, 208 MHz, 115200 8N1 | same header (`AX620E_UART_CLOCK`); the SPL leaves the pads muxed and the port configured (§11.2) |
| generic timer | 24 MHz | `SYS_COUNTER_FREQ`, vendor `platform_def.h`; the SPL writes `CNTFRQ_EL0` |
| CPUs | 1 cluster × 2 Cortex-A53 | `PLATFORM_CORE_COUNT`, vendor `platform_def.h` |
| CPU release mailbox | `0x02340000 + 0xDC/0xE0` (core 1), `+0xE4/0xE8` (core 0) | `COMM_SYS_DUMMY_SW0..3`, vendor `ax620e_common_sys_glb.h`; the same addresses appear in `bl1/board/arch/arm64/common.S:13-14`, and `bl1`'s own non-ATF secondary-core loop (`start.S:178-192`) implements the identical WFE/poll/branch protocol the boot ROM uses |
| WDT0 | `0x04840000`; `EN 0x00`, `TORR 0x0c`, `TORR_LOAD 0x18`, `CRR 0x30`, kick word `0x61696370` | `pkgs/kernel-mainline/tree/drivers/watchdog/ax630c_wdt.c`, whose model is hardware-measured (#80). Two stages of 64Ki ticks each, so a reload of 0 resets within microseconds |
| header magic / capability | `0x55543322` / `0x54FAFE` | `sec_boot_AX620E_sign.py:163`, `[SDK]/boot/atf/Makefile:88` |

**What the platform deliberately does *not* do.** The vendor's
`bl31_platform_setup()` also runs `pmu_init()`, `chip_top_set()` (PLL wake-wait
tuning and GPIO interrupt masking), clock auto-gating writes, an EIC wakeup
mask, `firewall_config()`, `sema_config()` and `mmio_write_32(EFUSE_CTRL, 0)`.
Every one of those is suspend/resume or OP-TEE support. `sema_config()` is
`#if 0` in the vendor source and the firewall's only region is the OP-TEE one,
so dropping BL32 drops both (§11.3). Not writing `EFUSE_CTRL` is strictly more
permissive than the vendor, so nothing that works today can stop working.
`SYSTEM_OFF` is not implemented: nothing inside the SoC can remove its own
supply.

**One codegen trap worth recording.** `udelay()` without
`generic_delay_timer_init()` is not a no-op — `timer_ops` is provably NULL, so
GCC treats the call as undefined behaviour and deletes *everything after it*.
The first build silently emitted a `SYSTEM_RESET` that programmed half the
watchdog and then fell through into the next function. The build is clean and
the fix is one call; the only reason it was caught is that the disassembly was
read. Read it again after any change to this platform.

**What the check asserts** (`checks.<system>.atf-mainline`, 15 assertions, all
read back out of the artefacts):

- the ELF's entry point and its first LOAD segment are both `0x40040000`, and
  the whole image spans 57 344 B of the 256 KiB window;
- the signed image is **14 456 B**, inside the 256 KiB `atf` partition;
- the Axera header's magic, capability word and RSA-2048 key descriptor match
  the vendor `atf_bl31_signed.bin` this repo builds, field for field;
- `img_size` equals the payload length, and both header checksums recompute
  with the SPL's arithmetic (32-bit wrapping sums of little-endian words:
  the payload for `img_check_sum`, header words 2..253 for `check_sum`);
- the last eight header bytes are zero, which is the only reason the SPL's
  2..255 sum and the signing tool's 2..253 sum agree (§11.2).

**Rung 1: the slot-B hardware test.** Reversible, unattended, no AXDL. It
proves the GIC, the PSCI mailbox, the second-core bring-up and the BL33
handoff, with the vendor U-Boot and the vendor kernel unchanged above it.

Slot B selects the `_b` copy of *every* A/B stage, so `uboot_b` (p6),
`kernel_b` (p15) and `dtb_b` (p13) must hold **working vendor images** before
the run. A previous mainline-kernel test may have left them otherwise; restore
them first (`/root/pre75` on the device holds the backups from #75/#76).

1. Build and copy: `nix build .#atf-mainline`, then
   `tools/kvmscp result/images/atf_bl31_mainline_signed.bin :/root/`.
2. Back up `atf_b` and write it. **`atf_b` is `/dev/mmcblk0p4`; `atf` (slot A,
   the recovery copy) is p3 and must not be touched.**
   ```
   dd if=/dev/mmcblk0p4 of=/root/atf_b.orig bs=256K count=1
   dd if=/root/atf_bl31_mainline_signed.bin of=/dev/mmcblk0p4 conv=fsync
   sync; echo 3 > /proc/sys/vm/drop_caches
   head -c $(stat -c%s /root/atf_bl31_mainline_signed.bin) /dev/mmcblk0p4 | md5sum
   md5sum /root/atf_bl31_mainline_signed.bin
   ```
   The two md5s must match. Take the byte count from `stat` every time — the
   image size changes between builds.
3. Arm slot B with the vendor script, never a raw `SLOTB` poke (a raw poke
   leaves `SLOTB_BOOTABLE` clear and silently falls back to A):
   ```
   /etc/init.d/S99checkboot systemB
   reboot
   ```
4. **The oracle** is the vendor system coming back on Ethernet with both CPUs
   up through PSCI:
   ```
   fw_printenv bootsystem          # B
   nproc                           # 2
   dmesg | grep -iE 'psci|CPU1|Booting Trusted|BL31'
   cat /sys/devices/system/cpu/cpu1/online   # 1
   ```
   `dmesg` should show `psci: probing for conduit method`, `psci: PSCIv1.x
   detected`, and `CPU1: Booted secondary processor`. A single-CPU boot with
   `psci: failed to boot CPU1` means the mailbox handoff is wrong and is the
   one interesting failure mode.
   Also expected, and not a fault: the `optee` driver no longer finds a TEE.
   The vendor SPL still loads OP-TEE to `0x44200000`, but a BL31 built with no
   SPD never enters it.
5. Prove `SYSTEM_RESET`, which the vendor BL31 never implemented: from the
   booted slot-B system, `reboot` should now go through PSCI rather than the
   watchdog shim. The board coming back is the whole test.
6. Return to slot A: `/etc/init.d/S99checkboot systemA; reboot`, then restore
   `atf_b` from `/root/atf_b.orig` if the run is finished with.

**Failure is cheap.** A BL31 that hangs never reaches U-Boot, so nothing
re-arms `SLOTB_BOOTABLE`; the SPL consumed it on the way in, and the next boot
— clean, watchdog or power cycle — is slot A with the vendor BL31 in p3.
Recovery is a power cycle, not AXDL.

---
