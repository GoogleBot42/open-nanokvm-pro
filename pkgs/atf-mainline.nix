{ pkgs, crossPkgs, maix_ax620e_sdk, boot
  # Build the milestone-instrumented variant (#89 rung 1). See "Milestone
  # instrumentation" below: identical BL31 plus seven register writes, used
  # only to find out how far a BL31 that never reaches BL33 actually got.
, debugMilestones ? false
, ... }:

# ===========================================================================
# Mainline Trusted Firmware-A BL31 for the AX630C (#89 rung 0).
#
# Upstream TF-A v2.15.0, plus a new `plat/axera/ax630c` platform carried as a
# patch series in ./atf-mainline/patches (upstream-shaped: one commit adds the
# platform, one adds its documentation). Nothing else in the tree is touched --
# see docs/mainline-port.md 11.9 for the constants table and where each number
# came from.
#
# BL31 only. No SPD, no BL32/OP-TEE, no secure services beyond PSCI CPU_ON /
# CPU_OFF / SYSTEM_RESET. The vendor first-stage loader hands BL31 a stock
# bl_params_t v2 chain in x0 with the standard cookie in x3, so this is an
# ordinary loaded (non-RESET_TO_BL31) platform -- the SPL needs no change at
# all to boot it (docs/mainline-port.md 11.2).
#
# Packaging matches the vendor `atf_bl31_signed.bin` byte protocol exactly,
# because the SPL is what reads it:
#   bl31.bin -> sec_boot_AX620E_sign.py -cap 0x54FAFE -key_bit 2048
#     with the SDK's committed dev keys
# which is [SDK]/boot/atf/Makefile:92-99, the `SUPPPORT_GZIPD != TRUE` arm:
# BL31 stored RAW behind the signed header. The container carries no
# "compressed" flag, so which of the two the stored bytes are is decided by
# the SPL's compile-time `SUPPPORT_GZIPD` and by nothing else -- this file and
# `.#spl-minimal` are ONE ARTEFACT and must always change together. (#95;
# the raw chain booted the board 2026-09-12.)
#
# The result is a drop-in replacement for the `atf` partition: BL31 is ~24 KB,
# the window at 0x40040000 is 256 KiB, and the partition is 1 MiB.
#
# No prebuilt host binary is involved: cross-compile plus the SDK's Python
# signing script. `ax_gzip`, which used to sit between the two, is gone (#95).
# ===========================================================================

let
  inherit (pkgs) lib;

  crossPrefix = crossPkgs.stdenv.cc.targetPrefix; # aarch64-unknown-linux-gnu-

  # The `atf` partition this image is written into -- 1 MiB in the minimal
  # layout, and NOT the same thing as the 256 KiB DRAM window below.
  atfPart = (import ../nixos/emmc-partitions.nix { inherit lib; }).byName.atf;

  # The payload behind the header is the raw BL31, byte for byte, and every
  # header field recomputes -- asserted here as well as in the flake check, so
  # a bad packing cannot reach the .axp even if nobody runs the check. It also
  # checks the signed container against the `atf` PARTITION (1 MiB), which is
  # not the same number as the 256 KiB DRAM window checked above.
  rawAssertion = ''

    python3 ${./ax-sign-verify.py} \
      --image "$out/images/atf_bl31_mainline_signed.bin" \
      --stored "$work/bl31.bin" \
      --raw-payload "$work/bl31.bin" \
      --max-size ${toString atfPart.size}'';

  tfaVersion = "2.15.0";

  tfaSrc = pkgs.fetchFromGitHub {
    owner = "ARM-software";
    repo = "arm-trusted-firmware";
    rev = "v${tfaVersion}";
    hash = "sha256-pFisArv6snepJ1qWmjckbr0O2Jg4WMhUkN3exgdyb+c=";
  };

  # sec_boot_AX620E_sign.py needs `rsa`; nothing else in the sign path does.
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.rsa ]);

  # BL31 window / `atf` partition, from
  # [SDK]/build/projects/AX630C_emmc_arm64_k419_sipeed_nanokvm/partition_ab.mak:5-6,23.
  bl31Base = 1074003968; # 0x40040000
  atfPartitionSize = 262144; # 256 KiB

  # -------------------------------------------------------------------------
  # Milestone instrumentation (#89 rung 1, debugMilestones = true).
  #
  # BL31 owns no console this board can read, so a BL31 that never hands off
  # to BL33 says nothing at all. These seven writes give it the same channel
  # the mainline kernel bring-up uses: the spare high bits of the A/B slot
  # register 0x02390024 (SET alias at +4), which survive a warm reboot, a
  # watchdog reset and the SPL's own fallback to slot A -- so slot A can read
  # afterwards how far slot B got.
  #
  # Bits, in execution order:
  #   12  bl31_early_platform_setup2 entered (the SPL loaded and ran us)
  #   13  bl_params chain walked, BL33 entry point captured
  #   14  bl31_plat_arch_setup entered (about to build page tables)
  #   15  enable_mmu_el3() returned -- BL31 is running with its MMU on
  #   16  generic_delay_timer_init() done
  #   17  GIC initialised (bl31_platform_setup complete)
  #   18  bl31_plat_runtime_setup -- the last platform code before BL33
  #
  # The window holding the register is not in the production mmap, so the
  # debug build maps it; everything else is byte-identical to the shipping
  # platform.
  # -------------------------------------------------------------------------
  milestonePostPatch = ''
    f=plat/axera/ax630c/ax630c_bl31_setup.c

    substituteInPlace $f --replace-fail \
      '#include <plat/common/platform.h>' \
      '#include <lib/mmio.h>
    #include <plat/common/platform.h>'

    substituteInPlace $f --replace-fail \
      'static console_t ax630c_console;' \
      '/* #89 rung 1 boot-evidence channel -- see pkgs/atf-mainline.nix. */
    #define AX630C_DBG_SLOT_SET	UL(0x02390028)

    static void ax630c_milestone(unsigned int bit)
    {
    	mmio_write_32(AX630C_DBG_SLOT_SET, (uint32_t)1U << bit);
    }

    static console_t ax630c_console;'

    substituteInPlace $f --replace-fail \
      '	bl_params_node_t *node;' \
      '	bl_params_node_t *node;

    	ax630c_milestone(12U);'

    substituteInPlace $f --replace-fail \
      '	bl33_ep_info.args.arg3 = 0UL;' \
      '	bl33_ep_info.args.arg3 = 0UL;

    	ax630c_milestone(13U);'

    substituteInPlace $f --replace-fail \
      '	generic_delay_timer_init();' \
      '	generic_delay_timer_init();
    	ax630c_milestone(16U);'

    substituteInPlace $f --replace-fail \
      '	ax630c_gic_init();' \
      '	ax630c_gic_init();
    	ax630c_milestone(17U);'

    substituteInPlace $f --replace-fail \
      '	console_flush();' \
      '	ax630c_milestone(18U);
    	console_flush();'

    substituteInPlace $f --replace-fail \
      '	MAP_REGION_FLAT(AX630C_SYS_GLB_BASE, AX630C_SYS_GLB_SIZE,
    			MT_DEVICE | MT_RW | MT_NS),' \
      '	MAP_REGION_FLAT(AX630C_SYS_GLB_BASE, AX630C_SYS_GLB_SIZE,
    			MT_DEVICE | MT_RW | MT_NS),
    	MAP_REGION_FLAT(UL(0x02390000), AX630C_SIZE_K(64),
    			MT_DEVICE | MT_RW | MT_NS),'

    substituteInPlace $f --replace-fail \
      '	setup_page_tables(bl_regions, ax630c_mmap);
    	enable_mmu_el3(0);' \
      '	ax630c_milestone(14U);
    	setup_page_tables(bl_regions, ax630c_mmap);
    	enable_mmu_el3(0);
    	ax630c_milestone(15U);'
  '';

  atf-mainline = pkgs.stdenv.mkDerivation {
    pname = "atf-mainline" + pkgs.lib.optionalString debugMilestones "-debug";
    version = "tfa-${tfaVersion}-ax630c";

    src = tfaSrc;

    patches = [
      ./atf-mainline/patches/0001-plat-axera-add-a-BL31-only-AX630C-platform.patch
      ./atf-mainline/patches/0002-docs-plat-document-the-Axera-AX630C-platform.patch
    ];

    postPatch = pkgs.lib.optionalString debugMilestones milestonePostPatch;

    # TF-A manages its own freestanding flags; the cc-wrapper must not inject
    # PIE / fortify / stack-protector into an EL3 image.
    hardeningDisable = [ "all" ];
    enableParallelBuilding = true;

    nativeBuildInputs = [
      crossPkgs.buildPackages.gcc13
      crossPkgs.buildPackages.binutils
      pkgs.gnumake
      pythonEnv
    ];

    dontConfigure = true;

    makeFlags = [
      "PLAT=ax630c"
      "ARCH=aarch64"
      "CROSS_COMPILE=${crossPrefix}"
      # TF-A 2.15's toolchain detection reads CC/CPP/AS/LD/OC/OD/AR straight
      # out of the environment, and stdenv puts the NATIVE tools there --
      # `CC=gcc` alone gets you "gcc: error: unrecognized command-line option
      # '-mstrict-align'". A make-command-line assignment beats the
      # environment, so name every one of them.
      "CC=${crossPrefix}gcc"
      "CPP=${crossPrefix}gcc"
      "AS=${crossPrefix}gcc"
      "LD=${crossPrefix}gcc"
      "OC=${crossPrefix}objcopy"
      "OD=${crossPrefix}objdump"
      "AR=${crossPrefix}ar"
      "DEBUG=0"
      # 20 = LOG_LEVEL_NOTICE: the banner and errors, nothing per-boot chatty.
      "LOG_LEVEL=20"
      "bl31"
    ];

    installPhase = ''
      runHook preInstall

      rel="build/ax630c/release"
      test -f "$rel/bl31.bin" || { echo "ERROR: no bl31.bin at $rel" >&2; exit 1; }

      mkdir -p "$out/images" "$out/debug"
      cp "$rel/bl31.bin"      "$out/images/atf_bl31_mainline.bin"
      cp "$rel/bl31/bl31.elf" "$out/debug/atf_bl31_mainline.elf"
      cp "$rel/bl31/bl31.map" "$out/debug/atf_bl31_mainline.map"

      # --- sign the RAW bl31.bin: the vendor ATF Makefile's FALSE arm ------
      work="$TMPDIR/sign"
      mkdir -p "$work"
      cp "$rel/bl31.bin" "$work/bl31.bin"

      python3 "${maix_ax620e_sdk}/build/tools/imgsign/sec_boot_AX620E_sign.py" \
        -i "$work/bl31.bin" \
        -pub "${maix_ax620e_sdk}/tools/imgsign/public.pem" \
        -prv "${maix_ax620e_sdk}/tools/imgsign/private.pem" \
        -o "$out/images/atf_bl31_mainline_signed.bin" \
        -cap 0x54FAFE -key_bit 2048

      test -f "$out/images/atf_bl31_mainline_signed.bin" || \
        { echo "ERROR: sign step produced no output" >&2; exit 1; }

      # Fail in-build, never on the device: the signed image must fit the
      # 256 KiB `atf` partition, and the raw image must fit the 256 KiB DRAM
      # window the SPL enters at 0x40040000.
      raw=$(stat -c %s "$out/images/atf_bl31_mainline.bin")
      signed=$(stat -c %s "$out/images/atf_bl31_mainline_signed.bin")
      echo "BL31 raw: $raw B   signed: $signed B   (limit ${toString atfPartitionSize} B)"
      if [ "$raw" -gt ${toString atfPartitionSize} ]; then
        echo "ERROR: bl31.bin ($raw B) does not fit the 256 KiB BL31 window" >&2
        exit 1
      fi
      if [ "$signed" -gt ${toString atfPartitionSize} ]; then
        echo "ERROR: signed image ($signed B) exceeds the 256 KiB atf partition" >&2
        exit 1
      fi${rawAssertion}

      runHook postInstall
    '';

    dontFixup = true;

    passthru = {
      inherit tfaVersion bl31Base atfPartitionSize atfPart;
      src = tfaSrc;
      verify = verify;
    };

    meta = {
      description =
        "Mainline TF-A ${tfaVersion} BL31 for the Axera AX630C, signed and stored raw (#95) for the atf partition";
      license = pkgs.lib.licenses.bsd3;
      # #95: no prebuilt x86-64 host tool is reached for anywhere in this
      # build -- it is cross-compile + Python all the way down.
      platforms = lib.platforms.linux;
    };
  };

  # -------------------------------------------------------------------------
  # checks.<system>.atf-mainline
  #
  # Everything asserted here is a property of the artefact, read back out of
  # the built files: the ELF's entry and link address, the signed image's
  # size, and every field of the Axera 1 KiB header -- including the two
  # checksums, recomputed, and the magic compared against the vendor
  # atf_bl31_signed.bin this repo builds from the SDK.
  # -------------------------------------------------------------------------
  verify = pkgs.runCommand "atf-mainline-verify"
    {
      nativeBuildInputs = [ pkgs.python3 crossPkgs.buildPackages.binutils ];
      meta.platforms = [ "x86_64-linux" ];
    }
    ''
      set -eu
      elf="${atf-mainline}/debug/atf_bl31_mainline.elf"
      img="${atf-mainline}/images/atf_bl31_mainline_signed.bin"
      vendor="${boot}/images/atf_bl31_signed.bin"

      # #95: the stored payload is the BL31 binary itself. Read back from the
      # two built files, so a packing regression fails the check even if the
      # in-build assertion is ever weakened.
      raw="${atf-mainline}/images/atf_bl31_mainline.bin"
      python3 ${./ax-sign-verify.py} --image "$img" --stored "$raw" \
        --raw-payload "$raw" --max-size ${toString atfPart.size}

      echo "== ELF entry / link address =="
      ${crossPrefix}readelf -h "$elf" > headers.txt
      ${crossPrefix}readelf -lW "$elf" > phdrs.txt
      cat headers.txt phdrs.txt

      python3 ${./atf-mainline/verify.py} \
        --elf-headers headers.txt \
        --elf-phdrs phdrs.txt \
        --image "$img" \
        --vendor-image "$vendor" \
        --entry ${toString bl31Base} \
        --max-size ${toString atfPartitionSize} \
        | tee "$out"
    '';
in
atf-mainline
