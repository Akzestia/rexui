// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/lib.h"

#include <cmath>
#include <cstring>

#include "base/analyzer.h"
#include "engine/vm/gc.h"
#include "engine/vm/number.h"

namespace rx::engine::vm::lib {

MissFn qstr_miss = nullptr;

double to_integer(Rt& rt, Value v) noexcept {
    double d = v.is_num() ? v.as_num() : to_number(rt, v);
    if (d != d)
        return 0;
    if (std::isinf(d))
        return d;
    return std::trunc(d) + 0.0;
}

uint32_t relative(double rel, uint32_t len) noexcept {
    if (rel < 0)
        return rel + len < 0 ? 0 : static_cast<uint32_t>(rel + len);
    return rel > len ? len : static_cast<uint32_t>(rel);
}

bool callable(Value v) noexcept {
    return v.is(Kind::function) || v.is(Kind::native);
}

Value arg(const Value* args, uint32_t argc, uint32_t i) noexcept {
    return i < argc ? args[i] : Value::undefined();
}

Value type_error(Rt& rt, const char* what) noexcept {
    return rt.fail(ErrorKind::type, "%s", what);
}

Str* this_string(Vm& vm, Value self, const char* method) noexcept {
    if (self.is_nullish() || self.is_hole()) {
        vm.rt.fail(ErrorKind::type, "String.prototype.%s called on null or undefined", method);
        return nullptr;
    }
    return to_string(vm.rt, self);
}

bool def(Rt& rt, Obj* o, const char* name, NativeFn fn, uint32_t length) noexcept {
    Native* n = rt.native(name, fn, length);
    return n && rt.put(o, n->name, val(n));
}

namespace {

Value num(double d) {
    return Value::num(d);
}
double num_arg(Vm& vm, const Value* args, uint32_t argc, uint32_t i) {
    return to_number(vm.rt, arg(args, argc, i));
}

#define MATH1(name, expr)                                                \
    Value math_##name(Vm& vm, Value, const Value* args, uint32_t argc) { \
        double x = num_arg(vm, args, argc, 0);                           \
        return num(expr);                                                \
    }
MATH1(abs, std::fabs(x))
MATH1(floor, std::floor(x))
MATH1(ceil, std::ceil(x))
MATH1(trunc, std::trunc(x))
MATH1(sqrt, std::sqrt(x))
MATH1(cbrt, std::cbrt(x))
MATH1(sin, std::sin(x))
MATH1(cos, std::cos(x))
MATH1(tan, std::tan(x))
MATH1(asin, std::asin(x))
MATH1(acos, std::acos(x))
MATH1(atan, std::atan(x))
MATH1(sinh, std::sinh(x))
MATH1(cosh, std::cosh(x))
MATH1(tanh, std::tanh(x))
MATH1(asinh, std::asinh(x))
MATH1(acosh, std::acosh(x))
MATH1(atanh, std::atanh(x))
MATH1(exp, std::exp(x))
MATH1(expm1, std::expm1(x))
MATH1(log, std::log(x))
MATH1(log2, std::log2(x))
MATH1(log10, std::log10(x))
MATH1(log1p, std::log1p(x))
MATH1(fround, static_cast<double>(static_cast<float>(x)))
MATH1(sign, x != x ? x : x > 0 ? 1 : x < 0 ? -1 : x)
#undef MATH1

Value math_round(Vm& vm, Value, const Value* args, uint32_t argc) {
    double x = num_arg(vm, args, argc, 0);
    if (!std::isfinite(x) || x == 0)
        return num(x);
    if (x > 0 && x < 0.5)
        return num(0.0);
    if (x < 0 && x >= -0.5)
        return num(-0.0);
    double r = std::floor(x);
    if (x - r >= 0.5)
        r += 1;
    return num(r);
}
Value math_max(Vm& vm, Value, const Value* args, uint32_t argc) {
    double best = -INFINITY;
    bool nan = false;
    for (uint32_t i = 0; i < argc; i++) {
        double x = to_number(vm.rt, args[i]);
        if (vm.rt.failed)
            return Value::undefined();
        if (x != x)
            nan = true;
        else if (x > best || (x == 0 && best == 0 && !std::signbit(x)))
            best = x;
    }
    return num(nan ? NAN : best);
}
Value math_min(Vm& vm, Value, const Value* args, uint32_t argc) {
    double best = INFINITY;
    bool nan = false;
    for (uint32_t i = 0; i < argc; i++) {
        double x = to_number(vm.rt, args[i]);
        if (vm.rt.failed)
            return Value::undefined();
        if (x != x)
            nan = true;
        else if (x < best || (x == 0 && best == 0 && std::signbit(x)))
            best = x;
    }
    return num(nan ? NAN : best);
}
Value math_pow(Vm& vm, Value, const Value* args, uint32_t argc) {
    double a = num_arg(vm, args, argc, 0), b = num_arg(vm, args, argc, 1);
    return num(js_pow(a, b));
}
Value math_atan2(Vm& vm, Value, const Value* args, uint32_t argc) {
    double a = num_arg(vm, args, argc, 0), b = num_arg(vm, args, argc, 1);
    return num(std::atan2(a, b));
}
Value math_hypot(Vm& vm, Value, const Value* args, uint32_t argc) {
    double xs[64];
    uint32_t n = argc < 64 ? argc : 64;
    bool inf = false, nan = false;
    double big = 0;
    for (uint32_t i = 0; i < n; i++) {
        xs[i] = to_number(vm.rt, args[i]);
        if (vm.rt.failed)
            return Value::undefined();
        if (std::isinf(xs[i]))
            inf = true;
        else if (xs[i] != xs[i])
            nan = true;
        else
            big = std::fmax(big, std::fabs(xs[i]));
    }
    if (inf)
        return num(INFINITY);
    if (nan)
        return num(NAN);
    if (big == 0)
        return num(0.0);
    if (n == 2)
        return num(std::hypot(xs[0], xs[1]));
    if (n == 1)
        return num(std::fabs(xs[0]));
    int e;
    std::frexp(big, &e);
    double sum = 0, comp = 0;
    for (uint32_t i = 0; i < n; i++) {
        double v = std::ldexp(xs[i], -e);
        double sq = v * v;
        double s = sq - comp;
        double prel = sum + s;
        comp = (prel - sum) - s;
        sum = prel;
    }
    return num(std::ldexp(std::sqrt(sum), e));
}
Value math_random(Vm& vm, Value, const Value*, uint32_t) {
    if (vm.rt.test_seed > 0) {
        vm.rt.test_seed = std::fmod(vm.rt.test_seed * 16807, 2147483647);
        return num((vm.rt.test_seed - 1) / 2147483646);
    }
    static uint64_t s = 0x9E3779B97F4A7C15ull ^ reinterpret_cast<uintptr_t>(&s);
    s ^= s >> 12, s ^= s << 25, s ^= s >> 27;
    return num(static_cast<double>((s * 2685821657736338717ull) >> 11) / 9007199254740992.0);
}

Value g_string(Vm& vm, Value, const Value* args, uint32_t argc) {
    if (!argc)
        return val(vm.rt.empty);
    Str* s = to_string(vm.rt, args[0]);
    return s ? val(s) : Value::undefined();
}
Value g_number(Vm& vm, Value, const Value* args, uint32_t argc) {
    return num(argc ? to_number(vm.rt, args[0]) : 0);
}
Value g_boolean(Vm&, Value, const Value* args, uint32_t argc) {
    return Value::boolean(argc && to_boolean(args[0]));
}
Value g_isnan(Vm& vm, Value, const Value* args, uint32_t argc) {
    double d = num_arg(vm, args, argc, 0);
    return Value::boolean(d != d);
}
Value g_isfinite(Vm& vm, Value, const Value* args, uint32_t argc) {
    return Value::boolean(std::isfinite(num_arg(vm, args, argc, 0)));
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
int digit_of(char16_t c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if ((c | 0x20) >= 'a' && (c | 0x20) <= 'z')
        return (c | 0x20) - 'a' + 10;
    return 99;
}

Value g_parseint(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Str* s = to_string(rt, arg(args, argc, 0));
    if (!s)
        return Value::undefined();
    int32_t radix = num::to_int32(to_number(rt, arg(args, argc, 1)));
    std::u16string_view t = s->view();
    size_t i = 0;
    while (i < t.size() && js_space(t[i]))
        i++;
    bool negative = false;
    if (i < t.size() && (t[i] == '+' || t[i] == '-'))
        negative = t[i++] == '-';
    bool strip = true;
    if (radix != 0) {
        if (radix < 2 || radix > 36)
            return num(NAN);
        if (radix != 16)
            strip = false;
    } else
        radix = 10;
    if (strip && i + 1 < t.size() && t[i] == '0' && (t[i + 1] | 0x20) == 'x')
        i += 2, radix = 16;
    size_t start = i;
    while (i < t.size() && digit_of(t[i]) < radix)
        i++;
    if (i == start)
        return num(NAN);
    std::u16string_view digits = t.substr(start, i - start);
    double v;
    if (radix == 10) {
        v = num::from_string(digits);
    } else if ((radix & (radix - 1)) == 0) {
        char16_t buf[1100];
        size_t n = 0;
        int bits = radix == 2 ? 1 : radix == 4 ? 2 : radix == 8 ? 3 : radix == 16 ? 4 : 5;
        if (bits == 4 || bits == 3 || bits == 1) {
            buf[n++] = '0';
            buf[n++] = bits == 4 ? 'x' : bits == 3 ? 'o' : 'b';
            for (char16_t c : digits) {
                if (n >= sizeof buf / sizeof *buf)
                    break;
                buf[n++] = c;
            }
            v = num::from_string({buf, n});
        } else {
            v = 0;
            for (char16_t c : digits)
                v = v * radix + digit_of(c);
        }
    } else {
        v = 0;
        for (char16_t c : digits)
            v = v * radix + digit_of(c);
    }
    return num(negative ? -v : v);
}

Value g_parsefloat(Vm& vm, Value, const Value* args, uint32_t argc) {
    Str* s = to_string(vm.rt, arg(args, argc, 0));
    if (!s)
        return Value::undefined();
    std::u16string_view t = s->view();
    size_t i = 0;
    while (i < t.size() && js_space(t[i]))
        i++;
    size_t start = i;
    if (i < t.size() && (t[i] == '+' || t[i] == '-'))
        i++;
    if (t.substr(i).starts_with(u"Infinity"))
        return num(t[start] == '-' ? -INFINITY : INFINITY);
    size_t digits = 0;
    while (i < t.size() && t[i] >= '0' && t[i] <= '9')
        i++, digits++;
    if (i < t.size() && t[i] == '.') {
        i++;
        while (i < t.size() && t[i] >= '0' && t[i] <= '9')
            i++, digits++;
    }
    if (!digits)
        return num(NAN);
    size_t end = i;
    if (i < t.size() && (t[i] == 'e' || t[i] == 'E')) {
        size_t j = i + 1;
        if (j < t.size() && (t[j] == '+' || t[j] == '-'))
            j++;
        size_t e0 = j;
        while (j < t.size() && t[j] >= '0' && t[j] <= '9')
            j++;
        if (j > e0)
            end = j;
    }
    return num(num::from_string(t.substr(start, end - start)));
}

Value g_decode(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Str* s = to_string(rt, arg(args, argc, 0));
    if (!s)
        return Value::undefined();
    std::u16string_view t = s->view();
    char16_t* out = rt.arena.array<char16_t>(t.size() + 1);
    if (!out)
        return rt.fail(ErrorKind::internal, "out of memory");
    size_t n = 0;
    auto hex2 = [&](size_t at) -> int {
        if (at + 3 > t.size() || t[at] != '%')
            return -1;
        int a = digit_of(t[at + 1]), b = digit_of(t[at + 2]);
        return a > 15 || b > 15 ? -1 : a * 16 + b;
    };
    for (size_t i = 0; i < t.size();) {
        if (t[i] != '%') {
            out[n++] = t[i++];
            continue;
        }
        int b0 = hex2(i);
        if (b0 < 0)
            return rt.fail(ErrorKind::uri, "URI error");
        i += 3;
        if (b0 < 0x80) {
            out[n++] = static_cast<char16_t>(b0);
            continue;
        }
        int len = (b0 & 0xE0) == 0xC0 ? 2 : (b0 & 0xF0) == 0xE0 ? 3 : (b0 & 0xF8) == 0xF0 ? 4 : 0;
        if (!len)
            return rt.fail(ErrorKind::uri, "URI error");
        uint32_t cp = static_cast<uint32_t>(b0 & (0x7F >> len));
        for (int k = 1; k < len; k++) {
            int b = hex2(i);
            if (b < 0 || (b & 0xC0) != 0x80)
                return rt.fail(ErrorKind::uri, "URI error");
            cp = cp << 6 | static_cast<uint32_t>(b & 0x3F);
            i += 3;
        }
        static constexpr uint32_t k_min[] = {0, 0, 0x80, 0x800, 0x10000};
        if (cp < k_min[len] || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
            return rt.fail(ErrorKind::uri, "URI error");
        if (cp >= 0x10000) {
            out[n++] = static_cast<char16_t>(0xD800 + ((cp - 0x10000) >> 10));
            out[n++] = static_cast<char16_t>(0xDC00 + ((cp - 0x10000) & 0x3FF));
        } else
            out[n++] = static_cast<char16_t>(cp);
    }
    Str* r = rt.str({out, n});
    return r ? val(r) : Value::undefined();
}
Value g_encode(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Str* s = to_string(rt, arg(args, argc, 0));
    if (!s)
        return Value::undefined();
    std::u16string_view t = s->view();
    char16_t* out = rt.arena.array<char16_t>(t.size() * 12 + 1);
    if (!out)
        return rt.fail(ErrorKind::internal, "out of memory");
    size_t n = 0;
    static constexpr char k_hex[] = "0123456789ABCDEF";
    for (size_t i = 0; i < t.size(); i++) {
        char16_t c = t[i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
            || (c < 0x80 && std::strchr("-_.!~*'()", static_cast<char>(c)) && c)) {
            out[n++] = c;
            continue;
        }
        uint32_t cp = c;
        if (c >= 0xDC00 && c <= 0xDFFF)
            return rt.fail(ErrorKind::uri, "URI error");
        if (c >= 0xD800 && c <= 0xDBFF) {
            if (i + 1 >= t.size() || t[i + 1] < 0xDC00 || t[i + 1] > 0xDFFF)
                return rt.fail(ErrorKind::uri, "URI error");
            cp = 0x10000 + ((c - 0xD800u) << 10) + (t[++i] - 0xDC00u);
        }
        uint8_t b[4];
        int len;
        if (cp < 0x80)
            b[0] = static_cast<uint8_t>(cp), len = 1;
        else if (cp < 0x800)
            b[0] = static_cast<uint8_t>(0xC0 | cp >> 6), b[1] = static_cast<uint8_t>(0x80 | (cp & 0x3F)), len = 2;
        else if (cp < 0x10000)
            b[0] = static_cast<uint8_t>(0xE0 | cp >> 12), b[1] = static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)),
            b[2] = static_cast<uint8_t>(0x80 | (cp & 0x3F)), len = 3;
        else
            b[0] = static_cast<uint8_t>(0xF0 | cp >> 18), b[1] = static_cast<uint8_t>(0x80 | ((cp >> 12) & 0x3F)),
            b[2] = static_cast<uint8_t>(0x80 | ((cp >> 6) & 0x3F)), b[3] = static_cast<uint8_t>(0x80 | (cp & 0x3F)),
            len = 4;
        for (int k = 0; k < len; k++) {
            out[n++] = '%';
            out[n++] = static_cast<char16_t>(k_hex[b[k] >> 4]);
            out[n++] = static_cast<char16_t>(k_hex[b[k] & 15]);
        }
    }
    Str* r = rt.str({out, n});
    return r ? val(r) : Value::undefined();
}

bool this_number(Vm& vm, Value self, double& out, const char* method) {
    if (!self.is_num()) {
        vm.rt.fail(ErrorKind::type, "Number.prototype.%s requires that 'this' be a Number", method);
        return false;
    }
    out = self.as_num();
    return true;
}

Value n_tofixed(Vm& vm, Value self, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    double x;
    if (!this_number(vm, self, x, "toFixed"))
        return Value::undefined();
    double fd = to_integer(rt, arg(args, argc, 0));
    if (rt.failed)
        return Value::undefined();
    if (!std::isfinite(fd) || fd < 0 || fd > 100)
        return rt.fail(ErrorKind::range, "toFixed() argument must be between 0 and 100");
    int f = static_cast<int>(fd);
    if (x != x)
        return val(rt.a_nan);
    if (std::fabs(x) >= 1e21) {
        Str* s = to_string(rt, Value::num(x));
        return s ? val(s) : Value::undefined();
    }
    bool negative = x < 0;
    if (negative)
        x = -x;
    uint32_t big[48] = {};
    int words = 1;
    auto mul = [&](uint32_t m) {
        uint64_t carry = 0;
        for (int k = 0; k < words; k++) {
            uint64_t cur = static_cast<uint64_t>(big[k]) * m + carry;
            big[k] = static_cast<uint32_t>(cur);
            carry = cur >> 32;
        }
        if (carry && words < 48)
            big[words++] = static_cast<uint32_t>(carry);
    };
    int ex;
    double frac = std::frexp(x, &ex);
    uint64_t m = x == 0 ? 0 : static_cast<uint64_t>(std::ldexp(frac, 53));
    int e = ex - 53;
    big[0] = static_cast<uint32_t>(m), big[1] = static_cast<uint32_t>(m >> 32), words = 2;
    for (int k = 0; k < f; k++)
        mul(10);
    if (e > 0) {
        for (int k = 0; k < e; k++)
            mul(2);
    } else if (e < 0) {
        int sh = -e;
        bool half = false, more = false;
        auto bit = [&](int b) { return b / 32 < words ? (big[b / 32] >> (b % 32)) & 1u : 0u; };
        half = bit(sh - 1) != 0;
        for (int b = 0; b < sh - 1 && !more; b++)
            more = bit(b) != 0;
        (void)more;
        int ws = sh / 32, bs = sh % 32;
        for (int k = 0; k < words; k++) {
            uint64_t lo = k + ws < words ? big[k + ws] : 0, hi = k + ws + 1 < words ? big[k + ws + 1] : 0;
            big[k] = static_cast<uint32_t>(bs ? (lo >> bs) | (hi << (32 - bs)) : lo);
        }
        if (half) {
            for (int k = 0; k < words; k++)
                if (++big[k])
                    break;
        }
    }
    char digits[400] RX_ANALYZER_ZERO;
    int nd = 0;
    for (;;) {
        bool zero = true;
        for (int k = 0; k < words; k++)
            zero = zero && !big[k];
        if (zero)
            break;
        uint64_t r = 0;
        for (int k = words - 1; k >= 0; k--) {
            uint64_t cur = (r << 32) | big[k];
            big[k] = static_cast<uint32_t>(cur / 10);
            r = cur % 10;
        }
        digits[nd++] = static_cast<char>('0' + r);
        if (nd >= 399)
            break;
    }
    while (nd <= f)
        digits[nd++] = '0';
    char16_t out[420];
    size_t n = 0;
    if (negative) {
        out[n++] = '-';
    }
    for (int k = nd - 1; k >= f; k--)
        out[n++] = static_cast<char16_t>(digits[k]);
    if (f) {
        out[n++] = '.';
        for (int k = f - 1; k >= 0; k--)
            out[n++] = static_cast<char16_t>(digits[k]);
    }
    Str* s = rt.str({out, n});
    return s ? val(s) : Value::undefined();
}
Value n_tostring(Vm& vm, Value self, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    double x;
    if (!this_number(vm, self, x, "toString"))
        return Value::undefined();
    double radix = 10;
    if (argc && !args[0].is_undefined())
        radix = to_integer(rt, args[0]);
    if (rt.failed)
        return Value::undefined();
    if (radix < 2 || radix > 36)
        return rt.fail(ErrorKind::range, "toString() radix must be between 2 and 36");
    char16_t buf[2200];
    size_t n = num::to_string_radix(x, static_cast<int>(radix), buf);
    Str* s = rt.str({buf, n});
    return s ? val(s) : Value::undefined();
}
Value n_valueof(Vm& vm, Value self, const Value*, uint32_t) {
    double x;
    if (!this_number(vm, self, x, "valueOf"))
        return Value::undefined();
    return num(x);
}
Value b_tostring(Vm& vm, Value self, const Value*, uint32_t) {
    if (!self.is_bool())
        return type_error(vm.rt, "Boolean.prototype.toString requires that 'this' be a Boolean");
    return val(self.is_true() ? vm.rt.a_true : vm.rt.a_false);
}
Value b_valueof(Vm& vm, Value self, const Value*, uint32_t) {
    if (!self.is_bool())
        return type_error(vm.rt, "Boolean.prototype.valueOf requires that 'this' be a Boolean");
    return self;
}
Value num_isfinite(Vm&, Value, const Value* args, uint32_t argc) {
    Value v = arg(args, argc, 0);
    return Value::boolean(v.is_num() && std::isfinite(v.as_num()));
}
Value num_isinteger(Vm&, Value, const Value* args, uint32_t argc) {
    Value v = arg(args, argc, 0);
    return Value::boolean(v.is_num() && std::isfinite(v.as_num()) && std::trunc(v.as_num()) == v.as_num());
}
Value num_isnan(Vm&, Value, const Value* args, uint32_t argc) {
    Value v = arg(args, argc, 0);
    return Value::boolean(v.is_num() && v.as_num() != v.as_num());
}

Value o_keys(Vm& vm, Value, const Value* args, uint32_t argc) {
    Value o = arg(args, argc, 0);
    if (o.is_nullish() || o.is_hole())
        return type_error(vm.rt, "Object.keys requires that input parameter not be null or undefined");
    Arr* k = own_keys(vm.rt, o);
    return k ? val(k) : Value::undefined();
}
Value o_fromentries(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value src = arg(args, argc, 0);
    Value pairs = src;
    if (src.is(Kind::set)) {
        Arr* all = rt.array(0);
        uint32_t at = 0;
        Value x;
        while (all && set_step(rt, src, at, x))
            rt.push(all, x);
        if (!all)
            return Value::undefined();
        pairs = val(all);
    }
    if (!pairs.is(Kind::array))
        return type_error(rt, "Object.fromEntries requires an iterable");
    Obj* out = rt.object();
    if (!out)
        return Value::undefined();
    Arr* a = pairs.as<Arr>();
    for (uint32_t k = 0; k < a->length; k++) {
        Value p = a->items[k];
        if (p.is_hole() || !p.is_cell() || p.is(Kind::string))
            return type_error(rt, "Iterator value is not an entry object");
        Str* key = to_property_key(rt, get(rt, p, Value::num(0)));
        Value v = get(rt, p, Value::num(1));
        if (rt.failed || !key || !rt.put(out, key, v))
            return Value::undefined();
    }
    return val(out);
}
Value o_entries(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value o = arg(args, argc, 0);
    if (o.is_nullish() || o.is_hole())
        return type_error(rt, "Object.entries requires that input parameter not be null or undefined");
    Arr* k = own_keys(rt, o);
    if (!k)
        return Value::undefined();
    Arr* out = rt.array(k->length);
    for (uint32_t i = 0; out && i < k->length; i++) {
        Arr* pair = rt.array(2);
        if (!pair)
            return Value::undefined();
        rt.push(pair, k->items[i]);
        rt.push(pair, get(rt, o, k->items[i].as<Str>()));
        if (rt.failed)
            return Value::undefined();
        rt.push(out, val(pair));
    }
    return out ? val(out) : Value::undefined();
}
Value o_values(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value o = arg(args, argc, 0);
    if (o.is_nullish() || o.is_hole())
        return type_error(rt, "Object.values requires that input parameter not be null or undefined");
    Arr* k = own_keys(rt, o);
    if (!k)
        return Value::undefined();
    Arr* out = rt.array(k->length);
    for (uint32_t i = 0; out && i < k->length; i++) {
        rt.push(out, get(rt, o, k->items[i].as<Str>()));
        if (rt.failed)
            return Value::undefined();
    }
    return out ? val(out) : Value::undefined();
}
Value o_assign(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value target = arg(args, argc, 0);
    if (target.is_nullish() || target.is_hole())
        return type_error(rt, "Object.assign requires that input parameter not be null or undefined");
    for (uint32_t i = 1; i < argc; i++) {
        Value src = args[i];
        if (src.is_nullish() || !src.is_cell())
            continue;
        Arr* k = own_keys(rt, src);
        for (uint32_t j = 0; k && j < k->length; j++) {
            Str* key = k->items[j].as<Str>();
            Value v = get(rt, src, key);
            if (rt.failed)
                return Value::undefined();
            set(rt, target, key, v);
            if (rt.failed)
                return Value::undefined();
        }
    }
    return target;
}
Value o_tostring(Vm& vm, Value self, const Value*, uint32_t) {
    const char* tag = self.is_undefined()                  ? "Undefined"
        : self.is_null()                                   ? "Null"
        : self.is(Kind::array)                             ? "Array"
        : self.is(Kind::function) || self.is(Kind::native) ? "Function"
        : self.is(Kind::string)                            ? "String"
        : self.is_num()                                    ? "Number"
        : self.is_bool()                                   ? "Boolean"
        : self.is(Kind::date)                              ? "Date"
        : self.is(Kind::regexp)                            ? "RegExp"
        : self.is(Kind::set)                               ? (set_is_map(self) ? "Map" : "Set")
        : self.is(Kind::promise)                           ? "Promise"
                                                           : "Object";
    char buf[32];
    std::snprintf(buf, sizeof buf, "[object %s]", tag);
    return val(vm.rt.str_ascii(buf));
}
Value o_valueof(Vm&, Value self, const Value*, uint32_t) {
    return self;
}
Value o_hasown(Vm& vm, Value self, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Str* k = to_property_key(rt, arg(args, argc, 0));
    if (!k)
        return Value::undefined();
    uint32_t index;
    if (self.is(Kind::object))
        return Value::boolean(!rt.get_own(self.as<Obj>(), k).is_hole());
    if (self.is(Kind::array)) {
        Arr* a = self.as<Arr>();
        return Value::boolean(k == rt.a_length
                              || (canonical_index(k, index) && index < a->length && !a->items[index].is_hole()));
    }
    if (self.is(Kind::string))
        return Value::boolean(k == rt.a_length || (canonical_index(k, index) && index < self.as<Str>()->length));
    if (self.is_nullish())
        return type_error(rt, "Object.prototype.hasOwnProperty called on null or undefined");
    return Value::boolean(false);
}

Value g_rgba(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value parts[4] = {arg(args, argc, 0), arg(args, argc, 1), arg(args, argc, 2),
                      argc > 3 && !args[3].is_undefined() ? args[3] : Value::num(1)};
    Str* out = rt.str_ascii("rgba(");
    for (int k = 0; k < 4 && out; k++) {
        Str* s = to_string(rt, parts[k]);
        if (!s)
            return Value::undefined();
        out = rt.concat(out, s);
        if (out)
            out = rt.concat(out, k < 3 ? rt.a_comma : rt.str_ascii(")"));
    }
    return out ? val(out) : Value::undefined();
}
bool hex_color(Str* s, double out[4]) {
    std::u16string_view v = s->view();
    if (v.size() < 4 || v[0] != '#')
        return false;
    double d[8] = {};
    for (size_t i = 1; i < v.size(); i++) {
        char16_t c = v[i];
        if (i > 8)
            return false;
        d[i - 1] = c >= '0' && c <= '9' ? c - '0'
            : c >= 'a' && c <= 'f'      ? c - 'a' + 10
            : c >= 'A' && c <= 'F'      ? c - 'A' + 10
                                        : -1;
        if (d[i - 1] < 0)
            return false;
    }
    out[0] = 255;
    if (v.size() == 4) {
        for (int k = 0; k < 3; k++)
            out[k + 1] = d[k] * 17;
        return true;
    }
    if (v.size() == 7) {
        for (int k = 0; k < 3; k++)
            out[k + 1] = d[k * 2] * 16 + d[k * 2 + 1];
        return true;
    }
    if (v.size() == 9) {
        for (int k = 0; k < 4; k++)
            out[k] = d[k * 2] * 16 + d[k * 2 + 1];
        return true;
    }
    return false;
}
Value hex_of(Rt& rt, const double c[4]) {
    static constexpr char k[] = "0123456789abcdef";
    char16_t b[9];
    b[0] = '#';
    for (int i = 0; i < 4; i++) {
        const int x = static_cast<int>(c[i] < 0 ? 0 : c[i] > 255 ? 255 : c[i] + 0.5);
        b[1 + i * 2] = static_cast<char16_t>(k[x >> 4]);
        b[2 + i * 2] = static_cast<char16_t>(k[x & 15]);
    }
    Str* s = rt.str({b, 9});
    return s ? val(s) : Value::undefined();
}
Value g_alpha(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value cv = arg(args, argc, 0);
    Str* s = cv.is(Kind::string) ? cv.as<Str>() : nullptr;
    double c[4];
    if (!s || !hex_color(s, c))
        return cv;
    double a = to_number(rt, arg(args, argc, 1));
    if (rt.failed)
        return Value::undefined();
    c[0] = (a != a ? 1 : a < 0 ? 0 : a > 1 ? 1 : a) * 255;
    return hex_of(rt, c);
}
Value g_mix(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value av = arg(args, argc, 0), bv = arg(args, argc, 1);
    Str *as = av.is(Kind::string) ? av.as<Str>() : nullptr, *bs = bv.is(Kind::string) ? bv.as<Str>() : nullptr;
    double a[4], b[4];
    if (!as || !bs || !hex_color(as, a) || !hex_color(bs, b))
        return av;
    double t = to_number(rt, arg(args, argc, 2));
    if (rt.failed)
        return Value::undefined();
    t = t != t ? 0 : t < 0 ? 0 : t > 1 ? 1 : t;
    for (int k = 0; k < 4; k++)
        a[k] += (b[k] - a[k]) * t;
    return hex_of(rt, a);
}

Value g_qstr(Vm& vm, Value, const Value* args, uint32_t argc);
Value g_qstrn(Vm& vm, Value self, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value n = arg(args, argc, 2);
    double d = to_number(rt, n);
    if (rt.failed)
        return Value::undefined();
    Value buf[10];
    uint32_t k = 0;
    buf[k++] = arg(args, argc, d == 1 ? 0 : 1);
    buf[k++] = n;
    for (uint32_t i = 3; i < argc && k < 10; i++)
        buf[k++] = args[i];
    return g_qstr(vm, self, buf, k);
}

Value g_qstr(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value t = arg(args, argc, 0);
    Str* text = to_string(rt, t.is_nullish() ? Value::cell(&rt.empty->h) : t);
    if (!text)
        return Value::undefined();
    Str* s = text;
    Str* a_i18n = rt.atom(rt.str_ascii("i18n"));
    Value i18n = rt.globals ? rt.get_own(rt.globals, a_i18n) : Value::hole();
    if (i18n.is_hole())
        i18n = vm.host.get(rt, a_i18n);
    if (!rt.failed && i18n.is_cell()) {
        Value strings = get(rt, i18n, rt.atom(rt.str_ascii("strings")));
        if (!rt.failed && strings.is(Kind::object)) {
            Value tr = rt.get_own(strings.as<Obj>(), rt.atom(text));
            if (tr.is(Kind::string) && tr.as<Str>()->length)
                s = tr.as<Str>();
            else if (qstr_miss && text->length)
                qstr_miss(text->view().data(), text->view().size());
        }
    }
    if (rt.failed)
        return Value::undefined();
    if (argc <= 1)
        return val(s);
    std::u16string_view v = s->view();
    Str* out = rt.empty;
    size_t run = 0;
    for (size_t i = 0; i < v.size() && out; i++) {
        if (v[i] != '%' || i + 1 >= v.size() || v[i + 1] < '0' || v[i + 1] > '9')
            continue;
        size_t j = i + 1;
        double k = 0;
        while (j < v.size() && v[j] >= '0' && v[j] <= '9')
            k = k * 10 + (v[j++] - '0');
        if (k > 0 && k <= argc - 1) {
            Str* a = to_string(rt, args[static_cast<uint32_t>(k)]);
            Str* pre = rt.str(v.substr(run, i - run));
            if (!a || !pre)
                return Value::undefined();
            out = rt.concat(rt.concat(out, pre), a);
            run = j;
        }
        i = j - 1;
    }
    if (out && run < v.size())
        out = rt.concat(out, rt.str(v.substr(run)));
    return out ? val(out) : Value::undefined();
}
Value g_log(Vm&, Value, const Value*, uint32_t) {
    return Value::undefined();
}

Value a_isarray(Vm&, Value, const Value* args, uint32_t argc) {
    return Value::boolean(arg(args, argc, 0).is(Kind::array));
}

Value e_tostring(Vm& vm, Value self, const Value*, uint32_t) {
    Rt& rt = vm.rt;
    if (!self.is_cell() || self.is(Kind::string))
        return type_error(rt, "Error.prototype.toString called on a value that isn't an object");
    Value n = get(rt, self, rt.atom(rt.str_ascii("name"))), m = get(rt, self, rt.atom(rt.str_ascii("message")));
    if (rt.failed)
        return Value::undefined();
    Str* name = n.is_undefined() ? rt.str_ascii("Error") : to_string(rt, n);
    Str* msg = m.is_undefined() ? rt.empty : to_string(rt, m);
    if (!name || !msg)
        return Value::undefined();
    if (!name->length)
        return val(msg);
    if (!msg->length)
        return val(name);
    Str* out = rt.concat(rt.concat(name, rt.str_ascii(": ")), msg);
    return out ? val(out) : Value::undefined();
}

}

bool install(Rt& rt) noexcept {
    auto obj = [&] { return rt.object(); };
    rt.object_proto = obj();
    rt.string_proto = obj();
    rt.number_proto = obj();
    rt.boolean_proto = obj();
    rt.array_proto = obj();
    rt.function_proto = obj();
    rt.date_proto = obj();
    rt.set_proto = obj();
    rt.map_proto = obj();
    rt.regexp_proto = obj();
    rt.promise_proto = obj();
    rt.error_proto = obj();
    rt.globals = obj();
    if (rt.failed)
        return false;
    Obj* g = rt.globals;
    auto put = [&](Obj* o, const char* name, Value v) { rt.put(o, rt.atom(rt.str_ascii(name)), v); };

    put(g, "undefined", Value::undefined());
    put(g, "NaN", Value::num(NAN));
    put(g, "Infinity", Value::num(INFINITY));

    Obj* math = obj();
    put(g, "Math", val(math));
    put(math, "PI", num(M_PI));
    put(math, "E", num(M_E));
    put(math, "LN2", num(M_LN2));
    put(math, "LN10", num(M_LN10));
    put(math, "LOG2E", num(M_LOG2E));
    put(math, "LOG10E", num(M_LOG10E));
    put(math, "SQRT2", num(M_SQRT2));
    put(math, "SQRT1_2", num(M_SQRT1_2));
    struct M {
        const char* name;
        NativeFn fn;
        uint32_t len;
    };
    static constexpr M k_math[] = {
        {"abs", math_abs, 1},       {"floor", math_floor, 1}, {"ceil", math_ceil, 1},   {"trunc", math_trunc, 1},
        {"sqrt", math_sqrt, 1},     {"cbrt", math_cbrt, 1},   {"sin", math_sin, 1},     {"cos", math_cos, 1},
        {"tan", math_tan, 1},       {"asin", math_asin, 1},   {"acos", math_acos, 1},   {"atan", math_atan, 1},
        {"sinh", math_sinh, 1},     {"cosh", math_cosh, 1},   {"tanh", math_tanh, 1},   {"asinh", math_asinh, 1},
        {"acosh", math_acosh, 1},   {"atanh", math_atanh, 1}, {"exp", math_exp, 1},     {"expm1", math_expm1, 1},
        {"log", math_log, 1},       {"log2", math_log2, 1},   {"log10", math_log10, 1}, {"log1p", math_log1p, 1},
        {"fround", math_fround, 1}, {"sign", math_sign, 1},   {"round", math_round, 1}, {"max", math_max, 2},
        {"min", math_min, 2},       {"pow", math_pow, 2},     {"atan2", math_atan2, 2}, {"hypot", math_hypot, 2},
        {"random", math_random, 0}};
    for (const M& m : k_math)
        def(rt, math, m.name, m.fn, m.len);

    Native* string_f = rt.native("String", g_string, 1);
    Native* number_f = rt.native("Number", g_number, 1);
    Native* boolean_f = rt.native("Boolean", g_boolean, 1);
    if (!string_f || !number_f || !boolean_f)
        return false;
    put(g, "String", val(string_f));
    put(g, "Number", val(number_f));
    put(g, "Boolean", val(boolean_f));
    def(rt, g, "parseInt", g_parseint, 2);
    def(rt, g, "parseFloat", g_parsefloat, 1);
    def(rt, g, "isNaN", g_isnan, 1);
    def(rt, g, "isFinite", g_isfinite, 1);
    def(rt, g, "decodeURIComponent", g_decode, 1);
    def(rt, g, "encodeURIComponent", g_encode, 1);
    def(rt, g, "rgba", g_rgba, 3);
    def(rt, g, "qsTr", g_qstr, 1);
    def(rt, g, "qsTrn", g_qstrn, 3);
    def(rt, g, "alpha", g_alpha, 2);
    def(rt, g, "mix", g_mix, 3);
    Obj* console = obj();
    put(g, "console", val(console));
    def(rt, console, "log", g_log, 0);
    def(rt, console, "warn", g_log, 0);
    def(rt, console, "error", g_log, 0);

    Obj* number_statics = obj();
    def(rt, number_statics, "isFinite", num_isfinite, 1);
    def(rt, number_statics, "isInteger", num_isinteger, 1);
    def(rt, number_statics, "isNaN", num_isnan, 1);
    def(rt, number_statics, "parseFloat", g_parsefloat, 1);
    def(rt, number_statics, "parseInt", g_parseint, 2);
    put(number_statics, "MAX_SAFE_INTEGER", num(9007199254740991.0));
    put(number_statics, "MIN_SAFE_INTEGER", num(-9007199254740991.0));
    put(number_statics, "EPSILON", num(2.220446049250313e-16));
    put(number_statics, "MAX_VALUE", num(1.7976931348623157e308));
    put(number_statics, "MIN_VALUE", num(5e-324));
    put(number_statics, "POSITIVE_INFINITY", num(INFINITY));
    put(number_statics, "NEGATIVE_INFINITY", num(-INFINITY));
    put(number_statics, "NaN", num(NAN));
    number_f->props = number_statics;

    Obj* object = obj();
    put(g, "Object", val(object));
    def(rt, object, "keys", o_keys, 1);
    def(rt, object, "entries", o_entries, 1);
    def(rt, object, "fromEntries", o_fromentries, 1);
    def(rt, object, "values", o_values, 1);
    def(rt, object, "assign", o_assign, 2);
    Obj* array = obj();
    put(g, "Array", val(array));
    def(rt, array, "isArray", a_isarray, 1);

    def(rt, rt.error_proto, "toString", e_tostring, 0);
    def(rt, rt.object_proto, "toString", o_tostring, 0);
    def(rt, rt.object_proto, "valueOf", o_valueof, 0);
    def(rt, rt.object_proto, "hasOwnProperty", o_hasown, 1);
    def(rt, rt.number_proto, "toFixed", n_tofixed, 1);
    def(rt, rt.number_proto, "toString", n_tostring, 1);
    def(rt, rt.number_proto, "valueOf", n_valueof, 0);
    def(rt, rt.boolean_proto, "toString", b_tostring, 0);
    def(rt, rt.boolean_proto, "valueOf", b_valueof, 0);
    install_string(rt, rt.string_proto);
    install_regex(rt, rt.regexp_proto);
    install_json(rt);
    install_set(rt);
    install_date(rt);
    install_promise(rt);
    install_array(rt, rt.array_proto, array);
    return !rt.failed;
}

size_t gc_size(const Cell* c) noexcept {
    switch (c->kind) {
    case Kind::date:
        return gc_date_size();
    case Kind::set:
        return gc_set_size();
    case Kind::regexp:
        return gc_regexp_size();
    case Kind::promise:
    case Kind::native:
        return gc_promise_size(c);
    default:
        return 0;
    }
}

void gc_trace(Cell* c, Gc& gc) noexcept {
    switch (c->kind) {
    case Kind::set:
        return gc_set_trace(c, gc);
    case Kind::regexp:
        return gc_regexp_trace(c, gc);
    case Kind::promise:
    case Kind::native:
        return gc_promise_trace(c, gc);
    default:
        return;
    }
}

}
