#!/usr/bin/env python3
"""h3_analyze.py <H3dir>: HEVC fixed-QP ladder -> per-QP register laws (sw7/sw37/sw125-132/sw105-107/sw172/173),
bitstream slice QPs (h265parse), per-frame mirror read-backs (sw9 bytes / sw82 cycles) and NAL sizes."""
import sys, os, re, glob, subprocess, struct
T = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, T)
from analib import load, mirrors, nal_sizes
D = sys.argv[1]
runs = [("fixqp%d" % q, q, q) for q in (16,20,24,28,32,36,40,44,48,51)] + [("fixqp_i28_p34", 28, 34)]
Fi, Fp = {}, {}
print("== HEVC fixed-QP ladder (1080p, 6 frames, static card) ==")
for tag, iq, pq in runs:
    i = load(os.path.join(D, "vendor_%s_f000.txt" % tag)); p = load(os.path.join(D, "vendor_%s_f001.txt" % tag))
    out = subprocess.run([sys.executable, os.path.join(T, "h265parse.py"), os.path.join(D, tag + ".h265")], capture_output=True, text=True).stdout
    qps = re.findall(r"type=(\w)\(\d\).*?qp=(\d+)", out)
    fr = nal_sizes(os.path.join(D, tag + ".log"))
    mir = []
    for k in range(6):
        ms = mirrors(D, tag, "f%03d" % k)
        # the freshest mirror = the one whose sw82 (cycles) is new vs the previous snapshot; report all (sw9,sw82) pairs seen
        mir.append(sorted({(m[2][9], m[2][82]) for m in ms if len(m[2]) > 82}))
    print("-- %-14s I=%d P=%d  sizes %s  sliceQP %s" % (tag, iq, pq, " ".join("%s%d" % ("I" if f['coding']==0 else "P", f['len']) for f in fr), " ".join("%s%s" % t for t in qps)))
    print("   IDR: sw7=%08x sw37=%08x sw105=%d sw106=%d sw107=%d sw172=%x sw173=%x sw6=%x sw22=%x sw245=%x sw246=%x sw239=%x sw241=%x" % (i[7], i[37], i[105], i[106], i[107], i[172], i[173], i[6], i[22], i[245], i[246], i.get(239,0), i.get(241,0)))
    print("        sw125..132: %s" % " ".join("%08x" % i[r] for r in range(125,133)))
    print("   P  : sw7=%08x sw37=%08x sw105=%d sw106=%d sw107=%d sw172=%x sw173=%x sw243=%x sw244=%x sw247=%x" % (p[7], p[37], p[105], p[106], p[107], p[172], p[173], p[243], p[244], p[247]))
    print("        sw125..132: %s" % " ".join("%08x" % p[r] for r in range(125,133)))
    newm = []
    for k in range(6):
        prev = set(mir[k-1]) if k else set()
        newm.append([m for m in mir[k] if m not in prev])
    print("   mirrors (sw9 bytes, sw82 cycles) new per frame: %s" % " | ".join(",".join("%d/%d" % m for m in n) for n in newm))
    Fi[iq] = [i[r] for r in range(125,133)]; Fi[("sw37", iq)] = i[37]
    Fp[pq] = [p[r] for r in range(125,133)]; Fp[("sw37", pq)] = p[37]
print("\n== table view: q -> (sw37, F block) for I and P ==")
for q in sorted(k for k in Fi if isinstance(k, int)):
    print("I q=%2d sw37=%08x F=%s" % (q, Fi[("sw37", q)], " ".join("%08x" % v for v in Fi[q])))
for q in sorted(k for k in Fp if isinstance(k, int)):
    print("P q=%2d sw37=%08x F=%s" % (q, Fp[("sw37", q)], " ".join("%08x" % v for v in Fp[q])))
