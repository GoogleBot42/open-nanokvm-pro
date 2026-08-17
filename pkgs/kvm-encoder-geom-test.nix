{ pkgs, ... }:

# The 1080p regression proof for the open capture backend (issue #17).
#
# The device can only be tested against a 1920x1080 HDMI source, so "the
# parameterized payloads are bit-identical to the device-proven 1080p
# constants" is the one property hardware can actually check. This derivation
# compiles the geometry module NATIVELY (no cross toolchain, no Axera headers --
# kvm_capture_geom.c is deliberately SDK-free) together with a test that
# byte-compares its output against the pre-#17 constants, and fails the build
# if anything differs.
#
#   nix build .#checks.x86_64-linux.open-capture-geometry -L
#   (equivalently: nix build .#kvm-encoder-geom-test -L; the log and
#    $out/geom-identity.log both carry the full per-payload result table)

pkgs.stdenv.mkDerivation {
  pname = "kvm-encoder-geom-test";
  version = "0.1.0";

  src = ./kvm-encoder/src;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -Werror -std=gnu17 -I. \
      kvm_capture_geom.c tests/geom_identity_test.c -o geom_identity_test
    runHook postBuild
  '';

  # The check phase IS the point of this derivation: a non-zero exit (any
  # payload byte, descriptor word, pool size or envelope decision that differs
  # from the reference) fails the build.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ./geom_identity_test | tee geom-identity.log
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp geom_identity_test "$out/bin/"
    cp geom-identity.log "$out/"
    runHook postInstall
  '';

  meta = {
    description = "1080p byte-identity proof for the parametric open-capture geometry (issue #17)";
    platforms = pkgs.lib.platforms.linux;
  };
}
