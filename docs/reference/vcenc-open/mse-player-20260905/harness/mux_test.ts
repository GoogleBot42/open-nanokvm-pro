// Host-side check of the fMP4 remuxer on captured Annex-B streams: frames one
// message per VCL NAL (parameter sets folded into the key message that
// follows, like the server does) and writes init+segments to an .mp4 for
// ffprobe/ffmpeg. usage: node --experimental-strip-types mux_test.ts <h264|h265> <in.annexb> <out.mp4>
import { readFileSync, writeFileSync } from 'node:fs';

import { splitNalUnits } from '../../../../../web/src/lib/mp4/annexb.ts';
import { Remuxer } from '../../../../../web/src/lib/mp4/remuxer.ts';

const [codec, input, output] = process.argv.slice(2) as ['h264' | 'h265', string, string];
const bytes = new Uint8Array(readFileSync(input));
const nals = splitNalUnits(bytes);

const isParam = (nal: Uint8Array) => {
  if (codec === 'h264') {
    const t = nal[0] & 0x1f;
    return t === 7 || t === 8 || t === 9 || t === 6;
  }
  const t = (nal[0] >> 1) & 0x3f;
  return t >= 32 && t <= 40;
};
const isKey = (nal: Uint8Array) => {
  if (codec === 'h264') return (nal[0] & 0x1f) === 5;
  const t = (nal[0] >> 1) & 0x3f;
  return t >= 16 && t <= 23;
};

const startCode = Uint8Array.of(0, 0, 0, 1);
function message(key: boolean, ts: number, units: Uint8Array[]): ArrayBuffer {
  const body = units.reduce((n, u) => n + 4 + u.length, 0);
  const buf = new ArrayBuffer(9 + body);
  const view = new DataView(buf);
  view.setUint8(0, key ? 1 : 0);
  view.setBigUint64(1, BigInt(ts), true);
  const out = new Uint8Array(buf, 9);
  let o = 0;
  for (const u of units) {
    out.set(startCode, o);
    out.set(u, o + 4);
    o += 4 + u.length;
  }
  return buf;
}

const remuxer = new Remuxer(codec, 'hvc1');
const parts: Uint8Array[] = [];
let pending: Uint8Array[] = [];
let ts = 0;
let frames = 0;
let inits = 0;
let logs = 0;

for (const nal of nals) {
  if (isParam(nal)) {
    pending.push(nal);
    continue;
  }
  const key = isKey(nal);
  const units = key ? [...pending, nal] : [nal];
  pending = [];
  for (const ev of remuxer.feed(message(key, ts, units))) {
    if (ev.type === 'init') {
      inits++;
      console.log(`init: ${ev.codec} ${ev.width}x${ev.height} (${ev.data.length} B)`);
      parts.push(ev.data);
    } else if (ev.type === 'segment') {
      frames++;
      parts.push(ev.data);
    } else {
      logs++;
      console.log(`${ev.level}: ${ev.text}`);
    }
  }
  ts += 16667;
}

const total = parts.reduce((n, p) => n + p.length, 0);
const out = new Uint8Array(total);
let o = 0;
for (const p of parts) {
  out.set(p, o);
  o += p.length;
}
writeFileSync(output, out);
console.log(`${nals.length} NALs -> ${inits} init, ${frames} segments, ${logs} logs, ${total} bytes`);
