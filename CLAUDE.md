# open-nanokvm-pro

From-source Nix rebuild of the Sipeed NanoKVM-Pro (AX630C) firmware. Start with
`README.md` (build/flash quick start); the `docs/` tree is authoritative and kept
current. Unmodified upstream Sipeed clones live at `../NanoKVM` and `../NanoKVM-Pro`
(reference only, never edit).

A second, DORMANT project shares this history: a from-source SG2002 NanoKVM rebuild,
not started, blocked on packaging a T-Head C906 GCC. Its frozen research log is
`docs/plan-sg2002-research.md` (last substantive entry 2026-07-18 — also covers early
Pro reverse-engineering; current Pro truth is `docs/` and git history, not that log).

## Web UI is a fork (2026-09-05)

Sipeed's web UI lives in-tree at `web/` (GPL-3.0 fork of `NanoKVM-Pro/web` at
`8d0557b`; provenance in `web/FORK.md`). Edit it as ordinary source — there is no
patch stack any more; `pkgs/nanokvm-web.nix` builds `web/`. The Go server is still
upstream + nix-time patches in `pkgs/nanokvm-server.nix`. Browser facts measured
2026-09-05: Linux Firefox and Chrome decode HEVC for `<video>` but expose none through
WebCodecs, so H.265 reaches them only via the MediaSource player (`mse-player.tsx`).
**Never assert browser codec support without measuring it** (`web/`'s probes log every
answer to the console; the Firefox/Chromium headless harnesses under
`docs/reference/vcenc-open/{h264-direct-chromium,mse-player}-20260905/harness/` run the
real UI through an SSH loopback tunnel). `index.html` now ships `no-cache` + a content
ETag and hashed assets ship `immutable` (#71 fixed 2026-09-05) — a warm browser picks
up a deploy on its own. **Chromium refuses to cache any response whose certificate
errored**, so a harness using `--ignore-certificate-errors` makes every resource look
uncacheable; pin the cert instead (`--ignore-certificate-errors-spki-list`,
`docs/reference/vcenc-open/cache-headers-20260905/harness/`). **Chromium with
`chrome://flags/#enable-vulkan` (Skia Vulkan backend) paints every `<video>` white on
Wayland** (#69): decoded frames never import, WebCodecs/canvas modes are unaffected,
and the only page-side oracle is `VideoFrame.copyTo()` throwing `InvalidStateError`
(pixel reads return opaque black, indistinguishable from a black host screen).
Headless-KWin/sway harness that reproduces it:
`docs/reference/vcenc-open/chromium-white-compositors-20260905/`.
**One capture channel serves every viewer**, gated by the global
`KvmVision.StreamType`: a second viewer in another mode — another tab, a
`curl /api/stream/mjpeg`, a stray mode POST — takes the stream and starves the
first, which the page reports as "inconsistent video mode". Upstream never gave
it back (that half of #69 looked like a rendering bug for a week); since
2026-09-06 `service/stream/claims.go` hands it to whoever still has clients when
a consumer empties. Two viewers at once still means one of them is starved —
that is arbitration, not a bug.

## Git

- The source of truth is Gitea: `gitea@git.neet.dev:zuckerberg/open-nanokvm-pro.git`.
  `github.com/GoogleBot42/open-nanokvm-pro` is a **read-only public downstream
  mirror** (release hosting + Actions release builds only) — never push,
  commit, or tag on GitHub. Releases: write the `CHANGELOG.md` section first
  (mandatory), then Gitea web UI → Actions → `cut-release`
  with a version input (`tools/release` is the local fallback); the mirror +
  GitHub Actions do the rest — docs/updates.md.
- **Commit as you work; push after committing.** Never let finished work sit
  uncommitted or unpushed. (Standing instruction from Jeremy; a Stop hook also checks.)
- This repo pushes directly to `main` (Jeremy's explicit instruction, 2026-08-15) —
  an exception to the git-forges skill's general PR-only rule.
- Never commit device IPs, passwords, or other credentials.

## Traps that cost real debugging time (details in docs — don't re-derive)

- `libkvm.so` needs `patchelf --force-rpath` (DT_RPATH, not DT_RUNPATH); a binary that
  works from an SSH shell but crash-loops under systemd is this. See
  `docs/architecture.md` ("Load-bearing linker detail") and `pkgs/kvm-encoder.nix`.
- Vendor `ax_*.ko` modules require an exact vermagic match — `docs/building.md`.
  And vermagic match is NOT ABI safety: config flags can add `#ifdef` fields to
  core structs the blobs touch (CONFIG_DMA_CMA → `struct device.cma_area`;
  CONFIG_CMA → migratetype renumber → `struct zone`) and kill boot when the
  blobs load — audit struct layout per flag. Proven the hard way in #49:
  `docs/vcmd-cma-unblock.md`.
- The device must run `nanokvm.service`, not the vendor `kvmcomm.service`, or the web
  UI is down — `docs/architecture.md` ("The two app stacks").
- The app tree is copied to tmpfs at boot: hot patches must land in BOTH `/kvmapp`
  and `/dev/shm/kvmapp` — see the deploy-iterate skill.
- #50 (FIXED 2026-08-31, closed): a process that brought VIN up and then dies
  oopsed vendor `ax_proton.ko` in `vin_model_manager_deinit+0x44` — but the real
  trigger was **our own** capture replay issuing AINR ioctl `0xc008708a` (proton
  nr138), which `kmalloc`s a `model_manager` whose garbage slot array the teardown
  walks. `ax_venc` presence only masked it data-dependently; it was never a venc
  registration. Fix: `kvm_capture_open.c` gates nr138 behind `getenv("OPENKVM_NR138")`
  (unset in prod) → `model_manager` stays NULL → deinit no-ops. Set `OPENKVM_NR138=1`
  to reproduce the old crash. Caveat: the oops faults before the NULL-store, so a
  crashed nr138 process leaves the global dangling — the fix is clean only from a
  boot where nobody issued nr138. Full analysis + hardware proof: `docs/blob-replacement.md`
  ("#50 FIXED"). `panic_on_oops=1` still turns any oops into a hard reboot, and an
  oopsed task still wedges later `systemctl stop` until reboot.
- "ATX reset works but power doesn't" = the SW_PWR pinmux trap: sysfs GPIO export
  never programs the mux, gpio7 lives on the VI_D7 pad (mux reg `0x02300060`), and
  capture init re-muxes it — the server re-asserts it per press. A GPIO `value`
  read only echoes the output latch, it proves nothing about the ball. Details:
  `docs/mini-display.md` ("The SW_PWR pinmux trap").
- A register-image "golden table" captured from `/dev/mem` must carry the vendor's
  **zero-valued** config words too, or the open driver silently keeps reset values
  (WDMA `0x142f8` = 4 at reset, vendor writes 0 → every pixel word came out `<<4`;
  #59, 2026-09-02). Validate a replay by diffing the open driver's *own* streaming
  register file against the vendor's — `docs/reference/deblob-scope/regdumps/geom/`.
- On an open (base-only) boot the MM/VPP domain is unclocked: **reading `0x04403000`
  (the vendor's rst1 "hold" register block) hangs the AXI bus → watchdog reboot** —
  proven 2026-09-01. Only ax_vpp/production clocks it. The same rule holds for ANY block whose clock is off: a U-Boot register dump of the cardless SD slot at `0x104E0000` hung the bus and cost a power cycle (#89 rung 2f, 2026-09-08) — dump only what you have proven clocked. And glibc `memset`/`memcpy` on a
  `/dev/mem` mapping SIGBUSes (DC ZVA on Device memory): use word loops. Details:
  `docs/reference/deblob-scope/regdumps/README.md`.
- A bare `platform_device_register_simple()` device on arm64 4.19 gets `dummy_dma_ops`
  (`dma_supported` = 0), so `dma_coerce_mask_and_coherent()` FAILS silently and the
  coherent mask stays 0 (WARN at every `dma_alloc_attrs`). Set `dev.coherent_dma_mask`
  / `dev.dma_mask` directly when the device only uses a declared carveout (#63).
- The vendor encoder stack can be put back on the shipped open image **at
  runtime, from the Nix inputs** (`.#ax-ko-blobs` + `.#axera-libs` + the stock-
  rootfs `libax_venc.so`), no reflash — proven by the 2026-09-05 HEVC campaign.
  Three traps: `ax_jenc.ko` is required for `AX_VENC_Init`; the SDK-snapshot
  `libax_venc.so` is NOT the rootfs one (rejects pixel-unit strides); reboot
  before the swap if `ax630c_venc_vcmd` shows a phantom refcount, else the vendor
  `ax_venc.ko` loads inert. Recipe: device-re-subagent skill.
- Deleting from the vendor ext4 with `debugfs`: `ls -p` also lists **ghost (deleted)
  directory entries with inode 0** — filter `$2 != "0"` in every enumeration and
  post-purge count, or the "still present" assertion trips on entries that are not
  files (#54, cost a rebuild). Pattern + helpers: `pkgs/rootfs.nix` step 5d2.
- A kernel with no rootfs is invisible unless you plan for it. The mainline
  bring-up channel (#75, reusable for every #26 child) is: milestone bits 12-15
  of the A/B slot register `0x02390024` (spare in every boot-chain stage; they
  survive a warm reboot AND a raw chip reset), plus ramoops and a verbatim
  kernel-log copy in the 64 KiB TAIL of the vendor pstore window. Two traps
  inside that: the vendor kernel **zaps every pstore zone it owns ~1.5 s into
  the boot that would read yours**, so never put a log at `0x48000000`; and
  `/dev/kmsg` writes are ratelimited to ten records per five seconds per fd
  unless `printk_devkmsg` is `on` (systemd sets it, an initramfs does not) --
  which silently eats everything past the tenth line.
  `docs/mainline-port.md` section 8; `pkgs/kernel-mainline/initramfs/`.
- **`patch` silently truncates a hunk to its declared line count.** A hunk
  header saying `+1,78` over an 81-line body drops the last three lines with
  no error, and `nix build` reports success; on #89 that ate the `b` back
  from an assembly routine, so U-Boot ran into its own literal pool and looked
  exactly like an intermittent hang for four hardware rounds. Any patch whose
  tail is load-bearing gets verified in the built artefact (disassemble the
  function, grep the ELF), never by "the patch applied".
- **A stale fixed-output hash is invisible on any host that already holds the
  output** (the store path comes from the hash alone, so the fetch never
  re-runs): `.#update-package` built green here for two days while the release
  runner died on `vendorHash`. `buildGoModule`'s vendor tree also depends on
  `postPatch` (a patch that drops an import drops a module). Validate
  release-critical FODs with `nix build --rebuild` before cutting --
  `docs/building.md` "Pinned hashes" (alpha.5, 2026-09-07).
- **The eMMC is not reliably `mmcblk0` on mainline, and when it loses it has NO
  partitions at all.** The three SD4HC instances probe concurrently and the
  eMMC's layout comes from the `blkdevparts=mmcblk0:...` cmdline clause, which
  binds the table to a device *name* (there is no on-disk partition table). Lose
  the race and the table lands on the empty SD slot while the eMMC comes up bare
  -- two boots in five, measured in #78. Locating the partition by name does not
  help, because in the losing case nothing is named. Fixed by `aliases { mmc0 =
  &emmc; ... }` in `dts/ax630c.dtsi`; #76/#77 never saw it because they won.
- **A slot-B *appliance* has no way back to slot A** unless you give it one, and
  NixOS stage 1's `fail()` is INTERACTIVE -- it blocks in `read` on a console
  whose pads nobody can reach, while the kernel pets U-Boot's watchdog forever.
  Set `panicOnFail=1` from `boot.initrd.preDeviceCommands` (upstream only reads
  it from the cmdline, which here comes from the U-Boot env) and carry a
  userspace deadman on `/proc/uptime` -- NOT `date +%s`, because timesyncd jumps
  the clock months forward the moment DHCP lands and a wall-clock deadline
  expires instantly. `nixos/loop-test.nix`; both halves hardware-proven in #78.
- **Three separate things decide the appliance's identity, and each looks
  sufficient alone.** `hostnamectl` must be `--transient` (the plain call writes
  `/etc/hostname`, a read-only store symlink); `networking.hostName` must be
  **empty**, or systemd-hostnamed refuses the transient one ("static hostname is
  already set"); and `dhcpV4Config.ClientIdentifier` must be `mac`, because the
  same MAC does not get the same lease when networkd sends a DUID in option 61.
  Four hardware runs, one per discovery -- `docs/reference/mainline/nixos-appliance-20260907/HARDWARE.md`.
- **The board's ethernet PHY is a Realtek RTL8211F, not the JLSemi JL2101 the
  vendor DT names** (PHYID 0x001cc916, read over MDIO 2026-09-06). An
  `ethernet-phy-id*` compatible makes Linux skip the bus read, so the vendor has
  always bound a JLSemi driver to a Realtek part -- harmlessly, because that
  driver programs nothing. Mainline's realtek driver DOES program things, so
  `phy-mode` must be **`rgmii-id`**: both 2 ns delays are pin-strapped on and
  `"rgmii"` clears them. The failure is a link that trains, reports 1Gbps/Full,
  and passes not one packet -- **that signature is always an RGMII delay
  problem** (#77, `docs/reference/mainline/ethernet-boot-20260906/`).

## Hardware tripwires

- eMMC is `/dev/mmcblk0`; the SD card is `/dev/mmcblk1`. **Never write mmcblk0 during
  SD-card testing.** (Deliberate duplication with `docs/flashing-and-recovery.md` — keep both.)
- Hash-verify every firmware/block-device write; drop caches on the device before the
  read-back or you verify the page cache, not the medium.
- U-Boot has `bootdelay=0`: no autoboot interrupt window even over serial. A bad
  boot-chain flash means physical AXDL recovery — which Jeremy has tested and works,
  so bricking is not a concern, but it needs his hands on the device.

## Device access

Use `tools/kvmssh` / `tools/kvmscp`; credentials live in `~/.config/nanokvm/device.env`
(untracked). See the kvm-device skill.

**The board's power is agent-controllable (since 2026-09-09):** it hangs off the
zigbee plug named `nanokvm switch` — user-level `power-switch` skill,
`~/.claude/skills/power-switch/switch.sh "nanokvm switch" off|on|state`. A cold
cycle clears the slot register and lands on slot A; SSH is back ~30 s after
`on` (tested 2026-09-09: off → 0 W, on → 2 W, booted, slot `0x14`). Read the
slot register / pstore / console buffer BEFORE cycling — the cycle destroys
them. Jeremy's standing word: with self-recovery available, take more risk on
slot-B experiments; the plug is the way out of a stranded appliance, not AXDL.

## Docs index — read before working on X

| Task | Read first |
|---|---|
| Anything architectural (boot chain, pipeline, services) | `docs/architecture.md` |
| Building components / hashes / vermagic | `docs/building.md` |
| Flashing, backup, recovery, SD boot | `docs/flashing-and-recovery.md` |
| OTA / releases / versioning | `docs/updates.md` |
| Blob or network-endpoint questions | `docs/provenance.md` |
| Mini-display | `docs/mini-display.md` |
| Capture-pipeline internals / RE history | `docs/blob-replacement.md` |
| Full deblob epic (#55): capture-stack replacement plan + scoping | `docs/deblob-capture.md` |
| Open-encoder driver bring-up / #49 resolution (CMA = blob ABI break; no-flash coherent carveout) | `docs/vcmd-cma-unblock.md` |
| Slot-B kernel boot-testing (proven A/B harness) | `docs/flashing-and-recovery.md` |
| NixOS appliance / pure-Nix rootfs: boot contract, identity, gaps (#26, #78) | `docs/nixos-rootfs.md` |
| Mainline port (#26): driver inventory, boot/rollback contract, child issues #74-#87, and how a serial-less first boot is made observable | `docs/mainline-port.md` |
| SG2002 project (dormant) | `docs/plan-sg2002-research.md` |

## Working with Jeremy

- **Blob policy (2026-09-04):** the aic8800 wireless *firmware* is the only closed
  content allowed on the image. No closed userspace, no closed `.ko`, ever. NixOS
  goes **straight to mainline** (no 4.19 NixOS stage; the custom A/B scheme dies with it).
- **Mainline everything (2026-09-07):** kernel, U-Boot, and TF-A where a port is
  tractable. Patches are fine, but against upstream, never a vendor fork; the
  SDK's U-Boot 2020.04 / TF-A 2.7 forks are a stopgap. Partition layout: the
  simplest that works (no A/B twins; extlinux generations carry the kernel).
  Reflashing over AXDL is a bench trip, never a brick, so "recovery = AXDL"
  means "needs Jeremy", not "dangerous".
- Concise, confident prose — no hedging, no over-explaining (applies to docs, READMEs,
  commit messages).
- On hardware: prefer the reversible method first, even if it's "only short-term";
  ask before irreversible/destructive operations.
- Prefer re-implementing against documented/open APIs over reverse-engineering a
  vendor-internal seam.
- **Clean-room RE (hard requirement, 2026-08-30):** all RE of vendor binaries
  goes through *describing* subagents that emit behavioral specs; drivers are
  written from the spec only, never from vendor code/disassembly directly.
  On-device observation (register snapshots, traces) is unrestricted.
- Record findings and rationale even for rejected paths, so decisions can be revisited.
- Questions get direct answers before (or instead of) action.
- Delegate aggressively to `model: opus` subagents to save usage — searching, mining,
  bulk writing, analysis, verification, anything that doesn't truly need the session
  model. Reserve Fable/Mythos-tier work for what genuinely requires it; never let
  subagents inherit the session model. Always check the agent's work yourself
  (spot-read the code paths it cites, verify its claims) before acting on it.
  For bulk transcription, hand the agent the invariant counts up front as an
  acceptance test it must measure and reconcile itself -- then re-check them
  from a *different artifact* than the one it wrote (compiled object sizes and
  symbols, not a re-read of its source). Both #80 table agents passed 16- and
  8-way count checks that way, and the same discipline caught two errors of
  *mine*: an undercount from a too-narrow regex, and a claim of "device-
  confirmed" for something the device could not actually witness (clk_summary
  echoes the driver's own parent table, so it cannot corroborate that table).
- After substantial work, run the reflect skill.
