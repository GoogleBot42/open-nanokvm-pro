import { useEffect, useRef } from 'react';
import clsx from 'clsx';
import { useAtomValue } from 'jotai';

import * as api from '@/api/stream.ts';
import type { H265DecoderConfig } from '@/lib/video.ts';
import { mouseStyleAtom } from '@/jotai/mouse';
import { videoParametersAtom } from '@/jotai/screen.ts';

import DirectWorker from './direct.worker.ts?worker';

type DirectPlayerProps = {
  // worker init message: selects the WebCodecs codec
  init: 'init_h264' | 'init_h265';
  // opens the matching /api/stream/<codec>/direct WebSocket
  connect: () => ReturnType<typeof api.directH264>;
  // decoder configuration the worker falls back to when the stream's own
  // parameter sets cannot be read (init_h265)
  decoderConfig?: H265DecoderConfig;
  // the worker's decoder failed before producing a single frame
  onDecoderError?: (reason: string) => void;
};

const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 5000;

// One WebSocket of [key:1][timestamp_us:8 LE][Annex-B] messages, decoded in a
// worker and drawn onto an OffscreenCanvas. Codec-agnostic; H264Direct and
// H265Direct only differ in the props.
export const DirectPlayer = ({ init, connect, decoderConfig, onDecoderError }: DirectPlayerProps) => {
  const videoParameters = useAtomValue(videoParametersAtom);
  const mouseStyle = useAtomValue(mouseStyleAtom);

  const canvasRef = useRef<HTMLCanvasElement>(null);
  const workerRef = useRef<Worker | null>(null);

  useEffect(() => {
    if (!canvasRef.current) {
      return;
    }

    const tag = init === 'init_h265' ? '[direct:h265]' : '[direct:h264]';

    let disposed = false;
    let ws: ReturnType<typeof connect> | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let reconnectDelay = RECONNECT_MIN_MS;

    const worker = new DirectWorker();
    workerRef.current = worker;

    worker.onmessage = (event: MessageEvent) => {
      if (event.data?.type === 'decoder_error') {
        onDecoderError?.(String(event.data.reason));
      }
    };

    const offscreen = canvasRef.current.transferControlToOffscreen();
    worker.postMessage({ type: init, canvas: offscreen, ...decoderConfig }, [offscreen]);

    // Reconnect after a close (#67): upstream left the canvas frozen until the
    // user refreshed, so a nanokvm.service restart, a resolution change that
    // rebuilds the encoder channel or a transient network drop killed the
    // stream for good. The worker owns the canvas and closes its decoder on
    // 'close'/'error', so a reconnect only has to reopen the socket: the
    // decoder rebuilds itself at the next key message, which carries its own
    // parameter sets (see nanokvm-server.nix steps 9 and 10).
    function open() {
      if (disposed) {
        return;
      }

      const socket = connect();
      ws = socket;
      socket.binaryType = 'arraybuffer';

      socket.onopen = () => {
        reconnectDelay = RECONNECT_MIN_MS;
        console.log(`${tag} WebSocket open`);
      };

      socket.onmessage = (event) => {
        try {
          worker.postMessage({ type: 'ws_message', data: event.data }, [event.data]);
        } catch (error) {
          console.error(`${tag} error processing WebSocket message:`, error);
        }
      };

      socket.onerror = () => {
        worker.postMessage({ type: 'error' });
      };

      socket.onclose = () => {
        if (disposed || ws !== socket) {
          return;
        }
        ws = null;
        worker.postMessage({ type: 'close' });
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
      if (reconnectTimer) {
        clearTimeout(reconnectTimer);
      }
      const socket = ws;
      ws = null;
      if (socket && socket.readyState === 1) {
        socket.close();
      }
      worker.terminate();
    };
  }, []);

  return (
    <div className="flex h-screen w-screen items-start justify-center xl:items-center">
      <canvas
        id="screen"
        ref={canvasRef}
        className={clsx(
          'block min-h-[50vh] min-w-[50vw] max-w-full select-none object-scale-down',
          mouseStyle
        )}
        style={{ transform: `scale(${videoParameters.scale})` }}
      ></canvas>
    </div>
  );
};

export const H264Direct = () => <DirectPlayer init="init_h264" connect={api.directH264} />;
