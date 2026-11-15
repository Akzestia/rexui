// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/gc.h"
#include "engine/vm/lib.h"

namespace rx::engine::vm {

struct SetObj {
    Cell h;
    Value* items;
    Value* vals;
    uint32_t n, cap, live;
};
constexpr uint16_t k_is_map = 1;

namespace lib {
namespace {

SetObj* as_set(Value v) {
    return v.is(Kind::set) && !(v.as<Cell>()->flags & k_is_map) ? v.as<SetObj>() : nullptr;
}
SetObj* as_map(Value v) {
    return v.is(Kind::set) && (v.as<Cell>()->flags & k_is_map) ? v.as<SetObj>() : nullptr;
}
int32_t find(SetObj* s, Value v) {
    for (uint32_t k = 0; k < s->n; k++)
        if (!s->items[k].is_hole() && same_value_zero(s->items[k], v))
            return static_cast<int32_t>(k);
    return -1;
}
bool add(Rt& rt, SetObj* s, Value v, Value mapped = Value::undefined()) {
    if (v.is_num() && v.as_num() == 0)
        v = Value::num(0);
    const bool map = s->h.flags & k_is_map;
    if (int32_t at = find(s, v); at >= 0) {
        if (map)
            s->vals[at] = mapped;
        return true;
    }
    if (s->n == s->cap) {
        uint32_t cap = s->cap ? s->cap * 2 : 8;
        Value* items = rt.arena.array<Value>(cap);
        Value* vals = map ? rt.arena.array<Value>(cap) : nullptr;
        if (!items || (map && !vals))
            return rt.fail(ErrorKind::internal, "out of memory"), false;
        for (uint32_t k = 0; k < s->n; k++) {
            items[k] = s->items[k];
            if (map)
                vals[k] = s->vals[k];
        }
        s->items = items, s->vals = vals, s->cap = cap;
    }
    if (map)
        s->vals[s->n] = mapped;
    s->items[s->n++] = v;
    s->live++;
    return true;
}

#define THIS_SET(method)      \
    Rt& rt = vm.rt;           \
    SetObj* S = as_set(self); \
    if (!S)                   \
    return rt.fail(ErrorKind::type, "Set.prototype.%s called on incompatible receiver", method)

#define THIS_MAP(method)      \
    Rt& rt = vm.rt;           \
    SetObj* S = as_map(self); \
    if (!S)                   \
    return rt.fail(ErrorKind::type, "Map.prototype.%s called on incompatible receiver", method)

Value set_add(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_SET("add");
    return add(rt, S, arg(args, argc, 0)) ? self : Value::undefined();
}
Value set_has(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_SET("has");
    return Value::boolean(find(S, arg(args, argc, 0)) >= 0);
}
Value set_delete(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_SET("delete");
    int32_t k = find(S, arg(args, argc, 0));
    if (k < 0)
        return Value::boolean(false);
    S->items[k] = Value::hole();
    S->live--;
    return Value::boolean(true);
}
Value set_clear(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_SET("clear");
    for (uint32_t k = 0; k < S->n; k++)
        S->items[k] = Value::hole();
    S->live = 0;
    return Value::undefined();
}
Value set_foreach(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_SET("forEach");
    Value fn = arg(args, argc, 0);
    if (!callable(fn))
        return rt.fail(ErrorKind::type, "Set.prototype.forEach callback must be a function");
    for (uint32_t k = 0; k < S->n; k++) {
        if (S->items[k].is_hole())
            continue;
        Value a[3] = {S->items[k], S->items[k], self};
        vm.call(fn, arg(args, argc, 1), a, 3);
        if (rt.failed)
            return Value::undefined();
    }
    return Value::undefined();
}
Value set_values(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_SET("values");
    Arr* a = rt.array(S->live);
    for (uint32_t k = 0; a && k < S->n; k++)
        if (!S->items[k].is_hole())
            rt.push(a, S->items[k]);
    return a ? val(a) : Value::undefined();
}
Value map_get(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_MAP("get");
    int32_t k = find(S, arg(args, argc, 0));
    return k < 0 ? Value::undefined() : S->vals[k];
}
Value map_set(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_MAP("set");
    return add(rt, S, arg(args, argc, 0), arg(args, argc, 1)) ? self : Value::undefined();
}
Value map_has(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_MAP("has");
    return Value::boolean(find(S, arg(args, argc, 0)) >= 0);
}
Value map_delete(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_MAP("delete");
    int32_t k = find(S, arg(args, argc, 0));
    if (k < 0)
        return Value::boolean(false);
    S->items[k] = Value::hole();
    S->vals[k] = Value::undefined();
    S->live--;
    return Value::boolean(true);
}
Value map_clear(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_MAP("clear");
    for (uint32_t k = 0; k < S->n; k++)
        S->items[k] = Value::hole(), S->vals[k] = Value::undefined();
    S->live = 0;
    return Value::undefined();
}
Value map_foreach(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_MAP("forEach");
    Value fn = arg(args, argc, 0);
    if (!callable(fn))
        return rt.fail(ErrorKind::type, "Map.prototype.forEach callback must be a function");
    for (uint32_t k = 0; k < S->n; k++) {
        if (S->items[k].is_hole())
            continue;
        Value a[3] = {S->vals[k], S->items[k], self};
        vm.call(fn, arg(args, argc, 1), a, 3);
        if (rt.failed)
            return Value::undefined();
    }
    return Value::undefined();
}
Value map_keys(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_MAP("keys");
    Arr* a = rt.array(S->live);
    for (uint32_t k = 0; a && k < S->n; k++)
        if (!S->items[k].is_hole())
            rt.push(a, S->items[k]);
    return a ? val(a) : Value::undefined();
}
Value map_values(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_MAP("values");
    Arr* a = rt.array(S->live);
    for (uint32_t k = 0; a && k < S->n; k++)
        if (!S->items[k].is_hole())
            rt.push(a, S->vals[k]);
    return a ? val(a) : Value::undefined();
}
Value map_entries(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_MAP("entries");
    Arr* a = rt.array(S->live);
    for (uint32_t k = 0; a && k < S->n; k++) {
        if (S->items[k].is_hole())
            continue;
        Arr* pair = rt.array(2);
        if (!pair)
            return Value::undefined();
        rt.push(pair, S->items[k]);
        rt.push(pair, S->vals[k]);
        rt.push(a, val(pair));
    }
    return a ? val(a) : Value::undefined();
}
Value map_construct(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    SetObj* s = rt.arena.make<SetObj>();
    if (!s)
        return rt.fail(ErrorKind::internal, "out of memory");
    s->h = Cell{0, Kind::set, 0, k_is_map};
    Value src = arg(args, argc, 0);
    auto pair = [&](Value p) {
        if (!p.is_cell() || p.is(Kind::string))
            return rt.fail(ErrorKind::type, "Iterator value is not an entry object"), false;
        Value k = get(rt, p, Value::num(0)), v = get(rt, p, Value::num(1));
        return !rt.failed && add(rt, s, k, v);
    };
    if (src.is(Kind::array)) {
        Arr* a = src.as<Arr>();
        for (uint32_t k = 0; k < a->length; k++)
            if (!pair(a->items[k].is_hole() ? Value::undefined() : a->items[k]))
                return Value::undefined();
    } else if (SetObj* m = as_map(src)) {
        for (uint32_t k = 0; k < m->n; k++)
            if (!m->items[k].is_hole() && !add(rt, s, m->items[k], m->vals[k]))
                return Value::undefined();
    } else if (SetObj* o = as_set(src)) {
        for (uint32_t k = 0; k < o->n; k++)
            if (!o->items[k].is_hole() && !pair(o->items[k]))
                return Value::undefined();
    } else if (!src.is_nullish() && !src.is_hole()) {
        return rt.fail(ErrorKind::type, "Map constructor requires an iterable");
    }
    return Value::cell(&s->h);
}
Value map_call(Vm& vm, Value, const Value*, uint32_t) {
    return vm.rt.fail(ErrorKind::type, "calling Map constructor without new is invalid");
}

Value set_construct(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    SetObj* s = rt.arena.make<SetObj>();
    if (!s)
        return rt.fail(ErrorKind::internal, "out of memory");
    s->h = Cell{0, Kind::set, 0, 0};
    Value src = arg(args, argc, 0);
    if (src.is(Kind::array)) {
        Arr* a = src.as<Arr>();
        for (uint32_t k = 0; k < a->length; k++)
            if (!add(rt, s, a->items[k].is_hole() ? Value::undefined() : a->items[k]))
                return Value::undefined();
    } else if (src.is(Kind::string)) {
        Str* str = src.as<Str>();
        for (uint32_t i = 0; i < str->length;) {
            uint32_t n = str->units[i] >= 0xD800 && str->units[i] <= 0xDBFF && i + 1 < str->length
                    && str->units[i + 1] >= 0xDC00 && str->units[i + 1] <= 0xDFFF
                ? 2
                : 1;
            Str* one = rt.str({&str->units[i], n});
            if (!one || !add(rt, s, val(one)))
                return Value::undefined();
            i += n;
        }
    } else if (SetObj* o = as_set(src)) {
        for (uint32_t k = 0; k < o->n; k++)
            if (!o->items[k].is_hole() && !add(rt, s, o->items[k]))
                return Value::undefined();
    } else if (SetObj* m = as_map(src)) {
        for (uint32_t k = 0; k < m->n; k++) {
            if (m->items[k].is_hole())
                continue;
            Arr* pair = rt.array(2);
            if (!pair)
                return Value::undefined();
            rt.push(pair, m->items[k]);
            rt.push(pair, m->vals[k]);
            if (!add(rt, s, val(pair)))
                return Value::undefined();
        }
    } else if (!src.is_nullish() && !src.is_hole()) {
        return rt.fail(ErrorKind::type, "Set constructor requires an iterable");
    }
    return Value::cell(&s->h);
}
Value set_call(Vm& vm, Value, const Value*, uint32_t) {
    return vm.rt.fail(ErrorKind::type, "calling Set constructor without new is invalid");
}

}

Value set_size(Value set) noexcept {
    return Value::num(set.as<SetObj>()->live);
}
bool set_is_map(Value set) noexcept {
    return set.as<Cell>()->flags & k_is_map;
}
bool set_step(Rt& rt, Value set, uint32_t& at, Value& out) noexcept {
    SetObj* s = set.as<SetObj>();
    while (at < s->n && s->items[at].is_hole())
        at++;
    if (at >= s->n)
        return false;
    if (s->h.flags & k_is_map) {
        Arr* pair = rt.array(2);
        if (!pair)
            return false;
        rt.push(pair, s->items[at]);
        rt.push(pair, s->vals[at]);
        out = val(pair);
        at++;
        return true;
    }
    out = s->items[at++];
    return true;
}

void install_set(Rt& rt) noexcept {
    struct M {
        const char* name;
        NativeFn fn;
        uint32_t len;
    };
    static constexpr M k[] = {{"add", set_add, 1},     {"has", set_has, 1},         {"delete", set_delete, 1},
                              {"clear", set_clear, 0}, {"forEach", set_foreach, 1}, {"values", set_values, 0},
                              {"keys", set_values, 0}};
    for (const M& m : k)
        def(rt, rt.set_proto, m.name, m.fn, m.len);
    rt.set_ctor = rt.native("Set", set_call, 0, set_construct);
    if (rt.set_ctor)
        rt.put(rt.globals, rt.set_ctor->name, val(rt.set_ctor));
    static constexpr M km[] = {{"get", map_get, 1},       {"set", map_set, 2},       {"has", map_has, 1},
                               {"delete", map_delete, 1}, {"clear", map_clear, 0},   {"forEach", map_foreach, 1},
                               {"keys", map_keys, 0},     {"values", map_values, 0}, {"entries", map_entries, 0}};
    for (const M& m : km)
        def(rt, rt.map_proto, m.name, m.fn, m.len);
    rt.map_ctor = rt.native("Map", map_call, 0, map_construct);
    if (rt.map_ctor)
        rt.put(rt.globals, rt.map_ctor->name, val(rt.map_ctor));
}

size_t gc_set_size() noexcept {
    return sizeof(SetObj);
}
void gc_set_trace(Cell* c, Gc& gc) noexcept {
    SetObj* s = reinterpret_cast<SetObj*>(c);
    if (s->items && gc.in_from(s->items)) {
        Value* items = s->cap ? gc.to.array<Value>(s->cap) : nullptr;
        if (s->cap && !items)
            return void(gc.failed = true);
        if (s->n && items)
            std::memcpy(static_cast<void*>(items), s->items, sizeof(Value) * s->n);
        s->items = items;
    }
    gc.forward_values(s->items, s->n);
    if (s->vals && gc.in_from(s->vals)) {
        Value* vals = s->cap ? gc.to.array<Value>(s->cap) : nullptr;
        if (s->cap && !vals)
            return void(gc.failed = true);
        if (s->n && vals)
            std::memcpy(static_cast<void*>(vals), s->vals, sizeof(Value) * s->n);
        s->vals = vals;
    }
    if (s->vals)
        gc.forward_values(s->vals, s->n);
}

}
}
