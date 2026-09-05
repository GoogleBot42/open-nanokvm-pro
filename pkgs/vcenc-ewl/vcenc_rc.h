// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * vcenc_rc.h -- from-scratch frame-level rate controller for the open
 * VC8000E encoder (#46): CBR and capped-VBR, H.264 and HEVC.
 *
 * WHERE IT SITS. The controller is pure software above the per-frame
 * builder: it turns (target bitrate, fps, GOP, measured frame sizes) into
 * one frame QP, which vcenc_encode.h programs through the vendor's true
 * fixed-QP register set (ENC_RC_FIXQP -- rate control OFF in the hardware,
 * QP block from the per-frame-type tables). Codec-agnostic: the RC register
 * set is identical for H.264 and HEVC (vendor-diff-hevc-20260905 H4), and
 * so is this loop.
 *
 * WHY NOT THE HARDWARE RC-ENABLE CLUSTER. E1 identified the nine registers
 * that switch the core's own CTB-level rate control on (sw6[0], sw22[3:2],
 * the sw105..107 picture targets, sw172/173, sw245/246, the sw239/241
 * scratch), and E5 showed the core then REWRITES model state per frame
 * (sw243/244/247, sw105..107, the sw215..223 lambda LUTs). That is an
 * in-silicon loop with an unpublished model, steered blind by an in-frame
 * target we would have to derive from a frame-level loop anyway. The
 * fixed-QP program is device-proven at every QP of the ladder for both
 * codecs, gives a deterministic size per (QP, content), and a KVM stream
 * needs the average right, not intra-frame bit spreading. v1 is therefore
 * software-only over ENC_RC_FIXQP -- the same from-scratch decision as #47.
 * Enabling the CTB cluster for in-frame distribution is a v2 option; the
 * seam (the register program) does not change.
 *
 * THE LOOP (all vendor facts from docs/reference/vcenc-open/, E4/E6/H8 and
 * the 2026-08-22 stage; the algorithm itself is ours):
 *
 *  1. Seed. The first IDR QP is a function of bits-per-pixel
 *     bpp = bitrate / (fps * W * H). Vendor evidence at 60 fps: QP 32 for
 *     bpp >= 1/16 (8 and 16 Mbps at 1080p), 34 at 0.048, 36 at 0.036 and
 *     36 +- 1 down to 0.0145 (2 Mbps at 1080p, 8 Mbps at 4K). Fit:
 *     seed = clamp(32 + 4.8 * log2(0.0625 / bpp), 32, 36). (The 36/32/26
 *     the 2026-08-22 stage recorded are the vendor's PPS pic_init_qp for
 *     2/8/16 Mbps -- a nominal value the slice_qp_delta then corrects; the
 *     IDR slice QP was 37/32/32. We write pic_init_qp = seed.)
 *
 *  2. Budget. bpf = bitrate / fps. Each GOP of N frames is planned with
 *     TM5-style remaining-bits allocation: budget G = N * bpf minus a share
 *     of the leaky-bucket debt, the I frame gets G * min(I_SHARE_MAX,
 *     r / (r + N - 1)) with r = C_I / C_P the measured I:P complexity ratio,
 *     every P frame gets (G - spent) / frames_left; the cap keeps a 10 %
 *     reserve for P frames on a static screen (the vendor's own GOP-8 I
 *     target is 90 % of the GOP, E4). The bucket is a 2 s CPB
 *     (the vendor's cpbSize = 2 x bitrate); debt is repaid over ~1 s,
 *     credit is capped at half a GOP so a static screen cannot bank a
 *     burst.
 *
 *  3. Model. bits(QP) = C * 2^-((QP - 32) / 6): the quantiser-step doubling
 *     law of both codecs. C_I and C_P are EMAs (alpha 1/2) of the measured
 *     bits normalised to QP 32, so the controller adapts to content in two
 *     or three frames. QP* = 32 + 6 * log2(C / target).
 *
 *  4. Steps. P frames move at most +2 / -1 per frame (vendor: +2 when
 *     starved, -1 when comfortable), the second P of the session may drop
 *     2 (the +3 seed below is deliberately conservative and the vendor
 *     corrects it by 2 exactly once). The first P after an IDR is
 *     IDR QP + 3 (E6/H8: 32->35, 30->33, 28->31, 37->40, 35->38 without
 *     exception).
 *
 *  5. Floor. P QP >= IDR QP - 11. Every comfortable GOP the vendor ran
 *     bottomed out at exactly IDR-11 (32->21, 30->19, 28->17, both codecs,
 *     both bitrates) instead of chasing an unfillable budget; it bounds
 *     the quality breathing between the keyframe and the P frames behind
 *     it. The outer loop moves the floor by moving the IDR QP.
 *
 *  6. I-frame rule. The IDR QP is its own slow state, not the running P
 *     QP: each IDR is chosen from C_I against its GOP share and clamped to
 *     the previous IDR +-2 (vendor: 32, 30, 28 at both 8 and 16 Mbps while
 *     the P QPs were 26/19 and 21/19). VBR never takes it below the seed.
 *
 *  7. Retarget. vcenc_rc_set_target() applies a new bitrate/fps at the next
 *     frame: the current GOP is re-planned at the new rate and the next
 *     decision (P or I) may jump straight to the model's QP, skipping the
 *     step clamp once. This is the dynamic-bitrate feature.
 *
 *  8. Clamps. qpMin/qpMax default to the QP-table range (16..51).
 *
 * VBR (cap-only, the vendor's VBR == AVBR, E1/H4) is the same loop with the
 * bitrate as a cap: no credit is banked and the IDR QP never goes below the
 * seed, so quality does not inflate to fill an idle pipe.
 *
 * VALIDATION: tests/vcenc_rc_test.c replays the vendor's CBR trajectories
 * (E6, H8 and any *_trajectory.csv dropped next to a vdrive .log) through
 * this controller and runs closed-loop simulations against size models
 * fitted from the E2/H3 ladders. `nix build .#checks.x86_64-linux.open-venc-rc`.
 */
#ifndef VCENC_RC_H
#define VCENC_RC_H

#include <stdint.h>
#include <string.h>
#include <math.h>
#include "vcenc_qp.h"

#define VCENC_RC_CBR        0u
#define VCENC_RC_VBR        1u

#define VCENC_RC_MODEL_QP   32.0    /* complexity is "bits at QP 32" */
#define VCENC_RC_QP_PER_OCT 6.0     /* bits halve every 6 QP */
#define VCENC_RC_CPB_SEC    2.0     /* leaky bucket = 2 s of target bits */
#define VCENC_RC_REPAY_SEC  1.0     /* debt repayment horizon */
#define VCENC_RC_CREDIT_GOP 0.5     /* credit cap, in GOP budgets */
#define VCENC_RC_I_SHARE_MAX 0.9    /* the IDR never plans > 90 % of the GOP */
#define VCENC_RC_P_FLOOR_DELTA 11u  /* P QP >= IDR QP - 11 */
#define VCENC_RC_FIRST_P_DELTA 3u   /* first P after an IDR = IDR QP + 3 */
#define VCENC_RC_I_STEP     2       /* IDR QP moves <= 2 per GOP */
#define VCENC_RC_P_STEP_UP  2
#define VCENC_RC_P_STEP_DN  1
#define VCENC_RC_ALPHA      0.5     /* complexity EMA weight of the new sample */
#define VCENC_RC_MIN_TARGET 0.05    /* per-frame target floor, in bpf */

struct vcenc_rc {
	/* configuration */
	uint32_t codec, w, h;
	uint32_t mode;             /* VCENC_RC_CBR | VCENC_RC_VBR */
	uint32_t fps;
	uint32_t gop;              /* IDR period; 0 = IDR only at start */
	uint32_t qp_min, qp_max;
	double   bitrate;          /* bits per second (target or cap) */
	double   bpf;              /* bits per frame */
	double   cpb;              /* bucket size, bits */
	/* leaky bucket: bits owed (> 0 = over budget) */
	double   buf;
	/* GOP plan */
	uint32_t plan_len;         /* frames in the current plan */
	uint32_t plan_pos;         /* frames coded so far in the plan */
	double   plan_budget;
	double   plan_spent;
	/* complexity model (bits at QP 32) */
	double   c_i, c_p;
	int      have_i, have_p;
	uint32_t p_count;          /* P frames coded in the session */
	/* QP state */
	uint32_t qp_seed;
	uint32_t qp_i;             /* current GOP's IDR QP */
	uint32_t qp_last;
	uint32_t since_idr;        /* frames since the last IDR (0 = IDR itself) */
	int      free_step;        /* skip the step clamp once (retarget) */
	int      pending_idr;      /* what vcenc_rc_pick_qp() decided */
	uint32_t pending_qp;
	/* statistics */
	uint32_t frames;
	double   total_bits;
};

/* First-IDR QP from bits per pixel (see item 1). */
static inline uint32_t vcenc_rc_seed_qp(double bpp)
{
	double q;
	if (bpp <= 0.0)
		return 36u;
	q = 32.0 + 4.8 * log2(0.0625 / bpp);
	if (q < 32.0)
		q = 32.0;
	if (q > 36.0)
		q = 36.0;
	return (uint32_t)lrint(q);
}

static inline uint32_t vcenc_rc_clampu(double v, uint32_t lo, uint32_t hi)
{
	long q = lrint(v);
	if (q < (long)lo)
		q = (long)lo;
	if (q > (long)hi)
		q = (long)hi;
	return (uint32_t)q;
}

/* Bits the model expects at `qp` for complexity c. */
static inline double vcenc_rc_model_bits(double c, uint32_t qp)
{
	return c * exp2(-((double)qp - VCENC_RC_MODEL_QP) / VCENC_RC_QP_PER_OCT);
}

/* QP the model wants for `target` bits at complexity c (unrounded). */
static inline double vcenc_rc_model_qp(double c, double target)
{
	if (target < 1.0)
		target = 1.0;
	if (c < 1.0)
		c = 1.0;
	return VCENC_RC_MODEL_QP + VCENC_RC_QP_PER_OCT * log2(c / target);
}

/* Planning horizon: the GOP, or 2 s for an IDR-once stream. */
static inline uint32_t vcenc_rc_plan_len(const struct vcenc_rc *rc)
{
	uint32_t n = rc->gop ? rc->gop : 2u * rc->fps;
	return n ? n : 1u;
}

static inline void vcenc_rc_retarget(struct vcenc_rc *rc, double bitrate,
				     uint32_t fps)
{
	rc->bitrate = bitrate;
	rc->fps = fps ? fps : 1u;
	rc->bpf = rc->bitrate / (double)rc->fps;
	rc->cpb = rc->bitrate * VCENC_RC_CPB_SEC;
}

/* Start a plan window (at an IDR, or when an IDR-once stream rolls over). */
static inline void vcenc_rc_start_plan(struct vcenc_rc *rc)
{
	uint32_t n = vcenc_rc_plan_len(rc);
	double repay = rc->buf;
	double frac = (double)n / ((double)rc->fps * VCENC_RC_REPAY_SEC);
	if (frac < 1.0)
		repay *= frac;                     /* spread debt over ~1 s */
	rc->plan_len = n;
	rc->plan_pos = 0;
	rc->plan_spent = 0.0;
	rc->plan_budget = (double)n * rc->bpf - repay;
	if (rc->plan_budget < 0.25 * (double)n * rc->bpf)
		rc->plan_budget = 0.25 * (double)n * rc->bpf;
}

/*
 * Initialise a session.
 *   codec   ENC_CODEC_H264 / ENC_CODEC_HEVC (informational; same loop)
 *   fps     source frame rate (>= 1)
 *   bitrate target (CBR) or cap (VBR), bits per second
 *   gop     IDR period in frames; 0 = IDR only at the first frame
 *   mode    VCENC_RC_CBR | VCENC_RC_VBR
 */
static inline void vcenc_rc_init(struct vcenc_rc *rc, uint32_t codec,
				 uint32_t w, uint32_t h, uint32_t fps,
				 double bitrate, uint32_t gop, uint32_t mode)
{
	memset(rc, 0, sizeof *rc);
	rc->codec = codec;
	rc->w = w;
	rc->h = h;
	rc->mode = mode;
	rc->gop = gop;
	rc->qp_min = VCENC_QP_MIN;
	rc->qp_max = VCENC_QP_MAX;
	vcenc_rc_retarget(rc, bitrate, fps);
	rc->qp_seed = vcenc_rc_seed_qp(rc->bitrate /
				       ((double)rc->fps * (double)w * (double)h));
	rc->qp_i = rc->qp_last = rc->qp_seed;
}

/* Apply a new bitrate and/or fps from the next frame on (item 7). */
static inline void vcenc_rc_set_target(struct vcenc_rc *rc, double bitrate,
				       uint32_t fps)
{
	uint32_t left;
	if (bitrate == rc->bitrate && fps == rc->fps)
		return;
	vcenc_rc_retarget(rc, bitrate, fps);
	/* re-plan the rest of the current window at the new rate */
	left = rc->plan_len > rc->plan_pos ? rc->plan_len - rc->plan_pos : 0;
	rc->plan_budget = rc->plan_spent + (double)left * rc->bpf;
	if (rc->buf > rc->cpb)
		rc->buf = rc->cpb;
	rc->free_step = 1;
}

/* New IDR period; takes effect at the next IDR. */
static inline void vcenc_rc_set_gop(struct vcenc_rc *rc, uint32_t gop)
{
	rc->gop = gop;
}

/*
 * Decide the QP of the frame about to be encoded. Call vcenc_rc_update()
 * with the result once the frame's size is known.
 */
static inline uint32_t vcenc_rc_pick_qp(struct vcenc_rc *rc, int is_idr)
{
	uint32_t qp;

	if (is_idr) {
		uint32_t n;
		vcenc_rc_start_plan(rc);
		n = rc->plan_len;
		if (!rc->have_i) {
			qp = rc->qp_seed;
		} else {
			double share = VCENC_RC_I_SHARE_MAX, target, q;
			uint32_t lo = rc->qp_min, hi = rc->qp_max;
			if (n == 1) {
				share = 1.0;
			} else if (rc->have_p && rc->c_p > 0.0) {
				double r = rc->c_i / rc->c_p;
				double s = r / (r + (double)(n - 1));
				if (s < share)
					share = s;
			}
			target = rc->plan_budget * share;
			q = vcenc_rc_model_qp(rc->c_i, target);
			if (!rc->free_step) {
				lo = rc->qp_i > (uint32_t)VCENC_RC_I_STEP + lo
				   ? rc->qp_i - VCENC_RC_I_STEP : lo;
				if (rc->qp_i + VCENC_RC_I_STEP < hi)
					hi = rc->qp_i + VCENC_RC_I_STEP;
			}
			if (rc->mode == VCENC_RC_VBR && lo < rc->qp_seed)
				lo = rc->qp_seed;
			if (lo > hi)
				lo = hi;
			qp = vcenc_rc_clampu(q, lo, hi);
		}
		rc->qp_i = qp;
		rc->since_idr = 0;
		rc->free_step = 0;
	} else {
		uint32_t floor = rc->qp_min, lo, hi;
		double target, q;
		if (rc->qp_i > VCENC_RC_P_FLOOR_DELTA + rc->qp_min)
			floor = rc->qp_i - VCENC_RC_P_FLOOR_DELTA;
		if (rc->plan_pos >= rc->plan_len)      /* IDR-once rollover */
			vcenc_rc_start_plan(rc);
		rc->since_idr++;

		if (rc->since_idr == 1 && !rc->free_step) {
			qp = rc->qp_i + VCENC_RC_FIRST_P_DELTA;
		} else {
			uint32_t left = rc->plan_len - rc->plan_pos;
			target = (rc->plan_budget - rc->plan_spent) / (double)left;
			if (target < VCENC_RC_MIN_TARGET * rc->bpf)
				target = VCENC_RC_MIN_TARGET * rc->bpf;
			q = rc->have_p ? vcenc_rc_model_qp(rc->c_p, target)
				       : (double)rc->qp_last;
			lo = rc->qp_min;
			hi = rc->qp_max;
			if (!rc->free_step) {
				uint32_t dn = rc->p_count == 1 ? 2u
					    : (uint32_t)VCENC_RC_P_STEP_DN;
				lo = rc->qp_last > dn + lo ? rc->qp_last - dn : lo;
				if (rc->qp_last + VCENC_RC_P_STEP_UP < hi)
					hi = rc->qp_last + VCENC_RC_P_STEP_UP;
			}
			qp = vcenc_rc_clampu(q, lo, hi);
		}
		if (qp < floor)
			qp = floor;
		rc->free_step = 0;
	}
	if (qp < rc->qp_min)
		qp = rc->qp_min;
	if (qp > rc->qp_max)
		qp = rc->qp_max;
	rc->pending_idr = is_idr;
	rc->pending_qp = qp;
	return qp;
}

/*
 * Feed back the coded size of the frame vcenc_rc_pick_qp() decided.
 *   bits    coded size including parameter sets (what goes on the wire)
 *   qp      the QP the frame was really coded at (normally the picked one;
 *           a replay harness passes the recorded QP so the model learns
 *           from the true (QP, size) pair)
 */
static inline void vcenc_rc_update(struct vcenc_rc *rc, double bits,
				   uint32_t qp)
{
	double c = bits * exp2(((double)qp - VCENC_RC_MODEL_QP) /
			       VCENC_RC_QP_PER_OCT);
	if (rc->pending_idr) {
		rc->c_i = rc->have_i ? (1.0 - VCENC_RC_ALPHA) * rc->c_i
				       + VCENC_RC_ALPHA * c : c;
		rc->have_i = 1;
	} else {
		rc->c_p = rc->have_p ? (1.0 - VCENC_RC_ALPHA) * rc->c_p
				       + VCENC_RC_ALPHA * c : c;
		rc->have_p = 1;
		rc->p_count++;
	}
	rc->qp_last = qp;
	rc->plan_spent += bits;
	rc->plan_pos++;
	rc->buf += bits - rc->bpf;
	if (rc->buf > rc->cpb)
		rc->buf = rc->cpb;
	{
		double credit = rc->mode == VCENC_RC_VBR ? 0.0
			      : VCENC_RC_CREDIT_GOP * (double)vcenc_rc_plan_len(rc) * rc->bpf;
		if (rc->buf < -credit)
			rc->buf = -credit;
	}
	rc->frames++;
	rc->total_bits += bits;
}

#endif /* VCENC_RC_H */
