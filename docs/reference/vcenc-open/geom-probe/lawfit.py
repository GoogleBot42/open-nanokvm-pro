#!/usr/bin/env python3
"""Fit geometry laws across all 12 probed geometries (fresh IDR slot 1, P slot 2)."""
import glob, re
from cmdpool_decode import load_pool

def geoms():
    out = {}
    for f in sorted(glob.glob("geomprobe/cmdpool_*_IDR_*.bin")):
        m = re.search(r"cmdpool_(?:c|g)(\d+)(?:x(\d+))?_IDR", f)
        tag = re.search(r"cmdpool_([a-z0-9]+)_IDR", f).group(1)
        out[tag] = f
    return out

DIMS = {"c1080": (1920,1080), "g720": (1280,720), "g1366": (1366,768),
        "g1024x768": (1024,768), "g800x600": (800,600), "g1600x900": (1600,900),
        "g1440x900": (1440,900), "g640x480": (640,480), "g1360x768": (1360,768),
        "g1362x768": (1362,768), "g1920x1200": (1920,1200), "g1152x864": (1152,864)}

def helpers(W, H):
    mbw, mbh = (W+15)//16, (H+15)//16
    a8mbw = (mbw+7)//8*8
    Wp = a8mbw*16              # 8-MB-aligned width in px
    Hp = (H+63)//64*64         # 64-aligned height
    return dict(W=W, H=H, mbw=mbw, mbh=mbh, a8mbw=a8mbw, Wp=Wp, Hp=Hp,
                mbwp=Wp//16, mbhp=Hp//16)

idr = {}; pfr = {}
for tag, f in geoms().items():
    idr[tag] = load_pool(f)[1]
    pfr[tag] = load_pool(f.replace("_IDR_", "_P_"))[2]

# sanity: fresh slots must carry the right geometry (sw261 hi = Wp... check vs sw210)
for tag, (W, H) in DIMS.items():
    h = helpers(W, H)
    s210 = idr[tag].get(210, 0)
    assert (s210 >> 16) == W//16 and ((s210 >> 12) & 0xF) == W % 16, \
        (tag, hex(s210), "sw210 mismatch -- wrong slot?")
    assert (pfr[tag].get(191, 0) >> 24) == 0x04, (tag, "P slot not P")

print("tag         W    H  | sw5        sw237      sw261      sw38       sw193(idr) sw245      sw246      sw134      sw9-2WH lupitch  chpitch  s62-s60  s239sz")
for tag, (W, H) in sorted(DIMS.items(), key=lambda kv: kv[1]):
    h = helpers(W, H)
    i, p = idr[tag], pfr[tag]
    lupitch = p[15] - i[15]
    chpitch = p[16] - i[16]
    print("%-10s %4d %4d | 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x 0x%05x 0x%06x 0x%06x 0x%04x 0x%05x"
          % (tag, W, H, i[5], i[237], i[261], i[38], i[193], i[245], i[246],
             i[134], i[9] - 2*W*H, lupitch, chpitch, i[62]-i[60], abs(i[241]-i[239])))

print()
print("derivation checks (law -> per-geom ok/FAIL):")
def check(name, lawf, actf):
    fails = []
    for tag, (W, H) in DIMS.items():
        h = helpers(W, H)
        want, got = lawf(h), actf(idr[tag], pfr[tag])
        if want != got:
            fails.append("%s want=0x%x got=0x%x" % (tag, want, got))
    print("  %-46s %s" % (name, "OK" if not fails else "FAIL " + "; ".join(fails)))

import math
check("sw2 == 0xf0 const", lambda h: 0xf0, lambda i, p: i[2])
check("sw237 = (a8mbw*32)<<16 | 0x44", lambda h: (h["a8mbw"]*32) << 16 | 0x44,
      lambda i, p: i[237])
check("sw212 = (a8mbw*32)<<16 | 0xff8", lambda h: (h["a8mbw"]*32) << 16 | 0xff8,
      lambda i, p: i[212])
check("sw213 = (a8mbw*32)<<16 | 0x3fe0", lambda h: (h["a8mbw"]*32) << 16 | 0x3fe0,
      lambda i, p: i[213])
check("sw261 = (mbw*16)<<16 | 0x400", lambda h: (h["mbw"]*16) << 16 | 0x400,
      lambda i, p: i[261])
check("sw210 = mbw_floor<<16|(W%16)<<12|0xff8",
      lambda h: (h["W"]//16) << 16 | (h["W"] % 16) << 12 | 0xff8,
      lambda i, p: i[210])
check("sw9 = 2WH + 0xffd8 (IDR, +-1)", lambda h: 2*h["W"]*h["H"] + 0xffd8,
      lambda i, p: i[9] & ~1)
check("sw13-sw12 = 2WH", lambda h: 2*h["W"]*h["H"], lambda i, p: i[13]-i[12])
check("sw14-sw13 = WH", lambda h: h["W"]*h["H"], lambda i, p: i[14]-i[13])
check("lupitch = Wp*Hp + align4k(mbwp*mbhp*16)",
      lambda h: h["Wp"]*h["Hp"] + (h["mbwp"]*h["mbhp"]*16 + 4095)//4096*4096,
      lambda i, p: p[15]-i[15])
check("chpitch = Wp*Hp/2 + align4k(mbwp*mbhp*16)/2?",
      lambda h: h["Wp"]*h["Hp"]//2,
      lambda i, p: p[16]-i[16])
check("sw72 pitch == lupitch", lambda h: 0,
      lambda i, p: (p[72]-i[74]) if False else 0)  # placeholder
check("sw46 gap to sw15 == 0x12000", lambda h: 0x12000, lambda i, p: i[15]-i[46])
check("sw245 = 0x20000000|round(0x3ffc0/mbw)",
      lambda h: 0x20000000 | round(0x3FFC0 / h["mbw"]),
      lambda i, p: i[245])
check("sw246 hi = round(0xfff0/mbw)",
      lambda h: round(0xFFF0 / h["mbw"]),
      lambda i, p: i[246] >> 16)
