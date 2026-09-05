// Minimal fragmented-MP4 writer for a single video track: one initialization
// segment (ftyp + moov with an empty sample table and a trex) and one media
// segment (moof + mdat) per frame. ISO/IEC 14496-12; the sample-entry payload
// (avcC / hvcC) comes from h264.ts / h265.ts.

export type VideoTrack = {
  box: 'avc1' | 'hvc1' | 'hev1';
  config: Uint8Array; // avcC or hvcC record body
  width: number;
  height: number;
};

// The track timescale. The server timestamps frames in microseconds, so 1e6
// lets sample durations be used as-is.
export const TIMESCALE = 1_000_000;
const TRACK_ID = 1;

type Part = Uint8Array | Part[];

function u16(v: number): Uint8Array {
  return Uint8Array.of((v >> 8) & 0xff, v & 0xff);
}

function u32(v: number): Uint8Array {
  return Uint8Array.of((v >>> 24) & 0xff, (v >>> 16) & 0xff, (v >>> 8) & 0xff, v & 0xff);
}

function u64(v: number): Uint8Array {
  const hi = Math.floor(v / 0x1_0000_0000);
  const lo = v >>> 0;
  return concat([u32(hi), u32(lo)]);
}

function ascii(s: string): Uint8Array {
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

function flatten(parts: Part[], out: Uint8Array[]): void {
  for (const p of parts) {
    if (p instanceof Uint8Array) out.push(p);
    else flatten(p, out);
  }
}

function concat(parts: Part[]): Uint8Array {
  const flat: Uint8Array[] = [];
  flatten(parts, flat);
  const out = new Uint8Array(flat.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of flat) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

function box(type: string, ...payload: Part[]): Uint8Array {
  const body = concat(payload);
  return concat([u32(8 + body.length), ascii(type), body]);
}

// version + flags header of a FullBox
function full(version: number, flags: number): Uint8Array {
  return u32(((version & 0xff) << 24) | (flags & 0xffffff));
}

const ZERO4 = new Uint8Array(4);

function ftyp(track: VideoTrack): Uint8Array {
  return box('ftyp', ascii('isom'), u32(0x200), ascii('isom'), ascii('iso6'), ascii(track.box), ascii('mp41'));
}

function mvhd(): Uint8Array {
  return box(
    'mvhd',
    full(0, 0),
    ZERO4, // creation_time
    ZERO4, // modification_time
    u32(TIMESCALE),
    ZERO4, // duration (unknown: fragments)
    u32(0x00010000), // rate 1.0
    u16(0x0100), // volume 1.0
    u16(0), // reserved
    new Uint8Array(8), // reserved
    unityMatrix(),
    new Uint8Array(24), // pre_defined
    u32(TRACK_ID + 1) // next_track_ID
  );
}

function unityMatrix(): Uint8Array {
  return concat([u32(0x10000), ZERO4, ZERO4, ZERO4, u32(0x10000), ZERO4, ZERO4, ZERO4, u32(0x40000000)]);
}

function tkhd(track: VideoTrack): Uint8Array {
  return box(
    'tkhd',
    full(0, 0x7), // enabled | in_movie | in_preview
    ZERO4, // creation_time
    ZERO4, // modification_time
    u32(TRACK_ID),
    ZERO4, // reserved
    ZERO4, // duration
    new Uint8Array(8), // reserved
    u16(0), // layer
    u16(0), // alternate_group
    u16(0), // volume (video)
    u16(0), // reserved
    unityMatrix(),
    u32(track.width << 16), // 16.16 fixed point
    u32(track.height << 16)
  );
}

function mdhd(): Uint8Array {
  return box(
    'mdhd',
    full(0, 0),
    ZERO4,
    ZERO4,
    u32(TIMESCALE),
    ZERO4, // duration
    u16(0x55c4), // language "und"
    u16(0)
  );
}

function hdlr(): Uint8Array {
  return box(
    'hdlr',
    full(0, 0),
    ZERO4, // pre_defined
    ascii('vide'),
    new Uint8Array(12), // reserved
    ascii('VideoHandler\0')
  );
}

function dinf(): Uint8Array {
  return box('dinf', box('dref', full(0, 0), u32(1), box('url ', full(0, 1))));
}

function sampleEntry(track: VideoTrack): Uint8Array {
  const compressorName = new Uint8Array(32); // pascal string, empty
  const configType = track.box === 'avc1' ? 'avcC' : 'hvcC';

  return box(
    track.box,
    new Uint8Array(6), // reserved
    u16(1), // data_reference_index
    u16(0), // pre_defined
    u16(0), // reserved
    new Uint8Array(12), // pre_defined
    u16(track.width),
    u16(track.height),
    u32(0x00480000), // horizresolution 72 dpi
    u32(0x00480000), // vertresolution
    ZERO4, // reserved
    u16(1), // frame_count
    compressorName,
    u16(0x0018), // depth
    u16(0xffff), // pre_defined = -1
    box(configType, track.config)
  );
}

function stbl(track: VideoTrack): Uint8Array {
  return box(
    'stbl',
    box('stsd', full(0, 0), u32(1), sampleEntry(track)),
    box('stts', full(0, 0), u32(0)),
    box('stsc', full(0, 0), u32(0)),
    box('stsz', full(0, 0), u32(0), u32(0)),
    box('stco', full(0, 0), u32(0))
  );
}

function minf(track: VideoTrack): Uint8Array {
  return box('minf', box('vmhd', full(0, 1), u16(0), new Uint8Array(6)), dinf(), stbl(track));
}

function trak(track: VideoTrack): Uint8Array {
  return box('trak', tkhd(track), box('mdia', mdhd(), hdlr(), minf(track)));
}

function mvex(): Uint8Array {
  return box(
    'mvex',
    box(
      'trex',
      full(0, 0),
      u32(TRACK_ID),
      u32(1), // default_sample_description_index
      ZERO4, // default_sample_duration
      ZERO4, // default_sample_size
      ZERO4 // default_sample_flags
    )
  );
}

export function initSegment(track: VideoTrack): Uint8Array {
  return concat([ftyp(track), box('moov', mvhd(), trak(track), mvex())]);
}

// sample_flags (8.8.3.1): key = depends_on 2 (no); delta = depends_on 1 (yes) +
// sample_is_non_sync_sample
const FLAGS_KEY = 0x02000000;
const FLAGS_DELTA = 0x01010000;

export type Sample = {
  key: boolean;
  decodeTime: number; // in TIMESCALE units
  duration: number; // in TIMESCALE units
  data: Uint8Array; // length-prefixed NAL units
};

// One moof + mdat carrying a single sample.
export function mediaSegment(sequenceNumber: number, sample: Sample): Uint8Array {
  const trunBody = concat([
    full(0, 0x000701), // data-offset, sample-duration, sample-size, sample-flags
    u32(1), // sample_count
    ZERO4, // data_offset placeholder
    u32(sample.duration),
    u32(sample.data.length),
    u32(sample.key ? FLAGS_KEY : FLAGS_DELTA)
  ]);

  const traf = box(
    'traf',
    box('tfhd', full(0, 0x020000), u32(TRACK_ID)), // default-base-is-moof
    box('tfdt', full(1, 0), u64(sample.decodeTime)),
    box('trun', trunBody)
  );
  const moof = box('moof', box('mfhd', full(0, 0), u32(sequenceNumber)), traf);

  // data_offset: from the moof start to the first sample byte (mdat header = 8).
  // trun is the last box in moof, so its payload is the last trunBody.length
  // bytes; data_offset sits after version/flags (4) and sample_count (4).
  const dataOffset = moof.length + 8;
  moof.set(u32(dataOffset), moof.length - trunBody.length + 8);

  const mdat = box('mdat', sample.data);
  return concat([moof, mdat]);
}
