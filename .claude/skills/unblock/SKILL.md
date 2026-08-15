---
name: unblock
description: Produce a ranked list of HUMAN actions (things only Jeremy can do — physical device tests, hardware pokes, account/forge admin) that would unblock the most downstream agent work.
---

# Unblock

Finds the things that need a human hand — physical access to the
NanoKVM-Pro device, a button press, a forge/account decision — and ranks
them by how much downstream agent work each one frees up.

## Procedure

1. Read `../work-sources.md` (full path:
   `.claude/skills/work-sources.md`) for
   the current inventory of hardware-validation gaps and known
   inconsistencies.
2. Pull the live `needs-human` slice from Gitea, which is exactly this
   list, pre-tagged:
   ```sh
   tea issues list --repo zuckerberg/open-nanokvm-pro --labels needs-human
   ```
   As of the last check this includes: #7 (SD card image in releases),
   #8 (docs need human touch), #9 (SD-card image never booted on
   hardware), #10 (OTA A/B slot failover never exercised on hardware),
   #11 (mini-display final on-device boot test), #28 (decide pending
   blobs: aic8800 WiFi/BT, axbox syslog, eip_ax620e.bin), #31 (OTA updates
   unsigned), #32 (default root password "sipeed" with SSH enabled).
   Re-pull rather than trusting this list verbatim — it changes.
3. Identify items blocked on either:
   - **Physical access to the device**: on-device boot tests (SD image,
     A/B failover, mini-display panel bring-up), AXDL button-press
     flashing/recovery, serial/UART probing (blocked separately on locating
     the console pads per `nanokvm-pro-blob-audit.md` memory — "UART0
     console pad location UNDOCUMENTED... need BOARD PHOTO").
   - **Human decisions**: forge/CI migration choices (the GitHub-vs-Gitea
     release pipeline split in the sources file — someone has to decide
     the Gitea Actions/release approach), security tradeoffs that are
     policy calls not code calls (default password, unsigned OTA), and the
     "pending blobs" triage (#28) which is a keep-or-replace call, not an
     engineering one.
4. Rank by **downstream-work-unblocked**: how much agent work becomes
   possible, or how much uncertainty collapses, once this human action
   happens. A device boot test that finally proves or disproves the SD-SPL
   chain outranks a small doc fix.
5. Tag each with:
   - **Effort**: minutes / hour / long (e.g. "flip a button while
     power-cycling" is minutes; "solder a serial adapter" is long).
   - **Risk**: reversible (pull the SD card, power-cycle) / destructive
     (eMMC writes, A/B slot flashing without proven fallback — see the
     "our from-source kernel NEVER proven to boot" + "bad flash needs
     physical AXDL-only recovery" notes in `nanokvm-pro-blob-audit.md`
     memory).

## Output

A short table — Action | Effort | Risk | What it unblocks — followed by,
for the top few, a sentence on what becomes possible afterward (e.g. "once
SD boot is confirmed working, the A/B eMMC failover test and the mini-
display boot test can both piggyback on the same non-destructive SD path
instead of needing an eMMC write").

## Failure modes

- Don't rank by "easy for me to describe" — rank by actual downstream
  unblocking. A five-minute button press that proves out the entire SD
  boot chain (which several other tests are waiting on, per the sources
  file) outranks a longer but isolated task.
- Don't quietly upgrade a "reversible" item to "destructive" scope creep —
  e.g. testing A/B failover by deliberately corrupting a slot is what
  issue #10 calls for, but do it on a slot the eMMC backup
  (`scratchpad/fw-backup-20260718/`, per memory) actually covers, and say
  so explicitly rather than assuming it's safe.
- Cross-check against the memory dir before proposing anything the user
  already tried and stopped: the SD-boot chase was explicitly dropped
  after four failed hardware attempts (`nanokvm-pro-blob-audit.md`,
  "SD-BOOT CHASE ... DROPPED by user") — re-proposing the identical
  approach without new information (e.g. a way to get serial console
  access) is not a fresh unblock, it's re-litigating a decision.
