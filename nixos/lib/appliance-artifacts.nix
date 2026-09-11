{ pkgs, nixpkgs }:

# ===========================================================================
# The two artifacts a NanoKVM-Pro NixOS system turns into: the `/boot`
# directory the bootloader reads, and the ext4 the eMMC carries.
#
# They live here, as PURE FUNCTIONS OF THE SYSTEM CLOSURE, for one reason: the
# `.axp` builder (nixos/lib/make-axp-image.nix, wired up by nixos/image-axp.nix)
# has to produce them from INSIDE the module system -- `system.build.axpImage`
# is defined in terms of `config.system.build.toplevel`. Computing them outside
# the eval and injecting the result back would be a module-system cycle.
# Because they are pure functions, `nixos/rootfs.nix` (which calls them from
# outside, at flake level) and the module (which calls them from inside) land
# on exactly the same store paths, and nothing is built twice.
#
# Everything about WHY they look like this is in nixos/rootfs.nix's header and
# docs/nixos-rootfs.md ("The boot contract"); the comments here cover only the
# traps that live in the code itself.
#
# `pkgs` is the BUILD host's package set (x86_64-linux). The ext4 is packed by
# nixpkgs' make-ext4-fs on the build machine -- `fakeroot mkfs.ext4 -d`, no
# root and no loop mount -- so it must not come from the emulated aarch64 set.
# ===========================================================================

let
  lib = pkgs.lib;

  # ---- /boot, written by NixOS's own extlinux builder (#99) --------------
  #
  # THE IMAGE'S /boot AND THE DEVICE'S ARE THE SAME PROGRAM'S OUTPUT. On the
  # board `switch-to-configuration boot` runs
  # nixos/modules/system/boot/loader/generic-extlinux-compatible's builder;
  # here we run THAT SCRIPT against the image's toplevel, exactly the way
  # nixpkgs' sd-image does in `populateRootCommands`. So a freshly flashed
  # board and one that has switched once have a /boot of identical shape, and
  # there is no second generator to keep in step.
  #
  # WHY NOT `config.boot.loader.generic-extlinux-compatible.populateCmd`: that
  # attribute instantiates the builder from `pkgs.buildPackages`, which for a
  # natively-evaluated aarch64 system is aarch64 -- so running it at image
  # build time would need binfmt on whatever machine cuts the release. The
  # builder is bash + coreutils + sed + grep and the files it copies are
  # architecture-neutral, so it is instantiated from the BUILD host's set
  # instead. The three arguments that shape its output are passed in from the
  # module's own options, so the two cannot disagree about them.
  extlinuxBuilder = import
    (nixpkgs + "/nixos/modules/system/boot/loader/generic-extlinux-compatible/extlinux-conf-builder.nix")
    { inherit lib pkgs; };

  mkBootDir = { toplevel, configurationLimit, timeout, dtbName }:
    pkgs.runCommand "nanokvm-boot-dir"
      {
        nativeBuildInputs = with pkgs; [ coreutils gnugrep gnused ];
        meta.description =
          "The /boot tree for one NixOS generation, written by NixOS's own extlinux builder";
      } ''
      mkdir -p "$out"
      ${extlinuxBuilder} \
        -g ${toString configurationLimit} \
        -t ${if timeout == null then "-1" else toString timeout} \
        -n ${lib.escapeShellArg dtbName} \
        -d "$out" \
        -c ${toplevel}

      # THE SEED FALLBACK. `altbootcmd` reads this file and nothing creates it
      # on a board that has never switched, so it ships as a copy: the only
      # known-good generation on a freshly flashed board is the one being
      # flashed. `nanokvm-mark-good` derives every later version of it from
      # extlinux.conf (nixos/lib/mark-good.nix).
      cp "$out/extlinux/extlinux.conf" "$out/extlinux/extlinux-fallback.conf"

      # --- contract checks, every one of them a silent non-boot ----------
      conf="$out/extlinux/extlinux.conf"
      echo "=== $conf ==="
      cat "$conf"

      n=$(find "$out/extlinux" -name 'extlinux.conf' | wc -l)
      [ "$n" = 1 ] || { echo "ERROR: $n extlinux.conf files under $out/extlinux" >&2; exit 1; }

      # NO TOP-LEVEL `MENU` KEYWORD. `parse_pxefile_top()` sets
      # `cfg->prompt = 1` on any of them (boot/pxe_utils.c) and U-Boot then
      # reads this board's unterminated console forever. The indented
      # `MENU LABEL` lines inside a LABEL go to `parse_label_menu()`, which
      # does not. So the test is on the COLUMN, and it is exact.
      if grep -q '^MENU' "$conf"; then
        echo "ERROR: a top-level MENU keyword makes U-Boot prompt on a console" >&2
        echo "       nobody can reach. Set boot.loader.timeout = 0." >&2
        exit 1
      fi

      grep -qx 'DEFAULT nixos-default' "$conf" \
        || { echo "ERROR: the config does not default to nixos-default" >&2; exit 1; }
      grep -qx 'LABEL nixos-default' "$conf" \
        || { echo "ERROR: the config has no nixos-default entry" >&2; exit 1; }
      grep -q 'APPEND init=${toplevel}/init ' "$conf" \
        || { echo "ERROR: the default entry does not pin this image's generation" >&2; exit 1; }

      # Every file the config names has to BE there. A config naming a missing
      # kernel is a board that loads nothing and has no console to say so.
      for kw in LINUX INITRD FDT; do
        f=$(sed -n "s|^[[:space:]]*$kw[[:space:]]\+||p" "$conf" | head -1)
        [ -n "$f" ] || { echo "ERROR: no $kw line in $conf" >&2; exit 1; }
        # Paths are relative to the config's own directory (ctx->bootdir in
        # U-Boot's get_relfile()), which is /extlinux -- hence ../nixos/...
        [ -f "$out/extlinux/$f" ] \
          || { echo "ERROR: $kw names $f, which is not in this /boot" >&2; exit 1; }
        echo "  $kw $f -> $(stat -Lc%s "$out/extlinux/$f") bytes"
      done

      echo "=== /boot tree ==="
      find "$out" -maxdepth 2 | sort
      du -sh "$out"
    '';

  mkRootImage = toplevel: import (nixpkgs + "/nixos/lib/make-ext4-fs.nix") {
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

      # THE switch_root BACKSTOP. Every extlinux LABEL pins `init=` since #99,
      # so this is no longer the mechanism -- but stage 1 falls back to
      # $targetRoot/init when the command line carries none, and a /boot
      # written by hand during a hardware round might. /sbin/init is kept as
      # well: it costs a symlink and it is what the vendor initramfs would
      # exec if this image were ever booted by the 4.19 kernel.
      ln -s /nix/var/nix/profiles/system/init ./files/init
      ln -s /nix/var/nix/profiles/system/init ./files/sbin/init

      # Marks the root as NixOS-managed; switch-to-configuration refuses without it.
      touch ./files/etc/NIXOS

      # THE FIRST GENERATION'S CLOSURE LIST (#86). There is no nix on the
      # appliance, so nothing on the device can ever recompute which store
      # paths a generation needs -- and `nanokvm-gc` refuses to delete anything
      # while a kept generation has no list, which without this file would be
      # true of the flashed one forever. Every update writes its own alongside.
      #
      # It lives in /var, NOT in the closure, and it has to: a file inside the
      # closure that lists the closure would change the toplevel's hash, which
      # would change the file. The image builder is the one place with both the
      # toplevel and a writable /var.
      mkdir -p ./files/var/lib/nanokvm/closures
      cp ${pkgs.writeClosure [ toplevel ]} \
         ./files/var/lib/nanokvm/closures/$(basename ${toplevel}).txt
      chmod 0644 ./files/var/lib/nanokvm/closures/$(basename ${toplevel}).txt
    '';
  };

  # The packed rootfs, in both forms: raw ext4 (dd / debugfs / QEMU) and the
  # Android-sparse copy the .axp carries. Every contract check that can be made
  # offline is made here, on the packed image -- each one would otherwise be a
  # silent non-boot on a board with no console and bootdelay=0.
  mkRootfs = { toplevel, bootDir, version, variant, rootDevice }:
    pkgs.stdenvNoCC.mkDerivation {
      pname = "nanokvm-pro-nixos-rootfs";
      inherit version;

      dontUnpack = true;
      dontConfigure = true;

      nativeBuildInputs = with pkgs; [ e2fsprogs android-tools ];

      buildPhase = ''
        runHook preBuild
        set -euo pipefail

        cp ${mkRootImage toplevel} rootfs.ext4
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

        # THE KERNEL IS IN THE CLOSURE (#99), and so are the initrd and the
        # dtbs. Without them the extlinux builder has nothing to copy and
        # /boot names files that do not exist -- and the only symptom on the
        # board is a bootloader that loads nothing, silently.
        for l in kernel initrd dtbs; do
          debugfs -R "stat ${toplevel}/$l" rootfs.ext4 2>/dev/null | grep -q "Inode:" \
            || { echo "ERROR: ${toplevel}/$l is not in the image -- is boot.kernel.enable off?" >&2; exit 1; }
        done
        echo "  the generation carries its own kernel, initrd and dtbs."

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

        # Android-sparse copy, the form the .axp carries.
        img2simg rootfs.ext4 ubuntu_rootfs_sparse.ext4

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mkdir -p "$out"
        cp rootfs.ext4               "$out/nixos_rootfs.ext4"
        cp ubuntu_rootfs_sparse.ext4 "$out/ubuntu_rootfs_sparse.ext4"
        ln -s "${toplevel}" "$out/system"
        ln -s "${bootDir}"  "$out/boot"
        cat > "$out/NOTES.txt" <<EOF
        NanoKVM-Pro NixOS appliance rootfs (issue #78) -- variant: ${variant}

        system closure : ${toplevel}
        nixpkgs pin    : ${toString nixpkgs}
        root device    : ${rootDevice}
        init contract  : each extlinux LABEL pins init=<generation>/init;
                         /init -> /nix/var/nix/profiles/system/init is the backstop
        stage 1        : the generation's own initrd, loaded off /boot by U-Boot
        outputs        : nixos_rootfs.ext4 (raw), ubuntu_rootfs_sparse.ext4 (.axp),
                         boot/ (the extlinux tree this generation's /boot carries)

        DO NOT FLASH THE eMMC ROOTFS PARTITION WITH THIS while the vendor system is
        the only way back onto the board. Read docs/nixos-rootfs.md; the reversible
        hardware test is the loop-image variant (.#nixos-appliance-loop), and AXDL
        recovery needs Jeremy's hands on the board.
        EOF
        echo "Installed:"; ls -l "$out"
        runHook postInstall
      '';

      meta = {
        description =
          "NanoKVM-Pro NixOS appliance rootfs (${variant} root) -- system closure -> rootless ext4, for the mainline kernel";
        platforms = [ "x86_64-linux" ];
      };
    };
in
{ inherit mkBootDir mkRootImage mkRootfs; }
