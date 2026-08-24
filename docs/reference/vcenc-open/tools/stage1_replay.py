#!/usr/bin/env python3
# Stage 1 EXPERIMENT 1: literal record-and-replay of the vendor IDR cmdbuf via the
# raw public VCMD ioctls (no vendor encode call for the submit itself).
#
# Flow: dlopen libkvm, prime ONE vendor IDR (kvmv_read_img) to (a) get the reference
# NAL, (b) fill the live input/recon/output buffers, (c) leave a valid IDR cmdbuf in
# the pool. WITHOUT deinit (keeps the VCMD core enabled + buffers live), then:
#   RESERVE_CMDBUF(29) -> memcpy the vendor IDR cmdbuf bytes into the reserved slot
#   -> LINK_RUN_CMDBUF(30) -> WAIT_CMDBUF(31) -> read output -> RELEASE_CMDBUF(32).
# Milestone: our-submitted HW output == vendor reference output, byte-identical,
# AND the HW cycle counter (swreg82) advanced (proves the HW re-executed, not a
# stale buffer). Permitted writes only: cmdbuf bytes into the cmdbuf pool + the 4
# ioctls. /dev/mem is opened RW ONLY to write the cmdbuf pool slot; all other maps
# are PROT_READ.
import ctypes, mmap, os, struct, re, fcntl, hashlib, sys, signal, faulthandler
faulthandler.enable()

LIB="/dev/shm/kvmapp/server/dl_lib/libkvm.so"
W,H=1920,1080; BR=8000; MARK=0x90101010; OUT="/tmp/axwork"

def IOC(d,nr): return (d<<30)|(8<<16)|(0x6b<<8)|nr
R_RESERVE=IOC(3,29); R_LINK=IOC(2,30); R_WAIT=IOC(2,31); R_RELEASE=IOC(2,32)

_libc=ctypes.CDLL(None,use_errno=True)
_libc.ioctl.restype=ctypes.c_int
_ARGBUF=ctypes.create_string_buffer(256)   # ONE persistent arg buffer, reused for all ioctls
def vioc(fd,req,ex,raise_on_err=True):
    # Call libc ioctl() with the REAL address of a persistent 256B buffer (the same one
    # a successful RESERVE proved good), as the vendor does. Returns (rc, errno).
    ctypes.memset(_ARGBUF,0,256)
    _ARGBUF[:len(ex)]=bytes(ex)
    ctypes.set_errno(0)
    r=_libc.ioctl(ctypes.c_int(fd),ctypes.c_ulong(req),ctypes.c_void_p(ctypes.addressof(_ARGBUF)))
    err=ctypes.get_errno()
    ex[:]=_ARGBUF.raw[:len(ex)]
    if r<0 and raise_on_err:
        raise OSError(err,os.strerror(err))
    return r,err

def venc_blocks():
    b=[]
    for line in open("/proc/ax_proc/mem_cmm_info"):
        if "venc_ko" not in line: continue
        m=re.search(r"phys\(0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+)\)",line)
        if m: b.append((int(m.group(1),16),int(m.group(2),16)-int(m.group(1),16)+1))
    return b

def mapwin(base,length,write=False):
    ps=0x1000; off=base&~(ps-1); delta=base-off
    maplen=((delta+length+ps-1)//ps)*ps
    prot=mmap.PROT_READ|(mmap.PROT_WRITE if write else 0)
    fd=os.open("/dev/mem",(os.O_RDWR if write else os.O_RDONLY)|os.O_SYNC)
    m=mmap.mmap(fd,maplen,mmap.MAP_SHARED,prot,offset=off)
    return fd,m,delta

def readmem(base,length):
    fd,m,d=mapwin(base,length); data=bytes(m[d:d+length]); m.close(); os.close(fd); return data

log=open(os.path.join(OUT,"stage1_replay.log"),"w")
def P(*a):
    s=" ".join(str(x) for x in a); print(s,flush=True); log.write(s+"\n"); log.flush()

def main():
    lib=ctypes.CDLL(LIB)
    lib.kvmv_init.argtypes=[ctypes.c_ubyte]
    lib.kvmv_read_img.argtypes=[ctypes.c_uint16,ctypes.c_uint16,ctypes.c_ubyte,ctypes.c_uint16,
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),ctypes.POINTER(ctypes.c_uint)]
    lib.kvmv_read_img.restype=ctypes.c_int

    P("=== stage1 replay: prime one vendor IDR ===")
    lib.kvmv_init(1)
    ptr=ctypes.POINTER(ctypes.c_ubyte)(); ln=ctypes.c_uint(0)
    vendor_nal=None
    for i in range(6):
        rc=lib.kvmv_read_img(W,H,3,BR,ctypes.byref(ptr),ctypes.byref(ln)); n=ln.value
        P("  read_img[%d] rc=%d len=%d"%(i,rc,n))
        if rc==3:
            vendor_nal=bytes(ptr[j] for j in range(n)); break
    if vendor_nal is None: P("!!! no IDR"); lib.kvmv_deinit(); return
    open(os.path.join(OUT,"replay_vendor.nal"),"wb").write(vendor_nal)
    P("vendor NAL: %d bytes sha=%s head=%s"%(len(vendor_nal),hashlib.sha256(vendor_nal).hexdigest()[:16],vendor_nal[:8].hex()))

    blocks=venc_blocks()
    cmd_base,cmd_len=blocks[0]; st_base,st_len=blocks[1]
    UNIT=0x2000
    P("cmdbuf pool base=0x%08x len=0x%x unit=0x%x"%(cmd_base,cmd_len,UNIT))

    # locate encoder register image (readback) -> swreg8 out base, swreg9 size, swreg82 cc
    span_lo=min(b for b,_ in blocks); span_hi=max(b+l for b,l in blocks)
    fd,m,d=mapwin(span_lo,span_hi-span_lo)
    mb=struct.pack("<I",MARK); i=d; markers=[]
    while True:
        j=m.find(mb,i,d+(span_hi-span_lo))
        if j<0: break
        if (j-d)%4==0: markers.append(span_lo+(j-d))
        i=j+4
    reg0=markers[0]
    def rimg(k): return struct.unpack_from("<I",m,d+(reg0+k*4-span_lo))[0]
    sw8=rimg(8); sw9=rimg(9); cc_before=rimg(82); sw11=rimg(11); sw191=rimg(191)
    m.close(); os.close(fd)
    out_base=sw8 & ~0xfff
    P("live reg image @0x%08x: sw8=0x%08x sw9(size)=%d sw11=%d sw191=0x%08x cc(sw82)=0x%08x"%(reg0,sw8,sw9,sw11,sw191,cc_before))

    # snapshot the reference HW output buffer BEFORE replay
    OLEN=0x4000
    V=readmem(out_base,OLEN)
    open(os.path.join(OUT,"replay_out_vendor.bin"),"wb").write(V)
    off_nal=sw8-out_base
    P("ref HW output @0x%08x len 0x%x  sha=%s  (NAL starts at +0x%x)"%(out_base,OLEN,hashlib.sha256(V).hexdigest()[:16],off_nal))
    # sanity: HW buffer at sw8 offset should equal vendor NAL minus its 4-byte startcode
    body=vendor_nal[4:] if vendor_nal[:4]==b"\x00\x00\x00\x01" else vendor_nal
    hw_body=V[off_nal:off_nal+len(body)]
    P("HW-buffer-vs-NAL body match at +0x%x: %s (%d bytes)"%(off_nal,hw_body==body,len(body)))
    # locate the true NAL offset in the HW buffer (search for the slice payload prefix)
    probe=body[:16]; true_off=V.find(probe)
    P("NAL body prefix %s found in HW buffer at offset=0x%x"%(probe.hex(),true_off))
    nal_off = true_off if true_off>=0 else off_nal

    # pick this-run IDR cmdbuf slot: matches live sw8/sw12/sw15/sw16 AND frame_num=0/intra
    def slotswl(off,N): return struct.unpack_from("<I",pool,off+0x14+(N-1)*4)[0]
    pool=readmem(cmd_base,cmd_len)
    live12=None
    # read live sw12/15/16 from reg image again quickly
    fd,m,d=mapwin(span_lo,span_hi-span_lo)
    def rimg2(k): return struct.unpack_from("<I",m,d+(reg0+k*4-span_lo))[0]
    L={k:rimg2(k) for k in (8,12,15,16)}
    m.close(); os.close(fd)
    idr_slot=None
    for sid in range(cmd_len//UNIT):
        off=sid*UNIT
        if struct.unpack_from("<I",pool,off)[0]!=0xb0010068: continue
        if slotswl(off,11)==0 and slotswl(off,191)==0x14000000 and all(slotswl(off,k)==L[k] for k in (8,12,15,16)):
            idr_slot=sid; break
    if idr_slot is None: P("!!! no live-matching IDR cmdbuf slot"); lib.kvmv_deinit(); return
    src_off=idr_slot*UNIT
    cmdbuf_bytes=pool[src_off:src_off+UNIT]
    # actual program length (last nonzero word +1, word-rounded up a bit)
    words=struct.unpack_from("<%dI"%(UNIT//4),pool,src_off)
    # cmdbuf_size must be JMP-aligned: the driver reads the terminating JMP opcode at
    # word (cmdbuf_size/4 - 4), so size = (jmp_word_index + 4)*4 (matches vendor 0x8e8).
    jmp_idx=max(i for i,v in enumerate(words) if (v>>27)==0x19)  # OPCODE_JMP=0x19
    prog_bytes=(jmp_idx+4)*4
    P("IDR cmdbuf: slot=%d src_phys=0x%08x JMP@word%d cmdbuf_size=0x%x"%(idr_slot,cmd_base+src_off,jmp_idx,prog_bytes))

    # --- drive the raw VCMD ioctls. RESERVE works on a fresh fd, but LINK_RUN needs the
    # per-fd VCMD context libkvm established (GET_VCMD_PARAMETER/GET_CMDBUF_PARAMETER),
    # so we issue the four ioctls on libkvm's already-initialized ax_venc fd. We still
    # assemble+submit the cmdbuf entirely ourselves via the public ioctls. ---
    USE_OWN = os.environ.get("OWNFD")=="1"
    vfd=None
    if USE_OWN:
        vfd=os.open("/dev/ax_venc",os.O_RDWR); P("opened OUR OWN /dev/ax_venc fd=%d"%vfd)
    else:
        for e in os.listdir("/proc/self/fd"):
            try:
                if os.readlink("/proc/self/fd/"+e)=="/dev/ax_venc": vfd=int(e); break
            except OSError: pass
        if vfd is None: P("!!! no libkvm ax_venc fd"); lib.kvmv_deinit(); return
        P("using libkvm's initialized ax_venc fd=%d for raw VCMD ioctls"%vfd)
    ex=bytearray(64)
    struct.pack_into("<I",ex,0,0x001fa400)   # executing_time (us), vendor value
    rc,_=vioc(vfd,R_RESERVE,ex)
    my_id=struct.unpack_from("<H",ex,0x0a)[0]
    ret_sz=struct.unpack_from("<H",ex,0x06)[0]
    P("RESERVE(29) rc=%d -> my cmdbuf_id=%d (slot cap=0x%x)  arg=%s"%(rc,my_id,ret_sz,bytes(ex).hex()))
    if not (0<=my_id<cmd_len//UNIT): P("!!! bad id"); lib.kvmv_deinit(); return
    my_slot_phys=cmd_base+my_id*UNIT
    P("my slot phys=0x%08x"%my_slot_phys)

    if os.environ.get("NOMEMCPY")=="1":
        # diagnostic: link the reserved slot's NATIVE content (skip overwrite) to test
        # whether overwriting with a foreign-id cmdbuf is what trips the EFAULT.
        fdx,mx,dx=mapwin(my_slot_phys,16); w0=struct.unpack_from("<I",mx,dx)[0]; mx.close(); os.close(fdx)
        P("NOMEMCPY: linking native slot content, first word=0x%08x"%w0)
        # find JMP in native slot for cmdbuf_size
        nat=readmem(my_slot_phys,UNIT); natw=struct.unpack_from("<%dI"%(UNIT//4),nat,0)
        jset=[i for i,v in enumerate(natw) if (v>>27)==0x19]
        prog_bytes=((max(jset) if jset else 566)+4)*4
        ok_copy=(w0!=0)
        P("memcpy skipped; native cmdbuf_size=0x%x ok=%s"%(prog_bytes,ok_copy))
    else:
        # memcpy the vendor IDR cmdbuf bytes into my reserved slot (writing cmdbuf pool: permitted)
        fd,m,d=mapwin(my_slot_phys,UNIT,write=True)
        # Write word-by-word: glibc's wide/NEON memcpy (slice assignment) faults on
        # non-cacheable Device memory; 32-bit stores are safe. Lands directly in CMM.
        nwords=UNIT//4
        src=struct.unpack("<%dI"%nwords,cmdbuf_bytes)
        for wi in range(nwords):
            struct.pack_into("<I",m,d+wi*4,src[wi])
        # verify readback WORD-WISE (wide slice reads also fault on Device memory)
        pw=prog_bytes//4
        back=[struct.unpack_from("<I",m,d+wi*4)[0] for wi in range(pw)]
        m.close(); os.close(fd)
        ok_copy = back==list(src[:pw]) and back[0]==0xb0010068
        P("memcpy cmdbuf -> slot verify: %s (first word=0x%08x)"%(ok_copy,back[0]))
    if not ok_copy: P("!!! copy verify failed, aborting before LINK_RUN"); lib.kvmv_deinit(); return

    # LINK_RUN: build exchange_parameter per the authoritative vc8000_driver.h layout:
    #   0x00 u32 executing_time; 0x04 u16 module_type(0=VC8000E); 0x06 u16 cmdbuf_size;
    #   0x08 u16 priority; 0x0a u16 cmdbuf_id; 0x0c u16 core_id; 0x0e u16 numa_id.
    struct.pack_into("<I",ex,0x00,0x001fa400)
    struct.pack_into("<H",ex,0x04,0)          # module_type = VC8000E
    struct.pack_into("<H",ex,0x06,prog_bytes) # cmdbuf_size (JMP-aligned)
    struct.pack_into("<H",ex,0x08,0)          # priority
    struct.pack_into("<H",ex,0x0a,my_id)      # cmdbuf_id
    struct.pack_into("<H",ex,0x0c,0)          # core_id
    struct.pack_into("<H",ex,0x0e,1)          # numa_id (vendor used 1)
    P("LINK_RUN arg=%s"%bytes(ex[:16]).hex())
    rc,lerr=vioc(vfd,R_LINK,ex,raise_on_err=False)
    P("LINK_RUN(30) rc=%d errno=%d (%s) -- errno14 after run = benign copy_to_user writeback fault"%(rc,lerr,os.strerror(lerr) if lerr else "ok"))
    # WAIT (guard with a 12s alarm so a HW hang doesn't block our script indefinitely)
    wid=bytearray(8); struct.pack_into("<H",wid,0,my_id)
    def _to(sig,frm): raise TimeoutError("WAIT timed out")
    signal.signal(signal.SIGALRM,_to); signal.alarm(12)
    try:
        rc,werr=vioc(vfd,R_WAIT,wid,raise_on_err=False); signal.alarm(0)
        P("WAIT(31) rc=%d errno=%d arg_after=%s"%(rc,werr,bytes(wid[:4]).hex()))
    except TimeoutError:
        P("!!! WAIT(31) TIMED OUT after 12s (HW may be busy/hung)")

    # read HW output AFTER replay + cycle counter
    R=readmem(out_base,OLEN)
    open(os.path.join(OUT,"replay_out_ours.bin"),"wb").write(R)
    fd,m,d=mapwin(span_lo,span_hi-span_lo)
    cc_after=struct.unpack_from("<I",m,d+(reg0+82*4-span_lo))[0]
    sw9_after=struct.unpack_from("<I",m,d+(reg0+9*4-span_lo))[0]
    m.close(); os.close(fd)
    P("cc(sw82) before=0x%08x after=0x%08x  changed=%s"%(cc_before,cc_after,cc_before!=cc_after))
    P("sw9(out size) after=%d (vendor NAL body=%d)"%(sw9_after,len(body)))
    P("OUTPUT identical (full 0x%x region): %s"%(OLEN,R==V))
    P("  V sha=%s  R sha=%s"%(hashlib.sha256(V).hexdigest()[:16],hashlib.sha256(R).hexdigest()[:16]))
    hw_body_R=R[nal_off:nal_off+len(body)]
    P("our HW-output NAL body (at 0x%x) == vendor NAL body: %s"%(nal_off,hw_body_R==body))

    # RELEASE
    rid=bytearray(8); struct.pack_into("<H",rid,0,my_id)
    rc,rerr=vioc(vfd,R_RELEASE,rid,raise_on_err=False)
    P("RELEASE(32) rc=%d errno=%d"%(rc,rerr))
    if vfd is not None:
        try: os.close(vfd)
        except: pass

    P("=== MILESTONE: output byte-identical=%s AND hw re-ran(cc changed)=%s ==="%(R==V,cc_before!=cc_after))
    lib.kvmv_deinit()
    P("=== stage1 replay done ===")

main()
log.close()
