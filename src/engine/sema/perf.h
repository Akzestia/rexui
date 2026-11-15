// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <string_view>

#include "engine/base/arena.h"
#include "engine/sema/check.h"
#include "engine/syntax/rui.h"

namespace rx::engine::sema {

inline constexpr uint32_t k_perf_rows = 200;
inline constexpr uint32_t k_perf_drawer = 200;
inline constexpr double k_perf_shader_fps = 30;

List<Diagnostic> perf(const rui::File& file, std::string_view path, std::string_view name, Arena& arena) noexcept;

}
