{ pkgs, size ? 128 * 1024 * 1024, version ? "0.0.0-dev", files ? { }, ... }:

# ===========================================================================
# The `/boot` partition image (p16 `boot`, 128 MiB vfat), from source.
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
# WHAT THE APPLIANCE NEEDS. `/boot` is mounted `nofail,noatime,umask=000` and
# must stay WRITABLE: NanoKVM-Server writes `eth.nodhcp`, `hostname`,
# `usb.disk0`, `usb.ncm`, `usb.uac2`, `usb.disk1.{sd,emmc}` there and reads
# `ver`. So the image ships `ver` and nothing else -- the vendor's two /init
# flags are dead (NixOS stage 1 does the fsck and the resize), `configs` fed a
# module loader the appliance does not have, and every gadget flag is a runtime
# choice, not a shipped default. An empty-but-formatted /boot is the correct
# initial state.
#
# Deterministic: fixed volume id, and every source file carries the store's
# epoch-0 mtime, which mtools clamps to the FAT epoch.
# ===========================================================================

let
  inherit (pkgs) lib;

  content = { ver = "${version}\n"; } // files;

  stage = pkgs.linkFarm "nanokvm-bootfs-files" (lib.mapAttrsToList
    (name: text: { inherit name; path = pkgs.writeText "bootfs-${name}" text; })
    content);
in
pkgs.runCommand "nanokvm-bootfs.fat32"
{
  nativeBuildInputs = [ pkgs.dosfstools pkgs.mtools ];
  meta.description = "NanoKVM-Pro /boot partition image (FAT32, ${toString (size / 1048576)} MiB)";
} ''
  truncate -s ${toString size} bootfs.fat32
  mkfs.fat -F 32 -S 512 -s 1 -R 32 -n BOOT -i 4E4B564D bootfs.fat32

  for f in ${stage}/*; do
    mcopy -i bootfs.fat32 "$f" "::/$(basename "$f")"
  done

  echo "=== /boot contents ==="
  mdir -i bootfs.fat32 ::
  mtype -i bootfs.fat32 ::/ver

  cp bootfs.fat32 "$out"
''
