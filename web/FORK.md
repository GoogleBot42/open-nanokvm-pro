# Downstream fork of the Sipeed NanoKVM-Pro web UI

This directory is a fork of the `web/` tree of
<https://github.com/sipeed/NanoKVM-Pro>, vendored into open-nanokvm-pro on
2026-09-05 at upstream commit `8d0557b400e20d18590b780df3b7faddb2a5588c`
(upstream tag `nanokvm@1.2.15`, 2026-06-12). The vendoring commit carries the
upstream content byte-for-byte; every later change is an ordinary commit in this
repository's history, not a patch on a pinned upstream.

License: GPL-3.0 (upstream's `LICENSE`, copied alongside). Copyright remains with
the upstream authors for their code; changes here are licensed the same way.

Build: `nix build .#nanokvm-web` (`pkgs/nanokvm-web.nix`, pnpm + Vite). The
lockfile `pnpm-lock.yaml` is pinned by the `pnpmDeps` hash in that derivation
— bump the hash when the lockfile changes.

## Surfaces this fork adds

**Settings → Check for Updates** (`src/pages/desktop/menu/settings/update/`):

- **Automatic updates** (`auto.tsx`) — a switch beside upstream's *Preview
  updates*, same shape, same kind of backing (`/etc/kvm/auto_updates`, presence
  = on). It is the only switch for unattended updates; there is no NixOS option
  behind it. `docs/updates.md`.
- **A pending-restart state** (`index.tsx`) — an automatic update installs
  immediately and reboots only when nobody is using the device, so the page
  shows `<from> -> <version>`, what the device is waiting for, and a **Restart
  now** button (the existing `POST /api/vm/system/reboot`). While a restart is
  owed it does not offer to install that version again.

**i18n:** new strings go in `src/i18n/locales/en.ts` only. i18next is configured
with `fallbackLng: 'en'` and falls back per key, which is why upstream's own
`previewDesc` exists in six of the twenty-two locale files and works in all of
them. Adding English text to the other twenty would be noise, not translation.
