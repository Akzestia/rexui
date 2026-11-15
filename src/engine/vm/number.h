// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace rx::engine::num {

inline constexpr size_t k_max_chars = 32;

size_t to_string(double x, char16_t* out) noexcept;
size_t to_string_radix(double x, int radix, char16_t* out) noexcept;
double from_string(std::u16string_view s) noexcept;

int32_t to_int32(double x) noexcept;
inline uint32_t to_uint32(double x) noexcept {
    return static_cast<uint32_t>(to_int32(x));
}

}
