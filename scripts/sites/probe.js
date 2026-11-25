// Loaded into the probe page; the checks call these through the javascript tool.
window.wait = ms => new Promise(r => setTimeout(r, ms));

// Plays a file muted and says whether frames and time really moved.
window.playFile = async (name, kind) => {
  const el = document.createElement(kind || (/\.(m4a|mp3|ogg|flac|wav|aiff|ac3)$/.test(name) || name.startsWith('opus') ? 'audio' : 'video'));
  el.muted = true; el.playsInline = true; el.preload = 'auto';
  document.body.appendChild(el);
  let err = null;
  el.onerror = () => { err = el.error ? `${el.error.code} ${el.error.message}` : 'error'; };
  el.src = name;
  let playErr = null;
  try { await Promise.race([el.play(), wait(5000)]); } catch (e) { playErr = String(e.name + ': ' + e.message); }
  for (let i = 0; i < 25 && !err && el.currentTime < 0.5 && !el.ended; i++) await wait(200);
  const q = el.getVideoPlaybackQuality ? el.getVideoPlaybackQuality() : null;
  const r = {
    plays: !err && el.currentTime > 0.3,
    time: +el.currentTime.toFixed(2), err, playErr,
    w: el.videoWidth || 0, frames: q ? q.totalVideoFrames : null, dropped: q ? q.droppedVideoFrames : null,
  };
  el.pause(); el.remove();
  return r;
};

// Media Source Extensions: the type is supported, the file appends and plays.
window.mse = async (name, type) => {
  const r = { supported: MediaSource.isTypeSupported(type) };
  if (!r.supported) return r;
  const v = document.createElement('video'); v.muted = true; document.body.appendChild(v);
  const ms = new MediaSource(); v.src = URL.createObjectURL(ms);
  try {
    await new Promise((ok, no) => { ms.onsourceopen = ok; setTimeout(() => no(new Error('no sourceopen')), 4000); });
    const sb = ms.addSourceBuffer(type);
    const data = await (await fetch(name)).arrayBuffer();
    await new Promise((ok, no) => { sb.onupdateend = ok; sb.onerror = () => no(new Error('append error')); sb.appendBuffer(data); });
    ms.endOfStream();
    await Promise.race([v.play(), wait(4000)]);
    for (let i = 0; i < 20 && v.currentTime < 0.5; i++) await wait(200);
    r.plays = v.currentTime > 0.3; r.time = +v.currentTime.toFixed(2); r.w = v.videoWidth;
    r.err = v.error ? v.error.message : null;
  } catch (e) { r.plays = false; r.err = String(e.message || e); }
  v.remove();
  return r;
};

window.capabilities = async () => {
  const v = document.createElement('video'), a = document.createElement('audio');
  const types = {
    'video/mp4; codecs="avc1.42E01E"': v, 'video/mp4; codecs="avc1.6E0028"': v, 'video/mp4; codecs="hvc1.1.6.L93.B0"': v,
    'video/mp4; codecs="hev1.2.4.L120.B0"': v, 'video/mp4; codecs="dvh1.05.06"': v, 'video/mp4; codecs="av01.0.05M.08"': v,
    'video/mp4; codecs="av01.0.12M.10"': v, 'video/webm; codecs="vp9"': v, 'video/mp4; codecs="vp09.02.10.10"': v,
    'video/webm; codecs="vp8"': v, 'video/ogg; codecs="theora"': v, 'video/quicktime': v, 'video/x-matroska': v,
    'application/vnd.apple.mpegurl': v, 'application/x-mpegURL': v, 'application/dash+xml': v,
    'audio/mp4; codecs="mp4a.40.2"': a, 'audio/mp4; codecs="mp4a.40.5"': a, 'audio/mp4; codecs="mp4a.40.29"': a,
    'audio/mpeg': a, 'audio/ogg; codecs="opus"': a, 'audio/ogg; codecs="vorbis"': a, 'audio/webm; codecs="opus"': a,
    'audio/flac': a, 'audio/mp4; codecs="flac"': a, 'audio/mp4; codecs="alac"': a, 'audio/mp4; codecs="ac-3"': a,
    'audio/mp4; codecs="ec-3"': a, 'audio/wav': a, 'audio/aiff': a,
  };
  const canPlay = {};
  for (const [t, el] of Object.entries(types)) canPlay[t] = el.canPlayType(t) || 'no';
  const mseTypes = {};
  for (const t of Object.keys(types)) if (t.includes('codecs')) mseTypes[t] = MediaSource.isTypeSupported(t);
  // Hardware decoding, as the browser reports it (powerEfficient).
  const mc = {};
  for (const [label, contentType] of [['h264 1080p', 'video/mp4; codecs="avc1.640028"'], ['hevc 4K', 'video/mp4; codecs="hvc1.1.6.L153.B0"'],
    ['hevc main10 HDR', 'video/mp4; codecs="hvc1.2.4.L153.B0"'], ['av1 4K', 'video/mp4; codecs="av01.0.12M.08"'],
    ['vp9 4K', 'video/webm; codecs="vp09.00.51.08"'], ['vp9 profile 2 HDR', 'video/webm; codecs="vp09.02.51.10"']]) {
    try {
      const big = /4K|HDR/.test(label);
      const i = await navigator.mediaCapabilities.decodingInfo({ type: 'media-source', video: {
        contentType, width: big ? 3840 : 1920, height: big ? 2160 : 1080, bitrate: 20e6, framerate: 30,
        ...(label.includes('HDR') ? { transferFunction: 'pq', colorGamut: 'rec2020', hdrMetadataType: 'smpteSt2086' } : {}) } });
      mc[label] = `${i.supported ? 'supported' : 'NO'}${i.smooth ? ' smooth' : ''}${i.powerEfficient ? ' hardware' : ''}`;
    } catch (e) { mc[label] = 'error ' + e.message; }
  }
  const webcodecs = {};
  if (window.VideoDecoder) {
    for (const [label, codec] of [['h264', 'avc1.640028'], ['hevc', 'hvc1.1.6.L120.B0'], ['av1', 'av01.0.08M.08'], ['vp9', 'vp09.00.40.08'], ['vp8', 'vp8']]) {
      const out = [];
      for (const hw of ['prefer-hardware', 'prefer-software']) {
        try { const s = await VideoDecoder.isConfigSupported({ codec, codedWidth: 1920, codedHeight: 1080, hardwareAcceleration: hw }); out.push(`${hw.split('-')[1]}:${s.supported ? 'yes' : 'no'}`); }
        catch (e) { out.push(`${hw}:error`); }
      }
      try { const e = await VideoEncoder.isConfigSupported({ codec, width: 1280, height: 720, bitrate: 2e6 }); out.push('encode:' + (e.supported ? 'yes' : 'no')); } catch { out.push('encode:error'); }
      webcodecs[label] = out.join(' ');
    }
    for (const [label, codec] of [['aac', 'mp4a.40.2'], ['opus', 'opus'], ['flac', 'flac'], ['mp3', 'mp3']]) {
      try { const s = await AudioDecoder.isConfigSupported({ codec, sampleRate: 48000, numberOfChannels: 2 }); webcodecs['audio ' + label] = s.supported ? 'yes' : 'no'; }
      catch (e) { webcodecs['audio ' + label] = 'error'; }
    }
  }
  // Encrypted media (Netflix, Spotify, Disney+…).
  const eme = {};
  const cfg = robustness => [{ initDataTypes: ['cenc'], videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"', robustness }],
    audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"', robustness: robustness ? 'SW_SECURE_CRYPTO' : '' }] }];
  for (const [label, ks, rob] of [['widevine L3 (SW_SECURE_DECODE)', 'com.widevine.alpha', 'SW_SECURE_DECODE'],
    ['widevine HW_SECURE_ALL', 'com.widevine.alpha', 'HW_SECURE_ALL'], ['clearkey', 'org.w3.clearkey', ''],
    ['playready', 'com.microsoft.playready', ''], ['fairplay', 'com.apple.fps', '']]) {
    try {
      const access = await navigator.requestMediaKeySystemAccess(ks, cfg(rob));
      let extra = '';
      if (ks.includes('widevine')) {
        const keys = await access.createMediaKeys();
        try { extra = ' hdcp1.4:' + await keys.getStatusForPolicy({ minHdcpVersion: '1.4' }); } catch (e) { extra = ' hdcp:' + e.name; }
        // A session that makes a license request: the CDM really loaded.
        try {
          const session = keys.createSession();
          const message = new Promise((ok, no) => { session.onmessage = e => ok(e.messageType); setTimeout(() => no(new Error('no message')), 8000); });
          const pssh = Uint8Array.from(atob('AAAAW3Bzc2gAAAAA7e+LqXnWSs6jyCfc1R0h7QAAADsIARIQ62dqu8s0Xpa7z2FmMPGj2hoNd2lkZXZpbmVfdGVzdCIQZmtqM2xqYVNkZmFsa3IzaioCSEQyAA=='), c => c.charCodeAt(0));
          await session.generateRequest('cenc', pssh);
          extra += ' license-request:' + await message;
        } catch (e) { extra += ' session:' + (e.message || e.name); }
      }
      eme[label] = 'yes' + extra;
    } catch (e) { eme[label] = 'no (' + e.name + ')'; }
  }
  return { canPlay, mseTypes, mediaCapabilities: mc, webcodecs, eme };
};

// Platform features a site may need, each tried for real where it can be
// without a prompt the user would have to answer.
window.features = async () => {
  const r = {};
  const t = async (k, f) => { try { r[k] = await Promise.race([f(), wait(6000).then(() => 'timed out')]); } catch (e) { r[k] = 'error ' + (e.name || '') + ': ' + (e.message || e); } };
  await t('crossOriginIsolated', () => crossOriginIsolated);
  await t('SharedArrayBuffer + Atomics in a worker', async () => {
    const sab = new SharedArrayBuffer(4); const a = new Int32Array(sab);
    const w = new Worker(URL.createObjectURL(new Blob(['onmessage=e=>{const a=new Int32Array(e.data);Atomics.store(a,0,42);Atomics.notify(a,0);}'], { type: 'text/javascript' })));
    w.postMessage(sab); for (let i = 0; i < 20 && Atomics.load(a, 0) !== 42; i++) await wait(50); w.terminate();
    return Atomics.load(a, 0) === 42 ? 'yes' : 'no';
  });
  await t('AudioWorklet', async () => {
    const ctx = new AudioContext(); await ctx.audioWorklet.addModule('/worklet.js');
    const node = new AudioWorkletNode(ctx, 'tone'); node.connect(ctx.destination); await ctx.resume(); await wait(500);
    const frames = await new Promise(ok => { node.port.onmessage = e => ok(e.data); node.port.postMessage(0); });
    await ctx.close(); return frames > 1000 ? `yes (${frames} samples, ${ctx.sampleRate} Hz, state ran)` : 'no ' + frames;
  });
  await t('fullscreen (video element)', async () => {
    const v = document.getElementById('fsv'); await v.requestFullscreen(); await wait(1200);
    const on = document.fullscreenElement === v, size = innerWidth + 'x' + innerHeight;
    await document.exitFullscreen(); await wait(1200);
    return on ? `yes (${size})` : 'no';
  });
  await t('passkeys: platform authenticator (Touch ID)', () => PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable());
  await t('passkeys: conditional UI (autofill)', () => PublicKeyCredential.isConditionalMediationAvailable && PublicKeyCredential.isConditionalMediationAvailable());
  await t('passkeys: client capabilities', async () => PublicKeyCredential.getClientCapabilities ? PublicKeyCredential.getClientCapabilities() : 'n/a');
  await t('notifications permission', async () => (await navigator.permissions.query({ name: 'notifications' })).state + ' / Notification.permission=' + Notification.permission);
  await t('clipboard write + read', async () => { await navigator.clipboard.writeText('cha-clip-' + Date.now()); return 'write ok; read permission ' + (await navigator.permissions.query({ name: 'clipboard-read' })).state; });
  await t('File System Access', () => ['showOpenFilePicker', 'showSaveFilePicker', 'showDirectoryPicker'].filter(f => f in window).join(', ') || 'none');
  await t('Origin Private File System', async () => { const root = await navigator.storage.getDirectory(); const f = await root.getFileHandle('x.txt', { create: true });
    const w = await f.createWritable(); await w.write('hello'); await w.close(); return (await (await f.getFile()).text()) === 'hello' ? 'yes' : 'no'; });
  await t('storage persisted / quota', async () => { const e = await navigator.storage.estimate(); return `quota ${(e.quota / 1e9).toFixed(1)} GB`; });
  await t('device APIs', () => ['hid', 'usb', 'serial', 'bluetooth', 'xr', 'gpu', 'share', 'wakeLock', 'contacts', 'virtualKeyboard', 'ink', 'login', 'credentials']
    .map(k => `${k}:${k in navigator ? 'y' : 'n'}`).join(' '));
  await t('Web Share', () => navigator.canShare ? navigator.canShare({ text: 'x' }) : 'n/a');
  await t('Speech synthesis voices', async () => { let v = speechSynthesis.getVoices(); for (let i = 0; i < 10 && !v.length; i++) { await wait(200); v = speechSynthesis.getVoices(); } return v.length + ' voices'; });
  await t('Speech recognition', () => 'webkitSpeechRecognition' in window || 'SpeechRecognition' in window);
  await t('Payment Request', () => 'PaymentRequest' in window);
  await t('Translator / on-device AI', () => ['Translator', 'LanguageDetector', 'Summarizer', 'LanguageModel'].filter(k => k in window).join(', ') || 'none');
  await t('Gamepad', () => 'getGamepads' in navigator);
  await t('Compression streams', async () => { const s = new Blob(['hello']).stream().pipeThrough(new CompressionStream('gzip')); return (await new Response(s).arrayBuffer()).byteLength > 0; });
  await t('View transitions', () => 'startViewTransition' in document);
  await t('Popover / anchor CSS', () => HTMLElement.prototype.hasOwnProperty('popover') && CSS.supports('anchor-name: --a'));
  await t('IndexedDB', async () => { const db = await new Promise((ok, no) => { const q = indexedDB.open('p', 1); q.onupgradeneeded = () => q.result.createObjectStore('s'); q.onsuccess = () => ok(q.result); q.onerror = no; }); db.close(); return 'yes'; });
  await t('Service worker register (scope)', () => 'serviceWorker' in navigator);
  await t('Screen Wake Lock', async () => { const l = await navigator.wakeLock.request('screen'); await l.release(); return 'yes'; });
  await t('Media Session', () => 'mediaSession' in navigator);
  await t('Picture-in-Picture enabled', () => document.pictureInPictureEnabled + ' / document PiP ' + ('documentPictureInPicture' in window));
  return r;
};
