import { useEffect, useRef } from 'react';
import clsx from 'clsx';
import { useAtomValue } from 'jotai';

import * as api from '@/api/stream.ts';
import { type MseCodec, mseCodecSupport } from '@/lib/video.ts';
import { mouseStyleAtom } from '@/jotai/mouse';
import { videoParametersAtom } from '@/jotai/screen.ts';

import MseWorker from './mse.worker.ts?worker';

type MsePlayerProps = {
  codec: MseCodec;
  // opens /api/stream/<codec>/direct
  connect: () => ReturnType<typeof api.directH264>;
  // MediaSource cannot play this stream at all (no MediaSource, or the codec
  // string the stream's parameter sets describe is rejected)
  onUnsupported?: (reason: string) => void;
};

// Live-edge policy (seconds). Beyond MAX_LAG we jump to the edge; between
// NUDGE_LAG and MAX_LAG we play slightly fast; below it, at normal speed.
// EDGE_MARGIN keeps currentTime a frame or two behind the last appended sample
// so the element does not stall waiting for the next one.
const MAX_LAG = 0.25;
const NUDGE_LAG = 0.1;
const EDGE_MARGIN = 0.04;
const KEEP_BEHIND = 4; // seconds of history kept behind the playhead
const TRIM_AT = 8; // trim once this much history has accumulated

const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 5000;

type QueueItem = { kind: 'append'; data: Uint8Array } | { kind: 'changeType'; mime: string };

// Media Source Extensions player for the direct WebSocket streams: a worker
// remuxes [key][ts][Annex-B] messages into fragmented MP4 (lib/mp4), the page
// appends them to a SourceBuffer in sequence mode and keeps playback pinned to
// the live edge. The browser's own media pipeline decodes, so this plays HEVC
// wherever <video> can, independent of WebCodecs.
export const MsePlayer = ({ codec, connect, onUnsupported }: MsePlayerProps) => {
  const videoParameters = useAtomValue(videoParametersAtom);
  const mouseStyle = useAtomValue(mouseStyleAtom);

  const videoRef = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    const tag = `[mse:${codec}]`;
    const support = mseCodecSupport(codec);
    if (!support.supported) {
      const reason = `MediaSource does not accept ${codec}`;
      console.warn(`${tag} ${reason}`);
      onUnsupported?.(reason);
      return;
    }

    let disposed = false;
    let ws: ReturnType<typeof connect> | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let reconnectDelay = RECONNECT_MIN_MS;

    const mediaSource = new MediaSource();
    let sourceBuffer: SourceBuffer | null = null;
    let currentMime = '';
    const queue: QueueItem[] = [];
    let pendingInit: { mime: string; codec: string; data: Uint8Array } | null = null;

    let segments = 0;
    let firstSegmentAt = 0;
    let lastReport = 0;

    const worker = new MseWorker();
    worker.postMessage({ type: 'init', codec, hevcBox: support.hevcBox });

    const objectUrl = URL.createObjectURL(mediaSource);
    video.src = objectUrl;

    function play() {
      if (!video || !video.paused) return;
      video.play().catch((err) => {
        // autoplay policy or a transient state; the next append retries
        if (err?.name !== 'AbortError') console.log(`${tag} play() rejected: ${err?.name ?? err}`);
      });
    }

    // Accept the init segment: create the SourceBuffer (first time), or switch
    // codec string / re-init on a parameter-set change.
    function acceptInit(mime: string, codecString: string, data: Uint8Array) {
      if (mediaSource.readyState !== 'open') {
        pendingInit = { mime, codec: codecString, data };
        return;
      }

      if (!sourceBuffer) {
        const supported = MediaSource.isTypeSupported(mime);
        console.log(`${tag} stream says ${codecString}; isTypeSupported: ${supported}`);
        try {
          sourceBuffer = mediaSource.addSourceBuffer(mime);
        } catch (err: any) {
          const reason = `addSourceBuffer(${mime}) failed: ${err?.name ?? err}`;
          console.error(`${tag} ${reason}`);
          onUnsupported?.(reason);
          return;
        }
        sourceBuffer.mode = 'sequence';
        sourceBuffer.addEventListener('updateend', onUpdateEnd);
        sourceBuffer.addEventListener('error', (e) => console.error(`${tag} SourceBuffer error`, e));
        currentMime = mime;
      } else if (mime !== currentMime) {
        console.log(`${tag} codec changed ${currentMime} -> ${mime}`);
        queue.push({ kind: 'changeType', mime });
        currentMime = mime;
      } else {
        console.log(`${tag} new init segment (same codec ${codecString})`);
      }

      queue.push({ kind: 'append', data });
      pump();
    }

    function pump() {
      const sb = sourceBuffer;
      if (!sb || sb.updating || mediaSource.readyState !== 'open') return;

      const item = queue.shift();
      if (!item) return;

      if (item.kind === 'changeType') {
        if (typeof sb.changeType === 'function') {
          try {
            sb.changeType(item.mime);
          } catch (err) {
            console.error(`${tag} changeType failed: ${err}`);
          }
        } else {
          console.warn(`${tag} changeType unavailable; continuing with ${currentMime}`);
        }
        pump();
        return;
      }

      try {
        sb.appendBuffer(item.data as BufferSource);
      } catch (err: any) {
        if (err?.name === 'QuotaExceededError') {
          // drop history and retry this item after the removal completes
          queue.unshift(item);
          const cut = Math.max(0, video!.currentTime - 1);
          console.warn(`${tag} QuotaExceededError; removing [0, ${cut.toFixed(2)})`);
          if (cut > 0) sb.remove(0, cut);
          else queue.length = 0;
        } else {
          console.error(`${tag} appendBuffer failed: ${err}`);
        }
      }
    }

    function onUpdateEnd() {
      if (disposed || !video) return;
      chaseLiveEdge();
      pump();
    }

    function chaseLiveEdge() {
      const sb = sourceBuffer;
      if (!sb || !video || video.readyState < 1 || sb.updating) return;

      const buffered = video.buffered;
      if (buffered.length === 0) return;

      const end = buffered.end(buffered.length - 1);
      const lag = end - video.currentTime;

      if (video.paused) play();

      if (lag > MAX_LAG || lag < 0) {
        video.currentTime = Math.max(0, end - EDGE_MARGIN);
        video.playbackRate = 1;
      } else if (lag > NUDGE_LAG) {
        video.playbackRate = 1.1;
      } else if (video.playbackRate !== 1) {
        video.playbackRate = 1;
      }

      // keep memory bounded: drop everything well behind the playhead
      const start = buffered.start(0);
      if (video.currentTime - start > TRIM_AT) {
        try {
          sb.remove(0, video.currentTime - KEEP_BEHIND);
        } catch (err) {
          console.log(`${tag} remove failed: ${err}`);
        }
      }
    }

    worker.onmessage = (event: MessageEvent) => {
      if (disposed) return;
      const msg = event.data;
      switch (msg.type) {
        case 'init':
          console.log(`${tag} init segment: ${msg.width}x${msg.height} ${msg.codec} (${msg.data.byteLength} B)`);
          acceptInit(msg.mime, msg.codec, msg.data);
          break;
        case 'segment':
          if (!sourceBuffer && !pendingInit) return; // no init yet
          segments++;
          if (segments === 1) firstSegmentAt = performance.now();
          queue.push({ kind: 'append', data: msg.data });
          pump();
          report();
          break;
        case 'log':
          (console as any)[msg.level ?? 'log'](msg.text);
          break;
      }
    };

    function report() {
      const now = performance.now();
      if (now - lastReport < 5000 || !video) return;
      lastReport = now;
      const q = video.getVideoPlaybackQuality?.();
      const buffered = video.buffered;
      const end = buffered.length ? buffered.end(buffered.length - 1) : 0;
      console.log(
        `${tag} ${segments} segments, ${q?.totalVideoFrames ?? '?'} frames shown (${q?.droppedVideoFrames ?? '?'} dropped), ` +
          `${video.videoWidth}x${video.videoHeight}, lag ${(end - video.currentTime).toFixed(3)}s, rate ${video.playbackRate}, ` +
          `first segment after ${Math.round(firstSegmentAt)} ms`
      );
    }

    mediaSource.addEventListener('sourceopen', () => {
      if (disposed) return;
      console.log(`${tag} MediaSource open`);
      if (pendingInit) {
        const { mime, codec: c, data } = pendingInit;
        pendingInit = null;
        acceptInit(mime, c, data);
      }
    });
    mediaSource.addEventListener('sourceended', () => console.log(`${tag} MediaSource ended`));
    mediaSource.addEventListener('sourceclose', () => console.log(`${tag} MediaSource closed`));

    video.addEventListener('error', () => {
      const e = video.error;
      console.error(`${tag} <video> error ${e?.code}: ${e?.message}`);
    });
    video.addEventListener('loadedmetadata', () => {
      console.log(`${tag} loadedmetadata ${video.videoWidth}x${video.videoHeight}`);
      play();
    });
    video.addEventListener('stalled', () => console.log(`${tag} stalled`));
    video.addEventListener('waiting', () => chaseLiveEdge());

    function open() {
      if (disposed) return;
      const socket = connect();
      ws = socket;
      socket.binaryType = 'arraybuffer';

      socket.onopen = () => {
        reconnectDelay = RECONNECT_MIN_MS;
        console.log(`${tag} WebSocket open`);
      };

      socket.onmessage = (event) => {
        const data = event.data;
        if (!(data instanceof ArrayBuffer)) return;
        worker.postMessage({ type: 'ws_message', data }, [data]);
      };

      socket.onerror = () => {
        console.warn(`${tag} WebSocket error`);
      };

      socket.onclose = () => {
        if (disposed || ws !== socket) return;
        ws = null;
        worker.postMessage({ type: 'reset' });
        console.warn(`${tag} WebSocket closed; reconnecting in ${reconnectDelay} ms`);
        reconnectTimer = setTimeout(() => {
          reconnectTimer = null;
          open();
        }, reconnectDelay);
        reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
      };
    }

    open();

    return () => {
      disposed = true;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      const socket = ws;
      ws = null;
      if (socket && socket.readyState === 1) socket.close();
      worker.terminate();
      try {
        if (mediaSource.readyState === 'open') mediaSource.endOfStream();
      } catch {
        // already detached
      }
      video.removeAttribute('src');
      video.load();
      URL.revokeObjectURL(objectUrl);
    };
  }, []);

  return (
    <div className="flex h-screen w-screen items-start justify-center xl:items-center">
      <video
        id="screen"
        ref={videoRef}
        className={clsx(
          'block max-h-full min-h-[50vh] min-w-[50vw] max-w-full select-none object-scale-down',
          mouseStyle
        )}
        style={{ transform: `scale(${videoParameters.scale})` }}
        muted
        autoPlay
        playsInline
        controls={false}
        onClick={(e) => e.preventDefault()}
        onContextMenu={(e) => e.preventDefault()}
      ></video>
    </div>
  );
};

export const H264Mse = () => <MsePlayer codec="h264" connect={api.directH264} />;
export const H265Mse = () => <MsePlayer codec="h265" connect={api.directH265} />;
