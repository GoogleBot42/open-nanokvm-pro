#!/usr/bin/env python3
# Item 5 (persisted): capture the VC8000E encoder-core register image from the
# VCMD register-pool DRAM mirror via /dev/mem, and emit a FULL raw hex dump
# (absolute phys per word) covering swreg0..~319, so the EWLReadAsicConfig fuse
# words at swreg 80/214/226/287 (byte 0x140/0x358/0x388/0x47C) are backed by a
# preserved artifact. Read-only.
import ctypes, mmap, os, struct

LIB = "/dev/shm/kvmapp/server/dl_lib/libkvm.so"
W, H = 1920, 1080
SCAN_BASE = 0x73000000
SCAN_LEN  = 0x02000000
MARK = 0x90101010

lib = ctypes.CDLL(LIB)
lib.kvmv_init.argtypes = [ctypes.c_ubyte]
lib.kvmv_read_img.argtypes = [ctypes.c_uint16, ctypes.c_uint16, ctypes.c_ubyte, ctypes.c_uint16,
    ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)), ctypes.POINTER(ctypes.c_uint)]
lib.kvmv_read_img.restype = ctypes.c_int

def mapwin(base, length):
    ps = 0x1000
    off = base & ~(ps - 1); delta = base - off
    maplen = ((delta + length + ps - 1) // ps) * ps
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    m = mmap.mmap(fd, maplen, mmap.MAP_SHARED, mmap.PROT_READ, offset=off)
    return fd, m, delta

def rd(m, delta, phys):
    return struct.unpack_from("<I", m, delta + (phys - SCAN_BASE))[0]

print("=== pool_asic3: priming H.264 encode (6 frames @ 8000 kbps) ===", flush=True)
lib.kvmv_init(0)
ptr = ctypes.POINTER(ctypes.c_ubyte)(); ln = ctypes.c_uint(0)
for i in range(6):
    rc = lib.kvmv_read_img(W, H, 3, 8000, ctypes.byref(ptr), ctypes.byref(ln))
    print("  read_img[%d] rc=%d len=%d" % (i, rc, ln.value), flush=True)

fd, m, delta = mapwin(SCAN_BASE, SCAN_LEN)

# encoder register image base = first 0x90101010 (swreg0 control word)
mb = struct.pack("<I", MARK); i = delta; base = None
while True:
    j = m.find(mb, i, delta + SCAN_LEN)
    if j < 0: break
    if (j - delta) % 4 == 0:
        base = SCAN_BASE + (j - delta); break
    i = j + 4
print("=== encoder register image base (first 0x%08x) = 0x%08x ===" % (MARK, base or 0), flush=True)

if base:
    print("=== FULL RAW DUMP: encoder register image, swreg0..319 (absolute phys) ===", flush=True)
    for off in range(0, 0x500, 4):
        phys = base + off
        v = rd(m, delta, phys)
        print("phys=0x%08x  +0x%03x  swreg%-3d  0x%08x" % (phys, off, off // 4, v), flush=True)
    print("=== EWLReadAsicConfig FUSE WORDS (raw) ===", flush=True)
    for sw, off in ((80,0x140),(214,0x358),(226,0x388),(287,0x47C)):
        phys = base + off
        print("FUSE swreg%-3d  byte 0x%03x  phys=0x%08x  raw=0x%08x" % (sw, off, phys, rd(m, delta, phys)), flush=True)
else:
    print("!!! no 0x90101010 marker found -- encoder image not located (encode may not have primed)", flush=True)

m.close(); os.close(fd)
lib.kvmv_deinit()
print("=== done ===", flush=True)
