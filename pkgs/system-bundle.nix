{ pkgs
, lib ? pkgs.lib
, toplevel # the NixOS system closure this bundle installs
, version ? "0.0.0-dev"
, layout ? "minimal"
, manifestName ? "nanokvm_pro_sys_latest.json"
, payloadPrefix ? "nanokvm_pro_sys"
, ...
}:

# ===========================================================================
# THE SYSTEM BUNDLE -- what a release publishes for the NixOS appliance (#86).
#
# The appliance has no `nix` yet (#100), so an update cannot be a
# `nixos-rebuild` and cannot be a binary-cache fetch. It is this: the new
# toplevel's ENTIRE closure and the list of store paths that says what belongs
# to it. `nanokvm-update` on the device unpacks the paths it does not already
# have, makes the toplevel the system profile, and runs
# `switch-to-configuration boot`.
#
# THERE IS NO /boot HALF SINCE #99, and that is the point of the change. The
# kernel, the initrd and the device tree are part of the generation now, so
# they are ordinary store paths inside `closure.txt` -- and NixOS's own
# extlinux builder, run by `switch-to-configuration boot`, is the one thing
# that copies them into /boot. A bundle that carried them separately would be a
# second copy of the same bytes and a second writer of the same directory.
#
# TWO FILES ARE PUBLISHED, and their shape is the legacy OTA's on purpose:
#
#   nanokvm_pro_sys_latest.json   { version, name, sha512(base64), size }
#   nanokvm_pro_sys_<version>.tar.gz
#
# so the SERVER's download path -- fetch the manifest, fetch `name`, check the
# base64 SHA-512, untar -- is reused byte for byte and the web UI's update
# button needs no change at all. Only the manifest FILENAME differs from the
# 4.19 channel's, which is what stops a device being offered a payload its
# installer cannot apply.
#
# PAYLOAD LAYOUT (single top-level dir `nanokvm_pro_sys_<version>/`, which is
# what the server's UnTarGz hands to install()):
#
#   MANIFEST.json     format, version, toplevel, closure count
#   closure.txt       every store path in the toplevel's closure, one per line
#   store/<base>/     those store paths, as ordinary directories
#
# --hard-dereference IS LOAD-BEARING, and it is not an optimisation. The
# server's own extractor (server/utils/untar.go) handles TypeDir, TypeReg and
# TypeSymlink and SILENTLY IGNORES TypeLink -- so a tar that hardlinks two
# identical files in the closure would install one of them and leave the other
# missing, with no error anywhere and a generation that dies on a file that is
# not there. Dereferencing them costs a little size and removes the failure
# mode; the assertion below is what keeps it true.
#
# WHY THE WHOLE CLOSURE, EVERY TIME. See docs/updates.md, "Weighed and
# rejected": a delta needs the builder to know what the device already has, and
# the honest ways to get that (a binary cache, or a device-reported closure)
# both mean putting a nar-fetching client -- effectively nix -- back on the
# appliance. The device skips the paths it already has, so the cost is
# bandwidth, not eMMC writes.
# ===========================================================================

let
  closure = pkgs.writeClosure [ toplevel ];
  root = "${payloadPrefix}_${version}";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-system-bundle";
  inherit version;

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = with pkgs; [ gnutar gzip coreutils openssl jq gnugrep ];

  buildPhase = ''
    runHook preBuild
    set -euo pipefail

    mkdir -p "${root}/store"

    # ---- 1. the closure -------------------------------------------------
    cp ${closure} "${root}/closure.txt"
    n=$(wc -l < "${root}/closure.txt")
    echo "=== staging $n store paths ==="
    grep -qxF "${toplevel}" "${root}/closure.txt" \
      || { echo "ERROR: writeClosure did not list the toplevel itself" >&2; exit 1; }

    while read -r p; do
      [ -n "$p" ] || continue
      cp -a "$p" "${root}/store/$(basename "$p")"
    done < "${root}/closure.txt"
    chmod -R u+w "${root}/store"

    staged=$(find "${root}/store" -mindepth 1 -maxdepth 1 | wc -l)
    [ "$staged" = "$n" ] \
      || { echo "ERROR: staged $staged of $n closure paths" >&2; exit 1; }

    # THE KERNEL IS IN THERE, as a store path like any other (#99). Assert it,
    # because a bundle whose generation has no kernel installs a system the
    # extlinux builder cannot write a boot entry for -- and the board finds
    # that out with no console.
    grep -q "$(readlink -f ${toplevel}/kernel | sed 's|/Image$||')" "${root}/closure.txt" \
      || { echo "ERROR: the toplevel's kernel is not in the closure" >&2; exit 1; }
    echo "kernel: $(readlink -f ${toplevel}/kernel) ($(stat -Lc%s ${toplevel}/kernel) B)"
    echo "initrd: $(readlink -f ${toplevel}/initrd) ($(stat -Lc%s ${toplevel}/initrd) B)"

    # ---- 2. the bundle manifest ------------------------------------------
    jq -n \
      --arg version   "${version}" \
      --arg toplevel  "${toplevel}" \
      --arg layout    "${layout}" \
      --argjson count "$n" \
      '{ format: "nanokvm-system-bundle/1",
         version: $version,
         toplevel: $toplevel,
         layout: $layout,
         closureCount: $count }' \
      > "${root}/MANIFEST.json"
    cat "${root}/MANIFEST.json"

    # ---- 3. the tarball, and the manifest the device polls ---------------
    # Deterministic: sorted, no owner names, epoch mtimes. --hard-dereference
    # because the server's extractor drops hardlink entries on the floor.
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@1 \
        --hard-dereference \
        -czf "${payloadPrefix}_${version}.tar.gz" "${root}"

    # The assertion that keeps the above honest: not one 'h' (hardlink) entry.
    echo "=== checking the archive carries no hardlink entries ==="
    if tar -tvzf "${payloadPrefix}_${version}.tar.gz" | grep -q '^h'; then
      echo "ERROR: the bundle contains hardlink entries. The device-side" >&2
      echo "       extractor (server/utils/untar.go) ignores them silently," >&2
      echo "       so those files would simply not be installed." >&2
      exit 1
    fi

    b64=$(openssl dgst -sha512 -binary "${payloadPrefix}_${version}.tar.gz" | base64 -w0)
    size=$(stat -c%s "${payloadPrefix}_${version}.tar.gz")
    printf '{\n  "version": "%s",\n  "name": "%s",\n  "sha512": "%s",\n  "size": %s\n}\n' \
      "${version}" "${payloadPrefix}_${version}.tar.gz" "$b64" "$size" > "${manifestName}"
    cat "${manifestName}"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp "${payloadPrefix}_${version}.tar.gz" "${manifestName}" "$out/"
    # Kept unpacked beside the tarball so `nix flake check` and a hardware run
    # can read the manifest without unpacking half a gigabyte.
    cp "${root}/MANIFEST.json" "$out/MANIFEST.json"
    cp "${root}/closure.txt"   "$out/closure.txt"
    echo "System bundle v${version}:"; ls -l "$out"
    runHook postInstall
  '';

  meta = {
    description =
      "NanoKVM-Pro NixOS system bundle (#86): the appliance's whole system closure -- kernel included, as a store path -- plus the manifest a device polls";
    platforms = [ "x86_64-linux" ];
  };
}
