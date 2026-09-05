#!/usr/bin/env python3
"""Per-retarget-segment summary of an [openvenc][rc] log (live path)."""
import re, sys
fps = 59.0
segs = []
cur = None
for l in open(sys.argv[1]):
    m = re.search(r"\[openvenc\] up: .*?(H\.26[45]) .*rc=(\w+) program=(\w+) QP(\d+) gop=(\d+)", l)
    if m:
        cur = dict(name="%s %s gop%s seed%s" % (m.group(1), m.group(2), m.group(5), m.group(4)), kbps=None, fr=[])
        segs.append(cur); continue
    m = re.search(r"\[openvenc\] rc: (\d+) kbps", l)
    if m and cur is not None and cur["kbps"] is None:
        cur["kbps"] = int(m.group(1)); continue
    m = re.search(r"\[rc\] retarget (\d+) kbps", l)
    if m:
        cur = dict(name=(segs[-1]["name"] if segs else "?") + " retarget", kbps=int(m.group(1)), fr=[])
        segs.append(cur); continue
    m = re.search(r"\[rc\] f=(\d+) (IDR|P) qp=(\d+) bytes=(\d+)", l)
    if m and cur is not None:
        cur["fr"].append((m.group(2) == "IDR", int(m.group(3)), int(m.group(4))))
for s in segs:
    fr = s["fr"]
    if not fr: continue
    b = sum(x[2] for x in fr)
    pq = [x[1] for x in fr if not x[0]]
    iq = [x[1] for x in fr if x[0]]
    ib = [x[2] for x in fr if x[0]]
    print("%-36s target %5s kbps: %4d frames, %6.0f kbps achieved, IDR QPs %s (IDR bytes %s), P QP %d..%d, mean P bytes %.0f" % (
        s["name"], s["kbps"], len(fr), b * 8 / len(fr) * fps / 1000, iq[:9], [round(x / 1024) for x in ib[:6]],
        min(pq) if pq else -1, max(pq) if pq else -1, sum(x[2] for x in fr if not x[0]) / max(1, len(pq))))
    print("    first 60 QPs:", " ".join(("I" if x[0] else "") + str(x[1]) for x in fr[:60]))
    if len(fr) > 300:
        print("    frames 240..300:", " ".join(("I" if x[0] else "") + str(x[1]) for x in fr[240:300]))
