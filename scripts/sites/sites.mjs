// Real sites, each with a check that says whether it really works in cha
// (not only loads): video advances, DRM licenses, WebGL draws, workers run.
// No sign-ins and nothing submitted: what a visitor without an account sees.
import { sleep } from './mcp.mjs';

// Waits for a <video> (in the page or its same-origin frames), plays it
// muted and says whether time and frames moved.
const videoProbe = (selector = 'video', seconds = 8) => `
  (async () => {
    const find = () => { const all = [...document.querySelectorAll(${JSON.stringify(selector)})];
      for (const f of document.querySelectorAll('iframe')) { try { all.push(...f.contentDocument.querySelectorAll('video')); } catch {} }
      return all.sort((a, b) => (b.videoWidth * b.videoHeight || b.clientWidth) - (a.videoWidth * a.videoHeight || a.clientWidth))[0]; };
    let v; for (let i = 0; i < 40 && !(v = find()); i++) await new Promise(r => setTimeout(r, 250));
    if (!v) return { ok: false, note: 'no video element' };
    v.muted = true; try { await Promise.race([v.play(), new Promise(r => setTimeout(r, 4000))]); } catch (e) {}
    const t0 = v.currentTime, start = Date.now();
    while (Date.now() - start < ${seconds * 1000} && v.currentTime - t0 < 2) await new Promise(r => setTimeout(r, 250));
    const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {};
    return { ok: v.currentTime - t0 > 1, advanced: +(v.currentTime - t0).toFixed(1), size: v.videoWidth + 'x' + v.videoHeight,
      frames: q.totalVideoFrames, dropped: q.droppedVideoFrames, src: (v.currentSrc || '').slice(0, 40), error: v.error && v.error.message,
      paused: v.paused, readyState: v.readyState };
  })()`;

// Consent walls (YouTube, Google) are declined, as cha's privacy rules say.
async function declineConsent(mcp) {
  const r = await mcp.call('find', { query: 'Reject all', tab_id: mcp.tab.id });
  const ref = r.text.match(/\[(ref_\d+)\]/)?.[1];
  if (ref) { await mcp.call('click', { ref, tab_id: mcp.tab.id }); await sleep(3000); return true; }
  return false;
}

export const sites = [
  {
    name: 'youtube',
    url: 'https://www.youtube.com/watch?v=aqz-KE-bpKQ',  // Big Buck Bunny, up to 4K60
    wait: 7000,
    async check(mcp) {
      const consent = await declineConsent(mcp);
      const r = await mcp.js(videoProbe('video.html5-main-video', 12));
      const stats = await mcp.js(`(() => { const p = document.getElementById('movie_player');
        const s = p && p.getStatsForNerds ? p.getStatsForNerds() : null;
        return s ? { codecs: s.codecs, resolution: s.resolution, dims: s.dims_and_frames, health: s.buffer_health_seconds } : null; })()`);
      const ad = await mcp.js(`!!document.querySelector('.ad-showing')`);
      return { ok: r.ok, detail: { ...r, stats, consent, ad } };
    },
  },
  {
    name: 'youtube-4k',
    url: 'https://www.youtube.com/watch?v=LXb3EKWsInQ',  // Costa Rica 4K60 HDR
    wait: 7000,
    async check(mcp) {
      await declineConsent(mcp);
      // Ask the player for its top quality; then see what it decodes.
      await mcp.js(`(() => { const p = document.getElementById('movie_player'); if (!p) return;
        const q = p.getAvailableQualityLevels(); p.setPlaybackQualityRange && p.setPlaybackQualityRange(q[0], q[0]); return q; })()`);
      const r = await mcp.js(videoProbe('video.html5-main-video', 15));
      await sleep(4000);
      const stats = await mcp.js(`(() => { const p = document.getElementById('movie_player'); const s = p && p.getStatsForNerds && p.getStatsForNerds();
        return s ? { codecs: s.codecs, color: s.color, dims: s.dims_and_frames, levels: p.getAvailableQualityLevels().slice(0, 4) } : null; })()`);
      return { ok: r.ok, detail: { ...r, stats } };
    },
  },
  {
    name: 'vimeo',
    url: 'https://player.vimeo.com/video/76979871?muted=1&autoplay=1',
    wait: 6000,
    async check(mcp) { const r = await mcp.js(videoProbe()); return { ok: r.ok, detail: r }; },
  },
  {
    name: 'twitch-live',
    url: 'https://www.twitch.tv/directory/all',
    wait: 6000,
    async check(mcp) {
      // The first live channel on the page.
      const href = await mcp.js(`(async () => { for (let i = 0; i < 20; i++) { const a = [...document.querySelectorAll('a[data-a-target="preview-card-image-link"]')][0];
        if (a) return a.href; await new Promise(r => setTimeout(r, 500)); } return null; })()`);
      if (!href || href.__error) return { ok: false, note: 'no live channel found ' + JSON.stringify(href) };
      await mcp.call('navigate', { url: href, tab_id: mcp.tab.id });
      await sleep(6000);
      const r = await mcp.js(videoProbe('video', 12));
      return { ok: r.ok, detail: { channel: href, ...r } };
    },
  },
  {
    name: 'dashjs-widevine',
    // dash.js's own Widevine sample: DASH, licensed by DRMtoday's test server.
    url: 'https://reference.dashif.org/dash.js/latest/samples/drm/widevine.html',
    wait: 8000,
    async check(mcp) {
      await mcp.js(`(() => { const b = [...document.querySelectorAll('button')].find(b => /load|play/i.test(b.textContent)); if (b) b.click(); })()`);
      const r = await mcp.js(videoProbe('video', 15));
      const drm = await mcp.js(`(() => { const v = document.querySelector('video'); return v && v.mediaKeys ? 'mediaKeys set' : 'no mediaKeys'; })()`);
      return { ok: r.ok && drm === 'mediaKeys set', detail: { ...r, drm } };
    },
  },
  {
    name: 'bitmovin-widevine',
    url: 'https://bitmovin.com/demos/drm',
    wait: 9000,
    async check(mcp) {
      const r = await mcp.js(videoProbe('video', 15));
      const drm = await mcp.js(`(() => { const v = document.querySelector('video'); return v && v.mediaKeys ? (v.mediaKeys.keySystem || 'mediaKeys set') : 'no mediaKeys'; })()`);
      return { ok: r.ok, detail: { ...r, drm } };
    },
  },
  {
    name: 'hls-js',
    url: 'https://hlsjs.video-dev.org/demo/?src=https%3A%2F%2Ftest-streams.mux.dev%2Fx36xhzz%2Fx36xhzz.m3u8',
    wait: 7000,
    async check(mcp) { const r = await mcp.js(videoProbe('video', 10)); return { ok: r.ok, detail: r }; },
  },
  {
    name: 'apple-hls-hevc-native',
    url: 'https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8',
    wait: 5000,
    async check(mcp) {
      // A playlist opened as a page: Chromium's own HLS player. It fetches
      // the playlists and a few segments first: 4-6 s before it starts.
      const r = await mcp.js(videoProbe('video', 20));
      return { ok: r.ok, detail: r };
    },
  },
  {
    name: 'dash-if',
    url: 'https://reference.dashif.org/dash.js/latest/samples/dash-if-reference-player/index.html?mpd=https%3A%2F%2Fdash.akamaized.net%2Fakamai%2Fbbb_30fps%2Fbbb_30fps.mpd&autoLoad=true&muted=true',
    wait: 8000,
    async check(mcp) { const r = await mcp.js(videoProbe('video', 10)); return { ok: r.ok, detail: r }; },
  },
  {
    name: 'pip-api',
    url: 'https://www.youtube.com/watch?v=aqz-KE-bpKQ',
    wait: 7000,
    async check(mcp) {
      await declineConsent(mcp);
      await mcp.js(videoProbe('video.html5-main-video', 6));
      const api = await mcp.js(`({ video: document.pictureInPictureEnabled, documentPiP: 'documentPictureInPicture' in window,
        disabled: document.querySelector('video') && document.querySelector('video').disablePictureInPicture })`);
      // Opening one makes a floating window: only when the Mac is idle (CHA_FLOATING set by the caller).
      if (!process.env.CHA_FLOATING) return { ok: api.video && api.documentPiP, detail: { ...api, opened: 'not tried (Mac in use)' } };
      const opened = await mcp.js(`(async () => { const v = document.querySelector('video');
        try { const w = await v.requestPictureInPicture(); const r = { video: w.width + 'x' + w.height, element: !!document.pictureInPictureElement };
          await new Promise(r => setTimeout(r, 1500)); await document.exitPictureInPicture(); return r; } catch (e) { return { videoError: e.name + ': ' + e.message }; } })()`);
      const doc = await mcp.js(`(async () => { try { const w = await documentPictureInPicture.requestWindow({ width: 320, height: 180 });
          w.document.body.textContent = 'doc pip'; const r = { doc: w.innerWidth + 'x' + w.innerHeight }; await new Promise(r => setTimeout(r, 1500)); w.close(); return r; }
        catch (e) { return { docError: e.name + ': ' + e.message }; } })()`);
      return { ok: !opened.videoError && !doc.docError, detail: { ...api, ...opened, ...doc } };
    },
  },
  {
    name: 'webgl-aquarium',
    url: 'https://webglsamples.org/aquarium/aquarium.html',
    wait: 8000,
    async check(mcp) {
      const r = await mcp.js(`(() => { const c = document.querySelector('canvas'); const gl = c && (c.getContext('webgl2') || c.getContext('webgl'));
        const fps = (document.getElementById('fps') || {}).textContent;
        const dbg = gl && gl.getExtension('WEBGL_debug_renderer_info');
        return { fps, renderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : null, version: gl && gl.getParameter(gl.VERSION) }; })()`);
      return { ok: !!r.renderer && parseFloat(r.fps) > 5, detail: r };
    },
  },
  {
    name: 'webgpu',
    url: 'https://webgpu.github.io/webgpu-samples/?sample=rotatingCube',
    wait: 7000,
    async check(mcp) {
      const r = await mcp.js(`(async () => { if (!navigator.gpu) return { gpu: false }; const a = await navigator.gpu.requestAdapter();
        if (!a) return { gpu: true, adapter: null }; const info = a.info || {};
        return { gpu: true, vendor: info.vendor, arch: info.architecture, features: [...a.features].length, f16: a.features.has('shader-f16') }; })()`);
      return { ok: !!(r.gpu && r.vendor !== undefined), detail: r };
    },
  },
  {
    name: 'google-maps',
    url: 'https://www.google.com/maps/@59.3293,18.0686,15z',
    wait: 9000,
    async check(mcp) {
      await declineConsent(mcp);
      await sleep(3000);
      const r = await mcp.js(`({ canvases: document.querySelectorAll('canvas').length, title: document.title,
        lite: /lite mode|light mode/i.test(document.body.innerText) })`);
      return { ok: r.canvases > 0 && !r.lite, detail: r };
    },
  },
  {
    name: 'squoosh-wasm-sw',
    url: 'https://squoosh.app/',
    wait: 6000,
    async check(mcp) {
      const r = await mcp.js(`(async () => { const reg = await navigator.serviceWorker.getRegistration();
        return { sw: !!reg, active: !!(reg && reg.active), wasm: typeof WebAssembly.instantiateStreaming, simd: WebAssembly.validate(new Uint8Array([0,97,115,109,1,0,0,0,1,5,1,96,0,1,123,3,2,1,0,10,10,1,8,0,65,0,253,15,253,98,11])) }; })()`);
      return { ok: r.sw && r.simd, detail: r };
    },
  },
  {
    name: 'telegram-web',
    url: 'https://web.telegram.org/k/',
    wait: 9000,
    async check(mcp) {
      const r = await mcp.js(`({ qr: !!document.querySelector('canvas, .qr-container svg, .auth-image'), text: document.body.innerText.slice(0, 120),
        sw: !!navigator.serviceWorker.controller, idb: !!indexedDB })`);
      return { ok: r.qr && !/not supported|update your browser/i.test(r.text), detail: r };
    },
  },
  {
    name: 'discord-web',
    url: 'https://discord.com/login',
    wait: 15000,  // a cold cache takes it a while
    async check(mcp) {
      const r = await mcp.js(`({ form: !!document.querySelector('input[name="email"]'), qr: !!document.querySelector('[class*="qrCode"]'),
        text: document.body.innerText.slice(0, 120) })`);
      return { ok: r.form && !/unsupported browser/i.test(r.text), detail: r };
    },
  },
  {
    name: 'cloudflare-challenge',
    url: 'https://nowsecure.nl/',
    wait: 12000,
    async check(mcp) {
      const r = await mcp.js(`({ title: document.title, text: document.body.innerText.slice(0, 160) })`);
      return { ok: !/just a moment|verify you are human|checking your browser/i.test(r.title + r.text), detail: r };
    },
  },
  {
    name: 'webrtc-datachannel',
    url: 'https://webrtc.github.io/samples/src/content/datachannel/basic/',
    wait: 4000,
    async check(mcp) {
      // Two peers in the page, no camera or microphone.
      const r = await mcp.js(`(async () => { document.getElementById('startButton').click(); await new Promise(r => setTimeout(r, 2500));
        const send = document.getElementById('sendButton'); const box = document.getElementById('dataChannelSend');
        if (send.disabled) return { connected: false };
        box.value = 'hello from cha'; send.click(); await new Promise(r => setTimeout(r, 1500));
        return { connected: true, received: document.getElementById('dataChannelReceive').value }; })()`);
      return { ok: r.received === 'hello from cha', detail: r };
    },
  },
  {
    name: 'excalidraw-drag',
    url: 'https://excalidraw.com/',
    wait: 7000,
    async check(mcp) {
      // The rectangle tool (R), then a drag on the canvas: one element drawn.
      await mcp.call('press_key', { keys: 'Escape r', tab_id: mcp.tab.id });
      const d = await mcp.call('drag', { x: 400, y: 300, to_x: 600, to_y: 450, tab_id: mcp.tab.id });
      await sleep(800);
      const r = await mcp.js(`(() => { try { const s = JSON.parse(localStorage.getItem('excalidraw') || '[]');
        return { elements: s.filter(e => !e.isDeleted).map(e => e.type + ' ' + Math.round(e.width) + 'x' + Math.round(e.height)) }; } catch (e) { return { err: String(e) }; } })()`);
      return { ok: (r.elements || []).some(e => e.startsWith('rectangle')), detail: { drag: d.text, ...r } };
    },
  },
  {
    name: 'complex-scripts',
    url: 'https://ar.wikipedia.org/wiki/%D8%A7%D9%84%D9%84%D8%BA%D8%A9_%D8%A7%D9%84%D8%B9%D8%B1%D8%A8%D9%8A%D8%A9',
    wait: 4000,
    async check(mcp) {
      const r = await mcp.js(`({ dir: document.dir, fonts: document.fonts.status, emoji: (() => { const c = document.createElement('canvas').getContext('2d');
        c.font = '32px sans-serif'; return c.measureText('🧑🏽‍🚀').width > 20; })() })`);
      return { ok: r.dir === 'rtl' && r.emoji, detail: r };
    },
  },
];
