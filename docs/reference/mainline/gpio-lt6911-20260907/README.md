# GPIO, ATX and the LT6911UXC on a mainline kernel — #81, 2026-09-07

Two slot-B runs on the NanoKVM-Pro, kernel `7.1.3-nanokvm`, read live over the
#77 initramfs SSH. Run 2 came back with milestone register **`0x003FF014`** —
every bit — and the board returned to slot A on its own.

| | run 1 | run 2 |
|---|---|---|
| kernel md5 | `0197b260eade01823c6ed5de1efe98ce` | `bcc963d27b8f8012d25ebed6ca0fe0da` |
| dtb md5 | `4d6ecc64c21607f1ab0c060777330b66` | same |
| milestone on return | `0x003F3014` | **`0x003FF014`** |
| `.get()` reads | the DR latch when the line is an output | EXT_PORT always |

Run 1's register is short of bits 14 and 15 because the dwell was extended with
`touch /run/keepalive` to read the running system and then ended by hand from
the mainline shell — the run did not fail, it was cut. Run 2 is the unattended
one, with the EXT_PORT change run 1's measurement justified.

Files: `run1/` holds the full boot log, the debugfs GPIO and pinmux dumps, the
consolidated register reads and the EXT_PORT experiment; `run2-device-reads.txt`
is run 2's confirmation of the same state.

## What the run proves

**Four gpiochips, and the line names came from DT.** `4800000.gpio`,
`4801000.gpio`, `6000000.gpio`, `6001000.gpio`, 32 lines each, with
`atx-power`, `atx-reset`, `atx-hdd-led`, `atx-power-led` and `sys-heartbeat`
named exactly as the board dts spells them. Nothing holds the four ATX lines,
which is correct — they belong to userspace, and `nanokvm-gpio` asks for them
by those names.

**`gpio_request_enable()` ran, and it moved real pads.** #80 shipped it
untested; this is its first exercise on silicon. Four pad words differ from what
the boot chain's own table writes, and the difference is the mux field:

| Pad | Boot table | After the GPIO claim | Function |
|---|---|---|---|
| `EPHY_LED0` `0x104f006c` | `0x00000083` | **`0x00060083`** | `EPHY_LED0` → `GPIO1_A28` |
| `CDTX_L3P` `0x0230a060` | `0x00000003` | **`0x00060003`** | `DPHY_TX` → `GPIO2_A17` |
| `CDTX_L4N` `0x0230a06c` | `0x00000003` | **`0x00060003`** | `DPHY_TX` → `GPIO2_A18` |
| `CDTX_L4P` `0x0230a078` | `0x00000003` | **`0x00060003`** | `DPHY_TX` → `GPIO2_A19` |

Those are the four pads the vendor's LT6911 driver re-muxes by hand with a raw
`iowrite32` — the same trap class as SW_PWR, and now the pin controller's job.
The pull-up on `EPHY_LED0` survives the mux change because it comes from a
config-only pin state, which was the point of writing one.

`pinmux-pins` lists nine pads owned as GPIO (`VI_D5`, `VI_D6`, `EPHY_RSTN`,
`EPHY_LED0`, `CDTX_L3P`, `CDTX_L4N`, `CDTX_L4P`, `TMS`, `SD_PWR_EN`) alongside
the eMMC, SD, UART0 and — new here — I2C0 states. `VI_D7` is deliberately
absent: nothing claimed `atx-power`, so the pad sits where U-Boot left it, and
because no peripheral state names it, nothing can take it.

**The GPIO interrupt controller works end to end.** Three lines on two chips
carry IRQs (`lt6911-int`, `lt6911-rx-detect`, `lt6911-tx-detect`), and
`lt6911-int` had fired three times by the time the log was read. Everything the
LT6911 driver reports about the attached source is the *product* of those
interrupts, so the chained handler, the non-secure `INTSTATUS` read, the
both-edge configuration and the manual `EOI` pulse are all exercised.

**The reset provider's `.status` is exercised; nothing was ever asserted.**
`SW_RST0` (`0x04870018`) reads `0x00000001` — the audio codec, held by
firmware — with all eight GPIO reset bits clear, and no controller logged the
"reset was asserted at probe" line. `.assert` and `.reset` remain untested on
silicon, deliberately: lines on these blocks drive the host's ATX power button
and the HDMI receiver's rails, and a reset pulse at probe would be a keystroke
nobody pressed.

**The LT6911UXC answers, on I2C, with real video.**

```
chip_id         lt6911uxc
power/hdmi_power/loopout_power   on / on / on
status          new res
width           4096
height          2160
fps             29
hdcp            no hdcp
hdmi_rx_status  access
version         NanoKVM_Pro (Desk-A) NeaL00275
```

The geometry is the attached bench host at DCI 4K. `version` carries the `Desk`
token and the device number as its last field, which is what the Go server
parses. `edid_snapshot` returns a full 256 bytes beginning `00 ff ff ff ff ff
ff 00`, with **byte 12 = `0x36`** — the byte the server keys `EDIDMap` on, and
the byte the vendor's own read handler destroyed by writing `"unknown\n"` over
the first nine on every read.

**Fourteen new clock rows, corroborated against the #80 boot.** `CLK_MUX0`
reads `0x000FBF9A`: bits [4:3] = `11`, which the vendor I2C driver's own comment
calls 208 MHz, and `clk_summary` independently reports `clk_i2c_sel` at
208000000. `CLK_EB0` reads `0x00007DE3` where #80's run read `0x00007DE7` — the
single differing bit is bit 2, which is exactly the bit newly registered as
`clk_i2c_eb` and which the DesignWare driver's runtime PM gates between
transfers. `EB1` bits 4–7 and `EB2` bits 13–16 are all set, the four GPIO
functional and APB gates. `clk_gpio_sel` reads 32768 Hz: firmware leaves the
debounce source on the RTC output and nothing here changes it, because nothing
uses the filter.

Three artifacts agree on the clock count: the source tables, the compiled
`vmlinux` symbol sizes (`ax630c_*_clks` at 56 bytes a row — common 135, mm 40,
periph 41, flash 30, dispc 14, cpu 11, vpu 7, pllc 1 = **279**), and
`clk_summary` on the running kernel, which lists 280 distinct names: those 279
plus the DT `fixed-clock` `sysclk`.

**Nothing regressed.** eMMC came up HS200 with all 17 partitions, Ethernet
negotiated and carried the session this evidence was collected over, the
watchdog resolved 24 MHz and was petted for the whole dwell, `devices_deferred`
is empty, and there is no WARN or oops anywhere in either log.

## Not proven

- **`nanokvm-gpio` has never run on hardware.** It targets the NixOS appliance
  (#78) and is dynamically linked against that closure, so it does not run on
  the vendor rootfs and there is no mainline userspace to run it in yet.
  The ATX pulse path is therefore unexercised end to end — the kernel half is
  proven, the tool is not.
- **No ATX line was driven.** Pressing `atx-power` presses the button on the
  machine the KVM is attached to. The lines are claimed by no one and read
  correctly; that is as far as an unattended test should go.
- **`edid` and `version` writes** — both program the bridge's SPI flash. Read
  paths are proven; the write paths are transcribed and untested.
- **`.assert` / `.reset` on the reset provider**, for the reason above.
- The **`force_*` module parameters** read back `-1` and were not set.
