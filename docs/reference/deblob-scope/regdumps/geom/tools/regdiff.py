#!/usr/bin/env python3
"""regdiff.py A.bin B.bin [base] [--exclude noise.bin ...]: list u32 words that differ."""
import sys, struct
args = sys.argv[1:]
a, b = args[0], args[1]
base = int(args[2], 0) if len(args) > 2 and not args[2].startswith('--') else 0
A = open(a, 'rb').read(); B = open(b, 'rb').read()
n = min(len(A), len(B)) // 4
out = []
for i in range(n):
    x = struct.unpack_from('<I', A, i*4)[0]; y = struct.unpack_from('<I', B, i*4)[0]
    if x != y: out.append((i*4, x, y))
print("%d words differ (%s vs %s)" % (len(out), a, b))
for off, x, y in out:
    print("  +0x%05x  %#010x -> %#010x   (abs %#010x)" % (off, x, y, base + off))
