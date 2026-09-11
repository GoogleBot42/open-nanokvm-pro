{ config, lib, pkgs, ... }:

# ===========================================================================
# Per-device identity: the MAC and the hostname derived from the SoC UID, the
# DHCP client identifier that keeps the lease, and /etc/fw_env.config.
#
# ENABLES: `nanokvm-identity.service`, which reads the SoC UID out of the
# bootloader's `misc_info_t` in IRAM0, writes /device_key, and sets the
# TRANSIENT hostname and the interface MAC from its SHA-512; networkd with
# `ClientIdentifier = mac`; and the fw_printenv/fw_setenv configuration
# computed from the eMMC layout.
#
# HARDWARE FACTS IT ENCODES: every NanoKVM-Pro carries a unique 64-bit UID at
# physical 0x740 (IRAM0 is mapped at 0 on this SoC), and the vendor firmware
# has always derived the MAC and the hostname from it -- so a board that
# computes anything else loses its DHCP reservation and the address the
# tooling knows it by.
#
# THREE THINGS DECIDE THE IDENTITY AND EACH LOOKS SUFFICIENT ALONE (four
# hardware runs, one per discovery): the hostname must be set `--transient`,
# `networking.hostName` must be EMPTY or systemd-hostnamed refuses the
# transient one, and DHCP option 61 must carry the MAC rather than networkd's
# default DUID.
# ===========================================================================

let
  parts = import ../emmc-partitions.nix { inherit lib; };
  cfg = config.nanokvm;

  # ---- Per-device identity, recovered from the SoC UID -------------------
  # See the service below for the derivation and its provenance.
  identityScript = pkgs.writeShellApplication {
    name = "nanokvm-identity";
    runtimeInputs = with pkgs; [ coreutils busybox iproute2 systemd gnugrep gnused ];
    text = ''
      set -eu

      uid=""

      # 1. The vendor kernel's own node, if we happen to be on it. Format is
      #    "ax_uid: 0x<uid_h><uid_l>"; the vendor /init takes field 2 and drops
      #    the "0x". Kept first so the derivation can be validated against the
      #    value the device has always used, by running this on a vendor boot.
      if [ -r /proc/ax_proc/uid ]; then
        uid=$(awk '{print $2}' /proc/ax_proc/uid | cut -c 3-)
      fi

      # 2. Mainline: read the same two words out of the misc_info structure the
      #    boot ROM/SPL leaves in IRAM0. busybox devmem mmap()s /dev/mem, which
      #    is the only way to touch a non-System-RAM physical page.
      if [ -z "$uid" ] && [ -r /dev/mem ]; then
        hi=$(devmem ${parts.hex (cfg.identity.miscInfoPhys + 76)} 32 || echo 0)
        lo=$(devmem ${parts.hex (cfg.identity.miscInfoPhys + 72)} 32 || echo 0)
        hi=$((hi)); lo=$((lo))
        if [ "$hi" -ne 0 ] || [ "$lo" -ne 0 ]; then
          if [ "$hi" -ne 4294967295 ] || [ "$lo" -ne 4294967295 ]; then
            uid=$(printf '%08x%08x' "$hi" "$lo")
          fi
        fi
      fi

      if [ -z "$uid" ]; then
        echo "identity: no SoC UID available -- keeping the kernel's MAC and" >&2
        echo "          the default hostname. DHCP reservations will not match." >&2
        exit 0
      fi

      # /device_key is a plain file at the root of the rootfs. The server reads
      # it (service/vm/info.go) and the MAC is the hash OF THE FILE, newline
      # included -- so it is written before, and hashed exactly as, the vendor
      # /init does it.
      printf '%s\n' "$uid" > /device_key
      chmod 0644 /device_key

      mac_uid=$(sha512sum /device_key | head -c 4)
      hi_b=''${mac_uid:0:2}
      lo_b=''${mac_uid:2:2}
      mac="${cfg.identity.macPrefix}:''${hi_b}:''${lo_b}"
      host="${cfg.identity.hostnamePrefix}''${hi_b}''${lo_b}"

      echo "identity: uid=$uid mac=$mac hostname=$host"

      # --transient, and it is load-bearing. `hostnamectl set-hostname` sets the
      # STATIC hostname, which means writing /etc/hostname -- a read-only store
      # symlink on NixOS. On the first hardware boot that failed with
      # "Could not set static hostname: /etc/hostname is in a read-only
      # filesystem" and the board came up as `nanokvm`: the same
      # write-into-a-store-symlink trap the vendor's own sed hits, reproduced by
      # its replacement. The transient hostname is what gethostname(2), the
      # server, mDNS and the DHCP client all actually read.
      #
      # The option exists so a hardware run can put the ORIGINAL, broken call
      # back and isolate which of the two run-2 changes cost what. Nothing but
      # a deliberate bisect should ever set it false.
      if ! hostnamectl ${lib.optionalString cfg.identity.useTransientHostname "--transient "}set-hostname "$host"; then
        echo "identity: WARNING could not set the hostname" >&2
      fi

      for d in /sys/class/net/*; do
        ifn=$(basename "$d")
        case "$ifn" in lo|wlan*|usb*|sit*|dummy*) continue ;; esac
        [ -e "$d/device" ] || continue
        ip link set dev "$ifn" down || true
        ip link set dev "$ifn" address "$mac" || true
        ip link set dev "$ifn" up || true
        break
      done
    '';
  };
in
{
  options.nanokvm = {
    identity = {
      miscInfoPhys = lib.mkOption {
        type = lib.types.int;
        default = 1856; # 0x740
        description = ''
          Physical address of the bootloader's `misc_info_t`. IRAM0 is mapped
          at physical 0 on this SoC: the vendor driver ioremap()s the bare
          constant `MISC_INFO_ADDR` (0x740) with no base added
          (drivers/soc/axera/ax_hwinfo/ax_hwinfo.c). `uid_l` is at +0x48 and
          `uid_h` at +0x4c, after `pub_key_hash[8]`, `aes_key[8]`, `board_id`
          and `chip_type` (include/linux/soc/axera/ax_boardinfo.h).
        '';
      };
      macPrefix = lib.mkOption {
        type = lib.types.str;
        default = "48:da:35:6d";
        description = "The four fixed octets of the derived MAC.";
      };
      hostnamePrefix = lib.mkOption {
        type = lib.types.str;
        default = "kvm-";
        description = "Hostname prefix; the derived two bytes are appended.";
      };
      useTransientHostname = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Set the TRANSIENT hostname rather than the static one.

          Must stay true on any real image. `hostnamectl set-hostname` writes
          the static hostname, which means writing /etc/hostname -- a read-only
          store symlink -- and it fails; the transient hostname is what
          gethostname(2), the server, mDNS and the DHCP client read. False
          exists only so a hardware run can reproduce the original failure and
          attribute it.
        '';
      };
    };

    dhcp.clientIdentifier = lib.mkOption {
      type = lib.types.enum [ "mac" "duid" ];
      default = "mac";
      description = ''
        DHCP option 61 for the wired link. `mac` is what the vendor's udhcpc
        sends and what this device's lease has always been keyed on;
        systemd-networkd's own default, `duid`, reads as a new client and gets
        a new address. `duid` exists only so a hardware run can reproduce that
        and attribute it.
      '';
    };
  };

  config = {
    # /etc/fw_env.config -- libubootenv's fw_printenv/fw_setenv need it to
    # locate the U-Boot environment. The value is not a guess and not a device
    # capture: it is the cumulative offset and size of the `env` partition in
    # the same blkdevparts clause U-Boot itself parses, computed and asserted
    # in nixos/emmc-partitions.nix. Non-redundant, eMMC user area.
    #
    # U-Boot rewrites this environment TWICE per boot (set_slot_ab,
    # update_cmdline), so a userspace fw_setenv must not race a reboot.
    environment.etc."fw_env.config".text = parts.fwEnvConfig;

    # Per-device identity (MAC + hostname) from the SoC UID.
    #
    # The vendor initramfs derives this on EVERY boot and writes it into files
    # a NixOS root does not have: `/etc/network/interfaces` gets
    # `hwaddress ether 48:da:35:6d:HH:LL` sed-ed into it, and on a first boot
    # `/etc/hostname` becomes kvm-HHLL. Both are ifupdown/Ubuntu-shaped writes
    # into read-only store symlinks here, so both would silently fail and the
    # board would come up with a kernel-random MAC -- breaking the DHCP
    # reservation and the address tools/kvmssh knows.
    #
    # The derivation is reproduced exactly, not approximated:
    #   uid       = /proc/ax_proc/uid field 2, minus the "0x"  (vendor kernel)
    #             = printf '%08x%08x' misc_info.uid_h misc_info.uid_l (mainline)
    #   /device_key = "<uid>\n"
    #   HHLL      = first 4 hex chars of sha512sum(/device_key)
    #   MAC       = 48:da:35:6d:HH:LL      hostname = kvm-HHLL
    # so a mainline boot keeps the same MAC, the same lease and the same
    # hostname the unit has always had.
    #
    # Note this corrects a claim made while #77 was being written -- that the
    # MAC is a provisioning-time literal in /etc/network/interfaces. It is not:
    # the vendor /init recomputes it from /proc/ax_proc/uid on every single
    # boot and rewrites that line. The file is a cache, not the source.
    systemd.services.nanokvm-identity = {
      description = "Apply the NanoKVM-Pro per-device MAC and hostname (from the SoC UID)";
      # WantedBy on network-pre.target alone is passive -- nothing in this
      # closure pulls it -- so pull it from multi-user.target and only ORDER
      # against network-pre (systemd.special(7)).
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-pre.target" ];
      before = [ "network-pre.target" "systemd-networkd.service" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${identityScript}/bin/nanokvm-identity";
      };
    };

    # EMPTY, and that is the whole point. `networking.hostName = "nanokvm"`
    # writes /etc/hostname, which is a STATIC hostname -- and systemd-hostnamed
    # refuses to let a transient hostname override a static one:
    #
    #   hostnamectl[489]: Hint: static hostname is already set, so the
    #                     specified transient hostname will not be used.
    #
    # So the first three hardware runs came up as `nanokvm` no matter what
    # nanokvm-identity did, and switching that call to `--transient` (which was
    # itself a necessary fix -- the static write fails outright on a read-only
    # store symlink) only changed the error into a polite refusal. With no
    # static hostname there is nothing to lose to, and the transient one the
    # identity service derives from the SoC UID is what gethostname(2), the
    # server, mDNS and the DHCP client read. An un-provisioned board falls back
    # to the kernel default, `localhost`.
    # mkDefault, so a consumer can take the static hostname back -- but read
    # the paragraph above before doing it.
    networking.hostName = lib.mkDefault "";
    networking.useNetworkd = lib.mkDefault true;
    networking.useDHCP = lib.mkDefault true;

    # THE SAME MAC IS NOT ENOUGH TO GET THE SAME LEASE. systemd-networkd's
    # default `ClientIdentifier=duid` sends a DUID+IAID in DHCP option 61, and
    # a DHCP server keys its reservation on whatever option 61 says. The vendor
    # stack runs udhcpc through ifupdown, which sends the MAC. So the first
    # hardware boot of this appliance came up with the correct derived MAC and
    # a BRAND NEW ADDRESS, not the one the unit has always had -- which on a
    # board reached only over the network is most of the way to invisible.
    # `mac` restores option 61 to what every previous boot of this device sent.
    #
    # Settable so a hardware run can put the default back and isolate which of
    # the two run-2 changes cost what.
    systemd.network.networks."99-ethernet-default-dhcp".dhcpV4Config.ClientIdentifier =
      cfg.dhcp.clientIdentifier;
  };
}
