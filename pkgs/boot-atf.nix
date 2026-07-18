{ pkgs, crossPkgs, maix_ax620e_sdk, ... }:

# ---------------------------------------------------------------------------
# ARM Trusted Firmware BL31. REAL build lives in ./boot.nix (shared).
# This selector exposes the signed ATF A/B partition images.
#
# Source: maix_ax620e_sdk/boot/atf/arm-trusted-firmware-2.7, PLAT=ax620e
# SPD=opteed (SUPPORT_OPTEE=TRUE). Toolchain: aarch64 cross gcc13; needs the
# binutils-2.46 `--no-warn-rwx-segments` fix (TF-A 2.7 forces
# -Wl,--fatal-warnings). See boot.nix header.
#
# Outputs (into $out): atf_bl31_signed.bin (p3), atf_b_bl31_signed.bin (p4).
# ---------------------------------------------------------------------------

let
  boot = import ./boot.nix { inherit pkgs crossPkgs maix_ax620e_sdk; };
in
pkgs.runCommand "nanokvm-pro-boot-atf"
{
  inherit boot;
  meta = {
    description = "NanoKVM-Pro ARM Trusted Firmware BL31 (TF-A 2.7, ax620e, signed)";
    platforms = [ "x86_64-linux" ];
  };
}
  ''
    mkdir -p "$out"
    cp "${boot}/images/atf_bl31_signed.bin"   "$out/"
    cp "${boot}/images/atf_b_bl31_signed.bin" "$out/"
  ''
