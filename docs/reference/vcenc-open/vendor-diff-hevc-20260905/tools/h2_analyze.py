#!/usr/bin/env python3
"""h2_analyze.py <H2dir> [geoms...] -- HEVC geometry sweep analysis.
1. Which H.264 laws (vcenc_geom.h) still hold for the HEVC programs.
2. Per-register value table of every geometry-varying non-address register
   (IDR and P) so CTU-based laws can be fitted.
3. Candidate HEVC laws tried automatically (edit CAND below as the fit evolves)."""
import re, sys, os, glob
D = sys.argv[1]
def load(fn):
    d = {}
    for l in open(fn):
        m = re.match(r"swreg(\d+)\s+0x([0-9a-f]+)", l)
        if m: d[int(m.group(1))] = int(m.group(2), 16)
    return d
def al(v, a): return (v + a - 1) // a * a
def h264laws(W, H, hdr):
    mbw, mbh = (W+15)//16, (H+15)//16
    w4 = al(mbw, 4); wp = w4*16; hp = al(H, 64); mbhp = hp//16; p4 = w4*4
    g = {}
    g[5] = ((mbw*16//2) << 20) | ((mbh*16+3) << 8)
    g[9] = 2*W*H + 0x10000 - hdr
    g[38] = 0x20000000 | (W*64 + ((16-W%16)%8)*8 + ((16-H%16)%8)*2)
    g[134] = 0x0a000000 | (0x10000000 // (wp*hp))
    g[210] = ((W//16) << 16) | ((W%16) << 12) | 0xff8
    g[212] = (p4 << 16) | 0x0ff8
    g[213] = (p4 << 16) | 0x3fe0
    g[237] = (p4 << 16) | 0x0044
    g[245] = 0x20000000 | (((2*0x10000//mbw + 1)//2)*4)
    g[246] = (((2*0x40000//mbw + 1)//2) << 14) | 0x1028
    g[261] = ((mbw*16) << 16) | 0x0400
    g['lupitch'] = wp*hp + al(w4*mbhp*16, 4096)
    g['chpitch'] = al(wp*hp//2, 4096)
    g['s62off'] = al(w4*mbhp//2, 64)
    g['s239sz'] = al(w4*mbhp, 4096)
    g['s114sz'] = al(w4*mbhp//2, 4096)
    return g
ADDR = {8,10,12,13,14,15,16,18,19,27,46,60,62,64,66,72,74,114,239,241}
if len(sys.argv) > 2: GEOMS = sys.argv[2:]
else:
    GEOMS = sorted({os.path.basename(f)[7:-8] for f in glob.glob(os.path.join(D, "vendor_*_IDR.txt"))},
                   key=lambda g: (int(g.split("x")[0]), int(g.split("x")[1])))
data = {}
for g in GEOMS:
    fi, fp, fl = [os.path.join(D, "vendor_%s_%s.txt" % (g, k)) for k in ("IDR", "P")] + [os.path.join(D, "%s.log" % g)]
    if not (os.path.exists(fi) and os.path.exists(fp)):
        print("%-10s MISSING program (refused or undecoded)" % g); continue
    i, p = load(fi), load(fp)
    log = open(fl).read() if os.path.exists(fl) else ""
    m = re.search(r"frame 0:.*?n32:(\d+) n33:(\d+) n34:(\d+)", log); hdr = sum(map(int, m.groups())) if m else 0
    W, H = map(int, g.split("x")); data[g] = (W, H, i, p, hdr)
print("== H.264 laws re-checked against the HEVC programs ==")
allbad = {}
for g, (W, H, i, p, hdr) in data.items():
    L = h264laws(W, H, hdr); bad = []
    def chk(name, want, got):
        if want != got: bad.append(name); 
    chk("sw5(I)", L[5] | (i[5] & 0xff), i[5]); chk("sw5(P)", L[5] | (p[5] & 0xff), p[5])
    chk("sw9(I)=2WH+0x10000-hdr", L[9], i[9]); chk("sw9(P)=2WH+0x10000", 2*W*H+0x10000, p[9])
    for r in (38, 134, 210, 212, 213, 237, 245, 246, 261): chk("sw%d" % r, L[r], i[r])
    chk("sw13-12=2WH", 2*W*H, i[13]-i[12]); chk("sw14-13=WH", W*H, i[14]-i[13])
    chk("lupitch", L['lupitch'], p[15]-i[15]); chk("chpitch", L['chpitch'], p[16]-i[16])
    chk("s72pitch", L['lupitch'], p[72]-i[72]); chk("sw15-sw46=0x12000", 0x12000, i[15]-i[46])
    chk("s62off", L['s62off'], i[62]-i[60])
    chk("s239sz", L['s239sz'], abs(i[241]-i[239]) if i.get(239) and i.get(241) else -1)
    chk("s114sz", L['s114sz'], abs(p[114]-i[114]))
    for b in bad: allbad.setdefault(b, []).append(g)
    print("%-10s hdr=%2d sw7=0x%08x sw105=%d  %s" % (g, hdr, i[7], i[105], ("FAILS: " + " ".join(bad)) if bad else "all H.264 laws hold"))
print("\nlaw -> geometries where it fails:")
for b, gs in allbad.items(): print("  %-22s %d/%d  %s" % (b, len(gs), len(data), " ".join(gs)))
print("\n== geometry-varying non-address registers (IDR) ==")
regs = sorted({r for g in data for r in data[g][2]})
var_i = [r for r in regs if r not in ADDR and len({data[g][2].get(r) for g in data}) > 1]
var_p = [r for r in regs if r not in ADDR and len({data[g][3].get(r) for g in data}) > 1]
print("IDR varying:", " ".join("sw%d" % r for r in var_i))
print("P   varying:", " ".join("sw%d" % r for r in var_p))
hdrrow = "%-10s %5s %5s %4s %4s " % ("geom", "W", "H", "ctbw", "ctbh")
for r in var_i: hdrrow += " sw%-8d" % r
print(hdrrow)
for g, (W, H, i, p, hdr) in data.items():
    row = "%-10s %5d %5d %4d %4d " % (g, W, H, (W+63)//64, (H+63)//64)
    for r in var_i: row += " 0x%08x" % i.get(r, 0)
    print(row)
print("\n== P-only extra varying regs ==")
extra = [r for r in var_p if r not in var_i]
if extra:
    print("%-10s " % "geom" + "".join(" sw%-8d" % r for r in extra))
    for g, (W, H, i, p, hdr) in data.items(): print("%-10s " % g + "".join(" 0x%08x" % p.get(r, 0) for r in extra))
print("\n== buffer deltas (IDR/P address arithmetic) ==")
print("%-10s %10s %10s %10s %10s %10s %10s %10s %10s" % ("geom", "13-12", "14-13", "lu(15P-I)", "ch(16P-I)", "72P-I", "62-60", "|241-239|", "114P-I"))
for g, (W, H, i, p, hdr) in data.items():
    print("%-10s %10x %10x %10x %10x %10x %10x %10x %10x" % (g, i[13]-i[12], i[14]-i[13], p[15]-i[15], p[16]-i[16], p[72]-i[72], i[62]-i[60], abs(i.get(241,0)-i.get(239,0)), abs(p[114]-i[114])))
