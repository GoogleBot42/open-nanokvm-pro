// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * vcenc_rc.h -- from-scratch frame-level rate controller for the open
 * VC8000E encoder (#46): CBR and capped VBR, H.264 and HEVC.
 *
 * WHERE IT SITS. The controller is pure software above the per-frame
 * builder: it turns (target bitrate, fps, GOP, measured frame sizes) into
 * one frame QP, which vcenc_encode.h programs through the vendor's true
 * fixed-QP register set (ENC_RC_FIXQP -- rate control OFF in the hardware,
 * QP block from the per-frame-type tables). Codec-agnostic: the RC register
 * set is identical for H.264 and HEVC (vendor-diff-hevc-20260905 H4) and so
 * is the vendor's frame-level law on real content (vendor-diff-rc-20260905
 * §9); only the seed differs by codec.
 *
 * WHY NOT THE HARDWARE RC-ENABLE CLUSTER. E1 identified the nine registers
 * that switch the core's own CTB-level rate control on (sw6[0], sw22[3:2],
 * the sw105..107 picture targets, sw172/173, sw245/246, the sw239/241
 * scratch), and E5 showed the core then REWRITES model state per frame
 * (sw243/244/247, sw105..107, the sw215..223 lambda LUTs). That is an
 * in-silicon loop with an unpublished model, steered by a per-frame target
 * a frame-level loop has to produce anyway. The fixed-QP program is
 * device-proven at every QP of the ladder for both codecs, gives a
 * deterministic size per (QP, content), and a KVM stream needs the average
 * right, not intra-frame bit spreading. v1 is therefore software-only over
 * ENC_RC_FIXQP -- the same from-scratch decision as #47. Enabling the CTB
 * cluster for in-frame distribution is a v2 option; the seam (the register
 * program) does not change.
 *
 * THE LAWS. Every rule below is a measurement of the vendor controller on
 * the real 1080p60 KVM desktop (docs/reference/vcenc-open/
 * vendor-diff-rc-20260905/REPORT.md, 51 runs, 11 400 frames: static,
 * 4 px scroll, half-screen jumps, CBR and VBR, mid-stream target changes),
 * cross-checked against the synthetic-card runs (E4/E6/H8). Section
 * numbers refer to that REPORT.
 *
 *  1. Seed (§2). First IDR QP from bits-per-pixel bpp = bitrate/(fps*W*H).
 *     CBR: 32 for bpp >= 1/16 (8 and 16 Mbps at 1080p), rising 4.8 QP per
 *     octave below (34 at 0.048, 36 at 0.036 -- the E3 geometry series),
 *     clamped at 37 for H.264 and 35 for HEVC (1000..3000 kbps at 1080p
 *     seed 37 / 35 on every run). VBR seeds the nominal curve 36 / 32 / 26
 *     at 2 / 8 / 16 Mbps (= the vendor's PPS pic_init_qp law, 2026-08-22).
 *
 *  2. First P (§2). CBR: IDR QP + 3 on every GOP of every run, both codecs,
 *     in band, under and over target. VBR: first P = IDR QP.
 *
 *  3. P-step law (§3). With r = bits(previous frame) / target(previous
 *     frame):
 *          r in [0.95, 1.05)   0          dead band
 *          r in [1.05, 1.25)   +1
 *          r >= 1.25           +2
 *          r in [0.85, 0.95)   -1
 *          r in [0.70, 0.85)   -2
 *          r <  0.70           -1         throttled descent in deep undershoot
 *     |dQP| <= 2 always. The second P of a session may take -2 below 0.85
 *     (the +3 seed is conservative; the vendor corrects it by 2 exactly
 *     once, E6/H8/R1). The +-1 vs +-2 choice inside the 5..30 % bands is
 *     not a function of r alone in the vendor (REPORT §3); the bands above
 *     take the majority outcome of every bin. One addition of ours: a frame
 *     that follows our own QP decrease and costs >= 2.5x its predecessor is
 *     a static picture's one-time refinement toward the new QP, and does
 *     not trigger an up-step (the vendor never sees such a frame -- its
 *     in-frame CTB rate control shapes P frames to sw105 within the
 *     sw106/107 bounds, which is why its 2 Mbps desktop frames are all
 *     ~3.3 KB; v1 runs the core with RC off and its frames run free).
 *
 *  4. Bounds (§3). P QP >= IDR QP - 11 (hit and held in every
 *     content-limited GOP, both codecs) down to qpMin. P QP <= 51 in the
 *     first GOP of a session, 46 from the second GOP on (every over-target
 *     run, synthetic and real). qpMin here is 16, the QP-table range, where
 *     the vendor goes to 10.
 *
 *  5. IDR rule (§4). The IDR QP is its own slow state, not the running P QP:
 *          IDR(k+1) = clamp(round(meanP of GOP k) - 4,
 *                           IDR(k) - 2, min(IDR(k) + 2, IDR(initial)))
 *     which yields the three observed regimes: -2 per GOP exactly while the
 *     content is under target (P frames sit at IDR-11, so meanP-4 is far
 *     below), meanP-4 in band (jump runs: 36.0 -> 32, 34.8 -> 31 ...), and
 *     never above the initial QP over target (37 x 8 GOPs at 1.3x). One
 *     guard the vendor lacks: an IDR that took more than half the GOP
 *     budget may push the IDR QP above its initial value (+2 per GOP), so
 *     rich content at a low rate does not run at 1.4x target forever.
 *
 *  6. Targets (§5). The budget window is StatTime = 1 s, rounded to whole
 *     GOPs (two GOPs at gop 30 / 60 fps). Inside the window every P frame
 *     is planned TM5-style: target = (window budget - spent - IDRs still
 *     due, reserved at the last IDR's size) / P frames left, bounded to
 *     [0.05, 4] x bits/frame; the IDR takes what its QP costs. The
 *     vendor's first-P targets (127 433 @8000, 267 715 @16000 bits) fall
 *     out of this to within 1 %. Unspent bits are dropped at the window end
 *     (the vendor's last-frame target balloons and cannot be spent; no
 *     credit is banked, so a static screen never stores a burst); overspend
 *     is carried as debt and repaid within the next window (which may be
 *     fully mortgaged), bounded by a 2 s CPB (the vendor's cpbSize).
 *
 *  7. Retarget (§7). vcenc_rc_set_target() re-plans the rest of the window
 *     at the new rate from the very next frame. The P QP does NOT jump: it
 *     moves through the step law (downward -1/frame while the content is
 *     under the new target, upward +1/+2 only as bits exceed it). The first
 *     IDR after a change restarts at the new bitrate's seed (CBR) or at 32
 *     (VBR).
 *
 *  8. VBR (§8). The cap is the only target: per-frame target 0.8 x bits/
 *     frame (the vendor lands at 0.90 x cap over the stream), steps +2 above
 *     1.05 x, -1 below 0.95 x, 0 between, no IDR-11 floor (QP descends to
 *     qpMin under the cap), the IDR QP follows the last P QP (+1).
 *
 * NOT COPIED: HEVC CBR at <= 7000 kbps / 1080p60 (<= ~0.058 bpp) in the
 * vendor programs no target at all and ramps QP open-loop to 46 (REPORT
 * §6, the H8 "undershoot"). HEVC gets the H.264 law here.
 *
 * VALIDATION: tests/vcenc_rc_test.c replays every vendor trajectory
 * (vendor-diff-rc-20260905 R1..R7, E6, H8, and any *_trajectory.csv dropped
 * next to a vdrive .log) one step ahead through this controller, and runs
 * closed-loop simulations against size models measured on the real desktop.
 * `nix build .#checks.x86_64-linux.open-venc-rc`.
 */
#ifndef VCENC_RC_H
#define VCENC_RC_H

#include <stdint.h>
#include <string.h>
#include <math.h>
#include "vcenc_qp.h"

#define VCENC_RC_CBR        0u
#define VCENC_RC_VBR        1u

#define VCENC_RC_CPB_SEC    2.0     /* leaky bucket = 2 s of target bits */
#define VCENC_RC_STAT_SEC   1.0     /* budget window (vendor StatTime) */
#define VCENC_RC_P_FLOOR_DELTA 11u  /* CBR: P QP >= IDR QP - 11 */
#define VCENC_RC_FIRST_P_DELTA 3u   /* CBR: first P after an IDR = IDR + 3 */
#define VCENC_RC_P_CEIL_LATER 46u   /* CBR ceiling from the second GOP on */
#define VCENC_RC_I_STEP     2       /* IDR QP moves <= 2 per GOP */
#define VCENC_RC_I_MEANP_DELTA 4    /* in band: IDR = meanP(prev GOP) - 4 */
#define VCENC_RC_I_GUARD_SHARE 0.5  /* IDR > half the GOP budget: may rise above the seed */
#define VCENC_RC_MIN_TARGET 0.05    /* per-frame target floor, in bpf */
#define VCENC_RC_MAX_TARGET 4.0     /* per-frame target cap, in bpf */
#define VCENC_RC_VBR_TARGET 0.8     /* VBR per-frame target, in bpf of the cap */
#define VCENC_RC_VBR_RESTART_QP 32u /* VBR first IDR after a retarget */
#define VCENC_RC_BURST_RATIO 2.5    /* refinement burst after a QP drop: bits >= 2.5x predecessor */

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
	/* leaky bucket: bits owed (>= 0, no credit) */
	double   buf;
	/* budget window */
	uint32_t win_len;          /* frames in the current window */
	uint32_t win_pos;          /* frames coded so far in the window */
	double   win_budget;
	double   win_spent;
	/* GOP bookkeeping for the IDR rule */
	double   gop_p_qp_sum;
	uint32_t gop_p_n;
	uint32_t gop_index;        /* 0 = first GOP of the session */
	double   last_idr_bits;
	/* QP state */
	uint32_t qp_seed;          /* IDR(initial) for the current bitrate */
	uint32_t qp_i;             /* current GOP's IDR QP */
	uint32_t qp_last;          /* QP of the last coded frame */
	double   last_bits, last_target;   /* for r */
	double   prev_bits;        /* the frame before last (burst detection) */
	int      last_dropped;     /* last P was coded at a lower QP than its predecessor */
	uint32_t since_idr;        /* frames since the last IDR (0 = IDR itself) */
	uint32_t p_count;          /* P frames coded in the session */
	int      retargeted;       /* an IDR must restart at the new seed */
	int      pending_idr;      /* what vcenc_rc_pick_qp() decided */
	uint32_t pending_qp;
	double   pending_target;
	/* statistics */
	uint32_t frames;
	double   total_bits;
};

/* CBR first-IDR QP from bits per pixel (law 1). */
static inline uint32_t vcenc_rc_seed_qp(uint32_t codec, double bpp)
{
	double q, cap = codec ? 35.0 : 37.0;   /* ENC_CODEC_HEVC == 1 */
	if (bpp <= 0.0)
		return (uint32_t)cap;
	q = 32.0 + 4.8 * log2(0.0625 / bpp);
	if (q < 32.0)
		q = 32.0;
	if (q > cap)
		q = cap;
	return (uint32_t)lrint(q);
}

/* VBR first-IDR QP: the nominal pic_init_qp curve, 36 / 32 / 26 at
 * 2 / 8 / 16 Mbps 1080p60 (2 QP per octave below 0.0643 bpp, 6 above). */
static inline uint32_t vcenc_rc_nominal_qp(double bpp)
{
	double q;
	if (bpp <= 0.0)
		return 36u;
	q = bpp < 0.0643 ? 32.0 + 2.0 * log2(0.0643 / bpp)
			 : 32.0 - 6.0 * log2(bpp / 0.0643);
	if (q < 16.0)
		q = 16.0;
	if (q > 51.0)
		q = 51.0;
	return (uint32_t)lrint(q);
}

static inline uint32_t vcenc_rc_clampu(long q, uint32_t lo, uint32_t hi)
{
	if (q < (long)lo)
		q = (long)lo;
	if (q > (long)hi)
		q = (long)hi;
	return (uint32_t)q;
}

static inline double vcenc_rc_bpp(const struct vcenc_rc *rc)
{
	return rc->bitrate / ((double)rc->fps * (double)rc->w * (double)rc->h);
}

/* Budget window: StatTime rounded to whole GOPs (law 6). */
static inline uint32_t vcenc_rc_win_len(const struct vcenc_rc *rc)
{
	uint32_t stat = (uint32_t)lrint(VCENC_RC_STAT_SEC * rc->fps), n;
	if (!rc->gop)
		return stat ? stat : 1u;
	n = (stat + rc->gop / 2) / rc->gop;
	if (n < 1)
		n = 1;
	return n * rc->gop;
}

static inline void vcenc_rc_retarget(struct vcenc_rc *rc, double bitrate,
				     uint32_t fps)
{
	rc->bitrate = bitrate;
	rc->fps = fps ? fps : 1u;
	rc->bpf = rc->bitrate / (double)rc->fps;
	rc->cpb = rc->bitrate * VCENC_RC_CPB_SEC;
}

/* Open a budget window: 1 s of bits minus the debt carried in. */
static inline void vcenc_rc_start_window(struct vcenc_rc *rc)
{
	uint32_t n = vcenc_rc_win_len(rc);
	rc->win_len = n;
	rc->win_pos = 0;
	rc->win_spent = 0.0;
	/* debt carried in is repaid within this window; a window can be fully
	 * mortgaged (the vendor's targets go to ~0 bits while over target) */
	rc->win_budget = (double)n * rc->bpf - rc->buf;
	if (rc->win_budget < 0.0)
		rc->win_budget = 0.0;
}

/* IDRs still due in the window after the current frame position. */
static inline uint32_t vcenc_rc_idrs_left(const struct vcenc_rc *rc)
{
	if (!rc->gop || rc->win_pos == 0 || rc->win_pos >= rc->win_len)
		return 0;
	return (rc->win_len - 1) / rc->gop - (rc->win_pos - 1) / rc->gop;
}

/*
 * Initialise a session.
 *   codec   ENC_CODEC_H264 / ENC_CODEC_HEVC (seed clamp only)
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
	rc->qp_seed = mode == VCENC_RC_VBR
		    ? vcenc_rc_nominal_qp(vcenc_rc_bpp(rc))
		    : vcenc_rc_seed_qp(codec, vcenc_rc_bpp(rc));
	rc->qp_seed = vcenc_rc_clampu((long)rc->qp_seed, rc->qp_min, rc->qp_max);
	rc->qp_i = rc->qp_last = rc->qp_seed;
}

/* Apply a new bitrate and/or fps from the next frame on (law 7). */
static inline void vcenc_rc_set_target(struct vcenc_rc *rc, double bitrate,
				       uint32_t fps)
{
	uint32_t left;
	if (bitrate == rc->bitrate && fps == rc->fps)
		return;
	vcenc_rc_retarget(rc, bitrate, fps);
	left = rc->win_len > rc->win_pos ? rc->win_len - rc->win_pos : 0;
	rc->win_budget = rc->win_spent + (double)left * rc->bpf;
	if (rc->buf > rc->cpb)
		rc->buf = rc->cpb;
	rc->qp_seed = rc->mode == VCENC_RC_VBR
		    ? VCENC_RC_VBR_RESTART_QP
		    : vcenc_rc_seed_qp(rc->codec, vcenc_rc_bpp(rc));
	rc->qp_seed = vcenc_rc_clampu((long)rc->qp_seed, rc->qp_min, rc->qp_max);
	rc->retargeted = 1;
}

/* New IDR period; takes effect at the next window. */
static inline void vcenc_rc_set_gop(struct vcenc_rc *rc, uint32_t gop)
{
	rc->gop = gop;
}

/* The step law (law 3 / law 8) on r = bits / target of the previous frame. */
static inline int vcenc_rc_step(const struct vcenc_rc *rc, double r)
{
	if (rc->mode == VCENC_RC_VBR)
		return r >= 1.05 ? 2 : r < 0.95 ? -1 : 0;
	if (r >= 1.25)
		return 2;
	if (r >= 1.05)
		return 1;
	if (r >= 0.95)
		return 0;
	if (r >= 0.85)
		return -1;
	if (r >= 0.70 || rc->p_count == 1)
		return -2;
	return -1;
}

/*
 * Decide the QP of the frame about to be encoded. Call vcenc_rc_update()
 * with the result once the frame's size is known.
 */
static inline uint32_t vcenc_rc_pick_qp(struct vcenc_rc *rc, int is_idr)
{
	uint32_t qp;

	if (is_idr) {
		if (rc->frames == 0 || rc->win_pos >= rc->win_len ||
		    (rc->gop && rc->win_pos % rc->gop == 0 && rc->win_pos == 0))
			vcenc_rc_start_window(rc);
		if (rc->frames == 0 || rc->retargeted) {
			qp = rc->qp_seed;
			rc->retargeted = 0;
		} else if (rc->mode == VCENC_RC_VBR) {
			qp = vcenc_rc_clampu((long)rc->qp_last + 1, rc->qp_min, rc->qp_max);
		} else {
			long want, lo, hi;
			double meanp = rc->gop_p_n
				     ? rc->gop_p_qp_sum / rc->gop_p_n : rc->qp_i;
			want = lrint(meanp) - VCENC_RC_I_MEANP_DELTA;
			lo = (long)rc->qp_i - VCENC_RC_I_STEP;
			hi = (long)rc->qp_i + VCENC_RC_I_STEP;
			if (hi > (long)rc->qp_seed)
				hi = (long)rc->qp_seed;
			/* guard: an IDR that took more than half the GOP budget
			 * may climb past the initial QP */
			if (rc->last_idr_bits > VCENC_RC_I_GUARD_SHARE *
			    (double)(rc->gop ? rc->gop : rc->fps) * rc->bpf)
				hi = (long)rc->qp_i + VCENC_RC_I_STEP;
			if (hi < lo)
				hi = lo;
			if (want < lo)
				want = lo;
			if (want > hi)
				want = hi;
			qp = vcenc_rc_clampu(want, rc->qp_min, rc->qp_max);
		}
		if (rc->frames)
			rc->gop_index++;
		rc->qp_i = qp;
		rc->since_idr = 0;
		rc->gop_p_qp_sum = 0.0;
		rc->gop_p_n = 0;
		rc->pending_target = 0.0;
	} else {
		uint32_t floor = rc->qp_min, ceil = rc->qp_max, left;
		double target;
		if (rc->win_pos >= rc->win_len)      /* IDR-once rollover */
			vcenc_rc_start_window(rc);
		/* TM5 over the P frames left in the window, with the IDRs still
		 * due reserved at the last IDR's size (the vendor's first-P
		 * targets at 8/16 Mbps fall out of this to within 1 %) */
		{
			uint32_t idrs = vcenc_rc_idrs_left(rc);
			left = rc->win_len - rc->win_pos - idrs;
			if (left < 1)
				left = 1;
			target = (rc->win_budget - rc->win_spent
				  - (double)idrs * rc->last_idr_bits) / (double)left;
		}
		if (rc->mode == VCENC_RC_VBR)
			target = VCENC_RC_VBR_TARGET * rc->bpf;
		if (target < VCENC_RC_MIN_TARGET * rc->bpf)
			target = VCENC_RC_MIN_TARGET * rc->bpf;
		if (target > VCENC_RC_MAX_TARGET * rc->bpf)
			target = VCENC_RC_MAX_TARGET * rc->bpf;
		rc->since_idr++;

		if (rc->mode == VCENC_RC_CBR) {
			if (rc->qp_i > VCENC_RC_P_FLOOR_DELTA + rc->qp_min)
				floor = rc->qp_i - VCENC_RC_P_FLOOR_DELTA;
			if (rc->gop_index > 0 && ceil > VCENC_RC_P_CEIL_LATER)
				ceil = VCENC_RC_P_CEIL_LATER;
		}
		if (rc->since_idr == 1) {
			qp = rc->qp_i + (rc->mode == VCENC_RC_CBR
					 ? VCENC_RC_FIRST_P_DELTA : 0u);
		} else {
			double r = rc->last_target > 0.0
				 ? rc->last_bits / rc->last_target : 1.0;
			int step = vcenc_rc_step(rc, r);
			/* A frame that follows OUR OWN QP decrease and costs several
			 * times its predecessor is the one-time refinement of a
			 * static picture toward the new QP, not a rate signal: hold
			 * once and read the next frame (the window accounting still
			 * carries its bits). Without in-frame CTB rate control (the
			 * vendor shapes such frames to sw105 within sw106/107) the
			 * -1/+2 law would otherwise ratchet a static screen up to the
			 * ceiling. Alternating content (jump runs, 1.5x) is untouched. */
			if (step > 0 && rc->last_dropped && rc->prev_bits > 0.0 &&
			    rc->last_bits >= VCENC_RC_BURST_RATIO * rc->prev_bits)
				step = 0;
			qp = vcenc_rc_clampu((long)rc->qp_last + step,
					     rc->qp_min, rc->qp_max);
		}
		if (qp < floor)
			qp = floor;
		if (qp > ceil)
			qp = ceil;
		rc->pending_target = target;
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
 *           a replay harness passes the recorded QP so the state follows
 *           the true trajectory)
 */
static inline void vcenc_rc_update(struct vcenc_rc *rc, double bits,
				   uint32_t qp)
{
	if (rc->pending_idr) {
		rc->last_idr_bits = bits;
		rc->qp_i = qp;
		rc->last_dropped = 0;
		rc->prev_bits = 0.0;
	} else {
		rc->gop_p_qp_sum += qp;
		rc->gop_p_n++;
		rc->p_count++;
		rc->last_dropped = (rc->since_idr > 1 && qp < rc->qp_last);
		rc->prev_bits = rc->since_idr > 1 ? rc->last_bits : 0.0;
		rc->last_bits = bits;
		rc->last_target = rc->pending_target;
	}
	rc->qp_last = qp;
	rc->win_spent += bits;
	rc->win_pos++;
	rc->buf += bits - rc->bpf;
	if (rc->buf > rc->cpb)
		rc->buf = rc->cpb;
	if (rc->buf < 0.0)
		rc->buf = 0.0;                     /* no credit (law 6) */
	rc->frames++;
	rc->total_bits += bits;
}

#endif /* VCENC_RC_H */
