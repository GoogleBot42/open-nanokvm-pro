// SPDX-License-Identifier: GPL-2.0
/*
 * Axera AX630C (AX620E family) pin controller -- pad, group and function
 * tables.
 *
 * Transcribed from docs/reference/mainline/pinctrl-model-20260906.md: the pad
 * table of its section 2, the 56 collapsed functions of section 3.3, and the
 * per-pad notes of section 2.1. Every value here comes from that document; it
 * is the specification, not this file, that is the source of truth.
 *
 * 111 pads x 8 mux values = 888 slots, of which 551 are populated and 337 are
 * reserved. EMMC_RESET_N is the only pad whose slot 0 is reserved.
 *
 * Copyright (c) 2026 the open-nanokvm-pro contributors.
 */

#include <linux/array_size.h>
#include <linux/pinctrl/pinctrl.h>

#include "pinctrl-ax630c.h"

/*
 * Function indices. The order of this enum is the order of
 * ax630c_functions[] below -- the array is built with designated
 * initialisers so the two cannot drift -- and it is what ax630c_pad.mux[]
 * stores.
 */
enum ax630c_function {
	AX630C_FUNC_GPIO,
	AX630C_FUNC_DB_GPIO,
	AX630C_FUNC_VI,
	AX630C_FUNC_SENSOR_SYNC,
	AX630C_FUNC_PWM,
	AX630C_FUNC_DPI,
	AX630C_FUNC_RGMII,
	AX630C_FUNC_DEBUG_BUS,
	AX630C_FUNC_ANALOG_TEST,
	AX630C_FUNC_SPI_M2,
	AX630C_FUNC_DPHY_RX,
	AX630C_FUNC_CLK_AUX,
	AX630C_FUNC_EMMC,
	AX630C_FUNC_DPHY_TX,
	AX630C_FUNC_INFRARED,
	AX630C_FUNC_BT656,
	AX630C_FUNC_MCLK,
	AX630C_FUNC_SPI_M1,
	AX630C_FUNC_SPI_M0,
	AX630C_FUNC_SFC,
	AX630C_FUNC_SPI_S,
	AX630C_FUNC_SPI2AHB,
	AX630C_FUNC_SDIO,
	AX630C_FUNC_SD,
	AX630C_FUNC_I2S1,
	AX630C_FUNC_I2S0,
	AX630C_FUNC_RISC_JTAG,
	AX630C_FUNC_EPHY,
	AX630C_FUNC_UART5,
	AX630C_FUNC_UART4,
	AX630C_FUNC_UART3,
	AX630C_FUNC_UART2,
	AX630C_FUNC_UART1,
	AX630C_FUNC_UART0,
	AX630C_FUNC_TIMESTAMP,
	AX630C_FUNC_THERMAL_AIN,
	AX630C_FUNC_SYSCTL,
	AX630C_FUNC_RESERVED_ANALOG,
	AX630C_FUNC_EMAC_PPS,
	AX630C_FUNC_SD_CTRL,
	AX630C_FUNC_BOND,
	AX630C_FUNC_USB,
	AX630C_FUNC_LCD_TE,
	AX630C_FUNC_JTAG,
	AX630C_FUNC_I2C_SLV1,
	AX630C_FUNC_I2C_SLV0,
	AX630C_FUNC_I2C7,
	AX630C_FUNC_I2C6,
	AX630C_FUNC_I2C5,
	AX630C_FUNC_I2C4,
	AX630C_FUNC_I2C3,
	AX630C_FUNC_I2C2,
	AX630C_FUNC_I2C1,
	AX630C_FUNC_I2C0,
	AX630C_FUNC_DMIC,
	AX630C_FUNC_EMMC_PWR_EN,
};

const struct pinctrl_pin_desc ax630c_pin_descs[AX630C_NUM_PADS] = {
	PINCTRL_PIN(0, "VI_D0"),
	PINCTRL_PIN(1, "VI_D1"),
	PINCTRL_PIN(2, "VI_D2"),
	PINCTRL_PIN(3, "VI_D3"),
	PINCTRL_PIN(4, "VI_D4"),
	PINCTRL_PIN(5, "VI_D5"),
	PINCTRL_PIN(6, "VI_D6"),
	PINCTRL_PIN(7, "VI_D7"),
	PINCTRL_PIN(8, "VI_D8"),
	PINCTRL_PIN(9, "VI_D9"),
	PINCTRL_PIN(10, "VI_CLK0"),
	PINCTRL_PIN(11, "I2C0_SCL"),
	PINCTRL_PIN(12, "I2C0_SDA"),
	PINCTRL_PIN(13, "I2C1_SCL"),
	PINCTRL_PIN(14, "I2C1_SDA"),
	PINCTRL_PIN(15, "UART0_TXD"),
	PINCTRL_PIN(16, "UART0_RXD"),
	PINCTRL_PIN(17, "UART1_TXD"),
	PINCTRL_PIN(18, "UART1_RXD"),
	PINCTRL_PIN(19, "UART2_TXD"),
	PINCTRL_PIN(20, "UART2_RXD"),
	PINCTRL_PIN(21, "UART3_TXD"),
	PINCTRL_PIN(22, "UART3_RXD"),
	PINCTRL_PIN(23, "EMAC_PTP_PPS0"),
	PINCTRL_PIN(24, "EMAC_PTP_PPS1"),
	PINCTRL_PIN(25, "EMAC_PTP_PPS2"),
	PINCTRL_PIN(26, "EMAC_PTP_PPS3"),
	PINCTRL_PIN(27, "RGMII_MDCK"),
	PINCTRL_PIN(28, "RGMII_MDIO"),
	PINCTRL_PIN(29, "EPHY_CLK"),
	PINCTRL_PIN(30, "EPHY_RSTN"),
	PINCTRL_PIN(31, "EPHY_LED0"),
	PINCTRL_PIN(32, "EPHY_LED1"),
	PINCTRL_PIN(33, "RGMII_RXD0"),
	PINCTRL_PIN(34, "RGMII_RXD1"),
	PINCTRL_PIN(35, "RGMII_RXDV"),
	PINCTRL_PIN(36, "RGMII_RXCLK"),
	PINCTRL_PIN(37, "RGMII_RXD2"),
	PINCTRL_PIN(38, "RGMII_RXD3"),
	PINCTRL_PIN(39, "RGMII_TXD0"),
	PINCTRL_PIN(40, "RGMII_TXD1"),
	PINCTRL_PIN(41, "RGMII_TXCLK"),
	PINCTRL_PIN(42, "RGMII_TXEN"),
	PINCTRL_PIN(43, "RGMII_TXD2"),
	PINCTRL_PIN(44, "RGMII_TXD3"),
	PINCTRL_PIN(45, "SD_DAT0"),
	PINCTRL_PIN(46, "SD_DAT1"),
	PINCTRL_PIN(47, "SD_CLK"),
	PINCTRL_PIN(48, "SD_CMD"),
	PINCTRL_PIN(49, "SD_DAT2"),
	PINCTRL_PIN(50, "SD_DAT3"),
	PINCTRL_PIN(51, "EMMC_DAT5"),
	PINCTRL_PIN(52, "EMMC_RESET_N"),
	PINCTRL_PIN(53, "EMMC_DAT4"),
	PINCTRL_PIN(54, "EMMC_DAT6"),
	PINCTRL_PIN(55, "EMMC_DS"),
	PINCTRL_PIN(56, "EMMC_DAT7"),
	PINCTRL_PIN(57, "EMMC_DAT3"),
	PINCTRL_PIN(58, "EMMC_DAT2"),
	PINCTRL_PIN(59, "EMMC_CLK"),
	PINCTRL_PIN(60, "EMMC_DAT0"),
	PINCTRL_PIN(61, "EMMC_CMD"),
	PINCTRL_PIN(62, "EMMC_DAT1"),
	PINCTRL_PIN(63, "SDIO_DAT0"),
	PINCTRL_PIN(64, "SDIO_DAT1"),
	PINCTRL_PIN(65, "SDIO_CLK"),
	PINCTRL_PIN(66, "SDIO_CMD"),
	PINCTRL_PIN(67, "SDIO_DAT2"),
	PINCTRL_PIN(68, "SDIO_DAT3"),
	PINCTRL_PIN(69, "CDTX_L0N"),
	PINCTRL_PIN(70, "CDTX_L0P"),
	PINCTRL_PIN(71, "CDTX_L1N"),
	PINCTRL_PIN(72, "CDTX_L1P"),
	PINCTRL_PIN(73, "CDTX_L2N"),
	PINCTRL_PIN(74, "CDTX_L2P"),
	PINCTRL_PIN(75, "CDTX_L3N"),
	PINCTRL_PIN(76, "CDTX_L3P"),
	PINCTRL_PIN(77, "CDTX_L4N"),
	PINCTRL_PIN(78, "CDTX_L4P"),
	PINCTRL_PIN(79, "THM_AIN3"),
	PINCTRL_PIN(80, "THM_AIN2"),
	PINCTRL_PIN(81, "THM_AIN1"),
	PINCTRL_PIN(82, "THM_AIN0"),
	PINCTRL_PIN(83, "SD_PWR_SW"),
	PINCTRL_PIN(84, "GPIO3_A1"),
	PINCTRL_PIN(85, "GPIO3_A2"),
	PINCTRL_PIN(86, "GPIO3_A3"),
	PINCTRL_PIN(87, "BOND0"),
	PINCTRL_PIN(88, "BOND1"),
	PINCTRL_PIN(89, "EMMC_PWR_EN"),
	PINCTRL_PIN(90, "BOND2"),
	PINCTRL_PIN(91, "SYS_RSTN_OUT"),
	PINCTRL_PIN(92, "TMS"),
	PINCTRL_PIN(93, "TCK"),
	PINCTRL_PIN(94, "SD_PWR_EN"),
	PINCTRL_PIN(95, "MICP_L_D"),
	PINCTRL_PIN(96, "MICN_L_D"),
	PINCTRL_PIN(97, "MICN_R_D"),
	PINCTRL_PIN(98, "MICP_R_D"),
	PINCTRL_PIN(99, "CDRX_L0N"),
	PINCTRL_PIN(100, "CDRX_L0P"),
	PINCTRL_PIN(101, "CDRX_L1N"),
	PINCTRL_PIN(102, "CDRX_L1P"),
	PINCTRL_PIN(103, "CDRX_L2N"),
	PINCTRL_PIN(104, "CDRX_L2P"),
	PINCTRL_PIN(105, "CDRX_L3N"),
	PINCTRL_PIN(106, "CDRX_L3P"),
	PINCTRL_PIN(107, "CDRX_L4N"),
	PINCTRL_PIN(108, "CDRX_L4P"),
	PINCTRL_PIN(109, "CDRX_L5N"),
	PINCTRL_PIN(110, "CDRX_L5P"),
};

/*
 * Offsets are LOCAL to the pad's window: window 0 is the 0x02300000 block,
 * window 1 the 0x104F0000 block. The specification's section 2 lists one
 * offset per pad in the vendor's single logical space, which splits at
 * SECOND_OFFSET = 0x0E1F0000; a window-1 offset here is that value minus
 * SECOND_OFFSET, so the driver can index base[window] + offset directly.
 *
 * GPIO is mux value 6 on 94 pads, 0 on the three GPIO bank 3 pads, and
 * absent on 14 (section 2.1) -- every gpio_mux below is read out of the
 * pad's own function list, never defaulted.
 *
 * pull_enc is AX630C_PULL_ENSEL for the analog-capable groups G2, G5 and G7
 * and AX630C_PULL_ONEHOT everywhere else (section 1.4).
 *
 * UNRESOLVED (specification section 1.4 and section 9 item 2): the vendor's
 * own board pinmux table writes one-hot pull values into G7 -- 0x0230500C
 * (MICP_L_D) gets bit 7 set with bit 6 clear, which under the EN/SE reading
 * is no pull at all. Either the table generator is encoding-blind or the
 * EN/SE reading is wrong for G7. The specification says to follow the driver
 * (EN/SE for G2, G5, G7) and measure the pad on hardware before trusting
 * either reading, so that is what these four G7 rows do. Do not change them
 * without a measurement.
 */
const struct ax630c_pad ax630c_pads[AX630C_NUM_PADS] = {
	[0] = { /* VI_D0 */
		.window = 0, .offset = 0xc,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_D0 */
			[1] = AX630C_FUNC_INFRARED,		/* INFRARED_FS */
			[2] = AX630C_FUNC_SPI_M1,		/* SPI_M1_MOSI */
			[3] = AX630C_FUNC_I2C6,			/* I2C6_SDA */
			[4] = AX630C_FUNC_I2S0,			/* I2S0_DIN0 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO0 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A0 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST1 */
		},
	},
	[1] = { /* VI_D1 */
		.window = 0, .offset = 0x18,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_D1 */
			[1] = AX630C_FUNC_INFRARED,		/* INFRARED_SDO0 */
			[2] = AX630C_FUNC_SPI_M1,		/* SPI_M1_MISO */
			[3] = AX630C_FUNC_I2C6,			/* I2C6_SCL */
			[4] = AX630C_FUNC_I2S0,			/* I2S0_SCLK */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO1 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A1 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST2 */
		},
	},
	[2] = { /* VI_D2 */
		.window = 0, .offset = 0x24,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_D2 */
			[1] = AX630C_FUNC_INFRARED,		/* INFRARED_SDO1 */
			[2] = AX630C_FUNC_SPI_M1,		/* SPI_M1_CS0 */
			[3] = AX630C_FUNC_SYSCTL,		/* TIME_50HZ */
			[4] = AX630C_FUNC_I2S0,			/* I2S0_DOUT */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO2 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A2 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST3 */
		},
	},
	[3] = { /* VI_D3 */
		.window = 0, .offset = 0x30,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_D3 */
			[1] = AX630C_FUNC_INFRARED,		/* INFRARED_SDO2 */
			[2] = AX630C_FUNC_SPI_M1,		/* SPI_M1_CS1 */
			[3] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX1_1 */
			[4] = AX630C_FUNC_I2S0,			/* I2S0_MCLK */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO3 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A3 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST4 */
		},
	},
	[4] = { /* VI_D4 */
		.window = 0, .offset = 0x3c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_D4 */
			[1] = AX630C_FUNC_INFRARED,		/* INFRARED_CLK_M */
			[2] = AX630C_FUNC_SPI_M1,		/* SPI_M1_SCLK */
			[3] = AX630C_FUNC_I2C5,			/* I2C5_SDA */
			[4] = AX630C_FUNC_I2S0,			/* I2S0_DIN1 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO4 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A4 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST5 */
		},
	},
	[5] = { /* VI_D5 */
		.window = 0, .offset = 0x48,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_D5 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_SPI_S,		/* SPI_S_D3 */
			[3] = AX630C_FUNC_I2C_SLV0,		/* I2C_S0_SDA */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO5 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A5 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[6] = { /* VI_D6 */
		.window = 0, .offset = 0x54,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_D6 */
			[1] = AX630C_FUNC_INFRARED,		/* INFRARED_SDI0 */
			[2] = AX630C_FUNC_SPI_S,		/* SPI_S_D1 */
			[3] = AX630C_FUNC_I2C_SLV0,		/* I2C_S0_SCL */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO6 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A6 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[7] = { /* VI_D7 */
		.window = 0, .offset = 0x60,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_D7 */
			[1] = AX630C_FUNC_INFRARED,		/* INFRARED_SDI1 */
			[2] = AX630C_FUNC_SPI_S,		/* SPI_S_D0 */
			[3] = AX630C_FUNC_SPI_M1,		/* SPI_M1_CS2 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO7 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A7 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[8] = { /* VI_D8 */
		.window = 0, .offset = 0x6c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_D8 */
			[1] = AX630C_FUNC_INFRARED,		/* INFRARED_SDI2 */
			[2] = AX630C_FUNC_SPI_S,		/* SPI_S_CS */
			[3] = AX630C_FUNC_I2C7,			/* I2C7_SCL */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO8 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A8 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[9] = { /* VI_D9 */
		.window = 0, .offset = 0x78,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_D9 */
			[1] = AX630C_FUNC_INFRARED,		/* INFRARED_SDI3 */
			[2] = AX630C_FUNC_SPI_S,		/* SPI_S_D2 */
			[3] = AX630C_FUNC_I2C7,			/* I2C7_SDA */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO9 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A9 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[10] = { /* VI_CLK0 */
		.window = 0, .offset = 0x84,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_VI,			/* VI_CLK0 */
			[1] = AX630C_FUNC_SPI_M1,		/* SPI_M1_CS3 */
			[2] = AX630C_FUNC_SPI_S,		/* SPI_S_SCLK */
			[3] = AX630C_FUNC_I2C5,			/* I2C5_SCL */
			[4] = AX630C_FUNC_I2S0,			/* I2S0_LRCK */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO10 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A10 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST0 */
		},
	},
	[11] = { /* I2C0_SCL */
		.window = 0, .offset = 0x400c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_I2C0,			/* I2C0_SCL */
			[1] = AX630C_FUNC_SPI_M2,		/* SPI_M2_CS1 */
			[2] = AX630C_FUNC_RISC_JTAG,		/* RISC_TCK */
			[3] = AX630C_FUNC_PWM,			/* PWM00 */
			[4] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX0_0 */
			[5] = AX630C_FUNC_UART2,		/* UART2_CTS */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A24 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST12 */
		},
	},
	[12] = { /* I2C0_SDA */
		.window = 0, .offset = 0x4018,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_I2C0,			/* I2C0_SDA */
			[1] = AX630C_FUNC_SPI_M2,		/* SPI_M2_CS2 */
			[2] = AX630C_FUNC_RISC_JTAG,		/* RISC_TRSTN */
			[3] = AX630C_FUNC_PWM,			/* PWM01 */
			[4] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX0_1 */
			[5] = AX630C_FUNC_UART2,		/* UART2_RTS */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A25 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST13 */
		},
	},
	[13] = { /* I2C1_SCL */
		.window = 0, .offset = 0x4024,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_I2C1,			/* I2C1_SCL */
			[1] = AX630C_FUNC_SPI_M2,		/* SPI_M2_SCLK */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_PWM,			/* PWM02 */
			[4] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX0_2 */
			[5] = AX630C_FUNC_UART4,		/* UART4_CTS */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A26 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[14] = { /* I2C1_SDA */
		.window = 0, .offset = 0x4030,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_I2C1,			/* I2C1_SDA */
			[1] = AX630C_FUNC_SPI_M2,		/* SPI_M2_CS0 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_PWM,			/* PWM03 */
			[4] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX1_0 */
			[5] = AX630C_FUNC_UART4,		/* UART4_RTS */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A27 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[15] = { /* UART0_TXD */
		.window = 0, .offset = 0x403c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_UART0,		/* UART0_TXD */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_RISC_JTAG,		/* RISC_TDI */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO24 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A28 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST6 */
		},
	},
	[16] = { /* UART0_RXD */
		.window = 0, .offset = 0x4048,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_UART0,		/* UART0_RXD */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_RISC_JTAG,		/* RISC_TMS */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO25 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A29 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST7 */
		},
	},
	[17] = { /* UART1_TXD */
		.window = 0, .offset = 0x4054,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_UART1,		/* UART1_TXD */
			[1] = AX630C_FUNC_SPI_M2,		/* SPI_M2_CS3 */
			[2] = AX630C_FUNC_RISC_JTAG,		/* RISC_TDO */
			[3] = AX630C_FUNC_PWM,			/* PWM06 */
			[4] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D1 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO26 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A30 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST8 */
		},
	},
	[18] = { /* UART1_RXD */
		.window = 0, .offset = 0x4060,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_UART1,		/* UART1_RXD */
			[1] = AX630C_FUNC_MCLK,			/* MCLK7 */
			[2] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX3_0 */
			[3] = AX630C_FUNC_PWM,			/* PWM07 */
			[4] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D2 */
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A31 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST9 */
		},
	},
	[19] = { /* UART2_TXD */
		.window = 0, .offset = 0x406c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_UART2,		/* UART2_TXD */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX3_1 */
			[3] = AX630C_FUNC_TIMESTAMP,		/* TIMESTAMP_LOCK_I1 */
			[4] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D3 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO27 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A0 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST10 */
		},
	},
	[20] = { /* UART2_RXD */
		.window = 0, .offset = 0x4078,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_UART2,		/* UART2_RXD */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX3_2 */
			[3] = AX630C_FUNC_TIMESTAMP,		/* TIMESTAMP_LOCK_O1 */
			[4] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_ELEC_PLS */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO28 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A1 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST11 */
		},
	},
	[21] = { /* UART3_TXD */
		.window = 0, .offset = 0x4084,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_UART3,		/* UART3_TXD */
			[1] = AX630C_FUNC_SPI_M2,		/* SPI_M2_MOSI */
			[2] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX2_1 */
			[3] = AX630C_FUNC_PWM,			/* PWM04 */
			[4] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D4 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO29 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A2 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[22] = { /* UART3_RXD */
		.window = 0, .offset = 0x4090,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_UART3,		/* UART3_RXD */
			[1] = AX630C_FUNC_SPI_M2,		/* SPI_M2_MISO */
			[2] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX2_2 */
			[3] = AX630C_FUNC_PWM,			/* PWM05 */
			[4] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D0 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO30 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A3 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[23] = { /* EMAC_PTP_PPS0 */
		.window = 1, .offset = 0xc,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMAC_PPS,		/* EMAC_PTP_PPS0 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D17 */
			[2] = AX630C_FUNC_PWM,			/* PWM0_M */
			[3] = AX630C_FUNC_UART5,		/* UART5_CTS */
			[4] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D5 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO35 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A8 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[24] = { /* EMAC_PTP_PPS1 */
		.window = 1, .offset = 0x18,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMAC_PPS,		/* EMAC_PTP_PPS1 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D16 */
			[2] = AX630C_FUNC_PWM,			/* PWM1_M */
			[3] = AX630C_FUNC_UART5,		/* UART5_RTS */
			[4] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_VSYNC_D0 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO36 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A9 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[25] = { /* EMAC_PTP_PPS2 */
		.window = 1, .offset = 0x24,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMAC_PPS,		/* EMAC_PTP_PPS2 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D18 */
			[2] = AX630C_FUNC_SD_CTRL,		/* SD_CARD_DETECT_N */
			[3] = AX630C_FUNC_UART5,		/* UART5_TXD */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO37 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A10 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[26] = { /* EMAC_PTP_PPS3 */
		.window = 1, .offset = 0x30,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMAC_PPS,		/* EMAC_PTP_PPS3 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D15 */
			[2] = AX630C_FUNC_PWM,			/* PWM2_M */
			[3] = AX630C_FUNC_UART5,		/* UART5_RXD */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO38 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A11 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[27] = { /* RGMII_MDCK */
		.window = 1, .offset = 0x3c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_MDCK */
			[1] = AX630C_FUNC_DPI,			/* DPI_D1 */
			[2] = AX630C_FUNC_PWM,			/* PWM5_M */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D1_M */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO51 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A24 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[28] = { /* RGMII_MDIO */
		.window = 1, .offset = 0x48,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_MDIO */
			[1] = AX630C_FUNC_DPI,			/* DPI_D2 */
			[2] = AX630C_FUNC_PWM,			/* PWM6_M */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D2_M */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO52 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A25 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[29] = { /* EPHY_CLK */
		.window = 1, .offset = 0x54,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EPHY,			/* EPHY_CLK */
			[1] = AX630C_FUNC_DPI,			/* DPI_PCLK */
			[2] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX1_2 */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D3_M */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO53 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A26 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[30] = { /* EPHY_RSTN */
		.window = 1, .offset = 0x60,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EPHY,			/* EPHY_RSTN */
			[1] = AX630C_FUNC_DPI,			/* DPI_D0 */
			[2] = AX630C_FUNC_PWM,			/* PWM7_M */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D4_M */
			[4] = AX630C_FUNC_SPI_M2,		/* SPI_M2_CS0_M */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO54 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A27 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[31] = { /* EPHY_LED0 */
		.window = 1, .offset = 0x6c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EPHY,			/* EPHY_LED0 */
			[1] = AX630C_FUNC_RGMII,		/* RGMII_MDCK_M */
			[2] = AX630C_FUNC_LCD_TE,		/* TE0 */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D5_M */
			[4] = AX630C_FUNC_SPI_M2,		/* SPI_M2_CS3_M */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO55 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A28 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[32] = { /* EPHY_LED1 */
		.window = 1, .offset = 0x78,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EPHY,			/* EPHY_LED1 */
			[1] = AX630C_FUNC_RGMII,		/* RGMII_MDIO_M */
			[2] = AX630C_FUNC_LCD_TE,		/* TE1 */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_ELEC_PLS_M */
			[4] = AX630C_FUNC_SPI_M2,		/* SPI_M2_CS2_M */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO56 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A29 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[33] = { /* RGMII_RXD0 */
		.window = 1, .offset = 0x84,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_RXD0 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D5 */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS6 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_FUNC_UART0,		/* UART0_CTS */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO39 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A12 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[34] = { /* RGMII_RXD1 */
		.window = 1, .offset = 0x90,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_RXD1 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D6 */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS7 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_FUNC_UART0,		/* UART0_RTS */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO40 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A13 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[35] = { /* RGMII_RXDV */
		.window = 1, .offset = 0x9c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_RXDV */
			[1] = AX630C_FUNC_DPI,			/* DPI_D4 */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS8 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO41 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A14 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[36] = { /* RGMII_RXCLK */
		.window = 1, .offset = 0xa8,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_RXCLK */
			[1] = AX630C_FUNC_DPI,			/* DPI_D3 */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS9 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO42 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A15 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[37] = { /* RGMII_RXD2 */
		.window = 1, .offset = 0xb4,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_RXD2 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D7 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO43 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A16 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[38] = { /* RGMII_RXD3 */
		.window = 1, .offset = 0xc0,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_RXD3 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D8 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO44 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A17 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[39] = { /* RGMII_TXD0 */
		.window = 1, .offset = 0xcc,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_TXD0 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D11 */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS2 */
			[3] = AX630C_FUNC_MCLK,			/* MCLK1 */
			[4] = AX630C_FUNC_SPI_M2,		/* SPI_M2_MOSI_M */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO45 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A18 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[40] = { /* RGMII_TXD1 */
		.window = 1, .offset = 0xd8,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_TXD1 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D12 */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS3 */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_HSYNC_D0_M */
			[4] = AX630C_FUNC_SPI_M2,		/* SPI_M2_MISO_M */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO46 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A19 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[41] = { /* RGMII_TXCLK */
		.window = 1, .offset = 0xe4,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_TXCLK */
			[1] = AX630C_FUNC_DPI,			/* DPI_D9 */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS4 */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_HSYNC_D1_M */
			[4] = AX630C_FUNC_SPI_M2,		/* SPI_M2_SCLK_M */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO47 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A20 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[42] = { /* RGMII_TXEN */
		.window = 1, .offset = 0xf0,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_TXEN */
			[1] = AX630C_FUNC_DPI,			/* DPI_D10 */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS5 */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_VSYNC_D0_M */
			[4] = AX630C_FUNC_SPI_M2,		/* SPI_M2_CS1_M */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO48 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A21 */
			[7] = AX630C_FUNC_ANALOG_TEST,		/* ANALOG_TEST14 */
		},
	},
	[43] = { /* RGMII_TXD2 */
		.window = 1, .offset = 0xfc,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_TXD2 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D13 */
			[2] = AX630C_FUNC_PWM,			/* PWM3_M */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_VSYNC_D1_M */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO49 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A22 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[44] = { /* RGMII_TXD3 */
		.window = 1, .offset = 0x108,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RGMII,		/* RGMII_TXD3 */
			[1] = AX630C_FUNC_DPI,			/* DPI_D14 */
			[2] = AX630C_FUNC_PWM,			/* PWM4_M */
			[3] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_FLASH_D0_M */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO50 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A23 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[45] = { /* SD_DAT0 */
		.window = 1, .offset = 0x100c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SD,			/* SD_DAT0 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS10 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_FUNC_MCLK,			/* MCLK2 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO63 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A4 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[46] = { /* SD_DAT1 */
		.window = 1, .offset = 0x1018,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SD,			/* SD_DAT1 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS11 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_FUNC_MCLK,			/* MCLK3 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO64 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A5 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[47] = { /* SD_CLK */
		.window = 1, .offset = 0x1024,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SD,			/* SD_CLK */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS12 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO65 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A6 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[48] = { /* SD_CMD */
		.window = 1, .offset = 0x1030,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SD,			/* SD_CMD */
			[1] = AX630C_FUNC_I2C_SLV1,		/* I2C_S1_SDA */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS13 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO66 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A7 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[49] = { /* SD_DAT2 */
		.window = 1, .offset = 0x103c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SD,			/* SD_DAT2 */
			[1] = AX630C_FUNC_I2C_SLV1,		/* I2C_S1_SCL */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS14 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_FUNC_MCLK,			/* MCLK4 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO67 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A8 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[50] = { /* SD_DAT3 */
		.window = 1, .offset = 0x1048,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SD,			/* SD_DAT3 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS15 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_FUNC_MCLK,			/* MCLK5 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO68 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A9 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[51] = { /* EMMC_DAT5 */
		.window = 0, .offset = 0x900c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_DAT5 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO83 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A24 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[52] = { /* EMMC_RESET_N */
		.window = 0, .offset = 0x9018,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_MUX_RESERVED,
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO82 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A23 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[53] = { /* EMMC_DAT4 */
		.window = 0, .offset = 0x9024,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_DAT4 */
			[1] = AX630C_FUNC_SFC,			/* SFC_CSN1 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO84 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A25 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[54] = { /* EMMC_DAT6 */
		.window = 0, .offset = 0x9030,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_DAT6 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO80 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A21 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[55] = { /* EMMC_DS */
		.window = 0, .offset = 0x903c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_DS */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO81 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A22 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[56] = { /* EMMC_DAT7 */
		.window = 0, .offset = 0x9048,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_DAT7 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO79 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A20 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[57] = { /* EMMC_DAT3 */
		.window = 0, .offset = 0x9054,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_DAT3 */
			[1] = AX630C_FUNC_SFC,			/* SFC_HOLD_IO3 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO85 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A26 */
			[7] = AX630C_FUNC_SPI2AHB,		/* SPI2AHB_CS */
		},
	},
	[58] = { /* EMMC_DAT2 */
		.window = 0, .offset = 0x9060,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_DAT2 */
			[1] = AX630C_FUNC_SFC,			/* SFC_WP_IO2 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO86 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A27 */
			[7] = AX630C_FUNC_SPI2AHB,		/* SPI2AHB_DATA0 */
		},
	},
	[59] = { /* EMMC_CLK */
		.window = 0, .offset = 0x906c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_CLK */
			[1] = AX630C_FUNC_SFC,			/* SFC_CLK */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO87 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A28 */
			[7] = AX630C_FUNC_SPI2AHB,		/* SPI2AHB_DATA1 */
		},
	},
	[60] = { /* EMMC_DAT0 */
		.window = 0, .offset = 0x9078,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_DAT0 */
			[1] = AX630C_FUNC_SFC,			/* SFC_MOSI_IO0 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO15 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A20 */
			[7] = AX630C_FUNC_SPI2AHB,		/* SPI2AHB_DATA2 */
		},
	},
	[61] = { /* EMMC_CMD */
		.window = 0, .offset = 0x9084,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_CMD */
			[1] = AX630C_FUNC_SFC,			/* SFC_CSN0 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO88 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A29 */
			[7] = AX630C_FUNC_SPI2AHB,		/* SPI2AHB_DATA3 */
		},
	},
	[62] = { /* EMMC_DAT1 */
		.window = 0, .offset = 0x9090,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC,			/* EMMC_DAT1 */
			[1] = AX630C_FUNC_SFC,			/* SFC_MISO_IO1 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO89 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A19 */
			[7] = AX630C_FUNC_SPI2AHB,		/* SPI2AHB_CLK */
		},
	},
	[63] = { /* SDIO_DAT0 */
		.window = 1, .offset = 0x200c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SDIO,			/* SDIO_DAT0 */
			[1] = AX630C_FUNC_I2C3,			/* I2C3_SCL */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_I2S1,			/* I2S1_DOUT */
			[4] = AX630C_FUNC_PWM,			/* PWM08 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO57 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A30 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[64] = { /* SDIO_DAT1 */
		.window = 1, .offset = 0x2018,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SDIO,			/* SDIO_DAT1 */
			[1] = AX630C_FUNC_I2C3,			/* I2C3_SDA */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_I2S1,			/* I2S1_SCLK */
			[4] = AX630C_FUNC_PWM,			/* PWM09 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO58 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A31 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[65] = { /* SDIO_CLK */
		.window = 1, .offset = 0x2024,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SDIO,			/* SDIO_CLK */
			[1] = AX630C_FUNC_EPHY,			/* EPHY_CLK_M */
			[2] = AX630C_FUNC_I2C2,			/* I2C2_SCL */
			[3] = AX630C_FUNC_I2S1,			/* I2S1_MCLK */
			[4] = AX630C_FUNC_CLK_AUX,		/* CLK_AUX2_0 */
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO59 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A0 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[66] = { /* SDIO_CMD */
		.window = 1, .offset = 0x2030,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SDIO,			/* SDIO_CMD */
			[1] = AX630C_FUNC_I2C2,			/* I2C2_SDA */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_I2S1,			/* I2S1_LRCK */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO60 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A1 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[67] = { /* SDIO_DAT2 */
		.window = 1, .offset = 0x203c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SDIO,			/* SDIO_DAT2 */
			[1] = AX630C_FUNC_I2C4,			/* I2C4_SCL */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_I2S1,			/* I2S1_DIN1 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO61 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A2 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[68] = { /* SDIO_DAT3 */
		.window = 1, .offset = 0x2048,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SDIO,			/* SDIO_DAT3 */
			[1] = AX630C_FUNC_I2C4,			/* I2C4_SDA */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_I2S1,			/* I2S1_DIN0 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO62 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A3 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[69] = { /* CDTX_L0N */
		.window = 0, .offset = 0xa00c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = true,
		.mux = {
			[0] = AX630C_FUNC_DPHY_TX,		/* CDTX_L0N */
			[1] = AX630C_FUNC_BT656,		/* BT656_CLK */
			[2] = AX630C_FUNC_SPI_M0,		/* SPI_M0_SCLK */
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO69 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A10 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[70] = { /* CDTX_L0P */
		.window = 0, .offset = 0xa018,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = true,
		.mux = {
			[0] = AX630C_FUNC_DPHY_TX,		/* CDTX_L0P */
			[1] = AX630C_FUNC_BT656,		/* BT656_D0 */
			[2] = AX630C_FUNC_SPI_M0,		/* SPI_M0_MISO */
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO70 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A11 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[71] = { /* CDTX_L1N */
		.window = 0, .offset = 0xa024,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = true,
		.mux = {
			[0] = AX630C_FUNC_DPHY_TX,		/* CDTX_L1N */
			[1] = AX630C_FUNC_BT656,		/* BT656_D1 */
			[2] = AX630C_FUNC_SPI_M0,		/* SPI_M0_CS0 */
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO71 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A12 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[72] = { /* CDTX_L1P */
		.window = 0, .offset = 0xa030,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = true,
		.mux = {
			[0] = AX630C_FUNC_DPHY_TX,		/* CDTX_L1P */
			[1] = AX630C_FUNC_BT656,		/* BT656_D2 */
			[2] = AX630C_FUNC_SPI_M0,		/* SPI_M0_CS1 */
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO72 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A13 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[73] = { /* CDTX_L2N */
		.window = 0, .offset = 0xa03c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = true,
		.mux = {
			[0] = AX630C_FUNC_DPHY_TX,		/* CDTX_L2N */
			[1] = AX630C_FUNC_BT656,		/* BT656_D3 */
			[2] = AX630C_FUNC_SPI_M0,		/* SPI_M0_CS2 */
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO73 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A14 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[74] = { /* CDTX_L2P */
		.window = 0, .offset = 0xa048,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = true,
		.mux = {
			[0] = AX630C_FUNC_DPHY_TX,		/* CDTX_L2P */
			[1] = AX630C_FUNC_BT656,		/* BT656_D4 */
			[2] = AX630C_FUNC_SPI_M0,		/* SPI_M0_MOSI */
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO74 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A15 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[75] = { /* CDTX_L3N */
		.window = 0, .offset = 0xa054,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = true,
		.mux = {
			[0] = AX630C_FUNC_DPHY_TX,		/* CDTX_L3N */
			[1] = AX630C_FUNC_BT656,		/* BT656_D5 */
			[2] = AX630C_FUNC_SPI_M0,		/* SPI_M0_CS3 */
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO75 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A16 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[76] = { /* CDTX_L3P */
		.window = 0, .offset = 0xa060,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = true,
		.mux = {
			[0] = AX630C_FUNC_DPHY_TX,		/* CDTX_L3P */
			[1] = AX630C_FUNC_BT656,		/* BT656_D6 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO76 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A17 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[77] = { /* CDTX_L4N */
		.window = 0, .offset = 0xa06c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = true,
		.mux = {
			[0] = AX630C_FUNC_DPHY_TX,		/* CDTX_L4N */
			[1] = AX630C_FUNC_BT656,		/* BT656_D7 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO77 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A18 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[78] = { /* CDTX_L4P */
		.window = 0, .offset = 0xa078,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = true,
		.mux = {
			[0] = AX630C_FUNC_DPHY_TX,		/* CDTX_L4P */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO78 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO2_A19 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[79] = { /* THM_AIN3 */
		.window = 0, .offset = 0x100c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_THERMAL_AIN,		/* THM_AIN3 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO11 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A11 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[80] = { /* THM_AIN2 */
		.window = 0, .offset = 0x1018,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_THERMAL_AIN,		/* THM_AIN2 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_MCLK,			/* MCLK6 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO12 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A12 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[81] = { /* THM_AIN1 */
		.window = 0, .offset = 0x1024,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_THERMAL_AIN,		/* THM_AIN1 */
			[1] = AX630C_FUNC_TIMESTAMP,		/* TIMESTAMP_LOCK_O0 */
			[2] = AX630C_FUNC_PWM,			/* PWM11 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO13 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A13 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[82] = { /* THM_AIN0 */
		.window = 0, .offset = 0x1030,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_THERMAL_AIN,		/* THM_AIN0 */
			[1] = AX630C_FUNC_TIMESTAMP,		/* TIMESTAMP_LOCK_I0 */
			[2] = AX630C_FUNC_PWM,			/* PWM10 */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO14 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A14 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[83] = { /* SD_PWR_SW */
		.window = 0, .offset = 0x200c,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SD_CTRL,		/* SD_PWR_SW */
			[1] = AX630C_FUNC_SYSCTL,		/* WDT_THM_RST */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO16 */
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[84] = { /* GPIO3_A1 */
		.window = 0, .offset = 0x2018,
		.gpio_mux = 0,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_GPIO,			/* GPIO3_A1 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_FUNC_SYSCTL,		/* SLEEPOUT */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO18 */
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[85] = { /* GPIO3_A2 */
		.window = 0, .offset = 0x2024,
		.gpio_mux = 0,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_GPIO,			/* GPIO3_A2 */
			[1] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_HSYNC_D0 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO19 */
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[86] = { /* GPIO3_A3 */
		.window = 0, .offset = 0x2030,
		.gpio_mux = 0,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_GPIO,			/* GPIO3_A3 */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO20 */
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[87] = { /* BOND0 */
		.window = 0, .offset = 0x2048,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_BOND,			/* BOND0 */
			[1] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_VSYNC_D1 */
			[2] = AX630C_FUNC_UART3,		/* UART3_RTS */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A15 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[88] = { /* BOND1 */
		.window = 0, .offset = 0x2054,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_BOND,			/* BOND1 */
			[1] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_HSYNC_D1 */
			[2] = AX630C_FUNC_UART3,		/* UART3_CTS */
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A16 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[89] = { /* EMMC_PWR_EN */
		.window = 0, .offset = 0x2060,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_EMMC_PWR_EN,		/* EMMC_PWR_EN */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_UART1,		/* UART1_CTS */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO17 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A17 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[90] = { /* BOND2 */
		.window = 0, .offset = 0x206c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_BOND,			/* BOND2 */
			[1] = AX630C_FUNC_MCLK,			/* MCLK0 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_UART1,		/* UART1_RTS */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A18 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[91] = { /* SYS_RSTN_OUT */
		.window = 0, .offset = 0x2078,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SYSCTL,		/* SYS_RSTN_OUT */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[92] = { /* TMS */
		.window = 0, .offset = 0x2090,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_JTAG,			/* TMS */
			[1] = AX630C_FUNC_UART4,		/* UART4_TXD */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO21 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A21 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[93] = { /* TCK */
		.window = 0, .offset = 0x209c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_JTAG,			/* TCK */
			[1] = AX630C_FUNC_UART4,		/* UART4_RXD */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO22 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A22 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[94] = { /* SD_PWR_EN */
		.window = 0, .offset = 0x20a8,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_SD_CTRL,		/* SD_PWR_EN */
			[1] = AX630C_MUX_RESERVED,
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO23 */
			[6] = AX630C_FUNC_GPIO,			/* GPIO0_A23 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[95] = { /* MICP_L_D */
		.window = 0, .offset = 0x500c,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RESERVED_ANALOG,	/* NULL__MICP_L_D */
			[1] = AX630C_FUNC_DMIC,			/* DMIC_DIN */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS0 */
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO31 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A4 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[96] = { /* MICN_L_D */
		.window = 0, .offset = 0x5018,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RESERVED_ANALOG,	/* NULL__MICN_L_D */
			[1] = AX630C_FUNC_DMIC,			/* DMIC_CLK */
			[2] = AX630C_FUNC_DEBUG_BUS,		/* DEBUG_BUS1 */
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO32 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A5 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[97] = { /* MICN_R_D */
		.window = 0, .offset = 0x5024,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RESERVED_ANALOG,	/* NULL__MICN_R_D */
			[1] = AX630C_FUNC_USB,			/* USB_OVRCUR */
			[2] = AX630C_FUNC_SENSOR_SYNC,		/* SEN_HSYNC_D1__MICN_R_D */
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO33 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A6 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[98] = { /* MICP_R_D */
		.window = 0, .offset = 0x5030,
		.gpio_mux = 6,
		.pull_enc = AX630C_PULL_ENSEL,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_RESERVED_ANALOG,	/* NULL__MICP_R_D */
			[1] = AX630C_FUNC_USB,			/* USB_POWER_EN */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_FUNC_DB_GPIO,		/* DB_GPIO34 */
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_FUNC_GPIO,			/* GPIO1_A7 */
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[99] = { /* CDRX_L0N */
		.window = 0, .offset = 0x300c,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L0N */
			[1] = AX630C_FUNC_VI,			/* VI_D10 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[100] = { /* CDRX_L0P */
		.window = 0, .offset = 0x3018,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L0P */
			[1] = AX630C_FUNC_VI,			/* VI_D11 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[101] = { /* CDRX_L1N */
		.window = 0, .offset = 0x3024,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L1N */
			[1] = AX630C_FUNC_VI,			/* VI_D12 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[102] = { /* CDRX_L1P */
		.window = 0, .offset = 0x3030,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L1P */
			[1] = AX630C_FUNC_VI,			/* VI_D13 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[103] = { /* CDRX_L2N */
		.window = 0, .offset = 0x303c,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L2N */
			[1] = AX630C_FUNC_VI,			/* VI_D14 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[104] = { /* CDRX_L2P */
		.window = 0, .offset = 0x3048,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L2P */
			[1] = AX630C_FUNC_VI,			/* VI_D15 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[105] = { /* CDRX_L3N */
		.window = 0, .offset = 0x3054,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L3N */
			[1] = AX630C_FUNC_VI,			/* VI_D16 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[106] = { /* CDRX_L3P */
		.window = 0, .offset = 0x3060,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L3P */
			[1] = AX630C_FUNC_VI,			/* VI_D17 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[107] = { /* CDRX_L4N */
		.window = 0, .offset = 0x306c,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L4N */
			[1] = AX630C_FUNC_VI,			/* VI_D18 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[108] = { /* CDRX_L4P */
		.window = 0, .offset = 0x3078,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L4P */
			[1] = AX630C_FUNC_VI,			/* VI_D19 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[109] = { /* CDRX_L5N */
		.window = 0, .offset = 0x3084,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L5N */
			[1] = AX630C_FUNC_VI,			/* VI_CLK1 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
	[110] = { /* CDRX_L5P */
		.window = 0, .offset = 0x3090,
		.gpio_mux = AX630C_NO_GPIO,
		.pull_enc = AX630C_PULL_ONEHOT,
		.dphytx = false,
		.mux = {
			[0] = AX630C_FUNC_DPHY_RX,		/* CDRX_L5P */
			[1] = AX630C_FUNC_VI,			/* VI_D20 */
			[2] = AX630C_MUX_RESERVED,
			[3] = AX630C_MUX_RESERVED,
			[4] = AX630C_MUX_RESERVED,
			[5] = AX630C_MUX_RESERVED,
			[6] = AX630C_MUX_RESERVED,
			[7] = AX630C_MUX_RESERVED,
		},
	},
};

/*
 * Groups: the 56 functions' member pads as named multi-pad groups (named
 * after the function, lower case), plus all 111 single-pad groups named
 * after the pad in upper case, which GPIO consumers and hogs need for
 * per-pad granularity (specification section 8.2). 167 groups in total.
 */
static const unsigned int vi_d0_pins[] = { 0 };
static const unsigned int vi_d1_pins[] = { 1 };
static const unsigned int vi_d2_pins[] = { 2 };
static const unsigned int vi_d3_pins[] = { 3 };
static const unsigned int vi_d4_pins[] = { 4 };
static const unsigned int vi_d5_pins[] = { 5 };
static const unsigned int vi_d6_pins[] = { 6 };
static const unsigned int vi_d7_pins[] = { 7 };
static const unsigned int vi_d8_pins[] = { 8 };
static const unsigned int vi_d9_pins[] = { 9 };
static const unsigned int vi_clk0_pins[] = { 10 };
static const unsigned int i2c0_scl_pins[] = { 11 };
static const unsigned int i2c0_sda_pins[] = { 12 };
static const unsigned int i2c1_scl_pins[] = { 13 };
static const unsigned int i2c1_sda_pins[] = { 14 };
static const unsigned int uart0_txd_pins[] = { 15 };
static const unsigned int uart0_rxd_pins[] = { 16 };
static const unsigned int uart1_txd_pins[] = { 17 };
static const unsigned int uart1_rxd_pins[] = { 18 };
static const unsigned int uart2_txd_pins[] = { 19 };
static const unsigned int uart2_rxd_pins[] = { 20 };
static const unsigned int uart3_txd_pins[] = { 21 };
static const unsigned int uart3_rxd_pins[] = { 22 };
static const unsigned int emac_ptp_pps0_pins[] = { 23 };
static const unsigned int emac_ptp_pps1_pins[] = { 24 };
static const unsigned int emac_ptp_pps2_pins[] = { 25 };
static const unsigned int emac_ptp_pps3_pins[] = { 26 };
static const unsigned int rgmii_mdck_pins[] = { 27 };
static const unsigned int rgmii_mdio_pins[] = { 28 };
static const unsigned int ephy_clk_pins[] = { 29 };
static const unsigned int ephy_rstn_pins[] = { 30 };
static const unsigned int ephy_led0_pins[] = { 31 };
static const unsigned int ephy_led1_pins[] = { 32 };
static const unsigned int rgmii_rxd0_pins[] = { 33 };
static const unsigned int rgmii_rxd1_pins[] = { 34 };
static const unsigned int rgmii_rxdv_pins[] = { 35 };
static const unsigned int rgmii_rxclk_pins[] = { 36 };
static const unsigned int rgmii_rxd2_pins[] = { 37 };
static const unsigned int rgmii_rxd3_pins[] = { 38 };
static const unsigned int rgmii_txd0_pins[] = { 39 };
static const unsigned int rgmii_txd1_pins[] = { 40 };
static const unsigned int rgmii_txclk_pins[] = { 41 };
static const unsigned int rgmii_txen_pins[] = { 42 };
static const unsigned int rgmii_txd2_pins[] = { 43 };
static const unsigned int rgmii_txd3_pins[] = { 44 };
static const unsigned int sd_dat0_pins[] = { 45 };
static const unsigned int sd_dat1_pins[] = { 46 };
static const unsigned int sd_clk_pins[] = { 47 };
static const unsigned int sd_cmd_pins[] = { 48 };
static const unsigned int sd_dat2_pins[] = { 49 };
static const unsigned int sd_dat3_pins[] = { 50 };
static const unsigned int emmc_dat5_pins[] = { 51 };
static const unsigned int emmc_reset_n_pins[] = { 52 };
static const unsigned int emmc_dat4_pins[] = { 53 };
static const unsigned int emmc_dat6_pins[] = { 54 };
static const unsigned int emmc_ds_pins[] = { 55 };
static const unsigned int emmc_dat7_pins[] = { 56 };
static const unsigned int emmc_dat3_pins[] = { 57 };
static const unsigned int emmc_dat2_pins[] = { 58 };
static const unsigned int emmc_clk_pins[] = { 59 };
static const unsigned int emmc_dat0_pins[] = { 60 };
static const unsigned int emmc_cmd_pins[] = { 61 };
static const unsigned int emmc_dat1_pins[] = { 62 };
static const unsigned int sdio_dat0_pins[] = { 63 };
static const unsigned int sdio_dat1_pins[] = { 64 };
static const unsigned int sdio_clk_pins[] = { 65 };
static const unsigned int sdio_cmd_pins[] = { 66 };
static const unsigned int sdio_dat2_pins[] = { 67 };
static const unsigned int sdio_dat3_pins[] = { 68 };
static const unsigned int cdtx_l0n_pins[] = { 69 };
static const unsigned int cdtx_l0p_pins[] = { 70 };
static const unsigned int cdtx_l1n_pins[] = { 71 };
static const unsigned int cdtx_l1p_pins[] = { 72 };
static const unsigned int cdtx_l2n_pins[] = { 73 };
static const unsigned int cdtx_l2p_pins[] = { 74 };
static const unsigned int cdtx_l3n_pins[] = { 75 };
static const unsigned int cdtx_l3p_pins[] = { 76 };
static const unsigned int cdtx_l4n_pins[] = { 77 };
static const unsigned int cdtx_l4p_pins[] = { 78 };
static const unsigned int thm_ain3_pins[] = { 79 };
static const unsigned int thm_ain2_pins[] = { 80 };
static const unsigned int thm_ain1_pins[] = { 81 };
static const unsigned int thm_ain0_pins[] = { 82 };
static const unsigned int sd_pwr_sw_pins[] = { 83 };
static const unsigned int gpio3_a1_pins[] = { 84 };
static const unsigned int gpio3_a2_pins[] = { 85 };
static const unsigned int gpio3_a3_pins[] = { 86 };
static const unsigned int bond0_pins[] = { 87 };
static const unsigned int bond1_pins[] = { 88 };
static const unsigned int emmc_pwr_en_pins[] = { 89 };
static const unsigned int bond2_pins[] = { 90 };
static const unsigned int sys_rstn_out_pins[] = { 91 };
static const unsigned int tms_pins[] = { 92 };
static const unsigned int tck_pins[] = { 93 };
static const unsigned int sd_pwr_en_pins[] = { 94 };
static const unsigned int micp_l_d_pins[] = { 95 };
static const unsigned int micn_l_d_pins[] = { 96 };
static const unsigned int micn_r_d_pins[] = { 97 };
static const unsigned int micp_r_d_pins[] = { 98 };
static const unsigned int cdrx_l0n_pins[] = { 99 };
static const unsigned int cdrx_l0p_pins[] = { 100 };
static const unsigned int cdrx_l1n_pins[] = { 101 };
static const unsigned int cdrx_l1p_pins[] = { 102 };
static const unsigned int cdrx_l2n_pins[] = { 103 };
static const unsigned int cdrx_l2p_pins[] = { 104 };
static const unsigned int cdrx_l3n_pins[] = { 105 };
static const unsigned int cdrx_l3p_pins[] = { 106 };
static const unsigned int cdrx_l4n_pins[] = { 107 };
static const unsigned int cdrx_l4p_pins[] = { 108 };
static const unsigned int cdrx_l5n_pins[] = { 109 };
static const unsigned int cdrx_l5p_pins[] = { 110 };

static const unsigned int gpio_grp_pins[] = {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
	20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36,
	37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53,
	54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70,
	71, 72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 84, 85, 86, 87, 88,
	89, 90, 92, 93, 94, 95, 96, 97, 98
};
static const unsigned int db_gpio_grp_pins[] = {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 16, 17, 19, 20, 21, 22, 23, 24,
	25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41,
	42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58,
	59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75,
	76, 77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 89, 92, 93, 94, 95, 96,
	97, 98
};
static const unsigned int vi_grp_pins[] = {
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 99, 100, 101, 102, 103, 104, 105,
	106, 107, 108, 109, 110
};
static const unsigned int sensor_sync_grp_pins[] = {
	17, 18, 19, 20, 21, 22, 23, 24, 27, 28, 29, 30, 31, 32, 40, 41, 42,
	43, 44, 85, 87, 88, 97
};
static const unsigned int pwm_grp_pins[] = {
	11, 12, 13, 14, 17, 18, 21, 22, 23, 24, 26, 27, 28, 30, 43, 44, 63,
	64, 81, 82
};
static const unsigned int dpi_grp_pins[] = {
	23, 24, 25, 26, 27, 28, 29, 30, 33, 34, 35, 36, 37, 38, 39, 40, 41,
	42, 43, 44
};
static const unsigned int rgmii_grp_pins[] = {
	27, 28, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44
};
static const unsigned int debug_bus_grp_pins[] = {
	33, 34, 35, 36, 39, 40, 41, 42, 45, 46, 47, 48, 49, 50, 95, 96
};
static const unsigned int analog_test_grp_pins[] = {
	0, 1, 2, 3, 4, 10, 11, 12, 15, 16, 17, 18, 19, 20, 42
};
static const unsigned int spi_m2_grp_pins[] = {
	11, 12, 13, 14, 17, 21, 22, 30, 31, 32, 39, 40, 41, 42
};
static const unsigned int dphy_rx_grp_pins[] = {
	99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110
};
static const unsigned int clk_aux_grp_pins[] = {
	3, 11, 12, 13, 14, 18, 19, 20, 21, 22, 29, 65
};
static const unsigned int emmc_grp_pins[] = {
	51, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62
};
static const unsigned int dphy_tx_grp_pins[] = {
	69, 70, 71, 72, 73, 74, 75, 76, 77, 78
};
static const unsigned int infrared_grp_pins[] = { 0, 1, 2, 3, 4, 6, 7, 8, 9 };
static const unsigned int bt656_grp_pins[] = {
	69, 70, 71, 72, 73, 74, 75, 76, 77
};
static const unsigned int mclk_grp_pins[] = { 18, 39, 45, 46, 49, 50, 80, 90 };
static const unsigned int spi_m1_grp_pins[] = { 0, 1, 2, 3, 4, 7, 10 };
static const unsigned int spi_m0_grp_pins[] = { 69, 70, 71, 72, 73, 74, 75 };
static const unsigned int sfc_grp_pins[] = { 53, 57, 58, 59, 60, 61, 62 };
static const unsigned int spi_s_grp_pins[] = { 5, 6, 7, 8, 9, 10 };
static const unsigned int spi2ahb_grp_pins[] = { 57, 58, 59, 60, 61, 62 };
static const unsigned int sdio_grp_pins[] = { 63, 64, 65, 66, 67, 68 };
static const unsigned int sd_grp_pins[] = { 45, 46, 47, 48, 49, 50 };
static const unsigned int i2s1_grp_pins[] = { 63, 64, 65, 66, 67, 68 };
static const unsigned int i2s0_grp_pins[] = { 0, 1, 2, 3, 4, 10 };
static const unsigned int risc_jtag_grp_pins[] = { 11, 12, 15, 16, 17 };
static const unsigned int ephy_grp_pins[] = { 29, 30, 31, 32, 65 };
static const unsigned int uart5_grp_pins[] = { 23, 24, 25, 26 };
static const unsigned int uart4_grp_pins[] = { 13, 14, 92, 93 };
static const unsigned int uart3_grp_pins[] = { 21, 22, 87, 88 };
static const unsigned int uart2_grp_pins[] = { 11, 12, 19, 20 };
static const unsigned int uart1_grp_pins[] = { 17, 18, 89, 90 };
static const unsigned int uart0_grp_pins[] = { 15, 16, 33, 34 };
static const unsigned int timestamp_grp_pins[] = { 19, 20, 81, 82 };
static const unsigned int thermal_ain_grp_pins[] = { 79, 80, 81, 82 };
static const unsigned int sysctl_grp_pins[] = { 2, 83, 84, 91 };
static const unsigned int reserved_analog_grp_pins[] = { 95, 96, 97, 98 };
static const unsigned int emac_pps_grp_pins[] = { 23, 24, 25, 26 };
static const unsigned int sd_ctrl_grp_pins[] = { 25, 83, 94 };
static const unsigned int bond_grp_pins[] = { 87, 88, 90 };
static const unsigned int usb_grp_pins[] = { 97, 98 };
static const unsigned int lcd_te_grp_pins[] = { 31, 32 };
static const unsigned int jtag_grp_pins[] = { 92, 93 };
static const unsigned int i2c_slv1_grp_pins[] = { 48, 49 };
static const unsigned int i2c_slv0_grp_pins[] = { 5, 6 };
static const unsigned int i2c7_grp_pins[] = { 8, 9 };
static const unsigned int i2c6_grp_pins[] = { 0, 1 };
static const unsigned int i2c5_grp_pins[] = { 4, 10 };
static const unsigned int i2c4_grp_pins[] = { 67, 68 };
static const unsigned int i2c3_grp_pins[] = { 63, 64 };
static const unsigned int i2c2_grp_pins[] = { 65, 66 };
static const unsigned int i2c1_grp_pins[] = { 13, 14 };
static const unsigned int i2c0_grp_pins[] = { 11, 12 };
static const unsigned int dmic_grp_pins[] = { 95, 96 };
static const unsigned int emmc_pwr_en_grp_pins[] = { 89 };

#define AX630C_GROUP(_name, _pins)				\
	{ .name = (_name), .pins = (_pins), .num_pins = ARRAY_SIZE(_pins) }

const struct ax630c_group ax630c_groups[] = {
	/* The 56 multi-pad groups, one per function. */
	AX630C_GROUP("gpio", gpio_grp_pins),
	AX630C_GROUP("db_gpio", db_gpio_grp_pins),
	AX630C_GROUP("vi", vi_grp_pins),
	AX630C_GROUP("sensor_sync", sensor_sync_grp_pins),
	AX630C_GROUP("pwm", pwm_grp_pins),
	AX630C_GROUP("dpi", dpi_grp_pins),
	AX630C_GROUP("rgmii", rgmii_grp_pins),
	AX630C_GROUP("debug_bus", debug_bus_grp_pins),
	AX630C_GROUP("analog_test", analog_test_grp_pins),
	AX630C_GROUP("spi_m2", spi_m2_grp_pins),
	AX630C_GROUP("dphy_rx", dphy_rx_grp_pins),
	AX630C_GROUP("clk_aux", clk_aux_grp_pins),
	AX630C_GROUP("emmc", emmc_grp_pins),
	AX630C_GROUP("dphy_tx", dphy_tx_grp_pins),
	AX630C_GROUP("infrared", infrared_grp_pins),
	AX630C_GROUP("bt656", bt656_grp_pins),
	AX630C_GROUP("mclk", mclk_grp_pins),
	AX630C_GROUP("spi_m1", spi_m1_grp_pins),
	AX630C_GROUP("spi_m0", spi_m0_grp_pins),
	AX630C_GROUP("sfc", sfc_grp_pins),
	AX630C_GROUP("spi_s", spi_s_grp_pins),
	AX630C_GROUP("spi2ahb", spi2ahb_grp_pins),
	AX630C_GROUP("sdio", sdio_grp_pins),
	AX630C_GROUP("sd", sd_grp_pins),
	AX630C_GROUP("i2s1", i2s1_grp_pins),
	AX630C_GROUP("i2s0", i2s0_grp_pins),
	AX630C_GROUP("risc_jtag", risc_jtag_grp_pins),
	AX630C_GROUP("ephy", ephy_grp_pins),
	AX630C_GROUP("uart5", uart5_grp_pins),
	AX630C_GROUP("uart4", uart4_grp_pins),
	AX630C_GROUP("uart3", uart3_grp_pins),
	AX630C_GROUP("uart2", uart2_grp_pins),
	AX630C_GROUP("uart1", uart1_grp_pins),
	AX630C_GROUP("uart0", uart0_grp_pins),
	AX630C_GROUP("timestamp", timestamp_grp_pins),
	AX630C_GROUP("thermal_ain", thermal_ain_grp_pins),
	AX630C_GROUP("sysctl", sysctl_grp_pins),
	AX630C_GROUP("reserved_analog", reserved_analog_grp_pins),
	AX630C_GROUP("emac_pps", emac_pps_grp_pins),
	AX630C_GROUP("sd_ctrl", sd_ctrl_grp_pins),
	AX630C_GROUP("bond", bond_grp_pins),
	AX630C_GROUP("usb", usb_grp_pins),
	AX630C_GROUP("lcd_te", lcd_te_grp_pins),
	AX630C_GROUP("jtag", jtag_grp_pins),
	AX630C_GROUP("i2c_slv1", i2c_slv1_grp_pins),
	AX630C_GROUP("i2c_slv0", i2c_slv0_grp_pins),
	AX630C_GROUP("i2c7", i2c7_grp_pins),
	AX630C_GROUP("i2c6", i2c6_grp_pins),
	AX630C_GROUP("i2c5", i2c5_grp_pins),
	AX630C_GROUP("i2c4", i2c4_grp_pins),
	AX630C_GROUP("i2c3", i2c3_grp_pins),
	AX630C_GROUP("i2c2", i2c2_grp_pins),
	AX630C_GROUP("i2c1", i2c1_grp_pins),
	AX630C_GROUP("i2c0", i2c0_grp_pins),
	AX630C_GROUP("dmic", dmic_grp_pins),
	AX630C_GROUP("emmc_pwr_en", emmc_pwr_en_grp_pins),

	/* The 111 single-pad groups. */
	AX630C_GROUP("VI_D0", vi_d0_pins),
	AX630C_GROUP("VI_D1", vi_d1_pins),
	AX630C_GROUP("VI_D2", vi_d2_pins),
	AX630C_GROUP("VI_D3", vi_d3_pins),
	AX630C_GROUP("VI_D4", vi_d4_pins),
	AX630C_GROUP("VI_D5", vi_d5_pins),
	AX630C_GROUP("VI_D6", vi_d6_pins),
	AX630C_GROUP("VI_D7", vi_d7_pins),
	AX630C_GROUP("VI_D8", vi_d8_pins),
	AX630C_GROUP("VI_D9", vi_d9_pins),
	AX630C_GROUP("VI_CLK0", vi_clk0_pins),
	AX630C_GROUP("I2C0_SCL", i2c0_scl_pins),
	AX630C_GROUP("I2C0_SDA", i2c0_sda_pins),
	AX630C_GROUP("I2C1_SCL", i2c1_scl_pins),
	AX630C_GROUP("I2C1_SDA", i2c1_sda_pins),
	AX630C_GROUP("UART0_TXD", uart0_txd_pins),
	AX630C_GROUP("UART0_RXD", uart0_rxd_pins),
	AX630C_GROUP("UART1_TXD", uart1_txd_pins),
	AX630C_GROUP("UART1_RXD", uart1_rxd_pins),
	AX630C_GROUP("UART2_TXD", uart2_txd_pins),
	AX630C_GROUP("UART2_RXD", uart2_rxd_pins),
	AX630C_GROUP("UART3_TXD", uart3_txd_pins),
	AX630C_GROUP("UART3_RXD", uart3_rxd_pins),
	AX630C_GROUP("EMAC_PTP_PPS0", emac_ptp_pps0_pins),
	AX630C_GROUP("EMAC_PTP_PPS1", emac_ptp_pps1_pins),
	AX630C_GROUP("EMAC_PTP_PPS2", emac_ptp_pps2_pins),
	AX630C_GROUP("EMAC_PTP_PPS3", emac_ptp_pps3_pins),
	AX630C_GROUP("RGMII_MDCK", rgmii_mdck_pins),
	AX630C_GROUP("RGMII_MDIO", rgmii_mdio_pins),
	AX630C_GROUP("EPHY_CLK", ephy_clk_pins),
	AX630C_GROUP("EPHY_RSTN", ephy_rstn_pins),
	AX630C_GROUP("EPHY_LED0", ephy_led0_pins),
	AX630C_GROUP("EPHY_LED1", ephy_led1_pins),
	AX630C_GROUP("RGMII_RXD0", rgmii_rxd0_pins),
	AX630C_GROUP("RGMII_RXD1", rgmii_rxd1_pins),
	AX630C_GROUP("RGMII_RXDV", rgmii_rxdv_pins),
	AX630C_GROUP("RGMII_RXCLK", rgmii_rxclk_pins),
	AX630C_GROUP("RGMII_RXD2", rgmii_rxd2_pins),
	AX630C_GROUP("RGMII_RXD3", rgmii_rxd3_pins),
	AX630C_GROUP("RGMII_TXD0", rgmii_txd0_pins),
	AX630C_GROUP("RGMII_TXD1", rgmii_txd1_pins),
	AX630C_GROUP("RGMII_TXCLK", rgmii_txclk_pins),
	AX630C_GROUP("RGMII_TXEN", rgmii_txen_pins),
	AX630C_GROUP("RGMII_TXD2", rgmii_txd2_pins),
	AX630C_GROUP("RGMII_TXD3", rgmii_txd3_pins),
	AX630C_GROUP("SD_DAT0", sd_dat0_pins),
	AX630C_GROUP("SD_DAT1", sd_dat1_pins),
	AX630C_GROUP("SD_CLK", sd_clk_pins),
	AX630C_GROUP("SD_CMD", sd_cmd_pins),
	AX630C_GROUP("SD_DAT2", sd_dat2_pins),
	AX630C_GROUP("SD_DAT3", sd_dat3_pins),
	AX630C_GROUP("EMMC_DAT5", emmc_dat5_pins),
	AX630C_GROUP("EMMC_RESET_N", emmc_reset_n_pins),
	AX630C_GROUP("EMMC_DAT4", emmc_dat4_pins),
	AX630C_GROUP("EMMC_DAT6", emmc_dat6_pins),
	AX630C_GROUP("EMMC_DS", emmc_ds_pins),
	AX630C_GROUP("EMMC_DAT7", emmc_dat7_pins),
	AX630C_GROUP("EMMC_DAT3", emmc_dat3_pins),
	AX630C_GROUP("EMMC_DAT2", emmc_dat2_pins),
	AX630C_GROUP("EMMC_CLK", emmc_clk_pins),
	AX630C_GROUP("EMMC_DAT0", emmc_dat0_pins),
	AX630C_GROUP("EMMC_CMD", emmc_cmd_pins),
	AX630C_GROUP("EMMC_DAT1", emmc_dat1_pins),
	AX630C_GROUP("SDIO_DAT0", sdio_dat0_pins),
	AX630C_GROUP("SDIO_DAT1", sdio_dat1_pins),
	AX630C_GROUP("SDIO_CLK", sdio_clk_pins),
	AX630C_GROUP("SDIO_CMD", sdio_cmd_pins),
	AX630C_GROUP("SDIO_DAT2", sdio_dat2_pins),
	AX630C_GROUP("SDIO_DAT3", sdio_dat3_pins),
	AX630C_GROUP("CDTX_L0N", cdtx_l0n_pins),
	AX630C_GROUP("CDTX_L0P", cdtx_l0p_pins),
	AX630C_GROUP("CDTX_L1N", cdtx_l1n_pins),
	AX630C_GROUP("CDTX_L1P", cdtx_l1p_pins),
	AX630C_GROUP("CDTX_L2N", cdtx_l2n_pins),
	AX630C_GROUP("CDTX_L2P", cdtx_l2p_pins),
	AX630C_GROUP("CDTX_L3N", cdtx_l3n_pins),
	AX630C_GROUP("CDTX_L3P", cdtx_l3p_pins),
	AX630C_GROUP("CDTX_L4N", cdtx_l4n_pins),
	AX630C_GROUP("CDTX_L4P", cdtx_l4p_pins),
	AX630C_GROUP("THM_AIN3", thm_ain3_pins),
	AX630C_GROUP("THM_AIN2", thm_ain2_pins),
	AX630C_GROUP("THM_AIN1", thm_ain1_pins),
	AX630C_GROUP("THM_AIN0", thm_ain0_pins),
	AX630C_GROUP("SD_PWR_SW", sd_pwr_sw_pins),
	AX630C_GROUP("GPIO3_A1", gpio3_a1_pins),
	AX630C_GROUP("GPIO3_A2", gpio3_a2_pins),
	AX630C_GROUP("GPIO3_A3", gpio3_a3_pins),
	AX630C_GROUP("BOND0", bond0_pins),
	AX630C_GROUP("BOND1", bond1_pins),
	AX630C_GROUP("EMMC_PWR_EN", emmc_pwr_en_pins),
	AX630C_GROUP("BOND2", bond2_pins),
	AX630C_GROUP("SYS_RSTN_OUT", sys_rstn_out_pins),
	AX630C_GROUP("TMS", tms_pins),
	AX630C_GROUP("TCK", tck_pins),
	AX630C_GROUP("SD_PWR_EN", sd_pwr_en_pins),
	AX630C_GROUP("MICP_L_D", micp_l_d_pins),
	AX630C_GROUP("MICN_L_D", micn_l_d_pins),
	AX630C_GROUP("MICN_R_D", micn_r_d_pins),
	AX630C_GROUP("MICP_R_D", micp_r_d_pins),
	AX630C_GROUP("CDRX_L0N", cdrx_l0n_pins),
	AX630C_GROUP("CDRX_L0P", cdrx_l0p_pins),
	AX630C_GROUP("CDRX_L1N", cdrx_l1n_pins),
	AX630C_GROUP("CDRX_L1P", cdrx_l1p_pins),
	AX630C_GROUP("CDRX_L2N", cdrx_l2n_pins),
	AX630C_GROUP("CDRX_L2P", cdrx_l2p_pins),
	AX630C_GROUP("CDRX_L3N", cdrx_l3n_pins),
	AX630C_GROUP("CDRX_L3P", cdrx_l3p_pins),
	AX630C_GROUP("CDRX_L4N", cdrx_l4n_pins),
	AX630C_GROUP("CDRX_L4P", cdrx_l4p_pins),
	AX630C_GROUP("CDRX_L5N", cdrx_l5n_pins),
	AX630C_GROUP("CDRX_L5P", cdrx_l5p_pins),
};

const unsigned int ax630c_num_groups = ARRAY_SIZE(ax630c_groups);

/*
 * Functions: the 56 of specification section 3.3. Each is valid on its own
 * multi-pad group and on each of the single-pad groups section 3.3 lists for
 * it -- a consumer can therefore say groups = "emmc" or spell out
 * groups = "EMMC_CLK", "EMMC_CMD", ... as section 8.3 does.
 */
static const char * const gpio_groups[] = {
	"gpio",
	"VI_D0", "VI_D1", "VI_D2", "VI_D3", "VI_D4", "VI_D5", "VI_D6",
	"VI_D7", "VI_D8", "VI_D9", "VI_CLK0", "I2C0_SCL", "I2C0_SDA",
	"I2C1_SCL", "I2C1_SDA", "UART0_TXD", "UART0_RXD", "UART1_TXD",
	"UART1_RXD", "UART2_TXD", "UART2_RXD", "UART3_TXD", "UART3_RXD",
	"EMAC_PTP_PPS0", "EMAC_PTP_PPS1", "EMAC_PTP_PPS2", "EMAC_PTP_PPS3",
	"RGMII_MDCK", "RGMII_MDIO", "EPHY_CLK", "EPHY_RSTN", "EPHY_LED0",
	"EPHY_LED1", "RGMII_RXD0", "RGMII_RXD1", "RGMII_RXDV", "RGMII_RXCLK",
	"RGMII_RXD2", "RGMII_RXD3", "RGMII_TXD0", "RGMII_TXD1",
	"RGMII_TXCLK", "RGMII_TXEN", "RGMII_TXD2", "RGMII_TXD3", "SD_DAT0",
	"SD_DAT1", "SD_CLK", "SD_CMD", "SD_DAT2", "SD_DAT3", "EMMC_DAT5",
	"EMMC_RESET_N", "EMMC_DAT4", "EMMC_DAT6", "EMMC_DS", "EMMC_DAT7",
	"EMMC_DAT3", "EMMC_DAT2", "EMMC_CLK", "EMMC_DAT0", "EMMC_CMD",
	"EMMC_DAT1", "SDIO_DAT0", "SDIO_DAT1", "SDIO_CLK", "SDIO_CMD",
	"SDIO_DAT2", "SDIO_DAT3", "CDTX_L0N", "CDTX_L0P", "CDTX_L1N",
	"CDTX_L1P", "CDTX_L2N", "CDTX_L2P", "CDTX_L3N", "CDTX_L3P",
	"CDTX_L4N", "CDTX_L4P", "THM_AIN3", "THM_AIN2", "THM_AIN1",
	"THM_AIN0", "GPIO3_A1", "GPIO3_A2", "GPIO3_A3", "BOND0", "BOND1",
	"EMMC_PWR_EN", "BOND2", "TMS", "TCK", "SD_PWR_EN", "MICP_L_D",
	"MICN_L_D", "MICN_R_D", "MICP_R_D",
};
static const char * const db_gpio_groups[] = {
	"db_gpio",
	"VI_D0", "VI_D1", "VI_D2", "VI_D3", "VI_D4", "VI_D5", "VI_D6",
	"VI_D7", "VI_D8", "VI_D9", "VI_CLK0", "UART0_TXD", "UART0_RXD",
	"UART1_TXD", "UART2_TXD", "UART2_RXD", "UART3_TXD", "UART3_RXD",
	"EMAC_PTP_PPS0", "EMAC_PTP_PPS1", "EMAC_PTP_PPS2", "EMAC_PTP_PPS3",
	"RGMII_MDCK", "RGMII_MDIO", "EPHY_CLK", "EPHY_RSTN", "EPHY_LED0",
	"EPHY_LED1", "RGMII_RXD0", "RGMII_RXD1", "RGMII_RXDV", "RGMII_RXCLK",
	"RGMII_RXD2", "RGMII_RXD3", "RGMII_TXD0", "RGMII_TXD1",
	"RGMII_TXCLK", "RGMII_TXEN", "RGMII_TXD2", "RGMII_TXD3", "SD_DAT0",
	"SD_DAT1", "SD_CLK", "SD_CMD", "SD_DAT2", "SD_DAT3", "EMMC_DAT5",
	"EMMC_RESET_N", "EMMC_DAT4", "EMMC_DAT6", "EMMC_DS", "EMMC_DAT7",
	"EMMC_DAT3", "EMMC_DAT2", "EMMC_CLK", "EMMC_DAT0", "EMMC_CMD",
	"EMMC_DAT1", "SDIO_DAT0", "SDIO_DAT1", "SDIO_CLK", "SDIO_CMD",
	"SDIO_DAT2", "SDIO_DAT3", "CDTX_L0N", "CDTX_L0P", "CDTX_L1N",
	"CDTX_L1P", "CDTX_L2N", "CDTX_L2P", "CDTX_L3N", "CDTX_L3P",
	"CDTX_L4N", "CDTX_L4P", "THM_AIN3", "THM_AIN2", "THM_AIN1",
	"THM_AIN0", "SD_PWR_SW", "GPIO3_A1", "GPIO3_A2", "GPIO3_A3",
	"EMMC_PWR_EN", "TMS", "TCK", "SD_PWR_EN", "MICP_L_D", "MICN_L_D",
	"MICN_R_D", "MICP_R_D",
};
static const char * const vi_groups[] = {
	"vi",
	"VI_D0", "VI_D1", "VI_D2", "VI_D3", "VI_D4", "VI_D5", "VI_D6",
	"VI_D7", "VI_D8", "VI_D9", "VI_CLK0", "CDRX_L0N", "CDRX_L0P",
	"CDRX_L1N", "CDRX_L1P", "CDRX_L2N", "CDRX_L2P", "CDRX_L3N",
	"CDRX_L3P", "CDRX_L4N", "CDRX_L4P", "CDRX_L5N", "CDRX_L5P",
};
static const char * const sensor_sync_groups[] = {
	"sensor_sync",
	"UART1_TXD", "UART1_RXD", "UART2_TXD", "UART2_RXD", "UART3_TXD",
	"UART3_RXD", "EMAC_PTP_PPS0", "EMAC_PTP_PPS1", "RGMII_MDCK",
	"RGMII_MDIO", "EPHY_CLK", "EPHY_RSTN", "EPHY_LED0", "EPHY_LED1",
	"RGMII_TXD1", "RGMII_TXCLK", "RGMII_TXEN", "RGMII_TXD2",
	"RGMII_TXD3", "GPIO3_A2", "BOND0", "BOND1", "MICN_R_D",
};
static const char * const pwm_groups[] = {
	"pwm",
	"I2C0_SCL", "I2C0_SDA", "I2C1_SCL", "I2C1_SDA", "UART1_TXD",
	"UART1_RXD", "UART3_TXD", "UART3_RXD", "EMAC_PTP_PPS0",
	"EMAC_PTP_PPS1", "EMAC_PTP_PPS3", "RGMII_MDCK", "RGMII_MDIO",
	"EPHY_RSTN", "RGMII_TXD2", "RGMII_TXD3", "SDIO_DAT0", "SDIO_DAT1",
	"THM_AIN1", "THM_AIN0",
};
static const char * const dpi_groups[] = {
	"dpi",
	"EMAC_PTP_PPS0", "EMAC_PTP_PPS1", "EMAC_PTP_PPS2", "EMAC_PTP_PPS3",
	"RGMII_MDCK", "RGMII_MDIO", "EPHY_CLK", "EPHY_RSTN", "RGMII_RXD0",
	"RGMII_RXD1", "RGMII_RXDV", "RGMII_RXCLK", "RGMII_RXD2",
	"RGMII_RXD3", "RGMII_TXD0", "RGMII_TXD1", "RGMII_TXCLK",
	"RGMII_TXEN", "RGMII_TXD2", "RGMII_TXD3",
};
static const char * const rgmii_groups[] = {
	"rgmii",
	"RGMII_MDCK", "RGMII_MDIO", "EPHY_LED0", "EPHY_LED1", "RGMII_RXD0",
	"RGMII_RXD1", "RGMII_RXDV", "RGMII_RXCLK", "RGMII_RXD2",
	"RGMII_RXD3", "RGMII_TXD0", "RGMII_TXD1", "RGMII_TXCLK",
	"RGMII_TXEN", "RGMII_TXD2", "RGMII_TXD3",
};
static const char * const debug_bus_groups[] = {
	"debug_bus",
	"RGMII_RXD0", "RGMII_RXD1", "RGMII_RXDV", "RGMII_RXCLK",
	"RGMII_TXD0", "RGMII_TXD1", "RGMII_TXCLK", "RGMII_TXEN", "SD_DAT0",
	"SD_DAT1", "SD_CLK", "SD_CMD", "SD_DAT2", "SD_DAT3", "MICP_L_D",
	"MICN_L_D",
};
static const char * const analog_test_groups[] = {
	"analog_test",
	"VI_D0", "VI_D1", "VI_D2", "VI_D3", "VI_D4", "VI_CLK0", "I2C0_SCL",
	"I2C0_SDA", "UART0_TXD", "UART0_RXD", "UART1_TXD", "UART1_RXD",
	"UART2_TXD", "UART2_RXD", "RGMII_TXEN",
};
static const char * const spi_m2_groups[] = {
	"spi_m2",
	"I2C0_SCL", "I2C0_SDA", "I2C1_SCL", "I2C1_SDA", "UART1_TXD",
	"UART3_TXD", "UART3_RXD", "EPHY_RSTN", "EPHY_LED0", "EPHY_LED1",
	"RGMII_TXD0", "RGMII_TXD1", "RGMII_TXCLK", "RGMII_TXEN",
};
static const char * const dphy_rx_groups[] = {
	"dphy_rx",
	"CDRX_L0N", "CDRX_L0P", "CDRX_L1N", "CDRX_L1P", "CDRX_L2N",
	"CDRX_L2P", "CDRX_L3N", "CDRX_L3P", "CDRX_L4N", "CDRX_L4P",
	"CDRX_L5N", "CDRX_L5P",
};
static const char * const clk_aux_groups[] = {
	"clk_aux",
	"VI_D3", "I2C0_SCL", "I2C0_SDA", "I2C1_SCL", "I2C1_SDA", "UART1_RXD",
	"UART2_TXD", "UART2_RXD", "UART3_TXD", "UART3_RXD", "EPHY_CLK",
	"SDIO_CLK",
};
static const char * const emmc_groups[] = {
	"emmc",
	"EMMC_DAT5", "EMMC_DAT4", "EMMC_DAT6", "EMMC_DS", "EMMC_DAT7",
	"EMMC_DAT3", "EMMC_DAT2", "EMMC_CLK", "EMMC_DAT0", "EMMC_CMD",
	"EMMC_DAT1",
};
static const char * const dphy_tx_groups[] = {
	"dphy_tx",
	"CDTX_L0N", "CDTX_L0P", "CDTX_L1N", "CDTX_L1P", "CDTX_L2N",
	"CDTX_L2P", "CDTX_L3N", "CDTX_L3P", "CDTX_L4N", "CDTX_L4P",
};
static const char * const infrared_groups[] = {
	"infrared",
	"VI_D0", "VI_D1", "VI_D2", "VI_D3", "VI_D4", "VI_D6", "VI_D7",
	"VI_D8", "VI_D9",
};
static const char * const bt656_groups[] = {
	"bt656",
	"CDTX_L0N", "CDTX_L0P", "CDTX_L1N", "CDTX_L1P", "CDTX_L2N",
	"CDTX_L2P", "CDTX_L3N", "CDTX_L3P", "CDTX_L4N",
};
static const char * const mclk_groups[] = {
	"mclk",
	"UART1_RXD", "RGMII_TXD0", "SD_DAT0", "SD_DAT1", "SD_DAT2",
	"SD_DAT3", "THM_AIN2", "BOND2",
};
static const char * const spi_m1_groups[] = {
	"spi_m1",
	"VI_D0", "VI_D1", "VI_D2", "VI_D3", "VI_D4", "VI_D7", "VI_CLK0",
};
static const char * const spi_m0_groups[] = {
	"spi_m0",
	"CDTX_L0N", "CDTX_L0P", "CDTX_L1N", "CDTX_L1P", "CDTX_L2N",
	"CDTX_L2P", "CDTX_L3N",
};
static const char * const sfc_groups[] = {
	"sfc",
	"EMMC_DAT4", "EMMC_DAT3", "EMMC_DAT2", "EMMC_CLK", "EMMC_DAT0",
	"EMMC_CMD", "EMMC_DAT1",
};
static const char * const spi_s_groups[] = {
	"spi_s",
	"VI_D5", "VI_D6", "VI_D7", "VI_D8", "VI_D9", "VI_CLK0",
};
static const char * const spi2ahb_groups[] = {
	"spi2ahb",
	"EMMC_DAT3", "EMMC_DAT2", "EMMC_CLK", "EMMC_DAT0", "EMMC_CMD",
	"EMMC_DAT1",
};
static const char * const sdio_groups[] = {
	"sdio",
	"SDIO_DAT0", "SDIO_DAT1", "SDIO_CLK", "SDIO_CMD", "SDIO_DAT2",
	"SDIO_DAT3",
};
static const char * const sd_groups[] = {
	"sd",
	"SD_DAT0", "SD_DAT1", "SD_CLK", "SD_CMD", "SD_DAT2", "SD_DAT3",
};
static const char * const i2s1_groups[] = {
	"i2s1",
	"SDIO_DAT0", "SDIO_DAT1", "SDIO_CLK", "SDIO_CMD", "SDIO_DAT2",
	"SDIO_DAT3",
};
static const char * const i2s0_groups[] = {
	"i2s0",
	"VI_D0", "VI_D1", "VI_D2", "VI_D3", "VI_D4", "VI_CLK0",
};
static const char * const risc_jtag_groups[] = {
	"risc_jtag",
	"I2C0_SCL", "I2C0_SDA", "UART0_TXD", "UART0_RXD", "UART1_TXD",
};
static const char * const ephy_groups[] = {
	"ephy",
	"EPHY_CLK", "EPHY_RSTN", "EPHY_LED0", "EPHY_LED1", "SDIO_CLK",
};
static const char * const uart5_groups[] = {
	"uart5",
	"EMAC_PTP_PPS0", "EMAC_PTP_PPS1", "EMAC_PTP_PPS2", "EMAC_PTP_PPS3",
};
static const char * const uart4_groups[] = {
	"uart4",
	"I2C1_SCL", "I2C1_SDA", "TMS", "TCK",
};
static const char * const uart3_groups[] = {
	"uart3",
	"UART3_TXD", "UART3_RXD", "BOND0", "BOND1",
};
static const char * const uart2_groups[] = {
	"uart2",
	"I2C0_SCL", "I2C0_SDA", "UART2_TXD", "UART2_RXD",
};
static const char * const uart1_groups[] = {
	"uart1",
	"UART1_TXD", "UART1_RXD", "EMMC_PWR_EN", "BOND2",
};
static const char * const uart0_groups[] = {
	"uart0",
	"UART0_TXD", "UART0_RXD", "RGMII_RXD0", "RGMII_RXD1",
};
static const char * const timestamp_groups[] = {
	"timestamp",
	"UART2_TXD", "UART2_RXD", "THM_AIN1", "THM_AIN0",
};
static const char * const thermal_ain_groups[] = {
	"thermal_ain",
	"THM_AIN3", "THM_AIN2", "THM_AIN1", "THM_AIN0",
};
static const char * const sysctl_groups[] = {
	"sysctl",
	"VI_D2", "SD_PWR_SW", "GPIO3_A1", "SYS_RSTN_OUT",
};
static const char * const reserved_analog_groups[] = {
	"reserved_analog",
	"MICP_L_D", "MICN_L_D", "MICN_R_D", "MICP_R_D",
};
static const char * const emac_pps_groups[] = {
	"emac_pps",
	"EMAC_PTP_PPS0", "EMAC_PTP_PPS1", "EMAC_PTP_PPS2", "EMAC_PTP_PPS3",
};
static const char * const sd_ctrl_groups[] = {
	"sd_ctrl",
	"EMAC_PTP_PPS2", "SD_PWR_SW", "SD_PWR_EN",
};
static const char * const bond_groups[] = {
	"bond",
	"BOND0", "BOND1", "BOND2",
};
static const char * const usb_groups[] = {
	"usb",
	"MICN_R_D", "MICP_R_D",
};
static const char * const lcd_te_groups[] = {
	"lcd_te",
	"EPHY_LED0", "EPHY_LED1",
};
static const char * const jtag_groups[] = {
	"jtag",
	"TMS", "TCK",
};
static const char * const i2c_slv1_groups[] = {
	"i2c_slv1",
	"SD_CMD", "SD_DAT2",
};
static const char * const i2c_slv0_groups[] = {
	"i2c_slv0",
	"VI_D5", "VI_D6",
};
static const char * const i2c7_groups[] = {
	"i2c7",
	"VI_D8", "VI_D9",
};
static const char * const i2c6_groups[] = {
	"i2c6",
	"VI_D0", "VI_D1",
};
static const char * const i2c5_groups[] = {
	"i2c5",
	"VI_D4", "VI_CLK0",
};
static const char * const i2c4_groups[] = {
	"i2c4",
	"SDIO_DAT2", "SDIO_DAT3",
};
static const char * const i2c3_groups[] = {
	"i2c3",
	"SDIO_DAT0", "SDIO_DAT1",
};
static const char * const i2c2_groups[] = {
	"i2c2",
	"SDIO_CLK", "SDIO_CMD",
};
static const char * const i2c1_groups[] = {
	"i2c1",
	"I2C1_SCL", "I2C1_SDA",
};
static const char * const i2c0_groups[] = {
	"i2c0",
	"I2C0_SCL", "I2C0_SDA",
};
static const char * const dmic_groups[] = {
	"dmic",
	"MICP_L_D", "MICN_L_D",
};
static const char * const emmc_pwr_en_groups[] = {
	"emmc_pwr_en",
	"EMMC_PWR_EN",
};

#define AX630C_FUNCTION(_uc, _lc)					\
	[AX630C_FUNC_##_uc] = PINCTRL_PINFUNCTION(#_lc, _lc##_groups,	\
						  ARRAY_SIZE(_lc##_groups))

const struct pinfunction ax630c_functions[] = {
	AX630C_FUNCTION(GPIO, gpio),
	AX630C_FUNCTION(DB_GPIO, db_gpio),
	AX630C_FUNCTION(VI, vi),
	AX630C_FUNCTION(SENSOR_SYNC, sensor_sync),
	AX630C_FUNCTION(PWM, pwm),
	AX630C_FUNCTION(DPI, dpi),
	AX630C_FUNCTION(RGMII, rgmii),
	AX630C_FUNCTION(DEBUG_BUS, debug_bus),
	AX630C_FUNCTION(ANALOG_TEST, analog_test),
	AX630C_FUNCTION(SPI_M2, spi_m2),
	AX630C_FUNCTION(DPHY_RX, dphy_rx),
	AX630C_FUNCTION(CLK_AUX, clk_aux),
	AX630C_FUNCTION(EMMC, emmc),
	AX630C_FUNCTION(DPHY_TX, dphy_tx),
	AX630C_FUNCTION(INFRARED, infrared),
	AX630C_FUNCTION(BT656, bt656),
	AX630C_FUNCTION(MCLK, mclk),
	AX630C_FUNCTION(SPI_M1, spi_m1),
	AX630C_FUNCTION(SPI_M0, spi_m0),
	AX630C_FUNCTION(SFC, sfc),
	AX630C_FUNCTION(SPI_S, spi_s),
	AX630C_FUNCTION(SPI2AHB, spi2ahb),
	AX630C_FUNCTION(SDIO, sdio),
	AX630C_FUNCTION(SD, sd),
	AX630C_FUNCTION(I2S1, i2s1),
	AX630C_FUNCTION(I2S0, i2s0),
	AX630C_FUNCTION(RISC_JTAG, risc_jtag),
	AX630C_FUNCTION(EPHY, ephy),
	AX630C_FUNCTION(UART5, uart5),
	AX630C_FUNCTION(UART4, uart4),
	AX630C_FUNCTION(UART3, uart3),
	AX630C_FUNCTION(UART2, uart2),
	AX630C_FUNCTION(UART1, uart1),
	AX630C_FUNCTION(UART0, uart0),
	AX630C_FUNCTION(TIMESTAMP, timestamp),
	AX630C_FUNCTION(THERMAL_AIN, thermal_ain),
	AX630C_FUNCTION(SYSCTL, sysctl),
	AX630C_FUNCTION(RESERVED_ANALOG, reserved_analog),
	AX630C_FUNCTION(EMAC_PPS, emac_pps),
	AX630C_FUNCTION(SD_CTRL, sd_ctrl),
	AX630C_FUNCTION(BOND, bond),
	AX630C_FUNCTION(USB, usb),
	AX630C_FUNCTION(LCD_TE, lcd_te),
	AX630C_FUNCTION(JTAG, jtag),
	AX630C_FUNCTION(I2C_SLV1, i2c_slv1),
	AX630C_FUNCTION(I2C_SLV0, i2c_slv0),
	AX630C_FUNCTION(I2C7, i2c7),
	AX630C_FUNCTION(I2C6, i2c6),
	AX630C_FUNCTION(I2C5, i2c5),
	AX630C_FUNCTION(I2C4, i2c4),
	AX630C_FUNCTION(I2C3, i2c3),
	AX630C_FUNCTION(I2C2, i2c2),
	AX630C_FUNCTION(I2C1, i2c1),
	AX630C_FUNCTION(I2C0, i2c0),
	AX630C_FUNCTION(DMIC, dmic),
	AX630C_FUNCTION(EMMC_PWR_EN, emmc_pwr_en),
};

const unsigned int ax630c_num_functions = ARRAY_SIZE(ax630c_functions);
