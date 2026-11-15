// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "model.h"

#include <sys/stat.h>
#include <time.h>

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <functional>
#include <regex>

#include "engine/core/doc.h"
#include "engine/core/globals.h"
#include "gen/rx_props.h"

namespace rui_ls {

namespace sch = rx::schema;
namespace fs = std::filesystem;

std::string g_repo;

const Type* type_of(const std::string& name) {
    static std::map<std::string, Type> types = [] {
        std::map<std::string, Type> out;
        for (int e = 0; e < static_cast<int>(sch::Elem::count_); e++) {
            Type t;
            t.name = std::string(sch::k_elems[e]);
            sch::Span ps = sch::k_elem_props[e];
            for (uint32_t k = ps.first; k < ps.first + ps.count; k++) {
                const sch::PropDef& d = sch::k_prop_defs[k];
                Prop p;
                p.name = std::string(sch::k_props[static_cast<int>(d.prop)].name);
                p.has_default = d.def != sch::Def::unset;
                p.default_json = std::string(d.json);
                p.js = d.js;
                t.props.push_back(p);
            }
            sch::Span ss = sch::k_elem_signals[e];
            for (uint32_t k = ss.first; k < ss.first + ss.count; k++)
                t.signals.emplace_back(std::string(sch::k_signals[k].name), std::string(sch::k_signals[k].params));
            sch::Span ms = sch::k_elem_methods[e];
            for (uint32_t k = ms.first; k < ms.first + ms.count; k++)
                t.methods.emplace_back(sch::k_methods[k]);
            sch::Span os = sch::k_elem_objects[e];
            for (uint32_t k = os.first; k < os.first + os.count; k++)
                t.objects.emplace_back(sch::k_objects[k]);
            out[t.name] = t;
        }
        return out;
    }();
    auto it = types.find(name);
    return it == types.end() ? nullptr : &it->second;
}

std::vector<std::string> type_names() {
    std::vector<std::string> out;
    for (int e = 0; e < static_cast<int>(sch::Elem::count_); e++)
        out.emplace_back(sch::k_elems[e]);
    return out;
}

const Prop* Type::prop(const std::string& n) const {
    for (const Prop& p : props)
        if (p.name == n)
            return &p;
    return nullptr;
}
const std::string* Type::signal(const std::string& n) const {
    for (auto& [s, ps] : signals)
        if (s == n)
            return &ps;
    return nullptr;
}
bool Type::has_object(const std::string& n) const {
    for (auto& o : objects)
        if (o == n)
            return true;
    return false;
}

bool signal_params(const Type* t, const std::string& handler, const std::string& type, std::string& params,
                   std::string& why) {
    params.clear();
    if (handler == "Component.onCompleted" || handler == "Component.onDestruction")
        return true;
    if (handler.size() < 3)
        return why = type + " has no signal " + handler, false;
    std::string s = std::string(1, static_cast<char>(std::tolower(handler[2]))) + handler.substr(3);
    if (const std::string* p = t ? t->signal(s) : nullptr)
        return params = *p, true;
    if (s == "pressedOutside" && t && t->prop("opacity"))
        return true;
    if (s == "filesDropped" && t && t->prop("dropFiles"))
        return params = "paths, copy", true;
    if (s.size() > 7 && s.compare(s.size() - 7, 7, "Changed") == 0)
        return params = "initial", true;
    why = type + " has no signal " + s;
    return false;
}

namespace {
std::string read_file(const std::string& p) {
    FILE* f = std::fopen(p.c_str(), "rb");
    if (!f)
        return "";
    std::string out;
    char b[65536];
    size_t n;
    while ((n = std::fread(b, 1, sizeof b, f)) > 0)
        out.append(b, n);
    std::fclose(f);
    return out;
}
constexpr double k_fresh = 0.5;
double clock_s() {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return static_cast<double>(t.tv_sec) + static_cast<double>(t.tv_nsec) / 1e9;
}
double mtime(const std::string& p) {
    static std::map<std::string, std::pair<double, double>> seen;
    double now = clock_s();
    auto it = seen.find(p);
    if (it != seen.end() && now - it->second.first < k_fresh)
        return it->second.second;
    struct stat st;
    double t = stat(p.c_str(), &st) != 0
        ? 0
        : static_cast<double>(st.st_mtimespec.tv_sec) + static_cast<double>(st.st_mtimespec.tv_nsec) / 1e9;
    seen[p] = {now, t};
    return t;
}
std::string trim(const std::string& s) {
    size_t a = s.find_first_not_of(" \t"), b = s.find_last_not_of(" \t\r");
    return a == std::string::npos ? "" : s.substr(a, b - a + 1);
}
}

const Docs& docs() {
    static Docs d;
    static double stamp = -1;
    std::string readme = g_repo + "/README.md";
    double now = mtime(readme);
    if (now == stamp)
        return d;
    stamp = now;
    static size_t reads = 0;
    d = Docs{};
    d.serial = ++reads;
    std::string text = read_file(readme);
    std::string section, general;
    const std::vector<std::string>& gl = global_names();
    auto is_global = [&](const std::string& n) {
        for (const std::string& g : gl)
            if (g == n)
                return true;
        return false;
    };
    std::regex row(R"(^\|\s*(.+?)\s*\|\s*(.*?)\s*\|\s*(.*?)\s*\|\s*$)"), two(R"(^\|\s*(.+?)\s*\|\s*(.*?)\s*\|\s*$)"),
        tick("`(\\w+)`");
    std::regex chain(R"(`([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*))");
    size_t at = 0;
    while (at <= text.size()) {
        size_t nl = text.find('\n', at);
        std::string l = text.substr(at, nl == std::string::npos ? std::string::npos : nl - at);
        at = nl == std::string::npos ? text.size() + 1 : nl + 1;
        if (l.rfind("## ", 0) == 0 || l.rfind("### ", 0) == 0)
            section = l.substr(l.find(' ') + 1);
        std::smatch m;
        bool is_row = std::regex_match(l, m, row);
        std::smatch m2;
        bool is_two = !is_row && std::regex_match(l, m2, two);
        if (section == "The Dock element" && is_two && m2[1].str().rfind("`", 0) == 0) {
            auto& e = d.elements["Dock"];
            e.first +=
                (e.first.empty() ? "" : ", ") + m2[1].str() + (m2[2].str().empty() ? "" : " (" + m2[2].str() + ")");
        } else if (section == "The Dock element" && l.rfind("|", 0) != 0 && !trim(l).empty()
                   && l.rfind("### ", 0) != 0) {
            d.elements["Dock"].second += " " + l;
        } else if (section == "Elements" && is_row && m[1].str().rfind("`", 0) == 0) {
            std::string cell = m[1];
            for (auto it = std::sregex_iterator(cell.begin(), cell.end(), tick); it != std::sregex_iterator(); ++it)
                d.elements[(*it)[1]] = {m[2], m[3]};
        } else if (section == "Docks" && (is_row || is_two) && (is_row ? m : m2)[1].str().rfind("`", 0) == 0) {
            const std::smatch& r = is_row ? m : m2;
            std::string member = r[1];
            member.erase(std::remove(member.begin(), member.end(), '`'), member.end());
            d.members.emplace_back(member, r[2]);
        } else if (section == "Elements" && l.rfind("|", 0) != 0 && !trim(l).empty()) {
            general += (general.empty() ? "" : " ") + l;
        }
        if ((is_row || is_two) && (is_row ? m : m2)[1].str().rfind("`", 0) == 0) {
            const std::smatch& r = is_row ? m : m2;
            std::string cell = r[1], words = r[2];
            for (auto it = std::sregex_iterator(cell.begin(), cell.end(), chain); it != std::sregex_iterator(); ++it) {
                std::string name = (*it)[1];
                std::string head = name.substr(0, name.find('.'));
                if (!is_global(head) || d.globals.count(name))
                    continue;
                d.globals[name] = words;
            }
        }
    }
    std::string squashed;
    bool sp = false;
    for (char c : general) {
        bool w = c == ' ' || c == '\t' || c == '\n' || c == '\r';
        if (w) {
            if (!sp)
                squashed += ' ';
            sp = true;
        } else
            squashed += c, sp = false;
    }
    d.general = squashed;
    return d;
}

std::string phrase(const std::string& text, const std::string& name) {
    if (text.empty())
        return "";
    for (const std::string& open : {"`" + name + "`", "`" + name + ":", "`" + name + "("}) {
        for (size_t at = text.find(open); at != std::string::npos; at = text.find(open, at + 1)) {
            int depth = 0;
            size_t k = text.find('`', at + 1);
            k = k == std::string::npos ? text.size() : k + 1;
            for (; k < text.size(); k++) {
                char c = text[k];
                if (c == '(')
                    depth++;
                else if (c == ')') {
                    if (depth == 0)
                        break;
                    depth--;
                } else if (depth == 0
                           && ((c == ',' || c == ';' || c == '.') && k + 1 < text.size() && text[k + 1] == ' '))
                    break;
                else if (depth == 0 && text.compare(k, 6, " and `") == 0)
                    break;
            }
            std::string words = trim(text.substr(at, k - at));
            std::string bare = words;
            bare.erase(std::remove(bare.begin(), bare.end(), '`'), bare.end());
            if (bare.size() > name.size() + 3)
                return words;
        }
    }
    return "";
}

std::string member_doc(const std::string& member) {
    for (auto& [m, text] : docs().members)
        if (m.rfind(member, 0) == 0)
            return "`" + m + "`: " + text;
    return "";
}

namespace {
using EDoc = rx::engine::core::Doc;
using rx::engine::core::Sink;
using rx::engine::vm::Value;
struct Quiet final : Sink {
    void create(uint32_t, std::string_view, uint32_t) override {}
    void set(EDoc&, uint32_t, std::string_view, Value) override {}
    void call(uint32_t, std::string_view, std::string_view) override {}
    void send(uint32_t, std::string_view) override {}
    void log(std::string_view, std::string_view) override {}
    bool source(std::string_view, std::string_view&) override { return false; }
    Value api(EDoc&, std::string_view, std::string_view, const Value*, uint32_t) override { return Value::null(); }
};
EDoc& engine_doc() {
    static Quiet q;
    static EDoc d(q);
    static bool loaded = false;
    if (!loaded)
        loaded = true, d.load("Dock { }", "rui-ls.rui", "");
    return d;
}
J eval_json(const std::string& expr) {
    J r = J::parse(engine_doc().debug("eval", J::array({J("JSON.stringify(" + expr + ")")}).dump()));
    std::string t = r["text"].text();
    J v = J::parse(t);
    if (v.is_str())
        v = J::parse(v.str());
    return v;
}
}

const std::vector<std::string>& global_names() {
    static std::vector<std::string> names = [] {
        std::vector<std::string> out;
        for (const J& k : eval_json("Object.keys(globalThis)").a)
            out.push_back(k.text());
        for (const char* extra : {"qsTr", "rgba", "console"})
            if (std::find(out.begin(), out.end(), extra) == out.end())
                out.emplace_back(extra);
        return out;
    }();
    return names;
}

const std::vector<GlobalMember>& global_members(const std::string& name) {
    static std::map<std::string, std::vector<GlobalMember>> cache;
    auto it = cache.find(name);
    if (it != cache.end())
        return it->second;
    std::vector<GlobalMember> out;
    for (char c : name)
        if (!(std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '$'))
            return cache[name] = out;
    J keys = eval_json("typeof " + name + " === 'object' || typeof " + name + " === 'function' ? Object.keys(" + name
                       + ").map((k) => [k, typeof " + name + "[k], typeof " + name
                       + "[k] === 'function' ? '' : JSON.stringify(" + name + "[k])]) : []");
    for (const J& k : keys.a) {
        std::string key = k[0].text();
        if (key.rfind("__", 0) == 0)
            continue;
        out.push_back(GlobalMember{key, k[1] == "function", k[1] == "function" ? "function" : k[2].text()});
    }
    for (uint32_t i = 0; i < rx::engine::core::globals::method_count(); i++) {
        const char *g, *m;
        uint32_t len;
        rx::engine::core::globals::method_at(i, g, m, len);
        if (name != g)
            continue;
        bool have = false;
        for (auto& x : out)
            have = have || x.name == m;
        if (!have)
            out.push_back(GlobalMember{m, true, "function"});
    }
    return cache[name] = out;
}

std::string expand(const std::string& p) {
    if (p == "rexui")
        return g_repo + "/src/ui/kit";
    if (p.rfind("rexui/", 0) == 0)
        return g_repo + "/src/ui/kit" + p.substr(5);
    if (p == "rexshared")
        return g_repo + "/distros/shared";
    if (p.rfind("rexshared/", 0) == 0)
        return g_repo + "/distros/shared" + p.substr(9);
    if (p == "~" || p.rfind("~/", 0) == 0) {
        const char* h = std::getenv("HOME");
        return std::string(h ? h : "") + p.substr(1);
    }
    return p;
}
std::string resolve_path(const std::string& p) {
    std::string s = fs::path(p).lexically_normal().string();
    while (s.size() > 1 && s.back() == '/')
        s.pop_back();
    return s;
}
std::string dirname(const std::string& f) {
    size_t s = f.rfind('/');
    return s == std::string::npos ? "." : s == 0 ? "/" : f.substr(0, s);
}
std::string basename(const std::string& f) {
    size_t s = f.rfind('/');
    return s == std::string::npos ? f : f.substr(s + 1);
}
bool is_component_file(const std::string& file) {
    std::string b = basename(file);
    return !file.empty() && !b.empty() && b[0] >= 'A' && b[0] <= 'Z';
}

std::string use_dir(const std::string& file, const Use& u) {
    if (u.path == "rexui" || u.path == "rexshared")
        return resolve_path(expand(u.path));
    if (u.path.rfind("/", 0) == 0 || u.path.rfind("~", 0) == 0)
        return resolve_path(expand(u.path));
    if (file.empty())
        return "";
    return resolve_path(dirname(file) + "/" + u.path);
}

std::vector<std::string> component_dirs(const std::string& file, const Outline& o, const std::string& type) {
    size_t dot = type.rfind('.');
    std::string ns = dot == std::string::npos ? "" : type.substr(0, dot);
    std::vector<std::string> own;
    for (const Use& u : o.uses)
        if ((u.has_as ? u.as : "") == ns) {
            std::string d = use_dir(file, u);
            if (!d.empty())
                own.push_back(d);
        }
    if (!ns.empty())
        return own;
    std::vector<std::string> out;
    if (!file.empty())
        out.push_back(dirname(file));
    out.insert(out.end(), own.begin(), own.end());
    return out;
}

long g_generation = 0;
namespace {
struct Cached {
    double stamp;
    long serial;
    std::unique_ptr<Component> comp;
};
std::map<std::string, Cached> comp_cache;
}

Component* load_component(const std::string& p) {
    std::string uri = "file://" + p;
    Doc* od = doc(uri);
    double stamp = od ? 0 : mtime(p);
    if (!od && stamp == 0)
        return nullptr;
    auto it = comp_cache.find(p);
    if (it != comp_cache.end() && it->second.serial == (od ? od->serial : 0) && it->second.stamp == stamp)
        return it->second.comp.get();
    auto c = std::make_unique<Component>();
    c->name = basename(p).substr(0, basename(p).size() - 4);
    c->path = p, c->uri = uri;
    if (od)
        c->d = od;
    else {
        c->own = std::make_unique<Doc>();
        c->own->uri = uri;
        c->own->text = read_file(p);
        c->own->starts.push_back(0);
        for (size_t k = 0; k < c->own->text.size(); k++)
            if (c->own->text[k] == '\n')
                c->own->starts.push_back(static_cast<int>(k) + 1);
        c->d = c->own.get();
    }
    c->own_o = outline(c->d->text);
    c->o = c->own_o.get();
    Component* raw = c.get();
    comp_cache[p] = Cached{stamp, od ? od->serial : 0, std::move(c)};
    return raw;
}

Component* find_component(const std::string& file, const Outline& o, const std::string& type) {
    std::string name = type.substr(type.rfind('.') == std::string::npos ? 0 : type.rfind('.') + 1);
    for (const std::string& dir : component_dirs(file, o, type))
        if (Component* c = load_component(dir + "/" + name + ".rui"))
            return c;
    return nullptr;
}

void annotate(const std::string& file, Outline* o) {
    if (!o || o->annotated == g_generation)
        return;
    o->annotated = g_generation;
    for (Element* el : o->all) {
        el->comp = nullptr;
        el->base = type_of(el->type) && el->type != "Slot" ? el->type : "";
        if (!el->base.empty() || el->type == "Slot")
            continue;
        Component* c = find_component(file, *o, el->type);
        if (!c || !c->o)
            continue;
        el->comp = c;
        annotate(c->path, c->o);
        el->base = c->o->root->base;
    }
}

std::vector<std::string> cycle_of(Component* c, std::vector<std::string> stack) {
    auto at = std::find(stack.begin(), stack.end(), c->path);
    if (at != stack.end()) {
        std::vector<std::string> out(at, stack.end());
        out.push_back(c->path);
        return out;
    }
    if (!c->o)
        return {};
    annotate(c->path, c->o);
    stack.push_back(c->path);
    for (Element* x : c->o->all)
        if (x->comp) {
            auto r = cycle_of(x->comp, stack);
            if (!r.empty())
                return r;
        }
    return {};
}

Names comp_names(Component* c) {
    std::vector<std::string> seen;
    std::function<Names(Component*)> go = [&](Component* k) {
        Names names;
        if (!k || !k->o || std::find(seen.begin(), seen.end(), k->path) != seen.end())
            return names;
        seen.push_back(k->path);
        annotate(k->path, k->o);
        Element* root = k->o->root;
        if (root->comp)
            for (auto& [n, v] : go(root->comp))
                names.set(n, v);
        for (const Member& m : root->members)
            if (m.kind == Member::custom || m.kind == Member::function)
                names.set(m.name, Name{m.kind == Member::custom ? Name::custom : Name::function, "", &m, k});
        return names;
    };
    return go(c);
}

std::vector<std::string> components_in(const std::string& dir) {
    static std::map<std::string, std::pair<double, std::vector<std::string>>> seen;
    double now = clock_s();
    auto at = seen.find(dir);
    if (at != seen.end() && now - at->second.first < k_fresh)
        return at->second.second;
    std::vector<std::string> out;
    std::error_code ec;
    for (auto it = fs::directory_iterator(dir, ec); !ec && it != fs::directory_iterator(); it.increment(ec)) {
        std::string f = it->path().filename().string();
        if (f.size() < 5 || f.compare(f.size() - 4, 4, ".rui") != 0 || !(f[0] >= 'A' && f[0] <= 'Z'))
            continue;
        bool ok = true;
        for (size_t k = 0; k + 4 < f.size(); k++)
            ok = ok && (std::isalnum(static_cast<unsigned char>(f[k])) || f[k] == '_' || f[k] == '$');
        if (ok)
            out.push_back(f.substr(0, f.size() - 4));
    }
    std::sort(out.begin(), out.end());
    seen[dir] = {now, out};
    return out;
}

bool exists(const std::string& p) {
    return mtime(p) != 0;
}

Names type_names(const std::string& type, bool delegate) {
    Names names;
    const Type* t = type_of(type);
    if (!t)
        return names;
    for (const Prop& p : t->props) {
        std::string top = p.name.substr(0, p.name.find('.'));
        if (!names.has(top))
            names.set(top, p.name.find('.') != std::string::npos ? Name{Name::group} : Name{Name::prop, p.name});
    }
    for (const std::string& m : t->methods)
        names.set(m, Name{Name::method});
    if (delegate)
        names.set("modelData", Name{Name::model}), names.set("index", Name{Name::model});
    return names;
}

Names element_names(const Element* el) {
    Names names = type_names(el->base.empty() ? el->type : el->base, !el->delegate.empty());
    if (el->comp)
        for (auto& [k, v] : comp_names(el->comp))
            names.set(k, v);
    for (const Member& m : el->members)
        if (m.kind == Member::custom || m.kind == Member::function)
            names.set(m.name, Name{m.kind == Member::custom ? Name::custom : Name::function, "", &m});
    return names;
}

}
