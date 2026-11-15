// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <expected>
#include <string_view>

#include "engine/base/arena.h"
#include "engine/syntax/js.h"
#include "engine/vm/code.h"
#include "engine/vm/runtime.h"

namespace rx::engine::vm {

struct CompileError {
    uint32_t pos;
    std::string_view msg;
};

std::expected<const Code*, CompileError> compile(const js::Node* unit, js::Goal goal, std::string_view file, Rt& rt,
                                                 const std::string_view* params = nullptr, uint32_t n_params = 0,
                                                 Arena* scratch = nullptr) noexcept;
std::expected<const Code*, CompileError> compile_function(const js::Node* func, std::string_view file, Rt& rt,
                                                          Arena* scratch = nullptr) noexcept;

}
