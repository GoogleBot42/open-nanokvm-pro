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
| GPIO | `axera,ax-apb-gpio` ×4 (`0x4800000`, `0x4801000`, `0x6000000`, `0x6001000`, SPI 114–117), **97** `gpio-ranges` (not 128; corrected 2026-09-06) | `drivers/gpio/gpio-axera.c` 538 LOC (defconfig also has `GPIO_DWAPB=y`, unused) | DesignWare *names* only: **one 32-bit register per GPIO** at `base + (n+1)*4` with DR/DDR/INTEN/… as bit fields, relocated port regs (`EXT_PORTA 0x8c`, secure/non-secure INTSTATUS `0x84/0xa4`), raw clock pokes at `0x4870000` (V) | **new driver** (~500 LOC); `gpio-dwapb` cannot bind | S–M | KVM (ATX, panel, LT6911 pins) |
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
| eMMC | `axera,sdhc` @`0x1B40000` (`mmc0`), HS400-ES, 8-bit, `cdns,phy-*` tuning props, 3 resets (`prst`/`arst`/`cardrst`), hw-reset GPIO2_A23 | `drivers/mmc/host/sdhci-axera.c` 1208 LOC | **Cadence SD4HC** — the vendor file is `sdhci-cadence.c` (Socionext header intact, `sdhci_cdns_*` names kept) with Axera additions; DT already uses the mainline `cdns,phy-*` properties (V) | `sdhci-cadence` (`cdns,sd4hc`) + `clocks =` (vendor gates by hand via `ax_set_mmc_clk`) + **no `resets`** — mainline binds index 0 as the *card* `RST_n`, so listing the vendor's `prst` there makes error recovery assert the controller's own APB reset; use `reset-gpios = <&gpio2 23 GPIO_ACTIVE_LOW>` for the real card reset. Tuning is byte-identical to upstream; the 1208-vs-675 gap is clock/reset integration plus dead code, not Axera tuning. Stock `sdhci-cadence` drives this IP — the only code needed is a 15-line `drv_data` entry for `SDHCI_QUIRK2_PRESET_VALUE_BROKEN`. See [sdhci-model-20260906.md](reference/mainline/sdhci-model-20260906.md) | S–M | **boot** |
| SD | `axera,sdhc` @`0x104E0000` (`mmc1`), UHS to SDR104, `broken-cd` | same | same | same | S | opt (test path) |
| SDIO | `axera,sdhc` @`0x104D0000` (`mmc2`), no-1.8V, WiFi | same | same | same | S | opt (WiFi) |
| Ethernet MAC | `axera,dwmac-4.10a` @`0x104C0000`, 5 clocks, 3 resets, `phy-mode = "rgmii"`, `snps,dwmac-mdio` | `drivers/net/ethernet/stmicro/stmmac/dwmac-axera-plat.c` 187 LOC glue over stmmac | **Synopsys DWMAC 4.10a** (V) | **DONE (#77)**: `dwmac-axera.c`, ~230 lines over mainline stmmac — four of the five clocks, the PHY-interface select and block reset as flash-syscon bits, an RGMII tx-clock hook, and a register poke for PHY reset GPIO1_A27 until #81 | S–M | **boot** (SSH) |
| Ethernet PHY | `ethernet-phy-id937c.4030` (JLSemi **JL2101**), 20 `jl2xxx,*` tuning props | `drivers/net/phy/jlsemi.c` 561 + `jlsemi-core.c` 3043 LOC | **The part is a Realtek RTL8211F, not a JL2101** — PHYID 0x001cc916 read over MDIO 2026-09-06 (V). The vendor DT's `ethernet-phy-id*` compatible forces the MDIO core to skip the bus read, so the JLSemi driver binds to a Realtek chip and works only because it programs almost nothing | **DONE (#77)**: mainline's own realtek driver, with `phy-mode = "rgmii-id"` — the RTL8211F's two 2 ns delays are pin-strapped on and mainline's driver *writes* them to match phy-mode. No JLSemi driver is needed or wanted | S | **boot** (SSH) |
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

Filed 2026-09-06 as #74–#87, in the dependency order below; the index map also
lives as a comment on #26. **#74, #75, #76 and #77 are done** (see "What exists
now" at the end of this section), and #80's source half is written and
boot-proven; everything else is open.

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
   `nanokvm-checkboot` after `nanokvm-healthy.target`; `RuntimeWatchdogSec` on
   `/dev/watchdog0`; kernel/dtb updates write the other slot and flip
   `bootsystem`; document the cold-power-cycle caveat. Hardware-test the
   ATF/U-Boot slot failover that updates.md still lists as unexercised.
   Depends on: #78.
7. **#80 Full clock driver + pinctrl (data model + driver)** — Extend the
   gate-only CCF driver to the 246 registered clocks incl. the fractional-N
   CPUPLL (`cpufreq-dt` follows); pinctrl driver + a regenerated dtsi (~30
   multi-group functions instead of 551 single-group ones), restoring the
   I2C `pinctrl-0` states the board dts deletes and turning the DEMO pad
   table into DT states; `gpio_request_enable` wired (kills the SW_PWR mux
   trap at the root). Depends on: #77 (can start in parallel).
8. **#81 GPIO + ATX + LT6911 on mainline** — New ~500-LOC driver for
   `axera,ax-apb-gpio` (one register per line; `gpio-dwapb` cannot bind);
   `lt6911_manage` gets a DT node (I2C0 @0x2b, GPIO descriptors, its three
   pinmux pokes as pinctrl states) and keeps its `/proc` ABI; `nanokvm-gpio`
   moves to libgpiod/DT names. Depends on: #80.
9. **#82 USB: dwc3 glue + gadget HID** — `dwc3-of-simple`-class glue (one
   PHY reset bit + clocks), `extcon-usb-gpio`, configfs `hid/mass_storage/ncm/
   uac2` as today (`usbdev.sh` contract from nixos-rootfs.md gap 2).
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
store or this repository. (The eth0 MAC is a provisioning-time literal in that
file — it is *not* derived from the SoC UID at boot, whatever the vendor's
USB-gadget scripts do for their own NCM addresses. Deriving it properly is #78.)
Static dropbear pulls in libxcrypt, which is what makes this work at all: the
vendor hashes root's password with yescrypt and musl's own `crypt()` cannot
verify that.

Milestone bits 18–21 are new — carrier up, address configured, ICMP round trip,
dropbear started — so the clear-mask is now **`0x3FF000`** and a fully
successful run reads `0x003FF014`. The dwell is 300 s rather than 120, because
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
