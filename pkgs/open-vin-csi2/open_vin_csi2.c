// SPDX-License-Identifier: GPL-2.0
/*
 * open_vin_csi2 - V4L2 CSI-2 receiver subdev for the Axera AX630C MIPI CSI-2
 * host. Open replacement for the vendor ax_mipi_rx blob (epic #55, issue #57).
 *
 * CLEAN-ROOM: written solely from the behavioral specification
 * docs/reference/deblob-scope/specs/spec-mipi-rx.md ("spec" below). Register
 * offsets and field names describe the silicon; spec section numbers are cited
 * at each sequence. No vendor code was consulted.
 *
 * Hardware (device-confirmed in the spec header):
 *   - CSI-2 protocol controller: CUSTOM Axera register map, DWC-derived error
 *     core only. Do NOT confuse with mainline dw-mipi-csi2 - offsets differ.
 *   - Two RX controllers, 0x02600000 (dev0) / 0x02602000 (dev1), stride
 *     0x2000, both inside this platform device's single reg bank. The
 *     NanoKVM-Pro uses dev0 only, fed by a fixed HDMI-to-MIPI bridge:
 *     4 data lanes, digital YUV422-8, comboMode 4, DataLaneMap [0,1,3,4],
 *     ClkLane [2,5]. This driver drives dev0.
 *   - IRQ is ERROR-ONLY (spec section 5): no frame/packet interrupt exists in
 *     this block. Frame timing belongs to the downstream VIN capture driver.
 *
 * Global register blocks NOT in this device's DT reg (mapped by fixed
 * physical address below; TODO(mainline): move these behind DT/syscon
 * phandles for the mainline port):
 *   - isp_sys_glb  0x02500000  csirx clock gates, soft resets, deskew lock
 *   - D-PHY global 0x023f0000  analog/PPI lane config, HS-RX timing, PHY en
 *   - common_glb   0x02340000  VI subsystem: D-PHY power, dphyrx TLB clock
 *
 * Shared-owner discipline (spec section 7): isp_sys_glb and common_glb are
 * also touched by the in-tree axera clk/reset providers and (in a vendor
 * boot) by the VIN stack. All writes below use the hardware's SET/CLR and
 * VALUE/MASK shadow registers - never a read-modify-write of a whole shared
 * word - so concurrent owners of *other* bits are safe.
 *
 * The pinmux block (0x02300000) is deliberately NOT touched: it is owned by
 * pinctrl and carries the SW_PWR pad trap. The MIPI pads must be muxed by
 * firmware/pinctrl before streaming. Verified: a cold boot of the purged
 * image (#54, no vendor module anywhere) streams 4K30 through this receiver,
 * so the boot chain muxes the MIPI pads without ax_mipi_rx. Revisit only for
 * the mainline port (spec section 6a step 12).
 */

#include <linux/delay.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/spinlock.h>

#include <media/media-entity.h>
#include <media/v4l2-ctrls.h>
#include <media/v4l2-device.h>
#include <media/v4l2-subdev.h>

#define OPENVIN_CSI2_NAME		"open_vin_csi2"

/* Fixed source configuration (spec header: device-confirmed). */
#define OPENVIN_LANE_NUM		4
#define OPENVIN_COMBO_MODE		4

/*
 * ---------------------------------------------------------------------------
 * CSI-2 protocol controller (DT reg 0x02600000, 0x4000; dev stride 0x2000)
 * Spec section 2. Offsets relative to the per-dev controller base.
 * ---------------------------------------------------------------------------
 */
#define CSI_DEV_STRIDE			0x2000

#define CSI_CTRL_SOFT_RESET		0x04	/* bits[1:0] csi2rx soft reset */
#define CSI_CTRL_DPHY_LANE_CONTROL	0x08	/* lane map + combo mode */
#define CSI_CTRL_ERR_IRQ_MASK_A		0x1c
#define CSI_CTRL_DPHY_ERR_IRQ_MASK	0x24
#define CSI_CTRL_ERR_STATUS0		0x28	/* W1C; spec section 5 bit map */
#define CSI_CTRL_ERR_IRQS_MASK		0x2c
#define CSI_CTRL_ERR_IRQS_MASK2		0x38	/* second per-ctrl copy */
#define CSI_CTRL_STREAM_CFG_LANES	0x40	/* N_LANES / lane-enable */
#define CSI_CTRL_ERR_STATUS1		0x4c	/* W1C; per-lane errsot hs */
#define CSI_CTRL_INFO_IRQS_MASK		0x50
#define CSI_CTRL_STREAM_CTRL		0x100	/* bit0 start, bit1 stop, bit4 srst */
#define CSI_CTRL_STREAM0_MONITOR_CTRL	0x10c
#define CSI_CTRL_STREAM0_MONITOR	0x110	/* bit4 toggled during init */
#define CSI_CTRL_STREAM0_MONITOR_LB	0x118

/* CSI_CTRL_DPHY_LANE_CONTROL fields (spec section 2, +0x08). Device-confirmed
 * final value for comboMode 4: 0x43210410. */
#define CSI_LANE_CONTROL_MASK		0x77770710
#define CSI_LANE_CONTROL_BASE		0x43210010	/* default lane map + bit4 */
#define CSI_LANE_CONTROL_COMBO(m)	((m) << 8)	/* bits[10:8] */

/* Mask/enable values, verbatim from spec section 2 init order. */
#define CSI_ERR_IRQ_MASK_A_VAL		0x7
#define CSI_DPHY_ERR_IRQ_MASK_VAL	0x6f
#define CSI_ERR_IRQS_MASK_VAL		0x00011ee1
#define CSI_INFO_IRQS_MASK_VAL		0x00111100
#define CSI_MONITOR_CTRL_MASK		0x333
#define CSI_MONITOR_CTRL_VAL		0x301
#define CSI_MONITOR_LB_VAL		0x00000d1f

#define CSI_STREAM_CTRL_START		BIT(0)
#define CSI_STREAM_CTRL_STOP		BIT(1)
#define CSI_STREAM_CTRL_SRST		BIT(4)

/*
 * N_LANES register (+0x40): table[LaneNum-1] | 0x10 (spec section 2).
 * The 4-lane value 0x1f is device-confirmed. The table itself is inferred as
 * a lane-enable bitmask {0x1, 0x3, 0x7, 0xf}.
 * TODO(bringup): confirm the 1/2/3-lane table entries on hardware if a
 * non-4-lane mode is ever needed (spec section 9 item 5).
 */
static const u32 csi_lane_table[4] = { 0x1, 0x3, 0x7, 0xf };
#define CSI_STREAM_CFG_LANES_OR		0x10
#define CSI_STREAM_CFG_LANES_MASK	0x1f

/*
 * ---------------------------------------------------------------------------
 * isp_sys_glb (phys 0x02500000) - csirx clock gates, soft resets, deskew lock
 * Spec section 3. SET/CLR pairs: write 1 to SET asserts, 1 to CLR deasserts.
 * VALUE/MASK pairs: write field mask to MASK, then value to VALUE.
 * ---------------------------------------------------------------------------
 */
#define ISP_SYS_GLB_PHYS		0x02500000
#define ISP_SYS_GLB_SIZE		0x1000

#define ISP_GLB_CSIRX_STATUS		0xc4	/* deskew status: bits[1:0]==3 locked, 2 = recovery trigger (spec-dphy-writes s5) */
#define ISP_GLB_CSIRX_LOCK_MASK		0x3
#define ISP_GLB_CSIRX_LOCKED		0x3

#define ISP_GLB_CLK_SEL_VAL		0xc8	/* csirx_cfg_clk_sel bits[1:0] */
#define ISP_GLB_CLK_SEL_MASK		0xcc
#define ISP_GLB_CSIRX_CFG_CLK_SEL_MASK	0x3
#define ISP_GLB_CSIRX_CFG_CLK_SEL_VAL	0x3	/* spec section 6a step 14 */

#define ISP_GLB_CLK_EB0_SET		0xd0
#define ISP_GLB_CLK_EB0_CLR		0xd4
#define ISP_GLB_CFG_PHY_CLK_EB		BIT(0)
#define ISP_GLB_DPHY_RX_REF_CLK_EB	BIT(1)

#define ISP_GLB_CLK_EB1_SET		0xd8
#define ISP_GLB_CLK_EB1_CLR		0xdc
#define ISP_GLB_SYS_PIXEL_CLK_EB(d)	BIT(4 + (d))
#define ISP_GLB_CSIRX_PCLK_EB(d)	BIT(7 + (d))

#define ISP_GLB_SWRST_SET		0xe0	/* write 1: assert reset */
#define ISP_GLB_SWRST_CLR		0xe4	/* write 1: deassert reset */
#define ISP_GLB_RST_PIXEL(d)		BIT(2 + 4 * (d))
#define ISP_GLB_RST_PPI_RX_BYTE(d)	BIT(3 + 4 * (d))
#define ISP_GLB_RST_PRESETN(d)		BIT(4 + 4 * (d))
#define ISP_GLB_RST_SYS(d)		BIT(5 + 4 * (d))
#define ISP_GLB_RST_DESKEW(d)		BIT(10 + (d))
#define ISP_GLB_RST_DPHYRX		BIT(12)

#define ISP_GLB_CSI_CTRL_SEL_VAL	0x218
#define ISP_GLB_CSI_CTRL_SEL_MASK	0x21c
#define ISP_GLB_CSI_CTRL_SEL_DEV0_MASK	0x3	/* dev0 field; dev1 = 0x30 */

/*
 * csi_ctrl_sel (spec-dphy-writes section 3): a masked-write pair, 0x21c =
 * mask/write-enable, 0x218 = value; field [1:0] = controller-0 select,
 * [5:4] = controller-1 select. For "4 lanes on one PHY" (lane_divide_mode
 * 0, our HDMI case) the vendor selects mode 4 = {mask 3, value 0} then
 * {mask 0x30, value 0x30}, once, at the top of the D-PHY global init. The
 * first draft wrote {mask 3, value 3} (mode 0) and a second "running" value
 * that does not exist on the vendor path.
 */

/*
 * ---------------------------------------------------------------------------
 * D-PHY global config (phys 0x023f0000) - lane swap, HS-RX timing, PHY enable
 * Spec section 4 + spec-dphy-writes sections 2-4 (instruction-level list).
 * Every config register is a write-only SET (0xc0 + 8k) / CLR (+4) pair with
 * a readable mirror at 0x34 + (SET - 0xc8) / 2. Vendor idiom: CLR(mask) then
 * SET(value << shift).
 * ---------------------------------------------------------------------------
 */
#define DPHY_GLB_PHYS			0x023f0000
#define DPHY_GLB_SIZE			0x1000

#define DPHY_LANE_CFG_SET		0xc8	/* lane swap fields, databus16, 1d2c */
#define DPHY_LANE_CFG_CLR		0xcc
#define DPHY_DPDN_SWAP_MASK		0x0000003f
#define DPHY_SWAP_FIELD			0x7
#define DPHY_C1_SWAP_SHIFT		6
#define DPHY_C0_SWAP_SHIFT		9
#define DPHY_D3_SWAP_SHIFT		12
#define DPHY_D2_SWAP_SHIFT		15
#define DPHY_D1_SWAP_SHIFT		18
#define DPHY_D0_SWAP_SHIFT		21
#define DPHY_DATABUS16_SEL		BIT(24)
#define DPHY_1D2C_EN			BIT(25)
/*
 * Physical lane slot feeding each logical lane {d0, d1, d2, d3, c0, c1}.
 * Board wiring for the LT6911UXC bridge on the NanoKVM-Pro: clock on
 * physical slot 2, data on 0,1,3,4 (the "map[0,1,3,4]/clk[2,5]" this
 * repo's kvm_pipeline.h has always documented). DEVICE-CONFIRMED
 * 2026-09-01: the vendor streaming state reads 0x0005c540 in the +0x34
 * mirror; the first draft's naive 0..5 map read 0x00053940 and produced a
 * locked PHY that forwarded only short packets (no pixel data).
 */
static const u8 openvin_lane_swap[6] = { 0, 1, 3, 4, 2, 5 };
static const u8 openvin_lane_swap_shift[6] = {
	DPHY_D0_SWAP_SHIFT, DPHY_D1_SWAP_SHIFT, DPHY_D2_SWAP_SHIFT,
	DPHY_D3_SWAP_SHIFT, DPHY_C0_SWAP_SHIFT, DPHY_C1_SWAP_SHIFT,
};

#define DPHY_MODE_SET			0xd0	/* mirror +0x38; vendor 0x820 (MIPI) */
#define DPHY_MODE_CLR			0xd4
#define DPHY_MODE_FIELD_MASK		0x00000fff
#define DPHY_MODE_MIPI			0x00000820
#define DPHY_PRE_TIME_SET		0xd8	/* mirror +0x3c: 4 x 8-bit pre-times */
#define DPHY_PRE_TIME_CLR		0xdc
#define DPHY_PRE_TIME_VAL		8	/* all four groups, fixed (no rate scaling) */
#define DPHY_DESKEW_DBG_SET		0xe8	/* mirror +0x44: debug-ctrl deskew reset */
#define DPHY_DESKEW_DBG_CLR		0xec
#define DPHY_DESKEW_DBG_4LANE		0x3c00

#define DPHY_PHY_EN			0x110	/* write-1-to-enable, per lane */
#define DPHY_PHY_DISABLE		0x114	/* write-1-to-disable mirror */
#define DPHY_PHY_ALL_LANES		0x3f	/* clk pair + 4 data lanes */
#define DPHY_PHY_DATA_LANES		0x3c	/* 4 data lanes (bits 5:2) */

/*
 * ---------------------------------------------------------------------------
 * common_glb (phys 0x02340000) - VI subsystem controller
 * Spec sections 3/6/7. HAZARD: shared with the VIN stack and the in-tree
 * axera reset provider; only ever write single bits via SET/CLR.
 *
 * D-PHY power registers follow the bank's (STATUS, SET, CLR) triple layout,
 * the same shape as the clock gate at +0x24/+0x28/+0x2c. DEVICE-CONFIRMED
 * 2026-09-01 (our own /dev/mem observation on a base-only boot vs the
 * vendor streaming state): power_off = {status 0x1e8, SET 0x1ec, CLR 0x1f0},
 * power_ready = {status 0x1f4, SET 0x1f8, CLR 0x1fc}. The first draft's
 * "CLR ready" write went to 0x1f8, which is the SET strobe: 0x1f4 read 1
 * afterwards (vendor streaming reads 0) and the ISP pixel clocks stayed
 * dead (isp_sys_glb +0xc4 = 0 instead of 0xf0f). Writing 1 to 0x1fc clears
 * it and the pixel clocks come up immediately.
 * ---------------------------------------------------------------------------
 */
#define COMMON_GLB_PHYS			0x02340000
#define COMMON_GLB_SIZE			0x1000

#define CGLB_CLK_EB_SET			0x28
#define CGLB_CLK_EB_CLR			0x2c
#define CGLB_CLK_DPHYRX_TLB_EB		BIT(9)
#define CGLB_RST_CLR			0x5c	/* comm_sys_reset deassert (async pair 0x58 SET / 0x5c CLR) */
#define CGLB_RST_DPHYRX_TLB		BIT(7)

#define CGLB_DPHY_POWER_OFF_STATUS	0x1e8
#define CGLB_DPHY_POWER_OFF_SET		0x1ec
#define CGLB_DPHY_POWER_OFF_CLR		0x1f0	/* spec section 6a step 18 */
#define CGLB_DPHY_POWER_READY_STATUS	0x1f4
#define CGLB_DPHY_POWER_READY_SET	0x1f8
#define CGLB_DPHY_POWER_READY_CLR	0x1fc
#define CGLB_DPHY_POWER_BIT		BIT(0)

/* Deskew lock poll (spec section 5: retry ~20x with delay). */
#define OPENVIN_LOCK_POLL_US		1000
#define OPENVIN_LOCK_TIMEOUT_US		20000

/* ErrorStatus0 bit meanings (spec section 5). Index = bit number. */
static const char *const csi_err0_names[32] = {
	[0]  = "packet/protocol error",
	[4]  = "stream0 FIFO overflow",
	[5]  = "stream1 FIFO overflow",
	[6]  = "stream2 FIFO overflow",
	[7]  = "stream3 FIFO overflow",
	[8]  = "truncated header",
	[9]  = "truncated long packet: wrong byte count",
	[10] = "truncated long packet: no payload",
	[11] = "reserved/invalid short packet",
	[12] = "invalid access to configuration register space",
	[16] = "resynchronization FIFO overflow (DPHY<->protocol)",
	[17] = "data-id error in header",
	[18] = "ECC error corrected",
	[19] = "unrecoverable ECC error",
	/*
	 * TODO(bringup): the spec lists a CRC-error condition in the same
	 * status word but does not pin its bit position; identify it from a
	 * live error dump and name it here.
	 */
};

/*
 * Private V4L2 controls exposing M1 health telemetry (PHY lock + error
 * counters) on the subdev node, so link bring-up is checkable from userspace
 * without the capture pipeline.
 * TODO(mainline): request an official control range before submission.
 */
#define OPENVIN_CID_BASE		(V4L2_CID_USER_BASE + 0x10a0)
#define OPENVIN_CID_LINK_LOCKED		(OPENVIN_CID_BASE + 0)
#define OPENVIN_CID_ERR0_EVENTS		(OPENVIN_CID_BASE + 1)
#define OPENVIN_CID_ERR1_EVENTS		(OPENVIN_CID_BASE + 2)

enum openvin_pads {
	OPENVIN_PAD_SINK,	/* from the HDMI->MIPI bridge */
	OPENVIN_PAD_SOURCE,	/* to the VIN capture block (M2) */
	OPENVIN_NUM_PADS,
};

struct openvin_csi2 {
	struct device *dev;

	void __iomem *csi;		/* CSI-2 protocol controller, dev0 */
	void __iomem *isp_glb;		/* isp_sys_glb 0x02500000 */
	void __iomem *dphy_glb;		/* D-PHY global 0x023f0000 */
	void __iomem *common_glb;	/* common_glb 0x02340000 */

	int irq;

	struct v4l2_subdev sd;
	struct media_pad pads[OPENVIN_NUM_PADS];
	struct v4l2_ctrl_handler ctrls;
	struct v4l2_mbus_framefmt fmt;

	/* Standalone-mode owner of the subdev (M1 bring-up without M2). */
	struct v4l2_device v4l2_dev;
	bool standalone;

	struct mutex lock;		/* start/stop + format */
	bool streaming;

	/* IRQ telemetry (spec section 5): counters + last latched status. */
	spinlock_t err_lock;
	u64 err0_events;
	u64 err1_events;
	u32 last_err0;
	u32 last_err1;
	u64 irq_count;
};

static bool standalone;
module_param(standalone, bool, 0444);
MODULE_PARM_DESC(standalone,
	"Own a private v4l2_device and expose /dev/v4l-subdev* without a bridge (M1 bench mode). Default 0: register with v4l2-async for the open_vin_capture bridge, which starts/stops the receiver with its stream (M2 link).");

static bool start_on_probe;
module_param(start_on_probe, bool, 0444);
MODULE_PARM_DESC(start_on_probe,
	"Run the full RX bring-up at probe time (M1 hardware milestone: prove PHY lock without the capture pipeline).");

static inline struct openvin_csi2 *sd_to_openvin(struct v4l2_subdev *sd)
{
	return container_of(sd, struct openvin_csi2, sd);
}

/* --------------------------------------------------------------------------
 * Register helpers. Plain writes for the CSI controller (sole owner);
 * SET/CLR or VALUE/MASK shadow writes only for the shared glb blocks.
 */

static inline u32 csi_rd(struct openvin_csi2 *priv, u32 off)
{
	return readl(priv->csi + off);
}

static inline void csi_wr(struct openvin_csi2 *priv, u32 off, u32 val)
{
	writel(val, priv->csi + off);
}

static inline void csi_rmw(struct openvin_csi2 *priv, u32 off, u32 mask,
			   u32 val)
{
	csi_wr(priv, off, (csi_rd(priv, off) & ~mask) | (val & mask));
}

static inline u32 isp_glb_rd(struct openvin_csi2 *priv, u32 off)
{
	return readl(priv->isp_glb + off);
}

static inline void isp_glb_wr(struct openvin_csi2 *priv, u32 off, u32 val)
{
	writel(val, priv->isp_glb + off);
}

static inline void dphy_wr(struct openvin_csi2 *priv, u32 off, u32 val)
{
	writel(val, priv->dphy_glb + off);
}

static inline void cglb_wr(struct openvin_csi2 *priv, u32 off, u32 val)
{
	writel(val, priv->common_glb + off);
}

/* VALUE/MASK shadow write into isp_sys_glb (spec section 0 access idiom). */
static void isp_glb_field_wr(struct openvin_csi2 *priv, u32 val_off,
			     u32 mask_off, u32 mask, u32 val)
{
	isp_glb_wr(priv, mask_off, mask);
	isp_glb_wr(priv, val_off, val & mask);
}

static bool openvin_link_locked(struct openvin_csi2 *priv)
{
	return (isp_glb_rd(priv, ISP_GLB_CSIRX_STATUS) &
		ISP_GLB_CSIRX_LOCK_MASK) == ISP_GLB_CSIRX_LOCKED;
}

/* --------------------------------------------------------------------------
 * D-PHY global init -- spec-dphy-writes section 3, rows 1-33, resolved for
 * dev 0 / MIPI / 4 lanes on one PHY. Exact vendor order; every D-PHY config
 * write is CLR(field mask) then SET(value). One pass (the vendor start path
 * calls it once).
 */
static void openvin_dphy_glb_init(struct openvin_csi2 *priv)
{
	unsigned int i;

	/* rows 1-4: csi_ctrl_sel(dev0, mode 4): {mask 3, val 0}, {mask 0x30, val 0x30} */
	isp_glb_wr(priv, ISP_GLB_CSI_CTRL_SEL_MASK, 0x3);
	isp_glb_wr(priv, ISP_GLB_CSI_CTRL_SEL_VAL, 0x0);
	isp_glb_wr(priv, ISP_GLB_CSI_CTRL_SEL_MASK, 0x30);
	isp_glb_wr(priv, ISP_GLB_CSI_CTRL_SEL_VAL, 0x30);

	/* row 5: the thirteen plain words 0x00..0x30 are zeroed */
	for (i = 0; i <= 0x30; i += 4)
		dphy_wr(priv, i, 0);

	/* rows 6-17: lane swap, one 3-bit field per logical lane */
	for (i = 0; i < ARRAY_SIZE(openvin_lane_swap); i++) {
		dphy_wr(priv, DPHY_LANE_CFG_CLR,
			DPHY_SWAP_FIELD << openvin_lane_swap_shift[i]);
		dphy_wr(priv, DPHY_LANE_CFG_SET,
			(u32)openvin_lane_swap[i] << openvin_lane_swap_shift[i]);
	}
	/* row 18: 1d2c_en = 0 (single clock) */
	dphy_wr(priv, DPHY_LANE_CFG_CLR, DPHY_1D2C_EN);
	/* rows 19-20: dpdn_swap = 0 */
	dphy_wr(priv, DPHY_LANE_CFG_CLR, DPHY_DPDN_SWAP_MASK);
	dphy_wr(priv, DPHY_LANE_CFG_SET, 0);
	/* row 21: databus16_sel = 0 */
	dphy_wr(priv, DPHY_LANE_CFG_CLR, DPHY_DATABUS16_SEL);

	/* rows 22-29: HS-RX pre-times, clk grp1, clk grp0, data grp1, data grp0 */
	dphy_wr(priv, DPHY_PRE_TIME_CLR, 0x00ff0000);
	dphy_wr(priv, DPHY_PRE_TIME_SET, DPHY_PRE_TIME_VAL << 16);
	dphy_wr(priv, DPHY_PRE_TIME_CLR, 0xff000000);
	dphy_wr(priv, DPHY_PRE_TIME_SET, DPHY_PRE_TIME_VAL << 24);
	dphy_wr(priv, DPHY_PRE_TIME_CLR, 0x000000ff);
	dphy_wr(priv, DPHY_PRE_TIME_SET, DPHY_PRE_TIME_VAL);
	dphy_wr(priv, DPHY_PRE_TIME_CLR, 0x0000ff00);
	dphy_wr(priv, DPHY_PRE_TIME_SET, DPHY_PRE_TIME_VAL << 8);

	/* rows 30-31: the MIPI mode word (the first draft missed this pair) */
	dphy_wr(priv, DPHY_MODE_CLR, DPHY_MODE_FIELD_MASK);
	dphy_wr(priv, DPHY_MODE_SET, DPHY_MODE_MIPI);

	/* row 32: required settle before the D-PHY reset release */
	usleep_range(2000, 2500);

	/* row 33: release the D-PHY soft reset (isp_sys_glb, deassert = CLR) */
	isp_glb_wr(priv, ISP_GLB_SWRST_CLR, ISP_GLB_RST_DPHYRX);
}

/* --------------------------------------------------------------------------
 * CSI-2 protocol controller init - spec section 2, strict order (steps 1-14).
 */
static void openvin_csi_ctrl_init(struct openvin_csi2 *priv)
{
	u32 lanes;

	/* 1. Lane map + combo mode (device-confirmed result 0x43210410). */
	csi_rmw(priv, CSI_CTRL_DPHY_LANE_CONTROL, CSI_LANE_CONTROL_MASK,
		CSI_LANE_CONTROL_BASE |
		CSI_LANE_CONTROL_COMBO(OPENVIN_COMBO_MODE));

	/* 2. N_LANES / lane-enable (device-confirmed result 0x1f). */
	lanes = csi_lane_table[OPENVIN_LANE_NUM - 1] | CSI_STREAM_CFG_LANES_OR;
	csi_rmw(priv, CSI_CTRL_STREAM_CFG_LANES, CSI_STREAM_CFG_LANES_MASK,
		lanes);

	/* 3-9. IRQ masks and stream monitor config, before any reset. */
	csi_wr(priv, CSI_CTRL_ERR_IRQ_MASK_A, CSI_ERR_IRQ_MASK_A_VAL);
	csi_wr(priv, CSI_CTRL_DPHY_ERR_IRQ_MASK, CSI_DPHY_ERR_IRQ_MASK_VAL);
	csi_wr(priv, CSI_CTRL_ERR_IRQS_MASK, CSI_ERR_IRQS_MASK_VAL);
	csi_wr(priv, CSI_CTRL_ERR_IRQS_MASK2, CSI_ERR_IRQS_MASK_VAL);
	csi_wr(priv, CSI_CTRL_INFO_IRQS_MASK, CSI_INFO_IRQS_MASK_VAL);
	csi_rmw(priv, CSI_CTRL_STREAM0_MONITOR_CTRL, CSI_MONITOR_CTRL_MASK,
		CSI_MONITOR_CTRL_VAL);
	/* Stream monitor bit4 toggle (spec section 2 step 8). */
	csi_rmw(priv, CSI_CTRL_STREAM0_MONITOR, BIT(4), BIT(4));
	csi_wr(priv, CSI_CTRL_STREAM0_MONITOR_LB, CSI_MONITOR_LB_VAL);

	/* 10-11. Stream soft-reset pulse, then settle. */
	csi_rmw(priv, CSI_CTRL_STREAM_CTRL, CSI_STREAM_CTRL_SRST,
		CSI_STREAM_CTRL_SRST);
	udelay(10);
	csi_rmw(priv, CSI_CTRL_STREAM_CTRL, CSI_STREAM_CTRL_SRST, 0);
	udelay(100);

	/*
	 * 12-13. Clear the stop bit, set the start bit. Device-confirmed
	 * running state: +0x100 == 0x1.
	 * TODO(bringup): the spec notes the vendor start/stop encodings are
	 * RMW with a sentinel value 2 - verify start/stop/srst semantics by
	 * toggling live and watching deskew status (spec section 9 item 6).
	 */
	csi_rmw(priv, CSI_CTRL_STREAM_CTRL, CSI_STREAM_CTRL_STOP, 0);
	csi_rmw(priv, CSI_CTRL_STREAM_CTRL, CSI_STREAM_CTRL_START,
		CSI_STREAM_CTRL_START);

	/* 14. Clear any latched error/interrupt status, last. */
	csi_wr(priv, CSI_CTRL_ERR_STATUS0, 0xffffffff);
	csi_wr(priv, CSI_CTRL_ERR_STATUS1, 0xffffffff);
}

/* --------------------------------------------------------------------------
 * Full RX bring-up - spec section 6a (ax_mipi_rx_start behavioral order).
 * Hard ordering constraints (spec section 6a tail): resets deasserted ->
 * clocks enabled -> D-PHY powered -> D-PHY enabled -> controller init/stream.
 */
static int openvin_rx_start(struct openvin_csi2 *priv)
{
	u32 val;
	int ret;

	/*
	 * Step 1 (fastboot check) is skipped: common_glb_check_fastboot_mode
	 * guards against re-initialising a block the boot firmware already
	 * streams from. On an open-stack boot nothing has touched the RX.
	 * TODO(bringup): if boot firmware ever pre-starts the RX (vendor
	 * fastboot images), identify the common_glb fastboot flag and skip
	 * re-init here (spec sections 6a/7).
	 */

	/* Steps 2-5: deassert the csirx0 sub-resets (CLR = deassert). */
	isp_glb_wr(priv, ISP_GLB_SWRST_CLR, ISP_GLB_RST_PIXEL(0));
	isp_glb_wr(priv, ISP_GLB_SWRST_CLR, ISP_GLB_RST_PPI_RX_BYTE(0));
	isp_glb_wr(priv, ISP_GLB_SWRST_CLR, ISP_GLB_RST_PRESETN(0));
	isp_glb_wr(priv, ISP_GLB_SWRST_CLR, ISP_GLB_RST_SYS(0));

	/*
	 * Step 5: deassert both deskew resets (4 lanes -> deskew0 + deskew1),
	 * then step 6: the D-PHY debug-ctrl deskew reset release (CLR 0x3c00
	 * for 4 lanes) -- spec-dphy-writes section 5 rows 5-6.
	 */
	isp_glb_wr(priv, ISP_GLB_SWRST_CLR, ISP_GLB_RST_DESKEW(0));
	isp_glb_wr(priv, ISP_GLB_SWRST_CLR, ISP_GLB_RST_DESKEW(1));
	dphy_wr(priv, DPHY_DESKEW_DBG_CLR, DPHY_DESKEW_DBG_4LANE);

	/* Step 7: common_glb dphyrx TLB soft-reset deassert (row 7). */
	cglb_wr(priv, CGLB_RST_CLR, CGLB_RST_DPHYRX_TLB);

	/* Step 8: settle. */
	udelay(10);

	/* Steps 9-10: csirx0 pclk + pixel clock enables (SET = enable). */
	isp_glb_wr(priv, ISP_GLB_CLK_EB1_SET, ISP_GLB_CSIRX_PCLK_EB(0));
	isp_glb_wr(priv, ISP_GLB_CLK_EB1_SET, ISP_GLB_SYS_PIXEL_CLK_EB(0));

	/*
	 * The vendor start path runs the D-PHY global init exactly ONCE, after
	 * the power-up and lane disable below (spec-dphy-writes section 5 row
	 * 20); the earlier two-pass reading of the older spec was wrong.
	 * Step 12 (dphy_pin_mux_config): NOT performed - see the pinmux note
	 * in the header comment. Step 13 (ax_dvp_bt_soc_init, 0x02303000) is
	 * omitted: not on the MIPI data path (spec section 0).
	 */

	/* Step 14: csirx cfg clock select. */
	isp_glb_field_wr(priv, ISP_GLB_CLK_SEL_VAL, ISP_GLB_CLK_SEL_MASK,
			 ISP_GLB_CSIRX_CFG_CLK_SEL_MASK,
			 ISP_GLB_CSIRX_CFG_CLK_SEL_VAL);

	/* Steps 15-16: PHY config clock + D-PHY RX reference clock. */
	isp_glb_wr(priv, ISP_GLB_CLK_EB0_SET, ISP_GLB_CFG_PHY_CLK_EB);
	isp_glb_wr(priv, ISP_GLB_CLK_EB0_SET, ISP_GLB_DPHY_RX_REF_CLK_EB);

	/* Step 17: dphyrx TLB clock enable (common_glb, single-bit SET). */
	cglb_wr(priv, CGLB_CLK_EB_SET, CGLB_CLK_DPHYRX_TLB_EB);

	/*
	 * Steps 15-18 (spec-dphy-writes section 5): D-PHY power-up -- release
	 * power_off, settle, release power_ready, settle. Both are CLR strobes
	 * of the (status, SET, CLR) triples; the ready/off SET writes belong
	 * to the vendor's reset/PM path (mipi_rx_reset), which our teardown
	 * mirrors, not to the start path.
	 */
	cglb_wr(priv, CGLB_DPHY_POWER_OFF_CLR, CGLB_DPHY_POWER_BIT);
	udelay(100);
	cglb_wr(priv, CGLB_DPHY_POWER_READY_CLR, CGLB_DPHY_POWER_BIT);
	udelay(100);

	/* Step 19: disable all PHY lanes before the analog config. */
	dphy_wr(priv, DPHY_PHY_DISABLE, DPHY_PHY_ALL_LANES);

	/* Step 20: the D-PHY global init (lane swap, timing, mode, reset). */
	openvin_dphy_glb_init(priv);

	/* Step 23: enable clock + data lanes (4-lane: 0x3f). */
	dphy_wr(priv, DPHY_PHY_EN, DPHY_PHY_ALL_LANES);

	/* Step 24: data-lane disable/enable toggle. */
	dphy_wr(priv, DPHY_PHY_DISABLE, DPHY_PHY_DATA_LANES);
	dphy_wr(priv, DPHY_PHY_EN, DPHY_PHY_DATA_LANES);

	/* Step 25: CSI-2 protocol controller init, ends with stream start. */
	openvin_csi_ctrl_init(priv);

	/* Step 26: TLB clock enable again (pinmux write skipped, as above). */
	cglb_wr(priv, CGLB_CLK_EB_SET, CGLB_CLK_DPHYRX_TLB_EB);

	/*
	 * Deskew/lock status is valid only after step 25 (spec section 6a).
	 * Poll it (spec section 5: ~20 retries). Lock needs a live source on
	 * the bridge, so a timeout is a warning, not a failure: the link
	 * comes up when the host starts driving HDMI.
	 */
	ret = readl_poll_timeout(priv->isp_glb + ISP_GLB_CSIRX_STATUS, val,
				 (val & ISP_GLB_CSIRX_LOCK_MASK) ==
				 ISP_GLB_CSIRX_LOCKED,
				 OPENVIN_LOCK_POLL_US,
				 OPENVIN_LOCK_TIMEOUT_US);
	if (ret)
		dev_warn(priv->dev,
			 "link not locked after start (status 0x%08x) - no source?\n",
			 val);
	else
		dev_info(priv->dev, "link locked (deskew status 0x%08x)\n",
			 val);

	return 0;
}

/* --------------------------------------------------------------------------
 * Teardown - spec section 6d (mipi_rx_stop behavioral order).
 */
static void openvin_rx_stop(struct openvin_csi2 *priv)
{
	/* Assert the D-PHY soft reset. */
	isp_glb_wr(priv, ISP_GLB_SWRST_SET, ISP_GLB_RST_DPHYRX);

	/* Reference + config PHY clocks off (CLR = disable). */
	isp_glb_wr(priv, ISP_GLB_CLK_EB0_CLR, ISP_GLB_DPHY_RX_REF_CLK_EB);
	isp_glb_wr(priv, ISP_GLB_CLK_EB0_CLR, ISP_GLB_CFG_PHY_CLK_EB);

	/* All PHY lanes off. */
	dphy_wr(priv, DPHY_PHY_DISABLE, DPHY_PHY_ALL_LANES);

	/* D-PHY power-down cycle (ready then off, with settles). */
	cglb_wr(priv, CGLB_DPHY_POWER_READY_SET, CGLB_DPHY_POWER_BIT);
	udelay(100);
	cglb_wr(priv, CGLB_DPHY_POWER_OFF_SET, CGLB_DPHY_POWER_BIT);
	udelay(100);

	/* Deskew reset asserted, TLB clock off. */
	isp_glb_wr(priv, ISP_GLB_SWRST_SET, ISP_GLB_RST_DESKEW(0));
	cglb_wr(priv, CGLB_CLK_EB_CLR, CGLB_CLK_DPHYRX_TLB_EB);

	/* Stream stop, last (spec section 6d). */
	csi_rmw(priv, CSI_CTRL_STREAM_CTRL, CSI_STREAM_CTRL_START, 0);
	csi_rmw(priv, CSI_CTRL_STREAM_CTRL, CSI_STREAM_CTRL_STOP,
		CSI_STREAM_CTRL_STOP);
}

/* --------------------------------------------------------------------------
 * Error IRQ - spec section 5. Error-only: W1C both status words, count,
 * decode. No frame interrupt exists on this block.
 */
static irqreturn_t openvin_csi2_irq(int irq, void *arg)
{
	struct openvin_csi2 *priv = arg;
	unsigned long flags;
	unsigned long err0_bits;
	u32 err0, err1;
	unsigned int bit;

	err0 = csi_rd(priv, CSI_CTRL_ERR_STATUS0);
	if (err0)
		csi_wr(priv, CSI_CTRL_ERR_STATUS0, err0);
	err1 = csi_rd(priv, CSI_CTRL_ERR_STATUS1);
	if (err1)
		csi_wr(priv, CSI_CTRL_ERR_STATUS1, err1);

	if (!err0 && !err1)
		return IRQ_NONE;

	spin_lock_irqsave(&priv->err_lock, flags);
	priv->irq_count++;
	if (err0) {
		priv->last_err0 = err0;
		priv->err0_events += hweight32(err0);
	}
	if (err1) {
		priv->last_err1 = err1;
		priv->err1_events += hweight32(err1);
	}
	spin_unlock_irqrestore(&priv->err_lock, flags);

	err0_bits = err0;
	for_each_set_bit(bit, &err0_bits, 32)
		dev_dbg_ratelimited(priv->dev, "csi error: %s (bit %u)\n",
				    csi_err0_names[bit] ?: "unknown", bit);
	if (err1)
		dev_dbg_ratelimited(priv->dev,
				    "dphy errsot hs, lanes 0x%08x\n", err1);

	return IRQ_HANDLED;
}

/* --------------------------------------------------------------------------
 * V4L2 subdev ops
 */

static int openvin_csi2_s_stream(struct v4l2_subdev *sd, int enable)
{
	struct openvin_csi2 *priv = sd_to_openvin(sd);
	int ret = 0;

	mutex_lock(&priv->lock);
	if (enable && !priv->streaming) {
		enable_irq(priv->irq);
		ret = openvin_rx_start(priv);
		if (ret)
			disable_irq(priv->irq);
		else
			priv->streaming = true;
	} else if (!enable && priv->streaming) {
		disable_irq(priv->irq);
		openvin_rx_stop(priv);
		priv->streaming = false;
	}
	mutex_unlock(&priv->lock);

	return ret;
}

static int openvin_csi2_log_status(struct v4l2_subdev *sd)
{
	struct openvin_csi2 *priv = sd_to_openvin(sd);
	unsigned long flags;
	u64 err0_events, err1_events, irq_count;
	u32 last_err0, last_err1;

	spin_lock_irqsave(&priv->err_lock, flags);
	err0_events = priv->err0_events;
	err1_events = priv->err1_events;
	irq_count = priv->irq_count;
	last_err0 = priv->last_err0;
	last_err1 = priv->last_err1;
	spin_unlock_irqrestore(&priv->err_lock, flags);

	v4l2_info(sd, "streaming: %d\n", priv->streaming);
	v4l2_info(sd, "deskew/lock status: 0x%08x (%s)\n",
		  isp_glb_rd(priv, ISP_GLB_CSIRX_STATUS),
		  openvin_link_locked(priv) ? "LOCKED" : "not locked");
	v4l2_info(sd, "lane control: 0x%08x, n_lanes: 0x%08x, stream ctrl: 0x%08x\n",
		  csi_rd(priv, CSI_CTRL_DPHY_LANE_CONTROL),
		  csi_rd(priv, CSI_CTRL_STREAM_CFG_LANES),
		  csi_rd(priv, CSI_CTRL_STREAM_CTRL));
	v4l2_info(sd, "error irqs: %llu (status0 events: %llu, status1 events: %llu)\n",
		  irq_count, err0_events, err1_events);
	v4l2_info(sd, "last ErrorStatus0: 0x%08x, last ErrorStatus1: 0x%08x\n",
		  last_err0, last_err1);
	v4l2_info(sd, "live ErrorStatus0: 0x%08x, ErrorStatus1: 0x%08x\n",
		  csi_rd(priv, CSI_CTRL_ERR_STATUS0),
		  csi_rd(priv, CSI_CTRL_ERR_STATUS1));

	return 0;
}

static struct v4l2_mbus_framefmt *
openvin_get_pad_fmt(struct openvin_csi2 *priv,
		    struct v4l2_subdev_pad_config *cfg, unsigned int pad,
		    u32 which)
{
	if (which == V4L2_SUBDEV_FORMAT_TRY)
		return v4l2_subdev_get_try_format(&priv->sd, cfg, pad);
	return &priv->fmt;
}

static int openvin_csi2_enum_mbus_code(struct v4l2_subdev *sd,
				       struct v4l2_subdev_pad_config *cfg,
				       struct v4l2_subdev_mbus_code_enum *code)
{
	if (code->index > 0)
		return -EINVAL;
	code->code = MEDIA_BUS_FMT_UYVY8_1X16;
	return 0;
}

static int openvin_csi2_get_fmt(struct v4l2_subdev *sd,
				struct v4l2_subdev_pad_config *cfg,
				struct v4l2_subdev_format *fmt)
{
	struct openvin_csi2 *priv = sd_to_openvin(sd);

	mutex_lock(&priv->lock);
	fmt->format = *openvin_get_pad_fmt(priv, cfg, fmt->pad, fmt->which);
	mutex_unlock(&priv->lock);
	return 0;
}

static int openvin_csi2_set_fmt(struct v4l2_subdev *sd,
				struct v4l2_subdev_pad_config *cfg,
				struct v4l2_subdev_format *fmt)
{
	struct openvin_csi2 *priv = sd_to_openvin(sd);
	struct v4l2_mbus_framefmt *format;

	/*
	 * The receiver is format-transparent: it forwards whatever the fixed
	 * HDMI->MIPI bridge emits (digital YUV422-8). Only the frame size is
	 * negotiable; geometry enforcement is the capture driver's job.
	 */
	mutex_lock(&priv->lock);
	format = openvin_get_pad_fmt(priv, cfg, fmt->pad, fmt->which);
	format->code = MEDIA_BUS_FMT_UYVY8_1X16;
	format->width = clamp_t(u32, fmt->format.width, 64, 4096);
	format->height = clamp_t(u32, fmt->format.height, 64, 2160);
	format->field = V4L2_FIELD_NONE;
	format->colorspace = V4L2_COLORSPACE_SRGB;
	fmt->format = *format;
	mutex_unlock(&priv->lock);
	return 0;
}

static const struct v4l2_subdev_core_ops openvin_csi2_core_ops = {
	.log_status = openvin_csi2_log_status,
};

static const struct v4l2_subdev_video_ops openvin_csi2_video_ops = {
	.s_stream = openvin_csi2_s_stream,
};

static const struct v4l2_subdev_pad_ops openvin_csi2_pad_ops = {
	.enum_mbus_code = openvin_csi2_enum_mbus_code,
	.get_fmt = openvin_csi2_get_fmt,
	.set_fmt = openvin_csi2_set_fmt,
};

static const struct v4l2_subdev_ops openvin_csi2_subdev_ops = {
	.core = &openvin_csi2_core_ops,
	.video = &openvin_csi2_video_ops,
	.pad = &openvin_csi2_pad_ops,
};

/* --------------------------------------------------------------------------
 * Controls: read-only volatile health telemetry (M1 milestone checks).
 */
static int openvin_csi2_g_volatile_ctrl(struct v4l2_ctrl *ctrl)
{
	struct openvin_csi2 *priv =
		container_of(ctrl->handler, struct openvin_csi2, ctrls);
	unsigned long flags;

	switch (ctrl->id) {
	case OPENVIN_CID_LINK_LOCKED:
		ctrl->val = openvin_link_locked(priv);
		return 0;
	case OPENVIN_CID_ERR0_EVENTS:
		spin_lock_irqsave(&priv->err_lock, flags);
		*ctrl->p_new.p_s64 = priv->err0_events;
		spin_unlock_irqrestore(&priv->err_lock, flags);
		return 0;
	case OPENVIN_CID_ERR1_EVENTS:
		spin_lock_irqsave(&priv->err_lock, flags);
		*ctrl->p_new.p_s64 = priv->err1_events;
		spin_unlock_irqrestore(&priv->err_lock, flags);
		return 0;
	}
	return -EINVAL;
}

static const struct v4l2_ctrl_ops openvin_csi2_ctrl_ops = {
	.g_volatile_ctrl = openvin_csi2_g_volatile_ctrl,
};

static const struct v4l2_ctrl_config openvin_csi2_ctrl_cfgs[] = {
	{
		.ops = &openvin_csi2_ctrl_ops,
		.id = OPENVIN_CID_LINK_LOCKED,
		.name = "CSI-2 Link Locked",
		.type = V4L2_CTRL_TYPE_BOOLEAN,
		.min = 0,
		.max = 1,
		.step = 1,
		.def = 0,
		.flags = V4L2_CTRL_FLAG_READ_ONLY | V4L2_CTRL_FLAG_VOLATILE,
	}, {
		.ops = &openvin_csi2_ctrl_ops,
		.id = OPENVIN_CID_ERR0_EVENTS,
		.name = "CSI-2 Error Events",
		.type = V4L2_CTRL_TYPE_INTEGER64,
		.min = 0,
		.max = S64_MAX,
		.step = 1,
		.def = 0,
		.flags = V4L2_CTRL_FLAG_READ_ONLY | V4L2_CTRL_FLAG_VOLATILE,
	}, {
		.ops = &openvin_csi2_ctrl_ops,
		.id = OPENVIN_CID_ERR1_EVENTS,
		.name = "D-PHY ErrSotHS Events",
		.type = V4L2_CTRL_TYPE_INTEGER64,
		.min = 0,
		.max = S64_MAX,
		.step = 1,
		.def = 0,
		.flags = V4L2_CTRL_FLAG_READ_ONLY | V4L2_CTRL_FLAG_VOLATILE,
	},
};

/* --------------------------------------------------------------------------
 * Probe / remove
 */

static int openvin_csi2_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct openvin_csi2 *priv;
	struct resource *res;
	void __iomem *csi_bank;
	unsigned int i;
	int ret;

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;
	priv->dev = dev;
	priv->standalone = standalone;
	mutex_init(&priv->lock);
	spin_lock_init(&priv->err_lock);

	/* CSI-2 protocol controller bank from the DT node's reg (both devs;
	 * this driver uses dev0 at +0x0000). */
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	csi_bank = devm_ioremap_resource(dev, res);
	if (IS_ERR(csi_bank))
		return PTR_ERR(csi_bank);
	priv->csi = csi_bank;	/* dev0; dev1 would be csi_bank + CSI_DEV_STRIDE */

	/*
	 * Global blocks. The axera,mipi DT node carries no reg/clocks/resets
	 * for these (the in-tree clk/reset providers own the same physical
	 * ranges via their own syscon nodes), so they are mapped by fixed
	 * physical address, SET/CLR access only.
	 * TODO(mainline): describe these as syscon phandles (isp_sys_glb is
	 * the existing isp_clk/isp_reset syscon at 0x2500000, common_glb the
	 * common_clk syscon at 0x2340000) and add a proper reg entry for the
	 * D-PHY file at 0x23f0000.
	 */
	priv->isp_glb = devm_ioremap(dev, ISP_SYS_GLB_PHYS, ISP_SYS_GLB_SIZE);
	priv->dphy_glb = devm_ioremap(dev, DPHY_GLB_PHYS, DPHY_GLB_SIZE);
	priv->common_glb = devm_ioremap(dev, COMMON_GLB_PHYS, COMMON_GLB_SIZE);
	if (!priv->isp_glb || !priv->dphy_glb || !priv->common_glb)
		return -ENOMEM;

	/* Error IRQ for controller 0 (GIC 31, "csictrl0"). Controller 1 is
	 * unused on this board; its "csictrl1" line is left unclaimed. */
	priv->irq = platform_get_irq_byname(pdev, "csictrl0");
	if (priv->irq < 0)
		return priv->irq;
	ret = devm_request_irq(dev, priv->irq, openvin_csi2_irq, 0,
			       OPENVIN_CSI2_NAME, priv);
	if (ret)
		return ret;
	/* Enabled only while streaming (balanced in s_stream). */
	disable_irq(priv->irq);

	/* Default active format: 1080p from the HDMI bridge. */
	priv->fmt.code = MEDIA_BUS_FMT_UYVY8_1X16;
	priv->fmt.width = 1920;
	priv->fmt.height = 1080;
	priv->fmt.field = V4L2_FIELD_NONE;
	priv->fmt.colorspace = V4L2_COLORSPACE_SRGB;

	v4l2_subdev_init(&priv->sd, &openvin_csi2_subdev_ops);
	priv->sd.owner = THIS_MODULE;
	priv->sd.dev = dev;
	priv->sd.flags |= V4L2_SUBDEV_FL_HAS_DEVNODE;
	snprintf(priv->sd.name, sizeof(priv->sd.name), OPENVIN_CSI2_NAME);
	v4l2_set_subdevdata(&priv->sd, priv);

	priv->sd.entity.function = MEDIA_ENT_F_VID_IF_BRIDGE;
	priv->pads[OPENVIN_PAD_SINK].flags = MEDIA_PAD_FL_SINK;
	priv->pads[OPENVIN_PAD_SOURCE].flags = MEDIA_PAD_FL_SOURCE;
	ret = media_entity_pads_init(&priv->sd.entity, OPENVIN_NUM_PADS,
				     priv->pads);
	if (ret)
		return ret;

	v4l2_ctrl_handler_init(&priv->ctrls,
			       ARRAY_SIZE(openvin_csi2_ctrl_cfgs));
	for (i = 0; i < ARRAY_SIZE(openvin_csi2_ctrl_cfgs); i++)
		v4l2_ctrl_new_custom(&priv->ctrls,
				     &openvin_csi2_ctrl_cfgs[i], NULL);
	if (priv->ctrls.error) {
		ret = priv->ctrls.error;
		goto err_entity;
	}
	priv->sd.ctrl_handler = &priv->ctrls;

	if (priv->standalone) {
		/*
		 * M1 bring-up mode: own a private v4l2_device so the subdev
		 * node exists without the M2 capture bridge. The M2 driver
		 * will instead take this subdev over v4l2-async
		 * (standalone=0).
		 */
		ret = v4l2_device_register(dev, &priv->v4l2_dev);
		if (ret)
			goto err_ctrls;
		ret = v4l2_device_register_subdev(&priv->v4l2_dev, &priv->sd);
		if (ret)
			goto err_v4l2_dev;
		ret = v4l2_device_register_subdev_nodes(&priv->v4l2_dev);
		if (ret)
			goto err_v4l2_dev;
	} else {
		ret = v4l2_async_register_subdev(&priv->sd);
		if (ret)
			goto err_ctrls;
	}

	platform_set_drvdata(pdev, priv);

	dev_info(dev,
		 "AX630C CSI-2 RX subdev (dev0 @%pa, %u lanes, combo mode %u)%s\n",
		 &res->start, OPENVIN_LANE_NUM, OPENVIN_COMBO_MODE,
		 priv->standalone ? ", standalone" : "");

	if (start_on_probe) {
		ret = openvin_csi2_s_stream(&priv->sd, 1);
		if (ret)
			dev_warn(dev, "start_on_probe failed: %d\n", ret);
	}

	return 0;

err_v4l2_dev:
	v4l2_device_unregister(&priv->v4l2_dev);
err_ctrls:
	v4l2_ctrl_handler_free(&priv->ctrls);
err_entity:
	media_entity_cleanup(&priv->sd.entity);
	return ret;
}

static int openvin_csi2_remove(struct platform_device *pdev)
{
	struct openvin_csi2 *priv = platform_get_drvdata(pdev);

	openvin_csi2_s_stream(&priv->sd, 0);

	if (priv->standalone) {
		v4l2_device_unregister_subdev(&priv->sd);
		v4l2_device_unregister(&priv->v4l2_dev);
	} else {
		v4l2_async_unregister_subdev(&priv->sd);
	}
	v4l2_ctrl_handler_free(&priv->ctrls);
	media_entity_cleanup(&priv->sd.entity);

	return 0;
}

static const struct of_device_id openvin_csi2_of_match[] = {
	{ .compatible = "axera,mipi" },
	{ /* sentinel */ },
};
MODULE_DEVICE_TABLE(of, openvin_csi2_of_match);

static struct platform_driver openvin_csi2_driver = {
	.probe = openvin_csi2_probe,
	.remove = openvin_csi2_remove,
	.driver = {
		.name = OPENVIN_CSI2_NAME,
		.of_match_table = openvin_csi2_of_match,
	},
};
module_platform_driver(openvin_csi2_driver);

MODULE_AUTHOR("open-nanokvm-pro contributors");
MODULE_DESCRIPTION("Open V4L2 CSI-2 receiver subdev for AX630C (ax_mipi_rx replacement, #57)");
MODULE_LICENSE("GPL v2");
