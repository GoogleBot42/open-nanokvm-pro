{ config, lib, pkgs, ... }:

# ===========================================================================
# OUR appliance -- the choices that make a NanoKVM-Pro running these modules
# into the thing this project ships (issue #78, epic #26; thinned by #87).
#
# THE HARDWARE IS NOT HERE ANY MORE. The kernel, the bootloader, the initrd,
# the eMMC layout, the rollback gate, the capture stack, the mini-display,
# ATX, WiFi, the updater and the server all live in nixos/modules/, one file
# per area, and are composed by `nixosModules.nanokvm-pro`
# (nixos/nanokvm-modules.nix). docs/modules.md says how to consume them; the
# boot contract and the reasoning behind each area are docs/nixos-rootfs.md
# and the module headers themselves.
#
# What is left below is policy, and it is policy a stranger building their own
# image would reasonably want to differ on: which SSH and mDNS we run, the
# root password the flashing instructions quote, how much journal an eMMC is
# allowed, and the interactive package set. `nixos/rootfs.nix` evaluates
# `nixosModules.nanokvm-pro` plus this file plus whatever variant module the
# flake asks for (the .axp image, or nixos/qemu-test.nix).
#
# NO CLOSED CODE. The shipped video stack has been blob-free since #60, and
# the `kvmapp` derivation in nixos/modules/server.nix asserts it.
# ===========================================================================

{
  # The NixOS release this system's stateful defaults were set against. Ours,
  # not the modules': a consumer building their own image picks their own.
  system.stateVersion = "26.11";

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = true;
    # MUST be false. With startWhenNeeded there is no plain `sshd.service` to
    # alias `ssh.service` onto, and the web UI's SSH-enable path
    # (StartService("ssh.service")) would fail. False gives a real persistent
    # sshd.service -- which is also what the device is reached by today. The
    # alias itself is in nixos/modules/server.nix, which is what wants it.
    startWhenNeeded = false;
  };

  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # Replaces the vendor chrony and its time.{windows,apple,google}.com host
  # list (docs/provenance.md); timesyncd talks to the NTP pool only.
  services.timesyncd.enable = true;

  networking.firewall.enable = false; # appliance on a trusted LAN, ports 22/80/443

  users.mutableUsers = true;
  # Parity with the vendor image's documented default
  # (docs/flashing-and-recovery.md). CHANGE ON FIRST BOOT.
  users.users.root.initialPassword = "sipeed";

  # eMMC is the only writable medium; an unbounded journal is what chewed
  # ~100 MB/week during the wifi.service restart loop (#43).
  services.journald.extraConfig = ''
    SystemMaxUse=32M
    RuntimeMaxUse=16M
  '';

  system.switch.enable = lib.mkDefault true;

  documentation.enable = false;
  documentation.nixos.enable = false;
}
