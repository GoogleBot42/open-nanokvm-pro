{ pkgs
, lib ? pkgs.lib
, system-manifest
, toplevel
, version
, ...
}:

# ===========================================================================
# THE RELEASE MANIFEST, READ BACK (#100) -- `nix flake check`'s
# `nanokvm-system-manifest`.
#
# A release does two things: it pushes a closure to the binary cache and it
# publishes a manifest naming that closure's toplevel. Every device on the
# channel then tries to substitute exactly the path this file names. So the
# things worth asserting are the ones that would make that path wrong:
#
#   * it is the toplevel of the appliance THIS commit builds (not last
#     release's, not the loop variant's);
#   * the version is the version this commit is (release.yml greps for it, but
#     a check that runs on every `nix flake check` catches it a week earlier);
#   * the closure list beside it is the toplevel's real closure, so "what the
#     release pushed" is knowable without re-evaluating the flake.
#
# What it cannot check is that the cache actually HAS those paths -- that is
# the release job's `attic push`, and the device's `nix copy` is what finds out.
# ===========================================================================

let
  closure = pkgs.writeClosure [ toplevel ];
in
pkgs.runCommand "nanokvm-system-manifest-check"
{
  nativeBuildInputs = [ pkgs.jq pkgs.coreutils pkgs.diffutils ];
  meta.description =
    "Offline proof that the release manifest names this commit's appliance closure";
} ''
  set -euo pipefail
  mf=${system-manifest}/nanokvm_pro_sys_latest.json
  fail() { echo "FAIL: $*" >&2; exit 1; }
  ok()   { echo "  ok: $*"; }

  echo "=== the manifest a release publishes ==="
  cat "$mf"

  [ "$(jq -r '.format' "$mf")" = "nanokvm-nix-closure/1" ] \
    || fail "the manifest declares a format this appliance's updater does not install"
  ok "format is nanokvm-nix-closure/1"

  [ "$(jq -r '.version' "$mf")" = "${version}" ] \
    || fail "the manifest says version $(jq -r '.version' "$mf"), this tree is ${version}"
  ok "version is ${version}"

  [ "$(jq -r '.toplevel' "$mf")" = "${toplevel}" ] \
    || fail "the manifest names $(jq -r '.toplevel' "$mf"), not this commit's appliance (${toplevel})"
  ok "toplevel is this commit's appliance closure"

  # A device refuses anything that is not a store path, so the manifest must
  # never be able to carry one that is not.
  case "$(jq -r '.toplevel' "$mf")" in
    /nix/store/*) ok "toplevel is spelled as a store path" ;;
    *) fail "the toplevel is not a store path" ;;
  esac

  [ "$(jq -r '.size' "$mf")" -gt 0 ] || fail "the manifest reports a zero-byte closure"
  ok "size is $(jq -r '.size' "$mf") bytes of NAR (the UI's upper bound)"

  echo "=== the closure list beside it ==="
  sort ${system-manifest}/closure.txt > got.txt
  sort ${closure} > want.txt
  diff -u want.txt got.txt || fail "the published closure list is not the toplevel's closure"
  [ "$(jq -r '.closureCount' "$mf")" = "$(wc -l < got.txt)" ] \
    || fail "closureCount disagrees with the closure list"
  ok "$(wc -l < got.txt) paths, and the manifest counts them correctly"

  echo
  echo "the release manifest names this commit's appliance and nothing else."
  touch "$out"
''
