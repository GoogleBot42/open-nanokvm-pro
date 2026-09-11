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
- [How the device updates itself](#how-the-device-updates-itself)
- [How the device installs one](#how-the-device-installs-one)
- [Rollback, including the kernel](#rollback-including-the-kernel)
- [Garbage collection without nix](#garbage-collection-without-nix)
- [Cutting a release](#cutting-a-release)
- [Local testing](#local-testing)
- [Weighed and rejected](#weighed-and-rejected)
- [Caveats](#caveats)
- [History: the 4.19 overlay OTA](#history-the-419-overlay-ota)

---

> **Status (2026-09-11, #86 + #99): built and proven offline; not yet run on
> hardware.** Four `nix flake check` gates cover the loop and the policy around
> it — `nanokvm-updater-loop` applies a real bundle to a fake root with the real
> scripts, `nanokvm-update-idle` drives the checkbox, the pending markers and
> the idle reboot gate against a fake release host,
> `nanokvm-mark-good-fallback` derives a rollback config and refuses the cases
> it must, and `nanokvm-system-bundle` reads the published artefact back against
> the closure it claims. Since #99 the appliance also boots end to end under
> QEMU with the generation's own kernel and initrd, zero failed units. What is
> unproven is everything that needs the board: `switch-to-configuration`, the
> `/nix/store` remount, whether U-Boot boots the `/boot` NixOS wrote, and
> whether the server's own idle answer is right.
> See [the hardware plan](#what-hardware-still-has-to-prove).

## The idea

The appliance is a **NixOS system with no `nix` on it**
([nixos-rootfs.md](nixos-rootfs.md)): the rootfs is a fixed store closure the
build host produced, which is what keeps the image small and the running system
exactly what the flake describes. So an update cannot be a `nixos-rebuild`, and
since #78 it cannot be a file overlay either — there are no files to overlay,
only store paths.

An update is therefore a **system bundle**: the new toplevel's entire closure —
its kernel, initrd and device tree included, as ordinary store paths (#99) —
and a list saying which paths belong to it. The device unpacks what it does not
already have, points the system profile at the new toplevel, runs
`switch-to-configuration boot`, and reboots.

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
MANIFEST.json     format, version, toplevel, closure count
closure.txt       every store path in the toplevel's closure, one per line
store/<base>/     those store paths, as ordinary directories
```

**There is no `boot/` half** (#99). The kernel, the initrd and the device tree
are part of the generation, so they travel in `closure.txt` as ordinary store
paths, and `switch-to-configuration boot` — NixOS's own extlinux builder — is
what copies them onto `/boot`. `nanokvm-update` does not write a single byte of
that partition, and `pkgs/system-bundle-check.nix` asserts both halves: the
manifest declares no out-of-band payload, and `<toplevel>/{kernel,initrd,dtbs}`
resolve to store paths that are in the closure *and* in the archive.

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

## How the device updates itself

Three rules, and each of them is something a KVM gets wrong at its owner's
expense.

**1. The switch is a checkbox, not a NixOS option.** Settings → Check for
Updates carries **Automatic updates** beside **Preview updates**, and both are
flag files in `/etc/kvm`: `auto_updates` and `preview_updates`, presence = on.
The timer runs whenever `nanokvm.update.enable` is set and `nanokvm-update
update` exits 0 doing nothing while the box is unticked, so ticking it takes
effect immediately and without a rebuild. `nanokvm.update.auto` is gone.

**2. It installs on a timer; it reboots when the room is empty.** Nothing a
`switch-to-configuration boot` installs is live until the board restarts, and
a KVM is the machine you are using to fix the machine — so the restart waits.
After a successful install the updater writes two markers and asks the server
whether anybody is there:

| marker | says | cleared by |
|---|---|---|
| `/run/nanokvm-update-pending` | a reboot is owed | the reboot itself (tmpfs) |
| `/var/lib/nanokvm/update-pending` | an update was installed | the next `reboot-if-idle` after the boot, by comparing versions |

Idle → reboot now. In use → exit 0, leave the markers, and let
`nanokvm-update-reboot` (every ten minutes) ask again. `nanokvm.update.rebootWindow`
is an `OnCalendar` expression that *becomes* that timer's schedule when set, so
it must fire repeatedly inside the window you want
(`*-*-* 03..05:00/10:00` is every ten minutes between three and five); installs
are unaffected. A second update never stacks on an unbooted one.

**"Idle" is what the server can actually see**, over a loopback-only route
(`GET /api/update/idle`, `pkgs/nanokvm-server/update-status.go.in`), and every
term is a zero except the last two:

- video clients across all four consumers — the arbitration map from #69 keeps
  the counts, `stream.TotalStreamClients()` reads them;
- `/api/ws` HID sessions (`ws.GetManager().GetClients()`): a browser with
  keyboard and mouse attached *is* the definition of at-the-console;
- web-terminal sessions and the last web request from anywhere but loopback —
  neither of which anything recorded before, hence `common/activity.go` and
  `middleware/activity.go`. Loopback is filtered out or the mini-display's
  once-a-second poll would keep the device permanently busy;
- the mini-display's live-preview lease: somebody is standing at the device;
- a mounted virtual-media image — rebooting yanks a USB disk out of a machine
  that may be installing from it. **An image left mounted blocks the reboot
  indefinitely**; unmount it, or press *Restart now*;
- seconds since the last frame read, and since that last web request, both
  against `nanokvm.update.idleQuietSec` (default 600).

**A server that does not answer is BUSY.** An unanswered question must never
become a reboot, and the offline check asserts exactly that.

**None of this is tied to the tarball.** `update` is check → download/verify →
one `install_staged` call → markers → idle-gated reboot, and `install_staged`
reports what it installed through `STAGED_VERSION`/`STAGED_TOPLEVEL` rather than
writing the markers itself. When #100 replaces the transport with `nix copy`
from a binary cache, that one function and the download above it are what is
replaced; the checkbox, the markers, the idle gate and the second timer do not
move.

The update page shows `<from> -> <version>`, "Update installed. It takes effect
after a restart.", what it is waiting for, and a **Restart now** button — the
person reading that page is usually the person the device is waiting for. It
does not offer to install the pending version again.

**3. No device ever follows a branch.** Both channels are GitHub releases cut
from a `vX.Y.Z` tag: stable is `releases/latest/download`, which never serves a
prerelease, and preview is the rolling `preview` release, which only a
tag-triggered run refreshes. `.github/workflows/release.yml` triggers on tags
only *and* asserts `GITHUB_REF_TYPE = tag` before it writes either channel,
because that job is where the write happens and a trigger is something a future
edit can widen. Nothing publishes from `main`; the alpha channel is prerelease
**tags**.

---

## How the device installs one

`nanokvm-update` (`nixos/lib/updater.nix`) is the whole implementation, and it
has two callers:

- **the web UI button** → `POST /api/application/update` → the server downloads,
  SHA-512-verifies and untars, then our `install()`
  (`pkgs/nanokvm-server/install-bundle.go.in`) runs
  `nanokvm-update install-staged <dir>` and reboots;
- **the timer** → `nanokvm-update update` does the whole cycle itself, gated by
  the web UI's *Automatic updates* checkbox and rebooting only once nobody is
  using the device ([above](#how-the-device-updates-itself)).

```
nanokvm-update update
  ├─ exit 0 unless /etc/kvm/auto_updates     the web UI's checkbox
  ├─ exit 0 if a reboot is already owed      never stack on an unbooted update
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
      4. profile: system-<N+1>-link -> toplevel, then rename `system` onto it
      5. switch-to-configuration boot   → NixOS's extlinux builder copies THIS
                                          generation's kernel, initrd and dtbs
                                          into /boot/nixos/ and rewrites
                                          /boot/extlinux/extlinux.conf
      6. write the pending markers
  └─ reboot IF the server says nobody is using the device; otherwise leave the
     markers and let nanokvm-update-reboot take it later
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

**#99 closes the kernel half, by deleting the question.** The kernel, the
initrd and the device tree are part of the generation — `boot.kernelPackages`
and `hardware.deviceTree` — so an entry that names a generation names its
kernel by construction. NixOS's own extlinux builder writes one `LABEL` per
generation with its own `LINUX`/`INITRD`/`FDT`/`init=`, and
`nanokvm-mark-good` promotes by rewriting one `DEFAULT` line.

#86's scheme is worth recording because it worked and was still the wrong
shape: content-addressed `/boot/Image-<hash>` files, a `nanokvmboot=` token on
the command line so a running system could tell which one `sysboot` had loaded,
a copier in the updater and a collector in the health gate. Four mechanisms to
re-implement what the store already does. All four are gone.

`/boot` is 272 MiB and a generation's kernel + initrd + dtbs is ~50 MB.
`configurationLimit` is 3 and `pkgs/bootfs.nix` asserts room for four sets — the
builder writes the new one before it collects the obsolete one, so the peak is
the menu plus the set being replaced.

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
profile's target, `/run/booted-system`, `/run/current-system`, and the
generation **each extlinux config's `DEFAULT` entry** names — the fallback most
of all, since it is the one that gets used exactly when the default does not
work.

**The `DEFAULT` entry, not the first `init=` in the file.** Since #99 both
configs list every generation in the menu and differ only in which `LABEL`
their `DEFAULT` selects, so "the `init=` in this file" has several answers and
only one of them is live. Reading the first would pin whichever generation the
builder emitted first — `nixos-default`, the newest — and leave the fallback's
own generation collectable.

**If any kept generation has no closure list, or a boot config yields no
generation at all, `nanokvm-gc` deletes nothing** and says so. An unknown live
set makes every deletion a guess; a store that is too full is recoverable, a
store missing one path is a bench trip.

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

The four gates that run in `nix flake check`:

```bash
nix build .#checks.x86_64-linux.nanokvm-updater-loop -L
nix build .#checks.x86_64-linux.nanokvm-update-idle -L
nix build .#checks.x86_64-linux.nanokvm-mark-good-fallback -L
nix build .#checks.x86_64-linux.nanokvm-system-bundle -L
```

**`nanokvm-updater-loop`** (`nixos/lib/updater-test.nix`) runs the real
`nanokvm-update` and `nanokvm-gc` against a fake root in a build sandbox —
`--root` exists for exactly this — with a tiny synthetic bundle. It asserts,
after an apply: both new store paths landed, the old generation is untouched,
the profile advanced, the closure list was recorded, and **`/boot` is
byte-for-byte untouched** (#99: the extlinux builder owns it, and this run is
`--no-activate`). Then it collects twice against a pair of NixOS-shaped configs
that list all three generations — once while the fallback's `DEFAULT` names
generation 1 (nothing may be deleted) and once after it has been promoted
(generation 1 and its exclusive paths go, the live set stays) — and finally
checks the two refusals: a kept generation with no closure list, and a boot
config whose `DEFAULT` resolves to no generation. Both must delete nothing.

**`nanokvm-mark-good-fallback`** (`nixos/lib/mark-good-test.nix`) runs the real
`nanokvm-mark-good` against a fake `/boot` holding an official config with
three labels, with `/run/booted-system` on the *older* generation — the state
after an install and before the reboot. It asserts the fallback selects the
**booted** generation's label and not the profile's, that exactly two lines
differ from `extlinux.conf` and both are the `DEFAULT`, that a repeat run is a
no-op, that a booted generation with no `LABEL` in the file is **refused** with
the previous fallback intact, and that an absent `/boot/extlinux` is a clean
skip rather than a write into the root filesystem.

**`nanokvm-update-idle`** (`nixos/lib/update-idle-test.nix`) runs the same real
scripts against a fake root, a fake release host and a fake idle route on
loopback — a python `http.server` serving the manifest, the tarball and a JSON
file the test rewrites between phases. Nine of them: an unticked checkbox
installs nothing and is not an error; ticked-and-in-use installs, writes both
markers and does **not** reboot; a second update refuses to stack on an unbooted
one; the reboot timer waits while the room is full and takes it when it empties;
an **unreachable** idle route fails closed; the note settles after the boot and
says the update is live; ticked-and-idle installs and reboots in one run. Under
`--root` the reboot is *recorded* in `/run/nanokvm-reboot-requested` rather than
taken — `writeShellApplication` puts its own systemd first on `PATH`, so a stub
could not catch it, and a build sandbox is no place to find out.

**`nanokvm-system-bundle`** (`pkgs/system-bundle-check.nix`) opens the published
artefact: the manifest's SHA-512 and size against the tarball, the digest's
form (base64 of a raw SHA-512, 88 chars — a hex digest would be a channel that
can never install anything), one top-level directory, no hardlink entries,
`closure.txt` diffed against the toplevel's real closure, one `store/` member
per closure line and no extras, that `MANIFEST.json` declares **no** separate
boot payload, and that `<toplevel>/{kernel,initrd,dtbs}` resolve to store paths
which are both in the closure and in the archive.

To exercise the round trip against a device before trusting CI, serve
`result/` over HTTPS from a host the device trusts and point a test build's
`nanokvm.update.stableUrl` at it. Plain HTTP or an untrusted certificate will
not work — both the server and `curl` verify.

### What hardware still has to prove

Offline coverage stops at the sandbox boundary. Five board rounds, each
ending in a state the plug recovers from — a cold cycle clears `bootcount`, and
a candidate that does not come up is on the fallback config by the fourth
attempt.

**Round 1 — bootstrap onto the official layout (#99).** The board's `/boot` is
the pre-#86 shape: a flat `/Image`, `/ax630c-nanokvm-pro.dtb` and two
hand-written extlinux configs, 245 MB with 97 MB free. One generation of the
new shape is 50 MB, so it fits beside the old files with room to spare and
nothing has to be deleted first.

Ship the new toplevel by the manual recipe
(`.claude/skills/kvm-device/SKILL.md`) and then let NixOS write `/boot` for the
first time:

```sh
cp /boot/extlinux/extlinux-fallback.conf /root/fallback.pre99
<toplevel>/bin/switch-to-configuration boot    # writes extlinux.conf + /boot/nixos/*
# hand-restore the OLD fallback: it must keep naming /Image and the old generation
cp /root/fallback.pre99 /boot/extlinux/extlinux-fallback.conf
sync; reboot
```

Restoring the old fallback is the whole safety of this round: the official
builder does not write that file, so three failed attempts land back exactly
where the board started, on the kernel and generation it is running now.

**Oracles:** SSH at ~71 s; `devmem 0x02390030 32` = `0xB0010000`;
`readlink /run/booted-system` is the new toplevel; `journalctl -u
nanokvm-mark-good` shows `fallback promoted to generation N`; and
`diff /boot/extlinux/extlinux{,-fallback}.conf` is exactly two lines, both
`DEFAULT`.

**Round 2 — the forced rollback.** `devmem 0x02390030 32 0xB001000A; reboot`.
**Oracles:** the board comes up on the generation the fallback's `DEFAULT`
named, bit 30 of `0x02390024` is set, and `nanokvm-update status` resolves both
configs to the two different generations. This is the way to exercise the
rollback — not a deliberately broken generation, which is what cost a bench
trip in #89 rung 5.

**Round 3 — a kernel-only change.** Build a bundle whose *only* difference is a
kernel config string, install it, reboot. **Oracles:** `uname -r`/`uname -v`
moves; `ls /boot/nixos` holds two Image files; `nanokvm-update status` shows
generation N+1. Then force the counter again and confirm the board comes back
on the **old** kernel — which is the property #86 needed four mechanisms for
and #99 gets from the generation. A deliberately unbootable kernel is *not* the
test.

**Round 4 — collection, then the button.** `nanokvm-gc --keep 2 -n`, read it,
then without `-n`; the generation the fallback names must survive, the one
before it must not, and `du -sh /nix/store` must drop. Then cut an alpha and
press **update** in the web UI (or point `nanokvm.update.stableUrl` at a local
HTTPS server), which is the only path that exercises the server's `install()`
handoff rather than the CLI.

**Round 5 — the checkbox and the wait.** Two board rounds at most, and neither
writes a partition.

1. Tick **Automatic updates** in Settings → Check for Updates; confirm
   `/etc/kvm/auto_updates` appears and `nanokvm-update status` says `on`. Open a
   video stream from a browser and leave it open, then
   `systemctl start nanokvm-update` with a real bundle on the channel.
   **Oracles:** `nanokvm-update status` shows the new generation *and* `reboot
   pending`; `curl -sk https://127.0.0.1/api/update/idle` reports
   `idle:false` with `busy` naming `stream`; the board has **not** rebooted; the
   update page shows `<from> -> <version>` and *Restart now*.
2. Close the browser tab and wait for the next `nanokvm-update-reboot` tick
   (≤10 min). **Oracles:** the board reboots on its own; after it comes back,
   `readlink /run/booted-system` is the new toplevel, `bootcount` is
   `0xB0010000`, and within two minutes `journalctl -u nanokvm-update-reboot`
   says `update <version> is live` with the note gone. Pressing *Restart now*
   instead of waiting is the same round with the button as the trigger.

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

**Rebooting as soon as the update is installed.** What the first cut of #86 did,
and what every appliance auto-updater does. Rejected because this appliance is a
KVM: the one session an unattended reboot is guaranteed to interrupt is somebody
using the console to fix a machine they cannot otherwise reach. Installing is
free (nothing is live until the restart), so the reboot is the only part that
has to wait, and waiting costs a marker file and a second timer.

**A NixOS option instead of a checkbox** (`nanokvm.update.auto`, which is what
this replaced). Rejected on Jeremy's instruction and for two mechanical reasons:
the owner of the box never sees the flake, and a device whose owner had ticked
the box would still read `auto = false` in the configuration that built it. A
default that the UI can override also needs tri-state storage plus a way to ship
that default into the server, where presence-or-absence of one file needs
neither. The option is gone; `enable` (ship the tools at all) and `schedule`
stay.

**Polling `main`.** A device that tracked the branch would get every commit,
including the ones that do not boot, and the rollback would then be the only
review step. Both channels are tags; the alpha channel is *prerelease* tags, so
"give me the new stuff early" and "give me whatever landed an hour ago" stay
different things.

**Letting the server decide the idle threshold.** The route reports raw counts
and takes `?quiet=<seconds>` from the caller, rather than owning a policy
constant, so `nanokvm.update.idleQuietSec` is the only place the number lives
and the same route can answer a UI that wants to display the state.

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
- **A mounted virtual-media image blocks the reboot for as long as it is
  mounted.** That is the intended behaviour — the host may be installing from
  it — but it is the one idle term that can stay true forever with nobody
  present. The update page names it, and *Restart now* overrides it.
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
