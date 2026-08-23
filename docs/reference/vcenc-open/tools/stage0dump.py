#!/usr/bin/env python3
# Stage 0 "finish the static picture" — read-only, on-device.
# Artifact 1: extend the encoder register-image dump to swreg400.
# Artifact 2: decode the VCMD WREG order for one IDR frame (cmdbuf).
# Artifact 3: decode a P-frame cmdbuf + register image; diff vs IDR for DPB/ref state.
#
# Method: drive H.264 headless via libkvm (GOP 30, encode enough frames to emit a
# P-frame). After the IDR frame AND after a chosen P-frame, snapshot the venc_ko
# VCMD pools from /dev/mem: (a) the encoder register-image mirror (marker
# 0x90101010) dumped swreg0..400, and (b) the cmdbuf pool decoded into ordered
# WREG bursts. venc_ko pool bases are parsed live from /proc/ax_proc/mem_cmm_info.
# Everything is written to /tmp/axwork FIRST (SSH-drop safe). NO writes to device
# memory anywhere.
import ctypes, mmap, os, struct, sys, re

LIB   = "/dev/shm/kvmapp/server/dl_lib/libkvm.so"
W, H  = 1920, 1080
MARK  = 0x90101010
BR    = 8000
NFRAMES = 40
GOP   = 30
OUT   = "/tmp/axwork"
REGWORDS = 401           # swreg0..400 inclusive

# ---- parse venc_ko CMM blocks (dynamic per run) ----
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

# ---- /dev/mem window helpers ----
def mapwin(base, length):
    ps = 0x1000
    off = base & ~(ps - 1); delta = base - off
    maplen = ((delta + length + ps - 1) // ps) * ps
    fd = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
    m = mmap.mmap(fd, maplen, mmap.MAP_SHARED, mmap.PROT_READ, offset=off)
    return fd, m, delta

def find_markers(base, length):
    """Return list of absolute phys of every 4-aligned 0x90101010 in [base,base+length)."""
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
    """Dump swreg0..nwords-1 at markphys with absolute phys per word."""
    length = nwords * 4 + 0x40
    fd, m, delta = mapwin(markphys, length)
    lines = []
    words = []
    for i in range(nwords):
        phys = markphys + i * 4
        v = struct.unpack_from("<I", m, delta + (phys - markphys))[0]
        words.append(v)
        lines.append("phys=0x%08x  +0x%03x  swreg%-3d  0x%08x" % (phys, i*4, i, v))
    m.close(); os.close(fd)
    return words, lines

# ---- VCMD cmdbuf decode (WREG=0x01 is the trustworthy opcode; others best-effort) ----
OPC = {0x01:"WREG", 0x02:"END", 0x03:"NOP", 0x08:"JMP", 0x09:"STALL",
       0x0A:"CLRINT", 0x0B:"JMP_RDY", 0x0C:"RREG?", 0x0E:"INT", 0x14:"INT2",
       0x16:"RREG2?"}

def decode_cmdbuf(base, length):
    """Decode the cmdbuf; return (text_lines, wreg_program) where wreg_program is a
    list of (write_order_index, reg_byte_addr, swreg_index, value) in WRITE ORDER."""
    fd, m, delta = mapwin(base, length)
    w = [struct.unpack_from("<I", m, delta + o)[0] for o in range(0, length, 4)]
    m.close(); os.close(fd)
    nz = [i for i, v in enumerate(w) if v != 0]
    lines = []; prog = []
    if not nz:
        return ["(cmdbuf all zero)"], prog
    lo, hi = nz[0], nz[-1]
    lines.append("cmdbuf @0x%08x nonzero words %d..%d (byte 0x%x..0x%x)" % (base, lo, hi, lo*4, hi*4))
    i = lo; guard = 0; order = 0
    while i <= hi and guard < 4000:
        guard += 1
        cw = w[i]
        op = (cw >> 27) & 0x1f
        name = OPC.get(op, "op0x%02x" % op)
        if op == 0x01:  # WREG — addr(byte) in [15:0], length(words) in [25:16]
            length_w = (cw >> 16) & 0x3ff
            addr = cw & 0xffff
            lines.append("  [%04x] %08x  WREG addr=0x%04x(byte) swreg%d len=%d" %
                         (i*4, cw, addr, addr // 4, length_w))
            for k in range(length_w):
                if i+1+k <= hi:
                    val = w[i+1+k]
                    baddr = addr + k*4
                    swi = baddr // 4
                    prog.append((order, baddr, swi, val))
                    order += 1
                    lines.append("     +%03d swreg%-3d (byte0x%04x) <= 0x%08x" % (k, swi, baddr, val))
            i += 1 + length_w
            continue
        lines.append("  [%04x] %08x  %s" % (i*4, cw, name))
        i += 1
        if op == 0x02:  # END
            break
    return lines, prog

# ---- driver ----
def main():
    os.makedirs(OUT, exist_ok=True)
    log = open(os.path.join(OUT, "stage0.log"), "w")
    def P(*a):
        s = " ".join(str(x) for x in a)
        print(s, flush=True); log.write(s + "\n"); log.flush()

    lib = ctypes.CDLL(LIB)
    lib.kvmv_init.argtypes = [ctypes.c_ubyte]
    try:
        lib.kvmv_set_gop.argtypes = [ctypes.c_ubyte]
    except Exception:
        pass
    lib.kvmv_read_img.argtypes = [ctypes.c_uint16, ctypes.c_uint16, ctypes.c_ubyte, ctypes.c_uint16,
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)), ctypes.POINTER(ctypes.c_uint)]
    lib.kvmv_read_img.restype = ctypes.c_int

    P("=== stage0: init, GOP=%d, bitrate=%d kbps, encode up to %d frames ===" % (GOP, BR, NFRAMES))
    lib.kvmv_init(1)
    try:
        lib.kvmv_set_gop(GOP)
        P("kvmv_set_gop(%d) ok" % GOP)
    except Exception as e:
        P("kvmv_set_gop unavailable:", e)

    blocks = venc_blocks()
    P("venc_ko blocks:", ["0x%08x/0x%x" % (b, l) for b, l in blocks])
    # cmdbuf pool = first venc_ko block; register-image mirror lives in the pools too.
    CMDBUF_BASE, CMDBUF_LEN = blocks[0]
    # union span of all venc_ko blocks for marker scan
    span_lo = min(b for b, _ in blocks)
    span_hi = max(b + l for b, l in blocks)
    SCAN_BASE, SCAN_LEN = span_lo, span_hi - span_lo
    P("cmdbuf pool = 0x%08x len 0x%x ; marker-scan span 0x%08x..0x%08x" %
      (CMDBUF_BASE, CMDBUF_LEN, span_lo, span_hi))

    ptr = ctypes.POINTER(ctypes.c_ubyte)(); ln = ctypes.c_uint(0)

    def snapshot(tag):
        P("--- SNAPSHOT %s ---" % tag)
        markers = find_markers(SCAN_BASE, SCAN_LEN)
        P("%s: 0x90101010 markers found: %s" % (tag, ["0x%08x" % x for x in markers]))
        # dump register image at every marker; the primary is the first
        allwords = {}
        for mi, mk in enumerate(markers):
            words, lines = dump_regimage(mk, REGWORDS)
            allwords[mk] = words
            fn = os.path.join(OUT, "regimg_%s_m%d_0x%08x.txt" % (tag, mi, mk))
            with open(fn, "w") as f:
                f.write("# register image marker#%d @0x%08x  swreg0..%d\n" % (mi, mk, REGWORDS-1))
                f.write("\n".join(lines) + "\n")
            # note nonzero in swreg320..400
            hi_nz = [(320+k, words[320+k]) for k in range(REGWORDS-320) if words[320+k] != 0]
            P("  regimg %s m%d @0x%08x -> %s ; swreg320..400 nonzero: %s" %
              (tag, mi, mk, fn, ["swreg%d=0x%08x" % t for t in hi_nz]))
        # decode cmdbuf
        clines, prog = decode_cmdbuf(CMDBUF_BASE, CMDBUF_LEN)
        fn = os.path.join(OUT, "cmdbuf_%s.txt" % tag)
        with open(fn, "w") as f:
            f.write("\n".join(clines) + "\n\n")
            f.write("=== ORDERED WREG PROGRAM (write_order: swreg <= value) ===\n")
            for (o, baddr, swi, val) in prog:
                f.write("%04d  swreg%-3d (byte0x%04x) <= 0x%08x\n" % (o, swi, baddr, val))
        P("  cmdbuf %s decoded -> %s ; %d WREG writes" % (tag, fn, len(prog)))
        return markers, allwords, prog

    # encode frames; snapshot after IDR (first I) and after a late P-frame
    idr_snap = None; p_snap = None
    kinds = []
    for i in range(NFRAMES):
        rc = lib.kvmv_read_img(W, H, 3, BR, ctypes.byref(ptr), ctypes.byref(ln))
        kinds.append((i, rc, ln.value))
        # rc: 1=SPS 2=PPS 3=I/IDR 4=P
        if rc == 3 and idr_snap is None:
            P("frame %d: IDR (len=%d) -> snapshotting" % (i, ln.value))
            idr_snap = snapshot("IDR")
        if i == NFRAMES - 1:
            # ensure last is a P-frame; if not, encode a couple more
            pass
    # frame kinds summary
    P("frame kinds (idx,rc,len):", kinds[:8], "...", kinds[-6:])
    # snapshot a P-frame: do one more read (guaranteed P mid-GOP), then snapshot
    rc = lib.kvmv_read_img(W, H, 3, BR, ctypes.byref(ptr), ctypes.byref(ln))
    P("extra frame rc=%d len=%d (expect P=4)" % (rc, ln.value))
    if rc == 4:
        p_snap = snapshot("P")
    else:
        # try again to land on a P
        for _ in range(5):
            rc = lib.kvmv_read_img(W, H, 3, BR, ctypes.byref(ptr), ctypes.byref(ln))
            if rc == 4:
                P("landed on P rc=%d len=%d" % (rc, ln.value))
                p_snap = snapshot("P"); break

    # ---- IDR vs P register-image diff (primary marker = first) ----
    if idr_snap and p_snap:
        idr_mk = idr_snap[0][0]; p_mk = p_snap[0][0]
        idr_words = idr_snap[1][idr_mk]; p_words = p_snap[1][p_mk]
        P("=== IDR vs P register-image diff (IDR m0 @0x%08x vs P m0 @0x%08x) ===" % (idr_mk, p_mk))
        difflines = []
        for k in range(REGWORDS):
            a = idr_words[k]; b = p_words[k]
            if a != b:
                difflines.append("swreg%-3d  IDR=0x%08x  P=0x%08x" % (k, a, b))
                P("  swreg%-3d  IDR=0x%08x  P=0x%08x" % (k, a, b))
        with open(os.path.join(OUT, "diff_IDR_vs_P.txt"), "w") as f:
            f.write("# IDR marker 0x%08x vs P marker 0x%08x\n" % (idr_mk, p_mk))
            f.write("\n".join(difflines) + "\n")
        P("diff written: %d registers differ -> %s/diff_IDR_vs_P.txt" %
          (len(difflines), OUT))

    try:
        lib.kvmv_deinit()
    except Exception:
        pass
    P("=== stage0 done ===")
    log.close()

main()
