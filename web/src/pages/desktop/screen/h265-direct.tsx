import { useEffect, useState } from 'react';
import { notification } from 'antd';
import { useTranslation } from 'react-i18next';

import * as api from '@/api/stream.ts';
import * as storage from '@/lib/localstorage.ts';
import { H265_DIRECT_CODEC, H265DecoderConfig, probeH265DirectConfig } from '@/lib/video.ts';

import { DirectPlayer, H264Direct } from './h264-direct.tsx';

// H.265 Direct: the H.264 Direct player pointed at /api/stream/h265/direct
// with an HEVC decoder in the worker. The browser is asked which HEVC
// configuration it accepts (answers logged to the console) and the player is
// mounted regardless -- a WebCodecs probe is advisory, not a verdict. Only an
// actual decoder failure before the first frame falls back to H.264 Direct,
// with a notice, and rewrites the stored mode so the next load starts there.
export const H265Direct = () => {
  const { t } = useTranslation();
  const [notify, contextHolder] = notification.useNotification();
  const [config, setConfig] = useState<H265DecoderConfig | null>(null);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let cancelled = false;

    probeH265DirectConfig().then((accepted) => {
      if (cancelled) return;
      setConfig(accepted ?? { codec: H265_DIRECT_CODEC, hardwareAcceleration: 'no-preference' });
    });

    return () => {
      cancelled = true;
    };
  }, []);

  function onDecoderError(reason: string) {
    console.error(`[h265-direct] decoder failed before the first frame: ${reason}`);

    storage.setVideoMode('h264-direct');
    api.setMode('h264-direct');

    notify.warning({
      key: 'h265_fallback',
      message: t('notification.h265.webcodecs'),
      description: t('notification.h265.fallback'),
      placement: 'topRight',
      duration: 10
    });

    setFailed(true);
  }

  return (
    <>
      {contextHolder}
      {failed && <H264Direct />}
      {!failed && config && (
        <DirectPlayer
          init="init_h265"
          connect={api.directH265}
          decoderConfig={config}
          onDecoderError={onDecoderError}
        />
      )}
    </>
  );
};
