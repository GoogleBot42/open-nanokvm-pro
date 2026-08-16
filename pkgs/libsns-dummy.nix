{ pkgs, crossPkgs, maix_ax620e_sdk_msp, axera-libs, ... }:

# ===========================================================================
# libsns_dummy.so -- the ISP "dummy sensor" library, built FROM SOURCE (#30).
#
# The closed-capture backend dlopens this by name (kvm_pipeline.c:176) and
# registers its `gSnsdummyObj` (AX_SENSOR_REGISTER_FUNC_T) so the VIN pipe in
# ISP_BYPASS_MODE has a sensor object to talk to -- there is no real sensor;
# the LT6911 HDMI bridge supplies already-formed YUV. Until now the runtime
# copy was the vendor's prebuilt /opt/lib/libsns_dummy.so from the pinned
# Ubuntu base (docs/provenance.md); this builds the same library from the
# SDK's own source (maix_ax620e_sdk_msp component/isp_proton/sensor/
# dummysensor: dummysensor.c + shared i2c/ + common/ sources, GPL-side SDK
# tree), replacing one more opaque binary with a compiled artifact.
#
# The vendor .so is ~1.3 MB; this one is far smaller. The difference is
# baggage, not function: the vendor build drags in AI-ISP glue and debug
# machinery irrelevant to bypass mode. The dlopen contract is exactly the
# `gSnsdummyObj` symbol.
# ===========================================================================

let
  cc = "${crossPkgs.stdenv.cc.targetPrefix}gcc";
  snsRoot = "component/isp_proton/sensor";
in
crossPkgs.stdenv.mkDerivation {
  pname = "libsns-dummy";
  version = "3.0.0";

  src = maix_ax620e_sdk_msp;

  nativeBuildInputs = [ pkgs.patchelf ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    cd ${snsRoot}

    # The SDK generates ax_module_version.h at build time (`modversion`
    # target); it only defines the embedded version-string macro.
    mkdir -p generated
    cat > generated/ax_module_version.h <<'EOF'
    #define AXERA_MODULE_VERSION "sns_dummy V3.0.0 (open-nanokvm-pro from-source build)"
    EOF

    # Mirrors the SDK's Makefile.dynamic: dummysensor.c + the shared i2c and
    # common sources, headers from the sensor tree + the packaged MSP include
    # set (axera-libs). -std=gnu17 for the same GLIBC_2.38-symbol reason as
    # kvm-encoder.nix.
    ${cc} -shared -fPIC -O2 -Wall -std=gnu17 \
      -I i2c -I include -I common/include -I dummysensor -I generated \
      -I ${axera-libs}/include \
      dummysensor/dummysensor.c i2c/i2c.c common/src/sensor_user_debug.c \
      -Wl,-soname,libsns_dummy.so \
      -o libsns_dummy.so

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    # buildPhase cd'd into the sensor tree; the artifact is in the cwd.
    mkdir -p $out/lib
    cp libsns_dummy.so $out/lib/
    runHook postInstall
  '';
}
