#!/usr/bin/env python3
# Rewrite the PPS pic_init_qp in an annex-B stream to a target QP, so a decoder
# reconstructs the correct SliceQP for our from-scratch fixed-QP IDR.
import sys
sys.path.insert(0,'.')
from pps_patch import patch_pps

def split_nals(b):
    idx=[]; i=0
    while i<len(b)-3:
        if b[i]==0 and b[i+1]==0 and b[i+2]==0 and b[i+3]==1: idx.append(i); i+=4
        elif b[i]==0 and b[i+1]==0 and b[i+2]==1: idx.append(i); i+=3
        else: i+=1
    idx.append(len(b))
    return idx

def main(inp,outp,qp):
    b=bytearray(open(inp,'rb').read())
    idx=split_nals(b)
    out=bytearray()
    for k in range(len(idx)-1):
        s=idx[k]; e=idx[k+1]
        sc=4 if b[s+2]==0 else 3
        nal=b[s+sc:e]
        ntype=nal[0]&0x1f
        if ntype==8:  # PPS
            new_rbsp,old=patch_pps(bytes(nal[1:]),qp)
            nal=bytes([nal[0]])+new_rbsp
            print("  PPS pic_init_qp %d -> %d"%(old,qp))
        out+=b[s:s+sc]+nal
    open(outp,'wb').write(out)

if __name__=='__main__':
    main(sys.argv[1],sys.argv[2],int(sys.argv[3]))
