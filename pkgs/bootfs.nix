{ pkgs
, size ? 128 * 1024 * 1024
, # "vfat" is what the vendor layout carries; "ext4" is what the minimal
  # layout carries (#89 rung 4).
  fsType ? "vfat"
, version ? "0.0.0-dev"
, files ? { }
, payload ? { }
, # A whole directory tree copied into the filesystem root: since #99 that is
  # the /boot NixOS's own extlinux builder wrote for the generation being
  # imaged (nixos/lib/appliance-artifacts.nix, `mkBootDir`). Its file names are
  # store hashes computed at build time, so it cannot be an eval-time attrset.
  payloadDir ? null
, # How many generations the extlinux config may name. Every DISTINCT
  # kernel/initrd pair in that menu is a separate copy under /boot/nixos/, so
  # this is the multiplier in the headroom assertion below, and it must be the
  # same number `generic-extlinux-compatible.configurationLimit` is.
  configurationLimit ? 5
, ...
}:

# ===========================================================================
# The `/boot` partition image, from source.
#
# WHAT THE VENDOR SHIPS, read out of its own member with mtools:
#
#   ver               31 B   "nanokvm-pro-2026-05-29-v1.0.15"
#   configs         2630 B   a MaixPy `maix_*=` settings file, inherited from
#                            the SDK's other boards; nothing in the NanoKVM
#                            stack reads it except the 4.19 module loader
#   check_resize2fs    0 B   flags consumed by the VENDOR /init
#   first_time_boot    0 B
#   usb.ncm            0 B   a USB-gadget feature flag
#
# and the geometry, from the BPB: FAT32, 512 B sectors, 1 sector per cluster,
# 32 reserved sectors, 2 FATs, 262144 total sectors, label BOOT.
#
# WHAT THE APPLIANCE NEEDS. `/boot` is mounted `nofail,noatime` and must stay
# WRITABLE: NanoKVM-Server writes `eth.nodhcp`, `hostname`, `usb.disk0`,
# `usb.ncm`, `usb.uac2`, `usb.disk1.{sd,emmc}` there and reads `ver`. The
# vendor's two /init flags are dead (NixOS stage 1 does the fsck and the
# resize), and `configs` fed a module loader the appliance does not have.
#
# SINCE #89 RUNG 3 IT IS ALSO THE BOOT PAYLOAD. Mainline U-Boot's bootcmd runs
# `sysboot mmc 0:<bootpart> any ... /extlinux/extlinux.conf`, so the kernel,
# the initrd, the device tree and the command line all live here rather than in
# the signed `kernel` and `dtb` partitions the vendor chain loads by byte
# offset. Since #99 that whole tree is written by NixOS's own extlinux builder
# and arrives here as `payloadDir` -- nothing in this file knows the shape of
# it. `extlinux-fallback.conf`, which `altbootcmd` boots when `bootcount`
# passes `bootlimit`, ships as a copy of `extlinux.conf`: the only known-good
# generation on a freshly flashed board is the one being flashed.
#
# EXT4 SINCE #89 RUNG 4. The minimal layout puts /boot on ext4, which retires
# the CONFIG_VFAT_FS + NLS-codepage trap in docs/nixos-rootfs.md (without those
# tables the mount fails -EINVAL and every USB-gadget flag silently reads as
# absent) and lets NixOS generations live here without a case-folding
# filesystem underneath them. U-Boot reads it with the same `sysboot`, because
# `bootmeth_extlinux` goes through the filesystem layer and mainline U-Boot has
# ext4 support compiled in. The flag-file contract is unchanged.
#
# Deterministic in both modes: a fixed volume id / UUID, no timestamps that
# vary, and every source file carries the store's epoch-0 mtime.
# ===========================================================================

let
  inherit (pkgs) lib;

  content = { ver = "${version}\n"; } // files;

  stage = pkgs.linkFarm "nanokvm-bootfs-files" (lib.mapAttrsToList
    (name: text: { inherit name; path = pkgs.writeText "bootfs-${name}" text; })
    content);

  # payload: "path/under/boot" -> store path. Copied in verbatim, so an Image
  # or a dtb goes in without a round trip through a Nix string.
  payloadCopyFat = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: src:
      let dir = builtins.dirOf name; in
      lib.optionalString (dir != ".") "mmd -i bootfs.fat32 \"::/${dir}\" || true"
      + "\n  mcopy -i bootfs.fat32 ${lib.escapeShellArg src} \"::/${name}\"")
    payload);

  payloadCopyExt = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: src:
      let dir = builtins.dirOf name; in
      lib.optionalString (dir != ".") "mkdir -p root/${dir}"
      + "\n  install -m 0644 ${lib.escapeShellArg src} root/${name}")
    payload);

  payloadDirCopyExt = lib.optionalString (payloadDir != null) ''
    cp -r --no-preserve=mode,ownership,timestamps ${payloadDir}/. root/
    find root -type d -exec chmod 0755 {} +
    find root -type f -exec chmod 0644 {} +
  '';

  payloadDirCopyFat = lib.optionalString (payloadDir != null) ''
    (cd ${payloadDir} && find . -type d ! -name .) | sed 's|^\./||' | while read -r d; do
      mmd -i bootfs.fat32 "::/$d" || true
    done
    (cd ${payloadDir} && find . -type f) | sed 's|^\./||' | while read -r f; do
      mcopy -i bootfs.fat32 "${payloadDir}/$f" "::/$f"
    done
  '';

  fat = pkgs.runCommand "nanokvm-bootfs.fat32"
    {
      nativeBuildInputs = [ pkgs.dosfstools pkgs.mtools ];
      meta.description = "NanoKVM-Pro /boot partition image (FAT32, ${toString (size / 1048576)} MiB)";
    } ''
    truncate -s ${toString size} bootfs.fat32
    mkfs.fat -F 32 -S 512 -s 1 -R 32 -n BOOT -i 4E4B564D bootfs.fat32

    for f in ${stage}/*; do
      mcopy -i bootfs.fat32 "$f" "::/$(basename "$f")"
    done

    ${payloadCopyFat}
    ${payloadDirCopyFat}

    echo "=== /boot contents ==="
    mdir -i bootfs.fat32 -/ ::
    mtype -i bootfs.fat32 ::/ver

    cp bootfs.fat32 "$out"
  '';

  ext = pkgs.runCommand "nanokvm-bootfs.ext4"
    {
      nativeBuildInputs = [ pkgs.e2fsprogs ];
      meta.description = "NanoKVM-Pro /boot partition image (ext4, ${toString (size / 1048576)} MiB)";
    } ''
    mkdir root
    for f in ${stage}/*; do
      install -m 0644 "$f" "root/$(basename "$f")"
    done

    ${payloadCopyExt}
    ${payloadDirCopyExt}

    # ROOM FOR `configurationLimit + 1` GENERATIONS, and that is the sizing
    # rule (#99). The extlinux builder copies one kernel + initrd + dtbs set
    # per DISTINCT generation in the menu, and it writes the new set BEFORE it
    # collects the obsolete one -- so the peak, at the moment of a switch, is
    # the whole menu plus the set being replaced. Nothing on the device can
    # grow this partition, and a /boot that fills up mid-switch is a board with
    # half a boot payload, so the headroom is asserted here at build time from
    # the sizes this image actually carries.
    if [ -d root/nixos ]; then
      used=$(du -sb root | cut -f1)
      gen=$(du -sb root/nixos | cut -f1)
      need=$(( used + ${toString configurationLimit} * gen + 16777216 ))
      echo "/boot sizing: content $used B + ${toString configurationLimit} more generations ($gen B each) + 16 MiB slack = $need B of ${toString size} B"
      [ "$need" -le ${toString size} ] || {
        echo "ERROR: /boot (${toString (size / 1048576)} MiB) cannot hold ${toString (configurationLimit + 1)} generations." >&2
        echo "       Either lower boot.loader.generic-extlinux-compatible.configurationLimit" >&2
        echo "       (it must stay above nanokvm.update.keepGenerations), or grow \`boot\`" >&2
        echo "       in nixos/lib/emmc-layout.nix -- which means a new GPT, an SPL rebuild" >&2
        echo "       and an AXDL flash, so do that deliberately." >&2
        exit 1
      }
    fi

    # -d stages the tree, -U pins the UUID, -m 0 keeps no reserved blocks (this
    # filesystem has no privileged writer to reserve them for), and
    # -E hash_seed pins the directory hash so two builds of the same content
    # produce the same bytes.
    truncate -s ${toString size} bootfs.ext4
    mkfs.ext4 -F -q \
      -L BOOT \
      -U 4e4b564d-0000-4000-8000-000000626f6f \
      -E hash_seed=4e4b564d-0000-4000-8000-000000626f6f \
      -m 0 \
      -d root \
      bootfs.ext4

    echo "=== /boot contents ==="
    debugfs -R "ls -l /" bootfs.ext4 2>/dev/null
    echo "=== /boot/extlinux ==="
    debugfs -R "ls -l /extlinux" bootfs.ext4 2>/dev/null || true

    # A filesystem that does not fsck clean is a filesystem the board mounts
    # read-only, and every USB-gadget flag then silently fails to write.
    e2fsck -fn bootfs.ext4

    cp bootfs.ext4 "$out"
  '';
in
if fsType == "ext4" then ext
else if fsType == "vfat" then fat
else throw "bootfs: unknown fsType '${fsType}' (want \"vfat\" or \"ext4\")"
