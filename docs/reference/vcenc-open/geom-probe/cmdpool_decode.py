#!/usr/bin/env python3
"""Decode vendor cmdbuf pool dumps -> per-slot programmed swreg images, then
diff the encode programs across geometries."""
import struct, sys, glob, os

SLOT = 0x2000

def decode_slot(words):
    """Return {swreg: value} from the WREG bursts in one cmdbuf slot."""
    prog = {}
    nz = [i for i, v in enumerate(words) if v]
    if not nz:
        return prog
    i, hi = nz[0], nz[-1]
    guard = 0
    while i <= hi and guard < 5000:
        guard += 1
        cw = words[i]
        op = (cw >> 27) & 0x1F
        if op == 0x01:  # WREG
            ln = (cw >> 16) & 0x3FF
            addr = cw & 0xFFFF
            for k in range(ln):
                if i + 1 + k < len(words):
                    baddr = addr + k * 4
                    if 0x1000 <= baddr < 0x1000 + 512 * 4:
                        prog[(baddr - 0x1000) // 4] = words[i + 1 + k]
            i += 1 + ln
            continue
        i += 1
        if op == 0x02:
            break
    return prog

def load_pool(path):
    data = open(path, "rb").read()
    slots = []
    for s in range(len(data) // SLOT):
        words = list(struct.unpack_from("<%dI" % (SLOT // 4), data, s * SLOT))
        prog = decode_slot(words)
        slots.append(prog)
    return slots

def encode_progs(path):
    """Return the slots that look like full encode programs (>=400 regs)."""
    return [(i, p) for i, p in enumerate(load_pool(path)) if len(p) >= 400]

if __name__ == "__main__":
    d = sys.argv[1] if len(sys.argv) > 1 else "geomprobe"
    for f in sorted(glob.glob(os.path.join(d, "cmdpool_*.bin"))):
        progs = encode_progs(f)
        print(os.path.basename(f), "->", [(i, len(p)) for i, p in progs])
        for i, p in progs:
            print("   slot %d: sw2=0x%08x sw5=0x%08x sw210=0x%08x sw237=0x%08x sw261=0x%08x sw191=0x%08x"
                  % (i, p.get(2, 0), p.get(5, 0), p.get(210, 0), p.get(237, 0),
                     p.get(261, 0), p.get(191, 0)))
