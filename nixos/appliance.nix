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
#   * A REAL BOOTLOADER, AND ONE WRITER OF /boot (#99). BootROM -> SPL -> TF-A
#     -> U-Boot, all mainline. U-Boot's `bootcmd` runs `sysboot` on
#     /boot/extlinux/extlinux.conf, and that file is written by NixOS's own
#     `boot.loader.generic-extlinux-compatible` builder -- nothing in this
#     repo generates it, and nothing but `switch-to-configuration boot` writes
#     it. The kernel, the initrd and the dtb are copied into /boot/nixos/ by
#     the same builder, from the generation that owns them.
#
#   * THE KERNEL IS PART OF THE GENERATION. `boot.kernelPackages` is
#     pkgs/kernel-mainline, so a generation carries its own kernel, initrd and
#     device tree, and a kernel change is a generation change: it rolls back
#     with everything else and needs no out-of-band copy. This replaced an
#     initrd baked into the Image with CONFIG_INITRAMFS_SOURCE, which was a
#     workaround for the VENDOR U-Boot's initrd-less `booti` and outlived it
#     by two issues.
#
#   * `init=` COMES FROM THE BOOTLOADER, per entry. Each LABEL's APPEND pins
#     `init=<generation>/init`, which is what lets extlinux.conf and
#     extlinux-fallback.conf name two different generations. The image's
#     `/init` symlink to the system profile is kept as a backstop, not as the
#     mechanism.
#
#   * SIX MODULES, AND NOTHING ELSE MODULAR. All but the video stack's
#     drivers are built into the Image. Those six ride in the closure as
#     `nanokvm.video-modules` (pkgs/video-modules.nix), a /lib/modules tree
#     built from the SAME kernel derivation this generation boots -- which is
#     what closes the seam #83 had to leave open, when the kernel was a /boot
#     artefact outside every generation and could disagree with them.
#     `system.modulesTree` stays empty: nanokvm-video.service loads them by
#     path, in the order the build resolved.
#
#   * NO CLOSED CODE. The shipped video stack has been blob-free since #60,
#     so unlike its predecessor this module stages no Axera libraries and no
#     vendor .ko. nixos/rootfs.nix asserts that (blob policy, CLAUDE.md).
# ===========================================================================

let
  # THE eMMC LAYOUT (#89 rung 4), from the one place it is defined. The root
  # device, /boot and /etc/fw_env.config all follow from it. There is one
  # layout since #97 -- `spl` plus a GPT-carrying `disk`.
  parts = import ./emmc-partitions.nix { inherit lib; };
  cfg = config.nanokvm;

  # ---- /kvmapp : the app tree the service model copies to tmpfs ----------
  # Layout is the vendor's (server/{NanoKVM-Server,web,dl_lib}, version), so
  # NanoKVM-Server finds ./web and $ORIGIN/dl_lib exactly as it does today.
  #
  # libkvm.so is RE-RPATH'd here so the three open libraries it needs are named
  # by store path rather than reached for in /opt/lib. It used to also be how
  # the closed Axera library set was kept out of the closure -- kvm-encoder.nix
  # put "<axera-libs>/lib" in the RPATH, which on an overlay rootfs is a dead
  # string but in a Nix closure is a REFERENCE. That entry, and the SDK it came
  # from, are gone (#102); the assertions below stay as the regression guard.
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
      # ... and neither binary may ASK for one either (#102): a DT_NEEDED on a
      # libax_* is a server that cannot start on a blob-free image.
      if grep -qa 'libax_' "$f"; then
        echo "ERROR: $f names a closed Axera library (libax_*)." >&2
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

  # ---- the two boot configs ----------------------------------------------
  #
  #   /boot/extlinux/extlinux.conf           NixOS writes it; the default boot
  #   /boot/extlinux/extlinux-fallback.conf  DERIVED from it by mark-good
  #
  # U-Boot's `bootcmd` runs `sysboot ... ${extlinux_cfg}`; its `altbootcmd`,
  # which `bootcount` > `bootlimit` selects, runs the same command against
  # ${extlinux_fallback}. `sysboot` boots a config's DEFAULT entry and has no
  # way to be told a LABEL, so the choice of generation is made by choosing a
  # FILE -- but since #99 the two files have the SAME labels, and only their
  # DEFAULT line differs. That is what makes the fallback a derivation of the
  # official config rather than a second generator: nothing in this repo
  # renders an extlinux.conf any more.
  #
  # nixos/lib/mark-good.nix is the script and its reasoning; it lives there
  # rather than here so `nix flake check`'s `nanokvm-mark-good-fallback` can
  # instantiate it against the BUILD host's package set and run it for real.
  markGood = import ./lib/mark-good.nix {
    inherit pkgs lib;
    serverEnabled = cfg.server.enable;
    timeoutSec = cfg.markGood.timeoutSec;
    tolerateFailed = cfg.markGood.tolerateFailed;
  };

  # ---- the updater (#86, nix-native since #100) ---------------------------
  # nixos/lib/updater.nix's header is the design; this is only the wiring.
  updateTools = import ./lib/updater.nix {
    inherit pkgs lib;
    # The SAME nix the system runs, so the tool cannot disagree with the store
    # it is writing into.
    nix = config.nix.package;
    stableUrl = cfg.update.stableUrl;
    previewUrl = cfg.update.previewUrl;
    manifestName = cfg.update.manifestName;
    keepGenerations = cfg.update.keepGenerations;
    cacheUrl = cfg.update.cacheUrl;
    trustedPublicKeys = cfg.update.trustedPublicKeys;
    idleQuietSec = cfg.update.idleQuietSec;
    # No server = nothing that could be using the device, so the idle gate is
    # satisfied by construction rather than by a curl that can only fail.
    idleUrl = lib.optionalString cfg.server.enable
      "https://127.0.0.1/api/update/idle";
    # A configured window means the install must never reboot on its own: the
    # window is enforced by `nanokvm-update-reboot`'s OnCalendar, and an
    # `update` that rebooted at install time would walk straight past it.
    rebootImmediately = cfg.update.rebootWindow == null;
  };

  # ---- the U-Boot chainload test slot ------------------------------------
  # The minimal layout has one `uboot` partition and no B twin, so trying a
  # U-Boot candidate by writing it is a USB-recovery trip. U-Boot patch 0025
  # gives the partition its A/B property back as a FILE: on the first boot
  # attempt after a healthy one, `bootcmd` loads /boot/uboot-test.bin to
  # CONFIG_TEXT_BASE and chainloads it. This is the appliance's half -- putting
  # the file there, and taking it away again after the one attempt.
  #
  # NOTHING HERE WRITES FLASH. Staging is a copy; recovery is a reboot.
  ubootTest = pkgs.writeShellApplication {
    name = "nanokvm-uboot-test";
    runtimeInputs = with pkgs; [ coreutils busybox gnugrep ];
    text = ''
      set -eu

      TESTFILE=/boot/uboot-test.bin
      # The arming token, and the reason the slot is safe: one 512-byte block
      # at the head of the unused `env` partition. U-Boot zeroes it BEFORE it
      # jumps, so a candidate is tried exactly once, ever. It has to live in
      # flash -- an earlier version armed on `bootcount`, which clears on power
      # loss, so the cold cycle that recovers a hung board re-armed the
      # candidate that hung it and the board could not be recovered at all.
      TOKPART=/dev/loop0p3
      BOOTCOUNT_REG=0x02390030
      MSREG=0x02390024
      # The chainload record U-Boot leaves in the spare page of the pstore
      # window: 0x43484C44 ("CHLD") and the address it jumped to.
      CHLD_REG=0x480EE000
      CHLD_ADDR=0x480EE004

      usage() {
        cat >&2 <<'EOF'
      usage: nanokvm-uboot-test stage <u-boot.bin> | clear | status

        stage   put a RAW U-Boot image (images/u-boot.bin, device tree
                appended -- NOT the signed container) in the test slot. The
                next boot chainloads it, once. A candidate that hangs is reset
                by the watchdog and the boot after it runs the production
                U-Boot on flash, unattended.
        clear   remove it.
        status  say what is staged, and what the last boot did with it.
      EOF
        exit 2
      }

      [ $# -ge 1 ] || usage

      case "$1" in
      stage)
        [ $# -eq 2 ] || usage
        src="$2"
        [ -f "$src" ] || { echo "nanokvm-uboot-test: no such file: $src" >&2; exit 1; }
        [ -d /boot ] || { echo "nanokvm-uboot-test: /boot is not there" >&2; exit 1; }
        mountpoint -q /boot \
          || { echo "nanokvm-uboot-test: /boot is not mounted -- U-Boot would never see the file" >&2; exit 1; }

        size=$(stat -c%s "$src")
        if [ "$size" -lt 65536 ] || [ "$size" -gt 2097152 ]; then
          echo "nanokvm-uboot-test: $src is $size bytes; a U-Boot image for this board is 64 KiB..2 MiB" >&2
          exit 1
        fi

        # The image must be the RAW one, linked at 0x5C000400. arch/arm/cpu/
        # armv8/start.S puts `_TEXT_BASE: .quad CONFIG_TEXT_BASE` at offset 8,
        # so those eight bytes are a free, exact identity check -- and they are
        # what separates a raw u-boot.bin from the axgzip'd signed container
        # (which would be loaded and jumped into as if it were code), from a
        # kernel Image, and from a U-Boot built for another board.
        got=$(od -An -tx8 -j8 -N8 "$src" | tr -d ' \n')
        if [ "$got" != "000000005c000400" ]; then
          echo "nanokvm-uboot-test: $src does not carry _TEXT_BASE = 0x5C000400 at offset 8" >&2
          echo "nanokvm-uboot-test: found $got -- this is not a raw u-boot.bin for this board." >&2
          echo "nanokvm-uboot-test: stage images/u-boot.bin, NOT u-boot_mainline_signed.bin." >&2
          exit 1
        fi

        cp "$src" "$TESTFILE.new"
        sync "$TESTFILE.new"
        mv "$TESTFILE.new" "$TESTFILE"
        sync

        # Verify from the medium, not the page cache.
        echo 3 > /proc/sys/vm/drop_caches
        a=$(md5sum < "$src" | cut -d' ' -f1)
        b=$(md5sum < "$TESTFILE" | cut -d' ' -f1)
        [ "$a" = "$b" ] || { echo "nanokvm-uboot-test: read-back mismatch $a != $b" >&2; exit 1; }

        # Arm it, last: the token is what U-Boot acts on, so it must not be
        # there before the file it names is.
        [ -b "$TOKPART" ] || { echo "nanokvm-uboot-test: no $TOKPART" >&2; exit 1; }
        { printf 'CHTK'; dd if=/dev/zero bs=508 count=1 2>/dev/null; } \
          | dd of="$TOKPART" bs=512 count=1 conv=fsync 2>/dev/null
        sync
        echo 3 > /proc/sys/vm/drop_caches
        [ "$(dd if="$TOKPART" bs=4 count=1 2>/dev/null)" = CHTK ] \
          || { echo "nanokvm-uboot-test: token did not stick" >&2; exit 1; }

        echo "nanokvm-uboot-test: staged $size bytes, md5 $b"
        echo "nanokvm-uboot-test: armed (token CHTK in $TOKPART, spent by the attempt)"
        echo "nanokvm-uboot-test: bootcount is $(devmem $BOOTCOUNT_REG 32) (0xB0010000 = healthy)"
        echo "nanokvm-uboot-test: reboot to try it, then \`nanokvm-uboot-test status\`:"
        echo "  chainload: no                       nothing was chainloaded"
        echo "  chainload: yes, ms_uboot clear      the candidate never reached its own preboot"
        echo "  chainload: yes, ms_uboot set        two U-Boot passes in one boot"
        ;;
      clear)
        rm -f "$TESTFILE" "$TESTFILE.new"
        if [ -b "$TOKPART" ]; then
          dd if=/dev/zero of="$TOKPART" bs=512 count=1 conv=fsync 2>/dev/null
        fi
        sync
        echo "nanokvm-uboot-test: cleared (file and token)"
        ;;
      status)
        if [ -e "$TESTFILE" ]; then
          echo "staged: $(stat -c%s "$TESTFILE") bytes, md5 $(md5sum < "$TESTFILE" | cut -d' ' -f1)"
        else
          echo "staged: nothing"
        fi
        if [ -b "$TOKPART" ] && [ "$(dd if="$TOKPART" bs=4 count=1 2>/dev/null)" = CHTK ]; then
          echo "armed: yes -- the next boot will chainload it, once"
        else
          echo "armed: no (token spent or never written)"
        fi
        echo "bootcount: $(devmem $BOOTCOUNT_REG 32)"
        ms=$(devmem $MSREG 32)
        echo "milestones: $ms"
        # devmem prints 0x........; bit 28 is the top hex digit's bit 0.
        if [ "$(( ms & 0x10000000 ))" -ne 0 ]; then
          echo "  ms_uboot (28): set   -- a U-Boot reached preboot after the last write to this bit"
        else
          echo "  ms_uboot (28): CLEAR -- no U-Boot reached preboot since bootchain cleared it"
        fi
        chld=$(cat /run/nanokvm-uboot-test.chainload 2>/dev/null || devmem $CHLD_REG 32)
        if [ "$(( chld ))" -eq "$(( 0x43484C44 ))" ]; then
          echo "chainload: yes, to $(cat /run/nanokvm-uboot-test.addr 2>/dev/null || devmem $CHLD_ADDR 32)"
        else
          echo "chainload: no (record $chld)"
        fi
        ;;
      *)
        usage
        ;;
      esac
    '';
  };

  # ONE ATTEMPT, and this is what makes it one. U-Boot only chainloads at
  # `bootcount` == 1 and the candidate increments the counter itself, so a
  # staged file cannot loop the board -- but it would be retried after every
  # later healthy boot, which is a surprise nobody wants from a file they
  # forgot about. Removing it on the boot after it was staged makes the slot
  # strictly one-shot whichever way the attempt went.
  ubootTestClear = pkgs.writeShellApplication {
    name = "nanokvm-uboot-test-clear";
    runtimeInputs = with pkgs; [ coreutils busybox ];
    text = ''
      set -eu
      TESTFILE=/boot/uboot-test.bin

      # Latch the chainload record before anything else can lose it, and zero
      # it, so a record that is present always describes THIS boot. It lives
      # in the spare page of the pstore window and survives a chip reset,
      # which is exactly why it has to be consumed rather than left lying.
      chld=$(devmem 0x480EE000 32)
      addr=$(devmem 0x480EE004 32)
      printf '%s\n' "$chld" > /run/nanokvm-uboot-test.chainload
      printf '%s\n' "$addr" > /run/nanokvm-uboot-test.addr
      if [ "$(( chld ))" -eq "$(( 0x43484C44 ))" ]; then
        echo "uboot-test: this boot chainloaded a candidate at $addr" \
             "(milestones $(devmem 0x02390024 32))"
        devmem 0x480EE000 32 0
        devmem 0x480EE004 32 0
      fi

      # The token is U-Boot's to spend and it already has; zeroing it here is
      # belt and braces for the case where the load failed and the attempt
      # never happened. The FILE is this unit's to remove.
      if [ -b /dev/loop0p3 ]; then
        dd if=/dev/zero of=/dev/loop0p3 bs=512 count=1 conv=fsync 2>/dev/null || true
      fi

      mountpoint -q /boot || exit 0
      [ -e "$TESTFILE" ] || exit 0
      echo "uboot-test: consuming the staged candidate"
      rm -f "$TESTFILE"
      sync
    '';
  };

in
{
  # WiFi is its own module (#85): the AIC8800 needs an out-of-tree driver, a
  # firmware package, a supplicant and a script the server execs, and none of
  # that belongs in the middle of this file. It declares `nanokvm.wifi.enable`.
  imports = [ ./wifi.nix ];

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

    panel.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Load the mini-display's panel modules at boot -- `fbtft` and
        `fb_jd9853` (#84) -- so that /dev/fb0 exists and
        `nanokvm-display.service` has something to draw on. They come out of
        this generation's own closure (`pkgs/display-modules.nix`), built from
        the same kernel derivation `boot.kernelPackages` names, exactly like
        the video stack's.

        Turning this off leaves a system with no /dev/fb0, which
        `nanokvm-display` treats as "no panel on this board" and skips.
        `nixos/qemu-test.nix` does that: there is no SPI panel on a QEMU virt
        machine, so the load would succeed and the framebuffer would never
        appear.
      '';
    };

    videoStack.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Load the open capture/encode kernel modules at boot: `open_vin_csi2`,
        `open_vin_capture` and `ax630c_venc_vcmd`, plus the videobuf2 modules
        the capture node imports (#83). They are in this generation's own
        closure (`pkgs/video-modules.nix`), built from the same kernel
        derivation `boot.kernelPackages` names -- so a generation and the
        kernel it boots cannot disagree about them (#99). The load order is
        `<video-modules>/lib/modules/<release>/load-order`.

        Turning this off gives a server that serves the UI but no stream.
        `nixos/qemu-test.nix` does exactly that: the modules load fine on a
        QEMU virt machine and then nothing probes, so the unit's /dev/video0
        oracle fails on a boot that is otherwise perfect.
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

    markGood.tolerateFailed = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "nanokvm-wifi.service"
        "nanokvm-panel.service"
        "nanokvm-display.service"
      ];
      example = [ "nanokvm-wifi.service" ];
      description = ''
        Units whose failure still counts as a healthy boot. When
        `systemctl is-system-running` says `degraded` and EVERY failed unit is
        in this list, the boot counter is cleared and the generation is
        promoted anyway.

        This is the second half of a rule the units themselves implement
        first: optional hardware gets a journal line and `exit 0`, never a
        failed unit (#85's WiFi, #84's panel). Both cost a hardware round to
        the same mechanism -- a peripheral unit that `exit 1`-ed made the
        system `degraded`, `nanokvm-mark-good` polled `markGood.timeoutSec`
        and gave up, `bootcount` was never cleared, and the fourth such boot
        would have rolled a working KVM onto its previous generation over a
        missing radio or a dark status screen.

        Keep it to peripherals. A unit that is not listed still fails the
        gate, which is what keeps the rollback meaningful for the things this
        appliance is actually for: the server, the network, the capture stack.
      '';
    };

    ubootTest.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Ship `nanokvm-uboot-test` and the unit that consumes the chainload test
        slot after one attempt. The slot itself lives in U-Boot (patch 0025);
        this is only the half that stages and removes /boot/uboot-test.bin.
      '';
    };

    # ---- flake-based updates (#86, nix-native since #100) ---------------
    # This is a NixOS system and nix is on it, so an update is the standard
    # NixOS story: substitute the release's toplevel closure from our binary
    # cache, `nix-env --set` it, `switch-to-configuration boot`. What is ours
    # is the channel, the idle-gated reboot and the bootcount rollback.
    # nixos/lib/updater.nix is the implementation and docs/updates.md is the
    # design.
    update = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Ship `nanokvm-update` and its timers. The web UI's update button goes
          through the same tool (the server's install() override), so turning
          this off leaves a device that can only be updated by hand.
        '';
      };

      # THERE IS NO `auto` OPTION, and that is the design (#86). Automatic
      # updates are a CHECKBOX in the web UI -- a flag file, /etc/kvm/auto_updates,
      # beside the one the "preview updates" toggle already writes -- because
      # the person who owns the box is the person who decides whether it
      # updates itself, and they never see this file. A NixOS option would also
      # lie: the flake would read `auto = false` on a device that had been
      # updating itself for months. The timer therefore runs whenever `enable`
      # is set, and `nanokvm-update update` is a no-op while the box is
      # unticked.

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = ''
          systemd OnCalendar expression for the unattended check. The CHECK,
          not the reboot: an update installs whenever this fires and the
          checkbox is ticked, and reboots only once nobody is using the device
          (see `rebootWindow`).
        '';
      };

      rebootWindow = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "*-*-* 03..05:00/10:00";
        description = ''
          Maintenance window for the reboot half, as an OnCalendar expression.
          Null (the default) means any time, as soon as the device is idle:
          `nanokvm-update-reboot` runs every ten minutes.

          When set, THIS EXPRESSION IS THE TIMER -- so it has to fire
          repeatedly inside the window you want, not once at its start. The
          example above is every ten minutes between 03:00 and 05:00. Installs
          are unaffected; only the reboot waits.
        '';
      };

      idleQuietSec = lib.mkOption {
        type = lib.types.int;
        default = 600;
        description = ''
          How long the last web request and the last frame read must be in the
          past before the device counts as unused. The zero-valued terms of the
          idle test -- stream clients, HID sessions, web terminals, the
          mini-display preview lease, a mounted virtual-media image -- are not
          subject to it; this is the grace period on top of them.
        '';
      };

      # ---- the binary cache (#96) --------------------------------------
      # NEEDS-HUMAN, both of them: the attic server is Jeremy's to stand up and
      # the signing key is his to hold. Until they are filled in, a device
      # builds and boots but refuses to update, and the module says so at build
      # time (see `warnings` below) rather than letting it fail at 03:00.
      cacheUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "https://attic.example.org/nanokvm-pro";
        description = ''
          The binary cache an update's closure is substituted from --
          `nix copy --from`. Anything nix can read works (an attic or harmonia
          endpoint, an S3 bucket, a plain `file://` directory, `ssh://` from a
          build host). It is NOT a substituter for the whole system: only
          `nanokvm-update` reads it, and only for the toplevel a release
          manifest names.

          Authenticity does not come from this URL. Every NAR must carry a
          signature by one of `trustedPublicKeys`, so a cache that is
          compromised, mirrored or simply wrong serves paths this device
          refuses.
        '';
      };

      trustedPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "nanokvm-pro:Ihqvn9…=" ];
        description = ''
          The keys an update's NARs must be signed by, in nix's
          `<name>:<base64>` form. `nanokvm-update` passes exactly these to
          `nix copy` as `trusted-public-keys` with `require-sigs = true` -- on
          the command line, not from /etc/nix/nix.conf, so nothing an operator
          adds to the machine's nix config can widen what an update will
          install.
        '';
      };

      stableUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download";
        description = ''
          Where the updater fetches the manifest. THE ONLY CHANNEL THIS DEVICE
          KNOWS since #101 -- the server used to carry a second one compiled
          into its binary, and one press of the update button read both. The
          Gitea source of truth is Tailscale-only, so devices poll the public
          GitHub mirror's releases.
        '';
      };

      previewUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://github.com/GoogleBot42/open-nanokvm-pro/releases/download/preview";
        description = ''
          The rolling preview channel, selected by the same flag file the web
          UI's "preview updates" toggle writes (`/etc/kvm/preview_updates`).
        '';
      };

      manifestName = lib.mkOption {
        type = lib.types.str;
        default = "nanokvm_pro_sys_latest.json";
        description = ''
          The manifest this system polls. Nothing else on the device names one
          any more: since #101 the web UI's version route and its update button
          both go through `nanokvm-update`, so they cannot poll a different
          place than this tool does.

          The `_sys_` name is what keeps the retired 4.19 channel
          separate: that image polls `nanokvm_pro_latest.json`, which nothing
          publishes any more, so it is offered nothing rather than being
          offered a store closure no Ubuntu rootfs could apply.
        '';
      };

      keepGenerations = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = ''
          How many generations `nanokvm-update gc` keeps. The booted system,
          the activated one and every generation a boot config names --
          above all the ROLLBACK one -- are pinned as nix gc roots on top of
          this, so a small number cannot strand the board.
        '';
      };

      gcSchedule = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
        description = ''
          systemd OnCalendar expression for the collector. Weekly is plenty:
          an update only leaves garbage behind when it lands, and the eMMC is
          large enough that a stale generation for a few days costs nothing.
        '';
      };
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

    # =====================================================================
    # 1a. The kernel, the device tree, and the bootloader (#99)
    # =====================================================================
    # THE KERNEL IS THE GENERATION'S. `pkgs/kernel-mainline` with no embedded
    # initramfs, wrapped by `linuxPackagesFor` so NixOS's own machinery --
    # `system.build.toplevel`'s `kernel`/`initrd`/`dtbs` links, the extlinux
    # builder, the closure -- treats it as any other kernel. `nanokvm.kernel`
    # is handed in through specialArgs because it is a cross build owned by the
    # flake (nixos/rootfs.nix), not a package in this pkgs set.
    #
    # There are no modules: every driver is built in. `aggregateModules` copes
    # ("No modules found"), and `makeModulesClosure` over an empty tree with an
    # empty root list is a no-op -- which is why the two mkForce'd lists below
    # are not optional.
    boot.kernelPackages = pkgs.linuxPackagesFor nanokvm.kernel;

    # OUR dtb, from dts/ in this repo -- NOT `make dtbs` inside the kernel
    # tree, which on arm64 would build every other vendor's device trees to
    # produce our one file (pkgs/dtb-mainline.nix). `name` makes the builder
    # emit `FDT <dir>/<name>` rather than `FDTDIR <dir>`, which matters: an
    # FDTDIR is resolved against `$fdtfile` or `$soc-$board.dtb` at boot
    # (boot/pxe_utils.c, label_boot()), so it would put a second copy of this
    # filename in the U-Boot environment. FDT names the file outright.
    hardware.deviceTree.enable = true;
    hardware.deviceTree.dtbSource = "${nanokvm.dtb}/dtb";
    hardware.deviceTree.name = "ax630c-nanokvm-pro.dtb";

    # THE BOOTLOADER IS NIXOS'S OWN, and it is the only writer of /boot.
    # `switch-to-configuration boot` runs
    # nixos/modules/system/boot/loader/generic-extlinux-compatible's builder,
    # which copies this generation's kernel, initrd and dtbs into /boot/nixos/
    # and writes /boot/extlinux/extlinux.conf. Nothing in this repo renders
    # that file, and nothing else writes it -- the updater does not, the image
    # build runs this same builder, and `nanokvm-mark-good` only ever derives
    # the fallback FROM it.
    boot.loader.generic-extlinux-compatible.enable = true;

    # TIMEOUT 0 IS NOT A SPEED SETTING, it is what keeps U-Boot off the
    # console. The builder emits a top-level `MENU TITLE` line whenever the
    # timeout is non-zero, and `parse_pxefile_top()` sets `cfg->prompt = 1` on
    # ANY top-level MENU keyword (boot/pxe_utils.c); `menu_get_choice()` then
    # takes `menu_interactive_choice()`, which calls
    # `cli_readline_into_buffer("Enter choice: ", ...)`. This board's console
    # is a hidden, unterminated UART pad: a character of line noise is an
    # unmatched key, the loop prints "<junk> not found" and asks again, and the
    # timeout is reset each time -- forever. With 0 the builder writes no MENU
    # line at all, `cfg->prompt` stays 0, and `menu_default_choice()` picks
    # DEFAULT without reading anything. The per-LABEL `MENU LABEL` lines the
    # builder still emits are parsed by `parse_label_menu()`, which does not
    # touch `cfg->prompt`.
    boot.loader.timeout = 0;

    # HOW MANY GENERATIONS THE BOOT MENU NAMES, and it is squeezed from both
    # sides.
    #
    # FROM BELOW: `nanokvm-mark-good` promotes by setting DEFAULT to the booted
    # generation's LABEL, so that label has to be in the file -- a fallback
    # naming a label U-Boot cannot match falls through to the FIRST label,
    # which is the generation the rollback exists to escape. The deepest gap
    # that can open is one: an update makes generation N+1 the default while
    # the fallback still names N, and `nanokvm-update` refuses to install over
    # a boot that has not been marked good, so N+2 cannot appear first. Two
    # would do; three leaves a spare.
    #
    # FROM ABOVE: /boot. Each generation in the menu is a ~50 MB copy of its
    # kernel, initrd and dtbs under /boot/nixos/, and the builder writes the
    # new set BEFORE collecting the obsolete one -- so the partition has to
    # hold `configurationLimit + 1` of them at the moment of a switch.
    # pkgs/bootfs.nix asserts exactly that against the 272 MiB partition, from
    # the sizes the image actually carries.
    boot.loader.generic-extlinux-compatible.configurationLimit = 3;

    boot.loader.grub.enable = false;
    boot.loader.systemd-boot.enable = false;

    # THE COMMAND LINE, minus `init=`, which the builder pins per LABEL -- that
    # is what lets extlinux.conf and extlinux-fallback.conf name two different
    # generations. Everything here was hardware-proven in #89 rung 2q round 6,
    # minus that round's two test-only tokens:
    #
    #   * `watchdog.open_timeout=` is a DEADMAN, not a setting. Nothing in the
    #     appliance opens /dev/watchdog, so the watchdog core pets U-Boot's dog
    #     from kernel context forever; with an open deadline it stops and a
    #     perfectly healthy board resets a few minutes in.
    #   * `systemd.mask=systemd-pstore.service` keeps a boot's ramoops readable
    #     by stopping systemd archiving and unlinking it. Also a harness
    #     setting.
    #
    # `mem=512M` STAYS for now. The board has 1 GiB and the appliance sees
    # 428 MB usable; dropping it made the kernel die before any console in
    # rung 2p, and what lives above 512 MB has not been established.
    #
    # `blkdevparts=` is the layout, and it is the same string U-Boot's own
    # `part_cmdline` driver reads. Since #89 rung 4 it is GENERATED from
    # nixos/lib/emmc-layout.nix -- the SPL's stage offsets are compile-time
    # constants derived from that list, so the list is the definition and the
    # DT clause is checked against it, not the other way round.
    #
    # `boot.panic_on_fail` AND `stage1panic=1` CARRY NO `=1`, and that is the
    # whole point. Upstream's stage-1 parser is
    # `case $o in boot.panic_on_fail|stage1panic=1)`, and a shell `case`
    # pattern must match the WHOLE word -- so `boot.panic_on_fail=1`, which is
    # what this line said until 2026-09-09, matched NOTHING and silently left
    # `panicOnFail` unset. It cost the rung-5 drill and a bench trip.
    # `preDeviceCommands` below sets the variable too, depending on no string.
    boot.kernelParams = [
      "mem=512M"
      "console=ttyS0,115200n8"
      "earlycon=uart8250,mmio32,0x4880000"
      "board_id=0x5,boot_reason=0x00,initcall_debug=0"
      "usbcore.autosuspend=-1"
      "root=${parts.root.device}"
      "rootfstype=ext4"
      "rw"
      "rootwait"
      parts.blkdevparts
      "logomode=vo0@dsi_dpi_video"
      "boot.panic_on_fail"
      "stage1panic=1"
      "panic=10"
    ];
    # `loglevel=` is emitted by nixos/modules/system/boot/kernel.nix from this
    # option, so setting it here rather than in kernelParams keeps one of them.
    boot.consoleLogLevel = 8;

    # =====================================================================
    # 2. The initrd -- what replaces the vendor /init
    # =====================================================================
    # Classic (script) stage 1, not systemd-in-initrd. The failure mode of a
    # stage 1 that dies on this board is a board with no console and no
    # autoboot interrupt window; a shell script that mounts one ext4 is the
    # smaller, more inspectable thing, and `panicOnFail` below is a property of
    # that script specifically.
    boot.initrd.enable = true;
    boot.initrd.systemd.enable = false;

    # Compressed the way NixOS compresses an initrd (zstd), because it is a
    # FILE now: U-Boot loads /boot/nixos/<gen>-initrd to `ramdisk_addr_r` and
    # hands the address to `booti`. It used to be `cat`, because
    # pkgs/kernel-mainline.nix fed it to CONFIG_INITRAMFS_SOURCE and let the
    # kernel do the compression -- compress it twice and the Image grew.
    # Nothing embeds it any more (#99).

    # There are no kernel modules in the INITRD. Every driver stage 1 needs is
    # built into the Image, and the kernel derivation ships no /lib/modules
    # tree for `makeModulesClosure` to draw from. The six the video stack
    # loads (#83) are a stage-2 concern and come out of the closure's own
    # `nanokvm.video-modules`.
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
    boot.initrd.extraUtilsCommands = ''
      copy_bin_and_libs ${pkgs.util-linux}/bin/losetup
      copy_bin_and_libs ${pkgs.e2fsprogs}/bin/resize2fs
    '';

    # THE STAGE-1 DEADMAN, and it is not optional on this board.
    #
    # NixOS stage 1's `fail()` is INTERACTIVE: it prints a menu and blocks in
    # `read -n 1 reply` on /dev/console. This board's console is a hidden,
    # unterminated UART pad, so that is a board which is powered, warm and
    # unreachable forever -- no reset, no watchdog (nothing arms WDT0 before
    # Linux), and therefore no `bootcount` increment and no rollback. It has to
    # be a panic, so that `panic=10` restarts the board into the count.
    #
    # SETTING IT FROM THE COMMAND LINE ALONE IS NOT ENOUGH, and believing it
    # was cost a bench trip on 2026-09-09. Upstream parses
    # `case $o in boot.panic_on_fail|stage1panic=1)`, and a shell `case`
    # pattern must match the WHOLE word -- so the `boot.panic_on_fail=1` the
    # extlinux APPEND had carried since rung 3 matched nothing at all and
    # `panicOnFail` was never set. The rung-5 rollback drill installed a
    # generation that could not boot, stage 1 sat in `read` instead of
    # panicking, and the board had to be recovered by hand.
    #
    # preDeviceCommands is spliced in AFTER the command-line parse and after
    # `trap 'fail' 0`, which is exactly where the variable has to land. The
    # APPEND now carries the right tokens too; this does not depend on them.
    boot.initrd.preDeviceCommands = lib.mkBefore ''
      panicOnFail=1
    '';

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
    boot.initrd.preLVMCommands = ''
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

    # =====================================================================
    # 3. Filesystems -- all three numbers derived from the blkdevparts clause
    # =====================================================================
    fileSystems."/" = {
      device = cfg.rootDevice;
      fsType = "ext4";
      options = [ "noatime" ];
      # make-ext4-fs shrinks the image to its contents, so a partition root is
      # ~1 GB inside a ~30 GB partition. Stage 1 grows it, which is what the
      # vendor /init did with static binaries copied out of the rootfs.
      autoResize = true;
    };

    # /boot, and it must be WRITABLE: the server keeps its USB-gadget feature
    # flags there (usb.ncm, usb.disk0, usb.uac2, eth.nodhcp, ...), the module
    # loader sources /boot/configs, and the vendor initramfs contract still
    # uses /boot/rec and /boot/check_resize2fs on a vendor boot. Since #89
    # rung 3 it also holds the boot payload, and since #99 that payload is
    # NixOS's: /boot/extlinux/extlinux.conf plus one /boot/nixos/<hash>-kernel,
    # -initrd and -dtbs per generation in the menu.
    #
    # EXT4 UNDER THE MINIMAL LAYOUT. The kernel needs ext4 for root anyway, so
    # putting /boot on it retires the CONFIG_VFAT_FS + NLS-codepage trap
    # documented in docs/nixos-rootfs.md (without those tables the mount fails
    # -EINVAL and every USB-gadget flag silently reads as absent). `umask` is
    # a vfat-only option; on ext4 the permissions are in the filesystem.
    fileSystems."/boot" = {
      device = parts.bootfs.device;
      fsType = "ext4";
      options = [ "nofail" "noatime" ];
    };

    swapDevices = [ ];

    # =====================================================================
    # 4. FHS accommodation
    # =====================================================================
    # NanoKVM-Server and libkvm request /lib/ld-linux-aarch64.so.1.
    environment.ldso = "${pkgs.glibc}/lib/ld-linux-aarch64.so.1";

    systemd.tmpfiles.rules = [
      # The updater's state: one file, `update-pending`, which survives the
      # reboot so the UI can say what happened on the other side of it. The
      # per-generation closure lists that used to live here are gone -- nix
      # knows what a generation needs (#100).
      "d /var/lib/nanokvm 0755 root root - -"
      # Where a release closure is pinned as a gc root while it is installed.
      "d /nix/var/nix/gcroots/nanokvm 0755 root root - -"
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

    # THE VERSION THIS GENERATION IS, as a file INSIDE the closure (#86). The
    # web UI reads `/kvmapp/version`, which is a store symlink and therefore
    # also per-generation -- but `nanokvm-update` needs the version of the
    # RUNNING system specifically, and `/run/current-system/etc/nanokvm-version`
    # is the only thing that says it without guessing. Making it part of the
    # closure is what removes the need for any mutable version stamp at all:
    # a rollback rolls the version back with everything else.
    environment.etc."nanokvm-version".text = "${nanokvm.version}\n";

    # =====================================================================
    # 5. Services
    # =====================================================================

    # 5a. The video stack (#83). Six modules out of the generation's own
    # closure, in the order the kernel build's depmod resolved, then a check
    # that the pipeline actually came up.
    #
    # THE MODULES AND THEIR KERNEL ARE IN THE SAME GENERATION (#99).
    # pkgs/video-modules.nix copies the .ko set out of the kernel derivation
    # `boot.kernelPackages` names, so a generation carries the drivers it was
    # built with and cannot be booted on a kernel it was not built for. #83
    # shipped with a caveat here -- the Image was a /boot artefact outside every
    # generation, so the two could disagree with nothing able to detect it,
    # because the vermagic is the release string alone and does not change when
    # a built-in driver does. #99 closed that by construction.
    #
    # insmod, not modprobe: the order is six lines long, it ships next to the
    # modules, and an explicit order is a mechanism a reader can check. (The
    # package also carries depmod output, so `modprobe -d` works by hand.)
    systemd.services.nanokvm-video = {
      description = "NanoKVM-Pro open video stack (capture + encoder modules)";
      wantedBy = [ "multi-user.target" ];
      before = [ "nanokvm.service" ];
      after = [ "systemd-modules-load.service" ];
      path = [ pkgs.kmod ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script =
        if cfg.videoStack.enable then ''
          set -e
          # `uname -r` rather than a baked-in release string, so a generation
          # running on a kernel it was not built for fails HERE, with a path
          # that names the mismatch, instead of at the first insmod with a
          # vermagic error -- or worse, not at all.
          dir=${nanokvm.video-modules}/lib/modules/$(uname -r)
          if [ ! -r "$dir/load-order" ]; then
            echo "nanokvm-video: $dir does not exist." >&2
            echo "               This generation's modules were built for a" >&2
            echo "               different kernel than the one /boot booted." >&2
            exit 1
          fi
          while read -r ko; do
            [ -n "$ko" ] || continue
            if [ -d "/sys/module/$(basename "$ko" .ko | tr - _)" ]; then
              echo "nanokvm-video: $ko already loaded"
              continue
            fi
            echo "nanokvm-video: insmod $ko"
            insmod "$dir/$ko"
          done < "$dir/load-order"

          # The oracle, not a formality: every module above can load cleanly
          # and still leave no pipeline if a probe deferred or a carveout was
          # rejected. /dev/video0 is what the server opens.
          for _ in $(seq 1 20); do
            [ -e /dev/video0 ] && break
            sleep 0.25
          done
          if [ ! -e /dev/video0 ]; then
            echo "nanokvm-video: modules loaded but /dev/video0 never appeared" >&2
            exit 1
          fi
          echo "nanokvm-video: /dev/video0 up"
        '' else ''
          echo "nanokvm-video: DISABLED (nanokvm.videoStack.enable = false)."
          echo "               No /dev/video0; the server will serve the UI"
          echo "               but not a stream."
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
    # store path (pkgs/nanokvm-server.nix).
    #
    # This module therefore stubs the POLICY half of #82 alone. #81 and #83
    # both landed: 5a loads the video modules for real, and the board streams.

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

    # 5d2. The mini-display's panel (#84). Two modules out of the generation's
    # own closure, then a check that /dev/fb0 actually appeared.
    #
    # Same shape as nanokvm-video above and a SEPARATE unit from it on purpose:
    # the two sets have different oracles, and a panel that did not come up
    # must not read as a capture failure (or stop the server from starting).
    #
    # Why these two are modules at all is argued in pkgs/display-modules.nix:
    # loading fb_jd9853 runs the vendor's power-on sequence twice, ~560 ms of
    # mdelay plus two resets over SPI, and a hang in there must cost a dead
    # unit rather than a kernel that never reaches userspace. THE OTHER HALF OF
    # THAT RULE IS NOT ENFORCEABLE HERE: never unload them. On the vendor 4.19
    # driver that hard-hangs the board; the cause is structurally absent from
    # our port, and it has never been tested. Test at boot.
    #
    # THIS UNIT NEVER FAILS, for the reason nanokvm-wifi does not (#85): a
    # `Type=oneshot` that exits non-zero over absent optional hardware makes
    # `systemctl is-system-running` report `degraded`, which makes
    # nanokvm-mark-good poll its whole timeout and give up, which leaves
    # `bootcount` uncleared -- so every reboot counts as a failed attempt and
    # the fourth rolls the board onto the fallback generation. A KVM whose
    # HDMI, USB and ethernet all work is not unhealthy because it has no
    # status screen. Every dead end here is a journal line and `exit 0`, and
    # nanokvm.markGood.tolerateFailed is the second belt on the same trousers.
    systemd.services.nanokvm-panel = {
      description = "NanoKVM-Pro mini-display panel (fbtft + JD9853)";
      wantedBy = [ "multi-user.target" ];
      before = [ "nanokvm-display.service" ];
      after = [ "systemd-modules-load.service" ];
      path = [ pkgs.kmod ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script =
        if cfg.panel.enable then ''
          say() { echo "nanokvm-panel: $*"; }
          note() { echo "nanokvm-panel: $*" >&2; }

          # `uname -r` rather than a baked-in release, for the same reason
          # nanokvm-video does it: a generation running on a kernel it was not
          # built for says so here, with a path that names the mismatch, rather
          # than at the first insmod with a vermagic error.
          dir=${nanokvm.display-modules}/lib/modules/$(uname -r)
          if [ ! -r "$dir/load-order" ]; then
            note "$dir does not exist: this generation's panel modules were"
            note "built for a different kernel than the one /boot booted."
            note "No /dev/fb0; the status daemon will not start."
            exit 0
          fi
          while read -r ko; do
            [ -n "$ko" ] || continue
            if [ -d "/sys/module/$(basename "$ko" .ko | tr - _)" ]; then
              say "$ko already loaded"
              continue
            fi
            if insmod "$dir/$ko"; then
              say "insmod $ko"
            else
              note "insmod $ko failed -- see dmesg for the driver's own reason."
              break
            fi
          done < "$dir/load-order"

          # The oracle. fb_jd9853 can load cleanly and still register no
          # framebuffer -- a failed SPI transfer, a GPIO it could not claim, a
          # panel that did not answer. /dev/fb0 is what the daemon opens.
          for _ in $(seq 1 20); do
            [ -e /dev/fb0 ] && break
            sleep 0.25
          done
          if [ -e /dev/fb0 ]; then
            say "/dev/fb0 up"
            exit 0
          fi

          # The diagnosis, in the journal, in the order that separates the
          # causes. The panel hangs off spi2, and the single fact that says
          # whether anything could have bound is whether the SPI MASTER
          # probed: with no /sys/bus/spi/devices/spi2.1 there is no device for
          # fb_jd9853 to attach to and the fault is the controller (its
          # clocks, its resets, its pinctrl), not the panel driver. #84 lost
          # its first hardware round to exactly this: five clock rows the
          # binding header declared and the clock table never registered, so
          # dw_spi_mmio and dwc-pwm-of both failed clk_get with -ENOENT.
          note "modules loaded but /dev/fb0 never appeared."
          if [ -e /sys/bus/platform/drivers/dw_spi_mmio/6072000.spi ]; then
            note "spi2 (6072000.spi) IS bound; the panel itself did not answer."
          else
            note "spi2 (6072000.spi) did NOT bind -- no SPI device for the panel."
            note "check: dmesg | grep -iE '6072000|dw_spi|dwc-pwm', and"
            note "       /sys/kernel/debug/devices_deferred"
          fi
          note "spi devices: $(ls /sys/bus/spi/devices 2>/dev/null | tr '\n' ' ')"
          exit 0
        '' else ''
          echo "nanokvm-panel: DISABLED (nanokvm.panel.enable = false)."
          echo "               No /dev/fb0; the status daemon will not start."
        '';
    };

    # 5e. Mini-display status daemon. Draws the status screen on /dev/fb0 and
    # reads the knob's two evdev devices; the panel itself is nanokvm-panel
    # above, which is ordered before this.
    #
    # ConditionPathExists rather than a hard dependency: a board with no panel
    # (or with nanokvm.panel.enable = false) should simply not run the daemon,
    # not accumulate a failed unit.
    #
    # `path` carries nanokvm-gpio because that is how the daemon reads the
    # target's power-LED sense on mainline -- there is no sysfs GPIO export any
    # more and global line numbers are not stable, so the line is addressed by
    # its device-tree name (#81, #84).
    #
    # AND iproute2, which is the whole of the daemon's network line. NixOS
    # gives a unit coreutils, findutils, gnugrep, gnused and systemd and
    # nothing else, so `ip -j -4 addr` was an ENOENT the daemon caught and
    # turned into an empty address list -- a panel that read "no network" in
    # amber on a board that was routed, serving and reachable over SSH. It
    # cost nothing to find on hardware and would have been invisible offline
    # (the 4.19 image ran this daemon with an Ubuntu PATH). #84, 2026-09-11.
    systemd.services.nanokvm-display = {
      description = "NanoKVM-Pro mini-display status screen";
      wantedBy = [ "multi-user.target" ];
      after = [ "nanokvm-panel.service" ];
      unitConfig.ConditionPathExists = "/dev/fb0";
      path = [ nanokvm.nanokvm-gpio pkgs.iproute2 ];
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

    # Consume the chainload test slot: one attempt, then the file goes.
    # Ordered after /boot is mounted and before nothing -- it is not on any
    # critical path, and if it never runs the only cost is that the candidate
    # is tried again after the next healthy boot.
    systemd.services.nanokvm-uboot-test-clear = lib.mkIf cfg.ubootTest.enable {
      description = "Consume the one-shot U-Boot chainload test slot";
      wantedBy = [ "multi-user.target" ];
      after = [ "boot.mount" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${ubootTestClear}/bin/nanokvm-uboot-test-clear";
      };
    };

    # ---- unattended updates (#86) ---------------------------------------
    # THE TIMER ALWAYS RUNS; THE CHECKBOX DECIDES WHAT IT DOES.
    # `nanokvm-update update` exits 0 immediately unless /etc/kvm/auto_updates
    # exists -- the file the web UI's "Automatic updates" switch writes, beside
    # the "preview updates" one. Gating the UNIT on a NixOS option instead
    # would mean the toggle could not take effect without a rebuild, which is
    # the opposite of what a checkbox is for.
    #
    # `Persistent` so a board that is off at the scheduled hour still checks
    # once it is back, rather than waiting a whole period.
    systemd.services.nanokvm-update = lib.mkIf cfg.update.enable {
      description = "Install the NanoKVM release this channel offers (reboots when idle)";
      after = [ "network-online.target" "nanokvm-mark-good.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${updateTools.updater}/bin/nanokvm-update update";
        # An update that fails must not take the board with it: every step
        # before the profile switch is a no-op on failure, and the boot config
        # is only rewritten once the store and /boot are complete.
        SuccessExitStatus = [ 0 ];
      };
    };

    systemd.timers.nanokvm-update = lib.mkIf cfg.update.enable {
      description = "Periodic NanoKVM update check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.update.schedule;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    # ---- the reboot half, which is the whole point (#86) -----------------
    # An update installs the moment the timer above fires, but `switch-to-
    # configuration boot` makes nothing live until the board restarts -- and a
    # KVM is the machine you are using to fix the machine, so the restart waits
    # for an empty room. `update` leaves /run/nanokvm-update-pending when it
    # finds the device in use; this asks the server the same question again and
    # takes the reboot as soon as the answer is yes. It also settles the
    # persistent note left by an update that HAS booted, which is what lets the
    # web UI say "updated to X" on the other side.
    systemd.services.nanokvm-update-reboot = lib.mkIf cfg.update.enable {
      description = "Reboot into a pending NanoKVM update once nobody is using the device";
      after = [ "nanokvm-mark-good.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${updateTools.updater}/bin/nanokvm-update reboot-if-idle";
      };
    };

    systemd.timers.nanokvm-update-reboot = lib.mkIf cfg.update.enable {
      description = "Re-check whether a pending NanoKVM update may reboot the device";
      wantedBy = [ "timers.target" ];
      # `Persistent = false`: a missed re-check is nothing to catch up on. The
      # marker is still there and the next tick asks again; running a backlog of
      # them at boot would only ask the same question several times in a row.
      timerConfig = {
        Persistent = false;
      } // (if cfg.update.rebootWindow == null then {
        # OnBootSec settles the note from an update that just booted, within a
        # couple of minutes, so the UI stops showing a restart that has happened.
        OnBootSec = "2min";
        OnUnitActiveSec = "10min";
      } else {
        OnCalendar = cfg.update.rebootWindow;
      });
    };

    # ---- the collector (#100) --------------------------------------------
    # `nix-collect-garbage`, with the one thing nix cannot know pinned first:
    # the generation the ROLLBACK boot config names, which no profile link and
    # no /run symlink protects. `nanokvm-update gc` writes those pins as gc
    # roots BEFORE it deletes anything -- see the command in
    # nixos/lib/updater.nix.
    #
    # After `nanokvm-mark-good`, so a boot that is still on trial never
    # collects; and `Persistent`, because a board that was off on the scheduled
    # day should still tidy up once.
    systemd.services.nanokvm-gc = lib.mkIf cfg.update.enable {
      description = "Delete superseded NanoKVM generations and collect the store";
      after = [ "nanokvm-mark-good.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${updateTools.updater}/bin/nanokvm-update gc";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.nanokvm-gc = lib.mkIf cfg.update.enable {
      description = "Periodic NanoKVM store collection";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.update.gcSchedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
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
    ] ++ lib.optional cfg.ubootTest.enable ubootTest
    # On PATH so a hardware run can force the promotion by hand and read what
    # it decided, rather than inferring it from the unit's journal.
    ++ lib.optional cfg.markGood.enable markGood
    ++ lib.optional cfg.update.enable updateTools.updater
    ++ (with pkgs; [
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

    # =====================================================================
    # 7. Nix (#100)
    # =====================================================================
    # THIS IS A NixOS SYSTEM, SO NIX IS ON IT. The #78 appliance shipped
    # `nix.enable = false` and a fixed closure, and every consequence of that
    # had to be rebuilt by hand: a tar transport for the closure, a list of
    # which paths belong to which generation, and a collector that refused to
    # run whenever that list was missing. All three are gone. What the device
    # gains is the only thing it actually needed -- a store it can add a signed
    # closure to, and a collector that knows what is reachable.
    #
    # SINGLE-USER, NOT THE DAEMON. There is exactly one user here and it is
    # root, and nothing on this board ever builds. The daemon exists to
    # mediate between untrusted users and the store; with no untrusted users it
    # is a socket, a unit, 32 `nixbld` accounts and a second process in the
    # update path, for nothing. `store = auto` resolves to the local store
    # whenever /nix/var/nix is writable and no daemon socket exists, which is
    # the state this leaves the system in.
    #
    # AND IT IS THE STRICTER OF THE TWO. Signature checking on a direct
    # LocalStore has no trusted-user bypass: `require-sigs` applies to root the
    # same as to anyone, so `nix copy` cannot be talked into accepting an
    # unsigned NAR the way a trusted client of a daemon can.
    nix.enable = true;
    systemd.sockets.nix-daemon.wantedBy = lib.mkForce [ ];
    nix.nrBuildUsers = 0;
    # No channels, no registry, no NIX_PATH: nothing on this box evaluates
    # nixpkgs, and a channel is a second, mutable source of truth for a system
    # whose whole point is that its generation came from a tagged release.
    nix.channel.enable = false;
    # nixos-rebuild / nixos-install / nixos-generate-config would all be lies
    # here (there is no nixpkgs to evaluate, and a rebuild is a release), and
    # they are not small.
    system.disableInstallerTools = true;

    nix.settings = {
      # The release cache, so `nix copy --from` has a default and an operator
      # debugging by hand gets the same source the updater uses. Not a
      # substituter for cache.nixos.org's sake: this device builds nothing, so
      # the only thing it ever fetches is a release closure.
      substituters = lib.mkForce (lib.optional (cfg.update.cacheUrl != "") cfg.update.cacheUrl);
      trusted-public-keys = lib.mkForce cfg.update.trustedPublicKeys;
      require-sigs = true;
      # THE BOARD NEVER BUILDS. An update is a closure someone else built; a
      # derivation that somehow got realised here would take minutes per
      # package on a 1.2 GHz A53 and wear the eMMC doing it.
      max-jobs = 0;
      sandbox = false;
      # eMMC. Store optimisation rewrites every duplicate file as a hardlink,
      # which is a full store walk and a lot of small writes to buy back space
      # on a device whose store holds three generations of one closure.
      auto-optimise-store = false;
      experimental-features = [ "nix-command" ];
      # Only root exists; spelling it out keeps a future user from inheriting
      # the ability to add paths to the store.
      allowed-users = [ "root" ];
      trusted-users = [ "root" ];
    };

    system.switch.enable = lib.mkDefault true;

    warnings =
      lib.optional (cfg.update.enable && cfg.update.cacheUrl == "")
        ''
          nanokvm.update.cacheUrl is empty: this system can be built and booted
          but cannot update itself (#96 -- the attic endpoint is Jeremy's to
          stand up). `nanokvm-update update` will refuse rather than install
          anything unverified.
        ''
      ++ lib.optional (cfg.update.enable && cfg.update.cacheUrl != "" && cfg.update.trustedPublicKeys == [ ])
        ''
          nanokvm.update.cacheUrl is set but nanokvm.update.trustedPublicKeys is
          empty. Nothing will install: every NAR must be signed by a key this
          system trusts, and this system trusts none.
        '';

    documentation.enable = false;
    documentation.nixos.enable = false;

    assertions = [
      {
        assertion = !config.boot.initrd.systemd.enable;
        message = ''
          nixos/appliance.nix: boot.initrd.systemd.enable must stay false.
          A stage 1 that dies on this board is silent -- no console, no
          autoboot interrupt window -- and the `panicOnFail` deadman below is
          a property of the SCRIPTED stage 1 specifically. top-level.nix also
          swaps <system>/init for a copy of the systemd binary when it is on,
          which breaks the /init contract the rootfs asserts.
        '';
      }
      {
        assertion = config.boot.kernel.enable;
        message = ''
          nixos/appliance.nix: boot.kernel.enable must stay true (#99). The
          kernel, the initrd and the dtb ARE the generation now; with this off
          there is no $out/kernel for the extlinux builder to copy and /boot
          would name files nothing produces.
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
      {
        assertion = config.boot.loader.generic-extlinux-compatible.enable;
        message = ''
          nixos/appliance.nix: generic-extlinux-compatible must stay enabled.
          It is the only writer of /boot/extlinux/extlinux.conf, and U-Boot's
          `bootcmd` reads exactly that file. Nothing else on this system
          writes a boot config.
        '';
      }
      {
        assertion = config.boot.loader.timeout == 0;
        message = ''
          nixos/appliance.nix: boot.loader.timeout must be 0. Any other value
          makes the builder emit a top-level `MENU TITLE`, which sets
          `cfg->prompt = 1` in U-Boot's parse_pxefile_top() -- and this board's
          console is a hidden, unterminated UART pad, so the prompt loop reads
          line noise forever and the board never boots.
        '';
      }
      {
        assertion =
          config.boot.loader.generic-extlinux-compatible.configurationLimit >= 3;
        message = ''
          nixos/appliance.nix: the boot menu must name at least three
          generations. nanokvm-mark-good promotes the BOOTED one by name, and
          an update can put the default one generation ahead of it -- so with
          fewer than two the fallback ends up naming a LABEL the file does not
          define, and a DEFAULT U-Boot cannot match falls through to the FIRST
          label, which is the generation the rollback exists to escape. The
          third is a spare. The ceiling is /boot, asserted in pkgs/bootfs.nix.
        '';
      }
      {
        assertion = config.hardware.deviceTree.name != null;
        message = ''
          nixos/appliance.nix: hardware.deviceTree.name must be set. Without
          it the builder writes FDTDIR, which U-Boot resolves through
          $fdtfile / $soc-$board.dtb -- putting the filename in the U-Boot
          environment, where nothing in this repo maintains it.
        '';
      }
    ];
  };
}
