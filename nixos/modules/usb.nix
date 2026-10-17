{ config, lib, pkgs, nanokvm, ... }:

# ===========================================================================
# usb: the gadget the KVM presents to the host (#82, policy half).
#
# The controller side has been done since 2026-09-07 -- the dwc3 glue in the
# kernel tree, `USB_CONFIGFS` and the function drivers built in -- and a host
# has enumerated a gadget off this board. What was missing until now was the
# script that assembles the gadget under /sys/kernel/config/usb_gadget/g0:
# the vendor's `usbdev.sh` shipped only in its rootfs and was never captured.
# pkgs/nanokvm-usbdev.nix is the from-source replacement; this module runs it
# at boot and puts it where the server execs it.
#
# The server is the one that RE-RUNS it: `restart` after an image is mounted
# or unmounted, `hid-only` / `restart` from the mouse menu's HID-only toggle,
# `restart` from "reset HID". That is why the script lives inside /kvmapp
# (server.nix's `kvmapp` derivation copies it to scripts/usbdev.sh) -- both
# literal paths the Go source uses, /kvmapp/scripts/usbdev.sh and its tmpfs
# copy /dev/shm/kvmapp/scripts/usbdev.sh, resolve to the same file. It also
# runs `usbdev.sh stop; touch|rm /boot/usb.{ncm,uac2}; usbdev.sh start` from
# the virtual-devices settings page, which is what the host-facing halves
# below -- usb0's DHCP server and the ttyGS0 getty -- have to survive.
#
# A failure here IS a failed unit. Unlike the radio or the panel, the gadget
# is the product: a board that cannot build one should say so in
# `systemctl --failed`, and `nanokvm-mark-good` should see it. The UDC not
# being attached is NOT a failure -- that is the cable, and the gadget is
# built and bound regardless, waiting for a host.
# ===========================================================================

let
  cfg = config.nanokvm.usb;
  usbdev = "${nanokvm.nanokvm-usbdev}/bin/usbdev.sh";
in
{
  options.nanokvm.usb = {
    enable = lib.mkEnableOption "the USB HID (+ virtual disk) gadget" // {
      default = true;
    };

    ncm.address = lib.mkOption {
      type = lib.types.str;
      default = "10.82.0.1/24";
      description = ''
        The KVM's address on `usb0`, the device end of the virtual network
        (`/boot/usb.ncm`). networkd serves DHCP on the rest of this /24, so it
        must not overlap any network the host is already on.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ---- The virtual network (ncm.usb0) ------------------------------------
    # networkd's own DHCP server rather than the udhcpd instance the vendor
    # image ran: networkd already owns every link on this appliance, it
    # starts and stops the server with usb0's carrier (the host unplugging or
    # the server's `usbdev.sh stop; ... start` cycle needs no hook), and it is
    # one .network file instead of a second daemon with its own lease file and
    # unit ordering. The file only matters while usb0 exists, so a board
    # without /boot/usb.ncm carries an inert config.
    #
    # Matched by name. networkd reports u_ether's netdev as `Type: gadget`
    # (driver g_ether, path platform-8000000.usb; measured 2026-10-17), so
    # nixpkgs' 99-ethernet-default-dhcp.network, which matches `Type=ether`,
    # leaves it alone and without this file usb0 stays `unmanaged` and DOWN.
    # The 40- prefix keeps it ahead of that file anyway: networkd applies the
    # first match in lexical order, and a DHCP client on the link this board
    # is meant to serve is the one wrong answer.
    #
    # Nothing a host learns here may change how it reaches anything else: no
    # router, no DNS, no NTP in the offer, and no RA accepted from the host, so
    # neither end gains a default route over the cable. RequiredForOnline=no
    # because the link is down whenever the host is.
    systemd.network.networks."40-usb-gadget-ncm" = {
      matchConfig.Name = "usb0";
      address = [ cfg.ncm.address ];
      networkConfig = {
        DHCPServer = true;
        IPv6AcceptRA = false;
      };
      dhcpServerConfig = {
        PoolOffset = 100;
        PoolSize = 50;
        EmitRouter = false;
        EmitDNS = false;
        EmitNTP = false;
      };
      linkConfig.RequiredForOnline = "no";
    };

    # The appliance runs no firewall; a consumer of this module that does
    # must let the DHCP requests in.
    networking.firewall.interfaces.usb0.allowedUDPPorts =
      lib.mkIf config.networking.firewall.enable [ 67 ];

    # ---- The serial console (acm.usb0) -------------------------------------
    # A getty on /dev/ttyGS0 for as long as the node exists: a udev
    # SYSTEMD_WANTS on the tty starts serial-getty@ttyGS0 when usbdev.sh binds
    # acm.usb0, and the condition below ends it when the node goes, so the
    # server's stop/start cycle takes the getty down and back with the
    # function. Without /boot/usb.acm the node never appears and the unit is
    # never started -- inactive, not failed, so it needs no
    # `markGood.tolerateFailed` entry -- while a getty that cannot run with
    # its node present still fails, visibly.
    #
    # A udev rule, NOT `systemd.services."serial-getty@ttyGS0"`. NixOS writes
    # any instance attrset as a unit (which shadows the template outright and
    # has no ExecStart) or, with `asDropin`, as serial-getty@ttyGS0.service.d/
    # overrides.conf -- the SAME file name NixOS uses for the template's own
    # ExecStart override, and a more specific drop-in of the same name
    # replaces the less specific one. The getty then ran upstream's
    # `/usr/bin/agetty` and looped on "Unable to locate executable" (the
    # second build, on hardware, 2026-10-17). The rule leaves the template
    # exactly as NixOS ships it.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="tty", KERNEL=="ttyGS0", TAG+="systemd", ENV{SYSTEMD_WANTS}+="serial-getty@ttyGS0.service"
    '';

    # BindsTo= alone does not survive the node going away. The kernel removes
    # ttyGS0, agetty takes the hangup and exits at once, and the template's
    # Restart=always (RestartSec=100ms) respawns it five times -- 208/STDIN,
    # "Failed to set up standard input" -- before udev's remove event reaches
    # systemd: start-limit-hit, a FAILED unit, `degraded`, and the re-added
    # node's start request refused for being "repeated too quickly". One
    # `usbdev.sh stop` did that on hardware (2026-10-17). A start whose
    # condition fails leaves the unit inactive and is checked before the start
    # limit, so with the node gone the respawn simply stops, and a getty that
    # dies with its node present still trips the limit and shows as failed.
    # On the template, so it merges into NixOS's own drop-in for it; every
    # other serial getty's node exists, so it is a no-op for them.
    systemd.services."serial-getty@".unitConfig.ConditionPathExists = "/dev/%I";

    systemd.services.nanokvm-usb = {
      description = "NanoKVM-Pro USB gadget (HID keyboard, mice, virtual disk)";
      wantedBy = [ "multi-user.target" ];
      # configfs is mounted by systemd's sys-kernel-config.mount; the gadget
      # must be up before the server opens /dev/hidg*.
      after = [ "sys-kernel-config.mount" ];
      requires = [ "sys-kernel-config.mount" ];
      before = [ "nanokvm.service" ];
      # Every optional function is a flag file on /boot (usb.disk0 and the
      # usb.* overrides). Without this the unit started at 14.9 s and /boot
      # mounted at 18.4 s (measured 2026-10-04), so the virtual disk the
      # server had enabled was gone after every reboot.
      unitConfig.RequiresMountsFor = [ "/boot" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${usbdev} start";
        ExecStop = "${usbdev} stop";
      };
    };

    systemd.tmpfiles.rules = lib.mkOrder 300 [
      # service/hid/status.go reads the HID-only flag from here.
      "d /dev/shm/tmp 0755 root root - -"
    ];

    environment.systemPackages = lib.mkOrder 300 [ nanokvm.nanokvm-usbdev ];
  };
}
