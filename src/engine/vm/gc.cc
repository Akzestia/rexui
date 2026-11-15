// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/gc.h"

#include <cstring>

#include "engine/vm/interp.h"
#include "engine/vm/lib.h"

namespace rx::engine::vm {

Gc::Gc(Rt& r, Arena& from, Arena& t, Arena& tm) noexcept : rt(r), to(t), tmp(tm) {
    uint32_t n = 0;
    from.each_block([&](uintptr_t, uintptr_t) { n++; });
    ranges_ = tmp.array<Range>(n);
    if (!ranges_) {
        failed = true;
        return;
    }
    from.each_block([&](uintptr_t b, uintptr_t e) { ranges_[n_ranges_++] = Range{b, e}; });
    for (uint32_t i = 1; i < n_ranges_; i++)
        for (uint32_t j = i; j > 0 && ranges_[j - 1].begin > ranges_[j].begin; j--) {
            Range x = ranges_[j];
            ranges_[j] = ranges_[j - 1];
            ranges_[j - 1] = x;
        }
}

bool Gc::in_from(const void* p) const noexcept {
    uintptr_t a = reinterpret_cast<uintptr_t>(p);
    uint32_t lo = 0, hi = n_ranges_;
    while (lo < hi) {
        uint32_t m = (lo + hi) / 2;
        if (ranges_[m].end <= a)
            lo = m + 1;
        else
            hi = m;
    }
    return lo < n_ranges_ && a >= ranges_[lo].begin && a < ranges_[lo].end;
}

namespace {
uint32_t hash_ptr(const void* p) {
    uint64_t x = reinterpret_cast<uintptr_t>(p);
    x ^= x >> 33, x *= 0xff51afd7ed558ccdull, x ^= x >> 33;
    return static_cast<uint32_t>(x);
}
}

void* Gc::find(const void* p) const noexcept {
    if (!cap_)
        return nullptr;
    for (uint32_t h = hash_ptr(p) & (cap_ - 1); map_[h].from; h = (h + 1) & (cap_ - 1))
        if (map_[h].from == p)
            return map_[h].to;
    return nullptr;
}

bool Gc::put(const void* p, void* q) noexcept {
    if ((count_ + 1) * 2 > cap_) {
        uint32_t cap = cap_ ? cap_ * 2 : 4096;
        Fwd* m = tmp.array<Fwd>(cap);
        if (!m)
            return failed = true, false;
        for (uint32_t i = 0; i < cap_; i++)
            if (map_[i].from) {
                uint32_t h = hash_ptr(map_[i].from) & (cap - 1);
                while (m[h].from)
                    h = (h + 1) & (cap - 1);
                m[h] = map_[i];
            }
        map_ = m, cap_ = cap;
    }
    uint32_t h = hash_ptr(p) & (cap_ - 1);
    while (map_[h].from)
        h = (h + 1) & (cap_ - 1);
    map_[h] = Fwd{p, q};
    count_++;
    return true;
}

void* Gc::raw(const void* p, size_t n, size_t align) noexcept {
    if (!p || !in_from(p) || failed)
        return const_cast<void*>(p);
    if (void* q = find(p))
        return q;
    void* q = to.alloc(n ? n : 1, align);
    if (!q)
        return failed = true, const_cast<void*>(p);
    std::memcpy(q, p, n);
    put(p, q);
    bytes += n;
    return q;
}

namespace {
size_t cell_size(const Cell* c) {
    switch (c->kind) {
    case Kind::string: {
        const Str* s = reinterpret_cast<const Str*>(c);
        return sizeof(Str) + sizeof(char16_t) * (s->length ? s->length - 1 : 0);
    }
    case Kind::array:
        return sizeof(Arr);
    case Kind::object:
        return sizeof(Obj);
    case Kind::function:
        return sizeof(Fn);
    case Kind::env: {
        const Env* e = reinterpret_cast<const Env*>(c);
        return sizeof(Env) + sizeof(Value) * (e->size ? e->size - 1 : 0);
    }
    case Kind::iterator:
        return sizeof(Iter);
    case Kind::native: {
        size_t n = lib::gc_size(c);
        return n ? n : sizeof(Native);
    }
    default:
        return lib::gc_size(c);
    }
}
}

Cell* Gc::cell(Cell* c) noexcept {
    if (!c || failed || !in_from(c))
        return c;
    if (void* q = find(c))
        return static_cast<Cell*>(q);
    size_t n = cell_size(c);
    if (!n)
        return failed = true, c;
    void* q = to.alloc(n, 16);
    if (!q)
        return failed = true, c;
    std::memcpy(q, c, n);
    if (!put(c, q) || !gray_.push(tmp, static_cast<Cell*>(q)))
        return failed = true, c;
    cells++, bytes += n;
    return static_cast<Cell*>(q);
}

Value Gc::value(Value v) noexcept {
    if (!v.is_cell())
        return v;
    return Value::cell(cell(v.as_cell()));
}

void Gc::scan(Cell* c) noexcept {
    switch (c->kind) {
    case Kind::string:
        break;
    case Kind::array: {
        Arr* a = reinterpret_cast<Arr*>(c);
        if (a->items && in_from(a->items)) {
            uint32_t cap = a->length ? a->length : 0;
            Value* items = cap ? to.array<Value>(cap) : nullptr;
            if (cap && !items)
                return void(failed = true);
            if (cap)
                std::memcpy(static_cast<void*>(items), a->items, sizeof(Value) * a->length);
            a->items = items;
            a->cap = cap;
        }
        forward_values(a->items, a->length);
        a->props = of(a->props);
        break;
    }
    case Kind::object: {
        Obj* o = reinterpret_cast<Obj*>(c);
        uint32_t n = o->shape ? o->shape->count : 0;
        if (o->slots && in_from(o->slots)) {
            Value* slots = n ? to.array<Value>(n) : nullptr;
            if (n && !slots)
                return void(failed = true);
            if (n)
                std::memcpy(static_cast<void*>(slots), o->slots, sizeof(Value) * n);
            o->slots = slots;
            o->cap = n;
        }
        forward_values(o->slots, n);
        o->proto = of(o->proto);
        break;
    }
    case Kind::function: {
        Fn* f = reinterpret_cast<Fn*>(c);
        f->env = of(f->env);
        break;
    }
    case Kind::env: {
        Env* e = reinterpret_cast<Env*>(c);
        e->parent = of(e->parent);
        forward_values(e->slots, e->size);
        break;
    }
    case Kind::iterator: {
        Iter* it = reinterpret_cast<Iter*>(c);
        it->src = value(it->src);
        break;
    }
    case Kind::native: {
        Native* nf = reinterpret_cast<Native*>(c);
        nf->name = of(nf->name);
        nf->props = of(nf->props);
        lib::gc_trace(c, *this);
        break;
    }
    default:
        lib::gc_trace(c, *this);
    }
}

void Gc::finish() noexcept {
    for (uint32_t i = 0; i < gray_.size && !failed; i++)
        scan(gray_[i]);
    gray_.size = 0;
}

void Rt::gc_roots(Gc& gc) noexcept {
    for (Str** s : {&empty, &a_length, &a_undefined, &a_null, &a_true, &a_false, &a_object, &a_number, &a_string,
                    &a_boolean, &a_function, &a_nan, &a_comma, &a_object_object, &a_value_of, &a_to_string, &message})
        *s = gc.of(*s);
    for (Obj** o : {&string_proto, &number_proto, &boolean_proto, &array_proto, &object_proto, &function_proto,
                    &date_proto, &set_proto, &map_proto, &regexp_proto, &promise_proto, &error_proto, &globals})
        *o = gc.of(*o);
    date_ctor = gc.of(date_ctor);
    set_ctor = gc.of(set_ctor);
    map_ctor = gc.of(map_ctor);
    thrown = gc.value(thrown);
    for (uint32_t i = 0; i < atom_cap_; i++)
        if (atoms_[i])
            atoms_[i] = gc.of(atoms_[i]);
    for (RegexCache& k : regexes) {
        k.pattern = gc.of(const_cast<Str*>(k.pattern));
        k.flags = gc.of(const_cast<Str*>(k.flags));
        k.error = gc.of(k.error);
    }
    List<Shape*> todo;
    if (!todo.push(gc.tmp, root_))
        return void(gc.failed = true);
    while (todo.size) {
        Shape* s = todo[--todo.size];
        s->key = gc.of(s->key);
        for (uint32_t i = 0; i < s->n_edges; i++) {
            s->edges[i].key = gc.of(s->edges[i].key);
            if (!todo.push(gc.tmp, s->edges[i].to))
                return void(gc.failed = true);
        }
    }
    lib::gc_jobs(*this, gc);
}

}
