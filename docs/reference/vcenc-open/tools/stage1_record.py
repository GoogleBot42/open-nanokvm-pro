#!/usr/bin/env python3
# Stage 1 RECORD phase. Prime ONE vendor IDR via libkvm (with stage1trace.so
# LD_PRELOAD'd to capture the exact VCMD ioctl arg structs), then snapshot, all
# from valid live vendor allocations:
#   - vendor IDR NAL (from kvmv_read_img return)              -> vendor_idr.nal
#   - venc_ko cmdbuf pool (block0, 64KB, holds the IDR cmdbuf) -> vendor_cmdbuf_pool.bin
#   - venc_ko status/register pool (block1, 64KB)              -> vendor_status_pool.bin
#   - the encoder register image (marker 0x90101010): swreg8 output base, swreg9
#     size, swreg12 input-Y, swreg82 cycle counter               -> stage1_meta.txt
#   - the raw HW output stream buffer (swreg8 base, NAL length)  -> vendor_out.bin
# Read-only w.r.t. device memory (all /dev/mem maps are PROT_READ).
import ctypes, mmap, os, struct, re

LIB="/dev/shm/kvmapp/server/dl_lib/libkvm.so"
W,H=1920,1080
BR=8000
MARK=0x90101010
OUT="/tmp/axwork"

def venc_blocks():
    b=[]
    for line in open("/proc/ax_proc/mem_cmm_info"):
        if "venc_ko" not in line: continue
        m=re.search(r"phys\(0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+)\)",line)
        if m:
            lo=int(m.group(1),16); hi=int(m.group(2),16); b.append((lo,hi-lo+1))
    return b

def mapwin(base,length,write=False):
    ps=0x1000; off=base&~(ps-1); delta=base-off
    maplen=((delta+length+ps-1)//ps)*ps
    prot=mmap.PROT_READ|(mmap.PROT_WRITE if write else 0)
    fd=os.open("/dev/mem",(os.O_RDWR if write else os.O_RDONLY)|os.O_SYNC)
    m=mmap.mmap(fd,maplen,mmap.MAP_SHARED,prot,offset=off)
    return fd,m,delta

def readmem(base,length):
    fd,m,delta=mapwin(base,length)
    data=m[delta:delta+length]
    m.close(); os.close(fd)
    return bytes(data)

def main():
    os.makedirs(OUT,exist_ok=True)
    log=open(os.path.join(OUT,"stage1_meta.txt"),"w")
    def P(*a):
        s=" ".join(str(x) for x in a); print(s,flush=True); log.write(s+"\n"); log.flush()

    lib=ctypes.CDLL(LIB)
    lib.kvmv_init.argtypes=[ctypes.c_ubyte]
    lib.kvmv_read_img.argtypes=[ctypes.c_uint16,ctypes.c_uint16,ctypes.c_ubyte,ctypes.c_uint16,
        ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),ctypes.POINTER(ctypes.c_uint)]
    lib.kvmv_read_img.restype=ctypes.c_int

    P("=== stage1 record: init + one vendor IDR @%d kbps ===" % BR)
    lib.kvmv_init(1)
    ptr=ctypes.POINTER(ctypes.c_ubyte)(); ln=ctypes.c_uint(0)
    idr=None
    for i in range(6):
        rc=lib.kvmv_read_img(W,H,3,BR,ctypes.byref(ptr),ctypes.byref(ln))
        n=ln.value
        P("read_img[%d] rc=%d len=%d" % (i,rc,n))
        if rc==3:   # IDR/I slice
            idr=bytes(ptr[j] for j in range(n))
            break
    if idr is None:
        P("!!! no IDR obtained"); lib.kvmv_deinit(); return
    with open(os.path.join(OUT,"vendor_idr.nal"),"wb") as f: f.write(idr)
    P("vendor IDR NAL saved: %d bytes, head=%s" % (len(idr), idr[:8].hex()))

    blocks=venc_blocks()
    P("venc_ko blocks:", ["0x%08x/0x%x"%(b,l) for b,l in blocks])
    cmd_base,cmd_len=blocks[0]
    st_base,st_len=blocks[1]

    # snapshot the two 64KB pools (cmdbuf holds the IDR cmdbuf; status holds reg image)
    with open(os.path.join(OUT,"vendor_cmdbuf_pool.bin"),"wb") as f: f.write(readmem(cmd_base,cmd_len))
    with open(os.path.join(OUT,"vendor_status_pool.bin"),"wb") as f: f.write(readmem(st_base,st_len))
    P("saved cmdbuf pool 0x%08x/0x%x and status pool 0x%08x/0x%x" % (cmd_base,cmd_len,st_base,st_len))

    # locate encoder register image marker inside the venc_ko span
    span_lo=min(b for b,_ in blocks); span_hi=max(b+l for b,l in blocks)
    fd,m,delta=mapwin(span_lo,span_hi-span_lo)
    mb=struct.pack("<I",MARK); i=delta; markers=[]
    while True:
        j=m.find(mb,i,delta+(span_hi-span_lo))
        if j<0: break
        if (j-delta)%4==0: markers.append(span_lo+(j-delta))
        i=j+4
    P("register-image markers:", ["0x%08x"%x for x in markers])
    reg0=markers[0]
    def rd(phys): return struct.unpack_from("<I",m,delta+(phys-span_lo))[0]
    sw={k:rd(reg0+k*4) for k in range(0,401)}
    m.close(); os.close(fd)
    out_base=sw[8]; out_sz9=sw[9]; in_y=sw[12]; cc=sw[82]
    P("reg image @0x%08x: swreg8(OUTPUT_STRM_BASE)=0x%08x swreg9(size)=0x%08x swreg12(INPUT_Y)=0x%08x swreg82(cc)=0x%08x"
      % (reg0,out_base,out_sz9,in_y,cc))
    P("swreg5(ctrl)=0x%08x swreg11(frame_num)=0x%08x swreg191(type)=0x%08x swreg10=0x%08x swreg15=0x%08x swreg16=0x%08x"
      % (sw[5],sw[11],sw[191],sw[10],sw[15],sw[16]))

    # dump the raw HW output stream buffer. swreg8 low bits are a bit-offset; page-align.
    ob=out_base & ~0xfff
    # read enough to cover the NAL (len(idr)) plus slack
    rdlen=((len(idr)+0x2000+0xfff)//0x1000)*0x1000
    obuf=readmem(ob,rdlen)
    with open(os.path.join(OUT,"vendor_out.bin"),"wb") as f: f.write(obuf)
    P("saved raw HW output buffer @0x%08x len 0x%x (swreg8 aligned from 0x%08x)" % (ob,rdlen,out_base))
    P("=== stage1 record done ===")
    lib.kvmv_deinit()
    log.close()

main()
