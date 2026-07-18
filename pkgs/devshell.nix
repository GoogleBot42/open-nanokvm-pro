{ pkgs, crossPkgs, toolchain, ... }:

# Dev shell for working on the NanoKVM-Pro flake: cross toolchain + the native
# tools the vendor SDK / image pipeline expect. axp-tools (pip) is NOT in
# nixpkgs -- install into a venv if you need to repack .axp (see notes below).

pkgs.mkShell {
  name = "nanokvm-pro-dev";

  packages = with pkgs; [
    # cross toolchain bundle (stock aarch64 gcc + binutils)
    toolchain
    crossPkgs.stdenv.cc

    # kernel / boot build deps
    gnumake bison flex bc ncurses openssl ubootTools dtc perl

    # app layer
    go_1_25 nodejs_22 pnpm_10 patchelf

    # image / rootfs tooling
    android-tools        # img2simg / simg2img (sparse ext4)
    e2fsprogs dosfstools mtools
    qemu-user            # qemu-aarch64-static for rootfs chroot / debootstrap
    debootstrap
    zip unzip python3

    # audio dep for the Go server cgo build
    crossPkgs.libopus
  ];

  shellHook = ''
    echo "NanoKVM-Pro (AX630C) firmware flake dev shell"
    echo "  cross prefix : ${crossPkgs.stdenv.cc.targetPrefix}"
    echo "  vendor triple: aarch64-none-linux-gnu-  (pass CROSS_COMPILE to SDK)"
    echo ""
    echo "axp-tools is not packaged in nixpkgs. If you need to repack a .axp:"
    echo "    python3 -m venv .venv && . .venv/bin/activate && pip install axp-tools"
    echo ""
    echo "Vendor one-shot build (in a writable maix_ax620e_sdk clone):"
    echo "    cd build && make p=AX630C_emmc_arm64_k419_sipeed_nanokvm clean all install axp -j8"
  '';
}
