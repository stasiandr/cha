#import "ChaTab.h"

#include <string>

#include "include/cef_browser.h"
#include "include/cef_client.h"
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
class TabHost : public CefClient,
                public CefDisplayHandler,
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

  // CefLifeSpanHandler
  bool OnBeforePopup(CefRefPtr<CefBrowser>,
                     CefRefPtr<CefFrame>,
                     int,
                     const CefString& target_url,
                     const CefString&,
                     WindowOpenDisposition,
                     bool,
                     const CefPopupFeatures&,
                     CefWindowInfo&,
                     CefRefPtr<CefClient>&,
                     CefBrowserSettings&,
                     CefRefPtr<CefDictionaryValue>&,
                     bool*) override {
    NSString* url = ToNSString(target_url);
    ChaTab* tab = tab_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [tab cefRequestsNewTab:url];
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

@implementation ChaTab {
  CefRefPtr<TabHost> _host;
}

- (instancetype)initWithURL:(NSString*)url screenFrame:(NSRect)screenFrame {
  self = [super init];
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

- (void)clickAtX:(int)x y:(int)y {
  auto browser = _host ? _host->browser() : nullptr;
  if (!browser) {
    return;
  }
  CefMouseEvent event;
  event.x = x;
  event.y = y;
  auto host = browser->GetHost();
  host->SendMouseMoveEvent(event, false);
  host->SendMouseClickEvent(event, MBT_LEFT, false, 1);
  host->SendMouseClickEvent(event, MBT_LEFT, true, 1);
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
  native.hasShadow = NO;
  native.backgroundColor = NSColor.clearColor;
  native.opaque = NO;
  native.contentView.wantsLayer = YES;
  native.contentView.layer.cornerRadius = 10;
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

- (void)cefChanged {
  [self.delegate tabDidUpdate:self];
}

@end
