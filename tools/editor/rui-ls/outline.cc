// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <cctype>
#include <cstring>
#include <functional>

#include "ls.h"

namespace rui_ls {

namespace {

bool word_start(char c) {
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_' || c == '$';
}
bool word_char(char c) {
    return word_start(c) || (c >= '0' && c <= '9');
}
bool upper(char c) {
    return c >= 'A' && c <= 'Z';
}
bool space_char(char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
}

struct Parser {
    const std::string& src;
    int i = 0, n;
    Outline& o;
    Parser(const std::string& s, Outline& out) : src(s), n(static_cast<int>(s.size())), o(out) {}

    char at(int k) const { return k >= 0 && k < n ? src[static_cast<size_t>(k)] : 0; }
    bool starts_with(const char* s, int k) const {
        return k <= n && src.compare(static_cast<size_t>(k), std::strlen(s), s) == 0;
    }

    bool skip_comment() {
        if (at(i) != '/')
            return false;
        if (at(i + 1) == '/') {
            while (i < n && at(i) != '\n')
                i++;
            return true;
        }
        if (at(i + 1) == '*') {
            size_t j = src.find("*/", static_cast<size_t>(i + 2));
            i = j == std::string::npos ? n : static_cast<int>(j) + 2;
            return true;
        }
        return false;
    }
    void space() {
        while (i < n) {
            char c = at(i);
            if (c == ' ' || c == '\t' || c == '\r' || c == '\n')
                i++;
            else if (!skip_comment())
                return;
        }
    }
    bool name(std::string& out) {
        if (!word_start(at(i)))
            return false;
        int s = i;
        while (i < n && word_char(at(i)))
            i++;
        out = src.substr(static_cast<size_t>(s), static_cast<size_t>(i - s));
        return true;
    }
    void string(char q) {
        i++;
        while (i < n) {
            char c = at(i);
            if (c == '\\') {
                i += 2;
                continue;
            }
            if (c == q) {
                i++;
                return;
            }
            if (c == '\n' && q != '`')
                return;
            if (q == '`' && c == '$' && at(i + 1) == '{') {
                i++;
                balanced('{', '}');
                continue;
            }
            i++;
        }
    }
    bool regex_can_start(int from) const {
        int b = i;
        while (b > from && space_char(at(b - 1)))
            b--;
        if (b == from)
            return true;
        char p = at(b - 1);
        if ((p == '+' || p == '-') && b - from >= 2 && at(b - 2) == p)
            return false;
        if (std::strchr("(,=:[!&|?{;+-*%<>~^", p))
            return true;
        auto word_char = [](char c) { return std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '$'; };
        if (!word_char(p))
            return false;
        int w = b;
        while (w > from && word_char(at(w - 1)))
            w--;
        std::string word = src.substr(static_cast<size_t>(w), static_cast<size_t>(b - w));
        for (const char* k : {"return", "typeof", "case", "in", "of", "void", "delete", "new", "else", "do"})
            if (word == k)
                return true;
        return false;
    }
    bool skip_regex(int from) {
        if (at(i) != '/' || !regex_can_start(from))
            return false;
        bool cls = false;
        for (int j = i + 1; j < n && at(j) != '\n'; j++) {
            char c = at(j);
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
    std::string balanced(char open, char close) {
        int start = i, depth = 0;
        while (i < n) {
            char c = at(i);
            if (c == '"' || c == '\'' || c == '`') {
                string(c);
                continue;
            }
            if (skip_comment())
                continue;
            if (skip_regex(start + 1))
                continue;
            if (c == open)
                depth++;
            else if (c == close && --depth == 0) {
                i++;
                return src.substr(static_cast<size_t>(start), static_cast<size_t>(i - start));
            }
            i++;
        }
        return src.substr(static_cast<size_t>(start), static_cast<size_t>(i - start));
    }
    bool continues(int start) const {
        int b = i;
        while (b > start && space_char(at(b - 1)))
            b--;
        bool step = b - start >= 2 && at(b - 1) == at(b - 2) && (at(b - 1) == '+' || at(b - 1) == '-');
        if (!step && b > start && std::strchr("+-*/%&|^!~?:=<>,.", at(b - 1)))
            return true;
        int j = i + 1;
        while (j < n && space_char(at(j)))
            j++;
        if (at(j) == '/' && (at(j + 1) == '/' || at(j + 1) == '*'))
            return false;
        return j < n && std::strchr("?:.+-*/&|=<>", at(j)) && at(j);
    }
    std::pair<int, int> expression() {
        space();
        int start = i, depth = 0;
        while (i < n) {
            char c = at(i);
            if (c == '"' || c == '\'' || c == '`') {
                string(c);
                continue;
            }
            if (c == '/' && (at(i + 1) == '/' || at(i + 1) == '*')) {
                if (depth == 0 && at(i + 1) == '/')
                    break;
                skip_comment();
                continue;
            }
            if (skip_regex(start))
                continue;
            if (c == '(' || c == '[' || c == '{')
                depth++;
            else if (c == ')' || c == ']' || c == '}') {
                if (depth == 0)
                    break;
                depth--;
            } else if (depth == 0 && c == ';')
                break;
            else if (depth == 0 && c == '\n' && !continues(start))
                break;
            i++;
        }
        int end = i;
        while (end > start && space_char(at(end - 1)))
            end--;
        return {start, end};
    }
    bool type_name(std::string& t) {
        if (!name(t))
            return false;
        std::string more;
        while (at(i) == '.' && upper(at(i + 1))) {
            i++;
            name(more);
            t += "." + more;
        }
        return true;
    }
    bool element_ahead() const {
        int k = i;
        for (;;) {
            if (!upper(at(k)))
                return false;
            while (word_char(at(k)))
                k++;
            if (at(k) == '.' && upper(at(k + 1))) {
                k++;
                continue;
            }
            break;
        }
        while (space_char(at(k)))
            k++;
        return at(k) == '{';
    }
    static bool type_like(const std::string& key) {
        size_t k = 0;
        for (;;) {
            if (k >= key.size() || !upper(key[k]))
                return false;
            while (k < key.size() && word_char(key[k]))
                k++;
            if (k == key.size())
                return true;
            if (key[k] != '.')
                return false;
            k++;
        }
    }
    Element* make(const std::string& type, int pos, Element* parent, const std::string& delegate) {
        o.store.emplace_back();
        Element* el = &o.store.back();
        el->type = type, el->pos = pos, el->parent = parent, el->delegate = delegate;
        return el;
    }
    void value(Member& m, Element* el, bool elements) {
        space();
        if (elements && element_ahead()) {
            int tpos = i;
            std::string t;
            type_name(t);
            Element* child = element(t, tpos, el, m.name);
            m.kind = Member::object;
            m.vpos = tpos;
            m.vend = child->end;
            m.node = child;
            el->children.push_back(child);
            return;
        }
        auto [s, e] = expression();
        m.vpos = s, m.vend = e;
        if (e - s < 200 && (at(s) == '"' || at(s) == '\''))
            m.vtext = src.substr(static_cast<size_t>(s), static_cast<size_t>(e - s));
    }
    Element* element(const std::string& type, int pos, Element* parent, const std::string& delegate) {
        space();
        Element* el = make(type, pos, parent, delegate);
        el->open = i, el->end = n;
        if (at(i) != '{') {
            el->open = -1, el->end = i;
            return el;
        }
        i++;
        for (;;) {
            space();
            while (at(i) == ';' || at(i) == ',')
                i++, space();
            if (i >= n)
                return el;
            if (at(i) == '}') {
                i++;
                el->end = i, el->closed = true;
                return el;
            }
            int kpos = i;
            std::string key;
            if (!name(key)) {
                i++;
                continue;
            }
            if (key == "readonly") {
                space();
                kpos = i;
                if (!name(key))
                    key = "";
            }
            if (key == "signal") {
                space();
                if (word_start(at(i))) {
                    int npos = i;
                    std::string sname;
                    name(sname);
                    space();
                    int ppos = i + 1;
                    std::string params = at(i) == '(' ? balanced('(', ')') : "";
                    if (params.size() >= 2)
                        params = params.substr(1, params.size() - 2);
                    Member m;
                    m.kind = Member::function, m.signal = true, m.name = sname, m.pos = npos,
                    m.kend = npos + static_cast<int>(sname.size());
                    m.params = params, m.ppos = ppos, m.colon = i, m.vpos = i, m.vend = i;
                    el->members.push_back(m);
                    continue;
                }
            }
            if (key == "property" || key == "function") {
                space();
                if (word_start(at(i))) {
                    int npos = i;
                    if (key == "function") {
                        std::string fname;
                        name(fname);
                        space();
                        int ppos = i + 1;
                        std::string params = at(i) == '(' ? balanced('(', ')') : "";
                        if (params.size() >= 2)
                            params = params.substr(1, params.size() - 2);
                        else if (!params.empty())
                            params = params.substr(1);
                        space();
                        int vpos = i + 1;
                        std::string body = at(i) == '{' ? balanced('{', '}') : "";
                        size_t blen = body.size() >= 2 ? body.size() - 2 : body.empty() ? 0 : body.size() - 1;
                        Member m;
                        m.kind = Member::function, m.name = fname, m.pos = npos,
                        m.kend = npos + static_cast<int>(fname.size());
                        m.params = params, m.ppos = ppos, m.colon = vpos, m.vpos = vpos,
                        m.vend = vpos + static_cast<int>(blen);
                        el->members.push_back(m);
                        continue;
                    }
                    std::string ptype, pname;
                    name(pname);
                    space();
                    if (word_start(at(i))) {
                        ptype = pname;
                        npos = i;
                        name(pname);
                    }
                    Member m;
                    m.kind = Member::custom, m.name = pname, m.ptype = ptype, m.pos = npos,
                    m.kend = npos + static_cast<int>(pname.size());
                    el->members.push_back(m);
                    space();
                    if (at(i) == ':') {
                        i++;
                        el->members.back().colon = i;
                        Member mm = el->members.back();
                        value(mm, el, false);
                        el->members.back() = mm;
                    }
                    continue;
                }
            }
            while (at(i) == '.') {
                i++;
                std::string k;
                bool got = name(k);
                key += "." + k;
                if (!got)
                    break;
            }
            int kend = i;
            space();
            if (at(i) == '{') {
                if (type_like(key))
                    el->children.push_back(element(key, kpos, el, ""));
                else
                    balanced('{', '}');
                continue;
            }
            Member m;
            m.kind = Member::prop, m.name = key, m.pos = kpos, m.kend = kend;
            if (at(i) != ':') {
                m.kind = Member::partial;
                el->members.push_back(m);
                continue;
            }
            i++;
            m.colon = i;
            if (key == "id") {
                space();
                m.kind = Member::id;
                m.vpos = i;
                std::string v;
                bool got = name(v);
                m.vend = i;
                if (got && el->id.empty())
                    el->id = v, el->idPos = m.vpos;
                el->members.push_back(m);
                continue;
            }
            value(m, el, true);
            if (m.kind == Member::prop) {
                for (size_t k = 0; k + 2 < key.size(); k++)
                    if ((k == 0 || key[k - 1] == '.') && key[k] == 'o' && key[k + 1] == 'n' && upper(key[k + 2])) {
                        m.kind = Member::handler;
                        break;
                    }
            }
            el->members.push_back(m);
        }
    }

    std::unique_ptr<Outline> run(std::unique_ptr<Outline> out) {
        for (;;) {
            space();
            if (starts_with("import", i)) {
                while (i < n && at(i) != '\n')
                    i++;
                continue;
            }
            if (!(starts_with("use", i) && space_char(at(i + 3))))
                break;
            i += 3;
            space();
            Use u;
            u.pos = i, u.end = i;
            if (at(i) == '"' || at(i) == '\'') {
                string(at(i));
                u.end = i;
                u.path =
                    src.substr(static_cast<size_t>(u.pos + 1), static_cast<size_t>(std::max(0, i - 1 - (u.pos + 1))));
            }
            int save = i;
            space();
            if (starts_with("as", i) && !word_char(at(i + 2))) {
                i += 2;
                space();
                u.asPos = i;
                u.has_as = name(u.as);
            } else {
                i = save;
            }
            o.uses.push_back(u);
        }
        int pos = i;
        std::string type;
        if (!type_name(type))
            return nullptr;
        o.root = element(type, pos, nullptr, "");
        walk(o.root);
        return out;
    }
    void walk(Element* el) {
        o.all.push_back(el);
        if (!el->id.empty() && !o.id(el->id))
            o.ids.emplace_back(el->id, el);
        for (Element* c : el->children)
            walk(c);
    }
};

}

std::unique_ptr<Outline> outline(const std::string& src) {
    auto out = std::make_unique<Outline>();
    Parser p(src, *out);
    return p.run(std::move(out));
}

std::vector<Tok> lex(const std::string& src, int start, int end) {
    std::vector<Tok> out;
    int i = start;
    auto at = [&](int k) { return k >= 0 && k < static_cast<int>(src.size()) ? src[static_cast<size_t>(k)] : '\0'; };
    std::function<void(bool)> code = [&](bool stop_at_brace) {
        int depth = 0;
        while (i < end) {
            char c = at(i);
            if (c == '/' && at(i + 1) == '/') {
                while (i < end && at(i) != '\n')
                    i++;
                continue;
            }
            if (c == '/' && at(i + 1) == '*') {
                size_t j = src.find("*/", static_cast<size_t>(i + 2));
                i = j == std::string::npos || static_cast<int>(j) + 2 > end ? end : static_cast<int>(j) + 2;
                continue;
            }
            if (c == '"' || c == '\'') {
                i++;
                while (i < end && at(i) != c && at(i) != '\n')
                    i += at(i) == '\\' ? 2 : 1;
                i++;
                continue;
            }
            if (c == '`') {
                i++;
                while (i < end && at(i) != '`') {
                    if (at(i) == '\\') {
                        i += 2;
                        continue;
                    }
                    if (at(i) == '$' && at(i + 1) == '{') {
                        i += 2;
                        code(true);
                        continue;
                    }
                    i++;
                }
                i++;
                continue;
            }
            if (c == '{')
                depth++;
            if (c == '}') {
                if (stop_at_brace && depth == 0) {
                    i++;
                    return;
                }
                depth--;
            }
            if (c >= '0' && c <= '9') {
                while (i < end && (word_char(at(i)) || at(i) == '.'))
                    i++;
                continue;
            }
            if (c == '.' && at(i + 1) == '.' && at(i + 2) == '.') {
                i += 3;
                out.push_back(Tok{"...", i - 3});
                continue;
            }
            if (c == '.' || (c == '?' && at(i + 1) == '.' && !(at(i + 2) >= '0' && at(i + 2) <= '9'))) {
                out.push_back(Tok{".", i});
                i += c == '.' ? 1 : 2;
                continue;
            }
            if (word_start(c)) {
                int s = i;
                while (i < end && word_char(at(i)))
                    i++;
                Tok t{"id", s, i};
                t.text = src.substr(static_cast<size_t>(s), static_cast<size_t>(i - s));
                out.push_back(t);
                continue;
            }
            if (!space_char(c))
                out.push_back(Tok{std::string(1, c), i});
            i++;
        }
    };
    code(false);
    for (size_t k = 1; k < out.size(); k++) {
        if (out[k].t != "id")
            continue;
        const Tok& p = out[k - 1];
        if (p.t != ".")
            continue;
        int from = p.s + (at(p.s) == '?' ? 2 : 1);
        bool blank = true;
        for (int q = from; q < out[k].s; q++)
            blank = blank && space_char(at(q));
        out[k].dot = blank;
    }
    return out;
}

}
