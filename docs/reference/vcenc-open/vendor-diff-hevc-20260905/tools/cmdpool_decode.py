#!/usr/bin/env python3
"""Decode vendor cmdbuf pool dumps -> per-slot programmed swreg images.
2026-09-05: `ops` mode lists the FULL opcode structure of a slot (every command
word with its opcode / length / address, and the non-swreg WREG targets) so a
codec differential can compare cmdbuf STRUCTURE, not only swreg values.
  cmdpool_decode.py <dir>                 summary of encode-program slots
  cmdpool_decode.py ops <pool.bin> <slot> opcode listing of one slot
  cmdpool_decode.py opsig <pool.bin>      one-line structural signature per slot"""
import struct, sys, glob, os

SLOT = 0x2000
OPNAME = {0x01: "WREG", 0x02: "END", 0x03: "NOP", 0x04: "RREG", 0x05: "JMP", 0x06: "STALL", 0x07: "CLRINT"}

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

def list_ops(words):
    """Walk one slot; return [(index, opcode, length, addr, payload_words)] until END.
    Length rule: WREG carries (ln) payload words; RREG likewise (ln words of
    destination addresses in this ABI: observed as RREG(1,0x68) / RREG(512,0x1000)
    -- treat identically); other opcodes are single words."""
    out = []
    nz = [i for i, v in enumerate(words) if v]
    if not nz:
        return out
    i, hi = nz[0], nz[-1]
    guard = 0
    while i <= hi and guard < 5000:
        guard += 1
        cw = words[i]
        op = (cw >> 27) & 0x1F
        ln = (cw >> 16) & 0x3FF
        addr = cw & 0xFFFF
        if op in (0x01, 0x04):
            out.append((i, op, ln, addr, words[i + 1:i + 1 + ln] if op == 0x01 else words[i + 1:i + 1 + 2]))
            i += 1 + (ln if op == 0x01 else 2)
        else:
            out.append((i, op, ln, addr, [cw]))
            i += 1
            if op == 0x02:
                break
    return out

def op_signature(words):
    """Compact structural signature: opcode/len/addr per command (WREG payload
    omitted), plus the words of every WREG outside 0x1000..0x17fc verbatim."""
    sig = []
    for i, op, ln, addr, pl in list_ops(words):
        name = OPNAME.get(op, "op%02x" % op)
        if op == 0x01 and not (0x1000 <= addr < 0x1800):
            sig.append("%s(%d,0x%04x)=%s" % (name, ln, addr, ",".join("%08x" % w for w in pl)))
        else:
            sig.append("%s(%d,0x%04x)" % (name, ln, addr))
    return " ".join(sig)

def load_pool_words(path):
    data = open(path, "rb").read()
    return [list(struct.unpack_from("<%dI" % (SLOT // 4), data, s * SLOT)) for s in range(len(data) // SLOT)]

def load_pool(path):
    return [decode_slot(w) for w in load_pool_words(path)]

def encode_progs(path):
    """Return the slots that look like full encode programs (>=400 regs)."""
    return [(i, p) for i, p in enumerate(load_pool(path)) if len(p) >= 400]

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "ops":
        words = load_pool_words(sys.argv[2])[int(sys.argv[3])]
        n = 0
        for i, op, ln, addr, pl in list_ops(words):
            name = OPNAME.get(op, "op%02x" % op)
            if op == 0x01:
                if 0x1000 <= addr < 0x1800:
                    print("%4d %-6s len=%-3d 0x%04x  (swreg%d..swreg%d)" % (i, name, ln, addr, (addr - 0x1000) // 4, (addr - 0x1000) // 4 + ln - 1))
                else:
                    print("%4d %-6s len=%-3d 0x%04x  = %s" % (i, name, ln, addr, " ".join("%08x" % w for w in pl)))
            else:
                print("%4d %-6s len=%-3d 0x%04x  raw=%08x %s" % (i, name, ln, addr, pl[0], " ".join("%08x" % w for w in pl[1:])))
            n = i
        nzhi = max((i for i, v in enumerate(words) if v), default=0)
        print("last opcode word %d, last nonzero word %d (%d words used)" % (n, nzhi, nzhi + 1))
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == "opsig":
        for s, words in enumerate(load_pool_words(sys.argv[2])):
            if any(words):
                print("slot %d: %s" % (s, op_signature(words)))
        sys.exit(0)
    d = sys.argv[1] if len(sys.argv) > 1 else "geomprobe"
    for f in sorted(glob.glob(os.path.join(d, "cmdpool_*.bin"))):
        progs = encode_progs(f)
        print(os.path.basename(f), "->", [(i, len(p)) for i, p in progs])
        for i, p in progs:
            print("   slot %d: sw2=0x%08x sw5=0x%08x sw210=0x%08x sw237=0x%08x sw261=0x%08x sw191=0x%08x"
                  % (i, p.get(2, 0), p.get(5, 0), p.get(210, 0), p.get(237, 0),
                     p.get(261, 0), p.get(191, 0)))
