{ config, lib, pkgs, nanokvm, ... }:

# ===========================================================================
# NanoKVM-Pro appliance -- NixOS system definition (issue #78, epic #26).
#
# STATUS: builds; boot-tested only as far as the report in
# docs/mainline-port.md says it is. Read docs/nixos-rootfs.md before touching
# it, and especially before flashing anything.
#
# This is the mainline-kernel appliance. Its predecessor targeted the vendor
# Linux 4.19.125 and was pinned to nixos-24.11 because systemd's declared
# kernel floor had moved past 4.19; that whole constraint is gone. The kernel
# is now `pkgs/kernel-mainline` (Linux 7.1.x), far above systemd's 5.10
# minimum, so this module evaluates against the flake's ONE nixpkgs pin --
# the same unstable pin every other output uses.
#
# What is unusual about this system, and why every switch below is here:
#
#   * NO BOOTLOADER, but a real boot contract. BootROM -> SPL -> ATF -> OP-TEE
#     -> U-Boot, all from pkgs/boot.nix. U-Boot raw-reads the kernel and dtb
#     out of signed A/B partitions BY NAME and `booti`s them; nothing in the
#     rootfs picks a kernel. So `boot.loader.external` owns "install", and the
#     installer writes the inactive A/B slot (#79 turns that on).
#
#   * NIXOS INITRD, EMBEDDED IN THE KERNEL IMAGE. U-Boot passes no initrd
#     address and there is no partition to hold one, so the initrd rides in
#     the Image via CONFIG_INITRAMFS_SOURCE (pkgs/kernel-mainline.nix). The
#     vendor /init -- which fsck'd, resized, derived the MAC and
#     `switch_root`ed -- is GONE; every one of its jobs is a NixOS mechanism
#     or a unit below.
#
#   * NO `init=` ON THE COMMAND LINE. The cmdline comes from the U-Boot
#     environment, not from us and not from the device tree (U-Boot's
#     fdt_chosen overwrites /chosen/bootargs at `booti`). NixOS stage 1
#     therefore falls back to its default `stage2Init=/init`, so the image
#     ships `/init` as a symlink to the system profile -- which is also what
#     makes a generation switch take effect with no bootloader involved.
#
#   * NO NIXOS KERNEL. `boot.kernel.enable = false`: the running kernel lives
#     in its own eMMC partition and every driver it needs is built in. There
#     is no /lib/modules tree at all yet -- see the video-stack stub below.
#
#   * NO CLOSED CODE. The shipped video stack has been blob-free since #60,
#     so unlike its predecessor this module stages no Axera libraries and no
#     vendor .ko. nixos/rootfs.nix asserts that (blob policy, CLAUDE.md).
# ===========================================================================

let
  # THE eMMC LAYOUT (#89 rung 4). `nanokvm.emmcLayout` picks which of the two
  # layouts nixos/lib/emmc-layout.nix defines this system is built for:
  # "minimal" (six partitions, the mainline chain, the default) or "vendor"
  # (the shipped 17, which the vendor chain's SPL is compiled for and which an
  # AXDL recovery puts back). The root device, /boot, its filesystem type and
  # /etc/fw_env.config all follow from it.
  layoutOf = n: import ./emmc-partitions.nix { inherit lib; layout = n; };
  parts = layoutOf cfg.emmcLayout;
  cfg = config.nanokvm;

  # ---- /kvmapp : the app tree the service model copies to tmpfs ----------
  # Layout is the vendor's (server/{NanoKVM-Server,web,dl_lib}, version), so
  # NanoKVM-Server finds ./web and $ORIGIN/dl_lib exactly as it does today.
  #
  # libkvm.so is RE-RPATH'd here, and that is not cosmetic. pkgs/kvm-encoder.nix
  # sets DT_RPATH to "/opt/lib:<axera-libs>/lib" so the same artifact also works
  # in the vendor-encoder configuration. On an overlay rootfs that store path is
  # a dead string; in a Nix closure it is a REFERENCE, and it would drag the
  # entire closed Axera library set into an image that is supposed to contain
  # none of it. The V4L2/openVenc build links no vendor library at all, so the
  # three open libraries it does need are named directly.
  kvmapp = pkgs.runCommand "kvmapp"
    {
      nativeBuildInputs = [ pkgs.patchelf ];
    } ''
    mkdir -p "$out/server/dl_lib" "$out/server/web"
    cp ${nanokvm.nanokvm-server}/bin/NanoKVM-Server "$out/server/NanoKVM-Server"
    cp -a ${nanokvm.nanokvm-web}/. "$out/server/web/"
    cp ${nanokvm.kvm-encoder}/lib/libkvm.so   "$out/server/dl_lib/"
    cp ${nanokvm.kvm-encoder}/lib/libkvm.so.0 "$out/server/dl_lib/"
    printf '%s\n' "${nanokvm.version}" > "$out/version"
    chmod -R u+w "$out"

    # --force-rpath: DT_RPATH, not DT_RUNPATH. libkvm is dlopen'd by the
    # server, and only DT_RPATH is inherited down the dependency chain --
    # the trap in docs/architecture.md ("Load-bearing linker detail").
    #
    # BOTH copies. pkgs/kvm-encoder.nix installs libkvm.so and libkvm.so.0 as
    # two real files, not a symlink pair, so patching one leaves the store path
    # in the other and the closure is dragged in anyway.
    for so in "$out/server/dl_lib/libkvm.so" "$out/server/dl_lib/libkvm.so.0"; do
      patchelf --force-rpath --set-rpath \
        "/opt/lib:${nanokvm.opus}/lib:${nanokvm.alsaLib}/lib:${nanokvm.jpeg}/lib" \
        "$so"
    done

    for f in "$out/server/dl_lib/libkvm.so" "$out/server/dl_lib/libkvm.so.0" \
             "$out/server/NanoKVM-Server"; do
      if grep -qa 'axera-libs' "$f"; then
        echo "ERROR: $f still references axera-libs -- the closed media" >&2
        echo "       libraries would be pulled into the image closure." >&2
        exit 1
      fi
    done
  '';

  # ---- /opt/lib : the FHS path the vendor-shaped binaries reach through ---
  # Three open libraries, nothing else. libkvm DT_NEEDEDs libopus and libasound
  # (ALSA HDMI-audio capture -> Opus) and, on the soft-MJPEG path (#51),
  # libjpeg.so.8. They are named in libkvm's rpath above as well; /opt/lib
  # exists because NanoKVM-Server's own DT_RUNPATH is the bare, store-free
  # "$ORIGIN/dl_lib:/opt/lib:/opt/usr/lib" (pkgs/nanokvm-server.nix).
  optLib = pkgs.runCommand "nanokvm-opt-lib" { } ''
    mkdir -p "$out/lib"
    cp -aL ${nanokvm.opus}/lib/libopus.so*      "$out/lib/"
    cp -aL ${nanokvm.alsaLib}/lib/libasound.so* "$out/lib/"
    cp -aL ${nanokvm.jpeg}/lib/libjpeg.so*      "$out/lib/"
    chmod -R u+w "$out/lib"
    for must in libopus.so.0 libasound.so.2 libjpeg.so.8; do
      test -e "$out/lib/$must" \
        || { echo "ERROR: $must missing from /opt/lib" >&2; exit 1; }
    done
  '';

  # ---- ether-wake compat shim (Wake-on-LAN) ------------------------------
  # The server's WoL route runs exactly `ether-wake -b <MAC>`
  # (service/network/wol.go). That binary is Debian net-tools; nixpkgs ships no
  # package providing the name. wakeonlan sends the same magic packet and
  # broadcasts by default. Only `-b <MAC>` is ever passed.
  etherWakeShim = pkgs.writeShellScriptBin "ether-wake" ''
    exec ${pkgs.wakeonlan}/bin/wakeonlan "''${@: -1}"
  '';

  # ---- The PATH contract for NanoKVM-Server and its script children -------
  # environment.systemPackages does NOT set a systemd unit's PATH, so the unit
  # would otherwise carry only NixOS's default 5-package PATH and every
  # bare-name exec.Command in the server would fail to resolve. Derived from a
  # full grep of the server's Go source (ip ifconfig openssl passwd aplay
  # wpa_cli python systemctl timedatectl reboot ether-wake ps pgrep grep sed awk
  # rm touch insmod rmmod lsmod fw_printenv fw_setenv devmem udhcpc/udhcpd
  # hostapd ...). The server is the PARENT of usbdev.sh / wifi.sh, so those
  # inherit this PATH too.
  #
  # Known-absent, documented in docs/nixos-rootfs.md: chronyc (we run timesyncd)
  # and dpkg/tailscale (out of scope).
  serverPath = with pkgs; [
    etherWakeShim
    coreutils
    bash
    gnugrep
    gnused
    gawk
    procps
    util-linux
    kmod
    iproute2
    nettools
    iptables
    openssl
    ethtool
    wpa_supplicant
    hostapd
    alsa-utils
    shadow
    systemd
    python3
    ubootTools # fw_printenv / fw_setenv -- the A/B boot-slot scripts
    busybox # devmem + udhcpc/udhcpd; LAST so the real tools above win
  ];

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

  # ---- the boot payload's two configs ------------------------------------
  # ONE generator, two files, and the difference between them is one token.
  #
  #   /boot/extlinux/extlinux.conf           the generation to boot
  #   /boot/extlinux/extlinux-fallback.conf  the last one that was healthy
  #
  # U-Boot's `bootcmd` runs `sysboot ... ${extlinux_cfg}`; its `altbootcmd`,
  # which `bootcount` > `bootlimit` selects, runs the same command against
  # ${extlinux_fallback}. `sysboot` boots a config's DEFAULT entry and has no
  # way to name a LABEL, so the choice of generation IS the choice of file --
  # which is also why generations are not labels in one config here.
  #
  # The template carries @INIT@ where the generation's `init=` goes;
  # nanokvm-install-boot substitutes the toplevel it was handed. Nothing else
  # in the file varies, so a diff between the two configs is exactly the
  # generation difference.
  extlinuxTemplate = pkgs.writeText "extlinux.conf.in"
    (import ../pkgs/extlinux.nix { inherit pkgs lib; init = "@INIT@"; });

  # ---- boot.loader.external installer ------------------------------------
  # "Installing the bootloader" on this board is writing one text file. There
  # is no kernel to copy: `boot.kernel.enable = false`, the Image lives in
  # /boot as a flake artefact with the stage-1 initrd inside it, and what a
  # NixOS generation actually is here is a userspace closure. So the installer
  # pins that closure into the default extlinux config and leaves the fallback
  # alone -- the fallback is nanokvm-mark-good's to write, and only after a
  # boot has proven itself.
  #
  # THE FALLBACK IS NEVER WRITTEN HERE. That is the whole safety property: at
  # the moment of a switch the new generation has never booted, so promoting
  # it to the rollback target would leave a board with two copies of the same
  # untested system. The one exception is bootstrap -- if no fallback exists
  # at all there is nothing to roll back TO, and a copy of the entry being
  # installed is strictly better than a missing file.
  bootInstaller = pkgs.writeShellApplication {
    name = "nanokvm-install-boot";
    runtimeInputs = with pkgs; [ coreutils gnused gnugrep ];
    text = ''
      set -eu
      toplevel="''${1:?usage: nanokvm-install-boot <toplevel>}"

      dir=/boot/extlinux
      conf="$dir/extlinux.conf"
      fallback="$dir/extlinux-fallback.conf"

      [ -d "$dir" ] || { echo "nanokvm: $dir is missing -- is /boot mounted?" >&2; exit 1; }

      # Write, fsync, rename: a config half-written by a power cut is a board
      # that boots nothing, and this partition is the only thing U-Boot reads.
      tmp="$conf.new"
      sed "s|@INIT@|$toplevel/init|" ${extlinuxTemplate} > "$tmp"
      grep -q "init=$toplevel/init" "$tmp" \
        || { echo "nanokvm: generated config does not name $toplevel" >&2; rm -f "$tmp"; exit 1; }
      sync "$tmp"
      mv "$tmp" "$conf"

      if [ ! -e "$fallback" ]; then
        echo "nanokvm: no rollback fallback yet -- seeding it with this generation"
        cp "$conf" "$fallback.new"
        sync "$fallback.new"
        mv "$fallback.new" "$fallback"
      fi
      sync

      echo "nanokvm: default generation is now $toplevel"
      echo "nanokvm: fallback stays $(sed -n 's|.*init=\([^ ]*\)/init.*|\1|p' "$fallback")"
      echo "nanokvm: the boot counter is armed; nanokvm-mark-good promotes this"
      echo "         generation to the fallback only once the boot is healthy."

      ${lib.optionalString cfg.bootUpdate.enable ''
        echo "nanokvm: A/B kernel/dtb update is enabled but unimplemented (#79)." >&2
        echo "         Refusing to write ${parts.slotB.kernel.device} blindly." >&2
        exit 1
      ''}
    '';
  };

  # ---- the health gate ---------------------------------------------------
  # What "healthy" means for a KVM, in the three things it is FOR: the system
  # finished starting, the web server answers, and the network works. A board
  # that reaches a shell but serves nothing is not a board worth keeping as
  # the rollback target.
  #
  # `systemctl is-system-running` is polled rather than ordered against,
  # because it only becomes `running` when the initial transaction is EMPTY --
  # a unit inside that transaction waiting for it would wait for itself. Hence
  # the timer: the service it starts is its own job, outside the boot's.
  markGood = pkgs.writeShellApplication {
    name = "nanokvm-mark-good";
    runtimeInputs = with pkgs; [ coreutils busybox curl iproute2 systemd gnugrep gnused ];
    text = ''
      set -eu

      # TOP_CHIPMODE_GLB_BACKUP1, and the value U-Boot's DM_BOOTCOUNT_SYSCON
      # backend reads as "magic present, count zero": CONFIG_SYS_BOOTCOUNT_MAGIC
      # is 0xB001C041 and the four-byte mode keeps its top half in bits 31..16.
      # A plain 32-bit store is right here -- nothing else owns this word, and
      # unlike BACKUP0 there are no neighbouring bits to preserve.
      BOOTCOUNT_REG=0x02390030
      BOOTCOUNT_CLEAR=0xB0010000

      deadline=$(( ${toString cfg.markGood.timeoutSec} ))
      start=$(cut -d. -f1 /proc/uptime)

      # /proc/uptime, never `date +%s`: timesyncd jumps the clock the moment
      # DHCP lands, and a wall-clock deadline expires instantly when it does.
      elapsed() { echo $(( $(cut -d. -f1 /proc/uptime) - start )); }

      healthy() {
        [ "$(systemctl is-system-running 2>/dev/null || true)" = running ] || return 1
        ip -4 route show default | grep -q . || return 1
        ${lib.optionalString cfg.server.enable ''
          curl -sk -o /dev/null -m 5 https://127.0.0.1/ || return 1
        ''}
        return 0
      }

      while ! healthy; do
        if [ "$(elapsed)" -ge "$deadline" ]; then
          echo "mark-good: NOT healthy after ''${deadline}s -- leaving bootcount alone." >&2
          echo "mark-good: is-system-running=$(systemctl is-system-running 2>&1 || true)" >&2
          systemctl --failed --no-legend --no-pager >&2 || true
          exit 1
        fi
        sleep 5
      done

      echo "mark-good: healthy after $(elapsed)s (bootcount was $(devmem $BOOTCOUNT_REG 32))"
      devmem $BOOTCOUNT_REG 32 $BOOTCOUNT_CLEAR
      echo "mark-good: bootcount cleared -> $(devmem $BOOTCOUNT_REG 32)"

      # The fallback is regenerated from /run/booted-system, NOT copied from
      # extlinux.conf. A `nixos-rebuild switch` between this boot and now has
      # already rewritten extlinux.conf to name a generation that has never
      # booted; copying it would promote an untested system on the strength of
      # a different one's health. /run/booted-system is the only thing here
      # that says what actually came up.
      booted=$(readlink -f /run/booted-system)
      fallback=/boot/extlinux/extlinux-fallback.conf
      sed "s|@INIT@|$booted/init|" ${extlinuxTemplate} > "$fallback.new"
      if cmp -s "$fallback.new" "$fallback"; then
        rm -f "$fallback.new"
        echo "mark-good: fallback already $booted"
      else
        sync "$fallback.new"
        mv "$fallback.new" "$fallback"
        sync
        echo "mark-good: fallback promoted to $booted"
      fi
    '';
  };
in
{
  # =====================================================================
  # 0. Options -- the knobs the hardware tests and the sibling issues use
  # =====================================================================
  options.nanokvm = {
    emmcLayout = lib.mkOption {
      type = lib.types.enum [ "minimal" "vendor" ];
      default = "minimal";
      description = ''
        Which eMMC partition layout this system is built for
        (nixos/lib/emmc-layout.nix).

        `minimal` is the six-partition layout the mainline boot chain runs on
        (#89 rung 4): spl, atf, uboot, env, boot, rootfs -- no A/B twins, no
        ddrinit, no OP-TEE, no separate kernel/dtb partitions, /boot on ext4.

        `vendor` is the 17-partition A/B map the board shipped with. The
        vendor boot chain's SPL is COMPILED for it, so a system imaged with
        that chain must be built with this, and it is what an AXDL recovery
        restores.
      '';
    };

    rootDevice = lib.mkOption {
      type = lib.types.str;
      default = (layoutOf config.nanokvm.emmcLayout).root.device;
      description = ''
        Block device holding the NixOS root filesystem. Derived from the
        `blkdevparts=` clause, which is the only definition of this eMMC's
        layout (there is no on-disk partition table).
      '';
    };

    rootImage = {
      enable = lib.mkEnableOption ''
        booting from a rootfs IMAGE FILE loop-mounted off another filesystem
        instead of from a partition.

        This is the reversible hardware-test root. The device's only writable
        medium is the eMMC, whose p17 carries the running vendor system, and
        there is no SD card in the unit. Dropping a file onto p17 and
        loop-mounting it from stage 1 boots a real NixOS root without
        overwriting anything: rolling back is `rm` plus a slot-B restore
      '';
      hostDevice = lib.mkOption {
        type = lib.types.str;
        default = parts.root.device;
        description = "Filesystem holding the image file.";
      };
      hostFsType = lib.mkOption {
        type = lib.types.str;
        default = "ext4";
        description = "Filesystem type of the carrier.";
      };
      hostPartition = lib.mkOption {
        type = lib.types.int;
        default = parts.root.number;
        description = ''
          Partition number of the carrier, used to FIND it rather than to name
          it. Stage 1 takes whichever `mmcblk*` disk has this partition,
          because the three SD4HC instances probe in no fixed order and the
          eMMC is not reliably `mmcblk0` -- one #78 hardware run had it as
          `mmcblk1`. Seventeen partitions is unique to the eMMC on this board.
        '';
      };
      path = lib.mkOption {
        type = lib.types.str;
        default = "/nixos-root.img";
        description = "Path of the image file, relative to `hostDevice`'s root.";
      };
    };

    videoStack.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Load the open capture/encode kernel modules at boot. OFF on mainline:
        `open_vin_csi2`, `open_vin_capture` and `ax630c_venc_vcmd` are written
        against the 4.19 V4L2/DMA APIs and are ported to current ones by #83.
        Until then the server runs with no /dev/video0.
      '';
    };

    server.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run NanoKVM-Server (the web UI, ATX, network and update routes).";
    };

    checkboot.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Re-arm the active A/B slot on every boot (the S99checkboot equivalent).

        Turn this OFF for a slot-B boot test. The SPL treats `SLOTB_BOOTABLE` as
        consume-once, and the entire safety argument of the reversible harness
        is that NOTHING in the slot-B image re-arms it -- so whatever happens
        there, the next boot lands on slot A by itself. A booted appliance that
        re-armed would stay on slot B, and getting back would need either a
        working shell on it or Jeremy's hands on the power.
      '';
    };

    markGood.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Clear U-Boot's boot counter and promote the running generation to the
        rollback fallback, once this boot has been shown to be healthy
        (#89 rung 5, and what closes #79).

        With this OFF the counter is never cleared, so every boot counts and
        the fourth consecutive one takes `altbootcmd`. That is the correct
        behaviour for a deliberately-broken generation in a rollback drill --
        and the reason the knob exists.
      '';
    };

    markGood.delaySec = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        Seconds after boot before the health check first runs. The appliance
        takes ~93 s of userspace on this board, so this is a floor, not a
        deadline: the check polls from here until `markGood.timeoutSec`.
      '';
    };

    markGood.timeoutSec = lib.mkOption {
      type = lib.types.int;
      default = 240;
      description = ''
        How long the health check keeps polling before giving up and leaving
        the boot counter alone. Must stay well under the time three more boot
        attempts would take, or a board that is merely slow looks broken.
      '';
    };

    bootUpdate.enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Let a generation switch write the inactive A/B kernel/dtb slot and flip
        `bootsystem`. Owned by #79 (health-gated re-arm); inert until then.
      '';
    };

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
    # =====================================================================
    # 1. Platform, and everything NixOS must NOT do
    # =====================================================================
    nixpkgs.hostPlatform = "aarch64-linux";
    system.stateVersion = "26.11";

    # The kernel is pkgs/kernel-mainline, in its own signed eMMC partition;
    # every driver this board needs is built in, so there is no modules tree.
    boot.kernel.enable = false;

    # "Install the bootloader" here means "write the inactive A/B slot", which
    # is #79. Declaring it keeps `nixos-rebuild switch` honest instead of
    # silently doing nothing.
    boot.loader.external = {
      enable = true;
      installHook = "${bootInstaller}/bin/nanokvm-install-boot";
    };
    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;
    boot.loader.generic-extlinux-compatible.enable = false;

    # =====================================================================
    # 2. The initrd -- what replaces the vendor /init
    # =====================================================================
    # Classic (script) stage 1, not systemd-in-initrd. Two reasons, both
    # specific to this board: the initrd is EMBEDDED IN THE KERNEL IMAGE and
    # every byte of it is charged against a 64 MiB partition shared with the
    # kernel; and the failure mode of a stage-1 that dies here is a board with
    # no console and no autoboot interrupt window. A shell script that mounts
    # one ext4 is the smaller, more inspectable thing.
    boot.initrd.enable = true;
    boot.initrd.systemd.enable = false;

    # Uncompressed, because pkgs/kernel-mainline.nix hands this straight to
    # CONFIG_INITRAMFS_SOURCE and lets the KERNEL compress it (zstd). Compress
    # it twice and the Image grows.
    boot.initrd.compressor = "cat";

    # There are no kernel modules at all -- every driver this board has is
    # built into the Image, and `boot.kernel.enable = false` means there is no
    # modules tree to draw a closure from.
    #
    # mkForce, not `= [ ]`: option lists MERGE, and nixos/modules/tasks/
    # filesystems/ext.nix adds "ext2 ext4" to availableKernelModules for the
    # root filesystem's type. Merging leaves those two in place, and
    # makeModulesClosure over an empty tree with a non-empty root module list
    # is a hard build failure ("Can not derive a closure of kernel modules").
    boot.initrd.includeDefaultModules = false;
    boot.initrd.kernelModules = lib.mkForce [ ];
    boot.initrd.availableKernelModules = lib.mkForce [ ];

    # `losetup` for the image-file root below and for the GPT mapping. Busybox
    # in the initrd has an applet, but the real one is 100 KB, behaves the same
    # everywhere, and is the only one that takes `-P`.
    # `resize2fs` is the minimal layout's one-time shrink -- see the comment on
    # preLVMCommands below.
    boot.initrd.extraUtilsCommands = lib.mkMerge [
      (lib.mkIf cfg.rootImage.enable ''
        copy_bin_and_libs ${pkgs.util-linux}/bin/losetup
      '')
      (lib.mkIf (cfg.emmcLayout == "minimal") ''
        copy_bin_and_libs ${pkgs.util-linux}/bin/losetup
        copy_bin_and_libs ${pkgs.e2fsprogs}/bin/resize2fs
      '')
    ];

    # =====================================================================
    # MAPPING `disk`: the GPT the kernel cannot be told to look for
    # =====================================================================
    # The eMMC is two logical devices (#89 rung 4): `spl`, the 768 KiB the
    # BootROM reads its first-stage loader from, and `disk`, everything after
    # it. `disk` carries a spec-conformant GPT at its own LBA 0 -- but Linux
    # has no way to be told "parse a partition table at an offset", so the
    # kernel command line splits the raw eMMC in two with
    # `blkdevparts=mmcblk0:768K(spl),-(disk)` and stage 1 puts a loop device
    # over the second half. The in-kernel EFI parser then does the rest, and
    # /dev/loop0p1..5 appear with their GPT names.
    #
    # This has to happen before any filesystem is mounted, which is what
    # preLVMCommands is: after udev has settled, before the root is looked for.
    boot.initrd.preLVMCommands = lib.mkIf (cfg.emmcLayout == "minimal") ''
      # THE eMMC IS NOT RELIABLY mmcblk0 unless something makes it so -- three
      # SD4HC instances probe concurrently on this SoC. `aliases { mmc0 =
      # &emmc; }` in dts/ax630c.dtsi is what pins it, and the blkdevparts=
      # clause binds the split to that name, so if the alias ever lapses the
      # split lands on an empty slot and NOTHING here can recover it. Wait for
      # the device the clause created rather than assuming it is instant.
      nktry=0
      while [ ! -e ${parts.diskDevice} ] && [ "$nktry" -lt 60 ]; do
        sleep 1
        nktry=$((nktry + 1))
      done
      if [ ! -e ${parts.diskDevice} ]; then
        echo "nanokvm: ${parts.diskDevice} never appeared -- is blkdevparts= on the cmdline?" >&2
        cat /proc/partitions >&2 || true
      else
        # The loop module creates loop0..7 at init; udev makes the nodes. Only
        # make one by hand if that has not happened, because the root device is
        # a compile-time constant and it says loop0.
        if [ ! -e ${parts.loopDevice} ]; then
          modprobe loop 2>/dev/null || true
          nktry=0
          while [ ! -e ${parts.loopDevice} ] && [ "$nktry" -lt 10 ]; do
            sleep 1
            nktry=$((nktry + 1))
          done
          [ -e ${parts.loopDevice} ] || mknod ${parts.loopDevice} b 7 0
        fi

        echo "nanokvm: mapping ${parts.diskDevice} -> ${parts.loopDevice} (GPT)"
        losetup -P ${parts.loopDevice} ${parts.diskDevice} \
          || echo "nanokvm: losetup failed" >&2
        udevadm settle || true

        # THE FILESYSTEM IS FIVE BLOCKS TOO BIG ON THE FIRST BOOT AFTER THE
        # MIGRATION, and ext4 refuses to mount rather than truncating. The old
        # 17-partition table ran `rootfs` to the last byte of the eMMC and the
        # filesystem was grown to fill it; a GPT reserves the last 33 LBAs for
        # the alternate header, so the new partition is 16896 bytes shorter.
        #
        # `resize2fs` with no size argument resizes to the device, shrinking
        # included, and it only demands a check when it has to -- so on every
        # boot after the first this is one command, no fsck, "Nothing to do!".
        if [ -e ${parts.root.device} ]; then
          if ! resize2fs ${parts.root.device}; then
            echo "nanokvm: checking ${parts.root.device} before resizing it"
            e2fsck -fp ${parts.root.device} || true
            resize2fs ${parts.root.device} || true
          fi
        fi
      fi
    '';

    # Mount the carrier filesystem and attach the image before stage 1 goes
    # looking for the root device. Runs after udev has settled the block
    # devices, which is exactly when the eMMC partitions exist.
    boot.initrd.postDeviceCommands = lib.mkIf cfg.rootImage.enable ''
      # LOCATE THE CARRIER, DO NOT ASSUME IT. The AX630C has three SD4HC
      # instances and nothing orders their probes, so the eMMC is not reliably
      # mmcblk0: one #78 run had it as mmcblk1 and stage 1 sat waiting for a
      # /dev/mmcblk0p17 that was never going to appear. #75's bring-up init
      # already knew this and located its partition by name out of
      # /proc/partitions; this is the same discipline. The eMMC is the only
      # device on this board with seventeen partitions, so "the disk that has
      # a p17" identifies it exactly.
      nkhost=""
      nktry=0
      while [ "$nktry" -lt 60 ]; do
        for nkp in /sys/class/block/mmcblk*p${toString cfg.rootImage.hostPartition}; do
          [ -e "$nkp" ] || continue
          nkhost="/dev/$(basename "$nkp")"
          break
        done
        [ -n "$nkhost" ] && break
        sleep 1
        nktry=$((nktry + 1))
      done

      if [ -z "$nkhost" ]; then
        echo "nanokvm: no mmcblk*p${toString cfg.rootImage.hostPartition} appeared -- no carrier" >&2
        nkhost=${cfg.rootImage.hostDevice}
      fi

      echo "nanokvm: loop-mounting ${cfg.rootImage.path} off $nkhost"
      mkdir -p /nanokvm-host
      # rw, and it has to be: losetup opens the backing file O_RDWR, which
      # fails with EROFS on a read-only mount, and a read-only loop device
      # cannot carry a writable root. The only blocks written on the carrier
      # filesystem are the ones already allocated to our image file, plus its
      # journal -- the same traffic every vendor boot generates.
      mount -t ${cfg.rootImage.hostFsType} "$nkhost" /nanokvm-host \
        || echo "nanokvm: could not mount $nkhost" >&2
      losetup /dev/loop0 /nanokvm-host${cfg.rootImage.path} \
        || echo "nanokvm: could not attach /nanokvm-host${cfg.rootImage.path}" >&2
      # /nanokvm-host is deliberately left mounted: the loop device holds the
      # backing file open for the life of the system, and switch_root does not
      # delete across a mount point.
    '';

    # =====================================================================
    # 3. Filesystems -- all three numbers derived from the blkdevparts clause
    # =====================================================================
    fileSystems."/" = {
      device = if cfg.rootImage.enable then "/dev/loop0" else cfg.rootDevice;
      fsType = "ext4";
      options = [ "noatime" ];
      # make-ext4-fs shrinks the image to its contents, so a partition root is
      # ~1 GB inside a ~30 GB partition. Stage 1 grows it, which is what the
      # vendor /init did with static binaries copied out of the rootfs.
      autoResize = !cfg.rootImage.enable;
    };

    # /boot, and it must be WRITABLE: the server keeps its USB-gadget feature
    # flags there (usb.ncm, usb.disk0, usb.uac2, eth.nodhcp, ...), the module
    # loader sources /boot/configs, and the vendor initramfs contract still
    # uses /boot/rec and /boot/check_resize2fs on a vendor boot. Since #89
    # rung 3 it also holds the boot payload -- extlinux.conf, Image, dtb.
    #
    # EXT4 UNDER THE MINIMAL LAYOUT. The kernel needs ext4 for root anyway, so
    # putting /boot on it retires the CONFIG_VFAT_FS + NLS-codepage trap
    # documented in docs/nixos-rootfs.md (without those tables the mount fails
    # -EINVAL and every USB-gadget flag silently reads as absent). `umask` is
    # a vfat-only option; on ext4 the permissions are in the filesystem.
    fileSystems."/boot" =
      let vfat = cfg.emmcLayout == "vendor"; in
      {
        device = parts.bootfs.device;
        fsType = if vfat then "vfat" else "ext4";
        options = [ "nofail" "noatime" ] ++ lib.optional vfat "umask=000";
      };

    swapDevices = [ ];

    # =====================================================================
    # 4. FHS accommodation
    # =====================================================================
    # NanoKVM-Server and libkvm request /lib/ld-linux-aarch64.so.1.
    environment.ldso = "${pkgs.glibc}/lib/ld-linux-aarch64.so.1";

    systemd.tmpfiles.rules = [
      "d /opt 0755 root root - -"
      "L+ /opt/lib - - - - ${optLib}/lib"
      # Third entry of NanoKVM-Server's DT_RUNPATH; same directory.
      "d /opt/usr 0755 root root - -"
      "L+ /opt/usr/lib - - - - ${optLib}/lib"
      # The vendor scripts are #!/bin/bash; NixOS materialises only /bin/sh.
      "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
      # service/vm/datetime.go readlink()s /etc/localtime and slices on the
      # literal "/usr/share/zoneinfo/" -- see gap 6 in docs/nixos-rootfs.md.
      "d /usr/share 0755 root root - -"
      "L+ /usr/share/zoneinfo - - - - ${pkgs.tzdata}/share/zoneinfo"
      # /kvmapp -- immutable app tree. Hot patches only apply to the tmpfs copy
      # and are lost on reboot (deploy-iterate skill assumes otherwise).
      "L+ /kvmapp - - - - ${kvmapp}"
      # Writable server state: server.yaml plus the HTTPS cert+key.
      "d /etc/kvm 0700 root root - -"
      "d /var/log/nanokvm 0755 root root - -"
    ];

    # /etc/fw_env.config -- libubootenv's fw_printenv/fw_setenv need it to
    # locate the U-Boot environment. The value is not a guess and not a device
    # capture: it is the cumulative offset and size of the `env` partition in
    # the same blkdevparts clause U-Boot itself parses, computed and asserted
    # in nixos/emmc-partitions.nix. Non-redundant, eMMC user area.
    #
    # U-Boot rewrites this environment TWICE per boot (set_slot_ab,
    # update_cmdline), so a userspace fw_setenv must not race a reboot.
    environment.etc."fw_env.config".text = parts.fwEnvConfig;

    # =====================================================================
    # 5. Services
    # =====================================================================

    # 5a. The video stack. On mainline there is nothing to load yet: the three
    # open modules are 4.19 out-of-tree drivers and #83 ports them. The unit
    # exists so the ordering edge nanokvm.service already declares stays real,
    # and so a boot log says which issue owns the missing pipeline rather than
    # leaving a silent black stream.
    systemd.services.nanokvm-video = {
      description = "NanoKVM-Pro open video stack (capture + encoder modules)";
      wantedBy = [ "multi-user.target" ];
      before = [ "nanokvm.service" ];
      after = [ "systemd-modules-load.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script =
        if cfg.videoStack.enable then ''
          echo "nanokvm-video: nanokvm.videoStack.enable is set but no module set"
          echo "               is built for this kernel yet (#83)." >&2
          exit 1
        '' else ''
          echo "nanokvm-video: STUB. open_vin_csi2 / open_vin_capture /"
          echo "               ax630c_venc_vcmd are not ported to this kernel yet"
          echo "               (issue #83). No /dev/video0; the server will serve"
          echo "               the UI but not a stream."
        '';
    };

    # 5b. NO ATX GPIO UNIT AT ALL, and that is the #81 result rather than a
    # gap. The 4.19 image had one: it poked the VI_D7 pad mux with `devmem` and
    # exported gpio 7/35/74/75 through /sys/class/gpio (the SW_PWR pinmux trap,
    # docs/mini-display.md). Neither half has anything to do here. There is
    # nothing to export, because consumers address lines by their device-tree
    # name (dts/ax630c-nanokvm-pro.dts: atx-power, atx-reset, atx-power-led,
    # atx-hdd-led); and nothing to mux by hand, because requesting a line runs
    # through gpio-ranges -> gpio_request_enable() and the pin controller
    # programs the pad. The tool that does the requesting is `nanokvm-gpio` in
    # environment.systemPackages below, and the server reaches it by absolute
    # store path (pkgs/nanokvm-server.nix, gpioBackend = "libgpiod").
    #
    # This module therefore stubs #82 and #83, and no longer stubs #81.

    # 5c. USB gadget -- STUB, but no longer for the reason it was written.
    # #82 landed the dwc3 glue and the configfs function drivers, and a host has
    # enumerated a gadget off this board on a mainline kernel. What is missing is
    # the POLICY: `usbdev.sh` builds the whole gadget -- three HID report
    # descriptors, the Microsoft OS descriptors, the flag files under /boot, the
    # udhcpd instance -- and it exists only in the vendor rootfs, uncaptured
    # (gap 2 in docs/nixos-rootfs.md). Until it is vendored or reimplemented
    # there is nothing here to instantiate those functions.
    systemd.services.nanokvm-usb = {
      description = "NanoKVM-Pro USB HID/storage gadget (stub -- #82 policy half)";
      wantedBy = [ "multi-user.target" ];
      before = [ "nanokvm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo "nanokvm-usb: STUB. The controller and the configfs function"
        echo "             drivers are here (#82), but usbdev.sh -- the script"
        echo "             that builds the gadget -- is vendor-only and not"
        echo "             captured yet: no keyboard, no mouse, no mass"
        echo "             storage, no NCM."
      '';
    };

    # 5d. The KVM server. Mirrors the vendor service model: the app tree is
    # copied to tmpfs at boot and the binary runs from there
    # (docs/architecture.md "Runtime service model").
    #
    # This replaces the vendor `nanokvm.sh` supervisor, which did three things:
    # the tmpfs copy (nanokvm-appdir below), a restart loop that gives up after
    # three crashes (Restart=on-failure), and generating the HTTPS cert+key
    # under /etc/kvm (nanokvm-cert below). That script exists only in the
    # vendor rootfs and was gap 1 in docs/nixos-rootfs.md; all three halves are
    # now declared here instead of ported.
    # The tmpfs copy is its OWN unit, not an ExecStartPre. systemd applies
    # WorkingDirectory= to every Exec* line of a unit, including ExecStartPre,
    # so the copy that CREATES /dev/shm/kvmapp/server was being chdir'd into it
    # first and died with 200/CHDIR on every boot -- caught in QEMU, where a
    # first boot is the only kind there is. Splitting it also makes the
    # dependency explicit instead of implicit in an argument string.
    systemd.services.nanokvm-appdir = lib.mkIf cfg.server.enable {
      description = "Copy /kvmapp to tmpfs (the vendor nanokvm_pre.sh step)";
      wantedBy = [ "multi-user.target" ];
      before = [ "nanokvm.service" ];
      unitConfig.ConditionPathExists = "/kvmapp/server/NanoKVM-Server";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ coreutils ];
      script = ''
        rm -rf /dev/shm/kvmapp
        cp -rL /kvmapp /dev/shm/kvmapp
        chmod -R u+w /dev/shm/kvmapp
      '';
    };

    # The HTTPS cert+key the server serves :443 with. Without them it loads its
    # config, binds both ports and then exits 1 on
    # "open /etc/kvm/server.crt: no such file or directory" -- which is what a
    # fresh boot of this image did in QEMU, and would have done on hardware.
    # Self-signed and per-device, exactly as the vendor's does; the browser
    # warning is the same one the vendor image produces.
    systemd.services.nanokvm-cert = lib.mkIf cfg.server.enable {
      description = "Generate the NanoKVM-Pro HTTPS certificate if absent";
      wantedBy = [ "multi-user.target" ];
      before = [ "nanokvm.service" ];
      after = [ "nanokvm-identity.service" ]; # so the CN is the final hostname
      unitConfig.ConditionPathExists = "!/etc/kvm/server.crt";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      path = with pkgs; [ openssl coreutils ];
      script = ''
        mkdir -p /etc/kvm
        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
          -subj "/CN=$(cat /proc/sys/kernel/hostname)" \
          -addext "subjectAltName=DNS:$(cat /proc/sys/kernel/hostname),DNS:$(cat /proc/sys/kernel/hostname).local" \
          -keyout /etc/kvm/server.key -out /etc/kvm/server.crt
        chmod 0600 /etc/kvm/server.key
        chmod 0644 /etc/kvm/server.crt
      '';
    };

    systemd.services.nanokvm = lib.mkIf cfg.server.enable {
      description = "NanoKVM-Pro server (open stack)";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
        "nanokvm-video.service"
        "nanokvm-appdir.service"
        "nanokvm-cert.service"
      ];
      requires = [ "nanokvm-appdir.service" ];
      path = serverPath;
      serviceConfig = {
        Type = "simple";
        WorkingDirectory = "/dev/shm/kvmapp/server";
        # The documented fallback for the bare-name dlopen chain; adds only
        # /opt/lib, never a glibc, so it cannot create the mismatched
        # loader/libc crash an explicit ${pkgs.glibc}/lib would.
        Environment = "LD_LIBRARY_PATH=/opt/lib";
        ExecStart = "/dev/shm/kvmapp/server/NanoKVM-Server";
        Restart = "on-failure";
        RestartSec = 3;
        StandardOutput = "append:/var/log/nanokvm/NanoKVM-Server.log";
        StandardError = "inherit";
      };
    };

    # 5e. Mini-display status daemon. The display's fb_jd9853 / gpio_keys /
    # rotary_encoder modules are 4.19-only for now, so the daemon has no
    # framebuffer to draw on until #84; it fails cleanly rather than being
    # silently absent.
    systemd.services.nanokvm-display = {
      description = "NanoKVM-Pro mini-display status screen";
      wantedBy = [ "multi-user.target" ];
      unitConfig.ConditionPathExists = "/dev/fb0";
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.python3}/bin/python3 ${nanokvm.nanokvm-display}/opt/nanokvm-display/nanokvm_display.py";
        Restart = "on-failure";
        RestartSec = 5;
        Nice = 10;
      };
    };

    # 5f. Per-device identity (MAC + hostname) from the SoC UID.
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

    # 5g. Confirm the active A/B boot slot on every boot -- the S99checkboot
    # equivalent. The SPL CONSUMES the current slot's BOOTABLE bit on the way
    # in, so a boot that never re-arms it is a boot that falls back next time.
    # `bootsystem` is written uppercase A/B by U-Boot; the vendor's own script
    # writes lowercase in places, so both are accepted.
    #
    # This was inert in the 4.19 scaffold for want of /etc/fw_env.config. That
    # file now ships (see section 4), so the unit is live -- and #79 is what
    # puts a health gate in front of it (After=nanokvm-healthy.target) instead
    # of re-arming unconditionally the way the vendor does.
    #
    # UNDER THE MINIMAL LAYOUT THE SLOT BITS SELECT NOTHING (#89 rung 4). The
    # rebuilt SPL has `*_BAK_FLASH_BASE` equal to the A bases, so slot A and
    # slot B are the same two partitions and `select_slot_ab()` picks between
    # two identical addresses. The unit is kept anyway, for two reasons: it
    # keeps bits 2-5 of 0x02390024 in a DETERMINISTIC state (slot A, armed),
    # which is what makes `0x300000x5` a readable oracle rather than a value
    # that alternates every boot; and it keeps the mechanism alive for a
    # vendor-layout system, where the bits do still choose. Rung 5 replaces
    # the whole thing with U-Boot's `bootcount`/`altbootcmd` over
    # DM_BOOTCOUNT_SYSCON on this same register.
    systemd.services.nanokvm-checkboot = lib.mkIf cfg.checkboot.enable {
      description = "Confirm the active A/B boot slot (S99checkboot equivalent)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      unitConfig.ConditionPathExists = "/etc/fw_env.config";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [ ubootTools busybox gnugrep gnused coreutils ];
      script = ''
        slot=$(fw_printenv -n bootsystem 2>/dev/null | tr -d '[:space:]') || slot=""
        case "$slot" in
          a|A) echo "checkboot: slot A -> 0x2390028=0x10"; devmem 0x2390028 32 0x10 ;;
          b|B) echo "checkboot: slot B -> 0x2390028=0x20"; devmem 0x2390028 32 0x20 ;;
          *)   echo "checkboot: bootsystem='$slot' not a/b -- refusing to write the slot register" >&2 ;;
        esac
      '';
    };

    # 5h. The rollback gate (#89 rung 5; this is what closes #79).
    #
    # U-Boot increments `bootcount` in TOP_CHIPMODE_GLB_BACKUP1 on every boot
    # and, once it passes `bootlimit` (3), runs `altbootcmd` instead of
    # `bootcmd` -- which sets milestone bit 30 and boots
    # /boot/extlinux/extlinux-fallback.conf. This unit is the other half: it
    # clears the counter, and promotes the config that booted to the fallback,
    # ONLY once the system has been shown to work.
    #
    # A TIMER, not a `WantedBy=multi-user.target` service. The health check
    # polls `systemctl is-system-running` for `running`, which is only reached
    # when the boot's initial transaction is empty -- so a unit inside that
    # transaction would be waiting on itself. A timer-started job is not part
    # of it.
    #
    # THE FAILURE MODE IS THE SAFE ONE. If this unit does not run, or runs and
    # finds the system unhealthy, the counter is simply not cleared and the
    # next boot counts one higher. Three of those and the board rolls back by
    # itself. Nothing here can strand the board; only NOT running it can end
    # a boot on the fallback.
    systemd.services.nanokvm-mark-good = lib.mkIf cfg.markGood.enable {
      description = "Clear the boot counter and promote this generation to the rollback fallback";
      after = [ "multi-user.target" "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${markGood}/bin/nanokvm-mark-good";
      };
    };

    systemd.timers.nanokvm-mark-good = lib.mkIf cfg.markGood.enable {
      description = "Run the boot health gate once, after this boot has had time to finish";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "${toString cfg.markGood.delaySec}s";
        AccuracySec = "1s";
        RemainAfterElapse = false;
      };
    };

    # The hardware watchdog, petted from PID 1. Without this the ax630c
    # watchdog is petted by the KERNEL for as long as the kernel schedules,
    # which protects against nothing a user would call a hang. With it, a PID 1
    # that stops running resets the board, the counter reaches `bootlimit`, and
    # the rollback above happens unattended -- which is the whole point of a
    # box whose console is a pad nobody can reach.
    #
    # 60 s is the driver's own default timeout (it programs TORR in units of
    # 64Ki ticks of a 24 MHz counter, two stages); systemd pings at half that.
    # RebootWatchdogSec covers a shutdown that wedges after the filesystems are
    # gone, which is exactly where this board has no other way out.
    systemd.watchdog = {
      runtimeTime = "60s";
      rebootTime = "3min";
    };

    # =====================================================================
    # 6. Base system
    # =====================================================================
    services.openssh = {
      enable = true;
      settings.PermitRootLogin = "yes";
      settings.PasswordAuthentication = true;
      # MUST be false. With startWhenNeeded there is no plain `sshd.service` to
      # alias `ssh.service` onto, and the web UI's SSH-enable path
      # (StartService("ssh.service")) would fail. False gives a real persistent
      # sshd.service -- which is also what the device is reached by today.
      startWhenNeeded = false;
    };

    # NanoKVM-Server toggles SSH over org.freedesktop.systemd1 using DEBIAN
    # unit names; every error-checked operation is on `ssh.service`
    # (utils/systemctl.go, service/vm/ssh.go). The `ssh.socket` operations are
    # all best-effort, so aliasing the service alone makes the toggle work end
    # to end. We deliberately do NOT alias ssh.socket -- there is no socket
    # unit to alias, and fabricating one systemd refuses to load is worse than
    # an absent unit the server already tolerates.
    systemd.services.sshd.aliases = [ "ssh.service" ];

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
    networking.hostName = "";
    networking.useNetworkd = true;
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

    # /var/log/nanokvm/*.log is NanoKVM-Server's redirected stdout;
    # copytruncate is mandatory because the fd is held open for the process
    # lifetime (#41).
    services.logrotate = {
      enable = true;
      settings.nanokvm = {
        files = "/var/log/nanokvm/*.log";
        frequency = "daily";
        rotate = 3;
        size = "10M";
        compress = true;
        missingok = true;
        notifempty = true;
        copytruncate = true;
      };
    };

    # Login shells and any unit without its own `path=`. The unit PATH contract
    # lives in `serverPath`; this is the interactive superset, so an admin over
    # SSH finds the same tools.
    environment.systemPackages = [
      # ATX power/reset/LED by device-tree line name (#81) -- the replacement
      # for the deleted sysfs-export unit. On PATH so it can be driven by hand;
      # the server reaches it by store path, not through PATH.
      nanokvm.nanokvm-gpio
    ] ++ (with pkgs; [
      busybox # devmem, udhcpd/udhcpc
      bash
      kmod
      e2fsprogs
      coreutils
      util-linux
      gnugrep
      gnused
      gawk
      procps
      iproute2
      nettools
      iptables
      openssl
      ethtool
      ubootTools # fw_printenv / fw_setenv
      etherWakeShim
      alsa-utils
      wpa_supplicant
      shadow
      tzdata
      python3
      pciutils
      usbutils
    ]);

    # No nix on the appliance: the rootfs is a fixed closure produced by the
    # build host, which is also what keeps the image small. An update is a new
    # closure, not a `nixos-rebuild` on the device (#86).
    nix.enable = false;
    system.switch.enable = lib.mkDefault true;

    documentation.enable = false;
    documentation.nixos.enable = false;

    assertions = [
      {
        assertion = !config.boot.initrd.systemd.enable;
        message = ''
          nixos/appliance.nix: boot.initrd.systemd.enable must stay false.
          The initrd is embedded in the kernel Image and shares a 64 MiB
          partition with it, and a stage 1 that dies on this board is silent
          (no console, no autoboot interrupt window).
        '';
      }
      {
        assertion = !config.boot.kernel.enable;
        message = ''
          nixos/appliance.nix: boot.kernel.enable must stay false. The kernel
          is pkgs/kernel-mainline in eMMC partitions p14/p15; a NixOS kernel in
          the closure would be dead weight nothing boots.
        '';
      }
      {
        assertion = config.boot.initrd.enable;
        message = ''
          nixos/appliance.nix: boot.initrd.enable must stay true. Nothing else
          mounts the root filesystem -- the vendor initramfs that used to do it
          is not on this kernel.
        '';
      }
    ];
  };
}
