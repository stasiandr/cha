#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol ChaEngineDelegate <NSObject>
// Called once CEF is ready; build the UI here.
- (void)engineDidInitialize;
@end

// Owns the CEF browser process: library loading, initialization, message loop.
@interface ChaEngine : NSObject

@property(class, readonly) ChaEngine* shared;
@property(nonatomic, weak) id<ChaEngineDelegate> delegate;

// Installs the NSApplication subclass CEF requires. Call before any UI.
+ (void)installApplication;

// Loads the framework and initializes CEF. NO if the process should exit.
- (BOOL)startWithArgc:(int)argc argv:(char* _Nullable* _Nonnull)argv;

- (void)run;       // Runs the message loop until quit.
- (void)quit;      // Stops the message loop.
- (void)shutdown;  // Tears CEF down after run returns.

@end

NS_ASSUME_NONNULL_END
