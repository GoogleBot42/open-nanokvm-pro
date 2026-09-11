{ pkgs
, lib ? pkgs.lib
, ...
}:

# ===========================================================================
# THE OFFLINE PROOF OF "INSTALL NOW, REBOOT WHEN IDLE" (#86, #100).
# `nix flake check`'s `nanokvm-update-idle`.
#
# `nanokvm-updater-loop` proves the install; this proves the policy wrapped
# around it -- the checkbox, the channel, the pending markers, the idle gate
# and the second timer -- with the REAL `nanokvm-update` against a fake root, a
# real chroot store, a real signed binary cache and a fake release host inside
# a build sandbox.
#
# The transport under it changed completely in #100 (a signed closure
# substituted from a cache, instead of a 460 MB tarball) and NOT ONE PHASE OF
# THIS FILE CHANGED SHAPE. That was the design claim of #86's seam, and this is
# where it is cashed: the policy never knew what a bundle was.
#
# TWO STUBS, AND ONLY TWO. A python http.server on loopback plays both the
# release host and the server's idle route (a file whose contents the test
# rewrites between phases), and `--root` makes the updater RECORD its reboot in
# /run/nanokvm-reboot-requested rather than take it. Everything else is the
# code that runs on the board.
#
# What this cannot prove is the other side of the idle route: that the server's
# own answer is right. That is hardware (docs/updates.md).
# ===========================================================================

let
  port = "18731";
  base = "http://127.0.0.1:${port}";

  fixture = import ./update-fixture.nix { inherit pkgs lib; };

  tools = import ./updater.nix {
    inherit pkgs lib;
    stableUrl = base;
    previewUrl = "${base}/preview";
    idleUrl = "${base}/api/update/idle";
    idleQuietSec = 600;
    keepGenerations = 3;
    cacheUrl = "https://example.invalid/cache";
    trustedPublicKeys = [ "nobody:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ];
  };
in
pkgs.runCommand "nanokvm-update-idle"
{
  nativeBuildInputs = [
    tools.updater pkgs.nix
    pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.findutils
    pkgs.curl pkgs.python3
  ];
  inherit (fixture) releaseClosure deviceClosure paths;
  meta.description =
    "Offline proof of the update policy: the auto-updates checkbox, the pending markers and the idle reboot gate";
} ''
  set -euo pipefail
  ${fixture.shellLib}

  fail() { echo "FAIL: $*" >&2; exit 1; }
  ok()   { echo "  ok: $*"; }

  nix_sandbox_setup
  V1=$(sed -n 1p "$paths"); V2=$(sed -n 2p "$paths"); V3=$(sed -n 3p "$paths")
  R="$PWD/root"; SRV="$PWD/srv"; SRC="$PWD/release"; CACHE="$PWD/cache"
  export STC_LOG="$PWD/stc.log"

  # Every invocation carries the throwaway cache and key, because the built-in
  # ones are placeholders until #96 lands (nixos/appliance.nix).
  U() { nanokvm-update --root "$R" --cache "file://$CACHE" \
          --trusted-key "$(cat release.pub)" "$@"; }

  # The three things the test drives.
  idle()   { printf '{"code":0,"msg":"success","data":{"idle":true,"busy":[]}}\n' > "$SRV/api/update/idle"; }
  inuse()  { printf '{"code":0,"msg":"success","data":{"idle":false,"busy":["stream"]}}\n' > "$SRV/api/update/idle"; }
  tick()   { : > "$R/etc/kvm/auto_updates"; }
  untick() { rm -f "$R/etc/kvm/auto_updates"; }
  offer()  { # offer <toplevel> <version>
    jq -n --arg t "$1" --arg v "$2" \
      '{format:"nanokvm-nix-closure/1", version:$v, toplevel:$t, size:4096, closureCount:2}' \
      > "$SRV/nanokvm_pro_sys_latest.json"
  }

  marker="$R/run/nanokvm-update-pending"
  note="$R/var/lib/nanokvm/update-pending"
  rebooted="$R/run/nanokvm-reboot-requested"
  no_reboot() { [ ! -e "$rebooted" ] || fail "$1"; }
  did_reboot() { [ -e "$rebooted" ] || fail "$1"; rm -f "$rebooted"; }

  # =====================================================================
  # The release side and the device, as nixos/lib/updater-test.nix builds
  # them: a signed cache, and a board with one registered generation.
  # =====================================================================
  nix key generate-secret --key-name nanokvm-test-1 > release.key
  nix key convert-secret-to-public < release.key > release.pub
  make_store "$SRC" "$releaseClosure"
  sign_into_cache "$CACHE" "$SRC" "$V2" "$V3"

  make_store "$R" "$deviceClosure"
  mkdir -p "$R/boot/extlinux" "$R/run" "$R/etc/kvm" "$R/var/lib/nanokvm" "$R/proc" \
           "$SRV/api/update"
  ln -s "$V1" "$R/nix/var/nix/profiles/system-1-link"
  ln -s system-1-link "$R/nix/var/nix/profiles/system"
  ln -s "$R$V1" "$R/run/booted-system"
  ln -s "$R$V1" "$R/run/current-system"
  printf 'DEFAULT nixos\nLABEL nixos\n  APPEND init=%s/init\n' "$V1" \
    > "$R/boot/extlinux/extlinux.conf"
  cp "$R/boot/extlinux/extlinux.conf" "$R/boot/extlinux/extlinux-fallback.conf"

  offer "$V2" "9.9.9"
  inuse
  python3 -m http.server --directory "$SRV" --bind 127.0.0.1 ${port} >/dev/null 2>&1 &
  http_pid=$!
  for _ in $(seq 1 50); do
    curl -sf "${base}/nanokvm_pro_sys_latest.json" >/dev/null 2>&1 && break
    sleep 0.2
  done
  curl -sf "${base}/nanokvm_pro_sys_latest.json" >/dev/null \
    || fail "the fake release host never came up on ${base}"
  ok "fake release host + idle route serving on ${base}"

  # =====================================================================
  # A. THE CHECKBOX IS OFF -- nothing happens, and it is not an error.
  # =====================================================================
  echo "=== A. automatic updates unticked ==="
  untick; idle
  U update > "$PWD/a.log" 2>&1 || fail "update exited non-zero with the box unticked"
  grep -q "automatic updates are off" "$PWD/a.log" \
    || { cat "$PWD/a.log" >&2; fail "update did not say why it did nothing"; }
  [ "$(generation "$R")" = "system-1-link" ] \
    || fail "an unticked device installed an update"
  [ ! -e "$marker" ] || fail "an unticked device wrote a pending marker"
  no_reboot "an unticked device asked for a reboot"
  ok "unticked: no install, no marker, no reboot, exit 0"

  # =====================================================================
  # B. TICKED, SOMEBODY IS USING IT -- install, mark, DO NOT reboot.
  # =====================================================================
  echo "=== B. ticked, device in use ==="
  tick; inuse
  U update > "$PWD/b.log" 2>&1 || { cat "$PWD/b.log" >&2; fail "update failed with the box ticked"; }
  [ "$(generation "$R")" = "system-2-link" ] || fail "the update did not install"
  [ "$(system_path "$R")" = "$V2" ] || fail "generation 2 is not the offered toplevel"
  [ -e "$marker" ] || fail "no /run pending marker after an install"
  [ -r "$note" ]   || fail "no persistent note after an install"
  [ "$(sed -n 's/^VERSION=//p' "$marker")" = "9.9.9" ] \
    || fail "the marker does not name the installed version"
  [ "$(sed -n 's/^FROM=//p' "$marker")" = "1.0.0" ] \
    || fail "the marker does not name the version it replaced"
  no_reboot "the device rebooted while somebody was using it"
  grep -q "the reboot is pending" "$PWD/b.log" \
    || { cat "$PWD/b.log" >&2; fail "update did not report the deferred reboot"; }
  ok "in use: installed, both markers written, NO reboot"

  # =====================================================================
  # C. A SECOND UPDATE MUST NOT STACK ON AN UNBOOTED ONE.
  # =====================================================================
  echo "=== C. update with a reboot already owed ==="
  offer "$V3" "9.9.10"
  U update > "$PWD/c.log" 2>&1 || fail "update failed with a marker present"
  grep -q "not installing anything on top of it" "$PWD/c.log" \
    || { cat "$PWD/c.log" >&2; fail "update stacked on a pending reboot"; }
  [ "$(generation "$R")" = "system-2-link" ] \
    || fail "a third generation was installed on top of a pending one"
  ok "refused, and said so"
  offer "$V2" "9.9.9"

  # =====================================================================
  # D. THE REBOOT TIMER, STILL IN USE -- marker survives, no reboot.
  # =====================================================================
  echo "=== D. reboot-if-idle while in use ==="
  U reboot-if-idle > "$PWD/d.log" 2>&1 || fail "reboot-if-idle exited non-zero"
  no_reboot "reboot-if-idle rebooted a device in use"
  [ -e "$marker" ] || fail "reboot-if-idle dropped the pending marker"
  ok "still pending, still no reboot"

  # =====================================================================
  # E. THE ROOM EMPTIES -- the reboot is taken.
  # =====================================================================
  echo "=== E. reboot-if-idle once idle ==="
  idle
  U reboot-if-idle > "$PWD/e.log" 2>&1 || fail "reboot-if-idle exited non-zero when idle"
  did_reboot "reboot-if-idle did not reboot an idle device with a pending update"
  ok "reboot requested"

  # =====================================================================
  # F. THE SERVER DOES NOT ANSWER -- fail CLOSED, never reboot.
  # =====================================================================
  echo "=== F. the idle route is unreachable ==="
  kill "$http_pid"; wait "$http_pid" 2>/dev/null || true
  U reboot-if-idle > "$PWD/f.log" 2>&1 || fail "reboot-if-idle exited non-zero with no server"
  grep -q "treating the device as BUSY" "$PWD/f.log" \
    || { cat "$PWD/f.log" >&2; fail "an unanswered idle question did not fail closed"; }
  no_reboot "an unanswerable idle question became a reboot"
  [ -e "$marker" ] || fail "the marker was dropped when the server was down"
  ok "unreachable server = busy; the marker survives"

  python3 -m http.server --directory "$SRV" --bind 127.0.0.1 ${port} >/dev/null 2>&1 &
  http_pid=$!
  for _ in $(seq 1 50); do
    curl -sf "${base}/nanokvm_pro_sys_latest.json" >/dev/null 2>&1 && break
    sleep 0.2
  done

  # =====================================================================
  # G. THE BOOT HAPPENS -- the note settles, and says the update is live.
  # =====================================================================
  echo "=== G. after the reboot ==="
  rm -f "$marker"                       # /run is tmpfs: the reboot clears it
  rm -f "$R/run/current-system" "$R/run/booted-system"
  ln -s "$R$V2" "$R/run/current-system"
  ln -s "$R$V2" "$R/run/booted-system"
  U reboot-if-idle > "$PWD/g.log" 2>&1 || fail "reboot-if-idle exited non-zero after the boot"
  grep -q "update 9.9.9 is live" "$PWD/g.log" \
    || { cat "$PWD/g.log" >&2; fail "the note was not settled"; }
  [ ! -e "$note" ] || fail "the settled note was left behind"
  no_reboot "a settled note caused a reboot"
  ok "note settled, nothing rebooted"

  # =====================================================================
  # H. TICKED AND IDLE -- install and reboot in the same run.
  # =====================================================================
  echo "=== H. ticked, nobody using it ==="
  offer "$V3" "9.9.10"
  idle
  U update > "$PWD/h.log" 2>&1 || { cat "$PWD/h.log" >&2; fail "update failed when idle"; }
  [ "$(generation "$R")" = "system-3-link" ] \
    || fail "the update did not install when idle"
  [ "$(system_path "$R")" = "$V3" ] || fail "generation 3 is not the newly offered toplevel"
  [ -e "$marker" ] || fail "an idle install wrote no pending marker"
  did_reboot "an idle device did not reboot into its update"
  ok "installed and rebooted in one run"

  # ...and an update that is already installed is not installed again.
  echo "=== H2. the channel offers what is already running ==="
  rm -f "$marker" "$note"
  rm -f "$R/run/current-system"; ln -s "$R$V3" "$R/run/current-system"
  U update > "$PWD/h2.log" 2>&1 || fail "update failed when up to date"
  grep -q "already on 9.9.10" "$PWD/h2.log" \
    || { cat "$PWD/h2.log" >&2; fail "an up-to-date device reinstalled its own version"; }
  [ "$(generation "$R")" = "system-3-link" ] || fail "an up-to-date device made a generation"
  no_reboot "an up-to-date device rebooted"
  ok "up to date: nothing installed, nothing rebooted"

  # =====================================================================
  # I. THE STATUS SURFACES -- what the UI and an operator read.
  # =====================================================================
  echo "=== I. pending/status ==="
  # Into a file, not a pipe: `grep -q` closes the pipe on its first match and
  # `set -o pipefail` would then fail the whole line on the writer's SIGPIPE.
  rm -f "$R/run/current-system"; ln -s "$R$V2" "$R/run/current-system"
  U install-manifest <(jq -n --arg t "$V3" \
      '{format:"nanokvm-nix-closure/1", version:"9.9.10", toplevel:$t}') > /dev/null
  U pending > "$PWD/i.log"
  grep -q "reboot pending    : 9.9.10" "$PWD/i.log" \
    || { cat "$PWD/i.log" >&2; fail "'pending' does not report the owed reboot"; }
  grep -q "automatic updates : on" "$PWD/i.log" \
    || { cat "$PWD/i.log" >&2; fail "'pending' does not report the checkbox"; }
  untick
  U pending > "$PWD/i2.log"
  grep -q "automatic updates : off" "$PWD/i2.log" \
    || { cat "$PWD/i2.log" >&2; fail "'pending' does not follow the checkbox"; }
  U status > "$PWD/i3.log"
  grep -q "pinned  " "$PWD/i3.log" \
    || { cat "$PWD/i3.log" >&2; fail "'status' does not report what the boot configs pin"; }
  ok "pending and status report the version, the checkbox and the pins"

  kill "$http_pid" 2>/dev/null || true
  wait "$http_pid" 2>/dev/null || true

  echo
  echo "the update policy holds offline: the checkbox gates it, the reboot waits."
  touch "$out"
''
