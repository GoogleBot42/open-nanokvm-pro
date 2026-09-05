#!/usr/bin/env python3
"""Minimal stdlib WebSocket client for the NanoKVM direct H.264/H.265 streams.

Connects to wss://127.0.0.1/api/stream/<codec>/direct (localhost bypasses
auth), collects N binary messages (server framing: 1-byte keyframe flag +
8-byte LE microsecond timestamp + Annex-B payload -- one NAL for H.264, one
NAL or VPS+SPS+PPS+IDR for H.265 key messages), writes the concatenated
payloads to the output file, and prints a per-message summary line listing
every NAL type found in the message.

Usage: wsgrab.py <out.h26x> <nmsgs> [timeout_s] [h264|h265]
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


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("socket closed")
        buf += chunk
    return buf


def nal_types(data, codec):
    """NAL unit types of every Annex-B NAL (00 00 01 / 00 00 00 01) in data."""
    types = []
    i = 0
    n = len(data)
    while i + 3 <= n:
        if data[i] == 0 and data[i + 1] == 0:
            if data[i + 2] == 1:
                hdr = i + 3
            elif i + 3 < n and data[i + 2] == 0 and data[i + 3] == 1:
                hdr = i + 4
            else:
                i += 1
                continue
            if hdr < n:
                if codec == "h265":
                    types.append((data[hdr] >> 1) & 0x3F)
                else:
                    types.append(data[hdr] & 0x1F)
            i = hdr + 1
        else:
            i += 1
    return types


def main():
    out_path = sys.argv[1]
    want = int(sys.argv[2])
    deadline = time.time() + (float(sys.argv[3]) if len(sys.argv) > 3 else 30.0)
    codec = sys.argv[4] if len(sys.argv) > 4 else "h264"
    path = f"/api/stream/{codec}/direct"

    raw = socket.create_connection((HOST, PORT), timeout=10)
    ctx = ssl._create_unverified_context()
    sock = ctx.wrap_socket(raw, server_hostname=HOST)
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\n"
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
    print(f"ws connected ({path}): {status}")

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
            msgs.append((flag, ts, nal))
            print(f"msg {len(msgs):3d}: key={flag} ts={ts} len={len(nal)} "
                  f"nal_types={nal_types(nal, codec)}")
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
