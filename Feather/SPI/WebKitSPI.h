// The only place Feather touches private WebKit API. Every call checks that the
// class or selector exists at runtime and falls back to public behaviour, so an
// OS update that drops one of these degrades efficiency instead of crashing.

#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface FTWebKitSPI : NSObject

/// YES when the process-pool configuration SPI is present.
@property (class, readonly) BOOL isAvailable;

/// A process pool that keeps no idle WebContent processes around: no process
/// cache, no prewarmed process, and aggressive suspension under memory
/// pressure. `lean` also turns off the back/forward page cache at pool level.
/// Returns a plain pool when the SPI is missing. Typed as NSObject because the
/// public WKProcessPool class is deprecated; it is a WKProcessPool.
+ (NSObject *)makeProcessPoolLean:(BOOL)lean;

/// Uses `pool` for web views made from `configuration`. The public setter is
/// deprecated, but a pool made with `makeProcessPoolLean:` still takes effect.
+ (void)assignProcessPool:(NSObject *)pool toConfiguration:(WKWebViewConfiguration *)configuration
    NS_SWIFT_NAME(assignProcessPool(_:to:));

/// Throttles timers in hidden pages and lets WebKit suppress hidden pages' processes.
+ (void)applyThrottlingToPreferences:(WKPreferences *)preferences;

/// Back/forward page cache: instant "Back" at the cost of keeping old pages in memory.
+ (void)setPageCacheEnabled:(BOOL)enabled preferences:(WKPreferences *)preferences;

/// WebContent identifier, or 0 when unknown. The Network/GPU testing getters
/// can trap before those processes exist; discover them by process ownership
/// instead when inspecting a newly constructed view.
+ (pid_t)webProcessIdentifierForWebView:(WKWebView *)webView;
+ (pid_t)networkProcessIdentifierForWebView:(WKWebView *)webView;
+ (pid_t)gpuProcessIdentifierForWebView:(WKWebView *)webView;

/// Whether the page is currently producing audio (KVO-observable key `_isPlayingAudio`).
+ (BOOL)isPlayingAudio:(WKWebView *)webView;

/// Whether `isPlayingAudio:` is backed by WebKit rather than always NO.
+ (BOOL)canDetectAudio:(WKWebView *)webView;

/// Lets pages (and Feather) put videos into picture-in-picture.
+ (void)enablePictureInPictureForPreferences:(WKPreferences *)preferences NS_SWIFT_NAME(enablePictureInPicture(for:));

/// Mutes or unmutes all of the page's audio, in every frame. NO if unsupported.
+ (BOOL)setAudioMuted:(BOOL)muted webView:(WKWebView *)webView NS_SWIFT_NAME(setAudioMuted(_:webView:));

/// Drops any cached WebContent processes the pool still holds.
+ (void)clearWebProcessCacheOfPool:(NSObject *)pool;

/// The pool's effective settings and what it is holding right now, read back
/// from WebKit: usesWebProcessCache, prewarmsProcessesAutomatically,
/// pageCacheEnabled, suspendsWebProcessesAggressivelyOnMemoryPressure,
/// processCacheSize, hasPrewarmedWebProcess. Missing keys are unknown.
+ (NSDictionary<NSString *, NSNumber *> *)statusOfPool:(NSObject *)pool;

/// Number of WebContent processes the pool owns, or -1 when unknown.
+ (NSInteger)webProcessCountOfPool:(NSObject *)pool;

@end

NS_ASSUME_NONNULL_END
