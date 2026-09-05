// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * From-source H.265/HEVC VPS/SPS/PPS emission for the open VC8000E fixed-QP
 * path (#64).
 *
 * The hardware emits slice NALs only. Every field below that the hardware-
 * written slice header and CTU data depend on is pinned to the configuration
 * the silicon was observed encoding with (docs/reference/vcenc-open/
 * vendor-diff-hevc-20260905/REPORT.md, H1/H3/H5 parses): CTB 64, min CB 8,
 * TB 4..16, max TU depth inter 4 / intra 2, AMP on, SAO on, PCM off, TMVP off,
 * strong intra smoothing off, no scaling lists, log2_max_pic_order_cnt_lsb =
 * 16 (the core writes poc_lsb from swreg11), two identical short-term RPS
 * sets {delta -1, used}, no long-term refs, CABAC init present, one reference
 * per list, cu_qp_delta OFF (the vendor's fixed-QP PPS; its CBR PPS turns it
 * on), sign-data-hiding / transform-skip / weighted prediction / tiles / WPP
 * off, deblocking control present with override off, parallel merge level 2.
 * pic_init_qp must equal the register program's frame QP (slice_qp_delta is
 * written as 0). The VUI is the vendor's (video_format 5 unspecified, full
 * range, colour 5/1/5, 60 fps timing, bitstream restriction with mv lengths
 * 10/8). Picture dimensions are min-CB (8) aligned with a conformance window
 * for the remainder, as the vendor does at 1366x768.
 *
 * With level_idc 153 the 1080p output is byte-identical to the vendor's
 * fixed-QP32 VPS/SPS/PPS (tests/hevc_header_test.c). Syntax is written from
 * ITU-T H.265 (2016) clauses 7.3.2.1-7.3.2.3, 7.3.3, 7.3.7 and E.2.1 -- no
 * vendor code involved. Reuses the bit writer of vcenc_header.h.
 */
#ifndef VCENC_HEVC_HEADER_H
#define VCENC_HEVC_HEADER_H

#include <stdint.h>
#include <string.h>
#include "vcenc_header.h"

/* profile_tier_level(1, 0): Main profile, Main tier, no sub-layers. */
static void hevc_ptl(struct bitw *w, uint32_t level_idc)
{
	bw_u(w, 0, 2);          /* general_profile_space */
	bw_u(w, 0, 1);          /* general_tier_flag: Main tier */
	bw_u(w, 1, 5);          /* general_profile_idc: Main */
	bw_u(w, 0x40000000u, 32); /* general_profile_compatibility_flag[1] */
	bw_u(w, 1, 1);          /* general_progressive_source_flag */
	bw_u(w, 0, 1);          /* general_interlaced_source_flag */
	bw_u(w, 0, 1);          /* general_non_packed_constraint_flag */
	bw_u(w, 0, 1);          /* general_frame_only_constraint_flag */
	bw_u(w, 0, 32);         /* general_reserved_zero_43bits ... */
	bw_u(w, 0, 11);         /* ... (43) */
	bw_u(w, 0, 1);          /* general_reserved_zero_bit / inbld */
	bw_u(w, level_idc, 8);  /* general_level_idc */
	/* sps_max_sub_layers_minus1 == 0: no sub-layer flags */
}

/* Smallest HEVC level whose MaxLumaPs and MaxLumaSr (Table A.8, Main tier)
 * hold the picture at 60 fps. level_idc = level * 30. */
static inline uint32_t vcenc_hevc_level_idc(uint32_t w, uint32_t h)
{
	static const struct { uint32_t ps; uint64_t sr; uint32_t idc; } lvl[] = {
		{ 2228224u,  133693440ull, 123 },   /* 4.1 */
		{ 8912896u,  267386880ull, 150 },   /* 5   */
		{ 8912896u,  534773760ull, 153 },   /* 5.1 */
		{ 8912896u, 1069547520ull, 156 },   /* 5.2 */
	};
	uint64_t ps = (uint64_t)w * h;
	for (unsigned i = 0; i < sizeof lvl / sizeof lvl[0]; i++)
		if (ps <= lvl[i].ps && ps * 60 <= lvl[i].sr)
			return lvl[i].idc;
	return 156;
}

/* Annex-B VPS NAL (start code included). */
static uint32_t vcenc_write_vps(uint8_t *out, uint32_t level_idc)
{
	static const uint8_t sc[6] = { 0, 0, 0, 1, 0x40, 0x01 }; /* nal 32 */
	struct bitw w;
	memset(&w, 0, sizeof w);
	bw_u(&w, 0, 4);         /* vps_video_parameter_set_id */
	bw_u(&w, 1, 1);         /* vps_base_layer_internal_flag */
	bw_u(&w, 1, 1);         /* vps_base_layer_available_flag */
	bw_u(&w, 0, 6);         /* vps_max_layers_minus1 */
	bw_u(&w, 0, 3);         /* vps_max_sub_layers_minus1 */
	bw_u(&w, 1, 1);         /* vps_temporal_id_nesting_flag */
	bw_u(&w, 0xffff, 16);   /* vps_reserved_0xffff_16bits */
	hevc_ptl(&w, level_idc);
	bw_u(&w, 1, 1);         /* vps_sub_layer_ordering_info_present_flag */
	bw_ue(&w, 1);           /* vps_max_dec_pic_buffering_minus1 */
	bw_ue(&w, 0);           /* vps_max_num_reorder_pics */
	bw_ue(&w, 0);           /* vps_max_latency_increase_plus1 */
	bw_u(&w, 0, 6);         /* vps_max_layer_id */
	bw_ue(&w, 0);           /* vps_num_layer_sets_minus1 */
	bw_u(&w, 0, 1);         /* vps_timing_info_present_flag */
	bw_u(&w, 0, 1);         /* vps_extension_flag */
	memcpy(out, sc, 6);
	return 6 + bw_finish(&w, out + 6);
}

/* Annex-B SPS NAL for a progressive 4:2:0 8-bit stream of WxH (even). */
static uint32_t vcenc_write_hevc_sps(uint8_t *out, uint32_t width,
				     uint32_t height, uint32_t level_idc)
{
	static const uint8_t sc[6] = { 0, 0, 0, 1, 0x42, 0x01 }; /* nal 33 */
	uint32_t w8 = (width + 7) & ~7u, h8 = (height + 7) & ~7u;
	uint32_t win_r = (w8 - width) / 2, win_b = (h8 - height) / 2;
	struct bitw w;
	memset(&w, 0, sizeof w);
	bw_u(&w, 0, 4);         /* sps_video_parameter_set_id */
	bw_u(&w, 0, 3);         /* sps_max_sub_layers_minus1 */
	bw_u(&w, 1, 1);         /* sps_temporal_id_nesting_flag */
	hevc_ptl(&w, level_idc);
	bw_ue(&w, 0);           /* sps_seq_parameter_set_id */
	bw_ue(&w, 1);           /* chroma_format_idc: 4:2:0 */
	bw_ue(&w, w8);          /* pic_width_in_luma_samples (MinCb aligned) */
	bw_ue(&w, h8);          /* pic_height_in_luma_samples */
	bw_u(&w, (win_r || win_b) != 0, 1); /* conformance_window_flag */
	if (win_r || win_b) {
		bw_ue(&w, 0);       /* conf_win_left_offset */
		bw_ue(&w, win_r);   /* conf_win_right_offset (SubWidthC units) */
		bw_ue(&w, 0);       /* conf_win_top_offset */
		bw_ue(&w, win_b);   /* conf_win_bottom_offset */
	}
	bw_ue(&w, 0);           /* bit_depth_luma_minus8 */
	bw_ue(&w, 0);           /* bit_depth_chroma_minus8 */
	bw_ue(&w, 12);          /* log2_max_pic_order_cnt_lsb_minus4 -> 16 (pinned) */
	bw_u(&w, 1, 1);         /* sps_sub_layer_ordering_info_present_flag */
	bw_ue(&w, 1);           /* sps_max_dec_pic_buffering_minus1 */
	bw_ue(&w, 0);           /* sps_max_num_reorder_pics */
	bw_ue(&w, 0);           /* sps_max_latency_increase_plus1 */
	bw_ue(&w, 0);           /* log2_min_luma_coding_block_size_minus3 -> 8 */
	bw_ue(&w, 3);           /* log2_diff_max_min_luma_coding_block_size -> CTB 64 */
	bw_ue(&w, 0);           /* log2_min_luma_transform_block_size_minus2 -> 4 */
	bw_ue(&w, 2);           /* log2_diff_max_min_luma_transform_block_size -> 16 */
	bw_ue(&w, 4);           /* max_transform_hierarchy_depth_inter */
	bw_ue(&w, 2);           /* max_transform_hierarchy_depth_intra */
	bw_u(&w, 0, 1);         /* scaling_list_enabled_flag */
	bw_u(&w, 1, 1);         /* amp_enabled_flag */
	bw_u(&w, 1, 1);         /* sample_adaptive_offset_enabled_flag */
	bw_u(&w, 0, 1);         /* pcm_enabled_flag */
	bw_ue(&w, 2);           /* num_short_term_ref_pic_sets */
	for (int i = 0; i < 2; i++) {   /* st_ref_pic_set(i): {-1, used} */
		if (i)
			bw_u(&w, 0, 1); /* inter_ref_pic_set_prediction_flag */
		bw_ue(&w, 1);       /* num_negative_pics */
		bw_ue(&w, 0);       /* num_positive_pics */
		bw_ue(&w, 0);       /* delta_poc_s0_minus1 */
		bw_u(&w, 1, 1);     /* used_by_curr_pic_s0_flag */
	}
	bw_u(&w, 0, 1);         /* long_term_ref_pics_present_flag */
	bw_u(&w, 0, 1);         /* sps_temporal_mvp_enabled_flag */
	bw_u(&w, 0, 1);         /* strong_intra_smoothing_enabled_flag */
	bw_u(&w, 1, 1);         /* vui_parameters_present_flag */
	/* vui_parameters() */
	bw_u(&w, 0, 1);         /* aspect_ratio_info_present_flag */
	bw_u(&w, 0, 1);         /* overscan_info_present_flag */
	bw_u(&w, 1, 1);         /* video_signal_type_present_flag */
	bw_u(&w, 5, 3);         /* video_format: unspecified */
	bw_u(&w, 1, 1);         /* video_full_range_flag */
	bw_u(&w, 1, 1);         /* colour_description_present_flag */
	bw_u(&w, 5, 8);         /* colour_primaries */
	bw_u(&w, 1, 8);         /* transfer_characteristics */
	bw_u(&w, 5, 8);         /* matrix_coeffs */
	bw_u(&w, 0, 1);         /* chroma_loc_info_present_flag */
	bw_u(&w, 0, 1);         /* neutral_chroma_indication_flag */
	bw_u(&w, 0, 1);         /* field_seq_flag */
	bw_u(&w, 0, 1);         /* frame_field_info_present_flag */
	bw_u(&w, 0, 1);         /* default_display_window_flag */
	bw_u(&w, 1, 1);         /* vui_timing_info_present_flag */
	bw_u(&w, 1, 32);        /* vui_num_units_in_tick */
	bw_u(&w, 60, 32);       /* vui_time_scale */
	bw_u(&w, 0, 1);         /* vui_poc_proportional_to_timing_flag */
	bw_u(&w, 0, 1);         /* vui_hrd_parameters_present_flag */
	bw_u(&w, 1, 1);         /* bitstream_restriction_flag */
	bw_u(&w, 1, 1);         /* tiles_fixed_structure_flag */
	bw_u(&w, 1, 1);         /* motion_vectors_over_pic_boundaries_flag */
	bw_u(&w, 1, 1);         /* restricted_ref_pic_lists_flag */
	bw_ue(&w, 0);           /* min_spatial_segmentation_idc */
	bw_ue(&w, 0);           /* max_bytes_per_pic_denom */
	bw_ue(&w, 0);           /* max_bits_per_min_cu_denom */
	bw_ue(&w, 10);          /* log2_max_mv_length_horizontal */
	bw_ue(&w, 8);           /* log2_max_mv_length_vertical */
	bw_u(&w, 0, 1);         /* sps_extension_present_flag */
	memcpy(out, sc, 6);
	return 6 + bw_finish(&w, out + 6);
}

/* Annex-B PPS NAL. pic_init_qp must equal the register program's frame QP. */
static uint32_t vcenc_write_hevc_pps(uint8_t *out, uint32_t pic_init_qp)
{
	static const uint8_t sc[6] = { 0, 0, 0, 1, 0x44, 0x01 }; /* nal 34 */
	struct bitw w;
	memset(&w, 0, sizeof w);
	bw_ue(&w, 0);           /* pps_pic_parameter_set_id */
	bw_ue(&w, 0);           /* pps_seq_parameter_set_id */
	bw_u(&w, 0, 1);         /* dependent_slice_segments_enabled_flag */
	bw_u(&w, 0, 1);         /* output_flag_present_flag */
	bw_u(&w, 0, 3);         /* num_extra_slice_header_bits */
	bw_u(&w, 0, 1);         /* sign_data_hiding_enabled_flag */
	bw_u(&w, 1, 1);         /* cabac_init_present_flag (pinned) */
	bw_ue(&w, 0);           /* num_ref_idx_l0_default_active_minus1 */
	bw_ue(&w, 0);           /* num_ref_idx_l1_default_active_minus1 */
	bw_se(&w, (int32_t)pic_init_qp - 26);
	bw_u(&w, 0, 1);         /* constrained_intra_pred_flag */
	bw_u(&w, 0, 1);         /* transform_skip_enabled_flag */
	bw_u(&w, 0, 1);         /* cu_qp_delta_enabled_flag (fixed-QP) */
	bw_se(&w, 0);           /* pps_cb_qp_offset */
	bw_se(&w, 0);           /* pps_cr_qp_offset */
	bw_u(&w, 0, 1);         /* pps_slice_chroma_qp_offsets_present_flag */
	bw_u(&w, 0, 1);         /* weighted_pred_flag */
	bw_u(&w, 0, 1);         /* weighted_bipred_flag */
	bw_u(&w, 0, 1);         /* transquant_bypass_enabled_flag */
	bw_u(&w, 0, 1);         /* tiles_enabled_flag */
	bw_u(&w, 0, 1);         /* entropy_coding_sync_enabled_flag */
	bw_u(&w, 1, 1);         /* pps_loop_filter_across_slices_enabled_flag */
	bw_u(&w, 1, 1);         /* deblocking_filter_control_present_flag */
	bw_u(&w, 0, 1);         /* deblocking_filter_override_enabled_flag */
	bw_u(&w, 0, 1);         /* pps_deblocking_filter_disabled_flag */
	bw_se(&w, 0);           /* pps_beta_offset_div2 */
	bw_se(&w, 0);           /* pps_tc_offset_div2 */
	bw_u(&w, 0, 1);         /* pps_scaling_list_data_present_flag */
	bw_u(&w, 0, 1);         /* lists_modification_present_flag */
	bw_ue(&w, 0);           /* log2_parallel_merge_level_minus2 */
	bw_u(&w, 0, 1);         /* slice_segment_header_extension_present_flag */
	bw_u(&w, 0, 1);         /* pps_extension_present_flag */
	memcpy(out, sc, 6);
	return 6 + bw_finish(&w, out + 6);
}

/* VPS+SPS+PPS for one IDR; returns bytes written (out >= 160 bytes). */
static inline uint32_t vcenc_write_hevc_headers(uint8_t *out, uint32_t width,
						uint32_t height, uint32_t qp,
						uint32_t level_idc)
{
	uint32_t n = vcenc_write_vps(out, level_idc);
	n += vcenc_write_hevc_sps(out + n, width, height, level_idc);
	n += vcenc_write_hevc_pps(out + n, qp);
	return n;
}

#endif /* VCENC_HEVC_HEADER_H */
