import ctypes, sys, time, subprocess, os
w, h = int(sys.argv[1]), int(sys.argv[2])
tag = "fake-%dx%d" % (w, h)
lib = ctypes.CDLL("/dev/shm/kvmapp/server/dl_lib/libkvm.so")
ctx = ctypes.create_string_buffer(4096)
r = lib.kvm_sys_init(ctx, w, h); print(tag, "sys_init", r, flush=True)
if r == 0:
    r2 = lib.kvm_cap_start(ctx, w, h, 30); print(tag, "cap_start", r2, flush=True)
    time.sleep(1.5)
    os.chdir("/root/axbring")
    for base, ln in (("0x02400000", "0xd4008"), ("0x02600000", "0x4000"), ("0x02500000", "0x800")):
        with open("geo/%s-%s.bin" % (tag, base[2:]), "wb") as f:
            subprocess.run(["./dumpreg", base, ln], stdout=f)
    img = ctypes.create_string_buffer(4096)
    g = lib.kvm_cap_get(img, 800); print(tag, "cap_get", g, flush=True)
    if g == 0:
        got = 0
        for i in range(10):
            lib.kvm_cap_release(img)
            if lib.kvm_cap_get(img, 300) == 0: got += 1
        print(tag, "more frames", got, flush=True)
        lib.kvm_cap_release(img)
    lib.kvm_cap_stop(ctx); print(tag, "stopped", flush=True)
lib.kvm_sys_deinit(ctx); print(tag, "deinit", flush=True)
