#!/usr/bin/env bash
# Read every channel a chainload round leaves behind, in the order that loses
# the least if the board goes away mid-way. Run it BEFORE any power cycle: the
# chainload record, the milestone register and the pre-console buffer all die
# with the power (#91).
set -euo pipefail
repo="$(cd "$(dirname "$0")/../../../../.." && pwd)"

"$repo/tools/kvmssh" '
  echo "=== slot register / milestones ==="
  devmem 0x02390024 32
  echo "=== bootcount ==="
  devmem 0x02390030 32
  echo "=== chainload record (latched by nanokvm-uboot-test-clear) ==="
  cat /run/nanokvm-uboot-test.chainload 2>/dev/null || echo "(not latched)"
  cat /run/nanokvm-uboot-test.addr 2>/dev/null || true
  devmem 0x480EE000 32
  echo "=== nanokvm-uboot-test status ==="
  nanokvm-uboot-test status || true
  echo "=== clear unit ==="
  journalctl -b -u nanokvm-uboot-test-clear --no-pager || true
  echo "=== health gate ==="
  journalctl -b -u nanokvm-mark-good --no-pager || true
  echo "=== pre-console buffer (0x480E8000, 8 KiB) ==="
  dd if=/dev/mem bs=4096 skip=295144 count=2 2>/dev/null | tr -d "\000"
  echo
  echo "=== previous boot pstore archive ==="
  ls -l /var/lib/systemd/pstore/ 2>/dev/null || true
'
