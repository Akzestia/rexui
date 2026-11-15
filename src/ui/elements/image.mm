// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#import <ImageIO/ImageIO.h>

#include <cmath>

@interface RXDecoded : NSObject
@property(nonatomic, strong) id image;
@property(nonatomic) NSSize size;
@property(nonatomic) CGFloat pixels;
@property(nonatomic) NSSize native;
@end
@implementation RXDecoded
@end

static NSCache<NSString*, RXDecoded*>* image_cache(void) {
    static NSCache* c = [] {
        NSCache* c = [NSCache new];
        c.countLimit = 64;
        return c;
    }();
    return c;
}

static constexpr CGFloat k_unknown_max = 2048;
static constexpr double k_gif_bytes = 48 << 20;

static CGFloat bucket(CGFloat px) {
    CGFloat b = 64;
    while (b < px && b < 4096)
        b *= 2;
    return b;
}

static CGFloat needed_px(CGSize box, CGFloat scale, NSString* fit, CGFloat iw, CGFloat ih) {
    if (box.width <= 0 || box.height <= 0 || iw <= 0 || ih <= 0)
        return k_unknown_max;
    double sx = box.width * scale / iw, sy = box.height * scale / ih;
    double s = [fit isEqualToString:@"contain"] ? MIN(sx, sy)
        : [fit isEqualToString:@"fill"]         ? MAX(sx, sy)
                                                : MAX(sx, sy);
    return MIN(4096, MAX(iw, ih) * MIN(1.0, s));
}

CF_RETURNS_RETAINED static CGImageRef decode_at(CGImageSourceRef src, size_t index, CGFloat max_px) {
    NSDictionary* o = @{
        (__bridge NSString*)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString*)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString*)kCGImageSourceShouldCacheImmediately: @YES,
        (__bridge NSString*)kCGImageSourceThumbnailMaxPixelSize: @(MAX(1, (int)ceil(max_px))),
    };
    return CGImageSourceCreateThumbnailAtIndex(src, index, (__bridge CFDictionaryRef)o);
}

@interface RXGif : NSObject
@property(nonatomic, strong) NSArray* frames;
@property(nonatomic, strong) NSArray<NSNumber*>* starts;
@property(nonatomic) double duration;
@end
@implementation RXGif
@end

static NSCache<NSString*, RXGif*>* gif_cache(void) {
    static NSCache* c = [] {
        NSCache* c = [NSCache new];
        c.countLimit = 16;
        return c;
    }();
    return c;
}

static RXGif* decode_gif(CGImageSourceRef src, CGFloat max_px, CGFloat iw, CGFloat ih) {
    if (!src)
        return nil;
    size_t count = CGImageSourceGetCount(src);
    if (count > 1 && iw > 0 && ih > 0) {
        double side = MIN(max_px, MAX(iw, ih)), k = side / MAX(iw, ih);
        double bytes = (double)count * iw * k * ih * k * 4;
        if (bytes > k_gif_bytes)
            max_px = MAX(16, side * sqrt(k_gif_bytes / bytes));
    }
    NSMutableArray* frames = [NSMutableArray array];
    std::vector<double> delays;
    for (size_t i = 0; count > 1 && i < count; i++) {
        CGImageRef image = decode_at(src, i, max_px);
        if (!image)
            continue;
        NSDictionary* props = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, i, nullptr));
        NSDictionary* gif = props[(__bridge NSString*)kCGImagePropertyGIFDictionary];
        double d = [gif[(__bridge NSString*)kCGImagePropertyGIFUnclampedDelayTime] doubleValue];
        if (d <= 0)
            d = [gif[(__bridge NSString*)kCGImagePropertyGIFDelayTime] doubleValue];
        if (d < 0.011)
            d = 0.1;
        [frames addObject:(__bridge_transfer id)image];
        delays.push_back(d);
    }
    if (frames.count < 2)
        return nil;
    RXGif* g = [RXGif new];
    double total = 0;
    for (double d : delays)
        total += d;
    NSMutableArray* starts = [NSMutableArray array];
    double t = 0;
    for (double d : delays) {
        [starts addObject:@(t / total)];
        t += d;
    }
    [starts addObject:@1];
    g.frames = frames;
    g.starts = starts;
    g.duration = total;
    return g;
}

static void play_gif(RXNode* n, RXGif* gif) {
    CALayer* layer = n.layer;
    [layer removeAnimationForKey:@"gif"];
    if (gif) {
        CAKeyframeAnimation* a = [CAKeyframeAnimation animationWithKeyPath:@"contents"];
        a.values = gif.frames;
        a.keyTimes = gif.starts;
        a.calculationMode = kCAAnimationDiscrete;
        a.duration = gif.duration;
        a.repeatCount = HUGE_VALF;
        a.removedOnCompletion = NO;
        [layer addAnimation:a forKey:@"gif"];
    }
    apply_gif_rate(n);
}

void apply_gif_rate(RXNode* n) {
    CALayer* layer = n.layer;
    bool gif = [layer animationForKey:@"gif"] != nil;
    float rate = gif && flag(n, P::playing, true) ? MAX(0, num(n, P::speed, 1)) : gif ? 0 : 1;
    if (layer.speed == rate)
        return;
    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval local = [layer convertTime:now fromLayer:nil];
    layer.beginTime = layer.superlayer ? [layer.superlayer convertTime:now fromLayer:nil] : now;
    layer.timeOffset = local;
    layer.speed = rate;
}

static NSString* cache_key(NSString* source, CGFloat px) {
    return [NSString stringWithFormat:@"%.0f %@", bucket(px), source];
}

static void tell_status(RXNode* n, NSString* status, NSString* error) {
    if (!flag(n, @"wantsStatus", false) || !n.doc.ctx)
        return;
    doc_call(n.doc, @"update", @[@(n.uid), @{@"status": status}]);
    if ([status isEqualToString:@"ready"])
        doc_call(n.doc, @"emit", @[@(n.uid), @"loaded", @[]]);
    else if (error)
        doc_call(n.doc, @"emit", @[@(n.uid), @"failed", @[error]]);
}

static void show_image(RXNode* n, NSString* source, RXDecoded* image, NSString* key) {
    if (![n.loaded isEqualToString:source])
        return;
    if (source.length)
        tell_status(n, image ? @"ready" : @"error", image ? nil : [@"could not load " stringByAppendingString:source]);
    else
        tell_status(n, @"", nil);
    CGFloat scale = backing_scale();
    n.layer.contents = image.image;
    n.layer.contentsScale = scale;
    n.image_px = image ? image.pixels : 0;
    n.image_native = image ? image.native : CGSizeZero;
    n.layer.minificationFilter = kCAFilterTrilinear;
    n.image_size = image ? image.size : CGSizeZero;
    invalidate(n);
    play_gif(n, image && key ? [gif_cache() objectForKey:key] : nil);
    if (n.doc)
        schedule_layout(n.doc, false);
}

void apply_image_shape(RXNode* n) {
    CALayer* layer = n.layer;
    NSString* shape = str(n, P::shape, @"");
    CALayer* own = layer.mask && !mask_passing(layer.mask) ? layer.mask : nil;
    if (!shape.length) {
        if (own)
            mask_set_own(layer, nil);
        return;
    }
    CAShapeLayer* mask = [own isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer*)own : nil;
    NSSize size = n.layer.bounds.size;
    {
        CAShapeLayer* m = mask ?: (CAShapeLayer*)still([CAShapeLayer layer]);
        CGAffineTransform t = layer_flip(layer, size.height);
        const bool fresh = !mask || ![m.name isEqualToString:shape] || !CGSizeEqualToSize(m.bounds.size, size);
        if (fresh) {
            m.transform = CATransform3DIdentity;
            m.frame = CGRectMake(0, 0, size.width, size.height);
            CGPathRef p = shape_path(shape, CGPointMake(size.width / 2, size.height / 2),
                                     MIN(size.width, size.height) / 2, 0, &t);
            m.path = p;
            CGPathRelease(p);
            m.name = shape;
        }
        const double turn = spin_angle(n);
        m.transform = turn == 0 ? CATransform3DIdentity : CATransform3DMakeRotation(t.d < 0 ? -turn : turn, 0, 0, 1);
        if (!mask)
            mask_set_own(layer, m);
    }
}

void apply_image_source(RXNode* n) {
    NSString* source = str(n, P::source, @"");
    if ([source isEqualToString:n.loaded])
        return;
    n.loaded = source;
    if (!source.length) {
        show_image(n, source, nil, nil);
        return;
    }
    tell_status(n, @"loading", nil);
    const CGSize box = n.layer.bounds.size;
    const CGFloat scale = backing_scale();
    NSString* fit = str(n, P::fit, @"cover");
    const CGFloat want = box.width > 0 && box.height > 0 ? MAX(box.width, box.height) * scale * 2 : k_unknown_max;
    bool gif = [source.pathExtension.lowercaseString isEqualToString:@"gif"];
    NSString* key = cache_key(source, want);
    RXDecoded* cached = [image_cache() objectForKey:key];
    if (cached && (!gif || [gif_cache() objectForKey:key])) {
        show_image(n, source, cached, key);
        return;
    }
    __weak RXNode* weak = n;
    auto decode = ^(NSData* data) {
        RXDecoded* image = nil;
        RXGif* anim = nil;
        if (CGImageSourceRef src = data ? CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr) : nullptr) {
            NSDictionary* pr = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(src, 0, nullptr));
            CGFloat iw = [pr[(__bridge NSString*)kCGImagePropertyPixelWidth] doubleValue];
            CGFloat ih = [pr[(__bridge NSString*)kCGImagePropertyPixelHeight] doubleValue];
            int orient = [pr[(__bridge NSString*)kCGImagePropertyOrientation] intValue];
            if (orient >= 5 && orient <= 8)
                std::swap(iw, ih);
            double dpi = [pr[(__bridge NSString*)kCGImagePropertyDPIWidth] doubleValue];
            CGFloat px = needed_px(box, scale, fit, iw, ih);
            if (CGImageRef img = decode_at(src, 0, px)) {
                image = [RXDecoded new];
                image.image = (__bridge_transfer id)img;
                image.pixels = MAX(CGImageGetWidth(img), CGImageGetHeight(img));
                double k = dpi > 0 ? 72.0 / dpi : 1;
                image.size =
                    iw > 0 ? NSMakeSize(iw * k, ih * k) : NSMakeSize(CGImageGetWidth(img), CGImageGetHeight(img));
                image.native = iw > 0 ? NSMakeSize(iw, ih) : NSMakeSize(CGImageGetWidth(img), CGImageGetHeight(img));
                anim = decode_gif(src, px, iw, ih);
            }
            CFRelease(src);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (anim)
                [gif_cache() setObject:anim forKey:key];
            if (image)
                [image_cache() setObject:image forKey:key];
            else if (data)
                rexui_log([NSString stringWithFormat:@"could not load image %@", source]);
            if (RXNode* n2 = weak)
                show_image(n2, source, image, key);
        });
    };
    if (files_image(source, ^(NSData* data) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                decode(data);
            });
        }))
        return;
    NSURL* url;
    if ([source hasPrefix:@"http://"] || [source hasPrefix:@"https://"] || [source hasPrefix:@"file:"]) {
        url = [NSURL URLWithString:source];
    } else {
        NSString* path = source.stringByExpandingTildeInPath;
        if (!path.isAbsolutePath)
            path = [doc_dir(n) stringByAppendingPathComponent:path];
        url = [NSURL fileURLWithPath:path];
    }
    if (!url)
        return;
    if (url.isFileURL) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData* data = [NSData dataWithContentsOfURL:url];
            if (!data)
                dispatch_async(dispatch_get_main_queue(), ^{
                    rexui_log([NSString stringWithFormat:@"could not load image %@", source]);
                });
            decode(data);
        });
    } else {
        [[NSURLSession.sharedSession
              dataTaskWithURL:url
            completionHandler:^(NSData* data, NSURLResponse*, NSError*) {
                if (!data)
                    dispatch_async(dispatch_get_main_queue(), ^{
                        rexui_log([NSString stringWithFormat:@"could not load image %@", source]);
                    });
                decode(data);
            }] resume];
    }
}

void image_resized(RXNode* n) {
    if (!n.loaded.length || n.image_px <= 0)
        return;
    CGSize b = n.layer.bounds.size;
    CGFloat need = needed_px(b, backing_scale(), str(n, P::fit, @"cover"), n.image_native.width, n.image_native.height);
    bool grow = need > n.image_px * 1.25 && n.image_px < MAX(n.image_native.width, n.image_native.height);
    bool shrink = need < n.image_px / 2 && n.image_px > 256;
    if (!grow && !shrink)
        return;
    n.loaded = nil;
    apply_image_source(n);
}

void image_caches_clear(void) {
    [image_cache() removeAllObjects];
    [gif_cache() removeAllObjects];
}

void apply_fit(RXNode* n) {
    NSString* fit = str(n, P::fit, @"cover");
    n.layer.contentsGravity = [fit isEqualToString:@"contain"] ? kCAGravityResizeAspect
        : [fit isEqualToString:@"fill"]                        ? kCAGravityResize
                                                               : kCAGravityResizeAspectFill;
}
