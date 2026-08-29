{ pkgs
, nixpkgsRootfs # a SEPARATE nixpkgs pin -- see the systemd ceiling below
, axera-libs
, ax-ko-blobs
, kernel
, kvm-encoder
, nanokvm-server
, nanokvm-web
, nanokvm-display
, libsns-dummy
, version ? "0.0.0-dev"
, ...
}:

# ===========================================================================
# Pure Nix rootfs (issue #26) -- evaluates nixos/appliance.nix into a NixOS
# system closure and packs it into a rootless ext4 image.
#
# STATUS: SCAFFOLD, NEVER BOOTED. It builds; it has not been near hardware.
# docs/nixos-rootfs.md is the feasibility study behind it and lists what must
# be hardware-tested, in what order.
#
# ---------------------------------------------------------------------------
# WHY A SECOND NIXPKGS PIN (the load-bearing constraint):
#
# systemd states a hard kernel floor in its README, and it moved past us:
#
#     systemd 256 (nixos-24.11)  minimum 3.15, recommended 4.15  -> 4.19 OK
#     systemd 257 (nixos-25.05)  minimum 3.15, recommended 5.4   -> 4.19 tainted
#     systemd 258 (nixos-25.11)  minimum 5.4                     -> 4.19 UNSUPPORTED
#     systemd 260 (nixos-26.05)  minimum 5.10                    -> 4.19 UNSUPPORTED
#     systemd 261 (nixos-unstable, this flake's main pin)        -> 4.19 UNSUPPORTED
#
# "⛔ Kernel versions below <N> ('minimum baseline') are not supported at all,
# and are missing required functionality" -- systemd README. Our kernel is
# 4.19.125 and cannot move, because the prebuilt ax_*.ko media modules load
# only into a kernel whose vermagic matches (docs/building.md).
#
# So the rootfs is evaluated against nixos-24.11 -- the newest branch whose
# systemd still lists 4.19 as ABOVE its recommended baseline -- while the rest
# of the flake stays on nixos-unstable. Our own aarch64 packages (server,
# libkvm, display, kernel modules) are cross-built from the unstable pin and
# dropped in as-is; they are self-contained ELF with their own store rpaths,
# so the two glibcs coexist. The cost is a frozen, EOL rootfs pin -- see
# docs/nixos-rootfs.md for the mitigation and the exit condition.
#
# ---------------------------------------------------------------------------
# BUILD MODEL: the appliance is evaluated as a NATIVE aarch64-linux system and
# built through binfmt/qemu-user emulation (this host has
# `extra-platforms = aarch64-linux`), not through pkgsCross. Almost the entire
# closure substitutes prebuilt from cache.nixos.org, so emulation only pays for
# the handful of tiny system derivations. Cross-compiling a full NixOS closure
# is the alternative and is materially worse.
#
# The ext4 is produced by nixpkgs' make-ext4-fs, which uses
# `fakeroot mkfs.ext4 -d` -- no root, no loop mount, same constraint that
# forced the debugfs surgery in pkgs/rootfs.nix.
# ===========================================================================

let
  lib = pkgs.lib;

  nanokvm = {
    inherit axera-libs ax-ko-blobs kernel kvm-encoder
      nanokvm-server nanokvm-web nanokvm-display libsns-dummy version;
  };

  eval = import (nixpkgsRootfs + "/nixos/lib/eval-config.nix") {
    system = null; # set via nixpkgs.hostPlatform in the module
    modules = [ ./appliance.nix ];
    specialArgs = { inherit nanokvm; };
  };

  toplevel = eval.config.system.build.toplevel;

  # The one contract the vendor initramfs enforces: `switch_root /realroot
  # /sbin/init`. Everything else in here is the ordinary FHS skeleton a NixOS
  # image needs before stage 2 can run, plus the system profile so that
  # /sbin/init resolves and a future switch-to-configuration has a generation
  # to switch from.
  rootImage = import (nixpkgsRootfs + "/nixos/lib/make-ext4-fs.nix") {
    inherit pkgs lib;
    inherit (pkgs) e2fsprogs libfaketime perl fakeroot zstd;
    storePaths = [ toplevel ];
    volumeLabel = "NANOKVM";
    populateImageCommands = ''
      mkdir -p ./files/sbin ./files/etc ./files/proc ./files/sys ./files/dev \
               ./files/run ./files/tmp ./files/var ./files/root ./files/boot \
               ./files/mnt ./files/opt ./files/soc ./files/home ./files/realroot
      chmod 1777 ./files/tmp
      chmod 0700 ./files/root

      # System profile -> the generation stage 2 boots.
      mkdir -p ./files/nix/var/nix/profiles ./files/nix/var/nix/gcroots
      ln -s ${toplevel}   ./files/nix/var/nix/profiles/system-1-link
      ln -s system-1-link ./files/nix/var/nix/profiles/system
      ln -s /nix/var/nix/profiles ./files/nix/var/nix/gcroots/profiles

      # THE switch_root TARGET.
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

    # Contract checks -- these are the failures that would show up as a silent
    # non-boot with no serial console (bootdelay=0, so there is no prompt to
    # catch it at). Assert them here instead.
    echo "=== verifying the switch_root contract ==="
    debugfs -R "stat /sbin/init" rootfs.ext4 2>/dev/null | grep -q "Type: symlink" \
      || { echo "ERROR: /sbin/init is not a symlink -- switch_root will fail" >&2; exit 1; }
    debugfs -R "stat /nix/var/nix/profiles/system" rootfs.ext4 2>/dev/null | grep -q "Inode:" \
      || { echo "ERROR: no /nix/var/nix/profiles/system -- /sbin/init dangles" >&2; exit 1; }
    debugfs -R "stat ${toplevel}/init" rootfs.ext4 2>/dev/null | grep -q "Inode:" \
      || { echo "ERROR: stage-2 init missing from the image closure" >&2; exit 1; }
    echo "  /sbin/init -> profile -> ${toplevel}/init: present."

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
    cat > "$out/NOTES.txt" <<EOF
    NanoKVM-Pro pure-Nix rootfs (issue #26) -- SCAFFOLD, NEVER BOOTED.

    system closure : ${toplevel}
    rootfs pin     : ${toString nixpkgsRootfs}
    init contract  : /sbin/init -> /nix/var/nix/profiles/system/init (NixOS stage 2)
    outputs        : nixos_rootfs.ext4 (raw), ubuntu_rootfs_sparse.ext4 (for the .axp)

    DO NOT FLASH THIS TO eMMC. Read docs/nixos-rootfs.md first; the validation
    ladder there starts with a chroot smoke test on a running device and ends
    with eMMC, and AXDL recovery needs Jeremy's hands on the board.
    EOF
    echo "Installed:"; ls -l "$out"
    runHook postInstall
  '';

  meta = {
    description =
      "NanoKVM-Pro rootfs built entirely from nixpkgs (NixOS system closure -> rootless ext4). Scaffold for issue #26; not boot-tested.";
    platforms = [ "x86_64-linux" ];
  };
}
