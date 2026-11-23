#import "ChaEngine.h"

#include "include/cef_app.h"
#include "include/cef_request_context.h"
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
    const char* loud = getenv("CHA_LOUD");
    quiet = (headless && *headless) || (screen && *screen && !(loud && *loud));
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
  // Whatever happens below, the app is gone in 15 s (time for Chromium to write the profile out): quitting must never
  // leave a process nobody can close.
  static dispatch_once_t watchdog;
  dispatch_once(&watchdog, ^{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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

// The profile's Extensions/ folders that hold a manifest, comma-separated.
NSString* InstalledExtensionPaths() {
  NSString* root;
  if (const char* custom = getenv("CHA_PROFILE")) {
    root = [NSString stringWithUTF8String:custom];
  } else {
    NSURL* support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    root = [support.path stringByAppendingPathComponent:@"cha"];
  }
  NSString* dir = [root stringByAppendingPathComponent:@"Extensions"];
  NSMutableArray<NSString*>* paths = [NSMutableArray array];
  for (NSString* name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]
                             sortedArrayUsingSelector:@selector(compare:)]) {
    NSString* path = [dir stringByAppendingPathComponent:name];
    if ([NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingPathComponent:@"manifest.json"]] &&
        ![name hasPrefix:@"."]) {
      [paths addObject:path];
    }
  }
  return paths.count ? [paths componentsJoinedByString:@","] : nil;
}

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
    // Chrome extensions: every folder in the profile's Extensions/ with a
    // manifest (cha's Extensions window installs them there). Chromium
    // loads them as unpacked extensions; only at launch.
    if (NSString* list = InstalledExtensionPaths()) {
      command_line->AppendSwitchWithValue("load-extension", list.UTF8String);
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

  void OnContextInitialized() override {
    // Downloads are cha's (the sidebar's list): Chromium's own bubble, which
    // popped up on its own when a download finished, stays shut, and nothing
    // asks where to save.
    CefRefPtr<CefRequestContext> context = CefRequestContext::GetGlobalContext();
    const std::pair<const char*, bool> prefs[] = {
        {"download_bubble.partial_view_enabled", false},
        {"download.prompt_for_download", false},
    };
    for (const auto& [name, value] : prefs) {
      CefRefPtr<CefValue> v = CefValue::Create();
      v->SetBool(value);
      CefString error;
      if (!context->SetPreference(name, v, error)) {
        fprintf(stderr, "PREF %s not set: %s\n", name, error.ToString().c_str());
      }
    }
    [engine_.delegate engineDidInitialize];
  }

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
  // Chromium's own session (Sessions/ in each profile) is never wanted:
  // tabs are cha's (state.json). After a force quit Chromium restored it
  // and opened its own windows with the old tabs.
  NSFileManager* files = NSFileManager.defaultManager;
  for (NSString* name in [files contentsOfDirectoryAtPath:root error:nil]) {
    if ([name isEqualToString:@"Default"] || [name hasPrefix:@"Profile-"]) {
      NSString* sessions = [[root stringByAppendingPathComponent:name]
          stringByAppendingPathComponent:@"Sessions"];
      if ([files fileExistsAtPath:sessions]) {
        [files removeItemAtPath:sessions error:nil];
        fprintf(stderr, "SESSIONS removed %s\n", sessions.UTF8String);
      }
    }
  }
  CefString(&settings.root_cache_path) = root.UTF8String;
  CefString(&settings.cache_path) =
      [root stringByAppendingPathComponent:@"Default"].UTF8String;
  // Session cookies (no expiry) are what many sites keep a sign-in in; by
  // default Chromium drops them at quit, which signed people out.
  settings.persist_session_cookies = true;

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
