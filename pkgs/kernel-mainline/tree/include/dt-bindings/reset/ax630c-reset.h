/* SPDX-License-Identifier: (GPL-2.0 OR MIT) */
/*
 * Reset IDs for the Axera AX630C (AX620E family).
 *
 * Transcribed from docs/reference/mainline/reset-model-20260906.md section 6
 * (issue #80), which derived them from 445 (consumer, reset-name) bindings in
 * the vendor GPL device tree and deduplicated them to 144 distinct lines. The
 * four AX630C_RST_PERIPH_WDT* lines are not in that count: SW_RST3 has no
 * vendor DT consumer, and they come from wdt-model-20260906.md section 7.
 *
 * Each controller keeps its own ID namespace, exactly as
 * dt-bindings/clock/ax630c-clock.h does -- the same numeric cell means a
 * different line under a different phandle. The reset lines live in the same
 * syscon windows as the clocks and are handed out by the same DT nodes, which
 * carry both #clock-cells and #reset-cells.
 *
 * Names are the vendor consumer's node label plus its reset-name with the
 * trailing _RST/_RESET stripped. That is the only human-readable
 * identification these bits have; do not read a functional meaning into them
 * beyond it. In particular the vendor DT and the vendor U-Boot disagree about
 * which of the two GZIPD bits is the "core" one.
 *
 * The isp window (0x2500000) is absent: it has no clock node, no reset
 * consumer anywhere in the vendor tree, and no driver has ever implemented it.
 */

#ifndef _DT_BINDINGS_RESET_AX630C_H
#define _DT_BINDINGS_RESET_AX630C_H

/* cpu clock-controller@1900000 -- SW_RST0, value word 0x10 */
#define AX630C_RST_CPU_EMMC_CARD                       0
#define AX630C_RST_CPU_EMMC                            1
#define AX630C_RST_CPU_SPI4_PRST                       2
#define AX630C_RST_CPU_SPI4                            3
#define AX630C_RST_CPU_NR                              4

/* comm clock-controller@2340000 -- SW_RST_0, value word 0x54 */
#define AX630C_RST_COMM_AUDIO_CODEC_PRST               0
#define AX630C_RST_COMM_BT_DPI0_CM_DPU_1X              1
#define AX630C_RST_COMM_BT_DPI0_CM_DPU_NX              2
#define AX630C_RST_COMM_BT_DPI1_CM_DPU_1X              3
#define AX630C_RST_COMM_BT_DPI1_CM_DPU_NX              4
#define AX630C_RST_COMM_NR                             5

/* vpu clock-controller@4030000 -- value word 0x0c */
#define AX630C_RST_VPU_JENC                            0
#define AX630C_RST_VPU_VDEC                            1
#define AX630C_RST_VPU_VENC                            2
#define AX630C_RST_VPU_NR                              3

/* mm clock-controller@4430000 -- value word 0x10 */
#define AX630C_RST_MM_VPP_RST8                         0
#define AX630C_RST_MM_VPP_RST9                         1
#define AX630C_RST_MM_VO1_MM_DPU_OUT                   2
#define AX630C_RST_MM_VO1_MM_DPU_PRST                  3
#define AX630C_RST_MM_VO1_MM_DPU                       4
#define AX630C_RST_MM_VO0_MM_DPU_OUT                   5
#define AX630C_RST_MM_VO0_MM_DPU_PRST                  6
#define AX630C_RST_MM_VO0_MM_DPU                       7
#define AX630C_RST_MM_GDC_RST0                         8
#define AX630C_RST_MM_GDC_RST1                         9
#define AX630C_RST_MM_GDC_RST2                         10
#define AX630C_RST_MM_IVE_PRST                         11
#define AX630C_RST_MM_IVE                              12
#define AX630C_RST_MM_TDP_RST0                         13
#define AX630C_RST_MM_TDP_RST1                         14
#define AX630C_RST_MM_VPP_RST0                         15
#define AX630C_RST_MM_VPP_RST1                         16
#define AX630C_RST_MM_VPP_RST2                         17
#define AX630C_RST_MM_VPP_RST3                         18
#define AX630C_RST_MM_VPP_RST4                         19
#define AX630C_RST_MM_VPP_RST5                         20
#define AX630C_RST_MM_VPP_RST6                         21
#define AX630C_RST_MM_VPP_RST7                         22
#define AX630C_RST_MM_NR                               23

/* dispc clock-controller@4600000 -- value word 0x0c */
#define AX630C_RST_DISPC_DSI_DISPC_DPHY2DSI            0
#define AX630C_RST_DISPC_LVDSTX_DPHYTX_PLL_DIV7        1
#define AX630C_RST_DISPC_LVDSTX_DPHYTX_PLL             2
#define AX630C_RST_DISPC_DSI_DISPC_DPHYTX              3
#define AX630C_RST_DISPC_DSI_DISPC_DSI_RX_ESC          4
#define AX630C_RST_DISPC_DSI_DISPC_SYS                 5
#define AX630C_RST_DISPC_DSI_DISPC_TXESC               6
#define AX630C_RST_DISPC_DSI_DISPC_TXPIX               7
#define AX630C_RST_DISPC_DSI_DISPC_DSI_PRST            8
#define AX630C_RST_DISPC_LVDSTX_LVDS_P                 9
#define AX630C_RST_DISPC_NR                            10

/* periph clock-controller@4870000 -- SW_RST0..3, value words 0x18..0x24 */
#define AX630C_RST_PERIPH_AUDIO_CODEC                  0
#define AX630C_RST_PERIPH_DMA_PER_DMAPER_ARST          1
#define AX630C_RST_PERIPH_DMA_PER_DMAPER_PRST          2
#define AX630C_RST_PERIPH_PUB_CE_MAIN_SW               3
#define AX630C_RST_PERIPH_PUB_CE_CNT_SW                4
#define AX630C_RST_PERIPH_PUB_CE_SOFT_SW               5
#define AX630C_RST_PERIPH_PUB_CE_SW                    6
#define AX630C_RST_PERIPH_PUB_CE_SW_PRST               7
#define AX630C_RST_PERIPH_DMAC                         8
#define AX630C_RST_PERIPH_AX_GPIO0_GPIO_PRST           9
#define AX630C_RST_PERIPH_AX_GPIO0_GPIO                10
#define AX630C_RST_PERIPH_AX_GPIO1_GPIO_PRST           11
#define AX630C_RST_PERIPH_AX_GPIO1_GPIO                12
#define AX630C_RST_PERIPH_AX_GPIO2_GPIO_PRST           13
#define AX630C_RST_PERIPH_AX_GPIO2_GPIO                14
#define AX630C_RST_PERIPH_AX_GPIO3_GPIO_PRST           15
#define AX630C_RST_PERIPH_AX_GPIO3_GPIO                16
#define AX630C_RST_PERIPH_I2C0_PRST                    17
#define AX630C_RST_PERIPH_I2C0                         18
#define AX630C_RST_PERIPH_I2C1_PRST                    19
#define AX630C_RST_PERIPH_I2C1                         20
#define AX630C_RST_PERIPH_I2C2_PRST                    21
#define AX630C_RST_PERIPH_I2C2                         22
#define AX630C_RST_PERIPH_I2C3_PRST                    23
#define AX630C_RST_PERIPH_I2C3                         24
#define AX630C_RST_PERIPH_I2C4_PRST                    25
#define AX630C_RST_PERIPH_I2C4                         26
#define AX630C_RST_PERIPH_I2C5_PRST                    27
#define AX630C_RST_PERIPH_I2C5                         28
#define AX630C_RST_PERIPH_I2C6_PRST                    29
#define AX630C_RST_PERIPH_I2C6                         30
#define AX630C_RST_PERIPH_I2C7_PRST                    31
#define AX630C_RST_PERIPH_I2C7                         32
#define AX630C_RST_PERIPH_I2C_SLV0_PRST                33
#define AX630C_RST_PERIPH_I2C_SLV0                     34
#define AX630C_RST_PERIPH_I2C_SLV1_PRST                35
#define AX630C_RST_PERIPH_I2C_SLV1                     36
#define AX630C_RST_PERIPH_I2S_MST0_PRST                37
#define AX630C_RST_PERIPH_I2S_MST0                     38
#define AX630C_RST_PERIPH_I2S_SLV0_PRST                39
#define AX630C_RST_PERIPH_I2S_SLV0                     40
#define AX630C_RST_PERIPH_I2S_TDM_MST0_PRST            41
#define AX630C_RST_PERIPH_I2S_TDM_MST0                 42
#define AX630C_RST_PERIPH_I2S_TDM_SLV0_PRST            43
#define AX630C_RST_PERIPH_I2S_TDM_SLV0                 44
#define AX630C_RST_PERIPH_PWM0_PWM_CH0                 45
#define AX630C_RST_PERIPH_PWM0_PWM_CH1                 46
#define AX630C_RST_PERIPH_PWM0_PWM_CH2                 47
#define AX630C_RST_PERIPH_PWM0_PWM_CH3                 48
#define AX630C_RST_PERIPH_PWM0_PWM                     49
#define AX630C_RST_PERIPH_PWM1_PWM_CH0                 50
#define AX630C_RST_PERIPH_PWM1_PWM_CH1                 51
#define AX630C_RST_PERIPH_PWM1_PWM_CH2                 52
#define AX630C_RST_PERIPH_PWM1_PWM_CH3                 53
#define AX630C_RST_PERIPH_PWM1_PWM                     54
#define AX630C_RST_PERIPH_PWM2_PWM_CH0                 55
#define AX630C_RST_PERIPH_PWM2_PWM_CH1                 56
#define AX630C_RST_PERIPH_PWM2_PWM_CH2                 57
#define AX630C_RST_PERIPH_PWM2_PWM_CH3                 58
#define AX630C_RST_PERIPH_PWM2_PWM                     59
#define AX630C_RST_PERIPH_SPI0_PRST                    60
#define AX630C_RST_PERIPH_SPI0                         61
#define AX630C_RST_PERIPH_SPI1_PRST                    62
#define AX630C_RST_PERIPH_SPI1                         63
#define AX630C_RST_PERIPH_SPI2_PRST                    64
#define AX630C_RST_PERIPH_SPI2                         65
#define AX630C_RST_PERIPH_AX_HRTIMER_PRESET            66
#define AX630C_RST_PERIPH_AX_HRTIMER                   67
#define AX630C_RST_PERIPH_APB_TIMER1_PRESET            68
#define AX630C_RST_PERIPH_APB_TIMER1                   69
#define AX630C_RST_PERIPH_AX_UART0_PRESET              70
#define AX630C_RST_PERIPH_AX_UART0                     71
#define AX630C_RST_PERIPH_AX_UART1_PRESET              72
#define AX630C_RST_PERIPH_AX_UART1                     73
#define AX630C_RST_PERIPH_AX_UART2_PRESET              74
#define AX630C_RST_PERIPH_AX_UART2                     75
#define AX630C_RST_PERIPH_AX_UART3_PRESET              76
#define AX630C_RST_PERIPH_AX_UART3                     77
#define AX630C_RST_PERIPH_AX_UART4_PRESET              78
#define AX630C_RST_PERIPH_AX_UART4                     79
#define AX630C_RST_PERIPH_AX_UART5_PRESET              80
#define AX630C_RST_PERIPH_AX_UART5                     81
#define AX630C_RST_PERIPH_WDT0_PRST                    82
#define AX630C_RST_PERIPH_WDT0_ARST                    83
#define AX630C_RST_PERIPH_WDT2_PRST                    84
#define AX630C_RST_PERIPH_WDT2_ARST                    85
#define AX630C_RST_PERIPH_NR                           86

/* flash clock-controller@10030000 -- SW_RST0/1, value words 0x14, 0x20 */
#define AX630C_RST_FLASH_DMA_ARST                      0
#define AX630C_RST_FLASH_DMA_PRST                      1
#define AX630C_RST_FLASH_ETH0_EMAC                     2
#define AX630C_RST_FLASH_ETH0_EPHY                     3
#define AX630C_RST_FLASH_GZIPD                         4
#define AX630C_RST_FLASH_GZIPD_CORE                    5
#define AX630C_RST_FLASH_SD_CARDRST                    6
#define AX630C_RST_FLASH_SD_ARST                       7
#define AX630C_RST_FLASH_SD_PRST                       8
#define AX630C_RST_FLASH_SDIO_CARDRST                  9
#define AX630C_RST_FLASH_SDIO_ARST                     10
#define AX630C_RST_FLASH_SDIO_PRST                     11
#define AX630C_RST_FLASH_SPI_SLV_HRST                  12
#define AX630C_RST_FLASH_SPI_SLV                       13
#define AX630C_RST_FLASH_BT_DPI0_FLASH_DPU_1X          14
#define AX630C_RST_FLASH_BT_DPI0_FLASH_DPU_NX          15
#define AX630C_RST_FLASH_ETH0_EPHY_SHUTDOWN            16
#define AX630C_RST_FLASH_NR                            17

#endif /* _DT_BINDINGS_RESET_AX630C_H */
