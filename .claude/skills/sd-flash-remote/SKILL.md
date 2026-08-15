---
name: sd-flash-remote
description: Flash a built SD-card image onto the SD card that lives INSIDE the running NanoKVM-Pro device, over SSH — there is no local card reader.
---

UNVALIDATED — verify on first use. Connectivity to the device was confirmed
read-only for this bootstrap; no dd/flash operation was run (device-mutating
steps are deliberately out of scope for setup validation). In particular,
whether `dd | tools/kvmssh '...'` passes stdin through cleanly (step 3) has
not been tested — see the fallback note there.

Full procedure, BootROM internals, and troubleshooting live in
`docs/flashing-and-recovery.md`, section "SD-card boot" →
subsection "Flashing the SD card remotely (no card reader)" — that
subsection already documents almost exactly this workflow (with raw
`ssh`/`dd` instead of the `tools/kvmssh`/`tools/kvmscp` wrappers used here).
Read it before the first real run. This skill is the short, wrapper-based
version of that procedure plus the safety guard restated for emphasis.

# Procedure

1. **Build.** `nix build .#sd-image` (from the repo root; confirmed
   package name in `flake.nix`). Produces a raw, `dd`-able microSD image
   under `result/`.

2. **Safety guard — do this before anything else touches the device.**
   The device has two block devices: **eMMC is `/dev/mmcblk0`** (the boot
   drive, holds the whole running system — must NEVER be a write target
   during SD testing) and **the SD card is `/dev/mmcblk1`**. Confirm you're
   about to write the right one, and that it's the card you think it is, by
   exact sector count:

   ```
   tools/kvmssh 'cat /sys/block/mmcblk1/size'
   ```

   Compare the number against the known card's sector count —
   **31211520** for the current 14.88 GiB card. If it doesn't match, STOP;
   do not proceed. If the card has genuinely changed, re-derive this number
   on purpose (e.g. from the same command against a freshly-confirmed card)
   — never skip the guard by assuming the old number still applies.

   Also check for and clear any mounted partitions first:
   ```
   tools/kvmssh 'mount | grep mmcblk1'
   tools/kvmssh 'umount /dev/mmcblk1p* 2>/dev/null; true'
   ```

3. **Stream the image.** The card lives in the device's own TF slot, not a
   reader on the workstation, so the image goes over SSH instead of a local
   `dd`:

   ```
   dd if=result/<image>.img bs=4M | tools/kvmssh 'umount /dev/mmcblk1p* 2>/dev/null; dd of=/dev/mmcblk1 bs=4M conv=fsync && sync && echo WRITE_DONE'
   ```

   `tools/kvmssh` runs `ssh` without `-t`, so stdin should pass through the
   pipe cleanly in principle — but this exact usage (large piped stdin
   through the wrapper's `nix shell ... sshpass ... ssh "$@"` chain) has not
   been exercised. Watch for `WRITE_DONE` to confirm the remote `dd`
   actually completed rather than the pipe silently stalling or truncating.
   If the wrapper does not pass stdin through correctly, fall back to raw
   `sshpass`+`ssh`, sourcing `~/.config/nanokvm/device.env` directly for the
   IP and password rather than hardcoding them.

4. **Verify — never trust a write without this.** Drop the device's page
   cache first, or you hash the write-cache instead of what's actually on
   the card:

   ```
   tools/kvmssh 'echo 3 > /proc/sys/vm/drop_caches'
   size=$(stat -c%s result/<image>.img)
   tools/kvmssh "head -c $size /dev/mmcblk1 | sha256sum"
   sha256sum result/<image>.img
   ```
   The two digests must match exactly.

5. **Boot from the card.** This requires a physical button-hold ritual at
   power-on (not automatic on card insertion) — see
   `docs/flashing-and-recovery.md`, section "SD-card boot"
   for the exact `User`-button procedure, how to tell SD boot succeeded
   (`cat /proc/cmdline` shows `root=/dev/mmcblk1p2`), and the "If the card
   does not boot" troubleshooting sequence. Do not restate that content
   here — it changes independently of this skill.
