import struct, sys
files = ["4k-a", "4k-b", "fake-3840x2160", "fake-1920x1080", "fake-2560x1440", "fake-1280x720", "fake-1920x1200"]
def rd(f, bank): return open("%s-%s.bin" % (f, bank), "rb").read()
def w(d, off): return struct.unpack_from("<I", d, off)[0]
print("ISP file 0x02400000:")
offs = list(range(0x160, 0x1c4, 4)) + list(range(0x1000, 0x1080, 4)) + [0x6448, 0x6518, 0x651c, 0x6530, 0x6540, 0x6544, 0x142ec, 0x142f0, 0x142f4, 0x14300, 0x14304, 0xd1098, 0xd1108, 0x14638]
ds = {f: rd(f, "02400000") for f in files}
print("%-8s" % "off" + "".join("%15s" % f[-9:] for f in files))
for o in offs:
    vals = [w(ds[f], o) for f in files]
    if len(set(vals)) > 1 or o in (0x6530, 0x6518, 0x142ec):
        print("+0x%05x " % o + "".join("     %#010x" % v for v in vals))
print("CSI 0x02600000:")
cs = {f: rd(f, "02600000") for f in files}
for o in range(0, 0x200, 4):
    vals = [w(cs[f], o) for f in files]
    if len(set(vals)) > 1: print("+0x%05x " % o + "".join("     %#010x" % v for v in vals))
for o in range(0x1000, 0x1200, 4):
    vals = [w(cs[f], o) for f in files]
    if len(set(vals)) > 1: print("+0x%05x " % o + "".join("     %#010x" % v for v in vals))
