{ pkgs, width ? 800, height ? 480, text ? "open-nanokvm-pro", ... }:

# ===========================================================================
# The boot LOGO partition image (p8 `logo` / p9 `logo_b`, 6 MiB each), from
# source.
#
# FORMAT, read off the vendor member itself (`axera_logo.bmp`, 1152054 B --
# a data file, so inspecting it is not reverse engineering):
#
#   42 4d              "BM"
#   36 94 11 00        bfSize     = 1152054 = 54 + 800*480*3
#   36 00 00 00        bfOffBits  = 54            (no palette)
#   28 00 00 00        biSize     = 40            (BITMAPINFOHEADER)
#   20 03 00 00        biWidth    = 800
#   e0 01 00 00        biHeight   = 480           (positive: bottom-up)
#   01 00  18 00       planes 1, biBitCount = 24
#   00 00 00 00        biCompression = 0          (BI_RGB, uncompressed)
#
# So: a plain uncompressed 24-bpp bottom-up Windows BMP at 800x480, padded to
# nothing (800*3 = 2400 is already a multiple of 4). No Axera header, no
# checksum, no signature -- the 1 KB signed header that wraps the kernel and
# dtb partitions is NOT present here. That makes the member reproducible from
# any image tool, which is what this derivation does.
#
# The generated image asserts every one of those header fields below, so a
# future ImageMagick that decides to emit BITMAPV4HEADER or a bottom-up flip
# fails the build instead of shipping a member the loader may not parse.
#
# WHAT READS IT, and what it will accept. U-Boot's `ax_bootlogo_show()`, once,
# from `stdio_add_devices()`. It tries `/boot/logo.bmp` on the vfat p16 first
# and falls back to reading the whole 6 MiB `logo` partition -- our /boot ships
# no logo.bmp, so p8 is the source. (`logo_b`, p9, has no reader at all; it
# exists so the A/B updater has a symmetric slot.) The loader checks the `BM`
# signature and the bit depth, computes the stride as `width * bpp/8` with NO
# BMP row padding, and then requires the geometry to be one of six fixed VO
# timings -- hence `allowedGeometries` below. Two consequences:
#   * width * bpp/8 must be a multiple of 4, or every row shears;
#   * an unlisted resolution takes the "unsupported resolution" path, which is
#     the same outcome as a corrupt image.
# And that outcome is harmless: the return value is DISCARDED at the call site,
# so a zeroed or rejected logo costs one console line, the ` logomode=` suffix
# on the kernel command line, and the `boot_logo_reserved` DT node -- nothing
# else. The board's actual front panel (the 172x320 JD9853 SPI TFT) is painted
# from an array compiled into U-Boot and never touches this partition.
# ===========================================================================

let
  font = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans-Bold.ttf";

  # The six geometries `ax_bootlogo_show()` can map to a VO timing. Anything
  # else is rejected by the loader at boot; reject it here instead.
  allowedGeometries = [
    { w = 1920; h = 1080; }
    { w = 800; h = 480; }
    { w = 1080; h = 1920; }
    { w = 1280; h = 720; }
    { w = 720; h = 480; }
    { w = 480; h = 640; }
  ];
in
assert pkgs.lib.assertMsg
  (builtins.any (g: g.w == width && g.h == height) allowedGeometries)
  "pkgs/logo.nix: ${toString width}x${toString height} is not one of the six geometries U-Boot's logo loader can display";
assert pkgs.lib.assertMsg (width * 3 / 4 * 4 == width * 3)
  "pkgs/logo.nix: a 24-bpp row of ${toString width} px is not 4-byte aligned; the loader ignores BMP row padding and the image would shear";
pkgs.runCommand "nanokvm-logo.bmp"
{
  nativeBuildInputs = [ pkgs.imagemagick pkgs.file ];
  meta.description = "NanoKVM-Pro boot logo partition image (${toString width}x${toString height} 24-bpp BMP)";
} ''
  magick -size ${toString width}x${toString height} xc:black \
    -font ${font} -pointsize 46 -fill white -gravity center \
    -annotate 0 '${text}' \
    -depth 8 -type TrueColor -alpha off \
    BMP3:logo.bmp

  # --- the header contract, asserted against the vendor member's shape ---
  expect() { # offset length hex-expected label
    got=$(od -An -tx1 -j"$1" -N"$2" logo.bmp | tr -d ' \n')
    if [ "$got" != "$3" ]; then
      echo "ERROR: BMP $4: got $got, expected $3" >&2; exit 1
    fi
  }
  expect 0  2 "424d"     "magic BM"
  expect 10 4 "36000000" "bfOffBits = 54"
  expect 14 4 "28000000" "biSize = 40 (BITMAPINFOHEADER)"
  expect 26 2 "0100"     "planes = 1"
  expect 28 2 "1800"     "biBitCount = 24"
  expect 30 4 "00000000" "biCompression = BI_RGB"

  size=$(stat -c %s logo.bmp)
  want=$((54 + ${toString width} * ${toString height} * 3))
  [ "$size" = "$want" ] || { echo "ERROR: BMP is $size B, expected $want" >&2; exit 1; }
  echo "logo: ${toString width}x${toString height} 24bpp BI_RGB, $size bytes"

  cp logo.bmp "$out"
''
