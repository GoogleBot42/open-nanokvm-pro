/* pipebench.c -- time libkvm's own capture+encode loop, stage by stage.
 * Links the shipped libkvm.so and calls the very functions libkvm.c calls,
 * in the very order kvmv_read_img calls them, so the numbers are the
 * production path's and not a re-implementation's.  Issue #107.
 *
 * usage: pipebench <W> <H> <seconds> <mode> [kbps] [out.h26x]
 *   mode = cap     -- kvm_cap_get / kvm_cap_release only (no encoder)
 *          h264    -- cap_get, venc_send, cap_release, venc_get, venc_release
 *          h265    -- same, H.265
 *
 * Prints per-stage mean/worst milliseconds and the resulting frame rate,
 * next to the V4L2 sequence span (what the hardware produced over the same
 * window).  The gap between the two is the frames the consumer lost.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

#include "kvm_pipeline.h"

static double now_s(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

struct stage { double sum, worst; unsigned long n; };

static void acc(struct stage *s, double dt)
{
	s->sum += dt;
	if (dt > s->worst) s->worst = dt;
	s->n++;
}

static void report(const char *name, const struct stage *s, double elapsed)
{
	if (!s->n) { printf("  %-12s (never ran)\n", name); return; }
	printf("  %-12s mean %7.2f ms  worst %7.2f ms  total %6.2f s (%4.1f%%)  n=%lu\n",
	       name, 1e3 * s->sum / s->n, 1e3 * s->worst, s->sum,
	       100 * s->sum / elapsed, s->n);
}

int main(int argc, char **argv)
{
	if (argc < 5) {
		fprintf(stderr, "usage: pipebench <W> <H> <seconds> <cap|h264|h265> [kbps]\n");
		return 2;
	}
	int W = atoi(argv[1]), H = atoi(argv[2]);
	double secs = atof(argv[3]);
	const char *mode = argv[4];
	int kbps = argc > 5 ? atoi(argv[5]) : 8000;
	FILE *out = argc > 6 ? fopen(argv[6], "wb") : NULL;
	if (argc > 6 && !out) { perror("fopen"); return 1; }
	int want_enc = strcmp(mode, "cap") != 0;
	int h265 = !strcmp(mode, "h265");
	int chn = h265 ? KVM_VENC_H265_CHN : KVM_VENC_H264_CHN;

	kvm_cap_ctx cap;
	if (kvm_sys_init(&cap, W, H) != 0) { fprintf(stderr, "sys_init failed\n"); return 1; }
	if (kvm_cap_start(&cap, W, H, 30) != 0) { fprintf(stderr, "cap_start failed\n"); return 1; }
	if (want_enc &&
	    kvm_venc_create(chn, h265 ? KVM_CODEC_H265 : KVM_CODEC_H264,
			    W, H, 30, 30, kbps, 0) != 0) {
		fprintf(stderr, "venc_create failed\n");
		kvm_cap_stop(&cap); kvm_sys_deinit(&cap);
		return 1;
	}

	struct stage s_get = {0}, s_send = {0}, s_rel = {0}, s_pack = {0}, s_prel = {0};
	unsigned long frames = 0, packs = 0, misses = 0, bytes = 0;
	uint32_t seq_first = 0, seq_last = 0;
	int have_first = 0;
	unsigned long gap_frames = 0;

	double t0 = now_s();
	while (now_s() - t0 < secs) {
		kvm_frame f;
		double a = now_s();
		if (kvm_cap_get(&f, 1000) != 0) { misses++; continue; }
		double b = now_s();
		acc(&s_get, b - a);

		if (!have_first) { seq_first = f.seq; have_first = 1; }
		else if (f.seq != seq_last + 1) gap_frames += f.seq - seq_last - 1;
		seq_last = f.seq;
		frames++;

		if (!want_enc) {
			kvm_cap_release(&f);
			acc(&s_rel, now_s() - b);
			continue;
		}

		kvm_venc_send(chn, &f);
		double c = now_s();
		acc(&s_send, c - b);

		kvm_cap_release(&f);
		double d = now_s();
		acc(&s_rel, d - c);

		kvm_pack pk;
		if (kvm_venc_get(chn, &pk, 2000) == 0) {
			double e = now_s();
			acc(&s_pack, e - d);
			packs++;
			bytes += pk.len;
			if (out) fwrite(pk.data, 1, pk.len, out);
			kvm_venc_release(chn, &pk);
			acc(&s_prel, now_s() - e);
		} else {
			acc(&s_pack, now_s() - d);
		}
	}
	double elapsed = now_s() - t0;

	if (out) fclose(out);
	if (want_enc) kvm_venc_destroy(chn);
	kvm_cap_stop(&cap);
	kvm_sys_deinit(&cap);

	unsigned long span = have_first ? (unsigned long)(seq_last - seq_first) + 1 : 0;
	printf("mode=%s %dx%d  elapsed %.2f s\n", mode, W, H, elapsed);
	printf("frames    %lu -> %.2f fps   (cap_get misses %lu)\n", frames, frames / elapsed, misses);
	printf("seq span  %lu -> %.2f fps produced by the hardware; %lu frames lost\n",
	       span, span / elapsed, gap_frames);
	if (want_enc)
		printf("packs     %lu -> %.2f fps, %lu B total (%.2f Mbit/s)\n",
		       packs, packs / elapsed, bytes, 8.0 * bytes / elapsed / 1e6);
	report("cap_get", &s_get, elapsed);
	report("venc_send", &s_send, elapsed);
	report("cap_release", &s_rel, elapsed);
	report("venc_get", &s_pack, elapsed);
	report("venc_release", &s_prel, elapsed);
	return 0;
}
