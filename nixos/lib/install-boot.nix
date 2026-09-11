{ pkgs
, lib ? pkgs.lib
, extlinuxTemplate
}:

# ===========================================================================
# `nanokvm-install-boot` -- the boot.loader.external install hook.
#
# "Installing the bootloader" on this board is writing one text file. There is
# no kernel to copy at switch time: `boot.kernel.enable = false` and the Image
# lives in /boot as a flake artefact with the stage-1 initrd inside it, so what
# a NixOS generation IS here is a userspace closure. The installer pins that
# closure into the default extlinux config and leaves the fallback alone.
#
# THE FALLBACK IS NEVER WRITTEN HERE. That is the whole safety property: at the
# moment of a switch the new generation has never booted, so promoting it to the
# rollback target would leave a board with two copies of the same untested
# system. The one exception is bootstrap -- if no fallback exists at all there is
# nothing to roll back TO, and a copy of the entry being installed is strictly
# better than a missing file.
#
# IT LIVES IN ITS OWN FILE (#86) so `nix flake check`'s `nanokvm-updater-loop`
# can instantiate it against the BUILD host's package set and run it for real.
# The appliance's own copy is aarch64, and a check that needed binfmt would not
# run on a release runner.
# ===========================================================================

pkgs.writeShellApplication {
  name = "nanokvm-install-boot";
  runtimeInputs = with pkgs; [ coreutils gnused gnugrep ];
  text = ''
    set -eu

    # --root exists so the whole installer can be exercised against a
    # directory tree in a build sandbox (nix flake check's
    # `nanokvm-updater-loop`), where there is no /boot and no eMMC.
    ROOT=""
    KERNEL=""
    FDT=""
    toplevel=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --root)   ROOT="''${2%/}"; shift 2 ;;
        --kernel) KERNEL="$2"; shift 2 ;;
        --fdt)    FDT="$2"; shift 2 ;;
        --*)      echo "nanokvm-install-boot: unknown option $1" >&2; exit 2 ;;
        *)        toplevel="$1"; shift ;;
      esac
    done
    [ -n "$toplevel" ] || { echo "usage: nanokvm-install-boot [--root D] [--kernel F] [--fdt F] <toplevel>" >&2; exit 2; }

    dir="$ROOT/boot/extlinux"
    conf="$dir/extlinux.conf"
    fallback="$dir/extlinux-fallback.conf"

    [ -d "$dir" ] || { echo "nanokvm: $dir is missing -- is /boot mounted?" >&2; exit 1; }

    # WHICH KERNEL THIS ENTRY BOOTS, in order of authority:
    #
    #   1. --kernel/--fdt              an update that ships its own kernel
    #   2. /run/nanokvm-pending-boot   nanokvm-update's note to itself, so a
    #                                  plain `switch-to-configuration boot`
    #                                  (which is what calls this hook) picks
    #                                  up the kernel the update just staged
    #   3. the current extlinux.conf   a generation switch that changes no
    #                                  kernel must keep the running one
    #
    # There is deliberately NO built-in default. The names are content-
    # addressed, so a guess would name a file that does not exist, and a
    # config naming a missing kernel is a board that loads nothing and has no
    # console to say so.
    pending="$ROOT/run/nanokvm-pending-boot"
    if [ -z "$KERNEL" ] && [ -r "$pending" ]; then
      KERNEL=$(sed -n 's|^KERNEL=||p' "$pending")
      FDT=$(sed -n 's|^FDT=||p' "$pending")
      echo "nanokvm: taking the boot payload from $pending"
    fi
    if [ -z "$KERNEL" ] && [ -r "$conf" ]; then
      KERNEL=$(sed -n 's|^[[:space:]]*LINUX[[:space:]]\+||p' "$conf" | head -1)
      FDT=$(sed -n 's|^[[:space:]]*FDT[[:space:]]\+||p' "$conf" | head -1)
    fi
    [ -n "$KERNEL" ] && [ -n "$FDT" ] || {
      echo "nanokvm: no kernel/dtb to name in $conf." >&2
      echo "         Pass --kernel/--fdt, or restore a config that names them." >&2
      exit 1
    }

    # The files have to BE there. This is the one check that separates "the
    # update wrote /boot" from "the update wrote a config about /boot".
    for f in "$KERNEL" "$FDT"; do
      [ -f "$ROOT/boot/$f" ] || {
        echo "nanokvm: /boot$f does not exist -- refusing to write a config that names it" >&2
        exit 1
      }
    done

    # Write, fsync, rename: a config half-written by a power cut is a board
    # that boots nothing, and this partition is the only thing U-Boot reads.
    tmp="$conf.new"
    sed -e "s|@INIT@|$toplevel/init|g" \
        -e "s|@KERNEL@|$KERNEL|g" \
        -e "s|@FDT@|$FDT|g" ${extlinuxTemplate} > "$tmp"
    grep -q "init=$toplevel/init" "$tmp" \
      || { echo "nanokvm: generated config does not name $toplevel" >&2; rm -f "$tmp"; exit 1; }
    ! grep -q '@[A-Z]*@' "$tmp" \
      || { echo "nanokvm: generated config still has a placeholder in it" >&2; rm -f "$tmp"; exit 1; }
    sync "$tmp"
    mv "$tmp" "$conf"

    if [ ! -e "$fallback" ]; then
      echo "nanokvm: no rollback fallback yet -- seeding it with this generation"
      cp "$conf" "$fallback.new"
      sync "$fallback.new"
      mv "$fallback.new" "$fallback"
    fi
    sync

    echo "nanokvm: default generation is now $toplevel on $KERNEL"
    echo "nanokvm: fallback stays $(sed -n 's|.*init=\([^ ]*\)/init.*|\1|p' "$fallback") on $(sed -n 's|^[[:space:]]*LINUX[[:space:]]\+||p' "$fallback" | head -1)"
    echo "nanokvm: the boot counter is armed; nanokvm-mark-good promotes this"
    echo "         generation to the fallback only once the boot is healthy."
  '';
}
