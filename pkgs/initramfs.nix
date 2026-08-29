{ pkgs, crossPkgs, maix_ax620e_sdk, ... }:

# ---------------------------------------------------------------------------
# Embedded kernel initramfs -- from source, no vendor binaries.
#
# The kernel bakes this cpio into the Image (CONFIG_INITRAMFS_SOURCE, see
# pkgs/kernel.nix). Its /init is the ONLY path to userspace: it parses root=
# from /proc/cmdline, picks eMMC (mmcblk0p17) vs SD (mmcblk1p2), mounts the
# real rootfs at /realroot (e2fsck / resize2fs on demand), then
# `exec switch_root /realroot /sbin/init`. The kernel never mounts root=
# itself, so a missing or broken initramfs = no userspace.
#
# The vendor SDK ships a prebuilt initramfs/ tree (busybox 1.37.0, e2fsck,
# ld-linux-aarch64.so.1, libc.so.6, libuuid.so.1.3.0 -- five aarch64 blobs).
# We keep the vendor /init and /show_iostat SHELL SCRIPTS verbatim (they encode
# the board's boot contract: partition numbers, LED triggers, USB-MSC recovery
# gadget, device_key/MAC derivation) and rebuild every BINARY from nixpkgs.
#
# Static (musl) rather than glibc-dynamic: it drops ld-linux + libc + libuuid
# from the image entirely -- five blobs replaced by two from-source binaries,
# and no runtime loader/RPATH surface at all. The tree is also ~1.7 MB smaller
# than the vendor's.
#
# Applet coverage: nixpkgs' busybox 1.37.0 config is a superset of the vendor's
# for everything /init and /show_iostat touch (usleep, switch_root, blockdev,
# iostat, dmesg, sha512sum, df, awk, sed, find, fdisk, ...). The only vendor
# applets it lacks are `last runlevel users w wall who linuxrc` (utmp toys,
# unused here) and `tune2fs` -- /init deliberately does NOT use a busybox
# tune2fs, it copies /realroot/opt/e2fs-static/{tune2fs,resize2fs} out of the
# real rootfs before unmounting it. `fsck.vfat` is referenced by /init's
# bootfs-recovery path but is absent from the VENDOR tree too (dosfstools is
# not shipped), so that call fails identically on both.
# ---------------------------------------------------------------------------

let
  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";

  # aarch64 + musl, fully static: no interpreter, no shared libs.
  staticPkgs = crossPkgs.pkgsStatic;
  busybox = staticPkgs.busybox;
  e2fsprogs = staticPkgs.e2fsprogs;

  # aarch64 `strip` (the gnu-triple binutils already used by pkgs/kernel.nix
  # handles the musl-triple ELFs -- same arch, same format).
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;

  vendorTree = "${maix_ax620e_sdk}/build/projects/${project}/initramfs";
in
pkgs.stdenv.mkDerivation {
  pname = "nanokvm-pro-initramfs";
  version = busybox.version;

  dontUnpack = true;

  nativeBuildInputs = [ pkgs.cpio crossPkgs.buildPackages.binutils ];

  # Reproduces the vendor build/projects/${project}/gen_initramfs.sh: ensure
  # proc/sys/dev exist, chmod +x init, `find . | cpio -o --format=newc`.
  # `-R 0:0` forces root:root ownership in the archive (the vendor builds as
  # root; the defconfig sets CONFIG_INITRAMFS_ROOT_UID/GID=0).
  buildPhase = ''
    runHook preBuild

    tree=$PWD/tree
    mkdir -p "$tree"/bin "$tree"/proc "$tree"/sys "$tree"/dev

    install -m0755 ${vendorTree}/init "$tree/init"
    install -m0755 ${vendorTree}/show_iostat "$tree/show_iostat"

    install -m0755 ${busybox}/bin/busybox "$tree/bin/busybox"
    install -m0755 ${e2fsprogs.bin}/bin/e2fsck "$tree/bin/e2fsck"
    ${crossPrefix}strip "$tree/bin/busybox" "$tree/bin/e2fsck"

    # /init sets PATH=/bin, so every applet lives in /bin (the vendor tree has
    # no /sbin). nixpkgs splits them across bin/ and sbin/; flatten the union.
    applets=$(find ${busybox}/bin ${busybox}/sbin -mindepth 1 -maxdepth 1 \
                -printf '%f\n' | sort -u)
    for a in $applets; do
      if [ "$a" != busybox ]; then ln -sf busybox "$tree/bin/$a"; fi
    done

    # Nothing may be dynamically linked: a /lib in here would mean a libc blob.
    if [ -e "$tree/lib" ]; then
      echo "ERROR: initramfs grew a /lib -- something is dynamically linked." >&2
      exit 1
    fi

    # Deterministic archive: normalize every mtime to the epoch, sort the
    # entries, and pass --reproducible so the newc headers carry no build-time
    # mtime/inode noise -- otherwise the cpio (and the kernel Image that embeds
    # it) is not bit-reproducible, breaking the "verifiable from source" story.
    find "$tree" -exec touch -h -d @0 {} +
    ( cd "$tree" && find . -print0 | LC_ALL=C sort -z \
        | cpio --null -o --format=newc -R 0:0 --reproducible ) > initramfs_rootfs.cpio

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp initramfs_rootfs.cpio "$out/initramfs_rootfs.cpio"
    ( cd tree && find . -printf '%M %8s %P -> %l\n' | sort -k3 ) > "$out/contents.txt"
    echo "initramfs cpio: $(stat -c%s "$out/initramfs_rootfs.cpio") bytes"
    runHook postInstall
  '';

  # The payload is a cpio of already-stripped aarch64 binaries.
  dontFixup = true;

  meta = {
    description = "NanoKVM-Pro embedded kernel initramfs (static busybox + e2fsck from nixpkgs; vendor /init kept)";
    license = pkgs.lib.licenses.gpl2Plus;
    platforms = pkgs.lib.platforms.linux;
  };
}
