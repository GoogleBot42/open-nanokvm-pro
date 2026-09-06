import { useEffect } from 'react';
import { notification } from 'antd';
import { useAtom } from 'jotai';
import { useTranslation } from 'react-i18next';
import { useMediaQuery } from 'react-responsive';

import { VideoMode } from '@/types';
import * as storage from '@/lib/localstorage.ts';
import { resolveVideoMode } from '@/lib/video.ts';
import { client } from '@/lib/websocket.ts';
import { videoModeAtom, videoPaintNoticeAtom } from '@/jotai/screen.ts';
import { Head } from '@/components/head.tsx';

import { Keyboard } from './keyboard';
import { Menu } from './menu';
import { Message } from './message.tsx';
import { Mouse } from './mouse';
import { Notification } from './notification.tsx';
import { Screen } from './screen';
import { VirtualKeyboard } from './virtual-keyboard';

export const Desktop = () => {
  const { t } = useTranslation();
  const isBigScreen = useMediaQuery({ minWidth: 850 });

  const [videoMode, setVideoMode] = useAtom(videoModeAtom);
  const [paintNotice, setPaintNotice] = useAtom(videoPaintNoticeAtom);
  const [notify, contextHolder] = notification.useNotification();

  useEffect(() => {
    client.connect();

    // Honour the stored mode when this browser can play it; otherwise start the
    // nearest mode that can AND rewrite the stored value, so the menu, the next
    // reload and the picture all agree (upstream left a rejected stored mode in
    // place and quietly started the WebRTC player).
    const resolved = resolveVideoMode(storage.getVideoMode());
    if (resolved.replaced) {
      storage.setVideoMode(resolved.mode);
      notify.warning({
        key: 'video_mode_unsupported',
        message: t('notification.videoMode.title'),
        description: t('notification.videoMode.description', {
          stored: resolved.replaced,
          mode: resolved.mode
        }),
        placement: 'topRight',
        duration: 10
      });
    }
    setVideoMode(resolved.mode as VideoMode);

    return () => {
      client.close();
    };
  }, []);

  // The <video> paint check (#69) fires from inside a player that its own
  // fallback then unmounts, so the notice is shown from here instead.
  useEffect(() => {
    if (!paintNotice) return;

    notify.warning({
      key: 'video_paint',
      message: t('notification.videoPaint.title'),
      description:
        paintNotice === 'switched'
          ? t('notification.videoPaint.description')
          : t('notification.videoPaint.stay'),
      placement: 'topRight',
      duration: 0
    });

    setPaintNotice(null);
  }, [paintNotice]);

  return (
    <>
      <Head title={t('head.desktop')} />
      {contextHolder}

      {isBigScreen && (
        <>
          <Message />
          <Notification />
        </>
      )}

      {videoMode && (
        <>
          <Menu />
          <Screen />
          <Mouse />
          <Keyboard />
        </>
      )}

      <VirtualKeyboard />
    </>
  );
};
