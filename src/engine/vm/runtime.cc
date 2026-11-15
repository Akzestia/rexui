// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/runtime.h"

#include <cstdarg>
#include <cstdio>

#include "base/analyzer.h"
#include "engine/base/utf.h"

namespace rx::engine::vm {

Rt::Rt(Arena& a, Arena* p) noexcept : arena(a), perm(p ? *p : a) {
    root_ = perm.make<Shape>();
    empty = str_ascii("");
    a_length = atom(str_ascii("length"));
    a_undefined = atom(str_ascii("undefined"));
    a_null = atom(str_ascii("null"));
    a_true = atom(str_ascii("true"));
    a_false = atom(str_ascii("false"));
    a_object = atom(str_ascii("object"));
    a_number = atom(str_ascii("number"));
    a_string = atom(str_ascii("string"));
    a_boolean = atom(str_ascii("boolean"));
    a_function = atom(str_ascii("function"));
    a_nan = atom(str_ascii("NaN"));
    a_comma = atom(str_ascii(","));
    a_object_object = atom(str_ascii("[object Object]"));
    a_value_of = atom(str_ascii("valueOf"));
    a_to_string = atom(str_ascii("toString"));
}

namespace {
Str* alloc_str(Arena& a, uint32_t n) {
    void* p = a.alloc(sizeof(Str) + sizeof(char16_t) * (n ? n - 1 : 0), alignof(Str));
    if (!p)
        return nullptr;
    Str* s = static_cast<Str*>(p);
    s->h = Cell{0, Kind::string, 0, 0};
    s->length = n;
    s->hash = 0;
    s->ascii = true;
    return s;
}
}

Str* Rt::str(std::u16string_view u) noexcept {
    if (u.size() > 0x3FFFFFFFu)
        return fail(ErrorKind::range, "a string longer than 2^30 units"), nullptr;
    Str* s = alloc_str(arena, static_cast<uint32_t>(u.size()));
    if (!s)
        return fail(ErrorKind::internal, "out of memory"), nullptr;
    bool ascii = true;
    for (size_t i = 0; i < u.size(); i++)
        s->units[i] = u[i], ascii = ascii && u[i] < 0x80;
    s->ascii = ascii;
    return s;
}

Str* Rt::str_ascii(std::string_view b) noexcept {
    Str* s = alloc_str(arena, static_cast<uint32_t>(b.size()));
    if (!s)
        return fail(ErrorKind::internal, "out of memory"), nullptr;
    bool ascii = true;
    for (size_t i = 0; i < b.size(); i++) {
        s->units[i] = static_cast<unsigned char>(b[i]);
        ascii = ascii && static_cast<unsigned char>(b[i]) < 0x80;
    }
    s->ascii = ascii;
    return s;
}

Str* Rt::str_utf8(std::string_view b) noexcept {
    uint32_t n = static_cast<uint32_t>(utf::utf16_len(b));
    Str* s = alloc_str(arena, n);
    if (!s)
        return fail(ErrorKind::internal, "out of memory"), nullptr;
    uint32_t k = 0;
    bool ascii = true;
    for (size_t i = 0; i < b.size();) {
        utf::Cp c = utf::decode(b, i);
        char32_t cp = c.len ? c.cp : 0xFFFD;
        i += c.len ? c.len : 1;
        if (cp >= 0x10000) {
            s->units[k++] = static_cast<char16_t>(0xD800 + ((cp - 0x10000) >> 10));
            s->units[k++] = static_cast<char16_t>(0xDC00 + ((cp - 0x10000) & 0x3FF));
            ascii = false;
        } else {
            s->units[k++] = static_cast<char16_t>(cp);
            ascii = ascii && cp < 0x80;
        }
    }
    s->ascii = ascii;
    return s;
}

Str* Rt::concat(Str* a, Str* b) noexcept {
    if (!a->length)
        return b;
    if (!b->length)
        return a;
    uint64_t n = static_cast<uint64_t>(a->length) + b->length;
    if (n > 0x3FFFFFFFu)
        return fail(ErrorKind::range, "a string longer than 2^30 units"), nullptr;
    Str* s = alloc_str(arena, static_cast<uint32_t>(n));
    if (!s)
        return fail(ErrorKind::internal, "out of memory"), nullptr;
    std::memcpy(s->units, a->units, sizeof(char16_t) * a->length);
    std::memcpy(s->units + a->length, b->units, sizeof(char16_t) * b->length);
    s->ascii = a->ascii && b->ascii;
    return s;
}

Str* Rt::concat_all(Str* const* parts, uint32_t n, Str* sep) noexcept {
    uint64_t total = n ? static_cast<uint64_t>(sep->length) * (n - 1) : 0;
    bool ascii = sep->ascii || n < 2;
    for (uint32_t i = 0; i < n; i++)
        total += parts[i]->length, ascii = ascii && parts[i]->ascii;
    if (total > 0x3FFFFFFFu)
        return fail(ErrorKind::range, "a string longer than 2^30 units"), nullptr;
    if (!total)
        return empty;
    Str* s = alloc_str(arena, static_cast<uint32_t>(total));
    if (!s)
        return fail(ErrorKind::internal, "out of memory"), nullptr;
    char16_t* p = s->units;
    for (uint32_t i = 0; i < n; i++) {
        if (i && sep->length)
            std::memcpy(p, sep->units, sizeof(char16_t) * sep->length), p += sep->length;
        std::memcpy(p, parts[i]->units, sizeof(char16_t) * parts[i]->length), p += parts[i]->length;
    }
    s->ascii = ascii;
    return s;
}

bool Rt::grow_atoms() noexcept {
    uint32_t cap = atom_cap_ ? atom_cap_ * 2 : 256;
    Str** t = perm.array<Str*>(cap);
    if (!t)
        return false;
    for (uint32_t i = 0; i < atom_cap_; i++) {
        Str* s = atoms_[i];
        if (!s)
            continue;
        uint32_t k = s->hashed() & (cap - 1);
        while (t[k])
            k = (k + 1) & (cap - 1);
        t[k] = s;
    }
    atoms_ = t;
    atom_cap_ = cap;
    return true;
}

Str* Rt::atom(Str* s) noexcept {
    if (!s)
        return nullptr;
    if (atom_count_ * 2 >= atom_cap_ && !grow_atoms())
        return fail(ErrorKind::internal, "out of memory"), nullptr;
    uint32_t k = s->hashed() & (atom_cap_ - 1);
    for (Str* t; (t = atoms_[k]); k = (k + 1) & (atom_cap_ - 1))
        if (t == s || (t->hash == s->hash && t->view() == s->view()))
            return t;
    atoms_[k] = s;
    atom_count_++;
    return s;
}

Str* Rt::atom(std::u16string_view u) noexcept {
    if (atom_cap_) {
        uint32_t x = 2166136261u;
        for (char16_t c : u)
            x = (x ^ c) * 16777619u;
        x |= 1;
        for (uint32_t k = x & (atom_cap_ - 1); atoms_[k]; k = (k + 1) & (atom_cap_ - 1))
            if (atoms_[k]->hash == x && atoms_[k]->view() == u)
                return atoms_[k];
    }
    return atom(str(u));
}

Arr* Rt::array(uint32_t cap) noexcept {
    Arr* a = arena.make<Arr>();
    if (!a)
        return fail(ErrorKind::internal, "out of memory"), nullptr;
    a->h = Cell{0, Kind::array, 0, 0};
    a->cap = cap;
    a->items = cap ? arena.array<Value>(cap) : nullptr;
    if (cap && !a->items)
        return fail(ErrorKind::internal, "out of memory"), nullptr;
    return a;
}

bool Rt::push(Arr* a, Value x) noexcept {
    if (a->length == a->cap) {
        uint32_t cap = a->cap ? a->cap * 2 : 4;
        if (a->cap >= 0x10000000u)
            return fail(ErrorKind::range, "an array longer than 2^28"), false;
        Value* items = arena.array<Value>(cap);
        if (!items)
            return fail(ErrorKind::internal, "out of memory"), false;
        if (a->length)
            std::memcpy(static_cast<void*>(items), a->items, sizeof(Value) * a->length);
        a->items = items;
        a->cap = cap;
    }
    a->items[a->length++] = x;
    return true;
}

bool Rt::set_length(Arr* a, uint32_t n) noexcept {
    while (a->length < n)
        if (!push(a, Value::hole()))
            return false;
    a->length = n;
    return true;
}

Obj* Rt::object() noexcept {
    Obj* o = arena.make<Obj>();
    if (!o)
        return fail(ErrorKind::internal, "out of memory"), nullptr;
    o->h = Cell{0, Kind::object, 0, 0};
    o->shape = root_;
    return o;
}

Value Rt::get_own(const Obj* o, Str* key) const noexcept {
    for (const Shape* s = o->shape; s && s->key; s = s->parent)
        if (s->key == key)
            return o->slots[s->slot];
    return Value::hole();
}

Shape* Rt::transition(const Shape* from, Str* key) noexcept {
    Shape* f = const_cast<Shape*>(from);
    RX_ASSUME(f);
    for (uint32_t i = 0; i < f->n_edges; i++)
        if (f->edges[i].key == key)
            return f->edges[i].to;
    Shape* to = perm.make<Shape>();
    if (!to)
        return nullptr;
    to->parent = from;
    to->key = key;
    to->slot = from->count;
    to->count = from->count + 1;
    if (f->n_edges == f->cap_edges) {
        uint32_t cap = f->cap_edges ? f->cap_edges * 2 : 2;
        Shape::Edge* e = perm.array<Shape::Edge>(cap);
        if (!e)
            return nullptr;
        for (uint32_t i = 0; i < f->n_edges; i++)
            e[i] = f->edges[i];
        f->edges = e;
        f->cap_edges = cap;
    }
    f->edges[f->n_edges++] = {key, to};
    return to;
}

bool Rt::put(Obj* o, Str* key, Value x) noexcept {
    RX_ASSUME(!o->shape || !o->shape->key || o->slots);
    for (const Shape* s = o->shape; s && s->key; s = s->parent)
        if (s->key == key)
            return o->slots[s->slot] = x, true;
    Shape* to = transition(o->shape, key);
    if (!to)
        return fail(ErrorKind::internal, "out of memory"), false;
    if (to->count > o->cap) {
        uint32_t cap = o->cap ? o->cap * 2 : 4;
        Value* slots = arena.array<Value>(cap);
        if (!slots)
            return fail(ErrorKind::internal, "out of memory"), false;
        if (o->cap)
            std::memcpy(static_cast<void*>(slots), o->slots, sizeof(Value) * o->shape->count);
        o->slots = slots;
        o->cap = cap;
    }
    RX_ASSUME(o->slots);
    o->slots[to->slot] = x;
    o->shape = to;
    return true;
}

bool Rt::remove(Obj* o, Str* key) noexcept {
    const Shape* s = o->shape;
    while (s && s->key && s->key != key)
        s = s->parent;
    if (!s || !s->key)
        return true;
    uint32_t n = o->shape->count;
    const Shape* small[64];
    const Shape** chain = n <= 64 ? small : arena.array<const Shape*>(n);
    if (!chain)
        return fail(ErrorKind::internal, "out of memory"), false;
    for (const Shape* c = o->shape; c && c->key; c = c->parent)
        chain[c->slot] = c;
    Value* old = o->slots;
    o->shape = root_;
    o->cap = 0;
    o->slots = nullptr;
    for (uint32_t k = 0; k < n; k++)
        if (chain[k]->key != key && !put(o, chain[k]->key, old[chain[k]->slot]))
            return false;
    return true;
}

Native* Rt::native(const char* name, NativeFn fn, uint32_t length, NativeFn construct) noexcept {
    Native* n = arena.make<Native>();
    if (!n)
        return fail(ErrorKind::internal, "out of memory"), nullptr;
    n->h = Cell{0, Kind::native, 0, 0};
    n->fn = fn;
    n->construct = construct;
    n->name = atom(str_ascii(name));
    n->length = length;
    return n;
}

Value Rt::fail(ErrorKind k, const char* fmt, ...) noexcept {
    if (failed)
        return Value::undefined();
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = std::vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    failed = true;
    error = k;
    message = str_utf8({buf,
                        n < 0                                     ? 0
                            : static_cast<size_t>(n) < sizeof buf ? static_cast<size_t>(n)
                                                                  : sizeof buf - 1});
    static constexpr const char* k_names[] = {"Error",       "TypeError", "RangeError",   "ReferenceError",
                                              "SyntaxError", "URIError",  "InternalError"};
    Obj* e = object();
    if (e && message) {
        failed = false;
        put(e, atom(str_ascii("name")), val(str_ascii(k_names[static_cast<int>(k)])));
        put(e, atom(str_ascii("message")), val(message));
        e->proto = error_proto;
        failed = true;
        thrown = val(e);
    }
    return Value::undefined();
}

}
