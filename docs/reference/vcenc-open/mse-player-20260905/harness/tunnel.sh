#!/usr/bin/env bash
# Loopback tunnel to the device web UI.
#   usage: tunnel.sh [local-port] [device-port]      (default 8443 -> 443)
#   e.g.   tunnel.sh 8443 443     https://127.0.0.1:8443
#          tunnel.sh 8080 80      http://127.0.0.1:8080
# Requests arrive at the device from 127.0.0.1, so the server's localhost auth
# bypass applies. Credentials come from device.env; nothing is printed.
# Runs in the FOREGROUND -- start it with & and poll the local port.
set -u
LPORT="${1:-8443}"
RPORT="${2:-443}"
source "${NANOKVM_DEVICE_ENV:-$HOME/.config/nanokvm/device.env}"
for ip in "${KVM_IP_TAILSCALE:-}" "${KVM_IP_LAN:-}"; do
  [ -n "$ip" ] || continue
  timeout 4 bash -c "echo > /dev/tcp/$ip/22" 2>/dev/null || continue
  for pw in "${KVM_PASSWORD:-}" "${KVM_PASSWORD_FACTORY:-}"; do
    [ -n "$pw" ] || continue
    nix shell nixpkgs#sshpass --command sshpass -p "$pw" \
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
          -o ConnectTimeout=12 -o ExitOnForwardFailure=yes -N \
          -L "$LPORT:127.0.0.1:$RPORT" "root@$ip"
    rc=$?
    [ "$rc" -eq 5 ] && continue
    exit "$rc"
  done
done
echo "tunnel: no reachable IP" >&2
exit 1
