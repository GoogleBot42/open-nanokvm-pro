{ pkgs, crossPkgs, maix_ax620e_sdk, ... }:

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
  pname = "nanokvm-pro-boot";
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

    # OP-TEE build scripts carry /bin/bash shebangs.
    patchShebangs "$HOME_PATH/boot/optee"

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
    # Install only fdl (FDL1) + spl (produces spl/ddrinit signed images). We skip
    # the sd/ subdir's install: it signs an SD-card-boot SPL that overflows its
    # 50K SD slot under gcc13's slightly larger codegen -- irrelevant to the eMMC
    # boot path, and its sign script exits 0 regardless, so it is simply omitted.
    ( cd boot/bl1/fdl && $mk install CONFIG_PROJECT=AX620E_CFG )
    ( cd boot/bl1/spl && $mk install CONFIG_PROJECT=AX620E_CFG )

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

    # Signed per-partition images (what the image/.axp layer consumes).
    for f in \
      spl_${project}_signed.bin \
      spl_${project}_enc_signed.bin \
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
