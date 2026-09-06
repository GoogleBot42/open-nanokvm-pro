#!/usr/bin/env python3
"""Serve a built web bundle with just enough fake backend to exercise the input
path off-device: static files + a WebSocket that accepts /api/ws (the HID
socket) and the stream sockets, and a catch-all JSON reply for /api/* HTTP.

    usage: mock_server.py <dist-dir> [port]      (default 8099, plain http)

The video never plays -- the stream sockets send nothing -- but every player
still mounts its `#screen` element, which is exactly what the #73 binding bug
is about.  ff_input.py against this proves the mouse/keyboard handlers bound,
with no device involved.  Requires the `websockets` package (see the
mse-player harness README for the nix env).
"""
import asyncio
import mimetypes
import os
import sys

from websockets.asyncio.server import serve
from websockets.http11 import Response
from websockets.datastructures import Headers

DIST = os.path.abspath(sys.argv[1])
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8099


def http_response(status, reason, body, content_type):
    headers = Headers()
    headers["Content-Type"] = content_type
    headers["Content-Length"] = str(len(body))
    headers["Cache-Control"] = "no-store"
    return Response(status, reason, headers, body)


def process_request(connection, request):
    # None -> let the WebSocket handshake proceed
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return None

    path = request.path.split("?")[0]
    if path.startswith("/api/"):
        return http_response(200, "OK", b'{"code":0,"msg":"ok","data":{}}', "application/json")

    rel = path.lstrip("/") or "index.html"
    full = os.path.normpath(os.path.join(DIST, rel))
    if not full.startswith(DIST) or not os.path.isfile(full):
        full = os.path.join(DIST, "index.html")
    with open(full, "rb") as f:
        body = f.read()
    ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
    return http_response(200, "OK", body, ctype)


async def handler(ws):
    path = ws.request.path
    print(f"    [mock] websocket open {path}", flush=True)
    try:
        async for _ in ws:
            pass  # HID frames are counted in the browser, not here
    except Exception:
        pass
    print(f"    [mock] websocket closed {path}", flush=True)


async def main():
    async with serve(handler, "127.0.0.1", PORT, process_request=process_request):
        print(f"[mock] http://127.0.0.1:{PORT}/ serving {DIST}", flush=True)
        await asyncio.get_running_loop().create_future()


asyncio.run(main())
