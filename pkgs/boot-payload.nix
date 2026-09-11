{ pkgs
, lib ? pkgs.lib
, kernelImage # the kernel Image (stage-1 initrd baked in)
  # The video stack's kernel modules (#83), or null. They go in under the
  # kernel's own content hash, for the same reason the kernel is hashed: /boot
  # holds two kernels, and one unversioned module directory would hand the
  # fallback kernel the other kernel's modules -- which would LOAD (same
  # vermagic, no MODVERSIONS) and be silently wrong.
, modules ? null
, dtb # the device tree blob
, dtbName ? "ax630c-nanokvm-pro.dtb"
, label ? "NixOS appliance, mainline"
, ...
}:

# ===========================================================================
# THE /boot BOOT PAYLOAD, CONTENT-ADDRESSED (#86).
#
# WHY THE NAMES CARRY A HASH. Until #86 there was one `/boot/Image` and one
# `/boot/ax630c-nanokvm-pro.dtb`, shared by `extlinux.conf` and
# `extlinux-fallback.conf`. That made the rollback a USERSPACE rollback only:
# the two configs could name two generations, but never two kernels, so a
# kernel update had nothing to fall back to and `/boot/Image.prev` was a manual
# stand-in (docs/mainline-port.md 11.10).
#
# Naming each kernel `Image-<16 hex of its sha256>` fixes that with no new
# mechanism: an update writes its kernel under a name nothing else uses, the
# config it installs names that file, and the fallback config keeps naming the
# one that booted. Two kernels coexist in /boot; `nanokvm-mark-good` deletes
# whatever neither config names once a boot has proven itself.
#
# ONE GENERATOR FOR BOTH SIDES. The device's `nanokvm-install-boot` writes a
# config by substituting @KERNEL@, @FDT@ and @INIT@ in a template rendered from
# pkgs/extlinux.nix; this derivation renders the SAME template from the SAME
# file and substitutes the first two here. So the flashed image's config and an
# updated one differ only in the values, never in the shape -- and
# `nix flake check`'s `boot-payload-template` asserts it.
#
# THE BAKED CONFIG CARRIES NO `init=`, and that is deliberate: a freshly
# flashed board boots `/init`, the symlink to the system profile, so the image
# needs no knowledge of its own store path. `nanokvm-install-boot` pins `init=`
# from the first update onward, which is what makes the two configs name two
# different generations.
# ===========================================================================

let
  mkTemplate = init: pkgs.writeText "extlinux.conf.in" (import ./extlinux.nix {
    inherit pkgs lib label init;
    kernelFile = "@KERNEL@";
    dtbFile = "@FDT@";
    bootId = "@KERNEL@,@FDT@";
  });

  # The template the DEVICE substitutes: all three placeholders live.
  template = mkTemplate "@INIT@";
  # The template the flashed image uses: no `init=` token at all.
  templateNoInit = mkTemplate "";
in
pkgs.runCommand "nanokvm-boot-payload"
{
  nativeBuildInputs = [ pkgs.coreutils pkgs.gnused pkgs.gnugrep ];
  meta.description =
    "NanoKVM-Pro /boot payload: a content-addressed kernel + dtb and the two extlinux configs that name them";
} ''
  mkdir -p "$out/boot/extlinux"

  kh=$(sha256sum ${kernelImage} | cut -c1-16)
  dh=$(sha256sum ${dtb} | cut -c1-16)
  kname="Image-$kh"
  dname="${lib.removeSuffix ".dtb" dtbName}-$dh.dtb"

  install -m 0644 ${kernelImage} "$out/boot/$kname"
  install -m 0644 ${dtb}         "$out/boot/$dname"

  ${lib.optionalString (modules != null) ''
    mname="modules-$kh"
    mkdir -p "$out/boot/$mname"
    install -m 0644 ${modules}/* "$out/boot/$mname/"
    # nanokvm-video.service reads this, in this order; the kernel build wrote
    # it from its own depmod run.
    [ -r "$out/boot/$mname/load-order" ] \
      || { echo "ERROR: the module set carries no load-order" >&2; exit 1; }
  ''}

  sed -e "s|@KERNEL@|/$kname|g" -e "s|@FDT@|/$dname|g" \
    ${templateNoInit} > "$out/boot/extlinux/extlinux.conf"
  # The only known-good generation on a freshly flashed board is the one being
  # flashed, so the fallback starts as a copy. nanokvm-mark-good rewrites it
  # with a pinned `init=` the first time a boot proves healthy.
  cp "$out/boot/extlinux/extlinux.conf" "$out/boot/extlinux/extlinux-fallback.conf"

  # The device-side template, shipped beside the payload so the check (and a
  # human) can diff the shape the installer will produce against this one.
  install -m 0644 ${template} "$out/extlinux.conf.in"

  # What the rest of the build needs to know, without re-hashing anything.
  {
    echo "KERNEL=$kname"
    echo "FDT=$dname"
    echo "KERNEL_SHA256=$(sha256sum ${kernelImage} | cut -d' ' -f1)"
    echo "FDT_SHA256=$(sha256sum ${dtb} | cut -d' ' -f1)"
    echo "KERNEL_BYTES=$(stat -Lc%s ${kernelImage})"
    echo "FDT_BYTES=$(stat -Lc%s ${dtb})"
    ${lib.optionalString (modules != null) ''echo "MODULES=modules-$kh"''}
  } > "$out/NAMES"

  # --- contract checks ---------------------------------------------------
  # Nothing may reach /boot with a placeholder still in it: a config naming
  # "@KERNEL@" is a board that loads nothing, with no console to say so.
  ! grep -q '@[A-Z]*@' "$out/boot/extlinux/extlinux.conf" \
    || { echo "ERROR: unsubstituted placeholder in the baked extlinux.conf" >&2; exit 1; }
  grep -q "LINUX /$kname" "$out/boot/extlinux/extlinux.conf" \
    || { echo "ERROR: the config does not name the kernel it ships" >&2; exit 1; }
  grep -q "FDT /$dname" "$out/boot/extlinux/extlinux.conf" \
    || { echo "ERROR: the config does not name the dtb it ships" >&2; exit 1; }
  grep -q "nanokvmboot=/$kname,/$dname" "$out/boot/extlinux/extlinux.conf" \
    || { echo "ERROR: the config carries no nanokvmboot= token -- mark-good could" >&2
         echo "       not tell which kernel booted, so the kernel rollback is dead." >&2; exit 1; }
  # The device template must still have all three placeholders, or
  # nanokvm-install-boot writes a config that names the build host's choices.
  for p in '@KERNEL@' '@FDT@' '@INIT@'; do
    grep -qF "$p" "$out/extlinux.conf.in" \
      || { echo "ERROR: the installer template lost $p" >&2; exit 1; }
  done

  echo "=== /boot payload ==="
  cat "$out/NAMES"
  ls -lR "$out"
  cat "$out/boot/extlinux/extlinux.conf"
''
