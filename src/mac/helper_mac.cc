// Copyright (c) 2013 The Chromium Embedded Framework Authors. All rights
// reserved. Use of this source code is governed by a BSD-style license that can
// be found in the LICENSE file.

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"

// When generating projects with CMake the CEF_USE_SANDBOX value will be defined
// automatically. Pass -DUSE_SANDBOX=OFF to the CMake command-line to disable
// use of the sandbox.
#if defined(CEF_USE_SANDBOX)
#include "include/cef_sandbox_mac.h"
#endif

// Pages' processes: before a document's own scripts run, keep the handler a
// site registers for Chrome's automatic picture in picture (Meet and other
// calls). cha calls it when the user leaves the tab; Chromium only would on a
// tab-strip switch, which cha's tabs don't have.
class HelperApp : public CefApp, public CefRenderProcessHandler {
 public:
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }
  void OnContextCreated(CefRefPtr<CefBrowser>,
                        CefRefPtr<CefFrame>,
                        CefRefPtr<CefV8Context> context) override {
    CefRefPtr<CefV8Value> result;
    CefRefPtr<CefV8Exception> exception;
    context->Eval(R"JS(
(() => {
  // What plays sound in this frame, for the sidebar's speaker and the mini
  // player: one console line to cha whenever it changes. Elements played
  // from script (new Audio()) are followed as well as the page's own.
  if (window.__chaMedia) return;
  const token = Math.random().toString(36).slice(2);
  const els = new Set();
  const handlers = {};
  let last = '';
  const sounding = m => !m.paused && !m.ended && !m.muted && m.volume > 0;
  const report = () => {
    const all = [...els, ...document.querySelectorAll('video, audio')];
    const playing = all.some(sounding);
    const meta = navigator.mediaSession && navigator.mediaSession.metadata;
    const line = JSON.stringify({ t: token, p: playing ? 1 : 0, paused: !playing && all.some(m => m.paused && m.currentTime > 0 && !m.ended) ? 1 : 0,
      title: (meta && meta.title) || '', artist: (meta && meta.artist) || '' });
    if (line !== last) { last = line; console.log('__cha_media__ ' + line); }
  };
  let pending = false;
  const schedule = () => { if (!pending) { pending = true; setTimeout(() => { pending = false; report(); }, 50); } };
  const follow = m => {
    if (els.has(m)) return;
    els.add(m);
    ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied'].forEach(e => m.addEventListener(e, schedule));
  };
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () { follow(this); schedule(); return play.apply(this, arguments); };
  ['playing', 'pause'].forEach(e => document.addEventListener(e, ev => { if (ev.target instanceof HTMLMediaElement) follow(ev.target); schedule(); }, true));
  const ms = navigator.mediaSession;
  if (ms) {
    const set = ms.setActionHandler.bind(ms);
    ms.setActionHandler = (action, handler) => { handlers[action] = handler; return set(action, handler); };
  }
  // The mini player's buttons.
  window.__chaMedia = (command) => {
    const all = [...els, ...document.querySelectorAll('video, audio')];
    if (command === 'toggle') {
      const playing = all.filter(sounding);
      if (playing.length) {
        if (handlers.pause) handlers.pause({ action: 'pause' }); else playing.forEach(m => m.pause());
      } else if (handlers.play) {
        handlers.play({ action: 'play' });
      } else {
        const paused = all.find(m => m.paused && m.currentTime > 0 && !m.ended);
        if (paused) paused.play();
      }
    } else if (handlers[command]) {
      handlers[command]({ action: command });
    } else if (command === 'nexttrack' || command === 'previoustrack') {
      const m = all.find(sounding) || all[0];
      if (m) m.currentTime = command === 'nexttrack' ? m.currentTime + 10 : Math.max(0, m.currentTime - 10);
    }
    schedule();
  };
})();
(() => {
  const ms = navigator.mediaSession;
  if (!ms || ms.__cha) return;
  Object.defineProperty(ms, '__cha', { value: true });
  const set = ms.setActionHandler.bind(ms);
  ms.setActionHandler = (action, handler) => {
    if (action === 'enterpictureinpicture') window.__chaEnterPiP = handler;
    return set(action, handler);
  };
  // A call: the page holds a live camera or microphone track. (Chromium's
  // own signal for it doesn't reach cha's tabs.)
  const md = navigator.mediaDevices;
  if (md && md.getUserMedia && !md.__cha) {
    Object.defineProperty(md, '__cha', { value: true });
    const streams = [];
    const get = md.getUserMedia.bind(md);
    md.getUserMedia = (c) => get(c).then(s => { streams.push(s); return s; });
    window.__chaCall = () => streams.some(s => s.getTracks().some(t => t.readyState === 'live'));
  }
  // What became of a floating-window request, for cha's tabs.log.
  const dpip = window.documentPictureInPicture;
  if (dpip && !dpip.__cha) {
    Object.defineProperty(dpip, '__cha', { value: true });
    const request = dpip.requestWindow.bind(dpip);
    dpip.requestWindow = (options) => {
      const active = navigator.userActivation && navigator.userActivation.isActive;
      return request(options).then(
        w => { console.log('__cha_probe__ floating window given to ' + location.host); return w; },
        e => { console.log('__cha_probe__ floating window refused to ' + location.host + ' (activation ' + active + '): ' + e.name + ' ' + e.message); throw e; });
    };
  }
})();
)JS",
                  CefString(), 0, result, exception);
  }

 private:
  IMPLEMENT_REFCOUNTING(HelperApp);
};

// Entry point function for sub-processes.
int main(int argc, char* argv[]) {
#if defined(CEF_USE_SANDBOX)
  // Initialize the macOS sandbox for this helper process.
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }
#endif

  // Load the CEF framework library at runtime instead of linking directly
  // as required by the macOS sandbox implementation.
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }

  // Provide CEF with command-line arguments.
  CefMainArgs main_args(argc, argv);

  // Execute the sub-process.
  CefRefPtr<CefApp> app = new HelperApp();
  return CefExecuteProcess(main_args, app, nullptr);
}
