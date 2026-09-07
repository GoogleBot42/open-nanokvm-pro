# Pad SET/CLR aliases and the G2/G5/G7 pull encoding — device probe, 2026-09-06

Two questions `pinctrl-model-20260906.md` left open and told us to settle on
hardware rather than by more reading (§1.2 aliases, §1.4 + §9 item 2 pull
encoding). Both were probed on the live device with `devmem`; every pad written
was read first and restored afterwards, and all nine were confirmed back at
their original values with the device still healthy.

## 1. Per-pad SET/CLR aliases — CONFIRMED

The `0xC` stride really is a `{VALUE, SET, CLR}` slot. On `MICN_L_D`
(`0x2305018`), writing `0x10` to `VALUE+4` set bit 4 of VALUE; writing `0x10` to
`VALUE+8` cleared it. Repeated on `MICP_R_D` (`0x2305030`) with a multi-bit
field (drive strength `0x5`) — set, then cleared. Clearing bits that were not
set is a no-op. Both alias words read back `0x00000000`, i.e. they are
write-only.

**Consequence, applied:** the pinctrl driver writes fields through the aliases
and has no lock. A field update is two writes that name only the bits they
touch, so it never reads, never clobbers another field of the same pad, and
pads do not contend with each other. The cost is that a multi-bit field passes
briefly through the value with those bits cleared; that is acceptable because
`.strict = true` means nothing else holds the pad during a mux change.

## 2. G2/G5/G7 pull encoding — SETTLED LATER THE SAME DAY: EN/SE

**This section records a null result that was superseded within hours.** The
digital probe below could not separate the two readings; switching oracle from
the GPIO input register to the on-chip **ADC** did, on the first pad tried.
The answer is EN/SE — bit 6 enables, bit 7 selects — confirming the driver as
written. See [`pull-encoding-adc/README.md`](pull-encoding-adc/README.md).

Two corrections to what is written below, both worth keeping because they are
easy mistakes to repeat:

- **"pull-up beats pull-down in contention on this silicon" is unsupported.**
  It was inferred from `VI_D2` reading high at `0xC0`, but `VI_D2` has an
  external pull-up, so that reading says nothing about contention. Struck.
- The reason a digital read could not settle this is not only the external
  pull-ups: `THM_AIN3` floats at ~65% of full scale, a level the GPIO input
  buffer does not resolve usefully, while the ADC reads it directly.

The original null result follows, unedited apart from those strikes.

### The digital probe (superseded)

The question: on the analog-capable groups, is bit 6 a pull *enable* with bit 7
selecting up/down (the `pinctrl-axera.c` reading), or is it one-hot like every
other group (bit 7 = up, bit 6 = down)? The two disagree only about `0x80`:
one-hot calls it pull-up, EN/SE calls it *no pull*.

Sweeping all four bias codes on `MICN_L_D` (G7, `gpio-37`, unclaimed):

| bias | reads | one-hot says | EN/SE says |
|---|---|---|---|
| `0x00` | 1 | no pull | no pull |
| `0x40` | 0 | pull-down | pull-down |
| `0x80` | 1 | pull-**up** | no pull |
| `0xC0` | 1 | up + down | pull-up |

`0x40` pulling the pad to 0 proves the pull circuit works and is stronger than
whatever holds the pad high. But **`VI_D2` (`0x2300024`, `gpio-2`), a pad
outside the G ranges and therefore known one-hot, produces an identical table**
— including `0xC0` reading 1 (which I wrongly read as "pull-up beats pull-down in
contention" -- see the correction above). So the G7 pad is indistinguishable from a known
one-hot pad, which is consistent with one-hot but is not proof: the pad sits on
an external pull-up, and "internal pull-up" and "no pull" both read 1 there.

Settling it needs a pad that floats *low*, where `0x80` would read 1 under
one-hot and 0 under EN/SE. **No such pad exists on this board.** Every G2/G5/G7
pad is either externally pulled up (the four `MIC*_D` mic pads) or held low hard
enough that no internal pull moves it, `0xC0` included — `THM_AIN0/2`
(`gpio-14`/`gpio-12`), `GPIO3_A3` (`gpio-99`); `BOND0..2` are straps and
`TMS`/`TCK`/`SD_PWR_EN`/`EMMC_PWR_EN` are claimed or unsafe to borrow.

So the driver keeps the specification's per-pad `pull_enc` flag and the EN/SE
reading for the 20 G2/G5/G7 pads, unchanged. A definitive answer needs a meter
on a pad, not another register experiment.

## A trap this probe cost time on

**A GPIO input register reads 0 for a pad that is not muxed to GPIO.** `VI_D2`
read 0 in a bank-wide `EXT_PORTA` snapshot while sitting at function 0, and read
1 as soon as it was muxed to function 6 — the input buffer follows the mux. Two
candidate oracles were picked and discarded on the strength of that false "floats
low" reading before the cause was spotted. Mux the pad to GPIO *first*, then read
its level. Worth knowing for #81.

## Registers touched (all restored)

`0x2300024` `0x230100c` `0x2301018` `0x2301024` `0x2301030` `0x2302030`
`0x2305018` `0x2305024` `0x2305030`, plus a transient sysfs export of `gpio-37`.
