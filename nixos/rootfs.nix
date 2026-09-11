{ pkgs
, inputs
  # nixos/nanokvm-modules.nix -- the flake's `nixosModules`. This file
  # evaluates `nanokvm-pro` (every hardware module plus this flake's cross
  # builds) together with nixos/appliance.nix, which is only our policy.
, nanokvmModules
, version ? "0.0.0-dev"
, applianceModules ? [ ]
, variant ? "emmc"
, ...
}:

# ===========================================================================
# The NanoKVM-Pro NixOS appliance (issue #78, epic #26) --
# `nixosModules.nanokvm-pro` + nixos/appliance.nix evaluated into a system
# closure, packed into a rootless ext4, with the /boot tree that generation
# boots from exposed beside it.
#
# SINCE #87 THE HARDWARE IS A MODULE SET, not one file. nixos/modules/ holds
# nine modules -- kernel, identity, rollback, video, display, atx, wifi,
# updates, server -- with no host-specific values in any of them, and
# nixos/appliance.nix is what makes a board running them OUR appliance.
# Anybody can build their own image from the same modules; docs/modules.md.
#
# ONE nixpkgs pin. The predecessor of this file evaluated against a second,
# older pin (nixos-24.11) because systemd's declared kernel floor had risen
# above the vendor's Linux 4.19.125 while the prebuilt ax_*.ko blobs held the
# kernel there. Both halves of that argument are long gone, and since #97 so is
# the 4.19 image itself: the kernel is mainline 7.1.x, well above systemd's
# 5.10 minimum, and this evaluates against the same unstable pin as everything
# else.
#
# BUILD MODEL: the appliance is evaluated as a NATIVE aarch64-linux system and
# built through binfmt/qemu-user emulation (this host has
# `extra-platforms = aarch64-linux`). Almost the whole closure substitutes from
# cache.nixos.org, so emulation only pays for the handful of tiny system
# derivations. The ext4 itself is packed by nixpkgs' make-ext4-fs on the BUILD
# machine -- `fakeroot mkfs.ext4 -d`, no root and no loop mount.
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
  nixpkgs = inputs.nixpkgs;

  artifacts = import ./lib/appliance-artifacts.nix { inherit pkgs nixpkgs; };

  eval = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = null; # set via nixpkgs.hostPlatform in the module
    modules = [ nanokvmModules.nanokvm-pro ./appliance.nix ] ++ applianceModules;
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
