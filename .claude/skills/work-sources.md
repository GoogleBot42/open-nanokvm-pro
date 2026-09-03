# Work sources for open-nanokvm-pro

Shared reference for the `fetch-work`, `unblock`, and `reflect` skills. Not a
skill itself — just the ranked list of places candidate work comes from, and
the known inconsistencies to account for when proposing any of it.

Two projects live here:

- This repo — **active.** From-source NanoKVM-Pro (AX630C) firmware,
  a Nix flake. Git remote is Gitea: `zuckerberg/open-nanokvm-pro` on
  `git.neet.dev`, the user's forge, worked via the `tea` CLI (see the
  user-level `git-forges` skill).
- `docs/plan-sg2002-research.md` — **dormant, research-only.** SG2002 NanoKVM
  from-source rebuild. Deferred, not abandoned; see below.

## 1. Gitea issues (primary live source, check this first)

`tea login list` shows one login, `neet` (`https://git.neet.dev`), default,
authenticated as bot user `agent` — confirmed working.

```sh
tea issues list --repo zuckerberg/open-nanokvm-pro
```

Issue indices run from #1 (early seed issues #1–#8 included; #1 and #6 look
like duplicate "auto update" asks). Filed by the bot `agent` or by
`zuckerberg` directly. Don't trust any cached count — pull the live list.

Label taxonomy already in place — filter on these:

| Label | Meaning |
|---|---|
| `bug`, `enhancement`, `documentation`, `security` | kind |
| `blob-replacement` | part of the from-source/blob-removal effort |
| `hardware-validation` | needs verification on real hardware |
| `needs-human` | needs physical hardware, an owner decision, infra, or key custody — **the filter the `unblock` skill uses** |
| `priority/high`, `priority/medium`, `priority/low` | queue order |
| `good first issue`, `help wanted`, `question`, `duplicate`, `invalid`, `wontfix` | defined but unused so far |

Useful filtered pulls:

```sh
tea issues list --repo zuckerberg/open-nanokvm-pro --labels needs-human
tea issues list --repo zuckerberg/open-nanokvm-pro --labels priority/high
```

(A stale `file-issues.sh` seed script once existed — it
targeted GitHub via `gh` and its ~26 issues were long since filed on Gitea as
issues #9–#34. Deleted 2026-08-15 on Jeremy's instruction; the Gitea issues
are the only source of truth.)

## 2. Hardware-validation TODOs recorded in docs

Scanned `docs/{updates,mini-display,architecture,blob-replacement}.md`
for pending/TODO/unverified markers still present in the tree:

- **`docs/updates.md`, "Hardware validation TODO" callout (around line
  163–167):** the SPL→U-Boot A/B slot-B failover path was reasoned from
  source. **2026-08-30: now EXERCISED on hardware** (during #49) — slot B
  boots via `/etc/init.d/S99checkboot systemB`+reboot, and a kernel that
  dies on slot B auto-fails-over to slot A in ~40s (BOOTABLE bits are
  consume-once). Procedure in `docs/flashing-and-recovery.md` "Slot-B kernel
  testing". Issue #10's *deliberate slot-corruption* failover is still not
  the exact thing tested, but the failover mechanism itself is now proven.
- **Issue #42 (2026-08-17, `needs-human`): USB HID to the host is dead** —
  ep0 enumeration failure; every software remedy exhausted (ladder in the
  kvm-device skill), and the 2026-08-17 cold power cycle changed nothing —
  KVM-side PHY exonerated, fault is the physical link. Blocked on Jeremy:
  cable SWAP (not replug), different host port, host dmesg. Until
  resolved, keyboard/mouse via the web KVM does not work; video is
  unaffected.
- **`docs/mini-display.md`, "Hardware verification" section:** RESOLVED
  2026-08-15 — the from-source stack was proven end-to-end on the device
  running v2.0.0 (modules at boot, fb registration, daemon drawing, idle
  blank + knob-press wake; fb dump rendered legibly off-device). Issue #11
  closed. Durable trap retained in the doc: never unload/live-swap
  `fb_jd9853` — teardown deadlock hard-hangs the device; test at boot.
- **`docs/blob-replacement.md`:** the RE narrative log for de-blobbing
  capture/encode. The `openCapture` flag (`pkgs/kvm-encoder.nix`, default
  **off**) landed and was **device-validated 2026-07-21** for the capture
  half (real decodable 1080p H.264, teardown+re-init both clean). The
  **encoder is explicitly called out as the remaining blob gate** (near the
  end of the file): the open build still links `libax_venc`/`sys`/`ivps`/
  `proton` because the closed encoder pins them; only `libax_mipi` was
  dropped. Matches the epic issue #25 ("blob-free video encoder — port the
  open VC8000E VCMD driver"). Issue #17 (1080p-only payloads) implemented
  2026-08-17: geometry is now parametric (`kvm_capture_geom.c`), guarded by
  a mechanical 1080p byte-identity check (`nix build
  .#checks.<system>.open-capture-geometry`); **non-1080p is still untested
  on hardware — needs a non-1080p source**. Issue #16 (isp_model phys
  derivation, teardown validation, pool-block leak) was closed 2026-08-16
  with on-device warm suspend/resume validation. 2026-08-17: the first
  real-use bugs of the open backend (frame-phys off by the pool's meta
  pages → green bar + horizontal scroll; web-UI fps=0 wedging VENC
  rebuilds → black screen on refresh; 120 Hz retry storms) were fixed,
  device-verified, and released as v2.1.0-alpha.2 (commit 26ce865; doc
  section "2026-08-17" in blob-replacement.md). Follow-ups resolved
  2026-08-17: #41 (log rotation) fixed in e485d02 + hot on device; #40
  root-caused as a deploy-tooling artifact (cp onto the mapped .so zapped
  the GOT — not a firmware bug; hardening + skill fix in b95c8ba). #43
  (wifi.service crash loop) FIXED + CLOSED 2026-08-17: Restart=no drop-in
  via rootfs + OTA (97507e3), hot-applied and verified on device. #39
  (module curation) DONE + CLOSED 2026-08-17: curated 12-of-22 loader
  shipped (a553f55), device-proven over 3 warm reboots; keep/drop table in
  blob-replacement.md ("Module curation"); cold-cycle datapoint rides #42.
  2026-08-22: the ENCODER line advanced substantially. §8 device-tracing
  complete (items 1–5): VCMD ABI hardware-confirmed 1:1 with the public
  driver, hw_version_id/AsicConfig pinned, CBR rate control characterized as
  stock VCEnc one-pass RC. A device-grounded feasibility study of a fully-open
  VCEnc reimpl returned **GO for H.264 (medium-high)** (docs stages
  "2026-08-22 …" + reference data in `docs/reference/vcenc-open/`). Epic #25
  broken into children: **#44** (port the open VCMD kernel driver — the first
  buildable step, priority/high), **#45** (EWL/CMM glue), **#46** (from-scratch
  CBR controller), **#47** (VCEnc-core licensing decision — `needs-human`, the
  gate on whether "fully blob-free" is the target). Also this
  session: **#27** (kernel initramfs rebuild) reprioritized priority/low →
  **priority/high** per Jeremy (high priority for his blob-free goals).
  2026-08-23: **Stages 0 and 1 both done** (docs stages "2026-08-23 …",
  data under `docs/reference/vcenc-open/stage0|stage1/`). Stage 0 closed the
  old "main gap" — P-frame/DPB register state is now decoded (swreg18/19 =
  prev-frame recon; IDR WREG order + kick swreg5 pinned). **Stage 1 PoC
  ACHIEVED on hardware:** an open, externally-supplied VC8000E register
  program drives the encoder to a decodable, QP-controllable 1080p IDR (via a
  LINK-time cmdbuf hijack — the effective-QP control surface is swreg7/37/
  105–107/125–132). The register-program half of a from-source encoder is
  proven; remaining encoder work is submission (#44/#45) + program generation
  (#46/#47). Note: a fully-blob-free raw-ioctl submit hits the vendor `.ko`'s
  nr70/nr83 EFAULT seam — that's #44's job, not a bug. Path B (the hijack) is
  now a validated on-hardware test harness for candidate open programs.
  **2026-08-29 (overnight overseer campaign):** **#47 DECIDED + CLOSED** — fixed-QP
  open v1 first (from-scratch, no vendor ref, no capture-patch; CBR #46 deferred).
  The from-scratch **fixed-QP register-program generator (`gen_idr.py`) is DONE +
  device-proven** (docs stage "2026-08-29 Fixed-QP …" + `docs/reference/vcenc-open/
  stage-fixedqp/`; QP ladder 28–44 → decodable 1080p IDRs, swreg82 varies). **#44
  open VCMD driver PORTED + cross-compiles** (vermagic-matched `.ko`; the open LINK
  path removes the nr70/nr83 seam — confirmed from source). BUT **#25 submission is
  walled on both paths** (docs stage "2026-08-29 … finish-line"): Path B (open `.ko`)
  is flash-gated — `vcmd_mem_init` needs contiguous coherent DMA but the device has
  no `CONFIG_CMA` (proven on-device); Path A (drive vendor `ax_venc.ko`) needs
  unpublished nr70/nr83 blob RE.
  **2026-08-30 — #49 RESOLVED + closed, and #45 Stage A PROVEN (no flash):** the CMA
  kernel was flashed to slot B and DIES pre-init — `CONFIG_CMA`/`DMA_CMA` are
  vermagic-invisible but ABI-breaking for the vendor blobs (struct device `cma_area`;
  migratetype/`struct zone`), proven by slot-B bisection. Replaced with the open
  driver declaring an 8 MB CMM-tail coherent carveout via
  `dma_declare_coherent_memory()` on the SHIPPING kernel (+ open `clk_venc_eb`, real
  GIC_SPI 93 IRQ). Open driver initialises + `/dev/es_venc` live. Then **#45 Stage A**:
  `pkgs/vcenc-ewl` (`ewl_probe`) drives the full open VCMD cmdbuf lifecycle from
  userspace (RESERVE→LINK→WAIT→RELEASE) — hardware DMAs encoder swreg0=0x90101010
  into the mmap'd status pool. NO vendor lib, NO flash. `.#kernel-cma` outputs removed.
  **2026-08-30 (later) — #44 + #45 BOTH CLOSED (Stages B–D device-proven):** Stage B
  drove a real 1080p fixed-QP(32) IDR through the open path; Stage C made it a
  **fully decodable stream** (from-source SPS/PPS in `vcenc_header.h`, params pinned
  by bit-parsing our own slice; ffmpeg decodes with zero errors) and **resolved the
  input format: packed YUYV 4:2:2** (test-card proof; sw17=0x30 "NV12" label wrong;
  encoder input == open capture output); Stage D added the **from-source CMM
  allocator** (`pkgs/vc8000-vcmd/framebuf_alloc.c`, ioctls 36/37, per-fd ownership)
  and retired `/dev/mem` — allocator run bit-identical to the fixed-address run.
  **2026-08-30 (same day, later) — P-frames + GOP + kvm-app integration ALL
  device-proven:** `vcenc_encode.h` is a per-frame builder (Stage-0-derived P
  overlay + recon/aux ping-pong; GOP restart = plain frame-0 replay; QP is a
  per-frame input = the #46 seam); 10-frame IPPP and 20-frame GOP-8 streams
  decode clean, moving test card tracks pixel-perfect. Then
  `kvm_venc_open.c` (`.#kvm-encoder-openvenc`, ZERO vendor libs) put the open
  encoder behind libkvm's venc seam (zero-copy: capture YUYV phys straight
  into swreg12) and **the server's real wss h264-direct endpoint streamed live
  HDMI blob-free** (0 libax mappings in the process). Bonus fix: libkvm's
  malloc-per-NAL leaked (Go never frees) → library-owned serve buffer,
  deployed. **#50 FIXED + closed (2026-08-31):** the ax_proton teardown oops
  was armed by our OWN capture issuing AINR ioctl 0xc008708a (proton nr138),
  now gated off — not an ax_venc-registration gap (the two-function-RE plan was
  wrong). Hardware-proven clean teardown; docs/blob-replacement.md "#50 FIXED".
  **#51 DONE + closed (2026-08-31):** blob-free MJPEG via from-source soft-JPEG
  (libjpeg-turbo raw 4:2:2 over the mapped YUYV frame), hardware-proven ~9 fps
  1080p, 0 libax mappings (5a24baf). **#17 DONE (2026-08-31, e115561 +
  31a55d0):** openvenc geometry fully parametric (vcenc_geom laws from a
  17-geometry vendor differential) AND open CAPTURE hardware-proven at **4K30**
  — the MIPI link was never the wall (nDataRate=600 = PHY timing band, not a
  per-lane ceiling; vendor captures 4K30 over the same 4-lane link). Capture
  envelope now 64x64..3840x2160; both non-1080p suspects (os_mem 0xf0, nr54)
  disproven; stride assumption A2 resolved to stride==width. Only 4K blob-free
  *encode* remains (framebuf carveout, split to **#52**) — NOT a default-flip
  blocker. Also landed: clean-room EDID set (pkgs/edid, from source,
  --check-clean, fixes Sipeed's shared-identity defect), shipped via rootfs.
  **#25 openvenc-as-default now gates on #46 (RC) only** — or ship fixed-QP v1
  per #25's fallback; the flip+close call is Jeremy's.
  Blob-RE roadmap in `docs/blob-replacement.md` (2026-08-30). Non-encoder blob work
  the same night: **#27** initramfs from nixpkgs DONE (static musl, 5 blobs gone,
  bit-reproducible); axbox syslog + 4 stray closed blobs dropped; **#48** filed (42
  unused `/opt/lib` libs = 29.4 MB, needs a device `lsof`); **#26** NixOS rootfs
  verdict + green scaffold (nixos-24.11, systemd-256 kernel floor) with 4 review
  defects fixed. All hardware flash/boot tests remain human-gated.
  **2026-08-31 — epic #55 (full deblob) SCOPED + decided:** working doc
  `docs/deblob-capture.md`, clean-room evidence `docs/reference/deblob-scope/`.
  KVM path is pure ISP-bypass (CSI-2→IFE-WDMA→DDR writer, not an ISP); blobs
  unstripped; clk/reset/IRQ open in-tree; OSAL is GPL source in the SDK.
  Decision: clean V4L2/media-controller, whole-closure swap (no vendor-ioctl
  drop-in, no inter-blob ABI reimpl). Children: **#56** stub experiment (4
  blobs out if green), **#57** M1 CSI-2 ident (likely Synopsys DWC) + open
  subdev, **#58** gate RE (ax_base CDMA descriptor + proton bypass/IFE-WDMA
  spec — do before any proton timeline), **#59** M2 frames-to-DDR, **#60** M3
  parity + closure retirement. EDID set COMPLETE from source (all six bins;
  **#61** hw validation is Jeremy-gated; **#62** 720p UI omission -- FIXED e286ddc, closed 2026-09-03). **#60 + #54 closed 2026-09-03; epic #55 body rewritten to "executing-blob goal MET"** -- what is left there is human bench work (flash the #54 image, #61, real non-4K source, mini-display visual), #52, #63, #28, and the M1<->M2 subdev-link polish.
  Standing rule: vendor-binary RE only via describing subagents (behavioral
  specs), implementation from specs only.
  **2026-09-02 STATUS — M1 + M2 HARDWARE-PROVEN; M3 is the open front.** #56/#57/#58
  closed (stub 0 edge hits; CSI-2 core is custom; specs verified). **#59 M2 milestone
  reached 2026-09-01:** 4K30 YUYV frames to DDR with the two open drivers alone, zero
  vendor capture modules, either load order — docs/deblob-capture.md step 4 has the
  resolved picture (the DEADBEEF wall was resets + the ISP-top gate; M2 config is a
  golden-table replay; M1 is spec-exact per specs/spec-dphy-writes.md; the WDMA shadow
  strobe per frame per specs/spec-ife-start.md). **2026-09-02: geometry + pixel parity
  CLOSED** without a second source (vendor driver run at fake geometries vs the 4K
  source; `regdumps/geom/README.md`): four geometry words, all already parametric; the
  `0x142f8 = 0` WDMA sample-width word was missing from the non-zero-only snapshot and
  made open frames `vendor<<4` — fixed, open frames now match vendor pool frames at
  720p/1080p/4K, packing is **YUYV** (not UYVY), 30 fps sustained. The bench HTPC is a
  couch-UI session that PINS its mode regardless of EDID (a real 1080p60 signal is a
  human step). **#60 M3 SHIPPED 2026-09-02 (same session):** `kvm_capture_v4l2.c`
  (`.#kvm-encoder-v4l2`, now the image default) drives `/dev/video0` over plain V4L2 and
  hands the open encoder each frame zero-copy via dma-buf (capture driver exports; open
  VCMD driver imports through new ioctls 38/39). The default loader insmods exactly three
  from-source modules and ZERO vendor ax_*.ko (ax_sys/cmm/pool/base proven unnecessary by
  live rmmod + cold boot). Hardware-proven: web 200, 4K MJPEG, H.264 over wss (1080p crop),
  cold boot of the shipped config.
  **#54 DONE 2026-09-03 (blob purge round 2 -- last executing-blob item of #55):**
  `pkgs/rootfs.nix` step 5d2 deletes ~355 files / ~248 MB from the flashed image,
  enumerated from the vendor rootfs and build-asserted gone -- ALL vendor `/soc/ko`
  modules (all 22 `ax_*.ko`, `ax_perf_monitor` included, + the vendor
  `aic8800_{bsp,btlpm,fdrv}` /
  `hynitron_touch` copies, 26 files / ~32 MB; `/soc/ko` now holds only our three open
  modules), `/opt/lib/libsns_*.so` except our `libsns_dummy.so` (13 / ~24 MB), the NPU /
  AI-ISP model data `/opt/etc/{models,skelModels}` + `/opt/data/npu` (62 / ~167 MB), and
  the `/opt/etc` ISP tuning `*.ini`/`*.bin` set (254 / ~26 MB). No rollback loader ships
  any more (nothing left to insmod -- reverting = reflash the vendor `.axp`);
  `ax-load-drv.vendor.sh` stays as the byte-compare pin, the `.openvenc`/`.base-only`/
  `.stub` variants are bench-only. `/opt/scripts/wifi.sh` rewritten insmod-by-path ->
  `modprobe` (udev already autoloads our from-source aic8800 modules, device-proven).
  Remaining closed content on a flashed image: aic8800 WiFi/BT **firmware** (~3.5 MB,
  #28) + the flash-time-only `eip_ax620e.bin`. Vermagic no longer binds anything shipped.
  OTA can't delete, so an OTA-upgraded device keeps the purged files until reflash.
  Residuals: async subdev link (polish), real non-4K signal (human), #52 4K H.264,
  #61 EDID hw validation. #53 DMA map shipped + hw-validated. #63 = pre-existing encoder DMA-mask WARN
  at module load (cosmetic). Harness: base-only loader swap + reboot (memory
  device-hardware-status has the exact paths); never read 0x04403000 on an open boot.
- **`docs/architecture.md`:** no pending/TODO/unverified markers found in
  this scan — it currently reads as settled. Don't assume that stays true;
  re-grep before trusting it stale.

Idle video power-down (`kvmv_video_suspend`/`resume`, commit `bfa823e`):
**fully observed live on device 2026-08-15** — suspend engages when idle
(mini-display reads "video asleep (power save)") and resume-on-viewer
worked in real use (Jeremy opened the web KVM from the suspended state;
video and HID both functional). No longer a pending validation item.

## 3. Memory dir (transient session state)

`/home/googlebot/.claude/projects/-home-googlebot-workspace-nanokvm-nix-nanokvm-pro/memory/`

Contains `MEMORY.md` (the index) plus four project memory files:
`nanokvm-nix-rebuild-project.md` (SG2002), `nanokvm-pro-blob-audit.md`,
`nanokvm-pro-runtime-stack.md`, `nanokvm-pro-ota-updates.md`. These carry
day-to-day findings that haven't necessarily been codified into docs yet —
check them for recent context. (All four were reconciled against the tree
as of 2026-08-15; no known staleness.)

## 4. Dormant SG2002 project

`docs/plan-sg2002-research.md` (~52KB). Latest dated entries are 2026-07-18; the
user's priority decision ("Pro first") deferred — not abandoned — the SG2002
flake in favor of the Pro rebuild, which is where all subsequent work went.
Nothing else in this repo touches SG2002.

Resuming it starts with **packaging a T-Head C906 GCC toolchain**: the
target needs `-mcpu=c906fdv -march=rv64imafdcv0p7xthead -mcmodel=medany
-mabi=lp64d` with musl libc, and stock nixpkgs GCC lacks the `xtheadv0p7`
vector extension (per memory `nanokvm-nix-rebuild-project.md`). Don't
propose SG2002 work without flagging this gap up front.

## 5. Known inconsistencies awaiting work

- **Preview/alpha update channel: LIVE + pipeline-proven (issues #19 + #4
  closed 2026-08-16).** Alpha = any `-suffix` semver version via
  cut-release; publishes as a GitHub prerelease + refreshes the rolling
  `preview` release the web-UI toggle polls. Proven by the real
  v2.1.0-alpha.1 cut (openCapture build): prerelease flag set, rolling
  `preview` release refreshed (manifest 2.1.0-alpha.1 + payload,
  hash-verified bit-exact), stable channel untouched (still 2.0.0).
- **Release pipeline: LIVE (issue #37 closed 2026-08-15).** Gitea source
  of truth → push mirror → public GitHub downstream mirror
  (GoogleBot42/open-nanokvm-pro) hosts releases and runs the tag-triggered
  release workflow. v2.0.0 published, verified, and APPLIED on the device
  (2026-08-16) — the full-firmware OTA path incl. partition writes +
  reboot is hardware-proven. A/B *failover* is still unexercised (#10).
  Releases are cut via the `cut-release` workflow in the Gitea web UI
  (dry-run-tested; `tools/release` = fallback). Never propose
  pushing/tagging on GitHub directly; see `docs/updates.md`.
