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
  };

  config = lib.mkIf cfg.enable {
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
