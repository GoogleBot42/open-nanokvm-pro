{ pkgs, crossPkgs, ... }:

# ---------------------------------------------------------------------------
# Bring-up initramfs for the mainline kernel (#75, epic #26).
#
# Baked into `.#kernel-mainline` via CONFIG_INITRAMFS_SOURCE. One static
# aarch64 binary as /init and nothing else -- no busybox, no shell. See
# kernel-mainline/initramfs/bringup-init.c for what it does and why: the
# mainline kernel has no storage driver yet (#76), so there is no root to
# switch to, and this program's entire purpose is to leave evidence that
# userspace ran, in places the vendor system can read after the next boot.
#
# Distinct from pkgs/initramfs.nix, which is the SHIPPING 4.19 initramfs
# (vendor /init + busybox). Nothing is shared between them on purpose: this one
# must not depend on anything the mainline port has not yet built.
# ---------------------------------------------------------------------------

let
  # aarch64 + musl, fully static: no interpreter, no shared libs, and no glibc
  # memset/memcpy (whose DC ZVA SIGBUSes on a Device-memory /dev/mem mapping --
  # the program uses word loops regardless, but a static musl removes the
  # possibility of the compiler emitting a call to one).
  staticPkgs = crossPkgs.pkgsStatic;
in
staticPkgs.stdenv.mkDerivation {
  pname = "nanokvm-pro-initramfs-mainline";
  version = "1";

  dontUnpack = true;

  nativeBuildInputs = [ pkgs.cpio ];

  src = ./kernel-mainline/initramfs/bringup-init.c;

  buildPhase = ''
    runHook preBuild

    tree=$PWD/tree
    mkdir -p "$tree/dev" "$tree/proc" "$tree/sys"

    $CC -O2 -static -Wall -Wextra -Werror -o "$tree/init" "$src"
    $STRIP "$tree/init"
    chmod 0755 "$tree/init"

    # A static binary is the whole point: a dynamic /init would need a loader
    # and a libc in here, and there is no rootfs to find them on.
    if $READELF -l "$tree/init" | grep -q INTERP; then
      echo "ERROR: /init is dynamically linked" >&2
      exit 1
    fi

    # Deterministic archive, same recipe as pkgs/initramfs.nix: epoch mtimes,
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
    description = "NanoKVM-Pro mainline bring-up initramfs (#75): one static init that leaves boot evidence in reserved DRAM";
    license = pkgs.lib.licenses.gpl2Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
