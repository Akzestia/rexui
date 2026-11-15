// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace rx::engine::utf {

struct Cp {
    char32_t cp;
    uint32_t len;
};
inline Cp decode(std::string_view s, size_t i) noexcept {
    auto b = [&](size_t k) -> uint32_t { return i + k < s.size() ? static_cast<uint8_t>(s[i + k]) : 0x100; };
    uint32_t c = b(0);
    if (c < 0x80)
        return {c, 1};
    auto cont = [&](size_t k) { return (b(k) & 0xC0) == 0x80; };
    if (c >= 0xC2 && c <= 0xDF && cont(1))
        return {((c & 0x1F) << 6) | (b(1) & 0x3F), 2};
    if (c >= 0xE0 && c <= 0xEF && cont(1) && cont(2)) {
        char32_t v = ((c & 0x0F) << 12) | ((b(1) & 0x3F) << 6) | (b(2) & 0x3F);
        if (v < 0x800 || (v >= 0xD800 && v <= 0xDFFF))
            return {0, 0};
        return {v, 3};
    }
    if (c >= 0xF0 && c <= 0xF4 && cont(1) && cont(2) && cont(3)) {
        char32_t v = ((c & 0x07) << 18) | ((b(1) & 0x3F) << 12) | ((b(2) & 0x3F) << 6) | (b(3) & 0x3F);
        if (v < 0x10000 || v > 0x10FFFF)
            return {0, 0};
        return {v, 4};
    }
    return {0, 0};
}

inline size_t invalid_at(std::string_view s) noexcept {
    for (size_t i = 0; i < s.size();) {
        if (static_cast<uint8_t>(s[i]) < 0x80) {
            i++;
            continue;
        }
        Cp c = decode(s, i);
        if (!c.len)
            return i;
        i += c.len;
    }
    return s.size();
}

inline bool js_space(char32_t c) noexcept {
    switch (c) {
    case 0x09:
    case 0x0A:
    case 0x0B:
    case 0x0C:
    case 0x0D:
    case 0x20:
    case 0xA0:
    case 0x1680:
    case 0x2028:
    case 0x2029:
    case 0x202F:
    case 0x205F:
    case 0x3000:
    case 0xFEFF:
        return true;
    default:
        return c >= 0x2000 && c <= 0x200A;
    }
}

inline size_t space_before(std::string_view s, size_t end) noexcept {
    if (end == 0)
        return end;
    size_t k = end - 1;
    while (k > 0 && (static_cast<uint8_t>(s[k]) & 0xC0) == 0x80 && end - k < 4)
        k--;
    Cp c = decode(s, k);
    return c.len && k + c.len == end && js_space(c.cp) ? k : end;
}

inline std::string_view trim_end(std::string_view s) noexcept {
    size_t e = s.size();
    for (size_t k; (k = space_before(s, e)) != e;)
        e = k;
    return s.substr(0, e);
}
inline std::string_view trim(std::string_view s) noexcept {
    size_t b = 0;
    while (b < s.size()) {
        Cp c = decode(s, b);
        if (!c.len || !js_space(c.cp))
            break;
        b += c.len;
    }
    return trim_end(s.substr(b));
}

inline size_t utf16_len(std::string_view s) noexcept {
    size_t n = 0;
    for (size_t i = 0; i < s.size();) {
        uint8_t c = static_cast<uint8_t>(s[i]);
        if (c < 0x80) {
            i++, n++;
            continue;
        }
        Cp d = decode(s, i);
        if (!d.len) {
            i++, n++;
            continue;
        }
        i += d.len;
        n += d.cp >= 0x10000 ? 2 : 1;
    }
    return n;
}

}
