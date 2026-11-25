# Sites in cha: what works, what doesn't

Checked 2026-11-25 on cha's own CEF 152 (proprietary codecs), an M5 Pro, by
`scripts/sites/run.mjs` through cha's MCP server (the tools Claude uses):
headless and muted, a throwaway profile, no accounts. PiP windows were opened
for real while the Mac was idle. Pictures and raw results: `build/sites/out`.

## Codecs and containers (`run.mjs media`, local files)

Each file is played for real (time and decoded frames move), not only asked
about with `canPlayType`.

| Plays | Doesn't |
|---|---|
| H.264 (8-bit, High 10, 4:4:4) in MP4, MOV, MKV | ProRes (MOV) |
| HEVC hvc1 and hev1, Main 10 HDR (PQ/BT.2020) | ALAC (M4A) |
| AV1 8- and 10-bit in MP4 and WebM | AC-3, E-AC-3 (MP4 or raw; the video of an H.264+AC-3 file plays silent) |
| VP9 (and profile 2 10-bit), VP8 | AIFF |
| AAC-LC, HE-AAC, MP3, Opus (WebM/Ogg/MP4), Vorbis, FLAC (raw/MP4), WAV PCM 16/float | Dolby Vision (`dvh1`), Theora |

The right-hand column is what Google Chrome on the Mac doesn't play either.

- **MSE** (YouTube, Netflix, Twitch…): H.264, HEVC, AV1, VP9, AAC, Opus append
  and play; AC-3 isn't accepted (as in Chrome).
- **HLS without a library**: Chromium's own player plays MPEG-TS/H.264 and
  fMP4/HEVC playlists, starting 4-6 s after load.
- **Hardware decoding** (MediaCapabilities `powerEfficient`): H.264 1080p,
  HEVC 4K and Main 10 HDR, AV1 4K, VP9 4K. WebCodecs: H.264, HEVC, AV1, VP9
  in hardware; VP8 in software; all encode.
- **DRM**: Widevine L3 (`SW_SECURE_DECODE`) with HDCP 1.4 reported usable;
  ClearKey. No hardware Widevine (`HW_SECURE_ALL`), PlayReady or FairPlay —
  the same as Chrome on the Mac. Widevine's CDM comes by Chromium's component
  updater into the profile (`WidevineCdm/`), a few minutes after a first launch.

## Real sites (`run.mjs sites`)

| Site | Result |
|---|---|
| YouTube (Big Buck Bunny) | plays: AV1 + Opus, 1080p after ramp-up, consent wall declined |
| YouTube 4K60 HDR | plays: AV1 10-bit BT.2020 PQ offered, levels to 2160p |
| Vimeo player | 720p, no dropped frames |
| Twitch live | 1080p live |
| Widevine: Bitmovin demo, dash.js DRMtoday sample | encrypted video plays, licence granted |
| hls.js, dash.js reference players | play |
| Apple's HEVC HLS example opened as a page | plays (Chromium's HLS, slow start) |
| Picture in picture | a video's PiP window and a Document PiP window both open |
| WebGL (Aquarium) | 119 fps on ANGLE/Metal |
| WebGPU | Metal 3 adapter, shader-f16 |
| Google Maps | the full vector map, not Lite |
| Squoosh | service worker active, WASM SIMD |
| Telegram Web K | QR sign-in, service worker, IndexedDB |
| Discord | sign-in page with QR (slow on a cold cache) |
| Cloudflare's bot check (nowsecure.nl) | passes on its own |
| WebRTC data channel | two peers talk |
| Excalidraw | a rectangle drawn by a mouse drag |
| Arabic Wikipedia | right to left, fonts and emoji |

## Platform features (`run.mjs features`)

Work: cross-origin isolation with SharedArrayBuffer and Atomics in a worker,
AudioWorklet, Origin Private File System, File System Access pickers,
IndexedDB, service workers, Screen Wake Lock, Media Session, Web Share,
Payment Request, speech synthesis (180 voices) and recognition, gamepads,
WebHID/USB/Serial/Bluetooth present, compression streams, view transitions,
popover and anchor positioning, Chromium's on-device AI APIs (Translator,
Summarizer, LanguageModel…), passkeys from a phone (hybrid) and conditional
passkey autofill.

## What doesn't, and what was fixed

- **Fixed: a page's full screen** (YouTube's ⛶ or F, any video's own button)
  only filled the page area, the sidebar still there: Chromium tries to take
  the tab's own window to full screen, and it is a child of cha's. cha now
  takes its window to full screen and hides the sidebar, and Esc or the
  button puts both back (`PageFullscreen.swift`). Checked headless (the
  sidebar goes and comes back); the window's full screen itself wasn't checked
  on a real screen — the screen was locked during the run.
- **Passkeys with Touch ID don't work**: no platform authenticator
  (`isUserVerifyingPlatformAuthenticatorAvailable` is false). Chrome's own
  Touch ID passkeys need a keychain access group the app is signed for, and
  iCloud Keychain passkeys need Apple's browser entitlement. Passkeys from a
  phone and security keys work.
- **The browser calls itself Chromium**: `navigator.userAgentData` brands are
  Chromium only, no "Google Chrome". Sites that check the brand (rather than
  the version) treat cha as a Chromium build.
- **Clipboard in a background tab**: `navigator.clipboard` refuses a tab that
  isn't focused, as in Chrome; Claude working in a background tab can't use it.
- Not tested: camera and microphone (no devices were turned on), sign-ins
  (Google's "this browser may not be secure" check needs an account), Netflix
  and Spotify playback (accounts; Netflix also wants Widevine's VMP signature,
  which a CEF build doesn't have, so expect at most 720p there).

## Fixes to the Claude tools found on the way

- `javascript` returned `{}` for a promise the code returned (REPL mode only
  awaits a top-level `await`): promises are awaited now, up to 60 s.
- No way to drag or hover: `drag` (drawing, sliders, drag and drop) and
  `hover` (menus, tooltips) were added.
