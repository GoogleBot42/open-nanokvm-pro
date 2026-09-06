#!/usr/bin/env python3
"""Grab the whole KWin workspace through org.kde.KWin.ScreenShot2 (needs
KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 on the compositor) and save it as PNG.
usage: kwin_shot.py out.png
"""
import os, sys
from jeepney import DBusAddress, new_method_call
from jeepney.fds import FileDescriptor
from jeepney.io.blocking import open_dbus_connection
from PIL import Image

out = sys.argv[1]
addr = DBusAddress('/org/kde/KWin/ScreenShot2', bus_name='org.kde.KWin', interface='org.kde.KWin.ScreenShot2')
conn = open_dbus_connection(bus='SESSION', enable_fds=True)
r, w = os.pipe()
opts = {'include-cursor': ('b', False), 'native-resolution': ('b', True)}
msg = new_method_call(addr, 'CaptureWorkspace', 'a{sv}h', (opts, FileDescriptor(w)))
reply = conn.send_and_get_reply(msg, timeout=20)
os.close(w)
if reply.header.message_type.name == 'error':
    raise SystemExit(f"ScreenShot2 error: {reply.header.fields} {reply.body}")
info = {k: v[1] for k, v in reply.body[0].items()}
chunks = []
while True:
    b = os.read(r, 1 << 20)
    if not b: break
    chunks.append(b)
data = b''.join(chunks)
W, H, stride, fmt = info['width'], info['height'], info['stride'], info['format']
# QImage::Format: 4 RGB32, 5 ARGB32, 6 ARGB32_Premultiplied -> little-endian 0xAARRGGBB = B,G,R,A bytes
raw = {4: 'BGRX', 5: 'BGRA', 6: 'BGRa', 17: 'RGBA', 18: 'RGBX', 19: 'RGBa'}.get(fmt)
if raw is None:
    raise SystemExit(f"unhandled QImage format {fmt}; info={info} bytes={len(data)}")
img = Image.frombuffer('RGBA', (W, H), data, 'raw', raw, stride, 1).convert('RGB')
img.save(out)
print(f"kwin_shot: {W}x{H} fmt={fmt} stride={stride} bytes={len(data)} -> {out}")
