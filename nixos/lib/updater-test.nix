{ pkgs
, lib ? pkgs.lib
, ...
}:

# ===========================================================================
# THE OFFLINE UPDATER LOOP (#86, reshaped by #99) -- `nix flake check`'s
# `nanokvm-updater-loop`.
#
# It runs the REAL `nanokvm-update` and the REAL `nanokvm-gc` against a fake
# root inside a build sandbox: apply a bundle, check the profile advanced and
# the closure record was written, then collect and check the right things
# survived. This is the whole of what can be proven about an update before it
# meets hardware.
#
# WHAT MOVED IN #99. The updater no longer writes /boot at all -- the kernel,
# the initrd and the dtb are store paths inside the closure, and
# `switch-to-configuration boot` is the only thing that copies them out. So
# what this check now owns on the /boot side is the OTHER half of the
# contract: that `nanokvm-gc` pins the generation each config's DEFAULT entry
# names, out of a file that lists several. Reading the first `init=` in a
# NixOS-written extlinux.conf would pin whichever generation the builder
# emitted first and leave the fallback's own collectable -- and the fallback is
# what gets used precisely when the default does not work.
# `nanokvm-mark-good-fallback` (nixos/lib/mark-good-test.nix) owns the writing
# half.
#
# WHY THE SCRIPTS ARE INSTANTIATED AGAINST `pkgs` AND NOT THE APPLIANCE'S.
# The appliance is aarch64; running its copies would need binfmt, which a
# release runner does not have. The script TEXT is identical either way -- the
# only difference is which coreutils is on PATH -- so this is a test of the
# logic, which is what the logic needs.
#
# WHAT IT CANNOT PROVE: `switch-to-configuration`, the `/nix/store` remount,
# the eMMC, and whether U-Boot can read what was written. Those are the
# hardware plan in docs/updates.md.
#
# The fixture is deliberately tiny and synthetic -- six "store paths" of a few
# bytes each -- because the thing under test is the bookkeeping, not the size.
# `nanokvm-system-bundle` (pkgs/system-bundle-check.nix) is where the REAL
# artefact's shape is checked.
# ===========================================================================

let
  tools = import ./updater.nix {
    inherit pkgs lib;
    stableUrl = "https://example.invalid/latest";
    previewUrl = "https://example.invalid/preview";
    keepGenerations = 3;
  };

  # Store-path-shaped names, because closure.txt lines are `/nix/store/<base>`
  # and everything downstream takes the basename.
  oldSys = "00000000000000000000000000000001-nixos-system-old";
  newSys = "00000000000000000000000000000002-nixos-system-new";
  shared = "00000000000000000000000000000003-shared-lib";
  oldOnly = "00000000000000000000000000000004-old-only";
  newOnly = "00000000000000000000000000000005-new-only";

  # One LABEL per generation and a single DEFAULT that selects among them --
  # the shape NixOS's builder writes, and the reason `conf_default_toplevel`
  # exists.
  entry = tag: sys: ''

    LABEL nixos-${tag}
      MENU LABEL NixOS - ${tag}
      LINUX ../nixos/${sys}-kernel
      INITRD ../nixos/${sys}-initrd
      APPEND init=/nix/store/${sys}/init root=/dev/loop0p5 panic=10
      FDT ../nixos/${sys}-dtbs/ax630c-nanokvm-pro.dtb
  '';

  mkConf = def: pkgs.writeText "extlinux.conf" (''
    # Generated file, all changes will be lost on nixos-rebuild!

    DEFAULT ${def}

    TIMEOUT 1
  ''
  # nixos-default is emitted FIRST and names the newest generation, which is
  # exactly what makes "read the first init=" the wrong answer.
  + entry "default" newSys
  + entry "2-default" newSys
  + entry "1-default" oldSys);
in
pkgs.runCommand "nanokvm-updater-loop"
{
  nativeBuildInputs = [
    tools.updater tools.gc
    pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gawk pkgs.jq pkgs.findutils
  ];
  meta.description =
    "Offline proof of the #86 update loop: apply a bundle to a fake root, then collect";
} ''
  set -euo pipefail
  R="$PWD/root"
  B="$PWD/bundle"

  fail() { echo "FAIL: $*" >&2; exit 1; }
  ok()   { echo "  ok: $*"; }

  # =====================================================================
  # The fake root: one installed generation and the closure record the image
  # build would have written.
  # =====================================================================
  mkdir -p "$R/nix/store" "$R/nix/var/nix/profiles" "$R/boot/extlinux" \
           "$R/boot/nixos" "$R/var/lib/nanokvm/closures" "$R/run" "$R/etc"

  for p in ${oldSys} ${shared} ${oldOnly}; do
    mkdir -p "$R/nix/store/$p/bin"
    echo "$p" > "$R/nix/store/$p/marker"
  done
  printf '#!/bin/sh\nexit 0\n' > "$R/nix/store/${oldSys}/bin/switch-to-configuration"
  chmod +x "$R/nix/store/${oldSys}/bin/switch-to-configuration"

  # The profile link is RELATIVE so it resolves inside the fake root, the way
  # an absolute one does on the device.
  ln -s ../../../store/${oldSys} "$R/nix/var/nix/profiles/system-1-link"
  ln -s system-1-link "$R/nix/var/nix/profiles/system"
  ln -s "$R/nix/store/${oldSys}" "$R/run/booted-system"
  ln -s "$R/nix/store/${oldSys}" "$R/run/current-system"

  printf '/nix/store/%s\n' ${oldSys} ${shared} ${oldOnly} \
    | sort > "$R/var/lib/nanokvm/closures/${oldSys}.txt"

  # =====================================================================
  # The bundle: a new toplevel, one new path, one shared path it already has.
  # NO boot/ directory -- that is the #99 contract.
  # =====================================================================
  mkdir -p "$B/store"
  for p in ${newSys} ${newOnly}; do
    mkdir -p "$B/store/$p/bin"
    echo "$p" > "$B/store/$p/marker"
  done
  printf '#!/bin/sh\nexit 0\n' > "$B/store/${newSys}/bin/switch-to-configuration"
  chmod +x "$B/store/${newSys}/bin/switch-to-configuration"

  printf '/nix/store/%s\n' ${newSys} ${newOnly} ${shared} \
    | sort > "$B/closure.txt"

  jq -n '{ format: "nanokvm-system-bundle/1", version: "9.9.9", layout: "minimal",
           toplevel: "/nix/store/${newSys}", closureCount: 3 }' > "$B/MANIFEST.json"

  # =====================================================================
  # 1. APPLY
  # =====================================================================
  echo "=== nanokvm-update install-staged ==="
  nanokvm-update --root "$R" --no-activate install-staged "$B"

  echo "=== what the apply must have done ==="
  [ -e "$R/nix/store/${newSys}/marker" ]  || fail "the new toplevel is not in the store"
  [ -e "$R/nix/store/${newOnly}/marker" ] || fail "the new-only path is not in the store"
  ok "both new store paths landed"

  [ -e "$R/nix/store/${oldSys}/marker" ]  || fail "the old generation was destroyed by an update"
  ok "the old generation is untouched"

  gen=$(readlink "$R/nix/var/nix/profiles/system")
  [ "$gen" = "system-2-link" ] || fail "the profile is $gen, expected system-2-link"
  [ "$(readlink -f "$R/nix/var/nix/profiles/system")" = "$R/nix/store/${newSys}" ] \
    || fail "generation 2 does not resolve to the new toplevel"
  ok "the system profile is generation 2 -> the new toplevel"

  [ -f "$R/var/lib/nanokvm/closures/${newSys}.txt" ] \
    || fail "no closure record for the new generation -- gc could never run again"
  ok "the new generation's closure list was recorded"

  # THE UPDATER MUST NOT HAVE TOUCHED /boot (#99). It was empty going in and it
  # stays empty: `switch-to-configuration boot` is the only writer, and this
  # run was --no-activate.
  [ -z "$(find "$R/boot" -mindepth 2)" ] \
    || { find "$R/boot" >&2; fail "the updater wrote /boot"; }
  ok "/boot is untouched -- the extlinux builder owns it, not this script"

  [ ! -e "$R/run/nanokvm-pending-boot" ] || fail "a pending-boot note was left behind"
  ok "no pending-boot note (the mechanism it served is gone)"

  # =====================================================================
  # 2. COLLECT -- while the FALLBACK's DEFAULT still names generation 1
  # =====================================================================
  # Both files list all three entries; only their DEFAULT differs. Pinning the
  # first `init=` instead of the DEFAULT's would pin the NEW generation from
  # both files and collect the one the rollback needs.
  install -m 0644 ${mkConf "nixos-default"}   "$R/boot/extlinux/extlinux.conf"
  install -m 0644 ${mkConf "nixos-1-default"} "$R/boot/extlinux/extlinux-fallback.conf"

  echo "=== nanokvm-gc --keep 1, with generation 1 named by the fallback's DEFAULT ==="
  nanokvm-gc --root "$R" --keep 1
  [ -e "$R/nix/var/nix/profiles/system-1-link" ] \
    || fail "gc dropped the generation the ROLLBACK config's DEFAULT names"
  [ -e "$R/nix/store/${oldOnly}/marker" ] \
    || fail "gc deleted a path the fallback generation needs"
  [ -e "$R/nix/store/${shared}/marker" ] || fail "gc deleted a shared path"
  ok "the fallback generation and its exclusive paths survive --keep 1"

  # =====================================================================
  # 3. COLLECT -- after the fallback has been promoted (what mark-good does)
  # =====================================================================
  install -m 0644 ${mkConf "nixos-2-default"} "$R/boot/extlinux/extlinux-fallback.conf"
  rm -f "$R/run/booted-system" "$R/run/current-system"
  ln -s "$R/nix/store/${newSys}" "$R/run/booted-system"
  ln -s "$R/nix/store/${newSys}" "$R/run/current-system"
  echo "=== nanokvm-gc --keep 1, with the fallback promoted to generation 2 ==="
  nanokvm-gc --root "$R" --keep 1

  [ ! -e "$R/nix/var/nix/profiles/system-1-link" ] \
    || fail "gc kept generation 1 when nothing pins it any more"
  [ ! -e "$R/nix/store/${oldSys}" ] || fail "gc kept the old toplevel"
  [ ! -e "$R/nix/store/${oldOnly}" ] || fail "gc kept a path only the old generation used"
  [ -e "$R/nix/store/${shared}/marker" ] \
    || fail "gc deleted a path the SURVIVING generation still needs"
  [ -e "$R/nix/store/${newSys}/marker" ] || fail "gc deleted the running system"
  [ -e "$R/nix/store/${newOnly}/marker" ] || fail "gc deleted the running system's dependency"
  ok "generation 1 and its exclusive paths collected; the live set is intact"

  [ ! -e "$R/var/lib/nanokvm/closures/${oldSys}.txt" ] \
    || fail "gc left the closure record of a generation it deleted"
  ok "the stale closure record is gone"

  # =====================================================================
  # 4. THE REFUSALS -- an unknown live set must mean NO deletion at all
  # =====================================================================
  # (a) a kept generation with no closure record. Without nix there is no way
  #     to recompute one, so a gc that guessed here would be a bench trip.
  echo "=== nanokvm-gc must refuse when a kept generation has no closure list ==="
  mv "$R/var/lib/nanokvm/closures/${newSys}.txt" "$PWD/hidden.txt"
  if nanokvm-gc --root "$R" --keep 1 2>"$PWD/gc-refusal.log"; then
    fail "gc collected with an unknown live set"
  fi
  grep -q "refusing to collect anything" "$PWD/gc-refusal.log" \
    || { cat "$PWD/gc-refusal.log" >&2; fail "gc failed for the wrong reason"; }
  [ -e "$R/nix/store/${shared}/marker" ] || fail "gc deleted something before refusing"
  ok "gc refuses, and deletes nothing, when a closure list is missing"
  mv "$PWD/hidden.txt" "$R/var/lib/nanokvm/closures/${newSys}.txt"

  # (b) a boot config whose DEFAULT names a label that is not in it. An empty
  #     pin list is NOT "nothing is pinned" -- it is "we do not understand this
  #     file", and the answer is to stop.
  echo "=== nanokvm-gc must refuse a boot config it cannot read a generation out of ==="
  printf 'DEFAULT nixos-nonexistent\n\nLABEL nixos-default\n  APPEND root=/dev/loop0p5\n' \
    > "$R/boot/extlinux/extlinux-fallback.conf"
  if nanokvm-gc --root "$R" --keep 1 2>"$PWD/gc-refusal2.log"; then
    fail "gc collected from a boot config whose DEFAULT names nothing"
  fi
  grep -q "names no generation on its DEFAULT entry" "$PWD/gc-refusal2.log" \
    || { cat "$PWD/gc-refusal2.log" >&2; fail "gc failed for the wrong reason"; }
  [ -e "$R/nix/store/${newSys}/marker" ] || fail "gc deleted something before refusing"
  ok "gc refuses when a config's DEFAULT resolves to no generation"

  echo
  echo "the #86 update loop holds offline, on the #99 boot contract."
  touch "$out"
''
