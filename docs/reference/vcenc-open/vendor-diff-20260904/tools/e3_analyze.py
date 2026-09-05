#!/usr/bin/env python3
"""Compare vendor programs (geom-probe format) against the vcenc_geom.h laws."""
import re, sys, os, glob
D = sys.argv[1]
def load(fn):
    d = {}
    for l in open(fn):
        m = re.match(r"swreg(\d+)\s+0x([0-9a-f]+)", l)
        if m: d[int(m.group(1))] = int(m.group(2), 16)
    return d
def al(v, a): return (v + a - 1) // a * a
def laws(W, H, hdr=40):
    mbw, mbh = (W+15)//16, (H+15)//16
    w4 = al(mbw, 4); wp = w4*16; hp = al(H, 64); mbhp = hp//16; p4 = w4*4
    g = {}
    g[5] = ((mbw*16//2) << 20) | ((mbh*16+3) << 8)     # + frame-type bits
    g[9] = 2*W*H + 0x10000 - hdr
    g[38] = 0x20000000 | (W*64 + ((16-W%16)%8)*8 + ((16-H%16)%8)*2)
    g[134] = 0x0a000000 | (0x10000000 // (wp*hp))
    g['193_idr'] = 0x0010010d | (0x40 if mbw*16-W >= 8 else 0) | (0x10 if mbh*16-H >= 8 else 0)
    g['193_p'] = 0x00200109 | (0x40 if mbw*16-W >= 8 else 0) | (0x10 if mbh*16-H >= 8 else 0)
    g[210] = ((W//16) << 16) | ((W%16) << 12) | 0xff8
    g[212] = (p4 << 16) | 0x0ff8
    g[213] = (p4 << 16) | 0x3fe0
    g[237] = (p4 << 16) | 0x0044
    g[245] = 0x20000000 | (((2*0x10000//mbw + 1)//2)*4)
    g[246] = (((2*0x40000//mbw + 1)//2) << 14) | 0x1028
    g[261] = ((mbw*16) << 16) | 0x0400
    g['tps'] = 1760000*W*H//(1920*1080)
    g['lupitch'] = wp*hp + al(w4*mbhp*16, 4096)
    g['chpitch'] = al(wp*hp//2, 4096)
    g['s60sz'] = al(w4*mbhp*4, 4096)
    g['s239sz'] = al(w4*mbhp, 4096)
    g['s114sz'] = al(mbhp*64, 4096)
    g['s62off'] = al(w4*mbhp//2, 64)
    g['s10sz'] = al(W*H//8, 4096)
    return g
GEOMS = ["1920x1080","1920x1440","2048x1080","2560x1080","2560x1440","3200x1800","3440x1440","3840x2160","3840x2400"]
ADDR = {8,9,10,12,13,14,15,16,27,46,60,62,72,114,239,241}
GEOMREG = {2,5,9,38,134,193,210,212,213,237,245,246,261}
RCREG = {7,37,105,106,107}|set(range(125,133))
base_i = load(os.path.join(D, "vendor_1920x1080_IDR.txt")); base_p = load(os.path.join(D, "vendor_1920x1080_P.txt"))
rows = []
print("== geometry-law check (vendor vs vcenc_geom.h prediction) ==")
for g in GEOMS:
    W, H = map(int, g.split("x"))
    i = load(os.path.join(D, "vendor_%s_IDR.txt" % g)); p = load(os.path.join(D, "vendor_%s_P.txt" % g))
    log = open(os.path.join(D, "%s.log" % g)).read()
    m = re.search(r"frame 0:.*n7:(\d+) n8:(\d+)", log); hdr = int(m.group(1))+int(m.group(2)) if m else 40
    L = laws(W, H, hdr)
    bad = []
    def chk(name, want, got):
        if want != got: bad.append("%s want=0x%x got=0x%x" % (name, want, got))
    chk("sw5(I)", L[5] | (i[5] & 0xff), i[5]); chk("sw5(P)", L[5] | (p[5] & 0xff), p[5])
    chk("sw9(I)", L[9], i[9]); chk("sw9(P)=2WH+0x10000", 2*W*H+0x10000, p[9])
    for r in (38, 134, 210, 212, 213, 237, 245, 246, 261): chk("sw%d" % r, L[r], i[r]); chk("sw%d(P)" % r, L[r], p[r])
    chk("sw193(I)", L['193_idr'], i[193]); chk("sw193(P)", L['193_p'], p[193])
    chk("sw2", 0xf0, i[2])
    chk("sw13-12=2WH", 2*W*H, i[13]-i[12]); chk("sw14-13=WH", W*H, i[14]-i[13])
    chk("lupitch(sw15 P-I)", L['lupitch'], p[15]-i[15]); chk("chpitch(sw16 P-I)", L['chpitch'], p[16]-i[16])
    chk("s72pitch==lupitch", L['lupitch'], p[72]-i[72]); chk("sw15-sw46=0x12000", 0x12000, i[15]-i[46])
    chk("sw62-sw60=s62off", L['s62off'], i[62]-i[60])
    s239 = abs(i[241]-i[239]); s60 = abs(p[60]-i[60]); s114 = abs(p[114]-i[114]) if p[114]!=i[114] else 0
    print("%-10s hdr=%d tps(sw105)=%d pred=%d sw7=0x%08x  |s239|=0x%x (law 0x%x) |s60 P-I|=0x%x (bound 0x%x) s114 P-I=0x%x (bound 0x%x)" % (
        g, hdr, i[105], L['tps'], i[7], s239, L['s239sz'], s60, L['s60sz'], s114, L['s114sz']))
    for b in bad: print("   MISMATCH", b)
    if not bad: print("   all geometry laws OK")
    # non-geometry, non-addr registers that differ from the 1080p baseline
    dif = [(r, base_i.get(r), i.get(r)) for r in sorted(set(base_i)|set(i)) if base_i.get(r)!=i.get(r) and r not in ADDR and r not in GEOMREG]
    difp = [(r, base_p.get(r), p.get(r)) for r in sorted(set(base_p)|set(p)) if base_p.get(r)!=p.get(r) and r not in ADDR and r not in GEOMREG]
    print("   IDR non-geom/non-addr regs differing from 1080p:", ", ".join("sw%d %s->%s%s" % (r, hex(a), hex(b), "[RC]" if r in RCREG else "") for r, a, b in dif) or "none")
    print("   P   non-geom/non-addr regs differing from 1080p:", ", ".join("sw%d %s->%s%s" % (r, hex(a), hex(b), "[RC]" if r in RCREG else "") for r, a, b in difp) or "none")
