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
- **The pinctrl register model is right, and the `0xC` stride is a slot.** Pad
  words appear every `0xC` bytes and the two words between them read zero
  because they are the write-1-to-set and write-1-to-clear aliases — write-only,
  so a slot is `{VALUE, SET, CLR}` rather than a word plus padding. See
  `../pinctrl-model-20260906.md`.
- **The SW_PWR pad is confirmed end to end.** `0x02300060` reads back
  `0x00060003` live: function `[18:16]` = 6 (GPIO0_A7), drive `[3:0]` = 3. That
  address is `VI_D7_OFFSET = 0x60` in the vendor pad table, and function 6 is
  GPIO — the entry the SW_PWR pinmux trap turns on (`docs/mini-display.md`).
- **What this dump does *not* cover.** It reads `0x600` bytes from each of the
  two pinctrl windows, which lands entirely inside the first pad block. The 111
  pad offsets are not a dense run: they reach `0xa078`, grouped in blocks, 77 in
  the window at `0x2300000` and 34 in the one at `0x104f0000`. Within a block
  the register space aliases (offset `n` and `n + 0x200` read identically here),
  so do not infer a pad count from a contiguous dump — take the offsets from the
  spec's pad table.
- **Which clocks the firmware leaves running.** The enable/prepare counts say
  what a first mainline boot can treat as already-on: a bring-up that models
  only gates does not have to bring up the PLL tree to reach a shell.

## Reading them again

`docs/mainline-port.md` section 9 carries the full command list. Everything
there is read-only, but note the standing trap: **never read `0x04403000` on an
open boot** — the MM/VPP domain is unclocked and the AXI read hangs the bus into
a watchdog reboot. The two pinctrl bases dumped here are not in that domain and
are safe.
