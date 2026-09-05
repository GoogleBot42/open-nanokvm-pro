// Annex-B byte stream helpers: split on start codes, length-prefix for MP4.

// Split an Annex-B buffer into NAL units (without start codes). Both 3- and
// 4-byte start codes are accepted; trailing zero bytes before a start code
// belong to the start code, not the NAL.
export function splitNalUnits(data: Uint8Array): Uint8Array[] {
  const nals: Uint8Array[] = [];
  const n = data.length;
  let i = 0;
  let start = -1;

  while (i + 2 < n) {
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1) {
      if (start >= 0) {
        let end = i;
        while (end > start && data[end - 1] === 0) end--;
        if (end > start) nals.push(data.subarray(start, end));
      }
      i += 3;
      start = i;
      continue;
    }
    i++;
  }

  if (start >= 0 && start < n) {
    nals.push(data.subarray(start, n));
  }

  return nals;
}

// Concatenate NAL units as 4-byte big-endian length-prefixed units (the
// lengthSizeMinusOne = 3 layout declared in avcC/hvcC).
export function lengthPrefixed(nals: Uint8Array[]): Uint8Array {
  const total = nals.reduce((sum, nal) => sum + 4 + nal.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const nal of nals) {
    const len = nal.length;
    out[offset] = (len >>> 24) & 0xff;
    out[offset + 1] = (len >>> 16) & 0xff;
    out[offset + 2] = (len >>> 8) & 0xff;
    out[offset + 3] = len & 0xff;
    out.set(nal, offset + 4);
    offset += 4 + len;
  }
  return out;
}

export function bytesEqual(a: Uint8Array | undefined, b: Uint8Array | undefined): boolean {
  if (!a || !b || a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}
