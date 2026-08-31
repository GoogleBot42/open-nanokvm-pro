{ pkgs, base-axp, kvm-encoder, kernel, vc8000-vcmd
, nanokvm-server, nanokvm-web, nanokvm-display, libsns-dummy, edid
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
#       lt6911_manage.ko), depmod'd. The prebuilt vendor ax_*.ko are DELIBERATELY
#       NOT merged in here -- see the guard in step [4] for why (autoload panic).
#   - /etc/modules-load.d/nanokvm.conf -> makes systemd-modules-load.service
#       modprobe lt6911_manage at boot (nothing on the vendor rootfs loads it
#       for the kvmapp/nanokvm stack, yet libkvm polls /proc/lt6911_info/*).
#   - /kvmcomm/edid/*.bin -> our clean-room EDID set (pkgs/edid). All six vendor
#       bins replaced in place, filename + byte 12 preserved -- step [5a1b].
#   Everything else stays vendor (app server + web already live in /kvmapp).
# Also hardened in the overlay:
#   - motd-news DISABLED: /etc/default/motd-news ENABLED=0 kills the Ubuntu
#       motd.ubuntu.com news beacon (50-motd-news phones home on login/timer).
#   - /etc/logrotate.d/nanokvm -> rotates /var/log/nanokvm/*.log at 10M
#       (copytruncate; the server holds its stdout fd open -- see #41).
#   - /etc/systemd/system/wifi.service.d/override.conf -> Restart=no, ends the
#       vendor wifi.service crash-restart loop (see #43).
#   - /soc/scripts/auto_load_all_drv.sh -> our CURATED module loader: 10 of the
#       vendor's 22 /soc/ko blobs (the ax_proton capture closure) PLUS our
#       from-source open VC8000E VCMD encode driver (ax630c_venc_vcmd.ko, emitted
#       to /soc/ko in step [5b7a]) in place of vendor ax_venc/ax_jenc -- so the
#       encode path is now blob-free too (#25 default). The pristine vendor
#       script is kept beside it as auto_load_all_drv.sh.vendor for on-device
#       rollback, and step [5b7] byte-compares the base .axp's copy against our
#       pin so a base bump that changes the loader fails the build.
#   - libkvm.so is the openvenc build (open capture + open encode; 0 vendor
#       libs). Its soft-MJPEG path DT_NEEDEDs libjpeg.so.8, which the vendor
#       Ubuntu base already ships at /lib/aarch64-linux-gnu/libjpeg.so.8.
#   - /etc/rc.local -> our copy with the axbox syslog daemon DROPPED. The vendor
#       rc.local starts /etc/init.d/{axsyslogd,axklogd} -> /bin/axbox, a CLOSED
#       Axera BusyBox multicall; stock rsyslogd already runs alongside it, so
#       axbox is redundant. The pristine vendor script is pinned as
#       pkgs/rootfs/rc.local.vendor and byte-compared in step [5b8].
#   - inert CLOSED vendor binaries REMOVED: the disabled kvmcomm stack's closed
#       kvm_ui/kvm_vin/frameforge + its display .ko, the vendor swupdate
#       self-updater, and the axbox syslog pair (/bin/axbox, its /sbin symlinks,
#       and libax_syslog.so). Exact paths only (debugfs has no recursive rm); the
#       live kvmcomm scripts/edid/lt6911_manage.ko and swupdate
#       fw_printenv/fw_setenv are KEPT. See docs/provenance.md.
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

    # ---- 4. stage the from-source /lib/modules tree and depmod it (host) ----
    # ONLY our from-source modules go here (incl. lt6911_manage.ko, which
    # /etc/modules-load.d loads for libkvm's /proc/lt6911_info HDMI-capture path).
    #
    # The prebuilt vendor ax_*.ko (pkgs/ax-ko-blobs.nix) are DELIBERATELY NOT
    # merged in. They already ship on the device via the retained vendor rootfs at
    # /soc/ko, where /soc/scripts/auto_load_all_drv.sh -- OUR curated
    # loader since #39 (step [5b7]) -- insmods them by path WITH their required
    # parameters (notably `ax_cmm cmmpool=...`). Putting them in
    # /usr/lib/modules makes depmod emit `of:` aliases; systemd-udevd coldplug then
    # autoloads the chain parameter-less at boot -> ax_cmm does strlen(NULL) ->
    # NULL-deref Oops -> panic-on-oops -> reboot loop. This bricked a device once
    # (the first OTA); the guard below fails the build if the blobs ever return.
    echo "=== [4] stage from-source kernel modules, depmod ==="
    stage="$PWD/stage"
    mkdir -p "$stage/lib/modules/${release}"
    cp -a "${kernel}/lib/modules/${release}/." "$stage/lib/modules/${release}/"
    chmod -R u+w "$stage"
    echo "  .ko count: $(find "$stage" -name '*.ko' | wc -l)"
    depmod -b "$stage" "${release}"
    if find "$stage" \( -name 'ax_cmm.ko' -o -name 'ax_sys.ko' -o -name 'ax_base.ko' \) | grep -q .; then
      echo "ERROR: vendor ax_*.ko present in the modules tree -- they autoload-panic (ax_cmm). Load from /soc/ko instead." >&2
      exit 1
    fi
    grep -q 'lt6911_manage' "$stage/lib/modules/${release}/modules.dep" \
      || { echo "ERROR: lt6911_manage missing from modules.dep" >&2; exit 1; }

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

    # 5a1. from-source ISP dummy-sensor lib over the vendor prebuilt (#30).
    # The closed-capture backend dlopens it from /opt/lib; device-tested
    # 2026-08-16 (clean dlopen, live MJPEG on the vendor-MPI path).
    if ! debugfs -R "stat /opt/lib/libsns_dummy.so" rootfs.ext4 >/dev/null 2>&1; then
      echo "ERROR: /opt/lib/libsns_dummy.so missing in vendor rootfs -- layout changed" >&2
      exit 1
    fi
    emit_file "${libsns-dummy}/lib/libsns_dummy.so" "/opt/lib/libsns_dummy.so" 0100755

    # 5a1b. Clean-room EDID set (from source, pkgs/edid/mkedid.py) over Sipeed's
    # shipped /kvmcomm/edid bins. Sipeed's set shares one monitor identity across
    # modes (only the serial LSB differs) so a host that caches per-display
    # settings won't re-probe on a mode switch; ours give each variant a distinct
    # product-id + serial while keeping byte 12 = the server's EDIDMap selector,
    # so the web UI still names them. Every bin passes edid-decode --check
    # (enforced in pkgs/edid.nix). ALL SIX stock files are replaced in place
    # (filename + byte 12 preserved, so NanoKVM-Server's EDIDMap and the web
    # UI's mode list are untouched); 720p is added. No vendor EDID bytes remain
    # in the image. The four exotic modes (4K39/2K60/4K-16:10/ultrawide) are
    # spec-derived and edid-decode-clean but NOT yet hardware-validated on a
    # real source -- 1080p60 and 4K30 are.
    if ! debugfs -R "stat /kvmcomm/edid" rootfs.ext4 >/dev/null 2>&1; then
      echo "ERROR: /kvmcomm/edid missing in vendor rootfs -- layout changed" >&2
      exit 1
    fi
    emit_file "${edid}/NanoKVM-1080P60.bin"  "/kvmcomm/edid/E54-1080P60FPS.bin" 0100644
    emit_file "${edid}/NanoKVM-4K30.bin"     "/kvmcomm/edid/E18-4K30FPS.bin"    0100644
    emit_file "${edid}/NanoKVM-4K39.bin"     "/kvmcomm/edid/E48-4K39FPS.bin"    0100644
    emit_file "${edid}/NanoKVM-2K60.bin"     "/kvmcomm/edid/E56-2K60FPS.bin"    0100644
    emit_file "${edid}/NanoKVM-4K1610.bin"   "/kvmcomm/edid/E58-4K16-10.bin"    0100644
    emit_file "${edid}/NanoKVM-Ultrawide.bin" "/kvmcomm/edid/E63-Ultrawide.bin" 0100644
    emit_file "${edid}/NanoKVM-720P60.bin"   "/kvmcomm/edid/NanoKVM-720P60.bin" 0100644

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
    # fb_jd9853 (pulls fbtft via modules.dep) + the knob input drivers are the
    # mini-display stack -- ALL built from OUR kernel source (the vendor
    # defconfig already sets FB_TFT_JD9853/KEYBOARD_GPIO/INPUT_GPIO_ROTARY_
    # ENCODER =m); no /kvmcomm/ko blobs involved. All four are parameter-less-
    # safe (fb binds the DT panel node; the input drivers bind DT nodes), so
    # this explicit load cannot re-create the ax_cmm autoload brick (step [4]).
    # f_udisp_drv (the 5th vendor display .ko) is a USB *gadget* function
    # (USB-display), not needed for the panel -- built from source but not loaded.
    printf '%s\n' \
      '# NanoKVM-Pro: load HDMI-capture bridge driver at boot (libkvm needs it).' \
      'lt6911_manage' \
      '# Mini-display stack (docs/mini-display.md): JD9853 SPI panel -> /dev/fb0' \
      '# (fbtft loads as a dependency), plus the knob button + rotary encoder.' \
      'fb_jd9853' \
      'gpio_keys' \
      'rotary_encoder' \
      > "$PWD/nanokvm-modules-load.conf"
    emit_file "$PWD/nanokvm-modules-load.conf" "/etc/modules-load.d/nanokvm.conf" 0100644

    # 5b4. mini-display status daemon (pkgs/nanokvm-display.nix): pure-Python
    # renderer + build-time-generated fonts under /opt/nanokvm-display, plus a
    # systemd unit, enabled via wants-symlink (same pattern as nanokvm.service).
    echo "mkdir /opt" >> "$script"                    # existing dir: harmless
    echo "mkdir /opt/nanokvm-display" >> "$script"
    emit_file "${nanokvm-display}/opt/nanokvm-display/nanokvm_display.py" \
              "/opt/nanokvm-display/nanokvm_display.py" 0100755
    emit_file "${nanokvm-display}/opt/nanokvm-display/font_data.py" \
              "/opt/nanokvm-display/font_data.py" 0100644
    emit_file "${nanokvm-display}/etc/systemd/system/nanokvm-display.service" \
              "/etc/systemd/system/nanokvm-display.service" 0100644
    # ATX GPIO setup unit (same package): exports the target power/reset pins
    # the vendor kvmcomm stack used to export -- without it the web UI power
    # menu and the knob control page cannot actuate anything.
    emit_file "${nanokvm-display}/etc/systemd/system/nanokvm-gpio.service" \
              "/etc/systemd/system/nanokvm-gpio.service" 0100644

    # 5b3. Disable the Ubuntu motd-news beacon. The vendor Ubuntu base ships
    # /etc/update-motd.d/50-motd-news, which phones home to motd.ubuntu.com on
    # login/timer to fetch Canonical "news". Drop /etc/default/motd-news with
    # ENABLED=0 so it never reaches out. /etc/default exists on Ubuntu; mkdir is
    # belt-and-braces (harmless on an existing dir).
    echo "mkdir /etc/default" >> "$script"   # existing dir: harmless
    printf '# Disabled in open-nanokvm-pro: no Canonical motd news beacon (motd.ubuntu.com).\nENABLED=0\n' \
      > "$PWD/motd-news"
    emit_file "$PWD/motd-news" "/etc/default/motd-news" 0100644

    # 5b5. Log rotation for /var/log/nanokvm (#41). The vendor Ubuntu base
    # already ships logrotate + an enabled logrotate.timer (OnCalendar=daily,
    # device-verified), so a drop-in is the whole fix -- no unit of ours.
    # copytruncate is mandatory: NanoKVM-Server's stdout/stderr fd is held open
    # for the process lifetime by nanokvm.sh's `>>` redirect.
    if ! debugfs -R "stat /etc/logrotate.d" rootfs.ext4 >/dev/null 2>&1; then
      echo "ERROR: /etc/logrotate.d missing in vendor rootfs -- layout changed" >&2
      exit 1
    fi
    echo "mkdir /etc/logrotate.d" >> "$script"   # existing dir: harmless
    emit_file "${./rootfs/logrotate-nanokvm.conf}" "/etc/logrotate.d/nanokvm" 0100644

    # 5b6. Kill the vendor wifi.service crash-restart loop (#43) with a systemd
    # drop-in. The vendor unit is /etc/systemd/system/wifi.service (Type=simple,
    # RemainAfterExit=yes, Restart=on-failure, RestartSec=3); its ExecStart
    # (/opt/scripts/wifi.sh start) exits 1 whenever aic8800_fdrv is already
    # loaded, so Restart=on-failure loops it forever -- RestartSec=3 keeps 5
    # attempts just outside the default 10s StartLimit window, so the rate
    # limiter never trips. Restart=no is the operative change; RemainAfterExit
    # merely restates the vendor value. We do NOT mask the unit or patch
    # wifi.sh -- see pkgs/rootfs/wifi-service-override.conf for the rationale.
    if ! debugfs -R "stat /etc/systemd/system/wifi.service" rootfs.ext4 >/dev/null 2>&1; then
      echo "ERROR: /etc/systemd/system/wifi.service missing in vendor rootfs -- layout changed" >&2
      exit 1
    fi
    echo "mkdir /etc/systemd/system/wifi.service.d" >> "$script"
    emit_file "${./rootfs/wifi-service-override.conf}" \
              "/etc/systemd/system/wifi.service.d/override.conf" 0100644

    # 5b7. CURATED /soc/ko module loader (#39). The vendor
    # /soc/scripts/auto_load_all_drv.sh insmods all 22 blobs at boot; we load 10
    # vendor blobs (the ax_proton capture closure) + our from-source open VCMD
    # encode driver (ax630c_venc_vcmd.ko) IN PLACE of vendor ax_venc/ax_jenc
    # (#25 default). We ship a curated loader in its place and keep
    # the pristine vendor script alongside as auto_load_all_drv.sh.vendor, so a
    # rollback on the device is `cp <name>.vendor <name>` + reboot. Rationale and
    # the full keep/drop table: docs/blob-replacement.md.
    #
    # The vendor loader is asserted BYTE-IDENTICAL to our pinned copy: if a base
    # .axp bump ever ships a different auto_load_all_drv.sh, this build FAILS
    # instead of silently overwriting it with a curated set derived from the old
    # one. (debugfs `stat` exits 0 even for a missing path, so test the OUTPUT.)
    vloader="/soc/scripts/auto_load_all_drv.sh"
    if ! debugfs -R "stat $vloader" rootfs.ext4 2>/dev/null | grep -q "Inode:"; then
      echo "ERROR: $vloader missing in vendor rootfs -- layout changed" >&2
      exit 1
    fi
    debugfs -R "dump $vloader $PWD/chk.vloader" rootfs.ext4 2>/dev/null
    cmp -s "$PWD/chk.vloader" "${./rootfs/ax-load-drv.vendor.sh}" || {
      echo "ERROR: the base .axp's $vloader differs from" >&2
      echo "       pkgs/rootfs/ax-load-drv.vendor.sh. The vendor module loader" >&2
      echo "       changed -- re-derive the curated module set (#39/#25," >&2
      echo "       docs/blob-replacement.md) and re-pin both files." >&2
      exit 1
    }
    # Content asserts on OUR loader (fail in-build, never on the device):
    # the ax_cmm pool parameter and the proton IQ level are load-bearing --
    # ax_cmm without cmmpool= is the strlen(NULL) panic from the OTA brick --
    # and the whole point of the change is the module count.
    curated="${./rootfs/ax-load-drv.sh}"
    grep -qF 'insmod /soc/ko/ax_cmm.ko $cmm_param' "$curated" \
      || { echo "ERROR: curated loader lost the ax_cmm cmmpool= parameter (panic risk)" >&2; exit 1; }
    grep -qF 'insmod /soc/ko/ax_proton.ko mem_iq_level=1' "$curated" \
      || { echo "ERROR: curated loader lost ax_proton mem_iq_level=1" >&2; exit 1; }
    # Blob-free encode (#25 default): the open VCMD driver must be loaded, and
    # the vendor venc/jenc blobs must NOT be (they'd grab the VCMD MMIO+IRQ).
    grep -qF 'insmod /soc/ko/ax630c_venc_vcmd.ko' "$curated" \
      || { echo "ERROR: curated loader lost the open ax630c_venc_vcmd.ko (no encode)" >&2; exit 1; }
    if grep -Eq 'insmod /soc/ko/ax_(venc|jenc)\.ko' "$curated"; then
      echo "ERROR: curated loader still insmods vendor ax_venc/ax_jenc -- clashes with the open VCMD driver" >&2; exit 1
    fi
    nins=$(grep -c '^[[:space:]]*insmod ' "$curated" || true)
    if [ "$nins" -ne 11 ]; then
      echo "ERROR: curated loader has $nins insmod lines, expected 11 (10 vendor + open venc, #25)" >&2; exit 1
    fi
    # No modprobe/depmod: the loader must insmod by PATH with explicit params.
    # A modprobe here would resolve through modules.dep and could load ax_cmm
    # parameter-less -- the exact autoload brick step [4] guards against.
    if grep -Eq '(^|[^[:alnum:]_])(modprobe|depmod)([^[:alnum:]_]|$)' "$curated"; then
      echo "ERROR: curated loader uses modprobe/depmod -- must insmod by path with params" >&2; exit 1
    fi
    echo "  module loader: vendor script pinned + curated set asserted ($nins insmod lines)."
    emit_file "${./rootfs/ax-load-drv.vendor.sh}" "$vloader.vendor" 0100755
    emit_file "${./rootfs/ax-load-drv.sh}"        "$vloader"        0100755

    # 5b7a. The from-source open VC8000E VCMD driver (#44/#25), loaded by the
    # curated loader above in place of vendor ax_venc/ax_jenc. Built against OUR
    # kernel (vermagic-compatible). Provides /dev/es_venc for the openvenc libkvm
    # backend. Emitted into /soc/ko (flat, insmod-by-path -- no depmod needed).
    # debugfs `stat` exits 0 even for a MISSING path -- test the output for
    # "Inode:" (the idiom used for the libkvm/loader guards; a bare exit-status
    # check here would be a silent no-op).
    if ! debugfs -R "stat /soc/ko" rootfs.ext4 2>/dev/null | grep -q "Inode:"; then
      echo "ERROR: /soc/ko missing in vendor rootfs -- layout changed" >&2
      exit 1
    fi
    emit_file "${vc8000-vcmd}/ax630c_venc_vcmd.ko" "/soc/ko/ax630c_venc_vcmd.ko" 0100644

    # 5b8. DROP the axbox syslog daemon (docs/provenance.md). The vendor
    # /etc/rc.local starts /etc/init.d/{axsyslogd,axklogd}, which start-stop-daemon
    # /sbin/{axsyslogd,axklogd} -> both symlinks to /bin/axbox, a CLOSED Axera
    # BusyBox-1.32.0 multicall linked against /usr/lib/libax_syslog.so. Stock
    # rsyslogd already runs on this base (rsyslog.service is enabled in
    # multi-user.target.wants and Alias=syslog.service) with imuxsock + imklog
    # loaded and 50-default.conf writing /var/log/{syslog,kern.log,auth.log} --
    # so axbox is a redundant SECOND syslog+klog pair. We ship an rc.local
    # without the two launch lines and delete the binaries in step 5d.
    #
    # The base's other caller, /etc/init.d/rcS, is dead: /usr/lib/systemd/system/
    # rcS.service and rc.service are symlinks to /dev/null (masked), so nothing
    # runs it. /etc/rc.local itself runs via systemd-rc-local-generator ->
    # rc-local.service (ConditionFileIsExecutable=/etc/rc.local), so our copy
    # must stay executable -- mode 0755 below.
    #
    # Same guard shape as the module loader: the vendor rc.local is asserted
    # BYTE-IDENTICAL to our pin, so a base .axp bump that changes rc.local fails
    # the build instead of silently dropping whatever the vendor added.
    rclocal="/etc/rc.local"
    if ! debugfs -R "stat $rclocal" rootfs.ext4 2>/dev/null | grep -q "Inode:"; then
      echo "ERROR: $rclocal missing in vendor rootfs -- layout changed" >&2
      exit 1
    fi
    debugfs -R "dump $rclocal $PWD/chk.vrclocal" rootfs.ext4 2>/dev/null
    cmp -s "$PWD/chk.vrclocal" "${./rootfs/rc.local.vendor}" || {
      echo "ERROR: the base .axp's $rclocal differs from" >&2
      echo "       pkgs/rootfs/rc.local.vendor. Re-derive our rc.local from the" >&2
      echo "       new vendor script (drop only the axsyslogd/axklogd lines)" >&2
      echo "       and re-pin both files." >&2
      exit 1
    }
    # Content asserts on OUR rc.local (fail in-build, never on the device).
    ourrc="${./rootfs/rc.local}"
    if grep -Eq 'axsyslogd|axklogd|axbox' "$ourrc"; then
      # comments explaining the removal are fine; actual invocations are not
      if grep -Ev '^[[:space:]]*#' "$ourrc" | grep -Eq 'axsyslogd|axklogd|axbox'; then
        echo "ERROR: our rc.local still launches axbox (axsyslogd/axklogd)" >&2; exit 1
      fi
    fi
    # every load-bearing vendor line must survive the edit
    for need in \
      '/etc/init.d/axemac.sh' \
      '/soc/scripts/auto_load_all_drv.sh' \
      '/soc/scripts/npu_set_bw_limiter.sh' \
      'devmem 0x10030028' \
      '/etc/init.d/S99checkboot' \
      '/etc/init.d/S99checkota' \
      'sysdev.service' ; do
      grep -qF "$need" "$ourrc" \
        || { echo "ERROR: our rc.local lost the vendor line '$need'" >&2; exit 1; }
    done
    echo "  rc.local: vendor pinned + axbox launch removed, vendor lines asserted."
    emit_file "$ourrc" "$rclocal" 0100755

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
      # enable the mini-display status daemon (unit written in step 5b4)
      echo "rm $wants/nanokvm-display.service"
      echo "symlink $wants/nanokvm-display.service /etc/systemd/system/nanokvm-display.service"
      echo "sif $wants/nanokvm-display.service uid 0"
      echo "sif $wants/nanokvm-display.service gid 0"
      # enable the ATX GPIO setup oneshot (unit written in step 5b4)
      echo "rm $wants/nanokvm-gpio.service"
      echo "symlink $wants/nanokvm-gpio.service /etc/systemd/system/nanokvm-gpio.service"
      echo "sif $wants/nanokvm-gpio.service uid 0"
      echo "sif $wants/nanokvm-gpio.service gid 0"
    } >> "$script"

    # 5d. remove inert closed kvmcomm binaries + vendor swupdate -- see
    # docs/provenance.md. These belong to the disabled kvmcomm stack (5c: the
    # vendor's closed kvm_vin/kvm_ui/frameforge pipeline + its display .ko) and to
    # the vendor swupdate self-updater (we ship our own updater). With kvmcomm
    # disabled they never run, so drop the closed blobs from the image. debugfs
    # has no recursive remove, so these are EXACT file paths; `rm` silently
    # continues if a path is already absent.
    # KEEP (live deps -- do NOT add here): /kvmcomm/scripts/*, /kvmcomm/edid/*,
    # and /opt/swupdate/bin/fw_printenv|fw_setenv (used by S99checkboot).
    # lt6911_manage.ko left this list 2026-08-16 (issue #29): the loaded
    # driver is OUR kernel build via /etc/modules-load.d -> /usr/lib/modules;
    # nothing in the active stack references the /kvmcomm/ko copy (grep of
    # kvmapp tree, server binary, systemd units, init scripts), and a reboot
    # without it came up fully healthy (HDMI capture included).
    for dead in \
      /kvmcomm/ui/kvm_ui \
      /kvmcomm/ui/frameforge \
      /kvmcomm/vin/kvm_vin \
      /kvmcomm/ko/fbtft.ko \
      /kvmcomm/ko/fb_jd9853.ko \
      /kvmcomm/ko/f_udisp_drv.ko \
      /kvmcomm/ko/gpio_keys.ko \
      /kvmcomm/ko/rotary_encoder.ko \
      /kvmcomm/ko/lt6911_manage.ko \
      /kvmcomm/ko/wireguard.ko \
      /opt/swupdate/bin/swupdate \
      /usr/bin/axbox \
      /usr/sbin/axsyslogd \
      /usr/sbin/axklogd \
      /usr/bin/axdmesg \
      /etc/init.d/axsyslogd \
      /etc/init.d/axklogd \
      /usr/lib/libax_syslog.so \
      /opt/lib/libax_syslog.so \
      /usr/bin/kvm_ui_setup \
      /usr/bin/ax_clk \
      /usr/bin/ax_lookat \
      /soc/ko/ax_venc.ko \
      /soc/ko/ax_jenc.ko \
      /kvmapp/server/dl_lib/libkvm.so.0.1.0 ; do
      echo "rm $dead" >> "$script"
    done
    # /kvmapp/server/dl_lib/libkvm.so.0.1.0: Sipeed's ORIGINAL closed libkvm
    # (2.3 MB, DT_NEEDEDs the full libax closure). We overwrite libkvm.so + .so.0
    # with ours, but the versioned .so.0.1.0 was left behind -- never mapped (the
    # server's DT_NEEDED libkvm.so.0 resolves to our file), but it is the largest
    # closed blob on the image and the one file that could pull libax back into a
    # process. Removed (#25).

    # ---- 5d1. PURGE the vendor libax_*.so (dead weight since openvenc, #25) ----
    # The shipped libkvm is openvenc and DT_NEEDEDs ZERO libax; nothing else in
    # our stack references them (server + libkvm readelf-clean; libsns_dummy is
    # dlopen'd only on the closed-capture path, which we don't ship). Device-
    # proven safe: with every /opt/lib/libax_*.so moved aside the openvenc stack
    # still captures + streams (0 libax maps). Enumerated from the extracted
    # rootfs so the list can't drift. The base's other closed .so (vendor
    # libsns_*, NPU model data) are separate dead weight -- a later purge (#54).
    libax_n=0
    for lib in $(debugfs -R "ls -p /opt/lib" rootfs.ext4 2>/dev/null \
                 | awk -F/ '{print $6}' | grep -E '^libax_.*\.so$' | sort -u); do
      echo "rm /opt/lib/$lib" >> "$script"
      libax_n=$((libax_n + 1))
    done
    echo "  libax purge: queued $libax_n /opt/lib/libax_*.so for removal (0 refs, openvenc)"
    test "$libax_n" -ge 20 \
      || { echo "ERROR: only $libax_n libax_*.so found in /opt/lib -- layout changed, refusing to ship a half-purge" >&2; exit 1; }
    # The two vendor ENCODE blobs (#25): our from-source open VC8000E VCMD
    # driver (ax630c_venc_vcmd.ko, loaded in their place by the curated loader)
    # makes them dead weight -- nothing kept symbol-depends on them (only
    # ax_jenc depended on ax_venc, both dropped), and the shipped libkvm links
    # ZERO vendor libs. Removing them shrinks the shipped blob set toward the
    # zero-vendor-blob goal (standing direction, 2026-08-30). /soc is a real
    # dir (not a usr symlink), so debugfs `rm` reaches it. The pristine .vendor
    # rollback loader still references them, but it has no `set -e`, so a
    # rollback insmods the CAPTURE blobs fine and simply skips the (now absent)
    # encode pair -- encode rollback needs a reflash, which is the intent.
    # (OTA can't delete, so an OTA-upgraded device keeps them unused until
    # reflash -- same pattern as the axbox removal.)
    # The axbox set above (step 5b8): axbox is the closed multicall,
    # ax{syslog,klog,dmesg}d are its symlinks (axdmesg is caller-less but would
    # dangle once axbox is gone), /etc/init.d/{axsyslogd,axklogd} the (now
    # caller-less) sysv wrappers, and libax_syslog.so is axbox's only non-libc
    # DT_NEEDED -- verified: nothing else on the image DT_NEEDEDs or dlopens it
    # (the /opt/lib copy is a second, equally unreferenced build). rsyslogd
    # covers logging; see the rationale block in step 5b8.
    #
    # Also dropped, same debugfs-delete pattern -- CLOSED vendor userspace ELFs
    # with ZERO caller anywhere on the image (grep of every init script + systemd
    # unit + kvmcomm script is empty):
    #   kvm_ui_setup  6.5 MB closed Sipeed C++ (RPATH into a dev's ~/kvm_ui tree);
    #                 its only mention was a string inside /kvmcomm/ui/kvm_ui,
    #                 which we already delete. A stray, not even kvmcomm-launched.
    #   ax_clk        14.5 KB closed Axera clock-poke tool.
    #   ax_lookat     14.5 KB closed Axera /dev/mem peek/poke; referenced only by
    #                 /soc/scripts/busmonitor.sh, a manual debug script never run
    #                 at boot.
    #
    # NOTE the REAL paths /usr/bin, /usr/sbin: on this rootfs /bin, /sbin and
    # /lib are all SYMLINKS into usr/, and debugfs `rm` does not traverse them --
    # `rm /bin/axbox` fails SILENTLY (same trap as the /lib modules tree; see the
    # header). debugfs `stat` DOES resolve symlinks, which is why the step-[6]
    # assertion below catches this rather than papering over it.

    # ---- 6. apply overlay in a single debugfs -w pass ----
    echo "=== [6] apply overlay (debugfs -w) ==="
    debugfs -w -f "$script" rootfs.ext4 > debugfs.log 2>&1 || {
      echo "ERROR: debugfs overlay failed; tail of log:" >&2; tail -40 debugfs.log >&2; exit 1;
    }
    # Sanity: our libkvm must now be in the image and match ours byte-for-byte.
    debugfs -R "dump /kvmapp/server/dl_lib/libkvm.so.0 $PWD/chk.so" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.so "${kvm-encoder}/lib/libkvm.so.0" \
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
    debugfs -R "dump /kvmapp/server/NanoKVM-Server $PWD/chk.srv" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.srv "${nanokvm-server}/bin/NanoKVM-Server" \
      || { echo "ERROR: NanoKVM-Server in image != our build" >&2; exit 1; }
    debugfs -R "cat /kvmapp/version" rootfs.ext4 2>/dev/null | grep -qx "${version}" \
      || { echo "ERROR: /kvmapp/version in image != ${version}" >&2; exit 1; }
    echo "  app: our NanoKVM-Server + /kvmapp/version=${version} -- verified in image."

    # Sanity: the MODULES TREE actually landed (this is the check whose absence let
    # the /lib-symlink bug ship). We check PRESENCE + content, not a byte-for-byte
    # cmp of modules.dep: the tree either lands (dump has real content) or the
    # /lib-symlink swallow leaves it absent (empty dump). A content check is robust
    # to debugfs/depmod byte-level quirks while still catching the silent failure.
    debugfs -R "dump /usr/lib/modules/${release}/modules.dep $PWD/chk.dep" rootfs.ext4 2>/dev/null || true
    grep -q 'lt6911_manage' $PWD/chk.dep \
      || { echo "ERROR: /usr/lib/modules/${release}/modules.dep absent or missing lt6911 in image" >&2; exit 1; }
    # And the actual .ko must be present + byte-identical (single-file dump).
    ltrel=$( cd "$stage" && find lib/modules/${release} -name lt6911_manage.ko | head -1 )
    test -n "$ltrel" || { echo "ERROR: lt6911_manage.ko not in staging tree" >&2; exit 1; }
    debugfs -R "dump /usr/$ltrel $PWD/chk.ko" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.ko "$stage/$ltrel" \
      || { echo "ERROR: lt6911_manage.ko missing/differs in image (/usr/$ltrel)" >&2; exit 1; }
    echo "  modules: /usr/lib/modules/${release} modules.dep + lt6911_manage.ko -- verified in image."

    # The open VCMD encode driver must land byte-identical (the curated loader
    # insmods it by path at boot; a silent debugfs write-miss would boot with no
    # H.264 and no build error -- #25 default).
    debugfs -R "dump /soc/ko/ax630c_venc_vcmd.ko $PWD/chk.vcmd" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.vcmd "${vc8000-vcmd}/ax630c_venc_vcmd.ko" \
      || { echo "ERROR: ax630c_venc_vcmd.ko missing/differs in image (/soc/ko)" >&2; exit 1; }
    # vermagic must match the shipped kernel or insmod fails at boot (no H.264).
    vcmdvm=$(modinfo -F vermagic "${vc8000-vcmd}/ax630c_venc_vcmd.ko")
    case "$vcmdvm" in
      "${release} "*) ;;
      *) echo "ERROR: ax630c_venc_vcmd.ko vermagic '$vcmdvm' != ${release}" >&2; exit 1 ;;
    esac
    echo "  open venc driver: /soc/ko/ax630c_venc_vcmd.ko -- verified in image (vermagic $vcmdvm)."

    # The vendor ENCODE blobs must be GONE (#25 -- open VCMD driver replaces
    # them). debugfs `stat` prints "File not found" (no "Inode:") for a removed
    # path; assert that for both, so a debugfs rm that silently no-oped fails
    # the build instead of shipping the blobs we meant to drop.
    for gone in /soc/ko/ax_venc.ko /soc/ko/ax_jenc.ko; do
      if debugfs -R "stat $gone" rootfs.ext4 2>/dev/null | grep -q "Inode:"; then
        echo "ERROR: $gone still present in image -- vendor encode blob not removed (#25)" >&2
        exit 1
      fi
    done
    echo "  vendor encode blobs: ax_venc.ko + ax_jenc.ko -- confirmed removed from image."

    # The vendor libax_*.so purge (#25) must have taken -- assert none remain.
    remaining_libax=$(debugfs -R "ls -p /opt/lib" rootfs.ext4 2>/dev/null \
                      | awk -F/ '{print $6}' | grep -cE '^libax_.*\.so$' || true)
    if [ "$remaining_libax" -ne 0 ]; then
      echo "ERROR: $remaining_libax libax_*.so still in /opt/lib after purge (#25)" >&2
      exit 1
    fi
    # And Sipeed's original closed libkvm must be gone.
    if debugfs -R "stat /kvmapp/server/dl_lib/libkvm.so.0.1.0" rootfs.ext4 2>/dev/null | grep -q "Inode:"; then
      echo "ERROR: closed libkvm.so.0.1.0 still present in image (#25)" >&2
      exit 1
    fi
    echo "  libax purge + closed libkvm.so.0.1.0: confirmed removed from image."

    # Sanity: the boot-time module loader config landed.
    debugfs -R "dump /etc/modules-load.d/nanokvm.conf $PWD/chk.conf" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.conf "$PWD/nanokvm-modules-load.conf" \
      || { echo "ERROR: /etc/modules-load.d/nanokvm.conf missing/differs in image" >&2; exit 1; }
    echo "  modules-load: /etc/modules-load.d/nanokvm.conf -- verified in image."

    # Sanity: the display modules the loader config names actually exist in the
    # staged modules tree (all built from OUR kernel source, no /kvmcomm blobs).
    for m in fb_jd9853 fbtft gpio_keys rotary_encoder; do
      find "$stage" -name "$m.ko" | grep -q . \
        || { echo "ERROR: $m.ko missing from from-source modules tree" >&2; exit 1; }
    done
    echo "  display modules: fb_jd9853/fbtft/gpio_keys/rotary_encoder -- present, from source."

    # Sanity: the mini-display daemon + unit landed and the unit is enabled.
    debugfs -R "dump /opt/nanokvm-display/nanokvm_display.py $PWD/chk.disp" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.disp "${nanokvm-display}/opt/nanokvm-display/nanokvm_display.py" \
      || { echo "ERROR: nanokvm_display.py missing/differs in image" >&2; exit 1; }
    debugfs -R "dump /opt/nanokvm-display/font_data.py $PWD/chk.font" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.font "${nanokvm-display}/opt/nanokvm-display/font_data.py" \
      || { echo "ERROR: font_data.py missing/differs in image" >&2; exit 1; }
    debugfs -R "stat $wants/nanokvm-display.service" rootfs.ext4 2>/dev/null | grep -q "Type: symlink" \
      || { echo "ERROR: nanokvm-display.service not enabled (symlink missing) in image" >&2; exit 1; }
    debugfs -R "stat $wants/nanokvm-gpio.service" rootfs.ext4 2>/dev/null | grep -q "Type: symlink" \
      || { echo "ERROR: nanokvm-gpio.service not enabled (symlink missing) in image" >&2; exit 1; }
    echo "  mini-display: daemon + fonts + enabled units (display, ATX gpio) -- verified in image."

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

    # Sanity: the axbox syslog daemon is GONE and rsyslog is still the enabled
    # logger (step 5b8). Same "test the OUTPUT" idiom -- debugfs stat exits 0 on
    # a missing path.
    # Both the real paths AND the /bin,/sbin symlink paths are checked: debugfs
    # `stat` follows symlinks, so the /bin/axbox form also proves the removal is
    # visible at the path the device actually uses.
    for dead in /usr/bin/axbox /usr/sbin/axsyslogd /usr/sbin/axklogd /usr/bin/axdmesg \
                /bin/axbox /sbin/axsyslogd /sbin/axklogd /bin/axdmesg \
                /usr/lib/libax_syslog.so /opt/lib/libax_syslog.so \
                /etc/init.d/axsyslogd /etc/init.d/axklogd \
                /usr/bin/kvm_ui_setup /usr/bin/ax_clk /usr/bin/ax_lookat; do
      if debugfs -R "stat $dead" rootfs.ext4 2>/dev/null | grep -q "Inode:"; then
        echo "ERROR: $dead still present in image (closed-blob removal, step 5b8/5d)" >&2; exit 1
      fi
    done
    # rsyslog must remain enabled -- it is what replaces axbox.
    debugfs -R "stat $wants/rsyslog.service" rootfs.ext4 2>/dev/null | grep -q "Type: symlink" \
      || { echo "ERROR: rsyslog.service not enabled in image -- axbox removal would leave no syslog" >&2; exit 1; }
    # and our rc.local must have landed, byte-identical, still executable.
    debugfs -R "dump $rclocal $PWD/chk.rclocal" rootfs.ext4 2>/dev/null
    cmp -s "$PWD/chk.rclocal" "${./rootfs/rc.local}" \
      || { echo "ERROR: $rclocal in image != our rc.local" >&2; exit 1; }
    debugfs -R "stat $rclocal" rootfs.ext4 2>/dev/null | grep -qE "Mode: +0755" \
      || { echo "ERROR: $rclocal is not mode 0755 -- rc-local.service would not run it" >&2; exit 1; }
    echo "  axbox: /bin/axbox + libax_syslog.so removed, rc.local swapped, rsyslog enabled -- verified in image."

    # Sanity: the motd-news beacon is disabled (file present with ENABLED=0).
    debugfs -R "cat /etc/default/motd-news" rootfs.ext4 2>/dev/null | grep -qx "ENABLED=0" \
      || { echo "ERROR: /etc/default/motd-news missing or not ENABLED=0 in image" >&2; exit 1; }
    echo "  motd-news: /etc/default/motd-news ENABLED=0 -- verified in image."

    # Sanity: the logrotate drop-in landed and still says copytruncate (the
    # load-bearing directive -- see pkgs/rootfs/logrotate-nanokvm.conf).
    debugfs -R "dump /etc/logrotate.d/nanokvm $PWD/chk.lr" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.lr "${./rootfs/logrotate-nanokvm.conf}" \
      || { echo "ERROR: /etc/logrotate.d/nanokvm missing/differs in image" >&2; exit 1; }
    grep -q '^ *copytruncate' $PWD/chk.lr \
      || { echo "ERROR: logrotate drop-in lost copytruncate" >&2; exit 1; }
    echo "  logrotate: /etc/logrotate.d/nanokvm -- verified in image."

    # Sanity: the wifi.service drop-in landed and still carries Restart=no (the
    # load-bearing directive -- see pkgs/rootfs/wifi-service-override.conf, #43).
    debugfs -R "dump /etc/systemd/system/wifi.service.d/override.conf $PWD/chk.wifi" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.wifi "${./rootfs/wifi-service-override.conf}" \
      || { echo "ERROR: wifi.service drop-in missing/differs in image" >&2; exit 1; }
    grep -q '^Restart=no$' $PWD/chk.wifi \
      || { echo "ERROR: wifi.service drop-in lost Restart=no" >&2; exit 1; }
    echo "  wifi loop: /etc/systemd/system/wifi.service.d/override.conf -- verified in image."

    # Sanity: the curated /soc/ko module loader replaced the vendor one, and the
    # pristine vendor script is present alongside it for on-device rollback (#39).
    debugfs -R "dump $vloader $PWD/chk.loader" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.loader "${./rootfs/ax-load-drv.sh}" \
      || { echo "ERROR: $vloader in image != our curated loader" >&2; exit 1; }
    debugfs -R "dump $vloader.vendor $PWD/chk.loader.vendor" rootfs.ext4 2>/dev/null
    cmp -s $PWD/chk.loader.vendor "${./rootfs/ax-load-drv.vendor.sh}" \
      || { echo "ERROR: $vloader.vendor rollback copy missing/differs in image" >&2; exit 1; }
    debugfs -R "stat $vloader" rootfs.ext4 2>/dev/null | grep -qE "Mode: +0755" \
      || { echo "ERROR: $vloader is not mode 0755 in image" >&2; exit 1; }
    debugfs -R "stat $vloader.vendor" rootfs.ext4 2>/dev/null | grep -qE "Mode: +0755" \
      || { echo "ERROR: $vloader.vendor is not mode 0755 in image" >&2; exit 1; }
    echo "  module loader: curated $vloader + .vendor rollback copy -- verified in image."

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
      /usr/lib/modules/${release}/           <- our from-source kernel modules
                                                (incl. lt6911_manage.ko), depmod'd
                                                (vendor ax_*.ko NOT merged; they
                                                load from /soc/ko -- see step [4])
      /etc/modules-load.d/nanokvm.conf       <- autoloads lt6911_manage + the
                                                mini-display stack (fb_jd9853/
                                                fbtft/gpio_keys/rotary_encoder,
                                                all from-source) at boot
      /kvmcomm/edid/*.bin                    <- clean-room EDID set (pkgs/edid,
                                                E-EDID 1.3 + CTA-861 from source).
                                                ALL SIX vendor bins replaced in
                                                place (filename + byte 12 kept, so
                                                the server EDIDMap / web UI mode
                                                list are unchanged) + NanoKVM-720P60
                                                added. No vendor EDID bytes remain.
      /opt/nanokvm-display/                  <- mini-display status daemon
                                                (pure Python + generated fonts)
      /etc/systemd/system/nanokvm-display.service (enabled)
      /etc/systemd/system/nanokvm-gpio.service (enabled) <- exports the ATX
                                                target power/reset GPIOs at boot
      /etc/default/motd-news (ENABLED=0)     <- disables the Ubuntu motd-news
                                                beacon (no motd.ubuntu.com phone-home)
      /etc/logrotate.d/nanokvm               <- rotates /var/log/nanokvm/*.log
                                                (size 10M, rotate 3, copytruncate;
                                                the vendor logrotate.timer runs daily)
      /etc/systemd/system/wifi.service.d/    <- Restart=no drop-in; ends the vendor
        override.conf                           wifi.service 3s crash-restart loop
                                                (~100 MB/week of syslog churn)
      /soc/scripts/auto_load_all_drv.sh      <- our CURATED /soc/ko module loader:
                                                10 vendor blobs (the ax_proton
                                                capture closure) + our open VCMD
                                                encode driver in place of vendor
                                                ax_venc/ax_jenc (#39, #25)
      /soc/ko/ax630c_venc_vcmd.ko            <- our from-source open VC8000E VCMD
                                                encode driver (blob-free encode)
    removed (encode blobs, #25)  : /soc/ko/ax_venc.ko + /soc/ko/ax_jenc.ko --
                                   the open VCMD driver replaces them; nothing
                                   kept depends on them and libkvm links no
                                   vendor libs. (OTA can't delete; an upgraded
                                   device keeps them unused until reflash.)
      /soc/scripts/auto_load_all_drv.sh.vendor <- pristine vendor loader, kept for
                                                on-device rollback (restore + reboot)
      /etc/rc.local                          <- vendor script minus the axbox
                                                syslog launch (rsyslogd covers it);
                                                pkgs/rootfs/rc.local.vendor is the
                                                pinned original, byte-compared
    removed         : inert CLOSED vendor binaries from the disabled kvmcomm stack
                      (kvm_ui, frameforge, kvm_vin, and its display .ko:
                      fbtft/fb_jd9853/f_udisp_drv/gpio_keys/rotary_encoder/wireguard),
                      the vendor swupdate self-updater (/opt/swupdate/bin/swupdate),
                      and the axbox syslog daemon (/bin/axbox, /sbin/axsyslogd,
                      /sbin/axklogd, /etc/init.d/axsyslogd, /etc/init.d/axklogd,
                      /usr/lib/libax_syslog.so, /opt/lib/libax_syslog.so).
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
    description = "NanoKVM-Pro rootfs: vendor Ubuntu-arm64 base overlaid (no-root debugfs) with our libkvm.so + from-source depmod'd kernel modules";
    platforms = pkgs.lib.platforms.linux;
  };
}
