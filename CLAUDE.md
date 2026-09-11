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
- **`/sys/fs/pstore` is empty on a HEALTHY appliance boot**: `systemd-pstore`
  archives every record into `/var/lib/systemd/pstore/` and unlinks it ~10 s
  in. An empty `/sys/fs/pstore` says nothing about whether the previous kernel
  logged; read the archive. On #89 that misreading turned "kernel booted to
  systemd, ethernet dead" into "kernel died before ramoops" for two rungs.
  Run the control experiment (warm-reboot a known-good boot and look) before
  trusting any absence-of-evidence channel.
- **A pad no DT node names is a pad the port does not own.** Linux inherits
  whatever the loader left on it, so it works under the vendor U-Boot and dies
  under mainline U-Boot (which programs nothing). The fourteen RGMII pads had
  no pinctrl group until #89 rung 2q; every peripheral needs its pins in a
  named group, checked against the pad table, not "it worked on slot A".
- **An arming condition for a dangerous test must not live in state the
  recovery action clears.** The first chainload slot (#91) gated on
  `bootcount`, which a power cycle zeroes; the only console-less recovery
  therefore re-armed the hung candidate every cycle, and the board needed an
  AXDL flash. The slot now spends a one-shot token in flash BEFORE it jumps
  (patch 0025 v2), and the build check asserts that ordering. Ask "what clears
  this?" of every guard before trusting it; and never trust a safety net you
  have not watched fire (the stage-1 panic token, rung 5, was the same lesson).
- **A magic compared as a WORD must be written as that word, not as it reads in
  a hexdump.** The same slot's token is four ASCII bytes `43 48 54 4B` and
  U-Boot's `itest.l *addr` is a native `*(u32 *)`, so the constant is
  `0x4B544843`; spelled `0x4348544B` it builds, boots, and silently never
  matches — and a gate that never opens looks exactly like a load that failed.
  One hardware round, 2026-09-10. Same shape as the `writel(0x43484C44)` record
  it sits next to, which is read back as a word and so is correct as written.
- **`patch` silently truncates a hunk to its declared line count.** A hunk
  header saying `+1,78` over an 81-line body drops the last three lines with
  no error, and `nix build` reports success; on #89 that ate the `b` back
  from an assembly routine, so U-Boot ran into its own literal pool and looked
  exactly like an intermittent hang for four hardware rounds. Any patch whose
  tail is load-bearing gets verified in the built artefact (disassemble the
  function, grep the ELF), never by "the patch applied".
- **`sed 's|\(A\|B\)|…|'` has no alternation.** With `|` as the `s` delimiter,
  `\|` is an escaped delimiter (a literal bar), so the group matches the string
  `A|B` and nothing else — silently. The `/boot` collector in `nanokvm-mark-good`
  shipped that way (#86), its keep-list came out empty, and it deleted the live
  dtb on the board on the first healthy boot (2026-09-10, caught by #83 round 2;
  on the content-addressed layout it would have removed the kernel too and looped
  the board to AXDL). Use another delimiter, and give every collector the
  property that an empty keep-list collects nothing.
- **A stale fixed-output hash is invisible on any host that already holds the
  output** (the store path comes from the hash alone, so the fetch never
  re-runs): the release OTA package built green here for two days while the
  release runner died on `vendorHash`. `.#system-bundle` sits in exactly that
  place now. `buildGoModule`'s vendor tree also depends on
  `postPatch` (a patch that drops an import drops a module). Validate
  release-critical FODs with `nix build --rebuild` before cutting --
  `docs/building.md` "Pinned hashes" (alpha.5, 2026-09-07).
- **The eMMC is not reliably `mmcblk0` on mainline, and when it loses it has NO
  partitions at all.** The three SD4HC instances probe concurrently and the
  eMMC's layout comes from the `blkdevparts=mmcblk0:...` cmdline clause, which
  binds the split to a device *name*. Since #89 rung 4 that clause is only two
  entries (`spl` + `disk`) and the real table is a GPT inside `disk` — but the
  clause is still what creates `disk`, so the race is unchanged: lose
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
- **`boot.panic_on_fail=1` ON THE COMMAND LINE DOES NOTHING.** Upstream's
  stage-1 parser is `case $o in boot.panic_on_fail|stage1panic=1)` and a shell
  `case` pattern must match the WHOLE word, so the `=1` makes it match neither
  alternative -- silently, with a cmdline that reads as if the deadman were
  armed. The appliance carried exactly that from #89 rung 3 to rung 5 and
  therefore had NO stage-1 deadman at all; the rung-5 rollback drill installed a
  generation that could not boot, stage 1 sat in `read -n 1 reply` forever, the
  board never reset, `bootcount` never climbed, `altbootcmd` was never reached,
  and recovery was AXDL. **Never trust a safety net you have not watched fire.**
  Set the variable from `preDeviceCommands` (which depends on no string) AND
  emit the bare `boot.panic_on_fail` plus `stage1panic=1`. (Until #99 the
  initrd was inside the kernel Image, so applying that fix meant writing `/boot`
  from a board that still boots; now it is an ordinary generation switch.)
- **Three separate things decide the appliance's identity, and each looks
  sufficient alone.** `hostnamectl` must be `--transient` (the plain call writes
  `/etc/hostname`, a read-only store symlink); `networking.hostName` must be
  **empty**, or systemd-hostnamed refuses the transient one ("static hostname is
  already set"); and `dhcpV4Config.ClientIdentifier` must be `mac`, because the
  same MAC does not get the same lease when networkd sends a DUID in option 61.
  Four hardware runs, one per discovery -- `docs/reference/mainline/nixos-appliance-20260907/HARDWARE.md`.
- **NixOS's extlinux builder collects `/boot/nixos` against the MENU, and the
  rollback fallback is not in the menu.** `extlinux-conf-builder.sh` deletes
  every file under `/boot/nixos` that the generations it just wrote entries for
  do not name; it has never heard of `extlinux-fallback.conf`. Drop a
  generation from the menu (a smaller `configurationLimit`, or an `rm` of its
  profile link) while the fallback still names it and the rollback points at
  files that no longer exist. `nanokvm-mark-good` closes the window by
  re-deriving the fallback — but `systemctl start nanokvm-mark-good` is a
  **no-op** after a boot (`Type=oneshot`, `RemainAfterExit=yes`, still
  `active`), so it must be `restart`. Both seen in #99 round 4, 2026-09-11.
- **`CONFIG_LOCALVERSION` lives in two files and the build checks both.**
  `pkgs/kernel-mainline/ax630c.config` sets it; `pkgs/kernel-mainline.nix`
  asserts the built `include/config/kernel.release` equals the string it
  computed from its own `localversion`. Changing only the Nix side fails the
  build with `CONFIG_LOCALVERSION is not '…'` — that is the assertion working,
  not a stale config. (#99 round 3, 2026-09-11.)
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

**Since 2026-09-09 the eMMC is `spl` + a GPT-carrying `disk`** (#89 rung 4).
The first 768 KiB are the BootROM's and are outside every partition table;
everything after carries a real GPT at its own LBA 0 (protective MBR at
physical LBA 1536). Linux gets there via
`blkdevparts=mmcblk0:768K(spl),-(disk)` plus a stage-1
`losetup -P /dev/loop0 /dev/mmcblk0p2`, so root is `/dev/loop0p5` and `/boot`
is `/dev/loop0p4`; U-Boot reads the same table through
`CONFIG_EFI_PARTITION_BASE_LBA=1536` (patch `0023`). The SPL is
`.#spl-minimal`, compiled for those offsets — **the layout and the
first-stage loader are one artefact, so a layout change means an SPL
rebuild**, and a bad SPL is an AXDL bench trip. There are no A/B twins any
more; both `_BAK` bases point at the A bases, so the slot register's SLOT
bits select nothing. **That SPL is blob-free (#90):** signed with an empty
`-fw` member, so the closed EIP-130 firmware is not spliced in at
0xCC00/0x2CC00 at all — the BootROM accepts a header declaring `fw_size = 0`,
proven across two warm reboots and a cold cycle. `.#spl-minimal-eip` rebuilds
the vendor-shaped container if a unit ever needs it. A good boot reads
`0x30000014`. **A mainline boot is 71 seconds to SSH since #91 was fixed
(2026-09-10)** — one U-Boot attempt, `bootcount` = `0xB0010001` at the health
gate. It used to be 2:49 to 24:51 with up to four attempts, because the eMMC
node asked for HS400ES at 50 MHz and no multi-block read ever framed; the tree
now says `max-frequency = <200000000>`. `bootcount`
(`journalctl -u nanokvm-mark-good`) says how many attempts a boot needed, and
anything above 1 is now worth investigating rather than shrugging at. **Still
poll 30 minutes before calling a mainline board dark**: a candidate that hangs
costs a 300 s watchdog cycle, and ten minutes was what made #94 look like a bad
flash. `docs/mainline-port.md` §11.10 "Handoff" is the current device contract;
§11.11 is #94.

**`/boot` is NixOS's since #99 (hardware-proven 2026-09-11) — there is no
`/boot/Image`.** The kernel, the initrd and the dtb are store paths in the
generation, and `boot.loader.generic-extlinux-compatible`, run by
`switch-to-configuration boot`, is the ONLY writer of `/boot`: it copies the
three files into `/boot/nixos/<store-hash>-…` and writes
`/boot/extlinux/extlinux.conf` with one `LABEL` per generation, each pinning
its own `init=`. `nanokvm-mark-good` derives `extlinux-fallback.conf` from that
file by changing one `DEFAULT` line. Consequences when you touch the board:
`/boot` must be mounted before any switch (`mountpoint -q /boot`), a kernel
change needs no extra copy, `nanokvmboot=` and `Image-<hash>` are gone, and
**read the `DEFAULT` label, never the first `init=`** — both files list every
generation. A generation built with `boot.kernel.enable = false` gets NO menu
entry (the builder skips any toplevel with no `kernel`/`initrd` link), which is
why generations 1-3 on this board are not bootable and why migrating a pre-#99
`/boot` costs one generation of space, not three.

**Try a U-Boot candidate through the one-shot chainload slot, never by writing
the `uboot` partition** — there is one copy and no B twin. `nanokvm-uboot-test
stage <raw u-boot.bin>` puts it on `/boot` and arms a token in flash that
`bootchain` **spends before it jumps**, so a candidate runs exactly once even if
it hangs at its first instruction (WDT0 resets into the production copy;
hardware-proven both ways 2026-09-10). Oracle: `CHLD` at `0x480EE000`,
`chainstat` at `+8`, and `bootcount` at the health gate. Read those, and the
pre-console ring at `0x480E8000`, BEFORE any power cycle — a chip reset keeps
them, power loss does not, which is why `.#uboot-mainline-spldrv` (it wedges the
board past WDT0) has never measured anything.

**Rollback is live since rung 5 (#79 closed).** `bootcount` is
`devmem 0x02390030 32` -- `0xB0010000` healthy, `0xB001000N` = N attempts
since the last healthy boot -- and `bootlimit` is 3, so the FOURTH attempt
runs `altbootcmd`, sets milestone bit 30 and boots
`/boot/extlinux/extlinux-fallback.conf` instead of `extlinux.conf`.

**Since #99 the kernel, the initrd and the dtb are part of the NixOS
generation** (`boot.kernelPackages` + `hardware.deviceTree`), and
`boot.loader.generic-extlinux-compatible` — NixOS's own builder, run by
`switch-to-configuration boot` — is the **only** writer of
`/boot/extlinux/extlinux.conf` and `/boot/nixos/*`. Nothing in this repo renders
an extlinux.conf any more; `pkgs/extlinux.nix`, `pkgs/boot-payload.nix`,
`nixos/lib/install-boot.nix`, the `nanokvmboot=` token and the `Image-<hash>`
naming are all deleted. The two configs carry the SAME labels — one per
generation, each with its own kernel and pinned `init=` — and differ only in
which one `DEFAULT` selects. `nanokvm-mark-good` (timer, `OnBootSec=60s`) clears
the counter and then DERIVES the fallback by copying `extlinux.conf` and setting
`DEFAULT` to the label of the generation `/run/booted-system` resolves to; it
**refuses**, loudly, leaving the previous fallback, if that label is not in the
file — a `DEFAULT` U-Boot cannot match falls through to the FIRST label, which
is the generation the rollback exists to escape. It deletes nothing: the
extlinux builder collects its own obsolete kernels.
`boot.loader.timeout` must stay 0 (any other value makes the builder emit a
top-level `MENU TITLE`, and `parse_pxefile_top()` then sets `cfg->prompt = 1`
and U-Boot reads this board's unreachable console forever) and
`configurationLimit` is 3, bounded above by a 272 MiB `/boot` at ~50 MB per
generation. To force a fallback by hand: `devmem 0x02390030 32 0xB001000A;
reboot` -- and **that is the way to exercise the rollback, not a broken
generation**: it proves `bootcount_error()`, `altbootcmd`, bit 30 and the
fallback config in one boot and cannot strand the board. Details:
`docs/nixos-rootfs.md` §1 and §4b.

Hardware-proven 2026-09-09: the board rolled itself back onto the fallback
generation, unattended, after four boot-chain attempts. What triggered it was
**#91**, not a bad generation — U-Boot sometimes could not read the 51 MB
`Image` inside `bootcmd`'s four tries, and that cost a rollback instead of a
power cycle. Since #99 the Image is 42 MB with a 7.6 MB initrd beside it.

**An update is a system bundle, and there is no OTA any more (#86, 2026-09-10).**
`.#system-bundle` is the appliance's whole store closure (~450 MB), kernel and
initrd and dtb included as ordinary store paths since #99 — there is no `boot/`
half in the tarball;
`nanokvm-update install <tarball>` unpacks what the board is missing, sets the
profile, runs `switch-to-configuration boot` (which is what writes `/boot`) and
leaves the reboot to arm the rollback, and
`nanokvm-gc` reclaims old generations from the closure lists the installer
records (it refuses to delete anything if one is missing). The 4.19 overlay OTA
and `.#update-package` are **deleted** — a vendor-layout board is reflashed over
AXDL, by decision, because nobody runs the alpha releases. **Unattended updates
are a web-UI checkbox** (`/etc/kvm/auto_updates`, beside the preview flag — there
is no `nanokvm.update.auto`), they install on the timer and **reboot only when
the server's loopback `/api/update/idle` route says nobody is connected**, and
both channels are tagged releases only. `docs/updates.md`.

**The board's power is agent-controllable (since 2026-09-09):** it hangs off the
zigbee plug named `nanokvm switch` — user-level `power-switch` skill,
`~/.claude/skills/power-switch/switch.sh "nanokvm switch" off|on|state`. A cold
cycle clears the slot register and lands on slot A; SSH is back ~30 s after
`on` for the 4.19 image, and ~90 s for the mainline chain since #91 was fixed
(it was 3-18 min before). **Leave it OFF for at least 15 s.** An 8-second
cycle on 2026-09-09 came back into the same dark state the cycle was meant to
clear; the 15-second one after it booted normally. **A flat ~3.3 W with no
open port is the hang signature**; a healthy board draws the same at idle, so
power tells you nothing on its own — only SSH does. Read the
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
