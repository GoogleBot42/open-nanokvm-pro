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

Extending the screen: add an entry to build_lines() below. Each line is
(font, fg565, text); the renderer stacks them top-down with per-font spacing.
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
        fps = data["result"]["streamer"]["source"]["captured_fps"]
        if fps and fps > 0:
            return "streaming", f"{fps} fps"
        return "idle", "no viewer"
    except Exception:
        return "down", "server off"


def get_hdmi_input():
    w, h = read_file(LT6911_W, "0"), read_file(LT6911_H, "0")
    try:
        wi, hi = int(w), int(h)
    except ValueError:
        wi = hi = 0
    return f"{wi}x{hi}" if wi and hi else "no signal"


def get_uptime():
    try:
        secs = int(float(read_file("/proc/uptime", "0").split()[0]))
    except (ValueError, IndexError):
        secs = 0
    d, rem = divmod(secs, 86400)
    h, rem = divmod(rem, 3600)
    m = rem // 60
    return f"{d}d {h:02}:{m:02}" if d else f"{h:02}:{m:02}"


def build_lines():
    """The screen content. To add a status item, append a line tuple here:
    (font_name, color565, text) -- or a ("gap", pixels, None) spacer."""
    ips = get_ips()
    state, detail = get_stream_status()
    stream_color = {"streaming": GREEN, "idle": GREY, "down": AMBER}[state]
    stream_text = {"streaming": f"LIVE  {detail}",
                   "idle": "idle  (no viewer)",
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
    lines += [
        ("gap", 8, None),
        ("small", stream_color, f" video   {stream_text}"),
        ("small", WHITE, f" hdmi in {get_hdmi_input()}"),
        ("small", GREY, f" fw {read_file(VERSION_FILE, '?')}   up {get_uptime()}"),
    ]
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
        canvas.text(0, y, text, kind, color)
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
    """Read all pending events; return True if any counts as user activity
    (button press/release or knob rotation)."""
    activity = False
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
            if etype == EV_KEY and value == 1:  # button press
                activity = True
            elif etype == EV_REL:               # knob rotation
                activity = True
    return activity


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

    awake = True
    last_frame = None
    last_activity = time.monotonic()
    last_scan = time.monotonic()

    while True:
        # -- draw (only while awake) ---------------------------------------
        if awake:
            try:
                render(canvas, build_lines())
                frame = canvas.to_fb_bytes()
                if frame != last_frame:
                    write_fb(frame)
                    last_frame = frame
            except Exception as e:  # never die on a transient source error
                print(f"refresh failed: {e}", file=sys.stderr)

        # -- wait for input or next refresh tick ---------------------------
        timeout = REFRESH_S if awake else 60.0  # asleep: just wait for input
        try:
            readable, _, _ = select.select(list(inputs), [], [], timeout)
        except InterruptedError:
            readable = []

        activity = False
        for fd in readable:
            got = drain_events(fd)
            if got is None:  # device vanished; drop and rescan below
                os.close(fd)
                inputs.pop(fd, None)
                last_scan = 0
            elif got:
                activity = True

        now = time.monotonic()
        if activity:
            last_activity = now
            if not awake:  # waking press only wakes -- no other action
                awake = True
                last_frame = None  # force redraw
                set_backlight(True)

        # -- inactivity -> sleep (backlight off + blank panel) -------------
        if (awake and SLEEP_TIMEOUT_S > 0
                and now - last_activity >= SLEEP_TIMEOUT_S):
            awake = False
            set_backlight(False)
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
