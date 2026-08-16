{ pkgs, crossPkgs, nanokvm-pro-src, kvm-encoder, axera-libs
, # Base URL the on-device updater fetches from: the public GitHub downstream
  # mirror's releases (`releases/latest/download` always resolves to the
  # newest release's assets; the Gitea source of truth is Tailscale-only and
  # unreachable from devices). See flake.nix (updateBaseUrl) and
  # docs/updates.md.
  updateBaseUrl ? "https://github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download"
, ...
}:

# ---------------------------------------------------------------------------
# NanoKVM-Server (Go + cgo), cross-built for aarch64/glibc.
# Source: NanoKVM-Pro/server (GPL-3.0). Upstream build: server/build.sh.
#
# cgo dependencies (grepped from the source):
#   common/kvm_vision.go        : #cgo CFLAGS: -I../include
#                                 #cgo LDFLAGS: -L../dl_lib -lkvm   (our encoder)
#   service/stream/opus/decoder.go : #cgo LDFLAGS: -lopus -lm       (audio)
# So this binary hard-links libkvm.so (kvm-encoder) and libopus. Upstream copies
# the built libkvm.so into server/dl_lib/ and patchelf-adds rpath $ORIGIN/dl_lib;
# we instead stage libkvm.so into dl_lib/ pre-build and let Nix set rpath.
# libkvm (kvm-encoder.nix) is the capture+encode backend; the server binary
# links it and its full AX_VENC dependency graph.
# ---------------------------------------------------------------------------

let
  # Cross buildGoModule: emits aarch64 binaries and wires the cross CC for cgo.
  # IMPORTANT: use crossPkgs' own `go` (cross-capable). Overriding it with a
  # native `pkgs.go_1_25` breaks the cross cgo setup (native go passes -m64 to
  # the aarch64 gcc). nixpkgs default go (1.26) already satisfies go.mod's
  # `go 1.25.0` requirement.
  buildGoModule = crossPkgs.buildGoModule;
in
buildGoModule {
  pname = "nanokvm-server";
  version = "unstable-2026-06-12";

  src = nanokvm-pro-src;
  sourceRoot = "source/server";

  # Pinned from the go-modules FOD (2026-07-17); regenerate if go.mod changes.
  vendorHash = "sha256-cPh//bSTnvibkCRqeIwxjWaRI7YQHOK42PZGMcoJhiY=";

  # ---- Redirect application updates from Sipeed's CDN to OUR host -----------
  # So the web UI "update" button pulls firmware/app updates we publish, not
  # Sipeed's. Runs in sourceRoot (server/). See docs/updates.md for the protocol.
  postPatch = ''
    # 1. Base URL. One fixed-string replace rewrites BOTH consts, because
    #    PreviewURL == StableURL + "/preview": replacing the StableURL substring
    #    also fixes the PreviewURL prefix.
    substituteInPlace service/application/service.go \
      --replace-fail 'https://cdn.sipeed.com/nanokvm' '${updateBaseUrl}'

    # 2. Drop the ?now= cache-buster. Release-asset URLs may redirect and a
    #    trailing query can interfere; a static manifest needs no cache-bust.
    substituteInPlace service/application/version.go \
      --replace-fail '"%s/nanokvm_pro_latest.json?now=%d", baseURL, time.Now().Unix()' '"%s/nanokvm_pro_latest.json", baseURL'
    sed -i '/^[[:space:]]*"time"$/d' service/application/version.go

    # 3. Replace the vendor dpkg-based install() with our overlay-copy version
    #    (see pkgs/nanokvm-server/install-override.go.in for the rationale).
    #    install() is the LAST function in update.go: truncate at its signature
    #    and append ours. appNames/getFileInfo become unused package-level decls,
    #    which Go permits (only unused imports / locals are errors).
    sed -i '/^func install(dir string, version string) error {/,$d' service/application/update.go
    cat ${./nanokvm-server/install-override.go.in} >> service/application/update.go

    # 4. Strip the kvmadmin + assistant extension endpoints. Both fetch and run
    #    third-party closed code on user action: /kvmadmin/install pulls the
    #    closed NanoKVM-Admin binary from cdn.sipeed.com, and /assistant pipes to
    #    Alibaba dashscope + assorted CDNs. See docs/provenance.md. We keep only
    #    tailscale. Overwriting extensions.go and DROPPING the assistant/kvmadmin
    #    imports leaves those packages simply uncompiled (no importer references
    #    them -- only extensions.go did), which Go permits; leaving the imports in
    #    would be an unused-import compile error.
    cat > router/extensions.go <<'EOF'
package router

import (
	"NanoKVM-Server/middleware"
	"NanoKVM-Server/service/extensions/tailscale"

	"github.com/gin-gonic/gin"
)

func extensionsRouter(r *gin.Engine) {
	api := r.Group("/api/extensions").Use(middleware.CheckToken())

	ts := tailscale.NewService()

	api.POST("/tailscale/install", ts.Install)     // install tailscale
	api.POST("/tailscale/uninstall", ts.Uninstall) // uninstall tailscale
	api.GET("/tailscale/status", ts.GetStatus)     // get tailscale status
	api.POST("/tailscale/up", ts.Up)               // run tailscale up
	api.POST("/tailscale/down", ts.Down)           // run tailscale down
	api.POST("/tailscale/login", ts.Login)         // tailscale login
	api.POST("/tailscale/logout", ts.Logout)       // tailscale logout
	api.POST("/tailscale/start", ts.Start)         // tailscale start
	api.POST("/tailscale/stop", ts.Stop)           // tailscale stop
	api.POST("/tailscale/restart", ts.Restart)     // tailscale restart
}
EOF

    # 5. Idle power management for the capture pipeline. Adds
    #    common/video_power.go (idle watcher + cgo bindings for our libkvm
    #    extension kvmv_video_suspend/resume -- see pkgs/kvm-encoder/src) and
    #    hooks every frame/audio read with markVideoActive(): reads only happen
    #    while a client is attached (all streamer loops exit at zero clients),
    #    so read-recency == viewer-recency, and the /api/streamer/local poller
    #    (mini-display) can never keep capture awake. Config knob:
    #    videoIdleTimeout (seconds) in /etc/kvm/server.yaml; 0/unset = 300,
    #    negative = disabled. State surfaces as "video_state" ("active" |
    #    "suspended") in /api/streamer/local.
    cp ${./nanokvm-server/video-power.go.in} common/video_power.go

    substituteInPlace common/kvm_vision.go \
      --replace-fail 'func (k *KvmVision) ReadMjpeg(width uint16, height uint16, quality uint16) (data []byte, result int) {' \
'func (k *KvmVision) ReadMjpeg(width uint16, height uint16, quality uint16) (data []byte, result int) {
	k.markVideoActive()' \
      --replace-fail 'func (k *KvmVision) ReadH264(width uint16, height uint16, bitRate uint16) (data []byte, result int) {' \
'func (k *KvmVision) ReadH264(width uint16, height uint16, bitRate uint16) (data []byte, result int) {
	k.markVideoActive()' \
      --replace-fail 'func (k *KvmVision) ReadH265(width uint16, height uint16, bitRate uint16) (data []byte, result int) {' \
'func (k *KvmVision) ReadH265(width uint16, height uint16, bitRate uint16) (data []byte, result int) {
	k.markVideoActive()' \
      --replace-fail 'func (k *KvmVision) ReadAudio() (data []byte, result int) {' \
'func (k *KvmVision) ReadAudio() (data []byte, result int) {
	k.markVideoActive()'

    # Start the idle watcher at boot (after screen/config init).
    substituteInPlace main.go \
      --replace-fail '_ = common.GetScreen()' \
'_ = common.GetScreen()

	// suspend the capture pipeline when idle (our common/video_power.go)
	common.StartVideoIdleWatcher()'

    # Config knob (viper matches the yaml key case-insensitively by field name).
    substituteInPlace config/types.go \
      --replace-fail 'Stun           string   `yaml:"stun"`' \
'Stun           string   `yaml:"stun"`
	VideoIdleTimeout int    `yaml:"videoIdleTimeout"`'

    # Surface the suspend state on /api/streamer/local so pollers (mini-display)
    # can tell "suspended" from plain "no viewer" -- endpoint keeps working
    # while suspended (it only reads /proc + in-memory state).
    substituteInPlace service/ui/response.go \
      --replace-fail 'InstanceID string  `json:"instance_id"`' \
'InstanceID string  `json:"instance_id"`
	VideoState string  `json:"video_state"`'
    substituteInPlace service/ui/streamer.go \
      --replace-fail 'clients := 0' \
'videoState := "active"
	if common.VideoIsSuspended() {
		videoState = "suspended"
	}
	clients := 0' \
      --replace-fail 'Streamer: Streamer{' \
'Streamer: Streamer{
				VideoState: videoState,'

    # Mini-display live preview: loopback keep-alive endpoint the display
    # daemon POSTs while its preview page is open; the lease drives
    # common.PanelPreviewKeepAlive (video-power.go.in) -> kvmv_preview_tick,
    # which publishes panel-ready frames to /dev/shm/nanokvm-preview.
    cp ${./nanokvm-server/panel-preview.go.in} service/ui/panel_preview.go
    substituteInPlace router/local.go \
      --replace-fail 'api.GET("/streamer/local", ui.GetStreamer)' \
'api.GET("/streamer/local", ui.GetStreamer)
	api.POST("/streamer/preview", ui.PanelPreview)'

    # 6. Re-assert the SW_PWR pinmux before every power press. The closed
    #    capture stack re-muxes the VI_D7 pad (= gpio7, the ATX power line)
    #    back to camera-data function on every pipeline init (boot, restart,
    #    idle resume), leaving the power button dead while reset works; the
    #    vendor never muxed it correctly anywhere (their gpio.sh pokes the
    #    wrong register). See pkgs/nanokvm-server/pinmux-power.go.in and
    #    docs/mini-display.md ("ATX GPIO setup").
    cp ${./nanokvm-server/pinmux-power.go.in} service/vm/pinmux_power.go
    sed -i 's|device = conf.GPIOPower$|device = conf.GPIOPower\n\t\tmuxPowerPin()|' \
      service/vm/gpio.go
    grep -q 'muxPowerPin()' service/vm/gpio.go \
      || { echo "ERROR: muxPowerPin hook failed to apply to service/vm/gpio.go" >&2; exit 1; }
  '';

  # cgo on for the kvm_vision + opus bindings.
  env.CGO_ENABLED = "1";
  env.GOEXPERIMENT = "boringcrypto";

  # opus for -lopus; kvm-encoder provides libkvm.so + kvm_vision.h. axera-libs is
  # needed at LINK time only: the real libkvm.so has DT_NEEDED on libax_venc/sys/
  # proton/mipi/ivps, and libax_proton in turn NEEDs libax_engine, so ld must be
  # able to find the whole AX graph to validate the cgo link (see rpath-link below).
  buildInputs = [
    crossPkgs.libopus
    crossPkgs.alsa-lib
    kvm-encoder
    axera-libs
  ];

  # The cgo directive is `-L../dl_lib -lkvm` (relative to server/common). Stage
  # libkvm.so where the linker expects it. Also expose opus include/lib via CGO
  # env so the relative `../include` (server/include, kvm_vision.h) resolves.
  preBuild = ''
    mkdir -p dl_lib
    cp ${kvm-encoder}/lib/libkvm.so dl_lib/libkvm.so
    cp ${kvm-encoder}/lib/libkvm.so dl_lib/libkvm.so.0
    export CGO_CFLAGS="-I$PWD/include -I${crossPkgs.libopus.dev}/include $CGO_CFLAGS"
    # -rpath-link (NOT -L): resolve libkvm.so's transitive deps at link time
    # WITHOUT adding them as DT_NEEDED to the server binary. libkvm DT_NEEDEDs the
    # AX graph (libax_engine via libax_proton, ...) AND libasound.so.2 (its real
    # ALSA HDMI-audio path), so ld must be able to find BOTH to validate the cgo
    # link. On-device the AX libs load from /opt/lib via libkvm's RPATH and
    # libasound from the standard multiarch path.
    export CGO_LDFLAGS="-L$PWD/dl_lib -L${crossPkgs.libopus}/lib -Wl,-rpath-link,${axera-libs}/lib -Wl,-rpath-link,${crossPkgs.alsa-lib}/lib $CGO_LDFLAGS"
  '';

  ldflags = [
    "-X" "main.Version=nix"
    "-X" "main.GitBranch=open-nanokvm-pro"
  ];

  nativeBuildInputs = [ pkgs.patchelf ];

  # Make the binary run on the device's Ubuntu userland, NOT in nix. buildGoModule
  # bakes the nix-store glibc as the ELF interpreter and a nix-store RUNPATH, which
  # do not exist on the target -- so retarget both to on-device paths (matching the
  # vendor binary: interpreter /lib/ld-linux-aarch64.so.1, RUNPATH $ORIGIN/dl_lib).
  # We add /opt/usr/lib (libopus.so.0) and /opt/lib (Axera libs) because, unlike the
  # vendor server, ours DT_NEEDEDs libopus directly. Device glibc is 2.35 and our
  # binary's highest required symbol is GLIBC_2.34, so there is no ABI gap.
  # dontPatchELF stops nix's fixup from shrinking the RUNPATH we set here.
  dontPatchELF = true;
  postInstall = ''
    patchelf \
      --set-interpreter /lib/ld-linux-aarch64.so.1 \
      --set-rpath '$ORIGIN/dl_lib:/opt/lib:/opt/usr/lib' \
      "$out/bin/NanoKVM-Server"
  '';

  # Keep binary unstripped cross-target.
  dontStrip = true;

  meta = {
    description = "NanoKVM-Server (Go+cgo, aarch64) with updates redirected to our releases and the kvmadmin/assistant extensions removed (tailscale kept)";
    license = pkgs.lib.licenses.gpl3Only;
    platforms = pkgs.lib.platforms.linux;
  };
}
