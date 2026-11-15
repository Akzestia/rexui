// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "rex/rex.h"
#include "web/web.h"

static CGFloat base_width(RXTile* t) {
    return t.kind == kTileSeparator ? kSeparator : kTile;
}

static RXTile* tile_at(RXAppBar* bar, CGFloat x) {
    for (RXTile* t in bar.tiles) {
        if (x >= NSMinX(t.frame) - kTileGap / 2 && x <= NSMaxX(t.frame) + kTileGap / 2)
            return t;
    }
    return nil;
}

static RXDoc* doc_of(RXSlot* slot, RXTile* t) {
    for (RXDoc* d in slot.members) {
        if ([d.path isEqualToString:t.path])
            return d;
    }
    return nil;
}

static NSArray<RXTile*>* part_of(RXAppBar* bar, RXTile* t) {
    int part = bar_part(doc_of(bar.slot, t));
    NSMutableArray* out = [NSMutableArray array];
    for (RXTile* o in bar.tiles) {
        if (o.kind == kTileDock && bar_part(doc_of(bar.slot, o)) == part)
            [out addObject:o];
    }
    return out;
}

@implementation RXTile
- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super init]))
        return nil;
    _frame = f;
    _layer = [CALayer layer];
    _layer.geometryFlipped = YES;
    _layer.actions = @{@"position": NSNull.null, @"bounds": NSNull.null, @"zPosition": NSNull.null};
    _layer.frame = f;
    return self;
}
- (void)setFrame:(NSRect)f {
    _frame = f;
    _layer.frame = f;
}
@end

@interface RXAppBar () {
    __weak RXSlot* _w_slot;
}
@end
@interface RXAppBar () {
    __weak id _w_host;
}
@end
@implementation RXAppBar
- (id)host {
    return _w_host;
}
- (void)setHost:(id)v {
    _w_host = v;
}
- (RXSlot*)slot {
    return _w_slot;
}
- (void)setSlot:(RXSlot*)v {
    _w_slot = v;
}
@end

static void shape_pill(RXAppBar* bar, double seconds = 0) {
    CAShapeLayer* s = bar.pill_fill;
    if (!s)
        return;
    CGRect f = bar.pill.bounds;
    CAShapeLayer* shown = seconds > 0 ? ((CAShapeLayer*)s.presentationLayer ?: s) : nil;
    id from_path = (__bridge id)shown.path;
    CGRect from_bounds = shown.bounds;
    CGPoint from_pos = shown.position;
    if (!CGRectEqualToRect(s.frame, f))
        s.frame = f;
    CGPathRef p = box_path(bar.pill_shape, f.size);
    s.path = p;
    if (p)
        CGPathRelease(p);
    if (!shown)
        return;
    CAMediaTimingFunction* curve = [CATransaction animationTimingFunction];
    auto go = [&](NSString* key, id from, id to) {
        if (!from || !to || [from isEqual:to])
            return;
        CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:key];
        a.fromValue = from, a.toValue = to, a.duration = seconds, a.timingFunction = curve;
        [s addAnimation:a forKey:[@"rexui.pill." stringByAppendingString:key]];
    };
    go(@"path", from_path, (__bridge id)s.path);
    go(@"bounds", [NSValue valueWithRect:from_bounds], [NSValue valueWithRect:s.bounds]);
    go(@"position", [NSValue valueWithPoint:from_pos], [NSValue valueWithPoint:s.position]);
}

static void bounce(RXTile* t) {
    CABasicAnimation* b = [CABasicAnimation animationWithKeyPath:@"position.y"];
    b.byValue = @(8);
    b.duration = 0.12;
    b.autoreverses = YES;
    [t.tile addAnimation:b forKey:@"bounce"];
}

static void magnify(RXAppBar* bar, double seconds) {
    NSUInteger n = bar.tiles.count;
    if (!n)
        return;
    std::vector<double> scale(n);
    double b = bar.base > 0 ? bar.base : 1, gap = kTileGap * b;
    double total = (n - 1) * gap;
    for (NSUInteger i = 0; i < n; i++) {
        double d = isnan(bar.mouse_x) ? 1e9 : fabs(NSMidX(bar.tiles[i].frame) - bar.mouse_x);
        scale[i] =
            bar.tiles[i].kind == kTileSeparator ? b : b * (1 + 0.5 * MAX(0.0, cos(MIN(d / (110 * b), 1.0) * M_PI_2)));
        total += base_width(bar.tiles[i]) * scale[i];
    }
    double mid = (NSMinX(bar.tiles.firstObject.frame) + NSMaxX(bar.tiles.lastObject.frame)) / 2;
    double x = mid - total / 2;
    [CATransaction begin];
    [CATransaction setAnimationDuration:seconds];
    for (NSUInteger i = 0; i < n; i++) {
        RXTile* t = bar.tiles[i];
        double w = base_width(t) * scale[i], dx = x + w / 2 - NSMidX(t.frame);
        t.tile.transform = CATransform3DScale(CATransform3DMakeTranslation(dx, 0, 0), scale[i], scale[i], 1);
        t.dot.transform = CATransform3DMakeTranslation(dx, 0, 0);
        x += w + gap;
    }
    CGRect pill = bar.pill.frame;
    double grown = total + 2 * kPillPad * b;
    bar.pill.frame = CGRectMake(mid - grown / 2, pill.origin.y, grown, pill.size.height);
    shape_pill(bar, seconds);
    [CATransaction commit];
    if (is_float_bar(bar.slot))
        float_bar_grow(bar.slot, grown, seconds);
}

static NSView* chrome_for(RXSlot* slot) {
    NSWindow* w = slot.view.window ?: slot.floating.window;
    return (w ? chrome_of(w) : nil) ?: slot.view.superview;
}

static CALayer* make_ghost(RXTile* t, NSView* chrome) {
    CALayer* src = t.tile;
    if (!chrome.layer || !src)
        return nil;
    CGRect from = [chrome.layer convertRect:src.bounds fromLayer:src];
    CGFloat scale = chrome.window.backingScaleFactor ?: 2;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx =
        CGBitmapContextCreate(nullptr, (size_t)(from.size.width * scale), (size_t)(from.size.height * scale), 8, 0, cs,
                              (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    if (!ctx) {
        CGColorSpaceRelease(cs);
        return nil;
    }
    CGContextScaleCTM(ctx, scale, scale);
    CGContextScaleCTM(ctx, from.size.width / src.bounds.size.width, from.size.height / src.bounds.size.height);
    [src renderInContext:ctx];
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    uint8_t px[8 * 8 * 4] = {0};
    CGContextRef small = CGBitmapContextCreate(px, 8, 8, 8, 32, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    double sum[4] = {0, 0, 0, 0};
    if (small) {
        CGContextSetInterpolationQuality(small, kCGInterpolationHigh);
        CGContextDrawImage(small, CGRectMake(0, 0, 8, 8), img);
        CGContextRelease(small);
        for (int i = 0; i < 64; i++)
            for (int c = 0; c < 4; c++)
                sum[c] += px[i * 4 + c];
    }
    NSColor* tint = sum[3] > 0
        ? [NSColor colorWithSRGBRed:sum[0] / sum[3] green:sum[1] / sum[3] blue:sum[2] / sum[3] alpha:1]
        : NSColor.controlAccentColor;

    NSDictionary* still = @{
        @"position": NSNull.null,
        @"bounds": NSNull.null,
        @"cornerRadius": NSNull.null,
        @"backgroundColor": NSNull.null,
        @"opacity": NSNull.null,
        @"transform": NSNull.null,
        @"shadowOpacity": NSNull.null
    };
    CALayer *ghost = [CALayer layer], *face = [CALayer layer];
    ghost.actions = still, face.actions = still;
    ghost.zPosition = 100;
    ghost.cornerRadius = 10 * from.size.width / kTile;
    ghost.cornerCurve = kCACornerCurveContinuous;
    ghost.masksToBounds = YES;
    ghost.backgroundColor = tint.CGColor;
    face.contents = (__bridge_transfer id)img;
    face.bounds = CGRectMake(0, 0, from.size.width, from.size.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ghost.frame = from;
    face.position = CGPointMake(from.size.width / 2, from.size.height / 2);
    [ghost addSublayer:face];
    [chrome.layer addSublayer:ghost];
    [CATransaction commit];
    return ghost;
}

struct Spring {
    double mass, stiffness, damping, settle, lands;
};
static Spring rex_spring(void) {
    double s[3] = {1, 520, 46};
    rex_easing_spring(s);
    CASpringAnimation* probe = [CASpringAnimation animation];
    probe.mass = s[0], probe.stiffness = s[1], probe.damping = s[2];
    double settle = MIN(probe.settlingDuration, 0.8);
    return {s[0], s[1], s[2], settle, settle * 0.7};
}

static void grow_into(CALayer* ghost, CGRect to, CGColorRef bg, CGFloat radius, Spring sp) {
    CALayer* face = ghost.sublayers.firstObject;
    CASpringAnimation* (^grow)(NSString*, id) = ^(NSString* key, id was) {
        CASpringAnimation* a = [CASpringAnimation animationWithKeyPath:key];
        a.mass = sp.mass, a.stiffness = sp.stiffness, a.damping = sp.damping;
        a.fromValue = was;
        a.duration = a.settlingDuration;
        return a;
    };
    CABasicAnimation* (^ease)(NSString*, id, id, double, double) =
        ^(NSString* key, id a0, id a1, double after, double secs) {
            CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:key];
            a.fromValue = a0, a.toValue = a1;
            a.beginTime = CACurrentMediaTime() + after, a.duration = secs;
            a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
            a.fillMode = kCAFillModeBoth, a.removedOnCompletion = NO;
            return a;
        };
    CALayer* now = ghost.presentationLayer ?: ghost;
    double sc = now.transform.m11 > 0.01 ? now.transform.m11 : 1;
    CGRect b = now.bounds;
    NSValue* p0 = [NSValue valueWithPoint:NSPointFromCGPoint(now.position)];
    NSValue* b0 = [NSValue valueWithRect:NSMakeRect(0, 0, b.size.width * sc, b.size.height * sc)];
    CGPoint fp = ((CALayer*)face.presentationLayer ?: face).position;
    NSValue* f0 = [NSValue valueWithPoint:NSMakePoint(fp.x * sc, fp.y * sc)];
    id c0 = (__bridge id)ghost.backgroundColor;
    NSNumber* r0 = @(now.cornerRadius * sc);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [ghost removeAllAnimations];
    ghost.position = CGPointMake(CGRectGetMidX(to), CGRectGetMidY(to));
    ghost.bounds = CGRectMake(0, 0, to.size.width, to.size.height);
    ghost.cornerRadius = radius;
    ghost.backgroundColor = bg;
    ghost.transform = CATransform3DIdentity;
    ghost.shadowOpacity = 0;
    face.position = CGPointMake(to.size.width / 2, to.size.height / 2);
    [ghost addAnimation:grow(@"position", p0) forKey:@"fly.position"];
    [ghost addAnimation:grow(@"bounds", b0) forKey:@"fly.bounds"];
    [ghost addAnimation:grow(@"cornerRadius", r0) forKey:@"fly.radius"];
    [face addAnimation:grow(@"position", f0) forKey:@"fly.position"];
    [ghost addAnimation:ease(@"backgroundColor", c0, (__bridge id)bg, 0, sp.settle * 0.6) forKey:@"fly.colour"];
    [face addAnimation:ease(@"transform.scale", @(sc), @(1.6 * sc), 0, sp.settle * 0.6) forKey:@"fly.scale"];
    [face addAnimation:ease(@"opacity", @1, @0, sp.settle * 0.15, sp.settle * 0.4) forKey:@"fly.fade"];
    [ghost addAnimation:ease(@"opacity", @1, @0, sp.lands, 0.2) forKey:@"fly.land"];
    [CATransaction commit];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((sp.lands + 0.25) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [ghost removeFromSuperlayer];
                   });
}

static CGColorRef landing_colour(RXDoc* d, CALayer* ghost) {
    CALayer* dl = d.root.layer;
    return dl.backgroundColor && CGColorGetAlpha(dl.backgroundColor) > 0.05 ? dl.backgroundColor
                                                                            : ghost.backgroundColor;
}

static void fly(RXTile* t, RXSlot* slot) {
    if (!flag(slot_lead(slot), P::iconFly, false))
        return;
    NSView* chrome = slot.view.superview;
    CALayer* ghost = make_ghost(t, chrome);
    if (!ghost)
        return;
    Spring sp = rex_spring();
    slot.flying_until = CACurrentMediaTime() + 0.02 + sp.lands;

    dispatch_async(dispatch_get_main_queue(), ^{
        RXDoc* d = active_member(slot);
        RXDockView* dv = d.root.host.window ? d.root.host : slot.view;
        CGRect to =
            dv.window ? NSRectToCGRect([dv convertRect:dv.bounds toView:chrome]) : NSRectToCGRect(slot.view.frame);
        if (to.size.width < 2 || to.size.height < 2) {
            [ghost removeFromSuperlayer];
            return;
        }
        CALayer* dl = d.root.layer;
        grow_into(ghost, to, landing_colour(d, ghost), dl.cornerRadius > 0 ? dl.cornerRadius : 12, sp);
    });
}

static constexpr CGFloat kTear = 24;

static void carry_to(RXAppBar* bar, NSView* chrome) {
    CALayer* ghost = bar.carried;
    if (!ghost || !chrome.window)
        return;
    NSPoint p = [chrome convertPoint:[chrome.window convertPointFromScreen:NSEvent.mouseLocation] fromView:nil];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ghost.position = NSPointToCGPoint(p);
    [CATransaction commit];
}

static void drop_torn(RXAppBar* bar, RXTile* t);
static void untear(RXAppBar* bar, RXTile* t);

static id host_of(RXAppBar* bar) {
    id h = bar.host;
    return h && [h layer] == bar.layer.superlayer ? h : nil;
}

static __weak RXAppBar* g_carrying;

static void stop_carry_monitor(void) {
    g_carrying = nil;
}
static void carry_monitor(RXAppBar* bar) {
    g_carrying = bar;
}

bool bar_carry_event(NSEvent* e) {
    RXAppBar* b = g_carrying;
    if (!b)
        return false;
    NSEventType type = e.type;
    if (type != NSEventTypeLeftMouseDragged && type != NSEventTypeLeftMouseUp && type != NSEventTypeKeyDown)
        return false;
    RXTile* t = b.pressed;
    if (!t) {
        stop_carry_monitor();
        return false;
    }
    if (type == NSEventTypeKeyDown) {
        if (e.keyCode != 53 || !b.torn)
            return false;
        b.pressed = nil;
        b.dragging = false;
        stop_carry_monitor();
        untear(b, t);
        return true;
    }
    id host = host_of(b);
    NSPoint p = host ? [host convertPoint:e.locationInWindow fromView:nil] : NSMakePoint(NAN, NAN);
    if (type == NSEventTypeLeftMouseDragged) {
        if (host)
            bar_dragged(b, p);
        return true;
    }
    stop_carry_monitor();
    bar_up(b, p);
    return true;
}

static void tear(RXAppBar* bar, RXTile* t) {
    bar.torn = true;
    carry_monitor(bar);
    NSView* chrome = chrome_for(bar.slot);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    t.layer.zPosition = 0;
    [CATransaction commit];
    bar.mouse_x = NAN;
    magnify(bar, 0.15);
    if (!bar.carried) {
        CALayer* ghost = make_ghost(t, chrome);
        if (ghost) {
            ghost.shadowOpacity = 0.3, ghost.shadowRadius = 10, ghost.shadowOffset = CGSizeMake(0, 4);
            ghost.masksToBounds = NO;
            ghost.sublayers.firstObject.cornerRadius = ghost.cornerRadius;
            ghost.sublayers.firstObject.masksToBounds = YES;
            CASpringAnimation* a = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
            a.fromValue = @1, a.toValue = @1.15;
            a.damping = 18, a.stiffness = 300;
            a.duration = a.settlingDuration;
            ghost.transform = CATransform3DMakeScale(1.15, 1.15, 1);
            [ghost addAnimation:a forKey:@"lift"];
        }
        bar.carried = ghost;
    }
    bar.carried.opacity = 1;
    carry_to(bar, chrome);
    CABasicAnimation* dim = [CABasicAnimation animationWithKeyPath:@"opacity"];
    dim.fromValue = @(((CALayer*)t.tile.presentationLayer ?: t.tile).opacity);
    dim.toValue = @0.35;
    dim.duration = 0.12;
    t.tile.opacity = 0.35;
    [t.tile addAnimation:dim forKey:@"dim"];
}

static void undim(RXTile* t) {
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @(((CALayer*)t.tile.presentationLayer ?: t.tile).opacity);
    a.toValue = @1;
    a.duration = 0.18;
    t.tile.opacity = 1;
    [t.tile addAnimation:a forKey:@"dim"];
}

static void send_home(CALayer* ghost, RXTile* t, NSView* chrome) {
    if (!ghost)
        return;
    if (!chrome.layer || !t.tile.superlayer)
        return (void)[ghost removeFromSuperlayer];
    CGRect home = [chrome.layer convertRect:t.tile.bounds fromLayer:t.tile];
    Spring sp = rex_spring();
    CALayer* now = ghost.presentationLayer ?: ghost;
    NSValue* p0 = [NSValue valueWithPoint:NSPointFromCGPoint(now.position)];
    NSValue* s0 = [NSValue valueWithCATransform3D:now.transform];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [ghost removeAllAnimations];
    ghost.position = CGPointMake(CGRectGetMidX(home), CGRectGetMidY(home));
    ghost.transform = CATransform3DMakeScale(home.size.width / MAX(1, ghost.bounds.size.width),
                                             home.size.height / MAX(1, ghost.bounds.size.height), 1);
    for (NSString* key in @[@"position", @"transform"]) {
        CASpringAnimation* a = [CASpringAnimation animationWithKeyPath:key];
        a.mass = sp.mass, a.stiffness = sp.stiffness, a.damping = sp.damping;
        a.fromValue = [key isEqualToString:@"position"] ? p0 : s0;
        a.duration = a.settlingDuration;
        [ghost addAnimation:a forKey:[@"home." stringByAppendingString:key]];
    }
    CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1, fade.toValue = @0;
    fade.beginTime = CACurrentMediaTime() + sp.lands * 0.8, fade.duration = 0.15;
    fade.fillMode = kCAFillModeBoth, fade.removedOnCompletion = NO;
    [ghost addAnimation:fade forKey:@"home.fade"];
    [CATransaction commit];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((sp.lands * 0.8 + 0.2) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [ghost removeFromSuperlayer];
                   });
}

static void untear(RXAppBar* bar, RXTile* t) {
    bar.torn = false;
    pane_target_end();
    CALayer* ghost = bar.carried;
    bar.carried = nil;
    send_home(ghost, t, chrome_for(bar.slot));
    undim(t);
}

static bool off_bar(RXAppBar* bar, NSPoint at) {
    return !NSPointInRect(at, NSInsetRect(bar.frame, -kTear / 2, -kTear));
}

static void drop_torn(RXAppBar* bar, RXTile* t) {
    bar.torn = false;
    NSDictionary* at = pane_target_end();
    CALayer* ghost = bar.carried;
    bar.carried = nil;
    RXSlot* slot = bar.slot;
    NSView* chrome = chrome_for(slot);
    RXDoc* d = doc_of(slot, t);
    NSString *path = d.path, *block = at[@"block"], *zone = at[@"zone"];
    bool there = path.length && [NSFileManager.defaultManager fileExistsAtPath:path];
    if (!at || !there || !g_session_id.length) {
        if (at && !there)
            rexui_log([NSString stringWithFormat:@"app bar: %@ has no file to open in a pane", t.title]);
        send_home(ghost, t, chrome);
        undim(t);
        return;
    }
    if ([zone isEqualToString:@"center"]) {
        if (!ui_pane_here(path, block, g_session_id, nil)) {
            send_home(ghost, t, chrome);
            undim(t);
            return;
        }
    } else {
        bool across = [zone isEqualToString:@"left"] || [zone isEqualToString:@"right"];
        bool before = [zone isEqualToString:@"left"] || [zone isEqualToString:@"top"];
        ui_open_pane(path, @{
            @"direction": across ? @"horizontal" : @"vertical",
            @"side": before ? @"before" : @"after",
            @"anchor": block
        });
    }
    bounce(t);
    undim(t);
    CGRect to = chrome.window ? NSRectToCGRect([chrome convertRect:[at[@"rect"] rectValue] fromView:nil]) : CGRectZero;
    if (!ghost || to.size.width < 2 || to.size.height < 2)
        return (void)[ghost removeFromSuperlayer];
    ghost.sublayers.firstObject.cornerRadius = 0;
    grow_into(ghost, to, landing_colour(d, ghost), [at[@"radius"] doubleValue], rex_spring());
}

static void raise(RXSlot* slot, bool on) {
    if (!slot || slot.floating)
        return;
    NSUInteger gen = ++slot.raise_gen;
    if (on) {
        if (slot.raised)
            return;
        slot.raised = true;
        slot.bar.layer.zPosition = 1;
        RXRoot* root = slot.view.rootView;
        if ([slot.view.superview isKindOfClass:RXRoot.class])
            [root addHost:slot.view band:kBandDocksRaised];
        return;
    }
    if (!slot.raised)
        return;
    __weak RXSlot* weak = slot;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RXSlot* s = weak;
        if (!s || s.raise_gen != gen || !s.raised)
            return;
        s.raised = false;
        s.bar.layer.zPosition = 0;
        RXRoot* root = s.view.rootView;
        if ([s.view.superview isKindOfClass:RXRoot.class])
            [root addHost:s.view band:kBandDocks];
    });
}

void bar_moved(RXAppBar* bar, NSPoint p) {
    CGFloat x = isnan(p.x) ? NAN : p.x - NSMinX(bar.frame);
    RXTile* t = isnan(x) || bar.dragging ? nil : tile_at(bar, x);
    id host = bar.host;
    if (t.title.length && host)
        tips_at(t, t.title, [host window],
                [host convertRect:NSOffsetRect(t.frame, NSMinX(bar.frame), NSMinY(bar.frame)) toView:nil]);
    else
        tips_at(nil, nil, nil, NSZeroRect);
    if (isnan(x) && isnan(bar.mouse_x))
        return;
    bool leaving = isnan(x);
    bar.mouse_x = bar.dragging ? NAN : x;
    magnify(bar, leaving ? 0.2 : 0.08);
    raise(bar.slot, !isnan(bar.mouse_x));
}

void bar_down(RXAppBar* bar, NSPoint at) {
    NSPoint p = NSMakePoint(at.x - NSMinX(bar.frame), at.y - NSMinY(bar.frame));
    RXTile* t = tile_at(bar, p.x);
    bar.pressed = nil;
    bar.dragging = false;
    if (!t || t.kind == kTileSeparator)
        return;
    if (t.kind == kTileSearch) {
        bounce(t);
        if (RXSlot* slot = bar.slot)
            bar_search(slot);
        return;
    }
    bar.pressed = t;
    bar.press_x = p.x;
}

void bar_dragged(RXAppBar* bar, NSPoint at) {
    RXTile* t = bar.pressed;
    if (!t)
        return;
    CGFloat dx = at.x - NSMinX(bar.frame) - bar.press_x;
    bool off = off_bar(bar, at);
    if (!bar.dragging) {
        if (fabs(dx) < 4 && !off)
            return;
        bar.dragging = true;
        bar.mouse_x = NAN;
        magnify(bar, 0.12);
    }
    if (off) {
        if (!bar.torn)
            tear(bar, t);
        carry_to(bar, chrome_for(bar.slot));
        pane_target_aim(NSEvent.mouseLocation);
        return;
    }
    if (bar.torn)
        untear(bar, t);
    NSArray<RXTile*>* part = part_of(bar, t);
    CGFloat lo = NSMinX(part.firstObject.frame), hi = NSMaxX(part.lastObject.frame), b = bar.base > 0 ? bar.base : 1;
    dx = MAX(lo - NSMinX(t.frame), MIN(dx, hi - NSMaxX(t.frame)));
    CGFloat mid = NSMidX(t.frame) + dx;
    NSInteger at_i = 0;
    for (RXTile* o in part)
        at_i += o != t && NSMidX(o.frame) < mid;
    bar.drop_at = at_i;
    NSMutableArray<RXTile*>* order = [part mutableCopy];
    [order removeObject:t];
    [order insertObject:t atIndex:at_i];
    [CATransaction begin];
    [CATransaction setAnimationDuration:0.15];
    for (NSUInteger k = 0; k < order.count; k++) {
        RXTile* o = order[k];
        if (o == t)
            continue;
        CGFloat shift = NSMinX(part[k].frame) - NSMinX(o.frame);
        o.tile.transform = CATransform3DScale(CATransform3DMakeTranslation(shift, 0, 0), b, b, 1);
        o.dot.transform = CATransform3DMakeTranslation(shift, 0, 0);
    }
    [CATransaction commit];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    t.layer.zPosition = 1;
    t.tile.transform = CATransform3DScale(CATransform3DMakeTranslation(dx, 0, 0), b * 1.08, b * 1.08, 1);
    t.dot.transform = CATransform3DMakeTranslation(dx, 0, 0);
    [CATransaction commit];
}

void bar_up(RXAppBar* bar, NSPoint) {
    RXTile* t = bar.pressed;
    RXSlot* slot = bar.slot;
    bar.pressed = nil;
    if (g_carrying == bar)
        stop_carry_monitor();
    if (!t || !slot)
        return;
    if (!bar.dragging) {
        bounce(t);
        if (!slot.shown)
            slot_show(slot, t.path), fly(t, slot);
        else if ([slot.active isEqualToString:t.path])
            slot_hide(slot);
        else
            slot_switch(slot, t.path), fly(t, slot);
        return;
    }
    bar.dragging = false;
    t.layer.zPosition = 0;
    if (bar.torn)
        return drop_torn(bar, t);
    NSArray<RXTile*>* part = part_of(bar, t);
    NSMutableArray<RXTile*>* order = [part mutableCopy];
    [order removeObject:t];
    [order insertObject:t atIndex:MIN((NSUInteger)bar.drop_at, order.count)];
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    int which = bar_part(doc_of(slot, t));
    bool placed = false;
    for (RXTile* o in bar.tiles) {
        if (o.kind != kTileDock)
            continue;
        if (bar_part(doc_of(slot, o)) != which)
            [names addObject:o.path.lastPathComponent];
        else if (!placed) {
            for (RXTile* x in order)
                [names addObject:x.path.lastPathComponent];
            placed = true;
        }
    }
    save_bar_order(slot, names);
}

NSArray<NSDictionary*>* bar_menu(RXAppBar* bar, NSPoint at) {
    RXSlot* slot = bar.slot;
    RXTile* t = tile_at(bar, at.x - NSMinX(bar.frame));
    RXDoc* doc = t.kind == kTileDock ? doc_of(slot, t) : nil;
    if (!doc || !is_web_doc(doc))
        return nil;
    bool awake = web_kept_awake(doc);
    return @[
        @{@"title" : tr(@"Suspend When Hidden"), @"on" : @(!awake), @"run" : ^{ web_keep_awake(doc, !awake);
}
}
, @{@"title": tr(@"Suspend Now"),
    @"enabled": @(web_can_suspend(doc)),
    @"run": ^{
        web_suspend_doc(doc);
}
}
, @{}, @{@"title": is_tab_doc(doc) ? tr(@"Close") : tr(@"Close Page"),
         @"run": ^{
             close_web_doc(slot, doc);
}
},
    ];
}

static uint64_t sig_str(uint64_t h, NSString* s) {
    const NSUInteger n = s.length;
    unichar buf[64];
    for (NSUInteger at = 0; at < n;) {
        const NSUInteger k = MIN((NSUInteger)64, n - at);
        [s getCharacters:buf range:NSMakeRange(at, k)];
        for (NSUInteger i = 0; i < k; i++)
            h = (h ^ buf[i]) * 1099511628211ull;
        at += k;
    }
    return (h ^ 0x10000) * 1099511628211ull;
}
static uint64_t sig_num(uint64_t h, double d) {
    uint64_t bits;
    memcpy(&bits, &d, sizeof bits);
    return (h ^ bits) * 1099511628211ull;
}
void build_bar(RXSlot* slot) {
    uint64_t sig = 1469598103934665603ull;
    for (RXDoc* d in slot.members) {
        sig = sig_str(sig, d.path), sig = sig_str(sig, str(d.root, P::icon, @"")),
        sig = sig_str(sig, str(d.root, P::iconColor, @""));
        sig = sig_str(sig, str(d.root, P::title, @"")), sig = sig_num(sig, bar_part(d)),
        sig = sig_num(sig, num(d.root, P::tileRadius, 10));
        sig = sig_str(sig, str(d.root, P::iconInk, @""));
    }
    RXDoc* lead = slot.lead ?: slot.members.firstObject;
    NSString *engine = bar_search_engine(slot), *search_color = lead.root ? str(lead.root, P::searchColor, @"") : @"";
    CGFloat bar_radius = lead.root ? num(lead.root, P::barRadius, 18) : 18;
    auto first_set = [&](NSString* name) -> NSString* {
        for (RXDoc* d in slot.members) {
            NSString* v = d.root ? str(d.root, name, @"") : @"";
            if (v.length)
                return v;
        }
        return @"";
    };
    NSString *tile_shape = first_set(@"tileShape"), *pill_shape = first_set(@"barShape");
    NSString *tile_fill_s = first_set(@"tileFill"), *tile_active_s = first_set(@"tileActive"),
             *active_ink_s = first_set(@"tileActiveInk");
    sig = sig_num(sig, g_theme.dark), sig = sig_str(sig, engine ?: @""), sig = sig_str(sig, search_color),
    sig = sig_num(sig, bar_radius);
    for (NSString* x in @[tile_shape, pill_shape, tile_fill_s, tile_active_s, active_ink_s])
        sig = sig_str(sig, x);
    RXAppBar* bar = slot.bar;
    if (bar && sig == bar.signature)
        return;
    if (!bar) {
        bar = [RXAppBar new];
        bar.layer = [RXLayer layer];
        bar.slot = slot;
        bar.mouse_x = NAN;
        bar.pill = [CALayer layer];
        bar.pill.cornerRadius = 18;
        bar.pill.cornerCurve = kCACornerCurveContinuous;
        bar.pill.borderWidth = 0.5;
        [bar.layer addSublayer:bar.pill];
        slot.bar = bar;
    }
    bar.signature = sig;
    bar.laid_out = nil;
    NSColor* fg = g_theme.fg;
    bar.pill_radius = MAX(0, bar_radius);
    bar.pill_shape = pill_shape;
    bar.pill.cornerRadius = pill_shape.length ? 0 : bar.pill_radius;
    CGColorRef pill_bg = [fg colorWithAlphaComponent:g_theme.dark ? 0.07 : 0.06].CGColor,
               pill_edge = [fg colorWithAlphaComponent:0.12].CGColor;
    if (pill_shape.length) {
        if (!bar.pill_fill) {
            bar.pill_fill = (CAShapeLayer*)still([CAShapeLayer layer]);
            [bar.pill addSublayer:bar.pill_fill];
        }
        bar.pill_fill.fillColor = pill_bg;
        bar.pill_fill.strokeColor = [fg colorWithAlphaComponent:0.2].CGColor;
        bar.pill_fill.lineWidth = 1;
        bar.pill.backgroundColor = nil;
        bar.pill.borderWidth = 0;
        shape_pill(bar);
    } else {
        [bar.pill_fill removeFromSuperlayer];
        bar.pill_fill = nil;
        bar.pill.backgroundColor = pill_bg;
        bar.pill.borderColor = pill_edge;
        bar.pill.borderWidth = 0.5;
    }
    NSColor *tile_fill = parse_color(tile_fill_s), *tile_active = parse_color(tile_active_s),
            *active_ink = parse_color(active_ink_s);
    for (RXTile* t in bar.tiles)
        [t.layer removeFromSuperlayer];
    bar.tiles = [NSMutableArray array];
    bar.pressed = nil;
    bar.dragging = false;
    if (bar.torn) {
        bar.torn = false;
        pane_target_end();
    }
    [bar.carried removeFromSuperlayer];
    bar.carried = nil;
    auto separator = [&] {
        RXTile* t = [[RXTile alloc] initWithFrame:NSMakeRect(0, 0, kSeparator, kTile)];
        t.kind = kTileSeparator;
        CALayer* line = [CALayer layer];
        line.anchorPoint = CGPointMake(0.5, 0);
        line.bounds = CGRectMake(0, 0, 1.5, kTile * 0.6);
        line.position = CGPointMake(kSeparator / 2, kTile * 0.2);
        line.cornerRadius = 0.75;
        line.backgroundColor = [fg colorWithAlphaComponent:0.28].CGColor;
        [t.layer addSublayer:line];
        t.tile = line;
        [bar.layer addSublayer:t.layer];
        [bar.tiles addObject:t];
    };
    int part = -1;
    for (RXDoc* d in slot.members) {
        if (part >= 0 && bar_part(d) != part)
            separator();
        part = bar_part(d);
        RXNode* r = d.root;
        RXTile* t = [[RXTile alloc] initWithFrame:NSMakeRect(0, 0, kTile, kTile)];
        t.path = d.path;
        t.title = str(r, P::title, d.path.lastPathComponent.stringByDeletingPathExtension);
        CALayer* tile = [CALayer layer];
        tile.anchorPoint = CGPointMake(0.5, 0);
        tile.bounds = CGRectMake(0, 0, kTile, kTile);
        tile.position = CGPointMake(kTile / 2, 0);
        CGFloat tr = MAX(0, num(r, P::tileRadius, 10));
        NSColor* ink = parse_color(str(r, P::iconInk, @"")) ?: NSColor.whiteColor;
        tile.cornerRadius = tr;
        tile.cornerCurve = kCACornerCurveContinuous;
        tile.masksToBounds = NO;
        tile.shadowOpacity = 0.25;
        tile.shadowRadius = 3;
        tile.shadowOffset = CGSizeMake(0, -1);
        NSString* icon = str(r, P::icon, @"");
        NSString* path = icon.stringByExpandingTildeInPath;
        if (!path.isAbsolutePath)
            path = [d.path.stringByDeletingLastPathComponent stringByAppendingPathComponent:icon];
        static NSSet* pictures = [NSSet setWithArray:@[
            @"png", @"jpg", @"jpeg", @"gif", @"tif", @"tiff", @"icns", @"pdf", @"svg", @"webp", @"heic", @"bmp"
        ]];
        bool file = [icon containsString:@"/"] || [icon hasPrefix:@"~"] ||
            [pictures containsObject:icon.pathExtension.lowercaseString];
        NSImage* picture = file ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
        if (file && !picture)
            icon = @"";
        CALayer* glyph = [CALayer layer];
        glyph.frame = tile.bounds;
        glyph.contentsGravity = kCAGravityCenter;
        glyph.contentsScale = 2;
        NSInteger pixels = 0;
        for (NSImageRep* rep in picture.representations)
            pixels = MAX(pixels, rep.pixelsWide);
        if (picture && pixels >= 96) {
            glyph.contents = [picture layerContentsForContentsScale:2];
            glyph.contentsGravity = kCAGravityResizeAspectFill;
            glyph.cornerRadius = tr;
            glyph.cornerCurve = kCACornerCurveContinuous;
            glyph.masksToBounds = YES;
        } else if (picture) {
            CAGradientLayer* g = [CAGradientLayer layer];
            g.frame = tile.bounds;
            g.cornerRadius = tr;
            g.cornerCurve = kCACornerCurveContinuous;
            g.colors =
                @[(id)[NSColor colorWithWhite:0.99 alpha:1].CGColor, (id)[NSColor colorWithWhite:0.88 alpha:1].CGColor];
            [tile addSublayer:g];
            glyph.frame = CGRectInset(tile.bounds, 9, 9);
            glyph.contents = [picture layerContentsForContentsScale:2];
            glyph.contentsGravity = kCAGravityResizeAspect;
            glyph.magnificationFilter = kCAFilterTrilinear;
        } else if (tile_shape.length) {
            NSColor* base = tile_fill ?: parse_color(str(r, P::iconColor, @"")) ?: NSColor.controlAccentColor;
            tile.shadowOpacity = 0;
            tile.cornerRadius = 0;
            CGPathRef path2 = box_path(tile_shape, tile.bounds.size);
            CGAffineTransform flip = CGAffineTransformMake(1, 0, 0, -1, 0, tile.bounds.size.height);
            CGPathRef up = path2 ? CGPathCreateCopyByTransformingPath(path2, &flip) : nullptr;
            if (path2)
                CGPathRelease(path2);
            CAShapeLayer* plate = (CAShapeLayer*)still([CAShapeLayer layer]);
            plate.frame = tile.bounds;
            plate.path = up;
            plate.fillColor = base.CGColor;
            plate.strokeColor = [fg colorWithAlphaComponent:0.28].CGColor;
            plate.lineWidth = 1;
            [tile addSublayer:plate];
            NSColor* lit_fill = tile_active ?: NSColor.controlAccentColor;
            CAShapeLayer* lit = (CAShapeLayer*)still([CAShapeLayer layer]);
            lit.frame = tile.bounds;
            lit.path = up;
            lit.fillColor = lit_fill.CGColor;
            lit.strokeColor = lit_fill.CGColor;
            lit.lineWidth = 1;
            lit.opacity = 0;
            [tile addSublayer:lit];
            t.lit = lit;
            if (up)
                CGPathRelease(up);
            NSImage* sym = [NSImage imageWithSystemSymbolName:icon.length ? icon : @"square.grid.2x2"
                                     accessibilityDescription:nil];
            auto drawn = [&](NSColor* c) {
                return [[sym imageWithSymbolConfiguration:
                                 [[NSImageSymbolConfiguration configurationWithPointSize:17 weight:NSFontWeightSemibold]
                                     configurationByApplyingConfiguration:[NSImageSymbolConfiguration
                                                                              configurationWithHierarchicalColor:c]]]
                    layerContentsForContentsScale:2];
            };
            glyph.contents = drawn(ink);
            CALayer* glit = [CALayer layer];
            glit.frame = tile.bounds;
            glit.contentsGravity = kCAGravityCenter;
            glit.contentsScale = 2;
            glit.contents = drawn(active_ink ?: ink);
            glit.opacity = 0;
            t.glyph_lit = glit;
            [tile addSublayer:glit];
        } else {
            NSColor* base = parse_color(str(r, P::iconColor, @"")) ?: NSColor.controlAccentColor;
            base = [base colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
            CAGradientLayer* g = [CAGradientLayer layer];
            g.frame = tile.bounds;
            g.cornerRadius = tr;
            g.cornerCurve = kCACornerCurveContinuous;
            g.colors = @[
                (id)[base blendedColorWithFraction:0.25 ofColor:NSColor.whiteColor].CGColor,
                (id)[base blendedColorWithFraction:0.15 ofColor:NSColor.blackColor].CGColor
            ];
            [tile addSublayer:g];
            NSImage* sym = [NSImage imageWithSystemSymbolName:icon.length ? icon : @"square.grid.2x2"
                                     accessibilityDescription:nil];
            sym = [sym imageWithSymbolConfiguration:
                           [[NSImageSymbolConfiguration configurationWithPointSize:19 weight:NSFontWeightSemibold]
                               configurationByApplyingConfiguration:[NSImageSymbolConfiguration
                                                                        configurationWithHierarchicalColor:ink]]];
            glyph.contents = [sym layerContentsForContentsScale:2];
        }
        if (picture && tile_shape.length) {
            CGPathRef path2 = box_path(tile_shape, tile.bounds.size);
            CGAffineTransform flip = CGAffineTransformMake(1, 0, 0, -1, 0, tile.bounds.size.height);
            CGPathRef up = path2 ? CGPathCreateCopyByTransformingPath(path2, &flip) : nullptr;
            if (path2)
                CGPathRelease(path2);
            CAShapeLayer* m = (CAShapeLayer*)still([CAShapeLayer layer]);
            m.frame = tile.bounds;
            m.path = up;
            if (up)
                CGPathRelease(up);
            tile.mask = m;
            tile.shadowOpacity = 0;
            glyph.cornerRadius = 0;
            for (CALayer* x in tile.sublayers)
                x.cornerRadius = 0;
        }
        if (t.glyph_lit)
            [tile insertSublayer:glyph below:t.glyph_lit];
        else
            [tile addSublayer:glyph];
        t.glyph = glyph;
        [t.layer addSublayer:tile];
        t.tile = tile;
        CALayer* dot = [CALayer layer];
        dot.bounds = tile_shape.length ? CGRectMake(0, 0, 16, 2) : CGRectMake(0, 0, 4, 4);
        dot.cornerRadius = tile_shape.length ? 0 : 2;
        dot.backgroundColor = tile_shape.length ? (tile_active ?: NSColor.controlAccentColor).CGColor
                                                : [fg colorWithAlphaComponent:0.75].CGColor;
        dot.position = CGPointMake(kTile / 2, -6);
        [t.layer addSublayer:dot];
        t.dot = dot;
        [bar.layer addSublayer:t.layer];
        [bar.tiles addObject:t];
    }
    if (!engine)
        return;
    if (part >= 0 && part != 2)
        separator();
    RXTile* t = [[RXTile alloc] initWithFrame:NSMakeRect(0, 0, kTile, kTile)];
    t.kind = kTileSearch;
    t.title = tr(@"Search or open a page");
    CALayer* tile = [CALayer layer];
    tile.anchorPoint = CGPointMake(0.5, 0);
    tile.bounds = CGRectMake(0, 0, kTile, kTile);
    tile.position = CGPointMake(kTile / 2, 0);
    tile.shadowOpacity = 0.25, tile.shadowRadius = 3, tile.shadowOffset = CGSizeMake(0, -1);
    CAGradientLayer* g = [CAGradientLayer layer];
    g.frame = tile.bounds;
    g.cornerRadius = 10;
    g.cornerCurve = kCACornerCurveContinuous;
    NSColor* fill =
        [parse_color(search_color) ?: NSColor.controlAccentColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    g.colors = @[
        (id)[fill blendedColorWithFraction:0.2 ofColor:NSColor.whiteColor].CGColor,
        (id)[fill blendedColorWithFraction:0.12 ofColor:NSColor.blackColor].CGColor
    ];
    [tile addSublayer:g];
    CALayer* glyph = [CALayer layer];
    glyph.frame = tile.bounds;
    glyph.contentsGravity = kCAGravityCenter;
    glyph.contentsScale = 2;
    NSImage* plus = [[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:nil]
        imageWithSymbolConfiguration:
            [[NSImageSymbolConfiguration configurationWithPointSize:19 weight:NSFontWeightBold]
                configurationByApplyingConfiguration:[NSImageSymbolConfiguration
                                                         configurationWithHierarchicalColor:NSColor.whiteColor]]];
    glyph.contents = [plus layerContentsForContentsScale:2];
    [tile addSublayer:glyph];
    [t.layer addSublayer:tile];
    t.tile = tile;
    [bar.layer addSublayer:t.layer];
    [bar.tiles addObject:t];
}

CGFloat bar_width(RXSlot* slot) {
    NSArray<RXTile*>* tiles = slot.bar.tiles;
    CGFloat w = 2 * kPillPad + (tiles.count ? (tiles.count - 1) * kTileGap : 0);
    for (RXTile* t in tiles)
        w += base_width(t);
    return w;
}

void layout_bar(RXSlot* slot, id host, NSRect frame) {
    slot.bar.host = host;
    RXAppBar* bar = slot.bar;
    if (!NSEqualRects(bar.frame, frame)) {
        bar.frame = frame;
        bar.laid_out = nil;
    }
    NSUInteger n = bar.tiles.count;
    CGFloat full = bar_width(slot);
    CGFloat b = MIN(1.0, (frame.size.width - 16) / MAX(full, 1.0));
    bar.base = b;
    CGFloat tile = kTile * b, gap = kTileGap * b, pad = kPillPad * b;
    CGFloat w = full * b, h = tile + 2 * pad;
    CGFloat x = round((frame.size.width - w) / 2), y = round((frame.size.height - h) / 2);
    RXDoc* shown = active_member(slot);
    NSString* sig =
        [NSString stringWithFormat:@"%@ %lu %@", NSStringFromSize(frame.size), (unsigned long)n, shown.path];
    if ([sig isEqualToString:bar.laid_out])
        return;
    bar.laid_out = sig;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    bar.layer.bounds = CGRectMake(0, 0, frame.size.width, frame.size.height);
    bar.layer.position = CGPointMake(NSMidX(frame), NSMidY(frame));
    bar.pill.frame = CGRectMake(x, y, w, h);
    bar.pill.cornerRadius = bar.pill_shape.length ? 0 : bar.pill_radius * b;
    shape_pill(bar);
    RXDoc* active = shown;
    CGFloat at = x + pad;
    for (NSUInteger i = 0; i < n; i++) {
        RXTile* t = bar.tiles[i];
        CGFloat tw = base_width(t) * b;
        t.frame = NSMakeRect(at, y + pad, tw, tile);
        at += tw + gap;
        t.tile.position = CGPointMake(tw / 2, t.kind == kTileSeparator ? tile * 0.2 : 0);
        t.tile.transform = CATransform3DMakeScale(b, b, 1);
        t.dot.position = CGPointMake(tw / 2, -6 * b);
        bool on = t.path && [t.path isEqualToString:active.path];
        t.dot.opacity = on ? 1 : 0;
        if (t.lit) {
            t.lit.opacity = on ? 1 : 0;
            t.glyph.opacity = on && t.glyph_lit ? 0 : 1;
            t.glyph_lit.opacity = on ? 1 : 0;
        }
    }
    [CATransaction commit];
    if (!isnan(bar.mouse_x))
        magnify(bar, 0);
}
