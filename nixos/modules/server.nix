{ config, lib, pkgs, nanokvm, ... }:

# ===========================================================================
# NanoKVM-Server and the web UI: the app tree, the FHS paths the
# vendor-shaped binaries reach through, the HTTPS certificate, and the PATH
# contract the server's script children inherit.
#
# ENABLES: `nanokvm.service` (the Go server, run from a tmpfs copy of
# /kvmapp exactly as the vendor service model does), `nanokvm-appdir`,
# `nanokvm-cert`, the USB-gadget stub, logrotate over the server's redirected
# stdout, the `ssh.service` alias the web UI's SSH toggle needs, and the
# interactive superset of the server's own unit PATH.
#
# HARDWARE FACTS IT ENCODES: none directly -- this is the application layer.
# What it encodes instead is the BINARY's contract: NanoKVM-Server's
# DT_RUNPATH is the store-free "$ORIGIN/dl_lib:/opt/lib:/opt/usr/lib", it
# dlopens libkvm (which needs DT_RPATH, not DT_RUNPATH, to pass its own
# dependencies down), it execs a dozen bare-name tools that
# `environment.systemPackages` does NOT put on a unit's PATH, and it
# readlink()s /etc/localtime expecting a "/usr/share/zoneinfo/" prefix.
#
# THE CLOSURE IS ASSERTED BLOB-FREE HERE: the `kvmapp` derivation fails the
# build if libkvm or the server still references the closed Axera media
# libraries.
# ===========================================================================

let
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
in
{
  options.nanokvm = {
    server.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run NanoKVM-Server (the web UI, ATX, network and update routes).";
    };
  };

  config = {
    # =====================================================================
    # 4. FHS accommodation
    # =====================================================================
    # NanoKVM-Server and libkvm request /lib/ld-linux-aarch64.so.1.
    environment.ldso = "${pkgs.glibc}/lib/ld-linux-aarch64.so.1";

    # mkOrder pins where these land in the one merged list (#87).
    systemd.tmpfiles.rules = lib.mkOrder 300 [
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

    # THE VERSION THIS GENERATION IS, as a file INSIDE the closure (#86). The
    # web UI reads `/kvmapp/version`, which is a store symlink and therefore
    # also per-generation -- but `nanokvm-update` needs the version of the
    # RUNNING system specifically, and `/run/current-system/etc/nanokvm-version`
    # is the only thing that says it without guessing. Making it part of the
    # closure is what removes the need for any mutable version stamp at all:
    # a rollback rolls the version back with everything else.
    environment.etc."nanokvm-version".text = "${nanokvm.version}\n";

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
    # (docs/architecture.md "Service model").
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

    # NanoKVM-Server toggles SSH over org.freedesktop.systemd1 using DEBIAN
    # unit names; every error-checked operation is on `ssh.service`
    # (utils/systemctl.go, service/vm/ssh.go). The `ssh.socket` operations are
    # all best-effort, so aliasing the service alone makes the toggle work end
    # to end. We deliberately do NOT alias ssh.socket -- there is no socket
    # unit to alias, and fabricating one systemd refuses to load is worse than
    # an absent unit the server already tolerates.
    #
    # Guarded, because a definition under `systemd.services.sshd` would
    # otherwise CREATE a broken unit on a system that does not run sshd.
    systemd.services.sshd.aliases =
      lib.mkIf config.services.openssh.enable [ "ssh.service" ];

    # Login shells and any unit without its own `path=`. The unit PATH contract
    # lives in `serverPath`; this is the interactive superset, so an admin over
    # SSH finds the same tools.
    # mkOrder pins where this lands (#87). It is the LAST contributor, which
    # is where this list was when it was one list in one file.
    environment.systemPackages = lib.mkOrder 500 (with pkgs; [
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
  };
}
