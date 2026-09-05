// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * vcenc_rc_test -- host validation of the from-scratch rate controller (#46).
 *
 * Two families of evidence, both hardware-free:
 *
 * A. VENDOR TRAJECTORY REPLAY. Every `*_trajectory.csv` under the directory
 *    given as argv[1] (columns frame,type,bytes,slice_qp and optionally
 *    br_kbps / target_kbps) is replayed through vcenc_rc.h: the controller
 *    sees the vendor's real per-frame sizes and its own QP decision for each
 *    frame is compared to the vendor's. Session parameters come from the
 *    sibling vdrive log (`<tag>.log`, first line `# vdrive tag=..
 *    [codec=h265] WxH rc=cbr|vbr br=8000 fps=60/60 gop=30 ..`), so a new
 *    capture is picked up by dropping the two files in. A per-frame bitrate
 *    column drives vcenc_rc_set_target() mid-stream (the R3 runs).
 *
 *    This is a ONE-STEP-AHEAD comparison: after each frame the controller's
 *    state (window, last size, last QP) is advanced with the vendor's real
 *    QP and size, so every decision is "from the vendor's state, what would
 *    we pick next". A free-running comparison needs the encoder (sizes
 *    depend on our QP) -- that is the closed-loop family below and the
 *    device run.
 *
 *    Tolerance: mean |dQP| <= 1.5 over the scored frames, the vendor QP
 *    clamped to our programmable range first (the QP tables stop at 16
 *    where the vendor descends to 10). Content-limited and VBR runs replay
 *    at 0.0..0.1; in-band CBR runs sit at 1.0..1.3, the residue being the
 *    +-1/+-2 choice the vendor itself does not make from r alone (REPORT
 *    §3). Plus the first-IDR QP within +-1 of the vendor's seed. HEVC CBR
 *    frames at <= 7000 kbps (1080p60) are the vendor's no-target DEFECT
 *    (REPORT §6): replayed and printed, excluded from the score.
 *
 * B. CLOSED-LOOP SIMULATION against size models measured on the real
 *    desktop (vendor-diff-rc-20260905):
 *      static   the measured IDR curve (84 KB at QP 10 .. 22 KB at 37); P
 *               1890 B at QP 21 when the QP holds, plus the refinement law
 *               below when it drops
 *      scroll   4 px/frame scroll: P 1.9..2.8 KB holding (R2 VBR), same
 *               refinement law with the scroll cost curve
 *      jump1    half-screen jump every frame (R6/R7): the measured P curve
 *               (43.9 KB at QP 21 .. 4.0 KB at 51, knee at 37..40), H.264 and
 *               HEVC
 *      video    textbook s = 6 plant for robustness
 *    Each plant runs 2/8/16 Mbps at 1080p60, GOP 30, 10 s; the steady-state
 *    rate over the last 5 s must land within +-10 % of the target where the
 *    plant can reach it inside [qpMin+2, 46], at the 46 ceiling (plus the
 *    IDR+3 ramp) when the content is richer than that, under the target when
 *    it is poorer, and never above 1.10 x target on a still picture. Extra
 *    scenarios: a mid-GOP retarget (8 -> 2 -> 16 Mbps: the P law answers in
 *    2..5 frames, no jump), a 2 s complexity burst against the 2 s CPB, and
 *    VBR (static under the cap descends to qpMin; scroll at the cap lands at
 *    0.75..1.0 x, the vendor's 0.90 x).
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
static double sum_mean_cbr, sum_mean_vbr;
static int n_cbr, n_vbr;

/* ------------------------------------------------------------------ */
/* A. vendor trajectory replay                                         */

#define MAXF 8192

struct traj {
	char tag[96];
	uint32_t codec, w, h, fps, gop, mode;
	double kbps;
	int n;
	int is_i[MAXF];
	uint32_t bytes[MAXF], qp[MAXF];
	double target_kbps[MAXF];   /* 0 = unchanged */
	int has_target;
};

static void parse_sidecar(const char *csv, struct traj *t)
{
	char path[1024], line[1024], *p;
	size_t n = strlen(csv);
	FILE *f;
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
	char line[2048];
	int col_type = -1, col_bytes = -1, col_qp = -1, col_tgt = -1;
	if (!f)
		return -1;
	memset(t, 0, sizeof *t);
	{
		/* tag = "<parent dir>/<name>" */
		const char *s = strrchr(path, '/'), *d = NULL;
		if (s) { for (d = s - 1; d > path && *d != '/'; d--) ; if (*d == '/') d++; }
		snprintf(t->tag, sizeof t->tag, "%s", d ? d : path);
		if (strlen(t->tag) > 15)
			t->tag[strlen(t->tag) - 15] = 0;
	}
	parse_sidecar(path, t);
	if (!fgets(line, sizeof line, f)) { fclose(f); return -1; }
	{
		int c = 0;
		char *tok = strtok(line, ",\r\n");
		for (; tok; tok = strtok(NULL, ",\r\n"), c++) {
			if (!strcmp(tok, "type")) col_type = c;
			else if (!strcmp(tok, "bytes")) col_bytes = c;
			else if (!strcmp(tok, "slice_qp") || !strcmp(tok, "qp")) col_qp = c;
			else if (!strcmp(tok, "br_kbps") || !strcmp(tok, "target_kbps") ||
				 !strcmp(tok, "kbps")) col_tgt = c;
		}
	}
	if (col_type < 0 || col_bytes < 0 || col_qp < 0) { fclose(f); return -1; }
	while (fgets(line, sizeof line, f) && t->n < MAXF) {
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
	fclose(f);
	return t->n ? 0 : -1;
}

/* the vendor's HEVC no-target mode: CBR, <= 7000 kbps at 1080p60 */
static int defective(const struct traj *t, double kbps)
{
	return t->codec == ENC_CODEC_HEVC && t->mode == VCENC_RC_CBR &&
	       kbps * 1000.0 / (60.0 * t->w * t->h) <= 0.0580 &&
	       kbps <= 7000;
}

static void replay_one(const char *path)
{
	static struct traj t;
	struct vcenc_rc rc;
	double sum_abs = 0, sum_abs_i = 0, sum_abs_def = 0, vendor_bits = 0, cur_kbps;
	int i, n_i = 0, n_scored = 0, n_def = 0, max_abs = 0, within1 = 0;
	static uint32_t ours[MAXF];
	static int excluded[MAXF];

	if (load_csv(path, &t)) {
		printf("FAIL cannot parse %s\n", path);
		fails++;
		return;
	}
	csv_seen++;
	cur_kbps = t.has_target && t.target_kbps[0] > 0 ? t.target_kbps[0] : t.kbps;
	if (cur_kbps <= 0) {
		printf("FAIL %s: no bitrate (need traj<kbps>_ name, a .log or a target column)\n", t.tag);
		fails++;
		return;
	}
	t.kbps = cur_kbps;
	vcenc_rc_init(&rc, t.codec, t.w, t.h, t.fps, cur_kbps * 1000.0, t.gop, t.mode);

	for (i = 0; i < t.n; i++) {
		int d;
		if (t.has_target && t.target_kbps[i] > 0 && t.target_kbps[i] != cur_kbps) {
			cur_kbps = t.target_kbps[i];
			vcenc_rc_set_target(&rc, cur_kbps * 1000.0, t.fps);
		}
		ours[i] = vcenc_rc_pick_qp(&rc, t.is_i[i]);
		vcenc_rc_update(&rc, 8.0 * t.bytes[i], t.qp[i]);
		/* score against the vendor QP clamped to OUR programmable range:
		 * the QP tables stop at 16 where the vendor descends to 10 */
		{
			int vq = (int)t.qp[i];
			if (vq < (int)VCENC_QP_MIN) vq = VCENC_QP_MIN;
			if (vq > (int)VCENC_QP_MAX) vq = VCENC_QP_MAX;
			d = abs((int)ours[i] - vq);
		}
		excluded[i] = defective(&t, cur_kbps);
		vendor_bits += 8.0 * t.bytes[i];
		if (excluded[i]) { sum_abs_def += d; n_def++; continue; }
		sum_abs += d;
		n_scored++;
		if (d > max_abs) max_abs = d;
		if (d <= 1) within1++;
		if (t.is_i[i]) { sum_abs_i += d; n_i++; }
	}

	printf("\n== %s: %s %ux%u %s %.0f kbps fps %u gop %u, %d frames "
	       "(vendor achieved %.0f kbps)%s\n", t.tag,
	       t.codec == ENC_CODEC_HEVC ? "HEVC" : "H.264", t.w, t.h,
	       t.mode == VCENC_RC_VBR ? "VBR" : "CBR", t.kbps, t.fps, t.gop, t.n,
	       vendor_bits / t.n * t.fps / 1000.0,
	       n_def ? "  [HEVC no-target defect frames excluded, see below]" : "");
	printf("   frame: vendor->ours  (* = IDR, ! = excluded defect frame)\n");
	for (i = 0; i < t.n; i++) {
		printf("%s%3d:%s%2u->%-2u", i % 10 ? " " : "   ", i,
		       excluded[i] ? "!" : t.is_i[i] ? "*" : "", t.qp[i], ours[i]);
		if (i % 10 == 9 || i == t.n - 1)
			printf("\n");
	}
	{
		double mean = n_scored ? sum_abs / n_scored : 0.0;
		double tol = 1.5;
		int seed_err = excluded[0] ? 0 : abs((int)ours[0] - (int)t.qp[0]);
		int ok = (n_scored == 0 || mean <= tol) && seed_err <= 1;
		printf("   scored %d frames: mean|dQP| %.2f  max %d  within+-1 %d/%d  IDR mean|dQP| %.2f (%d IDRs)"
		       "  first-IDR %u vs %u  -> tolerance %.1f %s\n",
		       n_scored, mean, max_abs, within1, n_scored,
		       n_i ? sum_abs_i / n_i : 0.0, n_i, ours[0], t.qp[0], tol,
		       ok ? "PASS" : "FAIL");
		if (n_def)
			printf("   defect frames (not scored): %d, mean|dQP| %.2f -- the vendor "
			       "ramps open-loop to 46 here; ours tracks the target\n",
			       n_def, sum_abs_def / n_def);
		if (!ok)
			fails++;
		if (n_scored) {
			if (t.mode == VCENC_RC_VBR) { sum_mean_vbr += mean; n_vbr++; }
			else { sum_mean_cbr += mean; n_cbr++; }
		}
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

/* A size curve: (QP, bytes) knots, log-linear between knots, extrapolated
 * with the end slopes. Knots are per-QP means of the vendor CSVs. */
struct curve { int n; const double *qp, *bytes; };

/* IDR bytes on the real desktop: R4/R1 (CBR 32..18), R1 2000 (37..24),
 * R2 VBR (13, 10) -- the same frame, so one curve. */
static const double I264_Q[] = { 10, 13, 18, 20, 22, 24, 26, 28, 30, 32, 33, 35, 37 };
static const double I264_B[] = { 84141, 74596, 60896, 56299, 51112, 46570, 42391, 38177, 34365, 30842, 29097, 25691, 22170 };
static const double I265_Q[] = { 18, 20, 22, 24, 26, 28, 30, 32, 35 };
static const double I265_B[] = { 57269, 52509, 48092, 43593, 39762, 36212, 32398, 28832, 23869 };
/* half-screen jump every frame (R6/R7 jump1), P frames */
static const double J264_Q[] = { 21, 24, 25, 26, 30, 32, 34, 35, 37, 40, 44, 46, 51 };
static const double J264_B[] = { 43870, 36506, 33063, 29838, 25759, 23464, 19850, 16539, 12495, 6773, 5367, 4930, 4021 };
static const double J265_Q[] = { 22, 24, 25, 26, 30, 32, 33, 34, 35, 37, 46, 51 };
static const double J265_B[] = { 42368, 38563, 32886, 29362, 25779, 23735, 21222, 17247, 14632, 10738, 4400, 3600 };
/* static desktop, QP holding (R4: 1890 B at 21, 1723 at 10, ~2.0 KB in the
 * 20s) and 4 px scroll holding (R2 VBR 2000, loosely bounded: 1.9 KB below
 * 20, 2.1 KB in the 20s, 2.8 KB in the 30s) */
static const double S264_Q[] = { 10, 21, 30, 46 };
static const double S264_B[] = { 1723, 1890, 2000, 2000 };
static const double C264_Q[] = { 10, 20, 30, 46 };
static const double C264_B[] = { 1920, 2100, 2800, 2800 };
/* textbook: bits halve every 6 QP */
static const double V264_Q[] = { 20, 32, 44 };
static const double VI_B[]  = { 600000, 150000, 37500 };
static const double VP_B[]  = {  60000,  15000,  3750 };

static const struct curve I264 = { 13, I264_Q, I264_B }, I265 = { 9, I265_Q, I265_B };
static const struct curve J264 = { 13, J264_Q, J264_B }, J265 = { 12, J265_Q, J265_B };
static const struct curve S264 = { 3, S264_Q, S264_B },  C264 = { 4, C264_Q, C264_B };
static const struct curve VI = { 3, V264_Q, VI_B },     VP = { 3, V264_Q, VP_B };

static double curve_bytes(const struct curve *c, double qp)
{
	int i = 0;
	double x0, x1, y0, y1;
	if (c->n == 1)
		return c->bytes[0];
	while (i < c->n - 2 && qp > c->qp[i + 1])
		i++;
	x0 = c->qp[i]; x1 = c->qp[i + 1];
	y0 = log2(c->bytes[i]); y1 = log2(c->bytes[i + 1]);
	return exp2(y0 + (y1 - y0) * (qp - x0) / (x1 - x0));
}

/*
 * Desktop refinement (the free-running encoder, RC off): a still picture
 * carries a QUALITY STATE qs (QP-equivalent of the reference). An IDR at
 * QP q sets qs = q + 4 (intra at q is coarser than inter-refined q: the
 * first P at IDR+3 still costs a full refinement frame, R4 8000: 8.8 KB).
 * A P frame at q < qs closes ALPHA = 0.25 of the gap (qs - q) and pays
 * D(q) per QP step of detail added, on top of the hold size. A -1/frame
 * descent therefore settles at a 4-QP lag and costs ~D every frame
 * (R4/R1 8000: 7..10 KB from 35 to 21; R2 VBR 8000: 7..9.7 KB), a QP that
 * stops moving converges geometrically (R2 VBR 8000: 8.3 -> 1.7 KB over 8
 * frames at QP 10), and a slow descent -- one new low every few frames --
 * pays 2..4.5 KB per drop (R2 VBR 2000: 3.1..4.6 KB) because the gap never
 * grows. A P frame at q >= qs costs the hold size. D(q): static 7 KB at
 * QP >= 21 tapering to ~0 below 19 (R4: 2.3 KB drops below 20); scroll
 * 3 KB at 32 rising to 7 KB at <= 25 (R2 VBR 8000: 3.2 -> 9.7 KB).
 */
#define PLANT_ALPHA 0.25
struct plant {
	const char *name;
	uint32_t codec;
	const struct curve *i, *p;
	int refine;         /* 0 none, 1 static law, 2 scroll law */
};

/* measured on the real 1080p desktop (vendor-diff-rc-20260905) */
static const struct plant PLANTS[] = {
	{ "static",     ENC_CODEC_H264, &I264, &S264, 1 },
	{ "scroll",     ENC_CODEC_H264, &I264, &C264, 2 },
	{ "jump1-h264", ENC_CODEC_H264, &I264, &J264, 0 },
	{ "jump1-hevc", ENC_CODEC_HEVC, &I265, &J265, 0 },
	{ "video-h264", ENC_CODEC_H264, &VI,   &VP,   0 },
};

static double plant_p_steady(const struct plant *p, uint32_t qp)
{
	return curve_bytes(p->p, qp);
}

static double plant_i(const struct plant *p, uint32_t qp)
{
	return curve_bytes(p->i, qp);
}

static double plant_refine_cost(const struct plant *p, uint32_t qp)
{
	double k;
	if (p->refine == 1) {
		k = ((double)qp - 19.0) / 2.0;
		if (k < 0.05) k = 0.05;
		if (k > 1) k = 1;
		return 7000.0 * k;
	}
	k = 7000.0 - 600.0 * ((double)qp - 25.0);
	if (k < 3000) k = 3000;
	if (k > 7000) k = 7000;
	return k;
}

/* qs: the plant's quality state, updated in place */
static double plant_bytes(const struct plant *p, int is_i, uint32_t qp,
			  double *qs, double scale_p)
{
	double b;
	if (is_i) {
		*qs = (double)qp + 4.0;
		return plant_i(p, qp);
	}
	b = plant_p_steady(p, qp) * scale_p;
	if (p->refine && (double)qp < *qs) {
		double add = PLANT_ALPHA * (*qs - (double)qp);   /* QP steps of detail */
		b += plant_refine_cost(p, qp) * add;
		*qs -= add;
	}
	return b < 40.0 ? 40.0 : b;
}

/* GOP bytes at a uniform QP with no refinement (plant capacity) */
static double plant_gop_bytes(const struct plant *p, uint32_t qp_i, uint32_t qp_p, uint32_t gop)
{
	return plant_i(p, qp_i) + (gop - 1) * plant_p_steady(p, qp_p);
}

/* fewest bytes the controller can reach: IDR pinned at the seed (law 5,
 * without the >50 % guard), P at the 46 ceiling */
static double plant_floor_kbps(const struct plant *p, double kbps, uint32_t fps, uint32_t gop)
{
	uint32_t seed = vcenc_rc_seed_qp(p->codec, kbps * 1000.0 / (fps * 1920.0 * 1080.0));
	return plant_gop_bytes(p, seed, VCENC_RC_P_CEIL_LATER, gop) * 8 / gop * fps / 1000.0;
}

struct simres {
	double achieved_kbps;      /* over the measurement window */
	uint32_t qp_i_last, qp_p_min, qp_p_max;
	double max_2s_bits;        /* worst 2 s window, bits */
	int    frames_to_move3;    /* after a switch: frames until |dQP| >= 3 */
};

static void simulate(const struct plant *p, double kbps, uint32_t fps, uint32_t gop,
		     uint32_t mode, int frames, int meas_from,
		     int switch_at, double switch_kbps,
		     int burst_from, int burst_to, double burst_scale,
		     struct simres *r)
{
	struct vcenc_rc rc;
	static double bits[16384];
	double meas_bits = 0, qs = 99.0;
	int i, meas_n = 0;
	uint32_t prev_qp = 0, qp_at_switch = 0;

	memset(r, 0, sizeof *r);
	r->qp_p_min = 99;
	r->frames_to_move3 = -1;
	vcenc_rc_init(&rc, p->codec, 1920, 1080, fps, kbps * 1000.0, gop, mode);
	for (i = 0; i < frames; i++) {
		int is_i = (i % (int)gop) == 0;
		uint32_t qp;
		double b;
		if (switch_at > 0 && i == switch_at) {
			vcenc_rc_set_target(&rc, switch_kbps * 1000.0, fps);
			qp_at_switch = prev_qp;
		}
		qp = vcenc_rc_pick_qp(&rc, is_i);
		if (switch_at > 0 && i >= switch_at && r->frames_to_move3 < 0 &&
		    abs((int)qp - (int)qp_at_switch) >= 3)
			r->frames_to_move3 = i - switch_at;
		b = plant_bytes(p, is_i, qp, &qs,
				(i >= burst_from && i < burst_to) ? burst_scale : 1.0);
		vcenc_rc_update(&rc, 8.0 * b, qp);
		bits[i] = 8.0 * b;
		prev_qp = qp;
		if (is_i) r->qp_i_last = qp;
		if (i >= meas_from) {
			meas_bits += 8.0 * b; meas_n++;
			if (!is_i) {
				if (qp < r->qp_p_min) r->qp_p_min = qp;
				if (qp > r->qp_p_max) r->qp_p_max = qp;
			}
		}
	}
	r->achieved_kbps = meas_n ? meas_bits / meas_n * fps / 1000.0 : 0;
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
			double cap_lo = plant_floor_kbps(p, KBPS[ki], fps, gop) / 8 * gop / fps * 1000.0; /* fewest bytes */
			double cap_hi = plant_gop_bytes(p, VCENC_QP_MIN + 2, VCENC_QP_MIN + 2, gop); /* most bytes */
			int reachable = target_gop >= cap_lo && target_gop <= cap_hi;
			const char *verdict;
			int ok;
			simulate(p, KBPS[ki], fps, gop, VCENC_RC_CBR, 600, 300,
				 0, 0, 0, 0, 1.0, &r);
			if (p->refine && !reachable && target_gop > cap_hi) {
				/* a still picture is not bounded by its hold size: refinement
				 * frames can fill the budget while the QP keeps moving. The
				 * vendor lands 1996/2004 kbps here with in-frame RC; free-
				 * running frames must at least honour the cap. */
				ok = r.achieved_kbps <= KBPS[ki] * 1.10;
				verdict = "still picture: <= 1.10 x target";
			} else if (reachable) {
				ok = fabs(r.achieved_kbps - KBPS[ki]) <= 0.10 * KBPS[ki];
				verdict = "reachable: +-10 %";
			} else if (target_gop < cap_lo) {
				/* richer than the ceiling allows: expect the 46 ceiling and
				 * the plant's rate there plus the IDR+3 ramp (the vendor's
				 * +30 %) */
				ok = r.qp_p_max == VCENC_RC_P_CEIL_LATER &&
				     r.achieved_kbps <= cap_lo * 8 / gop * fps / 1000.0 * 1.15;
				verdict = "unreachable (over): P at the 46 ceiling";
			} else {
				ok = r.achieved_kbps <= KBPS[ki] * 1.05 &&
				     r.qp_p_min <= VCENC_QP_MIN + VCENC_RC_P_FLOOR_DELTA;
				verdict = "content-limited: <= target, floor-bound";
			}
			printf("  %-11s %5.0f kbps -> %7.0f kbps (%+5.1f %%)  IDR QP %2u  P QP [%2u..%2u]"
			       "  worst-2s %.2f s   %s %s\n",
			       p->name, KBPS[ki], r.achieved_kbps,
			       100.0 * (r.achieved_kbps - KBPS[ki]) / KBPS[ki],
			       r.qp_i_last, r.qp_p_min, r.qp_p_max,
			       r.max_2s_bits / (KBPS[ki] * 1000.0), verdict,
			       ok ? "PASS" : "FAIL");
			if (!ok) fails++;
			if (reachable && r.max_2s_bits > 1.5 * VCENC_RC_CPB_SEC * KBPS[ki] * 1000.0) {
				printf("    FAIL worst 2 s window %.2f s of target bits > 3 s\n",
				       r.max_2s_bits / (KBPS[ki] * 1000.0));
				fails++;
			}
		}
	}

	/* dynamic bitrate: 8 -> 2 -> 16 Mbps, switched MID-GOP (frame 305 /
	 * 605) so the P law answers first: +2/frame downward-rate (|dQP| >= 3
	 * within 2 frames), -1/frame upward (within 3), no jump; the first IDR
	 * after the change restarts at the new seed; converged within 3 s */
	printf("\n== retarget: 8000 kbps, then 2000 at frame 305, then 16000 at frame 605 (last 3 s of each window)\n");
	for (pi = 2; pi < 5; pi++) {
		const struct plant *p = &PLANTS[pi];
		struct simres r1, r2;
		int ok1, ok2;
		simulate(p, 8000, fps, gop, VCENC_RC_CBR, 600, 420, 305, 2000, 0, 0, 1.0, &r1);
		simulate(p, 2000, fps, gop, VCENC_RC_CBR, 600, 420, 305, 16000, 0, 0, 1.0, &r2);
		/* 2000 on the jump plants is over the ceiling: expect the 46 rate */
		{
			double cap_lo = plant_floor_kbps(p, 2000, fps, gop);
			ok1 = cap_lo > 2000 ? (r1.qp_p_max == VCENC_RC_P_CEIL_LATER && r1.achieved_kbps <= cap_lo * 1.10)
					    : fabs(r1.achieved_kbps - 2000) <= 200;
		}
		ok1 = ok1 && r1.frames_to_move3 >= 1 && r1.frames_to_move3 <= 3;
		ok2 = fabs(r2.achieved_kbps - 16000) <= 1600 && r2.frames_to_move3 >= 2 && r2.frames_to_move3 <= 6;
		printf("  %-11s 8000->2000: %6.0f kbps, P QP [%u..%u], |dQP|>=3 after %d frames  %s\n", p->name,
		       r1.achieved_kbps, r1.qp_p_min, r1.qp_p_max, r1.frames_to_move3, ok1 ? "PASS" : "FAIL");
		printf("  %-11s 2000->16000: %6.0f kbps, P QP [%u..%u], |dQP|>=3 after %d frames  %s\n", p->name,
		       r2.achieved_kbps, r2.qp_p_min, r2.qp_p_max, r2.frames_to_move3, ok2 ? "PASS" : "FAIL");
		if (!ok1) fails++;
		if (!ok2) fails++;
	}

	/* burst: P complexity x4 for 2 s in the middle of an 8 Mbps run */
	printf("\n== burst: video-h264 at 8000 kbps, P complexity x4 for frames 300..420\n");
	{
		struct simres r;
		int ok;
		simulate(&PLANTS[4], 8000, fps, gop, VCENC_RC_CBR, 900, 480, 0, 0, 300, 420, 4.0, &r);
		ok = r.max_2s_bits <= 1.25 * VCENC_RC_CPB_SEC * 8000e3
		     && fabs(r.achieved_kbps - 8000) <= 800;
		printf("  worst 2 s window %.2f s of target bits (CPB 2 s), after-burst %.0f kbps  %s\n",
		       r.max_2s_bits / 8000e3, r.achieved_kbps, ok ? "PASS" : "FAIL");
		if (!ok) fails++;
	}

	/* VBR: cap only. Under the cap the QP descends to qpMin (static desktop);
	 * at the cap the rate lands at 0.8..1.0 x (jump plant at 2000). */
	printf("\n== VBR\n");
	{
		struct simres r;
		int ok;
		simulate(&PLANTS[0], 8000, fps, gop, VCENC_RC_VBR, 600, 300, 0, 0, 0, 0, 1.0, &r);
		ok = r.achieved_kbps <= 8000 * 1.02 && r.qp_p_min == VCENC_QP_MIN;
		printf("  static  cap 8000: %6.0f kbps, IDR QP %u, P QP [%u..%u]  %s\n", r.achieved_kbps,
		       r.qp_i_last, r.qp_p_min, r.qp_p_max, ok ? "PASS" : "FAIL");
		if (!ok) fails++;
		/* the vendor's R2 scroll run at the 2000 cap landed at 1802 (0.90x) */
		simulate(&PLANTS[1], 2000, fps, gop, VCENC_RC_VBR, 600, 300, 0, 0, 0, 0, 1.0, &r);
		ok = r.achieved_kbps <= 2000 * 1.02 && r.achieved_kbps >= 2000 * 0.75;
		printf("  scroll  cap 2000: %6.0f kbps, IDR QP %u, P QP [%u..%u]  %s\n", r.achieved_kbps,
		       r.qp_i_last, r.qp_p_min, r.qp_p_max, ok ? "PASS" : "FAIL");
		if (!ok) fails++;
	}
}

/* ------------------------------------------------------------------ */

static void seed_law(void)
{
	/* vendor first-IDR slice QPs at 60 fps: E3 geometry series, E6/H8, R1..R7 */
	static const struct { uint32_t codec, w, h; double kbps; uint32_t qp; int tol; } S[] = {
		{ 0, 1920, 1080,  1000, 37, 0 }, { 0, 1920, 1080,  2000, 37, 0 },
		{ 0, 1920, 1080,  3000, 37, 0 }, { 0, 1920, 1080,  8000, 32, 0 },
		{ 0, 1920, 1080, 16000, 32, 0 }, { 0, 2048, 1080,  8000, 32, 0 },
		{ 0, 1920, 1440,  8000, 34, 0 }, { 0, 2560, 1080,  8000, 34, 0 },
		{ 0, 2560, 1440,  8000, 36, 0 }, { 0, 3840, 2160,  8000, 36, 1 },
		{ 0, 3840, 2400,  8000, 36, 1 },
		{ 1, 1920, 1080,  1000, 35, 0 }, { 1, 1920, 1080,  2000, 35, 0 },
		{ 1, 1920, 1080,  3000, 35, 0 }, { 1, 1920, 1080,  7500, 32, 0 },
		{ 1, 1920, 1080,  8000, 32, 0 }, { 1, 1920, 1080, 16000, 32, 0 },
	};
	static const struct { double kbps; uint32_t qp; } V[] = {
		{ 2000, 36 }, { 8000, 32 }, { 16000, 26 },
	};
	unsigned i;
	printf("\n== seed law\n");
	for (i = 0; i < sizeof S / sizeof S[0]; i++) {
		uint32_t q = vcenc_rc_seed_qp(S[i].codec, S[i].kbps * 1000.0 / (60.0 * S[i].w * S[i].h));
		int ok = abs((int)q - (int)S[i].qp) <= S[i].tol;
		printf("  CBR %s %4ux%-4u %5.0f kbps: seed %u vendor %u %s\n",
		       S[i].codec ? "HEVC " : "H.264", S[i].w, S[i].h,
		       S[i].kbps, q, S[i].qp, ok ? "ok" : "FAIL");
		if (!ok) fails++;
	}
	for (i = 0; i < sizeof V / sizeof V[0]; i++) {
		uint32_t q = vcenc_rc_nominal_qp(V[i].kbps * 1000.0 / (60.0 * 1920 * 1080));
		int ok = q == V[i].qp;
		printf("  VBR 1920x1080 %5.0f kbps: seed %u vendor %u %s\n", V[i].kbps, q, V[i].qp,
		       ok ? "ok" : "FAIL");
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
		printf("\n== replay summary: %d trajectories; mean of per-run mean|dQP|: CBR %.2f (%d runs), VBR %.2f (%d runs)\n",
		       csv_seen, n_cbr ? sum_mean_cbr / n_cbr : 0.0, n_cbr,
		       n_vbr ? sum_mean_vbr / n_vbr : 0.0, n_vbr);
	}
	closed_loop();
	if (fails) {
		printf("\nRESULT: FAIL (%d)\n", fails);
		return 1;
	}
	printf("\nRESULT: PASS (%d trajectories replayed)\n", csv_seen);
	return 0;
}
