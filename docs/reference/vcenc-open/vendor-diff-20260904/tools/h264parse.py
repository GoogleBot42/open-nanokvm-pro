#!/usr/bin/env python3
"""h264parse.py file.h264 -> per-NAL: type,size; SPS/PPS fields; slice type + QP (pic_init_qp+slice_qp_delta), deblocking idc."""
import sys
class BR:
    def __init__(s, d): s.b = s._un(d); s.p = 0
    def _un(s, d):
        o = bytearray(); z = 0
        for x in d:
            if z >= 2 and x == 3: z = 0; continue
            o.append(x); z = z + 1 if x == 0 else 0
        return bytes(o)
    def u1(s):
        v = (s.b[s.p >> 3] >> (7 - (s.p & 7))) & 1; s.p += 1; return v
    def u(s, n):
        v = 0
        for _ in range(n): v = (v << 1) | s.u1()
        return v
    def ue(s):
        z = 0
        while s.u1() == 0: z += 1
        return (1 << z) - 1 + s.u(z) if z else 0
    def se(s):
        k = s.ue(); return (k + 1) // 2 if (k & 1) else -(k // 2)
SPS = {}; PPS = {}
def sps(n):
    r = BR(n[1:]); prof = r.u(8); cs = r.u(8); lvl = r.u(8); r.ue()
    if prof in (100,110,122,244,44,83,86,118,128,138,139,134,135):
        cf = r.ue()
        if cf == 3: r.u1()
        r.ue(); r.ue(); r.u1()
        if r.u1():
            for i in range(8 if cf != 3 else 12):
                if r.u1():
                    # skip scaling list
                    sz = 16 if i < 6 else 64; last = 8; nxt = 8
                    for j in range(sz):
                        if nxt: nxt = (last + r.se() + 256) % 256
                        last = last if nxt == 0 else nxt
    l2 = r.ue() + 4; pt = r.ue(); lsb = 0
    if pt == 0: lsb = r.ue() + 4
    elif pt == 1:
        r.u1(); r.se(); r.se(); k = r.ue()
        for _ in range(k): r.se()
    nref = r.ue(); r.u1(); wm = r.ue() + 1; hm = r.ue() + 1; fmo = r.u1()
    if not fmo: r.u1()
    d8 = r.u1(); crop = r.u1()
    SPS.update(prof=prof, cs=cs, lvl=lvl, log2_fn=l2, poc_type=pt, poc_lsb=lsb, fmof=fmo, nref=nref, wm=wm, hm=hm, d8=d8, crop=crop)
    return "SPS profile=%d cs=0x%02x level=%d mbs=%dx%d nref=%d poc_type=%d log2fn=%d direct8x8=%d crop=%d" % (prof, cs, lvl, wm, hm, nref, pt, l2, d8, crop)
def pps(n):
    r = BR(n[1:]); r.ue(); r.ue(); ent = r.u1(); bpof = r.u1(); ng = r.ue()
    if ng > 0: PPS.update(complex=True); return "PPS slice groups!"
    l0 = r.ue(); l1 = r.ue(); wp = r.u1(); wb = r.u(2); q = r.se() + 26; qs = r.se() + 26; cqo = r.se()
    dfc = r.u1(); cip = r.u1(); rpc = r.u1()
    PPS.update(ent=ent, bpof=bpof, pic_init_qp=q, dfc=dfc, rpc=rpc)
    return "PPS entropy=%s init_qp=%d qs=%d chroma_qp_off=%d deblock_ctrl_present=%d constrained_intra=%d redundant=%d wpred=%d/%d nref_l0=%d" % ("CABAC" if ent else "CAVLC", q, qs, cqo, dfc, cip, rpc, wp, wb, l0+1)
def slc(n):
    if 'log2_fn' not in SPS or 'pic_init_qp' not in PPS: return "slice (no ctx)"
    nt = n[0] & 0x1f; idr = nt == 5; nri = (n[0] >> 5) & 3
    r = BR(n[1:]); first = r.ue(); st = r.ue(); r.ue(); fn = r.u(SPS['log2_fn'])
    if not SPS['fmof']:
        if r.u1(): r.u1()
    if idr: r.ue()
    if SPS['poc_type'] == 0:
        r.u(SPS['poc_lsb'])
        if PPS['bpof']: r.se()
    if PPS.get('rpc'): r.ue()
    stm = st % 5
    if stm in (0, 3):
        if r.u1(): r.ue()
        if r.u1():
            while True:
                op = r.ue()
                if op == 3: break
                r.ue()
    if nri:
        if idr: r.u1(); r.u1()
        else:
            if r.u1():
                while True:
                    mop = r.ue()
                    if mop == 0: break
                    if mop in (1, 3): r.ue()
                    if mop == 2: r.ue()
                    if mop in (3, 6): r.ue()
                    if mop == 4: r.ue()
    if PPS['ent'] and stm not in (2, 4): r.ue()
    sqd = r.se(); ddi = -1
    if PPS.get('dfc'):
        ddi = r.ue()
    return "slice first_mb=%d type=%s frame_num=%d qp=%d dbk_idc=%d" % (first, {0:'P',1:'B',2:'I',3:'SP',4:'SI'}[stm], fn, PPS['pic_init_qp'] + sqd, ddi)
def nals(data):
    out = []; i = 0; n = len(data)
    starts = []
    j = 0
    while True:
        k = data.find(b"\x00\x00\x01", j)
        if k < 0: break
        starts.append(k + 3); j = k + 3
    for a, b in zip(starts, starts[1:] + [n]):
        e = b
        # strip trailing zero bytes belonging to next start code
        while e > a and data[e-1] == 0 and (b - e) < 3: e -= 1
        out.append(data[a:e])
    return out
if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    fr = -1
    for n in nals(data):
        t = n[0] & 0x1f
        if t == 7: print("  ", len(n), sps(n))
        elif t == 8: print("  ", len(n), pps(n))
        elif t in (1, 5):
            print("  ", len(n), "nal%d" % t, slc(n))
        else: print("  ", len(n), "nal%d" % t)
