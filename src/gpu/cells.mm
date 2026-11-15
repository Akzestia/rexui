// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "gpu/cells.h"
#include <CoreVideo/CVPixelBuffer.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#include <vector>
#include "gpu/gpu.h"

namespace rx::gpu {
namespace {

const char* k_source = R"msl(
#include <metal_stdlib>
using namespace metal;
struct Cell { float4 rect, uv, color; };
struct Out { float4 pos [[position]]; uint i [[flat]]; };
vertex Out cells_vertex(uint v [[vertex_id]], uint i [[instance_id]], const device Cell *cells [[buffer(0)]],
                        constant float2 &view [[buffer(1)]]) {
    Cell c = cells[i];
    float2 p = float2((v & 1) ? c.rect.x + c.rect.z : c.rect.x, (v & 2) ? c.rect.y + c.rect.w : c.rect.y);
    Out o;
    o.pos = float4(p.x / view.x * 2 - 1, 1 - p.y / view.y * 2, 0, 1);
    o.i = i;
    return o;
}
fragment float4 cells_fragment(Out in [[stage_in]], const device Cell *cells [[buffer(0)]], texture2d<float> atlas [[texture(0)]]) {
    Cell c = cells[in.i];
    if (c.uv.z == 0) return float4(c.color.rgb * c.color.a, c.color.a);
    uint2 at = uint2(c.uv.xy + floor(in.pos.xy - c.rect.xy));
    float4 s = atlas.read(at);
    if (c.uv.z < 0) return s * c.color.a;
    float a = s.a * c.color.a;
    return float4(c.color.rgb * a, a);
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
    d.vertexFunction = [lib newFunctionWithName:@"cells_vertex"];
    d.fragmentFunction = [lib newFunctionWithName:@"cells_fragment"];
    MTLRenderPipelineColorAttachmentDescriptor* c = d.colorAttachments[0];
    c.pixelFormat = MTLPixelFormatBGRA8Unorm;
    c.blendingEnabled = YES;
    c.sourceRGBBlendFactor = c.sourceAlphaBlendFactor = MTLBlendFactorOne;
    c.destinationRGBBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    if (lib && d.vertexFunction && d.fragmentFunction)
        g_pipeline = [device() newRenderPipelineStateWithDescriptor:d error:&e];
    if (!g_pipeline) {
        g_failed = true;
        fprintf(stderr, "rexui cells: no pipeline: %s\n", e.localizedDescription.UTF8String);
    }
    return g_pipeline;
}

id<MTLTexture> make_texture(int side) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:NSUInteger(side)
                                                                                height:NSUInteger(side)
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    return [device() newTextureWithDescriptor:d];
}

constexpr int k_first_side = 512, k_most_side = 4096;

}

bool Atlas::grow() {
    const int side = side_ ? side_ * 2 : k_first_side;
    if (side > k_most_side)
        return false;
    id<MTLTexture> t = make_texture(side);
    if (!t)
        return false;
    if (tex_) {
        id<MTLCommandBuffer> cb = [queue() commandBuffer];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:tex_
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(NSUInteger(side_), NSUInteger(side_), 1)
                    toTexture:t
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [b endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
    }
    if (side_)
        shelf_y_ = side_, shelf_h_ = 0, x_ = 0;
    tex_ = t;
    side_ = side;
    return true;
}

bool Atlas::place(int w, int h, int* x, int* y) {
    if (w <= 0 || h <= 0 || w > k_most_side || h > k_most_side)
        return false;
    if (!tex_ && !grow())
        return false;
    for (;;) {
        if (x_ + w > side_)
            shelf_y_ += shelf_h_, shelf_h_ = 0, x_ = 0;
        if (shelf_y_ + h <= side_ && x_ + w <= side_)
            break;
        if (!grow())
            return false;
    }
    *x = x_, *y = shelf_y_;
    x_ += w + 1;
    if (h + 1 > shelf_h_)
        shelf_h_ = h + 1;
    return true;
}

void Atlas::upload(int x, int y, int w, int h, const void* bgra, std::size_t row_bytes) {
    if (!tex_)
        return;
    [tex_ replaceRegion:MTLRegionMake2D(NSUInteger(x), NSUInteger(y), NSUInteger(w), NSUInteger(h))
            mipmapLevel:0
              withBytes:bgra
            bytesPerRow:row_bytes];
}

id<MTLTexture> Atlas::texture() {
    if (!tex_)
        grow();
    return tex_;
}

bool cells_encode(id<MTLCommandBuffer> cb, id<MTLTexture> target, const CellSet& set) {
    id<MTLRenderPipelineState> p = pipeline();
    if (!p || !target)
        return false;
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:pass];
    if (set.n && set.buffer && set.atlas) {
        const simd_float2 view = {float(target.width), float(target.height)};
        [e setRenderPipelineState:p];
        [e setVertexBuffer:set.buffer offset:0 atIndex:0];
        [e setFragmentBuffer:set.buffer offset:0 atIndex:0];
        [e setVertexBytes:&view length:sizeof view atIndex:1];
        [e setFragmentTexture:set.atlas atIndex:0];
        [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:set.n];
    }
    [e endEncoding];
    return true;
}

namespace {
struct Kept {
    Surface s;
    int w = 0, h = 0;
    double since = 0;
};
std::vector<Kept> g_kept;

double now_s() {
    return CACurrentMediaTime();
}
}

Surface cells_surface(int width, int height) {
    for (std::size_t i = 0; i < g_kept.size(); i++) {
        Kept& k = g_kept[i];
        if (k.w != width || k.h != height || IOSurfaceIsInUse(k.s.surface))
            continue;
        Surface s = k.s;
        g_kept.erase(g_kept.begin() + std::ptrdiff_t(i));
        return s;
    }
    Surface s;
    NSDictionary* props = @{
        (id)kIOSurfaceWidth: @(width),
        (id)kIOSurfaceHeight: @(height),
        (id)kIOSurfaceBytesPerElement: @4,
        (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA)
    };
    s.surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!s.surface)
        return s;
    static const CFPropertyListRef srgb = [] {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CFPropertyListRef p = cs ? CGColorSpaceCopyPropertyList(cs) : nullptr;
        CGColorSpaceRelease(cs);
        return p;
    }();
    if (srgb)
        IOSurfaceSetValue(s.surface, kIOSurfaceColorSpace, srgb);
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:NSUInteger(width)
                                                                                height:NSUInteger(height)
                                                                             mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    s.texture = [device() newTextureWithDescriptor:d iosurface:s.surface plane:0];
    if (!s.texture)
        CFRelease(s.surface), s.surface = nullptr;
    return s;
}

void cells_surface_done(Surface& s) {
    if (!s.surface)
        return;
    g_kept.push_back({s, int(IOSurfaceGetWidth(s.surface)), int(IOSurfaceGetHeight(s.surface)), now_s()});
    s = Surface{};
}

std::size_t cells_surfaces_trim(double now) {
    std::size_t bytes = 0;
    std::erase_if(g_kept, [&](Kept& k) {
        if (now - k.since < 3 || IOSurfaceIsInUse(k.s.surface)) {
            bytes += IOSurfaceGetAllocSize(k.s.surface);
            return false;
        }
        CFRelease(k.s.surface);
        return true;
    });
    return bytes;
}

}
