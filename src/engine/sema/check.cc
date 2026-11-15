// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/sema/check.h"

#include <cstdarg>
#include <cstdio>
#include <cstring>

#include "gen/rx_props.h"

namespace rx::engine::sema {
namespace {

using rx::schema::Elem;
using rx::schema::Prop;
using sv = std::string_view;

constexpr sv k_globals[] = {"rgba",
                            "alpha",
                            "mix",
                            "theme",
                            "i18n",
                            "qsTr",
                            "qsTrn",
                            "conf",
                            "keys",
                            "panes",
                            "pane",
                            "context",
                            "notices",
                            "activity",
                            "diagnostics",
                            "shared",
                            "loading",
                            "windows",
                            "files",
                            "rex",
                            "console",
                            "debug",
                            "clipboard",
                            "power",
                            "undefined",
                            "NaN",
                            "Infinity",
                            "globalThis",
                            "Math",
                            "JSON",
                            "Date",
                            "Object",
                            "Array",
                            "String",
                            "Number",
                            "Boolean",
                            "Symbol",
                            "RegExp",
                            "Set",
                            "Map",
                            "WeakMap",
                            "WeakSet",
                            "WeakRef",
                            "Promise",
                            "Error",
                            "TypeError",
                            "RangeError",
                            "SyntaxError",
                            "ReferenceError",
                            "EvalError",
                            "URIError",
                            "AggregateError",
                            "parseInt",
                            "parseFloat",
                            "isNaN",
                            "isFinite",
                            "encodeURIComponent",
                            "decodeURIComponent",
                            "encodeURI",
                            "decodeURI",
                            "escape",
                            "unescape",
                            "Intl",
                            "Reflect",
                            "Proxy",
                            "ArrayBuffer",
                            "SharedArrayBuffer",
                            "DataView",
                            "Int8Array",
                            "Uint8Array",
                            "Uint8ClampedArray",
                            "Int16Array",
                            "Uint16Array",
                            "Int32Array",
                            "Uint32Array",
                            "Float32Array",
                            "Float64Array",
                            "BigInt",
                            "BigInt64Array",
                            "BigUint64Array",
                            "Function",
                            "Atomics",
                            "FinalizationRegistry",
                            "arguments",
                            "setTimeout",
                            "clearTimeout",
                            "setInterval",
                            "clearInterval",
                            "queueMicrotask"};

constexpr sv k_dynamic[] = {"modelData", "state",   "theme",   "rex",      "conf",        "keys",   "panes",
                            "pane",      "context", "notices", "activity", "diagnostics", "shared", "loading",
                            "windows",   "files",   "debug",   "i18n",     "power"};

constexpr sv k_own[] = {"__uid",    "__type", "__values", "__deps",      "__bindings", "__handlers", "__names",
                        "__native", "parent", "children", "__templates", "__at",       "__ctx"};

template<size_t N>
bool in(const sv (&list)[N], sv s) {
    for (sv x : list)
        if (x == s)
            return true;
    return false;
}

struct Inst;
struct Ctx {
    enum Kind : uint8_t { none, root, inside } kind = none;
    Inst* in = nullptr;
};

struct Inst {
    Elem type;
    bool delegate_root;
    bool pane;
    Inst* parent;
    Inst* ctx;
    List<sv> customs;
    List<sv> functions;
    List<rui::Signal> signals;
};

struct UseDir {
    sv dir, as;
    bool has_as;
};
struct Comp {
    sv path, file;
    sv src;
    rui::File* ast;
    List<UseDir> uses;
    bool missing, failed;
    rui::Error error;
};

struct Scope;
struct SlotFill {
    rui::Element* node;
    Scope* sc;
    Ctx ctx;
};
struct Id {
    sv name;
    Inst* inst;
};
struct Scope {
    sv file, path;
    List<UseDir> uses;
    Scope* ids_up;
    List<Id> ids;
    Inst* root;
    SlotFill* slot;
    bool slotted;
    sv src;
};

struct PendingNode {
    Inst* o;
    rui::Element* node;
    Scope* sc;
    Inst* cx;
    bool has_cx;
    bool tmpl;
};
struct PendingBinding {
    Inst* o;
    const rui::Member* m;
    Scope* sc;
    Inst* cx;
    bool has_cx;
    bool tmpl;
};
struct Pending {
    List<PendingNode> nodes;
    List<PendingBinding> bindings;
};

struct Stop {};

struct Checker {
    Checker(Arena& a, Reader& r) : arena(a), reader(r) {}
    Arena& arena;
    Reader& reader;
    Result out;
    sv top_path;
    List<Comp*> comps;
    List<sv> using_;
    List<sv> used_at;
    bool in_template = false;
    bool phase1 = true;

    struct Local {
        sv name;
        const Local* up;
    };
    const Local* push(sv name, const Local* up) {
        Local* l = arena.make<Local>(name, up);
        return l ? l : up;
    }

    sv fmt(const char* f, ...) __attribute__((format(printf, 2, 3))) {
        char buf[2048];
        va_list ap;
        va_start(ap, f);
        int n = std::vsnprintf(buf, sizeof buf, f, ap);
        va_end(ap);
        return arena.copy({buf,
                           n < 0                                     ? 0
                               : static_cast<size_t>(n) < sizeof buf ? static_cast<size_t>(n)
                                                                     : sizeof buf - 1});
    }
    sv cat(sv a, sv b) {
        char* p = static_cast<char*>(arena.alloc(a.size() + b.size() + 1, 1));
        if (!p)
            return {};
        std::memcpy(p, a.data(), a.size());
        std::memcpy(p + a.size(), b.data(), b.size());
        return {p, a.size() + b.size()};
    }
    static int w(sv s) { return static_cast<int>(s.size()); }

    static sv dirname(sv p) {
        size_t k = p.rfind('/');
        return k == sv::npos ? sv{} : p.substr(0, k);
    }
    sv normalize(sv p) {
        size_t slashes = 0;
        for (char c : p)
            slashes += c == '/';
        if (slashes >= 512)
            return p;
        sv parts[512];
        size_t n = 0;
        size_t at = 0;
        for (;;) {
            size_t e = p.find('/', at);
            sv s = p.substr(at, e == sv::npos ? sv::npos : e - at);
            if (s == "." || (s.empty() && n)) {
            } else if (s == ".." && n && parts[n - 1] != ".." && !parts[n - 1].empty()) {
                n--;
            } else if (n < 512) {
                parts[n++] = s;
            }
            if (e == sv::npos)
                break;
            at = e + 1;
        }
        sv r;
        for (size_t k = 0; k < n; k++)
            r = k ? cat(cat(r, "/"), parts[k]) : parts[k];
        return r;
    }
    sv folder(sv from, sv p) {
        if (p == "rexui" || p == "rexshared")
            return p;
        if (p.starts_with("/") || p.starts_with("~"))
            return normalize(p);
        sv base = dirname(from);
        return normalize(base.empty() ? p : cat(cat(base, "/"), p));
    }
    sv display(sv p) {
        sv d = dirname(top_path);
        if (d.empty() || !p.starts_with("/"))
            return p;
        size_t slashes = 0;
        for (char c : d)
            slashes += c == '/';
        for (char c : p)
            slashes += c == '/';
        if (slashes >= 256)
            return p;
        sv a[256], b[256];
        size_t na = split(d, a), nb = split(p, b);
        size_t k = 0;
        while (k < na && k < nb - 1 && a[k] == b[k])
            k++;
        if (k < 2)
            return p;
        sv r;
        for (size_t x = k; x < na; x++)
            r = cat(r, "../");
        for (size_t x = k; x < nb; x++)
            r = cat(x > k ? cat(r, "/") : r, b[x]);
        return r;
    }
    static size_t split(sv s, sv* out) {
        size_t n = 0, at = 0;
        for (;;) {
            size_t e = s.find('/', at);
            if (n < 256)
                out[n++] = s.substr(at, e == sv::npos ? sv::npos : e - at);
            if (e == sv::npos)
                return n;
            at = e + 1;
        }
    }

    void diag(Severity sev, Scope* sc, sv file, sv path, uint32_t line, uint32_t pos, sv msg, bool subset = false) {
        sv at;
        if (phase1)
            for (sv u : used_at)
                at = at.empty() ? u : cat(cat(at, " <- "), u);
        (void)sc;
        for (const Diagnostic& d : out.diags)
            if (d.pos == pos && d.path == path && d.msg == msg)
                return;
        Diagnostic d{sev, subset, in_template, !in_template && sev == Severity::error, false, file, path, line,
                     pos, msg,    at};
        (void)out.diags.push(arena, d);
    }
    void error(Scope* sc, uint32_t line, uint32_t pos, sv msg) {
        diag(Severity::error, sc, sc->file, sc->path, line, pos, msg);
    }

    static bool type_has_value(Elem e, sv name) {
        Prop p;
        return rx::schema::prop_of(name, &p) && rx::schema::has(e, p);
    }
    struct Groups {
        sv names[8];
        int n = 0;
    };
    static const Groups& groups(Elem e) {
        static Groups table[static_cast<int>(Elem::count_)];
        static bool built = false;
        if (!built) {
            for (int t = 0; t < static_cast<int>(Elem::count_); t++)
                for (int i = 0; i < static_cast<int>(Prop::count_); i++) {
                    if (!rx::schema::has(static_cast<Elem>(t), static_cast<Prop>(i)))
                        continue;
                    sv n = rx::schema::k_props[i].name;
                    size_t dot = n.find('.');
                    if (dot == sv::npos)
                        continue;
                    Groups& g = table[t];
                    bool seen = false;
                    for (int k = 0; k < g.n; k++)
                        seen = seen || g.names[k] == n.substr(0, dot);
                    if (!seen && g.n < 8)
                        g.names[g.n++] = n.substr(0, dot);
                }
            built = true;
        }
        return table[static_cast<int>(e)];
    }
    static bool type_has_name(Elem e, sv name) {
        if (name.find('.') == sv::npos && type_has_value(e, name))
            return true;
        const Groups& g = groups(e);
        for (int k = 0; k < g.n; k++)
            if (g.names[k] == name)
                return true;
        auto ms = rx::schema::k_elem_methods[static_cast<int>(e)];
        for (int i = 0; i < ms.count; i++)
            if (rx::schema::k_methods[ms.first + i] == name)
                return true;
        return false;
    }
    static bool has_value(const Inst* o, sv name) {
        if (type_has_value(o->type, name))
            return true;
        if (o->delegate_root && (name == "modelData" || name == "index" || (o->pane && name == "pane")))
            return true;
        for (sv c : o->customs)
            if (c == name)
                return true;
        return false;
    }
    static bool has_name(const Inst* o, sv name) {
        if (type_has_name(o->type, name))
            return true;
        if (o->delegate_root && (name == "modelData" || name == "index" || (o->pane && name == "pane")))
            return true;
        for (sv c : o->customs)
            if (c == name)
                return true;
        for (sv f : o->functions)
            if (f == name)
                return true;
        for (const rui::Signal& g : o->signals)
            if (g.name == name)
                return true;
        return false;
    }
    static bool own_property(const Inst* o, sv name) { return in(k_own, name) || has_name(o, name); }

    void look_in(sv type, Scope* sc, List<sv>& dirs) {
        size_t dot = type.rfind('.');
        sv ns = dot == sv::npos ? sv{} : type.substr(0, dot);
        if (ns.empty() && !sc->path.empty())
            (void)dirs.push(arena, dirname(sc->path));
        for (const UseDir& u : sc->uses)
            if ((u.has_as ? u.as : sv{}) == ns)
                (void)dirs.push(arena, u.dir);
    }
    Comp* component(sv type, Scope* sc, uint32_t line, uint32_t pos, bool& stop) {
        size_t dot = type.rfind('.');
        sv ns = dot == sv::npos ? sv{} : type.substr(0, dot), name = type.substr(dot == sv::npos ? 0 : dot + 1);
        if (!ns.empty()) {
            bool found = false;
            for (const UseDir& u : sc->uses)
                found = found || (u.has_as && u.as == ns);
            if (!found) {
                error(sc, line, pos, fmt("no use ... as %.*s for %.*s", w(ns), ns.data(), w(type), type.data()));
                stop = true;
                return nullptr;
            }
        }
        List<sv> dirs;
        look_in(type, sc, dirs);
        for (sv d : dirs) {
            sv p = cat(cat(cat(d, "/"), name), ".rui");
            Comp* c = nullptr;
            for (Comp* x : comps)
                if (x->path == p)
                    c = x;
            if (!c) {
                c = arena.make<Comp>();
                if (!c)
                    return nullptr;
                c->path = p;
                (void)comps.push(arena, c);
                (void)out.components.push(arena, p);
                sv text;
                if (!reader.read(p, text)) {
                    c->missing = true;
                } else {
                    c->file = display(p);
                    c->src = text;
                    auto f = rui::parse(text, arena);
                    if (!f) {
                        c->failed = true;
                        c->error = f.error();
                    } else {
                        c->ast = *f;
                        for (const rui::Use& u : c->ast->uses)
                            (void)c->uses.push(arena, UseDir{folder(p, u.path), u.as, u.has_as});
                    }
                }
            }
            if (c->failed) {
                diag(Severity::error, sc, c->file, c->path, c->error.line, c->error.pos, c->error.msg);
                stop = true;
                return nullptr;
            }
            if (!c->missing)
                return c;
        }
        return nullptr;
    }

    Scope* new_scope(sv file, sv path, const List<UseDir>& uses, sv src) {
        Scope* s = arena.make<Scope>();
        if (!s)
            return nullptr;
        s->file = file;
        s->path = path;
        s->uses = uses;
        s->src = src;
        return s;
    }

    const rui::Element* use_of = nullptr;
    static sv slot_name(const rui::Element* node) {
        for (const rui::Member& m : node->props) {
            if (m.name != "name" || m.value.size() < 2)
                continue;
            char q = m.value[0];
            if ((q == '"' || q == '\'') && m.value.back() == q)
                return m.value.substr(1, m.value.size() - 2);
        }
        return {};
    }
    static bool has_named_slot(const rui::Element* n, sv name) {
        if (n->type == "Slot")
            return slot_name(n) == name;
        for (const rui::Element* c : n->children)
            if (has_named_slot(c, name))
                return true;
        for (const rui::Object& ob : n->objects)
            if (has_named_slot(ob.node, name))
                return true;
        return false;
    }

    bool create(rui::Element* node, Inst* parent, Pending& pending, Scope* sc, Ctx ctx, Inst** made) {
        if (made)
            *made = nullptr;
        out.stats.elements++;
        if (node->type == "Slot") {
            if (sv named = slot_name(node); !named.empty()) {
                if (!sc->slot) {
                    error(sc, node->line, node->pos,
                          "a Slot is only for a component's file (Card.rui): where Card { ... }'s elements go");
                    return false;
                }
                bool ok = true;
                for (const rui::Object& ob : sc->slot->node->objects) {
                    if (ob.name != named)
                        continue;
                    Ctx c = sc->slot->ctx;
                    if (c.kind == Ctx::root)
                        c = parent->ctx ? Ctx{Ctx::inside, parent->ctx} : Ctx{};
                    ok = create(ob.node, parent, pending, sc->slot->sc, c, nullptr) && ok;
                }
                return ok;
            }
            if (!sc->slot) {
                error(sc, node->line, node->pos,
                      "a Slot is only for a component's file (Card.rui): where Card { ... }'s elements go");
                return false;
            }
            if (sc->slotted) {
                error(sc, node->line, node->pos, "a component has one Slot");
                return false;
            }
            sc->slotted = true;
            return fill(*sc->slot, parent, pending);
        }
        Elem e;
        if (!rx::schema::elem_of(node->type, &e) || e == Elem::Slot)
            return instance(node, parent, pending, sc, ctx, made);
        Inst* o = arena.make<Inst>();
        if (!o)
            return false;
        o->type = e;
        o->parent = parent;
        if (ctx.kind == Ctx::root)
            ctx = {Ctx::inside, o};
        o->ctx = ctx.kind == Ctx::inside ? ctx.in : nullptr;
        if (o->ctx == o) {
            o->delegate_root = true;
            o->pane = parent && parent->type == Elem::Panes;
        }
        if (made)
            *made = o;
        if (!members(o, node, pending, sc, nullptr, false))
            return false;
        for (rui::Element* child : node->children) {
            create(child, o, pending, sc, ctx, nullptr);
        }
        return true;
    }

    bool fill(const SlotFill& f, Inst* into, Pending& pending) {
        Ctx c = f.ctx;
        if (c.kind == Ctx::root)
            c = into->ctx ? Ctx{Ctx::inside, into->ctx} : Ctx{};
        bool ok = true;
        for (rui::Element* child : f.node->children)
            ok = create(child, into, pending, f.sc, c, nullptr) && ok;
        return ok;
    }

    bool members(Inst* o, rui::Element* node, Pending& pending, Scope* sc, Inst* cx, bool has_cx) {
        bool ok = true;
        if (node->has_id) {
            bool dup = false;
            for (const Id& x : sc->ids)
                dup = dup || x.name == node->id;
            if (dup) {
                error(sc, node->line, node->id_pos, fmt("id %.*s is used twice", w(node->id), node->id.data()));
                return false;
            }
            (void)sc->ids.push(arena, Id{node->id, o});
        }
        for (const rui::Object& ob : node->objects) {
            auto os = rx::schema::k_elem_objects[static_cast<int>(o->type)];
            bool takes = false;
            for (int i = 0; i < os.count; i++)
                takes = takes || rx::schema::k_objects[os.first + i] == ob.name;
            if (use_of && has_named_slot(use_of, ob.name))
                continue;
            if (!takes) {
                error(sc, ob.line, ob.pos,
                      fmt("%.*s has no property %.*s taking an element", w(node->type), node->type.data(), w(ob.name),
                          ob.name.data()));
                return false;
            }
        }
        for (const rui::Signal& g : node->signals) {
            if (has_name(o, g.name)) {
                error(sc, g.line, g.pos,
                      fmt("%.*s already has %.*s", w(node->type), node->type.data(), w(g.name), g.name.data()));
                return false;
            }
            (void)o->signals.push(arena, g);
        }
        for (const rui::Member& c : node->custom) {
            if (has_name(o, c.name)) {
                error(sc, c.line, c.pos,
                      fmt("%.*s already has a property %.*s", w(node->type), node->type.data(), w(c.name),
                          c.name.data()));
                return false;
            }
            (void)o->customs.push(arena, c.name);
            if (c.has_value)
                (void)pending.bindings.push(arena, PendingBinding{o, &c, sc, cx, has_cx, in_template});
        }
        for (const rui::Member& p : node->props) {
            if (!has_value(o, p.name)) {
                error(sc, p.line, p.pos,
                      fmt("%.*s has no property %.*s", w(node->type), node->type.data(), w(p.name), p.name.data()));
                return false;
            }
            for (const rui::Member& q : node->props) {
                if (&q == &p)
                    break;
                if (q.name == p.name) {
                    error(sc, p.line, p.pos,
                          fmt("%.*s sets %.*s twice", w(node->type), node->type.data(), w(p.name), p.name.data()));
                    return false;
                }
            }
            (void)pending.bindings.push(arena, PendingBinding{o, &p, sc, cx, has_cx, in_template});
        }
        (void)pending.nodes.push(arena, PendingNode{o, node, sc, cx, has_cx, in_template});
        for (const rui::Object& ob : node->objects)
            if (!use_of || !has_named_slot(use_of, ob.name))
                (void)templates.push(arena, Template{o, ob.node, sc});
        return ok;
    }

    bool instance(rui::Element* node, Inst* parent, Pending& pending, Scope* sc, Ctx ctx, Inst** made) {
        bool stop = false;
        Comp* c = component(node->type, sc, node->line, node->pos, stop);
        if (stop)
            return false;
        if (!c) {
            List<sv> looked;
            look_in(node->type, sc, looked);
            sv known;
            for (int i = 0; i < static_cast<int>(Elem::count_); i++) {
                if (static_cast<Elem>(i) == Elem::Slot)
                    continue;
                known = known.empty() ? rx::schema::k_elems[i] : cat(cat(known, ", "), rx::schema::k_elems[i]);
            }
            sv msg = fmt("unknown element %.*s (known: %.*s", w(node->type), node->type.data(), w(known), known.data());
            if (looked.size) {
                sv dirs;
                for (sv d : looked)
                    dirs = dirs.empty() ? d : cat(cat(dirs, ", "), d);
                size_t dot = node->type.rfind('.');
                sv base = node->type.substr(dot == sv::npos ? 0 : dot + 1);
                msg = cat(msg, fmt("; no %.*s.rui in %.*s", w(base), base.data(), w(dirs), dirs.data()));
            }
            error(sc, node->line, node->pos, cat(msg, ")"));
            return false;
        }
        for (sv u : using_)
            if (u == c->path) {
                sv chain;
                for (sv x : using_)
                    chain = chain.empty() ? display(x) : cat(cat(chain, " -> "), display(x));
                error(sc, node->line, node->pos,
                      fmt("%.*s uses itself (%.*s)", w(node->type), node->type.data(), w(chain), chain.data()));
                return false;
            }
        out.stats.components++;
        Scope* inner = new_scope(c->file, c->path, c->uses, c->src);
        SlotFill* own = arena.make<SlotFill>();
        if (!inner || !own)
            return false;
        *own = SlotFill{node, sc, ctx.kind == Ctx::root ? Ctx{Ctx::root, nullptr} : ctx};
        inner->slot = own;
        (void)using_.push(arena, c->path);
        (void)used_at.push(arena, fmt("%.*s:%u", w(sc->file), sc->file.data(), node->line));
        Inst* o = nullptr;
        bool ok =
            create(c->ast->root, parent, pending, inner, ctx.kind == Ctx::root ? Ctx{Ctx::root, nullptr} : Ctx{}, &o);
        used_at.size--;
        using_.size--;
        if (!o)
            return false;
        inner->root = o;
        if (made)
            *made = o;
        Inst* cx = ctx.kind == Ctx::inside ? ctx.in : nullptr;
        use_of = c->ast->root;
        const bool members_ok = members(o, node, pending, sc, cx, cx != nullptr);
        use_of = nullptr;
        if (!members_ok)
            return false;
        if (!inner->slotted)
            ok = fill(*own, o, pending) && ok;
        return ok;
    }

    static bool signal_ok(Elem e, sv name) {
        if (name == "Component.onCompleted" || name == "Component.onDestruction")
            return true;
        if (name.size() < 3)
            return false;
        char first = name[2] >= 'A' && name[2] <= 'Z' ? static_cast<char>(name[2] + 32) : name[2];
        sv rest = name.substr(3);
        auto ss = rx::schema::k_elem_signals[static_cast<int>(e)];
        for (int i = 0; i < ss.count; i++) {
            sv sig = rx::schema::k_signals[ss.first + i].name;
            if (!sig.empty() && sig[0] == first && sig.substr(1) == rest)
                return true;
        }
        bool visual = type_has_value(e, "opacity");
        if (first == 'p' && rest == "ressedOutside" && visual)
            return true;
        if (first == 'f' && rest == "ilesDropped" && type_has_value(e, "dropFiles"))
            return true;
        return rest.ends_with("Changed");
    }
    static sv signal_of(sv name, char* buf, size_t n) {
        size_t k = 0;
        if (name.find('.') != sv::npos)
            return name;
        if (name.size() >= 3) {
            buf[k++] = name[2] >= 'A' && name[2] <= 'Z' ? static_cast<char>(name[2] + 32) : name[2];
            for (size_t i = 3; i < name.size() && k < n; i++)
                buf[k++] = name[i];
        }
        return {buf, k};
    }

    static const rui::Signal* declared_signal(const Inst* o, sv handler) {
        if (handler.size() < 3 || handler[0] != 'o' || handler[1] != 'n')
            return nullptr;
        for (const rui::Signal& g : o->signals) {
            if (g.name.size() != handler.size() - 2 || g.name.substr(1) != handler.substr(3))
                continue;
            char first = handler[2] >= 'A' && handler[2] <= 'Z' ? static_cast<char>(handler[2] + 32) : handler[2];
            if (g.name[0] == first || g.name[0] == handler[2])
                return &g;
        }
        return nullptr;
    }
    void js_error(Scope* sc, uint32_t member_line, const js::Error& e) {
        diag(Severity::error, sc, sc->file, sc->path, member_line, e.pos, e.msg, e.subset);
    }

    void wire(const PendingNode& pn) {
        in_template = pn.tmpl;
        for (const rui::Function& f : pn.node->functions) {
            if (own_property(pn.o, f.name)) {
                error(pn.sc, f.line, f.pos,
                      fmt("%.*s already has a function %.*s", w(pn.node->type), pn.node->type.data(), w(f.name),
                          f.name.data()));
                continue;
            }
            auto r = js::parse_function(pn.sc->src, f.params_pos, static_cast<uint32_t>(f.params.size()), f.body_pos,
                                        static_cast<uint32_t>(f.body.size()), arena);
            out.stats.units++;
            out.stats.classes[static_cast<int>(Class::function)]++;
            if (!r)
                js_error(pn.sc, f.line, r.error());
            else
                later(*r, pn, nullptr);
            (void)pn.o->functions.push(arena, f.name);
        }
        for (const rui::Member& h : pn.node->handlers) {
            for (const rui::Member& q : pn.node->handlers) {
                if (&q == &h)
                    break;
                if (q.name == h.name)
                    error(pn.sc, h.line, h.pos,
                          fmt("%.*s has %.*s twice", w(pn.node->type), pn.node->type.data(), w(h.name), h.name.data()));
            }
            const rui::Signal* declared = declared_signal(pn.o, h.name);
            if (!declared && !signal_ok(pn.o->type, h.name)) {
                char buf[256];
                sv s = signal_of(h.name, buf, sizeof buf);
                sv type = rx::schema::k_elems[static_cast<int>(pn.o->type)];
                error(pn.sc, h.line, h.pos, fmt("%.*s has no signal %.*s", w(type), type.data(), w(s), s.data()));
                continue;
            }
            auto r =
                js::parse(pn.sc->src, h.value_pos, static_cast<uint32_t>(h.value.size()), js::Goal::handler, arena);
            out.stats.units++;
            out.stats.classes[static_cast<int>(Class::handler)]++;
            if (!r) {
                js_error(pn.sc, h.line, r.error());
                continue;
            }
            const Local* params = nullptr;
            sv list = declared ? declared->params : signal_params(pn.o->type, h.name);
            for (size_t at = 0; at < list.size();) {
                size_t e = list.find(',', at);
                sv one = list.substr(at, e == sv::npos ? sv::npos : e - at);
                while (!one.empty() && one.front() == ' ')
                    one.remove_prefix(1);
                if (!one.empty())
                    params = push(one, params);
                if (e == sv::npos)
                    break;
                at = e + 1;
            }
            later(*r, pn, params);
        }
    }
    static sv signal_params(Elem e, sv name) {
        if (name.size() < 3 || name == "Component.onCompleted" || name == "Component.onDestruction")
            return {};
        char first = name[2] >= 'A' && name[2] <= 'Z' ? static_cast<char>(name[2] + 32) : name[2];
        sv rest = name.substr(3);
        auto ss = rx::schema::k_elem_signals[static_cast<int>(e)];
        for (int i = 0; i < ss.count; i++) {
            const auto& sig = rx::schema::k_signals[ss.first + i];
            if (!sig.name.empty() && sig.name[0] == first && sig.name.substr(1) == rest)
                return sig.params;
        }
        if (first == 'f' && rest == "ilesDropped")
            return "paths, copy";
        if (name.ends_with("Changed"))
            return "initial";
        return {};
    }
    struct Later {
        const js::Node* n;
        PendingNode pn;
        const Local* locals;
    };
    List<Later> laters;
    void later(const js::Node* n, const PendingNode& pn, const Local* locals) {
        (void)laters.push(arena, Later{n, pn, locals});
    }

    static bool color_ok(sv v) {
        while (!v.empty() && v.front() == ' ')
            v.remove_prefix(1);
        while (!v.empty() && v.back() == ' ')
            v.remove_suffix(1);
        if (v.empty())
            return true;
        if (v[0] == '#') {
            if (v.size() != 4 && v.size() != 7 && v.size() != 9)
                return false;
            for (char c : v.substr(1))
                if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')))
                    return false;
            return true;
        }
        if ((v.starts_with("rgba(") || v.starts_with("rgb(")) && v.back() == ')')
            return true;
        for (sv k : {"transparent", "white", "black", "red", "green", "blue", "orange", "yellow", "pink", "purple",
                     "gray", "grey", "accent", "foreground", "background"})
            if (v == k)
                return true;
        return false;
    }
    static bool enum_ok(sv values, sv v) {
        if (v.empty())
            return true;
        for (size_t at = 0;;) {
            size_t e = values.find('|', at);
            sv one = values.substr(at, e == sv::npos ? sv::npos : e - at);
            if (one == v || (one.ends_with('*') && v.starts_with(one.substr(0, one.size() - 1))))
                return true;
            if (e == sv::npos)
                return false;
            at = e + 1;
        }
    }
    template<class F>
    static void each_literal(const js::Node* n, F&& f) {
        if (!n)
            return;
        switch (n->kind) {
        case js::K::str:
            if (n->text.find('\\') == sv::npos)
                f(n);
            return;
        case js::K::paren:
            if (!n->a->next)
                each_literal(n->a, f);
            return;
        case js::K::cond:
            each_literal(n->b, f), each_literal(n->c, f);
            return;
        case js::K::logical:
            if (n->op != js::Op::and_)
                each_literal(n->a, f);
            each_literal(n->b, f);
            return;
        default:
            return;
        }
    }
    void check_literals(const js::Node* r, const PendingBinding& pb) {
        Scope* sc = pb.sc;
        uint32_t line = pb.m->line;
        sv ptype = pb.m->type;
        if (!ptype.empty()) {
            const js::Node* v = r;
            while (v->kind == js::K::paren && !v->a->next)
                v = v->a;
            const bool str = v->kind == js::K::str || (v->kind == js::K::tmpl && v->a && !v->a->next);
            const bool num =
                v->kind == js::K::num || (v->kind == js::K::unary && v->op == js::Op::neg && v->a->kind == js::K::num);
            const bool boolean = v->kind == js::K::true_ || v->kind == js::K::false_;
            const bool numeric = ptype == "int" || ptype == "real" || ptype == "double" || ptype == "number";
            sv is = str ? "a string" : num ? "a number" : boolean ? "a boolean" : sv{};
            if (!is.empty() && ((numeric && !num) || (ptype == "string" && !str) || (ptype == "bool" && !boolean)))
                diag(Severity::warning, sc, sc->file, sc->path, line, r->pos,
                     fmt("%.*s is declared %.*s, and this is %.*s", w(pb.m->name), pb.m->name.data(), w(ptype),
                         ptype.data(), w(is), is.data()));
            if (ptype == "color")
                each_literal(r, [&](const js::Node* l) {
                    if (!color_ok(l->text))
                        diag(Severity::warning, sc, sc->file, sc->path, line, l->pos,
                             fmt("%.*s isn't a colour", w(l->text), l->text.data()));
                });
            return;
        }
        Prop p;
        if (!rx::schema::prop_of(pb.m->name, &p) || !rx::schema::has(pb.o->type, p))
            return;
        sv values;
        for (const auto& e : rx::schema::k_enums)
            if (e.elem == pb.o->type && e.prop == p)
                values = e.values;
        const bool color = rx::schema::k_props[static_cast<int>(p)].type == rx::schema::Type::color;
        if (values.empty() && !color)
            return;
        each_literal(r, [&](const js::Node* l) {
            if (color && !color_ok(l->text))
                diag(Severity::warning, sc, sc->file, sc->path, line, l->pos,
                     fmt("%.*s isn't a colour", w(l->text), l->text.data()));
            else if (!values.empty() && !enum_ok(values, l->text))
                diag(Severity::warning, sc, sc->file, sc->path, line, l->pos,
                     fmt("%.*s isn't a value of %.*s (%.*s)", w(l->text), l->text.data(), w(pb.m->name),
                         pb.m->name.data(), w(values), values.data()));
        });
    }

    void bind(const PendingBinding& pb) {
        in_template = pb.tmpl;
        auto r =
            js::parse(pb.sc->src, pb.m->value_pos, static_cast<uint32_t>(pb.m->value.size()), js::Goal::value, arena);
        out.stats.units++;
        if (!r) {
            js_error(pb.sc, pb.m->line, r.error());
            return;
        }
        PendingNode pn{pb.o, nullptr, pb.sc, pb.cx, pb.has_cx, pb.tmpl};
        Class c = classify(*r);
        out.stats.classes[static_cast<int>(c)]++;
        check_literals(*r, pb);
        later(*r, pn, nullptr);
    }

    void bind_all(Pending& p) {
        bool was = phase1;
        phase1 = false;
        for (uint32_t k = 0; k < p.nodes.size; k++)
            wire(p.nodes[k]);
        for (uint32_t k = 0; k < p.bindings.size; k++)
            bind(p.bindings[k]);
        phase1 = was;
    }
    List<sv> assigned;
    void collect_assigned(const js::Node* n, const PendingNode& pn) {
        if (!n)
            return;
        if (n->kind == js::K::assign || n->kind == js::K::update || n->kind == js::K::for_in
            || n->kind == js::K::for_of) {
            const js::Node* t = n->a;
            while (t && t->kind == js::K::paren)
                t = t->a;
            if (t && t->kind == js::K::ident && !resolved_not_assigned(t->text, pn, nullptr))
                (void)assigned.push(arena, t->text);
        }
        for (const js::Node* k : {n->a, n->b, n->c, n->d})
            for (const js::Node* x = k; x; x = x->next)
                collect_assigned(x, pn);
    }
    void resolve_all() {
        for (uint32_t k = 0; k < laters.size; k++)
            collect_assigned(laters[k].n, laters[k].pn);
        bool was = phase1;
        phase1 = false;
        for (uint32_t k = 0; k < laters.size; k++) {
            in_template = laters[k].pn.tmpl;
            resolve(laters[k].n, laters[k].pn, laters[k].locals);
        }
        in_template = false;
        phase1 = was;
    }

    static bool constant(const js::Node* n) {
        switch (n->kind) {
        case js::K::num:
        case js::K::str:
        case js::K::true_:
        case js::K::false_:
        case js::K::null_:
            return true;
        case js::K::ident:
            return n->text == "undefined";
        case js::K::tmpl:
            return n->a && !n->a->next;
        case js::K::paren:
            return n->a && !n->a->next && constant(n->a);
        case js::K::unary:
            return (n->op == js::Op::neg || n->op == js::Op::plus || n->op == js::Op::not_) && constant(n->a);
        case js::K::array:
            for (const js::Node* e = n->a; e; e = e->next)
                if (e->kind == js::K::spread || (e->kind != js::K::hole && !constant(e)))
                    return false;
            return true;
        case js::K::object:
            for (const js::Node* e = n->a; e; e = e->next)
                if (e->kind != js::K::prop || (e->flags & (js::f_computed | js::f_shorthand | js::f_method))
                    || !constant(e->b))
                    return false;
            return true;
        default:
            return false;
        }
    }
    static bool alias(const js::Node* n) {
        while (n->kind == js::K::paren && n->a && !n->a->next)
            n = n->a;
        if (n->kind == js::K::ident)
            return n->text != "undefined";
        return n->kind == js::K::member && !(n->flags & (js::f_optional | js::f_chain)) && alias(n->a);
    }
    static bool reads_dynamic(const js::Node* n) {
        if (n->kind == js::K::ident)
            return in(k_dynamic, n->text);
        if (n->kind == js::K::index)
            return true;
        if (n->kind == js::K::prop && !(n->flags & js::f_computed))
            return reads_dynamic(n->b);
        if (n->kind == js::K::member)
            return reads_dynamic(n->a);
        for (const js::Node* k : {n->a, n->b, n->c, n->d})
            for (const js::Node* x = k; x; x = x->next)
                if (reads_dynamic(x))
                    return true;
        return false;
    }
    static Class classify(const js::Node* n) {
        if (n->kind == js::K::block_body)
            return Class::block;
        if (constant(n))
            return Class::constant;
        if (n->kind == js::K::call && n->a->kind == js::K::ident && n->a->text == "qsTr" && n->b
            && n->b->kind == js::K::str && !n->b->next)
            return Class::lang;
        if (reads_dynamic(n))
            return Class::dynamic;
        if (alias(n))
            return Class::alias;
        return Class::expr;
    }

    bool resolved_not_assigned(sv name, const PendingNode& pn, const Local* locals) {
        for (const Local* l = locals; l; l = l->up)
            if (l->name == name)
                return true;
        for (Scope* s = pn.sc; s; s = s->ids_up)
            for (const Id& x : s->ids)
                if (x.name == name)
                    return true;
        if (name == "parent" || has_name(pn.o, name))
            return true;
        Inst* cx = pn.has_cx ? pn.cx : pn.o->ctx;
        if (cx && has_name(cx, name))
            return true;
        if (pn.sc->root && has_name(pn.sc->root, name))
            return true;
        return in(k_globals, name);
    }
    bool resolved(sv name, const PendingNode& pn, const Local* locals) {
        for (const Local* l = locals; l; l = l->up)
            if (l->name == name)
                return true;
        for (Scope* s = pn.sc; s; s = s->ids_up)
            for (const Id& x : s->ids)
                if (x.name == name)
                    return true;
        if (name == "parent")
            return true;
        if (has_name(pn.o, name))
            return true;
        Inst* cx = pn.has_cx ? pn.cx : pn.o->ctx;
        if (cx && has_name(cx, name))
            return true;
        if (pn.sc->root && has_name(pn.sc->root, name))
            return true;
        for (sv g : assigned)
            if (g == name)
                return true;
        return in(k_globals, name);
    }
    void member_of_id(const js::Node* n, const PendingNode& pn, const Local* l) {
        const js::Node* a = n->a;
        while (a->kind == js::K::paren && !a->a->next)
            a = a->a;
        if (a->kind != js::K::ident)
            return;
        for (const Local* x = l; x; x = x->up)
            if (x->name == a->text)
                return;
        const Inst* o = nullptr;
        for (Scope* s = pn.sc; s && !o; s = s->ids_up)
            for (const Id& x : s->ids)
                if (x.name == a->text)
                    o = x.inst;
        if (!o || in(k_own, n->text) || n->text == "pressedOutside" || has_name(o, n->text))
            return;
        sv type = rx::schema::k_elems[static_cast<int>(o->type)];
        diag(Severity::warning, pn.sc, pn.sc->file, pn.sc->path, line_of(pn.sc->src, n->pos), n->pos,
             fmt("%.*s (a %.*s) has no %.*s", w(a->text), a->text.data(), w(type), type.data(), w(n->text),
                 n->text.data()));
    }
    const Local* declare(const js::Node* p, const Local* l) {
        if (!p)
            return l;
        switch (p->kind) {
        case js::K::ident:
            return push(p->text, l);
        case js::K::array_pat:
            for (const js::Node* e = p->a; e; e = e->next)
                l = declare(e, l);
            return l;
        case js::K::object_pat:
            for (const js::Node* e = p->a; e; e = e->next)
                l = declare(e->kind == js::K::prop ? e->b : e, l);
            return l;
        case js::K::rest:
        case js::K::default_:
            return declare(p->a, l);
        default:
            return l;
        }
    }
    const Local* hoist(const js::Node* s, const Local* l) {
        for (; s; s = s->next)
            l = hoist_one(s, l);
        return l;
    }
    const Local* hoist_one(const js::Node* s, const Local* l) {
        if (!s)
            return l;
        switch (s->kind) {
        case js::K::var:
            if (s->op == js::Op::var_)
                for (const js::Node* d = s->a; d; d = d->next)
                    l = declare(d->a, l);
            return l;
        case js::K::func_decl:
            return push(s->text, l);
        case js::K::block:
            return hoist(s->a, l);
        case js::K::if_:
            return hoist_one(s->c, hoist_one(s->b, l));
        case js::K::switch_:
            return hoist_one(s->b, l);
        case js::K::for_:
        case js::K::for_in:
        case js::K::for_of:
        case js::K::while_:
        case js::K::do_while:
            return hoist_one(s->d, s->a && s->a->kind == js::K::var ? hoist_one(s->a, l) : l);
        case js::K::try_:
            return hoist_one(s->d, hoist_one(s->c, hoist_one(s->a, l)));
        default:
            return l;
        }
    }

    void resolve_list(const js::Node* first, const PendingNode& pn, const Local* l) {
        for (const js::Node* e = first; e; e = e->next)
            resolve(e, pn, l);
    }
    void resolve(const js::Node* n, const PendingNode& pn, const Local* l) {
        if (!n)
            return;
        switch (n->kind) {
        case js::K::ident:
            if (!resolved(n->text, pn, l))
                diag(Severity::warning, pn.sc, pn.sc->file, pn.sc->path, line_of(pn.sc->src, n->pos), n->pos,
                     fmt("%.*s is not a name here (an id, a property, a local or a global)", w(n->text),
                         n->text.data()));
            return;
        case js::K::member:
            member_of_id(n, pn, l);
            return resolve(n->a, pn, l);
        case js::K::prop:
            if (n->flags & js::f_computed)
                resolve(n->a, pn, l);
            return resolve(n->b, pn, l);
        case js::K::func:
        case js::K::func_decl:
        case js::K::arrow: {
            if (n->kind == js::K::func && !n->text.empty())
                l = push(n->text, l);
            for (const js::Node* p = n->a; p; p = p->next)
                l = declare(p, l);
            for (const js::Node* p = n->a; p; p = p->next)
                pattern(p, pn, l);
            if (n->b && n->b->kind == js::K::block_body)
                return block(n->b->a, pn, hoist(n->b->a, l));
            return resolve(n->b, pn, l);
        }
        case js::K::block_body:
            return block(n->a, pn, hoist(n->a, l));
        case js::K::block:
            return block(n->a, pn, l);
        case js::K::var:
            for (const js::Node* d = n->a; d; d = d->next) {
                pattern(d->a, pn, l);
                resolve(d->b, pn, l);
            }
            return;
        case js::K::for_:
        case js::K::for_in:
        case js::K::for_of:
            if (n->a && n->a->kind == js::K::var)
                for (const js::Node* d = n->a->a; d; d = d->next)
                    l = declare(d->a, l);
            if (n->a && (n->kind == js::K::for_ || n->a->kind == js::K::var))
                resolve(n->a, pn, l);
            else
                pattern(n->a, pn, l);
            resolve(n->b, pn, l);
            resolve(n->c, pn, l);
            return resolve(n->d, pn, l);
        case js::K::try_:
            resolve(n->a, pn, l);
            if (n->b) {
                pattern(n->b, pn, l);
                l = declare(n->b, l);
            }
            resolve(n->c, pn, l);
            return resolve(n->d, pn, l);
        case js::K::update:
            if (const js::Node* t = n->a; t && t->kind == js::K::ident && !resolved_not_assigned(t->text, pn, l))
                diag(Severity::warning, pn.sc, pn.sc->file, pn.sc->path, line_of(pn.sc->src, t->pos), t->pos,
                     fmt("%.*s is not a name here: this makes a global", w(t->text), t->text.data()));
            return resolve(n->a, pn, l);
        case js::K::assign:
            if (const js::Node* t = n->a; t && t->kind == js::K::ident && !resolved_not_assigned(t->text, pn, l))
                diag(Severity::warning, pn.sc, pn.sc->file, pn.sc->path, line_of(pn.sc->src, t->pos), t->pos,
                     fmt("%.*s is not a name here: this makes a global", w(t->text), t->text.data()));
            pattern(n->a, pn, l);
            return resolve(n->b, pn, l);
        case js::K::array_pat:
        case js::K::object_pat:
        case js::K::rest:
        case js::K::default_:
            return pattern(n, pn, l);
        default:
            for (const js::Node* k : {n->a, n->b, n->c, n->d})
                resolve_list(k, pn, l);
            return;
        }
    }
    void pattern(const js::Node* p, const PendingNode& pn, const Local* l) {
        if (!p)
            return;
        switch (p->kind) {
        case js::K::ident:
            return;
        case js::K::array_pat:
            for (const js::Node* e = p->a; e; e = e->next)
                pattern(e, pn, l);
            return;
        case js::K::object_pat:
            for (const js::Node* e = p->a; e; e = e->next) {
                if (e->kind != js::K::prop) {
                    pattern(e, pn, l);
                    continue;
                }
                if (e->flags & js::f_computed)
                    resolve(e->a, pn, l);
                pattern(e->b, pn, l);
            }
            return;
        case js::K::rest:
            return pattern(p->a, pn, l);
        case js::K::default_:
            pattern(p->a, pn, l);
            return resolve(p->b, pn, l);
        case js::K::paren:
            return pattern(p->a, pn, l);
        default:
            return resolve(p, pn, l);
        }
    }
    void block(const js::Node* stmts, const PendingNode& pn, const Local* l) {
        for (const js::Node* s = stmts; s; s = s->next) {
            if (s->kind == js::K::var && s->op != js::Op::var_)
                for (const js::Node* d = s->a; d; d = d->next)
                    l = declare(d->a, l);
            if (s->kind == js::K::func_decl)
                l = push(s->text, l);
        }
        resolve_list(stmts, pn, l);
    }
    static uint32_t line_of(sv src, uint32_t pos) {
        uint32_t line = 1;
        for (uint32_t k = 0; k < pos && k < src.size(); k++)
            line += src[k] == '\n';
        return line;
    }

    struct Template {
        Inst* list;
        rui::Element* node;
        Scope* sc;
    };
    List<Template> templates;

    void check_templates() {
        for (uint32_t k = 0; k < templates.size; k++) {
            Template t = templates[k];
            out.stats.templates++;
            Scope* sc = new_scope(t.sc->file, t.sc->path, t.sc->uses, t.sc->src);
            if (!sc)
                return;
            sc->ids_up = t.sc;
            sc->root = t.sc->root;
            Pending p;
            bool was = in_template;
            in_template = true;
            create(t.node, t.list, p, sc, Ctx{Ctx::root, nullptr}, nullptr);
            bind_all(p);
            in_template = was;
        }
    }

    void load(sv path, sv name, sv src) {
        top_path = path.empty() ? sv{} : normalize(path);
        auto f = rui::parse(src, arena);
        if (!f) {
            diag(Severity::error, nullptr, name, path, f.error().line, f.error().pos, f.error().msg);
            return;
        }
        rui::File* ast = *f;
        sv base = path.substr(path.rfind('/') == sv::npos ? 0 : path.rfind('/') + 1);
        bool component_file = !base.empty() && base[0] >= 'A' && base[0] <= 'Z';
        List<UseDir> uses;
        for (const rui::Use& u : ast->uses)
            (void)uses.push(arena, UseDir{folder(top_path, u.path), u.as, u.has_as});
        Scope* sc = new_scope(name, top_path, uses, src);
        if (!sc)
            return;
        if (!component_file && ast->root->type != "Dock" && ast->root->type != "Panes") {
            Elem e;
            bool known = rx::schema::elem_of(ast->root->type, &e);
            sv t = ast->root->type;
            diag(Severity::error, sc, name, path, ast->root->line, ast->root->pos,
                 known ? fmt("the top element must be a Dock (or Panes), not %.*s", w(t), t.data())
                       : fmt("the top element must be a Dock (or Panes), not %.*s (a component, %.*s.rui, is used from "
                             "another file)",
                             w(t), t.data(), w(t), t.data()));
            return;
        }
        if (component_file) {
            SlotFill* own = arena.make<SlotFill>();
            rui::Element* none = arena.make<rui::Element>();
            if (!own || !none)
                return;
            *own = SlotFill{none, sc, Ctx{}};
            sc->slot = own;
        }
        Pending pending;
        Inst* root = nullptr;
        create(ast->root, nullptr, pending, sc, Ctx{}, &root);
        sc->root = root;
        if (!root)
            return;
        bind_all(pending);
        check_templates();
        resolve_all();
    }
};

}

const char* class_name(Class c) noexcept {
    static constexpr const char* k[] = {"const", "lang", "alias", "expr", "dynamic", "block", "handler", "function"};
    return static_cast<size_t>(c) < sizeof k / sizeof *k ? k[static_cast<size_t>(c)] : "?";
}

Result check(std::string_view path, std::string_view name, std::string_view src, Reader& reader,
             Arena& arena) noexcept {
    Checker c{arena, reader};
    c.load(path, name, src);
    return c.out;
}

}
