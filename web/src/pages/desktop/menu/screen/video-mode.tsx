import { Divider, Popover } from 'antd';
import clsx from 'clsx';
import { useAtom } from 'jotai';
import { CheckIcon, TvMinimalPlayIcon } from 'lucide-react';
import { useTranslation } from 'react-i18next';

import type { VideoMode as TVideoMode } from '@/types';
import { setVideoMode as setCookie } from '@/lib/localstorage.ts';
import { getSupportedVideoModes } from '@/lib/video.ts';
import { videoModeAtom } from '@/jotai/screen.ts';

const videoGroups = [
  {
    key: 'h264',
    name: 'H.264',
    modes: [
      { key: 'h264-webrtc', name: 'H.264 WebRTC' },
      { key: 'h264-direct', name: 'H.264 Direct ' },
      { key: 'h264-mse', name: 'H.264 Direct (MSE)' }
    ]
  },
  {
    key: 'h265',
    name: 'H.265',
    modes: [
      { key: 'h265-direct', name: 'H.265 Direct' },
      { key: 'h265-mse', name: 'H.265 Direct (MSE)' }
    ]
  },
  {
    key: 'mjpeg',
    name: 'MJPEG',
    modes: [{ key: 'mjpeg', name: 'MJPEG' }]
  }
];

export const VideoMode = () => {
  const { t } = useTranslation();
  const [videoMode, setVideoMode] = useAtom(videoModeAtom);

  const supportedVideoModes = getSupportedVideoModes();

  // Swap the player in place (#70). Upstream reloaded the whole page, which
  // tore down the app and closed whatever menu or settings panel the mode was
  // picked from. The Screen component already mounts the player for the mode
  // atom and each player closes its own socket or peer connection on unmount,
  // and menu/screen/index.tsx POSTs the new mode to the server (plus the
  // bitrate/gop/fps/quality it needs) whenever the atom changes -- so setting
  // the atom is the whole job.
  function update(mode: string) {
    if (mode === videoMode || !supportedVideoModes.includes(mode)) return;

    setCookie(mode);
    setVideoMode(mode as TVideoMode);
  }

  const content = (
    <>
      {videoGroups.map((group) => (
        <div key={group.key}>
          {group.modes.map((mode) => (
            <div
              key={mode.key}
              className={clsx(
                'flex select-none items-center rounded py-1.5 pl-1 pr-5 hover:bg-neutral-700/70',
                supportedVideoModes.includes(mode.key)
                  ? 'cursor-pointer'
                  : 'cursor-not-allowed text-neutral-500'
              )}
              onClick={() => update(mode.key)}
            >
              <div className="flex h-[14px] w-[20px] items-end text-blue-500">
                {mode.key === videoMode && <CheckIcon size={15} />}
              </div>
              <span>{mode.name}</span>
            </div>
          ))}

          {group.key !== 'mjpeg' && <Divider style={{ margin: '5px 0' }} />}
        </div>
      ))}
    </>
  );

  return (
    <Popover content={content} placement="rightTop" arrow={false} align={{ offset: [14, 0] }}>
      <div className="flex h-[30px] cursor-pointer items-center space-x-2 rounded pl-3 pr-6 text-neutral-300 hover:bg-neutral-700/70">
        <TvMinimalPlayIcon size={18} />
        <span className="select-none text-sm">{t('screen.video')}</span>
      </div>
    </Popover>
  );
};
