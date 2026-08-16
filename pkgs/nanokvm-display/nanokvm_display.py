#!/usr/bin/env python3
"""nanokvm-display -- status screen for the NanoKVM-Pro built-in mini-display.

Pure-stdlib Python (the device rootfs ships python3 but no PIL); the bitmap
fonts are pre-converted at Nix build time from source-built PSF2 console fonts
(see gen_font.py) into font_data.py next to this file.

Panel (docs/mini-display.md): JD9853 SPI TFT, /dev/fb0, 172x320 native
portrait, RGB565-LE, stride 344 = 172*2 (no padding). The panel is mounted
rotated: physical pixel (x,y) on the 320x172 landscape face shows framebuffer
cell [row 319-x, col y] (verified against the vendor UI's own framebuffer
content). So we render a 320x172 landscape canvas and emit fb row r as canvas
column (319-r), top to bottom -- a cheap strided-slice transpose.

Sleep/wake: after SLEEP_TIMEOUT_S with no input activity the backlight is
switched off (bl_power=1), the panel is blanked, and refreshing stops. A press
of the knob button (gpio-keys, KEY_ENTER) -- or turning the knob
(rotary-encoder, REL_X) -- wakes it again; the waking press only wakes, it
triggers nothing else. While awake, any knob/button activity resets the timer.
Set SLEEP_TIMEOUT_S (or env NANOKVM_DISPLAY_SLEEP_S) to 0 to never sleep.

Pages: twisting the knob on the status page opens the target-control page
(power press / reset / force off, actuated through the KVM server's loopback
/api/vm/gpio endpoint -- see nanokvm-gpio.service for the pin setup). Twist
moves the selection, press activates; every action needs a second confirming
press, and any twist cancels. Selection starts on "back" so stray input does
nothing. Falling asleep returns to the status page.

The "hdmi preview" menu entry opens a live view of the captured HDMI input:
libkvm publishes panel-ready frames (172x320 RGB565, pre-rotated) to
/dev/shm/nanokvm-preview while this daemon POSTs the server's loopback
/api/streamer/preview keep-alive (~1x/s); the page just blits the freshest
frame straight to the framebuffer -- zero per-pixel Python work. Press = back;
falling asleep exits the page (and the lease dies with it, so capture can
power down again). See docs/mini-display.md ("Live HDMI preview").

Extending the screen: add an entry to build_lines() below. Each line is
(font, fg565, text) -- fg may also be a (fg, bg) tuple for inverse video;
the renderer stacks them top-down with per-font spacing.
"""

import array
import fcntl
import json
import os
import select
import signal
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from font_data import FONTS  # generated at build time by gen_font.py

# ---------------------------------------------------------------------------
# Panel geometry / device paths / tunables
# ---------------------------------------------------------------------------
FB_DEV = "/dev/fb0"
FB_W, FB_H = 172, 320          # native framebuffer geometry (portrait)
W, H = FB_H, FB_W              # logical landscape canvas: 320 x 172
BACKLIGHT = "/sys/class/backlight/backlight"
REFRESH_S = 2.0                # content poll interval while awake
SLEEP_TIMEOUT_S = int(os.environ.get("NANOKVM_DISPLAY_SLEEP_S", "180"))
#   ^ seconds of no knob/button input before the panel sleeps; 0 = never.
BRIGHTNESS = "80"              # 0..100 (panel max_brightness = 100)
STREAMER_URL = "http://127.0.0.1/api/streamer/local"  # loopback-only endpoint
GPIO_URL = "https://127.0.0.1/api/vm/gpio"  # loopback bypasses auth; must be
#   https directly: port 80 answers 307 and urllib drops a POST body on redirect
CONFIRM_TIMEOUT_S = 8   # confirm prompt auto-cancels after this
FLASH_S = 3             # how long the done/FAILED result stays on screen
KNOB_DETENT = int(os.environ.get("NANOKVM_KNOB_DETENT", "2"))
#   ^ rotary events per navigation step. The encoder emits 2 REL_X events per
#   physical detent, so 1 would move the selection on half-clicks (it lands
#   between detents). Twist-to-cancel on the confirm screen stays raw.

# Target-control menu: (label, action, press ms). action None = back,
# "preview" = open the live-preview page (no confirm), else the gpio type for
# /api/vm/gpio (confirm required). "back" first so entering the page with a
# stray twist + press exits cleanly. Durations mirror the web UI (800 ms
# click, 8 s force-off hold).
MENU = [
    ("back", None, 0),
    ("hdmi preview", "preview", 0),
    ("power press", "power", 800),
    ("reset", "reset", 800),
    ("force off (8s)", "power", 8000),
]

# Live-preview frame feed (written by libkvm's kvm_preview.c; see the header
# struct there): 32-byte header + 172*320 RGB565-LE payload in native fb
# layout, atomically renamed into place, mono_us stamping freshness.
PREVIEW_FILE = "/dev/shm/nanokvm-preview"
PREVIEW_URL = "https://127.0.0.1/api/streamer/preview"  # loopback, no auth;
#   https directly for the same 307-redirect reason as GPIO_URL above
PV_FMT = "<IIIHHHHQI"
PV_HDR_SIZE = struct.calcsize(PV_FMT)  # 32
PV_MAGIC = 0x56504B4E                  # "NKPV"
PREVIEW_STALE_S = 2.0   # older than this = show the waiting screen instead
LT6911_W = "/proc/lt6911_info/width"
LT6911_H = "/proc/lt6911_info/height"
VERSION_FILE = "/kvmapp/version"

# fbdev / evdev ioctls
FBIOGET_VSCREENINFO = 0x4600
EVIOCGNAME_256 = 0x81004506    # EVIOCGNAME(256): _IOC(READ, 'E', 0x06, 256)

# input_event on 64-bit: timeval(16) + u16 type + u16 code + s32 value
EV_FMT = "qqHHi"
EV_SIZE = struct.calcsize(EV_FMT)  # 24
EV_KEY, EV_REL = 0x01, 0x02


def rgb565(r, g, b):
    return ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)


BLACK = rgb565(0, 0, 0)
WHITE = rgb565(255, 255, 255)
GREY = rgb565(150, 150, 150)
GREEN = rgb565(80, 220, 80)
AMBER = rgb565(255, 180, 40)
CYAN = rgb565(90, 200, 255)


# ---------------------------------------------------------------------------
# Canvas: 320x172 array of RGB565 words, row-major
# ---------------------------------------------------------------------------
class Canvas:
    def __init__(self):
        self.px = array.array("H", [BLACK]) * (W * H)

    def clear(self, color=BLACK):
        self.px = array.array("H", [color]) * (W * H)

    def text(self, x, y, s, font, fg, bg=None):
        """Draw string s at (x, y) top-left. Returns x after the last glyph."""
        f = FONTS[font]
        gw, gh, glyphs = f["w"], f["h"], f["glyphs"]
        bpr = (gw + 7) // 8  # bytes per glyph row
        px = self.px
        for ch in s:
            g = glyphs.get(ord(ch)) or glyphs.get(0x3F)  # '?' fallback
            if x + gw > W:
                break
            for ry in range(gh):
                yy = y + ry
                if yy >= H:
                    break
                rowbits = int.from_bytes(g[ry * bpr:(ry + 1) * bpr], "big")
                base = yy * W + x
                for rx in range(gw):
                    if rowbits & (1 << (bpr * 8 - 1 - rx)):
                        px[base + rx] = fg
                    elif bg is not None:
                        px[base + rx] = bg
            x += gw
        return x

    def hline(self, y, color):
        self.px[y * W:(y + 1) * W] = array.array("H", [color]) * W

    def to_fb_bytes(self):
        """Transpose the landscape canvas into native fb layout.

        fb row r (0..319) = canvas column (319 - r), rows 0..171 top-down.
        Stride is exactly 172*2, so rows concatenate with no padding.
        """
        px = self.px
        out = bytearray(FB_W * FB_H * 2)
        mv = memoryview(out)
        for r in range(FB_H):
            col = px[(FB_H - 1 - r)::W]  # strided slice: 172 items, C-speed
            mv[r * FB_W * 2:(r + 1) * FB_W * 2] = col.tobytes()
        return bytes(out)


# ---------------------------------------------------------------------------
# Status sources (each returns a short string; keep them cheap + fail-safe)
# ---------------------------------------------------------------------------
def read_file(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def get_ips():
    """IPv4 addresses of real NICs, via `ip -j` (present on the Ubuntu base)."""
    try:
        out = subprocess.run(["ip", "-j", "-4", "addr"], capture_output=True,
                             timeout=5, check=True).stdout
        ips = []
        for link in json.loads(out):
            if link.get("ifname") == "lo":
                continue
            for a in link.get("addr_info", []):
                if a.get("family") == "inet":
                    ips.append(a["local"])
        return ips
    except Exception:
        return []


_SSL_CTX = ssl._create_unverified_context()  # server uses a self-signed cert;
# port 80 307-redirects to https, urlopen follows it with this context.


def get_stream_status():
    """(state, detail) from the server's loopback-only streamer endpoint.

    captured_fps mirrors screen.RealFPS, which the server's FrameRateCounter
    only drives above 0 while a client is actively pulling frames -- so it is
    a direct "is someone viewing right now" signal.
    """
    try:
        with urllib.request.urlopen(STREAMER_URL, timeout=3,
                                    context=_SSL_CTX) as r:
            data = json.load(r)
        streamer = data["result"]["streamer"]
        # video_state == "suspended": capture pipeline powered down after the
        # server's idle timeout (videoIdleTimeout). Expected while unwatched.
        if streamer.get("video_state") == "suspended":
            return "sleep", "power save"
        fps = streamer["source"]["captured_fps"]
        if fps and fps > 0:
            return "streaming", f"{fps} fps"
        return "idle", "no viewer"
    except Exception:
        return "down", "server off"


def start_press(gtype, duration_ms):
    """Pulse the target's power/reset line via POST /api/vm/gpio (loopback,
    no auth). The server holds the pin high for duration_ms, so the HTTP call
    blocks for the whole press -- run it in a thread and let the main loop
    watch the returned dict ({"done": bool, "ok": bool})."""
    res = {"done": False, "ok": False}

    def work():
        try:
            body = json.dumps({"type": gtype, "duration": duration_ms}).encode()
            req = urllib.request.Request(
                GPIO_URL, data=body, method="POST",
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=duration_ms / 1000 + 10,
                                        context=_SSL_CTX) as r:
                rsp = json.load(r)
            res["ok"] = rsp.get("code") == 0
            if not res["ok"]:
                print(f"gpio {gtype}: server said {rsp}", file=sys.stderr)
        except Exception as e:
            print(f"gpio {gtype} failed: {e}", file=sys.stderr)
        res["done"] = True

    threading.Thread(target=work, daemon=True).start()
    return res


def get_hdmi_input():
    w, h = read_file(LT6911_W, "0"), read_file(LT6911_H, "0")
    try:
        wi, hi = int(w), int(h)
    except ValueError:
        wi = hi = 0
    return f"{wi}x{hi}" if wi and hi else "no signal"


def get_host_power():
    """Target power LED straight from sysfs (gpio75, exported at boot by
    nanokvm-gpio.service): cheap local read, safe for the render path.
    Inverted sense: host ON = reads 0. Returns True/False/None."""
    v = read_file("/sys/class/gpio/gpio75/value")
    return {"0": True, "1": False}.get(v)


def get_uptime():
    try:
        secs = int(float(read_file("/proc/uptime", "0").split()[0]))
    except (ValueError, IndexError):
        secs = 0
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    return f"{d}d {h:02}:{m:02}" if d else f"{h:02}:{m:02}"


class StatusPoller(threading.Thread):
    """Polls the two slow status sources (the `ip` subprocess and the HTTPS
    streamer endpoint) off the main loop, publishing an atomic snapshot.

    The main loop renders from the latest snapshot and never blocks on the
    network, so knob/button response is bounded by the select() timeout even
    when the KVM server hangs (issue #20). While the panel sleeps the poller
    is paused -- nothing polls a screen nobody is looking at."""

    def __init__(self):
        super().__init__(daemon=True)
        self.snapshot = ([], ("down", "server off"))  # (ips, stream_status)
        self.first = threading.Event()   # set once the first poll completed
        self._tick = threading.Event()   # set -> skip the inter-poll wait
        self._active = threading.Event()  # cleared -> paused (panel asleep)
        self._active.set()

    def run(self):
        while True:
            self._active.wait()
            self.snapshot = (get_ips(), get_stream_status())
            self.first.set()
            self._tick.wait(REFRESH_S)
            self._tick.clear()

    def pause(self):
        self._active.clear()

    def resume(self):
        """Un-pause and poll immediately (fresh data for the wake redraw)."""
        self._active.set()
        self._tick.set()


class PreviewKeepAlive(threading.Thread):
    """POSTs the server's loopback preview keep-alive ~1x/s while active.

    Each POST extends a ~3 s lease server-side; while it is fresh the server
    ticks libkvm's preview publisher (resuming the capture pipeline if it was
    idle-suspended). Runs off the main loop so a hung server can never block
    knob input; page transitions just flip the event."""

    def __init__(self):
        super().__init__(daemon=True)
        self._active = threading.Event()

    def run(self):
        while True:
            self._active.wait()
            try:
                req = urllib.request.Request(PREVIEW_URL, data=b"",
                                             method="POST")
                with urllib.request.urlopen(req, timeout=3, context=_SSL_CTX):
                    pass
            except Exception:
                pass  # server down; the page shows its waiting screen
            time.sleep(1.0)

    def set_active(self, on):
        if on:
            self._active.set()
        else:
            self._active.clear()


def read_preview_frame():
    """Freshest published preview frame, or None.

    Returns (payload, seq) where payload is the full 110080-byte native-fb
    RGB565 frame ready for write_fb(). The writer replaces the file by
    rename(), so a single read() always sees one consistent frame."""
    try:
        with open(PREVIEW_FILE, "rb") as f:
            data = f.read()
    except OSError:
        return None
    if len(data) < PV_HDR_SIZE:
        return None
    magic, ver, seq, fb_w, fb_h, _sw, _sh, mono_us, plen = \
        struct.unpack_from(PV_FMT, data, 0)
    if (magic != PV_MAGIC or ver != 1 or fb_w != FB_W or fb_h != FB_H
            or plen != FB_W * FB_H * 2 or len(data) < PV_HDR_SIZE + plen):
        return None
    # mono_us is CLOCK_MONOTONIC on this same host, directly comparable.
    if time.monotonic() - mono_us / 1e6 > PREVIEW_STALE_S:
        return None
    return data[PV_HDR_SIZE:PV_HDR_SIZE + plen], seq


def build_preview_wait_lines(stream):
    """Shown on the preview page until fresh frames arrive (pipeline resume
    takes ~1-2 s) or when they stop (no signal, server down)."""
    state, _ = stream
    if state == "down":
        msg, color = "server off", AMBER
    elif get_hdmi_input() == "no signal":
        msg, color = "no hdmi signal", AMBER
    else:
        msg, color = "starting video", CYAN
    return [
        ("small", WHITE, " hdmi preview"),
        ("hr", GREY, None),
        ("gap", 40, None),
        ("big", color, msg.center(22)),
        ("gap", 24, None),
        ("small", GREY, "  press = back"),
    ]


def build_lines(ips, stream):
    """The screen content. To add a status item, append a line tuple here:
    (font_name, color565, text) -- or a ("gap", pixels, None) spacer.
    ips/stream come from the StatusPoller snapshot; anything gathered inline
    here must be cheap (local file reads), never network or subprocess."""
    state, detail = stream
    stream_color = {"streaming": GREEN, "idle": GREY, "sleep": GREY,
                    "down": AMBER}[state]
    stream_text = {"streaming": f"LIVE  {detail}",
                   "idle": "idle  (no viewer)",
                   "sleep": "asleep  (power save)",
                   "down": "server not running"}[state]

    lines = [
        ("small", WHITE, f" {socket.gethostname()}"),
        ("hr", GREY, None),
        ("gap", 6, None),
    ]
    if ips:
        lines.append(("big", CYAN, ips[0].center(22)))
        for ip in ips[1:2]:  # second NIC, if any
            lines.append(("small", CYAN, ip.center(40)))
    else:
        lines.append(("big", AMBER, "no network".center(22)))
    host = get_host_power()
    host_color = {True: GREEN, False: AMBER, None: GREY}[host]
    host_text = {True: "on", False: "off", None: "?"}[host]
    lines += [
        ("gap", 8, None),
        ("small", host_color, f" host    {host_text}"),
        ("small", stream_color, f" video   {stream_text}"),
        ("small", WHITE, f" hdmi in {get_hdmi_input()}"),
        ("small", GREY, f" fw {read_file(VERSION_FILE, '?')}   up {get_uptime()}"),
    ]
    return lines


def build_control_lines(power, sel, mode, flash):
    """The target-control page (issue #35). mode: "menu" | "confirm" | "busy";
    flash: transient (text, color) result line or None."""
    ptxt = {True: "on", False: "off", None: "?"}[power]
    pcol = {True: GREEN, False: AMBER, None: GREY}[power]
    lines = [
        ("small", WHITE, " target control"),
        ("hr", GREY, None),
        ("gap", 4, None),
        ("small", pcol, f" host power  {ptxt}"),
    ]
    label = MENU[sel][0]
    if mode == "confirm":
        lines += [
            ("gap", 14, None),
            ("big", AMBER, label.center(22)),
            ("gap", 10, None),
            ("small", WHITE, "  press = confirm"),
            ("small", GREY, "  twist = cancel"),
        ]
    elif mode == "busy":
        lines += [
            ("gap", 14, None),
            ("big", CYAN, label.center(22)),
            ("gap", 10, None),
            ("small", GREY, "  working ..."),
        ]
    else:
        lines.append(("small", flash[1], f" {flash[0]}") if flash
                     else ("gap", FONTS["small"]["h"] + 2, None))
        lines.append(("gap", 4, None))
        for i, (item, _, _) in enumerate(MENU):
            if i == sel:
                lines.append(("small", (BLACK, WHITE), f" {item} ".ljust(40)))
            else:
                lines.append(("small", GREY, f"  {item}"))
    return lines


# ---------------------------------------------------------------------------
# Rendering / panel control
# ---------------------------------------------------------------------------
def render(canvas, lines):
    canvas.clear()
    y = 2
    for kind, color, text in lines:
        if kind == "gap":
            y += color  # ("gap", pixels, None)
            continue
        if kind == "hr":
            canvas.hline(y + 1, color)
            y += 4
            continue
        fg, bg = color if isinstance(color, tuple) else (color, None)
        canvas.text(0, y, text, kind, fg, bg)
        y += FONTS[kind]["h"] + 2
        if y >= H:
            break


def set_backlight(on):
    try:
        with open(os.path.join(BACKLIGHT, "brightness"), "w") as f:
            f.write(BRIGHTNESS)
    except OSError:
        pass
    try:
        with open(os.path.join(BACKLIGHT, "bl_power"), "w") as f:
            f.write("0" if on else "1")  # 0 = backlight on, 1 = off
    except OSError as e:
        print(f"backlight: {e}", file=sys.stderr)


def write_fb(frame):
    with open(FB_DEV, "r+b") as fb:
        fb.write(frame)


def wait_for_fb(timeout=60):
    """Wait for /dev/fb0 (fb_jd9853 loads via systemd-modules-load; SPI panel
    init takes a moment). Verify geometry via FBIOGET_VSCREENINFO."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(FB_DEV):
            try:
                with open(FB_DEV, "rb") as f:
                    vinfo = fcntl.ioctl(f, FBIOGET_VSCREENINFO, b"\0" * 160)
                xres, yres = struct.unpack_from("<2I", vinfo, 0)
                if (xres, yres) == (FB_W, FB_H):
                    return True
                print(f"fb0 is {xres}x{yres}, expected {FB_W}x{FB_H}; "
                      "not the mini-display -- exiting", file=sys.stderr)
                return False
            except OSError:
                pass
        time.sleep(1)
    print(f"timed out waiting for {FB_DEV}", file=sys.stderr)
    return False


# ---------------------------------------------------------------------------
# Input: knob button (gpio-keys) + rotation (rotary-encoder) via evdev
# ---------------------------------------------------------------------------
def open_input_devices():
    """Open every /dev/input/event* that looks like the knob button or the
    rotary encoder (by EVIOCGNAME). Returns {fd: name}."""
    fds = {}
    try:
        nodes = sorted(os.listdir("/dev/input"))
    except OSError:
        return fds
    for node in nodes:
        if not node.startswith("event"):
            continue
        path = os.path.join("/dev/input", node)
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError:
            continue
        try:
            raw = fcntl.ioctl(fd, EVIOCGNAME_256, b"\0" * 256)
            name = raw.split(b"\0", 1)[0].decode(errors="replace").lower()
        except OSError:
            name = ""
        if any(k in name for k in ("key", "rotary")):
            fds[fd] = name
        else:
            os.close(fd)
    return fds


def drain_events(fd):
    """Read all pending events; return (presses, delta) -- button presses and
    signed knob-rotation detents -- or None if the device went away."""
    presses = delta = 0
    while True:
        try:
            buf = os.read(fd, EV_SIZE * 64)
        except BlockingIOError:
            break
        except OSError:
            return None  # device went away; caller reopens
        if not buf:
            return None
        for off in range(0, len(buf) - EV_SIZE + 1, EV_SIZE):
            _, _, etype, _, value = struct.unpack_from(EV_FMT, buf, off)
            if etype == EV_KEY and value == 1:  # button press (not release)
                presses += 1
            elif etype == EV_REL and value:     # knob rotation
                delta += 1 if value > 0 else -1
    return presses, delta


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

    if not wait_for_fb():
        return 1
    set_backlight(True)

    canvas = Canvas()
    blank = bytes(FB_W * FB_H * 2)  # all-black frame for sleep
    inputs = open_input_devices()
    print(f"input devices: {list(inputs.values()) or 'none found'}",
          file=sys.stderr)

    poller = StatusPoller()
    poller.start()
    poller.first.wait(8)  # brief grace so the first paint has real data

    preview_ka = PreviewKeepAlive()
    preview_ka.start()
    last_preview_seq = None

    awake = True
    last_frame = None
    last_activity = time.monotonic()
    last_scan = time.monotonic()

    # target-control page state (issue #35)
    page = "status"          # "status" | "control"
    sel = 0                  # MENU index
    mode = "menu"            # "menu" | "confirm" | "busy"
    press_res = None         # dict from start_press() while busy
    confirm_deadline = 0.0   # auto-cancel the confirm prompt
    flash = None             # ((text, color), until) transient result line
    twist_acc = 0            # rotary events accumulated toward a full detent

    while True:
        # -- keep the server's preview lease exactly while the page is open --
        preview_ka.set_active(awake and page == "preview")

        # -- draw (only while awake) ---------------------------------------
        if awake:
            try:
                if page == "preview":
                    got = read_preview_frame()
                    if got:
                        payload, seq = got
                        if seq != last_preview_seq:
                            write_fb(payload)
                            last_preview_seq = seq
                            last_frame = None  # canvas pages redraw after this
                        lines = None
                    else:
                        _, stream = poller.snapshot
                        lines = build_preview_wait_lines(stream)
                elif page == "control":
                    lines = build_control_lines(
                        get_host_power(), sel, mode, flash and flash[0])
                else:
                    ips, stream = poller.snapshot
                    lines = build_lines(ips, stream)
                if lines is not None:
                    render(canvas, lines)
                    frame = canvas.to_fb_bytes()
                    if frame != last_frame:
                        write_fb(frame)
                        last_frame = frame
            except Exception as e:  # never die on a transient source error
                print(f"refresh failed: {e}", file=sys.stderr)

        # -- wait for input or next refresh tick ---------------------------
        if not awake:
            timeout = 60.0        # just wait for the waking input
        elif page == "preview":
            timeout = 0.1         # poll the frame feed at ~10 Hz
        elif mode == "busy":
            timeout = 0.25        # notice the press thread finishing quickly
        else:
            timeout = REFRESH_S
        try:
            readable, _, _ = select.select(list(inputs), [], [], timeout)
        except InterruptedError:
            readable = []

        presses = delta = 0
        for fd in readable:
            got = drain_events(fd)
            if got is None:  # device vanished; drop and rescan below
                os.close(fd)
                inputs.pop(fd, None)
                last_scan = 0
            else:
                presses += got[0]
                delta += got[1]

        now = time.monotonic()
        if presses or delta:
            last_activity = now
            if not awake:  # waking input only wakes -- no other action
                awake = True
                last_frame = None  # force redraw
                set_backlight(True)
                poller.resume()
                twist_acc = 0  # the waking twist doesn't count toward a step
            elif page == "status":
                twist_acc += delta
                if abs(twist_acc) >= KNOB_DETENT:  # full detent opens control
                    page, sel, mode, flash = "control", 0, "menu", None
                    twist_acc = 0
                    last_frame = None
            elif page == "preview":
                if presses:  # press = back; twists only reset the sleep timer
                    page, mode, flash = "status", "menu", None
                    twist_acc = 0
                    last_frame = None
                    last_preview_seq = None
            elif mode == "menu":
                twist_acc += delta
                steps = int(twist_acc / KNOB_DETENT)  # trunc toward zero
                if steps:
                    sel = max(0, min(len(MENU) - 1, sel + steps))
                    twist_acc -= steps * KNOB_DETENT
                if presses:
                    twist_acc = 0
                    if MENU[sel][1] is None:  # back
                        page = "status"
                        last_frame = None
                    elif MENU[sel][1] == "preview":  # live view; no confirm
                        page = "preview"
                        last_frame = None
                        last_preview_seq = None
                    else:
                        mode = "confirm"
                        confirm_deadline = now + CONFIRM_TIMEOUT_S
            elif mode == "confirm":
                if delta:       # any twist cancels (raw, no detent gate)
                    mode = "menu"
                    twist_acc = 0
                elif presses:   # second press fires the action
                    _, gtype, ms = MENU[sel]
                    press_res = start_press(gtype, ms)
                    mode = "busy"
            # mode == "busy": input ignored (only resets the sleep timer)

        # -- control-page timers -------------------------------------------
        if mode == "confirm" and now >= confirm_deadline:
            mode = "menu"
        if mode == "busy" and press_res and press_res["done"]:
            flash = ((("done", GREEN) if press_res["ok"]
                      else ("FAILED (see log)", AMBER)), now + FLASH_S)
            mode, press_res = "menu", None
            last_activity = now     # keep the result visible before sleep
        if flash and now >= flash[1]:
            flash = None

        # -- inactivity -> sleep (backlight off + blank panel) -------------
        if (awake and SLEEP_TIMEOUT_S > 0 and mode != "busy"
                and now - last_activity >= SLEEP_TIMEOUT_S):
            awake = False
            set_backlight(False)
            poller.pause()
            page, mode, flash = "status", "menu", None  # sleep resets the UI
            twist_acc = 0
            try:
                write_fb(blank)  # nothing lingers on the panel while dark
            except OSError:
                pass
            last_frame = None

        # -- periodic rescan: input modules may load after we start --------
        if now - last_scan >= 30 and len(inputs) < 2:
            for fd, name in open_input_devices().items():
                if name in inputs.values():
                    os.close(fd)
                else:
                    inputs[fd] = name
            last_scan = now


if __name__ == "__main__":
    sys.exit(main())
