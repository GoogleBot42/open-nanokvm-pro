{ pkgs, crossPkgs, toolchain, axdl, ... }:

# Dev shell for working on the NanoKVM-Pro flake: cross toolchain + the native
# tools the vendor SDK / image pipeline expect.

pkgs.mkShell {
  name = "nanokvm-pro-dev";

  packages = with pkgs; [
    # cross toolchain bundle (stock aarch64 gcc + binutils)
    toolchain
    crossPkgs.stdenv.cc

    # kernel / boot build deps
    gnumake bison flex bc ncurses openssl ubootTools dtc perl

    # app layer (server / web)
    go_1_25 nodejs_22 pnpm_10 patchelf

    # image / rootfs tooling
    android-tools        # img2simg / simg2img (sparse ext4)
    e2fsprogs dosfstools mtools
    zip unzip python3

    # audio dep for the Go server cgo build
    crossPkgs.libopus

    # AXDL USB flasher (same build `nix run .#axdl` uses)
    axdl
  ];

  shellHook = ''
    echo "NanoKVM-Pro (AX630C) firmware flake dev shell"
    echo "  cross prefix : ${crossPkgs.stdenv.cc.targetPrefix}"
    echo "  vendor triple: aarch64-none-linux-gnu-  (pass CROSS_COMPILE to SDK)"
    echo ""
    echo "Build + flash (host <-USB-> AX630C in BootROM download mode):"
    echo "    nix build .#base-axp        # stock recovery .axp (or grab from Sipeed releases)"
    echo "    nix build .#firmware-image  # our from-source .axp"
    echo "    nix run .#axdl -- --file result/*.axp --wait-for-device"
    echo "  Enter download mode: remove the SD card, then hold User (~10s) while powering on."
    echo "  Non-root USB access needs the udev rule (VID:PID 32c9:1000): see"
    echo "  99-axdl.rules in the axdl-rs repo -> /etc/udev/rules.d (or run axdl as root)."
  '';
}
