# Mainline TF-A BL31 on the AX630C — rung 1 hardware run, 2026-09-08

Issue #89. Full write-up: `docs/mainline-port.md` §11.9, "What exists now
(rung 1, 2026-09-08)". Device identifiers (MAC, hostname) are redacted.

`.#atf-mainline` (upstream TF-A v2.15.0 + `plat/axera/ax630c`) was written to
`atf_b` (`/dev/mmcblk0p4`) on the flashed NixOS appliance and booted from slot
B. Slot A, `p3` and the rootfs were never written.

## Result

Mainline BL31 boots the board. PSCI `CPU_ON` brings up the second core;
`SYSTEM_RESET` works. One fix was needed: `INIT_UNUSED_NS_EL2 := 1` in
`platform.mk` — without it TF-A leaves `HCR_EL2.RW` at 0 and BL33, which this
SPL enters at EL1h, runs as AArch32 and dies instantly.

## Runs

| # | `atf_b` | Result | Round trip |
|---|---|---|---|
| 1 | mainline, no fix | fell back to slot A, `boot_reason=0x05` | 133 s |
| 2 | mainline + milestones, no fix | same, milestone register `0x0007F014` | 133 s |
| 3 | **vendor** (control) | slot B boots — slot B itself is healthy | 68 s |
| 4 | mainline + milestones, no fix, kmsg marker | same; ramoops proves no kernel ran on slot B | 133 s |
| 5 | mainline + milestones + fix | **boots slot B**, `0x0007F038` | 75 s |
| 6 | mainline production + fix | **boots slot B** | 74 s |
| 7 | run 6, PSCI as the only restart handler | **`SYSTEM_RESET` resets the board**, `boot_reason=0x04` | 65 s |

Slot-A control of run 7's rig against the vendor BL31: 189 s — the kernel
halted and the hand-armed watchdog rescued it.

## Files

- `slotB-mainline-bl31-dmesg.txt` — full kernel log of run 6 (slot B, mainline
  BL31). `psci: MIGRATE_INFO_TYPE not supported`, `SMC Calling Convention v1.5`
  and the failed `optee` probe are the mainline-BL31 fingerprints; the vendor
  BL31 gives `Trusted OS migration not required`, v1.2 and `optee: revision 3.21`.
- `slotB-mainline-bl31-cpuinfo.txt` — both Cortex-A53s online, slot register,
  `bootsystem`.
- `slotA-unbind-oops-console.txt` — the ramoops console showing that unbinding
  `syscon-reboot` corrupts the restart-handler chain (`pc : 0x0` inside
  `atomic_notifier_call_chain`). A harness trap, not a BL31 result.
