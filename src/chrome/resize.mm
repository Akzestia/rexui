// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <algorithm>

#include "chrome/chrome.h"
#include "rex/rex.h"

namespace {

constexpr CGFloat kGapMax = 24;
constexpr CGFloat kInside = 5;
constexpr CGFloat kMinPane = 80;
constexpr CGFloat kStart = 2;
constexpr double kSpan = 1.0 / 30;

enum class State { idle, pressed, dragging, holding, settling };

State g_state;
bool g_horizontal;
NSString *g_session, *g_before, *g_after;
__weak NSView* g_content;
NSPoint g_down;
CGFloat g_border, g_gap;
CGFloat g_lo, g_hi;
double g_ratio;
CGFloat g_at;
bool g_ready;
bool g_due;
int g_gen;
int g_puts;
NSMapTable<NSView*, NSValue*>* g_rects;
NSMapTable<NSView*, NSValue*>* g_targets;
NSMutableSet<NSView*>* g_low_side;

CGFloat along(NSRect r, bool max) {
    return g_horizontal ? (max ? NSMaxX(r) : NSMinX(r)) : (max ? NSMaxY(r) : NSMinY(r));
}
CGFloat along_p(NSPoint p) {
    return g_horizontal ? p.x : p.y;
}
NSRect in_window(NSView* v) {
    return [v convertRect:v.bounds toView:nil];
}

bool border_at(NSDictionary<NSString*, NSView*>* panes, NSPoint p) {
    for (NSString* a in panes) {
        NSRect ra = in_window(panes[a]);
        for (NSString* b in panes) {
            if (a == b)
                continue;
            NSRect rb = in_window(panes[b]);
            if (NSMaxX(ra) - kInside <= p.x && p.x <= NSMinX(rb) + kInside && NSMinX(rb) >= NSMaxX(ra)
                && NSMinX(rb) - NSMaxX(ra) <= kGapMax && p.y >= MAX(NSMinY(ra), NSMinY(rb))
                && p.y <= MIN(NSMaxY(ra), NSMaxY(rb))) {
                g_horizontal = true, g_before = a, g_after = b;
                g_border = (NSMaxX(ra) + NSMinX(rb)) / 2, g_gap = NSMinX(rb) - NSMaxX(ra);
                return true;
            }
            if (NSMaxY(rb) - kInside <= p.y && p.y <= NSMinY(ra) + kInside && NSMinY(ra) >= NSMaxY(rb)
                && NSMinY(ra) - NSMaxY(rb) <= kGapMax && p.x >= MAX(NSMinX(ra), NSMinX(rb))
                && p.x <= MIN(NSMaxX(ra), NSMaxX(rb))) {
                g_horizontal = false, g_before = a, g_after = b;
                g_border = (NSMinY(ra) + NSMaxY(rb)) / 2, g_gap = NSMinY(ra) - NSMaxY(rb);
                return true;
            }
        }
    }
    return false;
}

bool has(NSDictionary* n, NSString* bid) {
    if (![n isKindOfClass:NSDictionary.class])
        return false;
    if (n[@"block_id"])
        return [n[@"block_id"] isEqual:bid];
    NSDictionary* s = n[@"split"];
    return has(s[@"before"], bid) || has(s[@"after"], bid);
}

void leaves_of(NSDictionary* n, NSMutableArray<NSString*>* out) {
    if (![n isKindOfClass:NSDictionary.class])
        return;
    if (NSString* b = n[@"block_id"])
        return (void)[out addObject:b];
    leaves_of(n[@"split"][@"before"], out);
    leaves_of(n[@"split"][@"after"], out);
}

NSDictionary* split_between(NSDictionary* n, NSString* a, NSString* b) {
    NSDictionary* s = [n isKindOfClass:NSDictionary.class] ? n[@"split"] : nil;
    if (!s)
        return nil;
    if (has(s[@"before"], a) && has(s[@"after"], b))
        return s;
    return split_between(s[@"before"], a, b) ?: split_between(s[@"after"], a, b);
}

NSDictionary* tiled_with(id view, NSString* bid) {
    if (![view isKindOfClass:NSDictionary.class])
        return nil;
    for (NSDictionary* w in ((NSDictionary*)view)[@"windows"])
        for (NSDictionary* l in [w isKindOfClass:NSDictionary.class] ? w[@"layers"] : nil)
            if ([l isKindOfClass:NSDictionary.class] && [l[@"kind"] isEqual:@"tiled"] && has(l[@"layout"], bid))
                return l[@"layout"];
    return nil;
}

id call(NSString* session, NSString* method, NSDictionary* args) {
    NSString* json = [[NSString alloc] initWithData:json_data(args ?: @{}, NSJSONWritingSortedKeys)
                                           encoding:NSUTF8StringEncoding];
    NSString* error = nil;
    NSData* out = rex_cli(@[@"api", @"call", @"-s", session, method, json], &error);
    if (!out) {
        rexui_log([NSString
            stringWithFormat:@"pane resize: %@: %@", method,
                             [error stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]);
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:out options:0 error:nil] ?: @{};
}

dispatch_queue_t calls_queue(void) {
    static dispatch_queue_t q = dispatch_queue_create("rexui.resize", DISPATCH_QUEUE_SERIAL);
    return q;
}

NSDictionary* g_split;
NSMapTable<NSString*, NSView*>* g_leaf_views;

bool take(NSDictionary* split) {
    NSMutableArray<NSString*>*before = [NSMutableArray array], *after = [NSMutableArray array];
    leaves_of(split[@"before"], before);
    leaves_of(split[@"after"], after);
    NSArray* low = g_horizontal ? before : after;
    NSView* content = g_content;
    void* raw = content ? rex_panes((__bridge const void*)content) : nullptr;
    NSDictionary<NSString*, NSView*>* panes = raw ? (__bridge_transfer NSDictionary*)raw : nil;
    g_rects = [NSMapTable weakToStrongObjectsMapTable];
    g_targets = [NSMapTable weakToStrongObjectsMapTable];
    g_low_side = [NSMutableSet set];
    NSRect all = NSZeroRect;
    for (NSString* bid in [before arrayByAddingObjectsFromArray:after]) {
        NSView* v = panes[bid];
        if (!v.superview)
            continue;
        NSRect r = in_window(v);
        [g_rects setObject:[NSValue valueWithRect:r] forKey:v];
        if ([low containsObject:bid])
            [g_low_side addObject:v];
        all = NSIsEmptyRect(all) ? r : NSUnionRect(all, r);
    }
    if (NSIsEmptyRect(all) || !g_rects.count)
        return false;
    g_lo = along(all, false), g_hi = along(all, true);
    CGFloat c0 = g_horizontal ? NSMinY(all) : NSMinX(all), c1 = g_horizontal ? NSMaxY(all) : NSMaxX(all);
    NSMutableArray<NSView*>* lines = [NSMutableArray array];
    pane_lines(content, lines);
    for (NSView* l in lines) {
        if (!l.superview || l.hiddenOrHasHiddenAncestor)
            continue;
        NSRect r = in_window(l);
        CGFloat x0 = g_horizontal ? NSMinY(r) : NSMinX(r), x1 = g_horizontal ? NSMaxY(r) : NSMaxX(r);
        if (along(r, false) < g_lo - 1 || along(r, true) > g_hi + 1 || x0 < c0 - 1 || x1 > c1 + 1)
            continue;
        [g_rects setObject:[NSValue valueWithRect:r] forKey:l];
        if ((along(r, false) + along(r, true)) / 2 < g_border)
            [g_low_side addObject:l];
    }
    g_ratio = [split[@"ratio"] isKindOfClass:NSNumber.class] ? [split[@"ratio"] doubleValue] : 0.5;
    g_split = split;
    g_leaf_views = [NSMapTable strongToWeakObjectsMapTable];
    for (NSString* bid in [before arrayByAddingObjectsFromArray:after])
        if (NSView* v = panes[bid])
            [g_leaf_views setObject:v forKey:bid];
    return true;
}

bool touches(NSRect r, bool low) {
    CGFloat h = g_gap / 2, slack = h + 2;
    return low ? fabs(along(r, true) - (g_border - h)) <= slack : fabs(along(r, false) - (g_border + h)) <= slack;
}

CGFloat clamp_border(CGFloat at) {
    CGFloat h = g_gap / 2, lo = g_lo + kMinPane + h, hi = g_hi - kMinPane - h;
    for (NSView* v in g_rects.keyEnumerator.allObjects) {
        NSRect r = [g_rects objectForKey:v].rectValue;
        if (along(r, true) - along(r, false) < 4)
            continue;
        bool low = [g_low_side containsObject:v];
        if (!touches(r, low))
            continue;
        if (low)
            lo = MAX(lo, along(r, false) + kMinPane + h);
        else
            hi = MIN(hi, along(r, true) - kMinPane - h);
    }
    return lo < hi ? MAX(MIN(at, hi), lo) : g_border;
}

NSRect rect_for(NSView* v, CGFloat at) {
    NSRect r = [g_rects objectForKey:v].rectValue;
    bool low = [g_low_side containsObject:v];
    CGFloat a0 = along(r, false), a1 = along(r, true), n0 = a0, n1 = a1, h = g_gap / 2;
    if (a1 - a0 < 4) {
        CGFloat mid = (a0 + a1) / 2;
        if (fabs(mid - g_border) < MAX(g_gap, 2))
            n0 = at - (a1 - a0) / 2, n1 = at + (a1 - a0) / 2;
    } else if (touches(r, low)) {
        if (low)
            n1 = round(a1 + (at - g_border));
        else
            n0 = round(a0 + (at - g_border));
    }
    (void)h;
    return g_horizontal ? NSMakeRect(n0, NSMinY(r), n1 - n0, r.size.height)
                        : NSMakeRect(NSMinX(r), n0, r.size.width, n1 - n0);
}

void split_calls(NSDictionary* n, NSMutableArray<NSDictionary*>* out) {
    NSDictionary* s = [n isKindOfClass:NSDictionary.class] ? (n[@"split"] ?: (n[@"before"] ? n : nil)) : nil;
    if (!s)
        return;
    bool same = [s[@"direction"] isEqual:(g_horizontal ? @"horizontal" : @"vertical")];
    NSMutableArray<NSString*>*b = [NSMutableArray array], *a = [NSMutableArray array];
    leaves_of(s[@"before"], b);
    leaves_of(s[@"after"], a);
    if (same && b.count && a.count) {
        NSArray *lowb = g_horizontal ? b : a, *highb = g_horizontal ? a : b;
        auto extent = [&](NSArray<NSString*>* ids, bool now, CGFloat* lo, CGFloat* hi) {
            *lo = INFINITY, *hi = -INFINITY;
            for (NSString* bid in ids) {
                NSView* v = [g_leaf_views objectForKey:bid];
                NSValue* was = v ? [g_rects objectForKey:v] : nil;
                if (!was)
                    continue;
                NSRect r = now ? rect_for(v, g_at) : was.rectValue;
                *lo = MIN(*lo, along(r, false)), *hi = MAX(*hi, along(r, true));
            }
        };
        CGFloat l0, l1, h0, h1, nl0, nl1, nh0, nh1;
        extent(lowb, false, &l0, &l1), extent(highb, false, &h0, &h1);
        extent(lowb, true, &nl0, &nl1), extent(highb, true, &nh0, &nh1);
        if (isfinite(l0) && isfinite(h1) && isfinite(nl0) && isfinite(nh1)) {
            double f0 = ((l1 + h0) / 2 - l0) / MAX(1.0, h1 - l0), f1 = ((nl1 + nh0) / 2 - nl0) / MAX(1.0, nh1 - nl0);
            double r0 = [s[@"ratio"] isKindOfClass:NSNumber.class] ? [s[@"ratio"] doubleValue] : 0.5;
            double r1 = MAX(0.02, MIN(0.98, g_horizontal ? r0 + (f1 - f0) : r0 - (f1 - f0)));
            if (fabs(r1 - r0) > 1e-4)
                [out addObject:@{
                    @"session_id": g_session,
                    @"direction": s[@"direction"],
                    @"before_block_id": b.firstObject,
                    @"after_block_id": a.firstObject,
                    @"ratio": @(r1)
                }];
        }
    }
    split_calls(s[@"before"], out);
    split_calls(s[@"after"], out);
}

bool is_line(NSView* v) {
    NSRect r = [g_rects objectForKey:v].rectValue;
    return along(r, true) - along(r, false) < 4;
}

void move_lines(CGFloat at) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSView* v in g_rects.keyEnumerator.allObjects) {
        if (!is_line(v) || !v.layer)
            continue;
        NSRect now = in_window(v), want = rect_for(v, at);
        CGFloat d = along(want, false) - along(now, false);
        bool flip = v.superview.isFlipped;
        v.layer.transform =
            g_horizontal ? CATransform3DMakeTranslation(d, 0, 0) : CATransform3DMakeTranslation(0, flip ? -d : d, 0);
    }
    [CATransaction commit];
}

void put(CGFloat at) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSView* v in g_rects.keyEnumerator.allObjects) {
        NSRect f = [v.superview convertRect:rect_for(v, at) fromView:nil];
        [g_targets setObject:[NSValue valueWithRect:f] forKey:v];
        if (is_line(v))
            v.layer.transform = CATransform3DIdentity;
        if (!NSEqualRects(v.frame, f))
            v.frame = f;
        if (!is_line(v))
            panes_pane_framed(v);
    }
    [CATransaction commit];
    term_live_frame();
    g_puts++;
}

CFRunLoopObserverRef g_turns;
CFTimeInterval g_sleep_at, g_put_at;
double g_idle;
bool g_want;
double g_costs[512];
int g_ncosts;

void put_now(void) {
    if (!g_want || !g_ready || g_state != State::dragging)
        return;
    g_want = false;
    CFTimeInterval now = CACurrentMediaTime();
    if (g_put_at > 0 && g_ncosts < 512)
        g_costs[g_ncosts++] = MAX(0.0, now - g_put_at - g_idle) * 1000;
    put(g_at);
    g_put_at = now;
    g_idle = 0;
}

void watch_turns(bool on) {
    if (!on) {
        if (g_turns)
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), g_turns, kCFRunLoopCommonModes), CFRelease(g_turns);
        g_turns = nullptr;
        return;
    }
    if (g_turns)
        return;
    g_sleep_at = 0;
    g_turns = CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting, true,
                                                 INT_MAX, ^(CFRunLoopObserverRef, CFRunLoopActivity a) {
                                                     CFTimeInterval now = CACurrentMediaTime();
                                                     if (a == kCFRunLoopAfterWaiting) {
                                                         if (g_sleep_at > 0)
                                                             g_idle += now - g_sleep_at;
                                                         g_sleep_at = 0;
                                                         return;
                                                     }
                                                     g_sleep_at = now;
                                                     double since = now - g_put_at, busy = since - g_idle;
                                                     if (g_want && since >= kSpan && busy <= g_idle)
                                                         dispatch_async(dispatch_get_main_queue(), ^{
                                                             put_now();
                                                         });
                                                 });
    CFRunLoopAddObserver(CFRunLoopGetMain(), g_turns, kCFRunLoopCommonModes);
}

void put_soon(void) {
    g_want = true;
    if (g_put_at == 0)
        put_now();
}

static bool g_quiet;
static void (*orig_metrics)(id, SEL);
static void hook_metrics(id self, SEL sel) {
    if (g_quiet)
        return;
    orig_metrics(self, sel);
}

static void quiet_host_above(NSView* pane) {
    static Class hooked;
    static NSString* host = @"AppKitPlatformViewHost";
    for (NSView* v = pane.superview; v; v = v.superview) {
        Class c = v.class;
        if (![NSStringFromClass(c) containsString:host])
            continue;
        if (hooked)
            return;
        SEL sel = NSSelectorFromString(@"_layoutMetricsInvalidatedForHostedView");
        if (!class_getInstanceMethod(c, sel))
            return;
        swizzle(c, sel, (IMP)hook_metrics, (IMP*)&orig_metrics);
        hooked = c;
        rexui_log_file([NSString stringWithFormat:@"pane resize: %@ quiet while dragging", NSStringFromClass(c)]);
        return;
    }
}

void filter_on(void) {
    motion_frame_filter(^NSRect(NSView* v, NSRect asked) {
        NSValue* t = [g_targets objectForKey:v];
        if (!t)
            return asked;
        NSRect r = t.rectValue;
        if (g_state == State::settling && fabs(NSMinX(asked) - NSMinX(r)) < 3 && fabs(NSMinY(asked) - NSMinY(r)) < 3
            && fabs(asked.size.width - r.size.width) < 3 && fabs(asked.size.height - r.size.height) < 3) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (g_state == State::settling)
                    g_state = State::idle, g_quiet = false, g_panes_instant = false, motion_frame_filter(nil),
                    term_live_end(0.2);
            });
            return asked;
        }
        return r;
    });
}

void end_now(void) {
    term_live_end(0.2);
    watch_turns(false);
    g_panes_instant = false;
    g_gen++;
    g_state = State::idle;
    g_quiet = false;
    motion_frame_filter(nil);
}

constexpr double kPause = 0.4;
constexpr double kPauseMax = 2.0;
NSArray<NSDictionary*>* g_pending;
CFTimeInterval g_released_at, g_input_at;

void tell_now(void) {
    NSArray<NSDictionary*>* calls = g_pending;
    g_pending = nil;
    if (g_state != State::holding)
        return;
    if (!calls.count)
        return end_now();
    g_state = State::settling;
    g_quiet = false;
    int gen = g_gen;
    dispatch_async(calls_queue(), ^{
        for (NSDictionary* args in calls)
            call(args[@"session_id"], @"session.resize_pane", args);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == g_gen && g_state == State::settling)
            end_now();
    });
}

void tell_when_still(int gen) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen != g_gen || g_state != State::holding)
            return;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - g_input_at >= kPause || now - g_released_at >= kPauseMax)
            tell_now();
        else
            tell_when_still(gen);
    });
}

}

void pane_lines(NSView* v, NSMutableArray<NSView*>* out) {
    static NSString* line = RXNS(RXN_183);
    for (NSView* s in v.subviews) {
        if ([NSStringFromClass(s.class) containsString:line])
            [out addObject:s];
        else
            pane_lines(s, out);
    }
}

bool pane_resize_event(NSEvent* e) {
    if (!g_config.pane_resize)
        return false;
    NSEventType t = e.type;
    if (t != NSEventTypeAppKitDefined && t != NSEventTypeSystemDefined && t != NSEventTypeApplicationDefined
        && t != NSEventTypePeriodic)
        g_input_at = CACurrentMediaTime();
    if (g_state == State::holding && t != NSEventTypeMouseMoved)
        tell_now();
    if (g_state == State::holding)
        return false;
    if (g_state == State::idle || g_state == State::settling) {
        if (t != NSEventTypeLeftMouseDown || e.clickCount != 1
            || (e.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask & ~NSEventModifierFlagCapsLock))
            return false;
        NSWindow* w = e.window;
        if (!is_rex_window(w))
            return false;
        NSView *chrome = chrome_of(w), *content = chrome ? chrome_content(chrome) : nil;
        if (!content || !NSPointInRect([content convertPoint:e.locationInWindow fromView:nil], content.bounds))
            return false;
        if (ui_top_at(w, e.locationInWindow))
            return false;
        void* raw = rex_panes((__bridge const void*)content);
        NSDictionary<NSString*, NSView*>* panes = raw ? (__bridge_transfer NSDictionary*)raw : nil;
        if (panes.count < 2 || !border_at(panes, e.locationInWindow))
            return false;
        NSString* session = current_session_id();
        if (!session.length)
            return false;
        if (g_state == State::settling)
            end_now();
        g_state = State::pressed;
        g_panes_instant = true;
        g_gen++;
        g_ready = g_due = false;
        g_puts = 0;
        g_put_at = 0;
        g_idle = 0;
        g_want = false;
        g_ncosts = 0;
        watch_turns(true);
        g_content = content;
        g_session = session;
        g_down = e.locationInWindow;
        g_at = g_border;
        g_rects = g_targets = nil;
        use_cursor(g_horizontal ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor);
        rexui_log_file([NSString stringWithFormat:@"pane resize: press between %@ and %@ (%@)",
                                                  [g_before substringFromIndex:MAX(6, g_before.length) - 6],
                                                  [g_after substringFromIndex:MAX(6, g_after.length) - 6],
                                                  g_horizontal ? @"left|right" : @"above/below"]);
        int gen = g_gen;
        NSString *a = g_before, *b = g_after;
        dispatch_async(calls_queue(), ^{
            NSDictionary* split = split_between(tiled_with(call(session, @"session.view", nil), a), a, b);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != g_gen)
                    return;
                if (!split) {
                    rexui_log(@"pane resize: no split between them in session.view");
                    return;
                }
                g_ready = take(split);
                if (!g_ready)
                    return;
                term_live_begin(g_session, g_leaf_views);
                for (NSView* v in g_rects.keyEnumerator.allObjects) {
                    quiet_host_above(v);
                    break;
                }
                g_quiet = true;
                filter_on();
                if (g_state == State::dragging)
                    put(g_at = clamp_border(g_at));
            });
        });
        return true;
    }
    if (t == NSEventTypeKeyDown && e.keyCode == 53) {
        if (g_ready)
            put(g_border);
        end_now();
        return true;
    }
    if (t == NSEventTypeLeftMouseDragged) {
        CGFloat moved = along_p(e.locationInWindow) - along_p(g_down);
        if (g_state == State::pressed && fabs(moved) < kStart)
            return true;
        g_state = State::dragging;
        g_at = g_border + moved;
        if (!g_ready)
            return true;
        g_at = clamp_border(g_at);
        move_lines(g_at);
        put_soon();
        return true;
    }
    if (t == NSEventTypeLeftMouseUp) {
        bool dragged = g_state == State::dragging;
        if (!dragged || !g_ready || fabs(g_at - g_border) < 0.5) {
            end_now();
            return true;
        }
        put(g_at);
        NSMutableArray<NSDictionary*>* calls = [NSMutableArray array];
        split_calls(g_split, calls);
        double ratio = calls.count ? [calls.firstObject[@"ratio"] doubleValue] : g_ratio;
        std::sort(g_costs, g_costs + g_ncosts);
        auto at = [](double q) { return g_ncosts ? g_costs[std::min(g_ncosts - 1, (int)(q * g_ncosts))] : 0.0; };
        rexui_log_file([NSString
            stringWithFormat:
                @"pane resize: %d puts, ratio %.3f -> %.3f; main busy between puts %.1f ms median, %.1f p90, %.1f max",
                g_puts, g_ratio, ratio, at(0.5), at(0.9), g_ncosts ? g_costs[g_ncosts - 1] : 0.0]);
        g_state = State::holding;
        watch_turns(false);
        g_pending = calls;
        g_released_at = CACurrentMediaTime();
        tell_when_still(g_gen);
        return true;
    }
    return t == NSEventTypeLeftMouseDown || t == NSEventTypeMouseMoved;
}
