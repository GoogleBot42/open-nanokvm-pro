{ config, lib, pkgs, nanokvm, ... }:

# ===========================================================================
# NanoKVM-Pro appliance -- NixOS system definition (issue #26 scaffold).
#
# STATUS: SCAFFOLD. This evaluates and builds a rootfs image; it has NEVER
# been booted on hardware. Read docs/nixos-rootfs.md before touching it, and
# especially before flashing anything.
#
# What makes this system unusual, and why every "off" switch below is here:
#
#   * NO BOOTLOADER. The AX630C boot chain is BootROM -> SPL -> ATF -> OP-TEE
#     -> U-Boot -> Linux, all from pkgs/boot.nix, and the kernel+dtb live in
#     their own signed eMMC partitions (p12..p15). Nothing in the rootfs
#     participates in boot selection, so every NixOS bootloader backend is off.
#
#   * NO NIXOS INITRD. The kernel embeds the VENDOR initramfs (pkgs/kernel.nix,
#     CONFIG_INITRAMFS_SOURCE); its /init reads root= from the cmdline, fscks
#     it, mounts it at /realroot and `exec switch_root /realroot /sbin/init`.
#     So the one hard contract this rootfs owes the boot chain is:
#         /sbin/init must exist and must be NixOS stage 2.
#     nixos/rootfs.nix creates it as a symlink to the system profile's `init`.
#
#   * NO NIXOS KERNEL. `boot.kernel.enable = false` stops NixOS building or
#     referencing a kernel of its own; the running kernel is our from-source
#     4.19.125 (pkgs/kernel.nix). Its modules tree is spliced into the system
#     closure by hand below, at the path nixpkgs' patched kmod searches
#     (/run/booted-system/kernel-modules/lib/modules -- see
#     pkgs/os-specific/linux/kmod/module-dir.patch upstream).
#
#   * SYSTEMD CEILING. 4.19.125 is BELOW systemd's declared minimum baseline
#     from v258 on ("Kernel versions below 5.4 are not supported at all").
#     This module is therefore evaluated against a SEPARATE, OLDER nixpkgs pin
#     (nixpkgs-rootfs -> nixos-24.11, systemd 256.10), not the flake's main
#     nixos-unstable pin. docs/nixos-rootfs.md has the full version table.
#     Do not "modernise" that pin without re-reading it.
#
#   * FHS ACCOMMODATION. The media stack is closed vendor code that hardcodes
#     /opt/lib, /soc/ko and /soc/scripts and expects a distro-shaped root. The
#     `vendor tree` section below materialises exactly those paths -- from our
#     pinned derivations, not from a retained vendor rootfs, which also closes
#     the "provenance nuance" in docs/provenance.md.
# ===========================================================================

let
  release = "4.19.125";

  # ---- Axera userspace media libs, made NixOS-loadable -------------------
  # pkgs/axera-libs.nix deliberately ships the vendor .so byte-for-byte: no
  # rpath, DT_NEEDED on bare libc.so.6/libstdc++.so.6, resolved on Ubuntu via
  # the loader's default /lib search path. NixOS has no such path, so the same
  # libraries must be patchelf'd against this system's glibc/libstdc++ before
  # anything can dlopen them. Everything else about them is unchanged.
  axLibs = pkgs.stdenv.mkDerivation {
    pname = "axera-libs-nixos";
    version = "3.0.0-msp";
    src = nanokvm.axera-libs;
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib # libstdc++ / libgcc_s
      pkgs.glibc
    ];
    # The vendor set has genuine internal cycles and a few libs with no
    # consumer in our stack; a missing dep must not fail the whole build.
    autoPatchelfIgnoreMissingDeps = true;
    installPhase = ''
      mkdir -p "$out"
      cp -a "$src/lib" "$out/lib"
      chmod -R u+w "$out/lib"
    '';
    meta.description =
      "Axera media libraries (pkgs/axera-libs.nix) autoPatchelf'd for a NixOS rootfs";
  };

  # ---- /soc/ko : the pinned prebuilt Axera media modules -----------------
  # Same set the vendor rootfs carries at /soc/ko, but sourced from OUR pinned
  # derivation (pkgs/ax-ko-blobs.nix) instead of the retained vendor image.
  axKo = pkgs.runCommand "nanokvm-soc-ko" { } ''
    mkdir -p "$out"
    cp -a ${nanokvm.ax-ko-blobs}/lib/modules/ax/. "$out/"
  '';

  # ---- /soc/scripts/auto_load_all_drv.sh : our curated 12-module loader ---
  # Byte-identical to pkgs/rootfs/ax-load-drv.sh, only the interpreter and the
  # PATH are made explicit: the script is bash (it uses `function` and `[ ==
  # ]`), and it needs insmod/rmmod plus coreutils. It still insmods BY PATH
  # WITH parameters -- never modprobe; a parameter-less ax_cmm is the
  # strlen(NULL) panic that bricked a device (docs/blob-replacement.md).
  axLoader = pkgs.writeShellApplication {
    name = "auto_load_all_drv.sh";
    runtimeInputs = [ pkgs.kmod pkgs.coreutils pkgs.gnused pkgs.gnugrep ];
    # The vendor script is not shellcheck-clean and must not be "fixed".
    checkPhase = "";
    text = builtins.readFile ../pkgs/rootfs/ax-load-drv.sh;
  };

  # ---- /kvmapp : the app tree the service model copies to tmpfs ----------
  # Layout is the vendor's (server/{NanoKVM-Server,web,dl_lib}, version), so
  # NanoKVM-Server finds ./web and $ORIGIN/dl_lib exactly as it does today.
  kvmapp = pkgs.runCommand "kvmapp" { } ''
    mkdir -p "$out/server/dl_lib" "$out/server/web"
    cp ${nanokvm.nanokvm-server}/bin/NanoKVM-Server "$out/server/NanoKVM-Server"
    cp -a ${nanokvm.nanokvm-web}/. "$out/server/web/"
    cp ${nanokvm.kvm-encoder}/lib/libkvm.so   "$out/server/dl_lib/"
    cp ${nanokvm.kvm-encoder}/lib/libkvm.so.0 "$out/server/dl_lib/"
    printf '%s\n' "${nanokvm.version}" > "$out/version"
    chmod -R u+w "$out"
  '';

  # Our from-source kernel modules, in the layout nixpkgs' kmod expects to find
  # under <system>/kernel-modules. depmod is re-run here because the tree is
  # re-rooted; the vendor ax_*.ko are NOT merged in, for the same reason as in
  # pkgs/rootfs.nix (a merged tree gets `of:` modaliases, udev coldplug then
  # autoloads ax_cmm parameter-less, and the device panic-loops).
  modulesTree = pkgs.runCommand "nanokvm-modules-tree"
    { nativeBuildInputs = [ pkgs.kmod ]; } ''
    mkdir -p "$out/lib/modules/${release}"
    cp -a ${nanokvm.kernel}/lib/modules/${release}/. "$out/lib/modules/${release}/"
    chmod -R u+w "$out"
    depmod -b "$out" "${release}"
    if find "$out" \( -name 'ax_cmm.ko' -o -name 'ax_sys.ko' -o -name 'ax_base.ko' \) | grep -q .; then
      echo "ERROR: vendor ax_*.ko in the modules tree -- they autoload-panic." >&2
      exit 1
    fi
    grep -q lt6911_manage "$out/lib/modules/${release}/modules.dep" \
      || { echo "ERROR: lt6911_manage missing from modules.dep" >&2; exit 1; }
  '';
in
{
  # =====================================================================
  # 1. Platform, and everything NixOS must NOT do
  # =====================================================================
  nixpkgs.hostPlatform = "aarch64-linux";
  system.stateVersion = "24.11";

  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  boot.loader.generic-extlinux-compatible.enable = false;
  boot.initrd.enable = false; # the kernel embeds the vendor initramfs
  boot.kernel.enable = false; # our own 4.19.125 lives in its own partition

  # Splice our modules tree in at the path the NixOS-patched kmod searches.
  # `boot.kernel.enable = false` skips the stock `ln -s ... $out/kernel-modules`,
  # so we add it back by hand; stage 2 then points /run/booted-system at it.
  system.systemBuilderCommands = ''
    ln -s ${modulesTree} $out/kernel-modules
  '';

  # No nix on the appliance: the rootfs is a fixed closure produced by the
  # build host. This is also what keeps the image small. It means an OTA
  # cannot `nixos-rebuild` on the device -- see docs/nixos-rootfs.md.
  nix.enable = false;
  system.switch.enable = lib.mkDefault true; # keep switch-to-configuration for OTA

  # =====================================================================
  # 2. Filesystems -- the eMMC partition map (docs/flashing-and-recovery.md)
  # =====================================================================
  fileSystems."/" = {
    device = "/dev/mmcblk0p17";
    fsType = "ext4";
    options = [ "noatime" ];
  };
  # p16 = boot (vfat). /boot/configs is sourced by the module loader.
  fileSystems."/boot" = {
    device = "/dev/mmcblk0p16";
    fsType = "vfat";
    options = [ "nofail" "noatime" ];
  };
  swapDevices = [ ];

  # =====================================================================
  # 3. FHS accommodation for the closed media stack
  # =====================================================================
  # Vendor binaries request /lib/ld-linux-aarch64.so.1 as their interpreter.
  environment.ldso = "${pkgs.glibc}/lib/ld-linux-aarch64.so.1";

  systemd.tmpfiles.rules = [
    # /opt/lib -- the media libs. libkvm's DT_RPATH is "/opt/lib:<store>", so
    # it resolves either way, but the vendor code that dlopens by bare name
    # (libsns_dummy.so) needs the FHS path to exist.
    "d /opt 0755 root root - -"
    "L+ /opt/lib - - - - ${axLibs}/lib"
    # /soc -- module blobs + the curated loader, from our pins.
    "d /soc 0755 root root - -"
    "L+ /soc/ko - - - - ${axKo}"
    "d /soc/scripts 0755 root root - -"
    "L+ /soc/scripts/auto_load_all_drv.sh - - - - ${axLoader}/bin/auto_load_all_drv.sh"
    # /kvmapp -- immutable app tree. NOTE: this is a behaviour change from the
    # vendor rootfs, where /kvmapp is writable and hot patches persist there.
    # On this rootfs hot patches only apply to /dev/shm/kvmapp (the tmpfs copy)
    # and are lost on reboot; the deploy-iterate skill assumes otherwise.
    "L+ /kvmapp - - - - ${kvmapp}"
    # /etc/kvm -- writable server state: server.yaml plus the HTTPS cert+key
    # nanokvm.sh regenerates. Must survive reboots.
    "d /etc/kvm 0700 root root - -"
    "d /var/log/nanokvm 0755 root root - -"
  ];

  # =====================================================================
  # 4. Kernel modules loaded at boot
  # =====================================================================
  # lt6911_manage: the HDMI->CSI bridge poller libkvm reads /proc/lt6911_info
  # from. fb_jd9853 (pulls fbtft), gpio_keys, rotary_encoder: the mini-display
  # stack (docs/mini-display.md). All from OUR kernel build; all safe to load
  # parameter-less (they bind DT nodes), unlike the ax_*.ko set.
  boot.kernelModules = [
    "lt6911_manage"
    "fb_jd9853"
    "gpio_keys"
    "rotary_encoder"
  ];

  # =====================================================================
  # 5. Services
  # =====================================================================

  # 5a. The Axera media modules. On the vendor rootfs this is run by an init
  # script; here it is a first-class unit, ordered before anything that opens
  # the capture pipeline.
  systemd.services.ax-modules = {
    description = "Load Axera media kernel modules (curated 12 of 22, issue #39)";
    wantedBy = [ "multi-user.target" ];
    before = [ "nanokvm.service" ];
    after = [ "systemd-modules-load.service" ];
    unitConfig.ConditionPathExists = "/soc/ko/ax_sys.ko";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${axLoader}/bin/auto_load_all_drv.sh -i";
      ExecStop = "${axLoader}/bin/auto_load_all_drv.sh -r";
    };
  };

  # 5b. ATX target power/reset GPIOs. Straight port of nanokvm-gpio.service
  # (pkgs/nanokvm-display.nix). The devmem write is the SW_PWR pinmux trap:
  # gpio7 sits on the VI_D7 pad and sysfs export never programs the mux
  # (docs/mini-display.md).
  systemd.services.nanokvm-gpio = {
    description = "NanoKVM-Pro ATX GPIO setup (target power/reset pins)";
    wantedBy = [ "multi-user.target" ];
    before = [ "nanokvm.service" "nanokvm-display.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = [
        "${pkgs.busybox}/bin/devmem 0x02300060 32 0x00060003"
        ''${pkgs.bash}/bin/sh -c 'cd /sys/class/gpio && for p in 7:low 35:low 74:in 75:in; do n=''${p%%:*} d=''${p##*:}; [ -d gpio$n ] || echo $n > export; echo $d > gpio$n/direction; done' ''
      ];
    };
  };

  # 5c. The KVM server. Mirrors the vendor service model: the app tree is
  # copied to tmpfs at boot and the binary runs from there (docs/architecture.md
  # "Runtime service model").
  #
  # TODO(#26): the vendor ExecStart (nanokvm.sh) is a supervisor that also
  # verifies/regenerates the HTTPS cert+key under /etc/kvm and gives up after
  # 3 crash-restarts. That script lives only in the vendor rootfs; it must be
  # read off the device and either ported here or replaced by Restart= plus a
  # cert-generation ExecStartPre. Until then this unit is UNVERIFIED.
  systemd.services.nanokvm = {
    description = "NanoKVM-Pro server (open stack)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "ax-modules.service" ];
    requires = [ "ax-modules.service" ];
    serviceConfig = {
      Type = "simple";
      WorkingDirectory = "/dev/shm/kvmapp/server";
      ExecStartPre = "${pkgs.bash}/bin/sh -c '${pkgs.coreutils}/bin/rm -rf /dev/shm/kvmapp && ${pkgs.coreutils}/bin/cp -rL /kvmapp /dev/shm/kvmapp && ${pkgs.coreutils}/bin/chmod -R u+w /dev/shm/kvmapp'";
      ExecStart = "/dev/shm/kvmapp/server/NanoKVM-Server";
      Restart = "on-failure";
      RestartSec = 3;
      StandardOutput = "append:/var/log/nanokvm/NanoKVM-Server.log";
      StandardError = "inherit";
    };
  };

  # 5d. Mini-display status daemon (pkgs/nanokvm-display.nix, pure stdlib
  # Python). Declared natively instead of shipping the package's unit file,
  # whose ExecStart hardcodes /usr/bin/python3.
  systemd.services.nanokvm-display = {
    description = "NanoKVM-Pro mini-display status screen";
    wantedBy = [ "multi-user.target" ];
    after = [ "systemd-modules-load.service" ];
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 ${nanokvm.nanokvm-display}/opt/nanokvm-display/nanokvm_display.py";
      Restart = "on-failure";
      RestartSec = 5;
      Nice = 10;
    };
  };

  # 5e. Per-device identity (MAC + hostname), recovered from the SoC UID.
  #
  # This exists because of something the vendor initramfs does that is easy to
  # miss: before `switch_root` it derives a stable MAC from the AX630C UID and
  # SED-EDITS IT INTO /etc/network/interfaces on the rootfs
  # (`hwaddress ether 48:da:35:6d:HH:LL`), and on a first boot writes
  # /etc/hostname = kvm-HHLL. Both are ifupdown/Ubuntu-shaped writes into files
  # that on NixOS are read-only store symlinks, so BOTH SILENTLY FAIL HERE and
  # the device would come up with a kernel-random MAC and a fixed hostname --
  # breaking DHCP reservations and mDNS identity across a fleet.
  #
  # The initramfs still writes /device_key (a plain file at the root of the
  # rootfs, which the server also reads), so we reproduce its arithmetic from
  # that file: mac = 48:da:35:6d:<first 4 hex of sha512(/device_key)>.
  #
  # TODO(#26): the interface name and whether NanoKVM-Server depends on the
  # exact hostname form are UNVERIFIED against the device.
  systemd.services.nanokvm-identity = {
    description = "Apply the NanoKVM-Pro per-device MAC and hostname (from the SoC UID)";
    wantedBy = [ "network-pre.target" ];
    before = [ "network-pre.target" "systemd-networkd.service" ];
    after = [ "local-fs.target" ];
    unitConfig.ConditionPathExists = "/device_key";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ coreutils iproute2 systemd gnugrep ];
    script = ''
      set -eu
      mac_uid=$(sha512sum /device_key | head -c 4)
      hi=''${mac_uid:0:2}; lo=''${mac_uid:2:2}
      mac="48:da:35:6d:''${hi}:''${lo}"
      hostnamectl set-hostname "kvm-''${hi}''${lo}" || true
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

  # 5f. Grow the rootfs to fill p17 on first boot.
  #
  # make-ext4-fs shrinks the image to fit its contents (+16 MiB), so the
  # flashed rootfs is ~1 GB inside a ~30 GB partition. The vendor grows it from
  # the INITRAMFS, but only by copying STATIC binaries out of the rootfs at
  # /opt/e2fs-static/{tune2fs,resize2fs} -- a path this rootfs does not have.
  # That failure is benign (the initramfs falls through, clears
  # /boot/check_resize2fs and boots anyway), so instead of shipping a static
  # e2fsprogs we grow online from here: ext4 supports online resize, and doing
  # it in the running system is both simpler and observable.
  systemd.services.nanokvm-grow-rootfs = {
    description = "Grow the root filesystem to fill its partition";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.e2fsprogs}/bin/resize2fs /dev/mmcblk0p17";
      # Already-maximal is exit 0 with a message; a genuine failure must not
      # block the boot of an otherwise healthy appliance.
      SuccessExitStatus = "0 1";
    };
  };

  # =====================================================================
  # 6. Base system
  # =====================================================================
  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
    settings.PasswordAuthentication = true;
  };

  # LAN discovery, same role avahi plays on the vendor rootfs.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
  };

  # Time sync. Replaces the vendor chrony + its time.{windows,apple,google}.com
  # host list (docs/provenance.md); timesyncd talks to the NTP pool only.
  services.timesyncd.enable = true;

  networking.hostName = "nanokvm";
  networking.useNetworkd = true;
  networking.useDHCP = lib.mkDefault true;
  networking.firewall.enable = false; # appliance on a trusted LAN, ports 22/80/443

  users.mutableUsers = true;
  # Parity with the vendor image's documented default
  # (docs/flashing-and-recovery.md). CHANGE ON FIRST BOOT.
  users.users.root.initialPassword = "sipeed";

  # eMMC is the only writable medium; an unbounded journal is what chewed
  # ~100 MB/week during the wifi.service restart loop (issue #43).
  services.journald.extraConfig = ''
    SystemMaxUse=32M
    RuntimeMaxUse=16M
  '';

  # /var/log/nanokvm/*.log is NanoKVM-Server's redirected stdout; copytruncate
  # is mandatory because the fd is held open for the process lifetime (#41).
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

  environment.systemPackages = with pkgs; [
    busybox # devmem, and the shell tooling the vendor scripts assume
    kmod
    e2fsprogs
    pciutils
    usbutils
    iproute2
    python3
  ];

  # Nothing here should ever try to build documentation into the image.
  documentation.enable = false;
  documentation.nixos.enable = false;
}
