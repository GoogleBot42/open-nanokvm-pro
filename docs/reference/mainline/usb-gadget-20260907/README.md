# USB on the mainline kernel — device run, 2026-09-07 (#82)

**A machine on the other end of the cable enumerated a mainline-kernel gadget
from this board.** One slot-B run, milestone register `0x01FFF014` on return —
every bit, including the three new ones. Slot A came back on its own.

Files here:

- `mainline-dmesg.txt` — the whole kernel log as `/init` stashed it in reserved
  DRAM, in `/dev/kmsg` record format (`<prio>,<seq>,<usec>,-;<text>`).
- `mainline-console.txt` — the ramoops console zone. 16 KiB, so it covers the
  early boot only; the stash above is the full run.

IP addresses and the board's MAC are replaced with `<redacted-ip>` /
`<redacted-mac>` in both files; nothing else is altered.

Everything below was read from the running mainline kernel over SSH during the
300 s dwell.

## The run

| | |
|---|---|
| Kernel | `7.1.3-nanokvm`, slot B |
| Milestone register on return | `0x01FFF014` (bits 12–24 + slot A re-armed) |
| Glue probe | `t = 1.10 s` |
| Gadget bound | `t = 12.63 s` |
| Host enumerated it | `t = 13.63 s` — 1.0 s later |
| Dwell | 300 s, `watchdog0 timeleft=27` at every 10 s sample |
| Exit | self-reboot through the watchdog restart handler, SPL fell back to slot A |

```
[    1.101096] axera-dwc3 soc:usb@8000000: 2 clocks, VBUSVALID set (peripheral mode)
[   12.594773] openkvm: usb: UDC is 8000000.usb
[   12.614532] openkvm: usb: 5 of 5 usbdev.sh function drivers present
[   12.627246] openkvm: usb: HID keyboard gadget bound
[   13.632736] openkvm: usb: host enumerated and configured us
```

Nothing in the log complains. The dwc3 core is silent, which is what it is
when it is happy.

## The UDC

```
/sys/class/udc/8000000.usb/state          configured
/sys/class/udc/8000000.usb/current_speed  high-speed
/sys/class/udc/8000000.usb/function       g0
/sys/kernel/config/usb_gadget/g0/UDC      8000000.usb
```

`state = configured` is the host-side answer measured from the device: a
machine on the other end enumerated us, read our descriptors and selected a
configuration. `high-speed` is right — this is a USB2-only integration.

The gadget is what `/init` built: `functions/hid.GS0` and the symlink
`configs/c.1/hid.GS0`, one boot-protocol keyboard interface.

The five function drivers `usbdev.sh` needs — HID, mass storage, NCM, UAC2,
ACM — were each instantiated by a `mkdir` under `functions/` and removed
again. **5 of 5.** That is a presence test for the drivers, not a test of the
functions: nothing here ran a mass-storage LUN or an NCM link.

## The clocks

`clk_summary` on the running kernel, the rows that matter:

```
usb_ref_alt_clk_eb     1  1  0          0    Y  usb@8000000    no_connection_id
clk_flash_glb_sel      2  2  0  312000000    Y  deviceless     no_connection_id
   bus_clk_usb_eb      1  1  0  312000000    Y  usb@8000000    no_connection_id
   clk_usb_ref_eb      1  1  0   24000000    Y  8000000.usb    ref
```

**`clk_usb_ref_eb` reads 24000000 and is bound to the core as `ref`.**
Mainline's `dwc3_ref_clk_period()` derives `GUCTL.REFCLKPER`,
`GFLADJ.REFCLK_FLADJ` and `GFLADJ.240MHZDECR` from `clk_get_rate()` on this
clock, and 24 MHz exactly is what reproduces the vendor glue's `0x29`, `0x7f0`
and `0xa`.

Two different strengths of claim in that row, and they should not be blurred.
The **consumer column is independent evidence**: it comes from the clock
framework's own consumer list and is what proves the DT split works — the
glue node holds two clocks, the core node holds this one, and the core really
did `clk_get(dev, "ref")`. The **rate is not a measurement**; `clk_summary`
echoes the driver's own parent table (`cpll_24m`, a fixed-factor row). What it
does establish is the number the core's arithmetic actually ran on. The
silicon evidence for 24 MHz is elsewhere: #80 measured `cpll_24m` at
24.007 MHz, and the vendor's hardcoded `0x7f0`/`0xa` are only reproducible
from a rate of exactly 24000000.

`clk_flash_glb_sel` has **two** users and still reads 312 MHz. That is the
flash domain's AXI bus, shared with the EMAC and both SD hosts; the USB gate
hangs off it deliberately without `CLK_SET_RATE_PARENT`, and nothing moved it.

`usb_ref_alt_clk_eb` reads 0 because it is modelled with a NULL parent — its
source is not established in any artifact we have. It is enabled, which is all
the glue asks of it.

## The registers

Read from the running mainline kernel with `busybox devmem`, flash syscon at
`0x1003_0000`:

| Word | Value | What it says |
|---|---|---|
| `+0x40` USB2_CTRL | `0x00000060` | **bit 6 VBUSVALID set** — the one write only a glue driver can make |
| `+0x14` SW_RST0 | `0x3C0002E0` | bits 24 and 25 **clear**: both USB software resets released |
| `+0x04` CLK_EB0 | `0x00007A2C` | bit 12 (`usb_ref`) and bit 14 (`usb_ref_alt`) set |
| `+0x08` CLK_EB1 | `0x000FF03F` | bit 5 (`bus_clk_usb`) set |
| `+0x00` CLK_MUX0 | `0x00330B60` | `[8:6] = 0b101` = `cpll_312m`, exactly as firmware left it |

The three gate bits are the direct confirmation of the id-to-bit arithmetic
the tables were written from: ids 13, 11 and 40 land on bits 12, 14 and 5, in
the two words predicted.

## What the reset pulse proved, precisely

`reset_control_assert()` and `reset_control_deassert()` both returned 0 and
probe carried on to log VBUSVALID — so **#80's reset provider's `.assert` path
executed and its regmap writes succeeded**, which nothing before this run had
exercised. SW_RST0 bits 24/25 read clear afterwards, the released state.

What the register read alone does *not* prove is that the bits were ever set,
because a clear reading is also what "nothing was written" looks like. The
evidence that the pulse did something is circumstantial and worth stating as
such: a warm reboot does not reset this SoC's USB2 PHY, the port was
`configured` to the same host under the vendor system a minute earlier, and
after this boot the host enumerated a *different* device (`1d6b:0104`,
"NanoKVM-Pro mainline bring-up") one second after the gadget bound. Catching
the asserted state needs a read from inside the pulse, which is 2 µs long.

## Three bits, not one

The USB step writes milestone bits 22 (a UDC registered), 23 (all five
function drivers present and the gadget bound) and 24 (a host enumerated it).
Only 24 depends on the cable, and this unit's USB link has been unreliable
since 2026-09-05. On this run all three are set, so the split bought nothing —
but the run before it, on the vendor system, is what confirmed a host was
attached at all (`/sys/class/udc/8000000.dwc3/state` read `configured` before
the reboot), and that check is the one to make first when 24 comes back clear.

## Not proven

Mass storage, NCM, UAC2 and ACM as *running* functions; any transfer over the
HID endpoint; suspend and resume; host mode; OTG role switching (there is no
GPIO controller until #81, so `dr_mode` is `peripheral`).

## One correction

The glue logs **2 clocks**, not the 3 an earlier draft of `mainline-port.md`
predicted. That is the design working: the glue node names `bus` and
`ref_alt`, and `ref` belongs to the core node so the dwc3 core can take its
rate. Two is the right number and the doc has been fixed.
