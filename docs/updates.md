# Updates & releases

How this firmware builds device images and serves its **own** over-the-air
updates — so the web UI's "update" button pulls from **our** GitHub Releases
instead of Sipeed's CDN. See [architecture.md](architecture.md) for the runtime
and [building.md](building.md) for the build.

- [The idea](#the-idea)
- [One-time setup](#one-time-setup)
- [Cutting a release](#cutting-a-release)
- [How the device updates itself](#how-the-device-updates-itself)
- [The update protocol](#the-update-protocol)
- [Versioning](#versioning)
- [Local testing](#local-testing)
- [Caveats](#caveats)

---

## The idea

Stock NanoKVM-Server checks `https://cdn.sipeed.com/nanokvm/...` for updates. We
build the server **from source**, so we patch two things (in
`pkgs/nanokvm-server.nix`, applied to the pinned upstream source):

1. **The update base URL** → our GitHub Releases
   (`flake.nix` `updateBaseUrl`). `releases/latest/download/<name>` always
   resolves to the newest release's assets, so the manifest URL is stable.
2. **The apply step** → instead of the vendor's three-`.deb` + `dpkg -i` flow, our
   `install()` (see `pkgs/nanokvm-server/install-override.go.in`) unpacks a plain
   tarball over `/kvmapp` and restarts the service. No dpkg, no package-ownership
   conflicts with the from-source rootfs.

Everything else in the vendor update path — manifest fetch, SHA-512 verification,
WebSocket progress, the web UI, the client-side semver check — is untouched.

Two Nix outputs feed a release:

| Output | What it is | Published as |
|---|---|---|
| `firmware-image` | the flashable `.axp` device image | Release asset (flash via AXDL) |
| `update-package` | `nanokvm_pro_<ver>.tar.gz` + `nanokvm_pro_latest.json` | Release assets (the OTA payload + manifest) |

Publishing a release **is** the OTA push.

---

## One-time setup

1. **Create the GitHub repo** that hosts the code + Releases, and push this flake
   to it. This project targets
   [`GoogleBot42/open-nanokvm-pro`](https://github.com/GoogleBot42/open-nanokvm-pro).
2. **The update URL is already set.** `flake.nix` `updateBaseUrl` points at
   `https://github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download`,
   baked into `NanoKVM-Server` at build time. If you fork/move the repo, change it
   there and rebuild (images built against the old URL keep pointing at it).
3. **Actions permissions.** The workflow needs `contents: write` (already declared
   in `.github/workflows/release.yml`). Ensure Settings → Actions → Workflow
   permissions allows it (default `GITHUB_TOKEN` is sufficient).
4. **Flash a build that has your URL** (see
   [flashing-and-recovery.md](flashing-and-recovery.md)) so the device's update
   button targets your releases.

---

## Cutting a release

Tag and push:

```bash
git tag v2.0.0
git push origin v2.0.0
```

`.github/workflows/release.yml` then:

1. writes `2.0.0` into `VERSION` (so the flake stamps `/kvmapp/version` and the
   manifest),
2. `nix build .#update-package .#firmware-image`,
3. creates the GitHub Release `v2.0.0` and uploads:
   - `AX630C_..._sipeed_nanokvm-selfbuilt.axp` (device image),
   - `nanokvm_pro_2.0.0.tar.gz` (OTA payload),
   - `nanokvm_pro_latest.json` (manifest).

You can also run it manually from the Actions tab (`workflow_dispatch`) with an
explicit version.

Once the release is published, every device on an older version sees the update
in the web UI.

---

## How the device updates itself

```
web UI "check"  ─► GET /api/application/version (server)
                     └─► GET releases/latest/download/nanokvm_pro_latest.json
                          └─► {version, name, sha512, size}
web UI compares  ─► semver.gt(latest, /kvmapp/version)?  → offer "update"
user clicks      ─► POST /api/application/update (server)
   server        ─► download releases/latest/download/<name>   (WS progress)
                 ─► verify base64 SHA-512 == manifest.sha512
                 ─► untar; cp -a <dir>/kvmapp/. /kvmapp/
                 ─► write /kvmapp/version; systemctl --no-block restart nanokvm
   nanokvm.service restart ─► ExecStartPre copies /kvmapp → /dev/shm/kvmapp
                            ─► supervisor relaunches the new NanoKVM-Server
web UI           ─► reloads after ~20 s
```

The payload contains only the app tree (`server/NanoKVM-Server`, `server/web/`,
`server/dl_lib/libkvm.so{,.0}`, `version`) — the boot chain, kernel, and modules
are **not** touched by an OTA. Those ship only in the `.axp` and change only by
re-flashing.

---

## The update protocol

The contract our `update-package` must honour for an (unmodified-mechanism)
NanoKVM-Server to accept it:

- **Manifest** `nanokvm_pro_latest.json`:
  ```json
  { "version": "2.0.0", "name": "nanokvm_pro_2.0.0.tar.gz",
    "sha512": "<base64(StdEncoding) of the RAW SHA-512 of the tarball>", "size": 12418564 }
  ```
  `sha512` is base64 of the raw digest, **not** hex — the server enforces it.
  `size` is informational.
- **Payload** `nanokvm_pro_<ver>.tar.gz`: a single top-level dir
  `nanokvm_pro_<ver>/` containing `kvmapp/…`. The server's `UnTarGz` returns that
  dir; our `install()` copies `<dir>/kvmapp/.` over `/kvmapp`.

Both are produced deterministically by `pkgs/update-package.nix`.

> **Preview channel:** the vendor supports a `preview` channel gated by the file
> `/etc/kvm/preview_updates`; our base URL keeps a `/preview` sub-path but it is
> not wired for the Releases-only layout. Leave the flag file absent (default).

---

## Versioning

- The device's installed version is `/kvmapp/version`; the manifest offers an
  update only when its `version` is **semver-greater** (`semver.gt`).
- The version comes from the tracked `./VERSION` file; CI overwrites it with the
  tag (`vX.Y.Z` → `X.Y.Z`). Local untagged builds default to `0.0.0-dev`.
- Vendor stock devices report `1.2.x`. Start our line at **`2.0.0`** so our
  releases are unambiguously newer than any stock image, and bump semver from
  there.

---

## Local testing

Build and inspect the artifacts without a release:

```bash
nix build .#update-package
cat result/nanokvm_pro_latest.json
tar tzf result/*.tar.gz | head

# verify the manifest hash matches (what the device checks):
openssl dgst -sha512 -binary result/*.tar.gz | base64 -w0
```

To exercise the full round-trip before trusting CI, serve `result/` over HTTPS
from a host the device trusts and temporarily point a test build's
`updateBaseUrl` at it, then click "update" in the web UI. (Plain HTTP / untrusted
TLS won't work — the server uses `https://` and verifies the certificate.)

---

## Caveats

- **No signature, only a hash.** The tarball is gated by a SHA-512 that comes from
  your own manifest — integrity, not authenticity. Whoever serves the manifest
  controls what the device installs (it runs as root). GitHub Releases over TLS is
  the trust boundary; keep the repo's write access tight.
- **CI cost/disk.** The `.axp` build cross-compiles the kernel + boot chain and
  de-sparses a multi-GB rootfs; on a stock GitHub runner it is slow and
  disk-tight (the workflow frees space first). Consider a binary cache (Cachix) or
  a larger/self-hosted runner if it gets painful. The `update-package` alone is
  small and fast.
- **kvmadmin extension.** The optional `kvmadmin`/Tailscale-admin helper still
  downloads from `cdn.sipeed.com/nanokvm/resources/` (a separate code path from
  the app update). It is unrelated to the web-UI "update" button; redirect it too
  if you use that feature.
- **URL is baked in.** `updateBaseUrl` is compiled into the server. Changing where
  you host means a rebuild + re-flash (or a new OTA that carries the new binary).
