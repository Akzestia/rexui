// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "ui/elements/shader_prelude.h"
#include "ui/ui.h"

#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#include <objc/message.h>
#include <simd/simd.h>

#include <mach/mach.h>
#include <pthread.h>
#include <atomic>
#include <vector>

#include "core/sync/rmw.h"
#include "core/sync/seq.h"
#include "core/sync/triple.h"
#include "gpu/gpu.h"
#include "rexui_frames.h"

struct ShaderUniforms {
    simd_float2 size, mouse;
    float time, hover, scale, seed;
    float params[16];
    simd_float4 colors[8];
};
static_assert(sizeof(ShaderUniforms) == 224, "the prelude's struct Shader, up to its frames");
struct ShaderFull {
    ShaderUniforms u;
    float nframes;
    float frames[128];
    MTLResourceID image;
    simd_float2 imageSize;
    MTLResourceID last;
    MTLResourceID passes[4];
};
static_assert(sizeof(ShaderFull) == 800 && offsetof(ShaderFull, frames) == 228 && offsetof(ShaderFull, image) == 744
                  && offsetof(ShaderFull, imageSize) == 752 && offsetof(ShaderFull, last) == 760
                  && offsetof(ShaderFull, passes) == 768,
              "the prelude's struct Shader, byte for byte");

@interface RXPassSet : NSObject {
   @public
    NSArray<id<MTLRenderPipelineState>>* states;
    NSArray<id<MTLTexture>>* tex;
}
@end
@implementation RXPassSet
@end

struct Inputs {
    __unsafe_unretained id<MTLResource> t[6];
    int n = 0;
    void add(id<MTLResource> r) {
        if (r && n < 6)
            t[n++] = r;
    }
    void use(id<MTLRenderCommandEncoder> e) const {
        if (n)
            [e useResources:t count:(NSUInteger)n usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
    }
};

static uint64_t g_passes_main;
static std::atomic<uint64_t> g_r_passes;
static void encode_passes(id<MTLCommandBuffer> cb, RXPassSet* ps, ShaderFull& full, Inputs& in, bool main) {
    if (!ps || ps->states.count != ps->tex.count)
        return;
    const NSUInteger n = MIN(ps->tex.count, 4u);
    for (NSUInteger i = 0; i < n; i++) {
        id<MTLTexture> t = ps->tex[i];
        MTLRenderPassDescriptor* d = [MTLRenderPassDescriptor renderPassDescriptor];
        d.colorAttachments[0].texture = t;
        d.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        d.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:d];
        [e setRenderPipelineState:ps->states[i]];
        ShaderFull f = full;
        f.u.scale = (float)t.width / MAX(1.f, full.u.size.x);
        Inputs mine = in;
        for (NSUInteger j = 0; j < n; j++)
            if (j != i)
                f.passes[j] = ps->tex[j].gpuResourceID, mine.add(ps->tex[j]);
        mine.use(e);
        [e setFragmentBytes:&f length:sizeof f atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
    }
    for (NSUInteger j = 0; j < n; j++)
        full.passes[j] = ps->tex[j].gpuResourceID, in.add(ps->tex[j]);
    if (main)
        g_passes_main += n;
    else
        g_r_passes.store(g_r_passes.load(std::memory_order_relaxed) + n, std::memory_order_relaxed);
}

static bool last_fits(id<MTLTexture> last, id<MTLTexture> drawn) {
    return last && !drawn.framebufferOnly && last.width == drawn.width && last.height == drawn.height;
}
static void put_last(ShaderFull& f, id<MTLTexture> last, id<MTLTexture> drawn, Inputs& in) {
    if (!last_fits(last, drawn))
        return;
    f.last = last.gpuResourceID;
    in.add(last);
}
static uint64_t g_last_copies;
static std::atomic<uint64_t> g_r_last_copies;
static void copy_last(id<MTLCommandBuffer> cb, id<MTLTexture> last, id<MTLTexture> drawn, bool main) {
    if (!last_fits(last, drawn))
        return;
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:drawn toTexture:last];
    [b endEncoding];
    if (main)
        g_last_copies++;
    else
        g_r_last_copies.store(g_r_last_copies.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
}

enum { k_by_main, k_by_job, k_by_link };
static std::atomic<uint64_t> g_image_frames[3];
static void put_image(ShaderFull& f, id<MTLTexture> t, Inputs& in, int by) {
    if (!t)
        return;
    g_image_frames[by].store(g_image_frames[by].load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    f.image = t.gpuResourceID;
    f.imageSize = simd_make_float2((float)t.width, (float)t.height);
    in.add(t);
}

struct LiveState {
    ShaderUniforms u;
    float over;
    bool running, pane;
    bool exact;
    float fps;
    uint32_t gen, w, h;
    uint32_t room;
};

@interface RXShaderLayer : CAMetalLayer
@property(nonatomic) RXNode* node;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, copy) NSString* key;
@property(nonatomic, copy) NSString* file;
@property(nonatomic, strong) NSDate* file_mtime;
@property(nonatomic) double time, hover, last_draw, resized_at;
@property(nonatomic) double unseen_at;
@property(nonatomic) simd_float2 mouse;
@property(nonatomic) float seed;
@property(nonatomic, copy) NSString* placed;
@property(nonatomic) BOOL stale;
@property(nonatomic) BOOL trimmed;
@property(nonatomic) BOOL queued;
@property(nonatomic) BOOL frames_wanted;
@property(nonatomic, strong) id<MTLTexture> image;
@property(nonatomic, copy) NSString* image_file;
@property(nonatomic, strong) NSDate* image_mtime;
@property(nonatomic) uint32_t image_ask;
@property(nonatomic, strong) id<MTLTexture> last;
@property(nonatomic, copy) NSArray<NSString*>* pass_names;
@property(nonatomic, copy) NSArray<NSNumber*>* pass_scales;
@property(nonatomic, copy) NSArray<id<MTLRenderPipelineState>>* pass_states;
@property(nonatomic, copy) NSArray<id<MTLTexture>>* pass_tex;
@property(nonatomic, strong) RXPassSet* passset;
@end
static void fit_last(RXShaderLayer* l);
static void fit_passes(RXShaderLayer* l);

static NSString* pane_key(RXNode* n);

@interface RXShaderLayer () {
    __weak RXNode* _w_node;
}
@end
@implementation RXShaderLayer {
   @public
    float params[16];
    float from[16];
    double glide_t0, glide_s;
    simd_float4 colors[8];
    std::atomic<int> inflight;
    std::atomic<bool> owed;
    uint32_t gen;
    std::atomic<uint32_t> shown_gen;
    std::atomic<uint64_t> gpu_ns, gpu_passes;
    rx::sync::Triple<LiveState> live;
    rx::gpu::LinkId link;
    double link_t0, link_time0;
    float over;
    double r_time, r_hover, r_last, r_due;
    double due;
    bool unlinking;
    rexui_frames_reader* reader;
    uint32_t r_nframes;
    float r_frames[128];
}
- (RXNode*)node {
    return _w_node;
}
- (void)setNode:(RXNode*)v {
    _w_node = v;
}
- (void)dealloc {
    if (reader)
        rexui_frames_unmap(reader), delete reader;
}
- (id<CAAction>)actionForKey:(NSString*)key {
    return nil;
}
- (void)setBounds:(CGRect)b {
    bool resized = !CGSizeEqualToSize(b.size, self.bounds.size);
    [super setBounds:b];
    if (resized && self.modelLayer == self)
        [self fitDrawable];
}
- (void)fitDrawable {
    if (self.modelLayer != self)
        return;
    RXNode* n = self.node;
    CGFloat scale = backing_scale() * MAX(0.1, MIN(2, n ? num(n, P::scale, 1) : 1));
    CGSize b = self.bounds.size, d = CGSizeMake(MAX(1, round(b.width * scale)), MAX(1, round(b.height * scale)));
    if (!CGSizeEqualToSize(d, self.drawableSize))
        self.drawableSize = d;
    if (self.contentsScale != scale)
        self.contentsScale = scale;
}
- (void)setDrawableSize:(CGSize)s {
    [super setDrawableSize:s];
    if (self.modelLayer == self)
        fit_last(self), fit_passes(self);
}
@end

static NSString* pane_key(RXNode* n) {
    if (!n || !is_elem(n.doc.root, E::Panes))
        return nil;
    for (RXNode* c = n; c; c = c.parent) {
        if (c.parent == n.doc.root) {
            id k = obj(c, @"paneId");
            return [k isKindOfClass:NSString.class] && [k length] ? k : nil;
        }
    }
    return nil;
}

static double g_epoch;
static double pane_time(void) {
    if (!g_epoch)
        g_epoch = CACurrentMediaTime();
    return CACurrentMediaTime() - g_epoch;
}

static NSHashTable<RXShaderLayer*>* g_shaders;
static NSMutableDictionary<NSString*, id<MTLRenderPipelineState>>* g_pipelines;
static NSMutableDictionary<NSString*, NSString*>* g_failed;
static NSMutableDictionary<NSString*, NSArray<id<MTLRenderPipelineState>>*>* g_pass_states;
static NSMutableSet<NSString*>* g_compiling;

static void draw(RXShaderLayer* l, bool synced = false);
static void draw_soon(RXShaderLayer* l);

static id<MTLCounterSampleBuffer> g_samples;
static NSUInteger g_sample_at;
static constexpr NSUInteger k_samples = 2048;
static double g_gpu_until;

void shader_gpu_timing(double seconds) {
    g_gpu_until = MAX(g_gpu_until, CACurrentMediaTime() + seconds);
}

static bool gpu_timing(void) {
    static bool env = getenv("REXUI_GPU_TIMING") != nullptr;
    if (!env && CACurrentMediaTime() > g_gpu_until)
        return false;
    if (!g_samples) {
        static bool tried;
        if (tried)
            return false;
        tried = true;
        if (![rx::gpu::device() supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary])
            return false;
        for (id<MTLCounterSet> s in rx::gpu::device().counterSets) {
            if (![s.name isEqualToString:MTLCommonCounterSetTimestamp])
                continue;
            MTLCounterSampleBufferDescriptor* d = [MTLCounterSampleBufferDescriptor new];
            d.counterSet = s;
            d.storageMode = MTLStorageModeShared;
            d.sampleCount = k_samples;
            g_samples = [rx::gpu::device() newCounterSampleBufferWithDescriptor:d error:nil];
        }
        if (!g_samples)
            rexui_log(@"shader: no GPU timestamps on this device");
    }
    return g_samples != nil;
}

void shader_gpu_totals(RXDoc* doc, double* ns, double* passes) {
    *ns = 0, *passes = 0;
    for (RXShaderLayer* l in g_shaders.allObjects) {
        if (doc && l.node.doc != doc)
            continue;
        *ns += l->gpu_ns.load(std::memory_order_relaxed);
        *passes += l->gpu_passes.load(std::memory_order_relaxed);
    }
}

static void sweep_start(void);
CALayer* make_shader(RXNode* n) {
    if (!g_shaders) {
        g_shaders = [NSHashTable weakObjectsHashTable];
        g_pipelines = [NSMutableDictionary dictionary];
        g_failed = [NSMutableDictionary dictionary];
        g_pass_states = [NSMutableDictionary dictionary];
        g_compiling = [NSMutableSet set];
    }
    RXShaderLayer* l = [RXShaderLayer layer];
    l.node = n;
    l.device = rx::gpu::device();
    l.pixelFormat = MTLPixelFormatBGRA8Unorm;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    l.colorspace = srgb;
    CGColorSpaceRelease(srgb);
    l.framebufferOnly = YES;
    l.opaque = NO;
    l.maximumDrawableCount = 3;
    l.contentsGravity = kCAGravityResize;
    l.seed = arc4random() / 4294967296.0f;
    [g_shaders addObject:l];
    sweep_start();
    return l;
}

static uint64_t fnv(NSString* s) {
    uint64_t h = 1469598103934665603ull;
    for (const char* c = s.UTF8String; *c; c++)
        h = (h ^ (uint8_t)*c) * 1099511628211ull;
    return h;
}

static NSString* tidy_error(NSError* e) {
    NSString* s = e.localizedDescription ?: @"compile failed";
    NSMutableArray* out = [NSMutableArray array];
    for (NSString* line in [s componentsSeparatedByString:@"\n"]) {
        if (!line.length || [line hasPrefix:@"Compilation failed"])
            continue;
        [out addObject:line];
        if (out.count == 6)
            break;
    }
    return [out componentsJoinedByString:@"\n"];
}

static void set_error(RXShaderLayer* l, NSString* error) {
    RXNode* n = l.node;
    if (!n.doc.ctx || [str(n, P::error, @"") isEqualToString:error])
        return;
    prop_put(n, @"error", error);
    doc_call(n.doc, @"update", @[@(n.uid), @{@"error": error}]);
}

static void set_passes(RXShaderLayer* l);
static void compiled(NSString* key) {
    for (RXShaderLayer* l in g_shaders.allObjects) {
        if (![l.key isEqualToString:key])
            continue;
        if (NSString* e = g_failed[key]) {
            set_error(l, e);
            continue;
        }
        if (l.node)
            shader_unlink(l.node);
        l.pipeline = g_pipelines[key];
        l.pass_states = g_pass_states[key];
        set_passes(l);
        set_error(l, @"");
        draw_soon(l);
        node_link(l.node, true);
    }
}

static void prune_pipelines(void) {
    NSMutableSet<NSString*>* used = [g_compiling mutableCopy];
    for (RXShaderLayer* l in g_shaders.allObjects)
        if (l.key)
            [used addObject:l.key];
    for (NSString* k in g_pipelines.allKeys)
        if (![used containsObject:k])
            [g_pipelines removeObjectForKey:k], [g_pass_states removeObjectForKey:k];
    for (NSString* k in g_failed.allKeys)
        if (![used containsObject:k])
            [g_failed removeObjectForKey:k];
}

static void compile(RXShaderLayer* l, NSString* source, NSString* name) {
    NSMutableString* full =
        [NSMutableString stringWithFormat:@"%s#line 1 \"%@\"\n%@\n%s", kShaderPrelude, name, source, kShaderEpilogue];
    NSArray<NSString*>* pass_names = l.pass_names ?: @[];
    for (NSUInteger i = 0; i < pass_names.count; i++)
        [full appendString:@(shader_pass_entry((int)i, pass_names[i].UTF8String).c_str())];
    NSString* key = [NSString stringWithFormat:@"%016llx", fnv(full)];
    if ([l.key isEqualToString:key])
        return;
    l.key = key;
    if (g_pipelines[key] || g_failed[key])
        return compiled(key);
    if ([g_compiling containsObject:key])
        return;
    [g_compiling addObject:key];
    MTLCompileOptions* o = [MTLCompileOptions new];
    o.mathMode = MTLMathModeFast;
    NSString* who = [NSString stringWithFormat:@"%@: %@", l.node.doc.path.lastPathComponent, name];
    [rx::gpu::device()
        newLibraryWithSource:full
                     options:o
           completionHandler:^(id<MTLLibrary> lib, NSError* error) {
               auto done =
                   ^(id<MTLRenderPipelineState> p, NSArray<id<MTLRenderPipelineState>>* passes, NSString* failed) {
                       dispatch_async(dispatch_get_main_queue(), ^{
                           [g_compiling removeObject:key];
                           if (p)
                               g_pipelines[key] = p, g_pass_states[key] = passes ?: @[];
                           if (failed) {
                               g_failed[key] = failed;
                               rexui_log([NSString stringWithFormat:@"%@: %@", who, failed]);
                           }
                           compiled(key);
                           prune_pipelines();
                       });
                   };
               if (!lib)
                   return done(nil, nil, tidy_error(error));
               NSMutableArray<id<MTLRenderPipelineState>>* passes = [NSMutableArray array];
               for (NSUInteger i = 0; i < pass_names.count; i++) {
                   MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
                   pd.vertexFunction = [lib newFunctionWithName:@"rx_vertex"];
                   pd.fragmentFunction =
                       [lib newFunctionWithName:[NSString stringWithFormat:@"rx_pass_%lu", (unsigned long)i]];
                   pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
                   NSError* pe = nil;
                   id<MTLRenderPipelineState> ps = [rx::gpu::device() newRenderPipelineStateWithDescriptor:pd
                                                                                                     error:&pe];
                   if (!ps)
                       return done(nil, nil, tidy_error(pe));
                   [passes addObject:ps];
               }
               MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
               d.vertexFunction = [lib newFunctionWithName:@"rx_vertex"];
               d.fragmentFunction = [lib newFunctionWithName:@"rx_fragment"];
               d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
               [rx::gpu::device() newRenderPipelineStateWithDescriptor:d
                                                     completionHandler:^(id<MTLRenderPipelineState> p, NSError* e) {
                                                         done(p, passes, p ? nil : tidy_error(e));
                                                     }];
           }];
}

static void load_source(RXShaderLayer* l) {
    RXNode* n = l.node;
    NSString *code = str(n, P::code, @""), *source = str(n, P::source, @"");
    if (code.length) {
        l.file = nil;
        return compile(l, code, @"code");
    }
    if (!source.length) {
        if (l.node)
            shader_unlink(l.node);
        l.file = nil, l.key = nil, l.pipeline = nil;
        return;
    }
    NSString* path = source.stringByExpandingTildeInPath;
    if (!path.isAbsolutePath)
        path = [doc_dir(n) stringByAppendingPathComponent:path];
    l.file = path.stringByStandardizingPath;
    l.file_mtime = [NSFileManager.defaultManager attributesOfItemAtPath:l.file error:nil].fileModificationDate;
    NSString* text = [NSString stringWithContentsOfFile:l.file encoding:NSUTF8StringEncoding error:nil];
    if (!text) {
        NSString* e = [NSString stringWithFormat:@"%@: no such file", source];
        rexui_log([NSString stringWithFormat:@"%@: %@", n.doc.path.lastPathComponent, e]);
        return set_error(l, e);
    }
    compile(l, text, source.lastPathComponent);
}

static void read_params(RXShaderLayer* l) {
    id a = obj(l.node, P::params);
    NSArray* list = [a isKindOfClass:NSArray.class] ? a : @[];
    for (NSUInteger i = 0; i < 16; i++)
        l->params[i] = i < list.count && [list[i] isKindOfClass:NSNumber.class] ? [list[i] floatValue] : 0;
}

static void read_colors(RXShaderLayer* l) {
    id a = obj(l.node, P::colors);
    NSArray* list = [a isKindOfClass:NSArray.class] ? a : @[];
    for (NSUInteger i = 0; i < 8; i++) {
        NSColor* c = i < list.count ? [parse_color(list[i]) colorUsingColorSpace:NSColorSpace.sRGBColorSpace] : nil;
        l->colors[i] = c ? simd_make_float4(c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
                         : simd_make_float4(0, 0, 0, 0);
    }
}

static bool gliding(RXShaderLayer* l) {
    return l->glide_s > 0 && CACurrentMediaTime() - l->glide_t0 < l->glide_s;
}
static void shown_params(RXShaderLayer* l, float out[16]) {
    double t = l->glide_s > 0 ? (CACurrentMediaTime() - l->glide_t0) / l->glide_s : 1;
    if (t >= 1) {
        memcpy(out, l->params, sizeof l->params);
        return;
    }
    float e = 1 - pow(2, -10 * MAX(0, t));
    for (int i = 0; i < 16; i++)
        out[i] = l->from[i] + (l->params[i] - l->from[i]) * e;
}

static bool hidden_by_us(CALayer* l) {
    static Class host = NSClassFromString(@"RXHostLayer");
    for (CALayer* x = l; x; x = x.superlayer) {
        if ([x.delegate isKindOfClass:NSView.class] || [x isKindOfClass:host])
            return false;
        if (x.hidden)
            return true;
    }
    return false;
}

static void redraw_owed(RXShaderLayer* l) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (RXNode* n = l.node; n && !shader_moving(n))
            draw(l);
    });
}
static void owe(RXShaderLayer* l) {
    RXNode* n = l.node;
    if (!n || !l.pipeline || shader_moving(n) || l->inflight.load() == 0)
        return;
    l->owed.store(true);
    if (l->inflight.load() == 0 && rx::sync::exchange(l->owed, false, std::memory_order_seq_cst))
        redraw_owed(l);
}
static void frame_done(RXShaderLayer* l, uint32_t gen) {
    l->shown_gen.store(gen, std::memory_order_relaxed);
    rx::sync::fetch_sub(l->inflight, 1, std::memory_order_seq_cst);
    if (rx::sync::exchange(l->owed, false, std::memory_order_seq_cst))
        redraw_owed(l);
}

static void draw_soon(RXShaderLayer* l) {
    l->gen++;
    if (l.queued)
        return;
    l.queued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        l.queued = NO;
        if (l.node)
            draw(l);
    });
}

bool shader_settled(RXNode* n) {
    RXShaderLayer* l = (RXShaderLayer*)n.layer;
    return !l.queued && l->inflight.load() == 0 && !l->owed.load() && l->shown_gen.load() == l->gen;
}

static int room(RXShaderLayer* l) {
    return MAX(1, (int)l.maximumDrawableCount - 1);
}

static uint64_t g_main_drawable_wait;
static std::atomic<uint64_t> g_render_drawable_wait;
static id<CAMetalDrawable> next_drawable(RXShaderLayer* l) {
    const uint64_t t0 = mach_absolute_time();
    id<CAMetalDrawable> d = [l nextDrawable];
    const uint64_t t = mach_absolute_time() - t0;
    if (pthread_main_np())
        g_main_drawable_wait = MAX(g_main_drawable_wait, t);
    else if (t > g_render_drawable_wait.load(std::memory_order_relaxed))
        g_render_drawable_wait.store(t, std::memory_order_relaxed);
    return d;
}
double shader_drawable_wait_ms(void) {
    const uint64_t t = MAX(g_main_drawable_wait, g_render_drawable_wait.load(std::memory_order_relaxed));
    return double(t) * rx::trace::ns_per_tick() / 1e6;
}

static id<CAMetalDrawable> encode(RXShaderLayer* l, id<MTLCommandBuffer> __strong* cb, int most_inflight) {
    CGSize b = l.bounds.size, d = l.drawableSize;
    most_inflight = MIN(most_inflight, room(l));
    if (!l.pipeline || b.width < 1 || b.height < 1 || l->inflight.load() >= most_inflight)
        return nil;
    id<CAMetalDrawable> drawable = next_drawable(l);
    if (!drawable)
        return nil;
    ShaderUniforms u = {};
    u.size = simd_make_float2(b.width, b.height);
    u.mouse = l.mouse;
    u.time = l.time;
    u.hover = l.hover;
    u.scale = d.width / b.width;
    u.seed = l.seed;
    shown_params(l, u.params);
    memcpy(u.colors, l->colors, sizeof u.colors);
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    NSUInteger sample = NSNotFound;
    if (gpu_timing()) {
        sample = g_sample_at;
        g_sample_at = (g_sample_at + 2) % (k_samples / 2);
        MTLRenderPassSampleBufferAttachmentDescriptor* a = pass.sampleBufferAttachments[0];
        a.sampleBuffer = g_samples;
        a.startOfVertexSampleIndex = sample;
        a.endOfVertexSampleIndex = MTLCounterDontSample;
        a.startOfFragmentSampleIndex = MTLCounterDontSample;
        a.endOfFragmentSampleIndex = sample + 1;
    }
    if (!*cb)
        *cb = [rx::gpu::queue() commandBuffer];
    ShaderFull full{};
    full.u = u;
    id<MTLTexture> image = l.image, last = l.last;
    RXPassSet* ps = l.passset;
    Inputs in;
    put_image(full, image, in, k_by_main);
    put_last(full, last, drawable.texture, in);
    encode_passes(*cb, ps, full, in, true);
    id<MTLRenderCommandEncoder> e = [*cb renderCommandEncoderWithDescriptor:pass];
    [e setRenderPipelineState:l.pipeline];
    in.use(e);
    [e setFragmentBytes:&full length:sizeof full atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    copy_last(*cb, last, drawable.texture, true);
    rx::sync::fetch_add(l->inflight, 1, std::memory_order_seq_cst);
    RXShaderLayer* held = l;
    const uint32_t gen = l->gen;
    id<MTLCounterSampleBuffer> samples = g_samples;
    [*cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        (void)image, (void)last, (void)ps;
        frame_done(held, gen);
        if (sample == NSNotFound)
            return;
        NSData* r = [samples resolveCounterRange:NSMakeRange(sample, 2)];
        if (r.length < 2 * sizeof(MTLCounterResultTimestamp))
            return;
        const MTLCounterResultTimestamp* t = (const MTLCounterResultTimestamp*)r.bytes;
        if (t[0].timestamp == MTLCounterErrorValue || t[1].timestamp == MTLCounterErrorValue
            || t[1].timestamp < t[0].timestamp)
            return;
        uint64_t ns = t[1].timestamp - t[0].timestamp;
        rx::sync::fetch_add(held->gpu_ns, static_cast<decltype(held->gpu_ns.load())>(ns), std::memory_order_relaxed);
        rx::sync::fetch_add(held->gpu_passes, static_cast<decltype(held->gpu_passes.load())>(1),
                            std::memory_order_relaxed);
        rx::trace::record_ns(rx::trace::Cat::gpu, ns);
    }];
    l.last_draw = CACurrentMediaTime();
    l.stale = NO;
    return drawable;
}

struct RenderJob {
    void* layer;
    void* pipeline;
    void* image;
    void* last;
    void* passes;
    uint32_t gen;
    ShaderUniforms u;
    uint32_t w, h;
    uint32_t sample;
    int room;
};
static_assert(sizeof(RenderJob) <= rx::gpu::k_job_bytes, "a Shader's frame in a render job's data");

static void encode_job(rx::gpu::Job& job, id<MTLCommandBuffer> cb) {
    RenderJob j;
    memcpy(&j, job.data, sizeof j);
    RXShaderLayer* l = (__bridge_transfer RXShaderLayer*)j.layer;
    id<MTLRenderPipelineState> pipeline = (__bridge_transfer id<MTLRenderPipelineState>)j.pipeline;
    id<MTLTexture> image = (__bridge_transfer id<MTLTexture>)j.image;
    id<MTLTexture> last = (__bridge_transfer id<MTLTexture>)j.last;
    RXPassSet* ps = (__bridge_transfer RXPassSet*)j.passes;
    id<CAMetalDrawable> drawable = l->inflight.load() <= j.room ? next_drawable(l) : nil;
    if (!drawable || drawable.texture.width != j.w || drawable.texture.height != j.h) {
        l->owed.store(true);
        frame_done(l, l->shown_gen.load(std::memory_order_relaxed));
        return;
    }
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    uint32_t sample = j.sample;
    if (sample != UINT32_MAX) {
        MTLRenderPassSampleBufferAttachmentDescriptor* a = pass.sampleBufferAttachments[0];
        a.sampleBuffer = g_samples;
        a.startOfVertexSampleIndex = sample;
        a.endOfVertexSampleIndex = MTLCounterDontSample;
        a.startOfFragmentSampleIndex = MTLCounterDontSample;
        a.endOfFragmentSampleIndex = sample + 1;
    }
    ShaderFull full{};
    full.u = j.u;
    Inputs in;
    put_image(full, image, in, k_by_job);
    put_last(full, last, drawable.texture, in);
    encode_passes(cb, ps, full, in, false);
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
    [e setRenderPipelineState:pipeline];
    in.use(e);
    [e setFragmentBytes:&full length:sizeof full atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    copy_last(cb, last, drawable.texture, false);
    [cb presentDrawable:drawable];
    id<MTLCounterSampleBuffer> samples = g_samples;
    const uint32_t gen = j.gen;
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        (void)drawable, (void)pipeline, (void)image, (void)last, (void)ps;
        frame_done(l, gen);
        if (sample == UINT32_MAX)
            return;
        NSData* r = [samples resolveCounterRange:NSMakeRange(sample, 2)];
        if (r.length < 2 * sizeof(MTLCounterResultTimestamp))
            return;
        const MTLCounterResultTimestamp* t = (const MTLCounterResultTimestamp*)r.bytes;
        if (t[0].timestamp == MTLCounterErrorValue || t[1].timestamp == MTLCounterErrorValue
            || t[1].timestamp < t[0].timestamp)
            return;
        uint64_t ns = t[1].timestamp - t[0].timestamp;
        rx::sync::fetch_add(l->gpu_ns, static_cast<decltype(l->gpu_ns.load())>(ns), std::memory_order_relaxed);
        rx::sync::fetch_add(l->gpu_passes, static_cast<decltype(l->gpu_passes.load())>(1), std::memory_order_relaxed);
        rx::trace::record_ns(rx::trace::Cat::gpu, ns);
    }];
}

static bool render_start(void) {
    return rx::gpu::render_start();
}

static bool render_push(RXShaderLayer* l) {
    CGSize b = l.bounds.size, d = l.drawableSize;
    if (!render_start() || !l.pipeline || b.width < 1 || b.height < 1 || l->inflight.load() >= MIN(2, room(l)))
        return false;
    RenderJob j{};
    j.u.size = simd_make_float2(b.width, b.height);
    j.u.mouse = l.mouse;
    j.u.time = l.time;
    j.u.hover = l.hover;
    j.u.scale = d.width / b.width;
    j.u.seed = l.seed;
    shown_params(l, j.u.params);
    memcpy(j.u.colors, l->colors, sizeof j.u.colors);
    j.w = (uint32_t)d.width, j.h = (uint32_t)d.height;
    j.gen = l->gen;
    j.sample = UINT32_MAX;
    j.room = MIN(2, room(l));
    if (gpu_timing()) {
        j.sample = (uint32_t)g_sample_at;
        g_sample_at = (g_sample_at + 2) % k_samples;
    }
    j.layer = (__bridge_retained void*)l;
    j.pipeline = (__bridge_retained void*)l.pipeline;
    j.image = l.image ? (__bridge_retained void*)l.image : nullptr;
    j.last = l.last ? (__bridge_retained void*)l.last : nullptr;
    j.passes = l.passset ? (__bridge_retained void*)l.passset : nullptr;
    rx::sync::fetch_add(l->inflight, 1, std::memory_order_seq_cst);
    rx::gpu::Job job;
    job.encode = encode_job;
    memcpy(job.data, &j, sizeof j);
    if (!rx::gpu::render_push(job)) {
        rx::sync::fetch_sub(l->inflight, 1, std::memory_order_seq_cst);
        (void)(__bridge_transfer id)j.layer, (void)(__bridge_transfer id)j.pipeline;
        if (j.image)
            (void)(__bridge_transfer id)j.image;
        if (j.last)
            (void)(__bridge_transfer id)j.last;
        if (j.passes)
            (void)(__bridge_transfer id)j.passes;
        return false;
    }
    l.last_draw = CACurrentMediaTime();
    l.stale = NO;
    return true;
}

static NSMutableOrderedSet<RXShaderLayer*>* g_sync;
static bool g_sync_armed;

static void flush_sync(bool in_commit = true) {
    g_sync_armed = false;
    if (!g_sync.count)
        return;
    NSArray<RXShaderLayer*>* ls = [g_sync.array copy];
    [g_sync removeAllObjects];
    id<MTLCommandBuffer> cb = nil;
    NSMutableArray<id<CAMetalDrawable>>* drawables = [NSMutableArray array];
    NSMutableArray<RXShaderLayer*>* drawn = [NSMutableArray array];
    for (RXShaderLayer* l in ls) {
        if (id<CAMetalDrawable> d = encode(l, &cb, 3)) {
            [drawables addObject:d];
            [drawn addObject:l];
        } else {
            owe(l);
        }
    }
    if (!cb)
        return;
    if (!in_commit) {
        for (id<CAMetalDrawable> d in drawables)
            [cb presentDrawable:d];
        [cb commit];
        return;
    }
    for (RXShaderLayer* l in drawn)
        l.presentsWithTransaction = YES;
    [cb commit];
    [cb waitUntilScheduled];
    for (id<CAMetalDrawable> d in drawables)
        [d present];
    for (RXShaderLayer* l in drawn)
        l.presentsWithTransaction = NO;
}

static bool arm_sync(void) {
    if (g_sync_armed)
        return true;
    static SEL sel = @selector(addCommitHandler:forPhase:);
    static bool has = [CATransaction respondsToSelector:sel];
    if (!has)
        return false;
    using Add = BOOL (*)(id, SEL, void (^)(void), int);
    constexpr int kPreCommit = 1;
    g_sync_armed = ((Add)objc_msgSend)(
        [CATransaction class], sel,
        ^{
            flush_sync();
        },
        kPreCommit);
    static uint64_t armings;
    if (g_sync_armed) {
        const uint64_t mine = ++armings;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (g_sync_armed && armings == mine)
                flush_sync(false);
        });
    }
    return g_sync_armed;
}

@interface RXLive : NSObject {
   @public
    RXShaderLayer* layer;
    id<MTLRenderPipelineState> pipeline;
    id<MTLTexture> image;
    id<MTLTexture> last;
    RXPassSet* passes;
}
@end
@implementation RXLive
@end

static std::atomic<uint64_t> g_link_frames;
static std::atomic<uint64_t> g_frames_read;
uint64_t shader_frames_read(void) {
    return g_frames_read.load(std::memory_order_relaxed);
}
CGSize shader_last_size(CALayer* layer) {
    if (![layer isKindOfClass:RXShaderLayer.class])
        return CGSizeZero;
    id<MTLTexture> t = ((RXShaderLayer*)layer).last;
    return t ? CGSizeMake(t.width, t.height) : CGSizeZero;
}
uint64_t shader_passes_drawn(void) {
    return g_passes_main + g_r_passes.load(std::memory_order_relaxed);
}
NSUInteger shader_pass_count(CALayer* layer) {
    if (![layer isKindOfClass:RXShaderLayer.class])
        return 0;
    RXPassSet* ps = ((RXShaderLayer*)layer).passset;
    return ps ? ps->tex.count : 0;
}
uint64_t shader_last_copies(void) {
    return g_last_copies + g_r_last_copies.load(std::memory_order_relaxed);
}
void shader_image_frames(uint64_t out[3]) {
    for (int i = 0; i < 3; i++)
        out[i] = g_image_frames[i].load(std::memory_order_relaxed);
}
CGSize shader_image_size(CALayer* layer) {
    if (![layer isKindOfClass:RXShaderLayer.class])
        return CGSizeZero;
    id<MTLTexture> t = ((RXShaderLayer*)layer).image;
    return t ? CGSizeMake(t.width, t.height) : CGSizeZero;
}

static constexpr double k_watch_fps = 4;
static NSHashTable<RXShaderLayer*>* g_linked;
static rx::sync::Flag g_timing_on;
static NSUInteger g_r_sample_at = k_samples / 2;

static void live_publish(RXShaderLayer* l) {
    RXNode* n = l.node;
    CGSize b = l.bounds.size, d = l.drawableSize;
    LiveState& s = l->live.back();
    s.u.size = simd_make_float2(b.width, b.height);
    s.u.mouse = l.mouse;
    s.u.scale = b.width > 0 ? d.width / b.width : 1;
    s.u.seed = l.seed;
    shown_params(l, s.u.params);
    memcpy(s.u.colors, l->colors, sizeof s.u.colors);
    s.over = l->over;
    s.running = n && flag(n, P::running, true);
    s.pane = n && pane_key(n) != nil;
    s.gen = l->gen;
    s.w = (uint32_t)d.width, s.h = (uint32_t)d.height;
    s.room = (uint32_t)MIN(2, room(l));
    s.fps = n ? (float)shader_fps(n) : 60;
    s.exact = g_config.shader_pacing == 2;
    l->live.publish();
    l.last_draw = CACurrentMediaTime();
    l.stale = NO;
}

static bool live_draw(void* ctx, double now, id<MTLCommandBuffer> cb) {
    RXLive* c = (__bridge RXLive*)ctx;
    RXShaderLayer* l = c->layer;
    (void)l->live.take();
    const LiveState& s = l->live.front();
    if (s.exact && s.fps > 0) {
        if (now < l->r_due - 0.002)
            return false;
        l->r_due = MAX(l->r_due + 1.0 / s.fps, now - 0.5 / s.fps);
    }
    if (l->inflight.load() >= (int)s.room)
        return false;
    id<CAMetalDrawable> drawable = next_drawable(l);
    if (!drawable)
        return false;
    if (drawable.texture.width != s.w || drawable.texture.height != s.h)
        return false;
    const double dt = l->r_last > 0 ? MIN(0.1, now - l->r_last) : 0;
    l->r_last = now;
    if (s.running)
        l->r_time = s.pane ? now - g_epoch : l->r_time + dt;
    l->r_hover += (s.over - l->r_hover) * (float)(1 - exp(-dt / 0.18));
    ShaderUniforms u = s.u;
    u.time = (float)l->r_time;
    u.hover = (float)l->r_hover;
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    uint32_t sample = UINT32_MAX;
    id<MTLCounterSampleBuffer> samples = nil;
    if (g_timing_on.get()) {
        samples = g_samples;
        sample = (uint32_t)g_r_sample_at;
        g_r_sample_at = g_r_sample_at + 2 >= k_samples ? k_samples / 2 : g_r_sample_at + 2;
        MTLRenderPassSampleBufferAttachmentDescriptor* a = pass.sampleBufferAttachments[0];
        a.sampleBuffer = samples;
        a.startOfVertexSampleIndex = sample;
        a.endOfVertexSampleIndex = MTLCounterDontSample;
        a.startOfFragmentSampleIndex = MTLCounterDontSample;
        a.endOfFragmentSampleIndex = sample + 1;
    }
    id<MTLRenderPipelineState> pipeline = c->pipeline;
    id<MTLTexture> image = c->image, last = c->last;
    RXPassSet* ps = c->passes;
    ShaderFull full{};
    full.u = u;
    if (l->reader) {
        const long got = rexui_frames_copy(l->reader, l->r_frames, 128);
        if (got >= 0)
            l->r_nframes = (uint32_t)got,
            g_frames_read.store(g_frames_read.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
        full.nframes = (float)l->r_nframes;
        memcpy(full.frames, l->r_frames, sizeof full.frames);
    }
    Inputs in;
    put_image(full, image, in, k_by_link);
    put_last(full, last, drawable.texture, in);
    encode_passes(cb, ps, full, in, false);
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
    [e setRenderPipelineState:pipeline];
    in.use(e);
    [e setFragmentBytes:&full length:sizeof full atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    copy_last(cb, last, drawable.texture, false);
    [cb presentDrawable:drawable];
    rx::sync::fetch_add(l->inflight, 1, std::memory_order_seq_cst);
    const uint32_t gen = s.gen;
    g_link_frames.store(g_link_frames.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
        (void)pipeline, (void)drawable, (void)image, (void)last, (void)ps;
        frame_done(l, gen);
        if (sample == UINT32_MAX)
            return;
        NSData* r = [samples resolveCounterRange:NSMakeRange(sample, 2)];
        if (r.length < 2 * sizeof(MTLCounterResultTimestamp))
            return;
        const MTLCounterResultTimestamp* t = (const MTLCounterResultTimestamp*)r.bytes;
        if (t[0].timestamp == MTLCounterErrorValue || t[1].timestamp == MTLCounterErrorValue
            || t[1].timestamp < t[0].timestamp)
            return;
        uint64_t ns = t[1].timestamp - t[0].timestamp;
        rx::sync::fetch_add(l->gpu_ns, static_cast<decltype(l->gpu_ns.load())>(ns), std::memory_order_relaxed);
        rx::sync::fetch_add(l->gpu_passes, static_cast<decltype(l->gpu_passes.load())>(1), std::memory_order_relaxed);
        rx::trace::record_ns(rx::trace::Cat::gpu, ns);
    }];
    return true;
}

uint64_t shader_link_frames(void) {
    return g_link_frames.load(std::memory_order_relaxed);
}

static void live_gone(void* ctx) {
    RXLive* c = (__bridge_transfer RXLive*)ctx;
    RXShaderLayer* l = c->layer;
    dispatch_async(dispatch_get_main_queue(), ^{
        l->unlinking = false;
        if (l.node)
            draw(l);
    });
}

static bool linked(RXShaderLayer* l) {
    return l->link.v != 0;
}

void shader_unlink(RXNode* n) {
    if (!is_elem(n, E::Shader) || ![n.layer isKindOfClass:RXShaderLayer.class])
        return;
    RXShaderLayer* l = (RXShaderLayer*)n.layer;
    if (!linked(l) || !rx::gpu::link_remove(l->link))
        return;
    l->link = {};
    l->unlinking = true;
    [g_linked removeObject:l];
    const double now = CACurrentMediaTime();
    if (flag(n, P::running, true))
        l.time = pane_key(n) ? pane_time() : l->link_time0 + (now - l->link_t0);
    l.hover = l->over;
    node_link_rate(n);
}

static double paced_fps(RXNode* n);
static double link_fps(RXNode* n) {
    return paced_fps(n);
}

static bool may_link(RXShaderLayer* l, RXNode* n) {
    static const bool off = [] {
        const char* e = getenv("REXUI_SHADER_LINK");
        return e && e[0] == '0';
    }();
    return !off && !l->unlinking && !l.frames_wanted && !ui_clock_occluded_now() && l.pipeline
        && flag(n, P::running, true) && !gliding(l) && l->glide_s == 0 && !l.trimmed && !l.queued
        && CACurrentMediaTime() - l.resized_at >= 0.5 && !hidden_by_us(l) && ![g_sync containsObject:l]
        && l.drawableSize.width >= 1;
}

bool ui_gpu_clock(void) {
    static bool attached;
    if (!attached) {
        id link = [NSScreen.mainScreen displayLinkWithTarget:rx::gpu::link_target() selector:@selector(tick:)];
        attached = link && rx::gpu::clock_attach(link);
    }
    return attached;
}

static bool shader_link(RXShaderLayer* l, RXNode* n) {
    if (linked(l))
        return true;
    if (!rx::gpu::render_start())
        return false;
    g_timing_on.set(gpu_timing());
    l->r_time = l.time, l->r_hover = l.hover, l->r_last = 0, l->r_due = 0;
    live_publish(l);
    RXLive* c = [RXLive new];
    c->layer = l, c->pipeline = l.pipeline, c->image = l.image, c->last = l.last, c->passes = l.passset;
    void* ctx = (__bridge_retained void*)c;
    l->link = ui_gpu_clock() ? rx::gpu::link_add(link_fps(n), live_draw, live_gone, ctx) : rx::gpu::LinkId{};
    if (!linked(l)) {
        (void)(__bridge_transfer RXLive*)ctx;
        return false;
    }
    l->link_t0 = CACurrentMediaTime(), l->link_time0 = l.time;
    if (!g_linked)
        g_linked = [NSHashTable weakObjectsHashTable];
    [g_linked addObject:l];
    node_link_rate(n);
    return true;
}

void shaders_pointer(NSWindow* w, NSPoint p, bool out) {
    if (!g_linked.count)
        return;
    NSInteger under = -1;
    for (RXShaderLayer* l in g_linked) {
        RXNode* n = l.node;
        if (!n || host_of(n).window != w)
            continue;
        NSRect r = node_window_rect(n);
        bool over = !out && NSPointInRect(p, r);
        if (over) {
            if (under < 0)
                under = [NSWindow windowNumberAtPoint:[w convertPointToScreen:p] belowWindowWithWindowNumber:0];
            over = under == w.windowNumber;
        }
        const simd_float2 m = over ? simd_make_float2(p.x - r.origin.x, NSMaxY(r) - p.y) : l.mouse;
        if ((over ? 1.f : 0.f) == l->over && (!over || !simd_any(m != l.mouse)))
            continue;
        l->over = over ? 1 : 0;
        l.mouse = m;
        live_publish(l);
    }
}

void shader_link_rate(RXNode* n) {
    RXShaderLayer* l = [n.layer isKindOfClass:RXShaderLayer.class] ? (RXShaderLayer*)n.layer : nil;
    if (l && linked(l))
        (void)rx::gpu::link_rate(l->link, link_fps(n)), live_publish(l);
}

static double paced_fps(RXNode* n) {
    return g_config.shader_pacing == 0 ? shader_fps(n) : 120;
}
double shader_clock_fps(RXNode* n) {
    RXShaderLayer* l = [n.layer isKindOfClass:RXShaderLayer.class] ? (RXShaderLayer*)n.layer : nil;
    return l && linked(l) ? k_watch_fps : paced_fps(n);
}

void shaders_unlink_all(void) {
    for (RXShaderLayer* l in g_linked.allObjects)
        if (RXNode* n = l.node)
            shader_unlink(n);
}

static void draw(RXShaderLayer* l, bool synced) {
    RX_INTERVAL(shader, "draw");
    if (l->unlinking)
        return l.stale = YES, void();
    if (linked(l)) {
        synced |= CACurrentMediaTime() - l.resized_at < 0.5;
        if (!synced)
            return live_publish(l);
        if (RXNode* n = l.node)
            shader_unlink(n);
        if (linked(l))
            return live_publish(l);
        return l.stale = YES, void();
    }
    NSString* key = l.node ? pane_key(l.node) : nil;
    if (key && ![key isEqualToString:l.placed]) {
        NSString* bid = [key componentsSeparatedByString:@"#"].firstObject;
        l.seed = (fnv(bid) >> 11) / 9007199254740992.0;
        l.placed = key;
        [l fitDrawable];
    }
    if (hidden_by_us(l)) {
        l.stale = YES;
        return;
    }
    if (l.trimmed)
        l.trimmed = NO, [l fitDrawable];
    synced |= CACurrentMediaTime() - l.resized_at < 0.5;
    if (!g_sync)
        g_sync = [NSMutableOrderedSet orderedSet];
    if (synced && arm_sync()) {
        [g_sync addObject:l];
        return;
    }
    if (!synced && [g_sync containsObject:l])
        return;
    if (!synced && render_push(l))
        return;
    id<MTLCommandBuffer> cb = nil;
    id<CAMetalDrawable> drawable = encode(l, &cb, synced ? 3 : 2);
    if (!drawable)
        return owe(l);
    if (!synced) {
        [cb presentDrawable:drawable];
        [cb commit];
        return;
    }
    l.presentsWithTransaction = YES;
    [cb commit];
    [cb waitUntilScheduled];
    [drawable present];
    l.presentsWithTransaction = NO;
}

static void shown(CALayer* root, int depth) {
    if (depth > 64)
        return;
    if ([root isKindOfClass:RXShaderLayer.class] && ((RXShaderLayer*)root).stale)
        draw((RXShaderLayer*)root, true);
    for (CALayer* s in root.sublayers)
        shown(s, depth + 1);
}
void shaders_shown(CALayer* root) {
    if (root && g_shaders.count)
        shown(root, 0);
}

static void open_frames(RXShaderLayer* l, RXNode* n) {
    if (linked(l) || l->unlinking)
        return;
    NSString* region = str(n, P::frames, @"");
    if (l->reader)
        rexui_frames_unmap(l->reader), delete l->reader, l->reader = nullptr;
    l->r_nframes = 0;
    if (!region.length)
        return;
    auto* r = new rexui_frames_reader();
    if ([region hasPrefix:@"/"] && region.length <= 31 && rexui_frames_open(r, region.UTF8String) == 0)
        l->reader = r;
    else
        delete r, rexui_log([NSString stringWithFormat:@"%@: no frames at %@", n.doc.path.lastPathComponent, region]);
}

static void image_ready(RXShaderLayer* l, id<MTLTexture> t) {
    RXNode* n = l.node;
    if (n)
        shader_unlink(n);
    l.image = t;
    if (!n)
        return;
    if (!shader_moving(n))
        draw_soon(l);
    node_link(n, true);
}
static id<MTLTexture> read_image(NSString* path) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], nullptr);
    if (!src)
        return nil;
    NSDictionary* o = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @4096,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceShouldCacheImmediately: @YES
    };
    CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)o);
    CFRelease(src);
    if (!img)
        return nil;
    const size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    std::vector<uint8_t> px(w * h * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx =
        CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (ctx)
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img), CGContextRelease(ctx);
    CGImageRelease(img);
    if (!ctx)
        return nil;
    for (size_t i = 0; i < px.size(); i += 4)
        if (const uint8_t a = px[i + 3]; a && a < 255)
            for (int c = 0; c < 3; c++)
                px[i + c] = (uint8_t)MIN(255, (px[i + c] * 255 + a / 2) / a);
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                 width:w
                                                                                height:h
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [rx::gpu::device() newTextureWithDescriptor:d];
    [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px.data() bytesPerRow:w * 4];
    return t;
}
static void load_image(RXShaderLayer* l) {
    RXNode* n = l.node;
    NSString* image = n ? str(n, P::image, @"") : @"";
    const uint32_t ask = ++l.image_ask;
    if (!image.length) {
        l.image_file = nil;
        if (l.image)
            image_ready(l, nil);
        return;
    }
    NSString* path = image.stringByExpandingTildeInPath;
    if (!path.isAbsolutePath)
        path = [doc_dir(n) stringByAppendingPathComponent:path];
    path = path.stringByStandardizingPath;
    l.image_file = path;
    l.image_mtime = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
    NSString* who = n.doc.path.lastPathComponent;
    __weak RXShaderLayer* weak = l;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        id<MTLTexture> t = read_image(path);
        dispatch_async(dispatch_get_main_queue(), ^{
            RXShaderLayer* layer = weak;
            if (!layer || layer.image_ask != ask)
                return;
            if (!t)
                rexui_log([NSString stringWithFormat:@"%@: no image at %@", who, image]);
            image_ready(layer, t);
        });
    });
}

static void fit_last(RXShaderLayer* l) {
    RXNode* n = l.node;
    const bool on = n && flag(n, P::feedback, false);
    const CGSize d = l.drawableSize;
    if (l.framebufferOnly == on)
        l.framebufferOnly = !on;
    if (!on || d.width < 2 || d.height < 2) {
        l.last = nil;
        return;
    }
    if (l.last && l.last.width == (NSUInteger)d.width && l.last.height == (NSUInteger)d.height)
        return;
    MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:(NSUInteger)d.width
                                                                                 height:(NSUInteger)d.height
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [rx::gpu::device() newTextureWithDescriptor:td];
    MTLRenderPassDescriptor* clear = [MTLRenderPassDescriptor renderPassDescriptor];
    clear.colorAttachments[0].texture = t;
    clear.colorAttachments[0].loadAction = MTLLoadActionClear;
    clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    clear.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [rx::gpu::queue() commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:clear] endEncoding];
    [cb commit];
    l.last = t;
}

static bool read_passes(RXShaderLayer* l) {
    RXNode* n = l.node;
    id a = n ? obj(n, P::passes) : nil;
    NSArray* list = [a isKindOfClass:NSArray.class] ? a : @[];
    NSMutableArray<NSString*>* names = [NSMutableArray array];
    NSMutableArray<NSNumber*>* scales = [NSMutableArray array];
    static NSRegularExpression* word = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z_][A-Za-z0-9_]*$"
                                                                                 options:0
                                                                                   error:nil];
    bool ok = list.count <= 4;
    for (id p in list) {
        NSString* fn = [p isKindOfClass:NSString.class] ? p : [p isKindOfClass:NSDictionary.class] ? p[@"fn"] : nil;
        id sc = [p isKindOfClass:NSDictionary.class] ? p[@"scale"] : nil;
        if (![fn isKindOfClass:NSString.class]
            || ![word firstMatchInString:fn options:0 range:NSMakeRange(0, fn.length)] || [fn isEqualToString:@"shade"]
            || [fn hasPrefix:@"rx_"]) {
            ok = false;
            continue;
        }
        if (names.count == 4)
            break;
        [names addObject:fn];
        [scales addObject:@(MAX(0.05, MIN(2.0, [sc isKindOfClass:NSNumber.class] ? [sc doubleValue] : 1.0)))];
    }
    l.pass_names = names, l.pass_scales = scales;
    return ok;
}

static void fit_passes(RXShaderLayer* l) {
    const CGSize d = l.drawableSize;
    NSArray<NSNumber*>* scales = l.pass_scales ?: @[];
    if (!scales.count || d.width < 2 || d.height < 2) {
        if (l.pass_tex.count)
            l.pass_tex = @[], set_passes(l);
        return;
    }
    NSMutableArray<id<MTLTexture>>* tex = [NSMutableArray array];
    id<MTLCommandBuffer> cb = nil;
    bool changed = scales.count != l.pass_tex.count;
    for (NSUInteger i = 0; i < scales.count; i++) {
        const NSUInteger w = MAX(1, (NSUInteger)round(d.width * scales[i].doubleValue)),
                         h = MAX(1, (NSUInteger)round(d.height * scales[i].doubleValue));
        id<MTLTexture> was = i < l.pass_tex.count ? l.pass_tex[i] : nil;
        if (was && was.width == w && was.height == h) {
            [tex addObject:was];
            continue;
        }
        MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                      width:w
                                                                                     height:h
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [rx::gpu::device() newTextureWithDescriptor:td];
        MTLRenderPassDescriptor* clear = [MTLRenderPassDescriptor renderPassDescriptor];
        clear.colorAttachments[0].texture = t;
        clear.colorAttachments[0].loadAction = MTLLoadActionClear;
        clear.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        clear.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (!cb)
            cb = [rx::gpu::queue() commandBuffer];
        [[cb renderCommandEncoderWithDescriptor:clear] endEncoding];
        [tex addObject:t];
        changed = true;
    }
    [cb commit];
    if (changed)
        l.pass_tex = tex, set_passes(l);
}

static void set_passes(RXShaderLayer* l) {
    NSArray *st = l.pass_states ?: @[], *tex = l.pass_tex ?: @[];
    RXPassSet* ps = nil;
    if (st.count && st.count == tex.count && st.count == l.pass_names.count) {
        ps = [RXPassSet new];
        ps->states = st, ps->tex = tex;
    }
    if (ps == l.passset
        || (ps && l.passset && [ps->states isEqualToArray:l.passset->states] &&
            [ps->tex isEqualToArray:l.passset->tex]))
        return;
    if (l.node)
        shader_unlink(l.node);
    l.passset = ps;
    if (l.node)
        node_link(l.node, true);
}

void shader_apply(RXNode* n, NSString* name) {
    RXShaderLayer* l = (RXShaderLayer*)n.layer;
    if ([name isEqualToString:@"source"] || [name isEqualToString:@"code"])
        return load_source(l);
    if ([name isEqualToString:@"image"])
        return load_image(l);
    if ([name isEqualToString:@"passes"]) {
        NSArray* was = l.pass_names;
        if (!read_passes(l))
            set_error(l, @"passes: up to 4 of the source's functions by name (not shade), or {fn, scale}");
        fit_passes(l);
        if (![was isEqualToArray:l.pass_names] && (was.count || l.pass_names.count)) {
            l.key = nil;
            load_source(l);
        }
        set_passes(l);
        if (!shader_moving(n))
            draw_soon(l);
        return;
    }
    if ([name isEqualToString:@"feedback"]) {
        shader_unlink(n);
        fit_last(l);
        if (!shader_moving(n))
            draw_soon(l);
        return node_link(n, true);
    }
    if ([name isEqualToString:@"frames"]) {
        l.frames_wanted = YES;
        shader_unlink(n);
        open_frames(l, n);
        if (!linked(l) && !l->unlinking)
            l.frames_wanted = NO;
        return node_link(n, true);
    }
    if ([name isEqualToString:@"fps"]) {
        NSUInteger want = shader_fps(n) <= 30 ? 2 : 3;
        if (l.maximumDrawableCount != want)
            l.maximumDrawableCount = want;
    }
    if ([name isEqualToString:@"params"]) {
        float was[16], shown[16];
        memcpy(was, l->params, sizeof was);
        shown_params(l, shown);
        read_params(l);
        if (!memcmp(was, l->params, sizeof was))
            return;
        double ms = num(n, P::paramsAnimation, 0);
        if (ms > 0 && l.pipeline && n.doc) {
            memcpy(l->from, shown, sizeof shown);
            l->glide_t0 = CACurrentMediaTime(), l->glide_s = ms / 1000;
            node_link(n, true);
            return;
        }
        l->glide_s = 0;
    } else if ([name isEqualToString:@"colors"]) {
        simd_float4 was[8];
        memcpy(was, l->colors, sizeof was);
        read_colors(l);
        if (!memcmp(was, l->colors, sizeof was))
            return;
    } else if ([name isEqualToString:@"scale"])
        [l fitDrawable];
    else if ([name isEqualToString:@"running"] || [name isEqualToString:@"fps"]) {
        node_link_rate(n);
        return node_link(n, true);
    } else
        return;
    if (!shader_moving(n))
        draw_soon(l);
}

void shader_resized(RXNode* n) {
    RXShaderLayer* l = (RXShaderLayer*)n.layer;
    l.resized_at = CACurrentMediaTime();
    draw(l, true);
}

bool shader_moving(RXNode* n) {
    RXShaderLayer* l = (RXShaderLayer*)n.layer;
    return l.pipeline && (flag(n, P::running, true) || gliding(l));
}

static bool pane_unfocused(RXNode* n) {
    if (g_config.pane_shader_unfocused_fps <= 0)
        return false;
    NSString* key = pane_key(n);
    if (!key)
        return false;
    NSString* focused = panes_focused_block();
    return focused.length && ![[key componentsSeparatedByString:@"#"].firstObject isEqualToString:focused];
}
double shader_fps(RXNode* n) {
    const double s = power_shader_scale();
    double fps = MIN(120, num(n, P::fps, 60));
    if (pane_unfocused(n))
        fps = MIN(fps, g_config.pane_shader_unfocused_fps);
    return MAX(1, fps * (s > 0 ? s : 1));
}

void shaders_panes_changed(void) {
    for (RXShaderLayer* l in g_shaders.allObjects)
        if (RXNode* n = l.node)
            if (pane_key(n))
                node_link_rate(n);
}

void shaders_config_changed(void) {
    static int was = -1;
    if (was == g_config.shader_pacing)
        return;
    was = g_config.shader_pacing;
    for (RXShaderLayer* l in g_shaders.allObjects)
        if (RXNode* n = l.node)
            l->due = 0, node_link_rate(n);
}

void shaders_power_changed(void) {
    for (RXShaderLayer* l in g_shaders.allObjects)
        if (RXNode* n = l.node) {
            node_link_rate(n);
            node_link(n, power_shader_scale() > 0);
        }
}

uint64_t shader_drawable_bytes(CALayer* layer) {
    if (![layer isKindOfClass:RXShaderLayer.class])
        return 0;
    RXShaderLayer* l = (RXShaderLayer*)layer;
    if (l.modelLayer != l || l.trimmed || l.last_draw <= 0)
        return 0;
    uint64_t passes = 0;
    for (id<MTLTexture> t in l.pass_tex)
        passes += t.width * t.height * 8;
    return (uint64_t)(l.drawableSize.width * l.drawableSize.height * 4) * (l.maximumDrawableCount + (l.last ? 1 : 0))
        + passes;
}

static bool seen(CALayer* l);
static double trim_after(void) {
    static const double after = [] {
        const char* e = getenv("REXUI_SHADER_TRIM_S");
        return e ? atof(e) : 30.0;
    }();
    return after;
}
static void shaders_sweep(void) {
    const double now = CACurrentMediaTime();
    static const bool slim = getenv("REXUI_SHADER_SLIM") != nullptr;
    for (RXShaderLayer* l in g_shaders.allObjects) {
        if (l.modelLayer != l)
            continue;
        if (seen(l)) {
            l.unseen_at = 0;
            RXNode* n = l.node;
            if (l.trimmed && l.stale && n && !linked(l)) {
                draw(l, false);
                continue;
            }
            if (slim && n && !flag(n, P::running, true) && !l.trimmed && l.last_draw > 0 && now - l.last_draw > 3
                && !linked(l) && !l.queued && l->inflight.load() == 0 && !l->owed.load()) {
                l.drawableSize = CGSizeMake(1, 1);
                l.trimmed = YES;
            }
            continue;
        }
        if (l.unseen_at <= 0)
            l.unseen_at = now;
        if (l.trimmed || l.last_draw <= 0 || now - l.unseen_at < trim_after())
            continue;
        l.drawableSize = CGSizeMake(1, 1);
        l.trimmed = YES;
        l.stale = YES;
    }
}
static void sweep_start(void) {
    static dispatch_source_t t;
    if (t)
        return;
    t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    const double every = MIN(5.0, trim_after() / 2);
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(every * NSEC_PER_SEC)),
                              (uint64_t)(every * NSEC_PER_SEC), NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(t, ^{
        shaders_sweep();
    });
    dispatch_resume(t);
}

int shaders_trim(void) {
    int n = 0;
    for (RXShaderLayer* l in g_shaders.allObjects) {
        if (l.trimmed || seen(l) || l.modelLayer != l)
            continue;
        l.drawableSize = CGSizeMake(1, 1);
        l.trimmed = YES;
        l.stale = YES;
        n++;
    }
    return n;
}

static bool seen(CALayer* l) {
    for (CALayer* x = l; x; x = x.superlayer) {
        if (x.hidden || x.opacity <= 0)
            return false;
    }
    return true;
}

static bool covered(RXNode* n, NSString* key) {
    if (!key || [key containsString:@"#"])
        return false;
    for (RXNode* c = n; c; c = c.parent)
        if (c.parent == n.doc.root) {
            if ([obj(c, @"paneSlot") isEqual:@"overlay"])
                return false;
            break;
        }
    return panes_app_covers(key);
}

void shader_tick(RXNode* n, double dt) {
    RXShaderLayer* l = (RXShaderLayer*)n.layer;
    NSString* key = pane_key(n);
    bool pane = key != nil;
    if (pane && covered(n, key)) {
        shader_unlink(n);
        l.stale = YES;
        return;
    }
    if (l.frames_wanted && !linked(l) && !l->unlinking)
        open_frames(l, n), l.frames_wanted = NO;
    if (linked(l))
        g_timing_on.set(gpu_timing());
    else if (flag(n, P::running, true))
        l.time = pane ? pane_time() : l.time + dt;
    bool landing = l->glide_s > 0 && !gliding(l);
    if (landing)
        l->glide_s = 0;
    if (!seen(l)) {
        shader_unlink(n);
        l.stale = YES;
        return;
    }
    l.unseen_at = 0;
    if (power_shader_scale() <= 0 && !landing && l->glide_s == 0) {
        shader_unlink(n);
        node_link(n, false);
        return;
    }
    if (linked(l)) {
        if (!landing && may_link(l, n))
            return;
        shader_unlink(n);
    }
    id<RXHost> host = host_of(n);
    NSWindow* w = host.window;
    bool over = false;
    if (w.isVisible) {
        NSPoint p = w.mouseLocationOutsideOfEventStream;
        NSRect r = node_window_rect(n);
        static double asked_at;
        static NSInteger under;
        double now = CACurrentMediaTime();
        if (NSPointInRect(p, r)) {
            if (now - asked_at > 0.004)
                under = [NSWindow windowNumberAtPoint:NSEvent.mouseLocation belowWindowWithWindowNumber:0],
                asked_at = now;
            if (under == w.windowNumber) {
                over = true;
                l.mouse = simd_make_float2(p.x - r.origin.x, NSMaxY(r) - p.y);
            }
        }
    }
    l->over = over ? 1 : 0;
    l.hover += ((over ? 1 : 0) - l.hover) * (1 - exp(-dt / 0.18));
    if (!landing && may_link(l, n) && shader_link(l, n))
        return;
    const double now = CACurrentMediaTime(), fps = shader_fps(n);
    if (!landing) {
        if (g_config.shader_pacing == 2) {
            if (now < l->due - 0.002)
                return;
            l->due = MAX(l->due + 1 / fps, now - 0.5 / fps);
        } else if (g_config.shader_pacing == 0 && now - l.last_draw < 1 / fps - 0.004) {
            return;
        }
    }
    draw(l);
}

static void wake(CALayer* root, int depth) {
    if (depth > 64)
        return;
    if ([root isKindOfClass:RXShaderLayer.class]) {
        RXShaderLayer* l = (RXShaderLayer*)root;
        if (l.node && pane_key(l.node) && shader_moving(l.node))
            l.time = pane_time();
        draw(l);
    }
    for (CALayer* s in root.sublayers)
        wake(s, depth + 1);
}
extern "C" void rexui_shaders_wake(const void* layer) {
    if (layer && g_shaders.count)
        wake((__bridge CALayer*)layer, 0);
}

static void moved(CALayer* root, int depth) {
    if (depth > 64)
        return;
    if ([root isKindOfClass:RXShaderLayer.class]) {
        RXShaderLayer* l = (RXShaderLayer*)root;
        NSString* key = l.node ? pane_key(l.node) : nil;
        if (key && ![key isEqualToString:l.placed]) {
            NSString* bid = [key componentsSeparatedByString:@"#"].firstObject;
            if (l.placed && [[l.placed componentsSeparatedByString:@"#"].firstObject isEqualToString:bid])
                l.placed = key;
            else
                draw(l, true);
        }
    }
    for (CALayer* s in root.sublayers)
        moved(s, depth + 1);
}
void shaders_moved(CALayer* root) {
    if (root && g_shaders.count)
        moved(root, 0);
}

void shader_check(void) {
    static bool out;
    if (out)
        return;
    NSMutableArray<NSString*>* paths = [NSMutableArray array];
    for (RXShaderLayer* l in g_shaders.allObjects) {
        if (l.file && l.node.doc)
            [paths addObject:l.file];
        if (l.image_file && l.node.doc)
            [paths addObject:l.image_file];
    }
    if (!paths.count)
        return;
    out = true;
    stat_files(paths, ^(NSDictionary<NSString*, id>* when) {
        out = false;
        for (RXShaderLayer* l in g_shaders.allObjects) {
            if (!l.node.doc)
                continue;
            id m = l.file ? when[l.file] : nil;
            if (m && m != NSNull.null && ![m isEqual:l.file_mtime])
                load_source(l);
            id im = l.image_file ? when[l.image_file] : nil;
            if (im && im != NSNull.null && ![im isEqual:l.image_mtime])
                load_image(l);
        }
    });
}
