// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <array>
#include <cmath>
#include <cstdint>

namespace rx::term {

inline double srgb_linear(uint32_t v) {
    static const std::array<double, 256> table = [] {
        std::array<double, 256> t{};
        for (int i = 0; i < 256; i++) {
            const double c = i / 255.0;
            t[size_t(i)] = c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
        }
        return t;
    }();
    return table[v & 0xFF];
}

inline double luminance(uint32_t rgb) {
    return 0.2126 * srgb_linear(rgb >> 16) + 0.7152 * srgb_linear(rgb >> 8) + 0.0722 * srgb_linear(rgb);
}

inline double contrast_ratio(double a, double b) {
    return ((a > b ? a : b) + 0.05) / ((a > b ? b : a) + 0.05);
}

inline bool contrast_exempt(char32_t cp) {
    static constexpr char32_t ranges[][2] = {
        {0xE0B0, 0xE0D7},   {0x1CC00, 0x1CEBF}, {0x1FB00, 0x1FBFF}, {0x2500, 0x25FF},   {0x2800, 0x28FF},
        {0x2300, 0x23FF},   {0x1F900, 0x1FAFF}, {0xE000, 0xF8FF},   {0xF0000, 0xFFFFD}, {0x100000, 0x10FFFD},
        {0x2190, 0x21FF},   {0x2700, 0x27BF},   {0x1F600, 0x1F64F}, {0x2460, 0x24FF},   {0x1F300, 0x1F5FF},
        {0x1F100, 0x1F1FF}, {0x2600, 0x26FF},   {0x1F680, 0x1F6FF},
    };
    for (const auto& r : ranges)
        if (cp >= r[0] && cp <= r[1])
            return true;
    return false;
}

inline uint32_t contrast_toward(uint32_t fg, double lb, double min, bool up) {
    const double r = (fg >> 16) & 0xFF, g = (fg >> 8) & 0xFF, b = fg & 0xFF, to = up ? 255 : 0;
    uint32_t best = up ? 0xFFFFFF : 0;
    double lo = 0, hi = 1;
    for (int i = 0; i < 12; i++) {
        const double t = (lo + hi) / 2;
        const uint32_t c = uint32_t(std::round((to - r) * t + r)) << 16 | uint32_t(std::round((to - g) * t + g)) << 8
            | uint32_t(std::round((to - b) * t + b));
        if (contrast_ratio(luminance(c), lb) < min) {
            lo = t;
        } else {
            best = c, hi = t;
        }
    }
    return best;
}

inline uint32_t contrasted(uint32_t fg, uint32_t bg, double min) {
    if (min <= 1)
        return fg;
    const double lb = luminance(bg);
    if (contrast_ratio(luminance(fg), lb) >= min)
        return fg;
    const double dark_best = (lb + 0.05) / 0.05, light_best = 1.05 / (lb + 0.05);
    if (dark_best < min && light_best < min)
        return dark_best < light_best ? 0xFFFFFF : 0;
    if (dark_best < min)
        return contrast_toward(fg, lb, min, true);
    const uint32_t dark = contrast_toward(fg, lb, min, false);
    if (light_best < min)
        return dark;
    const uint32_t light = contrast_toward(fg, lb, min, true);
    auto dist = [&](uint32_t c) {
        int64_t s = 0;
        for (int k : {16, 8, 0}) {
            const int64_t d = int64_t((c >> k) & 0xFF) - int64_t((fg >> k) & 0xFF);
            s += d * d;
        }
        return s;
    };
    return dist(dark) <= dist(light) ? dark : light;
}

inline uint32_t text_colour(uint32_t fg, uint32_t bg, bool dim, char32_t cp, double min) {
    if (dim) {
        auto half = [&](int s) {
            const double f = (fg >> s) & 0xFF, b = (bg >> s) & 0xFF;
            return uint32_t(std::round((b - f) * 0.5 + f)) << s;
        };
        fg = half(16) | half(8) | half(0);
    }
    return contrast_exempt(cp) ? fg : contrasted(fg, bg, min);
}

}
