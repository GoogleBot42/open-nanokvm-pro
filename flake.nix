{
  description = "Self-built open firmware for the Sipeed NanoKVM-Pro (Axera AX630C): boot chain, kernel, and app layer from source; Axera's redistributable media libraries and ax_*.ko modules pinned as binary inputs";

  # ---- the release binary cache (#96) ------------------------------------
  # NOT WIRED UP HERE YET, ON PURPOSE. Nobody should have to build a cross
  # toolchain, a kernel, U-Boot and an appliance closure to get an image -- and
  # the appliance substitutes its updates from the same cache (#100), signed by
  # the same key. The flake half of that is four lines:
  #
  #   nixConfig = {
  #     extra-substituters = [ "https://<attic host>/nanokvm-pro" ];
  #     extra-trusted-public-keys = [ "nanokvm-pro:<base64>" ];
  #   };
  #
  # A PLACEHOLDER URL HERE IS NOT FREE, which is why there is not one. A
  # substituter in `nixConfig` is contacted for every path every build on every
  # host is missing, the release runner's included; an unreachable one buys a
  # warning or a connect timeout per path, for nothing, on everybody. An
  # unreachable substituter is worse than no substituter, so this stays a
  # comment until the endpoint and the key exist.
  #
  # When they do, they land in THREE places (docs/releasing.md): here, the
  # release workflow's `ATTIC_*` secrets, and
  # `nanokvm.update.{cacheUrl,trustedPublicKeys}` in nixos/modules/updates.nix -- the
  # device's own trust, which does not read this file. The appliance-side
  # defaults stay empty in the meantime and the module warns at build time,
  # because there the placeholder's cost is a device that quietly cannot update
  # rather than a slower build for everyone.

  inputs = {
    # ONE nixpkgs pin. There used to be a second, older one (nixos-24.11) for
    # the NixOS rootfs alone, because systemd's declared minimum kernel had
    # risen to 5.4 and then 5.10 while the ax_*.ko vermagic contract held this
    # board on Linux 4.19.125. Both halves of that argument are gone -- the
    # image has carried no vendor kernel module since #54, and the appliance
    # boots pkgs/kernel-mainline (7.1.x) since #78 -- so the appliance is back
    # on this pin and `nixpkgs-rootfs` is retired. docs/nixos-rootfs.md.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Upstream Sipeed / Axera source repos, pinned by commit (`flake = false`
    # plain trees). No release tags exist upstream; these are main-branch
    # commits matching the on-device V3.0.0_20250319 SDK.

    # The vendor SDK snapshot. Nothing here builds the vendor PRODUCT any more
    # (#97): what is still read out of this tree is the bl1/SPL source
    # `.#spl-minimal` recompiles for our layout, the `imgsign` signing tool
    # `pkgs/ax-sign.nix` drives, and the two FDL download agents the AXDL
    # flasher pushes into BootROM RAM (pkgs/boot.nix).
    maix_ax620e_sdk = {
      url = "github:sipeed/maix_ax620e_sdk/45ebcc32dfcfade1f8cfd1d8f70da67b86ea2902";
      flake = false;
    };

    # The V3.0.0 Axera media HEADERS (ax_base_type.h, ax_venc_comm.h, ...).
    # Our blob-free libkvm still compiles against them for the SDK's frame and
    # stream types; NO library out of this tree is linked or shipped, and
    # nixos/modules/server.nix asserts the closure carries none of it.
    maix_ax620e_sdk_msp = {
      url = "github:sipeed/maix_ax620e_sdk_msp/1bd333bc5ec074b868107102889044e79209771d";
      flake = false;
    };

    # App layer (GPL-3.0): server/ (Go + cgo -> libkvm.so). The web UI is our
    # own fork in ./web (web/FORK.md) and no longer comes from this input.
    nanokvm-pro-src = {
      url = "github:sipeed/NanoKVM-Pro/8d0557b400e20d18590b780df3b7faddb2a5588c";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , ...
    }@inputs:
    let
      # The firmware targets aarch64-linux but must be built from an
      # x86_64-linux dev box: the vendor's ax_gzip partition packer is an
      # x86-64-only static ELF (pkgs/boot.nix), so every flashable output is
      # x86_64-only. The cross set below handles the aarch64 target.
      supportedSystems = [ "x86_64-linux" ];

      # Release identity for the OTA / web-update system (docs/updates.md).
      # `version` comes from ./VERSION (first token) — the single source of
      # truth that `tools/release` tags from — and is stamped into
      # /kvmapp/version and the update manifest.
      #
      # THE CHANNEL IS NOT HERE ANY MORE (#101). It used to be, as
      # `updateBaseUrl`/`previewUpdateBaseUrl` compiled into NanoKVM-Server —
      # a second source of truth beside `nanokvm.update.stableUrl`, which is
      # what actually installs. The server now asks `nanokvm-update` instead,
      # so the only channel a device knows is the one in its own NixOS
      # configuration (nixos/modules/updates.nix).
      version =
        let m = builtins.match "[[:space:]]*([^[:space:]]+).*" (builtins.readFile ./VERSION);
        in if m == null then "0.0.0-dev" else builtins.head m;

      perSystem = flake-utils.lib.eachSystem supportedSystems (
        localSystem:
      let
        pkgs = import nixpkgs { system = localSystem; };

        # aarch64/glibc cross set. Everything that runs on the board is built
        # through it; the flake itself only evaluates on x86_64-linux.
        crossPkgs = pkgs.pkgsCross.aarch64-multiplatform;

        project = "AX630C_emmc_arm64_k419_sipeed_nanokvm";

        # Shared arguments handed to every derivation file.
        callArgs = {
          inherit pkgs crossPkgs inputs;
          inherit (inputs)
            maix_ax620e_sdk
            maix_ax620e_sdk_msp
            nanokvm-pro-src;
        };

        callPkg = path: extra: import path (callArgs // extra);

        # The same, but overridable. `boot.kernelPackages`'s `apply` in
        # nixos/modules/system/boot/kernel.nix calls `kernel.override`, so the
        # kernel -- and only the kernel -- has to be instantiated through
        # `makeOverridable` rather than a bare `import` (#99).
        callPkgOverridable = path: extra:
          pkgs.lib.makeOverridable (import path) (callArgs // extra);

        toolchain = callPkg ./pkgs/toolchain.nix { };

        # The Axera media HEADERS (see the input). The last thing this project
        # takes from the vendor userspace: our blob-free libkvm compiles
        # against the SDK's frame/stream types. No library out of it is linked
        # into the appliance and none reaches the image.
        axera-libs = callPkg ./pkgs/axera-libs.nix { };

        # The vendor boot chain, built from source. Nothing BOOTS from it any
        # more (#97): the appliance runs mainline TF-A and mainline U-Boot off
        # a blob-free SPL. Two things still come out of this derivation --
        # the FDL1/FDL2 download agents the AXDL flasher pushes into BootROM
        # RAM (nixos/axp-image.nix), and the vendor `atf_bl31_signed.bin` the
        # `atf-mainline` check compares its own header against field for field.
        boot = callPkg ./pkgs/boot.nix { };

        # The stored U-Boot environment (the `env` partition), generated from
        # the MAINLINE U-Boot's own compiled-in default (#89 rung 3), so the
        # partition and the binary cannot disagree.
        uboot-env = callPkg ./pkgs/uboot-env.nix { uboot = uboot-mainline; };

        # /boot, and since rung 3 the whole boot payload: mainline U-Boot's
        # bootcmd runs `sysboot ... /extlinux/extlinux.conf` off this
        # partition, so the kernel, the initrd and the device tree ride in it
        # rather than in the signed `kernel`/`dtb` partitions the vendor chain
        # loaded by byte offset.
        #
        # SINCE #99 NOTHING HERE GENERATES THAT TREE. `payloadDir` is the
        # directory NixOS's own extlinux builder wrote for the generation being
        # imaged (nixos/lib/appliance-artifacts.nix, `mkBootDir`), so the image
        # and a `switch-to-configuration boot` on the device produce /boot of
        # the same shape from the same program.
        #
        # SIZE COMES FROM THE LAYOUT (#89 rung 4): 272 MiB of ext4.
        # nixos/lib/emmc-layout.nix is the single definition.
        mkBootfs = bootDir:
          let l = import ./nixos/emmc-partitions.nix { inherit (pkgs) lib; };
          in
          callPkg ./pkgs/bootfs.nix {
            inherit version;
            size = l.bootfs.size;
            payloadDir = bootDir;
            # Read off the system being imaged, so the headroom assertion can
            # never be computed from a different number than the bootloader's.
            configurationLimit =
              nixos-appliance-mainline-chain.eval.config
                .boot.loader.generic-extlinux-compatible.configurationLimit;
          };
        bootfs = mkBootfs nixos-appliance-mainline-chain.bootDir;

        # Mainline TF-A BL31 with our own plat/axera/ax630c (#89 rung 0),
        # signed for the `atf` partition exactly like the vendor BL31 was.
        atf-mainline = callPkg ./pkgs/atf-mainline.nix { inherit boot; };

        # The same BL31 plus seven milestone-bit writes (#89 rung 1). A
        # debugging tool, never a shipped image: it writes the A/B slot
        # register. See pkgs/atf-mainline.nix.
        atf-mainline-debug = callPkg ./pkgs/atf-mainline.nix {
          inherit boot;
          debugMilestones = true;
        };

        # Bring-up initramfs for the mainline kernel (#75): one static init
        # whose only job is to leave evidence that userspace ran, in places a
        # later boot can read back. Nothing shipped embeds an initramfs.
        initramfsMainline = callPkg ./pkgs/initramfs-mainline.nix { };

        # The kernel, built from the kernel.org tree our nixpkgs pin carries,
        # with our own config fragment, our own drivers grafted in
        # (pkgs/kernel-mainline/tree/) and our own device tree (dts/, compiled
        # by pkgs/dtb-mainline.nix).
        #
        # This is the BRING-UP variant: it carries the #75 evidence initramfs
        # and reboots itself. Nothing else embeds an initramfs -- see
        # `kernel-mainline-appliance` below.
        kernel-mainline = callPkg ./pkgs/kernel-mainline.nix {
          inherit initramfsMainline;
        };

        # THE APPLIANCE'S KERNEL, and it embeds NOTHING (#99). It is
        # `boot.kernelPackages` for the appliance, so the initrd and the
        # dtb that go with it are the GENERATION's -- NixOS's extlinux builder
        # copies all three into /boot and U-Boot loads them. One kernel for
        # every root variant, because the initrd is no longer inside it.
        #
        # Overridable, because `boot.kernelPackages` insists on calling
        # `.override` (see callPkgOverridable).
        kernel-mainline-appliance = callPkgOverridable ./pkgs/kernel-mainline.nix {
          initramfsCpio = null;
          variant = "appliance";
        };

        # The video stack's modules, copied out of that kernel (#83). A
        # BUILD-time dependency on it, so the appliance's closure carries the
        # ~280 KB of .ko rather than a second reference to the Image.
        #
        # #83 had to write a careful note here about not creating a cycle: the
        # kernel embedded that configuration's initrd, and the configuration
        # loaded these modules. #99 removed the first half -- the kernel is a
        # function of nothing but its own sources now -- so the dependency runs
        # one way and the generation's kernel and its modules are built from
        # the same derivation by construction.
        video-modules = callPkg ./pkgs/video-modules.nix {
          kernel = kernel-mainline-appliance;
        };

        # The mini-display's panel modules (#84), out of the same kernel. A
        # second package rather than more entries in the one above: the two
        # sets are loaded by different units with different oracles, and a
        # panel that did not come up must not read as a capture failure.
        display-modules = callPkg ./pkgs/display-modules.nix {
          kernel = kernel-mainline-appliance;
        };

        # --- WiFi (#85) ------------------------------------------------------
        # The AIC8800 on mmc@104d0000. The DRIVER is GPL source, pinned from
        # radxa-pkg/aic8800 and built out of tree against the appliance
        # kernel's KDIR; the FIRMWARE is the one piece of closed content the
        # blob policy permits, MD5-pinned to AICsemi's own manifest. Neither is
        # in any image unless `nanokvm.wifi.enable` is on (nixos/modules/wifi.nix).
        aic8800-src = callPkg ./pkgs/aic8800-src.nix { };
        aic8800-firmware = callPkg ./pkgs/aic8800-firmware.nix { inherit aic8800-src; };
        aic8800 = callPkg ./pkgs/aic8800.nix {
          kernel = kernel-mainline-appliance;
          inherit aic8800-src;
        };

        # The open capture and VC8000E encode drivers live IN the kernel tree
        # now (pkgs/kernel-mainline/tree/drivers/media/platform/axera) and come
        # out of it as `video-modules` above. The out-of-tree 4.19 builds they
        # grew up as -- `.#open-vin-csi2`, `.#open-vin-capture`,
        # `.#vc8000-vcmd` -- are gone with the 4.19 image (#97); their history
        # is docs/deblob-capture.md and docs/vcmd-cma-unblock.md.

        # Open VC8000E userspace submitter -- userspace half of the blob-free
        # encoder (#45). Stage A (ewl_probe) drives the full VCMD cmdbuf
        # lifecycle from userspace and is device-proven. Its register-program
        # sources are shared with libkvm's encoder. See pkgs/vcenc-ewl.nix.
        vcenc-ewl = callPkg ./pkgs/vcenc-ewl.nix { };

        # Mainline device tree, compiled from dts/ in this repo (#74).
        dtb-mainline = callPkg ./pkgs/dtb-mainline.nix { inherit kernel-mainline; };

        # THE A/B SLOT PACKAGING IS GONE (#97). There is one copy of every
        # boot-chain stage, the kernel and the device tree ride in the NixOS
        # generation on /boot, and a U-Boot candidate is tried through the
        # one-shot chainload slot rather than by writing a `_b` partition.
        # docs/flashing-and-recovery.md.

        # libkvm.so -- THE ONE BUILD, and it is blob-free (#60): the open V4L2
        # capture driver feeding the open VC8000E encoder, linking no vendor
        # library at all. The closed-backend variants that selected the vendor
        # MPI capture path or AX_VENC are gone with the 4.19 image (#97); their
        # record is docs/blob-replacement.md.
        kvm-encoder = callPkg ./pkgs/kvm-encoder.nix {
          inherit axera-libs; openCapture = true; openVenc = true; v4l2Capture = true;
        };
        # Host-side 1080p byte-identity proof for the open backend's parametric
        # geometry (#17). See pkgs/kvm-encoder-geom-test.nix.
        kvm-encoder-geom-test = callPkg ./pkgs/kvm-encoder-geom-test.nix { };
        # Host-side geometry-law proof for the open ENCODER (#17): 17 golden
        # vendor vectors + 1080p template identity. See pkgs/vcenc-geom-test.nix.
        vcenc-geom-test = callPkg ./pkgs/vcenc-geom-test.nix { };
        # Host-side proof of the from-scratch rate controller (#46): vendor
        # trajectory replay + closed-loop simulation. See pkgs/vcenc-rc-test.nix.
        vcenc-rc-test = callPkg ./pkgs/vcenc-rc-test.nix { };
        # ATX power/reset/LED tool (#81): resolves a line by its dts/
        # gpio-line-names entry over libgpiod v2, and the request programs the
        # pad mux. Replaces the vendor-era sysfs export unit, the devmem pad
        # poke and the server's per-press pinmux re-assert.
        nanokvm-gpio = callPkg ./pkgs/nanokvm-gpio.nix { };

        # NanoKVM-Server (Go + cgo). ATX lines through nanokvm-gpio, and the
        # web UI's update button hands off to `nanokvm-update` -- one channel,
        # the device's own (#101).
        nanokvm-server = callPkg ./pkgs/nanokvm-server.nix {
          inherit kvm-encoder nanokvm-gpio;
        };

        nanokvm-web = callPkg ./pkgs/nanokvm-web.nix { inherit version; };

        # Mini-display status daemon (pure Python + build-time-generated
        # fonts). The panel's kernel modules are `display-modules` above.
        nanokvm-display = callPkg ./pkgs/nanokvm-display.nix { };

        # Host-side USB flasher (axdl-cli): pushes a .axp onto an AX630C in
        # BootROM download mode. Built for the local system, not cross-compiled.
        axdl = callPkg ./pkgs/axdl.nix { };

        # Clean-room EDID set for the LT6911UXC front-end (from source; distinct
        # per-mode identity + edid-decode --check clean). See pkgs/edid.nix.
        edid = callPkg ./pkgs/edid.nix { };

        # ---- the composable module set (#87, product 1) --------------------
        #
        # THE HARDWARE IS A MODULE SET, NOT A FILE. nixos/modules/ holds nine
        # modules -- kernel, identity, rollback, video, display, atx, wifi,
        # updates, server -- none of which carries a host-specific value, and
        # nixos/nanokvm-modules.nix binds this flake's cross builds to them.
        # What comes out is the flake's `nixosModules`, lifted verbatim at the
        # bottom of this file: a stranger writes
        # `imports = [ nanokvm.nixosModules.nanokvm-pro ]` and gets a bootable
        # NanoKVM-Pro. docs/modules.md.
        #
        # A FUNCTION OF THE VERSION, because `version` is stamped into
        # /kvmapp/version and /etc/nanokvm-version, and the #100 cache harness
        # below builds the same appliance with a different one.
        mkNanokvmModules = ver: callPkg ./nixos/nanokvm-modules.nix {
          # The kernel and the device tree are part of the generation now
          # (#99): `boot.kernelPackages` and `hardware.deviceTree.dtbSource`.
          kernel = kernel-mainline-appliance;
          dtb = dtb-mainline;
          version = ver;
          inherit kvm-encoder nanokvm-server nanokvm-gpio nanokvm-web
            nanokvm-display;
          # The open capture/encode modules (#83), built against the kernel
          # the appliance boots and carried in the generation's closure.
          inherit video-modules;
          # The panel's fbtft + JD9853 modules (#84), same arrangement.
          inherit display-modules;
          # WiFi (#85), same shape: the out-of-tree aic8800 modules built
          # against that kernel, and the MD5-pinned radio firmware. Both are
          # dropped from the closure entirely by `nanokvm.wifi.enable = false`.
          inherit aic8800 aic8800-firmware;
        };
        nanokvmModules = mkNanokvmModules version;

        # THE system (#78): `nixosModules.nanokvm-pro` plus nixos/appliance.nix,
        # which is our policy and nothing else. nixos/image-axp.nix defines
        # `system.build.axpImage` from this configuration's own closure, so
        # `.#nixos-firmware-image-mainline` and the system it images are one
        # derivation and cannot disagree.
        nixos-appliance-mainline-chain = callPkg ./nixos/rootfs.nix {
          inherit version nanokvmModules;
          applianceModules = [ applianceImageModule ];
        };
        # The .axp builder, bound to the module that defines
        # `system.build.axpImage` in terms of it. Applied here rather than
        # handed through the module system, because it needs the x86_64
        # package set while the module evaluates as aarch64.
        applianceImageModule = import ./nixos/image-axp.nix {
          builder = applianceAxpImageMainline;
        };
        # The same appliance retargeted at `qemu-system-aarch64 -M virt`, which
        # is where the NixOS half of a boot is proven before anything is
        # written to the device. See nixos/qemu-test.nix.
        nixos-appliance-qemu = callPkg ./nixos/rootfs.nix {
          inherit version nanokvmModules;
          variant = "qemu";
          applianceModules = [ ./nixos/qemu-test.nix ];
        };

        # ---- proof that a stranger can consume the modules (#87) -----------
        #
        # A second, minimal NixOS system built from `nixosModules.nanokvm-pro`
        # and the unavoidable minimum: a stateVersion and a hostname policy of
        # its own. It carries NONE of nixos/appliance.nix -- no sshd, no mDNS,
        # no root password, no interactive package set -- so if any hardware
        # module had quietly come to depend on one of those, this stops
        # evaluating. It is a `checks` entry and it BUILDS, because a module
        # set that evaluates and does not build is not a module set anybody
        # can use.
        nixos-modules-consumer = (import (inputs.nixpkgs + "/nixos/lib/eval-config.nix") {
          system = null;
          modules = [
            nanokvmModules.nanokvm-pro
            {
              system.stateVersion = "26.11";
              # The identity module leaves `networking.hostName` empty on
              # purpose (systemd-hostnamed refuses a transient hostname when a
              # static one is set); a consumer who wants a fixed name takes it
              # back here, which is the override this proves is possible.
              networking.hostName = pkgs.lib.mkForce "nanokvm-consumer";
              # No .axp, no QEMU harness: the point is the system closure.
            }
          ];
        }).config.system.build.toplevel;

        # `nix run .#nixos-appliance-qemu-run` -- boots the appliance under
        # qemu-system-aarch64 on a throwaway copy of the rootfs image. The one
        # place the NixOS boot can be watched on a console, since the real
        # board has none.
        nixos-appliance-qemu-run = pkgs.writeShellApplication {
          name = "nanokvm-appliance-qemu";
          runtimeInputs = with pkgs; [ qemu coreutils e2fsprogs ];
          text = ''
            work=$(mktemp -d)
            trap 'rm -rf "$work"' EXIT
            cp ${nixos-appliance-qemu}/nixos_rootfs.ext4 "$work/root.img"
            chmod u+w "$work/root.img"
            # Room for the writes a first boot makes (machine-id, journal,
            # /etc). make-ext4-fs shrinks the image to its contents.
            truncate -s +512M "$work/root.img"
            resize2fs "$work/root.img" >/dev/null

            # The kernel and the initrd are the GENERATION's (#99), so they are
            # taken out of the toplevel rather than from a kernel built around
            # this variant's initrd -- exactly the two files U-Boot loads off
            # /boot on the board.
            exec qemu-system-aarch64 \
              -M virt -cpu cortex-a53 -smp 2 -m 1024 -nographic \
              -kernel ${nixos-appliance-qemu.toplevel}/kernel \
              -initrd ${nixos-appliance-qemu.toplevel}/initrd \
              -append "console=ttyAMA0,115200 loglevel=8 root=/dev/vda rw panic=10 init=${nixos-appliance-qemu.toplevel}/init" \
              -drive file="$work/root.img",format=raw,if=none,id=hd0 \
              -device virtio-blk-device,drive=hd0 \
              -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
              "$@"
          '';
        };

        # ---- the NixOS appliance's .axp, built FROM SCRATCH (#78/#26) -------
        #
        # Not a member swap on Sipeed's bundle: nixos/lib/make-axp-image.nix
        # writes the manifest and the ZIP itself, and every partition it stores
        # comes from this flake. It is a FUNCTION of a system closure, called
        # from inside the module system by nixos/image-axp.nix -- so
        # `.#nixos-firmware-image-mainline` and
        # `.#nixosConfigurations.nanokvm-pro.config.system.build.axpImage` are
        # one derivation, and the image can never disagree with the system it
        # images.
        applianceAxpImageMainline = import ./nixos/axp-image.nix {
          inherit pkgs project version boot uboot-env mkBootfs;
          inherit atf-mainline uboot-mainline spl-minimal gpt-image;
          artifacts = import ./nixos/lib/appliance-artifacts.nix {
            inherit pkgs;
            nixpkgs = inputs.nixpkgs;
          };
        };

        # ---- the appliance's update artefacts (#86, nix-native since #100) --
        # The system closure a release offers, and the few hundred bytes that
        # name it. The toplevel is a first-class output because the release job
        # has to BUILD it (to push it to the cache) before it can publish the
        # manifest that names it -- and because `nix copy --to ssh://` from a
        # dev box wants exactly this path.
        #
        # It is the closure of the SAME appliance `.#nixos-firmware-image-
        # mainline` and `.#bootfs` are built from -- and since #99 that closure
        # contains the kernel, the initrd and the dtb as well -- so a release
        # cannot offer an update that disagrees with the image flashed from the
        # same commit.
        appliance-toplevel =
          nixos-appliance-mainline-chain.eval.config.system.build.toplevel;

        # ---- the #100 hardware harness: the appliance, pointed elsewhere ----
        # The same appliance, except that the update channel, the binary cache,
        # the cache's public key and the version stamp all come from the
        # ENVIRONMENT. It exists so a hardware run can prove the whole update
        # path -- curl the manifest, `nix copy` from a signed cache, `nix-env
        # --set`, `switch-to-configuration boot`, the idle gate and the
        # rollback -- against a throwaway cache on a build host, without
        # waiting for #96 to stand the real one up.
        #
        # THE VALUES ARE NOT IN THIS FILE ON PURPOSE. A test cache is one
        # machine's address and one throwaway key; neither belongs in a commit,
        # and a placeholder substituter is contacted for every missing path on
        # every host that evaluates this flake. `builtins.getEnv` returns ""
        # under pure evaluation, so `nix flake check` sees exactly the shipped
        # configuration; this attribute differs only when somebody deliberately
        # builds it with `--impure`:
        #
        #   NANOKVM_TEST_VERSION=2.1.0-test1 \
        #   NANOKVM_TEST_CACHE_URL=http://<host>:<port>/cache \
        #   NANOKVM_TEST_CHANNEL_URL=http://<host>:<port>/chan \
        #   NANOKVM_TEST_CACHE_KEY=nanokvm-test-1:<base64> \
        #   nix build --impure .#appliance-toplevel-cachetest
        #
        # A release must NEVER be cut from this attribute: its device would
        # trust a key nobody rotates and poll a channel nobody publishes.
        appliance-toplevel-cachetest =
          let
            env = builtins.getEnv;
            testVersion = env "NANOKVM_TEST_VERSION";
            testCache = env "NANOKVM_TEST_CACHE_URL";
            testChannel = env "NANOKVM_TEST_CHANNEL_URL";
            testKey = env "NANOKVM_TEST_CACHE_KEY";
            ver = if testVersion == "" then version else testVersion;
          in
          (callPkg ./nixos/rootfs.nix {
            version = ver;
            nanokvmModules = mkNanokvmModules ver;
            applianceModules = [
              applianceImageModule
              ({ lib, ... }: {
                nanokvm.update.cacheUrl = lib.mkIf (testCache != "") testCache;
                nanokvm.update.trustedPublicKeys =
                  lib.mkIf (testKey != "") [ testKey ];
                nanokvm.update.stableUrl = lib.mkIf (testChannel != "") testChannel;
                nanokvm.update.previewUrl = lib.mkIf (testChannel != "") testChannel;
              })
            ];
          }).eval.config.system.build.toplevel;

        system-manifest = callPkg ./pkgs/system-manifest.nix {
          inherit version;
          toplevel = "${appliance-toplevel}";
        };

        # THE FLASHABLE IMAGE. Mainline TF-A BL31 + mainline U-Boot behind the
        # blob-free SPL, and the kernel loaded by `sysboot` from
        # /boot/extlinux/extlinux.conf (#89 rung 3).
        nixos-firmware-image-mainline =
          nixos-appliance-mainline-chain.eval.config.system.build.axpImage;

        # ---- mainline U-Boot (#89 rung 0) ----------------------------------
        #
        # Upstream U-Boot 2026.07 plus our AX630C board port, wrapped in the
        # axgzip + signed-header container the SPL loads. This is BL33 on the
        # board. docs/mainline-port.md 11.10.
        axSign = callPkg ./pkgs/ax-sign.nix { };
        uboot-mainline = callPkg ./pkgs/uboot-mainline.nix { inherit axSign; };

        # ---- the SPL, rebuilt for the minimal layout (#89 rung 4) ---------
        #
        # The one artefact the layout change cannot be made without: the SPL
        # finds BL31 and BL33 by compile-time byte offsets, so it is compiled
        # from the same nixos/lib/emmc-layout.nix list the kernel command line
        # and the .axp manifest come from. Writing it to p1 is the single
        # one-way step of the port -- a bad SPL means AXDL.
        gpt-image = callPkg ./pkgs/gpt-image.nix { };

        # BLOB-FREE since 2026-09-09 (#90): signed with an EMPTY firmware
        # member, so the closed EIP-130 crypto-engine firmware is absent from
        # the container entirely rather than spliced in at 0xCC00/0x2CC00.
        # Nothing documented said the BootROM would accept a header declaring
        # `fw_size = 0`; it does, proven on hardware across two warm reboots
        # and a cold power cycle. That was the last closed payload on the
        # eMMC image.
        spl-minimal = callPkg ./pkgs/spl-minimal.nix { };

        # The vendor-shaped container, WITH the closed firmware spliced in --
        # kept as the fallback a single `dd` away if a unit ever turns out to
        # need it. Not what any image stores.
        spl-minimal-eip = callPkg ./pkgs/spl-minimal.nix { withEip = true; };

        # The same image plus milestone writes through every board_init_r hook
        # U-Boot already calls, so a BL33 that dies before `preboot` still says
        # where. The sibling of `.#atf-mainline-debug`, and the build that
        # localised rung 2's first failure. Never ship it: it writes bits 12-20,
        # which are Linux's in the shipping assignment.
        uboot-mainline-debug = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          debugMilestones = true;
        };

        # The shipping image plus the pre-console capture, and nothing that
        # writes the slot register -- so a run that succeeds leaves the
        # register reading exactly as the shipping bit assignment says, while
        # a run that fails still leaves a full U-Boot log in reserved DRAM.
        # This is the variant to reach for on this board.
        uboot-mainline-console = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          consoleToBuffer = true;
        };

        # The SHIPPING image with its console redirected into the pre-console
        # buffer from board_late_init() on -- so `bootcmd`, `sysboot` and their
        # error messages are readable from the next boot. Nothing else differs
        # from `.#uboot-mainline`. A diagnostic; never flashed as the product.
        uboot-mainline-trace = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          traceBoot = true;
        };

        # The SHIPPING image with every console write ALSO copied into the
        # pre-console buffer. Unlike `-trace` it takes nothing away: serial
        # output and console input both stay live, so the boot behaves exactly
        # as the product does and the DRAM ring records what it printed.
        uboot-mainline-tee = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          teeConsole = true;
        };

        # The tee image plus a one-shot eMMC interrogation in `preboot`
        # (#89 rung 3b, data for #91): one open-ended CMD18 with the card's
        # own CMD13 state read before any CMD12 or controller reset, a
        # single-block read in MMC_HS and in HS200, and a forced re-init.
        # A diagnostic; never flashed as the product.
        uboot-mainline-probe = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          teeConsole = true;
          probeMmc = true;
        };

        # (#91's two multi-block measurement images, `-probe-mb` and
        # `-probe-mb-50m`, are gone: the question they answered is settled --
        # the eMMC runs HS400ES and the tree now says 200 MHz. The generic
        # `probeCmds`/`emmcMaxFreq` knobs in pkgs/uboot-mainline.nix remain, so
        # the next such measurement is a few lines here.)

        # The tee image plus the AX630C first-stage loader's own SD4HC read
        # path (#91): its init ladder, its HS400ES-at-200 MHz clock, its PHY
        # table and its single 32-bit SRS03 write, run from `preboot` against
        # the #91 four-read matrix and a 51 MiB timed read, then `mmc rescan`
        # and a normal boot so the answer can be read out of the pre-console
        # buffer. A diagnostic, and a CHAINLOAD candidate -- stage it with
        # `nanokvm-uboot-test`, never write it to the `uboot` partition.
        uboot-mainline-spldrv = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          teeConsole = true;
          splDrv = true;
        };

        # The shipping image with the branch out of save_boot_params turned
        # into a branch to itself: it arms WDT0 and then hangs, at the first
        # instruction U-Boot runs. The negative half of the #91 chainload
        # proof -- a candidate that never comes back must cost one unattended
        # boot cycle. Only ever staged in the test slot, never flashed.
        uboot-mainline-hangtest = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          hangTest = true;
        };

        # The MMU is never switched on, so the boot walks straight past rung
        # 2's mmu_setup() hang and exercises what the rung is actually for --
        # sdhci-cadence, part_cmdline, the environment, extlinux, booti. Slow,
        # a diagnostic, never a shipped image; carries the milestone writes.
        uboot-mainline-nommu = callPkg ./pkgs/uboot-mainline.nix {
          inherit axSign;
          debugMilestones = true;
          dcacheOff = true;
        };

      in
      {
        packages = {
          inherit
            toolchain axera-libs boot
            atf-mainline atf-mainline-debug
            initramfsMainline kernel-mainline dtb-mainline
            kernel-mainline-appliance
            video-modules display-modules
            aic8800-src aic8800 aic8800-firmware
            nixos-appliance-qemu nixos-appliance-qemu-run
            nixos-appliance-mainline-chain
            vcenc-ewl
            kvm-encoder kvm-encoder-geom-test vcenc-geom-test vcenc-rc-test
            nanokvm-server nanokvm-gpio nanokvm-web nanokvm-display
            uboot-env bootfs system-manifest appliance-toplevel
            appliance-toplevel-cachetest
            uboot-mainline uboot-mainline-debug uboot-mainline-console
            uboot-mainline-nommu uboot-mainline-trace uboot-mainline-tee
            uboot-mainline-probe uboot-mainline-spldrv uboot-mainline-hangtest
            gpt-image spl-minimal spl-minimal-eip
            nixos-firmware-image-mainline
            edid axdl;

          default = nixos-firmware-image-mainline;
        };

        # Cheap, hardware-free regression gates.
        #   nix build .#checks.x86_64-linux.open-capture-geometry -L
        checks = {
          open-capture-geometry = kvm-encoder-geom-test;
          open-venc-geometry = vcenc-geom-test;
          open-venc-rc = vcenc-rc-test;
          # The mainline DT asserts its own boot contract (FDT slack, the
          # blkdevparts= clause, the ATF/OP-TEE reservations) -- #74.
          mainline-dtb = dtb-mainline;
          # Mainline TF-A BL31 for the AX630C: it builds, the ELF's entry and
          # link address are 0x40040000, the signed image fits the 256 KiB
          # `atf` partition, and its Axera header matches the vendor
          # atf_bl31_signed.bin field for field with both checksums
          # recomputed (#89).
          atf-mainline = atf-mainline.verify;
          # Mainline U-Boot (#89 rung 0): it links where the SPL jumps, the
          # signed image fits the `uboot` partition and carries the AX header
          # magic, the device tree reserves what belongs to other stages, and
          # the new blkdevparts= partition driver -- compiled from the shipped
          # source -- yields the same table nixos/emmc-partitions.nix does.
          uboot-mainline = callPkg ./pkgs/uboot-mainline-check.nix {
            inherit uboot-mainline;
          };
          # The GPT-at-a-base-LBA parser (patch 0023), RUN rather than read:
          # sandbox U-Boot against a faithful model of the eMMC (#89 rung 4).
          uboot-gpt = callPkg ./pkgs/uboot-gpt-test.nix {
            inherit uboot-mainline gpt-image;
          };
          # The eMMC partition map, parsed out of the blkdevparts= clause that
          # defines it, with the root/boot partition numbers and the U-Boot
          # environment offset asserted against the values docs record (#78).
          # Pure evaluation -- it builds a text file.
          # The from-scratch .axp, read back: one manifest, the partition table
          # against the blkdevparts= clause, every <Img> against what the host
          # flasher's parser requires, every member inside its partition, the
          # A/B pairs identical and the Axera signed headers intact (#78).
          nixos-axp-manifest = nixos-firmware-image-mainline.verify;
          # The #86 update loop, run for real against a fake root: apply a
          # bundle, check the profile advanced and the boot config names the
          # new generation AND its kernel, then collect and check the right
          # things survived -- including that gc REFUSES when it cannot know
          # the live set. Everything an update does except meeting hardware.
          nanokvm-updater-loop = callPkg ./nixos/lib/updater-test.nix { };
          # The policy wrapped around that loop (#86): the web UI's automatic-
          # updates checkbox gating the timer, the pending markers, and the
          # reboot that waits for an empty room -- including that an
          # unanswerable idle question fails CLOSED. A fake release host and a
          # fake idle route on loopback; everything else is the real scripts.
          nanokvm-update-idle = callPkg ./nixos/lib/update-idle-test.nix { };
          # The release artefact itself, read back (#100): the manifest names
          # the toplevel of the appliance THIS commit builds, carries the
          # version this commit is, and its closure list is the toplevel's real
          # closure. A release publishes these few hundred bytes and pushes
          # that closure to the cache; if the two ever disagree, every device
          # on the channel tries to substitute a path nobody pushed.
          nanokvm-system-manifest = callPkg ./pkgs/system-manifest-check.nix {
            inherit system-manifest version;
            toplevel = "${appliance-toplevel}";
          };
          # The fallback derivation (#99), run for real against a fake /boot:
          # promote, and check that exactly the DEFAULT line moved -- then that
          # it REFUSES when the booted generation has no LABEL in the file.
          nanokvm-mark-good-fallback = callPkg ./nixos/lib/mark-good-test.nix { };
          # A STRANGER'S CONFIGURATION (#87): a minimal NixOS system built from
          # `nixosModules.nanokvm-pro` and nothing else of ours -- none of
          # nixos/appliance.nix's policy. It is the proof that the module set
          # stands alone, and it builds rather than merely evaluating, because
          # a module set that evaluates and does not build is not one anybody
          # can use. docs/modules.md is the guide it demonstrates.
          inherit nixos-modules-consumer;
          # The /boot tree the flashed image carries, as a first-class check:
          # one extlinux.conf, no top-level MENU keyword, and LINUX/INITRD/FDT
          # lines whose files are actually there.
          nanokvm-boot-dir = nixos-appliance-mainline-chain.bootDir;
          emmc-partition-map =
            let l = import ./nixos/lib/emmc-layout.nix { inherit (pkgs) lib; };
            in
            pkgs.writeText "emmc-partition-map" ''
              === ${l.layoutName} (${toString (pkgs.lib.length l.parts)} partitions)
              ${l.table}
              ${l.blkdevparts}
              fw_env.config: ${l.fwEnvConfig}
            '';
        };

        # `nix run .#axdl -- --file result/*.axp --wait-for-device`
        apps.axdl = {
          type = "app";
          program = "${axdl}/bin/axdl-cli";
        };

        devShells.default = callPkg ./pkgs/devshell.nix { inherit toolchain axdl; };

        formatter = pkgs.nixpkgs-fmt;

        # NOT A FLAKE OUTPUT -- lifted out of the per-system set below and
        # stripped from it, because `nixosModules` is system-independent by
        # schema while the builds these modules carry are instantiated from
        # one host's package set (the same x86_64-linux one
        # `nixosConfigurations.nanokvm-pro` uses).
        nanokvmModules = nanokvmModules;
      }
      );
    in
    builtins.removeAttrs perSystem [ "nanokvmModules" ] // {
      # ---- the composable module set (#87, epic #26 product 1) ------------
      #
      # `nixosModules.nanokvm-pro` is the whole board -- every module in
      # nixos/modules/ plus this flake's cross builds -- and it is what
      # `nixosConfigurations.nanokvm-pro` below is made of, so a stranger's
      # image and ours come off the same definitions. The nine area modules
      # are exported beside it for anyone who wants to take only some of the
      # board; each needs `nixosModules.packages` imported exactly once
      # alongside it, which is what carries the kernel, the device tree and
      # the rest. docs/modules.md.
      #
      # System-independent by flake schema, but built from the x86_64-linux
      # instantiation -- every flashable output of this flake is (pkgs/boot.nix's
      # packer is x86-64-only); the SYSTEM the modules describe is aarch64-linux.
      nixosModules = perSystem.nanokvmModules.x86_64-linux;

      # The appliance as a first-class NixOS system (#78), so it can be
      # inspected and switched with the ordinary tooling:
      #   nix build .#nixosConfigurations.nanokvm-pro.config.system.build.toplevel
      # It is built from the x86_64-linux instantiation because every flashable
      # output of this flake is (pkgs/boot.nix's packer is x86-64-only); the
      # SYSTEM it describes is aarch64-linux.
      #
      #   nixos-rebuild switch --flake .#nanokvm-pro --target-host root@<dev>
      nixosConfigurations.nanokvm-pro =
        perSystem.packages.x86_64-linux.nixos-appliance-mainline-chain.eval;
    };
}
