import { useEffect, useState } from 'react';

// Tracks the video surface (`#screen`), which is mounted by whichever player
// the current video mode picked -- and some of them mount it LATE: H.265
// Direct renders nothing until an async codec probe resolves and chooses
// WebCodecs or MSE, so `#screen` appears one or more ticks after the mouse
// handlers mount. Reading `document.getElementById('screen')` once, at mount,
// therefore bound nothing on that path and input was dead (#73) while the
// explicit `h265-mse` mode -- which mounts its <video> synchronously -- was
// fine. Observing the DOM instead rebinds when the element first appears AND
// when it is replaced (mode switch, WebCodecs -> MSE demotion, player remount).
export function useScreenElement(): HTMLElement | null {
  const [screen, setScreen] = useState<HTMLElement | null>(null);

  useEffect(() => {
    // setState with an updater that returns the previous value is a no-op in
    // React, so an unrelated mutation costs one getElementById and no render.
    const read = () =>
      setScreen((prev) => {
        const el = document.getElementById('screen');
        return el === prev ? prev : el;
      });

    read();

    const observer = new MutationObserver(read);
    observer.observe(document.body, { childList: true, subtree: true });

    return () => observer.disconnect();
  }, []);

  return screen;
}
