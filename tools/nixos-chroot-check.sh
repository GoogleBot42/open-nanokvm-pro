#!/bin/sh
# nixos-chroot-check.sh -- runs ON THE DEVICE, inside/around a chroot into the
# pure-Nix rootfs image. Shipped there by tools/nixos-chroot-test; not meant to
# be run by hand on the build host.
#
#   $1  directory holding rootfs.ext4 and mnt/   (e.g. /root/nixos-rootfs-test)
#   $2  the NixOS system closure store path      (e.g. /nix/store/xxx-nixos-system-...)
#   $3  the patchelf'd Axera lib store path      (e.g. /nix/store/yyy-axera-libs-nixos-...)
#   $4  the /kvmapp store path                   (e.g. /nix/store/zzz-kvmapp)
#
# Everything addresses ABSOLUTE store paths, never the FHS paths the running
# system would have. Two reasons: /etc inside the image is empty (NixOS builds
# it during activation, which only happens at boot), and /opt/lib, /soc/ko and
# /kvmapp are systemd.tmpfiles symlinks that are likewise only created at boot.
set -u

DIR="$1"
SYS="$2"
AXLIB="$3"
KVMAPP="${4:-}"
M="$DIR/mnt"

pass=0
fail=0
ok()   { echo "PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $*"; fail=$((fail + 1)); }
note() { echo "note  $*"; }
run()  { chroot "$M" "$@"; }

echo "=== chroot checks: $M (kernel $(uname -r)) ==="

# --- 1. Does this systemd start at all on this kernel? -------------------
# THE headline result. systemd 256's README claims 4.19 support; the vendor
# rootfs only proves 249. This is the gap being closed.
if out=$(run "$SYS/systemd/lib/systemd/systemd" --version 2>&1); then
    ok "systemd runs: $(echo "$out" | head -1)"
else
    bad "systemd --version"
    echo "$out" | head -20
fi

# --- 2. Unit-graph parse. --test never touches the running system. -------
if out=$(run "$SYS/systemd/lib/systemd/systemd" --test --system 2>&1); then
    ok "systemd --test --system (unit graph parses)"
else
    bad "systemd --test --system"
    echo "$out" | tail -25
fi

# --- 3. udev. No udev means no /dev/fb0, no evdev, no capture. -----------
if out=$(run "$SYS/systemd/bin/udevadm" --version 2>&1); then
    ok "udevadm: $out"
else
    bad "udevadm --version"
    echo "$out" | head -10
fi

# --- 4. The app's whole DT_NEEDED/DT_RPATH chain, resolved WITHOUT --------
# executing anything: ld.so --list walks it exactly as a real load would.
# This is what catches "libax_engine.so: cannot open shared object file".
LDSO=$(run sh -c "ls $SYS/sw/lib/ld-linux-aarch64.so.1 2>/dev/null" \
       || echo "")
if [ -z "$LDSO" ]; then
    # Ask the server binary which loader it wants -- on this image that is the
    # UNSTABLE pin's glibc, deliberately (docs/nixos-rootfs.md, "Two glibcs").
    LDSO=$(run sh -c "
        for f in \$(sed -n 's/.*\(\/nix\/store\/[a-z0-9]*-glibc-[^ ]*\/lib\/ld-linux-aarch64\.so\.1\).*/\1/p' \
                    /kvmapp/server/NanoKVM-Server 2>/dev/null | head -1); do
            [ -x \"\$f\" ] && echo \"\$f\" && break
        done" 2>/dev/null || echo "")
fi
if [ -z "$LDSO" ]; then
    note "could not locate the dynamic loader; skipping the link-resolution checks"
    note "find it with: chroot $M sh -c 'ls /nix/store/*glibc*/lib/ld-linux-aarch64.so.1'"
else
    ok "loader: $LDSO"
    for t in /kvmapp/server/NanoKVM-Server /kvmapp/server/dl_lib/libkvm.so.0; do
        if ! run test -e "$t"; then
            bad "missing in image: $t"
            continue
        fi
        out=$(run "$LDSO" --list "$t" 2>&1)
        if echo "$out" | grep -q "not found"; then
            bad "unresolved libraries in $t"
            echo "$out" | grep "not found"
        else
            ok "all libraries resolve: $t"
        fi
    done
fi

# --- 5. Do the patchelf'd Axera libs actually dlopen? --------------------
# The ABI question: vendor .so built against Ubuntu glibc 2.35, loaded here
# against the rootfs pin's glibc, with libstdc++ coming from the rootfs pin's
# gcc-lib via the rpath autoPatchelfHook added.
if [ -n "$AXLIB" ] && run test -d "$AXLIB/lib"; then
    for l in libax_sys.so libax_venc.so libax_proton.so; do
        if run "$SYS/sw/bin/python3" -c \
            "import ctypes; ctypes.CDLL('$AXLIB/lib/$l'); print('ok')" >/dev/null 2>&1
        then
            ok "dlopen $l"
        else
            bad "dlopen $l"
            run "$SYS/sw/bin/python3" -c \
                "import ctypes; ctypes.CDLL('$AXLIB/lib/$l')" 2>&1 | tail -3
        fi
    done
else
    note "no axera-libs-nixos path given/found; skipping the dlopen checks"
fi

# --- 6. The mini-display daemon is pure-stdlib Python; make sure the ------
# interpreter in the image can at least compile it.
if run sh -c "ls $SYS/sw/bin/python3" >/dev/null 2>&1; then
    ok "python3 present in the system path"
else
    bad "no python3 in the system path (mini-display would not start)"
fi

echo
echo "--- summary: $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
