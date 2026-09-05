{ pkgs, ... }:

# The rate-controller proof for the open VC8000E encoder (#46).
#
# vcenc_rc.h is the from-scratch frame-level CBR/VBR controller that feeds
# per-frame QPs to the fixed-QP register program. This derivation compiles it
# NATIVELY (it is SDK-free by construction, libm only) with a test that
# (1) replays every vendor trajectory committed under
# docs/reference/vcenc-open/ (the 47 real-desktop CBR/VBR/retarget runs of
# vendor-diff-rc-20260905, the synthetic E6/H8 runs, and any *_trajectory.csv
# with a vdrive .log sibling added later -- no change here needed) and
# compares the controller's QP decisions to the vendor's, and (2) runs
# closed-loop simulations against size models measured on the real desktop
# at 2/8/16 Mbps for both codecs, plus a mid-stream retarget, a complexity
# burst and VBR.
#
#   nix build .#checks.x86_64-linux.open-venc-rc -L
#
# Only the trajectory CSVs and their vdrive logs are copied into the sandbox
# (the reference tree also holds register dumps and bitstreams).

let
  lib = pkgs.lib;
  vectors = lib.fileset.toSource {
    root = ../docs/reference/vcenc-open;
    fileset = lib.fileset.fileFilter
      (f: lib.hasSuffix "_trajectory.csv" f.name || lib.hasSuffix ".log" f.name)
      ../docs/reference/vcenc-open;
  };
in
pkgs.stdenv.mkDerivation {
  pname = "vcenc-rc-test";
  version = "0.1.0";

  src = ./vcenc-ewl;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -Werror -std=gnu17 -I. \
      tests/vcenc_rc_test.c -lm -o vcenc_rc_test
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ./vcenc_rc_test ${vectors} | tee vcenc-rc.log
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp vcenc_rc_test vcenc-rc.log "$out/"
    runHook postInstall
  '';

  meta.description =
    "Host-native proof of the from-scratch VC8000E rate controller (#46)";
}
