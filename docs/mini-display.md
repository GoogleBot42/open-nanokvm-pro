# The built-in mini-display — INCLUDED, fully from source

**Status: included in the firmware, with ZERO vendor display blobs.** The panel
driver stack is built from our own kernel tree and a small open Python status
daemon draws to it. The vendor's closed `kvm_ui`/`frameforge` binaries and the
prebuilt `/kvmcomm/ko/*.ko` copies are not shipped: since #97 there is no
vendor-derived rootfs to strip them out of — the appliance is built from
source and nothing puts them on it.

The panel findings below were verified on real hardware (a NanoKVM-Pro Desk
running our from-source firmware); the orientation mapping was additionally
confirmed against a live framebuffer dump from a stock-firmware device. The
from-source module + daemon stack was proven end-to-end on the device
(2026-08-15, see [Hardware verification](#hardware-verification)).

**The shipped stack is mainline.** The 4.19 image the panel was first brought
up on was deleted in #97, so every section before
[Mainline (#84)](#mainline-84) describes the **4.19 bring-up** — kept because
the panel, its geometry, `/dev/fb0`, the orientation mapping and the daemon are
unchanged, and the findings are where they were established. That section is
the delta: which drivers replaced which, and what the hardware proved.

**The mainline panel was proven on the board on 2026-09-11** — `/dev/fb0`, the
daemon drawing the real status screen, the backlight's duty cycle read out of
the PWM registers, the 3-minute blank and the wake. What is still open is
audio, and only because the attached HDMI source sends none.

- [What the display is](#what-the-display-is)
- [How it is blob-free](#how-it-is-blob-free)
- [What ships in the image](#what-ships-in-the-image)
- [The status daemon](#the-status-daemon)
- [Live HDMI preview](#live-hdmi-preview)
- [Orientation](#orientation)
- [Drawing to it](#drawing-to-it)
- [Coexistence with the web KVM](#coexistence-with-the-web-kvm)
- [Mainline (#84)](#mainline-84)
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
   (`docs/provenance.md`).
2. **Status daemon**: `/opt/nanokvm-display/nanokvm_display.py` (+
   `font_data.py`), run by the enabled systemd unit
   `nanokvm-display.service`. Package: `pkgs/nanokvm-display.nix`.
3. **ATX GPIO**: the server and the knob's control page actuate the target's
   power/reset lines through `nanokvm-gpio` (`pkgs/nanokvm-gpio.nix`), which
   resolves each line by its device-tree `gpio-line-names` entry —
   `atx-power`, `atx-reset`, `atx-power-led`, `atx-hdd-led` — over libgpiod
   v2. Without it the server's `POST /api/vm/gpio` (web UI power menu) and the
   knob control page have nothing to actuate.

   **The SW_PWR pinmux trap — RETIRED by #81.** It no longer applies, and this
   is why the device tree names those lines. On 4.19 the lines were driven
   through legacy sysfs, and sysfs GPIO export **never programs the pinmux**
   on this SoC (the vendor `axera-pinctrl` doesn't wire `gpio_request_enable`
   to the mux). `gpio7` sits on the **`VI_D7` camera-data pad** (mux register
   `0x02300060`, function 6 = `GPIO0_A7`, correct word `0x00060003`), and the
   closed capture stack re-muxed that pad group back to camera-data function
   on pipeline init, so no boot-time write stuck — "reset works but power
   doesn't", because reset (`UART3_RXD`, `0x02304090`) and the LED senses
   (`CDTX_L0N/P`, `0x0230A00C`/`0x0230A018`) were never touched by capture.
   The 4.19 fix was a `/dev/mem` re-assert in the Go server before every power
   press. On mainline the **request itself programs the pad**: `gpio-ranges`
   in the DT routes a claim through `gpio_request_enable`, so there is no
   sysfs export, no boot-time pad poke and no per-press re-assert anywhere in
   the tree. The vendor's own `gpio.sh` poking `0x02302024` (GPIO3_A2's
   register, not VI_D7's) stands as the original clue that stock firmware had
   the same bug. One reading habit survives: a GPIO's `value` echoes the
   output latch and proves nothing about the ball — check the pad word.

---

## The status daemon

Pure-stdlib **Python** (no PIL, no pip packages — the daemon runs on the
`pkgs.python3` already in the appliance closure). Source:
`pkgs/nanokvm-display/nanokvm_display.py`.

Shown (refreshed every 2 s while awake):

- hostname
- **IP address(es)** (large font; `ip -j -4 addr`, skipping `lo`)
- **target host power** — `host on`/`off`, read from the ATX power-LED sense:
  `nanokvm-gpio get atx-power-led`, whose logical value already applies the
  DT's active-low flag (on 4.19 it was the raw, inverted `gpio75` sysfs latch);
  `?` if the line cannot be read
- **video state** — `LIVE <n> fps` (green) while a client is actively
  streaming, `idle (no viewer)` otherwise, `asleep (power save)` once the
  server has suspended the capture pipeline after its idle timeout (see
  [architecture.md](architecture.md), *capture lifecycle*), `server not
  running` if the KVM server is down. Source: `GET /api/streamer/local` on
  loopback (no auth from 127.0.0.1); its `captured_fps` mirrors the server's
  `RealFPS` counter, which is only non-zero while a client is pulling frames,
  and its `video_state` field reports `active`/`suspended`. This poll never
  touches the frame-read path, so the display can never keep capture awake,
  and the endpoint keeps answering while the pipeline is suspended.
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

**Target-control page (knob-driven power/reset):** twisting the knob on the
status page opens a control page; twisting moves the selection (`back`,
`hdmi preview` — see [Live HDMI preview](#live-hdmi-preview) —
`power press`, `reset`, `force off (8s)` — selection starts on `back` so
stray input is harmless), pressing the knob arms an amber confirm screen
(`press = confirm, twist = cancel`, auto-cancels after 8 s), and a second
press fires the action. Actions go through the KVM server's loopback
`POST /api/vm/gpio` (no auth from 127.0.0.1; press durations mirror the web
UI: 800 ms click, 8 s force-off) in a worker thread, so even an 8-second
hold never blocks knob input; a `done`/`FAILED` result flashes afterwards.
Both pages show the target's power state via the power-LED read above. Falling asleep resets to the status page. Slow status sources (the `ip` subprocess and the streamer poll)
run in a `StatusPoller` thread that pauses during panel sleep, so knob
latency is never bounded by server health.

**Extending the screen** is intentionally trivial: add a
`(font, color, text)` tuple in `build_lines()` — the renderer stacks lines
top-down. Fonts available: `small` (Terminus 8×16 → 40 cols) and `big`
(Terminus Bold 14×28 → 22 cols); add more PSF sizes in `pkgs/nanokvm-display.nix`
if needed.

---

## Live HDMI preview

**Included, device-verified 2026-08-16** (issues #36/#33). The `hdmi preview`
entry on the control page shows the captured HDMI input live on the panel.
Press = back; falling asleep exits too. It honors the coexistence constraint
below by design: the preview is **fed from libkvm's own frames** — no second
capture pipeline, no `kvm_vin`.

How the pieces fit (each layer does the only thing it can do cheaply):

1. **libkvm** (`pkgs/kvm-encoder/src/kvm_preview.c`) converts a held capture
   frame (YUYV 4:2:2, the live source geometry) straight into the panel's
   native fb layout — 172×320 portrait RGB565-LE, pre-rotated with the
   verified orientation mapping, letterboxed to preserve aspect — and
   publishes it atomically (write + `rename(2)`) to `/dev/shm/nanokvm-preview`
   (32-byte header: magic/seq/geometry/`CLOCK_MONOTONIC` stamp + 110 080-byte
   payload). Rate-limited to ~12 fps; nearest-neighbour + integer BT.601,
   a few ms per frame on the A53.
2. **The Go server** exposes loopback-only `POST /api/streamer/preview`
   (`pkgs/nanokvm-server/panel-preview.go.in` + the lease logic in
   `video-power.go.in`). Each POST extends a 3 s lease; while it is fresh, a
   single goroutine ticks our libkvm extension `kvmv_preview_tick()` at 10 Hz
   and marks video activity (so idle suspend stays away and a suspended
   pipeline resumes on entry).
3. **`kvmv_preview_tick`** (in `libkvm.c`) is what makes coexistence free:
   if the encoder read path has captured a frame in the last 300 ms (a web
   viewer is streaming), the tick is a no-op — the viewer's own frames feed
   the publisher via a tap in `kvmv_read_img`. Otherwise the tick captures a
   frame itself and releases it **without touching VENC**: no encoded pack is
   stolen from a web stream, no codec switch happens, and the preview works
   with zero viewers connected (including from a cold idle-suspended state).
4. **The daemon** POSTs the keep-alive ~1×/s from a background thread while
   the page is open and just blits the freshest payload to `/dev/fb0` when
   the header seq changes — zero per-pixel Python. A stale feed (>2 s: no
   signal, server down, pipeline warming) falls back to a rendered status
   screen (`starting video` / `no hdmi signal` / `server off`).

Lifecycle: page closed (or panel asleep) → keep-alives stop → lease expires
in ≤3 s → ticking stops → the normal `videoIdleTimeout` suspends capture.
The lease means a crashed daemon can never pin the pipeline awake.

Verified on device with a live 1080p source: correct orientation/colors on
the panel (fb dump == published payload, byte-exact), lease open/expiry in
the server log, and a simultaneous loopback MJPEG viewer pulling 28 fps while
the panel preview stayed live.

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
pipeline our `libkvm` owns. This is why the shipped
[live preview](#live-hdmi-preview) is fed from `libkvm`'s frames, never by
running `kvm_vin`. The status screen needs no capture at all.

Related (capture-idle behavior): when the last web viewer disconnects, the
server's streaming goroutines exit and stop pulling frames — and after
`videoIdleTimeout` (default 5 min) the server now also suspends the SoC-side
capture pipeline (VIN/VENC/MIPI_RX + audio capture; the LT6911 HDMI-RX stays
powered so the host keeps seeing its monitor). See
[architecture.md](architecture.md), *capture lifecycle & idle power-down*.

---

## Mainline (#84)

The panel, its backlight, the knob and the LT6911UXC's HDMI audio all exist on
the mainline kernel (`pkgs/kernel-mainline`, Linux 7.1.x). Everything above
describes the 4.19 bring-up; this section is the delta, and it is what ships.

**What is the same.** The panel, its geometry, `/dev/fb0`, the orientation
mapping, the backlight ABI (`/sys/class/backlight/backlight`, `bl_power` 0/1,
`brightness` 0..100), the two evdev devices, the status daemon, the live HDMI
preview and its `/dev/shm/nanokvm-preview` layout. `nanokvm-display` runs
unchanged apart from the two fixes below, and libkvm's preview publisher is
untouched.

**What changed, and why.**

| | 4.19 | mainline |
|---|---|---|
| panel driver | SDK `fb_jd9853.ko`, built by the vendor defconfig | `pkgs/kernel-mainline/tree/drivers/staging/fbtft/fb_jd9853.c`, our port |
| tearing-effect pin | used: IRQ + workqueue + double buffer + 5 s liveness timer | **not used**; `te-gpios` is absent from the DT |
| SPI controller | SDK `spi-dw-mmio.c` fork with a DMA endian swap | stock mainline `spi-dw-mmio`, PIO |
| backlight PWM | `drivers/pwm/pwm-axera.c` (527 lines) | `drivers/pwm/pwm-dwc-of.c` (~110) over upstream's `pwm-dwc-core` |
| `gpio_keys` / `rotary_encoder` | modules, loaded at boot | built in |
| module set | four modules | two: `fbtft`, `fb_jd9853` |
| loader | `/etc/modules-load.d/nanokvm.conf` | `nanokvm-panel.service`, out of the generation's own closure |
| ATX pin setup | `nanokvm-gpio.service` + sysfs export + a `devmem` pad poke | nothing — a GPIO claim programs the pad (#81) |
| audio | vendor `sound/soc/axera/dwc-i2s.c` (993 lines) + `dummy-codec` | stock `snps,designware-i2s` in PIO mode + `linux,spdif-dir` |

### The module list

Two, both in `pkgs/display-modules.nix`, laid out as `/lib/modules/<release>`
in the generation's closure exactly like the video stack's (#83):

```
fbtft.ko
fb_jd9853.ko
```

`nanokvm-panel.service` insmods them in that order (`fb_jd9853` imports
`fbtft`'s symbols and the loader is a plain `insmod`, not `modprobe`), then
waits up to 5 s for `/dev/fb0`. `nanokvm-display.service` is ordered after it
and still gated on `ConditionPathExists=/dev/fb0`, so a board with no panel
runs no daemon rather than accumulating a failed unit.

**They are modules for a safety reason, not a convenience one.** Loading
`fb_jd9853` runs the vendor's power-on sequence twice — ~560 ms of `mdelay`,
two hardware resets and about forty SPI register writes. Built in, a hang
anywhere in there is a kernel that never reaches userspace, which on this board
costs a `bootcount` rollback. As a module the system is already up, the unit
fails, and the board is still reachable.

### The device-tree nodes

All in `dts/`, all disabled in the SoC file and enabled by the board:

| node | compatible | notes |
|---|---|---|
| `spi@6072000` | `snps,dw-apb-ssi` | 2 chip selects, CS1 is `gpio0 27`; `spi2_pins` claims SCLK+MOSI (no MISO — the panel is write-only) |
| `spi@6072000/panel@1` | `jadard,jd9853` | 80 MHz asked, 52 MHz actual (208 MHz SSI / 4) |
| `pwm@6060000` | `snps,dw-apb-timers-pwm2` | clocks `bus`/`timer`; `pwm0_pins` is the one pin state here that is **not** a no-op in value |
| `backlight` | `pwm-backlight` | `pwms = <&pwm0 0 462963 0>` — 0 is `PWM_POLARITY_NORMAL` |
| `gpio-keys` | `gpio-keys` | `label = "gpio_keys"`, which is what the input device is named |
| `rotary-encoder` | `rotary-encoder` | gray, 4 steps/period, REL_X |
| `i2s@6051000` | `snps,designware-i2s` | PIO; `snps,syscon` + `snps,rx-channel` are patch 0003's |
| `spdif-in` | `linux,spdif-dir` | the stub codec |
| `sound` | `simple-audio-card` | card name "Lontium Lt6911UXC", verbatim from the vendor |

Five new clock rows carry them (`AX630C_CLK_SPI_M2_{SEL,EB}`,
`AX630C_PCLK_SPI_M2_EB`, `AX630C_CLK_PWM00_EB`, `AX630C_PCLK_PWM0_EB`). Every
bit position is cited rather than derived: the vendor `spi-dw-mmio.c` writes
`EB0` bit `(6 + spi_id)` and `EB3` bit `(2 + spi_id)`, and the vendor `pwm0`
node spells its own register offsets out in DT properties. The PWM block's
source mux and class gate turn out to be the **timer** ones — it is a
DesignWare APB timer in PWM mode — so only the per-channel gate and the APB
gate are new.

### Two GPIO polarities that are inverted relative to the vendor DT

4.19 fbtft drove `dc` and `reset` through `gpio_set_value()`, which is the
**raw** GPIO API and ignores the active-low flag. Mainline fbtft uses
`gpiod_set_value()`, which does not. So:

- **`dc-gpios` is `GPIO_ACTIVE_HIGH` here** where the vendor DT says active-low.
  Get this wrong and every command byte is sent as data: a blank panel, no
  error message, nothing in `dmesg`.
- **`reset-gpios` stays `GPIO_ACTIVE_LOW`.** `fbtft_reset()` asserts then
  deasserts *logically*, which with that flag is the same low-then-high pulse
  the vendor's raw writes produced.

`pkgs/dtb-mainline.nix` asserts both flag cells with `fdtget`, because neither
failure is visible any other way.

### The rmmod hard-hang, explained

The trap this document has carried since 2026-08-15 — *unloading a loaded
`fb_jd9853` hard-hangs the device* — is understood now, and it is not the TE
timer.

The vendor's `init_display()` does `dev_set_drvdata(&par->spi->dev, panel)`,
overwriting the `struct fb_info *` that `fbtft_register_framebuffer()` had just
stored there. `fbtft_driver_remove_spi()` then reads a ~120-byte
`jd9853_priv_data` as a `fb_info`, `info->par` is uninitialised slab memory
well past the end of that object, and `fbtft_unregister_framebuffer()` makes an
indirect call through `par->fbtftops.unregister_backlight`. The SDK's own
`fb_jd9853_hkc_2_01.c` is the repaired copy of the same driver and fixes
exactly this (it uses `par->extra`), which is the corroboration.

Our port keeps **no** private state, so the mechanism is structurally absent.
**The rule is unchanged anyway: load at boot, never unload.** It has not been
tested on hardware and there is nothing to gain from finding out the hard way.

### Rejected paths

- **`drm/tiny/panel-mipi-dbi` with a firmware init blob** — zero lines of C.
  The JD9853's whole init sequence fits its `command, len, params...` blob
  format, and the awkward part of this panel (172 columns at offset 34 on a
  240-column array) is expressed natively by `panel-timing`'s back porches. It
  was rejected on three counts: it drags the entire DRM/KMS stack into an Image
  that has a 64 MiB ceiling for one 172×320 status screen; it needs a binary
  artifact loaded through `request_firmware` on an image whose blob policy is
  "the aic8800 firmware and nothing else"; and DRM's fbdev emulation is another
  layer between the daemon's byte-exact 172×320/stride-344 writes and the
  panel. Worth revisiting if the DRM stack ever arrives for another reason.
- **A new `drm/tiny/jd9853.c`** (~400-500 lines, TE as a vblank source) — this
  is the **upstreamable** form, and it is the right answer for #87: mainline's
  own fbtft `TODO` says the subsystem takes no new drivers. It is not the right
  answer for #84, which is about making the panel work on the kernel we boot.
- **Porting the vendor driver as-is, TE and all** (~70 changed lines) — smaller
  than the rewrite on paper, but the thing being copied is the one that hangs
  on unload, plus a `blank()` that cannot blank, a teardown that cancels work
  before stopping the two things that queue it, and a `memcpy_reverse32()` that
  exists only to cancel the vendor SPI DMA's 32-bit endian swap and would
  scramble every pixel against a stock master.
- **`dma_per` for the audio path** — not started, by the brief. PIO first.

### Audio

`arecord`-visible as the card **Lontium Lt6911UXC**, stock
`snps,designware-i2s` in **PIO** mode. The driver picks PIO purely from the DT:
mainline's `dw_i2s_probe()` registers the PIO PCM when the node has
`interrupts` and dmaengine when it does not — and `dw_pcm_register()` is an
`-EINVAL` stub without `CONFIG_SND_DESIGNWARE_PCM`, so a kernel missing that
symbol does not fall back to DMA, it fails the probe.

Three things the stock driver cannot know, added as optional properties by
`patches/0003-ASoC-dwc-integration-properties.patch` (each a no-op when absent,
so no existing DT changes behaviour):

- **`snps,syscon = <&periph_clk 0x3c 0x00ffffff 0x00080620>`** — the audio
  crossbar word in the peripheral syscon, written masked before the block is
  used. The value is recomputed from the vendor board DT's own seventeen
  `i2s-*-sel` properties: `exter-codec-en` (bit 19), `s-rx0-sel = 3` (bits
  10:9), `s-sclk-sel = 1` (bits 6:5). Six I2S instances share this one
  register and only this one is enabled, so there is exactly one writer.
- **`snps,rx-channel = <1>`** — that crossbar setting lands the capture stream
  on the block's RX channel **1**, not 0. The vendor driver carries a
  hardcoded `if (rx0_sel == 3) { enable RER(1); break; }` for precisely this;
  the stock driver assumes channel 0 in four places (`RCR/RFCR/RER`, the
  `IMR` unmask, the ISR's channel test, and the PIO FIFO registers) and would
  wait forever for an interrupt that is masked.
- **`clock-names = "apb", "mclk"`** — in slave mode the driver takes no clock
  at all, having no bit clock to program, so without naming the APB gate
  `clk_disable_unused()` takes the register window away partway through boot.

Interrupt load at 48 kHz stereo is `48000 / fifo_th` per second. The block
reports a **16-deep FIFO** (`I2S_COMP_PARAM_1` = `0x024C00EE`, read on the
board), so `fifo_th` is 8 and the rate is **6 000/s** of roughly 28 MMIO
accesses each — the low end of the estimate. What that costs under a live
encode is still unmeasured, because the attached source sends no audio; if
`RX overrun` ever shows up in `dmesg` during real capture, the `axera,dma-per`
dmaengine driver becomes a separate rung and **is not started without saying
so first**.

### What is not proven, and can only be proven on hardware

Four of the five entries this section used to list were settled on the board on
2026-09-11; the measurements are in the next section. What is left needs
something SSH cannot supply:

1. **A source that sends audio over HDMI.** `/proc/lt6911_info/asr` reads 0 on
   the attached host, so the I2S port has no bit clock and nothing can be
   captured. That one fact blocks three questions at once: whether the stream
   really lands on RX channel **1** (the `snps,rx-channel` half of patch 0003),
   whether a pure slave needs `CLK_I2S_REF0_EB` at all, and what PIO's overrun
   count is under a live encode — the number that decides whether `dma_per`
   ever becomes a rung.
2. **Hands on the knob**, and **eyes on the panel**. Both input devices exist
   with the right capability bits and every backlight duty cycle was read out
   of the PWM's own registers, but that the three GPIOs reach the knob and that
   the glass lights up are physical facts.

### Hardware verification (mainline) — DONE 2026-09-11

**The panel works on the mainline appliance.** `/dev/fb0`, the status daemon,
the backlight, the idle blank and the wake-on-press were all measured on the
board (generations 20 and 21, boots of 54 s and 53 s to SSH, `bootcount`
`0xB0010001` cleared by `nanokvm-mark-good` each time).

**What the first boot found: five clock rows that were never registered.**
`/dev/fb0` did not appear, and the reason was two lines of `dmesg`:

```
dw_spi_mmio 6072000.spi: probe with driver dw_spi_mmio failed with error -2
dwc-pwm-of 6060000.pwm: error -ENOENT: cannot get the bus clock
```

`ax630c-clock.h` declared `AX630C_CLK_SPI_M2_{SEL,EB}`, `PCLK_SPI_M2_EB`,
`CLK_PWM00_EB` and `PCLK_PWM0_EB`; `ax630c_periph_clks[]` carried none of them,
and `ax630c_clk_probe()` fills every unregistered id with `ERR_PTR(-ENOENT)`.
Neither driver can probe without its clocks, so there was no SPI device for
`fb_jd9853` to bind to and the backlight sat in permanent deferred probe
(`platform backlight: deferred probe pending: supplier 6060000.pwm not ready` —
the one line that names the whole chain). The rows are in the table now, each
bit cited and then read back off the board; see `clk-ax630c-tables.c`.

| oracle | measured |
|---|---|
| boot | SSH at 53 s; `bootcount` `0xB0010001` → `0xB0010000`, `mark-good: healthy after 0s`, fallback promoted |
| modules | `nanokvm-panel` active, `fbtft` + `fb_jd9853` loaded, `nanokvm-panel: /dev/fb0 up` |
| the framebuffer | `/dev/fb0` (29:0), `fb_jd9853 spi0.1` — the panel binds as **`spi0.1`**, not `spi2.1`: with one SPI master registered the bus number is 0 |
| the pads | `0x02304024` = `0x00010083`, `0x02304084` = `0x00010083`, `0x104F000C` = `0x00020003` — all three exactly as predicted, and the third is the one the boot chain does *not* write, so `pwm0_pins` is doing it |
| the clocks | `clk_spi_m2_sel` 208 MHz, `clk_spi_m2_eb`/`pclk_spi_m2_eb` enabled with `6072000.spi` named, `clk_pwm00_eb` 24 MHz and `clk_timer_eb` pulled up with it, `pclk_pwm0_eb` with `6060000.pwm` named |
| the daemon | `nanokvm-display` active, `input devices: ['rotary-encoder', 'gpio_keys']`, and the framebuffer dumped off the board renders as the status screen: hostname, IP, `host off`, `video idle (no viewer)`, `hdmi in 4096x2160`, firmware and uptime |
| the backlight | `/sys/class/backlight/backlight`, `max_brightness` 100. Duty measured in the PWM's own registers (`0x06060000` low period, `0x060600b0` high period, 11021 ticks total ≈ 462963 ns at 24 MHz): brightness 1 → 0.98 % high, 10 → 9.9 %, 50 → 49.5 %, 80 → 79.2 %. **Monotonic in the right direction**, which is the polarity check, made without eyes on the panel |
| the blank | after `NANOKVM_DISPLAY_SLEEP_S` (180 s): `bl_power` 1 and `/dev/fb0` all zeros (md5 equal to 110080 zero bytes) |
| the wake | a synthetic `KEY_ENTER` press written to the `gpio_keys` evdev node → `bl_power` 0, brightness 80, framebuffer non-zero |
| the evdev nodes | `rotary-encoder` = `event0`, `EV=5` / `REL=1` (REL_X); `gpio_keys` = `event1`, `EV=100003` / `KEY=10000000` (bit 28 = `KEY_ENTER`) |
| teardown | none. Nothing was unloaded. |

**One bug the hardware found that nothing offline could.** The status daemon
read "no network" in amber on a board that was routed, serving and reachable:
NixOS gives a unit `coreutils`, `findutils`, `gnugrep`, `gnused` and `systemd`
and nothing else, so the daemon's `ip -j -4 addr` was an `ENOENT` it caught and
turned into an empty address list. `nanokvm-display.service` carries
`pkgs.iproute2` now. The 4.19 image ran the same daemon with an Ubuntu `PATH`,
which is why this is new.

**Still needs a human, and cannot be done over SSH:**

- **Turning and pressing the real knob.** Both input devices exist with the
  right capability bits, and the daemon's wake path is proven with injected
  events — but nothing here proves the three GPIOs are wired to the knob.
- **Seeing the panel.** Every pixel is proven at the framebuffer and every
  duty cycle at the PWM register; that the glass lights up, at the right
  brightness and the right way up, is an eyes-on check.
- **The ATX power-LED sense.** `nanokvm-gpio get atx-power-led` reads 0 and the
  daemon prints `host off` while the HDMI input is live at 4096x2160 — which is
  either a disconnected ATX harness or a sense line that does not read. It is
  #81's oracle, not the display's, and it needs someone who knows what is
  plugged into the board.

**Audio — the card is there, the capture is not.** `arecord -l` lists
`card 0: Lt6911UXC [Lontium Lt6911UXC], device 0: 6051000.i2s-dir-hifi`, so the
DW I2S, the `linux,spdif-dir` codec and `simple-audio-card` all probed. The
register reads:

| | value | decode |
|---|---|---|
| `I2S_COMP_PARAM_1` `0x060511F4` | `0x024C00EE` | `COMP1_MODE_EN` = **0** (so `set_fmt` accepts `BC_FC` — the one value that had to be right), `FIFO_DEPTH_GLOBAL` = 3 → **16-deep FIFO**, `fifo_th` 8, TX and RX both enabled, `RX_CHANNELS` = 1 → **two RX channels, so channel 1 exists**, 32-bit APB |
| `I2S_COMP_PARAM_2` `0x060511F0` | `0x000004A4` | RX word sizes 32/32/16/16-bit |
| `I2S_COMP_VERSION` `0x060511F8` | `0x3131312A` | "1.11*" |
| crossbar `0x0487003C` | `0x00080620` | exactly the word `snps,syscon` asks for |

At 48 kHz stereo a 16-deep FIFO is **6 000 interrupts/s**, the low end of the
estimate. The capture itself cannot be run here: `/proc/lt6911_info/asr` reads
**0** — the attached source sends no audio at all — so there is no bit clock,
`/proc/interrupts` line 19 (`GIC 177`, `6051000.i2s`) stands at **0** on both
CPUs, and `arecord` returns `read error: Input/output error` immediately for
both `S16_LE` and `S32_LE`. That is the correct behaviour for a slave port with
no clock, and it is also why **the RX-channel question, `CLK_I2S_REF0_EB` and
the PIO overrun count are all still open**: every one of them needs a source
that sends audio. `dma_per` stays unstarted — there is no overrun number yet to
justify it.

---

## Hardware verification

**Verified on hardware:**

- **The full from-source stack, end-to-end (2026-08-15),** on the device
  running the v2.0.0 from-source firmware (applied via OTA): all modules
  loaded at boot (`fbtft`, `fb_jd9853`, `gpio_keys`, `rotary_encoder`),
  `graphics fb0: fb_jd9853 frame buffer, 172x320 ... spi2.1 at 80 MHz` in
  dmesg, `nanokvm-display` active. After the 3-min idle blank (backlight
  `bl_power=1`, fb zeroed), a knob-button press injected through
  `/dev/input/event0` woke the panel (backlight on, fb redrawn); the fb dump
  read back over SSH renders as the legible status screen (hostname, IPs,
  video power-save state, HDMI input mode, fw version, uptime).
- **The target-control page (2026-08-16),** by injecting real knob events
  through the evdev nodes: twist opens the page, selection moves, the
  confirm screen arms, twist cancels, `back` returns to the status page —
  each step verified via framebuffer dumps rendered off-device. The host
  power state read (`GET /api/vm/gpio` → gpio75) reported the live host
  correctly after `nanokvm-gpio.service` exported the pins.
- **Physical power and reset pulses (2026-08-16).** Reset was pressed by
  Jeremy (target rebooted); power was initially dead — root-caused to the
  `VI_D7` pinmux trap above. With the mux fixed, an 800 ms press through
  `POST /api/vm/gpio` powered the live target **off** (gpio75 LED 0→1) and
  a second press powered it back **on** — both observed via the LED sense.
  The per-press re-assert was verified by deliberately breaking the mux,
  firing a 1 ms press (below ATX debounce), and reading the pad word back
  repaired.
- All panel-side findings (top table, DT node, backlight, `/dev/fb0`
  behavior) — on a NanoKVM-Pro Desk running this firmware.
- The **orientation mapping** — by dumping the live framebuffer of a
  stock-firmware NanoKVM-Pro while its vendor UI was drawing and un-rotating
  it (the "Welcome / visit IP" screen reads upright exactly under
  `phys(x,y) = fb[319-x][y]`); the daemon uses that same mapping.

**Verified off-device (pre-flash evidence):**

- Our five modules build from the SDK kernel source with vermagic
  `4.19.125 SMP preempt mod_unload aarch64` — identical to the vendor blobs.
- Symbol-table equivalence: for each of the five, the defined- and
  undefined-symbol sets of our `.ko` match the vendor's `/kvmcomm/ko` blob
  exactly (sole diff: our `fbtft` imports `memset`, which the vendor's GCC
  inlined — `memset` is a core exported symbol). Same sources, same ABI.
- The daemon end-to-end in a harness: render → rotate → fb-file write, plus
  the full **sleep → blank/backlight-off → wake-on-button-press** cycle
  against a synthetic evdev stream.

Durable trap from development: **unloading a loaded `fb_jd9853` hard-hangs the
device** (its TE-timer/workqueue teardown deadlocks; the *load* path exercised
at boot is unaffected) — never live-swap the panel modules; test at boot.

Quick post-flash checklist (run in full 2026-08-15, all green):

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
Modules:    OURS, from source. Mainline: two, from pkgs/display-modules.nix at
            /lib/modules/<release>, insmod'd by nanokvm-panel.service --
            fbtft.ko fb_jd9853.ko (gpio-keys + rotary-encoder are built in).
            4.19 shipped four under /usr/lib/modules/4.19.125/kernel/, plus
            f_udisp_drv.ko (built, NOT loaded -- USB-display gadget function).
Rotation:   physical (x,y) = fb[row 319-x, col y]  (vendor's R270)
Daemon:     /opt/nanokvm-display/nanokvm_display.py  (nanokvm-display.service)
            sleep after 180 s idle (backlight off), wake on knob button/turn
            twist on status page -> target-control page (power press / reset /
            force off, confirm-then-fire via loopback POST /api/vm/gpio)
ATX pins:   nanokvm-gpio (libgpiod v2), lines by DT gpio-line-names:
            atx-power, atx-reset, atx-power-led, atx-hdd-led. The request
            programs the pad mux via gpio-ranges -> gpio_request_enable, so
            there is NO sysfs export and NO per-press re-assert (#81). `get`
            prints the logical value, so 1 = host on. Pads: SW_PWR = VI_D7
            (0x02300060), reset = UART3_RXD (0x02304090), LEDs = CDTX_L0N/P.
Closed junk:kvm_ui / frameforge / kvm_vin and /kvmcomm/ko blob copies are not
            built and not shipped -- nothing puts them on the image (#97)
```
