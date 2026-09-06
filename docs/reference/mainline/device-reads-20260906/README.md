# Device reads for the mainline port (#26), 2026-09-06

Read-only captures from the running NanoKVM-Pro, taken to ground the mainline
driver work in what the silicon and firmware actually do rather than in what the
vendor tree says they do. This is the set `docs/mainline-port.md` section 9 asks
for; it was collected for **#80** (clock + pinctrl) but serves every child issue.

State of the device when captured: the shipped open stack (Linux 4.19.125
vendor kernel, our three from-source modules, zero vendor `ax_*.ko`).

| File | Command | What it settles |
|---|---|---|
| `clk_summary.txt` | `cat /sys/kernel/debug/clk/clk_summary` | The complete registered clock tree with live rates, parents and enable counts |
| `gpio.txt` | `cat /sys/kernel/debug/gpio` | Which GPIO lines are claimed today, by which driver, direction and IRQ |
| `pinmux-regs.txt` | `devmem` word loop over both pinctrl bases | The live pad mux/pull/drive words |
| `iomem.txt` | `cat /proc/iomem` | Confirms the inventory's register windows |
| `interrupts.txt` | `cat /proc/interrupts` | Confirms IRQ numbers and their owners |
| `platform.txt` | `ls /sys/bus/platform/{devices,drivers}` | What actually probes on this board |
| `cmdline-model.txt` | `/proc/cmdline`, `/proc/device-tree/model` | The real boot contract, incl. `blkdevparts=` |

## What these already prove

- **246 clocks come from the clock driver, not 247.** `clk_summary` has 247
  rows, but `sysclk` is an unrelated 10 MHz DT `fixed-clock` with no consumer
  (`AX620E.dtsi:127`) — section 2's "247 registered" counts it by mistake. The
  remaining 246 partition exactly, and a from-scratch driver must reproduce the
  split: **86 gates** (`_eb`), **50 muxes** (`_sel`), **20 dividers** (16
  `_divn` + 4 `_divn_flash` — a suffix match on `_divn` alone undercounts), and
  90 roots, fixed-factor taps and the one PLL. See `../clk-model-20260906.md`.
- **The pinctrl register model is right.** Pad words appear every `0xC` bytes
  with the two intervening words reading zero, so the stride is real and not an
  artefact of the vendor's table. `0x02300060 = 0x00060003` reads back live:
  function field `[18:16]` = 6, drive `[3:0]` = 3 — the VI_D7 → GPIO0_A7 entry
  that the SW_PWR pinmux trap turns on (`docs/mini-display.md`).
- **Which clocks the firmware leaves running.** The enable/prepare counts say
  what a first mainline boot can treat as already-on: a bring-up that models
  only gates does not have to bring up the PLL tree to reach a shell.

## Reading them again

`docs/mainline-port.md` section 9 carries the full command list. Everything
there is read-only, but note the standing trap: **never read `0x04403000` on an
open boot** — the MM/VPP domain is unclocked and the AXI read hangs the bus into
a watchdog reboot. The two pinctrl bases dumped here are not in that domain and
are safe.
