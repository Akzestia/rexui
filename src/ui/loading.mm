// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import "ui/ui.h"

#include <notify.h>

@interface RXCoverHost : RXRoot
@end
@implementation RXCoverHost
- (NSView*)hitTest:(NSPoint)p {
    NSView* hit = [super hitTest:p];
    if (hit)
        return hit;
    return !self.hidden && NSPointInRect(p, self.frame) ? self : nil;
}
- (BOOL)mouseDownCanMoveWindow {
    return YES;
}
- (void)cursorUpdate:(NSEvent*)e {
}
- (void)rightMouseDown:(NSEvent*)e {
}
- (void)otherMouseDown:(NSEvent*)e {
}
- (void)scrollWheel:(NSEvent*)e {
}
@end

static RXDoc* g_cover;
static RXCoverHost* g_host;
static bool g_staging;
static bool g_docs_done, g_ready, g_lifting, g_waits;
static double g_t0;
static double g_progress;
static NSString* g_stage = @"";
static NSString* g_path;
static NSTimer *g_clock, *g_replay;
static bool g_hold;

static NSString* configured(void) {
    NSString* p = g_config.loading_screen;
    if (!p.length)
        return nil;
    p = p.stringByExpandingTildeInPath;
    if (!p.isAbsolutePath)
        p = [ui_dir() stringByAppendingPathComponent:p];
    return p.stringByStandardizingPath;
}

static NSString* cover_path(void) {
    NSString* p = configured();
    return p && [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}

static NSDictionary* state(void) {
    return @{
        @"active": @(g_cover != nil && !g_lifting),
        @"progress": @(g_progress),
        @"ready": @(g_ready),
        @"stage": g_stage ?: @"",
        @"elapsed": @(g_cover ? round((CACurrentMediaTime() - g_t0) * 10) / 10 : 0)
    };
}

static void push(void) {
    NSDictionary* s = state();
    if (g_cover.ctx)
        doc_call(g_cover, @"setLoading", @[s]);
    for (RXDoc* d in [g_docs copy])
        if (d.ctx)
            doc_call(d, @"setLoading", @[s]);
}

void loading_doc_loaded(id d) {
    RXDoc* doc = d;
    if (doc.ctx)
        doc_call(doc, @"setLoading", @[state()]);
}

bool loading_is_cover(NSString* path) {
    path = path.stringByStandardizingPath;
    return (g_cover && [path isEqualToString:g_path]) || [path isEqualToString:configured()];
}
bool loading_staging(void) {
    return g_cover && g_staging;
}

NSView* ui_loading_cover(NSView* chrome) {
    return g_host && g_host.superview == chrome ? g_host : nil;
}

static void lift(void);

static void ready_check(void) {
    if (!g_cover || g_ready || !g_docs_done || g_hold)
        return;
    NSWindow* w = dock_window();
    if (!w || !g_host.window)
        return;
    g_ready = true;
    g_progress = 1;
    rexui_log([NSString stringWithFormat:@"loading: ready after %.2f s", CACurrentMediaTime() - g_t0]);
    push();
    if (!g_waits)
        lift();
}

void loading_place(NSView* chrome) {
    if (!g_cover || !g_host || !chrome)
        return;
    if (g_host.superview && g_host.superview != chrome) {
        NSWindow* want = dock_window();
        if (!want || chrome.window != want)
            return;
    }
    if (g_host.superview != chrome) {
        [g_host removeFromSuperview];
        g_host.frame = chrome.bounds;
        [chrome addSubview:g_host positioned:NSWindowAbove relativeTo:nil];
    } else if (chrome.subviews.lastObject != g_host) {
        for (NSView* v in [chrome.subviews copy]) {
            if (v == g_host || [chrome.subviews indexOfObject:v] < [chrome.subviews indexOfObject:g_host])
                continue;
            [chrome addSubview:v positioned:NSWindowBelow relativeTo:g_host];
        }
    }
    if (!NSEqualRects(g_host.frame, chrome.bounds))
        g_host.frame = chrome.bounds;
    if (RXDockView* v = g_cover.root.host)
        [g_host addHost:v band:0];
    NSAppearance* look = [NSAppearance appearanceNamed:g_theme.dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    if (![g_host.appearance.name isEqualToString:look.name])
        g_host.appearance = look;
    place(g_cover.root, g_host.bounds);
    place_natives(g_cover);
    if (g_docs_done && !g_ready)
        dispatch_async(dispatch_get_main_queue(), ^{
            ready_check();
        });
}

static void place_now(void) {
    NSWindow* w = dock_window();
    if (!w) {
        for (NSWindow* c in NSApp.windows)
            if (is_rex_window(c) && chrome_of(c)) {
                w = c;
                break;
            }
    }
    if (NSView* chrome = w ? chrome_of(w) : nil)
        loading_place(chrome);
}

static void done(void) {
    [g_clock invalidate];
    g_clock = nil;
    [g_replay invalidate];
    g_replay = nil;
    g_hold = false;
    RXDoc* doc = g_cover;
    g_cover = nil;
    g_lifting = false;
    g_staging = false;
    if (doc)
        unload(doc);
    [g_host removeFromSuperview];
    g_host = nil;
    g_progress = 0;
    g_ready = false;
    push();
    chrome_relayout();
}

static void lift(void) {
    if (!g_cover || g_lifting)
        return;
    g_lifting = true;
    push();
    double ms = num(g_cover.root, P::animation, 400);
    rexui_log([NSString stringWithFormat:@"loading: lifted after %.2f s", CACurrentMediaTime() - g_t0]);
    if (!g_host.window || ms <= 0)
        return done();
    fade_layer(g_host.layer, 0, ms, ^{
        done();
    });
}

static void replay(void) {
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    for (RXDoc* d in g_docs)
        if (!d.pane && d.root)
            [names addObject:d.path.lastPathComponent.stringByDeletingPathExtension];
    __block NSUInteger i = 0;
    g_replay = [NSTimer
        scheduledTimerWithTimeInterval:0.11
                               repeats:YES
                                 block:^(NSTimer* t) {
                                     if (!g_cover || g_lifting)
                                         return [t invalidate];
                                     if (i < names.count) {
                                         g_stage = names[i++];
                                         g_progress = 0.9 * i / names.count;
                                         push();
                                         return;
                                     }
                                     [t invalidate];
                                     g_replay = nil;
                                     g_docs_done = true;
                                     dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                                                    dispatch_get_main_queue(), ^{
                                                        ready_check();
                                                    });
                                 }];
}

static bool start(bool stage, NSString* path = nil) {
    if (g_cover)
        return true;
    path = path.length ? path.stringByExpandingTildeInPath.stringByStandardizingPath : cover_path();
    if (!path || ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        rexui_log([@"loading: no file " stringByAppendingString:path
                                            ?: g_config.loading_screen.length ? g_config.loading_screen
                                                                              : @"(loading_screen is unset)"]);
        return false;
    }
    NSString* src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    g_waits = [src containsString:@"loading.finish"];
    g_path = path;
    g_t0 = CACurrentMediaTime();
    g_progress = 0;
    g_stage = @"";
    g_ready = false;
    g_lifting = false;
    g_docs_done = false;
    g_staging = stage;
    RXDoc* doc = [RXDoc new];
    doc.path = path;
    doc.mtime = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
    g_cover = doc;
    load(doc);
    if (!doc.root || !doc.ctx || !is_elem(doc.root, E::Dock)) {
        rexui_log([path.lastPathComponent stringByAppendingString:@": a loading screen is a Dock"]);
        g_cover = nil;
        if (doc.ctx)
            unload(doc);
        g_staging = false;
        return false;
    }
    g_host = [[RXCoverHost alloc] initWithFrame:NSZeroRect];
    g_host.wantsLayer = YES;
    g_host.translatesAutoresizingMaskIntoConstraints = NO;
    push();
    place_now();
    double cap = g_config.loading_max > 0 ? g_config.loading_max : 15;
    g_clock = [NSTimer scheduledTimerWithTimeInterval:0.1
                                              repeats:YES
                                                block:^(NSTimer*) {
                                                    if (!g_cover || g_lifting)
                                                        return;
                                                    if (!g_host.superview)
                                                        place_now();
                                                    ready_check();
                                                    if (!g_hold && CACurrentMediaTime() - g_t0 > cap) {
                                                        rexui_log(@"loading: loading_max reached");
                                                        return lift();
                                                    }
                                                    if (g_cover.ctx)
                                                        doc_call(g_cover, @"setLoading", @[state()]);
                                                }];
    [NSRunLoop.mainRunLoop addTimer:g_clock forMode:NSRunLoopCommonModes];
    if (!stage)
        replay();
    rexui_log([NSString stringWithFormat:@"loading: %@ up%s%s", path.lastPathComponent, stage ? "" : " (a preview)",
                                         g_hold ? ", held" : ""]);
    return true;
}

static bool play(NSString* path, bool hold) {
    if (g_cover)
        done();
    g_hold = hold;
    if (start(false, path))
        return true;
    g_hold = false;
    return false;
}

static void stop(void) {
    if (!g_cover)
        return;
    if (g_hold) {
        g_hold = false;
        g_docs_done = true;
        [g_replay invalidate];
        g_replay = nil;
        ready_check();
    } else {
        lift();
    }
}

static void take_request(void) {
    NSString* req = [g_state stringForKey:@"loading"];
    if (!req.length)
        return;
    [g_state removeObjectForKey:@"loading"];
    NSArray<NSString*>* f = [req componentsSeparatedByString:@"\t"];
    if ([f[0] isEqualToString:@"stop"])
        return stop();
    if ([f[0] isEqualToString:@"play"])
        play(f.count > 1 ? f[1] : nil, f.count > 2 && [f[2] isEqualToString:@"hold"]);
}

void loading_start(void) {
    [g_state removeObjectForKey:@"loading"];
    int token;
    notify_register_dispatch("com.rexui.loading", &token, dispatch_get_main_queue(), ^(int) {
        [g_state synchronize];
        take_request();
    });
    start(true);
}

void loading_scanned(NSUInteger have, NSUInteger total, NSString* last, bool more) {
    if (!loading_staging())
        return;
    if (last.length)
        g_stage = last.lastPathComponent.stringByDeletingPathExtension;
    g_progress = total ? 0.9 * have / total : 0.9;
    if (more) {
        push();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            scan();
        });
        return;
    }
    g_staging = false;
    g_docs_done = true;
    push();
    chrome_relayout();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        ready_check();
    });
}

void loading_scan(void) {
    take_request();
    if (!g_cover || g_lifting)
        return;
    NSDate* m = [NSFileManager.defaultManager attributesOfItemAtPath:g_cover.path error:nil].fileModificationDate;
    if (!m || [m isEqual:g_cover.mtime])
        return;
    unload(g_cover);
    g_cover.mtime = m;
    load(g_cover);
    place_now();
}

id loading_native(NSString* op) {
    if ([op isEqualToString:@"finish"]) {
        if (g_cover)
            lift();
    } else if ([op isEqualToString:@"preview"]) {
        return @(play(nil, false));
    }
    return nil;
}
