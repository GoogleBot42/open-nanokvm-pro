{ pkgs, ... }:

# Open VC8000E userspace submitter -- the userspace half of the blob-free
# encoder (#45), built from source with NO vendor library.
#
# Stage A (ewl_probe, DONE + device-proven 2026-08-30): drives the full open
# VCMD cmdbuf lifecycle from userspace against /dev/es_venc --
# GET_VCMD_PARAMETER -> GET_CMDBUF_PARAMETER -> mmap pools -> RESERVE -> build a
# register-readback cmdbuf (the driver's own minimal known-good program) ->
# LINK_RUN -> WAIT -> read the encoder core register file back out of the status
# pool. PASS = WAIT OK and status swreg0 == 0x90101010 (encoder core ASIC ID).
# This proves the ioctl/cmdbuf ABI, the mmap path, hardware execution, IRQ
# completion, and status readback -- everything a real IDR (Stage B) builds on.
#
# The ABI is transcribed from the open driver (pkgs/vc8000-vcmd) in
# vcmd_abi.h; the cmdbuf layout in vcenc_cmdbuf.h matches the driver's
# create_read_all_registers_cmdbuf word-for-word.
#
# Static musl aarch64 so it runs on the device with no runtime deps:
#   nix build .#vcenc-ewl -L
#   tools/kvmscp result/bin/ewl_probe /tmp/ ; tools/kvmssh /tmp/ewl_probe
# (Run against the open driver: stop nanokvm, rmmod ax_venc/ax_jenc, insmod
#  ax630c_venc_vcmd.ko first -- see docs/vcmd-cma-unblock.md.)

let
  # Static musl aarch64 -- a self-contained device binary with no runtime deps.
  # (pkgsCross.aarch64-multiplatform-musl is cache-backed; a from-source musl
  # cross-libc is not.)
  xpkgs = pkgs.pkgsCross.aarch64-multiplatform-musl;
  muslCC = xpkgs.stdenv.cc;
  prefix = xpkgs.stdenv.cc.targetPrefix;
in
pkgs.stdenv.mkDerivation {
  pname = "vcenc-ewl";
  version = "0.1.0";

  src = ./vcenc-ewl;

  nativeBuildInputs = [ muslCC ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    # Stage A: submission-path prover (register readback).
    ${prefix}cc -static -O2 -Wall -Wextra -std=gnu11 -I. \
      ewl_probe.c -o ewl_probe
    # Stage B: real 1080p fixed-QP IDR encode.
    ${prefix}cc -static -O2 -Wall -std=gnu11 -I. \
      ewl_encode.c -o ewl_encode
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin"
    cp ewl_probe ewl_encode "$out/bin/"
    runHook postInstall
  '';

  # Confirm we actually produced static aarch64 ELFs (so a silent host-cc
  # fallback can't ship an x86 binary that "runs" in CI but not on the device).
  doInstallCheck = true;
  installCheckPhase = ''
    for b in ewl_probe ewl_encode; do
      ${prefix}readelf -h "$out/bin/$b" | grep -q AArch64 \
        || { echo "ERROR: $b is not an AArch64 ELF" >&2; exit 1; }
    done
  '';

  meta = {
    description = "Open VC8000E userspace VCMD submitter (blob-free encoder, #45)";
    platforms = pkgs.lib.platforms.linux;
  };
}
