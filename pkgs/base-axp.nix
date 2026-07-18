{ pkgs, ... }:

# ===========================================================================
# Vendor NanoKVM-Pro release .axp  (the OVERLAY base).
#
# The .axp is a plain ZIP shipped on the NanoKVM-Pro releases page. It contains
# the full stock 17-partition image set, including:
#   ubuntu_rootfs_sparse.ext4   <- the vendor Ubuntu-arm64 rootfs (Android sparse)
#   bootfs.fat32                <- the /boot vfat partition
#   boot_signed.bin[.1]         <- stock kernel partition image (A/B)
#   u-boot_signed.bin / u-boot_b_signed.bin
#   AX630C_..._signed.dtb[.1]   <- stock dtb (A/B)
#   ddrinit/spl/atf/optee/logo/env images + the partition XML
#
# We use it as the BASE for the overlay: pkgs/rootfs.nix pulls the rootfs out of
# it and swaps in our libkvm + kernel modules; pkgs/image.nix swaps in our
# boot/kernel/dtb partition images and the overlaid rootfs (build_image.py flow).
#
# ---------------------------------------------------------------------------
# PIN: fixed-output derivation. The URL is the pinned v1.0.15 release asset and
# the sha256 was computed by streaming the asset through sha256sum
# (curl -sL <url> | sha256sum), NOT stored in-tree (it is 1.4 GB).
#
#   asset : 20260529_NanoKVMPro_1_0_15.axp   (1428 MB)
#   sha256: 201d9404e37224a6533e85d7d8e585f69259955f867ce0f7371d03d969ab5f30
#
# To re-pin a different release:
#   nix-prefetch-url <url>            # or: curl -sL <url> | sha256sum
#   nix hash convert --to sri --hash-algo sha256 <hex>
# and drop the SRI value into `hash` below.
# ===========================================================================

let
  version = "1.0.15";
  asset = "20260529_NanoKVMPro_1_0_15.axp";
in
pkgs.fetchurl {
  name = "nanokvm-pro-base-${version}.axp";
  url = "https://github.com/sipeed/NanoKVM-Pro/releases/download/v${version}/${asset}";
  # Real, verified sha256 of the v1.0.15 asset (streamed hash, see header).
  hash = "sha256-IB2UBONyJKZTPoXX2OWF9pJZlV+GfOD3Nx0D2WmrXzA=";

  meta = {
    description = "Vendor NanoKVM-Pro v${version} release .axp (overlay base; ZIP of the stock 17-partition image set incl. ubuntu_rootfs_sparse.ext4)";
    # Vendor firmware bundle: Ubuntu (GPL/misc) rootfs + Axera images. Redistribution
    # per Sipeed's public release. Treated as an opaque pinned base here.
    platforms = pkgs.lib.platforms.linux;
  };
}
