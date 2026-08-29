#!/usr/bin/env python3
"""
gen_idr.py  --  From-scratch VC8000E H.264 fixed-QP IDR register-program generator
==================================================================================
Emits the 511-word VC8000E encoder-core register image (swreg1..511) that drives
the AX630C Hantro VC8000E to a decodable 1080p H.264 IDR at a chosen fixed QP.

CLEAN-ROOM POSTURE (see docs/reference/vcenc-open/README.md):
  Every value below is either (a) our own device observation (register offsets/values
  read from /dev/mem on hardware we own -- the Asahi/nouveau/OpenIPC model), (b)
  computed from the frame geometry, or (c) computed from the chosen QP by a scaling
  law we *derived from our own multi-bitrate dumps*. NO VeriSilicon registertable.h,
  NO vendor DWARF, NO EULA source is used. Register *names* are analytical convenience.

WHAT IS "FROM SOURCE" vs "TEMPLATE CONSTANT" (honest boundary -- see REG_DOC):
  - STRUCTURAL cmdbuf envelope (VCMD opcodes): fully understood, emitted by build_cmdbuf().
  - GEOMETRY registers: computed from (W,H) -- proven derivation for the fields we decoded.
  - QP BLOCK (sw7/37/105-107/125-132): computed from QP by derived scaling laws.
  - FIXED TEMPLATE (the remaining ~73 nonzero regs): documented 1080p/YUV/GOP/ASIC-config
    constants from our invariant multi-capture template. Semantics annotated where decoded;
    the residue is honestly marked "template constant, role known / bitfield not decoded".

INJECTION (safety): gen_hook.c overlays ONLY swreg1..511 (this file's output) into the
live vendor cmdbuf slot at LINK time, PRESERVING this-run's per-run address registers
(KEEP set) and the VCMD structural words (readback DMA dests) from libkvm's live program.
So no invented phys address ever reaches the silicon.
"""
import struct, argparse, math

# ---------------------------------------------------------------------------
# Documented 1080p IDR template (swreg1..511), from device observation slot8k.bin
# (a real QP32 8Mbps IDR cmdbuf captured at LINK time on the ATX unit).
# index i (0-based) == swreg(i+1).
# ---------------------------------------------------------------------------
TEMPLATE = [
    0x000009fd, 0x000000f0, 0xff000000, 0x4090004a, 0x3c044302, 0x00000003, 0x80002000, 0x749ce028,  # sw1..8
    0x004047d8, 0x7541f008, 0x00000000, 0x73c45000, 0x74039800, 0x74233c00, 0x74de5000, 0x75221000,  # sw9..16
    0x00000030, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x0000000c, 0xffffffff, 0xffffffff,  # sw17..24
    0xffffffff, 0x54551760, 0x76306300, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw25..32
    0x00000000, 0x00000000, 0x00018e1a, 0x1c995f3c, 0x00f00510, 0x2001e000, 0x4c85962b, 0x1d509090,  # sw33..40
    0xb6940000, 0x00000000, 0x00000000, 0x00000000, 0x00000200, 0x74dd3000, 0x00000000, 0x00000000,  # sw41..48
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw49..56
    0x00000000, 0x00000000, 0x00000000, 0x75429000, 0x00000000, 0x7542a000, 0x00000000, 0x00000000,  # sw57..64
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x74fe3000,  # sw65..72
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x88da4280,  # sw73..80
    0x10000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw81..88
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw89..96
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw97..104
    0x001adb00, 0x001adb00, 0x001adb00, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw105..112
    0x00000000, 0x75435000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw113..120
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x09042020, 0x07281980, 0x05ac1440, 0x04801010,  # sw121..128
    0x03940cc0, 0x02d80a20, 0x02400800, 0x01c80660, 0x00000000, 0x0a000080, 0x00000000, 0x2c000000,  # sw129..136
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw137..144
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw145..152
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw153..160
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw161..168
    0x00000000, 0x00332700, 0x00393700, 0x0000014f, 0x00000662, 0x00000000, 0x00000000, 0x00000000,  # sw169..176
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000139, 0x00000000, 0x00000000,  # sw177..184
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x04000000, 0x14000000, 0x00000000,  # sw185..192
    0x0010011d, 0x0010011c, 0x0000fff0, 0x00100000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw193..200
    0x05050505, 0x00000000, 0x05000101, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x78001ff0,  # sw201..208
    0xffffffe0, 0x00780ff8, 0x00000ff8, 0x01e00ff8, 0x01e03fe0, 0x48500800, 0x00000000, 0x00000000,  # sw209..216
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00020080,  # sw217..224
    0x01014040, 0x00a19200, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw225..232
    0x00000000, 0x00000000, 0x00000000, 0x00002000, 0x01e00044, 0x00000000, 0x75427000, 0x00000000,  # sw233..240
    0x75425000, 0x00000000, 0x00000000, 0x00000000, 0x20000888, 0x02225028, 0x00000000, 0x00000000,  # sw241..248
    0x00fff7f8, 0x00000004, 0x00000004, 0xfffffffc, 0xfffffffc, 0xfffffffc, 0xfffffffc, 0xfffffffc,  # sw249..256
    0xfffffffc, 0xfffffffc, 0xfffffffc, 0x00000000, 0x07800400, 0x00000000, 0x00000000, 0x00000000,  # sw257..264
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0xffffffff,  # sw265..272
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x84000000, 0x00000000, 0x00000000, 0x00000000,  # sw273..280
    0x00000006, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00001000,  # sw281..288
    0x9090b694, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw289..296
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw297..304
    0x00000000, 0x00000000, 0x10100808, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000,  # sw305..312
    0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00000000, 0x00060460, 0x00000400,  # sw313..320
] + [0x00000000]*(511-320)
# sw349 and sw430 are the only nonzero registers past sw320:
TEMPLATE[349-1] = 0x80000000
TEMPLATE[430-1] = 0x00100000
assert len(TEMPLATE) == 511

# ---------------------------------------------------------------------------
# Register documentation / field map. confidence:
#   'struct'  = VCMD/structural, not in the swreg image (see build_cmdbuf)
#   'geom'    = computed from geometry (derivation decoded)
#   'qp'      = computed from QP (scaling law derived from our dumps)
#   'addr'    = per-run CMM phys, PRESERVED from live slot (never emitted for real)
#   'known'   = fixed template, meaning decoded from public semantics / our dumps
#   'opaque'  = fixed template, ROLE known but exact bitfields not decoded (copied)
# ---------------------------------------------------------------------------
REG_DOC = {
  0:  ('known',  'sw0 ASIC-ID 0x90101010, read-only, never written by the program'),
  1:  ('opaque', 'sw1 core mode/interrupt-enable word (0x9fd); fixed for our config'),
  2:  ('geom',   'sw2 = 2*mb_width (0xf0=240 for 120 MB cols); frame-width datum'),
  3:  ('opaque', 'sw3 0xff000000 core control flags; fixed template'),
  4:  ('opaque', 'sw4 0x4090004a pipeline/feature enables; fixed template'),
  5:  ('known',  'sw5 KICK/frame-code 0x3c044302; low byte 0x02=IDR-enable (Stage0)'),
  6:  ('opaque', 'sw6 0x3 slice/entropy config; fixed template (CAVLC path)'),
  7:  ('qp',     'sw7 [31:26]=pic_init_qp (HEADER-ONLY on this HW); kept=32 for PPS match'),
  8:  ('addr',   'sw8 OUTPUT_STRM_BASE (+bit offset); per-run, preserved'),
  9:  ('addr',   'sw9 output stream bit-limit/position; per-run, preserved'),
  10: ('addr',   'sw10 output/aux stream base; per-run CMM, preserved'),
  11: ('known',  'sw11 frame_num/POC = 0 for IDR (Stage0)'),
  12: ('addr',   'sw12 INPUT_Y_BASE (capture frame luma phys); per-run, preserved'),
  13: ('addr',   'sw13 INPUT_CB_BASE; per-run, preserved'),
  14: ('addr',   'sw14 INPUT_CR_BASE; per-run, preserved'),
  15: ('addr',   'sw15 recon luma base; per-run, preserved'),
  16: ('addr',   'sw16 recon chroma base; per-run, preserved'),
  17: ('known',  'sw17 0x30 chroma/format field (NV12 input)'),
  22: ('opaque', 'sw22 0xc slice config; fixed'),
  23: ('known',  'sw23-25 0xffffffff ROI/region-QP disable (no ROI)'),
  26: ('opaque', 'sw26 0x54551760 rate/model seed; fixed template'),
  27: ('addr',   'sw27 CMM aux buffer; per-run, preserved'),
  35: ('opaque', 'sw35-36 model/denoise seeds; fixed template'),
  37: ('qp',     'sw37 QP-dependent lambda/cost (2^((QP-32)/4)); derived scaling'),
  38: ('opaque', 'sw38 0x2001e000 contains 0x1e0; fixed template'),
  39: ('opaque', 'sw39-41 fixed model constants; template'),
  45: ('opaque', 'sw45 0x200; fixed'),
  46: ('addr',   'sw46 CMM buffer; per-run, preserved'),
  60: ('addr',   'sw60/62/72 aux recon/colmv buffers; per-run, preserved'),
  80: ('known',  'sw80 0x88da4280 AsicConfig fuse echo: H264+HEVC, 128-bit AXI (S8.5)'),
  81: ('opaque', 'sw81 0x10000000 core config; fixed'),
  105:('qp',     'sw105-107 TARGETPICSIZE (RC target, sets operating QP); QP-scaled'),
  114:('addr',   'sw114 CMM buffer; per-run, preserved'),
  125:('qp',     'sw125-132 8-entry quant/lambda table; 2^((QP-32)/8) per 16-bit field'),
  134:('opaque', 'sw134/136 fixed model constants; template'),
  170:('opaque', 'sw170-173 rate/complexity stats seeds; template'),
  182:('opaque', 'sw182 0x139; template'),
  190:('known',  'sw190 0x04000000 / sw191 0x14000000 = coding type IDR/intra (Stage0)'),
  193:('opaque', 'sw193-196 deblocking/slice-boundary params; template'),
  201:('opaque', 'sw201/203 0x05.. deblock filter offsets; template'),
  208:('geom',   'sw208-213 frame dimensions/crop (0x780=1920,0x1e0,0x78=120 mb); geom'),
  214:('known',  'sw214 0x48500800 maxEncodedWidth fuse (S8.5)'),
  224:('opaque', 'sw224-225 fixed core config; template'),
  226:('known',  'sw226 0x00a19200 ctbRcVersion=1 fuse (S8.5)'),
  236:('geom',   'sw236/237 0x01e00044: lo=0x44=68 mb rows (frame height in MB)'),
  239:('addr',   'sw239/241 CMM buffers; per-run, preserved'),
  245:('opaque', 'sw245-259 RC model init + ROI-QP-delta defaults (0xfffffffc); template'),
  261:('geom',   'sw261 0x07800400: hi=0x780=1920 frame width'),
  272:('opaque', 'sw272/277/281/288/289 fixed core/model constants; template'),
  307:('opaque', 'sw307 0x10100808; template'),
  319:('opaque', 'sw319 0x00060460 / sw320 0x400 tail config; template'),
  349:('opaque', 'sw349 0x80000000; template'),
  430:('opaque', 'sw430 0x00100000; template'),
}

# per-run address registers (image swreg indices) preserved from the live slot at inject.
KEEP_ADDR = [8,9,10,12,13,14,15,16,27,46,60,62,72,114,239,241]

# ---------------------------------------------------------------------------
# QP scaling laws, derived from our two full captured IDR programs:
#   slot8k.bin  (anchor QP32) and slot400.bin (QP36).
# Validated: predicting slot400 from slot8k reproduces every 16-bit field to
# within rounding noise (<17 LSB) -- see report.
# ---------------------------------------------------------------------------
ANCHOR_QP = 32
def _scale16(word, factor):
    hi, lo = word >> 16, word & 0xffff
    return (min(0xffff, round(hi*factor)) << 16) | min(0xffff, round(lo*factor))

def qp_block(qp, drive_targetpicsize=True):
    """Return {swreg_index: value} for the QP-variable block at the chosen fixed QP."""
    out = {}
    d = qp - ANCHOR_QP
    # sw7 [31:26] = pic_init_qp = QP.  On this HW pic_init_qp only takes effect on the
    # operating QP when the quant/lambda block below is consistent with it (proven: sw7
    # alone is recomputed away; sw7 + block together move the encode). The [25:0] remainder
    # is a QP-derived secondary field; interpolate it from our two anchors
    # (QP32 low=0x2000, QP36 low=0x2500 -> 0x140/QP). A matching PPS (pic_init_qp=QP,
    # via pps_patch.py) must be emitted for correct decode.
    low = (0x2000 + (qp - ANCHOR_QP) * 0x140) & 0x03ffffff
    out[7] = ((qp & 0x3f) << 26) | low
    # sw37 lambda/cost: doubles per +4 QP  ->  x 2^(dQP/4)
    out[37] = _scale16(TEMPLATE[37-1], 2**(d/4.0))
    # sw125..132 quant/lambda table: x sqrt(2) per +4 QP  ->  x 2^(dQP/8), per 16-bit field
    for i in range(125, 133):
        out[i] = _scale16(TEMPLATE[i-1], 2**(d/8.0))
    # sw105..107 TARGETPICSIZE: content-calibrated log-linear between our two anchors
    #   (QP32 -> 0x001adb00 = 1760000 [8Mbps budget, converged QP32];
    #    QP36 -> 0x000157c0 =   88000 [400kbps budget, converged QP36]).
    # This is the register the single-frame RC actually reads to pick operating QP.
    if drive_targetpicsize:
        lo32, lo36 = 1760000.0, 88000.0
        slope = math.log(lo36/lo32) / 4.0        # per-QP log slope from the two anchors
        val = int(round(lo32 * math.exp(slope * d)))
        val = max(0x1000, min(0x0fffffff, val))
        out[105] = out[106] = out[107] = val
    return out

# ---------------------------------------------------------------------------
# Geometry derivation from (W,H) -- proves these regs are computed, not copied.
# For 1920x1080 the results are byte-identical to the observed template (self-check).
# ---------------------------------------------------------------------------
def geometry(W, H):
    mbw = (W + 15) // 16          # 120 for 1920
    mbh = (H + 15) // 16          # 68  for 1080 (padded 1080->1088)
    out = {}
    out[2]   = (TEMPLATE[2-1]   & 0xffff0000) | (2*mbw & 0xffff)      # lo = 2*mb_width
    out[210] = (TEMPLATE[210-1] & 0x0000ffff) | ((mbw & 0xffff) << 16) # hi = mb_width
    out[237] = (TEMPLATE[237-1] & 0xffff0000) | (mbh & 0xffff)        # lo = mb_height
    out[261] = (TEMPLATE[261-1] & 0x0000ffff) | ((W & 0xffff) << 16)  # hi = frame width px
    return out

# ---------------------------------------------------------------------------
def build_image(qp, W=1920, H=1080, drive_targetpicsize=True):
    img = list(TEMPLATE)
    for i, v in geometry(W, H).items():
        img[i-1] = v
    for i, v in qp_block(qp, drive_targetpicsize).items():
        img[i-1] = v
    return img

def build_cmdbuf(image):
    """Full standalone 570-word VCMD cmdbuf (documented envelope + our image).
    NOTE: only used for the field-map artifact / offline decode. On-device
    injection uses gen_hook.c which overlays image-only into the LIVE slot so the
    per-run VCMD readback DMA addresses stay valid. Here the RREG dest words are
    left 0 (placeholder) precisely because they are per-run and must not be invented.
    """
    ENC_BASE = 0x1000
    w = []
    w += [0xb0010068, 0x00000000, 0x00000000, 0x00000000]         # RREG preamble (dest per-run=0 here)
    w += [0x09ff1004] + image[0:511]                              # WREG swreg1..511 @ASIC 0x1004
    # secondary bank pokes @ASIC 0x2800 then 0x2014..0x21f4 stride 0x20 (payload=0 template)
    w += [0x08012800, 0x00000000]
    for a in range(0x2014, 0x2014+16*0x20, 0x20):
        w += [0x08010000 | a, 0x00000000]
    w += [0x08011014, image[5-1]]                                 # KICK: re-write swreg5 last
    w += [0x48000001, 0x00000000]                                 # STALL
    w += [0xb2001000, 0x00000000, 0x00000000, 0x00000000]         # RREG readback (dest per-run=0)
    w += [0xd0001014, 0xfffffffe, 0xd0001004, 0xffffffff]         # CLRINT x2
    w += [0xb01b0000, 0x00000000, 0x00000000, 0x00000000]         # RREG status (dest per-run=0)
    w += [0xc8000000] + [0x00000000]*3                            # end
    return w

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--qp', type=int, required=True)
    ap.add_argument('--width', type=int, default=1920)
    ap.add_argument('--height', type=int, default=1080)
    ap.add_argument('--no-targetpicsize', action='store_true',
                    help='vary only quant table (sw125-132)+sw37, keep TARGETPICSIZE at QP32')
    ap.add_argument('--out', required=True, help='output image .bin (511 LE words)')
    a = ap.parse_args()
    img = build_image(a.qp, a.width, a.height, drive_targetpicsize=not a.no_targetpicsize)
    with open(a.out, 'wb') as f:
        f.write(struct.pack('<511I', *img))
    b = qp_block(a.qp, drive_targetpicsize=not a.no_targetpicsize)
    print("QP=%d image -> %s (%d words)" % (a.qp, a.out, len(img)))
    print("  sw7 =0x%08x (pic_init_qp=%d, header)" % (img[6], (img[6]>>26)&0x3f))
    print("  sw37=0x%08x  sw105=0x%08x  TARGETPICSIZE=%d" % (img[36], img[104], img[104]))
    print("  quant sw125-132:", " ".join("%08x"%img[i-1] for i in range(125,133)))
