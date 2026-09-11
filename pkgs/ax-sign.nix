{ pkgs, maix_ax620e_sdk, ... }:

# ===========================================================================
# The AX620E boot-image container, as a reusable function.
#
# Every stage the SPL loads is wrapped the same way: a 1 KiB signed header
# carrying magic 0x55543322, a header checksum, a payload checksum, a
# capability word and an RSA-2048 key/signature pair, followed by the payload.
# pkgs/boot.nix gets that for free because the vendor makefiles do it; anything
# built OUTSIDE those makefiles -- mainline U-Boot, mainline BL31 -- has to do
# it itself, and this is that.
#
# COMPRESSED OR RAW (#95). Whether the payload is Axera's "axgzip" (the format
# the SoC's gzipd block decompresses in hardware) or the plain binary is
# decided by ONE compile-time flag in the first-stage loader,
# `SUPPPORT_GZIPD`, and by nothing in the container: there is no "compressed"
# bit in `struct img_header` and the capability word is 0x54FAFE either way
# ([SDK]/boot/bl1/core/include/boot.h:87-127 lists every header field and every
# capability bit; [SDK]/boot/atf/Makefile:83-99 signs with the same `-cap` in
# both branches). The SPL decides by itself which it will read:
#
#   SUPPPORT_GZIPD defined -- read_image_data() stages `img_size` bytes at
#     0x58000000 and runs them through gzip_pipeline_flash_read(), which DMAs
#     the decompressed output to `ram_ops + 1024`
#     ([SDK]/boot/bl1/core/boot/boot.c:768-778).
#   not defined -- the same `img_size` bytes are read STRAIGHT to
#     `ram_ops + 1024` by flash_read() (boot.c:781-787).
#
# Either way `img_size` and `img_check_sum` describe the STORED payload, and
# the payload lands at the same address. So `gzip = false` means: sign the raw
# binary, for an SPL built with SUPPPORT_GZIPD=FALSE. The two must be changed
# together -- see the warning in pkgs/spl-minimal.nix.
#
# `gzip = true` IS STILL THE DEFAULT, and the body under it is FROZEN: it is
# byte-for-byte the script this file carried before #95, so `.#uboot-mainline`
# and the flashable image keep the store paths the board is proven on. The
# flashable image is also the AXDL recovery image, and a recovery image that
# fails the same way the candidate did is not a recovery. The default flips,
# and this branch is deleted, once the raw chain has booted the board.
#
# The signing tool comes from the SDK snapshot and is not reimplemented here:
#   build/tools/imgsign/sec_boot_AX620E_sign.py   python, needs `rsa`
# The script computes its own HOME_PATH from its location and reads the keys
# from $HOME_PATH/tools/imgsign, so the two directories are staged at exactly
# the relative paths it expects.
#
# With `gzip = true` a SECOND tool is needed: tools/ax_gzip_tool/ax_gzip, an
# Axera prebuilt x86-64 static ELF. That is the only thing that ever made this
# file -- and every consumer of it -- x86_64-linux only, which is why #95
# exists. The raw path uses no prebuilt binary at all.
#
# The keys are the SDK's committed dev/test keys. Signature enforcement is a
# runtime decision made by the SPL from the SECURE_BOOT_EN efuse, which is
# unburned on retail units -- see the long note in pkgs/boot.nix. So these
# images boot on the same units the vendor images do, and the signature is
# there to satisfy a check that never runs rather than to assert anything.
# ===========================================================================

let
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.rsa ]);
in
{
  # signImage { name, payload, capability ? …, maxSize ? null, gzip ? true }
  #
  #   name        the output file name, e.g. "u-boot_mainline_signed.bin"
  #   payload     path to the raw binary to wrap
  #   capability  the header's capability word; 0x54FAFE is what the vendor
  #               makefiles pass for every RSA-2048 stage
  #   maxSize     bytes; fail the build if the signed image does not fit the
  #               partition it is destined for
  #   gzip        axgzip the payload first (needs the prebuilt x86-64 tool, and
  #               an SPL compiled with SUPPPORT_GZIPD=TRUE to read it)
  signImage =
    { name
    , payload
    , pname ? "ax-signed-image"
    , capability ? "0x54FAFE"
    , maxSize ? null
    , gzip ? true
    }:
    if gzip then
    # ---- FROZEN: the pre-#95 body, unchanged so the store path is too ------
    pkgs.runCommand pname
      {
        nativeBuildInputs = [ pythonEnv ];
        meta.platforms = [ "x86_64-linux" ];
      }
      ''
        set -euo pipefail

        # Stage the two tool trees at the layout the sign script assumes.
        mkdir -p work/build/tools work/tools
        cp -r ${maix_ax620e_sdk}/build/tools/imgsign work/build/tools/imgsign
        cp -r ${maix_ax620e_sdk}/tools/imgsign       work/tools/imgsign
        cp -r ${maix_ax620e_sdk}/tools/ax_gzip_tool  work/tools/ax_gzip_tool
        chmod -R u+w work

        cp ${payload} work/payload.bin

        # axgzip: writes <base>_axgzip.bin beside the input. The SPL requires
        # it -- read_image_data() sends every stage but ddrinit through the
        # gzipd pipeline, and a raw payload fails the "20" magic check.
        ( cd work && ./tools/ax_gzip_tool/ax_gzip -9 payload.bin )
        test -f work/payload_axgzip.bin

        mkdir -p "$out"
        python3 work/build/tools/imgsign/sec_boot_AX620E_sign.py \
          -i work/payload_axgzip.bin \
          -o "$out/${name}" \
          -pub work/tools/imgsign/public.pem \
          -prv work/tools/imgsign/private.pem \
          -cap ${capability} \
          -key_bit 2048

        test -s "$out/${name}" || {
          echo "ERROR: the sign tool produced no output (it exits 0 on overflow)" >&2
          exit 1
        }

        # Magic 0x55543322 lives at byte offset 4, little-endian.
        magic=$(od -An -tx1 -j4 -N4 "$out/${name}" | tr -d ' ')
        if [ "$magic" != "22335455" ]; then
          echo "ERROR: ${name} bad header magic ($magic != 22335455)" >&2
          exit 1
        fi

        sz=$(stat -c %s "$out/${name}")
        echo "${name}: $sz bytes signed (raw $(stat -c %s work/payload.bin), axgzip $(stat -c %s work/payload_axgzip.bin))"
        ${pkgs.lib.optionalString (maxSize != null) ''
        if [ "$sz" -gt ${toString maxSize} ]; then
          echo "ERROR: ${name} is $sz bytes, over its ${toString maxSize}-byte partition" >&2
          exit 1
        fi
        ''}
      ''
    else
    # ---- #95: the payload is stored verbatim -------------------------------
    pkgs.runCommand pname
      {
        nativeBuildInputs = [ pythonEnv ];
        meta.platforms = pkgs.lib.platforms.linux;
        passthru = { inherit gzip; };
      }
      ''
        set -euo pipefail

        # Only the signing tool: no ax_gzip, and therefore no prebuilt binary.
        mkdir -p work/build/tools work/tools
        cp -r ${maix_ax620e_sdk}/build/tools/imgsign work/build/tools/imgsign
        cp -r ${maix_ax620e_sdk}/tools/imgsign       work/tools/imgsign
        chmod -R u+w work

        cp ${payload} work/payload.bin

        mkdir -p "$out"
        python3 work/build/tools/imgsign/sec_boot_AX620E_sign.py \
          -i work/payload.bin \
          -o "$out/${name}" \
          -pub work/tools/imgsign/public.pem \
          -prv work/tools/imgsign/private.pem \
          -cap ${capability} \
          -key_bit 2048

        test -s "$out/${name}" || {
          echo "ERROR: the sign tool produced no output (it exits 0 on overflow)" >&2
          exit 1
        }

        # The header, read back out of the artefact -- not "the tool was
        # invoked correctly" but "the bytes on disk say what the SPL needs
        # them to say", including that the stored payload IS the raw binary.
        python3 ${./ax-sign-verify.py} \
          --image "$out/${name}" \
          --stored work/payload.bin \
          --raw-payload work/payload.bin \
          ${pkgs.lib.optionalString (maxSize != null)
              "--max-size ${toString maxSize}"}

        sz=$(stat -c %s "$out/${name}")
        echo "${name}: $sz bytes signed (raw $(stat -c %s work/payload.bin), stored RAW)"
      '';
}
