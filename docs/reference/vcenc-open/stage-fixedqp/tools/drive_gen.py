#!/usr/bin/env python3
# Drive libkvm through one H.264 encode under gen_hook.so (LD_PRELOAD), which
# overlays our from-scratch gen_idr.py image at LINK time. Capture the IDR NAL +
# SPS/PPS into a decodable single-I-frame stream, and read back swreg82 (HW cycle
# counter, proves the core actually ran our program) + swreg7.
# Args: <tag> [nframes] [bitrate]   (bitrate only affects libkvm's SPS/PPS baseline)
import ctypes,sys,os,struct,mmap,re,hashlib
LIB="/dev/shm/kvmapp/server/dl_lib/libkvm.so"
W,H=1920,1080; MARK=0x90101010; OUT="/tmp/axwork"
tag=sys.argv[1] if len(sys.argv)>1 else "gen"
NF=int(sys.argv[2]) if len(sys.argv)>2 else 6
BR=int(sys.argv[3]) if len(sys.argv)>3 else 8000

def venc_span():
    lo=hi=None
    for line in open("/proc/ax_proc/mem_cmm_info"):
        if "venc_ko" not in line: continue
        m=re.search(r"phys\(0x([0-9a-fA-F]+),\s*0x([0-9a-fA-F]+)\)",line)
        if m:
            a=int(m.group(1),16); b=int(m.group(2),16)
            lo=a if lo is None else min(lo,a); hi=b if hi is None else max(hi,b)
    return lo,hi
def mapwin(base,length):
    ps=0x1000; off=base&~(ps-1); d=base-off; ml=((d+length+ps-1)//ps)*ps
    fd=os.open("/dev/mem",os.O_RDONLY|os.O_SYNC)
    m=mmap.mmap(fd,ml,mmap.MAP_SHARED,mmap.PROT_READ,offset=off); return fd,m,d

lib=ctypes.CDLL(LIB)
lib.kvmv_init.argtypes=[ctypes.c_ubyte]
lib.kvmv_read_img.argtypes=[ctypes.c_uint16,ctypes.c_uint16,ctypes.c_ubyte,ctypes.c_uint16,
    ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)),ctypes.POINTER(ctypes.c_uint)]
lib.kvmv_read_img.restype=ctypes.c_int

print("=== drive_gen tag=%s nframes=%d br=%d ==="%(tag,NF,BR),flush=True)
lib.kvmv_init(1)
ptr=ctypes.POINTER(ctypes.c_ubyte)(); ln=ctypes.c_uint(0)
sps=pps=idr=None; sizes=[]
for i in range(NF):
    rc=lib.kvmv_read_img(W,H,3,BR,ctypes.byref(ptr),ctypes.byref(ln)); n=ln.value
    data=bytes(ptr[j] for j in range(n)) if n else b""
    if rc in (3,4): sizes.append((i,'I' if rc==3 else 'P',n))
    print("  read_img[%d] rc=%d len=%d"%(i,rc,n),flush=True)
    if rc==1 and sps is None: sps=data
    elif rc==2 and pps is None: pps=data
    elif rc==3 and idr is None:
        idr=data; break
if idr is None: print("!!! no IDR"); lib.kvmv_deinit(); sys.exit(1)
# decodable single-I-frame stream = SPS + PPS + IDR
stream=bytearray()
for part in (sps,pps,idr):
    if part: stream+=part
fn=os.path.join(OUT,"gen_%s.nal"%tag); open(fn,"wb").write(idr)
sfn=os.path.join(OUT,"gen_%s.h264"%tag); open(sfn,"wb").write(bytes(stream))
print("IDR NAL[%s]: %d bytes sha=%s -> %s"%(tag,len(idr),hashlib.sha256(idr).hexdigest()[:16],fn),flush=True)
print("stream[%s]: %d bytes (sps=%s pps=%s) -> %s"%(tag,len(stream),
      len(sps) if sps else 0,len(pps) if pps else 0,sfn),flush=True)
print("frame sizes:",sizes,flush=True)

lo,hi=venc_span(); fd,m,d=mapwin(lo,hi-lo+1)
mb=struct.pack("<I",MARK); i=d; base=None
while True:
    j=m.find(mb,i,d+(hi-lo))
    if j<0: break
    if (j-d)%4==0: base=lo+(j-d); break
    i=j+4
if base:
    def rd(k): return struct.unpack_from("<I",m,d+(base+k*4-lo))[0]
    print("post-encode reg image @0x%08x: swreg7=0x%08x(pic_init_qp=%d) swreg82(cc)=0x%08x swreg78=0x%08x"
          %(base,rd(7),(rd(7)>>26)&0x3f,rd(82),rd(78)),flush=True)
    with open(os.path.join(OUT,"gen_%s.regs"%tag),"w") as rf:
        for k in range(0,321): rf.write("swreg%-3d 0x%08x\n"%(k,rd(k)))
m.close(); os.close(fd)
lib.kvmv_deinit()
print("=== done %s ==="%tag,flush=True)
