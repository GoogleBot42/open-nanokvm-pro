args@{ pkgs, maix_ax620e_sdk, kernel-slot-image, rootfs, ... }:

# ===========================================================================
# Non-destructive microSD boot image (`.#sd-image`): a single `dd`-able raw
# .img that boots the from-source boot chain + kernel + dtb + rootfs from an
# SD/TF card, leaving eMMC untouched. SD boot is an officially supported path
# (Sipeed FAQ: wiki.sipeed.com/hardware/en/kvm/NanoKVM_Pro/faq.html) and is
# manually triggered: hold `User` while applying power, release immediately.
# A normal power-on always boots eMMC, card present or not.
#
# BOOT MECHANISM (CONFIRMED 2026-07 against the official v1.0.15 SD image AND
# a live device running it): the BootROM SD-SPL path, not U-Boot `sd_update`.
#   BootROM (User strap) -> mounts MBR p1 FAT32, loads `boot.bin` (the
#   boot/bl1/sd SPL variant with FatFS; official boot.bin carries the same
#   0x55543322 img_header, img_size ~50K, zero-padded to exactly 262144 B)
#   -> SPL loads atf.img + uboot.bin as named FAT files (boot.c sd_img_name[])
#   -> the Sipeed-patched U-Boot's `sd_boot` cmd (cmd/axera/sd_boot/sd_boot.c,
#      gated on boot_info_data.mode == SD_BOOT_MODE, i.e. it only fires on a
#      ROM SD boot) sets env bootargs = BOOTARGS_SD
#      ("... console=ttyS0 ... root=/dev/mmcblk1p2 rw rootdelay=3 ...", with
#      mem= rewritten from `configs`), fatloads kernel.img + dtb.img from
#      mmc 1:1 (skipping their 1 KiB img_header, gzip payload), and `booti`s.
#   Evidence: the live rescue device's /proc/cmdline is BOOTARGS_SD verbatim
#   (incl. the runtime-computed mem=824M), and U-Boot's `sd_update` is an
#   eMMC/flash WRITER (blk_dwrite/mtd_write), i.e. the FAQ's separate
#   "flash eMMC after booting from SD" step, not the live-boot path.
#
# LAYOUT -- byte-matched to the official 20260529_NanoKVMPro_1_0_15_sdcard.img
# (which boots the exact unit our first attempt failed on):
#   MBR (disk id 0x3e7afe58, same as official): 1 MiB gap (zeros, like official)
#     p1  FAT32 (type 0x0c, boot flag), sectors 2048..264191 (128 MiB)
#     p2  ext4 (type 0x83), rest: our overlaid rootfs
#   p1 filesystem replicates the official BPB byte-for-byte:
#     512 B/sector, 1 sector/cluster, 32 reserved, 2 FATs, FATsz 2017,
#     CHS geometry 128 heads / 63 spt, HIDDEN SECTORS = 2048 (the partition
#     offset -- ours used to be 0), total sectors 262143 (official mkfs left
#     the last partition sector out), label BOOT, volume id 1FF4-582A.
#   p1 file set, exactly the official one, in the official directory order:
#     boot.bin  atf.img  dtb.img  kernel.img  uboot.bin
#     check_resize2fs  configs  first_time_boot  usb.ncm(empty)  ver
#
# WHAT CHANGED vs the first (non-booting) attempt, and why -- every change is
# grounded in a concrete diff against the official image / live card:
#   1. CONSOLE BACK TO UART0 (the big one). The official image runs EVERY
#      stage on UART0/ttyS0; our failed card used the experimental
#      boot-sd/dtb-sd UART1-redirect variants, whose patched SPL/ATF/U-Boot
#      had never run on hardware (a UART1 MMIO touch with the clock still
#      gated hangs the SPL before any output -- consistent with the observed
#      total silence). We now build the plain UART0 chain ourselves (below)
#      and deliberately IGNORE the flake-passed `boot`(=boot-sd) and
#      `dtb-slot-image`(=dtb-slot-image-sd) arguments. The UART0 ATF/OP-TEE/
#      U-Boot binaries are the exact ones proven to boot this unit from eMMC.
#   2. FAT GEOMETRY: official BPB has hidden-sectors=2048 + CHS 128/63; ours
#      had 0 + 8/32. A ROM FAT reader that trusts BPB_HiddSec for absolute
#      LBAs would read garbage from our card. Now byte-identical.
#   3. FILE SET: dropped ddrinit.img + optee.img (absent from the official
#      card, which boots -- the SD SPL has DDR init compiled in and OPTEE_BOOT
#      off, so they were dead weight and a divergence); added the empty
#      usb.ncm the official card carries (read by rootfs usb-gadget.sh).
#   4. DTB: root=/dev/mmcblk1p2 baked into chosen/bootargs but console kept
#      on ttyS0 (official behaviour). U-Boot's BOOTARGS_SD sets the same
#      values at runtime, so DTB and env agree whichever wins.
#   (Names still match the SPL's own table, boot/bl1/core/boot/boot.c
#    sd_img_name[]: [ATF]="0:atf.img" [UBOOT]="0:uboot.bin" [DTB]="0:dtb.img"
#    [KERNEL]="0:kernel.img"; FatFS there has LFN off + 512 B sectors, and
#    both mtools and the official image store the same uppercase 8.3 SFNs.)
#
# CONSOLE / OBSERVABILITY: like the official image, the whole chain logs to
# UART0 (0x4880000, ttyS0) which is on HIDDEN PADS -- the exposed UART1 header
# pin stays silent by design. Success is observed over the network (DHCP +
# web UI + ssh), exactly how the official card is used.
#
# Still a no-root Nix build: mkfs.vfat + mtools for the FAT, sfdisk for the
# MBR, prebuilt raw ext4 from pkgs/rootfs.nix as p2.
# ===========================================================================

let
  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";

  # UART0 boot chain (change #1). `args` carries the flake's callArgs (pkgs,
  # crossPkgs, the SDK inputs, ...), so we can instantiate the plain variants
  # right here; with sdConsoleUart1 = false this evaluates to the *same
  # derivation* as the flake's `boot` (the one whose ATF/OP-TEE/U-Boot boot
  # this unit from eMMC), so nothing extra is built.
  boot = import ./boot.nix (args // { sdConsoleUart1 = false; });

  # DTB for SD: SD root (mmcblk1p2) baked in, console left on ttyS0/UART0
  # (change #4). Packaged with the same slot-image recipe/params as the
  # flake's dtb-slot-image (1 KiB signed header + ax_gzip payload -- the exact
  # container the official dtb.img uses, verified: same magic 0x55543322,
  # same header size, same in-family img_size).
  dtb-sd = import ./dtb.nix (args // {
    rootDev = "/dev/mmcblk1p2";
    nameSuffix = "-sd-uart0";
  });
  dtb-slot-image = import ./slot-image.nix (args // {
    payload = "${dtb-sd}/dtb/${project}.dtb";
    pname = "nanokvm-pro-dtb-slot-image";
    version = "ax630c-dtb";
    artifact = "${project}_signed.dtb";
    partSize = 1024 * 1024;
    loadAddr = "0x40001000";
    title = "dtb partition image (SD root, UART0 console)";
    flashNotes = ''
      CONSUMED BY: pkgs/sd-image.nix as p1 FAT file `dtb.img` (U-Boot sd_boot
      fatloads it from mmc 1:1). chosen/bootargs bake root=/dev/mmcblk1p2 +
      console=ttyS0, agreeing with the BOOTARGS_SD env U-Boot sets anyway.'';
    nameSuffix = "-sd-uart0";
  });

  bootImages = "${boot}/images";
  # Vendor bootfs helper files (configs / ver / first_time_boot / check_resize2fs).
  bootfsDir = "${maix_ax620e_sdk}/build/projects/${project}/bootfs";

  bootPartMiB = 128;   # partition size: 262144 sectors (matches official)
  gapMiB = 1;          # first partition starts at 1 MiB (matches official)

  # Official p1 filesystem is one sector SHORTER than the partition (mkfs.fat
  # on the 262144-sector partition produced a 262143-sector FS). Replicated.
  fatSects = 262143;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-pro-sd-image";
  version = "ax630c-sdcard-v2-official-match";

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = with pkgs; [
    mtools        # mcopy / mdir  (no-root FAT32 population)
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

    # ---- 1. FAT32 boot partition, BPB byte-matched to the official image ----
    echo "=== [1] build FAT32 boot partition (official-matched BPB) ==="
    truncate -s $(( ${toString fatSects} * sect )) boot.fat
    #  -s 1        1 sector/cluster        -R 32   32 reserved sectors
    #  -f 2        2 FATs                  -g 128/63  CHS heads/sectors-per-track
    #  -h 2048     hidden sectors = partition start LBA (official value; a BPB
    #              consumer computing absolute LBAs needs this to be right)
    #  -i 1FF4582A volume id, matched to the official image for a byte-identical
    #              boot sector (it is an arbitrary label, not an identity)
    mkfs.vfat -F 32 -n BOOT -s 1 -R 32 -f 2 -g 128/63 -h 2048 -i 1FF4582A \
      boot.fat >/dev/null

    # Assert the BPB core (bytes 0x0B..0x27: sector size, sec/cluster,
    # reserved, FATs, media, CHS, hidden sectors, total sectors, FAT size)
    # equals the official image's, byte for byte.
    bpb=$(od -An -tx1 -j11 -N29 boot.fat | tr -d ' \n')
    expected="00020120000200000000f800003f00800000080000ffff0300e1070000"
    if [ "$bpb" != "$expected" ]; then
      echo "ERROR: FAT BPB deviates from the official image:" >&2
      echo "  built:    $bpb" >&2
      echo "  official: $expected" >&2
      exit 1
    fi
    echo "BPB matches the official image byte-for-byte."

    # ---- 2. populate p1: official file set, official directory order ----
    echo "=== [2] copy boot files (official set/order) ==="
    : > empty.usb.ncm
    # dest-name-on-FAT : source. Order = the official image's root directory.
    # boot chain names MUST match boot.c sd_img_name[] / sd_boot.c.
    fatFiles=(
      "boot.bin:${bootImages}/spl_${project}_sd_signed.bin"
      "atf.img:${bootImages}/atf_bl31_signed.bin"
      "dtb.img:${dtb-slot-image}/${project}_signed.dtb"
      "kernel.img:${kernel-slot-image}/kernel_b.bin"
      "uboot.bin:${bootImages}/u-boot_signed.bin"
      "check_resize2fs:${bootfsDir}/check_resize2fs"
      "configs:${bootfsDir}/configs"
      "first_time_boot:${bootfsDir}/first_time_boot"
      "usb.ncm:empty.usb.ncm"
      "ver:${bootfsDir}/ver"
    )
    for spec in "''${fatFiles[@]}"; do
      name="''${spec%%:*}"
      src="''${spec#*:}"
      if [ ! -f "$src" ]; then
        echo "ERROR: missing SD boot component for '$name': $src" >&2
        exit 1
      fi
      mcopy -i boot.fat "$src" ::/"$name"
    done

    # boot.bin sanity: the official SPL is zero-padded to exactly 256 KiB by
    # the sign step; ours must be the same object shape.
    splSz=$(stat -c %s "${bootImages}/spl_${project}_sd_signed.bin")
    if [ "$splSz" != "262144" ]; then
      echo "ERROR: boot.bin (SD SPL) is $splSz bytes, official is 262144" >&2
      exit 1
    fi

    echo "--- FAT32 contents ---"
    mdir -i boot.fat ::/

    # ---- 3. rootfs ext4 (p2): the raw image from pkgs/rootfs.nix ----
    echo "=== [3] stage rootfs ext4 (p2) ==="
    cp "${rootfs}/ubuntu_rootfs.ext4" rootfs.ext4
    chmod u+w rootfs.ext4
    rootBytes=$(stat -c %s rootfs.ext4)

    # ---- 4. assemble MBR disk: gap + FAT + ext4, then write the table ----
    echo "=== [4] assemble MBR disk image ==="
    p1_start=$(( ${toString gapMiB} * 1024 * 1024 / sect ))
    p1_sects=$(( ${toString bootPartMiB} * 1024 * 1024 / sect ))
    p2_start=$(( p1_start + p1_sects ))
    p2_sects=$(( rootBytes / sect ))
    total_sects=$(( p2_start + p2_sects ))

    truncate -s $(( total_sects * sect )) sdcard.img
    dd if=boot.fat    of=sdcard.img bs=$sect seek=$p1_start conv=notrunc status=none
    dd if=rootfs.ext4 of=sdcard.img bs=$sect seek=$p2_start conv=notrunc status=none

    # label-id matched to the official image (arbitrary MBR disk id; matching
    # removes one more delta from the known-good card). Partition entries are
    # identical to official except p2's size (our rootfs).
    sfdisk sdcard.img <<SFDISK
    label: dos
    label-id: 0x3e7afe58
    start=$p1_start, size=$p1_sects, type=c, bootable
    start=$p2_start, size=$p2_sects, type=83
    SFDISK

    echo "--- final partition table ---"
    sfdisk -l sdcard.img

    # ---- 5. sanity: FAT readable at its LBA, boot.bin present ----
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
    (v2: structure byte-matched to the official v1.0.15 SD image, which is
     known to boot this hardware. Boot chain console is UART0, like official.)

    file : ${project}-sdcard.img   ($imgSz bytes)
    boots: our from-source SPL/ATF/U-Boot + kernel + dtb + rootfs, entirely
           from the microSD. eMMC is never written -- pull the card / power on
           without the button to revert to stock.

    LAYOUT (MBR, disk id 0x3e7afe58 -- same as the official SD image):
      1 MiB gap
      p1  FAT32  ${toString bootPartMiB} MiB (official-matched BPB: hidden=2048, CHS 128/63):
                 boot.bin(=SD SPL, 256 KiB) atf.img dtb.img kernel.img uboot.bin
                 + configs ver first_time_boot check_resize2fs usb.ncm
      p2  ext4   rest: rootfs (Ubuntu + libkvm + our modules)

    WRITE IT (Linux) -- pick the RIGHT device or you can wipe your disk:
      1) Find the card:   lsblk    (look for the removable disk, e.g. sdX / mmcblkN)
      2) Unmount any auto-mounted partitions of that device.
      3) Write (DOUBLE-CHECK of=; destructive to the CARD only):
           sudo dd if=${project}-sdcard.img of=/dev/sdX bs=4M oflag=direct conv=fsync status=progress
         (macOS: of=/dev/rdiskN  bs=4m ; use 'diskutil list' + 'diskutil unmountDisk')
      4) sync, then remove the card.

    BOOT -- identical procedure to the official SD image:
      - Power OFF the NanoKVM-Pro, insert this card.
      - HOLD the \`User\` button while applying power, RELEASE it immediately
        after power is applied. (Holding ~10 s enters USB download mode
        instead.) A normal power-on always boots eMMC.

    WHAT SUCCESS LOOKS LIKE -- observe over the NETWORK, not serial:
      - Like the official image, the whole chain logs to UART0/ttyS0, which is
        on hidden pads; the exposed UART1 header pin stays SILENT even on a
        fully successful boot. Do not use serial silence as a failure signal.
      - Within ~30-60 s the device should DHCP; then: web UI at https://<ip>/
        and ssh root@<ip> (password: sipeed).
      - Confirm it is really the card: on the device,
          cat /proc/cmdline   -> should contain root=/dev/mmcblk1p2
          mount | grep ' / '  -> /dev/mmcblk1p2 on /

    REVERT (non-destructive -- eMMC is never written):
      - Power on again WITHOUT holding \`User\` (and/or remove the card)
        -> stock eMMC firmware, untouched.
    EOF
    echo "Installed:"; ls -l "$out"
    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro AX630C non-destructive microSD boot image (dd-able), structure byte-matched to the official v1.0.15 SD image: from-source SD SPL + UART0 boot chain + kernel + dtb + overlaid rootfs, MBR/FAT32+ext4";
    # Inherits the x86-64-only ax_gzip constraint via boot / slot-image.
    platforms = [ "x86_64-linux" ];
  };
}
