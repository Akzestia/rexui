// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "chrome/chrome.h"
#include "rex/rex.h"
#include "ui/ui.h"

static NSDictionary* g_layout;
static void count_frames(void);

NSString* rexstate_zoomed(void) {
    return [g_layout[@"zoomed"] isKindOfClass:NSString.class] ? g_layout[@"zoomed"] : @"";
}

static bool g_layout_events, g_layout_dirty = true;
static double g_layout_at;
void rexstate_layout_dirty(void) {
    g_layout_dirty = true;
}
static void read_layout(void);
void rexstate_rex_event(bool connected) {
    if (connected)
        g_layout_events = true;
    g_layout_dirty = true;
    static bool due;
    if (due)
        return;
    due = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        due = false;
        read_layout();
    });
}

void rexstate_layout(void) {
    count_frames();
    if (g_layout_events && !g_layout_dirty && CACurrentMediaTime() - g_layout_at < 5)
        return;
    read_layout();
}

static void read_layout(void) {
    g_layout_dirty = false;
    g_layout_at = CACurrentMediaTime();
    bool wanted = false;
    for (RXDoc* d in g_docs)
        wanted |= d.wants_rexstate && d.ctx;
    NSDictionary* l = (__bridge_transfer NSDictionary*)rex_layout_state();
    if (l.count)
        term_full_zoom([l[@"zoomed"] isKindOfClass:NSString.class] ? l[@"zoomed"] : @"");
    if (!l.count || [l isEqualToDictionary:g_layout])
        return;
    NSString* was = g_layout[@"failure"];
    bool zoom = ![l[@"zoomed"] ?: @"" isEqual:g_layout[@"zoomed"] ?: @""];
    g_layout = l;
    if (zoom)
        pane_styles_changed(true);
    if ([l[@"failure"] length] && ![l[@"failure"] isEqualToString:was ?: @""])
        notices_post(@"Pane", l[@"failure"]);
    if (!wanted)
        return;
    NSDictionary* p = @{@"zoomed": l[@"zoomed"] ?: @"", @"busy": l[@"busy"] ?: @NO, @"arriving": l[@"arriving"] ?: @""};
    for (RXDoc* d in [g_docs copy])
        if (d.ctx && d.wants_rexstate)
            doc_call(d, @"setPanes", @[p]);
}

#include <unordered_map>
static std::unordered_map<const void*, int> g_frames;
static id (*orig_next_drawable)(id, SEL);
static id hook_next_drawable(CAMetalLayer* self, SEL sel) {
    g_frames[(__bridge const void*)self]++;
    return orig_next_drawable(self, sel);
}

static CAMetalLayer* metal_in(CALayer* l, int depth) {
    if ([l isKindOfClass:CAMetalLayer.class])
        return (CAMetalLayer*)l;
    if (depth > 6)
        return nil;
    for (CALayer* s in l.sublayers)
        if (CAMetalLayer* m = metal_in(s, depth + 1))
            return m;
    return nil;
}

static void count_frames(void) {
    static double at;
    static bool hooked;
    bool wanted = false;
    for (RXDoc* d in g_docs)
        wanted |= d.wants_fps_panes && d.ctx;
    if (!wanted)
        return;
    if (!hooked) {
        hooked = true;
        swizzle(CAMetalLayer.class, @selector(nextDrawable), (IMP)hook_next_drawable, (IMP*)&orig_next_drawable);
        at = CACurrentMediaTime();
        g_frames.clear();
        return;
    }
    double now = CACurrentMediaTime(), dt = MAX(0.001, now - at);
    at = now;
    NSMutableDictionary* fps = [NSMutableDictionary dictionary];
    NSDictionary<NSString*, NSView*>* views = pane_views_now();
    for (NSString* bid in views) {
        CAMetalLayer* m = metal_in(views[bid].layer, 0);
        fps[bid] = @(m ? lround(g_frames[(__bridge const void*)m] / dt) : 0);
    }
    g_frames.clear();
    for (RXDoc* d in [g_docs copy])
        if (d.ctx && d.wants_fps_panes)
            doc_call(d, @"setPanes", @[@{@"fps": fps}]);
}

static NSView* surface_under_pointer(void) {
    static Class cls = NSClassFromString(RXNS(RXN_165)) ?: NSClassFromString(RXNS(RXN_164));
    NSInteger n = [NSWindow windowNumberAtPoint:NSEvent.mouseLocation belowWindowWithWindowNumber:0];
    NSWindow* w = [NSApp windowWithWindowNumber:n];
    if (!w || !cls)
        return nil;
    NSView* v = [w.contentView.superview ?: w.contentView hitTest:[w convertPointFromScreen:NSEvent.mouseLocation]];
    while (v && ![v isKindOfClass:cls])
        v = v.superview;
    return v;
}

static void pointer_tick(void) {
    RX_INTERVAL(timer, "pointer_tick");
    static NSString* last_link = @"";
    static bool last_hints;
    bool link = false, hints = false;
    for (RXDoc* d in g_docs)
        link |= d.wants_hover && d.ctx, hints |= d.wants_hints && d.ctx;
    if (link) {
        NSView* s = surface_under_pointer();
        NSString* u = s ? (__bridge_transfer NSString*)rex_hovered_link((__bridge void*)s) : term_hovered_link();
        if (![u ?: @"" isEqualToString:last_link]) {
            last_link = u ?: @"";
            for (RXDoc* d in [g_docs copy])
                if (d.ctx && d.wants_hover)
                    doc_call(d, @"setContext", @[@{@"hoveredLink": last_link}]);
        }
    }
    if (hints) {
        bool now = (NSEvent.modifierFlags & NSEventModifierFlagCommand) && rex_hints_revealed() == 1;
        if (now != last_hints) {
            last_hints = now;
            for (RXDoc* d in [g_docs copy])
                if (d.ctx && d.wants_hints)
                    doc_call(d, @"setKeys", @[@{@"hints": @(now)}]);
        }
    }
}

static NSMutableArray<NSDictionary*>* g_history;

void rexstate_tab_changed(NSString* session, int tab) {
    if (!session.length || tab < 1)
        return;
    if (!g_history)
        g_history = [NSMutableArray array];
    NSDictionary* e = @{@"session": session, @"tab": @(tab)};
    if ([g_history.lastObject isEqualToDictionary:e])
        return;
    [g_history removeObject:e];
    [g_history addObject:e];
    while (g_history.count > 50)
        [g_history removeObjectAtIndex:0];
}

static bool go_back(void) {
    if (g_history.count < 2)
        return false;
    NSDictionary* to = g_history[g_history.count - 2];
    if (![to[@"session"] isEqualToString:g_session_id])
        rex_run(@"session.select", @{@"session_id": to[@"session"]});
    rex_run(@"client.tab.goto", @{@"index": to[@"tab"]});
    return true;
}

static void layers_speed(NSView* v, float speed, int depth) {
    if (depth > 12)
        return;
    if ([v isKindOfClass:RXRoot.class]) {
        v.layer.speed = speed;
        return;
    }
    for (NSView* s in v.subviews)
        layers_speed(s, speed, depth + 1);
}

static double set_time_scale(double scale) {
    double now = rex_time_scale(scale > 0 ? scale : 0, true);
    for (NSWindow* w in NSApp.windows)
        if (w.contentView)
            layers_speed(w.contentView.superview ?: w.contentView, scale > 0 ? 1 / scale : 1, 0);
    rexui_log(
        [NSString stringWithFormat:@"rex: animation time scale %@", scale > 0 ? @(scale).stringValue : @"Rex's own"]);
    return now;
}

bool rex_method_ok(id method) {
    if (![method isKindOfClass:NSString.class] || ![method length] || [method length] > 128)
        return false;
    static NSCharacterSet* bad = [[NSCharacterSet
        characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"]
        invertedSet];
    return [method rangeOfCharacterFromSet:bad].location == NSNotFound && ![method hasPrefix:@"-"];
}

static RXPromise* api(id method, NSDictionary* args) {
    NSData* json = json_data(args ?: @{}, 0);
    NSString* arg = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    bool ok = rex_method_ok(method);
    return rx_promise(nil, ^id(NSString** error) {
        if (!ok) {
            *error = @"rex.api: a method is a name like session.list";
            return nil;
        }
        NSString* err = nil;
        NSData* out = rex_cli(@[@"api", @"call", method, arg ?: @"{}"], &err);
        if (!out) {
            *error = err ?: @"failed";
            return nil;
        }
        id reply = out.length
            ? [NSJSONSerialization JSONObjectWithData:out options:NSJSONReadingFragmentsAllowed error:nil]
            : nil;
        return reply ?: [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding] ?: NSNull.null;
    });
}

id rexstate_native(NSString* op, NSDictionary* a) {
    if ([op isEqualToString:@"modifiers"]) {
        NSEventModifierFlags f = NSEvent.modifierFlags;
        return @{
            @"cmd": @((f & NSEventModifierFlagCommand) != 0),
            @"shift": @((f & NSEventModifierFlagShift) != 0),
            @"alt": @((f & NSEventModifierFlagOption) != 0),
            @"ctrl": @((f & NSEventModifierFlagControl) != 0)
        };
    }
    if ([op isEqualToString:@"timeScale"])
        return @(set_time_scale(num_of(a[@"scale"])));
    if ([op isEqualToString:@"paneFullscreen"])
        return @(panes_set_full([a[@"block"] isKindOfClass:NSString.class] ? a[@"block"] : @"",
                                [a[@"on"] isKindOfClass:NSNumber.class] ? [a[@"on"] intValue] : -1));
    if ([op isEqualToString:@"keymap"])
        return (__bridge_transfer NSArray*)rex_keymap() ?: @[];
    if ([op isEqualToString:@"hosts"])
        return (__bridge_transfer NSArray*)rex_hosts() ?: @[];
    if ([op isEqualToString:@"themes"])
        return (__bridge_transfer NSDictionary*)rex_themes() ?: @{};
    if ([op isEqualToString:@"keyLayout"])
        return (__bridge_transfer NSDictionary*)rex_key_layout() ?: @{};
    if ([op isEqualToString:@"openDirectory"]) {
        NSMutableArray* paths = [NSMutableArray array];
        for (id p in [a[@"paths"] isKindOfClass:NSArray.class] ? a[@"paths"] : @[])
            if ([p isKindOfClass:NSString.class])
                [paths addObject:[p stringByExpandingTildeInPath]];
        return @(rex_open_directory((__bridge void*)paths));
    }
    if ([op isEqualToString:@"back"])
        return @(go_back());
    if ([op isEqualToString:@"findState"])
        return (__bridge_transfer NSDictionary*)rex_find_state() ?: NSNull.null;
    if ([op isEqualToString:@"api"])
        return api(a[@"method"], [a[@"args"] isKindOfClass:NSDictionary.class] ? a[@"args"] : @{});
    return nil;
}

void rexstate_init(void) {
}

void rexstate_docs_changed(void) {
    static NSTimer* t;
    bool want = false;
    for (RXDoc* d in g_docs)
        want |= (d.wants_hover || d.wants_hints) && d.ctx;
    if (want == (t != nil))
        return;
    if (!want) {
        [t invalidate];
        t = nil;
        return;
    }
    t = [NSTimer timerWithTimeInterval:0.2
                               repeats:YES
                                 block:^(NSTimer*) {
                                     pointer_tick();
                                 }];
    t.tolerance = 0.05;
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSRunLoopCommonModes];
}
