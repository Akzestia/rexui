// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>

static uint32_t u32(const uint8_t* p) {
    return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint16_t u16(const uint8_t* p) {
    return p[0] | p[1] << 8;
}

static bool is_png(NSData* d) {
    static const uint8_t sig[8] = {0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
    return d.length >= 8 && memcmp(d.bytes, sig, 8) == 0;
}

CF_RETURNS_RETAINED static CGImageRef image_at(NSData* d, size_t index) {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)d, nullptr);
    if (!src)
        return nullptr;
    CGImageRef img =
        index < CGImageSourceGetCount(src) ? CGImageSourceCreateImageAtIndex(src, index, nullptr) : nullptr;
    CFRelease(src);
    return img;
}

CF_RETURNS_RETAINED static CGImageRef decode_dib(const uint8_t* b, size_t n) {
    if (n < 40)
        return nullptr;
    uint32_t hsize = u32(b), comp = u32(b + 16), used = u32(b + 32);
    int32_t w = (int32_t)u32(b + 4), h2 = (int32_t)u32(b + 8);
    int bpp = u16(b + 14);
    int64_t hh = h2 < 0 ? -(int64_t)h2 : (int64_t)h2;
    int h = (int)(hh / 2 > 4096 ? 4096 : hh / 2);
    if (w <= 0 || w > 512 || h <= 0 || h > 512 || hsize < 40 || hsize > n || (comp != 0 && comp != 3))
        return nullptr;
    if (bpp != 1 && bpp != 4 && bpp != 8 && bpp != 24 && bpp != 32)
        return nullptr;
    size_t at = hsize + (comp == 3 && hsize == 40 ? 12 : 0);
    size_t colors = bpp <= 8 ? (used ? used : 1u << bpp) : 0;
    const uint8_t* pal = b + at;
    at += colors * 4;
    size_t stride = ((size_t)w * bpp + 31) / 32 * 4, mstride = ((size_t)w + 31) / 32 * 4;
    if (at + stride * h > n)
        return nullptr;
    const uint8_t *px = b + at, *mask = at + stride * h + mstride * h <= n ? px + stride * h : nullptr;
    NSMutableData* out = [NSMutableData dataWithLength:(size_t)w * h * 4];
    uint8_t* o = (uint8_t*)out.mutableBytes;
    bool own_alpha = false;
    if (bpp == 32)
        for (int y = 0; y < h && !own_alpha; y++)
            for (int x = 0; x < w; x++)
                if (px[y * stride + x * 4 + 3]) {
                    own_alpha = true;
                    break;
                }
    for (int y = 0; y < h; y++) {
        const uint8_t* row = px + (size_t)(h - 1 - y) * stride;
        const uint8_t* mrow = mask ? mask + (size_t)(h - 1 - y) * mstride : nullptr;
        for (int x = 0; x < w; x++) {
            uint8_t r, g, bl, a = 255;
            if (bpp <= 8) {
                int bit = x * bpp, v = (row[bit / 8] >> (8 - bpp - bit % 8)) & ((1 << bpp) - 1);
                const uint8_t* c = (size_t)v < colors ? pal + v * 4 : pal;
                bl = c[0], g = c[1], r = c[2];
            } else {
                const uint8_t* c = row + x * (bpp / 8);
                bl = c[0], g = c[1], r = c[2];
                if (bpp == 32 && own_alpha)
                    a = c[3];
            }
            if (!own_alpha && mrow && (mrow[x / 8] >> (7 - x % 8) & 1))
                a = 0;
            uint8_t* d = o + ((size_t)y * w + x) * 4;
            d[0] = r * a / 255, d[1] = g * a / 255, d[2] = bl * a / 255, d[3] = a;
        }
    }
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)out);
    CGImageRef img = CGImageCreate(w, h, 8, 32, (size_t)w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast, dp,
                                   nullptr, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    return img;
}

CF_RETURNS_RETAINED static CGImageRef decode_icon(NSData* data, CGPoint* hot) {
    *hot = CGPointZero;
    if (is_png(data))
        return image_at(data, 0);
    const uint8_t* b = (const uint8_t*)data.bytes;
    if (data.length < 6 || u16(b) != 0)
        return nullptr;
    uint16_t type = u16(b + 2), count = u16(b + 4);
    if ((type != 1 && type != 2) || !count || data.length < 6 + 16 * (size_t)count)
        return nullptr;
    size_t best = 0;
    int best_w = -1;
    for (size_t i = 0; i < count; i++) {
        int w = b[6 + 16 * i] ? b[6 + 16 * i] : 256;
        if (w > best_w)
            best_w = w, best = i;
    }
    const uint8_t* e = b + 6 + 16 * best;
    int nominal = e[0] ? e[0] : 256;
    if (type == 2)
        *hot = CGPointMake(u16(e + 4), u16(e + 6));
    NSMutableData* ico = [data mutableCopy];
    ((uint8_t*)ico.mutableBytes)[2] = 1;
    CGImageRef img = image_at(ico, best);
    if (!img) {
        uint32_t size = u32(e + 8), off = u32(e + 12);
        if ((size_t)off + size <= data.length) {
            NSData* entry = [data subdataWithRange:NSMakeRange(off, size)];
            img = is_png(entry) ? image_at(entry, 0) : decode_dib((const uint8_t*)entry.bytes, entry.length);
        }
    }
    if (img && CGImageGetWidth(img) != (size_t)nominal && nominal > 0) {
        double k = (double)CGImageGetWidth(img) / nominal;
        *hot = CGPointMake(hot->x * k, hot->y * k);
    }
    return img;
}

static NSDictionary* frame(CGImageRef img, CGPoint hot, double delay) {
    return
        @{@"image": (__bridge id)img,
          @"hotspot": [NSValue valueWithPoint:NSPointFromCGPoint(hot)],
          @"delay": @(delay)};
}

static NSArray<NSDictionary*>* ani_frames(NSData* data, NSString** error) {
    const uint8_t* b = (const uint8_t*)data.bytes;
    size_t n = data.length;
    if (n < 12 || memcmp(b, "RIFF", 4) || memcmp(b + 8, "ACON", 4)) {
        if (error)
            *error = @"not an animated cursor (RIFF ACON)";
        return nil;
    }
    uint32_t steps = 0, rate = 10;
    NSMutableArray<NSNumber*>*rates = [NSMutableArray array], *seq = [NSMutableArray array];
    NSMutableArray<NSData*>* icons = [NSMutableArray array];
    for (size_t at = 12; at + 8 <= n;) {
        uint32_t size = u32(b + at + 4);
        size_t body = at + 8;
        if (body + size > n)
            size = (uint32_t)(n - body);
        if (!memcmp(b + at, "anih", 4) && size >= 36) {
            steps = u32(b + body + 8);
            rate = u32(b + body + 28);
        } else if (!memcmp(b + at, "rate", 4)) {
            for (size_t i = 0; i + 4 <= size; i += 4)
                [rates addObject:@(u32(b + body + i))];
        } else if (!memcmp(b + at, "seq ", 4)) {
            for (size_t i = 0; i + 4 <= size; i += 4)
                [seq addObject:@(u32(b + body + i))];
        } else if (!memcmp(b + at, "LIST", 4) && size >= 4 && !memcmp(b + body, "fram", 4)) {
            for (size_t s = body + 4; s + 8 <= body + size;) {
                uint32_t len = u32(b + s + 4);
                if (s + 8 + len > body + size)
                    break;
                if (!memcmp(b + s, "icon", 4))
                    [icons addObject:[data subdataWithRange:NSMakeRange(s + 8, len)]];
                s += 8 + len + (len & 1);
            }
        }
        at = body + size + (size & 1);
    }
    NSMutableArray *images = [NSMutableArray array], *hots = [NSMutableArray array];
    for (NSData* icon in icons) {
        CGPoint hot;
        CGImageRef img = decode_icon(icon, &hot);
        if (!img)
            continue;
        [images addObject:(__bridge_transfer id)img];
        [hots addObject:[NSValue valueWithPoint:NSPointFromCGPoint(hot)]];
    }
    if (!images.count) {
        if (error)
            *error = @"no frames";
        return nil;
    }
    if (!steps)
        steps = seq.count ? (uint32_t)seq.count : (uint32_t)images.count;
    steps = MIN(steps, MAX((uint32_t)MAX(seq.count, images.count), 1u));
    steps = MIN(steps, 4096u);
    NSMutableArray* out = [NSMutableArray array];
    for (uint32_t i = 0; i < steps; i++) {
        NSUInteger f = i < seq.count ? seq[i].unsignedIntValue : i;
        if (f >= images.count)
            f = images.count - 1;
        uint32_t jiffies = i < rates.count ? rates[i].unsignedIntValue : rate;
        [out addObject:frame((__bridge CGImageRef)images[f], [hots[f] pointValue], MAX(jiffies, 1u) / 60.0)];
    }
    return out;
}

NSArray<NSDictionary*>* cursor_file_frames(NSString* path, NSString** error) {
    NSData* data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) {
        if (error)
            *error = @"can't read it";
        return nil;
    }
    if (data.length >= 4 && !memcmp(data.bytes, "RIFF", 4))
        return ani_frames(data, error);
    CGPoint hot;
    CGImageRef img = decode_icon(data, &hot);
    if (!img) {
        if (error)
            *error = @"not a cursor, icon or PNG";
        return nil;
    }
    NSDictionary* f = frame(img, hot, 0);
    CGImageRelease(img);
    return @[f];
}
