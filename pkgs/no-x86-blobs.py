#!/usr/bin/env python3
"""Walk a nix closure and fail on any x86-64 artefact (#95).

Two things are asserted of every regular file in every store path listed in the
file named on the command line:

  * it is not an ELF whose `e_machine` is `EM_X86_64` (62);
  * it is not named `ax_gzip`, the Axera prebuilt packer #95 retired.

Used by pkgs/no-x86-blobs-check.nix.
"""

import os
import struct
import sys

EM_X86_64 = 62


def main():
    paths = [l.strip() for l in open(sys.argv[1]) if l.strip()]
    bad = []
    files = 0
    elfs = {}

    for root in paths:
        for dirpath, _dirs, names in os.walk(root):
            for n in names:
                p = os.path.join(dirpath, n)
                if os.path.islink(p) or not os.path.isfile(p):
                    continue
                files += 1
                if n == "ax_gzip":
                    bad.append("%s: the retired Axera packer (#95)" % p)
                try:
                    with open(p, "rb") as f:
                        head = f.read(20)
                except OSError:
                    continue
                if len(head) < 20 or head[:4] != b"\x7fELF":
                    continue
                machine = struct.unpack_from("<H", head, 18)[0]
                elfs[machine] = elfs.get(machine, 0) + 1
                if machine == EM_X86_64:
                    bad.append("%s: ELF e_machine = EM_X86_64" % p)

    print("no-x86-blobs (#95)")
    print("  store paths scanned: %d" % len(paths))
    print("  regular files:       %d" % files)
    print("  ELF e_machine seen:  %s"
          % (", ".join("%d x%d" % (m, c) for m, c in sorted(elfs.items()))
             or "none"))
    for p in paths:
        print("  root: %s" % p)

    if bad:
        print()
        for b in bad[:40]:
            print("  FAIL " + b)
        if len(bad) > 40:
            print("  ... and %d more" % (len(bad) - 40))
        print("\n%d x86-64 artefact(s) found" % len(bad))
        return 1
    print("  PASS no x86-64 ELF and no ax_gzip in any of these artefacts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
