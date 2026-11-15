// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/syntax/rui.h"

#include <cstdarg>
#include <cstdio>

#include "engine/base/utf.h"

namespace rx::engine::rui {
namespace {

bool name_start(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '$';
}
bool name_part(char c) {
    return name_start(c) || (c >= '0' && c <= '9');
}
bool upper(char c) {
    return c >= 'A' && c <= 'Z';
}
bool in(char c, const char* set) {
    return c && __builtin_strchr(set, c);
}

struct Parser {
    std::string_view src;
    Arena& arena;
    size_t i = 0, n = 0;
    uint32_t line = 1, depth = 0;
    bool failed = false;
    Error error{};

    char at(size_t k) const { return k < n ? src[k] : '\0'; }
    void adv() {
        if (at(i++) == '\n')
            line++;
    }
    uint32_t pos32(size_t p) const { return static_cast<uint32_t>(p); }

    bool err(size_t pos, const char* fmt, ...) __attribute__((format(printf, 3, 4))) {
        char buf[512];
        va_list ap;
        va_start(ap, fmt);
        int len = std::vsnprintf(buf, sizeof buf, fmt, ap);
        va_end(ap);
        size_t m = len < 0 ? 0 : static_cast<size_t>(len) < sizeof buf ? static_cast<size_t>(len) : sizeof buf - 1;
        failed = true;
        error = {line, pos32(pos), arena.copy({buf, m})};
        return false;
    }
    static int clip(std::string_view s) { return static_cast<int>(s.size() < 200 ? s.size() : 200); }

    bool skip_comment() {
        if (at(i) != '/')
            return false;
        if (at(i + 1) == '/') {
            while (i < n && src[i] != '\n')
                i++;
            return true;
        }
        if (at(i + 1) == '*') {
            i += 2;
            while (i < n && !(src[i] == '*' && at(i + 1) == '/'))
                adv();
            if (i >= n)
                return err(i, "unterminated /* comment"), true;
            i += 2;
            return true;
        }
        return false;
    }
    bool space() {
        while (i < n) {
            char c = src[i];
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
                adv();
            else if (!skip_comment())
                return true;
            else if (failed)
                return false;
        }
        return true;
    }
    bool name(std::string_view& out) {
        if (!name_start(at(i))) {
            if (i >= n)
                return err(i, "expected a name, found the end of the file");
            utf::Cp c = utf::decode(src, i);
            char q[16];
            if (c.len == 1) {
                std::string_view one = src.substr(i, 1);
                struct B {
                    char* p;
                    size_t k;
                    void append(const char* s, size_t m) {
                        for (size_t x = 0; x < m && k < 15; x++)
                            p[k++] = s[x];
                    }
                } b{q, 0};
                json_string(one, b);
                q[b.k] = 0;
            } else if (c.cp >= 0x10000) {
                std::snprintf(q, sizeof q, "\"\\u%04x\"", static_cast<unsigned>(0xD800 + ((c.cp - 0x10000) >> 10)));
            } else {
                std::snprintf(q, sizeof q, "\"%.*s\"", static_cast<int>(c.len), src.data() + i);
            }
            return err(i, "expected a name, found %s", q);
        }
        size_t s = i;
        while (name_part(at(i)))
            i++;
        out = src.substr(s, i - s);
        return true;
    }
    bool string(char q) {
        uint32_t start_line = line;
        size_t start = i;
        adv();
        while (i < n) {
            char c = src[i];
            if (c == '\\') {
                adv();
                adv();
                continue;
            }
            if (c == q) {
                adv();
                return true;
            }
            if (c == '\n' && q != '`')
                return err(i, "unterminated string");
            if (q == '`' && c == '$' && at(i + 1) == '{') {
                adv();
                std::string_view ignored;
                if (!balanced('{', '}', ignored))
                    return false;
                continue;
            }
            adv();
        }
        line = start_line;
        return err(start, "unterminated string");
    }
    bool regex_can_start(size_t from) const {
        size_t b = i;
        while (b > from && (src[b - 1] == ' ' || src[b - 1] == '\t' || src[b - 1] == '\r' || src[b - 1] == '\n'))
            b--;
        if (b == from)
            return true;
        char p = src[b - 1];
        if ((p == '+' || p == '-') && b - from >= 2 && src[b - 2] == p)
            return false;
        if (in(p, "(,=:[!&|?{;+-*%<>~^"))
            return true;
        if (!name_part(p))
            return false;
        size_t w = b;
        while (w > from && name_part(src[w - 1]))
            w--;
        std::string_view word = src.substr(w, b - w);
        for (std::string_view k : {"return", "typeof", "case", "in", "of", "void", "delete", "new", "else", "do"})
            if (word == k)
                return true;
        return false;
    }
    bool skip_regex(size_t from) {
        if (at(i) != '/' || !regex_can_start(from))
            return false;
        size_t j = i + 1;
        bool cls = false;
        for (; j < n && src[j] != '\n'; j++) {
            char c = src[j];
            if (c == '\\') {
                j++;
                if (at(j) == '\n')
                    return false;
                continue;
            }
            if (c == '[')
                cls = true;
            else if (c == ']')
                cls = false;
            else if (c == '/' && !cls) {
                i = j + 1;
                return true;
            }
        }
        return false;
    }
    bool balanced(char open, char close, std::string_view& out) {
        size_t start = i;
        int d = 0;
        while (i < n) {
            char c = src[i];
            if (c == '"' || c == '\'' || c == '`') {
                if (!string(c))
                    return false;
                continue;
            }
            if (skip_comment()) {
                if (failed)
                    return false;
                continue;
            }
            if (skip_regex(start + 1))
                continue;
            if (c == open)
                d++;
            else if (c == close && --d == 0) {
                adv();
                out = src.substr(start, i - start);
                return true;
            }
            adv();
        }
        return err(i, "missing %c", close);
    }
    bool continues(size_t start) const {
        std::string_view before = utf::trim_end(src.substr(start, i - start));
        bool step = before.ends_with("++") || before.ends_with("--");
        if (!step && !before.empty() && in(before.back(), "+-*/%&|^!~?:=<>,."))
            return true;
        size_t j = i + 1;
        while (j < n) {
            utf::Cp c = utf::decode(src, j);
            if (!c.len || !utf::js_space(c.cp))
                break;
            j += c.len;
        }
        if (at(j) == '/' && (at(j + 1) == '/' || at(j + 1) == '*'))
            return false;
        return j < n && in(src[j], "?:.+-*/&|=<>");
    }
    bool expression(std::string_view& out, uint32_t& out_pos) {
        if (!space())
            return false;
        size_t start = i;
        int d = 0;
        while (i < n) {
            char c = src[i];
            if (c == '"' || c == '\'' || c == '`') {
                if (!string(c))
                    return false;
                continue;
            }
            if (c == '/' && (at(i + 1) == '/' || at(i + 1) == '*')) {
                if (d == 0 && at(i + 1) == '/')
                    break;
                skip_comment();
                if (failed)
                    return false;
                continue;
            }
            if (skip_regex(start))
                continue;
            if (c == '(' || c == '[' || c == '{')
                d++;
            else if (c == ')' || c == ']' || c == '}') {
                if (d == 0)
                    break;
                d--;
            } else if (d == 0 && c == ';')
                break;
            else if (d == 0 && c == '\n' && !continues(start))
                break;
            adv();
        }
        std::string_view raw = src.substr(start, i - start);
        std::string_view text = utf::trim(raw);
        if (text.empty())
            return err(i, "expected a value");
        out = text;
        out_pos = pos32(static_cast<size_t>(text.data() - src.data()));
        return true;
    }
    bool delegate_ahead() const {
        size_t j = i;
        for (;;) {
            if (!upper(at(j)))
                return false;
            j++;
            while (name_part(at(j)))
                j++;
            if (at(j) == '.' && upper(at(j + 1))) {
                j++;
                continue;
            }
            break;
        }
        while (j < n) {
            utf::Cp c = utf::decode(src, j);
            if (!c.len || !utf::js_space(c.cp))
                break;
            j += c.len;
        }
        return at(j) == '{';
    }
    static bool type_like(std::string_view k) {
        size_t j = 0;
        for (;;) {
            if (j >= k.size() || !upper(k[j]))
                return false;
            j++;
            while (j < k.size() && name_part(k[j]))
                j++;
            if (j == k.size())
                return true;
            if (k[j] != '.')
                return false;
            j++;
        }
    }
    static bool handler_name(std::string_view k) {
        for (size_t j = 0; j + 2 < k.size(); j++)
            if ((j == 0 || k[j - 1] == '.') && k[j] == 'o' && k[j + 1] == 'n' && upper(k[j + 2]))
                return true;
        return false;
    }
    bool type_name(std::string_view& out) {
        size_t s = i;
        std::string_view part;
        if (!name(part))
            return false;
        while (at(i) == '.' && upper(at(i + 1))) {
            adv();
            if (!name(part))
                return false;
        }
        out = src.substr(s, i - s);
        return true;
    }
    bool push_failed() { return err(i, "out of memory"); }
    bool signal_params(std::string_view list, std::string_view& out) {
        char* buf = static_cast<char*>(arena.alloc(list.size() + 2, 1));
        if (!buf)
            return push_failed();
        size_t k = 0;
        for (size_t at_ = 0; at_ <= list.size();) {
            size_t e = list.find(',', at_);
            std::string_view part =
                utf::trim(list.substr(at_, e == std::string_view::npos ? std::string_view::npos : e - at_));
            size_t w = part.size();
            while (w > 0 && name_part(part[w - 1]))
                w--;
            std::string_view word = part.substr(w);
            if (!word.empty()) {
                if (k)
                    buf[k++] = ',';
                __builtin_memcpy(buf + k, word.data(), word.size());
                k += word.size();
            }
            if (e == std::string_view::npos)
                break;
            at_ = e + 1;
        }
        out = {buf, k};
        return true;
    }

    bool object(std::string_view type, uint32_t start_line, size_t start_pos, Element*& out) {
        if (!space())
            return false;
        if (at(i) != '{')
            return err(i, "expected { after %.*s", clip(type), type.data());
        if (++depth > k_max_depth)
            return err(start_pos, "elements nested deeper than %u", k_max_depth);
        adv();
        Element* node = arena.make<Element>();
        if (!node)
            return push_failed();
        node->type = type;
        node->line = start_line;
        node->pos = pos32(start_pos);
        for (;;) {
            if (!space())
                return false;
            while (at(i) == ';' || at(i) == ',') {
                adv();
                if (!space())
                    return false;
            }
            if (i >= n) {
                line = start_line;
                return err(start_pos, "%.*s has no closing }", clip(type), type.data());
            }
            if (src[i] == '}') {
                adv();
                depth--;
                out = node;
                return true;
            }
            uint32_t at_line = line;
            size_t kpos = i;
            std::string_view key;
            if (!name(key))
                return false;
            bool readonly = false;
            if (key == "readonly") {
                if (!space() || !name(key))
                    return false;
                readonly = true;
            }
            if (key == "signal") {
                if (!space())
                    return false;
                if (name_start(at(i))) {
                    std::string_view sname, params;
                    if (!name(sname) || !space())
                        return false;
                    Signal sg{sname, {}, at_line, pos32(kpos)};
                    if (at(i) == '(') {
                        if (!balanced('(', ')', params))
                            return false;
                        if (!signal_params(params.substr(1, params.size() - 2), sg.params))
                            return false;
                    }
                    if (!node->signals.push(arena, sg))
                        return push_failed();
                    continue;
                }
            }
            if (key == "property" || key == "function") {
                if (!space())
                    return false;
                if (name_start(at(i))) {
                    if (key == "function") {
                        std::string_view fname, params, body;
                        if (!name(fname) || !space())
                            return false;
                        if (at(i) != '(')
                            return err(i, "expected ( after function %.*s", clip(fname), fname.data());
                        size_t ppos = i;
                        if (!balanced('(', ')', params) || !space())
                            return false;
                        if (at(i) != '{')
                            return err(i, "expected { for the body of %.*s", clip(fname), fname.data());
                        size_t bpos = i;
                        if (!balanced('{', '}', body))
                            return false;
                        Function f{fname,
                                   params.substr(1, params.size() - 2),
                                   body.substr(1, body.size() - 2),
                                   at_line,
                                   pos32(kpos),
                                   pos32(ppos + 1),
                                   pos32(bpos + 1)};
                        if (!node->functions.push(arena, f))
                            return push_failed();
                        continue;
                    }
                    std::string_view pname, ptype;
                    if (!name(pname) || !space())
                        return false;
                    if (name_start(at(i))) {
                        ptype = pname;
                        if (!name(pname))
                            return false;
                    }
                    if (!space())
                        return false;
                    Member m{pname, {}, ptype, at_line, pos32(kpos), 0, false, readonly};
                    if (at(i) == ':') {
                        adv();
                        if (!expression(m.value, m.value_pos))
                            return false;
                        m.has_value = true;
                    }
                    if (!node->custom.push(arena, m))
                        return push_failed();
                    continue;
                }
            }
            size_t kstart = static_cast<size_t>(key.data() - src.data());
            bool joined = kstart + key.size() == i;
            while (at(i) == '.') {
                adv();
                std::string_view part;
                if (!name(part))
                    return false;
                if (joined) {
                    key = src.substr(kstart, i - kstart);
                    continue;
                }
                char* buf = static_cast<char*>(arena.alloc(key.size() + 1 + part.size(), 1));
                if (!buf)
                    return push_failed();
                __builtin_memcpy(buf, key.data(), key.size());
                buf[key.size()] = '.';
                __builtin_memcpy(buf + key.size() + 1, part.data(), part.size());
                key = {buf, key.size() + 1 + part.size()};
            }
            if (!space())
                return false;
            if (at(i) == '{') {
                if (!type_like(key))
                    return err(i, "%.*s is not an element (element names start with a capital)", clip(key), key.data());
                Element* child;
                if (!object(key, at_line, kstart, child))
                    return false;
                if (!node->children.push(arena, child))
                    return push_failed();
                continue;
            }
            if (at(i) != ':')
                return err(i, "expected : after %.*s", clip(key), key.data());
            adv();
            if (key == "id") {
                if (!space())
                    return false;
                node->id_pos = pos32(i);
                if (!name(node->id))
                    return false;
                node->has_id = true;
                continue;
            }
            if (!space())
                return false;
            if (delegate_ahead()) {
                uint32_t tline = line;
                size_t tpos = i;
                std::string_view tname;
                Element* child;
                if (!type_name(tname) || !object(tname, tline, tpos, child))
                    return false;
                if (!node->objects.push(arena, Object{key, child, at_line, pos32(kpos)}))
                    return push_failed();
                continue;
            }
            Member m{key, {}, {}, at_line, pos32(kpos), 0, true, readonly};
            if (!expression(m.value, m.value_pos))
                return false;
            if (!(handler_name(key) ? node->handlers : node->props).push(arena, m))
                return push_failed();
        }
    }

    bool file(File& f) {
        for (;;) {
            if (!space())
                return false;
            if (src.substr(i).starts_with("import")) {
                while (i < n && src[i] != '\n')
                    i++;
                continue;
            }
            if (!src.substr(i).starts_with("use"))
                break;
            utf::Cp c = utf::decode(src, i + 3);
            if (!c.len || !utf::js_space(c.cp))
                break;
            uint32_t at_line = line;
            size_t upos = i;
            i += 3;
            if (!space())
                return false;
            char q = at(i);
            if (q != '"' && q != '\'')
                return err(i, "expected a folder in quotes after use");
            size_t start = i;
            if (!string(q))
                return false;
            Use u{src.substr(start + 1, i - 1 - (start + 1)), {}, at_line, pos32(upos), false};
            size_t save = i;
            uint32_t save_line = line;
            if (!space())
                return false;
            if (src.substr(i).starts_with("as") && !name_part(at(i + 2))) {
                i += 2;
                if (!space() || !name(u.as))
                    return false;
                u.has_as = true;
                if (!upper(u.as[0]))
                    return err(i, "a use's name starts with a capital (%.*s)", clip(u.as), u.as.data());
            } else {
                i = save;
                line = save_line;
            }
            if (!f.uses.push(arena, u))
                return push_failed();
        }
        uint32_t at_line = line;
        size_t pos = i;
        std::string_view type;
        if (!type_name(type) || !object(type, at_line, pos, f.root))
            return false;
        if (!space())
            return false;
        if (i < n)
            return err(i, "unexpected text after the top element");
        return true;
    }
};

}

std::expected<File*, Error> parse(std::string_view src, Arena& arena) noexcept {
    if (src.size() >= 0xFFFFFFFFu)
        return std::unexpected(Error{1, 0, "the file is larger than 4 GB"});
    size_t bad = utf::invalid_at(src);
    if (bad != src.size()) {
        uint32_t line = 1;
        for (size_t k = 0; k < bad; k++)
            line += src[k] == '\n';
        char buf[64];
        int len = std::snprintf(buf, sizeof buf, "the file isn't UTF-8 (byte %zu)", bad);
        return std::unexpected(Error{line, static_cast<uint32_t>(bad), arena.copy({buf, static_cast<size_t>(len)})});
    }
    Parser p{src, arena};
    p.n = src.size();
    File* f = arena.make<File>();
    if (!f)
        return std::unexpected(Error{1, 0, "out of memory"});
    f->src = src;
    if (!p.file(*f))
        return std::unexpected(p.error);
    return f;
}

}
