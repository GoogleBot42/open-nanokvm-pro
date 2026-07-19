{ pkgs, boot, ... }:

# FSBL / BL1 = SPL (incl. open DDR init/training) + FDL1 download agent.
# Thin selector over the shared boot chain (pkgs/boot.nix); exposes just the
# SPL/DDR-init/FDL1 artifacts.
#
# Outputs (into $out): spl_<project>_signed.bin (p1, 768K slot),
# spl_<project>_enc_signed.bin (AES-encrypted variant), ddrinit_<project>_
# signed.bin (p2, empty payload -- DDR init is linked into the SPL for AX630C),
# and fdl_<project>_signed.bin (FDL1, used by the AXDL host flasher).

let
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
