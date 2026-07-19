{ pkgs, boot, ... }:

# U-Boot 2020.04 (BL33) + FDL2 download loader. Thin selector over the shared
# boot chain (pkgs/boot.nix); exposes the signed U-Boot A/B images + FDL2.
#
# Outputs (into $out): u-boot_signed.bin (p5), u-boot_b_signed.bin (p6),
# fdl2_signed.bin (host flasher). The default U-Boot environment for the ENV
# partition (p7) is not emitted separately; it is baked into U-Boot and the ENV
# partition is populated by the image layer.

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
