{ pkgs, maix_ax620e_sdk, boot, dtb-slot-image, kernel-slot-image, rootfs, ... }:

# ===========================================================================
# NON-DESTRUCTIVE microSD BOOT IMAGE  (`.#sd-image`)  -- REAL derivation.
#
# Produces a single `dd`-able raw .img that boots the NanoKVM-Pro (AX630C) from
# a microSD/TF card using our FROM-SOURCE boot chain + kernel + dtb + rootfs,
# WITHOUT touching eMMC. Insert the card to test; pull it to revert to the
# stock eMMC firmware. eMMC is never written.
#
# ---------------------------------------------------------------------------
# WHY THIS IS THE RIGHT LAYOUT  (derived from SDK source, not guessed)
#
# The AX620E BootROM's SD path is FILE-based, not raw-offset. When the ROM
# boots from the SD slot (mmc1 @ 0x104E0000) it reads an MBR partition table,
# mounts the FIRST FAT32 partition and loads the file `boot.bin` from its root
# -- there is NO SPL at a raw LBA. `boot.bin` is the SD-variant SPL
# (boot/bl1/sd, which links FatFS + the SD mmc driver). That SD SPL then loads
# every later stage as a NAMED FILE from the same FAT32 partition. The exact
# filenames are the SPL's own table, boot/bl1/core/boot/boot.c `sd_img_name[]`:
#     [DDRINIT]="0:ddrinit.img" [ATF]="0:atf.img"   [UBOOT]="0:uboot.bin"
#     [OPTEE]  ="0:optee.img"   [DTB]="0:dtb.img"    [KERNEL]="0:kernel.img"
# (drive "0:" = the FAT32 partition). We name our files to match that table
# EXACTLY -- this is the authoritative reader, more reliable than the vendor's
# generic tools/mkaxp/sd_upgrade_pack.py which has a known naming mismatch
# (it calls u-boot "boot.bin" and never emits uboot.bin / ddrinit.img).
#
# The overall MBR layout mirrors the vendor's own SD recipe for THIS board,
# build/projects/AX630C_..._sipeed_nanokvm/gen_sd_image.sh:
#     MBR (msdos):
#       gap   : 1 MiB
#       p1    : FAT32, 128 MiB, boot flag  -> boot.bin + the chain .img files
#       p2    : ext4, rest               -> our overlaid rootfs
# gen_sd_image.sh needs root (losetup/mount); we build the identical bytes with
# NO root: mtools (FAT), the prebuilt raw ext4 from pkgs/rootfs.nix (p2), and
# sfdisk writing the MBR onto a plain file.
#
# ---------------------------------------------------------------------------
# FROM SOURCE (our derivations, dropped into the FAT partition):
#   boot.bin    <- ${boot}/images/spl_<project>_sd_signed.bin  (SD SPL, gc-sec)
#   ddrinit.img <- ${boot}/images/ddrinit_<project>_signed.bin
#   atf.img     <- ${boot}/images/atf_bl31_signed.bin
#   uboot.bin   <- ${boot}/images/u-boot_signed.bin
#   optee.img   <- ${boot}/images/optee_signed.bin
#   dtb.img     <- ${dtb-slot-image}/<project>_signed.dtb   (reserved-mem patched)
#   kernel.img  <- ${kernel-slot-image}/kernel_b.bin        (ax_gzip + signed)
#   (p2 rootfs) <- ${rootfs}/ubuntu_rootfs.ext4  (Ubuntu base + libkvm + modules)
# plus the vendor bootfs helper files (configs / ver / first_time_boot) copied
# verbatim from the SDK project, exactly as gen_sd_image.sh does.
#
# The whole boot chain is signed with the SDK's committed repo dev keys; it
# boots on OPEN boards (SECURE_BOOT_EN efuse unburned) -- see pkgs/boot.nix.
#
# ---------------------------------------------------------------------------
# BOOT-FLOW -- REQUIRES A BUTTON HOLD (confirmed: Sipeed NanoKVM-Pro wiki).
# SD boot is NOT automatic card-detect. The AX630C latches its boot source from
# the CHIP_MODE strap at reset; on the NanoKVM-Pro that strap is the `User`
# button. To boot THIS card you MUST hold `User` while applying power, then
# release -- a normal power-on ALWAYS boots eMMC, card present or not. This
# matches the SPL source (spl_main.c only trusts a ROM-set is_sd_boot flag from
# chip_mode[0]=USB_DL_SD_BOOT; it never probes mmc1-vs-mmc0). So revert is
# trivial and non-destructive: power on WITHOUT holding `User` (or pull the
# card) => stock eMMC, never written. (Holding `User` LONGER instead enters USB
# download mode, so release it right after power-on.)
#   Ref: https://wiki.sipeed.com/hardware/en/kvm/NanoKVM_Pro/faq.html
#
# STATUS: real derivation. The FAT assembly + MBR pipeline is validated no-root.
# Realising it builds pkgs/rootfs.nix (base-axp 1.4 GB fetch + multi-GB ext4) --
# heavy, same caveat as pkgs/image.nix; not exercised end-to-end in the sandbox.
# ===========================================================================

let
  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";

  bootImages = "${boot}/images";
  # Vendor bootfs helper files (configs / ver / first_time_boot / check_resize2fs).
  bootfsDir = "${maix_ax620e_sdk}/build/projects/${project}/bootfs";

  bootPartMiB = 128;   # gen_sd_image.sh BOOT_PART_SIZE_MIB
  gapMiB = 1;          # gen_sd_image.sh first partition starts at 1 MiB
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-pro-sd-image";
  version = "ax630c-sdcard-v1";

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = with pkgs; [
    mtools        # mformat / mcopy  (no-root FAT32)
    dosfstools    # mkfs.vfat
    e2fsprogs     # (rootfs ext4 already built; kept for e2fsck sanity)
    util-linux    # sfdisk
    coreutils
  ];

  # mtools would otherwise refuse to operate on a plain file that is not a
  # recognised removable device.
  MTOOLS_SKIP_CHECK = "1";

  buildPhase = ''
    runHook preBuild
    set -euo pipefail

    sect=512
    fatBytes=$(( ${toString bootPartMiB} * 1024 * 1024 ))

    # ---- 1. FAT32 boot partition: named files the SD SPL (boot.c) reads ----
    echo "=== [1] build FAT32 boot partition (${toString bootPartMiB} MiB) ==="
    dd if=/dev/zero of=boot.fat bs=1M count=${toString bootPartMiB} status=none
    mkfs.vfat -F 32 -n BOOT boot.fat >/dev/null

    # (dest-name-on-FAT , source file) -- names MUST match boot.c sd_img_name[].
    declare -A files=(
      [boot.bin]="${bootImages}/spl_${project}_sd_signed.bin"
      [ddrinit.img]="${bootImages}/ddrinit_${project}_signed.bin"
      [atf.img]="${bootImages}/atf_bl31_signed.bin"
      [uboot.bin]="${bootImages}/u-boot_signed.bin"
      [optee.img]="${bootImages}/optee_signed.bin"
      [dtb.img]="${dtb-slot-image}/${project}_signed.dtb"
      [kernel.img]="${kernel-slot-image}/kernel_b.bin"
    )
    for name in "''${!files[@]}"; do
      src="''${files[$name]}"
      if [ ! -f "$src" ]; then
        echo "ERROR: missing SD boot component for '$name': $src" >&2
        exit 1
      fi
      mcopy -i boot.fat "$src" ::/"$name"
    done

    # Vendor bootfs helper files (harmless if absent), verbatim as gen_sd_image.sh.
    if [ -d "${bootfsDir}" ]; then
      for f in "${bootfsDir}"/*; do
        [ -f "$f" ] && mcopy -i boot.fat "$f" ::/"$(basename "$f")" || true
      done
    fi

    echo "--- FAT32 contents ---"
    mdir -i boot.fat ::/

    # ---- 2. rootfs ext4 (p2): the raw image from pkgs/rootfs.nix ----
    echo "=== [2] stage rootfs ext4 (p2) ==="
    cp "${rootfs}/ubuntu_rootfs.ext4" rootfs.ext4
    chmod u+w rootfs.ext4
    rootBytes=$(stat -c %s rootfs.ext4)

    # ---- 3. assemble MBR disk: gap + FAT + ext4, then write the table ----
    echo "=== [3] assemble MBR disk image ==="
    p1_start=$(( ${toString gapMiB} * 1024 * 1024 / sect ))
    p1_sects=$(( fatBytes / sect ))
    p2_start=$(( p1_start + p1_sects ))
    p2_sects=$(( rootBytes / sect ))
    total_sects=$(( p2_start + p2_sects ))

    truncate -s $(( total_sects * sect )) sdcard.img
    dd if=boot.fat    of=sdcard.img bs=$sect seek=$p1_start conv=notrunc status=none
    dd if=rootfs.ext4 of=sdcard.img bs=$sect seek=$p2_start conv=notrunc status=none

    sfdisk sdcard.img <<SFDISK
    label: dos
    start=$p1_start, size=$p1_sects, type=c, bootable
    start=$p2_start, size=$p2_sects, type=83
    SFDISK

    echo "--- final partition table ---"
    sfdisk -l sdcard.img

    # ---- 4. sanity: FAT partition readable at its LBA, boot.bin present ----
    off=$(( p1_start * sect ))
    mdir -i sdcard.img@@$off ::/boot.bin >/dev/null \
      || { echo "ERROR: boot.bin not readable at partition offset" >&2; exit 1; }

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp sdcard.img "$out/${project}-sdcard.img"

    imgSz=$(stat -c %s "$out/${project}-sdcard.img")
    cat > "$out/SD-CARD-INSTRUCTIONS.txt" <<EOF
    NanoKVM-Pro AX630C -- NON-DESTRUCTIVE self-built microSD boot image.

    file : ${project}-sdcard.img   ($imgSz bytes)
    boots: our from-source SPL/DDR/ATF/OP-TEE/U-Boot + kernel + dtb + rootfs,
           entirely from the microSD. eMMC is NEVER written -- pull the card to
           revert to stock.

    LAYOUT (MBR):
      1 MiB gap
      p1  FAT32  ${toString bootPartMiB} MiB  (boot): boot.bin(=SD SPL) + ddrinit.img +
                 atf.img + uboot.bin + optee.img + dtb.img + kernel.img
      p2  ext4   rest              : rootfs (Ubuntu + libkvm + our modules)

    WRITE IT (Linux) -- pick the RIGHT device or you can wipe your disk:
      1) Find the card:   lsblk    (look for the ~GB removable disk, e.g. sdX / mmcblkN)
      2) Unmount any auto-mounted partitions of that device.
      3) Write (DOUBLE-CHECK of=; this is destructive to the CARD only):
           sudo dd if=${project}-sdcard.img of=/dev/sdX bs=4M oflag=direct conv=fsync status=progress
         (macOS: of=/dev/rdiskN  bs=4m ; use 'diskutil list' + 'diskutil unmountDisk')
      4) sync, then remove the card.

    TEST -- the button hold is REQUIRED (SD boot is not auto-on-insert):
      - Power OFF the NanoKVM-Pro, insert this card.
      - HOLD the \`User\` button while applying power, then RELEASE it right away.
        (A normal power-on always boots eMMC. Holding \`User\` too long enters USB
         download mode instead -- release it just after power comes on.)
      - It boots the self-built firmware from SD.

    REVERT (non-destructive -- eMMC is never written):
      - Power on again WITHOUT holding \`User\` (and/or remove the card)
        -> stock eMMC firmware, untouched.

    WHY THE BUTTON: the AX630C latches its boot source from the CHIP_MODE strap
    at reset; on the NanoKVM-Pro that strap is the \`User\` button (Sipeed wiki:
    wiki.sipeed.com/hardware/en/kvm/NanoKVM_Pro/faq.html). SD boot is a manually
    -triggered path, NOT automatic card detection.
    EOF
    echo "Installed:"; ls -l "$out"
    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro AX630C non-destructive microSD boot image (dd-able): from-source SD SPL + boot chain + kernel + dtb + overlaid rootfs, MBR/FAT32+ext4";
    # Depends on boot.nix / kernel-fip / dtb-fip (ax_gzip x86-64 host tool).
    platforms = [ "x86_64-linux" ];
  };
}
