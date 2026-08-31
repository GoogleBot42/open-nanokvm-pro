#!/usr/bin/env python3
"""
Clean-room EDID generator for the NanoKVM-Pro HDMI front-end (LT6911UXC).

Replaces Sipeed's shipped /kvmcomm/edid set for the modes we can validate,
fixing the two real defects in the vendor bins:

  1. Shared identity. Sipeed's EDIDs differ only in the serial LSB (byte 12,
     which their web UI uses as the mode selector); manufacturer + product-id
     are identical across the set. A host that caches per-display settings
     keyed on {mfr, product, serial} therefore sees "the same monitor" when
     you switch modes and may not re-probe — a real interop failure. Each
     variant here gets a DISTINCT product id AND serial, while byte 12 stays
     the value the server's EDIDMap expects so the UI still names it.

  2. edid-decode --check failures: no Colorimetry Data Block (sRGB bit), no
     stated display size. Both are added.

Everything is written from the E-EDID 1.4 + CTA-861 spec (no vendor bytes).
Modes are the standard CEA/DMT timings for each named resolution, so what the
source sees is the ordinary mode for that resolution.

Emits <name>.bin (256 bytes: base block + one CTA-861 extension) for each
entry in MODES. `python3 mkedid.py <outdir>`.
"""
import struct
import sys

# ---- low-level EDID field builders ---------------------------------------

def mfr_id(s):
    """3-letter PnP id -> 2 big-endian bytes (5 bits each, 'A'=1)."""
    v = ((ord(s[0]) - 64) << 10) | ((ord(s[1]) - 64) << 5) | (ord(s[2]) - 64)
    return struct.pack(">H", v)

def dtd(pclk_khz, hact, hbl, vact, vbl, hfp, hsw, vfp, vsw, wmm, hmm,
        vpol=True, hpol=True):
    """18-byte Detailed Timing Descriptor."""
    b = bytearray(18)
    struct.pack_into("<H", b, 0, pclk_khz // 10)
    b[2] = hact & 0xFF
    b[3] = hbl & 0xFF
    b[4] = ((hact >> 8) << 4) | (hbl >> 8)
    b[5] = vact & 0xFF
    b[6] = vbl & 0xFF
    b[7] = ((vact >> 8) << 4) | (vbl >> 8)
    b[8] = hfp & 0xFF
    b[9] = hsw & 0xFF
    b[10] = ((vfp & 0xF) << 4) | (vsw & 0xF)
    b[11] = ((hfp >> 8) << 6) | ((hsw >> 8) << 4) | ((vfp >> 4) << 2) | (vsw >> 4)
    b[12] = wmm & 0xFF
    b[13] = hmm & 0xFF
    b[14] = ((wmm >> 8) << 4) | (hmm >> 8)
    b[15] = 0
    # bit7=interlaced(0), bits4-3 = 11 digital separate sync, +vsync/+hsync
    b[17] = 0x18 | (0x04 if vpol else 0) | (0x02 if hpol else 0)
    return bytes(b)

def desc_string(tag, text):
    """18-byte monitor descriptor: 00 00 00 <tag> 00 <13 bytes text/pad>."""
    b = bytearray(18)
    b[3] = tag
    t = text.encode()[:13]
    b[5:5 + len(t)] = t
    for i in range(5 + len(t), 18):
        b[i] = 0x0A if i == 5 + len(t) else 0x20
    return bytes(b)

def desc_range(vmin, vmax, hmin, hmax, pclk_max_mhz):
    b = bytearray(18)
    b[3] = 0xFD
    b[5], b[6], b[7], b[8] = vmin, vmax, hmin, hmax
    b[9] = pclk_max_mhz // 10
    b[10] = 0x00  # default GTF marker (the EDID 1.3 conventional form)
    b[11] = 0x0A
    for i in range(12, 18):
        b[i] = 0x20
    return bytes(b)

def desc_dummy():
    return bytes([0, 0, 0, 0x10] + [0] * 14)

def checksum(block):
    return (256 - (sum(block[:127 if len(block) == 128 else 255]) & 0xFF)) & 0xFF

# ---- base block ----------------------------------------------------------

def base_block(product_id, serial, name, dtds, std_timings, wmm, hmm,
               n_ext=1):
    b = bytearray(128)
    b[0:8] = bytes([0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0])
    b[8:10] = mfr_id("NKV")            # our own PnP-style id (not Sipeed's SPD)
    struct.pack_into("<H", b, 10, product_id)
    struct.pack_into("<I", b, 12, serial)
    b[16] = 40                        # week
    b[17] = 2026 - 1990               # year
    b[18], b[19] = 1, 3               # EDID 1.3 (HDMI VSDB requires 1.3)
    b[20] = 0x80                      # digital (EDID 1.3: no bit-depth/iface bits)
    b[21] = max(1, wmm // 10)         # H image size cm
    b[22] = max(1, hmm // 10)         # V image size cm
    b[23] = 0x78                      # gamma 2.2
    b[24] = 0x02                      # preferred timing is native; no GTF/CVT claim
    # established timings 1/2/3: 720x400,640x480@60 etc. Keep 640x480@60 only.
    b[35] = 0x20
    # standard timings (8 x 2 bytes)
    st = bytearray(16)
    for i, (hpx, ar, refresh) in enumerate(std_timings[:8]):
        st[2 * i] = (hpx // 8) - 31
        armap = {"8:5": 0, "4:3": 1, "5:4": 2, "16:9": 3}
        st[2 * i + 1] = (armap[ar] << 6) | (refresh - 60)
    for i in range(len(std_timings), 8):
        st[2 * i] = 0x01
        st[2 * i + 1] = 0x01
    b[38:54] = st
    # 4 x 18-byte descriptors: DTDs first, then name + range fillers
    # No 0xFF serial-string descriptor: the base serial carries byte-12 (the
    # server's mode selector), and edid-decode flags base-serial + string-serial
    # both set. Product name + range limits + a dummy fill the remaining slots.
    descs = list(dtds)
    descs.append(desc_string(0xFC, name))              # product name
    descs.append(desc_range(24, 61, 15, 68, 300))
    descs.append(desc_dummy())
    while len(descs) < 4:
        descs.append(desc_dummy())
    for i in range(4):
        b[54 + i * 18:54 + (i + 1) * 18] = descs[i]
    b[126] = n_ext
    b[127] = checksum(b)
    return bytes(b)

# ---- CTA-861 extension ---------------------------------------------------

def cta_ext(vics, native_dtd, wmm, hmm, hdmi=True):
    b = bytearray(128)
    blocks = bytearray()
    # Video Data Block: tag 2
    vdb = bytes([(2 << 5) | len(vics)]) + bytes(vics)
    blocks += vdb
    # Video Capability Data Block (extended tag 0): QY+QS selectable RGB/YCC
    #   quantization + underscanned IT/CE (fixes the overscan-default warning).
    vcdb = bytes([(7 << 5) | 2, 0x00, 0xCA])
    blocks += vcdb
    # Colorimetry Data Block (extended tag 5): xvYCC601 + sRGB metadata.
    cdb = bytes([(7 << 5) | 3, 0x05, 0x01, 0x20])
    blocks += cdb
    if hdmi:
        # HDMI VSDB (tag 3, IEEE OUI 00-0C-03), source phys addr 1.0.0.0
        vsdb = bytes([(3 << 5) | 5, 0x03, 0x0C, 0x00, 0x10, 0x00])
        blocks += vsdb
    dtd_off = 4 + len(blocks)
    b[0] = 0x02
    b[1] = 0x03
    b[2] = dtd_off
    b[3] = 0x80 | 0x40 | 1  # underscan(IT)+basic-audio, 1 native DTD (matches VCDB)
    b[4:4 + len(blocks)] = blocks
    b[dtd_off:dtd_off + 18] = native_dtd
    b[127] = checksum(b)
    return bytes(b)

# ---- mode catalogue (distinct product ids / serials; byte12 = EDIDMap key) --
# DTD args: pclk_khz, hact, hbl, vact, vbl, hfp, hsw, vfp, vsw, wmm, hmm

DTD_1080P60 = dtd(148500, 1920, 280, 1080, 45, 88, 44, 4, 5, 1600, 900)
DTD_720P60  = dtd(74250, 1280, 370, 720, 30, 110, 40, 5, 5, 1600, 900)
DTD_4K30    = dtd(297000, 3840, 560, 2160, 90, 176, 88, 8, 10, 1600, 900)

MODES = {
    # name: (byte12_id, product_id, dtd, [VICs], std_timings, wmm, hmm)
    "NanoKVM-1080P60": (0x36, 0x1080, DTD_1080P60, [16],
                        [(1280, "16:9", 60), (1024, "4:3", 60)], 1600, 900),
    "NanoKVM-720P60":  (0x72, 0x0720, DTD_720P60, [4],
                        [(1024, "4:3", 60)], 1600, 900),
    "NanoKVM-4K30":    (0x12, 0x2160, DTD_4K30, [95, 16],
                        [(1280, "16:9", 60)], 1600, 900),
}


def build(name, spec):
    byte12, pid, native_dtd, vics, stds, wmm, hmm = spec
    serial = (byte12 << 16) | pid
    base = bytearray(base_block(pid, serial, name, [native_dtd], stds, wmm, hmm))
    base[12] = byte12                 # server EDIDMap selector (serial LSB)
    base[127] = checksum(base)
    ext = cta_ext(vics, native_dtd, wmm, hmm)
    return bytes(base) + ext


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    for name, spec in MODES.items():
        data = build(name, spec)
        assert len(data) == 256
        open("%s/%s.bin" % (outdir, name), "wb").write(data)
        print("wrote %s.bin (byte12=0x%02x)" % (name, spec[0]))


if __name__ == "__main__":
    main()
