# AX630C GPIO — bare `/dev/mem` model for the heartbeat LED

Issue #75 (the first mainline hardware step). Written 2026-09-06 from the GPL-2.0
vendor 4.19 sources, the SDK's U-Boot, the board pad table, and a read-only
capture of the running device. It exists so a freestanding initramfs `init` with
**nothing but `/dev/mem`** — no gpiolib, no pinctrl, no clock driver — can blink
the board's heartbeat LED as a "userspace was reached" beacon.

**Sources.** `[K]` = `/nix/store/gzmk3ygvw8n2vgi230fplbv5295nf42q-source/linux/linux-4.19.125`
(vendor kernel). `[S]` = `/nix/store/k7b551m83qh9dpxdkvgjgjjc3w2rhknn-source`
(Sipeed `maix_ax620e_sdk`). `[D]` =
`docs/reference/mainline/device-reads-20260906/`. Short names:
`gpio-axera.c` = `[K]/drivers/gpio/gpio-axera.c`; `axera_reset.c` =
`[K]/drivers/reset/axera_reset/axera_reset.c`; `AX620E.dtsi`,
`AX620E_resets.dtsi`, `AX620E_pinctrl.dtsi`, `AX630C_emmc_arm64_k419_sipeed_nanokvm.dts`
= `[K]/arch/arm64/boot/dts/axera/`; **DEMO table** =
`[S]/build/projects/AX630C_emmc_arm64_k419_sipeed_nanokvm/pinmux/AX630C_DEMO_pinmux.h`;
`uboot-gpio.c` = `[S]/boot/uboot/u-boot-2020.04/drivers/gpio/axera_gpio.c`.
Companion specs: `pinctrl-model-20260906.md`, `clk-model-20260906.md`.

**Evidence marking.** Every fact is **V** (read out of a cited source or device
dump) or **I** (inferred, reasoning stated). Unresolved items are **GAP**.

---

## 0. The answer in four lines

```
0x04800060   read-modify-write   |= 0x3          LED on   (DDR=1 output, DR=1 high)
0x04800060   read-modify-write   |= 0x2, &= ~0x1 LED off  (DDR=1 output, DR=0 low)
```

Nothing else is required on a board that booted through this SoC's U-Boot: the
pad is already muxed to GPIO (§5), and the GPIO0 block is already clocked and out
of reset (§4). The optional belt-and-braces preamble is five single-bit writes,
listed in §6.2.

---

## 1. The heartbeat LED

### 1.1 The device-tree node, verbatim as a table

`AX630C_emmc_arm64_k419_sipeed_nanokvm.dts`, node `leds` / `led-heartbeat` (**V**):

| Node | Property | Value | Meaning |
|---|---|---|---|
| `leds` | `compatible` | `"gpio-leds"` | standard `leds-gpio` binding |
| `leds` | `status` | `"okay"` | |
| `leds` | `pinctrl-names` | `"default"` | |
| `leds` | `pinctrl-0` | `<&sd_pwr_en_gpio0_a23_pins>` | mux the `SD_PWR_EN` pad to `GPIO0_A23` (§5) |
| `led-heartbeat` | `label` | `"sys-heartbeat"` | → `/sys/class/leds/sys-heartbeat` |
| `led-heartbeat` | `gpios` | `<&ax_gpio0 23 0>` | controller `ax_gpio0`, line **23**, flags **0** |
| `led-heartbeat` | `linux,default-trigger` | `"heartbeat"` | kernel heartbeat blink at boot |
| `led-heartbeat` | `status` | `"okay"` | |

* Flags cell `0` = `GPIO_ACTIVE_HIGH`, so **the LED is active-high**: line driven
  high = lit (**V**, the DT cell; the polarity of the physical circuit is **I** —
  no schematic — but everything in software treats high as on).
* `ax_gpio0` is `gpio@4800000` (**V**, `AX620E.dtsi:233`). So the line is
  **GPIO0_A23**, global gpiolib number **23** on the vendor kernel.
* Live confirmation (**V**, `[D]/gpio.txt`): `gpio-23 ( |sys-heartbeat ) out lo`
  on `gpiochip0` / `4800000.gpio`.

### 1.2 One aliasing trap

The same line is also named as `reset-gpio = <&ax_gpio0 23 0>` by the `panel_dsi`
node with the same `pinctrl-0` (**V**, board dts). `panel_dsi` is
`status = "disabled"` on this board, so there is no conflict — but do not be
surprised to find GPIO0_A23 described as a panel reset elsewhere in the tree.

---

## 2. Controllers and line numbering

Four identical controllers, all `compatible = "axera,ax-apb-gpio"`, each a
`0x400` window with 32 lines (**V**, `AX620E.dtsi:233-327`; corroborated live by
`[D]/iomem.txt` and `[D]/gpio.txt`).

| DT node | Physical base | `ax,ngpios` | Lines | gpiolib range (vendor 4.19) | IRQ | `ax_clk_id` |
|---|---|---|---|---|---|---|
| `ax_gpio0` | `0x0480_0000` | 32 | `GPIO0_A0` … `GPIO0_A31` | 0–31 | SPI 114 | 0 |
| `ax_gpio1` | `0x0480_1000` | 32 | `GPIO1_A0` … `GPIO1_A31` | 32–63 | SPI 115 | 1 |
| `ax_gpio2` | `0x0600_0000` | 32 | `GPIO2_A0` … `GPIO2_A31` | 64–95 | SPI 116 | 2 |
| `ax_gpio3` | `0x0600_1000` | 32 | `GPIO3_A0` … `GPIO3_A31` | 96–127 | SPI 117 | 3 |

**Name → address mapping is trivial and exact.** `GPIOc_Ax` means controller `c`,
per-controller index `x`. There is no second bank inside a controller: the driver
declares `AX_GPIO_BANK_NR 1` and `AX_GPIO_BANK_MASK GENMASK(31,0)`
(**V**, `gpio-axera.c:41-42`). The global gpiolib number is `32*c + x`, because
the driver hands out `chip.base` from a running counter in probe order
(**V**, `gpio-axera.c` `gpio_base` static) — but that numbering is a Linux
artefact and irrelevant to a `/dev/mem` poker.

Two caveats that do **not** affect the LED:

* `ax_gpio2` maps only 30 pads and `ax_gpio3` only 3 (lines 1–3) via
  `gpio-ranges`; the unmapped lines exist in the register file but reach no pad
  (**V**, `AX620E.dtsi:301-325`).
* `DB_GPIOnn` in the pinmux function lists is a **different** block — the
  low-power debounce GPIO at `0x0234_0000` (`deb_gpio_lp`, disabled on this
  board except for `db_gpio11` as a wake source) (**V**, `AX620E.dtsi:785-791`
  and the board dts). It is not one of these four controllers.

For this task: **GPIO0_A23 → controller base `0x04800000`, index 23.**

---

## 3. Register model (exhaustive)

The block is a DesignWare APB GPIO **rewired by Axera**: instead of one
`SWPORTA_DR` word with 32 line bits, there is **one 32-bit word per line**, and
every per-line control (direction, output value, interrupt setup, debounce) is a
bit field inside that line's own word.

### 3.1 Per-line word address

```
word(controller_base, n) = controller_base + (n + 1) * 4        for n = 0..31
```

**V**, `gpio-axera.c:78-81` (`base + (offset + 1) * GPIO_PORTA0_FUNC`, with
`GPIO_PORTA0_FUNC = 0x4`); identically in `uboot-gpio.c:83-118`.

The `+1` matters: line 0 is at `base+0x04`, line 31 at `base+0x80`.
`base+0x00` is **not a line** — see §3.4.

GPIO0 line words, the ones this board actually uses:

| Line | Word address | Board function (from `[D]/gpio.txt` + board dts) |
|---|---|---|
| 5 | `0x04800018` | `LT6911UXC_PWR` — HDMI receiver power, **out hi** |
| 6 | `0x0480001C` | `LT86102UXC_HDMI_PWR` — HDMI splitter power, **out hi** |
| 7 | `0x04800020` | **ATX `SW_PWR`** — host power button, out lo |
| 8 | `0x04800024` | i2c7 bit-bang recovery SCL |
| 9 | `0x04800028` | i2c7 bit-bang recovery SDA |
| 18 | `0x0480004C` | rotary encoder B |
| 21 | `0x04800058` | `LT86102UXC_HDMI_TXO` |
| 22 | `0x0480005C` | knob button (`GPIO KEY ENTER`), input + IRQ |
| **23** | **`0x04800060`** | **`sys-heartbeat` LED** |
| 24 | `0x04800064` | i2c0 recovery SCL |
| 25 | `0x04800068` | i2c0 recovery SDA |
| 27 | `0x04800070` | spi2 CS1 → mini-display |

### 3.2 Per-line word — bit fields

All ten fields are **V** from `gpio-axera.c:18-27` plus the code paths that use
them; `uboot-gpio.c:22-31` defines the identical set, an independent
confirmation. Bit 2's *name* is verified, its *behaviour* is not (see below).

| Bit | Mask | Name | Meaning | Where used |
|---|---|---|---|---|
| 0 | `0x0000_0001` | `SWPORTA_DR` | **Output data.** 1 = drive high, 0 = drive low. Only meaningful when bit 1 = 1. | `ax_gpio_set`, `ax_gpio_direction_output` |
| 1 | `0x0000_0002` | `SWPORTA_DDR` | **Direction. 1 = output (driver enabled), 0 = input.** This is the output-enable; there is no separate OE bit anywhere. | `ax_gpio_direction_input/output`, `ax_gpio_get_direction` |
| 2 | `0x0000_0004` | `SOFT_HAR_MODE` | Software/hardware source select for the output. **Never written by any vendor code path** (kernel or U-Boot) — declared and unused. Leave at whatever the reset/bootloader left. | — |
| 3 | `0x0000_0008` | `INTEN` | Interrupt enable for this line. | `ax_irq_enable/disable` |
| 4 | `0x0000_0010` | `INTMASK` | Interrupt mask (1 = masked). | `ax_gpio_irq_mask/unmask` |
| 5 | `0x0000_0020` | `INTTYPE_LEVEL` | **1 = edge-triggered, 0 = level-triggered.** (The DW name is inverted from the sense; the vendor comment `//1 is edge, 0 is vol` settles it.) | `ax_gpio_irq_set_type` |
| 6 | `0x0000_0040` | `INT_POLARITY` | 1 = active high / rising, 0 = active low / falling. | `ax_gpio_irq_set_type` |
| 7 | `0x0000_0080` | `PORTA_DEBOUNCE` | 1 = enable the debounce filter on this line. Clocked from the block's debounce clock, §4.1. | `ax_enable_debounce` |
| 8 | `0x0000_0100` | `PORTA_EOI` | **Interrupt acknowledge, not a level.** The vendor acks by writing 1 then writing 0 — i.e. it is a manual pulse, not self-clearing. | `ax_gpio_irq_ack` |
| 9 | `0x0000_0200` | `INT_BOTHEDGE` | 1 = both edges (overrides polarity). | `ax_gpio_irq_set_type` |
| 31:10 | — | reserved | No vendor code writes above bit 9 (**V**, exhaustive read of both drivers). Preserve them. (**I**: they read back as 0.) |

**Consequences for a poker:**

* Because bit 8 is a manual pulse rather than write-1-to-clear, a blind
  read-modify-write is safe — you will read back `EOI=0` and write `EOI=0`.
* Because every line has its own word, **a single 32-bit write can only ever
  affect one line.** That is the whole safety story of this block (§9).
* There is no per-line set/clear alias. The pad-mux block has `+4`/`+8`
  set/clear aliases; **the GPIO block does not** (**V** — the whole `0x00`–`0xA8`
  map below is accounted for with no aliases, and both drivers do
  read-modify-write on the value word).

### 3.3 Relocated port-level registers

The 32 per-line words consume `base+0x04` … `base+0x80`, so Axera moved the
DesignWare port registers above them. Offsets from the controller base
(**V**, `gpio-axera.c:29-38`, byte-identical in `uboot-gpio.c:33-42`):

| Offset | Address (GPIO0) | Name | Notes |
|---|---|---|---|
| `0x00` | `0x04800000` | *(secure-mode word)* | see §3.4 |
| `0x04`–`0x80` | `0x04800004`–`0x04800080` | per-line words, lines 0–31 | §3.1 |
| `0x84` | `0x04800084` | `INTSTATUS_SECURE` | masked interrupt status, secure view; one bit per line |
| `0x88` | `0x04800088` | `RAW_INTSTATUS_SECURE` | raw (pre-mask) status, secure view |
| `0x8C` | `0x0480008C` | **`EXT_PORTA`** | **input read-back, one bit per line** — bit *n* = level of line *n* |
| `0x90` | `0x04800090` | `ID_CODE` | read-only ID |
| `0x94` | `0x04800094` | `LS_SYNC` | level-sensitive IRQ sync to pclk |
| `0x98` | `0x04800098` | `VER_ID_CODE` | read-only version |
| `0x9C` | `0x0480009C` | `CONFIG_REG2` | read-only DW build config |
| `0xA0` | `0x048000A0` | `CONFIG_REG1` | read-only DW build config |
| `0xA4` | `0x048000A4` | **`INTSTATUS_NSECURE`** | masked status, non-secure view — this is the one the vendor IRQ handler reads (**V**, `ax_gpio_irq_handler`) |
| `0xA8` | `0x048000A8` | `RAW_INTSTATUS_NSECURE` | raw status, non-secure view |

`EXT_PORTA` caveat (**I**): the vendor `get()` returns `EXT_PORTA >> n & 1` only
when the line is an **input**; when `DDR = 1` it returns the `DR` bit instead
(**V**, `gpio-axera.c:145-160`, and identically `uboot-gpio.c:83-88`). Whether
`EXT_PORTA` loops back a driven output on this silicon is therefore **GAP** —
§8 uses it as a bonus check only.

### 3.4 The word at `base + 0x00`

`ax_gpio_probe()` writes `GPIO_NSECURE_MODE_VALUE = 0x0` to the controller base
before doing anything else (**V**, `gpio-axera.c`, `writel_relaxed(GPIO_NSECURE_MODE_VALUE, ax_gpio->base)`).
The constant's name is the only documentation: it selects the **non-secure**
access/interrupt view, which is consistent with there being two status register
pairs (`0x84/0x88` secure, `0xA4/0xA8` non-secure).

* **Do not touch it.** The vendor's Linux writes 0 there, and its U-Boot driver
  never writes it at all yet still drives lines successfully (**V**,
  `uboot-gpio.c` — no write to `plat->base + 0`). So the block is usable in
  whatever mode the boot chain leaves. **I**: this word gates the *interrupt
  status view*, not the register file's writability.
* **GAP**: the meaning of the other 31 bits, and whether a non-zero value would
  break plain EL1 access. If a poke ever fails to take, writing `0` here is the
  first thing to try — it is what the vendor kernel does.

---

## 4. Clocks and resets — are they needed?

### 4.1 The vendor kernel's own preamble

`ax_gpio_probe()` does three things before adding the chip (**V**,
`gpio-axera.c`):

1. **Once globally** (guarded by a `source_set_flag` static, so only the first
   controller to probe does it): `ioremap(0x4870000, 0x100)` and write
   `BIT(2)` to `+0xA8`. `0xA8` is the periph `MUX0` **write-1-to-set** alias
   (**V**, `clk-model-20260906.md` §1.3 periph alias table). The comment reads
   `clk source set, bit2, 0 32k, 1 24m` — this selects the **24 MHz** source for
   the GPIO blocks' debounce clock rather than the 32 kHz one. It affects
   debounce timing only; it is not an enable.
2. **Deassert both resets** for this controller, via the `resets` phandle.
3. **Enable the two clocks** for this controller: `writel(PCLK_BIT(id), 0x4870000 + 0xC0)`
   then `writel(CLK_BIT(id), 0x4870000 + 0xB8)`, where `CLK_BIT(x) = BIT(4 + x)`
   and `PCLK_BIT(x) = BIT(13 + x)`.

Decoded against `clk-model-20260906.md` §1.3 (**V** for the alias offsets,
**I** for the value-register offsets, which follow the documented
`MUX0=0x00, EB0=0x04, EB1=0x08, EB2=0x0C, EB3=0x10` layout):

| Purpose | Value reg | SET alias | CLR alias | Bit for GPIO*id* | GPIO0 |
|---|---|---|---|---|---|
| GPIO functional clock | `0x04870008` (EB1) | `0x048700B8` | `0x048700BC` | `BIT(4 + id)` | `BIT(4)` = `0x10` |
| GPIO APB clock (pclk) | `0x0487000C` (EB2) | `0x048700C0` | `0x048700C4` | `BIT(13 + id)` | `BIT(13)` = `0x2000` |
| Debounce source select | `0x04870000` (MUX0) | `0x048700A8` | `0x048700AC` | `BIT(2)` (global) | `0x4` |

Resets for GPIO0 (**V**, `AX620E.dtsi:236-238` + `axera_reset.c` 4-cell xlate):
`resets = <&periph_reset_ext 10 0xD8 10 0xDC>, <&periph_reset_ext 11 0xD8 11 0xDC>`
with `reset-names = "gpio_prst", "gpio_rst"`. The 4-cell form is
`<dev_id, rst_set_reg, rst_clr_bit, rst_clr_reg>` (**V**, `axera_reset.c`
`axera_reset_of_xlate` case 4), and assert/deassert are pure alias writes
(**V**, `axera_reset_updatenew`): **assert** = write `BIT(dev_id)` to
`base + rst_set_reg`; **deassert** = write `BIT(rst_clr_bit)` to
`base + rst_clr_reg`. `0xD8`/`0xDC` are periph `RST0` set/clear
(**V**, `clk-model-20260906.md` §1.3).

| Reset | Assert | Deassert | GPIO0 bit |
|---|---|---|---|
| `gpio_prst` | `0x048700D8 ← BIT(10)` | `0x048700DC ← BIT(10)` = `0x400` | 10 |
| `gpio_rst` | `0x048700D8 ← BIT(11)` | `0x048700DC ← BIT(11)` = `0x800` | 11 |

Per-controller bits: prst/rst are `(10+2c, 11+2c)` — GPIO1 = 12/13, GPIO2 = 14/15,
GPIO3 = 16/17 (**V**, `AX620E.dtsi:263-264, 290, 315`).

### 4.2 Verdict: not needed on a normally-booted board

**The `/dev/mem` blinker does not have to touch `0x4870000` at all.** Reasoning
(**I**, but well supported):

* **The SDK's own U-Boot GPIO driver programs no clock and no reset.** It reads
  and writes only `plat->base + (pin+1)*4` and `EXT_PORTA` (**V**, `uboot-gpio.c`
  — grep for `writel`/`readl` finds nothing outside the GPIO window; the
  `clk_rst_base` field in its platdata is declared and never used). U-Boot on
  this board *does* drive a GPIO0 line: `ax620e_emmc.c:127` sets the
  mini-display's SPI chip-select to `gpio 27` and `ulcddev`/`ugpiodev_init`
  puts it through `gpio_request()` + `gpio_direction_output()` (**V**,
  `[S]/boot/uboot/u-boot-2020.04/board/axera/ax620e_emmc/ax620e_emmc.c:100-127`).
  Global 27 = GPIO0 line 27. So GPIO0 answers reads and writes with no
  software clock enable, meaning the boot ROM/SPL/ATF leaves the periph GPIO
  gates on — or they are on out of reset.
* The vendor kernel's enable writes are therefore belt-and-braces, not a
  precondition.

**But do them anyway** — they cost five stores, they are all single-bit writes to
write-1-to-set/clear alias registers (so they cannot disturb a neighbouring
peripheral), and they make the blinker independent of what the boot chain did.
Sequence in §6.2.

**Do not** read or write the periph *value* registers (`0x04870000`–`0x04870010`)
with anything but reads. A read-modify-write there would race the rest of the SoC.

---

## 5. The pad mux — already done by U-Boot

**The pad is already `GPIO0_A23` before Linux starts. No pinmux write is
required.**

| Fact | Value | Evidence |
|---|---|---|
| Pad name | `SD_PWR_EN` | pinctrl pad #94 (**V**, `pinctrl-model-20260906.md` §2; `gpio-ranges` maps `ax_gpio0` line 23 → pin 94, `AX620E.dtsi:255`) |
| Pad mux register | **`0x023020A8`** | G5 group base `0x02302000`, slot 14 → `0x0C*14 = 0xA8` (**V**, `pinctrl-model-20260906.md` §1.2) |
| Value the board table writes | **`0x00060003`** | **V**, DEMO table line 113: `0x023020A8, 0x00060003, /* PadName = SD_PWR_EN  Fuction = GPIO0_A23 */` |
| Mux field | bits `[18:16]` = **6** | **V**, `pinctrl-model-20260906.md` §1.3 (`FUNCTION_SELECT 16`, `GENMASK(18,16)`) |
| Function 6 on this pad | `GPIO0_A23` | **V**, pad function table, `pinctrl-model-20260906.md` §2 row 94 (`SD_PWR_EN | — | — | — | — | DB_GPIO23 | GPIO0_A23 | —`) |
| Rest of the word | bits `[7:6]` pull = `00` (none), bit `[4]` schmitt = `0`, bits `[3:0]` drive = `3` | **V**, decode of `0x00060003` per `pinctrl-model-20260906.md` §1.3 |
| Who writes it | **U-Boot first, then the vendor kernel's `ax_pinmux` arch_initcall** | **V**, `pinctrl-model-20260906.md` §4.1: `[S]/boot/uboot/u-boot-2020.04/board/axera/ax620e_emmc/pinmux.c` `#include`s the same header and runs the same `<addr,value>` loop |

Because U-Boot applies it, a **mainline** kernel with no pinctrl driver at all
inherits a correctly muxed pad — nothing in mainline will overwrite it. This is
the opposite of the SW_PWR trap (`docs/mini-display.md`), where the *closed
capture stack* re-muxed `VI_D7` back to camera-data at runtime; nothing on this
board ever re-muxes `SD_PWR_EN`.

**If you want the write anyway** (idempotent, e.g. because you are booting from a
modified boot chain):

```
0x023020A8 ← 0x00060003          # full-word write, exactly what U-Boot writes
```

A read-modify-write variant that preserves the electrical config is
`val = (val & ~0x00070000) | 0x00060000`. Do **not** use the pad block's `+4`/`+8`
SET/CLR aliases here: they are verified only for the group MISC slot, not for pad
slots (**I**, `pinctrl-model-20260906.md` §1.2).

**GAP:** `[D]/pinmux-regs.txt` dumps only offsets `0x000`–`0x5FC` of each window,
so `0x023020A8` was not read live. The functional proof that it is `0x00060003`
is that the LED visibly blinks on the vendor system with the heartbeat trigger
bound to this line. §8 closes the gap with one `devmem` read.

---

## 6. The exact write sequence

### 6.1 Minimum: two operations

Read-modify-write is **required** (see below). `W = 0x04800060`.

**(a) LED on**

```
v = read32(0x04800060)
v = v | 0x00000003          # DDR=1 (output enable) + DR=1 (drive high)
write32(0x04800060, v)
```

**(b) LED off**

```
v = read32(0x04800060)
v = (v | 0x00000002) & ~0x00000001    # DDR stays 1, DR=0 (drive low)
write32(0x04800060, v)
```

That is exactly what `ax_gpio_set()` does (**V**, `gpio-axera.c:164-186` — it
sets `DDR` on *both* paths, so the first `set()` is also the
`direction_output()`). Blink by alternating (a) and (b).

**Is read-modify-write required?** Yes, for correctness in general; on this
specific line a blind `write32(W, 3)` / `write32(W, 2)` also works, and here is
the exact reasoning so the author can choose:

* There is no set/clear alias, so RMW is the only way to change one field
  (**V**, §3.2).
* The bits that must be preserved are 2 (`SOFT_HAR_MODE`), 3–7 and 9 (interrupt
  configuration and debounce) and 10–31 (reserved). On a freshly booted mainline
  kernel with no GPIO driver, **nothing has configured an interrupt on any line**,
  so all of those read back 0 and a blind write of `0x3`/`0x2` is identical to
  the RMW result (**I**, from "no driver ran"). On the *vendor* system, line 23
  likewise has no interrupt (it is an LED), so the same holds — but line 22
  (knob) and line 18 (rotary) do, which is why the habit matters.
* Bit 8 (`PORTA_EOI`) is a manual pulse, not write-1-to-clear, so RMW cannot
  accidentally ack an interrupt (**V**, §3.2).
* **Use RMW.** It costs one load and is correct on every line.

**Starting state.** After U-Boot the word is whatever reset left plus anything
U-Boot's GPIO driver did to line 23 — and U-Boot's board file drives lines 27
(SPI CS), and GPIO1 lines 9/11 for the display, **not** line 23 (**V**, board
file + DT). So the expected starting value is `0x00000000` (input, everything
off) and the first (a) turns the LED on. Neither branch depends on this.

**Memory-mapping rules for the program** (from the repo's hard-won `/dev/mem`
notes, `docs/reference/deblob-scope/regdumps/README.md`):

* `mmap` `/dev/mem` at a page-aligned base — for GPIO0 that is `0x04800000`,
  length `0x1000` (the DT window is `0x400`; one page covers it).
* Use `volatile uint32_t` loads and stores. **Never** `memset`/`memcpy` on a
  `/dev/mem` mapping — glibc uses `DC ZVA`, which SIGBUSes on Device memory.
* All accesses must be naturally aligned 32-bit.
* On mainline, `/dev/mem` needs `CONFIG_DEVMEM=y` and, for these addresses,
  `CONFIG_STRICT_DEVMEM=n` (they are not in `System RAM`, but arm64's
  `devmem_is_allowed()` is stricter than x86's — build with it off for the
  bring-up initramfs).

### 6.2 Optional belt-and-braces preamble

Do these **once**, before the first blink, in this order. Every one is a
single-bit write to a write-1-to-set or write-1-to-clear alias, so none of them
can disturb another peripheral.

```
write32(0x048700DC, 0x00000400)   # deassert GPIO0 gpio_prst  (RST0 CLR, bit 10)
write32(0x048700DC, 0x00000800)   # deassert GPIO0 gpio_rst   (RST0 CLR, bit 11)
write32(0x048700C0, 0x00002000)   # enable GPIO0 pclk         (EB2 SET, bit 13)
write32(0x048700B8, 0x00000010)   # enable GPIO0 clk          (EB1 SET, bit 4)
write32(0x048700A8, 0x00000004)   # debounce source = 24 MHz  (MUX0 SET, bit 2)
```

Order matters only in that resets come out before the clocks go on, matching the
vendor probe (**V**, `ax_gpio_probe`: `ax_deassert_reset()` then `ax_gpio_clk(id, true)`).
The MUX0 write is cosmetic for an LED (debounce is unused) — include it only if
you want to mirror the vendor exactly.

Note the periph window `0x04870000` is a *different page* from the GPIO window;
map it separately (base `0x04870000`, length `0x1000`).

### 6.3 A complete blink loop, in words

1. `open("/dev/mem", O_RDWR | O_SYNC)`.
2. `mmap` `0x04800000`, length `0x1000` → `gpio0`.
3. Optionally `mmap` `0x04870000`, length `0x1000` → `periph`, do §6.2, `munmap`.
4. Forever: RMW `gpio0[0x60/4] |= 3`; sleep ~250 ms; RMW
   `gpio0[0x60/4] = (v | 2) & ~1`; sleep ~250 ms.

Use `nanosleep`, not a busy loop — a mainline kernel this early may have no
other timekeeping validated, but `nanosleep` only needs the arch timer, which is
architectural on arm64.

---

## 7. Reading the line back

To confirm a write took, without an oscilloscope:

* `read32(0x04800060) & 3` — echoes the latch you just wrote. **This proves
  nothing about the ball**; it is the same trap as the sysfs `value` file
  (`docs/mini-display.md`). It does prove the register file is alive and writable,
  which on a first mainline boot is most of what you want.
* `read32(0x04800090)` (`ID_CODE`) and `read32(0x04800098)` (`VER_ID_CODE`) are
  read-only identity words. **Non-zero, stable values here prove the block is
  clocked and out of reset** — the single most useful liveness check, and it is
  purely read-only. (**I**: their exact expected values are unknown; capture them
  once from the vendor system, §8 step 1, and compare.)
* `read32(0x0480008C)` (`EXT_PORTA`) bit 23 — the pad input read-back. Whether it
  tracks a driven output is **GAP** (§3.3).

---

## 8. Verification recipe (vendor system, over SSH, read-mostly)

Prerequisites: `tools/kvmssh` (see the kvm-device skill); BusyBox `devmem` is
present on the stock rootfs. `devmem ADDR` reads; `devmem ADDR 32 VALUE` writes a
32-bit word.

Every step is reversible; the only writes are to the LED's own line word, and
step 6 restores the kernel's control of it.

**1. Baseline — pure reads. Record everything.**

```sh
devmem 0x023020A8        # pad mux for SD_PWR_EN.  Expect 0x00060003
devmem 0x04800090        # GPIO0 ID_CODE           record it
devmem 0x04800098        # GPIO0 VER_ID_CODE       record it
devmem 0x04800060        # line 23 word            expect 0x2 or 0x3 (DDR set, DR = current blink phase)
devmem 0x0480008C        # EXT_PORTA               note bit 23
devmem 0x04870008        # periph EB1              expect bit 4 set  (0x10)
devmem 0x0487000C        # periph EB2              expect bit 13 set (0x2000)
```

`0x023020A8 == 0x00060003` confirms §5. Bits 4 / 13 in the two EB words confirm
§4. `0x04800060` flipping between `0x2` and `0x3` across two reads a moment apart
is itself proof that bit 0 is the output data bit and bit 1 the direction bit,
because the heartbeat trigger is toggling exactly that.

**2. Take the LED away from the kernel (reversible).**

```sh
cat /sys/class/leds/sys-heartbeat/trigger     # record the current one; 'heartbeat' will be [bracketed]
echo none > /sys/class/leds/sys-heartbeat/trigger
echo 0    > /sys/class/leds/sys-heartbeat/brightness
devmem 0x04800060                              # expect 0x00000002 : output, low. LED dark.
```

Confirm by eye that the LED has stopped blinking and is **off**. That single
observation already proves *DDR=1, DR=0 ⇒ dark* and hence **active-high**.

**3. The one write that toggles the LED.**

```sh
devmem 0x04800060 32 0x3     # LED ON
devmem 0x04800060 32 0x2     # LED OFF
```

Watch the LED across the pair. This is the whole spec, confirmed:
bit 0 = output value, bit 1 = output enable, address = `base + (23+1)*4`.

**4. Prove the address arithmetic — a negative control.**

```sh
devmem 0x0480005C            # line 22 word (knob button). READ ONLY. Do not write.
devmem 0x04800064            # line 24 word (i2c0 SCL).    READ ONLY. Do not write.
```

Neither read changes the LED. If your candidate address had been off by one
slot, step 3 would have done nothing visible — so a *working* step 3 is itself
the proof that `(n+1)*4` is right, and these two reads just show the neighbours
exist and are distinct words.

**5. Prove bit 1 is the output enable, not a second data bit.**

```sh
devmem 0x04800060 32 0x1     # DR=1 but DDR=0 : line is an INPUT, driver disabled
```

The LED must stay **dark** (or float to whatever the board's pull does).
Then:

```sh
devmem 0x04800060 32 0x3     # DDR=1 : driver enabled, LED lights
devmem 0x04800060 32 0x2     # back to dark
```

**6. Prove the mux field, then put it straight back (optional, 2 writes).**

```sh
devmem 0x04800060 32 0x3     # LED on
devmem 0x023020A8 32 0x00000003   # mux field -> 0 = SD_PWR_EN function. LED should go dark.
devmem 0x023020A8 32 0x00060003   # mux field -> 6 = GPIO0_A23.          LED should light again.
devmem 0x04800060 32 0x2     # LED off
```

Function 0 (`SD_PWR_EN`, the SD-card power switch) has **no consumer** on this
board — the `sd` node is `broken-cd` and no SD regulator is modelled (**V**,
board dts; `pinctrl-model-20260906.md` §3.3 lists `sd_ctrl` as a 3-pad function
group, and its §4.2 classifies the other two `sd_ctrl` pads as _unclaimed_) — so
briefly parking the pad there is harmless. Skip this step
if you would rather not touch a pad word at all; §5's evidence chain is already
`V` from two independent boot-chain sources.

**7. Restore.**

```sh
echo heartbeat > /sys/class/leds/sys-heartbeat/trigger
devmem 0x04800060            # expect it to start flipping 0x2/0x3 again
```

Nothing above survives a reboot in any case: the pad word is rewritten by U-Boot
and `ax_pinmux`, and the line word is reprogrammed by `leds-gpio` at probe.

---

## 9. Risks

**The structural safety property:** one line = one 32-bit word, and the word
carries no other line's state. A correct-address, correct-width write to
`0x04800060` cannot affect anything else on the SoC. Every risk below is a risk
of writing the *wrong address*.

### 9.1 Wrong offset on the same controller — what is next door

An off-by-one slot from `0x04800060` lands on line 22 or line 24; an off-by-`+1`
in the formula (forgetting the `(n+1)`) lands on `0x0480005C` = line 22. Worse
arithmetic reaches:

| Wrong address | Line | What a stray `0x3` / `0x2` does |
|---|---|---|
| `0x04800020` | 7 | **Worst case.** This is the ATX `SW_PWR` line — the host's front-panel power button. Driving it high is pressing the button; holding it high ≥ 4 s is a hard power-off of the machine the KVM is attached to. |
| `0x04800018` | 5 | Forcing low cuts `LT6911UXC_PWR` — the HDMI receiver dies, capture stops, and the vendor teardown path is the one that used to oops (#50). |
| `0x0480001C` | 6 | Forcing low cuts `LT86102UXC_HDMI_PWR` — the HDMI splitter/bridge; the pass-through output to the user's monitor goes dark. |
| `0x04800058` | 21 | `LT86102UXC_HDMI_TXO` control — bridge output routing. |
| `0x0480005C` | 22 | Knob button, an **input with an IRQ**. Forcing it to output stops the button working and can wedge the level-triggered IRQ. |
| `0x04800064` / `0x04800068` | 24 / 25 | i2c0 bit-bang recovery SCL/SDA. Forcing them mid-transaction corrupts the bus that talks to the HDMI front end. |
| `0x04800024` / `0x04800028` | 8 / 9 | Same, for i2c7. |
| `0x04800070` | 27 | spi2 CS1 — the mini-display. Cosmetic only. |
| `0x0480004C` | 18 | Rotary encoder B, input + IRQ. |
| `0x04800000` | — | Not a line: the secure-mode word (§3.4). Effect unknown (**GAP**); most likely changes which interrupt-status view is live. |
| `0x04800084`–`0x048000A8` | — | Port-level registers. Writing `ID_CODE`/`CONFIG_REG*` is harmless (read-only); writing the status registers could ack or fake interrupts. |

**Nothing on GPIO0 gates the board's own power, the eMMC, or the boot chain.** The
eMMC hardware reset is `GPIO2_A23` (`0x0600_0060` — note the identical *offset*
on a different controller, a genuine footgun), and the Ethernet PHY reset is
`GPIO1_A27` (`0x0480_1070`). Neither is reachable by an offset error within
GPIO0. So **the LED blinker cannot brick the device**; the realistic worst case
is powering off the attached host or dropping HDMI capture until reboot.

### 9.2 Wrong address in the periph window `0x04870000`

This window carries the clock gates and resets for **every** peripheral in the
periph domain — UARTs, I²C, SPI, timers, the crypto engine, the watchdogs.

* Only ever write **single-bit** values to the **alias** registers
  (`0xA8`–`0xF4`). They are write-1-to-set / write-1-to-clear, so a single-bit
  write touches exactly one gate.
* **Never** write the value registers `0x04870000`–`0x04870010` or `0x14`–`0x20`.
  A read-modify-write there races every other agent in the SoC.
* Gating off the wrong clock (e.g. a bit in `0x048700BC` other than 4–7) can
  silence a peripheral the boot depends on. Since §4.2 shows the preamble is
  optional, **the safest blinker omits §6.2 entirely** and touches only
  `0x04800060`.

### 9.3 Reads that hang

Do not go wandering with `devmem` on this SoC. Reading `0x04403000` (the MM/VPP
rst1 block) on a boot where the MM domain is unclocked **hangs the AXI bus and
watchdogs the board** (proven 2026-09-01, `docs/reference/deblob-scope/regdumps/README.md`).
The GPIO windows (`0x0480_0000`, `0x0480_1000`, `0x0600_0000`, `0x0600_1000`),
the pinctrl windows (`0x0230_0000`, `0x104F_0000`) and the periph window
(`0x0487_0000`) are all confirmed live on a base boot; treat everything else as
hostile.

### 9.4 Mainline-specific

* `panic_on_oops=1` in the vendor cmdline turns any fault into a reboot. On the
  slot-B mainline test that is *convenient* — a hang and a reboot are
  distinguishable by whether `bootsystem` re-armed — but do not confuse a
  `/dev/mem` SIGBUS in the init with a kernel failure. Catch `SIGBUS` in the
  blinker if you want the distinction.
* If `CONFIG_STRICT_DEVMEM` is left on, the `mmap` fails with `EPERM` and the
  LED never blinks — an indistinguishable outcome from "the kernel died". Verify
  the config, or have the init `write()` a marker to the boot-flag address
  (`0x2390028 ← 0x20`, `docs/mainline-port.md` §7 step 2) *before* attempting
  the LED, so the two failures separate.

---

## 10. Gaps

| # | Gap | How to close |
|---|---|---|
| 1 | Live value of `0x023020A8` never dumped (`[D]/pinmux-regs.txt` stops at `+0x5FC`) | §8 step 1, one read |
| 2 | Expected `ID_CODE` / `VER_ID_CODE` values | §8 step 1, record them |
| 3 | Does `EXT_PORTA` loop back a driven output? | §8 step 3 with an extra `devmem 0x0480008C` between the two writes |
| 4 | Meaning of `base + 0x00` beyond "0 = non-secure" | none needed for this task |
| 5 | Meaning of `SOFT_HAR_MODE` (bit 2) | never written by any vendor code; leave alone |
| 6 | Whether the periph GPIO gates are on out of reset or turned on by SPL/ATF | irrelevant given §4.2, but `devmem 0x04870008` from U-Boot's console would settle it — and this unit has no serial console (`docs/mini-display.md`, memory: "no serial on this unit") |
