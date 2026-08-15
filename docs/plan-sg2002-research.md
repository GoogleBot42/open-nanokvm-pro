# NanoKVM (SG2002) — 100% From-Source Nix Flake Rebuild

Status: research complete (2026-07-17), build not yet started.
Decision: **Option (a)** — all components built from source, Sophgo vendor 5.10 kernel,
closed ISP/3A blobs stubbed out (not linked). Not targeting mainline kernel (no VENC
driver) and not linking vendor ISP blobs.

Target hardware: NanoKVM Cube/Lite/PCIe (SG2002, RISC-V C906 @1GHz, 256MB DDR3, microSD).
Official repo cloned at `./NanoKVM`.

## Research verdict

No mandatory binary blob exists on the KVM datapath
(boot → vendor 5.10 kernel → HDMI/LT6911 MIPI capture → VI → VPSS → VENC H.264/MJPEG → Go server → web).
The only true blobs in the stack are the ISP algorithm objects (~273 .o), the 3A
(AE/AWB/AF) libs, and audio DSP objects — all bypassable for KVM because the HDMI
bridge delivers formed YUV (no raw-Bayer ISP needed). scpcom's Buildroot fork proves
dummy-stubbing these works.

Caveats to remember:
- `cvi_mpi` middleware has NO LICENSE file — buildable source, but not clean OSS provenance.
- The whole stack uses T-Head C906 flags: `-mcpu=c906fdv -march=rv64imafdcv0p7xthead
  -mcmodel=medany -mabi=lp64d`, musl libc. Stock nixpkgs GCC lacks xthead/v0.7 vector.
- riscv64 is not on cache.nixos.org — all cross-compiled locally.
- `./NanoKVM` repo's kvmapp binaries are 0-byte placeholders; `server/dl_lib/*.so` are
  convenience blob copies we will NOT use — everything gets rebuilt.

## Source repos (the full bill of materials)

Boot chain (all source, public RISC-V GCC sufficient):
- FSBL incl. open DDR init/training: https://github.com/sophgo/fsbl (branch sg200x-dev)
- OpenSBI fork: https://github.com/sophgo/opensbi
- U-Boot fork: https://github.com/sophgo/u-boot-2021.10 (branch sg200x-dev)
- FIP assembly: `fsbl/plat/cv181x/fiptool.py` (also https://github.com/sophgo/fiptool)
- FIP layout: BL1(ROM) → BLCP(empty.bin for us) → BL2(fsbl) → DDR_PARAM → BLCP_2ND(skip) → OpenSBI fw_dynamic → u-boot-raw

Kernel:
- Vendor 5.10 (required for VENC/VPSS/VI): https://github.com/scpcom/linux branch `licheervnano-merged-5.10.y`
  (upstream: sophgo linux fork; no firmware blobs in drivers/)

Middleware:
- https://github.com/sophgo/cvi_mpi branch sg200x-dev — build VI/VPSS/VENC/SYS from source;
  stub libisp/libisp_algo/libae/libaf/libawb/audio with dummies (see scpcom approach)
- ISP tuning bins (NOT needed for HDMI ingest): https://github.com/scpcom/sophgo-isp_tuning

Sipeed layer (all open):
- Main repo: https://github.com/sipeed/NanoKVM (GPL-3.0): `server/` Go+cgo, `web/` React, `support/sg2002/` C++ (kvm_system, kvm_vision→libkvm.so, kvm_mmf→libkvm_mmf.so)
- Alt source home: https://github.com/sipeed/NanoKVM-System (Apache-2.0)
- Build framework: https://github.com/sipeed/MaixCDK (its `components/3rd_party/sophgo-middleware`
  normally links prebuilt v2/lib/*.so — we replace with our from-source cvi_mpi build)

Prior art / templates:
- The from-source recipe to port: https://github.com/scpcom/LicheeSG-Nano-Build (`build-nanokvm.sh`,
  Buildroot 2025.02, riscv64-gcc-thead toolchain, dummy stubs for closed libs, NanoKVM SD image)
- Official build tree: https://github.com/sipeed/LicheeRV-Nano-Build
- Nix riscv64 image scaffolding: https://github.com/zhaofengli/nixos-riscv64 ,
  https://github.com/nakato/nix-visionfive2-bsp
- Mainline status reference: https://milkv.io/docs/duo/resources/upstream-status

## Build plan (flake outputs, in order)

1. **Toolchain derivation** — T-Head GCC (`riscv64-gcc-thead`, musl). Either package the
   Sophgo/T-Head prebuilt-toolchain *from its GCC source tree*, or test whether
   `pkgsCross.riscv64-musl` + dropping the v0.7 vector ext compiles everything
   (kernel/middleware likely fine; check libkvm perf). 100%-from-source goal says: build
   T-Head GCC from source (github.com/T-head-Semi/xuantie-gnu-toolchain).
2. **Boot chain** — fsbl + opensbi + u-boot derivations → `fip.bin` via fiptool.
3. **Kernel** — vendor 5.10 derivation + `soph_mipi_rx` and vcodec modules; device tree
   for NanoKVM (from LicheeRV-Nano-Build board configs).
4. **Middleware** — cvi_mpi derivation (VI/VPSS/VENC/SYS/…); dummy-stub derivation for
   libisp/lib3A/audio symbols.
5. **libkvm / kvm_system** — build `support/sg2002` via MaixCDK against our middleware
   (may need to un-vendor MaixCDK's prebuilt sophgo-middleware component).
6. **Go server** — `buildGoModule`, CGO with toolchain flags, link our libkvm.so
   (Nix rpath instead of patchelf hack).
7. **Web frontend** — buildNpmPackage/pnpm.
8. **Rootfs + SD image** — assemble partitions (fip.bin at raw offset per
   LicheeRV-Nano-Build layout, boot partition, rootfs with init scripts from
   `NanoKVM/kvmapp/system/`). Skip: Tailscale fork (optional), picoclaw, audio.
9. **Verification** — boot on hardware, confirm HDMI capture + MJPEG/H.264 stream,
   USB HID gadget, web UI.

---

# NanoKVM-Pro (AX630C) — Feasibility Findings (2026-07-17)

Constraint from user: UI doesn't matter (NanoKVM or PiKVM), hardware-accelerated encode required.

## Blob audit summary
- Boot chain 100% source in sipeed/maix_ax620e_sdk: bl1/SPL incl. DDR training C code,
  TF-A 2.7, OP-TEE 3.21, U-Boot 2020.04 (`AX630C_emmc_arm64_k419_sipeed_nanokvm` target),
  Linux 4.19.125 core (sipeed/maix_ax620e_sdk_kernel), Ubuntu arm64 rootfs scripts,
  stock aarch64 GCC. Only boot blob: EIP-130 crypto engine fw byte-array (avoidable).
  UNVERIFIED: whether retail units enforce burned secure-boot keys (test on hardware!).
- All Axera media/NPU IP closed at both layers: prebuilt `ax_{mipi_rx,proton,ivps,venc,jenc,vdec,npu,...}.ko`
  (osdrv/private_drv2kernel has Makefile shims only) + prebuilt `libax_*.so` (msp out/).
  libax_* are BSD-3 licensed binaries — redistributable. .ko modules are GPL-tagged
  (source legally owed). No mainline Axera support, no RE community.
- VENC IP IDENTIFIED = VeriSilicon Hantro VC8000E (verbatim hantrovcmd_*/EWL/HANTRO_IOCG
  strings in ax_venc.ko + libax_venc.so). JPEG=VC9000, VDEC=hx170dec — all Hantro.
  ISP "proton" = Axera in-house AI-ISP (the one genuinely closed block).
  Mainline path exists: Pengutronix 2025 RFC "VC8000E H.264 V4L2 Stateless Encoder"
  (same core as i.MX8MP); DT has venc@4010000 (IRQ 93, vpu_clk, reset, OPP table).
  Open-driver estimate: 1-3 engineer-months for H.264, immature uAPI, H.265 extra.

## Runtime architecture (from dissecting release debs — decisive)
Two-process design, NOT "Go server → libkvm → SDK":
- `kvm_vin` daemon (kvmcomm.deb, stripped, 59 AX symbols: VIN/IVPS/ISP/MIPI/POOL) owns
  the whole capture pipeline (lt6911 HDMI bridge + EDID bins + dummy-sensor inject →
  VIN → proton ISP → IVPS) and publishes frames via /run/kvm/vin_sock + SysV shm
  (protocol undocumented — RE needed).
- `libkvm.so` (NanoKVM Go server) and Sipeed's ustreamer fork (PiKVM deb) are thin VENC
  consumers: identical embedded "axera_venc/axera_link" module, only 18 AX imports
  (14 AX_VENC_* + 4 AX_SYS_Link/Init). libkvm.so.0.1.0 ships UNSTRIPPED in
  nanokvm_pro_<ver>.tar.gz releases. Audio = statically linked ALSA+Opus.
- Sipeed ustreamer fork has `--encoder AX-VIDEO` (+ M2M-VIDEO! suggests a V4L2 M2M
  wrapper of the VENC exists in kernel) and is GPL — AX-VIDEO module source is
  legally requestable from Sipeed.
- IMPORTANT: ISP/proton IS on the datapath even for HDMI YUV (dummy-sensor inject path,
  libsns_dummy + libax_proton linked everywhere). No clean ISP bypass like SG2002.

## ON-DEVICE RECON + TEST RESULTS (2026-07-17, live desktop unit, app v1.2.15, AX SDK V3.0.0_20250319)
- **NO V4L2 NODES AT ALL** (/dev/video* absent, video4linux sysfs empty). Encoder exposed ONLY via
  Axera char devs /dev/ax_venc (VC8000E H264/H265) + /dev/ax_jenc (VC9000 MJPEG) + libax_venc.so
  (AX_VENC_* API). → stock-ustreamer-M2M path is DEAD; must drive AX_VENC_* ourselves (option 2/3).
- Live proof: VC8000E encoding H264+H265 1920x1080@59 VBR 8Mbps from HDMI (input YUYV422), GOP 50.
- Runtime arch on THIS fw: **NanoKVM-Server itself does the encode** (holds /dev/ax_venc+ax_jenc, links
  libkvm.so at /kvmapp/server/dl_lib/, only 14 AX_VENC_* + 4 AX_SYS_* imports). **kvm_vin** (/kvmcomm/vin/)
  does capture (20 AX_VIN + 11 AX_ISP + 11 AX_IVPS + 7 AX_MIPI_RX). Frames flow IVPS→VENC via in-kernel
  AX_SYS_Link + CMM physical-memory pools (NOT dmabuf/socket). /run/kvm/vin_sock = CONTROL plane only
  (res/EDID/start-stop handshake); wire protocol NOT yet decoded.
- HDMI bridge = **lt6911uxc** (not lt6911D), driver = custom GPL lt6911_manage.ko (/kvmcomm/ko/), managed via
  /proc/lt6911_info/*; 6 EDID blobs in /kvmcomm/edid/. NOT a v4l2-subdev.
- Both frameworks installed; NanoKVM ACTIVE, PiKVM (kvmd/ustreamer v6.45 AX-fork/janus/nginx) present but
  DISABLED. Sipeed's ustreamer fork links libax_venc/sys/ivps/proton + drives AX_VENC via AX_SYS_Link —
  the closest existing model for our open glue.
- Services: systemd. kvmcomm.service (supervises kvm_vin+kvm_ui), nanokvm.service (supervises NanoKVM-Server).
  Runtime copies execute from tmpfs /dev/shm/{kvmapp,kvmcomm}, copied at boot from on-disk /kvmapp + /kvmcomm.
- Storage: eMMC mmcblk0 29GB, 17 fixed partitions p1..p17 (spl/ddrinit/atf(A/B)/uboot(A/B)/env/logo/
  optee(A/B)/dtb(A/B)/kernel(A/B)/boot-vfat-128M/rootfs-ext4-p17). A/B redundancy. OP-TEE running
  (tee-supplicant, /dev/tee*). Secure-boot infra present (ATF+OP-TEE+libax_efuse over /dev/mem) but
  **enforcement state UNVERIFIED** (didn't probe efuse). DT codec nodes confirmed: jenc@4000000,
  venc@4010000, vdec@4020000 all status=okay.
- **kvm_vin STOP TEST (done, user-authorized):** `systemctl stop kvmcomm` → kvm_vin gone, vin_sock removed,
  codec .ko stay loaded, /dev/ax_venc persists. NanoKVM-Server survived the stop but nanokvm.service
  CASCADE-restarts when kvmcomm restarts (systemd dependency). `systemctl start kvmcomm` → full clean
  recovery in ~6s, no reboot, no errors, web server HTTP 200. VENC channels are created ON-DEMAND (only
  when a browser views the stream) — absent at idle is normal. OPERATIONAL TAKEAWAY: we can stop/start
  these daemons cleanly via systemd during dev; encoder consumer (server) is restartable and re-handshakes
  vin_sock. Binaries pulled to scratchpad device-recon/: libkvm.so.0.1.0, kvm_vin, ustreamer, libax_{venc,sys,proton}.so.

## ARCHITECTURE DECISION (2026-07-17): own the whole pipeline, no vin_sock RE
vin_sock is Sipeed's PRIVATE seam between their two-process split (shared capture for both
NanoKVM + PiKVM front-ends). We are replacing that design, so we never inherit the seam.
Build our own single-process (or our own IPC) VIN→ISP→IVPS→VENC pipeline against DOCUMENTED
Axera MPI APIs + open sources. NO reverse-engineering of vin_sock. "Reuse kvm_vin" path
DROPPED (it was the only thing that needed protocol RE).

## CAPTURE-INIT SPIKE RESULT (source-only, 2026-07-17) — validates the above
Open sources specify the capture bring-up to ~90%. Full ordered AX_* call sequence drafted
(saved in scratchpad/capture-spike/ analysis). Sources: open GPL lt6911_manage.c (status/EDID/
hotplug only, polled via /proc/lt6911_info — NOT a MIPI configurator), open dummysensor.c
(AE stub, rebuildable — an ISP-framework placeholder, carries no MIPI/format info), Axera VIN +
vin_ivps_venc_rtsp samples (full lifecycle), and headers. Cross-checked vs nm -D of the local
kvm_vin binary — our source-derived sequence uses the identical documented API surface.
- YUV pass-through CONFIRMED supported, raw-ISP NOT forced: AX_SNS_INTF_TYPE_MIPI_YUV +
  eRawType=AX_RT_YUV422 + pipe AX_VIN_PIPE_ISP_BYPASS_MODE/SUB_YUV_MODE + FRAME_SOURCE_ID_YUV.
  DT=0x1E (YUV422-8bit), YUYV order (AX_FORMAT_YUV422_INTERLEAVED_YUYV).
- NO closed datapath blobs: no ISP tuning .bin (kvm_vin never loads one), no AI-ISP .axmodel
  (raw path only, no NPU symbols). Only closed pieces = LT6911UXC on-chip fw (untouched, just
  emits CSI-2) + Axera's documented-API runtime libs (accepted).
- kvm_vin replaceable by ~400-700 lines of C (config structs + create/bind/start lifecycle +
  a /proc/lt6911_info poller for hotplug/resolution). libsns_dummy rebuildable from open source.
- RESIDUAL RISK = 3 MIPI D-PHY numbers NOT in open sources (LT6911UXC emits them from closed fw,
  driver doesn't report them): (1) per-lane data rate [High risk; ~594Mbps/lane computable from
  /proc pixel-clock for 1080p but exact value needs PHY-lock test]; (2) lane count/combo [assume
  4-lane MODE_0]; (3) lane/clk physical routing [SDK sample says {0,1,3,4}/{2,5}; verify vs board].
  All resolved by ONE on-hardware bring-up session watching for D-PHY lock + first
  AX_VIN_GetYuvFrame success. Not a design unknown — a single tuning experiment.

## ENCODER PoC RESULT (on-device, 2026-07-17) — SUCCESS, encode half PROVEN
Standalone C program drove AX630C HW H.264 encoder (VC8000E) end-to-end via documented Axera
MPI, ZERO Sipeed code. Fed synthetic NV12 color-bar → got valid 30-frame H.264 (Main/L5.1
1920x1080, SPS+PPS+IDR+29 P-frames), decoded to PNG = exact input pattern. Working sequence:
AX_SYS_Init → AX_POOL_CreatePool → AX_VENC_Init → AX_VENC_CreateChn(chn7, H264 CBR 8Mbps GOP30)
→ AX_VENC_StartRecvFrame → loop[AX_POOL_GetBlock, fill NV12, AX_VENC_SendFrame, AX_VENC_GetStream,
Release] → teardown. Built NATIVELY on-device (gcc present at /usr/bin/gcc, Ubuntu aarch64):
  gcc venc_poc.c -Iinclude -L/opt/lib -lax_venc -lax_sys -lax_ivps -lax_proton -Wl,-rpath,/opt/lib
QUIRK: libax_venc.so needs -lax_ivps + -lax_proton too (undefined refs otherwise). Headers from
sipeed/maix_ax620e_sdk_msp out/arm64_glibc/include (V3.0.0, matches on-device libs; public
AXERA bsp_sdk only tags v2.0.0 and headers differ — USE THE SIPEED SET). Artifacts in
scratchpad/venc-poc/ (venc_poc.c, build.sh, include/ 56 headers, poc.h264, frame0.png). Ran with
exclusive HW (systemctl stop nanokvm kvmcomm → PoC → start); device restored, HTTP 200.
Device on-device SDK: libax_venc V3.0.0 (Jul 7 2025), libax_sys V3.0.0_20250319. Native gcc exists.

## *** FULL VIDEO PATH PROVEN END-TO-END ON HARDWARE (2026-07-17) ***
Standalone C (documented Axera MPI only, ZERO Sipeed code) captured the REAL HDMI input through
our own MIPI_RX→VIN→ISP-bypass→IVPS→VENC and produced 60-frame H.264 (Main, 1920x1080) of the
actual desktop (decoded frame = genuine screen content, visually confirmed). Device restored
healthy (services active, HTTP 200, clean). Both halves of the video path now DEMONSTRATED.
Deliverables in scratchpad/capture-poc/: capture_venc.c, build.sh, cap.h264, frame30.png.
Build (native on-device gcc):
  gcc capture_venc.c -Iinclude -L/opt/lib -lax_venc -lax_sys -lax_proton -lax_mipi -lax_ivps \
      -Wl,-rpath,/opt/lib -ldl -O2 -o capture_venc

### RESOLVED capture config (read off the LIVE Sipeed stack via /proc/ax_proc/{mipi_rx,vin,isp},
### not guessed — this technique fully retired the "needs a bring-up session" D-PHY risk):
- MIPI: 4-lane, AX_LANE_COMBO_MODE_0, DataLaneMap [0,1,3,4], ClkLane [2,5], **600 Mbps/lane**
  (matches ~594 computed from 1080p59). PhyStatus 0x333307, ErrorCount 0.
- **CORRECTION to capture-spike guesses (which were WRONG on the non-PHY params):** the LT6911
  CSI-2 YUV422 (DT 0x1E) is consumed as **MIPI_RAW / RAW16 / BGGR** (sensor eRawType=RAW16), NOT
  MIPI_YUV/YUYV. Pipe = **ISP_BYPASS_MODE (12)** but only WITH the RAW16 dev; NORMAL_MODE1 and
  SUB_YUV_MODE both delivered 0 frames. Frames emerge at the chn as YUV422 interleaved YUYV
  (fmt 0xD) and go straight into the proven AX_VENC_SendFrame H.264 path (chn 7). Dummy sensor via
  dlopen(libsns_dummy.so); no 3A libs, no tuning bin — matches kvm_vin's imports exactly.
- NOTE: scratchpad/capture-spike/ was found EMPTY by the integration agent; the corrected config
  here (empirically verified against the live stack) is authoritative over the earlier spike report.

### STREAMING DAEMON + libkvm.so ABI (2026-07-17) — video path PRODUCTIZED
- MJPEG-over-HTTP streaming daemon (stream_daemon.c): pipeline init once + capture thread + HTTP
  server. MEASURED live 1080p59, 90s: avg 40.6 fps (min37/max50), latency ~22-26ms capture→encoded,
  CPU ~3% (VC9000 JPEG hw does the work), zero errors, browser-viewable, decoded = real desktop.
  MJPEG via same libax_venc PT_MJPEG (/dev/ax_jenc). Hotplug re-init coded but NOT exercised (source
  stayed 1080p).
- libkvm.so implementing kvm_vision.h ABI (libkvm.c + shared kvm_pipeline.c): harness green.
  MJPEG 30/30; H.264 returns ONE NAL per kvmv_read_img call, correctly classified SPS/PPS/I/P via
  AX pack stNaluInfo[]; set_fps/get_fps, set_gop, set_rate_control(recreates chn), get_sps/pps_frame,
  hdmi_control ok; read_audio = empty stub. DROP-IN READINESS HIGH for video.
  Gaps: audio stub (ALSA+Opus deferred); hdmi_control OFF path untested; resolution taken from live
  /proc geometry (overrides caller w/h — matches real behavior); rate-control recreates chn vs live
  AX_VENC_SetRcParam; not hot-swapped yet. BUILD NOTE: consumers need LD_LIBRARY_PATH=...:/opt/lib
  (RUNPATH misses transitive libax_engine.so).
- Deliverables scratchpad/capture-poc/: kvm_pipeline.{c,h}, stream_daemon.c, libkvm.c, kvm_vision.h,
  kvm_harness.c, build.sh (4 targets, native on-device), daemon_snap.jpg, harness.h264+png.

### CMM teardown — FIXED (2026-07-17) ✅
Root cause: oversized, partly-UNUSED RAW16 pool that couldn't be fully reclaimed. Fix in
kvm_pipeline.c: DROPPED the RAW16 pool entirely (VIN DEV_ONLINE→ISP-bypass streams raw on-chip,
never buffers in DRAM — matches Sipeed's kvm_vin: 1 common pool, no RAW pool); single common pool
sized to YUYV422 output (4147200 B), BlkCnt 12→4, VIN nDepth 4→3, VENC FIFO 4→2; AX_POOL_Exit
return now checked/logged; SIGINT/SIGTERM teardown handlers. Footprint per pool ~87MB → 15.8MB.
ACCEPTANCE PASSED: 3× run→exit→restart cycles, CMM-free IDENTICAL before/after each run (remain=
204360KB, zero leak), kvm_vin first-try stable, HTTPS 200, NO reboot. Tunable: KVM_CHN_DEPTH if a
higher-fps/res source ever starves frames.

### *** INTEGRATION MILESTONE — real NanoKVM-Server streaming through OUR libkvm.so (2026-07-17) ✅ ***
The ACTUAL Sipeed NanoKVM-Server (GPL Go binary) served live video through our open libkvm.so
(our own Axera-MPI capture+encode, zero Sipeed native code). Non-persistent: stopped services,
cp -a /dev/shm/kvmapp → /tmp/openkvm-run, replaced ONLY dl_lib/libkvm.so.0.1.0 with ours, ran real
server from /tmp. PROOF: server log printed our "OPEN-KVM libkvm active" marker + pool line;
/proc/<pid>/maps shows our libkvm + /opt/lib/libax_{engine,venc}.so + libsns_dummy.so loaded;
/api/stream/mjpeg returned 97 JPEG frames (12.3MB), carved frame decoded = genuine live 1080p desktop.
Restored: originals untouched (md5 verified = Sipeed's), /tmp removed, services active, HTTPS 200,
CMM back to idle baseline. AUTH NOTE: device pw is NOT admin/admin (custom bcrypt); CheckToken()
bypasses auth for 127.0.0.1 so on-device curl needed no token (no creds guessed/changed).
=> The whole Pro concept is now PROVEN end-to-end: real product software on our fully-open encoder.

### HDR verdict (Part C investigation) — hardware/SDK limitation, confidence HIGH
User's muted-color-on-HDR observation explained: LT6911UXC forwards BT.2020-PQ YCbCr UNTAGGED (no
colorimetry/AVI-InfoFrame; lt6911_manage.c only tracks signal stable/gone). No tone-mapping exists on
the path — the only CSC prims (IVPS AX_IVPS_CscTdp, VO AX_VO_SetCSC, ISP CscParam) are LINEAR 3x3,
can't invert nonlinear PQ EOTF → can't do BT2020-PQ→BT709. The bypassed ISP is a Bayer-RAW/sensor-WDR
pipeline, doesn't help HDMI PQ. In-pipeline best = AX_VENC_SetVuiParam to TAG stream BT2020/PQ (helps
only HDR-aware downstream; SDR viewer still washed out — tagging ≠ converting).
PRACTICAL FIX (not applied, read-only): advertise SDR-only EDID (drop HDR Static-Metadata block) via
writable /proc/lt6911_info/edid → source sends SDR BT709 which we capture PIXEL-PERFECT. i.e. the KVM
auto-tells the source "I'm SDR" instead of the user manually disabling HDR. (Nuance: Pro also has HDMI
loopout w/ merged EDID — verify SDR-forcing doesn't break a loopout display's needs.) v1 = SDR-correct.

### Open caveats (follow-ups, not blockers):
- "Muted chroma" EXPLAINED by user (2026-07-17): the test HDMI source was outputting **HDR**;
  with HDR off, color is correct. So it's not a code bug — it's an HDR (BT.2020/PQ wide-gamut)
  source being ingested as SDR YUV in ISP-bypass, flattening gamut/transfer. SDR capture is
  pixel-faithful. OPEN QUESTION (user unsure): can the AX630C VIN/ISP capture HDR HDMI correctly
  at all (in bypass we get raw YUV with no tone/gamut handling; a real HDR path may need ISP
  processing we're bypassing, or may be a hardware limitation). Investigate in the daemon phase;
  SDR-correct is sufficient for v1.
- Stride semantics for the bypass YUYV (fmt 0xD, PicStride 1920) not fully pinned, though VENC
  produced a correct image.

## NIX FLAKE SCAFFOLD (2026-07-17) — at /home/googlebot/workspace/nanokvm/nix-nanokvm-pro/
`nix flake check` passes (13 pkgs + devShell). Cross via pkgsCross.aarch64-multiplatform (stock GCC).
REAL BUILDS verified (aarch64 ELF/output): axera-libs (libax_*.so+headers from msp), ax-ko-blobs
(prebuilt ax_*.ko), kvm-encoder (libkvm.so — currently link-STUB, swap in hardened capture_venc.c),
nanokvm-web (Vite dist; pnpmDeps hash pinned), nanokvm-server (aarch64 cgo ELF linking libkvm+opus;
vendorHash pinned). DOCUMENTED STUBS (print real cmds, exit 1): boot-fsbl/atf/optee/uboot, kernel,
rootfs, image. Inputs pinned to main HEAD 2026-07-17 (sdk 45ebcc32, kernel ee5d7959, msp 1bd333bc
[matches on-device V3.0.0], app 8d0557b4).
Cross-cgo traps found+fixed: use crossPkgs.buildGoModule's own cross go (not native go_1_25 → -m64 bug);
SDK Makefiles need CROSS_COMPILE=aarch64-unknown-linux-gnu-. Decisions: rootfs = Ubuntu 22.04 arm64
(Option A, v1; pure-nix deferred); image = .axp(AXDL)+.img, real 17-part layout pulled from SDK
partition_ab.mak into image.nix; bootstrap = run vendor `make ... axp` once then nix-ify.
Follow-ups per heavy deriv: kernel.nix must MATCH vermagic to prebuilt ax_*.ko (vendor defconfig +
compatible GCC, try gcc12→gcc10); boot-* drive SDK build/ (unsigned vs signed = secure-boot efuse
enforcement still UNVERIFIED); rootfs+image assemble.

UPDATE 2026-07-17: kvm-encoder DERIVATION NOW REAL (stub→real). `nix build .#kvm-encoder` produces a
genuine aarch64 libkvm.so.0 (NEEDED libax_venc/sys/proton/mipi/ivps; all 13 kvmv_* ABI symbols
exported), cross-compiled clean first try from snapshot in pkgs/kvm-encoder/src/ (libkvm.c +
kvm_pipeline.{c,h} + kvm_vision.h). nanokvm-server still links it after fix: libax_proton→libax_engine
2nd-level transitive dep needed `-Wl,-rpath-link,${axera-libs}/lib` in CGO_LDFLAGS (vendorHash
unchanged). RUNPATH set via patchelf to "/opt/lib:${axera-libs}/lib" (dontFixup, since nix ld-wrapper
strips /opt/lib). flake check GREEN. RE-SYNC after CMM fix: cp capture-poc/{libkvm.c,kvm_pipeline.c,.h}
→ pkgs/kvm-encoder/src/, git add, nix build. Nothing committed (staged only).

## FROM-SOURCE KERNEL — REAL BUILD + MODULE COMPAT RESOLVED (2026-07-17) ✅
`nix build .#kernel` fully builds Linux 4.19.125 aarch64 from sipeed/maix_ax620e_sdk_kernel:
Image (12.9MB) + AX630C..._sipeed_nanokvm.dtb + vmlinux + 19 modules incl lt6911_manage.ko (in-tree,
CONFIG_LT6911_MANAGE=m). Real nix derivation (gcc13 cross — nixpkgs dropped gcc9-12; MODVERSIONS off
so exact vendor GCC unneeded). defconfig: arch/arm64/configs/axera_AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig.
*** LOAD-BEARING VERDICT: prebuilt ax_*.ko WILL LOAD on our kernel. ***
- vermagic (all 22 blobs identical): "4.19.125 SMP preempt mod_unload aarch64". Our lt6911_manage.ko
  built byte-identical vermagic. => CONFIG_SMP=y, PREEMPT=y, MODULE_UNLOAD=y, release "4.19.125".
- MODVERSIONS = OFF (no __versions section in blobs; defconfig has it unset) => NO per-symbol CRC
  check at load → vermagic-string match SUFFICES, exact vendor .config/GCC NOT required.
- Blobs' AX_OSAL_* imports resolved by vmlinux: CONFIG_AXERA_OSAL=y compiles osal/ into kernel,
  exports 256 AX_OSAL_* in Module.symvers. Standard syms (printk, of_*, param_*) also exported.
SDK build quirks solved (documented in kernel.nix): needs sibling layout <sdk>/{kernel,msp,build} +
make-vars HOME_PATH/PROJECT/LIBC=glibc (drivers/soc/axera reach into msp+build repos); openssl in
nativeBuildInputs (extract-cert); INITRAMFS_SOURCE="" ; bash for scripts/config. Guard added that
fails loudly if a future bump changes vermagic inputs.
CAVEATS for image/boot layer: (1) dtb built directly, BYPASSING vendor patch_reserve_mem.sh — reserved-
memory (atf/optee/cmm/ddr-retrain regions from project.mak) is placeholder; image.nix must run that
patch or supply patched dtb for a correct boot. (2) vendor gzip-compresses+RSA-signs Image+dtb for
KERNEL/DTB partitions — that packaging belongs in image.nix; derivation emits raw Image+.dtb.

## FROM-SOURCE BOOT CHAIN — REAL BUILD + SECURE-BOOT VERDICT (2026-07-17) ✅
`nix build .#boot` builds ALL 4 stages from source (sipeed/maix_ax620e_sdk boot/), all signed:
SPL+DDR-init (bl1, DDR training linked into SPL — p2 ddrinit is empty 1KB BY DESIGN), ATF bl31
(TF-A 2.7 PLAT=ax620e SPD=opteed), OP-TEE bl32 (3.21 axera-ax620e), U-Boot 2020.04 (+FDL2). One
aarch64 linux-gnu cross gcc13 builds everything (fixes: -Wno-error SPL, ld --no-warn-rwx-segments
ATF, python cryptography+shebang OP-TEE, HOSTCC=gcc+/bin/pwd U-Boot). ax_gzip host tool is prebuilt
x86_64 → boot deriv is x86_64-linux-only. pkgs/boot.nix (consolidated, 1 build) + boot-*.nix thin
selectors; flake check GREEN. Outputs in ${boot}/images/ per 17-part A/B layout (offsets: ATF
0x40040000, UBOOT_HDR 0x5C000000, OPTEE 0x44200000, DTB 0x40001000, KERNEL 0x40200000).

*** SECURE-BOOT VERDICT: (A) OPEN — CONFIRMED ON-DEVICE. Flashing self-built firmware feasible. ***
DEFINITIVE (2026-07-17, read-only): read COMM_SYS_BOND_OPT @ phys 0x02340098 (COMM_SYS_GLB 0x02340000
+0x98), the exact bond-option shadow reg U-Boot's is_secure_enable() checks. `devmem 0x02340098 32` =
0x00000000, bit26 (SECURE_BOOT_EN 1<<26) = 0 → NOT enforced. Region validated (neighbor regs non-zero).
Pure MMIO read (devmem no-value-arg), no writes, device left running healthy. So the boot code does NOT
require the fused vendor key; our-key-signed OR unsigned boot chain will boot.
Evidence (bl1/core/boot/boot.c read_image_data): pubkey-hash check AND RSA verify are BOTH gated on
efuse SECURE_BOOT_EN bit (1<<26, secure.c is_secure_enable()). Unburned efuse ⇒ ZERO verification
(boots on header magic 0x55543322 + checksum). efuse_drv.c has READ ONLY, no program path; NO
efuse-burning step anywhere in build/flash flow. imgsign runs unconditionally with COMMITTED dev/test
keys (tools/imgsign/{public,private}.pem RSA-2048 placeholder modulus; aes-256.key = "0"×64;
bl1/aes-256-p-key0 all zeros) → we can regenerate byte-valid signed images. Vendor ships firmware
built with these same repo keys ⇒ enabling secure boot on retail would self-defeat. => not enforced.
If a unit WERE fused to a different key (B), our-key SPL/ATF/OPTEE/UBOOT rejected, only kernel/rootfs
replaceable above the trust break — no in-source evidence of that.
image.nix consumes ${boot}/images/*_signed.bin (spl p1, ddrinit p2 empty, atf p3/4, uboot p5/6,
optee p8/9→copy both A/B) + FDL1/FDL2 host flashing agents. TODO: env partition p7 (default env baked
in U-Boot); re-pin SDK rev to on-device V3.0.0_20250319 tag before trusting byte-identical repro.
SD-boot SPL overflows 50K under gcc13 (irrelevant to eMMC; skipped).

## KEXEC KERNEL TEST #1 (2026-07-17) — safe-recovery VALIDATED; our kernel did NOT boot (cause TBD)
Cross-built static aarch64 kexec-tools (musl, nix), scp'd our nix `Image` + used STOCK dtb (/sys/firmware/fdt)
+ replicated cmdline. `kexec -l` RC=0, `kexec -e`. Our kernel NEVER reached network/SSH. Device auto-recovered
to STOCK via ax_wdt hardware watchdog (~90s timeout, IRQ-mode re-kick, no .shutdown hook so survives kexec) →
cold-boot stock from untouched eMMC, NO manual intervention. *** Safe-test design (no eMMC write + watchdog
dead-man) worked perfectly: failed kernel = ZERO damage, hands-free stock recovery. *** Device healthy after
(21 ax_ modules, kvmcomm+nanokvm active, HTTPS 200). NO eMMC writes ever.
Our build vs stock (both 4.19.125): ours "gcc 13.4.0, #1 1970, nix@nixbuild"; stock "gcc 9.2.1, #2 May-2026".
Stock dtb used → the KERNEL IMAGE is the failing variable. Root cause UNKNOWN (no serial console).
LEADS for next attempt: (1) kexec warned "can't get VA_BITS from kcore" (kcore access-restricted) → likely
WRONG image placement; fix kcore readability or pass VA_BITS. (2) try explicit load addr --mem-min=0x40200000
(vendor KERNEL partition load addr). (3) --reuse-cmdline. (4) CONTROL EXPERIMENT: kexec the STOCK kernel
(extract from p14 kernel_a via read-only dd + de-sign/gunzip) — if stock ALSO fails to kexec → kexec broken on
this SoC (ATF/OPTEE secure-mem handoff), need serial+real flash; if stock kexecs fine → OUR BUILD is the problem
(gcc13/config). (5) possible gcc13 vs vendor 9.2.1 early-boot codegen issue.
NOTE for eventual A/B flash: runtime watchdog recovery does NOT protect a bad FLASH (slot selection persists →
boot-loop unless U-Boot has bootcount A/B fallback — UNVERIFIED). So flashing is riskier than kexec was; verify
U-Boot fallback before any slot switch.

## KEXEC VERDICT — DEAD END on this SoC (control experiment, 2026-07-17)
Extracted the genuine STOCK kernel (read-only dd of p14 kernel partition; de-signed 1024B header magic
0x55543322; decompressed with vendor x86 ax_gzip -d; verified byte-identical version to running stock)
and kexec'd IT with stock dtb + stock cmdline. STOCK KERNEL ALSO FAILS TO KEXEC-BOOT (both default and
--mem-min=0x40200000). Discriminated via timing: warm kexec starts new kernel in ~1-3s; watchdog recovery
= ~90s wdt + ~50s cold boot. Both stock & our kernel landed ~143-147s → watchdog cold-boot, not warm kexec
(corroborated by tmpfs wipe + RTC backward jump). => The KEXEC MECHANISM is broken on AX630C (secure-world
ATF/OP-TEE handoff only the real SPL→U-Boot→ATF flow establishes; kexec bypasses it, re-entered kernel dies
pre-reachable). Leads were red herrings: /proc/kcore doesn't exist (CONFIG_PROC_KCORE off) so the VA_BITS
warning is unavoidable+harmless; load-addr didn't matter. *** Our kernel's viability is UNPROVEN either way
— kexec cannot test it. NOT a build problem. *** No eMMC writes; device healthy on stock.

NEXT: validating our kernel REQUIRES the real boot path (flash to a kernel slot, boot via U-Boot so
ATF/OP-TEE init correctly). SERIAL CONSOLE (ttyS0 @115200, earlycon uart8250 mmio32 0x4880000) is the key
enabler — it shows early-boot output AND gives a U-Boot shell for safe slot-switch recovery (no USB/AXDL
needed). Plan: flash our kernel to kernel_b (p15, inactive slot), keep kernel_a stock as fallback, boot B
via U-Boot with serial watching. User has offered to power-cycle; needs to hook up a USB-UART adapter.

## SLOT-B KERNEL ARTIFACT — READY (2026-07-17)
`nix build .#kernel-slot-image` → kernel_b.bin (6,481,288 B) in EXACT vendor format, ready to flash to
/dev/mmcblk0p15 (kernel_b, slot B). Pipeline (from SDK Makefile.kernel install: SUPPPORT_GZIPD=TRUE):
ax_gzip -9 Image → sec_boot_AX620E_sign.py (-cap 0x54FAFE -key_bit 2048, committed dev key). 1024B header:
magic 0x55543322 @off4, capability @8, img_size(=COMPRESSED payload len) @12, header/payload checksums,
RSA-2048 sig over compressed payload (NOT verified since secure boot off — but header must be well-formed,
and it is by construction). Verified: round-trip (strip 1024 + ax_gzip -d == our Image), ax_gzip codec
confirmed vs stock. Load/exec addr 0x40200000. pkgs/kernel-fip.nix (x86_64-only); flake check green.
Flash cmd (reversible): dd if=kernel_b.bin of=/dev/mmcblk0p15 bs=1M conv=fsync. Slot A (p14) stays stock.
CAVEATS for the flash test: (1) DTB NOT packaged (our dtb lacks reserved-mem patch) → REUSE stock dtb slot
(p12). (2) Our Image 12.96MB < stock 17.61MB — config diff, likely no embedded initramfs (we set
INITRAMFS_SOURCE=""); cmdline uses root=mmcblk0p17 rootwait direct-mount so probably fine, but a possible
early-boot factor to watch on serial.

## SERIAL / A-B / RECOVERY RESEARCH (2026-07-17) — reshapes the flash plan
1. SERIAL UART0 (ttyS0 console @ MMIO 0x4880000, 115200 8N1, earlycon shows SPL/ATF/kernel) PAD LOCATION
   IS UNDOCUMENTED. The labeled rear 5-pin header is UART1/UART2 (user pass-through terminals), NOT the
   console. Finding UART0 needs a BOARD PHOTO or schematic (likely internal/unpopulated test pad). Voltage
   3.3V expected but METER it (AX630C has 3.3V+1.8V domains); never 5V logic. Adapter: any 3.3V USB-UART.
2. NO A/B AUTO-FALLBACK. U-Boot (axera_boot/board.c) boots FIXED slot A (kernel p14/dtb p12). p15/p13 are
   PASSIVE MIRRORS the updater keeps byte-identical (Pro's own firmware_update.sh dd's same file to both).
   CONFIG_SUPPORT_AB almost certainly OFF (not in defconfig; verify on serial via "From slota/slotb boot"
   line). No bootcount/health/rollback. => Safety model = KEEP p14/p12 UNTOUCHED → power-cycle = stock.
   Flashing p15 is SAFE but INERT (U-Boot won't boot it) unless forced. Slot selection = hardware reg
   TOP_CHIPMODE_GLB_BACKUP0 (TOP_CHIPMODE_GLB+0x24) bit2/bit3, re-applied to env `bootsystem` every boot.
   TEST METHODS (need serial + U-Boot prompt; interrupt via any-key during ~2s bootdelay; wdt0 may reset if
   idle at prompt): (a) if SUPPORT_AB ON: flash our kernel→p15, `setenv bootsystem B; axera_boot` (NON-persist,
   power-cycle auto-reverts to A) — SAFEST; (b) if OFF: manual `mmc read` p15 + gzip+booti at prompt, or flash
   slot A directly (riskier, needs AXDL backstop). axera_boot takes NO slot arg (maxargs=1).
3. SECURE-BOOT = the research flagged it "open" but WE ALREADY RESOLVED IT: our devmem read of COMM_SYS_BOND_OPT
   (0x02340098) bit26=0 = NOT enforced (same register U-Boot is_secure_enable() checks). So RSA sig NOT verified
   → our sample-key-signed kernel WILL boot. Triple-confirm on serial: absence of "bondopt secureboot bit is
   enable:1". (IMG_CHECK_ENABLE payload checksum IS always verified regardless — our kernel-fip.nix header is
   well-formed so OK.)
4. AXDL USB RECOVERY (ultimate backstop): remove TF → HID USB-C to host → hold User btn while powering (til
   orange LED flashes) → enumerates VID:PID 32c9:1000 → flash .axp (a ZIP) via AXDL.exe (Win, from Sipeed dl)
   or ciniml/axdl-rs (Linux/Chrome WebUSB, has --exclude-rootfs). Reliable UNLESS GPT touched → NEVER
   re-partition mmcblk0; only `dd ... conv=notrunc` into existing partitions. One brick report (issue #92)
   where button method failed to enter DL mode — not 100% guaranteed. build_image.py repacks .axp with custom
   --dtb/--boot/--uboot (writes BOTH A+B) = Sipeed's intended custom-kernel injection path.
5. Kernel partition format CONFIRMED matches our kernel-fip.nix (1024B header magic 0x55543322 @off4 + ax_gzip
   payload). DTB partition same format; our from-source dtb still needs reserved-mem patch → use stock dtb.

BLOCKING DEPENDENCY: locating the UART0 debug pad (needs user board photo). Serial enables BOTH observing the
boot AND triggering/reverting the slot-B test cleanly. Without serial, any real kernel boot-test risks a
boot-loop recoverable only via AXDL (physical). Present decision to user.

## *** FIRMWARE IMAGE — REAL, FLASHABLE, BUILD VERIFIED E2E (2026-07-18) — CAPSTONE ***
`nix build .#firmware-image` BUILT SUCCESSFULLY end-to-end (exit 0): produced a real 1,423,544,168-byte
(1.42GB) `AX630C_..._sipeed_nanokvm-selfbuilt.axp`, a valid 20-member ZIP. Our from-source members
confirmed present by exact size: boot_signed.bin(+.1)=6,481,288 (our kernel-fip), *_signed.dtb(+.1)=25,160
(our dtb-fip, reserved-mem patched), u-boot_signed.bin/_b=649,688 (our boot.nix), ubuntu_rootfs_sparse.ext4
=4.2GB (our overlay: Ubuntu base + our libkvm.so + merged modules). flake check GREEN. IMAGE-NOTES.txt
in the output documents from-source vs vendor. Store path: c2jgk2am9bfgvzl0z6l6xjqjhbdm8zhl.
NOTE: the .axp DOES contain spl/ddrinit/atf(_b)/optee(_b) as members (still vendor 06-16 copies) → they
ARE swappable by the same streaming-zip member-swap → landing our boot.nix SPL/ATF/OP-TEE is the easy path
(Task in progress).
- DTB GAP CLOSED: pkgs/dtb.nix runs vendor patch_reserve_mem.sh → correct reserved-memory
  (atf 0x40040000/0x40000, optee 0x44200000/0x2000000, optee-tz firmware node, real bootargs
  root=/dev/mmcblk0p17) — VERIFIED via dtc decompile. pkgs/dtb-fip.nix packages it (ax_gzip+sign,
  magic 0x55543322, round-trip OK) → dtb_signed for p12/p13.
- ROOTFS OVERLAY (pkgs/rootfs.nix): base = vendor Ubuntu arm64 ubuntu_rootfs_sparse.ext4 from pinned
  release .axp (pkgs/base-axp.nix, v1.0.15, real sha256). Overlaid WITHOUT root via debugfs -w: our
  libkvm.so → /kvmapp/server/dl_lib/; our /lib/modules/4.19.125 MERGED with prebuilt ax_*.ko (41 mods)
  + re-depmod. Pipeline simg2img→resize2fs +256M→debugfs→img2simg.
- IMAGE (pkgs/image.nix): streaming-zip rewrite of base .axp swapping our dtb(+.1)/kernel boot_signed
  (+.1)/u-boot(+_b)/rootfs; GPT/partition table UNTOUCHED (never repartition = brick risk).
- FROM-SOURCE vs VENDOR in the .axp: FROM SOURCE = dtb, kernel(A/B), U-Boot(A/B), rootfs overlays
  (libkvm.so + kernel modules). VENDOR (from base .axp) = Ubuntu rootfs BASE, SPL, ddrinit, ATF(_b),
  OP-TEE(_b), env, logo, bootfs, partition XML. NOTE: our SPL/ATF/OP-TEE DO build (pkgs/boot.nix, same
  source+keys as vendor so functionally identical) but build_image.py's swap surface doesn't include
  them → landing our own boot-chain binaries needs the deeper raw-partition repack (mkaxp / `make … axp`),
  a follow-up. Full-from-source rootfs (vs vendor Ubuntu base) also a follow-up (user chose overlay-first).
- Caveats: vendor rootfs paths (/kvmapp/server/dl_lib) asserted-not-reinspected vs v1.0.15 (fails loud if
  moved); our modules unstripped (+256M grow; could strip). Files: NEW pkgs/{dtb,dtb-fip,base-axp}.nix;
  rewrote pkgs/{rootfs,image}.nix; edited flake.nix. Staged, NOT committed.

## AUDIO IMPLEMENTED in libkvm (2026-07-18, committed 9f54397)
kvmv_read_audio was a stub → now real, matching stock EXACTLY (from disassembling shipped libkvm.so):
ALSA (libasound) capture from LT6911UXC I2S HDMI-audio PCM (match "Lt6911" desc; S16_LE/2ch/48000/period960)
→ libopus encode (APPLICATION_AUDIO, 128kbps, complexity4, fullband, MUSIC, frame960). Lib-owned persistent
buffer (Go server copies, never frees audio), dedicated mutex, complete teardown in kvmv_deinit. Added
libopus+alsa-lib to kvm-encoder.nix. `nix build .#kvm-encoder` builds (aarch64, NEEDED libopus/libasound).
VALIDATED on device: capture opens w/ exact stock hw_params; encode path proven well-formed (synthetic PCM →
valid Opus → decoded clean tone). No live HDMI audio source now (lt6911 asr=0) so full read leg unproven —
same blocking behavior as stock. RUNTIME NOTE: image needs libopus.so.0 + libasound.so.2 — both present in
vendor Ubuntu rootfs base (overlay OK); for a full-from-source rootfs they'd need staging in /opt/lib.

## CONTROL TEST (2026-07-18) — STOCK kernel ALSO fails from SD → OUR KERNEL EXONERATED; SD BOOT CHAIN is the bug
Swapped STOCK kernel.img (from p14 backup, trim to 1024+img_size, decompress-verified valid ARM64 Image) onto
the card FAT, keeping OUR boot chain (SD-SPL/ATF/OPTEE/U-Boot) + OUR root=mmcblk1p2 dtb. User button-hold boot:
STILL nothing (device down, no network, no new host, black screen). => the KNOWN-GOOD stock kernel also can't
boot through our SD path → the problem is NOT our from-source kernel; it's our SD BOOT CHAIN (from-source
SD-SPL/U-Boot) or the SD image layout/flow. SD boot as constructed = dead end without serial to see where the
SD-SPL/U-Boot dies. Our from-source KERNEL is likely FINE (untestable via SD).
IMPLICATION: to validate our KERNEL, test it through the VENDOR's proven eMMC boot chain (flash our kernel to
eMMC kernel_b/p15, keep vendor SPL/U-Boot) — but eMMC writes + no A/B auto-fallback = AXDL-recovery risk (full
backup exists: fw-backup-20260718/ incl rootfs). OR get serial to debug the SD chain / see any boot. User
signaling SD is a dead end (fair). Device left DOWN after failed control boot — user powers on normally → stock.

## SD BOOT TEST #3 (2026-07-18) — initramfs restored, STILL fails → kernel not reaching userspace → SERIAL NEEDED
Committed initramfs fix (8bc8c72, kernel Image now 17.7MB w/ embedded vendor initramfs, /init byte-identical
to stock). Re-flashed card (per-file verified: kernel.img 8.86MB new sha, dtb root=mmcblk1p2). User button-hold
boot: STILL no IP, black screen. Decisive check (mount SD p2 from stock): mount count STILL 0, last-mount still
Jun15 factory, NOT resized, NO initramfs actions (fstab still /dev/root, no sd_boot.service), no journal. =>
our kernel is NOT reaching the embedded initramfs /init (which runs extremely early). So failure is EARLY-BOOT
(before userspace) OR U-Boot isn't booting our kernel.img at all. Ruled out: root= (fixed), initramfs (restored)
— neither was it. This is invisible from disk (nothing mounts → no logs). *** 3 blind attempts exhausted;
SERIAL CONSOLE now REQUIRED to see the early-boot/U-Boot failure. ***
Possible causes needing serial to distinguish: (a) U-Boot fails to load/boot our kernel.img (format/load addr);
(b) our kernel panics in early init (gcc13 codegen? config? Image head); (c) SD boot flow (our SPL/U-Boot) issue.
OPTIONAL no-serial control test to localize: swap STOCK kernel.img (from p14 backup, trim to header img_size)
onto the card FAT keeping our boot chain + our root=mmcblk1p2 dtb → if stock kernel boots from SD, OUR kernel is
the culprit; if not, the SD boot flow (our SPL/U-Boot) is. One boot cycle, no hardware surgery.
BIG PICTURE: full from-source firmware image BUILDS + video/audio/app all validated on HW (via stock eMMC
running our libkvm). Only the from-source KERNEL BOOT is unproven — the last mile, needs console to debug.

## SD BOOT — DEFINITIVE CONCLUSION (2026-07-18): our SD BOOT CHAIN is broken (NOT card, NOT kernel)
New HIGH-QUALITY 119GiB SDXC card (SDR104), flashed NORMAL-console image (root=mmcblk1p2 + initramfs,
console=ttyS0; boot files hash-verified byte-perfect on card, dtb decompile confirmed). Button-hold boot:
FAILED — no network in ~30min, device down (same as before). => good card ALSO fails. Combined with the
control test (stock kernel also fails from SD), this DEFINITIVELY rules out the card AND our kernel. The
bug is in our FROM-SOURCE SD BOOT CHAIN (SD-SPL / U-Boot / SD-image layout) — the one part reconstructed
from SDK source with NO official Pro SD image to validate against (Sipeed ships eMMC only). root= and
initramfs fixes were real but not the core issue.
BLOCKED ON VISIBILITY: to debug the SD-SPL/U-Boot failure needs serial; the accessible header UART1
(0x4881000) console-redirect WORKS (data floods it) but outputs a NON-STANDARD baud (UART1's clock isn't
set up in the boot chain like UART0's — only UART0 was ever configured by the vendor; stages also differ:
SD-SPL=38400/10MHz, ATF/U-Boot=115200/208MHz), and the user's CH340G only does standard bauds → can't lock
it. Console-redirect committed as ea2631c (sdConsoleUart1 flag). To read it: fix UART1 clock in boot chain
(deep) OR use an FT232 (arbitrary baud) OR find the hidden UART0 pads.
REMAINING PATHS to validate the from-source boot: (a) eMMC test — flash our kernel to eMMC kernel_b via
the VENDOR's proven boot chain (kernel likely fine per control test); eMMC-write/AXDL risk, full backup
exists. (b) FT232 → read UART1 serial → debug SD boot chain. (c) fix UART1 clock so CH340 can read it.
User deciding. Device healthy on stock. Enormous progress: full from-source firmware BUILDS + video/audio/
app validated on HW; only the from-source boot-chain-on-HW unproven.

## SD BOOT TEST #2 (2026-07-18) — root= fix didn't help; INITRAMFS is the likely culprit
After root=/dev/mmcblk1p2 fix + re-flash (per-file verified on card), user did button-hold boot: STILL no
IP, blank screen, then rebooted to stock. Mounted SD p2 from stock again: mount count STILL 0 / no journal /
not resized → our kernel STILL never mounts the SD rootfs. So it's NOT the root= name — kernel can't reach
userspace at all. (Earlier Ethernet link was likely U-Boot, not our kernel.)
DRIVERS ARE FINE (built-in, not the module theory): stock /proc/config.gz shows CONFIG_MMC=y, MMC_BLOCK=y,
MMC_SDHCI=y, MMC_SDHCI_AXERA=y, EXT4_FS=y (no mmc modules at runtime).
*** KEY FINDING: stock defconfig has CONFIG_BLK_DEV_INITRD=y + CONFIG_INITRAMFS_SOURCE=
"../../../../images/initramfs_rootfs.cpio" — the stock kernel EMBEDS a vendor initramfs. Our kernel.nix set
INITRAMFS_SOURCE="" (agent removed it — the cpio wasn't in the nix sandbox). Vendor boot design uses this
initramfs (likely does first-boot resize + root mount/switch_root). Removing it is the prime suspect for our
kernel not reaching userspace. NEXT: investigate what the vendor initramfs /init does (is it required for
root mount?) + rebuild kernel WITH it. IF the initramfs is only optional resize (direct root= should work),
then the failure is elsewhere (kernel-not-booting / mmc1 access) → SERIAL CONSOLE needed to see it.
2 blind attempts done; disk diagnosis exhausted (no logs since rootfs never mounts). Serial console strongly
recommended as next tool if the initramfs fix doesn't work.

## SD BOOT TEST #1 (2026-07-18) — kernel BOOTS, but wrong root= → FIX IDENTIFIED
Wrote sd-image to /dev/mmcblk1 (verified per-file byte-identical; whole-image sha differed only because
stock auto-mounts p1 FAT at /sdcard). User did User-button-hold power-on. RESULT: Ethernet PHY link came
up (switch activity) but NO network/DHCP/SSH, no logo. DIAGNOSIS (via mounting SD p2 from stock, read-only):
SD rootfs p2 NEVER mounted (mount count 0, last-mount Jun15 factory, no journal, not resized). => our boot
chain + KERNEL RAN (Ethernet init is kernel-level) but couldn't mount root → hung before userspace. ROOT
CAUSE: dtb.nix bootargs bake `root=/dev/mmcblk0p17` (eMMC), reused for the SD image → SD kernel told to
mount eMMC not the card's mmcblk1p2. FIX: SD image needs root=/dev/mmcblk1p2. STRONG POSITIVE: from-source
kernel+boot chain demonstrably execute on real hardware; just fed wrong root device. (Backup untouched;
device healthy on stock; SD card still written with the buggy image, to be rewritten after fix.)

## SD-BOOT IMAGE BUILT (2026-07-18, committed 006d73c)
`nix build .#sd-image` → 5.2GB dd-able microSD .img (MBR: p1 128M FAT32 boot [boot.bin SD-SPL +
named component imgs ddrinit/atf/uboot/optee/dtb/kernel] + p2 ext4 rootfs). SD-SPL builds FROM SOURCE
(fixed 248B overflow via -ffunction-sections -fdata-sections --gc-sections → 48460B, guarded).
*** SD BOOT IS STRAP-TRIGGERED, NOT auto card-detect: HOLD `User` button while applying power (release
right after — holding longer = USB download mode) → SD boot; normal power-on → stock eMMC always. ***
Confirmed: Sipeed wiki verbatim + SDK spl_main.c (CHIP_MODE strap / is_sd_boot flag). Non-destructive:
eMMC never written, revert = normal power-on ± pull card. Uncertainty (device-only): whether vendor
U-Boot default env reads kernel.img/dtb.img from SD FAT (cmd/axera/sd_boot exists; assumed).
WORKFLOW: write .img to /dev/mmcblk1 from running device over SSH (single direct conn, of=mmcblk1 NOT
mmcblk0!); user power-cycles holding User → detect our fw via SSH (uname = our nix/gcc13 build).

## PIVOT: SD-BOOT FIRST (2026-07-18, user's idea — non-destructive)
Pro HAS a microSD/TF slot: mmc1 @ 104e0000.sdhc (card-detect polling, currently EMPTY). mmc0=eMMC
(AT3SFB 29GiB), mmc2=SDIO WiFi. Plan: build a dd-able SD image of our from-source firmware; insert →
boots our fw from SD; pull card → boots stock eMMC untouched. ZERO eMMC risk, instant revert. Hinges on
AX630C BootROM booting SD-when-present (strong evidence: SDK has SD-boot SPL variant; AXDL docs say
"remove TF card" before USB-download → card presence changes boot source). KNOWN SNAG: SD-boot SPL
overflows 50K slot under gcc13 (51448>51200) — needs -Os/strip/trim. User granted broad autonomy
("set you loose") — drive SD work autonomously, commit as I go; only stop for physical (write/insert
card) + eventual eMMC write. eMMC slot-B + one-shot-revert-bootcmd plan is the LONG-TERM path (deferred).
Backup of all boot partitions done + verified (scratchpad/fw-backup-20260718/).

## DELIVERABLE STATUS (2026-07-18): flake produces a from-source flashable .axp. Commits: 24b47ce (initial),
## 05a650e (boot chain into image), 9f54397 (audio). firmware-image builds e2e (real 1.42GB .axp). Only
## on-hardware kernel boot remains unproven (parked behind serial access, user's choice). Remaining optional:
## FDL1/FDL2 from-source swap, full-from-source rootfs, live rate-control, SDR-EDID auto-config.

## Pro build options (effort estimates)
1. (SUPERSEDED by recon — no V4L2 M2M node exists.) Was: stock ustreamer --encoder=M2M-VIDEO.
   Reality: must link libax_venc and drive AX_VENC_* directly, as Sipeed's own ustreamer fork does.
2. Pragmatic (~2-4 wk): reuse redistributable kvm_vin binary + write open encoder
   consumer (reconstruct/request AX-VIDEO module; same code serves as open libkvm.so
   for the Go server). Nix flake builds boot+kernel+rootfs+app from source; Axera
   blobs as pinned fixed-output inputs. Hardware accel ✓.
3. Sipeed-binary-free (+8-14 wk): reimplement kvm_vin against blob libax_* libs
   (msp sample/vin_ivps_venc_rtsp covers most; deltas: lt6911 glue, vin_sock protocol,
   dummy-sensor inject tuning). Only Axera BSD-3 blobs remain.
4. Fully blob-free (research project, months+): port mainline VC8000E RFC driver for
   encode; capture would need proton ISP replacement — no open path exists. Not
   currently viable end-to-end.

PRIORITY (user decision 2026-07-17): **Pro first** — user prefers the more powerful Pro
hardware; the SG2002 flake (top half of this file) is deferred, not abandoned.
Axera media libs (libax_*.so + prebuilt .ko) accepted as pinned binary inputs — the goal
is an open, self-built firmware that links them, not a blob-free build.
Hardware available: user has a NanoKVM-Pro **desktop** unit reachable over SSH (no serial).
→ enables on-device recon + the two hardware tests (V4L2-without-kvm_vin, secure-boot)
without a bench serial setup.
Pro path = option 2 now (recreating the AX-VIDEO/libkvm encoder module ourselves —
do NOT count on Sipeed honoring a GPL source request), option 3 as stretch;
revisit option 4 as upstream VC8000E matures.
Analysis artifacts (extracted debs, symbol dumps, DTS) in scratchpad `libkvm-analysis/`
and `venc-analysis/` (session-temporary — re-download from NanoKVM-Pro releases if gone).

## Open questions for build phase
- Does kvm_vision run with ISP stubs on LT6911 HDMI ingest without image-quality
  regressions? (scpcom image suggests yes — inspect its stub set first.)
- Exact SD partition/offset layout for fip.bin (check LicheeRV-Nano-Build `build/` scripts).
- Whether MaixCDK is worth keeping in the loop or `support/sg2002` can be built with a
  plain CMake harness against cvi_mpi headers (less vendored magic, better for Nix).
