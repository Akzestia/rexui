// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <initializer_list>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace rx::tools::json {

struct J {
    enum class T : uint8_t { undef, null, boolean, num, str, arr, obj };
    T t = T::undef;
    bool b = false;
    double n = 0;
    std::string s;
    std::vector<J> a;
    std::vector<std::pair<std::string, J>> o;

    J() = default;
    J(std::nullptr_t) : t(T::null) {}
    J(bool v) : t(T::boolean), b(v) {}
    J(int v) : t(T::num), n(v) {}
    J(unsigned v) : t(T::num), n(v) {}
    J(long v) : t(T::num), n(static_cast<double>(v)) {}
    J(unsigned long v) : t(T::num), n(static_cast<double>(v)) {}
    J(double v) : t(T::num), n(v) {}
    J(const char* v) : t(T::str), s(v) {}
    J(std::string v) : t(T::str), s(std::move(v)) {}
    J(std::string_view v) : t(T::str), s(v) {}

    static J array(std::initializer_list<J> xs = {}) {
        J j;
        j.t = T::arr;
        j.a = xs;
        return j;
    }
    static J object(std::initializer_list<std::pair<std::string, J>> kv = {}) {
        J j;
        j.t = T::obj;
        for (auto& p : kv)
            j.set(p.first, p.second);
        return j;
    }

    bool is_undef() const { return t == T::undef; }
    bool is_null() const { return t == T::null; }
    bool is_nullish() const { return t == T::undef || t == T::null; }
    bool is_str() const { return t == T::str; }
    bool is_num() const { return t == T::num; }
    bool is_bool() const { return t == T::boolean; }
    bool is_arr() const { return t == T::arr; }
    bool is_obj() const { return t == T::obj; }
    bool truthy() const {
        switch (t) {
        case T::undef:
        case T::null:
            return false;
        case T::boolean:
            return b;
        case T::num:
            return n != 0 && !std::isnan(n);
        case T::str:
            return !s.empty();
        default:
            return true;
        }
    }
    size_t size() const { return t == T::arr ? a.size() : t == T::obj ? o.size() : t == T::str ? s.size() : 0; }

    static const J& none() {
        static const J u;
        return u;
    }
    const J& operator[](std::string_view k) const {
        if (t == T::obj)
            for (auto& p : o)
                if (p.first == k)
                    return p.second;
        return none();
    }
    const J& operator[](const char* k) const { return (*this)[std::string_view(k)]; }
    const J& operator[](size_t i) const { return t == T::arr && i < a.size() ? a[i] : none(); }
    const J& operator[](int i) const { return i < 0 ? none() : (*this)[static_cast<size_t>(i)]; }
    bool has(std::string_view k) const {
        if (t == T::obj)
            for (auto& p : o)
                if (p.first == k)
                    return true;
        return false;
    }
    J& set(std::string_view k, J v) {
        if (t != T::obj)
            t = T::obj, o.clear();
        for (auto& p : o)
            if (p.first == k)
                return p.second = std::move(v);
        o.emplace_back(std::string(k), std::move(v));
        return o.back().second;
    }
    J& push(J v) {
        if (t != T::arr)
            t = T::arr, a.clear();
        a.push_back(std::move(v));
        return a.back();
    }
    void remove(std::string_view k) {
        for (size_t i = 0; i < o.size(); i++)
            if (o[i].first == k) {
                o.erase(o.begin() + static_cast<long>(i));
                return;
            }
    }

    bool operator==(const J& x) const {
        if (t != x.t)
            return false;
        switch (t) {
        case T::undef:
        case T::null:
            return true;
        case T::boolean:
            return b == x.b;
        case T::num:
            return n == x.n;
        case T::str:
            return s == x.s;
        default:
            return dump() == x.dump();
        }
    }
    bool operator==(const char* x) const { return t == T::str && s == x; }
    bool operator==(std::string_view x) const { return t == T::str && s == x; }
    bool operator==(const std::string& x) const { return t == T::str && s == x; }
    bool operator==(double x) const { return t == T::num && n == x; }
    bool operator==(int x) const { return t == T::num && n == x; }
    bool operator==(bool x) const { return t == T::boolean && b == x; }
    const std::string& str() const { return s; }
    double num() const { return n; }

    std::string text() const {
        switch (t) {
        case T::undef:
            return "undefined";
        case T::null:
            return "null";
        case T::boolean:
            return b ? "true" : "false";
        case T::num:
            return number(n);
        case T::str:
            return s;
        case T::arr: {
            std::string r;
            for (size_t i = 0; i < a.size(); i++)
                r += (i ? "," : "") + (a[i].is_nullish() ? std::string() : a[i].text());
            return r;
        }
        default:
            return "[object Object]";
        }
    }

    static std::string number(double d) {
        if (std::isnan(d))
            return "NaN";
        if (std::isinf(d))
            return d < 0 ? "-Infinity" : "Infinity";
        if (d == 0)
            return "0";
        char buf[64];
        auto r = std::to_chars(buf, buf + sizeof buf, d, std::chars_format::scientific);
        std::string sci(buf, r.ptr);
        bool neg = sci[0] == '-';
        if (neg)
            sci.erase(0, 1);
        size_t e = sci.find('e');
        std::string digits;
        for (size_t i = 0; i < e; i++)
            if (sci[i] != '.')
                digits += sci[i];
        while (digits.size() > 1 && digits.back() == '0')
            digits.pop_back();
        int k = static_cast<int>(digits.size()), nexp = std::atoi(sci.c_str() + e + 1) + 1;
        std::string out;
        if (k <= nexp && nexp <= 21)
            out = digits + std::string(static_cast<size_t>(nexp - k), '0');
        else if (0 < nexp && nexp <= 21)
            out = digits.substr(0, static_cast<size_t>(nexp)) + "." + digits.substr(static_cast<size_t>(nexp));
        else if (-6 < nexp && nexp <= 0)
            out = "0." + std::string(static_cast<size_t>(-nexp), '0') + digits;
        else {
            int x = nexp - 1;
            out = digits.substr(0, 1) + (k > 1 ? "." + digits.substr(1) : "") + "e" + (x < 0 ? "-" : "+")
                + std::to_string(x < 0 ? -x : x);
        }
        return neg ? "-" + out : out;
    }
    static void quote(const std::string& v, std::string& out) {
        static const char* hex = "0123456789abcdef";
        out += '"';
        for (size_t i = 0; i < v.size(); i++) {
            unsigned char c = static_cast<unsigned char>(v[i]);
            if (c == '"')
                out += "\\\"";
            else if (c == '\\')
                out += "\\\\";
            else if (c == '\n')
                out += "\\n";
            else if (c == '\r')
                out += "\\r";
            else if (c == '\t')
                out += "\\t";
            else if (c == '\b')
                out += "\\b";
            else if (c == '\f')
                out += "\\f";
            else if (c < 0x20)
                out += std::string("\\u00") + hex[c >> 4] + hex[c & 15];
            else if (c == 0xED && i + 2 < v.size() && (static_cast<unsigned char>(v[i + 1]) & 0xE0) == 0xA0) {
                unsigned u = 0xD000u | ((static_cast<unsigned char>(v[i + 1]) & 0x3Fu) << 6)
                    | (static_cast<unsigned char>(v[i + 2]) & 0x3Fu);
                out += std::string("\\u") + hex[(u >> 12) & 15] + hex[(u >> 8) & 15] + hex[(u >> 4) & 15] + hex[u & 15];
                i += 2;
            } else
                out += static_cast<char>(c);
        }
        out += '"';
    }
    void dump_to(std::string& out) const {
        switch (t) {
        case T::undef:
            out += "null";
            break;
        case T::null:
            out += "null";
            break;
        case T::boolean:
            out += b ? "true" : "false";
            break;
        case T::num:
            out += std::isfinite(n) ? number(n) : "null";
            break;
        case T::str:
            quote(s, out);
            break;
        case T::arr:
            out += '[';
            for (size_t i = 0; i < a.size(); i++) {
                if (i)
                    out += ',';
                a[i].dump_to(out);
            }
            out += ']';
            break;
        case T::obj: {
            out += '{';
            bool first = true;
            for (auto& p : o) {
                if (p.second.is_undef())
                    continue;
                if (!first)
                    out += ',';
                first = false;
                quote(p.first, out);
                out += ':';
                p.second.dump_to(out);
            }
            out += '}';
            break;
        }
        }
    }
    std::string dump() const {
        if (t == T::undef)
            return "undefined";
        std::string out;
        dump_to(out);
        return out;
    }

    static J parse(std::string_view text, bool* ok = nullptr) {
        size_t i = 0;
        bool good = true;
        J v;
        skip(text, i);
        if (text.substr(i) == "undefined")
            v = J(), i = text.size();
        else
            v = value(text, i, good, 0);
        skip(text, i);
        if (i != text.size())
            good = false;
        if (ok)
            *ok = good;
        return good ? v : J();
    }

  private:
    static void skip(std::string_view t, size_t& i) {
        while (i < t.size() && (t[i] == ' ' || t[i] == '\n' || t[i] == '\r' || t[i] == '\t'))
            i++;
    }
    static void utf8(unsigned cp, std::string& out) {
        if (cp < 0x80)
            out += static_cast<char>(cp);
        else if (cp < 0x800)
            out += static_cast<char>(0xC0 | (cp >> 6)), out += static_cast<char>(0x80 | (cp & 0x3F));
        else if (cp < 0x10000)
            out += static_cast<char>(0xE0 | (cp >> 12)), out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F)),
                out += static_cast<char>(0x80 | (cp & 0x3F));
        else
            out += static_cast<char>(0xF0 | (cp >> 18)), out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F)),
                out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F)), out += static_cast<char>(0x80 | (cp & 0x3F));
    }
    static bool hex4(std::string_view t, size_t i, unsigned& u) {
        if (i + 4 > t.size())
            return false;
        u = 0;
        for (size_t k = i; k < i + 4; k++) {
            char c = t[k];
            u <<= 4;
            if (c >= '0' && c <= '9')
                u |= static_cast<unsigned>(c - '0');
            else if (c >= 'a' && c <= 'f')
                u |= static_cast<unsigned>(c - 'a' + 10);
            else if (c >= 'A' && c <= 'F')
                u |= static_cast<unsigned>(c - 'A' + 10);
            else
                return false;
        }
        return true;
    }
    static bool string(std::string_view t, size_t& i, std::string& out) {
        i++;
        while (i < t.size() && t[i] != '"') {
            char c = t[i];
            if (static_cast<unsigned char>(c) < 0x20)
                return false;
            if (c != '\\') {
                out += c, i++;
                continue;
            }
            if (++i >= t.size())
                return false;
            char e = t[i++];
            switch (e) {
            case '"':
                out += '"';
                break;
            case '\\':
                out += '\\';
                break;
            case '/':
                out += '/';
                break;
            case 'b':
                out += '\b';
                break;
            case 'f':
                out += '\f';
                break;
            case 'n':
                out += '\n';
                break;
            case 'r':
                out += '\r';
                break;
            case 't':
                out += '\t';
                break;
            case 'u': {
                unsigned u;
                if (!hex4(t, i, u))
                    return false;
                i += 4;
                unsigned lo;
                if (u >= 0xD800 && u < 0xDC00 && i + 6 <= t.size() && t[i] == '\\' && t[i + 1] == 'u'
                    && hex4(t, i + 2, lo) && lo >= 0xDC00 && lo < 0xE000) {
                    utf8(0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00), out);
                    i += 6;
                } else
                    utf8(u, out);
                break;
            }
            default:
                return false;
            }
        }
        if (i >= t.size())
            return false;
        i++;
        return true;
    }
    static J value(std::string_view t, size_t& i, bool& ok, int depth) {
        skip(t, i);
        if (i >= t.size() || depth > 512)
            return ok = false, J();
        char c = t[i];
        if (c == '{') {
            J o = object();
            i++;
            skip(t, i);
            if (i < t.size() && t[i] == '}')
                return i++, o;
            while (ok) {
                skip(t, i);
                std::string k;
                if (i >= t.size() || t[i] != '"' || !string(t, i, k))
                    return ok = false, J();
                skip(t, i);
                if (i >= t.size() || t[i] != ':')
                    return ok = false, J();
                i++;
                o.set(k, value(t, i, ok, depth + 1));
                skip(t, i);
                if (i < t.size() && t[i] == ',') {
                    i++;
                    continue;
                }
                if (i < t.size() && t[i] == '}')
                    return i++, o;
                ok = false;
            }
            return J();
        }
        if (c == '[') {
            J a = array();
            i++;
            skip(t, i);
            if (i < t.size() && t[i] == ']')
                return i++, a;
            while (ok) {
                a.push(value(t, i, ok, depth + 1));
                skip(t, i);
                if (i < t.size() && t[i] == ',') {
                    i++;
                    continue;
                }
                if (i < t.size() && t[i] == ']')
                    return i++, a;
                ok = false;
            }
            return J();
        }
        if (c == '"') {
            std::string s;
            if (!string(t, i, s))
                return ok = false, J();
            return J(std::move(s));
        }
        if (t.substr(i, 4) == "true")
            return i += 4, J(true);
        if (t.substr(i, 5) == "false")
            return i += 5, J(false);
        if (t.substr(i, 4) == "null")
            return i += 4, J(nullptr);
        size_t start = i;
        if (i < t.size() && t[i] == '-')
            i++;
        while (i < t.size()
               && ((t[i] >= '0' && t[i] <= '9') || t[i] == '.' || t[i] == 'e' || t[i] == 'E' || t[i] == '+'
                   || t[i] == '-'))
            i++;
        double d = 0;
        auto r = std::from_chars(t.data() + start, t.data() + i, d);
        if (start == i || r.ptr != t.data() + i)
            return ok = false, J();
        return J(d);
    }
};

}
