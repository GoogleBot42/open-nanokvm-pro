// SPDX-License-Identifier: GPL-2.0 OR MIT
/*
 * vcenc_qp.h -- the VC8000E QP-dependent register block (#46 seam).
 *
 * Three registers move with the quantiser and nothing else:
 *
 *   sw7        = (pic_init_qp << 26) | (frame_qp << 8)
 *   sw37       = L(q)                       a lambda pair (hi16, lo16)
 *   sw125+k    = F_<type>(q - 2k), k = 0..7 the mode-decision cost LUT
 *
 * with the table index
 *
 *   q = min(QP, 35)       for I/IDR frames
 *   q = min(QP, 35) - 3   for P frames
 *
 * so the block saturates: every I program at QP >= 36 is identical, and so is
 * every P program at QP >= 35.  All three laws were derived by differential
 * observation of the VENDOR encoder on the real device (the fixed-QP ladder
 * QP 16..51 of docs/reference/vcenc-open/vendor-diff-20260904/E2/, plus the
 * QP points the E1/E3/E4 phases and the 17-geometry probe swept as a side
 * effect of rate control).  No vendor code was read.
 *
 * F is a per-frame-type LUT.  The I and P instantiations agree at every index
 * observed in both EXCEPT q=19 (hi16 0x0200 vs 0x0204) and q=20 (lo16 0x0800
 * vs 0x0810), so the two tables are kept separate.  L is a single table: an I
 * frame at q and a P frame at the same q program the same sw37 (cross-checked
 * at q=19 and q=22 by independent runs).
 *
 * The tables themselves live in the auto-generated vcenc_qp_tables.h; the
 * generator (tests/gen_vectors.py) mines them straight out of the decoded
 * vendor programs and records the provenance of every entry.  The FIXQP
 * identity test in tests/vcenc_geom_test.c is the arbiter: it rebuilds the
 * whole 511-register program at each ladder QP and diffs it against the
 * vendor's.
 */
#ifndef VCENC_QP_H
#define VCENC_QP_H

#include <stdint.h>
#include "vcenc_qp_tables.h"

/* Range the tables cover.  Below 16 the I-frame block would need F(q) indices
 * the vendor never programmed; above 51 is not an H.264 QP. */
#define VCENC_QP_MIN 16u
#define VCENC_QP_MAX 51u

static inline int vcenc_qp_valid(uint32_t qp)
{
	return qp >= VCENC_QP_MIN && qp <= VCENC_QP_MAX;
}

/* Table index for a frame QP: clamps at 35 (I) / 32 (P). */
static inline int vcenc_qp_index(uint32_t qp, int is_p)
{
	int q = (int)(qp > 35u ? 35u : qp);
	return is_p ? q - 3 : q;
}

static inline uint32_t vcg_lut(const uint32_t *t, int lo, int hi, int q)
{
	if (q < lo)
		q = lo;
	if (q > hi)
		q = hi;
	return t[q - lo];
}

/*
 * Program the QP block for one frame.
 *   qp           : frame QP, VCENC_QP_MIN..VCENC_QP_MAX
 *   is_p         : 0 = I/IDR, 1 = P
 *   sw7_qp_field : receives the sw7 LOW field, (qp << 8); the caller ORs in
 *                  its own (pic_init_qp << 26) high field
 *   sw37         : receives the lambda pair
 *   blk          : receives sw125..sw132
 * Returns 0, or -1 (nothing written) if qp is outside the table range.
 */
static inline int vcenc_qp_regs(uint32_t qp, int is_p, uint32_t *sw7_qp_field,
				uint32_t *sw37, uint32_t blk[8])
{
	if (!vcenc_qp_valid(qp))
		return -1;
	int q = vcenc_qp_index(qp, is_p);
	const uint32_t *f = is_p ? VCENC_F_P : VCENC_F_I;
	int flo = is_p ? VCENC_F_P_LO : VCENC_F_I_LO;
	int fhi = is_p ? VCENC_F_P_HI : VCENC_F_I_HI;

	if (sw7_qp_field)
		*sw7_qp_field = (qp & 0x3fu) << 8;
	if (sw37)
		*sw37 = vcg_lut(VCENC_L, VCENC_L_LO, VCENC_L_HI, q);
	if (blk)
		for (int k = 0; k < 8; k++)
			blk[k] = vcg_lut(f, flo, fhi, q - 2 * k);
	return 0;
}

#endif /* VCENC_QP_H */
