// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>

#include "gpu/canvas.h"

namespace rx::gpu {

struct ArcState {
    float w = 0, h = 0, scale = 1;
    uint32_t dw = 0, dh = 0;
    float stroke = 6, gap = 8, start = -90, sweep = 360, waves = 8, period = 2;
    float value = 0;
    float from = 0;
    bool wavy = false, waving = true, dot = true, line = false, snap = false;
    simd_float4 fg = {1, 1, 1, 1}, bg = {1, 1, 1, 0.2f};
    uint32_t gen = 0;
};

struct VisState {
    float w = 0, h = 0, scale = 1;
    uint32_t dw = 0, dh = 0;
    uint32_t count = 60, scallops = 0;
    float cover = 0, gap = 12, width = 4;
    bool width_set = false;
    simd_float4 color = {1, 1, 1, 1};
    double spin_base = 0, spin_t0 = 0, spin_period = 0;
    uint32_t gen = 0;
    uint32_t nvalues = 0;
    float values[512];
};

struct GraphState {
    float w = 0, h = 0, scale = 1;
    uint32_t dw = 0, dh = 0;
    enum Style : uint32_t { line = 0, area = 1, bars = 2 } style = line;
    float lo = 0, hi = 0, thickness = 1.5f, gap = 1;
    bool fixed = false;
    simd_float4 color = {1, 1, 1, 1};
    uint32_t gen = 0, n = 0;
    float values[512];
};

std::uint32_t arc_figure(const ArcState& s, double shown, double phase01, Shape* out);
std::uint32_t bars_figure(const VisState& s, const float* frame, std::uint32_t have, double now, Shape* out,
                          std::uint32_t cap);

std::uint32_t graph_figure(const GraphState& s, const float* values, std::uint32_t n, Shape* out, std::uint32_t cap);

}
