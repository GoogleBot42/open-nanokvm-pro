# AX630C (AX620E) SD/eMMC host controller — mainline driver specification

Issue #76. Written 2026-09-06 from the GPL-2.0 vendor 4.19 kernel, the Sipeed
SDK bootloaders (SPL `bl1`, U-Boot 2020.04), mainline Linux 7.1.3, and a
read-only capture of the running device. This is a behavioural specification: a
driver author needs nothing from the vendor tree beyond this file.

Every fact is marked **V** (read directly out of a cited source file or device
dump) or **I** (inferred — the reasoning is always stated). Anything unresolved
is a **GAP**, not a guess.

| Tag | Tree |
|---|---|
| `[K]` | `/nix/store/gzmk3ygvw8n2vgi230fplbv5295nf42q-source/linux/linux-4.19.125` (vendor kernel, GPL-2.0) |
| `[S]` | `/nix/store/k7b551m83qh9dpxdkvgjgjjc3w2rhknn-source` (Sipeed `maix_ax620e_sdk`: SPL `boot/bl1`, U-Boot `boot/uboot/u-boot-2020.04`) |
| `[M]` | mainline Linux 7.1.3 (`/nix/store/5ppifwlw1racpcicp36cc7kk5hsc9q2l-linux-7.1.3.tar.xz`) |
| `[D]` | `docs/reference/mainline/device-reads-20260906/` (live 4.19 device, read-only) |

Sibling specs this one leans on and cross-checks against:
`clk-model-20260906.md` (§4 here), `reset-model-20260906.md` (§5 here),
`pinctrl-model-20260906.md` (§6.6 here), `gpio-devmem-20260906.md` (§5.5 here).

Short names: `sdhci-axera.c` = `[K]/drivers/mmc/host/sdhci-axera.c` (1208 lines,
compatible `axera,sdhc`); `cdns-419.c` = `[K]/drivers/mmc/host/sdhci-cadence.c`
(460 lines, the 4.19 upstream Cadence driver shipped alongside it, never built —
`# CONFIG_MMC_SDHCI_CADENCE is not set`, V `[K]/arch/arm64/configs/axera_AX630C_emmc_arm64_k419_defconfig:2724`);
`cdns-713.c` = `[M]/drivers/mmc/host/sdhci-cadence.c` (675 lines); `sdhci-713.c`,
`pltfm-713.c`, `host-713.c`, `reset-core-713.c` = the corresponding `[M]` files;
`AX620E.dtsi`, `AX620E_resets.dtsi`, `AX630C_…_sipeed_nanokvm.dts` in
`[K]/arch/arm64/boot/dts/axera/`; `axera_reset.c` =
`[K]/drivers/reset/axera_reset/axera_reset.c`; `spl-cdns.c`/`spl-cdns.h`/`spl-mmc.c`
= `[S]/boot/bl1/driver/mmc/sdhci_cdns.c`, `[S]/boot/bl1/driver/include/sdhci_cdns.h`,
`[S]/boot/bl1/driver/mmc/axera_mmc.c`; `ub-sdhci.c` =
`[S]/boot/uboot/u-boot-2020.04/drivers/mmc/sdhci_ax620e.c`;
`ax620e-clock.h` = `[K]/include/dt-bindings/clock/ax620e-clock.h`.

**Read this first, if you read nothing else.** The answer the issue's framing did
not expect: **stock mainline `sdhci-cadence` drives this controller.** The IP is
a Cadence SD4HC, unmodified, and every register the vendor driver touches inside
the controller window is already handled upstream. The 1208-vs-675 line gap is
**not** unported controller logic — it is SoC integration that mainline expresses
in DT (clocks, resets, a reset-GPIO), plus ~230 lines of dead `#ifdef` and
SDIO/debug code. What #76 must actually write is (1) DT, (2) the clock IDs listed
in `clk-model-20260906.md` §5.2 *plus one it is missing*, and (3) about fifteen
lines of new match-table entry in `sdhci-cadence.c` for one quirk. §7 has the
exact text.

---

## 1. IP identity

**It is a Cadence SD4HC (IP6116 family). Confidence: certain (V), from three
independent sources that never see each other's code.**

| Evidence | Source |
|---|---|
| Register window is split HRS (Host Register Set, offset 0) + SRS (SDHCI-compatible Slot Register Set, offset `0x200`) — the defining Cadence SD4HC layout | V `sdhci-axera.c:49`; V `spl-cdns.h:9-10` (`HRS_BASE_OFFSET 0`, `SRS_BASE_OFFSET 0x200`); V `ub-sdhci.c:583` |
| `HRS04` at `0x10` is a PHY indirect-access port with ACK/RD/WR at bits 26/25/24, WDATA `[15:8]`, ADDR `[5:0]` | V `sdhci-axera.c:28-34`, `spl-cdns.c:14-22`, `cdns-713.c:20-26` — bit-for-bit identical in all three |
| `HRS06` at `0x18` carries the eMMC mode `[2:0]` and the hardware tune value `[13:8]` with a TUNE_UP strobe at bit 15 | V `sdhci-axera.c:36-46`, `spl-cdns.c:24-34`, `cdns-713.c:28-37` |
| PHY delay-line addresses `0x00`–`0x0d` match the upstream Cadence set exactly | V `sdhci-axera.c:52-64` vs `cdns-713.c:61-72` |
| The vendor file *is* `sdhci-cadence.c`: Socionext copyright and Masahiro Yamada author line intact, all `sdhci_cdns_*` symbol names kept, the IP6116 receive-path errata comment carried verbatim | V `sdhci-axera.c:2-5, 350-354, 1206-1207` |
| The board DT uses the upstream Cadence `cdns,phy-*` property names | V `AX630C_…_nanokvm.dts:321-332` |
| The vendor's own DT node is `sdhc@`, the platform device name is `1b40000.sdhc`, and the driver name is `sdhci-axera` | V `[D]/platform.txt:7,8,12,166`; V `[D]/iomem.txt:1,25,26` |

**One trap in the source material.** `spl-cdns.h:82-93` defines a *Synopsys*
DWC-MSHC PHY block (`EMMC_PHY_CNFG` at `0x300`, `EMMC_PHY_CMDPAD_CNFG`,
`SDCLKDL_DC`, `SMPLDL_CNFG`, `ATDL_CNFG`) alongside the Cadence defines. **Those
are dead copy-paste**: no `.c` file anywhere in `[S]/boot/bl1` references any
`EMMC_PHY_*` symbol (V, grep over the whole SPL). Do not let them mislead a
reader into porting `sdhci-of-dwcmshc`. Every real PHY access in the SPL goes
through `HRS04` (V `spl-cdns.c:520-549`).

**Version.** Both the vendor driver and mainline `sdhci-cadence` *override* the
Host Version register with a constant rather than reading it: vendor writes
`3 << SDHCI_SPEC_VER_SHIFT` (V `sdhci-axera.c:965`), mainline writes
`SDHCI_SPEC_400 << SDHCI_SPEC_VER_SHIFT` (V `cdns-713.c:555`). `SDHCI_SPEC_400`
**is** 3 (V `sdhci-713.h`, the SPEC enum), so the two are the same value and this
is not a delta. Both then call `sdhci_enable_v4_mode()` (V `sdhci-axera.c:1042`,
`cdns-713.c:587`).

---

## 2. Topology

| Instance | Base | Length | GIC | Linux name (vendor) | Board role |
|---|---|---|---|---|---|
| eMMC | `0x01B4_0000` | `0x10000` | `GIC_SPI 9` (hwirq 41) | `mmc0` → `/dev/mmcblk0` | boot + rootfs, HS400-ES, 8-bit |
| SD | `0x104E_0000` | `0x10000` | `GIC_SPI 74` (hwirq 106) | `mmc1` → `/dev/mmcblk1` | removable card, 4-bit |
| SDIO | `0x104D_0000` | `0x10000` | `GIC_SPI 73` (hwirq 105) | `mmc2` | aic8800 Wi-Fi |

V: `AX620E.dtsi:1172-1207` for all three nodes; V: `[D]/iomem.txt:1,25,26` shows
all three windows live; V: `[D]/interrupts.txt:17-19` shows `GIC-0 41 → mmc0`,
`106 → mmc1`, `105 → mmc2`, confirming the SPI→hwirq offset of 32 and the
instance ordering. The `0x10000` window is what the vendor DT reserves; the IP
itself needs only `0x200 + 0x100` (V, upstream binding example uses `0x400`).

The vendor SoC nodes carry `#address-cells`/`#size-cells` (V
`AX620E.dtsi:1174-1175`) — meaningless on a leaf node, drop them.

---

## 3. The PHY / DLL

### 3.1 Access protocol

The PHY is **not** memory-mapped. It is reached through the Cadence HRS04
indirect port at `hrs_base + 0x10`:

| Field | Bits | Meaning |
|---|---|---|
| `ACK` | 26 | Hardware handshake. Read-only from software's view. |
| `RD` | 25 | Write 1 to request a read of `ADDR`. |
| `WR` | 24 | Write 1 to commit `WDATA` to `ADDR`. |
| `RDATA` | 23:16 | Read result. |
| `WDATA` | 15:8 | Byte to write. |
| `ADDR` | 5:0 | PHY register index. |

V: `sdhci-axera.c:28-34`; V (independent) `spl-cdns.c:14-22`; V (independent)
`cdns-713.c:20-26`.

**Write sequence** (four register accesses plus three polls), effect described:
poll until `ACK` is *clear*; write the word with `WDATA` and `ADDR` set and `WR`
clear; write the same word again with `WR` set; poll until `ACK` is *set*; write
the word again with `WR` cleared; poll until `ACK` is *clear* again. Each poll
has a 10 µs budget. V: `sdhci-axera.c:185-215`.

**Mainline's write sequence is identical, including both `ACK` polls** (V
`cdns-713.c:127-157`). The vendor added the leading and trailing polls relative
to `cdns-419.c:101-124`, which had neither; upstream added the same two polls
later. There is nothing to port here.

**Read sequence** (vendor-only, diagnostic): read the port, replace the low byte
with the address, write it back; set `RD`; poll for `ACK` set (10 µs); write the
whole port to zero; the result is `port >> 16`. V: `sdhci-axera.c:217-249`. Note
the vendor's own bug — it clears `RD` in a local variable and then writes `0` to
the register instead (V `:238-240`) — which is harmless because the next write to
the port reprograms it wholesale. Mainline has no PHY read path.

### 3.2 PHY register map and the `cdns,phy-*` mapping

| PHY addr | Symbol | DT property | In `cdns-713.c` table? | eMMC value (our board) | SD value |
|---|---|---|---|---|---|
| `0x00` | `DLY_SD_HS` | `cdns,phy-input-delay-sd-highspeed` | **yes** | 2 | 2 |
| `0x01` | `DLY_SD_DEFAULT` | `cdns,phy-input-delay-legacy` | **yes** | 4 | 3 |
| `0x02` | `DLY_UHS_SDR12` | `cdns,phy-input-delay-sd-uhs-sdr12` | **yes** | 1 | 3 |
| `0x03` | `DLY_UHS_SDR25` | `cdns,phy-input-delay-sd-uhs-sdr25` | **yes** | 2 | 2 |
| `0x04` | `DLY_UHS_SDR50` | `cdns,phy-input-delay-sd-uhs-sdr50` | **yes** | 1 | 1 |
| `0x05` | `DLY_UHS_DDR50` | `cdns,phy-input-delay-sd-uhs-ddr50` | **yes** | 2 | 1 |
| `0x06` | `DLY_EMMC_LEGACY` | `cdns,phy-input-delay-mmc-legacy` | **NO** | 1 (**ignored**) | — |
| `0x07` | `DLY_EMMC_SDR` | `cdns,phy-input-delay-mmc-highspeed` | **yes** | 2 | — |
| `0x08` | `DLY_EMMC_DDR` | `cdns,phy-input-delay-mmc-ddr` | **yes** | 2 | — |
| `0x09` | `LOCK_VALUE` | — (read-only status) | no | — | — |
| `0x0b` | `DLY_SDCLK` | `cdns,phy-dll-delay-sdclk` | **yes** | 45 | 0 |
| `0x0c` | `DLY_HSMMC` | `cdns,phy-dll-delay-sdclk-hsmmc` | **yes** | 31 | — |
| `0x0d` | `DLY_STROBE` | `cdns,phy-dll-delay-strobe` | **yes** | 18 | — |
| `0x0f` | `DLL_RESET` | — (no property) | **NO** | pulsed 0→1 | pulsed 0→1 |

V for the addresses: `sdhci-axera.c:52-65`. V for the property↔address table and
its 11 entries: `sdhci-axera.c:171-183` — **identical, entry for entry and in the
same order, to `cdns-713.c:107-119`.** V for our board's values:
`AX630C_…_nanokvm.dts:321-332` (eMMC), `:358-364` (SD), `:384-390` (SDIO).

Three consequences, all load-bearing for #76's DT:

1. **`cdns,phy-input-delay-mmc-legacy = <1>` on our eMMC node does nothing today
   and must be deleted.** Address `0x06` exists (V `sdhci-axera.c:58`) but is
   absent from the vendor's *own* property table (V `:171-183`) — so the vendor
   driver silently drops it, exactly as mainline would. Worse, mainline's binding
   is `unevaluatedProperties: false` (V `[M]/Documentation/devicetree/bindings/mmc/cdns,sdhci.yaml`),
   so leaving it in makes `dtbs_check` fail. Delete it; nothing regresses,
   because nothing ever applied it. (The SPL *does* program `0x06 = 10` directly,
   V `spl-cdns.c:567`, and Linux has never overwritten that.)
2. **Every other `cdns,phy-*` on all three nodes is parsed by mainline 7.1.3
   unchanged.** No glue needed for any of them. The upstream schema caps the input
   delays at `0x1f` and the DLL delays at `0x7f`; our largest values are 45 and 31,
   both in range (V, schema + dts).
3. `0x0f` (`DLL_RESET`) and `0x09` (`LOCK_VALUE`) are Axera additions to the
   symbol list, not to the property list. See §3.3.

### 3.3 The DLL reset pulse — the one PHY behaviour mainline lacks

Before writing the delay parameters, the vendor writes `0` then `1` to PHY
address `0x0f`. Effect, in the vendor's own words: driving this signal low puts
the DLL at the start of its locking mechanism; on de-assertion the master DLL
begins searching for lock; it is recommended to assert it low when changing the
sdmclk frequency. V: `sdhci-axera.c:285-290` (comment and the two writes).

Mainline's `sdhci_cdns_phy_init()` writes the parameters and nothing else (V
`cdns-713.c:190-202`). This is the **only** PHY-programming difference between
the two drivers.

Is it needed? The vendor's *own bootloader* does the same pulse before its own
parameter writes (V `ub-sdhci.c:1290-1291`, using the identical `0x0f` symbol at
`:59`), and the U-Boot pass runs at the final 200 MHz card clock and lands
`SDCLK = 45`, `HSMMC = 23`, `STROBE = 18` (V `spl-cdns.c:572-574` for the SPL's
values). Linux then re-writes the same set with `HSMMC = 31` instead of 23.
Because U-Boot already left the DLL locked at the operating frequency, and Linux
does not change the card-clock frequency at the syscon (§4), **a mainline driver
that skips the pulse starts from an already-locked DLL (I, well supported).**
Classification: **(c), optional but recommended** — two lines, and the first thing
to add if HS400-ES is unstable. §7 gives the shape.

**Lock check (diagnostic).** After `sdhci_add_host()` the vendor reads PHY `0x09`
and reports "phy lock successful" if bit 7 of the returned byte is set (V
`sdhci-axera.c:243-247, 1078`). This is a genuinely useful bring-up oracle and is
worth reproducing as a `dev_dbg` — but it is **(d)**: nothing depends on it.

---

## 4. Clocking

### 4.1 What the hardware needs

| Domain | Provider (clk-model §2) | Register | Field | ID |
|---|---|---|---|---|
| eMMC card clock mux | `cpu_clk` `0x1900000` | `0x00` (`CLK_MUX0`) | `[6:5]`, value 3 = `npll_400m` | 1 `CLK_EMMC_CARD_SEL` |
| eMMC card clock gate | `cpu_clk` | `0x04` (`CLK_EB0`) | bit 2 | 5 `CLK_EMMC_CARD_EB` |
| eMMC controller gate | `cpu_clk` | `0x08` (`CLK_EB1`) | bit 4 (**I**) | 14 `CLK_EMMC_EB` |
| eMMC card divider | `cpu_clk` | `0x0C` (`CLK_DIV0`) | `[5:0]`, update strobe bit 6 | 20 `CLK_EMMC_CARD_DIVN` |
| SD card mux | `flash_clk` `0x10030000` | `0x00` | `[17:16]`, value 3 = `npll_400m` | 3 `CLK_SD_CARD_SEL` |
| SD card gate | `flash_clk` | `0x04` | bit 9 | 16 `CLK_SD_CARD_EB` |
| SD APB gate | `flash_clk` | `0x08` | bit 17 | 28 `PCLK_SD_M_EB` |
| SD AXI gate | `flash_clk` | `0x08` | bit 3 | 42 `ACLK_SD_M_EB` |
| SD card divider | `flash_clk` | `0x0C` (`CLK_DIV0`) | `[25:20]`, update strobe bit 26 | 46 `CLK_SD_CARD_DIVN` |
| SDIO card mux | `flash_clk` | `0x00` | `[19:18]` | 2 `CLK_SDIO_M_CARD_SEL` |
| SDIO card gate | `flash_clk` | `0x04` | bit 10 | 15 `CLK_SDIO_M_CARD_EB` |
| SDIO APB gate | `flash_clk` | `0x08` | bit 18 | 27 `PCLK_SDIO_M_EB` |
| SDIO AXI gate | `flash_clk` | `0x08` | bit 4 | 41 `ACLK_SDIO_M_EB` |
| SDIO card divider | `flash_clk` | `0x10` (`CLK_DIV1`) | `[5:0]`, update strobe bit 6 | 51 `CLK_SDIO_M_CARD_DIVN` |
| **pinmux APB gate** | `flash_clk` | `0x08` | **bit 16** | **29 `PCLK_PINMUX_EB`** |

V for every field position and mux value: `sdhci-axera.c:120-133` (the shift/mask
macros) and their uses at `:690-761`. V for the register-offset aliasing
(`+0x1000`/`+0x2000` set/clear on `cpu_clk`, `+0x4000`/`+0x8000` on `flash_clk`):
`sdhci-axera.c:96-118`. V for the IDs: `ax620e-clock.h:17,21,30,36` (cpu) and
`:274,275,287,288,299,300,301,313,314,318,323` (flash). V (independent, and the
same field positions): `ub-sdhci.c:570-612` and `spl-mmc.c:22-73`.

The divider raw value the vendor programs is `1` for a 200 MHz card clock off
`npll_400m` (V `sdhci-axera.c:698-699`), consistent with the Axera divider's
`{1, 2, 4, 6, …}` table documented in `clk-model-20260906.md` §6 — raw 1 = ÷2.

### 4.2 What the vendor driver does about them

**It ignores the CCF entirely and pokes the syscons with a private `ioremap`.**
The whole `struct clk`-based path exists but is compiled out (`USING_CLK_FRAME`
is not defined, V `sdhci-axera.c:22`). The live path — one function per stage —
disables the card gate, clears then sets the mux to `npll_400m`, re-enables the
gate, clears then sets the divider and pulses its update bit, and for the SD and
SDIO instances additionally sets the APB and AXI gates in `CLK_EB1`. Effect, per
instance, is a fixed 200 MHz card clock. V: `sdhci-axera.c:690-761` (mux/gate/div),
`:823-923` (the APB/AXI gates at `:880` and `:888`, and the teardown path),
`:1035-1039` (probe calls it disabled-then-enabled around the reset deassert).

Notably **the eMMC path never touches an APB or AXI gate** (V, `ax_set_mmc_clk()`
has no `CLK_EB1` write for the eMMC branch) — only SD and SDIO do. (I) the eMMC
controller's bus clocks are on out of reset or left on by firmware, which is
consistent with U-Boot having just read the kernel through that controller.

**The vendor CCF driver does not model any of these clocks.** `[D]/clk_summary.txt`
contains no `emmc`, `sd_` or `sdio` row at all (V, grep). That is exactly what
`clk-model-20260906.md` §1.2/§5.2 predicts: the IDs exist in the header but were
never registered.

### 4.3 What mainline wants

`sdhci_cdns_probe()` begins with `devm_clk_get_enabled(dev, NULL)` and returns its
error immediately (V `cdns-713.c:557-559`). So:

* **`clocks` is mandatory.** With no `clocks` property the probe fails `-ENOENT`
  before touching the hardware. On a serial-less board that is a silent
  no-rootfs boot. This is the single most likely way #76 fails first time.
* **Exactly one clock, and it is unnamed.** The binding says `clocks: maxItems: 1`
  and lists no `clock-names` (V `cdns,sdhci.yaml`). `devm_clk_get_enabled(dev, NULL)`
  takes index 0.
* **The rate is never read.** `sdhci_cdns_ops` has no `.get_max_clock` (V
  `cdns-713.c:473-480`), so `sdhci_setup_host()` takes `host->max_clk` from the
  CAPS register's base-clock field, not from the clock (V `sdhci-713.c:4432-4437`).
  The clock handle exists only to be prepared/enabled and re-enabled on resume (V
  `cdns-713.c:572, 621`).

**Verdict.** Name the **card clock gate** as the one `clocks` entry — that is the
clock whose absence stops transfers:

```
eMMC:  clocks = <&cpu_clk   AX630C_CLK_EMMC_CARD_EB>;   /* cpu   id 5  */
SD:    clocks = <&flash_clk AX630C_CLK_SD_CARD_EB>;     /* flash id 16 */
SDIO:  clocks = <&flash_clk AX630C_CLK_SDIO_M_CARD_EB>; /* flash id 15 */
```

The other gates cannot be expressed through this binding, so the #80 clock driver
must keep them on: mark `CLK_EMMC_EB` (14), `PCLK_SD_M_EB` (28), `ACLK_SD_M_EB`
(42), `PCLK_SDIO_M_EB` (27), `ACLK_SDIO_M_EB` (41) **`CLK_IS_CRITICAL`**. That is
an honest description — they are bus clocks for a boot device and nothing should
ever gate them — and it needs no driver change. Model the muxes and dividers
`CLK_DIVIDER_READ_ONLY` / read-only-mux: firmware already set both to
`npll_400m ÷ 2 = 200 MHz` and mainline never asks to change them.

### 4.4 Cross-check against `clk-model-20260906.md` §5.2

§5.2's eMMC row (IDs 1/5/14/20) and SD/SDIO row (2/3/15/16/27/28/41/42/46/51) are
**complete and correct for this controller** — every ID the vendor driver's
register pokes correspond to is present, at the register and bit position §5.2
states, and I re-derived all of them independently from `sdhci-axera.c:120-133`
and the bootloaders. Two notes:

1. **§5.2 is missing one ID that #76 needs: `AX620X_PCLK_PINMUX_EB` = flash id
   **29**, `flash_clk + 0x08` bit **16**.** The vendor's SD/SDIO voltage switch
   enables it before reading the pad voltage-detect bit (V `sdhci-axera.c:93`
   defines `CLK_EB_1 = 0x10030008` and `:478-481`/`:518-521` set bit 16 there),
   and `ax620e-clock.h:301` names id 29 exactly there. This is also an
   *independent confirmation* of the §7 descending-ID rule: ids 27/28 sit at bits
   18/17, so id 29 must sit at bit 16 — and the vendor's magic `1 << 16` write
   proves it. Add it to the #80 table; the #80 pinctrl node needs it too.
2. §5.2 says mainline `sdhci-cadence` "will call `clk_get`" — correct, and it
   calls it exactly **once, unnamed**, not once per gate. The count §5.2 provides
   (4 for eMMC, 5 each for SD/SDIO) is a superset of what DT can name; the surplus
   becomes `CLK_IS_CRITICAL`, per §4.3.

---

## 5. Resets

### 5.1 The three lines

Every `sdhc@` node carries three resets, named `prst`, `arst`, `cardrst`, on an
Axera 4-cell reset controller whose specifier is
`<set_bit set_reg clr_bit clr_reg>` (V `AX620E_resets.dtsi:14-18, 104-108`
declaring `#reset-cells = <4>`; V `axera_reset.c:215-220` decoding the four cells;
V `axera_reset.c:109-129` — assert writes `BIT(bit)` to the *set* register,
deassert writes `BIT(bit)` to the *clear* register).

| Instance | Syscon | `SW_RST0` value reg | `prst` (APB) | `arst` (AXI) | `cardrst` |
|---|---|---|---|---|---|
| eMMC | `cpu_clk` `0x1900000` (set `+0x1010`, clr `+0x2010`) | `0x10` | bit **12** | bit **12** | bit **11** |
| SD | `flash_clk` `0x10030000` (set `+0x4014`, clr `+0x8014`) | `0x14` | bit **17** | bit **16** | bit **15** |
| SDIO | `flash_clk` | `0x14` | bit **20** | bit **19** | bit **18** |

V: `AX620E.dtsi:1178-1181, 1190-1193, 1202-1205`. Note the eMMC's `prst` and
`arst` phandle args are **the same bit twice** (V `:1178-1179`) — on this instance
the APB and AXI resets share one control bit; the vendor DT simply lists it under
both names.

The sibling spec `reset-model-20260906.md` §3.2 derives this same table
independently, from a whole-tree survey of all 68 reset specifiers, and agrees
bit for bit — including the eMMC's `prst == arst`. Its §9 reaches the same
"#76 should ship no `resets`" conclusion from the reset side. Two documents, two
methods, one answer.

`cardrst` is not a card reset. Its documented purpose is a DLL re-lock pulse
after the card clock is reprogrammed: the SPL asserts and immediately deasserts
it right after setting the mux and divider, commented "set emmc_card_sw_rst for
dll lock", with a 1 µs hold (V `spl-mmc.c:49-52` for eMMC bit 11, `:68-71` for SD
bit 15).

### 5.2 What the vendor driver does with them

Only ever **deassert**, once, at probe, between disabling and enabling the clocks:
`arst`, then `prst`, then `cardrst`. The reverse order (`cardrst`, `arst`, `prst`)
is asserted only on the probe error path. V: `sdhci-axera.c:645-665` (the two
orders), `:1035-1039` (the probe call sequence), `:1091` (error path). They are
acquired with `devm_reset_control_get_optional()`, so a missing one is not fatal
(V `:623-643`).

### 5.3 Does mainline sdhci-cadence handle resets? — and the trap

**It has exactly one reset, and it is not any of these.** `sdhci_cdns_probe()`
takes `devm_reset_control_get_optional_exclusive(dev, NULL)` — index 0, unnamed —
*only if* `MMC_CAP_HW_RESET` is set, and wires it to `card_hw_reset`, which
asserts, waits 3 µs, deasserts and waits 300 µs — i.e. the **eMMC RST_n pin**
(V `cdns-713.c:602-609, 529-543`). The binding agrees: `resets: maxItems: 1`
(V `cdns,sdhci.yaml`).

**Therefore: a mainline DT for this SoC must NOT put `prst`/`arst`/`cardrst` in
`resets`.** If it did, `card_hw_reset` would assert the controller's APB reset
mid-operation. This is the sharpest single mistake #76 could make, and it would
present as an eMMC that works until the first `mmc_hw_reset()` and then wedges.

### 5.4 Can a mainline driver simply not touch them?

**Yes. For eMMC (certain) and for SD (very likely).**

* No bootloader deasserts them. The SPL's clock-and-reset routine for eMMC and SD
  is inside an `#if 0` block (V `spl-mmc.c:22-74`), and U-Boot's `sdhci_ax620e.c`
  contains no reset API call and no `SW_RST0` write anywhere in its 1512 lines (V,
  grep for `reset`/`RST` — the only hits are the SDHCI *software* reset register
  inside the SRS window, `:179, 535-536, 865`). Its `axera_sys_glb_clk_set()`
  programs mux/gate/divider and stops (V `ub-sdhci.c:580-612`).
* Yet U-Boot reads the kernel and dtb off eMMC on every boot through this exact
  controller. **So the power-on state of the eMMC `prst`/`arst`/`cardrst` bits is
  already deasserted** (I, but as strong as an inference gets: the boot works and
  nothing wrote those bits).
* For SD the same registers, the same reset controller and the same firmware
  behaviour apply, so (I) the SD bits are also deasserted at power-on. The SPL's
  own SD-boot path (`flash_boot(FLASH_SD)`) likewise never deasserts them.
* The vendor kernel's deassert is therefore a no-op on a normal boot. It matters
  only after something has asserted them, and nothing in our stack ever will.

**Residual risk and how to see it.** If SD *were* held in reset, the SRS window
would read back as zeroes, `host->caps` would be 0, the CAPS base-clock field
would be 0, and `sdhci_setup_host()` would abort with
`"Hardware doesn't specify base clock frequency"` and `-ENODEV` (V
`sdhci-713.c:4438-4445`) — a clean, non-hanging, log-visible failure. eMMC would
fail the same way, but eMMC cannot be in reset because U-Boot just used it.
§9 gives the `/dev/mem` read that settles this before a boot is ever attempted.

**If it turns out they do need touching**, do not add them to `resets` on the mmc
node (`reset-model-20260906.md` §9 gives the deassert as three `devmem` writes if
it has to be done by hand). Either (a) pulse `cardrst` from the #76 clock driver's divider `set_rate`
(that is what the pulse is *for*, per §5.1), or (b) use the in-controller PHY DLL
reset of §3.3, which needs no reset controller at all.

### 5.5 The eMMC card reset GPIO — free, via a mainline mechanism

The board resets the eMMC chip through **GPIO2_A23**, active low: the vendor DT
uses a non-standard `hw-reset = <&ax_gpio2 23 0>` property (V
`AX630C_…_nanokvm.dts:313-314`), the driver requests it `GPIOF_OUT_INIT_HIGH` and
pulses low-10 µs-high on `mmc_hw_reset` (V `sdhci-axera.c:550-557, 571-580`), and
the SPL does the same thing by raw register write — `0x2` then 10 µs then `0x3`
at `GPIO2_BASE + 0x60`, with the JEDEC 84-B51 timings quoted in the comment (V
`spl-mmc.c:5-15`). The device confirms it: `[D]/gpio.txt:32` shows
`gpio-87 (eMMC HW RESET) out hi`, and 87 = gpiochip2 base 64 + 23.

`hw-reset` is not a mainline binding, but **mainline gets there anyway**. When a
device node has no `resets` property, the reset core falls back to `reset-gpios`,
synthesises a `reset-gpio` auxiliary controller over it, and hands it back as an
ordinary `struct reset_control` (V `reset-core-713.c:1166-1186`; the auxiliary
driver is `[M]/drivers/reset/reset-gpio.c`, whose assert = `gpiod_set_value(1)`).
So:

```
cap-mmc-hw-reset;
reset-gpios = <&gpio2 23 GPIO_ACTIVE_LOW>;
```

gives us `card_hw_reset` with **no glue code**. Three conditions, all cheap:

* `CONFIG_RESET_GPIO=y`. Without it the fallback is skipped and the optional get
  returns NULL — no error, just no hardware reset (V `reset-core-713.c:1167-1168`).
* The GPIO controller must use `#gpio-cells = <2>`; the fallback rejects anything
  else with `-ENOENT` (V `reset-core-713.c:1021-1028`). A constraint on #81.
* The flags cell must be 0 or `GPIO_ACTIVE_LOW` (1); anything larger is rejected
  with `-EINVAL` and a `pr_err` (V `reset-core-713.c:1048-1052`). `GPIO_ACTIVE_LOW`
  is what we want and is exactly at the limit.

One behavioural difference: the vendor re-runs `sdhci_cdns_phy_init()` after every
card hardware reset (V `sdhci-axera.c:579`). Mainline does not. (I) unnecessary —
`RST_n` resets the eMMC device, not the host PHY, and the PHY delay lines are not
in that reset domain. Classified **(d)**.

---

## 6. Card and bus quirks

### 6.1 `sdhci-caps-mask` — honoured by mainline, and mostly redundant

`sdhci-caps-mask` **is** a mainline property, parsed in the sdhci **core**, not by
any vendor code: `__sdhci_read_caps()` reads it as a `u64` and clears
`lower_32_bits()` from `CAPABILITIES` (`0x40`) and `upper_32_bits()` from
`CAPABILITIES_1` (`0x44`). The positive counterpart `sdhci-caps` ORs bits back in.
V: `sdhci-713.c:4161-4186`. A two-cell DT value is big-endian, so the **first**
cell is the caps1 mask and the **second** is the caps mask.

| Node | DT value | caps1 mask (cell 0) | caps mask (cell 1) | Decoded |
|---|---|---|---|---|
| eMMC | `<0x2 0x03200000>` | `0x2` | `0x03200000` | caps1: `SDHCI_SUPPORT_SDR104`. caps: `CAN_DO_HISPD` (bit 21) + `CAN_VDD_330` (bit 24) + `CAN_VDD_300` (bit 25) |
| SD / SDIO | `<0x7 0x00200000>` | `0x7` | `0x00200000` | caps1: `SUPPORT_SDR50 \| SDR104 \| DDR50`. caps: `CAN_DO_HISPD` |

V for the values: `AX630C_…_nanokvm.dts:306, 338, 370`. V for the bit names:
`sdhci-713.h:263, 266, 267, 274, 275, 276`.

**All of it is redundant or actively wrong, and #76 should drop the property.**

* The `HISPD` bit only makes `sdhci_setup_host()` set `MMC_CAP_SD_HIGHSPEED |
  MMC_CAP_MMC_HIGHSPEED`, which the DT's own `cap-sd-highspeed` /
  `cap-mmc-highspeed` set anyway. Masking it changes nothing.
* The caps1 UHS bits likewise only seed `mmc->caps` UHS flags that the DT's
  `sd-uhs-*` properties then re-add. On the eMMC node, where `no-sd` is set, an
  SD-UHS capability is inert regardless.
* **The `CAN_VDD_330 | CAN_VDD_300` mask on the eMMC node is not a trap — measured.**
  `sdhci_setup_host()` builds `ocr_avail` purely from the three CAPS voltage
  bits and aborts with `"Hardware doesn't report any support voltages"` /
  `-ENODEV` if the result is zero (V `sdhci-713.c:4688-4736`). The vendor
  force-assigns
  `mmc->ocr_avail = MMC_VDD_32_33 | 31_32 | 30_31 | 29_30 | 28_29 | 27_28 | 165_195`
  before `sdhci_add_host()` (V `sdhci-axera.c:1041`), and a pre-set `mmc->ocr_avail`
  wins over the computed one (V `sdhci-713.c:4714-4716`); stock `sdhci-cadence`
  sets no such thing. That made the mask look fatal on stock mainline. **It is
  not: the CAPS register advertises all three voltages** (V, §10 read 1 —
  `CAPS0 = 0x176AC8B2`, bit 24 `CAN_VDD_330`, bit 25 `CAN_VDD_300`, bit 26
  `CAN_VDD_180`, all set). The mask clears 24 and 25 and leaves 26, so
  `ocr_avail` becomes `MMC_VDD_165_195` — non-zero, and correct for a 1.8 V
  HS400ES part. Probe survives.

  **Drop the mask anyway, for the boring reason:** every bit it clears is
  re-added three lines later by `cap-mmc-highspeed` / `sd-uhs-*`, so it is
  redundant, and it leaves the eMMC on a 1.8 V-only OCR by accident rather than
  by intent. This is a tidiness fix, **not** a boot blocker — do not sequence it
  as one. A 3.3 V `vmmc-supply` fixed regulator is the idiomatic mainline way to
  state the intent explicitly if it is ever wanted
  (`mmc_regulator_get_supply()` runs before the OCR computation,
  V `sdhci-713.c:4297`).

### 6.2 `fixed-emmc-driver-type = <4>`

Parsed by mainline `mmc_of_parse()` (V `host-713.c:405`). No glue. Type 4 =
50 Ω / driver strength D. Keep it verbatim.

### 6.3 `broken-cd`, `non-removable`, `disable-wp`, `no-sd`/`no-sdio`/`no-mmc`

All parsed by mainline `mmc_of_parse()` (V `host-713.c:315-400`). `broken-cd` is
parsed *twice*, deliberately: `mmc_of_parse()` sets `MMC_CAP_NEEDS_POLL`
(V `host-713.c:325`) and `sdhci_get_of_property()` sets
`SDHCI_QUIRK_BROKEN_CARD_DETECTION` (V `pltfm-713.c:89-90`). `sdhci-cadence`
calls both (V `cdns-713.c:590-592`). No glue.

### 6.4 Tuning

`sdhci_cdns_execute_tuning()` is byte-identical between the two drivers for the
part that matters: skip unless the timing is `MMC_TIMING_MMC_HS200` or
`MMC_TIMING_UHS_SDR104`; sweep tune values 0..39 writing `HRS06[13:8]` with the
TUNE_UP strobe issued **twice** per value (the IP6116 receive-path errata); take
the midpoint of the longest passing streak. V: `sdhci-axera.c:336-408` vs
`cdns-713.c:239-352`.

Mainline adds one step the vendor does not have: after settling the tune value it
runs `sdhci_cdns_tune_blkgap()`, which writes `HRS37` (`0x94`) = the HS200 mode
code `0x23`, then sweeps `HRS38` (`0x98`) from 0 to 15 doing a real 32×512-byte
read from LBA 0 until one succeeds (V `cdns-713.c:282-307, 351`;
`mmc_read_tuning()` at `[M]/drivers/mmc/core/mmc_ops.c:1097`). **`HRS37`/`HRS38`
are absent from every AX630C source we have** — the vendor kernel, the SPL and
U-Boot all stop at `HRS06`. If the AX630C's SD4HC configuration does not
implement them, the writes land in a decoded-but-unimplemented part of the 64 KiB
window and the gap loop degenerates to "does a plain multi-block read work?",
which it will, on the first iteration. That is benign. But it is a genuinely new
code path relative to anything ever run on this silicon — see §8, risk 4.

### 6.5 `set_uhs_signaling` — the one silicon-visible behavioural difference

Both drivers map timings to `HRS06[2:0]`. The mapping differs in two places:

| Timing | Vendor eMMC-only host | Mainline (all hosts) |
|---|---|---|
| `MMC_TIMING_MMC_HS` | `0x2` MMC_SDR | `0x2` MMC_SDR |
| `MMC_TIMING_MMC_DDR52` | `0x3` MMC_DDR | `0x3` MMC_DDR |
| `MMC_TIMING_MMC_HS200` | `0x4` | `0x4` |
| `MMC_TIMING_MMC_HS400` | `0x5`, or `0x6` if enhanced strobe | same |
| **anything else (incl. `MMC_TIMING_LEGACY`)** | **`0x1` MMC_LEGACY** | **`0x0` MMC_SD**, then `sdhci_set_uhs_signaling()` |
| SD/SDIO host, any timing | HRS06 **untouched**; `sdhci_set_uhs_signaling()` only | `0x0` written, then `sdhci_set_uhs_signaling()` |

V: `sdhci-axera.c:411-444` (note the `caps2 & MMC_CAP2_NO_SDIO && caps2 &
MMC_CAP2_NO_SD` gate at `:416-417`, i.e. "eMMC-only host") vs `cdns-713.c:354-386`.
V: mode value `0x1` = `MODE_MMC_LEGACY` is an Axera addition to the symbol list
(`sdhci-axera.c:41`), absent from `cdns-419.c` and from `cdns-713.c`.

The eMMC identification sequence (CMD0/CMD1/CMD2/CMD3 at 400 kHz) runs in
`MMC_TIMING_LEGACY`, so on a mainline kernel it will run with `HRS06` mode `0`
(SD) where the vendor uses `1` (MMC legacy). **This is the only place where stock
mainline programs the controller differently from anything that has ever run on
this chip.** Two reasons not to worry, and one reason to keep it on the risk list:
upstream `sdhci-cadence` has always done this and boots eMMC on UniPhier, Elba and
EyeQ; and the SPL itself drives eMMC in both modes and only sets `MODE_MMC_LEGACY`
after identification (V `spl-cdns.c:719-732`). But if eMMC enumeration fails at
400 kHz with a mainline kernel, **this is the first thing to change** — it is a
one-line addition to the `switch`. See §8, risk 3.

### 6.6 1.8 V signalling and the pad-voltage switch — the real SD-only gap

`sdhci_axera_voltage_switch()` is an `sdhci_ops.voltage_switch` hook with no
mainline counterpart. What it does, per instance:

**SD (pin group G9, base `0x104F1000`):**
* To 3.3 V: write `GENMASK(8,7)` to the group MISC0 **clear** alias at `0x104F1008`.
* To 1.8 V: sleep 15 ms; enable `flash_clk + 0x08` bit 16 (`PCLK_PINMUX_EB`, §4.4);
  read the group's voltage-detect word at `0x104F1058` — **bit 0 clear means the
  rail has reached 1.8 V**; only then write `GENMASK(8,7)` to the MISC0 **set**
  alias at `0x104F1004`.
* Guarded by "the host advertises some UHS mode and 4-bit data".

**SDIO (pin group G12, base `0x104F2000`):** identical, with `0x104F2008/4/58`,
plus a board GPIO from the DT property `vol-sw-gpio` driven high for 1.8 V and low
for 3.3 V *before* the pad switch.

V: `sdhci-axera.c:82-90` (G9 addresses), `:87-90` (G12), `:93` (`CLK_EB_1`),
`:455-539` (the whole function), `:1068-1074` (`vol-sw-gpio`). Cross-checked
against `pinctrl-model-20260906.md` §1.5, which independently documents MISC0
bits `[8:7]` as the I/O voltage select for a group's CMD/DATA pads and `+0x58` as
the read-only 1.8 V detect.

Mainline's generic path sets `SDHCI_CTRL_VDD_180` in `HOST_CONTROL2` and drives a
`vqmmc-supply` regulator; there is no `vqmmc` on this board and no syscon-regulator
binding that fits a MISC0 bit field. So on stock mainline the pads stay at 3.3 V
while an SD card switched to 1.8 V signalling — CRC errors, and at best a fallback
to high speed.

**#76's answer: put `no-1-8-v` on the SD node.** `sdhci_get_of_property()` turns it
into `SDHCI_QUIRK2_NO_1_8_V`, and `sdhci_setup_host()` then clears
`SUPPORT_SDR50|SDR104|DDR50` from caps1 and `MMC_CAP2_HSX00_1_8V|HS400_ES` and
`MMC_CAP_1_8V_DDR|MMC_CAP_UHS` from the mmc caps (V `pltfm-713.c:92-93`;
`sdhci-713.c:4590-4603`). The SD slot then runs default/high speed to 50 MHz —
correct, safe, and one word of DT. This is exactly what the vendor already does
for the SDIO node (V `AX630C_…_nanokvm.dts:379`). SD is `opt` in the port
inventory; UHS on it is a later, separable piece of work.

If UHS on SD is wanted later, the clean mainline shape is a small
`.voltage_switch` in a `sdhci_cdns_drv_data.init` hook reaching G9's MISC0 through
`syscon_regmap_lookup_by_phandle()` on the #80 pinctrl/syscon node — **not** a
private `ioremap`, which would collide with pinctrl's `request_mem_region`.

### 6.7 The eMMC boot-strap downgrade

If the chip-mode strap at `0x0239000C` bits `[3:1]` reads `0x6` or `0x4` (the
"4-bit 25 MHz" eMMC boot modes), the vendor clears `MMC_CAP_8_BIT_DATA` and both
HS400 caps, overriding the DT. V: `sdhci-axera.c:75-80, 925-939, 1045`. On a board
strapped for 8-bit this is a no-op. Our board's DT declares `bus-width = <8>` and
HS400-ES and the device runs at those settings, so (I) the strap is not one of
those two values — but §9 lists the one-word read that proves it.

### 6.8 Power-management-only differences

The SD instance loses `MMC_CAP_AGGRESSIVE_PM` and gains `MMC_PM_KEEP_POWER`; the
eMMC instance gains `SDHCI_QUIRK2_HOST_OFF_CARD_ON` when its `pm_caps` already
request keep-power (V `sdhci-axera.c:1003-1011`). Nothing on this appliance
suspends. **(d).**

### 6.9 The one quirk mainline needs told

Both Cadence users that resemble ours carry `SDHCI_QUIRK2_PRESET_VALUE_BROKEN`
(V `cdns-713.c:482-501`, `socionext,uniphier-sd4hc` and `mobileye,eyeq-sd4hc`);
the bare `cdns,sd4hc` entry carries no quirks (V `cdns-713.c:503-507, 656`). **The
vendor driver selects the quirk for `axera,sdhc`** — its match data is
`sdhci_cdns_uniphier_pltfm_data`, whose only content is that quirk (V
`sdhci-axera.c:594-597, 1185-1191`). So on this silicon the SDHCI preset-value
registers are believed broken, and a DT that matches only `cdns,sd4hc` would let
`sdhci_set_ios()` take the clock divider and driver strength from
`SDHCI_PRESET_FOR_*` (`0x64`–`0x74`) instead of computing them
(V `sdhci-713.c:1872-1913, 2336-2339`). That is the **one** thing #76 cannot
express in DT. §7 has the ~15-line fix.

---

## 7. The delta, itemised, with a line budget

### 7.1 The rows

Category key: **(a)** mainline has it under another name/mechanism; **(b)**
absorbed by the mainline sdhci/mmc core since 4.19; **(c)** Axera-only *and*
needed on this board; **(d)** Axera-only and not needed.

| # | Vendor behaviour | Registers / values | Cat | Mainline answer |
|---|---|---|---|---|
| 1 | Card-clock mux + gate + divider programmed by private `ioremap` | `cpu_clk 0x00[6:5]=3`, `0x04` bit 2, `0x0C[5:0]=1` + update bit 6; `flash_clk 0x00[17:16]=3`, `0x04` bit 9, `0x0C[25:20]=1` + bit 26 | **(c)** | DT `clocks = <&…_clk …_CARD_EB>` + the #80 clk driver (§4.3). Zero sdhci code. |
| 2 | APB/AXI gates for SD and SDIO | `flash_clk 0x08` bits 17/3 (SD), 18/4 (SDIO) | **(c)** | `CLK_IS_CRITICAL` in the #80 table (the binding allows only one `clocks` entry). |
| 3 | `pinmux` APB gate enabled to read the pad voltage detect | `flash_clk 0x08` bit 16 (id 29) | **(c)** | Missing from clk-model §5.2 — add it; needed by #80's pinctrl too. |
| 4 | SoC reset deassert `arst`,`prst`,`cardrst` at probe | `cpu 0x10` bits 12,12,11; `flash 0x14` bits 17,16,15 (SD), 20,19,18 (SDIO) | **(c)** | **Do nothing** — firmware leaves them deasserted (§5.4). And never put them in `resets`, which mainline reserves for the card RST_n (§5.3). |
| 5 | PHY DLL reset pulse before parameter writes | HRS04 addr `0x0f` ← 0 then 1 | **(c)** opt | ~2 lines in a per-compatible `init` hook; U-Boot already pulsed it (§3.3). |
| 6 | SD 1.8 V pad-voltage switch | G9 MISC0 `0x104F1004/8` bits `[8:7]`; detect `0x104F1058` bit 0 | **(c)** SD-only | First boot: `no-1-8-v` on the SD node (§6.6). Later: `.voltage_switch` over the pinctrl syscon. |
| 7 | `mmc->ocr_avail` forced to 3.3–1.8 V before `add_host` | — | **(c)** | Drop the `0x03200000` half of `sdhci-caps-mask`, or add `vmmc-supply` (§6.1). |
| 8 | `HRS06` mode `0x1` (MMC_LEGACY) for eMMC legacy timing | HRS06 `[2:0]` | **(c)** cond | Mainline writes `0x0`. Upstream-proven elsewhere; risk 3 in §8. |
| 9 | eMMC 4-bit boot-strap downgrade | `0x0239000C[3:1] ∈ {4,6}` → drop 8-bit + HS400 | **(c)** cond | No-op on this board (§6.7); a device read settles it. |
| 10 | eMMC card RST_n GPIO + pulse | GPIO2_A23 active low, 10 µs low, 300 µs settle | **(a)** | `reset-gpios` + `CONFIG_RESET_GPIO` → `card_hw_reset` (§5.5). Zero code. |
| 11 | Suspend/resume clock disable/enable + PHY re-init | — | **(a)** | `sdhci_pltfm_suspend` / `sdhci_cdns_resume` (V `cdns-713.c:614-641`). |
| 12 | `sdhci-caps-mask` parsing | CAPS `0x40` / CAPS1 `0x44` | **(b)** | Core, `__sdhci_read_caps()` (V `sdhci-713.c:4161-4186`). |
| 13 | `cap-mmc-hw-reset`, `fixed-emmc-driver-type`, `broken-cd`, `no-*`, `max-frequency`, `no-1-8-v` | — | **(b)** | `mmc_of_parse()` + `sdhci_get_of_property()` (§6.2, §6.3, §6.6). |
| 14 | HS400-ES mode switching | HRS06 `0x5`↔`0x6` | **(b)** | Identical code already in `cdns-713.c:509-527`. |
| 15 | `HRS04` leading/trailing ACK polls | — | **(b)** | Upstream added the same two polls (§3.1). |
| 16 | PHY read + `0x09` lock-status print | HRS04 RD path | **(d)** | Useful as a `dev_dbg`; nothing depends on it. |
| 17 | SDIO 1.8 V switch + `vol-sw-gpio` | G12 `0x104F2004/8/58` | **(d)** | Our SDIO node is `no-1-8-v` already. |
| 18 | `sdio_host` global + `axera_sdio_rescan()` `EXPORT_SYMBOL_GPL` | — | **(d)** | An aic8800 hook. Revisit under the Wi-Fi issue, not #76. |
| 19 | `USING_CLK_FRAME` CCF path | clocks named `aclk`/`pclk`/`cardclk` | **(d)** | Never compiled. Its *names* are the only useful thing: they confirm the three-domain model of §4.1. |
| 20 | `SUPPORT_CLK_AUTOGATE` runtime-PM path | — | **(d)** | Never compiled. |
| 21 | SD `MMC_CAP_AGGRESSIVE_PM` clear / `KEEP_POWER` / `HOST_OFF_CARD_ON` | — | **(d)** | Nothing suspends (§6.8). |
| — | *(mainline-only, no vendor counterpart)* multi-block read-gap tuning | HRS37 `0x94`, HRS38 `0x98` | — | New on this silicon; risk 4 in §8. |
| — | *(mainline-only)* preset-value quirk selection by compatible | — | **needs code** | §6.9 — the one glue item. |

### 7.2 Line budget — all 1208 lines accounted for

Assigned by contiguous region, so the column sums to exactly 1208.

| Lines | Region | Cat | Size |
|---|---|---|---|
| 1–26 | header, includes, `ASSERT`/`DEASSERT` | shared/boiler | 26 |
| 27–72 | HRS + PHY defines (43 identical to upstream; `PHY_LOCK_VALUE`, `PHY_DLL_RESET`, `MODE_MMC_LEGACY` are the 3 additions) | shared 43 / (c) 2 / (d) 1 | 46 |
| 73–141 | Axera clock/reset/pinmux/strap/base-address defines | (c) 55 / (d) 14 | 69 |
| 142–184 | structs + the 11-entry `cdns,phy-*` table | shared | 43 |
| 185–216 | `write_phy_reg` | shared | 32 |
| 217–249 | `read_phy_reg` + lock print | (d) | 33 |
| 250–280 | phy param count + parse | shared | 31 |
| 281–300 | `phy_init` (6 lines = the DLL pulse and its comment) | shared 14 / (c) 6 | 20 |
| 301–335 | priv accessor, timeout clock, get/set eMMC mode | shared | 35 |
| 336–409 | `set_tune_val` + `execute_tuning` | shared | 74 |
| 410–453 | `set_uhs_signaling` + UHS helper | (c) | 44 |
| 454–540 | `voltage_switch` (SD half 42, SDIO half 45) | (c) 42 / (d) 45 | 87 |
| 541–582 | hw-reset GPIO acquire + pulse | (a) | 42 |
| 583–622 | ops tables, pltfm data, HS400-ES | shared | 40 |
| 623–665 | reset acquire + assert/deassert | (c) | 43 |
| 666–688 | `USING_CLK_FRAME` `axera_get_clk` | (d) | 23 |
| 689–763 | `ax_set_mmc_clk` | (c) | 75 |
| 764–822 | `set_mmc_div` | (c) | 59 |
| 823–924 | `axera_prepare_clk` (47 of it the dead `#ifdef` half) | (c) 55 / (d) 47 | 102 |
| 925–940 | `emmc_is_set_4bit` | (c) | 16 |
| 941–955 | `sdio_host` + `axera_sdio_rescan` | (d) | 15 |
| 956–1100 | `probe` | shared 85 / (c) 45 / (d) 15 | 145 |
| 1101–1184 | PM ops (40 of it the dead autogate half) | (a) 44 / (d) 40 | 84 |
| 1185–1208 | match table, driver, module macros | shared | 24 |
| | **Total** | | **1208** |

| Category | Lines | Share |
|---|---|---|
| Identical to upstream `sdhci-cadence` | **480** | 40 % |
| (a) mainline has it another way | **86** | 7 % |
| (b) absorbed by core | **0** | — |
| (c) Axera-only and needed | **409** | 34 % |
| (d) Axera-only and not needed | **233** | 19 % |

**No unexplained residual.** And the shape of the answer is the finding:
**category (b) is empty.** Nothing in this driver was overtaken by core evolution —
the vendor forked `sdhci-cadence.c` in 2019, when it was already only 460 lines,
and every line they added is SoC integration or dead code. The 409 lines of (c)
are almost entirely clock and reset poking (277 of them) that mainline moves into
DT plus the #80 clock driver, and none of it belongs in an mmc driver.

For symmetry: of mainline's 675 lines, ~480 are shared with the vendor and the
~195 the vendor does not have are the Pensando Elba byte-lane glue (~85), the
multi-block read-gap tuning (~30), the `drv_data` indirection and four extra
compatibles (~40), the reset-controller `card_hw_reset` (~20) and modernised
PM/probe boilerplate (~20).

---

## 8. Minimum viable #76 plan

### 8.1 Verdict

**Stock `sdhci-cadence` with the right DT, plus a ~15-line match-table entry.**
Nothing else is required for eMMC — the boot device, the rootfs, and the only
storage that gates a first mainline boot.

### 8.2 The one piece of code

Add a compatible whose match data carries the preset quirk the vendor selects
(§6.9), and hang the optional DLL pulse (§3.3) off the same entry. In
`[M]/drivers/mmc/host/sdhci-cadence.c`:

* a new `static int ax630c_drv_init(struct platform_device *pdev)` that writes PHY
  address `0x0f` with 0 and then 1 through the existing `sdhci_cdns_write_phy_reg()`
  — note it must run *before* `sdhci_cdns_phy_init()`, and mainline calls
  `data->init` at `cdns-713.c:582-586`, which is before the phy init at `:598`, so
  the hook slot is already in the right place;
* a `static const struct sdhci_cdns_drv_data sdhci_cdns_ax630c_drv_data` with
  `.init = ax630c_drv_init` and `.pltfm_data = { .ops = &sdhci_cdns_ops, .quirks2 =
  SDHCI_QUIRK2_PRESET_VALUE_BROKEN }`;
* a match entry `{ .compatible = "axera,ax630c-sd4hc", .data = &sdhci_cdns_ax630c_drv_data }`;
* one enum line in `cdns,sdhci.yaml`.

That is upstreamable as-is and is a smaller patch than any of the three vendor
integrations already in that file.

**Stopgap if you want zero patch for the very first boot:** compatible
`"cdns,sd4hc"` alone plus `sdhci.debug_quirks2=0x8` on the kernel cmdline
(`SDHCI_QUIRK2_PRESET_VALUE_BROKEN` = `1<<3`, V `sdhci-713.h:499`;
`debug_quirks2` is applied in `__sdhci_read_caps()`, V `sdhci-713.c:4153-4154`).
It is global to every sdhci instance, which on this SoC is fine — all three are
the same IP.

### 8.3 The DT

Add to `dts/ax630c-compat.h`:

```c
/*
 * SD/eMMC host. The IP is a stock Cadence SD4HC (HRS at +0, SDHCI SRS at
 * +0x200, HRS04 PHY port, HRS06 eMMC mode/tune) -- so the second compatible
 * is the real upstream one and the driver is mainline sdhci-cadence. The
 * vendor-specific first entry exists only to select
 * SDHCI_QUIRK2_PRESET_VALUE_BROKEN, which the vendor driver also selects.
 */
#define AX630C_SDHCI_COMPAT		"axera,ax630c-sd4hc"
```

`dts/ax630c.dtsi`, in `soc`:

```dts
		/*
		 * eMMC (#76). Boot device and rootfs: mmcblk0, and U-Boot has
		 * already read the kernel through this controller before Linux
		 * starts, which is why none of the three SoC resets
		 * (prst/arst/cardrst, cpu syscon 0x10 bits 12/12/11) appear
		 * here -- firmware leaves them deasserted and mainline
		 * sdhci-cadence reserves `resets` for the card's RST_n line.
		 *
		 * That RST_n is a GPIO, not a reset controller. The reset core
		 * falls back to `reset-gpios` when `resets` is absent and
		 * synthesises a reset-gpio controller over it, which is what
		 * gives us card_hw_reset with no glue -- needs
		 * CONFIG_RESET_GPIO=y and #gpio-cells = <2> on the GPIO
		 * controller (#81).
		 *
		 * One clock only: the binding allows one and the driver takes
		 * index 0 unnamed. The controller's own bus gate
		 * (AX630C_CLK_EMMC_EB) cannot be named here and is
		 * CLK_IS_CRITICAL in the clock driver instead.
		 *
		 * No sdhci-caps-mask. The vendor's value masked off
		 * CAN_VDD_330|CAN_VDD_300, which is only survivable because the
		 * vendor driver then force-assigns mmc->ocr_avail; stock
		 * sdhci-cadence does not, and the masked value makes
		 * sdhci_setup_host() abort with "doesn't report any support
		 * voltages". The rest of the mask was redundant with the
		 * cap-*/sd-uhs-* properties.
		 *
		 * cdns,phy-input-delay-mmc-legacy is deliberately absent: PHY
		 * address 0x06 has no entry in the driver's property table --
		 * in the vendor driver either -- so the vendor DT's value has
		 * never been applied, and the upstream schema is
		 * unevaluatedProperties:false.
		 */
		emmc: mmc@1b40000 {
			compatible = AX630C_SDHCI_COMPAT, "cdns,sd4hc";
			reg = <0x0 0x01b40000 0x0 0x10000>;
			interrupts = <GIC_SPI 9 IRQ_TYPE_LEVEL_HIGH>;
			clocks = <&cpu_clk AX630C_CLK_EMMC_CARD_EB>;
			max-frequency = <200000000>;
			bus-width = <8>;
			non-removable;
			no-sd;
			no-sdio;
			disable-wp;
			cap-mmc-highspeed;
			mmc-hs200-1_8v;
			mmc-hs400-1_8v;
			mmc-hs400-enhanced-strobe;
			fixed-emmc-driver-type = <4>;
			cap-mmc-hw-reset;
			reset-gpios = <&gpio2 23 GPIO_ACTIVE_LOW>;
			cdns,phy-input-delay-sd-highspeed = <2>;
			cdns,phy-input-delay-legacy = <4>;
			cdns,phy-input-delay-sd-uhs-sdr12 = <1>;
			cdns,phy-input-delay-sd-uhs-sdr25 = <2>;
			cdns,phy-input-delay-sd-uhs-sdr50 = <1>;
			cdns,phy-input-delay-sd-uhs-ddr50 = <2>;
			cdns,phy-input-delay-mmc-highspeed = <2>;
			cdns,phy-input-delay-mmc-ddr = <2>;
			cdns,phy-dll-delay-sdclk = <45>;
			cdns,phy-dll-delay-sdclk-hsmmc = <31>;
			cdns,phy-dll-delay-strobe = <18>;
			status = "okay";
		};

		/*
		 * SD card (#76). Not on the boot path -- this is the test-image
		 * slot. no-1-8-v is the deliberate choice: UHS on this board
		 * needs the pad I/O-voltage domain switched in pin-group G9's
		 * MISC0 word (bits [8:7] at 0x104F1004/8, gated by the pinmux
		 * APB clock, with a rail-detect read at 0x104F1058), which the
		 * mainline vqmmc-regulator model cannot express and which no
		 * upstream code does. Without the switch a card that negotiates
		 * 1.8 V signalling talks to 3.3 V pads. With no-1-8-v the slot
		 * runs default/high speed to 50 MHz, correctly. Revisit as a
		 * .voltage_switch over the pinctrl syscon when SD speed matters.
		 */
		sd: mmc@104e0000 {
			compatible = AX630C_SDHCI_COMPAT, "cdns,sd4hc";
			reg = <0x0 0x104e0000 0x0 0x10000>;
			interrupts = <GIC_SPI 74 IRQ_TYPE_LEVEL_HIGH>;
			clocks = <&flash_clk AX630C_CLK_SD_CARD_EB>;
			max-frequency = <200000000>;
			bus-width = <4>;
			no-mmc;
			no-sdio;
			no-1-8-v;
			disable-wp;
			broken-cd;
			cap-sd-highspeed;
			cdns,phy-input-delay-sd-highspeed = <2>;
			cdns,phy-input-delay-legacy = <3>;
			cdns,phy-input-delay-sd-uhs-sdr12 = <3>;
			cdns,phy-input-delay-sd-uhs-sdr25 = <2>;
			cdns,phy-input-delay-sd-uhs-sdr50 = <1>;
			cdns,phy-input-delay-sd-uhs-ddr50 = <1>;
			cdns,phy-dll-delay-sdclk = <0>;
			status = "okay";
		};
```

SDIO gets the same shape (`0x104d0000`, `GIC_SPI 73`,
`AX630C_CLK_SDIO_M_CARD_EB`, `no-sd`, `no-mmc`, `no-1-8-v`, the six SD delays and
`cdns,phy-dll-delay-sdclk = <0>`) whenever the Wi-Fi issue starts; leave it
`disabled` for #76 so a first boot has one fewer thing to go wrong.

### 8.4 Ordering and dependencies

1. #80 clock driver must register `AX630C_CLK_EMMC_CARD_EB` **before** the first
   boot with an `mmc@` node, or the probe fails on `devm_clk_get_enabled`. There
   is no `clock-frequency` escape hatch here the way there is for the UART.
2. #81 GPIO driver, `#gpio-cells = <2>`, plus `CONFIG_RESET_GPIO=y`, for the eMMC
   RST_n. Not fatal if missing — the optional get returns NULL and the board keeps
   working without a card hardware reset.
3. Kconfig: `CONFIG_MMC=y`, `CONFIG_MMC_BLOCK=y`, `CONFIG_MMC_SDHCI=y`,
   `CONFIG_MMC_SDHCI_PLTFM=y`, `CONFIG_MMC_SDHCI_CADENCE=y`, `CONFIG_RESET_GPIO=y`.
   All **built in**, not modules — this is the rootfs device.
4. `root=/dev/mmcblk0p17` already in the mainline cmdline. Instance ordering is not
   guaranteed by probe order; if the vendor's `mmc0`=eMMC ordering does not hold,
   switch to `root=PARTUUID=` or an `aliases { mmc0 = &emmc; mmc1 = &sd; }` block.

---

## 9. Risks for a serial-less first boot

This board has no console. The evidence channels are the milestone nibble in
`0x02390024[15:12]`, ramoops at `0x480e0000`, and the initramfs kernel-log stash
at `0x480e8000` (`docs/mainline-port.md` §8). A driver that hangs in probe and a
watchdog reset look identical unless the failure mode was predicted. Ranked by
likelihood.

| # | Failure | Where | Signature you will actually see | Pre-empt |
|---|---|---|---|---|
| 1 | No `clocks` property, or the #80 driver has not registered id 5 | `devm_clk_get_enabled` at `cdns-713.c:557` | Probe returns `-ENOENT`/`-EPROBE_DEFER` **before** the controller is touched. No hang. `mmc0` never appears; rootfs mount fails; `Kernel panic - not syncing: VFS: Unable to mount root fs`. Ramoops **will** contain it. | Grep the built dtb for `clocks` on the mmc node in CI. Set the milestone nibble from a late-initcall so "reached userspace" is distinguishable from "panicked at mount". |
| 2 | ~~`sdhci-caps-mask` carried over from the vendor DT~~ **VOID** (V, §10 read 1) | `sdhci_setup_host` OCR block, `sdhci-713.c:4731` | None. `CAPS0 = 0x176AC8B2` sets `CAN_VDD_180`, which the mask does not clear, so `ocr_avail` is non-zero and probe succeeds. | Still omit the property — but as tidiness (§6.1), not risk. |
| 3 | eMMC does not enumerate because `HRS06` mode is `0` not `1` during 400 kHz identification | `sdhci_cdns_set_uhs_signaling`, `cdns-713.c:376-379` | `mmc0: error -110 whilst initialising MMC card` repeated, then no `mmcblk0`. A **timeout loop**, not a hang: each attempt is bounded and the panic at mount still arrives. | If it happens, add `MMC_TIMING_LEGACY → 0x1` in the drv_data variant (§6.5). |
| 4 | `HRS37`/`HRS38` unimplemented, so read-gap tuning cannot find a gap | `sdhci_cdns_tune_blkgap`, `cdns-713.c:298-303` | 16 multi-block reads then `execute_tuning` fails → HS200 rejected → the card retries at HS/DDR52. **Degrades, does not hang.** Visible as a slow rootfs and `mmc0: tuning execution failed`. Worst case the retry storm delays boot past the 30 s U-Boot watchdog → indistinguishable from a crash. | Boot the first mainline kernel with the eMMC pinned below HS200 (`max-frequency = <50000000>`, drop `mmc-hs200-1_8v`/`mmc-hs400-*`), then raise it on the second attempt. This is the single highest-value de-risking step and costs one DT line. |
| 5 | `resets` populated with `prst`/`arst`/`cardrst` | `cdns-713.c:603` binds index 0 as `rst_hw` | Boots fine, then the first `mmc_hw_reset()` (an error-recovery path) asserts the controller's APB reset. **Wedges under I/O error, days later.** The nastiest one because it passes a first boot. | Never put them there (§5.3). Assert it in review, not on hardware. |
| 6 | `CONFIG_RESET_GPIO=n` | reset core fallback, `reset-core-713.c:1167` | Silent. No card hardware reset; everything else works until an eMMC needs one. | Kconfig assertion. |
| 7 | SD (or SDIO) held in reset, or its APB/AXI gate off | CAPS reads 0 | `"mmc1: Hardware doesn't specify base clock frequency."`, `-ENODEV`. Contained — eMMC is unaffected, the board still boots. | Leave SDIO `disabled` for the first boot; SD failing is survivable. §10 read 3. |
| 8 | Preset values applied (no quirk) | `sdhci_set_ios` preset path | Wrong SDCLK divider and driver strength in UHS/HS200/HS400. Data corruption or CRC storms, **after** a successful mount. | §8.2 — get the quirk in before the first boot. |
| 9 | `request_mem_region` collision if a future SD voltage-switch glue `ioremap`s `0x104f1000` | — | Pinctrl or mmc probe fails with `-EBUSY`. | Use `syscon_regmap_lookup_by_phandle`, never a private map (§6.6) — the same rule the wdt node comment already states. |

**The general shape of the good news:** every one of these is a *bounded failure*,
not a hang. `sdhci-cadence` has no unbounded loop in its probe path — the PHY
polls are `readl_poll_timeout` with a 10 µs budget (V `cdns-713.c:134, 146, 153`)
and the tuning loops are counted. So the expected worst case is "kernel panics at
rootfs mount", which ramoops captures, rather than "silence, then a watchdog
reboot". That is a materially safer first boot than #75's was.

---

## 10. Open questions needing a device read

**Reads 1, 2, 4 and 5 were taken on 2026-09-06** from the running vendor system
(`devmem`, read-only, vendor 4.19.125 with eMMC mounted and no SD card present).
Results are inlined below; §10.0 collects them. Reads 3, 6, 7 and 8 are still open.

One trap for whoever repeats this: the SDHCI register block is **not** at the
window base. Cadence SD4HC puts its own HRS region there and the SDHCI-compatible
SRS block starts at `+0x200` (V `cdns-713.c:58,579`), so CAPS is at `+0x240`, not
`+0x40`. Reading `+0x40` returns `0x00000000` on all three instances and looks
exactly like "the controller is dead".

### 10.0 Results

| Register | Value | What it settles |
|---|---|---|
| eMMC/SD/SDIO `CAPS0` `+0x240` | `0x176AC8B2` (all three identical) | Base clock `[15:8]` = `0xC8` = **200 MHz**, so no `.get_max_clock` is needed. `CAN_VDD_330`+`CAN_VDD_300`+`CAN_VDD_180` all set → §6.1's mask is **not** fatal. `CAN_DO_HISPD` set. |
| eMMC/SD/SDIO `CAPS1` `+0x244` | `0x10000077` | UHS SDR50/SDR104/DDR50 present; the vendor's caps1 masking was cosmetic. |
| eMMC presets `0x01B40260`–`0x01B4027C` | `0x000400FA 0x00040002 0x00010002 0x00020000 0` ×4 | **Negative result.** The presets are populated and structured, not blank. This does *not* corroborate `PRESET_VALUE_BROKEN` from silicon — the quirk rests on the vendor's match-data choice alone (§6.9). Keep it (their driver ships and works), but do not claim the register read confirmed it. |
| `cpu` `SW_RST0` `0x01900010` | `0x00000000` | eMMC bits 11/12 read **0** while eMMC is working → `1` = held in reset, `0` = released. |
| `flash` `SW_RST` `0x10030014` | `0x3C0002E0` | SD bits 15–17 and SDIO 18–20 all **0** (released); bits 5,6,7,9,26–29 are set, i.e. unused blocks *are* parked in reset — the register really does mean "1 = in reset". |
| `cpu` `MUX0` `0x01900000` | `0x00000073` | `[6:5]` = **3** = `npll_400m` ✓ clk-model §5.2. |
| `cpu` `EB0` `0x01900004` | `0x0000000F` | bit 2 `CLK_EMMC_CARD_EB` **set** ✓. |
| `cpu` `EB1` `0x01900008` | `0x000001BC` | bit 4 **set** — corroborates clk-model §5.2's one **(I)** row, `CLK_EMMC_EB`. Corroboration only: a set bit is consistent with the mapping, it does not prove it. |
| `cpu` `DIV0` `0x0190000C` | `0x00000001` | `[5:0]` = 1 → ÷2 → 400 ÷ 2 = **200 MHz**, matching CAPS base clock and the vendor's `set emmc clk to 200M`. |
| `flash` `MUX0` `0x10030000` | `0x003F0B60` | `[17:16]` = 3 (`SD_CARD_SEL`) and `[19:18]` = 3 (`SDIO_M_CARD_SEL`), both `npll_400m` ✓. |
| `flash` `EB0` `0x10030004` | `0x00007E6C` | bits 9 (`SD_CARD_EB`) and 10 (`SDIO_M_CARD_EB`) set ✓. |
| `flash` `EB1` `0x10030008` | `0x000FF43F` | bits 3/4 (AXI), 17/18 (APB) and **16** (`PCLK_PINMUX_EB`, the id-29 row this doc adds to clk-model §5.2) all set ✓. |
| `flash` `DIV` `0x1003000C` / `0x10030010` | `0x00100000` / `0x00000001` | `[25:20]` = 1 and `[5:0]` = 1 → both ÷2 → 200 MHz ✓. |

**Every register position in clk-model §5.2 is now confirmed against silicon**,
including its single **(I)** row, plus the `PCLK_PINMUX_EB` addition.

**What the reset reads do _not_ settle**, and §5.4's caution stands: the vendor
kernel driver deasserts all six lines at its own probe, so `0` at runtime is the
*driver's* doing and says nothing about the power-on default. The decisive
experiment is still the first mainline boot.

### 10.1 Still open

Ordered by decision value.

1. **The CAPS registers of all three instances.** **DONE 2026-09-06 — see §10.0.** `0x01B40240` and `0x01B40244`
   (eMMC CAPS/CAPS1), `0x104E0240`/`0x104E0244` (SD), `0x104D0240`/`0x104D0244`
   (SDIO) — SRS base `+0x200` plus SDHCI `0x40`/`0x44`.
   Settles: the base-clock field (`CAPS[15:8]`, expected 200 — if it reads 0, an
   `.get_max_clock` is mandatory and risk #1's signature changes); whether
   `CAN_VDD_180` (bit 26) is set, which decides whether §6.1's mask would really
   have been fatal; whether `CAN_DO_8BIT`, `CAN_DO_ADMA2` and `CAN_64BIT_V4` are
   set; and the caps1 UHS/driver-type/retuning fields, which tell us how much of
   the vendor's masking was ever meaningful.
2. **The preset registers.** **DONE 2026-09-06 — see §10.0; the result was negative.** `0x01B40264`–`0x01B40276` (16-bit reads, or one
   `dd` of `0x01B40260..0x01B40280`).
   Settles §6.9 empirically: if they read all-zero or all-ones, `PRESET_VALUE_BROKEN`
   is confirmed from silicon rather than from the vendor's choice of match data.
3. **The two `SW_RST0` words.** `0x01900010` (eMMC bits 11,12) and `0x10030014`
   (SD bits 15–17, SDIO 18–20).
   Settles §5.4 *partially* — and this is worth being honest about: the vendor
   driver has already deasserted all six by the time userspace runs, so a read now
   proves only which polarity means "running". It cannot prove the power-on
   default. The bits to actually watch are the SDIO ones **if** the SDIO node were
   disabled, which it is not. **The decisive experiment is the first mainline
   boot itself**, where SD failing to probe with "doesn't specify base clock" is
   the positive result for "SD needed its resets".
4. **`flash_clk` `CLK_EB0`/`CLK_EB1`.** **DONE 2026-09-06 — see §10.0.** `0x10030004` and `0x10030008`.
   Settles: whether bits 9/10 (SD/SDIO card gates), 17/18 (APB), 3/4 (AXI) and 16
   (pinmux APB) are set right now, which is the ground truth for which gates #80
   must mark `CLK_IS_CRITICAL` and which are merely nice to have.
5. **`cpu_clk` `CLK_MUX0`/`CLK_EB0`/`CLK_EB1`/`CLK_DIV0`.** **DONE 2026-09-06 — see §10.0.** `0x01900000`,
   `0x01900004`, `0x01900008`, `0x0190000C`.
   Settles: that `[6:5]` really reads 3 (`npll_400m`), that `DIV0[5:0]` reads 1,
   and — the one genuinely unverified bit in clk-model §5.2 — whether bit 4 of
   `0x08` (`CLK_EMMC_EB`, marked **I** there) is set. If the whole word is
   otherwise sparse, a set bit 4 is good corroboration.
6. **The chip-mode strap.** `0x0239000C`, bits `[3:1]`.
   Settles §6.7: if it is not `4` or `6`, the vendor's 8-bit/HS400 downgrade is
   dead code on this board and #76 can ignore it permanently. (Note this is the
   same 64 KiB syscon page as the A/B slot register at `0x02390024`, so read it
   with the same care.)
7. **`HRS37`/`HRS38` existence.** Read `0x01B40094` and `0x01B40098`.
   Settles risk 4. If both read `0x00000000` **and** a write is impossible to test
   safely read-only, the read alone is still informative: an unimplemented
   Cadence HRS slot in this IP typically reads back as zero, whereas `HRS37`'s
   reset value on an implemented block would be a mode code. Weak evidence either
   way (**I**) — the real mitigation is risk 4's "boot slow first".
8. **PHY lock.** There is no `/sys` path for this. The only read is the HRS04
   read protocol of §3.1 against address `0x09`, which requires *writes* to
   `0x01B40010` and is therefore out of scope for a read-only capture. The vendor
   driver already prints the answer at every boot: **`dmesg | grep "phy lock"`**
   on the running system is the free version of this read, and should be captured
   for all three instances before any mainline excursion.

**Not answerable by any device read, and worth stating so:** whether the AX630C's
SD4HC is configured with the same tuning-value wrap-around the upstream comment
worries about (0–42 usable, 40 used for safety). Both drivers use 40; leave it.

---

## 11. Corrections to other docs

* **`docs/mainline-port.md` §2, eMMC row** says "`hw-reset = <&gpio>` is not a
  mainline binding (drop or `reset-gpios`)" and "+ the three resets". The first
  half is right and §5.5 above makes it concrete; **the second half is wrong** —
  the three SoC resets must *not* be put in `resets`, because mainline
  `sdhci-cadence` binds index 0 as the card RST_n. (`reset-model-20260906.md` §9
  reaches this independently.) It also says "diff 1208 vs ~460
  LOC for Axera-only tuning": the diff is not tuning at all (tuning is
  byte-identical), it is clock/reset integration plus dead code — §7.2.
* **`clk-model-20260906.md` §5.2** should gain `AX620X_PCLK_PINMUX_EB` (flash id
  **29**, `0x08` bit **16**) to its SD/SDIO table, with the note that the pinctrl
  driver of #80 needs it too. §4.4 above.
* **`pinctrl-model-20260906.md` §1.5** is confirmed, not corrected: its reading of
  MISC0 `[8:7]` as the group I/O-voltage select and `+0x58` as the 1.8 V detect is
  exactly what §6.6 re-derives, and the `PCLK_PINMUX_EB` requirement is a new fact
  that belongs alongside it.
