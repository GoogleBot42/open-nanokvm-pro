import re, os, glob, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmdpool_decode import load_pool
ADDR = {8,10,12,13,14,15,16,18,19,27,46,60,62,64,66,72,74,114,239,241}
def load(fn):
    d = {}
    for l in open(fn):
        m = re.match(r"swreg(\d+)\s+0x([0-9a-f]+)", l)
        if m: d[int(m.group(1))] = int(m.group(2), 16)
    return d
def pool(d, tag, ph):
    fs = glob.glob(os.path.join(d, "cmdpool_%s_%s_0x*.bin" % (tag, ph)))
    return load_pool(fs[0]) if fs else None
def fresh_between(prev, cur):
    """slots (>=400 regs) in cur that differ from prev; returns [(idx, prog)]"""
    out = []
    for i, p in enumerate(cur):
        if len(p) < 400: continue
        if i >= len(prev) or prev[i] != p: out.append((i, p))
    return out
def per_frame_programs(d, tag, n):
    """for snapall runs: frame k program = slot changed between f(k-1) and f(k)"""
    res = []; prev = pool(d, tag, "pre")
    for k in range(n):
        cur = pool(d, tag, "f%03d" % k)
        if cur is None: break
        ch = fresh_between(prev, cur)
        res.append(ch); prev = cur
    return res
MARK = 0x90101010
def mirrors(d, tag, ph):
    """find swreg mirror images (marker 0x90101010) in ALL venc_ko dumps of a snapshot; return list of (file, off, words[0:512])"""
    out = []
    for fn in sorted(glob.glob(os.path.join(d, "*_%s_%s_0x*.bin" % (tag, ph)))):
        data = open(fn, "rb").read()
        base = int(fn.rsplit("_0x", 1)[1][:8], 16)
        i = 0
        while True:
            j = data.find(struct.pack("<I", MARK), i)
            if j < 0: break
            if j % 4 == 0:
                n = min(512, (len(data) - j) // 4)
                out.append((os.path.basename(fn), base + j, list(struct.unpack_from("<%dI" % n, data, j))))
            i = j + 4
    return out
def nal_sizes(logfn):
    fr = []
    for l in open(logfn):
        m = re.match(r"frame (\d+): send=0x(\w+) get=0x(\w+) len=(\d+) coding=(\d+).*nalus=(\d+)(.*)", l)
        if m: fr.append(dict(i=int(m.group(1)), len=int(m.group(4)), coding=int(m.group(5)), nalus=m.group(7).strip()))
    return fr
def regtable(progs, labels, exclude=ADDR, only=None, fn=None):
    """markdown table of registers that differ across progs"""
    regs = sorted(set().union(*[set(p) for p in progs]))
    lines = ["| swreg | " + " | ".join(labels) + " |", "|---|" + "---|"*len(labels)]
    n = 0
    for r in regs:
        if r in exclude: continue
        if only is not None and r not in only: continue
        vals = [p.get(r) for p in progs]
        if len(set(vals)) > 1:
            lines.append("| sw%d | " % r + " | ".join("0x%08x" % v if v is not None else "-" for v in vals) + " |"); n += 1
    s = "\n".join(lines)
    if fn: open(fn, "w").write(s + "\n")
    return n, s
