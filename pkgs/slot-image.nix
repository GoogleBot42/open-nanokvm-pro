{ pkgs, maix_ax620e_sdk
, payload      # store-path string of the input file (e.g. "${kernel}/Image")
, pname
, version
, artifact     # output filename under $out (consumers reference it by name)
, partSize     # partition byte cap (hard-asserted below)
, loadAddr     # load/exec address, for the FLASH-NOTES documentation
, title        # one-line description of this artifact for FLASH-NOTES
, flashNotes   # variant-specific target/flash/content text for FLASH-NOTES
, nameSuffix ? ""
, ... }:

# ===========================================================================
# NanoKVM-Pro AX630C partition-image packaging (kernel + dtb slots).
#
# Turns a from-source payload (the kernel `Image` or the reserved-memory-patched
# board dtb) into the exact vendor partition binary, byte-for-byte the pipeline
# kernel/linux/Makefile.kernel runs in its SUPPPORT_GZIPD=TRUE install branch:
#     ax_gzip -9 <payload>                              # HW-gzipd payload
#     sec_boot_AX620E_sign.py -i <payload>.axgzip \     # 1KB signed header
#         -pub tools/imgsign/public.pem -prv .../private.pem \
#         -o <out> -cap 0x54FAFE -key_bit 2048
#
# ---------------------------------------------------------------------------
# FORMAT (build/tools/imgsign/sec_boot_AX620E_sign.py, `struct img_header`):
#
#   [ 1024-byte img_header ][ ax_gzip('axgzip' LZ77) compressed payload ]
#
#     off 0x00  u32 check_sum          # sum of header words [2 .. 254)
#     off 0x04  u32 magic_data         # 0x55543322  (LE bytes: 22 33 54 55)
#     off 0x08  u32 capability         # 0x0054FAFE  (cap arg)
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
#   `img_size` is the COMPRESSED (.axgzip) length, NOT the uncompressed payload
#   length: signed output = payload + 1024, and the off-0x0C field == the size of
#   the .axgzip. The SPL's gzipd HW learns the decompressed length from the axgzip
#   stream itself. The RSA-2048 signature (SHA-256, PKCS#1 v1.5) covers the
#   *compressed* payload, using the SDK's committed dev/test keypair
#   (tools/imgsign/{public,private}.pem). cap=0x54FAFE, key_bit=2048 are the
#   kernel/dtb-target constants from Makefile.kernel.
#
#   Secure boot: the 1KB header is ALWAYS parsed by the SPL/U-Boot loader (magic,
#   img_size, checksums drive the gzipd DMA + copy). RSA signature / pubkey-hash
#   verification is gated on the SECURE_BOOT_EN efuse (is_secure_enable(), bit
#   1<<26), expected unburned on retail boards -- so the dev-key signature is not
#   checked. The header must still be well-formed or the loader rejects it; this
#   derivation reproduces the vendor tool exactly, so it is well-formed by
#   construction. See pkgs/boot.nix for the full secure-boot notes.
#
# ---------------------------------------------------------------------------
# PARTITIONS (build/projects/.../partition_ab.mak), passed in per call:
#   kernel : kernel / kernel_b = p14 / p15, 64M, load addr 0x40200000.
#   dtb    : dtb    / dtb_b     = p12 / p13, 1M,  load addr 0x40001000.
#
# x86_64-linux ONLY: ax_gzip is Axera's prebuilt x86-64 static ELF (same
# constraint as pkgs/boot.nix). The signing python is portable, the codec is not.
# ===========================================================================

let
  sdk = maix_ax620e_sdk;

  axGzip     = "${sdk}/tools/ax_gzip_tool/ax_gzip";
  signScript = "${sdk}/build/tools/imgsign/sec_boot_AX620E_sign.py";
  pubKey     = "${sdk}/tools/imgsign/public.pem";
  prvKey     = "${sdk}/tools/imgsign/private.pem";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = pname + nameSuffix;
  inherit version;

  dontUnpack = true;
  dontConfigure = true;

  # The signing script uses the SDK-vendored pure-python `rsa`/`pyasn1` (it
  # sys.path.append()s <sdk>/tools/imgsign), so a bare python3 suffices.
  nativeBuildInputs = [ pkgs.python3 ];

  buildPhase = ''
    runHook preBuild

    # ax_gzip writes <input>.axgzip (+ .lz77/.json scratch) NEXT TO its input,
    # so stage the read-only store payload into the writable build dir first.
    cp "${payload}" ./staged
    chmod u+w ./staged

    echo "=== [1/2] ax_gzip -9 (Axera HW-gzipd 'axgzip' LZ77) ==="
    "${axGzip}" -9 ./staged
    test -f ./staged.axgzip || { echo "ERROR: ax_gzip produced no .axgzip" >&2; exit 1; }
    payloadSize=$(stat -c %s ./staged.axgzip)
    echo "  staged        $(stat -c %s ./staged) bytes (uncompressed)"
    echo "  staged.axgzip $payloadSize bytes (compressed payload)"

    echo "=== [2/2] sec_boot_AX620E_sign.py (1KB header, RSA-2048/SHA-256, dev key) ==="
    python3 "${signScript}" \
      -i ./staged.axgzip \
      -pub "${pubKey}" \
      -prv "${prvKey}" \
      -o ./${artifact} \
      -cap 0x54FAFE -key_bit 2048

    test -f ./${artifact} || { echo "ERROR: sign produced no output" >&2; exit 1; }

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    payloadSize=$(stat -c %s ./staged.axgzip)
    totalSize=$(stat -c %s ./${artifact})

    # --- format assertions (fail LOUDLY in-build, never on the device) ---

    # (a) 1024-byte header prepended: signed == payload + 1024.
    if [ "$totalSize" -ne "$((payloadSize + 1024))" ]; then
      echo "ERROR: size mismatch: signed=$totalSize payload=$payloadSize (+1024 expected)" >&2
      exit 1
    fi

    # (b) magic 0x55543322 at header offset 4 (LE bytes 22 33 54 55).
    magic=$(od -An -tx1 -j4 -N4 ./${artifact} | tr -d ' ')
    if [ "$magic" != "22335455" ]; then
      echo "ERROR: bad header magic ($magic != 22335455)" >&2
      exit 1
    fi

    # (c) img_size (u32 LE @ offset 12) == compressed payload length.
    imgSize=$(od -An -tu4 -j12 -N4 ./${artifact} | tr -d ' ')
    if [ "$imgSize" != "$payloadSize" ]; then
      echo "ERROR: header img_size ($imgSize) != payload size ($payloadSize)" >&2
      exit 1
    fi

    # (d) fits the target partition.
    if [ "$totalSize" -gt "${toString partSize}" ]; then
      echo "ERROR: ${artifact} ($totalSize B) exceeds partition cap (${toString partSize} B)" >&2
      exit 1
    fi

    # (e) round-trip: strip header + ax_gzip -d must reproduce the payload byte-for-byte.
    tail -c +1025 ./${artifact} > ./roundtrip.axgzip
    "${axGzip}" -d ./roundtrip.axgzip
    if ! cmp -s ./staged ./roundtrip.axgzip.bin; then
      echo "ERROR: round-trip mismatch: decompressed payload != source" >&2
      exit 1
    fi
    echo "round-trip OK: header(1024) + ax_gzip -d == source payload"

    mkdir -p "$out"
    cp ./${artifact} "$out/${artifact}"

    # Provenance / flashing note travels with the artifact.
    cat > "$out/FLASH-NOTES.txt" <<EOF
    NanoKVM-Pro AX630C -- ${title}

    file            : ${artifact}
    size            : $totalSize bytes (1024 header + $payloadSize compressed)
    payload codec   : Axera ax_gzip -9  (HW 'axgzip' LZ77, decompressed by SPL gzipd)
    header magic    : 0x55543322 @ off 4 ; img_size(=payload) @ off 12
    signature       : RSA-2048 SHA-256 (PKCS#1 v1.5), SDK committed dev key
    capability      : 0x54FAFE          key_bit: 2048
    load/exec addr  : ${loadAddr}   (header @ ${loadAddr} - 0x400)

    ${flashNotes}

    Secure boot: signature verification is gated on the SECURE_BOOT_EN efuse,
    expected unburned on retail boards -- so the RSA signature is not checked. The
    1KB header is always parsed; this image reproduces the vendor tool exactly, so
    the SPL/gzipd loader accepts it.
    EOF

    echo "Installed:"
    ls -l "$out"

    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro AX630C ${title}: ax_gzip -9 + vendor RSA-2048 signed header";
    # ax_gzip is a prebuilt x86-64 static ELF (same as pkgs/boot.nix).
    platforms = [ "x86_64-linux" ];
  };
}
