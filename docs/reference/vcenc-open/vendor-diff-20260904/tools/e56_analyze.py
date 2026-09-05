import sys, os, re, struct, glob
T = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, T)
from analib import *
import h264parse
D = sys.argv[1]
print("== E5 live encoder-core register window (READ from MMIO 0x04010000+0x1000 while a vendor encode ran) ==")
w = struct.unpack("<128I", open(D + "/E5/regs.bin", "rb").read())
print(open(D + "/E5/regpoll.log").read())
for k in range(0, 128, 8): print("  sw%-3d (+0x%03x): %s" % (k, 0x1000 + k*4, " ".join("%08x" % x for x in w[k:k+8])))
wide = D + "/E5/regs.bin.wide"
if os.path.exists(wide):
    ww = struct.unpack("<512I", open(wide, "rb").read())
    print("  wide window: sw80=%08x sw214=%08x sw226=%08x sw287=%08x sw0=%08x sw1=%08x sw82=%08x sw9=%08x sw191=%08x" % (ww[80], ww[214], ww[226], ww[287], ww[0], ww[1], ww[82], ww[9], ww[191]))
    dead = sum(1 for x in ww if x == 0xdeadbeef); print("  wide: %d/512 words read 0xdeadbeef" % dead)
    # compare live vs the E3 1080p vendor IDR program: which regs read back differently
    pi = load(D + "/E3/vendor_1920x1080_IDR.txt")
    same = sum(1 for r in pi if ww[r] == pi[r]); print("  live window vs 1080p IDR program: %d/%d registers identical (addresses differ per run)" % (same, len(pi)))
    diff = [r for r in range(1, 512) if r in pi and ww[r] != pi[r] and r not in ADDR]
    print("  non-addr regs differing (live readback vs program): %s" % " ".join("sw%d(%08x/%08x)" % (r, ww[r], pi[r]) for r in diff[:60]))
# samples: how did the live words evolve
s = open(D + "/E5/samples.txt").read().splitlines()
print("  %d live samples captured; sw80 across samples: %s" % (len(s), sorted(set(l.split()[2+80] for l in s))))
print("  sw82 (cycle counter) across samples:", sorted(set(l.split()[2+82] for l in s))[:10])
a = struct.unpack("<128I", open(D + "/E5/regs.bin", "rb").read())
c = a[80]
print("  fuse sw80=0x%08x: bit31 H264=%d bit27 HEVC=%d bit15 JPEG=%d ; raw sw214/226/287 in wide file above" % (c, c>>31&1, c>>27&1, c>>15&1))
print("\n== E6 CBR trajectory (moving synthetic card, 90 frames, 1080p fps60 gop30) ==")
for br in (2000, 8000, 16000):
    tag = "traj%d" % br
    fr = nal_sizes(D + "/E6/%s.log" % tag)
    h264parse.SPS.clear(); h264parse.PPS.clear(); qps = []
    for n in h264parse.nals(open(D + "/E6/%s.h264" % tag, "rb").read()):
        t = n[0] & 0x1f
        if t == 7: h264parse.sps(n)
        elif t == 8: h264parse.pps(n)
        elif t in (1, 5):
            m = re.search(r"type=(\w+) frame_num=(\d+) qp=(\d+)", h264parse.slc(n)); qps.append((m.group(1), int(m.group(3))))
    tot = sum(f['len'] for f in fr); 
    print("-- %s: %d frames, total %d bytes = %.0f kbps at 60fps (target %d); I frames at %s" % (tag, len(fr), tot, tot*8*60/len(fr)/1000, br, [f['i'] for f in fr if f['coding']==0]))
    line = []
    for f, q in zip(fr, qps): line.append("%d:%s%d/q%d" % (f['i'], q[0], f['len'], q[1]))
    print("   " + " ".join(line))
    with open(D + "/E6/%s_trajectory.csv" % tag, "w") as o:
        o.write("frame,type,bytes,slice_qp\n")
        for f, q in zip(fr, qps): o.write("%d,%s,%d,%d\n" % (f['i'], q[0], f['len'], q[1]))
