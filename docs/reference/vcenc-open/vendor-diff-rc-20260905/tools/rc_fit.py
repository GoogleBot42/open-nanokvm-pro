#!/usr/bin/env python3
"""rc_fit.py <trajectory.csv> [...]  -- fit the two laws the open controller (#46) needs
from a real-content trajectory:
  (1) I-frame QP rule: the IDR QP of GOP g against the P-QP statistics of GOP g-1
      (mean / last / min) and the achieved-vs-target ratio of GOP g-1;
  (2) P-frame QP update: dQP(i) = QP(i) - QP(i-1) tabulated against the previous
      frame's bits relative to its programmed target (bits*8 / sw105(i-1)) and
      against the running GOP bit balance -- prints a threshold table so the
      step rule can be read off directly.
Also prints the per-frame target law: sw105(i) vs the remaining GOP budget."""
import sys, csv, statistics

def load(fn):
    rows = list(csv.DictReader(open(fn)))
    for r in rows:
        for k in ("frame", "bytes", "slice_bytes", "slice_qp", "br_kbps", "sw7_frameqp"): r[k] = int(r[k])
        for k in ("sw105", "sw106", "sw107", "sw243", "sw244", "sw247"): r[k] = int(r[k], 16) if r[k] != "-" else 0
    return rows

def fit(fn, fps=60, gop=30):
    rows = load(fn); print("\n#### %s" % fn)
    gops = {}
    for r in rows: gops.setdefault(r["frame"] // gop, []).append(r)
    # (1) I-frame QP vs previous GOP
    print("I-QP rule: gop I_qp | prevGOP: meanP lastP minP maxP  bits/target")
    for g in sorted(gops):
        I = [r for r in gops[g] if r["type"] == "I"]
        if not I: continue
        if g - 1 in gops:
            P = [r for r in gops[g - 1] if r["type"] != "I"]; q = [r["slice_qp"] for r in P]
            tgt = gops[g - 1][0]["br_kbps"] * 1000 * len(gops[g - 1]) / fps
            print("  %2d  I=%2d | %.1f %2d %2d %2d  %.2f" % (g, I[0]["slice_qp"], statistics.mean(q), q[-1], min(q), max(q), sum(r["bytes"] for r in gops[g - 1]) * 8 / tgt))
        else:
            print("  %2d  I=%2d | (first GOP; br=%d)" % (g, I[0]["slice_qp"], I[0]["br_kbps"]))
    # (2) P-step vs previous frame's bits/target
    print("P-step rule: ratio r = bits(i-1)*8 / sw105(i-1)  ->  dQP(i) histogram")
    bins = [(0, 0.5), (0.5, 0.7), (0.7, 0.85), (0.85, 0.95), (0.95, 1.05), (1.05, 1.15), (1.15, 1.3), (1.3, 1.5), (1.5, 2.0), (2.0, 99)]
    tab = {b: {} for b in bins}
    for a, b in zip(rows, rows[1:]):
        if a["type"] == "I" or b["type"] == "I" or not a["sw105"]: continue
        r = a["bytes"] * 8 / a["sw105"]; d = b["slice_qp"] - a["slice_qp"]
        for lo, hi in bins:
            if lo <= r < hi: tab[(lo, hi)][d] = tab[(lo, hi)].get(d, 0) + 1
    for b in bins:
        if tab[b]: print("  r in [%.2f,%.2f): %s" % (b[0], b[1], " ".join("%+d:%d" % (k, tab[b][k]) for k in sorted(tab[b]))))
    # first P after I: offset
    fp = [(rows[k + 1]["slice_qp"] - r["slice_qp"]) for k, r in enumerate(rows[:-1]) if r["type"] == "I" and rows[k + 1]["type"] != "I"]
    print("I->firstP offsets:", fp)
    # P target law: sw105 of P frames vs remaining budget
    print("P target sw105 (bits) per GOP: first / median / last; I target sw105; GOP budget bits = br*1000*gop/fps")
    for g in sorted(gops):
        P = [r["sw105"] for r in gops[g] if r["type"] != "I" and r["sw105"]]; I = [r["sw105"] for r in gops[g] if r["type"] == "I"]
        if P: print("  %2d: P %6d / %6d / %6d  I %7d  budget %7d  bits/frame %6d" % (g, P[0], sorted(P)[len(P) // 2], P[-1], I[0] if I else 0, gops[g][0]["br_kbps"] * 1000 * gop // fps, gops[g][0]["br_kbps"] * 1000 // fps))
    # sw106/107 relation to sw105 on P frames
    P = [r for r in rows if r["type"] != "I" and r["sw105"]]
    if P:
        r6 = [r["sw106"] / r["sw105"] for r in P]; r7 = [r["sw107"] / r["sw105"] for r in P]
        print("P frames: sw106/sw105 = %.3f..%.3f  sw107/sw105 = %.3f..%.3f" % (min(r6), max(r6), min(r7), max(r7)))

if __name__ == "__main__":
    for fn in sys.argv[1:]: fit(fn)
