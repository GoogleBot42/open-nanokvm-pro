# HDMI audio, round 2 — the bridge's own registers (#104, 2026-09-12)

Round 1 concluded "the source is not transmitting HDMI audio". **That
conclusion is withdrawn.** Jeremy's host was playing an unencrypted movie
throughout both rounds, and the host reaches the KVM through an external HDMI
**splitter** whose other leg was audibly playing that audio. The host never
sees the KVM's EDID at all — it sees the splitter's — so every EDID argument in
round 1 was beside the point.

This round asked the bridge instead.

## Method — how to read the LT6911UXC by hand

The bridge sits on `/dev/i2c-0` at `0x2b` behind the `lt6911uxc` driver, which
does not poll: it works off the GPIO interrupt, so a forced `i2cget` races
almost nothing. Two facts make a hand read work at all, and both cost a wasted
attempt to rediscover:

1. **Register access is gated.** Bank `0x80` register `0xee` must be written
   `0x01` first. Until it is, *every* register in *every* bank reads `0x00` —
   including the chip ID. A dump of all zeros means the gate is shut, not that
   the chip is dead. Write `0x00` back when finished; the driver leaves it shut.
2. **The bank select needs its own transfer.** `i2ctransfer` issuing the bank
   write and the register read as one transfer with a repeated START does not
   switch banks — the chip wants a STOP. Use `i2cset` then `i2cget`
   (`i2c_smbus_write_byte_data` + `i2c_smbus_read_byte_data`, which is what the
   driver does), and `i2ctransfer` only for the block read *after* the bank is
   already selected.

```sh
i2cset -y -f 0 0x2b 0xff 0x80; i2cset -y -f 0 0x2b 0xee 0x01   # registers live
i2cset -y -f 0 0x2b 0xff 0x90; i2cset -y -f 0 0x2b 0x10 0x00   # bridge watchdog off
i2cset -y -f 0 0x2b 0xff 0xb0                                   # audio bank
i2cget -y -f 0 0x2b 0xa5                                        # audio signal
i2cget -y -f 0 0x2b 0xab                                        # sample rate
i2cset -y -f 0 0x2b 0xff 0x80; i2cset -y -f 0 0x2b 0xee 0x00   # release
```

`lt6911-banks-source-audio-on.txt` is a 36-bank × 256-register dump taken that
way with the movie playing: banks `0x80`-`0x87`, `0xa0`-`0xa8`, `0xb0`-`0xb8`,
`0xc0`, `0xd0`-`0xd8`. 497 of its 576 rows are all-zero — those banks do not
exist. No HDMI infoframe header (`82 02 0d` for AVI, `84 01 0a` for audio)
appears anywhere in it, so the bridge does not expose parsed infoframes through
any bank this dump covers.

## What the bridge says, with the movie playing

| register | value | meaning |
|---|---|---|
| `0x81` `0x00`-`0x02` | `17 04 83` | chip ID — an LT6911UXC, and the gate is open |
| `0x86` `0xa3` | `0x55` | HDMI video signal stable |
| `0x86` `0xab` | `0x00` | no HDCP |
| `0xb0` `0xa5` | `0x03` | audio signal: the vendor's "unknown but stable" bucket |
| `0xb0` `0xaa`, `0xab` | `0x00`, `0x00` | sample rate zero |

`asr` printing `0` is therefore **not** a parser bug: the vendor driver's
`lt6911_get_audio_sample_rate()` reads exactly `0xb0:0xab` and would print the
same `0`. The bridge has locked video and has not locked an audio rate.

Stable under every perturbation tried:

- **Quiesced.** `systemctl stop nanokvm`, 25 s of nobody touching the bridge,
  then one read burst over 18 s: `a5` = `0x03`, `ab` = `0x00`, unchanged. Not a
  polling or MCU-hold artefact.
- **Fresh link-up.** `echo off > /proc/lt6911_info/hdmi_power`, 3 s, `on` —
  which drops the on-board LT86102UXE splitter's rail and makes the bridge
  re-acquire the TMDS link from scratch. Video came back at 4096x2160@29;
  `a5`/`ab` did not move at 8 s or at 18 s.
- **Loop-out off and on.** The whole `0x86:0xa0`-`0xaf` row is byte-identical
  across `loopout_power` off/on, which is how `0x86:0xa5` was shown not to be
  the loop-out's status.

## The register diff, link up versus link down

Dumping all 36 banks again with `hdmi_power` off and diffing against the dump
above is what turns a register into a reading. Bank `0x86`:

```
up    0x86 a0  01 01 04 55 00 88 00 00 00 03 00 00 00 01 00 00
down  0x86 a0  00 00 04 88 00 88 00 00 00 03 00 00 00 04 00 00
```

`0xa3` is the video register the vendor's map names, and it behaves: `0x55`
locked, `0x88` gone. `0xa0`/`0xa1` are link flags. **`0xa5` reads `0x88` in
both** — the vendor's "gone" code, with video locked — and it does not move for
the loop-out either.

Bank `0xb0`, the vendor's audio bank:

```
up    0xb0 a0  00 38 0e 00 20 03 0f 00 00 00 00 00 00 00 14 40
down  0xb0 a0  a3 28 00 00 20 03 00 00 00 00 00 00 00 00 14 40
```

**`0xb0:0xa5` = `0x03` and `0xb0:0xab` = `0x00` in both states.** The vendor's
audio-presence register does not track the HDMI link at all, so `asr` = 0 is a
constant, not a measurement — and the `0x55`/`0x88`/`0xaa` codes their switch
is written against never appear in this bank, which is why v0.0.15 had to add
a "case 0x01: case 0x03: unknown audio signal but stable" arm. The bank-`0xb0`
registers that *do* track the link are `0x80`, `0x9c`, `0x9e`, `0x9f`, `0xa0`,
`0xa1`, `0xa2` and `0xa6`; nothing we hold names any of them.

The leading reading is that the audio-presence register is `0x86:0xa5`, two
addresses after the video one and in the right code space, and that it says
the bridge sees no audio. **It is not proven**: nothing on this bench can make
audio appear at the bridge, so that register has never been observed in any
other state.

## No bridge-side audio enable exists

The vendor driver's complete set of UXC register writes is nine addresses:
bank `0x80` `0x58`-`0x5e` (SPI-flash bridge), `0xee` (register gate), `0xff`
(bank select); bank `0x81` `0x08` (flash handshake); bank `0x85` `0x40` (start
a timing measurement); bank `0x86` `0xee`; bank `0x90` `0x10` (the bridge's own
watchdog). Our port writes exactly that set and nothing more. So #81 dropped no
audio configuration — there was none to drop, and the bridge's audio output is
set up by its own firmware or not at all.

## The pads: all three audio outputs are held low

`EXT_PORT` (`0x0480008c`) only samples a pad that is muxed to the GPIO
function, so each pad word was temporarily set to function 6, sampled 400
times, and restored to function 4.

| signal | pad | pad word | GPIO | level | toggling |
|---|---|---|---|---|---|
| `I2S0_SCLK` | VI_D1 | `0x02300018` | GPIO0_A1 | **0** | no |
| `I2S0_DIN1` | VI_D4 | `0x0230003c` | GPIO0_A4 | **0** | no |
| `I2S0_LRCK` | VI_CLK0 | `0x02300084` | GPIO0_A10 | **0** | no |
| `I2S0_MCLK` | VI_D3 | `0x02300030` | GPIO0_A3 | **1** | no |

Round 1 sampled only SCLK and LRCK. **The data line matters on its own**: the
LT6911UXC can emit SPDIF instead of I2S, and SPDIF is one self-clocked line —
idle clocks with a live data pin would have looked exactly like round 1's
result. It does not. Nothing moves.

VI_D3 reading **1** while the other three read **0** is the useful control. It
proves the GPIO input path works on a pad freshly switched to function 6 (round
1 had only validated the method on pads that were already GPIO), and it says
the three audio-output pins are being *driven* low rather than floating: the
bridge's audio output block is powered down, not idle.

## The MCLK hypothesis — tested, no effect

The vendor's running 4.19 board had **four** pads on I2S0, not three:
`pinmux-regs.txt` shows `0x02300030` (VI_D3, `I2S0_MCLK`) = `0x00040003`, and
`sound/soc/axera/dwc-i2s.c:876-892` does an unconditional
`clk_set_rate(dev->i2s_mclk, 12288000)` at probe. Our port names three pads
(`dts/ax630c.dtsi:435`, "no DOUT and no MCLK") and runs `clk_i2s_ref0_eb` at
**12 MHz**, not 12.288.

Both halves were reproduced by hand, reversibly:

```sh
devmem 0x02300030 32 0x00040003                  # VI_D3 -> I2S0_MCLK
devmem 0x04870000 32 <mux [6:5] = 2>             # clk_i2s_ref0_sel -> hpll_24p576m
devmem 0x04870014 32 <div [5:0] = 1, pulse bit 6>  # /2 -> 12.288 MHz
```

`a5`, `ab`, `CER`, the SPI-145 count and `arecord` were **identical** before and
after. The bridge does not need an MCLK from the SoC to lock HDMI audio — it
recovers that clock from the stream's N/CTS — and in any case it is not driving
MCLK back at us either. All four words were restored.

So the missing fourth pad is a real vendor-parity gap and is *not* the cause of
#104. Recorded here so the next reader does not re-derive it.

## Where that leaves it

Everything from the bridge's I2S pins inward is proven correct and proven idle:
the pads are the vendor's pads with the vendor's function value, the crossbar
word and RX channel are the vendor's, the DW I2S block is configured and
unmasked, and it receives nothing because nothing is sent. The fault is
upstream of the bridge's I2S output — inside the bridge, or in what reaches its
HDMI input.
