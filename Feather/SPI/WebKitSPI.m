#import "WebKitSPI.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// Private interfaces, declared only so the compiler knows the selectors.
// Signatures were checked against the WebKit runtime on macOS 27.0.
@protocol FTProcessPoolConfiguration <NSObject>
- (void)setUsesWebProcessCache:(BOOL)value;
- (void)setPrewarmsProcessesAutomatically:(BOOL)value;
- (void)setPageCacheEnabled:(BOOL)value;
- (void)setSuspendsWebProcessesAggressivelyOnMemoryPressure:(BOOL)value;
@end

@interface WKProcessPool (FTSPI)
- (instancetype)_initWithConfiguration:(id)configuration;
- (id)_configuration;
- (NSUInteger)_processCacheSize;
- (BOOL)_hasPrewarmedWebProcess;
- (void)_clearWebProcessCache;
- (NSUInteger)_webProcessCount;
@end

@interface WKWebView (FTSPI)
- (pid_t)_webProcessIdentifier;
- (pid_t)_networkProcessIdentifier;
- (pid_t)_gpuProcessIdentifier;
- (BOOL)_isPlayingAudio;
- (NSUInteger)_mediaMutedState;
- (void)_setPageMuted:(NSUInteger)mutedState;
@end

@interface WKPreferences (FTSPI)
- (void)_setHiddenPageDOMTimerThrottlingEnabled:(BOOL)enabled;
- (void)_setHiddenPageDOMTimerThrottlingAutoIncreases:(BOOL)enabled;
- (void)_setPageVisibilityBasedProcessSuppressionEnabled:(BOOL)enabled;
- (void)_setUsesPageCache:(BOOL)enabled;
- (void)_setAllowsPictureInPictureMediaPlayback:(BOOL)allowed;
@end

@implementation FTWebKitSPI

+ (BOOL)isAvailable {
    return NSClassFromString(@"_WKProcessPoolConfiguration") != nil &&
           [WKProcessPool instancesRespondToSelector:@selector(_initWithConfiguration:)];
}

+ (NSObject *)makeProcessPoolLean:(BOOL)lean {
    if (!self.isAvailable) return [[WKProcessPool alloc] init];
    id<FTProcessPoolConfiguration> configuration = [[NSClassFromString(@"_WKProcessPoolConfiguration") alloc] init];
    if ([configuration respondsToSelector:@selector(setUsesWebProcessCache:)])
        [configuration setUsesWebProcessCache:NO];
    if ([configuration respondsToSelector:@selector(setPrewarmsProcessesAutomatically:)])
        [configuration setPrewarmsProcessesAutomatically:NO];
    if ([configuration respondsToSelector:@selector(setSuspendsWebProcessesAggressivelyOnMemoryPressure:)])
        [configuration setSuspendsWebProcessesAggressivelyOnMemoryPressure:YES];
    if (lean && [configuration respondsToSelector:@selector(setPageCacheEnabled:)])
        [configuration setPageCacheEnabled:NO];
    return [[WKProcessPool alloc] _initWithConfiguration:configuration];
}

+ (void)assignProcessPool:(NSObject *)pool toConfiguration:(WKWebViewConfiguration *)configuration {
    if ([pool isKindOfClass:[WKProcessPool class]]) configuration.processPool = (WKProcessPool *)pool;
}

+ (void)applyThrottlingToPreferences:(WKPreferences *)preferences {
    if ([preferences respondsToSelector:@selector(_setHiddenPageDOMTimerThrottlingEnabled:)])
        [preferences _setHiddenPageDOMTimerThrottlingEnabled:YES];
    if ([preferences respondsToSelector:@selector(_setHiddenPageDOMTimerThrottlingAutoIncreases:)])
        [preferences _setHiddenPageDOMTimerThrottlingAutoIncreases:YES];
    if ([preferences respondsToSelector:@selector(_setPageVisibilityBasedProcessSuppressionEnabled:)])
        [preferences _setPageVisibilityBasedProcessSuppressionEnabled:YES];
}

+ (void)setPageCacheEnabled:(BOOL)enabled preferences:(WKPreferences *)preferences {
    if ([preferences respondsToSelector:@selector(_setUsesPageCache:)])
        [preferences _setUsesPageCache:enabled];
}

+ (pid_t)webProcessIdentifierForWebView:(WKWebView *)webView {
    return [webView respondsToSelector:@selector(_webProcessIdentifier)] ? webView._webProcessIdentifier : 0;
}

+ (pid_t)networkProcessIdentifierForWebView:(WKWebView *)webView {
    return [webView respondsToSelector:@selector(_networkProcessIdentifier)] ? webView._networkProcessIdentifier : 0;
}

+ (pid_t)gpuProcessIdentifierForWebView:(WKWebView *)webView {
    return [webView respondsToSelector:@selector(_gpuProcessIdentifier)] ? webView._gpuProcessIdentifier : 0;
}

+ (BOOL)isPlayingAudio:(WKWebView *)webView {
    return [webView respondsToSelector:@selector(_isPlayingAudio)] && webView._isPlayingAudio;
}

+ (BOOL)canDetectAudio:(WKWebView *)webView {
    return [webView respondsToSelector:@selector(_isPlayingAudio)];
}

+ (void)enablePictureInPictureForPreferences:(WKPreferences *)preferences {
    // Off by default in WKWebView on macOS; Safari turns it on. Without it, requestPictureInPicture() is NotSupportedError.
    if ([preferences respondsToSelector:@selector(_setAllowsPictureInPictureMediaPlayback:)]) {
        [preferences _setAllowsPictureInPictureMediaPlayback:YES];
    }
}

+ (BOOL)setAudioMuted:(BOOL)muted webView:(WKWebView *)webView {
    if (![webView respondsToSelector:@selector(_setPageMuted:)] || ![webView respondsToSelector:@selector(_mediaMutedState)]) return NO;
    // _WKMediaAudioMuted is bit 0; the other bits mute camera, microphone, and screen capture.
    NSUInteger state = webView._mediaMutedState;
    [webView _setPageMuted:muted ? (state | 1) : (state & ~(NSUInteger)1)];
    return YES;
}

+ (void)clearWebProcessCacheOfPool:(NSObject *)pool {
    if ([pool respondsToSelector:@selector(_clearWebProcessCache)]) [(WKProcessPool *)pool _clearWebProcessCache];
}

+ (NSDictionary<NSString *, NSNumber *> *)statusOfPool:(NSObject *)pool {
    NSMutableDictionary<NSString *, NSNumber *> *status = [NSMutableDictionary dictionary];
    WKProcessPool *processPool = (WKProcessPool *)pool;
    if ([pool respondsToSelector:@selector(_configuration)]) {
        id configuration = [processPool _configuration];
        for (NSString *key in @[@"usesWebProcessCache", @"prewarmsProcessesAutomatically", @"pageCacheEnabled",
                                @"suspendsWebProcessesAggressivelyOnMemoryPressure"]) {
            if ([configuration respondsToSelector:NSSelectorFromString(key)]) status[key] = [configuration valueForKey:key];
        }
    }
    if ([pool respondsToSelector:@selector(_processCacheSize)]) status[@"processCacheSize"] = @(processPool._processCacheSize);
    if ([pool respondsToSelector:@selector(_hasPrewarmedWebProcess)]) status[@"hasPrewarmedWebProcess"] = @(processPool._hasPrewarmedWebProcess);
    return status;
}

+ (NSInteger)webProcessCountOfPool:(NSObject *)pool {
    return [pool respondsToSelector:@selector(_webProcessCount)] ? (NSInteger)((WKProcessPool *)pool)._webProcessCount : -1;
}

@end
