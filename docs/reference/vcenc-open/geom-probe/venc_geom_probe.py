#!/usr/bin/env python3
# Vendor-encoder geometry probe (#17 differential): drive the VENDOR AX_VENC
# through the deployed libkvm.so's exported kvm_venc_* wrappers at an arbitrary
# WxH with a synthetic CMM YUYV frame (UNLINK mode -- no capture involvement),
# then dump the VC8000E register-image mirror(s) from the venc_ko CMM pools.
# Usage: venc_geom_probe.py <W> <H> <tag>   (run with nanokvm.service stopped)
import ctypes, mmap, os, struct, sys, re

W, H, TAG = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
LIB   = "/dev/shm/kvmapp/server/dl_lib/libkvm.so"
MARK  = 0x90101010
OUT   = "/tmp/geomprobe"
REGWORDS = 401
CHN   = 7
PT_H264 = 96
FMT_YUYV = 0x0D
AX_ID_VIN = 0x11

os.makedirs(OUT, exist_ok=True)
log = open(os.path.join(OUT, "probe_%s.log" % TAG), "w")
def P(*a):
    s = " ".join(str(x) for x in a)
    print(s, flush=True); log.write(s + "\n"); log.flush()

# ---- CMM pool scan helpers (from stage0dump.py, unchanged method) ----
def venc_blocks():
    blocks = []
    with open("/proc/ax_proc/mem_cmm_info") as f:
        for line in f:
            if "venc_ko" not in line:
                continue
            m = re.search(r"phys\(0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+)\)", line)
            if m:
                lo = int(m.group(1), 16); hi = int(m.group(2), 16)
                blocks.append((lo, hi - lo + 1))
    return blocks

def mapwin(base, length):
    ps = 0x1000
    off = base & ~(ps - 1); delta = base - off
    maplen = ((delta + length + ps - 1) // ps) * ps
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    m = mmap.mmap(fd, maplen, mmap.MAP_SHARED, mmap.PROT_READ, offset=off)
    return fd, m, delta

def find_markers(base, length):
    fd, m, delta = mapwin(base, length)
    mb = struct.pack("<I", MARK); found = []; i = delta
    end = delta + length
    while True:
        j = m.find(mb, i, end)
        if j < 0: break
        if (j - delta) % 4 == 0:
            found.append(base + (j - delta))
        i = j + 4
    m.close(); os.close(fd)
    return found

def dump_regimage(markphys, nwords):
    length = nwords * 4 + 0x40
    fd, m, delta = mapwin(markphys, length)
    lines = []; words = []
    for i in range(nwords):
        v = struct.unpack_from("<I", m, delta + i * 4)[0]
        words.append(v)
        lines.append("phys=0x%08x  +0x%03x  swreg%-3d  0x%08x" %
                     (markphys + i*4, i*4, i, v))
    m.close(); os.close(fd)
    return words, lines

def snapshot(tag):
    blocks = venc_blocks()
    if not blocks:
        P("!! no venc_ko CMM blocks"); return
    # raw cmdbuf pool (first venc_ko block): the WREG programs, decoded offline
    cb, cl = blocks[0]
    fd, m, delta = mapwin(cb, cl)
    fn = os.path.join(OUT, "cmdpool_%s_%s_0x%08x.bin" % (TAG, tag, cb))
    with open(fn, "wb") as f:
        f.write(m[delta:delta+cl])
    m.close(); os.close(fd)
    P("  cmdpool %s -> %s (0x%x bytes)" % (tag, fn, cl))
    span_lo = min(b for b, _ in blocks)
    span_hi = max(b + l for b, l in blocks)
    markers = find_markers(span_lo, span_hi - span_lo)
    P("%s markers: %s" % (tag, ["0x%08x" % x for x in markers]))
    for mi, mk in enumerate(markers):
        words, lines = dump_regimage(mk, REGWORDS)
        fn = os.path.join(OUT, "regimg_%s_%s_m%d_0x%08x.txt" % (TAG, tag, mi, mk))
        with open(fn, "w") as f:
            f.write("# %s marker#%d @0x%08x swreg0..%d  (%dx%d)\n" %
                    (TAG, mi, mk, REGWORDS-1, W, H))
            f.write("\n".join(lines) + "\n")
        P("  -> %s (sw2=0x%08x sw210=0x%08x sw237=0x%08x sw261=0x%08x)" %
          (fn, words[2], words[210], words[237], words[261]))

# ---- vendor encode session over exported libkvm internals ----
lib = ctypes.CDLL(LIB, mode=ctypes.RTLD_GLOBAL)
sysl = ctypes.CDLL("/opt/lib/libax_sys.so", mode=ctypes.RTLD_GLOBAL)
rc = sysl.AX_SYS_Init()
P("AX_SYS_Init rc=%d" % rc)

lib.kvm_venc_create.argtypes = [ctypes.c_int]*8
rc = lib.kvm_venc_create(CHN, PT_H264, W, H, 60, 30, 8000, 0)
P("kvm_venc_create(%d, H264, %dx%d, fps60 gop30 8000kbps CBR) rc=%d" % (CHN, W, H, rc))
if rc != 0:
    sys.exit(1)

# synthetic YUYV input frame from a REAL AX_POOL block (the venc validates
# u32BlkId against the kernel pool module -- MemAlloc phys + fake id = Fail2)
size = W * H * 2
poolcfg = (ctypes.c_ubyte * 96)()
struct.pack_into("<Q", poolcfg, 0, 4096)      # MetaSize
struct.pack_into("<Q", poolcfg, 8, size)      # BlkSize
struct.pack_into("<I", poolcfg, 16, 2)        # BlkCnt
struct.pack_into("<I", poolcfg, 20, 0)        # IsMergeMode
struct.pack_into("<I", poolcfg, 24, 0)        # CacheMode NONCACHE
name = b"anonymous"
poolcfg[28:28+len(name)] = name               # PartitionName
poolcfg[60:60+9] = b"geomprobe"               # PoolName
sysl.AX_POOL_CreatePool.restype = ctypes.c_uint32
pool = sysl.AX_POOL_CreatePool(poolcfg)
P("AX_POOL_CreatePool rc/id=0x%x" % pool)
if pool == 0xFFFFFFFF:
    sys.exit(1)
sysl.AX_POOL_GetBlock.restype = ctypes.c_uint32
sysl.AX_POOL_GetBlock.argtypes = [ctypes.c_uint32, ctypes.c_uint64, ctypes.c_char_p]
blk = sysl.AX_POOL_GetBlock(pool, size, None)
sysl.AX_POOL_Handle2PhysAddr.restype = ctypes.c_uint64
sysl.AX_POOL_Handle2PhysAddr.argtypes = [ctypes.c_uint32]
physv = sysl.AX_POOL_Handle2PhysAddr(blk)
sysl.AX_SYS_Mmap.restype = ctypes.c_void_p
sysl.AX_SYS_Mmap.argtypes = [ctypes.c_uint64, ctypes.c_uint32]
virtv = sysl.AX_SYS_Mmap(physv, size)
P("blk=0x%x phys=0x%x virt=0x%x" % (blk, physv, virtv or 0))
if not physv or not virtv:
    sys.exit(1)
phys = ctypes.c_uint64(physv); virt = ctypes.c_void_p(virtv)

# test card: horizontal luma gradient + 64px block stripes, neutral chroma
row = bytearray(W * 2)
for x in range(W):
    y = (x * 255 // max(1, W - 1)) ^ (0x40 if (x // 64) & 1 else 0)
    row[2*x] = y & 0xFF; row[2*x + 1] = 0x80
buf = (ctypes.c_ubyte * (W * 2)).from_buffer(row)
for r in range(H):
    ctypes.memmove(virt.value + r * W * 2, buf, W * 2)
P("frame filled")

# AX_VIDEO_FRAME_INFO_T (240 B): offsets from the V3.0.0 SDK headers
fi = (ctypes.c_ubyte * 240)()
struct.pack_into("<I", fi, 0, W)            # u32Width
struct.pack_into("<I", fi, 4, H)            # u32Height
struct.pack_into("<I", fi, 8, FMT_YUYV)     # enImgFormat
struct.pack_into("<I", fi, 32, W)           # u32PicStride[0] (pixels)
struct.pack_into("<Q", fi, 56, phys.value)  # u64PhyAddr[0]
struct.pack_into("<I", fi, 164, blk)        # u32BlkId[0] (real pool block)
struct.pack_into("<I", fi, 228, size)       # u32FrameSize
struct.pack_into("<I", fi, 232, AX_ID_VIN)  # enModId

st = (ctypes.c_ubyte * 816)()
lib.kvm_venc_send.argtypes = [ctypes.c_int, ctypes.c_void_p]
lib.kvm_venc_get.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
lib.kvm_venc_release.argtypes = [ctypes.c_int, ctypes.c_void_p]

did_idr = did_p = False
for i in range(6):
    struct.pack_into("<Q", fi, 192, i * 16667)   # u64PTS
    struct.pack_into("<Q", fi, 200, i + 1)       # u64SeqNum
    rc = lib.kvm_venc_send(CHN, fi)
    rg = lib.kvm_venc_get(CHN, st, 2000)
    ln = struct.unpack_from("<I", st, 16)[0]
    ct = struct.unpack_from("<I", st, 52)[0]
    P("frame %d: send rc=%d get rc=%d len=%d coding=%d" % (i, rc, rg & 0xFFFFFFFF, ln, ct))
    if i == 2:
        P("---- /proc/ax_proc/venc mid-session ----")
        P(open("/proc/ax_proc/venc").read())
    if rg == 0:
        # coding: 1=I? use IDR heuristics -- first frame is IDR
        if i == 0 and not did_idr:
            snapshot("IDR"); did_idr = True
        elif i >= 1 and not did_p:
            snapshot("P"); did_p = True
        lib.kvm_venc_release(CHN, st)

lib.kvm_venc_destroy.argtypes = [ctypes.c_int]
lib.kvm_venc_destroy(CHN)
lib.kvm_venc_module_deinit()
P("done %s %dx%d" % (TAG, W, H))
