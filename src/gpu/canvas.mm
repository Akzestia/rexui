// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "gpu/canvas.h"
#include "gpu/gpu.h"

#import <Foundation/Foundation.h>

namespace rx::gpu {
namespace {

const char* k_source = R"msl(
#include <metal_stdlib>
using namespace metal;

struct Shape { float4 geo, more, wave, color; };
struct Out { float4 pos [[position]]; float2 p; uint i [[flat]]; };

constant float k_pi = 3.14159265358979;

float4 bounds(Shape s, float px) {
    uint k = uint(s.more.w);
    float pad = px;
    if (k == 0) return float4(s.geo.xy - pad, s.geo.xy + s.geo.zw + pad);
    if (k == 1) return float4(min(s.geo.xy, s.geo.zw) - s.more.x - pad, max(s.geo.xy, s.geo.zw) + s.more.x + pad);
    if (k == 3) return float4(s.geo.xy - s.geo.z - pad, s.geo.xy + s.geo.z + pad);
    float r = s.geo.z + s.geo.w + abs(s.wave.x) + pad;
    return float4(s.geo.xy - r, s.geo.xy + r);
}

vertex Out canvas_vertex(uint v [[vertex_id]], uint i [[instance_id]], constant Shape *shapes [[buffer(0)]],
                         constant float3 &view [[buffer(1)]]) {
    Shape s = shapes[i];
    float4 b = bounds(s, 1.0 / view.z);
    float2 corner = float2((v & 1) ? b.z : b.x, (v & 2) ? b.w : b.y);
    Out o;
    o.p = corner;
    o.pos = float4(corner.x / view.x * 2 - 1, 1 - corner.y / view.y * 2, 0, 1);
    o.i = i;
    return o;
}

float d_rect(float2 p, float4 g, float r) {
    float2 c = g.xy + g.zw * 0.5, h = g.zw * 0.5;
    r = min(r, min(h.x, h.y));
    float2 q = abs(p - c) - h + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
float d_capsule(float2 p, float2 a, float2 b, float r) {
    float2 pa = p - a, ba = b - a;
    float t = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * t) - r;
}
float d_arc(float2 p, Shape s) {
    float2 c = s.geo.xy;
    float r = s.geo.z, t = s.geo.w, start = s.more.x, sweep = s.more.y;
    float2 q = p - c;
    float a = atan2(q.y, q.x);
    float rel = fmod(a - start + 4 * k_pi, 2 * k_pi);
    float centre = r + s.wave.x * sin(s.wave.y * rel + s.wave.z);
    float ring = abs(length(q) - centre) - t;
    if (sweep >= 2 * k_pi || rel <= sweep) return ring;
    float a0 = start, a1 = start + sweep;
    float r0 = r + s.wave.x * sin(s.wave.z), r1 = r + s.wave.x * sin(s.wave.y * sweep + s.wave.z);
    float2 e0 = c + r0 * float2(cos(a0), sin(a0)), e1 = c + r1 * float2(cos(a1), sin(a1));
    return min(length(p - e0), length(p - e1)) - t;
}

float d_cookie(float2 p, Shape s) {
    float2 q = p - s.geo.xy;
    float r = s.geo.z, n = s.more.x;
    if (n >= 1) {
        float depth = min(0.3, 1.2 / n), a = atan2(q.y, q.x);
        r *= 1 - depth * (1 - cos(n * (a - s.geo.w + k_pi / 2))) / 2;
    }
    return length(q) - r;
}

fragment float4 canvas_fragment(Out in [[stage_in]], constant Shape *shapes [[buffer(0)]], constant float3 &view [[buffer(1)]]) {
    Shape s = shapes[in.i];
    uint k = uint(s.more.w);
    float d = k == 0 ? d_rect(in.p, s.geo, s.more.x) : k == 1 ? d_capsule(in.p, s.geo.xy, s.geo.zw, s.more.x) : k == 2 ? d_arc(in.p, s) : d_cookie(in.p, s);
    float cover = clamp(0.5 - d * view.z, 0.0, 1.0);
    float a = s.color.a * cover;
    return float4(s.color.rgb * a, a);
}
)msl";

id<MTLRenderPipelineState> g_pipeline;
bool g_failed;

id<MTLRenderPipelineState> pipeline() {
    if (g_pipeline || g_failed)
        return g_pipeline;
    NSError* e = nil;
    id<MTLLibrary> lib = [device() newLibraryWithSource:@(k_source) options:nil error:&e];
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"canvas_vertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"canvas_fragment"];
    MTLRenderPipelineColorAttachmentDescriptor* c = d.colorAttachments[0];
    c.pixelFormat = MTLPixelFormatBGRA8Unorm;
    c.blendingEnabled = YES;
    c.sourceRGBBlendFactor = c.sourceAlphaBlendFactor = MTLBlendFactorOne;
    c.destinationRGBBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    if (lib && d.vertexFunction && d.fragmentFunction)
        g_pipeline = [device() newRenderPipelineStateWithDescriptor:d error:&e];
    if (!g_pipeline) {
        g_failed = true;
        fprintf(stderr, "rexui canvas: no pipeline: %s\n", e.localizedDescription.UTF8String);
    }
    return g_pipeline;
}

}

bool canvas_encode(id<MTLCommandBuffer> cb, id<MTLTexture> target, const Shape* shapes, std::uint32_t n, float scale,
                   bool clear) {
    id<MTLRenderPipelineState> p = pipeline();
    if (!p || !target)
        return false;
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
    if (n) {
        const simd_float3 view = {(float)target.width / scale, (float)target.height / scale, scale};
        [e setRenderPipelineState:p];
        const NSUInteger bytes = n * sizeof(Shape);
        id<MTLBuffer> buf = nil;
        if (bytes <= 4096) {
            [e setVertexBytes:shapes length:bytes atIndex:0];
            [e setFragmentBytes:shapes length:bytes atIndex:0];
        } else {
            buf = [device() newBufferWithBytes:shapes length:bytes options:MTLResourceStorageModeShared];
            [e setVertexBuffer:buf offset:0 atIndex:0];
            [e setFragmentBuffer:buf offset:0 atIndex:0];
        }
        [e setVertexBytes:&view length:sizeof view atIndex:1];
        [e setFragmentBytes:&view length:sizeof view atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:n];
        if (buf)
            [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
                (void)buf;
            }];
    }
    [e endEncoding];
    return true;
}

}
