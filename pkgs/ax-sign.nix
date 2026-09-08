{ pkgs, maix_ax620e_sdk, ... }:

# ===========================================================================
# The AX620E boot-image container, as a reusable function.
#
# Every stage the SPL loads is wrapped the same way: the payload is compressed
# with Axera's "axgzip" (the format the SoC's gzipd block decompresses in
# hardware) and then given a 1 KiB signed header carrying magic 0x55543322, a
# header checksum, a payload checksum, a capability word and an RSA-2048
# key/signature pair. pkgs/boot.nix gets that for free because the vendor
# makefiles do it; anything built OUTSIDE those makefiles -- mainline U-Boot
# (#89), later a mainline BL31 -- has to do it itself, and this is that.
#
# Both tools come from the SDK snapshot and neither is reimplemented here:
#   tools/ax_gzip_tool/ax_gzip                    prebuilt x86-64 host binary
#   build/tools/imgsign/sec_boot_AX620E_sign.py   python, needs `rsa`
# The script computes its own HOME_PATH from its location and reads the keys
# from $HOME_PATH/tools/imgsign, so the two directories are staged at exactly
# the relative paths it expects.
#
# The keys are the SDK's committed dev/test keys. Signature enforcement is a
# runtime decision made by the SPL from the SECURE_BOOT_EN efuse, which is
# unburned on retail units -- see the long note in pkgs/boot.nix. So these
# images boot on the same units the vendor images do, and the signature is
# there to satisfy a check that never runs rather than to assert anything.
#
# ax_gzip is an x86-64 static ELF, which is why every consumer of this file is
# x86_64-linux only.
# ===========================================================================

let
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.rsa ]);
in
{
  # signImage { name, payload, capability ? …, maxSize ? null }
  #
  #   name        the output file name, e.g. "u-boot_mainline_signed.bin"
  #   payload     path to the raw binary to wrap
  #   capability  the header's capability word; 0x54FAFE is what the vendor
  #               makefiles pass for every RSA-2048 stage
  #   maxSize     bytes; fail the build if the signed image does not fit the
  #               partition it is destined for
  signImage =
    { name
    , payload
    , pname ? "ax-signed-image"
    , capability ? "0x54FAFE"
    , maxSize ? null
    }:
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
      '';
}
