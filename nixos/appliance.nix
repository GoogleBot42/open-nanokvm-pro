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
  # This whole derivation is what becomes /opt/lib. It must be ONE derivation,
  # not a patch step plus a copy: the patched .so carry rpaths naming their own
  # store directory, so copying them elsewhere drags the intermediate into the
  # closure and ships the entire vendor lib set twice.
  #
  # It also carries our FROM-SOURCE ISP dummy-sensor library (issue #30), and
  # that is a provenance win the overlay build cannot claim. The MSP repo that
  # `pkgs/axera-libs.nix` pins ships NO `libsns_dummy.so` at all -- only
  # `libsns_dummy_bittrue.so`; that derivation's "WARN: libsns_dummy.so not
  # found" has always been firing. On the vendor Ubuntu rootfs the file exists
  # only because the retained vendor image carries a prebuilt copy at /opt/lib,
  # which pkgs/rootfs.nix step [5a1] then overwrites with ours. A pure-Nix
  # rootfs has no vendor image to inherit from, so here the from-source build
  # is not an override -- it is the only source, and the blob has nowhere to
  # come back from. It has to live in THIS directory because the capture
  # backend dlopens it by bare name from libs whose rpath names /opt/lib.
  axLibs = pkgs.stdenv.mkDerivation {
    pname = "nanokvm-opt-lib";
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
    # The vendor set has genuine internal cycles and several libs with no
    # consumer in our stack; a missing dep must not fail the whole build.
    autoPatchelfIgnoreMissingDeps = true;
    installPhase = ''
      mkdir -p "$out"
      cp -a "$src/lib" "$out/lib"
      chmod -R u+w "$out/lib"
      install -m0755 ${nanokvm.libsns-dummy}/lib/libsns_dummy.so "$out/lib/libsns_dummy.so"

      # libopus + libasound MUST live here. libkvm.so.0 DT_NEEDEDs both, and
      # its DT_RPATH is exactly "/opt/lib:<axera-libs store path>" -- neither of
      # which contains them. On the vendor Ubuntu rootfs they resolve anyway,
      # from the distro's default loader path (/lib/aarch64-linux-gnu) and from
      # /opt/usr/lib. NixOS has no default loader path, so without this the
      # server dies at startup with "libasound.so.2: cannot open shared object
      # file" -- the same class of failure as the DT_RPATH-vs-DT_RUNPATH trap in
      # docs/architecture.md. Copied (not symlinked) so the SONAME resolves
      # inside this one directory.
      cp -aL ${nanokvm.opus}/lib/libopus.so*    "$out/lib/"
      cp -aL ${nanokvm.alsaLib}/lib/libasound.so* "$out/lib/"
      # libjpeg.so.8 backs the openVenc soft-MJPEG path (#51); harmless
      # ballast when the image carries the vendor-encoder libkvm instead.
      cp -aL ${nanokvm.jpeg}/lib/libjpeg.so*    "$out/lib/"
      chmod -R u+w "$out/lib"

      for must in libax_venc.so libsns_dummy.so libopus.so.0 libasound.so.2 libjpeg.so.8; do
        test -e "$out/lib/$must" \
          || { echo "ERROR: $must missing from /opt/lib -- the server will not start" >&2; exit 1; }
      done
    '';
    meta.description =
      "/opt/lib for the Nix rootfs: Axera media libs autoPatchelf'd for NixOS, plus our from-source libsns_dummy.so";
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
    # RUN THE VENDOR SCRIPT VERBATIM. writeShellApplication defaults to injecting
    # `set -o errexit -o nounset -o pipefail`; under `nounset` the vendor script
    # dies on its own bug -- get_cmm_param reads $OS_MEM_MIN_SIZE but the file
    # defines OS_MEM_MIN_SZIE (a typo) -- so ax-modules.service would fail and
    # nanokvm.service (Requires=it) would never start: no capture, no web UI. It
    # is ALSO fragile under errexit (already-loaded insmod/rmmod, the `mem=` grep
    # miss) and pipefail. bashOptions=[] runs it exactly as the Ubuntu overlay
    # does under plain `bash` via rc.local -- the empty $OS_MEM_MIN_SIZE at
    # get_cmm_param is harmless because both if/else branches immediately
    # recompute os_mem_size from the correctly-spelled OS_MEM_MIN_SZIE.
    bashOptions = [ ];
    text = builtins.readFile ../pkgs/rootfs/ax-load-drv.sh;
  };

  # ---- ether-wake compat shim (Wake-on-LAN) ------------------------------
  # The server's WoL route runs exactly `ether-wake -b <MAC>`
  # (service/network/wol.go). That binary is Debian net-tools; nixpkgs ships no
  # package providing the name. wakeonlan (a maintained tool) sends the same
  # magic packet and broadcasts by default, so a one-line shim closes the gap
  # without patching the Go source. Only `-b <MAC>` is ever passed, so taking the
  # last argument as the MAC is sufficient and exact.
  etherWakeShim = pkgs.writeShellScriptBin "ether-wake" ''
    exec ${pkgs.wakeonlan}/bin/wakeonlan "''${@: -1}"
  '';

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

  # ---- The PATH contract for NanoKVM-Server and its script children -------
  # environment.systemPackages does NOT set a systemd unit's PATH: the built
  # nanokvm.service would otherwise carry only NixOS's default 5-package unit
  # PATH, and every bare-name `exec.Command` in the server -- and every bare-name
  # tool the vendor scripts it shells out to assume -- would fail to resolve.
  # A missing entry is a feature that silently stops working, not a build error.
  #
  # Derived from the live device's tool set PLUS a full grep of the server's Go
  # source (every exec.Command / `sh -c` first-word: ip ifconfig openssl passwd
  # aplay wpa_cli python systemctl timedatectl reboot chronyc ether-wake ps pgrep
  # grep sed awk rm touch insmod rmmod lsmod fw_printenv fw_setenv devmem
  # udhcpc/udhcpd hostapd ...). The server is the PARENT of usbdev.sh / wifi.sh /
  # mount_emmc.py, so those scripts inherit this PATH too.
  #
  # Known-absent, left as documented gaps in docs/nixos-rootfs.md (not on PATH):
  #   * chronyc    -- we run timesyncd, not chrony; the manual-NTP button no-ops.
  #   * dpkg/tailscale -- Debian OTA and the tailscale extension are out of scope.
  # (ether-wake IS provided, via the etherWakeShim above.)
  serverPath = with pkgs; [
    etherWakeShim    # `ether-wake -b <MAC>` -> wakeonlan (WoL)
    coreutils        # rm touch cat cp ln mkdir printf stat sync head tail tr wc cut date echo basename chmod
    bash             # bash + sh
    gnugrep          # grep
    gnused           # sed
    gawk             # awk
    procps           # ps pgrep pkill
    util-linux       # mount, kill, and the rest of the base util set the scripts assume
    kmod             # insmod rmmod lsmod (the module loader + usbdev.sh)
    iproute2         # ip
    nettools         # ifconfig, hostname
    iptables         # usbdev.sh NCM/NAT rules
    openssl          # nanokvm.sh regenerates the HTTPS cert+key
    ethtool          # axemac.sh (eth0 rx pause)
    wpa_supplicant   # wpa_cli (+ wpa_supplicant) -- the WiFi status/list routes
    hostapd          # wifi.sh AP mode (vendor script still to be provided)
    alsa-utils       # aplay -- the audio-test route
    shadow           # passwd root (fed on stdin when the UI changes the password)
    systemd          # systemctl timedatectl reboot hostnamectl (server drives these by bare name)
    python3          # `python` (a symlink in this pkg) -- user .py scripts + cua
    ubootTools       # fw_printenv / fw_setenv -- /boot/configs + the boot-slot scripts
    busybox          # devmem + udhcpc/udhcpd; LAST so real tools above win the lookup
  ];
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

  # THE TRAP, and why the assertion below is not paranoia:
  # 24.11's system/activation/top-level.nix branches on
  # `boot.initrd.systemd.enable` ALONE -- it never consults
  # `boot.initrd.enable`. When that option is true, `$out/init` stops being the
  # stage-2 SCRIPT and becomes a copy of the systemd ELF, meant to run as an
  # initrd PID 1. Our vendor initramfs would then exec systemd-as-initrd as the
  # real PID 1 and the board dies with no console (bootdelay=0, UART0 on hidden
  # pads). It defaults false, so we are fine today -- but 24.11's
  # profiles/image-based-appliance.nix sets it `mkDefault true`, and that
  # profile is exactly what someone would reach for next (it also sets
  # nix.enable = false and system.switch.enable = false). Fail the eval instead.
  boot.initrd.systemd.enable = false;

  assertions = [
    {
      assertion = !config.boot.initrd.systemd.enable;
      message = ''
        nixos/appliance.nix: boot.initrd.systemd.enable must stay false.
        With it on, <system>/init becomes the systemd ELF instead of the NixOS
        stage-2 script, and the vendor initramfs's `switch_root /realroot
        /sbin/init` then execs an initrd-mode systemd as PID 1. The board has
        no autoboot interrupt window and its console is on hidden pads, so that
        failure is silent. See docs/nixos-rootfs.md.
      '';
    }
    {
      # The vendor kernel is built `# CONFIG_NAMESPACES is not set`, so
      # unshare(CLONE_NEWUSER) returns EINVAL and any unit with
      # PrivateUsers=true dies with status 217/USER. Mount namespaces are
      # unconditional in Linux, which is why PrivateTmp=/ProtectSystem= still
      # work -- but user namespaces genuinely do not exist here.
      assertion = !(lib.any (u: (u.serviceConfig.PrivateUsers or false) == true)
        (lib.attrValues config.systemd.services));
      message = ''
        nixos/appliance.nix: a unit sets PrivateUsers=true, but this board's
        kernel has CONFIG_NAMESPACES=n -- user namespaces do not exist and the
        unit will fail to start with 217/USER. (For the same reason
        pkgs.buildFHSEnv, in either its bubblewrap or chroot form, cannot work
        on this device at all.) See docs/nixos-rootfs.md.
      '';
    }
  ];

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
    # /opt/usr/lib is the THIRD entry in NanoKVM-Server's DT_RUNPATH
    # ($ORIGIN/dl_lib:/opt/lib:/opt/usr/lib -- pkgs/nanokvm-server.nix sets it
    # by hand, and it contains NO store path at all). On the vendor rootfs this
    # is where libopus lives. Point it at the same directory as /opt/lib so
    # every entry in that RUNPATH resolves.
    "d /opt/usr 0755 root root - -"
    "L+ /opt/usr/lib - - - - ${axLibs}/lib"
    # /bin/bash: the vendor scripts are #!/bin/bash (nanokvm.sh is
    # #!/usr/bin/env bash, usbdev.sh and the /opt/scripts set are #!/bin/bash),
    # and NixOS materialises only /bin/sh and /usr/bin/env by default.
    "L+ /bin/bash - - - - ${pkgs.bash}/bin/bash"
    # /usr/share/zoneinfo: the server derives the timezone by readlink()ing
    # /etc/localtime and slicing on the literal "/usr/share/zoneinfo/"
    # (service/vm/datetime.go). See the known gaps in docs/nixos-rootfs.md --
    # this materialises the directory but does NOT by itself fix the readlink.
    "d /usr/share 0755 root root - -"
    "L+ /usr/share/zoneinfo - - - - ${pkgs.tzdata}/share/zoneinfo"
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
    # THE unit PATH the server + its script children resolve bare names through.
    # environment.systemPackages does not reach a unit; this does.
    path = serverPath;
    serviceConfig = {
      Type = "simple";
      WorkingDirectory = "/dev/shm/kvmapp/server";
      # LD_LIBRARY_PATH=/opt/lib is the documented, load-bearing fallback for the
      # bare-name dlopen chain (libsns_dummy.so, and libkvm's libopus/libasound
      # DT_NEEDEDs) -- see docs/nixos-rootfs.md "the fallback ladder". It adds
      # only /opt/lib (media libs), never a glibc, so it cannot create the
      # mismatched-loader/libc crash that an explicit ${glibc}/lib would.
      Environment = "LD_LIBRARY_PATH=/opt/lib";
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
    # `wantedBy = network-pre.target` alone is PASSIVE: nothing in this closure
    # pulls network-pre.target (it is a firewall/networkd hook and the firewall
    # is disabled), so the unit would never run and every boot would keep the
    # kernel-random MAC. Pull it via multi-user.target and only ORDER it before
    # network-pre.target -- per systemd.special(7), Wants= creates the pull that
    # WantedBy on a passive target cannot. (before= keeps the MAC set before any
    # network unit brings the link up.)
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-pre.target" ];
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

  # 5g. Confirm the active A/B boot slot on every boot -- the S99checkboot
  # equivalent. The vendor init script reads `bootsystem=` with fw_printenv and
  # writes the SoC boot-slot register (devmem 0x2390028 32 0x10 for slot A, 0x20
  # for slot B) so the bootloader keeps booting the slot that just came up;
  # without it, an OTA to the other slot is never confirmed and the board can
  # fall back (docs/nixos-rootfs.md "S99checkboot is load-bearing, confirmed").
  #
  # It is GATED on /etc/fw_env.config: the libubootenv fw_printenv/fw_setenv this
  # depends on (docs/provenance.md) needs that file to locate the U-Boot
  # environment on eMMC, and its exact contents (device/offset/size of the env)
  # are NOT recoverable host-side -- they must be read off the device. Until the
  # file is provided the unit is inert BY DESIGN: writing 0x2390028 for a guessed
  # slot could break A/B fallback, exactly the blind devmem write the project
  # refuses to make. The register semantics themselves are transcribed verbatim
  # from the RE, so the moment /etc/fw_env.config lands (a documented capture
  # TODO) this becomes correct with no further code change.
  #
  # NOTE: S99checkota (fw_setenv clears of upgrade_slot{a,b}_available) is part
  # of the OTA-commit flow, not boot confirmation, and belongs with the OTA
  # redesign (docs/nixos-rootfs.md gap 5) -- deliberately not reproduced here.
  systemd.services.nanokvm-checkboot = {
    description = "Confirm the active A/B boot slot (S99checkboot equivalent)";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    unitConfig.ConditionPathExists = "/etc/fw_env.config";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ ubootTools busybox gnugrep gnused ];
    script = ''
      # Only ever write the register for a slot fw_printenv DEFINITELY reports.
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
    # MUST be false. With startWhenNeeded=true, 24.11's sshd module defines only
    # `services."sshd@"` (a template) + `sockets.sshd` -- there is NO plain
    # `sshd.service`, so aliasing `ssh.service` onto it fabricates an empty,
    # ExecStart-less unit that systemd refuses to load, and the web UI's SSH
    # ENABLE path (StartService("ssh.service") -> EnableUnitFiles + RestartUnit)
    # fails. With it false the module defines a real persistent `sshd.service`
    # (ExecStart=`${sshd} -D -f ...`, Type=simple, Restart=always,
    # WantedBy=multi-user.target) -- which is also what Debian ships as the
    # `ssh.service` the server drives. sshd then runs from boot, matching how
    # the device is reached today (tools/kvmssh).
    startWhenNeeded = false;
  };

  # NanoKVM-Server toggles SSH by talking to org.freedesktop.systemd1 directly
  # (utils/systemctl.go, service/vm/ssh.go) using DEBIAN unit names. Its PRIMARY,
  # error-checked operations are all on `ssh.service`:
  #   EnableSSH  -> StartService("ssh.service", enable=true)  (EnableUnitFiles + RestartUnit)
  #   DisableSSH -> StopService("ssh.service", disable=true)  (systemctl stop + disable)
  #   GetSSHState-> IsServiceRunning("ssh.service") || IsServiceRunning("ssh.socket")
  # The `ssh.socket` operations are all best-effort (`_ = ...`, errors ignored),
  # and isSSHRunning tolerates a socket lookup that errors. So aliasing
  # `ssh.service` onto the real daemon makes the toggle fully work end to end.
  #
  # We deliberately do NOT alias `ssh.socket`: startWhenNeeded=false means there
  # is no `sockets.sshd` to alias, and referencing `systemd.sockets.sshd` here
  # would fabricate a ListenStream-less socket that systemd refuses to load --
  # strictly worse than an absent unit, which the server already handles.
  systemd.services.sshd.aliases = [ "ssh.service" ];

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

  # Login shells + any unit without its own `path=`. The nanokvm.service PATH
  # contract lives in `serverPath` (see the let block and 5c above); this list
  # is the interactive/system-wide superset so an admin over SSH, and the vendor
  # scripts a human runs by hand, find the same tools. A missing entry is a
  # feature that silently stops working, not a build error.
  environment.systemPackages = with pkgs; [
    busybox # devmem, udhcpd/udhcpc, and the shell tooling the scripts assume
    bash
    kmod # insmod / rmmod / lsmod
    e2fsprogs
    coreutils
    util-linux # mount + the base util set the vendor scripts assume
    gnugrep
    gnused
    gawk
    procps # ps, pgrep, pkill
    iproute2 # ip
    nettools # ifconfig
    iptables
    openssl # nanokvm.sh regenerates the HTTPS cert+key
    ethtool # /etc/init.d/axemac.sh (eth0 RPS/RFS + rx pause)
    ubootTools # fw_printenv / fw_setenv -- /boot/configs + the A/B boot-slot scripts
    etherWakeShim # `ether-wake -b <MAC>` -> wakeonlan (WoL); see the shim above
    alsa-utils # server audio test: `aplay -D plughw:UAC2Gadget,0 ...`
    wpa_supplicant # wpa_cli, used by the network settings routes
    shadow # `passwd root`, fed on stdin when the UI changes the password
    tzdata
    python3
    pciutils
    usbutils
  ];

  # Nothing here should ever try to build documentation into the image.
  documentation.enable = false;
  documentation.nixos.enable = false;
}
