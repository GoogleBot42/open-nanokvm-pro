{ pkgs, crossPkgs, ... }:

# ---------------------------------------------------------------------------
# Cross toolchain(s) for the NanoKVM-Pro (AX630C, aarch64, glibc).
#
# Unlike the SG2002/T-Head RISC-V target (which needs a custom xthead GCC with
# the v0.7 vector extension + musl), the AX630C is a stock ARMv8-A Cortex-A53.
# Stock aarch64 GCC from nixpkgs is sufficient for every from-source component:
#   - app layer (Go + cgo, glibc) -> crossPkgs.stdenv.cc
#   - libkvm encoder (C, glibc)    -> crossPkgs.stdenv.cc
#
# This derivation is just a convenience bundle so the devShell and the docs
# have one place that names the toolchain. It intentionally does NOT build a
# GCC from source (nixpkgs already provides a reproducible cross GCC).
#
# ---- GCC-version caveats to carry into the heavy derivations -------------
#
# 1. Kernel (Linux 4.19.125): 4.19 predates GCC 10+ default `-fno-common` and
#    trips several `-Werror` sites and asm-goto assumptions with very new GCC.
#    Vendor SDK builds it with the ARM GNU toolchain (see below). RECOMMENDATION:
#    build the kernel with an OLDER cross GCC (nixpkgs `gcc9`/`gcc10` era, e.g.
#    `pkgsCross.aarch64-multiplatform.buildPackages.gcc10`) or the vendor
#    ARM 12.2 toolchain, NOT bleeding-edge GCC 14+. FLAG: exact version to be
#    settled when kernel.nix is made real (try gcc12 first, fall back to gcc10).
#
# 2. Boot chain: the vendor documents gcc-arm-9.2 for the boot components, and
#    the app-layer build.sh pins ARM GNU toolchain 12.2.rel1
#    (aarch64-none-linux-gnu). TF-A 2.7 / U-Boot 2020.04 / OP-TEE 3.21 are all
#    known-good with GCC 9-12. Prefer the same 12.2 vendor toolchain for the
#    whole boot chain to match upstream exactly; nixpkgs gcc12 cross is the
#    from-source equivalent.
#
# 3. The vendor "bare" toolchain triple is `aarch64-none-linux-gnu` (ARM GNU).
#    nixpkgs cross uses `aarch64-unknown-linux-gnu`. Same ABI (AArch64 LP64,
#    glibc); only the triple string differs. Anything that greps the triple
#    (kernel CROSS_COMPILE, boot Makefiles) must be told our triple explicitly.
# ---------------------------------------------------------------------------

let
  cc = crossPkgs.stdenv.cc; # aarch64 glibc cross gcc + binutils wrapper
in
pkgs.buildEnv {
  name = "nanokvm-pro-cross-toolchain";
  paths = [
    cc
    cc.bintools
  ];
  meta = {
    description = "aarch64-linux-gnu cross toolchain bundle for NanoKVM-Pro (stock GCC)";
    # Record the CROSS_COMPILE prefix the heavy derivations should export.
    longDescription = ''
      CROSS_COMPILE prefix (nixpkgs): ${cc.targetPrefix}
      Vendor triple (app build.sh):   aarch64-none-linux-gnu-
      Vendor ARM GNU toolchain:       12.2.rel1 (config.ini in NanoKVM-Pro/support)
    '';
  };
}
