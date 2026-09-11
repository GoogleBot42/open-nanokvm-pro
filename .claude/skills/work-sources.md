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

- **The A/B slot-B failover** was reasoned from source, then EXERCISED on
  hardware 2026-08-30 (during #49): slot B booted via
  `/etc/init.d/S99checkboot systemB`+reboot, and a kernel that died on slot B
  auto-failed-over to slot A in ~40 s (BOOTABLE bits are consume-once).
  **Historical.** #89 rung 4 removed the A/B twins and rung 5 replaced the
  whole mechanism with `bootcount` + two extlinux configs
  (`docs/nixos-rootfs.md` §4b, unattended rollback hardware-proven);
  #97 deleted the slot packaging and the `docs/updates.md` callout this entry
  used to cite.
- **2026-09-04 STATUS.** Jeremy's decisions: WiFi stays, the aic8800 firmware is
  the ONLY closed content ever permitted (#28 closed); NixOS goes STRAIGHT to
  mainline (#26 stage 1 skipped; #10 closed obsolete); #17/#25 closed
  (bookkeeping; only #46 rate control remains as encoder quality work); #42
  closed (HID works again, physical-link fault). The pre-mainline
  vendor-differential capture is DONE (encoder + MIPI, see blob-replacement.md
  stage 2026-09-04 and regdumps/mipi-20260904) — nothing further needs the
  vendor 4.19 stack. Open human bench items: flash alpha.4, a real 1080p60
  source (the open stack has never seen 60 Hz), mini-display preview on the V4L2
  path, #61 EDIDs. Open agent items: fixed-QP/QP-ladder validation on the live
  web path (`OPENKVM_VENC_RC=fixqp`), capture envelope to 2400 rows, then #46.
- ~~**Issue #42 (2026-08-17, `needs-human`): USB HID to the host is dead**~~ —
  **CLOSED 2026-09-04**, HID works again (physical link); history:
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
  disproven; stride assumption A2 resolved to stride==width. 4K blob-free
  *encode* was split to **#52** (framebuf carveout) and is DONE 2026-09-03.
  Also landed: clean-room EDID set (pkgs/edid, from source,
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
  **#61** hw validation is Jeremy-gated; **#62** 720p UI omission -- FIXED e286ddc, closed 2026-09-03). **#60 + #54 closed 2026-09-03; epic #55 body rewritten to "executing-blob goal MET"** -- what is left there is human bench work (flash the #54 image, #61, real non-4K source, mini-display visual), #63, #28, and the M1<->M2 subdev-link polish (**#52 closed 2026-09-03** -- 4K blob-free H.264, see below).
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
  The 4.19 overlay OTA could not delete, so a device upgraded by one kept the purged files until reflash; #86 retired that OTA outright.
  **#52 DONE 2026-09-03 (4K blob-free H.264):** `vcenc_geom.h` envelope 1920x1200 ->
  3840x2160 plus `vcenc_geom_build_ex(..., want_input)` (libkvm passes 0 -- it points the
  encoder input registers at the capture frame's own bus address, so a 4K floorplan spans
  59.21 MB instead of 90.85 MB), and the DMA map gave it room: `MAP_FRAMEBUF_MB` 64 -> 136,
  `MAP_CMM_MIN_MB` 72 -> 0 (ax_cmm's slice, unclaimed since #55 M3/#54, folded into the
  encoder framebuf). 1G map is now framebuf 0x73800000 +136MB / capture 0x7C000000 +56MB /
  coherent 0x7F800000 +8MB = the whole 200 MB pool; rootfs.nix asserts
  `MAP_FRAMEBUF_MB >= 92`; the bench `.openvenc`/`.base-only`/`.stub` loaders keep 64/72
  (they still load ax_cmm). Hardware-proven: prover PASS 20/20 at 3840x2160 (ffprobe: Main
  L5.1, clean decode) and the live wss h264-direct path at the NATIVE 4K bench source with
  OPENKVM_FORCE_GEOM unset -- 90 NALs / 462 KB, 0 libax maps, ~25 fps. Whole video path
  (capture, MJPEG, H.264) is now blob-free at 4K; FORCE_GEOM is only a bench downscale hook.
  Caveats: no vendor golden vector at 4K (the 17-geometry differential tops out at
  1920x1200 -- laws extrapolate, device run is the proof), `vcenc_level_idc` falls through
  to 51, `out_limit` 16.65 MB makes libkvm's pack copy ~16 MB/frame at 4K (fps cost), RC
  still fixed QP32 (#46).
  Residuals: async subdev link (polish), real non-4K signal (human),
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
  reboot is hardware-proven. A/B *failover* was never exercised (#10 closed
  2026-09-04 as obsolete: NixOS generations + automatic rollback replace it, #26).
  Releases are cut via the `cut-release` workflow in the Gitea web UI
  (dry-run-tested; `tools/release` = fallback). Never propose
  pushing/tagging on GitHub directly; see `docs/updates.md`.
- **#64 HEVC (2026-09-05): capture campaign DONE + blob-free H.265 IMPLEMENTED** the same
  night, without the assumed vendor `.axp` reflash (vendor stack loaded at runtime from
  `.#ax-ko-blobs` + `.#axera-libs` + the stock-rootfs `libax_venc.so`; recipe in the
  device-re-subagent skill). Evidence: `docs/reference/vcenc-open/vendor-diff-hevc-20260905/`.
  Code: `vcenc_encode.h` HEVC overlay, `vcenc_hevc_header.h` (byte-identical to vendor
  VPS/SPS/PPS), 34-program golden test, `kvm_venc_open.c` `PT_H265`, libkvm `IMG_H265_*`
  channel -- device-proven via prover (1080p..3840x2400) and via `kvmv_read_img` on real
  HDMI capture (ffmpeg 0 errors). **2026-09-05 (night) four-agent sweep, all on main:**
  **#66 DONE** (h265-direct web consumer, device-proven; supported-browser live check is
  a human step), **#46 DONE** (from-scratch CBR/VBR controller, CBR now the DEFAULT for
  both codecs, device-proven; `open-venc-rc` check), real-content vendor RC oracle
  banked (`vendor-diff-rc-20260905/`), `docs/mainline-port.md` (#26 inventory; its
  14 proposed children were filed 2026-09-06 as #74-#87, see below), **#67 filed** (direct players do not reconnect
  after a ws close -- upstream behaviour). Draft `CHANGELOG.md` v2.1.0-alpha.5 section
  written; release NOT cut. Open on #64: cold-boot proof once an image ships.
  **Nothing left needs the 4.19 vendor stack** -- the pre-mainline wishlist is consumed.
  Bench: USB HID to the host DOWN again since 2026-09-05 (#42 pattern, physical link).
  **Later 2026-09-05:** **#68 FIXED** (Chromium white screen in H.264 Direct = upstream
  sent SPS/PPS as separate non-key messages; now folded into the IDR, device-proven,
  headless-Chromium 150/150 frames); H.265 Direct always selectable (probe advisory,
  fallback only on real decoder failure); **Firefox exposes NO HEVC via WebCodecs**
  although its media pipeline decodes HEVC -- real H.265 in Firefox needs an MSE remux
  player (design note on #66, Jeremy's call). **#69 filed** (WebRTC white screen; the
  stream-type takeover is real but does NOT explain Jeremy's case -- his Chromium decodes
  at 59 fps in software, play() ok, picture blank; GPU compositing suspect, awaiting a
  `--disable-gpu-compositing` test). **Even later:** **web UI FORKED into `web/`**
  (Jeremy's decision; `pkgs/patches/` gone), **#72 DONE** (MSE player: H.265 and H.264
  through `<video>` without WebCodecs, Firefox/Chromium headless device-proven; "H.265
  Direct" auto-picks WebCodecs > MSE > H.264 fallback), **#70 filed** (mode change
  reloads the page), **#71 filed** (no cache headers on index.html -> stale bundles).
  **Jeremy's browser results (evening):** Firefox/Linux plays H.265 via MSE (#72 confirmed);
  Chromium/Linux/AMD paints EVERY <video>-element mode white (WebRTC + both MSE modes)
  while canvas modes work -> **#69 broadened** to video-element rendering; **#73 filed**
  (H.265 Direct's auto-MSE path has dead keyboard/mouse input; explicit h265-mse is fine);
  #71 still forces cache-disable on every deploy. **Night of 2026-09-05 (three Opus
  worktree agents + session):** **#71 FIXED+closed** (content-ETag/no-cache index,
  immutable assets; the store mtime made even forced reloads 304-stale), **#73
  FIXED+closed** (`useScreenElement` MutationObserver hook; keyboard was never dead),
  **#72 agent boxes DONE** (4K HEVC via MSE in Firefox, EDID-driven live resolution
  change with a new init segment, stored-mode fallback fix; left open only for a
  human at a hardware-HEVC browser). **#69 NOT reproduced** across headed Chromium/
  Chrome 152 on Xvfb, sway (pixman/radeonsi), Weston colour-managed, and KWin 6.7
  `--virtual` incl. the device's WebRTC/MSE streams — harness + matrix in
  `docs/reference/vcenc-open/chromium-white-compositors-20260905/`. **Then RESOLVED the
  same night: Jeremy bisected his profile to `chrome://flags/#enable-vulkan`; reproduced
  on the build host under KWin and sway (`--enable-features=Vulkan` → 93 % white, Skia
  Vulkan backend cannot import software-decoded frames on Wayland ozone; WebCodecs/canvas
  modes unaffected). Only page-side oracle: `VideoFrame.copyTo()` throws
  `InvalidStateError` (pixel reads give opaque black = same as a black host screen). A
  detector + H.264 Direct auto-fallback with a notice naming the flag SHIPPED (merged
  42070bb, on the device as `index-BZloHD67.js`; `useUndrawableVideoDetector.ts` keys on
  `new VideoFrame(videoElement).copyTo()` throwing — track/captureStream frames read fine
  even when the screen is white). #69 closed.**
  **2026-09-06 — the browser queue is EMPTY.** #67, #70 and the #69 stream-type
  hand-back all shipped and are device-proven; #68 and #46 (done since 2026-09-05)
  were closed as bookkeeping. Open issues were down to 17 then (28 after the
  #74-#87 filing on 2026-09-06), and every one of them is
  either an epic (#55, #26), `needs-human`, or open only pending a human bench/browser
  check (#61, #64 cold boot, #66 supported-browser, #72 hardware-HEVC browser).
  Evidence + reusable harnesses: `docs/reference/vcenc-open/stream-handback-20260906/`
  (`handback_test.py` runs on the device, stdlib only; `cdp_reconnect.py` drives the
  real UI in headless Chromium through the loopback tunnel). Three lessons worth
  keeping: **build an A/B control by deploying the pre-fix binary** — the pre-change
  server was one `nix build` from a throwaway git worktree away, and phase 3 going
  58 → 0 → 58 frames is what makes the result mean anything; **for a page-lifetime
  claim, use an oracle a reload destroys** (a wrapped `window.WebSocket` counter plus
  a post-load sentinel), not a screenshot; and **the antd menu chain is
  click-then-hover** — `components/menu-item.tsx` sets `trigger="click"` on the
  sidebar while the video-mode Popover inside it is hover-triggered, so a harness
  must do both, locating each by its lucide icon class rather than a translated
  label. Still open on the #69 write-up: fix 3 (honour PLI/FIR in
  `startRTCPReader`), which needs a force-IDR in libkvm first. Also unchanged: while
  two consumers are connected one is necessarily starved — that is arbitration, not a
  bug, and the page already says "inconsistent video mode".

- **2026-09-06 — v2.1.0-alpha.5 is CUT ON GITEA BUT NOT PUBLISHED.** The
  `cut-release` workflow succeeded (commit `4e6cf0b` `release: 2.1.0-alpha.5`,
  tag `v2.1.0-alpha.5`, `preview` tag moved), the mirror replicated it, and
  then the GitHub `release.yml` run FAILED after 11.5 min in its first step,
  `nix build .#update-package`. No release object exists, so **devices are
  unaffected** — stable still serves 2.0.0 and the preview channel still
  serves alpha.4. **Cause found and FIXED 2026-09-07 (`bc1ec0a`, branch
  `fix/server-vendorhash`): `pkgs/nanokvm-server.nix` carried a `vendorHash`
  stale since #71 (`f429b2a`, 2026-09-05).** That commit's `postPatch` step 11
  drops the `github.com/gin-gonic/contrib/static` import; the go-modules
  derivation inherits `postPatch`, and `go mod vendor` vendors only imported
  packages, so that module left the vendor tree — the modules.txt diff is
  exactly that one line. It stayed invisible because a fixed-output
  derivation's store path comes from its hash alone: this build host already
  held the July output and never re-fetched, so "`.#update-package` builds
  green locally" was never evidence. `nix build --rebuild` on the go-modules
  drv reproduces the runner's hash exactly. The `v2.1.0-alpha.5` tag still
  points at the broken tree and stays where it is (never move tags).
  **Superseded by `v2.1.0-alpha.6`, cut over the Gitea API and PUBLISHED on
  GitHub 2026-09-07** (`8e26530`; same content plus the fix; the `preview`
  manifest serves alpha.6, sha512 `l9GXB1Jk…`). That checkbox is GONE: #86
  retired the 4.19 overlay OTA outright (2026-09-10, no users), and the board
  runs the mainline appliance.

- **2026-09-06 — the mainline port (#26) has a queue.** The 14 children drafted in
  `docs/mainline-port.md` section 8 are filed as **#74-#87** in dependency order
  (index map is a comment on #26, and the doc's section 8 now carries the real
  numbers). **#74 is DONE + closed** (2fbc1b8, 3cf8fa4, 31ed0a2): `.#kernel-mainline`
  builds mainline Linux 7.1.3 from the nixpkgs pin (`arm64 defconfig` +
  `pkgs/kernel-mainline/ax630c.config`), `.#dtb-mainline` compiles our own
  `dts/ax630c{.dtsi,-nanokvm-pro.dts}` with `cpp` + `dtc -p 4096`, and both are
  packaged for the slot-B partitions so #75's first boot is reversible. Additive:
  all eight vendor-path derivation hashes are byte-identical to before. New gate
  `.#checks.<system>.mainline-dtb`.
  **#75 is DONE + device-proven (2026-09-06): A MAINLINE KERNEL HAS BOOTED ON
  THIS SILICON.** Slot-B boot of `.#kernel-mainline` brought up both A53s,
  probed the clk/pinctrl/watchdog drivers, reached userspace, lived **122 s**
  (twice U-Boot's 30 s-per-stage wdt0 arm, with `watchdog0 timeleft=29` at every
  10 s sample — the core petting the adopted dog), rebooted itself through a
  `syscon-reboot` node on `CHIP_RST_SW`, and the SPL failed back to slot A on
  its own. Evidence: `docs/reference/mainline/first-boot-20260906/` (full boot
  log, both persistence channels). New: `drivers/watchdog/ax630c_wdt.c` from
  `docs/reference/mainline/wdt-model-20260906.md`, and
  `pkgs/initramfs-mainline.nix` + `pkgs/kernel-mainline/initramfs/bringup-init.c`
  — one static musl `/init` that leaves boot evidence in slot-register bits
  12-15, in reserved DRAM, and on the heartbeat LED. Reusable for every later
  child issue's first boot. Device was restored to slot B = vendor kernel;
  `/root/pre75/` holds both backups and the mainline images for a fast re-test.
  **#80's source half is DONE (2026-09-06, still open).** Both data models are
  banked as specs — `docs/reference/mainline/{clk,pinctrl}-model-20260906.md`,
  written by Opus subagents from the vendor GPL *source* and reconciled against
  read-only device captures in the sibling `device-reads-20260906/` — and both
  drivers are written from those specs and building in-tree
  (`pkgs/kernel-mainline/tree/`, a graft laid out at upstream paths). 246 clocks
  (CPUPLL deliberately read-only, which deletes the relock hazard) and 111 pads /
  56 functions / 167 groups. It corrected four counts in `docs/mainline-port.md`
  §2: 246 clocks not 247, 133 DEMO writes not ~66, 56 functions not ~30, 97
  gpio-ranges not 128. What #80 still owes is the I2C and DEMO-derived pin
  states, deliberately deferred to #76 and #81 because they attach to DT nodes
  that do not exist yet. #75 boot-tested both drivers on hardware: they probe,
  and the clock framework runs the tree to completion (`clk: Disabling unused
  clocks`).
  **2026-09-07 status of the queue:** **#76** eMMC half DONE (stock
  `sdhci-cadence`, no driver port; root-on-SD blocked on a missing card,
  `needs-human`); **#77 DONE, device-proven** (`tools/kvmssh` reaches the
  mainline kernel over Ethernet from the slot-B initramfs; PHY is a Realtek
  RTL8211F, `phy-mode = rgmii-id`; milestone mask `0x3FF000` at the time, `0x1FFF000` since #82; b2935d8);
  **#80 follow-ups DONE, device-proven** (reset controller, six WDT clock IDs,
  watchdog on CCF clocks/resets, five `pinctrl-0` states; 3600 s dwell,
  `0x003FF014`; 16cedba) -- #80 still owes `gmac` pin states and the CPUPLL/
  cpufreq model; **#81 DONE, device-proven 2026-09-07** (`gpio-ax630c.c` for
  the four controllers, `lt6911-manage.c` replacing the vendor's 2907-line
  driver with the 15-file `/proc` ABI intact, an i2c0 node, the PHY reset moved
  to `reset-gpios`, `nanokvm-gpio` as a libgpiod program instead of a
  sysfs-export unit, and 14 more clock rows; `0x003FF014`, evidence in
  `docs/reference/mainline/gpio-lt6911-20260907/`). **The SW_PWR trap is fixed
  at the root on mainline**: `gpio_request_enable()` got its first exercise on
  silicon and four pad words measurably changed function because a driver
  asked for the line. **#82 DONE, device-proven 2026-09-07** -- **a host
  enumerated a mainline-kernel USB HID gadget from this board**
  (`0x01FFF014`, every bit; gadget bound at t=12.63 s, host had it configured
  1.0 s later at high speed; `docs/reference/mainline/usb-gadget-20260907/`).
  `dwc3-axera.c` is a ~200-line of-simple-class glue whose real content is the
  VBUSVALID bit no generic glue can express; two DT nodes so the core takes
  the 24 MHz `ref` clock and lands on the vendor's exact GFLADJ constants;
  three flash clock rows and two reset lines; the configfs gadget and all five
  `usbdev.sh` function drivers built in (5 of 5 instantiated); milestone bits
  22/23/24 and mask `0x1FFF000`. **#82 is also where the reset provider's
  `.assert` finally ran on silicon** -- #81 only ever needed deassert, and
  pulsing a GPIO block whose lines drive the host's power button was rightly
  not done for coverage; the USB PHY reset needed a real pulse and got one.
  With both branches merged the clock table is **282 rows** (265 + 14 + 3) and
  the reset table 150. #74 and #77 are closed on the forge; #81 and #82 stay
  open with their residuals listed in coordinator comments (2026-09-07).
  **#78 offline half DONE** (the NixOS appliance is off the vendor kernel and
  off the second nixpkgs pin -- `nixpkgs-rootfs` deleted -- boots to multi-user
  under `qemu-system-aarch64` with zero failed units and the server on :80/:443;
  `nix run .#nixos-appliance-qemu-run`). It takes #81's `gpioBackend =
  "libgpiod"` server and ships `nanokvm-gpio`, so it is also what will finally
  run that tool on hardware, and it owns the USB gadget's *policy* -- report
  descriptors, flag files, the `udhcpd` instance -- that #82 deliberately left
  (the vendor `usbdev.sh` is still uncaptured).
  Two corrections it produced: **the eth0 MAC is NOT a provisioning-time
  literal** -- the vendor `/init` recomputes it from `/proc/ax_proc/uid` on
  every boot and rewrites `/etc/network/interfaces`, so that file is a cache;
  and IRAM0 is at physical 0, so `misc_info` really is at physical `0x740`
  (`uid_l` `0x788`, `uid_h` `0x78c`).
  **#78 HARDWARE HALF DONE, 2026-09-07 evening -- the appliance boots this
  board.** Six slot-B runs ending in a NixOS 26.11 system on mainline 7.1.3 with
  the device's own MAC, its own DHCP lease and its own derived hostname, zero
  failed units, NanoKVM-Server on HTTPS, in 26.3 s; root on a loop image over the
  vendor rootfs throughout, so nothing on the eMMC was overwritten.
  `docs/reference/mainline/nixos-appliance-20260907/HARDWARE.md`.
  Four findings, each of which cost a run:
  (1) **the eMMC is not reliably `mmcblk0`, and when it loses the race it has NO
  partitions at all** -- `blkdevparts=mmcblk0:` binds the table to a NAME, so it
  lands on the empty SD slot; two boots in five; fixed with `aliases { mmc0 =
  &emmc; ... }` in `dts/ax630c.dtsi`, and this affects EVERY mainline boot, not
  just #78's. (2) A slot-B appliance needs its own exit: stage-1 `panicOnFail`
  (NixOS's `fail()` blocks on an unreachable console) and a userspace deadman on
  `/proc/uptime` -- NOT `date +%s`, which timesyncd invalidates the moment DHCP
  lands. Both fired on hardware. (3) `networking.hostName` must be EMPTY or
  systemd-hostnamed refuses the transient hostname the identity service sets.
  (4) `ClientIdentifier=mac` -- the same MAC does not get the same lease when
  networkd sends a DUID. Also: the milestone clear-mask is `0xFFFF000`, not
  `0x7FFF000` (bit 27). Device left on slot A, slot B restored from
  `/root/pre75/*.bak` and verified from the medium.
  **2026-09-11 — #89 (mainline U-Boot + minimal layout) rungs 0-3 DONE:** slot A
  boots mainline TF-A 2.15 + mainline U-Boot 2026.07 + extlinux into the
  appliance, 10/10 boots, ~3 min to SSH; slot B keeps the vendor-derived U-Boot
  as the SPL's automatic fallback. Twenty-two upstream-shaped U-Boot patches
  (`pkgs/uboot-mainline/patches/`), seven of them genuine upstream bugs. The
  narrative per rung is `docs/mainline-port.md` §11.10. Open from it: **#91**
  eMMC multi-block never delivers data under mainline U-Boot (card streams,
  host deaf; every register/mode/engine excluded; single-block workaround
  patch 0017 ships; wants a logic capture of CLK+DAT0 — Jeremy asked); **#90**
  CLOSED 2026-09-09 (see below); **#92** reboot oops; **#88** parked
  behind #84 (no U-Boot splash, Jeremy). **Rung 4 is DONE** — see the
  2026-09-09 entry below; rung 5 = rollback drill on `bootcount`, which
  retires **#79**. The board is agent-power-cyclable
  (`nanokvm switch` plug) since 2026-09-09.
  **2026-09-09 — #89 RUNG 4 DONE, and #90 CLOSED with it.** The eMMC stopped
  having a vendor partition scheme: it is `spl` (the first 768 KiB, the
  BootROM's, outside every table) plus `disk` (everything after), and `disk`
  carries a spec-conformant GPT at its own LBA 0 — protective MBR at physical
  LBA 1536, alternate header in the eMMC's last sector, five named partitions
  with DPS type GUIDs. `rootfs` keeps its physical start, which is what let the
  whole conversion happen in place from a shell. Root is `/dev/loop0p5` and
  `/boot` is `/dev/loop0p4`, both on a loop device stage 1 puts over
  `/dev/mmcblk0p2`; U-Boot reads the same table through
  `CONFIG_EFI_PARTITION_BASE_LBA=1536` (patch `0023`, upstream-shaped, proved by
  `.#checks.uboot-gpt` running sandbox U-Boot against a model of the eMMC).
  `nixos/lib/emmc-layout.nix` is the one definition; `pkgs/spl-minimal.nix` is
  the SPL recompiled for those offsets — the layout and the first-stage loader
  are now one artefact. `.#migrate-layout` did the in-place conversion with
  every write verified from the medium.
  **#90 is closed:** the sign tool's `-fw` takes a file, an empty file gives
  `fw_size = 0`, and the BootROM accepts it (two warm reboots and a cold cycle).
  `.#spl-minimal` is blob-free by default; **the aic8800 wireless firmware is
  now the only closed content on the image.**
  Open from this rung: **rung 5** = the `bootcount` rollback drill, which wants
  `DM_BOOTCOUNT_SYSCON` (patch `0020` stopped U-Boot reading the env off the
  eMMC) and retires **#79** and `nanokvm-checkboot`. **#91** unchanged and now
  the boot chain's main cost. **#92** is the suspect for the one unexplained
  event: the first boot after the SPL write hung eight minutes and a power cycle
  fixed it; six boots since were clean. `SUPPPORT_GZIPD=FALSE` (retires
  `ax_gzip`, the last prebuilt x86-64 host tool) is a clean follow-up now.
  **2026-09-14 status: #89 CLOSED, and so are #79, #90, #92, #93, #94 and
  #91.** Rung 5 proved the unattended rollback (`bootcount` in
  `TOP_CHIPMODE_GLB_BACKUP1`, health-gated `nanokvm-mark-good`, `altbootcmd`);
  a fresh AXDL flash of `.#nixos-firmware-image-mainline` boots the whole chain;
  #91's cause was the eMMC DT capping HS400ES at 50 MHz against a strobe delay
  tuned for 200 MHz — boots are now 71 s, one U-Boot attempt, multi-block reads
  work, patch 0017 is gone. Traps banked in CLAUDE.md on the way: the stage-1
  panic token that never matched, an arming state a power cycle cleared, a
  token magic spelled as a hexdump, `/sys/fs/pstore` empty on healthy boots,
  the 30-minute poll. The board is agent-power-cyclable and U-Boot candidates go
  through the one-shot chainload slot, never into the `uboot` partition.
  Open: **#95** (SUPPPORT_GZIPD=FALSE, retire `ax_gzip`), and the epic's
  functional children. Bookkeeping worth doing: close **#76**, **#81**, **#82**
  (delivered; residuals in their comments) and re-title **#80** to its
  CPUPLL/cpufreq residual.
  Next: **#83** (video on mainline — the reason the appliance is not yet a KVM).
  **#86** (flake-based updates) landed its OFFLINE half 2026-09-10 -- system
  bundles, `nanokvm-update`/`nanokvm-gc`, a content-addressed kernel so the
  rollback covers one, the legacy OTA deleted -- and needs ONE device round to
  close. Then **#84**; **#85** (aic8800) is an owner decision,
  `needs-human`; **#87** last.
  **2026-09-11 status: #83 CLOSED (video streams on mainline, in-tree
  drivers, modules in the closure) and #99 CLOSED (kernel/initrd/dtb in the
  generation, NixOS's extlinux builder owns `/boot`, kernel rollback
  hardware-proven).** Jeremy's directives the same day reshaped #86: nix IS
  on the device (**#100**, merged offline, hardware rounds running), updates
  are `nix copy` from a signed cache + `nix-env --set` +
  `switch-to-configuration boot`, auto-updates are a web-UI checkbox with an
  idle-gated reboot, only tagged releases, and the legacy migration OTA is
  dropped (no users). Filed: **#96** binary cache (attic; Jeremy provides the
  endpoint, cache name, token and public key — the one blocker for a real
  update), **#97** remove the legacy 4.19 build (after #84/#86/#100),
  **#98** 4096-wide capture cap. **#86** closes after #100's hardware rounds
  prove the checkbox/idle path. Then **#84**, **#85**, **#87**, **#95**.
  **2026-09-11, end of the campaign: every agent-able child of #26 is CLOSED
  on hardware** — #83, #84 (display; audio card probes, the bench host sends
  no audio), #85 (AIC8801 scans), #86, #87 (nixosModules, `docs/modules.md`),
  #97 (legacy build gone), #98 (4096x2400 envelope), #99, #100, #101, #102
  (libkvm's own header). The board runs generation 24 with nix, WiFi, the
  panel, video at 4K DCI and the nix-native updater. **Open, and every one
  needs Jeremy:** #95 (the one-way raw boot-chain write; offline half merged,
  gzip chain stays default + recovery), #96 (attic endpoint/key/token — the
  blocker for a real update and the first tagged release), #103 (upstreaming,
  blocked on the Axera prefix), a host with HDMI audio for #84's capture
  proof, and the older `needs-human` items (#5 CI, #7/#9 SD image, #8 docs,
  #31/#32 signing and the default password, #34, #61 EDIDs, #88 logo). #26
  itself stays open until #95 and #96 land; #55 (deblob epic) can close on
  #102's evidence — closed content on the image is the aic8800 firmware only.
  Two facts worth reusing: the mainline kernel's release string must be asserted
  against `build/include/config/kernel.release` after the build, not `make
  kernelrelease` before it (they disagree); and `dtc` chokes on a `*/` appearing
  inside a block comment, which a phrase like `TEEC_*/tee_*` produces.

  **2026-09-11 — #97 LANDED: the legacy build is gone.** `fb77209` (code) and
  `fdfe9d6` (skills + CLAUDE.md) deleted everything that only existed to build,
  flash, update or document the vendor-derived Ubuntu 22.04 / Linux 4.19.125
  image. The mainline NixOS appliance is the only product.
  **Every mention of one of these in the log above is history, not a live
  reference:**

  - Flake outputs: `firmware-image`, `rootfs`, `base-axp`, the 4.19
    `kernel`/`dtb`/`initramfs`, `sd-image`, all five `*-slot-image`
    packagings, `migrate-layout`, `ax-ko-blobs`, `libsns-dummy`, `ax-stub`,
    `open-vin-csi2`, `open-vin-capture`, `vc8000-vcmd`, `boot-fsbl`/`-atf`/
    `-optee`/`-uboot`, `logo`, the four closed-backend `kvm-encoder` variants
    (the blob-free build is just `.#kvm-encoder`), `nanokvm-server-libgpiod`
    (just `.#nanokvm-server`), `nixos-appliance`, `nixos-firmware-image`,
    `nixos-appliance-loop(-nofixes)`, the two `uboot-mainline-probe-mb*`
    images, the `axp-migration-parity` check, and the
    `nanokvm-pro-vendor-layout` / `nanokvm-pro-loop` nixosConfigurations.
    `.#nixos-firmware-image-mainline` is `packages.default`.
  - Files: `pkgs/{rootfs,image,base-axp,kernel,initramfs,dtb,sd-image,slot-image,ax-ko-blobs,libsns-dummy,ax-stub,logo,migrate-layout,axp-migration-parity,boot-atf,boot-fsbl,boot-optee,boot-uboot}.nix`,
    `pkgs/rootfs/`, `pkgs/ax-stub/`, the out-of-tree
    `pkgs/{open-vin-csi2,open-vin-capture,vc8000-vcmd}/` (those drivers live in
    the kernel tree at
    `pkgs/kernel-mainline/tree/drivers/media/platform/axera/` and ship as
    `.#video-modules`), `tools/migrate-layout.sh.in`, `nixos/loop-test.nix`,
    and the `install-retired.go.in` / `pinmux-power.go.in` server overrides.
  - Skills: `deploy-iterate`, `mainline-boot-test`, `sd-flash-remote`.
  - Concepts: one eMMC layout (`nixos/lib/emmc-layout.nix`, no
    `nanokvm.emmcLayout`, no `nanokvm.rootImage`), `/boot` always ext4, no A/B
    twins, no slot-B testing, and no `gpioBackend`/`updateMode` arguments on
    `pkgs/nanokvm-server.nix`.

  **So: iterating on the device is a generation switch**, not a hot patch —
  `nix copy --to ssh://root@<board>` then `nanokvm-update install-toplevel`
  (kvm-device skill), with `bootcount` rollback as the escape; a U-Boot
  candidate goes through the one-shot chainload slot.

  **The open list after #97** (`tea issues list --state open`, read
  2026-09-11): **#84** mini-display + audio on mainline — packaged, never run
  on the board, and the biggest remaining functional gap; **#95**
  `SUPPPORT_GZIPD=FALSE` (retires `ax_gzip`, the last prebuilt x86-64 host
  tool); **#96** the binary cache — Jeremy provides the endpoint, cache name,
  token and public key, and it is the one blocker on a real update; **#88**
  boot logo; **#87** nixosModules split and upstreaming; **#98** the 4096-wide
  capture cap. #86, #83, #85, #89, #91, #99, #100 and #101 are closed;
  **#76/#80/#81/#82 are delivered but still open** — bookkeeping, with the
  residuals in their comments. **#7/#9 (the SD image) now have nothing to build
  on**: #97 deleted the vendor-layout `sd-image`, so an SD story for the NixOS
  appliance is new work, not a fix.
