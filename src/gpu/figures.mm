// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "gpu/figures.h"

#include <algorithm>
#include <cmath>

namespace rx::gpu {

static double turn_at(const VisState& s, double now) {
    return s.spin_period <= 0 ? s.spin_base : s.spin_base - 2 * M_PI * (now - s.spin_t0) / s.spin_period;
}

std::uint32_t arc_figure(const ArcState& s, double shown, double phase01, Shape* out) {
    uint32_t n = 0;
    const double stroke = s.stroke, amp = s.wavy ? 0.5 : 0, gap = s.gap;
    const double value = std::max(1.0 / 360, std::min(1.0, shown)), phase = phase01 * 2 * M_PI;
    const double cx = s.w / 2, cy = s.h / 2;
    simd_float4 bg = s.bg, fg = s.fg;
    if (s.line) {
        const double x0 = stroke / 2, len = std::max(1.0, s.w - stroke), g = gap + stroke;
        const double to = x0 + value * len, from = std::min(x0 + len, to + g), amplitude = stroke * amp;
        const double rest = std::max(0.0, x0 + len - from), fade = std::min(1.0, rest);
        bg.w *= (float)fade;
        if (rest > 0)
            out[n++] = capsule((float)from, (float)cy, (float)(x0 + len), (float)cy, (float)(fade * stroke / 2), bg);
        if (amplitude <= 0) {
            out[n++] = capsule((float)x0, (float)cy, (float)to, (float)cy, (float)(stroke / 2), fg);
        } else {
            const int segments = 48;
            double px = x0, py = cy + amplitude * sin(phase);
            for (int i = 1; i <= segments; i++) {
                const double x = x0 + (to - x0) * i / segments,
                             y = cy + amplitude * sin(s.waves * 2 * M_PI * (x - x0) / len + phase);
                out[n++] = capsule((float)px, (float)py, (float)x, (float)y, (float)(stroke / 2), fg);
                px = x, py = y;
            }
        }
        if (s.dot) {
            const double d = fade * std::min(4.0, stroke);
            simd_float4 c = fg;
            c.w *= (float)fade;
            out[n++] = capsule((float)(x0 + len), (float)cy, (float)(x0 + len), (float)cy, (float)(d / 2), c);
        }
        return n;
    }
    const double side = std::min(s.w, s.h), radius = std::max(1.0, (side - stroke * (1 + amp * 2)) / 2);
    auto rad = [](double deg) { return deg * M_PI / 180; };
    const double gapAngle = (gap + stroke) / radius * 180 / M_PI;
    const double rest = std::max(1.0 / 360, s.sweep * (1 - value) - gapAngle * (s.sweep < 360 ? 1 : 2));
    const double fade = std::min(1.0, rest);
    bg.w *= (float)fade;
    out[n++] = arc((float)cx, (float)cy, (float)radius, (float)(fade * stroke),
                   (float)rad(s.start + value * s.sweep + gapAngle), (float)rad(rest), bg);
    const double full = rad(s.sweep);
    out[n++] = arc((float)cx, (float)cy, (float)radius, (float)stroke, (float)rad(s.start), (float)(full * value), fg,
                   (float)(stroke * amp), (float)(s.waves * 2 * M_PI / std::max(1e-6, full)), (float)phase);
    if (s.dot) {
        const double a = rad(s.start + s.sweep - gapAngle * (s.sweep < 360 ? 0 : 1)), d = fade * std::min(4.0, stroke);
        simd_float4 c = fg;
        c.w *= (float)fade;
        const float x = (float)(cx + radius * cos(a)), y = (float)(cy + radius * sin(a));
        out[n++] = capsule(x, y, x, y, (float)(d / 2), c);
    }
    return n;
}

std::uint32_t bars_figure(const VisState& s, const float* frame, std::uint32_t have, double now, Shape* out,
                          std::uint32_t cap) {
    const uint32_t count = std::min(cap, have ? have : s.count);
    const double side = std::min(s.w, s.h),
                 width = s.width_set ? s.width : std::max(1.0, 360.0 / std::max<uint32_t>(1, count) - 2);
    const double reach = std::max(0.0, (side - s.cover) / 2 - s.gap), turn = turn_at(s, now);
    const double cx = s.w / 2, cy = s.h / 2;
    for (uint32_t i = 0; i < count; i++) {
        double value = frame ? (i < have ? frame[i] : 0) : 0;
        if (std::isnan(value))
            value = 0;
        value = std::max(1e-2, std::min(1.0, value));
        const double a = 2 * M_PI * i / count;
        double edge = s.cover / 2;
        if (s.scallops) {
            const double depth = std::min(0.3, 1.2 / s.scallops);
            edge *= 1 - depth * (1 - cos(s.scallops * (a - turn + M_PI / 2))) / 2;
        }
        const double from = edge + s.gap + width / 2, to = from + value * reach;
        out[i] = capsule((float)(cx + from * cos(a)), (float)(cy + from * sin(a)), (float)(cx + to * cos(a)),
                         (float)(cy + to * sin(a)), (float)(width / 2), s.color);
    }
    return count;
}

std::uint32_t graph_figure(const GraphState& s, const float* values, std::uint32_t n, Shape* out, std::uint32_t cap) {
    if (!n || s.w < 1 || s.h < 1 || !cap)
        return 0;
    float lo = s.lo, hi = s.hi;
    if (!s.fixed) {
        lo = 0, hi = 0;
        for (std::uint32_t i = 0; i < n; i++)
            if (std::isfinite(values[i]))
                lo = std::min(lo, values[i]), hi = std::max(hi, values[i]);
    }
    if (hi <= lo)
        hi = lo + 1;
    const float pad = s.style == GraphState::line ? s.thickness / 2 : 0;
    const float top = pad, span = s.h - 2 * pad;
    auto y_of = [&](float v) {
        if (!std::isfinite(v))
            v = lo;
        const float t = std::clamp((v - lo) / (hi - lo), 0.0f, 1.0f);
        return top + span * (1 - t);
    };
    std::uint32_t k = 0;
    if (s.style == GraphState::bars) {
        const float slot = s.w / n, bw = std::max(0.5f, slot - s.gap);
        for (std::uint32_t i = 0; i < n && k < cap; i++) {
            const float y = y_of(values[i]);
            out[k++] = rect(i * slot + (slot - bw) / 2, y, bw, s.h - y, std::min(bw / 2, 2.0f), s.color);
        }
        return k;
    }
    const float step = n > 1 ? (s.w - 2 * pad) / (n - 1) : 0;
    if (s.style == GraphState::area) {
        simd_float4 fill = s.color;
        fill.w *= 0.25f;
        const float cw = n > 1 ? step : s.w;
        for (std::uint32_t i = 0; i < n && k < cap; i++) {
            const float y = y_of(values[i]), x0 = std::max(0.0f, pad + i * step - cw / 2),
                        x1 = std::min(s.w, pad + i * step + cw / 2);
            out[k++] = rect(x0, y, x1 - x0, s.h - y, 0, fill);
        }
    }
    if (n == 1) {
        if (k < cap)
            out[k++] = capsule(pad, y_of(values[0]), s.w - pad, y_of(values[0]), s.thickness / 2, s.color);
        return k;
    }
    for (std::uint32_t i = 1; i < n && k < cap; i++)
        out[k++] = capsule(pad + (i - 1) * step, y_of(values[i - 1]), pad + i * step, y_of(values[i]), s.thickness / 2,
                           s.color);
    return k;
}

}
