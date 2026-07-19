# The built-in mini-display — findings & reclaim recipe

**Status: not included in the firmware.** The vendor's on-device screen is driven
by `kvm_ui`, a **closed-source** binary we don't ship (see
[architecture.md](architecture.md#the-built-in-mini-display)). This document
records what the display actually *is* and exactly how to bring it up from our own
open stack — so that **if we later decide the vendor display `.ko` blobs are
acceptable** (the same call we already made for the `ax_*.ko` media modules), the
work is a known quantity.

Everything below was verified on real hardware (a NanoKVM-Pro Desk running our
from-source firmware): the display was lit and drawn to **while the web KVM kept
running**, with no capture conflict.

- [What the display is](#what-the-display-is)
- [Orientation](#orientation)
- [Kernel modules](#kernel-modules)
- [Bring-up recipe (verified)](#bring-up-recipe-verified)
- [Drawing to it](#drawing-to-it)
- [What's closed vs open](#whats-closed-vs-open)
- [Coexistence with the web KVM](#coexistence-with-the-web-kvm)
- [If we decide the blobs are OK: a plan](#if-we-decide-the-blobs-are-ok-a-plan)
- [Reference](#reference)

---

## What the display is

A small **JD9853 SPI TFT panel** (Jadard JD9853 controller), presented as an
ordinary Linux **`/dev/fb0`** framebuffer once the driver is loaded:

| Property | Value |
|---|---|
| Controller | Jadard **JD9853** (DT `compatible = "jadard,jd9853"`) |
| Resolution | **172 × 320**, portrait (native framebuffer geometry) |
| Pixel format | **RGB565**, 16 bpp, little-endian; stride 344 B (= 172 × 2); ~110 KB total |
| Bus | SPI — `spi@6072000` / `spi2.1`, **80 MHz**, 8-bit words |
| GPIOs | reset = **GPIO41**, data/command (dc) = **GPIO43** |
| Backlight | `/sys/class/backlight/backlight` — `bl_power` **0 = on, 1 = off**; `brightness` 0–100 (`max_brightness` 100), `type = raw` |
| fps | driver reports ~90–100 |

The panel node is **already present in our from-source device tree**
(`/proc/device-tree/soc/spi@6072000/jd9853@1`, plus `soc/panel@0` / `panel@1`), so
**no DT overlay is needed** — the driver binds to the existing node.

---

## Orientation

The panel is mounted rotated relative to its native geometry. Writing horizontal
RGB bars to the framebuffer (row-major: top third red, middle green, bottom blue)
showed on the physical screen as **vertical bars in blue-green-red order** — i.e.
framebuffer rows map to physical columns and the axis is reversed. That matches the
vendor's own tool, which renders with **`--rotate R270`**. Colors were correct
(RGB565, no channel swap) — the only transform needed is a **270° rotation** in
software before writing. Any UI we draw should pre-rotate (or use the panel's
`rotate` DT property / an fbtft rotate param) so content is upright.

---

## Kernel modules

Shipped as prebuilt modules in the vendor tree at **`/kvmcomm/ko/`**. All are built
with `vermagic = 4.19.125 SMP preempt mod_unload aarch64`, i.e. **they insmod into
our from-source kernel unmodified** (same story as the `ax_*.ko` media blobs).

| Module | License | Role | Notes |
|---|---|---|---|
| `fbtft.ko` | GPL | mainline SPI-TFT framebuffer framework | **open** (Linux `drivers/staging/fbtft`) |
| `fb_jd9853.ko` | GPL | JD9853 panel driver (`depends: fbtft`) | author `iawak9lkm`, desc "FB driver for the JD9853 LCD Controller" — GPL, small; source likely obtainable / reimplementable |
| `f_udisp_drv.ko` | GPL | Axera display/pinmux glue, loaded first | vendor `.ko` blob |
| `rotary_encoder.ko` | GPL v2 | the side **knob** input | mainline (`drivers/input/misc/rotary_encoder`) |
| `gpio_keys.ko` | GPL | **button** input | mainline |

Only `f_udisp_drv` and `fb_jd9853` are genuinely vendor blobs; `fbtft`,
`rotary_encoder`, and `gpio_keys` are mainline drivers (rebuildable from our own
kernel if we ever want to drop the blob copies).

---

## Bring-up recipe (verified)

Minimal sequence to get `/dev/fb0` and a lit backlight (input modules optional):

```bash
insmod /kvmcomm/ko/f_udisp_drv.ko
insmod /kvmcomm/ko/fbtft.ko
insmod /kvmcomm/ko/fb_jd9853.ko          # depends on fbtft; load after it
echo 0 > /sys/class/backlight/backlight/bl_power   # 0 = backlight ON
# optional inputs:
insmod /kvmcomm/ko/rotary_encoder.ko
insmod /kvmcomm/ko/gpio_keys.ko
```

`dmesg` then shows: `graphics fb0: fb_jd9853 frame buffer, 172x320, 107 KiB video
memory ... spi2.1 at 80 MHz`.

For reference, the vendor's full order (from `/kvmcomm/scripts/kvmcomm.sh`) is:
`rotary_encoder` → `gpio_keys` → `f_udisp_drv` → (`lt6911_manage`) →
**`start_kvm_vin`** (the capture feeder — we skip this, it conflicts with our
`libkvm`) → start server → `fbtft` → `bl_power=1` → `fb_jd9853` → `bl_power=0`.
(They blank the backlight around the panel init to hide init garbage, then unblank.)

---

## Drawing to it

`/dev/fb0` is a raw RGB565 surface (172×320, stride 344). This exact snippet drew
correctly on hardware:

```python
import struct
w, h, stride = 172, 320, 344
def rgb565(r, g, b): return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
fb = open("/dev/fb0", "r+b")
out = bytearray()
for y in range(h):
    c = rgb565(255,0,0) if y < h//3 else rgb565(0,255,0) if y < 2*h//3 else rgb565(0,0,255)
    row = struct.pack("<%dH" % w, *([c]*w))
    out += row + b"\x00" * (stride - len(row))
fb.seek(0); fb.write(out); fb.close()
```

Sipeed also ship an **open Python framebuffer API** for exactly this — inside
`/kvmcomm/ui/userapp_demo.tar` there is a `Framebuffer` class (`framebuffer.py`,
`mmap` + `FBIOGET_VSCREENINFO`/`FBIOGET_FSCREENINFO` ioctls + PIL for text/images)
plus a set of demo "user apps" (clock, power-button, Conway, etc.). It's a clean
reference for a higher-level UI without touching any closed binary.

---

## What's closed vs open

- **Closed (not shipped by us):** `kvm_ui` (8.5 MB) and `frameforge` (988 KB) —
  vendor UI binaries, **no source published** in Sipeed's repo. `frameforge`
  renders "lvbin" (LVGL binary) assets to `/dev/fb0`
  (`frameforge --lvbin <asset> --rotate R270 --obin /dev/fb0`); `/kvmcomm/ui/srcs/`
  holds the JPG UI screens (host info, KVM info, live preview, settings). **We need
  none of this** — the framebuffer is standard and we can render our own UI.
- **Open / usable:** the `/dev/fb0` framebuffer, the Python `framebuffer.py` API,
  and the mainline `fbtft`/`rotary_encoder`/`gpio_keys` drivers.
- **Vendor blobs (the decision):** `f_udisp_drv.ko` and `fb_jd9853.ko`. Including
  the mini-display means accepting these two `.ko`s (both GPL, so source is
  obtainable in principle; `fb_jd9853` is a small fbtft panel that could be
  rewritten from the datasheet) — the same kind of call already made for `ax_*.ko`.

---

## Coexistence with the web KVM

The display path (SPI panel → `/dev/fb0`) is **independent of the capture path**
(HDMI → MIPI_RX → VIN → VENC). Loading the three display modules and drawing to
`/dev/fb0` left our `NanoKVM-Server` untouched — verified `:80/:443` still
listening, `GET / → 200`, server still running.

The thing that *does* conflict is `kvm_vin`, the vendor **capture** feeder that
supplies a live HDMI preview to the screen — it wants the same MIPI/VENC pipeline
our `libkvm` owns. So a **live preview** on the mini-display must be fed from
`libkvm`'s frames, not by running `kvm_vin`. Static/status screens need no capture
at all.

---

## If we decide the blobs are OK: a plan

1. **Persistence.** A small systemd unit (or a hook in the nanokvm bring-up) that
   `insmod`s `f_udisp_drv` + `fbtft` + `fb_jd9853` (and `rotary_encoder` +
   `gpio_keys` for input), then sets `bl_power=0`. Optionally package the two
   vendor `.ko`s in the image (pin like `ax_*.ko`) instead of reading them from the
   vendor `/kvmcomm/ko/`.
2. **Content.** Draw a status screen (IP, HDMI resolution, connected clients,
   power state) — the info the vendor's `srcs/` screens showed — using the
   `framebuffer.py` approach (PIL → rotate 270° → `/dev/fb0`). Optionally add a
   **live HDMI preview** by tapping `libkvm`'s decoded frames and blitting a
   downscaled copy to the panel.
3. **Input.** Wire the knob + buttons (`rotary_encoder` + `gpio_keys` expose evdev
   devices) to navigate the on-screen UI.
4. **Blob policy.** `fbtft`/`rotary_encoder`/`gpio_keys` can be built from our own
   kernel (drop the blob copies); only `f_udisp_drv` + `fb_jd9853` would remain as
   pinned vendor blobs — or reimplement `fb_jd9853` as an open fbtft panel.

---

## Reference

```
Panel:      Jadard JD9853, 172x320 RGB565, SPI spi2.1 @ 80 MHz, reset=GPIO41 dc=GPIO43
DT node:    /proc/device-tree/soc/spi@6072000/jd9853@1  (compatible "jadard,jd9853")  [already in our dtb]
Framebuffer:/dev/fb0  172x320  16bpp  stride=344  (~110 KB)  name "fb_jd9853"
Backlight:  /sys/class/backlight/backlight  bl_power(0=on,1=off) brightness(0..100)
Modules:    /kvmcomm/ko/{f_udisp_drv,fbtft,fb_jd9853,rotary_encoder,gpio_keys}.ko
            vermagic 4.19.125 SMP preempt mod_unload aarch64  (loads into our kernel)
Rotation:   physical = framebuffer rotated 270° (vendor uses --rotate R270)
Closed:     /kvmcomm/ui/{kvm_ui,frameforge}  (no source);  assets in /kvmcomm/ui/srcs
Open API:   /kvmcomm/ui/userapp_demo.tar -> framebuffer.py (mmap + fbdev ioctls + PIL)
```
