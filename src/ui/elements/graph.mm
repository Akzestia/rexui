// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/sync/rmw.h"
#include "core/sync/triple.h"
#include "gpu/canvas.h"
#include "gpu/figures.h"
#include "gpu/gpu.h"
#include "rexui_frames.h"
#include "ui/ui.h"

#include <algorithm>
#include <atomic>

using rx::gpu::GraphState;

@interface RXGraphLayer : CAMetalLayer {
   @public
    rx::sync::Triple<GraphState> state;
    std::atomic<int> inflight;
    rx::gpu::LinkId tick;
    uint32_t gen;
    rexui_frames_reader* reader;
    uint32_t r_gen;
    float r_frame[512];
}
@end
@implementation RXGraphLayer
- (id<CAAction>)actionForKey:(NSString*)key {
    return nil;
}
- (void)dealloc {
    if (reader)
        rexui_frames_unmap(reader), delete reader;
}
@end

@interface RXGraphLive : NSObject {
   @public
    RXGraphLayer* layer;
}
@end
@implementation RXGraphLive
@end

CALayer* make_graph(RXNode* n) {
    RXGraphLayer* l = [RXGraphLayer layer];
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

static std::atomic<uint64_t> g_graph_frames;
uint64_t graph_frames(void) {
    return g_graph_frames.load(std::memory_order_relaxed);
}

static bool graph_draw(RXGraphLive* c, id<MTLCommandBuffer> cb, bool always) {
    RXGraphLayer* l = c->layer;
    (void)l->state.take();
    const GraphState& s = l->state.front();
    const float* values = s.values;
    uint32_t n = s.n;
    bool fresh = always || s.gen != l->r_gen;
    if (l->reader) {
        const long got = rexui_frames_copy(l->reader, l->r_frame, 512);
        if (got >= 0)
            fresh = true, n = (uint32_t)got, values = l->r_frame;
        else
            n = 0;
    }
    if (!fresh || s.w < 1 || s.h < 1 || l->inflight.load(std::memory_order_relaxed) >= 2)
        return false;
    id<CAMetalDrawable> d = [l nextDrawable];
    if (!d || d.texture.width != s.dw || d.texture.height != s.dh)
        return false;
    static rx::gpu::Shape shapes[1024];
    const uint32_t k = rx::gpu::graph_figure(s, values, n, shapes, 1024);
    if (!rx::gpu::canvas_encode(cb, d.texture, shapes, k, s.scale, true))
        return false;
    [cb presentDrawable:d];
    l->r_gen = s.gen;
    g_graph_frames.store(g_graph_frames.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    l->inflight.store(l->inflight.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    RXGraphLayer* held = l;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        (void)d;
        rx::sync::fetch_sub(held->inflight, 1, std::memory_order_relaxed);
    }];
    return true;
}
static bool graph_tick(void* ctx, double, id<MTLCommandBuffer> cb) {
    return graph_draw((__bridge RXGraphLive*)ctx, cb, false);
}
static void graph_gone(void* ctx) {
    (void)(__bridge_transfer RXGraphLive*)ctx;
}
static void graph_once(rx::gpu::Job& job, id<MTLCommandBuffer> cb) {
    void* ctx;
    memcpy(&ctx, job.data, sizeof ctx);
    graph_draw((__bridge_transfer RXGraphLive*)ctx, cb, true);
}

void graph_stop(RXNode* n) {
    RXGraphLayer* l = [n.layer isKindOfClass:RXGraphLayer.class] ? (RXGraphLayer*)n.layer : nil;
    if (!l || !l->tick.v || !rx::gpu::link_remove(l->tick))
        return;
    l->tick = {};
}
double graph_clock_fps(RXNode* n) {
    RXGraphLayer* l = [n.layer isKindOfClass:RXGraphLayer.class] ? (RXGraphLayer*)n.layer : nil;
    return l && l->tick.v ? 4 : 120;
}
bool graph_moving(RXNode* n) {
    return str(n, P::frames, @"").length > 0;
}

void graph_apply(RXNode* n, NSString* name) {
    RXGraphLayer* l = [n.layer isKindOfClass:RXGraphLayer.class] ? (RXGraphLayer*)n.layer : nil;
    if (!l)
        return;
    if ([name isEqualToString:@"frames"]) {
        graph_stop(n);
        NSString* region = str(n, P::frames, @"");
        if (l->reader && !l->tick.v)
            rexui_frames_unmap(l->reader), delete l->reader, l->reader = nullptr;
        if (region.length && !l->reader) {
            auto* r = new rexui_frames_reader();
            if ([region hasPrefix:@"/"] && region.length <= 31 && rexui_frames_open(r, region.UTF8String) == 0)
                l->reader = r;
            else
                delete r,
                    rexui_log([NSString stringWithFormat:@"%@: no frames at %@", n.doc.path.lastPathComponent, region]);
        }
    }
    const CGSize size = l.bounds.size;
    const CGFloat scale = backing_scale();
    const CGSize want = CGSizeMake(MAX(1, round(size.width * scale)), MAX(1, round(size.height * scale)));
    if (!CGSizeEqualToSize(l.drawableSize, want))
        l.drawableSize = want;
    if (l.contentsScale != scale)
        l.contentsScale = scale;
    GraphState& s = l->state.back();
    s.w = (float)size.width, s.h = (float)size.height, s.scale = (float)scale;
    s.dw = (uint32_t)want.width, s.dh = (uint32_t)want.height;
    NSString* style = str(n, P::style, @"line");
    s.style = [style isEqualToString:@"bars"] ? GraphState::bars
        : [style isEqualToString:@"area"]     ? GraphState::area
                                              : GraphState::line;
    s.fixed = has_num(n, P::min) && has_num(n, P::max);
    s.lo = (float)num(n, P::min, 0), s.hi = (float)num(n, P::max, 0);
    s.thickness = (float)num(n, P::thickness, 1.5), s.gap = (float)num(n, P::gap, 1);
    NSColor* colour =
        [(parse_color(obj_of(n, P::color)) ?: g_theme.fg) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    s.color = simd_make_float4((float)colour.redComponent, (float)colour.greenComponent, (float)colour.blueComponent,
                               (float)colour.alphaComponent);
    NSArray* values = array_of(obj(n, P::values)) ?: @[];
    const NSUInteger from = values.count > 512 ? values.count - 512 : 0;
    s.n = (uint32_t)(values.count - from);
    for (uint32_t i = 0; i < s.n; i++)
        s.values[i] = (float)num_of(values[from + i], NAN);
    s.gen = ++l->gen;
    l->state.publish();
    if (size.width < 1 || size.height < 1)
        return;
    if (l->reader && node_on_screen(n)) {
        if (!l->tick.v) {
            RXGraphLive* c = [RXGraphLive new];
            c->layer = l;
            void* ctx = (__bridge_retained void*)c;
            l->tick = ui_gpu_clock() ? rx::gpu::link_add(120, graph_tick, graph_gone, ctx) : rx::gpu::LinkId{};
            if (!l->tick.v)
                (void)(__bridge_transfer RXGraphLive*)ctx;
        }
        node_link(n, true);
        node_link_rate(n);
        return;
    }
    RXGraphLive* c = [RXGraphLive new];
    c->layer = l;
    void* ctx = (__bridge_retained void*)c;
    rx::gpu::Job job;
    job.encode = graph_once;
    memcpy(job.data, &ctx, sizeof ctx);
    if (!rx::gpu::render_start() || !rx::gpu::render_push(job))
        (void)(__bridge_transfer RXGraphLive*)ctx;
}
