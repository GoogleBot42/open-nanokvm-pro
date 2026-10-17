#!/bin/sh
# Board side of the audio harness: every 0.5 s for $1 seconds, which aplay
# (if any) is feeding the gadget, where the gadget's playback and capture
# substreams are, and the two rate controls. Run on the device.
end=$(( $(cut -d. -f1 /proc/uptime) + ${1:-60} ))
st() { tr '\n' ' ' < "$1" 2>/dev/null | sed 's/  */ /g'; }
while [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
  printf '%s aplay=[%s] p=[%s] c=[%s] rates=%s\n' "$(date +%T.%N | cut -c1-12)" \
    "$(pgrep -x aplay | tr '\n' ' ')" \
    "$(st /proc/asound/UAC2Gadget/pcm0p/sub0/status)" \
    "$(st /proc/asound/UAC2Gadget/pcm0c/sub0/status)" \
    "$(amixer -c UAC2Gadget cget iface=PCM,name='Playback Rate' | sed -n 's/.*: values=//p'),$(amixer -c UAC2Gadget cget iface=PCM,name='Capture Rate' | sed -n 's/.*: values=//p')"
  sleep 0.5
done
