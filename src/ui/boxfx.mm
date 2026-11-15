// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include <objc/message.h>
#include <vector>

static constexpr size_t kGradientSize = 128;

@interface RXBoxFx : NSObject
@property(nonatomic, strong) CALayer* shadow;
@property(nonatomic) bool own;
@property(nonatomic, strong) CALayer* backdrop;
@end
@implementation RXBoxFx
@end

static RXBoxFx* fx_of(RXNode* n, bool make) {
    if (!n.fx && make)
        n.fx = [RXBoxFx new];
    return n.fx;
}

static CGImageRef gradient_image(NSArray* colors, double degrees, CGSize box) CF_RETURNS_RETAINED;
static CGImageRef gradient_image(NSArray* colors, double degrees, CGSize box) {
    std::vector<CGFloat> comps;
    std::vector<CGFloat> at;
    for (NSUInteger i = 0; i < colors.count; i++) {
        CGColorRef c = parse_color(colors[i]).CGColor;
        if (!c)
            continue;
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGColorRef in = CGColorCreateCopyByMatchingToColorSpace(srgb, kCGRenderingIntentDefault, c, nullptr);
        CGColorSpaceRelease(srgb);
        if (!in)
            continue;
        const size_t k = CGColorGetNumberOfComponents(in);
        const CGFloat* v = CGColorGetComponents(in);
        if (k >= 4)
            comps.insert(comps.end(), v, v + 4);
        CGColorRelease(in);
    }
    const size_t count = comps.size() / 4;
    if (count < 2)
        return nullptr;
    for (size_t i = 0; i < count; i++)
        at.push_back((CGFloat)i / (CGFloat)(count - 1));
    const CGFloat aspect = box.width > 0 && box.height > 0 ? box.width / box.height : 1;
    const size_t w = aspect >= 1 ? kGradientSize : MAX((size_t)8, (size_t)(kGradientSize * aspect));
    const size_t h = aspect >= 1 ? MAX((size_t)8, (size_t)(kGradientSize / aspect)) : kGradientSize;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(nullptr, w, h, 8, 0, srgb, kCGImageAlphaPremultipliedLast);
    CGGradientRef g = CGGradientCreateWithColorComponents(srgb, comps.data(), at.data(), count);
    CGColorSpaceRelease(srgb);
    const double a = degrees * M_PI / 180, dx = sin(a), dy = -cos(a);
    const double half = (fabs(dx) * w + fabs(dy) * h) / 2;
    const CGPoint from = CGPointMake(w / 2.0 + dx * half, h / 2.0 - dy * half),
                  to = CGPointMake(w / 2.0 - dx * half, h / 2.0 + dy * half);
    CGContextDrawLinearGradient(ctx, g, from, to,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGGradientRelease(g);
    CGContextRelease(ctx);
    return img;
}

static void apply_gradient(RXNode* n) {
    CALayer* l = n.layer;
    id list = obj_of(n, P::gradient);
    if (![list isKindOfClass:NSArray.class] || [list count] < 2) {
        if (n.has_gradient)
            l.contents = nil, n.has_gradient = false;
        return;
    }
    CGImageRef img = gradient_image(list, num(n, P::gradientAngle, 0), l.bounds.size);
    if (!img)
        return;
    l.contents = (__bridge_transfer id)img;
    l.contentsGravity = kCAGravityResize;
    n.has_gradient = true;
}

static bool shadow_on_own(CALayer* l) {
    return !l.masksToBounds && !(l.mask && !mask_passing(l.mask));
}

static CGPathRef shadow_path(CALayer* l, CGSize size) CF_RETURNS_RETAINED;
static CGPathRef shadow_path(CALayer* l, CGSize size) {
    CALayer* m = l.mask && !mask_passing(l.mask) ? l.mask : nil;
    if ([m isKindOfClass:CAShapeLayer.class] && ((CAShapeLayer*)m).path)
        return CGPathCreateCopy(((CAShapeLayer*)m).path);
    const CGRect b = CGRectMake(0, 0, size.width, size.height);
    const CGFloat r = MAX(0, MIN(l.cornerRadius, MIN(size.width, size.height) / 2));
    return CGPathCreateWithRoundedRect(b, r, r, nullptr);
}

static void shadow_place(RXNode* n, CGRect f) {
    RXBoxFx* x = fx_of(n, false);
    CALayer* l = n.layer;
    if (x.own) {
        CGPathRef p = shadow_path(l, f.size);
        l.shadowPath = p;
        CGPathRelease(p);
        return;
    }
    if (!x.shadow)
        return;
    if (x.shadow.superlayer != l.superlayer && l.superlayer)
        [l.superlayer insertSublayer:x.shadow below:l];
    CGPoint a = l.anchorPoint;
    x.shadow.anchorPoint = a;
    x.shadow.bounds = CGRectMake(0, 0, f.size.width, f.size.height);
    x.shadow.position = CGPointMake(f.origin.x + f.size.width * a.x, f.origin.y + f.size.height * a.y);
    x.shadow.transform = l.transform;
    x.shadow.opacity = l.opacity;
    x.shadow.hidden = l.hidden;
    CGPathRef p = shadow_path(l, f.size);
    x.shadow.shadowPath = p;
    CGPathRelease(p);
}

static void apply_shadow(RXNode* n) {
    CALayer* l = n.layer;
    id color = obj_of(n, P::shadow_color);
    CGColorRef c = color ? parse_color(color).CGColor : nullptr;
    RXBoxFx* x = fx_of(n, c != nullptr);
    const bool own = c && shadow_on_own(l);
    if (!own && x.own) {
        l.shadowOpacity = 0, l.shadowPath = nil;
        [l removeAnimationForKey:@"rexui.shadowPath"];
        x.own = false;
    }
    if (!c || own) {
        [x.shadow removeFromSuperlayer];
        x.shadow = nil;
    }
    if (!c)
        return;
    CALayer* s = own ? l : x.shadow;
    if (!s)
        s = x.shadow = still([CALayer layer]);
    x.own = own;
    s.shadowColor = c;
    s.shadowOpacity = 1;
    s.shadowRadius = num(n, P::shadow_radius, 8);
    s.shadowOffset = CGSizeMake(num(n, P::shadow_x, 0), num(n, P::shadow_y, 0));
    shadow_place(n, layer_frame(n, l));
}

static void apply_backdrop(RXNode* n) {
    CALayer* l = n.layer;
    const double r = num(n, P::backdropBlur, 0);
    RXBoxFx* x = fx_of(n, r > 0);
    if (r <= 0) {
        [x.backdrop removeFromSuperlayer];
        x.backdrop = nil;
        return;
    }
    Class backdrop = NSClassFromString(@"CABackdropLayer"), filter = NSClassFromString(@"CAFilter");
    if (!backdrop || !filter || ![filter respondsToSelector:@selector(filterWithType:)])
        return;
    if (!x.backdrop) {
        x.backdrop = still([backdrop new]);
        [l insertSublayer:x.backdrop atIndex:0];
    }
    id f = ((id(*)(id, SEL, NSString*))objc_msgSend)(filter, @selector(filterWithType:), @"gaussianBlur");
    [f setValue:@(r) forKey:@"inputRadius"];
    x.backdrop.filters = @[f];
    x.backdrop.frame = l.bounds;
}

void layer_blur(CALayer* l, double r) {
    if (r <= 0) {
        if (l.filters.count)
            l.filters = nil;
        return;
    }
    Class filter = NSClassFromString(@"CAFilter");
    if (!filter || ![filter respondsToSelector:@selector(filterWithType:)])
        return;
    id f = ((id(*)(id, SEL, NSString*))objc_msgSend)(filter, @selector(filterWithType:), @"gaussianBlur");
    [f setValue:@(r) forKey:@"inputRadius"];
    [f setValue:@YES forKey:@"inputNormalizeEdges"];
    l.filters = @[f];
}

void box_fx_apply(RXNode* n, P p) {
    if (p == P::gradient || p == P::gradientAngle)
        apply_gradient(n);
    else if (p == P::backdropBlur)
        apply_backdrop(n);
    else
        apply_shadow(n);
}

void box_fx_placed(RXNode* n, CGRect f) {
    if (n.fx) {
        RXBoxFx* x = n.fx;
        if ((x.shadow || x.own) && x.own != shadow_on_own(n.layer))
            apply_shadow(n);
        else if (x.shadow || x.own)
            shadow_place(n, f);
        if (x.backdrop)
            x.backdrop.frame = CGRectMake(0, 0, f.size.width, f.size.height);
    }
    if (n.has_gradient) {
        if (!CGSizeEqualToSize(n.gradient_at, f.size)) {
            n.gradient_at = f.size;
            if (id list = obj_of(n, P::gradient);
                [list isKindOfClass:NSArray.class] && num(n, P::gradientAngle, 0) != 0)
                apply_gradient(n);
        }
    }
}

void box_fx_clipped(RXNode* n) {
    RXBoxFx* x = n.fx;
    if ((x.shadow || x.own) && x.own != shadow_on_own(n.layer))
        apply_shadow(n);
}

void box_fx_sync(RXNode* n) {
    RXBoxFx* x = n.fx;
    CALayer *s = x.shadow, *l = n.layer;
    if (!s)
        return;
    if (s.hidden != l.hidden)
        s.hidden = l.hidden;
    if (s.opacity != l.opacity)
        s.opacity = l.opacity;
    if (!CATransform3DEqualToTransform(s.transform, l.transform))
        s.transform = l.transform;
}

void box_fx_follow(RXNode* n, NSString* key) {
    RXBoxFx* x = n.fx;
    if (!x || (!x.shadow && !x.own))
        return;
    CALayer* l = n.layer;
    CAAnimation* a = [l animationForKey:key];
    if (x.shadow) {
        if (a)
            [x.shadow addAnimation:a forKey:key];
        else
            [x.shadow removeAnimationForKey:key];
    }
    if (![key isEqualToString:@"rexui.bounds"])
        return;
    CALayer* s = x.shadow ?: l;
    CABasicAnimation* b = [a isKindOfClass:CABasicAnimation.class] ? (CABasicAnimation*)a : nil;
    if (!b || !b.fromValue || !b.toValue)
        return [s removeAnimationForKey:@"rexui.shadowPath"];
    CGPathRef from = shadow_path(l, [b.fromValue rectValue].size), to = shadow_path(l, [b.toValue rectValue].size);
    CABasicAnimation* g = [CABasicAnimation animationWithKeyPath:@"shadowPath"];
    g.fromValue = (__bridge id)from, g.toValue = (__bridge id)to;
    g.duration = b.duration, g.timingFunction = b.timingFunction, g.beginTime = b.beginTime;
    [s addAnimation:g forKey:@"rexui.shadowPath"];
    CGPathRelease(from);
    CGPathRelease(to);
}

void box_fx_fade(RXNode* n, NSString* key, float from, float to, double seconds, CFTimeInterval begin,
                 CAMediaTimingFunction* f) {
    RXBoxFx* x = n.fx;
    CALayer* s = x.shadow;
    if (!s)
        return;
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @(from), a.toValue = @(to), a.duration = seconds, a.beginTime = begin, a.timingFunction = f;
    a.fillMode = to == 0 ? kCAFillModeForwards : kCAFillModeBackwards;
    a.removedOnCompletion = to != 0;
    [s addAnimation:a forKey:key];
}

void box_fx_gone(RXNode* n) {
    if (n.fx)
        [((RXBoxFx*)n.fx).shadow removeFromSuperlayer];
}
