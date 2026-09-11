import { Image } from 'antd';
import clsx from 'clsx';
import { useAtomValue, useSetAtom } from 'jotai';

import MonitorXIcon from '@/assets/images/monitor-x.svg';
import { VideoStatus } from '@/types';
import { getBaseUrl } from '@/lib/service.ts';
import { mouseStyleAtom } from '@/jotai/mouse.ts';
import { videoParametersAtom, videoStatusAtom } from '@/jotai/screen.ts';

export const Mjpeg = () => {
  const videoParameters = useAtomValue(videoParametersAtom);
  const mouseStyle = useAtomValue(mouseStyleAtom);
  const setVideoStatus = useSetAtom(videoStatusAtom);

  const url = `${getBaseUrl('http')}/api/stream/mjpeg`;

  // The <img> tells us a load failed but never why, and this page has no
  // status channel of its own (unlike WebRTC, which carries one). Ask the
  // route: since #98 it answers 503 with a code instead of holding the
  // connection open and sending nothing, so a source the device cannot
  // capture becomes a message rather than a broken-image icon.
  async function onError() {
    try {
      const response = await fetch(url, { credentials: 'include' });
      if (response.status !== 503) return;

      const body = await response.json();
      if (body?.code === VideoStatus.UnsupportedMode) {
        setVideoStatus(VideoStatus.UnsupportedMode);
      }
    } catch {
      // offline, or the route answered something we do not model: leave the
      // fallback icon to speak for itself.
    }
  }

  return (
    <div className="flex h-screen w-screen items-start justify-center xl:items-center">
      <Image
        id="screen"
        className={clsx(
          'block max-h-screen min-h-[50vh] min-w-[50vw] select-none object-scale-down',
          mouseStyle
        )}
        style={{ transform: `scale(${videoParameters.scale})` }}
        src={url}
        fallback={MonitorXIcon}
        preview={false}
        onError={onError}
      />
    </div>
  );
};
