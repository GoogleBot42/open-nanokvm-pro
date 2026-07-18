{ pkgs, maix_ax620e_sdk_msp, ... }:

# ---------------------------------------------------------------------------
# Axera userspace media libraries (libax_*.so) + matching V3.0.0 headers.
#
# These are PREBUILT aarch64/glibc binaries, BSD-3-licensed and redistributable
# (this is the accepted "pinned binary input" of the whole design -- the goal
# is an open, self-built firmware that *links* these, not a blob-free build).
#
# Source: sipeed/maix_ax620e_sdk_msp, out/arm64_glibc/{lib,include}. This is the
# SAME SDK snapshot that matches the on-device V3.0.0_20250319 libraries, so the
# ABI matches (verified in the PoCs: headers here compile against and link the
# on-device libax_venc/sys/proton/mipi/ivps).
#
# This is a REAL derivation: it just installs the prebuilt tree. No compiler
# runs. We deliberately do NOT strip or autoPatchelf -- these are target
# (aarch64) binaries that must reach the device byte-for-byte; the runtime
# rpath on-device is /opt/lib (see PoC build.sh), which the rootfs/image layer
# is responsible for populating from this derivation.
#
# The flake input already pins the source rev, so provenance is reproducible
# without a separate fixed-output hash.
# ---------------------------------------------------------------------------

pkgs.stdenvNoCC.mkDerivation {
  pname = "axera-libs";
  version = "3.0.0-msp";

  src = maix_ax620e_sdk_msp;

  # Cross/host mismatch: contents are aarch64 ELF; we are only copying them.
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    subdir=out/arm64_glibc
    if [ ! -d "$subdir/lib" ] || [ ! -d "$subdir/include" ]; then
      echo "ERROR: expected $subdir/{lib,include} in maix_ax620e_sdk_msp" >&2
      echo "Repo layout changed -- re-pin the input and update this path." >&2
      exit 1
    fi

    mkdir -p "$out/lib" "$out/include"
    cp -a "$subdir/lib/." "$out/lib/"
    cp -a "$subdir/include/." "$out/include/"

    # Convenience: also expose the dummy-sensor lib explicitly if present
    # (libsns_dummy.so is dlopen'd by the capture path -- see PLAN.md).
    if [ -f "$out/lib/libsns_dummy.so" ]; then
      echo "libsns_dummy.so present (dummy-sensor inject path OK)"
    else
      echo "WARN: libsns_dummy.so not found in lib/ -- capture path dlopen may fail" >&2
    fi

    runHook postInstall
  '';

  meta = {
    description = "Axera AX630C prebuilt media libraries + V3.0.0 headers (BSD-3, pinned binary input)";
    license = pkgs.lib.licenses.bsd3;
    platforms = pkgs.lib.platforms.linux;
  };
}
