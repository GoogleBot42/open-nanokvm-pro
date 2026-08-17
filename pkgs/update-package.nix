{ pkgs, nanokvm-server, nanokvm-web, kvm-encoder, kernel, nanokvm-display
, libsns-dummy, boot, dtb-slot-image, kernel-slot-image
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
#     usr/lib/modules/4.19.125/...               our from-source modules (incl.
#                                                lt6911_manage.ko), depmod'd at BUILD
#                                                time so modules.dep/.alias/.symbols
#                                                (.bin) ship pre-generated (no
#                                                on-device depmod). Vendor ax_*.ko
#                                                NOT merged (they load from /soc/ko;
#                                                see step 2 guard). Under usr/lib/
#                                                modules (NOT lib/modules) to match
#                                                the device's real path -- /lib is a symlink to
#                                                usr/lib. Mirrors pkgs/rootfs.nix [4].
#     etc/modules-load.d/nanokvm.conf            autoloads lt6911_manage at boot
#                                                (systemd-modules-load) -- libkvm
#                                                needs it; nothing else loads it.
#                                                Also loads the mini-display stack
#                                                (fb_jd9853 -> fbtft, gpio_keys,
#                                                rotary_encoder), all from source.
#     opt/nanokvm-display/ + systemd unit        mini-display status daemon,
#                                                enabled via wants-symlink
#                                                (takes effect on next boot).
#     etc/logrotate.d/nanokvm                    rotates /var/log/nanokvm/*.log
#                                                (10M, copytruncate; vendor
#                                                logrotate.timer runs it daily).
#     etc/systemd/system/wifi.service.d/         Restart=no drop-in that ends the
#       override.conf                            vendor wifi.service crash-restart
#                                                loop (#43); needs a daemon-reload
#                                                or a reboot to take effect.
#     soc/scripts/auto_load_all_drv.sh           our CURATED /soc/ko module loader
#                                                -- 12 of the vendor's 22 blobs
#                                                (#39). Takes effect on the NEXT
#                                                REBOOT: the modules the OTA lands
#                                                on are already loaded.
#     soc/scripts/auto_load_all_drv.sh.vendor    pristine vendor loader kept for
#                                                on-device rollback (restore + reboot).
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
    # ONLY our from-source modules go here (incl. lt6911_manage.ko). The prebuilt
    # vendor ax_*.ko are NOT merged in -- they ship + load from /soc/ko (vendor
    # auto_load_all_drv.sh, with their required params like `ax_cmm cmm=<pool>`).
    # Putting them here makes depmod emit of: aliases that udev autoloads
    # parameter-less at boot -> ax_cmm strlen(NULL) panic -> boot loop. See
    # pkgs/rootfs.nix step [4] and docs.
    echo "=== stage from-source kernel modules, depmod ==="
    modroot="$rfs/usr/lib/modules/${release}"
    mkdir -p "$modroot"
    cp -a "${kernel}/lib/modules/${release}/." "$modroot/"
    chmod -R u+w "$rfs/usr/lib/modules"
    echo "  .ko count: $(find "$modroot" -name '*.ko' | wc -l)"
    # depmod against the modules PARENT (-b <dir> expects <dir>/lib/modules/<rel>);
    # our tree lives at <rfs>/usr/lib/modules/<rel>, so the base is <rfs>/usr.
    depmod -b "$rfs/usr" "${release}"

    # --- module assertions (fail LOUDLY in-build, never on the device) ---
    # (a) the autoload-panic vendor blobs must NOT be present (regression guard).
    if find "$modroot" \( -name 'ax_cmm.ko' -o -name 'ax_sys.ko' -o -name 'ax_base.ko' \) | grep -q .; then
      echo "ERROR: vendor ax_*.ko present in the modules tree -- they autoload-panic (ax_cmm). Load from /soc/ko instead." >&2
      exit 1
    fi
    # (b) vermagic consistency: the shipped modules' release string must match the
    #     modules directory name (${release}); guards against packaging modules
    #     built for a different kernel than the dir claims.
    ko="$(find "$modroot" -name 'lt6911_manage.ko' | head -1)"
    test -n "$ko" && test -f "$ko" || { echo "ERROR: lt6911_manage.ko missing for vermagic check" >&2; exit 1; }
    vm=$(modinfo -F vermagic "$ko")
    echo "  vermagic($(basename "$ko")) = $vm"
    case "$vm" in
      "${release} "*) ;;   # e.g. "4.19.125 SMP preempt mod_unload aarch64"
      *) echo "ERROR: vermagic '$vm' does not match modules dir ${release}" >&2; exit 1 ;;
    esac
    # (c) modules.dep exists and resolves our marker module.
    test -f "$modroot/modules.dep" || { echo "ERROR: modules.dep not generated" >&2; exit 1; }
    grep -q 'lt6911_manage' "$modroot/modules.dep" \
      || { echo "ERROR: lt6911_manage missing from modules.dep" >&2; exit 1; }

    # --- autoload lt6911_manage + the mini-display stack at boot (mirrors
    # pkgs/rootfs.nix step [5b2]). All four display/input modules are built
    # from OUR kernel source and are parameter-less-safe (they bind DT nodes),
    # so this cannot re-create the ax_cmm autoload brick. f_udisp_drv is a USB
    # gadget function (USB-display), unneeded for the panel -- not loaded.
    mkdir -p "$rfs/etc/modules-load.d"
    printf '%s\n' \
      '# NanoKVM-Pro: load HDMI-capture bridge driver at boot (libkvm needs it).' \
      'lt6911_manage' \
      '# Mini-display stack (docs/mini-display.md): JD9853 SPI panel -> /dev/fb0' \
      '# (fbtft loads as a dependency), plus the knob button + rotary encoder.' \
      'fb_jd9853' \
      'gpio_keys' \
      'rotary_encoder' \
      > "$rfs/etc/modules-load.d/nanokvm.conf"
    # the modules the conf names must exist in the shipped tree
    for m in lt6911_manage fb_jd9853 fbtft gpio_keys rotary_encoder; do
      find "$modroot" -name "$m.ko" | grep -q . \
        || { echo "ERROR: $m.ko missing from modules tree (named in modules-load.d)" >&2; exit 1; }
    done

    # --- log rotation for /var/log/nanokvm (#41, mirrors pkgs/rootfs.nix [5b5]).
    # logrotate + logrotate.timer already ship in the vendor Ubuntu base, so the
    # drop-in alone is the fix; it takes effect on the next daily timer run with
    # no restart or reboot. copytruncate is mandatory -- the server's stdout fd
    # is held open by nanokvm.sh's `>>` redirect.
    mkdir -p "$rfs/etc/logrotate.d"
    cp ${./rootfs/logrotate-nanokvm.conf} "$rfs/etc/logrotate.d/nanokvm"
    chmod 644 "$rfs/etc/logrotate.d/nanokvm"
    grep -q '^ *copytruncate' "$rfs/etc/logrotate.d/nanokvm" \
      || { echo "ERROR: logrotate drop-in lost copytruncate" >&2; exit 1; }

    # --- end the vendor wifi.service crash-restart loop (#43, mirrors
    # pkgs/rootfs.nix [5b6]). A drop-in over the vendor unit at
    # /etc/systemd/system/wifi.service; Restart=no is the operative directive
    # (the vendor already sets RemainAfterExit=yes). Unlike the logrotate
    # drop-in this is NOT picked up automatically -- systemd needs a
    # `systemctl daemon-reload` (or the next boot) to re-read the unit.
    mkdir -p "$rfs/etc/systemd/system/wifi.service.d"
    cp ${./rootfs/wifi-service-override.conf} \
       "$rfs/etc/systemd/system/wifi.service.d/override.conf"
    chmod 644 "$rfs/etc/systemd/system/wifi.service.d/override.conf"
    grep -q '^Restart=no$' "$rfs/etc/systemd/system/wifi.service.d/override.conf" \
      || { echo "ERROR: wifi.service drop-in lost Restart=no" >&2; exit 1; }

    # --- curated /soc/ko module loader (#39, mirrors pkgs/rootfs.nix [5b7]).
    # Replaces the vendor auto_load_all_drv.sh (all 22 blobs) with the 12-module
    # dependency closure of {ax_proton, ax_venc, ax_jenc}; the pristine vendor
    # script ships beside it as .vendor for on-device rollback. This takes effect
    # on the NEXT REBOOT -- when the OTA lands the vendor set is already loaded,
    # so nothing is unloaded and the running pipeline is untouched.
    # NOTE: unlike the rootfs build there is no vendor-loader byte-compare here
    # (the OTA has no copy of the base rootfs to diff against); pkgs/rootfs.nix
    # step [5b7] is the guard that catches a base .axp changing the loader.
    mkdir -p "$rfs/soc/scripts"
    cp ${./rootfs/ax-load-drv.sh}        "$rfs/soc/scripts/auto_load_all_drv.sh"
    cp ${./rootfs/ax-load-drv.vendor.sh} "$rfs/soc/scripts/auto_load_all_drv.sh.vendor"
    chmod 755 "$rfs/soc/scripts/auto_load_all_drv.sh" \
              "$rfs/soc/scripts/auto_load_all_drv.sh.vendor"
    # ax_cmm without its cmmpool= param is the strlen(NULL) boot-loop panic, and
    # the module count is the whole point of the change -- assert both in-build.
    grep -qF 'insmod /soc/ko/ax_cmm.ko $cmm_param' "$rfs/soc/scripts/auto_load_all_drv.sh" \
      || { echo "ERROR: curated loader lost the ax_cmm cmmpool= parameter (panic risk)" >&2; exit 1; }
    grep -qF 'insmod /soc/ko/ax_proton.ko mem_iq_level=1' "$rfs/soc/scripts/auto_load_all_drv.sh" \
      || { echo "ERROR: curated loader lost ax_proton mem_iq_level=1" >&2; exit 1; }
    nins=$(grep -c '^[[:space:]]*insmod ' "$rfs/soc/scripts/auto_load_all_drv.sh" || true)
    if [ "$nins" -ne 12 ]; then
      echo "ERROR: curated loader has $nins insmod lines, expected 12 (#39)" >&2; exit 1
    fi
    # No modprobe/depmod: the loader must insmod by PATH with explicit params, or
    # modules.dep resolution could load ax_cmm parameter-less (the autoload brick).
    if grep -Eq '(^|[^[:alnum:]_])(modprobe|depmod)([^[:alnum:]_]|$)' "$rfs/soc/scripts/auto_load_all_drv.sh"; then
      echo "ERROR: curated loader uses modprobe/depmod -- must insmod by path with params" >&2; exit 1
    fi
    echo "  module loader: curated set OK ($nins insmod lines) + .vendor rollback copy"

    # --- mini-display status daemon (pkgs/nanokvm-display.nix): daemon + fonts
    # under /opt/nanokvm-display, systemd unit, enabled via wants-symlink (the
    # OTA overlay is `cp -a rootfs/. /`, which preserves the symlink). It
    # starts on the next boot; an app-only OTA doesn't launch it immediately.
    mkdir -p "$rfs/opt"
    cp -r ${nanokvm-display}/opt/nanokvm-display "$rfs/opt/"

    # --- from-source ISP dummy-sensor lib over the vendor prebuilt (#30);
    # dlopen'd from /opt/lib by the closed-capture backend (mirrors
    # pkgs/rootfs.nix step [5a1]).
    mkdir -p "$rfs/opt/lib"
    cp ${libsns-dummy}/lib/libsns_dummy.so "$rfs/opt/lib/libsns_dummy.so"
    chmod 755 "$rfs/opt/lib/libsns_dummy.so"
    mkdir -p "$rfs/etc/systemd/system/multi-user.target.wants"
    cp ${nanokvm-display}/etc/systemd/system/nanokvm-display.service \
       "$rfs/etc/systemd/system/nanokvm-display.service"
    ln -sf /etc/systemd/system/nanokvm-display.service \
       "$rfs/etc/systemd/system/multi-user.target.wants/nanokvm-display.service"
    # ATX GPIO setup oneshot (same package): exports the target power/reset
    # pins so the web UI power menu and the knob control page can actuate.
    cp ${nanokvm-display}/etc/systemd/system/nanokvm-gpio.service \
       "$rfs/etc/systemd/system/nanokvm-gpio.service"
    ln -sf /etc/systemd/system/nanokvm-gpio.service \
       "$rfs/etc/systemd/system/multi-user.target.wants/nanokvm-gpio.service"

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
