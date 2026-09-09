#!/bin/sh
# Hold /dev/watchdog open and pet it, so watchdog.open_timeout does not reset
# a slot-B boot that actually succeeded.
setsid sh -c 'exec 3>/dev/watchdog; while :; do printf 1 >&3; sleep 5; done' </dev/null >/dev/null 2>&1 &
sleep 1
echo "watchdog held"
