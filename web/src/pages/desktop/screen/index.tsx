import { useAtomValue } from 'jotai';

import { videoModeAtom } from '@/jotai/screen.ts';

import { H264Direct } from './h264-direct.tsx';
import { H264Webrtc } from './h264-webrtc.tsx';
import { H265Direct } from './h265-direct.tsx';
import { Mjpeg } from './mjpeg.tsx';
import { H264Mse, H265Mse } from './mse-player.tsx';

export const Screen = () => {
  const videoMode = useAtomValue(videoModeAtom);

  if (videoMode === 'mjpeg') {
    return <Mjpeg />;
  }

  if (videoMode === 'h264-direct') {
    return <H264Direct />;
  }

  if (videoMode === 'h264-mse') {
    return <H264Mse />;
  }

  if (videoMode === 'h265-direct') {
    return <H265Direct />;
  }

  if (videoMode === 'h265-mse') {
    return <H265Mse />;
  }

  return <H264Webrtc />;
};
