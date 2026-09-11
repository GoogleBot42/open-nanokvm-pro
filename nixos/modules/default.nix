{ ... }:

# ===========================================================================
# THE NanoKVM-Pro HARDWARE MODULE SET (#87, epic #26 product 1).
#
# Nine modules, one area each, in the shape nixos-hardware uses: no
# host-specific values, every knob an option under `nanokvm.<area>.*`, and a
# header on each saying what it enables and which hardware fact it encodes.
# `nixos/appliance.nix` is one consumer of them; docs/modules.md is how to be
# another.
#
# THESE MODULES NEED PACKAGES THIS FLAKE CROSS-BUILDS -- the kernel, the
# device tree, the capture and panel modules, the server, the web UI, the
# encoder. They arrive as the module argument `nanokvm`, which
# `nixos/nanokvm-modules.nix` supplies. Import `nixosModules.nanokvm-pro`
# (this file PLUS that argument) rather than this file directly, unless you
# are supplying the packages yourself.
#
# IMPORT ORDER IS LOAD-BEARING for exactly two options -- `environment.
# systemPackages` and `systemd.tmpfiles.rules` -- because both are lists and
# both are hashed, in order, into a derivation. Each contributor wraps its
# definition in `lib.mkOrder`, so the merged order is a property of the
# modules rather than of this list.
# ===========================================================================

{
  imports = [
    ./kernel.nix
    ./identity.nix
    ./rollback.nix
    ./video.nix
    ./display.nix
    ./atx.nix
    ./wifi.nix
    ./updates.nix
    ./server.nix
  ];
}
