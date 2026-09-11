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
- [The manifest](#the-manifest)
- [How the device updates itself](#how-the-device-updates-itself)
- [How the device installs one](#how-the-device-installs-one)
- [Where the trust is](#where-the-trust-is)
- [Nix on the appliance](#nix-on-the-appliance)
- [Rollback](#rollback)
- [Garbage collection](#garbage-collection)
- [Cutting a release](#cutting-a-release)
- [Local testing](#local-testing)
- [What hardware still has to prove](#what-hardware-still-has-to-prove)
- [Weighed and rejected](#weighed-and-rejected)
- [Caveats](#caveats)
- [History](#history)

---

> **Status (2026-09-11, #100): built and proven offline; not yet run on
> hardware.** Three `nix flake check` gates cover it, and two of them now run
> **real nix** inside the build sandbox — a signed `file://` binary cache, two
> chroot stores, a real `nix copy`, a real `nix-env --set`, a real
> `nix-collect-garbage`. What is unproven is everything that needs the board:
> the real `switch-to-configuration`, the `/nix/store` remount, whether U-Boot
> boots what it wrote, and whether the server's own idle answer is right. The
> board has no nix yet, so round 1 is a bootstrap.
> See [the hardware plan](#what-hardware-still-has-to-prove).
>
> **Two things are still placeholders (#96):** `nanokvm.update.cacheUrl` and
> `nanokvm.update.trustedPublicKeys` are empty, and the release job's three
> attic secrets do not exist. A device builds and boots but refuses to update,
> and says so at build time. See [Caveats](#caveats).
>
> **One residual (#99):** the kernel, initrd and dtb are not part of the
> generation yet, so an update transports the closure and **cannot change the
> kernel**. See [Rollback](#rollback).

## The idea

The appliance is a NixOS system and **nix is on it** (#100), so an update is
what an update is on any NixOS machine:

1. put the new system's closure in the store,
2. make it the system profile,
3. run its `switch-to-configuration boot`.

Every one of those is an official tool doing the thing it is for. There is no
bundle format, no payload, no closure list, no hand-rolled collector and no
hand-rolled store surgery. What is *ours* is only the four things nixpkgs has
no opinion about: **which channel** the closure comes from, **which keys** must
have signed it, **when** the reboot happens, and **what catches** a generation
that does not come up.

**The reboot is the mechanism, not an afterthought.** `boot`, never `switch`:
nothing about the new generation is live until the board restarts, the restart
is counted by U-Boot's `bootcount`, and `nanokvm-mark-good` clears that counter
only once the **new** system is running, routed and serving. A generation that
does not come up healthy is rolled back by `altbootcmd` on the fourth attempt
with nobody watching — the only rollback story a box with no console and no
autoboot interrupt window can have. `switch` would activate an untested
userspace with no way back, and is never used.

Two Nix outputs feed a release:

| Output | What it is | Where it goes |
|---|---|---|
| `appliance-toplevel` | the NixOS system closure | pushed to the binary cache, signed |
| `system-manifest` | `nanokvm_pro_sys_latest.json`, ~200 bytes | attached to the release; devices poll it |
| `nixos-firmware-image-mainline` | the flashable `.axp` | the AXDL image — the only way onto a board that is not already running this |

Publishing a release **is** the update push, and it is two halves: the closure
lands in the cache *first*, then the manifest that names it.

---

## The manifest

`pkgs/system-manifest.nix`. A version and a store path:

```json
{
  "format": "nanokvm-nix-closure/1",
  "version": "2.3.0",
  "toplevel": "/nix/store/rkcz8k4w6fzdz0bnpxg1pk1ka0qbl8bd-nixos-system-nanokvm-pro-2.3.0",
  "size": 1351720704,
  "closureCount": 741
}
```

There is no `sha512` and no `name`, because there is no payload to hash. The
bytes live in the binary cache, each NAR signed; the manifest only ever says
*which store path to install*. See [Where the trust is](#where-the-trust-is).

`size` is the closure's **total NAR size**, not the download — the device
already has most of it, so what crosses the wire on a typical update is a few
percent of that. The UI shows it as an honest upper bound, computed before
asking the store what it is missing.

**The manifest FILENAME is the channel.** `nanokvm_pro_sys_latest.json` is the
appliance's; the retired 4.19 image polls `nanokvm_pro_latest.json`, which
nothing publishes any more, so it is offered nothing rather than offered a
store closure no Ubuntu rootfs could apply.
`pkgs/nanokvm-server.nix`'s `updateMode` (now `"closure"`) picks both the
manifest name and the `install()` body, and they move together.

Beside the manifest, not published: `closure.txt` — what the release pushed to
the cache, so a hardware run or a `nix build --rebuild` can diff a device's
store against a release without re-evaluating the flake.

---

## How the device updates itself

**The policy is unchanged from #86.** The transport underneath it was replaced
wholesale and not one phase of it moved — that was #86's design claim, and
`nixos/lib/update-idle-test.nix` is where it is cashed.

**1. The switch is a checkbox, not a NixOS option.** Settings → Check for
Updates carries **Automatic updates** beside **Preview updates**, and both are
flag files in `/etc/kvm`: `auto_updates` and `preview_updates`, presence = on.
The timer runs whenever `nanokvm.update.enable` is set and `nanokvm-update
update` exits 0 doing nothing while the box is unticked, so ticking it takes
effect immediately and without a rebuild. There is no `nanokvm.update.auto`.

**2. It installs on a timer; it reboots when the room is empty.** Nothing a
`switch-to-configuration boot` installs is live until the board restarts, and a
KVM is the machine you are using to fix the machine — so the restart waits.
After a successful install the updater writes two markers and asks the server
whether anybody is there:

| marker | says | cleared by |
|---|---|---|
| `/run/nanokvm-update-pending` | a reboot is owed | the reboot itself (tmpfs) |
| `/var/lib/nanokvm/update-pending` | an update was installed | the next `reboot-if-idle` after the boot, by comparing versions |

Idle → reboot now. In use → exit 0, leave the markers, and let
`nanokvm-update-reboot` (every ten minutes) ask again.
`nanokvm.update.rebootWindow` is an `OnCalendar` expression that *becomes* that
timer's schedule when set, so it must fire repeatedly inside the window you want
(`*-*-* 03..05:00/10:00` is every ten minutes between three and five); installs
are unaffected. A second update never stacks on an unbooted one.

**"Idle" is what the server can actually see**, over a loopback-only route
(`GET /api/update/idle`, `pkgs/nanokvm-server/update-status.go.in`), and every
term is a zero except the last two:

- video clients across all four consumers — the arbitration map from #69 keeps
  the counts, `stream.TotalStreamClients()` reads them;
- `/api/ws` HID sessions (`ws.GetManager().GetClients()`): a browser with
  keyboard and mouse attached *is* the definition of at-the-console;
- web-terminal sessions and the last web request from anywhere but loopback.
  Loopback is filtered out or the mini-display's once-a-second poll would keep
  the device permanently busy;
- the mini-display's live-preview lease: somebody is standing at the device;
- a mounted virtual-media image — rebooting yanks a USB disk out of a machine
  that may be installing from it. **An image left mounted blocks the reboot
  indefinitely**; unmount it, or press *Restart now*;
- seconds since the last frame read, and since that last web request, both
  against `nanokvm.update.idleQuietSec` (default 600).

**A server that does not answer is BUSY.** An unanswered question must never
become a reboot, and the offline check asserts exactly that.

The update page shows `<from> -> <version>`, "Update installed. It takes effect
after a restart.", what it is waiting for, and a **Restart now** button — the
person reading that page is usually the person the device is waiting for.

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
has two callers: the systemd timer runs `update`, and the web UI's button
reaches `install-now` through the server's `install()` override
(`pkgs/nanokvm-server/install-update.go.in`). Both end up in the same function.

```
nanokvm-update update
  ├─ exit 0 unless /etc/kvm/auto_updates     the web UI's checkbox
  ├─ exit 0 if a reboot is already owed      never stack on an unbooted update
  ├─ refuse if `bootcount` != 0xB0010000     this boot is not marked good yet;
  │                                          installing now would replace the
  │                                          very thing the counter is counting
  ├─ GET <base>/nanokvm_pro_sys_latest.json  (<base> is the preview channel if
  │                                          /etc/kvm/preview_updates exists)
  ├─ compare .version with /run/current-system/etc/nanokvm-version
  └─ install the toplevel it names, then reboot IF the server says nobody is
     using the device; otherwise leave the markers for nanokvm-update-reboot
```

The install itself is five steps, four of them somebody else's tool:

| # | Step | Command |
|---|---|---|
| 1 | fetch the channel manifest | `curl -fsSL <base>/nanokvm_pro_sys_latest.json` |
| 2 | substitute the closure | `nix copy --from <cache> --to auto --option require-sigs true --option trusted-public-keys <this system's keys> <toplevel>` |
| 3 | make it a generation | `nix-env -p /nix/var/nix/profiles/system --set <toplevel>` |
| 4 | write the bootloader | `<toplevel>/bin/switch-to-configuration boot` |
| 5 | markers, then the idle-gated reboot | ours |

Step 2 is skipped entirely when `nix path-info` already knows the path — and
"already here" means **valid in the database**, not present on disk. A directory
nix does not know about is not a store path, and `nix-env --set` on one tries to
*download* it; that is why the image ships a real database
([below](#nix-on-the-appliance)).

The commands, in full:

```
nanokvm-update check              what is installed, and what the channel offers
                update            check, install, reboot when idle (the timer)
                install-now       install what the channel offers, right now
                                  (the web UI button; no checkbox, no idle gate)
                install-manifest <file>    install what a manifest on disk names
                install-toplevel <path> [version]   one store path, straight in
                pending           the installed-but-not-yet-booted update
                reboot-if-idle    what nanokvm-update-reboot runs
                gc                delete old generations and collect the store
                status            generations, boot configs, store health

options: --root DIR  --cache URL  --trusted-key K  --keep N
         --no-activate  --no-reboot
```

`--root` prefixes every path and turns every nix invocation into
`--store local?root=...`, which is the only reason any of this is provable
before it meets hardware. `install-toplevel` is what a developer reaches for
after `nix copy --to ssh://` from a build host — the switch recipe in the
`kvm-device` skill.

Two details that are not obvious:

- **The version stamp is part of the closure.** `/etc/nanokvm-version` is a
  store file, so a rollback rolls the version back with everything else and
  there is no mutable stamp to get out of sync. (The web UI reads
  `/kvmapp/version`, likewise a store symlink.)
- **`/nix/store` is a read-only bind mount**, and `remount,ro` alone silently
  does nothing on a bind — it needs `remount,bind,ro`. The updater flips it
  around the `nix copy` and back again.

---

## Where the trust is

`nix copy` runs with `require-sigs = true` and an **explicit**
`trusted-public-keys` — the keys this system was built with, passed on the
command line, *not* read from `/etc/nix/nix.conf`. So the gate between the
network and this board's root filesystem is an ed25519 signature over each NAR,
made by the key that signed the release. A cache that is compromised, mirrored,
or simply wrong serves paths this device refuses. Nothing an operator adds to
the machine's nix config can widen what an update will install.

The manifest itself is only TLS-authenticated, and it does not need to be more.
A tampered manifest can:

- **name an older signed release** — a downgrade, which the boot counter and a
  deliberate re-point both already permit;
- **name a path that does not exist** — an update that fails and installs
  nothing.

It cannot make the device run unsigned code, because it never supplies bytes.
The updater also refuses anything that is not spelled as a store path before
`nix copy` ever sees it.

That is strictly more than the #86 tar bundle had. A SHA-512 out of our own
manifest is **integrity, not authenticity**: it only proved the download matched
what the manifest claimed, and whoever served the manifest controlled what the
device installed, as root. This is the whole of **#31** for the appliance.

---

## Nix on the appliance

**Single-user, not the daemon.** There is exactly one user here and it is root,
and nothing on this board ever builds. The daemon exists to mediate between
untrusted users and the store; with no untrusted users it is a socket, a unit,
32 `nixbld` accounts and a second process in the update path, for nothing. So:

```nix
nix.enable = true;
systemd.sockets.nix-daemon.wantedBy = lib.mkForce [ ];
nix.nrBuildUsers = 0;
nix.channel.enable = false;
system.disableInstallerTools = true;
```

`store = auto` then resolves to the local store, which is also **the stricter of
the two**: signature checking on a direct `LocalStore` has no trusted-user
bypass, so `nix copy` cannot be talked into accepting an unsigned NAR the way a
trusted client of a daemon can.

| `nix.settings` | Why |
|---|---|
| `substituters` = the release cache (only) | the board fetches release closures and nothing else |
| `trusted-public-keys` = `nanokvm.update.trustedPublicKeys` | the same keys the updater passes explicitly |
| `require-sigs = true` | the gate |
| `max-jobs = 0` | the board never builds — minutes per package on a 1.2 GHz A53, and eMMC wear |
| `sandbox = false` | nothing to sandbox with no builds |
| `auto-optimise-store = false` | a full store walk and a lot of small writes, to buy back space on a store holding three generations of one closure |
| `experimental-features = nix-command` | `nix copy`, `nix path-info` |
| `allowed-users` / `trusted-users` = `root` | only root exists; spelling it out keeps a future user from inheriting store-write |

No channels, no registry, no `NIX_PATH`: nothing on this box evaluates nixpkgs,
and a channel is a second, mutable source of truth for a system whose whole
point is that its generation came from a tagged release. `nixos-rebuild`,
`nixos-install` and `nixos-generate-config` would all be lies here, and they are
not small.

**The image ships a registered store, not a directory of store paths.**
`nixos/lib/appliance-artifacts.nix`'s `mkStoreDb` runs `nix-store --load-db`
over `closureInfo`'s registration at **image-build** time, checkpoints the WAL
into the file, and asserts with sqlite that `ValidPaths` is the closure exactly
— no more, no fewer. `mkRootfs` then asserts with `debugfs` that the packed ext4
actually carries `/nix/var/nix/db/db.sqlite` and its `schema`.

nixpkgs' image builders do this on **first boot** instead (a
`register-nix-paths` unit over `/nix-path-registration`). We do not, because on
this board that first boot is the one the `bootcount` rollback is judging: a
first boot that has to build a database before it can be a NixOS system is a
first boot with one more way to fail, on a board with no console.

**What it costs, measured on this branch (2026-09-11):**

| Configuration | Store paths | Bytes |
|---|---|---|
| the appliance, with nix + the updater | 741 | 1,351,720,704 |
| the same config, `nix.enable = false`, updater removed | 689 | 1,321,001,768 |

**52 store paths and ~29.3 MiB — about 2.3%.** A chunk of that is the `aws-c-*`
S3 libraries nix links; trimming them is
[rejected below](#weighed-and-rejected).

---

## Rollback

Unchanged by #100, and described in
[nixos-rootfs.md §4b](nixos-rootfs.md#4b-rollback--two-config-files-a-register-and-a-health-gate):
two files in `/boot`, `extlinux.conf` and `extlinux-fallback.conf`, chosen by
U-Boot's `bootcmd` and `altbootcmd`, with `bootcount` in `0x02390030` and
`bootlimit` 3. `nanokvm-mark-good` clears the counter and regenerates the
fallback from `/run/booted-system` once the system is running, routed and
serving. Hardware-proven unattended on 2026-09-09.

**To exercise it, do not install a broken generation.** Force the counter
instead — one boot, nothing to strand:

```sh
devmem 0x02390030 32 0xB001000A
reboot
```

> **The kernel is not in the generation yet — #99.** `switch-to-configuration
> boot` runs the existing `boot.loader.external` hook
> (`nixos/lib/install-boot.nix`), which pins the new generation's `init=` into
> `extlinux.conf` and names the **running** kernel, because that is the only
> kernel it knows about. So a nix-native update transports the closure and
> **cannot change the kernel, initrd or dtb**; a kernel change needs #99 or a
> reflash. The updater writes nothing in `/boot` by design, and the offline
> check asserts that it does not.

---

## Garbage collection

`nanokvm-update gc`, on the `nanokvm-gc` systemd timer
(`nanokvm.update.gcSchedule`, default weekly, `Persistent`, after
`nanokvm-mark-good` so a boot still on trial never collects).

`nix-collect-garbage` knows what is reachable; the only thing we tell it is what
must stay reachable. **Two steps, and the order is the safety property:**

1. **Pin.** Write a gc root into `/nix/var/nix/gcroots/nanokvm/` for every
   toplevel that `/run/booted-system`, `/run/current-system`, the system profile
   **or any `init=` in any `/boot/extlinux/*.conf`** names. The **fallback** is
   the one that matters: it is what gets used precisely when the default does
   not work, it is named by a text file rather than by a profile link, and
   nothing in nix knows about it unless we say so. The roots are rewritten from
   scratch every run, so a generation that stops being named stops being pinned.
2. **Then delete**, and only then: `nix-env --delete-generations <numbers>` for
   everything but the newest `nanokvm.update.keepGenerations` (default 3) and
   never one whose toplevel is pinned, followed by `nix-collect-garbage`.

**A pin that is written after the collection is a pin that was not there when it
mattered.** That ordering is what the offline check's two collection phases
exist to prove.

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

From there the push mirror replicates the commit + tag to GitHub, and
`.github/workflows/release.yml` fires on the mirrored tag, checks `VERSION` ==
tag, and does this in order:

1. build `.#appliance-toplevel` and `.#system-manifest`, asserting the manifest
   names what was just built;
2. **`attic push` the whole closure to the binary cache.** This is the payload,
   and it must land *before* the manifest — a manifest naming a path no cache
   has is an update every device on the channel fails;
3. build `.#nixos-firmware-image-mainline`;
4. publish `nanokvm_pro_sys_latest.json` on the release, refresh the rolling
   `preview` release with it, then upload the `.axp` separately with retries
   (GitHub's large-asset path intermittently 500s).

> **The push step needs three repository secrets, and they do not exist yet
> (#96).** `ATTIC_ENDPOINT`, `ATTIC_CACHE`, `ATTIC_TOKEN` — all Jeremy's to
> create, and the cache's **public** key has to match `nixConfig.
> extra-trusted-public-keys` in `flake.nix` and
> `nanokvm.update.trustedPublicKeys` in `nixos/appliance.nix`, because that is
> what every device checks each NAR against. **The job fails loudly if they are
> absent** rather than publishing a manifest naming a closure no cache serves.
> The `.axp` is a complete image and needs no cache, which is why a cacheless
> release is still recoverable — by reflashing.

> **The release job needs binfmt.** The appliance is evaluated as a native
> `aarch64-linux` system. Nearly all of it substitutes prebuilt from
> `cache.nixos.org`, but its own configuration derivations (`etc`,
> `system-path`, the units, the system closure) are built on the runner, so the
> workflow installs the qemu handlers (`docker/setup-qemu-action`) and sets
> `extra-platforms = aarch64-linux`.

A failed run is recovered by re-running it from the Actions tab; never fix a
release by pushing to GitHub.

---

## Local testing

```bash
nix build .#system-manifest
cat result/nanokvm_pro_sys_latest.json
head result/closure.txt
```

The three gates that run in `nix flake check`:

```bash
nix build .#checks.x86_64-linux.nanokvm-updater-loop -L
nix build .#checks.x86_64-linux.nanokvm-update-idle -L
nix build .#checks.x86_64-linux.nanokvm-system-manifest -L
```

**`nanokvm-updater-loop`** (`nixos/lib/updater-test.nix`) runs the real
`nanokvm-update` against **real nix**: a real signed `file://` binary cache, two
real chroot stores (`--store local?root=...`), a real `nix copy`, `nix-env`,
`nix-collect-garbage` and `nix-store --verify`. Eight properties, in this order:

1. a closure signed by an **untrusted** key is refused ("lacks a signature by a
   trusted key"), nothing lands, the profile does not move, and
   `switch-to-configuration` never runs;
2. a manifest naming a non-store path is refused;
3. the closure substitutes and the profile advances to generation N+1;
4. `switch-to-configuration boot` is called — and `switch` never is;
5. a second update fetches **exactly the 2 paths it adds**;
6. re-installing the same closure fetches nothing;
7. `gc --keep 2` keeps the generation the **fallback** config names and the
   paths only it uses, because it was pinned by name before anything was
   deleted; `gc --keep 1` collects them once nothing names it;
8. the store passes `nix-store --verify --check-contents` after every step.

**`nanokvm-update-idle`** (`nixos/lib/update-idle-test.nix`) drives the policy
around that loop against a fake release host and a fake idle route on loopback:
an unticked checkbox installs nothing and is not an error; ticked-and-in-use
installs, writes both markers and does not reboot; a second update refuses to
stack on an unbooted one; the reboot timer waits while the room is full and
takes it when it empties; an **unreachable** idle route fails closed; the note
settles after the boot; ticked-and-idle installs and reboots in one run.

**`nanokvm-system-manifest`** (`pkgs/system-manifest-check.nix`) reads the
release artefact back: the manifest names **this commit's** appliance toplevel,
carries **this** `VERSION`, declares the format the updater installs, spells the
toplevel as a store path, and its `closure.txt` diffs clean against the
toplevel's real closure with a matching `closureCount`.

**What is stubbed, and it is only this.** `switch-to-configuration` is a stub
script that records its argv — the real one is an aarch64 binary that writes a
bootloader and refuses to run without `/etc/NIXOS`, and what these checks need
to know is that the updater *called* it, with `boot`, after the profile moved.
The toplevels are three tiny synthetic systems (input-addressed on purpose:
content-addressed paths are self-verifying, and `require-sigs` does not apply to
them, which would make the negative test a lie). The reboot is recorded in
`/run/nanokvm-reboot-requested` instead of taken. Everything else is the code
that runs on the board.

---

## What hardware still has to prove

Offline coverage stops at the sandbox boundary. Three board rounds, each ending
in a state the plug recovers from — a cold cycle clears `bootcount`, and a
candidate that does not come up is on the fallback config by the fourth attempt.
**None of them has been run: the board has no nix.**

**Round 1 — bootstrap.** A board with no nix cannot substitute a closure, so the
first nix-carrying generation goes over **by hand**. `nix copy --to ssh://`
needs nix on both ends and is therefore impossible here; the one-time recipe is
the tar + `nix-store --dump-db` hand copy in
`.claude/skills/kvm-device/SKILL.md` ("Bootstrapping a board that has no nix
yet"): ship the missing store paths as a plain tar, set the profile links the
way `nix-env --set` would, `switch-to-configuration boot`, reboot, **then**
`nix-store --load-db < registration`. Step 4 is not optional — a path the
database does not know is not a store path.

**Oracles**, after the reboot:

```sh
nix-store --verify --check-contents
nix path-info -r /run/current-system | wc -l        # the closure count
nix-env -p /nix/var/nix/profiles/system --list-generations
nanokvm-update status
devmem 0x02390030 32                               # 0xB0010000
```

Leaving `extlinux-fallback.conf` alone is the whole safety of this round: it
still names the old generation, so three failed attempts land back exactly where
the board started.

**Round 2 — a real update from a real cache.** Cut an alpha, let the release job
push the closure, and run `nanokvm-update check` then `update` on the board —
then the same thing again through the web UI's button, which is the only path
that exercises the server's `install()` handoff rather than the CLI. **If
Jeremy's attic is not up yet, a `file://` cache copied to the board or served
over HTTP from the build host is an acceptable stand-in** (`--cache` and
`--trusted-key` take both), and it proves everything except the attic endpoint
itself. **Oracles:** the signature check passing on a real NAR;
`readlink /run/booted-system` is the new toplevel; `bootcount` back to
`0xB0010000`; the journal showing `nix copy` fetching a small fraction of the
closure.

**Round 3 — rollback, then collection.** Force the counter rather than breaking
a generation — `devmem 0x02390030 32 0xB001000A; reboot` — and confirm the board
comes up on the **previous** generation with bit 30 of `0x02390024` set. Then
`nanokvm-update gc --keep 2`: the generation the fallback names must survive
with its exclusive paths, the one before it must not, `du -sh /nix/store` must
drop, and `nix-store --verify --check-contents` must still pass.

**Failure catch, every round:** the boot counter. Nothing above writes a
partition, so the worst outcome is a generation that does not come up, which
`altbootcmd` undoes on the fourth attempt. The plug is the backstop if even that
does not fire.

---

## Weighed and rejected

Recorded because the reasoning will be revisited.

**The nix daemon.** The standard deployment, and wrong here twice over. There is
one user and it is root, and nothing on this board builds, so the daemon buys a
socket, a unit, 32 `nixbld` accounts and a second process in the update path for
nothing — and it is the *weaker* of the two, because signature checking on a
daemon has a trusted-user bypass and a direct `LocalStore` does not.
Single-user is both smaller and stricter.

**A device-side substituter list instead of an explicit `nix copy --from`.**
Setting `nix.settings.substituters` and letting `nix-env --set` fetch would work
and would be shorter. Rejected because the trust would then come from
`/etc/nix/nix.conf` — a file an operator can edit, and a file a future NixOS
module could merge into. `nanokvm-update` passes the cache **and** the key list
on the command line, so what an update may install is fixed by the build, not by
the machine's config. (The configured substituter is still set, for an operator
debugging by hand; it is not what the updater relies on.)

**`nix.gc.automatic`.** nixpkgs' collector is age-based
(`--delete-older-than 30d`) with no generation count and, decisively, **no
notion of the fallback pin**. On this board the generation that must survive is
the one a text file in `/boot` names, which no nix root protects; an age-based
sweep would collect it on exactly the schedule that makes the rollback useless.
`nanokvm-update gc` pins first and deletes second.

**Putting the cache URL in the manifest.** It would make a release
self-describing and let the cache move without a device rebuild. Rejected
outright: **a release must not be able to redirect the device's trust.** The
cache and the keys are the device's own configuration; a manifest names a store
path and nothing else, which is exactly why a tampered one can only cause a
downgrade or a failure.

**Trimming nix's `aws-c-*` S3 libraries.** They are a real fraction of the
29.3 MiB nix costs, and `nix.package` can be overridden to drop them. Rejected
because the override makes nix a *build*, not a substitution — on aarch64, under
emulation, on every release runner. Tens of minutes per release to save single-
digit megabytes on a 29 GiB rootfs.

**Keeping a tarball fallback** for devices whose cache is unreachable. Rejected:
it would mean maintaining two payload formats, two installers and two integrity
stories forever, and the weaker of the two (a hash out of our own manifest) is
what #100 exists to delete. A device that cannot reach the cache does not
update; a device that cannot update is reflashed, which is a bench trip and not
a brick.

**Delta transport.** Not needed: `nix copy` *is* a delta. It asks the
destination store what it is missing and copies exactly that — the offline check
measures it at 2 paths for a two-path change.

**A/B kernel partitions.** The vendor layout's answer, and the minimal layout
deleted it deliberately (#89 rung 4): one `uboot`, one `atf`, no twins.
Reintroducing an A/B kernel pair would mean two 64 MiB partitions, a slot
register to arbitrate them and an SPL that knows about both — against two text
files in an ext4 `/boot` naming two generations.

**Rebooting as soon as the update is installed.** What every appliance
auto-updater does. Rejected because this appliance is a KVM: the one session an
unattended reboot is guaranteed to interrupt is somebody using the console to
fix a machine they cannot otherwise reach. Installing is free (nothing is live
until the restart), so the reboot is the only part that has to wait, and waiting
costs a marker file and a second timer.

**A NixOS option instead of a checkbox** (`nanokvm.update.auto`). Rejected on
Jeremy's instruction and for two mechanical reasons: the owner of the box never
sees the flake, and a device whose owner had ticked the box would still read
`auto = false` in the configuration that built it. A default the UI can override
needs tri-state storage plus a way to ship that default into the server, where
presence-or-absence of one file needs neither.

**Polling `main`.** A device that tracked the branch would get every commit,
including the ones that do not boot, and the rollback would then be the only
review step. Both channels are tags; the alpha channel is *prerelease* tags, so
"give me the new stuff early" and "give me whatever landed an hour ago" stay
different things.

**Letting the server decide the idle threshold.** The route reports raw counts
and takes `?quiet=<seconds>` from the caller, so `nanokvm.update.idleQuietSec`
is the only place the number lives and the same route can answer a UI that wants
to display the state.

**`switch-to-configuration switch` instead of `boot`.** Rejected: it activates a
userspace the boot counter has not vouched for, restarts `nanokvm.service`
underneath the HTTP request that asked for the update, and leaves no automatic
way back. The reboot *is* the test.

---

## Caveats

- **The cache and the keys are placeholders (#96).**
  `nanokvm.update.cacheUrl` and `nanokvm.update.trustedPublicKeys` are empty,
  `flake.nix`'s `nixConfig` carries `https://attic.invalid/nanokvm-pro` and a
  dummy key, and the release job's three attic secrets do not exist. The module
  emits a **build-time warning** when the cache URL is empty, and a second one
  when a cache is set with no keys; `nanokvm-update` refuses rather than
  installing anything unverified. Standing up the attic server and holding the
  signing key are Jeremy's.
- **An update cannot change the kernel** until #99 lands
  ([above](#rollback)). A kernel change is a reflash.
- **The URL is baked in twice.** `nanokvm.update.stableUrl` (the updater) and
  `updateBaseUrl` in `flake.nix` (the server, compiled in). Changing where you
  host means a rebuild — and for the server half, an update carrying the new
  binary or a reflash.
- **A mounted virtual-media image blocks the reboot for as long as it is
  mounted.** Intended — the host may be installing from it — but it is the one
  idle term that can stay true forever with nobody present. The update page
  names it, and *Restart now* overrides it.
- **An update needs a healthy boot.** `nanokvm-update update` refuses while
  `bootcount` is non-zero, i.e. before `nanokvm-mark-good` has run. Installing
  then would rewrite the config the counter is counting. `install-now` does not
  refuse, because the web UI's button is an explicit human action.
- **There is no downgrade check.** The updater takes what the channel offers
  rather than comparing semver, because "the channel" is a release we cut and
  the thing that catches a bad one is the boot counter, not a version test.
  Pointing a device at an older release is a deliberate downgrade and works.
- **Mirrored-tag trigger.** The release workflow fires only if the mirror's
  pushes come from a PAT/deploy-key identity. If a tag lands on GitHub and no
  run starts, check the mirror's auth identity before anything else.

---

## History

**The 4.19 rootfs-overlay OTA (#37 → 2026-09-10).** From #37 the shipping 4.19
image updated itself with `pkgs/update-package.nix`: a `nanokvm_pro_<ver>.tar.gz`
carrying a `rootfs/` overlay copied verbatim over `/`, plus an optional
`partitions/` set of vendor-format signed images written to both A/B slots, B
first, compare-first and read-back verified — hardware-proven end to end on
2026-08-16 with `v2.0.0`. It is gone because the product is the mainline NixOS
appliance and a store closure is not something an Ubuntu rootfs can apply, so
the 4.19 server build keeps an `install()` that refuses and points at AXDL
rather than falling back to the vendor's dpkg installer and its three CDN
`.deb`s. **There is no migration path from the vendor layout, by decision**
(Jeremy, 2026-09-10) — nobody runs the alpha releases, so a migration OTA would
have been built for no users; a vendor-layout board is reflashed over AXDL,
which is a bench trip and not a brick.

**The #86 tar system bundle (2026-09-10 → 2026-09-11).** Because the #78
appliance shipped `nix.enable = false`, an update had to be a ~460 MB
`nanokvm_pro_sys_<ver>.tar.gz` carrying the toplevel's entire closure as
ordinary directories, a `closure.txt` saying which paths belonged to it, and the
kernel its stage-1 initrd was baked into — unpacked into the store by hand, with
a `nanokvm-gc` that could only work from the per-generation closure lists the
installer had recorded and refused to run at all when one was missing. It lasted
one day, and it went because every one of those was a workaround for the missing
package manager: the transport downloaded 460 MB to change one package, the
closure lists were a database reimplemented badly, and a SHA-512 out of our own
manifest authenticated nobody. **Nix costs 29.3 MiB and deletes all three.**
The one thing #86 got right is still load-bearing: the seam between transport
and policy, which is why replacing the entire transport moved not one line of
the checkbox, the markers or the idle gate.
