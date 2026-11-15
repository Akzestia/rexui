// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

static constexpr CGFloat kFloatH = 64, kFlare = 18, kNear = 96, kEdge = 24;
static constexpr CGFloat kGrowRoom = 40;
static constexpr double kShowMs = 320, kHideMs = 200, kHideAfter = 0.35, kWaveStep = 0.035;

@interface RXFloatBar : RXLayerHost
@property(nonatomic) RXSlot* slot;
@property(nonatomic, strong) CAShapeLayer* fill;
@property(nonatomic) double progress, target;
@property(nonatomic) double slide_from, slide_to, slide_t0, slide_len;
@property(nonatomic) const double* slide_curve;
@property(nonatomic) NSUInteger slide_gen;
@property(nonatomic) bool near;
@property(nonatomic) NSUInteger leaving;
@property(nonatomic) CGFloat fill_w;
@end

static double shown_progress(RXFloatBar* f);

@interface RXFloatBar () {
    __weak RXSlot* _w_slot;
}
@end
@implementation RXFloatBar {
    bool _pressed;
}
- (RXSlot*)slot {
    return _w_slot;
}
- (void)setSlot:(RXSlot*)v {
    _w_slot = v;
}
- (id)hitTest:(NSPoint)p {
    if (shown_progress(self) < 0.5 || !self.slot.bar)
        return nil;
    NSPoint q = [self convertPoint:p fromView:self.superview];
    if (fabs(q.x - self.bounds.size.width / 2) > self.fill_w / 2)
        return nil;
    return NSPointInRect(q, self.slot.bar.frame) ? self : nil;
}
- (NSPoint)at:(NSEvent*)e {
    return [self convertPoint:e.locationInWindow fromView:nil];
}
- (void)mouseDown:(NSEvent*)e {
    _pressed = true;
    bar_down(self.slot.bar, [self at:e]);
}
- (void)mouseDragged:(NSEvent*)e {
    if (_pressed)
        bar_dragged(self.slot.bar, [self at:e]);
}
- (void)mouseUp:(NSEvent*)e {
    if (!_pressed)
        return;
    _pressed = false;
    bar_up(self.slot.bar, [self at:e]);
}
@end

static NSHashTable<RXFloatBar*>* g_floats;

bool is_float_bar_view(id v) {
    return [v isKindOfClass:RXFloatBar.class];
}
RXLayerHost* float_bar_under(NSWindow* w, NSPoint win) {
    for (RXFloatBar* f in g_floats) {
        if (f.window == w && f.superview && !f.hiddenOrHasHiddenAncestor &&
            [f hitTest:[f.superview convertPoint:win fromView:nil]])
            return f;
    }
    return nil;
}
NSArray<NSDictionary*>* float_bar_menu(id v, NSPoint win) {
    if (![v isKindOfClass:RXFloatBar.class])
        return nil;
    RXFloatBar* f = (RXFloatBar*)v;
    return f.slot.bar ? bar_menu(f.slot.bar, [f convertPoint:win fromView:nil]) : nil;
}

static NSString* pin_key(RXSlot* slot) {
    return [@"bar pinned " stringByAppendingString:slot.key];
}
static bool pinned(RXSlot* slot) {
    return [g_state boolForKey:pin_key(slot)];
}

bool is_float_bar(RXSlot* slot) {
    return [slot.key hasPrefix:@"group:"] &&
        [str((slot.lead ?: slot.members.firstObject).root, @"bar", @"bottom") isEqualToString:@"float"];
}

static void wave(RXFloatBar* f) {
    NSArray<RXTile*>* tiles = f.slot.bar.tiles;
    double mid = (tiles.count - 1) / 2.0, now = CACurrentMediaTime();
    for (NSUInteger i = 0; i < tiles.count; i++) {
        CALayer* l = tiles[i].layer;
        CASpringAnimation* a = [CASpringAnimation animationWithKeyPath:@"transform"];
        a.fromValue =
            [NSValue valueWithCATransform3D:CATransform3DScale(CATransform3DMakeTranslation(0, -14, 0), 0.4, 0.4, 1)];
        a.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
        a.damping = 14, a.stiffness = 220, a.mass = 1;
        a.duration = a.settlingDuration;
        CABasicAnimation* o = [CABasicAnimation animationWithKeyPath:@"opacity"];
        o.fromValue = @0, o.toValue = @1, o.duration = 0.16;
        for (CAAnimation* x in @[a, o]) {
            x.beginTime = now + fabs(i - mid) * kWaveStep;
            x.fillMode = kCAFillModeBackwards;
            [l addAnimation:x forKey:x == a ? @"wave" : @"wave-in"];
        }
    }
}

static double shown_progress(RXFloatBar* f) {
    if (f.slide_len <= 0)
        return f.progress;
    double t = MIN(1, MAX(0, (CACurrentMediaTime() - f.slide_t0) / f.slide_len));
    return f.slide_from + (f.slide_to - f.slide_from) * curve_at(f.slide_curve, t);
}

struct Look {
    CGPathRef path;
    CGAffineTransform bar;
    float alpha;
};
static Look look_at(RXFloatBar* f, double progress) {
    CGFloat W = f.bounds.size.width, H = f.bounds.size.height, p = MAX(0, MIN(1, progress));
    CGFloat vis = MAX(1, round(H * p));
    CGFloat fw = MIN(W, f.fill_w > 0 ? f.fill_w : W);
    Look l;
    l.path = drawer_path(NSMakeRect(round((W - fw) / 2), 0, fw, vis), kFlare, f.fill.contentsAreFlipped, H);
    CGPoint from = [f convertPointToLayer:NSZeroPoint], to = [f convertPointToLayer:NSMakePoint(0, H - vis)];
    l.bar = CGAffineTransformMakeTranslation(to.x - from.x, to.y - from.y);
    l.alpha = (float)MIN(1, p * 1.5);
    return l;
}

static void draw(RXFloatBar* f) {
    CAShapeLayer* fill = f.fill;
    if (!CGRectEqualToRect(fill.frame, f.layer.bounds))
        fill.frame = f.layer.bounds;
    Look l = look_at(f, f.progress);
    fill.path = l.path;
    CGPathRelease(l.path);
    CALayer* bar = f.slot.bar.layer;
    if (!CGAffineTransformEqualToTransform(bar.affineTransform, l.bar))
        bar.affineTransform = l.bar;
    if (f.alphaValue != l.alpha)
        f.alphaValue = l.alpha;
    bool hide = f.progress <= 0.001 && f.slide_len <= 0;
    if (f.hidden != hide)
        f.hidden = hide;
}

static void slide_stop(RXFloatBar* f) {
    if (f.slide_len <= 0)
        return;
    f.progress = shown_progress(f);
    f.slide_len = 0;
    f.slide_gen++;
    [f.fill removeAnimationForKey:@"rexui.float.path"];
    [f.slot.bar.layer removeAnimationForKey:@"rexui.float.t"];
    [f.layer removeAnimationForKey:@"rexui.float.o"];
}

static constexpr int k_samples = 20;
static void set_target(RXFloatBar* f, NSView* chrome) {
    double target = pinned(f.slot) || f.near || f.slot.searching ? 1 : 0;
    if (target == f.target && (f.slide_len > 0 || f.progress == target))
        return;
    f.target = target;
    slide_stop(f);
    double from = f.progress, ms = (target > from ? kShowMs : kHideMs) * fabs(target - from);
    if (target > from && from < 0.05)
        wave(f);
    if (ms <= 0 || !chrome || f.bounds.size.height <= 0) {
        f.progress = target;
        draw(f);
        return;
    }
    const double* curve = target > from ? kSpatial : kStandard;
    NSMutableArray *paths = [NSMutableArray array], *bars = [NSMutableArray array], *alphas = [NSMutableArray array],
                   *times = [NSMutableArray array];
    for (int k = 0; k <= k_samples; k++) {
        double x = (double)k / k_samples;
        Look l = look_at(f, from + (target - from) * curve_at(curve, x));
        [paths addObject:(__bridge_transfer id)l.path];
        [bars addObject:[NSValue valueWithCATransform3D:CATransform3DMakeAffineTransform(l.bar)]];
        [alphas addObject:@(l.alpha)];
        [times addObject:@(x)];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    f.slide_from = from, f.slide_to = target, f.slide_t0 = CACurrentMediaTime(), f.slide_len = ms / 1000,
    f.slide_curve = curve;
    f.progress = target;
    draw(f);
    NSArray* layers = @[f.fill, f.slot.bar.layer ?: NSNull.null, f.layer];
    NSArray *keys = @[@"path", @"transform", @"opacity"],
            *names = @[@"rexui.float.path", @"rexui.float.t", @"rexui.float.o"];
    NSArray* values = @[paths, bars, alphas];
    for (NSUInteger i = 0; i < 3; i++) {
        if (layers[i] == NSNull.null)
            continue;
        CAKeyframeAnimation* a = [CAKeyframeAnimation animationWithKeyPath:keys[i]];
        a.values = values[i];
        a.keyTimes = times;
        a.duration = ms / 1000;
        a.calculationMode = kCAAnimationLinear;
        [(CALayer*)layers[i] addAnimation:a forKey:names[i]];
    }
    [CATransaction commit];
    NSUInteger gen = ++f.slide_gen;
    __weak RXFloatBar* weak = f;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        RXFloatBar* f2 = weak;
        if (!f2 || f2.slide_gen != gen)
            return;
        f2.slide_len = 0;
        draw(f2);
    });
}

void place_float_bar(RXSlot* slot, NSView* chrome) {
    RXFloatBar* f = (RXFloatBar*)slot.floating;
    if (!is_float_bar(slot) || !chrome) {
        [f removeFromSuperview];
        slot.floating = nil;
        return;
    }
    if (!f) {
        f = [[RXFloatBar alloc] initWithFrame:NSZeroRect];
        f.slot = slot;
        f.fill = [CAShapeLayer layer];
        f.fill.actions =
            @{@"path": NSNull.null, @"frame": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null};
        [f.layer addSublayer:f.fill];
        f.progress = f.target = 0;
        f.hidden = YES;
        slot.floating = f;
        if (!g_floats)
            g_floats = [NSHashTable weakObjectsHashTable];
        [g_floats addObject:f];
    }
    RXRoot* host = ui_root(chrome);
    [host addHost:f band:kBandFloatBar];
    build_bar(slot);
    RXAppBar* bar = slot.bar;
    if (bar.layer.superlayer != f.layer)
        [f.layer addSublayer:bar.layer];
    bar.pill.hidden = YES;
    CGFloat inner = bar_width(slot) + 16;
    CGFloat W = MIN(inner + 2 * kFlare + 2 * kGrowRoom, host.bounds.size.width), H = kFloatH;
    if (isnan(slot.bar.mouse_x) || f.fill_w <= 0)
        f.fill_w = MIN(W, inner + 2 * kFlare);
    NSRect fr = NSMakeRect(round(NSMidX(host.bounds) - W / 2), NSMaxY(host.bounds) - H, W, H);
    if (!NSEqualRects(f.frame, fr))
        f.frame = fr;
    layout_bar(slot, f, NSMakeRect(kFlare + kGrowRoom, 2, MAX(0, W - 2 * kFlare - 2 * kGrowRoom), H - 2));
    f.fill.fillColor =
        (parse_color(str((slot.lead ?: slot.members.firstObject).root, @"barColor", @"")) ?: g_theme.bg).CGColor;
    set_target(f, chrome);
    draw(f);
}

void float_bar_pointer(NSEvent* e) {
    NSWindow* ew = e.window;
    if (e.type != NSEventTypeMouseMoved)
        return;
    for (RXFloatBar* f in g_floats) {
        if (!f.window || f.window != ew)
            continue;
        id top = f.superview ? [f hitTest:[f.superview convertPoint:e.locationInWindow fromView:nil]] : nil;
        NSPoint q = [f at:e];
        bar_moved(f.slot.bar, top == f && NSPointInRect(q, f.slot.bar.frame) ? q : NSMakePoint(NAN, NAN));
        NSView* host = f.superview;
        NSPoint p = [host convertPoint:e.locationInWindow fromView:nil];
        NSRect zone = NSInsetRect(f.frame, -kNear, 0);
        double shown = shown_progress(f);
        zone.origin.y -= shown > 0.5 ? kNear : 0;
        zone.size.height += shown > 0.5 ? kNear : 0;
        if (shown <= 0.5)
            zone = NSMakeRect(NSMinX(zone), NSMaxY(host.bounds) - kEdge, zone.size.width, kEdge);
        bool near =
            NSPointInRect(p, zone) && !panes_has_pointer(ew, e.locationInWindow) && !debug_pointer_near_devtools(e);
        if (near) {
            f.leaving++;
            if (!f.near) {
                f.near = true;
                set_target(f, chrome_of(f.window));
            }
        } else if (f.near) {
            NSUInteger gen = ++f.leaving;
            __weak RXFloatBar* weak = f;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHideAfter * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               RXFloatBar* f2 = weak;
                               if (!f2 || f2.leaving != gen)
                                   return;
                               f2.near = false;
                               if (f2.window)
                                   set_target(f2, chrome_of(f2.window));
                           });
        }
    }
}

void float_bar_grow(RXSlot* slot, CGFloat grown, double seconds) {
    RXFloatBar* f = (RXFloatBar*)slot.floating;
    if (!f)
        return;
    CGFloat fw = MIN(f.bounds.size.width, round(grown + 16 + 2 * kFlare));
    if (fw == f.fill_w)
        return;
    f.fill_w = fw;
    if (f.slide_len > 0 || f.hidden)
        return;
    CAShapeLayer* fill = f.fill;
    id from = (id)((CAShapeLayer*)fill.presentationLayer ?: fill).path;
    draw(f);
    if (seconds > 0 && from) {
        CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"path"];
        a.fromValue = from;
        a.toValue = (id)fill.path;
        a.duration = seconds;
        [fill addAnimation:a forKey:@"grow"];
    }
}

void float_bar_refresh(RXSlot* slot) {
    RXFloatBar* f = (RXFloatBar*)slot.floating;
    if (f.window)
        set_target(f, chrome_of(f.window));
}

void float_bar_toggle(RXSlot* slot) {
    [g_state setBool:!pinned(slot) forKey:pin_key(slot)];
    RXFloatBar* f = (RXFloatBar*)slot.floating;
    if (f.window)
        set_target(f, chrome_of(f.window));
}
