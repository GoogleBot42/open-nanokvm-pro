{ pkgs
, lib ? pkgs.lib
, ...
}:

# ===========================================================================
# THE OFFLINE PROOF OF "INSTALL NOW, REBOOT WHEN IDLE" (#86).
# `nix flake check`'s `nanokvm-update-idle`.
#
# `nanokvm-updater-loop` proves the bundle apply; this proves the policy
# wrapped around it -- the checkbox, the pending markers, the idle gate and the
# second timer -- with the REAL `nanokvm-update` against a fake root and a fake
# release host inside a build sandbox.
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

  extlinuxTemplate = pkgs.writeText "extlinux.conf.in" (import ../../pkgs/extlinux.nix {
    inherit pkgs lib;
    init = "@INIT@";
    kernelFile = "@KERNEL@";
    dtbFile = "@FDT@";
    bootId = "@KERNEL@,@FDT@";
  });

  installBoot = import ./install-boot.nix { inherit pkgs lib extlinuxTemplate; };

  tools = import ./updater.nix {
    inherit pkgs lib;
    bootInstaller = installBoot;
    stableUrl = base;
    previewUrl = "${base}/preview";
    idleUrl = "${base}/api/update/idle";
    idleQuietSec = 600;
    keepGenerations = 3;
  };

  oldSys = "00000000000000000000000000000001-nixos-system-old";
  newSys = "00000000000000000000000000000002-nixos-system-new";
  shared = "00000000000000000000000000000003-shared-lib";
  newOnly = "00000000000000000000000000000005-new-only";
in
pkgs.runCommand "nanokvm-update-idle"
{
  nativeBuildInputs = [
    tools.updater installBoot
    pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.findutils
    pkgs.gnutar pkgs.gzip pkgs.openssl pkgs.curl pkgs.python3
  ];
  meta.description =
    "Offline proof of the #86 update policy: the auto-updates checkbox, the pending markers and the idle reboot gate";
} ''
  set -euo pipefail
  R="$PWD/root"
  SRV="$PWD/srv"

  fail() { echo "FAIL: $*" >&2; exit 1; }
  ok()   { echo "  ok: $*"; }

  U() { nanokvm-update --root "$R" "$@"; }

  # The two things the test drives.
  idle()   { printf '{"code":0,"msg":"success","data":{"idle":true,"busy":[]}}\n' > "$SRV/api/update/idle"; }
  inuse()  { printf '{"code":0,"msg":"success","data":{"idle":false,"busy":["stream"]}}\n' > "$SRV/api/update/idle"; }
  tick()   { : > "$R/etc/kvm/auto_updates"; }
  untick() { rm -f "$R/etc/kvm/auto_updates"; }

  marker="$R/run/nanokvm-update-pending"
  note="$R/var/lib/nanokvm/update-pending"
  rebooted="$R/run/nanokvm-reboot-requested"
  no_reboot() { [ ! -e "$rebooted" ] || fail "$1"; }
  did_reboot() { [ -e "$rebooted" ] || fail "$1"; rm -f "$rebooted"; }

  # =====================================================================
  # The fake root -- one installed generation, as nixos/lib/updater-test.nix
  # builds it, plus the /etc/kvm the flag files live in.
  # =====================================================================
  mkdir -p "$R/nix/store" "$R/nix/var/nix/profiles" "$R/boot/extlinux" \
           "$R/var/lib/nanokvm/closures" "$R/run" "$R/etc/kvm" "$R/proc"

  for p in ${oldSys} ${shared}; do
    mkdir -p "$R/nix/store/$p/bin" "$R/nix/store/$p/etc"
  done
  echo "0.0.1"  > "$R/nix/store/${oldSys}/etc/nanokvm-version"
  printf '#!/bin/sh\nexit 0\n' > "$R/nix/store/${oldSys}/bin/switch-to-configuration"
  chmod +x "$R/nix/store/${oldSys}/bin/switch-to-configuration"

  ln -s ../../../store/${oldSys} "$R/nix/var/nix/profiles/system-1-link"
  ln -s system-1-link "$R/nix/var/nix/profiles/system"
  ln -s "$R/nix/store/${oldSys}" "$R/run/booted-system"
  ln -s "$R/nix/store/${oldSys}" "$R/run/current-system"

  printf '/nix/store/%s\n' ${oldSys} ${shared} \
    | sort > "$R/var/lib/nanokvm/closures/${oldSys}.txt"

  echo "old kernel" > "$R/boot/Image-old0000000000000"
  echo "old dtb"    > "$R/boot/ax630c-nanokvm-pro-old0000000000000.dtb"
  nanokvm-install-boot --root "$R" \
    --kernel /Image-old0000000000000 \
    --fdt /ax630c-nanokvm-pro-old0000000000000.dtb \
    "/nix/store/${oldSys}"
  cp "$R/boot/extlinux/extlinux.conf" "$R/boot/extlinux/extlinux-fallback.conf"

  # =====================================================================
  # The fake release host: a bundle, its tarball, and the manifest the
  # updater polls -- served from the same directory as the idle route, which
  # is why the route is a plain file (http.server strips the query string).
  # =====================================================================
  B="$PWD/nanokvm_pro_sys_9.9.9"
  mkdir -p "$B/store" "$B/boot" "$SRV/api/update"
  for p in ${newSys} ${newOnly}; do
    mkdir -p "$B/store/$p/bin" "$B/store/$p/etc"
  done
  echo "9.9.9" > "$B/store/${newSys}/etc/nanokvm-version"
  printf '#!/bin/sh\nexit 0\n' > "$B/store/${newSys}/bin/switch-to-configuration"
  chmod +x "$B/store/${newSys}/bin/switch-to-configuration"

  printf '/nix/store/%s\n' ${newSys} ${newOnly} ${shared} | sort > "$B/closure.txt"
  echo "new kernel" > "$B/boot/Image-new0000000000000"
  echo "new dtb"    > "$B/boot/ax630c-nanokvm-pro-new0000000000000.dtb"
  ksha=$(sha256sum "$B/boot/Image-new0000000000000" | cut -d' ' -f1)
  fsha=$(sha256sum "$B/boot/ax630c-nanokvm-pro-new0000000000000.dtb" | cut -d' ' -f1)
  jq -n --arg k "$ksha" --arg f "$fsha" \
    '{ format: "nanokvm-system-bundle/1", version: "9.9.9", layout: "minimal",
       toplevel: "/nix/store/${newSys}", closureCount: 3,
       boot: { kernel: "Image-new0000000000000",
               fdt: "ax630c-nanokvm-pro-new0000000000000.dtb",
               kernelSha256: $k, fdtSha256: $f } }' > "$B/MANIFEST.json"

  tar --hard-dereference --sort=name -C "$PWD" \
      -czf "$SRV/nanokvm_pro_sys_9.9.9.tar.gz" nanokvm_pro_sys_9.9.9
  sha=$(openssl dgst -sha512 -binary "$SRV/nanokvm_pro_sys_9.9.9.tar.gz" | base64 -w0)
  size=$(stat -c%s "$SRV/nanokvm_pro_sys_9.9.9.tar.gz")
  jq -n --arg s "$sha" --argjson z "$size" \
    '{ version: "9.9.9", name: "nanokvm_pro_sys_9.9.9.tar.gz", sha512: $s, size: $z }' \
    > "$SRV/nanokvm_pro_sys_latest.json"

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
  [ "$(readlink "$R/nix/var/nix/profiles/system")" = "system-1-link" ] \
    || fail "an unticked device installed an update"
  [ ! -e "$marker" ] || fail "an unticked device wrote a pending marker"
  no_reboot "an unticked device asked for a reboot"
  ok "unticked: no install, no marker, no reboot, exit 0"

  # =====================================================================
  # B. TICKED, SOMEBODY IS USING IT -- install, mark, DO NOT reboot.
  # =====================================================================
  echo "=== B. ticked, device in use ==="
  tick; inuse
  U update > "$PWD/b.log" 2>&1 || fail "update failed with the box ticked"
  [ "$(readlink "$R/nix/var/nix/profiles/system")" = "system-2-link" ] \
    || fail "the update did not install"
  [ -e "$marker" ] || fail "no /run pending marker after an install"
  [ -r "$note" ]   || fail "no persistent note after an install"
  [ "$(sed -n 's/^VERSION=//p' "$marker")" = "9.9.9" ] \
    || fail "the marker does not name the installed version"
  [ "$(sed -n 's/^FROM=//p' "$marker")" = "0.0.1" ] \
    || fail "the marker does not name the version it replaced"
  no_reboot "the device rebooted while somebody was using it"
  grep -q "the reboot is pending" "$PWD/b.log" \
    || { cat "$PWD/b.log" >&2; fail "update did not report the deferred reboot"; }
  ok "in use: installed, both markers written, NO reboot"

  # =====================================================================
  # C. A SECOND UPDATE MUST NOT STACK ON AN UNBOOTED ONE.
  # =====================================================================
  echo "=== C. update with a reboot already owed ==="
  U update > "$PWD/c.log" 2>&1 || fail "update failed with a marker present"
  grep -q "not installing anything on top of it" "$PWD/c.log" \
    || { cat "$PWD/c.log" >&2; fail "update stacked on a pending reboot"; }
  [ "$(readlink "$R/nix/var/nix/profiles/system")" = "system-2-link" ] \
    || fail "a second generation was installed on top of a pending one"
  ok "refused, and said so"

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
  ln -s "$R/nix/store/${newSys}" "$R/run/current-system"
  ln -s "$R/nix/store/${newSys}" "$R/run/booted-system"
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
  rm -f "$R/run/current-system"
  ln -s "$R/nix/store/${oldSys}" "$R/run/current-system"   # an older version again
  idle
  U update > "$PWD/h.log" 2>&1 || fail "update failed when idle"
  [ "$(readlink "$R/nix/var/nix/profiles/system")" = "system-3-link" ] \
    || fail "the update did not install when idle"
  [ -e "$marker" ] || fail "an idle install wrote no pending marker"
  did_reboot "an idle device did not reboot into its update"
  ok "installed and rebooted in one run"

  # =====================================================================
  # I. THE STATUS SURFACES -- what the UI and an operator read.
  # =====================================================================
  echo "=== I. pending/status ==="
  # Into a file, not a pipe: `grep -q` closes the pipe on its first match and
  # `set -o pipefail` would then fail the whole line on the writer's SIGPIPE.
  U pending > "$PWD/i.log"
  grep -q "reboot pending    : 9.9.9" "$PWD/i.log" \
    || { cat "$PWD/i.log" >&2; fail "'pending' does not report the owed reboot"; }
  grep -q "automatic updates : on" "$PWD/i.log" \
    || { cat "$PWD/i.log" >&2; fail "'pending' does not report the checkbox"; }
  untick
  U pending > "$PWD/i2.log"
  grep -q "automatic updates : off" "$PWD/i2.log" \
    || { cat "$PWD/i2.log" >&2; fail "'pending' does not follow the checkbox"; }
  ok "pending reports the version, the checkbox and the running system"

  kill "$http_pid" 2>/dev/null || true
  wait "$http_pid" 2>/dev/null || true

  echo
  echo "the #86 update policy holds offline: the checkbox gates it, the reboot waits."
  touch "$out"
''
