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
# The dt-bindings headers come from pkgs/kernel-mainline.nix's `dev` output, so
# the DT is always compiled against the exact kernel that will boot it.
#
# `$out/dtb` HOLDS EXACTLY ONE FILE, and that is a contract since #99:
# `hardware.deviceTree.dtbSource` points at it, and NixOS's extlinux builder
# copies the whole directory into /boot/nixos/. Anything else in there would be
# copied onto a 272 MiB partition for no reason. The decompiled source, which
# the assertions below read, is installed beside it rather than inside it.
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
      -I ${kernel-mainline.dev}/include \
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

    # #82: the USB pair. The glue node is worthless without its child (nothing
    # would bind the controller) and the child is worthless without the "ref"
    # clock (the core would program the wrong frequency adjustment and the
    # error is invisible until a host times a transfer). Both are one edit away
    # from being lost silently, so assert them.
    grep -q 'compatible = "snps,dwc3"' ${board}.decompiled.dts \
      || fail "the dwc3 core node is missing (the glue populates nothing)"
    grep -q 'clock-names = "ref"' ${board}.decompiled.dts \
      || fail "the dwc3 core node lost its 24 MHz ref clock"
    grep -q 'dr_mode = "peripheral"' ${board}.decompiled.dts \
      || fail "the dwc3 core node is not in peripheral mode"

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

    # --- #84: the mini-display and HDMI audio ---------------------------
    # Every check here is on a CELL VALUE rather than the presence of a
    # property, because each of these is silent when wrong: a panel with the
    # dc line inverted is blank with no error, a backlight with the polarity
    # cell inverted is dark at brightness 100, and an I2S node that lost its
    # rx-channel waits forever for an interrupt that is masked.
    #
    # fdtget, not grep, so a phandle renumbering cannot make a check pass for
    # the wrong reason.
    for n in /soc/spi@6072000 /soc/pwm@6060000 /soc/i2s@6051000 \
             /soc/spi@6072000/panel@1 /backlight /gpio-keys /rotary-encoder \
             /spdif-in /sound; do
      fdtget -t s ${board}.dtb "$n" compatible >/dev/null 2>&1 \
        || fail "$n is missing from the device tree"
    done

    # The panel's two GPIO polarities, which disagree with each other and with
    # the vendor DT. 4.19 fbtft drove both lines with the RAW gpio API and
    # mainline uses the logical one, so `dc` flips to ACTIVE_HIGH (0) while
    # `reset` stays ACTIVE_LOW (1). Getting dc wrong sends every command byte
    # as data.
    dcflag=$(fdtget -t u ${board}.dtb /soc/spi@6072000/panel@1 dc-gpios | awk '{print $3}')
    [ "$dcflag" = "0" ] \
      || fail "the panel's dc-gpios is not ACTIVE_HIGH (flag=$dcflag); every command would be sent as data"
    rstflag=$(fdtget -t u ${board}.dtb /soc/spi@6072000/panel@1 reset-gpios | awk '{print $3}')
    [ "$rstflag" = "1" ] \
      || fail "the panel's reset-gpios is not ACTIVE_LOW (flag=$rstflag)"

    # The backlight's polarity cell. 0 = PWM_POLARITY_NORMAL, which is what
    # makes a longer HIGH period brighter; the upstream dwc driver only
    # accepted INVERSED until patch 0002, and inverted here would run
    # brightness backwards.
    blpol=$(fdtget -t u ${board}.dtb /backlight pwms | awk '{print $4}')
    [ "$blpol" = "0" ] \
      || fail "the backlight's pwm polarity cell is $blpol, not 0 (normal); brightness would run backwards"

    # The audio crossbar. Both properties are ours (patch 0003) and both are
    # invisible when missing: without the syscon write the pads feed a
    # different I2S instance, and without rx-channel the driver listens on the
    # wrong one of the block's four receivers.
    fdtget -t u ${board}.dtb /soc/i2s@6051000 snps,syscon >/dev/null 2>&1 \
      || fail "the i2s node lost snps,syscon (the audio crossbar would never be written)"
    rxch=$(fdtget -t u ${board}.dtb /soc/i2s@6051000 snps,rx-channel)
    [ "$rxch" = "1" ] \
      || fail "the i2s node's snps,rx-channel is $rxch, not 1"
    grep -q 'snps,designware-i2s' ${board}.decompiled.dts \
      || fail "the i2s node is not the stock DesignWare compatible"

    # --- #107: the VC8000E's core clock ---------------------------------
    # clk_vpu_glb_sel comes out of reset on cpll_208m, which is 41.6 ms for a
    # 4096x2160 H.264 frame -- a 24 fps encoder under a 30 fps source, and the
    # board silently drops every fourth frame. The only thing that moves the
    # mux is this assigned-clock-parents pair, and losing it is invisible
    # except as a frame rate, so assert BOTH cells: the mux id (0 =
    # AX630C_CLK_VPU_GLB_SEL) and the parent id (15 = AX630C_CPLL_312M).
    vencmux=$(fdtget -t u ${board}.dtb /soc/video-encoder@4010000 assigned-clocks | awk '{print $2}')
    [ "$vencmux" = "0" ] \
      || fail "the venc node's assigned-clocks names clock $vencmux, not clk_vpu_glb_sel (0)"
    vencpar=$(fdtget -t u ${board}.dtb /soc/video-encoder@4010000 assigned-clock-parents | awk '{print $2}')
    [ "$vencpar" = "15" ] \
      || fail "the venc core clock's parent is id $vencpar, not cpll_312m (15); without 312 MHz the mux keeps its reset tap (208 MHz), which caps 4K at 24 fps"

    # The knob's button name is an ABI: nanokvm-display finds its wake sources
    # by EVIOCGNAME, and gpio_keys takes the input device's name from `label`.
    lbl=$(fdtget -t s ${board}.dtb /gpio-keys label)
    [ "$lbl" = "gpio_keys" ] \
      || fail "the gpio-keys node's label is '$lbl', not gpio_keys"

    mkdir -p "$out/dtb"
    cp ${board}.dtb "$out/dtb/"
    cp ${board}.decompiled.dts "$out/"

    # The contract in the header, asserted: one file in $out/dtb, and it is the
    # blob. `hardware.deviceTree.dtbSource` is this directory.
    n=$(find "$out/dtb" -type f | wc -l)
    [ "$n" = 1 ] || fail "$out/dtb holds $n files; it must hold only ${board}.dtb"

    runHook postInstall
  '';

  meta = {
    description = "Mainline device tree for the Sipeed NanoKVM-Pro (AX630C), built from dts/";
    platforms = [ "x86_64-linux" ];
  };
}
