{ pkgs
, lib ? pkgs.lib
, serverEnabled ? true
, timeoutSec ? 240
, tolerateFailed ? [ ]
, bootcountReg ? "0x02390030"
, bootcountClear ? "0xB0010000"
}:

# ===========================================================================
# `nanokvm-mark-good` -- the health gate, and the other half of the rollback
# (#89 rung 5, reshaped by #99).
#
# WHAT "HEALTHY" MEANS for a KVM, in the three things it is FOR: the system
# finished starting, the network works, and the web server answers. A board
# that reaches a shell but serves nothing is not a board worth keeping as the
# rollback target.
#
# It does two things once that holds, and nothing at all before:
#
#   1. clears U-Boot's boot counter, so the next boot starts from zero;
#   2. rewrites /boot/extlinux/extlinux-fallback.conf to name the generation
#      that just proved itself.
#
# THE FALLBACK IS A DERIVATION OF THE OFFICIAL CONFIG, not a second rendering
# of it. Since #99 NixOS's own `generic-extlinux-compatible` builder is the
# only thing that writes /boot/extlinux/extlinux.conf and /boot/nixos/*, and
# that file already carries one LABEL per generation -- `nixos-default` for the
# one being booted by default, `nixos-<N>-default` for each of the last
# `configurationLimit` generations, each with its own kernel, initrd, dtb and
# pinned `init=`. So the fallback is that file with one line changed:
#
#     DEFAULT nixos-default   ->   DEFAULT nixos-<N>-default
#
# where N is the generation `/run/booted-system` resolves to. Both files then
# describe the same set of bootable generations and differ only in which one
# `sysboot` picks, which is exactly the shape U-Boot's parser wants: `DEFAULT`
# at top level is `parse_pxefile_top`'s `T_DEFAULT`, and it sets
# `cfg->default_label` (boot/pxe_utils.c).
#
# THE REFUSAL IS THE SAFETY PROPERTY. If the label is not in the file,
# `menu_default_choice()` returns -ENOENT and `handle_pxe_menu()` falls through
# to `boot_unattempted_labels()`, which boots the FIRST label -- i.e. the
# default generation, the one the rollback exists to escape. A fallback that
# names a label the file does not have is therefore worse than no promotion at
# all, so this refuses to write one and leaves the previous fallback standing.
#
# IT NEVER DELETES A FILE IN /boot. The extlinux builder collects its own
# obsolete kernels (`Removing no longer needed boot file:`), keyed on the
# generations it just wrote entries for. Anything this script removed would be
# something that builder had decided to keep.
#
# --root EXISTS FOR THE OFFLINE TEST, exactly as it does in the updater: every
# path is prefixed so `nix flake check`'s `nanokvm-mark-good-fallback` can run
# the real promotion against a fake /boot in a build sandbox. `--no-wait`
# skips the health poll and the register write, which are the two things a
# sandbox has no way to satisfy.
# ===========================================================================

pkgs.writeShellApplication {
  name = "nanokvm-mark-good";
  runtimeInputs = with pkgs; [ coreutils busybox curl iproute2 systemd gnugrep gnused gawk diffutils ];
  text = ''
    set -eu

    ROOT=""
    WAIT=1
    while [ $# -gt 0 ]; do
      case "$1" in
        --root)    ROOT="''${2%/}"; shift 2 ;;
        --no-wait) WAIT=0; shift ;;
        *) echo "usage: nanokvm-mark-good [--root DIR] [--no-wait]" >&2; exit 2 ;;
      esac
    done
    P() { printf '%s%s' "$ROOT" "$1"; }

    # TOP_CHIPMODE_GLB_BACKUP1, and the value U-Boot's DM_BOOTCOUNT_SYSCON
    # backend reads as "magic present, count zero": CONFIG_SYS_BOOTCOUNT_MAGIC
    # is 0xB001C041 and the four-byte mode keeps its top half in bits 31..16.
    # A plain 32-bit store is right here -- nothing else owns this word, and
    # unlike BACKUP0 there are no neighbouring bits to preserve.
    BOOTCOUNT_REG=${bootcountReg}
    BOOTCOUNT_CLEAR=${bootcountClear}

    deadline=$(( ${toString timeoutSec} ))
    start=$(cut -d. -f1 /proc/uptime)

    # /proc/uptime, never `date +%s`: timesyncd jumps the clock the moment
    # DHCP lands, and a wall-clock deadline expires instantly when it does.
    elapsed() { echo $(( $(cut -d. -f1 /proc/uptime) - start )); }

    # Units whose failure does not make this board unhealthy. See the header
    # block above `system_ok`.
    TOLERATE="${lib.concatStringsSep " " tolerateFailed}"

    # ---- is the SYSTEM up? ------------------------------------------------
    #
    # `running` is the plain answer. `degraded` means at least one unit
    # failed, and whether that matters depends entirely on WHICH unit: a
    # missing WiFi radio or an absent mini-display panel is not a reason to
    # roll a working KVM back onto its previous generation, and #85 and #84
    # each cost a hardware round to exactly that (a peripheral unit that
    # `exit 1`-ed held `bootcount` uncleared on every boot, three boots from a
    # rollback nobody asked for).
    #
    # The units themselves are the first fix -- optional hardware gets a
    # journal line and `exit 0` -- and this is the second. It is belt and
    # braces on purpose: a unit that starts failing for a NEW reason, or a
    # NixOS unit we do not own, must not be able to arm the rollback over a
    # peripheral. Anything NOT in the list still fails the gate, so a broken
    # server, a dead network or a failed nanokvm-video is as fatal as it ever
    # was.
    system_ok() {
      state=$(systemctl is-system-running 2>/dev/null || true)
      case "$state" in
        running) return 0 ;;
        degraded) ;;
        *) return 1 ;;
      esac
      [ -n "$TOLERATE" ] || return 1

      # `--plain` drops the leading bullet; column 1 is the unit name.
      for u in $(systemctl list-units --failed --plain --no-legend --no-pager \
                   | awk '{ print $1 }'); do
        case " $TOLERATE " in
          *" $u "*) ;;
          *) return 1 ;;
        esac
      done
      return 0
    }

    healthy() {
      system_ok || return 1
      ip -4 route show default | grep -q . || return 1
      ${lib.optionalString serverEnabled ''
        curl -sk -o /dev/null -m 5 https://127.0.0.1/ || return 1
      ''}
      return 0
    }

    if [ "$WAIT" = 1 ]; then
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
      # Say so out loud when the board is healthy DESPITE a failed unit -- the
      # whole point of the list is that it is a deliberate, readable decision
      # rather than a silently relaxed gate.
      if [ "$(systemctl is-system-running 2>/dev/null || true)" = degraded ]; then
        echo "mark-good: degraded, and tolerated: $(systemctl list-units --failed --plain --no-legend --no-pager | awk '{ print $1 }' | tr '\n' ' ')"
      fi
      devmem $BOOTCOUNT_REG 32 $BOOTCOUNT_CLEAR
      echo "mark-good: bootcount cleared -> $(devmem $BOOTCOUNT_REG 32)"
    fi

    # ---- the fallback -----------------------------------------------------
    #
    # THE DIRECTORY HAS TO BE THERE, and checking is not paranoia (#94).
    # /boot is mounted `nofail`, and on the VENDOR layout there is no extlinux
    # boot method at all -- the vendor U-Boot loads the kernel from a signed
    # partition by byte offset. In both cases this would otherwise write into
    # the root filesystem's own /boot directory: on the vendor layout that
    # makes every first boot of `.#nixos-firmware-image` end up `degraded`, and
    # with /boot unmounted it would SUCCEED, reporting a promotion into a file
    # U-Boot can never read. Skipping is right either way -- the counter is
    # already cleared, which is the half that keeps the board off the rollback
    # path.
    dir="$(P /boot/extlinux)"
    conf="$dir/extlinux.conf"
    fallback="$dir/extlinux-fallback.conf"

    if [ ! -d "$dir" ]; then
      echo "mark-good: no $dir -- not promoting a fallback."
      echo "mark-good: that is expected on the vendor layout, whose U-Boot does"
      echo "           not read extlinux; anywhere else it means /boot is not mounted."
      exit 0
    fi
    [ -r "$conf" ] || { echo "mark-good: no $conf -- nothing to derive a fallback from" >&2; exit 0; }

    # WHICH GENERATION BOOTED. /run/booted-system is the only thing on this
    # system that says it: `sysboot` tells the kernel nothing about the files
    # it loaded, and a `nixos-rebuild switch` between this boot and now has
    # already rewritten extlinux.conf to name a generation that has never
    # booted. Take the HIGHEST-numbered profile link that resolves to it, so a
    # generation installed twice promotes as its most recent number -- the one
    # the builder is certain to have written an entry for.
    booted=$(readlink -f "$(P /run/booted-system)" 2>/dev/null || true)
    [ -n "$booted" ] || { echo "mark-good: no /run/booted-system -- not promoting" >&2; exit 0; }

    gen=""
    for link in "$(P /nix/var/nix/profiles)"/system-*-link; do
      [ -e "$link" ] || continue
      [ "$(readlink -f "$link")" = "$booted" ] || continue
      n=$(basename "$link"); n=''${n#system-}; n=''${n%-link}
      case "$n" in (*[!0-9]*) continue ;; esac
      if [ -z "$gen" ] || [ "$n" -gt "$gen" ]; then gen="$n"; fi
    done
    if [ -z "$gen" ]; then
      echo "mark-good: $booted is not a system profile generation -- not promoting." >&2
      exit 0
    fi
    label="nixos-$gen-default"

    # The label has to BE in the file. See the header: a DEFAULT nothing
    # matches makes U-Boot boot the first label, which is the generation the
    # rollback exists to escape.
    if ! grep -qx "LABEL $label" "$conf"; then
      echo "mark-good: $conf has no \"LABEL $label\" -- not promoting." >&2
      echo "mark-good: generation $gen is outside the bootloader's" >&2
      echo "           configurationLimit, or this /boot predates #99." >&2
      echo "mark-good: the previous fallback stands." >&2
      exit 1
    fi

    # One line changed, and only that line. Write-fsync-rename, because a
    # config half-written by a power cut is the file `altbootcmd` reads.
    awk -v l="$label" '
      $1 == "DEFAULT" && !done { print "DEFAULT " l; done = 1; next }
      { print }
    ' "$conf" > "$fallback.new"

    grep -qx "DEFAULT $label" "$fallback.new" \
      || { echo "mark-good: the derived fallback does not select $label" >&2
           rm -f "$fallback.new"; exit 1; }
    # Belt and braces: exactly one line may differ from the official config.
    d=$(diff "$conf" "$fallback.new" | grep -c '^[<>]' || true)
    [ "$d" -le 2 ] \
      || { echo "mark-good: the derived fallback differs from $conf in more than" >&2
           echo "           its DEFAULT line ($d changed lines) -- refusing" >&2
           rm -f "$fallback.new"; exit 1; }

    if cmp -s "$fallback.new" "$fallback"; then
      rm -f "$fallback.new"
      echo "mark-good: fallback is already generation $gen ($booted)"
    else
      sync "$fallback.new"
      mv "$fallback.new" "$fallback"
      sync
      echo "mark-good: fallback promoted to generation $gen ($booted)"
    fi
  '';
}
