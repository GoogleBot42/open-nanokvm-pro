{ pkgs, crossPkgs, maix_ax620e_sdk, ... }:

# ---------------------------------------------------------------------------
# U-Boot 2020.04 (BL33) + FDL2 download loader. REAL build in ./boot.nix.
# This selector exposes the signed U-Boot A/B images + the FDL2 agent.
#
# Source: maix_ax620e_sdk/boot/uboot/u-boot-2020.04, defconfig
# AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig (patched by the vendor
# config2defconfig.py with project.mak vars). For this eMMC project
# FDL2_UBOOT_COMPILE_INDEPENDENT is unset, so ONE u-boot build yields both the
# UBOOT partition image (gzip+signed) and fdl2 (ungzipped u-boot, the AXDL
# download agent). Toolchain: aarch64 cross gcc13 + NATIVE HOSTCC=gcc; needs
# the `/bin/pwd`->`pwd` fix. See boot.nix header.
#
# Outputs (into $out): u-boot_signed.bin (p5), u-boot_b_signed.bin (p6),
# fdl2_signed.bin (host flasher). NOTE: the default U-Boot environment image
# for the ENV partition (p7) is not emitted separately by this build; the ENV
# partition is populated by the image layer (default env is baked into U-Boot).
# ---------------------------------------------------------------------------

let
  boot = import ./boot.nix { inherit pkgs crossPkgs maix_ax620e_sdk; };
in
pkgs.runCommand "nanokvm-pro-boot-uboot"
{
  inherit boot;
  meta = {
    description = "NanoKVM-Pro U-Boot 2020.04 BL33 + FDL2 (from source, signed)";
    platforms = [ "x86_64-linux" ];
  };
}
  ''
    mkdir -p "$out"
    cp "${boot}/images/u-boot_signed.bin"   "$out/"
    cp "${boot}/images/u-boot_b_signed.bin" "$out/"
    cp "${boot}/images/fdl2_signed.bin"     "$out/"
  ''
