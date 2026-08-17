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
initramfs binaries, `eip_ax620e.bin`, the vendor base rootfs). This document is
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
- Only **12 of 22** vendor-loaded modules are needed for video — module-set
  curation remains future work (needs reboot-cycle testing; see #30's closing
  notes).

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

#### 8. Device-tracing experiments for the follow-up (device-side) phase — DO NOT run here

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
64×64 minimum, 1920×1200 maximum. The ceiling is the link budget, not the
payloads: 4 lanes × 600 Mbps ≈ 2.4 Gbps and YUV422-8 is 16 bpp, so ~2.5 Mpx at
60 Hz saturates the DPHY — 1920×1200 is the largest standard mode inside it,
and we have no decoded way to program another rate. Out-of-envelope geometries
are **refused** (bring-up returns an error and logs the reason) rather than
clamped: clamping is what produced #17's garbage frames, because it drives the
pipe at a resolution the source is not sending.

**Assumptions made where the RE record is silent.** The only full-struct vendor
capture that exists is 1080p, so no vendor bytes for another resolution have
ever been observed. Each assumption is a no-op at 1920×1080:

1. The three "second width" fields (dev attr `@0xdc`, nr42 `@0x24`, nr48
   `@0x10`) are line strides **in pixels** — they equal the width in the
   capture, sit immediately after a `{width,height}` pair, and correspond to
   the single `nWidthStride` the vendor-MPI structs set for those same calls.
2. Stride is padded up to 16 px (32 B) — `KVM_GEOM_STRIDE_ALIGN`. No measured
   alignment rule exists; 16 px matches the AX DMA/VENC habit, is a no-op for
   every standard HDMI width except 1366 (→1376), and can only over-size a
   pool block, never under-size one. `BlkSize` follows the stride for the same
   reason. If a non-1080p bring-up ever shears, set the knob to 2.
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
