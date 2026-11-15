// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <string_view>

namespace rx::io {

inline constexpr std::uint32_t k_max = 256;
inline constexpr std::uint32_t k_line = 1u << 20;
inline constexpr std::uint32_t k_events = 1u << 22;
inline constexpr std::uint32_t k_stdin = 1u << 18;

enum class Kind : std::uint8_t { out, err, exit, hello, reply };

struct Event {
    std::uint32_t id;
    Kind kind;
    std::int32_t code;
    std::string_view text;
};

struct Spawn {
    const char* path;
    char* const* argv;
    char* const* envp;
    const char* cwd;
};

bool start(void (*wake)(void*), void* ctx) noexcept;

std::expected<std::uint32_t, int> spawn(const Spawn& s, std::int32_t* pid) noexcept;
bool send(std::uint32_t id, std::string_view line) noexcept;
bool call(std::uint32_t id, std::uint64_t seq, std::string_view json) noexcept;
void stop(std::uint32_t id) noexcept;
void release(std::uint32_t id) noexcept;

std::size_t drain(void (*f)(void*, const Event&), void* ctx) noexcept;
bool pending() noexcept;
void main_sleeping() noexcept;
void main_awake() noexcept;
void stop_all() noexcept;

}
