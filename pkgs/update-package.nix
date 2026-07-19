{ pkgs, nanokvm-server, nanokvm-web, kvm-encoder, version ? "0.0.0-dev", ... }:

# ---------------------------------------------------------------------------
# Web-update package -- the artifact the on-device NanoKVM-Server downloads when
# the user clicks "update" in the web UI. Our server is patched (see
# pkgs/nanokvm-server.nix) to fetch from OUR host instead of Sipeed's CDN and to
# apply a plain /kvmapp overlay (NOT vendor .deb packages), so the format here is
# ours to define. See docs/updates.md.
#
# This derivation emits TWO files, both published as GitHub Release assets:
#   nanokvm_pro_<version>.tar.gz  -- the payload (top dir nanokvm_pro_<version>/
#                                    containing a kvmapp/ tree overlaid onto the
#                                    device's /kvmapp)
#   nanokvm_pro_latest.json       -- the manifest the server polls:
#                                    { version, name, sha512(base64), size }
#
# PROTOCOL CONTRACT (must match server/service/application + our install override):
#   - manifest `version` MUST be valid semver and greater than the device's
#     /kvmapp/version for the web UI (semver.gt) to offer the update.
#   - `sha512` is base64(StdEncoding) of the RAW SHA-512 digest of the tarball
#     (NOT hex) -- the server enforces it (checksum()).
#   - the tarball's single top-level dir is `nanokvm_pro_<version>/`; UnTarGz
#     returns its path and our install() copies `<dir>/kvmapp/.` over /kvmapp.
# ---------------------------------------------------------------------------

pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-update-package";
  inherit version;

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = [ pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.openssl ];

  buildPhase = ''
    runHook preBuild
    set -euo pipefail

    root="nanokvm_pro_${version}"
    app="$root/kvmapp"
    mkdir -p "$app/server/dl_lib" "$app/server/web"

    # --- payload: our patched server + web + libkvm + version stamp ---
    cp ${nanokvm-server}/bin/NanoKVM-Server "$app/server/NanoKVM-Server"
    cp ${kvm-encoder}/lib/libkvm.so         "$app/server/dl_lib/libkvm.so"
    cp ${kvm-encoder}/lib/libkvm.so.0       "$app/server/dl_lib/libkvm.so.0"
    cp -r ${nanokvm-web}/.                   "$app/server/web/"
    printf '%s\n' "${version}"             > "$app/version"
    chmod -R u+w "$root"

    # --- deterministic tarball ---
    tarball="nanokvm_pro_${version}.tar.gz"
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
        -czf "$tarball" "$root"

    # --- manifest: base64(StdEncoding) of the RAW sha-512 digest (NOT hex) ---
    b64=$(openssl dgst -sha512 -binary "$tarball" | base64 -w0)
    size=$(stat -c%s "$tarball")
    printf '{\n  "version": "%s",\n  "name": "%s",\n  "sha512": "%s",\n  "size": %s\n}\n' \
      "${version}" "$tarball" "$b64" "$size" > nanokvm_pro_latest.json

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp "nanokvm_pro_${version}.tar.gz" nanokvm_pro_latest.json "$out/"
    echo "Update package for v${version}:"; ls -l "$out"
    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro web-update package (tarball + manifest) served from our own Releases";
    platforms = pkgs.lib.platforms.linux;
  };
}
