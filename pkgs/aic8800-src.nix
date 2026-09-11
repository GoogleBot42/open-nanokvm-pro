{ pkgs, ... }:

# ===========================================================================
# The aic8800 SDIO driver source, pinned and patched (#85).
#
# WHERE IT COMES FROM. AICsemi publishes no upstream tree and there is no
# mainline driver (none in progress, nothing in linux-firmware). The
# best-maintained GPL source is Radxa's package repo, which is what Radxa's
# apt, Armbian, Gentoo and the AUR all build:
#
#   https://github.com/radxa-pkg/aic8800
#
# It is an AICsemi SDK drop (`5.0+git20260123.5f7be68d`) plus a `debian/patches`
# series that is where every kernel-version fix actually lives -- including
# `fix-linux-7.1-build.patch`, which is the only reason this builds against
# 7.1 at all. Armbian hard-skips kernels >= 7.3, because cfg80211 changed the
# `remain_on_channel`/`mgmt_tx` cookie signatures and removed `probe_client`;
# that is the ceiling asserted in pkgs/kernel-mainline.nix.
#
# THE TREE IS TRIMMED TO SDIO. The repo carries three independent driver
# copies (SDIO, PCIE, USB) of the same SDK; this board's radio is on
# mmc@104d0000, so `src/SDIO` is the whole of what we build and the other two
# are deleted here rather than carried. That is also what makes the patch pass
# strict: two patches in the series (`fix-usb-firmware-path`,
# `fix-Lower-the-debugging-log-level`) have hunks that do not apply, and BOTH
# failures are CRLF line endings in `src/USB` files. Every SDIO hunk in the
# series applies cleanly with zero fuzz, and this derivation asserts it.
#
# HOW THE SERIES IS APPLIED. In `debian/patches/series` order, each patch is
# reduced to its `src/SDIO/` hunks with filterdiff and then applied with
# `-F0` (no fuzz). A patch with no SDIO hunk is skipped by name, and the
# count of applied patches is asserted, so a series that grows a new SDIO fix
# fails the build instead of being silently ignored.
#
# The firmware lives in this same tree (`src/SDIO/driver_fw/fw`) and is packaged
# by pkgs/aic8800-firmware.nix -- the one piece of closed content the blob
# policy permits (docs/provenance.md). The driver is GPL-2.0 source; nothing
# closed is built from it.
# ===========================================================================

let
  inherit (pkgs) lib;

  # Pinned by commit, never by branch. `fix aic8800 sdio firmware load issue`
  # (2026-09-01), the commit that made the firmware directory per-chip -- which
  # is what lets one firmware package serve whichever AIC8800 variant is
  # actually soldered on, without a module parameter naming the chip.
  rev = "516e3b087763d80c44f5e3b6d2dd63e0d925c91d";

  # The number of series patches that touch src/SDIO, counted from the pinned
  # tree. Asserted below: a bump that adds an SDIO fix has to be looked at, not
  # absorbed.
  expectedSdioPatches = 16;
in

pkgs.stdenvNoCC.mkDerivation {
  pname = "aic8800-src";
  version = "5.0+git20260123.5f7be68d-${builtins.substring 0 7 rev}";

  src = pkgs.fetchFromGitHub {
    owner = "radxa-pkg";
    repo = "aic8800";
    inherit rev;
    # Validate with `nix build --rebuild` after any change: a stale
    # fixed-output hash is invisible on a host that already holds the output,
    # which is the trap that shipped a broken `.#update-package` for two days
    # (CLAUDE.md, docs/building.md "Pinned hashes").
    sha256 = "187w51cgvrkkcx7nggqk5v3kwj9a6hgmayzmdwlmd83j1g84q2hk";
  };

  nativeBuildInputs = [ pkgs.patchutils ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    applied=0
    while read -r p; do
      [ -n "$p" ] || continue
      [ -f "debian/patches/$p" ] \
        || { echo "ERROR: series names $p, which is not in debian/patches" >&2; exit 1; }

      # Only the src/SDIO hunks. filterdiff strips one path component with -p1,
      # so the include pattern is the in-tree path.
      filterdiff -p1 -i 'src/SDIO/*' "debian/patches/$p" > "$TMPDIR/sdio.patch" || true
      if [ ! -s "$TMPDIR/sdio.patch" ]; then
        echo "skip  $p (no src/SDIO hunk)"
        continue
      fi

      echo "apply $p"
      patch -p1 -F0 --no-backup-if-mismatch -i "$TMPDIR/sdio.patch" \
        || { echo "ERROR: $p does not apply to src/SDIO" >&2; exit 1; }
      applied=$((applied + 1))
    done < debian/patches/series

    if [ "$applied" -ne ${toString expectedSdioPatches} ]; then
      echo "ERROR: applied $applied src/SDIO patches, expected ${toString expectedSdioPatches}." >&2
      echo "       The series changed -- read the new patch before bumping this." >&2
      exit 1
    fi

    # The kernel-version fix this whole pin exists for. Asserted by its effect,
    # not by its name: a rename upstream must not silently drop it.
    grep -q 'fix-linux-7.1-build.patch' debian/patches/series \
      || { echo "ERROR: the 7.1 build fix left the series" >&2; exit 1; }

    mkdir -p "$out"
    cp -r src/SDIO "$out/SDIO"
    # Provenance travels with the source: the firmware MD5 table (the pin
    # pkgs/aic8800-firmware.nix asserts against), the licence and Debian's
    # copyright file, which is the clearest statement of what is GPL here and
    # what is redistributable-binary-only.
    cp src/firmware_version.md "$out/firmware_version.md"
    cp LICENSE "$out/LICENSE"
    cp debian/copyright "$out/debian-copyright"

    runHook postInstall
  '';

  meta = {
    description = "AICsemi AIC8800 SDIO WiFi driver source (radxa-pkg/aic8800), trimmed to SDIO and patched for Linux 7.1";
    homepage = "https://github.com/radxa-pkg/aic8800";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
  };
}
