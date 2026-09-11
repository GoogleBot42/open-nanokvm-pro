{ pkgs, crossPkgs, maix_ax620e_sdk
, # The layout the SPL is compiled for. Its `atf` and `uboot` offsets become
  # the SPL's ATF_HEADER_FLASH_BASE / UBOOT_HEADER_FLASH_BASE constants.
  layout ? import ../nixos/emmc-partitions.nix { inherit (pkgs) lib; }
, # #90. `withEip = false` (the DEFAULT since 2026-09-09) signs the SPL with an
  # EMPTY firmware member: `fw_size` and `fw_check_sum` are 0 and no EIP-130
  # bytes are spliced at 0xCC00/0x2CC00 at all. The BootROM was not documented
  # to tolerate that, and the SDK says nothing either way -- so it was run on
  # hardware (#89 rung 4, 2026-09-09): two warm reboots and a cold power cycle,
  # all clean, register `0x30000014`, web 200. `withEip = true` rebuilds the
  # vendor-shaped container as `.#spl-minimal-eip`, kept as the fallback a
  # `dd` away should a unit ever refuse it.
  withEip ? false
, # #95. `gzipd = false` compiles the SPL with SUPPPORT_GZIPD undefined, so
  # every stage is read STRAIGHT from flash to its load address instead of
  # through the gzipd hardware decompressor -- and `ax_gzip`, the last prebuilt
  # x86-64 host tool in this build, is retired. THIS AND THE PACKING OF
  # `atf`/`uboot` ARE ONE CHANGE; see item 6 below.
  #
  # `true` IS STILL THE DEFAULT and this build is byte-for-byte the pre-#95
  # one, because the raw chain has not booted the board and
  # `.#nixos-firmware-image-mainline` is the AXDL recovery image. The raw
  # variant is `.#spl-minimal-raw`. The default flips, and the TRUE branches
  # here go, once hardware says the raw chain boots.
  gzipd ? true
, ... }:

# ===========================================================================
# THE SPL, REBUILT FOR THE MINIMAL LAYOUT (#89 rung 4).
#
# WHY A REBUILD IS UNAVOIDABLE. The SPL finds every later stage by a
# COMPILE-TIME byte offset: `-DATF_HEADER_FLASH_BASE=...`,
# `-DUBOOT_HEADER_FLASH_BASE=...`, passed by boot/bl1/spl/Makefile from a
# running sum over the vendor's partition list. Nothing on the eMMC tells it
# where anything is, and there is no partition table it could read. So the
# layout and the first-stage loader are one artefact: change the layout and
# the SPL must be rebuilt, or it reads the wrong bytes and hangs with no
# console (docs/mainline-port.md 11.2).
#
# WHAT THIS BUILD CHANGES, relative to pkgs/boot.nix's SPL.
#
#   1. `partition_ab.mak` is REPLACED by a file generated from
#      nixos/lib/emmc-layout.nix. Every `*_HEADER_FLASH_BASE` is written out
#      as a literal computed in Nix rather than by the vendor's
#      `calculate_flash_base` sed/awk pipeline, so the SPL's constants and the
#      `blkdevparts=` string both come from one list and cannot disagree.
#   2. `SUPPORT_OPTEE := FALSE`. With OP-TEE compiled in the SPL HANGS if the
#      BL32 image does not verify (spl_main.c `goto failed` -> `while(1)`),
#      which makes an optional stage mandatory. Nothing we run uses OP-TEE
#      (docs/mainline-port.md 11.3), so it goes, and with it the `optee` and
#      `optee_b` partitions and BL31's firewall configuration.
#   3. `SUPPORT_DDRINIT_PART := FALSE`. The vendor ships a signed header with
#      an EMPTY payload, so the DDR-vref cache the SPL is reading has always
#      been uninitialised OCM at 0x03200400 -- `flash_boot(DDRINIT, ...)`
#      writes the 1 KiB header at 0x03200000 and `img_size` = 0 bytes after
#      it. Dropping the read changes nothing about what `mc20e_ddr_init()`
#      sees; full DDR training runs either way, exactly as it does today.
#      The read is also non-fatal by construction (it prints and continues).
#   4. `*_BAK_FLASH_BASE` = the A bases. The layout has no twins, and with
#      A/B compiled in a bad header does NOT fall back (boot.c returns
#      immediately when `support_ab` is set); the twins were never a failover,
#      only a pair the slot register chose between. Pointing both at the same
#      partition is the smaller change than turning `AX_SUPPORT_AB_PART` off
#      -- it keeps the code path the board has always run -- and it makes the
#      slot register's SLOT bits select between two identical addresses, i.e.
#      harmless. `select_slot_ab()` still reads and rewrites
#      TOP_CHIPMODE_GLB_BACKUP0 (0x02390024) bits 2-5; the boot-milestone
#      bits 12-31 are untouched by it, so #75's evidence channel survives.
#   5. `DTB_*`/`KERNEL_*_HEADER_FLASH_BASE` = 0. Those macros are only read by
#      `fast_boot_process()`, under `AX_BOOT_OPTIMIZATION_SUPPORT`, which is
#      FALSE for this project -- dead code. The minimal layout has no `dtb`
#      or `kernel` partition because extlinux carries both per generation.
#
#   6. `SUPPPORT_GZIPD := FALSE` (#95, `.#spl-minimal-raw`; NOT the default
#      yet). This is the one flag that changes the ON-DISK FORMAT of the
#      stages behind the SPL, so read this before touching either side.
#
#      What the macro gates, all of it in [SDK]/boot/bl1/:
#        * `spl/Makefile:186-188` -- the only thing the flag does is define
#          `-DSUPPPORT_GZIPD`. The gzipd driver object
#          (`driver/gzipd/ax_gzipd_drv.o`) is in `OBJS` unconditionally and is
#          still linked; it simply loses every caller.
#        * `core/boot/boot.c:297-455` -- the whole of
#          `gzip_pipeline_flash_read()` exists only under the macro.
#        * `core/boot/boot.c:768-789` -- `read_image_data()` branches: with the
#          macro, every image but DDRINIT is staged at `IMAGE_COMPRESSED_PADDR`
#          (0x58000000) and DMA-decompressed to the load address; without it,
#          `flash_read()` puts `round_up(img_size, 4)` bytes straight there.
#        * `core/boot/boot.c:790-796, 847-849` -- the pointer fix-ups that only
#          the staged-then-decompressed path needs.
#        * `core/boot/boot.c:1007-1009` -- `gzipd_dev_init()` in `flash_boot()`.
#
#      What it does NOT change: the load address (`img_addr = boot_header +
#      sizeof(struct img_header)` either way, boot.c:731 -- 0x40040000 for BL31,
#      0x5C000400 for U-Boot), the header layout, the capability word, or any
#      header flag. THERE IS NO "COMPRESSED" BIT: `struct img_header`
#      (`core/include/boot.h:87-127`) has none, and the vendor's own ATF
#      Makefile signs with `-cap 0x54FAFE` in both branches
#      ([SDK]/boot/atf/Makefile:83-99). `img_size` and `img_check_sum` always
#      describe the STORED payload, which is why each side reads fine on its
#      own terms and neither can detect the other's format.
#
#      THAT IS THE HAZARD. A raw SPL reading a gzipped image passes the
#      checksum (the sum is over the stored bytes) and jumps into axgzip data;
#      a gzipped SPL reading a raw image fails `gzipd_dev_get_header_info()`
#      and then the checksum. With `support_ab` set neither retries
#      (boot.c:649-652, 806-808) and the caller spins in `while(1)`. Both
#      directions are a dark board with no console. So `spl`, `atf` and `uboot`
#      MUST be written in one step -- which is also why the RAW chain is not
#      the default: `.#nixos-firmware-image-mainline` is the AXDL recovery
#      image, and a recovery that fails the way the candidate did is not a
#      recovery. The raw trio is written from a running board
#      (docs/flashing-and-recovery.md); the defaults flip when it boots.
# ===========================================================================

let
  inherit (pkgs) lib;

  crossCC = crossPkgs.buildPackages.gcc13;
  crossBinutils = crossPkgs.buildPackages.binutils;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;

  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";

  pythonEnv = pkgs.python3.withPackages (ps: with ps; [ rsa setuptools ]);

  hex = layout.hex;
  need = layout.need;
  has = layout.has;

  # A base for a partition that exists, else 0x0 (the macro is dead code).
  base = n: if has n then hex (need n).offset else "0x0";
  size = n: if has n then (need n).sizeSpec else "0";

  # ---- the generated replacement for the vendor's partition_ab.mak --------
  # Everything layout-dependent is computed in Nix. The RAM addresses and the
  # memory-split constants below are the vendor's, carried verbatim: they are
  # not layout, they are where each stage is staged and entered, and BL31 and
  # U-Boot are linked for them.
  partitionMak = ''
    # GENERATED by pkgs/spl-minimal.nix from nixos/lib/emmc-layout.nix
    # (layout "${layout.layoutName}"). Do not edit; edit the layout.
    #
    # This REPLACES build/projects/${project}/partition_ab.mak. The vendor file
    # computed each *_HEADER_FLASH_BASE with `calculate_flash_base`, a sed/awk
    # running sum over the partition string; here the sums are done in Nix and
    # written out, so the SPL's constants and the kernel's blkdevparts= clause
    # are two renderings of one list.

    # ---- RAM addresses: where each stage is staged and entered -------------
    IMG_HEADER_SIZE                 := 1024
    DDRINIT_PARAM_HEADER_BASE       := 0x03200000
    ATF_IMG_HEADER_BASE             := 0x4003FC00
    ATF_IMG_ADDR                    := 0x40040000
    ATF_IMG_PKG_SIZE                := 0x40000
    UBOOT_IMG_HEADER_BASE           := 0x5C000000
    AXERA_DTB_IMG_ADDR              := 0x40001000
    DTB_IMG_HEADER_ADDR             := ($(AXERA_DTB_IMG_ADDR) - $(IMG_HEADER_SIZE))
    AXERA_KERNEL_IMG_ADDR           := 0x40200000
    KERNEL_IMG_HEADER_ADDR          := ($(AXERA_KERNEL_IMG_ADDR) - $(IMG_HEADER_SIZE))

    # ---- partition sizes, from the layout ---------------------------------
    SPL_PARTITION_SIZE        := ${size "spl"}
    ATF_PARTITION_SIZE        := ${size "atf"}
    UBOOT_PARTITION_SIZE      := ${size "uboot"}
    ENV_PARTITION_SIZE        := ${size "env"}
    BOOT_PARTITION_SIZE       := ${size "boot"}
    AUTO_FIT_PARTITION        := ROOTFS
    ENV_IMG_PKG_SIZE          := ${hex (need "env").size}

    # ---- memory split (vendor constants, not layout) ----------------------
    SYS_DRAM_BASE             := 0x40000000
    SYS_DRAM_SIZE             := 512 #MB
    OS_MEM_SIZE               := 256 #MB
    BOARD_0_5G_OS_MEM_SIZE    := 256
    BOARD_1G_OS_MEM_SIZE      := 512
    BOARD_2G_OS_MEM_SIZE      := 1024
    BOARD_4G_OS_MEM_SIZE      := 2048
    OS_MEM                    := mem=$(strip $(OS_MEM_SIZE))M
    BOARD_0_5G_OS_MEM := mem=$(strip $(BOARD_0_5G_OS_MEM_SIZE))M
    BOARD_1G_OS_MEM := mem=$(strip $(BOARD_1G_OS_MEM_SIZE))M
    BOARD_2G_OS_MEM := mem=$(strip $(BOARD_2G_OS_MEM_SIZE))M
    BOARD_4G_OS_MEM := mem=$(strip $(BOARD_4G_OS_MEM_SIZE))M
    CMM_START_ADDR       := $(call AddAddressMB, $(SYS_DRAM_BASE), $(OS_MEM_SIZE))
    CMM_SIZE             := $(shell echo $$(($(SYS_DRAM_SIZE) - $(OS_MEM_SIZE))))

    # ---- the partition string, and the command line built from it ---------
    FLASH_PARTITIONS  := ${layout.clause}
    ROOTFS_TYPE       := ext4
    ROOTFS_POSITION   := ${toString layout.root.number}
    ROOTFS_DEV        := ${layout.root.device}
    KERNEL_BOOTARGS   := "$(OS_MEM) console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x4880000 board_id=0x0,boot_reason=0x00,initcall_debug=0 loglevel=8 \
    usbcore.autosuspend=-1 root=$(ROOTFS_DEV) rootfstype=$(ROOTFS_TYPE) rw rootwait ${layout.blkdevparts}"

    # ---- where the SPL reads each stage, computed in Nix -------------------
    # No twins: every _B base is its _A base, so the slot register selects
    # between two identical addresses. DTB/KERNEL are dead macros (see the
    # header) and are pinned at 0.
    DDRINIT_HEADER_FLASH_BASE     := ${base "ddrinit"}
    ATF_A_HEADER_FLASH_BASE       := ${base "atf"}
    ATF_B_HEADER_FLASH_BASE       := ${if has "atf_b" then base "atf_b" else base "atf"}
    UBOOT_A_HEADER_FLASH_BASE     := ${base "uboot"}
    UBOOT_B_HEADER_FLASH_BASE     := ${if has "uboot_b" then base "uboot_b" else base "uboot"}
    ENV_DATA_FLASH_BASE           := ${base "env"}
    DTB_A_HEADER_FLASH_BASE       := 0x0
    DTB_B_HEADER_FLASH_BASE       := 0x0
    KERNEL_A_HEADER_FLASH_BASE    := 0x0
    KERNEL_B_HEADER_FLASH_BASE    := 0x0

    # DDR retrain scratch page (declaration only; no consumer in the SDK).
    DDR_RETRAIN_SIZE             := 0x1000
    DDR_RETRAIN_START            := $(SYS_DRAM_BASE)
  '';

  partitionMakFile = pkgs.writeText "partition_ab.mak" partitionMak;
  layoutTableFile = pkgs.writeText "emmc-layout.txt" layout.table;

  variant = lib.optionalString withEip "-eip" + lib.optionalString (!gzipd) "-raw";

  # ---- #95: which load path is actually IN the binary ----------------------
  # Asked of the ELF, not of project.mak. Spliced onto the END of the previous
  # line of installPhase so that the `gzipd = true` build's script is BYTE-FOR-
  # BYTE the pre-#95 one and keeps its store path; when the default flips, this
  # becomes unconditional.
  #
  # THE ORACLE IS THE CALL SITES, NOT A SYMBOL. `gzip_pipeline_flash_read()` is
  # a file-static with one caller, and at -Os gcc inlines it -- it has no
  # symbol of its own in EITHER build, which is exactly the sort of oracle that
  # looks like it passed when it never could have failed. What does survive is
  # the `bl` to each gzipd driver entry point: `gzipd_dev_init`, `_cfg`,
  # `_run`, `_run_last_tile`, `_wait_complete_finish`, `_get_header_info`,
  # `_get_fifo_level`. Every one of those calls is inside `#ifdef
  # SUPPPORT_GZIPD` (boot.c:297-455, 768-789, 1007-1009), and
  # `driver/gzipd/ax_gzipd_drv.o` is in the SPL's `OBJS` unconditionally -- so
  # the driver's SYMBOLS are in both binaries and prove nothing, while the
  # branches into it are 7 in the compressed build and 0 in the raw one --
  # measured both ways on this tree. Only the raw build asserts it, because the
  # default build's script has to stay byte-identical to the pre-#95 one; when
  # the default flips, this becomes unconditional and should assert both sides.
  gzipdOracle = lib.optionalString (!gzipd) ''

    # The linked ELF and its disassembly, banked next to the image: the only
    # way to ask the ARTEFACT, rather than the makefile, which load path it
    # carries.
    cp "$HOME_PATH/boot/bl1/spl/spl_${project}.axf" "$out/debug/spl_${project}${variant}.axf"
    cp "$HOME_PATH/boot/bl1/spl/spl.dis" "$out/debug/spl_${project}${variant}.dis"
    dis="$out/debug/spl_${project}${variant}.dis"

    calls=$(grep -cE 'bl[[:space:]]+[0-9a-f]+ <gzipd_dev_' "$dis" || true)
    echo "#95 SPL load path: branches into the gzipd driver = $calls"
    if [ "$calls" -ne 0 ]; then
      echo "ERROR (#95): the SPL still calls the gzipd driver ($calls call sites)" >&2
      grep -E 'bl[[:space:]]+[0-9a-f]+ <gzipd_dev_' "$dis" >&2 || true
      exit 1
    fi
    echo "#95: the decompressor is gone -- stages are read straight to their load address"'';
in
pkgs.stdenv.mkDerivation {
  pname = "nanokvm-pro-spl-minimal${variant}";
  version = "ax630c-spl-${layout.layoutName}";

  src = maix_ax620e_sdk;

  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;

  nativeBuildInputs = [ crossCC crossBinutils ] ++ (with pkgs; [
    gnumake bc which gawk perl bash openssl util-linux pythonEnv
  ]);

  dontUnpack = true;

  passthru = { inherit layout partitionMak gzipd withEip variant; };

  configurePhase = ''
    runHook preConfigure

    mkdir -p "$TMPDIR/sdk/boot"
    cp -a "$src/boot/bl1" "$TMPDIR/sdk/boot/bl1"
    cp -a "$src/build" "$TMPDIR/sdk/build"
    cp -a "$src/tools" "$TMPDIR/sdk/tools"
    chmod -R u+w "$TMPDIR/sdk"

    export HOME_PATH="$TMPDIR/sdk"
    prj="$HOME_PATH/build/projects/${project}"

    # gcc13 array-bounds false positives on the fixed-address misc_info struct.
    sed -i 's/-Werror/-Wno-error/g' "$HOME_PATH/boot/bl1/spl/Makefile"

    # ---- the generated layout ------------------------------------------
    cp ${partitionMakFile} "$prj/partition_ab.mak"
    chmod u+w "$prj/partition_ab.mak"
    echo "=== generated partition_ab.mak ==="
    cat "$prj/partition_ab.mak"

    # ---- the three build flags this SPL turns off ------------------------
    for kv in "SUPPORT_OPTEE:FALSE" "SUPPORT_DDRINIT_PART:FALSE"${lib.optionalString (!gzipd) " \"SUPPPORT_GZIPD:FALSE\""}; do
      k=''${kv%%:*}; v=''${kv##*:}
      grep -q "^$k  *:= TRUE" "$prj/project.mak" \
        || { echo "ERROR: $k is not ':= TRUE' in project.mak (SDK moved?)" >&2; exit 1; }
      sed -i "s/^\($k  *\):= TRUE/\1:= $v/" "$prj/project.mak"
      grep -q "^$k  *:= $v" "$prj/project.mak" \
        || { echo "ERROR: failed to set $k := $v" >&2; exit 1; }
      echo "project.mak: $k := $v"
    done
    # A/B stays ON, with both slots pointing at the same partitions.
    grep -q '^AX_SUPPORT_AB_PART  *:= TRUE' "$prj/project.mak" \
      || { echo "ERROR: AX_SUPPORT_AB_PART is not TRUE (the generated makefile would not be included)" >&2; exit 1; }
    ${if gzipd then ''
    grep -q '^SUPPPORT_GZIPD  *:= TRUE' "$prj/project.mak" \
      || { echo "ERROR: SUPPPORT_GZIPD is not TRUE (the stages are packed axgzip'd)" >&2; exit 1; }'' else ''
    grep -q '^SUPPPORT_GZIPD  *:= FALSE' "$prj/project.mak" \
      || { echo "ERROR (#95): SUPPPORT_GZIPD is not FALSE (the stages would have to be axgzip'd)" >&2; exit 1; }''}

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cd "$HOME_PATH/boot/bl1/spl"
    make p=${project} PROJECT=${project} CROSS=${crossPrefix} \
      CONFIG_PROJECT=AX620E_CFG all
    make p=${project} PROJECT=${project} CROSS=${crossPrefix} \
      CONFIG_PROJECT=AX620E_CFG install
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    imgs="$HOME_PATH/build/out/${project}/images"
    mkdir -p "$out/images"${lib.optionalString (!gzipd) " \"$out/debug\""}

    raw="$imgs/spl_${project}.bin"${gzipdOracle}
    rawSz=$(stat -c %s "$raw")
    echo "SPL raw size: $rawSz B (BootROM slot is 51200 B)"
    if [ "$rawSz" -gt 51200 ]; then
      echo "ERROR: SPL raw is $rawSz B, over the sign tool's 50K slot -- it would" >&2
      echo "       silently emit nothing (spl_AX620E_sign.py do_spl returns False," >&2
      echo "       the script still exits 0)." >&2
      exit 1
    fi

    ${lib.optionalString (!withEip) ''
    # ---- #90: sign with an EMPTY firmware member --------------------------
    # `-fw` is mandatory and the file must exist, so the omission is expressed
    # as a zero-byte file: fw_size and fw_check_sum become 0 in the header and
    # no firmware bytes are spliced at 0xCC00 / 0x2CC00. Nothing documented
    # said the BootROM would accept that; it does -- hardware-proven
    # 2026-09-09, two warm reboots and a cold power cycle.
    : > "$TMPDIR/empty_fw.bin"
    python3 "$HOME_PATH/build/tools/imgsign/spl_AX620E_sign.py" \
      -i "$raw" \
      -o "$imgs/spl_${project}_signed.bin" \
      -pub "$HOME_PATH/tools/imgsign/public.pem" \
      -prv "$HOME_PATH/tools/imgsign/private.pem" \
      -fw "$TMPDIR/empty_fw.bin" \
      -cap 0x54FAFE
    ''}

    cp "$imgs/spl_${project}_signed.bin" \
       "$out/images/spl_${project}${variant}_signed.bin"
    cp "$raw" "$out/images/spl_${project}${variant}.bin"

    signed="$out/images/spl_${project}${variant}_signed.bin"

    magic=$(od -An -tx1 -j4 -N4 "$signed" | tr -d ' ')
    [ "$magic" = "22335455" ] \
      || { echo "ERROR: bad header magic ($magic != 22335455)" >&2; exit 1; }

    sz=$(stat -c %s "$signed")
    echo "signed SPL: $sz B"
    # The container is header+SPL+fw twice over, PKG_SIZE 0x20000 each, and it
    # must fit the `spl` partition.
    if [ "$sz" -gt ${toString (layout.need "spl").size} ]; then
      echo "ERROR: signed SPL is $sz B, over the ${(layout.need "spl").sizeSpec} spl partition" >&2
      exit 1
    fi

    # ---- #90: where the closed EIP-130 firmware is, or is not -------------
    python3 - "$signed" ${if withEip then "2" else "0"} <<'PYEOF'
    import sys
    sig = bytes([0x00, 0x00, 0x00, 0xcf, 0x46, 0x57, 0x77, 0x02])
    want = int(sys.argv[2])
    data = open(sys.argv[1], "rb").read()
    at, i = [], data.find(sig)
    while i >= 0:
        at.append(hex(i)); i = data.find(sig, i + 1)
    if len(at) != want:
        sys.exit("ERROR (#90): %d copies of the EIP-130 firmware at %s, expected %d"
                 % (len(at), at, want))
    if want and at != ['0xcc00', '0x2cc00']:
        sys.exit("ERROR (#90): EIP-130 firmware at %s, expected 0xcc00/0x2cc00" % at)
    print("EIP-130 (#90): %d copies%s" % (len(at), (" at " + ", ".join(at)) if at else ""))
    PYEOF

    # The offsets this SPL was compiled with, banked next to the image so a
    # device write can be checked against the source of truth.
    cp ${layoutTableFile} "$out/images/layout.txt"
    cp "$HOME_PATH/build/projects/${project}/partition_ab.mak" "$out/images/partition.mak"

    echo "=== SPL (${layout.layoutName} layout, ${if withEip then "vendor container WITH the closed EIP-130 firmware" else "blob-free"}${lib.optionalString (!gzipd) ", stages RAW (#95)"}) ==="
    ls -l "$out/images"

    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description =
      "AX630C first-stage loader (bl1/spl) compiled for the ${layout.layoutName} eMMC layout"
      + (if withEip then ", signed with the vendor container's closed EIP-130 firmware (the #90 fallback)" else ", signed without the closed EIP-130 firmware (#90)")
      + (if gzipd then ", reading axgzip'd stages" else ", reading RAW stages (#95)");
    # No prebuilt host tool anywhere in this build: the SPL is cross-compiled
    # and the sign step is the SDK's own Python (`spl_AX620E_sign.py` + `rsa`)
    # plus openssl. `ax_gzip` was never part of the SPL's own build -- it
    # packed the stages BEHIND it, which is what #95 retires.
    platforms = pkgs.lib.platforms.linux;
  };
}
