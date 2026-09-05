#!/usr/bin/env python3
"""regdiff.py A.txt B.txt [--all]  -- registers that differ between two geom-probe programs
(address registers excluded unless --all)."""
import sys, re
ADDR = {8,10,12,13,14,15,16,18,19,27,46,60,62,64,66,72,74,114,239,241}
def load(fn):
    d = {}
    for l in open(fn):
        m = re.match(r"swreg(\d+)\s+0x([0-9a-f]+)", l)
        if m: d[int(m.group(1))] = int(m.group(2), 16)
    return d
a, b = load(sys.argv[1]), load(sys.argv[2]); ALL = "--all" in sys.argv
n = 0
for r in sorted(set(a) | set(b)):
    if r in ADDR and not ALL: continue
    if a.get(r) != b.get(r):
        n += 1
        print("sw%-4d %s -> %s" % (r, "0x%08x" % a[r] if r in a else "-", "0x%08x" % b[r] if r in b else "-"))
print("%d registers differ (%s)" % (n, "incl." if ALL else "excl.") + " address regs)")
