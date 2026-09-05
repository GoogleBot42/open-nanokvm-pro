#!/usr/bin/env python3
"""h2_fit.py <H2dir>: try HEVC candidate laws for the registers that left the H.264 laws."""
import re, sys, os, glob
D = sys.argv[1]
def load(fn):
    d = {}
    for l in open(fn):
        m = re.match(r"swreg(\d+)\s+0x([0-9a-f]+)", l)
        if m: d[int(m.group(1))] = int(m.group(2), 16)
    return d
def al(v, a): return (v + a - 1) // a * a
def rnd(a, b): return (2*a//b + 1)//2
GE = sorted({os.path.basename(f)[7:-8] for f in glob.glob(os.path.join(D, "vendor_*_IDR.txt"))}, key=lambda g: (int(g.split("x")[0]), int(g.split("x")[1])))
fails = {}
rows = []
for g in GE:
    W, H = map(int, g.split("x")); i = load(os.path.join(D, "vendor_%s_IDR.txt" % g)); p = load(os.path.join(D, "vendor_%s_P.txt" % g))
    ctbw, ctbh = (W+63)//64, (H+63)//64; mbw = (W+15)//16; w4 = al(mbw, 4); wp = w4*16; hp = al(H, 64); mbhp = hp//16
    cand = {
      "sw5=(al8W/2)<<20|al8H<<8|type": (((al(W,8)//2) << 20) | (al(H,8) << 8) | (i[5] & 0xff), i[5]),
      "sw5(P)": (((al(W,8)//2) << 20) | (al(H,8) << 8) | (p[5] & 0xff), p[5]),
      "sw261=al8(W)<<16|0x400": ((al(W,8) << 16) | 0x400, i[261]),
      "sw245=0x20000000|rnd(2^16/ctbw)*4": (0x20000000 | rnd(0x10000, ctbw)*4, i[245]),
      "sw246=rnd(2^18/ctbw)<<14|0x1010": ((rnd(0x40000, ctbw) << 14) | 0x1010, i[246]),
      "sw245(P)": (0x20000000 | rnd(0x10000, ctbw)*4, p[245]),
      "sw246(P)": ((rnd(0x40000, ctbw) << 14) | 0x1010, p[246]),
      "|241-239|=al4k(ctbw*ctbh)": (al(ctbw*ctbh, 4096), abs(i[241]-i[239])),
      "sw114 same I/P": (i[114], p[114]),
      "sw35": (0x00018e1a, i[35]), "sw36": (0x1c995f14, i[36]),
      "sw134=0x0a000000|2^28/(wp*hp)": (0x0a000000 | (0x10000000 // (wp*hp)), i[134]),
    }
    bad = [k for k, (want, got) in cand.items() if want != got]
    for b in bad: fails.setdefault(b, []).append("%s(want %08x got %08x)" % (g, cand[b][0], cand[b][1]))
    rows.append((g, ctbw, ctbh, i[245], i[246], i[261], i[5], i[114], i[239], i[241], i[60], i[62], p[60], i[72], p[72], i[15], i[16], i[46], i[8], i[10], i[27], i[12], i[13], i[14]))
print("candidate HEVC laws -- failures:")
for k, v in fails.items(): print("  %-36s %d: %s" % (k, len(v), " ".join(v[:6])))
print("  (all other candidates hold at all %d geometries)" % len(GE))
print("\ngeom       ctbw ctbh sw245      sw246      sw261      sw5        | sw114    sw239    sw241    sw60     sw62     sw60(P)  sw72     sw72(P)  sw15     sw16     sw46     sw8      sw10     sw27     sw12     sw13     sw14")
for r in rows:
    print("%-10s %4d %4d %08x %08x %08x %08x | " % r[:7] + " ".join("%08x" % x for x in r[7:]))
