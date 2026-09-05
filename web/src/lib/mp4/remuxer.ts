// Annex-B -> fragmented MP4 remuxer for the direct stream framing
// [key:1][timestamp_us:8 LE][Annex-B]. Codec-agnostic driver over h264.ts /
// h265.ts: collects the parameter sets, emits an initialization segment on the
// first key frame (and again whenever the parameter sets change -- a
// resolution change), then one media segment per frame with the parameter sets
// stripped (they live in avcC / hvcC).
import { lengthPrefixed, splitNalUnits } from './annexb.ts';
import { initSegment, mediaSegment, type Sample, type VideoTrack } from './fmp4.ts';
import {
  H264_NAL_AUD,
  H264_NAL_PPS,
  H264_NAL_SPS,
  buildAvcC,
  h264CodecString,
  h264NalType,
  parseH264Sps
} from './h264.ts';
import {
  H265_NAL_AUD,
  H265_NAL_PPS,
  H265_NAL_SPS,
  H265_NAL_VPS,
  buildHvcC,
  h265CodecString,
  h265NalType,
  parseH265Sps
} from './h265.ts';

export type RemuxCodec = 'h264' | 'h265';

export type RemuxEvent =
  | {
      type: 'init';
      codec: string; // RFC 6381 string derived from the stream's parameter sets
      mime: string; // video/mp4; codecs="..."
      width: number;
      height: number;
      data: Uint8Array;
    }
  | { type: 'segment'; key: boolean; timestamp: number; data: Uint8Array }
  | { type: 'log'; level: 'log' | 'warn' | 'error'; text: string };

const DEFAULT_DURATION_US = 16_667; // 60 fps until the stream says otherwise
const MIN_DURATION_US = 1_000;
const MAX_DURATION_US = 500_000;

export class Remuxer {
  private vps?: Uint8Array;
  private sps?: Uint8Array;
  private pps?: Uint8Array;
  private trackKey = ''; // identity of the parameter sets the current init segment describes
  private initialized = false;
  private sequence = 0;
  private decodeTime = 0;
  private lastTimestamp: number | null = null;
  private lastDuration = DEFAULT_DURATION_US;

  constructor(
    private readonly codec: RemuxCodec,
    // sample-entry box for HEVC; hvc1 keeps the parameter sets out of band
    // (what we do), hev1 is for browsers that only accept that string
    private readonly hevcBox: 'hvc1' | 'hev1' = 'hvc1'
  ) {}

  // Forget the initialization state (WebSocket reconnect): the next key frame
  // emits a fresh init segment even if the parameter sets did not change.
  reset(): void {
    this.initialized = false;
    this.trackKey = '';
    this.lastTimestamp = null;
  }

  feed(message: ArrayBuffer): RemuxEvent[] {
    if (message.byteLength < 9) return [];

    const view = new DataView(message);
    const key = view.getUint8(0) === 1;
    const timestamp = Number(view.getBigUint64(1, true));
    const nals = splitNalUnits(new Uint8Array(message, 9));

    const events: RemuxEvent[] = [];
    const payload: Uint8Array[] = [];

    for (const nal of nals) {
      if (nal.length === 0) continue;
      if (this.codec === 'h264') {
        const type = h264NalType(nal);
        if (type === H264_NAL_SPS) this.sps = nal.slice();
        else if (type === H264_NAL_PPS) this.pps = nal.slice();
        else if (type !== H264_NAL_AUD) payload.push(nal);
      } else {
        const type = h265NalType(nal);
        if (type === H265_NAL_VPS) this.vps = nal.slice();
        else if (type === H265_NAL_SPS) this.sps = nal.slice();
        else if (type === H265_NAL_PPS) this.pps = nal.slice();
        else if (type !== H265_NAL_AUD) payload.push(nal);
      }
    }

    if (payload.length === 0) return events;

    if (key) {
      const init = this.maybeInit();
      if (init) events.push(init);
    }

    if (!this.initialized) {
      // waiting for the first key frame (with its parameter sets)
      return events;
    }

    if (this.lastTimestamp !== null) {
      const delta = timestamp - this.lastTimestamp;
      if (delta >= MIN_DURATION_US && delta <= MAX_DURATION_US) {
        this.lastDuration = delta;
      }
    }
    this.lastTimestamp = timestamp;

    const sample: Sample = {
      key,
      decodeTime: this.decodeTime,
      duration: this.lastDuration,
      data: lengthPrefixed(payload)
    };
    this.decodeTime += sample.duration;
    this.sequence++;

    events.push({ type: 'segment', key, timestamp, data: mediaSegment(this.sequence, sample) });
    return events;
  }

  private maybeInit(): RemuxEvent | null {
    if (!this.sps || !this.pps || (this.codec === 'h265' && !this.vps)) {
      return {
        type: 'log',
        level: 'warn',
        text: `[mse] key frame without complete parameter sets (sps=${!!this.sps} pps=${!!this.pps} vps=${!!this.vps})`
      };
    }

    const trackKey = [this.vps, this.sps, this.pps].map((p) => (p ? Array.from(p).join(',') : '')).join('|');
    if (this.initialized && trackKey === this.trackKey) {
      return null;
    }

    let track: VideoTrack;
    let codec: string;
    try {
      if (this.codec === 'h264') {
        const sps = parseH264Sps(this.sps);
        codec = h264CodecString(sps);
        track = { box: 'avc1', config: buildAvcC(sps, this.sps, this.pps), width: sps.width, height: sps.height };
      } else {
        const sps = parseH265Sps(this.sps);
        codec = h265CodecString(sps, this.hevcBox);
        track = {
          box: this.hevcBox,
          config: buildHvcC(sps, this.vps!, this.sps, this.pps),
          width: sps.width,
          height: sps.height
        };
      }
    } catch (err) {
      return { type: 'log', level: 'error', text: `[mse] parameter set parse failed: ${err}` };
    }

    this.trackKey = trackKey;
    this.initialized = true;
    // A new init segment restarts the decode timeline; in sequence mode the
    // SourceBuffer abuts it to what is already buffered.
    this.decodeTime = 0;
    this.lastTimestamp = null;

    return {
      type: 'init',
      codec,
      mime: `video/mp4; codecs="${codec}"`,
      width: track.width,
      height: track.height,
      data: initSegment(track)
    };
  }
}
