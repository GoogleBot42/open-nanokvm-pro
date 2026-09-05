import Queue from 'yocto-queue';

type DecoderConfig = {
  codec: string;
  optimizeForLatency: boolean;
  hardwareAcceleration?: 'no-preference' | 'prefer-hardware' | 'prefer-software';
};

let canvas: OffscreenCanvas | null = null;
let ctx: OffscreenCanvasRenderingContext2D | null = null;
let rendering: boolean = false;
let decoder: VideoDecoder | null = null;
let config: DecoderConfig | null = null;

// Decoder configurations to try, in order, and how far we got. Filled at the
// first key message: for H.265 the string derived from the stream's own VPS
// comes first, then the configuration the page asked for. A decoder that
// fails before its first frame moves to the next candidate; when none is
// left the page is told (decoder_error) so it can fall back.
let configCandidates: DecoderConfig[] = [];
let candidateIndex = 0;
let framesDecoded = 0;

const frameQueue = new Queue<VideoFrame>();

// parameter-set messages received before a key message (see handleWsMessage)
let pendingParams: Uint8Array[] = [];

self.onmessage = (event: MessageEvent) => {
  const { type, data, canvas: offscreenCanvas } = event.data;

  switch (type) {
    case 'init_h264':
      canvas = offscreenCanvas;
      ctx = canvas!.getContext('2d') as OffscreenCanvasRenderingContext2D;
      config = {
        codec: 'avc1.42E01F',
        optimizeForLatency: true
      };
      break;
    case 'init_h265':
      canvas = offscreenCanvas;
      ctx = canvas!.getContext('2d') as OffscreenCanvasRenderingContext2D;
      // No description: Annex-B with in-band VPS/SPS/PPS on every key message.
      // The codec string is derived from the VPS when the first key message
      // arrives; this is what the page's probe accepted (or its default) and
      // serves as the fallback. Keep the default in step with
      // H265_DIRECT_CODEC in lib/video.ts.
      config = {
        codec: event.data.codec || 'hvc1.1.6.L153.B0',
        hardwareAcceleration: event.data.hardwareAcceleration || 'no-preference',
        optimizeForLatency: true
      };
      break;
    case 'ws_message':
      handleWsMessage(data);
      break;
    case 'error':
    case 'close':
      resetDecoder();
      break;
  }
};

// offset of the NAL header after a 3- or 4-byte Annex-B start code
function nalHeaderOffset(data: Uint8Array): number {
  return data[2] === 1 ? 3 : 4;
}

// Annex-B NAL is a parameter set: SPS/PPS for H.264, VPS/SPS/PPS for H.265
function isParameterSet(data: Uint8Array): boolean {
  const header = nalHeaderOffset(data);
  if (!config || data.length <= header) {
    return false;
  }

  if (isH265()) {
    const type = (data[header] >> 1) & 0x3f;
    return type >= 32 && type <= 34;
  }

  const type = data[header] & 0x1f;
  return type === 7 || type === 8;
}

function isH265(): boolean {
  return !!config && /^(hvc1|hev1)/.test(config.codec);
}

function concat(parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const p of parts) {
    out.set(p, offset);
    offset += p.length;
  }
  return out;
}

// ISO/IEC 14496-15 Annex E codec string from the VPS that opens an H.265 key
// message: hvc1.<profile>.<compat flags>.<L|H><level>.<constraint bytes>.
// The general profile_tier_level sits at a fixed offset in the VPS (no
// exp-Golomb before it), so this is byte picking once the emulation-prevention
// bytes (00 00 03 -> 00 00) are stripped. Returns null if the message does not
// start with a VPS.
function h265CodecFromVps(data: Uint8Array): string | null {
  const header = nalHeaderOffset(data);
  if (data.length <= header || ((data[header] >> 1) & 0x3f) !== 32) {
    return null;
  }

  // NAL header (2) + the 32 VPS bits before profile_tier_level (4) + PTL (12)
  const body: number[] = [];
  let zeros = 0;
  for (let i = header; i < data.length && body.length < 18; i++) {
    const b = data[i];
    if (zeros >= 2 && b === 3) {
      zeros = 0;
      continue;
    }
    body.push(b);
    zeros = b === 0 ? zeros + 1 : 0;
  }
  if (body.length < 18) {
    return null;
  }

  const ptl = 6;
  const profileSpace = body[ptl] >> 6;
  const tier = (body[ptl] >> 5) & 1;
  const profileIdc = body[ptl] & 0x1f;

  // general_profile_compatibility_flag[j] becomes bit j of the hex value
  // ("reverse bit order": Main profile with flags 1 and 2 set is "6")
  let compat = 0;
  for (let j = 0; j < 32; j++) {
    const bit = (body[ptl + 1 + (j >> 3)] >> (7 - (j & 7))) & 1;
    if (bit) compat |= 1 << j;
  }

  const constraints: string[] = [];
  for (let k = 0; k < 6; k++) {
    constraints.push(body[ptl + 5 + k].toString(16).toUpperCase().padStart(2, '0'));
  }
  while (constraints.length > 0 && constraints[constraints.length - 1] === '00') {
    constraints.pop();
  }

  const levelIdc = body[ptl + 11];

  const space = ['', 'A', 'B', 'C'][profileSpace];
  const parts = [
    'hvc1',
    `${space}${profileIdc}`,
    (compat >>> 0).toString(16).toUpperCase(),
    `${tier ? 'H' : 'L'}${levelIdc}`,
    ...constraints
  ];
  return parts.join('.');
}

function handleWsMessage(message: ArrayBuffer) {
  try {
    if (message.byteLength < 9) {
      return;
    }

    const view = new DataView(message);
    const isKeyFrame = view.getUint8(0) === 1;
    const timestamp = Number(view.getBigUint64(1, true));
    let data = new Uint8Array(message, 9);

    // A server that sends SPS/PPS (VPS/SPS/PPS) as their own non-key messages
    // ahead of each IDR: hold them and prepend them to that key message, so
    // every key chunk carries its parameter sets -- Chromium's H.264 decoder
    // fails on one that does not. Current servers fold them in already, so
    // this stays empty.
    if (!isKeyFrame && isParameterSet(data)) {
      pendingParams.push(data.slice());
      return;
    }

    if (isKeyFrame && pendingParams.length > 0) {
      data = concat([...pendingParams, data]);
      pendingParams = [];
    }

    if (!decoder && isKeyFrame) {
      initializeDecoder(data);
    }

    if (decoder?.state === 'configured') {
      decode(isKeyFrame, timestamp, data);
    }
  } catch (error) {
    console.error('Error processing WebSocket message in worker:', error);
  }
}

function initializeDecoder(firstKeyData: Uint8Array) {
  if (!self.VideoDecoder) {
    console.log('Error: WebCodecs API not supported in this worker.');
    return;
  }

  if (!config || (decoder && decoder.state !== 'unconfigured')) {
    return;
  }

  if (configCandidates.length === 0) {
    configCandidates = [config];
    if (isH265()) {
      const derived = h265CodecFromVps(firstKeyData);
      console.log(`[direct] stream VPS says ${derived}; page asked for ${config.codec}`);
      if (derived && derived !== config.codec) {
        configCandidates.unshift({ ...config, codec: derived });
      }
    }
  }

  if (candidateIndex >= configCandidates.length) {
    return;
  }
  const attempt = configCandidates[candidateIndex];

  const init = {
    output: (frame: VideoFrame) => {
      framesDecoded++;

      frameQueue.enqueue(frame);
      if (frameQueue.size >= 10) {
        frameQueue.dequeue()?.close();
      }

      if (!rendering) {
        rendering = true;
        processFrameQueue();
      }
    },
    error: (err: DOMException) => {
      if (framesDecoded === 0) {
        decoderFailed(attempt, `${err.name}: ${err.message}`);
      } else {
        resetDecoder();
      }
    }
  };

  try {
    decoder = new VideoDecoder(init);
    decoder.configure(attempt);
    console.log(`[direct] decoder configured: ${attempt.codec} (${attempt.hardwareAcceleration ?? 'default'})`);
  } catch (err: any) {
    decoder = null;
    decoderFailed(attempt, `configure threw ${err?.name ?? ''}: ${err?.message ?? err}`);
  }
}

// A decoder configuration failed before producing a frame: try the next one
// at the next key message, or tell the page when none is left.
function decoderFailed(attempt: DecoderConfig, reason: string) {
  console.warn(`[direct] decoder ${attempt.codec} failed before the first frame: ${reason}`);
  resetDecoder();
  candidateIndex++;

  if (candidateIndex >= configCandidates.length) {
    self.postMessage({ type: 'decoder_error', reason: `${attempt.codec}: ${reason}` });
  }
}

function decode(isKeyFrame: boolean, timestamp: number, data: Uint8Array) {
  const chunk = new EncodedVideoChunk({
    type: isKeyFrame ? 'key' : 'delta',
    timestamp: timestamp,
    data: data
  });

  try {
    decoder?.decode(chunk);
  } catch (err: any) {
    if (err.name === 'TypeError' || err.message.includes('configured')) {
      resetDecoder();
    }
  }
}

function processFrameQueue() {
  const frame = frameQueue.dequeue();
  if (frame) {
    renderFrame(frame);
  }

  if (frameQueue.size > 0) {
    setTimeout(processFrameQueue, 0);
  } else {
    rendering = false;
  }
}

function renderFrame(frame: VideoFrame) {
  if (!canvas || !ctx) {
    frame.close();
    return;
  }

  if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
    canvas.width = frame.displayWidth;
    canvas.height = frame.displayHeight;
  }

  ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
  frame.close();
}

function resetDecoder() {
  if (decoder && decoder.state !== 'closed') {
    try {
      decoder.close();
    } catch (err) {
      console.log(err);
    }
  }

  decoder = null;
  rendering = false;
  pendingParams = [];

  Array.from(frameQueue.drain()).forEach((frame) => frame.close());
}
