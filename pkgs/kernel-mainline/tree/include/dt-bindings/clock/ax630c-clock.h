/* SPDX-License-Identifier: (GPL-2.0 OR MIT) */
/*
 * Clock IDs for the Axera AX630C (AX620E family).
 *
 * Transcribed from docs/reference/mainline/clk-model-20260906.md (issue #80).
 *
 * Each controller keeps its own ID namespace -- the same numeric cell means a
 * different clock under a different phandle -- and the numbering is the
 * vendor's, deliberately: it is dense, already carved per controller, and
 * encodes a register/bit ordering worth preserving.
 *
 * 284 IDs of the 493 the vendor header declared, of which the driver registers
 * 282 -- the two SD/SDIO card muxes are named but deliberately left
 * unregistered, see the flash block below. 246 of the 282 are the set the
 * vendor CCF driver itself registered; the other 36 are IDs it declared and
 * never registered, because its own eMMC, SD, SDIO, watchdog, I2C, GPIO and
 * dwc3 drivers programmed those windows by hand. The rest are listed in
 * section 1.2 of the
 * specification and can be added as their register positions are confirmed. The isp and ddr namespaces are gone entirely --
 * neither ever had an implementation -- as are AX620X_CPUPLL (common ID 2,
 * deliberately never registered) and the seven dead PLL cells.
 */

#ifndef _DT_BINDINGS_CLOCK_AX630C_H
#define _DT_BINDINGS_CLOCK_AX630C_H

/* pllc clk -- axera,ax630c-pllc-clk */
#define AX630C_PLL_CPUPLL			1

/*
 * cpu clk -- axera,ax630c-cpu-clk
 *
 * The four EMMC ids are #76's, not #80's: the vendor CCF driver declares them
 * and registers none, because its own mmc driver programmed this window by
 * hand. Mainline sdhci-cadence calls clk_get(), so they have to exist.
 */
#define AX630C_CLK_H_SSI_SEL			0
#define AX630C_CLK_EMMC_CARD_SEL		1
#define AX630C_CLK_CPU_SEL			2
#define AX630C_CLK_BUS_FLASH_SEL		3
#define AX630C_CLK_H_SSI_EB			4
#define AX630C_CLK_EMMC_CARD_EB			5
#define AX630C_CLK_CPU_24M_EB			6
#define AX630C_CLK_EMMC_EB			14
#define AX630C_CLK_CS_APB_EB			15
#define AX630C_CLK_H_SSI_DIVN			19
#define AX630C_CLK_EMMC_CARD_DIVN		20

/* common clk -- axera,ax630c-common-clk */
#define AX630C_REF24M				0
#define AX630C_CPLL				1
#define AX630C_HPLL				3
#define AX630C_NPLL				4
#define AX630C_VPLL0				5
#define AX630C_VPLL1				6
#define AX630C_EPLL				7
#define AX630C_DPLL				8
#define AX630C_CPLL_2496M			9
#define AX630C_CPLL_1248M			10
#define AX630C_CPLL_12M				11
#define AX630C_CPLL_624M			12
#define AX630C_CPLL_416M			13
#define AX630C_CPLL_249P6M			14
#define AX630C_CPLL_312M			15
#define AX630C_CPLL_208M			16
#define AX630C_CPLL_19P2M			17
#define AX630C_CPLL_156M			18
#define AX630C_CPLL_24M				19
#define AX630C_CPLL_78M				20
#define AX630C_CPLL_39M				21
#define AX630C_CPLL_26M				22
#define AX630C_HPLL_1228P8M			23
#define AX630C_HPLL_245P76M			24
#define AX630C_HPLL_49P152M			25
#define AX630C_HPLL_81P92M			26
#define AX630C_HPLL_24P576M			27
#define AX630C_HPLL_16P384M			28
#define AX630C_HPLL_40P96M			29
#define AX630C_HPLL_12P288M			30
#define AX630C_HPLL_20P48M			31
#define AX630C_HPLL_4096K			32
#define AX630C_NPLL_1600M			33
#define AX630C_NPLL_800M			34
#define AX630C_NPLL_400M			35
#define AX630C_NPLL_200M			36
#define AX630C_NPLL_100M			37
#define AX630C_NPLL_50M				38
#define AX630C_NPLL_25M				39
#define AX630C_NPLL_533M			40
#define AX630C_VPLL0_1188M			41
#define AX630C_VPLL0_108M			42
#define AX630C_VPLL0_594M			43
#define AX630C_VPLL0_198M			44
#define AX630C_VPLL0_118P8M			45
#define AX630C_VPLL0_297M			46
#define AX630C_VPLL0_148P5M			47
#define AX630C_VPLL0_27M			48
#define AX630C_VPLL0_74P25M			49
#define AX630C_VPLL0_37P125M			50
#define AX630C_VPLL1_1188M			51
#define AX630C_VPLL1_108M			52
#define AX630C_VPLL1_594M			53
#define AX630C_VPLL1_198M			54
#define AX630C_VPLL1_118P8M			55
#define AX630C_VPLL1_297M			56
#define AX630C_VPLL1_148M			57
#define AX630C_VPLL1_27M			58
#define AX630C_VPLL1_74P25M			59
#define AX630C_VPLL1_37P125M			60
#define AX630C_EPLL_1500M			61
#define AX630C_EPLL_500M			62
#define AX630C_EPLL_750M			63
#define AX630C_EPLL_250M			64
#define AX630C_EPLL_375M			65
#define AX630C_EPLL_100M			66
#define AX630C_EPLL_125M			67
#define AX630C_EPLL_20M				68
#define AX630C_EPLL_50M				69
#define AX630C_EPLL_62P5M			70
#define AX630C_EPLL_10M				71
#define AX630C_EPLL_25M				72
#define AX630C_EPLL_31P25M			73
#define AX630C_EPLL_5M				74
#define AX630C_DPLL_3200M			75
#define AX630C_DPLL_1600M			76
#define AX630C_DPLL_800M			77
#define AX630C_DPLL_400M			78
#define AX630C_DPLL_200M			79
#define AX630C_DPLL_100M			80
#define AX630C_DPLL_50M				81
#define AX630C_DPLL_25M				82
#define AX630C_CPUPLL_1200M			83
#define AX630C_CPUPLL_600M			84
#define AX630C_CPUPLL_300M			85
#define AX630C_CPUPLL_150M			86
#define AX630C_CPUPLL_75M			87
#define AX630C_CPUPLL_25M			88
#define AX630C_ACLK_ISP_TOP_SEL			89
#define AX630C_ACLK_CPU_TOP_SEL			90
#define AX630C_MCLK5_SEL			91
#define AX630C_MCLK4_SEL			92
#define AX630C_MCLK3_SEL			93
#define AX630C_MCLK2_SEL			94
#define AX630C_MCLK1_SEL			95
#define AX630C_MCLK0_SEL			96
#define AX630C_CLK_VI_SEL			98
#define AX630C_CLK_NX_VO1_COMM_SEL		102
#define AX630C_CLK_NX_VO0_COMM_SEL		103
#define AX630C_CLK_ISP_MM_SEL			104
#define AX630C_CLK_DBC_GPIO_SEL			105
#define AX630C_CLK_1X_VO1_COMM_SEL		106
#define AX630C_CLK_1X_VO0_COMM_SEL		107
#define AX630C_ACLK_VPU_TOP_SEL			108
#define AX630C_ACLK_OCM_TOP_SEL			109
#define AX630C_ACLK_NN_TOP_SEL			110
#define AX630C_ACLK_MM_TOP_SEL			111
#define AX630C_PCLK_TOP_SEL			112
#define AX630C_CLK_VI_EB			114
#define AX630C_CLK_TMR_SYNC_EB			115
#define AX630C_CLK_NX_VO1_COMM_EB		118
#define AX630C_CLK_NX_VO0_COMM_EB		119
#define AX630C_CLK_ISP_MM_EB			120
#define AX630C_CLK_DPHYTX_TLB_EB		121
#define AX630C_CLK_DPHYRX_TLB_EB		122
#define AX630C_CLK_AUDIO_TLB_EB			123
#define AX630C_CLK_1X_VO1_COMM_EB		124
#define AX630C_CLK_1X_VO0_COMM_EB		125
#define AX630C_MCLK5_EB				126
#define AX630C_MCLK4_EB				127
#define AX630C_MCLK3_EB				128
#define AX630C_MCLK2_EB				129
#define AX630C_MCLK1_EB				130
#define AX630C_MCLK0_EB				131
#define AX630C_MCLK5_DIVN			151
#define AX630C_MCLK4_DIVN			152
#define AX630C_MCLK3_DIVN			153
#define AX630C_MCLK2_DIVN			154
#define AX630C_MCLK1_DIVN			155
#define AX630C_MCLK0_DIVN			156
#define AX630C_CLK_NX_VO1_DIVN			157
#define AX630C_CLK_NX_VO0_DIVN			158
#define AX630C_CLK_1X_VO1_DIVN			159
#define AX630C_CLK_1X_VO0_DIVN			160
#define AX630C_CLK_RTC_OUT_32K			161

/* dispc clk -- axera,ax630c-dispc-clk */
#define AX630C_CLK_DPHY_TX_ESC_SEL		0
#define AX630C_CLK_DISPC_GLB_SEL		1
#define AX630C_CLK_DPHY_TX_REF_EB		2
#define AX630C_CLK_DPHY_TX_ESC_EB		3
#define AX630C_PCLK_LVDS_TX_EB			4
#define AX630C_PCLK_DSI_EB			5
#define AX630C_PCLK_CSI_EB			6
#define AX630C_CLK_DSI_TX_ESC_EB		7
#define AX630C_CLK_DSI_SYS_EB			8
#define AX630C_CLK_DPHY_TX_PLL_DIV7_CG_EB	9
#define AX630C_CLK_DPHY_TX_PLL_CG_EB		10
#define AX630C_CLK_DPHY2DSI_HS_EB		11
#define AX630C_CLK_DPHY2CSI_HS_EB		12
#define AX630C_CLK_CSI_TX_ESC_EB		13

/*
 * flash clk -- axera,ax630c-flash-clk
 *
 * The SD/SDIO ids (2, 3, 15, 16, 27, 28, 41, 42, 46, 51) and the pinmux APB
 * gate (29) are #76's, for the same reason as the cpu EMMC ids above. The
 * three USB ids (11, 13, 40) are #82's, for the same reason again: the vendor
 * CCF declares them and registers none, because the vendor dwc3 glue pokes
 * this window's gates directly instead of taking clock handles.
 */
#define AX630C_RGMII_EPHY_CLK_SEL		0
#define AX630C_CLK_SDIO_M_CARD_SEL		2
#define AX630C_CLK_SD_CARD_SEL			3
#define AX630C_CLK_NX_VO1_SEL			4
#define AX630C_CLK_NX_VO0_SEL			5
#define AX630C_CLK_FLASH_GLB_SEL		7
#define AX630C_CLK_EMAC_RGMII_TX_SEL		8
#define AX630C_CLK_1X_VO1_SEL			9
#define AX630C_CLK_1X_VO0_SEL			10
#define AX630C_USB_REF_ALT_CLK_EB		11
#define AX630C_EPHY_CLK_EB			12
#define AX630C_CLK_USB_REF_EB			13
#define AX630C_CLK_SDIO_M_CARD_EB		15
#define AX630C_CLK_SD_CARD_EB			16
#define AX630C_CLK_NX_VO1_EB			17
#define AX630C_CLK_NX_VO0_EB			18
#define AX630C_CLK_EMAC_RMII_PHY_EB		21
#define AX630C_CLK_EMAC_RGMII_TX_EB		22
#define AX630C_CLK_EMAC_PTP_REF_EB		23
#define AX630C_CLK_1X_VO1_EB			24
#define AX630C_CLK_1X_VO0_EB			25
#define AX630C_PCLK_SDIO_M_EB			27
#define AX630C_PCLK_SD_M_EB			28
#define AX630C_PCLK_PINMUX_EB			29
#define AX630C_CLK_LPC_FLASH_EB			34
#define AX630C_BUS_CLK_USB_EB			40
#define AX630C_ACLK_SDIO_M_EB			41
#define AX630C_ACLK_SD_M_EB			42
#define AX630C_ACLK_EMAC_EB			43
#define AX630C_CLK_SD_CARD_DIVN			46
#define AX630C_CLK_NX_VO1_DIVN_FLASH		47
#define AX630C_CLK_NX_VO0_DIVN_FLASH		48
#define AX630C_CLK_1X_VO1_DIVN_FLASH		49
#define AX630C_CLK_1X_VO0_DIVN_FLASH		50
#define AX630C_CLK_SDIO_M_CARD_DIVN		51

/* mm clk -- axera,ax630c-mm-clk */
#define AX630C_CLK_VPP_SRC_SEL			0
#define AX630C_CLK_TDP_SRC_SEL			1
#define AX630C_CLK_MM_GLB_SEL			2
#define AX630C_CLK_IVE_SRC_SEL			3
#define AX630C_CLK_GDC_SRC_SEL			4
#define AX630C_CLK_DPU_SRC_SEL			5
#define AX630C_CLK_DPU_OUT_SEL			6
#define AX630C_CLK_DPU_LITE_SRC_SEL		7
#define AX630C_CLK_DPU_LITE_OUT_SEL		8
#define AX630C_CLK_CSI_ASYNC_SEL		9
#define AX630C_CLK_AXI2CSI_SRC_SEL		10
#define AX630C_CLK_DPU_OUT_EB			12
#define AX630C_CLK_DPU_LITE_OUT_EB		13
#define AX630C_CLK_CSI_ASYNC_EB			14
#define AX630C_PCLK_VPP_EB			15
#define AX630C_PCLK_TDP_EB			16
#define AX630C_PCLK_IVE_EB			17
#define AX630C_PCLK_GDC_EB			18
#define AX630C_PCLK_DPU_LITE_EB			19
#define AX630C_PCLK_DPU_EB			20
#define AX630C_PCLK_CMD_EB			21
#define AX630C_PCLK_AXI2CSI_EB			22
#define AX630C_CLK_VPP_SCL4_EB			23
#define AX630C_CLK_VPP_SCL3_EB			24
#define AX630C_CLK_VPP_SCL2_EB			25
#define AX630C_CLK_VPP_SCL1_EB			26
#define AX630C_CLK_VPP_SCL0_EB			27
#define AX630C_CLK_VPP_EB			28
#define AX630C_CLK_TDP_EB			29
#define AX630C_CLK_LPC_MM_EB			30
#define AX630C_CLK_IVE_EB			31
#define AX630C_CLK_GDC_EB			32
#define AX630C_CLK_FBCD_EB			33
#define AX630C_CLK_FBC_EB			34
#define AX630C_CLK_DPU_LITE_EB			35
#define AX630C_CLK_DPU_EB			36
#define AX630C_CLK_CMD_EB			37
#define AX630C_CLK_AXI2CSI_EB			40
#define AX630C_CLK_DPU_OUT_DIVN			41
#define AX630C_CLK_DPU_LITE_OUT_DIVN		42

/*
 * periph clk -- axera,ax630c-periph-clk
 *
 * The six WDT ids are #75's, not #80's, and like the EMMC ids above they are
 * declared but never registered by the vendor CCF driver -- its watchdog
 * programmed the gates, the resets and the source mux itself, through a second
 * mapping of this window.
 */
#define AX630C_SCLK_I2S_TDM_SEL			0
#define AX630C_SCLK_I2S_M_SEL			1
#define AX630C_CLK_WDT2_SEL			2
#define AX630C_CLK_WDT0_SEL			3
#define AX630C_CLK_TIMER_SEL			8
#define AX630C_CLK_I2S_REF0_SEL			12
/*
 * The I2C and GPIO ids below are #81's. Like the WDT ones they are declared by
 * the vendor binding header and never registered by its CCF driver -- its I2C
 * and GPIO drivers each mapped this window a second time and programmed their
 * own source mux, block gate and per-instance gates by hand.
 */
#define AX630C_CLK_I2C_SEL			13
#define AX630C_CLK_GPIO_SEL			14
#define AX630C_SCLK_I2S_TDM_EB			16
#define AX630C_SCLK_I2S_M_EB			17
#define AX630C_CLK_WDT2_EB			18
#define AX630C_CLK_WDT0_EB			19
#define AX630C_CLK_TIMER_EB			24
#define AX630C_CLK_I2S_REF0_EB			29
#define AX630C_CLK_I2S_AUDIO_REF_EB		30
#define AX630C_CLK_I2C_EB			31
#define AX630C_CLK_GPIO_EB			32
#define AX630C_CLK_TIMER0_EB			34
#define AX630C_CLK_LPC_PERI_EB			47
#define AX630C_CLK_I2C_MST0_EB			57
#define AX630C_CLK_GPIO3_EB			58
#define AX630C_CLK_GPIO2_EB			59
#define AX630C_CLK_GPIO1_EB			60
#define AX630C_CLK_GPIO0_EB			61
#define AX630C_ACLK_AX_DMA_PER_EB		65
#define AX630C_PCLK_I2S_TDM_S_EB		67
#define AX630C_PCLK_I2S_TDM_M_EB		68
#define AX630C_PCLK_I2S_S_EB			69
#define AX630C_PCLK_I2S_M_EB			70
#define AX630C_PCLK_I2C_MST0_EB			80
#define AX630C_PCLK_GPIO3_EB			81
#define AX630C_PCLK_GPIO2_EB			82
#define AX630C_PCLK_GPIO1_EB			83
#define AX630C_PCLK_GPIO0_EB			84
#define AX630C_PCLK_AX_DMA_PER_EB		86
#define AX630C_PCLK_WDT2_EB			98
#define AX630C_PCLK_WDT0_EB			99
#define AX630C_PCLK_TIMER0_EB			113
#define AX630C_SCLK_I2S_TDM_DIVN		119
#define AX630C_SCLK_I2S_M_DIVN			120
#define AX630C_CLK_I2S_REF0_DIVN		121

/* vpu clk -- axera,ax630c-vpu-clk */
#define AX630C_CLK_VPU_GLB_SEL			0
#define AX630C_CLK_VDEC_SRC_SEL			1
#define AX630C_CLK_JENC_SRC_SEL			2
#define AX630C_CLK_VENC_EB			4
#define AX630C_CLK_VDEC_EB			5
#define AX630C_CLK_LPC_VPU_EB			6
#define AX630C_CLK_JENC_EB			7

#endif /* _DT_BINDINGS_CLOCK_AX630C_H */
