# Updates & releases

How this firmware publishes its own updates and how a device installs them, so
the web UI's "update" button pulls from **our** releases and a bad update rolls
itself back. See [architecture.md](architecture.md) for the runtime,
[nixos-rootfs.md](nixos-rootfs.md) for the appliance and
[mainline-port.md](mainline-port.md) for the boot chain.

**Forge topology:** the source of truth is Gitea
([git.neet.dev/zuckerberg/open-nanokvm-pro](https://git.neet.dev/zuckerberg/open-nanokvm-pro),
Tailscale-only, locked down). A **public downstream mirror** at
[github.com/GoogleBot42/open-nanokvm-pro](https://github.com/GoogleBot42/open-nanokvm-pro)
exists solely for public distribution: it receives every branch and tag via
Gitea's push mirror, its Actions build the release assets, and its Releases are
what devices poll (public, no tailnet needed). **Never create commits, tags, or
edits on GitHub directly** — all git data flows one way, Gitea → GitHub.

- [The idea](#the-idea)
- [The system bundle](#the-system-bundle)
- [How the device installs one](#how-the-device-installs-one)
- [Rollback, including the kernel](#rollback-including-the-kernel)
- [Garbage collection without nix](#garbage-collection-without-nix)
- [Cutting a release](#cutting-a-release)
- [Local testing](#local-testing)
- [Weighed and rejected](#weighed-and-rejected)
- [Caveats](#caveats)
- [History: the 4.19 overlay OTA](#history-the-419-overlay-ota)

---

> **Status (2026-09-10, #86): built and proven offline; not yet run on
> hardware.** Two `nix flake check` gates cover the whole loop —
> `nanokvm-updater-loop` applies a real bundle to a fake root with the real
> scripts, and `nanokvm-system-bundle` reads the published artefact back
> against the closure it claims. What is unproven is everything that needs the
> board: `switch-to-configuration`, the `/nix/store` remount, and whether
> U-Boot boots what the updater wrote. See
> [the hardware plan](#what-hardware-still-has-to-prove).

## The idea

The appliance is a **NixOS system with no `nix` on it**
([nixos-rootfs.md](nixos-rootfs.md)): the rootfs is a fixed store closure the
build host produced, which is what keeps the image small and the running system
exactly what the flake describes. So an update cannot be a `nixos-rebuild`, and
since #78 it cannot be a file overlay either — there are no files to overlay,
only store paths.

An update is therefore a **system bundle**: the new toplevel's entire closure,
the kernel that closure's stage-1 initrd is baked into, and a list saying which
store paths belong to it. The device unpacks what it does not already have,
points the system profile at the new toplevel, writes the kernel into `/boot`,
and reboots.

**The reboot is the mechanism, not an afterthought.** The generation is
installed with `switch-to-configuration boot`, so nothing about it is live until
the board restarts; the restart is counted by U-Boot's `bootcount`, and
`nanokvm-mark-good` clears that counter only once the **new** system is running,
routed and serving. A generation that does not come up healthy is rolled back by
`altbootcmd` on the fourth attempt with nobody watching — which is the only
rollback story a box with no console and no autoboot interrupt window can have.
`switch` would activate an untested userspace with no way back, and is never
used.

Two Nix outputs feed a release:

| Output | What it is | Published as |
|---|---|---|
| `system-bundle` | `nanokvm_pro_sys_<ver>.tar.gz` + `nanokvm_pro_sys_latest.json` | the update payload + the manifest devices poll |
| `nixos-firmware-image-mainline` | the flashable `.axp` | the AXDL image — the only way onto a board that is not already running this |

Publishing a release **is** the update push.

---

## The system bundle

`pkgs/system-bundle.nix`. Two files, and their shape is the vendor OTA's on
purpose — the server's download path (fetch the manifest, fetch `name`, check
the base64 SHA-512, untar) is reused byte for byte, so the web UI's update
button needed no change at all.

**The manifest** `nanokvm_pro_sys_latest.json`:

```json
{ "version": "2.1.0", "name": "nanokvm_pro_sys_2.1.0.tar.gz",
  "sha512": "<base64(StdEncoding) of the RAW SHA-512 of the tarball>",
  "size": 459778288 }
```

`sha512` is base64 of the raw digest, **not** hex — the server enforces it.

**The payload**, one top-level directory `nanokvm_pro_sys_<ver>/`, which is what
the server's `UnTarGz` hands to `install()`:

```
MANIFEST.json     format, version, toplevel, boot payload + sha256s
closure.txt       every store path in the toplevel's closure, one per line
store/<base>/     those store paths, as ordinary directories
boot/Image-<h>    the kernel, content-addressed
boot/<dtb>        its device tree, likewise
```

**The manifest FILENAME is the channel.** `nanokvm_pro_sys_latest.json` is the
appliance's; the 4.19 image polls `nanokvm_pro_latest.json`, which nothing
publishes any more. A device is therefore never offered a payload its installer
cannot apply. `pkgs/nanokvm-server.nix`'s `updateMode` picks both the manifest
name and the `install()` body, and they move together.

**`--hard-dereference` is load-bearing.** The server's own extractor
(`server/utils/untar.go`) handles `TypeDir`, `TypeReg` and `TypeSymlink` and
**silently ignores `TypeLink`**. A tar that hardlinked two identical files in
the closure would install one and leave the other missing, with no error
anywhere and a generation that dies on a file that is not there. The bundle
build dereferences them and then asserts the finished archive has no `h`
entries.

**It is ~460 MB** (690 store paths, 1.3 GB of content) and that is the honest
cost of the design — see [Weighed and rejected](#weighed-and-rejected). The
device only *writes* the paths it does not already have, so the eMMC cost is
proportional to the change even though the download is not.

---

## How the device installs one

`nanokvm-update` (`nixos/lib/updater.nix`) is the whole implementation, and it
has two callers:

- **the web UI button** → `POST /api/application/update` → the server downloads,
  SHA-512-verifies and untars, then our `install()`
  (`pkgs/nanokvm-server/install-bundle.go.in`) runs
  `nanokvm-update install-staged <dir>` and reboots;
- **the timer** → `nanokvm-update update` does the whole cycle itself
  (`nanokvm.update.auto`, off by default — a KVM that reboots on its own
  schedule is a surprise in the middle of someone's console session).

```
nanokvm-update update
  ├─ refuse if `bootcount` != 0xB0010000     this boot is not marked good yet;
  │                                          installing now would replace the
  │                                          very thing the counter is counting
  ├─ GET <base>/nanokvm_pro_sys_latest.json  (<base> is the preview channel if
  │                                          /etc/kvm/preview_updates exists)
  ├─ compare with /run/current-system/etc/nanokvm-version
  ├─ download, verify base64 SHA-512, untar
  └─ install-staged:
      1. check EVERY closure path is installed or in the bundle   ← before any write
      2. remount /nix/store rw, rename the missing ones in, remount bind,ro
      3. record closure.txt as /var/lib/nanokvm/closures/<toplevel>.txt
      4. write /boot/Image-<h> + the dtb, verify each from the file
      5. profile: system-<N+1>-link -> toplevel, then rename `system` onto it
      6. note the kernel in /run/nanokvm-pending-boot
      7. switch-to-configuration boot   → nanokvm-install-boot writes
                                          /boot/extlinux/extlinux.conf naming
                                          THIS generation and THIS kernel
      8. reboot
```

Three details that are not obvious:

- **The version stamp is part of the closure.** `/etc/nanokvm-version` is a
  store file, so a rollback rolls the version back with everything else and
  there is no mutable stamp to get out of sync. (The web UI reads
  `/kvmapp/version`, which is likewise a store symlink.)
- **The paths are *renamed* into the store, not copied.** `/root/.kvmcache` and
  `/nix/store` are the same filesystem, so unpacking costs one write of the
  closure, not two.
- **`/nix/store` is a read-only bind mount**, and `remount,ro` alone silently
  does nothing on a bind — it needs `remount,bind,ro`.

---

## Rollback, including the kernel

The generation half has been live since #89 rung 5 and is described in
[nixos-rootfs.md §4b](nixos-rootfs.md#4b-rollback--two-config-files-a-register-and-a-health-gate):
two files in `/boot`, `extlinux.conf` and `extlinux-fallback.conf`, chosen by
U-Boot's `bootcmd` and `altbootcmd`, with `bootcount` in `0x02390030` and
`bootlimit` 3.

**#86 closes the kernel half.** Until now both configs named one `/boot/Image`,
so the two entries could name two generations but never two kernels, and a
kernel change had no automatic fallback — `/boot/Image.prev` was a manual
stand-in. Now:

- `pkgs/boot-payload.nix` names each kernel `Image-<16 hex of its sha256>` and
  each device tree `<name>-<hash>.dtb`;
- the extlinux template carries `@KERNEL@`/`@FDT@` beside `@INIT@`, and
  `nanokvm-install-boot` substitutes all three, so a config names a
  **(generation, kernel) pair**;
- an update writes its kernel under a name nothing else uses, so the two
  coexist;
- **the APPEND line carries `nanokvmboot=<kernel>,<fdt>`**, because `sysboot`
  loads LINUX and FDT and then tells the kernel nothing about which files they
  were. That token is how a running system knows which kernel booted it, and it
  is honest precisely because U-Boot copied it out of whichever config it chose;
- `nanokvm-mark-good` regenerates the fallback from `/run/booted-system` **and**
  that token, so it promotes the pair that actually proved itself, and then
  deletes the `/boot` files neither config names.

`/boot` is 272 MiB and the kernel is 48.9 MiB, so it holds the running kernel,
the fallback kernel and an incoming third with room to spare; `pkgs/bootfs.nix`
asserts that at build time rather than letting a future kernel quietly fill the
partition.

**To exercise the rollback, do not install a broken generation.** Force the
counter instead — one boot, nothing to strand:

```sh
devmem 0x02390030 32 0xB001000A
reboot
```

---

## Garbage collection without nix

`nanokvm-gc` keeps `nanokvm.update.keepGenerations` (default 3) generations and
deletes the store paths no kept generation needs.

The problem it has to solve is that **nothing on the device can recompute a
closure**. So every generation's closure list is recorded when it is installed
(`/var/lib/nanokvm/closures/<toplevel basename>.txt`), and the image builder
writes the flashed generation's list into `/var` so the very first one is not a
blind spot. On top of `keepGenerations`, four things are always kept: the
profile's target, `/run/booted-system`, `/run/current-system`, and **both**
generations the extlinux configs name — the fallback most of all, since it is
the one that gets used exactly when the default does not work.

**If any kept generation has no closure list, `nanokvm-gc` deletes nothing at
all** and says so. An unknown live set makes every deletion a guess; a store
that is too full is recoverable, a store missing one path is a bench trip.

---

## Cutting a release

Unchanged in shape from the 4.19 days. Everything starts on Gitea; GitHub only
builds and hosts the assets.

**First, write the release notes:** add a `## vX.Y.Z` section to `CHANGELOG.md`
(newest first), commit, push. `cut-release` and `tools/release` both refuse to
tag a version without one, and the GitHub release workflow lifts the section
verbatim into the release description.

**Primary path — the `cut-release` workflow on Gitea.** Actions →
**cut-release** → Run workflow → enter the version (e.g. `2.1.0`). The job
(`.gitea/workflows/cut-release.yml`) validates, writes `VERSION`, commits, tags,
pushes, and force-moves the rolling `preview` tag to the same commit — git work
only, no nix. A `dry_run` input validates without pushing.

The same workflow is dispatchable over the API, which is how an agent cuts a
release without a browser. Always dry-run first:

```bash
TOK=$(grep -o 'token: .*' ~/.config/tea/config.yml | head -1 | cut -d' ' -f2)
curl -X POST -H "Authorization: token $TOK" -H 'Content-Type: application/json' \
  -d '{"ref":"main","inputs":{"version":"2.2.0","dry_run":"true"}}' \
  https://git.neet.dev/api/v1/repos/zuckerberg/open-nanokvm-pro/actions/workflows/cut-release.yml/dispatches
```

**204 means accepted, not succeeded.** Poll
`/api/v1/repos/zuckerberg/open-nanokvm-pro/actions/tasks?limit=1` for the run's
`status` and `conclusion`, then re-dispatch with `dry_run` `"false"`. The
booleans are passed as **strings**; a JSON boolean is rejected.

**Alpha releases:** any semver prerelease suffix — `2.2.0-alpha.1` — makes
GitHub publish it as a *prerelease*, which the stable channel's
`releases/latest/download` alias never serves, while the rolling `preview`
release picks it up immediately. Devices with the web-UI **preview updates**
toggle on (`/etc/kvm/preview_updates`) get it; everyone else waits. Both the
server and `nanokvm-update` read that same flag file, so the button and the
timer can never install from different channels.

**Fallback — locally:** `echo 2.2.0 > VERSION`, commit, push, `tools/release`.

From there: the push mirror replicates the commit + tag to GitHub, and
`.github/workflows/release.yml` fires on the mirrored tag, checks `VERSION` ==
tag, builds `.#system-bundle` and `.#nixos-firmware-image-mainline`, and
publishes

- `nanokvm_pro_sys_latest.json` (manifest),
- `nanokvm_pro_sys_<ver>.tar.gz` (the bundle),
- the `.axp` (uploaded separately with retries — GitHub's large-asset path is
  flaky),

then refreshes the rolling `preview` release with the first two. A failed run is
recovered by re-running it from the Actions tab; never fix a release by pushing
to GitHub.

> **The release job now needs binfmt.** The appliance is evaluated as a native
> `aarch64-linux` system. Nearly all of it substitutes prebuilt from
> `cache.nixos.org`, but its own configuration derivations (`etc`,
> `system-path`, the units, the system closure) are built on the runner, so the
> workflow installs the qemu handlers (`docker/setup-qemu-action`) and sets
> `extra-platforms = aarch64-linux`. The dev box has always had this; **the
> runner half is the one part of the release path #86 could not test.**

---

## Local testing

```bash
nix build .#system-bundle
cat result/nanokvm_pro_sys_latest.json
cat result/MANIFEST.json
head result/closure.txt

# what the device checks:
openssl dgst -sha512 -binary result/*.tar.gz | base64 -w0
```

The two gates that run in `nix flake check`:

```bash
nix build .#checks.x86_64-linux.nanokvm-updater-loop -L
nix build .#checks.x86_64-linux.nanokvm-system-bundle -L
```

**`nanokvm-updater-loop`** (`nixos/lib/updater-test.nix`) runs the real
`nanokvm-update`, `nanokvm-gc` and `nanokvm-install-boot` against a fake root in
a build sandbox — `--root` exists for exactly this — with a tiny synthetic
bundle. It asserts, after an apply: both new store paths landed, the old
generation is untouched, the profile advanced, the closure list was recorded,
the new kernel is in `/boot` and the old one still is, `extlinux.conf` names the
new generation **and** the new kernel and carries the `nanokvmboot=` token, and
**the fallback did not move**. Then it collects twice — once while the fallback
still names generation 1 (nothing may be deleted) and once after the fallback
has been promoted (generation 1 and its exclusive paths go, the live set stays)
— and finally checks that `nanokvm-gc` **refuses and deletes nothing** when a
kept generation's closure list is missing.

**`nanokvm-system-bundle`** (`pkgs/system-bundle-check.nix`) opens the published
artefact: the manifest's SHA-512 and size against the tarball, the digest's
form (base64 of a raw SHA-512, 88 chars — a hex digest would be a channel that
can never install anything), one top-level directory, no hardlink entries,
`closure.txt` diffed against the toplevel's real closure, one `store/` member
per closure line and no extras, and the boot payload against the hashes
`MANIFEST.json` claims for it.

To exercise the round trip against a device before trusting CI, serve
`result/` over HTTPS from a host the device trusts and point a test build's
`nanokvm.update.stableUrl` at it. Plain HTTP or an untrusted certificate will
not work — both the server and `curl` verify.

### What hardware still has to prove

Offline coverage stops at the sandbox boundary. Three board rounds, each
ending in a state the plug recovers from — a cold cycle clears `bootcount`, and
a candidate that does not come up is on the fallback config by the fourth
attempt.

**Round 1 — bootstrap.** The board is running a generation from before this
work: it has no `nanokvm-update`, and its `/boot` holds the old flat `Image`.
So the first move is the manual switch
(`.claude/skills/kvm-device/SKILL.md`) plus a `/boot` rename, in this order:

```sh
cp /boot/Image /root/Image.pre86       # mark-good WILL collect the old one
# copy .#boot-payload's Image-<h> and <dtb>-<h>.dtb into /boot  (add, do not replace)
# ship the missing store paths, set the profile, switch-to-configuration switch
# write extlinux.conf naming the NEW pair; LEAVE extlinux-fallback.conf alone
reboot
```

Leaving the fallback alone is the whole safety of this round: it still names
the old generation and the old `/boot/Image`, so three failed attempts land
back exactly where the board started. **Oracles:** SSH at ~71 s;
`nanokvm-update status` prints the new generation and `Image-<hash>`;
`devmem 0x02390030 32` = `0xB0010000`; `journalctl -u nanokvm-mark-good` shows
the fallback promoted to the new pair **and the old `/boot/Image` collected** —
that last line is the `/boot` GC proving itself.

**Round 2 — a real bundle, end to end.** Build a bundle from a
trivially-changed configuration (any config change moves both the toplevel and
the kernel, because the stage-1 initrd is inside the Image), copy it over, and:

```sh
nanokvm-update --no-reboot install /root/nanokvm_pro_sys_<v>.tar.gz
nanokvm-update status      # gen N+1, two Image-* in /boot, fallback still N
reboot
```

**Oracles:** `readlink /run/booted-system` is the new toplevel; `bootcount`
back to `0xB0010000`; the fallback now names the new pair and `/boot` is back
to one kernel. Then, on the same round, force the rollback rather than breaking
a generation — `devmem 0x02390030 32 0xB001000A; reboot` — and confirm the
board comes up on the **previous** generation *and its kernel*, with bit 30 of
`0x02390024` set. That is the thing #86 added and the only way to watch it fire
that cannot strand the board.

**Round 3 — collection, then the button.** `nanokvm-gc --keep 2 -n`, read it,
then without `-n`; the generation the fallback names must survive, the one
before it must not, and `du -sh /nix/store` must drop. Then cut an alpha and
press **update** in the web UI (or point `nanokvm.update.stableUrl` at a local
HTTPS server), which is the only path that exercises the server's `install()`
handoff rather than the CLI.

**Failure catch, every round:** the boot counter. Nothing above writes a
partition, so the worst outcome is a generation that does not come up, which
`altbootcmd` undoes on the fourth attempt. The plug is the backstop if even
that does not fire.

---

## Weighed and rejected

Recorded because the reasoning will be revisited.

**Nix on the device.** The honest way to make updates cheap: `nix copy` a
closure, `nixos-rebuild switch --target-host`, real garbage collection with a
real database. Rejected because it puts a package manager, a SQLite database and
a daemon on an appliance whose entire value proposition is "it is exactly what
the flake says", adds ~150 MB to an image that must fit beside a 48.9 MiB kernel
in a fixed layout, and gives a KVM's root account a general-purpose build tool.
The device-side cost of *not* having it is one shell script and one closure
list per generation, which is what `nixos/lib/updater.nix` is. Revisit if the
bundle size becomes the thing users complain about.

**Delta bundles.** Ship only the store paths the device is missing. The builder
cannot know what that is without the device telling it, and the honest ways to
arrange that — serve the release as a binary cache, or have the device POST its
closure list and get a tailored tarball — both mean putting a nar-fetching
client (effectively nix) back on the appliance, or a stateful server behind the
release. A middle road exists and was not taken for #86: publish a per-release
`closure.txt` as its own small asset, have the device fetch the *previous*
release's list and request a range of the tarball. GitHub release assets have no
usable range semantics for tar members, so this needs a real artefact store
first. **The eMMC cost is already proportional to the change** — only missing
paths are written — so what a delta would save is bandwidth alone.

**Signing.** The bundle is gated by a SHA-512 that comes from our own manifest:
integrity, not authenticity. Whoever serves the manifest controls what the
device installs, as root. That is unchanged from the 4.19 OTA and is **issue
#31**; when it lands it plugs into `verify_payload` in `nixos/lib/updater.nix`,
between the hash check and the unpack, and nowhere else.

**A/B kernel partitions.** The vendor layout's answer, and the minimal layout
deleted it deliberately (#89 rung 4): one `uboot`, one `atf`, no twins.
Reintroducing an A/B kernel pair would mean two 64 MiB partitions, a slot
register to arbitrate them and an SPL that knows about both — against two files
in an ext4 `/boot` and a config that names one of them. The content-addressed
scheme gets the same property with no partition table change and no
first-stage-loader rebuild, and it scales past two.

**`switch-to-configuration switch` instead of `boot`.** Rejected: it activates
a userspace the boot counter has not vouched for, restarts `nanokvm.service`
underneath the HTTP request that asked for the update, and leaves no automatic
way back. The reboot *is* the test.

---

## Caveats

- **No signature, only a hash** (above, and #31). GitHub Releases over TLS is
  the trust boundary — note that is the *mirror*, not the Gitea source of truth,
  so both the GitHub repo's write access and the mirror credential matter.
- **The URL is baked in twice.** `nanokvm.update.stableUrl` (the updater) and
  `updateBaseUrl` in `flake.nix` (the server, compiled in). Changing where you
  host means a rebuild — and for the server half, an update carrying the new
  binary or a reflash.
- **~460 MB per update, and one closure of eMMC headroom.** The bundle is
  downloaded to `/root/.kvmcache`, untarred there, and the missing paths renamed
  into the store; a full-closure change therefore wants ~2 GB free on a 29 GiB
  rootfs. `nanokvm-gc` is what keeps that true over time.
- **An update needs a healthy boot.** `nanokvm-update update` refuses while
  `bootcount` is non-zero, i.e. before `nanokvm-mark-good` has run. That is
  deliberate: installing then would rewrite the config the counter is counting.
  `install-staged` does not refuse, because the web UI's button is an explicit
  human action.
- **There is no downgrade check.** The updater takes what the channel offers
  rather than comparing semver, because "the channel" is a release we cut and
  the thing that catches a bad one is the boot counter, not a version test.
  Pointing a device at an older release is a deliberate downgrade and works.
- **Mirrored-tag trigger.** The release workflow fires only if the mirror's
  pushes come from a PAT/deploy-key identity. If a tag lands on GitHub and no
  run starts, check the mirror's auth identity before anything else.

---

## History: the 4.19 overlay OTA

**Retired 2026-09-10 (#86).** From #37 until then, the shipping 4.19 image
updated itself with `pkgs/update-package.nix`: a `nanokvm_pro_<ver>.tar.gz`
carrying a `rootfs/` overlay copied verbatim over `/` (the app, the web UI,
`libkvm.so`, the `/lib/modules/4.19.125` tree, the `/soc/ko` loader) plus an
optional `partitions/` set of vendor-format signed images written to **both** A/B
slots, B first, compare-first and read-back verified. It was hardware-proven
end to end on 2026-08-16 with `v2.0.0`. The server-side half was
`pkgs/nanokvm-server/install-override.go.in`.

It is gone, along with the flake output `.#update-package`, because the product
is the mainline NixOS appliance and a store closure is not something an Ubuntu
rootfs can apply. The 4.19 server build keeps an `install()` that refuses and
points at AXDL (`install-retired.go.in`) rather than falling back to the
vendor's dpkg installer, which would fetch three `.deb`s from a CDN we do not
control.

**There is no migration path from the vendor layout, by decision** (Jeremy,
2026-09-10): nobody is running the alpha releases, so a migration OTA — the old
system staging a mainline kernel into `kernel_b`, an initramfs writing the split
layout — would have been built for no users. **A vendor-layout board is moved
forward by flashing `.#nixos-firmware-image-mainline` over AXDL**, which is a
bench trip and not a brick
([flashing-and-recovery.md](flashing-and-recovery.md)).

Two things from that era are still live and still worth knowing: the manifest
shape (`{version, name, sha512, size}`, base64 of a raw digest) and the
`releases/latest/download` + rolling-`preview` channel topology. The bundle
reuses both, which is why the server needed no change to its download path.
