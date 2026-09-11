# Cutting a release

How a version of this firmware is published, and what a release actually does. The
other half — how a device *takes* an update — is [updates.md](updates.md);
[building.md](building.md) is the outputs a release is made of.

**Forge topology:** the source of truth is Gitea
([git.neet.dev/zuckerberg/open-nanokvm-pro](https://git.neet.dev/zuckerberg/open-nanokvm-pro),
Tailscale-only, locked down). A **public downstream mirror** at
[github.com/GoogleBot42/open-nanokvm-pro](https://github.com/GoogleBot42/open-nanokvm-pro)
exists solely for public distribution: it receives every branch and tag through
Gitea's push mirror, its Actions build the release assets, and its Releases are what
devices poll (public, no tailnet needed). **Never create commits, tags, or edits on
GitHub directly** — all git data flows one way, Gitea → GitHub.

**A release publishes two files and pushes a third thing:** the manifest
`nanokvm_pro_sys_latest.json` (~200 bytes, naming a toplevel store path), the
flashable `.axp`, and — before either — the system closure itself, into the binary
cache. Publishing a release **is** the update push.

---

**First, write the release notes:** add a `## vX.Y.Z` section to `CHANGELOG.md`
(newest first), commit, push. `cut-release` and `tools/release` both refuse to tag a
version without one, and the release workflow lifts the section verbatim into the
release description.

**Primary path — the `cut-release` workflow on Gitea.** Actions → **cut-release** →
Run workflow → enter the version (e.g. `2.1.0`). The job
(`.gitea/workflows/cut-release.yml`) validates, writes `VERSION`, commits, tags,
pushes, and force-moves the rolling `preview` tag to the same commit — git work only,
no nix. A `dry_run` input validates without pushing. It is also dispatchable over the
API, which is how an agent cuts a release without a browser; always dry-run first:

```bash
TOK=$(grep -o 'token: .*' ~/.config/tea/config.yml | head -1 | cut -d' ' -f2)
curl -X POST -H "Authorization: token $TOK" -H 'Content-Type: application/json' \
  -d '{"ref":"main","inputs":{"version":"2.2.0","dry_run":"true"}}' \
  https://git.neet.dev/api/v1/repos/zuckerberg/open-nanokvm-pro/actions/workflows/cut-release.yml/dispatches
```

**204 means accepted, not succeeded.** Poll
`/api/v1/repos/zuckerberg/open-nanokvm-pro/actions/tasks?limit=1` for the run's
`status` and `conclusion`, then re-dispatch with `dry_run` `"false"`. The booleans are
passed as **strings**; a JSON boolean is rejected. **Fallback — locally:**
`echo 2.2.0 > VERSION`, commit, push, `tools/release`.

**Alpha releases:** any semver prerelease suffix — `2.2.0-alpha.1` — makes GitHub
publish it as a *prerelease*, which `releases/latest/download` never serves, while the
rolling `preview` release picks it up immediately. Devices with the web-UI **preview
updates** toggle on (`/etc/kvm/preview_updates`) get it; everyone else waits. The
server and `nanokvm-update` read that same flag file, so the button and the timer can
never install from different channels.

The push mirror then replicates the commit + tag to GitHub, and
`.github/workflows/release.yml` fires on the mirrored tag, checks `VERSION` == tag, and
does this in order:

1. build `.#appliance-toplevel` and `.#system-manifest`, asserting the manifest names
   what was just built;
2. **`attic push` the whole closure to the binary cache** — the payload, and it must
   land *before* the manifest: a manifest naming a path no cache has is an update
   every device on the channel fails;
3. build `.#nixos-firmware-image-mainline`;
4. publish `nanokvm_pro_sys_latest.json` on the release, refresh the rolling `preview`
   release with it, then upload the `.axp` separately with retries (GitHub's
   large-asset path intermittently 500s).

> **The push step needs three repository secrets, and they do not exist yet (#96).**
> `ATTIC_ENDPOINT`, `ATTIC_CACHE`, `ATTIC_TOKEN` — all Jeremy's to create, and the
> cache's **public** key has to match `nixConfig.extra-trusted-public-keys` in
> `flake.nix` and `nanokvm.update.trustedPublicKeys` in `nixos/appliance.nix`, because
> that is what every device checks each NAR against. **The job fails loudly if they
> are absent** rather than publishing a manifest naming a closure no cache serves. The
> `.axp` needs no cache, which is why a cacheless release is still recoverable — by
> reflashing.

> **The release job needs binfmt.** The appliance is evaluated as a native
> `aarch64-linux` system; nearly all of it substitutes prebuilt from
> `cache.nixos.org`, but its own configuration derivations (`etc`, `system-path`, the
> units, the system closure) are built on the runner, so the workflow installs the
> qemu handlers (`docker/setup-qemu-action`) and sets
> `extra-platforms = aarch64-linux`.

A failed run is recovered by re-running it from the Actions tab; never fix a release
by pushing to GitHub.

**Before a release, validate the fixed-output hashes** — a stale one is invisible on
any host that already holds the output, because the store path comes from the hash
alone and the fetch never re-runs. `nix build --rebuild` on the release-critical FODs
(`.#appliance-toplevel` pulls `nanokvm-server`'s `goModules`, whose vendor tree
depends on `postPatch` as well as `go.mod`). See
[building.md](building.md#pinned-hashes).
