#!/usr/bin/env python3
"""
Clean-room EDID generator for the NanoKVM-Pro HDMI front-end (LT6911UXC).

Replaces Sipeed's shipped /kvmcomm/edid set, fixing the real defects in the
vendor bins:

  1. Shared identity. Sipeed's EDIDs differ only in the serial LSB (byte 12,
     which their web UI uses as the mode selector); manufacturer + product-id
     are identical across the set (E63-Ultrawide is worse: it carries a real
     Philips PnP id). A host that caches per-display settings keyed on
     {mfr, product, serial} therefore sees "the same monitor" when you switch
     modes and may not re-probe — a real interop failure. Each variant here
     gets a DISTINCT product id AND serial, while byte 12 stays the value the
     server's EDIDMap expects so the UI still names it.

  2. edid-decode --check failures: no Colorimetry Data Block (sRGB bit), no
     stated display size, Display Range Limits that exclude timings the same
     EDID advertises.

  3. HDMI VSDB Max_TMDS_Clock that is LOWER than the mode the EDID exists to
     advertise (vendor E48 claims 300 MHz while listing a 336 MHz 4K39 DTD).

Everything is written from the E-EDID 1.3 + CTA-861 spec (no vendor bytes).
Modes are re-derived from timing parameters (front/sync/back porch + pixel
clock), so what the source sees is the ordinary mode for that resolution.

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

# Default Display Range Limits: covers every timing the 1080p/720p/4K30 modes
# list. Exotic modes override it (see RANGE in each MODES entry) -- a range
# descriptor that excludes an advertised timing is an edid-decode --check
# failure and is exactly one of the vendor defects we are fixing.
RANGE_DEFAULT = (24, 61, 15, 68, 300)   # vmin, vmax, hmin, hmax, max pclk MHz

def base_block(product_id, serial, name, dtds, std_timings, wmm, hmm,
               n_ext=1, established=(0x20, 0x00, 0x00), rng=RANGE_DEFAULT,
               color_type=0x08):
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
    # bits 4-3 = display colour type (00 monochrome, 01 RGB 4:4:4), bit 1 =
    # preferred timing is native, bit 0 = default GTF. The three production
    # modes pass color_type=0 to keep their hardware-validated bytes frozen;
    # everything else declares RGB.
    b[24] = color_type | 0x02
    # established timings 1/2/3. Default keeps 640x480@60 only.
    b[35], b[36], b[37] = established
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
    # 0xFC holds 13 chars; longer names are truncated (the shipped 1080p bin
    # reads 'NanoKVM-1080P'). New modes carry an explicit <=13-char `label`.
    descs.append(desc_string(0xFC, name))              # product name
    descs.append(desc_range(*rng))
    while len(descs) < 4:
        descs.append(desc_dummy())
    if len(descs) > 4:
        raise ValueError("%s: %d base descriptors, only 4 slots" % (name, len(descs)))
    for i in range(4):
        b[54 + i * 18:54 + (i + 1) * 18] = descs[i]
    b[126] = n_ext
    b[127] = checksum(b)
    return bytes(b)

# ---- CTA-861 extension ---------------------------------------------------

def hdmi_vsdb(phys=(1, 0, 0, 0), max_tmds_mhz=None, hdmi_vics=()):
    """HDMI 1.4b Vendor-Specific Data Block (IEEE OUI 00-0C-03).

    Max_TMDS_Clock (PB7) is emitted whenever a mode in this EDID needs more
    than the 165 MHz an absent field implies -- vendor E48 advertises a
    336 MHz DTD behind a 300 MHz PB7, which a strict source is entitled to
    reject. HDMI_VIC entries carry the HDMI 1.4 4K formats (VIC 1 = 4K30).
    """
    p = bytearray([0x03, 0x0C, 0x00])
    p += bytes([(phys[0] << 4) | phys[1], (phys[2] << 4) | phys[3]])
    if max_tmds_mhz is not None or hdmi_vics:
        p.append(0x00)                              # PB6: no DC/AI/dual-DVI
        p.append((max_tmds_mhz or 0) // 5)          # PB7: 5 MHz units
    if hdmi_vics:
        p.append(0x20)                              # PB8: HDMI_Video_present
        p.append(0x00)                              # PB9: no 3D, no image size
        p.append(len(hdmi_vics) << 5)               # PB10: HDMI_VIC_LEN
        p += bytes(hdmi_vics)
    return bytes([(3 << 5) | len(p)]) + bytes(p)

def cta_ext(vics, dtds, max_tmds_mhz=None, hdmi_vics=(), hdmi=True):
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
        blocks += hdmi_vsdb(max_tmds_mhz=max_tmds_mhz, hdmi_vics=hdmi_vics)
    dtd_off = 4 + len(blocks)
    if dtd_off + 18 * len(dtds) > 127:
        raise ValueError("CTA extension overflow: %d DTDs do not fit" % len(dtds))
    b[0] = 0x02
    b[1] = 0x03
    b[2] = dtd_off
    b[3] = 0x80 | 0x40 | 1  # underscan(IT)+basic-audio, 1 native DTD (matches VCDB)
    b[4:4 + len(blocks)] = blocks
    for i, d in enumerate(dtds):
        off = dtd_off + 18 * i
        b[off:off + 18] = d
    b[127] = checksum(b)
    return bytes(b)

# ---- mode catalogue (distinct product ids / serials; byte12 = EDIDMap key) --
# DTD args: pclk_khz, hact, hbl, vact, vbl, hfp, hsw, vfp, vsw, wmm, hmm
#
# Production modes (hardware-validated) -- 16:9, 1600x900 mm stated size.

DTD_1080P60 = dtd(148500, 1920, 280, 1080, 45, 88, 44, 4, 5, 1600, 900)
DTD_720P60  = dtd(74250, 1280, 370, 720, 30, 110, 40, 5, 5, 1600, 900)
DTD_4K30    = dtd(297000, 3840, 560, 2160, 90, 176, 88, 8, 10, 1600, 900)

# Exotic modes. The 4K39 / 2560x1440@83 / 1080p125 / 3840x2400 / 2560x1600
# timings are CVT reduced-blanking (h blanking 8+32+40 = 80, v sync 8, v back
# porch 6) -- the same family the vendor bins use, re-derived here from the
# porch/pclk arithmetic rather than copied.
#
#   pclk = (hact + hbl) * (vact + vbl) * refresh

# --- E48 "4K39": a 4K overclock. 39 Hz at CVT-RB is 336.336 MHz.
DTD_4K39     = dtd(336340, 3840, 80, 2160, 40, 8, 32, 26, 8, 1600, 900,
                   vpol=False)
DTD_4K30_RB  = dtd(258720, 3840, 80, 2160, 40, 8, 32, 26, 8, 1600, 900,
                   vpol=False)
DTD_1440P83  = dtd(328250, 2560, 80, 1440, 58, 8, 32, 44, 8, 1600, 900,
                   vpol=False)
DTD_1080P125 = dtd(286500, 1920, 80, 1080, 66, 8, 32, 52, 8, 1600, 900,
                   vpol=False)

# --- E56 "2K60": 2560x1440. 60 Hz = 241.5 MHz, 30 Hz = 119 MHz.
DTD_1440P60 = dtd(241500, 2560, 160, 1440, 41, 48, 32, 3, 5, 1600, 900)
DTD_1440P30 = dtd(119000, 2560, 160, 1440, 21, 48, 32, 3, 5, 1600, 900)

# --- E58 "4K 16:10": 3840x2400 and 2560x1600, both CVT-RB. 16:10 -> 1600x1000 mm.
DTD_4K1610_30 = dtd(286240, 3840, 80, 2400, 34, 8, 32, 20, 8, 1600, 1000,
                    vpol=False)
DTD_2560x1600 = dtd(260610, 2560, 80, 1600, 46, 8, 32, 32, 8, 1600, 1000,
                    vpol=False, hpol=False)

# --- E63 "Ultrawide": 3440x1440 (43:18), 2560x1080 (64:27), 3840x1600 (12:5).
#     Stated size 1600x670 mm keeps the ~21:9 aspect honest.
DTD_UW_3440x1440_60 = dtd(319750, 3440, 160, 1440, 41, 48, 32, 3, 10, 1600, 670,
                          vpol=False)
DTD_UW_2560x1080_75 = dtd(228250, 2560, 160, 1080, 39, 48, 32, 3, 10, 1600, 670,
                          vpol=False)
DTD_UW_3840x1600_50 = dtd(321050, 3840, 80, 1600, 38, 8, 32, 24, 8, 1600, 670,
                          vpol=False)

# Established-timing byte triples used below. CTA-861 REQUIRES 640x480p60 to
# be reachable (established bit 5 of byte 35, or VIC 1); the vendor E48/E58
# bins set neither and fail edid-decode on exactly that, so every set here
# keeps the 640x480@60 bit.
EST_640x480       = (0x20, 0x00, 0x00)   # 640x480@60 only (production set)
EST_VGA_XGA       = (0x21, 0x08, 0x00)   # 640x480@60, 800x600@60, 1024x768@60
EST_LEGACY_XGA    = (0xA3, 0x08, 0x00)   # 720x400@70, 640x480@60, 800x600@56/60,
                                         # 1024x768@60

MODES = {
    # name: dict(byte12, pid, base DTDs, CTA DTDs, VICs, std timings, size, ...)
    #   byte12 = the value NanoKVM-Server's EDIDMap keys the UI label on
    #   pid    = our product id, distinct per mode (the vendor's is not)
    #   label  = 0xFC product-name text (13 chars max); defaults to the key
    #
    # FROZEN: the three production modes below are hardware-validated (written
    # to the LT6911 SPI flash, read back byte-identical, driven on real hosts).
    # color_type=0 keeps their exact shipped bytes -- it also means they declare
    # "monochrome" in the feature byte, a harmless nit the new modes do not
    # inherit. Fixing it in the production three is a separate change that must
    # be re-validated on the device.
    "NanoKVM-1080P60": dict(
        byte12=0x36, pid=0x1080, color_type=0x00,
        base_dtds=[DTD_1080P60], cta_dtds=[DTD_1080P60], vics=[16],
        std=[(1280, "16:9", 60), (1024, "4:3", 60)], wmm=1600, hmm=900),

    "NanoKVM-720P60": dict(
        byte12=0x72, pid=0x0720, color_type=0x00,
        base_dtds=[DTD_720P60], cta_dtds=[DTD_720P60], vics=[4],
        std=[(1024, "4:3", 60)], wmm=1600, hmm=900),

    "NanoKVM-4K30": dict(
        byte12=0x12, pid=0x2160, color_type=0x00,
        base_dtds=[DTD_4K30], cta_dtds=[DTD_4K30], vics=[95, 16],
        std=[(1280, "16:9", 60)], wmm=1600, hmm=900),

    # ---- exotic set (replaces the remaining four vendor bins) --------------
    # E48-4K39FPS. The preferred DTD is the 39 Hz mode the UI label promises;
    # the vendor bin preferred 4K30 and buried 4K39 in the extension, which
    # makes the mode indistinguishable from E18. CVT-RB 4K30 stays as DTD 2
    # (a lower-clock fallback the vendor also offered) and CEA 4K30 / 1080p60
    # remain reachable via VIC 95 / 16 and HDMI_VIC 1.
    "NanoKVM-4K39": dict(
        byte12=0x30, pid=0x2139,
        base_dtds=[DTD_4K39, DTD_4K30_RB],
        cta_dtds=[DTD_1440P83, DTD_1080P125],
        vics=[95, 16], hdmi_vics=[1], max_tmds=340,
        std=[(1280, "16:9", 60)], wmm=1600, hmm=900,
        established=EST_VGA_XGA,
        rng=(24, 126, 15, 145, 340)),

    # E56-2K60FPS. 2560x1440@60 is the preferred DTD (the vendor bin preferred
    # 1080p60, contradicting its own "2560 x 1440 60Hz" UI label); 1080p60
    # stays as DTD 2 + VIC 16 so a source that cannot do 2K still locks.
    "NanoKVM-2K60": dict(
        byte12=0x38, pid=0x1440,
        base_dtds=[DTD_1440P60, DTD_1080P60],
        cta_dtds=[DTD_1440P30],
        vics=[16], max_tmds=250,
        std=[(1920, "16:9", 60), (1280, "16:9", 60)], wmm=1600, hmm=900,
        established=EST_LEGACY_XGA,
        rng=(24, 76, 15, 95, 250)),

    # E58-4K16-10. 3840x2400@30 (16:10) preferred, 1080p60 fallback,
    # 2560x1600@60 in the extension. The vendor bin's second extension DTD
    # (2560x1440 with a 30 Hz vtotal driven at 241.5 MHz -> 60.77 Hz) is a
    # broken duplicate and is dropped; 2K is what E56 is for.
    "NanoKVM-4K1610": dict(
        byte12=0x3A, pid=0x2400, label="NanoKVM-16x10",
        base_dtds=[DTD_4K1610_30, DTD_1080P60],
        cta_dtds=[DTD_2560x1600],
        vics=[95, 16], hdmi_vics=[1], max_tmds=300,
        std=[(1920, "8:5", 60), (1280, "16:9", 60)], wmm=1600, hmm=1000,
        established=EST_VGA_XGA,
        rng=(24, 76, 15, 100, 300)),

    # E63-Ultrawide. 3440x1440@60 preferred, 2560x1080@75 second, 3840x1600@50
    # in the extension; 2560x1080@50/60 come from CEA VIC 89/90 rather than the
    # vendor's non-standard 230 MHz duplicate DTD.
    "NanoKVM-Ultrawide": dict(
        byte12=0x3F, pid=0x3440, label="NanoKVM-21x9",
        base_dtds=[DTD_UW_3440x1440_60, DTD_UW_2560x1080_75],
        cta_dtds=[DTD_UW_3840x1600_50],
        vics=[16, 90, 89], max_tmds=340,
        std=[(1920, "16:9", 60), (1280, "16:9", 60)], wmm=1600, hmm=670,
        established=EST_LEGACY_XGA,
        rng=(24, 76, 15, 95, 340)),
}


def build(name, spec):
    byte12 = spec["byte12"]
    pid = spec["pid"]
    serial = (byte12 << 16) | pid
    base = bytearray(base_block(
        pid, serial, spec.get("label", name), spec["base_dtds"], spec["std"],
        spec["wmm"], spec["hmm"],
        established=spec.get("established", EST_640x480),
        rng=spec.get("rng", RANGE_DEFAULT),
        color_type=spec.get("color_type", 0x08)))
    base[12] = byte12                 # server EDIDMap selector (serial LSB)
    base[127] = checksum(base)
    ext = cta_ext(spec["vics"], spec["cta_dtds"],
                  max_tmds_mhz=spec.get("max_tmds"),
                  hdmi_vics=spec.get("hdmi_vics", ()))
    return bytes(base) + ext


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "."
    for name, spec in MODES.items():
        data = build(name, spec)
        assert len(data) == 256
        open("%s/%s.bin" % (outdir, name), "wb").write(data)
        print("wrote %s.bin (byte12=0x%02x)" % (name, spec["byte12"]))


if __name__ == "__main__":
    main()
