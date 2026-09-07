# G2/G5/G7 pull encoding — settled with the on-chip ADC, 2026-09-06

The question (`pinctrl-model-20260906.md` §1.4): on the analog-capable groups
G2/G5/G7, do pad-word bits `[7:6]` mean **enable + select** (bit 6 enables a
pull, bit 7 picks up/down — what `pinctrl-axera.c` does) or **one-hot** (bit 7 =
pull-up, bit 6 = pull-down, as everywhere else)? They differ only on `0x80`:
one-hot calls it pull-up, EN/SE calls it *no pull*.

**Answer: EN/SE, proven on hardware.** The driver's per-pad `pull_enc` flag and
the values it writes were already correct; this confirms them rather than
changing them.

## Why this worked when the digital probe could not

The first attempt ([`../pull-and-alias-probe.md`](../pull-and-alias-probe.md))
read pads through the GPIO input register, which only reports "above or below
threshold". On a pad with an external pull-up, "internal pull-up" and "no pull"
both read high, so `0x80` stayed ambiguous.

`THM_AIN0..3` are **analog** pads wired to the on-chip analog monitor block, so
`0x20000a0..ac` (raw) and `0x20000b4..c0` (filtered) give a *voltage* instead of
a bit. `THM_AIN3` floats mid-scale at ~661/1023 — neither rail — which makes
pull-up, pull-down and no-pull three separable levels on one pad. Nothing in the
ADC block was written; it was already enabled (`MON_CH` `0x20000c4` = `0x7C01`,
all four AIN channels on, filter on).

## The measurement

`THM_AIN3` (G2, pad word `0x230100c`), 40 samples per bias, filtered channel 3.
Recomputed independently from the raw sample lines in this directory:

| bias | pad word | ch3 mean | min | max | one-hot predicts | EN/SE predicts |
|---|---|---|---|---|---|---|
| `0x00` | `0x00050003` | 662.5 | 659 | 666 | float | float |
| `0x40` | `0x00050043` | 1.3 | 0 | 6 | low | low |
| `0x80` | `0x00050083` | **662.0** | 658 | 664 | **high (pure up)** | **float (disabled)** |
| `0xC0` | `0x000500C3` | **1018.0** | 1014 | 1020 | ≤ V(`0x80`) | **high (pure up)** |

One-hot is refuted twice over. `0x80` is pure pull-up under one-hot and must read
high; it reads 662.0, indistinguishable from no-pull's 662.5. And `0xC0` is
up-plus-down contention under one-hot, which can never read *higher* than pure
pull-up; it reads 356 LSB higher. Every one of the four codes matches EN/SE.

Noise is ≤ 8 LSB at any fixed bias against a 356 LSB discriminating gap.
Replicated with direct full-word VALUE writes as well as through the SET/CLR
aliases, in different sequence orders: `0x43`→1.1, `0x83`→661.7, `0xC3`→1018.3,
`0x03`→661.8.

Controls: during the sweep ch0 (`THM_AIN0`, the board-ID divider) held 324.0 ±0
and ch2 held ~510 ±2, so the ch3 movement is pad-local and not an ADC artifact.
`THM_AIN2` (ch2) and `THM_AIN0` (ch0) did not move one LSB under any of the four
codes — they are driven by stiff external sources and carry no encoding
information, which is why the earlier digital probe found them unresponsive.

## Scope

Hardware proof is for **G2**. G5 (`GPIO3_A*`) and G7 (`MIC*_D`) have no ADC
channel and no pad that floats mid-scale, so they cannot be measured this way.
They are covered by the same single contiguous offset test in the vendor driver,
and the earlier G7 digital readings are consistent with EN/SE, so the driver
treats all three groups alike. A direct G7 proof would need a meter on a pad.

Consequence for §1.4's trap: the DEMO table's `0x…83` on `MICP_L_D` really is
*no pull*. The table generator is encoding-blind for this group — harmless there,
because that pad (the USB OTG ID line) has an external pull-up.

## Channel map

`chN` = `THM_AINN`, shown for ch1 and ch3: ch1's raw word swings 0–1022 with a
~50% filtered mean while `THM_AIN1` is muxed to `PWM11` (a live PWM output —
left untouched), and ch3 tracked every `THM_AIN3` bias change. ch0/ch2 ↔
AIN0/AIN2 is inference from the same pattern. **The ADC sees the pad regardless
of the digital mux**, so no mux writes were needed.

## Files

`adc-<label>-<code>.txt` — one line per sample, four raw then four filtered
words. `sweep-*.log` — the per-bias summaries. `adcsample.sh`, `pullsweep.sh`,
`ain3direct.sh` — the sampler and the two sweep drivers (read-only on the ADC;
pad writes are read-before-write and restored). Every mean above is recomputable
from the `adc-*.txt` lines with
`awk '{s+=$11; n++} END{print s/n}' adc-ain3-0x80.txt`.

## Registers written

`0x230100c`, `0x2301018`, `0x2301030` — all read first, all restored, all
verified back at their original values afterwards (`0x00050043`, `0x00000003`,
`0x00000003`). Uptime stayed monotonic across the campaign, `nanokvm.service`
active, web UI 200.
