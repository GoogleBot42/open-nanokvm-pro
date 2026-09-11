{ pkgs
, crossPkgs
, kernel # pkgs/kernel-mainline.nix, the appliance variant
, aic8800-src
, firmwarePath ? "/run/current-system/firmware/aic8800_fw/SDIO"
  # The directory the driver opens firmware from. It is compiled in
  # (CONFIG_AIC_FW_PATH) rather than passed as a module parameter, because the
  # per-chip patch appends the detected chip's subdirectory to the COMPILED
  # default and skips that step entirely when the `aic_fw_path` parameter is
  # set -- so a parameter would mean naming the chip by hand.
, ...
}:

# ===========================================================================
# The AIC8800 SDIO WiFi driver, built out-of-tree against the appliance kernel
# (#85). Two modules ship:
#
#   aic8800_bsp    the SDIO transport and firmware loader: it claims the SDIO
#                  function, identifies the chip, and pushes the radio firmware
#                  in. Must be loaded first.
#   aic8800_fdrv   the FULLMAC cfg80211 driver -- it registers the wiphy and
#                  creates wlan0. The MAC itself runs in the radio's firmware,
#                  which is why mac80211 is not in the picture at all.
#
# BLUETOOTH IS OUT OF SCOPE for #85 and `aic8800_btlpm` is therefore NOT built
# (CONFIG_AIC8800_BTLPM_SUPPORT=n on the make line). btlpm is a low-power-mode
# helper for a BT HCI that arrives over a UART this board does not wire to a
# named DT node; bringing BT up means a host controller, a bluez stack and its
# own hardware round, and none of that is what "WiFi stays if it works" asked
# for. Turning it on later is one make variable and a third .ko.
#
# OUT OF TREE, not grafted like the six in-tree drivers in
# pkgs/kernel-mainline.nix: this is 150 kLOC of vendor SDK with its own nested
# Makefiles and its own config vocabulary. It builds against the KDIR that
# kernel derivation's `dev` output carries (`lib/modules/<release>/build`),
# which exists precisely for this.
#
# THE VERMAGIC IS ASSERTED from the built .ko, not assumed from the KDIR path.
# A module whose vermagic disagrees with the running kernel fails at insmod
# with a message about "version magic", on a board with no console -- the same
# class of failure the vendor ax_*.ko contract used to produce (docs/building.md).
# ===========================================================================

let
  inherit (pkgs) lib;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;

  # The literal the Debian series compiles in (fix-sdio-firmware-path.patch).
  # Rewritten to `firmwarePath` below; asserted present first, so a series
  # change that moves the default fails loudly instead of shipping a driver
  # that looks for firmware in a directory NixOS does not have.
  debianFwPath = "/lib/firmware/aic8800_fw/SDIO";
in

assert lib.assertMsg (lib.hasPrefix "/" firmwarePath)
  "aic8800: firmwarePath must be absolute, got '${firmwarePath}'";

pkgs.stdenv.mkDerivation {
  pname = "aic8800-modules";
  version = "${aic8800-src.version}-${kernel.modDirVersion}";

  src = aic8800-src;

  nativeBuildInputs = [
    crossPkgs.buildPackages.gcc
    crossPkgs.buildPackages.binutils
  ] ++ (with pkgs; [ gnumake bc kmod perl ]);

  # The kernel manages its own flags; the cross cc-wrapper must not inject
  # stack-protector / fortify / PIE into a module.
  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;

  unpackPhase = ''
    runHook preUnpack
    # The store source is read-only and kbuild writes its objects beside the
    # sources, so work on a copy.
    cp -r "$src/SDIO/driver_fw/driver/aic8800" ./aic8800
    chmod -R u+w ./aic8800
    runHook postUnpack
  '';

  postPatch = ''
    mk=aic8800/aic8800_bsp/Makefile
    grep -q '${debianFwPath}' "$mk" \
      || { echo "ERROR: the Debian firmware-path patch is not in this source" >&2
           echo "       (expected ${debianFwPath} in aic8800_bsp/Makefile)" >&2; exit 1; }
    substituteInPlace "$mk" --replace-fail '${debianFwPath}' '${firmwarePath}'
  '';

  buildPhase = ''
    runHook preBuild

    kdir="${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    [ -d "$kdir" ] \
      || { echo "ERROR: no KDIR at $kdir -- the kernel's dev output has no" >&2
           echo "       out-of-tree build tree (pkgs/kernel-mainline.nix)." >&2; exit 1; }

    make -C "$kdir" M="$PWD/aic8800" -j$NIX_BUILD_CORES \
      ARCH=arm64 CROSS_COMPILE=${crossPrefix} \
      CONFIG_AIC8800_BTLPM_SUPPORT=n \
      modules

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    d="$out/lib/modules/${kernel.modDirVersion}"
    mkdir -p "$d"

    # Load order is the contract, exactly as it is for the video stack: bsp
    # first (it owns the SDIO function and pushes the firmware), fdrv second
    # (it needs the symbols bsp exports). Reversed, fdrv's insmod fails.
    for ko in aic8800_bsp aic8800_fdrv; do
      src=$(find ./aic8800 -name "$ko.ko" -print -quit)
      [ -n "$src" ] || { echo "ERROR: $ko.ko was not built" >&2; exit 1; }
      ${crossPrefix}strip --strip-debug -o "$d/$ko.ko" "$src"
      echo "$ko.ko" >> "$d/load-order"
    done

    # aic8800_btlpm must NOT be here -- see the header. Assert it, because a
    # Makefile change upstream could quietly start building it and then it
    # would quietly start shipping.
    [ ! -e "$d/aic8800_btlpm.ko" ] \
      || { echo "ERROR: btlpm built; BT is out of scope for #85" >&2; exit 1; }

    # --- the vermagic contract ------------------------------------------
    for ko in "$d"/*.ko; do
      vm=$(modinfo -F vermagic "$ko")
      case "$vm" in
        "${kernel.modDirVersion} "*|"${kernel.modDirVersion}")
          echo "$(basename "$ko"): vermagic '$vm'" ;;
        *)
          echo "ERROR: $(basename "$ko") vermagic is '$vm', not ${kernel.modDirVersion}" >&2
          exit 1 ;;
      esac
    done

    # --- and the firmware path actually compiled in ----------------------
    # The one string that decides whether the radio ever gets its firmware.
    # A grep of the binary is the only check that cannot be fooled by a
    # Makefile that looked right.
    grep -qF '${firmwarePath}' "$d/aic8800_bsp.ko" \
      || { echo "ERROR: ${firmwarePath} is not in aic8800_bsp.ko" >&2; exit 1; }
    echo "firmware path: ${firmwarePath}"

    # depmod so `modinfo` and `modprobe -d` work for anyone debugging on the
    # board. It is not the loader -- nixos/wifi.nix walks load-order with
    # insmod, the same two-line mechanism nanokvm-video.service uses.
    depmod -b "$out" "${kernel.modDirVersion}"

    ls -l "$d"

    runHook postInstall
  '';

  dontFixup = true;

  meta = {
    description = "AIC8800 SDIO WiFi kernel modules for the NanoKVM-Pro's mainline kernel (#85)";
    homepage = "https://github.com/radxa-pkg/aic8800";
    license = lib.licenses.gpl2Only;
    # The BUILDER's platform, not the modules'. This derivation
    # cross-compiles: it runs on x86_64 and emits aarch64 .ko, so pinning
    # `aarch64-linux` here makes the appliance refuse to evaluate on the host
    # that builds it.
    platforms = lib.platforms.linux;
  };
}
