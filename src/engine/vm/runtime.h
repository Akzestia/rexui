// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <string_view>

#include "engine/base/arena.h"
#include "engine/vm/value.h"

namespace rx::engine::vm {

class Vm;
struct Job;
class Rt;

struct ObjHooks {
    Value (*get)(Rt& rt, Value obj, Str* key) noexcept;
    bool (*set)(Rt& rt, Value obj, Str* key, Value v) noexcept;
    Arr* (*keys)(Rt& rt, Value obj) noexcept;
};

enum class ErrorKind : uint8_t { none, type, range, reference, syntax, uri, internal };

class Rt {
  public:
    explicit Rt(Arena& arena, Arena* perm = nullptr) noexcept;

    Arena& arena;
    Arena& perm;

    Str* str(std::u16string_view s) noexcept;
    Str* str_ascii(std::string_view s) noexcept;
    Str* str_utf8(std::string_view s) noexcept;
    Str* concat(Str* a, Str* b) noexcept;
    Str* concat_all(Str* const* parts, uint32_t n, Str* sep) noexcept;
    Str* atom(std::u16string_view s) noexcept;
    Str* atom(Str* s) noexcept;
    Str* empty;

    Str *a_length, *a_undefined, *a_null, *a_true, *a_false, *a_object, *a_number, *a_string, *a_boolean, *a_function,
        *a_nan, *a_comma, *a_object_object, *a_value_of, *a_to_string;

    Arr* array(uint32_t cap) noexcept;
    bool push(Arr* a, Value v) noexcept;
    bool set_length(Arr* a, uint32_t n) noexcept;
    Obj* object() noexcept;
    Value get_own(const Obj* o, Str* key) const noexcept;
    bool put(Obj* o, Str* key, Value v) noexcept;
    bool remove(Obj* o, Str* key) noexcept;
    const Shape* empty_shape() const { return root_; }

    Obj *string_proto = nullptr, *number_proto = nullptr, *boolean_proto = nullptr, *array_proto = nullptr,
        *object_proto = nullptr, *function_proto = nullptr, *date_proto = nullptr, *map_proto = nullptr,
        *set_proto = nullptr, *regexp_proto = nullptr, *promise_proto = nullptr, *error_proto = nullptr;
    Obj* globals = nullptr;
    Vm* vm = nullptr;
    Native *date_ctor = nullptr, *set_ctor = nullptr, *map_ctor = nullptr;
    const ObjHooks* hooks = nullptr;
    double test_now = -1;
    double test_seed = 0;
    double (*clock)(void* ctx) = nullptr;
    void* clock_ctx = nullptr;
    double now() const noexcept;
    void* user = nullptr;
    struct RegexCache {
        const Str *pattern, *flags;
        void* compiled;
        Str* error;
    };
    List<RegexCache> regexes;
    List<Job*> jobs;
    Native* native(const char* name, NativeFn fn, uint32_t length, NativeFn construct = nullptr) noexcept;

    bool failed = false;
    ErrorKind error = ErrorKind::none;
    Value thrown;
    Value fail(ErrorKind k, const char* fmt, ...) noexcept __attribute__((format(printf, 3, 4)));
    void clear() noexcept { failed = false, error = ErrorKind::none, thrown = Value::undefined(); }
    Str* message = nullptr;

    void gc_roots(class Gc& gc) noexcept;
    Shape* root_shape() const { return root_; }

  private:
    Shape* root_;
    Str** atoms_ = nullptr;
    uint32_t atom_cap_ = 0, atom_count_ = 0;
    bool grow_atoms() noexcept;
    Shape* transition(const Shape* from, Str* key) noexcept;
};

inline Value val(Str* s) {
    return Value::cell(&s->h);
}
inline Value val(Arr* a) {
    return Value::cell(&a->h);
}
inline Value val(Obj* o) {
    return Value::cell(&o->h);
}
inline Value val(Fn* f) {
    return Value::cell(&f->h);
}
inline Value val(Native* f) {
    return Value::cell(&f->h);
}

}
