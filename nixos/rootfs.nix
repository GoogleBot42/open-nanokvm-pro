{ pkgs
, crossPkgs
, inputs
, kvm-encoder
, nanokvm-server # MUST be the gpioBackend = "libgpiod" build -- see flake.nix
, nanokvm-gpio
, nanokvm-web
, nanokvm-display
, kernel # pkgs/kernel-mainline.nix, no embedded initramfs -- boot.kernelPackages
, dtb # pkgs/dtb-mainline.nix -- hardware.deviceTree.dtbSource
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
# evaluated into a system closure, packed into a rootless ext4, with the /boot
# tree that generation boots from exposed beside it.
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
#   U-Boot's `bootcmd` runs `sysboot` on /boot/extlinux/extlinux.conf, which
#   NixOS's own generic-extlinux-compatible builder wrote. It names this
#   generation's kernel, initrd and dtb under /boot/nixos/, and pins
#   `init=<generation>/init` on the APPEND line -- so a generation switch IS a
#   /boot write, done by `switch-to-configuration boot` and by nothing else.
#   /init at the root of this image still points at the system profile, as a
#   backstop for a command line that carries no `init=`.
#
# The artifacts themselves -- the /boot tree and the ext4, with all their
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
      kernel dtb version;
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

  # The /boot this generation carries, written by NixOS's own extlinux builder
  # against the three options that shape it -- so the image's /boot and the one
  # `switch-to-configuration boot` writes on the device cannot disagree.
  bootDir = artifacts.mkBootDir {
    inherit toplevel;
    inherit (eval.config.boot.loader.generic-extlinux-compatible) configurationLimit;
    inherit (eval.config.boot.loader) timeout;
    dtbName = eval.config.hardware.deviceTree.name;
  };
in
(artifacts.mkRootfs {
  inherit toplevel bootDir version variant;
  rootDevice = eval.config.fileSystems."/".device;
}).overrideAttrs (_: {
  passthru = {
    inherit toplevel bootDir eval;
    inherit (eval) config;
  };
})
