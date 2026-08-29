#!/usr/bin/env python3
"""Parse a baseline H.264 PPS RBSP and rewrite pic_init_qp_minus26.
Used to emit a PPS whose pic_init_qp matches our generator's sw7, so a decoder
reconstructs the correct SliceQP for our from-scratch fixed-QP IDR."""
import struct,sys

class BR:
    def __init__(s,b): s.b=b; s.p=0
    def u1(s):
        byte=s.b[s.p>>3]; bit=(byte>>(7-(s.p&7)))&1; s.p+=1; return bit
    def u(s,n):
        v=0
        for _ in range(n): v=(v<<1)|s.u1()
        return v
    def ue(s):
        z=0
        while s.u1()==0: z+=1
        v=0
        for _ in range(z): v=(v<<1)|s.u1()
        return (1<<z)-1+v
    def se(s):
        k=s.ue();
        return (k+1)//2 if k&1 else -(k//2)

class BW:
    def __init__(s): s.bits=[]
    def u1(s,x): s.bits.append(x&1)
    def u(s,x,n):
        for i in range(n-1,-1,-1): s.u1((x>>i)&1)
    def ue(s,v):
        v+=1; n=v.bit_length()
        for _ in range(n-1): s.u1(0)
        for i in range(n-1,-1,-1): s.u1((v>>i)&1)
    def se(s,v):
        k=2*v-1 if v>0 else -2*v
        s.ue(k)
    def bytes(s):
        b=list(s.bits); b.append(1)                 # rbsp_stop_one_bit
        while len(b)%8: b.append(0)
        out=bytearray()
        for i in range(0,len(b),8):
            byte=0
            for j in range(8): byte=(byte<<1)|b[i+j]
            out.append(byte)
        return bytes(out)

def patch_pps(rbsp, new_qp):
    r=BR(rbsp); w=BW()
    pps_id=r.ue(); w.ue(pps_id)
    sps_id=r.ue(); w.ue(sps_id)
    ecm=r.u1();  w.u1(ecm)
    bf=r.u1();   w.u1(bf)
    nsg=r.ue();  w.ue(nsg)
    if nsg>0: raise SystemExit("slice groups unsupported")
    n0=r.ue();   w.ue(n0)
    n1=r.ue();   w.ue(n1)
    wp=r.u1();   w.u1(wp)
    wb=r.u(2);   w.u(wb,2)
    piq=r.se();  old=26+piq
    w.se(new_qp-26)                                  # <-- rewrite pic_init_qp_minus26
    pis=r.se();  w.se(pis)
    cqo=r.se();  w.se(cqo)
    dbf=r.u1();  w.u1(dbf)
    cip=r.u1();  w.u1(cip)
    rpc=r.u1();  w.u1(rpc)
    return w.bytes(), old

if __name__=='__main__':
    # self-test on the captured libkvm PPS: ee 06 72 (pic_init_qp should be 32)
    orig=bytes([0xee,0x06,0x72])
    same,old=patch_pps(orig,old if False else 32)
    print("captured PPS pic_init_qp=%d, round-trip=%s (%s vs %s)"%(
        old, same==orig, same.hex(), orig.hex()))
