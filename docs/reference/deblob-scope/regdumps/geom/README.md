# Geometry differential + open-vs-vendor pixel parity (2026-09-02, #59)

Our own `/dev/mem` observations and frame captures. No vendor code involved.

## Why

The M2 driver replays a register image captured while the vendor stack streamed
4K (`../regfile-vendor-live.bin`). Two questions were open: which words actually
depend on the frame geometry (the table is 4K-only), and whether the open
driver's frames are pixel-identical to the vendor's. The bench source is a
couch-UI HTPC that pins 4K30 regardless of EDID (EDID writes, HPD pulses and a
chip power cycle were all tried), so instead of a second source the *vendor
driver itself* was run at fake geometries against the 4K source.

## Method

1. `tools/geoprobe.py` drives libkvm's open-capture backend
   (`kvm_sys_init(w,h)` -> `kvm_cap_start(w,h,30)` -> `kvm_cap_get`) with the
   production vendor stack loaded and `nanokvm.service` stopped, for
   3840x2160, 1920x1080, 2560x1440, 1280x720 and 1920x1200, and dumps
   `0x02400000` (0xD4008), `0x02600000` (0x4000) and `0x02500000` (0x800)
   mid-stream. Every geometry started and delivered frames: the SIF window
   simply crops the 4K input at the top-left.
2. `tools/regdiff.py` / `tools/peek.py` diff the dumps against the 4K control.
   `regfile-vendor-fake1080p.bin` is the 1080p vendor image (second golden).
3. `tools/vendorcrop.py` saves the vendor pool frame at each geometry;
   `tools/v4l2grab.c` saves a full V4L2 frame from the open driver
   (`tools/openrun.sh` runs it across the same geometries on the base-only
   harness). Frames are compared word-for-word.

## Result: geometry words

Exactly four datapath words follow the geometry; every other word in the golden
table is invariant across the five geometries:

| register | law | 4K | 1080p |
|---|---|---|---|
| `0x02406518` SIF WIN0_SIZE | `W \| H<<16` | `0x08700f00` | `0x04380780` |
| `0x024142ec` WDMA fmt bank | `W \| H<<16` | `0x08700f00` | `0x04380780` |
| `0x024142f0` / `0x024142f4` WDMA stride | `bytes_per_line / 8` | `0x3c0` | `0x1e0` |

Correction: `0x02406530` reads `0x870` at *every* geometry -- it is not a
height. The driver had it marked `OVC_GEOM_H`; now a constant.

Everything else that differed between runs is status (SIF/IFE frame counters
`0x650c`, `0x14704/0x14724/0x14728`, `0x6448` bit4, the `0x160/0x168/0x178/0x188`
ISP-top words, deskew/clock-activity status in `0x02500000`, CSI status
`0x02600020/0x48/0x60/0x1104`) or the CDMA block (`0x01004` tracks the
vendor's `isp_model` allocation: `(phys + 0x3000) >> 3`; `0x0105c` counts).
The CSI-2 receiver has no geometry registers.

## Result: pixel parity -- the `0x142f8` zero word

The open frames were geometrically exact (each one byte-identical to the
top-left crop of the open 4K frame, as the vendor's are of theirs) but the
pixel values were wrong: every 16-bit word came out as `vendor_word << 4`
(67% exact, the rest animation of the desktop background). Diffing the register
file while the OPEN driver streamed 1080p against the vendor's 1080p image showed
one config difference in the datapath: **WDMA bank word `0x024142f8` = 4 (reset)
vs 0 (vendor)**. The golden snapshot only kept non-zero words, so the vendor's
explicit zero was never replayed and the WDMA stored 12-bit MSB-aligned samples.
With `0x142f8 = 0` the open frames match the vendor's (1080p 96%, 720p 94%,
4K 94% within Y+-4/C+-2 tolerance; 0% shifted) and the packing is plain
**YUYV**, exactly what libkvm's open venc / soft-JPEG already consume. The
earlier "UYVY" reading was an artefact of the shifted samples.

Lesson: a register image diff must include zero-valued words, or be checked by
diffing the open driver's *own* streaming state against the vendor's.

Sustained rate with the open drivers: 30.0 fps at 4K and 1080p (150- and
300-frame runs); the 17 fps in short runs is start-up latency.

## Result: the CDMA block is not needed

Dropping the `+0x1000..+0x1100` table entries (the vendor's residual CDMA
descriptor words, incl. the `0x1004` pointer into its `isp_model` allocation)
and cold-booting the harness: 1080p frames still match the vendor (98% within
tolerance), 4K runs at 29.8 fps, and the block reads reset values. The driver no
longer writes a DMA pointer to memory it does not own.
