// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include "engine/vm/runtime.h"

namespace rx::engine::vm {

Value vm_call(Vm& vm, Value fn, Value self, const Value* args, uint32_t argc) noexcept;

bool to_boolean(Value v) noexcept;
double to_number(Rt& rt, Value v) noexcept;
Str* to_string(Rt& rt, Value v) noexcept;
enum class Hint : uint8_t { none, number, string };
Value to_primitive(Rt& rt, Value v, Hint h) noexcept;
Str* type_of(Rt& rt, Value v) noexcept;
Str* to_property_key(Rt& rt, Value v) noexcept;
bool canonical_index(const Str* key, uint32_t& index) noexcept;

bool strict_equals(Value a, Value b) noexcept;
bool loose_equals(Rt& rt, Value a, Value b) noexcept;
bool same_value_zero(Value a, Value b) noexcept;
Value less_than(Rt& rt, Value a, Value b, bool left_first) noexcept;

enum class NumOp : uint8_t { sub, mul, div, mod, exp, shl, shr, ushr, band, bor, bxor };
Value add(Rt& rt, Value a, Value b) noexcept;
Value num_op(Rt& rt, NumOp op, Value a, Value b) noexcept;
double num_op(NumOp op, double a, double b) noexcept;
double js_pow(double a, double b) noexcept;

Value get(Rt& rt, Value obj, Value key) noexcept;
Value get(Rt& rt, Value obj, Str* atom) noexcept;
bool set(Rt& rt, Value obj, Value key, Value value) noexcept;
bool set(Rt& rt, Value obj, Str* atom, Value value) noexcept;

Arr* own_keys(Rt& rt, Value v) noexcept;

Str* join(Rt& rt, Arr* a, Str* sep) noexcept;

}
