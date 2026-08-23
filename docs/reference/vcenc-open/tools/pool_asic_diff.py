#!/usr/bin/env python3
# Differential register-image capture. Prime an H.264 encode at a given bitrate
# via the OPEN libkvm, locate the VC8000E swreg0..319 image in the VCMD register
# pool DRAM mirror (/dev/mem), and emit "swreg<idx> 0x<val>" lines for diffing.
# Read-only. Args: <bitrate_kbps> <nframes> <label>
import ctypes, mmap, os, struct, sys

LIB = "/dev/shm/kvmapp/server/dl_lib/libkvm.so"
W, H = 1920, 1080
SCAN_BASE = 0x73000000
SCAN_LEN  = 0x02000000
MARK = 0x90101010
BR   = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
NF   = int(sys.argv[2]) if len(sys.argv) > 2 else 6
LBL  = sys.argv[3] if len(sys.argv) > 3 else "run"

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

print("### LABEL=%s BITRATE=%d NF=%d" % (LBL, BR, NF), flush=True)
lib.kvmv_init(0)
ptr = ctypes.POINTER(ctypes.c_ubyte)(); ln = ctypes.c_uint(0)
lens = []
for i in range(NF):
    rc = lib.kvmv_read_img(W, H, 3, BR, ctypes.byref(ptr), ctypes.byref(ln))
    lens.append((rc, ln.value))
print("### read_img rc/len: %s" % lens, flush=True)

fd, m, delta = mapwin(SCAN_BASE, SCAN_LEN)
mb = struct.pack("<I", MARK); i = delta; base = None
while True:
    j = m.find(mb, i, delta + SCAN_LEN)
    if j < 0: break
    if (j - delta) % 4 == 0:
        base = SCAN_BASE + (j - delta); break
    i = j + 4
print("### base=0x%08x" % (base or 0), flush=True)
if base:
    for off in range(0, 0x500, 4):
        print("swreg%-3d 0x%08x" % (off // 4, rd(m, delta, base + off)), flush=True)
m.close(); os.close(fd)
try: lib.kvmv_deinit()
except Exception: pass
print("### done %s" % LBL, flush=True)
