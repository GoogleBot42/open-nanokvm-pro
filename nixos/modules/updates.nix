{ config, lib, pkgs, ... }:

# ===========================================================================
# How the device updates itself (#86, nix-native since #100): nix on the
# board, a signed closure substituted from a binary cache, an idle-gated
# reboot, and a collector that knows what the rollback still needs.
#
# ENABLES: `nanokvm-update` and its timer (the CHECK -- the automatic-updates
# checkbox in the web UI decides whether it installs), `nanokvm-update-reboot`
# (which waits until nobody is using the KVM), `nanokvm-gc`, and the nix
# settings that make all three safe: single-user, `require-sigs`,
# `max-jobs = 0`, no channels, and the trusted keys passed on the command line
# rather than read from /etc/nix/nix.conf.
#
# HARDWARE FACTS IT ENCODES: the board is a 1.2 GHz A53 with eMMC, so it never
# builds and never optimises the store; and it is the machine you are using to
# fix the machine, so an update installs whenever it likes but reboots only
# into an empty room.
#
# WHAT A CONSUMER MUST SET: `nanokvm.update.cacheUrl` and
# `nanokvm.update.trustedPublicKeys`, plus `nanokvm.update.stableUrl` if the
# channel is not ours. Empty (the shipped default until #96) means the device
# builds and boots but refuses to update, and says so at build time.
# ===========================================================================

let
  cfg = config.nanokvm;

  # ---- the updater (#86, nix-native since #100) ---------------------------
  # nixos/lib/updater.nix's header is the design; this is only the wiring.
  updateTools = import ../lib/updater.nix {
    inherit pkgs lib;
    # The SAME nix the system runs, so the tool cannot disagree with the store
    # it is writing into.
    nix = config.nix.package;
    stableUrl = cfg.update.stableUrl;
    previewUrl = cfg.update.previewUrl;
    manifestName = cfg.update.manifestName;
    keepGenerations = cfg.update.keepGenerations;
    cacheUrl = cfg.update.cacheUrl;
    trustedPublicKeys = cfg.update.trustedPublicKeys;
    idleQuietSec = cfg.update.idleQuietSec;
    # No server = nothing that could be using the device, so the idle gate is
    # satisfied by construction rather than by a curl that can only fail.
    idleUrl = lib.optionalString cfg.server.enable
      "https://127.0.0.1/api/update/idle";
    # A configured window means the install must never reboot on its own: the
    # window is enforced by `nanokvm-update-reboot`'s OnCalendar, and an
    # `update` that rebooted at install time would walk straight past it.
    rebootImmediately = cfg.update.rebootWindow == null;
  };
in
{
  options.nanokvm = {
    # ---- flake-based updates (#86, nix-native since #100) ---------------
    # This is a NixOS system and nix is on it, so an update is the standard
    # NixOS story: substitute the release's toplevel closure from our binary
    # cache, `nix-env --set` it, `switch-to-configuration boot`. What is ours
    # is the channel, the idle-gated reboot and the bootcount rollback.
    # nixos/lib/updater.nix is the implementation and docs/updates.md is the
    # design.
    update = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Ship `nanokvm-update` and its timers. The web UI's update button goes
          through the same tool (the server's install() override), so turning
          this off leaves a device that can only be updated by hand.
        '';
      };

      # THERE IS NO `auto` OPTION, and that is the design (#86). Automatic
      # updates are a CHECKBOX in the web UI -- a flag file, /etc/kvm/auto_updates,
      # beside the one the "preview updates" toggle already writes -- because
      # the person who owns the box is the person who decides whether it
      # updates itself, and they never see this file. A NixOS option would also
      # lie: the flake would read `auto = false` on a device that had been
      # updating itself for months. The timer therefore runs whenever `enable`
      # is set, and `nanokvm-update update` is a no-op while the box is
      # unticked.

      schedule = lib.mkOption {
        type = lib.types.str;
        default = "daily";
        description = ''
          systemd OnCalendar expression for the unattended check. The CHECK,
          not the reboot: an update installs whenever this fires and the
          checkbox is ticked, and reboots only once nobody is using the device
          (see `rebootWindow`).
        '';
      };

      rebootWindow = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "*-*-* 03..05:00/10:00";
        description = ''
          Maintenance window for the reboot half, as an OnCalendar expression.
          Null (the default) means any time, as soon as the device is idle:
          `nanokvm-update-reboot` runs every ten minutes.

          When set, THIS EXPRESSION IS THE TIMER -- so it has to fire
          repeatedly inside the window you want, not once at its start. The
          example above is every ten minutes between 03:00 and 05:00. Installs
          are unaffected; only the reboot waits.
        '';
      };

      idleQuietSec = lib.mkOption {
        type = lib.types.int;
        default = 600;
        description = ''
          How long the last web request and the last frame read must be in the
          past before the device counts as unused. The zero-valued terms of the
          idle test -- stream clients, HID sessions, web terminals, the
          mini-display preview lease, a mounted virtual-media image -- are not
          subject to it; this is the grace period on top of them.
        '';
      };

      # ---- the binary cache (#96) --------------------------------------
      # NEEDS-HUMAN, both of them: the attic server is Jeremy's to stand up and
      # the signing key is his to hold. Until they are filled in, a device
      # builds and boots but refuses to update, and the module says so at build
      # time (see `warnings` below) rather than letting it fail at 03:00.
      cacheUrl = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "https://attic.example.org/nanokvm-pro";
        description = ''
          The binary cache an update's closure is substituted from --
          `nix copy --from`. Anything nix can read works (an attic or harmonia
          endpoint, an S3 bucket, a plain `file://` directory, `ssh://` from a
          build host). It is NOT a substituter for the whole system: only
          `nanokvm-update` reads it, and only for the toplevel a release
          manifest names.

          Authenticity does not come from this URL. Every NAR must carry a
          signature by one of `trustedPublicKeys`, so a cache that is
          compromised, mirrored or simply wrong serves paths this device
          refuses.
        '';
      };

      trustedPublicKeys = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "nanokvm-pro:Ihqvn9…=" ];
        description = ''
          The keys an update's NARs must be signed by, in nix's
          `<name>:<base64>` form. `nanokvm-update` passes exactly these to
          `nix copy` as `trusted-public-keys` with `require-sigs = true` -- on
          the command line, not from /etc/nix/nix.conf, so nothing an operator
          adds to the machine's nix config can widen what an update will
          install.
        '';
      };

      stableUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://github.com/GoogleBot42/open-nanokvm-pro/releases/latest/download";
        description = ''
          Where the updater fetches the manifest. THE ONLY CHANNEL THIS DEVICE
          KNOWS since #101 -- the server used to carry a second one compiled
          into its binary, and one press of the update button read both. The
          Gitea source of truth is Tailscale-only, so devices poll the public
          GitHub mirror's releases.
        '';
      };

      previewUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://github.com/GoogleBot42/open-nanokvm-pro/releases/download/preview";
        description = ''
          The rolling preview channel, selected by the same flag file the web
          UI's "preview updates" toggle writes (`/etc/kvm/preview_updates`).
        '';
      };

      manifestName = lib.mkOption {
        type = lib.types.str;
        default = "nanokvm_pro_sys_latest.json";
        description = ''
          The manifest this system polls. Nothing else on the device names one
          any more: since #101 the web UI's version route and its update button
          both go through `nanokvm-update`, so they cannot poll a different
          place than this tool does.

          The `_sys_` name is what keeps the retired 4.19 channel
          separate: that image polls `nanokvm_pro_latest.json`, which nothing
          publishes any more, so it is offered nothing rather than being
          offered a store closure no Ubuntu rootfs could apply.
        '';
      };

      keepGenerations = lib.mkOption {
        type = lib.types.int;
        default = 3;
        description = ''
          How many generations `nanokvm-update gc` keeps. The booted system,
          the activated one and every generation a boot config names --
          above all the ROLLBACK one -- are pinned as nix gc roots on top of
          this, so a small number cannot strand the board.
        '';
      };

      gcSchedule = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
        description = ''
          systemd OnCalendar expression for the collector. Weekly is plenty:
          an update only leaves garbage behind when it lands, and the eMMC is
          large enough that a stale generation for a few days costs nothing.
        '';
      };
    };
  };

  config = {
    # ---- unattended updates (#86) ---------------------------------------
    # THE TIMER ALWAYS RUNS; THE CHECKBOX DECIDES WHAT IT DOES.
    # `nanokvm-update update` exits 0 immediately unless /etc/kvm/auto_updates
    # exists -- the file the web UI's "Automatic updates" switch writes, beside
    # the "preview updates" one. Gating the UNIT on a NixOS option instead
    # would mean the toggle could not take effect without a rebuild, which is
    # the opposite of what a checkbox is for.
    #
    # `Persistent` so a board that is off at the scheduled hour still checks
    # once it is back, rather than waiting a whole period.
    systemd.services.nanokvm-update = lib.mkIf cfg.update.enable {
      description = "Install the NanoKVM release this channel offers (reboots when idle)";
      after = [ "network-online.target" "nanokvm-mark-good.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${updateTools.updater}/bin/nanokvm-update update";
        # An update that fails must not take the board with it: every step
        # before the profile switch is a no-op on failure, and the boot config
        # is only rewritten once the store and /boot are complete.
        SuccessExitStatus = [ 0 ];
      };
    };

    systemd.timers.nanokvm-update = lib.mkIf cfg.update.enable {
      description = "Periodic NanoKVM update check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.update.schedule;
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
    };

    # ---- the reboot half, which is the whole point (#86) -----------------
    # An update installs the moment the timer above fires, but `switch-to-
    # configuration boot` makes nothing live until the board restarts -- and a
    # KVM is the machine you are using to fix the machine, so the restart waits
    # for an empty room. `update` leaves /run/nanokvm-update-pending when it
    # finds the device in use; this asks the server the same question again and
    # takes the reboot as soon as the answer is yes. It also settles the
    # persistent note left by an update that HAS booted, which is what lets the
    # web UI say "updated to X" on the other side.
    systemd.services.nanokvm-update-reboot = lib.mkIf cfg.update.enable {
      description = "Reboot into a pending NanoKVM update once nobody is using the device";
      after = [ "nanokvm-mark-good.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${updateTools.updater}/bin/nanokvm-update reboot-if-idle";
      };
    };

    systemd.timers.nanokvm-update-reboot = lib.mkIf cfg.update.enable {
      description = "Re-check whether a pending NanoKVM update may reboot the device";
      wantedBy = [ "timers.target" ];
      # `Persistent = false`: a missed re-check is nothing to catch up on. The
      # marker is still there and the next tick asks again; running a backlog of
      # them at boot would only ask the same question several times in a row.
      timerConfig = {
        Persistent = false;
      } // (if cfg.update.rebootWindow == null then {
        # OnBootSec settles the note from an update that just booted, within a
        # couple of minutes, so the UI stops showing a restart that has happened.
        OnBootSec = "2min";
        OnUnitActiveSec = "10min";
      } else {
        OnCalendar = cfg.update.rebootWindow;
      });
    };

    # ---- the collector (#100) --------------------------------------------
    # `nix-collect-garbage`, with the one thing nix cannot know pinned first:
    # the generation the ROLLBACK boot config names, which no profile link and
    # no /run symlink protects. `nanokvm-update gc` writes those pins as gc
    # roots BEFORE it deletes anything -- see the command in
    # nixos/lib/updater.nix.
    #
    # After `nanokvm-mark-good`, so a boot that is still on trial never
    # collects; and `Persistent`, because a board that was off on the scheduled
    # day should still tidy up once.
    systemd.services.nanokvm-gc = lib.mkIf cfg.update.enable {
      description = "Delete superseded NanoKVM generations and collect the store";
      after = [ "nanokvm-mark-good.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${updateTools.updater}/bin/nanokvm-update gc";
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.timers.nanokvm-gc = lib.mkIf cfg.update.enable {
      description = "Periodic NanoKVM store collection";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.update.gcSchedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };

    # =====================================================================
    # 7. Nix (#100)
    # =====================================================================
    # THIS IS A NixOS SYSTEM, SO NIX IS ON IT. The #78 appliance shipped
    # `nix.enable = false` and a fixed closure, and every consequence of that
    # had to be rebuilt by hand: a tar transport for the closure, a list of
    # which paths belong to which generation, and a collector that refused to
    # run whenever that list was missing. All three are gone. What the device
    # gains is the only thing it actually needed -- a store it can add a signed
    # closure to, and a collector that knows what is reachable.
    #
    # SINGLE-USER, NOT THE DAEMON. There is exactly one user here and it is
    # root, and nothing on this board ever builds. The daemon exists to
    # mediate between untrusted users and the store; with no untrusted users it
    # is a socket, a unit, 32 `nixbld` accounts and a second process in the
    # update path, for nothing. `store = auto` resolves to the local store
    # whenever /nix/var/nix is writable and no daemon socket exists, which is
    # the state this leaves the system in.
    #
    # AND IT IS THE STRICTER OF THE TWO. Signature checking on a direct
    # LocalStore has no trusted-user bypass: `require-sigs` applies to root the
    # same as to anyone, so `nix copy` cannot be talked into accepting an
    # unsigned NAR the way a trusted client of a daemon can.
    nix.enable = true;
    systemd.sockets.nix-daemon.wantedBy = lib.mkForce [ ];
    nix.nrBuildUsers = 0;
    # No channels, no registry, no NIX_PATH: nothing on this box evaluates
    # nixpkgs, and a channel is a second, mutable source of truth for a system
    # whose whole point is that its generation came from a tagged release.
    nix.channel.enable = false;
    # nixos-rebuild / nixos-install / nixos-generate-config would all be lies
    # here (there is no nixpkgs to evaluate, and a rebuild is a release), and
    # they are not small.
    system.disableInstallerTools = true;

    nix.settings = {
      # The release cache, so `nix copy --from` has a default and an operator
      # debugging by hand gets the same source the updater uses. Not a
      # substituter for cache.nixos.org's sake: this device builds nothing, so
      # the only thing it ever fetches is a release closure.
      substituters = lib.mkForce (lib.optional (cfg.update.cacheUrl != "") cfg.update.cacheUrl);
      trusted-public-keys = lib.mkForce cfg.update.trustedPublicKeys;
      require-sigs = true;
      # THE BOARD NEVER BUILDS. An update is a closure someone else built; a
      # derivation that somehow got realised here would take minutes per
      # package on a 1.2 GHz A53 and wear the eMMC doing it.
      max-jobs = 0;
      sandbox = false;
      # eMMC. Store optimisation rewrites every duplicate file as a hardlink,
      # which is a full store walk and a lot of small writes to buy back space
      # on a device whose store holds three generations of one closure.
      auto-optimise-store = false;
      experimental-features = [ "nix-command" ];
      # Only root exists; spelling it out keeps a future user from inheriting
      # the ability to add paths to the store.
      allowed-users = [ "root" ];
      trusted-users = [ "root" ];
    };

    # mkOrder pins where these land in the one merged list (#87).
    systemd.tmpfiles.rules = lib.mkOrder 200 [
      # The updater's state: one file, `update-pending`, which survives the
      # reboot so the UI can say what happened on the other side of it. The
      # per-generation closure lists that used to live here are gone -- nix
      # knows what a generation needs (#100).
      "d /var/lib/nanokvm 0755 root root - -"
      # Where a release closure is pinned as a gc root while it is installed.
      "d /nix/var/nix/gcroots/nanokvm 0755 root root - -"
    ];

    environment.systemPackages =
      lib.mkOrder 400 (lib.optional cfg.update.enable updateTools.updater);

    warnings =
      lib.optional (cfg.update.enable && cfg.update.cacheUrl == "")
        ''
          nanokvm.update.cacheUrl is empty: this system can be built and booted
          but cannot update itself (#96 -- the attic endpoint is Jeremy's to
          stand up). `nanokvm-update update` will refuse rather than install
          anything unverified.
        ''
      ++ lib.optional (cfg.update.enable && cfg.update.cacheUrl != "" && cfg.update.trustedPublicKeys == [ ])
        ''
          nanokvm.update.cacheUrl is set but nanokvm.update.trustedPublicKeys is
          empty. Nothing will install: every NAR must be signed by a key this
          system trusts, and this system trusts none.
        '';
  };
}
