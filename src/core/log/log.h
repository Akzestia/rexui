// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>

namespace rx::log {

inline constexpr std::size_t k_text = 240;
inline constexpr std::size_t k_ring = 512;

enum Level : std::uint8_t { info = 0, warn = 1, error = 2 };

struct Record {
    std::uint64_t ns;
    std::uint8_t level;
    std::uint8_t flags;
    std::uint16_t len;
    std::uint32_t pad;
    char text[k_text];
};
static_assert(sizeof(Record) == 256);
inline constexpr std::uint8_t k_more = 1;

void start(const char* path, std::uint64_t rotate_bytes = 4u << 20);
bool write(std::string_view line, Level level = info);
void flush(int timeout_ms = 500);
std::uint64_t dropped();
void stop();

}
