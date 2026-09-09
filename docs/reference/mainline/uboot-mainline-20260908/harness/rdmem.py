#!/usr/bin/env python3
"""Read a physical range out of /dev/mem by mmap, one aligned u32 at a time.

Two traps, both already documented and both hit anyway:

  * read() on /dev/mem returns ZERO BYTES, with no error, for a `no-map`
    reserved region -- and the ramoops console zone is inside one on the
    slot-A device tree. mmap of the same address works.
  * a bulk copy out of that mapping SIGBUSes: arm64 maps it as Device memory
    and glibc's memcpy uses instructions that fault there. Hence the word
    loop rather than a slice.
"""
import ctypes
import mmap
import os
import struct
import sys

phys = int(sys.argv[1], 0)
length = int(sys.argv[2], 0)
out = sys.argv[3]

assert phys % 4 == 0, "start must be 4-byte aligned"

pagesz = mmap.PAGESIZE
base = phys & ~(pagesz - 1)
off = phys - base
span = ((off + length + pagesz - 1) // pagesz) * pagesz

# PROT_WRITE only so that ctypes can take the buffer's address; nothing here
# writes through it, and the file is opened read-only.
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, span, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE,
              offset=base)
addr = ctypes.addressof(ctypes.c_char.from_buffer(m))
words = (ctypes.c_uint32 * ((length + 3) // 4)).from_address(addr + off)
data = struct.pack("<%dI" % len(words), *words)[:length]
del words
m.close()
os.close(fd)

with open(out, "wb") as f:
    f.write(data)
print("%d bytes from 0x%x -> %s" % (len(data), phys, out))
