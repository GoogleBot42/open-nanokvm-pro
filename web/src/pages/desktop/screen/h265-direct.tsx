import { useEffect, useState } from 'react';
import { notification } from 'antd';
import { useTranslation } from 'react-i18next';

import * as api from '@/api/stream.ts';
import * as storage from '@/lib/localstorage.ts';
import {
  H265_DIRECT_CODEC,
  H265DecoderConfig,
  isDecoderSupported,
  mseCodecSupport,
  probeH265DirectConfig
} from '@/lib/video.ts';

import { DirectPlayer, H264Direct } from './h264-direct.tsx';
import { MsePlayer } from './mse-player.tsx';

type Player = { kind: 'webcodecs'; config: H265DecoderConfig } | { kind: 'mse' } | { kind: 'h264' };

// H.265 Direct: /api/stream/h265/direct decoded in the browser, by whichever
// pipeline this browser can do it with. WebCodecs (the direct worker, lowest
// latency) when VideoDecoder.isConfigSupported accepts an HEVC configuration;
// otherwise the MSE player, whose <video> element decodes HEVC in browsers
// whose WebCodecs cannot (Firefox, Chrome on Linux). A WebCodecs decoder that
// fails at runtime before its first frame also moves to MSE. Only when neither
// can play HEVC does it fall back to H.264 Direct, with a notice, and rewrite
// the stored mode. Every probe answer and the choice are logged.
export const H265Direct = () => {
  const { t } = useTranslation();
  const [notify, contextHolder] = notification.useNotification();
  const [player, setPlayer] = useState<Player | null>(null);

  useEffect(() => {
    let cancelled = false;

    probeH265DirectConfig().then((accepted) => {
      if (cancelled) return;

      if (accepted) {
        console.log(`[h265-direct] player: WebCodecs (${accepted.codec})`);
        setPlayer({ kind: 'webcodecs', config: accepted });
      } else if (mseCodecSupport('h265').supported) {
        console.log('[h265-direct] player: MSE (WebCodecs accepted no HEVC configuration)');
        setPlayer({ kind: 'mse' });
      } else if (isDecoderSupported()) {
        console.log(`[h265-direct] player: WebCodecs, trying ${H265_DIRECT_CODEC} despite the probe`);
        setPlayer({
          kind: 'webcodecs',
          config: { codec: H265_DIRECT_CODEC, hardwareAcceleration: 'no-preference' }
        });
      } else {
        fallbackToH264('no WebCodecs and no MSE HEVC support');
      }
    });

    return () => {
      cancelled = true;
    };
  }, []);

  function fallbackToH264(reason: string) {
    console.error(`[h265-direct] ${reason}; falling back to H.264 Direct`);

    storage.setVideoMode('h264-direct');
    api.setMode('h264-direct');

    notify.warning({
      key: 'h265_fallback',
      message: t('notification.h265.webcodecs'),
      description: t('notification.h265.fallback'),
      placement: 'topRight',
      duration: 10
    });

    setPlayer({ kind: 'h264' });
  }

  function onDecoderError(reason: string) {
    console.error(`[h265-direct] WebCodecs decoder failed before the first frame: ${reason}`);

    if (mseCodecSupport('h265').supported) {
      console.log('[h265-direct] player: MSE (after the WebCodecs failure)');
      setPlayer({ kind: 'mse' });
      return;
    }

    fallbackToH264('WebCodecs decoder failed and MSE has no HEVC');
  }

  return (
    <>
      {contextHolder}
      {player?.kind === 'h264' && <H264Direct />}
      {player?.kind === 'mse' && (
        <MsePlayer codec="h265" connect={api.directH265} onUnsupported={fallbackToH264} />
      )}
      {player?.kind === 'webcodecs' && (
        <DirectPlayer
          init="init_h265"
          connect={api.directH265}
          decoderConfig={player.config}
          onDecoderError={onDecoderError}
        />
      )}
    </>
  );
};
