#import "ChaTab.h"

#include <map>
#include <string>

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_handler.h"
#include "include/cef_command_ids.h"
#include "include/cef_context_menu_handler.h"
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
- (void)cefWindowDestroyed;
- (void)cefBrowserClosed;
- (void)cefRequestsNewTab:(NSString*)url;
- (void)cefRequestsNewTab:(NSString*)url background:(BOOL)background;
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
  TabHost(ChaTab* tab, const std::string& url, const CefRect& bounds)
      : tab_(tab), url_(url), bounds_(bounds) {}

  CefRefPtr<CefWindow> window;
  CefRefPtr<CefBrowserView> view;

  CefRefPtr<CefBrowser> browser() { return view ? view->GetBrowser() : nullptr; }

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
        ChaTab* tab = tab_;
        dispatch_async(dispatch_get_main_queue(), ^{
          [tab cefRequestsNewTab:url background:background];
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
                     bool,
                     const CefPopupFeatures&,
                     CefWindowInfo&,
                     CefRefPtr<CefClient>&,
                     CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&,
                     bool*) override {
    // ⌘-click on a link arrives here too, as a background tab.
    NSString* url = ToNSString(target_url);
    BOOL background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
    ChaTab* tab = tab_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [tab cefRequestsNewTab:url background:background];
    });
    return true;  // Handled: the app opens its own tab instead.
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
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
                                             nullptr, nullptr,
                                             new TabViewDelegate);
    w->AddChildView(view);
    w->Show();
    [tab_ cefWindowCreated];
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    view = nullptr;
    window = nullptr;
    [tab_ cefWindowDestroyed];
  }

 private:
  __weak ChaTab* tab_;
  std::string url_;
  CefRect bounds_;
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

@implementation ChaTab {
  CefRefPtr<TabHost> _host;
  CGFloat _cornerRadius;
}

- (instancetype)initWithURL:(NSString*)url screenFrame:(NSRect)screenFrame {
  self = [super init];
  _cornerRadius = 12;
  _currentURL = [url copy];
  _title = @"";
  _host = new TabHost(self, url.UTF8String, ScreenRectToCef(screenFrame));
  CefWindow::CreateTopLevelWindow(_host);
  return self;
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
}

- (void)close {
  if (_host && _host->window) {
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
  native.styleMask &= ~NSWindowStyleMaskResizable;
  native.hasShadow = NO;
  native.backgroundColor = NSColor.clearColor;
  native.opaque = NO;
  native.contentView.wantsLayer = YES;
  native.contentView.layer.cornerRadius = _cornerRadius;
  native.contentView.layer.masksToBounds = YES;
  [self.delegate tabDidBecomeReady:self];
}

- (void)cefWindowDestroyed {
  _host = nullptr;
}

- (void)cefBrowserClosed {
  [self.delegate tabDidClose:self];
}

- (void)cefRequestsNewTab:(NSString*)url {
  [self.delegate tab:self requestsNewTabWithURL:url];
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
