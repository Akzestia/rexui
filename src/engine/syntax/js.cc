// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/syntax/js.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "engine/base/utf.h"

namespace rx::engine::js {
namespace {

enum class T : uint8_t { eof, name, num, str, tmpl, regex, punct, error };

struct Token {
    T type;
    bool nl;
    bool tmpl_tail;
    bool bad_escape;
    uint32_t pos, end;
    std::string_view text;
    std::string_view flags;
    double num;
    uint32_t code;
};

constexpr uint32_t pack(std::string_view p) {
    uint32_t c = 0;
    for (size_t k = 0; k < p.size() && k < 4; k++)
        c |= static_cast<uint32_t>(static_cast<uint8_t>(p[k])) << (8 * k);
    return c;
}

bool id_start(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '$';
}
bool id_part(char c) {
    return id_start(c) || (c >= '0' && c <= '9');
}
bool digit(char c) {
    return c >= '0' && c <= '9';
}
int hexval(char c) {
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

bool reserved(std::string_view s) {
    if (s.size() < 2 || s.size() > 10 || s[0] < 'b' || s[0] > 'w' || !std::strchr("bcdefinrstvw", s[0]))
        return false;
    static constexpr std::string_view k[] = {
        "break", "case",   "catch", "class",      "const",   "continue", "debugger", "default", "delete",
        "do",    "else",   "enum",  "export",     "extends", "false",    "finally",  "for",     "function",
        "if",    "import", "in",    "instanceof", "new",     "null",     "return",   "super",   "switch",
        "this",  "throw",  "true",  "try",        "typeof",  "var",      "void",     "while",   "with"};
    for (std::string_view w : k)
        if (w == s)
            return true;
    return false;
}

constexpr std::string_view k_puncts[] = {
    ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "?\?=", "=>", "==", "!=", "<=",
    ">=",   "&&",  "||",  "??",  "?.",  "++",  "--",  "+=",  "-=",  "*=",  "/=",   "%=", "&=", "|=", "^=",
    "**",   "<<",  ">>",  "{",   "}",   "(",   ")",   "[",   "]",   ";",   ",",    "<",  ">",  "+",  "-",
    "*",    "/",   "%",   "&",   "|",   "^",   "!",   "~",   "?",   ":",   "=",    ".",  "@",  "#"};

struct Scope {
    struct Name {
        std::string_view name;
        uint8_t kind;
    };
    Scope* up;
    bool function;
    List<Name> names;
};
enum : uint8_t { k_var, k_lex, k_param, k_func, k_catch };

struct Parser {
    std::string_view src;
    uint32_t begin, limit;
    Arena& arena;
    Token tok{};
    uint32_t i;
    Parser(std::string_view s, uint32_t b, uint32_t l, Arena& a) : src(s), begin(b), limit(l), arena(a), i(b) {}
    bool failed = false;
    Error error{};
    int loops = 0;
    int switches = 0;
    int depth = 0;
    Scope* scope = nullptr;
    bool cover_init = false;
    uint32_t cover_pos = 0;
    bool cover_ok = false;
    bool final_semi = false;
    bool params_text = false;
    bool value_text = false;

    char at(uint32_t k) const { return k < limit ? src[k] : '\0'; }

    bool fail(uint32_t pos, bool subset, const char* fmt, ...) __attribute__((format(printf, 4, 5))) {
        if (failed)
            return false;
        char buf[400];
        va_list ap;
        va_start(ap, fmt);
        int len = std::vsnprintf(buf, sizeof buf, fmt, ap);
        va_end(ap);
        size_t m = len < 0 ? 0 : static_cast<size_t>(len) < sizeof buf ? static_cast<size_t>(len) : sizeof buf - 1;
        failed = true;
        error = {pos, arena.copy({buf, m}), subset};
        return false;
    }
    bool subset(uint32_t pos, const char* what) { return fail(pos, true, "%s isn't in the .rui language", what); }
    void describe(char* buf, size_t n) const {
        switch (tok.type) {
        case T::eof:
            std::snprintf(buf, n, "the end of the value");
            break;
        case T::num:
            std::snprintf(buf, n, "a number");
            break;
        case T::str:
            std::snprintf(buf, n, "a string");
            break;
        case T::tmpl:
            std::snprintf(buf, n, "a template");
            break;
        case T::regex:
            std::snprintf(buf, n, "a regex");
            break;
        default:
            std::snprintf(buf, n, "'%.*s'", static_cast<int>(tok.text.size() < 40 ? tok.text.size() : 40),
                          tok.text.data());
        }
    }
    bool expected(const char* what) {
        char d[64];
        describe(d, sizeof d);
        return fail(tok.pos, false, "expected %s, found %s", what, d);
    }

    bool skip(bool& nl) {
        nl = false;
        while (i < limit) {
            char c = src[i];
            if (c == ' ' || c == '\t' || c == '\v' || c == '\f') {
                i++;
                continue;
            }
            if (c == '\n' || c == '\r') {
                nl = true, i++;
                continue;
            }
            if (c == '/' && at(i + 1) == '/') {
                uint32_t cs = i;
                while (i < limit && src[i] != '\n' && src[i] != '\r') {
                    utf::Cp cp = utf::decode(src, i);
                    if (cp.cp == 0x2028 || cp.cp == 0x2029)
                        break;
                    i += cp.len ? cp.len : 1;
                }
                if (i >= limit) {
                    if (params_text)
                        return fail(cs, false, "a // comment at the end of the parameters takes their )");
                    if (value_text)
                        return fail(cs, false,
                                    "a // comment at the end of a value takes the ) runtime.js puts after it");
                    final_semi = false;
                }
                continue;
            }
            if (c == '/' && at(i + 1) == '*') {
                uint32_t s = i;
                i += 2;
                while (i < limit && !(src[i] == '*' && at(i + 1) == '/')) {
                    utf::Cp cp = utf::decode(src, i);
                    if (cp.cp == '\n' || cp.cp == '\r' || cp.cp == 0x2028 || cp.cp == 0x2029)
                        nl = true;
                    i += cp.len ? cp.len : 1;
                }
                if (i >= limit)
                    return fail(s, false, "unterminated /* comment");
                i += 2;
                continue;
            }
            if (static_cast<uint8_t>(c) >= 0x80) {
                utf::Cp cp = utf::decode(src, i);
                if (cp.len && utf::js_space(cp.cp)) {
                    if (cp.cp == 0x2028 || cp.cp == 0x2029)
                        nl = true;
                    i += cp.len;
                    continue;
                }
            }
            return true;
        }
        return true;
    }

    bool next() {
        bool nl;
        if (!skip(nl))
            return tok.type = T::error, false;
        tok = Token{};
        tok.nl = nl;
        tok.pos = i;
        if (i >= limit) {
            if (final_semi) {
                final_semi = false;
                tok.type = T::punct;
                tok.text = ";";
                tok.code = pack(";");
                tok.end = i;
                return true;
            }
            tok.type = T::eof;
            tok.end = i;
            return true;
        }
        char c = src[i];
        if (id_start(c)) {
            while (id_part(at(i)))
                i++;
            if (at(i) == '\\')
                return fail(i, true, "an escape in a name isn't in the .rui language");
            if (static_cast<uint8_t>(at(i)) >= 0x80 && !utf::js_space(utf::decode(src, i).cp))
                return subset(tok.pos, "a name with characters past ASCII");
            tok.type = T::name;
        } else if (digit(c) || (c == '.' && digit(at(i + 1)))) {
            if (!number())
                return false;
        } else if (c == '"' || c == '\'') {
            if (!string(c))
                return false;
        } else if (c == '`') {
            i++;
            if (!template_piece())
                return false;
        } else if (static_cast<uint8_t>(c) >= 0x80) {
            return subset(i, "a name with characters past ASCII");
        } else if (c == '\\') {
            return fail(i, true, "an escape in a name isn't in the .rui language");
        } else {
            std::string_view rest = src.substr(i, limit - i < 4 ? limit - i : 4);
            for (std::string_view p : k_puncts) {
                if (p[0] != c || !rest.starts_with(p))
                    continue;
                if (p == "?." && digit(at(i + 2)))
                    continue;
                i += static_cast<uint32_t>(p.size());
                tok.type = T::punct;
                tok.code = pack(p);
                break;
            }
            if (tok.type != T::punct)
                return fail(i, false, "unexpected character '%c'", c);
            if (src[tok.pos] == '#')
                return subset(tok.pos, "a private name (#x)");
            if (src[tok.pos] == '@')
                return subset(tok.pos, "a decorator (@x)");
        }
        tok.end = i;
        if (tok.type == T::name || tok.type == T::punct)
            tok.text = src.substr(tok.pos, i - tok.pos);
        return true;
    }

    bool number() {
        uint32_t s = i;
        char buf[512];
        size_t n = 0;
        auto put = [&](char ch) {
            if (n < sizeof buf - 1)
                buf[n++] = ch;
        };
        auto digits = [&](auto ok) -> bool {
            bool any = false, under = false;
            while (ok(at(i)) || at(i) == '_') {
                if (at(i) == '_') {
                    if (!any || under)
                        return fail(i, false, "a _ in a number goes between digits");
                    under = true, i++;
                    continue;
                }
                put(src[i++]);
                any = true, under = false;
            }
            if (under)
                return fail(i - 1, false, "a _ in a number goes between digits");
            return true;
        };
        double v = 0;
        if (at(i) == '0'
            && (at(i + 1) == 'x' || at(i + 1) == 'X' || at(i + 1) == 'o' || at(i + 1) == 'O' || at(i + 1) == 'b'
                || at(i + 1) == 'B')) {
            char b = static_cast<char>(at(i + 1) | 0x20);
            int base = b == 'x' ? 16 : b == 'o' ? 8 : 2;
            i += 2;
            uint32_t ds = i;
            if (!digits([&](char ch) {
                    int h = hexval(ch);
                    return h >= 0 && h < base;
                }))
                return false;
            if (i == ds)
                return fail(i, false, "a number has no digits after 0%c", b);
            for (size_t k = 0; k < n; k++)
                v = v * base + hexval(buf[k]);
        } else if (at(i) == '0' && digit(at(i + 1))) {
            bool octal = true;
            uint32_t k = i;
            while (digit(at(k)))
                octal = octal && at(k) < '8', k++;
            if (octal) {
                while (digit(at(i)))
                    v = v * 8 + (src[i++] - '0');
            } else {
                while (digit(at(i)))
                    put(src[i++]);
                if (at(i) == '.') {
                    put('.'), i++;
                    while (digit(at(i)))
                        put(src[i++]);
                }
                if (at(i) == 'e' || at(i) == 'E') {
                    put('e'), i++;
                    if (at(i) == '+' || at(i) == '-')
                        put(src[i++]);
                    if (!digit(at(i)))
                        return fail(i, false, "a number's exponent has no digits");
                    while (digit(at(i)))
                        put(src[i++]);
                }
                buf[n] = 0;
                v = std::strtod(buf, nullptr);
            }
            if (at(i) == '_')
                return fail(i, false, "a _ can't be in a number that starts with 0");
        } else {
            if (!digits(digit))
                return false;
            if (at(i) == '.') {
                put('.'), i++;
                if (at(i) == '_')
                    return fail(i, false, "a _ in a number goes between digits");
                if (!digits(digit))
                    return false;
            }
            if (at(i) == 'e' || at(i) == 'E') {
                put('e'), i++;
                if (at(i) == '+' || at(i) == '-')
                    put(src[i++]);
                uint32_t es = i;
                if (!digits(digit))
                    return false;
                if (i == es)
                    return fail(i, false, "a number's exponent has no digits");
            }
            buf[n] = 0;
            v = std::strtod(buf, nullptr);
        }
        if (at(i) == 'n')
            return subset(s, "a BigInt (1n)");
        if (id_start(at(i)) || digit(at(i)) || at(i) == '\\')
            return fail(i, false, "a name can't start right after a number");
        tok.type = T::num;
        tok.num = v;
        return true;
    }

    bool escape(bool& bad, bool tmpl) {
        char c = at(i);
        if (c == 'x') {
            if (hexval(at(i + 1)) < 0 || hexval(at(i + 2)) < 0)
                return bad = true, false;
            i += 3;
            return true;
        }
        if (c == 'u') {
            if (at(i + 1) == '{') {
                uint32_t k = i + 2;
                uint32_t v = 0;
                bool any = false;
                while (hexval(at(k)) >= 0) {
                    v = v * 16 + static_cast<uint32_t>(hexval(at(k)));
                    if (v > 0x10FFFF)
                        return bad = true, false;
                    k++, any = true;
                }
                if (!any || at(k) != '}')
                    return bad = true, false;
                i = k + 1;
                return true;
            }
            for (uint32_t k = 1; k <= 4; k++)
                if (hexval(at(i + k)) < 0)
                    return bad = true, false;
            i += 5;
            return true;
        }
        if (digit(c)) {
            if (c == '0' && !digit(at(i + 1))) {
                i++;
                return true;
            }
            if (tmpl)
                return bad = true, false;
            i++;
            return true;
        }
        if (c == '\r' && at(i + 1) == '\n') {
            i += 2;
            return true;
        }
        utf::Cp cp = utf::decode(src, i);
        i += cp.len ? cp.len : 1;
        return true;
    }

    bool string(char q) {
        uint32_t s = i++;
        while (i < limit) {
            char c = src[i];
            if (c == q) {
                tok.type = T::str;
                tok.text = src.substr(s + 1, i - s - 1);
                i++;
                return true;
            }
            if (c == '\n' || c == '\r')
                break;
            if (c == '\\') {
                i++;
                bool bad = false;
                if (i >= limit)
                    break;
                if (!escape(bad, false))
                    return fail(i, false, "a malformed escape in a string");
                continue;
            }
            utf::Cp cp = utf::decode(src, i);
            i += cp.len ? cp.len : 1;
        }
        return fail(s, false, "unterminated string");
    }

    bool template_piece() {
        uint32_t s = i;
        tok.type = T::tmpl;
        while (i < limit) {
            char c = src[i];
            if (c == '`') {
                tok.text = src.substr(s, i - s);
                tok.tmpl_tail = true;
                i++;
                return true;
            }
            if (c == '$' && at(i + 1) == '{') {
                tok.text = src.substr(s, i - s);
                i += 2;
                return true;
            }
            if (c == '\\') {
                i++;
                if (i >= limit)
                    break;
                bool bad = false;
                if (!escape(bad, true)) {
                    tok.bad_escape = true;
                    i++;
                }
                continue;
            }
            utf::Cp cp = utf::decode(src, i);
            i += cp.len ? cp.len : 1;
        }
        return fail(tok.pos, false, "unterminated template");
    }

    bool regex() {
        i = tok.pos + 1;
        bool cls = false;
        while (true) {
            if (i >= limit)
                return fail(tok.pos, false, "unterminated regex");
            char c = src[i];
            if (c == '\n' || c == '\r')
                return fail(tok.pos, false, "unterminated regex");
            utf::Cp cp = utf::decode(src, i);
            if (cp.cp == 0x2028 || cp.cp == 0x2029)
                return fail(tok.pos, false, "unterminated regex");
            if (c == '\\') {
                i++;
                if (i >= limit || src[i] == '\n' || src[i] == '\r')
                    return fail(tok.pos, false, "unterminated regex");
                cp = utf::decode(src, i);
                i += cp.len ? cp.len : 1;
                continue;
            }
            if (c == '[')
                cls = true;
            else if (c == ']')
                cls = false;
            else if (c == '/' && !cls)
                break;
            i += cp.len ? cp.len : 1;
        }
        tok.text = src.substr(tok.pos + 1, i - tok.pos - 1);
        i++;
        uint32_t fs = i;
        while (id_part(at(i)))
            i++;
        tok.flags = src.substr(fs, i - fs);
        for (size_t k = 0; k < tok.flags.size(); k++) {
            char f = tok.flags[k];
            if (f == 'u' || f == 'v')
                return fail(fs + static_cast<uint32_t>(k), true, "the regex flag %c isn't in the .rui language", f);
            if (!std::strchr("dgimsy", f))
                return fail(fs + static_cast<uint32_t>(k), false, "unknown regex flag %c", f);
            if (tok.flags.substr(0, k).find(f) != std::string_view::npos)
                return fail(fs + static_cast<uint32_t>(k), false, "the regex flag %c twice", f);
        }
        if (!regex_check(tok.text, tok.pos + 1))
            return false;
        tok.type = T::regex;
        tok.end = i;
        return true;
    }

    bool regex_check(std::string_view p, uint32_t base) {
        int groups = 0;
        bool atom = false;
        for (size_t k = 0; k < p.size(); k++) {
            char c = p[k];
            uint32_t at_ = base + static_cast<uint32_t>(k);
            if (c == '\\') {
                k++;
                atom = true;
                continue;
            }
            if (c == '[') {
                k++;
                if (k < p.size() && p[k] == '^')
                    k++;
                if (!regex_class(p, k, base))
                    return false;
                if (k >= p.size())
                    return fail(at_, false, "a regex's [ has no ]");
                atom = true;
                continue;
            }
            if (c == '(') {
                groups++;
                atom = false;
                if (k + 1 < p.size() && p[k + 1] == '?') {
                    std::string_view r = p.substr(k + 2);
                    if (r.starts_with(":") || r.starts_with("=") || r.starts_with("!"))
                        k += 2;
                    else if (r.starts_with("<=") || r.starts_with("<!"))
                        k += 3;
                    else if (r.starts_with("<")) {
                        size_t e = r.find('>');
                        if (e == std::string_view::npos || e == 1)
                            return fail(at_, false, "a regex's named group has no name");
                        k += 2 + e;
                    } else
                        return fail(at_, false, "a regex's (? is one of (?: (?= (?! (?<= (?<! (?<name>");
                }
                continue;
            }
            if (c == ')') {
                if (--groups < 0)
                    return fail(at_, false, "a regex's ) has no (");
                atom = true;
                continue;
            }
            if (c == '*' || c == '+' || c == '?') {
                if (!atom)
                    return fail(at_, false, "nothing to repeat in a regex");
                if (k + 1 < p.size() && p[k + 1] == '?')
                    k++;
                atom = false;
                continue;
            }
            if (c == '{') {
                size_t e = k + 1;
                long lo = -1, hi = -1;
                if (e < p.size() && digit(p[e])) {
                    lo = 0;
                    while (e < p.size() && digit(p[e]))
                        lo = lo * 10 + (p[e++] - '0'), lo = lo > 1000000 ? 1000000 : lo;
                    if (e < p.size() && p[e] == ',') {
                        e++;
                        if (e < p.size() && digit(p[e])) {
                            hi = 0;
                            while (e < p.size() && digit(p[e]))
                                hi = hi * 10 + (p[e++] - '0'), hi = hi > 1000000 ? 1000000 : hi;
                        } else
                            hi = -2;
                    } else
                        hi = lo;
                    if (e < p.size() && p[e] == '}') {
                        if (!atom)
                            return fail(at_, false, "nothing to repeat in a regex");
                        if (hi >= 0 && hi < lo)
                            return fail(at_, false, "a regex's {n,m} has m < n");
                        k = e;
                        if (k + 1 < p.size() && p[k + 1] == '?')
                            k++;
                        atom = false;
                        continue;
                    }
                }
                atom = true;
                continue;
            }
            if (c == '|') {
                atom = false;
                continue;
            }
            if (c == '^' || c == '$') {
                atom = false;
                continue;
            }
            atom = true;
        }
        if (groups)
            return fail(base, false, "a regex's ( has no )");
        return true;
    }

    bool regex_class(std::string_view p, size_t& k, uint32_t base) {
        char16_t units[2];
        int pending = 0;
        auto atom = [&](long& v) -> bool {
            if (pending) {
                v = units[--pending == 0 ? 1 : 0];
                return true;
            }
            if (k >= p.size() || p[k] == ']')
                return false;
            char c = p[k];
            if (c == '\\') {
                k++;
                char e = k < p.size() ? p[k] : '\0';
                k++;
                switch (e) {
                case 'd':
                case 'D':
                case 'w':
                case 'W':
                case 's':
                case 'S':
                    v = -1;
                    return true;
                case 'b':
                    v = 8;
                    return true;
                case 't':
                    v = 9;
                    return true;
                case 'n':
                    v = 10;
                    return true;
                case 'v':
                    v = 11;
                    return true;
                case 'f':
                    v = 12;
                    return true;
                case 'r':
                    v = 13;
                    return true;
                case 'c':
                    if (k < p.size() && ((p[k] | 0x20) >= 'a' && (p[k] | 0x20) <= 'z')) {
                        v = p[k++] % 32;
                        return true;
                    }
                    if (k < p.size() && (digit(p[k]) || p[k] == '_')) {
                        v = p[k++] % 32;
                        return true;
                    }
                    v = '\\';
                    k--;
                    return true;
                case 'x':
                    if (k + 1 < p.size() && hexval(p[k]) >= 0 && hexval(p[k + 1]) >= 0) {
                        v = hexval(p[k]) * 16 + hexval(p[k + 1]);
                        k += 2;
                    } else
                        v = 'x';
                    return true;
                case 'u':
                    if (k + 3 < p.size() && hexval(p[k]) >= 0 && hexval(p[k + 1]) >= 0 && hexval(p[k + 2]) >= 0
                        && hexval(p[k + 3]) >= 0) {
                        v = ((hexval(p[k]) * 16 + hexval(p[k + 1])) * 16 + hexval(p[k + 2])) * 16 + hexval(p[k + 3]);
                        k += 4;
                    } else
                        v = 'u';
                    return true;
                default:
                    if (e >= '0' && e <= '7') {
                        long o = e - '0';
                        if (k < p.size() && p[k] >= '0' && p[k] <= '7') {
                            o = o * 8 + (p[k++] - '0');
                            if (o < 32 && k < p.size() && p[k] >= '0' && p[k] <= '7')
                                o = o * 8 + (p[k++] - '0');
                        }
                        v = o;
                        return true;
                    }
                    k--;
                    break;
                }
            }
            utf::Cp cp = utf::decode(p, k);
            k += cp.len ? cp.len : 1;
            if (cp.cp >= 0x10000) {
                units[0] = static_cast<char16_t>(0xD800 + ((cp.cp - 0x10000) >> 10));
                units[1] = static_cast<char16_t>(0xDC00 + ((cp.cp - 0x10000) & 0x3FF));
                v = units[0];
                pending = 1;
                return true;
            }
            v = static_cast<long>(cp.cp);
            return true;
        };
        long a;
        while (atom(a)) {
            if (pending || k >= p.size() || p[k] != '-' || k + 1 >= p.size() || p[k + 1] == ']')
                continue;
            size_t dash = k;
            k++;
            long b;
            if (!atom(b))
                return true;
            if (a >= 0 && b >= 0 && a > b)
                return fail(base + static_cast<uint32_t>(dash), false, "a regex class's range is out of order");
        }
        return true;
    }

    bool is(const char* p) const { return tok.type == T::punct && tok.code == pack(p); }
    bool is_name(const char* w) const { return tok.type == T::name && tok.text == w; }
    bool eat(const char* p) {
        if (!is(p))
            return false;
        next();
        return true;
    }
    bool want(const char* p) {
        if (failed)
            return false;
        if (!is(p)) {
            char w[16];
            std::snprintf(w, sizeof w, "'%s'", p);
            return expected(w);
        }
        return advance();
    }
    struct Mark {
        Token tok;
        uint32_t i;
        bool final_semi;
    };
    Mark mark() const { return {tok, i, final_semi}; }
    void reset(const Mark& m) { tok = m.tok, i = m.i, final_semi = m.final_semi; }
    Token peek() {
        Mark m = mark();
        Error e = error;
        bool f = failed;
        next();
        Token t = failed && !f ? Token{} : tok;
        reset(m);
        failed = f;
        error = e;
        return t;
    }
    bool semicolon() {
        if (failed)
            return false;
        if (is(";"))
            return next();
        if (is("}") || tok.type == T::eof || tok.nl)
            return true;
        return expected("';'");
    }

    Node* node(K k, uint32_t pos) {
        Node* n = arena.make<Node>();
        if (!n) {
            fail(pos, false, "out of memory");
            return nullptr;
        }
        n->kind = k;
        n->pos = pos;
        n->end = pos;
        return n;
    }
    Node* done(Node* n) {
        if (n)
            n->end = prev_end;
        return n;
    }
    uint32_t prev_end = 0;
    bool advance() {
        prev_end = tok.end;
        return next();
    }

    struct ListB {
        Node *head = nullptr, *tail = nullptr;
        void add(Node* n) {
            if (!n)
                return;
            if (tail)
                tail->next = n;
            else
                head = n;
            tail = n;
        }
    };

    struct Depth {
        Parser& p;
        explicit Depth(Parser& q) : p(q) { p.depth++; }
        ~Depth() { p.depth--; }
        bool ok() { return p.depth < 400 || p.fail(p.tok.pos, false, "nested too deeply"); }
    };

    bool open_scope(bool function) {
        Scope* s = arena.make<Scope>();
        if (!s)
            return fail(tok.pos, false, "out of memory");
        s->up = scope;
        s->function = function;
        scope = s;
        return true;
    }
    void close_scope() { scope = scope->up; }
    bool redeclared(uint32_t pos, std::string_view n) {
        return fail(pos, false, "%.*s is declared twice", static_cast<int>(n.size() < 80 ? n.size() : 80), n.data());
    }
    bool declare(std::string_view n, uint8_t kind, uint32_t pos) {
        if (kind == k_lex) {
            if (n == "let")
                return fail(pos, false, "let can't be a let or const name");
            for (const Scope::Name& x : scope->names)
                if (x.name == n)
                    return redeclared(pos, n);
            if (scope->function && scope->up)
                for (const Scope::Name& x : scope->up->names)
                    if (x.name == n && x.kind == k_param)
                        return redeclared(pos, n);
            return scope->names.push(arena, {n, kind}) || fail(pos, false, "out of memory");
        }
        if (kind == k_var || kind == k_func) {
            for (Scope* s = scope; s; s = s->up) {
                for (const Scope::Name& x : s->names)
                    if (x.name == n && x.kind == k_lex)
                        return redeclared(pos, n);
                if (!s->names.push(arena, {n, kind}))
                    return fail(pos, false, "out of memory");
                if (s->function)
                    break;
            }
            return true;
        }
        return scope->names.push(arena, {n, kind}) || fail(pos, false, "out of memory");
    }
    bool declare_pattern(Node* p, uint8_t kind) {
        if (!p)
            return true;
        switch (p->kind) {
        case K::ident:
            return declare(p->text, kind, p->pos);
        case K::array_pat:
            for (Node* e = p->a; e; e = e->next)
                if (!declare_pattern(e, kind))
                    return false;
            return true;
        case K::object_pat:
            for (Node* e = p->a; e; e = e->next)
                if (!declare_pattern(e->kind == K::prop ? e->b : e, kind))
                    return false;
            return true;
        case K::rest:
            return declare_pattern(p->a, kind);
        case K::default_:
            return declare_pattern(p->a, kind);
        default:
            return true;
        }
    }

    Node* binding_target() {
        Depth d(*this);
        if (!d.ok())
            return nullptr;
        uint32_t s = tok.pos;
        if (tok.type == T::name) {
            if (reserved(tok.text)) {
                if (tok.text == "this")
                    return subset(s, "this"), nullptr;
                expected("a name");
                return nullptr;
            }
            Node* n = node(K::ident, s);
            if (!n)
                return nullptr;
            n->text = tok.text;
            advance();
            return done(n);
        }
        if (is("[")) {
            Node* n = node(K::array_pat, s);
            advance();
            ListB l;
            while (!failed && !is("]")) {
                if (is(",")) {
                    l.add(node(K::hole, tok.pos));
                    advance();
                    continue;
                }
                if (is("...")) {
                    uint32_t rs = tok.pos;
                    advance();
                    Node* r = node(K::rest, rs);
                    if (r)
                        r->a = binding_target();
                    l.add(done(r));
                    if (!is("]"))
                        return expected("']' after a rest element"), nullptr;
                    break;
                }
                l.add(binding_element());
                if (!is("]") && !want(","))
                    return nullptr;
            }
            if (!want("]"))
                return nullptr;
            if (n)
                n->a = l.head;
            return done(n);
        }
        if (is("{")) {
            Node* n = node(K::object_pat, s);
            advance();
            ListB l;
            while (!failed && !is("}")) {
                if (is("...")) {
                    uint32_t rs = tok.pos;
                    advance();
                    Node* r = node(K::rest, rs);
                    if (r)
                        r->a = binding_target();
                    if (r && r->a && r->a->kind != K::ident)
                        return fail(rs, false, "a rest property takes a name"), nullptr;
                    l.add(done(r));
                    if (!is("}"))
                        return expected("'}' after a rest property"), nullptr;
                    break;
                }
                uint32_t ps = tok.pos;
                Node* p = node(K::prop, ps);
                if (!p)
                    return nullptr;
                bool name_key = tok.type == T::name;
                std::string_view key_text = tok.text;
                p->a = property_key(p->flags);
                if (!p->a)
                    return nullptr;
                if (is(":")) {
                    advance();
                    p->b = binding_element();
                } else {
                    if (!name_key || (p->flags & f_computed) || reserved(key_text))
                        return expected("':'"), nullptr;
                    p->flags |= f_shorthand;
                    Node* t = node(K::ident, ps);
                    if (t)
                        t->text = key_text, t->end = p->a->end;
                    p->b = t;
                    if (is("=")) {
                        advance();
                        Node* dn = node(K::default_, ps);
                        if (dn)
                            dn->a = t, dn->b = assign();
                        p->b = done(dn);
                    }
                }
                l.add(done(p));
                if (!is("}") && !want(","))
                    return nullptr;
            }
            if (!want("}"))
                return nullptr;
            if (n)
                n->a = l.head;
            return done(n);
        }
        expected("a name, [ or {");
        return nullptr;
    }
    Node* binding_element() {
        uint32_t s = tok.pos;
        Node* t = binding_target();
        if (!t || !is("="))
            return t;
        advance();
        Node* dn = node(K::default_, s);
        if (dn)
            dn->a = t, dn->b = assign();
        return done(dn);
    }

    Node* to_pattern(Node* e, bool binding) {
        if (!e)
            return nullptr;
        switch (e->kind) {
        case K::ident:
            return e;
        case K::member:
        case K::index:
            if (binding || (e->flags & (f_optional | f_chain)))
                break;
            return e;
        case K::paren:
            if (binding)
                break;
            if (e->a && (e->a->kind == K::ident || e->a->kind == K::member || e->a->kind == K::index) && !e->a->next)
                return to_pattern(e->a, false);
            break;
        case K::array: {
            e->kind = K::array_pat;
            for (Node** p = &e->a; *p; p = &(*p)->next) {
                Node* x = *p;
                if (x->kind == K::hole)
                    continue;
                Node* nx = x->next;
                if (x->kind == K::spread) {
                    if (nx || (e->flags & f_shorthand))
                        return fail(x->pos, false, "a rest element is last, with no comma after it"), nullptr;
                    x->kind = K::rest;
                    x->a = to_pattern(x->a, binding);
                    if (!x->a)
                        return nullptr;
                    continue;
                }
                Node* y = to_pattern(x, binding);
                if (!y)
                    return nullptr;
                y->next = nx;
                *p = y;
            }
            return e;
        }
        case K::object: {
            e->kind = K::object_pat;
            for (Node* x = e->a; x; x = x->next) {
                if (x->kind == K::spread) {
                    if (x->next)
                        return fail(x->pos, false, "a rest property is last"), nullptr;
                    x->kind = K::rest;
                    x->a = to_pattern(x->a, binding);
                    if (!x->a)
                        return nullptr;
                    if (x->a->kind != K::ident && (binding || (x->a->kind != K::member && x->a->kind != K::index)))
                        return fail(x->pos, false, "a rest property takes a name"), nullptr;
                    continue;
                }
                if (x->flags & f_method)
                    return fail(x->pos, false, "a method isn't a pattern"), nullptr;
                x->b = to_pattern(x->b, binding);
                if (!x->b)
                    return nullptr;
            }
            return e;
        }
        case K::assign:
            if (e->op != Op::assign)
                break;
            e->kind = K::default_;
            e->a = to_pattern(e->a, binding);
            return e->a ? e : nullptr;
        case K::default_:
            return e;
        default:
            break;
        }
        fail(e->pos, false, binding ? "a parameter is a name, [ ] or { }" : "not something a value can be assigned to");
        return nullptr;
    }

    Node* expression(bool no_in = false) {
        uint32_t s = tok.pos;
        Node* e = assign(no_in);
        if (!e || !is(","))
            return e;
        Node* q = node(K::seq, s);
        if (!q)
            return nullptr;
        ListB l;
        l.add(e);
        while (!failed && eat(","))
            l.add(assign(no_in));
        q->a = l.head;
        return done(q);
    }

    static Op assign_op(std::string_view t) {
        static constexpr std::pair<std::string_view, Op> k[] = {
            {"=", Op::assign},  {"+=", Op::add_a},    {"-=", Op::sub_a},  {"*=", Op::mul_a},
            {"/=", Op::div_a},  {"%=", Op::mod_a},    {"**=", Op::exp_a}, {"<<=", Op::shl_a},
            {">>=", Op::shr_a}, {">>>=", Op::ushr_a}, {"&=", Op::band_a}, {"|=", Op::bor_a},
            {"^=", Op::bxor_a}, {"&&=", Op::and_a},   {"||=", Op::or_a},  {"?\?=", Op::nullish_a}};
        for (auto& [w, o] : k)
            if (w == t)
                return o;
        return Op::none;
    }

    Node* assign(bool no_in = false) {
        Depth d(*this);
        if (!d.ok())
            return nullptr;
        if (failed)
            return nullptr;
        uint32_t s = tok.pos;
        bool may_cover = cover_ok;
        cover_ok = false;
        if (is_name("async")) {
            Token t = peek();
            if (!t.nl
                && ((t.type == T::name && t.text == "function") || (t.type == T::name && !reserved(t.text))
                    || (t.type == T::punct && t.text == "(")))
                return subset(s, "async"), nullptr;
        }
        if (is_name("yield")) {
        }
        if (tok.type == T::name && !reserved(tok.text)) {
            Token t = peek();
            if (t.type == T::punct && t.text == "=>") {
                if (t.nl)
                    return fail(t.pos, false, "no line break before =>"), nullptr;
                Node* p = node(K::ident, s);
                if (!p)
                    return nullptr;
                p->text = tok.text;
                advance();
                done(p);
                return arrow(s, p, no_in);
            }
        }
        cover_init = false;
        Node* left = conditional(no_in);
        if (!left)
            return nullptr;
        if (left->kind == K::paren && (left->flags & f_expr_body)) {
            Node* params = nullptr;
            ListB l;
            for (Node* x = left->a; x;) {
                Node* nx = x->next;
                x->next = nullptr;
                Node* p;
                if (x->kind == K::spread) {
                    if (nx)
                        return fail(x->pos, false, "a rest parameter is last"), nullptr;
                    x->kind = K::rest;
                    x->a = to_pattern(x->a, true);
                    if (!x->a)
                        return nullptr;
                    p = x;
                } else {
                    p = to_pattern(x, true);
                }
                if (!p)
                    return nullptr;
                l.add(p);
                x = nx;
            }
            params = l.head;
            cover_init = false;
            return arrow(s, params, no_in);
        }
        Op op = tok.type == T::punct ? assign_op(tok.text) : Op::none;
        if (op == Op::none) {
            if (cover_init && !(may_cover && (left->kind == K::object || left->kind == K::array)))
                return fail(cover_pos, false, "{ a = 1 } is only a pattern"), nullptr;
            return left;
        }
        Node* target;
        if (op == Op::assign && (left->kind == K::array || left->kind == K::object)) {
            target = to_pattern(left, false);
            cover_init = false;
        } else {
            if (cover_init)
                return fail(cover_pos, false, "{ a = 1 } is only a pattern"), nullptr;
            Node* t = left;
            while (t->kind == K::paren && t->a && !t->a->next)
                t = t->a;
            bool logical = op == Op::and_a || op == Op::or_a || op == Op::nullish_a;
            if (!simple_target(t) || (logical && t->kind == K::call))
                return fail(left->pos, false, "not something a value can be assigned to"), nullptr;
            target = t;
        }
        if (!target)
            return nullptr;
        advance();
        Node* n = node(K::assign, s);
        if (!n)
            return nullptr;
        n->op = op;
        n->a = target;
        n->b = assign(no_in);
        if (!n->b)
            return nullptr;
        return done(n);
    }

    Node* arrow(uint32_t s, Node* params, bool no_in) {
        if (tok.nl)
            return fail(tok.pos, false, "no line break before =>"), nullptr;
        if (!want("=>"))
            return nullptr;
        Node* f = node(K::arrow, s);
        if (!f)
            return nullptr;
        f->a = params;
        if (!open_scope(false))
            return nullptr;
        for (Node* p = params; p; p = p->next) {
            for (Node* q = params; q != p; q = q->next)
                if (!check_distinct(p, q))
                    return nullptr;
            if (!declare_pattern(p, k_param))
                return nullptr;
        }
        int was = loops, was_switches = switches;
        loops = 0, switches = 0;
        if (is("{")) {
            f->b = function_body();
        } else {
            f->flags |= f_expr_body;
            f->b = assign(no_in);
        }
        loops = was, switches = was_switches;
        close_scope();
        if (!f->b)
            return nullptr;
        return done(f);
    }
    bool check_distinct(Node* p, Node* q) {
        if (!p || !q)
            return true;
        if (p->kind == K::ident)
            return names_avoid(q, p->text, p->pos);
        switch (p->kind) {
        case K::array_pat:
            for (Node* e = p->a; e; e = e->next)
                if (!check_distinct(e, q))
                    return false;
            return true;
        case K::object_pat:
            for (Node* e = p->a; e; e = e->next)
                if (!check_distinct(e->kind == K::prop ? e->b : e, q))
                    return false;
            return true;
        case K::rest:
        case K::default_:
            return check_distinct(p->a, q);
        default:
            return true;
        }
    }
    bool names_avoid(Node* q, std::string_view n, uint32_t pos) {
        if (!q)
            return true;
        switch (q->kind) {
        case K::ident:
            return q->text != n || redeclared(pos, n);
        case K::array_pat:
            for (Node* e = q->a; e; e = e->next)
                if (!names_avoid(e, n, pos))
                    return false;
            return true;
        case K::object_pat:
            for (Node* e = q->a; e; e = e->next)
                if (!names_avoid(e->kind == K::prop ? e->b : e, n, pos))
                    return false;
            return true;
        case K::rest:
        case K::default_:
            return names_avoid(q->a, n, pos);
        default:
            return true;
        }
    }

    Node* conditional(bool no_in) {
        uint32_t s = tok.pos;
        Node* t = binary(0, no_in);
        if (!t || !is("?"))
            return t;
        if (t->kind == K::arrow)
            return fail(tok.pos, false, "an arrow function needs ( ) around it here"), nullptr;
        advance();
        Node* n = node(K::cond, s);
        if (!n)
            return nullptr;
        n->a = t;
        n->b = assign(false);
        if (!want(":"))
            return nullptr;
        n->c = assign(no_in);
        if (!n->c)
            return nullptr;
        return done(n);
    }

    struct BinOp {
        std::string_view text;
        Op op;
        int prec;
        K kind;
    };
    static const BinOp* bin_op(const Token& t, bool no_in) {
        static constexpr BinOp k[] = {{"??", Op::nullish, 1, K::logical},
                                      {"||", Op::or_, 2, K::logical},
                                      {"&&", Op::and_, 3, K::logical},
                                      {"|", Op::bor, 4, K::binary},
                                      {"^", Op::bxor, 5, K::binary},
                                      {"&", Op::band, 6, K::binary},
                                      {"==", Op::eq, 7, K::binary},
                                      {"!=", Op::ne, 7, K::binary},
                                      {"===", Op::seq, 7, K::binary},
                                      {"!==", Op::sne, 7, K::binary},
                                      {"<", Op::lt, 8, K::binary},
                                      {">", Op::gt, 8, K::binary},
                                      {"<=", Op::le, 8, K::binary},
                                      {">=", Op::ge, 8, K::binary},
                                      {"instanceof", Op::instanceof, 8, K::binary},
                                      {"in", Op::in, 8, K::binary},
                                      {"<<", Op::shl, 9, K::binary},
                                      {">>", Op::shr, 9, K::binary},
                                      {">>>", Op::ushr, 9, K::binary},
                                      {"+", Op::add, 10, K::binary},
                                      {"-", Op::sub, 10, K::binary},
                                      {"*", Op::mul, 11, K::binary},
                                      {"/", Op::div, 11, K::binary},
                                      {"%", Op::mod, 11, K::binary},
                                      {"**", Op::exp, 12, K::binary}};
        if (t.type != T::punct && !(t.type == T::name && (t.text == "in" || t.text == "instanceof")))
            return nullptr;
        for (const BinOp& b : k)
            if (b.text == t.text)
                return (no_in && b.op == Op::in) ? nullptr : &b;
        return nullptr;
    }

    Node* binary(int min, bool no_in) {
        Depth d(*this);
        if (!d.ok())
            return nullptr;
        uint32_t s = tok.pos;
        bool unary_left = starts_unary();
        Node* left = unary();
        if (!left)
            return nullptr;
        for (;;) {
            const BinOp* b = bin_op(tok, no_in);
            if (!b || b->prec < min)
                return left;
            if (left->kind == K::arrow)
                return fail(tok.pos, false, "an arrow function needs ( ) around it here"), nullptr;
            if (b->op == Op::exp && unary_left && left->kind == K::unary)
                return fail(tok.pos, false, "a unary operand of ** needs ( ) around it"), nullptr;
            uint32_t opos = tok.pos;
            advance();
            Node* right = binary(b->op == Op::exp ? b->prec : b->prec + 1, no_in);
            if (!right)
                return nullptr;
            if (right->kind == K::arrow)
                return fail(right->pos, false, "an arrow function needs ( ) around it here"), nullptr;
            if (b->kind == K::logical) {
                auto mixed = [&](Node* x) {
                    return x->kind == K::logical && ((b->op == Op::nullish) != (x->op == Op::nullish));
                };
                if (mixed(left) || mixed(right))
                    return fail(opos, false, "?? mixed with && or || needs ( ) around one of them"), nullptr;
            }
            Node* n = node(b->kind, s);
            if (!n)
                return nullptr;
            n->op = b->op;
            n->a = left;
            n->b = right;
            left = done(n);
            unary_left = false;
        }
    }
    bool starts_unary() const {
        if (tok.type == T::punct)
            return tok.text == "-" || tok.text == "+" || tok.text == "!" || tok.text == "~";
        return tok.type == T::name && (tok.text == "typeof" || tok.text == "void" || tok.text == "delete");
    }

    Node* unary() {
        Depth d(*this);
        if (!d.ok())
            return nullptr;
        uint32_t s = tok.pos;
        Op op = Op::none;
        if (tok.type == T::punct) {
            if (tok.text == "-")
                op = Op::neg;
            else if (tok.text == "+")
                op = Op::plus;
            else if (tok.text == "!")
                op = Op::not_;
            else if (tok.text == "~")
                op = Op::bnot;
            else if (tok.text == "++" || tok.text == "--") {
                Op u = tok.text == "++" ? Op::inc : Op::dec;
                advance();
                Node* x = unary();
                if (!x)
                    return nullptr;
                if (!simple_target(x))
                    return fail(x->pos, false, "not something ++ or -- can change"), nullptr;
                Node* n = node(K::update, s);
                if (!n)
                    return nullptr;
                n->op = u;
                n->flags = f_prefix;
                n->a = x;
                return done(n);
            }
        } else if (tok.type == T::name) {
            if (tok.text == "typeof")
                op = Op::typeof_;
            else if (tok.text == "void")
                op = Op::void_;
            else if (tok.text == "delete")
                op = Op::delete_;
            else if (tok.text == "await") {
                Token t = peek();
                if (!t.nl
                    && (t.type == T::name || t.type == T::num || t.type == T::str
                        || (t.type == T::punct && (t.text == "(" || t.text == "["))))
                    return subset(s, "await"), nullptr;
            }
        }
        if (op != Op::none) {
            advance();
            Node* x = unary();
            if (!x)
                return nullptr;
            if (x->kind == K::arrow)
                return fail(x->pos, false, "an arrow function needs ( ) around it here"), nullptr;
            Node* n = node(K::unary, s);
            if (!n)
                return nullptr;
            n->op = op;
            n->a = x;
            return done(n);
        }
        Node* x = postfix_ops();
        if (!x)
            return nullptr;
        if (!tok.nl && (is("++") || is("--"))) {
            if (x->kind == K::arrow)
                return fail(tok.pos, false, "an arrow function needs ( ) around it here"), nullptr;
            if (!simple_target(x))
                return fail(x->pos, false, "not something ++ or -- can change"), nullptr;
            Node* n = node(K::update, s);
            if (!n)
                return nullptr;
            n->op = is("++") ? Op::inc : Op::dec;
            n->a = x;
            advance();
            return done(n);
        }
        return x;
    }
    bool simple_target(Node* x) const {
        while (x->kind == K::paren && x->a && !x->a->next)
            x = x->a;
        return (x->kind == K::ident && !reserved(x->text))
            || ((x->kind == K::member || x->kind == K::index || x->kind == K::call)
                && !(x->flags & (f_optional | f_chain)));
    }

    Node* postfix_ops() {
        uint32_t s = tok.pos;
        Node* x;
        if (is_name("new")) {
            x = new_expression();
        } else {
            x = primary();
        }
        if (!x)
            return nullptr;
        bool chain = false;
        for (;;) {
            if (failed)
                return nullptr;
            bool optional = false;
            if (is("?.")) {
                if (x->kind == K::arrow)
                    return fail(tok.pos, false, "an arrow function needs ( ) around it here"), nullptr;
                optional = chain = true;
                advance();
                if (tok.type == T::tmpl)
                    return fail(tok.pos, false, "a template can't follow ?."), nullptr;
                if (!is("(") && !is("[")) {
                    if (tok.type != T::name)
                        return expected("a name after ?."), nullptr;
                    Node* m = node(K::member, s);
                    if (!m)
                        return nullptr;
                    m->a = x;
                    m->text = tok.text;
                    m->flags = f_optional | f_chain;
                    advance();
                    x = done(m);
                    continue;
                }
            }
            if (is(".")) {
                if (x->kind == K::arrow)
                    return fail(tok.pos, false, "an arrow function needs ( ) around it here"), nullptr;
                advance();
                if (tok.type != T::name) {
                    if (is("#"))
                        return subset(tok.pos, "a private name (#x)"), nullptr;
                    return expected("a name after ."), nullptr;
                }
                Node* m = node(K::member, s);
                if (!m)
                    return nullptr;
                m->a = x;
                m->text = tok.text;
                if (chain)
                    m->flags |= f_chain;
                advance();
                x = done(m);
                continue;
            }
            if (is("[")) {
                if (x->kind == K::arrow)
                    return fail(tok.pos, false, "an arrow function needs ( ) around it here"), nullptr;
                advance();
                Node* m = node(K::index, s);
                if (!m)
                    return nullptr;
                m->a = x;
                m->b = expression();
                if (!m->b || !want("]"))
                    return nullptr;
                m->flags = static_cast<uint8_t>((optional ? f_optional : 0) | (chain ? f_chain : 0));
                x = done(m);
                continue;
            }
            if (is("(")) {
                if (x->kind == K::arrow)
                    return fail(tok.pos, false, "an arrow function needs ( ) around it here"), nullptr;
                if (x->kind == K::ident && x->text == "eval")
                    return subset(x->pos, "eval"), nullptr;
                Node* c = node(K::call, s);
                if (!c)
                    return nullptr;
                c->a = x;
                c->b = arguments();
                if (failed)
                    return nullptr;
                c->flags = static_cast<uint8_t>((optional ? f_optional : 0) | (chain ? f_chain : 0));
                x = done(c);
                continue;
            }
            if (tok.type == T::tmpl) {
                if (x->kind == K::arrow)
                    return fail(tok.pos, false, "an arrow function needs ( ) around it here"), nullptr;
                if (chain)
                    return fail(tok.pos, false, "a template can't follow ?."), nullptr;
                Node* t = node(K::tagged, s);
                if (!t)
                    return nullptr;
                t->a = x;
                t->b = template_literal(true);
                if (!t->b)
                    return nullptr;
                x = done(t);
                continue;
            }
            return x;
        }
    }

    Node* new_expression() {
        uint32_t s = tok.pos;
        advance();
        if (is("."))
            return subset(s, "new.target"), nullptr;
        if (is_name("new"))
            return subset(tok.pos, "new of anything but Date, Set or Map"), nullptr;
        uint32_t cs = tok.pos;
        if (tok.type != T::name || (tok.text != "Date" && tok.text != "Set" && tok.text != "Map")) {
            if (tok.type == T::name && (tok.text == "Date" || tok.text == "Set" || tok.text == "Map")) {
            }
            return subset(cs, "new of anything but Date, Set or Map"), nullptr;
        }
        Node* callee = node(K::ident, cs);
        if (!callee)
            return nullptr;
        callee->text = tok.text;
        advance();
        done(callee);
        if (is(".") || is("[") || is("?.") || tok.type == T::tmpl)
            return subset(cs, "new of anything but Date, Set or Map"), nullptr;
        Node* n = node(K::new_, s);
        if (!n)
            return nullptr;
        n->a = callee;
        if (is("(")) {
            n->b = arguments();
            if (failed)
                return nullptr;
        }
        return done(n);
    }

    Node* arguments() {
        if (!want("("))
            return nullptr;
        ListB l;
        while (!failed && !is(")")) {
            if (is("...")) {
                uint32_t s = tok.pos;
                advance();
                Node* sp = node(K::spread, s);
                if (sp)
                    sp->a = assign();
                l.add(done(sp));
            } else {
                l.add(assign());
            }
            if (!is(")") && !want(","))
                return nullptr;
        }
        want(")");
        return l.head;
    }

    Node* template_literal(bool tagged) {
        uint32_t s = tok.pos;
        Node* t = node(K::tmpl, s);
        if (!t)
            return nullptr;
        ListB l;
        for (;;) {
            if (tok.type != T::tmpl)
                return expected("a template"), nullptr;
            if (tok.bad_escape && !tagged)
                return fail(tok.pos, false, "a malformed escape in a template"), nullptr;
            Node* q = node(K::str, tok.pos);
            if (!q)
                return nullptr;
            q->text = tok.text;
            q->end = tok.end;
            l.add(q);
            if (tok.tmpl_tail) {
                advance();
                break;
            }
            advance();
            Node* e = expression();
            if (!e)
                return nullptr;
            l.add(e);
            if (!is("}"))
                return expected("'}' to end ${"), nullptr;
            i = tok.pos + 1;
            tok.pos = i;
            if (!template_piece())
                return nullptr;
            tok.end = i;
        }
        t->a = l.head;
        return done(t);
    }

    Node* property_key(uint8_t& flags) {
        uint32_t s = tok.pos;
        if (is("[")) {
            advance();
            flags |= f_computed;
            Node* k = assign();
            if (!k || !want("]"))
                return nullptr;
            return k;
        }
        Node* k;
        if (tok.type == T::name) {
            k = node(K::ident, s);
            if (k)
                k->text = tok.text;
        } else if (tok.type == T::str) {
            k = node(K::str, s);
            if (k)
                k->text = tok.text;
        } else if (tok.type == T::num) {
            k = node(K::num, s);
            if (k)
                k->num = tok.num;
        } else {
            expected("a property name");
            return nullptr;
        }
        advance();
        return done(k);
    }

    Node* primary() {
        Depth d(*this);
        if (!d.ok())
            return nullptr;
        if (failed)
            return nullptr;
        uint32_t s = tok.pos;
        switch (tok.type) {
        case T::num: {
            Node* n = node(K::num, s);
            if (!n)
                return nullptr;
            n->num = tok.num;
            advance();
            return done(n);
        }
        case T::str: {
            Node* n = node(K::str, s);
            if (!n)
                return nullptr;
            n->text = tok.text;
            advance();
            return done(n);
        }
        case T::tmpl:
            return template_literal(false);
        case T::name: {
            std::string_view w = tok.text;
            if (w == "function")
                return function(true);
            if (w == "this")
                return subset(s, "this"), nullptr;
            if (w == "class")
                return subset(s, "class"), nullptr;
            if (w == "super")
                return subset(s, "super"), nullptr;
            if (w == "import")
                return subset(s, "import"), nullptr;
            if (w == "null" || w == "true" || w == "false") {
                Node* n = node(w == "null" ? K::null_ : w == "true" ? K::true_ : K::false_, s);
                advance();
                return done(n);
            }
            if (reserved(w))
                return expected("a value"), nullptr;
            Node* n = node(K::ident, s);
            if (!n)
                return nullptr;
            n->text = w;
            advance();
            return done(n);
        }
        case T::punct:
            if (is("("))
                return parenthesized();
            if (is("["))
                return array_literal();
            if (is("{"))
                return object_literal();
            if (is("/") || is("/=")) {
                if (!regex())
                    return nullptr;
                Node* n = node(K::regex, s);
                if (!n)
                    return nullptr;
                n->text = tok.text;
                n->flags_text = tok.flags;
                advance();
                return done(n);
            }
            return expected("a value"), nullptr;
        default:
            return expected("a value"), nullptr;
        }
    }

    Node* parenthesized() {
        uint32_t s = tok.pos;
        advance();
        Node* p = node(K::paren, s);
        if (!p)
            return nullptr;
        ListB l;
        bool rest = false, trailing = false;
        uint32_t rest_pos = 0;
        while (!failed && !is(")")) {
            trailing = false;
            if (is("...")) {
                rest = true;
                rest_pos = tok.pos;
                advance();
                Node* sp = node(K::spread, rest_pos);
                if (sp)
                    sp->a = binding_target();
                l.add(done(sp));
                break;
            }
            bool was = cover_init;
            cover_init = false;
            cover_ok = true;
            Node* e = assign();
            if (!e)
                return nullptr;
            cover_init = cover_init || was;
            l.add(e);
            if (!is(","))
                break;
            advance();
            trailing = true;
        }
        if (!want(")"))
            return nullptr;
        p->a = l.head;
        done(p);
        if (is("=>")) {
            p->flags |= f_expr_body;
            return p;
        }
        if (!l.head)
            return fail(tok.pos, false, "expected => after ( )"), nullptr;
        if (rest)
            return fail(rest_pos, false, "... in brackets is only for an arrow function's parameters"), nullptr;
        if (trailing)
            return fail(p->end - 1, false, "a , before ) is only for an arrow function's parameters"), nullptr;
        if (cover_init)
            return fail(cover_pos, false, "{ a = 1 } is only a pattern"), nullptr;
        if (l.head->next) {
            Node* q = node(K::seq, l.head->pos);
            if (!q)
                return nullptr;
            q->a = l.head;
            q->end = l.tail->end;
            p->a = q;
        }
        return p;
    }

    Node* array_literal() {
        uint32_t s = tok.pos;
        advance();
        Node* a = node(K::array, s);
        if (!a)
            return nullptr;
        ListB l;
        bool cover = false;
        while (!failed && !is("]")) {
            if (is(",")) {
                l.add(node(K::hole, tok.pos));
                advance();
                continue;
            }
            Node* e;
            if (is("...")) {
                uint32_t ss = tok.pos;
                advance();
                e = node(K::spread, ss);
                if (e)
                    e->a = assign();
                done(e);
            } else {
                bool was = cover_init;
                cover_init = false;
                cover_ok = true;
                e = assign();
                cover = cover || cover_init;
                cover_init = was;
            }
            if (!e)
                return nullptr;
            l.add(e);
            if (!is("]")) {
                if (!want(","))
                    return nullptr;
                if (is("]") && e->kind == K::spread)
                    a->flags |= f_shorthand;
            }
        }
        if (!want("]"))
            return nullptr;
        if (cover)
            cover_init = true;
        a->a = l.head;
        return done(a);
    }

    Node* object_literal() {
        uint32_t s = tok.pos;
        advance();
        Node* o = node(K::object, s);
        if (!o)
            return nullptr;
        ListB l;
        while (!failed && !is("}")) {
            uint32_t ps = tok.pos;
            if (is("...")) {
                advance();
                Node* sp = node(K::spread, ps);
                if (sp)
                    sp->a = assign();
                l.add(done(sp));
            } else {
                if (is("*"))
                    return subset(ps, "a generator"), nullptr;
                if (tok.type == T::name && (tok.text == "get" || tok.text == "set" || tok.text == "async")) {
                    Token t = peek();
                    bool key_follows = (t.type == T::name || t.type == T::str || t.type == T::num
                                        || (t.type == T::punct && (t.text == "[" || t.text == "*")));
                    if (key_follows && !(tok.text == "async" && t.nl))
                        return subset(ps, tok.text == "async" ? "async" : "a getter or setter"), nullptr;
                }
                Node* p = node(K::prop, ps);
                if (!p)
                    return nullptr;
                bool name_key = tok.type == T::name;
                std::string_view key_text = tok.text;
                p->a = property_key(p->flags);
                if (!p->a)
                    return nullptr;
                if (is(":")) {
                    advance();
                    bool was = cover_init;
                    cover_init = false;
                    cover_ok = true;
                    p->b = assign();
                    cover_init = cover_init || was;
                } else if (is("(")) {
                    p->flags |= f_method;
                    p->b = function_rest(ps, {});
                } else {
                    if (!name_key || (p->flags & f_computed))
                        return expected("':'"), nullptr;
                    if (reserved(key_text))
                        return expected("':'"), nullptr;
                    p->flags |= f_shorthand;
                    Node* v = node(K::ident, ps);
                    if (!v)
                        return nullptr;
                    v->text = key_text;
                    v->end = p->a->end;
                    p->b = v;
                    if (is("=")) {
                        if (!cover_init)
                            cover_pos = tok.pos;
                        advance();
                        Node* dn = node(K::default_, ps);
                        if (!dn)
                            return nullptr;
                        dn->a = v;
                        dn->b = assign();
                        p->b = done(dn);
                        cover_init = true;
                    }
                }
                if (!p->b)
                    return nullptr;
                l.add(done(p));
            }
            if (!is("}") && !want(","))
                return nullptr;
        }
        if (!want("}"))
            return nullptr;
        o->a = l.head;
        return done(o);
    }

    Node* function(bool expression_) {
        uint32_t s = tok.pos;
        advance();
        if (is("*"))
            return subset(s, "a generator"), nullptr;
        std::string_view name;
        if (tok.type == T::name && !reserved(tok.text)) {
            name = tok.text;
            advance();
        } else if (!expression_) {
            return expected("a function's name"), nullptr;
        }
        Node* f = function_rest(s, name);
        if (f && !expression_)
            f->kind = K::func_decl;
        return f;
    }
    Node* function_rest(uint32_t s, std::string_view name) {
        Node* f = node(K::func, s);
        if (!f)
            return nullptr;
        f->text = name;
        if (!want("("))
            return nullptr;
        if (!open_scope(false))
            return nullptr;
        f->a = parameters(")");
        if (failed || !want(")"))
            return nullptr;
        int was = loops, was_switches = switches;
        loops = 0, switches = 0;
        f->b = function_body();
        loops = was, switches = was_switches;
        close_scope();
        if (!f->b)
            return nullptr;
        return done(f);
    }
    Node* parameters(const char* close) {
        ListB l;
        bool simple = true;
        auto end = [&] { return close ? is(close) : tok.type == T::eof; };
        while (!failed && !end()) {
            if (is("...")) {
                uint32_t rs = tok.pos;
                advance();
                Node* r = node(K::rest, rs);
                if (r)
                    r->a = binding_target();
                l.add(done(r));
                simple = false;
                if (!end())
                    return expected("the end of the parameters after a rest parameter"), nullptr;
                break;
            }
            Node* p = binding_element();
            if (!p)
                return nullptr;
            if (p->kind != K::ident)
                simple = false;
            l.add(p);
            if (!end() && !want(","))
                return nullptr;
        }
        for (Node* p = l.head; p; p = p->next) {
            if (!simple)
                for (Node* q = l.head; q != p; q = q->next)
                    if (!check_distinct(p, q))
                        return nullptr;
            if (!declare_pattern(p, k_param))
                return nullptr;
        }
        return l.head;
    }
    Node* function_body() {
        uint32_t s = tok.pos;
        if (!want("{"))
            return nullptr;
        Node* b = node(K::block_body, s);
        if (!b)
            return nullptr;
        if (!open_scope(true))
            return nullptr;
        b->a = statements("}");
        close_scope();
        if (failed || !want("}"))
            return nullptr;
        return done(b);
    }

    Node* statements(const char* close) {
        ListB l;
        while (!failed) {
            if (close ? is(close) || tok.type == T::eof : tok.type == T::eof)
                break;
            l.add(statement());
        }
        return l.head;
    }

    Node* statement() {
        Depth d(*this);
        if (!d.ok())
            return nullptr;
        uint32_t s = tok.pos;
        if (tok.type == T::punct) {
            if (is("{"))
                return block();
            if (is(";")) {
                Node* n = node(K::empty, s);
                advance();
                return done(n);
            }
        }
        if (tok.type == T::name) {
            std::string_view w = tok.text;
            if (w == "var" || w == "const")
                return declaration();
            if (w == "let") {
                Token t = peek();
                if ((t.type == T::name && !reserved(t.text))
                    || (t.type == T::punct && (t.text == "[" || t.text == "{")))
                    return declaration();
            }
            if (w == "if")
                return if_statement();
            if (w == "for")
                return for_statement();
            if (w == "while")
                return while_statement();
            if (w == "do")
                return do_statement();
            if (w == "return")
                return jump(K::return_);
            if (w == "break")
                return jump(K::break_);
            if (w == "continue")
                return jump(K::continue_);
            if (w == "try")
                return try_statement();
            if (w == "function") {
                Node* f = function(false);
                if (f && !declare(f->text, scope->function ? k_func : k_func, f->pos))
                    return nullptr;
                return f;
            }
            if (w == "switch")
                return switch_statement();
            if (w == "throw")
                return subset(s, "throw"), nullptr;
            if (w == "with")
                return subset(s, "with"), nullptr;
            if (w == "class")
                return subset(s, "class"), nullptr;
            if (w == "debugger")
                return subset(s, "debugger"), nullptr;
            if (w == "import" || w == "export")
                return subset(s, "import and export"), nullptr;
            if (w == "async") {
                Token t = peek();
                if (!t.nl && t.type == T::name && t.text == "function")
                    return subset(s, "async"), nullptr;
            }
            if (!reserved(w)) {
                Token t = peek();
                if (t.type == T::punct && t.text == ":")
                    return subset(s, "a label"), nullptr;
            }
        }
        Node* n = node(K::expr_stmt, s);
        if (!n)
            return nullptr;
        n->a = expression();
        if (!n->a || !semicolon())
            return nullptr;
        return done(n);
    }

    Node* block() {
        uint32_t s = tok.pos;
        advance();
        Node* b = node(K::block, s);
        if (!b)
            return nullptr;
        if (!open_scope(false))
            return nullptr;
        b->a = statements("}");
        close_scope();
        if (failed || !want("}"))
            return nullptr;
        return done(b);
    }

    Node* declaration(bool in_for = false) {
        uint32_t s = tok.pos;
        Op kind = tok.text == "var" ? Op::var_ : tok.text == "let" ? Op::let_ : Op::const_;
        advance();
        Node* v = node(K::var, s);
        if (!v)
            return nullptr;
        v->op = kind;
        ListB l;
        for (;;) {
            uint32_t ds = tok.pos;
            Node* t = binding_target();
            if (!t)
                return nullptr;
            if (!declare_pattern(t, kind == Op::var_ ? k_var : k_lex))
                return nullptr;
            Node* dn = node(K::declarator, ds);
            if (!dn)
                return nullptr;
            dn->a = t;
            if (eat("=")) {
                dn->b = assign(in_for);
                if (!dn->b)
                    return nullptr;
            } else if (!(in_for && (is_name("in") || is_name("of")) && !l.head)) {
                if (kind == Op::const_)
                    return fail(tok.pos, false, "a const needs a value"), nullptr;
                if (t->kind != K::ident)
                    return fail(tok.pos, false, "a [ ] or { } declaration needs a value"), nullptr;
            }
            l.add(done(dn));
            if (!eat(","))
                break;
        }
        v->a = l.head;
        done(v);
        if (!in_for && !semicolon())
            return nullptr;
        return v;
    }

    Node* if_statement() {
        uint32_t s = tok.pos;
        advance();
        Node* n = node(K::if_, s);
        if (!n || !want("("))
            return nullptr;
        n->a = expression();
        if (!n->a || !want(")"))
            return nullptr;
        n->b = sub_statement();
        if (!n->b)
            return nullptr;
        if (is_name("else")) {
            advance();
            n->c = sub_statement();
            if (!n->c)
                return nullptr;
        }
        return done(n);
    }
    Node* sub_statement() {
        if (tok.type == T::name && (tok.text == "const" || tok.text == "class"))
            return fail(tok.pos, false, "a %.*s here needs { } around it", static_cast<int>(tok.text.size()),
                        tok.text.data()),
                   nullptr;
        if (is_name("let")) {
            Token t = peek();
            if ((t.type == T::punct && t.text == "[")
                || (!t.nl
                    && ((t.type == T::name && t.text != "in" && t.text != "instanceof")
                        || (t.type == T::punct && t.text == "{"))))
                return fail(tok.pos, false, "a let here needs { } around it"), nullptr;
            Node* n = node(K::expr_stmt, tok.pos);
            if (!n)
                return nullptr;
            n->a = expression();
            if (!n->a || !semicolon())
                return nullptr;
            return done(n);
        }
        if (is_name("function"))
            return fail(tok.pos, false, "a function here needs { } around it"), nullptr;
        return statement();
    }
    Node* loop_body() {
        loops++;
        Node* b = sub_statement();
        loops--;
        return b;
    }

    Node* for_statement() {
        uint32_t s = tok.pos;
        advance();
        if (is_name("await"))
            return subset(tok.pos, "for await"), nullptr;
        if (!want("("))
            return nullptr;
        if (!open_scope(false))
            return nullptr;
        Node* init = nullptr;
        bool decl = false;
        if (is(";")) {
        } else if (is_name("var") || is_name("const") || (is_name("let") && [&] {
                       Token t = peek();
                       return !(t.type == T::name && (t.text == "in" || t.text == "of"))
                           && !(t.type == T::punct && t.text == ";");
                   }())) {
            init = declaration(true);
            decl = true;
        } else {
            cover_init = false;
            init = expression(true);
        }
        if (failed)
            return nullptr;
        if (is_name("of") || is_name("in")) {
            bool of = tok.text == "of";
            Node* left = init;
            if (decl) {
                if (left->a->next)
                    return fail(left->a->next->pos, false, "a for…%s declares one name", of ? "of" : "in"), nullptr;
                if (left->a->b && (of || left->op != Op::var_ || left->a->a->kind != K::ident))
                    return fail(left->a->b->pos, false, "a for…%s's name takes no value", of ? "of" : "in"), nullptr;
            } else {
                if (of && left->kind == K::ident && left->text == "async")
                    return fail(left->pos, false, "for (async of"), nullptr;
                if (left->kind == K::array || left->kind == K::object)
                    left = to_pattern(left, false);
                else if (!simple_target(left))
                    return fail(left->pos, false, "not something a value can be assigned to"), nullptr;
                if (!left)
                    return nullptr;
                cover_init = false;
            }
            advance();
            Node* n = node(of ? K::for_of : K::for_in, s);
            if (!n)
                return nullptr;
            n->a = left;
            n->b = of ? assign() : expression();
            if (!n->b || !want(")"))
                return nullptr;
            n->d = loop_body();
            close_scope();
            if (!n->d)
                return nullptr;
            return done(n);
        }
        if (cover_init)
            return fail(cover_pos, false, "{ a = 1 } is only a pattern"), nullptr;
        if (decl && init->op == Op::const_)
            for (Node* x = init->a; x; x = x->next)
                if (!x->b)
                    return fail(x->pos, false, "a const needs a value"), nullptr;
        if (decl)
            for (Node* x = init->a; x; x = x->next)
                if (!x->b && x->a->kind != K::ident)
                    return fail(x->pos, false, "a [ ] or { } declaration needs a value"), nullptr;
        Node* n = node(K::for_, s);
        if (!n || !want(";"))
            return nullptr;
        n->a = init;
        if (!is(";"))
            n->b = expression();
        if (failed || !want(";"))
            return nullptr;
        if (!is(")"))
            n->c = expression();
        if (failed || !want(")"))
            return nullptr;
        n->d = loop_body();
        close_scope();
        if (!n->d)
            return nullptr;
        return done(n);
    }

    Node* while_statement() {
        uint32_t s = tok.pos;
        advance();
        Node* n = node(K::while_, s);
        if (!n || !want("("))
            return nullptr;
        n->a = expression();
        if (!n->a || !want(")"))
            return nullptr;
        n->d = loop_body();
        if (!n->d)
            return nullptr;
        return done(n);
    }
    Node* do_statement() {
        uint32_t s = tok.pos;
        advance();
        Node* n = node(K::do_while, s);
        if (!n)
            return nullptr;
        n->d = loop_body();
        if (!n->d)
            return nullptr;
        if (!is_name("while"))
            return expected("while"), nullptr;
        advance();
        if (!want("("))
            return nullptr;
        n->a = expression();
        if (!n->a || !want(")"))
            return nullptr;
        eat(";");
        return done(n);
    }
    Node* switch_statement() {
        uint32_t s = tok.pos;
        advance();
        Node* n = node(K::switch_, s);
        if (!n || !want("("))
            return nullptr;
        n->a = expression();
        if (!n->a || !want(")"))
            return nullptr;
        if (!is("{"))
            return expected("'{'"), nullptr;
        uint32_t bs = tok.pos;
        advance();
        Node* b = node(K::block, bs);
        if (!b || !open_scope(false))
            return nullptr;
        switches++;
        ListB l;
        bool has_default = false;
        while (!is("}") && !failed) {
            if (tok.type == T::eof)
                return expected("'}'"), nullptr;
            Node* one;
            if (is_name("case") || is_name("default")) {
                const bool def = is_name("default");
                uint32_t cs = tok.pos;
                if (def && has_default)
                    return fail(cs, false, "a switch has one default"), nullptr;
                has_default = has_default || def;
                advance();
                one = node(K::case_, cs);
                if (!one)
                    return nullptr;
                if (!def) {
                    one->a = expression();
                    if (!one->a)
                        return nullptr;
                }
                if (!want(":"))
                    return nullptr;
                one = done(one);
            } else {
                if (l.head == nullptr)
                    return expected("case"), nullptr;
                one = statement();
            }
            if (!one)
                return nullptr;
            l.add(one);
        }
        switches--;
        b->a = l.head;
        close_scope();
        if (failed || !want("}"))
            return nullptr;
        n->b = done(b);
        return done(n);
    }
    Node* jump(K k) {
        uint32_t s = tok.pos;
        advance();
        Node* n = node(k, s);
        if (!n)
            return nullptr;
        if (k == K::return_) {
            if (!is(";") && !is("}") && tok.type != T::eof && !tok.nl) {
                n->a = expression();
                if (!n->a)
                    return nullptr;
            }
        } else {
            if (tok.type == T::name && !tok.nl && !reserved(tok.text))
                return subset(tok.pos, "a label"), nullptr;
            if (!loops && !(k == K::break_ && switches))
                return fail(s, false, "%s outside a loop", k == K::break_ ? "break" : "continue"), nullptr;
        }
        if (!semicolon())
            return nullptr;
        return done(n);
    }
    Node* try_statement() {
        uint32_t s = tok.pos;
        advance();
        Node* n = node(K::try_, s);
        if (!n)
            return nullptr;
        if (!is("{"))
            return expected("'{'"), nullptr;
        n->a = block();
        if (!n->a)
            return nullptr;
        if (is_name("catch")) {
            advance();
            if (!open_scope(false))
                return nullptr;
            if (eat("(")) {
                n->b = binding_target();
                if (!n->b || !declare_pattern(n->b, k_catch) || !want(")"))
                    return nullptr;
            }
            if (!is("{"))
                return expected("'{'"), nullptr;
            uint32_t bs = tok.pos;
            advance();
            Node* b = node(K::block, bs);
            if (!b)
                return nullptr;
            b->a = statements("}");
            if (failed || !want("}"))
                return nullptr;
            n->c = done(b);
            close_scope();
        }
        if (is_name("finally")) {
            advance();
            if (!is("{"))
                return expected("'{'"), nullptr;
            n->d = block();
            if (!n->d)
                return nullptr;
        }
        if (!n->c && !n->d)
            return expected("catch or finally"), nullptr;
        return done(n);
    }
};

}

std::expected<Node*, Error> parse(std::string_view file, uint32_t pos, uint32_t len, Goal goal, Arena& arena) noexcept {
    Parser p{file, pos, pos + len, arena};
    p.i = pos;
    p.prev_end = pos;
    if (!p.next())
        return std::unexpected(p.error);
    Node* out = nullptr;
    if (!p.open_scope(false))
        return std::unexpected(p.error);
    switch (goal) {
    case Goal::params:
        out = p.node(K::block_body, pos);
        if (out)
            out->a = p.parameters(nullptr);
        if (!p.failed && p.tok.type != T::eof)
            p.expected("the end of the parameters");
        break;
    case Goal::value:
        if (p.is("{"))
            goto body;
        p.value_text = true;
        if (p.tok.type == T::eof && p.limit > p.begin) {
            p.i = p.begin;
            p.next();
        }
        out = p.expression();
        if (!p.failed && p.tok.type != T::eof)
            p.expected("the end of the value");
        break;
    case Goal::handler:
        if (!p.is("{")) {
            p.final_semi = true;
            if (p.tok.type == T::eof)
                p.next();
        }
        [[fallthrough]];
    case Goal::body:
    body:
        if (!p.open_scope(true))
            break;
        out = p.node(K::block_body, pos);
        if (out)
            out->a = p.statements(nullptr);
        if (out)
            out->end = pos + len;
        break;
    }
    if (p.failed)
        return std::unexpected(p.error);
    if (!out)
        return std::unexpected(Error{pos, "out of memory", false});
    return out;
}

std::expected<Node*, Error> parse_function(std::string_view file, uint32_t params_pos, uint32_t params_len,
                                           uint32_t body_pos, uint32_t body_len, Arena& arena) noexcept {
    Parser p{file, params_pos, params_pos + params_len, arena};
    p.i = params_pos;
    p.prev_end = params_pos;
    p.params_text = true;
    Node* f = p.node(K::func, params_pos);
    if (!f || !p.next() || !p.open_scope(false))
        return std::unexpected(p.error);
    f->a = p.parameters(nullptr);
    if (p.failed)
        return std::unexpected(p.error);
    p.params_text = false;
    p.begin = body_pos;
    p.limit = body_pos + body_len;
    p.i = body_pos;
    if (!p.next() || !p.open_scope(true))
        return std::unexpected(p.error);
    Node* b = p.node(K::block_body, body_pos);
    if (b)
        b->a = p.statements(nullptr), b->end = body_pos + body_len;
    if (p.failed)
        return std::unexpected(p.error);
    if (!b)
        return std::unexpected(Error{body_pos, "out of memory", false});
    f->b = b;
    f->end = body_pos + body_len;
    return f;
}

const char* op_name(Op op) noexcept {
    static constexpr const char* k[] = {
        "",    "+",   "-",      "*",    "/",      "%",  "**",  "==",  "!=",         "===", "!==", "<",    ">",  "<=",
        ">=",  "<<",  ">>",     ">>>",  "&",      "|",  "^",   "in",  "instanceof", "&&",  "||",  "??",   "-",  "+",
        "!",   "~",   "typeof", "void", "delete", "++", "--",  "=",   "+=",         "-=",  "*=",  "/=",   "%=", "**=",
        "<<=", ">>=", ">>>=",   "&=",   "|=",     "^=", "&&=", "||=", "?\?=",       "var", "let", "const"};
    size_t k_n = sizeof k / sizeof *k;
    return static_cast<size_t>(op) < k_n ? k[static_cast<size_t>(op)] : "?";
}

const char* kind_name(K k) noexcept {
    static constexpr const char* n[] = {
        "num",    "str",       "tmpl",       "tagged",   "regex",     "ident",     "null",       "true",  "false",
        "array",  "hole",      "object",     "prop",     "spread",    "arrow",     "func",       "unary", "update",
        "binary", "logical",   "assign",     "cond",     "call",      "new",       "member",     "index", "seq",
        "paren",  "array_pat", "object_pat", "rest",     "default",   "var",       "declarator", "if",    "for",
        "for_in", "for_of",    "while",      "do_while", "switch",    "case",      "return",     "break", "continue",
        "try",    "block",     "expr_stmt",  "empty",    "func_decl", "block_body"};
    size_t k_n = sizeof n / sizeof *n;
    return static_cast<size_t>(k) < k_n ? n[static_cast<size_t>(k)] : "?";
}

}
