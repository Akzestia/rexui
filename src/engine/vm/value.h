// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <cstring>
#include <string_view>

namespace rx::engine::vm {

enum class Kind : uint8_t {
    string,
    array,
    object,
    function,
    native,
    date,
    set,
    regexp,
    iterator,
    env,
    promise,
    element,
    group
};

struct Cell {
    uint32_t refs;
    Kind kind;
    uint8_t space;
    uint16_t flags;
};

class Value {
  public:
    static constexpr uint64_t k_special = 0xFFF9000000000000ull;
    static constexpr uint64_t k_cell = 0xFFFC000000000000ull;
    static constexpr uint64_t k_nan = 0x7FF8000000000000ull;
    static constexpr uint64_t k_tag_mask = 0xFFFF000000000000ull;

    constexpr Value() : bits_(k_special) {}
    static Value num(double d) {
        uint64_t b;
        std::memcpy(&b, &d, 8);
        if (d != d)
            b = k_nan;
        return Value(b);
    }
    static constexpr Value undefined() { return Value(k_special); }
    static constexpr Value null() { return Value(k_special | 1); }
    static constexpr Value boolean(bool b) { return Value(k_special | (b ? 3 : 2)); }
    static constexpr Value hole() { return Value(k_special | 4); }
    static Value cell(const Cell* c) { return Value(k_cell | reinterpret_cast<uint64_t>(c)); }

    bool is_num() const { return bits_ < k_special; }
    bool is_undefined() const { return bits_ == k_special; }
    bool is_null() const { return bits_ == (k_special | 1); }
    bool is_nullish() const { return bits_ == k_special || bits_ == (k_special | 1); }
    bool is_bool() const { return bits_ == (k_special | 2) || bits_ == (k_special | 3); }
    bool is_true() const { return bits_ == (k_special | 3); }
    bool is_hole() const { return bits_ == (k_special | 4); }
    bool is_cell() const { return (bits_ & k_tag_mask) == k_cell; }
    bool is(Kind k) const { return is_cell() && as_cell()->kind == k; }

    double as_num() const {
        double d;
        std::memcpy(&d, &bits_, 8);
        return d;
    }
    Cell* as_cell() const { return reinterpret_cast<Cell*>(bits_ & ~k_tag_mask); }
    template<class T>
    T* as() const {
        return reinterpret_cast<T*>(as_cell());
    }
    uint64_t bits() const { return bits_; }
    bool same_bits(Value o) const { return bits_ == o.bits_; }

  private:
    explicit constexpr Value(uint64_t b) : bits_(b) {}
    uint64_t bits_;
};
static_assert(sizeof(Value) == 8);

struct Str {
    Cell h;
    uint32_t length;
    uint32_t hash;
    bool ascii;
    char16_t units[1];

    std::u16string_view view() const { return {units, length}; }
    uint32_t hashed() {
        if (!hash) {
            uint32_t x = 2166136261u;
            for (uint32_t i = 0; i < length; i++)
                x = (x ^ units[i]) * 16777619u;
            hash = x | 1;
        }
        return hash;
    }
};

struct Obj;
struct Arr {
    Cell h;
    uint32_t length, cap;
    Value* items;
    Obj* props;
};

struct Shape {
    const Shape* parent;
    Str* key;
    uint32_t slot;
    uint32_t count;
    struct Edge {
        Str* key;
        Shape* to;
    };
    Edge* edges;
    uint32_t n_edges, cap_edges;
};

struct Obj {
    Cell h;
    const Shape* shape;
    uint32_t cap;
    Value* slots;
    Obj* proto;
};

struct Code;
struct Env;
class Host;

struct Fn {
    Cell h;
    const Code* code;
    Env* env;
    Host* host;
};

class Vm;
using NativeFn = Value (*)(Vm& vm, Value self, const Value* args, uint32_t argc);
struct Native {
    Cell h;
    NativeFn fn;
    NativeFn construct;
    Str* name;
    uint32_t length;
    struct Obj* props;
};

}
