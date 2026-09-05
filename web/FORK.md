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
