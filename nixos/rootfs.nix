{ pkgs
, crossPkgs
, inputs
, kvm-encoder
, nanokvm-server # MUST be the gpioBackend = "libgpiod" build -- see flake.nix
, nanokvm-gpio
, nanokvm-web
, nanokvm-display
, version ? "0.0.0-dev"
, applianceModules ? [ ]
, variant ? "emmc"
  # The .axp builder (nixos/axp-image.nix), or null. Handed to the module
  # system through specialArgs so nixos/image-axp.nix can define
  # `system.build.axpImage` in terms of this configuration's own closure --
  # see that file for why it cannot simply import it.
, imageBuilder ? null
, ...
}:

# ===========================================================================
# The NanoKVM-Pro NixOS appliance (issue #78, epic #26) -- nixos/appliance.nix
# evaluated into a system closure, packed into a rootless ext4, with the
# stage-1 initrd exposed separately so pkgs/kernel-mainline.nix can embed it.
#
# ONE nixpkgs pin. The predecessor of this file evaluated against a second,
# older pin (nixos-24.11) because systemd's declared kernel floor had risen
# above the vendor's Linux 4.19.125 while the prebuilt ax_*.ko blobs held the
# kernel there. Both halves of that argument are gone: the image has carried no
# vendor kernel module since #54, and the kernel is now mainline 7.1.x, well
# above systemd's 5.10 minimum. So `nixpkgs-rootfs` is retired and this
# evaluates against the same unstable pin as everything else -- which also
# retires the "two glibcs, one loader" hazard docs/nixos-rootfs.md warns about.
#
# BUILD MODEL: the appliance is evaluated as a NATIVE aarch64-linux system and
# built through binfmt/qemu-user emulation (this host has
# `extra-platforms = aarch64-linux`). Almost the whole closure substitutes from
# cache.nixos.org, so emulation only pays for the handful of tiny system
# derivations. The ext4 itself is packed by nixpkgs' make-ext4-fs on the BUILD
# machine -- `fakeroot mkfs.ext4 -d`, no root and no loop mount, the same
# constraint that forced the debugfs surgery in pkgs/rootfs.nix.
#
# THE BOOT CONTRACT this image owes the boot chain (docs/mainline-port.md
# section 5, and section 8's #78 entry):
#
#   U-Boot `booti`s our Image, which carries the NixOS initrd inside it. The
#   command line comes from the U-Boot ENVIRONMENT -- not from the device tree,
#   which fdt_chosen overwrites -- so we cannot put `init=` on it. NixOS stage 1
#   then falls back to its built-in default, `switch_root $targetRoot /init`.
#   Hence /init at the root of this image, pointing at the system profile.
#   Updating that profile is therefore the whole of a generation switch: no
#   bootloader, no config file, no partition write.
#
# The artifacts themselves -- the initrd cpio and the ext4, with all their
# offline contract checks -- live in nixos/lib/appliance-artifacts.nix, as pure
# functions of the system closure. They are called from here (flake level) and
# from nixos/image-axp.nix (inside the module system, where the .axp builder
# needs them); being pure functions, both routes land on the same store paths.
# ===========================================================================

let
  lib = pkgs.lib;
  nixpkgs = inputs.nixpkgs;

  artifacts = import ./lib/appliance-artifacts.nix { inherit pkgs nixpkgs; };

  nanokvm = {
    inherit kvm-encoder nanokvm-server nanokvm-gpio nanokvm-web nanokvm-display
      version;
    image = imageBuilder;
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

  eval = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = null; # set via nixpkgs.hostPlatform in the module
    modules = [ ./appliance.nix ] ++ applianceModules;
    specialArgs = { inherit nanokvm; };
  };

  toplevel = eval.config.system.build.toplevel;

  initrd = artifacts.mkInitrd {
    inherit (eval.config.system.build) initialRamdisk;
    inherit (eval.config.system.boot.loader) initrdFile;
  };
in
(artifacts.mkRootfs {
  inherit toplevel initrd version variant;
  rootDevice = eval.config.fileSystems."/".device;
}).overrideAttrs (_: {
  passthru = {
    inherit toplevel initrd eval;
    inherit (eval) config;
  };
})
