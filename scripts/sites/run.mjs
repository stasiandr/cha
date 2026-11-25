// Site checks for cha, driven through its MCP server the way Claude does.
//   node scripts/sites/run.mjs media            # codecs, MSE, HLS, EME on local files
//   node scripts/sites/run.mjs sites            # real sites (needs the network)
// cha runs headless and muted in build/sites/profile (kept between runs, so
// Widevine is fetched once); pictures and results go to build/sites/out.
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdirSync, statSync, openSync } from 'node:fs';
import { join, extname, resolve } from 'node:path';
import { connect, sleep } from './mcp.mjs';

const root = resolve(new URL('../..', import.meta.url).pathname);
const out = join(root, 'build/sites/out');
mkdirSync(out, { recursive: true });
const which = process.argv[2] || 'media';
const only = process.argv[3];

// cha, headless, in its own profile.
const profile = join(root, 'build/sites/profile');
mkdirSync(profile, { recursive: true });
const cha = spawn(join(root, 'build/cha.app/Contents/MacOS/cha'), [], {
  env: { ...process.env, CHA_HEADLESS: process.env.WINDOWED ? '' : '1', CHA_TEST: 'claude', CHA_PROFILE: profile, ...(process.env.CHA_FLOATING ? { CHA_FLOATING: '1' } : {}) },
  stdio: ['ignore', 'ignore', openSync(join(root, 'build/sites/out/cha.log'), 'w')],
});
process.on('exit', () => cha.kill());
for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => process.exit(1));
for (let i = 0; i < 60 && !existsSync(join(profile, 'cha-mcp.json')); i++) await sleep(250);
await sleep(3000);
const mcp = await connect(join(profile, 'cha-mcp'));

// The fixtures, served from 127.0.0.1 (a secure context, as EME wants).
const types = { '.mjs': 'text/javascript', '.mp4': 'video/mp4', '.m4a': 'audio/mp4', '.webm': 'video/webm', '.mkv': 'video/x-matroska', '.mov': 'video/quicktime',
  '.mp3': 'audio/mpeg', '.ogg': 'audio/ogg', '.flac': 'audio/flac', '.wav': 'audio/wav', '.aiff': 'audio/aiff', '.ac3': 'audio/ac3',
  '.m3u8': 'application/vnd.apple.mpegurl', '.ts': 'video/mp2t', '.m4s': 'video/iso.segment', '.html': 'text/html', '.js': 'text/javascript' };
const fixtures = join(root, 'build/sites/fixtures');
const server = createServer((req, res) => {
  const path = decodeURIComponent(req.url.split('?')[0]);
  const file = path === '/probe.js' ? join(root, 'scripts/sites/probe.js')
    : path === '/worklet.js' ? join(root, 'scripts/sites/worklet.js')
    : path === '/' ? null : join(fixtures, path);
  if (path === '/' || path === '/isolated') {
    // /isolated: cross-origin isolated (COOP + COEP), as SharedArrayBuffer and WASM threads want.
    const headers = { 'content-type': 'text/html', ...(path === '/isolated' ? { 'cross-origin-opener-policy': 'same-origin', 'cross-origin-embedder-policy': 'require-corp' } : {}) };
    res.writeHead(200, headers);
    return res.end('<!doctype html><title>probe</title><script src="/probe.js"></script><body><p>probe</p><video id=fsv muted src="/h264-aac.mp4"></video>');
  }
  if (!file || !existsSync(file) || statSync(file).isDirectory()) { res.writeHead(404); return res.end(); }
  const data = readFileSync(file);
  // Range requests, as media elements make them.
  const range = req.headers.range?.match(/bytes=(\d+)-(\d*)/);
  const headers = { 'content-type': types[extname(file)] || 'application/octet-stream', 'accept-ranges': 'bytes' };
  if (range) {
    const start = +range[1], end = range[2] ? +range[2] : data.length - 1;
    res.writeHead(206, { ...headers, 'content-range': `bytes ${start}-${end}/${data.length}`, 'content-length': end - start + 1 });
    return res.end(data.subarray(start, end + 1));
  }
  res.writeHead(200, { ...headers, 'content-length': data.length });
  res.end(data);
});
await new Promise(r => server.listen(0, '127.0.0.1', r));
const base = `http://127.0.0.1:${server.address().port}`;

const results = {};
const line = (k, v) => console.log(`${k.padEnd(28)} ${v}`);

if (which === 'eme') {
  await mcp.open(base + '/', 1500);
  const caps = await mcp.js('capabilities()');
  for (const [k, v] of Object.entries(caps.eme ?? caps)) line(k, v);
  results.eme = caps.eme;
}

if (which === 'fullscreen') {
  // The page asks for full screen (YouTube's button): does the video get the whole screen?
  await mcp.open(base + '/', 1500);
  await mcp.call('select_tab', { tab_id: mcp.tab.id });
  await sleep(1000);
  const before = await mcp.js('({ w: innerWidth, h: innerHeight, screen: screen.width + "x" + screen.height })');
  const during = await mcp.js(`(async () => { const v = document.getElementById('fsv'); await v.requestFullscreen(); await wait(2500);
    return { element: !!document.fullscreenElement, w: innerWidth, h: innerHeight, screen: screen.width + 'x' + screen.height }; })()`);
  await mcp.shot(join(out, 'fullscreen-during.jpg'));
  // Esc, as a person leaves it.
  await mcp.call('press_key', { keys: 'Escape', tab_id: mcp.tab.id });
  await sleep(2500);
  const after = await mcp.js('({ element: !!document.fullscreenElement, w: innerWidth, h: innerHeight })');
  results.fullscreen = { before, during, after };
  for (const [k, v] of Object.entries(results.fullscreen)) line(k, JSON.stringify(v));
}

if (which === 'features') {
  await mcp.open(base + '/isolated', 1500);
  const r = await mcp.js('features()');
  results.features = r;
  for (const [k, v] of Object.entries(r)) line(k, typeof v === 'string' ? v : JSON.stringify(v));
}

if (which === 'media') {
  await mcp.open(base + '/', 1500);
  console.log('\n== real playback (muted)');
  const files = ['h264-aac.mp4', 'h264-high10.mp4', 'h264-444.mp4', 'h264.mov', 'h264.mkv', 'h264-ac3.mp4', 'hevc-hvc1.mp4',
    'hevc-hev1.mp4', 'hevc-main10-hdr.mp4', 'av1.mp4', 'av1.webm', 'av1-10bit.mp4', 'vp9.webm', 'vp9-10bit.webm', 'vp9.mp4', 'vp8.webm',
    'prores.mov', 'aac-lc.m4a', 'he-aac.m4a', 'mp3.mp3', 'opus.webm', 'opus.ogg', 'opus.mp4', 'vorbis.ogg', 'flac.flac', 'flac.mp4',
    'alac.m4a', 'ac3.ac3', 'eac3.mp4', 'pcm16.wav', 'pcm-float.wav', 'pcm.aiff'];
  results.playback = {};
  for (const f of files) {
    const r = await mcp.js(`playFile(${JSON.stringify('/' + f)})`);
    results.playback[f] = r;
    line(f, r.__error ? 'ERROR ' + r.__error : `${r.plays ? 'plays' : 'NO'}  t=${r.time}${r.w ? ` ${r.w}px frames=${r.frames}` : ''}${r.err ? ' err=' + r.err : ''}${r.playErr ? ' ' + r.playErr : ''}`);
  }
  console.log('\n== Media Source Extensions');
  results.mse = {};
  for (const [f, t] of [['mse-h264.mp4', 'video/mp4; codecs="avc1.640016"'], ['mse-hevc.mp4', 'video/mp4; codecs="hvc1.1.6.L63.90"'],
    ['mse-av1.mp4', 'video/mp4; codecs="av01.0.00M.08"'], ['mse-vp9.mp4', 'video/mp4; codecs="vp09.00.20.08"'],
    ['mse-aac.mp4', 'audio/mp4; codecs="mp4a.40.2"'], ['mse-opus.mp4', 'audio/mp4; codecs="opus"'], ['mse-ac3.mp4', 'audio/mp4; codecs="ac-3"']]) {
    const r = await mcp.js(`mse(${JSON.stringify('/' + f)}, ${JSON.stringify(t)})`);
    results.mse[f] = r;
    line(f, r.__error ? 'ERROR ' + r.__error : `${r.supported ? 'type ok' : 'type NO'}${'plays' in r ? (r.plays ? ` plays t=${r.time}` : ` NO ${r.err || ''}`) : ''}`);
  }
  console.log('\n== HLS without a player library (native)');
  results.hls = {};
  for (const f of ['hls-ts/index.m3u8', 'hls-hevc/index.m3u8']) {
    const r = await mcp.js(`playFile(${JSON.stringify('/' + f)}, 'video')`);
    results.hls[f] = r;
    line(f, r.__error ? 'ERROR ' + r.__error : `${r.plays ? 'plays' : 'NO'} t=${r.time} ${r.err || ''}`);
  }
  console.log('\n== what the browser says it supports');
  const caps = await mcp.js('capabilities()');
  results.capabilities = caps;
  if (caps.__error) console.log(caps.__error);
  else for (const [group, map] of Object.entries(caps)) {
    console.log(`-- ${group}`);
    for (const [k, v] of Object.entries(map)) line('  ' + k.replace(/^(video|audio|application)\//, ''), v);
  }
}

if (which === 'sites') {
  const { sites } = await import('./sites.mjs');
  for (const site of sites) {
    if (only && !site.name.includes(only)) continue;
    const t0 = Date.now();
    let r;
    try {
      await mcp.open(site.url, site.wait ?? 6000);
      r = await site.check(mcp);
    } catch (e) { r = { ok: false, note: 'exception ' + e.message }; }
    await mcp.shot(join(out, site.name + '.jpg'));
    results[site.name] = r;
    line(site.name, `${r.ok ? 'ok  ' : 'FAIL'} ${JSON.stringify(r.detail ?? r.note ?? '').slice(0, 300)} (${Math.round((Date.now() - t0) / 1000)} s)`);
    await mcp.closeTab();
  }
}

writeFileSync(join(out, which + '.json'), JSON.stringify(results, null, 1));
mcp.close();
server.close();
cha.kill();
process.exit(0);
