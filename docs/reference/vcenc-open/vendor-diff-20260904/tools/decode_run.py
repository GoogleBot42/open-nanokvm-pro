#!/usr/bin/env python3
"""decode_run.py <outdir> <tag> <W> <H> [--all]
Find the fresh IDR/P cmdbuf slots for a vdrive run (slots that changed vs the
'pre' snapshot and carry the run's geometry in sw210) and write
vendor_<tag>_{IDR,P}.txt in the geom-probe format. --all: one file per fNNN snapshot."""
import sys, os, glob, struct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmdpool_decode import load_pool
out, tag, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
ALL = "--all" in sys.argv
def pools(phase):
    fs = glob.glob(os.path.join(out, "cmdpool_%s_%s_0x*.bin" % (tag, phase)))
    return fs[0] if fs else None
pre = load_pool(pools("pre")) if pools("pre") else []
def fresh(phase, want_type):
    f = pools(phase)
    if not f: return None, None
    slots = load_pool(f)
    cands = []
    for i, p in enumerate(slots):
        if len(p) < 400: continue
        if (p.get(210, 0) >> 16) != W // 16: continue
        ty = p.get(191, 0) >> 24
        if want_type is not None and ty != want_type: continue
        changed = (i >= len(pre)) or (pre[i] != p)
        cands.append((changed, i, p))
    if not cands: return None, None
    cands.sort(key=lambda c: (not c[0], c[1]))
    return cands[0][1], cands[0][2]
def write(p, slot, phase, kind):
    fn = os.path.join(out, "vendor_%s_%s.txt" % (tag, kind))
    with open(fn, "w") as f:
        f.write("# vendor AX_VENC %dx%d %s frame register program (cmdbuf WREG decode)\n" % (W, H, kind))
        f.write("# probe: vdrive.c tag=%s phase=%s slot=%d, 2026-09-04\n" % (tag, phase, slot))
        for r in sorted(p):
            f.write("swreg%-4d 0x%08x\n" % (r, p[r]))
    print("wrote %s (slot %d, %d regs, sw191=0x%08x sw7=0x%08x sw9=0x%08x)" % (fn, slot, len(p), p.get(191,0), p.get(7,0), p.get(9,0)))
if ALL:
    for f in sorted(glob.glob(os.path.join(out, "cmdpool_%s_f*_0x*.bin" % tag))):
        ph = f.split("_")[-2]
        s, p = fresh(ph, None)
        if p: write(p, s, ph, ph)
else:
    s, p = fresh("IDR", 0x14)
    if p: write(p, s, "IDR", "IDR")
    else: print("!! no IDR program for", tag)
    s, p = fresh("P", 0x04)
    if p: write(p, s, "P", "P")
    else: print("!! no P program for", tag)
