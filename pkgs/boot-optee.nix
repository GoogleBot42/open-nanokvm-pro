{ pkgs, crossPkgs, maix_ax620e_sdk, ... }:

# ---------------------------------------------------------------------------
# OP-TEE OS (BL32, secure world). REAL build lives in ./boot.nix (shared).
# This selector exposes the signed OP-TEE image.
#
# Source: maix_ax620e_sdk/boot/optee/optee_os-3.21.0, PLATFORM=axera-ax620e
# CFG_ARM64_core=y, OPTEE_BIN_NAME=tee-pager_v2. Toolchain: aarch64 cross
# gcc13 (CROSS_COMPILE64); needs python3 cryptography + pyelftools, bash, and
# shebang patching. See boot.nix header. SUPPORT_OPTEE=TRUE also gates the ATF
# firewall config, so ATF and OP-TEE are a matched pair.
#
# Output (into $out): optee_signed.bin. The image layer writes it to BOTH the
# optee (p8) and optee_b (p9) 1M partitions.
# ---------------------------------------------------------------------------

let
  boot = import ./boot.nix { inherit pkgs crossPkgs maix_ax620e_sdk; };
in
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
