// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/interp.h"

#include <cmath>

#include "engine/vm/lib.h"
#include "engine/vm/number.h"
#include "engine/vm/ops.h"

namespace rx::engine::vm {
namespace {

struct Handler {
    uint32_t target;
    uint16_t reg;
    Env* env;
};

struct Frame {
    Vm* vm;
    Rt* rt;
    const Code* code;
    Env* env;
    Value callee;
    const Value* args;
    uint32_t argc;
    Host* host;
    Handler handlers[16];
    uint32_t n_handlers;
};

using Fn_ = Value (*)(Frame*, const Ins*, Value*);
extern const Fn_ k_table[];

#define NEXT(n)                                                                 \
    do {                                                                        \
        ip += (n);                                                              \
        [[clang::musttail]] return k_table[static_cast<int>(ip->op)](f, ip, r); \
    } while (0)
#define CHECK()                                          \
    do {                                                 \
        if (f->rt->failed) [[unlikely]] {                \
            [[clang::musttail]] return unwind(f, ip, r); \
        }                                                \
    } while (0)
#define TARGET(ins) (static_cast<uint32_t>((ins).b) | static_cast<uint32_t>((ins).c) << 16)

Value unwind(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    if (rt.error != ErrorKind::internal && f->n_handlers) {
        Handler h = f->handlers[--f->n_handlers];
        r[h.reg] = rt.thrown;
        rt.clear();
        f->env = h.env;
        ip = f->code->ins + h.target;
        [[clang::musttail]] return k_table[static_cast<int>(ip->op)](f, ip, r);
    }
    return Value::undefined();
}

#define JUMP(target)                                                              \
    do {                                                                          \
        const Ins* to_ = f->code->ins + (target);                                 \
        if (to_ <= ip && --f->vm->budget <= 0) [[unlikely]] {                     \
            f->rt->fail(ErrorKind::internal, "the job ran past its time budget"); \
            [[clang::musttail]] return unwind(f, ip, r);                          \
        }                                                                         \
        ip = to_;                                                                 \
        [[clang::musttail]] return k_table[static_cast<int>(ip->op)](f, ip, r);   \
    } while (0)

Value op_loadk(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = f->code->consts[ip->b];
    NEXT(1);
}
Value op_undef(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = Value::undefined();
    NEXT(1);
}
Value op_mov(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = r[ip->b];
    NEXT(1);
}
Value op_add(Frame* f, const Ins* ip, Value* r) {
    Value a = r[ip->b], b = r[ip->c];
    if (a.is_num() && b.is_num()) [[likely]] {
        r[ip->a] = Value::num(a.as_num() + b.as_num());
        NEXT(1);
    }
    r[ip->a] = add(*f->rt, a, b);
    CHECK();
    NEXT(1);
}
template<NumOp O>
Value op_num(Frame* f, const Ins* ip, Value* r) {
    Value a = r[ip->b], b = r[ip->c];
    if (a.is_num() && b.is_num()) [[likely]] {
        r[ip->a] = Value::num(num_op(O, a.as_num(), b.as_num()));
        NEXT(1);
    }
    r[ip->a] = num_op(*f->rt, O, a, b);
    CHECK();
    NEXT(1);
}
Value op_sub(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::sub>(f, ip, r);
}
Value op_mul(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::mul>(f, ip, r);
}
Value op_div(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::div>(f, ip, r);
}
Value op_mod(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::mod>(f, ip, r);
}
Value op_exp(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::exp>(f, ip, r);
}
Value op_shl(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::shl>(f, ip, r);
}
Value op_shr(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::shr>(f, ip, r);
}
Value op_ushr(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::ushr>(f, ip, r);
}
Value op_band(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::band>(f, ip, r);
}
Value op_bor(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::bor>(f, ip, r);
}
Value op_bxor(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_num<NumOp::bxor>(f, ip, r);
}

Value op_eq(Frame* f, const Ins* ip, Value* r) {
    bool x = loose_equals(*f->rt, r[ip->b], r[ip->c]);
    CHECK();
    r[ip->a] = Value::boolean(x);
    NEXT(1);
}
Value op_ne(Frame* f, const Ins* ip, Value* r) {
    bool x = loose_equals(*f->rt, r[ip->b], r[ip->c]);
    CHECK();
    r[ip->a] = Value::boolean(!x);
    NEXT(1);
}
Value op_seq(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = Value::boolean(strict_equals(r[ip->b], r[ip->c]));
    NEXT(1);
}
Value op_sne(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = Value::boolean(!strict_equals(r[ip->b], r[ip->c]));
    NEXT(1);
}
Value op_lt(Frame* f, const Ins* ip, Value* r) {
    Value a = r[ip->b], b = r[ip->c];
    if (a.is_num() && b.is_num())
        r[ip->a] = Value::boolean(a.as_num() < b.as_num());
    else {
        Value x = less_than(*f->rt, a, b, true);
        CHECK();
        r[ip->a] = Value::boolean(x.is_true());
    }
    NEXT(1);
}
Value op_gt(Frame* f, const Ins* ip, Value* r) {
    Value a = r[ip->b], b = r[ip->c];
    if (a.is_num() && b.is_num())
        r[ip->a] = Value::boolean(a.as_num() > b.as_num());
    else {
        Value x = less_than(*f->rt, b, a, false);
        CHECK();
        r[ip->a] = Value::boolean(x.is_true());
    }
    NEXT(1);
}
Value op_le(Frame* f, const Ins* ip, Value* r) {
    Value a = r[ip->b], b = r[ip->c];
    if (a.is_num() && b.is_num())
        r[ip->a] = Value::boolean(a.as_num() <= b.as_num());
    else {
        Value x = less_than(*f->rt, b, a, false);
        CHECK();
        r[ip->a] = Value::boolean(!(x.is_true() || x.is_undefined()));
    }
    NEXT(1);
}
Value op_ge(Frame* f, const Ins* ip, Value* r) {
    Value a = r[ip->b], b = r[ip->c];
    if (a.is_num() && b.is_num())
        r[ip->a] = Value::boolean(a.as_num() >= b.as_num());
    else {
        Value x = less_than(*f->rt, a, b, true);
        CHECK();
        r[ip->a] = Value::boolean(!(x.is_true() || x.is_undefined()));
    }
    NEXT(1);
}
Value op_in(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    Value key = r[ip->b], obj = r[ip->c];
    if (!obj.is_cell() || obj.is(Kind::string)) {
        rt.fail(ErrorKind::type, "the right side of in is not an object");
        CHECK();
    }
    Str* k = to_property_key(rt, key);
    CHECK();
    bool has = false;
    uint32_t index;
    if (obj.is(Kind::array)) {
        Arr* a = obj.as<Arr>();
        has = k == rt.a_length || (canonical_index(k, index) && index < a->length && !a->items[index].is_hole());
    } else if (obj.is(Kind::object)) {
        has = !rt.get_own(obj.as<Obj>(), k).is_hole();
    }
    r[ip->a] = Value::boolean(has);
    NEXT(1);
}

Value op_neg(Frame* f, const Ins* ip, Value* r) {
    Value a = r[ip->b];
    double d = a.is_num() ? a.as_num() : to_number(*f->rt, a);
    CHECK();
    r[ip->a] = Value::num(-d);
    NEXT(1);
}
Value op_plus(Frame* f, const Ins* ip, Value* r) {
    Value a = r[ip->b];
    double d = a.is_num() ? a.as_num() : to_number(*f->rt, a);
    CHECK();
    r[ip->a] = Value::num(d);
    NEXT(1);
}
Value op_tonum(Frame* f, const Ins* ip, Value* r) {
    [[clang::musttail]] return op_plus(f, ip, r);
}
Value op_not_(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = Value::boolean(!to_boolean(r[ip->b]));
    NEXT(1);
}
Value op_bnot(Frame* f, const Ins* ip, Value* r) {
    double d = to_number(*f->rt, r[ip->b]);
    CHECK();
    r[ip->a] = Value::num(~num::to_int32(d));
    NEXT(1);
}
Value op_typeof_(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = val(type_of(*f->rt, r[ip->b]));
    NEXT(1);
}
Value op_tostr(Frame* f, const Ins* ip, Value* r) {
    Str* s = to_string(*f->rt, r[ip->b]);
    CHECK();
    r[ip->a] = val(s);
    NEXT(1);
}

Value op_jmp(Frame* f, const Ins* ip, Value* r) {
    JUMP(TARGET(*ip));
}
Value op_jf(Frame* f, const Ins* ip, Value* r) {
    if (!to_boolean(r[ip->a]))
        JUMP(TARGET(*ip));
    NEXT(1);
}
Value op_jt(Frame* f, const Ins* ip, Value* r) {
    if (to_boolean(r[ip->a]))
        JUMP(TARGET(*ip));
    NEXT(1);
}
Value op_jnullish(Frame* f, const Ins* ip, Value* r) {
    Value v = r[ip->a];
    if (v.is_nullish() || v.is_hole())
        JUMP(TARGET(*ip));
    NEXT(1);
}
Value op_jnotnullish(Frame* f, const Ins* ip, Value* r) {
    Value v = r[ip->a];
    if (!(v.is_nullish() || v.is_hole()))
        JUMP(TARGET(*ip));
    NEXT(1);
}

bool nullish_read(Frame* f, const Ins* ip, Value o) {
    if (!o.is_nullish() && !o.is_hole())
        return false;
    const Code* c = f->code;
    uint32_t i = static_cast<uint32_t>(ip - c->ins);
    if (!c->ends || !c->ends[i] || c->ends[i] <= c->pos[i] || c->ends[i] > c->src.size())
        return false;
    std::string_view t = c->src.substr(c->pos[i], c->ends[i] - c->pos[i]);
    f->rt->fail(ErrorKind::type, "%s is not an object (evaluating '%.*s')", o.is_null() ? "null" : "undefined",
                static_cast<int>(t.size()), t.data());
    return true;
}

Value op_getprop(Frame* f, const Ins* ip, Value* r) {
    Value o = r[ip->b];
    if (nullish_read(f, ip, o)) [[unlikely]] {
        CHECK();
    }
    Str* key = f->code->consts[ip->c].as<Str>();
    r[ip->a] = get(*f->rt, o, key);
    CHECK();
    NEXT(1);
}
Value op_getidx(Frame* f, const Ins* ip, Value* r) {
    if (nullish_read(f, ip, r[ip->b])) [[unlikely]] {
        CHECK();
    }
    r[ip->a] = get(*f->rt, r[ip->b], r[ip->c]);
    CHECK();
    NEXT(1);
}
Value op_del(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    Value o = r[ip->b];
    if (o.is_nullish() || o.is_hole()) {
        rt.fail(ErrorKind::type, "Cannot convert undefined or null to object");
        CHECK();
    }
    Value k = r[ip->c];
    if (o.is(Kind::array)) {
        Arr* a = o.as<Arr>();
        double d = k.is_num() ? k.as_num() : -1;
        uint32_t index;
        Str* ks = k.is_num() ? nullptr : to_property_key(rt, k);
        CHECK();
        if (k.is_num() && d >= 0 && d < a->length && d == std::floor(d))
            a->items[static_cast<uint32_t>(d)] = Value::hole();
        else if (ks && canonical_index(ks, index)) {
            if (index < a->length)
                a->items[index] = Value::hole();
        } else if (ks && a->props)
            rt.remove(a->props, ks);
    } else if (o.is(Kind::object)) {
        Str* ks = to_property_key(rt, k);
        CHECK();
        rt.remove(o.as<Obj>(), ks);
    }
    CHECK();
    r[ip->a] = Value::boolean(true);
    NEXT(1);
}
Value op_setprop(Frame* f, const Ins* ip, Value* r) {
    set(*f->rt, r[ip->a], f->code->consts[ip->b].as<Str>(), r[ip->c]);
    CHECK();
    NEXT(1);
}
Value op_setidx(Frame* f, const Ins* ip, Value* r) {
    set(*f->rt, r[ip->a], r[ip->b], r[ip->b + 1]);
    CHECK();
    NEXT(1);
}

Value op_newarr(Frame* f, const Ins* ip, Value* r) {
    Arr* a = f->rt->array(ip->b);
    CHECK();
    r[ip->a] = val(a);
    NEXT(1);
}
Value op_apush(Frame* f, const Ins* ip, Value* r) {
    f->rt->push(r[ip->a].as<Arr>(), r[ip->b]);
    CHECK();
    NEXT(1);
}
Value op_ahole(Frame* f, const Ins* ip, Value* r) {
    f->rt->push(r[ip->a].as<Arr>(), Value::hole());
    CHECK();
    NEXT(1);
}

bool iterable(Rt& rt, Value v) {
    if (v.is(Kind::array) || v.is(Kind::string) || v.is(Kind::set))
        return true;
    Str* t = type_of(rt, v);
    char name[16];
    uint32_t n = 0;
    for (; t && n < t->length && n < 15; n++)
        name[n] = static_cast<char>(t->units[n]);
    name[n] = 0;
    rt.fail(ErrorKind::type, "a value of type %s is not iterable", name);
    return false;
}
bool step(Rt& rt, Value v, uint32_t& at, Value& out) {
    if (v.is(Kind::set))
        return lib::set_step(rt, v, at, out);
    if (v.is(Kind::array)) {
        Arr* a = v.as<Arr>();
        if (at >= a->length)
            return false;
        Value x = a->items[at++];
        out = x.is_hole() ? Value::undefined() : x;
        return true;
    }
    Str* s = v.as<Str>();
    if (at >= s->length)
        return false;
    uint32_t n = 1;
    char16_t c = s->units[at];
    if (c >= 0xD800 && c <= 0xDBFF && at + 1 < s->length && s->units[at + 1] >= 0xDC00 && s->units[at + 1] <= 0xDFFF)
        n = 2;
    Str* one = rt.str({&s->units[at], n});
    at += n;
    if (!one)
        return false;
    out = val(one);
    return true;
}
Value op_aspread(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    Value src = r[ip->b];
    if (!iterable(rt, src))
        CHECK();
    Arr* dst = r[ip->a].as<Arr>();
    uint32_t at = 0;
    Value x;
    while (step(rt, src, at, x))
        if (!rt.push(dst, x))
            break;
    CHECK();
    NEXT(1);
}

Value op_newobj(Frame* f, const Ins* ip, Value* r) {
    Obj* o = f->rt->object();
    CHECK();
    r[ip->a] = val(o);
    NEXT(1);
}
Value op_oput(Frame* f, const Ins* ip, Value* r) {
    f->rt->put(r[ip->a].as<Obj>(), f->code->consts[ip->b].as<Str>(), r[ip->c]);
    CHECK();
    NEXT(1);
}
Value op_oputk(Frame* f, const Ins* ip, Value* r) {
    Str* k = to_property_key(*f->rt, r[ip->b]);
    CHECK();
    f->rt->put(r[ip->a].as<Obj>(), k, r[ip->b + 1]);
    CHECK();
    NEXT(1);
}

Value op_ospread(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    Value src = r[ip->b];
    Obj* dst = r[ip->a].as<Obj>();
    if (src.is_cell()) {
        Arr* keys = own_keys(rt, src);
        CHECK();
        for (uint32_t i = 0; keys && i < keys->length; i++) {
            Str* k = keys->items[i].as<Str>();
            rt.put(dst, k, get(rt, src, k));
        }
    }
    CHECK();
    NEXT(1);
}

Value op_orest(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    Value src = r[ip->b];
    Obj* dst = r[ip->a].as<Obj>();
    Arr* taken = r[ip->c].as<Arr>();
    for (uint32_t i = 0; i < taken->length; i++) {
        Str* k = to_property_key(rt, taken->items[i]);
        CHECK();
        taken->items[i] = val(k);
    }
    if (src.is_cell()) {
        Arr* keys = own_keys(rt, src);
        CHECK();
        for (uint32_t i = 0; keys && i < keys->length; i++) {
            Str* k = keys->items[i].as<Str>();
            bool skip = false;
            for (uint32_t j = 0; j < taken->length && !skip; j++)
                skip = taken->items[j].as<Str>() == k;
            if (!skip)
                rt.put(dst, k, get(rt, src, k));
        }
    }
    CHECK();
    NEXT(1);
}
Value op_getname(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    Str* name = f->code->consts[ip->b].as<Str>();
    Value v = f->host->get(rt, name);
    CHECK();
    if (v.is_hole() && rt.globals)
        v = rt.get_own(rt.globals, name);
    if (v.is_hole()) {
        if (ip->c == 1)
            v = Value::undefined();
        else {
            char buf[80];
            uint32_t n = 0;
            for (; n < name->length && n < 79; n++)
                buf[n] = static_cast<char>(name->units[n] < 0x80 ? name->units[n] : '?');
            buf[n] = 0;
            rt.fail(ErrorKind::reference, "Can't find variable: %s", buf);
            CHECK();
        }
    }
    r[ip->a] = v;
    NEXT(1);
}
Value op_getbase(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = f->host->base(*f->rt, f->code->consts[ip->b].as<Str>());
    CHECK();
    NEXT(1);
}
Value op_setname(Frame* f, const Ins* ip, Value* r) {
    f->host->set(*f->rt, f->code->consts[ip->b].as<Str>(), r[ip->a]);
    CHECK();
    NEXT(1);
}

Env* new_env(Rt& rt, Env* parent, uint32_t size) {
    void* p = rt.arena.alloc(sizeof(Env) + sizeof(Value) * (size ? size - 1 : 0), alignof(Env));
    if (!p)
        return rt.fail(ErrorKind::internal, "out of memory"), nullptr;
    Env* e = static_cast<Env*>(p);
    e->h = Cell{0, Kind::env, 0, 0};
    e->parent = parent;
    e->size = size;
    for (uint32_t i = 0; i < size; i++)
        e->slots[i] = Value::undefined();
    return e;
}
Value op_newenv(Frame* f, const Ins* ip, Value* r) {
    Env* e = new_env(*f->rt, f->env, ip->b);
    CHECK();
    f->env = e;
    NEXT(1);
}
Value op_popenv(Frame* f, const Ins* ip, Value* r) {
    f->env = f->env->parent;
    NEXT(1);
}
Value op_copyenv(Frame* f, const Ins* ip, Value* r) {
    Env* e = new_env(*f->rt, f->env->parent, f->env->size);
    CHECK();
    for (uint32_t i = 0; i < e->size; i++)
        e->slots[i] = f->env->slots[i];
    f->env = e;
    NEXT(1);
}
Env* up(Env* e, uint32_t n) {
    while (n--)
        e = e->parent;
    return e;
}
void tdz(Frame* f, Str* name) {
    char buf[80];
    uint32_t n = 0;
    for (; name && n < name->length && n < 79; n++)
        buf[n] = static_cast<char>(name->units[n] < 0x80 ? name->units[n] : '?');
    buf[n] = 0;
    f->rt->fail(ErrorKind::reference, "Cannot access '%s' before initialization.", buf);
}
Value op_getenv(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = up(f->env, ip->b)->slots[ip->c];
    NEXT(1);
}
Value op_getenvchk(Frame* f, const Ins* ip, Value* r) {
    Value v = up(f->env, ip->b)->slots[ip->c];
    if (v.is_hole()) {
        tdz(f, f->code->consts[ip[1].a].as<Str>());
        [[clang::musttail]] return unwind(f, ip, r);
    }
    r[ip->a] = v;
    NEXT(2);
}
Value op_setenv(Frame* f, const Ins* ip, Value* r) {
    up(f->env, ip->b)->slots[ip->c] = r[ip->a];
    NEXT(1);
}
Value op_chk(Frame* f, const Ins* ip, Value* r) {
    if (r[ip->a].is_hole()) {
        tdz(f, f->code->consts[ip->b].as<Str>());
        [[clang::musttail]] return unwind(f, ip, r);
    }
    NEXT(1);
}

Value op_closure(Frame* f, const Ins* ip, Value* r) {
    Fn* fn = f->rt->arena.make<Fn>();
    if (!fn) {
        f->rt->fail(ErrorKind::internal, "out of memory");
        CHECK();
    }
    fn->h = Cell{0, Kind::function, 0, 0};
    fn->code = f->code->children[ip->b];
    fn->env = f->env;
    fn->host = f->host;
    r[ip->a] = val(fn);
    NEXT(1);
}

bool not_callable(Frame* f, const Ins* ip, Value fn) {
    if (fn.is(Kind::function) || fn.is(Kind::native))
        return false;
    const Code* c = f->code;
    uint32_t i = static_cast<uint32_t>(ip - c->ins);
    if (!c->ends || !c->ends[i] || !c->ends[i + 1] || c->ends[i] > c->src.size())
        return false;
    std::string_view call = c->src.substr(c->pos[i], c->ends[i] - c->pos[i]);
    std::string_view callee = call.substr(0, c->ends[i + 1] > c->pos[i] ? c->ends[i + 1] - c->pos[i] : 0);
    char what[96];
    if (fn.is_undefined() || fn.is_hole())
        std::snprintf(what, sizeof what, "undefined");
    else if (fn.is_null())
        std::snprintf(what, sizeof what, "null");
    else if (fn.is_bool())
        std::snprintf(what, sizeof what, "%s", fn.is_true() ? "true" : "false");
    else if (fn.is_num()) {
        char16_t b[40];
        size_t n = num::to_string(fn.as_num(), b);
        for (size_t k = 0; k < n; k++)
            what[k] = static_cast<char>(b[k]);
        what[n] = 0;
    } else if (fn.is(Kind::string)) {
        Str* s = fn.as<Str>();
        size_t k = 0;
        what[k++] = '"';
        for (uint32_t j = 0; j < s->length && k < sizeof what - 2; j++)
            what[k++] = static_cast<char>(s->units[j] < 0x80 ? s->units[j] : '?');
        what[k++] = '"', what[k] = 0;
    } else
        std::snprintf(what, sizeof what, "an instance of %s", fn.is(Kind::array) ? "Array" : "Object");
    f->rt->fail(ErrorKind::type, "%.*s is not a function. (In '%.*s', '%.*s' is %s)", static_cast<int>(callee.size()),
                callee.data(), static_cast<int>(call.size()), call.data(), static_cast<int>(callee.size()),
                callee.data(), what);
    return true;
}

Value op_call(Frame* f, const Ins* ip, Value* r) {
    uint32_t argc = ip[1].a;
    if (--f->vm->budget <= 0) [[unlikely]] {
        f->rt->fail(ErrorKind::internal, "the job ran past its time budget");
        CHECK();
    }
    if (not_callable(f, ip, r[ip->b])) [[unlikely]] {
        CHECK();
    }
    Value v = f->vm->call(r[ip->b], r[ip->c], &r[ip->c + 1], argc);
    CHECK();
    r[ip->a] = v;
    NEXT(2);
}
Value op_callspread(Frame* f, const Ins* ip, Value* r) {
    if (--f->vm->budget <= 0) [[unlikely]] {
        f->rt->fail(ErrorKind::internal, "the job ran past its time budget");
        CHECK();
    }
    Arr* args = r[ip->c + 1].as<Arr>();
    Value v = f->vm->call(r[ip->b], r[ip->c], args->items, args->length);
    CHECK();
    r[ip->a] = v;
    NEXT(1);
}
Value op_newcall(Frame* f, const Ins* ip, Value* r) {
    Value ctor = r[ip->b];
    uint32_t argc = ip[1].a;
    if (!ctor.is(Kind::native) || !ctor.as<Native>()->construct) {
        f->rt->fail(ErrorKind::type, "the value is not a constructor");
        CHECK();
    }
    Value v = ctor.as<Native>()->construct(*f->vm, Value::undefined(), &r[ip->c + 1], argc);
    CHECK();
    r[ip->a] = v;
    NEXT(2);
}
Value op_ret(Frame* f, const Ins* ip, Value* r) {
    (void)f;
    return r[ip->a];
}
Value op_tryenter(Frame* f, const Ins* ip, Value* r) {
    if (f->n_handlers == 16) {
        f->rt->fail(ErrorKind::internal, "try nested more than 16 deep in one function");
        CHECK();
    }
    f->handlers[f->n_handlers++] = Handler{TARGET(*ip), ip->a, f->env};
    NEXT(1);
}
Value op_tryleave(Frame* f, const Ins* ip, Value* r) {
    f->n_handlers--;
    NEXT(1);
}
Value op_keys(Frame* f, const Ins* ip, Value* r) {
    Value src = r[ip->b];
    Arr* k = src.is_nullish() ? f->rt->array(0) : own_keys(*f->rt, src);
    CHECK();
    r[ip->a] = val(k);
    NEXT(1);
}
Value op_iter(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    Value src = r[ip->b];
    if (!iterable(rt, src))
        CHECK();
    Iter* it = rt.arena.make<Iter>();
    if (!it)
        rt.fail(ErrorKind::internal, "out of memory");
    CHECK();
    it->h = Cell{0, Kind::iterator, 0, 0};
    it->src = src;
    r[ip->a] = Value::cell(&it->h);
    NEXT(1);
}
Value op_next(Frame* f, const Ins* ip, Value* r) {
    Iter* it = r[ip->b].as<Iter>();
    Value x;
    if (!step(*f->rt, it->src, it->at, x)) {
        CHECK();
        JUMP(TARGET(ip[1]));
    }
    r[ip->a] = x;
    NEXT(2);
}
Value op_regex(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    Value v = lib::regexp_literal(rt, f->code->consts[ip->b].as<Str>(), f->code->consts[ip->c].as<Str>());
    CHECK();
    r[ip->a] = v;
    NEXT(1);
}
Value op_argc(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = Value::num(f->argc);
    NEXT(1);
}
Value op_rest(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    Arr* a = rt.array(f->argc > ip->b ? f->argc - ip->b : 0);
    CHECK();
    for (uint32_t i = ip->b; i < f->argc; i++)
        rt.push(a, f->args[i]);
    CHECK();
    r[ip->a] = val(a);
    NEXT(1);
}
Value op_arg(Frame* f, const Ins* ip, Value* r) {
    r[ip->a] = ip->b == 0xFFFF ? f->callee : ip->b < f->argc ? f->args[ip->b] : Value::undefined();
    NEXT(1);
}
Value op_throwtdz(Frame* f, const Ins* ip, Value* r) {
    {
        tdz(f, f->code->consts[ip->a].as<Str>());
        [[clang::musttail]] return unwind(f, ip, r);
    }
}
Value op_fail_(Frame* f, const Ins* ip, Value* r) {
    Rt& rt = *f->rt;
    if (ip->a == 0xFFFF) {
        rt.fail(ErrorKind::type, "rethrown");
        rt.thrown = r[ip->b];
    } else {
        Str* m = f->code->consts[ip->a].as<Str>();
        char buf[200];
        uint32_t n = 0;
        for (; m && n < m->length && n < 199; n++)
            buf[n] = static_cast<char>(m->units[n] < 0x80 ? m->units[n] : '?');
        buf[n] = 0;
        rt.fail(ErrorKind::type, "%s", buf);
    }
    CHECK();
    NEXT(1);
}
Value op_halt(Frame* f, const Ins* ip, Value* r) {
    (void)ip, (void)r;
    f->rt->fail(ErrorKind::internal, "the bytecode ran into a pseudo-instruction");
    return Value::undefined();
}

const Fn_ k_table[] = {
#define RX_ENTRY(n) op_##n,
    RX_OPS(RX_ENTRY)
#undef RX_ENTRY
};
static_assert(sizeof k_table / sizeof *k_table == static_cast<size_t>(Op::count_));

}

Value run_code(Vm& vm, const Code* code, Env* env, Value callee, const Value* args, uint32_t argc,
               Host* host) noexcept {
    Rt& rt = vm.rt;
    if (vm.depth >= Vm::k_max_depth)
        return rt.fail(ErrorKind::range, "Maximum call stack size exceeded.");
    if (!vm.stack) {
        vm.cap = 1u << 16;
        vm.stack = rt.perm.array<Value>(vm.cap);
        if (!vm.stack)
            return rt.fail(ErrorKind::internal, "out of memory");
    }
    if (vm.sp + code->n_regs > vm.cap)
        return rt.fail(ErrorKind::range, "Maximum call stack size exceeded.");
    Value* r = vm.stack + vm.sp;
    vm.sp += code->n_regs;
    for (uint32_t i = 0; i < code->n_regs; i++)
        r[i] = i < code->n_params && i < argc ? args[i] : Value::undefined();
    Frame f{&vm, &rt, code, env, callee, args, argc, host ? host : &vm.host, {}, 0};
    vm.depth++;
    Value out = k_table[static_cast<int>(code->ins[0].op)](&f, code->ins, r);
    vm.depth--;
    vm.sp -= code->n_regs;
    return out;
}

Value Vm::run(const Code* code, const Value* args, uint32_t argc, Host* in) noexcept {
    return run_code(*this, code, nullptr, Value::undefined(), args, argc, in);
}

Value Vm::call(Value fn, Value receiver, const Value* args, uint32_t argc) noexcept {
    if (fn.is(Kind::native)) {
        if (++depth > k_max_depth) {
            depth--;
            return rt.fail(ErrorKind::range, "Maximum call stack size exceeded.");
        }
        Native* n = fn.as<Native>();
        Value v = lib::is_promise_resolver(n) ? lib::promise_resolver(*this, n, args, argc)
            : lib::is_finally(n)              ? lib::finally_run(*this, n, args, argc)
                                              : (native = n, n->fn(*this, receiver, args, argc));
        depth--;
        return v;
    }
    if (fn.is(Kind::function)) {
        Fn* f = fn.as<Fn>();
        return run_code(*this, f->code, f->env, fn, args, argc, f->host);
    }
    Str* t = type_of(rt, fn);
    char name[16];
    uint32_t n = 0;
    for (; t && n < t->length && n < 15; n++)
        name[n] = static_cast<char>(t->units[n]);
    name[n] = 0;
    return rt.fail(ErrorKind::type, "a value of type %s is not a function", name);
}

}
