{ pkgs, ... }:

# The geometry-law proof for the open VC8000E encoder (#17).
#
# vcenc_geom.h derives every geometry-dependent register and buffer pitch of
# the fixed-QP program from (W,H). The laws were fitted against a 17-geometry
# differential of the VENDOR encoder on the real device; this derivation
# compiles the header NATIVELY (it is SDK-free by construction) with a test
# that (1) replays all 17 golden vendor vectors, (2) proves the full cmdbuf
# builder reproduces the device-proven img_qp32 template bit-for-bit at
# 1920x1080 for every non-address register, and (3) pins the envelope.
# Since #64 it also proves the H.265 overlay against 34 vendor HEVC fixed-QP
# programs (1080p ladder + six geometries) and the HEVC parameter-set writer
# against the vendor's VPS/SPS/PPS bytes.
#
#   nix build .#checks.x86_64-linux.open-venc-geometry -L

pkgs.stdenv.mkDerivation {
  pname = "vcenc-geom-test";
  version = "0.1.0";

  src = ./vcenc-ewl;

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -Werror -std=gnu17 -I. \
      tests/vcenc_geom_test.c -o vcenc_geom_test
    # HEVC VPS/SPS/PPS writer vs the vendor's parameter-set bytes (#64)
    $CC -O2 -Wall -Wextra -Werror -Wno-unused-function -std=gnu17 -I. \
      tests/hevc_header_test.c -o hevc_header_test
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    ./vcenc_geom_test | tee vcenc-geom.log
    ./hevc_header_test | tee -a vcenc-geom.log
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp vcenc_geom_test vcenc-geom.log "$out/"
    runHook postInstall
  '';

  meta.description =
    "Host-native geometry-law proof for the open VC8000E encoder (#17)";
}
