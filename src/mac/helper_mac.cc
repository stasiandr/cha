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
  const ms = navigator.mediaSession;
  if (!ms || ms.__cha) return;
  Object.defineProperty(ms, '__cha', { value: true });
  const set = ms.setActionHandler.bind(ms);
  ms.setActionHandler = (action, handler) => {
    if (action === 'enterpictureinpicture') window.__chaEnterPiP = handler;
    return set(action, handler);
  };
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
