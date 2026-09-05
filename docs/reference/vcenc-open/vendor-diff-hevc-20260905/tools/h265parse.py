#!/usr/bin/env python3
"""h265parse.py file.h265 [--json]

Annex-B H.265/HEVC elementary-stream header parser.  One line per NAL:
    <size> <TYPENAME>(<n>) <summary>
Reference: ITU-T H.265 sec 7.3 (NAL/VPS/SPS/PPS/slice), 7.3.4 (scaling list),
7.3.7 (st_ref_pic_set), Annex E.2 (VUI/HRD).  Sibling of h264parse.py.
"""
import sys, json


# ---------------------------------------------------------------- bit reader
class BR:
    """RBSP bit reader: strips emulation-prevention bytes, ue/se helpers."""

    def __init__(s, d):
        s.b = s._un(d)
        s.p = 0

    def _un(s, d):
        o = bytearray()
        z = 0
        for x in d:
            if z >= 2 and x == 3:
                z = 0
                continue
            o.append(x)
            z = z + 1 if x == 0 else 0
        return bytes(o)

    def u1(s):
        if (s.p >> 3) >= len(s.b):
            raise ValueError("bit reader ran past end of RBSP")
        v = (s.b[s.p >> 3] >> (7 - (s.p & 7))) & 1
        s.p += 1
        return v

    def u(s, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | s.u1()
        return v

    def ue(s):
        z = 0
        while s.u1() == 0:
            z += 1
            if z > 32:
                raise ValueError("ue(v) exp-golomb prefix too long")
        return (1 << z) - 1 + s.u(z) if z else 0

    def se(s):
        k = s.ue()
        return (k + 1) // 2 if (k & 1) else -(k // 2)

    def more(s):
        return (s.p >> 3) < len(s.b)


def clog2(x):
    """Ceil(Log2(x))"""
    return (x - 1).bit_length() if x > 1 else 0


def chk(v, lim, name):
    """Bound a ue(v) field so corrupt input cannot turn into a huge shift/loop."""
    if v > lim:
        raise ValueError("%s=%d exceeds sane limit %d" % (name, v, lim))
    return v


# ------------------------------------------------------------- NAL type names
NT = {
    0: "TRAIL_N", 1: "TRAIL_R", 2: "TSA_N", 3: "TSA_R", 4: "STSA_N", 5: "STSA_R",
    6: "RADL_N", 7: "RADL_R", 8: "RASL_N", 9: "RASL_R",
    16: "BLA_W_LP", 17: "BLA_W_RADL", 18: "BLA_N_LP",
    19: "IDR_W_RADL", 20: "IDR_N_LP", 21: "CRA_NUT",
    32: "VPS", 33: "SPS", 34: "PPS", 35: "AUD", 36: "EOS", 37: "EOB", 38: "FD",
    39: "PREFIX_SEI", 40: "SUFFIX_SEI",
}


def ntname(t):
    if t in NT:
        return NT[t]
    if t < 16:
        return "RSV_VCL%d" % t
    if t < 22:
        return "RSV_IRAP%d" % t
    if t < 32:
        return "RSV_VCL%d" % t
    return "UNSPEC%d" % t if t >= 48 else "RSV_NVCL%d" % t


# ------------------------------------------------------------- shared parsers
def ptl(r, max_sub_minus1, profile_present=1):
    """profile_tier_level() -- H.265 sec 7.3.3"""
    d = {}
    if profile_present:
        d["general_profile_space"] = r.u(2)
        d["general_tier_flag"] = r.u(1)
        d["general_profile_idc"] = r.u(5)
        cf = [r.u1() for _ in range(32)]
        d["general_profile_compatibility_flags"] = "".join(str(x) for x in cf)
        d["general_progressive_source_flag"] = r.u1()
        d["general_interlaced_source_flag"] = r.u1()
        d["general_non_packed_constraint_flag"] = r.u1()
        d["general_frame_only_constraint_flag"] = r.u1()
        r.u(43)   # general_reserved_zero_43bits / range-ext constraint flags
        r.u(1)    # general_inbld_flag or reserved bit
    d["general_level_idc"] = r.u(8)
    pflag = []
    lflag = []
    for _ in range(max_sub_minus1):
        pflag.append(r.u1())
        lflag.append(r.u1())
    if max_sub_minus1 > 0:
        for _ in range(max_sub_minus1, 8):
            r.u(2)  # reserved_zero_2bits
    subs = []
    for i in range(max_sub_minus1):
        sd = {"profile_present": pflag[i], "level_present": lflag[i]}
        if pflag[i]:
            sd["profile_space"] = r.u(2)
            sd["tier_flag"] = r.u(1)
            sd["profile_idc"] = r.u(5)
            r.u(32)
            sd["progressive"] = r.u1()
            sd["interlaced"] = r.u1()
            sd["non_packed"] = r.u1()
            sd["frame_only"] = r.u1()
            r.u(43)
            r.u(1)
        if lflag[i]:
            sd["level_idc"] = r.u(8)
        subs.append(sd)
    if subs:
        d["sub_layers"] = subs
    return d


def ptl_str(d):
    return "profile=%d tier=%d level=%.1f space=%d prog=%d int=%d nonpack=%d frameonly=%d" % (
        d.get("general_profile_idc", -1), d.get("general_tier_flag", 0),
        d.get("general_level_idc", 0) / 30.0, d.get("general_profile_space", 0),
        d.get("general_progressive_source_flag", 0), d.get("general_interlaced_source_flag", 0),
        d.get("general_non_packed_constraint_flag", 0), d.get("general_frame_only_constraint_flag", 0))


def scaling_list_data(r):
    """sec 7.3.4 -- parsed only far enough to consume the right number of bits."""
    for sizeId in range(4):
        matrixId = 0
        step = 3 if sizeId == 3 else 1
        while matrixId < 6:
            if not r.u1():          # scaling_list_pred_mode_flag
                r.ue()              # scaling_list_pred_matrix_id_delta
            else:
                coefNum = min(64, 1 << (4 + (sizeId << 1)))
                if sizeId > 1:
                    r.se()          # scaling_list_dc_coef_minus8
                for _ in range(coefNum):
                    r.se()          # scaling_list_delta_coef
            matrixId += step


def st_rps(r, idx, sets, num_sets):
    """st_ref_pic_set(idx) -- sec 7.3.7 + derivations (7-59)/(7-61).

    `sets` holds the already-decoded sets [0..idx-1] (SPS ones).  Returns a dict
    {'neg': [(deltaPoc, used), ...], 'pos': [...], 'inter': flag}.
    """
    inter = r.u1() if idx != 0 else 0
    if inter:
        delta_idx = 1
        if idx == num_sets:                    # slice-level inline set
            delta_idx = r.ue() + 1
        sign = r.u1()
        absd = r.ue() + 1
        deltaRps = (1 - 2 * sign) * absd
        ref = sets[idx - delta_idx]
        rneg, rpos = ref["neg"], ref["pos"]
        nneg, npos = len(rneg), len(rpos)
        nd = nneg + npos
        used = [0] * (nd + 1)
        useD = [1] * (nd + 1)
        for j in range(nd + 1):
            used[j] = r.u1()
            if not used[j]:
                useD[j] = r.u1()
        neg = []
        for j in range(npos - 1, -1, -1):
            dp = rpos[j][0] + deltaRps
            if dp < 0 and useD[nneg + j]:
                neg.append((dp, used[nneg + j]))
        if deltaRps < 0 and useD[nd]:
            neg.append((deltaRps, used[nd]))
        for j in range(nneg):
            dp = rneg[j][0] + deltaRps
            if dp < 0 and useD[j]:
                neg.append((dp, used[j]))
        pos = []
        for j in range(nneg - 1, -1, -1):
            dp = rneg[j][0] + deltaRps
            if dp > 0 and useD[j]:
                pos.append((dp, used[j]))
        if deltaRps > 0 and useD[nd]:
            pos.append((deltaRps, used[nd]))
        for j in range(npos):
            dp = rpos[j][0] + deltaRps
            if dp > 0 and useD[nneg + j]:
                pos.append((dp, used[nneg + j]))
        return {"neg": neg, "pos": pos, "inter": 1, "delta_rps": deltaRps,
                "ref_idx": idx - delta_idx}
    nn = r.ue()
    npo = r.ue()
    if nn > 64 or npo > 64:
        raise ValueError("implausible st_ref_pic_set counts %d/%d" % (nn, npo))
    neg = []
    p = 0
    for _ in range(nn):
        p -= (r.ue() + 1)
        neg.append((p, r.u1()))
    pos = []
    p = 0
    for _ in range(npo):
        p += (r.ue() + 1)
        pos.append((p, r.u1()))
    return {"neg": neg, "pos": pos, "inter": 0}


def rps_str(s):
    f = lambda L: "[" + ",".join("%+d%s" % (d, "u" if u else "-") for d, u in L) + "]"
    return "neg=%s pos=%s" % (f(s["neg"]), f(s["pos"]))


def hrd(r, common, max_sub_minus1):
    """hrd_parameters() -- Annex E.2.2"""
    d = {}
    nal = vcl = subpic = 0
    if common:
        nal = r.u1()
        vcl = r.u1()
        d["nal_hrd"] = nal
        d["vcl_hrd"] = vcl
        if nal or vcl:
            subpic = r.u1()
            d["sub_pic_hrd_params_present"] = subpic
            if subpic:
                r.u(8)   # tick_divisor_minus2
                r.u(5)   # du_cpb_removal_delay_increment_length_minus1
                r.u1()   # sub_pic_cpb_params_in_pic_timing_sei_flag
                r.u(5)   # dpb_output_delay_du_length_minus1
            d["bit_rate_scale"] = r.u(4)
            d["cpb_size_scale"] = r.u(4)
            if subpic:
                r.u(4)   # cpb_size_du_scale
            r.u(5)       # initial_cpb_removal_delay_length_minus1
            r.u(5)       # au_cpb_removal_delay_length_minus1
            r.u(5)       # dpb_output_delay_length_minus1
    for _ in range(max_sub_minus1 + 1):
        fg = r.u1()
        fc = fg
        if not fg:
            fc = r.u1()
        low = 0
        if fc:
            r.ue()       # elemental_duration_in_tc_minus1
        else:
            low = r.u1()
        cpb_cnt = 0
        if not low:
            cpb_cnt = chk(r.ue(), 31, "cpb_cnt_minus1")
        for present in (nal, vcl):
            if present:
                for _ in range(cpb_cnt + 1):
                    r.ue()   # bit_rate_value_minus1
                    r.ue()   # cpb_size_value_minus1
                    if subpic:
                        r.ue()  # cpb_size_du_value_minus1
                        r.ue()  # bit_rate_du_value_minus1
                    r.u1()      # cbr_flag
    return d


def vui(r, max_sub_minus1):
    """vui_parameters() -- Annex E.2.1 (best effort)."""
    d = {}
    if r.u1():                       # aspect_ratio_info_present_flag
        idc = r.u(8)
        d["aspect_ratio_idc"] = idc
        if idc == 255:
            d["sar_width"] = r.u(16)
            d["sar_height"] = r.u(16)
    if r.u1():                       # overscan_info_present_flag
        d["overscan_appropriate"] = r.u1()
    if r.u1():                       # video_signal_type_present_flag
        d["video_format"] = r.u(3)
        d["video_full_range_flag"] = r.u1()
        if r.u1():                   # colour_description_present_flag
            d["colour_primaries"] = r.u(8)
            d["transfer_characteristics"] = r.u(8)
            d["matrix_coeffs"] = r.u(8)
    if r.u1():                       # chroma_loc_info_present_flag
        d["chroma_sample_loc_type_top_field"] = r.ue()
        d["chroma_sample_loc_type_bottom_field"] = r.ue()
    d["neutral_chroma_indication_flag"] = r.u1()
    d["field_seq_flag"] = r.u1()
    d["frame_field_info_present_flag"] = r.u1()
    if r.u1():                       # default_display_window_flag
        d["def_disp_win"] = [r.ue(), r.ue(), r.ue(), r.ue()]
    if r.u1():                       # vui_timing_info_present_flag
        d["num_units_in_tick"] = r.u(32)
        d["time_scale"] = r.u(32)
        if r.u1():                   # vui_poc_proportional_to_timing_flag
            d["num_ticks_poc_diff_one_minus1"] = r.ue()
        if r.u1():                   # vui_hrd_parameters_present_flag
            d["hrd"] = hrd(r, 1, max_sub_minus1)
    if r.u1():                       # bitstream_restriction_flag
        d["tiles_fixed_structure_flag"] = r.u1()
        d["motion_vectors_over_pic_boundaries_flag"] = r.u1()
        d["restricted_ref_pic_lists_flag"] = r.u1()
        d["min_spatial_segmentation_idc"] = r.ue()
        d["max_bytes_per_pic_denom"] = r.ue()
        d["max_bits_per_min_cu_denom"] = r.ue()
        d["log2_max_mv_length_horizontal"] = r.ue()
        d["log2_max_mv_length_vertical"] = r.ue()
    return d


def vui_str(d):
    o = []
    if "aspect_ratio_idc" in d:
        o.append("sar_idc=%d%s" % (d["aspect_ratio_idc"],
                 ("(%d:%d)" % (d["sar_width"], d["sar_height"])) if "sar_width" in d else ""))
    if "video_format" in d:
        o.append("vidfmt=%d fullrange=%d" % (d["video_format"], d["video_full_range_flag"]))
        if "colour_primaries" in d:
            o.append("colour=%d/%d/%d" % (d["colour_primaries"], d["transfer_characteristics"],
                                          d["matrix_coeffs"]))
    if "time_scale" in d:
        nu = d["num_units_in_tick"]
        o.append("timing=%d/%d(%.3ffps)" % (nu, d["time_scale"],
                 (d["time_scale"] / float(nu)) if nu else 0.0))
    if "hrd" in d:
        o.append("hrd(nal=%d vcl=%d)" % (d["hrd"].get("nal_hrd", 0), d["hrd"].get("vcl_hrd", 0)))
    if "min_spatial_segmentation_idc" in d:
        o.append("bsrestrict(minseg=%d maxbytes=%d maxbits=%d mvlen=%d/%d)" % (
            d["min_spatial_segmentation_idc"], d["max_bytes_per_pic_denom"],
            d["max_bits_per_min_cu_denom"], d["log2_max_mv_length_horizontal"],
            d["log2_max_mv_length_vertical"]))
    return " ".join(o) if o else "(empty)"


# ------------------------------------------------------------------ VPS / SPS / PPS
VPS = {}
SPS = {}
PPS = {}


def vps(n):
    r = BR(n[2:])
    d = {}
    d["vps_video_parameter_set_id"] = r.u(4)
    r.u(1)                                   # vps_base_layer_internal_flag
    r.u(1)                                   # vps_base_layer_available_flag
    d["vps_max_layers_minus1"] = r.u(6)
    msl = r.u(3)
    d["vps_max_sub_layers_minus1"] = msl
    d["vps_temporal_id_nesting_flag"] = r.u(1)
    r.u(16)                                  # vps_reserved_0xffff_16bits
    d["ptl"] = ptl(r, msl)
    oip = r.u1()
    d["vps_sub_layer_ordering_info_present_flag"] = oip
    ord_ = []
    for _ in range(0 if oip else msl, msl + 1):
        ord_.append({"max_dec_pic_buffering_minus1": r.ue(),
                     "max_num_reorder_pics": r.ue(),
                     "max_latency_increase_plus1": r.ue()})
    d["sub_layer_ordering_info"] = ord_
    mli = r.u(6)
    d["vps_max_layer_id"] = mli
    nls = chk(r.ue(), 1023, "vps_num_layer_sets_minus1")
    d["vps_num_layer_sets_minus1"] = nls
    for _ in range(1, nls + 1):
        for _ in range(mli + 1):
            r.u1()                           # layer_id_included_flag
    ti = r.u1()
    d["vps_timing_info_present_flag"] = ti
    if ti:
        d["vps_num_units_in_tick"] = r.u(32)
        d["vps_time_scale"] = r.u(32)
        pp = r.u1()
        d["vps_poc_proportional_to_timing_flag"] = pp
        if pp:
            d["vps_num_ticks_poc_diff_one_minus1"] = r.ue()
    VPS[d["vps_video_parameter_set_id"]] = d
    o = ["id=%d" % d["vps_video_parameter_set_id"],
         "layers=%d" % (d["vps_max_layers_minus1"] + 1),
         "sublayers=%d" % (msl + 1),
         "tid_nesting=%d" % d["vps_temporal_id_nesting_flag"],
         ptl_str(d["ptl"]),
         "dpb=%s" % ",".join("%d/%d/%d" % (x["max_dec_pic_buffering_minus1"] + 1,
                                           x["max_num_reorder_pics"],
                                           x["max_latency_increase_plus1"]) for x in ord_),
         "max_layer_id=%d" % mli, "layer_sets=%d" % (nls + 1)]
    if ti:
        nu = d["vps_num_units_in_tick"]
        o.append("timing=%d/%d(%.3ffps) poc_prop=%d" % (
            nu, d["vps_time_scale"], (d["vps_time_scale"] / float(nu)) if nu else 0.0,
            d["vps_poc_proportional_to_timing_flag"]))
    return " ".join(o), d


def sps(n):
    r = BR(n[2:])
    d = {}
    d["sps_video_parameter_set_id"] = r.u(4)
    msl = r.u(3)
    d["sps_max_sub_layers_minus1"] = msl
    d["sps_temporal_id_nesting_flag"] = r.u(1)
    d["ptl"] = ptl(r, msl)
    sid = r.ue()
    d["sps_seq_parameter_set_id"] = sid
    cf = r.ue()
    d["chroma_format_idc"] = cf
    d["separate_colour_plane_flag"] = r.u1() if cf == 3 else 0
    d["ChromaArrayType"] = 0 if d["separate_colour_plane_flag"] else cf
    w = r.ue()
    h = r.ue()
    d["pic_width_in_luma_samples"] = w
    d["pic_height_in_luma_samples"] = h
    cw = r.u1()
    d["conformance_window_flag"] = cw
    if cw:
        d["conf_win"] = {"left": r.ue(), "right": r.ue(), "top": r.ue(), "bottom": r.ue()}
    d["bit_depth_luma_minus8"] = r.ue()
    d["bit_depth_chroma_minus8"] = r.ue()
    lm = chk(r.ue(), 12, "log2_max_pic_order_cnt_lsb_minus4")
    d["log2_max_pic_order_cnt_lsb_minus4"] = lm
    d["poc_lsb_bits"] = lm + 4
    oip = r.u1()
    d["sps_sub_layer_ordering_info_present_flag"] = oip
    ord_ = []
    for _ in range(0 if oip else msl, msl + 1):
        ord_.append({"max_dec_pic_buffering_minus1": r.ue(),
                     "max_num_reorder_pics": r.ue(),
                     "max_latency_increase_plus1": r.ue()})
    d["sub_layer_ordering_info"] = ord_
    mincb_m3 = chk(r.ue(), 16, "log2_min_luma_coding_block_size_minus3")
    diffcb = chk(r.ue(), 16, "log2_diff_max_min_luma_coding_block_size")
    mintb_m2 = chk(r.ue(), 16, "log2_min_luma_transform_block_size_minus2")
    difftb = chk(r.ue(), 16, "log2_diff_max_min_luma_transform_block_size")
    d["log2_min_luma_coding_block_size_minus3"] = mincb_m3
    d["log2_diff_max_min_luma_coding_block_size"] = diffcb
    d["log2_min_luma_transform_block_size_minus2"] = mintb_m2
    d["log2_diff_max_min_luma_transform_block_size"] = difftb
    d["max_transform_hierarchy_depth_inter"] = r.ue()
    d["max_transform_hierarchy_depth_intra"] = r.ue()
    sl = r.u1()
    d["scaling_list_enabled_flag"] = sl
    d["sps_scaling_list_data_present_flag"] = 0
    if sl:
        d["sps_scaling_list_data_present_flag"] = r.u1()
        if d["sps_scaling_list_data_present_flag"]:
            scaling_list_data(r)
    d["amp_enabled_flag"] = r.u1()
    sao = r.u1()
    d["sample_adaptive_offset_enabled_flag"] = sao
    pcm = r.u1()
    d["pcm_enabled_flag"] = pcm
    if pcm:
        d["pcm_sample_bit_depth_luma_minus1"] = r.u(4)
        d["pcm_sample_bit_depth_chroma_minus1"] = r.u(4)
        d["log2_min_pcm_luma_coding_block_size_minus3"] = r.ue()
        d["log2_diff_max_min_pcm_luma_coding_block_size"] = r.ue()
        d["pcm_loop_filter_disabled_flag"] = r.u1()
    ns = r.ue()
    d["num_short_term_ref_pic_sets"] = ns
    if ns > 64:
        raise ValueError("num_short_term_ref_pic_sets=%d out of range" % ns)
    sets = []
    for i in range(ns):
        sets.append(st_rps(r, i, sets, ns))
    d["st_rps"] = sets
    lt = r.u1()
    d["long_term_ref_pics_present_flag"] = lt
    d["num_long_term_ref_pics_sps"] = 0
    if lt:
        nlt = chk(r.ue(), 64, "num_long_term_ref_pics_sps")
        d["num_long_term_ref_pics_sps"] = nlt
        lts = []
        for _ in range(nlt):
            lts.append({"lt_ref_pic_poc_lsb_sps": r.u(lm + 4),
                        "used_by_curr_pic_lt_sps_flag": r.u1()})
        d["lt_ref_pics_sps"] = lts
    d["sps_temporal_mvp_enabled_flag"] = r.u1()
    d["strong_intra_smoothing_enabled_flag"] = r.u1()
    vp = r.u1()
    d["vui_parameters_present_flag"] = vp
    vs = ""
    if vp:
        try:
            d["vui"] = vui(r, msl)
            vs = " vui{%s}" % vui_str(d["vui"])
        except Exception as e:
            d["vui_error"] = str(e)
            vs = " vui parse failed (%s)" % e

    # derived (sec 7.4.3.2.1)
    ctb_log2 = mincb_m3 + 3 + diffcb
    d["CtbLog2SizeY"] = ctb_log2
    d["CtbSizeY"] = 1 << ctb_log2
    d["MinCbSizeY"] = 1 << (mincb_m3 + 3)
    d["MinTbSizeY"] = 1 << (mintb_m2 + 2)
    d["MaxTbSizeY"] = 1 << (mintb_m2 + 2 + difftb)
    d["PicWidthInCtbsY"] = (w + d["CtbSizeY"] - 1) // d["CtbSizeY"]
    d["PicHeightInCtbsY"] = (h + d["CtbSizeY"] - 1) // d["CtbSizeY"]
    d["PicSizeInCtbsY"] = d["PicWidthInCtbsY"] * d["PicHeightInCtbsY"]
    SPS[sid] = d

    o = ["id=%d vps=%d" % (sid, d["sps_video_parameter_set_id"]),
         "sublayers=%d tid_nesting=%d" % (msl + 1, d["sps_temporal_id_nesting_flag"]),
         ptl_str(d["ptl"]),
         "chroma_idc=%d%s" % (cf, " sep_colour_plane" if d["separate_colour_plane_flag"] else ""),
         "%dx%d" % (w, h),
         "depth=%d/%d" % (d["bit_depth_luma_minus8"] + 8, d["bit_depth_chroma_minus8"] + 8)]
    if cw:
        c = d["conf_win"]
        o.append("confwin=l%d,r%d,t%d,b%d" % (c["left"], c["right"], c["top"], c["bottom"]))
    o += ["poc_lsb_bits=%d" % (lm + 4),
          "dpb=%s" % ",".join("%d/%d/%d" % (x["max_dec_pic_buffering_minus1"] + 1,
                                            x["max_num_reorder_pics"],
                                            x["max_latency_increase_plus1"]) for x in ord_),
          "ctb=%d mincb=%d tb=%d..%d" % (d["CtbSizeY"], d["MinCbSizeY"],
                                         d["MinTbSizeY"], d["MaxTbSizeY"]),
          "ctbs=%dx%d(%d)" % (d["PicWidthInCtbsY"], d["PicHeightInCtbsY"], d["PicSizeInCtbsY"]),
          "tdepth=%d/%d" % (d["max_transform_hierarchy_depth_inter"],
                            d["max_transform_hierarchy_depth_intra"]),
          "scaling=%d/%d" % (sl, d["sps_scaling_list_data_present_flag"]),
          "amp=%d sao=%d pcm=%d" % (d["amp_enabled_flag"], sao, pcm),
          "tmvp=%d sis=%d" % (d["sps_temporal_mvp_enabled_flag"],
                              d["strong_intra_smoothing_enabled_flag"]),
          "nstrps=%d" % ns]
    for i, s in enumerate(sets):
        o.append("rps%d{%s%s}" % (i, "inter " if s["inter"] else "", rps_str(s)))
    o.append("lt=%d(%d)" % (lt, d["num_long_term_ref_pics_sps"]))
    if lt and d.get("lt_ref_pics_sps"):
        o.append("ltsps=[" + ",".join("%d%s" % (x["lt_ref_pic_poc_lsb_sps"],
                 "u" if x["used_by_curr_pic_lt_sps_flag"] else "-")
                 for x in d["lt_ref_pics_sps"]) + "]")
    o.append("vui=%d" % vp)
    return " ".join(o) + vs, d


def pps(n):
    r = BR(n[2:])
    d = {}
    pid = r.ue()
    d["pps_pic_parameter_set_id"] = pid
    d["pps_seq_parameter_set_id"] = r.ue()
    d["dependent_slice_segments_enabled_flag"] = r.u1()
    d["output_flag_present_flag"] = r.u1()
    d["num_extra_slice_header_bits"] = r.u(3)
    d["sign_data_hiding_enabled_flag"] = r.u1()
    d["cabac_init_present_flag"] = r.u1()
    d["num_ref_idx_l0_default_active_minus1"] = r.ue()
    d["num_ref_idx_l1_default_active_minus1"] = r.ue()
    iq = r.se()
    d["init_qp_minus26"] = iq
    d["init_qp"] = 26 + iq
    d["constrained_intra_pred_flag"] = r.u1()
    d["transform_skip_enabled_flag"] = r.u1()
    cq = r.u1()
    d["cu_qp_delta_enabled_flag"] = cq
    d["diff_cu_qp_delta_depth"] = r.ue() if cq else 0
    d["pps_cb_qp_offset"] = r.se()
    d["pps_cr_qp_offset"] = r.se()
    d["pps_slice_chroma_qp_offsets_present_flag"] = r.u1()
    d["weighted_pred_flag"] = r.u1()
    d["weighted_bipred_flag"] = r.u1()
    d["transquant_bypass_enabled_flag"] = r.u1()
    ti = r.u1()
    d["tiles_enabled_flag"] = ti
    d["entropy_coding_sync_enabled_flag"] = r.u1()
    if ti:
        nc = chk(r.ue(), 1023, "num_tile_columns_minus1")
        nr = chk(r.ue(), 1023, "num_tile_rows_minus1")
        d["num_tile_columns_minus1"] = nc
        d["num_tile_rows_minus1"] = nr
        us = r.u1()
        d["uniform_spacing_flag"] = us
        if not us:
            d["column_width_minus1"] = [r.ue() for _ in range(nc)]
            d["row_height_minus1"] = [r.ue() for _ in range(nr)]
        d["loop_filter_across_tiles_enabled_flag"] = r.u1()
    d["pps_loop_filter_across_slices_enabled_flag"] = r.u1()
    df = r.u1()
    d["deblocking_filter_control_present_flag"] = df
    d["deblocking_filter_override_enabled_flag"] = 0
    d["pps_deblocking_filter_disabled_flag"] = 0
    d["pps_beta_offset_div2"] = 0
    d["pps_tc_offset_div2"] = 0
    if df:
        d["deblocking_filter_override_enabled_flag"] = r.u1()
        dis = r.u1()
        d["pps_deblocking_filter_disabled_flag"] = dis
        if not dis:
            d["pps_beta_offset_div2"] = r.se()
            d["pps_tc_offset_div2"] = r.se()
    sl = r.u1()
    d["pps_scaling_list_data_present_flag"] = sl
    if sl:
        scaling_list_data(r)
    d["lists_modification_present_flag"] = r.u1()
    d["log2_parallel_merge_level_minus2"] = r.ue()
    d["slice_segment_header_extension_present_flag"] = r.u1()
    PPS[pid] = d

    o = ["id=%d sps=%d" % (pid, d["pps_seq_parameter_set_id"]),
         "dep_slices=%d output_flag=%d extra_bits=%d" % (
             d["dependent_slice_segments_enabled_flag"], d["output_flag_present_flag"],
             d["num_extra_slice_header_bits"]),
         "sdh=%d cabac_init=%d" % (d["sign_data_hiding_enabled_flag"],
                                   d["cabac_init_present_flag"]),
         "nref=%d/%d" % (d["num_ref_idx_l0_default_active_minus1"] + 1,
                         d["num_ref_idx_l1_default_active_minus1"] + 1),
         "init_qp=%d" % d["init_qp"],
         "cip=%d tskip=%d cuqp=%d(depth=%d)" % (
             d["constrained_intra_pred_flag"], d["transform_skip_enabled_flag"],
             cq, d["diff_cu_qp_delta_depth"]),
         "cbcr_qp_off=%d/%d slice_chroma_off=%d" % (
             d["pps_cb_qp_offset"], d["pps_cr_qp_offset"],
             d["pps_slice_chroma_qp_offsets_present_flag"]),
         "wp=%d wbp=%d tqbypass=%d" % (d["weighted_pred_flag"], d["weighted_bipred_flag"],
                                       d["transquant_bypass_enabled_flag"]),
         "tiles=%d" % ti]
    if ti:
        o.append("tilegeom=%dx%d uniform=%d lf_across=%d" % (
            d["num_tile_columns_minus1"] + 1, d["num_tile_rows_minus1"] + 1,
            d["uniform_spacing_flag"], d["loop_filter_across_tiles_enabled_flag"]))
        if not d["uniform_spacing_flag"]:
            o.append("cols=%s rows=%s" % (d["column_width_minus1"], d["row_height_minus1"]))
    o += ["wpp=%d" % d["entropy_coding_sync_enabled_flag"],
          "lf_across_slices=%d" % d["pps_loop_filter_across_slices_enabled_flag"],
          "dbf_ctrl=%d(override=%d disabled=%d beta=%d tc=%d)" % (
              df, d["deblocking_filter_override_enabled_flag"],
              d["pps_deblocking_filter_disabled_flag"],
              d["pps_beta_offset_div2"], d["pps_tc_offset_div2"]),
          "scaling=%d" % sl,
          "lists_mod=%d" % d["lists_modification_present_flag"],
          "par_merge_lvl=%d" % (d["log2_parallel_merge_level_minus2"] + 2),
          "sh_ext=%d" % d["slice_segment_header_extension_present_flag"]]
    return " ".join(o), d


# ------------------------------------------------------------------- slice header
STYPE = {0: "B", 1: "P", 2: "I"}


def slice_header(n, nut):
    r = BR(n[2:])
    d = {"nal_unit_type": nut}
    first = r.u1()
    d["first_slice_segment_in_pic_flag"] = first
    if 16 <= nut <= 23:
        d["no_output_of_prior_pics_flag"] = r.u1()
    pid = r.ue()
    d["slice_pic_parameter_set_id"] = pid
    p = PPS.get(pid)
    if p is None:
        return "slice pps=%d (no PPS yet)" % pid, d
    s = SPS.get(p["pps_seq_parameter_set_id"])
    if s is None:
        return "slice pps=%d (no SPS yet)" % pid, d

    dep = 0
    if not first:
        if p["dependent_slice_segments_enabled_flag"]:
            dep = r.u1()
        d["slice_segment_address"] = r.u(clog2(s["PicSizeInCtbsY"]))
    d["dependent_slice_segment_flag"] = dep
    o = ["first=%d" % first]
    if "slice_segment_address" in d:
        o.append("addr=%d" % d["slice_segment_address"])
    if dep:
        o.append("dependent")
        return "slice " + " ".join(o), d

    for i in range(p["num_extra_slice_header_bits"]):
        d.setdefault("slice_reserved_flag", []).append(r.u1())
    st = r.ue()
    d["slice_type"] = st
    o.append("type=%s(%d)" % (STYPE.get(st, "?"), st))
    if p["output_flag_present_flag"]:
        d["pic_output_flag"] = r.u1()
        o.append("output=%d" % d["pic_output_flag"])
    if s["separate_colour_plane_flag"]:
        d["colour_plane_id"] = r.u(2)
        o.append("plane=%d" % d["colour_plane_id"])

    curr = None
    num_lt_used = 0
    tmvp = 0
    if nut not in (19, 20):                     # not IDR
        d["slice_pic_order_cnt_lsb"] = r.u(s["poc_lsb_bits"])
        o.append("poc_lsb=%d" % d["slice_pic_order_cnt_lsb"])
        sf = r.u1()
        d["short_term_ref_pic_set_sps_flag"] = sf
        ns = s["num_short_term_ref_pic_sets"]
        if not sf:
            curr = st_rps(r, ns, s["st_rps"], ns)
            d["st_rps_inline"] = curr
            o.append("rps=inline")
        else:
            idx = 0
            if ns > 1:
                idx = r.u(clog2(ns))
            d["short_term_ref_pic_set_idx"] = idx
            curr = s["st_rps"][idx] if idx < ns else {"neg": [], "pos": []}
            o.append("rps=sps[%d]" % idx)
        o.append("{%s}" % rps_str(curr))
        if s["long_term_ref_pics_present_flag"]:
            n_sps = 0
            if s["num_long_term_ref_pics_sps"] > 0:
                n_sps = chk(r.ue(), 64, "num_long_term_sps")
            n_pics = chk(r.ue(), 64, "num_long_term_pics")
            d["num_long_term_sps"] = n_sps
            d["num_long_term_pics"] = n_pics
            lts = []
            for i in range(n_sps + n_pics):
                e = {}
                if i < n_sps:
                    if s["num_long_term_ref_pics_sps"] > 1:
                        e["lt_idx_sps"] = r.u(clog2(s["num_long_term_ref_pics_sps"]))
                    j = e.get("lt_idx_sps", 0)
                    e["used"] = s["lt_ref_pics_sps"][j]["used_by_curr_pic_lt_sps_flag"]
                    e["poc_lsb_lt"] = s["lt_ref_pics_sps"][j]["lt_ref_pic_poc_lsb_sps"]
                else:
                    e["poc_lsb_lt"] = r.u(s["poc_lsb_bits"])
                    e["used"] = r.u1()
                if e["used"]:
                    num_lt_used += 1
                e["delta_poc_msb_present_flag"] = r.u1()
                if e["delta_poc_msb_present_flag"]:
                    e["delta_poc_msb_cycle_lt"] = r.ue()
                lts.append(e)
            d["long_term"] = lts
            o.append("lt=%d+%d(used=%d)" % (n_sps, n_pics, num_lt_used))
        if s["sps_temporal_mvp_enabled_flag"]:
            tmvp = r.u1()
            d["slice_temporal_mvp_enabled_flag"] = tmvp
            o.append("tmvp=%d" % tmvp)
    else:
        curr = {"neg": [], "pos": []}

    npt = sum(u for _, u in curr["neg"]) + sum(u for _, u in curr["pos"]) + num_lt_used
    d["NumPicTotalCurr"] = npt
    o.append("NumPicTotalCurr=%d" % npt)

    sao_l = sao_c = 0
    if s["sample_adaptive_offset_enabled_flag"]:
        sao_l = r.u1()
        if s["ChromaArrayType"] != 0:
            sao_c = r.u1()
        d["slice_sao_luma_flag"] = sao_l
        d["slice_sao_chroma_flag"] = sao_c
        o.append("sao=%d/%d" % (sao_l, sao_c))

    nl0 = p["num_ref_idx_l0_default_active_minus1"]
    nl1 = p["num_ref_idx_l1_default_active_minus1"]
    if st in (0, 1):                            # P or B
        ov = r.u1()
        d["num_ref_idx_active_override_flag"] = ov
        if ov:
            nl0 = chk(r.ue(), 64, "num_ref_idx_l0_active_minus1")
            if st == 0:
                nl1 = chk(r.ue(), 64, "num_ref_idx_l1_active_minus1")
        d["num_ref_idx_l0_active_minus1"] = nl0
        d["num_ref_idx_l1_active_minus1"] = nl1
        o.append("nref=%d%s" % (nl0 + 1, ("/%d" % (nl1 + 1)) if st == 0 else ""))
        if p["lists_modification_present_flag"] and npt > 1:
            bits = clog2(npt)
            m = {}
            f0 = r.u1()
            m["ref_pic_list_modification_flag_l0"] = f0
            if f0:
                m["list_entry_l0"] = [r.u(bits) for _ in range(nl0 + 1)]
            if st == 0:
                f1 = r.u1()
                m["ref_pic_list_modification_flag_l1"] = f1
                if f1:
                    m["list_entry_l1"] = [r.u(bits) for _ in range(nl1 + 1)]
            d["ref_pic_lists_modification"] = m
            o.append("listmod=l0%s%s" % (
                m.get("list_entry_l0", "on" if f0 else "off"),
                ("/l1%s" % m.get("list_entry_l1", "on" if m.get(
                    "ref_pic_list_modification_flag_l1") else "off")) if st == 0 else ""))
        if st == 0:
            d["mvd_l1_zero_flag"] = r.u1()
            o.append("mvd_l1_zero=%d" % d["mvd_l1_zero_flag"])
        if p["cabac_init_present_flag"]:
            d["cabac_init_flag"] = r.u1()
            o.append("cabac_init=%d" % d["cabac_init_flag"])
        if tmvp:
            col_l0 = 1
            if st == 0:
                col_l0 = r.u1()
                d["collocated_from_l0_flag"] = col_l0
            if (col_l0 and nl0 > 0) or ((not col_l0) and nl1 > 0):
                d["collocated_ref_idx"] = r.ue()
            o.append("collocated=l%d[%d]" % (0 if col_l0 else 1, d.get("collocated_ref_idx", 0)))
        if (p["weighted_pred_flag"] and st == 1) or (p["weighted_bipred_flag"] and st == 0):
            d["pred_weight_table"] = "not parsed"
            return "slice " + " ".join(o) + " weighted (not parsed)", d
        d["five_minus_max_num_merge_cand"] = r.ue()
        d["MaxNumMergeCand"] = 5 - d["five_minus_max_num_merge_cand"]
        o.append("merge_cand=%d" % d["MaxNumMergeCand"])

    sqd = r.se()
    d["slice_qp_delta"] = sqd
    d["SliceQpY"] = 26 + p["init_qp_minus26"] + sqd
    o.append("qp=%d(delta=%+d)" % (d["SliceQpY"], sqd))
    if p["pps_slice_chroma_qp_offsets_present_flag"]:
        d["slice_cb_qp_offset"] = r.se()
        d["slice_cr_qp_offset"] = r.se()
        o.append("slice_cbcr_off=%d/%d" % (d["slice_cb_qp_offset"], d["slice_cr_qp_offset"]))
    # NOTE: pps_range_extension's chroma_qp_offset_list_enabled_flag (-> cu_chroma_qp_offset
    # _enabled_flag) is not parsed; assumed 0 (no PPS extension in these streams).
    dbf_dis = p["pps_deblocking_filter_disabled_flag"]
    if p["deblocking_filter_override_enabled_flag"]:
        ovf = r.u1()
        d["deblocking_filter_override_flag"] = ovf
        if ovf:
            dbf_dis = r.u1()
            d["slice_deblocking_filter_disabled_flag"] = dbf_dis
            if not dbf_dis:
                d["slice_beta_offset_div2"] = r.se()
                d["slice_tc_offset_div2"] = r.se()
            o.append("dbf_override(dis=%d beta=%d tc=%d)" % (
                dbf_dis, d.get("slice_beta_offset_div2", 0), d.get("slice_tc_offset_div2", 0)))
    if p["pps_loop_filter_across_slices_enabled_flag"] and (sao_l or sao_c or not dbf_dis):
        d["slice_loop_filter_across_slices_enabled_flag"] = r.u1()
        o.append("lf_across=%d" % d["slice_loop_filter_across_slices_enabled_flag"])
    return "slice " + " ".join(o), d


# --------------------------------------------------------------------------- SEI
SEI_T = {0: "buffering_period", 1: "pic_timing", 3: "filler", 4: "user_data_registered",
         5: "user_data_unregistered", 6: "recovery_point", 129: "active_parameter_sets",
         132: "decoded_picture_hash", 133: "scalable_nesting", 135: "time_code",
         137: "mastering_display_colour_volume", 144: "content_light_level",
         147: "alternative_transfer_characteristics"}


def sei(n):
    r = BR(n[2:])
    out = []
    ms = []
    while r.more():
        t = 0
        while True:
            b = r.u(8)
            t += b
            if b != 255:
                break
        sz = 0
        while True:
            b = r.u(8)
            sz += b
            if b != 255:
                break
        ms.append({"payload_type": t, "payload_size": sz})
        out.append("%s(%d,%dB)" % (SEI_T.get(t, "type%d" % t), t, sz))
        r.p += sz * 8
        if (r.p >> 3) >= len(r.b) or r.b[r.p >> 3] == 0x80:
            break
    return " ".join(out) if out else "(empty)", {"messages": ms}


# --------------------------------------------------------------------- NAL split
def nals(data):
    """Split Annex-B: returns list of NAL payloads (start codes + trailing zeros stripped)."""
    starts = []
    j = 0
    while True:
        k = data.find(b"\x00\x00\x01", j)
        if k < 0:
            break
        starts.append(k + 3)
        j = k + 3
    out = []
    n = len(data)
    for i, a in enumerate(starts):
        e = (starts[i + 1] - 3) if i + 1 < len(starts) else n
        while e > a and data[e - 1] == 0:      # trailing_zero_8bits / 4-byte start code
            e -= 1
        if e > a:
            out.append(data[a:e])
    return out


# --------------------------------------------------------------------------- main
def parse_nal(n):
    t = (n[0] >> 1) & 0x3f
    lid = ((n[0] & 1) << 5) | (n[1] >> 3)
    tid = (n[1] & 7)
    d = {"size": len(n), "nal_unit_type": t, "name": ntname(t),
         "nuh_layer_id": lid, "temporal_id_plus1": tid}
    pre = "lid=%d tid=%d" % (lid, tid)
    if len(n) < 2:
        return "%s truncated NAL" % pre, d
    try:
        if t == 32:
            sm, x = vps(n)
        elif t == 33:
            sm, x = sps(n)
        elif t == 34:
            sm, x = pps(n)
        elif t in (39, 40):
            sm, x = sei(n)
        elif t <= 21:
            sm, x = slice_header(n, t)
        else:
            sm, x = "", {}
        d.update(x)
        return (pre + " " + sm).rstrip(), d
    except Exception as e:
        d["error"] = "%s: %s" % (type(e).__name__, e)
        return "%s parse error: %s" % (pre, e), d


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    as_json = "--json" in argv[1:]
    if not args:
        print(__doc__)
        return 2
    data = open(args[0], "rb").read()
    res = []
    for n in nals(data):
        s, d = parse_nal(n)
        d["summary"] = s
        res.append(d)
        if not as_json:
            print("  %d %s(%d) %s" % (len(n), d["name"], d["nal_unit_type"], s))
    if as_json:
        print(json.dumps(res, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
