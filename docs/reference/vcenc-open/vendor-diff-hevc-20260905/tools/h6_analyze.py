#!/usr/bin/env python3
"""h6_analyze.py <H6dir> <tag> <nframes>: per-frame HEVC register table (snapall runs) correlated with the parsed slice headers."""
import sys, os, re, subprocess
T = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, T)
from analib import load, nal_sizes, ADDR
D, tag, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
out = subprocess.run([sys.executable, os.path.join(T, "h265parse.py"), os.path.join(D, tag + ".h265")], capture_output=True, text=True).stdout.splitlines()
sl = [l.strip() for l in out if " slice " in l]
progs = []
for k in range(n):
    f = os.path.join(D, "vendor_%s_f%03d.txt" % (tag, k))
    progs.append(load(f) if os.path.exists(f) else None)
WATCH = [5, 11, 17, 191, 192, 190, 193, 194, 195, 196, 197, 198, 202, 15, 16, 18, 19, 60, 62, 64, 66, 72, 74, 114, 239, 241, 8, 9, 82, 7, 37, 105, 243, 244, 247]
print("== %s: per-frame programs (%d frames) ==" % (tag, n))
print("frame " + " ".join("%-10s" % ("sw%d" % r) for r in WATCH))
for k, p in enumerate(progs):
    if p is None: print("%5d (no program)" % k); continue
    print("%5d " % k + " ".join("0x%08x" % p.get(r, 0) for r in WATCH))
print("\nslice headers:")
for k, s in enumerate(sl[:n]): print("%5d %s" % (k, re.sub(r"lid=0 tid=1 ", "", s)))
# which non-address registers change from frame to frame (excluding known RC/QP)
RC = {7, 37, 105, 106, 107, 243, 244, 247} | set(range(125, 133)) | {170, 171, 9}
print("\nnon-address, non-RC registers that change frame-to-frame:")
for k in range(1, n):
    a, b = progs[k-1], progs[k]
    if a is None or b is None: continue
    d = [(r, a.get(r), b.get(r)) for r in sorted(set(a)|set(b)) if a.get(r) != b.get(r) and r not in ADDR and r not in RC]
    print("  f%d->f%d: %s" % (k-1, k, ", ".join("sw%d %08x->%08x" % (r, x or 0, y or 0) for r, x, y in d) or "none"))
# address deltas: reference = previous recon?
print("\nDPB: sw18/19 (ref) vs previous frame's sw15/16 (recon), sw74 vs prev sw72, sw66 vs prev sw64:")
for k in range(1, n):
    a, b = progs[k-1], progs[k]
    if a is None or b is None: continue
    print("  f%d: ref_l=%s ref_c=%s s74=%s s66=%s | recon_l=%08x (ping-pong: %s)" % (k, "prevRecon" if b.get(18)==a.get(15) else "%08x" % b.get(18,0), "prevRecon" if b.get(19)==a.get(16) else "%08x" % b.get(19,0), "prev72" if b.get(74)==a.get(72) else "%08x" % b.get(74,0), "prev64" if b.get(66)==a.get(64) else "%08x" % b.get(66,0), b.get(15,0), "alt" if b.get(15)!=a.get(15) else "SAME"))
