#!/usr/bin/env python3
"""decode_run.py <outdir> <tag> <W> <H> [--all] [--generic]
Find the fresh IDR/P cmdbuf slots for a vdrive run and write
vendor_<tag>_{IDR,P}.txt in the geom-probe format. --all: one file per fNNN snapshot.
Default (H.264) slot finder: slots that changed vs 'pre' and carry the run's
geometry in sw210 / the H.264 frame type in sw191.
--generic (codec-agnostic, 2026-09-05): the fresh slot is the one that CHANGED
between consecutive snapshots (pre -> IDR, IDR -> P) among the >=400-register
slots, keyed on the codec-independent frame-type field sw5[7:0] (0x03 = IDR,
0x01 = P; identical in the H.264 and HEVC programs). A repeat run on a static
card rewrites byte-identical programs, so when nothing changed the vendor's
fixed slot assignment is used (fresh IDR = slot 1, fresh P = slot 2)."""
import sys, os, glob, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmdpool_decode import load_pool
out, tag, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
ALL = "--all" in sys.argv
GENERIC = "--generic" in sys.argv
FIXED = {"IDR": 1, "P": 2}
def pools(phase):
    fs = glob.glob(os.path.join(out, "cmdpool_%s_%s_0x*.bin" % (tag, phase)))
    return fs[0] if fs else None
pre = load_pool(pools("pre")) if pools("pre") else []
def fresh(phase, want_type, prev=None, sw5type=None):
    f = pools(phase)
    if not f: return None, None
    slots = load_pool(f)
    base = pre if prev is None else prev
    cands = []
    for i, p in enumerate(slots):
        if len(p) < 400: continue
        if not GENERIC:
            if (p.get(210, 0) >> 16) != W // 16: continue
            ty = p.get(191, 0) >> 24
            if want_type is not None and ty != want_type: continue
        else:
            if sw5type is not None and (p.get(5, 0) & 0xff) != sw5type: continue
        changed = (i >= len(base)) or (base[i] != p)
        if GENERIC and not changed and i != FIXED.get(phase, -1): continue
        cands.append((changed, i, p))
    if not cands: return None, None
    cands.sort(key=lambda c: (not c[0], c[1]))
    return cands[0][1], cands[0][2]
def write(p, slot, phase, kind):
    fn = os.path.join(out, "vendor_%s_%s.txt" % (tag, kind))
    with open(fn, "w") as f:
        f.write("# vendor AX_VENC %dx%d %s frame register program (cmdbuf WREG decode)\n" % (W, H, kind))
        f.write("# probe: vdrive.c tag=%s phase=%s slot=%d, 2026-09-05\n" % (tag, phase, slot))
        for r in sorted(p):
            f.write("swreg%-4d 0x%08x\n" % (r, p[r]))
    print("wrote %s (slot %d, %d regs, sw191=0x%08x sw7=0x%08x sw9=0x%08x sw5=0x%08x)" % (fn, slot, len(p), p.get(191,0), p.get(7,0), p.get(9,0), p.get(5,0)))
if ALL:
    prev = pre
    for f in sorted(glob.glob(os.path.join(out, "cmdpool_%s_f*_0x*.bin" % tag))):
        ph = f.split("_")[-2]
        s, p = fresh(ph, None, prev if GENERIC else None)
        if p: write(p, s, ph, ph)
        if GENERIC: prev = load_pool(f)
else:
    s, p = fresh("IDR", 0x14, None, 0x03)
    if p: write(p, s, "IDR", "IDR")
    else: print("!! no IDR program for", tag)
    idr_pool = load_pool(pools("IDR")) if pools("IDR") else None
    s, p = fresh("P", 0x04, idr_pool if GENERIC else None, 0x01)
    if p: write(p, s, "P", "P")
    else: print("!! no P program for", tag)
