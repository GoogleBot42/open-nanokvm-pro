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
  GitHub Actions do the rest — docs/releasing.md.
- **Commit as you work; push after committing.** Never let finished work sit
  uncommitted or unpushed. (Standing instruction from Jeremy; a Stop hook also checks.)
- This repo pushes directly to `main` (Jeremy's explicit instruction, 2026-08-15) —
  an exception to the git-forges skill's general PR-only rule.
- Never commit device IPs, passwords, or other credentials.

## Traps that cost real debugging time (details in docs — don't re-derive)

- `libkvm.so` needs `patchelf --force-rpath` (DT_RPATH, not DT_RUNPATH); a binary that
  works from an SSH shell but crash-loops under systemd is this. See
  `docs/architecture.md` ("Load-bearing linker detail"), `pkgs/kvm-encoder.nix`
  and the `kvmapp` derivation in `nixos/modules/server.nix`, which re-rpaths it.
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
- **A buffer in a declared coherent carveout costs a POWER OF TWO of pages, not
  its page-aligned size.** `dma_alloc_from_dev_coherent()` allocates through
  `bitmap_find_free_region(..., get_order(size))`, so the cost is
  `2^ceil(log2(size))` aligned to itself: a 15.82 MiB 3840x2160 YUYV frame
  costs 16 MiB and a 16.88 MiB 4096x2160 one costs **32**. Sizing a pool by
  `PAGE_ALIGN(sizeimage) * n` promises buffers it cannot hold, and vb2 then
  fails `REQBUFS` **entirely** — it refuses below `min_queued_buffers + 1` — so
  "raise the ceiling" looked done and one hardware round said otherwise. Out of
  the old 56 MiB pool the driver got three buffers at 3840x2160 and could not
  get ONE at 3840x2400 (#98, measured; the 16:10 EDID in #61 had therefore
  never worked and nothing said so). The capture pool is 96 MiB now —
  three 32 MiB slots — and `.#checks.open-capture-envelope` reproduces the
  order arithmetic rather than the page arithmetic that hid it.
- A bare `platform_device_register_simple()` device on arm64 4.19 gets `dummy_dma_ops`
  (`dma_supported` = 0), so `dma_coerce_mask_and_coherent()` FAILS silently and the
  coherent mask stays 0 (WARN at every `dma_alloc_attrs`). Set `dev.coherent_dma_mask`
  / `dev.dma_mask` directly when the device only uses a declared carveout (#63).
- A kernel with no rootfs is invisible unless you plan for it. The mainline
  bring-up channel (#75, reusable for every #26 child) is: milestone bits 12-15
  of the A/B slot register `0x02390024` (spare in every boot-chain stage; they
  survive a warm reboot AND a raw chip reset), plus ramoops and a verbatim
  kernel-log copy in the 64 KiB TAIL of the pstore window. Two traps
  inside that: a kernel **zaps every pstore zone it owns ~1.5 s into
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
- **`=m` is a lie in this kernel, and `IS_ENABLED()` believes it.** The
  mainline kernel has no module search path — six `.ko` are installed by hand
  and nothing else can ever load — so any `=m` symbol that a *built-in*
  `IS_ENABLED()` tests will send the built-in code down a path whose driver
  does not exist. `CONFIG_RESET_GPIO=m` (an arm64 defconfig default) did
  exactly that in #85: `mmc_pwrseq_simple` asks the reset core for a reset
  control whenever there is exactly one `reset-gpios`, the core synthesised an
  auxiliary `reset-gpio` device because `IS_ENABLED(CONFIG_RESET_GPIO)` was
  true, and then waited forever for the module. Permanent `-EPROBE_DEFER` on
  the pwrseq, which its consumer `104d0000.mmc` inherited — so the SDIO host
  never probed, no card enumerated, and a perfectly good radio looked dead.
  The only trace is two `deferred probe pending` lines 12 s into the boot and
  a missing entry in `/sys/class/mmc_host`. Make such a symbol `y` or unset it;
  never leave it `m`. Nothing offline catches it.
- **A peripheral that is allowed to be absent must still be allowed to FAIL.**
  A `Type=oneshot` unit that `exit 1`s when its hardware is missing makes
  `systemctl is-system-running` report `degraded`, which makes
  `nanokvm-mark-good` poll 240 s and give up, which leaves `bootcount`
  uncleared — so **every reboot counts as a failed boot attempt and the fourth
  rolls the board onto the fallback generation**. #85's WiFi unit did this and
  #84's panel unit did it the same week. The fix is
  `nanokvm.markGood.tolerateFailed` (wifi, panel, display) and **only** that;
  the `exit 0` both units also grew was withdrawn in #106, because a unit that
  cannot fail cannot be seen — `systemctl --failed` is empty, the journal line
  scrolls away, and a radio that stopped enumerating for a NEW reason looks
  exactly like a board that never had one. `nanokvm-mark-good --check-system`
  runs the real gate against a fake root, and `nanokvm-mark-good-fallback`
  exercises eight cases through it.
- **The DesignWare PWM cannot express either DC extreme, and `pwm-backlight`
  ignores the error.** Each load count is "value + 1" input clock periods, so
  duty 0 and duty == period are the two requests the timer cannot generate;
  upstream returns `-ERANGE`, and `pwm_backlight_update_status()` — on a board
  with neither `enable-gpios` nor `power-supply`, where it deliberately keeps
  the PWM *enabled* at duty 0 to hold a constant inactive output — discards
  it. So `bl_power=1` read back as 1 while `/sys/kernel/debug/pwm` showed
  pwm-0 `enabled, 366702/462966 ns`: the mini-display's backlight stayed at
  79.2 % through every inactivity blank (#106), and
  `default-brightness-level = <100>` had never applied either. Patch 0004
  stops the timer for the first and clamps to one tick for the second.
  **Read the PWM registers, not `bl_power`** — #84 read only sysfs and called
  the blank proven.
- **`gpio-line-names` cannot carry polarity, and three comments said it
  could.** It is a bare string array with no flags cell; only a `gpios =
  <&gpioN x GPIO_ACTIVE_LOW>` phandle carries the flag, and lines that are
  *named* for userspace have no such consumer. A libgpiod request that does
  not ask for `active-low` gets the RAW pad — so the host's power-LED sense,
  which the board pulls low while the host is on, read 0 and the web UI
  reported every powered host as off (#105). The board fact lives in
  `board_polarity[]` in `pkgs/nanokvm-gpio/nanokvm-gpio.c`; `nanokvm-gpio raw`
  prints the pad when you need to measure rather than believe.
- **A clock ID the binding header declares is not a clock the table
  registers**, and the difference is silent until something calls `clk_get()`.
  `ax630c_clk_probe()` fills every id up to `max_id` with `ERR_PTR(-ENOENT)`,
  so a missing row is `-ENOENT` at `clk_get` and a consumer that cannot probe —
  `dw_spi_mmio 6072000.spi: probe ... failed with error -2` and a backlight
  stuck in deferred probe behind it (#84, 2026-09-11; five rows for SPI2 and
  PWM0). In the VENDOR driver the same gap was harmless: 101 of the periph
  controller's 122 ids are unregistered there because its own drivers poked the
  syscon by hand, which is why the ids exist in the header at all. #75 (wdt),
  #76 (mmc), #81 (i2c/gpio) and #84 all had to add rows. **Before wiring a new
  peripheral's `clocks =`, check the table, not the header.** Corroborate a new
  gate bit by reading the live word: every registered-and-unconsumed gate reads
  0 (`clk_disable_unused` cleared it) while a gate the boot chain left on and
  nobody owns reads 1.
- **A mux the DT does not name is a mux nobody sets, and its reset value is
  usually the SLOWEST tap.** Mainline programs no clock a consumer does not
  ask for, and the vendor's own software is not there to do it, so a block
  whose `clocks =` names only a gate inherits whatever the silicon powers up
  with. `clk_vpu_glb_sel` offers 208/312/375/416/500/533 MHz and comes out of
  reset on 208; the VC8000E therefore spent 41.6 ms on a 4K H.264 frame and
  capped the product at 24 fps under a 30 fps source, which read as "raw
  capture is slow" for a day (#107, 2026-09-12). `assigned-clocks` /
  `assigned-clock-parents` on the consumer node is the fix, and
  `.#checks.mainline-dtb` asserts both cells because losing them is invisible
  except as a frame rate. **Check `clk_summary` against the mux's parent list
  for every block whose speed matters** — and corroborate with the hardware's
  own cycle counter: a count that does not change with the clock says the
  block is compute-bound and the clock is a pure multiplier, while a count
  that rises says you have run into the bus instead.
- **On a write-combining mapping, a byte loop costs a bus round trip PER
  BYTE.** `pgprot_writecombine` memory (every carveout here: the capture pool,
  the encoder framebuf) has no cache to coalesce into, so each `volatile
  uint8_t` load is its own transaction — measured 200 ns each, 5 MB/s. Reading
  a 25 kB bitstream out of the framebuf that way cost 5.0 ms, 11% of the whole
  4K encode budget; the same copy 8 bytes at a time is 0.65 ms (#107). The
  `/dev/mem` rule above ("use word loops, not `memcpy`") is about **Device**
  memory and DC ZVA; it does not license a *byte* loop anywhere, and these
  mappings are Normal non-cacheable, where `memcpy` is safe. For scale, a
  `memcpy` of a whole 17.7 MB frame out of the capture pool runs at 125 MB/s —
  7 fps — which is why nothing in the datapath may touch a frame with the CPU.
- **A NixOS unit's `PATH` is not the system's.** It gets `coreutils`,
  `findutils`, `gnugrep`, `gnused` and `systemd` — nothing else — so every
  external tool a service shells out to must be in its own `path`.
  `nanokvm-display`'s `ip -j -4 addr` was an `ENOENT` the daemon caught and
  turned into an empty address list: the panel read "no network" on a board
  that was routed and serving (#84, 2026-09-11). The 4.19 image ran the same
  daemon with an Ubuntu `PATH`, so nothing offline could have caught it.
- **Measure a binary's compiled-in paths; do not reason about its upstream
  defaults.** nixpkgs' `wpa_cli` is built with `/run/wpa_supplicant/control`
  and `/run/wpa_supplicant/client` patched in, NOT upstream's
  `/var/run/wpa_supplicant` — so `networking.wireless.userControlled` is what a
  bare `wpa_cli -i wlan0` needs, and #85's carefully-argued override of it cost
  a hardware round. `strings` on the binary settles such a question in seconds.
  Same lesson as the browser-codec rule above, in a different subsystem.
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
  release runner died on `vendorHash`. `.#appliance-toplevel` sits in exactly
  that place now — it is what a release pushes to the cache.
  `buildGoModule`'s vendor tree also depends on
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
- **NixOS stage 1's `fail()` is INTERACTIVE** -- it blocks in `read` on a console
  whose pads nobody can reach, while the kernel pets U-Boot's watchdog forever, so
  a generation that cannot find its root is a board that is powered, warm and
  unreachable. Set `panicOnFail=1` from `boot.initrd.preDeviceCommands` (upstream
  only reads it from the cmdline, which here comes from the U-Boot env) and carry
  a userspace deadman on `/proc/uptime` -- NOT `date +%s`, because timesyncd jumps
  the clock months forward the moment DHCP lands and a wall-clock deadline
  expires instantly. `nixos/modules/kernel.nix`; both halves hardware-proven in #78.
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
- **A COMMENT INSIDE A BUILD STRING IS A BUILD INPUT.** Renaming a file and
  sweeping the tree for references to it looks free and is not: a `#` line
  inside a `runCommand` script, a `writeShellApplication` `text`, a `preBuild`
  or a NOTES heredoc is hashed into the derivation. In #87 five such lines --
  in `pkgs/aic8800.nix`, `pkgs/nanokvm-server.nix`, `nixos/lib/updater.nix`,
  `nixos/lib/appliance-artifacts.nix` and `nixos/axp-image.nix` -- rebuilt
  `aic8800-modules`, `kvmapp` and `nanokvm-update`, which took `system-path`,
  `dbus-1`, `etc` and the toplevel with them and broke an oracle that was
  otherwise exact. They are deliberately left naming the pre-#87 paths. The
  test that catches it is the one worth running after any refactor that is
  supposed to change nothing: rebuild the toplevel and diff the store path.
- **A removal is only done when the last consumer is gone, and a default can be
  the consumer.** #97 deleted the 4.19 image's `nanokvm-server` variant and left
  the appliance calling the package without `gpioBackend = "libgpiod"` -- whose
  default was `"sysfs"`. `nix flake check` passed; the appliance would have
  shipped a server driving ATX through `/sys/class/gpio`. Caught by diffing the
  derivation's store path against the pre-removal one, which is the check worth
  running after any refactor that is supposed to change nothing.
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
- **`/nix/store` on the appliance is a READ-ONLY BIND MOUNT** (`boot.readOnlyNixStore`,
  NixOS's default), and `docs/updates.md` used to claim the remount was a no-op
  here. It is not: a hand `tar -C /nix/store` fails with **exit 2 and nothing
  useful on stderr**, and `mount -o remount,ro` alone is a silent no-op on a bind
  — it needs `remount,bind,ro`. `nanokvm-update` flips it both ways around its
  `nix copy`; anything writing the store by hand has to do the same. `nix` itself
  needs no help (as root it unshares a mount namespace). #100, 2026-09-11.
- **When the web UI's update button fails, read
  `/var/log/nanokvm/NanoKVM-Server.log` before you debug the cache.** For a week
  it failed because the server fetched its own manifest from a URL compiled into
  the Go binary while the install read the device's configured channel — two
  sources of truth, and a `404` the page reported as `{"code":-2}` (#101, fixed
  2026-09-11). There is one channel now: `GET /api/application/version` runs
  `nanokvm-update check --json` and `install()` runs `install-now`, both against
  `nanokvm.update.stableUrl`.
- **`nanokvm-update gc` leaves BOTH extlinux menus naming generations it just
  deleted.** The collector rewrites no boot config, so a `LABEL` can point at an
  `init=` that is gone. Never unsafe — the `DEFAULT` entries are exactly what `gc`
  pins — but repair it: the next `switch-to-configuration boot` fixes
  `extlinux.conf`, and `systemctl restart nanokvm-mark-good` (**restart**, not
  `start`) fixes `extlinux-fallback.conf`. #100, 2026-09-11.
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

## History: the 4.19 product (removed 2026-09-11, #97)

Everything that built, flashed, updated or documented the vendor-derived Ubuntu
22.04 / Linux 4.19.125 image is **deleted** -- `firmware-image`, the rootfs
overlay, `base-axp`, the 4.19 kernel/dtb/initramfs, the vendor boot chain, the
A/B `*-slot-image` packaging, `sd-image`, `migrate-layout`, `ax-ko-blobs`,
`axera-libs`, `libsns-dummy`, `ax-stub`, the closed-backend
`kvm-encoder` variants, the `deploy-iterate` / `mainline-boot-test` /
`sd-flash-remote` skills. Git history has all of it. (#102 finished `axera-libs`
off: libkvm compiled against its `ax_*.h` until then, and has its own
`kvm_types.h` now.)

The traps that only bit on that stack are gone from the list above, and are
recorded where they happened: the vendor `ax_*.ko` vermagic-and-struct-layout
contract (#49, `docs/vcmd-cma-unblock.md`), `kvmcomm.service` vs
`nanokvm.service` and the tmpfs `/kvmapp` hot-patch rule
(`docs/architecture.md`), the `ax_proton` nr138 oops (#50,
`docs/blob-replacement.md`), the SW_PWR pinmux trap (`docs/mini-display.md`;
retired by #81 -- requesting a libgpiod line programs the pad), and the
`debugfs` ghost-entry count (#54, git history of `pkgs/rootfs.nix`).
`docs/blob-replacement.md` and `docs/deblob-capture.md` are kept as the
reverse-engineering record, not as instructions.

## Hardware tripwires

- eMMC is `/dev/mmcblk0`; the SD card is `/dev/mmcblk1`. **Never write mmcblk0 during
  SD-card testing.** (Deliberate duplication with `docs/flashing-and-recovery.md` — keep both.)
  There is no SD image any more (#97 removed the vendor-layout one); if the SD
  story is wanted for the NixOS image it is new work -- #7/#9.
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
bits select nothing, and since #97 there is no A/B packaging left to point them
at. **That SPL is blob-free (#90):** signed with an empty
`-fw` member, so the closed EIP-130 firmware is not spliced in at
0xCC00/0x2CC00 at all — the BootROM accepts a header declaring `fw_size = 0`,
proven across two warm reboots and a cold cycle. `.#spl-minimal-eip` rebuilds
the vendor-shaped container if a unit ever needs it. **It is also compiled
`SUPPPORT_GZIPD=FALSE` (#95, on hardware 2026-09-12)**, so it reads `atf` and
`uboot` straight from flash — those two are stored RAW behind their signed
headers and `ax_gzip` is gone from the tree. The container carries no
"compressed" flag, so `pkgs/spl-minimal.nix`, `pkgs/atf-mainline.nix` and
`pkgs/uboot-mainline.nix` are **one artefact**: change one alone and the board
is dark with no console, in either direction. A good boot sets milestone bits
28+29 (`0x30000000`); the low nibble of `0x02390024` is the SPL's own A/B slot
bookkeeping, rewritten every boot, and means nothing. **A mainline boot is 71 seconds to SSH since #91 was fixed
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

**`/boot` IS the NixOS layout on the board, hardware-proven 2026-09-11 (#99),
and there is no `/boot/Image` any more.** It holds `extlinux/`, `nixos/` and
`ver` — 51 MB of 245 MB — and the mechanism below was watched working over six
boots: the bootstrap, a forced rollback, a kernel-only generation, and a
rollback that came back on the OLD kernel while the profile symlink still
pointed at the new one. Four things that cost time if you assume otherwise:
`/boot` must be MOUNTED before any `switch-to-configuration boot`
(`mountpoint -q /boot`) or the builder writes into the rootfs's own `/boot`;
**read the `DEFAULT` label, never the first `init=`**, because both files list
every generation; a toplevel with no `kernel`/`initrd` link gets NO menu entry
at all (`addEntry()` returns early), which is why generations 1-3 on this board
are not bootable and why migrating a pre-#99 `/boot` costs one generation of
space rather than `configurationLimit`; and a kernel change needs no extra
copy, because the kernel is in the closure.

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

**Nix is on the appliance, and an update is a signed closure (#100, 2026-09-11;
supersedes #86's tar bundle).** The release publishes ~200 bytes —
`.#system-manifest`, naming a toplevel store path — and pushes that closure to
the binary cache; the device runs `nix copy --from <cache>` with
`require-sigs` and **its own** `trusted-public-keys` (passed on the command
line, never read from `/etc/nix/nix.conf`), then `nix-env -p
/nix/var/nix/profiles/system --set`, then `switch-to-configuration boot`. Only
what the board is missing crosses the wire, and a NAR nobody trusted signed does
not install. Nix runs **single-user** (the daemon socket is not wanted): one
root user, no builds, and signature checking on a direct LocalStore has no
trusted-user bypass. The image ships a **registered store** — the db is built
from `closureInfo` at image-build time and asserted to equal the closure — because
a directory of store paths is not a store (`nix-env --set` on an unregistered
path tries to *download* it). GC is `nanokvm-update gc`: pin every generation a
boot config names as a gcroot **first**, then `nix-env --delete-generations` and
`nix-collect-garbage`. Costs 52 store paths / ~29 MiB of closure. The 4.19
overlay OTA and `.#update-package` are **deleted** — a vendor-layout board is
reflashed over AXDL, by decision, because nobody runs the alpha releases.
**Unattended updates are a web-UI checkbox** (`/etc/kvm/auto_updates`, beside the
preview flag — there is no `nanokvm.update.auto`), they install on the timer and
**reboot only when the server's loopback `/api/update/idle` route says nobody is
connected**, and both channels are tagged releases only. The cache URL and its
key are **placeholders until #96** (`nanokvm.update.{cacheUrl,trustedPublicKeys}`,
and the `ATTIC_*` Actions secrets; `flake.nix` carries the intended `nixConfig`
as a **comment**, because a substituter listed there is contacted for every
missing path on every host and an unreachable one is worse than none).
**An unregistered store path is not a store path**: the generations a pre-#100
board was given by `tar` are invisible to nix, `nix-env --set` on one fails and
`nix-collect-garbage` DELETES it *with a gcroot naming it* (both measured, and
the collection was watched doing it on hardware) — so the bootstrap registers
every generation the boot configs name
(`nix-store --dump-db $(nix-store -qR …)` on the build host, `--load-db` on the
board) and `nanokvm-update gc` refuses while one is unregistered.
`docs/updates.md`.

**HARDWARE-PROVEN 2026-09-11 (#100), and the bootstrap is DONE on this board.**
Nix 2.34.8 is on it, 748 registered paths, `nix-store --verify --check-contents`
clean. **A switch is now `nix copy --to ssh://root@<board>` + `nanokvm-update
install-toplevel <path>`** (key auth — nix drives `ssh` itself, so a password is
not an option), and an update from a cache, the idle gate, the unattended reboot
and a `bootcount` rollback onto the previous generation all ran end to end
against a throwaway signed `file://` cache tunnelled in over SSH
(`.#appliance-toplevel-cachetest` is that harness; it is inert under pure
evaluation). Eight boots, 51-58 s each, one U-Boot attempt every time. **A
generation that changes the KERNEL switches the same way** — #84 shipped one on
2026-09-11 (new clock rows in the tree), 53-54 s to SSH, `bootcount` cleared
both times; the Image is in the closure, so `nix copy` carries it and the
extlinux builder writes it. Still unproven: a real cache (#96), a generation
that genuinely fails to boot, and the store db that `mkStoreDb` builds into a
flashed image. `docs/mainline-port.md` "What exists now (#100)".

**The mini-display is live on mainline (#84, 2026-09-11).** `/dev/fb0`,
`nanokvm-panel` + `nanokvm-display` active, the status screen drawn, the
backlight's duty tracking `brightness`, the 180 s blank and the wake-on-press
all measured. Read the panel without eyes on the board by dumping `/dev/fb0`
and rendering it off-device (kvm-device skill) — **the dump contains the
board's IP, so never commit one.** HDMI audio probes as the card
`Lontium Lt6911UXC` but cannot be captured, and #104 settled why with three
independent in-band oracles: **`CER` (`0x605100c`) will not latch** — the
driver writes 1, a hand `devmem` write of 1 reads back 0 — because that bit
lives in the external bit-clock domain, the I2S SPI 145 count stands at 0, and
sampling `I2S0_SCLK`/`I2S0_LRCK` (pads VI_D1 / VI_CLK0, GPIO0_A1 / GPIO0_A10)
through the GPIO block's `EXT_PORT` after a temporary mux to GPIO gives a
constant 0. **The bridge is not clocking the port, so the source is not
sending HDMI audio** — `asr` = 0 with a 4-hour movie playing, and it is not a
video-state dependency either (unchanged while MJPEG streams). Fix the source,
not the driver.

**The board's power is agent-controllable (since 2026-09-09):** it hangs off the
zigbee plug named `nanokvm switch` — user-level `power-switch` skill,
`~/.claude/skills/power-switch/switch.sh "nanokvm switch" off|on|state`. A cold
cycle clears the milestone register; SSH is back ~90 s after `on` since #91 was
fixed (it was 3-18 min before). **Leave it OFF for at least 15 s.** An 8-second
cycle on 2026-09-09 came back into the same dark state the cycle was meant to
clear; the 15-second one after it booted normally. **A flat ~3.3 W with no
open port is the hang signature**; a healthy board draws the same at idle, so
power tells you nothing on its own — only SSH does. Read the
milestone register / `bootcount` / pstore / console buffer BEFORE cycling — the
cycle destroys them. Jeremy's standing word: with self-recovery available, take
more risk on on-device experiments; the plug is the way out of a stranded
appliance, not AXDL.

## Docs index — read before working on X

| Task | Read first |
|---|---|
| Anything architectural (boot chain, pipeline, services) | `docs/architecture.md` |
| Building anything / flake outputs / pinned hashes | `docs/building.md` |
| Flashing (AXDL), recovery, the chainload slot | `docs/flashing-and-recovery.md` |
| How a device updates itself (channels, signing, rollback, GC) | `docs/updates.md` |
| Cutting a release / the release workflow / versioning | `docs/releasing.md` |
| Blob or network-endpoint questions | `docs/provenance.md` |
| Mini-display | `docs/mini-display.md` |
| Capture-pipeline internals / RE history (HISTORICAL) | `docs/blob-replacement.md` |
| Deblob epic #55: the capture-stack replacement, as it happened (HISTORICAL) | `docs/deblob-capture.md` |
| Open-encoder driver bring-up / #49 resolution (HISTORICAL) | `docs/vcmd-cma-unblock.md` |
| Testing a kernel or a whole system on the board: it is a generation switch | `docs/nixos-rootfs.md` §4b, kvm-device skill |
| NixOS appliance / pure-Nix rootfs: boot contract, identity, gaps (#26, #78) | `docs/nixos-rootfs.md` |
| Building an image that is not ours: the composable `nixosModules` (#87) | `docs/modules.md` |
| Mainline port (#26): driver inventory, boot/rollback contract, child issues #74-#87, and how a serial-less first boot is made observable | `docs/mainline-port.md` |
| SG2002 project (dormant) | `docs/plan-sg2002-research.md` |

## Working with Jeremy

- **Blob policy (2026-09-04):** the aic8800 wireless *firmware* is the only closed
  content on the image, and the only closed content allowed on it. No closed
  userspace, no closed `.ko`, ever. What the vendor SDK snapshot is still read
  for -- the SPL C source, the `imgsign` script and the two FDL download
  agents -- is build-time only, ships nothing, and since #95 contains **no
  prebuilt binary at all** (`ax_gzip` is retired). Since #102 it is the boot
  chain only: libkvm has its own headers (`kvm_types.h`) and the
  `maix_ax620e_sdk_msp` input is gone. `docs/provenance.md` is the audit.
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
  model. **Subagents are always `model: opus`** (Jeremy, 2026-09-11) — never
  Fable/Mythos, never the session model. Always check the agent's work yourself
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
