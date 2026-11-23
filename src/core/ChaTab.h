#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@class ChaTab;

@protocol ChaTabDelegate <NSObject>
// The tab's window exists and can be placed on screen.
- (void)tabDidBecomeReady:(ChaTab*)tab;
// Title, URL, loading state or favicon changed.
- (void)tabDidUpdate:(ChaTab*)tab;
// The main frame finished loading a page.
- (void)tabDidFinishLoad:(ChaTab*)tab;
// A link asked for a new tab or window.
- (void)tab:(ChaTab*)tab requestsNewTabWithURL:(NSString*)url;
// The web content closed itself.
- (void)tabDidClose:(ChaTab*)tab;
@optional
// A link to show in a Peek over the page: another site followed from a
// tab that keeps its site, or a ⇧-click.
- (void)tab:(ChaTab*)tab requestsPeekWithURL:(NSString*)url;
// A link to open in a new tab without leaving this one (⌘-click, the
// context menu's Open Link in New Tab).
- (void)tab:(ChaTab*)tab requestsBackgroundTabWithURL:(NSString*)url;
// The tab's window was made active by the page's side, not by cha: Chromium
// asks for its tab to come forward (a floating window's "Back to tab").
- (void)tabWantsToBeShown:(ChaTab*)tab NS_SWIFT_NAME(tabWantsToBeShown(_:));
// The page's floating window (document picture-in-picture) closed: by its
// close button, by "Back to tab", or by the page.
- (void)tabFloatingWindowClosed:(ChaTab*)tab NS_SWIFT_NAME(tabFloatingWindowClosed(_:));
// A new document started loading in the main frame.
- (void)tabDidStartLoad:(ChaTab*)tab NS_SWIFT_NAME(tabDidStartLoad(_:));
// A page script of cha's own sent a line back (console "__cha_app__ …").
- (void)tab:(ChaTab*)tab didSendMessage:(NSString*)message NS_SWIFT_NAME(tab(_:didSendMessage:));
// Find in page: |count| matches, the |active|-th selected (1-based).
- (void)tab:(ChaTab*)tab didFindCount:(int)count active:(int)active final:(BOOL)final;
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
// The browser is gone (OnBeforeClose): the page runs and plays no more.
@property(nonatomic, readonly) BOOL isClosed;
// Where pages that misbehave on closing are reported (cha's tabs.log).
@property(class, nonatomic, copy, nullable) void (^log)(NSString* line);
// A link to another app (slack:, mailto:, zoommtg:…) that a page follows or
// is loaded: Chromium would drop it, cha hands it to macOS through this.
// |userGesture|: a click or typed address, not a page sending itself there.
@property(class, nonatomic, copy, nullable) void (^openExternal)(NSString* url, BOOL userGesture);
// Not a web page: a scheme some other app opens.
+ (BOOL)isExternalURL:(NSString*)url;
// The page's document picture-in-picture window (Meet's floating call) is open.
@property(nonatomic, readonly) BOOL hasFloatingWindow;
// Off for the checks, so no floating window lands on the screen in use.
@property(class, nonatomic) BOOL allowsFloatingWindows;
// Pages' own popup windows (sign-in, OAuth) open right now.
@property(class, nonatomic, readonly) NSInteger openPopupCount;
// A call: the page has the camera or the microphone.
@property(nonatomic, readonly) BOOL usesCameraOrMicrophone;
// Sound: the page plays some (a <video>/<audio> not muted), or has some
// paused part-way; what the page says is playing (Media Session); cha's mute.
@property(nonatomic, readonly) BOOL isPlayingMedia;
@property(nonatomic, readonly) BOOL hasPausedMedia;
@property(nonatomic, readonly, copy) NSString* mediaTitle;
@property(nonatomic, readonly, copy) NSString* mediaArtist;
@property(nonatomic) BOOL audioMuted;
// A picture of what the page shows now (PNG), or nil.
- (void)captureVisiblePage:(void (^)(NSData* _Nullable png))completion;
// The mini player's buttons: "toggle" (play/pause), "nexttrack",
// "previoustrack", in every frame of the page.
- (void)sendMediaCommand:(NSString*)command;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;

// Creates the browser window at |screenFrame|; the delegate is told when ready.
- (instancetype)initWithURL:(NSString*)url screenFrame:(NSRect)screenFrame;
// The same in a profile of its own (nil: the default profile): separate
// cookies, sign-ins, passwords and storage.
- (instancetype)initWithURL:(NSString*)url
                screenFrame:(NSRect)screenFrame
                    profile:(nullable NSString*)profileID;
@property(nonatomic, readonly, copy, nullable) NSString* profileID;
// Starts setting a profile up ahead of its first tab (a new one takes
// Chromium a few seconds); tabs in a profile not ready yet wait for it.
+ (void)prepareProfile:(nullable NSString*)profileID;
// Call once before the first tab: page windows report cha's corner radius
// to Chromium from the start.
+ (void)prepareWindows;
// Pinned tabs and favourites: links to other sites go to a Peek.
@property(nonatomic) BOOL keepsItsSite;

- (void)loadURL:(NSString*)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
// ⇧⌘R: the site's caches emptied (the HTTP cache, its Cache Storage and
// service workers), then a reload that fetches everything anew. Cookies
// and site data stay: nobody is signed out.
- (void)reloadClearingCache;
- (void)stopLoading;
- (void)focus;
- (void)executeJavaScript:(NSString*)script;
// Runs |script| as if the user had just clicked the page (DevTools'
// Runtime.evaluate with userGesture), for APIs such as
// requestPictureInPicture that need one.
- (void)executeJavaScriptWithUserGesture:(NSString*)script;
// Synthesizes a real user click in the page, at view coordinates.
- (void)clickAtX:(int)x y:(int)y;
// The same with CEF event flags, e.g. 1 << 7 for ⌘.
- (void)clickAtX:(int)x y:(int)y modifiers:(uint32_t)modifiers;
- (void)close;
// The page's rounded corners (0 in full screen).
- (void)setCornerRadius:(CGFloat)radius;
// Chrome's own commands (cef_command_ids.h), e.g. IDC_FIND = 37000.
- (BOOL)canExecuteChromeCommand:(int)commandID;
- (void)executeChromeCommand:(int)commandID;
// What is selected in the page (or in its focused field), handed to
// |handler| on the main thread; "" when nothing is.
- (void)fetchSelection:(void (^)(NSString* text))handler;
// Find in page through CEF, without Chrome's find bar.
- (void)find:(NSString*)text forward:(BOOL)forward findNext:(BOOL)findNext;
- (void)stopFinding:(BOOL)clearSelection;

@end

// Downloads are reported app-wide as the "ChaDownloadUpdated" notification
// (id, url, name, path, received, total, speed, state); this cancels one.
@interface ChaTab (Downloads)
+ (void)cancelDownload:(uint32_t)downloadID;
@end

NS_ASSUME_NONNULL_END
