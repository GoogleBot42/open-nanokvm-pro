{ pkgs, crossPkgs, maix_ax620e_sdk, ... }:

# ---------------------------------------------------------------------------
# FSBL / BL1 = SPL (incl. open DDR init/training) + FDL1 download agent.
# REAL build lives in ./boot.nix (whole boot chain, one shared derivation).
# This is a thin selector exposing just the SPL/DDRINIT/FDL1 artifacts.
#
# Source: maix_ax620e_sdk/boot/bl1 (board/meminit + driver/ddr/* DDR training,
# core/boot/boot.c loader). Toolchain: aarch64 cross gcc13, bare-metal, built
# with -Wno-error (gcc13 array-bounds false positives). See boot.nix header.
#
# Outputs (into $out): spl_<project>_signed.bin (p1, 768K slot),
# spl_<project>_enc_signed.bin (AES-encrypted variant), ddrinit_<project>_
# signed.bin (p2, empty payload -- DDR init is linked into the SPL for AX630C),
# and fdl_<project>_signed.bin (FDL1, used by the AXDL host flasher).
# ---------------------------------------------------------------------------

let
  boot = import ./boot.nix { inherit pkgs crossPkgs maix_ax620e_sdk; };
  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";
in
pkgs.runCommand "nanokvm-pro-boot-fsbl"
{
  inherit boot;
  meta = {
    description = "NanoKVM-Pro FSBL/BL1: SPL + open DDR init + FDL1 (from source, signed)";
    platforms = [ "x86_64-linux" ];
  };
}
  ''
    mkdir -p "$out"
    cp "${boot}/images/spl_${project}_signed.bin"      "$out/"
    cp "${boot}/images/spl_${project}_enc_signed.bin"  "$out/"
    cp "${boot}/images/ddrinit_${project}_signed.bin"  "$out/"
    cp "${boot}/images/fdl_${project}_signed.bin"      "$out/"
  ''
