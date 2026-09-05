// SPDX-License-Identifier: GPL-2.0 OR MIT
/* Host test: the from-source HEVC VPS/SPS/PPS must be byte-identical to the
 * vendor's fixed-QP32 1080p parameter sets (docs/reference/vcenc-open/
 * vendor-diff-hevc-20260905/H3/fixqp32.h265, first three NALs) and, for the
 * VPS+SPS, to the 1366x768 CBR stream's (conformance window). */
#include <stdio.h>
#include <string.h>
#include "../vcenc_hevc_header.h"

static int hex2bin(const char *h, uint8_t *b) { int n = 0; for (; h[0] && h[1]; h += 2) { unsigned v; sscanf(h, "%2x", &v); b[n++] = (uint8_t)v; } return n; }
static int cmp(const char *what, const uint8_t *got, int gn, const char *hex)
{
	uint8_t want[256]; int wn = hex2bin(hex, want);
	int ok = (gn == wn + 4) && !memcmp(got + 4, want, wn);
	printf("%-16s %s (%d bytes)\n", what, ok ? "MATCH" : "DIFF", gn);
	if (!ok) { printf("  got :"); for (int i = 4; i < gn; i++) printf("%02x", got[i]); printf("\n  want:%s\n", hex); }
	return !ok;
}
int main(void)
{
	uint8_t b[256]; int fails = 0, n;
	n = vcenc_write_vps(b, 153);
	fails += cmp("VPS 1080p", b, n, "40010c01ffff014000000300800000030000030099ac09");
	n = vcenc_write_hevc_sps(b, 1920, 1080, 153);
	fails += cmp("SPS 1080p", b, n, "420101014000000300800000030000030099a003c08010e58dae4b2b66b9713705010504000003000400000300f0fe2c4a");
	n = vcenc_write_hevc_pps(b, 32);
	fails += cmp("PPS qp32 fixqp", b, n, "4401c0e306066480");
	n = vcenc_write_hevc_sps(b, 1366, 768, 153);
	fails += cmp("SPS 1366x768", b, n, "420101014000000300800000030000030099a002ac80301d78dae4b2b66b97137050105040000003004000000f0fe2c4a0");
	uint8_t all[512]; n = vcenc_write_hevc_headers(all, 1920, 1080, 32, 153);
	printf("headers 1080p qp32: %d bytes (vendor 92)\n", n);
	printf("%s\n", fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
