// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <cmath>

#include "engine/vm/lib.h"

namespace rx::engine::vm::lib {
namespace {

using sv16 = std::u16string_view;

Value str(Rt& rt, sv16 s) {
    Str* x = rt.str(s);
    return x ? val(x) : Value::undefined();
}
bool js_space(char16_t c) {
    switch (c) {
    case 0x09:
    case 0x0A:
    case 0x0B:
    case 0x0C:
    case 0x0D:
    case 0x20:
    case 0xA0:
    case 0x1680:
    case 0x2028:
    case 0x2029:
    case 0x202F:
    case 0x205F:
    case 0x3000:
    case 0xFEFF:
        return true;
    default:
        return c >= 0x2000 && c <= 0x200A;
    }
}
size_t find_at(sv16 s, sv16 t, size_t from) {
    if (t.empty())
        return from <= s.size() ? from : sv16::npos;
    return s.find(t, from);
}

#define SELF(method)                        \
    Rt& rt = vm.rt;                         \
    Str* S = this_string(vm, self, method); \
    if (!S)                                 \
        return Value::undefined();          \
    sv16 s = S->view();                     \
    (void)s, (void)rt

Value s_slice(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("slice");
    uint32_t len = S->length;
    uint32_t from = relative(to_integer(rt, arg(args, argc, 0)), len);
    Value e = arg(args, argc, 1);
    uint32_t to = e.is_undefined() ? len : relative(to_integer(rt, e), len);
    if (rt.failed)
        return Value::undefined();
    return from >= to ? val(rt.empty) : str(rt, s.substr(from, to - from));
}
Value s_substring(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("substring");
    double len = S->length;
    double a = to_integer(rt, arg(args, argc, 0));
    Value e = arg(args, argc, 1);
    double b = e.is_undefined() ? len : to_integer(rt, e);
    if (rt.failed)
        return Value::undefined();
    a = std::fmin(std::fmax(a, 0), len), b = std::fmin(std::fmax(b, 0), len);
    uint32_t from = static_cast<uint32_t>(std::fmin(a, b)), to = static_cast<uint32_t>(std::fmax(a, b));
    return str(rt, s.substr(from, to - from));
}
Value s_substr(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("substr");
    double size = S->length;
    double start = to_integer(rt, arg(args, argc, 0));
    if (start == -INFINITY)
        start = 0;
    else if (start < 0)
        start = std::fmax(size + start, 0);
    else
        start = std::fmin(start, size);
    Value l = arg(args, argc, 1);
    double length = l.is_undefined() ? size : to_integer(rt, l);
    if (rt.failed)
        return Value::undefined();
    length = std::fmin(std::fmax(length, 0), size);
    double end = std::fmin(start + length, size);
    if (start >= end)
        return val(rt.empty);
    return str(rt, s.substr(static_cast<size_t>(start), static_cast<size_t>(end - start)));
}
Value s_charat(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("charAt");
    double p = to_integer(rt, arg(args, argc, 0));
    if (rt.failed)
        return Value::undefined();
    if (p < 0 || p >= S->length)
        return val(rt.empty);
    return str(rt, s.substr(static_cast<size_t>(p), 1));
}
Value s_charcodeat(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("charCodeAt");
    double p = to_integer(rt, arg(args, argc, 0));
    if (rt.failed)
        return Value::undefined();
    if (p < 0 || p >= S->length)
        return Value::num(NAN);
    return Value::num(s[static_cast<size_t>(p)]);
}
Value s_codepointat(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("codePointAt");
    double p = to_integer(rt, arg(args, argc, 0));
    if (rt.failed)
        return Value::undefined();
    if (p < 0 || p >= S->length)
        return Value::undefined();
    size_t i = static_cast<size_t>(p);
    char16_t c = s[i];
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.size() && s[i + 1] >= 0xDC00 && s[i + 1] <= 0xDFFF)
        return Value::num(0x10000 + ((c - 0xD800) << 10) + (s[i + 1] - 0xDC00));
    return Value::num(c);
}

bool not_regex(Rt& rt, Value v, const char* method) {
    if (v.is(Kind::regexp)) {
        rt.fail(ErrorKind::type, "First argument to String.prototype.%s must not be a regular expression", method);
        return false;
    }
    return true;
}
Value s_indexof(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("indexOf");
    Str* t = to_string(rt, arg(args, argc, 0));
    double pos = to_integer(rt, arg(args, argc, 1));
    if (!t || rt.failed)
        return Value::undefined();
    size_t from = static_cast<size_t>(std::fmin(std::fmax(pos, 0), S->length));
    size_t at = find_at(s, t->view(), from);
    return Value::num(at == sv16::npos ? -1.0 : static_cast<double>(at));
}
Value s_lastindexof(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("lastIndexOf");
    Str* t = to_string(rt, arg(args, argc, 0));
    double n = to_number(rt, arg(args, argc, 1));
    if (!t || rt.failed)
        return Value::undefined();
    double pos = n != n ? INFINITY : std::trunc(n);
    size_t len = S->length, tl = t->length;
    size_t start = static_cast<size_t>(std::fmin(std::fmax(pos, 0), static_cast<double>(len)));
    if (tl > len)
        return Value::num(-1);
    for (size_t k = std::min(start, len - tl) + 1; k-- > 0;)
        if (s.substr(k, tl) == t->view())
            return Value::num(static_cast<double>(k));
    return Value::num(-1);
}
Value s_includes(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("includes");
    if (!not_regex(rt, arg(args, argc, 0), "includes"))
        return Value::undefined();
    Str* t = to_string(rt, arg(args, argc, 0));
    double pos = to_integer(rt, arg(args, argc, 1));
    if (!t || rt.failed)
        return Value::undefined();
    size_t from = static_cast<size_t>(std::fmin(std::fmax(pos, 0), S->length));
    return Value::boolean(find_at(s, t->view(), from) != sv16::npos);
}
Value s_startswith(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("startsWith");
    if (!not_regex(rt, arg(args, argc, 0), "startsWith"))
        return Value::undefined();
    Str* t = to_string(rt, arg(args, argc, 0));
    double pos = to_integer(rt, arg(args, argc, 1));
    if (!t || rt.failed)
        return Value::undefined();
    size_t start = static_cast<size_t>(std::fmin(std::fmax(pos, 0), S->length));
    return Value::boolean(s.substr(start).starts_with(t->view()));
}
Value s_endswith(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("endsWith");
    if (!not_regex(rt, arg(args, argc, 0), "endsWith"))
        return Value::undefined();
    Str* t = to_string(rt, arg(args, argc, 0));
    Value e = arg(args, argc, 1);
    double pos = e.is_undefined() ? S->length : to_integer(rt, e);
    if (!t || rt.failed)
        return Value::undefined();
    size_t end = static_cast<size_t>(std::fmin(std::fmax(pos, 0), S->length));
    return Value::boolean(s.substr(0, end).ends_with(t->view()));
}
Value trim_(Vm& vm, Value self, bool start, bool end, const char* method) {
    SELF(method);
    size_t b = 0, e = s.size();
    if (start)
        while (b < e && js_space(s[b]))
            b++;
    if (end)
        while (e > b && js_space(s[e - 1]))
            e--;
    if (b == 0 && e == s.size())
        return val(S);
    return str(rt, s.substr(b, e - b));
}
Value s_trim(Vm& vm, Value self, const Value*, uint32_t) {
    return trim_(vm, self, true, true, "trim");
}
Value s_trimstart(Vm& vm, Value self, const Value*, uint32_t) {
    return trim_(vm, self, true, false, "trimStart");
}
Value s_trimend(Vm& vm, Value self, const Value*, uint32_t) {
    return trim_(vm, self, false, true, "trimEnd");
}
Value pad(Vm& vm, Value self, const Value* args, uint32_t argc, bool at_start, const char* method) {
    SELF(method);
    double max = to_integer(rt, arg(args, argc, 0));
    if (rt.failed)
        return Value::undefined();
    if (max <= S->length)
        return val(S);
    Value f = arg(args, argc, 1);
    Str* fill = f.is_undefined() ? rt.str_ascii(" ") : to_string(rt, f);
    if (!fill)
        return Value::undefined();
    if (!fill->length)
        return val(S);
    if (max > 0x3FFFFFFF)
        return rt.fail(ErrorKind::range, "Out of memory");
    size_t need = static_cast<size_t>(max) - S->length;
    char16_t* buf = rt.arena.array<char16_t>(static_cast<size_t>(max));
    if (!buf)
        return rt.fail(ErrorKind::internal, "out of memory");
    size_t n = 0;
    if (!at_start)
        for (char16_t c : s)
            buf[n++] = c;
    for (size_t k = 0; k < need; k++)
        buf[n++] = fill->units[k % fill->length];
    if (at_start)
        for (char16_t c : s)
            buf[n++] = c;
    return str(rt, {buf, n});
}
Value s_padstart(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return pad(vm, self, args, argc, true, "padStart");
}
Value s_padend(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return pad(vm, self, args, argc, false, "padEnd");
}
Value s_repeat(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("repeat");
    double n = to_integer(rt, arg(args, argc, 0));
    if (rt.failed)
        return Value::undefined();
    if (n < 0 || std::isinf(n))
        return rt.fail(ErrorKind::range,
                       "String.prototype.repeat argument must be greater than or equal to 0 and not be Infinity");
    if (n == 0 || !S->length)
        return val(rt.empty);
    if (n * S->length > 0x3FFFFFFF)
        return rt.fail(ErrorKind::range, "Out of memory");
    size_t total = static_cast<size_t>(n) * S->length;
    char16_t* buf = rt.arena.array<char16_t>(total);
    if (!buf)
        return rt.fail(ErrorKind::internal, "out of memory");
    for (size_t k = 0; k < total; k++)
        buf[k] = s[k % S->length];
    return str(rt, {buf, total});
}
Value s_concat(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("concat");
    Str* out = S;
    for (uint32_t i = 0; i < argc && out; i++) {
        Str* t = to_string(rt, args[i]);
        out = t ? rt.concat(out, t) : nullptr;
    }
    return out ? val(out) : Value::undefined();
}
Value s_tostring(Vm& vm, Value self, const Value*, uint32_t) {
    if (!self.is(Kind::string))
        return type_error(vm.rt, "String.prototype.toString requires that 'this' be a String");
    return self;
}
Value case_(Vm& vm, Value self, bool upper, const char* method) {
    SELF(method);
    if (!S->ascii)
        return os_case(rt, S, upper);
    bool same = true;
    for (char16_t c : s)
        same = same && (upper ? !(c >= 'a' && c <= 'z') : !(c >= 'A' && c <= 'Z'));
    if (same)
        return val(S);
    char16_t* buf = rt.arena.array<char16_t>(S->length);
    if (!buf)
        return rt.fail(ErrorKind::internal, "out of memory");
    for (uint32_t i = 0; i < S->length; i++) {
        char16_t c = s[i];
        buf[i] = upper ? (c >= 'a' && c <= 'z' ? static_cast<char16_t>(c - 32) : c)
                       : (c >= 'A' && c <= 'Z' ? static_cast<char16_t>(c + 32) : c);
    }
    return str(rt, {buf, S->length});
}
Value s_upper(Vm& vm, Value self, const Value*, uint32_t) {
    return case_(vm, self, true, "toUpperCase");
}
Value s_lower(Vm& vm, Value self, const Value*, uint32_t) {
    return case_(vm, self, false, "toLowerCase");
}

Value s_split(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("split");
    Value sep = arg(args, argc, 0), lim = arg(args, argc, 1);
    if (sep.is(Kind::regexp))
        return regex_split(vm, S, sep, lim);
    uint32_t limit = lim.is_undefined() ? 0xFFFFFFFFu : num::to_uint32(to_number(rt, lim));
    Arr* out = rt.array(0);
    if (!out || rt.failed)
        return Value::undefined();
    if (sep.is_undefined()) {
        if (limit)
            rt.push(out, val(S));
        return val(out);
    }
    Str* R = to_string(rt, sep);
    if (!R)
        return Value::undefined();
    if (!limit)
        return val(out);
    if (!R->length) {
        for (uint32_t i = 0; i < S->length && out->length < limit; i++)
            rt.push(out, str(rt, s.substr(i, 1)));
        return val(out);
    }
    if (!S->length) {
        rt.push(out, val(S));
        return val(out);
    }
    size_t p = 0;
    for (size_t q; (q = s.find(R->view(), p)) != sv16::npos;) {
        rt.push(out, str(rt, s.substr(p, q - p)));
        if (out->length == limit)
            return val(out);
        p = q + R->length;
    }
    rt.push(out, str(rt, s.substr(p)));
    return rt.failed ? Value::undefined() : val(out);
}

}

Str* substitution(Rt& rt, sv16 matched, sv16 str_, size_t position, const Value* captures, uint32_t n_captures,
                  sv16 replacement, Value groups) {
    Str* out = rt.empty;
    size_t run = 0;
    auto flush = [&](size_t to) {
        if (to > run && out)
            out = rt.concat(out, rt.str(replacement.substr(run, to - run)));
    };
    for (size_t i = 0; i + 1 < replacement.size() && out; i++) {
        if (replacement[i] != '$')
            continue;
        char16_t c = replacement[i + 1];
        Str* piece = nullptr;
        size_t used = 2;
        if (c == '$')
            piece = rt.str(u"$");
        else if (c == '&')
            piece = rt.str(matched);
        else if (c == '`')
            piece = rt.str(str_.substr(0, position));
        else if (c == '\'') {
            size_t tail = std::min(position + matched.size(), str_.size());
            piece = rt.str(str_.substr(tail));
        } else if (c == '<' && !groups.is_undefined()) {
            size_t close = replacement.find('>', i + 2);
            if (close == sv16::npos)
                continue;
            Str* name = rt.atom(replacement.substr(i + 2, close - (i + 2)));
            Value cap = name ? get(rt, groups, name) : Value::undefined();
            piece = cap.is_undefined() ? rt.empty : to_string(rt, cap);
            used = close - i + 1;
        } else if (c >= '0' && c <= '9') {
            uint32_t d1 = c - '0';
            bool two = i + 2 < replacement.size() && replacement[i + 2] >= '0' && replacement[i + 2] <= '9';
            uint32_t d2 = two ? d1 * 10 + (replacement[i + 2] - '0') : 0;
            uint32_t k;
            if (two && d2 >= 1 && d2 <= n_captures)
                k = d2, used = 3;
            else if (d1 >= 1 && d1 <= n_captures)
                k = d1;
            else
                continue;
            Value cap = captures[k - 1];
            piece = cap.is_undefined() ? rt.empty : to_string(rt, cap);
        } else
            continue;
        flush(i);
        if (!piece)
            return nullptr;
        out = rt.concat(out, piece);
        run = i + used;
        i += used - 1;
    }
    flush(replacement.size());
    return out;
}

namespace {
Value replace_(Vm& vm, Value self, const Value* args, uint32_t argc, bool all) {
    SELF(all ? "replaceAll" : "replace");
    Value pattern = arg(args, argc, 0), rep = arg(args, argc, 1);
    if (pattern.is(Kind::regexp))
        return regex_replace(vm, S, pattern, rep, all);
    Str* P = to_string(rt, pattern);
    if (!P)
        return Value::undefined();
    bool fn = callable(rep);
    Str* R = fn ? nullptr : to_string(rt, rep);
    if (!fn && !R)
        return Value::undefined();
    size_t advance = P->length ? P->length : 1, end = 0;
    size_t p = find_at(s, P->view(), 0);
    if (p == sv16::npos)
        return val(S);
    Str* out = rt.empty;
    for (; p != sv16::npos && out; p = all ? find_at(s, P->view(), p + advance) : sv16::npos) {
        out = rt.concat(out, rt.str(s.substr(end, p - end)));
        Str* piece;
        if (fn) {
            Value cargs[3] = {val(P), Value::num(static_cast<double>(p)), val(S)};
            Value r = vm.call(rep, Value::undefined(), cargs, 3);
            if (rt.failed)
                return Value::undefined();
            piece = to_string(rt, r);
        } else {
            piece = substitution(rt, P->view(), s, p, nullptr, 0, R->view());
        }
        if (!piece)
            return Value::undefined();
        out = rt.concat(out, piece);
        end = p + P->length;
    }
    if (out)
        out = rt.concat(out, rt.str(s.substr(end)));
    return out ? val(out) : Value::undefined();
}
Value s_replace(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return replace_(vm, self, args, argc, false);
}
Value s_replaceall(Vm& vm, Value self, const Value* args, uint32_t argc) {
    if (arg(args, argc, 0).is(Kind::regexp) && !regex_global(arg(args, argc, 0)))
        return type_error(vm.rt, "String.prototype.replaceAll argument must not be a non-global regular expression");
    return replace_(vm, self, args, argc, true);
}
Value s_search(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("search");
    return regex_search(vm, S, arg(args, argc, 0));
}
Value s_match(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("match");
    return regex_match(vm, S, arg(args, argc, 0));
}
Value s_matchall(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("matchAll");
    return regex_match_all(vm, S, arg(args, argc, 0));
}
Value s_localecompare(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("localeCompare");
    Str* t = to_string(rt, arg(args, argc, 0));
    if (!t)
        return Value::undefined();
    return os_compare(rt, S, t, arg(args, argc, 1));
}
Value s_tolocaleupper(Vm& vm, Value self, const Value*, uint32_t) {
    return case_(vm, self, true, "toLocaleUpperCase");
}
Value s_tolocalelower(Vm& vm, Value self, const Value*, uint32_t) {
    return case_(vm, self, false, "toLocaleLowerCase");
}
Value s_at(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("at");
    double k = to_integer(rt, arg(args, argc, 0));
    if (rt.failed)
        return Value::undefined();
    if (k < 0)
        k += S->length;
    if (k < 0 || k >= S->length)
        return Value::undefined();
    return str(rt, s.substr(static_cast<size_t>(k), 1));
}

}

void install_string(Rt& rt, Obj* p) noexcept {
    struct M {
        const char* name;
        NativeFn fn;
        uint32_t len;
    };
    static constexpr M k[] = {{"slice", s_slice, 2},
                              {"substring", s_substring, 2},
                              {"substr", s_substr, 2},
                              {"charAt", s_charat, 1},
                              {"charCodeAt", s_charcodeat, 1},
                              {"codePointAt", s_codepointat, 1},
                              {"indexOf", s_indexof, 1},
                              {"lastIndexOf", s_lastindexof, 1},
                              {"includes", s_includes, 1},
                              {"startsWith", s_startswith, 1},
                              {"endsWith", s_endswith, 1},
                              {"trim", s_trim, 0},
                              {"trimStart", s_trimstart, 0},
                              {"trimEnd", s_trimend, 0},
                              {"padStart", s_padstart, 2},
                              {"padEnd", s_padend, 2},
                              {"repeat", s_repeat, 1},
                              {"concat", s_concat, 1},
                              {"toString", s_tostring, 0},
                              {"valueOf", s_tostring, 0},
                              {"toUpperCase", s_upper, 0},
                              {"toLowerCase", s_lower, 0},
                              {"toLocaleUpperCase", s_tolocaleupper, 0},
                              {"toLocaleLowerCase", s_tolocalelower, 0},
                              {"split", s_split, 2},
                              {"replace", s_replace, 2},
                              {"replaceAll", s_replaceall, 2},
                              {"matchAll", s_matchall, 1},
                              {"search", s_search, 1},
                              {"match", s_match, 1},
                              {"localeCompare", s_localecompare, 1},
                              {"at", s_at, 1}};
    for (const M& m : k)
        def(rt, p, m.name, m.fn, m.len);
}

}
