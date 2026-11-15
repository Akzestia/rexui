// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <charconv>
#include <cmath>

#include "engine/vm/lib.h"

namespace rx::engine::vm::lib {
namespace {

using sv16 = std::u16string_view;

struct Reader {
    Reader(Rt& r, sv16 text) : rt(r), s(text) {}
    Rt& rt;
    sv16 s;
    size_t i = 0;
    int depth = 0;
    bool failed = false;

    bool fail(const char* what) {
        if (!failed) {
            failed = true;
            rt.fail(ErrorKind::syntax, "JSON Parse error: %s", what);
        }
        return false;
    }
    void ws() {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
            i++;
    }
    bool lit(const char16_t* w, size_t n) {
        if (s.substr(i, n) != sv16(w, n))
            return fail("Unexpected identifier");
        i += n;
        return true;
    }
    Str* string() {
        i++;
        size_t start = i;
        bool plain = true;
        while (i < s.size() && s[i] != '"') {
            if (s[i] == '\\') {
                plain = false;
                break;
            }
            if (s[i] < 0x20)
                return fail("Unterminated string"), nullptr;
            i++;
        }
        if (plain) {
            if (i >= s.size())
                return fail("Unterminated string"), nullptr;
            Str* out = rt.str(s.substr(start, i - start));
            i++;
            return out;
        }
        char16_t* buf = rt.arena.array<char16_t>(s.size() - start + 1);
        if (!buf)
            return rt.fail(ErrorKind::internal, "out of memory"), nullptr;
        size_t n = 0;
        for (size_t k = start; k < i; k++)
            buf[n++] = s[k];
        while (i < s.size() && s[i] != '"') {
            char16_t c = s[i];
            if (c < 0x20)
                return fail("Unterminated string"), nullptr;
            if (c != '\\') {
                buf[n++] = c, i++;
                continue;
            }
            if (++i >= s.size())
                break;
            char16_t e = s[i++];
            switch (e) {
            case '"':
                buf[n++] = '"';
                break;
            case '\\':
                buf[n++] = '\\';
                break;
            case '/':
                buf[n++] = '/';
                break;
            case 'b':
                buf[n++] = '\b';
                break;
            case 'f':
                buf[n++] = '\f';
                break;
            case 'n':
                buf[n++] = '\n';
                break;
            case 'r':
                buf[n++] = '\r';
                break;
            case 't':
                buf[n++] = '\t';
                break;
            case 'u': {
                uint32_t v = 0;
                for (int k = 0; k < 4; k++) {
                    if (i >= s.size())
                        return fail("Unterminated string"), nullptr;
                    char16_t h = s[i++];
                    int d = h >= '0' && h <= '9'                 ? h - '0'
                        : (h | 0x20) >= 'a' && (h | 0x20) <= 'f' ? (h | 0x20) - 'a' + 10
                                                                 : -1;
                    if (d < 0)
                        return fail("\\u must be followed by 4 hex digits"), nullptr;
                    v = v * 16 + static_cast<uint32_t>(d);
                }
                buf[n++] = static_cast<char16_t>(v);
                break;
            }
            default:
                return fail("Invalid escape character"), nullptr;
            }
        }
        if (i >= s.size())
            return fail("Unterminated string"), nullptr;
        i++;
        return rt.str({buf, n});
    }
    bool number(double& out) {
        size_t start = i;
        if (s[i] == '-')
            i++;
        if (i >= s.size())
            return fail("Unexpected end");
        if (s[i] == '0')
            i++;
        else if (s[i] >= '1' && s[i] <= '9')
            while (i < s.size() && s[i] >= '0' && s[i] <= '9')
                i++;
        else
            return fail("Unexpected token");
        if (i < s.size() && s[i] == '.') {
            i++;
            size_t d = i;
            while (i < s.size() && s[i] >= '0' && s[i] <= '9')
                i++;
            if (i == d)
                return fail("Unexpected token");
        }
        if (i < s.size() && (s[i] == 'e' || s[i] == 'E')) {
            i++;
            if (i < s.size() && (s[i] == '+' || s[i] == '-'))
                i++;
            size_t d = i;
            while (i < s.size() && s[i] >= '0' && s[i] <= '9')
                i++;
            if (i == d)
                return fail("Unexpected token");
        }
        out = num::from_string(s.substr(start, i - start));
        return true;
    }
    Value value() {
        if (++depth > 1000)
            return fail("nested too deeply"), Value::undefined();
        ws();
        if (i >= s.size())
            return fail("Unexpected EOF"), Value::undefined();
        char16_t c = s[i];
        Value out;
        if (c == '{') {
            i++;
            Obj* o = rt.object();
            if (!o)
                return Value::undefined();
            ws();
            if (i < s.size() && s[i] == '}')
                i++;
            else
                for (;;) {
                    ws();
                    if (i >= s.size() || s[i] != '"')
                        return fail("Expected '}'"), Value::undefined();
                    Str* k = string();
                    if (!k)
                        return Value::undefined();
                    ws();
                    if (i >= s.size() || s[i] != ':')
                        return fail("Expected ':' before value in object property definition"), Value::undefined();
                    i++;
                    Value v = value();
                    if (failed || rt.failed)
                        return Value::undefined();
                    rt.put(o, rt.atom(k), v);
                    ws();
                    if (i < s.size() && s[i] == ',') {
                        i++;
                        continue;
                    }
                    if (i < s.size() && s[i] == '}') {
                        i++;
                        break;
                    }
                    return fail("Expected '}'"), Value::undefined();
                }
            out = val(o);
        } else if (c == '[') {
            i++;
            Arr* a = rt.array(0);
            if (!a)
                return Value::undefined();
            ws();
            if (i < s.size() && s[i] == ']')
                i++;
            else
                for (;;) {
                    Value v = value();
                    if (failed || rt.failed)
                        return Value::undefined();
                    rt.push(a, v);
                    ws();
                    if (i < s.size() && s[i] == ',') {
                        i++;
                        continue;
                    }
                    if (i < s.size() && s[i] == ']') {
                        i++;
                        break;
                    }
                    return fail("Expected ']'"), Value::undefined();
                }
            out = val(a);
        } else if (c == '"') {
            Str* str = string();
            out = str ? val(str) : Value::undefined();
        } else if (c == '-' || (c >= '0' && c <= '9')) {
            double d = 0;
            if (!number(d))
                return Value::undefined();
            out = Value::num(d);
        } else if (c == 't') {
            if (!lit(u"true", 4))
                return Value::undefined();
            out = Value::boolean(true);
        } else if (c == 'f') {
            if (!lit(u"false", 5))
                return Value::undefined();
            out = Value::boolean(false);
        } else if (c == 'n') {
            if (!lit(u"null", 4))
                return Value::undefined();
            out = Value::null();
        } else {
            return fail("Unexpected token"), Value::undefined();
        }
        depth--;
        return out;
    }
};

Value revive(Vm& vm, Value holder, Str* key, Value reviver, int depth) {
    Rt& rt = vm.rt;
    if (depth > 1000)
        return rt.fail(ErrorKind::range, "Maximum call stack size exceeded.");
    Value v = get(rt, holder, key);
    if (rt.failed)
        return Value::undefined();
    if (v.is(Kind::array)) {
        Arr* a = v.as<Arr>();
        for (uint32_t k = 0; k < a->length; k++) {
            char16_t buf[16];
            size_t n = num::to_string(k, buf);
            Value r = revive(vm, v, rt.atom({buf, n}), reviver, depth + 1);
            if (rt.failed)
                return Value::undefined();
            a->items[k] = r.is_undefined() ? Value::hole() : r;
        }
    } else if (v.is(Kind::object)) {
        Arr* keys = own_keys(rt, v);
        Obj* o = v.as<Obj>();
        for (uint32_t k = 0; keys && k < keys->length; k++) {
            Str* name = keys->items[k].as<Str>();
            Value r = revive(vm, v, name, reviver, depth + 1);
            if (rt.failed)
                return Value::undefined();
            if (r.is_undefined()) {
                Obj* copy = rt.object();
                if (!copy)
                    return Value::undefined();
                Arr* all = own_keys(rt, v);
                for (uint32_t q = 0; all && q < all->length; q++) {
                    Str* kk = all->items[q].as<Str>();
                    if (kk != name)
                        rt.put(copy, kk, rt.get_own(o, kk));
                }
                *o = *copy;
            } else
                rt.put(o, name, r);
        }
    }
    Value args[2] = {val(key), v};
    return vm.call(reviver, holder, args, 2);
}

Value j_parse(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Str* text = to_string(rt, arg(args, argc, 0));
    if (!text)
        return Value::undefined();
    Reader r(rt, text->view());
    Value v = r.value();
    if (r.failed || rt.failed)
        return Value::undefined();
    r.ws();
    if (r.i != text->length)
        return rt.fail(ErrorKind::syntax, "JSON Parse error: Unable to parse JSON string");
    Value reviver = arg(args, argc, 1);
    if (!callable(reviver))
        return v;
    Obj* root = rt.object();
    if (!root)
        return Value::undefined();
    rt.put(root, rt.empty, v);
    return revive(vm, val(root), rt.empty, reviver, 0);
}

struct Writer {
    Writer(Vm& v, Rt& r) : vm(v), rt(r) {}
    Vm& vm;
    Rt& rt;
    Value replacer;
    Arr* keys = nullptr;
    sv16 gap;
    char16_t* buf = nullptr;
    size_t n = 0, cap = 0;
    Value stack[1024];
    uint32_t depth = 0;
    bool failed = false;

    bool grow(size_t more) {
        if (n + more <= cap)
            return true;
        size_t nc = cap ? cap * 2 : 256;
        while (nc < n + more)
            nc *= 2;
        if (nc > 0x40000000)
            return rt.fail(ErrorKind::range, "Out of memory"), failed = true, false;
        char16_t* b = rt.arena.array<char16_t>(nc);
        if (!b)
            return rt.fail(ErrorKind::internal, "out of memory"), failed = true, false;
        for (size_t k = 0; k < n; k++)
            b[k] = buf[k];
        buf = b, cap = nc;
        return true;
    }
    void put(char16_t c) {
        if (grow(1))
            buf[n++] = c;
    }
    void put(sv16 s) {
        if (!grow(s.size()))
            return;
        for (char16_t c : s)
            buf[n++] = c;
    }
    void put_ascii(const char* s) {
        while (*s)
            put(static_cast<char16_t>(*s++));
    }
    void quote(sv16 s) {
        put('"');
        static constexpr char k_hex[] = "0123456789abcdef";
        for (size_t k = 0; k < s.size(); k++) {
            char16_t c = s[k];
            switch (c) {
            case '\b':
                put_ascii("\\b");
                continue;
            case '\t':
                put_ascii("\\t");
                continue;
            case '\n':
                put_ascii("\\n");
                continue;
            case '\f':
                put_ascii("\\f");
                continue;
            case '\r':
                put_ascii("\\r");
                continue;
            case '"':
                put_ascii("\\\"");
                continue;
            case '\\':
                put_ascii("\\\\");
                continue;
            default:
                break;
            }
            bool lone = false;
            if (c >= 0xD800 && c <= 0xDBFF)
                lone = !(k + 1 < s.size() && s[k + 1] >= 0xDC00 && s[k + 1] <= 0xDFFF);
            else if (c >= 0xDC00 && c <= 0xDFFF)
                lone = !(k > 0 && s[k - 1] >= 0xD800 && s[k - 1] <= 0xDBFF);
            if (c < 0x20 || lone) {
                put_ascii("\\u");
                put(static_cast<char16_t>(k_hex[c >> 12]));
                put(static_cast<char16_t>(k_hex[(c >> 8) & 15]));
                put(static_cast<char16_t>(k_hex[(c >> 4) & 15]));
                put(static_cast<char16_t>(k_hex[c & 15]));
                continue;
            }
            put(c);
        }
        put('"');
    }
    void newline() {
        if (gap.empty())
            return;
        put('\n');
        for (uint32_t k = 0; k < depth; k++)
            put(gap);
    }
    bool property(Value holder, Str* key, Value v) {
        if (failed || rt.failed)
            return false;
        if (v.is_cell() && !v.is(Kind::string)) {
            Value to_json = get(rt, v, rt.atom(rt.str_ascii("toJSON")));
            if (rt.failed)
                return false;
            if (callable(to_json)) {
                Value a[1] = {val(key)};
                v = vm.call(to_json, v, a, 1);
                if (rt.failed)
                    return false;
            }
        }
        if (!replacer.is_undefined()) {
            Value a[2] = {val(key), v};
            v = vm.call(replacer, holder, a, 2);
            if (rt.failed)
                return false;
        }
        if (v.is_null())
            return put_ascii("null"), true;
        if (v.is_bool())
            return put_ascii(v.is_true() ? "true" : "false"), true;
        if (v.is(Kind::string))
            return quote(v.as<Str>()->view()), true;
        if (v.is_num()) {
            double d = v.as_num();
            if (!std::isfinite(d))
                return put_ascii("null"), true;
            char16_t b[num::k_max_chars];
            put({b, num::to_string(d, b)});
            return true;
        }
        if (v.is_undefined() || v.is_hole() || callable(v))
            return false;
        for (uint32_t k = 0; k < depth; k++)
            if (stack[k].same_bits(v))
                return rt.fail(ErrorKind::type, "JSON.stringify cannot serialize cyclic structures."), failed = true,
                                                                                                       false;
        if (depth >= 1023)
            return rt.fail(ErrorKind::range, "Maximum call stack size exceeded."), failed = true, false;
        stack[depth++] = v;
        if (v.is(Kind::array)) {
            Arr* a = v.as<Arr>();
            put('[');
            for (uint32_t k = 0; k < a->length; k++) {
                if (k)
                    put(',');
                newline();
                char16_t b[16];
                Str* ks = rt.atom({b, num::to_string(k, b)});
                if (!property(v, ks, a->items[k].is_hole() ? Value::undefined() : a->items[k])) {
                    if (failed || rt.failed)
                        return false;
                    put_ascii("null");
                }
            }
            depth--;
            if (a->length)
                newline();
            put(']');
            return true;
        }
        Arr* list = keys ? keys : own_keys(rt, v);
        if (!list)
            return false;
        put('{');
        bool any = false;
        for (uint32_t k = 0; k < list->length; k++) {
            Str* name = list->items[k].as<Str>();
            Value x = get(rt, v, name);
            if (rt.failed)
                return false;
            size_t mark = n;
            if (any)
                put(',');
            newline();
            quote(name->view());
            put(':');
            if (!gap.empty())
                put(' ');
            bool wrote = property(v, name, x);
            if (failed || rt.failed)
                return false;
            if (!wrote) {
                n = mark;
                continue;
            }
            any = true;
        }
        depth--;
        if (any)
            newline();
        put('}');
        return true;
    }
};

Value j_stringify(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Writer w(vm, rt);
    Value replacer = arg(args, argc, 1), space = arg(args, argc, 2);
    if (callable(replacer))
        w.replacer = replacer;
    else if (replacer.is(Kind::array)) {
        Arr* r = replacer.as<Arr>();
        w.keys = rt.array(0);
        if (!w.keys)
            return Value::undefined();
        for (uint32_t k = 0; k < r->length; k++) {
            Value x = r->items[k];
            Str* s = nullptr;
            if (x.is(Kind::string))
                s = x.as<Str>();
            else if (x.is_num())
                s = to_string(rt, x);
            if (!s)
                continue;
            s = rt.atom(s);
            bool dup = false;
            for (uint32_t q = 0; q < w.keys->length && !dup; q++)
                dup = w.keys->items[q].as<Str>() == s;
            if (!dup)
                rt.push(w.keys, val(s));
        }
    }
    char16_t gapbuf[10];
    if (space.is_num()) {
        double d = std::fmin(10, to_integer(rt, space));
        size_t k = 0;
        for (; k < static_cast<size_t>(d > 0 ? d : 0); k++)
            gapbuf[k] = ' ';
        w.gap = {gapbuf, k};
    } else if (space.is(Kind::string)) {
        Str* s = space.as<Str>();
        w.gap = s->view().substr(0, 10);
    }
    Obj* holder = rt.object();
    if (!holder)
        return Value::undefined();
    Value v = arg(args, argc, 0);
    rt.put(holder, rt.empty, v);
    bool wrote = w.property(val(holder), rt.empty, v);
    if (rt.failed)
        return Value::undefined();
    if (!wrote)
        return Value::undefined();
    Str* out = rt.str({w.buf, w.n});
    return out ? val(out) : Value::undefined();
}

}

void install_json(Rt& rt) noexcept {
    Obj* json = rt.object();
    if (!json)
        return;
    rt.put(rt.globals, rt.atom(rt.str_ascii("JSON")), val(json));
    def(rt, json, "parse", j_parse, 2);
    def(rt, json, "stringify", j_stringify, 3);
}

}
