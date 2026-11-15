// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include "core/sync/rmw.h"
#include "core/sync/triple.h"
#include "gpu/canvas.h"
#include "gpu/figures.h"
#include "gpu/gpu.h"
#include "rexui_frames.h"

#include <algorithm>
#include <atomic>
#include <cmath>

@interface RXFrames : NSObject {
   @public
    rexui_frames_reader reader;
}
@end
@implementation RXFrames
- (void)dealloc {
    rexui_frames_unmap(&reader);
}
@end

static RXFrames* frames_named(NSString* name) {
    static NSMapTable<NSString*, RXFrames*>* mapped = [NSMapTable strongToWeakObjectsMapTable];
    if (RXFrames* f = [mapped objectForKey:name])
        return f;
    RXFrames* f = [RXFrames new];
    if (![name hasPrefix:@"/"] || name.length > 31 || rexui_frames_open(&f->reader, name.UTF8String) != 0)
        return nil;
    [mapped setObject:f forKey:name];
    return f;
}

bool take_frame(RXNode* n) {
    RXFrames* f = n.frames;
    if (!f)
        return false;
    NSMutableData* d = [n.frame isKindOfClass:NSMutableData.class] ? (NSMutableData*)n.frame : nil;
    if (!d)
        n.frame = d = [NSMutableData dataWithLength:f->reader.capacity * sizeof(float)];
    if (d.length < f->reader.capacity * sizeof(float))
        d.length = f->reader.capacity * sizeof(float);
    long got = rexui_frames_copy(&f->reader, (float*)d.mutableBytes, f->reader.capacity);
    if (got < 0)
        return false;
    d.length = (NSUInteger)got * sizeof(float);
    return true;
}

bool is_canvas(RXNode* n) {
    return is_elem(n, E::Visualiser) || is_elem(n, E::Arc);
}

using rx::gpu::VisState;

@interface RXVisLayer : CAMetalLayer {
   @public
    rx::sync::Triple<VisState> state;
    std::atomic<int> inflight;
    rx::gpu::LinkId tick;
    uint32_t gen;
    uint32_t r_drawn_gen;
    uint32_t r_have;
    float r_frame[512];
}
@property(nonatomic, strong) RXFrames* reading;
@end
@implementation RXVisLayer
- (id<CAAction>)actionForKey:(NSString*)key {
    return nil;
}
@end

@interface RXVisLive : NSObject {
   @public
    RXVisLayer* layer;
    RXFrames* frames;
}
@end
@implementation RXVisLive
@end

CALayer* make_visualiser(RXNode* n) {
    RXVisLayer* l = [RXVisLayer layer];
    l.device = rx::gpu::device();
    l.pixelFormat = MTLPixelFormatBGRA8Unorm;
    l.opaque = NO;
    l.framebufferOnly = YES;
    l.maximumDrawableCount = 3;
    l.allowsNextDrawableTimeout = YES;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    l.colorspace = srgb;
    CGColorSpaceRelease(srgb);
    return l;
}

static std::atomic<uint64_t> g_vis_frames;
uint64_t visualiser_frames(void) {
    return g_vis_frames.load(std::memory_order_relaxed);
}

static bool vis_draw(RXVisLive* c, double now, id<MTLCommandBuffer> cb, bool always) {
    RXVisLayer* l = c->layer;
    (void)l->state.take();
    const VisState& s = l->state.front();
    bool fresh = always || s.gen != l->r_drawn_gen || s.spin_period > 0;
    if (c->frames) {
        const long got = rexui_frames_copy(&c->frames->reader, l->r_frame, 512);
        if (got >= 0)
            l->r_have = (uint32_t)got, fresh = true;
    }
    if (!fresh || s.w < 1 || s.h < 1)
        return false;
    if (l->inflight.load(std::memory_order_relaxed) >= 2)
        return false;
    id<CAMetalDrawable> d = [l nextDrawable];
    if (!d || d.texture.width != s.dw || d.texture.height != s.dh)
        return false;
    static rx::gpu::Shape shapes[512];
    const float* frame = c->frames ? l->r_frame : s.values;
    const uint32_t have = c->frames ? l->r_have : s.nvalues;
    const uint32_t n = rx::gpu::bars_figure(s, frame, have, now, shapes, 512);
    if (!rx::gpu::canvas_encode(cb, d.texture, shapes, n, s.scale, true))
        return false;
    [cb presentDrawable:d];
    l->r_drawn_gen = s.gen;
    g_vis_frames.store(g_vis_frames.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    l->inflight.store(l->inflight.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    RXVisLayer* held = l;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        (void)d;
        rx::sync::fetch_sub(held->inflight, 1, std::memory_order_relaxed);
    }];
    return true;
}
static bool vis_tick(void* ctx, double now, id<MTLCommandBuffer> cb) {
    return vis_draw((__bridge RXVisLive*)ctx, now, cb, false);
}
static void vis_gone(void* ctx) {
    (void)(__bridge_transfer RXVisLive*)ctx;
}
static void vis_once(rx::gpu::Job& job, id<MTLCommandBuffer> cb) {
    void* ctx;
    memcpy(&ctx, job.data, sizeof ctx);
    RXVisLive* c = (__bridge_transfer RXVisLive*)ctx;
    vis_draw(c, CACurrentMediaTime(), cb, true);
}

static bool vis_moves(RXNode* n) {
    return n.frames || (n.spin_period > 0 && str(n, P::shape, @"").length);
}

void visualiser_stop(RXNode* n) {
    RXVisLayer* l = [n.layer isKindOfClass:RXVisLayer.class] ? (RXVisLayer*)n.layer : nil;
    if (!l || !l->tick.v || !rx::gpu::link_remove(l->tick))
        return;
    l->tick = {};
}
double visualiser_clock_fps(RXNode* n) {
    RXVisLayer* l = [n.layer isKindOfClass:RXVisLayer.class] ? (RXVisLayer*)n.layer : nil;
    return l && l->tick.v ? 4 : 120;
}

void draw_visualiser(RXNode* n) {
    RXVisLayer* l = [n.layer isKindOfClass:RXVisLayer.class] ? (RXVisLayer*)n.layer : nil;
    if (!l)
        return;
    const CGSize size = l.bounds.size;
    const CGFloat scale = backing_scale();
    const CGSize want = CGSizeMake(MAX(1, round(size.width * scale)), MAX(1, round(size.height * scale)));
    if (!CGSizeEqualToSize(l.drawableSize, want))
        l.drawableSize = want;
    if (l.contentsScale != scale)
        l.contentsScale = scale;
    VisState& s = l->state.back();
    s.w = (float)size.width, s.h = (float)size.height, s.scale = (float)scale;
    s.dw = (uint32_t)want.width, s.dh = (uint32_t)want.height;
    s.count = (uint32_t)MAX(0, MIN(512, num(n, P::bars, 60)));
    s.scallops = (uint32_t)shape_scallops(str(n, P::shape, @"circle"));
    s.cover = (float)num(n, P::cover, 0), s.gap = (float)num(n, P::gap, 12);
    s.width_set = has_num(n, P::barWidth), s.width = (float)num(n, P::barWidth, 4);
    NSColor* colour =
        [(parse_color(obj_of(n, P::color)) ?: g_theme.fg) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    s.color = simd_make_float4((float)colour.redComponent, (float)colour.greenComponent, (float)colour.blueComponent,
                               (float)colour.alphaComponent);
    s.spin_base = n.spin_base, s.spin_t0 = n.spin_t0, s.spin_period = n.spin_period;
    id raw = obj(n, P::values);
    NSArray* values = [raw isKindOfClass:NSArray.class] ? raw : @[];
    s.nvalues = (uint32_t)MIN(512, values.count);
    for (uint32_t i = 0; i < s.nvalues; i++)
        s.values[i] = (float)num_of(values[i]);
    s.gen = ++l->gen;
    l->state.publish();
    if (size.width < 1 || size.height < 1)
        return;
    if (vis_moves(n) && node_on_screen(n)) {
        if (l->tick.v && l.reading == n.frames)
            return;
        visualiser_stop(n);
        RXVisLive* c = [RXVisLive new];
        c->layer = l, c->frames = n.frames;
        l.reading = n.frames;
        void* ctx = (__bridge_retained void*)c;
        l->tick = ui_gpu_clock() ? rx::gpu::link_add(120, vis_tick, vis_gone, ctx) : rx::gpu::LinkId{};
        if (!l->tick.v)
            (void)(__bridge_transfer RXVisLive*)ctx;
        return;
    }
    visualiser_stop(n);
    RXVisLive* c = [RXVisLive new];
    c->layer = l;
    void* ctx = (__bridge_retained void*)c;
    rx::gpu::Job job;
    job.encode = vis_once;
    memcpy(job.data, &ctx, sizeof ctx);
    if (!rx::gpu::render_start() || !rx::gpu::render_push(job))
        (void)(__bridge_transfer RXVisLive*)ctx;
}

void apply_canvas(RXNode* n, NSString* name) {
    if ([name isEqualToString:@"spin"])
        spin_set(n);
    if ([name isEqualToString:@"frames"]) {
        NSString* name2 = str(n, P::frames, @"");
        n.frames = name2.length ? frames_named(name2) : nil;
        n.frame = nil;
        if (name2.length && !n.frames)
            rexui_log([NSString stringWithFormat:@"%@: no frames at %@", n.doc.path.lastPathComponent, name2]);
    }
    if ([name isEqualToString:@"value"] && n.ticker == 0 && n.shown_value == 0 && CGRectIsEmpty(n.layer.frame)) {
        n.shown_value = MAX(0, MIN(1, num(n, P::value, 0)));
    }
    if (is_elem(n, E::Visualiser))
        draw_visualiser(n);
    else
        draw_arc(n);
    node_link(n, true);
}
