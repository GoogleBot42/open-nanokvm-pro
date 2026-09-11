{ pkgs
, lib ? pkgs.lib
, toplevel # the NixOS system closure this release offers
, version ? "0.0.0-dev"
, manifestName ? "nanokvm_pro_sys_latest.json"
, format ? "nanokvm-nix-closure/1"
, ...
}:

# ===========================================================================
# THE RELEASE MANIFEST -- the whole of what a release publishes for the
# appliance's updater (#100).
#
# It is a few hundred bytes: a version and a store path. The payload it used to
# name -- a 460 MB tarball of the entire closure (#86) -- is gone, because the
# device has nix and substitutes the closure from our binary cache, fetching
# only the paths it does not already have.
#
#   {
#     "format":   "nanokvm-nix-closure/1",
#     "version":  "2.3.0",
#     "toplevel": "/nix/store/<hash>-nixos-system-nanokvm-...",
#     "size":     1342177280,     # the closure's total NAR size, for the UI
#     "closureCount": 812
#   }
#
# WHERE THE INTEGRITY COMES FROM, since there is no sha512 here any more: every
# NAR in the cache is signed, and the device installs with `nix copy
# --option require-sigs true --option trusted-public-keys <its own keys>`. So a
# manifest can only ever say "install store path X" -- it cannot supply the
# bytes, and bytes nobody trusted signed do not install. A tampered manifest
# can name an older signed release (a downgrade) or a path that does not exist
# (an update that fails); it cannot make the device run unsigned code. That is
# strictly stronger than the tar bundle's SHA-512, which authenticated nothing
# -- it only proved the download matched our own manifest.
#
# `size` is the closure's TOTAL NAR SIZE, not the download: the device already
# has most of it, so what actually crosses the wire is usually a few percent of
# this. The UI shows it as an upper bound, which is the honest thing to show
# before asking the store what it is missing.
# ===========================================================================

let
  closureInfo = pkgs.closureInfo { rootPaths = [ toplevel ]; };
in
pkgs.runCommand "nanokvm-system-manifest-${version}"
{
  nativeBuildInputs = [ pkgs.jq pkgs.coreutils pkgs.gnugrep ];
  passthru = { inherit toplevel version manifestName closureInfo; };
  meta = {
    description =
      "NanoKVM-Pro release manifest (#100): the version and the store path an update installs";
    platforms = [ "x86_64-linux" ];
  };
} ''
  set -euo pipefail
  mkdir -p "$out"

  n=$(wc -l < ${closureInfo}/store-paths)
  size=$(cat ${closureInfo}/total-nar-size)

  # The toplevel must be IN its own closure. It always is -- but this manifest
  # is the only thing a device is told about a release, so the one sanity check
  # that can be made here is made here.
  grep -qxF "${toplevel}" ${closureInfo}/store-paths \
    || { echo "ERROR: the closure does not contain its own toplevel" >&2; exit 1; }

  jq -n \
    --arg format   "${format}" \
    --arg version  "${version}" \
    --arg toplevel "${toplevel}" \
    --argjson size "$size" \
    --argjson count "$n" \
    '{ format: $format,
       version: $version,
       toplevel: $toplevel,
       size: $size,
       closureCount: $count }' \
    > "$out/${manifestName}"
  cat "$out/${manifestName}"

  # Kept beside it, NOT published: what a release pushed to the cache, so a
  # hardware run or a `nix build --rebuild` can diff a device's store against
  # the release without re-evaluating the flake.
  cp ${closureInfo}/store-paths "$out/closure.txt"
  echo "${toplevel}" > "$out/toplevel"
''
