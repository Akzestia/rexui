// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <string_view>

#include "engine/base/arena.h"

namespace rx::engine::vm::re {

enum : uint8_t { f_global = 1, f_ignore_case = 2, f_multiline = 4, f_dot_all = 8, f_sticky = 16, f_indices = 32 };

struct Program;

struct Compiled {
    const Program* program;
    uint32_t n_groups;
    const std::u16string_view* names;
};

struct Error {
    std::string_view msg;
};

bool compile(std::u16string_view pattern, uint8_t flags, Arena& arena, Compiled& out, Error& err) noexcept;
bool parse_flags(std::u16string_view text, uint8_t& flags) noexcept;

enum class Result : uint8_t { match, no_match, budget };

Result match(const Compiled& re, std::u16string_view subject, uint32_t start, int32_t* caps, int64_t& steps) noexcept;

char16_t canonicalize(char16_t c) noexcept;

}
