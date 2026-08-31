#!/usr/bin/env python3
# Drive the VENDOR capture path (kvm_pipeline.c vendor MPI backend) headless at
# the LIVE source geometry, under the LD_PRELOAD ioctl tracer. Extracts:
#  - what MIPI rate / lane config the vendor stack programs at this geometry
#  - the delivered frame's true geometry/stride/format/size (AX_VIDEO_FRAME_T)
#  - a raw frame dump for off-device visual verification
# Usage: LD_PRELOAD=/tmp/ioctltrace.so TRACE_OUT=/tmp/cap.trace \
#          python3 cap4k_trace.py /tmp/libkvm-vendorcap.so
# Run with nanokvm.service STOPPED.
import ctypes, os, struct, sys

LIB = sys.argv[1] if len(sys.argv) > 1 else "/tmp/libkvm-vendorcap.so"
W = int(open("/proc/lt6911_info/width").read())
H = int(open("/proc/lt6911_info/height").read())
FPS = int(open("/proc/lt6911_info/fps").read())
print("live source: %dx%d@%d" % (W, H, FPS), flush=True)

lib = ctypes.CDLL(LIB, mode=ctypes.RTLD_GLOBAL)
sysl = ctypes.CDLL("/opt/lib/libax_sys.so", mode=ctypes.RTLD_GLOBAL)

ctx = (ctypes.c_ubyte * 512)()
rc = lib.kvm_sys_init(ctx, W, H)
print("kvm_sys_init rc=%d" % rc, flush=True)
rc = lib.kvm_cap_start(ctx, W, H, FPS)
print("kvm_cap_start rc=%d" % rc, flush=True)

img = (ctypes.c_ubyte * 592)()   # AX_IMG_INFO_T; stVFrame at offset 0
got = 0
for i in range(8):
    rc = lib.kvm_cap_get(img, 2000)
    if rc == 0:
        got += 1
        w = struct.unpack_from("<I", img, 0)[0]
        h = struct.unpack_from("<I", img, 4)[0]
        fmt = struct.unpack_from("<I", img, 8)[0]
        stride = struct.unpack_from("<I", img, 32)[0]
        phys = struct.unpack_from("<Q", img, 56)[0]
        fsz = struct.unpack_from("<I", img, 228)[0]
        print("frame %d: %ux%u fmt=0x%x stride=%u phys=0x%x framesize=%u"
              % (i, w, h, fmt, stride, phys, fsz), flush=True)
        if got == 3 and phys and fsz:
            sysl.AX_SYS_Mmap.restype = ctypes.c_void_p
            sysl.AX_SYS_Mmap.argtypes = [ctypes.c_uint64, ctypes.c_uint32]
            v = sysl.AX_SYS_Mmap(phys, fsz)
            if v:
                open("/tmp/frame4k.bin", "wb").write(ctypes.string_at(v, fsz))
                print("frame dumped: /tmp/frame4k.bin (%u bytes)" % fsz, flush=True)
        lib.kvm_cap_release(img)
    else:
        print("frame %d: rc=%d" % (i, rc), flush=True)

lib.kvm_cap_stop(ctx)
lib.kvm_sys_deinit(ctx)
print("done", flush=True)
