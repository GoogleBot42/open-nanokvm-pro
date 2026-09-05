# Replacing the Axera video blobs — findings & test plan

Status: **DONE — a real 1080p YUV frame was captured with ZERO vendor libraries
(Stage 6, 2026-07-21).** Open userspace (libc only; `ldd` = libc) drives the whole
capture path end-to-end: allocator/CMM/pool + MIPI-RX PHY bring-up + VIN
device/pipe/channel/stream + ISP-bypass config + `GetYuvFrame`, then reads the
YUYV out of the CMM pool. The dequeued frame is a live HDMI capture (a Linux
desktop launcher, with an on-screen clock matching the wall-clock time), and it
matches — pixel-for-pixel bar a ~4-min clock delta — a frame read at the same
moment from the Desk unit's untouched **vendor** pipeline (same HDMI via the
splitter). `libax_sys` / `libax_mipi` / `libax_proton` are **demonstrably
replaceable** by an open reimplementation for this capture use case.

The Stage-5 "embedded process pointers" hypothesis was **wrong** and is corrected
in Stage 6: those "pointers" were an artifact of dumping a fixed 512 bytes past
each selector's true (small) `copy_from_user` size. The real pipe/chn/stream
structs are **small pointer-free scalars**; the kernel resolves every object
in-kernel from a `pipe_id` byte, so byte-replay of the captured cfu-prefix is
valid. See the [Test log](#test-log) (Stage 6).

Earlier status (Stages 1–5): capture ioctl ABI recovered; open userspace drove the
allocation/context handshake, MIPI-RX PHY bring-up through START, and the VIN
device layer, all rc=0, no watchdog reboot — the Stage-2 mipi-Start hang was a
fabricated zeroed PHY attr.

This is the working document for the effort to replace the last executing closed
binaries on the NanoKVM Pro: the Axera video capture/encode stack. It records
what the video path actually depends on, the feasibility verdict from a
three-part investigation, and the concrete plan for on-device testing.

---

## State of play (read this first)

**Where we are (2026-07-20):** capture is the first blocker and it is now
*precisely characterized and bounded* — not the open-ended quagmire we feared.
Every cheap, observational probe has been run. The remaining moves are real
commitments, not more experiments.

**What we proved on hardware:**
- The whole video ioctl ABI is a thin uniform selector interface (`_IOWR(magic,
  nr, 8)`). The **capture path = 43 selectors** (7 mipi_rx + 36 proton; `AX_ISP_*`
  and `AX_VIN_*` share the one `/dev/ax_proton` fd), all mapped to their `AX_*`
  call.
- Open userspace (libc only, **zero vendor libs**) successfully drives the raw
  selector *transport* (`AX_MIPI_RX_Init`, `AX_VIN_Init`, … return 0).
- Clock/reset/PLL sequencing is **entirely in-kernel** (userspace footprint: 2
  reads of one word). The ISP register block (`0x2400000`) is **readable** via
  `/dev/mem`; ~140 live registers, and specific registers are attributed to
  specific selectors (e.g. frame geometry `0x2406518 = 0x04380780` = 1080×1920
  written by `AX_VIN_SetDevAttr`).

**The two residual gates (neither is cheap):**
1. **Userspace `.so` replacement** (keep the `.ko`): blocked below the `AX_*` API
   on the closed libs' *private marshaling* — `libax_sys`' CMM/pool allocator +
   shared SYS region, and the per-selector attr structs passed **by pointer**
   (not self-contained scalars). Userspace-recoverable RE, but real RE. Buys
   little license-wise (the `.so` are the permissive BSD-3 part).
2. **Fully-open capture** (replace the `.ko`): needs the in-kernel register
   write-order / RMW / polling for `0x2400000` (ISP) + `0x2600000` (MIPI) plus
   the in-kernel clock-gating. Task B recovered *which* registers and their
   end-values, **not** the sequence. Requires static RE of `ax_proton.ko` /
   `ax_mipi_rx.ko` — multi-week specialist effort.

**Recommended next steps (in priority order):**
1. **`ax_venc.ko` Hantro VCMD characterization** — the highest-leverage next
   move and *independent of capture*. The encoder is confirmed VC8000E over the
   **publicly documented** Hantro VCMD ABI, so its kernel side may be recoverable
   from docs rather than reversed from scratch — the only realistic route to a
   blob-free *encode* path. Start host-side (static analysis of `libax_venc.so` +
   `ax_venc.ko` against the public `hantrovcmd` uAPI and the Exp-1 venc selector
   table), then device-trace.
2. **`.ko` static RE for capture** (`ax_proton`/`ax_mipi_rx`) — the fully-open
   capture path. Large, separable go/no-go; the multi-year fork Stages 1–2 were
   explicitly designed *not* to commit us to. Only if there's appetite for it.
3. Userspace `.so` replacement (RE `libax_sys`' allocator + attr layouts) — of
   value mainly as proof/independence, not licensing.

> The Sipeed GPL-source request is **not** being pursued — decided that Sipeed
> cannot produce the unpublished `.ko` source.

---

- [State of play (read this first)](#state-of-play-read-this-first)
- [Scope: which blobs](#scope-which-blobs)
- [What the video path depends on](#what-the-video-path-depends-on)
- [Key findings](#key-findings)
- [Feasibility verdict](#feasibility-verdict)
- [Test plan](#test-plan)
- [Test rig](#test-rig)
- [Safety rules](#safety-rules)
- [Test log](#test-log)

---

## Scope: which blobs

Video is the largest *executing* blob set left, but not the only closed code —
see `provenance.md` for the full inventory (aic8800 WiFi, `ax_gzip` build tool,
`eip_ax620e.bin`, the vendor base rootfs). This document is
about the **HDMI-capture → H.264/MJPEG-encode path** only.

---

## What the video path depends on

Our open `libkvm.so` (`pkgs/kvm-encoder/src/`) makes exactly **54 documented
`AX_*` API calls**, all declared in shipped SDK headers. The closed code behind
them:

### Userspace `.so` (BSD-3, redistributable)

| Lib | Size | Role |
|---|---|---|
| `libax_proton.so` | 1.67 MB | VIN + ISP (single lib; no separate `libax_vin`) |
| `libax_venc.so` | 794 KB | H.264/H.265/MJPEG encode |
| `libax_sys.so` | 105 KB | SYS + POOL |
| `libax_mipi.so` | 14 KB | MIPI CSI-2 RX (thin shim) |
| `libax_engine.so` + `libax_interpreter.so` | 283 KB | NPU runtime — pulled in transitively by proton, unused by us |

~2.9 MB total. We call **30 of libax_proton's 2,148 exports**, and run VIN in
**ISP-bypass mode** (YUV pass-through from the LT6911UXC — no 3A, no demosaic).
Most of proton is dead code for a KVM.

### Kernel `.ko` (GPL-tagged, source unpublished)

Minimal set for capture→encode is **12 of the 22 vendor-loaded modules**, ~6.4 MB,
dominated by `ax_proton.ko` (4.5 MB). `ax_proton.ko` hard-depends on `ax_npu.ko`,
so the NPU driver is load-bearing for plain capture even though we never run a
network. `ax_venc.ko` is small (126 KB); `ax_jenc.ko` (JPEG) 115 KB.

`/dev` nodes: `/dev/ax_{sys,cmm,pool,sysmap,os_mem,hrtimer,log}`, `/dev/ax_proton`,
`/dev/ax_mipi_rx`, `/dev/ax_venc`, `/dev/ax_jenc`, `/dev/mem`.

### Already open (the scaffolding around the closed core)

`lt6911_manage.ko` (full HDMI front-end driver, from source), the `osal` layer,
all 56 SDK headers, the dummy-sensor source (`component/isp_proton/sensor/dummysensor/`),
~90 SDK samples using our exact APIs, and `drivers/soc/axera/` (non-media).

---

## Key findings

Three parallel investigations (blob static analysis, open-source landscape,
dependency mapping):

1. **The encoder is confirmed VeriSilicon Hantro VC8000E** (VC9000 for JPEG,
   VC8000D for decode). Not inference — `libax_venc.so` contains `VCEncInit`,
   compiled-in `../source/hevc/hevcencapi.c` paths, and the standard
   `HANTRO_IOC*` VCMD ioctls in the clear; `ax_venc.ko` self-describes as
   "VC8000 Vcmd driver" with `hantrovcmd_*` symbols. **The venc kernel ABI is
   the published Hantro VCMD interface** — recoverable without tracing. An open
   V4L2 VC8000E encoder driver is in active development (Pengutronix, i.MX8MP,
   RFC May 2025 — H.264-only, no rate control, unmerged). This is the only
   realistic long-term route to blob-free encode.

2. **The capture side (VIN/ISP) is the real blocker.** `ax_proton.ko` is ~1.3 MB
   of genuine in-kernel ISP code (not firmware — no `request_firmware`), and its
   kernel↔userspace ioctl ABI is **hidden inside the binaries**: the SDK headers
   expose zero `_IOW/_IOR` for the video path. `ax_mipi_rx.ko` (106 KB, no
   algorithms) and `libax_mipi.so` (14 KB shim) look tractable; proton does not.

3. **Nobody else has solved this.** Axera publishes "application layer only";
   `osdrv/private_drv2kernel/` ships only `obj-y` Makefile stubs, no `.c`. M5Stack
   (Module-LLM) and Sipeed MaixCAM2 consume the identical binary drop. No mainline
   AX630C support, no community RE, no OpenIPC interest. **OpenIPC never replaced
   an encoder blob on any SoC** — their model is open userspace shimming vendor
   blobs, which is exactly what our `libkvm` already is.

4. **CPU encode is not a viable primary path.** 2×A53 @ 1.2 GHz ≈ 4–5 fps of
   1080p x264 ultrafast. Every serious open KVM (PiKVM, JetKVM, GLKVM) uses
   hardware encode. Worth keeping only as a degraded dirty-rectangle fallback.

5. **The LT6911UXC front-end is the easy part** — an autonomous chip booting its
   own SPI-flash firmware; our from-source `lt6911_manage.ko` (thin I2C/EDID/IRQ
   shim) is all the SoC side needs. Capture would work as a standard V4L2 CSI-2
   pipeline *if the SoC's CSI-RX had an open driver* — the bridge is not the
   obstacle, the SoC side is.

### Cheap hygiene wins found along the way (issue #30 — resolved 2026-08-16)

- `libax_ivps` **must stay on the link line** despite zero `AX_IVPS_*` calls
  in our code: `libax_venc.so` references `AX_IVPS_AlphaBlendingTdp` /
  `AX_IVPS_CropResizeTdp` (and `AX_VIN_PRIV_FindMeStat` from `libax_proton`)
  as undefined symbols **without declaring the `DT_NEEDED`** — our link is the
  only thing keeping them resolvable in the process. Verified by symbol
  inspection of the shipped `libax_venc.so`.
- `libsns_dummy.so` is now **built from SDK source** (`pkgs/libsns-dummy.nix`
  from `component/isp_proton/sensor/dummysensor/` + shared i2c/common
  sources): 73 KB vs the vendor's 1.3 MB (the difference is AI-ISP glue and
  debug baggage irrelevant to bypass mode). Shipped in the rootfs and the OTA
  payload over the vendor `/opt/lib` copy; device-tested on the closed
  (vendor-MPI) backend — clean dlopen of `gSnsdummyObj`, live MJPEG.
- Only **12 of 22** vendor-loaded modules are needed for video. This is no
  longer future work: since #39 the image ships a **curated loader** in place of
  the vendor `auto_load_all_drv.sh` — see
  [Module curation](#module-curation-12-of-22-issue-39) below.

---

## Module curation (issue #39 → #25)

> **Superseded 2026-09-02 (#55 M3 / #60):** the shipped loader now insmods three
> from-source modules and **no vendor blob at all** — and since #54 (2026-09-03)
> the vendor `ax_*.ko` are deleted from the image, so no rollback loader ships.
> Everything below is history; `ax-load-drv.openvenc.sh` survives only as bench
> tooling for a device flashed with the vendor `.axp`.

The vendor `/soc/scripts/auto_load_all_drv.sh` insmods all 22 `/soc/ko` blobs at
boot. We replace it with a curated loader (`pkgs/rootfs/ax-load-drv.sh`, shipped
by both `pkgs/rootfs.nix` step `[5b7]` and the OTA payload).

**Updated for #25 (2026-08-31, openvenc default):** the loader now loads **11**
modules — the **10-module `{ax_proton}` capture closure** PLUS our from-source
open `ax630c_venc_vcmd.ko` **in place of** the vendor encode blobs `ax_venc` +
`ax_jenc` (which are now REMOVED from the flashed image entirely; see the
"openvenc default" work below). The `ax_venc`/`ax_jenc` rows below are marked
KEEP for the *historical* #39 curation; under #25 they are **dropped** — the
encode path is blob-free. At the time the pristine vendor script also shipped
beside the curated loader as `auto_load_all_drv.sh.vendor`, so a `cp` + reboot
rolled back the **capture** stack; **that stopped being true in #54** — no
rollback copy ships and the blobs are gone, so reverting is a vendor reflash.

Device-proven 2026-08-17: a 13-module boot came up green, `ax_tdp` sat at
refcount 0 *while the encoder was actively streaming*. Historical #39 set was
12 (capture closure + vendor venc/jenc); #25 replaced the two encode blobs with
one open module → 11.

| Module | Verdict | Why |
|---|---|---|
| `ax_sys` | **KEEP** | root of the whole MPI stack; everything else links it |
| `ax_cmm` | **KEEP** | contiguous-memory allocator — *must* get `cmmpool=` |
| `ax_pool` | **KEEP** | frame-buffer pools |
| `ax_base` | **KEEP** | shared MPI plumbing |
| `ax_npu` | **KEEP** | `ax_proton` hard-depends on it (AI-ISP), even with no network loaded |
| `ax_ivps` | **KEEP** | in the closure; also the module behind the `AX_IVPS_*` symbols `libax_venc.so` leaves undeclared (see the hygiene note above) |
| `ax_vpp` | **KEEP** | in the closure (video-processing path under ivps/proton) |
| `ax_gdc` | **KEEP** | in the closure (geometric-distortion block under the same chain) |
| `ax_venc` | ~~KEEP~~ **DROP (#25)** | vendor H.264/H.265 encode — replaced by our open `ax630c_venc_vcmd.ko`; REMOVED from the image |
| `ax_jenc` | ~~KEEP~~ **DROP (#25)** | vendor MJPEG encode — the open path does software JPEG; REMOVED from the image |
| `ax630c_venc_vcmd` (ours) | **KEEP** | from-source open VC8000E encode driver (`/dev/es_venc`), loaded in place of ax_venc/ax_jenc |
| `ax_mipi_rx` | **KEEP** | CSI-2 receiver — the capture front end |
| `ax_proton` | **KEEP** | the ISP/VIN driver (4.5 MB); needs `mem_iq_level=1` |
| `hynitron_touch` | drop | touchscreen; see the udev note below |
| `ax_tdp` | drop | 2D blit engine. Measured refcount 0 during active encode; its only in-tree user was `ax_avs`, also dropped |
| `ax_vo` | drop | video *out* — the SoC display controller. We never output video |
| `ax_fb` | drop | Axera vfb on top of `ax_vo`. The mini panel is `fb_jd9853` from our own kernel |
| `ax_vdec` | drop | decoder; we only encode |
| `ax_mipi_switch` | drop | multi-camera MIPI mux; one source here |
| `ax_audio` | drop | see the ALSA note below |
| `ax_ddr_dfs` | drop | DDR frequency scaling |
| `ax_ive` | drop | classic-CV accelerator, unused |
| `ax_avs` | drop | multi-sensor stitching, unused (and the only `ax_tdp` consumer) |

Three facts that make the drops safe, and are easy to get wrong:

- **`hynitron_touch` still loads anyway.** It is also built from source in our
  kernel and lives in `/usr/lib/modules`, where udev autoloads it from the DT
  match. Touch input therefore survives the curation untouched — what stops
  loading is the 4.78 MB `/soc/ko` blob copy.
- **Same for WiFi.** The `aic8800` drivers are in-tree from-source and
  udev-autoload at ~5 s into boot, so the vendor `/soc/ko/aic8800_*.ko` blobs
  never load on our image either — with or without this change. Only the
  *runtime firmware* blob question remains open (#28).
- **`ax_audio` is not the audio path.** The ALSA card is built into our kernel
  (`simple-audio-card` + `dw-i2s` + a dummy codec) and `libkvm` opens ALSA
  directly. `ax_audio` only provided the MPI audio layer, which nothing in our
  stack calls.

`pkgs/rootfs.nix` byte-compares the base `.axp`'s `auto_load_all_drv.sh` against
`pkgs/rootfs/ax-load-drv.vendor.sh` and **fails the build** if a base bump ever
ships a different loader, so the curated set can never silently drift from the
vendor script it was derived from. Both builds also assert the `ax_cmm
cmmpool=` parameter, `ax_proton mem_iq_level=1`, the insmod count, and the
absence of any `modprobe`/`depmod` (which could resolve `ax_cmm` parameter-less
— the OTA autoload-brick failure mode; see `pkgs/rootfs.nix` step `[4]`).

At this point the blobs themselves stayed on disk in `/soc/ko`: the curation
changed what *loads*, not what ships. **#54 (2026-09-03) closed that gap** —
every vendor `.ko` in `/soc/ko` (plus the `aic8800_*`/`hynitron_touch` copies
named above) is deleted from the image, `wifi.sh` `modprobe`s by name instead of
insmod'ing by path, and `ax-load-drv.vendor.sh` remains in-repo purely as the
byte-compare pin.

---

## Feasibility verdict

| Strategy | Verdict |
|---|---|
| **Full register-level RE of everything** | **Not viable.** No hardware *encoder* has ever been fully RE'd to production quality without vendor docs; rate control is the wall even for funded specialists (Bootlin/Pengutronix); mainline has no stateless-encode uAPI until ~2026; and the SoC has no mainline support underneath. Multi-engineer-year, likely "fixed-QP demo" endpoint. |
| **Replace encoder via Hantro lineage** | **Real technical foothold, long horizon.** `ax_venc.ko` is small, its ABI is published Hantro VCMD, and open VC8000E code exists to build on. ~6–18 month specialist effort; unknowns are Axera's clock/reset/CMM glue + rate control. Solves venc only. |
| **Open userspace over the recovered ioctl ABI (keep `.ko`)** | **The proven playbook — and we're already most of the way there.** Our `libkvm` is exactly this. Going deeper (open userspace speaking `/dev/ax_*` ioctls directly, dropping the closed libs) is feasible but buys little: the libs are the *permissively-licensed* part; the GPL-problem `.ko` remain either way. |
| **GPL source request to Sipeed** | **Cheap, worth firing, don't plan around it.** `.ko` are GPL-tagged and `obj-y` stubs prove in-kernel derivation → unusually clean compliance case. But no request against this class of vendor has ever produced media-driver source. One email. |
| **CPU encode** | **Not credible as primary** (see finding 4). Degraded fallback only. |

**Bottom line:** the current architecture — open everything above the line, link
the BSD-3 libs, pin the GPL-tagged `.ko` as vendor blobs — is the same trade-off
OpenIPC converged on after a decade of this exact problem. A full replacement is
a multi-engineer-year project with no successful precedent. **But** the encoder
being a confirmed VC8000E means the capture side is the first thing to actually
*test*, because it determines whether an open capture path is a bounded job or an
ISP-fabric quagmire.

---

## Test plan

The lever that makes this testable: **we own the userspace end of the wire.** An
instrumented `libkvm`/`kvm_pipeline` can log every ioctl its 54 API calls
generate — command word, decoded direction/size, argument struct before and
after the syscall — turning the "hidden ABI" problem into a data-collection
problem. Staged, with go/no-go gates:

### Stage 1 — ABI recovery (near-zero risk)

Run the instrumented pipeline on a test unit; capture the full ioctl trace for
`/dev/ax_mipi_rx`, `/dev/ax_proton`, `/dev/ax_cmm`, `/dev/ax_pool`, `/dev/ax_sys`,
`/dev/ax_venc` across a matrix of resolutions/formats. The splitter rig (same
source into both units) gives the second unit as live ground truth.
**Deliverable:** documented wire ABI for the capture path in ISP-bypass mode.

### Stage 2 — open userspace replay

A small C program speaking the recovered ioctls directly — no `libax_mipi`,
`libax_proton`, or `libax_sys` — brings up CSI-RX + VIN bypass and pulls YUV
frames, verified frame-by-frame against the blob path.
**Go/no-go gate:** if the proton ioctl surface for plain bypass capture is small
(plausible, since the ISP is excluded), the userspace `libax_proton` becomes
replaceable. If bypass still drags in ISP/3A state we can't reconstruct, we learn
that here, cheaply.

### Stage 3 — the kernel module (separate, much larger decision)

Even with open userspace, `ax_proton.ko` / `ax_mipi_rx.ko` / `ax_cmm.ko` remain.
Stages 1–2 tell us *whether* the register-level RE here is bounded or a quagmire.
This is the real fork in the road and is **not** committed to by running 1–2.

**Immediate objective:** run Stages 1–2 end to end, report either a working
open-userspace capture or a precise reason it's stuck.

---

## Test rig

- **Source:** a separate computer's HDMI output.
- **Splitter:** fans that one source to **both** NanoKVM Pro units → true A/B,
  identical frames into each.
- **Units** (both run our from-source image, both link the Axera blobs — the blob
  path is exactly what we trace):
  - ATX version — `192.168.0.221`
  - Desk version — `192.168.0.224`
- SSH as `root` (default password `sipeed` on the from-source image).

One unit runs the instrumented/experimental code; the other serves as the
untouched reference for frame-by-frame comparison.

---

## Safety rules

An OTA module-autoload bug bricked a device once (see `provenance.md` and the
`ota-modules-autoload-brick` memory). Therefore:

- **All experimental code runs from `/tmp`** — `insmod` / `LD_PRELOAD` /
  `LD_LIBRARY_PATH` against throwaway builds. **Never** touch the flashed image or
  the module tree.
- **Back up boot/eMMC partitions first** (procedure in `flashing-and-recovery.md`).
- Nothing here should require a reflash; worst case is a hang cleared by a
  power-cycle.
- Do the risky work on **one** unit; keep the other as a known-good reference and
  recovery reference.

---

## Test log

### 2026-07-20 — Stage 1 ABI recovery on the ATX unit (192.168.0.221)

**Setup.** Both units reachable over SSH (`root`/`sipeed`). ATX = experimental,
Desk (`.224`) left untouched. `/tmp` is **tmpfs** on the device, so every
artifact below (shim `.so`, harness, trace logs) lives in `/tmp/axwork` and a
reboot wipes it — nothing touches the flashed image, module tree, or any init
file. Boot partitions p1–p16 of the ATX unit were dumped to
`~/nanokvm-backups/atx-221/` first (all gzip-verified); the 30 GB rootfs is
recoverable from a stock `.axp` reflash so it was skipped. On-device `gcc 11.4`
means the tooling was **compiled natively on the target** — no cross-compile.

**Method.** An `LD_PRELOAD` shim (`axtrace.c`) wraps `open/openat/close`,
`ioctl`, and `mmap`. It maps each fd back to its `/dev/ax_*` path and, for every
ioctl, logs the decoded `_IOC` dir/type/nr/size plus a hexdump of the 8-byte
argument before and after the call; `mmap` on `/dev/mem` fds is logged with
physical offset + length. A tiny harness (`harness.c`) `dlopen`s the real
shipped `libkvm.so` and calls `kvmv_read_img`, driving the exact production
capture→encode pipeline (`kvm_pipeline.c`, the ~54 documented `AX_*` calls) in
ISP-bypass mode. The `nanokvm` service was stopped for each run (so only the
harness owned the video hardware) and restarted after — fully reversible, no
reboot needed. Runs covered H.264 and MJPEG at 1920×1080. Artifacts saved to
`~/nanokvm-backups/atx-221/traces/`.

**Result 0 — the from-source pipeline works.** The harness captured and encoded
real frames from the live HDMI source: H.264 SPS(32 B)+PPS(8 B)+IDR(~16.6 KB)+P
(~7–9 KB) and MJPEG (~61 KB/frame). This is the blob path (our open `libkvm`
over the Axera `.so`/`.ko`), so the traces below are the real wire ABI.

**Result 1 — the video kernel ABI is a thin, uniform selector interface.**
*Every* AX ioctl is `_IOWR(magic, nr, 8)` (a handful are `_IO(magic, nr)` with
no arg). The 8-byte argument is **inline data** — two `u32` scalars (e.g. the VB
pool block count `{4,0}`), a `-1`/`0xffff…` sentinel, or a **physical/CMM
address** — *not* a pointer to a big attribute struct. (A shim pass that chased
any pointer-looking arg via `/proc/self/mem` found only stack return-addresses
into code, confirming the args are scalars.) The big SDK structs
(`AX_VIN_DEV_ATTR_T`, etc.) never cross the ioctl boundary as-is; libax_proton
decomposes them. Per-device magic:

| Device | magic | distinct selectors | role |
|---|---|---|---|
| `/dev/ax_mipi_rx` | `'m'` 0x6d | **7** | CSI-2 RX bring-up |
| `/dev/ax_proton` | `'p'` 0x70 | **36** | VIN + ISP (bypass) |
| `/dev/ax_venc` | `'k'` 0x6b | 20 | H.264/H.265 (Hantro VCMD) |
| `/dev/ax_jenc` | `'k'` 0x6b | 19 | MJPEG |
| `/dev/ax_cmm` | `'p'` 0x70 | 10 | contiguous-memory allocator |
| `/dev/ax_pool` | `'p'` 0x70 | 6 | VB pool |
| `/dev/ax_hrtimer` | `'u'` 0x75 | 1 | frame/DMA-done wait (1145 calls — pure runtime timing) |
| `/dev/ax_sys`, `/dev/ax_os_mem` | `'p'`,`'O'` | 1 each | base init |

Total ≈ **101 distinct selectors** for the *whole* capture→encode path; the
capture half (mipi_rx + proton = **43**) is bounded and enumerable, not the
"ISP fabric of thousands" the pre-test verdict feared. Full lists with cmd
words and sample payloads are in `traces/trace_h264_1080.log` /
`trace_mjpeg_1080.log`. Bring-up is clean (one benign AX-level return code
mid-init, `errno=0`); the entire bring-up is a single burst (trace lines 6–647),
later iterations are just per-frame capture+encode.

**Result 2 — where the capture hardware is actually programmed (the important
one).** The `/dev/mem` mmap footprint over a full run is *only*:

- `0x2340000` len 768 — **clock-enable + reset** controller
  (`common_clk`/`comm_sys_reset@2340000` in the DTB), mapped once per dev/pipe.
- `0x2250000` len 8 — a **PLL** status/config reg (`pllc_clk@2210000` region).
- `0x6c…–0x74…` — **CMM buffers**: 4 147 200-byte blocks = exactly 1920×1080×2
  (YUYV frames) + ~2 MB NV12-ish blocks + 4 KB pool-metadata pages, all inside
  the `0x70000000–0x737fffff` reserved carveout.

Userspace **never maps the ISP (`isp@0x2400000`) or MIPI-RX
(`mipi_rx@0x2600000`) register blocks.** Cross-checked against `/proc/iomem`:
the *encoder* blocks (`ax_jenc@0x4000000`, `vsi_vcx@0x4010000` = VeriSilicon
VC8000E, `hx170dec0@0x4020000` = Hantro decoder) **are** kernel-claimed MMIO,
but the ISP/MIPI bases are **not** claimed there either. `devmem 0x2400000`
reads a live value (`0x40`); `0x2600000` reads the `0xDEADBEEF` bus-poison once
clock-gated after teardown — both are real peripherals.

**Interpretation.** The capture hardware register programming lives **inside the
kernel** (`ax_proton.ko` for ISP/VIN @0x2400000, `ax_mipi_rx.ko` for MIPI
@0x2600000), driven by the small scalar ioctls. Userspace (libax_proton /
libax_sys) does only: clock/reset sequencing (`/dev/mem @0x2340000`), PLL status
reads, CMM/pool buffer management, and marshaling → scalar ioctls. The encoder
half is the published Hantro VCMD interface over kernel-claimed MMIO, as the
static analysis predicted.

**Refined feasibility verdict.**

- **Open *userspace* capture lib (keep the `.ko`): now shown bounded and the ABI
  is recovered.** The userspace→kernel contract is the 43-selector capture table
  above (8-byte scalar args) + the `0x2340000` clock/reset block + the CMM/pool
  ioctls. A from-scratch `libax_proton`/`libax_mipi` replacement speaking these
  directly is a finite job. (Caveat, unchanged from the static analysis: the
  `.so` are the *permissively-licensed* part, so this removes little license
  risk — the GPL-tagged `.ko` remain.)
- **Fully open capture (replace `ax_proton.ko`/`ax_mipi_rx.ko`): still the
  quagmire, and now we know *why* precisely.** The ISP/VIN/MIPI **register-level
  programming is in-kernel and invisible to userspace tracing** — the scalar
  ioctls don't reveal it, and the register blocks are never mmap'd out. Recovering
  it needs either static RE of the 4.5 MB `ax_proton.ko` or the AX630C ISP/CSI
  register spec. This is the real gate, unchanged, but now isolated to exactly
  two register blocks (`0x2400000`, `0x2600000`) rather than a vague "ISP fabric."

**Concrete next experiments (not yet run).**
1. *Per-call selector map:* rebuild `kvm_pipeline` with a marker ioctl between
   each `AX_*` call (needs SDK headers copied to the device) to pin every proton
   `nr` to its exact `AX_VIN_*`/`AX_ISP_*` caller. Current traces already give
   the device-level and bring-up-order correlation.
2. *Clock/reset RE (bounded):* `mprotect`-trap the `0x2340000` mapping (768 B) +
   SIGSEGV handler to capture the exact clock-enable/reset write sequence — this
   part *is* in userspace and fully recoverable.
3. *ISP register-diff (the hard part, from userspace):* map `0x2400000` /
   `0x2600000` read-only via `/dev/mem` and snapshot the register block before/
   after each proton/mipi ioctl to reverse which registers each selector touches
   — a way to chip at the in-kernel register map without disassembling the `.ko`.

**Tooling** (all in `~/nanokvm-backups/atx-221/traces/`): `axtrace.c`
(LD_PRELOAD ioctl/mmap logger, env `AXTRACE_OUT/FOLLOW/DEREF/MAX/ALL`),
`harness.c` (dlopen-libkvm pipeline driver), and the three trace logs.

### 2026-07-20 — Stage 1 follow-ups: per-call map, clock-trap, ISP diff (ATX .221)

All three queued experiments ran on the ATX unit (`.221`); Desk (`.224`) left
untouched. Same safety envelope as before: everything in `/tmp/axwork` (tmpfs),
`nanokvm.service` stopped for each run and restarted after (verified **HTTPS 200**,
`NanoKVM-Server` live). One clean **reboot** was used to get a cold-boot cold-clock
state (power-cycle-equivalent, nothing persistent touched). New tooling saved
alongside Stage 1: `ax_marker.c/.so` (per-`AX_*` ENTER/LEAVE markers + read-only
ISP/MIPI `/dev/mem` snapshots) and `ax_clocktrap.c/.so` (mprotect write/read trap
with an AArch64 load/store decode+emulate handler, self-test-validated). Trace
artifacts: `exp13/` (marker log + 7 lifecycle snapshots) and `exp2/`
(`clocktrap_cold.log`, `clocktrap_rw.log`, `markers_rw.log`).

**Method for Exp 1/3.** Rather than rebuild `libkvm`, a second LD_PRELOAD shim
(`ax_marker.so`) interposes each of the 54 `AX_*` API symbols: it writes a
`>>> AXCALL <name>` / `<<< AXCALL <name> ret=` marker into the *same* log
`axtrace.so` writes, then forwards the call (8-long AAPCS trampoline — every
`AX_*` arg is a handle/pointer, none struct-by-value/float, so faithful). Result:
every `/dev/ax_*` ioctl burst is bracketed by the exact `AX_*` that emitted it.
The same shim snapshots the ISP (`0x2400000`) and MIPI (`0x2600000`) blocks
read-only at seven lifecycle points (Exp 3).

#### Experiment 1 — per-selector → `AX_*` map (capture side; ISP-bypass, 1080p)

The capture half is exactly **43 selectors** (7 `mipi_rx` + 36 `proton`), matching
Stage 1. Every one is now attributed to its originating `AX_*` call. All carry the
8-byte inline arg = **two `u32` scalars** (device/pipe/chn id + small config, e.g.
`GetYuvFrame` nr101 `{0,0x18}`); a few pass a CMM/phys or low-32 pointer handle
(e.g. `SetLaneCombo` nr8). `_IO` selectors (mipi nr0/1, pool nr20/21) take no arg.

| dev | nr | cmd word | originating `AX_*` |
|---|---|---|---|
| mipi_rx | 0 | `0x00006d00` | `AX_MIPI_RX_Init` |
| mipi_rx | 1 | `0x00006d01` | `AX_MIPI_RX_DeInit` |
| mipi_rx | 2 | `0xc0086d02` | `AX_MIPI_RX_SetAttr` |
| mipi_rx | 4 | `0xc0086d04` | `AX_MIPI_RX_Reset` |
| mipi_rx | 6 | `0xc0086d06` | `AX_MIPI_RX_Start` |
| mipi_rx | 7 | `0xc0086d07` | `AX_MIPI_RX_Stop` |
| mipi_rx | 8 | `0xc0086d08` | `AX_MIPI_RX_SetLaneCombo` |
| proton | 0 | `0xc0087000` | `AX_VIN_Init` |
| proton | 1 | `0xc0087001` | `AX_VIN_Deinit` |
| proton | 2 | `0xc0087002` | `AX_VIN_Init` |
| proton | 12 | `0xc008700c` | `AX_VIN_Init` |
| proton | 17 | `0xc0087011` | `AX_VIN_CreateDev` |
| proton | 18 | `0xc0087012` | `AX_VIN_DestroyDev` |
| proton | 19 | `0xc0087013` | `AX_VIN_EnableDev` |
| proton | 20 | `0xc0087014` | `AX_VIN_DisableDev` |
| proton | 21 | `0xc0087015` | `AX_VIN_SetDevAttr`, `AX_VIN_SetDevBindMipi` |
| proton | 22 | `0xc0087016` | `AX_VIN_SetDevBindMipi` |
| proton | 30 | `0xc008701e` | `AX_VIN_SetDevBindPipe` |
| proton | 35 | `0xc0087023` | `AX_VIN_CreatePipe` |
| proton | 36 | `0xc0087024` | `AX_VIN_DestroyPipe` |
| proton | 38 | `0xc0087026` | `AX_VIN_StartPipe` |
| proton | 39 | `0xc0087027` | `AX_VIN_StopPipe` |
| proton | 40 | `0xc0087028` | `AX_VIN_StartPipe` |
| proton | 41 | `0xc0087029` | `AX_VIN_StopPipe` |
| proton | 42 | `0xc008702a` | `AX_VIN_SetPipeAttr` |
| proton | 43 | `0xc008702b` | `AX_VIN_SetPipeAttr`, `AX_ISP_Create`, `AX_ISP_Open` (generic attr setter) |
| proton | 48 | `0xc0087030` | `AX_VIN_SetChnAttr` |
| proton | 53 | `0xc0087035` | `AX_ISP_Open` |
| proton | 54 | `0xc0087036` | `AX_ISP_Open` |
| proton | 55 | `0xc0087037` | `AX_VIN_EnableChn`, `AX_VIN_DisableChn` |
| proton | 56 | `0xc0087038` | `AX_ISP_Create` |
| proton | 69 | `0xc0087045` | `AX_ISP_StreamOn` / `GetYuvFrame` / `StreamOff` / `DisableDev` (runtime) |
| proton | 70 | `0xc0087046` | (same runtime group) |
| proton | 74 | `0xc008704a` | `AX_ISP_Open` |
| proton | 89 | `0xc0087059` | `AX_ISP_Open` |
| proton | 101 | `0xc0087065` | `AX_VIN_GetYuvFrame` |
| proton | 104 | `0xc0087068` | `AX_VIN_ReleaseYuvFrame` |
| proton | 109 | `0xc008706d` | `AX_VIN_EnableDev` / StreamOn / GetYuvFrame / StreamOff / DisableDev (frame poll) |
| proton | 138 | `0xc008708a` | `AX_VIN_Init` |
| proton | 139 | `0xc008708b` | `AX_VIN_Deinit` |
| proton | 158 | `0xc008709e` | `AX_ISP_Open` / StreamOn / GetYuvFrame / StreamOff / DisableDev |
| proton | 160 | `0xc00870a0` | `AX_ISP_Create` |
| proton | 163 | `0xc00870a3` | `AX_ISP_Destroy` |

Key structural reads: (a) `AX_ISP_*` and `AX_VIN_*` share one `/dev/ax_proton`
fd and a single `nr` namespace — the "ISP" API is not a separate driver, it is
more proton selectors. (b) In **ISP-bypass** the runtime frame loop is only
nr69/70/101/104/109/158 (+ `hrtimer` nr1 wait); everything else is one-shot
bring-up/teardown. (c) `nr43` is a reused generic "set-attr" selector (VIN pipe
attr *and* ISP create/open). Full before/after payload hexdumps per call are in
`exp13/exp13.log`.

#### Experiment 2 — clock/reset/PLL is **not** touched by userspace

`ax_clocktrap.so` mmap-interposes the two userspace-mapped MMIO windows
(`0x2340000` clk/reset, `0x2210000–0x2270000` PLL), `mprotect`s them, and a
SIGSEGV handler decodes+emulates each trapped AArch64 load/store (STR/LDR/STUR/
LDUR, 32/64-bit) so the access completes and the trap re-arms. A start-up
self-test (trap a store *and* a load on an anon page) reports **store=PASS
load=PASS**, and `mprotect_ret=0` confirms the protection actually takes on the
`/dev/mem` device VMAs.

- **Warm** run and, decisively, a **cold** run *immediately after reboot* (at
  which point `devmem 0x2600000` and `0x2400000` both read `0xDEADBEEF` — fully
  clock-gated) as the **first video consumer since boot**: the harness brings the
  pipeline up (frames captured/encoded) with **zero writes** to `0x2340000` or the
  PLL.
- Full read+write trap (`CLKTRAP_MODE=none`) shows the **entire** userspace
  footprint on these blocks for a whole bring-up is **2 reads** of one 64-bit word
  at `0x2340220` (value `0x4`) and **no writes at all**. The PLL page is mapped but
  never accessed in the bypass path.

**This corrects the Stage 1 interpretation.** Userspace does *not* do clock/reset
sequencing via `/dev/mem @0x2340000` — it maps the block and reads a single status
word. **All** clock-enable, reset de-assert and PLL programming for MIPI/ISP is
done **in-kernel** by `ax_proton.ko`/`ax_mipi_rx.ko`, triggered by the bring-up
ioctls (the MIPI sub-blocks visibly un-gate — `0xDEADBEEF`→live — during
`AX_VIN_CreateDev`; see Exp 3). So the clock/reset step, previously filed under
"userspace-recoverable," moves to the **in-kernel, needs-RE** side of the ledger.

#### Experiment 3 — ISP register block **is** readable via `/dev/mem`; per-lifecycle diff

Both blocks were fully readable read-only over `/dev/mem` for the entire 64 KB
window snapshotted — **no bus fault, the SoC does not block the ISP range** (the
SIGBUS guard never fired). Snapshots at 7 points (`00_start` → `06_after_streamoff`)
diffed:

| transition | ISP regs changed | notes |
|---|---|---|
| start → CreateDev | ~83 ISP (+ ~2048 MIPI un-gating from `0xDEADBEEF`) | bulk ISP core config, block `0x2406xxx`; MIPI clocks enabled here |
| CreateDev → CreatePipe | 20 ISP + 3 MIPI | pipe geometry — `0x2406518` = `0x04380780` (**0x438=1080 h, 0x780=1920 w**) |
| CreatePipe → StartPipe | 3 ISP + 4 MIPI | link enable; MIPI status regs (`…104`) toggle |
| StartPipe → StreamOn | ~38 ISP + 3 MIPI | VIN/DMA path in `0x2400xxx` (per-channel mirrored triplets) |
| StreamOn → capture | 7 | free-running counters tick (`0x24001bc`, `0x240650c`, `0x240105c`) |
| capture → StreamOff | 5 | counters only |

The decisive finding: **the in-kernel ISP register map is partly observable
read-only.** Across the whole bring-up only **~140 ISP registers** carry non-zero
state and a bounded, enumerable set changes at each transition — not the "ISP
fabric of thousands" the pre-test verdict feared. Directly legible already:
frame-geometry (`0x2406518`), the MIPI PHY/link config+status band
(`0x2600048/60/104`, `0x2601048/104`), and several frame/line counters. What the
snapshot diff does **not** give: intra-transition **write order**, read-modify-write
logic, polling, and which of the `CreateDev` block are control regs vs
coefficient/LUT tables — that still needs `.ko` RE or the AX630C ISP/CSI spec.

#### Updated read on the fully-open-capture gate

Recoverable now by observation, no disassembly:
- The **entire capture userspace↔kernel ioctl contract** — 43 selectors, each
  mapped to its `AX_*` and to `{u32,u32}`/handle arg semantics (Exp 1). An open
  `libax_proton`/`libax_mipi` over the kept `.ko` is a finite, spec'd job.
- That the clock/reset/PLL block needs **nothing** from a userspace rewrite (Exp 2):
  it's 2 status reads.
- A **bounded, read-only-observable** ISP/MIPI register surface (~140 live regs)
  with per-lifecycle deltas and several registers already identified (Exp 3).

Still gated on `.ko` RE (or a register spec), and now isolated precisely:
- The **in-kernel register *write sequence*** for `0x2400000`/`0x2600000` — Exp 3
  gives before/after *values* at coarse lifecycle points but not order/RMW/polling.
- The **in-kernel clock/reset/PLL sequence** — Exp 2 moved this here from
  Stage 1's userspace column; it is emphatically not in userspace.

Net: the gate did not get smaller in *kind* (replacing the `.ko` still needs RE),
but it got much better *bounded and characterized* — a ~140-register observable
ISP surface + a 43-selector ioctl contract + a known clock-gating trigger point,
versus Stage 1's "invisible in-kernel fabric." The clock/reset finding is a
genuine correction, not a refinement.

**Tooling added** (in `~/nanokvm-backups/atx-221/traces/`): `ax_marker.c/.so`
(per-`AX_*` markers + ISP/MIPI `/dev/mem` snapshots; env `AXTRACE_OUT`,`AXSNAP_DIR`),
`ax_clocktrap.c/.so` (write/read mprotect-trap + AArch64 ld/st emulator; env
`CLKTRAP_OUT`,`CLKTRAP_MODE=none`). Data: `exp13/` (marker log + 7 snapshots),
`exp2/` (cold + read/write clock traces).

### 2026-07-20 — Stage 2: open-userspace replay + per-selector ISP diff (ATX .221)

Both Stage-2 tasks ran on the ATX unit (`.221`); Desk (`.224`) untouched. Same
safety envelope (all in `/tmp` tmpfs; `nanokvm.service` stopped per run and
restarted after — verified **active + HTTPS 200** at the end). New tooling saved
to `traces/stage2/`: `ax_ispdiff.c/.so` (LD_PRELOAD ioctl hook that snapshots the
ISP `0x2400000` + MIPI `0x2600000` blocks read-only via `/dev/mem` **before and
after every individual proton/mipi_rx ioctl** and logs the exact 32-bit words
that changed, attributed to that selector — Task B) and `capreplay.c` (standalone
probe that links **no** vendor libs — `ldd` shows only libc — and issues the
recovered selectors directly on the raw char devices — Task A). Data:
`stage2/ispdiff.log`, `stage2/capreplay.log`.

#### Correction to the Stage-1 "8-byte inline scalar" reading

Re-examining the `exp13.log` hexdumps closely: the 8-byte ioctl arg is inline,
but for most **configuration** selectors those 8 bytes are **a 64-bit pointer to
a private attr struct**, not a self-contained `{u32,u32}`. Examples:
`AX_MIPI_RX_SetLaneCombo` nr8 payload `…d0dba2d4` and `AX_VIN_StartPipe`
nr38/40 payload `…d4ffff00` are stack addresses (`0xffffd4a2xxxx`, the same range
as the arg pointers); `AX_VIN_Init` nr138 payload `0x74846000` and the
`AX_SYS_Init` os_mem/sys selectors carry a **physical / CMM handle**. The Stage-1
DEREF pass that "found only stack return-addresses" was in fact looking straight
at these on-stack attr structs. So the true capture ABI is: *43 selector entry
points, each taking an 8-byte arg that is either an id pair, a userspace pointer
to a private struct, or a phys/CMM handle produced by libax_sys.* The pointed-to
struct layouts are internal to `libax_mipi`/`libax_proton`/`libax_sys` and do
**not** appear on the wire.

#### Task A — open-userspace capture replay (`capreplay`, zero vendor libs)

`capreplay` opened `/dev/ax_{os_mem,sys,cmm,pool,mipi_rx,proton}` directly and
replayed the recovered bring-up. Results (full log in `stage2/capreplay.log`):

- **The raw ioctl transport works from open userspace.** With **no** vendor libs
  linked, `AX_MIPI_RX_Init` (mipi nr0), `AX_VIN_Init` (proton nr0 `{3,3}`),
  proton nr12/nr2, and mipi `SetAttr`/`Reset`/`SetLaneCombo` (nr2/4/8, with a
  valid zeroed struct pointer) all returned **rc=0**. The recovered selector
  interface is real and drivable directly.
- **But bring-up cannot be completed without the closed libs' memory + marshaling
  layer.** The CMM/POOL selectors reject our calls (`cmm nr10` EINVAL, `nr17`
  EFAULT, `nr0` ENOMEM, `nr6` EPERM; `pool nr22/20` return AX error codes
  `0x8006xxxx`) because they expect the private request-struct/shared-region setup
  that `AX_SYS_Init`/`libax_sys` performs. The three phys-handle selectors
  (os_mem nr1, sys nr45, proton nr138) cannot be driven at all without libax_sys'
  internal allocator producing the handle — we refused to fabricate a physical
  address (kernel would `ioremap`/deref it).
- **Hard stop:** issuing `AX_MIPI_RX_Start` (mipi nr6) against an unconfigured
  (zeroed) PHY struct **hung the vendor `.ko` and tripped the kernel watchdog →
  board rebooted**. This is the anticipated "hang cleared by power-cycle" case:
  the unit came back clean (tmpfs, nothing persisted; `nanokvm.service`
  auto-restarted, HTTPS 200). It also directly demonstrates the coupling — the
  MIPI/VIN drivers assume the PHY/lane/geometry state the closed libs install and
  fault hard without it.

**Verdict on Task A's go/no-go gate.** Capturing a valid YUV frame from pure open
userspace (no libax_proton/mipi/sys) **did not succeed and is precisely blocked**,
not on the ioctl surface (that is recovered and works) but on the **private
userspace marshaling the closed libs perform below the AX_* API**: (a) the
`libax_sys` CMM/pool allocator + the shared SYS management region whose phys is
handed to proton (nr138) and whose layout carries the persistent attr structs,
and (b) the per-selector private attr struct layouts (lane combo, dev/pipe/chn
attr, ISP config) that travel as pointers, not as the public SDK structs. These
are **userspace-recoverable** (they live in the `.so`, not the `.ko`) but require
static RE of libax_sys/libax_proton's marshaling — this is *not* mechanical
replay of the 43 selectors. So: the userspace `.so` are replaceable **in
principle**, but the residual work is "RE the private struct/shared-region
layouts," a bounded RE job, rather than "the 43 selectors are sufficient."

#### Task B — per-selector ISP/MIPI register diff (read-only)

`ax_ispdiff.so` rode a normal blob-path capture (real H.264 frames encoded:
IDR ~16.6 KB) and diffed the ISP/MIPI blocks around **each** of 146 proton/mipi
ioctls. Attribution (counter reg `0x0240643c`, which ticks on ~half of all
ioctls, excluded as noise; the block-power transitions are annotated, not counted
as writes):

| selector (`AX_*`) | dev nr | ISP/MIPI registers programmed |
|---|---|---|
| `AX_VIN_Init` | proton 0 | **block power-on**: whole ISP+MIPI window transitions `0xDEADBEEF`→live (clock un-gate, in-kernel; not discrete writes) |
| `AX_VIN_CreateDev` | proton 17 | 82 ISP regs — bulk core config, geometry band `0x2406xxx`; sets `0x2406518=0x01000100` (default), `0x2406520/28/2c` |
| `AX_VIN_SetDevAttr` | proton 21 | 20 ISP regs — **writes the frame geometry**: `0x2406518: 0x01000100 → 0x04380780` (0x438=1080 h, 0x780=1920 w), plus `0x2406504=1`, `0x240650c` |
| `AX_VIN_SetDevBindPipe/Mipi` | proton 30/22 | `0x2406448`, `0x240650c` + MIPI link regs |
| `AX_MIPI_RX_Reset` | mipi 4 | 8 MIPI PHY regs (`0x260x048/100` lane band) |
| `AX_MIPI_RX_Start` | mipi 6 | 28 MIPI regs — PHY/link enable (`0x2600000–0x2601118`) |
| `AX_VIN_EnableDev` | proton 19 | 29 ISP regs in the `0x2400xxx` VIN/DMA datapath band |
| runtime loop | proton 69/70/109 | `0x2400xxx` DMA/status regs + free-running counters (`0x24001bc`, `0x240105c`) tick per frame |
| `AX_VIN_GetYuvFrame` | proton 101 | `0x2400160/168`, `0x24001bc` (frame-done handshake) |
| `AX_MIPI_RX_Stop` | mipi 7 | 2048 MIPI regs (block re-gate live→`0xDEADBEEF`) |

Decisive result: **the frame-geometry write is now pinned to a single selector** —
`AX_VIN_SetDevAttr` (proton nr21) writes `0x2406518 = 0x04380780`. The MIPI PHY
bring-up is a bounded ~28-register set programmed by mipi nr4+nr6; the VIN/DMA
datapath is `0x2400xxx`, programmed by proton nr19 and cycled by the runtime
loop. This is a concrete selector→register map for the in-kernel writes, obtained
with zero disassembly and pure read-only `/dev/mem` access.

#### Updated Stage-2 read on the two open questions

- **(a) Are the userspace `.so` now proven replaceable?** *Necessary transport
  yes; sufficiency no — with a bounded residual.* The 43-selector ioctl surface is
  recovered and directly drivable from open userspace, but a working replacement
  must also reimplement what the closed libs do *below* the AX_* API: libax_sys'
  CMM/pool allocator + shared SYS management region, and the private per-selector
  attr struct layouts passed by pointer. That is a real (userspace-side) RE task,
  not covered by "43 selectors observed." Downgrades the Exp-1 "finite, spec'd
  job" claim: the selectors are spec'd, their *pointed-to structs* are not.
- **(b) What is the residual gate to fully-open capture (needs `.ko` RE)?**
  Unchanged and now better-mapped: the in-kernel register **write sequence** for
  `0x2400000`/`0x2600000`. Task B attributes *which* registers each selector
  programs and their end values (geometry, PHY band, DMA band), but still not the
  intra-selector write order / RMW / polling, nor the clock-gating sequence
  (Exp 2 showed that is entirely in-kernel). Replacing `ax_proton.ko`/
  `ax_mipi_rx.ko` still needs static RE or the AX630C ISP/CSI register spec.

#### Durable rc log — `capreplay_safe` (Start-gated re-run)

The original Task A run above never produced a clean pulled-from-device log: the
final selector, `AX_MIPI_RX_Start` (mipi nr6) against a zeroed PHY struct, hung
the vendor `.ko` and tripped the watchdog → reboot **mid-run**, so the
per-selector rc table was reconstructed from terminal scrollback, not a saved
log. To harden the record, `capreplay_safe.c` (a copy of `capreplay.c` that
marks `AX_MIPI_RX_Start` **and the two selectors observed downstream of it**
— `AX_VIN_CreateDev` proton nr17, `AX_VIN_SetDevAttr` proton nr21 — as `GATED`,
i.e. logged but **never issued**) was built natively on-device (`gcc -O2`, `ldd`
= libc only) and run from `/tmp/axwork` with `nanokvm.service` stopped. It ran
to completion (exit 0, **no hang, no reboot** — uptime unbroken across the run);
service restarted and verified **active + HTTPS 200** after.

The durable log is `~/nanokvm-backups/atx-221/traces/stage2/capreplay_safe.log`
(pulled off tmpfs to the workstation backup dir — that path is persistent; the
device `/tmp/axwork` copy is tmpfs and does not survive reboot). **The
per-selector rc table it records is byte-for-byte identical to the
reconstructed-from-scrollback version above** — pool nr22 `rc=-2146762486`
(0x8006xxxx AX err) / nr20 `-2146762472`; mipi nr0 `rc=0`; cmm nr10 `EINVAL`
×2 / nr17 `EFAULT` / nr0 `ENOMEM` / nr6 `EPERM`; proton nr0 `rc=0 {3,3}` / nr12
`rc=0` / nr2 `rc=0 {4,1}`; mipi nr8/nr2/nr4 all `rc=0`; the PHYS handles (osmem
nr1, sys nr45, proton nr138) skipped as before. No rc changed; the table is now
backed by a real on-device log rather than scrollback.

**Tooling added** (`~/nanokvm-backups/atx-221/traces/stage2/`): `ax_ispdiff.c/.so`
(per-ioctl read-only ISP/MIPI register diff; env `ISPDIFF_OUT`), `capreplay.c`
(no-vendor-lib selector replay probe), `capreplay_safe.c` (Start-gated variant).
Data: `stage2/ispdiff.log`, `stage2/capreplay.log`, `stage2/capreplay_safe.log`.

### 2026-07-20 — Encoder (ax_venc) characterization — host-side static + web

**Scope/safety.** Pure host-side work: static analysis of the shipped
`libax_venc.so`, `ax_venc.ko`, `ax_jenc.ko`, the AX630C device tree in the kernel
source, and the SDK venc headers, cross-referenced against the public Hantro
VC8000E source landscape via web research. **No device was touched** (the ATX unit
is in use by another effort); the device-tracing experiments proposed at the end
are for a later, separately-scheduled phase. Binaries analysed:
`…yq0pw7iz…-axera-libs-3.0.0-msp/lib/libax_venc.so` (794 KB, stripped, aarch64);
`…gzmk3ygv…-source/osdrv/out/arm64_glibc_linux-4.19.125/ko/{ax_venc.ko,ax_jenc.ko}`
(unstripped). Both stamped `V3.0.0_20250319114413`.

#### Headline: encode is materially MORE tractable than capture

The pre-test verdict's optimism is confirmed **and sharpened, with one real
caveat**. The venc kernel side is a lightly-patched port of the *publicly
published* Hantro VCMD driver; its clock/reset/power is **standard, open,
in-tree** DT plumbing (the exact opposite of the capture side's opaque in-kernel
clock sequencing); and the whole userspace VCEnc+EWL encoder library is
**statically linked into `libax_venc.so`** and legible in the clear. The single
real gap is licensing, not knowledge: the userspace VCEnc **rate-control core**
(where our CBR lives) is **not published under any reusable licence** by anyone —
it ships prebuilt or under NXP's EULA. So "blob-free encode" is a *bounded port*
of open kernel + open EWL glue **plus** either an EULA-encumbered userspace core,
a from-scratch rate controller, or fixed-QP.

#### 1. `libax_venc.so` is stock VeriSilicon VC8000E (VCEnc) + EWL, statically linked

`nm -D` shows the lib exports **only the 55 `AX_VENC_*`/`AX_JENC_*` symbols**;
`DT_NEEDED` is just `libax_sys.so`, libpthread, libm, libc — i.e. **no separate
Hantro `.so`; the entire VC8000E control software + EWL is compiled in.** Strings
prove it is the genuine article, not a re-implementation:

- Compiled-in source paths: `../source/hevc/hevcencapi.c` (multiple lines).
- The full VCEnc API is present by name (~50 `VCEnc*` tokens): `VCEncInit`,
  `VCEncCheckCfg`, `VCEncSetCodingCtrl`, `VCEncSetRateCtrl`/`VCEncGetRateCtrl`,
  `VCEncInitRc`, `VCEncSetPreProcessing`, `VCEncStrmStart`/`VCEncStrmEncode`/
  `VCEncStrmEnd`/`VCEncStrmGetOutput`/`VCEncStrmWaitReady`, `VCEncChangeResolution`,
  `VCEncRelease`/`VCEncShutdown`, the HRD/VUI SPS helpers, etc. It advertises
  H.264/HEVC and carries (HW-disabled) AV1/VP9 checks — i.e. a recent VC8000E SW
  drop, not a cut-down fork.
- JPEG (`ax_jenc`) is the same lib: `JpegEncInit`/`JpegEncEncode`/`JpegEncGetRateCtrl`
  + a full **EWL** wrapper renamed `AXJENCEWL*`.
- **EWL ("Encoder Wrapper Layer") is present verbatim**: `EWLInit`, `EWLReadAsicID`,
  `EWLReadAsicConfig`, `EWLReadReg`/`EWLWriteCoreReg`, `EWLMallocLinear`/`EWLFreeLinear`,
  `EWLReserveHw`/`EWLReserveCmdbuf`/`EWLLinkRunCmdbuf`/`EWLWaitCmdbuf`/`EWLReleaseCmdbuf`,
  `EWLGetVcmdParameters`, `EWLSetVCMDMode`, `EWLReadVcmdPriority`. This is the
  **VCMD-mode EWL** (`vcx_cwl_t` instance struct; "cwl" = Axera's rename of EWL,
  matching the `vsi_vcx@0x4010000` block name). Axera's only userspace change is
  retargeting `EWLMallocLinear` onto its own allocator — the imports show EWL
  pulling `AX_SYS_MemAlloc`/`AX_SYS_Mmap`/`AX_POOL_*`/`AX_SYS_Mflush/Minvalidate
  Cache` from `libax_sys` (the CMM/pool allocator + cache ops), i.e. the **same
  libax_sys marshaling seam the capture side hit**, but here it is isolated to the
  one EWL memory file, not spread across dozens of attr structs.

#### 2. `AX_VENC_*` → VCEnc → VCMD-ioctl mapping (our 11 calls)

Our pipeline (`kvm_pipeline.c`) makes 11 distinct `AX_VENC_*` calls. Internally
`libax_venc.so` is a thin channel/threading manager over the stock VCEnc API,
which drives the hardware through EWL → the `HANTRO_IOC*` VCMD ioctls on
`/dev/ax_venc` (magic `'k'` 0x6b, matching Exp-1's 20 venc selectors). The
`HANTRO_IOC*` names are **in the clear** in the binary:
`HANTRO_IOCH_GET_VCMD_PARAMETER`, `HANTRO_IOCH_GET_CMDBUF_PARAMETER`,
`HANTRO_IOCH_GET_MMU_ENABLE`, `HANTRO_IOCG_CORE_WAIT`, `HANTRO_IOCG_ANYCORE_WAIT`,
`HANTRO_IOCH_SELECT_OUTFIFO_LEN_INC`/`_DEC`.

| our `AX_VENC_*` | VCEnc / EWL internal | VCMD kernel op (`/dev/ax_venc`) |
|---|---|---|
| `AX_VENC_Init` (mod) | process/EWL bring-up; `EWLInit` → mmap regs, `EWLReadAsicID`/`ReadAsicConfig`, `EWLGetVcmdParameters` | open + `HANTRO_IOCH_GET_VCMD_PARAMETER`, `GET_CMDBUF_PARAMETER`, `GET_MMU_ENABLE`, mmap of the vcmd cmdbuf/status/register pools |
| `AX_VENC_CreateChn` | `VCEncInit` + `VCEncCheckCfg` + `VCEncSetCodingCtrl` + `VCEncSetPreProcessing`; allocate ref/recon frames via `EWLMallocLinear`/`EWLMallocRefFrm` | `EWLMallocLinear` → `AX_SYS_MemAlloc`/CMM (not a VCMD ioctl); no HW touch yet |
| `AX_VENC_StartRecvFrame` | arms the channel recv thread | none (userspace state) |
| `AX_VENC_SendFrame` | `VCEncStrmStart` (first) then `VCEncStrmEncode`; EWL builds a VCMD command buffer and submits it | `EWLReserveCmdbuf` → `EWLLinkRunCmdbuf` (link+run), HW kicked via the cmdbuf; `EWLWriteCoreReg`/`ReadReg` for register program/readback |
| `AX_VENC_GetStream` | `VCEncStrmWaitReady`/`VCEncStrmGetOutput` — waits for the core, returns one NAL/pack | `HANTRO_IOCG_CORE_WAIT` / `HANTRO_IOCG_ANYCORE_WAIT` (block on IRQ), then read output regs |
| `AX_VENC_ReleaseStream` | returns the output buffer | `EWLReleaseCmdbuf` (recycle the cmdbuf slot) |
| `AX_VENC_GetRcParam`/`SetRcParam` | `VCEncGetRateCtrl`/`VCEncSetRateCtrl` (+ Axera's `AXRc*` wrapper, below) | none (pure userspace RC state; applied on next encode) |
| `AX_VENC_StopRecvFrame` | quiesce recv thread | none |
| `AX_VENC_DestroyChn` | `VCEncRelease`; free ref/recon | `EWLFreeLinear`/`FreeRefFrm` → CMM free |
| `AX_VENC_Deinit` (mod) | `EWLRelease`/`VCEncShutdown` | close `/dev/ax_venc`, unmap pools |

**Rate control specifically (our CBR path).** `libkvm` sets
`AX_VENC_RC_MODE_H264CBR` with `AX_VENC_H264_CBR_T` (gop, bitRate, min/max QP,
min/max I-QP, Iprop, IdrQpDeltaRange). The lib maps this onto stock VCEnc RC:
debug strings expose the exact `VCEncRateCtrl` field set being driven —
`"…vbr %d qp %2d qpRange I[%2d,%2d] PB[%2d,%2d] %9d bps  pic %d skip %d  hrd %d
cpbSize %d bitrateWindow %d intraQpDelta %2d fixedIntraQp %2d…"` — i.e. Axera's
CBR is a thin wrapper over `VCEncSetRateCtrl`. There is **one Axera-authored layer
on top** (`AXRcInitRcModel`, plus `AVBR`/`CVBR`/`QVBR` modes the stock lib may not
have shipped) — a proprietary adaptive-RC shim — but the base CBR/VBR is the
standard VC8000E `rateControl` block.

#### 3. `ax_venc.ko` / `ax_jenc.ko` are the public Hantro VCMD driver (OSAL-wrapped)

`.modinfo`: `ax_venc` = **"VC8000 Vcmd driver"**, `ax_jenc` = **"VC9000 Vcmd
driver"**, both `license=GPL`, `author=Axera`. The symbol table and log strings
are near-verbatim public `hantro_vcmd.c`:

- Core symbols: `hantrovcmd_ioctl`, `hantrovcmd_fops`, `hantrovcmd_isr`,
  `hantrovcmd_mmap`, `hantrovcmd_open/poll/release`, `vcmd_link_cmdbuf`,
  `vcmd_delink_rm_cmdbuf`, `vcmd_manager`, `vcmd_core_array`, `total_vcmd_core_num`,
  `vcmd_buf_mem_pool`/`vcmd_status_buf_mem_pool`/`vcmd_registers_mem_pool`,
  `abort_queue_vcmd`, `wait_queue_vcmd`, `asicVcmdRegisterDesc`.
- Log strings identical to upstream: `"hantrovcmd_isr: received IRQ!"`,
  `"too long before vcmd core to IDLE state"`, `HWIF_VCMD_IRQ_{ABORT,BUSERR,
  CMDERR,RESET,TIMEOUT}`, `"create cmdbuf data when hw_version_id = 0x%x"`, and
  the platform-device tag **`vsi_vcx`** (= the `/proc/iomem` `vsi_vcx@0x4010000`
  block). `hw_version_id` self-describes → the register program is version-gated
  exactly as upstream.
- Axera's changes are a thin **OSAL** shim, not algorithm changes: `AX_OSAL_DEV_*`
  wrappers for `platform_driver_register`, `ioremap_nocache`, `devm_clk_get`,
  `clk_prepare_enable`/`set_rate`, `devm_reset_control_get_optional`,
  `reset_control_assert/deassert`; `ax_os_mem_{vmalloc,kzalloc}` + a
  `vcmd_arm_dma_init` for the DMA-coherent cmdbuf/status/register pools. The
  driver allocates **only** the small VCMD command/status/register pools; all
  frame/ref buffers come from userspace CMM (§1). No `request_firmware`.

**ABI divergence from public Hantro: minimal.** Same magic (`'k'`), same
`HANTRO_IOC*` command set the userspace uses, same VCMD command-buffer model,
same `asicVcmdRegisterDesc` register-descriptor table. The published driver that
matches Axera's *VCMD* variant (not the older `hx280enc` reserve/IRQ variant) is
`vc8000_vcmd_driver.c` — see §5. Net: the venc kernel↔user contract is
**recoverable from public source without device tracing**, unlike the capture
ioctl surface which had to be traced.

#### 4. Clock/reset/power for venc is OPEN and standard (the big contrast with capture)

The AX630C DT (`arch/arm64/boot/dts/axera/AX620E.dtsi`, pulled into the nanokvm
`AX630C_fastemmc_arm64_k419.dtsi`) fully describes the block:

```
venc: venc@4010000 {
    compatible = "axera, venc-encoder";
    reg = <0x0 0x4010000 0x0 0x10000>;
    clocks = <&vpu_clk AX620X_CLK_VENC_EB>;   clock-names = "venc_clk";
    interrupts = <GIC_SPI 93 IRQ_TYPE_LEVEL_HIGH>;
    resets = <&vpu_reset_async 7 0x11C 7 0x120 0x8 7 0x114 7 0x118 7>;
    operating-points-v2 = <&venc_dfs>;
};
jenc: jenc@4000000 { … clocks = <&vpu_clk AX620X_CLK_JENC_EB>; interrupts = <GIC_SPI 91 …>; };
```

Crucially, **the providers are open, in-tree drivers**: the clock gate
`AX620X_CLK_VENC_EB` = `"clk_venc_eb"` (parent `clk_vpu_glb_sel`, gate reg 0x8
bit 7) is defined in `drivers/clk/axera/clk-ax620e.c`; the reset comes from
`drivers/reset/axera_reset/axera_reset.c`; DVFS via the open `venc_dfs` OPP table.
`ax_venc.ko` consumes them through the **standard Linux clk/reset framework**
(`devm_clk_get` + `clk_prepare_enable` + `reset_control_deassert`, via the OSAL
shim; the module even has `ax_venc_clk_{suspend,resume,get_freq}`). **This means
venc clock/reset/power needs NO reverse engineering** — a from-source driver
enables it with documented, open mechanisms. This is the sharpest divergence from
capture, where Exp 2 proved the ISP/MIPI clock sequencing is opaque and buried in
`ax_proton.ko`/`ax_mipi_rx.ko`.

The `private_drv2kernel/vcodec/{video_encoder,jpeg_encoder}/Makefile` ship the
usual `obj-y += ax_venc.o` / `ax_jenc.o` **stubs with no `.c`** — the GPL source
is unpublished, same as the rest of the tree (clean GPL-compliance posture, but
no source to ask for that we can't already reconstruct).

#### 5. Public VC8000E source landscape + licences (web research)

Kernel VCMD driver — **openly published, GPL/dual, matches Axera's variant**:
- **revyos/vpu-vc8000e-kernel** (T-Head TH1520): `linux/kernel_module/vc8000_vcmd_driver.c`,
  `vc8000_normal_driver.c`, `vc8000_driver.c/.h`, `vcmdswhwregisters.c/.h`,
  `vcmdregisterenum.h`, `vcmdregistertable.h`, `hantro_mmu.c`, `vc8000_axife.c`.
  Header licence: **dual MIT + GPL-2.0**, "COPYRIGHT (C) 2019 VERISILICON".
  Mirrors: `XUANTIE-RV/vpu-vc8000e-kernel`, `thead-yocto-mirror/vpu-vc8000e-kernel`.
- **eswincomputing/linux-stable** (branch `linux-6.6.18-EIC7X`, EIC7700):
  `drivers/staging/media/eswin/venc/vc8000_vcmd_driver.c` — SPDX `GPL-2.0` + the
  dual MIT/GPL VeriSilicon block. The cleanest, most modern in-tree copy.
- **nxp-imx/linux-imx** `drivers/mxc/hantro_vc8000e/hx280enc_vc8000e.c` + `hx280enc.h`
  (i.MX8MP) — `MODULE_LICENSE("GPL")`, magic **`'k'`**, but this is the older
  **`hx280enc` reserve/IRQ** variant (`HX280ENC_IOC*`), *not* the VCMD driver
  Axera uses. Useful as a second reference; not the closest match.
  (raw: `…/lf-6.6.y/drivers/mxc/hantro_vc8000e/hx280enc.h`.)
- Mainline `drivers/media/platform/verisilicon/` has **no VC8000E encoder** — only
  `hantro_h1_jpeg_enc.c` (the old H1 JPEG). No H.264/HEVC hw-encode is upstream.

Userspace VCEnc control software (hevcencapi/EWL + **rate control**) — **NOT
reusably licensed anywhere**:
- **NXP `imx-vpu-hantro-vc`** contains the real `hevcencapi.c` + EWL + RC source,
  but under **NXP proprietary EULA**, **not on GitHub** — tarball only
  (mirror: `http://sources.buildroot.net/imx-vpu-hantro-vc/`; meta-freescale ships
  only the recipe). License-incompatible with an open image.
- **VeriSilicon/VPE** publishes VC8000**E** encoder **headers only**
  (`sdk_inc/VC8000E/software/inc/hevcencapi.h`, `ewl.h`, `encswhwregisters.h`,
  `jpegencapi.h`) + **prebuilt** `libh2enc.so`/`libcwl.so` (BSD-3 only for the thin
  `vpi/` glue). No encoder `.c`.
- **TH1520 (revyos/th1520-vpu)** and **ESWIN (eic7x-images)** ship the encoder
  userspace **prebuilt** (`libOMX.hantro.H2.video.encoder.so`, etc.) — no source.
- The only openly-licensed **Hantro encoder C source** is ST's, and it is a
  **different, older IP**: `STMicroelectronics/STM32CubeN6`
  (`Middlewares/Third_Party/VideoEncoder/`) ships full source — `H264EncApi.c`,
  **`H264RateControl.c`**, `JpegEncApi.c`, `encasiccontroller.c` — under
  **BSD-3-Clause with VeriSilicon copyright**, plus the EWL port at
  `STMicroelectronics/stm32-mw-venc-ewl`. **But this is VC8000NanoE = the Hantro
  H1** (H.264+JPEG, no HEVC, API `H264EncInit`, different register model), *not*
  the VC8000E (`VCEncInit`/`hevcencapi.c`). It is the closest open **rate-control
  algorithm reference** in existence — directly useful for writing a from-scratch
  CBR controller (§6 gap 5) — but it is **not** drop-in for VC8000E.
- Cross-check that RC is userspace, not firmware (the VC8000E has no firmware):
  the follow-up research `nm -D`'d NXP's actual `libhantro_vc8000e.so` blob and
  found exported `VCEncInitRc`/`VCEncBeforePicRc`/`VCEncAfterPicRc`/`rcCalculate`
  and assert strings naming `rate_control_picture.c` — confirming CBR lives in the
  (closed) userspace lib. Global code search for `rate_control_picture` /
  `ewl_vcmd` returns **zero** public source hits.

Pengutronix mainline effort (the from-scratch open path):
- **"[RFC PATCH 00/11] VC8000E H.264 V4L2 Stateless Encoder"**, Marco Felsch /
  Pengutronix, **2 May 2025**, RFC v1. i.MX8MP. **H.264-only, stateless V4L2,
  reimplements the kernel side (no VeriSilicon stack).**
  `lore.kernel.org/linux-media/20250502150513.4169098-1-m.felsch@pengutronix.de/`;
  LWN `Articles/1020012`; dev tree `github.com/bootlin/linux/tree/hantro/h264-encoding-v5.11`.
- **Rate control: NONE.** The cover letter has no CBR/VBR/bitrate/QP discussion at
  all; Kocialkowski's Linux Media Summit 2025 slides classify it as
  **userspace-driven rate control**. **Unmerged** as of ≥6.16 / mid-2026, blocked
  on the still-unsettled stateless-encoder uAPI ("not for productive use").
- Prior art: Bootlin's out-of-tree Hantro **H1** H.264 encoder (PX30/RK3399, 2020),
  also userspace RC (`cnx-software.com/2020/11/24/…`).

SoCs shipping VC8000E (reuse surface): NXP i.MX8MP, T-Head TH1520, ESWIN EIC7700,
STM32N6, plus SpacemiT/StarFive VPU BSPs — a broad base, but all ship the RC-bearing
userspace as prebuilt/EULA.

#### 6. The concrete gaps to a blob-free encoder

Ordered easiest → hardest, with where each is sourced:

1. **VCMD kernel driver** — *recoverable now, open.* Port `vc8000_vcmd_driver.c`
   (revyos/eswin, dual MIT/GPL) to the AX630C: DT `reg=0x4010000/len 0x10000`,
   `GIC_SPI 93`, plus the standard clk/reset/OPP bindings that already exist
   (§4). Small, and licence-clean.
2. **Clock/reset/power** — *no gap.* Open DT + open `clk-ax620e.c`/`axera_reset.c`
   + standard framework (§4). Unlike capture, nothing to RE here.
3. **EWL / CMM allocator glue** — *bounded userspace RE / port.* Retarget
   `EWLMallocLinear`/reg-mmap onto the AX630C CMM: either reuse an open EWL port
   (ST `ewl_impl.c`, or the `ewl_linux.c` in vendor SDKs) over `/dev/ax_venc`, or
   re-point Hantro's linear allocator at a dma-heap/CMA carveout. This is the same
   libax_sys/CMM seam capture hit, but confined to one file.
4. **VCEnc encoder core (H.264/HEVC bitstream + syntax)** — *reusable in principle,
   licence-encumbered in practice.* Fully present and legible, but the only source
   copies are NXP-EULA (`imx-vpu-hantro-vc`) or prebuilt. For an open image you
   either accept the EULA blob (no better than today's `libax_venc.so`), or
   reimplement — impractical.
5. **CBR rate control (our path)** — *the real wall.* Lives inside that same
   closed VCEnc core (`VCEncSetRateCtrl` / `rate_control_picture.c` / `VCEncInitRc`,
   plus Axera's `AXRc*` adaptive shim). **No open, reusably-licensed CBR/VBR RC for
   VC8000E exists** — the Pengutronix path explicitly has none, and every vendor RC
   ships prebuilt/EULA. A blob-free encoder must either write a rate controller
   from scratch (the historically hardest part of any hw-encoder RE, per the
   feasibility table) or ship **fixed-QP only**.

#### 7. Feasibility read — is encode more tractable than capture?

**Yes, decisively, on the kernel/hardware axis; but the licensing wall moves, it
doesn't vanish.** Concretely:

- **What's genuinely better than capture:** the venc kernel↔user ABI is *public*
  (Hantro VCMD), so no multi-week `.ko` disassembly like `ax_proton.ko`; the
  clock/reset/power is *open and standard* (capture's is opaque in-kernel); the
  register program is version-gated stock VC8000E, not a bespoke ISP fabric; and
  an openly-licensed kernel driver to port already exists (revyos/eswin). A
  **fully-open venc *kernel* replacement is a realistic, bounded port**, where the
  fully-open *capture* kernel replacement remains a quagmire.
- **What is NOT better:** the userspace rate-control core is exactly as closed as
  the capture libs — worse, actually, because no permissively-licensed substitute
  exists (the capture `.so` are at least BSD-3). Reusing Hantro's own RC means the
  NXP EULA tarball, which is not meaningfully more "open" than the blob we ship.
- **Realistic shapes of a blob-free encode path:**
  - **(A) Port open VCMD kernel driver + open EWL, keep fixed-QP, write/borrow a
    simple CBR controller.** ~Bounded kernel port (weeks) + EWL port (weeks) +
    a from-scratch frame-level bitrate→QP controller (the risk item; VC8000E RC is
    a one-pass QP model, not intractable for "good enough" KVM CBR). H.264 baseline/
    main achievable; HEVC/JPEG follow the same VCMD path. **This is the only route
    that yields a licence-clean encoder.**
  - **(B) Port open VCMD kernel driver, reuse EULA `imx-vpu-hantro-vc` userspace.**
    Fastest to a *working* open-kernel encoder with real CBR, but the userspace
    stays proprietary — buys kernel-side openness only, doesn't remove the blob
    class.
  - **(C) Track the Pengutronix V4L2 stateless effort.** Cleanest long-term, but
    H.264-only, no RC, unmerged, uAPI unsettled — not a near-term option, and it'd
    still need an AX630C DT/clock binding (which we now have) and a from-scratch RC.
- **Bottom line:** encode is the right target for a *kernel-side* open replacement
  and the first place a fully-open block is actually reachable. The residual hard
  problem narrows from "reverse an entire ISP/encoder stack" to a single, well-known
  item: **rate control**. Everything else (kernel VCMD, clocks, EWL, bitstream
  syntax) is either open or legible. Whether to pursue (A) hinges on appetite for
  writing a rate controller and accepting fixed-QP as the fallback.

#### 8. Device-tracing experiments for the follow-up (device-side) phase

> **Status (2026-08-22): items 1–5 DONE** — run on the ATX unit, written up in the
> Test log stages "2026-08-22 — §8 device tracing" (1–3), "§8.4 RC observability"
> (4), and "§8.5 … AsicConfig" (5). The VC8000E VCMD ABI is hardware-confirmed
> (ioctl map 1:1 with the public driver, VCMD-engine `hw_version_id = 0x43421500`
> = v1.5.0 → eswin EIC7X `vc8000_vcmd_driver.c`, MMU off, single core, H264+HEVC
> core + separate JPEG). The CBR rate controller is stock VCEnc one-pass RC,
> characterized with a measured reference trajectory (§8.4) — the RC "wall" is
> bounded for CBR-KVM. Item 5's live register-diff is defeated by idle MMIO
> clock-gating, so AsicConfig was read from the encoder register image mirrored in
> the VCMD DRAM pool instead.

To confirm the above static findings on the ATX unit once it's free (same safety
envelope as prior stages: `/tmp/axwork` tmpfs, `nanokvm.service` stopped/restarted,
one unit only, backups first):

1. **LD_PRELOAD ioctl trace of `/dev/ax_venc` + `/dev/ax_jenc` during a real
   encode** (reuse `axtrace.so`, filtered to magic `'k'`): capture the exact
   `HANTRO_IOC*` sequence for one channel lifecycle — Init→CreateChn→SendFrame→
   GetStream→ReleaseStream→DestroyChn — with decoded `_IOC` nr/dir/size and 8-byte
   args. Deliverable: the venc ioctl `nr`→`HANTRO_IOC*` map (the encode analogue of
   the Exp-1 capture selector table), to line up 1:1 against
   `vc8000_vcmd_driver.c`'s ioctl switch.
2. **VCMD command-buffer capture.** Interpose `mmap` on `/dev/ax_venc` and dump the
   cmdbuf/status/register pool contents (EWL builds the command buffer in the
   mmap'd pool before `EWLLinkRunCmdbuf`). Snapshot the cmdbuf before submit and
   the status buf after `HANTRO_IOCG_CORE_WAIT`. Deliverable: the actual VCMD
   opcodes + the ASIC register writes for one H.264 frame — validates that the
   register program matches public `vcmdregistertable.h`/`vcmdregisterenum.h` for
   the reported `hw_version_id`.
3. **Read `hw_version_id` + AsicConfig** (via a tiny `EWLReadAsicID`/`ReadAsicConfig`
   replay, or from `dmesg`): pins which VC8000E revision/config (cores, max res,
   codec support, MMU on/off) the AX630C carries → tells us exactly which public
   driver revision to port and which register table applies.
4. **RC observability.** With a fixed CBR config, log `AX_VENC_GetRcParam` before/
   after and the per-frame QP/size (the debug strings in §2 are emitted at
   `debug` level) across a scene change, to characterise the `AXRc*` adaptive
   behaviour we'd need to approximate in a from-scratch controller.
5. **`/dev/mem` register-diff around `0x4010000`/`0x4000000`** (the read-only diff
   technique from Task B, applied to the venc/jenc blocks) to confirm the kernel
   register program end-state per encode phase — a cross-check on the cmdbuf dump
   without disassembling the `.ko`.

**Tooling to reuse (host-built, already on the unit):** `axtrace.so` (add a
`'k'`-magic filter), `ax_marker.so` (bracket each `AX_VENC_*`), `ax_ispdiff.so`
technique retargeted to the venc MMIO bases. No new device risk beyond a possible
encoder hang cleared by power-cycle.

### 2026-07-20 — Stage 3: record-and-replay (deep capture + allocator-handshake replay) (ATX .221)

Reframed the capture problem as an M1/Asahi-style *record-and-replay* job (à la
the AGX GPU RE: shim the command stream into the kernel, replay it verbatim
without understanding it, then perturb one knob and diff), rather than a
"decode every private struct" job. Ran entirely on the ATX unit (`.221`); Desk
(`.224`) untouched. Same safety envelope: everything in `/tmp/stage3` (tmpfs),
`nanokvm.service` stopped per run and restarted after — verified **active +
HTTPS 200**. **No reboot and no watchdog hang the entire session** (uptime
unbroken), a deliberate contrast with Stage 2's zeroed-PHY `Start` crash: every
Stage-3 replay was gated to memory-only, never issuing hardware bring-up. New
tooling in `traces/stage3/`: `axdeep.c/.so` (deep-capture shim: dumps size-byte
args + follows pointer graphs one/two levels via `/proc/self/mem`, records
`/dev/mem` mmap phys↔virt, snapshots small management regions, and mmaps+dumps
carveout physes referenced in ioctl args — env `AXDEEP_BYTES/DEPTH/SNAPMGMT/PHYS`),
`capreplay3.c` (allocator-handshake replay, zero vendor libs), `cmmprobe.c` (cmm
ABI-shape probe). Data: `deep_h264.log`, `deep_phys.log`, `deep_mgmt.log`,
`d_h264_720.log`, `d_mjpeg_1080.log`, `capreplay3.log`, `cmmprobe.log`.

#### Correction: the Stage-2 "8-byte payloads are pointers to private attr structs" reading was wrong

The deep follow (which dereferences any arg word that resolves to a mapped
address) shows the config selectors' 8-byte args are **genuine `{u32,u32}` inline
scalars**, not pointers. In a *clean* capture `AX_MIPI_RX_SetLaneCombo` (mipi
nr8), `SetAttr` (nr2), `Reset` (nr4) and `Start` (nr6) all carry `{0,0}` — the
`…d0dba2d4` "stack pointer" Stage 2 latched onto was **uninitialised stack** in
the second word of one earlier run, not a real pointer. This restores the
Stage-1 reading: the 43 capture selectors are **doorbells** carrying
device/pipe/chn ids, not struct pointers. (One real exception below: os_mem nr1.)

#### What deep-capture revealed (record pass)

- **Geometry enters through the allocator descriptor, not the config ioctls.**
  The one genuine pointer arg is `AX_SYS_Init`'s **os_mem nr1** (`/dev/ax_os_mem`,
  cmd `0xc0094f01`, `_IOC_SIZE=9`): the arg is `{u64 desc_ptr, u8 flag}`. The
  descriptor is a flat struct whose first two words are **`{width, height}`**;
  the kernel returns the allocated **phys in place** (arg[0..7] ← phys). This is
  the whole marshaling seam for frame size — a small, flat, capturable struct.
- **The allocator handshake shape** (all `/dev/ax_*`, in bring-up order):
  os_mem nr1 (desc→phys, immediately `mmap`'d as a 4 KB management page) →
  sys nr45 `{0x016e3600≈24 MB, 0}` (sys-mem size scalar) → pool nr22/nr20
  (config/init) → cmm nr10 ×2, nr17, nr0, nr6 (VB pool sub-allocations) →
  proton nr138 (SYS-region phys handed to the VIN driver).
- **Which handles flow where.** Two distinct memory regions: a **management
  region** (~`0x62800000`/`0x4c…`, the os_mem return, 4 KB, mmap'd) and the
  **frame carveout** (`0x73800000–0x748xxxxx`; the 4 147 200-byte = 1920×1080×2
  buffers). proton nr138's phys (`0x74846000`) is a carveout region **libax_sys
  computes internally** — it appears in *no* ioctl arg and (mmap'd read-only at
  bring-up) contains only `0xffff0000` fill, i.e. it is populated later / by the
  kernel, not a legible flat config image we can snapshot.
- **The management pages carry no CPU-visible command traffic.** `AXDEEP_SNAPMGMT`
  diffed the first 512 B of every small `/dev/mem` region around every ioctl and
  found **zero** changes — the CMM allocator's returned physes are *not* written
  into these pages by the CPU (they come back through the driver's own bookkeeping,
  not a shared-ring the way the M1 GPU used one).

#### Blob-free replay (replay pass) — reached the CMM sub-allocator, diverges there

`capreplay3` (ldd = libc only, **zero vendor libs**) replayed the handshake with
the **captured descriptor bytes**, threading returned handles forward:

- **os_mem nr1 and sys nr45 — the two selectors Stage 2 declared "unfabricatable
  PHYS handles" — REPLAY SUCCESSFULLY.** Driven with the captured `{width,height}`
  descriptor + flag, os_mem nr1 returns **rc=0 and a fresh valid phys handle**
  (`0x4c56f000`, `0x4c892000`, `0x6e6c2000` across runs — dynamic, exactly as a
  handshake-not-a-constant should be); the phys is `mmap`-able. sys nr45 rc=0.
  This is a concrete advance over Stage 2, which wrongly skipped these as
  impossible: they are **driveable allocation requests**, and record-replay of
  the descriptor bytes drives them.
- **Divergence point: cmm nr10** (`/dev/ax_cmm`, first VB sub-allocation). The
  same `{4,0}` that returns rc=0 on the blob path returns **EINVAL** in replay;
  the downstream cmm nr17 then returns **EFAULT** (the kernel `copy_to_user`s to a
  per-context user address that libax_sys registered and we never did), nr0
  ENOMEM, nr6 EPERM. `cmmprobe` resolved *why*: **cmm nr10 is content-multiplexed**
  — inline `{small,0}` selects a "pool-block" branch that requires pool **context**
  (EINVAL without it), whereas an 8-byte *pointer* value selects a different branch
  that copies back a large response struct (observed: a `copy_to_user` big enough
  to overflow a 256 B buffer → userspace stack-canary abort; no kernel damage,
  uptime intact). The blob succeeds with `{4,0}` only because libax_sys has already
  built the pool context; that context is **kernel-global state, not bytes on the
  wire**, so pure doorbell-replay cannot reconstruct it.

So **a blob-free frame was not dequeued**, and the divergence is now localised one
layer *below* where Stage 2 stopped: not at os_mem/sys (those replay fine) but at
the **CMM VB-pool context handshake** (cmm nr10/17/0/6). This is a genuine residual
of the record-replay method: the CMM allocator's per-open/global context is
established by a stateful sequence whose *effect* (a registered pool + user
buffer addresses the kernel writes back into) is not captured by replaying the
8-byte selector payloads. Reproducing it needs either (a) capturing the full
pointed-to request/response structs for the pointer-branch of cmm nr10 and driving
*that* branch to build the pool ourselves, or (b) RE of libax_sys' CMM manager —
i.e. the residual is "reverse the CMM pool-context protocol," a bounded userspace
RE task, **not** "the selectors are insufficient."

#### Differential field map (vary one knob, diff the bytes)

Captured the blob path at three settings and diffed:

| knob | where it lives | 1080p H.264 | 720p H.264 | 1080p MJPEG |
|---|---|---|---|---|
| **width** | os_mem nr1 desc word0 | `0x780` (1920) | `0x500` (1280) | `0x780` (1920) |
| **height** | os_mem nr1 desc word1 | `0x438` (1080) | `0x2d0` (720) | `0x438` (1080) |
| **codec/config** | os_mem nr1 arg flag byte (arg[8]) | `0xf0` | `0x70` | `0x00` |
| config doorbells (proton nr21 SetDevAttr, etc.) | ioctl payload | `{1,0}` | `{1,0}` | `{1,0}` |

Decisive: **resolution is parameterised by exactly two u32s** (os_mem nr1
descriptor words 0/1), and the config doorbells are **invariant** across
resolution — geometry never crosses the config-selector wire, it is cached in the
kernel from the allocation. The flag byte tracks codec/config (three distinct
values) but is not fully decoded. So a parameterised replay for *our* settings
needs to vary only `{width,height}` + that flag; everything else is fixed opaque
bytes.

#### Updated verdict — does record-replay make the userspace `.so` practically replaceable?

**Partly, and the boundary is now exact.** Record-replay *does* defeat the parts
Stage 2 called walls: the 43-selector transport is trivially replayable, the
os_mem/sys allocator selectors replay from captured bytes and yield fresh valid
physes, and geometry is a two-word flat descriptor. What it does **not** defeat is
the **CMM VB-pool context** (cmm nr10/17/0/6): that handshake carries its state in
kernel-global driver bookkeeping and in a pointer-branch request struct we have not
yet captured, so replaying the doorbell bytes alone diverges at the first cmm
sub-allocation. Net for the ledger: the userspace `.so` remain replaceable **in
principle**, and the residual RE is now pinned to a single, bounded component —
libax_sys' CMM pool manager — rather than "the whole marshaling layer." The next
concrete move (if pursued) is to point `axdeep` at the **pointer-branch** of
cmm nr10 (dump the full request/response struct it copies), then have `capreplay3`
build the pool via that branch and re-thread — the same incremental
one-selector-at-a-time advance the M1 effort used. (Licensing caveat unchanged:
the `.so` are the BSD-3 part; the GPL-tagged `.ko` remain regardless.)

**Tooling added** (`~/nanokvm-backups/atx-221/traces/stage3/`): `axdeep.c`
(deep-capture shim), `capreplay3.c` (handshake replay), `cmmprobe.c` (cmm ABI
probe). Data: `deep_h264.log` (full bring-up w/ pointer follow), `deep_phys.log`
(carveout-phys dumps), `deep_mgmt.log` (management-region diff = empty),
`d_h264_720.log` / `d_mjpeg_1080.log` (differential), `capreplay3.log`,
`cmmprobe.log`.

### 2026-07-20 — Stage 3b: cracked the pool + CMM handshake (blob-free) (ATX .221)

Continued the record-and-replay effort one layer deeper, targeting the Stage-3
divergence at **cmm nr10**. Ran entirely on the ATX unit (`.221`); Desk (`.224`)
untouched. Same safety envelope: everything in `/tmp/stage3` (tmpfs),
`nanokvm.service` stopped per run and restarted after (verified **active +
HTTPS 200**). **No reboot, no watchdog hang the entire session** (uptime unbroken
4h15m) — every replay was gated to memory-only, never issuing hardware bring-up.
New tooling in `traces/stage3/`: `poolcap.c` (record shim: dumps the full
pointed-to arg struct **before and after** each pool/cmm ioctl, plus mmap'd
shared regions), `cmmpool2/3/4.c` + `n17probe.c` (blob-free replay, zero vendor
libs). Data: `pc2.log`, `pc3.log` (blob arg-struct captures),
`poolcap_shared_regions.log`, `cmmpool4.log`.

#### The master key: `_IOC_SIZE=8` is a lie — the arg is a struct **pointer**

Every pool/cmm config selector is declared `_IOWR(magic, nr, 8)`, but the kernel
handlers **ignore the declared size and `copy_from_user` a much larger struct
straight from the arg pointer.** This single fact was the whole Stage-3 wall. The
blob's 8-byte "doorbell" payloads (`{0,0}`, `{4,0}`) are just the first 8 bytes of
these structs; every prior replay (Stage 2/3) passed only those 8 bytes, so the
kernel read **stack/heap garbage past byte 8** and rejected the call — which we
mis-diagnosed as "needs kernel-global pool context." It does not. Capturing the
full pointed-to struct (`poolcap.so` dumps it) and replaying it verbatim unblocks
the calls. **This corrects the Stage-3 conclusion that cmm nr10 diverges on
un-reconstructable kernel context.**

#### The pool-creation handshake, replayed blob-free (rc=0, zero vendor libs)

- **`pool nr22` (`AX_POOL_SetConfig`) → rc=0.** The arg points to a struct with a
  40-byte (all-zero) header, then `AX_POOL_CONFIG_T` at **offset 0x28**:
  `MetaSize@0x28=0x1000` (4096), `BlkSize@0x30=0x3f4800` (**4147200 = 1920×1080×2**),
  `BlkCnt@0x38=4`, `CacheMode@0x40=0`, `PartitionName@0x44="anonymous"`. Passing
  this struct **directly as the ioctl arg** succeeds; passing `{0,0}` returns
  `AX_ERR_POOL_ILLEGAL_PARAM` (0x800b010a).
- **`pool nr20` (`AX_POOL_Init`, no arg) → rc=0.** Previously `AX_ERR_POOL_NOMEM`
  (0x800b0118) because SetConfig had failed; with a valid config it succeeds.
- The floorplan is the **only** place block geometry crosses to the kernel: `poolcap`
  confirmed `BlkSize=0x3f4800` appears in **no** shared region — not the os_mem
  "MMSO" management page, not the fixed CMM **partition-name table** at phys
  `0x71022000` (which holds the 40 module carveout names ISP/VENC/VIN/SENSOR/… and
  is populated once at boot, not per-pool), not the PLL/clk pages. Geometry travels
  only via this struct + the os_mem nr1 descriptor.

#### cmm nr10 — the exact Stage-3 divergence — now passes (rc=0)

Same struct-pointer pattern. `cmm nr10`'s arg is a ~48-byte struct:
`count@0x00=4`, a field `@0x08` (0x02400000 / 0x02500000, varies per call), and a
**size `@0x2c`** (0x0d4008 / 0x2000). The kernel allocates and **writes back a
mapped userspace vaddr at `@0x20`** (e.g. `0xffffab12b000`). Replaying the full
struct → **rc=0**; `{4,0}`-only → EINVAL (confirming the garbage-read failure, not
context). Both blob `cmm nr10` calls replay successfully in order.

- **`cmm nr0` / `cmm nr6` → rc=0.** Named CMM allocations: `count@0=4`,
  `flag@0x28=1`, `size@0x2c=0x188` (392 B), `name@0x3c="anonymous:isp_model_manger_list"`.
  `cmm nr6` also carries `phys@0x08=0x74846000` (the carveout addr `proton nr138`
  consumes); the kernel returns that phys in place. These are small ISP-metadata
  allocations, **not** the frame pool.

**Net: 5 of the 6 pool/cmm sub-allocation selectors that blocked Stage 2/3 now
replay to rc=0 from zero vendor libs** (`pool nr22/nr20`, `cmm nr10 ×2`, `cmm
nr0/nr6`) — the entire allocation handshake, threading returned physes/vaddrs.

#### New precise residual: `cmm nr17` (partition-info query) EFAULTs

The one remaining diverging selector. On the blob path `cmm nr17` takes a **zeroed**
arg and returns rc=0 having written `"anonymous"` at `@0x3c` (a partition-name
query). Our replay returns **EFAULT (errno 14)** under every strategy tried
(`n17probe.c`: zeroed; `count=4`; an out-buffer pointer at `@0x20` and `@0x08`;
threading the `cmm nr10`-returned vaddr; reordering after `cmm nr0/nr6`). Because
the target is **not in the struct** (the blob's is all-zero) yet the blob succeeds,
the `copy_to_user` destination is **kernel per-context state**: libax_sys installs
it by populating its **"MMSO" shared control block** in the os_mem-returned page
(header `4d 4d 53 4f`), which our replay maps but leaves zeroed. Reproducing it
needs reversing the MMSO control-block layout — a bounded libax_sys RE now isolated
to exactly this one query selector (and it likely contains process-local pointers,
the classic record-replay wall for pointer-bearing shared state).

#### Updated verdict — record-replay vs the userspace `.so`

Record-replay now defeats the **whole pool + CMM allocation handshake**, not just
os_mem/sys: the "master key" is that the config selectors' 8-byte payloads are
struct *pointers* the driver over-reads, and once the full structs are captured they
replay verbatim (parameterized only by our `{width,height}` → floorplan `BlkSize`).
The Stage-3 "cmm nr10 needs un-reconstructable kernel-global context" verdict was
**wrong** — it was a struct-marshaling artifact. The residual shrinks to two named
items: (a) `cmm nr17`'s dependence on the libax_sys **MMSO** shared control block,
and (b) the still-gated **hardware bring-up** (MIPI/VIN Start), which a blob-free
frame ultimately requires and which we did not issue (Stage-2 zeroed-PHY `Start`
crashed the board). So the userspace `.so` remain replaceable **in principle**, and
the bounded RE is now "reverse the MMSO control block + faithfully replay the
hardware-attr structs" rather than "the whole allocator is a wall." A blob-free
YUV frame was **not** dequeued (it needs the gated hardware bring-up), but the
allocator handshake that blocked every prior stage is solved. (Licensing caveat
unchanged: the `.so` are BSD-3; the GPL-tagged `.ko` remain regardless.)

**Tooling added** (`~/nanokvm-backups/atx-221/traces/stage3/`): `poolcap.c`
(full-struct before/after record shim), `cmmpool2.c`/`cmmpool3.c`/`cmmpool4.c`
(blob-free pool+cmm replay, exact blob order), `n17probe.c` (cmm nr17 isolation).
Data: `pc2.log`/`pc3.log` (blob arg-struct captures with AFTER writebacks),
`poolcap_shared_regions.log` (shared-region dumps), `cmmpool4.log` (final replay
result: pool nr22/nr20 + cmm nr10×2/nr0/nr6 all rc=0, cmm nr17 EFAULT).

### 2026-07-21 — Stage 4: blob-free `cmm nr17` solved (the MMSO hypothesis was wrong) (ATX .221)

**Headline: `cmm nr17` now returns rc=0 with zero vendor libraries** (`ldd` =
libc + ld + vdso only), writing back `name="anonymous"` byte-for-byte like the
blob. The entire pool + CMM allocation/context layer — **all 6 selectors** (`pool
nr22/nr20`, `cmm nr10 ×2`, `cmm nr17`, `cmm nr0/nr6`) — is now blob-free.

**The Stage-3b MMSO explanation was a red herring.** `cmm nr17` has nothing to do
with the "MMSO" shared page. Static RE of `ax_cmm.ko` (unstripped; `objdump` on
the device) settled it definitively:

- `_IOC_NR 17 (0x11)` dispatches (in `ax_cmm_userdev_adapter_ioctl @0x4480`) to
  **`_ioctrl_get_mem_config.isra.0 @0x3a60`**, *not* the `get_partition_info`
  handler its returned string suggests.
- That handler does `AX_OSAL_DEV_copy_from_user(kbuf, arg, 0x378)` — it reads
  **888 bytes** from the arg pointer, ignoring the declared `_IOWR(,,8)` size. Same
  full-struct-over-read trap as every other CMM selector.
- It then **range-checks four fields** and returns `-14` on any failure:
  `u32 @0x368` must be in `[1,46]`; `u32 @0x36c` in `[0,31]`; `u32 @0x370` in
  `[0,15]`; `u8 @0x374` in `[0,2]`. The `-14` is `-EFAULT`, but here it is a
  **validation rejection, not a memory fault** — the misleading errno that sent
  Stage 3b chasing MMSO.
- The blob's arg was **not actually zeroed**: the `poolcap`/`axdeep` traces show
  `struct@0x368 = 0x11 (17)`, `@0x36c/0x370/0x374 = 0`. Every prior replay
  (`n17probe`, `cmmpool4`) passed a *fully*-zeroed 888-byte struct → field `@0x368
  = 0` → `0u-1 = 0xffffffff > 0x2d` → `-EFAULT`. The struct-tail values had simply
  never been reproduced (only the first 8 bytes were).

**Fix (verified on hardware, `stage4/nr17fix.c`):** allocate the full 888-byte
struct, set `u32@0x368 = 17` (any value in `[1,46]` works; `1` also passes),
leave the rest zero. Result — with zero vendor libs:
```
cmm nr10 #1/#2  rc=0    proton nr0 {3,3}  rc=0
nr17 idx=0  (old zeroed)          rc=-1 errno=14   <- reproduces the old failure
nr17 idx=17 (vendor-captured)     rc=0  name=anonymous   <<<PASSED
nr17 idx=1                        rc=0  name=anonymous   <<<PASSED
cmm nr0 / cmm nr6                 rc=0
nr17 idx=17 (post nr0/nr6)        rc=0  name=anonymous   <<<PASSED
```
So the Stage-3b "residual (a) MMSO control block" is closed, and it was never a
shared-page or per-context-state problem — it was the recurring "reproduce the
FULL pointed-to struct" rule applied to one more selector. The `mmso_repro.c`
experiment also confirmed the os_mem-returned page's `4d 4d 53 4f` magic is just
**residual physical-RAM content** from an earlier blob run (it survives in the
reused CMM page and is irrelevant to `nr17`); the kernel does **not** populate a
per-context partition table into our mapped page, further ruling MMSO out.

#### Hardware bring-up roadmap (mapped, not yet driven to a frame)

With the allocation/context layer fully blob-free, the only thing between here and
a blob-free YUV frame is faithfully replaying the hardware bring-up structs — the
same method, more selectors. The full pipeline from `deep_h264.log` is now
enumerated (`ax_mipi_rx` 7 selectors, `ax_proton`/VIN ~40 selectors, then
venc/jenc). Concrete shapes established this stage:

- **MIPI-RX** (`ax_mipi_rx.ko`, `ax_mipi_rx_ioctl @0x690` in `.text.unlikely`):
  a **pointer-indirect ABI** — the ioctl arg is a small descriptor whose `+8`
  field holds a pointer to the real attribute struct (`ldr x20,[x2,#8]`; the
  `axdeep` `in* +4` follow confirms the attr buffer). Selector map: `nr0` →
  `ax_mipi_rx_reg_init` (Init), `nr1` → `ax_mipi_deinit`, **`nr2` →
  `ax_mipi_set_attr`** (the lane/PHY `AX_MIPI_RX_ATTR_T` — size it from
  `ax_mipi_rx_api.h`), `nr4/6/7/8` → the reset/PHY/start helpers. Trace order:
  `nr8, nr2, nr4, nr6` at setup, then `nr7` (large 256B+ attr) and `nr1`-style
  start near first frame.
- **VIN/proton** bring-up interleaves with the CMM allocations already solved
  (`AX_VIN_CreateDev` = proton nr17, `SetDevAttr` = proton nr21, pipe/chan attrs,
  enable, `AX_VIN_Start`), then the frame-dequeue path. Each carries a
  pointer-borne attr struct to be dumped full and reproduced, exactly as for CMM.

**Status of a blob-free frame:** *not yet captured.* No fabricated result — the
remaining work is bounded and mechanical (disassemble `ax_mipi_rx`/`ax_proton`
handlers for each `copy_from_user` size + required-field ranges, reproduce the full
attr structs, thread pool ids/frame phys forward, then issue the live MIPI/VIN
`Start` and dequeue). The live hardware `Start` is safe to issue (tmpfs-only, watchdog
recovery); it was gated in Stage 2 only because the attr structs were fabricated
(zeroed PHY), which is precisely what this method now supplies faithfully.

#### Updated verdict

Every non-hardware layer of the vendor userspace (`libax_sys` allocator + CMM/pool
+ SYS region + the `nr17` context query) is now **demonstrably reproduced from
libc-only userspace** via record-replay of full pointed-to structs. No selector in
the allocation/context path remains a wall; the Stage-3b "kernel-global context"
and Stage-4 "MMSO control block" hypotheses were both struct-marshaling artifacts.
The vendor `.so` (`libax_sys`/`libax_mipi`/`libax_proton`) are therefore replaceable
for this capture use case **pending the mechanical hardware-attr reproduction**, not
any remaining unknown. (Licensing caveat unchanged: the `.so` are BSD-3; the
GPL-tagged `.ko` remain regardless.)

**Tooling added** (`~/nanokvm-backups/atx-221/traces/stage4/`, durable off tmpfs):
`nr17fix.c` (+built `nr17fix` binary — full-888B-struct blob-free `nr17`, the
verified fix), `mmso_repro.c` (MMSO-page experiment that disproved the MMSO
hypothesis), `mmsocap.c`/`mmso.log` (blob MMSO-page + `nr17`-arg capture),
`ax_cmm.ko` + `ax_cmm_nr17_disasm.txt` (the dispatch + `_ioctrl_get_mem_config`
disassembly that root-caused it), `n17probe.c` (prior isolation harness).

### 2026-07-21 — Stage 5: MIPI-RX PHY bring-up blob-free + full capture-ABI recovery (ATX .221)

Ran on the ATX unit (`.221`); Desk (`.224`) untouched. Same safety envelope (all in
`/tmp/stage5` tmpfs; `nanokvm.service` stopped for the runs, restarted after —
verified **active + HTTPS 200**; uptime stayed continuous the whole session, no
reboot). New tooling in `traces/stage5/`: `mv5cap.c/.so` (full-struct capture
shim), `mipibringup.c` (blob-free MIPI+VIN-dev bring-up), the two vendor `.ko`,
`mv5.log` (722-ioctl byte-exact capture), and the disassembly records
(`mipi_full_disasm.txt`, `proton_handlers_disasm.txt`).

**Method — disassembly-first, exactly as Stage 4 prescribed.** Both `ax_mipi_rx.ko`
(106 KB) and `ax_proton.ko` (4.5 MB) are **unstripped**; pulled off-device, they
disassemble cleanly with on-device `objdump`. For every bring-up selector we read
the real `copy_from_user` size and the pointer indirection directly from the
handler, then captured the exact bytes the vendor lib marshals with `mv5cap.so`
(dumping the true `cfu` size per selector, not the misleading `_IOC_SIZE=8`).

#### MIPI-RX handler ABI — fully recovered (all 7 selectors)

`ax_mipi_rx_ioctl` (`0x690`) is `(cmd_w0, user_arg_x1, ctx_x2)`; `*(ctx+8)` = the
in-kernel device object, `user_arg` = the userspace struct pointer. Every handler
`copy_from_user`s a small **pointer-free scalar** struct:

| nr | `AX_*` | handler | cfu size | struct |
|---|---|---|---|---|
| 0 | `AX_MIPI_RX_Init` | `ax_mipi_rx_reg_init` (`0x3c90`) | 0 | none — ioremaps `0x2600000` (MIPI base) |
| 1 | `DeInit` | `ax_mipi_deinit` | 0 | none |
| 2 | `SetAttr` | `ax_mipi_set_attr` (`0x35c0`) | **28** | `{u32 idx, ..., u32 lanes, u32 rate, u8[8] lanemap}` |
| 4 | `Reset` | `ax_mipi_reset` (`0x36d0`) | **4** | `{u8 idx}` |
| 5 | `Unreset` | `ax_mipi_unreset` (`0x3778`) | **4** | `{u8 idx}` |
| 6 | `Start` | `ax_mipi_start` (`0x3800`) | **4** | `{u8 idx}` |
| 7 | `Stop` | `ax_mipi_stop` | **4** | `{u8 idx}` |
| 8 | `SetLaneCombo` | `ax_mipi_set_lanecombo` (`0x39b0`) | **4** | `{u32 combo}` |

The **real 28-byte `SetAttr` payload** captured off the live vendor path (1080p,
ISP-bypass) is:
`00000000 00000000 00000000 04000000 58020000 00010304 02050000` — i.e.
`idx=0, lanes=4 (0x04), rate-field=0x258, lanemap bytes 00 01 03 04 02 05`. Stage 2's
hard-stop (mipi `Start` against a **zeroed** attr → 0 lanes → PHY never locks → the
`.ko` spun and the watchdog rebooted the board) was exactly this struct fabricated
wrong.

#### VIN/proton handler ABI — sizes recovered by disassembly

`ax_isp_ioctl` (`0x982e0`) is a two-level dispatch: `attr = *(ctx+8)` (the userspace
struct), `nr` routed by range to `isp_vin_dev_ioctl` (nr ≤ 0x21), `isp_vin_pipe_ioctl`
(≤ 0x61), `isp_vin_frame_ioctl` (≤ 0x68), etc. Leaf-handler `copy_from_user` sizes:

| nr | `AX_VIN_*` | handler | cfu size | pointers? |
|---|---|---|---|---|
| 17 | `CreateDev` | `ax_vin_dev_create` (`0x8dd18`) | **376** | none (pure scalar) |
| 21 | `SetDevAttr` | `ax_vin_dev_attr_set` (`0x8e1b0`) | **376** | none |
| 19 | `EnableDev` | `ax_vin_dev_enable` (`0x8e738`) | **1** | none |
| 101 | `GetYuvFrame` | `ax_vin_pipe_frame_get` (`0x8a2d0`) | **248** | (frame-info out) |

The 376-byte dev attr is all scalars — geometry `0x780×0x438` (1920×1080), lane map
`00 01 02 03 1e`, format `0x05`, dev id at off 240 (range-checked `≤3`).

#### Result — blob-free MIPI-RX PHY START, no hang (the Stage-2 wall is gone)

`mipibringup.c` (libc-only; `ldd` = libc) reproduces, with **zero vendor libraries**,
the allocator/context layer (the Stage-4 `nr17fix` sequence) **plus** the
pointer-free device bring-up, in the vendor's captured order, all with the **real**
captured struct bytes:

```
os_mem nr1 rc=0   pool nr22/nr20 rc=0   mipi nr0 rc=0
cmm nr10×2/nr17/nr0/nr6 rc=0   proton nr0{3,3} rc=0
proton nr138 (sys region 0x74846000) rc=0
proton nr12 (VIN_Init, geometry) rc=0
proton nr17 CreateDev (376B) rc=0
mipi nr8 lanecombo rc=0   mipi nr2 SetAttr (4 lanes) rc=0   mipi nr4 reset rc=0
mipi nr6 START rc=0   <<< previously hung the board; now clean, no reboot
proton nr21 SetDevAttr (376B) rc=0   proton nr19 EnableDev rc=0
```

`/proc/uptime` was continuous across the run (no watchdog reset). This is the
decisive advance over Stage 2: **the MIPI-RX PHY is brought up (lane/PHY attr →
reset → start) entirely from open userspace over the kept `.ko`, and it no longer
faults** — the difference is purely the faithful 4-lane attr struct that disassembly
+ capture supplied. `libax_mipi` is **demonstrably replaceable** for this use case.

#### Did we capture a real YUV frame with zero vendor libraries? — No, and here is exactly why

We captured the vendor path's frame buffers (`mv5.log` `[mmap]` lines: YUYV 1080p at
CMM physes `0x74451000`/`0x73c67000`, len 4 147 200 = 1920×1080×2) and the whole
722-ioctl bring-up byte-exact — but a **blob-free** frame is blocked at a precisely
characterized boundary. Byte-exact replay works only for **pointer-free** structs;
scanning the capture, the bring-up splits cleanly:

- **Pointer-free (replayable, and reproduced above):** all MIPI selectors; VIN
  `CreateDev`/`SetDevAttr`/`EnableDev` (nr17/21/19); `VIN_Init` (nr12); the
  `nr138` SYS-region handle (a deterministic carveout phys, `0x74846000`).
- **Pointer-bearing (NOT byte-exact replayable):** the runtime pipe/stream/frame
  path — `SetPipeAttr` (proton nr2-pipe, nr42, nr43×~15), `CreatePipe` tail (nr35),
  `SetChnAttr` tail (nr48), `EnableChn` (nr55), **`StartPipe` (nr38/40)**,
  `StreamOn` (nr69/109/158), and the ISP-config selectors (nr53/54/74/89). These
  carry **embedded userspace pointers to sub-structs** (0x0000ffff…/0x0000aaaa…
  halves) *very early* in the struct — e.g. `StartPipe`'s arg has a pointer at
  offset 1, `EnableChn` at offset 8. Replaying the captured bytes would make the
  kernel dereference dead vendor-process addresses (fault/hang), and even if mapped
  they point at data we did not reconstruct. So the frame dequeue is unreachable by
  mechanical replay: it needs **field-level marshaling reconstruction** — for each
  pointer-bearing selector, disassemble the leaf consumer (`ax_vin_pipe_*`) to learn
  what it reads through each pointer, rebuild those sub-structs at valid addresses,
  and thread our own pool ids + frame physes. This is the "bounded userspace RE"
  the earlier stages named, now **pinned to a specific ~10-selector set** rather than
  a vague unknown.

#### Verdict — are `libax_sys`/`libax_mipi`/`libax_proton` replaceable for capture?

- **`libax_mipi`: yes, demonstrated.** Full CSI-2 PHY bring-up (attr/reset/start)
  runs blob-free and locks without fault.
- **`libax_sys` (allocator/CMM/pool/SYS region): yes, demonstrated** (Stages 3b–4,
  reused verbatim here).
- **`libax_proton` VIN device layer: yes for the pointer-free structs**
  (`CreateDev`/`SetDevAttr`/`EnableDev`/`VIN_Init` reproduced rc=0).
- **`libax_proton` VIN pipe/channel/stream + ISP-bypass config: ABI recovered, not
  yet reproduced.** The selector set, dispatch, `copy_from_user` sizes and call order
  are fully mapped; what remains is reconstructing the ~10 pointer-bearing marshaling
  structs (the sub-struct layouts + pointer fix-ups) so `StartPipe`/`StreamOn`/
  `GetYuvFrame` can run. No hardware unknown remains between here and a frame — only
  this mechanical, disassembly-guided struct reconstruction. **That, and nothing
  else, is what stands between the current state and a blob-free captured frame.**

**Tooling added** (`~/nanokvm-backups/atx-221/traces/stage5/`, durable off tmpfs):
`mv5cap.c/.so` (full-struct capture shim; env `MV5_OUT`,`MV5_DUMP`), `mipibringup.c`
(the blob-free MIPI+VIN-dev bring-up harness, `ldd`=libc), `mv5.log` (byte-exact
722-ioctl vendor capture with frame-buffer physes), `mipi_full_disasm.txt` +
`proton_handlers_disasm.txt` (the handler disassembly that yielded every size/field),
and `ax_mipi_rx.ko`/`ax_proton.ko`.

### 2026-07-21 — Stage 6: a real 1080p YUV frame captured blob-free (ATX .221)

**Headline: a genuine 1920×1080 YUYV frame was dequeued from the camera pipeline
with zero vendor libraries** (`ldd stage6` = libc only), verified to be live HDMI
content and cross-checked against the Desk unit's vendor pipeline. Ran on ATX
(`.221`); Desk (`.224`) read-only. Same safety envelope (all in `/tmp/stage6`
tmpfs; `nanokvm.service` stopped for runs, restarted after — **active + HTTPS 200**;
progress logged to eMMC `/root/stage6.log` with `fsync` so a watchdog reset can't
hide the wedge point).

#### The Stage-5 "pointer" hypothesis was wrong — the selectors are pointer-free

Stage 5 concluded the pipe/chn/stream selectors carried *embedded process-specific
pointers early in the struct* (StartPipe@1, EnableChn@8, …) and were therefore not
byte-replayable. **That was an artifact of the capture shim dumping a fixed 512
bytes** starting at each ioctl arg — well past the selector's true (small)
`copy_from_user` size — so the bytes after the real struct were just adjacent stack
garbage (neighbouring locals, saved `x29/x30`, `0xffff…`/`0xaaaa…` stack/heap
addresses). Disassembling the *leaf* handlers in `ax_proton.ko` shows the truth:
each leaf does `copy_from_user(local, user_arg, SIZE)` with a **small hardcoded
SIZE**, reads a `pipe_id` **byte** from it (range-checked `≤6`), and resolves the
pipe object **in-kernel** via `DEV + pipe_id*8` at `[obj, #1024]`. No userspace
sub-struct pointer is ever dereferenced. Because the kernel copies *its own* size,
replaying the captured 512-byte buffer is safe: the kernel takes only the correct
pointer-free prefix and ignores the trailing garbage.

#### VIN pipe dispatch + selector map (recovered by disassembly)

`ax_isp_ioctl` (`0x982e0`) routes by `nr` range to `isp_vin_{dev,pipe,frame,irq,
stat,sync}_ioctl`. `isp_vin_pipe_ioctl` (`0x98790`) uses a 63-entry jump table at
`.rodata+0xbb04`: index `= nr-35`, target `= 0x987d0 + 4*int16(table[index])`. Decoding
it (and each leaf's first `copy_from_user` size) gives the exact map. The bring-up
selectors and their **true** sizes / roles:

| nr | handler | cfu | role |
|---|---|---|---|
| 35 | `ax_vin_pipe_create` | 76 | **CreatePipe** (scalar; pipe_id@0) |
| 42 | `ax_vin_pipe_attr_set` | 76 | **SetPipeAttr** (pure input; one call) |
| 43 | `ax_vin_pipe_attr_get` | 76 | GetPipeAttr (readback; copy_to_user — skip) |
| 48 | `ax_vin_pipe_yuv_chn_attr_set` | 48 | **SetChnAttr** (pipe@0, fmt@20 ≤8) |
| 55 | `ax_vin_pipe_yuv_chn_enable` | 8 | **EnableChn** (pipe@0, chn@1, u32@4) |
| 38 | `ax_vin_pipe_open` | 1 | **pipe_open** (just pipe_id) |
| 40 | `ax_vin_pipe_start` | 1 | **StartPipe** (just pipe_id) |
| 56 | `ax_vin_pipe_black_level_set` | 10 | ISP-bypass cfg |
| 74 | `ax_vin_pipe_scene_attr_set` | 24 | ISP-bypass cfg |
| 54 | `ax_vin_pipe_partition_info_set` | 180 | ISP-bypass cfg |
| 89 | `ax_vin_pipe_npu_throttle_info_set` | 424 | ISP-bypass cfg |
| 101 | `ax_vin_pipe_frame_get` | 248 | **GetYuvFrame** (in: pipe@0; out: copy_to_user 248B descriptor incl. pool block handle) |

Dev range: nr17 CreateDev(376) / nr21 SetDevAttr(376) / nr19 EnableDev(1) /
nr30,nr22 (dev attrs) — all pointer-free, as Stage 5 already had. The Stage-5
"pointers" nr38/nr40 are just the 1-byte pipe-open/start; nr69/nr70 (the streaming
loop) are `regio_switch`/`regio_sync`, 1 byte each.

#### Bring-up sequence that works (blob-free), and the one thing that mattered

`stage6.c` (libc-only) replays, in vendor order, the captured cfu-prefix of every
selector: allocator/CMM/pool → MIPI PHY (Stage-5 4-lane attr) → CreateDev/SetDevAttr/
nr30/nr22 → **CreatePipe, SetPipeAttr, [ISP-bypass cfg 56/74/54/89], SetChnAttr,
EnableChn, pipe_open, StartPipe, EnableDev** → **GetYuvFrame**. All rc=0, no reboot.

**Critical finding:** a first run that *skipped* the ISP-bypass config selectors
(nr56/74/54/89) brought every ioctl back rc=0 but then **hard-hung the SoC** when
the channel/DMA engaged → watchdog reboot (~60 s). Adding those four config calls
(pointer-free scalars, captured bytes) makes StartPipe/EnableChn/GetYuvFrame run
clean and a frame appear immediately (`GetYuvFrame` returns on attempt 0). The
ISP-bypass datapath config is **required**, not optional, for a stable capture.

#### Getting the pixels out, and proving the frame is real

`GetYuvFrame` returns a 248-byte descriptor whose only non-trivial output is a
**pool block handle** `0x5e000001` (vendor's was `0x5e0000xx`) at offset 0x28 — not
a raw phys. The YUYV pixels live in the CMM pool block. `/proc/ax_proc/mem_cmm_info`
shows the pool as one contiguous `comm_pool_0` CMM block (base `0x7386E000`,
16224 KB = 4 × 4147200 B blocks, data-first layout); block index = handle&0xff = 1,
so phys = `0x7386E000 + 1*4147200 = 0x73C62800`. `stage6.c` snapshots the CMM map
while the pool is live (it frees on process exit), `mmap`s `/dev/mem` at the block
phys, and reads out **4 147 200 B = 1920×1080×2 (YUYV)**.

Verification (rigorous, not overclaimed):
- **Dimensions/format:** exactly 1920×1080×2 YUYV, correct stride; renders to a
  coherent 1080p image.
- **Content is real, not zero/flat/noise:** Y range 28–83, 56 distinct Y values,
  every sampled byte non-zero, **adjacent-row correlation 0.982** (noise ≈ 0). The
  decoded RGB is a **Linux desktop app-launcher** (Jellyfin/Firefox/Steam/Spotify/
  Element/Hades/Chromium/Arduino IDE tiles) with an on-screen clock reading
  **"6:58 PM Monday, July 20, 2026"** — i.e. live wall-clock, so it is a fresh
  capture, not a stale/synthetic buffer.
- **A/B vs Desk (`.224`) vendor pipeline:** read the same-index pool block from the
  Desk unit's *untouched vendor* pipeline via `/dev/mem` (read-only). Same
  `comm_pool_0` layout; **identical Y stats (min/max/mean 28/83/51.7, rowcorr
  0.984)** and the same desktop image, its clock reading **"7:02 PM"** — the 4-min
  delta is exactly the gap between the two grabs. Both units capture the same HDMI
  via the splitter; the ATX side used **zero vendor libraries**.

Saved raws/renders: `~/nanokvm-backups/atx-221/traces/stage6/frame_stage6.yuyv`
(the raw blob-free 1080p YUYV), `frame_full.png`, `frame_small.png` (ATX blob-free),
`desk_reference.png` (Desk vendor A/B).

#### Verdict — capture is replaceable, demonstrated end-to-end

- **`libax_sys` (allocator/CMM/pool/SYS region): replaced** — reproduced blob-free.
- **`libax_mipi` (CSI-2 PHY bring-up): replaced** — locks without fault (Stage 5).
- **`libax_proton` (VIN dev + pipe/chn/stream + ISP-bypass cfg + frame dequeue):
  replaced** — every selector is a pointer-free scalar; the open harness brings the
  pipe up and dequeues a real YUV frame with no vendor lib in the process.

What remains is only **productionization**, not feasibility: fold this sequence into
`pkgs/kvm-encoder` as an open `libkvm` capture backend (own the pool-block↔phys math
instead of scraping `/proc`, add StopPipe/DisableDev teardown, wire the buffer
into the existing encoder path). No hardware unknown and no residual vendor-lib
dependency stands between here and an open capture stack.

> **Folded in (2026-07-21).** The Stage-6 sequence is now a real capture backend
> in the tree: `pkgs/kvm-encoder/src/kvm_capture_open.c`, selected by the
> `openCapture` flag in `pkgs/kvm-encoder.nix` (default **off** = vendor MPI).
> See the fold record at the end of the [Test log](#test-log).

**Tooling added** (`~/nanokvm-backups/atx-221/traces/stage6/`, durable off tmpfs):
`stage6.c` (blob-free bring-up + frame-dequeue harness, `ldd`=libc), `stage6_payloads.txt`
(captured cfu-prefixes per selector), `yuyv2png.py`/`yuyv2pgm.c` (renderers),
`devmem_grab.py` (read-only Desk grabber), `dev_analyze.py` (jump-table + cfu-size
decoder), `leaf_pipe.txt`/`leaf_disp.txt` (leaf-handler disassembly), `stage6.log`
(fsync'd per-step run log), `cmm_at_frame.txt` (CMM map at capture), and the
`frame_*.yuyv/.png` + `desk_reference.png` captures.

### 2026-07-21 — Stage 6 folded into pkgs/kvm-encoder

The proven Stage-6 capture sequence is now an in-tree, build-selectable capture
backend behind the unchanged `kvm_vision.h` ABI. Nothing about the shipped image
changes by default; this adds the blob-free path one flag away.

**What landed**
- `pkgs/kvm-encoder/src/kvm_capture_open.c` — blob-free implementations of the
  capture half (`kvm_sys_init` / `kvm_cap_start` / `kvm_cap_get` /
  `kvm_cap_release` / `kvm_cap_stop` / `kvm_sys_deinit`) driving `/dev/ax_*`
  directly. The bring-up is the byte-exact Stage-6 replay; every embedded `PL_*`
  payload is the within-`copy_from_user`-size prefix captured off the live vendor
  path (`traces/stage6/stage6_payloads.txt`), cross-checked against the leaf
  handler disassembly for each selector's true cfu size.
- `kvm_pipeline.c` — the vendor capture functions are now under
  `#ifndef KVM_OPEN_CAPTURE`; the VENC half and `kvm_read_source` are shared by
  both backends. The one `AX_VIN_GetImgBufferSize` call in `kvm_venc_create` is
  guarded (open build sizes the encoder buffers locally, needing no libax_proton).
- `pkgs/kvm-encoder.nix` — `openCapture` arg (default `false`). When `true`:
  compiles `kvm_capture_open.c`, defines `-DKVM_OPEN_CAPTURE`, and drops
  `-lax_mipi` from the link line (`-lax_venc -lax_sys -lax_ivps -lax_proton`
  stay — the closed encoder pins them; see the integration finding below).

**Productionization deltas vs `stage6.c`**
- Owns the pool-block↔phys math: parses `/proc/ax_proc/mem_cmm_info` **once** at
  pool init for the `comm_pool_0` base, then `phys = base + (handle&0xff)*blkSz`
  per frame (no per-frame `/proc` scrape, no whole-pool dump).
- Frame → encoder handoff: `kvm_cap_get` builds an `AX_IMG_INFO_T` (YUYV 0x0D,
  1920×1080, `u64PhyAddr`/`u32BlkId` from the block handle) that feeds the
  existing `AX_VENC_SendFrame` path unchanged — this is what wires capture to
  encode. `kvm_cap_release` issues `AX_VIN_ReleaseYuvFrame` (proton nr104) with
  the returned descriptor.
- Adds teardown (`kvm_cap_stop`): DisableDev/StopPipe/DisableChn/DestroyPipe/
  DestroyDev + MIPI Stop/DeInit, from the vendor selector order in `mv5.log`.

#### Device validation (2026-07-21, ATX .221) — PASSED end-to-end

Ran the `openCapture` `libkvm.so` on `.221` under a dlopen harness driving the
public `kvmv_read_img` H.264 path (service stopped, `/tmp` tmpfs, restarted
after; uptime continuous — no watchdog reboot at any point):

- **Real H.264 out of blob-free capture.** The library brought the capture up
  (`[openkvm] capture up 1920x1080 (blob-free)`) and produced
  **SPS(32B)+PPS(8B)+IDR(~15.5KB)+30 P-frames** (~550 KB). Pulled off-device and
  decoded with ffmpeg to a **correct, correctly-proportioned 1080p frame** of the
  live HDMI desktop (on-screen clock = wall time) — **not sheared/half-width, so
  `u32PicStride = width` is CONFIRMED** for the YUYV handoff.
- **Teardown + in-process re-init.** `kvmv_deinit` → re-init → capture again in
  one process: **both cycles produce a full IDR+P** (suspend/resume works). The
  one wrinkle: the `isp_model_manger_list` CMM carveout isn't freed by teardown,
  so `cmm nr6` returns EPERM on re-init; the block stays valid, so we tolerate
  EPERM and proceed (fix in `kvm_capture_open.c`).

**The integration finding that shaped the final design:** a maximally-blob-free
capture (Stage 6 replaced *all* userspace incl. libax_sys) does **not** compose
with the vendor encoder. `AX_VENC_Init` returns `AX_ERR_NOT_INIT` (0x80070212)
unless `AX_SYS_Init` (libax_sys) has run, and `libax_venc` also references
`AX_VIN_PRIV_FindMeStat` (libax_proton) + `AX_IVPS_*` (libax_ivps). So the
shipped shape of the fold is: **our capture code calls no AX libs (raw ioctls);
the process keeps libax_venc/sys/ivps/proton for the closed ENCODER and drops
only libax_mipi.** `kvm_capture_open.c` calls `AX_SYS_Init`/`AX_SYS_Deinit` (the
sole vendor-lib calls, for the encoder's benefit). Fully shedding proton/sys/ivps
is the separate encode gate — the encoder is precisely what still pins them.

**Build-verified**: both variants cross-compile clean for aarch64
(`nix build .#kvm-encoder`; open variant via `openCapture = true`), max GLIBC
symbol 2.17 (loads on the target's 2.35). Open `libkvm.so` DT_NEEDED =
libax_venc/sys/ivps/proton (+opus/asound/libc); libax_mipi dropped.

**Known limitations / residuals**:
- ~~**1080p-only.**~~ **Superseded 2026-08-17 (#17)** — the geometry-bearing
  payloads are now generated per-resolution by `kvm_capture_geom.c`; see
  "Parametric geometry" at the end of this document. (Was: the captured
  selector payloads baked in 1920×1080 and any other resolution was clamped.)
- **The `isp_model_manger_list` phys is now derived at bring-up (#16,
  2026-08-16):** reuse-before-allocate — an existing named block is adopted
  from `/proc/ax_proc/mem_cmm_info`; only when none exists does `cmm nr0`
  allocate, and the real phys is then read back from `/proc`. The captured
  constant `ISP_MODEL_PHYS` (0x74846000) survives only as a loudly-warned
  fallback. (Device finding: cross-session the kernel does *not* EPERM a
  duplicate nr0 — it allocates another 4 KB block, so alloc-then-tolerate
  would leak one block per warm cycle; reuse caps it at one per boot.)
- **Teardown is device-validated (#16, 2026-08-16):** three warm
  suspend/resume cycles — every teardown selector returned 0, the VB pool
  freed and re-created at the same base each cycle, the isp_model block held
  at exactly one instance, capture returned live frames every time. The
  isp_model block itself is intentionally persistent (no CMM-free selector is
  mapped); the reuse path re-adopts it and tolerates the `cmm nr6` EPERM.
- **The stray-handle path in `kvm_cap_get` now releases the dequeued frame**
  before erroring, so repeated stray handles can no longer starve the 4-block
  pool.

(Post-review fix: SetDevAttr#2 now sends the vendor's distinct `nr21b` bytes, so
the whole bring-up is byte-faithful to the captured vendor path.)

### 2026-08-17 — first live-use bugs of the open backend (green bar + scrolling; VENC fps=0)

First real-world session on the open backend (v2.1.0-alpha.1) surfaced three
symptoms: a green bar at the top of the image, a fast apparent horizontal
scroll, and a permanent black screen after a browser refresh. All three are
fixed and device-verified; the diagnoses matter for the record:

- **Green bar + scrolling = one bug: the hand-derived frame phys was wrong.**
  `kvm_cap_get` computed `pool_base + blkidx * BlkSize`. Dumping the live
  `comm_pool_0` region over `/dev/mem` showed the real CMM layout is
  `[BlkCnt × MetaSize meta pages][blk0][blk1]…` with data blocks at a
  **page-aligned pitch** (`ALIGN_UP(BlkSize, 4096)`), so the old formula
  pointed `16384 + 2048·idx` bytes *before* each real frame: the encoder ate
  the zeroed meta pages as the first ~4 lines (green bar — YUV zeros decode
  green) and each of the 4 cycling block indexes landed at a different
  horizontal phase (the "scroll"). Why Stage 6 missed it: the single-frame A/B
  compared two grabs computed with the *same wrong formula* — a common-mode
  offset cancels. The fix asks the documented API instead:
  `AX_POOL_Handle2PhysAddr(handle)` — device-verified to work fine for a pool
  created via raw ioctl (the handle is kernel-global state) and to agree
  exactly with the measured layout, which is kept as a bounds-checked fallback.
  `find_cmm_block` now matches `comm_pool_0` (not any `comm_pool*` substring)
  and the base is re-derived on every `kvm_cap_start`.
- **Black screen after refresh = VENC rebuilt with fps=0.** The web UI's
  default video setting is `fps: 0` ("auto") and it POSTs the full settings
  sequence on every page load; `kvmv_set_rate_control` intentionally destroys
  the live channel to apply the new mode, and the rebuild then used the raw
  stored 0 → `AX_VENC_CreateChn` = `0x8007020A` (`AX_ERR_VENC_ILLEGAL_PARAM` —
  the VC8000E rejects a zero frame rate), retried by the Go streamers at
  120 Hz forever (once: a 470 MB log). Only a *fresh* pipeline init healed
  `s_fps` from `/proc/lt6911_info`, which is why the first refresh after a
  suspend worked and the second wedged. Now fps 0 is a sentinel resolved from
  the live source at every channel (re)build (`effective_fps_locked`), a
  failed create destroys the half-created channel (else `AX_ERR_VENC_EXIST`
  forever) and arms a 500 ms cooldown, `kvm_venc_create` clamps fps/gop as a
  last line of defence, and the Go stream loops back off to 1 Hz after 30
  consecutive failed reads (`pkgs/nanokvm-server.nix`).
- `init_pipeline_locked` now refuses 0×0 geometry (HDMI unlocked) instead of
  building a 0-byte pool and looping on `AX_ERR_VIN_ILLEGAL_PARAM`
  (`0x8011010A`) — that sibling loop is in the vendor-backend logs of
  2026-07-20.

### 2026-08-17 — Parametric geometry: the open backend is no longer 1080p-only (#17)

The blob-free capture backend used to clamp every source to 1920×1080 because
the captured selector payloads baked that geometry in. It now derives every
geometry-dependent byte from the live `/proc/lt6911_info` source size.
`pkgs/kvm-encoder/src/kvm_capture_geom.{c,h}` owns that math;
`kvm_capture_open.c` just consumes it.

**Where geometry actually lives on the wire.** Re-derived mechanically by
scanning every captured payload for `u32` words equal to 1920/1080 (at *any*
alignment) and cross-checking against the field the vendor-MPI backend fills
for the same call in `kvm_pipeline.c`:

| payload | width | height | stride |
|---|---|---|---|
| os_mem nr1 descriptor | word 0 | word 1 | — |
| pool nr22 floorplan | — | — | `BlkSize@0x30 = stride·h·2` |
| proton nr17/nr21 dev attr (376 B) | `@0x58` | `@0x5c` | `@0xdc` |
| proton nr21 dev attr **#2** (376 B) | `@0x58` | `@0x5c` | — (stays 0, as captured) |
| proton nr35 CreatePipe (76 B) | `@0x1c` | `@0x20` | — (0 in the capture) |
| proton nr42 SetPipeAttr (76 B) | `@0x1c` | `@0x20` | `@0x24` |
| proton nr48 SetChnAttr (48 B) | `@0x08` | `@0x0c` | `@0x10` |

Everything else is resolution-invariant and stays byte-verbatim. Notably the
**MIPI nr2 `SetAttr` payload carries no geometry at all** — it is
`{idx, lanes=4, rate=0x258, lanemap}`; the DPHY link runs at a fixed
600 Mbps/lane at every resolution (the vendor-MPI backend hardcodes the same
`KVM_MIPI_RATE=600`). Issue #17 listed `PL_mipi_attr` as 1080p-baked; it is not.
The ISP-bypass config payloads (nr56/74/54/89), the dev binds (nr30/nr22), nr55
and the nr101 frame descriptor contain no geometry words either.

**The regression constraint and how it is proven.** The device can only be
tested against a 1080p source, so 1080p bit-identity with the device-proven
constants is the only hardware-checkable property. It is proven mechanically,
not by inspection: `pkgs/kvm-encoder/src/tests/geom_identity_test.c` holds the
pre-change payload arrays (extracted programmatically from
`97507e3:kvm_capture_open.c`) and byte-compares them against
`kvm_geom_build(1920,1080)`, plus the descriptor words, `BlkSize`, block pitch,
pool span, `MetaSize` and `BlkCnt`.

```
nix build .#checks.x86_64-linux.open-capture-geometry -L
```

The check phase fails the build on any difference (verified by mutation: moving
one field offset makes it fail with the exact differing bytes). It also pins
1280×720 and 1366×768 golden vectors and the accept/reject envelope so a later
refactor cannot silently drop a field back to its 1080p constant.

**Supported envelope.** Even width and height (a YUYV macropixel is 2 px),
64×64 minimum, **3840×2160 maximum** (raised from 1920×1200 on 2026-08-31 —
see the 4K30 stage entry below; the old "4 lanes × 600 Mbps DPHY link budget"
reasoning was WRONG: nDataRate=600 is a PHY timing band, the D-PHY is
source-synchronous, and the vendor path captures 4K30 over the same link).
Out-of-envelope geometries are **refused** (bring-up returns an error and logs
the reason) rather than clamped: clamping is what produced #17's garbage
frames, because it drives the pipe at a resolution the source is not sending.

**Assumptions made where the RE record is silent.** The only full-struct vendor
capture that exists is 1080p, so no vendor bytes for another resolution have
ever been observed. Each assumption is a no-op at 1920×1080:

1. The three "second width" fields (dev attr `@0xdc`, nr42 `@0x24`, nr48
   `@0x10`) are line strides **in pixels** — they equal the width in the
   capture, sit immediately after a `{width,height}` pair, and correspond to
   the single `nWidthStride` the vendor-MPI structs set for those same calls.
2. ~~Stride is padded up to 16 px (32 B) — `KVM_GEOM_STRIDE_ALIGN`.~~
   **RESOLVED 2026-08-31 (the knob is now 2, stride == width):** the encoder
   reads input lines packed at the TRUE width — a 1376-px-stride fill of a
   1366-wide encode sheared exactly 10 px/row through the open encoder — and
   the vendor MPI programs `nWidthStride = w` at every VIN stage. See the
   2026-08-31 stage entry.
3. CreatePipe (nr35) genuinely has no stride field — the captured bytes at
   `@0x24` are zero for nr35 while nr42's are `0x780`.
4. The vendor's second `SetDevAttr` keeps `@0xdc` and the `{01,02,03}` lane
   bytes zeroed; only its width/height are parameterised.
5. The os_mem nr1 **flag byte** stays `0xf0`. The Stage-3 differential table
   shows it varying across configs (`0xf0` 1080p H.264 / `0x70` 720p H.264 /
   `0x00` 1080p MJPEG) but it was never decoded and does not track resolution
   alone. If a non-1080p bring-up fails at the allocator, this byte is
   suspect #1.
6. `nr54 partition_info` is replayed verbatim. Its first word is
   `00 06 01 00` and the remaining 176 bytes are zero; whether any of it is an
   ISP line-partition width tied to 1920 is undecoded. Second suspect if the
   pipe hangs at a non-1080p geometry.

**Build wiring.** `pkgs/kvm-encoder.nix` compiles `kvm_capture_geom.c` only on
the `openCapture` path — the vendor-MPI build is untouched, and byte-identical:
the vendor `libkvm.so` built before and after this change has the same SHA-256.
New flake outputs: `kvm-encoder-open` (libkvm.so with `openCapture = true`, for
building/type-checking the open path on demand) and `kvm-encoder-geom-test` /
`checks.<system>.open-capture-geometry`.

**Still untested on hardware:** everything except 1080p. The device has no
non-1080p source available; the first 720p bring-up should be watched for the
allocator flag byte (assumption 5), the nr54 partition struct (6) and shearing
(2), in that order.

### 2026-08-22 — §8 device tracing: VC8000E VCMD encoder ABI confirmed on hardware (ATX .221)

Ran §8 experiments 1–3 (the read-only/trace-only set) on the live ATX unit to
confirm the §§2–3 static findings against real silicon. Device stayed healthy
throughout — uptime unbroken, no encoder hang, no watchdog reboot;
`nanokvm.service` active and web UI 200 at start and end. A real H.264 lifecycle
was driven headless via `libkvm` ctypes (`kvmv_init` → `kvmv_read_img(1920,1080,
type=3)` → `kvmv_deinit`; real I-frame + P-frame emitted), with an LD_PRELOAD
tracer (`axvenctrace.so`, magic-`'k'` filter, arg reads via `/proc/self/mem`
`pread` at the exact `_IOC_SIZE` — no fixed-size over-read, the trap that bit the
capture stages).

Method verified off-device by review of the tracer + decoder source (in the
session scratchpad): the `nr`/`dir`/`size` decode is the standard Linux `_IOC`
layout, so the map below is a clean decode of a real trace. Traces themselves
live in device tmpfs `/tmp/axwork` (`venc1.log`, `venc3.log`) — re-runnable, not
persisted.

**Exp 1 — venc `nr` → `HANTRO_IOCH_*` map (confirms §§2–3, 1:1).** Every ioctl to
`/dev/ax_venc`/`/dev/ax_jenc` is magic `'k'` (0x6b). Traced `nr`/dir vs the public
revyos/eswin `vc8000_driver.h`:

| nr | dir | public `HANTRO_IOCH_*` | match |
|---|---|---|---|
| 25 | IOWR | `GET_CMDBUF_PARAMETER` | ✓ |
| 28 | IOWR | `GET_VCMD_PARAMETER` | ✓ |
| 29 | IOWR | `RESERVE_CMDBUF` | ✓ |
| 30 | IOR | `LINK_RUN_CMDBUF` | ✓ |
| 31 | IOR | `WAIT_CMDBUF` | ✓ |
| 32 | IOR | `RELEASE_CMDBUF` | ✓ |
| 50 | IOWR | `GET_VCMD_ENABLE` | ✓ |

Every **core VCMD ioctl matches the public driver in both `nr` and direction.**
Observed lifecycle order matches §2: Init (`GET_VCMD_PARAMETER`/`GET_CMDBUF_
PARAMETER`) → per-frame `RESERVE_CMDBUF`(29) → `LINK_RUN_CMDBUF`(30) →
`WAIT_CMDBUF`(31) → `RELEASE_CMDBUF`(32). Axera-extension `nr`s also seen (51, 70,
71, 72, 79–83, 86–89 — channel/clock management, outside the public cmdbuf set;
not needed to port the core ABI). **Correction to a possible §2 misreading:** the
uniform `size=8` is *not* an Axera re-encoding — the public macros are themselves
pointer-typed (`struct config_parameter *`), so `_IOC_SIZE = sizeof(pointer) = 8`
on 64-bit. The args are pointers to the *standard public structs*, byte-compatible
(e.g. jenc `GET_VCMD_PARAMETER` arg begins `03 00 01 00…` = `config_parameter.
module_type=3`).

**Exp 2 — VCMD command buffer for one H.264 frame (confirms §3).** The VCMD pools
are DMA-coherent CMM carveouts (`venc_ko`/`jenc_ko` in
`/proc/ax_proc/mem_cmm_info`), **dynamically allocated per `kvmv_init`** (phys
differs each run). Decoded a textbook Hantro cmdbuf: `RREG` preamble → a large
`WREG` burst into the encoder ASIC register bank → strided sub-block writes →
`STALL` (wait-for-core) → `RREG` into the status pool → end/poll. The load-bearing
cross-check: **cmdbuf `swreg11` (input-luma base) = `0x73c45000`, the exact
capture-pool frame phys** — independent proof the decode is real and that capture
feeds the encoder by raw physical address. All addresses in the cmdbuf are raw
physical DRAM. *Caveat:* the decoder's VCMD opcode-mnemonic table (`pooldump2.py`)
labels `RREG=0x0C`, whereas public `vcmdswhwregisters.h` uses `RREG=0x16`; the
`WREG=0x01` decode (addr + 10-bit length) that the conclusions rest on is correct,
but treat the exact non-WREG opcode labels as unconfirmed.

**Exp 3 — `hw_version_id` + config.**
- **`hw_version_id = 0x43421500`** (`0x4342` = the VeriSilicon VCMD signature;
  public `HW_ID_1_0_C = 0x43421001`, so **same family, revision ~1.5.0**).
  Build-date register `0x20221012` (2022-10-12). `ax_venc` = V3.0.0_20250319,
  modinfo "VC8000 Vcmd driver"; `ax_jenc` = "VC9000 Vcmd driver". `/proc/iomem`:
  `vsi_vcx@0x04010000`, `ax_jenc@0x04000000`.
- **MMU/IOMMU: OFF** — the cmdbuf programs raw physical addresses directly into
  the ASIC registers (no translation). A port must feed raw phys, not IOVAs.
- **Single VCMD core.** H.264 confirmed working (I + P); JPEG is the same driver
  (`ax_jenc`).
- **Which public driver to port:** the **eswin `linux-6.6.18-EIC7X`
  `vc8000_vcmd_driver.c`** (handles `HW_ID_1_2_1`+, closest to `0x43421500`) with
  `vcmdregistertable.h` / `vcmdregisterenum.h` / `vcmdswhwregisters.h` from the
  same tree; the revyos copy (gated to the older `HW_ID_1_0_C`) is a second
  reference.

**Two new hardware facts (not in §§1–7):**
1. **MMIO clock-gating.** The venc/jenc register windows (`0x04010000` /
   `0x04000000`) read `0xdeadbeef` via `/dev/mem` whenever idle — the VPU power
   domain gates within µs of each synchronous frame. Post-hoc CPU register reads
   are therefore impossible; the only CPU-visible register state is the
   DMA-coherent DRAM pools (where `hw_id`/cmdbuf/status live). This is why the
   VCEnc *encoder-core* AsicConfig bitmap (max width, codec bits) was **not**
   cleanly extracted — a follow-up must decode it from the status-pool readback
   region (status+0x2800, first word `0x90101010`) against `encswhwregisters.h`,
   not from live MMIO.
2. **Cmdbuf mapping path.** Userspace maps the VCMD pools via **`/dev/mem`** at
   their phys (there were **zero** mmaps on the `ax_venc` fd), not
   `hantrovcmd_mmap`. A from-source port must either expose the pool phys to
   userspace or provide `hantrovcmd_mmap` — a small but real divergence from the
   stock upstream mmap path.

**Net.** §3's headline — the venc kernel↔user contract is *recoverable from public
source* — is now hardware-confirmed, and the target driver revision is pinned
(eswin EIC7X). The residual hard problem is unchanged and remains **userspace rate
control** (§§5–7), plus the licence-encumbered VCEnc core. Remaining §8 items 4
(RC observability) and 5 (`/dev/mem` register-diff) are not yet run; item 5 is
now known to be constrained by the idle clock-gating above (registers read
`0xdeadbeef` unless sampled mid-frame).

### 2026-08-22 — §8.4 RC observability: the CBR controller is stock VCEnc, characterized (ATX .221)

Ran §8 item 4 (the high-value one — it tells us what a from-source rate controller
must reproduce) on the live ATX unit, read-only, device healthy throughout. Drove
the encoder headless via `libkvm` ctypes at three CBR targets (2000 / 8000 / 16000
kbps, 90 frames each, GOP 30, 59 fps source, static 1080p desktop) and logged
per-frame QP + size plus the vendor RC debug strings. (Item 5 — AsicConfig fuse
readback — is NOT yet recorded: its capture run died on a transient SSH auth drop
and produced no verifiable register words; pending a clean re-capture.)

**The CBR path is stock VeriSilicon VCEnc rate control, not a heavy Axera layer.**
The vendor `H26xSetRcParam` debug line is the standard `VCEncRateCtrl` field set:

```
setRcParam, vbr 0 qp 36 qpRange I[10,51] PB[10,51] 2000000 bps pic 1 skip 0
  hrd 0 cpbSize 4000000 bitrateWindow 30 intraQpDelta 0 fixedIntraQp 0, idr length=30
```

- `vbr 0` = CBR; `bps` = target; `cpbSize = 2×bitrate` (a 2-second CPB/HRD buffer);
  `bitrateWindow = 30` = the GOP-length averaging window; `qpRange [10,51]`.
- **Initial QP is seeded from the target bitrate:** SPS `pic_init_qp` = **36 / 32 / 26**
  for 2 / 8 / 16 Mbps. This is the only bitrate-dependent knob at start.
- `AX_VENC_GetRcParam` returns the stock struct verbatim (byte-legible: target kbps
  at one offset — `d0070000`=2000, `401f0000`=8000, `803e0000`=16000 — GOP `1e`=30,
  QP range `0a`/`33` = 10/51), identical before/after — pure userspace RC state.

**Per-frame behaviour (the reference trajectory a from-source controller must match):**
- Right after each I-frame the P-QP starts high (35–40) and **ramps monotonically
  down across the GOP** toward a floor, then flattens — classic one-pass CBR draining
  then refilling the CPB buffer. Example @8 Mbps GOP1: F2 qp35 → F15 qp21, flat at
  qp21 (~8.7 KB/frame) through F30.
- The floor **descends across successive GOPs** as the controller converges
  (@8 Mbps: 21 → 19 → 17 over the three GOPs); I-frame QP likewise drifts down
  (32 → 30 → 28).
- **Content saturation is the headline.** Effective delivered bitrate: **1.95 Mbps**
  @2000 target (tracks), but only **5.9 Mbps** @8000 and **6.2 Mbps** @16000 — the
  8 k and 16 k runs are nearly QP-identical because a near-static desktop cannot
  fill the budget; the QP simply bottoms out at a content-determined floor. So the
  RC genuinely targets bitrate when content allows and QP-floors when it can't.
- The vendor lib also runs a `SceneChangeCheck` heuristic (logs "scene change ratio
  95") — a thin scene-change→IDR/QP-bump detector in the `H26x` glue, benign for a
  static screen.

**Verdict — the rate-control wall is real but bounded for CBR-KVM.** The exercised
path is stock VC8000E one-pass CBR (`VCEncSetRateCtrl` + the standard `VCEncRateCtrl`
fields); Axera's `H26xSetRcParam`/`SceneChangeCheck`/`VencUpdateChnVariables` are
thin marshaling + framerate bookkeeping + a scene-change heuristic, not a bespoke
adaptive core. The proprietary `AXRc*` AVBR/CVBR/QVBR modes (§2) were **not** used by
our CBR path — that is presumably where Axera's custom RC lives, but we don't need it.
A from-source "good enough" KVM CBR controller therefore has to reproduce only: (1)
bitrate→initial-QP seeding, (2) a per-frame QP feedback loop steering encoded size to
the `bitrate/fps` budget within `[qpMin,qpMax]` under a 2 s CPB model, (3) an I-frame
QP offset (`intraQpDelta`), and optionally (4) a scene-change→IDR trigger. We now have
a measured reference trajectory to validate such a controller against. This
meaningfully de-risks the §§5–7 "rate control is the historically hardest part"
framing: for our use case it is a bounded, fully-observed feedback loop — with
fixed-QP as the trivial fallback (acceptable for a mostly-static screen).

### 2026-08-22 — §8.5 VCEnc encoder-core AsicConfig recovered (ATX .221)

Closes the open AsicConfig item from the "§8 device tracing" stage above. The
VC8000E encoder-core register image is mirrored to DRAM in the VCMD register pool
(readable via `/dev/mem` despite the idle MMIO clock-gating). Primed 6 H.264 frames
via `libkvm`, located the image by its `swreg0 = 0x90101010` marker at phys
`0x7381c800`, and dumped `swreg0..319` with absolute phys per word (raw artifact
preserved and re-decoded independently). Base alignment is anchored by two
cross-checks in the same dump: `swreg8 (+0x20) = 0x749ce028` (output stream base,
matching the vendor ringbuffer log) and **`swreg12 (+0x30) = 0x73c45000` (input
luma = the capture frame phys)** — so the fuse offsets below are genuinely the
encoder register image, not stray memory.

The four `EWLReadAsicConfig` fuse words (`swreg` word-index → byte = index×4):

| swreg | byte | raw | decode |
|---|---|---|---|
| 80 | 0x140 | `0x88da4280` | **H264=1, HEVC=1**, JPEG=0 (separate `ax_jenc` core), busType=6 (AXIAPB), busWidth=128-bit, CAVLC=1 |
| 214 | 0x358 | `0x48500800` | roiAbsQp=1; `maxEncodedWidth` field (unit ambiguous — see caveat) |
| 226 | 0x388 | `0x00a19200` | **ctbRcVersion=1** (HW supports CTB/row-level rate control) |
| 287 | 0x47c | `0x00000000` | videoHeightExt / cscExt / scaler420 = 0 |

Capability cross-check: `0x88da4280 & 0x88000000 = 0x88000000` lights up exactly
bit31 (H264) + bit27 (HEVC), and `& 0x00008000` (JPEG) = 0 — a coherent, probe-
matching bitmap, not a random RW register. This refines the §8 hardware facts:
**single VCMD core, H.264+HEVC in the video core, JPEG on the separate `ax_jenc`
core, ≥1080p capable, no MMU by config.** `ctbRcVersion=1` is a useful RC datum —
the HW offers CTB/row-level rate control a from-source controller *could* exploit,
though the frame-level CBR loop of §8.4 does not need it.

**hw-ID clarification.** The `hw_version_id = 0x43421500` recorded in the first §8
stage is the **VCMD command-engine** ID (product `0x4342`, decode → v1.5.0), *not*
the VCEnc encoder-core ID — the two live in different register windows (VCMD engine
vs the encoder core at VCMD_base+0x1000) and use different version-nibble layouts.
The encoder-core capability set is the AsicConfig fuse block above, not the VCMD ID.
This does not change the port-target guidance (eswin EIC7X `vc8000_vcmd_driver.c`).

**Caveats.** (1) The `maxEncodedWidth` unit is genuinely ambiguous in VeriSilicon's
own header (documented as both "pixels" and "unit = 8 pixels", version-dependent),
so treat any absolute width figure as provisional — qualitatively ≥1080p. (2) This
is a driver register *image mirrored to DRAM*; the coherent decode plus the
`0x88000000` probe-mask match are strong evidence it is the genuine fuse config, but
strict proof would be a live read of `VCMD_base+0x1000+0x140` during `EWLInit`.

### 2026-08-22 — VCEnc open-reimplementation feasibility: GO for H.264 (medium-high)

Assessed whether a genuinely from-scratch, openly-licensed VCEnc core is buildable
— independent host software that programs the VC8000E registers to emit valid H.264,
driving the fixed-function silicon directly, using only public register knowledge +
device observation (no proprietary VCEnc core, no EULA source). This supersedes the
pre-§8 "impractical" verdict (§6 item 4), which predated the tracing phase. All work
read-only (`/dev/mem` + headless libkvm); device left healthy. Reference dumps +
tooling preserved under `docs/reference/vcenc-open/` (provenance + clean-room posture
in its README).

**Verdict: GO for H.264, medium-high confidence**, staged from a fixed-QP I-frame PoC.
Two honest qualifiers: (1) the hard remainder is not register programming but
**P-frame reference/DPB state + CBR rate control** — both bounded but real; (2)
"openly-licensed" forces **clean-room-via-observation** discipline, because the best
register/RC docs found (VeriSilicon `registertable.h`) are confidential/proprietary.

**Decomposition — silicon does the hard DSP.** Intra/inter prediction, motion
estimation, mode decision, transform/quant, CABAC/CAVLC, deblocking, reconstruction
are all in the VC8000E, which emits complete slice NAL payloads. An open core produces
only host bookkeeping per frame: the ASIC register program (a fixed template + a small
delta), reference-picture/CMM buffer management, SPS/PPS NAL generation (standard,
unencumbered), VCMD command-buffer assembly + submission over the public Hantro ioctls
(nr 29/30/31), and rate control (a software QP loop, or fixed-QP for v1). The KVM
envelope narrows it hard: 1080p, single-reference IPPP, one slice, low-latency.

**Evidence — the register-program differential (device-measured, independently
re-verified in this repo).** Captured the full encoder register image (swreg0..319)
at 2000 (×2 repeats), 8000, and 16000 kbps and diffed:

| Comparison | Registers differing |
|---|---|
| 2000 vs 2000 (same config — **noise floor**) | **1** (swreg82, a HW cycle counter) |
| 2000 vs 8000 kbps | 20 |
| 8000 vs 16000 kbps | 7 |
| **Invariant template** | **300 of 320** |

Every moved register is in the QP/rate-control cluster: `PIC_INIT_QP` (QP 36→32→26,
matching §8.4's SPS `pic_init_qp`); `TARGETPICSIZE`/MIN/MAX (swreg105–107) = **440000
/ 1760000 / 3520000, exactly linear in bitrate**; QP-derived lambda LUTs; CTB-RC model
state (`CTB_RC_MODEL_PARAM`, `PREV_PIC_LUM_MAD`, `CTB_QP_SUM`); and HW-written output
counters (`QP_SUM`, `TOTAL*` bit counters, `HW_PERFORMANCE` = the lone noise-floor
register). Image alignment is anchored by `OUTPUT_STRM_BASE` (= the vendor ringbuffer
phys), `OUTPUT_STRM_BUFFER_LIMIT` (= the captured NAL length), and `INPUT_Y_BASE` (=
the capture-pool frame phys). So the per-frame program is a stable ~94% template plus
a ≤20-register, semantically-clean, largely-computable delta. The register-programming
problem is not the wall. (The open header `rate_control_picture.h` documents the RC
state — `linReg` QP↔bits model, leaky-bucket HRD, `ctbRcModel.preFrameMad` → the
observed swreg247 — so header structure, §8.4 behaviour, and registers agree.)

**Hard parts / unknowns, rated by threat.**
1. **P-frame reference/DPB register state — MEDIUM-HIGH, the main open gap.** Not yet
   observed (the DRAM mirror at the first marker holds the IDR/setup program; the
   early-frame captures hadn't emitted a P-frame). Off the I-frame PoC path; must be
   characterized by decoding a P-frame command buffer (Stage 0). Characterizable by
   observation — no known blocker, just unobserved.
2. **CBR rate control — MEDIUM (bounded).** Entirely software (no bitrate register, no
   HW CBR mode); algorithm family documented + measured (§8.4); a BSD-3 sibling
   reference exists (STM32Cube `H264RateControl.c`, same linReg/virtual-buffer model);
   **skippable via fixed-QP for v1.**
3. Fixed-template completeness for arbitrary geometry — LOW/MEDIUM (KVM config is fixed;
   start from the captured template, vary only addresses + QP).
4. SPS/PPS/slice-header emission — LOW (standard; HW emits the slice payload already).
5. VCMD cmdbuf assembly — LOW/MEDIUM (public format, decoded in §8; non-WREG opcode
   labels still to confirm).
6. **HEVC — DEFER.** Fuse confirms HW support; same framework, more DPB/RPS/CTU
   complexity. Assess after H.264 IPPP.
7. **Clean-room / licensing — MEDIUM, strategic not technical.** Implementation must
   rest on our own device observations (`docs/reference/vcenc-open/`), the H.264 spec,
   and permissive references — not the proprietary `registertable.h` or vendor DWARF.
8. Loose ends (LOW): dump truncated at swreg319 (core spans ~0..400, ~75 uncaptured);
   the `0x90101010` marker identity; the `HWMAXVIDEOWIDTH=640` fuse contradiction;
   idle clock-gating blocks live-MMIO cross-check (DRAM mirror only).

**Staged plan (cheapest first).**
- **Stage 0 — finish the static picture (days, on-device, read-only).** Extend the
  dump to swreg400; capture the ioctl sequence + decode the VCMD **WREG order** for one
  IDR (the one thing no header gives); decode a **P-frame** cmdbuf to observe the
  reference/DPB registers (resolves hard-part #1). First experiment: drive one fixed-QP
  frame under `axvenctrace` + dump the cmdbuf/status/register pools → annotated WREG
  program for the IDR. Pure extension of tooling already in `docs/reference/vcenc-open/`.
- **Stage 1 — PoC (2–4 wks).** Record-and-replay **one fixed-QP IDR** in open code,
  keeping the vendor `ax_venc.ko` (public ioctl ABI — no kernel work yet): allocate CMM
  buffers, assemble the cmdbuf from the Stage-0 template with our own YUV input phys +
  chosen QP, submit via ioctls 29/30/31, retrieve the NAL, wrap with our own SPS/PPS,
  decode. **Milestone: an open-generated fixed-QP IDR that a standard decoder renders as
  the correct 1080p frame.**
- **Stage 2 — IPPP fixed-QP (1–2 mo).** Reference management + P-frame register program.
- **Stage 3 — CBR (1–2 mo).** Reimplement linReg + leaky-bucket from §8.4 + BSD ref.
- **Stage 4 — open EWL + port the eswin VCMD kernel driver (weeks)** to drop the vendor
  `.ko` (clock/reset/power already open in-tree — no RE). This is issues #44/#45.
- **Stage 5 — HEVC (assess after Stage 3).**

**Smallest end-to-end proof:** one open-code-generated fixed-QP IDR NAL, submitted
through the public VCMD ioctls with our own YUV input, that a standard H.264 decoder
accepts as a correct 1080p frame. If Stage 0's cmdbuf decode and Stage 1's replay land,
confidence flips medium-high → high.

### 2026-08-22 — Stage 0 complete: IDR WREG order + P-frame DPB state decoded (ATX .221)

Ran the full Stage-0 program (read-only, on-device). All three deliverables landed and
were re-derived from the preserved raw dumps in a separate verification pass. Device
healthy throughout — `nanokvm` active, web 200, uptime monotonic (no watchdog reboot).
Method: one `libkvm` session (`kvmv_init` → GOP 30 → 40+ `kvmv_read_img(1920,1080,
type=3, 8000 kbps)`), venc_ko VCMD pool bases parsed **live** from
`/proc/ax_proc/mem_cmm_info` (dynamic per run), snapshots taken *after* the IDR and after
a late P-frame returned (encode complete = DRAM mirror settled). Tool + dumps preserved
under `docs/reference/vcenc-open/stage0/` and `tools/stage0dump.py`.

**This resolves the feasibility study's one MEDIUM-HIGH gap (P-frame reference/DPB
state). H.264 confidence flips medium-high → high** — the static picture is now complete;
what remains for a PoC is buffer management, not observation.

**Deliverable 1 — register image extended swreg319 → swreg400.** Beyond the old cutoff
the only nonzero register is **swreg320 = 0x00000400** (constant across all 7 ring slots,
both IDR and P snapshots); swreg321..400 are all zero. The active encoder-core register
file effectively ends by ~swreg320. Tail matches §8.5 (swreg319 = 0x00060460).

**Deliverable 2 — VCMD WREG submission order for one IDR** (`stage0/idr_wreg_order.txt`,
decoded from `stage0/cmdbuf_IDR.txt`; IDR confirmed by swreg11 frame_num=0, swreg191
type=0x14000000, swreg12 input-luma=0x73c45000 = the capture-pool frame phys). The
encoder-core register base is **ASIC byte 0x1000**, so image `swregN` = ASIC byte
`0x1000 + N·4`. Ordered program:
1. `RREG` len=1 @VCMD 0x68 → DRAM (param-block preamble).
2. **`WREG` 511 words @ASIC 0x1004 = image swreg1..511 in one ascending burst** (swreg0 =
   0x90101010 is the read-only ASIC-ID, never written; swreg321..511 are zero-fill).
3. `WREG` len=1 @ASIC 0x2800, then **16× `WREG` len=1 @ASIC 0x2014, 0x2034 … 0x21f4**
   (stride 0x20) — a *secondary register bank* at ASIC 0x2000, NOT part of the encoder-core
   image. Purpose unconfirmed; a replay must reproduce these pokes.
4. **`WREG` len=1 @ASIC 0x1014 = image swreg5, written LAST = the encode kick** (swreg5 =
   0x3c044302 IDR / 0x3c044300 P — low byte is the frame-type/enable field).
5. `STALL` (wait-for-core) → `RREG` 512 words @ASIC 0x1000 → DRAM `0x7381c800` (reads the
   core registers back = the "register image" we dump) → `CLRINT` ×2 → `RREG` status → end.

Load-bearing clarification: **the `0x90101010`-marked "register image" is the post-encode
RREG *readback* (step 5), not the SW program; the WREG burst (step 2) is the program.**
They agree word-for-word except swreg1 (a HW status-writeback reg) — the cmdbuf WREG
payload matched the register image on 510/511 words including every DPB register.
Opcode-label caveat (unchanged from §8): the decoder's non-WREG mnemonics are unreliable,
but the RREG *destinations* are the exact DRAM pool phys we independently know
(`0x7381c800` register image, `0x7382a000` status), which self-confirm the interpretation.
The WREG addr/len decode (the load-bearing part) is trustworthy.

**Deliverable 3 — P-frame reference/DPB register state (the main open gap).** Captured a
7-slot ring of consecutive frames (frame_num 0..6) in one coherent snapshot
(`stage0/ring_slots_P.txt`, backed by `stage0/regimg_P_m0..m6`) plus an IDR-vs-P
53-register diff (`stage0/diff_IDR_vs_P.txt`). The decisive evidence: reordered by
frame_num, **swreg18 (reference luma) = the *previous* frame's swreg15 (recon luma) at
every step**, recon buffers ping-ponging `0x74de5000` ↔ `0x75003000` — textbook
double-buffered single-reference IPPP. DPB register map (independently re-verified from
the raw ring dumps):

| swreg | role | evidence |
|---|---|---|
| swreg15 / swreg16 | current recon luma / chroma base | ping-pong 0x74de5000↔0x75003000, 0x75221000↔0x75320000 |
| **swreg18 / swreg19** | **reference (L0[0]) luma / chroma base** | = previous frame's swreg15 / swreg16 across all 7 slots |
| swreg60/62, swreg64/66 | current / reference auxiliary recon (compressed-ref / colmv class) | ref = previous frame's current |
| swreg72, swreg74 | current / reference auxiliary buffer | ref = previous frame's current |
| swreg11 (= swreg192) | frame_num / POC | 0 at IDR, +1 per frame |
| swreg191 | coding type | 0x14000000 = IDR/intra, 0x04000000 = P/inter |

At the IDR (frame_num 0) the reference pointers self-point at the recon buffers (swreg18 =
swreg15 etc.) — an IDR has no real reference but HW still wants valid pointers. Other
registers newly nonzero on P (from the diff, inter state): swreg111/112/113, swreg197/198
(0xffc00000 / 0x00000e00), swreg17 (0xffd0007c). The rest of the 53-reg diff is the
expected RC/QP cluster (swreg105–107 TARGETPICSIZE, 215–223 lambda/QP LUTs) from §8.4/§8.5,
not DPB. The swreg60/62/72 exact roles (compressed-ref vs collocated-MV) are inferred from
the double-buffer discipline + VC8000E architecture, not pinned to a header name.

**Blockers for a Stage-1 fixed-QP IDR replay PoC: none newly found.** A replay now has the
full swreg0..400 IDR program, the exact WREG order (bulk swreg1..511 → secondary-bank
pokes → swreg5 kick last → STALL/readback), and the P-frame DPB semantics. Remaining work
is buffer management: allocate CMM and patch the per-run phys pointers (swreg8/10 output,
swreg12–16 input+recon, swreg18/19/64/66/74 references — all differ each run) and determine
the meaning of the ASIC-0x2000 secondary-bank writes. Kick register is image swreg5.

### 2026-08-23 — Stage 1: raw-ioctl drive — ABI recovered, RESERVE/assembly open, LINK blocked by a vendor-.ko private seam (ATX .221)

First attempt to *drive* the encoder from open code over the public VCMD ioctl ABI
(a write/drive path, not read-only: cmdbuf-pool writes + the four submission ioctls;
no MMIO-register or firmware writes). Device healthy throughout — no encoder hang, no
watchdog reboot across ~10 LINK attempts. Data + tools preserved under
`docs/reference/vcenc-open/stage1/` (our observations + our tooling only).

**Result: the milestone (a byte-identical NAL from our own submission) was NOT reached,
but the path is now precisely characterized.** What works from independent open code and
what walls off:

- **VCMD ABI fully recovered and hardware-cross-checked.** The authoritative source is
  eswin `linux-6.6.18-EIC7X` `drivers/staging/media/eswin/venc/vc8000_{driver.h,
  vcmd_driver.c}` (public, dual MIT/GPL — cited, not vendored). `struct
  exchange_parameter` (16 B): `u32 executing_time; u16 module_type; u16 cmdbuf_size;
  u16 priority; u16 cmdbuf_id/*out*/; u16 core_id; u16 numa_id`. Ioctls (magic `'k'`):
  RESERVE `_IOWR 29`, LINK_RUN `_IOR 30`, WAIT `_IOR 31`, RELEASE `_IOR 32`. Our
  on-device trace of libkvm matches byte-for-byte: RESERVE writes back `cmdbuf_size`
  (=slot cap `0x2000`) and `cmdbuf_id` at offset 0x0a; the actual program length
  (`0x8e8`, JMP-aligned) is written into `cmdbuf_size` just before LINK. Cmdbuf pool
  (from GET_CMDBUF_PARAMETER nr25, live): base `0x7380A000`, total `0x10000`, unit
  `0x2000` → 8 slots, slot(id) = base + id·0x2000.
- **RESERVE(29), RELEASE(32), and open cmdbuf assembly all work from independent raw
  ioctls** (`rc=0` on both a fresh fd and libkvm's fd). We captured the vendor IDR
  cmdbuf, matched this-run's IDR slot by its embedded physes (swreg8=0x749ce028 output,
  swreg12=0x73c45000 input), and word-copied it into a freshly-reserved slot (readback
  verified). *(Gotcha: glibc NEON/wide memcpy SIGBUSes on the non-cacheable Device
  `/dev/mem` mapping — use 32-bit word accesses only.)*
- **LINK_RUN(30) returns `-EFAULT` and the HW never runs** (swreg82 cycle counter
  unchanged, output buffer untouched — the "output identical" seen in the raw log is a
  false positive from the buffer still holding libkvm's prior frame). The arg marshaling
  is faithful (byte-diff vs the vendor's traced LINK arg differs only in `cmdbuf_id`),
  fd ownership is not it (fails on libkvm's fd and a fresh fd), and linking libkvm's own
  *native* valid slot content (no memcpy) EFAULTs identically. The public 6.6.18
  `link_and_run_cmdbuf` has no `-EFAULT` path at all, and dmesg is silent → the fault is
  in an Axera-added user-access on a suppressed-log path in the on-device 4.19
  `ax_venc.ko` (source NOT public — absent from `AXERA-TECH/ax620e_bsp_sdk` and
  `sipeed/maix_ax620e_sdk`, which ship only prebuilt `libax_venc.so`).

**Root cause (well-supported): a vendor per-frame EWL↔.ko private seam we skipped.** The
full vendor trace (`stage1/stage1_trace.log`) shows the real per-frame submission is
**nr70 (frame setup — passes a userspace VA at arg offset ~0x20) → nr83 ×2 → RESERVE(29)
→ LINK_RUN(30) → WAIT(31) → RELEASE(32)**. nr70/nr83 are Axera-extension ioctls (the
51/70–89 set noted in §8) that our out-of-band RESERVE→LINK skipped; Axera's
`link_and_run` evidently reads state they register (a userspace descriptor VA), so an
externally-reserved cmdbuf faults. This is exactly the "bounded libax_sys/CMM marshaling
seam, confined to EWL" that §§1/6 predicted — i.e. **fully-blob-free RESERVE/LINK is
properly the job of #44 (port the open eswin driver, whose LINK path is public and has no
such fault) + #45 (open EWL), not a Stage-1 deliverable.** Stage 1's own goal —
validating that our assembled register program drives a real encode — does not require
solving this and should instead be reached by **LINK-time cmdbuf-content hijack** (let
libkvm establish all vendor state and issue LINK on its own id, but overwrite the slot
contents with our assembled program + chosen QP just before its LINK). That cleanly
separates the encoder-core question (our register program) from the vendor-driver
question (blob-free submission = #44).

**Net:** the encoder can be *reserved and programmed* from open code today; *submission*
through the stock vendor `.ko` needs the nr70/nr83 setup, which the open driver port
(#44) removes wholesale. Confidence unchanged on the open-encoder feasibility; the wall
found is a driver-seam artifact, not a bitstream/register-program problem.

### 2026-08-23 — Stage 1 PoC ACHIEVED: an open register program drives the encoder to a decodable 1080p IDR (ATX .221)

Reached Stage 1's core milestone via the **LINK-time cmdbuf-content hijack** (Path B):
an LD_PRELOAD `ioctl` hook lets libkvm establish all vendor state and call LINK(nr30) on
its own cmdbuf, but rewrites the cmdbuf slot (`pool_base + cmdbuf_id·0x2000`, 32-bit
`/dev/mem` writes) with our program the instant before the real LINK — so libkvm's own
working LINK runs OUR register program. This sidesteps the vendor nr70/nr83 EFAULT seam
(→ #44) and isolates the encoder-core question. Device healthy across ~20 hijack encodes;
no hang, no reboot. Data + tools under `docs/reference/vcenc-open/stage1/` + `tools/`.

**All three milestones passed, verified independently from the artifacts:**
- **B0 (mechanism).** The hook fires at every LINK, self-copies the 570-word program into
  the correct slot; the encode completes and swreg82 (cycle counter) **advances** (HW ran
  — contrast the Stage-1 raw-ioctl attempt where it never did). Control IDR decodes to a
  sharp 1920×1080 desktop (`stage1/frame_control.png`).
- **B1 (QP control) + a real finding.** `PIC_INIT_QP` located off-device by diffing the
  committed `regs_{B2000,C8000,D16000}.txt`: **swreg7 bits[31:26] = 36/32/26** (re-verified
  in this repo — matches the §8.4 SPS `pic_init_qp`). But **`pic_init_qp` is header-only on
  this HW**: forcing swreg7 reached the bitstream (slice `SliceQP` delta changed) yet did
  **not** change frame size — the encoder recomputes `slice_qp_delta` so effective QP is
  unchanged. Capturing full IDR programs at 8000 vs 400 kbps and diffing showed the entire
  software QP difference is **13 registers: swreg7, swreg37, swreg105–107 (TARGETPICSIZE,
  linear in bitrate), and swreg125–132 (an 8-entry quant/lambda table)**. The lambda regs
  swreg219–223 are **0 in the SW program** (HW-computed) — editing them corrupts the
  stream, a useful negative result. Forcing the full 13-register block at 8 Mbps yields an
  IDR of **7839 B vs 12086 B control** (≈65%, matching a native 400 kbps encode = 7848 B to
  within 9 bytes) that decodes to a correct, visibly coarser 1080p frame
  (`stage1/frame_qpforced.png`). *Consistency requirement (expected, not a defect): the
  coarser slice decodes cleanly only with the matching PPS (`pic_init_qp` 36 vs the 8k
  stream's 32) — a from-source encoder emits header+slice together.*
- **B2 (full open-program injection).** Overwriting the ENTIRE IDR slot with an
  externally-supplied 570-word program (preserving this-run address registers, patching
  `cmdbuf_size` in the LINK arg) and running it through libkvm's LINK produces decodable
  1080p IDRs both for a self-captured 8k program and the cross-injected 400 kbps program.

**Stage 1 is done: a complete, externally-supplied VC8000E register program drives this
silicon to a valid, decodable, quality-controllable 1080p H.264 IDR — proven on
hardware.** The register-program half of a from-source encoder is no longer a question
mark; what remains is (a) blob-free *submission* (the open driver/EWL, #44/#45) and (b)
generating these programs from scratch rather than by capture-and-patch — i.e. the
from-scratch VCEnc core + CBR controller (#46/#47), with the effective-QP register block
above (swreg7/37/105–107/125–132, lambda HW-computed) as the concrete control surface a
CBR loop must drive. **Path B is now a validated on-hardware test harness** for that work:
any candidate open-generated program can be injected at LINK and decoded end-to-end.

Confidence **HIGH** — mechanism proven three independent ways, the QP-forced size matches
a native low-bitrate encode to within 9 bytes, and both frames render as correct 1080p.
Stage 2 (IPPP) is unblocked: the hook already fires on P-frame LINKs, and the DPB register
semantics are pinned (Stage 0). No new blocker.

### 2026-08-29 — #44: open VC8000E VCMD driver ported + cross-compiles against the 4.19 kernel; submission-path seam confirmed removed

The kernel half of blob-free encode *submission* is now real code. The open eswin
EIC7X VCMD command-engine driver (`github.com/eswincomputing/linux-stable`,
`linux-6.6.18-EIC7X` @ `fc6038c`, `drivers/staging/media/eswin/venc/`, dual
**MIT/GPL-2.0** VeriSilicon 2019) is vendored (VCMD subset only — 10 files; the
EIC7700 platform/AXI-FE/MMU/dma-heap layers deliberately excluded) at
`pkgs/vc8000-vcmd/eswin/` and ported out-of-tree to our kernel via
`pkgs/vc8000-vcmd.nix` (flake output `.#vc8000-vcmd`). Provenance + full port notes:
`pkgs/vc8000-vcmd/PROVENANCE.md`.

- **Cross-compiles clean, insmod-loadable in principle** (overseer-verified, not just
  reported): `nix build .#vc8000-vcmd` → `ax630c_venc_vcmd.ko`, ELF aarch64
  relocatable, `vermagic: 4.19.125 SMP preempt mod_unload aarch64` (byte-identical to
  the vendor `ax_*.ko` magic → plain-insmod), `license GPL`, `depends:` empty, all
  undefined symbols are standard exported kernel symbols (no dangling eswin/dma-heap/axife).
- **Port patch (6.6.18→4.19) is minimal**, confined to `vc8000_vcmd_driver.c` (other 9
  vendored files pristine): `access_ok()` 2-arg→3-arg shim, `pfn_to_phys`→`PFN_PHYS`,
  dma-heap `#ifdef`-gated out, Makefile `-std=gnu11` (the eswin source is C11; 4.19
  defaults modules to gnu89). Our own AX630C platform glue (`ax630c_vcmd_glue.c`, GPL-2.0)
  replaces the excluded eswin probe: registers a DMA-capable platform device, one encoder
  core at the device-traced base `0x04010000`.
- **The Stage-1 nr70/nr83 EFAULT seam is removed wholesale — confirmed from source.** The
  public userspace contract is `GET_CMDBUF_PARAMETER(25) → RESERVE(29) → [write program
  into the mmap'd pool slot] → LINK_RUN(30) → WAIT(31) → RELEASE(32)`. `LINK_RUN` is
  `_IOR(MAGIC, 30, u16 *)` and reads **only** a `cmdbuf_id` (`__get_user`), then operates
  exclusively on the kernel's own `cmdbuf_virtualAddress` of the shared pool — **no
  `copy_from_user` of any userspace VA in the reserve/link path, and no nr70/nr83 in the
  ioctl set at all** (verified by grepping the vendored driver). So the open EWL (#45) can
  drive submission with no frame-setup ioctl — closing the 2026-08-23 Stage-1 diagnosis.

**GO on the port (HIGH confidence)** for the compile + submission-path milestones (both
independently re-derived). NOT yet proven: driving a real encode through it, which needs
(1) a real AX630C DT node + reserved-memory carveout for the VCMD pools, (2) the VCMD IRQ
wired (currently `-1` → polling), (3) `enc_pm_runtime_*`/`enc_reset_system` driving real
DT clk/reset instead of no-ops, (4) on-device insmod + one IDR through the ioctl sequence
vs the Stage-1 hijack-validated register program. Item 4 is RISKY (conflicts with the
vendor `ax_venc.ko`) → serialized/human device session. Ticket #44.

### 2026-08-29 — Fixed-QP stage: a from-scratch open VC8000E generator drives the silicon to QP-controllable 1080p IDRs (ATX .221)

Per the #47 decision (fixed-QP open v1 first), the encoder-core question moves from
"capture-and-patch a vendor program" (Stage 1) to **generate the register program from
source**. Done and device-proven: `docs/reference/vcenc-open/stage-fixedqp/` (generator +
Path B harness + register evidence; screen-capture bitstreams/pixels deliberately excluded).

`gen_idr.py` emits the VC8000E encoder-core image (swreg1..511) for a chosen fixed QP + 1080p
geometry. Register classification: **VCMD envelope + geometry + the 13-register QP block are
computed/decoded from source**; the QP block uses scaling laws derived from our two committed
anchor programs (quant table swreg125-132 × 2^((QP-32)/8), swreg37 × 2^((QP-32)/4),
TARGETPICSIZE swreg105-107 content-calibrated, swreg7 pic_init_qp=QP with a matching PPS).
At QP32 the generated image is byte-identical to the QP32 anchor; at QP36 it matches within
<17 LSB. **Honest boundary:** ~40 template registers are `opaque` (role annotated, exact
bitfields not decoded, copied from our invariant 1080p observation) — cracking them needs the
public eswin VCEnc reference cross-walk, a follow-up, not a fixed-QP-1080p blocker.

**Hardware validation (Path B image-overlay, `gen_hook.c` — overlays swreg1..511, preserves
the 16 per-run address regs so no invented phys reaches DMA).** Device healthy throughout
(nanokvm active, web 200, uptime monotonic 12 days, no watchdog reboot). QP ladder, all
decoding to correct 1920×1080 of the live desktop:

| QP | swreg82 (HW cycles) | IDR NAL |
|----|---------------------|---------|
| control | 0x00200d95 | 11489 B |
| 28 | 0x0020225f | 17470 B |
| 32 | 0x00200c8a | 11378 B |
| 36 | 0x001ff76f | 7564 B |
| 40 | 0x001fe688 | 4661 B |
| 44 | 0x001fe681 | 3537 B |

**Overseer-verified independently** (not from the agent's report): NAL sizes are monotonic in
QP (re-derived from raw file sizes), swreg82 advances and varies per program (re-extracted from
the raw `.regs` dumps → the HW genuinely executed each distinct program, contrast the Stage-1
raw-ioctl attempt where it never advanced), all six decodes are distinct 1920×1080 8-bit RGB
frames (dimensions + md5 checked), and `gen_idr.py` computes the QP block from the scaling laws
rather than replaying a blob (spot-read).

**Net:** the from-scratch register-program generator — the encoder-core half of a blob-free
fixed-QP encoder — is proven on hardware. Confidence HIGH. Remaining for a *shipped* blobless
encoder: (a) blob-free submission (the #44 open driver + #45 open EWL, replacing the Path B
hijack), (b) integrate the generator into the open libkvm backend, (c) locate the RC-enable bit
so fixed-QP can disable RC instead of driving TARGETPICSIZE — *→ resolved 2026-09-04, see that
stage (E1: the RC-enable cluster is sw6[0] + sw22[3:2] + sw245/246 + sw172/173 + sw105–107, with
sw239/241 unallocated)* —, (d) crack the ~40 opaque template
regs for full from-source (or accept them as a documented 1080p init constant) — *→ resolved
2026-09-04, see that stage (E4: all but seven of them are constant across every knob, RC mode, QP
and geometry the vendor exposes)*. P-frames (Stage
2) not attempted; DPB regs pinned (Stage 0), no new blocker. Tickets #25/#46/#47.

### 2026-08-29 — #25 finish-line probe: blob-free SUBMISSION is walled on BOTH paths (encoder-core stays done) (ATX .221)

Pushed for the last userspace-blob gate — a blob-free *encode submission* (kill the
`libax_venc/sys/ivps/proton` linkage), the only piece of #25 left after the encoder-core
generator (fixed-QP stage). **Both routes are walled; the encoder-core half is unchanged and
device-proven.** Device stayed healthy (two watchdog reboots during the driver-load probe,
recovered clean each time via the curated loader; vendor stack restored, web 200 at end).

**Path B (load the open #44 driver) — empirically walled at a kernel-flash gate.** The ported
`ax630c_venc_vcmd.ko` loads, but `vc8000e_vcmd_init → vcmd_mem_init` needs 3× 2 MB physically
contiguous *coherent* DMA (`dma_alloc_attrs(DMA_ATTR_FORCE_CONTIGUOUS)`) before any MMIO claim.
On this device `/proc/config.gz` has **`CONFIG_CMA` not set**, `mem=824M`, and the 200 MB CMM
carveout (`0x73800000–0x7FFFFFFF`) is reserved *outside* kernel-managed DRAM — so no allocator
can satisfy it. Proven on hardware: first insmod → the stock code never null-checks the alloc →
NULL deref → **kernel panic → watchdog reboot** (recovered). With a fail-safe added (null-check →
`-ENOMEM`, committed this change) the second insmod aborts cleanly: `dma_alloc_attrs(2097152)
FAILED (no CMA?)` → `vcmd_mem_init failed (-12)` → clean module-load abort, no reboot, call
trace at `vcmd_mem_init+0x140`. **Unblock = a kernel/DTB reflash** with `CONFIG_CMA`+a CMA area,
or a VCMD reserved-memory DT carveout — a human action (no flash attempted). Secondary wall
confirmed in source: `vcmd_reserve_IO` does `request_mem_region(0x04010000)`, held by the loaded
vendor (`04010000-0401006b : vsi_vcx`), so a real load also needs `rmmod ax_jenc ax_venc` first
(refcount-clears with nanokvm stopped).

**Path A (drive the vendor `ax_venc.ko` from open code) — walled behind unpublished-blob RE.**
On-device disasm of `/soc/ko/ax_venc.ko`: same `hantrovcmd_*` VCMD lineage as the open eswin
source + Axera OSAL wrappers + the extension ioctls; one `hantrovcmd_ioctl` (0x2198 B, 44
`copy_from_user` sites, ~90-entry decision tree). The per-frame trace shows nr70 passes a struct
whose offset 0x20 is a **userspace VA** consumed by `link_and_run`; nr70/nr83 arg structs are
pointer-dense vendor-EWL private state. Replicating them in open C means byte-matching both the
unpublished `libax_venc.so` and `ax_venc.ko` layouts — genuine multi-session specialist RE, no
flash but not a session job. This is the exact vendor-private seam Stage-1 (2026-08-23) deferred.

**Honest #25 status:** encoder-core register-program generation = **DONE, device-proven**;
blob-free submission = **blocked**, with two precise remaining routes: (a) the human flash above
→ then Path B is a no-new-RE bring-up (unload vendor venc → insmod → drive RESERVE→LINK→WAIT→
RELEASE with a live CMM frame) + the #45 open frame-buffer allocator; or (b) a no-flash #45
variant that reworks `vcmd_mem_init` to back the VCMD pools from the existing CMM carveout (via
the CMM allocator / a reserved-memory region) instead of `dma_alloc_attrs` — more driver work,
but stays on the current kernel. #25 cannot close until one lands. Added to the unblock list:
**flash a `CONFIG_CMA`-enabled kernel (or a VCMD reserved-memory carveout DTB)** — the single
human action that converts Path B into a bring-up-only finish.

### 2026-08-29 — #49: the CONFIG_CMA unblock kernel is built + ready to flash to `kernel_b` (approach chosen, ABI-proven)

The Path-B wall above is now a ready-to-flash artifact. Both candidate unblocks were
analysed; **approach 1 (a `CONFIG_CMA` kernel variant) is implemented** because it is the
smaller blast radius — **zero driver change, zero DTB change, one partition flashed** — and its
only theoretical risk (an `ax_*.ko` ABI disturbance) is disproven, not assumed:

- **New opt-in flake outputs** (`pkgs/kernel.nix` gained `cmaSizeMBytes`, default `null`):
  `.#kernel-cma` (Image+modules with `CONFIG_CMA=y` + `CONFIG_DMA_CMA=y` + a 16 MiB default CMA
  area) and `.#kernel-slot-image-cma` (that Image → `ax_gzip -9` + signed 1 KB header for the
  64 MB `kernel_b` slot). The default `.#kernel` and every shipping image are **byte-for-byte
  unchanged** — the default kernel `.drv` hash is identical before/after (the CMA shell is
  appended via `lib.optionalString`, empty in the default case).
- **Vermagic byte-identical, verified empirically.** `CONFIG_CMA` is not a `VERMAGIC_STRING`
  input (`include/linux/vermagic.h`). A module built by `.#kernel-cma` reads
  `vermagic=4.19.125 SMP preempt mod_unload aarch64` — byte-for-byte equal to the vendor
  `ax_cmm.ko`/`ax_venc.ko`. So the blobs still plain-`insmod`.
- **`struct page` unchanged.** Its only config-gated field is under `CONFIG_MEMCG` (left off);
  `CONFIG_CMA` adds none and reuses the existing pageblock migrate-type machinery — the exact
  contrast with the `CONFIG_MEMCG` trap CLAUDE.md warns about. `CONFIG_CMA`'s `select`s
  (`MEMORY_ISOLATION`, `MIGRATION`) are already `=y` in the defconfig, so nothing new is pulled.
- **Why not DT carveout (approach 2):** it is DTB-only for kernel config but needs a driver
  change (DT-probed device + `memory-region`/`of_reserved_mem_device_init`), a hand-placed phys
  carveout inside `mem=256M`, and a second partition reflashed. Approach 1 dominates once
  vermagic is shown identical.

**Full reversible flash + Path-B bring-up plan: `docs/vcmd-cma-unblock.md`.** Slot A
(`kernel` p14) is never touched; `dtb_b` (p13) already holds the correct patched DTB
(`image.nix` writes it to both slots), so only `kernel_b` (p15) is written and rollback is a
slot switch. `nix build .#vc8000-vcmd` still builds against this tree (vermagic identical).
**Not device-verified** (host-only track): that the reserved CMA area satisfies the alloc on
this board, and the exact SPL slot-register behaviour for forcing a slot-B boot — both are
serial-confirmable human steps in the plan. Ticket #49.

### 2026-08-30 — #49 resolved on hardware: open VCMD driver initialises on the SHIPPING kernel (no flash)

Supersedes the paragraph above. The CMA path was flashed to slot B and is **dead** —
CONFIG_CMA/CONFIG_DMA_CMA break the vendor-blob ABI (`struct device` gains `cma_area`;
migratetype renumbering resizes `struct zone`): the blobs' insmod kills the kernel pre-init,
proven by slot-B bisection. The wall fell anyway, with **zero flash**: the glue now declares
an 8MB CMM-tail coherent carveout via exported `dma_declare_coherent_memory()` (consulted
by `dma_alloc_attrs` before any CMA path), holds `clk_venc_eb` through the open in-tree clk
driver (the block reads `0xDEADBEEF` unclocked; vendor userspace gates it per frame), and
wires GIC_SPI 93 via `of_irq_get`. Result on the stock kernel: `module inserted. Major
<241>`, `/dev/es_venc` live, init self-test cmdbufs completing with real interrupts. Full
record: `docs/vcmd-cma-unblock.md`. Next: #45 open EWL (RESERVE→LINK→WAIT→RELEASE IDR).

### 2026-08-30 (later) — #45 Stage A: blob-free userspace submission PROVEN on hardware

The open userspace submitter (`pkgs/vcenc-ewl`, `ewl_probe`) drives the full
open-driver cmdbuf lifecycle from userspace with **no vendor library and no
ax_venc.ko** — the seam the vendor's nr70/nr83 setup ioctls used to gate is
simply gone (the open LINK path is self-contained). Device-proven, stable over
repeated runs:

```
open(/dev/es_venc) -> GET_VCMD_PARAMETER (hwid 0x43421500, core base 0x1000)
  -> GET_CMDBUF_PARAMETER -> mmap(cmd pool)+mmap(status pool)
  -> RESERVE_CMDBUF -> build a register-readback cmdbuf (the driver's own
     minimal known-good program) -> LINK_RUN -> WAIT (status OK)
  -> read encoder swreg0 = 0x90101010 (core ASIC ID) out of the status pool
RESULT: PASS
```

This validates end-to-end: the ioctl/cmdbuf ABI (transcribed in
`pkgs/vcenc-ewl/vcmd_abi.h`), the cmdbuf head/tail patch layout
(`vcenc_cmdbuf.h`, matching the driver's `create_read_all_registers_cmdbuf`
word-for-word), the pool mmap (needed an AX630C mmap fix — see
`pkgs/vc8000-vcmd/PROVENANCE.md` port-edit 4), hardware execution, GIC_SPI 93
IRQ completion, and status-pool readback.

**What Stage A does NOT yet do:** a real encode. Stage B adds (a) CMM frame
buffers (input YUV, output stream, 2 recon sets, aux) allocated from userspace
CMM, (b) the encode register program — reuse the device-proven `img_qp32.bin`
swreg1..511 payload (byte-identical to the captured `slot8k.bin` IDR) with the
16 address registers (`KEEP_ADDR = 8,9,10,12,13,14,15,16,27,46,60,62,72,114,
239,241`) repointed at our buffers, (c) the 0x2000 secondary-bank pokes and the
swreg5 kick, (d) SPS/PPS emitted in userspace (HW emits slice data only;
`pic_init_qp` must match). Open unknowns for Stage B are enumerated in the
fixed-QP stage README and the RE mining notes: input pixel format (sw17=0x30
labelled NV12 but the capture block is 2 B/px), the kick low-nibble semantics,
~40 opaque registers, and the RC-enable bit. Fixed-QP 1080p IDR is reachable
without cracking those (replay + repoint); P-frames and rate control are not.

### 2026-08-30 — kernel-module (.ko) de-blobbing roadmap

The `ax630c_vcmd_glue.c` shim is the pattern for retiring a vendor `.ko`: take
an OPEN driver of the same hardware lineage, write a thin AX630C platform layer
(DT clk/reset/IRQ — all already open in-tree), and drop the blob. But that only
works where an open driver of that lineage EXISTS. Sorting the loaded blobs by
tractability against that test:

**Tractable — VC8000E VCMD family (open eswin/VeriSilicon lineage exists):**
- `ax_venc` (video H.264/265): **being replaced now** (#44 driver done, #45
  userspace Stage A proven). The shim replaces the blob, it doesn't wrap it.
- `ax_jenc` (JPEG): the open driver already models a JPEG-encoder core
  (`VCMD_TYPE_JPEG_ENCODER=3`, `VCMD_JENC_MODULE_TYPE_1=3`). Plausibly the same
  driver with a second core wired at the jenc base `0x4000000` — IF jenc is
  VCMD-driven on AX630C (unconfirmed; it may be direct-register). Cheapest next
  blob to attempt after the venc path closes.
- `ax_vdec` (video decode, VC8000D): not used by the KVM path; open VC8000D
  lineage exists if ever needed.

**High-value linchpin, RE-able but hard — `ax_cmm`:** the CMM allocator over the
200 MB reserved carveout. Everything imports its `AX_OSAL_*`/pool symbols, so
replacing it means re-implementing the inter-blob ABI, not just one driver. It
is a bounded problem (a contiguous allocator + an ioctl surface) unlike the ISP,
and Stage B needs *some* userspace CMM allocation anyway — so a minimal open CMM
shim is on the critical path regardless. Medium effort, unblocks a lot.

**The wall — the ISP/VIN capture stack:** `ax_proton` (2.3 MB ISP/VIN),
`ax_mipi_rx`, `ax_gdc`, `ax_vpp`, `ax_ivps`. No open driver of this lineage
exists. Capture is already blob-free at the *userspace* layer (libkvm speaks raw
ioctls to these `.ko`), but the `.ko` themselves would have to be written from
scratch against undocumented ISP registers — the same "no ISP has been fully RE'd
without vendor docs" wall as §8. Keep as blobs; revisit only if a vendor GPL
source drop or an open AX630C ISP effort appears.

**Infrastructure (small, follow the CMM decision):** `ax_base`, `ax_sys`,
`ax_pool` — thin glue/OSAL layers; only worth touching once `ax_cmm` is open,
since they share its symbol ABI.

Bottom line: the shim-and-replace pattern the user pointed at is exactly right
for the VC8000E family (venc now, jenc next) and, with more effort, for `ax_cmm`.
It does NOT reach the ISP stack — that has no open lineage to build glue against,
so "expanding the shim" there means writing a full ISP driver blind, which stays
out of scope.

**Standing direction (Jeremy, 2026-08-30): the end goal is a kernel with ZERO
vendor blobs — the ISP stack included.** The tractability ordering above still
governs sequencing, but "keep as blobs" entries are waypoints, not endpoints:
`ax_proton`/VIN is last-not-never (a from-scratch driver against undocumented
registers is accepted as eventual work), and the aic8800 WiFi/BT blobs may
simply be DROPPED rather than replaced — no WiFi ever is an acceptable
outcome (bears on #28). Consequence for interim work like the #50 fix: open
code that satisfies a blob's inter-module contract (registration shims, OSAL
stubs) is scaffolding — each absorbed contract is also a piece of the ABI map
needed to retire the blob it talks to.

> **Superseded by #55 scoping (2026-08-31).** The "keep as blobs / no open
> lineage / full ISP written blind" framing above is obsolete: the KVM path is
> a pure ISP-bypass DMA writer, the capture-relevant slice of ax_proton is
> ~17–35 % of its code, the blobs are unstripped, and clk/reset/IRQ resources
> are open in-tree. Current plan + decision record: `docs/deblob-capture.md`;
> evidence: `docs/reference/deblob-scope/`.

### 2026-08-30 (later still) — #45 Stage B: a real 1080p IDR driven blob-free through the open path

`pkgs/vcenc-ewl/ewl_encode` drives one fixed-QP(32) 1080p H.264 IDR end-to-end
through the open driver with **no vendor library and no ax_venc.ko**, and the
encoder core executes and emits a valid slice. Device-proven, stable across
repeated runs:

```
open(/dev/es_venc) -> GET_VCMD/CMDBUF_PARAMETER -> mmap pools
  -> place frame buffers in spare CMM (relocate the captured layout by a fixed
     page-aligned delta into 0x78000000+; /dev/mem, input+output only)
  -> fill a synthetic input gradient
  -> RESERVE -> build the 570-word IDR cmdbuf (img_qp32 swreg1..511 with the 16
     address regs relocated; secondary-bank pokes + swreg5 kick replayed)
  -> LINK_RUN -> WAIT(OK)
READBACK: swreg82(cycles)=~2,117,246  swreg9(NALbytes)=21970  swreg1=0x0805
NAL: start code @+0x29  nal_unit_type=5 (IDR slice)
RESULT: PASS
```

The cycle counter (nonzero, varying per run) proves the core genuinely ran a
1080p frame; `swreg9` gives the emitted byte count; and the output buffer holds
a real H.264 IDR-slice NAL (`00 00 01 25 ...`, nal_unit_type=5). This is the
register-program half (Stage 1 / fixed-QP stage) now driven through the fully
open submission path (Stage A), closing the loop from `/dev/es_venc` to a
bitstream with zero vendor code in the encode path.

**Two things learned building it:**
- Userspace only maps the input (fill) and output (read) regions; recon/aux
  buffers are DMA'd by the encoder internally and never touched by the CPU, so
  their (undecoded) sizes don't matter — relocating the whole captured layout by
  one delta preserves every gap/alignment.
- `/dev/mem` `O_SYNC` gives **Device** memory: libc `memset` (DC ZVA) faults on
  it. Use explicit aligned stores. (The driver-mapped pools are writecombine /
  Normal-NC and tolerate `memset`.)

**Remaining for a fully DECODABLE stream (refinements, not this milestone):**
1. **SPS/PPS** — the HW emits slice data only; prepend standard, unencumbered
   SPS+PPS (the fixed-QP stage's `pps_patch.py` has a matching PPS,
   `pic_init_qp=32`; SPS generation from source is the open piece). Then a host
   decoder (ffmpeg) confirms the frame decodes.
2. **Input pixel format** — the synthetic gradient encodes fine structurally,
   but a *correct-looking* image needs the real input format resolved (sw17=0x30
   labelled NV12 vs the 2 B/px capture block — still unresolved).
3. **Proper CMM allocator** — replace the fixed-address `/dev/mem` placement with
   a from-source allocator (the other half of #45's title). The driver already
   maps coherent memory writecombine; a small alloc ioctl over an enlarged
   carveout is the clean path.

### 2026-08-30 (Stage C) — fully decodable blob-free stream + input pixel format RESOLVED

Refinements 1 and 2 above are done, device-proven. `ewl_encode` now emits a
complete `.h264` (SPS+PPS+IDR) that **ffmpeg decodes with zero errors** — the
definitive host-decoder proof of the blob-free encode path.

**From-source SPS/PPS (`pkgs/vcenc-ewl/vcenc_header.h`).** The HW emits slice
NALs only, and the SPS fields must agree with the slice-header bit layout the
core writes. Those were pinned by parsing our own Stage B IDR slice bit-by-bit:
after `first_mb_in_slice=0, slice_type=I, pps_id=0` the layout fits exactly one
clean interpretation — `frame_num` u(16) (so `log2_max_frame_num_minus4=12`),
`idr_pic_id=1`, `pic_order_cnt_type=0` with `pic_order_cnt_lsb` u(16),
`slice_qp_delta=0` (SliceQP = PPS `pic_init_qp` = the register program's sw7),
deblocking-control-present with a zero-offset header, then two CABAC alignment
ones landing precisely on a byte boundary. Confirmation: our PPS writer
regenerates the vendor-captured QP32 PPS RBSP (`ee 06 72`) **byte-identically**;
ffmpeg reports Main@L4.0 1920×1080 and decodes clean. Syntax is written straight
from ITU-T H.264 §7.3.2; parameters come from our own device observation.

**swreg9 semantics fix.** `swreg9` counts stream bytes from the stream base —
buffer offset 0x28 (`swreg8 & 0xfff`), where the HW writes the 4-byte start
code — not from the buffer base. Stage B's original file write measured from the
scan hit at +0x29 and so dropped the last 40 bytes, which showed up as an ffmpeg
"error while decoding MB 96 67, bytestream -5" ~150 MBs before the end. Copying
`[0x28, 0x28+swreg9)` decodes with no errors.

**Input pixel format = packed YUYV 4:2:2 (2 B/px), sw17=0x30's "NV12" label
refuted.** Three test-card encodes in one run (`ewl_encode` pattern modes), same
register program, only the input fill differing:

| hypothesis | fill at sw12 | NAL bytes | decode |
|---|---|---|---|
| `yuyv` | packed [Y U Y V], 2 B/px | 730 | **the exact test card, pixel-perfect** (8 gray bars 16→233, white 100×100 TL, black 100×100 BR, neutral chroma, correct orientation/stride) |
| `nv12` | planar Y + CbCr at sw13 | 1639 | packed-422 aliasing signature: top half green/pink (chroma decoded from luma bytes), bottom half gray (the 0x80 fill) |
| `gradient` | byte gradient | 21970 | structured noise (as before) |

The plane geometry already said this: sw13−sw12 = 0x3f4800 = **2·W·H** exactly
(and sw14−sw13 = W·H) — the "Y plane" is the whole 2 B/px packed buffer; packed
modes ignore the Cb/Cr base registers. It also closes the pipeline loop: open
capture reads **YUYV** out of the CMM pool (Stage 6), so the encoder consumes
capture output directly — no format conversion sits between them.

Per policy the `.h264`/`.png` artifacts are not committed (the test-card decodes
are synthetic, but the rule stays uniform); the code + this record re-derive
everything. Remaining for #45: refinement 3, the from-source CMM allocator.

### 2026-08-30 (Stage D) — from-source CMM allocator; /dev/mem retired; #45 COMPLETE

Refinement 3 is done, device-proven, and with it every item in #45's title
(EWL + CMM allocator glue). `pkgs/vc8000-vcmd/framebuf_alloc.c` (our code) is
a from-source frame-buffer allocator over a module-parameter CMM carveout
(default `0x78000000+0x04000000` then, `0x73800000+0x08800000` = 136 MB since
#52 — a formal slice of the 200MB CMM
region on the 1G board, passed in by the curated loader since #53:
above ax_cmm’s lowered ceiling, below the open capture carveout and the 8MB
coherent VCMD-pool region — see docs/vcmd-cma-unblock.md, “DMA memory map”).
First-fit over a bus-sorted allocation list; pure address-space bookkeeping (the
kernel never maps the memory); allocations owned by the open fd, freed on
close. Three `AX630C-PORT` hooks wire it into the core: ioctl nrs 36/37
(`ALLOC_FRAMEBUF`/`FREE_FRAMEBUF`), a lookup branch in `hantrovcmd_mmap`
(same writecombine `remap_pfn_range` path as the pools), and per-filp cleanup
in `hantrovcmd_release`.

`ewl_encode` now allocates the whole relocated buffer layout as ONE block
(`LAYOUT_SPAN` 43MB, covering sw12..sw27 + slack) through the ioctl, mmaps it
through the driver, and relocates the 16 address registers by
`bus - 0x73c45000`. No `/dev/mem` anywhere in the path. Device run: the
allocator handed back `0x78000000` (delta `0x43bb000` — a different relocation
than Stage B's hardcoded `0x4400000`, so the delta logic was genuinely
exercised), WAIT OK, cycles ~2.09M, and the emitted 754-byte yuyv-card stream
is **bit-identical** to the Stage C `/dev/mem` run and decodes clean in ffmpeg.

The open encode path is now, end to end: `/dev/es_venc` open → VCMD/cmdbuf
params → framebuf ALLOC + driver mmap → YUYV input fill → RESERVE → from-source
570-word cmdbuf (register program + relocation) → LINK → WAIT → readback →
from-source SPS/PPS + slice → decodable 1080p H.264. Zero vendor code, zero
vendor kernel modules, zero `/dev/mem`.

### 2026-08-30 — #25: P-frames + GOP sessions through the open path (IPPP device-proven)

`ewl_encode` is now a multi-frame fixed-QP session driver — per-frame cmdbuf
construction, reference/recon buffer rotation, and optional periodic IDR
(`ewl_encode out.h264 <nframes> <gop>`). Device-proven on the first attempt:
a 10-frame IPPP run and a 20-frame GOP-8 run both decode in host ffmpeg with
zero errors and the exact programmed I/P cadence (ffprobe), the moving test
card (white square gliding 16px/frame) tracks pixel-perfect across every
decoded frame — at ~130–270 bytes per P frame that is only possible via real
motion-compensated prediction against the reconstructed reference, not intra
coding — and the 1-frame regression stream stays **bit-identical** to Stage D
(md5-equal to the Stage C/D artifact).

The P-frame register program (`pkgs/vcenc-ewl/vcenc_encode.h`) is derived
entirely from our own Stage-0 ring captures, unlocked by one decisive
observation: the fixed-QP program runs with the CBR run's lambda LUTs
(sw215–223), bit-budget state (sw183, 243/244/247/248, 318) and warmed-up
inter state (sw111–113, 197/198) **all zero** — so P frames keep them zero
too, and the overlay reduces to:

- frame-type constants: sw5 `0x3c044300` (kick = value|1), sw17 `0xffd0007c`
  (keeps the 0x30 format bits), sw170/171/173, sw191 `0x04000000`, sw193
  `0x00200119` — all identical across the CBR and fixed-QP captures at like
  frame types, so type- not RC-dependent;
- sw11/sw192 = frame_num (HW writes slice-header `frame_num` and
  `pic_order_cnt_lsb` from these; both u(16) in our SPS; reset at each IDR);
- the double-buffered bank ping-pong pinned by the 7-slot ring, parity =
  frame_num&1 (bank A = what the frame-0 img_qp32 program uses): current
  recon sw15/16 vs reference sw18/19 (= previous frame's recon), aux pairs
  sw60/62 vs sw64/66 and sw72 vs sw74, scratch sw114 alternating, and the
  sw239/241 pair swapping each frame (241 = previous frame's 239);
- a GOP-restart IDR is a **plain frame-0 replay** — no warmed-state mimicry
  (the vendor's mid-session sw17/sw193 variants turned out unnecessary).

Fallback knobs for the two genuinely ambiguous clusters (`EWL_P17`,
`EWL_PINTER` replaying the captured warmed-up inter state) were built and
never needed.

#46 seams are in place by construction: QP is a per-frame input to the
cmdbuf builder (`struct vcenc_frame.qp`) and the emitted frame size (sw9) is
read back per frame — a rate controller is a module that picks the number.
Only QP32 has a derived register program so far; `gen_qp28..48.regs` hold
the evidence for deriving the QP-dependent register set when needed.

Remaining for #25: kvm-app integration — put the open EWL behind the vendor
venc call sites so the web UI streams through it (then libax_venc/libax_sys/
libax_proton leave the encode path), with #46 or fixed-QP as the v1 rate
strategy.

### 2026-08-30 — #25: kvm-app integration — the web UI streamed BLOB-FREE (one teardown bug open)

`pkgs/kvm-encoder/src/kvm_venc_open.c` (build flag `KVM_OPEN_VENC`, flake
package `kvm-encoder-openvenc`) replaces libkvm's vendor AX_VENC backend with
the open VC8000E session behind the existing `kvm_venc_*` seam: per-frame
from-source cmdbuf with **swreg12 pointed straight at the capture-pool frame**
(open capture emits packed YUYV 4:2:2 — the encoder's exact input format, so
the hand-off is zero-copy with no conversion), recon/aux rotation and GOP as
in the IPPP entry above, from-source SPS/PPS prepended at each IDR, and the
pack handed to libkvm.c's existing NAL splitter (so the load-bearing return
codes 1/2/3/4 the Go server keys on are produced unchanged). With
`openVenc = true` the link line drops **every** vendor library — libkvm.so's
DT_NEEDED is just opus/asound/libc — and the small `#ifdef` seams remove the
AX_SYS_Init/`AX_POOL_Handle2PhysAddr`/`AX_SYS_Mmap` calls that only existed
for the closed encoder (frame phys comes from the device-verified measured
pool layout; preview maps via its existing /dev/mem fallback).

**Device-proven over the REAL streaming path** (swap-run-restore: open
`ax630c_venc_vcmd.ko` in place of `ax_venc`/`ax_jenc`, openvenc libkvm.so hot
in both trees): the server's own `wss /api/stream/h264/direct` endpoint
delivered 240 messages — from-source SPS(16 B) + PPS(8 B), then keyframe-
flagged 11.4 KB IDRs and ~450 B P frames of the live HDMI desktop at a clean
60 fps timestamp cadence, GOP 30 (8 IDRs) — while
`grep -c libax /proc/<server-pid>/maps` read **0**. The full userspace video
path (capture → encode → web transport) ran with zero vendor code.

**Fixed along the way — libkvm video buffers leaked.** The Go server never
calls `kvmv_free_data` (verified in the pinned server source: `C.GoBytes`
then drop, all three read paths), so libkvm.c's malloc-per-NAL leaked at up
to 120 Hz. Video reads now return a library-owned grow-on-demand serve
buffer, the same ownership rule the audio path always had; `kvmv_free_data`
stays ABI-compatible (no-op for the serve buffer).

**OPEN BUG — the one thing between this and default-on:** `systemctl stop
nanokvm` while the live openvenc session + open capture stack were up caused
a hard device reboot (10:54:01, clean self-recovery from slot A; no serial on
this unit so no panic trace). Standalone ewl_encode runs close the same fd
dozens of times without incident, and vendor-path service stops are equally
clean — the crash needs the full app teardown ordering (our driver release
with capture still live, then raw-ioctl capture teardown + pool exit without
libax_sys). Suspects, in order: (1) open-driver release interacting with the
live capture teardown, (2) CMM framebuf/coherent carveout collision under
full-app allocator pressure, (3) a side effect of dropping AX_SYS_Init on the
raw pool-exit path. Until it is diagnosed the openvenc build stays strictly
test-only (deploy-iterate hot swap, restore after); the shipped image and the
deployed device keep `kvm-encoder-open` (vendor encoder, now with the leak
fix).

### 2026-08-30 (later) — #50 ROOT-CAUSED: vendor ax_proton oops on VIN-owner exit whenever ax_venc.ko is absent (openvenc code exonerated)

The teardown reboot was bisected on hardware in one afternoon; every finding
below is a captured kernel trace or a clean control, not inference. Method:
`panic_on_oops=0` for each repro (the oops then lands in dmesg and the device
survives — the reboots were `panic_on_oops=1` + `panic=5` escalating an
ordinary oops), a `dmesg -w` SSH tap, and a reboot after every oops (an
oopsed task wedges in `do_exit` and hangs any later `systemctl stop` of its
unit — "Fixing recursive fault but reboot is needed").

The oops, identical in every reproduction:
`vin_model_manager_deinit+0x44 [ax_proton]` ← `ax_vin_glb_exit_by_exception`
← `ax_isp_close` ← `osal_release` ← `__fput` — a wild read/write of
garbage pointers (freed/never-initialized memory; one fault address was
literal ASCII string bytes) while ax_proton cleans up after a process that
brought VIN up and then died.

The experiment matrix that pins the one causal variable:

| config at process death (live VIN) | death | result |
|---|---|---|
| openvenc libkvm, venc/jenc rmmod'd, open VCMD ko | SIGKILL | **oops** |
| openvenc + AX_SYS_Init restored (libax_sys linked) | SIGKILL | **oops** (libax_sys exonerated) |
| VENDOR libkvm, venc/jenc rmmod'd, no open ko at all | SIGKILL | **oops** (openvenc exonerated) |
| vendor libkvm, venc/jenc NEVER loaded (loader edit) | SIGKILL | **oops** (dangling-unload theory dead) |
| openvenc, venc absent | graceful `systemctl stop` | **oops** (= the original 10:54 reboot) |
| stock: vendor libkvm + vendor modules | SIGKILL mid-stream | **clean** (control) |

**Conclusion: ax_proton's exception-exit path hard-depends on state that
`ax_venc.ko` provides at insmod** (a VIN "model" registration through the
ax_base/OSAL seam). With ax_venc loaded the cleanup walk is fine; without it
— removed OR never loaded — the walk dereferences garbage. This is a latent
vendor-blob bug from Sipeed's "all modules always loaded" world; the openvenc
deployment merely exposes it because the open encoder requires vendor venc
GONE — coexistence is impossible: ax_venc holds `request_mem_region` on the
VCMD register window (our insmod fails "NO ANY HW found") and the same
interrupt line (GIC-0 125 = SPI 93+32).

Also ruled out on the way: CMM carveout collision (live `mem_cmm_info` under
the full openvenc app tops out ~0x7543A000, far below the 0x78000000 framebuf
block and 0x7F800000 coherent region).

**Fix path (the real one):** RE the model registration ax_venc.ko performs
against ax_base/ax_proton at insmod — disassemble `vin_model_manager_deinit`
(what it walks) and ax_venc's init (what it registers), then provide that
registration openly, either from `ax630c_vcmd_glue.c` at our insmod or as a
tiny stub module. Bounded two-function RE, device-re-subagent material.
**Interim for openvenc testing:** deploy with `panic_on_oops=0` and reboot
after any service stop that had a live video session; the deployed device and
shipped images stay on the vendor encoder meanwhile.

Server-contract facts recovered for this work (pinned `nanokvm-pro-src` rev,
citations in the 2026-08-30 session log): one NAL per `kvmv_read_img` call;
the return code IS the classifier (the direct path's keyframe flag is
literally `result == 3`); Annex-B in-band SPS/PPS mandatory (no Go binding
for `kvmv_get_sps/pps_frame`; WebCodecs configured without `description`);
the server never requests keyframes (WebRTC PLI is read and discarded) — a
`_qlty` change forcing a channel rebuild is the system's only IDR-on-demand
lever, which the openvenc backend preserves (rebuild ⇒ new session ⇒ IDR);
MJPEG is user-visible (menu + automatic no-WebRTC fallback) — v1 openvenc
fails MJPEG create loudly; the follow-up plan is a from-source software JPEG
(YUYV is already 4:2:2 — `jpeg_write_raw_data` needs no color conversion).

### 2026-08-31 — #50 FIXED (the ax_venc-registration hypothesis above is WRONG; real trigger is our own nr138 ioctl)

The "ax_venc registers a VIN model at insmod" hypothesis of the previous
section is **false** and its "RE ax_venc's init" fix path is a dead end.
Static disassembly of the blobs (llvm-objdump over the pinned `ax-ko-blobs`;
`docs/reference/` not needed — pure two-function read) plus six on-device
reproductions pin the actual mechanism, which is entirely in code **we own**.

**The bug is a latent kmalloc-not-kzalloc in ax_proton, armed by an ioctl our
own capture replay issues.** `vin_model_manager_init` (ax_proton 0x90160)
allocates its `model_manager` struct with `ax_os_mem_kmalloc` — NOT kzalloc —
and initialises only a few fields; the per-model slot-pointer array at
`+0x10, +0x18, …` is left as heap garbage. `vin_model_manager_deinit`
(0x902a8) loops `count = *(u8*)ioremap(isp_model_block)` times and, per slot,
does `strb wzr, [slot->ptr]` at **+0x44** — a wild write through a garbage
pointer whenever `count` (read from the reused `isp_model_manger_list` CMM
block) exceeds the slots actually populated. We never call the populate ioctl
(nr140/update), so any nonzero `count` detonates. Captured trace, identical to
the field reports: `vin_model_manager_deinit+0x44 [ax_proton]` ← `ax_vin_glb_exit_by_exception` ← `ax_isp_close` ← `__fput`; fault address literal
ASCII bytes (`0x0038373261393366`).

**`model_manager` is allocated ONLY by ioctl `0xc008708a` (`/dev/ax_proton`,
nr 138).** Verified xrefs: `vin_model_manager_init` has one caller
(`ax_vin_model_manager_init`), called only from `isp_vin_ai_isp_ioctl` (the
AI-ISP/AINR handler); the exception-exit path calls `vin_model_manager_deinit`
directly, and that deinit **early-returns on a NULL `model_manager`**
(`cbz` at 0x902bc). And **we issue that ioctl ourselves** —
`kvm_capture_open.c` line ~403 replayed `PR(138)` = `0xc008708a`, a vestigial
AINR "model manager" init carried over from the captured vendor VIN bring-up.
This is ISP-bypass HDMI capture; the AINR model does nothing for us.

**Why ax_venc presence correlated (the matrix's one real variable):** with
vendor venc loaded the pipeline happens to leave the reused CMM count byte at
0, so the deinit loop runs zero times; with venc absent the byte is nonzero
and the garbage walk fires. It was never a venc *registration* — venc has
**zero symbolic coupling** to ax_proton (no shared undefined symbol; venc's
`init_module` only does `platform_driver_register`). The correlation is
data-dependent, which is why a fresh CMM block can mask the crash — do not
rely on a live repro as a control.

**The fix (shipped): don't issue nr138.** `kvm_capture_open.c` now gates
`PR(138)` behind `getenv("OPENKVM_NR138")` (unset in production; set only to
reproduce the old crash). `model_manager` then stays NULL for the process's
lifetime, so `vin_model_manager_deinit` no-ops on the NULL guard for **every**
teardown path (SIGKILL and graceful) — no ax_venc, no kernel-blob RE, no stub
module. One caveat, proven the hard way: an oops faults at +0x44, *before* the
`model_manager = NULL` store at the function's end, so a crashed
nr138-issuing process leaves the global dangling; a subsequent no-nr138
process then inherits it and oopses anyway. The fix is therefore only clean
**from a boot where no process ever issued nr138** (`.bss` fresh = NULL).

**Hardware proof (2026-08-31, clean boot, `.#kvm-encoder-openvenc` with the
gate, vcmd loaded, ax_venc/ax_jenc removed):** live blob-free H.264 stream up
(`[openvenc] up hwid=0x43421500`, decodable NALs, `AX_VENC_Init` count 0 =
no vendor path); capture works **without** nr138 (`[openkvm] capture up`);
then — VIN owner up, venc absent — **graceful `systemctl stop` = CLEAN, and
`kill -9` mid-stream = CLEAN**, both no oops, service self-recovers and
resumes streaming. The polluted-state repro before the reboot reproduced the
real oops (`[#2]`, exact trace) and confirmed the dangling-global caveat.
The gate lives in shared capture code, so `kvm-encoder-open` (vendor-encoder,
shipped) also stops issuing nr138 — harmless there (venc present) and it
removes the latent arming. Closes #50.

### 2026-08-31 — #51 DONE: blob-free MJPEG via from-source soft-JPEG (hardware-proven)

The openvenc backend now serves MJPEG with **zero blobs and zero hardware
encode**: `kvm_venc_open.c` gained a `PT_MJPEG` session that maps each capture
frame for CPU read (`kvm_frame_map`, the preview module's cached
AX_SYS_Mmap-or-/dev/mem route, now exported), de-interleaves the packed YUYV
rows into planar iMCU rows, and hands them to libjpeg-turbo's
`jpeg_write_raw_data` as raw YCbCr 4:2:2 — no color conversion, no scaling,
parametric in geometry (the MJPEG path has no 1080p bake-in; only H.264's
register program does). The whole JPEG is one pack, which is exactly what
`libkvm.c` serves for MJPEG. libjpeg errors longjmp back and cost one frame,
not the process; the `jpeg_mem_dest` regrow-adoption is handled (jdatadst.c
does NOT free a caller-provided buffer it outgrows).

Link/deploy contract: the openVenc build links `-ljpeg` against a
**jpeg8-ABI** libjpeg-turbo (`crossPkgs.libjpeg_turbo.override { enableJpeg8
= true; }`, exported as `kvm-encoder.passthru.libjpeg8`) so the DT_NEEDED is
`libjpeg.so.8` — the soname (and `LIBJPEG_8.0` symbol versions, verified) the
device's Ubuntu 22.04 multiarch path ships. The NixOS appliance stages the
same build into /opt/lib (nixos/appliance.nix).

**Hardware proof (2026-08-31, clean boot, vcmd loaded, ax_venc/ax_jenc
removed):** `/api/stream/mjpeg` streamed 91 frames in ~10 s (**~9 fps** at
1080p q80, ~100 KB/frame, `[openvenc] MJPEG up: 1920x1080 from-source
soft-JPEG q=80`), a pulled frame decodes as a clean correctly-colored
1920×1080 JPEG of the live host screen, `grep -c libax /proc/<pid>/maps` = 0;
switching back to `h264-direct` streamed decodable NALs (both channel-switch
directions exercised). ~9 fps soft-encode on the A53s is acceptable for the
no-WebRTC fallback this path exists for. Closes #51; the openvenc default
switch (#25) now gates on #17 (non-1080p) + #46 (rate control) only.

### 2026-08-31 — #17 encoder geometry: openvenc is parametric (17-geometry vendor differential)

The open H.264 encoder's last hard-coded 1080p — the frozen `img_qp32`
register program and the relocated captured buffer layout — is replaced by
closed-form geometry laws (`pkgs/vcenc-ewl/vcenc_geom.h`) and a **computed
floorplan**. The whole capture→encode open path now supports any even
geometry in 64×64..1920×1200.

**Method: differential-probe the VENDOR encoder, no source changes needed.**
The blocker was test data: the device has one HDMI source and it is 1080p.
Two facts dissolved it: (a) the deployed `libkvm.so` exports its internal
`kvm_venc_*` wrappers, so ctypes can drive the vendor `AX_VENC` at ANY
channel geometry; (b) `AX_VENC` in unlink mode accepts a synthetic YUYV frame
from an `AX_POOL` block (`u32BlkId` must be a real pool block — `BlkId=0` is
accepted-then-dropped, `Fail2` counter; `0xFFFFFFFF` is refused NOT_PERM at
send). `docs/reference/vcenc-open/geom-probe/venc_geom_probe.py` encodes 6
frames at a chosen WxH and dumps the live cmdbuf WREG programs (all 511 regs,
IDR + P) from the `venc_ko` CMM pool. Run at **17 geometries** (640×480 →
1920×1200, including the full partial-macroblock width sweep 1360..1374).
An EDID-forcing detour (write a 720p-only EDID via the writable
`/proc/lt6911_info/edid` — SPI-flash program + verify + auto chip restart,
the vendor UI's own switch path) was proven to work chip-side but the
attached gamescope HTPC pins its output mode regardless of EDID identity,
even across an ATX-reset reboot; stock E54 EDID restored, byte-verified.

**Laws recovered (all 17/17 exact; `vcenc_geom.h` header comment is the
reference).** Highlights: `sw5` packs `align16(W)/2` and `align16(H)+3`;
`sw9 = 2WH+0xffd8`; the sw208–213/237 "frame dimension band" resolves to
whole-MB + partial-px fields (`sw210`) and a `ceil(mbw/4)*16` pitch
(`sw212/213/237` hi16); `sw134 = floor(2^28/(Wp·Hp))`; `sw245/246` are
reciprocals of mbw at 2^16/2^18 precision; `sw193` carries **crop flags**
(`|0x40` when `align16(W)-W >= 8`, `|0x10` for the H analog); `sw38` is
`W*64` plus small partial-dim fixups. **Two of gen_idr.py's 1080p-derived
"laws" were coincidences**: `sw2` lo16 is a constant 240 (not `2*mbw`) and
`sw237` lo16 a constant 0x44 (not `mbh` — 68 == 0x44 at 1080p, pure luck).
Buffer sizing laws: recon dims pad W to 4 MBs and H to 64 (`Wp×Hp`); luma
pitch `Wp·Hp + align4k(16 B/MB)`, chroma `align4k(Wp·Hp/2)`, `sw239` class
1 B/MB, `sw62 = sw60 + align64(MBs/2)`, `sw46` a constant 0x12000; where the
vendor's packing fit no closed form (`sw60`, `sw10` classes) our floorplan
uses a proven upper bound (vendor pitch ≤ bound at all 17 points; the vendor
packs the next buffer at the pitch, so HW write extent ≤ pitch always).

**Stride discovery — capture assumption A2 RESOLVED (was wrong).** A
1366-wide encode filled at a 1376-px stride came out sheared by exactly
10 px/row: the VC8000E reads input lines packed at the **true width**, and
the vendor MPI likewise programs `nWidthStride = w` everywhere. Capture's
`KVM_GEOM_STRIDE_ALIGN` is now 2 (stride == width); `sw261` hi16 is the
CODED width `align16(W)`, not an input stride. Refilled at width, 1366×768
decodes clean.

**Proof.** Host: `nix build .#checks.<sys>.open-venc-geometry` — golden
vectors for all 17 vendor geometries (auto-generated, no transcription) +
bit-identity of the builder vs `img_qp32` at 1080p for every non-address
register + envelope. Hardware (open driver, `ax_venc/ax_jenc` removed):
`ewl_encode <out> 20 8 yuyv WxH` passed **20/20 frames at 1920×1080,
1280×720, 1366×768, 800×600 and 1920×1200**, every stream decoding to a
pixel-perfect moving test card (P-frames ~100–160 B). Live path: openvenc
libkvm deployed → wss `h264-direct` streamed the real host desktop at
1920×1080 with **0 libax mappings**, MJPEG ~9.5 fps; SPS now emits proper
right-crop and a computed `level_idc` (1080p60 = L4.2, was hardcoded L4.0).
Vendor deployment restored after the session.

**What #17 still needs before openvenc can be the shipped default:** one
hardware bring-up of the (already parametric, identity-tested) open CAPTURE
at a real non-1080p source — the encoder can be fed synthetically but VIN
cannot. The suspects list is unchanged (os_mem flag byte `0xf0` vs the
Stage-3 `0x70` at 720p H.264 = suspect #1, `nr54` partition_info = #2); the
stride suspect is retired (resolved above, in capture's favor). Needs a
human: set the HTPC to 720p output (gamescope ignores EDID) or attach any
non-1080p source; then watch `[openkvm] capture up WxH` + a clean stream.

### 2026-08-31 — Open capture at 4K30: the MIPI link was never the wall (#17)

The open blob-free capture backend delivers correct **3840×2160 YUYV** frames
on this hardware — device-proven, with NO change but the geometry-envelope
ceiling (`kvm_capture_geom.h` MAX now 3840×2160). The "1920×1200 / DPHY link
budget" ceiling in the 2026-08-17 entry was **over-conservative and is
superseded**.

**What killed the link-budget reasoning.** Drove the VENDOR capture path
(`kvm_pipeline.c`, `.#kvm-encoder`) headless at the live 4K30 source under an
LD_PRELOAD ioctl tracer (`docs/reference/vcenc-open/geom-probe/` tooling
family). It captured clean 4K30 while programming the **identical** MIPI
config we already replay — `AX_MIPI_RX_SetAttr` with `{4 lanes, nDataRate=600,
LaneCombo MODE_0}` — and the **identical** sys nr45 scalar `0x016e3600`
(byte-for-byte the value `kvm_capture_open.c` hardcodes). So `nDataRate=600`
is a **PHY timing band selector, not a per-lane Mbps ceiling**: D-PHY is
source-synchronous off the LT6911's clock lane, the RX locks to whatever the
transmitter clocks, and 4:2:2-8 at 4K30 (~4 Gbps) rides the same 4-lane link
our 1080p path uses. The link was never the constraint; the software envelope
was.

**Open-path bring-up (Fable subagent, verified from artifacts).** Built
`.#kvm-encoder-open` (open capture + vendor encode, to isolate capture) with
only the envelope raised; log: `[openkvm] SYS+pool up: 3840x2160 stride=3840
blk=16588800 B x 4 (63.3 MB)` → `capture up 3840x2160 (blob-free)` →
`frame phys: api=…==derived=…` (the parametric geometry math agrees with the
pool API at 4K). The MJPEG stream (vendor jenc) ran ~22 fps 4K; a pulled frame
decodes pixel-perfect to the live host desktop (a KDE display panel reading
"3840×2160, 30 Hz"), no shear/stride-wrap/green regions, two static frames
byte-identical.

**Both non-1080p suspects DISPROVEN at 4K.** The `OSMEM_ALLOC_FLAG 0xf0`
(assumption 5) and `nr54 partition_info` (assumption 6) that the 2026-08-17
entry flagged as the prime non-1080p failure suspects were **replayed
verbatim and capture was clean** — neither is resolution-dependent, at least
up to 4K. The remaining assumptions (stride==width, geometry-word offsets)
already held from the encoder differential.

**Scope.** This is the open CAPTURE envelope (now 64×64..3840×2160). The open
ENCODER (`vcenc_geom.h`) stayed at 1920×1200 for one more day, purely because
the `framebuf_alloc.c` carveout was 64 MB (#53) and a 4K recon/aux/output
floorplan exceeds it — closed by **#52** below.

**This also answers #17's capture bring-up:** a non-1080p source captured
cleanly end-to-end through the fully parametric open path — the hardware test
the issue was blocked on. Tooling: `docs/reference/vcenc-open/geom-probe/`
(the ioctl tracer + cap driver reused here).

---

### 2026-09-02 — the vendor capture closure is RETIRED (#55 M3 / #60)

Everything above is history now: the shipped stack loads **three from-source
kernel modules and zero vendor blobs** (`ax630c_venc_vcmd.ko`,
`open_vin_csi2.ko`, `open_vin_capture.ko`), and libkvm captures over plain
**V4L2** (`.#kvm-encoder-v4l2`) with dma-buf zero-copy into the open encoder.
No `ax_proton`/`ax_mipi_rx`/`ax_sys`/`ax_cmm` — and since #54 (2026-09-03) those
blobs are deleted from the image entirely, so the raw-ioctl replay path this
document spent months mapping ships nowhere at all; `ax-load-drv.openvenc.sh`
plus `.#kvm-encoder-openvenc` survive only as bench tooling for a device flashed
with the vendor `.axp`.
The M1–M3 record and what remains open live in
[deblob-capture.md](deblob-capture.md).

---

### 2026-09-03 — 4K blob-free H.264 encode (#52, DONE)

The encoder envelope is now the capture envelope: `VCENC_GEOM_MAX_W/H` went
1920×1200 → **3840×2160** (the only >1920 gate in `vcenc_geom.h`), and the DMA
map gave the encoder the room — `MAP_FRAMEBUF_MB` 64 → **136**,
`MAP_CMM_MIN_MB` 72 → **0**, folding `ax_cmm`'s slice (unclaimed since #55 M3 /
#54) into the frame-buffer carveout so the 1G map is encoder framebuf
`0x73800000` +136 MB, capture `0x7C000000` +56 MB, VCMD coherent `0x7F800000`
+8 MB — the whole 200 MB pool. New `vcenc_geom_build_ex(g, w, h, want_input)`
makes the fallback input region optional: libkvm passes 0 (it points the input
registers at the capture frame's own bus address), so a 4K floorplan spans
59.21 MB instead of 90.85 MB. Hardware-proven the same day: the standalone
prover (`ewl_encode /tmp/out4k.h264 20 8 yuyv 3840x2160`) returned **PASS
20/20** and ffprobe reports H.264 **Main L5.1 3840×2160**, decoding clean; the
live path (`mode=h264-direct`, `OPENKVM_FORCE_GEOM` unset, native 4K bench
source) served 90 NALs / 462 KB with `[openvenc] up: hwid=0x43421500 3840x2160
framebuf 0x73800000+0x3b35000 fixed-QP32 gop=30`, 0 libax maps, ffmpeg decoding
84 frames of the real host desktop at ~25 fps. **The whole open video path —
capture, MJPEG, H.264 — is blob-free at 4K**, and `OPENKVM_FORCE_GEOM` is now
only a bench downscale hook.

4K caveats worth knowing: at the time there was **no vendor golden vector at 4K**
(the 17-geometry differential topped out at 1920×1200 — the laws extrapolated and
the device run was the proof). **Superseded 2026-09-04**: nine vendor programs
above 1920 wide now exist, up to 3840×2400, and every geometry law holds exactly
at all of them — except `sw9`, `sw105–107` and the `sw114` bank spacing, which
the extrapolation got wrong (see the 2026-09-04 stage; the `sw114` bound
under-allocates from 3200 wide up). `vcenc_level_idc` falls through to **51** (correct for
4K30), `out_limit` is 16.65 MB so libkvm's pack copy is ~16 MB/frame at 4K (an
fps cost, not a failure), and rate control is still fixed QP32 (**#46**).

### 2026-09-04 — Vendor encoder differential campaign (pre-mainline evidence capture)

**Why now.** The mainline move retires the 4.19 vendor stack, and with it the
only way to ask the vendor encoder a question. Everything the open encoder still
guesses at — the QP→register laws behind #46, whether the geometry laws hold
above 1920 wide, what the ~40 `opaque` registers do — was measurable today and
unmeasurable after. The device was temporarily restored to the full vendor stack
(open state backed up to `/root/open-state-20260904`) for one session and
returned to the open stack afterwards.

Method (same clean-room posture as the rest of `vcenc-open/`): an on-device C
tool drives the vendor `AX_VENC` through its **public MPI only**, on a synthetic
YUYV card in a real `AX_POOL` block; the resulting cmdbuf slot is dumped over
`/dev/mem` read-only and decoded to a 511-register program. No vendor binary was
read. A 1080p CBR control run reproduces the committed #17 vendor program in all
511 registers bar the 16 per-run addresses. Evidence + index:
`docs/reference/vcenc-open/vendor-diff-20260904/` (`REPORT.md` is authoritative).

**E3 — vendor golden vectors above 1920 wide.** Nine geometries accepted, six of
them beyond the #17 sweep: 3840×2160, 3840×2400, 3440×1440, 3200×1800, 2560×1440,
2560×1080, 2048×1080, 1920×1440, plus 1920×1080 as control. Every `vcenc_geom.h`
law (sw5, sw38, sw134, sw193, sw210, sw212/213, sw237, sw245/246, sw261, the
recon pitches, `sw62−sw60`, the sw239 bank size) is **exact at all nine**. Three
generator corrections fall out:

1. `sw9 = 2WH + 0x10000 − (SPS+PPS bytes)`, not `2WH + 0xffd8`. `0xffd8` is
   `0x10000 − 40`, and 40 is the *1080p* header size; the vendor's 4K headers are
   42 B (`0x00fe1fd6` at 3840×2160), 2560×1080's are 43 B (`0x00555fd5`), and E4
   confirms causality — profile/fps/bitrate changes move sw9 by exactly the
   SPS/PPS length delta. The open generator emits its headers separately and
   reserves a fixed 40-byte slot (`sw8 = out + 0x28`, `sw9 = 2WH + 0xffd8`),
   which is internally consistent — no change needed, but sw9 is an allocation
   choice, not a vendor law, and the golden-vector test must treat it as such.
2. **TARGETPICSIZE (sw105–107) is not pixel-scaled.** The vendor programs
   `0x1adb00` = 1760000 at *every* geometry from 1920×1080 to 3840×2400 at 8 Mbps
   / 60 fps / GOP 30. `vcenc_geom.h`'s `1760000·WH/(1920·1080)` is wrong above
   1080p. It is bitrate/fps/GOP-derived: br2000 → 440000, br16000 → 3520000,
   fps30 → 2880000, gop8 → 960960, gop120 → 1920000, gop1 → 133333 (= exactly
   `bitrate·1000/fps`), minIprop/maxIprop 20/80 → 0x222e00. Shape is "I-frame
   budget = bits-per-frame × k(GOP)" with k(1)=1.0, k(8)=7.2, k(30)=13.2,
   k(120)=14.4; no closed-form fit attempted.
3. **`sw114` bank spacing is `align4k(w4·mbhp/2)`,** and the generator's
   `align4k(mbhp·64)` bound is *smaller* than the vendor's spacing from 3200 wide
   up: 0x2000 vs 0x3000 at 3200×1800 and 3440×1440, 0x3000 vs **0x4000** at
   3840×2160, 0x3000 vs 0x5000 at 3840×2400. The #17 fit was a coincidence of
   1920-wide widths (`60·mbhp ≈ 64·mbhp`). This is a live under-allocation in the
   shipped 4K path. `sw60`'s bound stays above the vendor spacing everywhere
   (0x14000 vs bound 0x20000 at 4K).

CBR's *chosen* initial QP moves with geometry at 8 Mbps (QP32 up to 2048×1080,
QP34 at 1920×1440 / 2560×1080, QP36 from 2560×1440 up) — rate control, not
geometry, but a >1080p golden-vector test must not expect the 1080p QP block.
P-frame `sw243/244/247` are per-frame RC bit-budget state (zero in fixed-QP), not
geometry laws — the generator's "leave 0" policy is correct.

**E2 — the QP ladder (Q16…Q51 + I28/P34, fixed-QP at 1080p).** The two laws #46
needs, exact over the whole ladder:

- **`sw7 = (pic_init_qp << 26) | (frame_qp << 8)`.** Proven by the split I28/P34
  run: IDR `0x88001c00` (init 34 from the shared PPS, frame 28), P `0x88002200`.
  `gen_idr.py`'s "0x140 per QP" interpolation of the low field is wrong; the CBR
  captures' `0x2300`/`0x2500`/`0x2800` were simply frame QPs 35/37/40.
- **`sw125–132 = F(q − 2k)`, k = 0..7**, a lambda-type LUT indexed by
  `q = min(QP, 35)` for I frames and `q = min(QP, 35) − 3` for P frames — so the
  block **clamps at QP 35 for I and 32 for P** (Q36…Q51 programs are identical
  here). `F(q)` as hi16/lo16, from the ladder: F1 `0040/00e0` F3 `0050/0120`
  F5 `0064/0170` F7 `0080/01d0` F9 `00a0/0240` F11 `00cc/02d0` F13 `0100/0390`
  F15 `0144/0480` F16 `016c/0510` F17 `0198/05b0` F18 `01c8/0660` F19 `0200/0720`
  F20 `0240/0800` F21 `0288/0900` F22 `02d8/0a20` F23 `0330/0b60` F24 `0394/0cc0`
  F25 `0404/0e50` F26 `0480/1010` F27 `0510/1200` F28 `05ac/1440` F29 `0660/16b0`
  F30 `0728/1980` F31 `0808/1ca0` F32 `0904/2020` F33 `0a1c/2410` F35 `0cc0/2d70`.
  Growth ≈ `2^((q−32)/6)`, not the `2^(dQP/8)` `gen_idr.py` assumed. Two entries
  differ between the I and P instantiations of the table — F19 hi `0200` (I) vs
  `0204` (P), F20 lo `0800` (I) vs `0810` (P) — so a generator should carry both
  columns rather than one shared table.
- **`sw37` is a (hi,lo) lambda pair**: I at Q16 `0x00040020`, Q20 `0x000c0050`,
  Q24 `0x002400c0`, Q28 `0x00600200`, Q32 `0x00f00510`, Q≥36 `0x01e40a20`
  (clamped); P takes the I value at QP−3 (Q32 → `0x00780280`, Q34 → `0x00c00400`).
  ≈ ×2.52 per +4 QP, i.e. λ ∝ 2^(QP/3).
- In fixed-QP, `sw105` is a constant 15000 (`0x3a98`) at the IDR and ~14900–15100
  on P frames; `sw106 = sw107 = 0`.
- Per-frame mirrors give `sw9` = actual slice bytes and `sw82` = HW cycles
  (IDR ≈ 2.15 M, P ≈ 2.04 M at 1080p, content-independent to ±0.5 %). The
  bitstream slice QP equals the requested QP in every run; the SDK never
  populates `u32StartQp/u32MeanQp`, so the bitstream is the QP truth.

**E1 — RC-mode differential (1080p, 8000 kbps).** CBR, VBR, AVBR, CVBR and FIXQP
are accepted; **QVBR and QPMAP are refused at `CreateChn` with `0x8007020a`**
(ILLEGAL_PARAM) under header-minimal attrs. **CBR ≡ CVBR bit-for-bit; VBR ≡ AVBR
bit-for-bit** — the "custom Axera modes" are aliases at the register level. VBR
differs from CBR only in sw105–107 (no fixed target, only a cap) and the QP block.

Fixed-QP vs CBR at the IDR differs in exactly these non-address registers —
**this is the RC-enable set the 2026-08-29 stage went looking for**:

| swreg | CBR | fixed-QP |
|---|---|---|
| sw6 (bit0) | `0x00000003` | `0x00000002` |
| sw22 (bits 3:2) | `0x0000000c` | `0x00000000` |
| sw105 | `0x001adb00` | `0x00003a98` |
| sw106 / sw107 | `0x001adb00` | `0` |
| sw172 | `0x0000014f` | `0x0000000f` |
| sw173 | `0x00000662` | `0x0000066a` |
| sw245 | `0x20000888` | `0` |
| sw246 | `0x02225028` | `0x00001000` |

Additionally `sw239`/`sw241` are **0** in fixed-QP: those are RC buffer base
addresses and the vendor does not allocate them at all when RC is off. P adds the
QP block (QP32 vs CBR's QP35) and `sw243/sw247 → 0`. Reading: the RC-enable
cluster is `sw6[0]` + `sw22[3:2]` + `sw245/246` (the per-MB-row rate
coefficients, geometry-dependent *only because RC is on*) + the `sw172/173` QP
range + the `sw105–107` target, with `sw239/241` as its scratch. `sw172 =
minQp<<5 | 0xf`, `sw173 = maxQp<<5 | flags` (E4: qp20_40 → `0x28f`/`0x502`,
qp30_30 → `0x3cf`/`0x3c2`).

**E4 — 33-run single-knob sweep from the 1080p CBR/8000/fps60/gop30/Main/L5.1
baseline.** `base` vs `base_rep` are identical in all 511 registers — zero
run-to-run noise on a static card. Highlights of the knob→register map:

- `sw193[0] = CABAC enable` (Baseline/CAVLC clears it), `sw193[1] = 8×8 transform`
  (High sets it). There is no separate entropy knob; entropy follows profile.
- `sw6[31:16] = MB rows per slice, encoded rows<<9` (slice-8 → `0x10000003`,
  slice-1 → `0x02000003`), with `sw1 0x9fd → 0x209fd` alongside.
- `sw172/173` carry the QP range; `sw173` bit3 is `idrQpDeltaRange`.
- `bRefRingbuf` is the only knob touching `sw56/57/73/83` + `sw195[1]`.
- **Level, intra-refresh (row and column), deBreath, deBreathQpDelta,
  sceneChangeDetect, rowQpDelta, statTime, bRcnRefShareBuf and re-applying
  RcParam move nothing at all** in the register program. minIprop/maxIprop moves
  only the IDR target. Moving content moves only P-frame RC state.
- There is no H.264 deblocking knob in this SDK; every run emits
  `deblocking_filter_control_present=1` / `disable_deblocking_filter_idc=0`.
- **464 of 511 registers never move under any knob**, and the 34-word
  secondary-bank poke block (`WREG 0x2800 = 0x44` then 16× `WREG 0x2014+i·0x20 =
  0`) is **byte-identical across all 214 programs of the campaign** — every
  geometry, RC mode, QP and knob.

**E5 — the live core register window, read from MMIO.** Polling
`0x04010000 + 0x1000` read-only while a vendor encode ran returned
`sw80 = 0x88da4280`, `sw214 = 0x48500800`, `sw226 = 0x00a19200`, `sw287 = 0`
— **identical to the DRAM-mirror values of §8.5**, which closes that stage's
"strict proof would be a live read of `VCMD_base+0x1000+0x140`" caveat. H264=1,
HEVC=1, JPEG=0, ctbRcVersion=1 stand; the `maxEncodedWidth` unit stays ambiguous.
Idle, the whole window reads `0xdeadbeef` (clock-gated), confirmed twice. Two
classifications fall out of the live-vs-program diff (462/511 identical):
registers that are **write-only** (read back 0: sw39–41, 125–132, 201, 203, 236,
237, 250/251, 272, 281, 289, 307, 349) and registers the **HW updates per frame**
(sw215–223 lambda LUTs, sw243/244/247, sw105–107, sw111–113, sw183–185, sw78/79)
— for those the program value is an input the hardware overwrites. Bonus:
`sw509/510/511` = `0x2114` / `0x9b83c` / **`0x20230307`**, a date-coded HW build
ID.

**E6 — CBR trajectories on a moving card** (90 frames, GOP 30, 1080p60). At
8000 kbps the IDR is QP32 and P QP descends 35→25 across the first GOP (7337 kbps
achieved); at 16000 kbps QP descends to 21 and holds (only 8196 kbps achieved —
content-limited); at 2000 kbps QP climbs 37→51 inside the first GOP and pins at
49–51, settling at 46 in later GOPs, and still overshoots to 3266 kbps — the
moving card is not encodable at 2 Mbps. QP steps at most ±1–2 per frame. **The
I-frame QP is not derived from the running P QP**: the IDRs at frames 30 and 60
are QP30 then QP28 at *both* 8000 and 16000 kbps (whose P QPs were 26/19 and
21/19), and QP37 throughout at 2000 kbps.

**What this changes.**

- **#46 no longer needs the vendor.** The QP→register laws (sw7, the F LUT,
  sw37), the exact RC-off register set, and three measured CBR trajectories to
  validate a controller against are all captured. Rate control is now a pure
  software exercise against committed vectors.
- **Generator fixes to make** in `pkgs/vcenc-ewl/`: `s114sz =
  align4k(w4·mbhp/2)` (a real under-allocation at ≥3200 wide, i.e. in the
  shipped 4K path — highest priority); TARGETPICSIZE/the fixed-QP register set
  (drop the pixel scaling; when RC is off, program the E1 fixed-QP column rather
  than driving a target); the exact I/P QP tables in place of the 2^(dQP/8)
  scaling law; and 3840×2400 into the envelope (the vendor accepts it).
- **The ~40 `opaque` registers are now classified.** Never moved by any knob, RC
  mode, QP or geometry: sw3, sw4, sw22†, sw26, sw35, sw36, sw38‡, sw39–41, sw45,
  sw81, sw134‡, sw136, sw170, sw171, sw182, sw194, sw196, sw201, sw203, sw224,
  sw225, sw245†, sw246†, sw248–259, sw272, sw277, sw281, sw288, sw289, sw307,
  sw319, sw320, sw349, sw430 († moves with RC mode only, ‡ is a geometry law).
  The ones that do move: sw1 and sw6 (slice split), sw172/173 (QP range), sw193
  (entropy / 8×8), sw195 (ring buffer), sw247 (RC state). So "opaque" now mostly
  means "constant on this SoC" — the 2026-08-29 stage's item (d) is answered by
  measurement rather than by cracking bitfields.

**Generator update, same day (commit 2d5d256).** `vcenc_geom.h`: `s114sz =
align4k(w4·mbhp/2)`, TARGETPICSIZE a constant 1760000 anchor, envelope
3840×2400. New `vcenc_qp.h` / `vcenc_qp_tables.h` carry the exact I and P
tables for QP 16…51 (auto-generated from the vendor programs by
`tests/gen_vectors.py`; unobserved entries are marked interpolated and none lie
on the ladder). `vcenc_encode.h` gains `rc_mode`: `ENC_RC_LEGACY` (the shipping
program, bit-identical at QP32) and `ENC_RC_FIXQP` (the vendor's RC-off set,
incl. sw197/198 on P frames). The golden-vector test now pins 25 geometries plus
all 22 vendor fixed-QP programs with **zero non-address diffs** (the two
structural exceptions: sw9, our fixed header slot, and sw105 on P frames, which
the HW rewrites). Device-proven on the open stack with the standalone prover
(20 frames, GOP 8): PASS at 1920×1080, 3840×2160 and **3840×2400** — the first
encode above 2160 rows on this hardware — all decoding clean in ffmpeg. libkvm
keeps `ENC_RC_LEGACY`/QP32 as the default; `OPENKVM_VENC_RC=fixqp` and
`OPENKVM_VENC_QP=<16..51>` select the new mode. **Still pending:** the fixed-QP
mode and QP ladder on the live web path, and raising the capture-side envelope
to 2400 rows (the encoder no longer limits 4K 16:10, #61).

### 2026-09-05 — Vendor HEVC differential campaign (#64): the gate passed, evidence banked

**Why now.** HEVC roughly halves the KVM bitrate at equal quality and the silicon
has it (`sw80` fuse HEVC=1, E5). Asking the vendor encoder how it programs HEVC
was assumed to need a vendor `.axp` reflash after the alpha.4 flash wiped the
on-device backups. It did not: the vendor `.ko` set is `.#ax-ko-blobs` and the
libax closure is `.#axera-libs` (+ the stock-rootfs `libax_venc.so`, extracted
from `.#base-axp` — the SDK snapshot's copy differs and rejects the pixel-unit
stride `vdrive` uses), so the vendor encoder was loaded on the running open image
for one session and discarded by a warm reboot. Recipe + traps:
`.claude/skills/device-re-subagent/SKILL.md`.

**Method.** `docs/reference/vcenc-open/vendor-diff-hevc-20260905/` — nine
experiments mirroring the 2026-09-04 H.264 campaign, `vdrive codec=h265` through
the public MPI, cmdbuf slots decoded from our own `/dev/mem` reads, headers parsed
with our own `h265parse.py` (ITU-T H.265 §7.3, validated against ffmpeg).
Control: the H.264 run reproduces the 2026-09-04 base in all 511 registers bar
addresses. 108/108 HEVC streams decode in ffmpeg with zero errors.

**Findings that shape the open implementation** (`REPORT.md` has every number):

- **`PT_H265` is accepted** (Main, Main tier, L5.1; Main10 header-only; MainRExt
  and SVC-T refused). Vendor HEVC config: CTB 64 / min CB 8 / TB 4..16, AMP on,
  SAO on, TMVP off, PCM off, `init_qp 32`, `cu_qp_delta` on, one short-term
  reference, `log2_max_poc_lsb 16`, no weighted prediction, no tiles/WPP.
- **The cmdbuf is the H.264 cmdbuf**: identical 570-word opcode structure,
  identical secondary-bank pokes, identical RREG/kick/tail. 19 non-address
  registers separate the HEVC IDR program from the H.264 one at 1080p: `sw4`,
  `sw5` (8-aligned dims, no `+3`), `sw6` (bit21 always, bit3 = intra), `sw9`
  (header length 92), `sw36`, `sw190 = 0`, `sw191 = 0x4c000000` (IDR), `sw193/194`
  (CABAC/8×8 bits clear), the new constant block `sw202–207` (write-only),
  `sw208`, `sw245/246` (per-CTB-row), `sw277`.
- **Geometry**: every H.264 law holds for HEVC at 35 geometries except `sw5`
  and `sw261` (`align8` instead of `align16`), `sw245/246` (`ctbw = ceil(W/64)`
  replaces `mbw`, low field `0x1010`), and **`sw114 = 0`** (one buffer fewer).
  The recon floorplan is still the MB-padded H.264 one. Refused: 136×136,
  200×136, 64×64; smallest accepted 640×480.
- **QP**: `sw7`, `sw37` and `sw125–132` are the E2 laws and tables; HEVC P frames
  index the table at `q = min(QP,35)` (no `−3`) and carry four P-variant entries.
- **RC**: fixed-QP vs CBR is exactly the E1 RC-enable set; CBR≡CVBR, VBR≡AVBR;
  QVBR/QPMAP refused. RC is codec-agnostic — #46's controller will serve both.
- **RPS/DPB**: IPPP needs only `sw11` counting (= `poc_lsb`), `sw192 = 0`, and
  the H.264 ping-pong. The long-term-reference mode (`ONELTR`) exposes the RPS
  descriptor cluster (`sw17` POC distances, `sw190[30]`, `sw91`, `sw104`, `sw198`)
  — recorded, not needed for IPPP.
- **Fixed-QP32 golden vectors** at 1080p, 720p, 1024×768, 1920×1200, 2560×1440,
  3840×2160 and 3840×2400 (`H3/`, `H3x/`) — the inputs for the open HEVC
  generator and its golden-vector test.

**Next (hevc-plan.md outline):** replay the 1080p fixed-QP32 HEVC IDR/P programs
through the open stack behind vendor-observed VPS/SPS/PPS (Step 0), then the
from-source header writer, the HEVC branch of `vcenc_geom.h`, and the
`PT_H265` dispatch in `kvm_venc_open.c` / `libkvm.c`.

### 2026-09-05 (later) — blob-free HEVC IPPP through the open stack (#64 Steps 0+1)

Same session, right after the campaign was banked. The vendor's HEVC program
turned out to be the H.264 template plus a fixed overlay, so instead of a
replay-only proof the open builder gained the overlay directly:

- `pkgs/vcenc-ewl/vcenc_encode.h`: `struct vcenc_frame.codec`
  (`ENC_CODEC_HEVC`). The overlay re-pins `sw4/36/190/191/193/194/202–207/208/
  277`, `sw6` (bit21, bit3 = intra), the min-CB laws for `sw5`/`sw261`, the
  per-CTB-row `sw245/246` (RC modes), `sw114 = 0`, P-frame `sw170/171`,
  `sw192 = sw198 = 0`, and indexes the QP tables at `q = min(QP,35)` for P
  frames with the four P-variant entries (and the `sw37` low field at q = 34).
- `pkgs/vcenc-ewl/vcenc_hevc_header.h` (new): VPS/SPS/PPS from ITU-T H.265
  §7.3.2 / 7.3.3 / 7.3.7 / E.2.1 with every hardware-dependent field pinned
  to the observed configuration; **byte-identical to the vendor's 1080p
  fixed-QP32 VPS/SPS/PPS and to the 1366×768 SPS (conformance window)** —
  `tests/hevc_header_test.c`, now part of `.#checks.open-venc-geometry`.
- `tests/vcenc_geom_test.c` `hevc_identity()`: the builder reproduces **34
  vendor HEVC fixed-QP programs** (the 1080p ladder IDR+P, fixed-QP32 at
  720p, 1024×768, 1920×1200, 2560×1440, 3840×2160, 3840×2400) with zero
  non-address differences (same two residuals as the H.264 identity test:
  `sw9` header slot, P-frame `sw105`). `gen_vectors.py` mines the HEVC
  programs into the QP tables too — the interpolated F(34) was confirmed
  exactly by the vendor's P34 program.
- `ewl_encode.c`: `EWL_CODEC=h265`.

**Device proof (open stack, `ax630c_venc_vcmd.ko`, no vendor module or
library):** IPPP HEVC at 1920×1080, 1280×720, 1366×768, 3840×2160 and
3840×2400 (6 frames each, IDR nal 19 + TRAIL_R P frames) and a 12-frame gop-3
1080p session; **every stream decodes in ffmpeg with zero errors** at the
right dimensions (Main, level 4.1/5.1/5.2), the slice headers carry
`poc_lsb` 1,2,3…, RPS `sps[0] {−1 used}`, slice QP 32, and the decoded frames
show the moving test card tracked across the P frames. 1080p IDR ≈ 2.08 M
cycles, 4K ≈ 8.3 M — the vendor's numbers. Stream sizes are roughly a third
of the H.264 ones at equal QP on the test card.

**libkvm dispatch (same session):** `kvm_venc_open.c` accepts `PT_H265`
(VPS+SPS+PPS + slice pack, `enH265EType` NAL typing, `ENC_RC_FIXQP` default for
HEVC) and `libkvm.c` maps `IMG_H265_*` requests onto a third channel
(`KVM_VENC_H265_CHN`); VPS+SPS are cached together as the "SPS". **Device-proven
through the public ABI**: a ctypes bench reader calling `kvmv_read_img(1920,
1080, IMG_H265_TYPE_SPS, …)` on the running open stack with the real HDMI
source gets VPS 27 B, SPS 53 B, PPS 12 B, a 32 KB IDR and ~200 B P frames;
ffmpeg decodes the 81-frame capture with zero errors, and the H.264/MJPEG
paths are unchanged (web 200, MJPEG streaming, H.264 bench 84 frames).

**Remaining:** a web consumer (`ReadH265` → a streamer + `hvc1`/pion H.265
client — separate issue), rate control for HEVC rides on #46 (the RC
register set is codec-agnostic, H4), and shipping the new libkvm in the next
image.

### 2026-09-05 (later still) — vendor rate controller on real HDMI content (#46 oracle)

The last cheap vendor question before the mainline move: what the vendor CBR/VBR
controller does on a real KVM desktop, not a synthetic card. Vendor stack loaded at
runtime (device-re-subagent recipe), frames recorded from the OPEN V4L2 driver
(static 1080p60 desktop, 30 byte-identical frames) and fed to the vendor encoder as
recorded or with labelled software motion (4 px/frame scroll, half-screen jumps).
51 runs, 11,400 frames, per-frame CSVs with slice QP, bytes and the RC registers:
`docs/reference/vcenc-open/vendor-diff-rc-20260905/` (README, REPORT, aggregate,
fits, tools; no desktop pixels or bitstreams committed).

- **Operating point.** A static or scrolling 1080p desktop cannot absorb 8 Mbps at
  any QP ≥ 10; at 8000/16000 the vendor runs an identical open-loop descent to the
  QP floor. The in-band regime is ~2000 kbps or heavy motion. A static P frame costs
  a constant 1890 B at QP 21.
- **Laws** (both codecs, frame-for-frame identical when a target exists): CBR IDR QP
  37 at ≤ 3000 kbps / 32 at 8000+ (HEVC 35 / 32); first P = IDR+3 on every GOP; P
  steps from r = bits/target of the previous frame — dead band ±5 %, +1 (at times
  +2) above, −1 below, −2 under 0.85, throttled to −1/frame in deep undershoot;
  |ΔQP| ≤ 2; floor IDR−11; ceiling 51 in GOP 0 then 46; IDR −2 per GOP under
  target, mean-P(prev GOP)−4 in band, never above the initial QP over target.
  Budget window = StatTime 1 s = 2 GOPs; first IDR target 0.22 × bitrate.
- **Mid-stream change** lands in the next frame's target; QP descends −1/frame,
  rises only when bits exceed the new target; the first IDR after a change
  restarts at the new bitrate's initial QP (CBR) or 32 (VBR).
- **VBR:** no IDR target, first P = IDR, up-steps +2, lands at 0.90 × cap.
- **Vendor defect, not to be copied:** HEVC CBR ≤ 7000 kbps at 1080p60 programs no
  target at all (`sw105–107 = 0`) and ramps QP open-loop to 46 — H8's undershoot
  explained.

The from-scratch controller (#46, `pkgs/vcenc-ewl/vcenc_rc.h`) is validated against
these CSVs by the `open-venc-rc` check. Bench note: USB HID to the host was down
again during the session (the #42 pattern; physical link), so no real host motion
was possible.

### 2026-09-05 (night) — h265-direct: the HEVC web consumer, device-proven (#66, closes the #64 loop)

The server and web UI now consume the blob-free H.265 channel. `service/stream/
direct/h265.go` (installed by `pkgs/nanokvm-server.nix`, route `GET /api/stream/
h265/direct`) is a second direct streamer with the H.264 framing; the one design
difference is that libkvm's VPS+SPS (both typed `IMG_H265_TYPE_SPS`) and PPS are
folded into the IDR message they precede, so every key message is self-contained
and a WebCodecs decoder configured for Annex-B starts at any IDR. The web UI
(`pkgs/patches/web-h265-direct.patch`) adds "H.265 Direct" to both mode selectors,
probes `VideoDecoder.isConfigSupported` for `hvc1.1.6.L153.B0`, and falls back to
H.264 Direct with a notice where the browser cannot decode HEVC.

Device-proven on the alpha.4 image with the hot-patched libkvm: 150 messages over
the WebSocket, every key message exactly VPS/SPS/PPS/IDR, ffprobe `hevc` Main
1920x1080 level 4.1, 150/150 frames decode with zero errors; the H.264 path is
unchanged; the fallback branch was exercised end-to-end in headless Chromium
(no platform HEVC decoder) against the real device. Not yet exercised: the
supported branch in a browser with an HEVC decoder (human at a Windows/macOS
browser). Evidence: `docs/reference/vcenc-open/h265-direct-20260905/`.
