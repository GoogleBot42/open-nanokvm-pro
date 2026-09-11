{ pkgs
, lib ? pkgs.lib
, system-bundle
, bootPayload
, toplevel
, version ? "0.0.0-dev"
, manifestName ? "nanokvm_pro_sys_latest.json"
, payloadPrefix ? "nanokvm_pro_sys"
, ...
}:

# ===========================================================================
# `nix flake check`'s `nanokvm-system-bundle`: the release artefact READ BACK
# (#86).
#
# pkgs/system-bundle.nix asserts what it is doing while it does it. This opens
# the finished files instead, and checks them against the two things they are
# supposed to describe -- the system closure and the boot payload -- the same
# way `nixos-axp-manifest` re-reads the finished `.axp`. A build-time assertion
# proves the builder ran; this proves the artefact is right.
#
# WHAT A DEVICE ACTUALLY CONSUMES, in order, and so what is checked here:
#
#   1. the manifest's sha512 -- the ONE gate between the network and the board
#   2. the tarball's single top-level directory (the server's UnTarGz returns
#      it, and install() is handed nothing else)
#   3. MANIFEST.json's `toplevel`, and that closure.txt contains it
#   4. closure.txt == the toplevel's real closure, exactly
#   5. one `store/<base>` per closure line
#   6. the boot payload the manifest names, present and matching its hashes
#   7. no hardlink entries, because the device's extractor drops them silently
# ===========================================================================

let
  closure = pkgs.writeClosure [ toplevel ];
  tarball = "${payloadPrefix}_${version}.tar.gz";
  root = "${payloadPrefix}_${version}";
in
pkgs.runCommand "nanokvm-system-bundle-check"
{
  nativeBuildInputs = with pkgs; [ coreutils gnutar gzip openssl jq gnugrep gnused findutils ];
  meta.description = "Read the published system bundle back and check it against the closure it claims";
} ''
  set -euo pipefail
  B=${system-bundle}
  fail() { echo "FAIL: $*" >&2; exit 1; }
  ok()   { echo "  ok: $*"; }

  # ---- 1. the manifest the device polls --------------------------------
  echo "=== the poll manifest ==="
  cat "$B/${manifestName}"
  mv=$(jq -r '.version' "$B/${manifestName}")
  mn=$(jq -r '.name'    "$B/${manifestName}")
  ms=$(jq -r '.sha512'  "$B/${manifestName}")
  mz=$(jq -r '.size'    "$B/${manifestName}")
  [ "$mv" = "${version}" ] || fail "manifest version $mv != ${version}"
  [ "$mn" = "${tarball}" ] || fail "manifest names $mn, not ${tarball}"
  [ -f "$B/${tarball}" ]   || fail "the payload the manifest names is not in the output"

  got=$(openssl dgst -sha512 -binary "$B/${tarball}" | base64 -w0)
  [ "$got" = "$ms" ] || fail "manifest sha512 does not match the tarball"
  [ "$(stat -Lc%s "$B/${tarball}")" = "$mz" ] || fail "manifest size does not match the tarball"
  ok "sha512 and size match the payload (this is what the device verifies)"

  # base64 of a RAW digest, not hex -- the server enforces it, and a hex digest
  # here would be a channel that can never install anything.
  case "$ms" in
    *[^A-Za-z0-9+/=]*) fail "sha512 is not base64" ;;
  esac
  [ "''${#ms}" = 88 ] || fail "sha512 is ''${#ms} chars, not the 88 of base64(SHA-512)"
  ok "the digest is base64 of the raw SHA-512, the form the server checks"

  # ---- 2. the archive ---------------------------------------------------
  echo "=== the archive ==="
  tar -tzvf "$B/${tarball}" > listing.txt
  wc -l < listing.txt

  # `tar -tv` prints `name -> target` for a symlink, and a store path may itself
  # BE a symlink -- so strip the arrow before treating the field as a path, or
  # every such member reads as missing.
  sed 's|^[^ ]* *[^ ]* *[^ ]* *[^ ]* *[^ ]* *||; s| -> .*$||' listing.txt \
    | sed 's|/$||' | sort -u > names.txt

  ! grep -q '^h' listing.txt \
    || fail "the archive has hardlink entries; server/utils/untar.go ignores them silently"
  ok "no hardlink entries"

  tops=$(cut -d/ -f1 names.txt | sort -u)
  [ "$tops" = "${root}" ] \
    || fail "the archive has top-level entries other than ${root}: $tops"
  ok "one top-level directory, ${root} -- what UnTarGz hands install()"

  # ---- 3/4. the closure -------------------------------------------------
  echo "=== the closure ==="
  top=$(jq -r '.toplevel' "$B/MANIFEST.json")
  [ "$top" = "${toplevel}" ] || fail "MANIFEST.json names $top, not the system it was built from"
  [ "$(jq -r '.format' "$B/MANIFEST.json")" = "nanokvm-system-bundle/1" ] \
    || fail "the bundle does not declare the format the device installs"
  grep -qxF "${toplevel}" "$B/closure.txt" || fail "closure.txt does not list the toplevel"

  sort ${closure} > want.txt
  sort "$B/closure.txt" > have.txt
  diff -u want.txt have.txt \
    || fail "closure.txt is not the toplevel's closure -- a device would install a system with a hole in it"
  ok "closure.txt is exactly the toplevel's closure ($(wc -l < have.txt) paths)"
  [ "$(jq -r '.closureCount' "$B/MANIFEST.json")" = "$(wc -l < have.txt)" ] \
    || fail "closureCount disagrees with closure.txt"

  # ---- 5. every closure path is carried --------------------------------
  echo "=== every closure path is in the archive ==="
  sed -n 's|^${root}/store/\([^/]*\)$|\1|p' names.txt | sort -u > carried.txt
  sed 's|^/nix/store/||' have.txt | sort > needed.txt
  missing=$(comm -23 needed.txt carried.txt)
  [ -z "$missing" ] || { echo "$missing" >&2; fail "closure paths missing from the archive"; }
  extra=$(comm -13 needed.txt carried.txt)
  [ -z "$extra" ] || { echo "$extra" >&2; fail "the archive carries store paths outside the closure"; }
  ok "store/ carries exactly the closure, no more and no less"

  # ---- 6. the boot payload ---------------------------------------------
  echo "=== the boot payload ==="
  # shellcheck source=/dev/null
  . ${bootPayload}/NAMES
  bk=$(jq -r '.boot.kernel' "$B/MANIFEST.json")
  bf=$(jq -r '.boot.fdt'    "$B/MANIFEST.json")
  [ "$bk" = "$KERNEL" ] || fail "MANIFEST.json names kernel $bk, the payload is $KERNEL"
  [ "$bf" = "$FDT" ]    || fail "MANIFEST.json names dtb $bf, the payload is $FDT"
  [ "$(jq -r '.boot.kernelSha256' "$B/MANIFEST.json")" = "$KERNEL_SHA256" ] \
    || fail "the kernel hash in MANIFEST.json is not the kernel's"
  [ "$(jq -r '.boot.fdtSha256' "$B/MANIFEST.json")" = "$FDT_SHA256" ] \
    || fail "the dtb hash in MANIFEST.json is not the dtb's"
  ok "the manifest names the bundled kernel and dtb, with their real hashes"

  grep -qxF "${root}/boot/$KERNEL" names.txt || fail "the kernel is not in the archive"
  grep -qxF "${root}/boot/$FDT"    names.txt || fail "the dtb is not in the archive"
  ok "both are actually in the archive"

  # The kernel's name IS its hash -- that is what lets two extlinux configs name
  # two kernels, so the two must agree or the rollback names a file that is not
  # what it says it is.
  case "$KERNEL_SHA256" in
    "''${KERNEL#Image-}"*) ;;
    *) fail "the kernel's content-addressed name is not a prefix of its sha256" ;;
  esac
  ok "the kernel's name is a prefix of its own sha256"

  # The flashed image's config must name the same kernel the bundle ships, or a
  # freshly flashed board and an updated one would not be the same system.
  grep -q "LINUX /$KERNEL" ${bootPayload}/boot/extlinux/extlinux.conf \
    || fail "the /boot payload's config does not name the kernel it ships"
  ok "the shipped extlinux.conf names the same kernel"

  echo
  echo "the published bundle describes the system it was built from."
  touch "$out"
''
