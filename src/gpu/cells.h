// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once
#include <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#include <simd/simd.h>

#include <cstddef>
#include <cstdint>

namespace rx::gpu {

struct Cell {
    simd_float4 rect, uv, color;
};
static_assert(sizeof(Cell) == 48);

class Atlas {
  public:
    bool place(int w, int h, int* x, int* y);
    void upload(int x, int y, int w, int h, const void* bgra, std::size_t row_bytes);
    id<MTLTexture> texture();
    std::size_t bytes() const { return std::size_t(side_) * std::size_t(side_) * 4; }

  private:
    bool grow();
    id<MTLTexture> tex_;
    int side_ = 0, shelf_y_ = 0, shelf_h_ = 0, x_ = 0;
};

struct CellSet {
    id<MTLBuffer> buffer;
    id<MTLTexture> atlas;
    std::uint32_t n = 0;
    int width = 0, height = 0;
};

bool cells_encode(id<MTLCommandBuffer> cb, id<MTLTexture> target, const CellSet& set);

struct Surface {
    IOSurfaceRef surface = nullptr;
    id<MTLTexture> texture;
};
Surface cells_surface(int width, int height);
void cells_surface_done(Surface& s);
std::size_t cells_surfaces_trim(double now);

}
