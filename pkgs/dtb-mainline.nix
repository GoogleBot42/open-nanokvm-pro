{ pkgs, kernel-mainline, ... }:

# ---------------------------------------------------------------------------
# NanoKVM-Pro device tree for the mainline kernel (#74).
#
# Compiled from dts/ IN THIS REPO -- not from a vendor tree. cpp + dtc rather
# than the kernel's `make dtbs`, for two reasons: our dts lives outside the
# kernel tree (which is where an out-of-tree board port belongs until it is
# upstreamed, #87), and `make dtbs` on arm64 would build every other vendor's
# device trees to produce our one file.
#
# The dt-bindings headers come from pkgs/kernel-mainline.nix's output, so the
# DT is always compiled against the exact kernel that will boot it.
# ---------------------------------------------------------------------------

let
  board = "ax630c-nanokvm-pro";

  # Trap 2 (docs/mainline-port.md section 5): `booti` skips BOOTM_STATE_FDT, so
  # the blob is never relocated or grown. U-Boot's fdt_chosen() then writes the
  # env `bootargs` into /chosen -- and if there is no free space in the blob,
  # fdt_setprop fails and boot_prep_linux() calls hang(). A silent hang with no
  # serial. 4 KiB of padding makes any plausible cmdline fit.
  fdtPadding = 4096;
in

pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-pro-dtb-mainline";
  version = kernel-mainline.version;

  src = ../dts;

  nativeBuildInputs = with pkgs; [ dtc gcc ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    # -undef so the host cpp's own macros cannot leak into the DT;
    # -x assembler-with-cpp so cpp keeps `/* */` handling sane for dts.
    cpp -nostdinc \
      -I . \
      -I ${kernel-mainline}/include \
      -undef -D__DTS__ -x assembler-with-cpp \
      -o ${board}.dts.pp ${board}.dts

    dtc -I dts -O dtb -p ${toString fdtPadding} \
      -o ${board}.dtb ${board}.dts.pp

    # Decompile for inspection and for the assertions below.
    dtc -I dtb -O dts -o ${board}.decompiled.dts ${board}.dtb

    runHook postBuild
  '';

  # The DT is the only thing standing between a working boot and a silent hang,
  # so assert the load-bearing facts rather than trusting the source read right.
  installPhase = ''
    runHook preInstall

    fail () { echo "ERROR: $1" >&2; exit 1; }

    size=$(stat -c %s ${board}.dtb)
    echo "dtb: $size bytes"
    [ "$size" -le $((1024 * 1024)) ] \
      || fail "dtb exceeds the 1 MiB dtb partition"

    # Trap 2: the padding must actually be in the blob, not just on the dtc
    # command line. Rebuild with -p 0 and require the difference.
    dtc -I dts -O dtb -p 0 -o unpadded.dtb ${board}.dts.pp 2>/dev/null
    unpadded=$(stat -c %s unpadded.dtb)
    [ $((size - unpadded)) -ge ${toString fdtPadding} ] \
      || fail "dtb carries no FDT slack (fdt_chosen would hang U-Boot)"

    grep -q 'ramoops' ${board}.decompiled.dts || fail "ramoops node missing"

    # The two firmware carveouts. Losing either bricks the boot: the ATF region
    # backs secondary-CPU bring-up, the OP-TEE region is firewalled by the ATF.
    grep -q '0x40040000' ${board}.decompiled.dts || fail "ATF reservation missing"
    grep -q '0x44200000' ${board}.decompiled.dts || fail "OP-TEE reservation missing"

    # Trap 1: U-Boot's partition table is this substring of the cmdline.
    grep -q 'blkdevparts=mmcblk0:' ${board}.decompiled.dts \
      || fail "bootargs lost the blkdevparts= clause (U-Boot would reset its env)"

    # Trap 3/4 groundwork: the watchdog node must exist for #75 to be a
    # driver-only change, and it must still be disabled until that driver lands.
    grep -q 'watchdog@4840000' ${board}.decompiled.dts || fail "wdt0 node missing"

    # #80: the watchdog takes its gates, resets and counter-source mux from the
    # peripheral clock controller. If a rename ever drops one of these the
    # driver still probes -- reset handles are optional and a missing clock is
    # only an error at get time -- so assert them here rather than discover it
    # as a board that reboots every 60 s with no console.
    grep -q 'clock-names = "wdt", "apb"' ${board}.decompiled.dts \
      || fail "wdt0 lost its clock-names"
    grep -q 'reset-names = "wdt", "apb"' ${board}.decompiled.dts \
      || fail "wdt0 lost its reset-names"
    grep -q 'assigned-clock-parents' ${board}.decompiled.dts \
      || fail "wdt0 lost the 24 MHz counter-source selection"
    grep -q 'axera,periph-syscon' ${board}.decompiled.dts \
      && fail "wdt0 still carries the pre-#80 syscon phandle"

    # #80: the pin states of the boot device. A state that fails to apply takes
    # the consumer's probe down with it, and for eMMC that is the rootfs.
    grep -q 'pinctrl-0' ${board}.decompiled.dts || fail "no pin states at all"

    # 24 MHz timer: firmware does not program CNTFRQ.
    grep -q 'clock-frequency = <0x16e3600>' ${board}.decompiled.dts \
      || fail "arch timer clock-frequency is not 24 MHz"

    # --- #81: GPIO, ATX and the HDMI receiver ---------------------------
    # Four controllers, and 97 pads mapped between them. gpio-ranges is the
    # property that makes a GPIO request reach the pin controller and program
    # the pad's mux; get it wrong and nothing fails loudly -- lines simply
    # drive pads that are still muxed to something else, which is exactly the
    # SW_PWR trap this issue exists to kill. The mapping is not an identity, so
    # count the pads the compiled blob actually claims rather than trusting the
    # source to have been read correctly.
    for g in 4800000 4801000 6000000 6001000; do
      grep -q "gpio@$g" ${board}.decompiled.dts || fail "gpio@$g node missing"
    done

    ranges=$(grep -o 'gpio-ranges = <[^>]*>' ${board}.decompiled.dts \
      | sed 's/.*<//; s/>//' \
      | awk '{ for (i = 4; i <= NF; i += 4) n += strtonum($i) } END { print n + 0 }')
    [ "$ranges" = "97" ] \
      || fail "gpio-ranges cover $ranges pads, not the vendor DT's 97"

    grep -q 'atx-power' ${board}.decompiled.dts \
      || fail "the ATX lines lost their gpio-line-names"

    # The HDMI receiver. Its driver takes every board fact from DT -- the bus,
    # the address and seven GPIOs the vendor hardcoded as global numbers -- so
    # a missing property here is a driver that binds and then drives nothing.
    grep -q 'hdmi-receiver@2b' ${board}.decompiled.dts \
      || fail "the LT6911UXC node is missing from i2c0"
    for p in interrupt-gpios power-gpios hdmi-power-gpios loopout-gpios \
             hdmi-rx-detect-gpios hdmi-tx-detect-gpios; do
      grep -q "$p" ${board}.decompiled.dts \
        || fail "the LT6911UXC node lost $p"
    done

    # #77's stopgap is gone: the PHY reset is a real GPIO on the PHY node now,
    # pulsed by the MDIO core. Both halves are asserted, because dropping the
    # property without adding the descriptor leaves a PHY nobody releases.
    grep -q 'axera,phy-reset-mmio' ${board}.decompiled.dts \
      && fail "gmac still pokes the PHY reset through a raw address"
    grep -q 'reset-gpios' ${board}.decompiled.dts \
      || fail "the ethernet PHY lost its reset-gpios"

    mkdir -p "$out/dtb"
    cp ${board}.dtb "$out/dtb/"
    cp ${board}.decompiled.dts "$out/dtb/"

    runHook postInstall
  '';

  meta = {
    description = "Mainline device tree for the Sipeed NanoKVM-Pro (AX630C), built from dts/";
    platforms = [ "x86_64-linux" ];
  };
}
