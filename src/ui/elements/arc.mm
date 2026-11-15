// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/sync/rmw.h"
#include "core/sync/triple.h"
#include "gpu/canvas.h"
#include "gpu/figures.h"
#include "gpu/gpu.h"
#include "ui/ui.h"

#include <algorithm>
#include <atomic>
#include <cmath>

using rx::gpu::ArcState;

@interface RXArcLayer : CAMetalLayer {
   @public
    rx::sync::Triple<ArcState> state;
    std::atomic<int> inflight;
    rx::gpu::LinkId tick;
    uint32_t gen;
    double published;
    uint32_t r_gen;
    double r_shown, r_phase, r_last;
}
@end
@implementation RXArcLayer
- (id<CAAction>)actionForKey:(NSString*)key {
    return nil;
}
@end

@interface RXArcLive : NSObject {
   @public
    RXArcLayer* layer;
}
@end
@implementation RXArcLive
@end

CALayer* make_arc(RXNode* n) {
    RXArcLayer* l = [RXArcLayer layer];
    l.device = rx::gpu::device();
    l.pixelFormat = MTLPixelFormatBGRA8Unorm;
    l.opaque = NO;
    l.framebufferOnly = YES;
    l.maximumDrawableCount = 3;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    l.colorspace = srgb;
    CGColorSpaceRelease(srgb);
    return l;
}

static simd_float4 rgba(NSColor* c) {
    c = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return simd_make_float4((float)c.redComponent, (float)c.greenComponent, (float)c.blueComponent,
                            (float)c.alphaComponent);
}

static std::atomic<uint64_t> g_arc_frames;
uint64_t arc_frames(void) {
    return g_arc_frames.load(std::memory_order_relaxed);
}

static bool arc_draw(RXArcLive* c, double now, id<MTLCommandBuffer> cb, bool always) {
    RXArcLayer* l = c->layer;
    (void)l->state.take();
    const ArcState& s = l->state.front();
    if (s.gen != l->r_gen) {
        if (s.snap || l->r_gen == 0)
            l->r_shown = s.value;
        else if (l->r_last == 0)
            l->r_shown = s.from;
    }
    const double dt = l->r_last > 0 ? std::min(0.1, now - l->r_last) : 0;
    l->r_last = now;
    const bool gliding = std::fabs(l->r_shown - s.value) > 1e-4;
    if (gliding) {
        l->r_shown += (s.value - l->r_shown) * (1 - exp(-dt / 0.12));
        if (std::fabs(s.value - l->r_shown) < 1e-4)
            l->r_shown = s.value;
    }
    const bool waves = s.wavy && s.waving;
    if (waves)
        l->r_phase = fmod(l->r_phase + dt / std::max(0.05, (double)s.period), 1);
    if (!always && !gliding && !waves && s.gen == l->r_gen)
        return false;
    if (s.w < 1 || s.h < 1 || l->inflight.load(std::memory_order_relaxed) >= 2)
        return false;
    id<CAMetalDrawable> d = [l nextDrawable];
    if (!d || d.texture.width != s.dw || d.texture.height != s.dh)
        return false;
    rx::gpu::Shape shapes[64];
    const uint32_t n = rx::gpu::arc_figure(s, l->r_shown, l->r_phase, shapes);
    if (!rx::gpu::canvas_encode(cb, d.texture, shapes, n, s.scale, true))
        return false;
    [cb presentDrawable:d];
    l->r_gen = s.gen;
    g_arc_frames.store(g_arc_frames.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    l->inflight.store(l->inflight.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    RXArcLayer* held = l;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        (void)d;
        rx::sync::fetch_sub(held->inflight, 1, std::memory_order_relaxed);
    }];
    return true;
}
static bool arc_tick(void* ctx, double now, id<MTLCommandBuffer> cb) {
    return arc_draw((__bridge RXArcLive*)ctx, now, cb, false);
}
static void arc_gone(void* ctx) {
    (void)(__bridge_transfer RXArcLive*)ctx;
}
static void arc_once(rx::gpu::Job& job, id<MTLCommandBuffer> cb) {
    void* ctx;
    memcpy(&ctx, job.data, sizeof ctx);
    arc_draw((__bridge_transfer RXArcLive*)ctx, CACurrentMediaTime(), cb, true);
}

void arc_watch(RXNode* n) {
    RXArcLayer* l = [n.layer isKindOfClass:RXArcLayer.class] ? (RXArcLayer*)n.layer : nil;
    if (!l)
        return;
    if (!l->tick.v)
        return draw_arc(n);
    if (!(flag(n, P::wavy, false) && flag(n, P::waving, true)) && CACurrentMediaTime() - l->published > 1)
        arc_stop(n), node_link(n, false);
}

void arc_stop(RXNode* n) {
    RXArcLayer* l = [n.layer isKindOfClass:RXArcLayer.class] ? (RXArcLayer*)n.layer : nil;
    if (!l || !l->tick.v || !rx::gpu::link_remove(l->tick))
        return;
    l->tick = {};
}
double arc_clock_fps(RXNode* n) {
    RXArcLayer* l = [n.layer isKindOfClass:RXArcLayer.class] ? (RXArcLayer*)n.layer : nil;
    return l && l->tick.v ? 4 : 120;
}

void draw_arc(RXNode* n) {
    RXArcLayer* l = [n.layer isKindOfClass:RXArcLayer.class] ? (RXArcLayer*)n.layer : nil;
    if (!l)
        return;
    const CGSize size = l.bounds.size;
    const CGFloat scale = backing_scale();
    const CGSize want = CGSizeMake(MAX(1, round(size.width * scale)), MAX(1, round(size.height * scale)));
    if (!CGSizeEqualToSize(l.drawableSize, want))
        l.drawableSize = want;
    if (l.contentsScale != scale)
        l.contentsScale = scale;
    const double target = MAX(0, MIN(1, num(n, P::value, 0)));
    ArcState& s = l->state.back();
    s.w = (float)size.width, s.h = (float)size.height, s.scale = (float)scale;
    s.dw = (uint32_t)want.width, s.dh = (uint32_t)want.height;
    s.stroke = (float)num(n, P::thickness, 6), s.gap = (float)num(n, P::gap, 8);
    s.start = (float)num(n, P::start, -90), s.sweep = (float)num(n, P::sweep, 360);
    s.waves = (float)num(n, P::waves, flag(n, P::line, false) ? 5 : 8),
    s.period = (float)(MAX(50, num(n, P::wavePeriod, 2000)) / 1000);
    s.from = (float)n.shown_value, s.value = (float)target;
    s.snap = n.shown_value == target;
    s.wavy = flag(n, P::wavy, false), s.waving = flag(n, P::waving, true), s.dot = flag(n, P::dot, true),
    s.line = flag(n, P::line, false);
    s.fg = rgba(parse_color(obj_of(n, P::color)) ?: g_theme.fg);
    s.bg = rgba(parse_color(obj_of(n, P::track)) ?: [g_theme.fg colorWithAlphaComponent:0.2]);
    s.gen = ++l->gen;
    l->state.publish();
    l->published = CACurrentMediaTime();
    n.shown_value = target;
    if (size.width < 1 || size.height < 1)
        return;
    const bool moves = (s.wavy && s.waving) || !s.snap;
    if (moves && node_on_screen(n)) {
        if (l->tick.v)
            return;
        l->r_last = 0;
        RXArcLive* c = [RXArcLive new];
        c->layer = l;
        void* ctx = (__bridge_retained void*)c;
        l->tick = ui_gpu_clock() ? rx::gpu::link_add(120, arc_tick, arc_gone, ctx) : rx::gpu::LinkId{};
        if (!l->tick.v)
            (void)(__bridge_transfer RXArcLive*)ctx;
        return;
    }
    if (l->tick.v && !(s.wavy && s.waving))
        arc_stop(n);
    RXArcLive* c = [RXArcLive new];
    c->layer = l;
    void* ctx = (__bridge_retained void*)c;
    rx::gpu::Job job;
    job.encode = arc_once;
    memcpy(job.data, &ctx, sizeof ctx);
    if (!rx::gpu::render_start() || !rx::gpu::render_push(job))
        (void)(__bridge_transfer RXArcLive*)ctx;
}

static bool arc_value_at(RXNode* n, NSPoint p, double* value, bool anywhere) {
    NSSize size = n.layer.bounds.size;
    double stroke = num(n, P::thickness, 6), amp = flag(n, P::wavy, false) ? 0.5 : 0;
    double reach = MAX(14, stroke * 2);
    CGPoint c = CGPointMake(size.width / 2, size.height / 2);
    if (flag(n, P::line, false)) {
        double x0 = stroke / 2, len = MAX(1, size.width - stroke);
        *value = MAX(0, MIN(1, (p.x - x0) / len));
        return anywhere || fabs(p.y - c.y) <= reach;
    }
    double side = MIN(size.width, size.height), radius = MAX(1, (side - stroke * (1 + amp * 2)) / 2);
    double start = num(n, P::start, -90), sweep = MAX(1, MIN(360, num(n, P::sweep, 360)));
    double deg = atan2(p.y - c.y, p.x - c.x) * 180 / M_PI;
    double along = fmod(fmod(deg - start, 360) + 360, 360);
    double over = along - sweep;
    if (over > 0)
        *value = over < 360 - along ? 1 : 0;
    else
        *value = along / sweep;
    if (anywhere)
        return true;
    if (fabs(hypot(p.x - c.x, p.y - c.y) - radius) > reach)
        return false;
    return over <= 0 || MIN(over, 360 - along) * M_PI / 180 * radius <= reach;
}

bool arc_hit(RXNode* n, NSPoint p) {
    double v;
    return flag(n, P::seekable, false) && arc_value_at(n, p, &v, false);
}

void arc_track(RXNode* n, NSPoint p, int phase) {
    double v = 0;
    arc_value_at(n, p, &v, true);
    n.shown_value = v;
    draw_arc(n);
    if (n.doc.ctx)
        doc_call(n.doc, @"emit", @[@(n.uid), phase == 2 ? @"released" : @"moved", @[@(v)]]);
}
