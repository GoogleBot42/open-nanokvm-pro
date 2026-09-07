{ pkgs
, crossPkgs
, inputs
, kvm-encoder
, nanokvm-server
, nanokvm-web
, nanokvm-display
, version ? "0.0.0-dev"
, applianceModules ? [ ]
, variant ? "emmc"
, ...
}:

# ===========================================================================
# The NanoKVM-Pro NixOS appliance (issue #78, epic #26) -- nixos/appliance.nix
# evaluated into a system closure, packed into a rootless ext4, with the
# stage-1 initrd exposed separately so pkgs/kernel-mainline.nix can embed it.
#
# ONE nixpkgs pin. The predecessor of this file evaluated against a second,
# older pin (nixos-24.11) because systemd's declared kernel floor had risen
# above the vendor's Linux 4.19.125 while the prebuilt ax_*.ko blobs held the
# kernel there. Both halves of that argument are gone: the image has carried no
# vendor kernel module since #54, and the kernel is now mainline 7.1.x, well
# above systemd's 5.10 minimum. So `nixpkgs-rootfs` is retired and this
# evaluates against the same unstable pin as everything else -- which also
# retires the "two glibcs, one loader" hazard docs/nixos-rootfs.md warns about.
#
# BUILD MODEL: the appliance is evaluated as a NATIVE aarch64-linux system and
# built through binfmt/qemu-user emulation (this host has
# `extra-platforms = aarch64-linux`). Almost the whole closure substitutes from
# cache.nixos.org, so emulation only pays for the handful of tiny system
# derivations. The ext4 itself is packed by nixpkgs' make-ext4-fs on the BUILD
# machine -- `fakeroot mkfs.ext4 -d`, no root and no loop mount, the same
# constraint that forced the debugfs surgery in pkgs/rootfs.nix.
#
# THE BOOT CONTRACT this image owes the boot chain (docs/mainline-port.md
# section 5, and section 8's #78 entry):
#
#   U-Boot `booti`s our Image, which carries the NixOS initrd inside it. The
#   command line comes from the U-Boot ENVIRONMENT -- not from the device tree,
#   which fdt_chosen overwrites -- so we cannot put `init=` on it. NixOS stage 1
#   then falls back to its built-in default, `switch_root $targetRoot /init`.
#   Hence /init at the root of this image, pointing at the system profile.
#   Updating that profile is therefore the whole of a generation switch: no
#   bootloader, no config file, no partition write.
# ===========================================================================

let
  lib = pkgs.lib;
  nixpkgs = inputs.nixpkgs;

  nanokvm = {
    inherit kvm-encoder nanokvm-server nanokvm-web nanokvm-display version;
    # The three open libraries libkvm DT_NEEDEDs, taken from crossPkgs -- the
    # exact builds it was compiled and linked against (pkgs/kvm-encoder.nix),
    # so there is no skew between what was linked and what is loaded.
    #
    # getLib on every one of them, not the bare derivation: these are
    # multi-output packages and libjpeg-turbo's FIRST output is `bin`, so
    # "${kvm-encoder.libjpeg8}/lib" is a directory that does not exist and the
    # only symptom is a `cp` with no source operand.
    opus = lib.getLib crossPkgs.libopus;
    alsaLib = lib.getLib crossPkgs.alsa-lib;
    # jpeg8 ABI, from kvm-encoder's passthru: the soft-MJPEG path (#51)
    # DT_NEEDEDs libjpeg.so.8 specifically.
    jpeg = lib.getLib kvm-encoder.libjpeg8;
  };

  eval = import (nixpkgs + "/nixos/lib/eval-config.nix") {
    system = null; # set via nixpkgs.hostPlatform in the module
    modules = [ ./appliance.nix ] ++ applianceModules;
    specialArgs = { inherit nanokvm; };
  };

  toplevel = eval.config.system.build.toplevel;

  # /dev/console and /dev/null, as a cpio fragment.
  #
  # THE TRAP THIS EXISTS FOR. The kernel ALWAYS unpacks a built-in initramfs;
  # when CONFIG_INITRAMFS_SOURCE is empty it unpacks usr/default_cpio_list,
  # which does nothing except create /dev, /dev/console and /root. So on an
  # ordinary machine -- bootloader hands the initrd to the kernel separately --
  # /dev/console exists before PID 1 starts, and a NixOS initrd carries no
  # device nodes because it has never needed to.
  #
  # Setting INITRAMFS_SOURCE REPLACES that default list. PID 1 then starts with
  # fd 0/1/2 closed ("Warning: unable to open an initial console"), and NixOS
  # stage 1 dies on its first `exec 8>&1` with no output whatsoever -- observed
  # as a panic 330 ms after "Run /init as init process", with nothing between.
  # On the real board that is indistinguishable from a kernel that hung.
  #
  # fakeroot, because mknod(2) needs privileges the build sandbox does not
  # have; it fakes the node and cpio records the type and rdev from its stat.
  # Appended AFTER the NixOS archive, so these entries win if anything ever
  # collides: the kernel's unpacker resets at each TRAILER and keeps going,
  # which is exactly how concatenated initramfs images are supported.
  devNodes = pkgs.runCommand "nanokvm-initrd-dev-nodes.cpio"
    {
      nativeBuildInputs = [ pkgs.fakeroot pkgs.cpio ];
      mkNodes = pkgs.writeShellScript "mk-dev-nodes" ''
        set -eu
        mknod dev/console c 5 1
        mknod dev/null    c 1 3
        chmod 0600 dev/console
        chmod 0666 dev/null
        printf 'dev\ndev/console\ndev/null\n' | cpio -o -H newc --quiet > "$out"
      '';
    } ''
    mkdir -p root/dev
    cd root
    fakeroot -- "$mkNodes"
    cpio -itv --quiet < "$out"
  '';

  # `boot.initrd.compressor = "cat"` in the appliance makes this a PLAIN cpio.
  # pkgs/kernel-mainline.nix hands it to CONFIG_INITRAMFS_SOURCE and lets the
  # kernel do the compression (a .cpio source is used verbatim, then compressed
  # once -- usr/Makefile). Compressing it here too would only make the Image
  # bigger.
  initrd = pkgs.runCommand "nanokvm-appliance-initramfs.cpio" { } ''
    src=${eval.config.system.build.initialRamdisk}/${eval.config.system.boot.loader.initrdFile}
    if [ "$(head -c 6 "$src")" != "070701" ]; then
      echo "ERROR: the initrd is not a plain (newc) cpio -- boot.initrd.compressor" >&2
      echo "       must be \"cat\", or the kernel will compress it twice." >&2
      exit 1
    fi
    cat "$src" ${devNodes} > "$out"
  '';

  rootImage = import (nixpkgs + "/nixos/lib/make-ext4-fs.nix") {
    inherit pkgs lib;
    inherit (pkgs) e2fsprogs libfaketime perl fakeroot zstd;
    storePaths = [ toplevel ];
    volumeLabel = "NANOKVM";
    populateImageCommands = ''
      mkdir -p ./files/sbin ./files/etc ./files/proc ./files/sys ./files/dev \
               ./files/run ./files/tmp ./files/var ./files/root ./files/boot \
               ./files/mnt ./files/opt ./files/soc ./files/home
      chmod 1777 ./files/tmp
      chmod 0700 ./files/root

      # System profile -> the generation stage 2 boots.
      mkdir -p ./files/nix/var/nix/profiles ./files/nix/var/nix/gcroots
      ln -s ${toplevel}   ./files/nix/var/nix/profiles/system-1-link
      ln -s system-1-link ./files/nix/var/nix/profiles/system
      ln -s /nix/var/nix/profiles ./files/nix/var/nix/gcroots/profiles

      # THE switch_root TARGET. NixOS stage 1 execs $targetRoot/init unless the
      # command line carries init=, and this board's command line comes from the
      # U-Boot environment, which we do not write. /sbin/init is kept as well:
      # it costs a symlink and it is what the vendor initramfs would exec if
      # this image were ever booted by the 4.19 kernel.
      ln -s /nix/var/nix/profiles/system/init ./files/init
      ln -s /nix/var/nix/profiles/system/init ./files/sbin/init

      # Marks the root as NixOS-managed; switch-to-configuration refuses without it.
      touch ./files/etc/NIXOS
    '';
  };
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-pro-nixos-rootfs";
  inherit version;

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = with pkgs; [ e2fsprogs android-tools ];

  buildPhase = ''
    runHook preBuild
    set -euo pipefail

    cp ${rootImage} rootfs.ext4
    chmod u+w rootfs.ext4

    # Contract checks. Every one of these would otherwise show up as a silent
    # non-boot on a board with no console and bootdelay=0.
    echo "=== verifying the switch_root contract ==="
    for l in /init /sbin/init; do
      debugfs -R "stat $l" rootfs.ext4 2>/dev/null | grep -q "Type: symlink" \
        || { echo "ERROR: $l is not a symlink -- switch_root will fail" >&2; exit 1; }
    done
    debugfs -R "stat /nix/var/nix/profiles/system" rootfs.ext4 2>/dev/null | grep -q "Inode:" \
      || { echo "ERROR: no /nix/var/nix/profiles/system -- /init dangles" >&2; exit 1; }
    debugfs -R "stat ${toplevel}/init" rootfs.ext4 2>/dev/null | grep -q "Inode:" \
      || { echo "ERROR: stage-2 init missing from the image closure" >&2; exit 1; }

    # ...and it must be the stage-2 SCRIPT, not an ELF. top-level.nix swaps
    # <system>/init for a copy of the systemd binary whenever
    # boot.initrd.systemd.enable is true, and it does NOT consult
    # boot.initrd.enable -- so nothing else would catch it. The module asserts
    # the option; this asserts the artifact, because an imported profile could
    # re-enable it (24.11's profiles/image-based-appliance.nix does).
    debugfs -R "dump ${toplevel}/init $PWD/chk.init" rootfs.ext4 2>/dev/null
    head -c 2 "$PWD/chk.init" | grep -q '#!' || {
      echo "ERROR: ${toplevel}/init is not a '#!' script." >&2
      echo "       boot.initrd.systemd.enable is probably on (see appliance.nix)." >&2
      exit 1
    }
    echo "  /init -> profile -> ${toplevel}/init: present, and is a stage-2 script."

    # BLOB POLICY (CLAUDE.md, #54, #60). The shipped video stack has been
    # blob-free since #60 and the image carries no vendor kernel module, so a
    # closed Axera library appearing in this closure means something grew a
    # reference to one -- most likely a store path left in an RPATH. Assert it
    # here, where the whole closure is visible, rather than discovering it in a
    # provenance audit.
    echo "=== verifying the image carries no closed Axera code ==="
    for p in $(cat ${pkgs.writeClosure [ toplevel ]}); do
      case "$p" in
        *axera-libs*|*ax-ko-blobs*|*libsns-dummy*)
          echo "ERROR: closed vendor content in the system closure: $p" >&2
          exit 1 ;;
      esac
    done
    echo "  no axera-libs / ax-ko-blobs in the closure."

    # Android-sparse copy, the form the .axp carries (pkgs/image.nix swaps this
    # member in by basename).
    img2simg rootfs.ext4 ubuntu_rootfs_sparse.ext4

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp rootfs.ext4               "$out/nixos_rootfs.ext4"
    cp ubuntu_rootfs_sparse.ext4 "$out/ubuntu_rootfs_sparse.ext4"
    ln -s "${toplevel}" "$out/system"
    ln -s "${initrd}"   "$out/initramfs.cpio"
    cat > "$out/NOTES.txt" <<EOF
    NanoKVM-Pro NixOS appliance rootfs (issue #78) -- variant: ${variant}

    system closure : ${toplevel}
    nixpkgs pin    : ${toString nixpkgs}
    root device    : ${eval.config.fileSystems."/".device}
    init contract  : /init -> /nix/var/nix/profiles/system/init (NixOS stage 2)
    stage 1        : NixOS initrd, embedded in the kernel Image
                     (.#kernel-mainline-appliance)
    outputs        : nixos_rootfs.ext4 (raw), ubuntu_rootfs_sparse.ext4 (.axp),
                     initramfs.cpio (uncompressed, for CONFIG_INITRAMFS_SOURCE)

    DO NOT FLASH THE eMMC ROOTFS PARTITION WITH THIS while the vendor system is
    the only way back onto the board. Read docs/nixos-rootfs.md; the reversible
    hardware test is the loop-image variant (.#nixos-appliance-loop), and AXDL
    recovery needs Jeremy's hands on the board.
    EOF
    echo "Installed:"; ls -l "$out"
    runHook postInstall
  '';

  passthru = {
    inherit toplevel initrd eval;
    inherit (eval) config;
  };

  meta = {
    description =
      "NanoKVM-Pro NixOS appliance rootfs (${variant} root) -- system closure -> rootless ext4, for the mainline kernel";
    platforms = [ "x86_64-linux" ];
  };
}
