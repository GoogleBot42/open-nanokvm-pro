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
# copy /dev/shm/kvmapp/scripts/usbdev.sh, resolve to the same file.
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
    # The NAME is load-bearing. nixpkgs' `useDHCP` puts a DHCP CLIENT on every
    # `Type=ether` link through 99-ethernet-default-dhcp.network, and the
    # gadget's usb0 is Type=ether with no Kind -- it matches. networkd uses the
    # first file in lexical order, so 40- wins; without it the KVM would ask
    # the host for an address on the link it is supposed to be serving.
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
    # A getty on /dev/ttyGS0 for as long as the node exists. systemd's tty
    # rules tag every tty[a-zA-Z]* node, so ttyGS0 is a device unit, and a
    # .wants on it starts the getty when usbdev.sh binds acm.usb0. The
    # serial-getty@ template BindsTo= its device, so the server's
    # stop/start cycle stops and restarts it with the function. Without
    # /boot/usb.acm the device never appears and the unit is never started:
    # inactive, not failed, so it needs no `markGood.tolerateFailed` entry --
    # and an agetty that genuinely dies still shows as failed.
    #
    # `asDropin`, or NixOS writes serial-getty@ttyGS0.service as a full unit
    # file -- an [Install] and an environment, no ExecStart -- and an instance
    # file shadows its template, so the getty would be a unit systemd refuses
    # to load (seen in the first build, 2026-10-17).
    systemd.services."serial-getty@ttyGS0" = {
      overrideStrategy = "asDropin";
      wantedBy = [ "dev-ttyGS0.device" ];
    };

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
