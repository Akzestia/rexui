// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/ops.h"

#include <cmath>

#include "base/analyzer.h"
#include "engine/vm/interp.h"
#include "engine/vm/number.h"

namespace rx::engine::vm {

Value vm_call(Vm& vm, Value fn, Value self, const Value* args, uint32_t argc) noexcept {
    return vm.call(fn, self, args, argc);
}
Value lib_regexp_get(Rt& rt, Value re, Str* key) noexcept;
bool lib_regexp_set(Rt& rt, Value re, Str* key, Value v) noexcept;
namespace lib {
Value set_size(Value set) noexcept;
bool set_is_map(Value set) noexcept;
}
static Value lib_set_size(Value s) noexcept {
    return lib::set_size(s);
}

bool to_boolean(Value v) noexcept {
    if (v.is_num()) {
        double d = v.as_num();
        return d == d && d != 0;
    }
    if (v.is_bool())
        return v.is_true();
    if (v.is_nullish() || v.is_hole())
        return false;
    if (v.is(Kind::string))
        return v.as<Str>()->length != 0;
    return true;
}

Value to_primitive(Rt& rt, Value v, Hint h) noexcept {
    if (!v.is_cell() || v.is(Kind::string))
        return v;
    if (h == Hint::none)
        h = v.is(Kind::date) ? Hint::string : Hint::number;
    if (!rt.vm) {
        if (v.is(Kind::array))
            return val(join(rt, v.as<Arr>(), rt.a_comma));
        return val(rt.a_object_object);
    }
    Str* names[2] = {rt.a_value_of, rt.a_to_string};
    if (h == Hint::string) {
        Str* t = names[0];
        names[0] = names[1], names[1] = t;
    }
    for (Str* name : names) {
        Value f = get(rt, v, name);
        if (rt.failed)
            return Value::undefined();
        if (!(f.is(Kind::function) || f.is(Kind::native)))
            continue;
        Value r = vm_call(*rt.vm, f, v, nullptr, 0);
        if (rt.failed)
            return Value::undefined();
        if (!r.is_cell() || r.is(Kind::string))
            return r;
    }
    return rt.fail(ErrorKind::type, "No default value");
}

double to_number(Rt& rt, Value v) noexcept {
    for (;;) {
        if (v.is_num())
            return v.as_num();
        if (v.is_bool())
            return v.is_true() ? 1 : 0;
        if (v.is_null())
            return 0;
        if (v.is_undefined() || v.is_hole())
            return NAN;
        if (v.is(Kind::string))
            return num::from_string(v.as<Str>()->view());
        v = to_primitive(rt, v, Hint::number);
        if (rt.failed)
            return NAN;
    }
}

Str* to_string(Rt& rt, Value v) noexcept {
    for (;;) {
        if (v.is(Kind::string))
            return v.as<Str>();
        if (v.is_num()) {
            char16_t buf[num::k_max_chars];
            size_t n = num::to_string(v.as_num(), buf);
            return rt.str({buf, n});
        }
        if (v.is_bool())
            return v.is_true() ? rt.a_true : rt.a_false;
        if (v.is_null())
            return rt.a_null;
        if (v.is_undefined() || v.is_hole())
            return rt.a_undefined;
        v = to_primitive(rt, v, Hint::string);
        if (rt.failed)
            return nullptr;
    }
}

Str* type_of(Rt& rt, Value v) noexcept {
    if (v.is_num())
        return rt.a_number;
    if (v.is_bool())
        return rt.a_boolean;
    if (v.is_undefined() || v.is_hole())
        return rt.a_undefined;
    if (v.is_null())
        return rt.a_object;
    if (v.is(Kind::string))
        return rt.a_string;
    if (v.is(Kind::function) || v.is(Kind::native))
        return rt.a_function;
    return rt.a_object;
}

bool canonical_index(const Str* key, uint32_t& index) noexcept {
    uint32_t n = key->length;
    if (n == 0 || n > 10)
        return false;
    if (key->units[0] == '0')
        return n == 1 ? (index = 0, true) : false;
    uint64_t x = 0;
    for (uint32_t i = 0; i < n; i++) {
        char16_t c = key->units[i];
        if (c < '0' || c > '9')
            return false;
        x = x * 10 + (c - '0');
    }
    if (x >= 4294967295ull)
        return false;
    index = static_cast<uint32_t>(x);
    return true;
}

Str* to_property_key(Rt& rt, Value v) noexcept {
    Str* s = to_string(rt, v);
    return s ? rt.atom(s) : nullptr;
}

bool strict_equals(Value a, Value b) noexcept {
    if (a.is_num() && b.is_num())
        return a.as_num() == b.as_num();
    if (a.is(Kind::string) && b.is(Kind::string)) {
        const Str *x = a.as<Str>(), *y = b.as<Str>();
        return x == y || x->view() == y->view();
    }
    if (a.is_hole())
        a = Value::undefined();
    if (b.is_hole())
        b = Value::undefined();
    return a.same_bits(b);
}

bool same_value_zero(Value a, Value b) noexcept {
    if (a.is_num() && b.is_num()) {
        double x = a.as_num(), y = b.as_num();
        return x == y || (x != x && y != y);
    }
    return strict_equals(a, b);
}

bool loose_equals(Rt& rt, Value a, Value b) noexcept {
    for (int round = 0; round < 4; round++) {
        if (a.is_hole())
            a = Value::undefined();
        if (b.is_hole())
            b = Value::undefined();
        bool an = a.is_num(), bn = b.is_num();
        bool as = a.is(Kind::string), bs = b.is(Kind::string);
        if ((an && bn) || (as && bs) || (a.is_bool() && b.is_bool())
            || (a.is_nullish() && b.is_nullish() && a.same_bits(b)))
            return strict_equals(a, b);
        if (a.is_cell() && b.is_cell() && !as && !bs)
            return a.same_bits(b);
        if (a.is_nullish() && b.is_nullish())
            return true;
        if (a.is_nullish() || b.is_nullish())
            return false;
        if (an && bs)
            return a.as_num() == to_number(rt, b);
        if (as && bn)
            return to_number(rt, a) == b.as_num();
        if (a.is_bool()) {
            a = Value::num(a.is_true() ? 1 : 0);
            continue;
        }
        if (b.is_bool()) {
            b = Value::num(b.is_true() ? 1 : 0);
            continue;
        }
        if ((an || as) && b.is_cell()) {
            b = to_primitive(rt, b, Hint::none);
            if (rt.failed)
                return false;
            continue;
        }
        if (a.is_cell() && (bn || bs)) {
            a = to_primitive(rt, a, Hint::none);
            if (rt.failed)
                return false;
            continue;
        }
        return false;
    }
    return false;
}

Value less_than(Rt& rt, Value a, Value b, bool left_first) noexcept {
    Value px, py;
    if (left_first) {
        px = to_primitive(rt, a, Hint::number);
        py = to_primitive(rt, b, Hint::number);
    } else {
        py = to_primitive(rt, b, Hint::number);
        px = to_primitive(rt, a, Hint::number);
    }
    if (rt.failed)
        return Value::undefined();
    if (px.is(Kind::string) && py.is(Kind::string)) {
        std::u16string_view x = px.as<Str>()->view(), y = py.as<Str>()->view();
        return Value::boolean(x < y);
    }
    double nx = to_number(rt, px), ny = to_number(rt, py);
    if (nx != nx || ny != ny)
        return Value::undefined();
    return Value::boolean(nx < ny);
}

Value add(Rt& rt, Value a, Value b) noexcept {
    if (a.is_num() && b.is_num())
        return Value::num(a.as_num() + b.as_num());
    Value pa = to_primitive(rt, a, Hint::none), pb = to_primitive(rt, b, Hint::none);
    if (rt.failed)
        return Value::undefined();
    if (pa.is(Kind::string) || pb.is(Kind::string)) {
        Str *x = to_string(rt, pa), *y = to_string(rt, pb);
        if (!x || !y)
            return Value::undefined();
        Str* s = rt.concat(x, y);
        return s ? val(s) : Value::undefined();
    }
    return Value::num(to_number(rt, pa) + to_number(rt, pb));
}

double js_pow(double a, double b) noexcept {
    if (b != b)
        return NAN;
    if (b == 0)
        return 1;
    if ((a == 1 || a == -1) && std::isinf(b))
        return NAN;
    if (b == -0.5 && a > 0 && std::isfinite(a))
        return 1 / std::sqrt(a);
    if (b == 0.5 && a > 0)
        return std::sqrt(a);
    if (b >= 0 && b <= 1000 && b == std::floor(b)) {
        int n = static_cast<int>(b);
        double result = 1, x = a;
        while (n) {
            if (n & 1)
                result *= x;
            x *= x;
            n >>= 1;
        }
        return result;
    }
    return std::pow(a, b);
}

double num_op(NumOp op, double a, double b) noexcept {
    switch (op) {
    case NumOp::sub:
        return a - b;
    case NumOp::mul:
        return a * b;
    case NumOp::div:
        return a / b;
    case NumOp::mod:
        return std::fmod(a, b);
    case NumOp::exp:
        return js_pow(a, b);
    case NumOp::shl:
        return num::to_int32(a) << (num::to_uint32(b) & 31);
    case NumOp::shr:
        return num::to_int32(a) >> (num::to_uint32(b) & 31);
    case NumOp::ushr:
        return num::to_uint32(a) >> (num::to_uint32(b) & 31);
    case NumOp::band:
        return num::to_int32(a) & num::to_int32(b);
    case NumOp::bor:
        return num::to_int32(a) | num::to_int32(b);
    case NumOp::bxor:
        return num::to_int32(a) ^ num::to_int32(b);
    }
    return NAN;
}

Value num_op(Rt& rt, NumOp op, Value a, Value b) noexcept {
    double x = to_number(rt, a), y = to_number(rt, b);
    return Value::num(num_op(op, x, y));
}

Arr* own_keys(Rt& rt, Value v) noexcept {
    Arr* out = rt.array(0);
    if (!out)
        return nullptr;
    char16_t buf[16];
    if (v.is(Kind::array) || v.is(Kind::string)) {
        uint32_t n = v.is(Kind::array) ? v.as<Arr>()->length : v.as<Str>()->length;
        for (uint32_t i = 0; i < n; i++) {
            if (v.is(Kind::array) && v.as<Arr>()->items[i].is_hole())
                continue;
            size_t len = num::to_string(i, buf);
            if (!rt.push(out, val(rt.atom({buf, len}))))
                return nullptr;
        }
        return out;
    }
    if ((v.is(Kind::element) || v.is(Kind::group)) && rt.hooks)
        return rt.hooks->keys(rt, v);
    if (!v.is(Kind::object))
        return out;
    const Obj* o = v.as<Obj>();
    uint32_t n = o->shape ? o->shape->count : 0;
    const Shape* small[64] RX_ANALYZER_ZERO;
    const Shape** chain = n <= 64 ? small : rt.arena.array<const Shape*>(n);
    if (!chain)
        return rt.fail(ErrorKind::internal, "out of memory"), nullptr;
    for (const Shape* s = o->shape; s && s->key; s = s->parent)
        chain[s->slot] = s;
    uint32_t first_index = out->length;
    for (uint32_t k = 0; k < n; k++) {
        uint32_t index;
        RX_ASSUME(chain[k]);
        if (!canonical_index(chain[k]->key, index))
            continue;
        if (!rt.push(out, val(chain[k]->key)))
            return nullptr;
        for (uint32_t j = out->length - 1; j > first_index; j--) {
            uint32_t a, b;
            canonical_index(out->items[j - 1].as<Str>(), a);
            canonical_index(out->items[j].as<Str>(), b);
            if (a < b)
                break;
            Value t = out->items[j - 1];
            out->items[j - 1] = out->items[j];
            out->items[j] = t;
        }
    }
    for (uint32_t k = 0; k < n; k++) {
        uint32_t index;
        if (canonical_index(chain[k]->key, index))
            continue;
        if (!rt.push(out, val(chain[k]->key)))
            return nullptr;
    }
    return out;
}

Str* join(Rt& rt, Arr* a, Str* sep) noexcept {
    if (a->h.flags & 1)
        return rt.empty;
    a->h.flags |= 1;
    const uint32_t n = a->length;
    Str** parts = n ? rt.arena.array<Str*>(n) : nullptr;
    Str* out = n && !parts ? nullptr : rt.empty;
    for (uint32_t i = 0; i < n && out; i++) {
        Value x = i < a->length ? a->items[i] : Value::undefined();
        if (x.is_nullish() || x.is_hole()) {
            parts[i] = rt.empty;
            continue;
        }
        parts[i] = to_string(rt, x);
        if (!parts[i])
            out = nullptr;
    }
    if (out && n)
        out = rt.concat_all(parts, n, sep);
    a->h.flags &= static_cast<uint16_t>(~1u);
    return out;
}

Value get(Rt& rt, Value obj, Str* key) noexcept {
    if (obj.is_nullish() || obj.is_hole()) {
        char name[64];
        uint32_t n = 0;
        for (; n < key->length && n < 60; n++)
            name[n] = static_cast<char>(key->units[n] < 0x80 ? key->units[n] : '?');
        name[n] = 0;
        return rt.fail(ErrorKind::type, "%s is not an object (evaluating '.%s')", obj.is_null() ? "null" : "undefined",
                       name);
    }
    if (obj.is(Kind::element) || obj.is(Kind::group))
        return rt.hooks ? rt.hooks->get(rt, obj, key) : Value::undefined();
    uint32_t index;
    Obj* proto = rt.object_proto;
    if (obj.is(Kind::string)) {
        Str* s = obj.as<Str>();
        if (key == rt.a_length)
            return Value::num(s->length);
        if (canonical_index(key, index))
            return index < s->length ? val(rt.str({&s->units[index], 1})) : Value::undefined();
        proto = rt.string_proto;
    } else if (obj.is(Kind::array)) {
        Arr* a = obj.as<Arr>();
        if (key == rt.a_length)
            return Value::num(a->length);
        if (canonical_index(key, index)) {
            if (index >= a->length || a->items[index].is_hole())
                return Value::undefined();
            return a->items[index];
        }
        if (a->props) {
            Value x = rt.get_own(a->props, key);
            if (!x.is_hole())
                return x;
        }
        proto = rt.array_proto;
    } else if (obj.is(Kind::object)) {
        Value x = rt.get_own(obj.as<Obj>(), key);
        if (!x.is_hole())
            return x;
        if (obj.as<Obj>()->proto)
            proto = obj.as<Obj>()->proto;
    } else if (obj.is_num()) {
        proto = rt.number_proto;
    } else if (obj.is_bool()) {
        proto = rt.boolean_proto;
    } else if (obj.is(Kind::function) || obj.is(Kind::native)) {
        if (obj.is(Kind::native) && obj.as<Native>()->props) {
            Value x = rt.get_own(obj.as<Native>()->props, key);
            if (!x.is_hole())
                return x;
        }
        proto = rt.function_proto;
    } else if (obj.is(Kind::date)) {
        proto = rt.date_proto;
    } else if (obj.is(Kind::set)) {
        if (key->view() == u"size")
            return lib_set_size(obj);
        proto = lib::set_is_map(obj) ? rt.map_proto : rt.set_proto;
    } else if (obj.is(Kind::promise)) {
        proto = rt.promise_proto;
    } else if (obj.is(Kind::regexp)) {
        Value x = lib_regexp_get(rt, obj, key);
        if (!x.is_hole())
            return x;
        proto = rt.regexp_proto;
    }
    for (Obj* p : {proto, rt.object_proto}) {
        if (!p)
            continue;
        Value x = rt.get_own(p, key);
        if (!x.is_hole())
            return x;
    }
    return Value::undefined();
}

Value get(Rt& rt, Value obj, Value key) noexcept {
    if (key.is_num() && (obj.is(Kind::array) || obj.is(Kind::string))) {
        double d = key.as_num();
        if (d >= 0 && d < 4294967295.0 && d == std::floor(d)) {
            uint32_t i = static_cast<uint32_t>(d);
            if (obj.is(Kind::array)) {
                Arr* a = obj.as<Arr>();
                return i < a->length && !a->items[i].is_hole() ? a->items[i] : Value::undefined();
            }
            Str* s = obj.as<Str>();
            return i < s->length ? val(rt.str({&s->units[i], 1})) : Value::undefined();
        }
    }
    if (obj.is_nullish() || obj.is_hole()) {
        Str* k = to_string(rt, key);
        return k ? get(rt, obj, k) : Value::undefined();
    }
    Str* k = to_property_key(rt, key);
    return k ? get(rt, obj, k) : Value::undefined();
}

bool set(Rt& rt, Value obj, Str* key, Value x) noexcept {
    if (obj.is_nullish() || obj.is_hole()) {
        rt.fail(ErrorKind::type, "%s is not an object", obj.is_null() ? "null" : "undefined");
        return false;
    }
    uint32_t index;
    if (obj.is(Kind::array)) {
        Arr* a = obj.as<Arr>();
        if (key == rt.a_length) {
            double d = to_number(rt, x);
            if (d < 0 || d != std::floor(d) || d > 4294967295.0)
                return rt.fail(ErrorKind::range, "Invalid array length"), false;
            return rt.set_length(a, static_cast<uint32_t>(d));
        }
        if (canonical_index(key, index)) {
            if (index >= a->length && !rt.set_length(a, index + 1))
                return false;
            a->items[index] = x;
            return true;
        }
        if (!a->props && !(a->props = rt.object()))
            return false;
        return rt.put(a->props, key, x);
    }
    if (obj.is(Kind::regexp))
        return lib_regexp_set(rt, obj, key, x);
    if (obj.is(Kind::object))
        return rt.put(obj.as<Obj>(), key, x);
    if (obj.is(Kind::element) || obj.is(Kind::group))
        return rt.hooks ? rt.hooks->set(rt, obj, key, x) : true;
    return true;
}

bool set(Rt& rt, Value obj, Value key, Value x) noexcept {
    if (key.is_num() && obj.is(Kind::array)) {
        double d = key.as_num();
        if (d >= 0 && d < 4294967295.0 && d == std::floor(d)) {
            Arr* a = obj.as<Arr>();
            uint32_t i = static_cast<uint32_t>(d);
            if (i >= a->length && !rt.set_length(a, i + 1))
                return false;
            a->items[i] = x;
            return true;
        }
    }
    Str* k = to_property_key(rt, key);
    return k && set(rt, obj, k, x);
}

}
