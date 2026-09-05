// Remux worker for the MSE player: WebSocket messages in, fMP4 init / media
// segments out (transferred). The SourceBuffer itself lives on the page --
// MSE-in-workers is not available everywhere HEVC playback is.
// relative: the worker bundle does not get the tsconfig path alias
import { Remuxer, type RemuxCodec } from '../../../lib/mp4/remuxer.ts';

let remuxer: Remuxer | null = null;

self.onmessage = (event: MessageEvent) => {
  const { type } = event.data;

  switch (type) {
    case 'init':
      remuxer = new Remuxer(event.data.codec as RemuxCodec, event.data.hevcBox);
      break;
    case 'reset':
      remuxer?.reset();
      break;
    case 'ws_message':
      if (!remuxer) return;
      for (const ev of remuxer.feed(event.data.data as ArrayBuffer)) {
        if (ev.type === 'log') {
          self.postMessage(ev);
        } else {
          self.postMessage(ev, [ev.data.buffer as ArrayBuffer]);
        }
      }
      break;
  }
};
