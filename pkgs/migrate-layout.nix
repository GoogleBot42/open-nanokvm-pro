{ pkgs
, lib ? pkgs.lib
, atf-mainline
, uboot-mainline
, spl-minimal
, uboot-env
, bootfs # the ext4 /boot image for the MINIMAL layout
, project
, layout ? import ../nixos/emmc-partitions.nix { inherit (pkgs) lib; layout = "minimal"; }
, vendorLayout ? import ../nixos/emmc-partitions.nix { inherit (pkgs) lib; layout = "vendor"; }
, ...
}:

# ===========================================================================
# The in-place layout migration kit (#89 rung 4).
#
#   nix build .#migrate-layout
#   tar -C result -cf - . | tools/kvmssh 'mkdir -p /root/rung4-kit && tar -C /root/rung4-kit -xf -'
#   tools/kvmssh '/root/rung4-kit/bin/migrate-layout backup'
#   tools/kvmssh '/root/rung4-kit/bin/migrate-layout write'
#   # ... coordinator's go ...
#   tools/kvmssh '/root/rung4-kit/bin/migrate-layout spl --i-have-the-go'
#
# WHY A KIT AND NOT A FLASH. The board already runs the mainline chain; only
# the layout changes. Rewriting five partitions in place from a shell keeps the
# 29 GiB rootfs exactly where it is (both layouts start it at the same byte)
# and keeps every step before p1 reversible from that same shell. An AXDL
# flash would be simpler and would also erase the machine.
#
# EVERY IMAGE IS PADDED TO A 4 KiB MULTIPLE. The signed containers are not:
# BL31 is 14592 B, U-Boot 184168 B. Padding with zeros lets the script `dd` in
# whole 4 KiB blocks and, more importantly, read the same span back and hash
# it -- a byte-exact read-back check needs a block-aligned length. The SPL
# reads `img_size` out of the header and ignores whatever follows, so the pad
# is invisible to the boot.
# ===========================================================================

let
  hex = layout.hex;

  pad = name: src: pkgs.runCommand "padded-${name}" { } ''
    cp ${src} img
    chmod u+w img
    sz=$(stat -c %s img)
    want=$(( (sz + 4095) / 4096 * 4096 ))
    truncate -s "$want" img
    echo "${name}: $sz B -> $want B (4 KiB aligned)"
    cp img "$out"
  '';

  images = {
    "spl.bin" = pad "spl" "${spl-minimal}/images/spl_${project}_signed.bin";
    "atf.bin" = pad "atf" "${atf-mainline}/images/atf_bl31_mainline_signed.bin";
    "uboot.bin" = pad "uboot" "${uboot-mainline}/images/u-boot_mainline_signed.bin";
    "env.bin" = pad "env" "${uboot-env}";
  };

  subst = {
    SPL_OFF = toString (layout.need "spl").offset;
    SPL_SIZE = toString (layout.need "spl").size;
    ATF_OFF = toString (layout.need "atf").offset;
    ATF_SIZE = toString (layout.need "atf").size;
    UBOOT_OFF = toString (layout.need "uboot").offset;
    UBOOT_SIZE = toString (layout.need "uboot").size;
    ENV_OFF = toString (layout.need "env").offset;
    ENV_SIZE = toString (layout.need "env").size;
    BOOT_OFF = toString (layout.need "boot").offset;
    BOOT_SIZE = toString (layout.need "boot").size;
    ROOT_OFF = toString layout.root.offset;
    NEW_ROOT_DEV = layout.root.device;
    OLD_ROOT_DEV = vendorLayout.root.device;
    CLAUSE = layout.blkdevparts;
    FW_ENV = lib.removeSuffix "\n" layout.fwEnvConfig;
  };

  substArgs = lib.concatStringsSep " "
    (lib.mapAttrsToList (k: v: "--subst-var-by ${k} ${lib.escapeShellArg v}") subst);

  copyImages = lib.concatStringsSep "\n"
    (lib.mapAttrsToList (n: p: "cp ${p} \"$out/images/${n}\"") images);
in
pkgs.runCommand "nanokvm-migrate-layout"
{
  nativeBuildInputs = [ pkgs.gzip ];
  meta.description =
    "In-place eMMC layout migration kit for the NanoKVM-Pro (#89 rung 4): "
    + "the vendor 17-partition map -> the minimal six, rootfs untouched";
} ''
  mkdir -p "$out/bin" "$out/images"

  substitute ${../tools/migrate-layout.sh.in} "$out/bin/migrate-layout" ${substArgs}
  chmod +x "$out/bin/migrate-layout"
  ! grep -n '@[A-Z_]\+@' "$out/bin/migrate-layout" \
    || { echo "ERROR: unsubstituted placeholder in migrate-layout" >&2; exit 1; }

  ${copyImages}

  # 275 MiB of mostly-zero ext4 compresses to a few MiB, which is the
  # difference between a fast scp and a slow one over the board's link.
  gzip -9 -c ${bootfs} > "$out/images/bootfs.ext4.gz"

  cat > "$out/LAYOUT.txt" <<'EOF'
  ${layout.table}
  EOF
  sed -i 's/^  //' "$out/LAYOUT.txt"

  {
    echo "target layout: ${layout.blkdevparts}"
    echo "fw_env.config: ${lib.removeSuffix "\n" layout.fwEnvConfig}"
    echo
    echo "images (sha256, as written to the medium):"
    for f in "$out"/images/*; do
      printf '  %s  %s  %s B\n' "$(sha256sum "$f" | cut -d' ' -f1)" \
        "$(basename "$f")" "$(stat -c %s "$f")"
    done
  } > "$out/MANIFEST.txt"
  cat "$out/MANIFEST.txt"
''
