{ pkgs
, lib ? pkgs.lib
, stableUrl # release base URL: <base>/<manifestName>, <base>/<payload>
, previewUrl # the rolling preview channel's base URL
, manifestName ? "nanokvm_pro_sys_latest.json"
, keepGenerations ? 3
, stateDir ? "/var/lib/nanokvm"
, cacheDir ? "/var/cache/nanokvm-update"
}:

# ===========================================================================
# `nanokvm-update` and `nanokvm-gc` -- the appliance's whole update mechanism
# (#86).
#
# WHAT AN UPDATE IS HERE. The appliance has no `nix` yet (nixos/appliance.nix,
# `nix.enable = false`; #100 turns it on): the rootfs is a fixed closure the
# build host produced, which is what keeps the image small and the device
# auditable. So an update is not a `nixos-rebuild`; it is a SYSTEM BUNDLE --
# the new toplevel's whole closure and a list saying which store paths belong
# to it -- unpacked into the store, made the system profile, and booted into.
# Once #100 lands, the profile and closure bookkeeping below become
# `nix-env -p .../system --set` and a real store database; the shape of the
# bundle does not change.
#
# THE BUNDLE CARRIES NO /boot HALF ANY MORE (#99). The kernel, the initrd and
# the device tree are part of the generation, so they arrive as ordinary store
# paths in the closure, and `switch-to-configuration boot` -- NixOS's own
# extlinux builder -- is what copies them into /boot. This script does not
# write a single byte of /boot, which is the whole point of the change: there
# is one writer, and it is the official one.
#
# THE REBOOT IS THE POINT, not an afterthought. The generation is installed
# with `switch-to-configuration boot`, so nothing about it is live until the
# board restarts; the restart is counted by U-Boot's `bootcount`, and
# `nanokvm-mark-good` clears that counter only once the NEW system is running,
# routed and serving. A generation that does not come up healthy is therefore
# rolled back by `altbootcmd` on the fourth attempt with nobody watching --
# which is the only rollback story a box with no console can have. `switch`
# would activate an untested userspace with no way back, and is never used.
#
# TWO CALLERS, ONE IMPLEMENTATION. The web UI's "update" button reaches this
# through the server's install() override (pkgs/nanokvm-server/
# install-bundle.go.in), which hands over an already-downloaded, already
# SHA-512-verified, already untarred bundle; the systemd timer runs the whole
# cycle itself. Both end up in `install-staged`.
#
# --root EXISTS FOR THE OFFLINE TEST. Every path this script touches is
# prefixed, so `nix flake check`'s `nanokvm-updater-loop` can run a real bundle
# into a real fake root inside a build sandbox -- no device, no loop mount, no
# privileges. That check is the only reason any of this is provable before it
# meets hardware.
#
# WHAT IS DELIBERATELY NOT HERE:
#
#   * No signature check. The bundle is gated by a SHA-512 that comes from our
#     own manifest, so this is integrity, not authenticity, and TLS to the
#     release host is the trust boundary -- exactly as the legacy OTA was.
#     Signing is #31; it plugs in at `verify_payload`, between the hash check
#     and the unpack, and nowhere else.
#   * No delta bundles. See docs/updates.md ("Weighed and rejected").
# ===========================================================================

let
  # Everything the scripts shell out to. `busybox` last, so the real tools win
  # and only `devmem` comes from it.
  tools = with pkgs; [
    coreutils gnused gnugrep gawk gnutar gzip findutils curl openssl jq util-linux
    systemd busybox
  ];

  usageText = ''
    usage: nanokvm-update [--root DIR] [--no-activate] [--no-reboot] <command>

      check                    what is installed, and what the channel offers
      update                   check, download, install, reboot (what the timer runs)
      install <bundle.tar.gz>  verify + unpack + install a bundle from a file
      install-staged <dir> [v] install an already-unpacked bundle (the web UI path)
      gc                       drop old generations and the store paths only they used
      status                   generations, both boot configs, /boot usage

    A bundle is built by "nix build .#system-bundle"; see docs/updates.md.
  '';

  # Shared preamble: option parsing and the path helpers, so the two scripts
  # cannot disagree about where anything lives.
  common = ''
    ROOT=""
    say() { printf 'nanokvm-update: %s\n' "$*"; }
    die() { printf 'nanokvm-update: %s\n' "$*" >&2; exit 1; }

    # /nix/store is a read-only BIND mount on the appliance, and `remount,ro`
    # alone silently does nothing on a bind -- it needs `remount,bind,ro`.
    # Under --root there is no mount at all, so both are no-ops.
    store_rw() {
      [ -z "$ROOT" ] || return 0
      mountpoint -q /nix/store || return 0
      mount -o remount,rw /nix/store
    }
    store_ro() {
      [ -z "$ROOT" ] || return 0
      mountpoint -q /nix/store || return 0
      mount -o remount,bind,ro /nix/store
    }
    P() { printf '%s%s' "$ROOT" "$1"; }

    # WHICH GENERATION AN EXTLINUX CONFIG ACTUALLY BOOTS (#99).
    #
    # NixOS's builder writes one LABEL per generation and a single top-level
    # DEFAULT that selects among them, so "the `init=` in this file" is no
    # longer a question with one answer -- there are several, and only one of
    # them is live. Reading the first would pin the wrong generation, and for
    # `nanokvm-gc` that means deleting the one the ROLLBACK depends on.
    #
    # Prints the toplevel store path the file's DEFAULT entry pins, or nothing
    # at all. Every caller must treat "nothing" as "do not delete", never as
    # "nothing is pinned".
    conf_default_toplevel() {
      [ -r "$1" ] || return 0
      awk '
        $1 == "DEFAULT" && !d { want = $2; d = 1; next }
        $1 == "LABEL"         { cur = $2; next }
        cur == want && $1 == "APPEND" {
          for (i = 2; i <= NF; i++)
            if (substr($i, 1, 5) == "init=") {
              p = substr($i, 6)
              sub(/\/init$/, "", p)
              print p
              exit
            }
        }
      ' "$1"
    }
  '';

  updater = pkgs.writeShellApplication {
    name = "nanokvm-update";
    runtimeInputs = tools;
    text = ''
      set -eu
      ${common}

      STABLE_URL='${stableUrl}'
      PREVIEW_URL='${previewUrl}'
      MANIFEST='${manifestName}'
      STATE='${stateDir}'
      CACHE='${cacheDir}'
      ACTIVATE=1
      REBOOT=1

      usage() {
        printf '%s\n' ${lib.escapeShellArg usageText} >&2
        exit 2
      }

      # ---- the channel ----------------------------------------------------
      base_url() {
        # Parity with the server: the web UI's "preview updates" toggle is a
        # flag file, and it has to select the same channel here or the button
        # and the timer would install different things.
        if [ -e "$(P /etc/kvm/preview_updates)" ]; then
          printf '%s' "$PREVIEW_URL"
        else
          printf '%s' "$STABLE_URL"
        fi
      }

      current_version() {
        for f in "$(P /run/current-system)/etc/nanokvm-version" \
                 "$(P /etc/nanokvm-version)"; do
          if [ -r "$f" ]; then tr -d '[:space:]' < "$f"; return 0; fi
        done
        echo "0.0.0-unknown"
      }

      fetch_manifest() {
        curl -fsSL --retry 3 --retry-delay 3 -m 60 "$(base_url)/$MANIFEST"
      }

      # ---- verification ---------------------------------------------------
      # The one gate between the network and this board's root filesystem.
      # A signature check (#31) belongs HERE, after this and before the unpack.
      verify_payload() {
        local file="$1" want="$2"
        local got
        got=$(openssl dgst -sha512 -binary "$file" | base64 -w0)
        [ "$got" = "$want" ] || die "sha512 mismatch on $(basename "$file")"
        say "sha512 verified"
      }

      # ---- installing an unpacked bundle ----------------------------------
      install_staged() {
        local dir="$1"
        local mf="$dir/MANIFEST.json"
        [ -r "$mf" ] || die "$dir is not a system bundle (no MANIFEST.json)"

        local fmt top
        fmt=$(jq -r '.format' "$mf")
        [ "$fmt" = "nanokvm-system-bundle/1" ] \
          || die "unknown bundle format '$fmt' -- this system installs nanokvm-system-bundle/1"
        top=$(jq -r '.toplevel' "$mf")
        [ -r "$dir/closure.txt" ] || die "$dir has no closure.txt"
        grep -qxF "$top" "$dir/closure.txt" \
          || die "closure.txt does not contain the toplevel it claims ($top)"

        say "bundle $(jq -r '.version' "$mf"): $top"

        # --- 1. the store ------------------------------------------------
        # Every path in the closure must be either already installed or in the
        # bundle. Checked in full BEFORE anything is moved, because a closure
        # with a hole in it is a generation that activates and then dies on a
        # missing binary -- and this board has no console to say which.
        local missing=""
        local n_have=0 n_new=0 b
        while read -r p; do
          [ -n "$p" ] || continue
          b=''${p#/nix/store/}
          if [ -e "$(P /nix/store)/$b" ]; then
            n_have=$((n_have + 1))
          elif [ -e "$dir/store/$b" ]; then
            n_new=$((n_new + 1))
            missing="$missing $b"
          else
            die "closure path $p is neither installed nor carried by the bundle"
          fi
        done < "$dir/closure.txt"
        say "closure: $n_have already here, $n_new to install"

        store_rw
        # shellcheck disable=SC2086
        for b in $missing; do
          if ! mv -T "$dir/store/$b" "$(P /nix/store)/$b" 2>/dev/null; then
            # Different filesystem (a --root test, or a bundle unpacked
            # elsewhere): copy to a sibling temp and rename into place, so a
            # half-copied path is never visible under its real name.
            cp -a "$dir/store/$b" "$(P /nix/store)/.nanokvm-tmp-$b"
            mv -T "$(P /nix/store)/.nanokvm-tmp-$b" "$(P /nix/store)/$b"
          fi
        done
        sync
        store_ro
        [ -e "$(P /nix/store)/''${top#/nix/store/}" ] || die "the toplevel is not in the store after unpacking"

        # --- 2. the closure list ------------------------------------------
        # WITHOUT THIS THERE IS NO GC. There is no nix on this board, so
        # nothing can recompute which paths a generation needs; the bundle's
        # own list is the only record, and it is kept per generation.
        mkdir -p "$(P "$STATE")/closures"
        install -m 0644 "$dir/closure.txt" "$(P "$STATE")/closures/''${top#/nix/store/}.txt"

        # --- 3. the system profile ----------------------------------------
        # AFTER the store, and that ordering is the failure plan: everything
        # that can fail on a full filesystem has already run, and if anything
        # below this line dies, what boots is still decided by the
        # extlinux.conf already on /boot -- which pins `init=` per entry, so
        # the profile the next boot follows does not matter.
        #
        # THE SYMLINK DANCE IS A STAND-IN. The official way to advance a
        # profile is `nix-env -p /nix/var/nix/profiles/system --set <toplevel>`,
        # and #100 puts `nix` on the appliance so this can be exactly that.
        # Until then there is no nix here to run it, and the store has no
        # database for it to consult, so the links are made by hand -- in the
        # same order and with the same atomic rename nix-env uses.
        local prof; prof="$(P /nix/var/nix/profiles)"
        mkdir -p "$prof"
        local next; next=$(next_generation "$prof")
        ln -sfn "$(P "$top")" "$prof/system-$next-link"
        ln -sfn "system-$next-link" "$prof/.system-new"
        mv -Tf "$prof/.system-new" "$prof/system"
        sync
        say "generation $next is now the system profile"

        # --- 4. /boot, written by NixOS and by nothing else ----------------
        # `switch-to-configuration boot` runs the generation's own
        # `installBootLoader` -- the generic-extlinux-compatible builder --
        # which copies THIS generation's kernel, initrd and dtbs into
        # /boot/nixos/ and rewrites /boot/extlinux/extlinux.conf. It also
        # collects the boot files no entry names any more. Nothing in this
        # script touches /boot at all (#99): one writer, and it is the
        # official one.
        #
        # It runs LAST, and out of the NEW toplevel, because it is the step
        # that decides what the next boot is. Everything before it is undone
        # by simply not doing this.
        if [ "$ACTIVATE" = 1 ] && [ -z "$ROOT" ]; then
          "$top/bin/switch-to-configuration" boot
        else
          say "not activating (--no-activate or --root): /boot is UNCHANGED, so the"
          say "next boot still runs whatever extlinux.conf already names."
        fi
        sync

        say "installed. The reboot is what proves it: U-Boot counts the attempt"
        say "and nanokvm-mark-good clears the counter only once this system is"
        say "running, routed and serving. Three bad attempts roll it back."
      }

      next_generation() {
        local prof="$1" max=0 n
        for l in "$prof"/system-*-link; do
          [ -e "$l" ] || continue
          n=$(basename "$l"); n=''${n#system-}; n=''${n%-link}
          case "$n" in (*[!0-9]*) continue ;; esac
          if [ "$n" -gt "$max" ]; then max=$n; fi
        done
        echo $((max + 1))
      }

      # ---- commands -------------------------------------------------------
      cmd=""
      args=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --root)        ROOT="''${2%/}"; shift 2 ;;
          --no-activate) ACTIVATE=0; shift ;;
          --no-reboot)   REBOOT=0; shift ;;
          -h|--help)     usage ;;
          --*)           echo "unknown option $1" >&2; usage ;;
          *)             if [ -z "$cmd" ]; then cmd="$1"; else args="$args $1"; fi; shift ;;
        esac
      done
      [ -n "$cmd" ] || usage
      # shellcheck disable=SC2086
      set -- $args

      case "$cmd" in
      check)
        cur=$(current_version)
        mf=$(fetch_manifest) || die "could not reach $(base_url)/$MANIFEST"
        av=$(printf '%s' "$mf" | jq -r '.version')
        echo "installed: $cur"
        echo "available: $av  ($(printf '%s' "$mf" | jq -r '.name'))"
        echo "channel:   $(base_url)"
        [ "$cur" != "$av" ] || echo "up to date"
        ;;

      update)
        # NEVER INSTALL OVER AN UNPROVEN BOOT. `bootcount` is only cleared once
        # nanokvm-mark-good has seen this system running, routed and serving;
        # writing a new extlinux.conf before that would replace the very thing
        # the counter is counting, and the rollback would then land on a
        # generation nobody chose. TOP_CHIPMODE_GLB_BACKUP1, 0xB0010000 =
        # healthy. Absent devmem (a --root run, or QEMU) the check is skipped.
        if [ -z "$ROOT" ] && command -v devmem >/dev/null 2>&1; then
          bc=$(devmem 0x02390030 32 2>/dev/null || echo "")
          case "$bc" in
            0x[Bb]0010000|"") ;;
            *) die "bootcount is $bc -- this boot has not been marked good yet. \
Wait for nanokvm-mark-good, or fix what is unhealthy first." ;;
          esac
        fi
        cur=$(current_version)
        mf=$(fetch_manifest) || die "could not reach $(base_url)/$MANIFEST"
        av=$(printf '%s' "$mf" | jq -r '.version')
        name=$(printf '%s' "$mf" | jq -r '.name')
        sha=$(printf '%s' "$mf" | jq -r '.sha512')
        if [ "$cur" = "$av" ]; then say "already on $cur"; exit 0; fi
        # A string compare, not semver: the appliance takes what the channel
        # offers, because "the channel" is a release we cut. Downgrades are a
        # deliberate operation (point the URL at an older release), and the
        # rollback that catches a bad one is the boot counter, not a version
        # test here.
        say "updating $cur -> $av"
        mkdir -p "$(P "$CACHE")"
        tarball="$(P "$CACHE")/$name"
        curl -fL --retry 3 --retry-delay 5 -o "$tarball.part" "$(base_url)/$name"
        mv -f "$tarball.part" "$tarball"
        verify_payload "$tarball" "$sha"
        d="$(P "$CACHE")/unpacked"
        rm -rf "$d"; mkdir -p "$d"
        tar -C "$d" -xzf "$tarball"
        top=$(find "$d" -mindepth 1 -maxdepth 1 -type d | head -1)
        install_staged "$top"
        rm -rf "$d" "$tarball"
        if [ "$REBOOT" = 1 ] && [ -z "$ROOT" ]; then
          say "rebooting into $av"
          systemctl --no-block reboot
        fi
        ;;

      install)
        tarball="''${1:?usage: nanokvm-update install <bundle.tar.gz>}"
        d="$(P "$CACHE")/unpacked"
        rm -rf "$d"; mkdir -p "$d"
        tar -C "$d" -xzf "$tarball"
        top=$(find "$d" -mindepth 1 -maxdepth 1 -type d | head -1)
        install_staged "$top"
        rm -rf "$d"
        ;;

      install-staged)
        install_staged "''${1:?usage: nanokvm-update install-staged <dir> [version]}"
        ;;

      gc)
        nanokvm-gc ''${ROOT:+--root "$ROOT"} --keep ${toString keepGenerations}
        ;;

      status)
        echo "installed version : $(current_version)"
        echo "booted system     : $(readlink -f "$(P /run/booted-system)" 2>/dev/null || echo '?')"
        echo "current system    : $(readlink -f "$(P /run/current-system)" 2>/dev/null || echo '?')"
        echo "profile           : $(readlink -f "$(P /nix/var/nix/profiles/system)" 2>/dev/null || echo '?')"
        echo "generations       : $(find "$(P /nix/var/nix/profiles)" -maxdepth 1 -name "system-*-link" 2>/dev/null | wc -l)"
        for c in extlinux.conf extlinux-fallback.conf; do
          f="$(P /boot/extlinux)/$c"
          [ -r "$f" ] || { echo "$c: (absent)"; continue; }
          l=$(awk '$1 == "DEFAULT" { print $2; exit }' "$f")
          echo "$c: DEFAULT $l -> $(conf_default_toplevel "$f")"
        done
        echo "boot files        : $(du -sh "$(P /boot/nixos)" 2>/dev/null | cut -f1) in /boot/nixos"
        ;;

      *) usage ;;
      esac
    '';
  };

  gc = pkgs.writeShellApplication {
    name = "nanokvm-gc";
    runtimeInputs = tools;
    text = ''
      set -eu
      ${common}

      STATE='${stateDir}'
      KEEP=${toString keepGenerations}
      DRYRUN=0

      while [ $# -gt 0 ]; do
        case "$1" in
          --root)    ROOT="''${2%/}"; shift 2 ;;
          --keep)    KEEP="$2"; shift 2 ;;
          -n|--dry-run) DRYRUN=1; shift ;;
          *) echo "usage: nanokvm-gc [--root DIR] [--keep N] [-n]" >&2; exit 2 ;;
        esac
      done

      prof="$(P /nix/var/nix/profiles)"
      store="$(P /nix/store)"
      closures="$(P "$STATE")/closures"
      [ -d "$prof" ] || die "no $prof"

      # ---- what must survive, whatever the numbers say --------------------
      # Four things, and each of them is a board that does not come back if it
      # is wrong: the profile the next boot follows, the system this boot is
      # running, and the two generations the boot configs name. The FALLBACK is
      # on that list for the same reason the whole rollback exists -- it is the
      # thing that gets used precisely when the default does not work.
      # A FILE, one path per line, so a store path can never match another by
      # being a prefix of it.
      pinned="$(mktemp)"
      live=""; present=""; dead=""
      trap 'rm -f "$pinned" "$live" "$present" "$dead"' EXIT
      add_pin() { [ -n "$1" ] && [ -e "$1" ] && readlink -f "$1" >> "$pinned"; return 0; }
      add_pin "$prof/system"
      add_pin "$(P /run/booted-system)"
      add_pin "$(P /run/current-system)"
      #
      # THE DEFAULT ENTRY OF EACH FILE, and only it. Both configs list every
      # generation the boot menu names; what each one BOOTS is its DEFAULT.
      # Pinning the first `init=` in the file instead would pin whichever
      # generation the builder happened to emit first and leave the fallback's
      # own generation collectable -- which is precisely the one that gets used
      # when the default does not work.
      #
      # A file that yields nothing is a file we do not understand, and an
      # unreadable pin is not the same as an absent one: refuse rather than
      # collect. (The same rule the /boot collector this replaced got wrong: a
      # broken keep-list read as "keep nothing".)
      for c in extlinux.conf extlinux-fallback.conf; do
        f="$(P /boot/extlinux)/$c"
        [ -r "$f" ] || continue
        t=$(conf_default_toplevel "$f")
        [ -n "$t" ] \
          || die "$f names no generation on its DEFAULT entry -- refusing to collect anything"
        add_pin "$(P "$t")"
      done

      # ---- generations ----------------------------------------------------
      gens=$(find "$prof" -mindepth 1 -maxdepth 1 -name 'system-*-link' -printf '%f\n' 2>/dev/null \
             | sed 's|^system-||; s|-link$||' | grep -E '^[0-9]+$' | sort -n || true)
      [ -n "$gens" ] || die "no generations in $prof"
      total=$(printf '%s\n' "$gens" | wc -l)
      keepgens=$(printf '%s\n' "$gens" | tail -n "$KEEP")

      keeptops=""
      droptops=""
      for g in $gens; do
        t=$(readlink -f "$prof/system-$g-link")
        if printf '%s\n' "$keepgens" | grep -qx "$g" || grep -qxF "$t" "$pinned"; then
          keeptops="$keeptops $t"
        else
          droptops="$droptops $t"
          echo "gc: dropping generation $g ($t)"
          [ "$DRYRUN" = 1 ] || rm -f "$prof/system-$g-link"
        fi
      done
      echo "gc: $total generations, keeping $(printf '%s\n' "$keepgens" | tr '\n' ' ')plus pinned"

      # ---- the live set ---------------------------------------------------
      # THE REFUSAL IS THE SAFETY PROPERTY. Without nix there is no way to
      # recompute a generation's closure, so a kept generation with no recorded
      # closure means the live set is unknown -- and an unknown live set makes
      # every deletion a guess. Do nothing at all in that case; a store that is
      # too full is recoverable, a store missing one path is a bench trip.
      live="$(mktemp)"
      for t in $keeptops; do
        f="$closures/$(basename "$t").txt"
        [ -r "$f" ] || die "no closure list for kept generation $t ($f) -- refusing to collect anything"
        cat "$f" >> "$live"
      done
      sort -u -o "$live" "$live"
      echo "gc: live set is $(wc -l < "$live") store paths"

      present="$(mktemp)"
      find "$store" -mindepth 1 -maxdepth 1 ! -name '.*' -printf '/nix/store/%f\n' | sort > "$present"
      dead="$(mktemp)"
      comm -13 "$live" "$present" > "$dead"
      n=$(wc -l < "$dead")
      echo "gc: $(wc -l < "$present") present, $n collectable"

      if [ "$n" -gt 0 ] && [ "$DRYRUN" = 0 ]; then
        store_rw
        while read -r p; do
          [ -n "$p" ] || continue
          d="$store/''${p#/nix/store/}"
          chmod -R u+w "$d" 2>/dev/null || true
          rm -rf "$d"
        done < "$dead"
        sync
        store_ro
      fi

      # Closure records for generations that no longer exist.
      if [ -d "$closures" ]; then
        for f in "$closures"/*.txt; do
          [ -e "$f" ] || continue
          b=$(basename "$f" .txt)
          [ -e "$store/$b" ] && continue
          [ "$DRYRUN" = 1 ] || rm -f "$f"
        done
      fi

      echo "gc: done"
    '';
  };
in
{ inherit updater gc; }
