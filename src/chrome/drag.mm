// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "chrome/chrome.h"
#include "rex/rex.h"

@interface RXPaneDragLayer : CALayer
@end
@implementation RXPaneDragLayer
- (id<CAAction>)actionForKey:(NSString*)key {
    return (id<CAAction>)NSNull.null;
}
@end

bool pane_drag_owns(CALayer* layer) {
    for (CALayer* l = layer; l; l = l.superlayer) {
        if ([l isKindOfClass:RXPaneDragLayer.class])
            return true;
    }
    return false;
}

namespace {

enum class State { idle, pressed, dragging, cancelled };
enum class Zone { none, left, right, top, bottom, center };

constexpr double kSpatial[4] = {0.38, 1.21, 0.22, 1.0};
constexpr CGFloat kStart = 6;
constexpr double kIndicatorMs = 120;

State g_state;
bool g_broken;
bool g_dropping;
int g_drag;
NSEvent* g_down;
NSPoint g_down_at, g_last_at;
__weak NSWindow* g_window;
__weak NSView *g_chrome, *g_content;
NSDictionary<NSString*, NSView*>* g_panes;
NSString* g_id;
NSString* g_session;
__weak NSView* g_pane;
__weak NSView* g_carrier;
CGPoint g_uv;
bool g_floated;
bool g_from_floating;
NSDictionary* g_layout;
NSString* g_focused;
NSString* g_target;
Zone g_zone = Zone::none;
RXPaneDragLayer* g_overlay;
__weak NSView* g_overlay_chrome;
RXPaneDragLayer* g_indicator;
bool g_shown;
dispatch_queue_t g_calls = dispatch_queue_create("rexui.pane-drag", DISPATCH_QUEUE_SERIAL);

struct Saved {
    CATransform3D transform;
    CGFloat z;
    float shadow_opacity;
    CGFloat shadow_radius;
    CGSize shadow_offset;
    id shadow_color;
    id shadow_path;
};
Saved g_saved;
__weak CALayer* g_lifted;

NSString* zone_label(Zone z) {
    switch (z) {
    case Zone::left:
        return @"left";
    case Zone::right:
        return @"right";
    case Zone::top:
        return @"top";
    case Zone::bottom:
        return @"bottom";
    case Zone::center:
        return @"center";
    case Zone::none:
        return @"none";
    }
    return @"none";
}

CAMediaTimingFunction* curve(const double c[4]) {
    return [CAMediaTimingFunction functionWithControlPoints:c[0]:c[1]:c[2]:c[3]];
}

bool shown(NSView* v) {
    NSRect b = v.bounds;
    return v.window && !v.hiddenOrHasHiddenAncestor && v.alphaValue > 0.01 && v.layer.opacity > 0.01 && b.size.width > 1
        && b.size.height > 1;
}

NSRect rect_of(NSView* v, NSView* chrome) {
    return [v convertRect:v.bounds toView:chrome];
}

bool tiled(NSDictionary<NSString*, NSView*>* panes, NSView* chrome) {
    NSMutableArray<NSValue*>* rects = [NSMutableArray array];
    for (NSView* v in panes.allValues) {
        if (shown(v))
            [rects addObject:[NSValue valueWithRect:rect_of(v, chrome)]];
    }
    if (rects.count < 2)
        return false;
    for (NSUInteger i = 0; i < rects.count; i++) {
        for (NSUInteger j = i + 1; j < rects.count; j++) {
            NSRect a = NSInsetRect(rects[i].rectValue, 2, 2), b = NSInsetRect(rects[j].rectValue, 2, 2);
            if (NSIntersectsRect(a, b))
                return false;
        }
    }
    return true;
}

NSWindow* rex_window(void) {
    for (NSWindow* w in NSApp.orderedWindows) {
        if (w.isVisible && is_rex_window(w) && chrome_of(w))
            return w;
    }
    return nil;
}

NSDictionary<NSString*, NSView*>* read_panes(NSView* content) {
    void* raw = content ? rex_panes((__bridge const void*)content) : nullptr;
    if (!raw)
        return nil;
    return (__bridge_transfer NSDictionary*)raw;
}

id api(NSString* session, NSString* method, NSDictionary* args) {
    NSString* json = [[NSString alloc] initWithData:json_data(args ?: @{}, NSJSONWritingSortedKeys)
                                           encoding:NSUTF8StringEncoding];
    NSString* error = nil;
    NSData* out = rex_cli(@[@"api", @"call", @"-s", session, method, json], &error);
    if (!out) {
        rexui_log([NSString
            stringWithFormat:@"pane drag: %@ %@: %@", method, json,
                             [error stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]);
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:out options:0 error:nil] ?: @{};
}

bool has_block(NSDictionary* n, NSString* bid) {
    if (![n isKindOfClass:NSDictionary.class])
        return false;
    if (n[@"block_id"])
        return [n[@"block_id"] isEqual:bid];
    NSDictionary* s = n[@"split"];
    return has_block(s[@"before"], bid) || has_block(s[@"after"], bid);
}

NSString* first_leaf(NSDictionary* n) {
    if (![n isKindOfClass:NSDictionary.class])
        return nil;
    return n[@"block_id"] ?: first_leaf(n[@"split"][@"before"]);
}

void leaves(NSDictionary* n, NSMutableArray<NSString*>* out) {
    if (![n isKindOfClass:NSDictionary.class])
        return;
    if (NSString* b = n[@"block_id"])
        return (void)[out addObject:b];
    leaves(n[@"split"][@"before"], out);
    leaves(n[@"split"][@"after"], out);
}

NSDictionary* parent_of(NSDictionary* n, NSString* bid) {
    NSDictionary* s = [n isKindOfClass:NSDictionary.class] ? n[@"split"] : nil;
    if (!s)
        return nil;
    if ([s[@"before"][@"block_id"] isEqual:bid] || [s[@"after"][@"block_id"] isEqual:bid])
        return n;
    return parent_of(s[@"before"], bid) ?: parent_of(s[@"after"], bid);
}

void place(NSDictionary* n, NSString* r, NSMutableArray<NSArray*>* calls) {
    NSDictionary* s = n[@"split"];
    if (!s)
        return;
    bool in_before = has_block(s[@"before"], r);
    NSDictionary* other = in_before ? s[@"after"] : s[@"before"];
    NSString* o = first_leaf(other);
    if (!o)
        return;
    NSMutableDictionary* args = [@{
        @"block_id": o,
        @"anchor_block_id": r,
        @"direction": s[@"direction"] ?: @"horizontal",
        @"side": in_before ? @"after" : @"before"
    } mutableCopy];
    if ([s[@"ratio"] isKindOfClass:NSNumber.class] && [s[@"ratio"] doubleValue] > 0 && [s[@"ratio"] doubleValue] < 1)
        args[@"ratio"] = s[@"ratio"];
    [calls addObject:@[@"session.move_block", args]];
    place(in_before ? s[@"before"] : s[@"after"], r, calls);
    place(other, o, calls);
}

NSDictionary* tiled_layout(NSDictionary* view, NSString* bid, NSString** focused) {
    if (![view isKindOfClass:NSDictionary.class])
        return nil;
    for (NSDictionary* w in view[@"windows"]) {
        for (NSDictionary* l in [w isKindOfClass:NSDictionary.class] ? w[@"layers"] : nil) {
            if (![l isKindOfClass:NSDictionary.class] || ![l[@"kind"] isEqual:@"tiled"]
                || !has_block(l[@"layout"], bid))
                continue;
            *focused = w[@"focused_block_id"];
            return l[@"layout"];
        }
    }
    return nil;
}

NSArray* rect_in(NSDictionary* n, NSString* bid) {
    if (![n isKindOfClass:NSDictionary.class])
        return nil;
    if ([n[@"block_id"] isEqual:bid])
        return n[@"rect"];
    NSDictionary* s = n[@"split"];
    return rect_in(s[@"before"], bid) ?: rect_in(s[@"after"], bid);
}

void put_back(CALayer* l, const Saved& s) {
    l.transform = s.transform;
    l.zPosition = s.z;
    l.shadowOpacity = s.shadow_opacity;
    l.shadowRadius = s.shadow_radius;
    l.shadowOffset = s.shadow_offset;
    l.shadowColor = (__bridge CGColorRef)s.shadow_color;
    l.shadowPath = (__bridge CGPathRef)s.shadow_path;
}

CGFloat radius_of(NSView* v);

NSMapTable<CALayer*, NSNumber*>* g_hidden;
CALayer* g_dress;
CGRect g_card;

void find_backdrops(NSView* v, NSMutableArray<NSView*>* out, int depth) {
    for (NSView* s in v.subviews) {
        if ([NSStringFromClass(s.class) containsString:RXNS(RXN_192)])
            [out addObject:s];
        else if (depth < 10)
            find_backdrops(s, out, depth + 1);
    }
}

void undress(void) {
    for (CALayer* l in g_hidden.keyEnumerator.allObjects)
        l.opacity = [g_hidden objectForKey:l].floatValue;
    g_hidden = nil;
    [g_dress removeFromSuperlayer];
    g_dress = nil;
}

void dress(NSView* carrier) {
    undress();
    NSMutableArray<NSView*>* backdrops = [NSMutableArray array];
    find_backdrops(carrier, backdrops, 0);
    static bool told;
    if (!backdrops.count && !told)
        rexui_log(@"pane drag: no FloatingPaneBackdrop view in the floating pane (a Rex update?)");
    told = told || !backdrops.count;
    g_hidden = [NSMapTable weakToStrongObjectsMapTable];
    for (NSView* v in backdrops) {
        if (!v.layer)
            continue;
        [g_hidden setObject:@(v.layer.opacity) forKey:v.layer];
        v.layer.opacity = 0;
    }
    CALayer* d = [RXPaneDragLayer layer];
    d.frame = g_card;
    d.cornerRadius = radius_of(g_pane);
    d.masksToBounds = YES;
    Class backdrop = NSClassFromString(@"CABackdropLayer"), filter = NSClassFromString(@"CAFilter");
    if (backdrop && filter && [filter respondsToSelector:@selector(filterWithType:)]) {
        CALayer* blur = [backdrop new];
        blur.frame = d.bounds;
        id f = ((id(*)(id, SEL, NSString*))objc_msgSend)(filter, @selector(filterWithType:), @"gaussianBlur");
        [f setValue:@24 forKey:@"inputRadius"];
        blur.filters = @[f];
        [d addSublayer:blur];
    }
    double rgb[3] = {0, 0, 0};
    chrome_theme(rgb);
    CALayer* tint = [RXPaneDragLayer layer];
    tint.frame = d.bounds;
    tint.backgroundColor = [NSColor colorWithSRGBRed:rgb[0]
                                               green:rgb[1]
                                                blue:rgb[2]
                                               alpha:g_config.transparency ? 0.5 * g_config.opacity : 1]
                               .CGColor;
    [d addSublayer:tint];
    [carrier.layer insertSublayer:d atIndex:0];
    g_dress = d;
}

void carry(NSView* carrier, NSView* pane) {
    if (CALayer* old = g_lifted) {
        if (old.superlayer)
            put_back(old, g_saved);
        g_lifted = nil;
    }
    undress();
    g_pane = pane;
    g_carrier = carrier;
    CALayer *l = carrier.layer, *pl = pane.layer;
    if (!l || !pl.superlayer)
        return;
    g_card = pl == l ? l.bounds : [pl.superlayer convertRect:pl.frame toLayer:l];
    if (carrier != pane)
        dress(carrier);
}

bool adopt_floating(void) {
    NSView* content = g_content;
    const void *pane = nullptr, *layer = nullptr;
    if (!content || !rex_floating_pane((__bridge const void*)content, g_id.UTF8String, &pane, &layer))
        return false;
    carry((__bridge NSView*)layer, (__bridge NSView*)pane);
    g_panes = read_panes(content) ?: g_panes;
    return true;
}

void lift(NSPoint at) {
    NSView *pane = g_pane, *carrier = g_carrier ?: pane, *chrome = g_chrome;
    CALayer *l = carrier.layer, *pl = pane.layer;
    if (!l.superlayer || !pl.superlayer || !chrome || !carrier.window)
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (g_lifted != l) {
        g_lifted = l;
        if (![l animationForKey:@"rexui.drag.back"])
            g_saved = {l.transform,
                       l.zPosition,
                       l.shadowOpacity,
                       l.shadowRadius,
                       l.shadowOffset,
                       (__bridge id)l.shadowColor,
                       (__bridge id)l.shadowPath};
        l.zPosition = 1000;
        CGPathRef path = CGPathCreateWithRoundedRect(g_card, radius_of(pane), radius_of(pane), nullptr);
        l.shadowPath = path;
        CGPathRelease(path);
        l.shadowColor = NSColor.blackColor.CGColor;
        l.shadowOpacity = 0.25;
        l.shadowRadius = 16;
        l.shadowOffset = CGSizeZero;
    }
    l.transform = CATransform3DIdentity;
    CGRect b = pl.bounds;
    CGPoint g = [pl convertPoint:CGPointMake(b.origin.x + g_uv.x * b.size.width, b.origin.y + g_uv.y * b.size.height)
                         toLayer:l.superlayer];
    CGPoint p = [chrome.layer convertPoint:[chrome convertPoint:at fromView:nil] toLayer:l.superlayer];
    const CGFloat px = carrier.window.backingScaleFactor ?: 1;
    l.transform = CATransform3DMakeTranslation(round((p.x - g.x) * px) / px, round((p.y - g.y) * px) / px, 0);
    [CATransaction commit];
}

void unlift_now(void) {
    CALayer* l = g_lifted;
    g_lifted = nil;
    undress();
    if (l)
        put_back(l, g_saved);
}

void unlift_back(void) {
    CALayer* l = g_lifted;
    g_lifted = nil;
    undress();
    if (!l)
        return;
    CATransform3D from = ((CALayer*)l.presentationLayer ?: l).transform;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    Saved s = g_saved;
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"transform"];
    a.fromValue = [NSValue valueWithCATransform3D:from];
    a.toValue = [NSValue valueWithCATransform3D:s.transform];
    a.duration = (g_config.pane_glide ? g_config.pane_glide_ms : 200) / 1000;
    a.timingFunction = curve(g_config.pane_glide_curve);
    [CATransaction setCompletionBlock:^{
        if (g_lifted == l)
            return;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        put_back(l, s);
        [CATransaction commit];
    }];
    l.transform = s.transform;
    [l addAnimation:a forKey:@"rexui.drag.back"];
    [CATransaction commit];
}

CGRect in_air(void) {
    NSView *pane = g_pane, *chrome = g_chrome;
    if (!pane.layer.superlayer || !chrome.layer)
        return CGRectNull;
    return [pane.layer convertRect:pane.layer.bounds toLayer:chrome.layer];
}

CGFloat radius_of(NSView* v) {
    CGFloat r = v.layer.cornerRadius;
    for (CALayer* s in v.layer.sublayers)
        r = MAX(r, s.cornerRadius);
    return r > 0 ? r : 10;
}

void ensure_overlay(NSView* chrome) {
    if (!g_overlay) {
        g_overlay = [RXPaneDragLayer layer];
        g_indicator = [RXPaneDragLayer layer];
        g_indicator.opacity = 0;
        g_indicator.borderWidth = 2;
        [g_overlay addSublayer:g_indicator];
    }
    CALayer* top = chrome.layer;
    if (!top)
        return;
    NSView* cover = ui_loading_cover(chrome);
    g_overlay_chrome = chrome;
    g_overlay.geometryFlipped = !chrome.isFlipped;
    if (!CGRectEqualToRect(g_overlay.frame, top.bounds))
        g_overlay.frame = top.bounds;
    g_overlay.zPosition = cover ? 0 : 900;
    if (g_overlay.superlayer != top) {
        if (cover.layer.superlayer == top)
            [top insertSublayer:g_overlay below:cover.layer];
        else
            [top addSublayer:g_overlay];
    }
}

static NSRect to_overlay(NSRect win) {
    NSView* chrome = g_overlay_chrome;
    if (!chrome)
        return NSZeroRect;
    NSRect r = [chrome convertRect:win fromView:nil];
    if (!chrome.isFlipped)
        r.origin.y = chrome.bounds.size.height - NSMaxY(r);
    return r;
}
static NSRect from_overlay(NSRect r) {
    NSView* chrome = g_overlay_chrome;
    if (!chrome)
        return NSZeroRect;
    if (!chrome.isFlipped)
        r.origin.y = chrome.bounds.size.height - NSMaxY(r);
    return [chrome convertRect:r toView:nil];
}

static NSColor* accent_colour(void) {
    NSColor* c = ui_accent() ?: NSColor.controlAccentColor;
    return [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace] ?: NSColor.systemBlueColor;
}

void colour_indicator(void) {
    NSColor* c = accent_colour();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g_indicator.backgroundColor = [c colorWithAlphaComponent:0.22].CGColor;
    g_indicator.borderColor = [c colorWithAlphaComponent:0.9].CGColor;
    [CATransaction commit];
}

void fade_indicator(float to) {
    float from = ((CALayer*)g_indicator.presentationLayer ?: g_indicator).opacity;
    g_indicator.opacity = to;
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @(from);
    a.toValue = @(to);
    a.duration = kIndicatorMs / 1000;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [g_indicator addAnimation:a forKey:@"rexui.opacity"];
}

void hide_indicator(void) {
    if (!g_shown || !g_indicator)
        return;
    g_shown = false;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    fade_indicator(0);
    [CATransaction commit];
}

void show_indicator(NSView* target, Zone z, bool glide) {
    NSView* chrome = g_chrome;
    if (!target || z == Zone::none || !chrome)
        return hide_indicator();
    NSRect r = to_overlay([target convertRect:target.bounds toView:nil]);
    switch (z) {
    case Zone::left:
        r.size.width /= 2;
        break;
    case Zone::right:
        r.origin.x += r.size.width / 2, r.size.width /= 2;
        break;
    case Zone::top:
        r.size.height /= 2;
        break;
    case Zone::bottom:
        r.origin.y += r.size.height / 2, r.size.height /= 2;
        break;
    default:
        break;
    }
    r = NSInsetRect(r, 4, 4);
    if (g_shown && !glide && CGRectEqualToRect(r, g_indicator.frame))
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    g_indicator.cornerRadius = MAX(0, radius_of(target) - 4);
    CALayer* now = g_indicator.presentationLayer ?: g_indicator;
    CGPoint from_pos = now.position;
    CGRect from_bounds = now.bounds;
    bool was = g_shown;
    g_indicator.frame = r;
    if (!was) {
        g_shown = true;
        [g_indicator removeAnimationForKey:@"rexui.position"];
        [g_indicator removeAnimationForKey:@"rexui.bounds"];
        fade_indicator(1);
    } else if (glide) {
        for (NSString* key in @[@"position", @"bounds"]) {
            id from = [key isEqualToString:@"position"] ? [NSValue valueWithPoint:from_pos]
                                                        : [NSValue valueWithRect:from_bounds];
            id to = [key isEqualToString:@"position"] ? [NSValue valueWithPoint:g_indicator.position]
                                                      : [NSValue valueWithRect:g_indicator.bounds];
            if ([from isEqual:to])
                continue;
            CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:key];
            a.fromValue = from;
            a.toValue = to;
            a.duration = kIndicatorMs / 1000;
            a.timingFunction = curve(kSpatial);
            [g_indicator addAnimation:a forKey:[@"rexui." stringByAppendingString:key]];
        }
    }
    [CATransaction commit];
}

Zone zone_at(NSPoint at, NSString** target, bool center = false) {
    NSView* chrome = g_chrome;
    *target = nil;
    if (!chrome)
        return Zone::none;
    NSPoint p = [chrome convertPoint:at fromView:nil];
    for (NSString* bid in g_panes) {
        NSView* v = g_panes[bid];
        if ([bid isEqualToString:g_id] || !shown(v))
            continue;
        NSRect r = rect_of(v, chrome);
        if (!NSPointInRect(p, r))
            continue;
        *target = bid;
        CGFloat u = (p.x - r.origin.x) / r.size.width, w = (p.y - r.origin.y) / r.size.height;
        CGFloat d = MIN(MIN(u, 1 - u), MIN(w, 1 - w));
        if (center && d > 0.25)
            return Zone::center;
        if (d == u)
            return Zone::left;
        if (d == 1 - u)
            return Zone::right;
        if (d == w)
            return Zone::top;
        return Zone::bottom;
    }
    return Zone::none;
}

bool no_op(NSRect a, NSRect b, Zone z) {
    constexpr CGFloat tol = 2, gap = 24;
    auto same_rows = [&] { return fabs(NSMinY(a) - NSMinY(b)) < tol && fabs(a.size.height - b.size.height) < tol; };
    auto same_cols = [&] { return fabs(NSMinX(a) - NSMinX(b)) < tol && fabs(a.size.width - b.size.width) < tol; };
    switch (z) {
    case Zone::left:
        return NSMaxX(a) <= NSMinX(b) + tol && NSMinX(b) - NSMaxX(a) < gap && same_rows();
    case Zone::right:
        return NSMaxX(b) <= NSMinX(a) + tol && NSMinX(a) - NSMaxX(b) < gap && same_rows();
    case Zone::top:
        return NSMaxY(a) <= NSMinY(b) + tol && NSMinY(b) - NSMaxY(a) < gap && same_cols();
    case Zone::bottom:
        return NSMaxY(b) <= NSMinY(a) + tol && NSMinY(a) - NSMaxY(b) < gap && same_cols();
    default:
        return false;
    }
}

void aim(NSPoint at) {
    NSString* target = nil;
    Zone z = zone_at(at, &target);
    bool same = z == g_zone && [target isEqual:g_target];
    g_zone = z;
    g_target = target;
    show_indicator(target ? g_panes[target] : nil, z, !same);
}

bool g_carried_floating;
bool g_transferring;
NSArray* g_float_bounds;

void transfer(void) {
    g_transferring = true;
    NSString *session = g_session, *bid = g_id;
    NSArray* bounds = g_float_bounds ?: @[@0.25, @0.25, @0.5, @0.5];
    int drag = g_drag;
    dispatch_async(g_calls, ^{
        NSDictionary* view = api(session, @"session.view", nil);
        NSDictionary* shown = nil;
        for (NSDictionary* w in [view isKindOfClass:NSDictionary.class] ? view[@"windows"] : nil) {
            if ([w isKindOfClass:NSDictionary.class] && [w[@"window_id"] isEqual:view[@"active_window_id"]])
                shown = w;
        }
        NSDictionary* layout = nil;
        bool here = false;
        for (NSDictionary* l in shown[@"layers"]) {
            if (![l isKindOfClass:NSDictionary.class])
                continue;
            here = here || has_block(l[@"layout"], bid);
            if ([l[@"kind"] isEqual:@"tiled"])
                layout = l[@"layout"];
        }
        NSString* anchor = first_leaf(layout);
        if (!here && anchor && api(session, @"session.move_block", @{@"block_id": bid, @"anchor_block_id": anchor}))
            api(session, @"session.float_block", @{@"block_id": bid, @"bounds": bounds});
        dispatch_async(dispatch_get_main_queue(), ^{
            if (drag == g_drag)
                g_transferring = false;
        });
    });
}

void check_tab(void) {
    for (NSView* v in g_panes.allValues) {
        if (v.window)
            return;
    }
    NSDictionary<NSString*, NSView*>* now = read_panes(g_content);
    if (!now.count)
        return;
    bool other_tab = ![now.allKeys firstObjectCommonWithArray:g_panes.allKeys];
    g_panes = now;
    if (other_tab && g_floated && !g_transferring) {
        rexui_log([NSString stringWithFormat:@"pane drag: %@ into the tab now shown", g_id]);
        transfer();
    }
}

bool follow(int drag) {
    if (drag != g_drag || !(g_state == State::dragging || g_dropping))
        return false;
    if (g_floated) {
        NSView* carrier = g_carrier;
        if (g_carried_floating && !carrier.window)
            g_carried_floating = false;
        if (!g_carried_floating && adopt_floating()) {
            g_carried_floating = true;
            lift(g_last_at);
        }
        if (g_state == State::dragging)
            check_tab();
    }
    if (g_state == State::dragging)
        aim(g_last_at);
    return true;
}

void set_cursor(NSCursor* c) {
    g_cursor_direct = true;
    [c set];
    g_cursor_direct = false;
}

void reset(void) {
    g_state = State::idle;
    panes_hold_pointer(false);
    g_down = nil;
    g_target = nil;
    g_zone = Zone::none;
}

NSView* hit_at(NSWindow* w, NSPoint at) {
    NSView* frame = w.contentView.superview ?: w.contentView;
    return [frame hitTest:frame.superview ? [frame.superview convertPoint:at fromView:nil] : at];
}

bool press(NSWindow* w, NSPoint at, NSView* hit) {
    if (!g_config.pane_drag || g_broken || g_dropping || g_state != State::idle)
        return false;
    if (!is_rex_window(w) || rex_slide_busy())
        return false;
    NSView *chrome = chrome_of(w), *content = chrome ? chrome_content(chrome) : nil;
    if (!content || !hit || ![hit isDescendantOf:content])
        return false;
    NSDictionary<NSString*, NSView*>* panes = read_panes(content);
    if (!panes) {
        g_broken = true;
        return false;
    }
    NSString* pressed = nil;
    for (NSString* bid in panes) {
        if ([hit isDescendantOf:panes[bid]])
            pressed = bid;
    }
    NSView *float_pane = nil, *float_layer = nil;
    if (!pressed) {
        void* raw = rex_all_panes((__bridge const void*)content);
        NSDictionary<NSString*, NSDictionary*>* all = raw ? (__bridge_transfer NSDictionary*)raw : nil;
        for (NSString* bid in all) {
            if ([all[bid][@"floating"] boolValue] && [hit isDescendantOf:all[bid][@"view"]])
                pressed = bid;
        }
        const void *p = nullptr, *l = nullptr;
        if (pressed && rex_floating_pane((__bridge const void*)content, pressed.UTF8String, &p, &l)) {
            float_pane = (__bridge NSView*)p, float_layer = (__bridge NSView*)l;
        } else {
            pressed = nil;
        }
    }
    if (!pressed || (!float_pane && !shown(panes[pressed])) || !tiled(panes, chrome) || !current_session_id().length)
        return false;
    g_drag++;
    g_window = w;
    g_chrome = chrome;
    g_content = content;
    g_panes = panes;
    g_id = pressed;
    g_session = current_session_id();
    g_carried_floating = false;
    g_transferring = false;
    g_float_bounds = nil;
    if (float_pane) {
        carry(float_layer, float_pane);
        g_floated = true;
        g_carried_floating = true;
    } else {
        carry(panes[pressed], panes[pressed]);
        g_floated = false;
    }
    g_from_floating = float_pane != nil;
    g_layout = nil;
    g_focused = nil;
    CALayer* pl = g_pane.layer;
    CGPoint q = [chrome.layer convertPoint:[chrome convertPoint:at fromView:nil] toLayer:pl];
    CGRect b = pl.bounds;
    g_uv = CGPointMake((q.x - b.origin.x) / MAX(1, b.size.width), (q.y - b.origin.y) / MAX(1, b.size.height));
    g_down_at = g_last_at = at;
    g_state = State::pressed;
    panes_hold_pointer(true);
    return true;
}

void float_out(void) {
    if (g_config.pane_drag_dry_run)
        return;
    g_floated = true;
    NSString *session = g_session, *bid = g_id;
    int drag = g_drag;
    dispatch_async(g_calls, ^{
        NSString* focused = nil;
        NSDictionary* layout = tiled_layout(api(session, @"session.view", nil), bid, &focused);
        NSArray* rect = rect_in(layout, bid);
        id done = rect.count == 4 ? api(session, @"session.float_block", @{@"block_id": bid, @"bounds": rect}) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (drag != g_drag)
                return;
            if (!done) {
                if (!layout)
                    rexui_log([NSString stringWithFormat:@"pane drag: %@ isn't in session.view's layout", bid]);
                g_floated = false;
                return;
            }
            g_layout = layout;
            g_focused = focused;
            g_float_bounds = rect;
        });
    });
    if (g_config.pane_motion != 2 && g_config.pane_glide)
        glide_panes_from_now(g_chrome, g_content, 1.0, true, CGRectNull, nil, nil);
}

void begin_drag(void) {
    g_state = State::dragging;
    ensure_overlay(g_chrome);
    colour_indicator();
    set_cursor(NSCursor.closedHandCursor);
    int drag = g_drag;
    each_commit(^bool {
        return follow(drag);
    });
    if (g_config.pane_drag_dry_run)
        rexui_log([NSString stringWithFormat:@"pane drag: %@ lifted", g_id]);
    if (!g_from_floating)
        float_out();
}

void move(NSPoint at) {
    g_last_at = at;
    lift(at);
    aim(at);
}

void land_with(NSArray<NSArray*>* calls, NSString* what, NSArray<NSString*>* keep, NSString* anchor) {
    NSView *chrome = g_chrome, *content = g_content, *orig = g_pane;
    NSString *bid = g_id, *session = g_session;
    CGRect from = in_air();
    NSRect was = orig && chrome ? rect_of(orig, chrome) : NSZeroRect;
    bool floated = g_floated;
    __block bool left = false;
    g_dropping = true;
    glide_panes_from_now(
        chrome, content, 3, g_config.pane_motion != 2, from,
        ^NSView* {
            NSView* v = read_panes(g_content)[bid];
            if (!v) {
                left = true;
                return nil;
            }
            if (v == orig && (floated ? !left : NSEqualRects(rect_of(v, chrome), was)))
                return nil;
            return v.window ? v : nil;
        },
        ^(bool landed) {
            g_dropping = false;
            if (landed)
                unlift_now();
            else
                unlift_back();
        });
    rexui_log([NSString stringWithFormat:@"pane drag: %@: %lu call(s)", what, (unsigned long)calls.count]);
    dispatch_async(g_calls, ^{
        bool ok = true;
        for (NSArray* c in calls) {
            ok = api(session, c[0], c[1]) && ok;
        }
        if (!ok && anchor) {
            NSDictionary* listed = api(session, @"session.list_blocks", nil);
            for (NSDictionary* b in [listed isKindOfClass:NSDictionary.class] ? listed[@"blocks"] : nil) {
                if (![b isKindOfClass:NSDictionary.class] || ![keep containsObject:b[@"block_id"]]
                    || ![b[@"placement"] isEqual:@"detached"])
                    continue;
                rexui_log([NSString
                    stringWithFormat:@"pane drag: %@ was left detached: back beside %@", b[@"block_id"], anchor]);
                api(session, @"session.move_block", @{@"block_id": b[@"block_id"], @"anchor_block_id": anchor});
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!ok)
                rexui_log([NSString stringWithFormat:@"pane drag: %@ failed", what]);
            if (!calls.count)
                glide_panes_abandon();
        });
    });
}

void put_it_back(void) {
    hide_indicator();
    if (!g_floated)
        return unlift_back();
    NSString* bid = g_id;
    int drag = g_drag;
    g_dropping = true;
    dispatch_async(g_calls, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (drag != g_drag)
                return;
            g_dropping = false;
            NSDictionary* parent = parent_of(g_layout, bid);
            if (!parent) {
                if (g_floated && !g_from_floating)
                    rexui_log(@"pane drag: no layout to put it back in");
                return unlift_back();
            }
            NSDictionary* s = parent[@"split"];
            NSDictionary* sibling = [s[@"before"][@"block_id"] isEqual:bid] ? s[@"after"] : s[@"before"];
            NSMutableArray<NSString*>* others = [NSMutableArray array];
            leaves(sibling, others);
            NSString* r = others.firstObject;
            NSMutableArray<NSArray*>* calls = [NSMutableArray array];
            for (NSString* o in others) {
                if (o != r)
                    [calls addObject:@[@"session.detach_block", @{@"block_id": o}]];
            }
            place(parent, r, calls);
            if (g_focused)
                [calls addObject:@[@"session.focus_block", @{@"block_id": g_focused}]];
            NSMutableArray<NSString*>* keep = [others mutableCopy];
            [keep addObject:bid];
            land_with(calls, @"putting it back", keep, r);
        });
    });
}

void cancel(void) {
    bool dragging = g_state == State::dragging;
    if (dragging)
        set_cursor(NSCursor.arrowCursor);
    if (g_config.pane_drag_dry_run && dragging)
        rexui_log(@"pane drag: cancelled");
    put_it_back();
}

void drop(NSPoint at) {
    move(at);
    hide_indicator();
    set_cursor(NSCursor.arrowCursor);
    NSView *chrome = g_chrome, *pane = g_pane, *target = g_target ? g_panes[g_target] : nil;
    Zone z = g_zone;
    if (z == Zone::none || !target || !chrome || !pane
        || (!g_floated && no_op(rect_of(pane, chrome), rect_of(target, chrome), z))) {
        if (g_config.pane_drag_dry_run)
            rexui_log([NSString
                stringWithFormat:@"pane drag: dropped (%@ on %@): nothing to do", zone_label(z), g_target ?: @"-"]);
        return put_it_back();
    }
    NSDictionary* args = @{
        @"block_id": g_id,
        @"anchor_block_id": g_target,
        @"direction": z == Zone::left || z == Zone::right ? @"horizontal" : @"vertical",
        @"side": z == Zone::left || z == Zone::top ? @"before" : @"after",
    };
    if (g_config.pane_drag_dry_run) {
        rexui_log([NSString stringWithFormat:@"pane drag: dry run: session.move_block %@", args]);
        return put_it_back();
    }
    land_with(@[@[@"session.move_block", args]], @"the drop", @[g_id], g_target);
}

void watch_key_window(void) {
    static bool watching;
    if (watching)
        return;
    watching = true;
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResignKeyNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification* note) {
                                                    if (g_state == State::idle || note.object != g_window)
                                                        return;
                                                    if (g_state == State::dragging)
                                                        cancel();
                                                    reset();
                                                }];
}

void replay(NSEvent* up) {
    NSEvent* down = g_down;
    reset();
    if (up)
        [NSApp postEvent:up atStart:YES];
    if (down)
        send_event_on(down);
}

}

bool pane_drag_event(NSEvent* e) {
    switch (e.type) {
    case NSEventTypeLeftMouseDown: {
        if (g_state == State::dragging)
            cancel();
        if (g_state != State::idle)
            reset();
        constexpr NSEventModifierFlags mods = NSEventModifierFlagCommand | NSEventModifierFlagControl
            | NSEventModifierFlagOption | NSEventModifierFlagShift;
        if (!g_config.pane_drag || (e.modifierFlags & mods) != g_config.pane_drag_modifier)
            return false;
        NSWindow* w = e.window;
        if (!press(w, e.locationInWindow, hit_at(w, e.locationInWindow)))
            return false;
        watch_key_window();
        g_down = e;
        return true;
    }
    case NSEventTypeLeftMouseDragged:
        if (g_state == State::idle)
            return false;
        if (g_state == State::pressed) {
            if (hypot(e.locationInWindow.x - g_down_at.x, e.locationInWindow.y - g_down_at.y) < kStart)
                return true;
            begin_drag();
        }
        if (g_state == State::dragging)
            move(e.locationInWindow);
        return true;
    case NSEventTypeLeftMouseUp:
        switch (g_state) {
        case State::idle:
            return false;
        case State::pressed:
            replay(e);
            return true;
        case State::dragging:
            drop(e.locationInWindow);
            break;
        case State::cancelled:
            break;
        }
        reset();
        return true;
    case NSEventTypeKeyDown:
        if (g_state != State::dragging || e.keyCode != 53)
            return false;
        cancel();
        g_state = State::cancelled;
        return true;
    default:
        return false;
    }
}

namespace {
bool g_aiming;
}

bool pane_target_aim(NSPoint screen) {
    if (g_state != State::idle)
        return false;
    if (!g_aiming) {
        NSWindow* w = rex_window();
        NSView *chrome = w ? chrome_of(w) : nil, *content = chrome ? chrome_content(chrome) : nil;
        NSDictionary<NSString*, NSView*>* panes = read_panes(content);
        if (!panes.count)
            return false;
        g_window = w, g_chrome = chrome, g_content = content, g_panes = panes;
        g_id = nil, g_target = nil, g_zone = Zone::none;
        ensure_overlay(chrome);
        colour_indicator();
        g_aiming = true;
    }
    NSWindow* w = g_window;
    if (!w)
        return false;
    NSString* target = nil;
    Zone z = zone_at([w convertPointFromScreen:screen], &target, true);
    bool same = z == g_zone && [target isEqual:g_target];
    g_zone = z, g_target = target;
    show_indicator(target ? g_panes[target] : nil, z, !same);
    return target != nil;
}

NSDictionary* pane_target_end(void) {
    if (!g_aiming)
        return nil;
    g_aiming = false;
    NSDictionary* r = nil;
    if (g_target && g_zone != Zone::none) {
        NSRect at = g_shown && g_overlay.superlayer ? from_overlay(NSRectFromCGRect(g_indicator.frame)) : NSZeroRect;
        r = @{
            @"block": g_target,
            @"zone": zone_label(g_zone),
            @"rect": [NSValue valueWithRect:at],
            @"radius": @(g_indicator.cornerRadius)
        };
    }
    hide_indicator();
    g_target = nil, g_zone = Zone::none, g_panes = nil;
    return r;
}

extern "C" {

void* rex_pane_drag_panes(void) {
    NSWindow* w = rex_window();
    NSView *chrome = w ? chrome_of(w) : nil, *content = chrome ? chrome_content(chrome) : nil;
    void* raw = content ? rex_panes((__bridge const void*)content) : nullptr;
    if (!raw)
        return rexui_log(@"pane drag: no panes"), nullptr;
    NSDictionary<NSString*, NSView*>* panes = (__bridge_transfer NSDictionary*)raw;
    NSMutableDictionary<NSString*, NSValue*>* out = [NSMutableDictionary dictionary];
    for (NSString* bid in panes) {
        NSView* v = panes[bid];
        NSRect r = [v convertRect:v.bounds toView:nil];
        out[bid] = [NSValue valueWithRect:r];
        rexui_log([NSString stringWithFormat:@"pane drag: %@ %@ shown %d radius %.0f", bid, NSStringFromRect(r),
                                             shown(v), radius_of(v)]);
    }
    rexui_log([NSString stringWithFormat:@"pane drag: tiled %d", tiled(panes, chrome)]);
    return (__bridge_retained void*)out;
}

bool rex_pane_drag_begin(CGPoint at) {
    NSWindow* w = rex_window();
    if (!w || !press(w, at, hit_at(w, at)))
        return false;
    begin_drag();
    move(at);
    return true;
}

void rex_pane_drag_move(CGPoint at) {
    if (g_state == State::dragging)
        move(at);
}

void rex_pane_drag_zone(char* out, size_t size) {
    NSView* chrome = g_chrome;
    NSPoint p = chrome ? [chrome convertPoint:g_last_at fromView:nil] : NSZeroPoint;
    snprintf(out, size, "%s %s; pane on screen %s, pointer %s, taken at %.2f,%.2f", zone_label(g_zone).UTF8String,
             (g_target ?: @"-").UTF8String, NSStringFromRect(in_air()).UTF8String, NSStringFromPoint(p).UTF8String,
             g_uv.x, g_uv.y);
}

void rex_pane_drag_end(CGPoint at) {
    if (g_state == State::dragging)
        drop(at);
    reset();
}

void rex_pane_drag_cancel(void) {
    if (g_state == State::dragging)
        cancel();
    reset();
}
}

NSCursor* pane_drag_cursor(void) {
    return g_state == State::dragging ? NSCursor.closedHandCursor : nil;
}
