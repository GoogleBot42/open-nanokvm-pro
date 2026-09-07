# Ethernet on the mainline kernel — #77, 2026-09-06

Two slot-B boots of `.#kernel-mainline` on the NanoKVM-Pro, ten minutes apart,
differing in exactly one functional property: the device tree's `phy-mode`.
Run 1 links and passes nothing; run 2 is a gigabit interface with an SSH shell
on it. Everything here is raw device output, redacted only for network identity
(see "Redaction" below).

Procedure for both runs: `.claude/skills/mainline-boot-test/SKILL.md`.

## The files

| File | What it is |
|---|---|
| `phy-identity-mdio.txt` | MDIO read of the PHY from the **running vendor system**, before any mainline boot. Establishes the part number and the pin-strapped RGMII delay state. The decisive artifact. |
| `harness/phyread.c` | The 60-line program that produced it. Compiles with the device's own gcc; reads over `SIOCGMIIREG`, writes only the page-select register and restores it. |
| `run1-rgmii-nodelay-dmesg.txt` | Run 1, `phy-mode = "rgmii"`. The kernel-log stash out of reserved DRAM (`0x480e8000`), read back from slot A afterwards. `/dev/kmsg` record format: `<facility,seq,usec,flag>;text`. |
| `run1-rgmii-nodelay-ramoops-console.txt` | Run 1, the ramoops console zone (`0x480e4000`) — plain text, covers the whole boot. |
| `run2-rgmii-id-dmesg.txt` | Run 2, `phy-mode = "rgmii-id"`. `dmesg` taken **live over Ethernet from the mainline system itself**, which is the point of the run. |
| `run2-rgmii-id-clk-summary.txt` | Run 2, `/sys/kernel/debug/clk/clk_summary` from the mainline system. |
| `run2-rgmii-id-state.txt` | Run 2, a state sweep: uname, cmdline, `/proc/net/dev`, `/proc/interrupts`, the PHY id read off the bus, link speed/duplex, the flash syscon words the glue writes, the PHY reset GPIO word, watchdog state, slot register. |

## What each run showed

**Run 1** (slot register `0x0027F014` on return). Milestones 12–18 and 21 set,
19 and 20 clear:

```
openkvm: net: carrier up after ms: 0x00000c80
openkvm: net: link 1000 Mbit/s full duplex
openkvm: net: udhcpc exit: 0x00000001
openkvm: net: FAIL -- no DHCP lease
```

The MAC, the MDIO bus, the PHY, the clocks and the glue were all already
working — the link trained at gigabit and dropbear started. Not one DHCP packet
completed a round trip. That combination, link up and traffic dead, is the
classic RGMII timing signature.

The same log names the cause:

```
eth0: PHY [stmmac-0:01] driver [RTL8211F Gigabit Ethernet] (irq=POLL)
eth0: configuring for phy/rgmii link mode
```

The PHY is a Realtek RTL8211F. Mainline's realtek driver writes both 2 ns delay
bits to match `phy-mode`, and `"rgmii"` means "no delays" — so it cleared the
delays the board is built around. The vendor never hits this because its
(mis-bound) JLSemi driver compiles its RGMII block out and leaves the strapped
values alone.

**Run 2**, `phy-mode = "rgmii-id"`, the only functional change:

```
eth0: configuring for phy/rgmii-id link mode
104c0000.ethernet: 1000 Mbit/s: RGMII tx clock 250000000 Hz (asked 250000000)
eth0: Link is Up - 1Gbps/Full - flow control off
udhcpc: lease of DEVICE_IP obtained from REDACTED_IP, lease time 43200
[86] Password auth succeeded for 'root' from REDACTED_IP:37298
```

Measured from the host during the run:

- `tools/kvmssh` reaches it unchanged — same address, same password, `uname -r`
  = `7.1.3-nanokvm`.
- 100 pings to the router, 0 % loss, 0.34 ms average.
- 128 MiB over raw TCP (busybox `nc`, no SSH crypto in the path) in 1.15 s =
  **111 MB/s**, i.e. gigabit line rate.
- 321 MiB transmitted, `errors:0 dropped:0 overruns:0 collisions:0`.

Run 2's slot register reads `0x003F3018` *during* the run. Bits 14 and 15 (dwell
completed, `reboot(2)` called) are clear because the run was ended by hand with
`reboot -f` from the SSH session rather than by letting the extended dwell
expire; run 1 set both with the identical dwell code.

## Redaction

`redact.sh` (not banked — it reads `~/.config/nanokvm/device.env`) replaced the
device's LAN address with `DEVICE_IP`, every other RFC1918 address with
`REDACTED_IP`, the board's provisioned MAC with `48:da:35:xx:xx:xx` (the Sipeed
OUI is public), and its link-local IPv6 with `fe80::REDACTED`. Netmasks, port
numbers, timings and every register value are untouched. The randomly generated
MAC stmmac assigns before `/init` overrides it (`device MAC address ...` in the
probe log) is not the board's and is left as captured.
