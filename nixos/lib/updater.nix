{ pkgs
, lib ? pkgs.lib
, stableUrl # release base URL: <base>/<manifestName>, <base>/<payload>
, previewUrl # the rolling preview channel's base URL
, manifestName ? "nanokvm_pro_sys_latest.json"
, keepGenerations ? 3
, stateDir ? "/var/lib/nanokvm"
, cacheDir ? "/var/cache/nanokvm-update"
, # The web UI's "Automatic updates" checkbox, as a flag file beside the
  # "preview updates" one. THE CHECKBOX IS THE STATE -- there is no NixOS
  # option behind it (see the header).
  autoFlag ? "/etc/kvm/auto_updates"
, # Where the server answers "is anybody using this box". Empty = no server on
  # this system, which is then treated as idle.
  idleUrl ? "https://127.0.0.1/api/update/idle"
, # How long the last web/API activity must be in the past before the device
  # counts as unused.
  idleQuietSec ? 600
, # false when `nanokvm.update.rebootWindow` is set: the install may happen at
  # any hour but the reboot only inside the window, so `update` never reboots
  # itself and always leaves the decision to `nanokvm-update-reboot`.
  rebootImmediately ? true
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
# BUT THE REBOOT WAITS FOR AN EMPTY ROOM. A KVM is the machine you are using to
# fix the machine, so a reboot in the middle of someone's console session is
# the one failure mode an update must not have. `update` therefore INSTALLS
# immediately and reboots only if the server says nobody is connected --
# otherwise it leaves `/run/nanokvm-update-pending` and exits 0, and
# `nanokvm-update-reboot` (a second timer) asks the same question every ten
# minutes until the answer is yes. The web UI shows the pending state and a
# "restart now" button, because the person looking at that page is usually the
# person the wait is for.
#
# THE SWITCH IS A CHECKBOX, NOT AN OPTION. `update` does nothing at all unless
# /etc/kvm/auto_updates exists -- the file the web UI's "Automatic updates"
# toggle writes, beside the "preview updates" one it already wrote. There is no
# `nanokvm.update.auto` any more: a NixOS default the UI can override has to be
# stored tri-state and shipped into the server as well, and the flake would
# still read `auto = false` on a device that had been updating itself for
# months. One file, one truth, and the user owns it.
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
      update                   check, download, install, reboot when idle
                               (what the timer runs; a no-op unless the
                               "Automatic updates" box is ticked in the web UI)
      install <bundle.tar.gz>  verify + unpack + install a bundle from a file
      install-staged <dir> [v] install an already-unpacked bundle (the web UI path)
      pending                  the installed-but-not-yet-booted update, if any
      reboot-if-idle           reboot into a pending update if nobody is using
                               the device (what nanokvm-update-reboot runs)
      gc                       drop old generations and the store paths only they used
      status                   generations, both boot configs, /boot usage

    ONLY TAGGED RELEASES ARE EVER INSTALLED. Both channels are GitHub releases
    cut from a vX.Y.Z tag -- stable is releases/latest/download, which never
    serves a prerelease, and preview is the rolling "preview" release, which
    only a tag-triggered run refreshes. Nothing publishes from a branch, so no
    device can be offered the tip of main.

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

  # ---- the idle gate and the pending marker ------------------------------
  # Shared verbatim by `nanokvm-update` and `nanokvm-update-reboot`, because
  # the two have to agree exactly about what "pending" and "idle" mean -- one
  # writes the marker the other consumes, and a disagreement is either a reboot
  # nobody asked for or a board that never takes its update.
  pending = ''
    AUTO_FLAG='${autoFlag}'
    PENDING=/run/nanokvm-update-pending
    NOTE='${stateDir}/update-pending'
    IDLE_URL='${idleUrl}'
    IDLE_QUIET=${toString idleQuietSec}

    current_version() {
      for f in "$(P /run/current-system)/etc/nanokvm-version" \
               "$(P /etc/nanokvm-version)"; do
        if [ -r "$f" ]; then tr -d '[:space:]' < "$f"; return 0; fi
      done
      echo "0.0.0-unknown"
    }

    # The checkbox. Presence is the whole state, exactly as for
    # /etc/kvm/preview_updates, so the server and this tool cannot disagree.
    auto_updates_enabled() { [ -e "$(P "$AUTO_FLAG")" ]; }

    # IS ANYBODY USING THIS BOX? Only the server knows: it holds every stream
    # consumer, every HID and terminal websocket, the mini-display's preview
    # lease and the timestamp of the last authenticated API call. So ask it,
    # over the same loopback route nanokvm-mark-good already proves reachable.
    #
    # A SERVER THAT DOES NOT ANSWER IS NOT IDLE. An unanswered question must
    # never become a reboot: if curl fails, if the JSON is not what we expect,
    # if `idle` is anything but true, the device is busy. The one exception is
    # a system built without the server at all, where there is nothing that
    # could be using it -- that is IDLE_URL empty, decided at build time.
    device_idle() {
      if [ -z "$IDLE_URL" ]; then
        say "no server on this system -- nothing can be using it"
        return 0
      fi
      local body verdict
      if ! body=$(curl -sk -m 10 "$IDLE_URL?quiet=$IDLE_QUIET" 2>/dev/null); then
        say "the server did not answer $IDLE_URL -- treating the device as BUSY"
        return 1
      fi
      verdict=$(printf '%s' "$body" | jq -r '.data.idle' 2>/dev/null || echo "")
      case "$verdict" in
        true)  say "idle: $(printf '%s' "$body" | jq -rc '.data' 2>/dev/null)"; return 0 ;;
        false) say "in use: $(printf '%s' "$body" | jq -rc '.data' 2>/dev/null)"; return 1 ;;
        *)     say "unparseable idle report from the server -- treating the device as BUSY"
               return 1 ;;
      esac
    }

    # TWO MARKERS, AND THEY ANSWER DIFFERENT QUESTIONS.
    #   /run/...            "a reboot is owed" -- tmpfs, so the reboot itself
    #                       is what clears it, which is the only clearing that
    #                       cannot be wrong.
    #   /var/lib/nanokvm/   "an update was installed" -- survives the reboot so
    #                       the UI can say what happened, and is settled on the
    #                       next `reboot-if-idle` by comparing versions.
    mark_pending() {
      local v="$1" top="$2" from="$3"
      mkdir -p "$(P "$(dirname "$NOTE")")"
      printf 'VERSION=%s\nFROM=%s\nTOPLEVEL=%s\nUPTIME=%s\n' \
        "$v" "$from" "$top" "$(cut -d. -f1 "$(P /proc/uptime)" 2>/dev/null || echo 0)" \
        > "$(P "$NOTE").new"
      mv -f "$(P "$NOTE").new" "$(P "$NOTE")"
      mkdir -p "$(P /run)"
      cp "$(P "$NOTE")" "$(P "$PENDING")"
      sync
    }

    note_field() { sed -n "s/^$2=//p" "$1" | head -1; }

    # THE ONE PLACE A REBOOT IS DECIDED. Idle -> go; in use -> say who, leave
    # the marker, exit 0. Exit 0 both ways on purpose: "someone is using the
    # KVM" is the system working, not a failed unit, and a systemd failure
    # counter climbing every ten minutes while a colleague is on the console
    # would be pure noise.
    #
    # Under --root the reboot is RECORDED, not taken: the offline check
    # (nixos/lib/updater-test.nix) reads /run/nanokvm-reboot-requested back out
    # of its fake root. A PATH stub could not do this -- writeShellApplication
    # puts its own systemd first on PATH -- and a build sandbox is no place to
    # find out.
    do_reboot() {
      if [ -n "$ROOT" ]; then
        mkdir -p "$(P /run)"
        printf 'reboot requested\n' > "$(P /run/nanokvm-reboot-requested)"
        say "--root: recorded the reboot request instead of taking it"
        return 0
      fi
      systemctl --no-block reboot
    }

    reboot_if_idle() {
      local v="$1"
      if device_idle; then
        say "nobody is using this device -- rebooting into $v"
        do_reboot
      else
        say "$v is installed and the reboot is pending; the device is in use."
        say "nanokvm-update-reboot will take it as soon as the room is empty,"
        say "and the web UI offers a restart button to whoever is there."
      fi
      return 0
    }

    # After the reboot the /run marker is gone and the note is not. Whichever
    # version is running now settles it: the update landed, or the boot counter
    # rolled it back -- and the second is worth a log line, because it is the
    # rollback firing on something we installed.
    settle_note() {
      local f; f="$(P "$NOTE")"
      [ -r "$f" ] || return 0
      [ ! -e "$(P "$PENDING")" ] || return 0
      local want cur; want=$(note_field "$f" VERSION); cur=$(current_version)
      if [ "$want" = "$cur" ]; then
        say "update $want is live"
      else
        say "update $want was installed but $cur is running -- it did not survive"
        say "the boot; the bootcount rollback put the previous generation back."
      fi
      rm -f "$f"
    }
  '';

  updater = pkgs.writeShellApplication {
    name = "nanokvm-update";
    runtimeInputs = tools;
    text = ''
      set -eu
      ${common}
      ${pending}

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
      # THE SEAM (#100). Everything above this function is transport -- fetch a
      # tarball, check a SHA-512, untar it -- and everything below `STAGED_*` is
      # policy: the pending markers and the idle-gated reboot. When the device
      # gets `nix` and the transport becomes `nix copy` from a binary cache,
      # THIS function and the download above it are what is replaced; the
      # markers, the checkbox and the reboot gate do not move. So it reports
      # what it installed through two variables rather than writing the markers
      # itself, and its callers decide what that means.
      STAGED_VERSION=""
      STAGED_TOPLEVEL=""

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

        STAGED_VERSION=$(jq -r '.version' "$mf")
        STAGED_TOPLEVEL="$top"

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
        # THE CHECKBOX IS THE SWITCH (#86). The timer runs whenever
        # `nanokvm.update.enable` is set -- there is no unit-level gate any
        # more -- so this file is what decides whether anything happens, and
        # the web UI's "Automatic updates" toggle is what writes it. Exit 0,
        # because a device whose owner has not asked for updates is not a
        # failed update.
        if ! auto_updates_enabled; then
          say "automatic updates are off (no $AUTO_FLAG) -- nothing to do"
          exit 0
        fi

        # A reboot already owed is a reboot not yet taken: installing a second
        # update on top of the first would leave a generation nothing has ever
        # booted underneath one nobody has booted either.
        if [ -e "$(P "$PENDING")" ]; then
          say "$(note_field "$(P "$PENDING")" VERSION) is installed and waiting for an"
          say "idle moment to reboot -- not installing anything on top of it."
          exit 0
        fi

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
        # From here down is policy, and survives the #100 transport swap.
        mark_pending "$STAGED_VERSION" "$STAGED_TOPLEVEL" "$cur"
        [ "$REBOOT" = 1 ] || exit 0
        ${lib.optionalString (!rebootImmediately) ''
        say "a reboot window is configured, so this install does not reboot."
        say "nanokvm-update-reboot takes $av inside the window, once idle."
        exit 0
        ''}
        reboot_if_idle "$av"
        ;;

      # What `nanokvm-update-reboot` runs every ten minutes (or, when
      # `nanokvm.update.rebootWindow` is set, on that calendar). Two jobs:
      # settle the note left by an update that has already booted, and take the
      # reboot an installed update is still owed as soon as the room empties.
      reboot-if-idle)
        settle_note
        if [ ! -e "$(P "$PENDING")" ]; then
          say "no update is waiting to be booted"
          exit 0
        fi
        v=$(note_field "$(P "$PENDING")" VERSION)
        [ "$REBOOT" = 1 ] || { say "$v is pending; --no-reboot given"; exit 0; }
        reboot_if_idle "$v"
        ;;

      pending)
        if [ -e "$(P "$PENDING")" ]; then
          echo "reboot pending    : $(note_field "$(P "$PENDING")" VERSION) (installed, not yet booted)"
          echo "replacing         : $(note_field "$(P "$PENDING")" FROM)"
        elif [ -r "$(P "$NOTE")" ]; then
          echo "last update       : $(note_field "$(P "$NOTE")" VERSION) (booted; note not settled yet)"
        else
          echo "no pending update"
        fi
        echo "running version   : $(current_version)"
        echo "automatic updates : $(if auto_updates_enabled; then echo on; else echo off; fi)"
        ;;

      install)
        tarball="''${1:?usage: nanokvm-update install <bundle.tar.gz>}"
        cur=$(current_version)
        d="$(P "$CACHE")/unpacked"
        rm -rf "$d"; mkdir -p "$d"
        tar -C "$d" -xzf "$tarball"
        top=$(find "$d" -mindepth 1 -maxdepth 1 -type d | head -1)
        install_staged "$top"
        rm -rf "$d"
        mark_pending "$STAGED_VERSION" "$STAGED_TOPLEVEL" "$cur"
        ;;

      # The web UI's path: the server has already downloaded, verified and
      # untarred the bundle (pkgs/nanokvm-server/install-bundle.go.in) and
      # reboots itself afterwards -- an explicit human action, so no idle gate.
      # The markers are still written, because the note is what lets the page
      # say what happened on the other side of the restart.
      install-staged)
        cur=$(current_version)
        install_staged "''${1:?usage: nanokvm-update install-staged <dir> [version]}"
        mark_pending "$STAGED_VERSION" "$STAGED_TOPLEVEL" "$cur"
        ;;

      gc)
        nanokvm-gc ''${ROOT:+--root "$ROOT"} --keep ${toString keepGenerations}
        ;;

      status)
        echo "installed version : $(current_version)"
        echo "automatic updates : $(if auto_updates_enabled; then echo "on ($AUTO_FLAG)"; else echo "off"; fi)"
        if [ -e "$(P "$PENDING")" ]; then
          echo "reboot pending    : $(note_field "$(P "$PENDING")" VERSION), waiting for an idle moment"
        fi
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
