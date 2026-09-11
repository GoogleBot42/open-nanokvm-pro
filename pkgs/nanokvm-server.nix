{ pkgs, crossPkgs, nanokvm-pro-src, kvm-encoder
, # The ATX power/reset lines are driven by shelling out to nanokvm-gpio
  # (pkgs/nanokvm-gpio) by device-tree line NAME (#81). Global GPIO numbers are
  # not stable on mainline, and requesting a line is what programs the pad mux;
  # upstream's /sys/class/gpio writes on the numbers 7/35/74/75 -- and the
  # per-press VI_D7 pinmux re-assert they needed -- went with the 4.19 image.
  nanokvm-gpio
, # What the web UI's "update" button does (#86, #100, #101).
  #
  # NO CHANNEL URL IS COMPILED INTO THIS BINARY. Since #101 the server asks
  # `nanokvm-update check --json` -- the device's own configured channel
  # (`nanokvm.update.stableUrl` / `previewUrl`) -- instead of fetching a
  # manifest of its own, so the version the page shows and the closure the
  # button installs come from one place. What is left to choose here is which
  # installer install() is:
  #
  # install() hands off to `nanokvm-update` (install-update.go.in): it
  # substitutes the release's system closure from our signed binary cache,
  # makes it a generation, and reboots. That is the only update path this
  # project publishes.
  ...
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
# libkvm (kvm-encoder.nix) is the capture+encode backend, and since #97 there is
# exactly one build of it -- the blob-free V4L2 + open-VC8000E one the appliance
# ships -- so what this binary links against is what it loads on the device.
# ---------------------------------------------------------------------------

let
  installOverride = ./nanokvm-server/install-update.go.in;
  # The two lines that replace update()'s fetch/download/verify/untar half --
  # see step 3b of postPatch.
  updateFragment = ./nanokvm-server/update-nix.go.in;
  # The whole of service/application/version.go: the version route, asking the
  # updater instead of a compiled-in URL (#101).
  versionOverride = ./nanokvm-server/version-updater.go.in;

  # postPatch below is written at 4-space indentation, and Nix strips NOTHING
  # from it (it contains column-0 lines, so the common indent is zero). A step
  # spliced in from up here must therefore re-indent itself to 4.
  step = s: pkgs.lib.replaceStrings [ "\n" ] [ "\n    " ] (pkgs.lib.removeSuffix "\n" s);

  # ---- Step 6 of postPatch: the ATX GPIO backend ---------------------------
  gpioPatch = ''
      # 6. ATX lines over libgpiod, by device-tree NAME (#81). Mainline has a
      #    real GPIO driver and a pin controller, so both vendor-era
      #    workarounds are deleted rather than ported: the boot-time
      #    /sys/class/gpio export unit, and the per-press VI_D7 pinmux
      #    re-assert that used to live in this step. Requesting a line is what
      #    programs the pad now (gpio-ranges -> gpio_request_enable), and the
      #    pin controller's strict mode keeps it that way.
      #
      #    hardware.go's four sysfs paths become the line names declared in
      #    dts/ax630c-nanokvm-pro.dts, and gpio.go's writeGpio/readGpio become
      #    nanokvm-gpio calls (pkgs/nanokvm-server/gpio-libgpiod.go.in). The
      #    truncate-and-append is step 3's mechanism, guarded the same way:
      #    writeGpio and readGpio are the LAST two declarations in gpio.go, so
      #    a pin bump that adds a third must fail here rather than silently
      #    delete it.
      substituteInPlace config/hardware.go \
        --replace-fail '"/sys/class/gpio/gpio7/value"' '"atx-power"' \
        --replace-fail '"/sys/class/gpio/gpio35/value"' '"atx-reset"' \
        --replace-fail '"/sys/class/gpio/gpio75/value"' '"atx-power-led"' \
        --replace-fail '"/sys/class/gpio/gpio74/value"' '"atx-hdd-led"'

      grep -q '^func writeGpio(device string, duration time.Duration) error {' service/vm/gpio.go \
        || { echo "ERROR: writeGpio anchor not found in service/vm/gpio.go — upstream changed its signature" >&2; exit 1; }
      [ "$(sed -n '/^func writeGpio(device string, duration time.Duration) error {/,$p' service/vm/gpio.go | grep -c '^func ')" = 2 ] \
        || { echo "ERROR: gpio.go does not end in exactly writeGpio+readGpio — the truncation would drop other declarations" >&2; exit 1; }
      sed -i '/^func writeGpio(device string, duration time.Duration) error {/,$d' service/vm/gpio.go
      cat ${./nanokvm-server/gpio-libgpiod.go.in} >> service/vm/gpio.go

      # The replacement shells out and touches no file, so "os" becomes an
      # unused import -- a compile error in Go, not a warning. sed rather than
      # substituteInPlace because the anchors are tab-indented import lines.
      sed -i -e 's|^\t"os"$|\t"os/exec"|' \
             -e 's|^\t"strconv"$|\t"strconv"\n\t"strings"|' service/vm/gpio.go
      grep -q '"os/exec"' service/vm/gpio.go && grep -q '"strings"' service/vm/gpio.go \
        || { echo "ERROR: import rewrite failed in service/vm/gpio.go" >&2; exit 1; }

      substituteInPlace service/vm/gpio.go \
        --replace-fail '@nanokvmGpio@' '${nanokvm-gpio}/bin/nanokvm-gpio'
    '';

  # Cross buildGoModule: emits aarch64 binaries and wires the cross CC for cgo.
  # IMPORTANT: use crossPkgs' own `go` (cross-capable). Overriding it with a
  # native `pkgs.go_1_25` breaks the cross cgo setup (native go passes -m64 to
  # the aarch64 gcc). nixpkgs default go (1.26) already satisfies go.mod's
  # `go 1.25.0` requirement.
  buildGoModule = crossPkgs.buildGoModule;
in
buildGoModule {
  pname = "nanokvm-server";
  # Track the actual upstream pin, so the store path says what was built (#34).
  version = "unstable-${nanokvm-pro-src.shortRev or "unpinned"}";

  src = nanokvm-pro-src;
  sourceRoot = "source/server";

  # Pinned from the go-modules FOD (2026-09-07). The vendor tree depends on
  # postPatch too, not just go.mod: `go mod vendor` only vendors packages the
  # main module actually imports, so a patch that drops an import drops its
  # module. Regenerate with `nix build --rebuild` on the go-modules drv (a stale
  # pin is invisible on a host that already has the output — see docs/building.md).
  vendorHash = "sha256-jvtP0rk43UvYAosNfQN03aEh1EusZmDT+cTj0ui6Y0M=";

  # ---- The update path asks the DEVICE, not a compiled-in URL --------------
  # Steps 1-2 are the whole of it: the version route runs `nanokvm-update check
  # --json` and install() hands off to the same tool, so one press of the web
  # UI's button reads one channel -- the device's own (#101). Runs in sourceRoot
  # (server/). See docs/updates.md for the protocol.
  postPatch = ''
    # 1. THE VERSION ROUTE. Replace service/application/version.go wholesale:
    #    upstream's fetches <StableURL>/<manifest> over HTTP from a base URL
    #    compiled into this binary, which is the second source of truth #101
    #    deletes. Ours runs the updater (version-updater.go.in).
    #
    #    A whole-file replacement rather than a truncate-and-append, because
    #    all three of its declarations change; the guard is that the file is
    #    still exactly those three, so a pin bump that adds anything to it
    #    fails here instead of silently losing it (#34).
    [ "$(grep -c '^func ' service/application/version.go)" = 3 ] \
      || { echo "ERROR: version.go is no longer exactly three functions — the replacement would drop what upstream added" >&2; exit 1; }
    for f in 'func (s \*Service) GetVersion(c \*gin.Context) {' \
             'func getCurrentVersion() string {' \
             'func getLatest() (\*Latest, error) {'; do
      grep -q "^$f" service/application/version.go \
        || { echo "ERROR: version.go does not declare $f — upstream restructured it" >&2; exit 1; }
    done
    cp ${versionOverride} service/application/version.go

    # 2. That leaves the two vendor CDN base URLs referenced by nothing.
    #     Delete them rather than leaving dead consts: they are network
    #     endpoints in a binary we publish, and docs/provenance.md is an
    #     audit of exactly that. The grep afterwards is the guard -- if any
    #     caller is left, the build fails instead of shipping a compile error.
    sed -i '/^\tStableURL  = "https:\/\/cdn\.sipeed\.com\/nanokvm"$/d' service/application/service.go
    sed -i '/^\tPreviewURL = "https:\/\/cdn\.sipeed\.com\/nanokvm\/preview"$/d' service/application/service.go
    ! grep -rn 'StableURL\|PreviewURL' --include='*.go' . \
      || { echo "ERROR: something still references StableURL/PreviewURL after deleting them" >&2; exit 1; }
    ! grep -rn 'cdn\.sipeed\.com/nanokvm' --include='*.go' service/application \
      || { echo "ERROR: a Sipeed CDN update URL survived in service/application" >&2; exit 1; }

    # 3. Replace the vendor dpkg-based install() with ours -- the handoff to
    #    `nanokvm-update` (install-update.go.in).
    #    install() is the LAST function in update.go: truncate at its signature
    #    and append ours. appNames/getFileInfo become unused package-level decls,
    #    which Go permits (only unused imports / locals are errors).
    #    Guarded for pin bumps (#34): fail loudly if the anchor is missing or
    #    upstream added declarations after install() that the truncation would
    #    silently delete.
    grep -q '^func install(dir string, version string) error {' service/application/update.go \
      || { echo "ERROR: install() anchor not found in update.go — upstream changed its signature" >&2; exit 1; }
    [ "$(sed -n '/^func install(dir string, version string) error {/,$p' service/application/update.go | grep -c '^func ')" = 1 ] \
      || { echo "ERROR: update.go has declarations after install() — the truncation would silently drop them" >&2; exit 1; }
    sed -i '/^func install(dir string, version string) error {/,$d' service/application/update.go
    cat ${installOverride} >> service/application/update.go
    # 3b. ...and cut everything update() did BEFORE install() out with it.
    #     There is no payload to download (#100 -- the manifest names a store
    #     path and `nanokvm-update` substitutes that closure from the signed
    #     cache), and no manifest to fetch either (#101 -- `install-now`
    #     fetches the device's own channel, and the getLatest() this used to
    #     call fetched a URL compiled into the binary). So the whole sequence
    #     from the version check to the install call goes.
    #
    #     Insert the replacement AFTER the block's last line, then delete the
    #     block -- two passes, because mixing sed's `r` and `d` on one address
    #     is not the same thing twice.
    #     The anchors are TAB-indented, and `grep` does not read \t as a tab
    #     -- `sed` does, so each guard is a sed match with a counted result.
    [ "$(sed -n '/^\tlatest, err := getLatest()$/p' service/application/update.go | wc -l)" = 1 ] \
      || { echo "ERROR: update()'s getLatest() call is not present exactly once — upstream restructured the update path" >&2; exit 1; }
    [ "$(sed -n '/^\t\/\/ download$/p' service/application/update.go | wc -l)" = 1 ] \
      || { echo "ERROR: update()'s '// download' anchor is not present exactly once — upstream restructured the download path" >&2; exit 1; }
    [ "$(sed -n '/^\terr = install(dir, latest.Version)$/p' service/application/update.go | wc -l)" = 1 ] \
      || { echo "ERROR: update()'s install() call is not present exactly once — upstream restructured the download path" >&2; exit 1; }
    sed -i '/^\terr = install(dir, latest.Version)$/r ${updateFragment}' service/application/update.go
    sed -i '/^\tlatest, err := getLatest()$/,/^\terr = install(dir, latest.Version)$/d' service/application/update.go
    grep -q 'err := install("", "")' service/application/update.go \
      || { echo "ERROR: the nix-native install() call is not in update()" >&2; exit 1; }
    ! grep -q 'getLatest\|UnTarGz\|latest\.' service/application/update.go \
      || { echo "ERROR: update() still fetches a manifest or untars a payload" >&2; exit 1; }

    # `dir` and `tarFile` went with the block, and so did update.go's only
    # uses of path/filepath. An unused import is a Go compile error.
    sed -i '/^\t"path\/filepath"$/d' service/application/update.go
    ! grep -q 'filepath\.' service/application/update.go \
      || { echo "ERROR: update.go still uses path/filepath after dropping its import" >&2; exit 1; }

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

    ${step gpioPatch}

    # 7. Backoff in the stream read loops. Upstream retries a failing
    #    ReadH264/ReadMjpeg with a bare `continue` on a 120 Hz ticker -- a wedged
    #    encoder means an infinite retry storm that once grew the server log to
    #    470 MB (two log lines per attempt, no rotation anywhere). After 30
    #    consecutive failures (~250 ms), drop to one attempt per second until a
    #    read succeeds. libkvm has its own 500 ms create-cooldown; this catches
    #    every other failure mode too.
    substituteInPlace service/stream/direct/streamer.go \
      --replace-fail 'startTime := time.Now()' \
'startTime := time.Now()
	failStreak := 0' \
      --replace-fail 'data, result := vision.ReadH264(screen.Width, screen.Height, screen.BitRate)
		if result < 0 || len(data) == 0 {
			continue
		}' \
'data, result := vision.ReadH264(screen.Width, screen.Height, screen.BitRate)
		if result < 0 || len(data) == 0 {
			failStreak++
			if failStreak > 30 {
				time.Sleep(time.Second)
			}
			continue
		}
		failStreak = 0'
    substituteInPlace service/stream/mjpeg/streamer.go \
      --replace-fail 'duration := time.Second / time.Duration(120)' \
'failStreak := 0
	duration := time.Second / time.Duration(120)' \
      --replace-fail 'data, result := vision.ReadMjpeg(screen.Width, screen.Height, screen.Quality)
		if result < 0 || len(data) == 0 {
			continue
		}' \
'data, result := vision.ReadMjpeg(screen.Width, screen.Height, screen.Quality)
		if result < 0 || len(data) == 0 {
			failStreak++
			if failStreak > 30 {
				time.Sleep(time.Second)
			}
			continue
		}
		failStreak = 0'
    substituteInPlace service/stream/webrtc/manager.go \
      --replace-fail 'startTime := time.Now()' \
'startTime := time.Now()
	failStreak := 0' \
      --replace-fail 'data, result := vision.ReadH264(screen.Width, screen.Height, screen.BitRate)
		m.updateStatus(result)

		if result < 0 || len(data) == 0 {
			continue
		}' \
'data, result := vision.ReadH264(screen.Width, screen.Height, screen.BitRate)
		m.updateStatus(result)

		if result < 0 || len(data) == 0 {
			failStreak++
			if failStreak > 30 {
				time.Sleep(time.Second)
			}
			continue
		}
		failStreak = 0'

    # 8. Expose the 720p60 EDID in the UI. Our clean-room EDID set ships
    #    NanoKVM-720P60.bin (byte 12 = 0x72, installed as
    #    /kvmcomm/edid/NanoKVM-720P60.bin, but upstream's
    #    EDIDMap has no 0x72 key, so GetEdid could not name the mode and the web
    #    dropdown never offered it -- only a raw POST /api/vm/edid could select
    #    it (#62). The map value is the bin's basename, which is what SwitchEdid
    #    joins with ".bin". The web-side list entry is in
    #    web/src/pages/desktop/menu/settings/screen/edid.tsx.
    substituteInPlace service/vm/edid.go \
      --replace-fail '	0x3f: "E63-Ultrawide",' '	0x3f: "E63-Ultrawide",
	0x72: "NanoKVM-720P60",'

    # 9. H.265 direct stream (#64 web consumer, #66). Upstream already ships
    #    the pieces that cost nothing: common.ReadH265 (kvmv_read_img with
    #    IMG_H265_TYPE_SPS), STREAM_TYPE_H265_DIRECT and the "h265-direct"
    #    key in StreamTypeMap, so POST /api/stream/mode accepts the mode --
    #    but no streamer reads the channel and no route serves it. Add both:
    #    our own streamer file (parameter sets folded into each IDR message,
    #    see the file comment) and the WebSocket route next to the H.264 one.
    #    The H.264 streamer stays byte-identical.
    cp ${./nanokvm-server/direct-h265.go.in} service/stream/direct/h265.go
    substituteInPlace router/stream.go \
      --replace-fail 'api.GET("/stream/h264/direct", direct.Connect) // h264 stream (direct)' \
'api.GET("/stream/h264/direct", direct.Connect) // h264 stream (direct)
	api.GET("/stream/h265/direct", direct.ConnectH265) // h265 stream (direct, blob-free HEVC)'

    # 10. H.264 direct: fold SPS+PPS into the IDR message they precede (#68).
    #     Upstream sends each NAL as its own WebSocket message and flags only
    #     the IDR as key, so SPS and PPS travel as two non-key messages ahead
    #     of it. The upstream worker (direct.worker.ts) creates its
    #     VideoDecoder on the first KEY message and drops everything before
    #     that, so the first key chunk it decodes has no parameter sets.
    #     Chromium's H.264 decoder fails on that ("Decoding error.", zero
    #     frames, repeating every GOP -- a white screen); Firefox tolerates
    #     it. Same treatment as the H.265 streamer (step 9): hold the
    #     parameter sets and prepend them to their IDR, so every key message
    #     is self-contained and a decoder can start at any IDR. Anchors on
    #     the step-7 `failStreak := 0` line.
    substituteInPlace service/stream/direct/streamer.go \
      --replace-fail 'failStreak := 0' \
'failStreak := 0

	// SPS+PPS waiting for their IDR (see nanokvm-server.nix step 10)
	var params []byte' \
      --replace-fail 'isKeyFrame := byte(0)
		if result == 3 {
			isKeyFrame = byte(1)
		}' \
'isKeyFrame := byte(0)
		switch uint8(result) {
		case common.IMG_H264_TYPE_SPS, common.IMG_H264_TYPE_PPS:
			params = append(params, data...)
			continue
		case common.IMG_H264_TYPE_IF:
			isKeyFrame = byte(1)
			if len(params) > 0 {
				data = append(params, data...)
				params = nil
			}
		}'

    # 11. HTTP caching for the web bundle (#71). Upstream serves it with
    #     gin-contrib/static -> http.FileServer: no Cache-Control, no ETag,
    #     and a Last-Modified of 1970-01-01T00:00:01Z, because every file in
    #     the bundle is copied out of the Nix store. No explicit freshness
    #     plus a validator decades old = heuristic freshness measured in
    #     years, so an ordinary reload after a deploy or an OTA keeps the old
    #     index.html -- and therefore a mix of old and new chunks. Our handler
    #     (pkgs/nanokvm-server/web-static.go.in) keeps the same "serve it if
    #     it exists under <execdir>/web, else fall through to the API routers"
    #     gate and changes only the caching: immutable for content-hashed
    #     assets/ files, no-cache + a strong content ETag for everything else.
    cp ${./nanokvm-server/web-static.go.in} router/web_static.go
    substituteInPlace router/router.go \
      --replace-fail 'r.Use(static.Serve("/", static.LocalFile(webPath, true)))' \
                     'r.Use(serveWeb(webPath))' \
      --replace-fail '	"github.com/gin-gonic/contrib/static"
	"github.com/gin-gonic/gin"' '	"github.com/gin-gonic/gin"'

    # 12. Hand the stream type back when a consumer empties (#69). One capture
    #     channel serves MJPEG, both direct streams and WebRTC, and upstream
    #     has each of them assert the global KvmVision.StreamType on connect
    #     and never give it back -- so a second viewer in a different mode
    #     starves the first PERMANENTLY, and the WebRTC page, which hides its
    #     <video> on the resulting video-status -4, stays white long after the
    #     intruder is gone. pkgs/nanokvm-server/stream-claims.go.in (the file
    #     comment has the full rationale) arbitrates instead: consumers report
    #     their live client count, a claim still takes the stream, and a
    #     release that empties the holder passes it to whoever still has
    #     clients. Each streamer already computes that count in removeClient;
    #     addClient gets it from the same helper.
    cp ${./nanokvm-server/stream-claims.go.in} service/stream/claims.go
    substituteInPlace service/stream/direct/streamer.go \
      --replace-fail '	s.clients[ws] = true
	s.updateClientSnapshotLocked()
	s.mutex.Unlock()

	common.GetKvmVision().SetStreamType(common.STREAM_TYPE_H264_DIRECT)' \
'	s.clients[ws] = true
	count := s.updateClientSnapshotLocked()
	s.mutex.Unlock()

	stream.ClaimStreamType(common.STREAM_TYPE_H264_DIRECT, count)' \
      --replace-fail '	log.Debugf("h264 websocket disconnected, remaining clients: %d", count)' \
'	stream.ReleaseStreamType(common.STREAM_TYPE_H264_DIRECT, count)

	log.Debugf("h264 websocket disconnected, remaining clients: %d", count)'
    substituteInPlace service/stream/mjpeg/streamer.go \
      --replace-fail '	s.clients[c] = true
	s.mutex.Unlock()

	common.GetKvmVision().SetStreamType(common.STREAM_TYPE_MJPEG)' \
'	s.clients[c] = true
	added := len(s.clients)
	s.mutex.Unlock()

	stream.ClaimStreamType(common.STREAM_TYPE_MJPEG, added)' \
      --replace-fail '	log.Debugf("mjpeg connection removed, remaining clients: %d", count)' \
'	stream.ReleaseStreamType(common.STREAM_TYPE_MJPEG, count)

	log.Debugf("mjpeg connection removed, remaining clients: %d", count)'
    substituteInPlace service/stream/webrtc/manager.go \
      --replace-fail '	common.GetKvmVision().SetStreamType(common.STREAM_TYPE_H264_WEBRTC)

	log.Debugf("added client %s, total clients: %d", ws.RemoteAddr(), count)' \
'	stream.ClaimStreamType(common.STREAM_TYPE_H264_WEBRTC, count)

	log.Debugf("added client %s, total clients: %d", ws.RemoteAddr(), count)' \
      --replace-fail '	log.Debugf("removed client %s, total clients: %d", ws.RemoteAddr(), count)' \
'	stream.ReleaseStreamType(common.STREAM_TYPE_H264_WEBRTC, count)

	log.Debugf("removed client %s, total clients: %d", ws.RemoteAddr(), count)'

    # 13. Automatic updates: the checkbox, and the idle gate the reboot waits on
    #     (#86). Three surfaces, one idea -- a KVM may install an update
    #     whenever it likes, but it may only REBOOT into one when the room is
    #     empty, because it is the machine you are using to fix the machine.
    #
    #     a) /etc/kvm/auto_updates, a flag file beside upstream's
    #        preview_updates, read the same way (presence = on) by the web UI's
    #        new "Automatic updates" switch AND by `nanokvm-update`. The
    #        checkbox is the whole state; there is no NixOS option behind it.
    cp ${./nanokvm-server/auto-updates.go.in} service/application/auto_updates.go
    substituteInPlace router/application.go \
      --replace-fail '	api.POST("/application/preview", service.SetPreview) // set preview updates state' \
'	api.POST("/application/preview", service.SetPreview) // set preview updates state

	api.GET("/application/auto", service.GetAutoUpdates)  // get automatic updates state
	api.POST("/application/auto", service.SetAutoUpdates) // set automatic updates state'

    #     b) The two signals nothing upstream records: web-terminal sessions
    #        (Terminal() keeps no registry at all -- it upgrades, starts a pty
    #        and blocks) and the time of the last web request from somewhere
    #        other than loopback (CheckToken is stateless). Both live in
    #        `common`, the leaf package, so any handler can read them.
    cp ${./nanokvm-server/activity.go.in} common/activity.go
    cp ${./nanokvm-server/activity-middleware.go.in} middleware/activity.go
    substituteInPlace main.go \
      --replace-fail '	r.Use(gin.Recovery())' \
'	r.Use(gin.Recovery())

	// "somebody is using the web UI" clock, for the update reboot gate
	r.Use(middleware.RecordActivity())'

    sed -i 's|^\t"NanoKVM-Server/proto"$|\t"NanoKVM-Server/common"\n\t"NanoKVM-Server/proto"|' \
      service/vm/terminal.go
    sed -i 's|^\tgo wsWrite(ws, ptmx)$|\tcommon.TerminalOpened()\n\tdefer common.TerminalClosed()\n\n\tgo wsWrite(ws, ptmx)|' \
      service/vm/terminal.go
    grep -q 'common.TerminalOpened()' service/vm/terminal.go \
      && grep -q '"NanoKVM-Server/common"' service/vm/terminal.go \
      || { echo "ERROR: the terminal-session counter did not apply to service/vm/terminal.go" >&2; exit 1; }

    #     c) The report itself, on two routes: loopback for `nanokvm-update`
    #        (the same LocalAuth group the mini-display preview uses) and
    #        token-gated for the web UI's update page, so the machine's decision
    #        and the banner a person reads come from one computation.
    cp ${./nanokvm-server/update-status.go.in} service/ui/update_status.go
    substituteInPlace router/local.go \
      --replace-fail '	api.POST("/streamer/preview", ui.PanelPreview)' \
'	api.POST("/streamer/preview", ui.PanelPreview)
	api.GET("/update/idle", ui.GetUpdateStatus) // loopback: is anybody using the KVM?

	auth := r.Group("/api").Use(middleware.CheckToken())
	auth.GET("/application/pending", ui.GetUpdateStatus) // the same answer, for the UI'
  '';

  # cgo on for the kvm_vision + opus bindings.
  env.CGO_ENABLED = "1";
  env.GOEXPERIMENT = "boringcrypto";

  # opus for -lopus; kvm-encoder provides libkvm.so + kvm_vision.h.
  buildInputs = [
    crossPkgs.libopus
    crossPkgs.alsa-lib
    kvm-encoder
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
    # WITHOUT adding them as DT_NEEDED to the server binary. The blob-free
    # libkvm DT_NEEDEDs libasound.so.2 (its ALSA HDMI-audio path) and
    # libjpeg.so.8 (the soft-MJPEG path, #51), so ld must be able to find both
    # to validate the cgo link. On-device both come from /opt/lib, which
    # nixos/appliance.nix stages from these same builds.
    #
    # The AX graph used to be here too, because the server was linked against
    # the VENDOR-backend libkvm while the image staged the open one -- two
    # libkvms, and the closed library set in this derivation's inputs for a
    # binary that never loaded it. One libkvm now (#97): the one the appliance
    # ships, which links no vendor library at all.
    export CGO_LDFLAGS="-L$PWD/dl_lib -L${crossPkgs.libopus}/lib -Wl,-rpath-link,${crossPkgs.alsa-lib}/lib -Wl,-rpath-link,${pkgs.lib.getLib kvm-encoder.libjpeg8}/lib $CGO_LDFLAGS"
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
  # We add /opt/usr/lib (libopus.so.0) and /opt/lib because, unlike the vendor
  # server, ours DT_NEEDEDs libopus directly. Device glibc is 2.35 and our
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
