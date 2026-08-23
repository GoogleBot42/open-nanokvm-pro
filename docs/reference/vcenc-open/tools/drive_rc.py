#!/usr/bin/env python3
# Item 4 (RC observability). Drive H.264 CBR encode headless via the OPEN libkvm,
# log per-NAL type+size, extract per-frame QP from the bitstream (PPS pic_init_qp
# + slice_qp_delta) as an INDEPENDENT cross-check of the vendor's own qpHdr debug
# line (which appears on stderr when VENC ulog is raised to level 7).
#
# Read-only: never writes device memory. Args: <bitrate_kbps> <nframes> <gop>
import ctypes, sys, struct

LIB = "/dev/shm/kvmapp/server/dl_lib/libkvm.so"
VENCLIB = "/opt/lib/libax_venc.so"
BITRATE = int(sys.argv[1]) if len(sys.argv) > 1 else 8000   # kbps, H264 CBR target
NFRAMES = int(sys.argv[2]) if len(sys.argv) > 2 else 90
GOP     = int(sys.argv[3]) if len(sys.argv) > 3 else 30
W, H = 1920, 1080
CHN = 7  # KVM_VENC_H264_CHN

lib = ctypes.CDLL(LIB)
lib.kvmv_init.argtypes = [ctypes.c_ubyte]
lib.kvmv_set_gop.argtypes = [ctypes.c_ubyte]
lib.kvmv_read_img.argtypes = [ctypes.c_uint16, ctypes.c_uint16, ctypes.c_ubyte, ctypes.c_uint16,
    ctypes.POINTER(ctypes.POINTER(ctypes.c_ubyte)), ctypes.POINTER(ctypes.c_uint)]
lib.kvmv_read_img.restype = ctypes.c_int

# libax_venc already resolved as a NEEDED dep of libkvm; open a handle for GetRcParam.
venc = ctypes.CDLL(VENCLIB)
venc.AX_VENC_GetRcParam.argtypes = [ctypes.c_int, ctypes.c_void_p]
venc.AX_VENC_GetRcParam.restype = ctypes.c_int
venc.AX_VENC_SetRcParam.argtypes = [ctypes.c_int, ctypes.c_void_p]
venc.AX_VENC_SetRcParam.restype = ctypes.c_int

RCBUF = 1024
def getrc_extent(tag):
    buf = (ctypes.c_ubyte * RCBUF)(*([0xAA] * RCBUF))
    rc = venc.AX_VENC_GetRcParam(CHN, ctypes.cast(buf, ctypes.c_void_p))
    b = bytes(buf)
    # find written extent: last offset not still 0xAA (best-effort bound)
    ext = 0
    for i in range(RCBUF):
        if b[i] != 0xAA:
            ext = i + 1
    print("[GETRC %s] rc=%d written_extent<=%d bytes" % (tag, rc, ext), flush=True)
    print("[GETRC %s] hex: %s" % (tag, b[:ext].hex()), flush=True)
    return buf

def setrc_same(buf):
    # re-apply the identical params read back, purely to trigger libax_venc's
    # [D] setRcParam debug dump (cpbSize/hrd/bitrateWindow/intraQpDelta -- the
    # VCEncRateCtrl field set). No value change.
    rc = venc.AX_VENC_SetRcParam(CHN, ctypes.cast(buf, ctypes.c_void_p))
    print("[SETRC same] rc=%d (identical params re-applied to emit RC dump)" % rc, flush=True)

# ---- minimal H.264 bit reader (RBSP, with emulation-prevention removal) ----
class BR:
    def __init__(self, data):
        self.b = self._unescape(data); self.pos = 0
    def _unescape(self, d):
        out = bytearray(); z = 0
        for x in d:
            if z >= 2 and x == 3:
                z = 0; continue
            out.append(x); z = z + 1 if x == 0 else 0
        return bytes(out)
    def u1(self):
        byte = self.b[self.pos >> 3]; bit = (byte >> (7 - (self.pos & 7))) & 1
        self.pos += 1; return bit
    def u(self, n):
        v = 0
        for _ in range(n): v = (v << 1) | self.u1()
        return v
    def ue(self):
        z = 0
        while self.u1() == 0: z += 1
        return (1 << z) - 1 + self.u(z) if z else 0
    def se(self):
        k = self.ue(); return (k + 1) // 2 if (k & 1) else -(k // 2)

SPS = {}; PPS = {}

def parse_sps(nal):  # nal without start code, includes 1-byte header
    r = BR(nal[1:])
    prof = r.u(8); r.u(8); lvl = r.u(8)
    r.ue()  # sps_id
    if prof in (100,110,122,244,44,83,86,118,128,138,139,134,135):
        cf = r.ue()
        if cf == 3: r.u1()
        r.ue(); r.ue(); r.u1()
        if r.u1():  # scaling matrix present
            for i in range(8 if cf != 3 else 12):
                # skip scaling lists (simplified: bail if seen; our encoder won't emit)
                return
    log2_fn = r.ue() + 4
    poc_type = r.ue()
    poc_lsb = 0
    if poc_type == 0:
        poc_lsb = r.ue() + 4
    elif poc_type == 1:
        r.u1(); r.se(); r.se(); n = r.ue()
        for _ in range(n): r.se()
    r.ue()  # max_num_ref_frames
    r.u1()  # gaps_in_frame_num
    r.ue(); r.ue()  # pic_width/height in mbs
    fmof = r.u1()   # frame_mbs_only_flag
    SPS.update(log2_fn=log2_fn, poc_type=poc_type, poc_lsb=poc_lsb, fmof=fmof, prof=prof, lvl=lvl)

def parse_pps(nal):
    r = BR(nal[1:])
    r.ue(); r.ue()  # pps_id, sps_id
    ent = r.u1()    # entropy_coding_mode_flag
    bpof = r.u1()   # bottom_field_pic_order_in_frame_present_flag
    ngm1 = r.ue()   # num_slice_groups_minus1
    if ngm1 > 0:
        PPS.update(complex_sg=True); return
    r.ue(); r.ue()  # num_ref_idx l0/l1 default
    r.u1()          # weighted_pred_flag
    r.u(2)          # weighted_bipred_idc
    pic_init_qp = r.se() + 26
    PPS.update(ent=ent, bpof=bpof, pic_init_qp=pic_init_qp)

def slice_qp(nal):
    # returns (slice_type, frame_qp) or None if context missing
    if 'log2_fn' not in SPS or 'pic_init_qp' not in PPS: return None
    nal_type = nal[0] & 0x1f
    idr = (nal_type == 5)
    r = BR(nal[1:])
    r.ue()             # first_mb_in_slice
    st = r.ue()        # slice_type
    r.ue()             # pps_id
    r.u(SPS['log2_fn'])  # frame_num
    if not SPS['fmof']:
        if r.u1():     # field_pic_flag
            r.u1()     # bottom_field_flag
    if idr: r.ue()     # idr_pic_id
    if SPS['poc_type'] == 0:
        r.u(SPS['poc_lsb'])          # pic_order_cnt_lsb
        if PPS['bpof']: r.se()       # delta_pic_order_cnt_bottom
    # (poc_type==1 path omitted; our encoder uses poc_type 0)
    st_mod = st % 5
    # redundant_pic_cnt_present assumed 0 (typical); no B slices (NORMALP GOP)
    if st_mod in (0, 3):  # P or SP
        if r.u1():        # num_ref_idx_active_override_flag
            r.ue()        # num_ref_idx_l0_active_minus1
        # ref_pic_list_modification (P): modification flag
        if r.u1():
            while True:
                op = r.ue()
                if op == 3: break
                r.ue()
    # dec_ref_pic_marking (nal_ref_idc != 0 -> our slices are ref)
    nri = (nal[0] >> 5) & 3
    if nri != 0:
        if idr:
            r.u1(); r.u1()   # no_output_of_prior_pics, long_term_reference
        else:
            if r.u1():       # adaptive_ref_pic_marking_mode_flag
                while True:
                    mop = r.ue()
                    if mop == 0: break
                    if mop in (1,3): r.ue()
                    if mop == 2: r.ue()
                    if mop in (3,6): r.ue()
                    if mop == 4: r.ue()
    if PPS['ent'] and st_mod not in (2, 4):  # cabac and not I/SI
        r.ue()               # cabac_init_idc
    sqd = r.se()             # slice_qp_delta
    return (st_mod, PPS['pic_init_qp'] + sqd)

STNAME = {0:'P',1:'B',2:'I',3:'SP',4:'SI'}

print("=== drive_rc: bitrate=%d kbps nframes=%d gop=%d ===" % (BITRATE, NFRAMES, GOP), flush=True)
lib.kvmv_init(1)
lib.kvmv_set_gop(GOP)

ptr = ctypes.POINTER(ctypes.c_ubyte)(); ln = ctypes.c_uint(0)
got_frames = 0
rc_before_done = False
series = []  # (frame_idx, kind, size, qp_bitstream)
frame_idx = 0
cur_size = 0
cur_kind = None
cur_qp = None
calls = 0
maxcalls = NFRAMES * 6 + 60

def flush_frame():
    global cur_size, cur_kind, cur_qp
    if cur_kind is not None:
        series.append((frame_idx, cur_kind, cur_size, cur_qp))
    cur_size = 0; cur_kind = None; cur_qp = None

while got_frames < NFRAMES and calls < maxcalls:
    calls += 1
    rc = lib.kvmv_read_img(W, H, 3, BITRATE, ctypes.byref(ptr), ctypes.byref(ln))
    n = ln.value
    if rc < 0:
        continue
    data = bytes(ptr[j] for j in range(n)) if n else b""
    # data has a 4-byte start code prefix (00 00 00 01) then NAL
    nal = data
    for sc in (b"\x00\x00\x00\x01", b"\x00\x00\x01"):
        if nal.startswith(sc): nal = nal[len(sc):]; break
    if rc == 1:      # SPS
        parse_sps(nal)
    elif rc == 2:    # PPS
        parse_pps(nal)
    elif rc in (3, 4):  # I or P slice -> a coded frame
        flush_frame()
        frame_idx += 1
        cur_kind = 'I' if rc == 3 else 'P'
        cur_size = n
        try:
            q = slice_qp(nal)
        except Exception:
            q = None
        cur_qp = q[1] if q else None
        got_frames += 1
        # capture GetRcParam once, right after the channel is warm (2nd frame)
        if got_frames == 2 and not rc_before_done:
            _b = getrc_extent("BEFORE"); setrc_same(_b); rc_before_done = True

flush_frame()
getrc_extent("AFTER")

print("=== per-frame series (idx kind size_bytes qp_bitstream) ===", flush=True)
for (i, k, s, q) in series:
    print("F%-4d %-2s %8d  qp=%s" % (i, k, s, q if q is not None else "?"), flush=True)

# summary
isz = [s for (_,k,s,_) in series if k=='I']
psz = [s for (_,k,s,_) in series if k=='P']
iq  = [q for (_,k,_,q) in series if k=='I' and q is not None]
pq  = [q for (_,k,_,q) in series if k=='P' and q is not None]
def stat(x): return ("n=%d min=%d max=%d avg=%.1f" % (len(x), min(x), max(x), sum(x)/len(x))) if x else "none"
print("=== summary bitrate=%d ===" % BITRATE, flush=True)
print("SPS pic_init_qp=%s  I-frame size: %s" % (PPS.get('pic_init_qp'), stat(isz)), flush=True)
print("P-frame size: %s" % stat(psz), flush=True)
print("I QP: %s | P QP: %s" % (stat(iq), stat(pq)), flush=True)
print("SPS ctx=%s PPS ctx=%s" % (SPS, PPS), flush=True)
try:
    lib.kvmv_deinit()
except Exception:
    pass
print("done", flush=True)
