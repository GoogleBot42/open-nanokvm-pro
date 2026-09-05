#!/bin/sh
# Return to the OPEN stack at runtime: unload the vendor modules, run the
# on-disk open loader, restart the services, verify. If an rmmod wedges, a plain
# `reboot` lands on the open stack anyway (loader on disk untouched).
set -x
for m in ax_venc ax_base ax_pool ax_cmm ax_sys; do lsmod | grep -q "^$m " && rmmod $m; done
lsmod | grep '^ax_' && echo "!! vendor modules still loaded"
/soc/scripts/auto_load_all_drv.sh -i
systemctl start nanokvm nanokvm-display
sleep 6
systemctl is-active nanokvm nanokvm-display
curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1/
lsmod | awk 'NR>1{print $1}' | tr '\n' ' '; echo
