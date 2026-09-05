# SPDX-License-Identifier: GPL-2.0 OR MIT
"""Regenerate every auto-generated table of the open VC8000E encoder from the
decoded VENDOR register programs.  Nothing here is transcribed by hand: the
inputs are the `swregN 0xVALUE` program dumps committed under
docs/reference/vcenc-open/ (the 17-geometry probe of 2026-08-31 and the
2026-09-04 vendor differential campaign).

    nix shell nixpkgs#python3 -c python3 pkgs/vcenc-ewl/tests/gen_vectors.py

Outputs (all overwritten in place):
  pkgs/vcenc-ewl/vcenc_qp_tables.h        QP -> lambda/cost LUTs (sw37, sw125..132)
  pkgs/vcenc-ewl/tests/vcenc_geom_vectors.h   golden geometry vectors (26 geometries)
  pkgs/vcenc-ewl/tests/vcenc_fixqp_vectors.h  vendor fixed-QP ladder programs (sparse)
"""

import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
REF = os.path.join(ROOT, "docs", "reference", "vcenc-open")
DIFF = os.path.join(REF, "vendor-diff-20260904")
PROBE = os.path.join(REF, "geom-probe", "programs")

NREGS = 511


def load(path):
    """Decoded program -> list of 512 words (index == swreg number, [0] unused)."""
    regs = [0] * (NREGS + 1)
    for line in open(path):
        m = re.match(r"^swreg(\d+)\s+0x([0-9a-fA-F]+)", line.strip())
        if m:
            regs[int(m.group(1))] = int(m.group(2), 16)
    return regs


def rel(path):
    return os.path.relpath(path, REF)


# --------------------------------------------------------------------------
# 1. QP tables: sw125..132 = F(q - 2k), k = 0..7 and sw37 = L(q), where
#    q = min(QP,35) for I frames and q = min(QP,35) - 3 for P frames.
#    F is instantiated SEPARATELY per frame type (the I and P LUTs differ at
#    q = 19 and q = 20); L is one table (I at q and P at q cross-validate).
# --------------------------------------------------------------------------

def collect_qp():
    f = {"I": {}, "P": {}}
    fsrc = {"I": {}, "P": {}}
    lam, lsrc = {}, {}
    files = sorted(glob.glob(os.path.join(DIFF, "E*", "vendor_*_IDR.txt"))
                   + glob.glob(os.path.join(DIFF, "E*", "vendor_*_P.txt"))
                   + glob.glob(os.path.join(PROBE, "vendor_*_IDR.txt"))
                   + glob.glob(os.path.join(PROBE, "vendor_*_P.txt")))
    for p in files:
        v = load(p)
        t = "I" if p.endswith("_IDR.txt") else "P"
        qp = (v[7] >> 8) & 0x3F
        q = min(qp, 35) if t == "I" else min(qp, 35) - 3
        for k in range(8):
            idx = q - 2 * k
            val = v[125 + k]
            if idx in f[t] and f[t][idx] != val:
                sys.exit("F_%s(%d) conflict: 0x%08x (%s) vs 0x%08x (%s)"
                         % (t, idx, f[t][idx], fsrc[t][idx], val, rel(p)))
            f[t][idx] = val
            fsrc[t].setdefault(idx, rel(p))
        if q in lam and lam[q] != v[37]:
            sys.exit("L(%d) conflict: 0x%08x (%s) vs 0x%08x (%s)"
                     % (q, lam[q], lsrc[q], v[37], rel(p)))
        lam[q] = v[37]
        lsrc.setdefault(q, rel(p))
    return f, fsrc, lam, lsrc


def r4(x):
    return int(round(x / 4.0)) * 4


def r16(x):
    return int(round(x / 16.0)) * 16


def geo(tab, q, lo_bound, hi_bound):
    """Geometric interpolation of the (hi16, lo16) pair between the nearest
    observed neighbours (the LUT grows as 2^(q/6); lambda as 2^(q/3))."""
    a = max(k for k in tab if k < q and lo_bound <= k <= hi_bound)
    b = min(k for k in tab if k > q and lo_bound <= k <= hi_bound)
    out = 0
    for shift, rnd in ((16, r4), (0, r16)):
        va = (tab[a] >> shift) & 0xFFFF
        vb = (tab[b] >> shift) & 0xFFFF
        if va == 0 or vb == 0:          # bottom of the table: linear
            v = rnd(va + (vb - va) * (q - a) / float(b - a))
        else:
            v = rnd(va * (float(vb) / va) ** ((q - a) / float(b - a)))
        out |= (v & 0xFFFF) << shift
    return out


def lam_from_f(fi, q):
    """L(q) = ( floor4(F_I(2q-48).hi * 2/3) << 16 ) | F_I(2q-48).lo -- a
    relation that reproduces all eight (q, 2q-48) pairs observed in both
    tables exactly.  Used to fill L gaps whose F partner IS observed."""
    idx = 2 * q - 48
    if idx not in fi:
        return None
    hi = (fi[idx] >> 16) & 0xFFFF
    lo = fi[idx] & 0xFFFF
    return (((hi * 2 // 3) // 4 * 4) << 16) | lo


def emit_qp_tables(path):
    f, fsrc, lam, lsrc = collect_qp()
    fi, fp = f["I"], f["P"]

    # self-check: the L = g(F(2q-48)) relation on every pair observed in both
    for q in sorted(lam):
        d = lam_from_f(fi, q)
        if d is not None and d != lam[q]:
            sys.exit("L=g(F(2q-48)) broken at q=%d: 0x%08x vs 0x%08x"
                     % (q, d, lam[q]))
    # self-check: I and P agree wherever both were observed, except 19 and 20
    for q in sorted(set(fi) & set(fp)):
        if fi[q] != fp[q] and q not in (19, 20):
            sys.exit("unexpected I/P split at q=%d" % q)

    # index ranges actually reachable for QP 16..51:
    #   I: q in [16,35], block indices q-2k -> [2,35]
    #   P: q in [13,32], block indices q-2k -> [-1,32]
    I_LO, I_HI = 2, 35
    P_LO, P_HI = -1, 32
    L_LO, L_HI = 13, 35

    rows = {"I": [], "P": [], "L": []}
    gaps = []
    for q in range(I_LO, I_HI + 1):
        if q in fi:
            rows["I"].append((q, fi[q], "obs " + fsrc["I"][q]))
        elif q in fp:
            rows["I"].append((q, fp[q], "P-table obs " + fsrc["P"][q]))
            gaps.append("F_I(%d) not observed in any I program" % q)
        else:
            rows["I"].append((q, geo(fi, q, I_LO, I_HI), "interpolated"))
            gaps.append("F_I(%d) not observed at all" % q)
    for q in range(P_LO, P_HI + 1):
        if q in fp:
            rows["P"].append((q, fp[q], "obs " + fsrc["P"][q]))
        elif q in fi:
            rows["P"].append((q, fi[q], "I-table obs " + fsrc["I"][q]))
            gaps.append("F_P(%d) not observed in any P program" % q)
        else:
            rows["P"].append((q, geo(fp, q, P_LO, P_HI), "interpolated"))
            gaps.append("F_P(%d) not observed at all" % q)
    for q in range(L_LO, L_HI + 1):
        if q in lam:
            rows["L"].append((q, lam[q], "obs " + lsrc[q]))
        else:
            d = lam_from_f(fi, q)
            if d is not None:
                rows["L"].append((q, d, "derived g(F(%d))" % (2 * q - 48)))
            else:
                rows["L"].append((q, geo(lam, q, L_LO, L_HI), "interpolated"))
            gaps.append("L(%d) (sw37) not observed" % q)

    with open(path, "w") as o:
        o.write("""/* SPDX-License-Identifier: GPL-2.0 OR MIT */
/* AUTO-GENERATED by pkgs/vcenc-ewl/tests/gen_vectors.py -- do not edit.
 *
 * VC8000E QP-dependent register tables, mined from the decoded VENDOR
 * register programs under docs/reference/vcenc-open/ (17-geometry probe
 * 2026-08-31 + vendor differential campaign 2026-09-04).  Laws:
 *
 *   sw7        = (pic_init_qp << 26) | (frame_qp << 8)
 *   sw125+k    = F_<type>(q - 2k), k = 0..7
 *   sw37       = L(q)
 *   q          = min(QP,35)      for I frames
 *   q          = min(QP,35) - 3  for P frames
 *
 * F is a per-frame-type LUT: the I and P instantiations are identical at
 * every commonly observed index EXCEPT q=19 (hi16 0x0200 vs 0x0204) and
 * q=20 (lo16 0x0800 vs 0x0810), so the two tables are kept separate and each
 * is derived only from programs of its own frame type.  L is a single table:
 * the I (q) and P (q) observations cross-validate at q=19 and q=22.
 *
 * Per-entry provenance is in the trailing comment: `obs <file>` = read
 * straight out of that vendor program; `derived` = filled from the
 * L(q) = (floor4(F_I(2q-48).hi * 2/3) << 16) | F_I(2q-48).lo relation, which
 * reproduces every observed (L, F) pair exactly; `interpolated` = no
 * observation, geometric fit between the neighbours (F ~ 2^(q/6),
 * lambda ~ 2^(q/3)) rounded to the LUT's own field granularity.
 */
#ifndef VCENC_QP_TABLES_H
#define VCENC_QP_TABLES_H

#include <stdint.h>

""")
        for name, lo, hi, key in (("VCENC_F_I", I_LO, I_HI, "I"),
                                  ("VCENC_F_P", P_LO, P_HI, "P"),
                                  ("VCENC_L", L_LO, L_HI, "L")):
            o.write("#define %s_LO (%d)\n#define %s_HI (%d)\n"
                    % (name, lo, name, hi))
            o.write("static const uint32_t %s[%s_HI - %s_LO + 1] = {\n"
                    % (name, name, name))
            for q, val, src in rows[key]:
                o.write("\t0x%08x, /* q=%-3d %s */\n" % (val, q, src))
            o.write("};\n\n")
        o.write("#endif /* VCENC_QP_TABLES_H */\n")
    return gaps, rows


# --------------------------------------------------------------------------
# 2. Golden geometry vectors
# --------------------------------------------------------------------------

def emit_geom(path):
    seen, out = {}, []
    for d in (PROBE, os.path.join(DIFF, "E3")):
        for p in sorted(glob.glob(os.path.join(d, "vendor_*x*_IDR.txt"))):
            m = re.search(r"vendor_(\d+)x(\d+)_IDR\.txt$", p)
            if not m:
                continue
            w, h = int(m.group(1)), int(m.group(2))
            if (w, h) in seen:
                continue
            seen[(w, h)] = True
            i = load(p)
            pp = p.replace("_IDR.txt", "_P.txt")
            v = load(pp) if os.path.exists(pp) else None
            row = dict(w=w, h=h, sw5_idr=i[5] & ~1, sw38=i[38], sw134=i[134],
                       sw193_idr=i[193], sw210=i[210], sw212=i[212],
                       sw213=i[213], sw237=i[237], sw245=i[245],
                       sw246=i[246], sw261=i[261], src=rel(p))
            if v:
                row.update(sw193_p=v[193], lupitch=v[15] - i[15],
                           chpitch=v[16] - i[16], s62off=i[62] - i[60],
                           s239pitch=abs(i[239] - i[241]),
                           s114pitch=v[114] - i[114])
            else:
                row.update(sw193_p=0, lupitch=0, chpitch=0, s62off=0,
                           s239pitch=0, s114pitch=0)
            out.append(row)
    out.sort(key=lambda r: (r["w"], r["h"]))
    with open(path, "w") as o:
        o.write("""/* SPDX-License-Identifier: GPL-2.0 OR MIT */
/* AUTO-GENERATED by pkgs/vcenc-ewl/tests/gen_vectors.py -- do not edit.
 * Each row is the VENDOR encoder's own programmed value for the
 * geometry-law registers, decoded from the live cmdbuf WREG program:
 * the 17-geometry differential probe of 2026-08-31
 * (docs/reference/vcenc-open/geom-probe/) plus the nine geometries above
 * 1920 wide of the 2026-09-04 campaign (.../vendor-diff-20260904/E3/).
 * Pitches are the vendor's own buffer spacing (P-frame bank minus IDR bank;
 * s62off and s239pitch from within the IDR program). 0 = not probed. */
static const struct {
    int w, h;
    uint32_t sw5_idr, sw38, sw134, sw193_idr, sw193_p;
    uint32_t sw210, sw212, sw213, sw237, sw245, sw246, sw261;
    uint32_t lupitch, chpitch, s62off, s239pitch, s114pitch;
} VG[] = {
""")
        for r in out:
            o.write("    { %4d, %4d, 0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%08x,\n"
                    "      0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%08x, 0x%08x,\n"
                    "      0x%x, 0x%x, 0x%x, 0x%x, 0x%x },\n"
                    % (r["w"], r["h"], r["sw5_idr"], r["sw38"], r["sw134"],
                       r["sw193_idr"], r["sw193_p"], r["sw210"], r["sw212"],
                       r["sw213"], r["sw237"], r["sw245"], r["sw246"],
                       r["sw261"], r["lupitch"], r["chpitch"], r["s62off"],
                       r["s239pitch"], r["s114pitch"]))
        o.write("};\n")
    return out


# --------------------------------------------------------------------------
# 3. Vendor fixed-QP ladder programs (sparse: only non-zero registers)
# --------------------------------------------------------------------------

LADDER = [("16", 16, 16), ("20", 20, 20), ("24", 24, 24), ("28", 28, 28),
          ("32", 32, 32), ("36", 36, 36), ("40", 40, 40), ("44", 44, 44),
          ("48", 48, 48), ("51", 51, 51), ("_i28_p34", 28, 34)]


def emit_fixqp(path):
    progs = []
    for tag, qpi, qpp in LADDER:
        for kind, qp in (("IDR", qpi), ("P", qpp)):
            p = os.path.join(DIFF, "E2", "vendor_fixqp%s_%s.txt" % (tag, kind))
            v = load(p)
            pic = v[7] >> 26
            progs.append((tag, kind, qp, pic, v, rel(p)))
    with open(path, "w") as o:
        o.write("""/* SPDX-License-Identifier: GPL-2.0 OR MIT */
/* AUTO-GENERATED by pkgs/vcenc-ewl/tests/gen_vectors.py -- do not edit.
 * The VENDOR encoder's 1920x1080 fixed-QP (AX_VENC_RC_MODE_H264FIXQP)
 * register programs, decoded from the live cmdbuf WREG program
 * (docs/reference/vcenc-open/vendor-diff-20260904/E2/).  Stored sparsely:
 * only the non-zero registers, `.reg` == swreg number.  qp is the requested
 * (and bitstream-confirmed) frame QP, pic_init_qp the PPS value the run
 * shares between both frame types. */
typedef struct { uint16_t reg; uint32_t val; } vfq_reg;
""")
        for tag, kind, qp, pic, v, src in progs:
            name = "VFQ_%s_%s" % (tag.strip("_"), kind)
            o.write("/* %s */\nstatic const vfq_reg %s[] = {\n" % (src, name))
            for r in range(1, NREGS + 1):
                if v[r]:
                    o.write("    { %3d, 0x%08x },\n" % (r, v[r]))
            o.write("};\n")
        o.write("\nstatic const struct {\n"
                "    const char *tag; int is_p; uint32_t qp, pic_init_qp;\n"
                "    const vfq_reg *regs; unsigned n;\n"
                "} VFQ[] = {\n")
        for tag, kind, qp, pic, v, src in progs:
            name = "VFQ_%s_%s" % (tag.strip("_"), kind)
            o.write('    { "fixqp%s/%s", %d, %d, %d, %s, '
                    'sizeof %s / sizeof %s[0] },\n'
                    % (tag, kind, 1 if kind == "P" else 0, qp, pic, name,
                       name, name))
        o.write("};\n")
    return progs


def main():
    qp_h = os.path.join(HERE, "..", "vcenc_qp_tables.h")
    gaps, rows = emit_qp_tables(qp_h)
    geom = emit_geom(os.path.join(HERE, "vcenc_geom_vectors.h"))
    fq = emit_fixqp(os.path.join(HERE, "vcenc_fixqp_vectors.h"))
    print("vcenc_qp_tables.h: F_I %d, F_P %d, L %d entries"
          % (len(rows["I"]), len(rows["P"]), len(rows["L"])))
    for g in gaps:
        print("  GAP: " + g)
    print("vcenc_geom_vectors.h: %d geometries" % len(geom))
    print("vcenc_fixqp_vectors.h: %d programs" % len(fq))


if __name__ == "__main__":
    main()
