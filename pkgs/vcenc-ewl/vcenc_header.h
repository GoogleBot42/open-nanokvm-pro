// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * From-source H.264 SPS/PPS emission for the open VC8000E fixed-QP path.
 *
 * The hardware emits slice NALs only; a decodable stream needs SPS+PPS whose
 * fields agree with the slice-header bit layout the core writes. Those fields
 * were pinned by parsing our own blob-free Stage B IDR slice bit-by-bit
 * (docs/blob-replacement.md, #45 Stage C): log2_max_frame_num = 16,
 * pic_order_cnt_type = 0 with log2_max_pic_order_cnt_lsb = 16, CABAC,
 * deblocking-control-present, slice_qp_delta = 0 (so pic_init_qp must equal
 * the register program's sw7 QP). With pic_init_qp=32 this PPS is
 * byte-identical to the PPS the vendor stack emits for its QP32 stream.
 *
 * Syntax is written straight from ITU-T H.264 (Rec. 03/2005) clause 7.3.2 --
 * no vendor code involved.
 */
#ifndef VCENC_HEADER_H
#define VCENC_HEADER_H

#include <stdint.h>
#include <string.h>

struct bitw {
	uint8_t buf[128];
	uint32_t bitpos;
};

static void bw_u(struct bitw *w, uint32_t val, int bits)
{
	for (int i = bits - 1; i >= 0; i--) {
		if ((val >> i) & 1)
			w->buf[w->bitpos >> 3] |= 0x80u >> (w->bitpos & 7);
		w->bitpos++;
	}
}

static void bw_ue(struct bitw *w, uint32_t val)
{
	uint32_t v = val + 1;
	int n = 32 - __builtin_clz(v);
	bw_u(w, 0, n - 1);
	bw_u(w, v, n);
}

static void bw_se(struct bitw *w, int32_t val)
{
	bw_ue(w, val > 0 ? (uint32_t)(2 * val - 1) : (uint32_t)(-2 * val));
}

/* rbsp_trailing_bits + emulation-prevention; returns NAL length. */
static uint32_t bw_finish(struct bitw *w, uint8_t *out)
{
	bw_u(w, 1, 1);                       /* rbsp_stop_one_bit */
	while (w->bitpos & 7)
		bw_u(w, 0, 1);
	uint32_t n = w->bitpos >> 3, o = 0, zeros = 0;
	for (uint32_t i = 0; i < n; i++) {
		if (zeros >= 2 && w->buf[i] <= 3) {
			out[o++] = 3;
			zeros = 0;
		}
		out[o++] = w->buf[i];
		zeros = w->buf[i] ? 0 : zeros + 1;
	}
	return o;
}

/* Annex-B SPS NAL (start code included) for a progressive 4:2:0 stream.
 * Returns bytes written. */
static uint32_t vcenc_write_sps(uint8_t *out, uint32_t width, uint32_t height)
{
	static const uint8_t sc[5] = { 0, 0, 0, 1, 0x67 };
	uint32_t mbs_w = (width + 15) / 16, mbs_h = (height + 15) / 16;
	uint32_t crop_b = (mbs_h * 16 - height) / 2;  /* 4:2:0 frame crop units */
	struct bitw w;
	memset(&w, 0, sizeof w);

	bw_u(&w, 77, 8);        /* profile_idc: Main (CABAC, no High PPS ext) */
	bw_u(&w, 0, 8);         /* constraint_set flags + reserved_zero */
	bw_u(&w, 40, 8);        /* level_idc 4.0 (1080p30) */
	bw_ue(&w, 0);           /* seq_parameter_set_id */
	bw_ue(&w, 12);          /* log2_max_frame_num_minus4 -> 16 (pinned) */
	bw_ue(&w, 0);           /* pic_order_cnt_type (pinned) */
	bw_ue(&w, 12);          /* log2_max_pic_order_cnt_lsb_minus4 -> 16 (pinned) */
	bw_ue(&w, 2);           /* max_num_ref_frames */
	bw_u(&w, 0, 1);         /* gaps_in_frame_num_value_allowed_flag */
	bw_ue(&w, mbs_w - 1);   /* pic_width_in_mbs_minus1 */
	bw_ue(&w, mbs_h - 1);   /* pic_height_in_map_units_minus1 */
	bw_u(&w, 1, 1);         /* frame_mbs_only_flag */
	bw_u(&w, 1, 1);         /* direct_8x8_inference_flag */
	bw_u(&w, crop_b != 0, 1);
	if (crop_b) {
		bw_ue(&w, 0);
		bw_ue(&w, 0);
		bw_ue(&w, 0);
		bw_ue(&w, crop_b);
	}
	bw_u(&w, 0, 1);         /* vui_parameters_present_flag */

	memcpy(out, sc, 5);
	return 5 + bw_finish(&w, out + 5);
}

/* Annex-B PPS NAL. pic_init_qp must equal the register program's sw7 QP
 * (the hardware writes slice_qp_delta = 0). */
static uint32_t vcenc_write_pps(uint8_t *out, uint32_t pic_init_qp)
{
	static const uint8_t sc[5] = { 0, 0, 0, 1, 0x68 };
	struct bitw w;
	memset(&w, 0, sizeof w);

	bw_ue(&w, 0);           /* pic_parameter_set_id */
	bw_ue(&w, 0);           /* seq_parameter_set_id */
	bw_u(&w, 1, 1);         /* entropy_coding_mode_flag: CABAC (pinned) */
	bw_u(&w, 0, 1);         /* bottom_field_pic_order_in_frame_present */
	bw_ue(&w, 0);           /* num_slice_groups_minus1 */
	bw_ue(&w, 0);           /* num_ref_idx_l0_default_active_minus1 */
	bw_ue(&w, 0);           /* num_ref_idx_l1_default_active_minus1 */
	bw_u(&w, 0, 1);         /* weighted_pred_flag */
	bw_u(&w, 0, 2);         /* weighted_bipred_idc */
	bw_se(&w, (int32_t)pic_init_qp - 26);
	bw_se(&w, 0);           /* pic_init_qs_minus26 */
	bw_se(&w, 0);           /* chroma_qp_index_offset */
	bw_u(&w, 1, 1);         /* deblocking_filter_control_present (pinned) */
	bw_u(&w, 0, 1);         /* constrained_intra_pred_flag */
	bw_u(&w, 0, 1);         /* redundant_pic_cnt_present_flag */

	memcpy(out, sc, 5);
	return 5 + bw_finish(&w, out + 5);
}

#endif /* VCENC_HEADER_H */
