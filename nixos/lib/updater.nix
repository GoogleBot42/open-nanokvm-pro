{ pkgs
, lib ? pkgs.lib
, nix ? pkgs.nix # the nix the appliance runs; must be the same package
, stableUrl # release base URL: <base>/<manifestName>
, previewUrl # the rolling preview channel's base URL
, manifestName ? "nanokvm_pro_sys_latest.json"
, # The binary cache the release closure is substituted from (#96). Empty means
  # this system cannot update itself and says so; nixos/appliance.nix warns at
  # build time rather than shipping a device that finds out at 03:00.
  cacheUrl ? ""
, # The keys a NAR must be signed by. THE DEVICE'S OWN TRUST, not the
  # manifest's: a release names a store path, never a key.
  trustedPublicKeys ? [ ]
, keepGenerations ? 3
, stateDir ? "/var/lib/nanokvm"
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
# `nanokvm-update` -- the appliance's whole update mechanism (#100).
#
# WHAT AN UPDATE IS HERE. This is a NixOS system and nix is on the device, so
# an update is what an update is on any NixOS machine: put the new system's
# closure in the store, make it the system profile, and run its
# switch-to-configuration. The only thing that is ours is WHERE the closure
# comes from and WHEN the reboot happens.
#
#   1. the manifest    a tagged release publishes {version, toplevel} at a
#                      fixed URL; the channel is the base URL.
#   2. nix copy        substitutes that toplevel's closure from our binary
#                      cache, verifying every NAR against the keys THIS SYSTEM
#                      was built with. Whatever the device already has is not
#                      downloaded -- which is the whole reason this replaced
#                      the 460 MB tar bundle it used to be (#86).
#   3. nix-env --set   the new toplevel becomes generation N+1 of
#                      /nix/var/nix/profiles/system.
#   4. switch-to-configuration boot
#                      NixOS's own activation, in `boot` mode: the bootloader
#                      is written, nothing running is touched.
#
# Every one of those four is an official tool doing the thing it is for. There
# is no bundle format, no closure list, no hand-rolled collector and no
# hand-rolled store surgery any more; docs/updates.md has the history.
#
# THE REBOOT IS THE POINT, not an afterthought. `boot`, never `switch`: nothing
# about the new generation is live until the board restarts, the restart is
# counted by U-Boot's `bootcount`, and `nanokvm-mark-good` clears that counter
# only once the NEW system is running, routed and serving. A generation that
# does not come up healthy is rolled back by `altbootcmd` on the fourth attempt
# with nobody watching -- the only rollback story a box with no console can
# have. `switch` would activate an untested userspace with no way back, and is
# never used.
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
# `nanokvm.update.auto`: a NixOS default the UI can override has to be stored
# tri-state and shipped into the server as well, and the flake would still read
# `auto = false` on a device that had been updating itself for months. One
# file, one truth, and the user owns it.
#
# WHERE THE TRUST IS. `nix copy` runs with `require-sigs = true` and an
# EXPLICIT `trusted-public-keys` -- the keys this system was built with, passed
# on the command line, not read from /etc/nix/nix.conf. So the gate between the
# network and this board's root filesystem is an ed25519 signature over each
# NAR, made by the key that signed the release; a cache that is compromised,
# mirrored, or simply wrong serves paths this device refuses. That is strictly
# more than the tar bundle had (a SHA-512 out of our own manifest, i.e.
# integrity only), and it is the whole of #31 for the appliance. The manifest
# itself is still only TLS-authenticated -- but all it can say is "install
# store path X", and a path nobody trusted signed does not install.
#
# TWO CALLERS, ONE IMPLEMENTATION. The web UI's "update" button reaches this
# through the server's install() override (pkgs/nanokvm-server/
# install-update.go.in), which runs `install-now`; the systemd timer runs
# `update`. Both end up in `install_toplevel`.
#
# --root EXISTS FOR THE OFFLINE TEST. Every path this script touches is
# prefixed and every nix invocation takes `--store local?root=...`, so
# `nix flake check`'s `nanokvm-updater-loop` runs the REAL substitution, the
# REAL signature check, the REAL profile switch and the REAL collector against
# a chroot store inside a build sandbox. That check is the only reason any of
# this is provable before it meets hardware.
#
# WHAT IS DELIBERATELY NOT HERE:
#
#   * No /boot writing. The kernel, initrd and dtb belong to the generation and
#     reach /boot through NixOS's own bootloader builder, which
#     `switch-to-configuration boot` runs (#99). Nothing in this file knows
#     what a kernel is.
#   * No closure bookkeeping. `nix-collect-garbage` knows what is reachable;
#     the only thing we tell it is which generations must survive.
#   * No delta transport. `nix copy` is already a delta: it asks the
#     destination store what it is missing and copies exactly that.
# ===========================================================================

let
  # Everything the scripts shell out to. `busybox` last, so the real tools win
  # and only `devmem` comes from it.
  tools = with pkgs; [
    coreutils gnused gnugrep findutils curl jq util-linux systemd busybox
  ] ++ [ nix ];

  keys = lib.concatStringsSep " " trustedPublicKeys;

  usageText = ''
    usage: nanokvm-update [OPTIONS] <command>

      check                    what is installed, and what the channel offers
      update                   check, install, reboot when idle (what the timer
                               runs; a no-op unless the "Automatic updates" box
                               is ticked in the web UI)
      install-now              install what the channel offers, right now,
                               whatever the checkbox says (the web UI button)
      install-manifest <file>  install the release named by a manifest on disk
      install-toplevel <path> [version]
                               install one store path as the next generation
      pending                  the installed-but-not-yet-booted update, if any
      reboot-if-idle           reboot into a pending update if nobody is using
                               the device (what nanokvm-update-reboot runs)
      gc                       delete old generations and collect the store
      status                   generations, boot configs, store health

    options:
      --root DIR       operate on a fake root (the offline check)
      --cache URL      substitute from this binary cache instead of the
                       configured one
      --trusted-key K  require this key instead of the configured ones
      --keep N         generations to keep (gc)
      --no-activate    do not run switch-to-configuration
      --no-reboot      install, never reboot

    ONLY TAGGED RELEASES ARE EVER INSTALLED. Both channels are GitHub releases
    cut from a vX.Y.Z tag -- stable is releases/latest/download, which never
    serves a prerelease, and preview is the rolling "preview" release, which
    only a tag-triggered run refreshes. Nothing publishes from a branch, so no
    device can be offered the tip of main.

    The manifest a release publishes is built by "nix build .#system-manifest";
    see docs/updates.md.
  '';

  # Shared preamble: option parsing and the path helpers, so the two scripts
  # cannot disagree about where anything lives.
  common = ''
    ROOT=""
    say() { printf 'nanokvm-update: %s\n' "$*"; }
    die() { printf 'nanokvm-update: %s\n' "$*" >&2; exit 1; }

    # /nix/store is a read-only BIND mount on some layouts, and `remount,ro`
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

    # WHICH STORE EVERY NIX COMMAND TALKS TO. On the device: `auto`, which is
    # the local store (this appliance runs nix single-user -- see
    # nixos/appliance.nix). Under --root: a chroot store, which is a real
    # store with its own db, so the offline check exercises the same code
    # paths rather than a simulation of them.
    store_uri() {
      if [ -n "$ROOT" ]; then printf 'local?root=%s' "$ROOT"; else printf 'auto'; fi
    }

    # WHICH GENERATION AN EXTLINUX CONFIG ACTUALLY BOOTS (#99).
    #
    # NixOS's builder writes one LABEL per generation and a single top-level
    # DEFAULT that selects among them, so "the `init=` in this file" is no
    # longer a question with one answer -- there are several, and only one of
    # them is live. Reading the first would pin the wrong generation, and for
    # `gc` that means deleting the one the ROLLBACK depends on.
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
    # (nixos/lib/update-idle-test.nix) reads /run/nanokvm-reboot-requested back
    # out of its fake root. A PATH stub could not do this --
    # writeShellApplication puts its own systemd first on PATH -- and a build
    # sandbox is no place to find out.
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
      CACHE='${cacheUrl}'
      KEYS='${keys}'
      KEEP=${toString keepGenerations}
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

      # The two fields an update needs, and the refusal that keeps a malformed
      # or hostile manifest from reaching `nix copy`: a toplevel is a store
      # path, spelled exactly the way the store spells one.
      manifest_toplevel() {
        local top
        top=$(printf '%s' "$1" | jq -r '.toplevel // empty')
        [ -n "$top" ] || die "the manifest names no toplevel -- is this a $MANIFEST from a release?"
        case "$top" in
          /nix/store/*) ;;
          *) die "the manifest's toplevel is not a store path: $top" ;;
        esac
        printf '%s' "$top"
      }

      # ---- installing a generation ----------------------------------------
      # THE SEAM. Everything above is transport (which URL, which version) and
      # everything below `STAGED_*` is policy (the pending markers and the
      # idle-gated reboot). This function is the whole of the install, and it
      # is four official commands in a row.
      STAGED_VERSION=""
      STAGED_TOPLEVEL=""

      install_toplevel() {
        local top="$1" ver="''${2:-}"
        local store; store=$(store_uri)

        case "$top" in
          /nix/store/*) ;;
          *) die "not a store path: $top" ;;
        esac

        # --- 1. the closure ------------------------------------------------
        # `nix copy` asks the destination what it is missing and fetches
        # exactly that, so an update that changes one package downloads one
        # package. require-sigs + an explicit key list is the gate: an
        # unsigned or differently-signed NAR does not land, and nothing is
        # half-installed when it is refused (nix stages each path and renames
        # it into place).
        # "Already here" means VALID IN THE DATABASE, not present on disk. A
        # directory nix does not know about is not a store path: `nix-env
        # --set` on one tries to download it, which on this device means
        # substituting the system it is already running.
        if nix path-info --extra-experimental-features nix-command \
             --store "$store" "$top" >/dev/null 2>&1; then
          say "$top is already in the store"
        else
          [ -n "$CACHE" ] || die "no binary cache configured -- set nanokvm.update.cacheUrl"
          [ -n "$KEYS" ] || die "no trusted public keys configured -- set nanokvm.update.trustedPublicKeys"
          say "substituting $top from $CACHE"
          store_rw
          nix copy \
            --extra-experimental-features nix-command \
            --from "$CACHE" --to "$store" \
            --option require-sigs true \
            --option trusted-public-keys "$KEYS" \
            "$top" || { store_ro; die "could not substitute $top from $CACHE"; }
          store_ro
          nix path-info --extra-experimental-features nix-command \
            --store "$store" "$top" >/dev/null \
            || die "$top is not valid in the store after nix copy"
        fi

        # --- 2. the system profile -----------------------------------------
        # `nix-env --set` is what makes a generation: it creates
        # system-<N>-link, points `system` at it, and leaves the old ones
        # where the rollback can still find them.
        #
        # BEFORE THE ACTIVATION, and that order is load-bearing: NixOS's
        # extlinux builder writes one LABEL per profile generation, so a
        # generation that is not in the profile yet is a generation the boot
        # menu does not name. `nixos-rebuild` does the same two steps in the
        # same order. If step 3 then fails, the profile points at the new
        # generation and /boot still names the old one -- which is the safe
        # way round, because /boot is what U-Boot reads and every entry pins
        # its own `init=`.
        say "making $top generation $(next_generation) of the system profile"
        nix-env --store "$store" \
          -p "$(P /nix/var/nix/profiles/system)" --set "$top" \
          || die "nix-env could not set the system profile to $top"
        sync

        # --- 3. activation, in `boot` mode ---------------------------------
        # NixOS's own switch-to-configuration: it writes the bootloader (which
        # on this board is the extlinux config, the kernel, the initrd and the
        # dtb -- all of them part of the generation since #99) and touches
        # nothing that is running. The reboot is what makes any of it live.
        if [ "$ACTIVATE" = 1 ]; then
          say "switch-to-configuration boot"
          "$(P "$top")/bin/switch-to-configuration" boot \
            || die "switch-to-configuration boot failed -- the profile points at $top but the bootloader does not"
        else
          say "not activating (--no-activate): the bootloader still names the old generation"
        fi
        sync

        STAGED_TOPLEVEL="$top"
        STAGED_VERSION="$ver"
        if [ -z "$STAGED_VERSION" ]; then
          STAGED_VERSION=$(tr -d '[:space:]' < "$(P "$top")/etc/nanokvm-version" 2>/dev/null || echo "unknown")
        fi

        say "installed. The reboot is what proves it: U-Boot counts the attempt"
        say "and nanokvm-mark-good clears the counter only once this system is"
        say "running, routed and serving. Three bad attempts roll it back."
      }

      # Fetch the manifest of the selected channel and install what it names.
      # `force` = install even if the version matches (the web UI's button,
      # which a human pressed).
      install_from_channel() {
        local force="$1" mf av top cur
        cur=$(current_version)
        mf=$(fetch_manifest) || die "could not reach $(base_url)/$MANIFEST"
        av=$(printf '%s' "$mf" | jq -r '.version')
        top=$(manifest_toplevel "$mf")
        if [ "$cur" = "$av" ] && [ "$force" != 1 ]; then
          say "already on $cur"
          return 1
        fi
        # A string compare, not semver: the appliance takes what the channel
        # offers, because "the channel" is a release we cut. Downgrades are a
        # deliberate operation (point the URL at an older release), and the
        # rollback that catches a bad one is the boot counter, not a version
        # test here.
        say "updating $cur -> $av"
        install_toplevel "$top" "$av"
        mark_pending "$STAGED_VERSION" "$STAGED_TOPLEVEL" "$cur"
        return 0
      }

      next_generation() {
        local prof n max=0
        prof="$(P /nix/var/nix/profiles)"
        for l in "$prof"/system-*-link; do
          [ -e "$l" ] || continue
          n=$(basename "$l"); n=''${n#system-}; n=''${n%-link}
          case "$n" in (*[!0-9]*) continue ;; esac
          if [ "$n" -gt "$max" ]; then max=$n; fi
        done
        echo $((max + 1))
      }

      # Every generation something other than the profile depends on. The
      # FALLBACK is the one that matters: it is what gets used precisely when
      # the default does not work, and it is named by a file in /boot rather
      # than by a profile link, so nothing in nix knows about it unless we say
      # so.
      #
      # THE DEFAULT ENTRY OF EACH FILE, AND ONLY IT (#99). Since NixOS's own
      # extlinux builder took over /boot, both configs list every generation
      # the menu names; what each one BOOTS is its DEFAULT. Pinning every
      # `init=` in the file would pin the whole menu and collect nothing ever;
      # pinning the first would pin whichever the builder emitted first and
      # leave the fallback's own generation collectable -- precisely the one
      # that gets used when the default does not work.
      #
      # A file that yields nothing is a file we do not understand, and an
      # unreadable pin is not the same as an absent one: `gc` refuses rather
      # than collects.
      #
      # LOGICAL store paths, always: a gc root must name /nix/store/<x> even
      # when --root has the store somewhere else, because that is what the
      # store it belongs to calls it.
      pinned_toplevels() {
        local f l t
        for l in "$(P /run/booted-system)" "$(P /run/current-system)" \
                 "$(P /nix/var/nix/profiles/system)"; do
          [ -e "$l" ] || continue
          t=$(readlink -f "$l")
          printf '%s\n' "''${t#"$ROOT"}"
        done
        for f in "$(P /boot/extlinux)"/*.conf; do
          [ -r "$f" ] || continue
          t=$(conf_default_toplevel "$f")
          [ -n "$t" ] \
            || die "$f names no generation on its DEFAULT entry -- refusing to collect anything"
          printf '%s\n' "$t"
        done
      }

      # ---- commands -------------------------------------------------------
      cmd=""
      args=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --root)        ROOT="''${2%/}"; shift 2 ;;
          --cache)       CACHE="$2"; shift 2 ;;
          --trusted-key) KEYS="$2"; shift 2 ;;
          --keep)        KEEP="$2"; shift 2 ;;
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
        echo "available: $av"
        echo "toplevel:  $(printf '%s' "$mf" | jq -r '.toplevel // "(none)"')"
        echo "channel:   $(base_url)"
        echo "cache:     ''${CACHE:-(none configured)}"
        [ "$cur" != "$av" ] || echo "up to date"
        ;;

      update)
        # THE CHECKBOX IS THE SWITCH. The timer runs whenever
        # `nanokvm.update.enable` is set -- there is no unit-level gate -- so
        # this file is what decides whether anything happens, and the web UI's
        # "Automatic updates" toggle is what writes it. Exit 0, because a
        # device whose owner has not asked for updates is not a failed update.
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
        # writing a new bootloader config before that would replace the very
        # thing the counter is counting, and the rollback would then land on a
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

        install_from_channel 0 || exit 0
        # From here down is policy, and it did not move when the transport did.
        [ "$REBOOT" = 1 ] || exit 0
        ${lib.optionalString (!rebootImmediately) ''
        say "a reboot window is configured, so this install does not reboot."
        say "nanokvm-update-reboot takes $STAGED_VERSION inside the window, once idle."
        exit 0
        ''}
        reboot_if_idle "$STAGED_VERSION"
        ;;

      # The web UI's path: a human pressed the button, so no checkbox and no
      # idle gate -- but the markers are still written, because the note is
      # what lets the page say what happened on the other side of the restart.
      # The server reboots the device itself afterwards.
      install-now)
        install_from_channel 1 || exit 0
        ;;

      # A manifest from disk: the offline check's entry point, and the way to
      # install a release by hand on a device whose channel is unreachable.
      install-manifest)
        mf=$(cat "''${1:?usage: nanokvm-update install-manifest <manifest.json>}")
        cur=$(current_version)
        av=$(printf '%s' "$mf" | jq -r '.version')
        install_toplevel "$(manifest_toplevel "$mf")" "$av"
        mark_pending "$STAGED_VERSION" "$STAGED_TOPLEVEL" "$cur"
        ;;

      # The lowest level: one store path, straight in. Recovery, and the thing
      # a developer reaches for after `nix copy --to ssh://` from a build host.
      install-toplevel)
        cur=$(current_version)
        install_toplevel "''${1:?usage: nanokvm-update install-toplevel <store path> [version]}" "''${2:-}"
        mark_pending "$STAGED_VERSION" "$STAGED_TOPLEVEL" "$cur"
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

      # ---- the collector --------------------------------------------------
      # `nix-collect-garbage` decides what is reachable; all we do is tell it
      # what must stay reachable. TWO STEPS, AND THE ORDER IS THE SAFETY
      # PROPERTY:
      #
      #   1. pin, as GC ROOTS, every generation a boot config names -- above
      #      all the FALLBACK, which no profile link and no /run symlink
      #      protects, and which is exactly what the board needs on the one
      #      boot where the default generation does not work.
      #   2. THEN delete the old generation links and collect.
      #
      # A pin that is written after the collection is a pin that was not there
      # when it mattered. The roots live in /nix/var/nix/gcroots/nanokvm and
      # are rewritten from scratch every run, so a generation that stops being
      # named stops being pinned.
      gc)
        prof="$(P /nix/var/nix/profiles)"
        roots="$(P /nix/var/nix/gcroots/nanokvm)"
        store=$(store_uri)
        [ -d "$prof" ] || die "no $prof"

        mkdir -p "$roots"
        rm -f "$roots"/*
        i=0
        pinned="$(mktemp)"
        trap 'rm -f "$pinned" "$pinned.raw"' EXIT
        # NOT `pinned_toplevels | sort`: `die` inside a function that runs in a
        # pipeline exits the SUBSHELL, and the pipeline's status is sort's. The
        # refusal would print and the collection would carry on with a short
        # keep-list -- the #86 collector's exact bug. A plain redirect runs the
        # function in this shell, where `die` is fatal.
        pinned_toplevels > "$pinned.raw"
        sort -u "$pinned.raw" > "$pinned"
        [ -s "$pinned" ] || die "nothing is pinned -- refusing to collect anything"
        # A PIN THAT IS NOT A VALID STORE PATH PROTECTS NOTHING, and the gc
        # root that names it is not a root -- it is a dangling symlink nix
        # ignores while it deletes the very closure the rollback needs.
        # Measured: a directory present on disk but absent from the database is
        # collected even with a gcroot pointing at it.
        #
        # That is not a hypothetical on this board. Generations 1-4 were
        # unpacked by tar before the appliance had nix (the bootstrap recipe in
        # the kvm-device skill), so they are on disk and unregistered until
        # someone loads their registration. If `extlinux-fallback.conf` still
        # names one of those, the correct action is to REFUSE -- loudly, naming
        # the path and the fix -- and delete nothing at all.
        while read -r t; do
          [ -n "$t" ] || continue
          [ -e "$(P "$t")" ] \
            || die "$t is named by a boot config and is not in the store at all -- refusing to collect anything"
          nix path-info --extra-experimental-features nix-command \
            --store "$store" "$t" >/dev/null 2>&1 \
            || die "$t is named by a boot config but is NOT VALID in the store database.
A gc root cannot protect it and nix would collect it, taking the generation the
rollback boots. Register it first -- on the build host:
  nix-store --dump-db \$(nix-store -qR $t) > reg
and on the device:
  nix-store --load-db < reg && nix-store --verify --check-contents
Refusing to collect anything."
          i=$((i + 1))
          ln -sfn "$t" "$roots/pin-$i"
          echo "gc: pinned $t"
        done < "$pinned"
        say "$i generations pinned as gc roots"
        [ "$i" -gt 0 ] || die "no pinned generation is in the store -- refusing to collect anything"

        # Which generation links may go: everything but the newest $KEEP, and
        # never one whose toplevel is pinned (it would still survive as a
        # store path, but a rollback is easier to reason about when the
        # generation is still in the profile).
        gens=$(find "$prof" -mindepth 1 -maxdepth 1 -name 'system-*-link' -printf '%f\n' 2>/dev/null \
               | sed 's|^system-||; s|-link$||' | grep -E '^[0-9]+$' | sort -n || true)
        [ -n "$gens" ] || die "no generations in $prof"
        keepgens=$(printf '%s\n' "$gens" | tail -n "$KEEP")
        doomed=""
        for g in $gens; do
          t=$(readlink -f "$prof/system-$g-link" 2>/dev/null || echo "")
          if printf '%s\n' "$keepgens" | grep -qx "$g"; then continue; fi
          if [ -n "$t" ] && grep -qxF "''${t#"$ROOT"}" "$pinned"; then
            echo "gc: keeping generation $g -- a boot config names it"
            continue
          fi
          doomed="$doomed $g"
        done
        if [ -n "$doomed" ]; then
          echo "gc: deleting generations$doomed"
          # shellcheck disable=SC2086
          nix-env --store "$store" -p "$prof/system" --delete-generations $doomed
        else
          echo "gc: no generation is old enough to delete (keeping $KEEP)"
        fi

        nix-collect-garbage --store "$store"
        echo "gc: done"
        ;;

      status)
        echo "installed version : $(current_version)"
        echo "automatic updates : $(if auto_updates_enabled; then echo "on ($AUTO_FLAG)"; else echo "off"; fi)"
        if [ -e "$(P "$PENDING")" ]; then
          echo "reboot pending    : $(note_field "$(P "$PENDING")" VERSION), waiting for an idle moment"
        fi
        echo "channel           : $(base_url)"
        echo "cache             : ''${CACHE:-(none configured)}"
        echo "booted system     : $(readlink -f "$(P /run/booted-system)" 2>/dev/null || echo '?')"
        echo "current system    : $(readlink -f "$(P /run/current-system)" 2>/dev/null || echo '?')"
        echo "profile           : $(readlink -f "$(P /nix/var/nix/profiles/system)" 2>/dev/null || echo '?')"
        echo "generations       : $(find "$(P /nix/var/nix/profiles)" -maxdepth 1 -name "system-*-link" 2>/dev/null | wc -l)"
        echo "pinned            :"
        pinned_toplevels | sort -u | sed 's/^/  /'
        for c in "$(P /boot/extlinux)"/*.conf; do
          [ -r "$c" ] || continue
          echo "$(basename "$c"): DEFAULT $(sed -n 's|^DEFAULT[[:space:]]*||p' "$c" | head -1) -> $(conf_default_toplevel "$c")"
        done
        ;;

      *) usage ;;
      esac
    '';
  };
in
{ inherit updater; }
