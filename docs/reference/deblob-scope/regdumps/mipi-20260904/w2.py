import struct,os
D=os.path.dirname(os.path.abspath(__file__))+"/device"
def ld(t,s,b):
    p=f"{D}/{t}-{s}-{b}.bin"; 
    if not os.path.exists(p): return None
    d=open(p,"rb").read(); return struct.unpack("<%dI"%(len(d)//4),d)
runs=["L4R600","L4R600b","L4R80","L4R2500","L1R600","L2R600","L3R600","V_L4C1","V_L2C1","V_L1C2","P_L4","P_L1ord","P_L2ord","P_L2C1"]
print("run | dphy+48 s/s2 | dphy+58 s/s2 | dphy+848 s/s2 | dphy+858 s/s2 | csi+20 s/s2 | csi+60 s/s2 | csi+74 s/s2 | csi+104 s/s2 | csi+48 s/s2")
for t in runs:
    a=ld(t,"start","023f0000"); b=ld(t,"start2","023f0000"); c=ld(t,"start","02600000"); d=ld(t,"start2","02600000")
    if not a: continue
    f=lambda x,y,o: f"{x[o//4]:x}/{y[o//4]:x}"
    print(t, "|", f(a,b,0x48),"|",f(a,b,0x58),"|",f(a,b,0x848),"|",f(a,b,0x858),"|",f(c,d,0x20),"|",f(c,d,0x60),"|",f(c,d,0x74),"|",f(c,d,0x104),"|",f(c,d,0x48))
