{ pkgs, crossPkgs, ... }:

# ---------------------------------------------------------------------------
# Bring-up initramfs for the mainline kernel (#75, #77; epic #26).
#
# Baked into `.#kernel-mainline` via CONFIG_INITRAMFS_SOURCE. /init is one
# static aarch64 binary -- see kernel-mainline/initramfs/bringup-init.c for
# what it does and why: the mainline kernel has no rootfs to switch to, so this
# program's job is to leave evidence that userspace ran, in places the vendor
# system can read after the next boot.
#
# #77 added the second half: once Ethernet works, the honest proof is a shell.
# So the tree now also carries a static busybox (udhcpc, ip, ping, sh) and a
# static dropbear. /init brings the link up, takes a DHCP lease and starts
# dropbear; the dwell then holds the board there long enough to log in.
#
# No credentials are built in. The MAC and the root password hash are harvested
# at runtime from the eMMC rootfs that #76's probe already mounts read-only,
# which is what makes `tools/kvmssh` reach the mainline system with the same
# address and the same password as the vendor one.
#
# The only initramfs this repo builds by hand. The appliance's initrd is the
# NixOS generation's, written by the extlinux builder (#99). Once distinct from
# the 4.19 image's embedded initramfs
# (vendor /init + busybox). Nothing is shared between them on purpose: this one
# must not depend on anything the mainline port has not yet built.
# ---------------------------------------------------------------------------

let
  # aarch64 + musl, fully static: no interpreter, no shared libs, and no glibc
  # memset/memcpy (whose DC ZVA SIGBUSes on a Device-memory /dev/mem mapping --
  # the program uses word loops regardless, but a static musl removes the
  # possibility of the compiler emitting a call to one).
  staticPkgs = crossPkgs.pkgsStatic;
  busybox = staticPkgs.busybox;
  # Static dropbear pulls in libxcrypt, which matters: the vendor rootfs hashes
  # root's password with yescrypt ($y$), and musl's own crypt() cannot verify
  # that. libxcrypt can.
  dropbear = staticPkgs.dropbear;
in
staticPkgs.stdenv.mkDerivation {
  pname = "nanokvm-pro-initramfs-mainline";
  version = "2";

  dontUnpack = true;

  nativeBuildInputs = [ pkgs.cpio ];

  src = ./kernel-mainline/initramfs/bringup-init.c;
  udhcpcScript = ./kernel-mainline/initramfs/udhcpc.script;

  buildPhase = ''
    runHook preBuild

    tree=$PWD/tree
    # /mnt is where #76's storage probe mounts the eMMC rootfs read-only.
    # /etc/dropbear holds the host key /init generates at boot; /run holds the
    # DHCP result the udhcpc script writes.
    mkdir -p "$tree/dev/pts" "$tree/proc" "$tree/sys" "$tree/mnt" \
             "$tree/bin" "$tree/etc/dropbear" "$tree/root" "$tree/run" \
             "$tree/tmp"

    $CC -O2 -static -Wall -Wextra -Werror -o "$tree/init" "$src"
    $STRIP "$tree/init"
    chmod 0755 "$tree/init"

    install -m0755 ${busybox}/bin/busybox        "$tree/bin/busybox"
    install -m0755 ${dropbear}/bin/dropbear      "$tree/bin/dropbear"
    install -m0755 ${dropbear}/bin/dropbearkey   "$tree/bin/dropbearkey"
    $STRIP "$tree/bin/busybox" "$tree/bin/dropbear" "$tree/bin/dropbearkey"

    # Applet symlinks. /init execs busybox
    # by absolute path for the two applets it needs, but a login shell wants
    # the usual names on PATH.
    applets=$(find ${busybox}/bin ${busybox}/sbin -mindepth 1 -maxdepth 1 \
                -printf '%f\n' | sort -u)
    for a in $applets; do
      if [ "$a" != busybox ]; then ln -sf busybox "$tree/bin/$a"; fi
    done
    ln -sf bin "$tree/sbin"

    install -m0755 "$udhcpcScript" "$tree/etc/udhcpc.script"

    # root's shell and home. /etc/shadow is NOT here: /init writes it at boot
    # from the hash it reads off the eMMC rootfs, so no password material is
    # ever in this store path or in the kernel Image.
    printf 'root:x:0:0:root:/root:/bin/sh\n' > "$tree/etc/passwd"
    printf 'root:x:0:\ntty:x:5:\n'          > "$tree/etc/group"

    # A static binary is the whole point: a dynamic /init would need a loader
    # and a libc in here, and there is no rootfs to find them on.
    for b in init bin/busybox bin/dropbear bin/dropbearkey; do
      if $READELF -l "$tree/$b" | grep -q INTERP; then
        echo "ERROR: $b is dynamically linked" >&2
        exit 1
      fi
    done

    # Deterministic archive: epoch mtimes,
    # sorted entries, --reproducible, root:root. The Image embeds this, so a
    # non-reproducible cpio would make the kernel non-reproducible.
    find "$tree" -exec touch -h -d @0 {} +
    ( cd "$tree" && find . -print0 | LC_ALL=C sort -z \
        | cpio --null -o --format=newc -R 0:0 --reproducible ) > initramfs-mainline.cpio

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp initramfs-mainline.cpio "$out/initramfs-mainline.cpio"
    cp "$tree/init" "$out/init"
    echo "bring-up initramfs cpio: $(stat -c%s "$out/initramfs-mainline.cpio") bytes"
    runHook postInstall
  '';

  dontFixup = true;

  meta = {
    description = "NanoKVM-Pro mainline bring-up initramfs (#75/#77): a static init that leaves boot evidence in reserved DRAM, brings up Ethernet and serves a shell";
    license = pkgs.lib.licenses.gpl2Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
