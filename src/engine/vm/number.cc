// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/number.h"

#include <charconv>
#include <cmath>
#include <cstring>

#include "base/analyzer.h"

namespace rx::engine::num {
namespace {

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

size_t put(char16_t* out, size_t at, const char* s) {
    while (*s)
        out[at++] = static_cast<char16_t>(*s++);
    return at;
}

double from_power_of_two(std::u16string_view d, int bits_per_digit) {
    uint64_t m = 0;
    int kept = 0;
    int dropped = 0;
    bool sticky = false;
    for (char16_t c : d) {
        int v = c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
        for (int b = bits_per_digit - 1; b >= 0; b--) {
            int bit = (v >> b) & 1;
            if (kept == 0 && !bit)
                continue;
            if (kept < 64)
                m = (m << 1) | static_cast<uint64_t>(bit), kept++;
            else
                dropped++, sticky = sticky || bit;
        }
    }
    if (kept == 0)
        return 0;
    if (kept > 53) {
        int extra = kept - 53;
        uint64_t rest = m & ((1ull << extra) - 1);
        uint64_t half = 1ull << (extra - 1);
        m >>= extra;
        dropped += extra;
        if (rest > half || (rest == half && (sticky || (m & 1)))) {
            m++;
            if (m >> 53)
                m >>= 1, dropped++;
        }
    }
    return std::ldexp(static_cast<double>(m), dropped);
}

}

size_t to_string(double x, char16_t* out) noexcept {
    if (std::isnan(x))
        return put(out, 0, "NaN");
    if (x == 0)
        return put(out, 0, "0");
    size_t at = 0;
    if (x < 0)
        out[at++] = '-', x = -x;
    if (std::isinf(x))
        return put(out, at, "Infinity");
    char buf[40];
    auto r = std::to_chars(buf, buf + sizeof buf, x, std::chars_format::scientific);
    char digits[20] RX_ANALYZER_ZERO;
    int k = 0;
    const char* p = buf;
    for (; p < r.ptr && *p != 'e'; p++)
        if (*p != '.')
            digits[k++] = *p;
    int e = 0;
    std::from_chars(p + 1 + (p[1] == '+'), r.ptr, e);
    int n = e + 1;
    if (k <= n && n <= 21) {
        for (int i = 0; i < k; i++)
            out[at++] = static_cast<char16_t>(digits[i]);
        for (int i = k; i < n; i++)
            out[at++] = '0';
    } else if (0 < n && n <= 21) {
        for (int i = 0; i < n; i++)
            out[at++] = static_cast<char16_t>(digits[i]);
        out[at++] = '.';
        for (int i = n; i < k; i++)
            out[at++] = static_cast<char16_t>(digits[i]);
    } else if (-6 < n && n <= 0) {
        out[at++] = '0';
        out[at++] = '.';
        for (int i = 0; i < -n; i++)
            out[at++] = '0';
        for (int i = 0; i < k; i++)
            out[at++] = static_cast<char16_t>(digits[i]);
    } else {
        out[at++] = static_cast<char16_t>(digits[0]);
        if (k > 1) {
            out[at++] = '.';
            for (int i = 1; i < k; i++)
                out[at++] = static_cast<char16_t>(digits[i]);
        }
        out[at++] = 'e';
        out[at++] = n - 1 < 0 ? '-' : '+';
        char eb[8] RX_ANALYZER_ZERO;
        auto er = std::to_chars(eb, eb + sizeof eb, n - 1 < 0 ? 1 - n : n - 1);
        for (char* q = eb; q < er.ptr; q++)
            out[at++] = static_cast<char16_t>(*q);
    }
    return at;
}

namespace {

struct Big {
    static constexpr int k_words = 36;
    uint32_t w[k_words] = {};
    bool zero() const {
        for (uint32_t x : w)
            if (x)
                return false;
        return true;
    }
    void shl_set(uint64_t m, int shift) {
        for (uint32_t& x : w)
            x = 0;
        if (shift < 0) {
            m = -shift < 64 ? m >> -shift : 0;
            shift = 0;
        }
        int word = shift / 32, bit = shift % 32;
        unsigned __int128 v = static_cast<unsigned __int128>(m) << bit;
        for (int k = 0; k < 4 && word + k < k_words; k++)
            w[word + k] = static_cast<uint32_t>(v >> (32 * k));
    }
    uint32_t divide(uint32_t d) {
        uint64_t r = 0;
        for (int k = k_words - 1; k >= 0; k--) {
            uint64_t cur = (r << 32) | w[k];
            w[k] = static_cast<uint32_t>(cur / d);
            r = cur % d;
        }
        return static_cast<uint32_t>(r);
    }
    void multiply(uint32_t m) {
        uint64_t carry = 0;
        for (uint32_t& x : w) {
            uint64_t cur = static_cast<uint64_t>(x) * m + carry;
            x = static_cast<uint32_t>(cur);
            carry = cur >> 32;
        }
    }
    void add(const Big& o) {
        uint64_t carry = 0;
        for (int k = 0; k < k_words; k++) {
            uint64_t cur = static_cast<uint64_t>(w[k]) + o.w[k] + carry;
            w[k] = static_cast<uint32_t>(cur);
            carry = cur >> 32;
        }
    }
    int compare(const Big& o) const {
        for (int k = k_words - 1; k >= 0; k--)
            if (w[k] != o.w[k])
                return w[k] < o.w[k] ? -1 : 1;
        return 0;
    }
    uint32_t take_above(int bit) {
        int word = bit / 32, b = bit % 32;
        uint64_t v = (static_cast<uint64_t>(word + 1 < k_words ? w[word + 1] : 0) << 32 | w[word]) >> b;
        w[word] &= b ? (1u << b) - 1 : 0;
        for (int k = word + 1; k < k_words; k++)
            w[k] = 0;
        return static_cast<uint32_t>(v);
    }
};

constexpr int k_frac_bits = 1076;

void split(double x, uint64_t& m, int& e) {
    int ex;
    double f = std::frexp(x, &ex);
    m = static_cast<uint64_t>(std::ldexp(f, 53));
    e = ex - 53;
}

}

size_t to_string_radix(double x, int radix, char16_t* out) noexcept {
    if (radix == 10 || radix < 2 || radix > 36)
        return to_string(x, out);
    if (std::isnan(x))
        return put(out, 0, "NaN");
    if (x == 0)
        return put(out, 0, "0");
    if (std::isinf(x))
        return put(out, 0, x < 0 ? "-Infinity" : "Infinity");
    static constexpr char k_digits[] = "0123456789abcdefghijklmnopqrstuvwxyz";
    char buf[2200];
    size_t integer_at = 1100, fraction_at = 1100;
    bool negative = x < 0;
    double v = negative ? -x : x;
    double integer = std::floor(v), fraction = v - integer;
    if (fraction != 0) {
        buf[fraction_at++] = '.';
        uint64_t m;
        int e;
        Big f, half_next, half_last, one, half;
        split(fraction, m, e);
        f.shl_set(m, k_frac_bits + e);
        double next = std::nextafter(v, INFINITY), last = std::nextafter(v, -INFINITY);
        split(next - v, m, e);
        half_next.shl_set(m, k_frac_bits + e - 1);
        split(v - last, m, e);
        half_last.shl_set(m, k_frac_bits + e - 1);
        one.shl_set(1, k_frac_bits);
        half.shl_set(1, k_frac_bits - 1);
        bool round_up = false;
        uint32_t last_digit = 0;
        for (;;) {
            int c = f.compare(half);
            if (c > 0 || (c == 0 && (last_digit & 1))) {
                Big sum = f;
                sum.add(half_next);
                if (sum.compare(one) > 0) {
                    round_up = true;
                    break;
                }
            } else if (f.compare(half_last) < 0) {
                break;
            }
            if (fraction_at >= sizeof buf - 1)
                break;
            f.multiply(static_cast<uint32_t>(radix));
            last_digit = f.take_above(k_frac_bits);
            buf[fraction_at++] = k_digits[last_digit];
            half_next.multiply(static_cast<uint32_t>(radix));
            half_last.multiply(static_cast<uint32_t>(radix));
        }
        if (round_up) {
            for (;;) {
                if (buf[fraction_at - 1] == '.') {
                    integer += 1;
                    break;
                }
                char ch = buf[fraction_at - 1];
                int d = ch > '9' ? ch - 'a' + 10 : ch - '0';
                if (d + 1 < radix) {
                    buf[fraction_at - 1] = k_digits[d + 1];
                    break;
                }
                fraction_at--;
            }
        }
        if (buf[fraction_at - 1] == '.')
            fraction_at--;
    }
    uint64_t m;
    int e;
    Big n;
    if (integer == 0) {
        buf[--integer_at] = '0';
    } else {
        split(integer, m, e);
        if (e >= 0)
            n.shl_set(m, e);
        else
            n.shl_set(m >> -e, 0);
        do
            buf[--integer_at] = k_digits[n.divide(static_cast<uint32_t>(radix))];
        while (!n.zero());
    }
    size_t at = 0;
    if (negative)
        out[at++] = '-';
    for (size_t i = integer_at; i < fraction_at; i++)
        out[at++] = static_cast<char16_t>(buf[i]);
    return at;
}

double from_string(std::u16string_view s) noexcept {
    size_t b = 0, e = s.size();
    while (b < e && js_space(s[b]))
        b++;
    while (e > b && js_space(s[e - 1]))
        e--;
    s = s.substr(b, e - b);
    if (s.empty())
        return 0;
    if (s.size() > 2 && s[0] == '0') {
        char16_t x = static_cast<char16_t>(s[1] | 0x20);
        int bits = x == 'x' ? 4 : x == 'o' ? 3 : x == 'b' ? 1 : 0;
        if (bits) {
            std::u16string_view d = s.substr(2);
            for (char16_t c : d) {
                int v = c >= '0' && c <= '9'                   ? c - '0'
                    : ((c | 0x20) >= 'a' && (c | 0x20) <= 'z') ? (c | 0x20) - 'a' + 10
                                                               : 99;
                if (v >= (1 << bits))
                    return NAN;
            }
            return from_power_of_two(d, bits);
        }
    }
    bool negative = false;
    size_t i = 0;
    if (s[0] == '+' || s[0] == '-')
        negative = s[0] == '-', i = 1;
    std::u16string_view rest = s.substr(i);
    if (rest == u"Infinity")
        return negative ? -INFINITY : INFINITY;
    char buf[800 + 32];
    size_t n = 2, k = 0, sig = 0;
    buf[0] = '0', buf[1] = '.';
    long long point = 0;
    bool any = false, seen_nonzero = false, sticky = false;
    auto digit = [&](char16_t c, bool integer_part) {
        any = true;
        if (!seen_nonzero && c == '0') {
            if (!integer_part)
                point--;
            return;
        }
        seen_nonzero = true;
        if (integer_part)
            point++;
        if (sig < 768)
            buf[n++] = static_cast<char>(c), sig++;
        else if (c != '0')
            sticky = true;
    };
    while (k < rest.size() && rest[k] >= '0' && rest[k] <= '9')
        digit(rest[k++], true);
    if (k < rest.size() && rest[k] == '.') {
        k++;
        while (k < rest.size() && rest[k] >= '0' && rest[k] <= '9')
            digit(rest[k++], false);
    }
    if (!any)
        return NAN;
    long long exp = 0;
    if (k < rest.size() && (rest[k] == 'e' || rest[k] == 'E')) {
        k++;
        bool eneg = false;
        if (k < rest.size() && (rest[k] == '+' || rest[k] == '-'))
            eneg = rest[k++] == '-';
        bool digits = false;
        while (k < rest.size() && rest[k] >= '0' && rest[k] <= '9') {
            if (exp < 100000000)
                exp = exp * 10 + (rest[k] - '0');
            k++, digits = true;
        }
        if (!digits)
            return NAN;
        if (eneg)
            exp = -exp;
    }
    if (k != rest.size())
        return NAN;
    if (!seen_nonzero)
        return negative ? -0.0 : 0.0;
    if (sticky)
        buf[n++] = '1';
    long long e10 = point + exp;
    if (e10 > 100000)
        e10 = 100000;
    if (e10 < -100000)
        e10 = -100000;
    buf[n++] = 'e';
    auto er = std::to_chars(buf + n, buf + sizeof buf, e10);
    n = static_cast<size_t>(er.ptr - buf);
    double v = 0;
    std::from_chars(buf, buf + n, v);
    return negative ? -v : v;
}

int32_t to_int32(double x) noexcept {
    if (!std::isfinite(x) || x == 0)
        return 0;
    double t = std::trunc(x);
    double m = std::fmod(t, 4294967296.0);
    if (m < 0)
        m += 4294967296.0;
    return static_cast<int32_t>(static_cast<uint32_t>(m));
}

}
