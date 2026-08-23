#!/usr/bin/env python3
# Dump the full non-zero content of the venc VCMD cmdbuf + status pools after
# an H.264 encode, with VCMD opcode decode on the cmdbuf.
import ctypes, mmap, os, struct

LIB = "/dev/shm/kvmapp/server/dl_lib/libkvm.so"
W, H = 1920, 1080

# VCMD opcode table (top 5 bits of the command word), from Hantro vcmdswhwregisters.h
OPC = {0x01:"WREG", 0x02:"END", 0x03:"NOP", 0x08:"JMP", 0x09:"STALL",
       0x0A:"CLRINT", 0x0B:"JMP_RDY", 0x0C:"RREG", 0x0E:"INT", 0x14:"INT2",
       0x16:"RREG2"}

def mapmem(base, length):
    fd = os.open("/dev/mem", os.O_RDONLY)
    m = mmap.mmap(fd, length, mmap.MAP_SHARED, mmap.PROT_READ, offset=base)
    return fd, m

def decode_cmdbuf(w, start, end):
    # VCMD command word: bits[31:27]=opcode. WREG: bit26=fixed, [25:16]=length,
    # [15:0]=addr(word). Print a decoded stream.
    i = start
    n = 0
    while i < end and n < 400:
        cw = w[i]
        op = (cw >> 27) & 0x1f
        name = OPC.get(op, "op0x%02x" % op)
        if op == 0x01:  # WREG
            length = (cw >> 16) & 0x3ff
            addr = (cw & 0xffff)
            print("   %04x: %08x  WREG addr=0x%04x len=%d" % (i*4, cw, addr, length))
            for k in range(length):
                if i+1+k < end:
                    print("          +%03d reg0x%04x <= %08x" % (k, addr+k*4, w[i+1+k]))
            i += 1 + length; n += 1; continue
        print("   %04x: %08x  %s" % (i*4, cw, name))
        i += 1; n += 1
        if op == 0x02:  # END
            break

def dump(base, length, name, decode=False):
    fd, m = mapmem(base, length)
    w = [struct.unpack_from("<I", m, o)[0] for o in range(0, length, 4)]
    nz = [i for i,v in enumerate(w) if v != 0]
    if not nz:
        print("=== %s: all zero ===" % name); m.close(); os.close(fd); return
    lo, hi = nz[0], nz[-1]
    print("=== %s @ 0x%08x  nonzero words %d..%d (off 0x%x..0x%x) ===" % (name, base, lo, hi, lo*4, hi*4))
    if decode:
        decode_cmdbuf(w, lo, hi+2)
    else:
        i = lo
        while i <= hi:
            if w[i] == 0:
                j = i
                while j <= hi and w[j]==0: j += 1
                if j-i >= 4:
                    print("   [%04x..%04x] zero x%d" % (i*4,(j-1)*4,j-i)); i=j; continue
            print("   %04x: %08x" % (i*4, w[i])); i += 1
            if i > lo + 300:
                print("   ... (truncated at 300 words)"); break
    m.close(); os.close(fd)

lib = ctypes.CDLL(LIB)
lib.kvmv_read_img.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                              ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),
                              ctypes.POINTER(ctypes.c_uint)]
lib.kvmv_init(0)
ptr = ctypes.POINTER(ctypes.c_ubyte)(); ln = ctypes.c_uint(0)
for i in range(3):
    lib.kvmv_read_img(W, H, 3, 80, ctypes.byref(ptr), ctypes.byref(ln))
print("--- CMDBUF (decoded) ---")
dump(0x7380A000, 0x10000, "venc cmdbuf pool", decode=True)
print("--- CMDBUF (raw window) ---")
dump(0x7380A000, 0x10000, "venc cmdbuf pool raw")
print("--- STATUS ---")
dump(0x7381A000, 0x10000, "venc status pool")
lib.kvmv_deinit()
print("deinit ok")
