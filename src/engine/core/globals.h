// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <string_view>

#include "engine/vm/interp.h"

namespace rx::engine::core {

struct Impl;

namespace globals {

enum class Delegate : uint8_t { notice, window, activity, count_ };

bool install(Impl& d) noexcept;
vm::Value ask(Impl& d, Delegate which, vm::Value arg) noexcept;

uint32_t method_count() noexcept;
void method_at(uint32_t i, const char*& global, const char*& name, uint32_t& length) noexcept;

Impl& of(vm::Vm& vm) noexcept;
vm::Rt& rt(Impl& d) noexcept;
vm::Vm& vm(Impl& d) noexcept;
vm::Str* atom(Impl& d, std::string_view ascii) noexcept;
vm::Value api(Impl& d, std::string_view name, const vm::Value* args, uint32_t argc) noexcept;
void log(Impl& d, vm::Str* text, std::string_view level) noexcept;
bool define(Impl& d, vm::Value o, vm::Str* key, vm::Value v) noexcept;
vm::Value& delegate(Impl& d, Delegate which) noexcept;

}
}
