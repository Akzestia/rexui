// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include "engine/vm/interp.h"
#include "engine/vm/number.h"
#include "engine/vm/ops.h"

namespace rx::engine::vm::lib {

bool install(Rt& rt) noexcept;

using MissFn = void (*)(const char16_t* text, size_t n) noexcept;
extern MissFn qstr_miss;

double to_integer(Rt& rt, Value v) noexcept;
uint32_t relative(double rel, uint32_t len) noexcept;
bool callable(Value v) noexcept;
Value arg(const Value* args, uint32_t argc, uint32_t i) noexcept;
Value type_error(Rt& rt, const char* what) noexcept;
Str* this_string(Vm& vm, Value self, const char* method) noexcept;
void install_string(Rt& rt, Obj* proto) noexcept;
void install_array(Rt& rt, Obj* proto, Obj* array_ctor) noexcept;
bool def(Rt& rt, Obj* o, const char* name, NativeFn fn, uint32_t length) noexcept;

Str* substitution(Rt& rt, std::u16string_view matched, std::u16string_view str, size_t position, const Value* captures,
                  uint32_t n_captures, std::u16string_view replacement, Value groups = Value::undefined());

Value regex_split(Vm& vm, Str* s, Value re, Value limit) noexcept;
Value regex_replace(Vm& vm, Str* s, Value re, Value replacement, bool all) noexcept;
Value regex_search(Vm& vm, Str* s, Value re) noexcept;
Value regex_match(Vm& vm, Str* s, Value re) noexcept;
Value regex_match_all(Vm& vm, Str* s, Value re) noexcept;
bool regex_global(Value re) noexcept;
void install_regex(Rt& rt, Obj* proto) noexcept;
Value regexp_literal(Rt& rt, Str* pattern, Str* flags) noexcept;

void install_json(Rt& rt) noexcept;
void install_set(Rt& rt) noexcept;
Value set_size(Value set) noexcept;
bool set_step(Rt& rt, Value set, uint32_t& at, Value& out) noexcept;
bool set_is_map(Value set) noexcept;

Value os_case(Rt& rt, Str* s, bool upper) noexcept;
Value os_compare(Rt& rt, Str* a, Str* b, Value locales) noexcept;
size_t os_zone_name(Rt& rt, double utc_ms, char16_t* out, size_t cap) noexcept;
Value os_format_date(Rt& rt, double t, Str* locale, const char* skeleton, int date_style, int time_style,
                     bool two_digit_hour) noexcept;
void install_date(Rt& rt) noexcept;
void install_promise(Rt& rt) noexcept;
Value promise_new(Rt& rt) noexcept;
void promise_settle(Vm& vm, Value promise, Value v, bool rejected) noexcept;
void drain_jobs(Vm& vm) noexcept;
bool is_promise(Value v) noexcept;
bool is_promise_resolver(const Native* n) noexcept;
Value promise_resolver(Vm& vm, Native* n, const Value* args, uint32_t argc) noexcept;
bool is_finally(const Native* n) noexcept;
Value finally_run(Vm& vm, Native* n, const Value* args, uint32_t argc) noexcept;
double date_value(Value d) noexcept;

}
