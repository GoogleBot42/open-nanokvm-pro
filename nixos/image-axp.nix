{ builder }:

{ config, lib, pkgs, ... }:

# ===========================================================================
# `system.build.axpImage` -- the flashable .axp for THIS configuration.
#
# Shaped after the way nixpkgs exposes an image on the system it images
# (`system.build.sdImage`, `system.build.isoImage`, `image/repart.nix`): the
# image is a function of the evaluated configuration, so there is exactly one
# place that decides what gets flashed, and `nix build
# .#nixosConfigurations.nanokvm-pro.config.system.build.axpImage` and the
# flake's `.#nixos-firmware-image` are the same derivation.
#
# The heavy lifting is `builder` (nixos/axp-image.nix), applied to this file by
# the flake before the module system ever sees it. It has to arrive that way
# rather than being imported here, because it needs the flake's BUILD-HOST
# package set -- the ext4 is packed by make-ext4-fs and the boot chain is signed
# there -- while THIS module evaluates as aarch64-linux. (Until #95 that host
# also had to be x86-64, because the signing path ran the prebuilt `ax_gzip`.
# It no longer does.)
# ===========================================================================

{
  assertions = [
    {
      assertion = config.fileSystems."/".autoResize;
      message = ''
        The .axp's rootfs member is shrunk to its contents by make-ext4-fs.
        Without autoResize the appliance would run in ~1.3 GiB of a ~29 GiB
        partition forever.
      '';
    }
  ];

  # The three bootloader options are passed through rather than read inside the
  # builder, because they are what shapes the /boot tree it writes -- and the
  # same three are read by nixos/rootfs.nix at flake level. One definition,
  # two callers, one store path (#99).
  system.build.axpImage = builder {
    inherit (config.system.build) toplevel;
    # For the VENDOR-layout image's `kernel`/`kernel_b` members only. Since #99
    # that Image carries no initramfs, and the vendor U-Boot has no way to pass
    # one -- see the NOTES that image ships.
    kernelImage = "${config.boot.kernelPackages.kernel}/Image";
    inherit (config.boot.loader.generic-extlinux-compatible) configurationLimit;
    inherit (config.boot.loader) timeout;
    dtbName = config.hardware.deviceTree.name;
    rootDevice = config.fileSystems."/".device;
  };
}
