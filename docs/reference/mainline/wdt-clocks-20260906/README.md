# The watchdog on CCF clocks and resets, and the first DT pin states (#80)

Slot-B boot on the NanoKVM-Pro, 2026-09-07 06:36 UTC, kernel `7.1.3-nanokvm`
built from branch `worktree-agent-a7bdb380adc3c814a` (`e355861`, rebased onto
`b2935d8` = #77). Run under `.claude/skills/mainline-boot-test`; slot A and the
rootfs were never written, and slot B was restored to the vendor kernel and dtb
afterwards.

What this run had to prove, and did:

| Claim | Evidence here |
|---|---|
| The watchdog resolves its counter rate through CCF, not a constant | `dmesg-mainline.txt:216` — `ax630c-wdt 4840000.watchdog: counter at 24000000 Hz, timeout 60s, max 357s`, and no `counter clock reports no rate` warning anywhere |
| The six WDT clock IDs address the right bits | `clk_summary.txt`: `clk_wdt0_sel` under `cpll_24m` at 24 MHz, `clk_wdt0_eb` consumed by `4840000.watchdog` as `wdt`, `pclk_wdt0_eb` as `apb`; `periph-registers.txt` shows the matching hardware bits |
| The reset lines are released through the new provider | probe reached `devm_clk_get_enabled()` at all, which only happens after both `reset_control_deassert()` calls returned; `SW_RST3` reads `0x00000000` |
| The dog is petted, not merely armed | `watchdog-samples.txt`, `ramoops-console.txt` and the `openkvm: alive …` lines: `timeleft` holds 26–29 s across a 3600 s dwell and never trends down, then the board reboots itself |
| The board comes back on its own | `milestones.txt` — `0x003FF014` read from slot A afterwards, every bit 12–21 |
| The pin states apply and the pads are owned | `pinmux-pins.txt` — 19 pins claimed by `1b40000.mmc`, `104e0000.mmc` and `4880000.serial`; `pinconf-claimed.txt` — every pad's bias and drive code matches the boot table |
| eMMC still enumerates with a state applied | `dmesg-mainline.txt` — HS200, all 17 partitions, ext4 mounted and read |
| Ethernet still comes up (#77 unbroken) | `dmesg-mainline.txt` — RGMII, 1000 Mbit/s full duplex, DHCP lease, dropbear |

## The register-level check that matters

`periph-registers.txt`, read from the running mainline kernel:

```
CLK_MUX0  0x04870000 = 0x000FBF9A   bit 19 SET   -> wdt0 counter on cpll_24m
                                    bit 20 clear -> wdt2 counter on rtc_out_32k
CLK_EB0   0x04870004 = 0x00007DE7   bit 14 SET   -> wdt0 counter gate open
                                    bit 15 clear -> wdt2 counter gated off
CLK_EB3   0x04870010 = 0x000FFFDF   bit 19 SET   -> wdt0 APB gate open
                                    bit 20 clear -> wdt2 APB gated off
SW_RST3   0x04870024 = 0x00000000   all four WDT reset bits released
```

Two of those words differ from what the **vendor** kernel leaves
(`wdt-model-20260906.md` §13 measured `CLK_MUX0 = 0x0007BFDE` with both mux bits
clear, and `CLK_EB0 = 0x0003FEFF` with bits 14 *and* 15 set). So this is not
firmware state read back: bit 19 of `CLK_MUX0` is set because the DT's
`assigned-clock-parents` asked for it, and bit 15 of `CLK_EB0` is clear because
`clk_disable_unused()` gated wdt2's counter — a block nothing on this board
pets, which is the safe direction. Both were predicted in the table comments
before the boot.

## A count, from a third artifact

`clk_summary.txt` has 273 data lines; eight of them are extra-consumer
continuation lines, so it describes **265 registered clocks** — the same number
the source macros give and the same number the `vmlinux` symbol sizes give
(common 135, mm 40, flash 30, periph 27, dispc 14, cpu 11, vpu 7, pllc 1).
Recompute it with:

```
tail -n +4 clk_summary.txt | awk '{print $1}' | sort -u | grep -vc deviceless
```

The tree claimed 246 until this branch; #76 added thirteen rows for storage and
serial and left every comment behind.

## Files

| File | What it is |
|---|---|
| `dmesg-mainline.txt` | the whole mainline boot log, read live over SSH during the dwell |
| `clk_summary.txt` | `/sys/kernel/debug/clk/clk_summary` from the running mainline kernel |
| `pinmux-pins.txt` | every pad and its owner; 19 claimed, the rest `UNCLAIMED` |
| `pinconf-claimed.txt` | bias and drive code read back per claimed pad |
| `watchdog-samples.txt` | five `timeleft` samples three seconds apart, mid-dwell |
| `ramoops-console.txt` | the ramoops console zone, read back from slot A: covers the end of the dwell and the reboot |
| `stash-dmesg.txt` | the log stash `/init` wrote at `0x480e8000`, read back from slot A |
| `milestones.txt` | the milestone register at each step, and what each bit means |
| `periph-registers.txt` | the six peripheral syscon words the WDT clocks and resets live in |

Device IPs, the netmask and the interface MAC are redacted in every file as `DEVICE_IP`,
`REDACTED_IP`, `REDACTED_MASK` and `REDACTED_MAC`, matching
`../ethernet-boot-20260906/`.

## What this run did NOT prove

- **The watchdog's own restart handler.** It sits at priority 128, behind
  `syscon-reboot` at 192, so an orderly reboot never reaches it. Unchanged from
  #75.
- **Any reset line being asserted.** Nothing on this board asks for one yet;
  the watchdog only deasserts, and firmware had already left those bits clear.
  `.assert`, `.reset` and `.status` are written and compiled but untested on
  hardware.
- **The i2c0/i2c7 pin states.** Declared, unreferenced, and therefore never
  applied — there is no I2C controller node to attach them to.
- **RGMII pin states.** The `gmac` node arrived with #77, after this branch was
  written, and has no `pinctrl-0`. Adding one is a follow-up: the pads are in
  the boot table, but getting them wrong takes out the SSH path that makes this
  test readable.

## How the run ended

The dwell was extended to the 3600 s hard cap by `touch /run/keepalive` from the
SSH session, so the watchdog was petted continuously for an hour against a 60 s
timeout — 120 stage boundaries, none of which fired. The last lines of the
ramoops console zone:

```
[ 3608.070470] openkvm: alive 3590s/3600s, watchdog0 state=inactive timeleft=28
[ 3618.087891] openkvm: rebooting via the restart handler
[ 3619.124014] reboot: Restarting system
```

`timeleft` reads 28 in **all 35** heartbeat lines the console zone holds, and 26
in every line of the earlier stash. It never once trended toward zero.

The board rebooted itself back to slot A, and the milestone register read
`0x003FF014` — every bit 12–21 — from the vendor system afterwards
(`milestones.txt`). Slot B was then restored to the vendor kernel and dtb, both
verified from the medium against the backups taken before the run
(`0a19b720189baad4aec9375931ad9c95` for p13, `e3b8750012fab3dbd8201a818459987a`
for p15), the milestone bits cleared with the current `0x3FF000` mask, the slot
register confirmed at `0x00000014`, `nanokvm.service` active and the web UI 200.
