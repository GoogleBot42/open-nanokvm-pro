#!/usr/bin/env python3
"""h78_analyze.py <root>: H7 live core window vs the HEVC program; H8 CBR trajectories."""
import sys, os, re, struct, subprocess
T = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, T)
from analib import load, nal_sizes, ADDR
D = sys.argv[1]
print("== H7 live encoder-core window (READ-ONLY MMIO 0x04010000+0x1000 during a 900-frame HEVC encode) ==")
print(open(D + "/H7/regpoll.log").read().strip())
f = D + "/H7/live512.bin"
if os.path.exists(f):
    ww = struct.unpack("<512I", open(f, "rb").read())
    print("  sw80=%08x sw214=%08x sw226=%08x sw287=%08x sw509..511=%08x %08x %08x sw191=%08x sw5=%08x" % (ww[80], ww[214], ww[226], ww[287], ww[509], ww[510], ww[511], ww[191], ww[5]))
    c = ww[80]; print("  fuse sw80: bit31 H264=%d bit27 HEVC=%d bit15 JPEG=%d" % (c>>31&1, c>>27&1, c>>15&1))
    pi = load(D + "/H1/vendor_h1_base_IDR.txt"); pp = load(D + "/H1/vendor_h1_base_P.txt")
    prog = pp if (ww[5] & 0xff) == 1 else pi
    same = sum(1 for r in prog if ww[r] == prog[r]); print("  live vs 1080p HEVC %s program: %d/%d identical" % ("P" if prog is pp else "IDR", same, len(prog)))
    diff = [r for r in range(1, 512) if r in prog and ww[r] != prog[r] and r not in ADDR]
    print("  non-addr regs differing (live/program): %s" % " ".join("sw%d(%08x/%08x)" % (r, ww[r], prog[r]) for r in diff))
    s = open(D + "/H7/live512.bin.samples").read().splitlines()
    print("  %d samples; registers that VARY across samples: %s" % (len(s), " ".join("sw%d" % r for r in range(512) if len({l.split()[2+r] for l in s}) > 1)))
    zero = [r for r in range(1, 400) if r in prog and prog[r] != 0 and all(int(l.split()[2+r], 16) == 0 for l in s)]
    print("  write-only candidates (program nonzero, always read 0): %s" % " ".join("sw%d" % r for r in zero))
print("\n== H8 CBR trajectories (moving card, 90 frames, 1080p fps60 gop30) ==")
for br in (2000, 8000, 16000):
    tag = "traj%d" % br
    fr = nal_sizes(D + "/H8/%s.log" % tag)
    out = subprocess.run([sys.executable, os.path.join(T, "h265parse.py"), D + "/H8/%s.h265" % tag], capture_output=True, text=True).stdout
    qps = re.findall(r"type=(\w)\(\d\).*?qp=(\d+)", out)
    tot = sum(f['len'] for f in fr)
    print("-- %s: %d frames, %d bytes = %.0f kbps (target %d); I at %s" % (tag, len(fr), tot, tot*8*60/len(fr)/1000, br, [f['i'] for f in fr if f['coding']==0]))
    print("   " + " ".join("%d:%s%d/q%s" % (f['i'], q[0], f['len'], q[1]) for f, q in zip(fr, qps)))
    with open(D + "/H8/%s_trajectory.csv" % tag, "w") as o:
        o.write("frame,type,bytes,slice_qp\n")
        for f, q in zip(fr, qps): o.write("%d,%s,%d,%s\n" % (f['i'], q[0], f['len'], q[1]))
