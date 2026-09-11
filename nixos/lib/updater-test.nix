{ pkgs
, lib ? pkgs.lib
, ...
}:

# ===========================================================================
# THE OFFLINE UPDATER LOOP (#86) -- `nix flake check`'s `nanokvm-updater-loop`.
#
# It runs the REAL `nanokvm-update`, the REAL `nanokvm-gc` and the REAL
# `nanokvm-install-boot` against a fake root inside a build sandbox: apply a
# bundle, check the profile advanced and the boot config names the new
# generation AND its kernel, then collect and check the right things survived.
# This is the whole of what can be proven about an update before it meets
# hardware, and it is a lot: everything after this is "does the board boot the
# thing the script installed".
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
in
pkgs.runCommand "nanokvm-updater-loop"
{
  nativeBuildInputs = [
    tools.updater tools.gc installBoot
    pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.findutils
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
  # The fake root: one installed generation, a /boot with its kernel, and
  # the closure record the image build would have written.
  # =====================================================================
  mkdir -p "$R/nix/store" "$R/nix/var/nix/profiles" "$R/boot/extlinux" \
           "$R/var/lib/nanokvm/closures" "$R/run" "$R/etc"

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

  echo "old kernel"  > "$R/boot/Image-old0000000000000"
  echo "old dtb"     > "$R/boot/ax630c-nanokvm-pro-old0000000000000.dtb"
  nanokvm-install-boot --root "$R" \
    --kernel /Image-old0000000000000 \
    --fdt /ax630c-nanokvm-pro-old0000000000000.dtb \
    "/nix/store/${oldSys}"
  cp "$R/boot/extlinux/extlinux.conf" "$R/boot/extlinux/extlinux-fallback.conf"

  # =====================================================================
  # The bundle: a new toplevel, one new path, one shared path it already has.
  # =====================================================================
  mkdir -p "$B/store" "$B/boot"
  for p in ${newSys} ${newOnly}; do
    mkdir -p "$B/store/$p/bin"
    echo "$p" > "$B/store/$p/marker"
  done
  printf '#!/bin/sh\nexit 0\n' > "$B/store/${newSys}/bin/switch-to-configuration"
  chmod +x "$B/store/${newSys}/bin/switch-to-configuration"

  printf '/nix/store/%s\n' ${newSys} ${newOnly} ${shared} \
    | sort > "$B/closure.txt"

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

  [ -f "$R/boot/Image-new0000000000000" ] || fail "the new kernel is not in /boot"
  ok "the new kernel is in /boot"
  [ -f "$R/boot/Image-old0000000000000" ] || fail "the old kernel was removed by the update"
  ok "the old kernel is still in /boot (mark-good collects it, not the updater)"

  conf="$R/boot/extlinux/extlinux.conf"
  fb="$R/boot/extlinux/extlinux-fallback.conf"
  grep -q "init=/nix/store/${newSys}/init" "$conf" \
    || fail "extlinux.conf does not name the new generation"
  grep -q "LINUX /Image-new0000000000000" "$conf" \
    || fail "extlinux.conf does not name the new kernel"
  grep -q "nanokvmboot=/Image-new0000000000000," "$conf" \
    || fail "extlinux.conf carries no nanokvmboot= token for the new kernel"
  ok "extlinux.conf names the new generation AND the new kernel"

  grep -q "init=/nix/store/${oldSys}/init" "$fb" \
    || fail "the fallback moved -- only nanokvm-mark-good may promote it"
  grep -q "LINUX /Image-old0000000000000" "$fb" \
    || fail "the fallback's kernel moved"
  ok "the fallback still names the OLD generation and the OLD kernel"

  [ ! -e "$R/run/nanokvm-pending-boot" ] || fail "the pending-boot note was left behind"
  ok "the pending-boot note was consumed"

  # =====================================================================
  # 2. COLLECT -- while the fallback still names generation 1
  # =====================================================================
  echo "=== nanokvm-gc --keep 1, with generation 1 named by the fallback ==="
  nanokvm-gc --root "$R" --keep 1
  [ -e "$R/nix/var/nix/profiles/system-1-link" ] \
    || fail "gc dropped the generation the ROLLBACK config names"
  [ -e "$R/nix/store/${oldOnly}/marker" ] \
    || fail "gc deleted a path the fallback generation needs"
  [ -e "$R/nix/store/${shared}/marker" ] || fail "gc deleted a shared path"
  ok "the fallback generation and its exclusive paths survive --keep 1"

  # =====================================================================
  # 3. COLLECT -- after the fallback has been promoted (what mark-good does)
  # =====================================================================
  echo "=== nanokvm-gc --keep 1, with the fallback promoted to generation 2 ==="
  cp "$conf" "$fb"
  rm -f "$R/run/booted-system" "$R/run/current-system"
  ln -s "$R/nix/store/${newSys}" "$R/run/booted-system"
  ln -s "$R/nix/store/${newSys}" "$R/run/current-system"
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
  # 4. THE REFUSAL -- a kept generation with no closure record
  # =====================================================================
  # Without nix there is no way to recompute a closure, so an unknown live set
  # must mean NO deletion at all. A gc that guessed here would be a bench trip.
  echo "=== nanokvm-gc must refuse when a kept generation has no closure list ==="
  mv "$R/var/lib/nanokvm/closures/${newSys}.txt" "$PWD/hidden.txt"
  if nanokvm-gc --root "$R" --keep 1 2>"$PWD/gc-refusal.log"; then
    fail "gc collected with an unknown live set"
  fi
  grep -q "refusing to collect anything" "$PWD/gc-refusal.log" \
    || { cat "$PWD/gc-refusal.log" >&2; fail "gc failed for the wrong reason"; }
  [ -e "$R/nix/store/${shared}/marker" ] || fail "gc deleted something before refusing"
  ok "gc refuses, and deletes nothing, when a closure list is missing"

  echo
  echo "the #86 update loop holds offline."
  touch "$out"
''
