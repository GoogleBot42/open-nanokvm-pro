{ pkgs, nanokvm-pro-src, base-axp, boot, kernel-slot-image, dtb-slot-image, rootfs, ... }:

# ===========================================================================
# Firmware image assembly (REAL) -- OVERLAY approach, via Sipeed's own tool flow.
#
# Sipeed ship support/scripts/build_image/build_image.py, whose replace_axp()
# opens a release .axp (a ZIP) and swaps in custom --dtb / --boot / --uboot, plus
# rewrites the rootfs. We use the same PURE zip-rewrite mechanism (no sudo/mount/
# chroot) but a WIDER swap surface: build_image.py only touches dtb/kernel/u-boot,
# whereas the base .axp is packed by the SDK's own make_axp_v2.py from EVERY signed
# partition image (SPL, DDR-init, ATF, OP-TEE, U-Boot, dtb, kernel, rootfs, ...),
# each ZIP member named by that image's basename. Since pkgs/boot.nix emits those
# exact basenames, we member-swap the whole from-source boot chain, not just the
# build_image.py subset. The rootfs modifications build_image.py does via chroot are
# already baked into our overlaid rootfs (pkgs/rootfs.nix). The GPT / partition XML
# is left byte-for-byte identical (never repartition -- a size change can hard-brick).
#
# ---------------------------------------------------------------------------
# SWAPPED IN (from source / our derivations)      .axp member(s) replaced
#   our dtb_signed (reserved-mem patched)  ->  AX630C_..._signed.dtb , .dtb.1
#   our kernel partition image             ->  boot_signed.bin , boot_signed.bin.1
#     (kernel-fip.nix "kernel_b.bin" IS the vendor boot_signed.bin format)
#   our SPL (FSBL)                         ->  spl_<project>_signed.bin
#   our DDR-init header                    ->  ddrinit_<project>_signed.bin
#   our ATF bl31 A / B                     ->  atf_bl31_signed.bin , atf_b_bl31_signed.bin
#   our OP-TEE (bl32) A / B                ->  optee_signed.bin , optee_signed.bin.1
#   our U-Boot A / B                       ->  u-boot_signed.bin , u-boot_b_signed.bin
#   our overlaid rootfs                    ->  ubuntu_rootfs_sparse.ext4
#
# The base .axp is built by the SDK's tools/mkaxp/make_axp_v2.py, which names
# every ZIP member by the BASENAME of the signed partition image it packs (see
# build/axp_make.sh: SPL_PATH=spl_<project>_signed.bin, ATF_PATH=atf_bl31_signed
# .bin, OPTEE_PATH=optee_signed.bin, ...). Those basenames are EXACTLY the files
# pkgs/boot.nix emits under ${boot}/images/, so every from-source boot stage can
# be landed by the same member-swap mechanism used for u-boot -- no deeper repack
# needed. A/B duplicate-basename members get a ".1" suffix (make_axp_v2's dedup):
# optee A/B share optee_signed.bin[.1]; ATF A/B have distinct basenames.
# Verified against the actual base .axp central directory (all member names present)
# and against partition_ab.mak sizes (every from-source image fits its partition:
# SPL 256K<=768K, DDRINIT 1K<=512K, ATF ~20K<=256K, OPTEE ~293K<=1M, U-Boot ~635K
# <=1536K). The GPT / partition XML is left byte-for-byte identical.
#
# KEPT VENDOR (stock images stay in the .axp):
#   env, logo/logo_b, bootfs.fat32, eip_ax620e.bin, the FDL1/FDL2 download agents,
#   the rootfs BASE (Ubuntu-arm64; only our libkvm + kernel modules are overlaid),
#   and the partition XML.
#   NB: FDL1/FDL2 are the AXDL HOST download agents (not stored partitions); the
#   vendor copies are kept so the stock flasher table is untouched. pkgs/boot.nix
#   does build fdl_<project>_signed.bin / fdl2_signed.bin from source, so they
#   could be swapped too, but they are outside the SPL/DDR/ATF/OP-TEE scope and
#   changing the download agent is a separate decision -- left vendor.
#
# ---------------------------------------------------------------------------
# STATUS: real derivation. Building it realises base-axp (1.4 GB fetch) and the
# overlaid rootfs (multi-GB) -- heavy; not exercised end-to-end in the dev
# sandbox. The pack logic itself is a straightforward streaming zip rewrite.
# ===========================================================================

let
  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";

  # (member-in-axp , replacement file) pairs. Member names are the signed-image
  # basenames make_axp_v2.py packs (build/axp_make.sh); verified against the base
  # .axp central directory. Slot A/B kernel + dtb are the same signed image; OP-TEE
  # A/B are the same signed image (member ".1" is the B dup); ATF and U-Boot A/B
  # are distinct images.
  swaps = {
    # ---- dtb (p12/p13) ----
    "${project}_signed.dtb" = "${dtb-slot-image}/${project}_signed.dtb";
    "${project}_signed.dtb.1" = "${dtb-slot-image}/${project}_signed.dtb";
    # ---- kernel (p14/p15) ----
    "boot_signed.bin" = "${kernel-slot-image}/kernel_b.bin";
    "boot_signed.bin.1" = "${kernel-slot-image}/kernel_b.bin";
    # ---- SPL / DDR-init (p1/p2), from pkgs/boot.nix ----
    "spl_${project}_signed.bin" = "${boot}/images/spl_${project}_signed.bin";
    "ddrinit_${project}_signed.bin" = "${boot}/images/ddrinit_${project}_signed.bin";
    # ---- ATF bl31 A/B (p3/p4), from pkgs/boot.nix ----
    "atf_bl31_signed.bin" = "${boot}/images/atf_bl31_signed.bin";
    "atf_b_bl31_signed.bin" = "${boot}/images/atf_b_bl31_signed.bin";
    # ---- U-Boot A/B (p5/p6), from pkgs/boot.nix ----
    "u-boot_signed.bin" = "${boot}/images/u-boot_signed.bin";
    "u-boot_b_signed.bin" = "${boot}/images/u-boot_b_signed.bin";
    # ---- OP-TEE bl32 A/B (p8/p9), same signed image both slots ----
    "optee_signed.bin" = "${boot}/images/optee_signed.bin";
    "optee_signed.bin.1" = "${boot}/images/optee_signed.bin";
    # ---- rootfs (overlaid: vendor Ubuntu base + our libkvm + kernel modules) ----
    "ubuntu_rootfs_sparse.ext4" = "${rootfs}/ubuntu_rootfs_sparse.ext4";
  };

  swapsJSON = builtins.toJSON swaps;

  # Streaming zip rewrite: copy every member of the base .axp through, replacing
  # the swap targets with our files. Kept at column 0 in its own file to avoid
  # heredoc-indentation pitfalls.
  packPy = pkgs.writeText "pack-axp.py" ''
    import json, sys, zipfile, os

    swaps_path, base_axp, out_axp = sys.argv[1], sys.argv[2], sys.argv[3]
    swaps = json.load(open(swaps_path))
    for m, p in swaps.items():
        if not os.path.isfile(p):
            print(f"ERROR: replacement for '{m}' missing: {p}", file=sys.stderr); sys.exit(1)

    seen = set()
    with zipfile.ZipFile(base_axp, "r") as zin, \
         zipfile.ZipFile(out_axp, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as zout:
        names = zin.namelist()
        for name in names:
            if name in swaps:
                print(f"[swap] {name} <- {swaps[name]}")
                info = zin.getinfo(name)
                with open(swaps[name], "rb") as f:
                    data = f.read()
                zout.writestr(info, data)
                seen.add(name)
            else:
                zout.writestr(zin.getinfo(name), zin.read(name))

    missing = set(swaps) - seen
    if missing:
        print(f"ERROR: swap targets not found in base .axp: {sorted(missing)}", file=sys.stderr)
        print(f"       base .axp members: {names}", file=sys.stderr)
        sys.exit(1)
    print("[ok] all swap targets replaced; every other member copied verbatim.")
  '';
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-pro-firmware-image";
  version = "v1.0.15-overlay";

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = [ pkgs.python3 ];

  # The reference build_image.py (for provenance / the documented alternate path).
  buildImagePy = "${nanokvm-pro-src}/support/scripts/build_image/build_image.py";

  buildPhase = ''
    runHook preBuild
    set -euo pipefail

    cat > swaps.json <<'JSON'
    ${swapsJSON}
    JSON

    echo "=== streaming-rewrite base .axp, swapping in our partition images ==="
    python3 ${packPy} "$PWD/swaps.json" "${base-axp}" "$PWD/firmware.axp"

    test -f firmware.axp
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp firmware.axp "$out/${project}-selfbuilt.axp"
    cat > "$out/IMAGE-NOTES.txt" <<EOF
    NanoKVM-Pro self-built firmware (.axp) -- overlay on vendor v1.0.15 base.

    FROM SOURCE (swapped in):
      spl    : spl_${project}_signed.bin       FSBL, from source        [pkgs/boot.nix]
      ddrinit: ddrinit_${project}_signed.bin   signed header            [pkgs/boot.nix]
      atf    : atf_bl31_signed.bin / atf_b_bl31_signed.bin  bl31        [pkgs/boot.nix]
      optee  : optee_signed.bin (+ .1)         bl32 secure world        [pkgs/boot.nix]
      u-boot : u-boot_signed.bin / u-boot_b_signed.bin  bl33           [pkgs/boot.nix]
      dtb    : ${project}_signed.dtb (+ .1)   reserved-memory patched  [pkgs/dtb.nix + dtb-fip.nix]
      kernel : boot_signed.bin (+ .1)          ax_gzip+signed Image     [pkgs/kernel.nix + kernel-fip.nix]
      rootfs : ubuntu_rootfs_sparse.ext4  (Ubuntu base + our libkvm.so
               + our kernel modules merged with ax_*.ko, depmod'd)      [pkgs/rootfs.nix]
    VENDOR (kept from the base .axp):
      env, logo/logo_b, bootfs.fat32, eip_ax620e.bin, fdl1/fdl2 download agents,
      partition XML. rootfs BASE is vendor Ubuntu-arm64 (only the overlays above
      are ours). The whole from-source boot chain (SPL/DDR/ATF/OP-TEE/U-Boot) is
      signed with the SDK's committed repo dev keys; boots on OPEN (SECURE_BOOT_EN
      efuse unburned) boards -- see pkgs/boot.nix VERDICT note.

    Flash: use the vendor AXDL host flasher with this .axp (same tool/table as stock).
    EOF
    echo "Installed:"; ls -l "$out"
    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro flashable firmware .axp (overlay on vendor v1.0.15 base: from-source boot chain SPL/DDR-init/ATF/OP-TEE/U-Boot + dtb + kernel + overlaid rootfs)";
    platforms = [ "x86_64-linux" ];
  };
}
