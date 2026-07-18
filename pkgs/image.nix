{ pkgs, nanokvm-pro-src, base-axp, boot, kernel-slot-image, dtb-slot-image, rootfs, ... }:

# ===========================================================================
# Firmware image assembly (REAL) -- OVERLAY approach, via Sipeed's own tool flow.
#
# Sipeed ship support/scripts/build_image/build_image.py, whose replace_axp()
# opens a release .axp (a ZIP) and swaps in custom --dtb / --boot / --uboot, plus
# rewrites the rootfs. We reproduce EXACTLY its file-swap surface -- the same
# member names it targets -- but as a PURE zip rewrite (no sudo/mount/chroot):
# the rootfs modifications build_image.py does via chroot are already baked into
# our overlaid rootfs (pkgs/rootfs.nix), so here we only substitute partition
# images into a copy of the base .axp. The GPT / partition XML is left byte-for-
# byte identical (never repartition -- a size change can hard-brick).
#
# ---------------------------------------------------------------------------
# SWAPPED IN (from source / our derivations)      .axp member(s) replaced
#   our dtb_signed (reserved-mem patched)  ->  AX630C_..._signed.dtb , .dtb.1
#   our kernel partition image             ->  boot_signed.bin , boot_signed.bin.1
#     (kernel-fip.nix "kernel_b.bin" IS the vendor boot_signed.bin format)
#   our U-Boot A / B                       ->  u-boot_signed.bin , u-boot_b_signed.bin
#   our overlaid rootfs                    ->  ubuntu_rootfs_sparse.ext4
#
# KEPT VENDOR (stock images stay in the .axp):
#   spl, ddrinit, atf/atf_b, optee/optee_b, env, logo/logo_b, bootfs.fat32,
#   and the partition XML.  <-- build_image.py does NOT swap these either; they
#   are outside the vendor-supported customization surface. Our from-source
#   SPL/ATF/OP-TEE DO build (pkgs/boot.nix) but landing them needs the deeper
#   raw-partition repack (mkaxp / `build && make ... axp`), out of scope for the
#   overlay flow. See "FROM-SOURCE vs VENDOR" in the flake README/report.
#
# The member names are exactly build_image.py's replacements dict + the rootfs
# entry it rewrites (support/scripts/build_image/build_image.py).
#
# ---------------------------------------------------------------------------
# STATUS: real derivation. Building it realises base-axp (1.4 GB fetch) and the
# overlaid rootfs (multi-GB) -- heavy; not exercised end-to-end in the dev
# sandbox. The pack logic itself is a straightforward streaming zip rewrite.
# ===========================================================================

let
  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";

  # (member-in-axp , replacement file) pairs. Mirrors build_image.py exactly.
  # Slot A and slot B kernel are the same signed image; U-Boot A/B are distinct.
  swaps = {
    "${project}_signed.dtb" = "${dtb-slot-image}/${project}_signed.dtb";
    "${project}_signed.dtb.1" = "${dtb-slot-image}/${project}_signed.dtb";
    "boot_signed.bin" = "${kernel-slot-image}/kernel_b.bin";
    "boot_signed.bin.1" = "${kernel-slot-image}/kernel_b.bin";
    "u-boot_signed.bin" = "${boot}/images/u-boot_signed.bin";
    "u-boot_b_signed.bin" = "${boot}/images/u-boot_b_signed.bin";
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
      dtb    : ${project}_signed.dtb (+ .1)   reserved-memory patched  [pkgs/dtb.nix + dtb-fip.nix]
      kernel : boot_signed.bin (+ .1)          ax_gzip+signed Image     [pkgs/kernel.nix + kernel-fip.nix]
      u-boot : u-boot_signed.bin / u-boot_b_signed.bin                  [pkgs/boot.nix]
      rootfs : ubuntu_rootfs_sparse.ext4  (Ubuntu base + our libkvm.so
               + our kernel modules merged with ax_*.ko, depmod'd)      [pkgs/rootfs.nix]
    VENDOR (kept from the base .axp, per build_image.py's swap surface):
      spl, ddrinit, atf/atf_b, optee/optee_b, env, logo/logo_b, bootfs.fat32, partition XML
      rootfs BASE is vendor Ubuntu-arm64 (only the two overlays above are ours).

    Flash: use the vendor AXDL host flasher with this .axp (same tool/table as stock).
    EOF
    echo "Installed:"; ls -l "$out"
    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro flashable firmware .axp (overlay on vendor v1.0.15 base: from-source dtb + kernel + u-boot + overlaid rootfs)";
    platforms = [ "x86_64-linux" ];
  };
}
