# nix-nanokvm-pro

From-source Nix rebuild of the Sipeed NanoKVM-Pro (AX630C) firmware. Start with
`README.md` (build/flash quick start) and `docs/architecture.md`; the `docs/` tree is
authoritative and kept current — `../PLAN.md` is a frozen early research log.

Traps that cost real debugging time (details live in the docs — don't re-derive):

- `libkvm.so` needs `patchelf --force-rpath` (DT_RPATH, not DT_RUNPATH); a binary that
  works from an SSH shell but crash-loops under systemd is this. See
  `docs/architecture.md` ("Load-bearing linker detail") and `pkgs/kvm-encoder.nix`.
- Vendor `ax_*.ko` modules require an exact vermagic match — `docs/building.md`.
- The device must run `nanokvm.service`, not the vendor `kvmcomm.service`, or the web
  UI is down — `docs/architecture.md` ("The two app stacks").
- eMMC is `/dev/mmcblk0`, SD is `/dev/mmcblk1`; never write mmcblk0 during SD testing —
  `docs/flashing-and-recovery.md`.

Repo hosting: the only forge is Gitea (`git.neet.dev/zuckerberg/open-nanokvm-pro`).
GitHub URLs in `flake.nix` (`updateBaseUrl`), `docs/updates.md`, and
`.github/workflows/release.yml` are stale; the OTA/release pipeline is pending
migration to Gitea releases.

Commit as you work and push after committing — don't leave finished work sitting.
Never commit device IPs, passwords, or other credentials.
