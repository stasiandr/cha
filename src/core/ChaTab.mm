#import "ChaTab.h"

#include <map>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string>

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_handler.h"
#include "include/cef_command_ids.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_fill_layout.h"
#include "include/views/cef_window.h"

@interface ChaTab ()
// Written from the CEF callbacks, which run on the main thread.
@property(nonatomic, copy) NSString* currentURL;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, nullable) NSImage* favicon;
@property(nonatomic) BOOL isLoading;
@property(nonatomic) BOOL canGoBack;
@property(nonatomic) BOOL canGoForward;
- (void)cefWindowCreated;
- (void)cefWindowDestroyed:(BOOL)browserAlive;
- (void)cefBrowserClosed;
- (void)cefRequestsNewTab:(NSString*)url;
- (void)cefRequestsNewTab:(NSString*)url background:(BOOL)background;
- (void)cefRequestsPeek:(NSString*)url;
- (BOOL)cefConsoleMessage:(NSString*)message;
- (void)cefDidFinishLoad;
- (void)cefChanged;
@end

namespace {

NSString* ToNSString(const CefString& value) {
  return [NSString stringWithUTF8String:value.ToString().c_str()];
}

// Toolbar-less Chrome style: keeps Chrome's password manager and autofill
// while the surrounding UI stays ours.
class TabViewDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override {
    return CEF_CTT_NONE;
  }
  IMPLEMENT_REFCOUNTING(TabViewDelegate);
};

class FaviconCallback : public CefDownloadImageCallback {
 public:
  explicit FaviconCallback(ChaTab* tab) : tab_(tab) {}

  void OnDownloadImageFinished(const CefString&,
                               int http_status_code,
                               CefRefPtr<CefImage> image) override {
    ChaTab* tab = tab_;
    if (!tab || !image) {
      return;
    }
    int width = 0, height = 0;
    auto binary = image->GetAsPNG(1.0f, true, width, height);
    if (!binary) {
      return;
    }
    NSMutableData* data = [NSMutableData dataWithLength:binary->GetSize()];
    binary->GetData(data.mutableBytes, binary->GetSize(), 0);
    NSImage* icon = [[NSImage alloc] initWithData:data];
    dispatch_async(dispatch_get_main_queue(), ^{
      tab.favicon = icon;
      [tab cefChanged];
    });
  }

 private:
  __weak ChaTab* tab_;
  IMPLEMENT_REFCOUNTING(FaviconCallback);
};

// Client and window delegate for a single tab.
// Profiles: each has its own Chromium profile (cookies, sign-ins, saved
// passwords, storage) in <root>/Profile-<id>; the default one is CEF's
// global context, <root>/Default, as before profiles existed. Chromium only
// keeps a profile whose folder sits right in the root, like Default: one a
// level deeper (<root>/Profiles/<id>, as at first) silently ran in memory
// and lost every sign-in at quit.
NSString* ProfilesRoot() {
  NSString* root = NSProcessInfo.processInfo.environment[@"CHA_PROFILE"];
  if (root.length == 0) {
    NSString* support = [NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    root = [support stringByAppendingPathComponent:@"cha"];
  }
  return root;
}

// What every profile gets once ready: downloads are cha's own.
// A profile Chromium is still setting up (a new one takes seconds) can't
// load pages yet: tabs wait for it and open once it is ready.
std::map<std::string, bool>& ProfileReady() {
  static std::map<std::string, bool> ready;
  return ready;
}
std::map<std::string, NSMutableArray*>& ProfileWaiting() {
  static std::map<std::string, NSMutableArray*> waiting;
  return waiting;
}

class ProfileHandler : public CefRequestContextHandler {
 public:
  explicit ProfileHandler(const std::string& key) : key_(key) {}
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    std::string key = key_;
    dispatch_async(dispatch_get_main_queue(), ^{
      ProfileReady()[key] = true;
      NSMutableArray* waiting = ProfileWaiting()[key];
      ProfileWaiting().erase(key);
      for (void (^open)(void) in waiting) {
        open();
      }
    });
    const std::pair<const char*, bool> prefs[] = {
        {"download_bubble.partial_view_enabled", false},
        {"download.prompt_for_download", false},
    };
    for (const auto& [name, value] : prefs) {
      CefRefPtr<CefValue> v = CefValue::Create();
      v->SetBool(value);
      CefString error;
      context->SetPreference(name, v, error);
    }
  }
 private:
  std::string key_;
  IMPLEMENT_REFCOUNTING(ProfileHandler);
};

CefRefPtr<CefRequestContext> ContextForProfile(NSString* profileID) {
  if (profileID.length == 0) {
    return nullptr;  // The global context: the default profile.
  }
  static std::map<std::string, CefRefPtr<CefRequestContext>> contexts;
  std::string key = profileID.UTF8String;
  auto found = contexts.find(key);
  if (found != contexts.end()) {
    return found->second;
  }
  NSString* path = [ProfilesRoot() stringByAppendingPathComponent:[@"Profile-" stringByAppendingString:profileID]];
  [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
  CefRequestContextSettings settings;
  CefString(&settings.cache_path) = path.UTF8String;
  // Sign-ins that use session cookies survive a restart too.
  settings.persist_session_cookies = true;
  CefRefPtr<CefRequestContext> context = CefRequestContext::CreateContext(settings, new ProfileHandler(key));
  contexts[key] = context;
  return context;
}

// The site a URL belongs to, for "is this another website": the host less
// "www." and, beyond two labels, its leading ones (mail.google.com and
// docs.google.com are one site). Good enough without a public-suffix list.
NSString* SiteOf(NSString* url) {
  NSString* host = [NSURL URLWithString:url].host.lowercaseString ?: @"";
  NSArray<NSString*>* labels = [host componentsSeparatedByString:@"."];
  if (labels.count > 2 && [host rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound) {
    labels = [labels subarrayWithRange:NSMakeRange(labels.count - 2, 2)];
  }
  return [labels componentsJoinedByString:@"."];
}

// Schemes Chromium shows itself; anything else belongs to another app.
BOOL IsExternalURL(NSString* url) {
  NSRange colon = [url rangeOfString:@":"];
  if (colon.location == NSNotFound || colon.location == 0) return NO;
  NSString* scheme = [url substringToIndex:colon.location].lowercaseString;
  NSCharacterSet* bad = [[NSCharacterSet characterSetWithCharactersInString:
      @"abcdefghijklmnopqrstuvwxyz0123456789+.-"] invertedSet];
  if ([scheme rangeOfCharacterFromSet:bad].location != NSNotFound) return NO;
  static NSSet* web = [NSSet setWithArray:@[
    @"http", @"https", @"about", @"data", @"blob", @"file", @"filesystem",
    @"javascript", @"chrome", @"chrome-extension", @"chrome-untrusted",
    @"chrome-error", @"devtools", @"view-source", @"ws", @"wss"
  ]];
  return ![web containsObject:scheme];
}

static void (^gOpenExternal)(NSString*, BOOL);

// Live downloads' callbacks, for cancelling from the downloads list.
std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>>& DownloadCallbacks() {
  static std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> callbacks;
  return callbacks;
}

// Where a download goes: ~/Downloads (CHA_DOWNLOADS for the checks), with
// " (1)", " (2)"… when the name is taken.
NSString* DownloadPath(NSString* suggested) {
  NSString* dir = NSProcessInfo.processInfo.environment[@"CHA_DOWNLOADS"];
  if (dir.length == 0) {
    dir = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
  }
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  NSString* name = suggested.length > 0 ? suggested.lastPathComponent : @"download";
  NSString* base = name.stringByDeletingPathExtension;
  NSString* ext = name.pathExtension;
  NSString* path = [dir stringByAppendingPathComponent:name];
  for (int i = 1; [NSFileManager.defaultManager fileExistsAtPath:path]; i++) {
    NSString* numbered = [NSString stringWithFormat:@"%@ (%d)", base, i];
    if (ext.length > 0) numbered = [numbered stringByAppendingPathExtension:ext];
    path = [dir stringByAppendingPathComponent:numbered];
  }
  return path;
}

class TabHost : public CefClient,
                public CefCommandHandler,
                public CefContextMenuHandler,
                public CefRequestHandler,
                public CefDisplayHandler,
                public CefDownloadHandler,
                public CefFindHandler,
                public CefLifeSpanHandler,
                public CefLoadHandler,
                public CefWindowDelegate {
 public:
  TabHost(ChaTab* tab, const std::string& url, const CefRect& bounds,
          CefRefPtr<CefRequestContext> context)
      : tab_(tab), url_(url), bounds_(bounds), context_(context) {}

  CefRefPtr<CefWindow> window;
  CefRefPtr<CefBrowserView> view;

  // The page's browser from its creation to OnBeforeClose, whether or not
  // its window still exists.
  CefRefPtr<CefBrowser> alive;
  CefRefPtr<CefBrowser> browser() { return view && view->GetBrowser() ? view->GetBrowser() : alive; }

  // CefClient
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefCommandHandler> GetCommandHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  // Links that ask for a new tab or window become cha's tabs; otherwise
  // Chromium opens a browser window of its own, tab strip and all.

  // CefContextMenuHandler: "Open Link in New Tab / Window / …".
  bool OnContextMenuCommand(CefRefPtr<CefBrowser>,
                            CefRefPtr<CefFrame>,
                            CefRefPtr<CefContextMenuParams> params,
                            int command_id,
                            EventFlags) override {
    switch (command_id) {
      case IDC_CONTENT_CONTEXT_OPENLINKNEWTAB:
      case IDC_CONTENT_CONTEXT_OPENLINKNEWWINDOW:
      case IDC_CONTENT_CONTEXT_OPENLINKOFFTHERECORD:
      case IDC_CONTENT_CONTEXT_OPENLINKINPROFILE:
      case IDC_CONTENT_CONTEXT_OPENLINKSPLITVIEW: {
        NSString* url = ToNSString(params->GetLinkUrl());
        if (url.length == 0) {
          return false;
        }
        BOOL background = command_id == IDC_CONTENT_CONTEXT_OPENLINKNEWTAB;
        ChaTab* tab = tab_;
        dispatch_async(dispatch_get_main_queue(), ^{
          [tab cefRequestsNewTab:url background:background];
        });
        return true;
      }
      default:
        return false;
    }
  }

  // CefRequestHandler: a pinned tab (or favourite) stays on its site, as in
  // Arc. A link the user follows to another site opens in a Peek over the
  // page instead of taking the tab away.
  bool OnBeforeBrowse(CefRefPtr<CefBrowser>,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    ChaTab* tab = tab_;
    NSString* url = ToNSString(request->GetURL());
    if (gOpenExternal && IsExternalURL(url)) {
      BOOL gesture = user_gesture;
      dispatch_async(dispatch_get_main_queue(), ^{
        if (gOpenExternal) gOpenExternal(url, gesture);
      });
      return true;  // Cancelled: the page stays where it is.
    }
    if (!tab.keepsItsSite || !frame->IsMain() || !user_gesture || is_redirect) {
      return false;
    }
    NSString* target = ToNSString(request->GetURL());
    NSString* here = tab.currentURL;
    if (![target hasPrefix:@"http"] || [SiteOf(target) isEqualToString:SiteOf(here)]) {
      return false;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [tab cefRequestsPeek:target];
    });
    return true;  // Cancelled: the pinned tab stays where it is.
  }

  // CefRequestHandler: ⌘-click (background), ⇧⌘-click and middle click.
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser>,
                        CefRefPtr<CefFrame>,
                        const CefString& target_url,
                        WindowOpenDisposition disposition,
                        bool) override {
    switch (disposition) {
      case CEF_WOD_NEW_FOREGROUND_TAB:
      case CEF_WOD_NEW_BACKGROUND_TAB:
      case CEF_WOD_NEW_WINDOW:
      case CEF_WOD_NEW_POPUP:
      case CEF_WOD_OFF_THE_RECORD: {
        NSString* url = ToNSString(target_url);
        BOOL background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
        BOOL peek = disposition == CEF_WOD_NEW_WINDOW;
        ChaTab* tab = tab_;
        dispatch_async(dispatch_get_main_queue(), ^{
          if (peek) {
            [tab cefRequestsPeek:url];
          } else {
            [tab cefRequestsNewTab:url background:background];
          }
        });
        return true;  // Cancelled here: cha opens it.
      }
      default:
        return false;
    }
  }

  // CefCommandHandler: Chrome's own commands that would open its windows or
  // tab strip (its shortcuts, when a page has the keyboard) do nothing; cha's
  // menu has its own versions.
  bool OnChromeCommand(CefRefPtr<CefBrowser>, int command_id,
                       cef_window_open_disposition_t) override {
    switch (command_id) {
      case IDC_NEW_WINDOW:
      case IDC_NEW_INCOGNITO_WINDOW:
      case IDC_NEW_TAB:
      case IDC_NEW_TAB_TO_RIGHT:
      case IDC_DUPLICATE_TAB:
      case IDC_RESTORE_TAB:
      case IDC_OPEN_IN_PWA_WINDOW:
      case IDC_SELECT_NEXT_TAB:
      case IDC_SELECT_PREVIOUS_TAB:
      case IDC_EXIT:
      case IDC_CLOSE_WINDOW:
      case IDC_SHOW_HISTORY:
      case IDC_SHOW_BOOKMARK_MANAGER:
      case IDC_SHOW_DOWNLOADS:
      case IDC_OPTIONS:
      case IDC_OPEN_FILE:
        return true;
      default:
        return false;
    }
  }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }

  // CefDownloadHandler: the app's own list instead of Chrome's bubble,
  // which has no toolbar to sit in here.
  bool OnBeforeDownload(CefRefPtr<CefBrowser>,
                        CefRefPtr<CefDownloadItem> item,
                        const CefString& suggested_name,
                        CefRefPtr<CefBeforeDownloadCallback> callback) override {
    callback->Continue(DownloadPath(ToNSString(suggested_name)).UTF8String, false);
    return true;
  }

  void OnDownloadUpdated(CefRefPtr<CefBrowser>,
                         CefRefPtr<CefDownloadItem> item,
                         CefRefPtr<CefDownloadItemCallback> callback) override {
    if (!item->IsValid()) {
      return;
    }
    uint32_t identifier = item->GetId();
    NSString* state = item->IsComplete()      ? @"complete"
                      : item->IsCanceled()    ? @"canceled"
                      : item->IsInterrupted() ? @"interrupted"
                                              : @"progress";
    if ([state isEqualToString:@"progress"]) {
      DownloadCallbacks()[identifier] = callback;
    } else {
      DownloadCallbacks().erase(identifier);
    }
    NSString* path = ToNSString(item->GetFullPath());
    NSString* name = path.length > 0 ? path.lastPathComponent : ToNSString(item->GetSuggestedFileName());
    NSDictionary* info = @{
      @"id" : @(identifier),
      @"url" : ToNSString(item->GetURL()),
      @"name" : name ?: @"",
      @"path" : path ?: @"",
      @"received" : @(item->GetReceivedBytes()),
      @"total" : @(item->GetTotalBytes()),
      @"speed" : @(item->GetCurrentSpeed()),
      @"state" : state,
    };
    [NSNotificationCenter.defaultCenter postNotificationName:@"ChaDownloadUpdated" object:nil userInfo:info];
  }

  // CefFindHandler
  void OnFindResult(CefRefPtr<CefBrowser>,
                    int,
                    int count,
                    const CefRect&,
                    int activeMatchOrdinal,
                    bool finalUpdate) override {
    ChaTab* tab = tab_;
    if ([tab.delegate respondsToSelector:@selector(tab:didFindCount:active:final:)]) {
      [tab.delegate tab:tab didFindCount:count active:activeMatchOrdinal final:finalUpdate];
    }
  }

  // CefDisplayHandler
  // Answers to cha's own scripts come back as console messages with a
  // marker; they are taken here and never reach the page's console.
  bool OnConsoleMessage(CefRefPtr<CefBrowser>, cef_log_severity_t, const CefString& message,
                        const CefString&, int) override {
    return [tab_ cefConsoleMessage:ToNSString(message)];
  }

  void OnTitleChange(CefRefPtr<CefBrowser>, const CefString& title) override {
    ChaTab* tab = tab_;
    tab.title = ToNSString(title);
    [tab cefChanged];
  }
  void OnAddressChange(CefRefPtr<CefBrowser>,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (!frame->IsMain()) {
      return;
    }
    ChaTab* tab = tab_;
    tab.currentURL = ToNSString(url);
    [tab cefChanged];
  }
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser,
                          const std::vector<CefString>& urls) override {
    if (urls.empty()) {
      return;
    }
    browser->GetHost()->DownloadImage(urls.front(), /*is_favicon=*/true,
                                      /*max_image_size=*/32,
                                      /*bypass_cache=*/false,
                                      new FaviconCallback(tab_));
  }

  // CefLoadHandler
  void OnLoadingStateChange(CefRefPtr<CefBrowser>,
                            bool isLoading,
                            bool canGoBack,
                            bool canGoForward) override {
    ChaTab* tab = tab_;
    tab.isLoading = isLoading;
    tab.canGoBack = canGoBack;
    tab.canGoForward = canGoForward;
    [tab cefChanged];
  }

  void OnLoadEnd(CefRefPtr<CefBrowser>,
                 CefRefPtr<CefFrame> frame,
                 int) override {
    if (frame->IsMain()) {
      [tab_ cefDidFinishLoad];
    }
  }

  // CefLifeSpanHandler
  bool OnBeforePopup(CefRefPtr<CefBrowser>,
                     CefRefPtr<CefFrame>,
                     int,
                     const CefString& target_url,
                     const CefString&,
                     WindowOpenDisposition disposition,
                     bool user_gesture,
                     const CefPopupFeatures&,
                     CefWindowInfo&,
                     CefRefPtr<CefClient>&,
                     CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&,
                     bool*) override {
    // ⌘-click on a link arrives here too, as a background tab; ⇧-click as a
    // new window, which in cha (as in Arc) is a Peek.
    // Document picture in picture (Meet's floating call window) isn't
    // supported yet: refused, rather than opened as an empty tab.
    if (disposition == CEF_WOD_NEW_PICTURE_IN_PICTURE) {
      return true;
    }
    NSString* url = ToNSString(target_url);
    BOOL background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    BOOL peek = disposition == CEF_WOD_NEW_WINDOW && user_gesture;
    ChaTab* tab = tab_;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (peek) {
        [tab cefRequestsPeek:url];
      } else {
        [tab cefRequestsNewTab:url background:background];
      }
    });
    return true;  // Handled: the app opens its own tab instead.
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { alive = browser; }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    alive = nullptr;
    [tab_ cefBrowserClosed];
  }

  // CefWindowDelegate
  cef_runtime_style_t GetWindowRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  bool CanMaximize(CefRefPtr<CefWindow>) override { return false; }
  // The page's window is pinned inside cha's: it moves and resizes only
  // with it, never by itself under the pointer.
  bool CanResize(CefRefPtr<CefWindow>) override { return false; }
  bool CanMinimize(CefRefPtr<CefWindow>) override { return false; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return bounds_; }
  void OnWindowCreated(CefRefPtr<CefWindow> w) override {
    window = w;
    w->SetToFillLayout();
    view = CefBrowserView::CreateBrowserView(this, url_, CefBrowserSettings(),
                                             nullptr, context_,
                                             new TabViewDelegate);
    w->AddChildView(view);
    w->Show();
    [tab_ cefWindowCreated];
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    view = nullptr;
    window = nullptr;
    [tab_ cefWindowDestroyed:alive != nullptr];
  }

 private:
  __weak ChaTab* tab_;
  std::string url_;
  CefRect bounds_;
  CefRefPtr<CefRequestContext> context_;
  IMPLEMENT_REFCOUNTING(TabHost);
};

// AppKit screen coordinates have the origin at the bottom left; CEF uses the
// top left of the main screen.
CefRect ScreenRectToCef(NSRect frame) {
  CGFloat screenTop = NSScreen.screens.firstObject.frame.size.height;
  return CefRect((int)frame.origin.x,
                 (int)(screenTop - frame.origin.y - frame.size.height),
                 (int)frame.size.width, (int)frame.size.height);
}

}  // namespace

// macOS draws a titled window's corners itself (CEF's page windows are
// titled, their title bar hidden), whatever the content's layer says: the
// page stayed rounded in full screen. The page windows' class answers the
// window server's two questions (_cornerRadius, _cornerMask) with cha's own
// radius instead — 0 there, 12 for the card.
static const void* kChaCornerRadiusKey = &kChaCornerRadiusKey;

static void ChaOverrideCorners(Class cls) {
  static NSMutableSet* done;
  if (!done) done = [NSMutableSet set];
  NSString* name = NSStringFromClass(cls);
  if ([done containsObject:name]) {
    return;
  }
  [done addObject:name];

  SEL radiusSel = NSSelectorFromString(@"_cornerRadius");
  Method radius = class_getInstanceMethod(cls, radiusSel);
  if (radius) {
    IMP replacement = imp_implementationWithBlock(^CGFloat(NSWindow* window) {
      // Chromium asks this when it makes the window, before cha has set
      // anything, and rounds the page it draws by it (the window was titled
      // then: ~16 pt on macOS 26) until the app is switched away and back.
      // Page windows answer cha's radius, 0 until it is set: the card's
      // rounding is cha's own layer.
      // Always 0: Chromium reads it rarely (at creation, on app switches),
      // so a card's 12 stuck when the page went full screen. The card is
      // rounded by cha's own layer, which clips whatever Chromium draws.
      return (CGFloat)0;
    });
    class_replaceMethod(cls, radiusSel, replacement, method_getTypeEncoding(radius));
  }

  SEL maskSel = NSSelectorFromString(@"_cornerMask");
  Method mask = class_getInstanceMethod(cls, maskSel);
  if (mask) {
    IMP replacement = imp_implementationWithBlock(^id(NSWindow* window) {
      return (id)nil;  // No system mask: the shape is the layer's.
    });
    class_replaceMethod(cls, maskSel, replacement, method_getTypeEncoding(mask));
  }
}

static void ChaApplyCornerRadius(NSWindow* window, CGFloat radius) {
  if (!window) return;
  ChaOverrideCorners(window.class);
  objc_setAssociatedObject(window, kChaCornerRadiusKey, @(radius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  // Have the window server ask again.
  SEL update = NSSelectorFromString(@"_updateCornerMask");
  if ([window respondsToSelector:update]) {
    ((void(*)(id, SEL))objc_msgSend)(window, update);
  }
  [window invalidateShadow];
  [window display];
}

// Before any page window exists (CEF's window class is in the framework,
// loaded by now).
void ChaPreparePageWindowCorners() {
  Class cls = NSClassFromString(@"CefNSWindow");
  if (cls) {
    ChaOverrideCorners(cls);
  }
}

@implementation ChaTab (Downloads)
+ (void)cancelDownload:(uint32_t)downloadID {
  auto& callbacks = DownloadCallbacks();
  auto found = callbacks.find(downloadID);
  if (found != callbacks.end()) {
    found->second->Cancel();
    callbacks.erase(found);
  }
}
@end

static void (^gTabLog)(NSString*);

@implementation ChaTab {
  CefRefPtr<TabHost> _host;
  CGFloat _cornerRadius;
  BOOL _wantsClose;
  void (^_selectionHandler)(NSString*);
}

+ (void (^)(NSString*))log {
  return gTabLog;
}

+ (void)setLog:(void (^)(NSString*))log {
  gTabLog = [log copy];
}

+ (void (^)(NSString*, BOOL))openExternal {
  return gOpenExternal;
}

+ (void)setOpenExternal:(void (^)(NSString*, BOOL))openExternal {
  gOpenExternal = [openExternal copy];
}

+ (BOOL)isExternalURL:(NSString*)url {
  return IsExternalURL(url);
}

static NSString* const kSelectionMarker = @"__cha_selection__";

- (void)fetchSelection:(void (^)(NSString*))handler {
  _selectionHandler = [handler copy];
  // The page's selection, or the selected part of the focused field.
  [self executeJavaScript:[NSString stringWithFormat:
      @"(() => { const e = document.activeElement; let t = '';"
       "try { if (e && typeof e.selectionStart === 'number' && e.value !== undefined)"
       "  t = e.value.substring(e.selectionStart, e.selectionEnd); } catch (x) {}"
       "if (!t) t = String(window.getSelection());"
       "console.log('%@' + JSON.stringify(t)); })()", kSelectionMarker]];
}

- (BOOL)cefConsoleMessage:(NSString*)message {
  if (![message hasPrefix:kSelectionMarker]) {
    return NO;
  }
  NSData* json = [[message substringFromIndex:kSelectionMarker.length] dataUsingEncoding:NSUTF8StringEncoding];
  NSString* text = [NSJSONSerialization JSONObjectWithData:json options:NSJSONReadingFragmentsAllowed error:nil];
  void (^handler)(NSString*) = _selectionHandler;
  _selectionHandler = nil;
  if (handler) {
    handler([text isKindOfClass:NSString.class] ? text : @"");
  }
  return YES;
}

- (instancetype)initWithURL:(NSString*)url screenFrame:(NSRect)screenFrame {
  return [self initWithURL:url screenFrame:screenFrame profile:nil];
}

- (instancetype)initWithURL:(NSString*)url
                screenFrame:(NSRect)screenFrame
                    profile:(nullable NSString*)profileID {
  self = [super init];
  _cornerRadius = 12;
  _currentURL = [url copy];
  _title = @"";
  _profileID = [profileID copy];
  _host = new TabHost(self, url.UTF8String, ScreenRectToCef(screenFrame), ContextForProfile(profileID));
  std::string key = profileID.length ? profileID.UTF8String : "";
  if (key.empty() || ProfileReady()[key]) {
    CefWindow::CreateTopLevelWindow(_host);
  } else {
    CefRefPtr<TabHost> host = _host;
    if (!ProfileWaiting()[key]) {
      ProfileWaiting()[key] = [NSMutableArray array];
    }
    [ProfileWaiting()[key] addObject:[^{
      CefWindow::CreateTopLevelWindow(host);
    } copy]];
  }
  return self;
}

+ (void)prepareWindows {
  ChaPreparePageWindowCorners();
}

+ (void)prepareProfile:(nullable NSString*)profileID {
  ContextForProfile(profileID);
}

- (nullable NSWindow*)nativeWindow {
  if (!_host || !_host->window) {
    return nil;
  }
  NSView* view =
      CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(_host->window->GetWindowHandle());
  return view.window;
}

- (void)loadURL:(NSString*)url {
  if (gOpenExternal && IsExternalURL(url)) {
    gOpenExternal(url, YES);  // typed or opened from elsewhere: asked for
    return;
  }
  if (auto browser = _host ? _host->browser() : nullptr) {
    browser->GetMainFrame()->LoadURL(url.UTF8String);
  }
}

- (void)goBack {
  if (auto browser = _host ? _host->browser() : nullptr) {
    browser->GoBack();
  }
}

- (void)goForward {
  if (auto browser = _host ? _host->browser() : nullptr) {
    browser->GoForward();
  }
}

- (void)reload {
  if (auto browser = _host ? _host->browser() : nullptr) {
    browser->Reload();
  }
}

- (void)reloadClearingCache {
  auto browser = _host ? _host->browser() : nullptr;
  if (!browser) {
    return;
  }
  auto host = browser->GetHost();
  // One DevTools channel, taken in order: the caches go before the reload.
  host->ExecuteDevToolsMethod(0, "Network.clearBrowserCache", nullptr);
  NSURL* url = [NSURL URLWithString:self.currentURL];
  if ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"]) {
    NSString* origin = [NSString stringWithFormat:@"%@://%@%@", url.scheme, url.host,
                                 url.port ? [NSString stringWithFormat:@":%@", url.port] : @""];
    CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
    params->SetString("origin", origin.UTF8String);
    params->SetString("storageTypes", "cache_storage,service_workers,shader_cache");
    host->ExecuteDevToolsMethod(0, "Storage.clearDataForOrigin", params);
  }
  CefRefPtr<CefDictionaryValue> reload = CefDictionaryValue::Create();
  reload->SetBool("ignoreCache", true);
  host->ExecuteDevToolsMethod(0, "Page.reload", reload);
}

- (void)stopLoading {
  if (auto browser = _host ? _host->browser() : nullptr) {
    browser->StopLoad();
  }
}

- (void)focus {
  if (_host && _host->view) {
    _host->view->RequestFocus();
  }
}

- (void)executeJavaScript:(NSString*)script {
  if (auto browser = _host ? _host->browser() : nullptr) {
    browser->GetMainFrame()->ExecuteJavaScript(script.UTF8String, "", 0);
  }
}

- (void)executeJavaScriptWithUserGesture:(NSString*)script {
  auto browser = _host ? _host->browser() : nullptr;
  if (!browser) {
    return;
  }
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("expression", script.UTF8String);
  params->SetBool("userGesture", true);
  browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
}

- (void)clickAtX:(int)x y:(int)y {
  [self clickAtX:x y:y modifiers:0];
}

- (void)clickAtX:(int)x y:(int)y modifiers:(uint32_t)modifiers {
  auto browser = _host ? _host->browser() : nullptr;
  if (!browser) {
    return;
  }
  CefMouseEvent event;
  event.x = x;
  event.y = y;
  event.modifiers = modifiers;
  auto host = browser->GetHost();
  host->SendMouseMoveEvent(event, false);
  host->SendMouseClickEvent(event, MBT_LEFT, false, 1);
  host->SendMouseClickEvent(event, MBT_LEFT, true, 1);
}

- (BOOL)canExecuteChromeCommand:(int)commandID {
  auto browser = _host ? _host->browser() : nullptr;
  return browser && browser->GetHost()->CanExecuteChromeCommand(commandID);
}

- (void)executeChromeCommand:(int)commandID {
  if (auto browser = _host ? _host->browser() : nullptr) {
    browser->GetHost()->ExecuteChromeCommand(commandID, CEF_WOD_CURRENT_TAB);
  }
}

- (void)find:(NSString*)text forward:(BOOL)forward findNext:(BOOL)findNext {
  if (auto browser = _host ? _host->browser() : nullptr) {
    browser->GetHost()->Find(text.UTF8String, forward, false, findNext);
  }
}

- (void)stopFinding:(BOOL)clearSelection {
  if (auto browser = _host ? _host->browser() : nullptr) {
    browser->GetHost()->StopFinding(clearSelection);
  }
}

- (void)setCornerRadius:(CGFloat)radius {
  _cornerRadius = radius;
  NSWindow* native = self.nativeWindow;
  native.contentView.wantsLayer = YES;
  native.contentView.layer.cornerRadius = radius;
  ChaApplyCornerRadius(native, radius);
}

// Ends the page for good, silent at once: the page's window closes and
// takes the browser along. Asked again (the page still there), the
// browser itself is told to close without asking. A tab closed before its
// browser exists closes as soon as it does.
- (void)close {
  BOOL again = _wantsClose;
  _wantsClose = YES;
  auto browser = _host ? _host->browser() : nullptr;
  if (browser) {
    browser->GetHost()->SetAudioMuted(true);
  }
  if (again && browser) {
    browser->GetHost()->CloseBrowser(true);
  } else if (_host && _host->window) {
    _host->window->Close();
  }
}

// Chromium draws the page into a layer-backed view; rounding the corners here
// keeps the tab looking like a card inside the main window.
- (void)cefWindowCreated {
  NSWindow* native = self.nativeWindow;
  native.collectionBehavior = NSWindowCollectionBehaviorTransient |
                              NSWindowCollectionBehaviorIgnoresCycle |
                              NSWindowCollectionBehaviorFullScreenAuxiliary;
  native.excludedFromWindowsMenu = YES;
  native.movable = NO;
  native.movableByWindowBackground = NO;
  // Borderless: macOS's window server rounds a titled window's corners on its
  // own (CEF's frameless windows are titled with the bar hidden), and no layer
  // or mask setting undoes it — the page stayed rounded in full screen. The
  // card's rounding is the content layer's (setCornerRadius:).
  native.styleMask = NSWindowStyleMaskBorderless;
  native.hasShadow = NO;
  native.backgroundColor = NSColor.clearColor;
  native.opaque = NO;
  native.contentView.wantsLayer = YES;
  native.contentView.layer.cornerRadius = _cornerRadius;
  ChaApplyCornerRadius(native, _cornerRadius);
  native.contentView.layer.masksToBounds = YES;
  if (_wantsClose) {
    _wantsClose = NO;
    [self close];
    return;
  }
  [self.delegate tabDidBecomeReady:self];
}

// Normally the browser has closed by now. One that outlives its window
// would play on with nothing to close it from: it is told to go, muted.
- (void)cefWindowDestroyed:(BOOL)browserAlive {
  auto browser = browserAlive && _host ? _host->browser() : nullptr;
  if (!browser) {
    _host = nullptr;
    return;
  }
  NSString* line = [NSString stringWithFormat:@"window gone before its browser, closing: %@", self.currentURL];
  if (ChaTab.log) {
    ChaTab.log(line);
  }
  browser->GetHost()->SetAudioMuted(true);
  browser->GetHost()->CloseBrowser(true);
}

- (void)cefBrowserClosed {
  _isClosed = YES;
  if (_host && _host->window) {
    _host->window->Close();  // the page's window goes with its browser
  } else {
    _host = nullptr;
  }
  [self.delegate tabDidClose:self];
}

- (void)cefRequestsNewTab:(NSString*)url {
  [self.delegate tab:self requestsNewTabWithURL:url];
}

- (void)cefRequestsPeek:(NSString*)url {
  if ([self.delegate respondsToSelector:@selector(tab:requestsPeekWithURL:)]) {
    [self.delegate tab:self requestsPeekWithURL:url];
  } else {
    [self.delegate tab:self requestsNewTabWithURL:url];
  }
}

- (void)cefRequestsNewTab:(NSString*)url background:(BOOL)background {
  if (background && [self.delegate respondsToSelector:@selector(tab:requestsBackgroundTabWithURL:)]) {
    [self.delegate tab:self requestsBackgroundTabWithURL:url];
  } else {
    [self.delegate tab:self requestsNewTabWithURL:url];
  }
}

- (void)cefChanged {
  [self.delegate tabDidUpdate:self];
}

- (void)cefDidFinishLoad {
  [self.delegate tabDidFinishLoad:self];
}

@end
