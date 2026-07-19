{ pkgs, crossPkgs, ... }:

# ---------------------------------------------------------------------------
# Cross toolchain bundle for the NanoKVM-Pro (AX630C, aarch64, glibc).
#
# The AX630C is a stock ARMv8-A Cortex-A53, so nixpkgs' stock aarch64 cross GCC
# suffices for every from-source component -- no exotic toolchain is needed. The
# kernel and the full boot chain build with cross gcc13 (see kernel.nix /
# boot.nix); the app layer (Go+cgo) and libkvm build with crossPkgs.stdenv.cc.
#
# This derivation is just a convenience bundle so the devShell and docs have one
# place that names the toolchain; it does not build a GCC from source. The
# vendor triple (aarch64-none-linux-gnu-) and the nixpkgs triple
# (aarch64-unknown-linux-gnu-) share the same ABI and differ only as strings, so
# anything that greps the triple (kernel CROSS_COMPILE, boot Makefiles) must be
# passed our prefix explicitly.
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
