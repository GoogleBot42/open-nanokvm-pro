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
| `/lib/modules/4.19.125/` (our modules + `ax_*.ko`, pre-`depmod`'d) | env (p7), logo (p10/11) |
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
