#!/usr/bin/env python3
"""Stream-type hand-back test (#69). Runs ON the device, stdlib only.

One capture channel serves every consumer, gated by the global
KvmVision.StreamType: a consumer whose type is not the active one skips its
read. Upstream never hands the type back, so the FIRST consumer stays starved
after the second one leaves -- the mechanism behind the permanently white
WebRTC page in #69.

Three phases against a live server:

  1  MJPEG only          -- an /api/stream/mjpeg reader claims STREAM_TYPE_MJPEG
  2  MJPEG + h264-direct -- a wss /api/stream/h264/direct client claims
                            STREAM_TYPE_H264_DIRECT and takes the stream;
                            MJPEG is expected to stall
  3  MJPEG only again    -- the direct client is closed. With the hand-back,
                            MJPEG gets the type back and resumes; without it,
                            MJPEG stays dead until something else claims MJPEG

Verdict is on phase 3: frames > 0 = PASS (hand-back), 0 = FAIL (upstream).
MJPEG frames are counted by JPEG SOI markers (ff d8 ff) in the multipart body.

Usage: handback_test.py [seconds_per_phase]
"""
import base64
import os
import socket
import ssl
import struct
import sys
import threading
import time

HOST = "127.0.0.1"
PORT = 443
CTX = ssl._create_unverified_context()


def connect():
    raw = socket.create_connection((HOST, PORT), timeout=10)
    return CTX.wrap_socket(raw, server_hostname=HOST)


class MjpegReader(threading.Thread):
    """Long-lived /api/stream/mjpeg consumer. Counts SOI markers as they land."""

    daemon = True

    def __init__(self):
        super().__init__()
        self.frames = 0
        self.bytes = 0
        self.error = None
        self.stop = threading.Event()

    def run(self):
        try:
            sock = connect()
            sock.sendall(
                f"GET /api/stream/mjpeg HTTP/1.1\r\nHost: {HOST}\r\n\r\n".encode()
            )
            sock.settimeout(2)
            tail = b""
            while not self.stop.is_set():
                try:
                    chunk = sock.recv(65536)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                self.bytes += len(chunk)
                # count SOI across the chunk boundary too
                window = tail + chunk
                self.frames += window.count(b"\xff\xd8\xff")
                tail = window[-2:]
            sock.close()
        except Exception as err:  # noqa: BLE001 - reported, not raised
            self.error = f"{type(err).__name__}: {err}"


class DirectClient:
    """wss /api/stream/<codec>/direct consumer. Counts binary messages."""

    def __init__(self, codec="h264"):
        self.codec = codec
        self.messages = 0
        self.error = None
        self.stop = threading.Event()
        self.sock = None
        self.thread = None

    def open(self):
        sock = connect()
        key = base64.b64encode(os.urandom(16)).decode()
        sock.sendall(
            (
                f"GET /api/stream/{self.codec}/direct HTTP/1.1\r\n"
                f"Host: {HOST}\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                "Sec-WebSocket-Version: 13\r\n"
                "\r\n"
            ).encode()
        )
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = sock.recv(4096)
            if not chunk:
                raise ConnectionError("closed during handshake")
            resp += chunk
        head, _, rest = resp.partition(b"\r\n\r\n")
        status = head.split(b"\r\n", 1)[0].decode()
        if "101" not in status:
            raise ConnectionError(f"handshake failed: {status}")

        self.sock = sock
        self.thread = threading.Thread(target=self._read, args=(rest,), daemon=True)
        self.thread.start()
        return status

    def _read(self, rest):
        buf = rest
        self.sock.settimeout(2)

        def take(n):
            nonlocal buf
            while len(buf) < n:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise ConnectionError("socket closed mid-frame")
                buf += chunk
            out, buf = buf[:n], buf[n:]
            return out

        try:
            while not self.stop.is_set():
                try:
                    b0, b1 = take(2)
                except socket.timeout:
                    continue
                ln = b1 & 0x7F
                if ln == 126:
                    (ln,) = struct.unpack(">H", take(2))
                elif ln == 127:
                    (ln,) = struct.unpack(">Q", take(8))
                if b1 & 0x80:
                    take(4)
                take(ln)
                if (b0 & 0x0F) == 2:
                    self.messages += 1
        except Exception as err:  # noqa: BLE001
            if not self.stop.is_set():
                self.error = f"{type(err).__name__}: {err}"

    def close(self):
        self.stop.set()
        try:
            self.sock.close()
        except Exception:  # noqa: BLE001
            pass
        if self.thread:
            self.thread.join(timeout=5)


def main():
    phase = float(sys.argv[1]) if len(sys.argv) > 1 else 6.0

    mjpeg = MjpegReader()
    mjpeg.start()
    time.sleep(1.5)  # let the multipart stream get going

    base = mjpeg.frames
    time.sleep(phase)
    p1 = mjpeg.frames - base
    print(f"phase 1  mjpeg alone           : {p1} frames")
    if mjpeg.error:
        print(f"  mjpeg error: {mjpeg.error}")

    direct = DirectClient("h264")
    print(f"  {direct.open()}")
    mark = mjpeg.frames
    time.sleep(phase)
    p2 = mjpeg.frames - mark
    print(f"phase 2  direct took the stream: {p2} mjpeg frames, {direct.messages} direct messages")

    direct.close()
    mark = mjpeg.frames
    time.sleep(phase)
    p3 = mjpeg.frames - mark
    print(f"phase 3  direct gone           : {p3} mjpeg frames")

    mjpeg.stop.set()
    mjpeg.join(timeout=5)

    ok = p1 > 0 and p2 < p1 / 4 and direct.messages > 0 and p3 > 0
    print()
    print(f"expect: phase 1 > 0, phase 2 ~ 0 with direct messages > 0, phase 3 > 0")
    print(f"VERDICT: {'PASS' if ok else 'FAIL'} (hand-back {'works' if p3 > 0 else 'did NOT happen'})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
