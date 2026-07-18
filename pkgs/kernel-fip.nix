{ pkgs, maix_ax620e_sdk, kernel, ... }:

# ===========================================================================
# NanoKVM-Pro AX630C kernel-PARTITION packaging (slot-B / kernel_b, p15).
#
# Turns the from-source kernel `Image` (pkgs/kernel.nix -> $kernel/Image) into
# the EXACT vendor kernel-partition binary that is `dd`-ed to the kernel_b eMMC
# slot. Byte-for-byte the same pipeline the SDK runs in
#   kernel/linux/Makefile.kernel : install:  (SUPPPORT_GZIPD=TRUE branch)
#     ax_gzip -9 Image                                   # HW-gzipd payload
#     sec_boot_AX620E_sign.py -i Image.axgzip \          # 1KB signed header
#         -pub tools/imgsign/public.pem \
#         -prv tools/imgsign/private.pem \
#         -o boot_signed.bin -cap 0x54FAFE -key_bit 2048
#   => build/out/<project>/images/boot_signed.bin  == the kernel partition image.
#
# ---------------------------------------------------------------------------
# FORMAT (reverse-engineered + confirmed against SDK source & stock kernel):
#
#   [ 1024-byte img_header ][ ax_gzip('axgzip' LZ77) compressed Image ]
#
#   img_header (build/tools/imgsign/sec_boot_AX620E_sign.py, `struct img_header`):
#     off 0x00  u32 check_sum          # sum of header words [2 .. 254)
#     off 0x04  u32 magic_data         # 0x55543322  (LE bytes: 22 33 54 55)
#     off 0x08  u32 capability         # 0x0054FAFE  (cap arg; kernel uses 0x54FAFE)
#     off 0x0C  u32 img_size           # = size of the COMPRESSED payload (bytes)
#     off 0x10  u32 reserved0
#     off 0x14  u32 img_check_sum      # 32-bit wrapping sum of payload u32 words
#     ...       reserved / boot_bak_flash_addr (unused, 0)
#     off 0x28  u32 key_n_header       # 0x02000800  (RSA-2048 modulus TLV)
#     off 0x2C  u8  rsa_key_n[384]     # modulus, little-endian (256B used @2048)
#     ...       key_e_header 0x02010020, rsa_key_e[4]
#     ...       sig_header 0x01000800, signature[384]  # RSA-2048 PKCS1v1.5/SHA-256
#     ...       aes_key[48] (0 -- no IMG_CIPHER), reserved
#
#   NOTE: `img_size` is the COMPRESSED (.axgzip) length, NOT the uncompressed
#   Image length. Verified empirically: signed output = payload + 1024, and the
#   off-0x0C field == stat(Image.axgzip). The SPL's gzipd HW learns the
#   decompressed length from the axgzip stream itself.
#
#   The signature is RSA-2048 (SHA-256, PKCS#1 v1.5) over the *compressed*
#   payload, using the SDK's COMMITTED dev/test keypair (tools/imgsign/{public,
#   private}.pem -- an obvious placeholder modulus, repeating pattern). Same key
#   the boot chain uses (see pkgs/boot.nix). cap=0x54FAFE, key_bit=2048 are the
#   kernel-target constants from Makefile.kernel.
#
# ---------------------------------------------------------------------------
# WHY THIS BOOTS (secure boot OFF):  The 1KB header is ALWAYS present and the
# SPL/U-Boot loader always parses it (magic, img_size, checksums drive the
# gzipd DMA + copy). RSA signature / pubkey-hash verification, however, is
# gated by the SECURE_BOOT_EN efuse (bit 1<<26, is_secure_enable()); on a board
# with that efuse unburned -- confirmed OFF on this unit per the efuse read --
# the signature is NOT checked, so our-dev-key-signed payload is accepted. The
# header MUST still be well-formed (correct magic, correct img_size, valid
# checksums) or the loader rejects/mis-copies it; this derivation reproduces the
# vendor tool exactly, so it is well-formed by construction.
#
# ---------------------------------------------------------------------------
# PARTITION TARGET (build/projects/.../partition_ab.mak):
#   kernel_b : 64M, load/exec addr AXERA_KERNEL_IMG_ADDR = 0x40200000
#              (header sits at 0x40200000 - 0x400 = 0x401FFC00).
#   On the 17-partition A/B eMMC layout kernel_b is p15 (p14 = kernel/slot-A,
#   the stock kernel that was extracted for round-trip verification).
#   Flash test:  dd if=kernel_b.bin of=/dev/mmcblk0p15  (slot B, reversible).
#
# DTB:  NOT packaged here. Our board dtb from pkgs/kernel.nix is built with a
# plain `make dtbs` and is MISSING the vendor reserved-memory / bootargs
# injection that Makefile.kernel's `dtbs` target applies via
# scripts/axera/patch_reserve_mem.sh (ATF/OP-TEE/CMM reserved regions, the
# kernel cmdline). Packaging that dtb with the identical gzip+sign flow is
# trivial (SUPPPORT_GZIPD dtb branch: ax_gzip -9 <proj>.dtb; sign -> 1M dtb
# partition, addr 0x40001000), but the CONTENT would be wrong. The first
# slot-B flash test therefore reuses the STOCK dtb slot; do the reserve-mem
# patch before shipping a self-built dtb.  <-- see README / follow-up.
#
# ---------------------------------------------------------------------------
# x86_64-linux ONLY: ax_gzip is Axera's prebuilt x86-64 static ELF (same
# constraint as pkgs/boot.nix). The signing python is portable but the codec is
# not, so the whole derivation is pinned to the flake's x86_64 dev host.
# ===========================================================================

let
  sdk = maix_ax620e_sdk;

  axGzip     = "${sdk}/tools/ax_gzip_tool/ax_gzip";
  signScript = "${sdk}/build/tools/imgsign/sec_boot_AX620E_sign.py";
  pubKey     = "${sdk}/tools/imgsign/public.pem";
  prvKey     = "${sdk}/tools/imgsign/private.pem";

  # partition_ab.mak: KERNEL(_B)_PARTITION_SIZE = 64M. Hard cap enforced below,
  # mirroring the vendor Makefile's `imgsize > kernel_img_size` guard.
  kernelPartSize = 64 * 1024 * 1024;
  kernelLoadAddr = "0x40200000"; # AXERA_KERNEL_IMG_ADDR
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-pro-kernel-slot-image";
  version = "ax630c-kernel-b";

  dontUnpack = true;
  dontConfigure = true;

  # The signing script uses the SDK-vendored pure-python `rsa`/`pyasn1` (it
  # sys.path.append()s <sdk>/tools/imgsign), so a bare python3 suffices -- no
  # extra python packages needed (unlike boot.nix, which also drives OP-TEE's
  # cryptography-based tooling).
  nativeBuildInputs = [ pkgs.python3 ];

  buildPhase = ''
    runHook preBuild

    # ax_gzip writes <input>.axgzip (+ .lz77/.json scratch) NEXT TO its input,
    # so stage the read-only store Image into the writable build dir first.
    cp "${kernel}/Image" ./Image
    chmod u+w ./Image

    echo "=== [1/2] ax_gzip -9 (Axera HW-gzipd 'axgzip' LZ77) ==="
    "${axGzip}" -9 ./Image
    test -f ./Image.axgzip || { echo "ERROR: ax_gzip produced no .axgzip" >&2; exit 1; }
    payloadSize=$(stat -c %s ./Image.axgzip)
    echo "  Image        $(stat -c %s ./Image) bytes (uncompressed)"
    echo "  Image.axgzip $payloadSize bytes (compressed payload)"

    echo "=== [2/2] sec_boot_AX620E_sign.py (1KB header, RSA-2048/SHA-256, dev key) ==="
    python3 "${signScript}" \
      -i ./Image.axgzip \
      -pub "${pubKey}" \
      -prv "${prvKey}" \
      -o ./kernel_b.bin \
      -cap 0x54FAFE -key_bit 2048

    test -f ./kernel_b.bin || { echo "ERROR: sign produced no output" >&2; exit 1; }

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    payloadSize=$(stat -c %s ./Image.axgzip)
    totalSize=$(stat -c %s ./kernel_b.bin)

    # --- format assertions (fail LOUDLY in-build, never on the device) ---

    # (a) 1024-byte header prepended: signed == payload + 1024.
    if [ "$totalSize" -ne "$((payloadSize + 1024))" ]; then
      echo "ERROR: size mismatch: signed=$totalSize payload=$payloadSize (+1024 expected)" >&2
      exit 1
    fi

    # (b) magic 0x55543322 at header offset 4 (LE bytes 22 33 54 55).
    magic=$(od -An -tx1 -j4 -N4 ./kernel_b.bin | tr -d ' ')
    if [ "$magic" != "22335455" ]; then
      echo "ERROR: bad header magic ($magic != 22335455)" >&2
      exit 1
    fi

    # (c) img_size (u32 LE @ offset 12) == compressed payload length.
    imgSize=$(od -An -tu4 -j12 -N4 ./kernel_b.bin | tr -d ' ')
    if [ "$imgSize" != "$payloadSize" ]; then
      echo "ERROR: header img_size ($imgSize) != payload size ($payloadSize)" >&2
      exit 1
    fi

    # (d) fits the 64M kernel_b partition.
    if [ "$totalSize" -gt "${toString kernelPartSize}" ]; then
      echo "ERROR: kernel_b.bin ($totalSize B) exceeds 64M partition (${toString kernelPartSize} B)" >&2
      exit 1
    fi

    # (e) round-trip: strip header + ax_gzip -d must reproduce our Image byte-for-byte.
    tail -c +1025 ./kernel_b.bin > ./roundtrip.axgzip
    "${axGzip}" -d ./roundtrip.axgzip
    if ! cmp -s ./Image ./roundtrip.axgzip.bin; then
      echo "ERROR: round-trip mismatch: decompressed payload != source Image" >&2
      exit 1
    fi
    echo "round-trip OK: header(1024) + ax_gzip -d == source Image"

    mkdir -p "$out"
    cp ./kernel_b.bin "$out/kernel_b.bin"

    # Provenance / flashing note travels with the artifact.
    cat > "$out/FLASH-NOTES.txt" <<EOF
    NanoKVM-Pro AX630C -- self-built kernel partition image (slot B).

    file            : kernel_b.bin
    size            : $totalSize bytes (1024 header + $payloadSize compressed)
    payload codec   : Axera ax_gzip -9  (HW 'axgzip' LZ77, decompressed by SPL gzipd)
    header magic    : 0x55543322 @ off 4 ; img_size(=payload) @ off 12
    signature       : RSA-2048 SHA-256 (PKCS#1 v1.5), SDK committed dev key
    capability      : 0x54FAFE          key_bit: 2048

    TARGET partition: kernel_b  (A/B slot B), 64M
      load/exec addr: ${kernelLoadAddr}   (header @ ${kernelLoadAddr} - 0x400)
      eMMC device   : /dev/mmcblk0p15     (p14 = slot A / stock kernel)

    Flash (reversible slot-B test):
      dd if=kernel_b.bin of=/dev/mmcblk0p15 bs=1M conv=fsync

    Secure boot is OFF on this unit (SECURE_BOOT_EN efuse unburned): the RSA
    signature is NOT verified, but the 1KB header IS parsed -- it is well-formed
    (reproduces the vendor tool exactly), so the SPL/gzipd loader accepts it.

    NOT INCLUDED: dtb. The board dtb from pkgs/kernel.nix lacks the vendor
    reserved-memory/bootargs patch (scripts/axera/patch_reserve_mem.sh). Reuse
    the STOCK dtb slot for the first flash test.
    EOF

    echo "Installed:"
    ls -l "$out"

    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro AX630C kernel partition image for slot B (kernel_b/p15): ax_gzip -9 + vendor RSA-2048 signed header, from the source-built Image";
    # ax_gzip is a prebuilt x86-64 static ELF (same as pkgs/boot.nix).
    platforms = [ "x86_64-linux" ];
  };
}
