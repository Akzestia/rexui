// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <cmath>
#include <cstring>

#include "engine/vm/gc.h"
#include "engine/vm/lib.h"
#include "engine/vm/regex.h"

namespace rx::engine::vm {

struct RegExpObj {
    Cell h;
    Str* source;
    Str* flags_text;
    uint8_t flags;
    re::Compiled re;
    Value last_index;
};

Value lib_regexp_get(Rt& rt, Value v, Str* key) noexcept {
    RegExpObj* r = v.as<RegExpObj>();
    auto is = [&](const char* name) { return key->view() == std::u16string_view(rt.str_ascii(name)->view()); };
    if (is("lastIndex"))
        return r->last_index;
    if (is("source"))
        return val(r->source->length ? r->source : rt.str_ascii("(?:)"));
    if (is("flags"))
        return val(r->flags_text);
    if (is("global"))
        return Value::boolean(r->flags & re::f_global);
    if (is("ignoreCase"))
        return Value::boolean(r->flags & re::f_ignore_case);
    if (is("multiline"))
        return Value::boolean(r->flags & re::f_multiline);
    if (is("dotAll"))
        return Value::boolean(r->flags & re::f_dot_all);
    if (is("sticky"))
        return Value::boolean(r->flags & re::f_sticky);
    if (is("hasIndices"))
        return Value::boolean(r->flags & re::f_indices);
    if (is("unicode") || is("unicodeSets"))
        return Value::boolean(false);
    return Value::hole();
}
bool lib_regexp_set(Rt& rt, Value v, Str* key, Value x) noexcept {
    if (key->view() == std::u16string_view(rt.str_ascii("lastIndex")->view()))
        v.as<RegExpObj>()->last_index = x;
    return true;
}

namespace lib {
namespace {

using sv16 = std::u16string_view;

RegExpObj* as_re(Value v) {
    return v.is(Kind::regexp) ? v.as<RegExpObj>() : nullptr;
}

Str* flags_text(Rt& rt, uint8_t f) {
    char b[8];
    int n = 0;
    if (f & re::f_indices)
        b[n++] = 'd';
    if (f & re::f_global)
        b[n++] = 'g';
    if (f & re::f_ignore_case)
        b[n++] = 'i';
    if (f & re::f_multiline)
        b[n++] = 'm';
    if (f & re::f_dot_all)
        b[n++] = 's';
    if (f & re::f_sticky)
        b[n++] = 'y';
    return rt.str_ascii({b, static_cast<size_t>(n)});
}

Value make(Rt& rt, Str* pattern, Str* flags) {
    uint8_t f;
    if (!re::parse_flags(flags->view(), f))
        return rt.fail(ErrorKind::syntax, "Invalid flags supplied to RegExp constructor.");
    re::Compiled* c = nullptr;
    for (const Rt::RegexCache& k : rt.regexes)
        if (k.pattern == pattern && k.flags == flags) {
            if (!k.compiled)
                return rt.fail(ErrorKind::syntax, "Invalid regular expression");
            c = static_cast<re::Compiled*>(k.compiled);
        }
    if (!c) {
        c = rt.perm.make<re::Compiled>();
        char16_t* units = rt.perm.array<char16_t>(pattern->length);
        re::Error err{};
        if (units)
            std::memcpy(units, pattern->units, sizeof(char16_t) * pattern->length);
        if (!c || !units || !re::compile(std::u16string_view(units, pattern->length), f, rt.perm, *c, err)) {
            (void)rt.regexes.push(rt.perm, Rt::RegexCache{pattern, flags, nullptr, nullptr});
            return rt.fail(ErrorKind::syntax, "Invalid regular expression: %.*s", static_cast<int>(err.msg.size()),
                           err.msg.data());
        }
        (void)rt.regexes.push(rt.perm, Rt::RegexCache{pattern, flags, c, nullptr});
    }
    RegExpObj* r = rt.arena.make<RegExpObj>();
    if (!r)
        return rt.fail(ErrorKind::internal, "out of memory");
    r->h = Cell{0, Kind::regexp, 0, 0};
    r->source = pattern;
    r->flags = f;
    r->flags_text = flags_text(rt, f);
    r->re = *c;
    r->last_index = Value::num(0);
    return Value::cell(&r->h);
}

Value exec(Vm& vm, RegExpObj* r, Str* S, int32_t* caps_out = nullptr) {
    Rt& rt = vm.rt;
    bool g = r->flags & re::f_global, y = r->flags & re::f_sticky;
    double li = 0;
    if (g || y) {
        li = to_integer(rt, r->last_index);
        if (rt.failed)
            return Value::undefined();
        if (li < 0)
            li = 0;
    }
    uint32_t n = (r->re.n_groups + 1) * 2;
    int32_t local[64];
    int32_t* caps = n <= 64 ? local : rt.arena.array<int32_t>(n);
    if (!caps)
        return rt.fail(ErrorKind::internal, "out of memory");
    sv16 s = S->view();
    for (;;) {
        if (li > s.size()) {
            if (g || y)
                r->last_index = Value::num(0);
            return Value::null();
        }
        re::Result m = re::match(r->re, s, static_cast<uint32_t>(li), caps, vm.budget);
        if (m == re::Result::budget)
            return rt.fail(ErrorKind::internal, "the job ran past its time budget (a regular expression)");
        if (m == re::Result::match)
            break;
        if (y) {
            r->last_index = Value::num(0);
            return Value::null();
        }
        li += 1;
    }
    if (g || y)
        r->last_index = Value::num(caps[1]);
    if (caps_out)
        for (uint32_t k = 0; k < n; k++)
            caps_out[k] = caps[k];
    Arr* a = rt.array(r->re.n_groups + 1);
    if (!a)
        return Value::undefined();
    for (uint32_t k = 0; k <= r->re.n_groups; k++) {
        if (caps[2 * k] < 0)
            rt.push(a, Value::undefined());
        else
            rt.push(a,
                    val(rt.str(s.substr(static_cast<size_t>(caps[2 * k]),
                                        static_cast<size_t>(caps[2 * k + 1] - caps[2 * k])))));
    }
    a->props = rt.object();
    if (!a->props)
        return Value::undefined();
    rt.put(a->props, rt.atom(rt.str_ascii("index")), Value::num(caps[0]));
    rt.put(a->props, rt.atom(rt.str_ascii("input")), val(S));
    bool named = false;
    for (uint32_t k = 1; k <= r->re.n_groups; k++)
        named = named || !r->re.names[k].empty();
    Value groups = Value::undefined();
    if (named) {
        Obj* o = rt.object();
        if (!o)
            return Value::undefined();
        for (uint32_t k = 1; k <= r->re.n_groups; k++)
            if (!r->re.names[k].empty())
                rt.put(o, rt.atom(r->re.names[k]), a->items[k]);
        groups = val(o);
    }
    rt.put(a->props, rt.atom(rt.str_ascii("groups")), groups);
    return rt.failed ? Value::undefined() : val(a);
}

#define THIS_RE(method)         \
    Rt& rt = vm.rt;             \
    RegExpObj* R = as_re(self); \
    if (!R)                     \
    return rt.fail(ErrorKind::type, "RegExp.prototype.%s requires that 'this' be a RegExp object", method)

Value r_exec(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_RE("exec");
    Str* S = to_string(rt, arg(args, argc, 0));
    return S ? exec(vm, R, S) : Value::undefined();
}
Value r_test(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_RE("test");
    Str* S = to_string(rt, arg(args, argc, 0));
    if (!S)
        return Value::undefined();
    Value m = exec(vm, R, S);
    return rt.failed ? Value::undefined() : Value::boolean(!m.is_null());
}
Value r_tostring(Vm& vm, Value self, const Value*, uint32_t) {
    THIS_RE("toString");
    Str* src = R->source->length ? R->source : rt.str_ascii("(?:)");
    Str* out = rt.concat(rt.concat(rt.concat(rt.str_ascii("/"), src), rt.str_ascii("/")), R->flags_text);
    return out ? val(out) : Value::undefined();
}
Value regexp_ctor(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value p = arg(args, argc, 0), f = arg(args, argc, 1);
    Str *pattern, *flags;
    if (RegExpObj* r = as_re(p)) {
        pattern = r->source;
        flags = f.is_undefined() ? r->flags_text : to_string(rt, f);
    } else {
        pattern = p.is_undefined() ? rt.empty : to_string(rt, p);
        flags = f.is_undefined() ? rt.empty : to_string(rt, f);
    }
    if (!pattern || !flags)
        return Value::undefined();
    return make(rt, rt.atom(pattern), rt.atom(flags));
}

}

Value regexp_literal(Rt& rt, Str* pattern, Str* flags) noexcept {
    return make(rt, pattern, flags);
}

bool regex_global(Value re) noexcept {
    return as_re(re) && (as_re(re)->flags & re::f_global);
}

Value regex_split(Vm& vm, Str* S, Value rv, Value limit) noexcept {
    Rt& rt = vm.rt;
    RegExpObj* R = as_re(rv);
    uint32_t lim = limit.is_undefined() ? 0xFFFFFFFFu : num::to_uint32(to_number(rt, limit));
    Arr* A = rt.array(0);
    if (!A || rt.failed)
        return Value::undefined();
    if (!lim)
        return val(A);
    sv16 s = S->view();
    uint32_t size = static_cast<uint32_t>(s.size());
    uint32_t n = (R->re.n_groups + 1) * 2;
    int32_t local[64];
    int32_t* caps = n <= 64 ? local : rt.arena.array<int32_t>(n);
    if (!caps)
        return rt.fail(ErrorKind::internal, "out of memory");
    auto at = [&](uint32_t q) {
        re::Result m = re::match(R->re, s, q, caps, vm.budget);
        if (m == re::Result::budget)
            rt.fail(ErrorKind::internal, "the job ran past its time budget (a regular expression)");
        return m == re::Result::match;
    };
    if (!size) {
        if (!at(0) && !rt.failed)
            rt.push(A, val(S));
        return rt.failed ? Value::undefined() : val(A);
    }
    uint32_t p = 0, q = 0;
    while (q < size) {
        if (!at(q)) {
            if (rt.failed)
                return Value::undefined();
            q++;
            continue;
        }
        uint32_t e = static_cast<uint32_t>(caps[1]) < size ? static_cast<uint32_t>(caps[1]) : size;
        if (e == p) {
            q++;
            continue;
        }
        rt.push(A, val(rt.str(s.substr(p, q - p))));
        if (A->length == lim)
            return val(A);
        p = e;
        for (uint32_t k = 1; k <= R->re.n_groups; k++) {
            if (caps[2 * k] < 0)
                rt.push(A, Value::undefined());
            else
                rt.push(A,
                        val(rt.str(s.substr(static_cast<size_t>(caps[2 * k]),
                                            static_cast<size_t>(caps[2 * k + 1] - caps[2 * k])))));
            if (A->length == lim)
                return val(A);
        }
        q = p;
    }
    rt.push(A, val(rt.str(s.substr(p))));
    return rt.failed ? Value::undefined() : val(A);
}

Value regex_replace(Vm& vm, Str* S, Value rv, Value rep, bool all) noexcept {
    (void)all;
    Rt& rt = vm.rt;
    RegExpObj* R = as_re(rv);
    bool global = R->flags & re::f_global;
    bool fn = callable(rep);
    Str* repl = fn ? nullptr : to_string(rt, rep);
    if (!fn && !repl)
        return Value::undefined();
    if (global)
        R->last_index = Value::num(0);
    sv16 s = S->view();
    List<Value> results;
    for (;;) {
        Value m = exec(vm, R, S);
        if (rt.failed)
            return Value::undefined();
        if (m.is_null())
            break;
        (void)results.push(rt.arena, m);
        if (!global)
            break;
        Arr* a = m.as<Arr>();
        if (a->items[0].as<Str>()->length == 0) {
            double li = to_integer(rt, R->last_index);
            R->last_index = Value::num(li + 1);
        }
    }
    Str* out = rt.empty;
    size_t next = 0;
    for (Value m : results) {
        Arr* a = m.as<Arr>();
        Str* matched = a->items[0].as<Str>();
        double position = to_integer(rt, rt.get_own(a->props, rt.atom(rt.str_ascii("index"))));
        position = std::fmax(std::fmin(position, static_cast<double>(s.size())), 0);
        size_t pos = static_cast<size_t>(position);
        uint32_t ncap = a->length - 1;
        Value groups = rt.get_own(a->props, rt.atom(rt.str_ascii("groups")));
        Str* replacement;
        if (fn) {
            Value* args = rt.arena.array<Value>(ncap + 4);
            if (!args)
                return rt.fail(ErrorKind::internal, "out of memory");
            uint32_t k = 0;
            args[k++] = val(matched);
            for (uint32_t c = 1; c <= ncap; c++)
                args[k++] = a->items[c];
            args[k++] = Value::num(static_cast<double>(pos));
            args[k++] = val(S);
            if (!groups.is_undefined() && !groups.is_hole())
                args[k++] = groups;
            Value r = vm.call(rep, Value::undefined(), args, k);
            if (rt.failed)
                return Value::undefined();
            replacement = to_string(rt, r);
        } else {
            replacement = substitution(rt, matched->view(), s, pos, a->items + 1, ncap, repl->view(),
                                       groups.is_hole() ? Value::undefined() : groups);
        }
        if (!replacement)
            return Value::undefined();
        if (pos >= next) {
            out = rt.concat(rt.concat(out, rt.str(s.substr(next, pos - next))), replacement);
            next = pos + matched->length;
        }
    }
    if (next < s.size())
        out = rt.concat(out, rt.str(s.substr(next)));
    return out ? val(out) : Value::undefined();
}

Value regex_search(Vm& vm, Str* S, Value rv) noexcept {
    Rt& rt = vm.rt;
    RegExpObj* R = as_re(rv);
    if (!R) {
        Str* src = rv.is_undefined() ? rt.empty : to_string(rt, rv);
        if (!src)
            return Value::undefined();
        Value made = make(rt, rt.atom(src), rt.empty);
        if (rt.failed)
            return Value::undefined();
        R = made.as<RegExpObj>();
    }
    Value prev = R->last_index;
    R->last_index = Value::num(0);
    Value m = exec(vm, R, S);
    R->last_index = prev;
    if (rt.failed)
        return Value::undefined();
    if (m.is_null())
        return Value::num(-1);
    return rt.get_own(m.as<Arr>()->props, rt.atom(rt.str_ascii("index")));
}

Value regex_match(Vm& vm, Str* S, Value rv) noexcept {
    Rt& rt = vm.rt;
    RegExpObj* R = as_re(rv);
    if (!R) {
        Str* src = rv.is_undefined() ? rt.empty : to_string(rt, rv);
        if (!src)
            return Value::undefined();
        Value made = make(rt, rt.atom(src), rt.empty);
        if (rt.failed)
            return Value::undefined();
        R = made.as<RegExpObj>();
    }
    if (!(R->flags & re::f_global))
        return exec(vm, R, S);
    R->last_index = Value::num(0);
    Arr* A = rt.array(0);
    if (!A)
        return Value::undefined();
    for (;;) {
        Value m = exec(vm, R, S);
        if (rt.failed)
            return Value::undefined();
        if (m.is_null())
            return A->length ? val(A) : Value::null();
        Str* t = m.as<Arr>()->items[0].as<Str>();
        rt.push(A, val(t));
        if (!t->length)
            R->last_index = Value::num(to_integer(rt, R->last_index) + 1);
    }
}

Value regex_match_all(Vm& vm, Str* S, Value rv) noexcept {
    Rt& rt = vm.rt;
    RegExpObj* R = as_re(rv);
    if (R && !(R->flags & re::f_global))
        return rt.fail(ErrorKind::type, "String.prototype.matchAll called with a non-global RegExp argument");
    if (!R) {
        Str* src = rv.is_undefined() ? rt.empty : to_string(rt, rv);
        if (!src)
            return Value::undefined();
        Str* flags = rt.str_ascii("g");
        Value made = flags ? make(rt, rt.atom(src), rt.atom(flags)) : Value::undefined();
        if (rt.failed)
            return Value::undefined();
        R = made.as<RegExpObj>();
    }
    R->last_index = Value::num(0);
    Arr* A = rt.array(0);
    if (!A)
        return Value::undefined();
    for (;;) {
        Value m = exec(vm, R, S);
        if (rt.failed)
            return Value::undefined();
        if (m.is_null())
            return val(A);
        rt.push(A, m);
        if (!m.as<Arr>()->items[0].as<Str>()->length)
            R->last_index = Value::num(to_integer(rt, R->last_index) + 1);
    }
}

void install_regex(Rt& rt, Obj* proto) noexcept {
    def(rt, proto, "exec", r_exec, 1);
    def(rt, proto, "test", r_test, 1);
    def(rt, proto, "toString", r_tostring, 0);
    Native* ctor = rt.native("RegExp", regexp_ctor, 2, regexp_ctor);
    if (ctor)
        rt.put(rt.globals, ctor->name, val(ctor));
}

size_t gc_regexp_size() noexcept {
    return sizeof(RegExpObj);
}
void gc_regexp_trace(Cell* c, Gc& gc) noexcept {
    RegExpObj* r = reinterpret_cast<RegExpObj*>(c);
    r->source = gc.of(r->source);
    r->flags_text = gc.of(r->flags_text);
    r->last_index = gc.value(r->last_index);
}

}
}
