// h264-mse / h265-mse are client-side players over the h264-direct /
// h265-direct server streams (lib/video.ts serverStreamMode).
export type VideoMode =
  | 'h265-webrtc'
  | 'h265-direct'
  | 'h265-mse'
  | 'h264-webrtc'
  | 'h264-direct'
  | 'h264-mse'
  | 'mjpeg';

export interface VideoParameters {
  rateControlMode: string; // cbr | vbr;
  bitrate: number;
  gop: number;
  fps: number;
  scale: number;
  quality?: number; // MJEPG only
}

export enum VideoStatus {
  Normal = 1,
  NoImage = -1,
  VencError = -2,
  ImageBufferFull = -3,
  InconsistentVideoMode = -4
}
