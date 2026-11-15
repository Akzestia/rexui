// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <functional>
#include <regex>
#include <sstream>

#include "engine/base/arena.h"
#include "engine/sema/check.h"
#include "engine/sema/perf.h"
#include "engine/syntax/rui.h"
#include "gen/rx_props.h"
#include "model.h"

namespace rui_ls {

bool snippets = false;

namespace {
std::map<std::string, std::unique_ptr<Doc>> g_docs;
long g_serial = 0;
}

void log(const std::string& msg) {
    std::fprintf(stderr, "%s\n", msg.c_str());
}

Doc* open(const std::string& uri, const std::string& text, long version) {
    auto d = std::make_unique<Doc>();
    d->uri = uri, d->text = text, d->version = version, d->serial = ++g_serial;
    d->starts.push_back(0);
    for (size_t k = 0; k < text.size(); k++)
        if (text[k] == '\n')
            d->starts.push_back(static_cast<int>(k) + 1);
    Doc* raw = d.get();
    g_docs[uri] = std::move(d);
    g_generation++;
    return raw;
}
Doc* doc(const std::string& uri) {
    auto it = g_docs.find(uri);
    return it == g_docs.end() ? nullptr : it->second.get();
}
void close(const std::string& uri) {
    g_docs.erase(uri);
}
std::vector<std::string> open_uris() {
    std::vector<std::string> out;
    for (auto& [k, v] : g_docs)
        out.push_back(k);
    return out;
}
std::string file_of(const std::string& uri) {
    if (uri.rfind("file://", 0) != 0)
        return "";
    std::string out;
    for (size_t k = 7; k < uri.size(); k++) {
        if (uri[k] == '%' && k + 2 < uri.size()) {
            out += static_cast<char>(std::strtol(uri.substr(k + 1, 2).c_str(), nullptr, 16));
            k += 2;
        } else
            out += uri[k];
    }
    return out;
}
Outline* outline_of(Doc* d) {
    if (!d->outlined)
        d->o = outline(d->text), d->outlined = true;
    if (d->o)
        annotate(file_of(d->uri), d->o.get());
    return d->o.get();
}

size_t u16len(const std::string& s) {
    size_t n = 0;
    for (size_t i = 0; i < s.size(); i++) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        if ((c & 0xC0) == 0x80)
            continue;
        n += c >= 0xF0 ? 2 : 1;
    }
    return n;
}
J to_pos(Doc* d, int off) {
    off = std::clamp(off, 0, static_cast<int>(d->text.size()));
    auto it = std::upper_bound(d->starts.begin(), d->starts.end(), off);
    int line = static_cast<int>(it - d->starts.begin()) - 1;
    size_t s = static_cast<size_t>(d->starts[static_cast<size_t>(line)]);
    size_t ch = 0;
    for (size_t k = s; k < static_cast<size_t>(off); k++) {
        unsigned char c = static_cast<unsigned char>(d->text[k]);
        if ((c & 0xC0) != 0x80)
            ch += c >= 0xF0 ? 2 : 1;
    }
    J p = J::object();
    p.set("line", J(line));
    p.set("character", J(static_cast<unsigned long>(ch)));
    return p;
}
int to_off(Doc* d, const J& pos) {
    long line = static_cast<long>(pos["line"].num()), ch = static_cast<long>(pos["character"].num());
    if (line >= static_cast<long>(d->starts.size()))
        return static_cast<int>(d->text.size());
    size_t k = static_cast<size_t>(d->starts[static_cast<size_t>(std::max(0L, line))]);
    for (long u = 0; u < ch && k < d->text.size(); u++) {
        unsigned char c = static_cast<unsigned char>(d->text[k]);
        size_t n = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
        if (n == 4)
            u++;
        k += n;
    }
    return static_cast<int>(std::min(k, d->text.size()));
}
J range(Doc* d, int s, int e) {
    J r = J::object();
    r.set("start", to_pos(d, s));
    r.set("end", to_pos(d, e));
    return r;
}

namespace {

bool wchar(char c) {
    return std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '$';
}
struct Word {
    int s = 0, e = 0;
    std::string text;
    explicit operator bool() const { return e > s; }
};
Word word_at(const std::string& text, int off) {
    int s = off, e = off, n = static_cast<int>(text.size());
    while (s > 0 && wchar(text[static_cast<size_t>(s - 1)]))
        s--;
    while (e < n && wchar(text[static_cast<size_t>(e)]))
        e++;
    if (s == e)
        return {};
    return Word{s, e, text.substr(static_cast<size_t>(s), static_cast<size_t>(e - s))};
}
Element* element_at(Outline* o, int off) {
    Element* found = nullptr;
    for (Element* el : o->all) {
        if (el->open < 0 || off <= el->open || !(off < el->end || (!el->closed && off == el->end)))
            continue;
        if (!found || el->open > found->open)
            found = el;
    }
    return found;
}
struct At {
    Member* m = nullptr;
    bool value = false;
};
At member_at(Element* el, int off) {
    for (Member& m : el->members) {
        if (m.colon >= 0 && off >= m.colon && off <= m.vend)
            return {&m, true};
        if (m.kind == Member::function && off >= m.ppos && off <= m.ppos + static_cast<int>(m.params.size()))
            return {&m, true};
        if (off >= m.pos && off <= m.kend)
            return {&m, false};
    }
    return {};
}
Element* delegate_root(Element* el) {
    for (Element* e = el; e; e = e->parent)
        if (!e->delegate.empty())
            return e;
    return nullptr;
}
std::string lower_first(const std::string& s) {
    return s.empty() ? s : std::string(1, static_cast<char>(std::tolower(s[0]))) + s.substr(1);
}
std::string upper_first(const std::string& s) {
    return s.empty() ? s : std::string(1, static_cast<char>(std::toupper(s[0]))) + s.substr(1);
}
std::string home_short(std::string p) {
    const char* h = std::getenv("HOME");
    if (h && *h && p.find(h) != std::string::npos)
        p.replace(p.find(h), std::strlen(h), "~");
    return p;
}
std::string join(const std::vector<std::string>& xs, const std::string& sep) {
    std::string r;
    for (size_t i = 0; i < xs.size(); i++)
        r += (i ? sep : "") + xs[i];
    return r;
}
std::string re_escape(const std::string& s) {
    std::string r;
    for (char c : s) {
        if (std::strchr("\\^$.|?*+()[]{}", c))
            r += '\\';
        r += c;
    }
    return r;
}
struct Range {
    Element* el;
    Member* m;
    int s, e;
};
std::vector<Range> code_ranges(Outline* o) {
    std::vector<Range> out;
    for (Element* el : o->all)
        for (Member& m : el->members) {
            if (m.kind == Member::prop || m.kind == Member::handler || m.kind == Member::custom
                || m.kind == Member::function) {
                if (m.vpos >= 0)
                    out.push_back({el, &m, m.vpos, m.vend});
                if (m.kind == Member::function)
                    out.push_back({el, &m, m.ppos, m.ppos + static_cast<int>(m.params.size())});
            }
        }
    return out;
}

size_t distance(const std::string& a, const std::string& b) {
    std::vector<size_t> dp(b.size() + 1);
    for (size_t k = 0; k <= b.size(); k++)
        dp[k] = k;
    for (size_t x = 1; x <= a.size(); x++) {
        size_t prev = dp[0];
        dp[0] = x;
        for (size_t y = 1; y <= b.size(); y++) {
            size_t t = dp[y];
            dp[y] = std::min({dp[y] + 1, dp[y - 1] + 1, prev + (a[x - 1] == b[y - 1] ? 0 : 1)});
            prev = t;
        }
    }
    return dp[b.size()];
}
std::string suggest(const std::string& name, const std::vector<std::string>& candidates) {
    const std::string* best = nullptr;
    size_t best_d = 3;
    for (const std::string& c : candidates) {
        size_t d = distance(name, c);
        if (d < best_d)
            best = &c, best_d = d;
    }
    return best && best_d <= std::max<size_t>(1, name.size() / 3) ? " (did you mean " + *best + "?)" : "";
}

constexpr int ERROR = 1, WARNING = 2, HINT = 4;

static bool slot_in_text(const Element* e, const std::string& name) {
    if (!e)
        return false;
    if (e->type == "Slot")
        for (const Member& sm : e->members)
            if (sm.kind == Member::prop && sm.name == "name" && sm.vtext == "\"" + name + "\"")
                return true;
    for (const Element* c : e->children)
        if (slot_in_text(c, name))
            return true;
    for (const Member& om : e->members)
        if (om.kind == Member::object && slot_in_text(om.node, name))
            return true;
    return false;
}

static const Member* declared_signal(const Element* el, const std::string& handler) {
    if (handler.size() < 3)
        return nullptr;
    std::string s = lower_first(handler.substr(2));
    for (const Member& m : el->members)
        if (m.signal && m.name == s)
            return &m;
    if (el->comp)
        if (const Name* n = comp_names(el->comp).get(s); n && n->member && n->member->signal)
            return n->member;
    return nullptr;
}

std::string signal_params_of(Element* el, const std::string& handler) {
    if (const Member* m = declared_signal(el, handler)) {
        std::string out;
        std::stringstream ss(m->params);
        for (std::string part; std::getline(ss, part, ',');) {
            size_t e = part.find_last_not_of(" \t\n");
            if (e == std::string::npos)
                continue;
            size_t b = part.find_last_of(" \t\n", e);
            out += (out.empty() ? "" : ", ")
                + part.substr(b == std::string::npos ? 0 : b + 1, e - (b == std::string::npos ? 0 : b + 1) + 1);
        }
        return out;
    }
    std::string params, why;
    signal_params(type_of(el->base), handler, el->base, params, why);
    return params;
}

struct Reader final : rx::engine::sema::Reader {
    std::deque<std::string> texts;
    bool read(std::string_view path, std::string_view& text) override {
        std::string p = expand(std::string(path));
        if (Doc* d = doc("file://" + p)) {
            texts.push_back(d->text);
        } else {
            FILE* f = std::fopen(p.c_str(), "rb");
            if (!f)
                return false;
            std::string t;
            char b[65536];
            size_t n;
            while ((n = std::fread(b, 1, sizeof b, f)) > 0)
                t.append(b, n);
            std::fclose(f);
            texts.push_back(std::move(t));
        }
        text = texts.back();
        return true;
    }
};

}

J diagnose(Doc* d) {
    J out = J::array();
    auto add = [&](int s, int e, const std::string& message, int severity = ERROR) {
        out.push(J::object({{"range", range(d, s, std::max(e, s + 1))},
                            {"severity", J(severity)},
                            {"source", J("rui")},
                            {"message", J(message)}}));
    };
    {
        rx::engine::Arena arena;
        auto tree = rx::engine::rui::parse(d->text, arena);
        if (!tree) {
            int at = std::min(static_cast<int>(tree.error().pos), static_cast<int>(d->text.size()));
            Word w = word_at(d->text, at);
            std::string msg(tree.error().msg);
            static const std::regex lead(R"(^\d+: )");
            add(at, w && w.s == at ? w.e : at + 1, std::regex_replace(msg, lead, ""));
            return out;
        }
    }
    Outline* o = outline_of(d);
    if (!o)
        return out;
    std::string file = file_of(d->uri);
    bool component = is_component_file(file);
    if (!component && o->root->type != "Dock" && o->root->type != "Panes")
        add(o->root->pos, o->root->pos + static_cast<int>(o->root->type.size()),
            "the top element must be a Dock (or Panes), not " + o->root->type
                + (type_of(o->root->type) ? ""
                                          : " (a component, " + o->root->type + ".rui, is used from another file)"));
    for (const Use& u : o->uses) {
        std::string dir = use_dir(file, u);
        if (u.end == u.pos)
            add(u.pos, u.pos + 1, "expected a folder in quotes after use");
        else if (!dir.empty() && !exists(dir))
            add(u.pos, u.end, "no folder " + dir, WARNING);
        if (u.has_as && !(u.as[0] >= 'A' && u.as[0] <= 'Z'))
            add(u.asPos, u.asPos + static_cast<int>(u.as.size()), "a use's name starts with a capital (" + u.as + ")");
    }
    std::map<Element*, std::vector<std::string>> seen_ids;
    int slots = 0;
    for (Element* el : o->all) {
        int type_end = el->pos + static_cast<int>(el->type.size());
        if (!el->id.empty()) {
            Element* key = delegate_root(el) ? delegate_root(el) : o->root;
            auto& ids = seen_ids[key];
            if (std::find(ids.begin(), ids.end(), el->id) != ids.end())
                add(el->idPos, el->idPos + static_cast<int>(el->id.size()), "id " + el->id + " is used twice");
            ids.push_back(el->id);
        }
        if (el->type == "Slot") {
            if (!component)
                add(el->pos, type_end,
                    "a Slot is only for a component's file (Card.rui): where Card { ... }'s elements go");
            else if (++slots > 1)
                add(el->pos, type_end, "a component has one Slot");
            continue;
        }
        if (el->comp) {
            auto cycle = cycle_of(el->comp, file.empty() ? std::vector<std::string>{} : std::vector<std::string>{file});
            if (!cycle.empty()) {
                std::vector<std::string> names;
                for (auto& f : cycle)
                    names.push_back(basename(f));
                add(el->pos, type_end, el->type + " uses itself (" + join(names, " -> ") + ")");
                continue;
            }
        }
        const Type* t = type_of(el->base);
        if (!t || el->base.empty()) {
            size_t dot = el->type.rfind('.');
            std::string ns = dot == std::string::npos ? "" : el->type.substr(0, dot);
            if (!ns.empty()) {
                bool used = false;
                for (const Use& u : o->uses)
                    used = used || (u.has_as && u.as == ns);
                if (!used) {
                    add(el->pos, el->pos + static_cast<int>(ns.size()), "no use ... as " + ns + " for " + el->type);
                    continue;
                }
            }
            auto dirs = component_dirs(file, *o, el->type);
            std::vector<std::string> known;
            for (auto& k : type_names())
                if (k != "Slot")
                    known.push_back(k);
            for (auto& dir : dirs)
                for (auto& c : components_in(dir))
                    known.push_back(c);
            std::string bare = el->type.substr(dot == std::string::npos ? 0 : dot + 1);
            add(el->pos, type_end,
                "unknown element " + el->type + suggest(bare, known)
                    + (dirs.empty() ? "" : " (no " + bare + ".rui in " + join(dirs, ", ") + ")"));
            continue;
        }
        Names own = el->comp ? comp_names(el->comp) : Names{};
        Names names = type_names(el->base, !el->delegate.empty());
        for (auto& [k, v] : own)
            names.set(k, v);
        std::vector<std::string> customs;
        auto has_custom = [&](const std::string& n) {
            return std::find(customs.begin(), customs.end(), n) != customs.end();
        };
        for (const Member& m : el->members) {
            if (m.kind != Member::custom)
                continue;
            if (names.has(m.name) || has_custom(m.name))
                add(m.pos, m.kend, el->type + " already has a property " + m.name);
            customs.push_back(m.name);
        }
        for (auto& [k, v] : own)
            if (v.kind == Name::custom)
                customs.push_back(k);
        std::vector<std::string> set;
        for (const Member& m : el->members) {
            if (m.kind == Member::function) {
                if (names.has(m.name) || has_custom(m.name))
                    add(m.pos, m.kend, el->type + " already has " + m.name);
            } else if (m.kind == Member::prop) {
                if (!t->prop(m.name) && !has_custom(m.name)) {
                    std::vector<std::string> cand;
                    for (auto& p : t->props)
                        cand.push_back(p.name);
                    cand.insert(cand.end(), customs.begin(), customs.end());
                    add(m.pos, m.kend, el->type + " has no property " + m.name + suggest(m.name, cand));
                }
            } else if (m.kind == Member::object) {
                if (el->comp && el->comp->o && slot_in_text(el->comp->o->root, m.name))
                    continue;
                if (!t->has_object(m.name))
                    add(m.pos, m.kend, el->type + " has no property " + m.name + " taking an element");
            } else if (m.kind == Member::handler) {
                std::string params, why;
                if (declared_signal(el, m.name))
                    continue;
                if (!signal_params(t, m.name, el->base, params, why)) {
                    std::vector<std::string> signals;
                    for (auto& [s, p] : t->signals)
                        signals.push_back("on" + upper_first(s));
                    add(m.pos, m.kend, why + suggest(m.name, signals));
                    continue;
                }
                static const std::regex changed(R"(^on([A-Z]\w*)Changed$)");
                std::smatch cm;
                if (std::regex_match(m.name, cm, changed) && !t->signal(lower_first(cm[1]) + "Changed")) {
                    std::string p = lower_first(cm[1]);
                    const Name* nm = names.get(p);
                    bool known = (nm && nm->kind != Name::group && nm->kind != Name::method) || has_custom(p);
                    if (!known)
                        add(m.pos, m.kend, el->type + " has no property " + p + ": " + m.name + " never runs", WARNING);
                }
            }
            if (m.kind == Member::prop || m.kind == Member::handler || m.kind == Member::object) {
                if (std::find(set.begin(), set.end(), m.name) != set.end())
                    add(m.pos, m.kend, m.name + " is set twice in this " + el->type + " (the last one wins)", WARNING);
                set.push_back(m.name);
            }
        }
    }
    for (const Range& r : code_ranges(o)) {
        auto toks = lex(d->text, r.s, r.e);
        std::string code = d->text.substr(static_cast<size_t>(r.s), static_cast<size_t>(r.e - r.s));
        for (size_t k = 0; k + 2 < toks.size(); k++) {
            const Tok &head = toks[k], &dot = toks[k + 1], &member = toks[k + 2];
            if (head.t != "id" || head.dot || dot.t != "." || member.t != "id" || !member.dot)
                continue;
            Element* target = nullptr;
            if (Element* e = o->id(head.text))
                target = e;
            else if (head.text == "parent" && !element_names(r.el).has("parent"))
                target = r.el->parent;
            if (!target || !type_of(target->base) || target->base.empty())
                continue;
            std::string h = re_escape(head.text);
            std::regex local("\\b(const|let|var|function)\\s+" + h + "\\b|\\(\\s*" + h + "\\s*\\)\\s*=>|\\b" + h
                             + "\\s*=>");
            if (std::regex_search(code, local))
                continue;
            std::regex word("\\b" + h + "\\b");
            if (r.m->kind == Member::function && std::regex_search(r.m->params, word))
                continue;
            if (r.m->kind == Member::handler && std::regex_search(signal_params_of(r.el, r.m->name), word))
                continue;
            Names names = element_names(target);
            if (names.has(member.text) || member.text == "parent" || member.text == "children")
                continue;
            std::string what =
                head.text == "parent" ? "parent (" + target->type + ")" : head.text + " (" + target->type + ")";
            std::vector<std::string> cand;
            for (auto& [n, v] : names)
                cand.push_back(n);
            add(member.s, member.e, what + " has no property " + member.text + suggest(member.text, cand), WARNING);
        }
    }
    {
        char cwd[4096];
        std::string path = !file.empty() ? file : std::string(getcwd(cwd, sizeof cwd) ? cwd : ".") + "/untitled.rui";
        Reader reader;
        rx::engine::Arena arena;
        auto r = rx::engine::sema::check(path, basename(path), d->text, reader, arena);
        std::vector<std::string> seen;
        for (const J& x : out.a)
            seen.push_back(std::to_string(static_cast<long>(x["range"]["start"]["line"].num())) + ":"
                           + x["message"].text());
        for (const auto& x : r.diags) {
            if (!file.empty() && x.path != file)
                continue;
            int at = std::min(static_cast<int>(x.pos), static_cast<int>(d->text.size()));
            long line = static_cast<long>(to_pos(d, at)["line"].num());
            std::string key = std::to_string(line) + ":" + std::string(x.msg);
            bool err = x.severity == rx::engine::sema::Severity::error;
            bool line_has_error = false;
            if (!err && std::string_view(x.msg).find(") has no ") != std::string_view::npos) {
                bool said = false;
                for (const J& y : out.a)
                    said = said
                        || (static_cast<long>(y["range"]["start"]["line"].num()) == line
                            && y["message"].text().find(" has no ") != std::string::npos);
                if (said)
                    continue;
            }
            for (const J& y : out.a)
                line_has_error = line_has_error
                    || (static_cast<long>(y["range"]["start"]["line"].num()) == line && y["severity"] == ERROR);
            if (std::find(seen.begin(), seen.end(), key) != seen.end() || (line_has_error && err))
                continue;
            seen.push_back(key);
            Word w = word_at(d->text, at);
            add(at, w && w.s == at ? w.e : at + 1, std::string(x.msg), err ? ERROR : WARNING);
        }
        if (auto tree = rx::engine::rui::parse(d->text, arena))
            for (const auto& x : rx::engine::sema::perf(**tree, path, basename(path), arena)) {
                int at = std::min(static_cast<int>(x.pos), static_cast<int>(d->text.size()));
                Word w = word_at(d->text, at);
                add(at, w && w.s == at ? w.e : at + 1, std::string(x.msg), HINT);
            }
    }
    return out;
}

namespace {

std::string prop_doc_of(const std::string& type, const std::string& name);
std::string prop_doc(const std::string& type, const std::string& name) {
    static std::map<std::string, std::string> memo;
    static const Docs* was = nullptr;
    static size_t stamp = 0;
    const Docs& dd = docs();
    if (was != &dd || stamp != dd.serial)
        memo.clear(), was = &dd, stamp = dd.serial;
    std::string key = type + "\x1f" + name;
    auto it = memo.find(key);
    if (it != memo.end())
        return it->second;
    return memo[key] = prop_doc_of(type, name);
}
std::string prop_doc_of(const std::string& type, const std::string& name) {
    const Type* t = type_of(type);
    std::vector<std::string> lines;
    const Prop* p = t ? t->prop(name) : nullptr;
    if (p) {
        lines.push_back("```rui\n" + type + " { " + name + ": " + (p->has_default ? p->default_json : "…") + " }\n```");
        auto it = docs().elements.find(type);
        std::string words = phrase(it != docs().elements.end() ? it->second.first : "", name);
        if (words.empty())
            words = phrase(docs().general, name);
        if (!words.empty())
            lines.push_back(words);
        if (p->js)
            lines.push_back("Written by rexui as the element changes; reading it follows it.");
    }
    return join(lines, "\n\n");
}

std::string element_doc_of(const std::string& type);
std::string element_doc(const std::string& type) {
    static std::map<std::string, std::string> memo;
    static size_t stamp = 0;
    const Docs& dd = docs();
    if (stamp != dd.serial)
        memo.clear(), stamp = dd.serial;
    auto it = memo.find(type);
    if (it != memo.end())
        return it->second;
    return memo[type] = element_doc_of(type);
}
std::string element_doc_of(const std::string& type) {
    const Type* t = type_of(type);
    if (!t)
        return "";
    std::vector<std::string> out{"```rui\n" + type + " { }\n```"};
    auto it = docs().elements.find(type);
    if (it != docs().elements.end())
        out.push_back(it->second.first);
    std::vector<std::string> sig, met, obj;
    for (auto& [s, p] : t->signals)
        sig.push_back("`" + s + "(" + p + ")`");
    for (auto& m : t->methods)
        met.push_back("`" + m + "()`");
    for (auto& o : t->objects)
        obj.push_back("`" + o + "`");
    if (!sig.empty())
        out.push_back("Signals: " + join(sig, ", "));
    if (!met.empty())
        out.push_back("Methods: " + join(met, ", "));
    if (!obj.empty())
        out.push_back("Takes an element: " + join(obj, ", "));
    return join(out, "\n\n");
}

std::string custom_doc(Element* el, const Member& m, Component* comp) {
    std::string code = m.kind == Member::function
        ? "function " + m.name + "(" + m.params + ")"
        : "property " + (m.ptype.empty() ? std::string("var") : m.ptype) + " " + m.name;
    if (m.kind == Member::custom && m.vpos >= 0) {
        std::string v =
            comp ? comp->d->text.substr(static_cast<size_t>(m.vpos), static_cast<size_t>(m.vend - m.vpos)) : "";
        if (!v.empty() && v.find('\n') == std::string::npos && u16len(v) < 60)
            code += ": " + v;
    }
    std::string where = comp ? "in " + comp->name + " (" + home_short(comp->path) + ")"
                             : "in " + el->type + (el->id.empty() ? "" : " " + el->id);
    return "```rui\n" + code + "\n```\n\n" + where;
}

std::string component_doc(Element* el) {
    Component* c = el->comp;
    std::vector<std::string> out{"```rui\n" + el->type + " { }\n```"};
    std::string what = "`" + home_short(c->path) + "`";
    if (!el->base.empty())
        what += ": a " + c->o->root->type + (c->o->root->type != el->base ? " (a " + el->base + ")" : "");
    out.push_back(what);
    std::vector<std::string> own;
    for (auto& [k, v] : comp_names(c))
        own.push_back(v.kind == Name::function ? "`" + k + "(" + v.member->params + ")`" : "`" + k + "`");
    if (!own.empty())
        out.push_back("Its own: " + join(own, ", "));
    bool slot = false;
    for (Element* x : c->o->all)
        slot = slot || x->type == "Slot";
    if (slot)
        out.push_back("Elements written in it go where its `Slot` is.");
    std::string base = el->base.empty() ? "" : element_doc(el->base);
    if (!base.empty()) {
        static const std::regex head("^```rui\\n.*\\n```\\n\\n");
        out.push_back(std::regex_replace(base, head, "", std::regex_constants::format_first_only));
    }
    return join(out, "\n\n");
}

std::vector<Word> chain_at(const std::string& text, int off) {
    Word w = word_at(text, off);
    if (!w)
        return {};
    std::vector<Word> chain{w};
    int k = w.s;
    auto at = [&](int i) { return i >= 0 && i < static_cast<int>(text.size()) ? text[static_cast<size_t>(i)] : '\0'; };
    for (;;) {
        int j = k;
        while (j > 0 && (at(j - 1) == ' ' || at(j - 1) == '\t'))
            j--;
        if (at(j - 1) != '.' || at(j - 2) == '.')
            break;
        j -= at(j - 2) == '?' ? 2 : 1;
        while (j > 0 && (at(j - 1) == ' ' || at(j - 1) == '\t'))
            j--;
        Word p = word_at(text, j);
        if (!p || p.e != j)
            break;
        chain.insert(chain.begin(), p);
        k = p.s;
    }
    return chain;
}

const char* const k_builtins[] = {"Math",
                                  "JSON",
                                  "Date",
                                  "Object",
                                  "Array",
                                  "String",
                                  "Number",
                                  "Boolean",
                                  "parseInt",
                                  "parseFloat",
                                  "isNaN",
                                  "encodeURIComponent",
                                  "decodeURIComponent",
                                  "Promise",
                                  "Map",
                                  "Set",
                                  "RegExp",
                                  "Intl",
                                  "setTimeout",
                                  "undefined",
                                  "NaN",
                                  "Infinity"};
const char* const k_keywords[] = {"return", "if",   "else",    "const", "let",   "var",   "function", "true",
                                  "false",  "null", "typeof",  "new",   "for",   "while", "break",    "continue",
                                  "switch", "case", "default", "try",   "catch", "throw", "of",       "in"};
bool builtin(const std::string& w) {
    for (const char* b : k_builtins)
        if (w == b)
            return true;
    return false;
}

struct Meaning {
    enum Kind { none, param, signal_param, id, element, name, global } kind = none;
    Element* el = nullptr;
    std::string word;
    Name sub;
    std::string doc;
    explicit operator bool() const { return kind != none; }
};
bool word_in(const std::string& list, const std::string& w) {
    std::regex re("\\b" + re_escape(w) + "\\b");
    return std::regex_search(list, re);
}
Meaning resolve(Outline* o, Element* el, Member* m, const std::string& word) {
    if (m && m->kind == Member::function && word_in(m->params, word))
        return Meaning{Meaning::param};
    if (m && m->kind == Member::handler) {
        std::string ps = signal_params_of(el, m->name);
        std::vector<std::string> parts;
        size_t a = 0;
        while (a <= ps.size()) {
            size_t c = ps.find(',', a);
            std::string part = ps.substr(a, c == std::string::npos ? std::string::npos : c - a);
            size_t f = part.find_first_not_of(" \t"), l = part.find_last_not_of(" \t");
            parts.push_back(f == std::string::npos ? "" : part.substr(f, l - f + 1));
            if (c == std::string::npos)
                break;
            a = c + 1;
        }
        if (std::find(parts.begin(), parts.end(), word) != parts.end()) {
            Meaning r{Meaning::signal_param};
            r.doc = "the argument of " + el->type + "'s " + lower_first(m->name.substr(2)) + " signal";
            return r;
        }
    }
    if (Element* e = o->id(word))
        return Meaning{Meaning::id, e};
    if (word == "parent")
        return el->parent ? Meaning{Meaning::element, el->parent} : Meaning{};
    for (Element* scope : {el, delegate_root(el), o->root}) {
        if (!scope)
            continue;
        Names names = element_names(scope);
        if (const Name* sub = names.get(word)) {
            Meaning r{Meaning::name, scope, word, *sub};
            return r;
        }
    }
    const auto& gl = global_names();
    if (std::find(gl.begin(), gl.end(), word) != gl.end() || builtin(word) || docs().globals.count(word)) {
        Meaning r{Meaning::global};
        r.word = word;
        return r;
    }
    return {};
}
Meaning resolve_chain(Outline* o, Element* el, Member* m, const std::vector<std::string>& chain) {
    Meaning cur = resolve(o, el, m, chain[0]);
    for (size_t k = 1; k < chain.size(); k++) {
        if (!cur)
            return {};
        const std::string& w = chain[k];
        if (cur.kind == Meaning::id || cur.kind == Meaning::element) {
            if (w == "parent") {
                cur = cur.el->parent ? Meaning{Meaning::element, cur.el->parent} : Meaning{};
                continue;
            }
            Names names = element_names(cur.el);
            const Name* sub = names.get(w);
            cur = sub ? Meaning{Meaning::name, cur.el, w, *sub} : Meaning{};
        } else if (cur.kind == Meaning::name && cur.sub.kind == Name::group) {
            std::string p = cur.word + "." + w;
            const Type* t = type_of(cur.el->base);
            cur = t && t->prop(p) ? Meaning{Meaning::name, cur.el, p, Name{Name::prop, p}} : Meaning{};
        } else if (cur.kind == Meaning::global) {
            cur.word = cur.word + "." + w;
        } else {
            return {};
        }
    }
    return cur;
}

std::string describe(const Meaning& r) {
    switch (r.kind) {
    case Meaning::id:
        return "```rui\n" + r.el->type + " { id: " + r.el->id + " }\n```\n\nline $LINE";
    case Meaning::element:
        return "```rui\n" + r.el->type + (r.el->id.empty() ? " { }" : " { id: " + r.el->id + " }") + "\n```";
    case Meaning::name: {
        const Name& sub = r.sub;
        if (sub.kind == Name::custom || sub.kind == Name::function)
            return custom_doc(r.el, *sub.member, sub.comp);
        if (sub.kind == Name::prop)
            return prop_doc(r.el->base, sub.prop_name);
        if (sub.kind == Name::group) {
            std::vector<std::string> ps;
            if (const Type* t = type_of(r.el->base))
                for (auto& p : t->props)
                    if (p.name.rfind(r.word + ".", 0) == 0)
                        ps.push_back(p.name);
            return "```rui\n" + join(ps, "\n") + "\n```";
        }
        if (sub.kind == Name::model)
            return r.word == "modelData" ? "the delegate's model entry" : "the delegate's index in its model";
        if (sub.kind == Name::method) {
            auto it = docs().elements.find(r.el->base);
            return "```rui\n" + r.el->base + "." + r.word + "()\n```\n\n"
                + phrase(it != docs().elements.end() ? it->second.first : "", r.word + "()");
        }
        return "";
    }
    case Meaning::global: {
        auto it = docs().globals.find(r.word);
        if (it == docs().globals.end())
            it = docs().globals.find(r.word.substr(0, r.word.find('.')));
        return "```rui\n" + r.word + "\n```" + (it != docs().globals.end() ? "\n\n" + it->second : "");
    }
    case Meaning::signal_param:
        return r.doc;
    default:
        return "";
    }
}

J hover_result(Doc* d, const std::string& text, int s, int e) {
    if (text.empty())
        return J(nullptr);
    return J::object(
        {{"contents", J::object({{"kind", J("markdown")}, {"value", J(text)}})}, {"range", range(d, s, e)}});
}

std::vector<std::string> words_of(const std::vector<Word>& c) {
    std::vector<std::string> out;
    for (auto& w : c)
        out.push_back(w.text);
    return out;
}

}

J hover(Doc* d, const J& pos) {
    Outline* o = outline_of(d);
    if (!o)
        return J(nullptr);
    int off = to_off(d, pos);
    Word w = word_at(d->text, off);
    if (!w)
        return J(nullptr);
    for (Element* el : o->all) {
        if (off < el->pos || off > el->pos + static_cast<int>(el->type.size()))
            continue;
        std::string t = el->comp ? component_doc(el) : element_doc(el->type);
        return hover_result(d, t.empty() ? "unknown element " + el->type : t, el->pos,
                            el->pos + static_cast<int>(el->type.size()));
    }
    for (const Use& u : o->uses) {
        if (off < u.pos || off > u.end)
            continue;
        std::string dir = use_dir(file_of(d->uri), u);
        auto names = dir.empty() ? std::vector<std::string>{} : components_in(dir);
        std::vector<std::string> ns;
        for (auto& k : names)
            ns.push_back("`" + (u.has_as ? u.as + "." : "") + k + "`");
        return hover_result(d,
                            "```rui\nuse \"" + u.path + "\"" + (u.has_as ? " as " + u.as : "") + "\n```\n\n"
                                + (dir.empty() ? "" : "`" + home_short(dir) + "`")
                                + (!ns.empty() ? ": " + join(ns, ", ") : ": no components"),
                            u.pos, u.end);
    }
    Element* el = element_at(o, off);
    if (!el)
        return J(nullptr);
    At at = member_at(el, off);
    if (!at.m)
        return J(nullptr);
    Member& m = *at.m;
    if (!at.value) {
        if (m.kind == Member::custom || m.kind == Member::function)
            return hover_result(d, custom_doc(el, m, nullptr), m.pos, m.kend);
        if (el->comp) {
            Names own = comp_names(el->comp);
            if (const Name* mine = own.get(m.name))
                return hover_result(d, custom_doc(el, *mine->member, mine->comp), m.pos, m.kend);
        }
        if (m.kind == Member::id)
            return hover_result(d, member_doc("id:"), m.pos, m.kend);
        if (m.name == "Component.onCompleted")
            return hover_result(d, member_doc("Component.onCompleted"), m.pos, m.kend);
        if (m.kind == Member::handler) {
            const Type* t = type_of(el->base);
            std::string s = lower_first(m.name.substr(2));
            if (t && t->signal(s)) {
                std::string sig = s + "(" + *t->signal(s) + ")";
                auto it = docs().elements.find(el->base);
                std::string words = phrase(it != docs().elements.end() ? it->second.second : "", s);
                std::string bare = words;
                bare.erase(std::remove(bare.begin(), bare.end(), '`'), bare.end());
                std::string more = !words.empty() && bare != sig ? ": " + words : "";
                return hover_result(
                    d, "```rui\n" + el->type + " { " + m.name + ": … }\n```\n\nruns on `" + sig + "`" + more, m.pos,
                    m.kend);
            }
            if (s.size() > 7 && s.compare(s.size() - 7, 7, "Changed") == 0)
                return hover_result(d, "runs after `" + s.substr(0, s.size() - 7) + "` changes", m.pos, m.kend);
            if (s == "pressedOutside")
                return hover_result(d, phrase(docs().general, "onPressedOutside"), m.pos, m.kend);
            return J(nullptr);
        }
        for (const Member& c : el->members)
            if (c.kind == Member::custom && c.name == m.name)
                return hover_result(d, custom_doc(el, c, nullptr), m.pos, m.kend);
        return hover_result(d, prop_doc(el->base, m.name), m.pos, m.kend);
    }
    if (m.kind == Member::id)
        return hover_result(d, "id `" + w.text + "`: a " + el->type, w.s, w.e);
    auto chain = chain_at(d->text, w.e);
    if (chain.empty())
        return J(nullptr);
    Meaning r = resolve_chain(o, el, &m, words_of(chain));
    std::string text = describe(r);
    if (r.kind == Meaning::id) {
        size_t at2 = text.find("$LINE");
        if (at2 != std::string::npos)
            text.replace(at2, 5, std::to_string(static_cast<long>(to_pos(d, r.el->pos)["line"].num()) + 1));
    }
    return hover_result(d, text, w.s, w.e);
}

J definition(Doc* d, const J& pos) {
    Outline* o = outline_of(d);
    if (!o)
        return J(nullptr);
    int off = to_off(d, pos);
    Word w = word_at(d->text, off);
    if (!w)
        return J(nullptr);
    auto loc = [&](int s, int e) { return J::object({{"uri", J(d->uri)}, {"range", range(d, s, e)}}); };
    auto there = [&](const Name& sub) {
        return J::object({{"uri", J(sub.comp->uri)}, {"range", range(sub.comp->d, sub.member->pos, sub.member->kend)}});
    };
    for (Element* t : o->all) {
        if (off < t->pos || off > t->pos + static_cast<int>(t->type.size()) || !t->comp)
            continue;
        Element* r = t->comp->o->root;
        return J::object({{"uri", J(t->comp->uri)},
                          {"range", range(t->comp->d, r->pos, r->pos + static_cast<int>(r->type.size()))}});
    }
    for (const Use& u : o->uses) {
        if (off < u.pos || off > u.end)
            continue;
        std::string dir = use_dir(file_of(d->uri), u);
        if (!dir.empty()) {
            J zero = J::object({{"line", J(0)}, {"character", J(0)}});
            return J::object({{"uri", J("file://" + dir)}, {"range", J::object({{"start", zero}, {"end", zero}})}});
        }
    }
    Element* el = element_at(o, off);
    if (!el)
        return J(nullptr);
    At at = member_at(el, off);
    if (at.m && !at.value) {
        for (const Member& c : el->members)
            if ((c.kind == Member::custom || c.kind == Member::function) && c.name == at.m->name)
                return loc(c.pos, c.kend);
        if (el->comp) {
            Names own = comp_names(el->comp);
            if (const Name* mine = own.get(at.m->name))
                return there(*mine);
        }
        return J(nullptr);
    }
    if (!at.m || at.m->kind == Member::id)
        return el->id == w.text ? loc(el->idPos, el->idPos + static_cast<int>(el->id.size())) : J(nullptr);
    Meaning r = resolve_chain(o, el, at.m, words_of(chain_at(d->text, w.e)));
    if (!r)
        return J(nullptr);
    if (r.kind == Meaning::id)
        return loc(r.el->idPos, r.el->idPos + static_cast<int>(w.text.size()));
    if (r.kind == Meaning::name && r.sub.member)
        return r.sub.comp ? there(r.sub) : loc(r.sub.member->pos, r.sub.member->kend);
    if (r.kind == Meaning::element)
        return loc(r.el->pos, r.el->pos + static_cast<int>(r.el->type.size()));
    return J(nullptr);
}

bool id_uses(Doc* d, const J& pos, IdUses& out) {
    Outline* o = outline_of(d);
    if (!o)
        return false;
    int off = to_off(d, pos);
    Word w = word_at(d->text, off);
    if (!w || !o->id(w.text))
        return false;
    Element* target = o->id(w.text);
    int p = w.s;
    while (p > 0 && std::isspace(static_cast<unsigned char>(d->text[static_cast<size_t>(p - 1)])))
        p--;
    if (p > 0 && d->text[static_cast<size_t>(p - 1)] == '.'
        && !(p >= 3 && d->text.compare(static_cast<size_t>(p - 3), 3, "...") == 0))
        return false;
    out = IdUses{w.text, w.s, w.e, {}};
    out.uses.push_back({{target->idPos, target->idPos + static_cast<int>(w.text.size())}, true});
    for (const Range& r : code_ranges(o))
        for (const Tok& t : lex(d->text, r.s, r.e))
            if (t.t == "id" && !t.dot && t.text == w.text)
                out.uses.push_back({{t.s, t.e}, false});
    return true;
}

namespace {

enum K {
    k_method = 2,
    k_function = 3,
    k_field = 5,
    k_variable = 6,
    k_class = 7,
    k_property = 10,
    k_value = 12,
    k_keyword = 14,
    k_snippet = 15,
    k_event = 23
};

J item(const std::string& label, int kind) {
    return J::object({{"label", J(label)}, {"kind", J(kind)}});
}
J markdown(const std::string& v) {
    return v.empty() ? J() : J::object({{"kind", J("markdown")}, {"value", J(v)}});
}

bool in_string_or_comment(const std::string& text) {
    char q = 0;
    for (size_t k = 0; k < text.size(); k++) {
        char c = text[k];
        if (q) {
            if (c == '\\')
                k++;
            else if (c == q)
                q = 0;
            else if (q == '`' && c == '$' && k + 1 < text.size() && text[k + 1] == '{') {
                size_t close = text.find('}', k);
                if (close == std::string::npos)
                    return false;
                k = close;
            }
            continue;
        }
        if (c == '/' && k + 1 < text.size() && text[k + 1] == '/') {
            size_t nl = text.find('\n', k);
            if (nl == std::string::npos)
                return true;
            k = nl;
            continue;
        }
        if (c == '/' && k + 1 < text.size() && text[k + 1] == '*') {
            size_t close = text.find("*/", k + 2);
            if (close == std::string::npos)
                return true;
            k = close + 1;
            continue;
        }
        if (c == '"' || c == '\'' || c == '`')
            q = c;
    }
    return q != 0;
}

J key_items(Doc* d, Outline* o, Element* el, const std::string& prefix, int off) {
    const Type* t = type_of(el->base);
    const J where = range(d, off - static_cast<int>(prefix.size()), off);
    auto edit = [&](const std::string& text) {
        J e = J::object();
        e.set("range", where);
        e.set("newText", J(text));
        return e;
    };
    J items = J::array();
    std::vector<std::string> have;
    for (const Member& m : el->members)
        if (m.kind != Member::partial)
            have.push_back(m.name);
    auto has = [&](const std::string& n) { return std::find(have.begin(), have.end(), n) != have.end(); };
    auto key = [&](const std::string& name, int kind, const std::string& doc, const std::string& sort,
                   const J& detail) {
        J it = item(name, kind);
        it.set("filterText", J(name));
        it.set("sortText", J(sort + name));
        it.set("detail", detail);
        it.set("textEdit", edit(snippets ? name + ": $0" : name + ": "));
        it.set("insertTextFormat", J(snippets ? 2 : 1));
        it.set("documentation", markdown(doc));
        items.push(it);
    };
    if (t) {
        for (const Prop& p : t->props)
            if (!has(p.name))
                key(p.name, k_property, prop_doc(el->base, p.name), "1", p.has_default ? J(p.default_json) : J());
        if (el->comp)
            for (auto& [name, v] : comp_names(el->comp)) {
                if (v.kind != Name::custom)
                    continue;
                if (!has(name))
                    key(name, k_property, custom_doc(el, *v.member, v.comp), "0",
                        J(v.member->ptype.empty() ? std::string("var") : v.member->ptype));
                std::string h = "on" + upper_first(name) + "Changed";
                if (!has(h))
                    key(h, k_event, "runs after `" + name + "` changes", "3", J());
            }
        for (auto& [s, params] : t->signals) {
            std::string h = "on" + upper_first(s);
            if (!has(h))
                key(h, k_event, "", "2", J(s + "(" + params + ")"));
        }
        for (const std::string& ob : t->objects)
            if (!has(ob))
                key(ob, k_field, "an element: made once per model entry", "1", J());
        for (const Prop& p : t->props) {
            if (p.name.find('.') != std::string::npos)
                continue;
            std::string h = "on" + upper_first(p.name) + "Changed";
            if (!has(h))
                key(h, k_event, "runs after `" + p.name + "` changes", "4", J());
        }
    }
    for (const Member& m : el->members) {
        if (m.kind != Member::custom)
            continue;
        std::string h = "on" + upper_first(m.name) + "Changed";
        if (!has(h))
            key(h, k_event, "runs after `" + m.name + "` changes", "3", J());
    }
    if (!has("id"))
        key("id", k_keyword, member_doc("id:"), "0", J());
    if (!has("Component.onCompleted"))
        key("Component.onCompleted", k_event, member_doc("Component.onCompleted"), "3", J());
    if (prefix.find('.') == std::string::npos) {
        auto kw = [&](const std::string& label, const std::string& body, const std::string& plain) {
            J it = item(label, k_keyword);
            it.set("sortText", J("5" + label));
            it.set("textEdit", edit(snippets ? body : plain));
            it.set("insertTextFormat", J(snippets ? 2 : 1));
            items.push(it);
        };
        kw("property", "property ${1:var} ${2:name}: $0", "property var ");
        kw("function", "function ${1:name}($2) {\n\t$0\n}", "function ");
        auto element = [&](const std::string& type, const std::string& detail, const std::string& doc) {
            J it = item(type, k_class);
            it.set("sortText", J("6" + type));
            it.set("filterText", J(type));
            it.set("detail", J(detail));
            it.set("textEdit", edit(snippets ? type + " {\n\t$0\n}" : type + " { }"));
            it.set("insertTextFormat", J(snippets ? 2 : 1));
            it.set("documentation", markdown(doc));
            items.push(it);
        };
        std::string file = file_of(d->uri);
        for (const std::string& type : type_names()) {
            if (type == "Dock" || (type == "Slot" && !is_component_file(file)))
                continue;
            element(type, "element", element_doc(type));
        }
        std::vector<std::string> seen;
        std::vector<std::pair<std::string, std::string>> dirs{{file.empty() ? "" : dirname(file), ""}};
        for (const Use& u : o->uses)
            dirs.emplace_back(use_dir(file, u), u.has_as ? u.as : "");
        for (auto& [dir, as] : dirs) {
            if (dir.empty())
                continue;
            for (const std::string& name : components_in(dir)) {
                std::string type = as.empty() ? name : as + "." + name;
                if (std::find(seen.begin(), seen.end(), type) != seen.end() || dir + "/" + name + ".rui" == file)
                    continue;
                seen.push_back(type);
                element(type, "component: " + home_short(dir + "/" + name + ".rui"), "");
            }
        }
    }
    return items;
}

J names_items(const Names& names, const std::string& sort,
              std::function<J(const std::string&, const Name&)> detail_of = nullptr) {
    J items = J::array();
    for (auto& [name, n] : names) {
        int kind = n.kind == Name::method || n.kind == Name::function ? k_method
            : n.kind == Name::group                                   ? k_field
                                                                      : k_property;
        J it = item(name, kind);
        it.set("sortText", J(sort + name));
        it.set("detail", detail_of ? detail_of(name, n) : J());
        items.push(it);
    }
    return items;
}

J global_items(const std::string& name) {
    J items = J::array();
    for (const GlobalMember& m : global_members(name)) {
        J it = item(m.name, m.function ? k_method : k_property);
        it.set("detail", J(m.detail));
        auto doc = docs().globals.find(name + "." + m.name);
        it.set("documentation", markdown(doc != docs().globals.end() ? doc->second : ""));
        items.push(it);
    }
    return items;
}

std::vector<std::string> dotted_chain(const std::string& t) {
    auto ws = [](char c) { return std::isspace(static_cast<unsigned char>(c)) != 0; };
    auto start = [](char c) { return std::isalpha(static_cast<unsigned char>(c)) || c == '_' || c == '$'; };
    long k = static_cast<long>(t.size());
    auto at = [&](long i) { return i >= 0 && i < static_cast<long>(t.size()) ? t[static_cast<size_t>(i)] : '\0'; };
    while (k > 0 && wchar(at(k - 1)))
        k--;
    auto separator = [&](long i) -> long {
        while (i > 0 && ws(at(i - 1)))
            i--;
        if (at(i - 1) != '.')
            return -1;
        i--;
        if (at(i - 1) == '?')
            i--;
        while (i > 0 && ws(at(i - 1)))
            i--;
        return i;
    };
    auto name = [&](long i) -> long {
        long b = i;
        while (b > 0 && wchar(at(b - 1)))
            b--;
        while (b < i && !start(at(b)))
            b++;
        return b < i ? b : -1;
    };
    long e = separator(k);
    if (e < 0)
        return {};
    std::vector<std::string> out;
    for (;;) {
        long s = name(e);
        if (s < 0)
            break;
        out.insert(out.begin(), t.substr(static_cast<size_t>(s), static_cast<size_t>(e - s)));
        if (s > 0 && wchar(at(s - 1)))
            break;
        long e2 = separator(s);
        if (e2 < 0 || name(e2) < 0)
            break;
        e = e2;
    }
    return out;
}

J value_items(Doc* d, Outline* o, Element* el, Member* m, int off) {
    std::string before =
        d->text.substr(static_cast<size_t>(std::max(0, off - 200)), static_cast<size_t>(off - std::max(0, off - 200)));
    std::vector<std::string> chain = dotted_chain(before);
    if (!chain.empty()) {
        Meaning r = resolve_chain(o, el, m, chain);
        if (!r)
            return J::array();
        if (r.kind == Meaning::id || r.kind == Meaning::element) {
            Names names = element_names(r.el);
            names.set("parent", Name{Name::element});
            const Type* t = type_of(r.el->base);
            return names_items(names, "1", [&](const std::string&, const Name& n) {
                if (n.kind == Name::prop) {
                    const Prop* p = t ? t->prop(n.prop_name) : nullptr;
                    return p && p->has_default ? J(p->default_json) : J();
                }
                const char* k[] = {"prop", "group", "method", "model", "custom", "function", "element"};
                return J(k[n.kind]);
            });
        }
        if (r.kind == Meaning::name && r.sub.kind == Name::group) {
            J items = J::array();
            if (const Type* t = type_of(r.el->base))
                for (const Prop& p : t->props)
                    if (p.name.rfind(r.word + ".", 0) == 0) {
                        J it = item(p.name.substr(r.word.size() + 1), k_property);
                        it.set("detail", p.has_default ? J(p.default_json) : J());
                        items.push(it);
                    }
            return items;
        }
        if (r.kind == Meaning::global)
            return global_items(r.word);
        return J::array();
    }
    J items = J::array();
    for (auto& [id, target] : o->ids) {
        J it = item(id, k_variable);
        it.set("sortText", J("0" + id));
        it.set("detail", J(target->type));
        items.push(it);
    }
    if (el->parent) {
        J it = item("parent", k_variable);
        it.set("sortText", J("1parent"));
        it.set("detail", J(el->parent->type));
        items.push(it);
    }
    std::vector<std::string> seen;
    for (const J& x : items.a)
        seen.push_back(x["label"].text());
    std::pair<Element*, const char*> scopes[] = {{el, "1"}, {delegate_root(el), "2"}, {o->root, "3"}};
    for (auto& [scope, sort] : scopes) {
        if (!scope)
            continue;
        for (const J& x : names_items(element_names(scope), sort).a)
            if (std::find(seen.begin(), seen.end(), x["label"].text()) == seen.end())
                seen.push_back(x["label"].text()), items.push(x);
    }
    std::string params = m->kind == Member::handler ? signal_params_of(el, m->name)
        : m->kind == Member::function               ? m->params
                                                    : "";
    size_t a = 0;
    while (a <= params.size() && !params.empty()) {
        size_t c = params.find(',', a);
        std::string p = params.substr(a, c == std::string::npos ? std::string::npos : c - a);
        size_t f = p.find_first_not_of(" \t\n");
        p = f == std::string::npos ? "" : p.substr(f);
        size_t cut = p.find_first_of("= \t\n");
        if (cut != std::string::npos)
            p = p.substr(0, cut);
        if (!p.empty()) {
            J it = item(p, k_variable);
            it.set("sortText", J("0" + p));
            it.set("detail", J("parameter"));
            items.push(it);
        }
        if (c == std::string::npos)
            break;
        a = c + 1;
    }
    for (const char* g : {"theme", "rex", "i18n", "conf", "qsTr", "rgba", "console"}) {
        std::string gs(g);
        J it = item(gs, gs == "qsTr" || gs == "rgba" ? k_function : k_variable);
        it.set("sortText", J("4" + gs));
        auto doc = docs().globals.find(gs);
        it.set("documentation", markdown(doc != docs().globals.end() ? doc->second : ""));
        items.push(it);
    }
    for (const char* b : k_builtins) {
        J it = item(b, k_variable);
        it.set("sortText", J(std::string("5") + b));
        items.push(it);
    }
    for (const char* k : k_keywords) {
        J it = item(k, k_keyword);
        it.set("sortText", J(std::string("6") + k));
        items.push(it);
    }
    return items;
}

}

J completion(Doc* d, const J& pos) {
    Outline* o = outline_of(d);
    if (!o)
        return J::array();
    int off = to_off(d, pos);
    Element* el = element_at(o, off);
    if (!el)
        return J::array();
    At at = member_at(el, off);
    if (at.m && at.value) {
        int from = at.m->colon >= 0 ? at.m->colon : at.m->vpos;
        if (in_string_or_comment(
                d->text.substr(static_cast<size_t>(from), static_cast<size_t>(std::max(0, off - from))))) {
            J items = J::array();
            rx::schema::Elem e;
            rx::schema::Prop pr;
            if (rx::schema::elem_of(el->type, &e) && rx::schema::prop_of(at.m->name, &pr))
                for (const auto& en : rx::schema::k_enums) {
                    if (en.elem != e || en.prop != pr)
                        continue;
                    std::string_view v = en.values;
                    for (size_t a = 0; a <= v.size();) {
                        size_t b = v.find('|', a);
                        std::string one(v.substr(a, b == std::string_view::npos ? std::string_view::npos : b - a));
                        if (!one.empty() && one.back() != '*')
                            items.push(item(one, k_value));
                        if (b == std::string_view::npos)
                            break;
                        a = b + 1;
                    }
                }
            return items;
        }
        return value_items(d, o, el, at.m, off);
    }
    size_t ls = 0;
    if (off > 0) {
        size_t p = d->text.rfind('\n', static_cast<size_t>(off - 1));
        ls = p == std::string::npos ? 0 : p + 1;
    }
    std::string line = d->text.substr(ls, static_cast<size_t>(off) - ls);
    size_t p = line.size();
    while (p > 0 && (wchar(line[p - 1]) || line[p - 1] == '.'))
        p--;
    std::string prefix = line.substr(p);
    size_t cut = line.find_last_of(";{,");
    std::string rest = cut == std::string::npos ? line : line.substr(cut + 1);
    size_t q = 0;
    while (q < rest.size() && std::isspace(static_cast<unsigned char>(rest[q])))
        q++;
    if (rest.compare(q, 8, "readonly") == 0 && q + 8 < rest.size()
        && std::isspace(static_cast<unsigned char>(rest[q + 8]))) {
        q += 8;
        while (q < rest.size() && std::isspace(static_cast<unsigned char>(rest[q])))
            q++;
    }
    for (; q < rest.size(); q++)
        if (!wchar(rest[q]) && rest[q] != '.')
            return J::array();
    return key_items(d, o, el, prefix, off);
}

J signature_help(Doc* d, const J& pos) {
    const std::string& t = d->text;
    int off = std::min(to_off(d, pos), static_cast<int>(t.size()));
    int depth = 0, commas = 0, open = -1;
    for (int i = off - 1; i >= 0 && t[static_cast<size_t>(i)] != '\n'; i--) {
        const char c = t[static_cast<size_t>(i)];
        if (c == ')' || c == ']' || c == '}')
            depth++;
        else if (c == '[' || c == '{') {
            if (!depth)
                break;
            depth--;
        } else if (c == '(') {
            if (!depth) {
                open = i;
                break;
            }
            depth--;
        } else if (c == ',' && !depth)
            commas++;
    }
    if (open <= 0)
        return J(nullptr);
    int e = open;
    while (e > 0 && std::isspace(static_cast<unsigned char>(t[static_cast<size_t>(e - 1)])))
        e--;
    int s = e;
    while (s > 0 && wchar(t[static_cast<size_t>(s - 1)]))
        s--;
    if (s == e)
        return J(nullptr);
    const std::string name = t.substr(static_cast<size_t>(s), static_cast<size_t>(e - s));
    Outline* o = outline_of(d);
    if (!o)
        return J(nullptr);
    const Member* found = nullptr;
    std::function<void(Element*)> look = [&](Element* el) {
        if (found || !el)
            return;
        for (const Member& m : el->members)
            if (m.kind == Member::function && m.name == name) {
                found = &m;
                return;
            }
        for (Element* c : el->children)
            look(c);
    };
    look(o->root);
    if (!found)
        return J(nullptr);
    J params = J::array();
    std::stringstream ss(found->params);
    for (std::string part; std::getline(ss, part, ',');) {
        size_t a = part.find_first_not_of(" \t\n");
        if (a != std::string::npos)
            params.push(J::object({{"label", J(part.substr(a))}}));
    }
    J sig = J::object({{"label", J(name + "(" + found->params + ")")}, {"parameters", params}});
    return J::object({{"signatures", J::array({sig})}, {"activeSignature", J(0)}, {"activeParameter", J(commas)}});
}

J symbols(Doc* d) {
    Outline* o = outline_of(d);
    if (!o)
        return J::array();
    std::function<J(Element*)> sym = [&](Element* el) {
        J kids = J::array();
        for (const Member& m : el->members) {
            if (m.kind != Member::custom && m.kind != Member::function)
                continue;
            kids.push(J::object({{"name", J(m.name)},
                                 {"kind", J(m.kind == Member::function ? 12 : 7)},
                                 {"detail", J(m.kind == Member::function ? "(" + m.params + ")" : m.ptype)},
                                 {"range", range(d, m.pos, std::max(m.vend, m.kend))},
                                 {"selectionRange", range(d, m.pos, m.kend)}}));
        }
        for (Element* c : el->children)
            kids.push(sym(c));
        int tlen = static_cast<int>(el->type.size());
        return J::object({{"name", J(el->type + (el->id.empty() ? "" : " " + el->id))},
                          {"detail", J(el->delegate)},
                          {"kind", J(5)},
                          {"range", range(d, el->pos, std::max(el->end, el->pos + tlen))},
                          {"selectionRange", range(d, el->pos, el->pos + tlen)},
                          {"children", kids}});
    };
    return J::array({sym(o->root)});
}

}
