{ pkgs, crossPkgs, maix_ax620e_sdk_kernel, ... }:

# ---------------------------------------------------------------------------
# Open VC8000E VCMD command-engine driver for the AX630C, built out-of-tree
# against the from-source 4.19.125 kernel (pkgs/kernel.nix).
#
# This is the kernel half of the blob-free encode-submission path (issue #44):
# it replaces the vendor ax_venc.ko's VCMD submission seam -- whose per-frame
# path adds Axera-private nr70/nr83 setup ioctls that fault an out-of-band
# RESERVE->LINK (docs/blob-replacement.md, 2026-08-23 Stage 1) -- with the
# PUBLIC VeriSilicon VCMD driver, whose LINK path is self-contained
# (RESERVE->LINK->WAIT->RELEASE, no userspace-VA copy).
#
# Source: eswin `linux-6.6.18-EIC7X` drivers/staging/media/eswin/venc/
#   github.com/eswincomputing/linux-stable @ fc6038c00e006226e3bd504d2679c534eabf5503
#   dual MIT / GPL-2.0, "COPYRIGHT (C) 2019 VERISILICON". See vc8000-vcmd/PROVENANCE.md.
#
# The eswin platform/probe layer (vc8000e_driver.c) is EIC7700-specific (DT
# vcmd-core bindings, SMMU SID, eswin clk/reset/pm) and is NOT used; the AX630C
# platform layer is our own vc8000-vcmd/ax630c_vcmd_glue.c.
#
# Milestone (this derivation): the .ko cross-compiles cleanly against our 4.19
# tree. On-device load/bring-up is follow-on work (PROVENANCE.md "Remaining").
# ---------------------------------------------------------------------------

let
  # Match kernel.nix exactly: oldest cross GCC in nixpkgs that builds 4.19.
  crossCC = crossPkgs.buildPackages.gcc13;
  crossBinutils = crossPkgs.buildPackages.binutils;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;

  kernelSubdir = "linux/linux-4.19.125";
  defconfig = "axera_AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig";
  release = "4.19.125";
in
pkgs.stdenv.mkDerivation {
  pname = "vc8000-vcmd";
  version = "0.1.0-ax630c";

  # The module tree (eswin sources + our AX630C glue + Makefile + provenance).
  src = ./vc8000-vcmd;

  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;

  nativeBuildInputs = [
    crossCC
    crossBinutils
  ] ++ (with pkgs; [
    gnumake bc bison flex openssl ncurses perl elfutils kmod cpio
    gzip lzop which gawk bash
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

    # Writable copy of the kernel tree; configure + modules_prepare only (no
    # full vmlinux) is enough to build an external module. MODVERSIONS is off in
    # the defconfig (see kernel.nix), so no Module.symvers CRC gate applies.
    cp -a "${maix_ax620e_sdk_kernel}" "$TMPDIR/kernel"
    chmod -R u+w "$TMPDIR/kernel"
    KROOT="$TMPDIR/kernel/${kernelSubdir}"
    cd "$KROOT"
    make ${defconfig}
    make -j$NIX_BUILD_CORES modules_prepare

    # Writable copy of our module tree, then the out-of-tree M= build.
    cp -a "$src" "$TMPDIR/mod"
    chmod -R u+w "$TMPDIR/mod"
    make -j$NIX_BUILD_CORES -C "$KROOT" M="$TMPDIR/mod" \
      KBUILD_MODPOST_WARN=1 modules

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp "$TMPDIR/mod/ax630c_venc_vcmd.ko" "$out/ax630c_venc_vcmd.ko"
    echo "Built module:"
    ls -l "$out"/*.ko
    ${crossBinutils}/bin/${crossPrefix}nm "$TMPDIR/mod/ax630c_venc_vcmd.ko" >/dev/null || true
    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "Open VeriSilicon VC8000E VCMD driver (eswin EIC7X) ported out-of-tree to the AX630C 4.19 kernel";
    license = with pkgs.lib.licenses; [ mit gpl2Only ];
    platforms = pkgs.lib.platforms.linux;
  };
}
