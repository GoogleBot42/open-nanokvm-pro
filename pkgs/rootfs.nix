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
#   - /usr/lib/modules/4.19.125/ -> our from-source kernel modules (incl.
#       lt6911_manage.ko) MERGED with the prebuilt ax_*.ko blobs, then depmod'd.
#   - /etc/modules-load.d/nanokvm.conf -> makes systemd-modules-load.service
#       modprobe lt6911_manage at boot (nothing on the vendor rootfs loads it
#       for the kvmapp/nanokvm stack, yet libkvm polls /proc/lt6911_info/*).
#   Everything else stays vendor (app server + web already live in /kvmapp).
# Also hardened in the overlay:
#   - motd-news DISABLED: /etc/default/motd-news ENABLED=0 kills the Ubuntu
#       motd.ubuntu.com news beacon (50-motd-news phones home on login/timer).
#   - inert CLOSED vendor binaries REMOVED: the disabled kvmcomm stack's closed
#       kvm_ui/kvm_vin/frameforge + its display .ko, and the vendor swupdate
#       self-updater. Exact paths only (debugfs has no recursive rm); the live
#       kvmcomm scripts/edid/lt6911_manage.ko and swupdate fw_printenv/fw_setenv
#       are KEPT. See docs/provenance.md.
#
# ---------------------------------------------------------------------------
# /lib SYMLINK PITFALL (this bug shipped once -- do NOT reintroduce it):
# On the vendor Ubuntu-arm64 rootfs, `/lib` is a SYMLINK to `usr/lib` and
# debugfs CANNOT traverse symlinks. Writing the modules tree under `/lib/...`
# therefore fails SILENTLY (debugfs continues past per-command errors), leaving
# NO /lib/modules on the target -> lt6911_manage.ko never loads -> HDMI capture
# dead. So we write to the REAL path `/usr/lib/modules/...` (which /lib->usr/lib
# resolves to at runtime, so modprobe/depmod still find it), we `mkdir` every
# missing ancestor (`/usr/lib/modules`) parent-first (debugfs never creates
# ancestors on its own), and step [6] now cmp-verifies the modules tree lands.
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
  # modules/<rel>/kernel/axera/ -- where we drop the prebuilt ax_*.ko so the
  # regenerated modules.dep references a single, self-consistent location.
  # (Staged under lib/modules on the host; written to /usr/lib/modules in the image.)
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

    # 5b. modules tree -> REAL path /usr/lib/modules (NOT /lib: /lib is a symlink
    # to usr/lib and debugfs cannot traverse symlinks -- writing under /lib fails
    # SILENTLY; see the /lib SYMLINK PITFALL note in the header). At runtime
    # /lib->usr/lib resolves so modprobe/depmod still find these.
    # debugfs never creates missing ancestors, so mkdir them parent-first:
    # /usr and /usr/lib already exist on the vendor rootfs; /usr/lib/modules does
    # not -- create it, then every staged dir (find order is already parent-first).
    echo "mkdir /usr/lib/modules" >> "$script"   # existing dir: harmless
    ( cd "$stage" && find lib/modules/${release} -type d ) | while read -r d; do
      echo "mkdir /usr/$d" >> "$script"   # errors on existing dirs are harmless
    done
    ( cd "$stage" && find lib/modules/${release} -type f ) | while read -r f; do
      case "$f" in
        *.ko) mode=0100644 ;;
        *)    mode=0100644 ;;             # modules.dep/.alias/.symbols(.bin)
      esac
      emit_file "$stage/$f" "/usr/$f" "$mode"
    done

    # 5b2. autoload lt6911_manage at boot. NOTHING on the vendor rootfs loads it
    # for the kvmapp/nanokvm stack (the vendor loads ax_*.ko from /soc/ko via init
    # scripts; lt6911_manage only appears under /kvmcomm/ko for the disabled
    # kvmcomm stack) -- yet libkvm polls /proc/lt6911_info/*. Drop a
    # modules-load.d entry so systemd-modules-load.service modprobes it at boot;
    # modprobe now works because modules.dep landed under /usr/lib/modules above.
    # /etc/modules-load.d exists on Ubuntu -- assert it (like dl_lib) and mkdir
    # belt-and-braces (mkdir on an existing dir is harmless).
    if ! debugfs -R "stat /etc/modules-load.d" rootfs.ext4 >/dev/null 2>&1; then
      echo "ERROR: /etc/modules-load.d missing in vendor rootfs -- layout changed" >&2
      exit 1
    fi
    echo "mkdir /etc/modules-load.d" >> "$script"   # existing dir: harmless
    printf '# NanoKVM-Pro: load HDMI-capture bridge driver at boot (libkvm needs it).\nlt6911_manage\n' \
      > "$PWD/nanokvm-modules-load.conf"
    emit_file "$PWD/nanokvm-modules-load.conf" "/etc/modules-load.d/nanokvm.conf" 0100644

    # 5b3. Disable the Ubuntu motd-news beacon. The vendor Ubuntu base ships
    # /etc/update-motd.d/50-motd-news, which phones home to motd.ubuntu.com on
    # login/timer to fetch Canonical "news". Drop /etc/default/motd-news with
    # ENABLED=0 so it never reaches out. /etc/default exists on Ubuntu; mkdir is
    # belt-and-braces (harmless on an existing dir).
    echo "mkdir /etc/default" >> "$script"   # existing dir: harmless
    printf '# Disabled in open-nanokvm-pro: no Canonical motd news beacon (motd.ubuntu.com).\nENABLED=0\n' \
      > "$PWD/motd-news"
    emit_file "$PWD/motd-news" "/etc/default/motd-news" 0100644

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

    # 5d. remove inert closed kvmcomm binaries + vendor swupdate -- see
    # docs/provenance.md. These belong to the disabled kvmcomm stack (5c: the
    # vendor's closed kvm_vin/kvm_ui/frameforge pipeline + its display .ko) and to
    # the vendor swupdate self-updater (we ship our own updater). With kvmcomm
    # disabled they never run, so drop the closed blobs from the image. debugfs
    # has no recursive remove, so these are EXACT file paths; `rm` silently
    # continues if a path is already absent.
    # KEEP (live deps -- do NOT add here): /kvmcomm/scripts/*, /kvmcomm/edid/*,
    # /kvmcomm/ko/lt6911_manage.ko, and /opt/swupdate/bin/fw_printenv|fw_setenv
    # (used by S99checkboot).
    for dead in \
      /kvmcomm/ui/kvm_ui \
      /kvmcomm/ui/frameforge \
      /kvmcomm/vin/kvm_vin \
      /kvmcomm/ko/fbtft.ko \
      /kvmcomm/ko/fb_jd9853.ko \
      /kvmcomm/ko/f_udisp_drv.ko \
      /kvmcomm/ko/gpio_keys.ko \
      /kvmcomm/ko/rotary_encoder.ko \
      /kvmcomm/ko/wireguard.ko \
      /opt/swupdate/bin/swupdate ; do
      echo "rm $dead" >> "$script"
    done

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

    # Sanity: the MODULES TREE actually landed (this is the check whose absence let
    # the /lib-symlink bug ship). Dump from the image at the REAL path and compare
    # byte-for-byte against the staged copies. A silent debugfs failure -> the dump
    # is empty/absent -> cmp fails -> build fails (instead of a dead HDMI on-device).
    debugfs -R "dump /usr/lib/modules/${release}/modules.dep /tmp/chk.dep" rootfs.ext4 2>/dev/null
    cmp -s /tmp/chk.dep "$stage/lib/modules/${release}/modules.dep" \
      || { echo "ERROR: /usr/lib/modules/${release}/modules.dep missing/differs in image" >&2; exit 1; }
    ltrel=$( cd "$stage" && find lib/modules/${release} -name lt6911_manage.ko | head -1 )
    test -n "$ltrel" || { echo "ERROR: lt6911_manage.ko not in staging tree" >&2; exit 1; }
    debugfs -R "dump /usr/$ltrel /tmp/chk.ko" rootfs.ext4 2>/dev/null
    cmp -s /tmp/chk.ko "$stage/$ltrel" \
      || { echo "ERROR: lt6911_manage.ko missing/differs in image (/usr/$ltrel)" >&2; exit 1; }
    echo "  modules: /usr/lib/modules/${release} modules.dep + lt6911_manage.ko -- verified in image."

    # Sanity: the boot-time module loader config landed.
    debugfs -R "dump /etc/modules-load.d/nanokvm.conf /tmp/chk.conf" rootfs.ext4 2>/dev/null
    cmp -s /tmp/chk.conf "$PWD/nanokvm-modules-load.conf" \
      || { echo "ERROR: /etc/modules-load.d/nanokvm.conf missing/differs in image" >&2; exit 1; }
    echo "  modules-load: /etc/modules-load.d/nanokvm.conf -- verified in image."

    # Sanity: the inert closed kvmcomm/swupdate binaries are GONE (5d). debugfs
    # `stat` exits 0 even for a missing path, so test the OUTPUT -- an "Inode:"
    # line only appears when the entry still exists (same idiom as the
    # kvmcomm.service check above).
    for dead in /kvmcomm/ui/kvm_ui /kvmcomm/vin/kvm_vin /opt/swupdate/bin/swupdate; do
      if debugfs -R "stat $dead" rootfs.ext4 2>/dev/null | grep -q "Inode:"; then
        echo "ERROR: $dead still present in image (should be removed)" >&2; exit 1
      fi
    done
    echo "  removed closed binaries: kvm_ui/kvm_vin/swupdate -- verified absent in image."

    # Sanity: the motd-news beacon is disabled (file present with ENABLED=0).
    debugfs -R "cat /etc/default/motd-news" rootfs.ext4 2>/dev/null | grep -qx "ENABLED=0" \
      || { echo "ERROR: /etc/default/motd-news missing or not ENABLED=0 in image" >&2; exit 1; }
    echo "  motd-news: /etc/default/motd-news ENABLED=0 -- verified in image."

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
      /usr/lib/modules/${release}/           <- our kernel modules (incl.
                                                lt6911_manage.ko) + prebuilt
                                                ax_*.ko, depmod-regenerated
      /etc/modules-load.d/nanokvm.conf       <- autoloads lt6911_manage at boot
      /etc/default/motd-news (ENABLED=0)     <- disables the Ubuntu motd-news
                                                beacon (no motd.ubuntu.com phone-home)
    removed         : inert CLOSED vendor binaries from the disabled kvmcomm stack
                      (kvm_ui, frameforge, kvm_vin, and its display .ko:
                      fbtft/fb_jd9853/f_udisp_drv/gpio_keys/rotary_encoder/wireguard)
                      plus the vendor swupdate self-updater (/opt/swupdate/bin/swupdate).
                      KEPT: /kvmcomm/scripts, /kvmcomm/edid, lt6911_manage.ko, and
                      swupdate fw_printenv/fw_setenv. See docs/provenance.md.
    method          : debugfs -w in-place edit (no root), sif uid/gid 0 to keep
                      root ownership; depmod -b on a host staging tree.
    /lib PITFALL    : /lib is a SYMLINK to usr/lib and debugfs cannot traverse
                      symlinks, so the modules tree MUST be written to the real
                      /usr/lib/modules (writing under /lib fails silently -> no
                      modules -> dead HDMI capture). Ancestors are mkdir'd
                      parent-first; step [6] cmp-verifies the tree landed.
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
