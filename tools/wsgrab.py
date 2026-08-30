#!/usr/bin/env python3
"""Minimal stdlib WebSocket client for the NanoKVM direct H.264 stream.

Connects to ws://127.0.0.1/api/stream/h264/direct (localhost bypasses auth),
collects N binary messages (server framing: 1-byte keyframe flag + 8-byte LE
microsecond timestamp + one Annex-B NAL), writes the concatenated NALs to the
output file, and prints a per-message summary line.

Usage: wsgrab.py <out.h264> <nmsgs> [timeout_s]
"""
import base64
import os
import socket
import ssl
import struct
import sys
import time

HOST = "127.0.0.1"
PORT = 443
PATH = "/api/stream/h264/direct"


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("socket closed")
        buf += chunk
    return buf


def main():
    out_path = sys.argv[1]
    want = int(sys.argv[2])
    deadline = time.time() + (float(sys.argv[3]) if len(sys.argv) > 3 else 30.0)

    raw = socket.create_connection((HOST, PORT), timeout=10)
    ctx = ssl._create_unverified_context()
    sock = ctx.wrap_socket(raw, server_hostname=HOST)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {PATH} HTTP/1.1\r\n"
        f"Host: {HOST}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    )
    sock.sendall(req.encode())

    resp = b""
    while b"\r\n\r\n" not in resp:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("closed during handshake")
        resp += chunk
    head, _, rest = resp.partition(b"\r\n\r\n")
    status = head.split(b"\r\n", 1)[0].decode()
    if "101" not in status:
        print(f"HANDSHAKE FAILED: {status}")
        print(head.decode(errors="replace"))
        sys.exit(1)
    print(f"ws connected: {status}")

    buf = rest
    msgs = []

    def take(n):
        nonlocal buf
        while len(buf) < n:
            chunk = sock.recv(65536)
            if not chunk:
                raise ConnectionError("socket closed mid-frame")
            buf += chunk
        out, buf = buf[:n], buf[n:]
        return out

    sock.settimeout(10)
    while len(msgs) < want and time.time() < deadline:
        b0, b1 = take(2)
        opcode = b0 & 0x0F
        ln = b1 & 0x7F
        if ln == 126:
            (ln,) = struct.unpack(">H", take(2))
        elif ln == 127:
            (ln,) = struct.unpack(">Q", take(8))
        if b1 & 0x80:  # masked server frame: not expected, but handle
            mask = take(4)
            payload = bytes(c ^ mask[i % 4] for i, c in enumerate(take(ln)))
        else:
            payload = take(ln)
        if opcode == 2 and len(payload) >= 9:
            flag = payload[0]
            (ts,) = struct.unpack("<q", payload[1:9])
            nal = payload[9:]
            nut = nal[4] & 0x1F if len(nal) > 4 else -1
            msgs.append((flag, ts, nal))
            print(f"msg {len(msgs):3d}: key={flag} ts={ts} len={len(nal)} nal_type={nut}")
        elif opcode == 8:
            print("server close frame")
            break

    with open(out_path, "wb") as f:
        for _, _, nal in msgs:
            f.write(nal)
    total = sum(len(n) for _, _, n in msgs)
    keys = sum(1 for fl, _, _ in msgs if fl)
    print(f"RESULT: {len(msgs)} messages, {total} bytes, {keys} keyframe-flagged -> {out_path}")
    sys.exit(0 if len(msgs) >= min(want, 10) else 2)


if __name__ == "__main__":
    main()
