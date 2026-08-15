# Updates & releases

How this firmware builds device images and serves its **own** over-the-air
updates — so the web UI's "update" button pulls from **our** Gitea releases
([git.neet.dev/zuckerberg/open-nanokvm-pro](https://git.neet.dev/zuckerberg/open-nanokvm-pro))
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

> **Status: no Gitea release has been cut yet**, so the update button has
> nothing to find until the first `tools/release` run. Two constraints gate a
> *usable* OTA (both tracked in issue #37):
>
> - **Reachability.** git.neet.dev is Tailscale-only and the device is not on
>   the tailnet (verified 2026-08-15: DNS resolves to the tailnet address,
>   connection times out). Until the device can reach the forge — tailnet
>   enrollment or a public release path — OTA checks fail silently (the UI
>   just reports "up to date").
> - **`.axp` size.** The flashable image (~1.4 GB) exceeds the server's
>   attachment limit (`[attachment] MAX_SIZE`, currently 1024 MB), so
>   releases carry it only once that limit is raised. OTA itself is
>   unaffected — the payload tarball is ~30 MB.
>
> The old GitHub pipeline (releases `v0.0.2`–`v0.0.5` at
> `github.com/GoogleBot42/open-nanokvm-pro`) is retired; the version line
> restarts at `2.0.0` per [Versioning](#versioning).

## The idea

Stock NanoKVM-Server checks `https://cdn.sipeed.com/nanokvm/...` for updates. We
build the server **from source**, so we patch two things (in
`pkgs/nanokvm-server.nix`, applied to the pinned upstream source):

1. **The update base URL** → our Gitea releases (`flake.nix` `updateBaseUrl`).
   Gitea has no GitHub-style `releases/latest/download` route, so the URL
   targets `releases/download/latest` — a **rolling release tagged `latest`**
   whose assets `tools/release` replaces on every cut. The manifest URL stays
   stable; the tag moves.
2. **The apply step** → instead of the vendor's three-`.deb` + `dpkg -i` flow, our
   `install()` (see `pkgs/nanokvm-server/install-override.go.in`) applies a
   **full-firmware** payload: a `rootfs/` overlay copied over `/` (app + web +
   libkvm + the whole kernel-modules tree) plus, optionally, signed A/B
   **partition** images for the boot chain, kernel and dtb. No dpkg, no
   package-ownership conflicts with the from-source rootfs.

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

1. **The repo and update URL are already set.** The forge is
   [`zuckerberg/open-nanokvm-pro` on git.neet.dev](https://git.neet.dev/zuckerberg/open-nanokvm-pro);
   `flake.nix` `updateBaseUrl` points at
   `https://git.neet.dev/zuckerberg/open-nanokvm-pro/releases/download/latest`,
   baked into `NanoKVM-Server` at build time. If you fork/move the repo, change
   it there and rebuild (images built against the old URL keep pointing at it).
2. **A Gitea token** with release (repo) scope, either as `GITEA_TOKEN` or via a
   logged-in `tea` CLI (`tools/release` reads either).
3. **Flash a build that has your URL** (see
   [flashing-and-recovery.md](flashing-and-recovery.md)) so the device's update
   button targets your releases — and make sure the device can actually reach
   the forge host (see the status note above).

---

## Cutting a release

Bump the version, push, and run the release script from the repo root:

```bash
echo 2.0.0 > VERSION
git commit -am "release: 2.0.0" && git push
tools/release          # add --no-axp to skip the 1.4 GB flashable image
```

`tools/release`:

1. sanity-checks (semver `VERSION`, clean tree, HEAD pushed, tag free),
2. `nix build .#update-package` (and `.#firmware-image` unless `--no-axp`),
3. cross-checks the built manifest against `VERSION`,
4. publishes the archival release `v2.0.0` with all assets:
   - `nanokvm_pro_latest.json` (manifest),
   - `nanokvm_pro_2.0.0.tar.gz` (OTA payload),
   - `AX630C_..._sipeed_nanokvm-selfbuilt.axp` (device image, when it fits —
     see the status note),
5. refreshes the rolling **`latest`** release (deletes and re-creates the
   `latest` tag+release with the new manifest + payload), and
6. fetches the device-facing manifest URL back and verifies it byte-for-byte.

Once `latest` is refreshed, every device on an older version that can reach the
forge sees the update in the web UI.

**Why not CI?** Gitea Actions is enabled and a runner exists, but a release
build on it currently rebuilds the whole aarch64 cross-toolchain from scratch
(no binary cache) and nix runs unsandboxed in the runner container (the
run dies on the `/homeless-shelter` purity check — see actions run #6).
A release from a warm local nix store takes minutes instead of hours;
CI releases can return with the binary-cache work tracked in issue #5.

---

## How the device updates itself

```
web UI "check"  ─► GET /api/application/version (server)
                     └─► GET releases/download/latest/nanokvm_pro_latest.json
                          └─► {version, name, sha512, size}
web UI compares  ─► semver.gt(latest, /kvmapp/version)?  → offer "update"
user clicks      ─► POST /api/application/update (server)
   server        ─► download releases/download/latest/<name>   (WS progress)
                 ─► verify base64 SHA-512 == manifest.sha512
                 ─► untar → install(dir):
                       1. cp -a <dir>/rootfs/. /            (app+web+libkvm+modules)
                       2. if <dir>/partitions/: write BOTH slots (B first, then A),
                          compare-first, dd oflag=direct + read-back verify
                       3. write /kvmapp/version
                       4. any partition written? systemctl --no-block reboot
                          else                    systemctl --no-block restart nanokvm
   app-only update ─► ExecStartPre copies /kvmapp → /dev/shm/kvmapp, relaunches server
   full update     ─► reboot; new boot chain / kernel / dtb take effect
web UI           ─► reconnects after the restart / reboot
```

### What a full OTA now covers

| Shipped by OTA (`rootfs/` + `partitions/`) | AXDL-only (re-flash the `.axp`) |
|---|---|
| app server, web UI, `libkvm.so{,.0}` | SPL (p1), ddrinit (p2) |
| `/lib/modules/4.19.125/` (from-source modules only, pre-`depmod`'d; `ax_*.ko` stay in `/soc/ko`) | env (p7), logo (p10/11) |
| kernel (p14/p15), dtb (p12/p13) | base Ubuntu rootfs (p17) |
| U-Boot (p5/p6), ATF (p3/p4), OP-TEE (p8/p9) | repartitioning / GPT layout |

So an OTA can now roll forward the entire runtime **and** the boot chain; only the
first-stage loader, the base filesystem, and the partition table remain AXDL-only.

### Dual-slot write strategy (why it is power-cut-safe)

The A/B partition layout carries two copies of the U-Boot/ATF/OP-TEE trio and of
the kernel/dtb. `install()` writes them in **strict slot order — every B-slot
target first, then every A-slot target** — and each target is written completely
(`dd oflag=direct conv=fsync`) and read back + `cmp`-verified before moving on.

Because one whole slot is finished before the other is touched, **at every instant
at least one slot is fully self-consistent.** If power is cut mid-update:

- The SPL picks the U-Boot/ATF/OP-TEE slot from a hardware register
  (`TOP_CHIPMODE_GLB_BACKUP0`), verifies each stage's header magic + checksums,
  and on a bad load hangs so the watchdog resets and the register flips to the
  other slot — genuine passive failover.
- **`CONFIG_SUPPORT_AB` is now enabled** in our U-Boot (`pkgs/boot.nix`), so U-Boot
  follows that same slot register for the kernel/dtb pair (`bootsystem` env →
  `kernel_b`/`dtb_b`). Without it U-Boot would always read slot-A kernel/dtb and
  the failover could never complete. (The vendor `project.mak` also derives this
  from `AX_SUPPORT_AB_PART=TRUE` via `config2defconfig.py`; we set it explicitly so
  the guarantee cannot silently lapse.)

No slot-register manipulation is done or wanted — the update just writes both
slots and lets the SPL/U-Boot verification + watchdog machinery choose a good one.

### Idempotency and the app-only fast path

Each partition write is **compare-first**: `install()` reads the current slot
(`iflag=direct`, bypassing the page cache) and skips the write if it already
matches the image. Re-running the same update is a no-op on the partitions.

`partitions/` is **optional**. A release that changes only the app/web/modules
ships just `rootfs/`; `install()` then does the overlay + version stamp and a plain
`systemctl --no-block restart nanokvm` — **no reboot**. A reboot happens only when
a boot-chain/kernel/dtb partition actually changed.

> **Hardware validation TODO.** The SPL→U-Boot slot-B failover path has been
> reasoned from source but **not yet exercised on hardware**. Before trusting
> rollback, deliberately corrupt one slot (or write a known-bad kernel to
> `kernel_b`) on a test unit and confirm the device fails over to the good slot and
> recovers. Until then, treat dual-slot writes as belt-and-suspenders, not a proven
> rollback guarantee.

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
  `nanokvm_pro_<ver>/` containing:
  - `rootfs/` — copied verbatim over `/`
    (`kvmapp/server/{NanoKVM-Server,web/…,dl_lib/libkvm.so{,.0}}`, `kvmapp/version`,
    `lib/modules/4.19.125/…`);
  - `partitions/` *(optional)* — vendor-format signed images with a fixed naming
    contract: `uboot_a.img`, `uboot_b.img`, `atf_a.img`, `atf_b.img`, `optee.img`,
    `dtb.img`, `kernel.img` (each carries header magic `0x55543322` at offset 4).

  The server's `UnTarGz` returns that dir; our `install()` consumes `<dir>/rootfs`
  and `<dir>/partitions`.

Both are produced deterministically by `pkgs/update-package.nix`, which also
asserts at build time: every `partitions/` image has the boot-header magic, the
shipped modules' `vermagic` matches the `4.19.125` modules directory, and
`modules.dep` resolves `ax_venc`/`lt6911_manage`.

> **Preview channel:** the vendor supports a `preview` channel gated by the file
> `/etc/kvm/preview_updates`; our base URL keeps a `/preview` sub-path but it is
> not wired for the Releases-only layout. Leave the flag file absent (default).

---

## Versioning

- The device's installed version is `/kvmapp/version`; the manifest offers an
  update only when its `version` is **semver-greater** (`semver.gt`).
- The version comes from the tracked `./VERSION` file — the single source of
  truth. `tools/release` refuses to run unless it is semver and untagged, and
  tags the release `v<VERSION>`. (A malformed `VERSION` makes the flake fall
  back to `0.0.0-dev`.)
- Vendor stock devices report `1.2.x`, and the old GitHub pipeline cut
  `0.0.2`–`0.0.5` — versions a `1.2.x` device would never accept
  (`semver.gt` fails). The line therefore restarts at **`2.0.0`** (the
  current `VERSION`), unambiguously newer than any stock image; bump semver
  from there.

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
  controls what the device installs (it runs as root). Gitea releases over TLS
  are the trust boundary; keep the repo's write access tight. (Signed OTA is
  issue #31.)
- **Build cost.** The `.axp` build cross-compiles the kernel + boot chain and
  de-sparses a multi-GB rootfs — run `tools/release` from a machine with a warm
  nix store. The `update-package` alone is small and fast.
- **kvmadmin / AI-assistant extensions.** Our build **removes** their backend
  routes (`pkgs/nanokvm-server.nix` rewrites `router/extensions.go` to register
  only the Tailscale routes — they fetched closed third-party code from
  `cdn.sipeed.com`, see [provenance.md](provenance.md)), and the web UI panels
  for them are patched out (`pkgs/patches/web-remove-dead-extensions.patch`).
  Unrelated to the web-UI "update" button.
- **URL is baked in.** `updateBaseUrl` is compiled into the server. Changing where
  you host means a rebuild + re-flash (or a new OTA that carries the new binary).
