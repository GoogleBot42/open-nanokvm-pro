#!/usr/bin/env python3
"""Assert an AX620E signed boot image against what the SPL reads (#95).

Read back out of the built file, never taken on trust from the build:

  * magic 0x55543322 at byte 4;
  * `img_size` equals the stored payload's length, so the SPL reads exactly
    the bytes that are there ([SDK]/boot/bl1/core/boot/boot.c:781-787 reads
    `round_up(img_size, 4)` bytes to `ram_ops + 1024`);
  * `img_check_sum` recomputes over the stored payload, and `check_sum` over
    header words 2..253, with the SPL's own arithmetic -- 32-bit wrapping sums
    of little-endian words (calc_word_chksum, boot.c:140-154);
  * the last eight header bytes are zero, so the SPL's `sizeof(hdr) - 8` sum
    from `&capability` and the signing tool's words-2..253 sum agree;
  * with --raw-payload, that the stored payload IS that file byte for byte --
    the #95 assertion that nothing compressed the image behind our back.

Used by pkgs/ax-sign.nix.
"""

import argparse
import struct
import sys

HEADER_SIZE = 1024
MAGIC = 0x55543322

OFF_CHECK_SUM = 0
OFF_MAGIC = 4
OFF_CAPABILITY = 8
OFF_IMG_SIZE = 12
OFF_FW_SIZE = 16
OFF_IMG_CHECK_SUM = 20
OFF_FW_CHECK_SUM = 24
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
    total = 0
    for off in range(start, end_exclusive, 4):
        total = (total + u32(buf, off)) & 0xFFFFFFFF
    return total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--stored", required=True,
                    help="the payload as it was handed to the signing tool")
    ap.add_argument("--raw-payload",
                    help="if given, the stored payload must equal this file")
    ap.add_argument("--max-size", type=int)
    args = ap.parse_args()

    img = open(args.image, "rb").read()
    stored = open(args.stored, "rb").read()

    check(len(img) == HEADER_SIZE + len(stored),
          "image is %d B = 1 KiB header + %d B payload" % (len(img), len(stored)))
    check(u32(img, OFF_MAGIC) == MAGIC,
          "header magic is 0x%08x" % u32(img, OFF_MAGIC))
    check(u32(img, OFF_KEY_N_HEADER) == 0x02000800,
          "key_n_header says RSA-2048 (0x%08x)" % u32(img, OFF_KEY_N_HEADER))

    payload_len = len(img) - HEADER_SIZE
    check(u32(img, OFF_IMG_SIZE) == payload_len,
          "header img_size is %d B and the payload is %d B"
          % (u32(img, OFF_IMG_SIZE), payload_len))

    want = wrapping_word_sum(img, HEADER_SIZE,
                             HEADER_SIZE + (payload_len & ~3))
    check(u32(img, OFF_IMG_CHECK_SUM) == want,
          "header img_check_sum 0x%08x recomputes over the payload"
          % u32(img, OFF_IMG_CHECK_SUM))

    want_hdr = wrapping_word_sum(img, 8, HEADER_SIZE - 8)
    check(u32(img, OFF_CHECK_SUM) == want_hdr,
          "header check_sum 0x%08x recomputes over header words 2..253"
          % u32(img, OFF_CHECK_SUM))

    check(img[HEADER_SIZE - 8:HEADER_SIZE] == b"\0" * 8,
          "the last eight header bytes are zero, so the SPL's "
          "sizeof(hdr)-8 sum agrees with the signing tool's")

    check(u32(img, OFF_FW_SIZE) == 0 and u32(img, OFF_FW_CHECK_SUM) == 0,
          "fw_size and fw_check_sum are 0 (no spliced firmware member)")

    if args.raw_payload:
        raw = open(args.raw_payload, "rb").read()
        check(img[HEADER_SIZE:] == raw,
              "#95: the stored payload is the %d B raw binary, verbatim -- "
              "nothing compressed it" % len(raw))

    if args.max_size is not None:
        check(len(img) <= args.max_size,
              "image is %d B, within its %d B partition (%.1f%% used)"
              % (len(img), args.max_size, 100.0 * len(img) / args.max_size))

    print("ax-sign verification: %s" % args.image)
    for n in notes:
        print("  " + n)

    if failures:
        print("%d check(s) FAILED" % len(failures), file=sys.stderr)
        for f in failures:
            print("  - " + f, file=sys.stderr)
        return 1
    print("all %d checks passed" % len(notes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
