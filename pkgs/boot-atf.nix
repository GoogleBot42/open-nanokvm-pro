{ pkgs, boot, ... }:

# ARM Trusted Firmware BL31. Thin selector over the shared boot chain
# (pkgs/boot.nix); exposes the signed ATF A/B partition images.
#
# Outputs (into $out): atf_bl31_signed.bin (p3), atf_b_bl31_signed.bin (p4).

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
