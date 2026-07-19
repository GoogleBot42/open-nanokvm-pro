{ pkgs, maix_ax620e_sdk_kernel, ... }:

# ---------------------------------------------------------------------------
# Prebuilt Axera media kernel modules (ax_*.ko).
#
# These are the closed media/NPU IP drivers: ax_{mipi_rx,proton,ivps,venc,jenc,
# vdec,npu,sys,pool,cmm,base,...}. In the SDK, osdrv/private_drv2kernel carries
# only Makefile shims -- the actual .ko objects ship PREBUILT under
# osdrv/out/arm64_glibc_linux-4.19.125/ko/. They are GPL-tagged (source is
# legally owed by Axera/Sipeed but not published); we pin the binaries.
#
# These .ko load only into a kernel whose vermagic string matches. kernel.nix
# reproduces the vendor vermagic ("4.19.125 SMP preempt mod_unload aarch64")
# exactly and builds with MODVERSIONS off, so the blobs insmod with a plain
# `insmod` (no --force-vermagic). See the compatibility analysis in kernel.nix.
#
# Installs the .ko tree (both plain and .xz variants).
# ---------------------------------------------------------------------------

let
  koSubdir = "osdrv/out/arm64_glibc_linux-4.19.125/ko";
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "ax-ko-blobs";
  version = "3.0.0-k4.19.125";

  src = maix_ax620e_sdk_kernel;

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    if [ ! -d "${koSubdir}" ]; then
      echo "ERROR: expected ${koSubdir} in maix_ax620e_sdk_kernel" >&2
      echo "Repo layout changed -- re-pin the input and update koSubdir." >&2
      exit 1
    fi

    mkdir -p "$out/lib/modules/ax"
    # Keep uncompressed .ko for depmod/insmod during bring-up; the .xz are what
    # the vendor ships in the rootfs (smaller). Install both, let image.nix pick.
    cp -a "${koSubdir}/." "$out/lib/modules/ax/"

    echo "Installed Axera .ko blobs:"
    ls -1 "$out/lib/modules/ax" | grep -v '\.xz$' || true

    runHook postInstall
  '';

  meta = {
    description = "Prebuilt Axera AX630C media kernel modules (ax_*.ko) for Linux 4.19.125 (pinned blobs)";
    # GPL-tagged modules; source not published upstream.
    license = pkgs.lib.licenses.gpl2Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
