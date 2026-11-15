// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/sync/rmw.h"
#include "core/sync/triple.h"
#include "gpu/canvas.h"
#include "gpu/gpu.h"
#include "ui/ui.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <vector>

namespace {
struct Wave {
    double amp, freq, phase;
    double at(double t) const { return amp * sin(freq * t + phase); }
};
struct Drifter {
    double x, y, size;
    double heading, speed;
    double turn, spin;
    double t;
    Wave bend1, bend2, pace, sway;
    float scallops;
    simd_float4 color;
};

struct ShapesState {
    float w = 0, h = 0, scale = 1;
    uint32_t dw = 0, dh = 0;
    uint32_t count = 14;
    double lo = 36, hi = 124, slow = 4, fast = 18, turn = 12 * M_PI / 180;
    bool moving = true;
    uint32_t gen = 0, seed_gen = 0;
    uint32_t ncolors = 0, nshapes = 0;
    simd_float4 colors[16];
    float shapes[16];
};
}

@interface RXShapesLayer : CAMetalLayer {
   @public
    rx::sync::Triple<ShapesState> state;
    std::atomic<int> inflight;
    rx::gpu::LinkId tick;
    uint32_t gen, seed_gen;
    std::vector<Drifter> drifters;
    uint32_t r_gen, r_seed_gen;
    double r_last;
}
@end
@implementation RXShapesLayer
- (id<CAAction>)actionForKey:(NSString*)key {
    return nil;
}
@end

@interface RXShapesLive : NSObject {
   @public
    RXShapesLayer* layer;
}
@end
@implementation RXShapesLive
@end

CALayer* make_shapes(RXNode* n) {
    RXShapesLayer* l = [RXShapesLayer layer];
    l.device = rx::gpu::device();
    l.pixelFormat = MTLPixelFormatBGRA8Unorm;
    l.opaque = NO;
    l.framebufferOnly = YES;
    l.maximumDrawableCount = 3;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    l.colorspace = srgb;
    CGColorSpaceRelease(srgb);
    l->drifters.reserve(64);
    return l;
}

static double rand_in(double lo, double hi) {
    return lo + (arc4random() / 4294967296.0) * (hi - lo);
}
static Wave wave(double amp, double slowest, double fastest) {
    return {amp, rand_in(slowest, fastest), rand_in(0, 2 * M_PI)};
}
static void set_path(Drifter& d, double slow, double fast, double turn) {
    d.heading = rand_in(0, 2 * M_PI);
    d.speed = rand_in(slow, fast);
    d.spin = rand_in(-turn, turn);
    d.t = 0;
    d.bend1 = wave(rand_in(0.06, 0.14), 2 * M_PI / 70, 2 * M_PI / 25);
    d.bend2 = wave(rand_in(0.03, 0.08), 2 * M_PI / 18, 2 * M_PI / 8);
    d.pace = wave(rand_in(0.15, 0.35), 2 * M_PI / 40, 2 * M_PI / 15);
    d.sway = wave(rand_in(0.3, 0.8), 2 * M_PI / 50, 2 * M_PI / 20);
}

static void set_looks(std::vector<Drifter>& ds, const ShapesState& s) {
    uint32_t x = (uint32_t)ds.size() * 7919u + 1;
    auto next = [&x] {
        x ^= x << 13, x ^= x >> 17, x ^= x << 5;
        return x;
    };
    for (Drifter& d : ds) {
        d.scallops = s.nshapes ? s.shapes[next() % s.nshapes] : 0;
        d.color = s.ncolors ? s.colors[next() % s.ncolors] : simd_make_float4(1, 1, 1, 0.16f);
    }
}

static void seed(std::vector<Drifter>& ds, const ShapesState& s) {
    const uint32_t count = std::min<uint32_t>(64, s.count);
    const int cols = std::max(1, (int)ceil(sqrt(count * s.w / std::max(1.0f, s.h))));
    const int rows = std::max(1, (int)ceil((double)count / cols));
    int cells[64 * 64];
    const int ncells = std::min(cols * rows, 64 * 64);
    for (int i = 0; i < ncells; i++)
        cells[i] = i;
    for (int i = ncells; i > 1; i--)
        std::swap(cells[i - 1], cells[arc4random_uniform((uint32_t)i)]);
    const double cw = s.w / cols, ch = s.h / rows;
    ds.clear();
    for (uint32_t i = 0; i < count; i++) {
        Drifter d{};
        d.size = s.lo + (count > 1 ? (double)i / count : 0) * (s.hi - s.lo);
        const int c = cells[i % ncells];
        d.x = (c % cols + rand_in(0.15, 0.85)) * cw - d.size / 2;
        d.y = (c / cols + rand_in(0.15, 0.85)) * ch - d.size / 2;
        set_path(d, s.slow, s.fast, s.turn);
        d.turn = rand_in(0, 2 * M_PI);
        d.t = rand_in(0, 60);
        ds.push_back(d);
    }
}

static void drift(std::vector<Drifter>& ds, const ShapesState& s, double dt) {
    for (Drifter& d : ds) {
        d.t += dt;
        d.heading += (d.bend1.at(d.t) + d.bend2.at(d.t)) * dt;
        const double speed = d.speed * (1 + d.pace.at(d.t));
        d.x += cos(d.heading) * speed * dt;
        d.y += sin(d.heading) * speed * dt;
        d.turn += d.spin * (1 + d.sway.at(d.t)) * dt;
        double in;
        if (d.x + d.size < 0)
            d.x = s.w, d.y = rand_in(-d.size / 2, s.h - d.size / 2), in = M_PI;
        else if (d.x > s.w)
            d.x = -d.size, d.y = rand_in(-d.size / 2, s.h - d.size / 2), in = 0;
        else if (d.y + d.size < 0)
            d.y = s.h, d.x = rand_in(-d.size / 2, s.w - d.size / 2), in = -M_PI / 2;
        else if (d.y > s.h)
            d.y = -d.size, d.x = rand_in(-d.size / 2, s.w - d.size / 2), in = M_PI / 2;
        else
            continue;
        const double place = d.turn;
        set_path(d, s.slow, s.fast, s.turn);
        d.heading = in + rand_in(-M_PI / 3, M_PI / 3);
        d.turn = place;
    }
}

static std::atomic<uint64_t> g_shapes_frames;
uint64_t shapes_frames(void) {
    return g_shapes_frames.load(std::memory_order_relaxed);
}

static bool shapes_draw(RXShapesLive* c, double now, id<MTLCommandBuffer> cb, bool always) {
    RXShapesLayer* l = c->layer;
    (void)l->state.take();
    const ShapesState& s = l->state.front();
    if (s.w < 1 || s.h < 1)
        return false;
    const bool changed = s.gen != l->r_gen;
    if (s.seed_gen != l->r_seed_gen || l->drifters.empty())
        seed(l->drifters, s), l->r_seed_gen = s.seed_gen, set_looks(l->drifters, s);
    else if (changed)
        set_looks(l->drifters, s);
    const double dt = l->r_last > 0 ? std::min(0.1, now - l->r_last) : 0;
    l->r_last = now;
    if (s.moving)
        drift(l->drifters, s, dt);
    if (!always && !s.moving && !changed)
        return false;
    if (l->inflight.load(std::memory_order_relaxed) >= 2)
        return false;
    id<CAMetalDrawable> d = [l nextDrawable];
    if (!d || d.texture.width != s.dw || d.texture.height != s.dh)
        return false;
    rx::gpu::Shape shapes[64];
    uint32_t n = 0;
    for (const Drifter& f : l->drifters)
        if (n < 64)
            shapes[n++] = rx::gpu::cookie((float)(f.x + f.size / 2), (float)(f.y + f.size / 2), (float)(f.size / 2),
                                          (float)f.turn, f.scallops, f.color);
    if (!rx::gpu::canvas_encode(cb, d.texture, shapes, n, s.scale, true))
        return false;
    [cb presentDrawable:d];
    l->r_gen = s.gen;
    g_shapes_frames.store(g_shapes_frames.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    l->inflight.store(l->inflight.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    RXShapesLayer* held = l;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        (void)d;
        rx::sync::fetch_sub(held->inflight, 1, std::memory_order_relaxed);
    }];
    return true;
}
static bool shapes_tick_fn(void* ctx, double now, id<MTLCommandBuffer> cb) {
    return shapes_draw((__bridge RXShapesLive*)ctx, now, cb, false);
}
static void shapes_gone(void* ctx) {
    (void)(__bridge_transfer RXShapesLive*)ctx;
}
static void shapes_once(rx::gpu::Job& job, id<MTLCommandBuffer> cb) {
    void* ctx;
    memcpy(&ctx, job.data, sizeof ctx);
    shapes_draw((__bridge_transfer RXShapesLive*)ctx, CACurrentMediaTime(), cb, true);
}

bool shapes_moving(RXNode* n) {
    return flag(n, P::moving, true) && num(n, P::count, 14) > 0;
}

void shapes_stop(RXNode* n) {
    RXShapesLayer* l = [n.layer isKindOfClass:RXShapesLayer.class] ? (RXShapesLayer*)n.layer : nil;
    if (!l || !l->tick.v || !rx::gpu::link_remove(l->tick))
        return;
    l->tick = {};
}
double shapes_clock_fps(RXNode* n) {
    RXShapesLayer* l = [n.layer isKindOfClass:RXShapesLayer.class] ? (RXShapesLayer*)n.layer : nil;
    return l && l->tick.v ? 4 : 120;
}

static NSArray* array_prop(RXNode* n, NSString* name) {
    id a = obj(n, name);
    return [a isKindOfClass:NSArray.class] ? a : @[];
}

void shapes_apply(RXNode* n, NSString* name) {
    RXShapesLayer* l = [n.layer isKindOfClass:RXShapesLayer.class] ? (RXShapesLayer*)n.layer : nil;
    if (!l)
        return;
    const CGSize size = l.bounds.size;
    if (size.width <= 0 || size.height <= 0)
        return;
    static NSSet* looks = [NSSet setWithArray:@[@"colors", @"opacities", @"shapes", @"moving"]];
    const CGFloat scale = backing_scale();
    const CGSize want = CGSizeMake(MAX(1, round(size.width * scale)), MAX(1, round(size.height * scale)));
    if (!CGSizeEqualToSize(l.drawableSize, want))
        l.drawableSize = want;
    if (l.contentsScale != scale)
        l.contentsScale = scale;
    ShapesState& s = l->state.back();
    s.w = (float)size.width, s.h = (float)size.height, s.scale = (float)scale;
    s.dw = (uint32_t)want.width, s.dh = (uint32_t)want.height;
    s.count = (uint32_t)MAX(0, MIN(64, num(n, P::count, 14)));
    s.lo = num(n, P::minSize, 36), s.hi = num(n, P::maxSize, 124);
    s.slow = num(n, P::minSpeed, 4), s.fast = num(n, P::maxSpeed, 18), s.turn = num(n, P::turn, 12) * M_PI / 180;
    s.moving = shapes_moving(n);
    NSArray *colours = array_prop(n, @"colors"), *opacities = array_prop(n, @"opacities"),
            *shapes = array_prop(n, @"shapes");
    if (!shapes.count)
        shapes = @[@"circle", @"cookie4", @"cookie6", @"cookie7", @"cookie9", @"cookie12"];
    s.ncolors = (uint32_t)MIN(16, MAX(colours.count, 1));
    for (uint32_t i = 0; i < s.ncolors; i++) {
        NSColor* c = [((i < colours.count ? parse_color(colours[i]) : nil) ?: g_theme.fg)
            colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        const double o = i < opacities.count ? num_of(opacities[i], 0.16) : 0.16;
        s.colors[i] = simd_make_float4((float)c.redComponent, (float)c.greenComponent, (float)c.blueComponent,
                                       (float)(c.alphaComponent * o));
    }
    s.nshapes = (uint32_t)MIN(16, shapes.count);
    for (uint32_t i = 0; i < s.nshapes; i++)
        s.shapes[i] = (float)shape_scallops(string_of(shapes[i]) ?: @"circle");
    if (name && ![looks containsObject:name])
        ++l->seed_gen;
    s.seed_gen = l->seed_gen;
    s.gen = ++l->gen;
    l->state.publish();
    if (s.moving && node_on_screen(n)) {
        if (!l->tick.v) {
            l->r_last = 0;
            RXShapesLive* c = [RXShapesLive new];
            c->layer = l;
            void* ctx = (__bridge_retained void*)c;
            l->tick = ui_gpu_clock() ? rx::gpu::link_add(120, shapes_tick_fn, shapes_gone, ctx) : rx::gpu::LinkId{};
            if (!l->tick.v)
                (void)(__bridge_transfer RXShapesLive*)ctx;
        }
        node_link(n, true);
        node_link_rate(n);
        return;
    }
    shapes_stop(n);
    RXShapesLive* c = [RXShapesLive new];
    c->layer = l;
    void* ctx = (__bridge_retained void*)c;
    rx::gpu::Job job;
    job.encode = shapes_once;
    memcpy(job.data, &ctx, sizeof ctx);
    if (!rx::gpu::render_start() || !rx::gpu::render_push(job))
        (void)(__bridge_transfer RXShapesLive*)ctx;
    node_link(n, true);
}

void shapes_tick(RXNode* n, double) {
    RXShapesLayer* l = [n.layer isKindOfClass:RXShapesLayer.class] ? (RXShapesLayer*)n.layer : nil;
    if (l && !l->tick.v)
        shapes_apply(n, @"moving");
}
