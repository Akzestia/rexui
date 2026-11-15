// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace rx::io::proto {

enum : std::uint32_t { k_patch = 1, k_call = 2, k_credit = 4 };
inline constexpr std::uint32_t k_supported = k_patch | k_call | k_credit;

bool hello(std::string_view line, std::uint32_t* features) noexcept;
std::size_t answer(std::uint32_t features, std::uint32_t credit, std::span<char> out) noexcept;
std::size_t patch_line(std::span<const std::uint8_t> payload, std::span<char> out) noexcept;

}
