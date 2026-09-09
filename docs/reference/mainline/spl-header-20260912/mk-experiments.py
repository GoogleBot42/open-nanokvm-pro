#!/usr/bin/env python3
"""#93 -- build the two corrupted SPL images the BootROM experiments write to p1.

Usage: mk-experiments.py <good_signed_spl.bin> <outdir>

The signed SPL container is 256 KiB: a 1 KiB header at 0 and an identical copy
at PKG_SIZE (0x20000), each followed by the SPL payload (0x400 / 0x20400).
`capability` = 0x54FAFE has IMG_BAK_ENABLE (bit 11) set, so a ROM that rejects
the primary header may fall back to the backup one -- BOTH copies are corrupted
identically, or "it booted" would not be an answer.

FLIP is header offset 0x300, inside `signature[384]` (header bytes 444..827),
which is exactly the region a hybrid pMBR+GPT header would occupy.

The header checksum is asserted against the good image first, computed two ways:
  * cksum_py -- the sign tool (build/tools/imgsign/spl_AX620E_sign.py):
    words 2..253, i.e. header bytes 8..1015.
  * cksum_c  -- the SPL's own verifier (boot/bl1/core/boot/boot.c
    verify_img_header): calc_word_chksum(&header->capability,
    sizeof(struct img_header) - 8), i.e. header bytes 8..1023.
They differ by the last two words, which are zero in `reserved[17]`, so both
must reproduce the stored value. Experiment 2 writes the cksum_c value (the
wider window), which the assertions show equals the cksum_py one.
"""
import sys
import struct
import hashlib

GOOD = sys.argv[1]
OUTDIR = sys.argv[2]
d = bytearray(open(GOOD, "rb").read())
assert len(d) == 262144, len(d)

HDR = 1024
PKG = 0x20000
COPIES = [0, PKG]
FLIP = 0x300  # header offset, inside signature[] (444..827)


def cksum_py(buf, base):
    """The sign script: words 2..253 -> header bytes 8..1015."""
    s = 0
    for i in range(2, (HDR - 8) // 4):
        s = (s + struct.unpack_from("<I", buf, base + 4 * i)[0]) & 0xFFFFFFFF
    return s


def cksum_c(buf, base):
    """boot.c verify_img_header: 1016 B from &capability -> bytes 8..1023."""
    s = 0
    for i in range((HDR - 8) // 4):
        s = (s + struct.unpack_from("<I", buf, base + 8 + 4 * i)[0]) & 0xFFFFFFFF
    return s


for base in COPIES:
    stored = struct.unpack_from("<I", d, base)[0]
    magic = struct.unpack_from("<I", d, base + 4)[0]
    cap = struct.unpack_from("<I", d, base + 8)[0]
    print("good copy @0x%05x: check_sum=0x%08x magic=0x%08x cap=0x%06x  py=0x%08x c=0x%08x"
          % (base, stored, magic, cap, cksum_py(d, base), cksum_c(d, base)))
    assert magic == 0x55543322
    assert stored == cksum_py(d, base), "sign-script recomputation misses check_sum"
    assert stored == cksum_c(d, base), "boot.c recomputation misses check_sum"
    print("  tail words 254,255 = 0x%08x 0x%08x"
          % struct.unpack_from("<2I", d, base + 1016))
    print("  sig_header@440 = 0x%08x ; signature byte @0x%03x = 0x%02x"
          % (struct.unpack_from("<I", d, base + 440)[0], FLIP, d[base + FLIP]))

# ---- experiment 1: flip, do NOT fix the checksum -------------------------
e1 = bytearray(d)
for base in COPIES:
    e1[base + FLIP] ^= 0xFF
for base in COPIES:
    stored = struct.unpack_from("<I", e1, base)[0]
    print("exp1 copy @0x%05x: stored=0x%08x recomputed=0x%08x (mismatch expected)"
          % (base, stored, cksum_c(e1, base)))
    assert stored != cksum_c(e1, base)

# ---- experiment 2: flip AND fix the checksum -----------------------------
e2 = bytearray(e1)
for base in COPIES:
    struct.pack_into("<I", e2, base, cksum_c(e2, base))
for base in COPIES:
    stored = struct.unpack_from("<I", e2, base)[0]
    print("exp2 copy @0x%05x: stored=0x%08x py=0x%08x c=0x%08x"
          % (base, stored, cksum_py(e2, base), cksum_c(e2, base)))
    assert stored == cksum_c(e2, base) == cksum_py(e2, base)

diff1 = [i for i in range(len(d)) if d[i] != e1[i]]
diff2 = [i for i in range(len(d)) if d[i] != e2[i]]
print("exp1 differs from good at", [hex(x) for x in diff1])
print("exp2 differs from good at", [hex(x) for x in diff2])
assert diff1 == [b + FLIP for b in COPIES]

open(OUTDIR + "/spl-exp1-badsum.bin", "wb").write(e1)
open(OUTDIR + "/spl-exp2-goodsum.bin", "wb").write(e2)
print(hashlib.sha256(d).hexdigest(), "spl-good.bin")
for n in ("spl-exp1-badsum.bin", "spl-exp2-goodsum.bin"):
    print(hashlib.sha256(open(OUTDIR + "/" + n, "rb").read()).hexdigest(), n)
