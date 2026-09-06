import { useEffect, type RefObject } from 'react';
import { useAtomValue, useSetAtom } from 'jotai';

import * as api from '@/api/stream.ts';
import type { VideoMode } from '@/types';
import * as storage from '@/lib/localstorage.ts';
import { getSupportedVideoModes } from '@/lib/video.ts';
import { videoModeAtom, videoPaintNoticeAtom } from '@/jotai/screen.ts';

// Give the pipeline a couple of seconds of real playback before judging it,
// then allow four attempts a second apart before declaring the picture lost.
const START_DELAY_MS = 2000;
const RETRY_MS = 1000;
const MAX_ATTEMPTS = 4;

// Debug-only: `localStorage.setItem('nano-kvm-debug-force-undrawable', '1')`
// makes every probe read as unreadable, so the fallback path can be exercised
// on a browser that paints correctly. Never set in normal use.
const FORCE_UNDRAWABLE_KEY = 'nano-kvm-debug-force-undrawable';

// Set once this tab has auto-switched away from a <video> mode. If the user
// then picks a <video> mode again (the menu reloads the page, sessionStorage
// survives it), a second detection only notifies -- it never fights the choice.
const FALLBACK_FLAG_KEY = 'nano-kvm-video-paint-fallback';

type Verdict = 'readable' | 'unreadable' | 'inconclusive';

/**
 * The discriminator, deliberately one small function.
 *
 * Measured for issue #69 on the same page in the same Chromium, KWin, once
 * with `--enable-features=Vulkan` and once without:
 *
 *   broken (screen 94% white): `new VideoFrame(video)` builds, then
 *     `copyTo()` throws `InvalidStateError: Failed to read VideoFrame data`
 *   healthy (screen shows the desktop): `copyTo()` resolves, format NV12,
 *     max luma 237
 *
 * It has to be a frame taken from the ELEMENT. Reading the WebRTC remote
 * track, or a `captureStream()` track, succeeds in BOTH states (max luma 236
 * either way) -- frames do leave the decoder; it is the element's own output
 * that is lost. Pixel sampling cannot be used either: every GPU-side read (2D
 * drawImage, WebGL readPixels, createImageBitmap) comes back opaque black
 * under Vulkan, which is exactly what a genuinely black picture looks like on
 * a healthy browser.
 *
 * Anything but InvalidStateError says nothing about painting, so it is
 * inconclusive and the check simply stops.
 */
export function classifyCopyFailure(err: unknown): Exclude<Verdict, 'readable'> {
  const name = (err as { name?: string } | null)?.name;
  return name === 'InvalidStateError' ? 'unreadable' : 'inconclusive';
}

// The defect is Chromium's Vulkan backend. Firefox plays these modes correctly
// (and is the only browser here that plays H.265 at all), so it must never be
// pushed off a <video> mode on the strength of a WebCodecs error of its own.
export function isChromiumFamily(ua: string): boolean {
  return ua.includes('Chrome/') && !ua.includes('Firefox');
}

function readFlag(store: Storage | undefined, key: string): boolean {
  try {
    return store?.getItem(key) === '1';
  } catch {
    return false;
  }
}

function setFlag(store: Storage | undefined, key: string) {
  try {
    store?.setItem(key, '1');
  } catch {
    // private mode / storage disabled: the flag is an optimisation, not state
  }
}

/**
 * Watch a playing <video> for the failure where the browser decodes frames but
 * never paints them, and fall back to H.264 Direct (canvas + WebCodecs, which
 * paints through a different path) with a notice naming the trigger.
 *
 * For the <video>-element players only -- the canvas players cannot hit this.
 * The notice is raised through `videoPaintNoticeAtom` rather than shown here,
 * because the fallback unmounts this player (and with it anything it renders).
 */
export function useUndrawableVideoDetector(videoRef: RefObject<HTMLVideoElement | null>) {
  const videoMode = useAtomValue(videoModeAtom);
  const setVideoMode = useSetAtom(videoModeAtom);
  const setPaintNotice = useSetAtom(videoPaintNoticeAtom);

  const mode = videoMode ?? 'video';

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;
    if (typeof (window as any).VideoFrame !== 'function') return;
    if (!isChromiumFamily(navigator.userAgent)) return;

    const tag = `[video-paint] ${mode}`;

    let stopped = false;
    let started = false;
    let attempts = 0;
    let timer: ReturnType<typeof setTimeout> | null = null;

    video.addEventListener('playing', onPlaying);
    if (!video.paused && video.readyState >= 3) onPlaying();

    function onPlaying() {
      if (started || stopped) return;
      started = true;
      timer = setTimeout(run, START_DELAY_MS);
    }

    function stop() {
      stopped = true;
      if (timer) clearTimeout(timer);
      video?.removeEventListener('playing', onPlaying);
    }

    // Take one frame from the element and copy it to memory.
    async function probeOnce(): Promise<Verdict> {
      if (readFlag(window.localStorage, FORCE_UNDRAWABLE_KEY)) return 'unreadable';
      if (!video || video.readyState < 2) return 'inconclusive';

      let frame: any = null;
      try {
        frame = new (window as any).VideoFrame(video, { timestamp: 0 });
        const buf = new Uint8Array(frame.allocationSize());
        await frame.copyTo(buf);
        return 'readable';
      } catch (err: any) {
        const verdict = classifyCopyFailure(err);
        console.log(`${tag}: frame read ${verdict} (${err?.name}: ${err?.message})`);
        return verdict;
      } finally {
        try {
          frame?.close();
        } catch {
          /* already closed */
        }
      }
    }

    async function run() {
      if (stopped) return;
      attempts++;

      const verdict = await probeOnce();
      if (stopped) return;

      if (verdict === 'readable') {
        console.log(`${tag}: video frames are readable; paint check done`);
        stop();
        return;
      }

      if (verdict === 'inconclusive') {
        stop();
        return;
      }

      if (attempts < MAX_ATTEMPTS) {
        timer = setTimeout(run, RETRY_MS);
        return;
      }

      stop();
      onUndrawable();
    }

    function onUndrawable() {
      const alreadyFellBack = readFlag(window.sessionStorage, FALLBACK_FLAG_KEY);
      const haveH264Direct = getSupportedVideoModes().includes('h264-direct');
      const switching = haveH264Direct && !alreadyFellBack;

      const why =
        'Chromium is not painting decoded video frames (chrome://flags/#enable-vulkan does this)';

      if (switching) {
        console.warn(`${tag}: ${why}; switching to h264-direct`);
      } else if (alreadyFellBack) {
        console.warn(
          `${tag}: ${why}; this mode was chosen after an earlier fallback, leaving it alone`
        );
      } else {
        console.warn(`${tag}: ${why}; h264-direct is unavailable here`);
      }

      setPaintNotice(switching ? 'switched' : 'stay');

      if (!switching) return;

      setFlag(window.sessionStorage, FALLBACK_FLAG_KEY);
      storage.setVideoMode('h264-direct');
      api.setMode('h264-direct');
      setVideoMode('h264-direct' as VideoMode);
    }

    return () => {
      stop();
    };
  }, []);
}
