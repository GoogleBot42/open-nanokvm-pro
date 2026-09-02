#!/bin/sh
cd /root/axbring
systemctl stop nanokvm; sleep 2
dmesg -C
for g in "3840 2160" "1920 1080" "2560 1440" "1280 720" "1920 1200"; do
  echo "=== $g"; python3 geoprobe.py $g 2>&1 | tail -12
  dmesg | tail -5; dmesg -C
  sleep 1
done
systemctl start nanokvm
for i in $(seq 1 30); do [ "$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/)" = 200 ] && break; sleep 2; done
echo "web $(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/) after ${i}x2s"
ls -la geo | grep fake
