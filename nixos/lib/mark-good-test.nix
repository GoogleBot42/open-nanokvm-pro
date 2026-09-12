{ pkgs
, lib ? pkgs.lib
, ...
}:

# ===========================================================================
# THE DERIVED FALLBACK (#99) -- `nix flake check`'s `nanokvm-mark-good-fallback`.
#
# It runs the REAL `nanokvm-mark-good` against a fake root in a build sandbox:
# a /boot holding an extlinux.conf of the shape NixOS's builder writes, two
# generations in the profile, and /run/booted-system pointing at the older one.
#
# What it proves, and each of these is a board that does not come back if it
# is wrong:
#
#   1. the fallback selects the BOOTED generation's label, not the default one;
#   2. exactly one line of the official config changed, and it is DEFAULT --
#      every LABEL, LINUX, INITRD, FDT and APPEND is byte-identical, because
#      the fallback has to describe the same bootable set;
#   3. a second run is a no-op rather than a rewrite;
#   4. it REFUSES, loudly and with the previous fallback intact, when the
#      booted generation has no LABEL in the file. U-Boot's
#      `menu_default_choice()` returns -ENOENT for a DEFAULT it cannot match
#      and `handle_pxe_menu()` then boots the FIRST label -- the generation the
#      rollback exists to escape -- so writing one would be worse than not
#      promoting at all.
#
# `--no-wait` skips the health poll and the `devmem` write, which are the two
# things a sandbox has no way to satisfy. Everything below that line is the
# code that actually runs on the board.
# ===========================================================================

let
  # The list is spelled out here rather than taken from the module so that the
  # test says what it is testing. It is the same SHAPE as
  # `nanokvm.markGood.tolerateFailed`'s default: peripherals only.
  tolerated = [ "nanokvm-wifi.service" "nanokvm-panel.service" ];
  markGood = import ./mark-good.nix {
    inherit pkgs lib;
    tolerateFailed = tolerated;
  };

  oldSys = "00000000000000000000000000000001-nixos-system-old";
  newSys = "00000000000000000000000000000002-nixos-system-new";

  # An extlinux.conf of exactly the shape
  # nixos/modules/system/boot/loader/generic-extlinux-compatible's builder
  # writes with `-t 0` (no MENU TITLE) and two generations in the profile.
  entry = tag: sys: ''

    LABEL nixos-${tag}
      MENU LABEL NixOS - ${tag}
      LINUX ../nixos/${sys}-kernel
      INITRD ../nixos/${sys}-initrd
      APPEND init=/nix/store/${sys}/init mem=512M root=/dev/loop0p5 panic=10
      FDT ../nixos/${sys}-dtbs/ax630c-nanokvm-pro.dtb
  '';

  officialConf = pkgs.writeText "extlinux.conf" (''
    # Generated file, all changes will be lost on nixos-rebuild!

    # Change this to e.g. nixos-42 to temporarily boot to an older configuration.
    DEFAULT nixos-default

    TIMEOUT 1
  ''
  + entry "default" newSys
  + entry "2-default" newSys
  + entry "1-default" oldSys);
in
pkgs.runCommand "nanokvm-mark-good-fallback"
{
  nativeBuildInputs = [ markGood pkgs.coreutils pkgs.gnugrep pkgs.diffutils pkgs.gawk ];
  meta.description =
    "Offline proof of the #99 derived fallback: promote, diff, refuse";
} ''
  set -euo pipefail
  R="$PWD/root"
  fail() { echo "FAIL: $*" >&2; exit 1; }
  ok()   { echo "  ok: $*"; }

  mkdir -p "$R/boot/extlinux" "$R/nix/store" "$R/nix/var/nix/profiles" "$R/run"
  for p in ${oldSys} ${newSys}; do mkdir -p "$R/nix/store/$p"; done

  # Relative profile links, so they resolve inside the fake root the way
  # absolute ones do on the device.
  ln -s ../../../store/${oldSys} "$R/nix/var/nix/profiles/system-1-link"
  ln -s ../../../store/${newSys} "$R/nix/var/nix/profiles/system-2-link"
  ln -s system-2-link "$R/nix/var/nix/profiles/system"

  install -m 0644 ${officialConf} "$R/boot/extlinux/extlinux.conf"
  # The seeded fallback a freshly flashed board carries: a copy.
  cp "$R/boot/extlinux/extlinux.conf" "$R/boot/extlinux/extlinux-fallback.conf"

  # =====================================================================
  # 1. THE BOOTED GENERATION IS THE OLD ONE -- i.e. the board booted gen 1
  #    while the profile has already advanced to gen 2. That is exactly the
  #    state after `nanokvm-update` and before the reboot, and promoting the
  #    profile instead of the booted system is the mistake this guards.
  # =====================================================================
  ln -sfn "$R/nix/store/${oldSys}" "$R/run/booted-system"

  echo "=== nanokvm-mark-good --no-wait (booted: generation 1) ==="
  nanokvm-mark-good --root "$R" --no-wait

  conf="$R/boot/extlinux/extlinux.conf"
  fb="$R/boot/extlinux/extlinux-fallback.conf"

  grep -qx 'DEFAULT nixos-1-default' "$fb" \
    || { cat "$fb" >&2; fail "the fallback does not select the BOOTED generation"; }
  ok "the fallback selects nixos-1-default, the generation that booted"

  grep -qx 'DEFAULT nixos-default' "$conf" \
    || fail "mark-good rewrote the official config -- only NixOS may write it"
  ok "extlinux.conf is untouched"

  # Exactly one line differs, and it is the DEFAULT. Anything else and the two
  # files would describe different bootable sets.
  diff "$conf" "$fb" > delta.txt || true
  changed=$(grep -c '^[<>]' delta.txt || true)
  [ "$changed" = 2 ] || { cat delta.txt >&2; fail "$changed lines differ, expected 2"; }
  grep -qx '< DEFAULT nixos-default' delta.txt || { cat delta.txt >&2; fail "the removed line is not the DEFAULT"; }
  grep -qx '> DEFAULT nixos-1-default' delta.txt || { cat delta.txt >&2; fail "the added line is not the new DEFAULT"; }
  ok "exactly the DEFAULT line moved; every LABEL/LINUX/INITRD/FDT/APPEND is identical"

  # The label it selected has to exist, or U-Boot boots the first entry.
  grep -qx 'LABEL nixos-1-default' "$fb" || fail "the fallback selects a label it does not define"
  ok "the selected label is defined in the file it is selected from"

  # =====================================================================
  # 2. IDEMPOTENT. A second healthy boot of the same generation must not
  #    rewrite the file -- /boot is the one partition a half-write kills.
  # =====================================================================
  cp "$fb" before.txt
  nanokvm-mark-good --root "$R" --no-wait | tee run2.log
  cmp -s before.txt "$fb" || fail "a second run rewrote an identical fallback"
  grep -q "already generation 1" run2.log || fail "the second run did not report a no-op"
  ok "a repeat promotion is a no-op"

  # =====================================================================
  # 3. THE REFUSAL. The booted system is a generation the boot menu does not
  #    name -- it fell outside configurationLimit, or this /boot predates #99.
  # =====================================================================
  echo "=== nanokvm-mark-good must refuse a generation the file does not name ==="
  mkdir -p "$R/nix/store/00000000000000000000000000000009-nixos-system-stray"
  ln -s ../../../store/00000000000000000000000000000009-nixos-system-stray \
    "$R/nix/var/nix/profiles/system-9-link"
  ln -sfn "$R/nix/store/00000000000000000000000000000009-nixos-system-stray" \
    "$R/run/booted-system"
  cp "$fb" before.txt

  if nanokvm-mark-good --root "$R" --no-wait 2> refusal.log; then
    fail "mark-good promoted a generation the config does not name"
  fi
  grep -q 'no "LABEL nixos-9-default"' refusal.log \
    || { cat refusal.log >&2; fail "it refused for the wrong reason"; }
  grep -q 'the previous fallback stands' refusal.log \
    || { cat refusal.log >&2; fail "the refusal does not say what it left standing"; }
  cmp -s before.txt "$fb" || fail "it changed the fallback while refusing"
  ok "it refuses, says so, and leaves the previous fallback exactly as it was"

  # =====================================================================
  # 4. NO /boot, which is what a vendor-layout boot and an unmounted /boot
  #    both look like. Must be a clean skip, never a write into the rootfs.
  # =====================================================================
  rm -rf "$R/boot/extlinux"
  nanokvm-mark-good --root "$R" --no-wait | tee noboot.log
  grep -q "not promoting a fallback" noboot.log || fail "no message about the missing /boot"
  [ ! -e "$R/boot/extlinux" ] || fail "it created a /boot that is not mounted"
  ok "an absent /boot/extlinux is a clean skip"

  # =====================================================================
  # 5. THE HEALTH GATE'S TOLERATE LIST (#106). Since the peripheral units
  #    fail honestly again, this list is the ONLY thing standing between a
  #    missing WiFi radio and a rollback nobody asked for -- so it is worth
  #    an offline proof rather than a hardware round. `--check-system` runs
  #    the real `system_ok` against the two answers below.
  # =====================================================================
  echo "=== the tolerate list ==="
  mkdir -p "$R/test"
  gate() {  # gate <expect-ok> <state> <failed units...>
    want="$1"; shift
    printf '%s\n' "$1" > "$R/test/is-system-running"; shift
    printf '%s' "" > "$R/test/failed-units"
    for u in "$@"; do echo "$u" >> "$R/test/failed-units"; done
    if nanokvm-mark-good --root "$R" --check-system > gate.log 2>&1; then got=yes; else got=no; fi
    [ "$got" = "$want" ] \
      || { cat gate.log >&2; fail "gate said $got, expected $want"; }
    ok "$(cat gate.log)"
  }

  gate yes running
  gate yes degraded nanokvm-wifi.service
  gate yes degraded nanokvm-wifi.service nanokvm-panel.service
  gate no  degraded nanokvm.service
  gate no  degraded nanokvm-wifi.service nanokvm.service
  gate no  degraded sshd.service
  gate no  starting
  gate no  ""

  echo
  echo "the derived fallback and the health gate hold offline."
  touch "$out"
''
