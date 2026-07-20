# The built-in mini-display — INCLUDED, fully from source

**Status: included in the firmware, with ZERO vendor display blobs.** The panel
driver stack is built from our own kernel tree and a small open Python status
daemon draws to it. The vendor's closed `kvm_ui`/`frameforge` binaries and the
prebuilt `/kvmcomm/ko/*.ko` copies are neither shipped nor used (the rootfs
overlay still deletes them — see `pkgs/rootfs.nix` step 5d).

The panel findings below were verified on real hardware (a NanoKVM-Pro Desk
running our from-source firmware); the orientation mapping was additionally
confirmed against a live framebuffer dump from a stock-firmware device. The
from-source module + daemon combination has been verified by build-time module
equivalence and an off-device harness — the final on-device boot test is
pending (see [Hardware verification](#hardware-verification)).

- [What the display is](#what-the-display-is)
- [How it is blob-free](#how-it-is-blob-free)
- [What ships in the image](#what-ships-in-the-image)
- [The status daemon](#the-status-daemon)
- [Orientation](#orientation)
- [Drawing to it](#drawing-to-it)
- [Coexistence with the web KVM](#coexistence-with-the-web-kvm)
- [Hardware verification](#hardware-verification)
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
| Inputs | knob button = `gpio-keys` (KEY_ENTER, code 28); knob rotation = `rotary-encoder` (REL_X, gray-coded) |
| fps | driver reports ~90–100 |

The panel node is **already present in our from-source device tree**
(`/proc/device-tree/soc/spi@6072000/jd9853@1`), as are the `gpio_keys` and
`rotary@0` input nodes and the pwm `backlight` node — no DT changes were needed.

---

## How it is blob-free

The vendor ships five prebuilt display modules in `/kvmcomm/ko/`. It turned out
**all five already exist as source in the SDK kernel tree we build**
(`maix_ax620e_sdk_kernel`, `linux/linux-4.19.125`), and the vendor NanoKVM
defconfig (which we build unmodified) already sets them all to `=m` — so our
existing `make modules` was *already producing all five from source*:

| Vendor blob | Our from-source equivalent | Kconfig (already `=m` in the defconfig) |
|---|---|---|
| `fbtft.ko` | `drivers/staging/fbtft/fbtft.ko` | `CONFIG_FB_TFT` |
| `fb_jd9853.ko` | `drivers/staging/fbtft/fb_jd9853.ko` (full source: `fb_jd9853.c`, GPL, author `iawak9lkm`) | `CONFIG_FB_TFT_JD9853` |
| `f_udisp_drv.ko` | `drivers/usb/gadget/function/f_udisp_drv.ko` (source: `f_udisp.c` + `f_sourcesink.c`) | `CONFIG_USB_F_UDISP` |
| `rotary_encoder.ko` | `drivers/input/misc/rotary_encoder.ko` (mainline) | `CONFIG_INPUT_GPIO_ROTARY_ENCODER` |
| `gpio_keys.ko` | `drivers/input/keyboard/gpio_keys.ko` (mainline) | `CONFIG_KEYBOARD_GPIO` |

So **no kernel config changes were required** — only wiring: the modules were
already in `/usr/lib/modules` (the rootfs ships the whole from-source modules
tree); what was missing was loading them and drawing something.

**What `f_udisp_drv` actually is:** not display/pinmux glue as first assumed —
it is a **USB gadget function** ("UDISP", a Sipeed edit of `f_loopback.c`,
`drivers/usb/gadget/function/f_udisp.c`) that lets the device present itself as
a *USB display* to the attached host (frames arrive over USB and get
decoded/drawn). It has no role in driving the SPI panel — `fb_jd9853`'s only
module dependency is `fbtft`, and neither references any UDISP symbol; the
vendor merely loads it first because their `kvm_ui` stack also offers the
USB-display feature. We build it from source like everything else but do
**not** load it.

Fonts for the status daemon are also blob-free: generated **at build time** from
`terminus_font` (a nixpkgs package built from source) into a plain-Python
literal module (`pkgs/nanokvm-display/gen_font.py`).

---

## What ships in the image

1. **Modules** (all from our kernel build, in `/usr/lib/modules/4.19.125/`):
   `fbtft`, `fb_jd9853`, `gpio_keys`, `rotary_encoder` are loaded at boot via
   `/etc/modules-load.d/nanokvm.conf` (`fb_jd9853` pulls `fbtft` through
   `modules.dep`). All four are parameter-less-safe DT-bound drivers, so this
   explicit load **cannot** re-create the `ax_cmm` autoload brick
   (`docs/provenance.md`, `pkgs/rootfs.nix` step [4]).
2. **Status daemon**: `/opt/nanokvm-display/nanokvm_display.py` (+
   `font_data.py`), run by the enabled systemd unit
   `nanokvm-display.service`. Package: `pkgs/nanokvm-display.nix`.
3. The OTA update package carries the same payload (`pkgs/update-package.nix`).

---

## The status daemon

Pure-stdlib **Python** (the Ubuntu-arm64 base already ships `python3`; no PIL,
no new interpreter, no pip packages). Source: `pkgs/nanokvm-display/nanokvm_display.py`.

Shown (refreshed every 2 s while awake):

- hostname
- **IP address(es)** (large font; `ip -j -4 addr`, skipping `lo`)
- **video state** — `LIVE <n> fps` (green) while a client is actively
  streaming, `idle (no viewer)` otherwise, `server not running` if the KVM
  server is down. Source: `GET /api/streamer/local` on loopback (no auth from
  127.0.0.1); its `captured_fps` mirrors the server's `RealFPS` counter, which
  is only non-zero while a client is pulling frames.
- HDMI input resolution (`/proc/lt6911_info/{width,height}`)
- firmware version (`/kvmapp/version`) + uptime

**Sleep/wake (panel preservation):** after **3 minutes** without knob/button
input (`SLEEP_TIMEOUT_S = 180` in the daemon; env `NANOKVM_DISPLAY_SLEEP_S`
overrides, `0` = never sleep) the daemon blanks the panel, switches the
backlight off (`bl_power=1`) and stops refreshing. **Pressing the knob button
wakes it** (backlight on + immediate redraw); turning the knob wakes it too.
The waking press *only* wakes — it triggers nothing else. While awake, any
knob/button activity resets the inactivity timer. Input is read straight from
the `gpio_keys` / `rotary_encoder` evdev devices (discovered by name via
`EVIOCGNAME`, re-scanned periodically).

**Extending the screen** is intentionally trivial: add a
`(font, color, text)` tuple in `build_lines()` — the renderer stacks lines
top-down. Fonts available: `small` (Terminus 8×16 → 40 cols) and `big`
(Terminus Bold 14×28 → 22 cols); add more PSF sizes in `pkgs/nanokvm-display.nix`
if needed.

---

## Orientation

The panel is mounted rotated relative to its native geometry: **physical pixel
(x, y)** on the 320×172 landscape face shows **framebuffer cell
[row 319−x, column y]**. This exact mapping was confirmed by dumping the stock
firmware's live framebuffer and un-rotating it (the vendor renders with
`--rotate R270`). The daemon renders a 320×172 landscape canvas and emits fb
row *r* as canvas column *(319−r)* top-to-bottom — a cheap strided-slice
transpose (`Canvas.to_fb_bytes`). Colors are straight RGB565, no channel swap.

---

## Drawing to it

`/dev/fb0` is a raw RGB565 surface (172×320, stride 344). Minimal test:

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

(For upright content use the orientation mapping above, as the daemon does.)

---

## Coexistence with the web KVM

The display path (SPI panel → `/dev/fb0`) is **independent of the capture path**
(HDMI → MIPI_RX → VIN → VENC). Loading the display modules and drawing left
`NanoKVM-Server` untouched — verified `:80/:443` still listening while drawing.

The thing that *does* conflict is `kvm_vin`, the vendor **capture** feeder that
supplies a live HDMI preview to the screen — it wants the same MIPI/VENC
pipeline our `libkvm` owns. So a future **live preview** on the mini-display
must be fed from `libkvm`'s frames, not by running `kvm_vin`. The status screen
needs no capture at all.

Related finding (capture-idle behavior): when the last web viewer disconnects,
the server's streaming goroutines exit and stop pulling frames — encoding
stops — but nothing tears the pipeline down (`kvmv_deinit` has no idle-path
caller), so VIN/VENC stay initialized and the LT6911 HDMI-RX stays powered.
There is no automatic capture power-down on idle.

---

## Hardware verification

**Verified on hardware:**

- All panel-side findings (top table, DT node, backlight, `/dev/fb0`
  behavior) — on a NanoKVM-Pro Desk running this firmware.
- The **orientation mapping** — by dumping the live framebuffer of a
  stock-firmware NanoKVM-Pro while its vendor UI was drawing and un-rotating
  it (the "Welcome / visit IP" screen reads upright exactly under
  `phys(x,y) = fb[319-x][y]`); the daemon uses that same mapping.

**Verified off-device (strong evidence, final boot test pending):**

- Our five modules build from the SDK kernel source with vermagic
  `4.19.125 SMP preempt mod_unload aarch64` — identical to the vendor blobs.
- Symbol-table equivalence: for each of the five, the defined- and
  undefined-symbol sets of our `.ko` match the vendor's `/kvmcomm/ko` blob
  exactly (sole diff: our `fbtft` imports `memset`, which the vendor's GCC
  inlined — `memset` is a core exported symbol). Same sources, same ABI.
- The daemon end-to-end in a harness: render → rotate → fb-file write, plus
  the full **sleep → blank/backlight-off → wake-on-button-press** cycle
  against a synthetic evdev stream.

**Pending on real hardware:** one boot of the built image (or an insmod of our
`fbtft.ko`+`fb_jd9853.ko` on a live device) to watch
`graphics fb0: fb_jd9853 frame buffer, 172x320` appear and the daemon light the
panel. The attempt during development was cut short: **unloading the vendor's
loaded `fb_jd9853` hard-hung the stock test device** (its TE-timer/workqueue
teardown deadlocks; the module's *load* path is what we exercise at boot and is
unaffected) — the device needed a power cycle before the swap could complete.

Quick post-flash checklist:

```bash
lsmod | grep -E 'fbtft|jd9853|gpio_keys|rotary'   # loaded at boot
dmesg | grep fb_jd9853                            # "frame buffer, 172x320"
systemctl status nanokvm-display                  # active (running)
# panel shows hostname/IP/status; goes dark after 3 min; knob press wakes it
```

---

## Reference

```
Panel:      Jadard JD9853, 172x320 RGB565, SPI spi2.1 @ 80 MHz, reset=GPIO41 dc=GPIO43
DT node:    /proc/device-tree/soc/spi@6072000/jd9853@1  (compatible "jadard,jd9853")
Framebuffer:/dev/fb0  172x320  16bpp  stride=344  (~110 KB)  name "fb_jd9853"
Backlight:  /sys/class/backlight/backlight  bl_power(0=on,1=off) brightness(0..100)
Inputs:     gpio-keys "GPIO KEY ENTER" (KEY_ENTER/28), rotary-encoder (REL_X)
Modules:    OURS, from source, /usr/lib/modules/4.19.125/kernel/...
            fbtft.ko fb_jd9853.ko gpio_keys.ko rotary_encoder.ko (loaded at boot)
            f_udisp_drv.ko (built, NOT loaded -- USB-display gadget function)
Rotation:   physical (x,y) = fb[row 319-x, col y]  (vendor's R270)
Daemon:     /opt/nanokvm-display/nanokvm_display.py  (nanokvm-display.service)
            sleep after 180 s idle (backlight off), wake on knob button/turn
Closed junk:kvm_ui / frameforge / kvm_vin and /kvmcomm/ko blob copies -- still
            REMOVED from the image (pkgs/rootfs.nix 5d)
```
