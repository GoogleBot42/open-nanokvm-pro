{ pkgs, base-axp, kvm-encoder, kernel, ax-ko-blobs
, nanokvm-server, nanokvm-web
, version ? "0.0.0-dev"   # stamped into /kvmapp/version; the update baseline
, ...
}:

# ===========================================================================
# Root filesystem -- OVERLAY approach (vendor Ubuntu-arm64 base + our bits).
#
# Base  : ubuntu_rootfs_sparse.ext4, extracted from the pinned vendor release
#         .axp (pkgs/base-axp.nix). This IS vendor Ubuntu -- not from-source.
# Swap-in (from source / our derivations):
#   - libkvm.so / libkvm.so.0  -> /kvmapp/server/dl_lib/   (our HW encoder)
#   - /lib/modules/4.19.125/   -> our from-source kernel modules (incl.
#       lt6911_manage.ko) MERGED with the prebuilt ax_*.ko blobs, then depmod'd.
#   Everything else stays vendor (app server + web already live in /kvmapp).
#
# ---------------------------------------------------------------------------
# NO-ROOT ext4 SURGERY:  a Nix build sandbox has no sudo / mount / loop, so the
# vendor build_image.py chroot+mount flow cannot run here. Instead we edit the
# ext4 IN PLACE with `debugfs -w` (write/rm/mkdir/sif) -- pure userspace, no
# privileges. `sif <path> uid/gid 0` restores root ownership after each write
# (debugfs writes as the build user otherwise).
#
# depmod: run on a HOST staging tree (`depmod -b stage 4.19.125`); the generated
# modules.dep/.alias/.symbols(.bin) are written into the image alongside the
# .ko, so module autoloading works on the target with no on-device depmod.
# ===========================================================================

let
  release = "4.19.125";
  # /lib/modules/<rel>/kernel/axera/ -- where we drop the prebuilt ax_*.ko so the
  # regenerated modules.dep references a single, self-consistent location.
  axSubdir = "kernel/axera";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-pro-rootfs";
  version = "ubuntu-arm64-overlay-v1";

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = with pkgs; [
    unzip
    e2fsprogs # debugfs, e2fsck, resize2fs, mke2fs
    android-tools # simg2img / img2simg (Android sparse <-> raw ext4)
    kmod # depmod
  ];

  buildPhase = ''
    runHook preBuild
    set -euo pipefail

    # ---- 1. extract the vendor rootfs (sparse ext4) from the base .axp ZIP ----
    echo "=== [1] extract ubuntu_rootfs_sparse.ext4 from base .axp ==="
    unzip -o "${base-axp}" ubuntu_rootfs_sparse.ext4 -d .
    test -f ubuntu_rootfs_sparse.ext4

    # ---- 2. de-sparse to a raw, writable ext4 ----
    echo "=== [2] simg2img (Android sparse -> raw ext4) ==="
    simg2img ubuntu_rootfs_sparse.ext4 rootfs.ext4
    rm -f ubuntu_rootfs_sparse.ext4

    # ---- 3. grow +256M so the overlay always has room (build_image.py grows
    #         +512M; our overlay is smaller) ----
    echo "=== [3] grow raw ext4 by 256M + resize2fs ==="
    dd if=/dev/zero bs=1M count=256 >> rootfs.ext4
    e2fsck -fy rootfs.ext4 || true
    resize2fs rootfs.ext4

    # ---- 4. build the merged /lib/modules tree and depmod it (host) ----
    echo "=== [4] merge kernel modules + ax_*.ko, depmod ==="
    stage="$PWD/stage"
    mkdir -p "$stage/lib/modules/${release}"
    cp -a "${kernel}/lib/modules/${release}/." "$stage/lib/modules/${release}/"
    chmod -R u+w "$stage"
    mkdir -p "$stage/lib/modules/${release}/${axSubdir}"
    cp "${ax-ko-blobs}"/lib/modules/ax/*.ko "$stage/lib/modules/${release}/${axSubdir}/"
    echo "  merged .ko count: $(find "$stage" -name '*.ko' | wc -l)"
    depmod -b "$stage" "${release}"
    grep -Eq 'ax_venc\.ko:.*ax_base' "$stage/lib/modules/${release}/modules.dep" \
      || { echo "ERROR: depmod did not resolve ax_venc -> ax_base" >&2; exit 1; }
    grep -q 'lt6911_manage' "$stage/lib/modules/${release}/modules.dep" \
      || { echo "ERROR: lt6911_manage missing from merged modules.dep" >&2; exit 1; }

    # ---- 5. generate a debugfs command script for the whole overlay ----
    echo "=== [5] generate debugfs overlay script ==="
    script="$PWD/overlay.debugfs"
    : > "$script"

    # Helper appended lines set root ownership + mode after each write.
    emit_file() {  # <src-host-path> <dest-image-path> <mode>
      echo "rm $2" >> "$script"          # ignore-if-absent (debugfs continues)
      echo "write $1 $2" >> "$script"
      echo "sif $2 uid 0" >> "$script"
      echo "sif $2 gid 0" >> "$script"
      echo "sif $2 mode $3" >> "$script"
    }

    # 5a. libkvm swap. Assert the vendor dl_lib dir exists first (fail loud if
    # the vendor layout moved, instead of silently creating a dead file).
    if ! debugfs -R "stat /kvmapp/server/dl_lib" rootfs.ext4 >/dev/null 2>&1; then
      echo "ERROR: /kvmapp/server/dl_lib missing in vendor rootfs -- layout changed" >&2
      exit 1
    fi
    emit_file "${kvm-encoder}/lib/libkvm.so"   "/kvmapp/server/dl_lib/libkvm.so"   0100755
    emit_file "${kvm-encoder}/lib/libkvm.so.0" "/kvmapp/server/dl_lib/libkvm.so.0" 0100755

    # 5a2. OUR from-source app: patched NanoKVM-Server + web UI + version stamp.
    # This makes the flashed image RUN our server (whose update check targets our
    # host, not Sipeed's CDN -- see pkgs/nanokvm-server.nix + docs/updates.md),
    # served with our web bundle. /kvmapp/version is the update baseline the web
    # UI compares against.
    emit_file "${nanokvm-server}/bin/NanoKVM-Server" "/kvmapp/server/NanoKVM-Server" 0100755
    ( cd "${nanokvm-web}" && find . -type d ) | while read -r d; do
      echo "mkdir /kvmapp/server/web/''${d#./}" >> "$script"   # existing dirs: harmless
    done
    ( cd "${nanokvm-web}" && find . -type f ) | while read -r f; do
      emit_file "${nanokvm-web}/''${f#./}" "/kvmapp/server/web/''${f#./}" 0100644
    done
    printf '%s\n' "${version}" > "$PWD/kvmapp-version"
    emit_file "$PWD/kvmapp-version" "/kvmapp/version" 0100644

    # 5b. modules tree: mkdir all dirs (parent-first), then write every file.
    ( cd "$stage" && find lib/modules/${release} -type d ) | while read -r d; do
      echo "mkdir /$d" >> "$script"       # errors on existing dirs are harmless
    done
    ( cd "$stage" && find lib/modules/${release} -type f ) | while read -r f; do
      case "$f" in
        *.ko) mode=0100644 ;;
        *)    mode=0100644 ;;             # modules.dep/.alias/.symbols(.bin)
      esac
      emit_file "$stage/$f" "/$f" "$mode"
    done

    # 5c. systemd stack selection.
    # The pinned vendor base ships TWO independent KVM app stacks and enables the
    # WRONG one for our purposes:
    #   * kvmapp  (nanokvm.service)  -> NanoKVM-Server serves the web KVM and loads
    #     OUR open libkvm.so for capture/encode. This is our from-source deliverable.
    #   * kvmcomm (kvmcomm.service)  -> the vendor's newer kvm_vin + kvm_ui pipeline
    #     that talks to the Axera libs directly (no libkvm) and tries to hand the
    #     web UI to PiKVM's kvmd. On this base kvmd is disabled+inactive, so kvmcomm
    #     serves NO web interface, and its kvm_vin/kvm_ui contend with our libkvm for
    #     the single MIPI_RX/VENC pipeline. The vendor enables kvmcomm by default.
    # So: disable kvmcomm, enable nanokvm (symlink in multi-user.target.wants). This
    # is what makes a FRESH FLASH boot straight into our open stack with a working
    # web KVM -- without it the device comes up on kvmcomm with no web UI.
    wants="/etc/systemd/system/multi-user.target.wants"
    {
      echo "rm $wants/kvmcomm.service"     # disable vendor stack (ignore-if-absent)
      echo "rm $wants/nanokvm.service"     # clear any stale link before re-creating
      echo "symlink $wants/nanokvm.service /etc/systemd/system/nanokvm.service"
      echo "sif $wants/nanokvm.service uid 0"
      echo "sif $wants/nanokvm.service gid 0"
    } >> "$script"

    # ---- 6. apply overlay in a single debugfs -w pass ----
    echo "=== [6] apply overlay (debugfs -w) ==="
    debugfs -w -f "$script" rootfs.ext4 > debugfs.log 2>&1 || {
      echo "ERROR: debugfs overlay failed; tail of log:" >&2; tail -40 debugfs.log >&2; exit 1;
    }
    # Sanity: our libkvm must now be in the image and match ours byte-for-byte.
    debugfs -R "dump /kvmapp/server/dl_lib/libkvm.so.0 /tmp/chk.so" rootfs.ext4 2>/dev/null
    cmp -s /tmp/chk.so "${kvm-encoder}/lib/libkvm.so.0" \
      || { echo "ERROR: libkvm.so.0 in image != our build" >&2; exit 1; }
    echo "  libkvm.so.0 verified in image."

    # Sanity: OUR stack is enabled and the vendor kvmcomm stack is disabled.
    debugfs -R "stat $wants/nanokvm.service" rootfs.ext4 2>/dev/null | grep -q "Type: symlink" \
      || { echo "ERROR: nanokvm.service not enabled (symlink missing) in image" >&2; exit 1; }
    # NB: debugfs `stat` exits 0 even for a missing path ("File not found"), so
    # test the OUTPUT (an "Inode:" line only appears when the entry exists).
    if debugfs -R "stat $wants/kvmcomm.service" rootfs.ext4 2>/dev/null | grep -q "Inode:"; then
      echo "ERROR: kvmcomm.service still enabled in image (should be disabled)" >&2; exit 1
    fi
    echo "  systemd stack: nanokvm enabled, kvmcomm disabled -- verified in image."

    # Sanity: our server binary + version stamp are in the image.
    debugfs -R "dump /kvmapp/server/NanoKVM-Server /tmp/chk.srv" rootfs.ext4 2>/dev/null
    cmp -s /tmp/chk.srv "${nanokvm-server}/bin/NanoKVM-Server" \
      || { echo "ERROR: NanoKVM-Server in image != our build" >&2; exit 1; }
    debugfs -R "cat /kvmapp/version" rootfs.ext4 2>/dev/null | grep -qx "${version}" \
      || { echo "ERROR: /kvmapp/version in image != ${version}" >&2; exit 1; }
    echo "  app: our NanoKVM-Server + /kvmapp/version=${version} -- verified in image."

    # ---- 7. fsck + re-sparse ----
    echo "=== [7] e2fsck + img2simg (raw -> sparse) ==="
    e2fsck -fy rootfs.ext4 || true
    img2simg rootfs.ext4 ubuntu_rootfs_sparse.ext4

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp ubuntu_rootfs_sparse.ext4 "$out/ubuntu_rootfs_sparse.ext4"   # for the .axp (image.nix)
    cp rootfs.ext4               "$out/ubuntu_rootfs.ext4"          # raw (dd / inspection)
    cat > "$out/OVERLAY-NOTES.txt" <<EOF
    NanoKVM-Pro rootfs -- vendor Ubuntu-arm64 base + our overlay.

    base            : ubuntu_rootfs_sparse.ext4 from vendor .axp (pkgs/base-axp.nix)
    swapped in:
      /kvmapp/server/dl_lib/libkvm.so{,.0}   <- our kvm-encoder (from source)
      /lib/modules/${release}/               <- our kernel modules (incl.
                                                lt6911_manage.ko) + prebuilt
                                                ax_*.ko, depmod-regenerated
    method          : debugfs -w in-place edit (no root), sif uid/gid 0 to keep
                      root ownership; depmod -b on a host staging tree.
    outputs         : ubuntu_rootfs_sparse.ext4 (for the .axp), ubuntu_rootfs.ext4 (raw)
    EOF
    echo "Installed:"; ls -l "$out"
    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro rootfs: vendor Ubuntu-arm64 base overlaid (no-root debugfs) with our libkvm.so + merged/depmod'd kernel modules";
    platforms = pkgs.lib.platforms.linux;
  };
}
