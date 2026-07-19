{ pkgs, nanokvm-server, nanokvm-web, kvm-encoder, kernel, ax-ko-blobs
, boot, dtb-slot-image, kernel-slot-image
, version ? "0.0.0-dev", ... }:

# ---------------------------------------------------------------------------
# Full-firmware OTA update package -- the artifact the on-device NanoKVM-Server
# downloads when the user clicks "update" in the web UI. Our server is patched
# (see pkgs/nanokvm-server.nix + pkgs/nanokvm-server/install-override.go.in) to
# fetch from OUR host and apply this payload directly, so the format is ours to
# define. See docs/updates.md.
#
# Emits TWO files, both published as GitHub Release assets:
#   nanokvm_pro_<version>.tar.gz  -- the payload (see LAYOUT below)
#   nanokvm_pro_latest.json       -- the manifest the server polls:
#                                    { version, name, sha512(base64), size }
#
# ---------------------------------------------------------------------------
# PAYLOAD LAYOUT  (top dir `nanokvm_pro_<version>/`):
#
#   rootfs/          overlay copied verbatim over / on the device (`cp -a rootfs/. /`):
#     kvmapp/server/NanoKVM-Server              our from-source server binary
#     kvmapp/server/dl_lib/libkvm.so{,.0}       our HW capture/encode backend
#     kvmapp/server/web/...                      our web UI bundle
#     kvmapp/version                             the OTA baseline stamp
#     usr/lib/modules/4.19.125/...               FULL modules tree: our from-source
#                                                modules MERGED with the prebuilt
#                                                ax_*.ko (under kernel/axera/), then
#                                                depmod'd at BUILD time so
#                                                modules.dep/.alias/.symbols(.bin)
#                                                ship pre-generated (no on-device
#                                                depmod). Under usr/lib/modules (NOT
#                                                lib/modules) to match the device's
#                                                real path -- /lib is a symlink to
#                                                usr/lib. Mirrors pkgs/rootfs.nix [4].
#     etc/modules-load.d/nanokvm.conf            autoloads lt6911_manage at boot
#                                                (systemd-modules-load) -- libkvm
#                                                needs it; nothing else loads it.
#
#   partitions/      vendor-format SIGNED partition images (magic 0x55543322 @ off 4),
#                    fixed naming contract consumed by install()'s image->partition map:
#     uboot_a.img  <- ${boot}/images/u-boot_signed.bin
#     uboot_b.img  <- ${boot}/images/u-boot_b_signed.bin
#     atf_a.img    <- ${boot}/images/atf_bl31_signed.bin
#     atf_b.img    <- ${boot}/images/atf_b_bl31_signed.bin
#     optee.img    <- ${boot}/images/optee_signed.bin      (same image -> optee + optee_b)
#     dtb.img      <- ${dtb-slot-image}/..._signed.dtb      (same image -> dtb + dtb_b)
#     kernel.img   <- ${kernel-slot-image}/kernel_b.bin     (same image -> kernel + kernel_b)
#
#   NOTE: SPL (p1), ddrinit (p2), env (p7), logo (p10/11) and the base rootfs
#   (p17) are deliberately NOT shipped by OTA -- they change only by re-flashing
#   the .axp over AXDL. See docs/updates.md.
#
# ---------------------------------------------------------------------------
# PROTOCOL CONTRACT (unchanged; must match server/service/application + our
# install override):
#   - manifest `version` MUST be valid semver and greater than the device's
#     /kvmapp/version for the web UI (semver.gt) to offer the update.
#   - `sha512` is base64(StdEncoding) of the RAW SHA-512 digest of the tarball
#     (NOT hex) -- the server enforces it (checksum()).
#   - the tarball's single top-level dir is `nanokvm_pro_<version>/`; UnTarGz
#     returns its path and our install() consumes <dir>/rootfs and <dir>/partitions.
# ---------------------------------------------------------------------------

let
  release = "4.19.125";
  # usr/lib/modules/<rel>/kernel/axera/ -- where the prebuilt ax_*.ko land so the
  # regenerated modules.dep references one self-consistent location (same as rootfs.nix).
  axSubdir = "kernel/axera";
  # dtb-slot-image artifact filename (pkgs/slot-image.nix `artifact` for the dtb call).
  dtbArtifact = "AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-update-package";
  inherit version;

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = [
    pkgs.gnutar pkgs.gzip pkgs.coreutils pkgs.openssl
    pkgs.kmod   # depmod (build the modules tree) + modinfo (vermagic assertion)
  ];

  buildPhase = ''
    runHook preBuild
    set -euo pipefail

    root="nanokvm_pro_${version}"
    rfs="$root/rootfs"
    parts="$root/partitions"
    app="$rfs/kvmapp"
    mkdir -p "$app/server/dl_lib" "$app/server/web" "$parts"

    # ===================================================================
    # 1. rootfs/ overlay -- our app tree + version stamp
    # ===================================================================
    cp ${nanokvm-server}/bin/NanoKVM-Server "$app/server/NanoKVM-Server"
    cp ${kvm-encoder}/lib/libkvm.so         "$app/server/dl_lib/libkvm.so"
    cp ${kvm-encoder}/lib/libkvm.so.0       "$app/server/dl_lib/libkvm.so.0"
    cp -r ${nanokvm-web}/.                   "$app/server/web/"
    printf '%s\n' "${version}"             > "$app/version"

    # ===================================================================
    # 2. rootfs/usr/lib/modules/${release} -- merged, depmod'd at BUILD time
    #    (replicates pkgs/rootfs.nix step [4]). Under usr/lib/modules (NOT
    #    lib/modules) to match the device's real path: /lib is a symlink to
    #    usr/lib, so this is where modprobe/depmod actually resolve.
    # ===================================================================
    echo "=== merge kernel modules + ax_*.ko, depmod ==="
    modroot="$rfs/usr/lib/modules/${release}"
    mkdir -p "$modroot"
    cp -a "${kernel}/lib/modules/${release}/." "$modroot/"
    chmod -R u+w "$rfs/usr/lib/modules"
    mkdir -p "$modroot/${axSubdir}"
    cp "${ax-ko-blobs}"/lib/modules/ax/*.ko "$modroot/${axSubdir}/"
    echo "  merged .ko count: $(find "$modroot" -name '*.ko' | wc -l)"
    # depmod against the modules PARENT (-b <dir> expects <dir>/lib/modules/<rel>);
    # our tree lives at <rfs>/usr/lib/modules/<rel>, so the base is <rfs>/usr.
    depmod -b "$rfs/usr" "${release}"

    # --- module assertions (fail LOUDLY in-build, never on the device) ---
    # (b) vermagic consistency: the release string in a couple of shipped .ko must
    #     match the modules directory name (${release}). Guards against ever
    #     packaging modules built for a different kernel than the dir claims.
    for ko in \
      "$(find "$modroot" -name 'lt6911_manage.ko' | head -1)" \
      "$(find "$modroot" -name 'ax_venc.ko'       | head -1)" \
      ; do
      test -n "$ko" && test -f "$ko" || { echo "ERROR: expected module missing for vermagic check" >&2; exit 1; }
      vm=$(modinfo -F vermagic "$ko")
      echo "  vermagic($(basename "$ko")) = $vm"
      case "$vm" in
        "${release} "*) ;;   # e.g. "4.19.125 SMP preempt mod_unload aarch64"
        *) echo "ERROR: vermagic '$vm' does not match modules dir ${release}" >&2; exit 1 ;;
      esac
    done
    # (c) modules.dep exists and resolves our two marker modules.
    test -f "$modroot/modules.dep" || { echo "ERROR: modules.dep not generated" >&2; exit 1; }
    grep -Eq 'ax_venc\.ko:.*ax_base' "$modroot/modules.dep" \
      || { echo "ERROR: depmod did not resolve ax_venc -> ax_base" >&2; exit 1; }
    grep -q 'lt6911_manage' "$modroot/modules.dep" \
      || { echo "ERROR: lt6911_manage missing from merged modules.dep" >&2; exit 1; }

    # --- autoload lt6911_manage at boot (mirrors pkgs/rootfs.nix step [5b2]).
    # Nothing on the vendor rootfs loads it for the kvmapp/nanokvm stack, yet
    # libkvm polls /proc/lt6911_info/*. systemd-modules-load.service modprobes
    # entries here at boot; modprobe resolves it via the modules.dep above.
    mkdir -p "$rfs/etc/modules-load.d"
    printf '# NanoKVM-Pro: load HDMI-capture bridge driver at boot (libkvm needs it).\nlt6911_manage\n' \
      > "$rfs/etc/modules-load.d/nanokvm.conf"

    # ===================================================================
    # 3. partitions/ -- vendor-format signed images, fixed naming contract
    # ===================================================================
    echo "=== stage signed partition images ==="
    cp "${boot}/images/u-boot_signed.bin"      "$parts/uboot_a.img"
    cp "${boot}/images/u-boot_b_signed.bin"    "$parts/uboot_b.img"
    cp "${boot}/images/atf_bl31_signed.bin"    "$parts/atf_a.img"
    cp "${boot}/images/atf_b_bl31_signed.bin"  "$parts/atf_b.img"
    cp "${boot}/images/optee_signed.bin"       "$parts/optee.img"
    cp "${dtb-slot-image}/${dtbArtifact}"      "$parts/dtb.img"
    cp "${kernel-slot-image}/kernel_b.bin"     "$parts/kernel.img"

    # (a) every partitions/ image must carry the AX boot header magic 0x55543322
    #     at byte offset 4 (LE bytes 22 33 54 55). A corrupt/mistyped image here
    #     would brick a slot on the device -- fail the build instead.
    for f in "$parts/"*.img; do
      magic=$(od -An -tx1 -j4 -N4 "$f" | tr -d ' ')
      if [ "$magic" != "22335455" ]; then
        echo "ERROR: $f bad header magic ($magic != 22335455)" >&2
        exit 1
      fi
    done
    echo "  partition images OK: $(ls -1 "$parts" | tr '\n' ' ')"

    chmod -R u+w "$root"

    # ===================================================================
    # 4. deterministic tarball + manifest (protocol UNCHANGED)
    # ===================================================================
    tarball="nanokvm_pro_${version}.tar.gz"
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 \
        -czf "$tarball" "$root"

    # manifest: base64(StdEncoding) of the RAW sha-512 digest (NOT hex).
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
    description = "NanoKVM-Pro full-firmware OTA package (rootfs overlay + signed A/B partition images + manifest) served from our own Releases";
    # partitions/ images come from x86_64-only derivations (ax_gzip prebuilt), so
    # this package inherits that platform constraint transitively.
    platforms = [ "x86_64-linux" ];
  };
}
