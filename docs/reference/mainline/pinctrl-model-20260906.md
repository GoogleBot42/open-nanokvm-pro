# AX630C (AX620E) pin-control data model — specification

Issue #80. Written 2026-09-06 from the GPL-2.0 vendor 4.19 kernel source plus a
read-only dump of the running device. This is the complete data model a
from-scratch mainline `pinctrl-ax630c` driver and a regenerated `.dtsi` can be
written from; no vendor code is reproduced.

Every fact is marked **V** (verified against a cited source line or device dump)
or **I** (inferred). Sources:

| Tag | File |
|---|---|
| `[K]` | `/nix/store/gzmk3ygvw8n2vgi230fplbv5295nf42q-source/linux/linux-4.19.125` (vendor kernel, GPL-2.0) |
| `[S]` | `/nix/store/k7b551m83qh9dpxdkvgjgjjc3w2rhknn-source` (Sipeed `maix_ax620e_sdk`) |
| `[D]` | `docs/reference/mainline/device-reads-20260906/` (live 4.19 device, read-only) |

Short names used below: `pinctrl-ax620e.c`/`.h` and `pinctrl-axera.c`/`.h` are in
`[K]/drivers/pinctrl/axera/`; `ax_pinmux.c`/`.h` in `[K]/drivers/soc/axera/pinmux/`;
`gpio-axera.c` in `[K]/drivers/gpio/`; `AX620E.dtsi`, `AX620E_pinctrl.dtsi` and
`AX630C_emmc_arm64_k419_sipeed_nanokvm.dts` in `[K]/arch/arm64/boot/dts/axera/`;
the board pad table is
`[S]/build/projects/AX630C_emmc_arm64_k419_sipeed_nanokvm/pinmux/AX630C_DEMO_pinmux.h`
(called **DEMO table** throughout).

---

## 1. Register model

### 1.1 The two windows are one address space

The controller is a single flat register file at physical `0x02300000`, but it is
described with two `reg` entries because the AON half sits far away:

| Window | Physical | Length | Covers |
|---|---|---|---|
| 0 | `0x02300000` | `0xB000` | groups G1, G2, G5, DPHYRX, G6, G7, G11, DPHYTX |
| 1 | `0x104F0000` | `0x3000` | groups G8, G9, G12 |

`AX620E.dtsi:133-136` declares exactly those two ranges (**V**), and
`iomem.txt` confirms both are live on the device as `pinctrl@0x2300000` (**V**).

The vendor driver stores **one** offset per pad, relative to `0x02300000`, and
splits at `SECOND_OFFSET = 0x0E1F0000` (`pinctrl-ax620e.h:280`, computed as
`EMAC_PTP_PPS0_OFFSET - 0xC`): offsets below it index window 0, offsets at or
above it index window 1 minus `SECOND_OFFSET` (`pinctrl-axera.c:35-49`) (**V**).
The magic constant exists only because `0x02300000 + 0x0E1F0000 == 0x104F0000`
exactly (**V**) — so **for every pad, absolute address = `0x02300000 + offset`**,
and the split is an implementation detail, not a hardware fact. A mainline driver
should carry `{window, offset}` per pad and drop the arithmetic entirely.

### 1.2 Group layout: 12-byte slots

Each group occupies a 4 KiB page and is an array of 12-byte slots:

```
group_base + 0x0C*k + 0x0   VALUE
group_base + 0x0C*k + 0x4   SET   alias (write-1-to-set)
group_base + 0x0C*k + 0x8   CLR   alias (write-1-to-clear)
```

* **Slot 0** (`group_base + 0x00/0x04/0x08`) is a group-level MISC word, not a pad.
* **Slots 1..N** are the pads, in the order the pad table below gives them —
  hence pad *k* at `group_base + 0x0C*k`, i.e. the first pad is at `+0x0C` and the
  stride is `0xC` (**V**, `pinctrl-ax620e.h:30-153`).
* Slots past the last pad are spare and the vendor reuses some as further MISC
  words (see §1.5).

The SET/CLR aliases are **V** for slot 0 only: `sdhci-axera.c:84-90` names
`PIN_MUX_G9_PINCTRL_SET = 0x104F1004` and `..._CLR = 0x104F1008` and writes
`GENMASK(8,7)` to them (`sdhci-axera.c:468-531`), and the DEMO table's paired
writes to `<group>+0x08` then `<group>+0x04` only make sense as clear-then-set
(**V**). Whether the *pad* slots also honour their `+4`/`+8` aliases is **I** —
nothing in the vendor tree uses them, and both the pinctrl driver
(`pinctrl-axera.c:100-103`, `235/273`) and every direct poker do read-modify-write
or blind full-word writes on the VALUE word. **Test this on hardware before
relying on it**; if it holds, the mainline driver can drop its spinlock.

Group bases (**V**, derived from `pinctrl-ax620e.h:30-153`):

| Group | Base | Pads | Pad offsets |
|---|---|---|---|
| G1 | `0x02300000` | 11 | `0x0C`–`0x84` |
| G2 | `0x02301000` | 4 | `0x100C`–`0x1030` |
| G5 | `0x02302000` | 12 | `0x200C`–`0x20A8`, slots 5 and 11 (`0x203C`, `0x2084`) unpopulated |
| DPHYRX | `0x02303000` | 12 | `0x300C`–`0x3090` |
| G6 | `0x02304000` | 12 | `0x400C`–`0x4090` |
| G7 | `0x02305000` | 4 | `0x500C`–`0x5030` |
| G11 | `0x02309000` | 12 | `0x900C`–`0x9090` |
| DPHYTX | `0x0230A000` | 10 | `0xA00C`–`0xA078` |
| G8 | `0x104F0000` | 22 | `0x0C`–`0x108` |
| G9 | `0x104F1000` | 6 | `0x100C`–`0x1048` |
| G12 | `0x104F2000` | 6 | `0x200C`–`0x2048` |

111 pads total. Groups G3, G4 and G10 do not exist in this SoC's table (**V** —
the enum has no members for them; whether they exist on a larger AX620E die is
unknown, **I**).

### 1.3 Pad VALUE word — bit fields

Verified field-by-field against the driver. The brief's assumed layout was
correct on all three counts:

| Bits | Field | Encoding | Evidence |
|---|---|---|---|
| `[31:19]` | untouched | — | no vendor code writes above bit 18 (**V**); reset-preserved (**I**) |
| `[18:16]` | **function select** | 0–7, per-pad meaning (§2) | `FUNCTION_SELECT 16`, `FUNCTION_SELECT_BIT_CLEAR (0x7<<16)`, `pinctrl-ax620e.h:26-27`; applied at `pinctrl-axera.c:101-103` (**V**). Also `PINMUX_FUNC_SEL GENMASK(18,16)` in `ax_pinmux.h:11` (**V**) |
| `[15:8]` | untouched | — | never written by any vendor code path (**V**) |
| `[7]` | **pull select / pull-up** | see §1.4 | `AX_PULL_UP_BIT 7` / `AX_PULL_SE_BIT 7`, `pinctrl-ax620e.h:14-20` (**V**) |
| `[6]` | **pull-down / pull-enable** | see §1.4 | `AX_PULL_DOWN_BIT 6` / `AX_PULL_EN_BIT 6` (**V**) |
| `[5]` | unknown | never set by anything | no vendor write ever sets it; all 111 DEMO values have bit 5 clear (**V** on the absence; function unknown, **I**) |
| `[4]` | **input schmitt enable** | 1 = enabled | `AX_SCHMITT_ENABLE_BIT 4`, `pinctrl-ax620e.h:23-24`; `pinctrl-axera.c:209-211, 263-266` (**V**) |
| `[3:0]` | **drive strength** | raw 0–15, written verbatim from `drive-strength` | `AX_DRIVE_STRENGTH 0xf`, `pinctrl-ax620e.h:22`; `pinctrl-axera.c:206-207, 259-261` (**V**) |

There is **no direction, input-enable or slew-rate bit** in this word (**V** —
`pinctrl-axera.c` implements exactly four `pin_config` params: `BIAS_PULL_DOWN`,
`BIAS_PULL_UP`, `BIAS_DISABLE`, `DRIVE_STRENGTH`, `INPUT_SCHMITT_ENABLE`, and
returns `-ENOTSUPP` for everything else). Direction lives in the GPIO controller
(`gpio-axera.c:106-133`), so a mainline `gpio_set_direction()` callback has
nothing to program in the pad word.

`drive-strength` is a raw 4-bit code, **not** milliamps. Codes actually used on
this board: 0, 3, 5, 8, 15. The mA mapping is unknown (**I**) — the mainline
binding should therefore keep the raw code, either as `drive-strength = <n>`
documented as a code, or better as a vendor property `axera,drive-strength`
so nobody reads it as mA.

### 1.4 Pull encoding is not uniform across groups

Two encodings coexist (**V**, `pinctrl-axera.c:190-199` and `246-253`):

* **Groups G2, G5, G7** (pad offsets `0x100C`–`0x20A8` and `0x500C`–`0x5030`,
  i.e. the analog-capable domains): bit 6 = pull **enable**, bit 7 = pull
  **select** (1 = up, 0 = down). Pull-up is therefore `0b11` = `0xC0`.
* **Every other group**: one-hot. Bit 7 = pull-**up**, bit 6 = pull-**down**.
  Pull-up is `0x80`.

Both encodings agree on pull-down (`0x40`) and on disable (`0x00`) (**I**, from
the shared code paths). The vendor selects the encoding by numeric offset range,
which happens to cover exactly all of G2, G5 and G7 and nothing else (**V**).
A mainline driver should carry this as a per-pad or per-group flag, not an
address comparison.


**RESOLVED on hardware 2026-09-06: the EN/SE reading is correct**
([`device-reads-20260906/pull-encoding-adc/README.md`](device-reads-20260906/pull-encoding-adc/README.md)).
Measured on `THM_AIN3` (G2) with the on-chip ADC as an analog oracle rather than
a GPIO input, because that pad floats mid-scale and so separates pull-up,
pull-down and no-pull into three distinguishable voltages. `0x80` reads 662/1023,
identical to no-pull's 662, when one-hot requires it to be a pull-up and read
high; and `0xC0` reads 1018, when one-hot makes it up-plus-down contention that
could never exceed pure pull-up. All four codes match EN/SE.

So the table generator IS encoding-blind for this group: the DEMO's `0x…83` on
`MICP_L_D` really is *no pull*, harmless only because that pad has an external
pull-up. Hardware proof covers G2; G5 and G7 have no ADC channel and are carried
on the vendor driver's single offset test plus digital readings consistent with
EN/SE. The driver's per-pad `pull_enc` flag and written values were already
right -- this confirms them rather than changing anything.

### 1.5 Group MISC words

* `<group>+0x00` — MISC0. The DEMO table initialises every one of the 11 groups
  identically: write `0x0000000F` to the CLR alias, then `0x00000201` to the SET
  alias, leaving bits `[3:0] = 0b0001` and bit 9 set (**V**, DEMO table, 22 of
  its 133 entries). Field meanings are unknown except:
  * bits `[8:7]` = **I/O voltage select** for the CMD/DATA pads of that group —
    `sdhci-axera.c:468-531` sets them for 1.8 V and clears them for 3.3 V on G9
    (SD) and G12 (SDIO) (**V**).
* `<group>+0x58` — read-only voltage detect, bit 0 = 0 means the rail is at
  1.8 V. Named `PIN_MUX_G9_VDET_RO0` / `PIN_MUX_G12_VDET_RO0`,
  `sdhci-axera.c:83, 91` (**V**). Falls in G9/G12's spare-slot region.
* `0x023040A8` — a second MISC word in G6 (spare slot 14). `ax_pinmux.c:65-73`
  writes `BIT(1)` to it and calls it "sleep mode enable / misc_g6[1]"
  (`ax_pinmux.h:15-19`) (**V**). `[K]/drivers/soc/axera/wake_timer/wake_timer.c:48`
  maps `0x023040AC` as `PINMUX_G6_MISC_CLR_ADDR` but never touches it (dead
  mapping) — and under the slot model `0x…A8+4` is the **SET** alias, so that
  name is probably a slip (**I**).

### 1.6 Reset values

**Unknown and unobservable.** U-Boot writes all 111 pad words before any code we
can run (`[S]/boot/uboot/u-boot-2020.04/board/axera/ax620e_emmc/pinmux.c`, **V**),
and `bootdelay=0` leaves no interruption window. The one reset value that can be
stated: bits `[15:8]`, `[5]` and `[31:19]` are never written by any vendor code
path, so whatever the device shows there today *is* the reset value (**I**).
This is a clearly-marked gap; it does not block the driver, because mainline will
also write every pad it manages.

---

## 2. The complete pad table

111 pads, pin numbers as `pinctrl-ax620e.h:155-278`, offsets as
`pinctrl-ax620e.h:30-153`, mux value → signal name as `pinctrl-ax620e.c:19-693`.
All **V**. Absolute address = `0x02300000 + offset` in every row (§1.1).

A dash means that function-select value is **reserved / not connected** on that
pad — 111 pads × 8 values = 888 slots, of which 551 are populated and 337 are
reserved. Writing a reserved value is undefined; the mainline driver must
reject it.

Two vendor naming conventions appear in the signal column:

* `SIGNAL__PAD` — the same signal is reachable from more than one pad and the
  vendor suffixed the pad name to keep function names globally unique. All 551
  names are unique (**V**, checked).
* `NULL__PAD` — function-select 0 means *no digital function* (the four G7 mic
  pads are analog in that position).
* A trailing `_M` (e.g. `PWM0_M`, `SPI_M2_MOSI_M`, `RGMII_MDCK_M`) marks an
  **alternate pad** for a signal that also exists elsewhere. `_M` variants belong
  to the same logical function as their primary (§3).

| Pin | Pad | Address | Offset | f=0 | f=1 | f=2 | f=3 | f=4 | f=5 | f=6 | f=7 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | `VI_D0` | `0x230000c` | `0xc` | VI_D0 | INFRARED_FS | SPI_M1_MOSI | I2C6_SDA | I2S0_DIN0 | DB_GPIO0 | GPIO0_A0 | ANALOG_TEST1 |
| 1 | `VI_D1` | `0x2300018` | `0x18` | VI_D1 | INFRARED_SDO0 | SPI_M1_MISO | I2C6_SCL | I2S0_SCLK | DB_GPIO1 | GPIO0_A1 | ANALOG_TEST2 |
| 2 | `VI_D2` | `0x2300024` | `0x24` | VI_D2 | INFRARED_SDO1 | SPI_M1_CS0 | TIME_50HZ | I2S0_DOUT | DB_GPIO2 | GPIO0_A2 | ANALOG_TEST3 |
| 3 | `VI_D3` | `0x2300030` | `0x30` | VI_D3 | INFRARED_SDO2 | SPI_M1_CS1 | CLK_AUX1_1 | I2S0_MCLK | DB_GPIO3 | GPIO0_A3 | ANALOG_TEST4 |
| 4 | `VI_D4` | `0x230003c` | `0x3c` | VI_D4 | INFRARED_CLK_M | SPI_M1_SCLK | I2C5_SDA | I2S0_DIN1 | DB_GPIO4 | GPIO0_A4 | ANALOG_TEST5 |
| 5 | `VI_D5` | `0x2300048` | `0x48` | VI_D5 | — | SPI_S_D3 | I2C_S0_SDA | — | DB_GPIO5 | GPIO0_A5 | — |
| 6 | `VI_D6` | `0x2300054` | `0x54` | VI_D6 | INFRARED_SDI0 | SPI_S_D1 | I2C_S0_SCL | — | DB_GPIO6 | GPIO0_A6 | — |
| 7 | `VI_D7` | `0x2300060` | `0x60` | VI_D7 | INFRARED_SDI1 | SPI_S_D0 | SPI_M1_CS2 | — | DB_GPIO7 | GPIO0_A7 | — |
| 8 | `VI_D8` | `0x230006c` | `0x6c` | VI_D8 | INFRARED_SDI2 | SPI_S_CS | I2C7_SCL | — | DB_GPIO8 | GPIO0_A8 | — |
| 9 | `VI_D9` | `0x2300078` | `0x78` | VI_D9 | INFRARED_SDI3 | SPI_S_D2 | I2C7_SDA | — | DB_GPIO9 | GPIO0_A9 | — |
| 10 | `VI_CLK0` | `0x2300084` | `0x84` | VI_CLK0 | SPI_M1_CS3 | SPI_S_SCLK | I2C5_SCL | I2S0_LRCK | DB_GPIO10 | GPIO0_A10 | ANALOG_TEST0 |
| 11 | `I2C0_SCL` | `0x230400c` | `0x400c` | I2C0_SCL | SPI_M2_CS1 | RISC_TCK | PWM00 | CLK_AUX0_0 | UART2_CTS | GPIO0_A24 | ANALOG_TEST12 |
| 12 | `I2C0_SDA` | `0x2304018` | `0x4018` | I2C0_SDA | SPI_M2_CS2 | RISC_TRSTN | PWM01 | CLK_AUX0_1 | UART2_RTS | GPIO0_A25 | ANALOG_TEST13 |
| 13 | `I2C1_SCL` | `0x2304024` | `0x4024` | I2C1_SCL | SPI_M2_SCLK | — | PWM02 | CLK_AUX0_2 | UART4_CTS | GPIO0_A26 | — |
| 14 | `I2C1_SDA` | `0x2304030` | `0x4030` | I2C1_SDA | SPI_M2_CS0 | — | PWM03 | CLK_AUX1_0 | UART4_RTS | GPIO0_A27 | — |
| 15 | `UART0_TXD` | `0x230403c` | `0x403c` | UART0_TXD | — | RISC_TDI | — | — | DB_GPIO24 | GPIO0_A28 | ANALOG_TEST6 |
| 16 | `UART0_RXD` | `0x2304048` | `0x4048` | UART0_RXD | — | RISC_TMS | — | — | DB_GPIO25 | GPIO0_A29 | ANALOG_TEST7 |
| 17 | `UART1_TXD` | `0x2304054` | `0x4054` | UART1_TXD | SPI_M2_CS3 | RISC_TDO | PWM06 | SEN_FLASH_D1 | DB_GPIO26 | GPIO0_A30 | ANALOG_TEST8 |
| 18 | `UART1_RXD` | `0x2304060` | `0x4060` | UART1_RXD | MCLK7 | CLK_AUX3_0 | PWM07 | SEN_FLASH_D2 | — | GPIO0_A31 | ANALOG_TEST9 |
| 19 | `UART2_TXD` | `0x230406c` | `0x406c` | UART2_TXD | — | CLK_AUX3_1 | TIMESTAMP_LOCK_I1 | SEN_FLASH_D3 | DB_GPIO27 | GPIO1_A0 | ANALOG_TEST10 |
| 20 | `UART2_RXD` | `0x2304078` | `0x4078` | UART2_RXD | — | CLK_AUX3_2 | TIMESTAMP_LOCK_O1 | SEN_ELEC_PLS | DB_GPIO28 | GPIO1_A1 | ANALOG_TEST11 |
| 21 | `UART3_TXD` | `0x2304084` | `0x4084` | UART3_TXD | SPI_M2_MOSI | CLK_AUX2_1 | PWM04 | SEN_FLASH_D4 | DB_GPIO29 | GPIO1_A2 | — |
| 22 | `UART3_RXD` | `0x2304090` | `0x4090` | UART3_RXD | SPI_M2_MISO | CLK_AUX2_2 | PWM05 | SEN_FLASH_D0 | DB_GPIO30 | GPIO1_A3 | — |
| 23 | `EMAC_PTP_PPS0` | `0x104f000c` | `0xe1f000c` | EMAC_PTP_PPS0 | DPI_D17 | PWM0_M | UART5_CTS | SEN_FLASH_D5 | DB_GPIO35 | GPIO1_A8 | — |
| 24 | `EMAC_PTP_PPS1` | `0x104f0018` | `0xe1f0018` | EMAC_PTP_PPS1 | DPI_D16 | PWM1_M | UART5_RTS | SEN_VSYNC_D0 | DB_GPIO36 | GPIO1_A9 | — |
| 25 | `EMAC_PTP_PPS2` | `0x104f0024` | `0xe1f0024` | EMAC_PTP_PPS2 | DPI_D18 | SD_CARD_DETECT_N | UART5_TXD | — | DB_GPIO37 | GPIO1_A10 | — |
| 26 | `EMAC_PTP_PPS3` | `0x104f0030` | `0xe1f0030` | EMAC_PTP_PPS3 | DPI_D15 | PWM2_M | UART5_RXD | — | DB_GPIO38 | GPIO1_A11 | — |
| 27 | `RGMII_MDCK` | `0x104f003c` | `0xe1f003c` | RGMII_MDCK | DPI_D1 | PWM5_M | SEN_FLASH_D1_M | — | DB_GPIO51 | GPIO1_A24 | — |
| 28 | `RGMII_MDIO` | `0x104f0048` | `0xe1f0048` | RGMII_MDIO | DPI_D2 | PWM6_M | SEN_FLASH_D2_M | — | DB_GPIO52 | GPIO1_A25 | — |
| 29 | `EPHY_CLK` | `0x104f0054` | `0xe1f0054` | EPHY_CLK | DPI_PCLK | CLK_AUX1_2 | SEN_FLASH_D3_M | — | DB_GPIO53 | GPIO1_A26 | — |
| 30 | `EPHY_RSTN` | `0x104f0060` | `0xe1f0060` | EPHY_RSTN | DPI_D0 | PWM7_M | SEN_FLASH_D4_M | SPI_M2_CS0_M | DB_GPIO54 | GPIO1_A27 | — |
| 31 | `EPHY_LED0` | `0x104f006c` | `0xe1f006c` | EPHY_LED0 | RGMII_MDCK_M | TE0 | SEN_FLASH_D5_M | SPI_M2_CS3_M | DB_GPIO55 | GPIO1_A28 | — |
| 32 | `EPHY_LED1` | `0x104f0078` | `0xe1f0078` | EPHY_LED1 | RGMII_MDIO_M | TE1 | SEN_ELEC_PLS_M | SPI_M2_CS2_M | DB_GPIO56 | GPIO1_A29 | — |
| 33 | `RGMII_RXD0` | `0x104f0084` | `0xe1f0084` | RGMII_RXD0 | DPI_D5 | DEBUG_BUS6 | — | UART0_CTS | DB_GPIO39 | GPIO1_A12 | — |
| 34 | `RGMII_RXD1` | `0x104f0090` | `0xe1f0090` | RGMII_RXD1 | DPI_D6 | DEBUG_BUS7 | — | UART0_RTS | DB_GPIO40 | GPIO1_A13 | — |
| 35 | `RGMII_RXDV` | `0x104f009c` | `0xe1f009c` | RGMII_RXDV | DPI_D4 | DEBUG_BUS8 | — | — | DB_GPIO41 | GPIO1_A14 | — |
| 36 | `RGMII_RXCLK` | `0x104f00a8` | `0xe1f00a8` | RGMII_RXCLK | DPI_D3 | DEBUG_BUS9 | — | — | DB_GPIO42 | GPIO1_A15 | — |
| 37 | `RGMII_RXD2` | `0x104f00b4` | `0xe1f00b4` | RGMII_RXD2 | DPI_D7 | — | — | — | DB_GPIO43 | GPIO1_A16 | — |
| 38 | `RGMII_RXD3` | `0x104f00c0` | `0xe1f00c0` | RGMII_RXD3 | DPI_D8 | — | — | — | DB_GPIO44 | GPIO1_A17 | — |
| 39 | `RGMII_TXD0` | `0x104f00cc` | `0xe1f00cc` | RGMII_TXD0 | DPI_D11 | DEBUG_BUS2 | MCLK1 | SPI_M2_MOSI_M | DB_GPIO45 | GPIO1_A18 | — |
| 40 | `RGMII_TXD1` | `0x104f00d8` | `0xe1f00d8` | RGMII_TXD1 | DPI_D12 | DEBUG_BUS3 | SEN_HSYNC_D0_M | SPI_M2_MISO_M | DB_GPIO46 | GPIO1_A19 | — |
| 41 | `RGMII_TXCLK` | `0x104f00e4` | `0xe1f00e4` | RGMII_TXCLK | DPI_D9 | DEBUG_BUS4 | SEN_HSYNC_D1_M | SPI_M2_SCLK_M | DB_GPIO47 | GPIO1_A20 | — |
| 42 | `RGMII_TXEN` | `0x104f00f0` | `0xe1f00f0` | RGMII_TXEN | DPI_D10 | DEBUG_BUS5 | SEN_VSYNC_D0_M | SPI_M2_CS1_M | DB_GPIO48 | GPIO1_A21 | ANALOG_TEST14 |
| 43 | `RGMII_TXD2` | `0x104f00fc` | `0xe1f00fc` | RGMII_TXD2 | DPI_D13 | PWM3_M | SEN_VSYNC_D1_M | — | DB_GPIO49 | GPIO1_A22 | — |
| 44 | `RGMII_TXD3` | `0x104f0108` | `0xe1f0108` | RGMII_TXD3 | DPI_D14 | PWM4_M | SEN_FLASH_D0_M | — | DB_GPIO50 | GPIO1_A23 | — |
| 45 | `SD_DAT0` | `0x104f100c` | `0xe1f100c` | SD_DAT0 | — | DEBUG_BUS10 | — | MCLK2 | DB_GPIO63 | GPIO2_A4 | — |
| 46 | `SD_DAT1` | `0x104f1018` | `0xe1f1018` | SD_DAT1 | — | DEBUG_BUS11 | — | MCLK3 | DB_GPIO64 | GPIO2_A5 | — |
| 47 | `SD_CLK` | `0x104f1024` | `0xe1f1024` | SD_CLK | — | DEBUG_BUS12 | — | — | DB_GPIO65 | GPIO2_A6 | — |
| 48 | `SD_CMD` | `0x104f1030` | `0xe1f1030` | SD_CMD | I2C_S1_SDA | DEBUG_BUS13 | — | — | DB_GPIO66 | GPIO2_A7 | — |
| 49 | `SD_DAT2` | `0x104f103c` | `0xe1f103c` | SD_DAT2 | I2C_S1_SCL | DEBUG_BUS14 | — | MCLK4 | DB_GPIO67 | GPIO2_A8 | — |
| 50 | `SD_DAT3` | `0x104f1048` | `0xe1f1048` | SD_DAT3 | — | DEBUG_BUS15 | — | MCLK5 | DB_GPIO68 | GPIO2_A9 | — |
| 51 | `EMMC_DAT5` | `0x230900c` | `0x900c` | EMMC_DAT5 | — | — | DB_GPIO83 | — | — | GPIO2_A24 | — |
| 52 | `EMMC_RESET_N` | `0x2309018` | `0x9018` | — | — | — | DB_GPIO82 | — | — | GPIO2_A23 | — |
| 53 | `EMMC_DAT4` | `0x2309024` | `0x9024` | EMMC_DAT4 | SFC_CSN1 | — | DB_GPIO84 | — | — | GPIO2_A25 | — |
| 54 | `EMMC_DAT6` | `0x2309030` | `0x9030` | EMMC_DAT6 | — | — | DB_GPIO80 | — | — | GPIO2_A21 | — |
| 55 | `EMMC_DS` | `0x230903c` | `0x903c` | EMMC_DS | — | — | DB_GPIO81 | — | — | GPIO2_A22 | — |
| 56 | `EMMC_DAT7` | `0x2309048` | `0x9048` | EMMC_DAT7 | — | — | DB_GPIO79 | — | — | GPIO2_A20 | — |
| 57 | `EMMC_DAT3` | `0x2309054` | `0x9054` | EMMC_DAT3 | SFC_HOLD_IO3 | — | DB_GPIO85 | — | — | GPIO2_A26 | SPI2AHB_CS |
| 58 | `EMMC_DAT2` | `0x2309060` | `0x9060` | EMMC_DAT2 | SFC_WP_IO2 | — | DB_GPIO86 | — | — | GPIO2_A27 | SPI2AHB_DATA0 |
| 59 | `EMMC_CLK` | `0x230906c` | `0x906c` | EMMC_CLK | SFC_CLK | — | DB_GPIO87 | — | — | GPIO2_A28 | SPI2AHB_DATA1 |
| 60 | `EMMC_DAT0` | `0x2309078` | `0x9078` | EMMC_DAT0 | SFC_MOSI_IO0 | — | DB_GPIO15 | — | — | GPIO0_A20 | SPI2AHB_DATA2 |
| 61 | `EMMC_CMD` | `0x2309084` | `0x9084` | EMMC_CMD | SFC_CSN0 | — | DB_GPIO88 | — | — | GPIO2_A29 | SPI2AHB_DATA3 |
| 62 | `EMMC_DAT1` | `0x2309090` | `0x9090` | EMMC_DAT1 | SFC_MISO_IO1 | — | DB_GPIO89 | — | — | GPIO0_A19 | SPI2AHB_CLK |
| 63 | `SDIO_DAT0` | `0x104f200c` | `0xe1f200c` | SDIO_DAT0 | I2C3_SCL | — | I2S1_DOUT | PWM08 | DB_GPIO57 | GPIO1_A30 | — |
| 64 | `SDIO_DAT1` | `0x104f2018` | `0xe1f2018` | SDIO_DAT1 | I2C3_SDA | — | I2S1_SCLK | PWM09 | DB_GPIO58 | GPIO1_A31 | — |
| 65 | `SDIO_CLK` | `0x104f2024` | `0xe1f2024` | SDIO_CLK | EPHY_CLK_M | I2C2_SCL | I2S1_MCLK | CLK_AUX2_0 | DB_GPIO59 | GPIO2_A0 | — |
| 66 | `SDIO_CMD` | `0x104f2030` | `0xe1f2030` | SDIO_CMD | I2C2_SDA | — | I2S1_LRCK | — | DB_GPIO60 | GPIO2_A1 | — |
| 67 | `SDIO_DAT2` | `0x104f203c` | `0xe1f203c` | SDIO_DAT2 | I2C4_SCL | — | I2S1_DIN1 | — | DB_GPIO61 | GPIO2_A2 | — |
| 68 | `SDIO_DAT3` | `0x104f2048` | `0xe1f2048` | SDIO_DAT3 | I2C4_SDA | — | I2S1_DIN0 | — | DB_GPIO62 | GPIO2_A3 | — |
| 69 | `CDTX_L0N` | `0x230a00c` | `0xa00c` | CDTX_L0N | BT656_CLK | SPI_M0_SCLK | DB_GPIO69 | — | — | GPIO2_A10 | — |
| 70 | `CDTX_L0P` | `0x230a018` | `0xa018` | CDTX_L0P | BT656_D0 | SPI_M0_MISO | DB_GPIO70 | — | — | GPIO2_A11 | — |
| 71 | `CDTX_L1N` | `0x230a024` | `0xa024` | CDTX_L1N | BT656_D1 | SPI_M0_CS0 | DB_GPIO71 | — | — | GPIO2_A12 | — |
| 72 | `CDTX_L1P` | `0x230a030` | `0xa030` | CDTX_L1P | BT656_D2 | SPI_M0_CS1 | DB_GPIO72 | — | — | GPIO2_A13 | — |
| 73 | `CDTX_L2N` | `0x230a03c` | `0xa03c` | CDTX_L2N | BT656_D3 | SPI_M0_CS2 | DB_GPIO73 | — | — | GPIO2_A14 | — |
| 74 | `CDTX_L2P` | `0x230a048` | `0xa048` | CDTX_L2P | BT656_D4 | SPI_M0_MOSI | DB_GPIO74 | — | — | GPIO2_A15 | — |
| 75 | `CDTX_L3N` | `0x230a054` | `0xa054` | CDTX_L3N | BT656_D5 | SPI_M0_CS3 | DB_GPIO75 | — | — | GPIO2_A16 | — |
| 76 | `CDTX_L3P` | `0x230a060` | `0xa060` | CDTX_L3P | BT656_D6 | — | DB_GPIO76 | — | — | GPIO2_A17 | — |
| 77 | `CDTX_L4N` | `0x230a06c` | `0xa06c` | CDTX_L4N | BT656_D7 | — | DB_GPIO77 | — | — | GPIO2_A18 | — |
| 78 | `CDTX_L4P` | `0x230a078` | `0xa078` | CDTX_L4P | — | — | DB_GPIO78 | — | — | GPIO2_A19 | — |
| 79 | `THM_AIN3` | `0x230100c` | `0x100c` | THM_AIN3 | — | — | — | — | DB_GPIO11 | GPIO0_A11 | — |
| 80 | `THM_AIN2` | `0x2301018` | `0x1018` | THM_AIN2 | — | MCLK6 | — | — | DB_GPIO12 | GPIO0_A12 | — |
| 81 | `THM_AIN1` | `0x2301024` | `0x1024` | THM_AIN1 | TIMESTAMP_LOCK_O0 | PWM11 | — | — | DB_GPIO13 | GPIO0_A13 | — |
| 82 | `THM_AIN0` | `0x2301030` | `0x1030` | THM_AIN0 | TIMESTAMP_LOCK_I0 | PWM10 | — | — | DB_GPIO14 | GPIO0_A14 | — |
| 83 | `SD_PWR_SW` | `0x230200c` | `0x200c` | SD_PWR_SW | WDT_THM_RST | — | — | — | DB_GPIO16 | — | — |
| 84 | `GPIO3_A1` | `0x2302018` | `0x2018` | GPIO3_A1 | — | SLEEPOUT | — | — | DB_GPIO18 | — | — |
| 85 | `GPIO3_A2` | `0x2302024` | `0x2024` | GPIO3_A2 | SEN_HSYNC_D0 | — | — | — | DB_GPIO19 | — | — |
| 86 | `GPIO3_A3` | `0x2302030` | `0x2030` | GPIO3_A3 | — | — | — | — | DB_GPIO20 | — | — |
| 87 | `BOND0` | `0x2302048` | `0x2048` | BOND0 | SEN_VSYNC_D1 | UART3_RTS | — | — | — | GPIO0_A15 | — |
| 88 | `BOND1` | `0x2302054` | `0x2054` | BOND1 | SEN_HSYNC_D1 | UART3_CTS | — | — | — | GPIO0_A16 | — |
| 89 | `EMMC_PWR_EN` | `0x2302060` | `0x2060` | EMMC_PWR_EN | — | — | UART1_CTS | — | DB_GPIO17 | GPIO0_A17 | — |
| 90 | `BOND2` | `0x230206c` | `0x206c` | BOND2 | MCLK0 | — | UART1_RTS | — | — | GPIO0_A18 | — |
| 91 | `SYS_RSTN_OUT` | `0x2302078` | `0x2078` | SYS_RSTN_OUT | — | — | — | — | — | — | — |
| 92 | `TMS` | `0x2302090` | `0x2090` | TMS | UART4_TXD | — | — | — | DB_GPIO21 | GPIO0_A21 | — |
| 93 | `TCK` | `0x230209c` | `0x209c` | TCK | UART4_RXD | — | — | — | DB_GPIO22 | GPIO0_A22 | — |
| 94 | `SD_PWR_EN` | `0x23020a8` | `0x20a8` | SD_PWR_EN | — | — | — | — | DB_GPIO23 | GPIO0_A23 | — |
| 95 | `MICP_L_D` | `0x230500c` | `0x500c` | NULL__MICP_L_D | DMIC_DIN | DEBUG_BUS0 | DB_GPIO31 | — | — | GPIO1_A4 | — |
| 96 | `MICN_L_D` | `0x2305018` | `0x5018` | NULL__MICN_L_D | DMIC_CLK | DEBUG_BUS1 | DB_GPIO32 | — | — | GPIO1_A5 | — |
| 97 | `MICN_R_D` | `0x2305024` | `0x5024` | NULL__MICN_R_D | USB_OVRCUR | SEN_HSYNC_D1__MICN_R_D | DB_GPIO33 | — | — | GPIO1_A6 | — |
| 98 | `MICP_R_D` | `0x2305030` | `0x5030` | NULL__MICP_R_D | USB_POWER_EN | — | DB_GPIO34 | — | — | GPIO1_A7 | — |
| 99 | `CDRX_L0N` | `0x230300c` | `0x300c` | CDRX_L0N | VI_D10 | — | — | — | — | — | — |
| 100 | `CDRX_L0P` | `0x2303018` | `0x3018` | CDRX_L0P | VI_D11 | — | — | — | — | — | — |
| 101 | `CDRX_L1N` | `0x2303024` | `0x3024` | CDRX_L1N | VI_D12 | — | — | — | — | — | — |
| 102 | `CDRX_L1P` | `0x2303030` | `0x3030` | CDRX_L1P | VI_D13 | — | — | — | — | — | — |
| 103 | `CDRX_L2N` | `0x230303c` | `0x303c` | CDRX_L2N | VI_D14 | — | — | — | — | — | — |
| 104 | `CDRX_L2P` | `0x2303048` | `0x3048` | CDRX_L2P | VI_D15 | — | — | — | — | — | — |
| 105 | `CDRX_L3N` | `0x2303054` | `0x3054` | CDRX_L3N | VI_D16 | — | — | — | — | — | — |
| 106 | `CDRX_L3P` | `0x2303060` | `0x3060` | CDRX_L3P | VI_D17 | — | — | — | — | — | — |
| 107 | `CDRX_L4N` | `0x230306c` | `0x306c` | CDRX_L4N | VI_D18 | — | — | — | — | — | — |
| 108 | `CDRX_L4P` | `0x2303078` | `0x3078` | CDRX_L4P | VI_D19 | — | — | — | — | — | — |
| 109 | `CDRX_L5N` | `0x2303084` | `0x3084` | CDRX_L5N | VI_CLK1 | — | — | — | — | — | — |
| 110 | `CDRX_L5P` | `0x2303090` | `0x3090` | CDRX_L5P | VI_D20 | — | — | — | — | — | — |

### 2.1 Facts a driver author must not miss

All **V**, from the table above:

* **Populated-function counts** (how many of the 8 values are valid): 8 → 10 pads,
  7 → 14, 6 → 18, 5 → 30, 4 → 14, 3 → 10, 2 → 14, 1 → 1 pad. `SYS_RSTN_OUT`
  (pin 91) has a single valid value; the mux is effectively hard-wired.
* **`EMMC_RESET_N` (pin 52) has no function 0.** It is the only pad whose f=0
  slot is reserved. Writing 0 there is undefined.
* **GPIO is function 6 on 94 pads but function 0 on three** — `GPIO3_A1`,
  `GPIO3_A2`, `GPIO3_A3` (pins 84–86), the only members of GPIO bank 3. A driver
  that hardcodes "GPIO = 6" breaks the rotary encoder.
* **14 pads have no GPIO function at all**: `SD_PWR_SW` (83), `SYS_RSTN_OUT` (91)
  and all twelve `CDRX_*` DPHY-RX pads (99–110). `gpio_request_enable()` must
  fail for these.
* **`DB_GPIO` (the always-on / deep-sleep GPIO domain) is function 5 on most
  pads but function 3 on G11 (eMMC), DPHYTX and G7 (mic)** — 26 pads. Same trap
  as above, one level down.
* **Function-0 is not always the pad's own name.** The four G7 mic pads carry
  `NULL__*` at f=0 (no digital function), and the `CDRX_*` pads carry the D-PHY
  lane itself.
* **DPHY-TX pads need a sequence, not just a mux write.** When a `CDTX_*` pad
  (group DPHYTX, `0x0230A000`) is given a *non-zero* function, the vendor first
  asserts DPHY-TX soft reset (`0x046000B8` bit 6) and clears DPHY-TX MIPI enable
  (`0x023F110C`), then writes the pad word (`ax_pinmux.c:152-158`,
  U-Boot `board/axera/ax620e_emmc/pinmux.c`) (**V**). A mainline driver must
  reproduce this, or the six `CDTX_L0N..L2P` GPIOs the board uses for LED sense
  and the touch panel will not work. Model it as a `syscon` phandle pair on the
  pinctrl node, not as a hidden `ioremap`.

---

## 3. Function collapse: 551 single-group functions → 56 real functions

### 3.1 What the vendor model is, and why it has to go

`ax_pinctrl_build_state()` (`pinctrl-axera.c:283-347`) creates **one group per
pin** (111 groups, each with exactly one pin) and then **one function per
(pin, mux-value) pair** — 551 functions, each with exactly one member group
(**V**; `FUNCTION_MAX 551` in `pinctrl-ax620e.h:28` matches the 551 mux entries
counted in `pinctrl-ax620e.c`). Function names are made globally unique with the
`SIGNAL__PAD` suffix so the flat radix tree works (**V**, all 551 checked unique).

That is not a pin-control model, it is a lookup table with the mux value hidden
inside a string compare (`pinctrl-axera.c:90-94`). It has two concrete
consequences:

* `AX620E_pinctrl.dtsi` needs one state node per (pad, function) pair — 6855
  lines, 563 nodes, of which **12 are dead**: `test_pins`, `hplp_pins`,
  `hpln_pins`, `hprn_pins`, `hprp_pins`, `micp_l_pins`, `micn_l_pins`,
  `vcap_pins`, `mic_bias0_pins`, `mic_bias1_pins`, `micn_r_pins`, `micp_r_pins`
  name pins (`TEST`, `HPLP`, …) that the driver's pin table does not contain, so
  selecting any of them fails at `pinctrl_get_group_selector` (**V**). The
  remaining 551 map 1:1 onto the driver's 551 functions (**V**, checked both
  directions — no state is missing, no function is unreachable).
* A consumer that needs *n* pads must list *n* separate states. `&spi2` in the
  board dts lists six (**V**).

### 3.2 Grouping rule

Applied mechanically to the 551 signal names:

1. Strip the `__PAD` uniqueness suffix — it carries no signal information.
2. Strip a trailing `_M`; an `_M` signal is the **same logical signal on an
   alternate pad**, so it joins its primary's function and contributes another
   member group. (`PWM0_M`, `SPI_M2_SCLK_M`, `RGMII_MDCK_M`, `EPHY_CLK_M`,
   `SEN_*_M` …)
3. Bucket by controller instance, keeping the instance number where the SoC has
   several independent controllers (`i2c0`…`i2c7`, `uart0`…`uart5`, `i2s0`/`i2s1`,
   `spi_m0`/`spi_m1`/`spi_m2`, `i2c_slv0`/`i2c_slv1`).
4. Collapse index suffixes that name *lanes of one bus*, not separate
   controllers (`VI_D0..VI_D20`+`VI_CLK0/1` → `vi`; `DPI_D0..D18`+`DPI_PCLK` →
   `dpi`; `PWM00..PWM11` → `pwm`; `MCLK0..MCLK7` → `mclk`; `GPIO0_A0..GPIO3_A3`
   → `gpio`; `DB_GPIO0..89` → `db_gpio`; `DEBUG_BUS0..15` → `debug_bus`;
   `ANALOG_TEST0..14` → `analog_test`).
5. Group name = lower-case of the collapsed signal family.

Result: **56 functions covering all 551 (pad, mux-value) pairs**, no leftovers,
no pair in two functions. Each function's member list below is the set of
**single-pad groups** it can be selected on, written as `PAD(mux value)`.

Under this model a mainline `.dtsi` state becomes, e.g.:

```dts
i2c7_pins: i2c7-pins {
    function = "i2c7";
    groups = "VI_D8", "VI_D9";     /* or: pins = "VI_D8", "VI_D9"; */
    bias-pull-up;
    drive-strength = <3>;
};
```

instead of the vendor's two nodes each naming a synthetic function.

### 3.3 The 56 functions

| Function | Groups | Member pads (mux value) |
|---|---|---|
| `gpio` | 97 | `VI_D0(6)`, `VI_D1(6)`, `VI_D2(6)`, `VI_D3(6)`, `VI_D4(6)`, `VI_D5(6)`, `VI_D6(6)`, `VI_D7(6)`, `VI_D8(6)`, `VI_D9(6)`, `VI_CLK0(6)`, `I2C0_SCL(6)`, `I2C0_SDA(6)`, `I2C1_SCL(6)`, `I2C1_SDA(6)`, `UART0_TXD(6)`, `UART0_RXD(6)`, `UART1_TXD(6)`, `UART1_RXD(6)`, `UART2_TXD(6)`, `UART2_RXD(6)`, `UART3_TXD(6)`, `UART3_RXD(6)`, `EMAC_PTP_PPS0(6)`, `EMAC_PTP_PPS1(6)`, `EMAC_PTP_PPS2(6)`, `EMAC_PTP_PPS3(6)`, `RGMII_MDCK(6)`, `RGMII_MDIO(6)`, `EPHY_CLK(6)`, `EPHY_RSTN(6)`, `EPHY_LED0(6)`, `EPHY_LED1(6)`, `RGMII_RXD0(6)`, `RGMII_RXD1(6)`, `RGMII_RXDV(6)`, `RGMII_RXCLK(6)`, `RGMII_RXD2(6)`, `RGMII_RXD3(6)`, `RGMII_TXD0(6)`, `RGMII_TXD1(6)`, `RGMII_TXCLK(6)`, `RGMII_TXEN(6)`, `RGMII_TXD2(6)`, `RGMII_TXD3(6)`, `SD_DAT0(6)`, `SD_DAT1(6)`, `SD_CLK(6)`, `SD_CMD(6)`, `SD_DAT2(6)`, `SD_DAT3(6)`, `EMMC_DAT5(6)`, `EMMC_RESET_N(6)`, `EMMC_DAT4(6)`, `EMMC_DAT6(6)`, `EMMC_DS(6)`, `EMMC_DAT7(6)`, `EMMC_DAT3(6)`, `EMMC_DAT2(6)`, `EMMC_CLK(6)`, `EMMC_DAT0(6)`, `EMMC_CMD(6)`, `EMMC_DAT1(6)`, `SDIO_DAT0(6)`, `SDIO_DAT1(6)`, `SDIO_CLK(6)`, `SDIO_CMD(6)`, `SDIO_DAT2(6)`, `SDIO_DAT3(6)`, `CDTX_L0N(6)`, `CDTX_L0P(6)`, `CDTX_L1N(6)`, `CDTX_L1P(6)`, `CDTX_L2N(6)`, `CDTX_L2P(6)`, `CDTX_L3N(6)`, `CDTX_L3P(6)`, `CDTX_L4N(6)`, `CDTX_L4P(6)`, `THM_AIN3(6)`, `THM_AIN2(6)`, `THM_AIN1(6)`, `THM_AIN0(6)`, `GPIO3_A1(0)`, `GPIO3_A2(0)`, `GPIO3_A3(0)`, `BOND0(6)`, `BOND1(6)`, `EMMC_PWR_EN(6)`, `BOND2(6)`, `TMS(6)`, `TCK(6)`, `SD_PWR_EN(6)`, `MICP_L_D(6)`, `MICN_L_D(6)`, `MICN_R_D(6)`, `MICP_R_D(6)` |
| `db_gpio` | 90 | `VI_D0(5)`, `VI_D1(5)`, `VI_D2(5)`, `VI_D3(5)`, `VI_D4(5)`, `VI_D5(5)`, `VI_D6(5)`, `VI_D7(5)`, `VI_D8(5)`, `VI_D9(5)`, `VI_CLK0(5)`, `UART0_TXD(5)`, `UART0_RXD(5)`, `UART1_TXD(5)`, `UART2_TXD(5)`, `UART2_RXD(5)`, `UART3_TXD(5)`, `UART3_RXD(5)`, `EMAC_PTP_PPS0(5)`, `EMAC_PTP_PPS1(5)`, `EMAC_PTP_PPS2(5)`, `EMAC_PTP_PPS3(5)`, `RGMII_MDCK(5)`, `RGMII_MDIO(5)`, `EPHY_CLK(5)`, `EPHY_RSTN(5)`, `EPHY_LED0(5)`, `EPHY_LED1(5)`, `RGMII_RXD0(5)`, `RGMII_RXD1(5)`, `RGMII_RXDV(5)`, `RGMII_RXCLK(5)`, `RGMII_RXD2(5)`, `RGMII_RXD3(5)`, `RGMII_TXD0(5)`, `RGMII_TXD1(5)`, `RGMII_TXCLK(5)`, `RGMII_TXEN(5)`, `RGMII_TXD2(5)`, `RGMII_TXD3(5)`, `SD_DAT0(5)`, `SD_DAT1(5)`, `SD_CLK(5)`, `SD_CMD(5)`, `SD_DAT2(5)`, `SD_DAT3(5)`, `EMMC_DAT5(3)`, `EMMC_RESET_N(3)`, `EMMC_DAT4(3)`, `EMMC_DAT6(3)`, `EMMC_DS(3)`, `EMMC_DAT7(3)`, `EMMC_DAT3(3)`, `EMMC_DAT2(3)`, `EMMC_CLK(3)`, `EMMC_DAT0(3)`, `EMMC_CMD(3)`, `EMMC_DAT1(3)`, `SDIO_DAT0(5)`, `SDIO_DAT1(5)`, `SDIO_CLK(5)`, `SDIO_CMD(5)`, `SDIO_DAT2(5)`, `SDIO_DAT3(5)`, `CDTX_L0N(3)`, `CDTX_L0P(3)`, `CDTX_L1N(3)`, `CDTX_L1P(3)`, `CDTX_L2N(3)`, `CDTX_L2P(3)`, `CDTX_L3N(3)`, `CDTX_L3P(3)`, `CDTX_L4N(3)`, `CDTX_L4P(3)`, `THM_AIN3(5)`, `THM_AIN2(5)`, `THM_AIN1(5)`, `THM_AIN0(5)`, `SD_PWR_SW(5)`, `GPIO3_A1(5)`, `GPIO3_A2(5)`, `GPIO3_A3(5)`, `EMMC_PWR_EN(5)`, `TMS(5)`, `TCK(5)`, `SD_PWR_EN(5)`, `MICP_L_D(3)`, `MICN_L_D(3)`, `MICN_R_D(3)`, `MICP_R_D(3)` |
| `vi` | 23 | `VI_D0(0)`, `VI_D1(0)`, `VI_D2(0)`, `VI_D3(0)`, `VI_D4(0)`, `VI_D5(0)`, `VI_D6(0)`, `VI_D7(0)`, `VI_D8(0)`, `VI_D9(0)`, `VI_CLK0(0)`, `CDRX_L0N(1)`, `CDRX_L0P(1)`, `CDRX_L1N(1)`, `CDRX_L1P(1)`, `CDRX_L2N(1)`, `CDRX_L2P(1)`, `CDRX_L3N(1)`, `CDRX_L3P(1)`, `CDRX_L4N(1)`, `CDRX_L4P(1)`, `CDRX_L5N(1)`, `CDRX_L5P(1)` |
| `sensor_sync` | 23 | `UART1_TXD(4)`, `UART1_RXD(4)`, `UART2_TXD(4)`, `UART2_RXD(4)`, `UART3_TXD(4)`, `UART3_RXD(4)`, `EMAC_PTP_PPS0(4)`, `EMAC_PTP_PPS1(4)`, `RGMII_MDCK(3)`, `RGMII_MDIO(3)`, `EPHY_CLK(3)`, `EPHY_RSTN(3)`, `EPHY_LED0(3)`, `EPHY_LED1(3)`, `RGMII_TXD1(3)`, `RGMII_TXCLK(3)`, `RGMII_TXEN(3)`, `RGMII_TXD2(3)`, `RGMII_TXD3(3)`, `GPIO3_A2(1)`, `BOND0(1)`, `BOND1(1)`, `MICN_R_D(2)` |
| `pwm` | 20 | `I2C0_SCL(3)`, `I2C0_SDA(3)`, `I2C1_SCL(3)`, `I2C1_SDA(3)`, `UART1_TXD(3)`, `UART1_RXD(3)`, `UART3_TXD(3)`, `UART3_RXD(3)`, `EMAC_PTP_PPS0(2)`, `EMAC_PTP_PPS1(2)`, `EMAC_PTP_PPS3(2)`, `RGMII_MDCK(2)`, `RGMII_MDIO(2)`, `EPHY_RSTN(2)`, `RGMII_TXD2(2)`, `RGMII_TXD3(2)`, `SDIO_DAT0(4)`, `SDIO_DAT1(4)`, `THM_AIN1(2)`, `THM_AIN0(2)` |
| `dpi` | 20 | `EMAC_PTP_PPS0(1)`, `EMAC_PTP_PPS1(1)`, `EMAC_PTP_PPS2(1)`, `EMAC_PTP_PPS3(1)`, `RGMII_MDCK(1)`, `RGMII_MDIO(1)`, `EPHY_CLK(1)`, `EPHY_RSTN(1)`, `RGMII_RXD0(1)`, `RGMII_RXD1(1)`, `RGMII_RXDV(1)`, `RGMII_RXCLK(1)`, `RGMII_RXD2(1)`, `RGMII_RXD3(1)`, `RGMII_TXD0(1)`, `RGMII_TXD1(1)`, `RGMII_TXCLK(1)`, `RGMII_TXEN(1)`, `RGMII_TXD2(1)`, `RGMII_TXD3(1)` |
| `rgmii` | 16 | `RGMII_MDCK(0)`, `RGMII_MDIO(0)`, `EPHY_LED0(1)`, `EPHY_LED1(1)`, `RGMII_RXD0(0)`, `RGMII_RXD1(0)`, `RGMII_RXDV(0)`, `RGMII_RXCLK(0)`, `RGMII_RXD2(0)`, `RGMII_RXD3(0)`, `RGMII_TXD0(0)`, `RGMII_TXD1(0)`, `RGMII_TXCLK(0)`, `RGMII_TXEN(0)`, `RGMII_TXD2(0)`, `RGMII_TXD3(0)` |
| `debug_bus` | 16 | `RGMII_RXD0(2)`, `RGMII_RXD1(2)`, `RGMII_RXDV(2)`, `RGMII_RXCLK(2)`, `RGMII_TXD0(2)`, `RGMII_TXD1(2)`, `RGMII_TXCLK(2)`, `RGMII_TXEN(2)`, `SD_DAT0(2)`, `SD_DAT1(2)`, `SD_CLK(2)`, `SD_CMD(2)`, `SD_DAT2(2)`, `SD_DAT3(2)`, `MICP_L_D(2)`, `MICN_L_D(2)` |
| `analog_test` | 15 | `VI_D0(7)`, `VI_D1(7)`, `VI_D2(7)`, `VI_D3(7)`, `VI_D4(7)`, `VI_CLK0(7)`, `I2C0_SCL(7)`, `I2C0_SDA(7)`, `UART0_TXD(7)`, `UART0_RXD(7)`, `UART1_TXD(7)`, `UART1_RXD(7)`, `UART2_TXD(7)`, `UART2_RXD(7)`, `RGMII_TXEN(7)` |
| `spi_m2` | 14 | `I2C0_SCL(1)`, `I2C0_SDA(1)`, `I2C1_SCL(1)`, `I2C1_SDA(1)`, `UART1_TXD(1)`, `UART3_TXD(1)`, `UART3_RXD(1)`, `EPHY_RSTN(4)`, `EPHY_LED0(4)`, `EPHY_LED1(4)`, `RGMII_TXD0(4)`, `RGMII_TXD1(4)`, `RGMII_TXCLK(4)`, `RGMII_TXEN(4)` |
| `dphy_rx` | 12 | `CDRX_L0N(0)`, `CDRX_L0P(0)`, `CDRX_L1N(0)`, `CDRX_L1P(0)`, `CDRX_L2N(0)`, `CDRX_L2P(0)`, `CDRX_L3N(0)`, `CDRX_L3P(0)`, `CDRX_L4N(0)`, `CDRX_L4P(0)`, `CDRX_L5N(0)`, `CDRX_L5P(0)` |
| `clk_aux` | 12 | `VI_D3(3)`, `I2C0_SCL(4)`, `I2C0_SDA(4)`, `I2C1_SCL(4)`, `I2C1_SDA(4)`, `UART1_RXD(2)`, `UART2_TXD(2)`, `UART2_RXD(2)`, `UART3_TXD(2)`, `UART3_RXD(2)`, `EPHY_CLK(2)`, `SDIO_CLK(4)` |
| `emmc` | 11 | `EMMC_DAT5(0)`, `EMMC_DAT4(0)`, `EMMC_DAT6(0)`, `EMMC_DS(0)`, `EMMC_DAT7(0)`, `EMMC_DAT3(0)`, `EMMC_DAT2(0)`, `EMMC_CLK(0)`, `EMMC_DAT0(0)`, `EMMC_CMD(0)`, `EMMC_DAT1(0)` |
| `dphy_tx` | 10 | `CDTX_L0N(0)`, `CDTX_L0P(0)`, `CDTX_L1N(0)`, `CDTX_L1P(0)`, `CDTX_L2N(0)`, `CDTX_L2P(0)`, `CDTX_L3N(0)`, `CDTX_L3P(0)`, `CDTX_L4N(0)`, `CDTX_L4P(0)` |
| `infrared` | 9 | `VI_D0(1)`, `VI_D1(1)`, `VI_D2(1)`, `VI_D3(1)`, `VI_D4(1)`, `VI_D6(1)`, `VI_D7(1)`, `VI_D8(1)`, `VI_D9(1)` |
| `bt656` | 9 | `CDTX_L0N(1)`, `CDTX_L0P(1)`, `CDTX_L1N(1)`, `CDTX_L1P(1)`, `CDTX_L2N(1)`, `CDTX_L2P(1)`, `CDTX_L3N(1)`, `CDTX_L3P(1)`, `CDTX_L4N(1)` |
| `mclk` | 8 | `UART1_RXD(1)`, `RGMII_TXD0(3)`, `SD_DAT0(4)`, `SD_DAT1(4)`, `SD_DAT2(4)`, `SD_DAT3(4)`, `THM_AIN2(2)`, `BOND2(1)` |
| `spi_m1` | 7 | `VI_D0(2)`, `VI_D1(2)`, `VI_D2(2)`, `VI_D3(2)`, `VI_D4(2)`, `VI_D7(3)`, `VI_CLK0(1)` |
| `spi_m0` | 7 | `CDTX_L0N(2)`, `CDTX_L0P(2)`, `CDTX_L1N(2)`, `CDTX_L1P(2)`, `CDTX_L2N(2)`, `CDTX_L2P(2)`, `CDTX_L3N(2)` |
| `sfc` | 7 | `EMMC_DAT4(1)`, `EMMC_DAT3(1)`, `EMMC_DAT2(1)`, `EMMC_CLK(1)`, `EMMC_DAT0(1)`, `EMMC_CMD(1)`, `EMMC_DAT1(1)` |
| `spi_s` | 6 | `VI_D5(2)`, `VI_D6(2)`, `VI_D7(2)`, `VI_D8(2)`, `VI_D9(2)`, `VI_CLK0(2)` |
| `spi2ahb` | 6 | `EMMC_DAT3(7)`, `EMMC_DAT2(7)`, `EMMC_CLK(7)`, `EMMC_DAT0(7)`, `EMMC_CMD(7)`, `EMMC_DAT1(7)` |
| `sdio` | 6 | `SDIO_DAT0(0)`, `SDIO_DAT1(0)`, `SDIO_CLK(0)`, `SDIO_CMD(0)`, `SDIO_DAT2(0)`, `SDIO_DAT3(0)` |
| `sd` | 6 | `SD_DAT0(0)`, `SD_DAT1(0)`, `SD_CLK(0)`, `SD_CMD(0)`, `SD_DAT2(0)`, `SD_DAT3(0)` |
| `i2s1` | 6 | `SDIO_DAT0(3)`, `SDIO_DAT1(3)`, `SDIO_CLK(3)`, `SDIO_CMD(3)`, `SDIO_DAT2(3)`, `SDIO_DAT3(3)` |
| `i2s0` | 6 | `VI_D0(4)`, `VI_D1(4)`, `VI_D2(4)`, `VI_D3(4)`, `VI_D4(4)`, `VI_CLK0(4)` |
| `risc_jtag` | 5 | `I2C0_SCL(2)`, `I2C0_SDA(2)`, `UART0_TXD(2)`, `UART0_RXD(2)`, `UART1_TXD(2)` |
| `ephy` | 5 | `EPHY_CLK(0)`, `EPHY_RSTN(0)`, `EPHY_LED0(0)`, `EPHY_LED1(0)`, `SDIO_CLK(1)` |
| `uart5` | 4 | `EMAC_PTP_PPS0(3)`, `EMAC_PTP_PPS1(3)`, `EMAC_PTP_PPS2(3)`, `EMAC_PTP_PPS3(3)` |
| `uart4` | 4 | `I2C1_SCL(5)`, `I2C1_SDA(5)`, `TMS(1)`, `TCK(1)` |
| `uart3` | 4 | `UART3_TXD(0)`, `UART3_RXD(0)`, `BOND0(2)`, `BOND1(2)` |
| `uart2` | 4 | `I2C0_SCL(5)`, `I2C0_SDA(5)`, `UART2_TXD(0)`, `UART2_RXD(0)` |
| `uart1` | 4 | `UART1_TXD(0)`, `UART1_RXD(0)`, `EMMC_PWR_EN(3)`, `BOND2(3)` |
| `uart0` | 4 | `UART0_TXD(0)`, `UART0_RXD(0)`, `RGMII_RXD0(4)`, `RGMII_RXD1(4)` |
| `timestamp` | 4 | `UART2_TXD(3)`, `UART2_RXD(3)`, `THM_AIN1(1)`, `THM_AIN0(1)` |
| `thermal_ain` | 4 | `THM_AIN3(0)`, `THM_AIN2(0)`, `THM_AIN1(0)`, `THM_AIN0(0)` |
| `sysctl` | 4 | `VI_D2(3)`, `SD_PWR_SW(1)`, `GPIO3_A1(2)`, `SYS_RSTN_OUT(0)` |
| `reserved_analog` | 4 | `MICP_L_D(0)`, `MICN_L_D(0)`, `MICN_R_D(0)`, `MICP_R_D(0)` |
| `emac_pps` | 4 | `EMAC_PTP_PPS0(0)`, `EMAC_PTP_PPS1(0)`, `EMAC_PTP_PPS2(0)`, `EMAC_PTP_PPS3(0)` |
| `sd_ctrl` | 3 | `EMAC_PTP_PPS2(2)`, `SD_PWR_SW(0)`, `SD_PWR_EN(0)` |
| `bond` | 3 | `BOND0(0)`, `BOND1(0)`, `BOND2(0)` |
| `usb` | 2 | `MICN_R_D(1)`, `MICP_R_D(1)` |
| `lcd_te` | 2 | `EPHY_LED0(2)`, `EPHY_LED1(2)` |
| `jtag` | 2 | `TMS(0)`, `TCK(0)` |
| `i2c_slv1` | 2 | `SD_CMD(1)`, `SD_DAT2(1)` |
| `i2c_slv0` | 2 | `VI_D5(3)`, `VI_D6(3)` |
| `i2c7` | 2 | `VI_D8(3)`, `VI_D9(3)` |
| `i2c6` | 2 | `VI_D0(3)`, `VI_D1(3)` |
| `i2c5` | 2 | `VI_D4(3)`, `VI_CLK0(3)` |
| `i2c4` | 2 | `SDIO_DAT2(1)`, `SDIO_DAT3(1)` |
| `i2c3` | 2 | `SDIO_DAT0(1)`, `SDIO_DAT1(1)` |
| `i2c2` | 2 | `SDIO_CLK(2)`, `SDIO_CMD(1)` |
| `i2c1` | 2 | `I2C1_SCL(0)`, `I2C1_SDA(0)` |
| `i2c0` | 2 | `I2C0_SCL(0)`, `I2C0_SDA(0)` |
| `dmic` | 2 | `MICP_L_D(1)`, `MICN_L_D(1)` |
| `emmc_pwr_en` | 1 | `EMMC_PWR_EN(0)` |

---

## 4. The DEMO table

### 4.1 What it is and when it runs

`ax_pinmux.c` registers its own platform device and driver from an
`arch_initcall` (`ax_pinmux.c:209-221`) and its probe replays a static
`<addr, value>` array chosen by board ID read from `MISC_INFO_ADDR`
(`ax_pinmux.c:53-63, 107-170`) (**V**). The arrays are **not in the kernel tree**
— the Makefile pulls them from `${HOME_PATH}/build/projects/${PROJECT}/pinmux/`
(`[K]/drivers/soc/axera/pinmux/Makefile`) (**V**). For this board that is
`AX630C_DEMO_pinmux.h` in the SDK's
`AX630C_emmc_arm64_k419_sipeed_nanokvm` project, reached through Sipeed's board-ID
aliasing (`ax_pinmux.c:75-105`, marked `### SIPEED EDIT ###`) (**V**).

**U-Boot applies the identical array first**, from
`[S]/boot/uboot/u-boot-2020.04/board/axera/ax620e_emmc/pinmux.c`, which
`#include`s the same header from the same project directory and runs the same
loop (**V**). Both passes are one-shot; nothing re-applies the table afterwards.

Before the replay, `ax_pinmux_probe()` also writes `BIT(1)` to `0x023040A8`
(G6 sleep-mode enable, §1.5) (**V**).

The table is **133 `<addr, value>` pairs**, not ~66: **22 group-MISC writes**
(a CLR of `0x0F` then a SET of `0x201` for each of the 11 groups) and **111 pad
writes — exactly one per pad, all 111 of them** (**V**, decoded and cross-checked
against the driver's pad table; every address resolves to a known pad and every
function value is valid for that pad).

Sipeed's table differs from Axera's stock `AX630C_emmc_arm64_k419` table in **54 of
the 111 pad entries** and in none of the 22 group writes (**V**, diffed). The whole
VI group is repurposed: `VI_D0`→SPI_M1, `VI_D1`/`VI_D3`/`VI_D4`/`VI_CLK0`→I2S0,
`VI_D5`/`VI_D6`/`VI_D7`→GPIO,
`VI_D8`/`VI_D9`→I2C7, only `VI_D2` left as `VI_D2`. **`0x02300060 = 0x00060003`
(VI_D7 → GPIO0_A7, drive 3, no pull) exists only on the NanoKVM boards** — every
other project's table has `0x00000003` (VI_D7 → VI_D7) there (**V**).

**Comment trap:** the header's `/* Fuction = … */` comments are generator output
and are not always right. `0x104F0054 = 0x00060003` is commented
`Fuction = EPHY_CLK` but function 6 on the `EPHY_CLK` pad is `GPIO1_A26` (**V**).
That is the only wrong comment of the 111; decode the value, never trust the text.

### 4.2 Every entry, decoded and classified

`Owner` = which node should carry the state in mainline; `soc:` = SoC `.dtsi`
peripheral node, `board:` = board `.dts` consumer.

Classification:

* **a** — the exact function **and** electrical config already exist as a state in
  `AX620E_pinctrl.dtsi`; mainline can reference that state as-is. **58 entries.**
* **b** — the function exists as a state but the DEMO's electrical config differs
  from it; a corrected state must be generated. The existing state's values are
  quoted so the delta is visible. **40 entries.**
* **c** — no in-kernel consumer at all; belongs in the **board dts** as an
  explicit default (a `gpio-hog`, or a `pinctrl-0` on the pinctrl node itself).
  **35 entries** = the 22 group-MISC writes + 13 unclaimed pads.

| Address | Value | Pad | f | Signal | Config | Owner | Class |
|---|---|---|---|---|---|---|---|
| `0x02300008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x02300004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x0230000C` | `0x00020043` | VI_D0 | 2 | `SPI_M1_MOSI` | drv 3, sch 0, pull down | board:spi1 | **b** `vi_d0_spi_m1_mosi_pins` = drv 3/sch 0/pull none |
| `0x02300018` | `0x00040003` | VI_D1 | 4 | `I2S0_SCLK` | drv 3, sch 0, pull — | board:i2s_slv0 | **a** `vi_d1_i2s0_sclk_pins` |
| `0x02300024` | `0x00000003` | VI_D2 | 0 | `VI_D2` | drv 3, sch 0, pull — | _unclaimed_ | **c** |
| `0x02300030` | `0x00040003` | VI_D3 | 4 | `I2S0_MCLK` | drv 3, sch 0, pull — | board:i2s_slv0 | **a** `vi_d3_i2s0_mclk_pins` |
| `0x0230003C` | `0x00040003` | VI_D4 | 4 | `I2S0_DIN1` | drv 3, sch 0, pull — | board:i2s_slv0 | **a** `vi_d4_i2s0_din1_pins` |
| `0x02300048` | `0x00060003` | VI_D5 | 6 | `GPIO0_A5` | drv 3, sch 0, pull — | board:lt6911-pwr(gpio) | **a** `vi_d5_gpio0_a5_pins` |
| `0x02300054` | `0x00060003` | VI_D6 | 6 | `GPIO0_A6` | drv 3, sch 0, pull — | board:lt86102-pwr(gpio) | **a** `vi_d6_gpio0_a6_pins` |
| `0x02300060` | `0x00060003` | VI_D7 | 6 | `GPIO0_A7` | drv 3, sch 0, pull — | board:atx-power(gpio) | **a** `vi_d7_gpio0_a7_pins` |
| `0x0230006C` | `0x00030083` | VI_D8 | 3 | `I2C7_SCL` | drv 3, sch 0, pull up | soc:i2c7 | **a** `vi_d8_i2c7_scl_pins` |
| `0x02300078` | `0x00030083` | VI_D9 | 3 | `I2C7_SDA` | drv 3, sch 0, pull up | soc:i2c7 | **a** `vi_d9_i2c7_sda_pins` |
| `0x02300084` | `0x00040003` | VI_CLK0 | 4 | `I2S0_LRCK` | drv 3, sch 0, pull — | board:i2s_slv0 | **a** `vi_clk0_i2s0_lrck_pins` |
| `0x02304008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x02304004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x0230400C` | `0x00000083` | I2C0_SCL | 0 | `I2C0_SCL` | drv 3, sch 0, pull up | soc:i2c0 | **a** `i2c0_scl_pins` |
| `0x02304018` | `0x00000083` | I2C0_SDA | 0 | `I2C0_SDA` | drv 3, sch 0, pull up | soc:i2c0 | **a** `i2c0_sda_pins` |
| `0x02304024` | `0x00010083` | I2C1_SCL | 1 | `SPI_M2_SCLK` | drv 3, sch 0, pull up | board:spi2 | **b** `i2c1_scl_spi_m2_sclk_pins` = drv 3/sch 0/pull none |
| `0x02304030` | `0x00060083` | I2C1_SDA | 6 | `GPIO0_A27` | drv 3, sch 0, pull up | board:spi2-cs1(gpio) | **b** `i2c1_sda_gpio0_a27_pins` = drv 3/sch 0/pull none |
| `0x0230403C` | `0x00000083` | UART0_TXD | 0 | `UART0_TXD` | drv 3, sch 0, pull up | soc:uart0 | **a** `uart0_txd_pins` |
| `0x02304048` | `0x00000083` | UART0_RXD | 0 | `UART0_RXD` | drv 3, sch 0, pull up | soc:uart0 | **a** `uart0_rxd_pins` |
| `0x02304054` | `0x00000083` | UART1_TXD | 0 | `UART1_TXD` | drv 3, sch 0, pull up | soc:uart1 | **a** `uart1_txd_pins` |
| `0x02304060` | `0x00000083` | UART1_RXD | 0 | `UART1_RXD` | drv 3, sch 0, pull up | soc:uart1 | **a** `uart1_rxd_pins` |
| `0x0230406C` | `0x00000083` | UART2_TXD | 0 | `UART2_TXD` | drv 3, sch 0, pull up | soc:uart2 | **a** `uart2_txd_pins` |
| `0x02304078` | `0x00000083` | UART2_RXD | 0 | `UART2_RXD` | drv 3, sch 0, pull up | soc:uart2 | **a** `uart2_rxd_pins` |
| `0x02304084` | `0x00010083` | UART3_TXD | 1 | `SPI_M2_MOSI` | drv 3, sch 0, pull up | board:spi2 | **b** `uart3_txd_spi_m2_mosi_pins` = drv 3/sch 0/pull none |
| `0x02304090` | `0x00060003` | UART3_RXD | 6 | `GPIO1_A3` | drv 3, sch 0, pull — | board:atx-reset(gpio) | **a** `uart3_rxd_gpio1_a3_pins` |
| `0x104F0008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x104F0004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x104F000C` | `0x00060003` | EMAC_PTP_PPS0 | 6 | `GPIO1_A8` | drv 3, sch 0, pull — | board:pwm0 (DT overrides to PWM0_M) | **a** `emac_ptp_pps0_gpio1_a8_pins` |
| `0x104F0018` | `0x00060003` | EMAC_PTP_PPS1 | 6 | `GPIO1_A9` | drv 3, sch 0, pull — | board:panel-reset(gpio) | **a** `emac_ptp_pps1_gpio1_a9_pins` |
| `0x104F0024` | `0x00060003` | EMAC_PTP_PPS2 | 6 | `GPIO1_A10` | drv 3, sch 0, pull — | _unclaimed_ | **c** |
| `0x104F0030` | `0x00060003` | EMAC_PTP_PPS3 | 6 | `GPIO1_A11` | drv 3, sch 0, pull — | board:panel-dc(gpio) | **a** `emac_ptp_pps3_gpio1_a11_pins` |
| `0x104F003C` | `0x0000000F` | RGMII_MDCK | 0 | `RGMII_MDCK` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_mdck_pins` = drv 3/sch 0/pull none |
| `0x104F0048` | `0x0000000F` | RGMII_MDIO | 0 | `RGMII_MDIO` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_mdio_pins` = drv 3/sch 0/pull up |
| `0x104F0054` | `0x00060003` | EPHY_CLK | 6 | `GPIO1_A26` | drv 3, sch 0, pull — | _unclaimed_ | **c** |
| `0x104F0060` | `0x00060008` | EPHY_RSTN | 6 | `GPIO1_A27` | drv 8, sch 0, pull — | board:eth-phy-reset(gpio) | **b** `ephy_rstn_gpio1_a27_pins` = drv 3/sch 0/pull none |
| `0x104F006C` | `0x00000083` | EPHY_LED0 | 0 | `EPHY_LED0` | drv 3, sch 0, pull up | board:lt6911-int(gpio) | **b** `ephy_led0_pins` = drv 3/sch 0/pull none |
| `0x104F0078` | `0x00060003` | EPHY_LED1 | 6 | `GPIO1_A29` | drv 3, sch 0, pull — | board:wifi-reset(gpio) | **a** `ephy_led1_gpio1_a29_pins` |
| `0x104F0084` | `0x0000000F` | RGMII_RXD0 | 0 | `RGMII_RXD0` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_rxd0_pins` = drv 3/sch 0/pull none |
| `0x104F0090` | `0x0000000F` | RGMII_RXD1 | 0 | `RGMII_RXD1` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_rxd1_pins` = drv 3/sch 0/pull none |
| `0x104F009C` | `0x0000000F` | RGMII_RXDV | 0 | `RGMII_RXDV` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_rxdv_pins` = drv 3/sch 0/pull none |
| `0x104F00A8` | `0x0000000F` | RGMII_RXCLK | 0 | `RGMII_RXCLK` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_rxclk_pins` = drv 3/sch 0/pull none |
| `0x104F00B4` | `0x0000000F` | RGMII_RXD2 | 0 | `RGMII_RXD2` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_rxd2_pins` = drv 3/sch 0/pull none |
| `0x104F00C0` | `0x0000000F` | RGMII_RXD3 | 0 | `RGMII_RXD3` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_rxd3_pins` = drv 3/sch 0/pull none |
| `0x104F00CC` | `0x0000000F` | RGMII_TXD0 | 0 | `RGMII_TXD0` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_txd0_pins` = drv 3/sch 0/pull none |
| `0x104F00D8` | `0x0000000F` | RGMII_TXD1 | 0 | `RGMII_TXD1` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_txd1_pins` = drv 3/sch 0/pull none |
| `0x104F00E4` | `0x0000000F` | RGMII_TXCLK | 0 | `RGMII_TXCLK` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_txclk_pins` = drv 3/sch 0/pull none |
| `0x104F00F0` | `0x0000000F` | RGMII_TXEN | 0 | `RGMII_TXEN` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_txen_pins` = drv 3/sch 0/pull none |
| `0x104F00FC` | `0x0000000F` | RGMII_TXD2 | 0 | `RGMII_TXD2` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_txd2_pins` = drv 3/sch 0/pull none |
| `0x104F0108` | `0x0000000F` | RGMII_TXD3 | 0 | `RGMII_TXD3` | drv 15, sch 0, pull — | soc:eth0 | **b** `rgmii_txd3_pins` = drv 3/sch 0/pull none |
| `0x104F1008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x104F1004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x104F100C` | `0x00000005` | SD_DAT0 | 0 | `SD_DAT0` | drv 5, sch 0, pull — | soc:mmc1 | **b** `sd_dat0_pins` = drv 3/sch 0/pull up |
| `0x104F1018` | `0x00000005` | SD_DAT1 | 0 | `SD_DAT1` | drv 5, sch 0, pull — | soc:mmc1 | **b** `sd_dat1_pins` = drv 3/sch 0/pull up |
| `0x104F1024` | `0x00000005` | SD_CLK | 0 | `SD_CLK` | drv 5, sch 0, pull — | soc:mmc1 | **b** `sd_clk_pins` = drv 3/sch 0/pull none |
| `0x104F1030` | `0x00000005` | SD_CMD | 0 | `SD_CMD` | drv 5, sch 0, pull — | soc:mmc1 | **b** `sd_cmd_pins` = drv 3/sch 0/pull up |
| `0x104F103C` | `0x00000005` | SD_DAT2 | 0 | `SD_DAT2` | drv 5, sch 0, pull — | soc:mmc1 | **b** `sd_dat2_pins` = drv 3/sch 0/pull up |
| `0x104F1048` | `0x00000005` | SD_DAT3 | 0 | `SD_DAT3` | drv 5, sch 0, pull — | soc:mmc1 | **b** `sd_dat3_pins` = drv 3/sch 0/pull up |
| `0x02309008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x02309004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x0230900C` | `0x00000083` | EMMC_DAT5 | 0 | `EMMC_DAT5` | drv 3, sch 0, pull up | soc:mmc0 | **a** `emmc_dat5_pins` |
| `0x02309018` | `0x00060083` | EMMC_RESET_N | 6 | `GPIO2_A23` | drv 3, sch 0, pull up | board:emmc-hw-reset(gpio) | **b** `emmc_reset_n_gpio2_a23_pins` = drv 3/sch 0/pull none |
| `0x02309024` | `0x00000083` | EMMC_DAT4 | 0 | `EMMC_DAT4` | drv 3, sch 0, pull up | soc:mmc0 | **a** `emmc_dat4_pins` |
| `0x02309030` | `0x00000083` | EMMC_DAT6 | 0 | `EMMC_DAT6` | drv 3, sch 0, pull up | soc:mmc0 | **a** `emmc_dat6_pins` |
| `0x0230903C` | `0x00000043` | EMMC_DS | 0 | `EMMC_DS` | drv 3, sch 0, pull down | soc:mmc0 | **b** `emmc_ds_pins` = drv 3/sch 0/pull none |
| `0x02309048` | `0x00000083` | EMMC_DAT7 | 0 | `EMMC_DAT7` | drv 3, sch 0, pull up | soc:mmc0 | **a** `emmc_dat7_pins` |
| `0x02309054` | `0x00000083` | EMMC_DAT3 | 0 | `EMMC_DAT3` | drv 3, sch 0, pull up | soc:mmc0 | **a** `emmc_dat3_pins` |
| `0x02309060` | `0x00000083` | EMMC_DAT2 | 0 | `EMMC_DAT2` | drv 3, sch 0, pull up | soc:mmc0 | **a** `emmc_dat2_pins` |
| `0x0230906C` | `0x00000003` | EMMC_CLK | 0 | `EMMC_CLK` | drv 3, sch 0, pull — | soc:mmc0 | **a** `emmc_clk_pins` |
| `0x02309078` | `0x00000083` | EMMC_DAT0 | 0 | `EMMC_DAT0` | drv 3, sch 0, pull up | soc:mmc0 | **a** `emmc_dat0_pins` |
| `0x02309084` | `0x00000083` | EMMC_CMD | 0 | `EMMC_CMD` | drv 3, sch 0, pull up | soc:mmc0 | **b** `emmc_cmd_pins` = drv 3/sch 0/pull down |
| `0x02309090` | `0x00000083` | EMMC_DAT1 | 0 | `EMMC_DAT1` | drv 3, sch 0, pull up | soc:mmc0 | **a** `emmc_dat1_pins` |
| `0x104F2008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x104F2004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x104F200C` | `0x00000008` | SDIO_DAT0 | 0 | `SDIO_DAT0` | drv 8, sch 0, pull — | soc:mmc2 | **b** `sdio_dat0_pins` = drv 3/sch 0/pull none |
| `0x104F2018` | `0x00000008` | SDIO_DAT1 | 0 | `SDIO_DAT1` | drv 8, sch 0, pull — | soc:mmc2 | **b** `sdio_dat1_pins` = drv 3/sch 0/pull none |
| `0x104F2024` | `0x00000008` | SDIO_CLK | 0 | `SDIO_CLK` | drv 8, sch 0, pull — | soc:mmc2 | **b** `sdio_clk_pins` = drv 3/sch 0/pull none |
| `0x104F2030` | `0x00000008` | SDIO_CMD | 0 | `SDIO_CMD` | drv 8, sch 0, pull — | soc:mmc2 | **b** `sdio_cmd_pins` = drv 3/sch 0/pull none |
| `0x104F203C` | `0x00000008` | SDIO_DAT2 | 0 | `SDIO_DAT2` | drv 8, sch 0, pull — | soc:mmc2 | **b** `sdio_dat2_pins` = drv 3/sch 0/pull none |
| `0x104F2048` | `0x00000008` | SDIO_DAT3 | 0 | `SDIO_DAT3` | drv 8, sch 0, pull — | soc:mmc2 | **b** `sdio_dat3_pins` = drv 3/sch 0/pull none |
| `0x0230A008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x0230A004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x0230A00C` | `0x00060003` | CDTX_L0N | 6 | `GPIO2_A10` | drv 3, sch 0, pull — | board:hdd-led-sense(gpio) | **a** `cdtx_l0n_gpio2_a10_pins` |
| `0x0230A018` | `0x00060003` | CDTX_L0P | 6 | `GPIO2_A11` | drv 3, sch 0, pull — | board:pwr-led-sense(gpio) | **a** `cdtx_l0p_gpio2_a11_pins` |
| `0x0230A024` | `0x00060003` | CDTX_L1N | 6 | `GPIO2_A12` | drv 3, sch 0, pull — | _unclaimed_ | **c** |
| `0x0230A030` | `0x00060003` | CDTX_L1P | 6 | `GPIO2_A13` | drv 3, sch 0, pull — | board:panel-te(gpio) | **a** `cdtx_l1p_gpio2_a13_pins` |
| `0x0230A03C` | `0x00060003` | CDTX_L2N | 6 | `GPIO2_A14` | drv 3, sch 0, pull — | board:touch-reset(gpio) | **a** `cdtx_l2n_gpio2_a14_pins` |
| `0x0230A048` | `0x00060003` | CDTX_L2P | 6 | `GPIO2_A15` | drv 3, sch 0, pull — | board:touch-irq(gpio) | **a** `cdtx_l2p_gpio2_a15_pins` |
| `0x0230A054` | `0x00000003` | CDTX_L3N | 0 | `CDTX_L3N` | drv 3, sch 0, pull — | _unclaimed_ | **c** |
| `0x0230A060` | `0x00000003` | CDTX_L3P | 0 | `CDTX_L3P` | drv 3, sch 0, pull — | board:lt86102-loop-ctrl(gpio) | **a** `cdtx_l3p_pins` |
| `0x0230A06C` | `0x00000003` | CDTX_L4N | 0 | `CDTX_L4N` | drv 3, sch 0, pull — | board:lt86102-hdmi-rxi(gpio) | **a** `cdtx_l4n_pins` |
| `0x0230A078` | `0x00000003` | CDTX_L4P | 0 | `CDTX_L4P` | drv 3, sch 0, pull — | board:lt86102-hdmi-txi(gpio) | **a** `cdtx_l4p_pins` |
| `0x02301008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x02301004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x0230100C` | `0x00050043` | THM_AIN3 | 5 | `DB_GPIO11` | drv 3, sch 0, pull down | board:deb_gpio_lp | **b** `thm_ain3_db_gpio11_pins` = drv 3/sch 0/pull none |
| `0x02301018` | `0x00000003` | THM_AIN2 | 0 | `THM_AIN2` | drv 3, sch 0, pull — | soc:tsensor | **a** `thm_ain2_pins` |
| `0x02301024` | `0x00020003` | THM_AIN1 | 2 | `PWM11` | drv 3, sch 0, pull — | _unclaimed_ | **c** |
| `0x02301030` | `0x00000003` | THM_AIN0 | 0 | `THM_AIN0` | drv 3, sch 0, pull — | soc:tsensor | **a** `thm_ain0_pins` |
| `0x02302008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x02302004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x0230200C` | `0x00000003` | SD_PWR_SW | 0 | `SD_PWR_SW` | drv 3, sch 0, pull — | _unclaimed_ | **c** |
| `0x02302018` | `0x00000003` | GPIO3_A1 | 0 | `GPIO3_A1` | drv 3, sch 0, pull — | board:rotary-a(gpio) | **a** `gpio3_a1_pins` |
| `0x02302024` | `0x00000003` | GPIO3_A2 | 0 | `GPIO3_A2` | drv 3, sch 0, pull — | _unclaimed_ | **c** |
| `0x02302030` | `0x00000013` | GPIO3_A3 | 0 | `GPIO3_A3` | drv 3, sch 1, pull — | _unclaimed_ | **c** |
| `0x02302048` | `0x00000013` | BOND0 | 0 | `BOND0` | drv 3, sch 1, pull — | _unclaimed_ | **c** |
| `0x02302054` | `0x00000013` | BOND1 | 0 | `BOND1` | drv 3, sch 1, pull — | _unclaimed_ | **c** |
| `0x02302060` | `0x00000003` | EMMC_PWR_EN | 0 | `EMMC_PWR_EN` | drv 3, sch 0, pull — | _unclaimed_ | **c** |
| `0x0230206C` | `0x00060003` | BOND2 | 6 | `GPIO0_A18` | drv 3, sch 0, pull — | board:rotary-b(gpio) | **a** `bond2_gpio0_a18_pins` |
| `0x02302078` | `0x00000043` | SYS_RSTN_OUT | 0 | `SYS_RSTN_OUT` | drv 3, sch 0, pull down | _unclaimed_ | **c** |
| `0x02302090` | `0x00060003` | TMS | 6 | `GPIO0_A21` | drv 3, sch 0, pull — | board:lt86102-hdmi-txo(gpio) | **a** `tms_gpio0_a21_pins` |
| `0x0230209C` | `0x00060003` | TCK | 6 | `GPIO0_A22` | drv 3, sch 0, pull — | board:knob-button(gpio) | **a** `tck_gpio0_a22_pins` |
| `0x023020A8` | `0x00060003` | SD_PWR_EN | 6 | `GPIO0_A23` | drv 3, sch 0, pull — | board:heartbeat-led(gpio) | **a** `sd_pwr_en_gpio0_a23_pins` |
| `0x02305008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x02305004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x0230500C` | `0x00060083` | MICP_L_D | 6 | `GPIO1_A4` | drv 3, sch 0, pull up | board:usb-extcon-id(gpio) | **b** `micp_l_d_gpio1_a4_pins` = drv 3/sch 0/pull none |
| `0x02305018` | `0x00060000` | MICN_L_D | 6 | `GPIO1_A5` | drv 0, sch 0, pull — | board:audio-mic(gpio) | **b** `micn_l_d_gpio1_a5_pins` = drv 3/sch 0/pull none |
| `0x02305024` | `0x00060000` | MICN_R_D | 6 | `GPIO1_A6` | drv 0, sch 0, pull — | board:audio-mic(gpio) | **b** `micn_r_d_gpio1_a6_pins` = drv 3/sch 0/pull none |
| `0x02305030` | `0x00060000` | MICP_R_D | 6 | `GPIO1_A7` | drv 0, sch 0, pull — | board:audio-mic(gpio) | **b** `micp_r_d_gpio1_a7_pins` = drv 3/sch 0/pull none |
| `0x02303008` | `0x0000000f` | — | — | — | — | group MISC0 CLR alias | **c** |
| `0x02303004` | `0x00000201` | — | — | — | — | group MISC0 SET alias | **c** |
| `0x0230300C` | `0x00000000` | CDRX_L0N | 0 | `CDRX_L0N` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l0n_pins` |
| `0x02303018` | `0x00000000` | CDRX_L0P | 0 | `CDRX_L0P` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l0p_pins` |
| `0x02303024` | `0x00000000` | CDRX_L1N | 0 | `CDRX_L1N` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l1n_pins` |
| `0x02303030` | `0x00000000` | CDRX_L1P | 0 | `CDRX_L1P` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l1p_pins` |
| `0x0230303C` | `0x00000000` | CDRX_L2N | 0 | `CDRX_L2N` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l2n_pins` |
| `0x02303048` | `0x00000000` | CDRX_L2P | 0 | `CDRX_L2P` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l2p_pins` |
| `0x02303054` | `0x00000000` | CDRX_L3N | 0 | `CDRX_L3N` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l3n_pins` |
| `0x02303060` | `0x00000000` | CDRX_L3P | 0 | `CDRX_L3P` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l3p_pins` |
| `0x0230306C` | `0x00000000` | CDRX_L4N | 0 | `CDRX_L4N` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l4n_pins` |
| `0x02303078` | `0x00000000` | CDRX_L4P | 0 | `CDRX_L4P` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l4p_pins` |
| `0x02303084` | `0x00000000` | CDRX_L5N | 0 | `CDRX_L5N` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l5n_pins` |
| `0x02303090` | `0x00000000` | CDRX_L5P | 0 | `CDRX_L5P` | drv 0, sch 0, pull — | soc:csi-rx | **a** `cdrx_l5p_pins` |

\* `up\*` = both pull bits set (`0xC0`); in groups G2/G5/G7 that is the EN+SE
pull-up encoding (§1.4). It occurs on no entry in this table — every DEMO pull-up
is bit 7 only.

### 4.3 What this means for the port

* **40 of the 111 pad writes need a DT state that does not exist today.** In
  every one of the 40 the *function* is right and only the electrical config is
  wrong — drive strength in 30 of them (RGMII wants 15, SDIO 8, SD 5, the vendor
  dtsi says 3 everywhere) and bias in 16, overlapping in 6. Schmitt never differs
  on an owned pad. The regenerated `.dtsi` must carry the DEMO's electrical
  values, not the dtsi's placeholder `drive-strength = <3>; input-schmitt-enable = <0>`.
* **13 pads have no consumer.** `VI_D2`, `EMAC_PTP_PPS2`, `EPHY_CLK`,
  `CDTX_L1N`, `CDTX_L3N`, `THM_AIN1` (muxed to `PWM11`, but the board's backlight
  uses `pwm0`), `SD_PWR_SW`, `GPIO3_A2`, `GPIO3_A3`, `BOND0`, `BOND1`,
  `EMMC_PWR_EN`, `SYS_RSTN_OUT`. These are board-level defaults. Put them in one
  `board_default_pins` state on the board dts, selected by the pinctrl node
  itself, or drop the ones that only restate the reset function.
* **The 22 group-MISC writes have no DT representation at all.** Model them as a
  pinctrl-node property (e.g. `axera,group-misc-init = <group value mask>…`) or,
  better, split the two known fields out: the I/O-voltage bits `[8:7]` belong to
  the MMC drivers via a `syscon`/regulator, not to pinctrl.
* **One live conflict:** the DEMO muxes `EMAC_PTP_PPS0` to `GPIO1_A8`, while the
  board's `&pwm0` carries `pinctrl-0 = <&emac_ptp_pps0_pwm0_m_pins>` (function 2)
  and `&uart5` claims the same pad as `UART5_CTS` (**V**). Two DT owners plus the
  static table on one pad — mainline must pick one, and with `strict = true` it
  will fail probe loudly instead of silently, which is the desired behaviour.

---

## 5. The I2C `/delete-property/`

### 5.1 What is deleted

`AX630C_emmc_arm64_k419_sipeed_nanokvm.dts:205-232` deletes `pinctrl-names`,
`pinctrl-0` **and** `pinctrl-1` on four nodes — `&i2c0` (kept `okay`), `&i2c1`
(disabled), `&i2c6` (disabled), `&i2c7` (kept `okay`) (**V**). It leaves
`scl-gpio`/`sda-gpio` in place on all four (**V**).

The I2C controllers are **the only nodes in the entire SoC dtsi that carry a
`pinctrl-0`** — 8 of them, one per bus, and nothing else (**V**, grep of
`AX620E.dtsi`). Every other pad on the SoC is configured purely by the replayed
DEMO table. That is the frame for everything below.

What each deleted `pinctrl-0` (the `"default"` state) would have written, versus
what the DEMO table writes (**V**, decoded both sides):

| Node | Status | Pads | Deleted default state → | DEMO table → | Agree? |
|---|---|---|---|---|---|
| `&i2c0` | okay | `I2C0_SCL`, `I2C0_SDA` | `0x00000083` (f0, drv 3, pull-up) ×2 | `0x00000083` ×2 | **byte-identical** |
| `&i2c7` | okay | `VI_D8`, `VI_D9` | `0x00030083` (f3, drv 3, pull-up) ×2 | `0x00030083` ×2 | **byte-identical** |
| `&i2c1` | disabled | `I2C1_SCL`, `I2C1_SDA` | `0x00000083` ×2 | `0x00010083` (`SPI_M2_SCLK`), `0x00060083` (`GPIO0_A27`) | **conflict** |
| `&i2c6` | disabled | `VI_D1`, `VI_D0` | `0x00030083` ×2 | `0x00040003` (`I2S0_SCLK`), `0x00020043` (`SPI_M1_MOSI`) | **conflict** |

`pinctrl-1` is the `"gpio"` bus-recovery state, muxing each pad to its
`GPIO0_A24/A25`, `GPIO0_A26/A27`, `GPIO0_A0/A1`, `GPIO0_A8/A9` function (**V**).

### 5.2 Why — pad ownership, not a driver bug

The i2c1 and i2c6 pads were reassigned to other controllers on this board (**V**):

* `&spi1` (`.dts:414-420`) takes `VI_D0` as `SPI_M1_MOSI` — i2c6's SDA pad.
* `&i2s_slv0` (`.dts:567`, HDMI audio) takes `VI_D1` as `I2S0_SCLK` — i2c6's SCL
  pad. It has **no** `pinctrl-0`; the pad is configured only by the DEMO table.
* `&spi2` (`.dts:430-442`) takes `UART3_TXD` as `SPI_M2_MOSI`, `I2C1_SCL` as
  `SPI_M2_SCLK`, and `I2C1_SDA` as `GPIO0_A27` — the mini-display chip select.
  Note it references `i2c1_sda_gpio0_a27_pins`, i.e. literally the state i2c1's
  own `pinctrl-1` points at.

With `.strict = true` (`pinctrl-axera.c:167`), `pin_request()` returns `-EBUSY`
when a second *device* claims a pin already mux-owned (`[K]/drivers/pinctrl/pinmux.c:101-107`),
so enabling i2c1 or i2c6 with their states intact would fail whichever of
{i2c1, spi2} / {i2c6, spi1, i2s_slv0} probed second (**V**). Deleting the states
disarms that.

For i2c0 and i2c7 the states are byte-identical to the DEMO table and no other
node claims those pads (**V**, grepped). The deletion there is not fixing a
conflict; it removes the *second source of truth* and, with it, one concrete
side effect: `i2c_gpio_init_generic_recovery()`
(`[K]/drivers/i2c/i2c-core-base.c:341-386`) selects the `"gpio"` state and
restores `"default"` on **every** `i2c_add_adapter()`, briefly driving SCL
push-pull high on an open-drain bus. With `pinctrl-names` gone,
`i2c_gpio_init_pinctrl_recovery()` NULLs the handle and logs a debug message
(`i2c-core-base.c:312-318`) — no failure, no flip (**V**).

Two candidate explanations are **ruled out** (**V**):

* *Probe-order deferral loop* — `dw_i2c` is `subsys_initcall`, pinctrl and
  gpio-axera are `device_initcall`, so i2c defers either way (the `scl-gpio`
  lookup alone defers it) and is retried at `late_initcall` once both providers
  exist. Deleting the properties changes nothing here.
* *`ax_set_mux()` walking off the end of the pad's mux array* — a real bug
  (`pinctrl-axera.c:90-103`: on a name miss it prints an error, then writes the
  terminator's `muxval` of **0** and returns success, silently muxing to function
  0), but every function named by these four nodes exists on its pad, so it is
  not the trigger here.

Cross-board evidence settles it: Axera's own `AX630C_emmc_arm64_k419.dts` has
**zero** deletions; Sipeed's `..._sipeed_maixcam2.dts:340-356` deletes on **i2c6
and i2c7 only**, and also deletes `scl-gpio`/`sda-gpio` (**V**). Different
Sipeed boards delete different sets — this is per-board bring-up editing, not an
SoC-level workaround (**I**).

### 5.3 A latent bug the deletion created

Because the pinctrl states are gone but `scl-gpio`/`sda-gpio` are not, i2c0 and
i2c7 have *half-configured* recovery. `i2c_dw_init_recovery_info()`
(`[K]/drivers/i2c/busses/i2c-designware-master.c:880-912`) still claims the
descriptors — that is exactly the live `gpio-24 (scl) out hi`,
`gpio-25 (sda) in lo`, `gpio-8 (scl)`, `gpio-9 (sda)` in `gpio.txt` (**V**) — but
with `bri->pinctrl` NULL, `i2c_generic_scl_recovery()` skips the pad switch
(`i2c-core-base.c:193-194`) and bit-bangs GPIO registers on pads still muxed to
the I2C function. **Bus recovery silently does nothing.** maixcam2 avoided this
by deleting the GPIOs too.

### 5.4 What mainline should say

1. **Restore `pinctrl-0` on `&i2c0` and `&i2c7`.** Mainline has no DEMO table to
   inherit from, so the DT must be the source of truth. The values are already
   known-correct — they match the shipping pad words bit for bit.
2. **Keep the `"gpio"` recovery state and `scl-gpios`/`sda-gpios` together, or
   drop both.** The shipped half-and-half is a bug either way.
3. **Leave `&i2c1` and `&i2c6` disabled and give their pads to their real
   owners.** `&spi1`, `&spi2` and — new — `&i2s_slv0` must each carry an explicit
   `pinctrl-0`; on 4.19 the I2S pads (`VI_D1`, `VI_D3`, `VI_D4`, `VI_CLK0`) are
   configured *only* by the static table, which mainline will not have.
4. **Keep `strict`.** It is what turns the i2c1↔spi2 and i2c6↔spi1/i2s overlaps
   into a loud probe failure instead of a silent mis-mux.

---

## 6. The SW_PWR trap, root-caused

### 6.1 The chain

1. **The pad.** ATX power-button drive is GPIO bank 0 line 7, which the SoC dtsi
   maps to **pin 7 = `VI_D7`**, register **`0x02300060`** (`AX620E.dtsi:248-249`
   + `pinctrl-ax620e.h:39,163`) (**V**). `GPIO0_A7` is function **6** on that pad
   (`pinctrl-ax620e.c`, pad table above) (**V**).
2. **Who muxes it to GPIO.** Only the DEMO table:
   `0x02300060 = 0x00060003` — function 6, drive 3, no pull (**V**). Applied
   twice, both one-shot: U-Boot's `pinmux_init()` and the kernel's
   `arch_initcall` `ax_pin_init()`. This value is **unique to the NanoKVM board
   headers**; every other AX630C project leaves `VI_D7` as `VI_D7` (**V**).
3. **No DT state ever touches it.** Grepping every `pinctrl-0`/`pinctrl-1` in
   `AX620E.dtsi` and the board dts: `vi_d7_*` appears **nowhere** (**V**). The
   state node `vi_d7_gpio0_a7_pins` exists in `AX620E_pinctrl.dtsi` and is
   referenced by nothing.
4. **Who muxes it away.** Not `lt6911_manage.c` — its `pinmux_register_init()`
   writes seven pad words (`lt6911_manage.c:1238-1256`) and `0x02300060` is not
   among them (**V**). Not `dwmac-axera.c`, `sdhci-axera.c` or `mmc/core/core.c`,
   the only other direct pad-word writers in the tree (**V**, exhaustive grep of
   `[K]/drivers` and `[K]/arch/arm64` for the two register windows). The vendor
   capture stack is the remaining suspect and **cannot be checked**: `[S]/msp`
   and `[S]/kernel` are empty and the only artifact is the prebuilt
   `ax_proton.ko` (**V** on the absence of source). The re-mux therefore stays an
   **on-device behavioural observation** (`docs/mini-display.md`, 2026-08-16),
   **not** a source-verified fact — mark it **I**.
5. **Why sysfs export cannot repair it.** `gpio-axera.c:97-104` installs no-op
   `ax_gpio_request()`/`ax_gpio_free()` as `chip.request`/`chip.free`
   (`gpio-axera.c:453-454`) (**V**). In 4.19, `gpiod_request_commit()`
   (`[K]/drivers/gpio/gpiolib.c:2293-2347`) reaches pinctrl **only** through
   `chip->request`, and `pinctrl_gpio_request()` is reached only from
   `gpiochip_generic_request()` (`gpiolib.c:2127-2129`) (**V**). So
   `ax_pinmux_ops.gpio_request_enable = axera_request_gpio` is dead code on this
   SoC, `desc->gpio_owner` is never set, and **no GPIO request on this chip ever
   programs a mux** (**V**).
6. **So the mux is write-once at boot with no owner.** Anything that clobbers it
   wins permanently. That is the whole trap.

Corollaries the source confirms:

* Reset (`gpio1.3` = `UART3_RXD`, `0x02304090`) and the LED senses
  (`CDTX_L0N/L0P`, `0x0230A00C`/`0x0230A018`) are in different pad groups from
  the VI group, which is why "reset works but power doesn't" is the signature
  (**V** on the pad/group assignment; **I** on the causal link, which depends on
  the unverifiable step 4).
* The vendor's own `gpio.sh` poking `0x02302024` is poking `GPIO3_A2`, an
  entirely different pad (**V** — `0x02302024` is pin 85 in the table above).
* `axera_request_gpio()` also has a latent bug: it calls
  `gpio_request(range->base, NULL)` rather than
  `range->base + offset - range->pin_base`, so it would always request the first
  line of the range (`pinctrl-axera.c:111-122`) (**V**). Harmless only because it
  never runs.

### 6.2 What mainline must implement

Three pieces, and the trap disappears without any `/dev/mem` workaround:

**(a) `pinmux_ops.gpio_request_enable`** — given `(range, offset)`, resolve the
pin via `range->pin_base + (offset - range->base)`, look up that pad's GPIO mux
value from a per-pad `gpio_muxval` field (6 on 94 pads, 0 on `GPIO3_A1/A2/A3`,
"none" on the 14 pads with no GPIO function — return `-ENOTSUPP` for those), and
write it into `[18:16]`. Save the previous function so
`gpio_disable_free()` can restore it. Do **not** call `gpio_request()` from here.

**(b) `pinmux_ops.gpio_set_direction`** — return 0. There is no direction bit in
the pad word (§1.3); direction lives in the GPIO controller's per-line register.
Implement it as a stub so the core does not warn, not as the vendor's
`gpio_direction_*()` re-entry.

**(c) The GPIO driver must stop stubbing `chip.request`.** Set
`chip.request = gpiochip_generic_request` and `chip.free = gpiochip_generic_free`
so `pinctrl_gpio_request()` actually runs. Keep `gpio-ranges` as the SoC dtsi has
them (§7) — they are already correct.

With those three, `gpiod_get()` on any line programs its mux, `strict = true`
arbitrates against peripheral claims, and a `gpio-hog` works with no
`pinctrl-0` at all.

### 6.3 The DT that would then work

Either form is sufficient once (a)+(c) exist. Hog form, no pinctrl state needed:

```dts
&gpio0 {
    atx_pwr_hog: atx-power-hog {
        gpio-hog;
        gpios = <7 GPIO_ACTIVE_HIGH>;   /* VI_D7 → GPIO0_A7 */
        output-low;                     /* button released */
        line-name = "ATX_SW_PWR";
    };
};
```

Consumer form, which also pins the electrical config and is what the ATX driver
should use:

```dts
&pinctrl {
    atx_pins: atx-pins {
        function = "gpio";
        groups = "VI_D7",       /* GPIO0_A7 — SW_PWR  */
                 "UART3_RXD";   /* GPIO1_A3 — SW_RST  */
        drive-strength = <3>;
        bias-disable;
    };
};

atx {
    compatible = "nanokvm,atx";        /* or gpio-leds / whatever drives it */
    pinctrl-names = "default";
    pinctrl-0 = <&atx_pins>;
    power-gpios = <&gpio0 7 GPIO_ACTIVE_HIGH>;
    reset-gpios = <&gpio1 3 GPIO_ACTIVE_HIGH>;
};
```

`bias-disable` and `drive-strength = <3>` reproduce the DEMO word `0x00060003`
exactly.

---

## 7. GPIO cross-check

### 7.1 The ranges

`AX620E.dtsi:248-325` declares **97** `<&pinctrl_ax line pin 1>` triples across
the four banks — 32 + 32 + 30 + 3, not 128; banks 2 and 3 are partly and mostly
unmapped (**V**). The mapping is `bank N line M` ↔ the pad whose function list
contains `GPIO{N}_A{M}` — verified for all 97 (**V**, zero unresolved). 94 use
function **6**; `GPIO3_A1/A2/A3` use function **0**.

The 97 sparse triples compress to **24 contiguous runs** (**V**, derived) — worth
doing in the regenerated dtsi:

```
gpio0: <&pinctrl 0 0 11>, <&pinctrl 11 79 4>, <&pinctrl 15 87 4>, <&pinctrl 19 62 1>,
       <&pinctrl 20 60 1>, <&pinctrl 21 92 3>, <&pinctrl 24 11 8>
gpio1: <&pinctrl 0 19 4>, <&pinctrl 4 95 4>, <&pinctrl 8 23 4>, <&pinctrl 12 33 12>,
       <&pinctrl 24 27 6>, <&pinctrl 30 63 2>
gpio2: <&pinctrl 0 65 4>, <&pinctrl 4 45 6>, <&pinctrl 10 69 10>, <&pinctrl 20 56 1>,
       <&pinctrl 21 54 2>, <&pinctrl 23 52 1>, <&pinctrl 24 51 1>, <&pinctrl 25 53 1>,
       <&pinctrl 26 57 3>, <&pinctrl 29 61 1>
gpio3: <&pinctrl 1 84 3>
```

### 7.2 Every mapped line vs. the live device

`Pad state` is what the pad word actually holds after boot: the DEMO value, plus
`lt6911_manage.c:1247-1253` where it overrides. `Live` is `gpio.txt`.

| GPIO | bank.line | Pin | Pad | Address | GPIO mux | Pad state after boot | Live claim |
|---|---|---|---|---|---|---|---|
| gpio-0 | 0.0 | 0 | VI_D0 | `0x230000c` | 6 | `0x00020043` = f2 (line unused) | — |
| gpio-1 | 0.1 | 1 | VI_D1 | `0x2300018` | 6 | `0x00040003` = f4 (line unused) | — |
| gpio-2 | 0.2 | 2 | VI_D2 | `0x2300024` | 6 | `0x00000003` = f0 (line unused) | — |
| gpio-3 | 0.3 | 3 | VI_D3 | `0x2300030` | 6 | `0x00040003` = f4 (line unused) | — |
| gpio-4 | 0.4 | 4 | VI_D4 | `0x230003c` | 6 | `0x00040003` = f4 (line unused) | — |
| gpio-5 | 0.5 | 5 | VI_D5 | `0x2300048` | 6 | `0x00060003` → lt6911 rewrites `0x00060003` (GPIO) | LT6911UXC_PWR |
| gpio-6 | 0.6 | 6 | VI_D6 | `0x2300054` | 6 | `0x00060003` → lt6911 rewrites `0x00060003` (GPIO) | LT86102UXC_HDMI_PWR |
| gpio-7 | 0.7 | 7 | VI_D7 | `0x2300060` | 6 | `0x00060003` = GPIO | sysfs (ATX SW_PWR) |
| gpio-8 | 0.8 | 8 | VI_D8 | `0x230006c` | 6 | **`0x00030083` = f3, NOT GPIO** | scl (i2c7 recovery) |
| gpio-9 | 0.9 | 9 | VI_D9 | `0x2300078` | 6 | **`0x00030083` = f3, NOT GPIO** | sda (i2c7 recovery) |
| gpio-10 | 0.10 | 10 | VI_CLK0 | `0x2300084` | 6 | `0x00040003` = f4 (line unused) | — |
| gpio-11 | 0.11 | 79 | THM_AIN3 | `0x230100c` | 6 | `0x00050043` = f5 (line unused) | — |
| gpio-12 | 0.12 | 80 | THM_AIN2 | `0x2301018` | 6 | `0x00000003` = f0 (line unused) | — |
| gpio-13 | 0.13 | 81 | THM_AIN1 | `0x2301024` | 6 | `0x00020003` = f2 (line unused) | — |
| gpio-14 | 0.14 | 82 | THM_AIN0 | `0x2301030` | 6 | `0x00000003` = f0 (line unused) | — |
| gpio-15 | 0.15 | 87 | BOND0 | `0x2302048` | 6 | `0x00000013` = f0 (line unused) | — |
| gpio-16 | 0.16 | 88 | BOND1 | `0x2302054` | 6 | `0x00000013` = f0 (line unused) | — |
| gpio-17 | 0.17 | 89 | EMMC_PWR_EN | `0x2302060` | 6 | `0x00000003` = f0 (line unused) | — |
| gpio-18 | 0.18 | 90 | BOND2 | `0x230206c` | 6 | `0x00060003` = GPIO | rotary@0 |
| gpio-19 | 0.19 | 62 | EMMC_DAT1 | `0x2309090` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-20 | 0.20 | 60 | EMMC_DAT0 | `0x2309078` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-21 | 0.21 | 92 | TMS | `0x2302090` | 6 | `0x00060003` → lt6911 rewrites `0x00060003` (GPIO) | LT86102UXC_HDMI_TXO |
| gpio-22 | 0.22 | 93 | TCK | `0x230209c` | 6 | `0x00060003` = GPIO | GPIO KEY ENTER |
| gpio-23 | 0.23 | 94 | SD_PWR_EN | `0x23020a8` | 6 | `0x00060003` = GPIO | sys-heartbeat |
| gpio-24 | 0.24 | 11 | I2C0_SCL | `0x230400c` | 6 | **`0x00000083` = f0, NOT GPIO** | scl (i2c0 recovery) |
| gpio-25 | 0.25 | 12 | I2C0_SDA | `0x2304018` | 6 | **`0x00000083` = f0, NOT GPIO** | sda (i2c0 recovery) |
| gpio-26 | 0.26 | 13 | I2C1_SCL | `0x2304024` | 6 | `0x00010083` = f1 (line unused) | — |
| gpio-27 | 0.27 | 14 | I2C1_SDA | `0x2304030` | 6 | `0x00060083` = GPIO | 6072000.spi (spi2 CS1) |
| gpio-28 | 0.28 | 15 | UART0_TXD | `0x230403c` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-29 | 0.29 | 16 | UART0_RXD | `0x2304048` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-30 | 0.30 | 17 | UART1_TXD | `0x2304054` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-31 | 0.31 | 18 | UART1_RXD | `0x2304060` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-32 | 1.0 | 19 | UART2_TXD | `0x230406c` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-33 | 1.1 | 20 | UART2_RXD | `0x2304078` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-34 | 1.2 | 21 | UART3_TXD | `0x2304084` | 6 | `0x00010083` = f1 (line unused) | — |
| gpio-35 | 1.3 | 22 | UART3_RXD | `0x2304090` | 6 | `0x00060003` = GPIO | sysfs (ATX SW_RST) |
| gpio-36 | 1.4 | 95 | MICP_L_D | `0x230500c` | 6 | `0x00060083` = GPIO | id (extcon-usb) |
| gpio-37 | 1.5 | 96 | MICN_L_D | `0x2305018` | 6 | `0x00060000` = GPIO | — |
| gpio-38 | 1.6 | 97 | MICN_R_D | `0x2305024` | 6 | `0x00060000` = GPIO | — |
| gpio-39 | 1.7 | 98 | MICP_R_D | `0x2305030` | 6 | `0x00060000` = GPIO | — |
| gpio-40 | 1.8 | 23 | EMAC_PTP_PPS0 | `0x104f000c` | 6 | `0x00060003` = GPIO | — |
| gpio-41 | 1.9 | 24 | EMAC_PTP_PPS1 | `0x104f0018` | 6 | `0x00060003` = GPIO | fb_jd9853 (reset) |
| gpio-42 | 1.10 | 25 | EMAC_PTP_PPS2 | `0x104f0024` | 6 | `0x00060003` = GPIO | — |
| gpio-43 | 1.11 | 26 | EMAC_PTP_PPS3 | `0x104f0030` | 6 | `0x00060003` = GPIO | fb_jd9853 (dc) |
| gpio-44 | 1.12 | 33 | RGMII_RXD0 | `0x104f0084` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-45 | 1.13 | 34 | RGMII_RXD1 | `0x104f0090` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-46 | 1.14 | 35 | RGMII_RXDV | `0x104f009c` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-47 | 1.15 | 36 | RGMII_RXCLK | `0x104f00a8` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-48 | 1.16 | 37 | RGMII_RXD2 | `0x104f00b4` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-49 | 1.17 | 38 | RGMII_RXD3 | `0x104f00c0` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-50 | 1.18 | 39 | RGMII_TXD0 | `0x104f00cc` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-51 | 1.19 | 40 | RGMII_TXD1 | `0x104f00d8` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-52 | 1.20 | 41 | RGMII_TXCLK | `0x104f00e4` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-53 | 1.21 | 42 | RGMII_TXEN | `0x104f00f0` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-54 | 1.22 | 43 | RGMII_TXD2 | `0x104f00fc` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-55 | 1.23 | 44 | RGMII_TXD3 | `0x104f0108` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-56 | 1.24 | 27 | RGMII_MDCK | `0x104f003c` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-57 | 1.25 | 28 | RGMII_MDIO | `0x104f0048` | 6 | `0x0000000F` = f0 (line unused) | — |
| gpio-58 | 1.26 | 29 | EPHY_CLK | `0x104f0054` | 6 | `0x00060003` = GPIO | — |
| gpio-59 | 1.27 | 30 | EPHY_RSTN | `0x104f0060` | 6 | `0x00060008` = GPIO | ? (eth PHY reset) |
| gpio-60 | 1.28 | 31 | EPHY_LED0 | `0x104f006c` | 6 | `0x00000083` → lt6911 rewrites `0x00060083` (GPIO) | init_gpio (LT6911 INT) |
| gpio-61 | 1.29 | 32 | EPHY_LED1 | `0x104f0078` | 6 | `0x00060003` = GPIO | reset (aic_bsp WiFi) |
| gpio-62 | 1.30 | 63 | SDIO_DAT0 | `0x104f200c` | 6 | `0x00000008` = f0 (line unused) | — |
| gpio-63 | 1.31 | 64 | SDIO_DAT1 | `0x104f2018` | 6 | `0x00000008` = f0 (line unused) | — |
| gpio-64 | 2.0 | 65 | SDIO_CLK | `0x104f2024` | 6 | `0x00000008` = f0 (line unused) | — |
| gpio-65 | 2.1 | 66 | SDIO_CMD | `0x104f2030` | 6 | `0x00000008` = f0 (line unused) | — |
| gpio-66 | 2.2 | 67 | SDIO_DAT2 | `0x104f203c` | 6 | `0x00000008` = f0 (line unused) | — |
| gpio-67 | 2.3 | 68 | SDIO_DAT3 | `0x104f2048` | 6 | `0x00000008` = f0 (line unused) | — |
| gpio-68 | 2.4 | 45 | SD_DAT0 | `0x104f100c` | 6 | `0x00000005` = f0 (line unused) | — |
| gpio-69 | 2.5 | 46 | SD_DAT1 | `0x104f1018` | 6 | `0x00000005` = f0 (line unused) | — |
| gpio-70 | 2.6 | 47 | SD_CLK | `0x104f1024` | 6 | `0x00000005` = f0 (line unused) | — |
| gpio-71 | 2.7 | 48 | SD_CMD | `0x104f1030` | 6 | `0x00000005` = f0 (line unused) | — |
| gpio-72 | 2.8 | 49 | SD_DAT2 | `0x104f103c` | 6 | `0x00000005` = f0 (line unused) | — |
| gpio-73 | 2.9 | 50 | SD_DAT3 | `0x104f1048` | 6 | `0x00000005` = f0 (line unused) | — |
| gpio-74 | 2.10 | 69 | CDTX_L0N | `0x230a00c` | 6 | `0x00060003` = GPIO | sysfs (HDD LED sense) |
| gpio-75 | 2.11 | 70 | CDTX_L0P | `0x230a018` | 6 | `0x00060003` = GPIO | sysfs (power LED sense) |
| gpio-76 | 2.12 | 71 | CDTX_L1N | `0x230a024` | 6 | `0x00060003` = GPIO | — |
| gpio-77 | 2.13 | 72 | CDTX_L1P | `0x230a030` | 6 | `0x00060003` = GPIO | — |
| gpio-78 | 2.14 | 73 | CDTX_L2N | `0x230a03c` | 6 | `0x00060003` = GPIO | hyn_reset_gpio |
| gpio-79 | 2.15 | 74 | CDTX_L2P | `0x230a048` | 6 | `0x00060003` = GPIO | hyn_irq_gpio |
| gpio-80 | 2.16 | 75 | CDTX_L3N | `0x230a054` | 6 | `0x00000003` = f0 (line unused) | — |
| gpio-81 | 2.17 | 76 | CDTX_L3P | `0x230a060` | 6 | `0x00000003` → lt6911 rewrites `0x00060003` (GPIO) | LT86102UXC_LOOP_CTRL |
| gpio-82 | 2.18 | 77 | CDTX_L4N | `0x230a06c` | 6 | `0x00000003` → lt6911 rewrites `0x00060003` (GPIO) | LT86102UXC_HDMI_RXI |
| gpio-83 | 2.19 | 78 | CDTX_L4P | `0x230a078` | 6 | `0x00000003` → lt6911 rewrites `0x00060003` (GPIO) | LT86102UXC_HDMI_TXI |
| gpio-84 | 2.20 | 56 | EMMC_DAT7 | `0x2309048` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-85 | 2.21 | 54 | EMMC_DAT6 | `0x2309030` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-86 | 2.22 | 55 | EMMC_DS | `0x230903c` | 6 | `0x00000043` = f0 (line unused) | — |
| gpio-87 | 2.23 | 52 | EMMC_RESET_N | `0x2309018` | 6 | `0x00060083` = GPIO | eMMC HW RESET |
| gpio-88 | 2.24 | 51 | EMMC_DAT5 | `0x230900c` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-89 | 2.25 | 53 | EMMC_DAT4 | `0x2309024` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-90 | 2.26 | 57 | EMMC_DAT3 | `0x2309054` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-91 | 2.27 | 58 | EMMC_DAT2 | `0x2309060` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-92 | 2.28 | 59 | EMMC_CLK | `0x230906c` | 6 | `0x00000003` = f0 (line unused) | — |
| gpio-93 | 2.29 | 61 | EMMC_CMD | `0x2309084` | 6 | `0x00000083` = f0 (line unused) | — |
| gpio-97 | 3.1 | 84 | GPIO3_A1 | `0x2302018` | 0 | `0x00000003` = GPIO | rotary@0 |
| gpio-98 | 3.2 | 85 | GPIO3_A2 | `0x2302024` | 0 | `0x00000003` = GPIO | — |
| gpio-99 | 3.3 | 86 | GPIO3_A3 | `0x2302030` | 0 | `0x00000013` = GPIO | — |

### 7.3 Flags

* **Four lines contradict the DEMO table: `gpio-8`, `gpio-9`, `gpio-24`,
  `gpio-25`** (**V**). All four are claimed with `scl`/`sda` labels but their pads
  are muxed to `I2C7_SCL/SDA` and `I2C0_SCL/SDA`. This is the i2c bus-recovery
  descriptor claim of §5.3 — `i2c-designware-master.c:892,898` grabs them, but
  with `pinctrl-names` deleted the recovery path can never switch the pad, so the
  bit-banging has no electrical effect. Not a mux bug; a dead-recovery bug.
  Mainline fixes it by restoring the `"gpio"` state (§5.4).
* **Four lines look like contradictions but are not: `gpio-60`, `gpio-81`,
  `gpio-82`, `gpio-83`** (**V**). The DEMO table leaves `EPHY_LED0` at
  `EPHY_LED0` and `CDTX_L3P/L4N/L4P` at their D-PHY function; `lt6911_manage.c`
  re-muxes all four to GPIO at module init, along with `VI_D5`, `VI_D6` and `TMS`
  (which the DEMO table already had right). **These seven direct pad writes must
  become DT pinctrl states** on the LT6911 node in mainline — the driver must not
  keep `ioremap`ing the pin controller.
* **`EPHY_LED0` is contested.** `lt6911_manage.c:1247` and
  `dwmac-axera.c:15-28` (`EMAC_EPHY_LED0_PINMUX_ADDR = 0x104F006C`,
  `dwmac-axera.h:58`) both blind-write that word. On this board it is latent:
  `phy-mode = "rgmii"` (`.dts:638`) sends `emac_phy_rst()` down the GPIO-reset
  branch, so the LED pinmux writes at `dwmac-axera.c:60,80,456` never run
  (**V**). In mainline, put the pad in exactly one node's state.
* **`gpio-59` shows as `?`** in `gpio.txt` — an unlabelled `gpio_request`. It is
  `EPHY_RSTN` / `GPIO1_A27`, the Ethernet PHY reset taken by `dwmac-axera`
  (`phy-rst-gpio` in the board dts) (**V**).
* **`gpio-43` is double-booked.** `EMAC_PTP_PPS3` / `GPIO1_A11` is the panel's
  `dc-gpios` (`.dts:462`) and also `&mmc1`'s `cd-gpios` (`.dts:353`) (**V**). The
  panel wins on the live device. Mainline must drop one.
* Everything else on all 97 lines agrees: pad muxed to GPIO where a consumer
  claims it, pad muxed to its peripheral where the GPIO line is unused (**V**).

---

## 8. Mainline shape

### 8.1 Binding: replace it

The vendor binding is not ABI worth keeping and it is our device tree. Replace
it:

* **New compatible** `axera,ax630c-pinctrl` (the AX620E family variants can be
  added as `axera,ax620q-pinctrl` etc. with their own pad tables). Do not reuse
  `axera,ax620e-pinctrl` — the group/function namespace is incompatible, and a
  clean break stops an old dtb binding to the new driver.
* **Keep `pinconf-generic`.** The vendor already uses `pinconf_generic_dt_node_to_map`
  with `.is_generic = true` (`pinctrl-axera.c:51-57, 277-281`) and the standard
  properties `pins`, `function`, `bias-pull-up`, `bias-pull-down`,
  `bias-disable`, `drive-strength`, `input-schmitt-enable` (**V**). That half of
  the design is right; keep it. Add `groups` alongside `pins` once real
  multi-pin groups exist.
* **One deviation to document:** `drive-strength` is a raw 4-bit code, not mA
  (§1.3). Either document it as a code in the binding, or use
  `axera,drive-strength` and reject `drive-strength`.
* **Drop the `mux { } / configs { }` subnode split.** It exists only because the
  vendor generator emitted it; `pinconf_generic_dt_node_to_map` handles a flat
  node fine.

### 8.2 Driver structure

`pinctrl-generic` + `pinmux-generic` + `pinconf-generic`, with real groups:

* **Pins**: the 111-entry `pinctrl_pin_desc` array from §2, each with
  `{window, offset, gpio_muxval, pull_encoding, mux[8]}` as `drv_data`.
  `mux[8]` holds the collapsed function id or `-1` for the 337 reserved slots.
* **Groups**: register the 56 functions' member pads as **named multi-pin
  groups** via `pinctrl_generic_add_group()` — e.g. `emmc`, `sd`, `sdio`,
  `rgmii`, `i2c0`, `uart0`, `vi`, `dphy_rx`. Also register all 111 single-pin
  groups named after the pad, because GPIO consumers and hogs need per-pad
  granularity and the board has many one-pad states. That is ~167 groups, still
  a fraction of the vendor's model.
* **Functions**: 56, via `pinmux_generic_add_function()`, each listing the groups
  it is valid on (§3.3).
* **`set_mux()`**: for each pin in the group, look up `mux[]` for the selected
  function; if it is `-1`, return `-EINVAL` — **do not** fall through and write 0
  the way `pinctrl-axera.c:94-103` does. This is the single most important
  correctness fix.
* **`.strict = true`** — keep it (§5.4).
* **`gpio_request_enable` / `gpio_disable_free` / `gpio_set_direction`** — §6.2.
* **DPHY-TX sequencing** — §2.1. Take two `syscon` phandles (DPHY-TX soft-reset
  and MIPI-enable) on the pinctrl node and run the sequence before muxing a
  `CDTX_*` pad away from function 0.
* **Locking**: none. The per-pad SET/CLR aliases were confirmed on hardware
  2026-09-06 (`device-reads-20260906/pull-and-alias-probe.md`), so
  function/pull/schmitt/drive are each written as a clear-then-set pair that
  names only its own bits — no read, no cross-field clobber, no contention
  between pads, and no lock. A multi-bit field passes briefly through the
  bits-cleared value, which `.strict = true` makes harmless.
* **No `regmap`**: two `devm_platform_ioremap_resource()` calls, indexed by the
  pad's `window` field. Drop the `SECOND_OFFSET` arithmetic.

Estimated size: ~400 lines of driver plus a ~900-line generated pad/function
table. The tables in this document are the generator input.

### 8.3 Regenerated `.dtsi` layout

Do **not** regenerate 563 single-pad states. Emit only states the DT actually
uses, in the SoC dtsi:

```dts
pinctrl: pinctrl@2300000 {
    compatible = "axera,ax630c-pinctrl";
    reg = <0x0 0x02300000 0x0 0xB000>,
          <0x0 0x104F0000 0x0 0x3000>;
    axera,dphytx-reset  = <&syscon_rst  0xB8 6>;
    axera,dphytx-mipien = <&syscon_dphy 0x10C>;

    emmc_pins: emmc-pins {
        function = "emmc";
        groups = "EMMC_CLK", "EMMC_CMD", "EMMC_DS",
                 "EMMC_DAT0", "EMMC_DAT1", "EMMC_DAT2", "EMMC_DAT3",
                 "EMMC_DAT4", "EMMC_DAT5", "EMMC_DAT6", "EMMC_DAT7";
        drive-strength = <3>;
        bias-pull-up;
        /* EMMC_CLK: no pull, EMMC_DS: pull-down — see the split node below */
    };
    ...
};
```

Rules for the generator:

1. **One node per (function, electrical config) pair.** Where the DEMO table
   gives one member pad a different drive/pull from its siblings (eMMC CLK and
   DS, the SD pads' mixed pull-ups), split it into a second node in the same
   `pinctrl-0` list rather than losing the value. §4.2's table is the source.
2. **Electrical values come from the DEMO table, not from the vendor dtsi.**
   40 of 111 differ (§4.3).
3. **Group names are pad names**, upper-case, exactly as §2. Function names are
   the 56 lower-case names of §3.3.
4. **Peripheral states live in the SoC dtsi; GPIO-line states live in the board
   dts**, next to the consumer that owns the line — the `Owner` column of §4.2
   says which is which.
5. **The 13 unclaimed pads** (§4.3) get one `board_default_pins` node in the
   board dts, selected by the pinctrl node itself via its own `pinctrl-0`.
6. **The 22 group-MISC writes** are not pinctrl states; see §4.3.

---

## 9. Open questions and gaps

Ranked by how much they can hurt the driver author:
1. **Does the vendor capture stack re-mux `VI_D7`?** Unverifiable from source --
   `ax_proton.ko` is the only artifact (**V** on the absence). It does not block
   the mainline driver (nothing closed will be loaded), but it means the trap's
   *mechanism* is still an inference. If mainline's own CSI driver ever writes
   pad words, this comes straight back.
2. ~~**The G2/G5/G7 pull encoding.**~~ **ANSWERED 2026-09-06: EN/SE, as the
   driver source says.** Measured on `THM_AIN3` (G2) with the on-chip ADC as an
   analog oracle: `0x80` is *no pull* (662/1023, same as bias-disable) and `0xC0`
   is pull-up (1018), which refutes one-hot twice over. G5/G7 have no ADC channel
   and ride on the vendor driver's single offset test. §1.4 and
   `device-reads-20260906/pull-encoding-adc/README.md`.
3. ~~**Do per-pad SET/CLR aliases work?**~~ **ANSWERED 2026-09-06: yes**, on
   ordinary pad words as well as the group MISC word, in both directions and for
   multi-bit fields; the alias words are write-only. The driver has no lock.
   See `device-reads-20260906/pull-and-alias-probe.md`.
4. **Group MISC0 field map.** Only bits `[8:7]` (I/O voltage) are known; the
   DEMO writes `[3:0] = 1` and bit 9 into every group with no explanation.
5. **Bit 5 of the pad word.** Never written by anything. Slew rate? Open-drain?
6. **Reset values.** Unobservable (§1.6). Not blocking.
7. **`drive-strength` code → mA.** Unknown. Copy the DEMO values verbatim.
