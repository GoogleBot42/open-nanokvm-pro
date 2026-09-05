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

    const worker = new DirectWorker();
    workerRef.current = worker;

    worker.onmessage = (event: MessageEvent) => {
      if (event.data?.type === 'decoder_error') {
        onDecoderError?.(String(event.data.reason));
      }
    };

    const offscreen = canvasRef.current.transferControlToOffscreen();
    worker.postMessage({ type: init, canvas: offscreen, ...decoderConfig }, [offscreen]);

    const ws = connect();
    ws.binaryType = 'arraybuffer';

    ws.onmessage = (event) => {
      try {
        worker.postMessage({ type: 'ws_message', data: event.data }, [event.data]);
      } catch (error) {
        console.error('Error processing WebSocket message:', error);
      }
    };

    ws.onerror = () => {
      worker.postMessage({ type: 'error' });
    };

    ws.onclose = () => {
      worker.postMessage({ type: 'close' });
    };

    return () => {
      if (ws.readyState === 1) {
        ws.close();
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
