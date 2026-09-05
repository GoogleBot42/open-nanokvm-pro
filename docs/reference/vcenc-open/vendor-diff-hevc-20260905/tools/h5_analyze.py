#!/usr/bin/env python3
"""h5_analyze.py <H5dir>: HEVC single-knob sweep -> knob->register map (+ parsed VPS/SPS/PPS/slice facts per run)."""
import sys, os, glob, re, struct, subprocess
T = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, T)
from analib import load, nal_sizes, ADDR
H5 = sys.argv[1]
runs = []
for l in open(H5 + "/batch.log"):
    m = re.match(r"=== (\S+): ?(.*)", l)
    if m: runs.append((m.group(1), m.group(2).strip()))
base_i = load(H5 + "/vendor_base_IDR.txt"); base_p = load(H5 + "/vendor_base_P.txt")
moves = {}
def sec(tag, ph):
    fs = glob.glob(H5 + "/cmdpool_%s_%s_0x*.bin" % (tag, ph))
    if not fs: return None
    d = open(fs[0], "rb").read(); w = struct.unpack_from("<%dI" % (0x2000//4), d, 0x2000)
    return w[516:552]
def parse(tag):
    f = H5 + "/%s.h265" % tag
    if not os.path.exists(f): return "", "", "", []
    out = subprocess.run([sys.executable, os.path.join(T, "h265parse.py"), f], capture_output=True, text=True).stdout.splitlines()
    vps = next((l for l in out if "VPS(32)" in l), ""); sps = next((l for l in out if "SPS(33)" in l), ""); pps = next((l for l in out if "PPS(34)" in l), "")
    sl = [l for l in out if " slice " in l]
    return vps.strip(), sps.strip(), pps.strip(), [s.strip() for s in sl]
bv, bs, bp, bsl = parse("base")
print("== H5 HEVC single-knob sweep (1080p CBR8000 fps60 gop30 Main 5.1 baseline). Per run: create rc, NAL sizes, header deltas vs base, regs moved vs base ==")
print("BASE VPS: %s\nBASE SPS: %s\nBASE PPS: %s\nBASE slices: %s" % (bv, bs, bp, " ; ".join(bsl[:2])))
for tag, args in runs:
    fi = H5 + "/vendor_%s_IDR.txt" % tag; fp = H5 + "/vendor_%s_P.txt" % tag
    log = open(H5 + "/%s.log" % tag).read()
    cr = re.search(r"CreateChn\(7\) rc=0x(\w+)", log); extra = re.findall(r"((?:Set|Get)\w+\([^)]*\) rc=0x\w+)", log)
    fr = nal_sizes(H5 + "/%s.log" % tag)
    if not os.path.exists(fi):
        print("-- %-12s %-36s CREATE rc=%s  (no program)" % (tag, args, cr.group(1) if cr else "?")); continue
    i = load(fi); p = load(fp) if os.path.exists(fp) else {}
    v, s, pp, sl = parse(tag)
    di = [(r, base_i.get(r), i.get(r)) for r in sorted(set(base_i)|set(i)) if base_i.get(r) != i.get(r) and r not in ADDR]
    dp = [(r, base_p.get(r), p.get(r)) for r in sorted(set(base_p)|set(p)) if base_p.get(r) != p.get(r) and r not in ADDR] if p else []
    sizes = " ".join("f%d:%s%d" % (f['i'], "I" if f['coding']==0 else "P", f['len']) for f in fr[:6])
    print("-- %-12s %-36s rc=%s %s" % (tag, args, cr.group(1) if cr else "?", " ".join(extra)))
    print("   sizes: %s" % sizes)
    def delta(a, b, name):
        ta, tb = a.split(), b.split(); d = [x for x in tb if x not in ta]
        return ("%s: %s" % (name, " ".join(d))) if d else ""
    hd = [x for x in (delta(bv, v, "VPS"), delta(bs, s, "SPS"), delta(bp, pp, "PPS")) if x]
    sd = [x for x in (delta(bsl[0] if bsl else "", sl[0] if sl else "", "slice0"), delta(bsl[1] if len(bsl)>1 else "", sl[1] if len(sl)>1 else "", "slice1")) if x]
    if hd or sd: print("   header deltas: %s" % " | ".join(hd + sd))
    print("   IDR moved: %s" % (", ".join("sw%d %s->%s" % (r, hex(a) if a is not None else "-", hex(b) if b is not None else "-") for r, a, b in di) or "none"))
    print("   P   moved: %s" % ((", ".join("sw%d %s->%s" % (r, hex(a) if a is not None else "-", hex(b) if b is not None else "-") for r, a, b in dp) or "none") if p else "(no P frame in run)"))
    for r, a, b in di: moves.setdefault(r, []).append((tag, "I"))
    for r, a, b in dp: moves.setdefault(r, []).append((tag, "P"))
    sb, st = sec("base", "IDR"), sec(tag, "IDR")
    if sb and st and sb != st: print("   SECONDARY-BANK pokes differ from base: %s" % [hex(x) for x in st])
print("\n== which knob moves swregN ==")
allregs = sorted(set(base_i)|set(base_p))
never = [r for r in allregs if r not in moves and r not in ADDR]
for r in sorted(moves): print("sw%-4d: %s" % (r, ", ".join("%s(%s)" % k for k in moves[r])))
print("\nregisters NEVER moved by any knob (excluding %d addr regs): %d of %d" % (len(ADDR), len(never), len(allregs)))
print("secondary-bank base pokes (slot1 words 516..551):", [hex(x) for x in sec("base", "IDR")])
