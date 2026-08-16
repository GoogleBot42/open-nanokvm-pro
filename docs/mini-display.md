# The built-in mini-display — INCLUDED, fully from source

**Status: included in the firmware, with ZERO vendor display blobs.** The panel
driver stack is built from our own kernel tree and a small open Python status
daemon draws to it. The vendor's closed `kvm_ui`/`frameforge` binaries and the
prebuilt `/kvmcomm/ko/*.ko` copies are neither shipped nor used (the rootfs
overlay still deletes them — see `pkgs/rootfs.nix` step 5d).

The panel findings below were verified on real hardware (a NanoKVM-Pro Desk
running our from-source firmware); the orientation mapping was additionally
confirmed against a live framebuffer dump from a stock-firmware device. The
from-source module + daemon stack was proven end-to-end on the device
(2026-08-15, see [Hardware verification](#hardware-verification)).

- [What the display is](#what-the-display-is)
- [How it is blob-free](#how-it-is-blob-free)
- [What ships in the image](#what-ships-in-the-image)
- [The status daemon](#the-status-daemon)
- [Live HDMI preview](#live-hdmi-preview)
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
3. **ATX GPIO setup**: the enabled oneshot `nanokvm-gpio.service` (same
   package) exports the target power/reset pins at boot — `gpio7` SW_PWR and
   `gpio35` SW_RST as outputs idling low (exported via `low` so the power
   line never glitches), `gpio75`/`gpio74` LED-sense inputs. The vendor's
   disabled kvmcomm stack used to do this; without it the server's
   `POST /api/vm/gpio` (web UI power menu) and the knob control page have
   nothing to actuate.

   **The SW_PWR pinmux trap** (cost a real debugging session — device-proven
   2026-08-16): sysfs GPIO export **never programs the pinmux** on this SoC
   (`axera-pinctrl` doesn't wire `gpio_request_enable` to the mux), and
   `gpio7` sits on the **`VI_D7` camera-data pad**, whose mux register is
   `0x02300060` (function 6 = `GPIO0_A7`, correct word `0x00060003`). Two
   consequences: (a) the vendor's own `gpio.sh` pokes `0x02302024` — that is
   **GPIO3_A2's register, not VI_D7's** — so the power button is likely
   broken on stock firmware too; (b) the closed capture stack re-muxes the
   VI pad group back to camera-data function on pipeline init (observed
   across a `nanokvm` restart), so no boot-time write can stick. Reset
   (`gpio35` = `UART3_RXD` pad, mux `0x02304090`) and the LED senses
   (`CDTX_L0N/P`, `0x0230A00C`/`0x0230A018`) are not touched by capture,
   which is why "reset works but power doesn't" is the symptom signature.
   The durable fix is in the server: `muxPowerPin()`
   (`pkgs/nanokvm-server/pinmux-power.go.in`) re-asserts `VI_D7 → GPIO0_A7`
   via `/dev/mem` immediately before **every** power press;
   `nanokvm-gpio.service` also writes it once at boot as belt-and-braces.
   Kernel-side reading: a GPIO's `value` file just echoes the output
   latch — it proves nothing about the ball; check the pad word with
   `devmem 0x02300060` instead.
4. The OTA update package carries the same payload (`pkgs/update-package.nix`).

---

## The status daemon

Pure-stdlib **Python** (the Ubuntu-arm64 base already ships `python3`; no PIL,
no new interpreter, no pip packages). Source: `pkgs/nanokvm-display/nanokvm_display.py`.

Shown (refreshed every 2 s while awake):

- hostname
- **IP address(es)** (large font; `ip -j -4 addr`, skipping `lo`)
- **target host power** — `host on`/`off`, read directly from the gpio75
  power-LED sense in sysfs (exported at boot by `nanokvm-gpio.service`;
  inverted: host on = reads 0); `?` if the pin isn't exported
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
Both pages show the target's power state via the direct gpio75 sysfs read
above. Falling asleep resets to the status page. Slow status sources (the `ip` subprocess and the streamer poll)
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
Modules:    OURS, from source, /usr/lib/modules/4.19.125/kernel/...
            fbtft.ko fb_jd9853.ko gpio_keys.ko rotary_encoder.ko (loaded at boot)
            f_udisp_drv.ko (built, NOT loaded -- USB-display gadget function)
Rotation:   physical (x,y) = fb[row 319-x, col y]  (vendor's R270)
Daemon:     /opt/nanokvm-display/nanokvm_display.py  (nanokvm-display.service)
            sleep after 180 s idle (backlight off), wake on knob button/turn
            twist on status page -> target-control page (power press / reset /
            force off, confirm-then-fire via loopback POST /api/vm/gpio)
ATX pins:   nanokvm-gpio.service (oneshot, boot) exports gpio7=SW_PWR out,
            gpio35=SW_RST out (idle low), gpio75/74 LED sense in; host on
            when gpio75 reads 0 (server inverts: GET /api/vm/gpio .pwr)
            SW_PWR pad = VI_D7, mux reg 0x02300060 must hold 0x00060003
            (GPIO0_A7); capture init re-muxes it, server re-asserts before
            every power press (pinmux-power.go.in). Reset pad = UART3_RXD
            (0x02304090), LED pads = CDTX_L0N/P -- capture leaves those alone.
Closed junk:kvm_ui / frameforge / kvm_vin and /kvmcomm/ko blob copies -- still
            REMOVED from the image (pkgs/rootfs.nix 5d)
```
