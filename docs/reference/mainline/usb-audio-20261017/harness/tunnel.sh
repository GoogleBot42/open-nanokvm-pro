#!/usr/bin/env bash
# Loopback tunnel to the device web UI by SSH key: https://127.0.0.1:8443 ->
# device:443, so requests arrive from 127.0.0.1 and the server's localhost
# auth bypass applies. The address comes from device.env; nothing is printed.
set -u
source "${NANOKVM_DEVICE_ENV:-$HOME/.config/nanokvm/device.env}"
exec ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR -o ExitOnForwardFailure=yes -N -L 8443:127.0.0.1:443 "root@$KVM_IP_LAN"
