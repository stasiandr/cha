#import "ChaEngine.h"

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"

// CEF needs an NSApplication that reports when it is dispatching an event.
@interface ChaApplication : NSApplication <CefAppProtocol> {
  BOOL handlingSendEvent_;
}
@end

@implementation ChaApplication
- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}
- (void)terminate:(id)sender {
  CefQuitMessageLoop();
}
@end

namespace {

class AppHandler : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit AppHandler(ChaEngine* engine) : engine_(engine) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) {
      return;
    }
    // The app is not signed yet, so it has no keychain entry of its own and the
    // system prompt for Chromium Safe Storage would block the UI thread.
    // Passwords are then encrypted with a throwaway key. Set CHA_REAL_KEYCHAIN
    // once the app is signed.
    if (!getenv("CHA_REAL_KEYCHAIN")) {
      command_line->AppendSwitch("use-mock-keychain");
    }
  }

  void OnContextInitialized() override { [engine_.delegate engineDidInitialize]; }

 private:
  __weak ChaEngine* engine_;
  IMPLEMENT_REFCOUNTING(AppHandler);
};

}  // namespace

@implementation ChaEngine {
  CefScopedLibraryLoader* _loader;
  CefRefPtr<AppHandler> _app;
}

+ (ChaEngine*)shared {
  static ChaEngine* shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    shared = [ChaEngine new];
  });
  return shared;
}

+ (void)installApplication {
  [ChaApplication sharedApplication];
}

- (BOOL)startWithArgc:(int)argc argv:(char**)argv {
  _loader = new CefScopedLibraryLoader();
  if (!_loader->LoadInMain()) {
    return NO;
  }

  CefMainArgs main_args(argc, argv);
  _app = new AppHandler(self);

  CefSettings settings;
  settings.no_sandbox = true;
  NSString* support = [NSSearchPathForDirectoriesInDomains(
      NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
  NSString* root = [support stringByAppendingPathComponent:@"cha"];
  CefString(&settings.root_cache_path) = root.UTF8String;
  CefString(&settings.cache_path) =
      [root stringByAppendingPathComponent:@"Default"].UTF8String;

  return CefInitialize(main_args, settings, _app.get(), nullptr) ? YES : NO;
}

- (void)run {
  CefRunMessageLoop();
}

- (void)quit {
  CefQuitMessageLoop();
}

- (void)shutdown {
  CefShutdown();
  _app = nullptr;
  delete _loader;
  _loader = nullptr;
}

@end
