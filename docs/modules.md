# Building your own NanoKVM-Pro image

This flake exposes the NanoKVM-Pro as a set of NixOS modules, the way
[nixos-hardware](https://github.com/NixOS/nixos-hardware) exposes a laptop.
Import one attribute and you get a bootable board: mainline kernel, our device
tree, the extlinux generations, the rollback gate, the capture stack, the
mini-display, ATX, WiFi, the updater and NanoKVM-Server. Everything that makes
the image *ours* — sshd, mDNS, the root password, the journal cap, the
interactive package set — lives in `nixos/appliance.nix` and is **not** part of
the modules.

Our appliance is one consumer of them. So is `checks.nixos-modules-consumer`,
a minimal configuration built on every `nix flake check` precisely so this page
cannot rot.

## Twenty lines

```nix
{
  inputs.nanokvm.url = "git+https://git.neet.dev/zuckerberg/open-nanokvm-pro";

  outputs = { self, nixpkgs, nanokvm }: {
    nixosConfigurations.my-kvm = nixpkgs.lib.nixosSystem {
      modules = [
        nanokvm.nixosModules.nanokvm-pro
        {
          system.stateVersion = "26.11";
          networking.hostName = nixpkgs.lib.mkForce "my-kvm";
          users.users.root.initialPassword = "change-me";
          services.openssh.enable = true;

          # Where YOUR releases come from (see "Updates" below).
          nanokvm.update.cacheUrl = "https://cache.example.org/my-kvm";
          nanokvm.update.trustedPublicKeys = [ "my-kvm:…=" ];
        }
      ];
    };
  };
}
```

`nix build .#nixosConfigurations.my-kvm.config.system.build.toplevel` gives the
system closure; `…config.system.build.axpImage` gives a flashable `.axp` — but
only if you also import the image module, which needs the packer. Copy
`nixos/image-axp.nix`'s wiring out of `flake.nix` for that, or build
`.#nixos-firmware-image-mainline` from this repo and replace the rootfs member.

**The flake evaluates on `x86_64-linux` only**, and the modules carry builds
instantiated from that host's package set (the vendor's `ax_gzip` packer is an
x86-64-only static ELF). The *system* they describe is `aarch64-linux`, built
here through binfmt/qemu-user.

## What each module is

| `nixosModules.…` | Enables | Hardware fact it encodes |
|---|---|---|
| `kernel` | `boot.kernelPackages` (mainline 7.1.x), the `dts/` device tree, NixOS's extlinux builder as the only writer of `/boot`, the kernel command line, scripted stage 1 with the `panicOnFail` deadman, the loop-device mapping for the GPT inside `disk`, `/` and `/boot` | arm64; 512 MiB usable of 1 GiB; a hidden unterminated UART0 pad, so U-Boot must never prompt and stage 1 must never block on a read; three SD4HC instances race, so the eMMC is pinned by a DT alias and split by `blkdevparts=` |
| `identity` | `nanokvm-identity.service` (MAC + transient hostname from the SoC UID), networkd with `ClientIdentifier = mac`, `/etc/fw_env.config` | every board carries a unique 64-bit UID at physical `0x740`; the vendor firmware has always derived the MAC and hostname from it, so anything else loses the DHCP reservation |
| `rollback` | `nanokvm-mark-good` (clears the boot counter, derives `extlinux-fallback.conf`), `nanokvm-checkboot`, `nanokvm-uboot-test`, systemd's watchdog | U-Boot counts attempts in `0x02390030` and takes `altbootcmd` past `bootlimit = 3`; WDT0's own timeout is 60 s; with no console, an unattended rollback is the only way back |
| `video` | `nanokvm-video.service` — the open capture + VC8000E modules, then `/dev/video0` | the modules come out of the same kernel derivation the generation boots; a clean insmod proves nothing, so the video node is the oracle |
| `display` | `nanokvm-panel.service` (fbtft + JD9853), `nanokvm-display.service` (the status screen) | JD9853 on spi2 with the backlight on PWM0; ~560 ms of power-on mdelay, which is why it is a module; never unload it |
| `atx` | `nanokvm-gpio` on `PATH`. No unit — that is the result, not a gap | the four lines are named in the device tree, and *requesting* one makes the pin controller program the pad (which retires the SW_PWR pinmux trap); global GPIO numbers are not stable on mainline |
| `wifi` | the out-of-tree AIC8800 modules, the MD5-pinned radio firmware, wpa_supplicant on `wlan0`, and the `/kvmcomm/scripts/wifi.sh` the server execs | the radio is optional hardware: every dead end is a journal line and `exit 0`, never a failed unit |
| `updates` | `nanokvm-update` + timer, the idle-gated reboot, `nanokvm-gc`, and nix configured single-user with `require-sigs` and `max-jobs = 0` | a 1.2 GHz A53 with eMMC never builds and never optimises the store; and a KVM is the machine you fix the machine with, so it reboots only into an empty room |
| `server` | `nanokvm.service` (from a tmpfs copy of `/kvmapp`), `nanokvm-appdir`, `nanokvm-cert`, the USB-gadget stub, logrotate, the `ssh.service` alias, the interactive package set | the binary's contract: a store-free `DT_RUNPATH`, a dlopened `libkvm` that needs `DT_RPATH`, a dozen bare-name `exec.Command`s, and a `readlink` on `/etc/localtime` that expects `/usr/share/zoneinfo/` |
| `packages` | nothing by itself — it carries this flake's cross builds as the module argument `nanokvm` | — |
| `nanokvm-pro` | all nine plus `packages`. **This is the entry point.** | |
| `default` | `nanokvm-pro` | |

The nine areas are exported individually for anyone who wants only part of the
board. Each needs `nixosModules.packages` imported **exactly once** beside it:

```nix
imports = [ nanokvm.nixosModules.packages
            nanokvm.nixosModules.kernel
            nanokvm.nixosModules.video ];
```

Importing `packages` twice — or beside `nanokvm-pro`, which already contains it
— is a `_module.args.nanokvm` conflict, because that option is
`lazyAttrsOf raw` and two definitions of one argument cannot merge.

## What a consumer must set

Nothing, to get something that boots. In practice:

- **`system.stateVersion`** — ours is the appliance's, not the board's.
- **`networking.hostName`** — the identity module leaves it `mkDefault ""` and
  that is load-bearing: `systemd-hostnamed` refuses a transient hostname when a
  static one is set, so the UID-derived name would never take. If you want a
  fixed name, `mkForce` it and accept that `nanokvm-identity` will log a
  warning instead of renaming the box.
- **`nanokvm.update.cacheUrl` and `nanokvm.update.trustedPublicKeys`** — empty
  by default, which means the device builds and boots but refuses to update,
  and says so at build time. Point them at *your* cache and *your* key;
  `nanokvm.update.stableUrl` is where the manifest is fetched from.
- **`users.users.root.*`, `services.openssh.*`** — the modules run no sshd. A
  board with no login and no console is a board you cannot reach.
- **Anything optional you do not have.** `nanokvm.wifi.enable`,
  `nanokvm.panel.enable`, `nanokvm.videoStack.enable`, `nanokvm.server.enable`,
  `nanokvm.markGood.enable`, `nanokvm.ubootTest.enable` are all `true` by
  default and all turn the corresponding half of the closure off.

Every option is documented where it is declared; `nanokvm.<area>.*` names the
module that owns it.

## Two options are order-sensitive

`environment.systemPackages` and `systemd.tmpfiles.rules` are lists, and both
are hashed **in order** into a derivation — the system path's `buildEnv` and
`/etc/tmpfiles.d/00-nixos.conf`. Six of these modules contribute to them, so
each wraps its definition in `lib.mkOrder`. If you add a module of your own
that contributes to either, give it an order above 500 (the server module's) or
accept wherever the import list puts it. This is why splitting the appliance
into nine files did not change a single store path.

## Upstreaming status

**Nothing is submitted, and nothing should be yet.** The blocker is the vendor
prefix, not our code ([mainline-port.md §1](mainline-port.md#community)):

- Nothing Axera is merged: `torvalds/linux` at v7.3-rc1 has no
  `arch/arm64/boot/dts/axera/`, no `axera` in `vendor-prefixes.yaml`, nothing
  in `MAINTAINERS` or `drivers/soc/`; neither does linux-next.
- A vendor series exists for a *different* SoC — *"arm64: Introduce Axera AX650
  SoC and AX650 Demo board"*, v2 of 2026-09-01 — and it is stalled on exactly
  the question that decides our binding names: Krzysztof Kozlowski questioned
  the `axera,` prefix (`axera.com` is not theirs), the author promised
  `axera-tech,` for v2 and then kept `axera,`, and the only review reply to v2
  is *"So how did you implement own comment?"*. No v3.
- AX630C / AX620E / AX620Q have **never** been mentioned on LKML or
  linux-arm-kernel. All 19 Axera messages ever on LKML are that one thread.
- U-Boot: nothing, ever. No `axera`/`ax6*` path in v2026.07, no list thread.

So: if the AX650 series lands, `ARCH_AXERA` and the dts directory exist and an
`ax630c.dtsi` drops in beside `ax650.dtsi`. If it dies, we would be first.
Either way the prefix spelling is unsettled, our compatibles are kept behind a
single macro, and submitting bindings now would mean rewriting them. The
modules in this repo are the deliverable in the meantime.

Note that both Sipeed's and M5Stack's trees carry files with an SPDX `GPL-2.0`
tag *and* an Axera "may not be copied or distributed" header — worth a legal
skim before vendoring text, and the reason this project reverse-engineers
through describing subagents rather than from vendor source.

## Where the rest is written down

- [nixos-rootfs.md](nixos-rootfs.md) — the boot contract, `/boot`, identity,
  the known gaps. Read it before changing `kernel` or `rollback`.
- [architecture.md](architecture.md) — boot chain, the video pipeline, the
  service model.
- [updates.md](updates.md) — channels, signing, rollback, GC.
- [mainline-port.md](mainline-port.md) — the port itself, and §11.10 for the
  device contract.
- The module headers. Each says what it enables and which hardware fact it
  encodes, and several carry the hardware round that discovered the fact.
