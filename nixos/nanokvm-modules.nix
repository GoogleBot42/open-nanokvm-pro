{ pkgs
, crossPkgs
, kvm-encoder
, nanokvm-server # pkgs/nanokvm-server.nix -- ATX over nanokvm-gpio (#81)
, nanokvm-gpio
, nanokvm-web
, nanokvm-display
, kernel # pkgs/kernel-mainline.nix, no embedded initramfs -- boot.kernelPackages
, dtb # pkgs/dtb-mainline.nix -- hardware.deviceTree.dtbSource
, video-modules # pkgs/video-modules.nix: the open capture/encode .ko set
, display-modules # pkgs/display-modules.nix: the mini-display panel .ko set (#84)
, aic8800 # pkgs/aic8800.nix: the out-of-tree WiFi modules (#85)
, aic8800-firmware # pkgs/aic8800-firmware.nix: the radio firmware (#85)
, version ? "0.0.0-dev"
, ...
}:

# ===========================================================================
# `nixosModules` (#87): this flake's cross builds, bound to the hardware
# modules in nixos/modules/, so that a stranger's flake can write
#
#   imports = [ nanokvm.nixosModules.nanokvm-pro ];
#
# and get a bootable NanoKVM-Pro without building a toolchain, a kernel or a
# device tree by hand. docs/modules.md is the consumer's guide.
#
# WHY THE PACKAGES TRAVEL AS A MODULE ARGUMENT rather than as options: they
# are a CROSS set owned by the flake (`pkgs.pkgsCross.aarch64-multiplatform`
# plus a dozen derivations of ours), not members of the `pkgs` the module
# system instantiates. `_module.args` is how NixOS carries exactly that kind
# of value, and it keeps the modules readable -- `nanokvm.kernel` rather than
# `config.nanokvm.packages.kernel` in thirty places. A consumer who wants to
# substitute one builds this set themselves; `nixosModules.packages` is the
# module that carries it, and it is a separate export for that reason.
#
# THE ATTRIBUTE SET THIS RETURNS IS `nixosModules` ITSELF. flake.nix lifts it
# verbatim, so the names here are the names a consumer types.
# ===========================================================================

let
  lib = pkgs.lib;

  # The value of the `nanokvm` module argument. Everything the hardware
  # modules read that is not an option lives here.
  packageSet = {
    inherit kvm-encoder nanokvm-server nanokvm-gpio nanokvm-web nanokvm-display
      kernel dtb video-modules display-modules version;
    inherit aic8800 aic8800-firmware;
    # The three open libraries libkvm DT_NEEDEDs, taken from crossPkgs -- the
    # exact builds it was compiled and linked against (pkgs/kvm-encoder.nix),
    # so there is no skew between what was linked and what is loaded.
    #
    # getLib on every one of them, not the bare derivation: these are
    # multi-output packages and libjpeg-turbo's FIRST output is `bin`, so
    # "${kvm-encoder.libjpeg8}/lib" is a directory that does not exist and the
    # only symptom is a `cp` with no source operand.
    opus = lib.getLib crossPkgs.libopus;
    alsaLib = lib.getLib crossPkgs.alsa-lib;
    # jpeg8 ABI, from kvm-encoder's passthru: the soft-MJPEG path (#51)
    # DT_NEEDEDs libjpeg.so.8 specifically.
    jpeg = lib.getLib kvm-encoder.libjpeg8;
  };

  # The carrier. A module of its own so that a consumer can mix and match the
  # area modules -- `imports = [ m.packages m.kernel m.video ]` -- without
  # reimplementing the package set. Import it AT MOST ONCE: `_module.args` is
  # `lazyAttrsOf raw`, so two definitions of the same argument conflict.
  packages = {
    _module.args.nanokvm = packageSet;
  };

  areas = {
    kernel = ./modules/kernel.nix;
    identity = ./modules/identity.nix;
    rollback = ./modules/rollback.nix;
    video = ./modules/video.nix;
    display = ./modules/display.nix;
    atx = ./modules/atx.nix;
    wifi = ./modules/wifi.nix;
    updates = ./modules/updates.nix;
    server = ./modules/server.nix;
  };

  # The whole board: every area module plus this flake's builds. What
  # `nixosConfigurations.nanokvm-pro` is made of, and what a consumer imports.
  nanokvm-pro = {
    imports = [ ./modules/default.nix packages ];
  };
in
areas // {
  inherit packages nanokvm-pro;
  default = nanokvm-pro;
}
