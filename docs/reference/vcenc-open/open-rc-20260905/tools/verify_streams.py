#!/usr/bin/env python3
"""Decode every prover/live stream with ffmpeg (zero errors required) and
compare the bitstream slice QPs against the controller's per-frame log."""
import os, re, subprocess, sys
ROOT = "/home/googlebot/workspace/nanokvm/nix-nanokvm-pro/.claude/worktrees/agent-a79b9f647adb6311b/docs/reference/vcenc-open"
sys.path.insert(0, os.path.join(ROOT, "vendor-diff-20260904", "tools"))
sys.path.insert(0, os.path.join(ROOT, "vendor-diff-hevc-20260905", "tools"))
import h264parse, h265parse  # noqa: E402

def slices_h264(fn):
    out = []
    for n in h264parse.nals(open(fn, "rb").read()):
        t = n[0] & 0x1f
        if t == 7: h264parse.sps(n)
        elif t == 8: h264parse.pps(n)
        elif t in (1, 5):
            s = h264parse.slc(n)
            m = re.search(r"qp=(\d+)", s)
            out.append(("I" if t == 5 else "P", int(m.group(1)) if m else -1, len(n)))
    return out

def slices_h265(fn):
    out = []
    for n in h265parse.nals(open(fn, "rb").read()):
        s, d = h265parse.parse_nal(n)
        t = d["nal_unit_type"]
        if t <= 21 and "SliceQpY" in d:
            out.append(("I" if t >= 16 else "P", d["SliceQpY"], len(n)))
    return out

def log_qps(fn):
    qps = []
    for l in open(fn):
        m = re.match(r"frame\s+(\d+): (IDR|P)\s+qp=(\d+)", l)
        if m: qps.append(("I" if m.group(2) == "IDR" else "P", int(m.group(3))))
    return qps

d = sys.argv[1]
bad = 0
for f in sorted(os.listdir(d)):
    if not (f.endswith(".h264") or f.endswith(".h265")): continue
    p = os.path.join(d, f)
    r = subprocess.run(["ffmpeg", "-v", "error", "-i", p, "-f", "null", "-"], capture_output=True, text=True)
    errs = [l for l in r.stderr.splitlines() if l.strip()]
    sl = slices_h265(p) if f.endswith(".h265") else slices_h264(p)
    logf = os.path.splitext(p)[0] + ".log"
    lq = log_qps(logf) if os.path.exists(logf) else []
    mism = sum(1 for a, b in zip(sl, lq) if a[1] != b[1] or a[0] != b[0]) if lq else -1
    qps = [q for _, q, _ in sl]
    print("%-24s ffmpeg-errors=%d slices=%d log-frames=%d qp-mismatch=%s I-qps=%s P-range=%d..%d bytes=%d" % (
        f, len(errs), len(sl), len(lq), mism, [q for t, q, _ in sl if t == "I"][:10],
        min(qps) if qps else -1, max(qps) if qps else -1, sum(b for _, _, b in sl)))
    if errs: print("   ", errs[:3])
    if errs or (lq and mism): bad += 1
print("RESULT:", "PASS" if not bad else "FAIL (%d)" % bad)
