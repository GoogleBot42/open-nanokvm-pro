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

// Media Source Extensions path: the same direct WebSocket streams, remuxed to
// fragmented MP4 in the browser and decoded by its own media pipeline, so it
// works wherever <video> plays the codec -- notably HEVC in browsers whose
// WebCodecs has no HEVC decoder (Firefox, Chrome on Linux).
export type MseCodec = 'h264' | 'h265';

export type MseSupport = {
  supported: boolean;
  // sample-entry box / codec-string family the browser accepted (HEVC only)
  hevcBox?: 'hvc1' | 'hev1';
};

// Representative strings: what the device's encoder writes (H.264 Main 4.2,
// HEVC Main 4.1 at 1080p, 5.1 at 4K -- read off live streams) plus the
// Baseline string the WebCodecs path uses. The exact string is derived from
// the stream's own parameter sets at play time and probed again then.
const MSE_PROBE_STRINGS: Record<MseCodec, string[]> = {
  h264: ['avc1.4D002A', 'avc1.42E01F'],
  h265: ['hvc1.1.2.L123.80', 'hvc1.1.2.L153.80', 'hev1.1.2.L123.80', 'hev1.1.2.L153.80']
};

const mseSupportCache = new Map<MseCodec, MseSupport>();

export function isMseSupported() {
  return 'MediaSource' in window && typeof MediaSource.isTypeSupported === 'function';
}

// Ask MediaSource.isTypeSupported about the codec; every answer is logged once.
export function mseCodecSupport(codec: MseCodec): MseSupport {
  const cached = mseSupportCache.get(codec);
  if (cached) return cached;

  let result: MseSupport = { supported: false };

  if (!isMseSupported()) {
    console.log('[mse] no MediaSource in this browser');
  } else {
    for (const s of MSE_PROBE_STRINGS[codec]) {
      const ok = MediaSource.isTypeSupported(`video/mp4; codecs="${s}"`);
      console.log(`[mse] isTypeSupported ${s}: ${ok}`);
      if (ok && !result.supported) {
        result = { supported: true, hevcBox: s.startsWith('hev1') ? 'hev1' : s.startsWith('hvc1') ? 'hvc1' : undefined };
      }
    }
  }

  mseSupportCache.set(codec, result);
  return result;
}

// The stream mode the server knows for a client video mode: the MSE players
// consume the direct streams.
export function serverStreamMode(mode: string): string {
  switch (mode) {
    case 'h264-mse':
      return 'h264-direct';
    case 'h265-mse':
      return 'h265-direct';
    default:
      return mode;
  }
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
  }

  if (mseCodecSupport('h264').supported) {
    videoModes.push('h264-mse');
  }

  // H.265 Direct picks WebCodecs or MSE at play time; it is offered when
  // either could work.
  const h265Mse = mseCodecSupport('h265').supported;
  if (decoderSupported || h265Mse) {
    videoModes.push('h265-direct');
  }

  if (h265Mse) {
    videoModes.push('h265-mse');
  }

  return videoModes;
}
