#!/usr/bin/env python3
"""Assert the mainline BL31 artefacts against the AX630C boot contract (#89).

Everything here is read back out of the built files -- nothing is taken on
trust from the build:

  * the ELF's entry point and its single executable LOAD segment both sit at
    BL31_BASE (0x40040000), and the image fits the 256 KiB `atf` window;
  * the signed image fits the 256 KiB `atf` partition;
  * the Axera 1 KiB header carries magic 0x55543322 -- compared field by field
    against the vendor atf_bl31_signed.bin this repo builds from the SDK, so
    the two are the same container and not merely both plausible;
  * both of the header's checksums recompute, using the SPL's arithmetic:
    32-bit signed wrapping sums of little-endian words, over the payload for
    img_check_sum and over header words 2..253 for check_sum;
  * the eight trailing header bytes are zero -- the SPL sums header words
    2..255 while the signing tool sums 2..253, and the two agree only because
    those words are zero (docs/mainline-port.md 11.2).

Usage is internal to pkgs/atf-mainline.nix.
"""

import argparse
import struct
import sys

HEADER_SIZE = 1024
MAGIC = 0x55543322

# Offsets into struct img_header (build/tools/imgsign/sec_boot_AX620E_sign.py).
OFF_CHECK_SUM = 0
OFF_MAGIC = 4
OFF_CAPABILITY = 8
OFF_IMG_SIZE = 12
OFF_IMG_CHECK_SUM = 20
OFF_KEY_N_HEADER = 44

failures = []
notes = []


def check(ok, msg):
    notes.append(("PASS" if ok else "FAIL") + "  " + msg)
    if not ok:
        failures.append(msg)


def u32(buf, off):
    return struct.unpack_from("<I", buf, off)[0]


def wrapping_word_sum(buf, start, end_exclusive):
    """Sum little-endian 32-bit words as C signed ints, wrapping at 32 bits."""
    total = 0
    for off in range(start, end_exclusive, 4):
        total = (total + u32(buf, off)) & 0xFFFFFFFF
    return total


def header_fields(img, label):
    return {
        "check_sum": u32(img, OFF_CHECK_SUM),
        "magic": u32(img, OFF_MAGIC),
        "capability": u32(img, OFF_CAPABILITY),
        "img_size": u32(img, OFF_IMG_SIZE),
        "img_check_sum": u32(img, OFF_IMG_CHECK_SUM),
        "key_n_header": u32(img, OFF_KEY_N_HEADER),
        "label": label,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--elf-headers", required=True)
    ap.add_argument("--elf-phdrs", required=True)
    ap.add_argument("--image", required=True)
    ap.add_argument("--vendor-image", required=True)
    ap.add_argument("--entry", type=int, required=True)
    ap.add_argument("--max-size", type=int, required=True)
    args = ap.parse_args()

    # ---- the ELF ---------------------------------------------------------
    headers = open(args.elf_headers).read()
    entry = None
    for line in headers.splitlines():
        if "Entry point address:" in line:
            entry = int(line.split(":", 1)[1].strip(), 16)
    check(entry == args.entry,
          "ELF entry point is 0x%08x (want 0x%08x)"
          % (entry if entry is not None else 0, args.entry))

    phdrs = open(args.elf_phdrs).read()
    loads = []
    for line in phdrs.splitlines():
        f = line.split()
        if len(f) >= 6 and f[0] == "LOAD":
            # Type Offset VirtAddr PhysAddr FileSiz MemSiz Flg Align
            loads.append((int(f[2], 16), int(f[3], 16), int(f[4], 16),
                          int(f[5], 16), line))
    check(len(loads) > 0, "the ELF has at least one LOAD segment")
    if loads:
        first = min(loads, key=lambda l: l[0])
        check(first[0] == args.entry and first[1] == args.entry,
              "first LOAD segment is linked at 0x%08x (vaddr 0x%08x, paddr 0x%08x)"
              % (args.entry, first[0], first[1]))
        span_end = max(v + m for v, _p, _f, m, _l in loads)
        span = span_end - args.entry
        check(span <= args.max_size,
              "BL31 occupies %d B of the %d B window at 0x%08x"
              % (span, args.max_size, args.entry))

    # ---- the signed image ------------------------------------------------
    img = open(args.image, "rb").read()
    vendor = open(args.vendor_image, "rb").read()

    check(len(img) > HEADER_SIZE, "signed image is larger than its header")
    check(len(img) <= args.max_size,
          "signed image is %d B (limit %d B, the atf partition)"
          % (len(img), args.max_size))

    ours = header_fields(img, "mainline")
    theirs = header_fields(vendor, "vendor")

    check(ours["magic"] == MAGIC,
          "header magic is 0x%08x" % ours["magic"])
    check(ours["magic"] == theirs["magic"],
          "header magic matches the vendor atf_bl31_signed.bin (0x%08x)"
          % theirs["magic"])
    check(ours["capability"] == theirs["capability"],
          "capability word matches the vendor image (0x%06x)"
          % theirs["capability"])
    check(ours["key_n_header"] == 0x02000800,
          "key_n_header says RSA-2048 (0x%08x)" % ours["key_n_header"])
    check(ours["key_n_header"] == theirs["key_n_header"],
          "key descriptor matches the vendor image (0x%08x)"
          % theirs["key_n_header"])

    payload_len = len(img) - HEADER_SIZE
    check(ours["img_size"] == payload_len,
          "header img_size is %d B and the payload is %d B"
          % (ours["img_size"], payload_len))

    want_img_sum = wrapping_word_sum(img, HEADER_SIZE, HEADER_SIZE +
                                     (payload_len & ~3))
    check(ours["img_check_sum"] == want_img_sum,
          "header img_check_sum 0x%08x recomputes over the payload"
          % ours["img_check_sum"])

    want_hdr_sum = wrapping_word_sum(img, 8, HEADER_SIZE - 8)
    check(ours["check_sum"] == want_hdr_sum,
          "header check_sum 0x%08x recomputes over header words 2..253"
          % ours["check_sum"])

    check(img[HEADER_SIZE - 8:HEADER_SIZE] == b"\0" * 8,
          "the last eight header bytes are zero, so the SPL's 2..255 sum "
          "agrees with the signing tool's 2..253")

    print("atf-mainline verification")
    print("  image:        %s (%d B)" % (args.image, len(img)))
    print("  vendor image: %s (%d B)" % (args.vendor_image, len(vendor)))
    print()
    for n in notes:
        print("  " + n)
    print()

    if failures:
        print("%d check(s) FAILED" % len(failures), file=sys.stderr)
        for f in failures:
            print("  - " + f, file=sys.stderr)
        return 1

    print("all %d checks passed" % len(notes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
