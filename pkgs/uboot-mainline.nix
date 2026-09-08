{ pkgs, crossPkgs, axSign, ... }:

# ===========================================================================
# Mainline U-Boot for the AX630C / NanoKVM-Pro (#89, epic #26).
#
# Upstream U-Boot 2026.07, unmodified, plus a five-patch AX630C port carried in
# pkgs/uboot-mainline/patches/ in upstream-submission shape. It replaces the
# vendor's U-Boot 2020.04 fork (pkgs/boot.nix), which is 325 files and
# +157 811 lines off upstream -- almost none of it load-bearing. What the port
# actually needs is 885 lines, because mainline already ships the two drivers
# the vendor forked (sdhci-cadence for the eMMC's Cadence SD4HC; ns16550 for
# the DesignWare UART), and because the first-stage loader hands BL33 a SoC
# whose clocks, muxes and pads are already set. docs/mainline-port.md 11.10.
#
# WHAT THIS PRODUCES
#   images/u-boot.bin                    raw, DT appended, links at 0x5C000400
#   images/u-boot.dtb                    the device tree that is inside it
#   images/u-boot_mainline_signed.bin    axgzip'd + 1 KiB signed header,
#                                        packaged exactly like the vendor's
#                                        u-boot_signed.bin, `dd`-able into the
#                                        `uboot` or `uboot_b` partition
#   src/part_cmdline.c                   the patched partition driver, so the
#                                        host-side parser test in
#                                        checks.uboot-mainline builds the
#                                        SHIPPED source rather than a copy
#
# ONE LAYOUT, NOT THREE. The blkdevparts= clause, the environment's offset and
# size, and the boot partition number are all injected below from
# nixos/emmc-partitions.nix, which parses them out of the `bootargs` line of
# dts/ax630c-nanokvm-pro.dts. The defconfig in the patch carries the same
# values as its upstream-visible default, and every substitution here is
# asserted, so the two can never silently disagree.
#
# NOT TESTED ON HARDWARE. Nothing in this file has run on the board; rung 0 of
# the #89 ladder is "it builds and the images fit".
# ===========================================================================

let
  inherit (pkgs) lib;

  layout = import ../nixos/emmc-partitions.nix { inherit lib; };

  version = "2026.07";

  # Current upstream release. Matches the tree docs/mainline-port.md 11.1
  # diffed the vendor fork against, and the version our nixpkgs pin builds
  # `ubootTools` from, so the toolchain expectations are already exercised.
  src = pkgs.fetchurl {
    url = "https://ftp.denx.de/pub/u-boot/u-boot-${version}.tar.bz2";
    sha256 = "0gi4y60y658lkls4qpcvfwvs08imas6ay7daandqyf7yhb1vzs3q";
  };

  defconfig = "ax630c_nanokvm_pro_defconfig";

  crossCC = crossPkgs.buildPackages.gcc;
  crossBinutils = crossPkgs.buildPackages.binutils;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;

  patches = [
    ./uboot-mainline/patches/0001-arm-add-Axera-AX620E-AX630C-SoC-support.patch
    ./uboot-mainline/patches/0002-board-axera-add-the-Sipeed-NanoKVM-Pro.patch
    ./uboot-mainline/patches/0003-arm-dts-add-the-AX630C-and-the-Sipeed-NanoKVM-Pro.patch
    ./uboot-mainline/patches/0004-disk-add-a-blkdevparts-command-line-partition-driver.patch
    ./uboot-mainline/patches/0005-configs-add-ax630c_nanokvm_pro_defconfig.patch
  ];

  # The SPL enters BL33 here (docs/mainline-port.md 11.2). It is not
  # negotiable: the address is a compile-time constant in the first-stage
  # loader, and the 1 KiB image header carries no load address of its own.
  textBase = "0x5C000400";

  ubootPart = layout.byName.uboot;

  raw = pkgs.stdenv.mkDerivation {
    pname = "nanokvm-pro-uboot-mainline";
    inherit version src patches;

    # U-Boot manages its own flags; the cc-wrapper must not inject PIE,
    # fortify or stack-protector into a bare-metal image.
    hardeningDisable = [ "all" ];
    enableParallelBuilding = true;

    nativeBuildInputs = [ crossCC crossBinutils ] ++ (with pkgs; [
      gnumake bison flex bc dtc openssl ncurses python3 swig
      which gawk perl bash
    ]);

    # Everything the layout defines, in the two places U-Boot reads it.
    blkdevparts = layout.blkdevparts;
    envOffset = layout.hex layout.env.offset;
    envSize = layout.hex layout.env.size;
    bootPart = toString layout.bootfs.number;

    postPatch = ''
      patchShebangs tools scripts

      cfg=configs/${defconfig}
      hdr=include/configs/ax630c.h

      # --- the eMMC layout, from dts/ax630c-nanokvm-pro.dts ----------------
      # A mismatch here is not a build error on either side: U-Boot would
      # simply find a different `boot` partition than Linux does, at a
      # different offset, and the first symptom would be a board that stops
      # booting. So substitute, then assert.
      sed -i "s|^CONFIG_CMDLINE_PARTITION_DEFAULT=.*|CONFIG_CMDLINE_PARTITION_DEFAULT=\"$blkdevparts\"|" "$cfg"
      grep -qF "CONFIG_CMDLINE_PARTITION_DEFAULT=\"$blkdevparts\"" "$cfg" \
        || { echo "ERROR: could not set the blkdevparts clause in $cfg" >&2; exit 1; }

      sed -i "s|^CONFIG_ENV_OFFSET=.*|CONFIG_ENV_OFFSET=$envOffset|" "$cfg"
      sed -i "s|^CONFIG_ENV_SIZE=.*|CONFIG_ENV_SIZE=$envSize|" "$cfg"
      grep -qx "CONFIG_ENV_OFFSET=$envOffset" "$cfg" \
        || { echo "ERROR: could not set CONFIG_ENV_OFFSET in $cfg" >&2; exit 1; }
      grep -qx "CONFIG_ENV_SIZE=$envSize" "$cfg" \
        || { echo "ERROR: could not set CONFIG_ENV_SIZE in $cfg" >&2; exit 1; }

      grep -q "bootpart=[0-9][0-9]*" "$hdr" \
        || { echo "ERROR: no bootpart default in $hdr (did the port move it?)" >&2; exit 1; }
      sed -i "s|bootpart=[0-9][0-9]*|bootpart=$bootPart|" "$hdr"
      grep -qF "bootpart=$bootPart" "$hdr" \
        || { echo "ERROR: could not set bootpart in $hdr" >&2; exit 1; }

      echo "layout: $blkdevparts"
      echo "layout: env at $envOffset size $envSize, /boot is p$bootPart"
    '';

    makeFlags = [
      "ARCH=arm"
      "CROSS_COMPILE=${crossPrefix}"
      "HOSTCC=cc"
      "KBUILD_BUILD_TIMESTAMP=@0"
      "KBUILD_BUILD_USER=nix"
      "KBUILD_BUILD_HOST=nix"
    ];

    configurePhase = ''
      runHook preConfigure
      make $makeFlags ${defconfig}
      runHook postConfigure
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/images" "$out/src" "$out/config"
      cp u-boot.bin "$out/images/u-boot.bin"
      cp u-boot.dtb "$out/images/u-boot.dtb"
      cp u-boot     "$out/images/u-boot.elf"
      cp .config    "$out/config/config"
      cp configs/${defconfig} "$out/config/${defconfig}"

      # The driver the host-side parser test compiles. Copied rather than
      # re-stated so the test can never test a stale copy.
      cp disk/part_cmdline.c "$out/src/part_cmdline.c"

      # The link address is a contract with the first-stage loader, so read it
      # back out of the ELF rather than trusting the defconfig.
      entry=$(${crossPrefix}readelf -h u-boot | ${pkgs.gawk}/bin/awk '/Entry point/ { print $NF }')
      echo "entry point: $entry"
      if [ "$entry" != "${textBase}" ] && [ "$entry" != "${lib.toLower textBase}" ]; then
        echo "ERROR: entry point $entry != ${textBase}; the SPL jumps to a fixed address" >&2
        exit 1
      fi

      ls -l "$out/images"
      runHook postInstall
    '';

    dontStrip = true;
    dontPatchELF = true;

    meta = {
      description = "Mainline U-Boot ${version} with an AX630C / NanoKVM-Pro board port (#89)";
      # The signed variant runs the prebuilt x86-64 ax_gzip; keep the whole
      # package on one platform so the two halves cannot diverge.
      platforms = [ "x86_64-linux" ];
      license = lib.licenses.gpl2Plus;
    };
  };

  signed = axSign.signImage {
    pname = "nanokvm-pro-uboot-mainline-signed";
    name = "u-boot_mainline_signed.bin";
    payload = "${raw}/images/u-boot.bin";
    maxSize = ubootPart.size;
  };
in

pkgs.runCommand "nanokvm-pro-uboot-mainline-${version}"
  {
    inherit version;
    passthru = {
      inherit raw signed layout;
      textBase = textBase;
      ubootPartSize = ubootPart.size;
      patchList = map baseNameOf patches;
    };
    meta = raw.meta;
  }
  ''
    mkdir -p "$out"
    cp -r ${raw}/images ${raw}/src ${raw}/config "$out/"
    chmod -R u+w "$out"
    cp ${signed}/u-boot_mainline_signed.bin "$out/images/"
    ls -l "$out/images"
  ''
