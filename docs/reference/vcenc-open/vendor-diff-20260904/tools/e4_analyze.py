import sys, os, glob, re, struct
T = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, T)
from analib import *
import h264parse
E4 = sys.argv[1]
runs = []
for l in open(E4 + "/batch.log"):
    m = re.match(r"=== (\S+): ?(.*)", l)
    if m: runs.append((m.group(1), m.group(2).strip()))
base_i = load(E4 + "/vendor_base_IDR.txt"); base_p = load(E4 + "/vendor_base_P.txt")
OP = {1,3,4,6,22,26,35,36,38,39,40,41,45,81,134,136,170,171,172,173,182,193,194,195,196,201,203,224,225}|set(range(245,260))|{272,277,281,288,289,307,319,320,349,430}
moves = {}
def sec(tag, ph):
    fs = glob.glob(E4 + "/cmdpool_%s_%s_0x*.bin" % (tag, ph))
    if not fs: return None
    d = open(fs[0], "rb").read(); w = struct.unpack_from("<%dI" % (0x2000//4), d, 0x2000)
    return w[516:552]
print("== E4 single-knob sweep (1080p CBR8000 fps60 gop30 main 5.1 baseline). Per run: create rc, NAL sizes, SPS/PPS facts, regs moved vs base (* = generator 'opaque') ==")
for tag, args in runs:
    fi = E4 + "/vendor_%s_IDR.txt" % tag; fp = E4 + "/vendor_%s_P.txt" % tag
    log = open(E4 + "/%s.log" % tag).read()
    cr = re.search(r"CreateChn\(7\) rc=0x(\w+)", log); extra = re.findall(r"(Set\w+\([^)]*\) rc=0x\w+)", log)
    fr = nal_sizes(E4 + "/%s.log" % tag)
    if not os.path.exists(fi):
        print("-- %-12s %-40s CREATE rc=%s  (no program)" % (tag, args, cr.group(1) if cr else "?")); continue
    i = load(fi); p = load(fp) if os.path.exists(fp) else {}
    h264parse.SPS.clear(); h264parse.PPS.clear(); sl = []; sp = pp = ""
    for n in h264parse.nals(open(E4 + "/%s.h264" % tag, "rb").read()):
        t = n[0] & 0x1f
        if t == 7: sp = h264parse.sps(n)
        elif t == 8: pp = h264parse.pps(n)
        elif t in (1, 5): sl.append(h264parse.slc(n))
    di = [(r, base_i.get(r), i.get(r)) for r in sorted(set(base_i)|set(i)) if base_i.get(r) != i.get(r) and r not in ADDR]
    dp = [(r, base_p.get(r), p.get(r)) for r in sorted(set(base_p)|set(p)) if base_p.get(r) != p.get(r) and r not in ADDR] if p else []
    sizes = " ".join("f%d:%s%d" % (f['i'], "I" if f['coding']==0 else "P", f['len']) for f in fr[:6])
    print("-- %-12s %-40s rc=%s %s" % (tag, args, cr.group(1) if cr else "?", " ".join(extra)))
    print("   sizes: %s | %s | %s" % (sizes, re.sub(r"mbs=\S+ ", "", sp), pp.replace("chroma_qp_off=0 ", "")))
    print("   slices: %s" % "; ".join(s.replace("slice first_mb=0 ", "") for s in sl[:3]))
    print("   IDR moved: %s" % (", ".join("sw%d %s->%s%s" % (r, hex(a) if a is not None else "-", hex(b) if b is not None else "-", "*" if r in OP else "") for r, a, b in di) or "none"))
    print("   P   moved: %s" % ((", ".join("sw%d %s->%s%s" % (r, hex(a) if a is not None else "-", hex(b) if b is not None else "-", "*" if r in OP else "") for r, a, b in dp) or "none") if p else "(no P frame in run)"))
    for r, a, b in di: moves.setdefault(r, []).append((tag, "I"))
    for r, a, b in dp: moves.setdefault(r, []).append((tag, "P"))
    sb, st = sec("base", "IDR"), sec(tag, "IDR")
    if sb and st and sb != st: print("   SECONDARY-BANK pokes differ from base (slot1 words 516..551): %s" % [hex(x) for x in st])
print("\n== which knob moves swregN (every register that moved in ANY run; * = generator 'opaque') ==")
allregs = sorted(set(base_i)|set(base_p))
never = [r for r in allregs if r not in moves and r not in ADDR]
for r in sorted(moves):
    print("sw%-4d%s: %s" % (r, "*" if r in OP else " ", ", ".join("%s(%s)" % k for k in moves[r])))
print("\nregisters NEVER moved by any knob (excluding %d addr regs): %d of %d -> %s" % (len(ADDR), len(never), len(allregs), " ".join("sw%d" % r for r in never)))
print("opaque regs never moved:", " ".join("sw%d" % r for r in sorted(OP) if r in never))
print("opaque regs moved:", " ".join("sw%d" % r for r in sorted(OP) if r in moves))
print("secondary-bank base pokes (slot1 words 516..551):", [hex(x) for x in sec("base", "IDR")])
