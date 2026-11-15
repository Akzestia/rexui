// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include <string>
#include "base/trace.h"
#include "rex/rex.h"

static CAMediaTimingFunction* timing(const double c[4]) {
    return [CAMediaTimingFunction functionWithControlPoints:c[0]:c[1]:c[2]:c[3]];
}

static bool is_spring(const double* c) {
    return c && c[0] < 0;
}

static CABasicAnimation* animation(NSString* path, double ms, const double* curve) {
    if (is_spring(curve)) {
        CASpringAnimation* s = [CASpringAnimation animationWithKeyPath:path];
        s.mass = 1;
        s.stiffness = MAX(1, curve[1]);
        s.damping = MAX(0, curve[2]);
        s.duration = s.settlingDuration;
        return s;
    }
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:path];
    a.duration = ms / 1000;
    a.timingFunction = timing(curve);
    return a;
}

@interface RXFoldMask : CALayer
@end
@implementation RXFoldMask
@end
@interface RXWipeMask : CAShapeLayer
@end
@implementation RXWipeMask
@end
@interface RXAppearMask : CALayer
@end
@implementation RXAppearMask
@end

bool mask_passing(CALayer* m) {
    return [m isKindOfClass:RXFoldMask.class] || [m isKindOfClass:RXWipeMask.class] ||
        [m isKindOfClass:RXAppearMask.class];
}

static CALayer* passing_of(CALayer* l, CALayer** holder) {
    CALayer* m = l.mask;
    if (m && mask_passing(m))
        return *holder = l, m;
    if (m && m.mask && mask_passing(m.mask))
        return *holder = m, m.mask;
    return *holder = nil, nil;
}

void mask_set_own(CALayer* l, CALayer* own) {
    CALayer *holder = nil, *passing = passing_of(l, &holder);
    CALayer* was = l.mask && l.mask != passing ? l.mask : nil;
    if (was == own && (!own || own.mask == passing))
        return;
    if (was && was != own)
        was.mask = nil;
    if (own) {
        if (passing && own.mask != passing)
            own.mask = passing;
        if (l.mask != own)
            l.mask = own;
    } else if (l.mask != passing) {
        l.mask = passing;
    }
}

static bool passing_on(CALayer* l, CALayer* m) {
    CALayer* holder = nil;
    if (passing_of(l, &holder))
        return false;
    if (l.mask)
        l.mask.mask = m;
    else
        l.mask = m;
    return true;
}
static void passing_off(CALayer* l, CALayer* m) {
    if (l.mask == m)
        l.mask = nil;
    else if (l.mask.mask == m)
        l.mask.mask = nil;
}
static CGRect passing_rect(CALayer* l) {
    return l.mask && !mask_passing(l.mask) ? l.mask.bounds : l.bounds;
}

@interface RXGlideEnd : NSObject <CAAnimationDelegate>
@property(nonatomic, copy) void (^done)(void);
@end
@implementation RXGlideEnd
- (void)animationDidStop:(CAAnimation*)a finished:(BOOL)finished {
    if (finished && self.done)
        self.done();
}
@end

static const double kEaseCubic[4] = {0.65, 0, 0.35, 1};

void ca_glide(CALayer* l, NSString* path, id from, double ms, const double* curve, void (^done)(void)) {
    CABasicAnimation* a = animation(path, ms, curve ?: kEaseCubic);
    a.fromValue = from;
    a.toValue = [l valueForKeyPath:path];
    if (done) {
        RXGlideEnd* end = [RXGlideEnd new];
        end.done = done;
        a.delegate = end;
    }
    [l addAnimation:a forKey:[@"rexui." stringByAppendingString:path]];
}

void move_animate(RXNode* n, CALayer* l, CATransform3D from, double ms) {
    CABasicAnimation* a = animation(@"transform", ms, easing_curve(n));
    a.fromValue = [NSValue valueWithCATransform3D:from];
    a.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    a.additive = YES;
    [l addAnimation:a forKey:@"rexui.move"];
    if (n.fx)
        box_fx_follow(n, @"rexui.move");
}

static void glide(CALayer* l, NSString* path, id from, id to, double ms, const double* curve) {
    CABasicAnimation* a = animation(path, ms, curve);
    a.fromValue = from;
    a.toValue = to;
    [l addAnimation:a forKey:[@"rexui." stringByAppendingString:path]];
}

bool g_panes_instant;

static char k_retargeted;
void deco_retargeted(RXNode* n) {
    objc_setAssociatedObject(n, &k_retargeted, @(CACurrentMediaTime()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
bool deco_lands(RXNode* n) {
    if (!n.doc.root || !is_elem(n.doc.root, E::Panes))
        return false;
    for (int i = 0; n && i < 32; i++, n = n.parent) {
        if (NSNumber* t = objc_getAssociatedObject(n, &k_retargeted))
            return CACurrentMediaTime() - t.doubleValue < 0.25;
    }
    return false;
}

CGRect layer_frame(RXNode* n, CALayer* l) {
    if (!n.transformed)
        return l.frame;
    CGSize s = l.bounds.size;
    CGPoint p = l.position, a = l.anchorPoint;
    return CGRectMake(p.x - s.width * a.x, p.y - s.height * a.y, s.width, s.height);
}
static void put_frame(RXNode* n, CALayer* l, CGRect f) {
    if (!n.transformed) {
        l.frame = f;
        return;
    }
    CGPoint a = l.anchorPoint;
    l.bounds = CGRectMake(l.bounds.origin.x, l.bounds.origin.y, f.size.width, f.size.height);
    l.position = CGPointMake(f.origin.x + f.size.width * a.x, f.origin.y + f.size.height * a.y);
}

void apply_transform(RXNode* n) {
    CALayer* l = n.layer;
    if (!l)
        return;
    const double x = num(n, P::transform_x, 0), y = num(n, P::transform_y, 0), sc = num(n, P::transform_scale, 1),
                 r = num(n, P::transform_rotation, 0);
    const bool any = x != 0 || y != 0 || sc != 1 || r != 0;
    if (!any && !n.transformed)
        return;
    CATransform3D to = CATransform3DMakeTranslation(x, y, 0);
    to = CATransform3DRotate(to, r * M_PI / 180, 0, 0, 1);
    to = CATransform3DScale(to, sc, sc, 1);
    CATransform3D from = ((CALayer*)l.presentationLayer ?: l).transform;
    n.transformed = any;
    l.transform = to;
    if (n.fx)
        box_fx_sync(n);
    const double ms = num(n, P::animate, 0);
    if (ms > 0 && node_on_screen(n) && !CATransform3DEqualToTransform(from, to) && !deco_lands(n)) {
        glide(l, @"transform", [NSValue valueWithCATransform3D:from], [NSValue valueWithCATransform3D:to], ms,
              easing_curve(n));
        if (n.fx)
            box_fx_follow(n, @"rexui.transform");
    }
}

void set_frame(RXNode* n, CALayer* l, NSRect f) {
    double ms = num(n, P::animate, 0);
    if (g_panes_instant && n.doc.root && is_elem(n.doc.root, E::Panes))
        ms = 0;
    if (g_row_recycled)
        ms = 0;
    if (ms > 0 && deco_lands(n))
        ms = 0;
    NSString* easing = str(n, P::easing, @"");
    if ([easing isEqualToString:@"rex"]
        && rex_easing_move((__bridge const void*)l, f, ms > 0 && !CGRectIsEmpty(l.frame))) {
        if (n.fx)
            box_fx_placed(n, f);
        return;
    }
    CALayer* now = ms > 0 ? (l.presentationLayer ?: l) : l;
    CGPoint from_pos = now.position;
    CGRect from_bounds = now.bounds;
    bool first = CGRectIsEmpty(l.bounds);
    put_frame(n, l, f);
    box_fx_placed(n, f);
    if (ms <= 0 || first || !node_on_screen(n)) {
        [l removeAnimationForKey:@"rexui.position"];
        [l removeAnimationForKey:@"rexui.bounds"];
        if (n.fx)
            box_fx_follow(n, @"rexui.position"), box_fx_follow(n, @"rexui.bounds");
        return;
    }
    const double* fn = easing_curve(n);
    if (!CGPointEqualToPoint(from_pos, l.position))
        glide(l, @"position", [NSValue valueWithPoint:from_pos], [NSValue valueWithPoint:l.position], ms, fn);
    if (!CGRectEqualToRect(from_bounds, l.bounds))
        glide(l, @"bounds", [NSValue valueWithRect:from_bounds], [NSValue valueWithRect:l.bounds], ms, fn);
    if (n.fx)
        box_fx_follow(n, @"rexui.position"), box_fx_follow(n, @"rexui.bounds");
}

void set_alpha(RXNode* n, CALayer* l, CGFloat a) {
    double ms = num(n, P::opacityAnimation, 0);
    if (ms <= 0)
        ms = num(n, P::animate, 0);
    if (ms > 0 && deco_lands(n))
        ms = 0;
    if (ms <= 0 || CGRectIsEmpty(l.frame) || !node_on_screen(n)) {
        [l removeAnimationForKey:@"rexui.opacity"];
        l.opacity = a;
        if (n.fx)
            box_fx_sync(n), box_fx_follow(n, @"rexui.opacity");
        return;
    }
    float from = ((CALayer*)l.presentationLayer ?: l).opacity;
    l.opacity = a;
    static const double kEaseInOut[4] = {0.42, 0, 0.58, 1};
    const double* c = easing_curve(n);
    glide(l, @"opacity", @(from), @(a), ms, is_spring(c) || c == kExpo ? c : kEaseInOut);
    if (n.fx)
        box_fx_sync(n), box_fx_follow(n, @"rexui.opacity");
}

const double* easing_curve(RXNode* n) {
    NSString* e = str(n, P::easing, @"");
    if ([e hasPrefix:@"bezier "]) {
        struct Slot {
            NSString* text;
            double c[4];
        };
        static Slot slots[8];
        static unsigned next;
        for (Slot& s : slots)
            if (s.text && [s.text isEqualToString:e])
                return s.c;
        Slot& s = slots[next++ % 8];
        s.text = [e copy];
        s.c[0] = 0, s.c[1] = 0, s.c[2] = 1, s.c[3] = 1;
        sscanf(e.UTF8String, "bezier %lf %lf %lf %lf", &s.c[0], &s.c[1], &s.c[2], &s.c[3]);
        return s.c;
    }
    if ([e hasPrefix:@"spring "]) {
        struct Slot {
            NSString* text;
            double c[4];
        };
        static Slot slots[8];
        static unsigned next;
        for (Slot& s : slots)
            if (s.text && [s.text isEqualToString:e])
                return s.c;
        Slot& s = slots[next++ % 8];
        s.text = [e copy];
        s.c[0] = -1, s.c[1] = 300, s.c[2] = 30, s.c[3] = 0;
        sscanf(e.UTF8String, "spring %lf %lf", &s.c[1], &s.c[2]);
        return s.c;
    }
    return [e isEqualToString:@"standard"] ? kStandard : [e isEqualToString:@"expo"] ? kExpo : kSpatial;
}

void appear_when_shown(RXNode* n) {
    static NSMapTable<RXNode*, NSNumber*>* waiting;
    static NSTimer* timer;
    auto play = [](RXNode* m) {
        m.appear_due = false;
        __weak RXNode* weak = m;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (RXNode* x = weak)
                appear_play(x);
        });
    };
    if (node_on_screen(n)) {
        [waiting removeObjectForKey:n];
        return play(n);
    }
    if (node_clipped_away(n)) {
        [waiting removeObjectForKey:n];
        n.appear_due = false;
        return;
    }
    if (!waiting)
        waiting = [NSMapTable weakToStrongObjectsMapTable];
    if (![waiting objectForKey:n])
        [waiting setObject:@(CACurrentMediaTime()) forKey:n];
    if (timer)
        return;
    timer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                            repeats:YES
                                              block:^(NSTimer* t) {
                                                  double now = CACurrentMediaTime();
                                                  for (RXNode* m in waiting.keyEnumerator.allObjects) {
                                                      if (!m.appear_due || !m.doc
                                                          || now - [[waiting objectForKey:m] doubleValue] > 3)
                                                          [waiting removeObjectForKey:m];
                                                      else if (node_on_screen(m))
                                                          [waiting removeObjectForKey:m], play(m);
                                                      else if (node_clipped_away(m))
                                                          [waiting removeObjectForKey:m], m.appear_due = false;
                                                  }
                                                  if (!waiting.count)
                                                      [t invalidate], timer = nil;
                                              }];
}

bool disappear_play(RXNode* n, void (^done)(void)) {
    CALayer* l = n.layer;
    NSString* kind = l ? str(n, P::disappear, @"") : @"";
    if (!kind.length || !node_on_screen(n))
        return false;
    const double set_ms = num(n, P::disappearDuration, 0);
    float o = ((CALayer*)l.presentationLayer ?: l).opacity;
    CALayer* holder = nil;
    if ([kind isEqualToString:@"wipe"] && passing_of(l, &holder))
        kind = @"fade";
    [CATransaction begin];
    __block RXWipeMask* wipe = nil;
    [CATransaction setCompletionBlock:^{
        if (wipe)
            passing_off(l, wipe);
        done();
    }];
    if ([kind isEqualToString:@"flicker"]) {
        CAKeyframeAnimation* a = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        a.values = @[@(o), @(0.5 * o), @0, @(0.5 * o), @0, @(0.5 * o), @0, @0];
        a.keyTimes = @[@0, @0.59, @0.6, @0.79, @0.8, @0.89, @0.9, @1];
        a.duration = (set_ms > 0 ? set_ms : 500) / 1000;
        a.fillMode = kCAFillModeForwards;
        a.removedOnCompletion = NO;
        [l addAnimation:a forKey:@"rexui.disappear"];
    } else if ([kind isEqualToString:@"wipe"]) {
        CGRect b = passing_rect(l);
        RXWipeMask* mask = (RXWipeMask*)still([RXWipeMask layer]);
        CGPathRef whole = CGPathCreateWithRect(b, nullptr),
                  none = CGPathCreateWithRect(CGRectMake(CGRectGetMaxX(b), b.origin.y, 0, b.size.height), nullptr);
        mask.path = none;
        if (passing_on(l, mask))
            wipe = mask;
        CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"path"];
        a.fromValue = (__bridge id)whole;
        a.toValue = (__bridge id)none;
        a.duration = (set_ms > 0 ? set_ms : 420) / 1000;
        a.timingFunction = timing(kExpo);
        [mask addAnimation:a forKey:@"rexui.disappear"];
        if (n.fx)
            box_fx_fade(n, @"rexui.disappear", o, 0, a.duration, 0, a.timingFunction);
        CGPathRelease(whole);
        CGPathRelease(none);
    } else {
        CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.fromValue = @(o), a.toValue = @0;
        a.duration = (set_ms > 0 ? set_ms : 240) / 1000;
        a.timingFunction = timing(kExpo);
        a.fillMode = kCAFillModeForwards;
        a.removedOnCompletion = NO;
        [l addAnimation:a forKey:@"rexui.disappear"];
    }
    if (n.fx && ![kind isEqualToString:@"wipe"])
        box_fx_follow(n, @"rexui.disappear");
    [CATransaction commit];
    return true;
}

void disappear_stop(RXNode* n) {
    CALayer* l = n.layer;
    [l removeAnimationForKey:@"rexui.disappear"];
    if (n.fx)
        box_fx_follow(n, @"rexui.disappear"), box_fx_sync(n);
    CALayer* holder = nil;
    if (CALayer* m = passing_of(l, &holder); [m isKindOfClass:RXWipeMask.class])
        passing_off(l, m);
}

void appear_hold(RXNode* n) {
    if (CALayer* l = n.layer; l && str(n, P::appear, @"").length && ![l animationForKey:@"rexui.appear"]) {
        CABasicAnimation* h = [CABasicAnimation animationWithKeyPath:@"opacity"];
        h.fromValue = @0, h.toValue = @0;
        h.duration = 0.25;
        [l addAnimation:h forKey:@"rexui.appear.hold"];
    }
    for (RXNode* c in n.children)
        appear_hold(c);
}

void appear_play(RXNode* n) {
    CALayer* l = n.layer;
    if (!l)
        return;
    [l removeAnimationForKey:@"rexui.appear.hold"];
    if (is_elem(n, E::Text) && num(n, P::scramble, 0) > 0)
        text_scramble(n);
    NSString* kind = str(n, P::appear, @"");
    if (!kind.length)
        return;
    double delay = MAX(0, num(n, P::appearDelay, 0)) / 1000, ms = num(n, P::appearDuration, 0);
    CFTimeInterval begin = [l convertTime:CACurrentMediaTime() fromLayer:nil] + delay;
    float o = l.opacity;
    if ([kind isEqualToString:@"flicker"]) {
        CAKeyframeAnimation* a = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        a.values = @[@0, @(0.5 * o), @0, @(0.5 * o), @0, @(0.5 * o), @(o), @(o)];
        a.keyTimes = @[@0, @0.10, @0.11, @0.20, @0.21, @0.40, @0.41, @1];
        a.duration = (ms > 0 ? ms : 500) / 1000;
        a.beginTime = begin;
        a.fillMode = kCAFillModeBackwards;
        [l addAnimation:a forKey:@"rexui.appear"];
        if (n.fx)
            box_fx_follow(n, @"rexui.appear");
    } else if ([kind isEqualToString:@"fade"]) {
        CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
        a.fromValue = @0, a.toValue = @(o);
        a.duration = (ms > 0 ? ms : 240) / 1000;
        a.beginTime = begin;
        a.timingFunction = timing(kExpo);
        a.fillMode = kCAFillModeBackwards;
        [l addAnimation:a forKey:@"rexui.appear"];
        if (n.fx)
            box_fx_follow(n, @"rexui.appear");
    } else if ([kind isEqualToString:@"wipe"]) {
        CGRect b = l.bounds;
        double dur = (ms > 0 ? ms : 420) / 1000;
        if (b.size.width <= 0)
            return;
        if (l.mask) {
            CABasicAnimation* sx = [CABasicAnimation animationWithKeyPath:@"transform.scale.x"];
            sx.fromValue = @0.001, sx.toValue = @1;
            CABasicAnimation* tx = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
            tx.fromValue = @(-b.size.width * l.anchorPoint.x), tx.toValue = @0;
            CAAnimationGroup* g = [CAAnimationGroup animation];
            g.animations = @[sx, tx];
            g.duration = dur, g.beginTime = begin, g.timingFunction = timing(kExpo), g.fillMode = kCAFillModeBackwards;
            [l addAnimation:g forKey:@"rexui.appear"];
            if (n.fx)
                box_fx_follow(n, @"rexui.appear");
            return;
        }
        CALayer* holder = nil;
        if (passing_of(l, &holder))
            return;
        CALayer* mask = still([RXAppearMask layer]);
        mask.backgroundColor = NSColor.blackColor.CGColor;
        mask.anchorPoint = CGPointMake(0, 0.5);
        mask.bounds = CGRectMake(0, 0, b.size.width, b.size.height);
        mask.position = CGPointMake(CGRectGetMinX(b), CGRectGetMidY(b));
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setCompletionBlock:^{
            passing_off(l, mask);
        }];
        (void)passing_on(l, mask);
        CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"bounds.size.width"];
        a.fromValue = @0, a.toValue = @(b.size.width);
        a.duration = dur, a.beginTime = [mask convertTime:CACurrentMediaTime() fromLayer:nil] + delay;
        a.timingFunction = timing(kExpo), a.fillMode = kCAFillModeBackwards;
        [mask addAnimation:a forKey:@"rexui.appear"];
        if (n.fx)
            box_fx_fade(n, @"rexui.appear", 0, o, dur, begin, a.timingFunction);
        [CATransaction commit];
    }
}

void apply_expanded(RXNode* n, bool animated) {
    CALayer* l = n.layer;
    if (!l || is_list(n))
        return;
    bool open = flag(n, P::expanded, true);
    CALayer *holder = nil, *was = passing_of(l, &holder);
    CALayer* mask = [was isKindOfClass:RXFoldMask.class] ? was : nil;
    if (!mask && open)
        return;
    if (!mask && was)
        passing_off(l, was), was = nil;
    CGRect b = passing_rect(l);
    if (!mask) {
        mask = still([RXFoldMask layer]);
        mask.backgroundColor = NSColor.blackColor.CGColor;
        mask.cornerCurve = kCACornerCurveContinuous;
        mask.bounds = CGRectMake(0, 0, b.size.width, b.size.height);
        (void)passing_on(l, mask);
    }
    bool bottom = [str(n, P::expandFrom, @"top") isEqualToString:@"bottom"];
    CALayer* now = mask.presentationLayer ?: mask;
    CGRect from = now.bounds, to = CGRectMake(0, 0, b.size.width, open ? b.size.height : 0);
    float from_a = now.opacity;
    mask.anchorPoint = CGPointMake(0.5, bottom ? 1 : 0);
    mask.position = CGPointMake(CGRectGetMidX(b), bottom ? CGRectGetMaxY(b) : CGRectGetMinY(b));
    mask.cornerRadius = l.mask == mask ? l.cornerRadius : 0;
    mask.bounds = to;
    mask.opacity = open ? 1 : 0;
    double ms = num(n, P::animate, 0);
    if (!animated || ms <= 0 || CGRectIsEmpty(b) || !node_on_screen(n)) {
        [mask removeAllAnimations];
        if (open)
            passing_off(l, mask);
        return;
    }
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        CALayer* h = nil;
        if (flag(n, P::expanded, true) && passing_of(l, &h) == mask && ![mask animationForKey:@"rexui.bounds"])
            passing_off(l, mask);
    }];
    glide(mask, @"bounds", [NSValue valueWithRect:from], [NSValue valueWithRect:to], ms, easing_curve(n));
    glide(mask, @"opacity", @(from_a), @(open ? 1 : 0), ms * 0.6, kStandard);
    [CATransaction commit];
}

void fade_layer(CALayer* l, float to, double ms, void (^done)(void)) {
    float from = ((CALayer*)l.presentationLayer ?: l).opacity;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (done)
        [CATransaction setCompletionBlock:done];
    l.opacity = to;
    if (ms > 0 && from != to)
        glide(l, @"opacity", @(from), @(to), ms, kStandard);
    [CATransaction commit];
}

static double ease(double t) {
    return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2;
}

static double bezier(const double c[4], double x) {
    double cx = 3 * c[0], bx = 3 * (c[2] - c[0]) - cx, ax = 1 - cx - bx;
    double cy = 3 * c[1], by = 3 * (c[3] - c[1]) - cy, ay = 1 - cy - by;
    auto fx = [&](double t) { return ((ax * t + bx) * t + cx) * t; };
    double t = x;
    for (int i = 0; i < 8; i++) {
        double err = fx(t) - x, d = (3 * ax * t + 2 * bx) * t + cx;
        if (fabs(err) < 1e-6)
            break;
        if (fabs(d) < 1e-6) {
            double lo = 0, hi = 1;
            t = x;
            for (int j = 0; j < 30 && hi - lo > 1e-6; j++)
                (fx(t) < x ? lo : hi) = t, t = (lo + hi) / 2;
            break;
        }
        t -= err / d;
    }
    return ((ay * t + by) * t + cy) * t;
}

double curve_at(const double c[4], double x) {
    return bezier(c, x);
}

static void anim_tick(id owner, const RXFrame* f) {
    RXAnim* a = owner;
    double t = a.duration > 0 ? (f->now - a.start) / a.duration : 1;
    if (t < 1) {
        a.step(a.curve ? bezier(a.curve, MAX(0, t)) : ease(MAX(0, t)));
        return;
    }
    [a cancel];
    a.step(1);
    if (a.done)
        a.done();
}

@implementation RXAnim
- (void)cancel {
    ui_clock_remove(self.tick);
    self.tick = 0;
}
@end

RXAnim* animate(id host, double ms, void (^step)(double), void (^done)(void)) {
    RXAnim* a = [RXAnim new];
    a.start = CACurrentMediaTime();
    a.duration = ms / 1000;
    a.step = step;
    a.done = done;
    a.tick = ui_clock_add(RX_TICK_ANIM, 120, host, a, anim_tick);
    return a;
}

void melt(CALayer* host, CALayer* src, CGRect frame, bool out, double ms, void (^done)(void)) {
    CGFloat scale = src.contentsScale > 0 ? src.contentsScale : 2, w = frame.size.width, h = frame.size.height;
    if (w < 2 || h < 2 || !host) {
        if (done)
            done();
        return;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(nullptr, (size_t)(w * scale), (size_t)(h * scale), 8, 0, cs,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) {
        if (done)
            done();
        return;
    }
    CGContextScaleCTM(ctx, scale, scale);
    if (src.geometryFlipped || [src isKindOfClass:RXLayer.class]) {
        CGContextTranslateCTM(ctx, 0, h);
        CGContextScaleCTM(ctx, 1, -1);
    }
    float was = src.opacity;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    src.opacity = 1;
    [src renderInContext:ctx];
    src.opacity = was;
    [CATransaction commit];
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CALayer* overlay = [CALayer layer];
    overlay.frame = frame;
    overlay.masksToBounds = YES;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [host addSublayer:overlay];
    CGFloat col = 6;
    int n = (int)ceil(w / col);
    double dur = ms / 1000, now = CACurrentMediaTime();
    double y0 = 0;
    for (int i = 0; i < n; i++) {
        CALayer* c = [CALayer layer];
        c.contents = (__bridge id)img;
        c.contentsGravity = kCAGravityResize;
        c.contentsRect = CGRectMake((CGFloat)i / n, 0, 1.0 / n, 1);
        c.frame = CGRectMake(i * col, 0, MIN(col, w - i * col), h);
        c.geometryFlipped = overlay.geometryFlipped;
        [overlay addSublayer:c];
        y0 = MIN(0.35, MAX(0, y0 + (arc4random_uniform(3) - 1.0) * 0.04));
        CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"position.y"];
        CGFloat at = c.position.y;
        a.fromValue = @(out ? at : at - h * (host.geometryFlipped ? 1 : -1));
        a.toValue = @(out ? at + h * (host.geometryFlipped ? 1 : -1) : at);
        a.beginTime = now + y0 * dur;
        a.duration = dur * 0.65;
        a.timingFunction =
            [CAMediaTimingFunction functionWithName:out ? kCAMediaTimingFunctionEaseIn : kCAMediaTimingFunctionEaseOut];
        a.fillMode = kCAFillModeBoth;
        a.removedOnCompletion = NO;
        [c addAnimation:a forKey:@"melt"];
    }
    [CATransaction commit];
    CGImageRelease(img);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * 1.05 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        [overlay removeFromSuperlayer];
        if (done)
            done();
    });
}
