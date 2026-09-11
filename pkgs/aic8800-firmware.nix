{ pkgs
, aic8800-src
, ...
}:

# ===========================================================================
# The AIC8800 radio firmware (#85) -- the ONE piece of closed content the blob
# policy permits on this image (CLAUDE.md, docs/provenance.md). It executes on
# the radio's own core, never on the A53s, and Jeremy approved it explicitly on
# 2026-09-04 (#28): "WiFi stays, and the wireless firmware is the ONLY closed
# content permitted on the image -- no closed userspace, no closed .ko, ever."
#
# PINNED BY PER-FILE MD5. `src/firmware_version.md` in the driver tree is
# AICsemi's own manifest: one row per file, with the MD5 and the build-version
# string the firmware reports. Every .bin shipped here is checked against it at
# build time, and every row for a directory we ship must have a file -- so a
# firmware swap upstream is a failed build, not a silent change in what runs on
# the radio. Sixty-two files, asserted by count as well as by sum.
#
# WHY ALL FIVE CHIP DIRECTORIES. The AIC8800 family shares one driver; which
# part is soldered onto the NanoKVM-Pro is read off the SDIO bus at probe, and
# the per-chip firmware patch pinned in pkgs/aic8800-src.nix makes the driver
# append the chip's own subdirectory to the firmware path. Shipping all five is
# 5.1 MB and needs no hardware to be right; narrowing to the one the board
# actually has is a follow-up once `dmesg` has named it (the hardware plan in
# docs/mainline-port.md section 8 asks for exactly that line).
#
# LAYOUT. `$out/lib/firmware/aic8800_fw/SDIO/<chip>/` -- `lib/firmware` because
# that is the only prefix `hardware.firmware` links (nixos/modules/services/
# hardware/udev.nix), and `aic8800_fw/SDIO` because that is the path Radxa's
# `fix-sdio-firmware-path` patch teaches the driver. At runtime the directory
# is reachable as /run/current-system/firmware/aic8800_fw/SDIO, which is what
# nixos/wifi.nix compiles into the module.
#
# NOT COMPRESSED, deliberately: `hardware.firmware` runs every package through
# zstd on a 7.x kernel, and this driver does NOT use request_firmware (the SDK
# builds with CONFIG_USE_FW_REQUEST = n) -- it opens a literal path with
# filp_open, so a `fmacfw.bin.zst` is simply a missing file. `compressFirmware
# = false` is the documented opt-out.
# ===========================================================================

let
  inherit (pkgs) lib;
  expectedFiles = 62;
in

pkgs.stdenvNoCC.mkDerivation {
  pname = "aic8800-firmware";
  inherit (aic8800-src) version;

  src = aic8800-src;

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    dst="$out/lib/firmware/aic8800_fw/SDIO"
    mkdir -p "$dst"

    # The .7z beside the chip directories is a redundant archive of one of
    # them; it is not firmware the driver ever opens.
    for d in "$src"/SDIO/driver_fw/fw/*/; do
      cp -r "$d" "$dst/"
    done
    chmod -R u+w "$out"

    # --- the manifest, flattened ----------------------------------------
    # firmware_version.md is CRLF, and its directory headers use a backslash
    # ("SDIO/driver_fw/fw\aic8800"), so both have to be normalised before any
    # of it can be compared with a path.
    dir=""
    : > "$TMPDIR/manifest"
    while IFS= read -r line; do
      line=''${line%$'\r'}
      case "$line" in
        '##  Directory: '*)
          dir=''${line#'##  Directory: '}
          dir=''${dir//\\//}
          ;;
        '|'*|' |'*)
          IFS='|' read -r _ name sum _rest <<<"$line"
          name=''${name## }; name=''${name%% }
          sum=''${sum## }; sum=''${sum%% }
          case "$name" in
            *.bin) [ ''${#sum} -eq 32 ] && printf '%s %s %s\n' "$dir" "$name" "$sum" >> "$TMPDIR/manifest" ;;
          esac
          ;;
      esac
    done < "$src/firmware_version.md"

    # --- every SDIO row must have a file, with that exact MD5 -------------
    checked=0
    while read -r d f h; do
      case "$d" in SDIO/driver_fw/fw/*) ;; *) continue ;; esac
      chip=''${d##*/}
      p="$dst/$chip/$f"
      [ -f "$p" ] || { echo "ERROR: $chip/$f is in the manifest but not in the tree" >&2; exit 1; }
      g=$(md5sum "$p" | cut -d' ' -f1)
      [ "$g" = "$h" ] || { echo "ERROR: $chip/$f md5 $g, manifest says $h" >&2; exit 1; }
      checked=$((checked + 1))
    done < "$TMPDIR/manifest"

    # --- and every file shipped must be in the manifest -------------------
    # The other direction matters just as much: an unpinned .bin is closed
    # content nobody approved.
    while read -r p; do
      chip=$(basename "$(dirname "$p")")
      f=$(basename "$p")
      grep -q "^SDIO/driver_fw/fw/$chip $f " "$TMPDIR/manifest" \
        || { echo "ERROR: $chip/$f is shipped but has no manifest row" >&2; exit 1; }
    done < <(find "$dst" -type f -name '*.bin')

    if [ "$checked" -ne ${toString expectedFiles} ]; then
      echo "ERROR: verified $checked firmware files, expected ${toString expectedFiles}" >&2
      exit 1
    fi
    echo "aic8800-firmware: $checked .bin files MD5-verified against firmware_version.md"

    # The .txt files beside them (aic_userconfig_*, aic_powerlimit_*) are
    # AICsemi's editable calibration/region tables, not firmware images, and
    # carry no manifest row. They are shipped because the driver reads them.
    find "$dst" -type f ! -name '*.bin' -printf 'config: %P\n'

    # Provenance, in the package: the manifest itself and Debian's copyright
    # file, which is the statement of redistribution terms.
    install -Dm444 "$src/firmware_version.md" "$out/share/doc/aic8800-firmware/firmware_version.md"
    install -Dm444 "$src/debian-copyright" "$out/share/doc/aic8800-firmware/copyright"

    runHook postInstall
  '';

  # See the header: this driver opens literal paths, so the files must keep
  # their names. `hardware.firmware` reads this attribute.
  passthru.compressFirmware = false;

  meta = {
    description = "AIC8800 SDIO radio firmware, MD5-pinned to AICsemi's own manifest (#85)";
    # Redistributable binary firmware, not free software. This is the single
    # approved exception in docs/provenance.md.
    license = lib.licenses.unfreeRedistributableFirmware;
    platforms = lib.platforms.linux;
  };
}
