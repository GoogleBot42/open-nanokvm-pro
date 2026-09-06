(async () => {
  const v = document.querySelector('video#screen');
  const out = { have: !!v, srcObjectTracks: null, results: {} };
  if (!v) return JSON.stringify(out);
  const src = v.srcObject;
  out.srcObjectTracks = src && src.getVideoTracks ? src.getVideoTracks().length : null;

  async function readTrack(track) {
    try {
      const p = new MediaStreamTrackProcessor({ track });
      const rd = p.readable.getReader();
      const { value: f } = await Promise.race([rd.read(), new Promise(r => setTimeout(() => r({}), 4000))]);
      if (!f) { rd.cancel(); return 'no-frame'; }
      const buf = new Uint8Array(f.allocationSize());
      try {
        await f.copyTo(buf);
        let mx = 0; for (let i = 0; i < Math.min(buf.length, 65536); i++) if (buf[i] > mx) mx = buf[i];
        f.close(); rd.cancel();
        return 'ok format=' + f.format + ' maxLuma=' + mx;
      } catch (e) { f.close(); rd.cancel(); return 'THROW ' + e.name + ': ' + e.message; }
    } catch (e) { return 'SETUP-THROW ' + e.name + ': ' + e.message; }
  }

  // 1. VideoFrame constructed straight from the element
  try {
    const f = new VideoFrame(v, { timestamp: 0 });
    const buf = new Uint8Array(f.allocationSize());
    try {
      await f.copyTo(buf);
      let mx = 0; for (let i = 0; i < Math.min(buf.length, 65536); i++) if (buf[i] > mx) mx = buf[i];
      out.results.videoFrameFromElement = 'ok format=' + f.format + ' maxLuma=' + mx;
    } catch (e) { out.results.videoFrameFromElement = 'THROW ' + e.name + ': ' + e.message; }
    f.close();
  } catch (e) { out.results.videoFrameFromElement = 'CTOR-THROW ' + e.name + ': ' + e.message; }

  // 2. the remote track (WebRTC) if present
  if (src && src.getVideoTracks && src.getVideoTracks()[0]) {
    out.results.remoteTrack = await readTrack(src.getVideoTracks()[0]);
  }

  // 3. captureStream of the element (do NOT stop the track)
  try {
    const cs = v.captureStream();
    const t = cs.getVideoTracks()[0];
    out.results.captureStreamSameAsRemote = !!(src && src.getVideoTracks && src.getVideoTracks()[0] === t);
    out.results.captureStreamTrack = await readTrack(t);
  } catch (e) { out.results.captureStreamTrack = 'CS-THROW ' + e.name + ': ' + e.message; }

  return JSON.stringify(out);
})()
