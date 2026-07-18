{ pkgs, maix_ax620e_sdk, dtb, ... }:

# ===========================================================================
# NanoKVM-Pro AX630C DTB-PARTITION packaging (dtb / dtb_b, p12 / p13).
#
# Turns the CORRECTLY-built board dtb (pkgs/dtb.nix -> reserved-memory patched)
# into the exact vendor dtb-partition binary, byte-for-byte the pipeline
# kernel/linux/Makefile.kernel : install_dtb (SUPPPORT_GZIPD=TRUE branch):
#     ax_gzip -9 <project>.dtb                              # HW-gzipd payload
#     sec_boot_AX620E_sign.py -i <project>.dtb.axgzip \     # 1KB signed header
#         -pub tools/imgsign/public.pem -prv .../private.pem \
#         -o <project>_signed.dtb -cap 0x54FAFE -key_bit 2048
#   => build/out/<project>/images/<project>_signed.dtb  == the dtb partition image.
#
# Same 1024-byte img_header format + RSA-2048/SHA-256 dev-key signature as the
# kernel partition (see kernel-fip.nix for the full format/secure-boot notes);
# only the cap constant is shared (0x54FAFE) and the payload is the dtb.
#
# PARTITION TARGET (partition_ab.mak):
#   dtb   : 1M, DTB_PARTITION_SIZE ; AXERA_DTB_IMG_ADDR = 0x40001000
#           (header sits at 0x40001000 - 0x400 = 0x40000C00).
#   17-partition A/B eMMC layout: dtb = p12, dtb_b = p13 (identical image in both).
#
# OUTPUT NAME:  the vendor DTB_IMAGE is $(PROJECT)_signed.dtb. build_image.py
# (image.nix) swaps this into the .axp under the names
#   AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb      (slot A)
#   AX630C_emmc_arm64_k419_sipeed_nanokvm_signed.dtb.1    (slot B)
# so we emit exactly $(PROJECT)_signed.dtb here.
#
# x86_64-linux ONLY: ax_gzip is Axera's prebuilt x86-64 static ELF.
# ===========================================================================

let
  sdk = maix_ax620e_sdk;
  project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";

  axGzip = "${sdk}/tools/ax_gzip_tool/ax_gzip";
  signScript = "${sdk}/build/tools/imgsign/sec_boot_AX620E_sign.py";
  pubKey = "${sdk}/tools/imgsign/public.pem";
  prvKey = "${sdk}/tools/imgsign/private.pem";

  # partition_ab.mak: DTB_PARTITION_SIZE = 1M. Hard cap, mirroring the vendor
  # Makefile's `imgsize > dtb_img_size` guard.
  dtbPartSize = 1 * 1024 * 1024;
  dtbLoadAddr = "0x40001000"; # AXERA_DTB_IMG_ADDR
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "nanokvm-pro-dtb-slot-image";
  version = "ax630c-dtb";

  dontUnpack = true;
  dontConfigure = true;

  nativeBuildInputs = [ pkgs.python3 ];

  buildPhase = ''
    runHook preBuild

    # ax_gzip writes <input>.axgzip next to its input; stage the read-only store
    # dtb into the writable build dir first.
    cp "${dtb}/dtb/${project}.dtb" ./${project}.dtb
    chmod u+w ./${project}.dtb

    echo "=== [1/2] ax_gzip -9 (Axera HW-gzipd 'axgzip' LZ77) ==="
    "${axGzip}" -9 ./${project}.dtb
    test -f ./${project}.dtb.axgzip || { echo "ERROR: ax_gzip produced no .axgzip" >&2; exit 1; }
    payloadSize=$(stat -c %s ./${project}.dtb.axgzip)
    echo "  ${project}.dtb        $(stat -c %s ./${project}.dtb) bytes (uncompressed)"
    echo "  ${project}.dtb.axgzip $payloadSize bytes (compressed payload)"

    echo "=== [2/2] sec_boot_AX620E_sign.py (1KB header, RSA-2048/SHA-256, dev key) ==="
    python3 "${signScript}" \
      -i ./${project}.dtb.axgzip \
      -pub "${pubKey}" \
      -prv "${prvKey}" \
      -o ./${project}_signed.dtb \
      -cap 0x54FAFE -key_bit 2048

    test -f ./${project}_signed.dtb || { echo "ERROR: sign produced no output" >&2; exit 1; }

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    payloadSize=$(stat -c %s ./${project}.dtb.axgzip)
    totalSize=$(stat -c %s ./${project}_signed.dtb)

    # --- format assertions (fail LOUDLY in-build, never on the device) ---

    # (a) 1024-byte header prepended: signed == payload + 1024.
    if [ "$totalSize" -ne "$((payloadSize + 1024))" ]; then
      echo "ERROR: size mismatch: signed=$totalSize payload=$payloadSize (+1024 expected)" >&2
      exit 1
    fi

    # (b) magic 0x55543322 at header offset 4 (LE bytes 22 33 54 55).
    magic=$(od -An -tx1 -j4 -N4 ./${project}_signed.dtb | tr -d ' ')
    if [ "$magic" != "22335455" ]; then
      echo "ERROR: bad header magic ($magic != 22335455)" >&2
      exit 1
    fi

    # (c) img_size (u32 LE @ offset 12) == compressed payload length.
    imgSize=$(od -An -tu4 -j12 -N4 ./${project}_signed.dtb | tr -d ' ')
    if [ "$imgSize" != "$payloadSize" ]; then
      echo "ERROR: header img_size ($imgSize) != payload size ($payloadSize)" >&2
      exit 1
    fi

    # (d) fits the 1M dtb partition.
    if [ "$totalSize" -gt "${toString dtbPartSize}" ]; then
      echo "ERROR: signed dtb ($totalSize B) exceeds 1M partition (${toString dtbPartSize} B)" >&2
      exit 1
    fi

    # (e) round-trip: strip header + ax_gzip -d must reproduce our dtb byte-for-byte.
    tail -c +1025 ./${project}_signed.dtb > ./roundtrip.axgzip
    "${axGzip}" -d ./roundtrip.axgzip
    if ! cmp -s ./${project}.dtb ./roundtrip.axgzip.bin; then
      echo "ERROR: round-trip mismatch: decompressed payload != source dtb" >&2
      exit 1
    fi
    echo "round-trip OK: header(1024) + ax_gzip -d == source dtb"

    mkdir -p "$out"
    cp ./${project}_signed.dtb "$out/${project}_signed.dtb"

    cat > "$out/FLASH-NOTES.txt" <<EOF
    NanoKVM-Pro AX630C -- self-built dtb partition image (reserved-memory patched).

    file            : ${project}_signed.dtb
    size            : $totalSize bytes (1024 header + $payloadSize compressed)
    payload codec   : Axera ax_gzip -9  (HW 'axgzip' LZ77, decompressed by SPL gzipd)
    header magic    : 0x55543322 @ off 4 ; img_size(=payload) @ off 12
    signature       : RSA-2048 SHA-256 (PKCS#1 v1.5), SDK committed dev key
    capability      : 0x54FAFE          key_bit: 2048

    TARGET partition: dtb / dtb_b  (A/B), 1M each (p12 / p13)
      load/exec addr: ${dtbLoadAddr}   (header @ ${dtbLoadAddr} - 0x400)

    CONTENT: the board dtb now carries the vendor reserved-memory regions
      atf_memreserved  = <0x0 0x40040000 0x0 0x40000>   (256K)
      optee_memserved  = <0x0 0x44200000 0x0 0x2000000> (32M)
    plus the real kernel bootargs (root=/dev/mmcblk0p17 ... blkdevparts=...).
    This is the dtb gap that kernel-fip.nix flagged -- now closed (pkgs/dtb.nix).
    EOF

    echo "Installed:"
    ls -l "$out"

    runHook postInstall
  '';

  meta = {
    description = "NanoKVM-Pro AX630C dtb partition image (dtb/dtb_b, p12/p13): ax_gzip -9 + vendor RSA-2048 signed header, from the reserved-memory-patched dtb";
    platforms = [ "x86_64-linux" ];
  };
}
