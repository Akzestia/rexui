// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include <objc/runtime.h>

namespace {
enum class Kind { square, round, cut, scoop, squircle };
struct CornerSpec {
    Kind kind = Kind::square;
    CGFloat size = 0;
};
}

static NSArray<NSString*>* words(NSString* s) {
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (NSString* w in [s componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (w.length)
            [out addObject:w];
    }
    return out;
}

static bool parse_corner(NSString* s, CornerSpec* c) {
    NSArray<NSString*>* parts = words(s);
    if (!parts.count)
        return false;
    NSString* k = parts[0].lowercaseString;
    if ([k isEqualToString:@"square"])
        c->kind = Kind::square;
    else if ([k isEqualToString:@"round"])
        c->kind = Kind::round;
    else if ([k isEqualToString:@"cut"])
        c->kind = Kind::cut;
    else if ([k isEqualToString:@"scoop"])
        c->kind = Kind::scoop;
    else if ([k isEqualToString:@"squircle"])
        c->kind = Kind::squircle;
    else
        return false;
    c->size = parts.count > 1 ? MAX(0, parts[1].doubleValue) : 0;
    return true;
}

CF_RETURNS_RETAINED static CGPathRef svg_path(NSString* d, CGSize size) {
    CGMutablePathRef p = CGPathCreateMutable();
    NSScanner* sc = [NSScanner scannerWithString:d];
    sc.charactersToBeSkipped = [NSCharacterSet characterSetWithCharactersInString:@" ,\n\t"];
    NSCharacterSet* cmds = [NSCharacterSet characterSetWithCharactersInString:@"MLHVCQZmlhvcqz"];
    unichar cmd = 'M';
    CGPoint at = CGPointZero;
    auto num = [&](double* v) { return [sc scanDouble:v]; };
    while (!sc.isAtEnd) {
        NSString* c = nil;
        if ([sc scanCharactersFromSet:cmds intoString:&c])
            cmd = [c characterAtIndex:c.length - 1];
        else if (!cmd)
            break;
        double x, y, x1, y1, x2, y2;
        switch (toupper(cmd)) {
        case 'M':
            if (!num(&x) || !num(&y))
                goto done;
            CGPathMoveToPoint(p, nullptr, x * size.width, y * size.height), at = CGPointMake(x, y), cmd = 'L';
            break;
        case 'L':
            if (!num(&x) || !num(&y))
                goto done;
            CGPathAddLineToPoint(p, nullptr, x * size.width, y * size.height), at = CGPointMake(x, y);
            break;
        case 'H':
            if (!num(&x))
                goto done;
            CGPathAddLineToPoint(p, nullptr, x * size.width, at.y * size.height), at.x = x;
            break;
        case 'V':
            if (!num(&y))
                goto done;
            CGPathAddLineToPoint(p, nullptr, at.x * size.width, y * size.height), at.y = y;
            break;
        case 'C':
            if (!num(&x1) || !num(&y1) || !num(&x2) || !num(&y2) || !num(&x) || !num(&y))
                goto done;
            CGPathAddCurveToPoint(p, nullptr, x1 * size.width, y1 * size.height, x2 * size.width, y2 * size.height,
                                  x * size.width, y * size.height);
            at = CGPointMake(x, y);
            break;
        case 'Q':
            if (!num(&x1) || !num(&y1) || !num(&x) || !num(&y))
                goto done;
            CGPathAddQuadCurveToPoint(p, nullptr, x1 * size.width, y1 * size.height, x * size.width, y * size.height);
            at = CGPointMake(x, y);
            break;
        case 'Z':
            CGPathCloseSubpath(p);
            cmd = 0;
            break;
        default:
            goto done;
        }
    }
done:
    if (CGPathIsEmpty(p)) {
        CGPathRelease(p);
        return nullptr;
    }
    return p;
}

CF_RETURNS_RETAINED static CGPathRef outline_path(NSString* spec, CGSize size);

CF_RETURNS_RETAINED static CGPathRef make_box_path(NSString* spec, CGSize size) {
    NSArray<NSString*>* parts = [spec componentsSeparatedByString:@";"];
    CGPathRef p = outline_path(parts.firstObject ?: @"", size);
    for (NSUInteger i = 1; p && i < parts.count; i++) {
        NSArray<NSString*>* w = words(parts[i]);
        if (w.count < 4 || ![w[0] isEqualToString:@"hole"])
            continue;
        CGFloat x = [w[1] doubleValue], y = [w[2] doubleValue], r = MAX(0, [w[3] doubleValue]);
        if (r < 0.5)
            continue;
        CGMutablePathRef cut = CGPathCreateMutable();
        if (w.count > 4 && [w[4] isEqualToString:@"tri"]) {
            CGPathMoveToPoint(cut, nullptr, x - r * 0.8660254, y - r * 0.5);
            CGPathAddLineToPoint(cut, nullptr, x + r * 0.8660254, y - r * 0.5);
            CGPathAddLineToPoint(cut, nullptr, x, y + r);
            CGPathCloseSubpath(cut);
        } else {
            CGPathAddEllipseInRect(cut, nullptr, CGRectMake(x - r, y - r, 2 * r, 2 * r));
        }
        CGPathRef left = CGPathCreateCopyBySubtractingPath(p, cut, false);
        CGPathRelease(cut);
        if (left)
            CGPathRelease(p), p = left;
    }
    return p;
}

static NSMutableDictionary<NSString*, id>* g_box_paths;
void box_paths_clear(void) {
    [g_box_paths removeAllObjects];
}

CGPathRef box_path(NSString* spec, CGSize size) {
    if (!spec.length || size.width <= 0 || size.height <= 0)
        return nullptr;
    if (!g_box_paths)
        g_box_paths = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString*, id>* cache = g_box_paths;
    NSString* key = [NSString stringWithFormat:@"%.3f %.3f %@", size.width, size.height, spec];
    if (id hit = cache[key])
        return hit == NSNull.null ? nullptr : CGPathRetain((__bridge CGPathRef)hit);
    CGPathRef p = make_box_path(spec, size);
    if (cache.count >= 512)
        [cache removeAllObjects];
    cache[key] = p ? (__bridge id)p : NSNull.null;
    return p;
}

static size_t path_elements(CGPathRef p) {
    __block size_t n = 0;
    if (p)
        CGPathApplyWithBlock(p, ^(const CGPathElement*) {
            n++;
        });
    return n;
}

CF_RETURNS_RETAINED static CGPathRef outline_path(NSString* spec, CGSize size) {
    spec = [spec stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!spec.length || size.width <= 0 || size.height <= 0)
        return nullptr;
    if ([spec.lowercaseString hasPrefix:@"svg"])
        return svg_path([spec substringFromIndex:3], size);
    NSArray<NSString*>* each = [spec componentsSeparatedByString:@","];
    CornerSpec c[4];
    if (each.count == 1) {
        if (!parse_corner(each[0], &c[0]))
            return nullptr;
        c[1] = c[2] = c[3] = c[0];
    } else if (each.count == 4) {
        for (int i = 0; i < 4; i++) {
            if (!parse_corner(each[i], &c[i]))
                return nullptr;
        }
    } else {
        return nullptr;
    }
    CGFloat w = size.width, h = size.height, most = MIN(w, h) / 2;
    for (auto& k : c)
        k.size = MIN(k.size, most);
    CGPoint K[4] = {{0, 0}, {w, 0}, {w, h}, {0, h}};
    CGPoint in[4] = {{0, c[0].size}, {w - c[1].size, 0}, {w, h - c[2].size}, {c[3].size, h}};
    CGPoint out[4] = {{c[0].size, 0}, {w, c[1].size}, {w - c[2].size, h}, {0, h - c[3].size}};
    auto lerp = [](CGPoint a, CGPoint b, CGFloat t) {
        return CGPointMake(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
    };
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, nullptr, out[0].x, out[0].y);
    for (int j = 1; j <= 4; j++) {
        int i = j % 4;
        CGPathAddLineToPoint(p, nullptr, in[i].x, in[i].y);
        CGPoint a = in[i], b = out[i], k = K[i], c1, c2;
        switch (c[i].kind) {
        case Kind::square:
        case Kind::round:
            c1 = lerp(a, k, 0.5523), c2 = lerp(b, k, 0.5523);
            break;
        case Kind::squircle:
            c1 = lerp(a, k, 0.82), c2 = lerp(b, k, 0.82);
            break;
        case Kind::cut:
            c1 = lerp(a, b, 1.0 / 3), c2 = lerp(a, b, 2.0 / 3);
            break;
        case Kind::scoop: {
            CGPoint inner = CGPointMake(a.x + b.x - k.x, a.y + b.y - k.y);
            c1 = lerp(a, inner, 0.5523), c2 = lerp(b, inner, 0.5523);
            break;
        }
        }
        CGPathAddCurveToPoint(p, nullptr, c1.x, c1.y, c2.x, c2.y, b.x, b.y);
    }
    CGPathCloseSubpath(p);
    return p;
}

static char k_mask, k_stroke, k_holed;

static void glide_path(CAShapeLayer* l, CGPathRef to, double ms, bool holed, const double* curve) {
    if (g_panes_instant)
        ms = 0;
    CGPathRef from = ((CAShapeLayer*)l.presentationLayer ?: l).path;
    bool was = [objc_getAssociatedObject(l, &k_holed) boolValue];
    if (was != holed)
        objc_setAssociatedObject(l, &k_holed, @(holed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    l.path = to;
    if (ms <= 0 || !from || holed || was || CGPathEqualToPath(from, to) || path_elements(from) != path_elements(to)) {
        [l removeAnimationForKey:@"rexui.path"];
        return;
    }
    ca_glide(l, @"path", (__bridge id)from, ms, curve ?: kStandard, nil);
}

static void stroke_extras(CAShapeLayer* line, NSArray* dash, double speed, double start, double end, double ms) {
    NSMutableArray* d = [NSMutableArray array];
    double period = 0;
    for (id v in [dash isKindOfClass:NSArray.class] ? dash : @[]) {
        if ([v isKindOfClass:NSNumber.class] && [v doubleValue] >= 0)
            [d addObject:v], period += [v doubleValue];
    }
    NSArray* want = period > 0 ? d : nil;
    if (!(line.lineDashPattern == want || [line.lineDashPattern isEqual:want]))
        line.lineDashPattern = want;
    NSString* march = [NSString stringWithFormat:@"%@|%g", want, speed];
    if (![[line valueForKey:@"rexuiMarch"] isEqual:march]) {
        [line setValue:march forKey:@"rexuiMarch"];
        [line removeAnimationForKey:@"rexui.march"];
        if (want && speed != 0) {
            CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"lineDashPhase"];
            a.fromValue = @0, a.toValue = @(speed > 0 ? -period : period);
            a.duration = period / fabs(speed), a.repeatCount = HUGE_VALF;
            [line addAnimation:a forKey:@"rexui.march"];
        }
    }
    start = MAX(0, MIN(1, start)), end = MAX(start, MIN(1, end));
    CAShapeLayer* shown = (CAShapeLayer*)line.presentationLayer ?: line;
    double was_s = shown.strokeStart, was_e = shown.strokeEnd;
    line.strokeStart = start, line.strokeEnd = end;
    if (ms > 0 && (was_s != start || was_e != end)) {
        CAMediaTimingFunction* curve = [CAMediaTimingFunction functionWithControlPoints:0.2:0:0:1];
        for (NSString* k in @[@"strokeStart", @"strokeEnd"]) {
            CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:k];
            a.fromValue = @([k isEqualToString:@"strokeStart"] ? was_s : was_e),
            a.toValue = @([k isEqualToString:@"strokeStart"] ? start : end);
            a.duration = ms / 1000, a.timingFunction = curve;
            [line addAnimation:a forKey:[@"rexui." stringByAppendingString:k]];
        }
    }
}

@interface RXMaskLayer : CAShapeLayer
@end
@implementation RXMaskLayer
@end

static CAShapeLayer* shape_stroke(CALayer* l) {
    return objc_getAssociatedObject(l, &k_stroke);
}

bool shape_intact(CALayer* l) {
    CAShapeLayer* mask = objc_getAssociatedObject(l, &k_mask);
    return mask && l.mask == mask;
}

void shape_layer(CALayer* l, NSString* spec, double ms, CGColorRef stroke, CGFloat width, bool* took_border,
                 const double* curve) {
    CAShapeLayer *mask = objc_getAssociatedObject(l, &k_mask), *line = objc_getAssociatedObject(l, &k_stroke);
    CGPathRef path = box_path(spec, l.bounds.size);
    bool holed = path && [spec rangeOfString:@"hole"].location != NSNotFound;
    if (took_border)
        *took_border = false;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!path) {
        if (mask && l.mask == mask)
            mask_set_own(l, nil);
        [line removeFromSuperlayer];
        objc_setAssociatedObject(l, &k_mask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(l, &k_stroke, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [CATransaction commit];
        return;
    }
    if (!mask) {
        mask = (CAShapeLayer*)still([RXMaskLayer layer]);
        objc_setAssociatedObject(l, &k_mask, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (l.mask != mask)
        mask_set_own(l, mask);
    if (!mask.fillColor || CGColorGetAlpha(mask.fillColor) < 1)
        mask.fillColor = NSColor.blackColor.CGColor;
    if (mask.fillRule != kCAFillRuleNonZero)
        mask.fillRule = kCAFillRuleNonZero;
    mask.frame = l.bounds;
    glide_path(mask, path, ms, holed, curve);
    if (width > 0 && stroke && CGColorGetAlpha(stroke) > 0) {
        if (!line) {
            line = (CAShapeLayer*)still([CAShapeLayer layer]);
            line.fillColor = nil;
            line.zPosition = 1000;
            objc_setAssociatedObject(l, &k_stroke, line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (line.superlayer != l)
            [l addSublayer:line];
        line.frame = l.bounds;
        glide_path(line, path, ms, holed, curve);
        CALayer* shown = (CALayer*)line.presentationLayer ?: line;
        CGColorRef was = ((CAShapeLayer*)shown).strokeColor;
        CGFloat was_w = ((CAShapeLayer*)shown).lineWidth;
        line.strokeColor = stroke;
        line.lineWidth = width * 2;
        if (ms > 0 && was && !CGColorEqualToColor(was, stroke)) {
            CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"strokeColor"];
            a.fromValue = (__bridge id)was, a.toValue = (__bridge id)stroke, a.duration = ms / 1000;
            [line addAnimation:a forKey:@"rexui.strokeColor"];
        }
        if (ms > 0 && was_w > 0 && was_w != width * 2) {
            CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"lineWidth"];
            a.fromValue = @(was_w), a.toValue = @(width * 2), a.duration = ms / 1000;
            [line addAnimation:a forKey:@"rexui.lineWidth"];
        }
        if (took_border)
            *took_border = true;
    } else {
        [line removeFromSuperlayer];
    }
    [CATransaction commit];
    CGPathRelease(path);
}

void apply_shape(RXNode* n) {
    CALayer* l = n.layer;
    if (!l || is_drawer(n) || is_native(n))
        return;
    NSString* spec = str(n, P::shape, @"");
    if (is_elem(n, E::Image) && ([spec isEqualToString:@"circle"] || [spec hasPrefix:@"cookie"]))
        spec = @"";
    id dash = obj(n, P::border_dash);
    bool extras = ([dash isKindOfClass:NSArray.class] && [dash count]) || num(n, P::border_start, 0) > 0
        || num(n, P::border_end, 1) < 1;
    if (!spec.length && extras)
        spec = [NSString stringWithFormat:@"round %g", num(n, P::radius, 0)];
    if (!spec.length && !objc_getAssociatedObject(l, &k_mask))
        return;
    double ms = MAX(num(n, P::colorAnimation, 0), num(n, P::animate, 0));
    if (ms > 0 && deco_lands(n))
        ms = 0;
    CGColorRef stroke = parse_color(obj_of(n, P::border_color)).CGColor ?: g_theme.fg.CGColor;
    bool took = false;
    shape_layer(l, spec, ms, stroke, num(n, P::border_width, 0), &took,
                [str(n, P::easing, @"") isEqualToString:@"rex"] ? nullptr : easing_curve(n));
    if (CAShapeLayer* line = took ? shape_stroke(l) : nil) {
        stroke_extras(line, dash, num(n, P::border_dashSpeed, 0), num(n, P::border_start, 0), num(n, P::border_end, 1),
                      ms);
    }
    CGFloat bw = took ? 0 : num(n, P::border_width, 0);
    if (l.borderWidth != bw)
        l.borderWidth = bw;
    if (spec.length && l.cornerRadius != 0)
        l.cornerRadius = 0;
    if (!spec.length)
        apply_radius(n);
}

CALayer* make_path(RXNode* n) {
    RXLayer* l = [RXLayer layer];
    CAShapeLayer* s = (CAShapeLayer*)still([CAShapeLayer layer]);
    s.fillColor = nil;
    [l addSublayer:s];
    return l;
}

void path_apply(RXNode* n) {
    CALayer* l = n.layer;
    CAShapeLayer* s = (CAShapeLayer*)l.sublayers.firstObject;
    if (![s isKindOfClass:CAShapeLayer.class])
        return;
    CGSize b = l.bounds.size;
    bool pt = [str(n, P::units, @"box") isEqualToString:@"pt"];
    CGPathRef p = svg_path(str(n, P::d, @""), pt ? CGSizeMake(1, 1) : b);
    double ms = num(n, P::animate, 0);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    s.frame = l.bounds;
    s.path = p;
    s.strokeColor = parse_color(obj_of(n, P::stroke)).CGColor ?: g_theme.fg.CGColor;
    s.fillColor = parse_color(obj_of(n, P::fill)).CGColor;
    s.lineWidth = num(n, P::strokeWidth, 1);
    NSString *cap = str(n, P::cap, @"butt"), *join = str(n, P::join, @"miter");
    s.lineCap = [cap isEqualToString:@"round"] ? kCALineCapRound
        : [cap isEqualToString:@"square"]      ? kCALineCapSquare
                                               : kCALineCapButt;
    s.lineJoin = [join isEqualToString:@"round"] ? kCALineJoinRound
        : [join isEqualToString:@"bevel"]        ? kCALineJoinBevel
                                                 : kCALineJoinMiter;
    [CATransaction commit];
    if (p)
        CGPathRelease(p);
    stroke_extras(s, obj(n, P::dash), num(n, P::dashSpeed, 0), num(n, P::start, 0), num(n, P::end, 1), ms);
}
