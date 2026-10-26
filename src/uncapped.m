// uncapped.m — lets Metal games on macOS render past the display's refresh rate.
// SPDX-License-Identifier: GPL-3.0-only
//
// 1. Forces CAMetalLayer.displaySyncEnabled = NO, so frames aren't held to vsync.
// 2. Catches the display link a game uses to pace frames
//    (-[NSView/NSWindow/NSScreen displayLinkWithTarget:selector:]) and also
//    fires its callback from a high-rate timer, so the game is no longer limited
//    to one frame per screen refresh.
// 3. Reports the screen as UNCAPPED_FPS Hz to the game, so refresh-based
//    limiters don't clamp back down.
// 4. Roblox only: feeds the same target to its AdaptiveSync frame pacer.
// 5. Counts finished frames and shows them in a small overlay.
//
// Environment: UNCAPPED_FPS (default 1000, 0 = only disable vsync),
//              UNCAPPED_OVERLAY=0 to hide the overlay.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <stdatomic.h>
#import <sys/sysctl.h>

void UncappedOverlayUpdate(NSString *text);

static int gTargetFps = 1000;
static BOOL gOverlay = YES;
static atomic_uint_fast64_t gRendered, gShown;

// Frame-time history (microseconds between finished frames), last ~10 s.
#define RING 8192
static _Atomic uint32_t gFrameUs[RING];
static atomic_uint_fast64_t gFrameIdx;
static _Atomic uint64_t gLastFrameTicks;
static char gChip[64] = "Apple Silicon";

static void recordFrame(void) {
    uint64_t now = mach_absolute_time();
    uint64_t prev = atomic_exchange(&gLastFrameTicks, now);
    if (!prev) return;
    uint64_t us = (now - prev) * gTB.numer / gTB.denom / 1000;
    if (us == 0 || us > 1000000) return;   // skip pauses (tabbed out, loading)
    uint64_t i = atomic_fetch_add(&gFrameIdx, 1);
    atomic_store(&gFrameUs[i % RING], (uint32_t)us);
}

static int cmpU32(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *)a, y = *(const uint32_t *)b;
    return (x > y) - (x < y);
}

// Average FPS with the fastest and slowest 5% of frames dropped, plus 1% low.
static void frameStats(double *avgFps, double *lowFps) {
    static uint32_t buf[RING];
    uint64_t total = atomic_load(&gFrameIdx);
    size_t n = total < RING ? (size_t)total : RING;
    *avgFps = *lowFps = 0;
    if (n < 60) return;
    for (size_t i = 0; i < n; i++) buf[i] = atomic_load(&gFrameUs[i]);
    qsort(buf, n, sizeof buf[0], cmpU32);
    size_t cut = n / 20;
    double sum = 0;
    for (size_t i = cut; i < n - cut; i++) sum += buf[i];
    double meanUs = sum / (double)(n - 2 * cut);
    *avgFps = meanUs > 0 ? 1e6 / meanUs : 0;
    uint32_t p99 = buf[n - 1 - n / 100];
    *lowFps = p99 ? 1e6 / p99 : 0;
}
static mach_timebase_info_data_t gTB;
static uint64_t gLastTick;

static void swizzle(Class cls, SEL sel, IMP repl, IMP *orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) *orig = method_setImplementation(m, repl);
}

// --- Metal: vsync off + frame counting ---------------------------------------

static IMP oSetSync, oNextDrawable;

static void h_setDisplaySyncEnabled(id self, SEL _cmd, BOOL on) {
    ((void (*)(id, SEL, BOOL))oSetSync)(self, _cmd, NO);
}

static id h_nextDrawable(id self, SEL _cmd) {
    CAMetalLayer *layer = self;
    if (layer.displaySyncEnabled)
        ((void (*)(id, SEL, BOOL))oSetSync)(self, @selector(setDisplaySyncEnabled:), NO);
    if (layer.maximumDrawableCount < 3) layer.maximumDrawableCount = 3;
    id<CAMetalDrawable> d = ((id (*)(id, SEL))oNextDrawable)(self, _cmd);
    [d addPresentedHandler:^(id<MTLDrawable> p) {
        atomic_fetch_add(&gRendered, 1);
        recordFrame();
        if (p.presentedTime > 0) atomic_fetch_add(&gShown, 1);
    }];
    return d;
}

// --- Refresh-rate spoofing -----------------------------------------------------

static IMP oMaxFps, oMinInterval, oMaxRefresh;
static NSInteger h_maximumFramesPerSecond(id s, SEL c) { return gTargetFps; }
static NSTimeInterval h_minimumRefreshInterval(id s, SEL c) { return 1.0 / gTargetFps; }
static double h_maximumRefreshRate(id s, SEL c) { return gTargetFps; }
static NSInteger realMaxFps(NSScreen *s) {
    return s && oMaxFps ? ((NSInteger (*)(id, SEL))oMaxFps)(s, @selector(maximumFramesPerSecond)) : 0;
}

// --- Display-link booster ------------------------------------------------------

// Forwards everything to the real link but reports timestamps for our timer.
@interface UncappedLinkProxy : NSProxy
@property (nonatomic, strong) CADisplayLink *real;
@property (nonatomic) CFTimeInterval ts;
@end
@implementation UncappedLinkProxy
- (CFTimeInterval)timestamp { return _ts; }
- (CFTimeInterval)duration { return 1.0 / gTargetFps; }
- (CFTimeInterval)targetTimestamp { return _ts + 1.0 / gTargetFps; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)s { return [_real methodSignatureForSelector:s]; }
- (void)forwardInvocation:(NSInvocation *)inv { [inv invokeWithTarget:_real]; }
@end

static id gTarget;
static SEL gAction;
static CADisplayLink *gLink;
static UncappedLinkProxy *gProxy;
static dispatch_source_t gBoost;

static void forceRobloxPacer(id t);

static void boostTick(void) {
    if (!gTarget || !gLink || gLink.paused) return;
    forceRobloxPacer(gTarget);
    gProxy.ts = CACurrentMediaTime();
    ((void (*)(id, SEL, id))objc_msgSend)(gTarget, gAction, gProxy);
}

static void startBooster(void) {
    if (gBoost) return;
    uint64_t interval = NSEC_PER_SEC / (uint64_t)gTargetFps;
    gBoost = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT,
                                    dispatch_get_main_queue());
    dispatch_source_set_timer(gBoost, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, 0);
    dispatch_source_set_event_handler(gBoost, ^{ boostTick(); });
    dispatch_resume(gBoost);
}

typedef id (*DLMakeFn)(id, SEL, id, SEL);
static void hookLinkMaker(Class cls) {
    SEL sel = @selector(displayLinkWithTarget:selector:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    __block IMP orig = NULL;
    orig = method_setImplementation(m, imp_implementationWithBlock(^id(id me, id target, SEL action) {
        id link = ((DLMakeFn)orig)(me, sel, target, action);
        dispatch_async(dispatch_get_main_queue(), ^{
            gTarget = target;
            gAction = action;
            gLink = link;
            if (!gProxy) gProxy = [UncappedLinkProxy alloc];
            gProxy.real = link;
            startBooster();
        });
        return link;
    }));
}

static IMP oInvalidate;
static void h_invalidate(id self, SEL _cmd) {
    if (self == gLink) { gTarget = nil; gLink = nil; }
    ((void (*)(id, SEL))oInvalidate)(self, _cmd);
}

// --- Roblox: AdaptiveSync frame pacer ------------------------------------------

static IMP oSetSchedule, oFrameTarget, oScreenMax;
static void h_setRenderScheduleFps(id s, SEL c, int fps) {
    ((void (*)(id, SEL, int))oSetSchedule)(s, c, gTargetFps);
}
static double h_frameTargetMs(id s, SEL c) { return 1000.0 / gTargetFps; }
static double h_screenMaxFps(id s, SEL c) { return gTargetFps; }

static void hookRobloxPacer(void) {
    static BOOL done;
    Class c = NSClassFromString(@"AdaptiveSync");
    if (done || !c) return;
    done = YES;
    swizzle(c, @selector(setRenderScheduleFps:), (IMP)h_setRenderScheduleFps, &oSetSchedule);
    swizzle(c, @selector(frameTargetMs), (IMP)h_frameTargetMs, &oFrameTarget);
    swizzle(c, @selector(screenMaxFps), (IMP)h_screenMaxFps, &oScreenMax);
}

static void forceRobloxPacer(id t) {
    static Class cls;
    static ptrdiff_t oSched = -1, oTarget = -1, oScreen = -1;
    if (cls != [t class]) {
        cls = [t class];
        Ivar a = class_getInstanceVariable(cls, "renderScheduleFps");
        Ivar b = class_getInstanceVariable(cls, "frameTargetMs");
        Ivar d = class_getInstanceVariable(cls, "screenMaxFps");
        oSched = a ? ivar_getOffset(a) : -1;
        oTarget = b ? ivar_getOffset(b) : -1;
        oScreen = d ? ivar_getOffset(d) : -1;
    }
    char *base = (__bridge void *)t;
    if (oSched >= 0) *(int *)(base + oSched) = gTargetFps;
    if (oTarget >= 0) atomic_store((_Atomic double *)(base + oTarget), 1000.0 / gTargetFps);
    if (oScreen >= 0) atomic_store((_Atomic double *)(base + oScreen), (double)gTargetFps);
}

// --- Reporting -------------------------------------------------------------------

static void report(void) {
    uint64_t now = mach_absolute_time();
    double secs = (double)(now - gLastTick) * gTB.numer / gTB.denom / 1e9;
    gLastTick = now;
    if (secs <= 0) return;
    double render = atomic_exchange(&gRendered, 0) / secs;
    atomic_exchange(&gShown, 0);
    double avg, low;
    frameStats(&avg, &low);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSScreen *screen = NSApp.keyWindow.screen ?: NSScreen.mainScreen;
        long hz = (long)(realMaxFps(screen) ?: screen.maximumFramesPerSecond);
        NSString *text = [NSString stringWithFormat:@"%s · %ld Hz\nNow %.0f · Avg %.0f · 1%% low %.0f",
                          gChip, hz, render, avg, low];
        fprintf(stderr, "[uncapped] %s | now %.0f avg %.0f 1%%low %.0f\n", gChip, render, avg, low);
        if (gOverlay) UncappedOverlayUpdate(text);
    });
}

__attribute__((constructor))
static void uncapped_init(void) {
    const char *e = getenv("UNCAPPED_FPS");
    if (e) gTargetFps = atoi(e);
    if (gTargetFps < 0) gTargetFps = 0;
    e = getenv("UNCAPPED_OVERLAY");
    if (e && strcmp(e, "0") == 0) gOverlay = NO;

    swizzle([CAMetalLayer class], @selector(setDisplaySyncEnabled:), (IMP)h_setDisplaySyncEnabled, &oSetSync);
    swizzle([CAMetalLayer class], @selector(nextDrawable), (IMP)h_nextDrawable, &oNextDrawable);

    if (gTargetFps > 0) {
        swizzle([NSScreen class], @selector(maximumFramesPerSecond), (IMP)h_maximumFramesPerSecond, &oMaxFps);
        swizzle([NSScreen class], @selector(minimumRefreshInterval), (IMP)h_minimumRefreshInterval, &oMinInterval);
        swizzle([CADisplayLink class], @selector(maximumRefreshRate), (IMP)h_maximumRefreshRate, &oMaxRefresh);
        swizzle([CADisplayLink class], @selector(invalidate), (IMP)h_invalidate, &oInvalidate);
        hookLinkMaker([NSView class]);
        hookLinkMaker([NSWindow class]);
        hookLinkMaker([NSScreen class]);
        hookRobloxPacer();
    }

    mach_timebase_info(&gTB);
    size_t len = sizeof gChip;
    if (sysctlbyname("machdep.cpu.brand_string", gChip, &len, NULL, 0) != 0)
        strlcpy(gChip, "Unknown Mac", sizeof gChip);
    gLastTick = mach_absolute_time();
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                              NSEC_PER_SEC / 2, 10 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ report(); });
    dispatch_resume(timer);

    fprintf(stderr, "[uncapped] loaded, target %d fps\n", gTargetFps);
}
