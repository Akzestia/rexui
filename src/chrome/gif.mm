// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "chrome/chrome.h"

struct Gif {
    NSString* key;
    NSArray* frames;
    NSArray<NSNumber*>* key_times;
    double duration = 0;
    CGSize size;
    int generation = 0;
};
static Gif g_gif;

static void key_out_black(uint8_t* px, size_t w, size_t h) {
    constexpr int kBlack = 24, kEdge = 72;
    auto level = [&](size_t i) { return MAX(px[i * 4], MAX(px[i * 4 + 1], px[i * 4 + 2])); };
    std::vector<uint8_t> removed(w * h);
    std::vector<size_t> todo;
    auto visit = [&](size_t i) {
        if (!removed[i] && level(i) <= kBlack)
            removed[i] = 1, todo.push_back(i);
    };
    for (size_t x = 0; x < w; x++)
        visit(x), visit((h - 1) * w + x);
    for (size_t y = 0; y < h; y++)
        visit(y * w), visit(y * w + w - 1);
    while (!todo.empty()) {
        size_t i = todo.back();
        todo.pop_back();
        if (!w)
            break;
        size_t x = i % w, y = i / w;
        if (x > 0)
            visit(i - 1);
        if (x + 1 < w)
            visit(i + 1);
        if (y > 0)
            visit(i - w);
        if (y + 1 < h)
            visit(i + w);
    }
    for (size_t i = 0; i < w * h; i++) {
        if (removed[i]) {
            px[i * 4] = px[i * 4 + 1] = px[i * 4 + 2] = px[i * 4 + 3] = 0;
            continue;
        }
        size_t x = i % w, y = i / w;
        bool edge = (x > 0 && removed[i - 1]) || (x + 1 < w && removed[i + 1]) || (y > 0 && removed[i - w])
            || (y + 1 < h && removed[i + w]);
        if (edge && level(i) < kEdge)
            px[i * 4 + 3] = uint8_t(level(i) * 255 / kEdge);
    }
}

static bool load_gif(NSString* path, CGFloat pixel_height) {
    static NSString* seen_path;
    static NSDate* seen_mtime;
    static double seen_at;
    double now = CACurrentMediaTime();
    if (![path isEqual:seen_path] || now - seen_at > 1) {
        seen_path = path;
        seen_mtime = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
        seen_at = now;
    }
    NSDate* mtime = seen_mtime;
    if (!mtime || pixel_height < 1)
        return false;
    NSString* key = [NSString stringWithFormat:@"%@|%@|%.0f", path, mtime, pixel_height];
    if ([key isEqualToString:g_gif.key])
        return g_gif.frames.count > 0;
    g_gif.key = key;
    g_gif.frames = nil;
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], nullptr);
    if (!src)
        return false;
    size_t n = CGImageSourceGetCount(src);
    NSMutableArray* frames = [NSMutableArray arrayWithCapacity:n];
    std::vector<double> delays;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    size_t w = 0, h = size_t(pixel_height);
    for (size_t i = 0; i < n; i++) {
        CGImageRef image = CGImageSourceCreateImageAtIndex(src, i, nullptr);
        if (!image)
            continue;
        if (!CGImageGetWidth(image) || !CGImageGetHeight(image)) {
            CGImageRelease(image);
            continue;
        }
        if (!w)
            w = MAX(size_t(1), size_t(pixel_height * CGImageGetWidth(image) / CGImageGetHeight(image)));
        std::vector<uint8_t> px(w * h * 4);
        CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
        if (!ctx) {
            CGImageRelease(image);
            continue;
        }
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
        key_out_black(px.data(), w, h);
        CGImageRef keyed = CGBitmapContextCreateImage(ctx);
        [frames addObject:(__bridge_transfer id)keyed];
        CGContextRelease(ctx);
        CGImageRelease(image);
        NSDictionary* props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, nullptr));
        NSDictionary* gif = props[(__bridge NSString*)kCGImagePropertyGIFDictionary];
        double d = [gif[(__bridge NSString*)kCGImagePropertyGIFUnclampedDelayTime] doubleValue];
        if (d < 0.011)
            d = [gif[(__bridge NSString*)kCGImagePropertyGIFDelayTime] doubleValue];
        delays.push_back(d < 0.011 ? 0.1 : d);
    }
    CGColorSpaceRelease(cs);
    CFRelease(src);
    if (frames.count == 0)
        return false;
    double total = 0;
    for (double d : delays)
        total += d;
    NSMutableArray<NSNumber*>* times = [NSMutableArray arrayWithCapacity:delays.size()];
    double t = 0;
    for (double d : delays) {
        [times addObject:@(t / total)];
        t += d;
    }
    [times addObject:@1];
    g_gif.frames = frames;
    g_gif.key_times = times;
    g_gif.duration = total;
    g_gif.size = CGSizeMake(w, h);
    g_gif.generation++;
    return true;
}

static NSView* hit_none(id, SEL, NSPoint) {
    return nil;
}

static Class gif_view_class(void) {
    static Class cls = [] {
        Class c = objc_allocateClassPair([NSView class], "RexUIGifView", 0);
        Method m = class_getInstanceMethod([NSView class], @selector(hitTest:));
        class_addMethod(c, @selector(hitTest:), (IMP)hit_none, method_getTypeEncoding(m));
        objc_registerClassPair(c);
        return c;
    }();
    return cls;
}

static char k_gif_generation;

void update_gif(NSView* chrome, NSRect area) {
    NSView* view = nil;
    for (NSView* v in chrome.subviews) {
        if ([v isKindOfClass:gif_view_class()])
            view = v;
    }
    const Config& c = g_config;
    CGFloat scale = chrome.window.backingScaleFactor ?: 2;
    if (!c.gif || !c.gif_visible || !load_gif(c.gif, round(c.gif_height * scale))) {
        [view removeFromSuperview];
        return;
    }
    if (!view) {
        view = [[gif_view_class() alloc] initWithFrame:NSZeroRect];
        view.wantsLayer = YES;
        view.layer.contentsGravity = kCAGravityResizeAspect;
        [chrome addSubview:view positioned:NSWindowBelow relativeTo:nil];
    }
    CGFloat h = c.gif_height, w = h * g_gif.size.width / g_gif.size.height, m = c.gif_margin;
    NSRect b = area;
    CGFloat left = b.origin.x + m, right = NSMaxX(b) - m - w, top = b.origin.y + m, bottom = NSMaxY(b) - m - h;
    NSPoint at;
    switch (c.gif_corner) {
    case Corner::top_left:
        at = NSMakePoint(left, top);
        break;
    case Corner::top_right:
        at = NSMakePoint(right, top);
        break;
    case Corner::bottom_left:
        at = NSMakePoint(left, bottom);
        break;
    case Corner::bottom_right:
        at = NSMakePoint(right, bottom);
        break;
    case Corner::center:
        at = NSMakePoint(NSMidX(b) - w / 2, NSMidY(b) - h / 2);
        break;
    }
    NSRect f = NSMakeRect(round(at.x), round(at.y), w, h);
    if (!NSEqualRects(view.frame, f))
        view.frame = f;
    CALayer* layer = view.layer;
    if (layer.opacity != float(c.gif_opacity))
        layer.opacity = float(c.gif_opacity);
    if (layer.contentsScale != scale)
        layer.contentsScale = scale;
    if ([objc_getAssociatedObject(view, &k_gif_generation) intValue] != g_gif.generation) {
        layer.contents = g_gif.frames[0];
        CAKeyframeAnimation* anim = [CAKeyframeAnimation animationWithKeyPath:@"contents"];
        anim.values = g_gif.frames;
        anim.keyTimes = g_gif.key_times;
        anim.calculationMode = kCAAnimationDiscrete;
        anim.duration = g_gif.duration;
        anim.repeatCount = HUGE_VALF;
        anim.removedOnCompletion = NO;
        [layer addAnimation:anim forKey:@"rexui-gif"];
        objc_setAssociatedObject(view, &k_gif_generation, @(g_gif.generation), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
