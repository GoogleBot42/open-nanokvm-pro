/* Read the ethernet PHY's identity and RGMII delay registers over MDIO.
 * Read-only apart from the page-select register, which is restored to 0.
 * Build on the device: gcc -O2 -o phyread phyread.c
 */
#include <linux/mii.h>
#include <linux/sockios.h>
#include <net/if.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

static int s;
static struct ifreq ifr;

static struct mii_ioctl_data *mii(void)
{
	return (struct mii_ioctl_data *)&ifr.ifr_data;
}

static int rd(int reg)
{
	mii()->reg_num = (unsigned short)reg;
	if (ioctl(s, SIOCGMIIREG, &ifr) < 0)
		return -1;
	return mii()->val_out;
}

static int wr(int reg, int val)
{
	mii()->reg_num = (unsigned short)reg;
	mii()->val_in = (unsigned short)val;
	return ioctl(s, SIOCSMIIREG, &ifr);
}

int main(int argc, char **argv)
{
	int page;

	s = socket(AF_INET, SOCK_DGRAM, 0);
	memset(&ifr, 0, sizeof(ifr));
	strncpy(ifr.ifr_name, argc > 1 ? argv[1] : "eth0", IFNAMSIZ - 1);

	if (ioctl(s, SIOCGMIIPHY, &ifr) < 0) {
		perror("SIOCGMIIPHY");
		return 1;
	}
	printf("phy_addr      = %u\n", mii()->phy_id);

	printf("BMCR   (0x00) = 0x%04x\n", rd(0x00));
	printf("BMSR   (0x01) = 0x%04x\n", rd(0x01));
	printf("PHYID1 (0x02) = 0x%04x\n", rd(0x02));
	printf("PHYID2 (0x03) = 0x%04x\n", rd(0x03));

	page = rd(0x1f);
	printf("PAGE   (0x1f) = 0x%04x\n", page);

	if (wr(0x1f, 0x0d08) < 0) {
		perror("page select 0xd08");
		return 1;
	}
	printf("p0xd08 TXCR (0x11) = 0x%04x   TX_DELAY(bit8) = %d\n",
	       rd(0x11), (rd(0x11) >> 8) & 1);
	printf("p0xd08 RXCR (0x15) = 0x%04x   RX_DELAY(bit3) = %d\n",
	       rd(0x15), (rd(0x15) >> 3) & 1);
	wr(0x1f, page < 0 ? 0 : page);
	printf("PAGE restored to 0x%04x\n", rd(0x1f));

	return 0;
}
