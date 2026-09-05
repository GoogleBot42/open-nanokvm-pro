# Updates & releases

How this firmware builds device images and serves its **own** over-the-air
updates — so the web UI's "update" button pulls from **our** releases instead
of Sipeed's CDN. See [architecture.md](architecture.md) for the runtime and
[building.md](building.md) for the build.

**Forge topology:** the source of truth is Gitea
([git.neet.dev/zuckerberg/open-nanokvm-pro](https://git.neet.dev/zuckerberg/open-nanokvm-pro),
Tailscale-only, locked down). A **public downstream mirror** at
[github.com/GoogleBot42/open-nanokvm-pro](https://github.com/GoogleBot42/open-nanokvm-pro)
exists solely for public distribution: it receives every branch and tag via
Gitea's push mirror, its Actions build the release assets, and its Releases
are what devices poll (public, no tailnet needed, 2 GB asset limit fits the
`.axp`). **Never create commits, tags, or edits on GitHub directly** — all
git data flows one way, Gitea → GitHub.

- [The idea](#the-idea)
- [One-time setup](#one-time-setup)
- [Cutting a release](#cutting-a-release)
- [How the device updates itself](#how-the-device-updates-itself)
- [The update protocol](#the-update-protocol)
- [Versioning](#versioning)
- [Local testing](#local-testing)
- [Caveats](#caveats)

---

> **Status: LIVE and hardware-proven.** Verified end-to-end 2026-08-15/16
> with `v2.0.0` (issue #37): Gitea tag → mirror (seconds) → tag-triggered
> workflow → all three assets published (incl. the 1.44 GB `.axp`), manifest
> served from `releases/latest/download` with a matching SHA-512 — and the
> **full-firmware OTA path was applied on the test device**: download,
> hash verify, rootfs overlay, partition writes, reboot, clean come-up on
> `2.0.0`. (The A/B *failover* path remains unexercised — see the hardware
> validation TODO below and issue #10.) Old releases `v0.0.2`–`v0.0.5`
> predate the version-line restart at `2.0.0` (see [Versioning](#versioning)).

## The idea

Stock NanoKVM-Server checks `https://cdn.sipeed.com/nanokvm/...` for updates. We
build the server **from source**, so we patch two things (in
`pkgs/nanokvm-server.nix`, applied to the pinned upstream source):

1. **The update base URL** → the public GitHub mirror's releases
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

1. **The update URL is already set.** `flake.nix` `updateBaseUrl` points at
   `https://github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download`
   (the public mirror), baked into `NanoKVM-Server` at build time. If you
   fork/move the mirror, change it there and rebuild (images built against
   the old URL keep pointing at it).
2. **Configure the Gitea push mirror** (repo Settings → Mirror on Gitea):
   target `github.com/GoogleBot42/open-nanokvm-pro`, with **tag sync** and
   ideally sync-on-commit (otherwise a cut release waits for the mirror
   interval or a manual "Synchronize now"). The mirror must push with a
   PAT/deploy-key identity — pushes from such identities trigger the GitHub
   release workflow; pushes authored by `github-actions` would not.
3. **GitHub Actions on the mirror**: enabled, with workflow permissions
   allowing `contents: write` (the default `GITHUB_TOKEN` is sufficient) so
   `release.yml` can create releases and upload assets.
4. **Flash a build that has your URL** (see
   [flashing-and-recovery.md](flashing-and-recovery.md)) so the device's update
   button targets your releases.

---

## Cutting a release

Everything starts on Gitea; GitHub only builds and hosts the assets.

**First, write the release notes:** add a `## vX.Y.Z` section to `CHANGELOG.md`
(newest first), commit, push. `cut-release` and `tools/release` both refuse to
tag a version without one, and the GitHub release workflow lifts the section
verbatim into the release description (plus a compare link to the previous
tag).

**Primary path — from the Gitea web UI:** Actions → **cut-release** → Run
workflow → enter the version (e.g. `2.0.1`). The job
(`.gitea/workflows/cut-release.yml`) validates, writes `VERSION`, commits
`release: 2.0.1`, tags `v2.0.1`, pushes, and force-moves the rolling
`preview` tag to the same commit — git work only, no nix, safe on the Gitea
runner. (A `dry_run` input validates without pushing.)

**Alpha releases:** give the version any semver prerelease suffix —
`2.1.0-alpha.1`. That single fact drives the whole split: GitHub publishes it
as a *prerelease*, which the stable channel's `releases/latest/download`
alias never serves, while the preview channel (below) picks it up
immediately. Devices with the web-UI **preview updates** toggle on get the
alpha; everyone else waits for the next stable. When `2.1.0` finally ships,
preview devices see it too (`semver.gt(2.1.0, 2.1.0-alpha.1)`) and converge
back onto stable.

**Fallback — locally:**

```bash
# (CHANGELOG.md section for v2.0.1 already committed)
echo 2.0.1 > VERSION
git commit -am "release: 2.0.1" && git push
tools/release
```

`tools/release` verifies (semver `VERSION`, clean tree, HEAD pushed, tag
free), then tags `v2.0.1` **on Gitea** and pushes the tag.

Either way, from there:

1. the Gitea push mirror replicates the commit + tag to GitHub
   (`tools/release` polls the public API until the tag appears);
2. `.github/workflows/release.yml` fires on the mirrored tag, checks
   `VERSION` == tag (it never writes or commits anything — the mirror must
   stay one-way), builds `.#update-package` and `.#firmware-image`, and
   publishes the GitHub Release (marked *prerelease* for alpha versions)
   with:
   - `nanokvm_pro_latest.json` (manifest),
   - `nanokvm_pro_2.0.0.tar.gz` (OTA payload),
   - `AX630C_..._sipeed_nanokvm-selfbuilt.axp` (device image, uploaded
     separately with retries — GitHub's large-asset path is flaky);
3. the same run refreshes the **rolling `preview` release** (fixed tag
   `preview`, moved by cut-release; assets clobbered, stale payloads
   pruned) — the fixed URL the preview channel polls.

Once the release is published, every device on an older version sees the
update in the web UI. A failed run is recovered by re-running it from the
Actions tab (the job is idempotent); never fix a release by pushing to
GitHub.

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
| `/lib/modules/4.19.125/` (from-source modules only, pre-`depmod`'d) | env (p7), logo (p10/11) |
| `/soc/scripts/auto_load_all_drv.sh` — our `/soc/ko` loader (three from-source modules, zero vendor blobs, #55 M3; no rollback copies ship any more, #54) **and** the three modules themselves (`ax630c_venc_vcmd.ko`, `open_vin_csi2.ko`, `open_vin_capture.ko`); takes effect on the **next reboot** — the installer forces one when the loader changed | **deletions** — the #54 purge of the vendor `/soc/ko` blobs, `libsns_*.so`, NPU model data and ISP tuning set |
| `/opt/scripts/wifi.sh` — the vendor script with its `insmod`/`rmmod /soc/ko/aic8800_*.ko` lines rewritten to `modprobe`/`modprobe -r` (#54) | |
| kernel (p14/p15), dtb (p12/p13) | base Ubuntu rootfs (p17) |
| U-Boot (p5/p6), ATF (p3/p4), OP-TEE (p10/p11) | repartitioning / GPT layout |

So an OTA can now roll forward the entire runtime **and** the boot chain; only the
first-stage loader, the base filesystem, and the partition table remain AXDL-only.

**An OTA only overlays files — it never deletes.** The blob purges done in the
image build (`libax_*.so` in #25, the vendor `ax_*.ko` / `libsns_*.so` / NPU
model data / ISP tuning set in #54) therefore reach an OTA-upgraded device only
on a reflash. Nothing loads or links them there, so this is dead weight, not a
functional difference.

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
shipped modules' `vermagic` (both `lt6911_manage.ko` and the open
`ax630c_venc_vcmd.ko`) matches the `4.19.125` modules directory, and
`modules.dep` resolves `lt6911_manage`.

> **Preview channel — wired (issues #19/#4).** The web UI's *preview updates*
> toggle (flag file `/etc/kvm/preview_updates`) switches the update check to
> `PreviewURL`, which our build points at the **rolling `preview` release**
> (`flake.nix` `previewUpdateBaseUrl` →
> `releases/download/preview/nanokvm_pro_latest.json`) instead of the
> vendor-derived `<stable>/preview` sub-path — impossible on GitHub's flat
> release-asset namespace, which used to make the toggle silently break
> update checks. The rolling release tracks the most recently cut release of
> either kind, so the toggle means: get alphas as soon as they're cut.

---

## Versioning

- The device's installed version is `/kvmapp/version`; the manifest offers an
  update only when its `version` is **semver-greater** (`semver.gt`).
- The version comes from the tracked `./VERSION` file — the single source of
  truth. `tools/release` refuses to run unless it is semver and untagged, and
  tags `v<VERSION>` on Gitea; the GitHub workflow independently re-checks
  `VERSION` == tag and fails the build on drift. (A malformed `VERSION` makes
  the flake fall back to `0.0.0-dev`.)
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
  controls what the device installs (it runs as root). **GitHub Releases over
  TLS is the trust boundary** — note that's the *mirror*, not the Gitea source
  of truth, so both the GitHub repo's write access and the mirror credential
  matter. (Signed OTA — which would collapse that boundary back to the signing
  key — is issue #31.)
- **CI cost/disk.** The `.axp` build cross-compiles the kernel + boot chain and
  de-sparses a multi-GB rootfs; on a stock GitHub runner it is slow (~2 h,
  uncached) and disk-tight (the workflow frees space first). Consider a binary
  cache if it gets painful. The `update-package` alone is small and fast.
- **Mirrored-tag trigger.** The release workflow fires only if the mirror's
  pushes come from a PAT/deploy-key identity. If a tag lands on GitHub and no
  run starts, check the mirror's auth identity before anything else.
- **kvmadmin / AI-assistant extensions.** Our build **removes** their backend
  routes (`pkgs/nanokvm-server.nix` rewrites `router/extensions.go` to register
  only the Tailscale routes — they fetched closed third-party code from
  `cdn.sipeed.com`, see [provenance.md](provenance.md)), and the web UI panels
  for them are removed in our web fork (`web/`, commit "remove the KVM Admin
  and AI Assistant panels").
  Unrelated to the web-UI "update" button.
- **URL is baked in.** `updateBaseUrl` is compiled into the server. Changing where
  you host means a rebuild + re-flash (or a new OTA that carries the new binary).
