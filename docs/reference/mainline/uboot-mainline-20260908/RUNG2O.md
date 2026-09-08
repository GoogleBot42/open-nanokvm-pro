# Rung 2o -- the kernel gets a device tree it cannot reach (#89)

2026-09-08. Six hardware rounds against a budget of five; the sixth was one
`fw_setenv` on an already-staged board and it is explained below.

Rung 2 is **not** done. But every "the kernel booted and never came up" round
since 2n now has a specific, measured cause, and the fix is one environment
variable.

## What the payload actually was

Worth stating, because it removes a whole class of doubt: the board's slot A is
already the **flashed NixOS appliance** (`NixOS 26.11pre-git`, mainline
`7.1.3-nanokvm`, root on p17). `.#kernel-mainline-appliance` builds `Image` at
md5 `7fb2938e258210be998eda44c854ee54` and `.#dtb-mainline` builds the dtb at
`dcfd46f14a6e49849492fac41d58cafe` -- **byte-identical to what rung 2n had
already staged**. So 2n's dark rounds were not a stale or wrong payload. Root
needed no staging at all; `APPEND` is the running board's own `/proc/cmdline`
plus `boot.panic_on_fail=1 panic=10`.

## Making a failed kernel observable

Two things had to be true at once: the watchdog must survive into the kernel,
and the kernel must not stop it.

`ax630c_wdt` stops WDT0 at probe, so the run uses a copy of the dtb with
`/soc/watchdog@4840000 status = "disabled"` (`fdtput`; the file is
`ax630c-nowdt.dtb`). That alone was not enough -- **round 2 still went dark for
eighteen minutes** -- and the reason is worth keeping:

> Disabling the node orphans the block's clocks. `clk_wdt0_eb` then has no
> consumer, and Linux's `clk_disable_unused` gates it off at late_initcall, so
> the counter stops and the dog never fires.

Adding **`clk_ignore_unused`** to the cmdline fixes it, and the next failed boot
reset itself at **337 s** -- 300 s reload plus boot -- landing on slot A with the
slot register readable. That is the observability chain working end to end for
the first time: node disabled, clock kept, dog armed by `save_boot_params`,
reset, evidence.

## The finding

With the dog now delivering the board back, the slot register read
`0x70000014`: bits 28, 29 and 30 set, **no failure bit**. So U-Boot loaded the
kernel and dtb, set `bootargs`, and reached `booti`. The pre-console buffer
survives the warm reset, and it says the rest:

```
WARNING:
The 'fdt_high' environment variable is set to ~0. This is known to cause
boot failures due to placement of DT at non-8-byte-aligned addresses.
This system will likely fail to boot. Unset the 'fdt_high' environment
variable and submit a fix upstream.
   Using Device Tree in place at 0000000049200000, end 0000000049205f58
Starting kernel ...
```

`fdt_high = ~0` had been inherited unexamined from the original rung-2 bootcmd.
Removing it produced the actual diagnosis:

```
   Loading Device Tree to 000000007e68c000, end 000000007e691f58 ... OK
Starting kernel ...
```

**`0x7e68c000` is at ~1006 MB.** The cmdline says `mem=512M`, so the kernel's
world ends at `0x60000000`. U-Boot relocates the FDT using its own `ram_top`,
which is the real 1 GiB, and hands the kernel a device-tree pointer into memory
the kernel has been told does not exist. It dies immediately, before any
console, before ramoops -- which is exactly why `/sys/fs/pstore` was empty after
every one of these boots.

That is almost certainly the whole story of 2n's two dark full-`sysboot` rounds
as well: not the eMMC, not the appliance, not the kernel. A device tree parked
out of reach.

**The fix is `fdt_high=0x5f000000`** -- a real ceiling below the kernel's memory
limit, which is what the variable is for; `~0` was the wrong value, not the
wrong idea. It was staged in the bootcmd and never got to run (below).

## The other finding: single-block reads are not reliable either

Across six rounds the environment read failed roughly half the time, always the
same way:

```
Loading Environment from MMC... Transfer data timeout
```

and when it fails, U-Boot falls back to the built-in default `bootcmd`, whose
`sysboot` then hits `Error reading cluster` partway through the 48.8 MiB kernel.
Both are single-block reads under the #91 stopgap. So the stopgap is not a clean
"single block always works": it has a residual failure rate, and it is high
enough to matter at ~100 000 blocks per kernel.

The sixth round -- the one over budget -- was spent because rounds 3 and 5 had
shown the env read working and the fix was a single `fw_setenv` on a staged
board. It lost the coin flip: the env read timed out, the built-in default ran
instead of the corrected bootcmd, and the fix has still never been exercised.

## Round by round

| # | change | slot register | outcome |
|---|---|---|---|
| 1 | appliance payload, `sysboot` | `0xB0000015` | `Error reading cluster` on `/Image` |
| 2 | explicit `load` + `booti` | -- | dark 18 min; clock gated, dog dead |
| 3 | + `clk_ignore_unused` | `0x70000014` | **337 s watchdog reset**; `fdt_high=~0` warning; kernel hung |
| 4 | `fdt_high` removed | `0xB0000015` | env read timed out; default `sysboot` ran |
| 5 | retries on each `load` | `0x70000015` | FDT relocated to `0x7e68c000`, above `mem=512M`; kernel hung |
| 6 | `fdt_high=0x5f000000` | `0xB0000014` | env read timed out; corrected bootcmd never ran |

## What the next rung needs

1. `fdt_high=0x5f000000` (or drop `mem=512M` so U-Boot's `ram_top` and the
   kernel's view agree). One round to confirm.
2. Something to make the environment read survive its own flakiness -- the
   built-in default `bootcmd` should be the corrected one, so a failed env read
   does not silently substitute a different boot path. That is a patch to
   `CFG_EXTRA_ENV_SETTINGS`, not an `fw_setenv`.
3. Then the oracle: SSH, `dmesg | grep 'SMC Calling'`, `/proc/cmdline`,
   bootcount, and a slot-B reboot -- none of which has been reachable yet.

## Files

- `rung2o-fdt-20260908.txt` -- the console excerpts and registers per round.
