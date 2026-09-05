#!/usr/bin/env python3
"""rc_report.py <campaign-dir>  -- aggregate the per-run *_trajectory.csv files of the
real-content RC campaign into the tables REPORT.md quotes (achieved kbps, I-frame QP
rule, first-P offset, P-step histogram, response to the mid-stream changes) and
recompute one trajectory from its raw log + bitstream when asked:
  rc_report.py <campaign-dir> --recompute <phase>/<tag>   (needs the .h264/.h265 + .log;
  those are not committed, so run it against the device copy or the scratchpad)."""
import sys, os, csv, glob, re

def load(fn):
    rows = list(csv.DictReader(open(fn)))
    for r in rows:
        for k in ("frame", "bytes", "slice_bytes", "slice_qp", "srcf", "off", "br_kbps", "sw7_initqp", "sw7_frameqp"):
            r[k] = int(r[k])
    return rows

def kbps(rows, fps=60):
    return sum(r["bytes"] for r in rows) * 8 * fps / len(rows) / 1000 if rows else 0

def steps(rows):
    h = {}
    for a, b in zip(rows, rows[1:]):
        if a["type"] != "I" and b["type"] != "I":
            d = b["slice_qp"] - a["slice_qp"]; h[d] = h.get(d, 0) + 1
    return h

def gop_of(rows, gop=30):
    g = {}
    for r in rows: g.setdefault(r["frame"] // gop, []).append(r)
    return g

def table(d, phases):
    out = []
    for ph in phases:
        for fn in sorted(glob.glob(os.path.join(d, ph, "*_trajectory.csv"))):
            tag = os.path.basename(fn).replace("_trajectory.csv", "")
            rows = load(fn)
            I = [r for r in rows if r["type"] == "I"]; P = [r for r in rows if r["type"] != "I"]
            fp = [rows[k + 1] for k, r in enumerate(rows[:-1]) if r["type"] == "I" and rows[k + 1]["type"] != "I"]
            gops = gop_of(rows)
            st = steps(rows)
            out.append("| %s/%s | %d | %.0f | %s | %s | %s | %d..%d | %s | %s |" % (
                ph, tag, len(rows), kbps(rows),
                " ".join(str(r["slice_qp"]) for r in I),
                " ".join(str(r["slice_qp"]) for r in fp),
                " ".join("%.0f" % kbps(gops[g]) for g in sorted(gops)),
                min(r["slice_qp"] for r in P), max(r["slice_qp"] for r in P),
                " ".join("%+d:%d" % (k, st[k]) for k in sorted(st)),
                "%d/%d" % (sum(1 for r in rows if r["sw7_frameqp"] == r["slice_qp"] and r["slot"] != "-"), len(rows))))
    return out

def change_view(d, fn, changes):
    rows = load(fn); out = []
    bounds = [0] + changes + [len(rows)]
    for a, b in zip(bounds, bounds[1:]):
        seg = rows[a:b]
        out.append("  frames %d..%d target %d: %.0f kbps, QP first %d last %d min %d max %d" % (
            a, b - 1, seg[0]["br_kbps"], kbps(seg), seg[0]["slice_qp"], seg[-1]["slice_qp"], min(r["slice_qp"] for r in seg), max(r["slice_qp"] for r in seg)))
    for c in changes:
        out.append("  at %d: " % c + " ".join("%d:%s%d/q%d" % (r["frame"], r["type"], r["bytes"], r["slice_qp"]) for r in rows[c - 3:c + 12]))
        # sw105-107 around the change
        out.append("        sw105/106/107: " + " ".join("%d:%s/%s/%s" % (r["frame"], r["sw105"][2:].lstrip("0") or "0", r["sw106"][2:].lstrip("0") or "0", r["sw107"][2:].lstrip("0") or "0") for r in rows[c - 2:c + 4]))
    return out

if __name__ == "__main__":
    d = sys.argv[1]
    print("| run | frames | kbps | I QPs | first-P QPs | kbps per GOP | P QP range | P->P step histogram | sw7==slice |")
    print("|---|---|---|---|---|---|---|---|---|")
    for l in table(d, ["R1", "R2", "R4", "R5", "R6", "R3"]): print(l)
    for fn in sorted(glob.glob(os.path.join(d, "R3", "*_trajectory.csv"))):
        tag = os.path.basename(fn).replace("_trajectory.csv", "")
        ch = [75, 165] if "mid" in tag else [60, 120]
        print("\n%s (changes at %s):" % (tag, ch)); print("\n".join(change_view(d, fn, ch)))
