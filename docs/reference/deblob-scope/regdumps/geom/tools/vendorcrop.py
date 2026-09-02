import ctypes, sys, time, struct, mmap, os
w, h = int(sys.argv[1]), int(sys.argv[2]); out = sys.argv[3]
lib = ctypes.CDLL("/dev/shm/kvmapp/server/dl_lib/libkvm.so")
ctx = ctypes.create_string_buffer(4096)
assert lib.kvm_sys_init(ctx, w, h) == 0
assert lib.kvm_cap_start(ctx, w, h, 30) == 0
time.sleep(1.0)
img = ctypes.create_string_buffer(4096)
assert lib.kvm_cap_get(img, 1000) == 0
raw = img.raw
phys = None
for off in range(0, 512, 8):
    v = struct.unpack_from("<Q", raw, off)[0]
    if 0x73800000 <= v < 0x80000000: phys = v; break
print("frame phys %#x" % phys, flush=True)
size = w * h * 2
fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
pg = phys & ~0xfff
m = mmap.mmap(fd, size + (phys - pg), mmap.MAP_SHARED, mmap.PROT_READ, offset=pg)
data = bytes(m[phys - pg: phys - pg + size])
m.close(); os.close(fd)
open(out, "wb").write(data)
print("wrote", out, len(data), "first", data[:8].hex(), flush=True)
lib.kvm_cap_release(img); lib.kvm_cap_stop(ctx); lib.kvm_sys_deinit(ctx)
