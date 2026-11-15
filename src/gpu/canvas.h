// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#import <Metal/Metal.h>
#include <simd/simd.h>

#include <cstdint>

namespace rx::gpu {

enum class Kind : std::uint32_t {
    rect = 0,
    capsule = 1,
    arc = 2,
    cookie = 3,
};

struct Shape {
    simd_float4 geo, more, wave, color;
    Kind kind() const { return static_cast<Kind>(static_cast<std::uint32_t>(more.w)); }
};
static_assert(sizeof(Shape) == 64);

inline Shape rect(float x, float y, float w, float h, float radius, simd_float4 c) {
    return {{x, y, w, h}, {radius, 0, 0, (float)Kind::rect}, {}, c};
}
inline Shape capsule(float x0, float y0, float x1, float y1, float radius, simd_float4 c) {
    return {{x0, y0, x1, y1}, {radius, 0, 0, (float)Kind::capsule}, {}, c};
}
inline Shape arc(float cx, float cy, float r, float thickness, float start, float sweep, simd_float4 c, float amp = 0,
                 float frequency = 0, float phase = 0) {
    return {{cx, cy, r, thickness / 2}, {start, sweep, 0, (float)Kind::arc}, {amp, frequency, phase, 0}, c};
}

inline Shape cookie(float cx, float cy, float r, float turn, float scallops, simd_float4 c) {
    return {{cx, cy, r, turn}, {scallops, 0, 0, (float)Kind::cookie}, {}, c};
}

bool canvas_encode(id<MTLCommandBuffer> cb, id<MTLTexture> target, const Shape* shapes, std::uint32_t n, float scale,
                   bool clear);

}
