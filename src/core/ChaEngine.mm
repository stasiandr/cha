#import "ChaEngine.h"

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"

#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

// Milliseconds since the kernel started this process, for the TIMING marks.
static double ChaMillisSinceStart() {
  struct kinfo_proc info;
  size_t size = sizeof(info);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
  struct timeval now;
  gettimeofday(&now, nullptr);
  if (sysctl(mib, 4, &info, &size, nullptr, 0) != 0) {
    return 0;
  }
  struct timeval start = info.kp_proc.p_starttime;
  return (now.tv_sec - start.tv_sec) * 1000.0 +
         (now.tv_usec - start.tv_usec) / 1000.0;
}

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
  // ⌘Q goes to our quit before any window sees it: with a page in front,
  // Chromium's own window took it and started a shutdown of its own that
  // left the message loop running forever.
  if (event.type == NSEventTypeKeyDown &&
      (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand &&
      [event.charactersIgnoringModifiers isEqualToString:@"q"]) {
    [self terminate:self];
    return;
  }
  // The same for every ⌘ shortcut: cha's menu first, the page after. A page's
  // window is Chromium's and answers its own shortcuts before the menu does
  // (⌘T opened a Chromium window). The Edit items send copy:/paste:… to the
  // first responder, so in a page they still reach the page.
  if (event.type == NSEventTypeKeyDown &&
      (event.modifierFlags & NSEventModifierFlagCommand) &&
      [self.mainMenu performKeyEquivalent:event]) {
    return;
  }
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}
// Checks run while someone works at this Mac (headless, or on another
// display with CHA_SCREEN): Chromium activates the app whenever it shows a
// tab's window, which would pull focus away from what they are doing.
static BOOL ChaQuiet() {
  static BOOL quiet;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    const char* headless = getenv("CHA_HEADLESS");
    const char* screen = getenv("CHA_SCREEN");
    quiet = (headless && *headless) || (screen && *screen);
  });
  return quiet;
}
- (void)activateIgnoringOtherApps:(BOOL)flag {
  if (!ChaQuiet()) {
    [super activateIgnoringOtherApps:flag];
  }
}
- (void)activate {
  if (!ChaQuiet()) {
    [super activate];
  }
}
- (void)terminate:(id)sender {
  fprintf(stderr, "TIMING quit-requested %.0f\n", ChaMillisSinceStart());
  // Whatever happens below, the app is gone in 3 s: quitting must never
  // leave a process nobody can close.
  static dispatch_once_t watchdog;
  dispatch_once(&watchdog, ^{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      fprintf(stderr, "TIMING quit-forced %.0f\n", ChaMillisSinceStart());
      _exit(0);
    });
  });
  // The browsers have to close before the loop may end; the delegate does
  // that and calls -quit once they have.
  id<ChaEngineDelegate> delegate = ChaEngine.shared.delegate;
  if ([delegate respondsToSelector:@selector(engineWillQuit)]) {
    [delegate engineWillQuit];
  } else {
    CefQuitMessageLoop();
  }
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
    // Test runs happen while someone works at this Mac: no sound, and pages
    // keep painting although their windows sit off screen.
    const char* headless = getenv("CHA_HEADLESS");
    const char* screen = getenv("CHA_SCREEN");
    if ((headless && *headless) || (screen && *screen)) {
      command_line->AppendSwitch("mute-audio");
      command_line->AppendSwitch("disable-backgrounding-occluded-windows");
      command_line->AppendSwitch("disable-renderer-backgrounding");
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
  NSString* root = NSProcessInfo.processInfo.environment[@"CHA_PROFILE"];
  if (root.length == 0) {
    NSString* support = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    root = [support stringByAppendingPathComponent:@"cha"];
  }
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
