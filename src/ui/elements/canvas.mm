// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "gpu/canvas.h"
#include "core/sync/rmw.h"
#include "core/sync/triple.h"
#include "gpu/gpu.h"
#include "rexui_frames.h"
#include "ui/ui.h"

#include <algorithm>
#include <atomic>
#include <cmath>

namespace {
constexpr uint32_t k_most = 256;
struct CanvasState {
    float w = 0, h = 0, scale = 1;
    uint32_t dw = 0, dh = 0;
    uint32_t gen = 0, n = 0;
    rx::gpu::Shape shapes[k_most];
};
}

@interface RXCanvasElLayer : CAMetalLayer {
   @public
    rx::sync::Triple<CanvasState> state;
    std::atomic<int> inflight;
    rx::gpu::LinkId tick;
    uint32_t gen;
    uint32_t r_gen;
    rexui_frames_reader* reader;
    float r_frame[k_most * 16];
}
@end
@implementation RXCanvasElLayer
- (id<CAAction>)actionForKey:(NSString*)key {
    return nil;
}
- (void)dealloc {
    if (reader)
        rexui_frames_unmap(reader), delete reader;
}
@end

@interface RXCanvasLive : NSObject {
   @public
    RXCanvasElLayer* layer;
}
@end
@implementation RXCanvasLive
@end

CALayer* make_canvas(RXNode* n) {
    RXCanvasElLayer* l = [RXCanvasElLayer layer];
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

static simd_float4 rgba_of(id c) {
    NSColor* col = [(parse_color(c) ?: g_theme.fg) colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    return simd_make_float4((float)col.redComponent, (float)col.greenComponent, (float)col.blueComponent,
                            (float)col.alphaComponent);
}

static bool shape_of(NSDictionary* d, rx::gpu::Shape* out) {
    NSString* kind = string_of(d[@"shape"]);
    auto f = [d](NSString* k, double otherwise = 0) { return (float)num_of(d[k], otherwise); };
    const simd_float4 c = rgba_of(d[@"color"]);
    if ([kind isEqualToString:@"rect"])
        *out = rx::gpu::rect(f(@"x"), f(@"y"), f(@"width"), f(@"height"), f(@"radius"), c);
    else if ([kind isEqualToString:@"line"])
        *out = rx::gpu::capsule(f(@"x0"), f(@"y0"), f(@"x1"), f(@"y1"), f(@"width", 1) / 2, c);
    else if ([kind isEqualToString:@"arc"]) {
        const float sweep = f(@"sweep", 360) * float(M_PI) / 180;
        const float waves = f(@"waves");
        *out = rx::gpu::arc(f(@"x"), f(@"y"), f(@"radius"), f(@"thickness", 2), f(@"start") * float(M_PI) / 180, sweep,
                            c, f(@"amplitude"), sweep > 0 ? waves * 2 * float(M_PI) / sweep : 0,
                            f(@"phase") * 2 * float(M_PI));
    } else if ([kind isEqualToString:@"circle"])
        *out = rx::gpu::cookie(f(@"x"), f(@"y"), f(@"radius"), f(@"turn") * float(M_PI) / 180, f(@"scallops"), c);
    else
        return false;
    return true;
}

static std::atomic<uint64_t> g_canvas_frames;
uint64_t canvas_el_frames(void) {
    return g_canvas_frames.load(std::memory_order_relaxed);
}

static bool canvas_draw(RXCanvasLive* c, id<MTLCommandBuffer> cb, bool always) {
    RXCanvasElLayer* l = c->layer;
    (void)l->state.take();
    const CanvasState& s = l->state.front();
    const rx::gpu::Shape* shapes = s.shapes;
    uint32_t n = s.n;
    bool fresh = always || s.gen != l->r_gen;
    if (l->reader) {
        const long got = rexui_frames_copy(l->reader, l->r_frame, k_most * 16);
        if (got >= 0) {
            fresh = true;
            n = (uint32_t)std::min<long>(got / 16, k_most);
            shapes = reinterpret_cast<const rx::gpu::Shape*>(l->r_frame);
        } else {
            n = 0;
        }
    }
    if (!fresh || s.w < 1 || s.h < 1 || l->inflight.load(std::memory_order_relaxed) >= 2)
        return false;
    id<CAMetalDrawable> d = [l nextDrawable];
    if (!d || d.texture.width != s.dw || d.texture.height != s.dh)
        return false;
    if (!rx::gpu::canvas_encode(cb, d.texture, shapes, n, s.scale, true))
        return false;
    [cb presentDrawable:d];
    l->r_gen = s.gen;
    g_canvas_frames.store(g_canvas_frames.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    l->inflight.store(l->inflight.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    RXCanvasElLayer* held = l;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        (void)d;
        rx::sync::fetch_sub(held->inflight, 1, std::memory_order_relaxed);
    }];
    return true;
}
static bool canvas_tick(void* ctx, double, id<MTLCommandBuffer> cb) {
    return canvas_draw((__bridge RXCanvasLive*)ctx, cb, false);
}
static void canvas_gone(void* ctx) {
    (void)(__bridge_transfer RXCanvasLive*)ctx;
}
static void canvas_once(rx::gpu::Job& job, id<MTLCommandBuffer> cb) {
    void* ctx;
    memcpy(&ctx, job.data, sizeof ctx);
    canvas_draw((__bridge_transfer RXCanvasLive*)ctx, cb, true);
}

void canvas_el_stop(RXNode* n) {
    RXCanvasElLayer* l = [n.layer isKindOfClass:RXCanvasElLayer.class] ? (RXCanvasElLayer*)n.layer : nil;
    if (!l || !l->tick.v || !rx::gpu::link_remove(l->tick))
        return;
    l->tick = {};
}
double canvas_el_clock_fps(RXNode* n) {
    RXCanvasElLayer* l = [n.layer isKindOfClass:RXCanvasElLayer.class] ? (RXCanvasElLayer*)n.layer : nil;
    return l && l->tick.v ? 4 : 120;
}
bool canvas_el_moving(RXNode* n) {
    return str(n, P::frames, @"").length > 0;
}

void canvas_el_apply(RXNode* n, NSString* name) {
    RXCanvasElLayer* l = [n.layer isKindOfClass:RXCanvasElLayer.class] ? (RXCanvasElLayer*)n.layer : nil;
    if (!l)
        return;
    if ([name isEqualToString:@"frames"]) {
        canvas_el_stop(n);
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
    CanvasState& s = l->state.back();
    s.w = (float)size.width, s.h = (float)size.height, s.scale = (float)scale;
    s.dw = (uint32_t)want.width, s.dh = (uint32_t)want.height;
    s.n = 0;
    for (id item in array_of(obj(n, P::draw)) ?: @[])
        if (NSDictionary* d = dict_of(item); d && s.n < k_most && shape_of(d, &s.shapes[s.n]))
            s.n++;
    s.gen = ++l->gen;
    l->state.publish();
    if (size.width < 1 || size.height < 1)
        return;
    if (l->reader && node_on_screen(n)) {
        if (!l->tick.v) {
            RXCanvasLive* c = [RXCanvasLive new];
            c->layer = l;
            void* ctx = (__bridge_retained void*)c;
            l->tick = ui_gpu_clock() ? rx::gpu::link_add(120, canvas_tick, canvas_gone, ctx) : rx::gpu::LinkId{};
            if (!l->tick.v)
                (void)(__bridge_transfer RXCanvasLive*)ctx;
        }
        node_link(n, true);
        node_link_rate(n);
        return;
    }
    RXCanvasLive* c = [RXCanvasLive new];
    c->layer = l;
    void* ctx = (__bridge_retained void*)c;
    rx::gpu::Job job;
    job.encode = canvas_once;
    memcpy(job.data, &ctx, sizeof ctx);
    if (!rx::gpu::render_start() || !rx::gpu::render_push(job))
        (void)(__bridge_transfer RXCanvasLive*)ctx;
}
