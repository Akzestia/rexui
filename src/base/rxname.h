// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once
#include <array>
#include <cstddef>
#include <cstdint>

namespace rxname {
template<size_t N>
struct Text {
    std::array<char, N> c{};
};
template<size_t N>
consteval Text<N> plain(const char (&s)[N]) {
    Text<N> t;
    for (size_t i = 0; i < N; i++)
        t.c[i] = s[i];
    return t;
}
template<size_t N>
consteval Text<N> decode(const char (&s)[N]) {
    Text<N> t;
    uint32_t x = 0x2545F491u;
    for (size_t i = 0; i + 1 < N; i++) {
        x ^= x << 13, x ^= x >> 17, x ^= x << 5;
        t.c[i] = static_cast<char>(static_cast<uint8_t>(s[i]) ^ static_cast<uint8_t>(x));
    }
    t.c[N - 1] = 0;
    return t;
}
}

#define RX_NAME(s)                                     \
    ([]() -> const char* {                             \
        static constexpr auto t_ = ::rxname::plain(s); \
        return t_.c.data();                            \
    }())
#define RX_NAME_X(s)                                    \
    ([]() -> const char* {                              \
        static constexpr auto t_ = ::rxname::decode(s); \
        return t_.c.data();                             \
    }())
#ifdef __OBJC__
#if __has_include("gen/rx_names.h")
#include "gen/rx_names.h"
#endif
#endif
