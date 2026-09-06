import { atom } from 'jotai';

import { VideoMode, VideoParameters, VideoStatus } from '@/types';

export const videoModeAtom = atom<VideoMode | null>(null);

export const videoParametersAtom = atom<VideoParameters>({
  rateControlMode: 'vbr', // cbr | vbr
  bitrate: 8000, // 1000 - 20000
  gop: 50, // 1 - 200
  fps: 0, // 0 - 120
  scale: 1,
  quality: 80 // 1-100 (only for mjpeg)
});

// Raised by the <video> paint check (#69) when this browser decodes frames it
// never paints. Held here, not in the player, because acting on it unmounts
// the player: 'switched' = H.264 Direct took over, 'stay' = it could not.
export const videoPaintNoticeAtom = atom<'switched' | 'stay' | null>(null);

export const videoStatusAtom = atom<VideoStatus>(VideoStatus.Normal);

export const videoVolumeAtom = atom(0);
