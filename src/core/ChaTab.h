#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class ChaTab;

@protocol ChaTabDelegate <NSObject>
// The tab's window exists and can be placed on screen.
- (void)tabDidBecomeReady:(ChaTab*)tab;
// Title, URL, loading state or favicon changed.
- (void)tabDidUpdate:(ChaTab*)tab;
// A link asked for a new tab or window.
- (void)tab:(ChaTab*)tab requestsNewTabWithURL:(NSString*)url;
// The web content closed itself.
- (void)tabDidClose:(ChaTab*)tab;
@end

// One tab: a frameless Chrome-style CEF window hosting a single browser. On
// macOS Chrome style requires a CEF window of its own, so the app shows a tab
// by attaching this window as a child of the main window.
@interface ChaTab : NSObject

@property(nonatomic, weak) id<ChaTabDelegate> delegate;
@property(nonatomic, readonly, nullable) NSWindow* nativeWindow;
@property(nonatomic, readonly, copy) NSString* currentURL;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, nullable) NSImage* favicon;
@property(nonatomic, readonly) BOOL isLoading;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;

// Creates the browser window at |screenFrame|; the delegate is told when ready.
- (instancetype)initWithURL:(NSString*)url screenFrame:(NSRect)screenFrame;

- (void)loadURL:(NSString*)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)stopLoading;
- (void)focus;
- (void)executeJavaScript:(NSString*)script;
// Synthesizes a real user click in the page, at view coordinates.
- (void)clickAtX:(int)x y:(int)y;
- (void)close;

@end

NS_ASSUME_NONNULL_END
