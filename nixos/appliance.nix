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
  parts = import ./emmc-partitions.nix { inherit lib; };
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
      hostnamectl set-hostname "$host" || true

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

  # ---- boot.loader.external installer ------------------------------------
  # There is no bootloader to install. What a "boot install" means on this
  # board is: write the new kernel Image and dtb into the INACTIVE A/B slot,
  # then flip the U-Boot `bootsystem` env so the next boot takes it -- leaving
  # the slot that currently works untouched as the rollback.
  #
  # That flip is #79's contract (health-gated re-arm, RuntimeWatchdogSec, the
  # cold-power-cycle caveat), and doing it half-way is worse than not doing it:
  # a slot flipped without a health gate turns a bad generation into a board
  # that needs Jeremy's hands on it. So the hook is inert until #79 enables it,
  # and says so rather than failing a switch.
  bootInstaller = pkgs.writeShellApplication {
    name = "nanokvm-install-boot";
    runtimeInputs = with pkgs; [ coreutils ubootTools ];
    text = ''
      set -eu
      toplevel="''${1:?usage: nanokvm-install-boot <toplevel>}"

      echo "nanokvm: userspace generation installed: $toplevel"
      echo "nanokvm: /init -> /nix/var/nix/profiles/system/init, so the next"
      echo "         boot takes it with no boot-chain write at all."

      ${lib.optionalString (!cfg.bootUpdate.enable) ''
        echo "nanokvm: kernel/dtb A/B updates are DISABLED (nanokvm.bootUpdate.enable"
        echo "         = false). Flipping a slot without the health-gated re-arm of"
        echo "         issue #79 can strand this board. Nothing was written."
        exit 0
      ''}

      ${lib.optionalString cfg.bootUpdate.enable ''
        echo "nanokvm: A/B kernel/dtb update is enabled but unimplemented (#79)." >&2
        echo "         Refusing to write ${parts.slotB.kernel.device} blindly." >&2
        exit 1
      ''}
    '';
  };
in
{
  # =====================================================================
  # 0. Options -- the knobs the hardware tests and the sibling issues use
  # =====================================================================
  options.nanokvm = {
    rootDevice = lib.mkOption {
      type = lib.types.str;
      default = parts.root.device;
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
        description = "Filesystem type of `hostDevice`.";
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

    # `losetup` for the image-file root below. Busybox in the initrd has an
    # applet, but the real one is 100 KB and behaves the same everywhere.
    boot.initrd.extraUtilsCommands = lib.mkIf cfg.rootImage.enable ''
      copy_bin_and_libs ${pkgs.util-linux}/bin/losetup
    '';

    # Mount the carrier filesystem and attach the image before stage 1 goes
    # looking for the root device. Runs after udev has settled the block
    # devices, which is exactly when the eMMC partitions exist.
    boot.initrd.postDeviceCommands = lib.mkIf cfg.rootImage.enable ''
      echo "nanokvm: loop-mounting ${cfg.rootImage.path} off ${cfg.rootImage.hostDevice}"
      # waitDevice is stage 1's own helper; `udevadm settle` has already run by
      # here, but the eMMC probes asynchronously and a missing partition would
      # otherwise be a bare mount failure with no explanation.
      waitDevice ${cfg.rootImage.hostDevice} || \
        echo "nanokvm: ${cfg.rootImage.hostDevice} never appeared" >&2
      mkdir -p /nanokvm-host
      # rw, and it has to be: losetup opens the backing file O_RDWR, which
      # fails with EROFS on a read-only mount, and a read-only loop device
      # cannot carry a writable root. The only blocks written on the carrier
      # filesystem are the ones already allocated to our image file, plus its
      # journal -- the same traffic every vendor boot generates.
      mount -t ${cfg.rootImage.hostFsType} ${cfg.rootImage.hostDevice} /nanokvm-host \
        || echo "nanokvm: could not mount ${cfg.rootImage.hostDevice}" >&2
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

    # p16, vfat, and it must be WRITABLE: the server keeps its USB-gadget
    # feature flags there (usb.ncm, usb.disk0, usb.uac2, eth.nodhcp, ...), the
    # module loader sources /boot/configs, and the vendor initramfs contract
    # still uses /boot/rec and /boot/check_resize2fs on a vendor boot.
    # umask=000 matches the device.
    fileSystems."/boot" = {
      device = parts.bootfs.device;
      fsType = "vfat";
      options = [ "nofail" "noatime" "umask=000" ];
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

    # 5b. ATX target power/reset GPIOs -- STUB.
    #
    # The 4.19 version of this poked the VI_D7 pad mux with devmem and then
    # exported gpio7/35/74/75 through sysfs (the SW_PWR pinmux trap,
    # docs/mini-display.md). None of that transfers: this kernel has a real
    # pinctrl driver whose gpio_request_enable() programs the mux, but no GPIO
    # driver to request a line from -- axera,ax-apb-gpio is #81. A blind devmem
    # write against a pad table the pinctrl driver also owns is exactly the
    # kind of poke that turns into a week of debugging.
    systemd.services.nanokvm-gpio = {
      description = "NanoKVM-Pro ATX GPIO setup (stub -- #81)";
      wantedBy = [ "multi-user.target" ];
      before = [ "nanokvm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo "nanokvm-gpio: STUB. No GPIO controller driver on this kernel yet"
        echo "              (issue #81), so ATX power/reset do nothing. The"
        echo "              pinmux is owned by pinctrl-ax630c now, not by a"
        echo "              devmem write."
      '';
    };

    # 5c. USB gadget -- STUB. #82 owns dwc3 glue, extcon-usb-gpio and the
    # configfs gadget; the vendor usbdev.sh contract is gap 2 in
    # docs/nixos-rootfs.md and is not even captured off the device yet.
    systemd.services.nanokvm-usb = {
      description = "NanoKVM-Pro USB HID/storage gadget (stub -- #82)";
      wantedBy = [ "multi-user.target" ];
      before = [ "nanokvm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        echo "nanokvm-usb: STUB. No dwc3 glue and no gadget script on this"
        echo "             kernel yet (issue #82): no keyboard, no mouse, no"
        echo "             mass storage, no NCM."
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
    systemd.services.nanokvm-checkboot = {
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

    # Overwritten per-device by nanokvm-identity above; this is what an
    # un-provisioned board reports.
    networking.hostName = "nanokvm";
    networking.useNetworkd = true;
    networking.useDHCP = lib.mkDefault true;
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
    environment.systemPackages = with pkgs; [
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
    ];

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
