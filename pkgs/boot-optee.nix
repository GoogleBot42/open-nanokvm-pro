{ pkgs, boot, ... }:

# OP-TEE OS (BL32, secure world). Thin selector over the shared boot chain
# (pkgs/boot.nix); exposes the signed OP-TEE image.
#
# Output (into $out): optee_signed.bin. The image layer writes it to BOTH the
# optee (p8) and optee_b (p9) 1M partitions.

pkgs.runCommand "nanokvm-pro-boot-optee"
{
  inherit boot;
  meta = {
    description = "NanoKVM-Pro OP-TEE OS 3.21.0 BL32 (axera-ax620e, signed)";
    platforms = [ "x86_64-linux" ];
  };
}
  ''
    mkdir -p "$out"
    cp "${boot}/images/optee_signed.bin" "$out/"
  ''
