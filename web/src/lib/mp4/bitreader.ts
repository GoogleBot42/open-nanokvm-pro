// MSB-first bit reader over an RBSP (emulation-prevention bytes already
// removed), with the Exp-Golomb codes H.264/H.265 parameter sets are written in.
export class BitReader {
  private pos = 0; // bit position

  constructor(private readonly data: Uint8Array) {}

  u(n: number): number {
    let v = 0;
    for (let i = 0; i < n; i++) {
      const byte = this.data[this.pos >> 3];
      if (byte === undefined) {
        throw new RangeError('bitstream ended early');
      }
      v = (v << 1) | ((byte >> (7 - (this.pos & 7))) & 1);
      this.pos++;
    }
    return v >>> 0;
  }

  flag(): boolean {
    return this.u(1) === 1;
  }

  skip(n: number): void {
    this.pos += n;
    if (this.pos > this.data.length * 8) {
      throw new RangeError('bitstream ended early');
    }
  }

  // ue(v): leading zeros, a one, then that many bits
  ue(): number {
    let zeros = 0;
    while (this.u(1) === 0) {
      zeros++;
      if (zeros > 31) {
        throw new RangeError('exp-golomb code too long');
      }
    }
    return zeros === 0 ? 0 : (1 << zeros) - 1 + this.u(zeros);
  }

  se(): number {
    const k = this.ue();
    return k & 1 ? (k + 1) / 2 : -(k / 2);
  }
}

// Strip emulation-prevention bytes (00 00 03 -> 00 00) from a NAL unit body.
export function toRbsp(nal: Uint8Array, start = 0): Uint8Array {
  const out = new Uint8Array(nal.length - start);
  let n = 0;
  let zeros = 0;
  for (let i = start; i < nal.length; i++) {
    const b = nal[i];
    if (zeros >= 2 && b === 3) {
      zeros = 0;
      continue;
    }
    out[n++] = b;
    zeros = b === 0 ? zeros + 1 : 0;
  }
  return out.subarray(0, n);
}
