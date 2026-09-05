#!/usr/bin/env python3
"""rc_traj.py <rundir> <tag> <W> <H> --codec h264|h265 [--rm-pools]

Per-frame RC trajectory of one vdrive run (real-content RC campaign, 2026-09-05).
Columns of <tag>_trajectory.csv:
  frame, type (I/P from the bitstream), bytes (AX_VENC pack length from the log;
  the IDR pack includes the parameter sets), slice_bytes (VCL NAL size),
  slice_qp (parsed from the slice header), srcf / off / br_kbps (source frame,
  motion offset and target bitrate the frame was sent with, from the log),
  slot (cmdbuf slot the frame's program was found in; "-" = no fresh slot),
  sw7 sw7_initqp sw7_frameqp sw105 sw106 sw107 sw172 sw173 sw243 sw244 sw247
  sw6 sw22 sw11 (the frame's programmed register values, hex).
The fresh slot is the >=400-register slot that CHANGED between consecutive
per-frame pool snapshots (vdrive snapall=2); when two changed, the one whose
sw5[7:0] frame type matches the log's coding type wins and the row is flagged.
<tag>_summary.txt carries the derived numbers (achieved kbps per GOP / per
segment, I-frame QPs, P-QP step histogram, register-vs-bitstream QP check).
Parsers come from the sibling campaigns unchanged (cmdpool_decode.py +
h265parse.py from ../vendor-diff-hevc-20260905/tools, h264parse.py from
../vendor-diff-20260904/tools); set VCTOOLS to a directory holding all three
when running elsewhere (on the device: /root/rc65/tools)."""
import sys, os, re, glob
HERE = os.path.dirname(os.path.abspath(__file__))
if os.environ.get("VCTOOLS"): sys.path.insert(0, os.environ["VCTOOLS"])
for sib in ("vendor-diff-hevc-20260905", "vendor-diff-20260904"):
    sys.path.append(os.path.join(HERE, "..", "..", sib, "tools"))
from cmdpool_decode import load_pool          # noqa: E402
import h264parse, h265parse                    # noqa: E402

REGS = [5, 6, 7, 9, 11, 22, 105, 106, 107, 172, 173, 243, 244, 247]
OUTREGS = [7, 105, 106, 107, 172, 173, 243, 244, 247, 6, 22, 11]

def parse_log(fn):
    hdr, frames, src, chg = {}, [], {}, []
    for l in open(fn):
        m = re.match(r"# vdrive tag=(\S+) codec=(\S+) (\d+)x(\d+) rc=(\S+) br=(\d+) fps=(\d+)/(\d+) gop=(\d+)", l)
        if m:
            hdr = dict(tag=m.group(1), codec=m.group(2), w=int(m.group(3)), h=int(m.group(4)), rc=m.group(5),
                       br=int(m.group(6)), fps=int(m.group(7)), dfps=int(m.group(8)), gop=int(m.group(9)))
        m = re.match(r"src frame (\d+): srcf=(-?\d+) off=(-?\d+) br=(\d+)", l)
        if m: src[int(m.group(1))] = (int(m.group(2)), int(m.group(3)), int(m.group(4)))
        m = re.match(r"chg frame=(\d+) br (\d+) -> (\d+) kbps: GetRcParam=0x(\w+) SetRcParam=0x(\w+) readback=(\d+)", l)
        if m: chg.append(dict(frame=int(m.group(1)), before=int(m.group(2)), to=int(m.group(3)), g=m.group(4), s=m.group(5), rb=int(m.group(6))))
        m = re.match(r"frame (\d+): send=0x(\w+) get=0x(\w+) len=(\d+) coding=(\d+).*nalus=(\d+)(.*)", l)
        if m: frames.append(dict(i=int(m.group(1)), send=m.group(2), get=m.group(3), len=int(m.group(4)), coding=int(m.group(5)), nalus=m.group(7).strip()))
    return hdr, frames, src, chg

def parse_slices_h264(fn):
    out = []
    for n in h264parse.nals(open(fn, "rb").read()):
        t = n[0] & 0x1f
        if t == 7: h264parse.sps(n)
        elif t == 8: h264parse.pps(n)
        elif t in (1, 5):
            s = h264parse.slc(n)
            m = re.search(r"type=(\w+) frame_num=\d+ qp=(\d+)", s)
            if m: out.append(dict(type="I" if (t == 5 or m.group(1) == "I") else m.group(1), qp=int(m.group(2)), bytes=len(n), nal=t))
    return out

def parse_slices_h265(fn):
    out = []
    for n in h265parse.nals(open(fn, "rb").read()):
        s, d = h265parse.parse_nal(n)
        t = d["nal_unit_type"]
        if t <= 21 and "SliceQpY" in d:
            st = d.get("slice_type")
            out.append(dict(type={2: "I", 1: "P", 0: "B"}.get(st, "?") if t < 16 else "I", qp=d["SliceQpY"], bytes=len(n), nal=t))
    return out

def fresh_slots(prev, cur):
    return [(i, p) for i, p in enumerate(cur) if len(p) >= 400 and (i >= len(prev) or prev[i] != p)]

def main():
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    d, tag, W, H = a[0], a[1], int(a[2]), int(a[3])
    codec = "h265" if "--codec" in sys.argv and sys.argv[sys.argv.index("--codec") + 1] == "h265" else None
    hdr, frames, src, chg = parse_log(os.path.join(d, tag + ".log"))
    if codec is None: codec = hdr.get("codec", "h264")
    bs = os.path.join(d, "%s.%s" % (tag, codec))
    slices = parse_slices_h265(bs) if codec == "h265" else parse_slices_h264(bs)
    if len(slices) != len(frames):
        print("!! %s: %d slices in bitstream vs %d frames in log" % (tag, len(slices), len(frames)))
    # per-frame programs
    def pool(ph):
        fs = glob.glob(os.path.join(d, "cmdpool_%s_%s_0x*.bin" % (tag, ph)))
        return load_pool(fs[0]) if fs else None
    prev = pool("pre"); progs = {}; flags = {}
    for f in frames:
        cur = pool("f%03d" % f["i"])
        if cur is None or prev is None: continue
        ch = fresh_slots(prev, cur); prev = cur
        want = 3 if f["coding"] == 0 else 1
        if len(ch) == 1: progs[f["i"]] = ch[0]; flags[f["i"]] = ""
        elif len(ch) > 1:
            m = [c for c in ch if (c[1].get(5, 0) & 0xff) == want]
            progs[f["i"]] = (m or ch)[0]; flags[f["i"]] = "ambig%d" % len(ch)
        else: flags[f["i"]] = "nochange"
    rows = []
    fps = hdr.get("fps", 60)
    with open(os.path.join(d, tag + "_trajectory.csv"), "w") as o:
        o.write("frame,type,bytes,slice_bytes,slice_qp,srcf,off,br_kbps,slot,flag," + ",".join(
            ["sw7", "sw7_initqp", "sw7_frameqp"] + ["sw%d" % r for r in OUTREGS[1:]]) + "\n")
        for k, f in enumerate(frames):
            s = slices[k] if k < len(slices) else dict(type="?", qp=-1, bytes=0)
            sf, off, br = src.get(f["i"], (-1, 0, hdr.get("br", 0)))
            sp = progs.get(f["i"]); slot = sp[0] if sp else "-"; p = sp[1] if sp else {}
            sw7 = p.get(7, 0)
            regs = ["0x%08x" % sw7, str(sw7 >> 26), str((sw7 >> 8) & 0x3f)] + ["0x%08x" % p.get(r, 0) if p else "-" for r in OUTREGS[1:]]
            row = dict(i=f["i"], type=s["type"], bytes=f["len"], sbytes=s["bytes"], qp=s["qp"], srcf=sf, off=off, br=br, slot=slot, flag=flags.get(f["i"], "nopool"), p=p, sw7qp=(sw7 >> 8) & 0x3f)
            rows.append(row)
            o.write("%d,%s,%d,%d,%d,%d,%d,%d,%s,%s,%s\n" % (f["i"], s["type"], f["len"], s["bytes"], s["qp"], sf, off, br, slot, row["flag"], ",".join(regs)))
    # summary
    gop = hdr.get("gop", 30)
    with open(os.path.join(d, tag + "_summary.txt"), "w") as o:
        def pr(*x):
            s = " ".join(str(v) for v in x); print(s); o.write(s + "\n")
        n = len(rows); tot = sum(r["bytes"] for r in rows)
        pr("== %s: codec=%s rc=%s br=%d fps=%d gop=%d frames=%d total=%d B achieved=%.0f kbps" % (
            tag, codec, hdr.get("rc"), hdr.get("br", 0), fps, gop, n, tot, tot * 8 * fps / max(n, 1) / 1000))
        pr("I frames (frame:qp/bytes):", " ".join("%d:%d/%d" % (r["i"], r["qp"], r["bytes"]) for r in rows if r["type"] == "I"))
        pr("first P after each I (frame:qp):", " ".join("%d:%d" % (rows[k + 1]["i"], rows[k + 1]["qp"]) for k, r in enumerate(rows[:-1]) if r["type"] == "I" and rows[k + 1]["type"] != "I"))
        # per GOP
        gops = {}
        for r in rows: gops.setdefault(r["i"] // gop, []).append(r)
        pr("per-GOP: gop#: kbps I_qp P_qp[min..max] P_qp_last")
        for g in sorted(gops):
            rs = gops[g]; pq = [r["qp"] for r in rs if r["type"] != "I"]; iq = [r["qp"] for r in rs if r["type"] == "I"]
            pr("  %d: %.0f kbps I=%s P=[%s..%s] last=%s n=%d" % (g, sum(r["bytes"] for r in rs) * 8 * fps / len(rs) / 1000, iq, min(pq) if pq else "-", max(pq) if pq else "-", pq[-1] if pq else "-", len(rs)))
        # P->P step histogram (within GOP)
        hist = {}
        for k in range(1, n):
            if rows[k]["type"] != "I" and rows[k - 1]["type"] != "I":
                dq = rows[k]["qp"] - rows[k - 1]["qp"]; hist[dq] = hist.get(dq, 0) + 1
        pr("P->P QP step histogram:", " ".join("%+d:%d" % (k, hist[k]) for k in sorted(hist)))
        # I->first P step
        pr("I->firstP QP delta:", " ".join("%+d" % (rows[k + 1]["qp"] - r["qp"]) for k, r in enumerate(rows[:-1]) if r["type"] == "I" and rows[k + 1]["type"] != "I"))
        # register vs bitstream
        mism = [r["i"] for r in rows if r["p"] and r["sw7qp"] != r["qp"]]
        pr("sw7 frame-QP == slice QP: %d/%d frames with a program agree; mismatches at %s" % (len([r for r in rows if r["p"]]) - len(mism), len([r for r in rows if r["p"]]), mism[:20]))
        pr("slot flags:", {f: sum(1 for r in rows if r["flag"] == f) for f in set(r["flag"] for r in rows)})
        pr("sw105-107 distinct (I):", sorted({("0x%x" % r["p"].get(105, 0), "0x%x" % r["p"].get(106, 0), "0x%x" % r["p"].get(107, 0)) for r in rows if r["p"] and r["type"] == "I"}))
        pr("sw172/173 distinct:", sorted({("0x%x" % r["p"].get(172, 0), "0x%x" % r["p"].get(173, 0)) for r in rows if r["p"]}))
        pr("sw6 distinct (I / P):", sorted({"0x%x" % r["p"].get(6, 0) for r in rows if r["p"] and r["type"] == "I"}), sorted({"0x%x" % r["p"].get(6, 0) for r in rows if r["p"] and r["type"] != "I"}))
        if chg:
            pr("mid-stream changes:", chg)
            bounds = [0] + [c["frame"] for c in chg] + [n]
            for a_, b_ in zip(bounds, bounds[1:]):
                seg = rows[a_:b_]
                if seg: pr("  segment %d..%d: %.0f kbps, qp first=%d last=%d min=%d max=%d" % (a_, b_ - 1, sum(r["bytes"] for r in seg) * 8 * fps / len(seg) / 1000, seg[0]["qp"], seg[-1]["qp"], min(r["qp"] for r in seg), max(r["qp"] for r in seg)))
            for c in chg:
                pr("  around change at %d:" % c["frame"], " ".join("%d:%s%d/q%d" % (r["i"], r["type"], r["bytes"], r["qp"]) for r in rows[max(0, c["frame"] - 4):c["frame"] + 16]))
    if "--rm-pools" in sys.argv and progs:
        for f in glob.glob(os.path.join(d, "cmdpool_%s_*_0x*.bin" % tag)): os.remove(f)

if __name__ == "__main__":
    main()
