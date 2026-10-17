# USB audio both ways — evidence (#82, 2026-10-17)

The narrative is `docs/mainline-port.md`, "#82 residuals", the UAC2 second
round. This directory is what it rests on. Generation 37 (`r6npbx9p…`), flags
`usb.disk0` + `usb.ncm` + `usb.uac2`. The host was powered off throughout
(`nanokvm-gpio get atx-power-led` = 0, UDC `not attached`), so every host-side
behaviour is unmeasured here.

## Harness

- `harness/tunnel.sh` — SSH-key loopback tunnel, `https://127.0.0.1:8443` →
  device `:443`; the server's localhost bypass then skips auth.
- `harness/cdp_audio.py <url> [seconds] [--mic-at N]` — the real web UI in
  headless Chromium, H.264 WebRTC mode, `audioLevel`/samples of the
  KVM-to-browser track every 5 s, and at `--mic-at` a fake microphone added the
  way the UI's mic toggle adds one (`getUserMedia` + `addTrack`; the UI's own
  `onnegotiationneeded` sends the offer). Needs chromium and python3 with
  `websockets`:
  `nix build --impure --expr 'let p = (builtins.getFlake "nixpkgs").legacyPackages.x86_64-linux; in p.buildEnv { name = "audio-harness"; paths = [ (p.python3.withPackages (ps: [ ps.websockets ])) p.chromium ]; }'`.
- `harness/board-watch.sh <seconds>` — on the device: the gadget's playback
  and capture substream status and both rate controls, every ~0.7 s.

## Files

- `mic-run.txt` — `cdp_audio.py ... 40 --mic-at 10`. The mic's m-line (`mid
  1`, the second sender the UI's `addTrack` creates) sends 50 packets/s from
  t=10 s. No `inAudio`: the host plays nothing into the gadget and HDMI has no
  samples (#104), so libkvm returns no data — by design, not an error.
- `mic-board-watch.txt` — the same 40 s on the device: six successive aplay
  PIDs as `owner_pid` of the gadget's playback substream, each `RUNNING`,
  `appl_ptr 4096` (the decoded mic has filled the 4096-frame buffer) and
  `hw_ptr 0` (no host reading). `rates=0,0` throughout.
- `selftest-run.txt` — the KVM-to-browser half, with a `KVM_AUDIO_SELFTEST`
  libkvm (440/660 Hz tone, the real Opus encode) copied over
  `/dev/shm/kvmapp/server/dl_lib/libkvm.so*` and `nanokvm` restarted;
  restored afterwards with `systemctl restart nanokvm-appdir nanokvm` (md5
  back to the generation's). 250 packets and 240 000 samples per 5 s, zero
  concealed, `audioLevel` 0.27 once the `<audio>` element is unmuted (9000 /
  32768 = 0.275).

## Server log, the same session (client address dropped)

    OPEN-KVM: audio: no source is playing (the HDMI bridge delivers no samples (#104)); the host's speaker is used whenever it streams into UAC2Gadget, HDMI is retried every 5 s
    [22:30:22.600] [info] [player.go:85] virtual mic: started (aplay -D plughw:UAC2Gadget,0)
    [22:30:22.824] [info] [player.go:155] virtual mic: aplay exited (exit status 1) -- nothing on the host is recording from the NanoKVM microphone; retrying every 1s, samples dropped until then
    [22:30:52.443] [info] [player.go:229] virtual mic: stopped

Earlier generations had left `failed to read audio: -1` 55 709 times in the
log file (one per ~1.2 s HDMI read timeout while a viewer was connected); this
generation logged none.

## Kernel semantics, measured with no host

    # arecord -q -D hw:UAC2Gadget,0 -f S16_LE -r 48000 -c 2 --period-size=960 --buffer-size=3840 -t raw -d 2 /dev/null
    arecord: pcm_read:2285: read error: Input/output error        (rc=1 after 0.155 s)
    # head -c 400000 /dev/zero | aplay -q -D plughw:UAC2Gadget,0 -r 48000 -f S16_LE -c 2 -t raw --buffer-size=4096
    aplay: pcm_write:2191: write error: Input/output error         (rc=1 after ~0.17 s)

`wait_for_avail()` (sound/core/pcm_lib.c) waits `max(100 ms, buffer x 1.1 /
rate)` for a pointer that only `u_audio_iso_complete()` moves.

## Gadget restart mid-session

`usbdev.sh restart` during a WebRTC session: the card came back as
`UAC2Gadget`, card 1 (the disconnected card releases its slot at
`snd_card_disconnect()`), and the server's control fd afterwards was
`/dev/snd/controlC1` — libkvm had closed the dead node on its first failed read
and opened the new one. The three `/dev/hidg*` fds were `(deleted)`, as they
always are after a rebuild; `systemctl restart nanokvm` reopens them.
