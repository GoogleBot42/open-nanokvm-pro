---
name: kvm-device
description: SSH/SCP access and health-check for the NanoKVM-Pro test device — use whenever a task needs to reach, inspect, or copy files to the device.
---

Validated 2026-08-15 (both the connection helper and the health-check one-liner below were run read-only against the live device).

# Reaching the device

Use the wrapper scripts, never raw `ssh`/`scp`, so credentials never end up
typed into a tracked file or a shell history line that gets pasted somewhere
public:

- `tools/kvmssh '<remote command>'` — run a command on the device.
- `tools/kvmscp <local-files...> <remote-path>` — copy files to the device
  (remote path is a path on the device, e.g. `/tmp/`; the script adds the
  `root@<ip>:` prefix itself).

Both scripts read credentials from `~/.config/nanokvm/device.env` (chmod
600). Never inline the IPs or passwords into any tracked file — if you find
yourself typing an IP or password literal into a commit, stop and use the
wrapper instead.

# Health check

Proven one-liner (run via `tools/kvmssh '<the whole thing>'`):

```
uname -r; systemctl is-active kvmcomm nanokvm; curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1/; [ -b /dev/mmcblk1 ] && echo present || echo absent
```

What each part tells you:
- `uname -r` — kernel is up and SSH works at all.
- `systemctl is-active kvmcomm nanokvm` — exactly one of these two should be
  `active` and the other `inactive`. `nanokvm` active is the healthy state
  for our from-source stack; if `kvmcomm` is active instead, the web UI will
  not be reachable (see Gotchas below).
- `curl ... https://127.0.0.1/` — expect HTTP `200` from the web UI once
  `nanokvm.service` is up.
- `[ -b /dev/mmcblk1 ]` — whether an SD card is currently inserted. Absent is
  normal when the device is running from eMMC with no card in the slot.

# Gotchas

- **Two IPs.** The device is reachable over Tailscale or plain LAN; which one
  answers depends on network state at the moment. `tools/kvmssh`/`kvmscp`
  already try Tailscale first, then LAN — you don't need to pick.
- **Two passwords.** The device normally uses a configured password, but
  right after a fresh reflash it reverts to the vendor factory default. Both
  scripts try the configured password first, then the factory default — you
  don't need to know which state the device is in.
- **Web KVM requires `nanokvm.service`, NOT vendor `kvmcomm.service`.** The
  two stacks are mutually exclusive and fight over the same capture
  hardware; only one is ever meant to be active. Full comparison table and
  why the vendor default is wrong for us: `docs/architecture.md`,
  section "The two app stacks: nanokvm vs kvmcomm".
