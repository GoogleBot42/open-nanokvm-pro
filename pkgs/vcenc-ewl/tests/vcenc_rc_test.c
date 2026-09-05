// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * vcenc_rc_test -- host validation of the from-scratch rate controller (#46).
 *
 * Two families of evidence, both hardware-free:
 *
 * A. VENDOR TRAJECTORY REPLAY. Every `*_trajectory.csv` under the directory
 *    given as argv[1] (frame,type,bytes,slice_qp[,target_kbps]) is replayed
 *    through vcenc_rc.h: the controller sees the vendor's real per-frame
 *    sizes (fed back with the vendor's QP, so the model learns the true
 *    (QP, size) pairs) and its own QP decision for each frame is compared to
 *    the vendor's. Session parameters come from the sibling vdrive log
 *    (`<tag>.log`, first line `# vdrive tag=.. [codec=h265] WxH rc=cbr
 *    br=8000 fps=60/60 gop=30 ..`), so new captures -- the real-HDMI CBR/VBR
 *    runs under vendor-diff-rc-20260905/ -- are picked up by dropping the
 *    files in. An optional `target_kbps` column drives vcenc_rc_set_target()
 *    mid-stream.
 *
 *    This is a ONE-STEP-AHEAD comparison: after each frame the controller's
 *    state (model, buffer, last QP) is advanced with the vendor's real QP
 *    and size, so every decision is "from the vendor's state, what would we
 *    pick next". A free-running comparison needs the encoder (sizes depend
 *    on our QP) -- that is the closed-loop family below and the device run.
 *
 *    Tolerance (mean |dQP| over the run) by (codec, kbps):
 *      8000 / 16000 kbps  <= 2.5   the vendor tracked its target or its own
 *                                  IDR-11 floor; we must land on the same QPs
 *      2000 kbps          <= 20    the vendor is OFF target on the moving card
 *                                  (H.264: holds P at IDR+9 while 60 % over;
 *                                  HEVC: pins QP 51 while 45 % under). Our
 *                                  controller honours the target instead, so
 *                                  these runs are reported, not matched.
 *      anything else      <= 6.0   default for dropped-in captures
 *    plus, for every run, the first-IDR QP within +-1 of the vendor's seed.
 *
 * B. CLOSED-LOOP SIMULATION against size models
 *      bytes(type, QP, n) = C_type * 2^-((QP - 32) / s_type) * alt(n)
 *    with (C, s) fitted from the committed vendor data (log-linear
 *    regression of log2(bytes) on QP): E2/H3 static-card I ladders give
 *    s_I = 18.3 for both codecs; the E6/H8 moving-card runs give
 *    s_P = 16.6 (H.264) / 10.8 (HEVC) and alt() = the card's 1.68:1
 *    even/odd frame-size alternation. A textbook plant (s = 6, the
 *    quantiser-step law) and a static-desktop plant complete the set.
 *    Each plant runs 2/8/16 Mbps at 1080p60, GOP 30, 10 s; the steady-state
 *    bitrate over the last 5 s must land within +-10 % of the target when
 *    the plant can reach it inside [qpMin+2, qpMax-2], or sit at the right
 *    QP bound otherwise. Extra scenarios: a mid-stream retarget (8 -> 2 ->
 *    16 Mbps), a 2 s complexity burst against the 2 s CPB, and VBR.
 */
#define _XOPEN_SOURCE 700
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ftw.h>
#include <math.h>
#include "../vcenc_encode.h"
#include "../vcenc_rc.h"

static int fails;
static int csv_seen;

/* ------------------------------------------------------------------ */
/* A. vendor trajectory replay                                         */

struct traj {
	char tag[64];
	uint32_t codec, w, h, fps, gop, mode;
	double kbps;
	int n;
	int is_i[4096];
	uint32_t bytes[4096], qp[4096];
	double target_kbps[4096];   /* 0 = unchanged */
	int has_target;
};

static void parse_sidecar(const char *csv, struct traj *t)
{
	char path[1024], line[1024], *p;
	size_t n = strlen(csv);
	FILE *f;
	/* defaults: the E6/H8 setup */
	t->codec = ENC_CODEC_H264; t->w = 1920; t->h = 1080; t->fps = 60;
	t->gop = 30; t->mode = VCENC_RC_CBR; t->kbps = 0;
	if (n < 16 || strcmp(csv + n - 15, "_trajectory.csv"))
		return;
	snprintf(path, sizeof path, "%.*s.log", (int)(n - 15), csv);
	if (sscanf(strrchr(csv, '/') ? strrchr(csv, '/') + 1 : csv,
		   "traj%lf_", &t->kbps) != 1)
		t->kbps = 0;
	f = fopen(path, "r");
	if (!f)
		return;
	if (fgets(line, sizeof line, f)) {
		unsigned a, b;
		double v;
		if (strstr(line, "codec=h265"))
			t->codec = ENC_CODEC_HEVC;
		if (strstr(line, "rc=vbr") || strstr(line, "rc=avbr"))
			t->mode = VCENC_RC_VBR;
		if ((p = strstr(line, " br=")) && sscanf(p, " br=%lf", &v) == 1)
			t->kbps = v;
		if ((p = strstr(line, " fps=")) && sscanf(p, " fps=%u/%u", &a, &b) == 2)
			t->fps = b ? b : a;
		if ((p = strstr(line, " gop=")) && sscanf(p, " gop=%u", &a) == 1)
			t->gop = a;
		for (p = line; (p = strchr(p, 'x')); p++) {
			if (p > line && p[-1] >= '0' && p[-1] <= '9' &&
			    sscanf(p + 1, "%u", &b) == 1) {
				const char *q = p - 1;
				while (q > line && q[-1] >= '0' && q[-1] <= '9')
					q--;
				if (sscanf(q, "%u", &a) == 1 && a >= 64 && b >= 64) {
					t->w = a; t->h = b; break;
				}
			}
		}
	}
	fclose(f);
}

static int load_csv(const char *path, struct traj *t)
{
	FILE *f = fopen(path, "r");
	char line[512];
	int col_frame = -1, col_type = -1, col_bytes = -1, col_qp = -1, col_tgt = -1;
	if (!f)
		return -1;
	memset(t, 0, sizeof *t);
	{
		const char *s = strrchr(path, '/');
		snprintf(t->tag, sizeof t->tag, "%s", s ? s + 1 : path);
		if (strlen(t->tag) > 15)
			t->tag[strlen(t->tag) - 15] = 0;
	}
	parse_sidecar(path, t);
	if (!fgets(line, sizeof line, f)) { fclose(f); return -1; }
	{
		int c = 0;
		char *tok = strtok(line, ",\r\n");
		for (; tok; tok = strtok(NULL, ",\r\n"), c++) {
			if (!strcmp(tok, "frame")) col_frame = c;
			else if (!strcmp(tok, "type")) col_type = c;
			else if (!strcmp(tok, "bytes")) col_bytes = c;
			else if (!strcmp(tok, "slice_qp") || !strcmp(tok, "qp")) col_qp = c;
			else if (!strcmp(tok, "target_kbps") || !strcmp(tok, "kbps")) col_tgt = c;
		}
	}
	if (col_type < 0 || col_bytes < 0 || col_qp < 0) { fclose(f); return -1; }
	while (fgets(line, sizeof line, f) && t->n < 4096) {
		int c = 0;
		char *tok = strtok(line, ",\r\n");
		for (; tok; tok = strtok(NULL, ",\r\n"), c++) {
			if (c == col_type) t->is_i[t->n] = (tok[0] == 'I');
			else if (c == col_bytes) t->bytes[t->n] = (uint32_t)strtoul(tok, NULL, 10);
			else if (c == col_qp) t->qp[t->n] = (uint32_t)strtoul(tok, NULL, 10);
			else if (c == col_tgt) { t->target_kbps[t->n] = atof(tok); t->has_target = 1; }
		}
		t->n++;
	}
	(void)col_frame;
	fclose(f);
	return t->n ? 0 : -1;
}

static double tolerance_for(const struct traj *t)
{
	if (t->kbps == 8000 || t->kbps == 16000)
		return 2.5;
	if (t->kbps == 2000)
		return 20.0;
	return 6.0;
}

static void replay_one(const char *path)
{
	static struct traj t;
	struct vcenc_rc rc;
	double sum_abs = 0, sum_abs_i = 0, vendor_bits = 0, cur_kbps;
	int i, n_i = 0, max_abs = 0, within2 = 0;
	uint32_t ours[4096];

	if (load_csv(path, &t)) {
		printf("FAIL cannot parse %s\n", path);
		fails++;
		return;
	}
	csv_seen++;
	cur_kbps = t.has_target && t.target_kbps[0] > 0 ? t.target_kbps[0] : t.kbps;
	if (cur_kbps <= 0) {
		printf("FAIL %s: no bitrate (need traj<kbps>_ name, a .log or a target_kbps column)\n", t.tag);
		fails++;
		return;
	}
	vcenc_rc_init(&rc, t.codec, t.w, t.h, t.fps, cur_kbps * 1000.0, t.gop, t.mode);

	for (i = 0; i < t.n; i++) {
		int d;
		if (t.has_target && t.target_kbps[i] > 0 && t.target_kbps[i] != cur_kbps) {
			cur_kbps = t.target_kbps[i];
			vcenc_rc_set_target(&rc, cur_kbps * 1000.0, t.fps);
		}
		ours[i] = vcenc_rc_pick_qp(&rc, t.is_i[i]);
		vcenc_rc_update(&rc, 8.0 * t.bytes[i], t.qp[i]);
		d = abs((int)ours[i] - (int)t.qp[i]);
		sum_abs += d;
		if (d > max_abs) max_abs = d;
		if (d <= 2) within2++;
		if (t.is_i[i]) { sum_abs_i += d; n_i++; }
		vendor_bits += 8.0 * t.bytes[i];
	}

	printf("\n== %s: %s %ux%u %s %.0f kbps fps %u gop %u, %d frames "
	       "(vendor achieved %.0f kbps)\n", t.tag,
	       t.codec == ENC_CODEC_HEVC ? "HEVC" : "H.264", t.w, t.h,
	       t.mode == VCENC_RC_VBR ? "VBR" : "CBR", t.kbps, t.fps, t.gop, t.n,
	       vendor_bits / t.n * t.fps / 1000.0);
	printf("   frame: vendor->ours  (I frames marked *)\n");
	for (i = 0; i < t.n; i++) {
		printf("%s%3d:%s%2u->%-2u", i % 10 ? " " : "   ", i,
		       t.is_i[i] ? "*" : "", t.qp[i], ours[i]);
		if (i % 10 == 9 || i == t.n - 1)
			printf("\n");
	}
	{
		double mean = sum_abs / t.n, tol = tolerance_for(&t);
		int seed_err = abs((int)ours[0] - (int)t.qp[0]);
		printf("   mean|dQP| %.2f  max %d  within+-2 %d/%d  IDR mean|dQP| %.2f (%d IDRs)"
		       "  first-IDR %u vs %u  -> tolerance %.1f %s\n",
		       mean, max_abs, within2, t.n, n_i ? sum_abs_i / n_i : 0.0, n_i,
		       ours[0], t.qp[0], tol,
		       mean <= tol && seed_err <= 1 ? "PASS" : "FAIL");
		if (mean > tol || seed_err > 1)
			fails++;
	}
}

static int walk_cb(const char *path, const struct stat *sb, int type, struct FTW *ftw)
{
	size_t n = strlen(path);
	(void)sb; (void)ftw;
	if (type == FTW_F && n > 15 && !strcmp(path + n - 15, "_trajectory.csv"))
		replay_one(path);
	return 0;
}

/* ------------------------------------------------------------------ */
/* B. closed-loop simulation                                           */

struct plant {
	const char *name;
	uint32_t codec;
	double c_i, s_i;    /* bytes at QP 32, QP per halving (I) */
	double c_p, s_p;    /* same for P */
	double alt;         /* even/odd size ratio (1 = none) */
};

/* Fitted from the committed vendor data (see file header). */
static const struct plant PLANTS[] = {
	{ "card-h264",  ENC_CODEC_H264, 10803, 19.0, 11023, 16.6, 1.68 },
	{ "card-hevc",  ENC_CODEC_HEVC, 16631,  8.6,  5036, 10.8, 1.68 },
	{ "video-h264", ENC_CODEC_H264, 150000, 6.0, 15000,  6.0, 1.0  },
	{ "video-hevc", ENC_CODEC_HEVC,  90000, 6.0,  8000,  6.0, 1.0  },
	{ "desktop",    ENC_CODEC_H264, 200000, 18.3,  300,  6.0, 1.0  },
};

static double plant_bytes(const struct plant *p, int is_i, uint32_t qp, int n,
			  double scale_p)
{
	double b = is_i ? p->c_i * exp2(-((double)qp - 32.0) / p->s_i)
			: p->c_p * exp2(-((double)qp - 32.0) / p->s_p) * scale_p;
	if (p->alt != 1.0) {
		double hi = 2.0 * p->alt / (1.0 + p->alt), lo = 2.0 / (1.0 + p->alt);
		b *= (n & 1) ? lo : hi;
	}
	return b < 40.0 ? 40.0 : b;
}

/* GOP bytes at a uniform QP (plant capacity) */
static double plant_gop_bytes(const struct plant *p, uint32_t qp, uint32_t gop)
{
	return p->c_i * exp2(-((double)qp - 32.0) / p->s_i)
	     + (gop - 1) * p->c_p * exp2(-((double)qp - 32.0) / p->s_p);
}

struct simres {
	double achieved_kbps;      /* over the measurement window */
	double i_share;            /* IDR bytes / GOP bytes, last GOP */
	uint32_t qp_i_last, qp_p_min, qp_p_max;
	double max_2s_bits;        /* worst 2 s window, bits */
	double first_after_switch_qp_delta;
};

static void simulate(const struct plant *p, double kbps, uint32_t fps, uint32_t gop,
		     uint32_t mode, int frames, int meas_from,
		     int switch_at, double switch_kbps,
		     int burst_from, int burst_to, double burst_scale,
		     struct simres *r)
{
	struct vcenc_rc rc;
	static double bits[8192];
	double meas_bits = 0, gop_bits = 0, gop_i_bits = 0, cur_kbps = kbps;
	int i, meas_n = 0;
	uint32_t last_qp = 0;

	memset(r, 0, sizeof *r);
	r->qp_p_min = 99;
	vcenc_rc_init(&rc, p->codec, 1920, 1080, fps, kbps * 1000.0, gop, mode);
	for (i = 0; i < frames; i++) {
		int is_i = (i % (int)gop) == 0;
		uint32_t qp;
		double b;
		if (switch_at > 0 && i == switch_at) {
			vcenc_rc_set_target(&rc, switch_kbps * 1000.0, fps);
			cur_kbps = switch_kbps;
		}
		qp = vcenc_rc_pick_qp(&rc, is_i);
		if (switch_at > 0 && i == switch_at)
			r->first_after_switch_qp_delta = (double)qp - (double)last_qp;
		b = plant_bytes(p, is_i, qp, i,
				(i >= burst_from && i < burst_to) ? burst_scale : 1.0);
		vcenc_rc_update(&rc, 8.0 * b, qp);
		bits[i] = 8.0 * b;
		last_qp = qp;
		if (is_i) { gop_bits = 0; gop_i_bits = 8.0 * b; r->qp_i_last = qp; }
		gop_bits += 8.0 * b;
		if (i >= meas_from) {
			meas_bits += 8.0 * b; meas_n++;
			if (!is_i) {
				if (qp < r->qp_p_min) r->qp_p_min = qp;
				if (qp > r->qp_p_max) r->qp_p_max = qp;
			}
		}
	}
	(void)cur_kbps;
	r->achieved_kbps = meas_n ? meas_bits / meas_n * fps / 1000.0 : 0;
	r->i_share = gop_bits > 0 ? gop_i_bits / gop_bits : 0;
	{
		int win = (int)(2 * fps), s;
		for (s = 0; s + win <= frames; s++) {
			double w = 0;
			int k;
			for (k = 0; k < win; k++) w += bits[s + k];
			if (w > r->max_2s_bits) r->max_2s_bits = w;
		}
	}
}

static void closed_loop(void)
{
	static const double KBPS[] = { 2000, 8000, 16000 };
	const uint32_t fps = 60, gop = 30;
	unsigned pi, ki;

	printf("\n== closed loop: 1080p60, GOP 30, 10 s per run, steady state = last 5 s\n");
	for (pi = 0; pi < sizeof PLANTS / sizeof PLANTS[0]; pi++) {
		const struct plant *p = &PLANTS[pi];
		for (ki = 0; ki < 3; ki++) {
			struct simres r;
			double target_gop = KBPS[ki] * 1000.0 / 8.0 * gop / fps;
			double cap_lo = plant_gop_bytes(p, VCENC_QP_MAX - 2, gop);   /* fewest bytes */
			double cap_hi = plant_gop_bytes(p, VCENC_QP_MIN + 2, gop);   /* most bytes */
			int reachable = target_gop >= cap_lo && target_gop <= cap_hi;
			const char *verdict;
			int ok;
			simulate(p, KBPS[ki], fps, gop, VCENC_RC_CBR, 600, 300,
				 0, 0, 0, 0, 1.0, &r);
			if (reachable) {
				ok = fabs(r.achieved_kbps - KBPS[ki]) <= 0.10 * KBPS[ki];
				verdict = "reachable: +-10 %";
			} else if (target_gop < cap_lo) {
				/* content too rich even at qpMax: expect the ceiling */
				ok = r.qp_p_max == VCENC_QP_MAX && r.achieved_kbps <= cap_lo * 8 / gop * fps / 1000.0 * 1.02;
				verdict = "unreachable (over): P at qpMax";
			} else {
				/* content too poor even at qpMin: expect under target */
				ok = r.achieved_kbps <= KBPS[ki] * 1.02 && r.qp_p_min <= VCENC_QP_MIN + 2 + VCENC_RC_P_FLOOR_DELTA;
				verdict = "unreachable (under): <= target, floor-bound";
			}
			printf("  %-11s %5.0f kbps -> %7.0f kbps (%+5.1f %%)  IDR QP %2u  P QP [%2u..%2u]"
			       "  I share %.2f  worst-2s %.2f s   %s %s\n",
			       p->name, KBPS[ki], r.achieved_kbps,
			       100.0 * (r.achieved_kbps - KBPS[ki]) / KBPS[ki],
			       r.qp_i_last, r.qp_p_min, r.qp_p_max, r.i_share,
			       r.max_2s_bits / (KBPS[ki] * 1000.0), verdict,
			       ok ? "PASS" : "FAIL");
			if (!ok) fails++;
			/* the leaky bucket: no 2 s window may exceed the CPB by more than
			 * the step-limited transient allows */
			if (r.max_2s_bits > 1.5 * VCENC_RC_CPB_SEC * KBPS[ki] * 1000.0) {
				printf("    FAIL worst 2 s window %.2f s of target bits > 3 s\n",
				       r.max_2s_bits / (KBPS[ki] * 1000.0));
				fails++;
			}
		}
	}

	/* dynamic bitrate: 8 -> 2 -> 16 Mbps on the textbook plants */
	printf("\n== retarget: 8000 kbps, then 2000 at frame 300, then 16000 at frame 600 (last 3 s of each window)\n");
	for (pi = 2; pi < 4; pi++) {
		const struct plant *p = &PLANTS[pi];
		struct simres r1, r2;
		int ok1, ok2;
		simulate(p, 8000, fps, gop, VCENC_RC_CBR, 600, 420, 300, 2000, 0, 0, 1.0, &r1);
		simulate(p, 2000, fps, gop, VCENC_RC_CBR, 600, 420, 300, 16000, 0, 0, 1.0, &r2);
		ok1 = fabs(r1.achieved_kbps - 2000) <= 200 && r1.first_after_switch_qp_delta >= 3;
		ok2 = fabs(r2.achieved_kbps - 16000) <= 1600 && r2.first_after_switch_qp_delta <= -3;
		printf("  %-11s 8000->2000: %6.0f kbps, first QP step %+.0f  %s\n", p->name,
		       r1.achieved_kbps, r1.first_after_switch_qp_delta, ok1 ? "PASS" : "FAIL");
		printf("  %-11s 2000->16000: %6.0f kbps, first QP step %+.0f  %s\n", p->name,
		       r2.achieved_kbps, r2.first_after_switch_qp_delta, ok2 ? "PASS" : "FAIL");
		if (!ok1) fails++;
		if (!ok2) fails++;
	}

	/* burst: P complexity x4 for 2 s in the middle of an 8 Mbps run */
	printf("\n== burst: video-h264 at 8000 kbps, P complexity x4 for frames 300..420\n");
	{
		struct simres r;
		int ok;
		simulate(&PLANTS[2], 8000, fps, gop, VCENC_RC_CBR, 900, 480, 0, 0, 300, 420, 4.0, &r);
		ok = r.max_2s_bits <= 1.25 * VCENC_RC_CPB_SEC * 8000e3
		     && fabs(r.achieved_kbps - 8000) <= 800;
		printf("  worst 2 s window %.2f s of target bits (CPB 2 s), after-burst %.0f kbps  %s\n",
		       r.max_2s_bits / 8000e3, r.achieved_kbps, ok ? "PASS" : "FAIL");
		if (!ok) fails++;
	}

	/* VBR: cap only; desktop plant must not inflate the IDR below the seed */
	printf("\n== VBR: desktop plant, 8000 kbps cap\n");
	{
		struct simres r;
		int ok;
		simulate(&PLANTS[4], 8000, fps, gop, VCENC_RC_VBR, 600, 300, 0, 0, 0, 0, 1.0, &r);
		ok = r.achieved_kbps <= 8000 * 1.02 && r.qp_i_last >= vcenc_rc_seed_qp(8000e3 / (60.0 * 1920 * 1080));
		printf("  %6.0f kbps, IDR QP %u (seed %u), P QP [%u..%u]  %s\n", r.achieved_kbps,
		       r.qp_i_last, vcenc_rc_seed_qp(8000e3 / (60.0 * 1920 * 1080)),
		       r.qp_p_min, r.qp_p_max, ok ? "PASS" : "FAIL");
		if (!ok) fails++;
	}
}

/* ------------------------------------------------------------------ */

static void seed_law(void)
{
	/* vendor first-IDR slice QPs (E3/E6/H8), 60 fps */
	static const struct { uint32_t w, h; double kbps; uint32_t qp; int tol; } S[] = {
		{ 1920, 1080,  8000, 32, 0 }, { 1920, 1080, 16000, 32, 0 },
		{ 2048, 1080,  8000, 32, 0 }, { 1920, 1440,  8000, 34, 0 },
		{ 2560, 1080,  8000, 34, 0 }, { 2560, 1440,  8000, 36, 0 },
		{ 3840, 2160,  8000, 36, 0 }, { 3840, 2400,  8000, 36, 0 },
		{ 1920, 1080,  2000, 37, 1 } /* H.264 37, HEVC 35 */,
	};
	unsigned i;
	printf("\n== seed law\n");
	for (i = 0; i < sizeof S / sizeof S[0]; i++) {
		uint32_t q = vcenc_rc_seed_qp(S[i].kbps * 1000.0 / (60.0 * S[i].w * S[i].h));
		int ok = abs((int)q - (int)S[i].qp) <= S[i].tol;
		printf("  %4ux%-4u %5.0f kbps: seed %u vendor %u %s\n", S[i].w, S[i].h,
		       S[i].kbps, q, S[i].qp, ok ? "ok" : "FAIL");
		if (!ok) fails++;
	}
}

int main(int argc, char **argv)
{
	seed_law();
	if (argc > 1) {
		printf("\n== vendor trajectory replay under %s\n", argv[1]);
		nftw(argv[1], walk_cb, 16, FTW_PHYS);
		if (!csv_seen) {
			printf("FAIL no *_trajectory.csv found\n");
			fails++;
		}
	}
	closed_loop();
	if (fails) {
		printf("\nRESULT: FAIL (%d)\n", fails);
		return 1;
	}
	printf("\nRESULT: PASS (%d trajectories replayed)\n", csv_seen);
	return 0;
}
