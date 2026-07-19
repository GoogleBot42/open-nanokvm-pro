{ pkgs, maix_ax620e_sdk, boot, dtb-slot-image, kernel-slot-image, rootfs, ... }:

# ===========================================================================
# Non-destructive microSD boot image (`.#sd-image`): a single `dd`-able raw
# .img that boots the from-source boot chain + kernel + dtb + rootfs from an
# SD/TF card, leaving eMMC untouched. SD boot is an officially supported path
# (Sipeed FAQ: wiki.sipeed.com/hardware/en/kvm/NanoKVM_Pro/faq.html) and is
# manually triggered: hold `User` while applying power, release immediately.
# A normal power-on always boots eMMC, card present or not.
#
# LAYOUT (mirrors the vendor gen_sd_image.sh for this board):
#   MBR: 1 MiB gap
#     p1  FAT32 (type 0x0c, boot flag), 128 MiB: boot.bin + chain images
#     p2  ext4, rest: our overlaid rootfs
# built with no root: mtools/mkfs.vfat for the FAT, sfdisk for the MBR, and the
# prebuilt raw ext4 from pkgs/rootfs.nix as p2.
#
# The AX620E BootROM's SD path is FILE-based, not raw-offset: the ROM mounts the
# first FAT32 partition and loads `boot.bin` (the boot/bl1/sd SPL variant, which
# links FatFS + the SD mmc driver). It records the SD channel by writing
# DL_CHAN_SD (0x6) into COMM_SYS_DUMMY_SW5; the SPL's setup_boot_mode()
# (boot/bl1/spl/spl_main.c) trusts that flag and never probes for a card. The
# SPL then loads each later stage as a named file from the same FAT partition --
# the names are the SPL's own table, boot/bl1/core/boot/boot.c sd_img_name[]:
#     [DDRINIT]="0:ddrinit.img" [ATF]="0:atf.img"   [UBOOT]="0:uboot.bin"
#     [OPTEE]  ="0:optee.img"   [DTB]="0:dtb.img"   [KERNEL]="0:kernel.img"
# We name our files to match that table exactly. (The vendor's generic
# tools/mkaxp/sd_upgrade_pack.py has a naming mismatch -- it calls u-boot
# "boot.bin" and never emits uboot.bin -- so the SPL table, not that tool, is
# the authoritative reference.) Notes:
#   - The SD SPL is built with AX620E_SUPPORT_SD: DDR init is compiled in
#     (mc20e_ddr_init) and OPTEE_BOOT is off, so ddrinit.img / optee.img are
#     never actually read on the SD path; they are kept to match the vendor
#     recipe and cost nothing.
#   - The SPL's FatFS has LFN disabled (ffconf.h FF_USE_LFN=0): every file on
#     the FAT partition must have an 8.3 name. 512-byte sectors; no exFAT.
#
# CONSOLE: the flake wires in the UART1 variants (boot-sd, dtb-slot-image-sd)
# so every stage from the SPL on logs to ttyS1 (0x4881000, the exposed header
# pin). Everything BEFORE our SPL -- the mask ROM -- prints only on UART0, so a
# card that never reaches our SPL is silent on UART1 by construction.
#
# STATUS: not yet verified on hardware -- the first attempt produced no boot
# (no UART1 output). Secure boot is ruled out (the dev-key-signed
# .#firmware-image boots from eMMC on the same unit); remaining suspects are
# strap timing, ROM FAT parsing, and SD-SPL DDR auto-training. See
# docs/flashing-and-recovery.md "If the card does not boot".
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
    NanoKVM-Pro AX630C -- non-destructive self-built microSD boot image.

    file : ${project}-sdcard.img   ($imgSz bytes)
    boots: our from-source SPL/DDR/ATF/OP-TEE/U-Boot + kernel + dtb + rootfs,
           entirely from the microSD. eMMC is never written -- pull the card to
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

    BOOT -- the button hold is REQUIRED (SD boot is not auto-on-insert):
      - Power OFF the NanoKVM-Pro, insert this card.
      - HOLD the \`User\` button while applying power, then RELEASE it right away.
        (A normal power-on always boots eMMC. Holding \`User\` too long enters USB
         download mode instead -- release it just after power comes on.)
      - Console: ttyS1 / UART1 on the exposed header pin, 115200 8N1. Everything
        BEFORE our SPL (the mask ROM) prints only on UART0, so if the ROM never
        loads boot.bin the UART1 line stays silent.

    REVERT (non-destructive -- eMMC is never written):
      - Power on again WITHOUT holding \`User\` (and/or remove the card)
        -> stock eMMC firmware, untouched.

    STATUS: this image has not yet been verified to boot on hardware. If it does
    not boot, see docs/flashing-and-recovery.md "If the card does not boot"
    (dual-UART capture + the official Sipeed SD image as a control).
    EOF
    echo "Installed:"; ls -l "$out"
    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro AX630C non-destructive microSD boot image (dd-able): from-source SD SPL + boot chain + kernel + dtb + overlaid rootfs, MBR/FAT32+ext4";
    # Inherits the x86-64-only ax_gzip constraint via boot / slot-image.
    platforms = [ "x86_64-linux" ];
  };
}
