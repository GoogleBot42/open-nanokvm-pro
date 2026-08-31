{ pkgs, crossPkgs, maix_ax620e_sdk_kernel, ... }:

# ---------------------------------------------------------------------------
# open_vin_csi2.ko -- open V4L2 CSI-2 receiver subdev for the Axera AX630C MIPI
# CSI-2 host (replaces vendor ax_mipi_rx). Epic #55 / issue #57 (M1).
# Clean-room: written from docs/reference/deblob-scope/specs/spec-mipi-rx.md ONLY.
# Build idiom identical to pkgs/ax-stub.nix / pkgs/vc8000-vcmd.nix -> exact vendor
# vermagic (4.19.125 SMP preempt mod_unload aarch64). FIRST-DRAFT: compiles;
# on-hardware bring-up (slot-B A/B) is the serial follow-on.
# ---------------------------------------------------------------------------

let
  crossCC = crossPkgs.buildPackages.gcc13;
  crossBinutils = crossPkgs.buildPackages.binutils;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;
  kernelSubdir = "linux/linux-4.19.125";
  defconfig = "axera_AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig";
in
pkgs.stdenv.mkDerivation {
  pname = "open-vin-csi2";
  version = "0.1.0-ax630c";
  src = ./open-vin-csi2;
  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;
  nativeBuildInputs = [ crossCC crossBinutils ] ++ (with pkgs; [
    gnumake bc bison flex openssl ncurses perl elfutils kmod cpio gzip lzop which gawk bash
  ]);
  dontUnpack = true;
  dontConfigure = true;
  buildPhase = ''
    runHook preBuild
    export ARCH=arm64
    export CROSS_COMPILE=${crossPrefix}
    export KBUILD_BUILD_TIMESTAMP="Thu Jan  1 00:00:00 UTC 1970"
    export KBUILD_BUILD_USER=nix
    export KBUILD_BUILD_HOST=nixbuild
    cp -a "${maix_ax620e_sdk_kernel}" "$TMPDIR/kernel"
    chmod -R u+w "$TMPDIR/kernel"
    KROOT="$TMPDIR/kernel/${kernelSubdir}"
    cd "$KROOT"
    make ${defconfig}
    make -j$NIX_BUILD_CORES modules_prepare
    cp -a "$src" "$TMPDIR/mod"
    chmod -R u+w "$TMPDIR/mod"
    make -j$NIX_BUILD_CORES -C "$KROOT" M="$TMPDIR/mod" modules
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp "$TMPDIR/mod/open_vin_csi2.ko" "$out/open_vin_csi2.ko"
    vm=$(${pkgs.kmod}/bin/modinfo -F vermagic "$out/open_vin_csi2.ko")
    echo "open-vin-csi2: vermagic = $vm"
    case "$vm" in
      "4.19.125 SMP preempt mod_unload aarch64") ;;
      *) echo "open-vin-csi2: vermagic mismatch" >&2; exit 1 ;;
    esac
    ls -l "$out"/*.ko
    runHook postInstall
  '';
  dontStrip = true;
  dontPatchELF = true;
  meta = {
    description = "Open V4L2 CSI-2 receiver subdev for AX630C (ax_mipi_rx replacement, #57)";
    license = pkgs.lib.licenses.gpl2Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
