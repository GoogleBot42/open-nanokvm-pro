{ pkgs, crossPkgs }:

# Shared helpers/notes for the four boot-chain derivations. The AX620E SDK does
# NOT build the boot components in isolation the way a clean Nix derivation
# wants -- everything is orchestrated by the top-level `build/` Makefile with a
# PROJECT variable, pulling shared config from build/config.mak +
# build/projects/AX630C_emmc_arm64_k419_sipeed_nanokvm/{partition_ab,project}.mak
# (image addresses, partition sizes, SUPPORT_OPTEE=TRUE, CROSS prefix).
#
# Canonical vendor invocation (from SDK README):
#   cd build && make p=AX630C_emmc_arm64_k419_sipeed_nanokvm clean all install axp -j8
#
# Cross prefix the SDK expects (build/cross_arm64_glibc.mak):
#   CROSS := aarch64-none-linux-gnu-
# nixpkgs cross prefix (what we actually have):
#   ${crossPkgs.stdenv.cc.targetPrefix}   (aarch64-unknown-linux-gnu-)
# => every boot derivation must pass CROSS_COMPILE explicitly to override the
#    vendor default, OR symlink a `aarch64-none-linux-gnu-*` alias set.
#
# GCC: vendor documents gcc-arm-9.2 for boot; TF-A 2.7 / U-Boot 2020.04 /
# OP-TEE 3.21 build fine with GCC 9-12. Prefer nixpkgs gcc12 cross to match the
# app-layer ARM 12.2 toolchain. FLAG: not yet validated against very new GCC.

rec {
  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;
  vendorCross = "aarch64-none-linux-gnu-";

  # Common native build-time deps the SDK boot Makefiles want.
  nativeBuildInputs = with pkgs; [
    gnumake
    bison
    flex
    bc
    ncurses # menuconfig
    openssl # signing / mkimage
    ubootTools # mkimage
    dtc # device-tree-compiler
    python3
    perl
  ];

  # Emit a uniform "this is a documented stub" build failure with the real plan.
  # Usage in a derivation's buildPhase:  ${stubNote "u-boot" ''<plan text>''}
  stubNote = component: plan: ''
    cat >&2 <<'EOF'
    ============================================================================
    STUB: boot component "${component}" is not built in this structure pass.
    This derivation evaluates and documents the real build; it does not yet
    produce a bootable artifact. See the plan below and remove this guard when
    wiring the real build.

    ${plan}
    ============================================================================
    EOF
    exit 1
  '';
}
