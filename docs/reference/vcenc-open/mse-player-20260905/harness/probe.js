(() => {
  // The UI names the H.264/H.265 surface `#screen`; the MJPEG mode renders an
  // antd <img> with no id, so fall back to the stream URL / first element.
  const pick = (tag, extra) => document.querySelector(tag + '#screen') ||
    (extra && document.querySelector(extra)) || document.querySelector(tag);
  const c = pick('canvas');
  const v = pick('video');
  const i = pick('img', 'img[src*="/api/stream/"]');
  const sel = (e) => e ? (e.id ? '#' + e.id : (e.getAttribute('class') || '').split(' ')[0] || '(no id)') : null;
  const notes = [...document.querySelectorAll('.ant-notification-notice')]
    .map(n => n.innerText.replace(/\s+/g, ' ').trim());
  let video = null;
  if (v) {
    let q = null;
    try {
      const s = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : null;
      if (s) q = { totalVideoFrames: s.totalVideoFrames, droppedVideoFrames: s.droppedVideoFrames };
    } catch (e) { q = { error: String(e) }; }
    const buf = [];
    try { for (let k = 0; k < v.buffered.length; k++) buf.push([+v.buffered.start(k).toFixed(3), +v.buffered.end(k).toFixed(3)]); }
    catch (e) { buf.push(String(e)); }
    video = {
      el: sel(v),
      videoWidth: v.videoWidth, videoHeight: v.videoHeight,
      currentTime: v.currentTime, readyState: v.readyState,
      networkState: v.networkState, paused: v.paused, ended: v.ended,
      duration: Number.isFinite(v.duration) ? v.duration : String(v.duration), buffered: buf, quality: q,
      srcObject: !!v.srcObject, src: (v.currentSrc || v.src || '').slice(0, 120),
      error: v.error ? { code: v.error.code, message: v.error.message } : null
    };
  }
  return JSON.stringify({
    href: location.href,
    title: document.title,
    storedMode: (() => { try { return localStorage.getItem('nano-kvm-vide-mode'); } catch (e) { return 'ERR ' + e; } })(),
    cookie: document.cookie.split(';').map(s => s.trim().split('=')[0]).join(','),
    canvas: c ? { el: sel(c), width: c.width, height: c.height,
                  clientWidth: c.clientWidth, clientHeight: c.clientHeight } : null,
    video: video,
    img: i ? { el: sel(i), naturalWidth: i.naturalWidth, naturalHeight: i.naturalHeight,
               clientWidth: i.clientWidth, clientHeight: i.clientHeight,
               complete: i.complete, src: (i.currentSrc || i.src || '').slice(0, 120) } : null,
    codecs: { MediaSource: typeof MediaSource, VideoDecoder: typeof VideoDecoder },
    notifications: notes
  });
})()
