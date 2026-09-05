export function isWebrtcSupported() {
  return 'RTCPeerConnection' in window;
}

export function isDecoderSupported() {
  return 'VideoDecoder' in window;
}

// H.265 over WebRTC (pion route). The server has no such route, so this no
// longer feeds the mode list; kept for the day it does.
export function isH265Supported() {
  if ('getCapabilities' in RTCRtpReceiver) {
    const capabilities = RTCRtpReceiver.getCapabilities('video');
    if (capabilities && capabilities.codecs) {
      const h265Codec = capabilities.codecs.find((codec) => codec.mimeType === 'video/H265');
      return !!h265Codec;
    }
  }

  return false;
}

// H.265 over the direct (WebSocket + WebCodecs) path.
export type HardwareAccelerationPreference = 'no-preference' | 'prefer-hardware' | 'prefer-software';

export type H265DecoderConfig = {
  codec: string;
  hardwareAcceleration: HardwareAccelerationPreference;
};

// Main profile, Main tier, level 5.1 -- what the device's encoder writes for
// 4K. The decoder runs without a description (Annex-B, parameter sets in-band
// on every key frame), so the worker derives the exact string from the
// stream's own VPS once it sees it; these are only what we ASK the browser
// about beforehand, and the last resort if the VPS cannot be read.
export const H265_DIRECT_CODEC = 'hvc1.1.6.L153.B0';
const H265_CODEC_CANDIDATES = ['hvc1.1.6.L153.B0', 'hvc1.1.6.L123.B0', 'hev1.1.6.L123.B0'];
const H265_ACCELERATION_CANDIDATES: HardwareAccelerationPreference[] = [
  'no-preference',
  'prefer-hardware',
  'prefer-software'
];

let h265DirectProbe: Promise<H265DecoderConfig | null> | null = null;

// Ask WebCodecs which HEVC configuration it accepts and log every answer, so
// a user can report them. Returns the first accepted configuration, or null.
// Advisory only: `isConfigSupported` for a codec string is a narrower question
// than "can this browser decode HEVC", so the H.265 Direct option is never
// disabled on this answer -- the player tries, and falls back to H.264 Direct
// only when the decoder actually fails at runtime.
export function probeH265DirectConfig(): Promise<H265DecoderConfig | null> {
  if (h265DirectProbe) return h265DirectProbe;

  h265DirectProbe = (async () => {
    if (!isDecoderSupported()) {
      console.log('[h265-direct] no VideoDecoder (WebCodecs) in this browser');
      return null;
    }

    let chosen: H265DecoderConfig | null = null;

    for (const codec of H265_CODEC_CANDIDATES) {
      for (const hardwareAcceleration of H265_ACCELERATION_CANDIDATES) {
        let answer: string;
        try {
          const { supported } = await VideoDecoder.isConfigSupported({
            codec,
            hardwareAcceleration,
            optimizeForLatency: true
          });
          answer = supported ? 'supported' : 'unsupported';
        } catch (err) {
          answer = `throws ${err}`;
        }

        console.log(`[h265-direct] isConfigSupported ${codec} ${hardwareAcceleration}: ${answer}`);

        if (!chosen && answer === 'supported') {
          chosen = { codec, hardwareAcceleration };
        }
      }
    }

    console.log(
      chosen
        ? `[h265-direct] probe accepted ${chosen.codec} (${chosen.hardwareAcceleration})`
        : `[h265-direct] probe accepted nothing; trying ${H265_DIRECT_CODEC} anyway`
    );

    return chosen;
  })();

  return h265DirectProbe;
}

export function getSupportedVideoModes() {
  const webrtcSupported = isWebrtcSupported();
  const decoderSupported = isDecoderSupported();

  const videoModes = ['mjpeg'];

  if (webrtcSupported) {
    videoModes.push('h264-webrtc');
  }

  if (decoderSupported) {
    videoModes.push('h264-direct');
    videoModes.push('h265-direct');
  }

  return videoModes;
}
