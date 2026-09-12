# Where the frames went (#107) — 2026-09-12

The board delivered 21.5 fps from a 29.97 fps 4K source. Raw capture was never
the reason: **the V4L2 driver produces the source rate exactly, and always
has.** The missing 8 fps were the encoder's core clock sitting on its
power-on tap plus a byte-at-a-time read of the bitstream out of
write-combining memory.

Source throughout: the bench host at **4096x2160@29** (`/proc/lt6911_info`,
`access`), playing a movie so every frame differs. Kernel 7.1.3-nanokvm,
generation 25 before the fix and 26 after. `nanokvm` stopped for every
capture measurement (one capture channel serves one consumer).

## The tools

`tools/capmeas.c` — plain V4L2 MMAP streaming for N seconds. Modes `none`
(DQBUF/QBUF only, no pixel ever read), `page`, `word`, `copy`. It reports the
dequeued rate **and** the V4L2 `sequence` span over the same window, so the
hardware's rate and the consumer's rate are separated by construction: a
`sequence` gap is a frame the WDMA dropped because nothing was queued.

`tools/pipebench.c` — links the shipped `libkvm.so` and calls the very
functions `kvmv_read_img` calls, in that order, timing each: `kvm_cap_get`,
`kvm_venc_send`, `kvm_cap_release`, `kvm_venc_get`, `kvm_venc_release`. Mode
`cap` runs the capture half alone. `OPENKVM_VENC_TIME=<n>` (the instrument
added to `kvm_venc_open.c` in this issue) splits `kvm_venc_send` itself into
cmdbuf build, LINK_RUN, WAIT_CMDBUF and the bitstream read-back, and prints
the VC8000E's own per-frame cycle count.

Both cross-compiled against the appliance's glibc and run from `/tmp`; the
instrumented `libkvm.so` was dropped in `/tmp/ilib` and reached through
`LD_LIBRARY_PATH`, so every measurement below except the last needed no
generation switch at all.

## What the four points measured, before the fix

| point | method | result |
|---|---|---|
| source | `/proc/lt6911_info` | 4096x2160, `fps` 29 (29.97 measured) |
| driver | `capmeas … 60 none`, `/proc/interrupts` deltas | **29.97 fps**, sequence span 1799 over 1799 frames, **0 gaps**, 1801 frame-done interrupts |
| libkvm capture | `pipebench 4096 2160 30 cap` | **29.95 fps**, 0 frames lost, `cap_get` 33.4 ms (all of it the wait for the next frame) |
| libkvm capture+encode | `pipebench 4096 2160 60 h264` | **21.28 fps**, 520 of 1797 frames lost |
| web route | `wsgrab.py … h264` (#98) | 23.0 fps |

The driver's own number settles the question the issue asked. It also settles
the archaeology: the 30.0 fps recorded on the 4.19 harness in 2026-09-02 and
the 21.5 fps recorded in #98 are **not the same measurement** — the first is
`v4l2grab`'s bare dequeue loop, the second is the encoded rate under a row
labelled "Raw rate". Repeating the 4.19-era measurement on mainline gives
29.97, so there is no capture regression to explain.

## Where the 8 fps went

`pipebench` puts 99.9 % of the loop's wall time inside `kvm_venc_send`, at a
mean of **46.95 ms** a frame. `OPENKVM_VENC_TIME` splits it:

```
[openvenc][time] n=900 build=0.01 run=0.00 wait=41.64 hdr=0.00 copyout=5.27 ms/frame (50141 B out, 8643311 cycles)
```

### 41.64 ms: the VC8000E at its reset clock

`clk_venc_eb`'s parent mux `clk_vpu_glb_sel` offers cpll_208m, cpll_312m,
epll_375m, cpll_416m, epll_500m and npll_533m. It comes out of reset on index
0 — the **lowest** — and a mainline boot moves nothing, so the encoder ran at
208 MHz. 8 643 300 cycles / 208 MHz = 41.55 ms, which is the measured wait to
0.1 ms; the `wait` ioctl is the hardware, with nothing wasted around it.

The encoder is cycle-deterministic and compute-bound. Repointing the mux at
runtime (`devmem 0x04030000 32 …`, with the encoder idle) and re-measuring:

| mux | rate | cycles/frame | `wait` | delivered |
|---|---|---|---|---|
| cpll_208m (reset) | 208 MHz | 8 643 298 | 41.64 ms | 21.3 fps |
| cpll_312m | 312 MHz | 8 643 382 | 27.76 ms | 29.4 fps |
| cpll_416m | 416 MHz | 8 643 303 | 20.83 ms | 29.8 fps (source-limited) |

**The cycle count does not move.** That is the measurement that says the core
is not waiting on DDR at any of these clocks — `aclk_vpu_top_sel` already runs
at 533 MHz — and that the clock is a pure multiplier. 0.98 cycles per pixel at
4096x2160.

### 5.0 ms: a byte loop over write-combining memory

The finished bitstream is read out of the encoder framebuf, which
`hantrovcmd_mmap` maps `pgprot_writecombine` (Normal non-cacheable). The read
was one `volatile uint8_t` at a time — **one bus round trip per byte**, 200 ns
each, 5.0 ms for a 25 kB frame (5 MB/s). Measured against the alternatives at
208 MHz, same source:

| read-back | `venc_send` | delivered |
|---|---|---|
| `volatile uint8_t` loop | 45.15 ms | 22.05 fps |
| `volatile uint64_t` loop | 42.10 ms | 23.67 fps |
| `memcpy` | 41.84 ms | 23.80 fps |

The 64-bit loop is what shipped: it is within noise of `memcpy` and does not
rest on glibc's behaviour over a non-cacheable mapping. Both `off_out` (4 kB
aligned) and `ENC_STREAM_SUBOFF` (0x28) are 8-aligned, so the source always
is; the destination is not, hence a `memcpy` of each word rather than a
`uint64_t` store.

**How expensive uncached memory is, for the record:** `capmeas … copy`
memcpy's a whole 17.7 MB frame out of the capture pool at **125 MB/s** — 141.6
ms a frame, 7.05 fps, with the driver dropping 1370 frames to keep up. Nothing
in the datapath may touch a frame with the CPU; the encoder gets the bus
address through the dma-buf import and that is the only reason 4K works at
all.

## After: the shipped fix

`cpll_312m` in the DT (`assigned-clocks`/`assigned-clock-parents` on `&venc`,
asserted by `.#checks.mainline-dtb`) and the 64-bit read-back. One generation
switch, generation 26, 0xB0010001 at the health gate and cleared.

| point | method | result |
|---|---|---|
| source | `/proc/lt6911_info` | 4096x2160@29 |
| driver | `capmeas … 60 none` | **29.97 fps**, 0 sequence gaps |
| libkvm capture+H.264 | `pipebench … 60 h264` | **29.96 fps**, 0 frames lost, 0 `cap_get` misses |
| libkvm capture+H.265 | `pipebench … 30 h265` | **29.93 fps**, 0 frames lost (8 329 154 cycles) |
| web route | `wsgrab.py /tmp/route.h264 900 90 h264` | 900 messages in 30.10 s = **29.90 fps**; the file decodes as 900 frames, 4096x2160, **0 errors** |

`kvm_venc_send` is now 28.45 ms (wait 27.78 + copyout 0.65), so the loop is
**source-limited**: `cap_get` spends 4.9 ms a frame waiting for the next one.

Stability: a 180 s continuous 4K encode at 312 MHz gave 5395 frames, 29.97
fps, **zero lost**, and the 174 MB clip decoded to 5395 frames with no errors.

## What is left

- **1.6 fps of encoder headroom at 4096x2400.** 2400 lines is ~9.6 Mcycles,
  30.8 ms at 312 MHz, against a 33.3 ms budget. It fits, but cpll_416m is the
  next tap if a faster source ever appears.
- **MJPEG is still 2.4 fps at 4K.** That is the software JPEG encoder (#51),
  untouched by any of this.
- **Nobody knows what the vendor firmware ran this mux at.** 208 MHz is the
  reset value, not a vendor decision we inherited; no dump of `0x04030000`
  from a vendor boot exists, and the vendor stack is gone from the board.
  312 MHz rests on the mux's own parent list plus 5395 decoded frames.
