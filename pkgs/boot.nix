{ pkgs, crossPkgs, maix_ax620e_sdk
, # ---- console UART redirect (SD debug variant) -----------------------------
  # When true, redirect the console of EVERY from-source boot stage (SPL/bl1,
  # ATF bl31, OP-TEE bl32, U-Boot bl33) from UART0 (0x4880000 = ttyS0, the
  # hidden debug pads) to UART1 (0x4881000 = ttyS1, the accessible header pin),
  # keeping 115200 8N1. Used ONLY for the microSD boot image so the whole SD
  # boot chain is watchable on the exposed UART1; the default (false) keeps the
  # eMMC boot chain on UART0 exactly as before. See the per-stage sed patches in
  # configurePhase and pkgs/dtb.nix (kernel side) / flake.nix (wiring).
  sdConsoleUart1 ? false
, ... }:

# ===========================================================================
# AX630C / NanoKVM-Pro boot chain, ALL FOUR STAGES, from source.
# Source: maix_ax620e_sdk (boot/{bl1,atf,optee,uboot} + build/ make system +
# tools/). Driven by the vendor `build/` make system, one writable tree, the
# same sibling-layout / make-var pattern the kernel derivation established.
#
# Produces the vendor's per-partition SIGNED images for the 17-partition eMMC
# A/B layout of project AX630C_emmc_arm64_k419_sipeed_nanokvm:
#   p1  spl        -> spl_<project>_signed.bin        (+ _enc_signed variant)
#   p2  ddrinit    -> ddrinit_<project>_signed.bin    (empty payload by design*)
#   p3  atf        -> atf_bl31_signed.bin
#   p4  atf_b      -> atf_b_bl31_signed.bin
#   p5  uboot      -> u-boot_signed.bin
#   p6  uboot_b    -> u-boot_b_signed.bin
#   p8  optee      -> optee_signed.bin  (image layer copies to optee + optee_b)
#   p9  optee_b    -> optee_signed.bin
# plus the AXDL download agents (not stored partitions, used by the host
# flasher): fdl_<project>_signed.bin (FDL1) and fdl2_signed.bin (FDL2 = u-boot).
#
# *ddrinit: for AX630C the DDR init/training C code (driver/ddr/*.o) is linked
#  INTO the SPL; the vendor build `touch`es an empty ddrinit.bin and signs it,
#  so the DDRINIT partition holds only a 1KB signed header. Reproduced exactly.
#
# ===========================================================================
# SECURE BOOT / SIGNING  (the load-bearing finding -- see notes at bottom)
# ===========================================================================
# Every stage is ALWAYS wrapped by the vendor signing tool
# (build/tools/imgsign/sec_boot_AX620E_sign.py / spl_AX620E_sign.py). The tool
# prepends a 1KB header carrying magic 0x55543322, checksums, the RSA-2048
# PUBLIC key (n,e) and an RSA-2048 signature (SHA-256) over the payload. The
# signing keys are the repo's COMMITTED dev/test keys (tools/imgsign/{public,
# private}.pem -- an obvious placeholder key whose modulus is a repeating
# pattern; aes-256.key is ASCII zeros). Signing is UNCONDITIONAL in the build;
# it is NOT gated by any "secure boot" flag. Whether the signature is actually
# ENFORCED is decided AT RUNTIME by the SPL loader (boot/bl1/core/boot/boot.c
# read_image_data): the RSA pub-key-hash check + signature verify run ONLY when
# is_secure_enable() reads the efuse SECURE_BOOT_EN bit (1<<26) as set. The SDK
# only READS that efuse (driver/secure/efuse_drv.c has no write path) -- there
# is NO efuse-burning step anywhere in the build/flash flow. => On a board
# whose SECURE_BOOT_EN efuse is unburned (the expected retail state, since the
# only key available is the public repo test key), these repo-key-signed images
# boot as-is. See VERDICT note at the bottom of this file.
#
# ===========================================================================
# TOOLCHAIN (per stage) -- a SINGLE aarch64 linux-gnu cross gcc13 builds all 4.
# nixpkgs dropped gcc9..12; gcc13 (matching kernel.nix) works for every stage.
# No bare-metal aarch64-none-elf toolchain is needed: the bare-metal stages
# (SPL, bl31, OP-TEE core) use their own linker scripts + -ffreestanding.
#   - ATF/bl31 : cross gcc13. Needs binutils-2.46 fix `--no-warn-rwx-segments`
#                (old TF-A 2.7 forces -Wl,--fatal-warnings; new binutils emits
#                a fatal RWX-LOAD-segment warning). Patched below.
#   - U-Boot   : cross gcc13 + NATIVE HOSTCC (gcc). Needs the `/bin/pwd`->`pwd`
#                fix (u-boot Makefile hardcodes /bin/pwd, absent on NixOS).
#   - OP-TEE   : cross gcc13 (CROSS_COMPILE64). Needs python3 cryptography +
#                pyelftools, bash, and shebang patching (scripts use /bin/bash).
#   - SPL/bl1  : cross gcc13 bare-metal (incl. open DDR init/training). Needs
#                `-Werror`->`-Wno-error` (gcc13 array-bounds false positives on
#                the fixed-address misc_info struct that gcc9 accepted).
#
# ax_gzip: install steps compress each stage with the PREBUILT x86-64 host tool
# tools/ax_gzip_tool/ax_gzip (Axera's LZ77 "axgzip", decompressed by the SPL's
# gzipd HW). It is an x86-64 static ELF, so THIS derivation only builds on an
# x86_64-linux builder (the flake's intended dev host). Flagged in meta.
# ===========================================================================

let
  crossCC = crossPkgs.buildPackages.gcc13;
  crossBinutils = crossPkgs.buildPackages.binutils;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix; # aarch64-unknown-linux-gnu-

  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";

  pythonEnv = pkgs.python3.withPackages (ps: with ps; [
    rsa            # imgsign RSA sign/verify
    pyelftools     # OP-TEE elf post-processing
    cryptography   # OP-TEE pem_to_pub_c.py (ta_pub_key.c gen)
    setuptools
  ]);
in
pkgs.stdenv.mkDerivation {
  pname = "nanokvm-pro-boot${pkgs.lib.optionalString sdConsoleUart1 "-sd-uart1"}";
  version = "ax630c-bootchain";

  src = maix_ax620e_sdk;

  # The vendor Makefiles manage their own flags (freestanding SPL/ATF/OP-TEE,
  # u-boot Kbuild). Do not let the cc-wrapper inject PIE/fortify/stackprotector.
  hardeningDisable = [ "all" ];
  enableParallelBuilding = true;

  nativeBuildInputs = [
    crossCC
    crossBinutils
  ] ++ (with pkgs; [
    gnumake
    bison
    flex
    bc
    ncurses
    openssl        # imgsign AES / u-boot host tools
    ubootTools     # mkimage
    dtc            # u-boot dtbs
    perl
    gawk
    which
    util-linux     # hexdump (SPL enc-key derivation step)
    bash
    pythonEnv
  ]);

  # We do our own writable copy of just the three dirs the boot build touches.
  dontUnpack = true;

  configurePhase = ''
    runHook preConfigure

    # Writable working tree: the boot Makefiles compute HOME_PATH from their own
    # location (boot/<x>/../..), write generated headers/defconfigs in-tree, and
    # all stages write into the shared build/out/<project>/images dir.
    mkdir -p "$TMPDIR/sdk"
    cp -a "$src/boot"  "$TMPDIR/sdk/boot"
    cp -a "$src/build" "$TMPDIR/sdk/build"
    cp -a "$src/tools" "$TMPDIR/sdk/tools"
    chmod -R u+w "$TMPDIR/sdk"

    export HOME_PATH="$TMPDIR/sdk"

    # --- toolchain-newness patches (see header) ---
    # ATF 2.7: relax the forced-fatal RWX-LOAD-segment warning (binutils 2.46).
    sed -i '/TF_LDFLAGS/ s/--fatal-warnings/--fatal-warnings --no-warn-rwx-segments/' \
      "$HOME_PATH/boot/atf/arm-trusted-firmware-2.7/Makefile"

    # U-Boot 2020.04: /bin/pwd does not exist on NixOS.
    sed -i 's|&& /bin/pwd)|\&\& pwd)|' \
      "$HOME_PATH/boot/uboot/u-boot-2020.04/Makefile"

    # SPL/bl1: gcc13 array-bounds false positives on the fixed-address structs.
    for m in spl fdl sd; do
      sed -i 's/-Werror/-Wno-error/g' "$HOME_PATH/boot/bl1/$m/Makefile"
    done

    # SD-boot SPL size fix: the sd/ variant links FatFS + the SD mmc driver on
    # top of the normal SPL, so under gcc13 its raw binary is 51448 B -- 248 B
    # over the sign tool's hard 50K (51200 B) slot (spl_AX620E_sign.py:
    # max_img_size = 128K - 77K(fw) - 1K(header) = 51200; do_spl() returns False
    # on overflow but the script still exits 0, so `make install` would SILENTLY
    # emit no signed SD SPL). Turn on dead-code elimination -- unused FatFS/gzipd/
    # DDR-training/secure paths get GC'd -- which drops the raw binary to 48460 B
    # (2740 B headroom). Purely a link-size change; the boot logic is untouched.
    sed -i 's/-fno-builtin -s/-fno-builtin -s -ffunction-sections -fdata-sections/' \
      "$HOME_PATH/boot/bl1/sd/Makefile"
    sed -i 's/^LDFLAGS  := --entry=_start$/LDFLAGS  := --entry=_start --gc-sections/' \
      "$HOME_PATH/boot/bl1/sd/Makefile"

    # OP-TEE build scripts carry /bin/bash shebangs.
    patchShebangs "$HOME_PATH/boot/optee"
${pkgs.lib.optionalString sdConsoleUart1 ''
    # =======================================================================
    # CONSOLE UART REDIRECT: UART0 (0x4880000 / ttyS0) -> UART1 (0x4881000 /
    # ttyS1) for EVERY from-source stage. Only the console/debug-UART selection
    # is touched; the FDL/USB-download UART channel and unrelated 0x4880000 refs
    # are left alone. Each stage is verified below (grep the sources).
    # =======================================================================
    b="$HOME_PATH/boot"

    # ---- 1. SPL / bl1 -----------------------------------------------------
    # The SPL boot console prints via core/trace/trace.c ax_print_str/ax_print_num
    # which hardcode uart_putc(UART0_BASE,...). And spl_main.c inits the console
    # with uart_init(USE_UART) where USE_UART is UART0_BASE. Point both at UART1
    # (uart_init pin-muxes+configures whichever base it is given).
    sed -i 's/uart_putc(UART0_BASE,/uart_putc(UART1_BASE,/g' \
      "$b/bl1/core/trace/trace.c"
    sed -i 's/^#define USE_UART[[:space:]]\+UART0_BASE/#define USE_UART\t\tUART1_BASE/' \
      "$b/bl1/driver/include/uart.h"

    # ---- 2. ATF / bl31 ----------------------------------------------------
    # plat/axera/ax620e uses console_16550_register(UART0_BASE,...) in both
    # ax620e_bl31_setup.c (boot) and drivers/wakeup/wakeup.c (resume). ax620e_def.h
    # defines UART0_BASE only; add UART1_BASE and switch the console registrations.
    # Both UARTs live inside the already-mapped PERIPH_SYS region (0x04800000+56M).
    atf="$b/atf/arm-trusted-firmware-2.7/plat/axera/ax620e"
    grep -q 'UART1_BASE' "$atf/include/ax620e_def.h" || \
      sed -i '/^#define UART0_SIZE/a #define UART1_BASE\t\t0x04881000' \
        "$atf/include/ax620e_def.h"
    sed -i 's/console_16550_register(UART0_BASE,/console_16550_register(UART1_BASE,/' \
      "$atf/ax620e_bl31_setup.c" "$atf/drivers/wakeup/wakeup.c"

    # ---- 3. OP-TEE / bl32 -------------------------------------------------
    # plat-axera/platform_config.h selects CONSOLE_UART_BASE = UART0_BASE (UART1_BASE
    # already defined there). Switch the console base (both HAPS/non-HAPS lines).
    sed -i 's/^#define CONSOLE_UART_BASE[[:space:]]\+UART0_BASE/#define CONSOLE_UART_BASE\tUART1_BASE/' \
      "$b/optee/optee_os-3.21.0/core/arch/arm/plat-axera/platform_config.h"

    # ---- 4. U-Boot / bl33 -------------------------------------------------
    # U-Boot uses the LEGACY ns16550 serial driver (CONFIG_SYS_NS16550_SERIAL, no
    # DM_SERIAL): the console port = serial_ports[CONFIG_CONS_INDEX-1] mapping to
    # CONFIG_SYS_NS16550_COMn. Defconfig has CONS_INDEX=1 (-> COM1 = 0x4880000).
    # Set CONS_INDEX=2 (-> COM2 = 0x4881000 = UART1). config2defconfig.py only
    # overrides its own mapped symbols, so this survives into .config.
    sed -i 's/^CONFIG_CONS_INDEX=1$/CONFIG_CONS_INDEX=2/' \
      "$b/uboot/u-boot-2020.04/configs/AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig"
    # Also redirect the kernel cmdline that SD-boot U-Boot injects (BOOTARGS_SD),
    # so whichever wins at booti (env bootargs vs dtb /chosen/bootargs) the kernel
    # console lands on UART1 too. This exact string occurs only in BOOTARGS_SD.
    sed -i 's#console=ttyS0,115200n8 earlycon=uart8250,mmio32,0x4880000 init=/sbin/init#console=ttyS1,115200n8 earlycon=uart8250,mmio32,0x4881000 init=/sbin/init#' \
      "$b/uboot/u-boot-2020.04/include/configs/ax620e_common.h"

    echo "=== console-redirect (UART0->UART1) applied; verifying sources ==="
    grep -n 'uart_putc(UART1_BASE' "$b/bl1/core/trace/trace.c"
    grep -n 'USE_UART' "$b/bl1/driver/include/uart.h"
    grep -n 'UART1_BASE\|console_16550_register' "$atf/include/ax620e_def.h" "$atf/ax620e_bl31_setup.c"
    grep -n 'CONSOLE_UART_BASE' "$b/optee/optee_os-3.21.0/core/arch/arm/plat-axera/platform_config.h"
    grep -n 'CONFIG_CONS_INDEX' "$b/uboot/u-boot-2020.04/configs/AX630C_emmc_arm64_k419_sipeed_nanokvm_defconfig"
    grep -n 'BOOTARGS_SD' "$b/uboot/u-boot-2020.04/include/configs/ax620e_common.h"
    ''}
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    cd "$HOME_PATH"

    mk="make p=${project} PROJECT=${project} CROSS=${crossPrefix}"

    echo "=== [1/4] OP-TEE (bl32, secure world) ==="
    ( cd boot/optee && $mk optee && $mk install )

    echo "=== [2/4] ATF (bl31) ==="
    ( cd boot/atf && $mk atf_bl31 && $mk install )

    echo "=== [3/4] FSBL/SPL + DDR init (bl1) ==="
    ( cd boot/bl1 && $mk all )
    # Install fdl (FDL1), spl (eMMC SPL + ddrinit signed images) AND the SD-boot
    # SPL. The sd/ variant now fits its 50K sign slot (see the gc-sections fix in
    # configurePhase), so it signs cleanly to spl_<project>_sd_signed.bin -- the
    # `boot.bin` the AX620E BootROM loads from the FAT partition of an SD card
    # (consumed by pkgs/sd-image.nix). A hard size guard in installPhase fails the
    # build LOUDLY if the raw SD SPL ever creeps back over 51200 B (which would
    # make the sign tool silently drop its output).
    ( cd boot/bl1/fdl && $mk install CONFIG_PROJECT=AX620E_CFG )
    ( cd boot/bl1/spl && $mk install CONFIG_PROJECT=AX620E_CFG )
    ( cd boot/bl1/sd  && $mk install CONFIG_PROJECT=AX620E_CFG )

    echo "=== [4/4] U-Boot 2020.04 (bl33) + FDL2 ==="
    # Native HOSTCC (gcc, from the native stdenv) for u-boot's build-time host
    # tools (fixdep, mkimage, ...); the cross gcc only builds the target.
    ( cd boot/uboot && $mk HOSTCC=gcc all && $mk HOSTCC=gcc install )

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    imgs="$HOME_PATH/build/out/${project}/images"
    mkdir -p "$out/images"

    # SD-boot SPL raw-size guard: the sign tool's slot is a hard 51200 B (50K);
    # over it the tool silently emits nothing. Assert here so a size regression
    # fails IN-BUILD, never on an SD card that won't boot.
    sdRaw="$imgs/spl_${project}_sd.bin"
    if [ -f "$sdRaw" ]; then
      sdSz=$(stat -c %s "$sdRaw")
      echo "SD SPL raw size: $sdSz B (limit 51200)"
      if [ "$sdSz" -gt 51200 ]; then
        echo "ERROR: SD SPL ($sdSz B) exceeds the 50K/51200 B sign slot -- shrink it" >&2
        exit 1
      fi
    fi

    # Signed per-partition images (what the image/.axp layer consumes).
    # spl_<project>_sd_signed.bin is the SD-card boot SPL (pkgs/sd-image.nix).
    for f in \
      spl_${project}_signed.bin \
      spl_${project}_enc_signed.bin \
      spl_${project}_sd_signed.bin \
      spl_${project}_enc_sd_signed.bin \
      ddrinit_${project}_signed.bin \
      atf_bl31_signed.bin \
      atf_b_bl31_signed.bin \
      u-boot_signed.bin \
      u-boot_b_signed.bin \
      optee_signed.bin \
      fdl_${project}_signed.bin \
      fdl2_signed.bin \
      ; do
      if [ -f "$imgs/$f" ]; then
        cp "$imgs/$f" "$out/images/$f"
      else
        echo "ERROR: expected boot image missing: $f" >&2
        exit 1
      fi
    done

    # Raw (unsigned) binaries + logo, for debugging / alternate packaging.
    for f in atf_bl31.bin u-boot.bin spl_${project}.bin fdl2.bin \
             axera_logo.bmp eip_ax620e.bin; do
      [ -f "$imgs/$f" ] && cp "$imgs/$f" "$out/images/$f" || true
    done

    # Sanity: every *_signed.bin must carry the AX boot header magic 0x55543322
    # at byte offset 4 (little-endian 22 33 54 55). Fail LOUDLY in-build, never
    # on the device.
    for f in "$out/images/"*_signed.bin; do
      magic=$(od -An -tx1 -j4 -N4 "$f" | tr -d ' ')
      if [ "$magic" != "22335455" ]; then
        echo "ERROR: $f bad header magic ($magic != 22335455)" >&2
        exit 1
      fi
    done

    echo "Boot chain images:"
    ls -l "$out/images"

    runHook postInstall
  '';

  dontStrip = true;
  dontPatchELF = true;

  meta = {
    description = "NanoKVM-Pro AX630C boot chain (SPL/DDR-init + ATF bl31 + OP-TEE bl32 + U-Boot 2020.04 bl33), signed with repo dev keys, from source";
    # Install steps run the prebuilt x86-64 ax_gzip host tool.
    platforms = [ "x86_64-linux" ];
  };
}

# ===========================================================================
# SECURE-BOOT VERDICT (from SOURCE; on-device efuse NOT read):
#   (A) Boards are expected to ship OPEN (SECURE_BOOT_EN efuse unburned), so
#       these built images -- signed with the committed repo keys -- boot and
#       flashing a self-built boot chain is feasible. HIGH confidence, because:
#         * the only signing keys in the SDK are the committed dev/test keys
#           (public modulus is a repeating placeholder pattern); enabling secure
#           boot would require burning THIS public key's hash into efuse, which
#           would pin every device to a key whose PRIVATE half is in the repo --
#           self-defeating, so vendors do not.
#         * signature/pubkey-hash verification is fully gated by is_secure_enable()
#           (efuse bit 1<<26) in boot/bl1/core/boot/boot.c; unburned => no check.
#         * the SDK contains NO efuse-burn step (efuse_drv.c is read-only) -- these
#           images are stored plaintext (no IMG_CIPHER_ENABLE) with a decorative
#           signature.
#   Residual risk -> (C): definitive enforcement state is per-unit and can only be
#   confirmed by reading the SECURE_BOOT_EN efuse on the actual board. If a unit
#   were fused to a DIFFERENT key (B), the SPL would reject our-key-signed SPL/ATF/
#   OP-TEE/U-Boot at public_key_verify, and only images above the trust break
#   (kernel/rootfs) could be replaced. No evidence in-source that retail units are
#   fused.
# ===========================================================================
