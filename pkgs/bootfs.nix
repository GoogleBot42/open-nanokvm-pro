{ pkgs
, size ? 128 * 1024 * 1024
, # "vfat" is what the vendor layout carries; "ext4" is what the minimal
  # layout carries (#89 rung 4).
  fsType ? "vfat"
, version ? "0.0.0-dev"
, files ? { }
, payload ? { }
  # Whole directories copied in recursively, "path/under/boot" -> store dir.
  # The video stack's kernel modules ride here (#83): they belong to the same
  # artefact as the Image and the dtb, not to the NixOS closure.
, payloadDirs ? { }
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
# the device tree and the command line all live here rather than in the signed
# `kernel` and `dtb` partitions the vendor chain loads by byte offset.
# `payload` is the attrset that carries them; a name may contain `/` and the
# directory is created. `extlinux-fallback.conf` is what `altbootcmd` boots
# when `bootcount` passes `bootlimit`; it ships as a copy of `extlinux.conf`,
# which is the correct initial state -- the only known-good generation is the
# one being installed.
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

  payloadDirsCopyFat = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: src: ''
      mmd -i bootfs.fat32 "::/${name}" || true
      for f in ${lib.escapeShellArg src}/*; do
        mcopy -i bootfs.fat32 "$f" "::/${name}/$(basename "$f")"
      done'')
    payloadDirs);

  payloadDirsCopyExt = lib.concatStringsSep "\n" (lib.mapAttrsToList
    (name: src: ''
      mkdir -p root/${name}
      for f in ${lib.escapeShellArg src}/*; do
        install -m 0644 "$f" "root/${name}/$(basename "$f")"
      done'')
    payloadDirs);

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
    ${payloadDirsCopyFat}

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
    ${payloadDirsCopyExt}

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
