// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/core/doc.h"

#include <cstdio>
#include <cstring>
#include <new>

#include "engine/core/globals.h"
#include "engine/syntax/js.h"
#include "engine/syntax/rui.h"
#include "engine/vm/compile.h"
#include "engine/vm/gc.h"
#include "engine/vm/lib.h"
#include "engine/vm/ops.h"
#include "gen/rx_props.h"

namespace rx::engine::core {

using namespace vm;
namespace sch = rx::schema;

struct Ctx;

namespace {

struct Binding;
struct Deps;
struct Edge {
    Binding* b;
    Deps* list;
    Edge *prev, *next;
    Edge* src_next;
};
struct Deps {
    Edge *head = nullptr, *tail = nullptr;
};

struct Elem;
struct Scope;

struct Binding {
    Elem* obj;
    const Code* code;
    Ctx* ctx;
    const rui::Member* m;
    Edge* sources;
    Binding *dprev, *dnext;
    uint32_t slot;
    uint32_t line : 31;
    uint32_t dirty : 1;
};
static_assert(sizeof(Binding) <= 64);

enum class SK : uint8_t { prop, group, method, function, plain };

struct PSlot {
    Str* name;
    Str* group;
    Str* leaf;
    Value value;
    Binding* binding;
    Deps deps;
    SK kind;
    bool native;
    bool named;
    bool has_value;
    bool assigned;
    bool tpl;
    bool pre;
    bool fired;
};
static_assert(sizeof(PSlot) <= 72);

struct NameInfo {
    Str* name;
    std::string_view text;
    Str* changed;
};

struct Handler {
    Str* name;
    const Code* code;
    Ctx* ctx;
    std::string_view file;
    uint32_t line;
};

struct Tpl {
    Str* name;
    const rui::Element* node;
    Scope* sc;
    Elem* ctx = nullptr;
    bool ctx_set = false;
};

struct TEntry {
    Str *name, *group, *leaf;
    int32_t def;
    SK kind;
    bool native, named;
    bool eager;
};
struct TypeTpl {
    TEntry* e;
    uint32_t n;
    int32_t* index;
    uint32_t cap;
};

struct DeclaredSignal {
    Str* handler;
    std::string_view params;
};

struct Elem {
    Cell h;
    uint32_t uid;
    int16_t type;
    std::string_view type_name;
    Elem* parent;
    List<Elem*> children;
    List<DeclaredSignal> signals;
    TypeTpl* tt;
    PSlot* slots;
    uint32_t n_slots, cap_slots;
    int32_t* index;
    uint32_t index_cap;
    Elem* ctx;
    List<Handler> handlers;
    List<Tpl> templates;
    Str* pane_slot;
    Str* pane_key;
    bool has_pane_key;
    bool alive;
    bool dying;
    bool s_syncing, s_again;
    bool v_named, v_bound, v_syncing, v_again;
    bool v_asked;
    bool k_named;
    uint32_t v_first, v_count, v_total, row;
    std::string_view file;
    uint32_t line;
    std::string_view id;
    std::string_view comp;
};

struct Group {
    Cell h;
    Elem* o;
    Str* group;
};

struct Ids {
    Ids* proto;
    List<Str*> keys;
    List<Elem*> vals;
};

struct UseDir {
    std::string_view dir, as;
};

struct Scope {
    std::string_view src;
    Ids* ids;
    Elem* root;
    std::string_view file;
    std::string_view path;
    List<UseDir> uses;
    std::string_view prefix;
    bool has_prefix;
    bool has_slot;
    bool slotted;
    bool named_slots;
    const rui::Element* slot_node;
    Scope* slot_sc;
    Elem* slot_ctx;
    bool slot_ctx_set;
};

Elem* const k_ctx_root = reinterpret_cast<Elem*>(uintptr_t{1});

struct Pending {
    struct B {
        Elem* obj;
        std::string_view name;
        const rui::Member* m;
        uint32_t line;
        Scope* sc;
        Elem* cx;
        bool cx_set;
    };
    struct N {
        Elem* o;
        const rui::Element* node;
        Scope* sc;
        Elem* cx;
        bool cx_set;
    };
    List<B> bindings;
    List<N> nodes;
    List<Handler> completed;
};

struct Comp {
    std::string_view path, file;
    rui::File* ast;
    List<UseDir> uses;
    bool error;
    uint32_t err_line;
    std::string_view err_msg;
};

struct LoadError {
    bool set = false;
    std::string_view file;
    uint32_t line = 0;
    std::string_view msg;
    List<std::string_view> uses;
};

}

struct Ctx final : Host {
    Impl* doc;
    Elem* o;
    Scope* sc;
    Elem* cx;
    Value get(Rt& rt, Str* name) noexcept override;
    bool set(Rt& rt, Str* name, Value v) noexcept override;
    Value base(Rt& rt, Str* name) noexcept override;
};

std::string_view bfile(const Binding* b) {
    return b->ctx->sc->file;
}

struct NoHost final : Host {
    Value get(Rt&, Str*) noexcept override { return Value::hole(); }
    bool set(Rt& rt, Str* name, Value v) noexcept override { return rt.globals && rt.put(rt.globals, name, v); }
};

struct Impl {
    Sink& sink;
    Arena arena;
    Arena scratch{64 * 1024};
    Arena heap{256 * 1024};
    Arena tmp{64 * 1024};
    Rt rt;
    NoHost nohost;
    Vm vm;
    Doc* self = nullptr;

    Elem* root = nullptr;
    Scope* top_sc = nullptr;
    uint32_t next_uid = 1;
    Binding* current = nullptr;
    bool building = false, flushing = false;
    Binding *dhead = nullptr, *dtail = nullptr;
    List<std::string_view> reported;
    List<Elem*> objs;
    Edge* free_edges = nullptr;
    Doc::Stats stat;

    std::string_view top_path;
    List<Comp*> comps;
    List<std::string_view> using_;
    LoadError err;

    struct CodeEntry {
        const char* key;
        uint32_t extra;
        const Code* code;
    };
    CodeEntry* codes = nullptr;
    uint32_t code_cap = 0, code_count = 0;

    struct Global {
        std::string_view name;
        Elem* o;
    };
    List<Global> globals;

    Str *a_layoutWidth, *a_layoutHeight, *a_contentX, *a_contentY, *a_active, *a_source, *a_ready, *a_loadNow,
        *a_loaderScope, *a_open, *a_lazy, *a_modelKey, *a_status, *a_position, *a_duration, *a_pressed, *a_running,
        *a_cursorPosition, *a_selectionStart, *a_selectionEnd;
    Str *a_model, *a_modelData, *a_index, *a_pane, *a_state, *a_text, *a_visible, *a_delegate, *a_background,
        *a_overlay, *a_message, *a_id, *a_key, *a_preview, *a_list, *a_previews, *a_virtualized, *a_follow;

    Obj* method_table = nullptr;

    char* jbuf = nullptr;
    size_t jcap = 0;

    explicit Impl(Sink& s) noexcept : sink(s), arena(256 * 1024), rt(heap, &arena), vm(rt, nohost) {}

    List<Elem*> all_elems;
    List<Ids*> all_ids;
    List<const Code*> all_codes;
    size_t gc_next = 1u << 20;
    bool gc_always = false;
    uint64_t collections = 0;
    size_t live = 0;
    uint32_t replays = 0;
    bool restoring = false;
    struct Undo {
        uint32_t uid, slot;
        Binding* b;
        std::string_view text;
        bool assigned;
    };
    Undo undos[64];
    uint32_t n_undos = 0;
    List<Value> promises;
    Value delegates[static_cast<int>(globals::Delegate::count_)] = {Value::null(), Value::null(), Value::null()};
    void gc_roots(Gc& gc) noexcept;
    void collect() noexcept;

    Str* atom(std::string_view s) noexcept {
        char16_t u[256];
        if (s.size() > 256)
            return rt.atom(rt.str_ascii(s));
        for (size_t i = 0; i < s.size(); i++)
            u[i] = static_cast<unsigned char>(s[i]);
        return rt.atom(std::u16string_view(u, s.size()));
    }
    Str* prop_atom[static_cast<int>(sch::Prop::count_)] = {};
    Value def_val[sizeof sch::k_prop_defs / sizeof sch::k_prop_defs[0]] = {};
    std::string_view copy(std::string_view s) noexcept { return arena.copy(s); }
    std::string_view cat(std::initializer_list<std::string_view> parts) noexcept { return cat_in(arena, parts); }
    std::string_view tcat(std::initializer_list<std::string_view> parts) noexcept { return cat_in(tmp, parts); }
    std::string_view cat_in(Arena& where, std::initializer_list<std::string_view> parts) noexcept {
        size_t n = 0;
        for (auto p : parts)
            n += p.size();
        char* b = static_cast<char*>(where.alloc(n ? n : 1, 1));
        if (!b)
            return {};
        size_t k = 0;
        for (auto p : parts)
            std::memcpy(b + k, p.data(), p.size()), k += p.size();
        return {b, n};
    }
    std::string_view num8(uint32_t v, Arena* where = nullptr) noexcept {
        char b[16];
        int n = std::snprintf(b, sizeof b, "%u", v);
        return (where ? *where : arena).copy({b, static_cast<size_t>(n)});
    }

    bool init() noexcept;

    Elem* new_elem(int16_t type, std::string_view type_name) noexcept;
    int32_t find_own(const Elem* o, Str* name) const noexcept;
    int32_t find(Elem* o, Str* name) noexcept;
    TypeTpl* ttpl[static_cast<int>(sch::Elem::count_)] = {};
    TypeTpl* type_tpl(int et) noexcept;
    int32_t tpl_find(const TypeTpl* t, Str* name) const noexcept;
    int32_t materialize(Elem* o, uint32_t t) noexcept;
    Value tpl_default(const TEntry& te) noexcept;
    void tpl_rehash(TypeTpl* t) noexcept;
    template<class F>
    void each_slot(Elem* o, F&& f) noexcept;
    int32_t add_slot(Elem* o, Str* name, std::string_view name8 = {}) noexcept;
    NameInfo* names = nullptr;
    uint32_t names_cap = 0, names_count = 0;
    NameInfo* name_info(Str* name, std::string_view text = {}) noexcept;
    bool reindex(Elem* o) noexcept;
    Value get_prop(Elem* o, uint32_t i) noexcept;
    Value elem_get(Elem* o, Str* key) noexcept;
    int32_t group_member(Group* g, Str* leaf) noexcept;
    bool elem_set(Elem* o, Str* key, Value v) noexcept;

    void report(std::string_view file, uint32_t line, Value e) noexcept;
    void report_text(std::string_view file, uint32_t line, std::string_view msg) noexcept;
    void track(Elem* o, uint32_t slot) noexcept;
    void unhook(Binding* b) noexcept;
    void dirty_add(Binding* b) noexcept;
    void dirty_del(Binding* b) noexcept;
    void write(Elem* o, uint32_t slot, Value v, bool from_binding) noexcept;
    void write_name(Elem* o, Str* name, Value v, bool from_binding) noexcept;
    void evaluate(Binding* b) noexcept;
    void flush() noexcept;
    void call(const Handler& h, const Value* args, uint32_t argc) noexcept;
    bool define(Elem* o, std::string_view name, Value initial, bool native, Str* a = nullptr) noexcept;
    Value run(const Code* code, Host* host, const Value* args, uint32_t argc, bool& ok) noexcept;
    void native_set(Elem* o, std::string_view name, Value v) noexcept;
    Value thrown_value() noexcept;
    void end_job() noexcept;

    bool fail(Scope* sc, uint32_t line, std::string_view msg) noexcept;
    std::string_view fmt(const char* f, std::string_view a, std::string_view b = {}, std::string_view c = {}) noexcept;
    Scope* new_scope(std::string_view file, std::string_view path, List<UseDir> uses, bool has_prefix,
                     std::string_view prefix) noexcept;
    Ids* new_ids(Ids* proto) noexcept;
    Elem* id_get(Ids* ids, Str* k) const noexcept;
    bool id_own(Ids* ids, Str* k) const noexcept;
    std::string_view dirname(std::string_view p) noexcept;
    std::string_view normalize(std::string_view p) noexcept;
    std::string_view folder(std::string_view from, std::string_view p) noexcept;
    std::string_view display(std::string_view p) noexcept;
    List<std::string_view> look_in(std::string_view type, Scope* sc) noexcept;
    bool component(std::string_view type, Scope* sc, uint32_t line, Comp*& out) noexcept;
    bool create(const rui::Element* node, Elem* parent, Pending& p, Scope* sc, Elem* ctx, bool ctx_set,
                Elem*& out) noexcept;
    bool members(Elem* o, const rui::Element* node, Pending& p, Scope* sc, Elem* cx, bool cx_set) noexcept;
    bool instance(const rui::Element* node, Elem* parent, Pending& p, Scope* sc, Elem* ctx, bool ctx_set,
                  Elem*& out) noexcept;
    bool wire(Elem* o, const rui::Element* node, Scope* sc, Pending& p, Elem* cx, bool cx_set) noexcept;
    bool bind_all(Pending& p) noexcept;
    Ctx* ctx_for(Elem* o, Scope* sc, Elem* cx, bool cx_set) noexcept;
    bool unit(std::string_view src, const char* key, uint32_t pos, uint32_t len, js::Goal goal,
              const std::string_view* params, uint32_t n_params, Scope* sc, uint32_t line, const Code*& out) noexcept;
    bool function(std::string_view src, const rui::Function& f, Scope* sc, const Code*& out) noexcept;
    bool signal_params(Elem* o, std::string_view name, std::string_view& params) noexcept;

    void sync(Elem* list) noexcept;
    bool virtualized(Elem* list) noexcept;
    void sync_window(Elem* list, bool model_changed) noexcept;
    void sync_panes(Elem* o) noexcept;
    bool sync_keyed(Elem* list, Arr* a) noexcept;
    Str* row_key(Elem* list, Value key, Value item, uint32_t i) noexcept;
    const rui::Element* use_of = nullptr;
    void instantiate(Elem* list, uint32_t i, Value data, Str* which) noexcept;
    void destroy(Elem* o) noexcept;
    void destroy_past(Elem* o, uint32_t keep) noexcept;
    void sync_rows(Elem* list) noexcept;
    void loader_write(Elem* o, Str* name, Value v) noexcept;
    void loader_clear(Elem* o) noexcept;
    void loader_make(Elem* o) noexcept;
    void drawer_build(Elem* o) noexcept;
    Value entries(Value model) noexcept;
    Str* pane_key(Value p) noexcept;
    Tpl* tpl(Elem* o, Str* name) noexcept;

    std::string_view load(std::string_view src, std::string_view name, std::string_view path) noexcept;
    Elem* obj(uint32_t uid) noexcept { return uid < objs.size ? objs[uid] : nullptr; }
    void emit(uint32_t uid, std::string_view signal, const Value* args, uint32_t argc) noexcept;
    bool key_heard(uint32_t uid, std::string_view signal, const Value* args, uint32_t argc) noexcept;
    NativeFn signal_method() noexcept;
    bool changes(Value cur, Value patch) noexcept;
    Value json_parse(std::string_view text, bool& ok) noexcept;
    std::string_view json(Value v) noexcept;
    Elem* global(std::string_view name, std::string_view json_initial) noexcept;
    void set_global(Elem* g, Value t) noexcept;
    bool install_globals() noexcept;
};

namespace {

Impl* doc_of(Rt& rt) {
    return static_cast<Impl*>(rt.user);
}

std::string_view ascii(Arena& a, const Str* s) {
    char* b = static_cast<char*>(a.alloc(s->length ? s->length : 1, 1));
    if (!b)
        return {};
    for (uint32_t i = 0; i < s->length; i++)
        b[i] = static_cast<char>(s->units[i] < 0x80 ? s->units[i] : '?');
    return {b, s->length};
}

size_t utf8(std::u16string_view s, char* out) {
    size_t k = 0;
    for (size_t i = 0; i < s.size(); i++) {
        uint32_t c = s[i];
        if (c >= 0xD800 && c < 0xDC00 && i + 1 < s.size() && s[i + 1] >= 0xDC00 && s[i + 1] < 0xE000)
            c = 0x10000 + ((c - 0xD800) << 10) + (s[++i] - 0xDC00u);
        else if (c >= 0xD800 && c < 0xE000)
            c = 0xFFFD;
        if (c < 0x80)
            out[k++] = static_cast<char>(c);
        else if (c < 0x800)
            out[k++] = static_cast<char>(0xC0 | c >> 6), out[k++] = static_cast<char>(0x80 | (c & 63));
        else if (c < 0x10000)
            out[k++] = static_cast<char>(0xE0 | c >> 12), out[k++] = static_cast<char>(0x80 | (c >> 6 & 63)),
            out[k++] = static_cast<char>(0x80 | (c & 63));
        else
            out[k++] = static_cast<char>(0xF0 | c >> 18), out[k++] = static_cast<char>(0x80 | (c >> 12 & 63)),
            out[k++] = static_cast<char>(0x80 | (c >> 6 & 63)), out[k++] = static_cast<char>(0x80 | (c & 63));
    }
    return k;
}

bool is_list_type(int16_t t) {
    return t == static_cast<int16_t>(sch::Elem::List) || t == static_cast<int16_t>(sch::Elem::Grid)
        || t == static_cast<int16_t>(sch::Elem::Stack) || t == static_cast<int16_t>(sch::Elem::Panes);
}

bool starts(std::string_view s, std::string_view p) {
    return s.substr(0, p.size()) == p;
}

}

Elem* Impl::new_elem(int16_t type, std::string_view type_name) noexcept {
    Elem* o = arena.make<Elem>();
    if (!o)
        return nullptr;
    o->h = Cell{0, Kind::element, 0, 0};
    o->type = type;
    o->type_name = type_name;
    o->alive = true;
    return all_elems.push(arena, o) ? o : nullptr;
}

int32_t Impl::find(Elem* o, Str* name) noexcept {
    int32_t i = find_own(o, name);
    if (i >= 0 || !o->tt)
        return i;
    int32_t t = tpl_find(o->tt, name);
    return t < 0 ? -1 : materialize(o, static_cast<uint32_t>(t));
}

int32_t Impl::tpl_find(const TypeTpl* t, Str* name) const noexcept {
    uint32_t m = t->cap - 1;
    for (uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(name) >> 4) & m;; h = (h + 1) & m) {
        int32_t i = t->index[h];
        if (i < 0)
            return -1;
        if (t->e[i].name == name)
            return i;
    }
}

void Impl::tpl_rehash(TypeTpl* t) noexcept {
    uint32_t m = t->cap - 1;
    for (uint32_t k = 0; k <= m; k++)
        t->index[k] = -1;
    for (uint32_t i = 0; i < t->n; i++) {
        uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(t->e[i].name) >> 4) & m;
        while (t->index[h] >= 0)
            h = (h + 1) & m;
        t->index[h] = static_cast<int32_t>(i);
    }
}

TypeTpl* Impl::type_tpl(int et) noexcept {
    if (ttpl[et])
        return ttpl[et];
    sch::Span sp = sch::k_elem_props[et], ms = sch::k_elem_methods[et];
    TypeTpl* t = arena.make<TypeTpl>();
    TEntry* e = arena.array<TEntry>(sp.count * 2 + ms.count + 1);
    if (!t || !e)
        return nullptr;
    uint32_t n = 0;
    auto have = [&](Str* a) {
        for (uint32_t k = 0; k < n; k++)
            if (e[k].name == a)
                return true;
        return false;
    };
    for (uint32_t k = sp.first; k < sp.first + sp.count; k++) {
        const sch::PropDef& d = sch::k_prop_defs[k];
        int pi = static_cast<int>(d.prop);
        Str* a = prop_atom[pi];
        if (have(a))
            continue;
        std::string_view name = sch::k_props[pi].name;
        size_t dot = name.find('.');
        Str* g = dot == std::string_view::npos ? nullptr : atom(name.substr(0, dot));
        Str* leaf = g ? atom(name.substr(dot + 1)) : nullptr;
        e[n++] = TEntry{a,        g,     leaf,         static_cast<int32_t>(k),
                        SK::prop, !d.js, g == nullptr, a == a_model && is_list_type(static_cast<int16_t>(et))};
        if (g && !have(g))
            e[n++] = TEntry{g, nullptr, nullptr, -1, SK::group, false, true, false};
    }
    for (uint32_t k = ms.first; k < ms.first + ms.count; k++) {
        Str* a = atom(sch::k_methods[k]);
        if (!have(a))
            e[n++] = TEntry{a, nullptr, nullptr, -1, SK::method, false, true, false};
    }
    uint32_t cap = 16;
    while (cap < n * 2 + 2)
        cap *= 2;
    t->index = arena.array<int32_t>(cap);
    if (!t->index)
        return nullptr;
    t->e = e, t->n = n, t->cap = cap;
    tpl_rehash(t);
    return ttpl[et] = t;
}

Value Impl::tpl_default(const TEntry& te) noexcept {
    const sch::PropDef& d = sch::k_prop_defs[te.def];
    if (d.def == sch::Def::fresh)
        return d.json == "[]" ? val(rt.array(0)) : val(rt.object());
    return def_val[te.def];
}

int32_t Impl::materialize(Elem* o, uint32_t t) noexcept {
    const TEntry& te = o->tt->e[t];
    int32_t i =
        add_slot(o, te.name,
                 te.def >= 0 ? sch::k_props[static_cast<int>(sch::k_prop_defs[te.def].prop)].name : std::string_view{});
    if (i < 0)
        return -1;
    PSlot& s = o->slots[i];
    s.kind = te.kind;
    s.named = te.named;
    s.native = te.native;
    s.tpl = true;
    if (te.kind == SK::prop) {
        s.has_value = true;
        s.value = tpl_default(te);
        if (te.name == a_layoutWidth || te.name == a_layoutHeight)
            native_set(o, "wantsLayout", Value::boolean(true));
        else if (te.name == a_contentX || te.name == a_contentY)
            native_set(o, "wantsScroll", Value::boolean(true));
        else if (te.name == a_cursorPosition || te.name == a_selectionStart || te.name == a_selectionEnd)
            native_set(o, "wantsCursor", Value::boolean(true));
        else if ((te.name == a_status || te.name == a_position || te.name == a_duration)
                 && (o->type == static_cast<int16_t>(sch::Elem::Image)
                     || o->type == static_cast<int16_t>(sch::Elem::Video)))
            native_set(o, "wantsStatus", Value::boolean(true));
        else if (te.name == a_pressed && o->type == static_cast<int16_t>(sch::Elem::Button))
            native_set(o, "wantsPressed", Value::boolean(true));
    } else if (te.kind == SK::method) {
        s.value = rt.get_own(method_table, te.name);
    } else {
        Group* gc = arena.make<Group>();
        if (!gc)
            return -1;
        gc->h = Cell{0, Kind::group, 0, 0};
        gc->o = o;
        gc->group = te.name;
        o->slots[i].value = Value::cell(&gc->h);
    }
    return i;
}

template<class F>
void Impl::each_slot(Elem* o, F&& f) noexcept {
    for (uint32_t i = 0; i < o->n_slots; i++)
        if (o->slots[i].pre)
            f(&o->slots[i], static_cast<const TEntry*>(nullptr));
    if (o->tt)
        for (uint32_t t = 0; t < o->tt->n; t++) {
            const TEntry& te = o->tt->e[t];
            int32_t i = find_own(o, te.name);
            if (i >= 0 && o->slots[i].pre)
                continue;
            f(i >= 0 ? &o->slots[i] : nullptr, &te);
        }
    for (uint32_t i = 0; i < o->n_slots; i++)
        if (!o->slots[i].pre && !o->slots[i].tpl)
            f(&o->slots[i], static_cast<const TEntry*>(nullptr));
}

int32_t Impl::find_own(const Elem* o, Str* name) const noexcept {
    if (!o->index_cap)
        return -1;
    uint32_t m = o->index_cap - 1;
    for (uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(name) >> 4) & m;; h = (h + 1) & m) {
        int32_t i = o->index[h];
        if (i < 0)
            return -1;
        if (o->slots[i].name == name)
            return i;
    }
}

bool Impl::reindex(Elem* o) noexcept {
    uint32_t cap = 16;
    while (cap < o->n_slots * 2 + 2)
        cap *= 2;
    int32_t* ix = arena.array<int32_t>(cap);
    if (!ix)
        return false;
    for (uint32_t k = 0; k < cap; k++)
        ix[k] = -1;
    for (uint32_t i = 0; i < o->n_slots; i++) {
        uint32_t m = cap - 1;
        uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(o->slots[i].name) >> 4) & m;
        while (ix[h] >= 0)
            h = (h + 1) & m;
        ix[h] = static_cast<int32_t>(i);
    }
    o->index = ix;
    o->index_cap = cap;
    return true;
}

NameInfo* Impl::name_info(Str* name, std::string_view text) noexcept {
    auto slot = [](Str* n, uint32_t cap) {
        return static_cast<uint32_t>(reinterpret_cast<uintptr_t>(n) >> 4) & (cap - 1);
    };
    if (names_cap) {
        for (uint32_t h = slot(name, names_cap); names[h].name; h = (h + 1) & (names_cap - 1))
            if (names[h].name == name)
                return &names[h];
    }
    if ((names_count + 1) * 2 > names_cap) {
        uint32_t cap = names_cap ? names_cap * 2 : 512;
        NameInfo* t = arena.array<NameInfo>(cap);
        if (!t)
            return nullptr;
        for (uint32_t i = 0; i < names_cap; i++)
            if (names[i].name) {
                uint32_t h = slot(names[i].name, cap);
                while (t[h].name)
                    h = (h + 1) & (cap - 1);
                t[h] = names[i];
            }
        names = t, names_cap = cap;
    }
    uint32_t h = slot(name, names_cap);
    while (names[h].name)
        h = (h + 1) & (names_cap - 1);
    names[h] = NameInfo{name, text.empty() ? ascii(arena, name) : text, nullptr};
    names_count++;
    return &names[h];
}

int32_t Impl::add_slot(Elem* o, Str* name, std::string_view name8) noexcept {
    if (o->n_slots == o->cap_slots) {
        uint32_t n = o->cap_slots ? o->cap_slots * 2 : 32;
        PSlot* s = arena.array<PSlot>(n);
        if (!s)
            return -1;
        if (o->n_slots)
            std::memcpy(static_cast<void*>(s), o->slots, sizeof(PSlot) * o->n_slots);
        for (uint32_t i = 0; i < o->n_slots; i++)
            for (Edge* e = s[i].deps.head; e; e = e->next)
                e->list = &s[i].deps;
        o->slots = s;
        o->cap_slots = n;
    }
    uint32_t i = o->n_slots++;
    PSlot& p = o->slots[i];
    p = PSlot{};
    p.name = name;
    p.value = Value::undefined();
    if (!name_info(name, name8))
        return -1;
    for (uint32_t k = 0; k < name->length; k++)
        if (name->units[k] == '.') {
            p.group = rt.atom(std::u16string_view(name->units, k));
            p.leaf = rt.atom(std::u16string_view(name->units + k + 1, name->length - k - 1));
            break;
        }
    if (o->n_slots * 2 + 2 > o->index_cap) {
        if (!reindex(o))
            return -1;
    } else {
        uint32_t m = o->index_cap - 1;
        uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(name) >> 4) & m;
        while (o->index[h] >= 0)
            h = (h + 1) & m;
        o->index[h] = static_cast<int32_t>(i);
    }
    return static_cast<int32_t>(i);
}

Value Impl::get_prop(Elem* o, uint32_t i) noexcept {
    Binding* b = o->slots[i].binding;
    if (b && flushing && b->dirty) {
        dirty_del(b);
        evaluate(b);
    }
    track(o, i);
    return o->slots[i].value;
}

Value Impl::elem_get(Elem* o, Str* key) noexcept {
    int32_t i = find(o, key);
    if (i >= 0) {
        PSlot& s = o->slots[i];
        if (s.kind == SK::prop)
            return s.named ? get_prop(o, static_cast<uint32_t>(i)) : Value::undefined();
        return s.value;
    }
    std::u16string_view k = key->view();
    if (k == u"parent")
        return o->parent ? Value::cell(&o->parent->h) : Value::null();
    if (k == u"children") {
        Arr* a = rt.array(o->children.size);
        if (!a)
            return Value::undefined();
        for (Elem* c : o->children)
            rt.push(a, Value::cell(&c->h));
        return val(a);
    }
    if (k == u"__uid")
        return Value::num(o->uid);
    if (k == u"__type")
        return val(rt.str_ascii(o->type_name));
    return Value::undefined();
}

int32_t Impl::group_member(Group* g, Str* leaf) noexcept {
    Elem* o = g->o;
    for (uint32_t i = 0; i < o->n_slots; i++)
        if (o->slots[i].group == g->group && o->slots[i].leaf == leaf && o->slots[i].kind == SK::prop)
            return static_cast<int32_t>(i);
    if (o->tt)
        for (uint32_t t = 0; t < o->tt->n; t++) {
            const TEntry& te = o->tt->e[t];
            if (te.group == g->group && te.leaf == leaf && te.kind == SK::prop)
                return find(o, te.name);
        }
    return -1;
}

bool Impl::elem_set(Elem* o, Str* key, Value v) noexcept {
    int32_t i = find(o, key);
    if (i >= 0) {
        PSlot& s = o->slots[i];
        if (s.kind == SK::prop && s.named)
            write(o, static_cast<uint32_t>(i), v, false);
        else if (s.kind == SK::plain)
            s.value = v;
        return true;
    }
    std::u16string_view k = key->view();
    if (k == u"parent" || k == u"children" || k.substr(0, 2) == u"__")
        return true;
    i = add_slot(o, key);
    if (i < 0)
        return false;
    o->slots[i].kind = SK::plain;
    o->slots[i].value = v;
    return true;
}

namespace {

Value hook_get(Rt& rt, Value obj, Str* key) noexcept {
    Impl* d = doc_of(rt);
    if (obj.is(Kind::element))
        return d->elem_get(obj.as<Elem>(), key);
    Group* g = obj.as<Group>();
    int32_t i = d->group_member(g, key);
    return i >= 0 ? d->get_prop(g->o, static_cast<uint32_t>(i)) : Value::undefined();
}

bool hook_set(Rt& rt, Value obj, Str* key, Value v) noexcept {
    Impl* d = doc_of(rt);
    if (obj.is(Kind::element))
        return d->elem_set(obj.as<Elem>(), key, v);
    Group* g = obj.as<Group>();
    int32_t i = d->group_member(g, key);
    if (i >= 0)
        d->write(g->o, static_cast<uint32_t>(i), v, false);
    return true;
}

Arr* hook_keys(Rt& rt, Value obj) noexcept {
    Arr* out = rt.array(0);
    if (!out)
        return nullptr;
    Impl* d = doc_of(rt);
    if (obj.is(Kind::element)) {
        d->each_slot(obj.as<Elem>(), [&](const PSlot* s, const TEntry* te) {
            if (s ? (s->kind == SK::prop && s->named && !s->group) || s->kind == SK::plain
                  : te->kind == SK::prop && te->named)
                rt.push(out, val(s ? s->name : te->name));
        });
    } else {
        Group* g = obj.as<Group>();
        d->each_slot(g->o, [&](const PSlot* s, const TEntry* te) {
            if (s ? s->group == g->group : te->group == g->group)
                rt.push(out, val(s ? s->leaf : te->leaf));
        });
    }
    return out;
}

const ObjHooks k_hooks{hook_get, hook_set, hook_keys};

}

Value Ctx::get(Rt&, Str* k) noexcept {
    if (Elem* e = doc->id_get(sc->ids, k))
        return Value::cell(&e->h);
    if (k->view() == u"parent")
        return o->parent ? Value::cell(&o->parent->h) : Value::null();
    int32_t i = doc->find(o, k);
    if (i >= 0 && o->slots[i].named)
        return doc->elem_get(o, k);
    if (cx && (i = doc->find(cx, k)) >= 0 && cx->slots[i].named)
        return doc->elem_get(cx, k);
    Elem* top = sc->root;
    if (top && (i = doc->find(top, k)) >= 0 && top->slots[i].named)
        return doc->elem_get(top, k);
    return Value::hole();
}

Value Ctx::base(Rt&, Str* k) noexcept {
    if (doc->id_get(sc->ids, k) || k->view() == u"parent")
        return Value::undefined();
    for (Elem* e : {o, cx, sc->root}) {
        int32_t i = e ? doc->find(e, k) : -1;
        if (i >= 0 && e->slots[i].named)
            return e->slots[i].kind == SK::method ? Value::cell(&e->h) : Value::undefined();
    }
    return Value::undefined();
}

bool Ctx::set(Rt& rt, Str* k, Value v) noexcept {
    int32_t i = doc->find(o, k);
    if (i >= 0 && o->slots[i].named)
        return doc->elem_set(o, k, v);
    if (cx && (i = doc->find(cx, k)) >= 0 && cx->slots[i].named)
        return doc->elem_set(cx, k, v);
    Elem* top = sc->root;
    if (top && (i = doc->find(top, k)) >= 0 && top->slots[i].named)
        return doc->elem_set(top, k, v);
    return rt.globals && rt.put(rt.globals, k, v);
}

Ctx* Impl::ctx_for(Elem* o, Scope* sc, Elem* cx, bool cx_set) noexcept {
    void* p = arena.alloc(sizeof(Ctx), alignof(Ctx));
    if (!p)
        return nullptr;
    Ctx* c = new (p) Ctx();
    c->doc = this;
    c->o = o;
    c->sc = sc;
    c->cx = cx_set ? cx : o->ctx;
    return c;
}

Ids* Impl::new_ids(Ids* proto) noexcept {
    Ids* i = arena.make<Ids>();
    if (i)
        i->proto = proto;
    return i && all_ids.push(arena, i) ? i : nullptr;
}

Elem* Impl::id_get(Ids* ids, Str* k) const noexcept {
    for (; ids; ids = ids->proto)
        for (uint32_t i = 0; i < ids->keys.size; i++)
            if (ids->keys[i] == k)
                return ids->vals[i];
    return nullptr;
}

bool Impl::id_own(Ids* ids, Str* k) const noexcept {
    for (uint32_t i = 0; i < ids->keys.size; i++)
        if (ids->keys[i] == k)
            return true;
    return false;
}

void Impl::report_text(std::string_view file, uint32_t line, std::string_view msg) noexcept {
    std::string_view whole = tcat({file, ":", num8(line, &tmp), ": ", msg});
    for (std::string_view r : reported)
        if (r == whole)
            return;
    whole = copy(whole);
    if (!reported.push(arena, whole))
        return;
    sink.log(whole, "error");
}

void Impl::report(std::string_view file, uint32_t line, Value e) noexcept {
    Value m = Value::undefined();
    rt.clear();
    if (e.is_cell() && !e.is(Kind::string))
        m = get(rt, e, atom("message"));
    if (rt.failed || !to_boolean(m))
        m = e, rt.clear();
    Str* s = to_string(rt, m);
    if (!s)
        s = rt.str_ascii("(an error)"), rt.clear();
    char* b = static_cast<char*>(tmp.alloc(s->length * 3 + 1, 1));
    if (!b)
        return;
    report_text(file, line, {b, utf8(s->view(), b)});
}

void Impl::track(Elem* o, uint32_t slot) noexcept {
    if (!current)
        return;
    Deps* list = &o->slots[slot].deps;
    for (Edge* e = current->sources; e; e = e->src_next)
        if (e->list == list)
            return;
    Edge* e = free_edges;
    if (e)
        free_edges = e->src_next;
    else if (!(e = arena.make<Edge>()))
        return;
    e->b = current;
    e->list = list;
    e->prev = list->tail;
    e->next = nullptr;
    if (list->tail)
        list->tail->next = e;
    else
        list->head = e;
    list->tail = e;
    e->src_next = current->sources;
    current->sources = e;
}

void Impl::unhook(Binding* b) noexcept {
    for (Edge *e = b->sources, *nx; e; e = nx) {
        nx = e->src_next;
        Deps* l = e->list;
        if (e->prev)
            e->prev->next = e->next;
        else
            l->head = e->next;
        if (e->next)
            e->next->prev = e->prev;
        else
            l->tail = e->prev;
        e->src_next = free_edges;
        free_edges = e;
    }
    b->sources = nullptr;
    dirty_del(b);
}

void Impl::dirty_add(Binding* b) noexcept {
    if (b->dirty)
        return;
    b->dirty = true;
    b->dnext = nullptr;
    b->dprev = dtail;
    if (dtail)
        dtail->dnext = b;
    else
        dhead = b;
    dtail = b;
}

void Impl::dirty_del(Binding* b) noexcept {
    if (!b->dirty)
        return;
    b->dirty = false;
    if (b->dprev)
        b->dprev->dnext = b->dnext;
    else
        dhead = b->dnext;
    if (b->dnext)
        b->dnext->dprev = b->dprev;
    else
        dtail = b->dprev;
    b->dprev = b->dnext = nullptr;
}

void Impl::native_set(Elem* o, std::string_view name, Value v) noexcept {
    sink.set(*self, o->uid, name, v);
}

void Impl::write(Elem* o, uint32_t i, Value v, bool from_binding) noexcept {
    PSlot* s = &o->slots[i];
    if (!from_binding && s->binding) {
        unhook(s->binding);
        s->binding = nullptr;
    }
    if (!from_binding)
        s->assigned = true;
    Value old = s->value;
    bool object = v.is_cell() && !v.is(Kind::string) && !v.is(Kind::function) && !v.is(Kind::native);
    if (strict_equals(old, v) && !object) {
        if (s->name == a_virtualized && o->type == static_cast<int16_t>(sch::Elem::List) && !o->v_bound)
            o->v_bound = true, sync(o);
        return;
    }
    if (old.is_num() && v.is_num() && old.as_num() != old.as_num() && v.as_num() != v.as_num())
        return;
    s->has_value = true;
    s->value = v;
    if (s->native)
        native_set(o, name_info(s->name)->text, v);
    if (o->type == static_cast<int16_t>(sch::Elem::Loader)
        && (s->name == a_active || s->name == a_source || s->name == a_loadNow)) {
        Str* name = s->name;
        loader_write(o, name, v);
        s = &o->slots[i];
    } else if (o->type == static_cast<int16_t>(sch::Elem::Drawer) && s->name == a_open && to_boolean(v)) {
        drawer_build(o);
        s = &o->slots[i];
    } else if ((s->name == a_model || s->name == a_modelKey) && is_list_type(o->type)) {
        sync(o);
        s = &o->slots[i];
    } else if (s->name == a_virtualized && o->type == static_cast<int16_t>(sch::Elem::List)) {
        o->v_bound = true;
        sync(o);
        s = &o->slots[i];
    } else if (s->name == a_follow && o->type == static_cast<int16_t>(sch::Elem::List) && to_boolean(v) && !o->v_asked
               && o->v_count && !o->v_first && o->v_total > o->v_count && virtualized(o)) {
        o->v_first = o->v_total - o->v_count;
        sync_window(o, false);
        s = &o->slots[i];
    }
    for (Edge* e = s->deps.head; e; e = e->next)
        dirty_add(e->b);
    if (!s->group && !building && o->handlers.size) {
        NameInfo* ni = name_info(s->name);
        if (!ni->changed) {
            std::string_view n = ni->text;
            char buf[192];
            if (n.empty() || n.size() + 10 > sizeof buf)
                return flush();
            size_t k = 0;
            buf[k++] = 'o', buf[k++] = 'n';
            buf[k++] = static_cast<char>(n[0] >= 'a' && n[0] <= 'z' ? n[0] - 32 : n[0]);
            std::memcpy(buf + k, n.data() + 1, n.size() - 1), k += n.size() - 1;
            std::memcpy(buf + k, "Changed", 7), k += 7;
            ni->changed = atom({buf, k});
        }
        Str* hn = ni->changed;
        const bool initial = !s->fired;
        bool ran = false;
        for (uint32_t k = 0; k < o->handlers.size; k++)
            if (o->handlers[k].name == hn) {
                Value first = Value::boolean(initial);
                ran = true;
                call(o->handlers[k], &first, 1);
            }
        if (ran)
            o->slots[i].fired = true;
    }
    flush();
}

void Impl::write_name(Elem* o, Str* name, Value v, bool from_binding) noexcept {
    int32_t i = find(o, name);
    if (i < 0) {
        i = add_slot(o, name);
        if (i < 0)
            return;
    }
    write(o, static_cast<uint32_t>(i), v, from_binding);
}

Value Impl::thrown_value() noexcept {
    Value e = rt.thrown;
    if (e.is_undefined() && rt.message)
        e = val(rt.message);
    return e;
}

Value Impl::run(const Code* code, Host* host, const Value* args, uint32_t argc, bool& ok) noexcept {
    rt.clear();
    Value v = vm.run(code, args, argc, host);
    ok = !rt.failed;
    return v;
}

void Impl::evaluate(Binding* b) noexcept {
    stat.evals++;
    unhook(b);
    Binding* prev = current;
    current = b;
    bool ok;
    Value v = run(b->code, b->ctx, nullptr, 0, ok);
    current = prev;
    if (!ok) {
        Value e = thrown_value();
        rt.clear();
        report(bfile(b), b->line, e);
        return;
    }
    write(b->obj, b->slot, v, true);
}

void Impl::flush() noexcept {
    if (building || flushing)
        return;
    flushing = true;
    uint32_t count = 0;
    while (dhead) {
        Binding* b = dhead;
        dirty_del(b);
        if (++count > 100000) {
            report_text(bfile(b), b->line, cat({"binding loop on ", name_info(b->obj->slots[b->slot].name)->text}));
            while (dhead)
                dirty_del(dhead);
            break;
        }
        evaluate(b);
    }
    flushing = false;
}

void Impl::call(const Handler& h, const Value* args, uint32_t argc) noexcept {
    Binding* prev = current;
    current = nullptr;
    bool ok;
    run(h.code, h.ctx, args, argc, ok);
    if (!ok) {
        Value e = thrown_value();
        rt.clear();
        report(h.file, h.line, e);
    }
    current = prev;
    flush();
}

bool Impl::define(Elem* o, std::string_view name, Value initial, bool native, Str* a) noexcept {
    if (!a)
        a = atom(name);
    int32_t i = find(o, a);
    if (i < 0)
        i = add_slot(o, a, name);
    if (i < 0)
        return false;
    PSlot& s = o->slots[i];
    s.kind = SK::prop;
    if (s.group) {
        int32_t g = find(o, s.group);
        if (g < 0) {
            Group* gc = arena.make<Group>();
            if (!gc)
                return false;
            gc->h = Cell{0, Kind::group, 0, 0};
            gc->o = o;
            gc->group = o->slots[i].group;
            Str* gname = o->slots[i].group;
            g = add_slot(o, gname);
            if (g < 0)
                return false;
            o->slots[g].kind = SK::group;
            o->slots[g].value = Value::cell(&gc->h);
            o->slots[g].named = true;
        }
    } else {
        o->slots[i].named = true;
    }
    o->slots[i].native = native;
    o->slots[i].value = Value::undefined();
    o->slots[i].has_value = true;
    write(o, static_cast<uint32_t>(i), initial, true);
    return true;
}

void Impl::end_job() noexcept {
    if (replays > 1 || restoring)
        return;
    lib::drain_jobs(vm);
    rt.clear();
    tmp.reset();
    if (gc_always || heap.used() > gc_next)
        collect();
}

namespace {
void gc_code(const Code* c, Gc& gc) {
    Code* m = const_cast<Code*>(c);
    m->name = gc.of(m->name);
    gc.forward_values(const_cast<Value*>(m->consts), m->n_consts);
    for (uint32_t i = 0; i < m->n_children; i++)
        gc_code(m->children[i], gc);
}
}

void Impl::gc_roots(Gc& gc) noexcept {
    rt.gc_roots(gc);
    for (Elem* e : all_elems) {
        for (uint32_t i = 0; i < e->n_slots; i++) {
            PSlot& sl = e->slots[i];
            sl.name = gc.of(sl.name), sl.group = gc.of(sl.group), sl.leaf = gc.of(sl.leaf);
            sl.value = gc.value(sl.value);
            if (sl.kind == SK::group && sl.value.is(Kind::group)) {
                Group* g = sl.value.as<Group>();
                g->group = gc.of(g->group);
            }
        }
        e->pane_slot = gc.of(e->pane_slot);
        e->pane_key = gc.of(e->pane_key);
        for (Handler& h : e->handlers)
            h.name = gc.of(h.name);
        for (Tpl& t : e->templates)
            t.name = gc.of(t.name);
    }
    for (Ids* ids : all_ids)
        for (Str*& k : ids->keys)
            k = gc.of(k);
    for (uint32_t i = 0; i < names_cap; i++)
        if (names[i].name)
            names[i].name = gc.of(names[i].name), names[i].changed = gc.of(names[i].changed);
    for (TypeTpl* t : ttpl)
        if (t)
            for (uint32_t i = 0; i < t->n; i++)
                t->e[i].name = gc.of(t->e[i].name), t->e[i].group = gc.of(t->e[i].group),
                t->e[i].leaf = gc.of(t->e[i].leaf);
    for (Str*& a : prop_atom)
        a = gc.of(a);
    for (Value& v : def_val)
        v = gc.value(v);
    method_table = gc.of(method_table);
    for (Str** a : {&a_layoutWidth,    &a_layoutHeight, &a_contentX,    &a_contentY,  &a_active,     &a_source,
                    &a_ready,          &a_loadNow,      &a_loaderScope, &a_open,      &a_lazy,       &a_modelKey,
                    &a_status,         &a_position,     &a_duration,    &a_pressed,   &a_running,    &a_cursorPosition,
                    &a_selectionStart, &a_selectionEnd, &a_model,       &a_modelData, &a_index,      &a_pane,
                    &a_state,          &a_text,         &a_visible,     &a_delegate,  &a_background, &a_overlay,
                    &a_message,        &a_id,           &a_key,         &a_preview,   &a_list,       &a_previews,
                    &a_virtualized,    &a_follow})
        *a = gc.of(*a);
    for (const Code* c : all_codes)
        gc_code(c, gc);
    for (Value& v : promises)
        v = gc.value(v);
    for (Value& v : delegates)
        v = gc.value(v);
}

void Impl::collect() noexcept {
    Arena to(256 * 1024), gtmp(256 * 1024);
    Gc gc(rt, heap, to, gtmp);
    if (gc.failed)
        return;
    gc_roots(gc);
    gc.finish();
    if (gc.failed) {
        sink.log("rexui engine: out of memory while compacting a document's heap", "error");
        if (Arena* keep = new (std::nothrow) Arena(64))
            keep->swap(to);
        return;
    }
    vm.native = nullptr;
    heap.swap(to);
    for (Elem* e : all_elems)
        if (e->index_cap) {
            uint32_t m = e->index_cap - 1;
            for (uint32_t k = 0; k <= m; k++)
                e->index[k] = -1;
            for (uint32_t i = 0; i < e->n_slots; i++) {
                uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(e->slots[i].name) >> 4) & m;
                while (e->index[h] >= 0)
                    h = (h + 1) & m;
                e->index[h] = static_cast<int32_t>(i);
            }
        }
    for (TypeTpl* t : ttpl)
        if (t)
            tpl_rehash(t);
    if (names_cap) {
        NameInfo* old = gtmp.array<NameInfo>(names_cap);
        if (old) {
            std::memcpy(static_cast<void*>(old), names, sizeof(NameInfo) * names_cap);
            for (uint32_t i = 0; i < names_cap; i++)
                names[i] = NameInfo{};
            for (uint32_t i = 0; i < names_cap; i++)
                if (old[i].name) {
                    uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(old[i].name) >> 4) & (names_cap - 1);
                    while (names[h].name)
                        h = (h + 1) & (names_cap - 1);
                    names[h] = old[i];
                }
        }
    }
    collections++;
    live = heap.used();
    gc_next = live * 2 > (1u << 20) ? live * 2 : (1u << 20);
}

bool Impl::fail(Scope* sc, uint32_t line, std::string_view msg) noexcept {
    if (err.set)
        return false;
    err.set = true;
    err.file = sc ? sc->file : std::string_view{};
    err.line = line;
    err.msg = copy(msg);
    return false;
}

std::string_view Impl::fmt(const char* f, std::string_view a, std::string_view b, std::string_view c) noexcept {
    size_t n = std::strlen(f) + a.size() + b.size() + c.size();
    char* out = static_cast<char*>(arena.alloc(n + 1, 1));
    if (!out)
        return {};
    size_t k = 0;
    for (const char* p = f; *p; p++) {
        if (*p == '%' && (p[1] == 'a' || p[1] == 'b' || p[1] == 'c')) {
            std::string_view x = p[1] == 'a' ? a : p[1] == 'b' ? b : c;
            std::memcpy(out + k, x.data(), x.size()), k += x.size();
            p++;
        } else {
            out[k++] = *p;
        }
    }
    return {out, k};
}

Scope* Impl::new_scope(std::string_view file, std::string_view path, List<UseDir> uses, bool has_prefix,
                       std::string_view prefix) noexcept {
    Scope* sc = arena.make<Scope>();
    if (!sc)
        return nullptr;
    sc->ids = new_ids(nullptr);
    sc->file = file;
    sc->path = path;
    sc->uses = uses;
    sc->has_prefix = has_prefix;
    sc->prefix = prefix;
    return sc->ids ? sc : nullptr;
}

std::string_view Impl::dirname(std::string_view p) noexcept {
    size_t k = p.rfind('/');
    return k == std::string_view::npos ? std::string_view{} : p.substr(0, k);
}

namespace {
uint32_t split(std::string_view s, std::string_view* out, uint32_t cap) {
    uint32_t n = 0;
    size_t at = 0;
    for (;;) {
        size_t k = s.find('/', at);
        if (n < cap)
            out[n++] = s.substr(at, k == std::string_view::npos ? std::string_view::npos : k - at);
        if (k == std::string_view::npos)
            return n;
        at = k + 1;
    }
}
}

std::string_view Impl::normalize(std::string_view p) noexcept {
    std::string_view parts[256], out[256];
    uint32_t count = 0;
    for (char c : p)
        count += c == '/';
    if (count >= 256)
        return p;
    uint32_t n = split(p, parts, 256), m = 0;
    for (uint32_t i = 0; i < n; i++) {
        std::string_view s = parts[i];
        if (s == "." || (s.empty() && m))
            continue;
        if (s == ".." && m && out[m - 1] != ".." && !out[m - 1].empty())
            m--;
        else
            out[m++] = s;
    }
    size_t len = 0;
    for (uint32_t i = 0; i < m; i++)
        len += out[i].size() + (i ? 1 : 0);
    char* b = static_cast<char*>(arena.alloc(len ? len : 1, 1));
    if (!b)
        return {};
    size_t k = 0;
    for (uint32_t i = 0; i < m; i++) {
        if (i)
            b[k++] = '/';
        std::memcpy(b + k, out[i].data(), out[i].size()), k += out[i].size();
    }
    return {b, k};
}

std::string_view Impl::folder(std::string_view from, std::string_view p) noexcept {
    if (p == "rexui" || p == "rexshared")
        return p;
    if (starts(p, "/") || starts(p, "~"))
        return normalize(p);
    std::string_view base = dirname(from);
    return normalize(base.empty() ? p : cat({base, "/", p}));
}

std::string_view Impl::display(std::string_view p) noexcept {
    std::string_view d = dirname(top_path);
    if (d.empty() || !starts(p, "/"))
        return p;
    uint32_t count = 0;
    for (char c : d)
        count += c == '/';
    for (char c : p)
        count += c == '/';
    if (count >= 256)
        return p;
    std::string_view a[256], b[256];
    uint32_t na = split(d, a, 256), nb = split(p, b, 256);
    uint32_t k = 0;
    while (k < na && k + 1 < nb && a[k] == b[k])
        k++;
    if (k < 2)
        return p;
    std::string_view out;
    for (uint32_t i = k; i < na; i++)
        out = cat({out, "../"});
    for (uint32_t i = k; i < nb; i++)
        out = cat({out, i > k ? "/" : "", b[i]});
    return out;
}

List<std::string_view> Impl::look_in(std::string_view type, Scope* sc) noexcept {
    size_t dot = type.rfind('.');
    std::string_view ns = dot == std::string_view::npos ? std::string_view{} : type.substr(0, dot);
    List<std::string_view> out;
    if (ns.empty() && !sc->path.empty())
        (void)out.push(arena, dirname(sc->path));
    for (const UseDir& u : sc->uses)
        if (u.as == ns)
            (void)out.push(arena, u.dir);
    return out;
}

bool Impl::component(std::string_view type, Scope* sc, uint32_t line, Comp*& out) noexcept {
    out = nullptr;
    size_t dot = type.rfind('.');
    std::string_view ns = dot == std::string_view::npos ? std::string_view{} : type.substr(0, dot);
    std::string_view name = dot == std::string_view::npos ? type : type.substr(dot + 1);
    if (!ns.empty()) {
        bool any = false;
        for (const UseDir& u : sc->uses)
            any = any || u.as == ns;
        if (!any)
            return fail(sc, line, fmt("no use ... as %a for %b", ns, type));
    }
    for (std::string_view d : look_in(type, sc)) {
        std::string_view p = cat({d, "/", name, ".rui"});
        Comp* c = nullptr;
        bool known = false;
        for (Comp* k : comps)
            if (k->path == p)
                c = k, known = true;
        for (std::string_view u : using_)
            (void)u;
        if (!known) {
            std::string_view text;
            if (sink.source(p, text)) {
                c = arena.make<Comp>();
                if (!c)
                    return fail(sc, line, "out of memory");
                c->path = p;
                c->file = display(p);
                auto ast = rui::parse(text, arena);
                if (!ast) {
                    c->error = true;
                    c->err_line = ast.error().line;
                    c->err_msg = ast.error().msg;
                } else {
                    c->ast = *ast;
                    for (const rui::Use& u : c->ast->uses)
                        (void)c->uses.push(arena, UseDir{folder(p, u.path), u.as});
                }
            }
            Comp* slot = c;
            if (!slot) {
                slot = arena.make<Comp>();
                if (!slot)
                    return fail(sc, line, "out of memory");
                slot->path = p;
                slot->ast = nullptr;
            }
            if (!comps.push(arena, slot))
                return fail(sc, line, "out of memory");
            c = slot;
        }
        if (c && c->error) {
            if (err.set)
                return false;
            err.set = true;
            err.file = c->file;
            err.line = c->err_line;
            err.msg = c->err_msg;
            return false;
        }
        if (c && c->ast)
            return out = c, true;
    }
    return true;
}

static std::string_view slot_name(const rui::Element* node) {
    for (const rui::Member& m : node->props) {
        if (m.name != "name" || m.value.size() < 2)
            continue;
        char q = m.value[0];
        if ((q == '"' || q == '\'') && m.value.back() == q)
            return m.value.substr(1, m.value.size() - 2);
    }
    return {};
}
static bool has_named_slot(const rui::Element* n, std::string_view name) {
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

bool Impl::create(const rui::Element* node, Elem* parent, Pending& p, Scope* sc, Elem* ctx, bool ctx_set,
                  Elem*& out) noexcept {
    out = nullptr;
    if (node->type == "Slot") {
        std::string_view named = slot_name(node);
        if (!named.empty()) {
            if (!sc->has_slot && !sc->named_slots)
                return fail(sc, node->line,
                            "a Slot is only for a component's file (Card.rui): where Card { ... }'s elements go");
            for (const rui::Object& ob : sc->slot_node->objects) {
                if (ob.name != named)
                    continue;
                Elem* filled;
                Elem* fill_ctx = parent->ctx ? parent->ctx : sc->slot_ctx;
                const bool is_root = fill_ctx == k_ctx_root;
                if (!create(ob.node, parent, p, sc->slot_sc, is_root ? k_ctx_root : fill_ctx,
                            is_root || fill_ctx || sc->slot_ctx_set, filled))
                    return false;
            }
            return true;
        }
        if (!sc->has_slot)
            return fail(sc, node->line,
                        "a Slot is only for a component's file (Card.rui): where Card { ... }'s elements go");
        if (sc->slotted)
            return fail(sc, node->line, "a component has one Slot");
        sc->slotted = true;
        Elem* into = parent;
        for (const rui::Element* child : sc->slot_node->children) {
            Elem* c;
            bool ok = sc->slot_ctx == k_ctx_root
                ? create(child, into, p, sc->slot_sc, into->ctx ? into->ctx : k_ctx_root, true, c)
                : create(child, into, p, sc->slot_sc, sc->slot_ctx, sc->slot_ctx_set, c);
            if (!ok)
                return false;
        }
        return true;
    }
    sch::Elem et;
    if (!sch::elem_of(node->type, &et))
        return instance(node, parent, p, sc, ctx, ctx_set, out);
    Elem* o = new_elem(static_cast<int16_t>(et), node->type);
    if (!o)
        return fail(sc, node->line, "out of memory");
    o->uid = next_uid++;
    while (objs.size <= o->uid)
        if (!objs.push(arena, nullptr))
            return fail(sc, node->line, "out of memory");
    objs[o->uid] = o;
    o->file = sc->file;
    o->id = node->has_id ? node->id : std::string_view{};
    o->line = node->line;
    o->parent = parent;
    if (ctx_set && ctx == k_ctx_root)
        ctx = o;
    o->ctx = ctx_set ? ctx : nullptr;
    sink.create(o->uid, node->type, parent ? parent->uid : 0);
    if (parent && !parent->children.push(arena, o))
        return fail(sc, node->line, "out of memory");
    {
        uint32_t want = node->props.size + node->custom.size + node->functions.size + node->objects.size
            + (o->ctx == o ? 3 : 0) + 2;
        o->slots = arena.array<PSlot>(want);
        if (!o->slots)
            return fail(sc, node->line, "out of memory");
        o->cap_slots = want;
    }
    if (o->ctx == o) {
        if (!define(o, "modelData", Value::undefined(), false) || !define(o, "index", Value::num(0), false))
            return false;
        if (parent && parent->type == static_cast<int16_t>(sch::Elem::Panes)
            && !define(o, "pane", Value::undefined(), false))
            return false;
        for (uint32_t i = 0; i < o->n_slots; i++)
            o->slots[i].pre = true;
    }
    o->tt = type_tpl(static_cast<int>(et));
    if (!o->tt)
        return fail(sc, node->line, "out of memory");
    const bool implied = sink.implies_defaults();
    for (uint32_t t = 0; t < o->tt->n; t++) {
        const TEntry& te = o->tt->e[t];
        if (te.kind != SK::prop)
            continue;
        if (te.eager) {
            int pi = static_cast<int>(sch::k_prop_defs[te.def].prop);
            if (!define(o, sch::k_props[pi].name, tpl_default(te), te.native, te.name))
                return false;
            continue;
        }
        if (!te.native || implied || find_own(o, te.name) >= 0)
            continue;
        Value v = tpl_default(te);
        if (!v.is_undefined())
            native_set(o, sch::k_props[static_cast<int>(sch::k_prop_defs[te.def].prop)].name, v);
    }
    if (!members(o, node, p, sc, nullptr, false))
        return false;
    if (o->type == static_cast<int16_t>(sch::Elem::Drawer) && !node->children.empty())
        for (const rui::Member& m : node->props)
            if (m.name == "lazy" && m.value == "true") {
                if (!o->templates.push(arena, Tpl{a_lazy, node, sc, ctx, ctx_set}))
                    return false;
                out = o;
                return true;
            }
    for (const rui::Element* child : node->children) {
        Elem* c;
        if (!create(child, o, p, sc, ctx, ctx_set, c))
            return false;
    }
    out = o;
    return true;
}

bool Impl::members(Elem* o, const rui::Element* node, Pending& p, Scope* sc, Elem* cx, bool cx_set) noexcept {
    if (node->has_id) {
        Str* id = atom(node->id);
        if (id_own(sc->ids, id))
            return fail(sc, node->line, fmt("id %a is used twice", node->id));
        if (!sc->ids->keys.push(arena, id) || !sc->ids->vals.push(arena, o))
            return false;
        if (sc->has_prefix)
            native_set(o, "id", val(rt.str_ascii(cat({sc->prefix, node->id}))));
        else if (o->type == static_cast<int16_t>(sch::Elem::WebView))
            native_set(o, "id", val(rt.str_ascii(node->id)));
    }
    for (const rui::Member& h : node->handlers)
        if (h.name == "onPressedOutside") {
            native_set(o, "pressedOutside", Value::boolean(true));
            break;
        }
    for (const rui::Member& h : node->handlers) {
        if (h.name == "onLayoutWidthChanged" || h.name == "onLayoutHeightChanged")
            native_set(o, "wantsLayout", Value::boolean(true));
        else if (h.name == "onScrolled" || h.name == "onContentXChanged" || h.name == "onContentYChanged")
            native_set(o, "wantsScroll", Value::boolean(true));
        else if ((o->type == static_cast<int16_t>(sch::Elem::Image)
                  || o->type == static_cast<int16_t>(sch::Elem::Video))
                 && (h.name == "onLoaded" || h.name == "onFailed" || h.name == "onEnded" || h.name == "onStatusChanged"
                     || h.name == "onPositionChanged" || h.name == "onDurationChanged"))
            native_set(o, "wantsStatus", Value::boolean(true));
        else if (h.name == "onPressedChanged" && o->type == static_cast<int16_t>(sch::Elem::Button))
            native_set(o, "wantsPressed", Value::boolean(true));
    }
    if (o->type == static_cast<int16_t>(sch::Elem::MouseArea) || o->type == static_cast<int16_t>(sch::Elem::Button)
        || o->type == static_cast<int16_t>(sch::Elem::Slider) || o->type == static_cast<int16_t>(sch::Elem::List)
        || o->type == static_cast<int16_t>(sch::Elem::TextField)
        || o->type == static_cast<int16_t>(sch::Elem::TextArea)) {
        for (const rui::Member& h : node->handlers) {
            const bool area = o->type == static_cast<int16_t>(sch::Elem::MouseArea);
            const char* wants = h.name == "onKeyPressed" || h.name == "onKeyReleased" ? "wantsKeys"
                : !area                                                               ? nullptr
                : h.name == "onMoved"                                                 ? "wantsMoved"
                : h.name == "onWheel"                                                 ? "wantsWheel"
                : h.name == "onDrop"                                                  ? "wantsDrop"
                : h.name == "onDragMoved"                                             ? "wantsDragMoved"
                                                                                      : nullptr;
            if (wants)
                native_set(o, wants, Value::boolean(true));
        }
    }
    for (const rui::Signal& sg : node->signals) {
        Str* a = atom(sg.name);
        int32_t i = find(o, a);
        if (i >= 0 && (o->slots[i].named || o->slots[i].kind == SK::plain))
            return fail(sc, sg.line, fmt("%a already has %b", node->type, sg.name));
        char c0 = sg.name[0] >= 'a' && sg.name[0] <= 'z' ? static_cast<char>(sg.name[0] - 32) : sg.name[0];
        Str* hn = atom(cat({"on", std::string_view(&c0, 1), sg.name.substr(1)}));
        std::string_view zname = cat({sg.name, std::string_view("\0", 1)});
        Native* fn = rt.native(zname.data(), signal_method(), 0);
        if (!fn || !hn || !o->signals.push(arena, DeclaredSignal{hn, sg.params}))
            return false;
        if (i < 0 && (i = add_slot(o, a)) < 0)
            return false;
        o->slots[i].kind = SK::method;
        o->slots[i].named = true;
        o->slots[i].value = val(fn);
    }
    sch::Span os = sch::k_elem_objects[o->type];
    for (const rui::Object& ob : node->objects) {
        bool takes = false;
        for (uint32_t k = os.first; k < os.first + os.count; k++)
            takes = takes || sch::k_objects[k] == ob.name;
        if (use_of && has_named_slot(use_of, ob.name))
            continue;
        if (!takes)
            return fail(sc, ob.line, fmt("%a has no property %b taking an element", node->type, ob.name));
        if (!o->templates.push(arena, Tpl{atom(ob.name), ob.node, sc}))
            return false;
    }
    if (o->type == static_cast<int16_t>(sch::Elem::Loader)) {
        if (!o->templates.push(arena, Tpl{a_loaderScope, nullptr, sc}))
            return false;
        sink.call(o->uid, "loaderDue", "");
    }
    for (const rui::Member& c : node->custom) {
        int32_t i = find(o, atom(c.name));
        if (i >= 0 && o->slots[i].named)
            return fail(sc, c.line, fmt("%a already has a property %b", node->type, c.name));
        if (!define(o, c.name, Value::undefined(), false))
            return false;
        if (c.has_value && !p.bindings.push(tmp, Pending::B{o, c.name, &c, c.line, sc, cx, cx_set}))
            return false;
    }
    for (const rui::Member& m : node->props) {
        if (m.name == "virtualized")
            o->v_named = true;
        if (m.name == "modelKey")
            o->k_named = true;
        int32_t i = find(o, atom(m.name));
        if (i < 0 || o->slots[i].kind != SK::prop || !o->slots[i].has_value)
            return fail(sc, m.line, fmt("%a has no property %b", node->type, m.name));
        for (const rui::Member& q : node->props) {
            if (&q == &m)
                break;
            if (q.name == m.name)
                return fail(sc, m.line, fmt("%a sets %b twice", node->type, m.name));
        }
        if (!p.bindings.push(tmp, Pending::B{o, m.name, &m, m.line, sc, cx, cx_set}))
            return false;
    }
    return p.nodes.push(tmp, Pending::N{o, node, sc, cx, cx_set});
}

bool Impl::instance(const rui::Element* node, Elem* parent, Pending& p, Scope* sc, Elem* ctx, bool ctx_set,
                    Elem*& out) noexcept {
    Comp* c;
    if (!component(node->type, sc, node->line, c))
        return false;
    if (!c) {
        std::string_view known;
        for (int k = 0; k < static_cast<int>(sch::Elem::count_); k++) {
            if (sch::k_elems[k] == "Slot")
                continue;
            known = known.empty() ? sch::k_elems[k] : cat({known, ", ", sch::k_elems[k]});
        }
        List<std::string_view> looked = look_in(node->type, sc);
        std::string_view more;
        if (looked.size) {
            std::string_view last =
                node->type.substr(node->type.rfind('.') == std::string_view::npos ? 0 : node->type.rfind('.') + 1);
            std::string_view dirs;
            for (std::string_view d : looked)
                dirs = dirs.empty() ? d : cat({dirs, ", ", d});
            more = cat({"; no ", last, ".rui in ", dirs});
        }
        return fail(sc, node->line, cat({"unknown element ", node->type, " (known: ", known, more, ")"}));
    }
    for (std::string_view u : using_)
        if (u == c->path) {
            std::string_view chain;
            for (std::string_view v : using_)
                chain = chain.empty() ? display(v) : cat({chain, " -> ", display(v)});
            return fail(sc, node->line, cat({node->type, " uses itself (", chain, ")"}));
        }
    bool inner_prefix = node->has_id && sc->has_prefix;
    Scope* inner = new_scope(c->file, c->path, c->uses, inner_prefix,
                             inner_prefix ? cat({sc->prefix, node->id, "."}) : std::string_view{});
    if (!inner)
        return fail(sc, node->line, "out of memory");
    inner->src = c->ast->src;
    inner->has_slot = true;
    inner->slot_node = node;
    inner->slot_sc = sc;
    inner->slot_ctx = ctx;
    inner->slot_ctx_set = ctx_set;
    if (!using_.push(arena, c->path))
        return false;
    Elem* o;
    bool root_ctx = ctx_set && ctx == k_ctx_root;
    bool ok = create(c->ast->root, parent, p, inner, root_ctx ? k_ctx_root : nullptr, root_ctx, o);
    using_.size--;
    if (!ok) {
        (void)err.uses.push(arena, cat({sc->file, ":", num8(node->line)}));
        return false;
    }
    inner->root = o;
    o->file = sc->file, o->line = node->line, o->comp = node->type;
    o->id = node->has_id ? node->id : std::string_view{};
    bool cx_given = ctx_set && ctx && ctx != k_ctx_root;
    use_of = c->ast->root;
    const bool members_ok = members(o, node, p, sc, cx_given ? ctx : nullptr, cx_given);
    use_of = nullptr;
    if (!members_ok)
        return false;
    if (!inner->slotted) {
        for (const rui::Element* child : node->children) {
            Elem* ch;
            bool k = root_ctx ? create(child, o, p, sc, o->ctx ? o->ctx : k_ctx_root, true, ch)
                              : create(child, o, p, sc, ctx, ctx_set, ch);
            if (!k)
                return false;
        }
    }
    out = o;
    return true;
}

bool Impl::unit(std::string_view src, const char* key, uint32_t pos, uint32_t len, js::Goal goal,
                const std::string_view* params, uint32_t n_params, Scope* sc, uint32_t line,
                const Code*& out) noexcept {
    uint32_t extra = static_cast<uint32_t>(goal) | n_params << 4;
    if (code_cap) {
        uint32_t m = code_cap - 1;
        for (uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(key) * 2654435761u) & m; codes[h].key;
             h = (h + 1) & m)
            if (codes[h].key == key && codes[h].extra == extra)
                return out = codes[h].code, true;
    }
    auto ast = js::parse(src, pos, len, goal, scratch);
    if (!ast)
        return fail(sc, line, ast.error().msg), scratch.reset(), false;
    auto code = compile(*ast, goal, src, rt, params, n_params, &scratch);
    if (!code)
        return fail(sc, line, code.error().msg), scratch.reset(), false;
    scratch.reset();
    out = *code;
    if (!all_codes.push(arena, out))
        return fail(sc, line, "out of memory");
    if ((code_count + 1) * 2 > code_cap) {
        uint32_t cap = code_cap ? code_cap * 2 : 256;
        CodeEntry* t = arena.array<CodeEntry>(cap);
        if (!t)
            return true;
        for (uint32_t i = 0; i < code_cap; i++)
            if (codes[i].key) {
                uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(codes[i].key) * 2654435761u) & (cap - 1);
                while (t[h].key)
                    h = (h + 1) & (cap - 1);
                t[h] = codes[i];
            }
        codes = t, code_cap = cap;
    }
    uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(key) * 2654435761u) & (code_cap - 1);
    while (codes[h].key)
        h = (h + 1) & (code_cap - 1);
    codes[h] = CodeEntry{key, extra, out};
    code_count++;
    return true;
}

bool Impl::function(std::string_view src, const rui::Function& f, Scope* sc, const Code*& out) noexcept {
    const char* key = f.body.data();
    if (code_cap) {
        uint32_t m = code_cap - 1;
        for (uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(key) * 2654435761u) & m; codes[h].key;
             h = (h + 1) & m)
            if (codes[h].key == key && codes[h].extra == 0xFFFF)
                return out = codes[h].code, true;
    }
    auto ast = js::parse_function(src, f.params_pos, static_cast<uint32_t>(f.params.size()), f.body_pos,
                                  static_cast<uint32_t>(f.body.size()), scratch);
    if (!ast)
        return fail(sc, f.line, ast.error().msg), scratch.reset(), false;
    auto code = compile_function(*ast, src, rt, &scratch);
    if (!code)
        return fail(sc, f.line, code.error().msg), scratch.reset(), false;
    scratch.reset();
    out = *code;
    if (!all_codes.push(arena, out))
        return fail(sc, f.line, "out of memory");
    if ((code_count + 1) * 2 > code_cap)
        return true;
    uint32_t h = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(key) * 2654435761u) & (code_cap - 1);
    while (codes[h].key)
        h = (h + 1) & (code_cap - 1);
    codes[h] = CodeEntry{key, 0xFFFF, out};
    code_count++;
    return true;
}

bool Impl::signal_params(Elem* o, std::string_view name, std::string_view& params) noexcept {
    params = {};
    if (name == "Component.onCompleted" || name == "Component.onDestruction")
        return true;
    if (name.size() < 3)
        return false;
    if (!o->signals.size) {
    } else if (Str* a = atom(name)) {
        for (const DeclaredSignal& ds : o->signals)
            if (ds.handler == a)
                return params = ds.params, true;
    }
    char c0 = name[2] >= 'A' && name[2] <= 'Z' ? static_cast<char>(name[2] + 32) : name[2];
    std::string_view s = cat({std::string_view(&c0, 1), name.substr(3)});
    sch::Span sp = sch::k_elem_signals[o->type];
    for (uint32_t k = sp.first; k < sp.first + sp.count; k++)
        if (sch::k_signals[k].name == s)
            return params = sch::k_signals[k].params, true;
    sch::Prop pr;
    if (s == "pressedOutside" && sch::prop_of("opacity", &pr) && sch::has(static_cast<sch::Elem>(o->type), pr))
        return true;
    if (s == "filesDropped" && sch::prop_of("dropFiles", &pr) && sch::has(static_cast<sch::Elem>(o->type), pr))
        return params = "paths, copy", true;
    if (s.size() >= 7 && s.substr(s.size() - 7) == "Changed")
        return params = "initial", true;
    params = name.find('.') != std::string_view::npos ? name : s;
    return false;
}

bool Impl::wire(Elem* o, const rui::Element* node, Scope* sc, Pending& p, Elem* cx, bool cx_set) noexcept {
    Ctx* ctx = ctx_for(o, sc, cx, cx_set);
    if (!ctx)
        return fail(sc, node->line, "out of memory");
    static constexpr std::string_view k_own[] = {"parent",      "children",   "__uid",      "__type",  "__values",
                                                 "__deps",      "__bindings", "__handlers", "__names", "__native",
                                                 "__templates", "__at",       "__ctx"};
    for (const rui::Function& f : node->functions) {
        Str* a = atom(f.name);
        int32_t i = find(o, a);
        bool own = i >= 0 && (o->slots[i].named || o->slots[i].kind == SK::plain);
        for (std::string_view k : k_own)
            own = own || k == f.name;
        if (own)
            return fail(sc, f.line, fmt("%a already has a function %b", node->type, f.name));
        const Code* code;
        if (!function(sc->src, f, sc, code))
            return false;
        Fn* fn = arena.make<Fn>();
        if (!fn)
            return false;
        fn->h = Cell{0, Kind::function, 0, 0};
        fn->code = code;
        fn->host = ctx;
        if (i < 0 && (i = add_slot(o, a)) < 0)
            return false;
        o->slots[i].kind = SK::function;
        o->slots[i].named = true;
        o->slots[i].value = val(fn);
    }
    for (const rui::Member& h : node->handlers) {
        std::string_view ps;
        for (const rui::Member& q : node->handlers) {
            if (&q == &h)
                break;
            if (q.name == h.name)
                return fail(sc, h.line, fmt("%a has %b twice", node->type, h.name));
        }
        if (!signal_params(o, h.name, ps))
            return fail(sc, h.line, fmt("%a has no signal %b", o->type_name, ps));
        std::string_view pnames[8];
        uint32_t n = 0;
        for (size_t at = 0; !ps.empty() && n < 8;) {
            size_t k = ps.find(',', at);
            std::string_view x = ps.substr(at, k == std::string_view::npos ? std::string_view::npos : k - at);
            while (!x.empty() && x.front() == ' ')
                x.remove_prefix(1);
            while (!x.empty() && x.back() == ' ')
                x.remove_suffix(1);
            pnames[n++] = x;
            if (k == std::string_view::npos)
                break;
            at = k + 1;
        }
        const Code* code;
        if (!unit(sc->src, h.value.data(), h.value_pos, static_cast<uint32_t>(h.value.size()), js::Goal::handler,
                  pnames, n, sc, h.line, code))
            return false;
        Handler hd{atom(h.name), code, ctx, sc->file, h.line};
        if (h.name == "Component.onCompleted") {
            if (!p.completed.push(tmp, hd))
                return false;
        } else if (!o->handlers.push(arena, hd)) {
            return false;
        }
    }
    return true;
}

namespace {
constexpr std::string_view k_panes_model = "(panes.list || []).concat(panes.previews || [])";
}

bool Impl::bind_all(Pending& p) noexcept {
    for (const Pending::N& n : p.nodes)
        if (!wire(n.o, n.node, n.sc, p, n.cx, n.cx_set))
            return false;
    Ctx* last = nullptr;
    for (const Pending::B& pb : p.bindings) {
        Ctx* ctx = last;
        Elem* cx = pb.cx_set ? pb.cx : pb.obj->ctx;
        if (!ctx || ctx->o != pb.obj || ctx->sc != pb.sc || ctx->cx != cx)
            ctx = last = ctx_for(pb.obj, pb.sc, pb.cx, pb.cx_set);
        if (!ctx)
            return false;
        const Code* code;
        bool ok = pb.m
            ? unit(pb.sc->src, pb.m->value.data(), pb.m->value_pos, static_cast<uint32_t>(pb.m->value.size()),
                   js::Goal::value, nullptr, 0, pb.sc, pb.line, code)
            : unit(k_panes_model, k_panes_model.data(), 0, static_cast<uint32_t>(k_panes_model.size()), js::Goal::value,
                   nullptr, 0, pb.sc, pb.line, code);
        if (!ok)
            return false;
        Binding* b = arena.make<Binding>();
        if (!b)
            return false;
        int32_t i = find(pb.obj, atom(pb.name));
        if (i < 0)
            return false;
        b->obj = pb.obj;
        b->slot = static_cast<uint32_t>(i);
        b->code = code;
        b->ctx = ctx;
        b->m = pb.m;
        b->line = pb.line & 0x7FFFFFFFu;
        if (Binding* old = pb.obj->slots[i].binding)
            unhook(old);
        pb.obj->slots[i].binding = b;
        dirty_add(b);
    }
    return true;
}

Value Impl::entries(Value model) noexcept {
    if (model.is(Kind::array))
        return model;
    Arr* a = rt.array(0);
    if (!a)
        return Value::undefined();
    if (model.is_num()) {
        double d = model.as_num();
        int32_t n = d != d || d == 1.0 / 0.0 || d == -1.0 / 0.0 ? 0 : static_cast<int32_t>(static_cast<int64_t>(d));
        for (int32_t k = 0; k < n; k++)
            rt.push(a, Value::num(k));
    }
    return val(a);
}

Tpl* Impl::tpl(Elem* o, Str* name) noexcept {
    Tpl* t = nullptr;
    for (Tpl& x : o->templates)
        if (x.name == name)
            t = &x;
    return t;
}

Str* Impl::pane_key(Value p) noexcept {
    if (!to_boolean(p))
        return rt.empty;
    Value k = get(rt, p, a_key);
    if (!to_boolean(k))
        k = get(rt, p, a_id);
    if (!to_boolean(k))
        return rt.empty;
    Str* s = to_string(rt, k);
    return s ? s : rt.empty;
}

void Impl::instantiate(Elem* list, uint32_t i, Value data, Str* which) noexcept {
    Pending p{};
    bool was = building;
    building = true;
    Tpl* t = tpl(list, which ? which : a_delegate);
    Scope* sc = arena.make<Scope>();
    if (!t || !sc)
        return void(building = was);
    *sc = *t->sc;
    sc->ids = new_ids(t->sc->ids);
    sc->has_prefix = false;
    sc->named_slots = t->sc->has_slot || t->sc->named_slots;
    sc->has_slot = false;
    sc->slotted = false;
    Elem* inst = nullptr;
    err = LoadError{};
    bool ok = create(t->node, list, p, sc, k_ctx_root, true, inst) && inst;
    if (ok) {
        if (which) {
            inst->pane_slot = which;
            native_set(inst, "paneSlot", val(which));
            Str* key = pane_key(data);
            native_set(inst, "paneId", val(key));
            inst->pane_key = key;
            inst->has_pane_key = true;
            write_name(inst, a_pane, data, true);
        }
        write_name(inst, a_modelData, data, true);
        write_name(inst, a_index, Value::num(i), true);
        ok = bind_all(p);
    }
    if (!ok) {
        building = was;
        if (err.set) {
            std::string_view file = err.file.empty() ? t->sc->file : err.file;
            report_text(file, err.line, err.msg);
        }
        err = LoadError{};
        return;
    }
    building = was;
    flush();
    for (const Handler& h : p.completed)
        call(h, nullptr, 0);
}

namespace {
std::string_view str8(Impl* d, Str* s);
}

void Impl::loader_write(Elem* o, Str* name, Value v) noexcept {
    if (name == a_loadNow) {
        if (to_boolean(v))
            loader_make(o);
        return;
    }
    if (name == a_source)
        loader_clear(o);
    int32_t ai = find(o, a_active);
    const bool active = ai < 0 || to_boolean(o->slots[ai].value);
    if (!active)
        return loader_clear(o);
    if (!o->children.size)
        sink.call(o->uid, "loaderDue", "");
}

void Impl::drawer_build(Elem* o) noexcept {
    Tpl* t = tpl(o, a_lazy);
    if (!t || !t->node)
        return;
    const rui::Element* node = t->node;
    Scope* sc = t->sc;
    Elem* ctx = t->ctx;
    const bool ctx_set = t->ctx_set;
    t->node = nullptr;
    Pending p{};
    bool was = building;
    building = true;
    err = LoadError{};
    bool ok = true;
    for (const rui::Element* child : node->children) {
        Elem* c;
        if (!(ok = create(child, o, p, sc, ctx, ctx_set, c)))
            break;
    }
    ok = ok && bind_all(p);
    building = was;
    if (!ok) {
        if (err.set)
            report_text(err.file.empty() ? sc->file : err.file, err.line, err.msg);
        err = LoadError{};
        return;
    }
    flush();
    for (const Handler& h : p.completed)
        call(h, nullptr, 0);
}

void Impl::loader_clear(Elem* o) noexcept {
    destroy_past(o, 0);
    write_name(o, a_ready, Value::boolean(false), true);
}

void Impl::loader_make(Elem* o) noexcept {
    int32_t ai = find(o, a_active);
    if ((ai >= 0 && !to_boolean(o->slots[ai].value)) || o->children.size)
        return;
    int32_t si = find(o, a_source);
    Value src = si >= 0 ? o->slots[si].value : Value::undefined();
    if (src.is(Kind::string) && src.as<Str>()->length) {
        std::string_view path = str8(this, src.as<Str>());
        size_t slash = path.rfind('/');
        std::string_view base = slash == std::string_view::npos ? path : path.substr(slash + 1);
        if (base.ends_with(".rui"))
            base.remove_suffix(4);
        rui::Element* el = arena.make<rui::Element>();
        Tpl* own = tpl(o, a_loaderScope);
        if (!el || !own)
            return;
        el->type = arena.copy(base);
        el->line = own->node ? own->node->line : 0;
        Tpl* t = tpl(o, a_delegate);
        if (t)
            t->node = el;
        else if (!o->templates.push(arena, Tpl{a_delegate, el, own->sc}))
            return;
    }
    if (!tpl(o, a_delegate))
        return;
    instantiate(o, 0, Value::undefined(), nullptr);
    if (!o->children.size)
        return;
    write_name(o, a_ready, Value::boolean(true), true);
    emit(o->uid, "loaded", nullptr, 0);
}

void Impl::destroy(Elem* o) noexcept {
    if (o->dying || !o->alive)
        return;
    o->dying = true;
    if (o->handlers.size) {
        Str* a = atom("Component.onDestruction");
        for (uint32_t k = 0; k < o->handlers.size; k++)
            if (o->handlers[k].name == a)
                call(o->handlers[k], nullptr, 0);
    }
    if (o->children.size) {
        Elem** copy = tmp.array<Elem*>(o->children.size);
        uint32_t n = o->children.size;
        if (copy) {
            for (uint32_t k = 0; k < n; k++)
                copy[k] = o->children[k];
            for (uint32_t k = 0; k < n; k++)
                destroy(copy[k]);
        }
    }
    for (uint32_t i = 0; i < o->n_slots; i++)
        if (Binding* b = o->slots[i].binding)
            unhook(b), o->slots[i].binding = nullptr;
    if (o->uid < objs.size)
        objs[o->uid] = nullptr;
    o->alive = false;
    if (Elem* p = o->parent) {
        uint32_t k = 0;
        while (k < p->children.size && p->children[k] != o)
            k++;
        if (k < p->children.size) {
            for (uint32_t j = k; j + 1 < p->children.size; j++)
                p->children[j] = p->children[j + 1];
            p->children.size--;
        }
    }
    sink.call(o->uid, "destroy", "");
}

void Impl::destroy_past(Elem* o, uint32_t keep) noexcept {
    for (;;) {
        uint32_t k = o->children.size;
        while (k > keep && o->children[k - 1]->dying)
            k--;
        if (k <= keep)
            return;
        destroy(o->children[k - 1]);
    }
}

void Impl::sync(Elem* list) noexcept {
    if (list->type == static_cast<int16_t>(sch::Elem::Panes))
        return sync_panes(list);
    if (!tpl(list, a_delegate))
        return;
    if (virtualized(list))
        return sync_window(list, true);
    if (list->s_syncing) {
        list->s_again = true;
        return;
    }
    list->s_syncing = true;
    do {
        list->s_again = false;
        sync_rows(list);
    } while (list->s_again && list->alive && !list->dying);
    list->s_syncing = false;
}

void Impl::sync_rows(Elem* list) noexcept {
    int32_t mi = find(list, a_model);
    Value items = entries(mi >= 0 ? list->slots[mi].value : Value::undefined());
    if (!items.is(Kind::array))
        return;
    Arr* a = items.as<Arr>();
    if (sync_keyed(list, a))
        return;
    for (uint32_t i = 0; i < a->length && !list->s_again; i++) {
        Value it = a->items[i].is_hole() ? Value::undefined() : a->items[i];
        if (i < list->children.size) {
            Elem* c = list->children[i];
            write_name(c, a_modelData, it, true);
            write_name(c, a_index, Value::num(i), true);
        } else {
            instantiate(list, i, it, nullptr);
        }
    }
    if (!list->s_again)
        destroy_past(list, a->length);
}

Str* Impl::row_key(Elem*, Value key, Value item, uint32_t i) noexcept {
    Value k;
    if (key.is(Kind::function) || key.is(Kind::native)) {
        Value argv[2] = {item, Value::num(i)};
        k = vm.call(key, Value::undefined(), argv, 2);
    } else if (key.is(Kind::string) && item.is_cell() && !item.is(Kind::string)) {
        k = get(rt, item, rt.atom(key.as<Str>()));
    } else {
        k = item;
    }
    if (rt.failed)
        rt.clear();
    Str* s = to_string(rt, k);
    return s ? s : rt.empty;
}

bool Impl::sync_keyed(Elem* list, Arr* a) noexcept {
    int32_t ki = find(list, a_modelKey);
    Value key = ki >= 0 ? list->slots[ki].value : Value::undefined();
    if (key.is_undefined())
        return list->k_named;
    const uint32_t n = a->length, have = list->children.size;
    Elem** old = tmp.array<Elem*>(have + 1);
    Elem** got = tmp.array<Elem*>(n + 1);
    Str** keys = tmp.array<Str*>(n + 1);
    if (!old || !got || !keys)
        return false;
    for (uint32_t k = 0; k < have; k++)
        old[k] = list->children[k];
    for (uint32_t i = 0; i < n; i++) {
        Value it = a->items[i].is_hole() ? Value::undefined() : a->items[i];
        keys[i] = row_key(list, key, it, i);
        got[i] = nullptr;
        if (i < have && old[i] && old[i]->has_pane_key && old[i]->pane_key->view() == keys[i]->view())
            got[i] = old[i], old[i] = nullptr;
    }
    for (uint32_t i = 0; i < n; i++)
        for (uint32_t k = 0; !got[i] && k < have; k++)
            if (old[k] && old[k]->has_pane_key && old[k]->pane_key->view() == keys[i]->view())
                got[i] = old[k], old[k] = nullptr;
    for (uint32_t k = 0; k < have; k++)
        if (old[k])
            destroy(old[k]);
    for (uint32_t i = 0; i < n; i++) {
        Value it = a->items[i].is_hole() ? Value::undefined() : a->items[i];
        if (got[i]) {
            write_name(got[i], a_modelData, it, true);
            write_name(got[i], a_index, Value::num(i), true);
            continue;
        }
        const uint32_t before = list->children.size;
        instantiate(list, i, it, nullptr);
        if (list->children.size > before) {
            got[i] = list->children[list->children.size - 1];
            got[i]->pane_key = keys[i];
            got[i]->has_pane_key = true;
        }
    }
    bool same = true;
    uint32_t w = 0;
    for (uint32_t i = 0; i < n; i++) {
        if (!got[i] || got[i]->dying || !got[i]->alive)
            continue;
        if (w >= list->children.size)
            break;
        same = same && list->children[w] == got[i];
        list->children[w++] = got[i];
    }
    if (!same) {
        std::string_view order;
        for (uint32_t k = 0; k < list->children.size; k++)
            order = cat({order, k ? "," : "", num8(list->children[k]->uid)});
        sink.call(list->uid, "order", order);
    }
    return true;
}

bool Impl::virtualized(Elem* list) noexcept {
    if (list->type != static_cast<int16_t>(sch::Elem::List) || !list->v_named)
        return false;
    if (!list->v_bound)
        return true;
    int32_t i = find(list, a_virtualized);
    return i >= 0 && to_boolean(list->slots[i].value);
}

void Impl::sync_window(Elem* list, bool model_changed) noexcept {
    if (list->v_syncing) {
        list->v_again = true;
        return;
    }
    list->v_syncing = true;
    do {
        list->v_again = false;
        int32_t mi = find(list, a_model);
        Value model = mi >= 0 ? list->slots[mi].value : Value::undefined();
        Arr* a = model.is(Kind::array) ? model.as<Arr>() : nullptr;
        uint32_t n = a ? a->length : 0;
        if (model.is_num()) {
            double d = model.as_num();
            n = d > 0 && d < 2147483648.0 ? static_cast<uint32_t>(d) : 0;
        }
        auto item = [&](uint32_t i) {
            return !a ? Value::num(i) : a->items[i].is_hole() ? Value::undefined() : a->items[i];
        };
        if (!list->v_count) {
            list->v_count = 32;
            if (int32_t fi = find(list, a_follow); fi >= 0 && to_boolean(list->slots[fi].value) && n > list->v_count)
                list->v_first = n - list->v_count;
        }
        uint32_t first = list->v_first < n ? list->v_first : n;
        uint32_t want = list->v_count < n - first ? list->v_count : n - first;
        int32_t ki = find(list, a_modelKey);
        const Value key = ki >= 0 ? list->slots[ki].value : Value::undefined();
        const bool keyed = !key.is_undefined();
        if (!keyed && list->k_named)
            break;
        const uint32_t have_n = list->children.size;
        bool* have = tmp.array<bool>(want);
        Elem **spare = tmp.array<Elem*>(have_n), **keep = tmp.array<Elem*>(have_n);
        uint32_t* at_of = tmp.array<uint32_t>(have_n);
        Str** keys = keyed ? tmp.array<Str*>(want + 1) : nullptr;
        if (!have || !spare || !keep || !at_of || (keyed && !keys))
            break;
        auto key_at = [&](uint32_t k) {
            if (!keys[k])
                keys[k] = row_key(list, key, item(first + k), first + k);
            return keys[k];
        };
        int64_t moved = 0;
        auto now_at = [&](Elem* c) -> uint32_t {
            const uint32_t was = c->row ? c->row - 1 : n;
            if (!keyed || !model_changed)
                return was;
            if (!c->has_pane_key)
                return n;
            const std::u16string_view ck = c->pane_key->view();
            if (was >= first && was - first < want && !have[was - first] && key_at(was - first)->view() == ck)
                return was;
            if (const int64_t g = int64_t(was) - moved; moved && g >= first && g - first < want && !have[g - first]
                && key_at(uint32_t(g - first))->view() == ck)
                return uint32_t(g);
            for (uint32_t k = 0; k < want; k++)
                if (!have[k] && key_at(k)->view() == ck) {
                    moved = int64_t(was) - (first + k);
                    return first + k;
                }
            return n;
        };
        uint32_t spares = 0, kept = 0;
        for (uint32_t j = 0; j < have_n; j++) {
            Elem* c = list->children[j];
            const uint32_t at = now_at(c);
            if (at >= first && at - first < want && !have[at - first]) {
                have[at - first] = true, keep[kept] = c, at_of[kept] = at, kept++;
            } else {
                spare[spares++] = c;
            }
        }
        if (keyed && model_changed && kept) {
            int64_t d = 0;
            bool one = true;
            for (uint32_t j = 0; j < kept && one; j++) {
                const int64_t dj = keep[j]->row ? int64_t(keep[j]->row) - 1 - at_of[j] : 0;
                if (!keep[j]->row)
                    one = false;
                else if (!j)
                    d = dj;
                else
                    one = dj == d;
            }
            if (one && d && d > -2147483648LL && d < 2147483648LL)
                sink.shift(list->uid, static_cast<int32_t>(d));
        }
        if (n != list->v_total || model_changed)
            sink.rows(list->uid, n), list->v_total = n;
        for (uint32_t j = 0; j < kept; j++) {
            Elem* c = keep[j];
            if (c->row != at_of[j] + 1)
                c->row = at_of[j] + 1, sink.row(c->uid, at_of[j]);
        }
        for (uint32_t j = 0; model_changed && j < kept; j++) {
            Elem* c = keep[j];
            write_name(c, a_modelData, item(c->row - 1), true);
            write_name(c, a_index, Value::num(c->row - 1), true);
        }
        uint32_t taken = 0;
        for (uint32_t k = 0; k < want; k++) {
            if (have[k])
                continue;
            uint32_t i = first + k;
            if (taken < spares) {
                Elem* c = spare[taken++];
                c->row = i + 1;
                if (keyed)
                    c->pane_key = key_at(k), c->has_pane_key = true;
                sink.row(c->uid, i);
                write_name(c, a_modelData, item(i), true);
                write_name(c, a_index, Value::num(i), true);
            } else {
                uint32_t before = list->children.size;
                instantiate(list, i, item(i), nullptr);
                if (list->children.size > before) {
                    Elem* c = list->children[list->children.size - 1];
                    c->row = i + 1;
                    if (keyed)
                        c->pane_key = key_at(k), c->has_pane_key = true;
                    sink.row(c->uid, i);
                }
            }
        }
        for (; taken < spares; taken++)
            destroy(spare[taken]);
        model_changed = list->v_again;
    } while (list->v_again);
    list->v_syncing = false;
}

void Impl::sync_panes(Elem* o) noexcept {
    int32_t mi = find(o, a_model);
    Value iv = entries(mi >= 0 ? o->slots[mi].value : Value::undefined());
    if (!iv.is(Kind::array))
        return;
    Arr* items = iv.as<Arr>();
    uint32_t n = items->length;
    auto item = [&](uint32_t i) {
        return i < items->length && !items->items[i].is_hole() ? items->items[i] : Value::undefined();
    };
    for (Str* which : {a_background, a_overlay}) {
        List<Elem*> have;
        for (Elem* c : o->children)
            if (c->pane_slot == which)
                (void)have.push(tmp, c);
        if (!tpl(o, which)) {
            for (Elem* c : have)
                destroy(c);
            continue;
        }
        Elem** got = tmp.array<Elem*>(n);
        bool* free_ = tmp.array<bool>(have.size);
        if (!got || !free_)
            return;
        for (uint32_t k = 0; k < have.size; k++)
            free_[k] = true;
        auto index_of = [&](Elem* c) {
            for (uint32_t k = 0; k < have.size; k++)
                if (have[k] == c)
                    return k;
            return have.size;
        };
        auto take = [&](uint32_t i, Elem* c) {
            if (!c)
                return false;
            uint32_t k = index_of(c);
            if (k == have.size || !free_[k])
                return false;
            got[i] = c, free_[k] = false;
            return true;
        };
        auto by_key = [&](Str* key) -> Elem* {
            for (Elem* c : have)
                if (c->has_pane_key && c->pane_key->view() == key->view())
                    return c;
            return nullptr;
        };
        auto block_of = [&](Value p) -> Str* {
            if (!to_boolean(p))
                return rt.empty;
            Value id = get(rt, p, a_id);
            if (id.is_undefined())
                return rt.empty;
            Str* s = to_string(rt, id);
            return s ? s : rt.empty;
        };
        auto is_live = [&](Value it) { return !(to_boolean(it) && to_boolean(get(rt, it, a_preview))); };
        for (uint32_t i = 0; i < n; i++)
            if (!got[i])
                take(i, by_key(pane_key(item(i))));
        for (bool pass : {true, false}) {
            for (uint32_t i = 0; i < n; i++) {
                if (got[i] || is_live(item(i)) != pass)
                    continue;
                Str* b = block_of(item(i));
                for (Elem* c : have) {
                    int32_t pi = find(c, a_pane);
                    Value pv = pi >= 0 ? c->slots[pi].value : Value::undefined();
                    if (block_of(pv)->view() == b->view() && take(i, c))
                        break;
                }
            }
        }
        List<Elem*> spare;
        for (uint32_t k = 0; k < have.size; k++)
            if (free_[k])
                (void)spare.push(tmp, have[k]);
        uint32_t spare_at = 0;
        for (uint32_t i = 0; i < n; i++) {
            if (!got[i] && spare_at < spare.size)
                take(i, spare[spare_at++]);
            Elem* c = got[i];
            if (!c) {
                instantiate(o, i, item(i), which);
                continue;
            }
            Str* key = pane_key(item(i));
            if (!c->has_pane_key || c->pane_key->view() != key->view()) {
                native_set(c, "paneId", val(key));
                c->pane_key = key;
                c->has_pane_key = true;
            }
            write_name(c, a_pane, item(i), true);
            write_name(c, a_modelData, item(i), true);
            write_name(c, a_index, Value::num(i), true);
        }
        for (uint32_t k = spare_at; k < spare.size; k++)
            destroy(spare[k]);
    }
}

Value Impl::json_parse(std::string_view text, bool& ok) noexcept {
    Str* s = rt.str_utf8(text);
    Value fn = get(rt, get(rt, Value::cell(&rt.globals->h), atom("JSON")), atom("parse"));
    Value arg = s ? val(s) : Value::undefined();
    Value v = vm.call(fn, Value::undefined(), &arg, 1);
    ok = !rt.failed;
    rt.clear();
    return v;
}

std::string_view Impl::json(Value v) noexcept {
    rt.clear();
    Value fn = get(rt, get(rt, Value::cell(&rt.globals->h), atom("JSON")), atom("stringify"));
    Value s = vm.call(fn, Value::undefined(), &v, 1);
    if (rt.failed) {
        rt.clear();
        Str* t = to_string(rt, v);
        s = t ? val(t) : Value::undefined();
        rt.clear();
    }
    if (!s.is(Kind::string))
        return "undefined";
    Str* t = s.as<Str>();
    size_t need = t->length * 3 + 1;
    if (need > jcap) {
        jbuf = static_cast<char*>(arena.alloc(need * 2, 1));
        jcap = jbuf ? need * 2 : 0;
        if (!jbuf)
            return "";
    }
    return {jbuf, utf8(t->view(), jbuf)};
}

namespace {
Value m_signal(Vm& vm, Value self, const Value* args, uint32_t argc) noexcept;
}
NativeFn Impl::signal_method() noexcept {
    return m_signal;
}

bool Impl::key_heard(uint32_t uid, std::string_view signal, const Value* args, uint32_t argc) noexcept {
    Elem* o = obj(uid);
    if (!o || signal.empty())
        return false;
    char c0 = signal[0] >= 'a' && signal[0] <= 'z' ? static_cast<char>(signal[0] - 32) : signal[0];
    Str* hn = atom(tcat({"on", std::string_view(&c0, 1), signal.substr(1)}));
    bool taken = false;
    for (uint32_t k = 0; k < o->handlers.size; k++) {
        if (o->handlers[k].name != hn)
            continue;
        const Handler& h = o->handlers[k];
        Binding* prev = current;
        current = nullptr;
        bool ok;
        Value r = run(h.code, h.ctx, args, argc, ok);
        if (!ok) {
            Value e = thrown_value();
            rt.clear();
            report(h.file, h.line, e);
        } else if (r.is_bool() && to_boolean(r)) {
            taken = true;
        }
        current = prev;
        flush();
    }
    return taken;
}

void Impl::emit(uint32_t uid, std::string_view signal, const Value* args, uint32_t argc) noexcept {
    Elem* o = obj(uid);
    if (!o || signal.empty())
        return;
    char c0 = signal[0] >= 'a' && signal[0] <= 'z' ? static_cast<char>(signal[0] - 32) : signal[0];
    Str* hn = atom(tcat({"on", std::string_view(&c0, 1), signal.substr(1)}));
    for (uint32_t k = 0; k < o->handlers.size; k++)
        if (o->handlers[k].name == hn)
            call(o->handlers[k], args, argc);
}

bool Impl::changes(Value cur, Value patch) noexcept {
    if (!to_boolean(cur) || !cur.is_cell() || cur.is(Kind::string) || cur.is(Kind::function) || cur.is(Kind::native))
        return true;
    Arr* keys = own_keys(rt, patch);
    if (!keys)
        return true;
    for (uint32_t i = 0; i < keys->length; i++) {
        Str* k = keys->items[i].as<Str>();
        bool has = cur.is(Kind::object) ? !rt.get_own(cur.as<Obj>(), k).is_hole() : !get(rt, cur, k).is_undefined();
        if (!has)
            return true;
        Value a = get(rt, cur, k), b = get(rt, patch, k);
        if (strict_equals(a, b))
            continue;
        auto objectish = [](Value x) {
            return to_boolean(x) && x.is_cell() && !x.is(Kind::string) && !x.is(Kind::function) && !x.is(Kind::native);
        };
        if (objectish(a) && objectish(b)) {
            std::string_view ja = tmp.copy(json(a)), jb = json(b);
            if (ja == jb)
                continue;
        }
        return true;
    }
    return false;
}

Elem* Impl::global(std::string_view name, std::string_view json_initial) noexcept {
    Elem* g = new_elem(-1, name);
    if (!g)
        return nullptr;
    bool ok;
    Value init = json_parse(json_initial, ok);
    if (!ok || !init.is(Kind::object))
        return nullptr;
    Arr* keys = own_keys(rt, init);
    for (uint32_t i = 0; keys && i < keys->length; i++) {
        Str* k = keys->items[i].as<Str>();
        if (!define(g, ascii(arena, k), get(rt, init, k), false))
            return nullptr;
    }
    if (!globals.push(arena, Global{name, g}))
        return nullptr;
    rt.put(rt.globals, atom(name), Value::cell(&g->h));
    return g;
}

void Impl::set_global(Elem* g, Value t) noexcept {
    bool was = flushing;
    flushing = true;
    if (t.is_cell() && !t.is(Kind::string)) {
        for (uint32_t i = 0; i < g->n_slots; i++) {
            PSlot& s = g->slots[i];
            if (s.kind != SK::prop || !s.named)
                continue;
            Str* k = s.name;
            bool has = t.is(Kind::object) ? !rt.get_own(t.as<Obj>(), k).is_hole() : false;
            if (has)
                write(g, i, get(rt, t, k), true);
        }
    }
    if (t.is(Kind::object)) {
        Value add = rt.get_own(t.as<Obj>(), atom("consoleAdd"));
        const int32_t ci = add.is(Kind::array) ? find(g, atom("console")) : -1;
        if (ci >= 0) {
            constexpr uint32_t k_kept = 500;
            Value cur = g->slots[ci].value;
            Arr* old = cur.is(Kind::array) ? cur.as<Arr>() : nullptr;
            Arr* na = add.as<Arr>();
            const uint32_t on = old ? old->length : 0, nn = na->length;
            const uint32_t skip = nn > k_kept ? nn - k_kept : 0, keep = std::min(on, k_kept - (nn - skip));
            if (Arr* a = rt.array(keep + nn - skip)) {
                for (uint32_t i = on - keep; i < on; i++)
                    rt.push(a, old->items[i].is_hole() ? Value::undefined() : old->items[i]);
                for (uint32_t i = skip; i < nn; i++)
                    rt.push(a, na->items[i].is_hole() ? Value::undefined() : na->items[i]);
                write(g, static_cast<uint32_t>(ci), val(a), true);
            }
        }
    }
    flushing = was;
    flush();
}

namespace {

Impl* native_doc(Vm& vm) {
    return static_cast<Impl*>(vm.rt.user);
}

std::string_view str8(Impl* d, Str* s) {
    char* b = static_cast<char*>(d->tmp.alloc(s->length * 3 + 1, 1));
    return b ? std::string_view{b, utf8(s->view(), b)} : std::string_view{};
}

Value m_signal(Vm& vm, Value self, const Value* args, uint32_t argc) noexcept {
    Impl* d = native_doc(vm);
    if (!self.is(Kind::element) || !vm.native)
        return Value::undefined();
    Value buf[16];
    uint32_t n = 0;
    for (; n < argc && n < 16; n++)
        buf[n] = args[n];
    d->emit(self.as<Elem>()->uid, str8(d, vm.native->name), buf, n);
    return Value::undefined();
}

Value m_method(Vm& vm, Value self, const Value* args, uint32_t argc) noexcept {
    Impl* d = native_doc(vm);
    if (!self.is(Kind::element) || !vm.native)
        return Value::undefined();
    Elem* o = self.as<Elem>();
    std::string_view m = str8(d, vm.native->name);
    Value a0 = lib::arg(args, argc, 0);
    if (m == "send") {
        if (a0.is(Kind::string))
            d->sink.send(o->uid, str8(d, a0.as<Str>()));
        else
            d->sink.send(o->uid, d->tmp.copy(d->json(a0)));
    } else if (m == "call") {
        Value argv[3] = {Value::undefined(), Value::num(static_cast<double>(o->uid)), a0};
        Str* op = vm.rt.str_ascii("call");
        if (!op)
            return Value::undefined();
        argv[0] = val(op);
        return d->sink.api(*d->self, "__native", "process", argv, 3);
    } else if (m == "recordKey") {
        d->sink.call(o->uid, "recordKey", a0.is_undefined() || to_boolean(a0) ? "" : "stop");
    } else if (m == "forceActiveFocus") {
        d->sink.call(o->uid, "focus", "");
    } else if (m == "start" || m == "stop" || m == "restart") {
        if (m == "restart")
            d->elem_set(o, d->a_running, Value::boolean(false));
        d->elem_set(o, d->a_running, Value::boolean(m != "stop"));
    } else if (m == "seek") {
        double at = lib::arg(args, argc, 0).is_num() ? lib::arg(args, argc, 0).as_num() : 0;
        char b[32];
        int len = std::snprintf(b, sizeof b, "%g", at);
        d->sink.call(o->uid, m, std::string_view(b, static_cast<size_t>(len)));
    } else if (m == "scrollTo") {
        double x = lib::arg(args, argc, 0).is_num() ? lib::arg(args, argc, 0).as_num() : 0,
               y = lib::arg(args, argc, 1).is_num() ? lib::arg(args, argc, 1).as_num() : 0;
        char b[64];
        int len = std::snprintf(b, sizeof b, "%g,%g", x, y);
        d->sink.call(o->uid, m, std::string_view(b, static_cast<size_t>(len)));
    } else if (m == "select") {
        double x = lib::arg(args, argc, 0).is_num() ? lib::arg(args, argc, 0).as_num() : 0,
               y = lib::arg(args, argc, 1).is_num() ? lib::arg(args, argc, 1).as_num() : x;
        char b[64];
        int len = std::snprintf(b, sizeof b, "%g,%g", x, y);
        d->sink.call(o->uid, m, std::string_view(b, static_cast<size_t>(len)));
    } else if (m == "find") {
        Str* u = to_string(vm.rt, a0);
        if (u)
            d->sink.call(o->uid, to_boolean(lib::arg(args, argc, 1)) ? "findBack" : "find", str8(d, u));
    } else if (m == "load" || m == "append" || m == "insert") {
        Str* u = to_string(vm.rt, a0);
        if (u)
            d->sink.call(o->uid, m, str8(d, u));
    } else {
        d->sink.call(o->uid, m, "");
    }
    return Value::undefined();
}

Value m_native(Vm& vm, Value, const Value* args, uint32_t argc) noexcept {
    Impl* d = native_doc(vm);
    if (!vm.native)
        return Value::undefined();
    return d->sink.api(*d->self, "__native", str8(d, vm.native->name), args, argc);
}

Value m_define(Vm& vm, Value, const Value* args, uint32_t argc) noexcept {
    Impl* d = native_doc(vm);
    Rt& rt = vm.rt;
    Value o = lib::arg(args, argc, 0), desc = lib::arg(args, argc, 2);
    Str* k = to_property_key(rt, lib::arg(args, argc, 1));
    if (!k)
        return Value::undefined();
    Value v = desc.is_cell() ? get(rt, desc, rt.atom(rt.str_ascii("value"))) : Value::undefined();
    if (rt.failed)
        return Value::undefined();
    if (!o.is(Kind::element) && !o.is(Kind::object) && (!o.is_cell() || o.is(Kind::string)))
        return lib::type_error(rt, "Object.defineProperty called on non-object");
    globals::define(*d, o, k, v);
    return o;
}

namespace pretty_json {

constexpr size_t k_width = 72;
constexpr int k_depth = 64;

struct Out {
    char* p = nullptr;
    size_t n = 0;
    void put(char c) noexcept {
        if (p)
            p[n] = c;
        n++;
    }
    void put(std::string_view s) noexcept {
        if (p)
            std::memcpy(p + n, s.data(), s.size());
        n += s.size();
    }
    void pad(size_t k) noexcept {
        for (size_t i = 0; i < k; i++)
            put(' ');
    }
};

size_t end_of(std::string_view s, size_t i, size_t& width) noexcept {
    const size_t from = i;
    if (s[i] == '"') {
        for (i++; i < s.size() && s[i] != '"'; i++)
            if (s[i] == '\\')
                i++;
        width = i + 1 - from;
        return i + 1;
    }
    if (s[i] != '{' && s[i] != '[') {
        while (i < s.size() && s[i] != ',' && s[i] != ']' && s[i] != '}')
            i++;
        width = i - from;
        return i;
    }
    size_t spaces = 0;
    int nest = 0;
    for (bool str = false; i < s.size(); i++) {
        const char c = s[i];
        if (str) {
            if (c == '\\')
                i++;
            else if (c == '"')
                str = false;
        } else if (c == '"')
            str = true;
        else if (c == '{' || c == '[')
            nest++;
        else if (c == ',' || c == ':')
            spaces++;
        else if ((c == '}' || c == ']') && --nest == 0) {
            width = i + 1 - from + spaces;
            return i + 1;
        }
    }
    width = s.size() - from + spaces;
    return s.size();
}

void spaced(Out& o, std::string_view v) noexcept {
    bool str = false;
    for (size_t i = 0; i < v.size(); i++) {
        const char c = v[i];
        o.put(c);
        if (str) {
            if (c == '\\' && i + 1 < v.size())
                o.put(v[++i]);
            else if (c == '"')
                str = false;
        } else if (c == '"')
            str = true;
        else if (c == ',' || c == ':')
            o.put(' ');
    }
}

bool scalars(std::string_view s, size_t i, size_t end) noexcept {
    for (bool str = false; i < end; i++) {
        const char c = s[i];
        if (str) {
            if (c == '\\')
                i++;
            else if (c == '"')
                str = false;
        } else if (c == '"')
            str = true;
        else if (c == '{' || c == '[')
            return false;
    }
    return true;
}

void value(Out& o, std::string_view s, size_t i, size_t end, size_t indent, size_t col, int depth) noexcept {
    size_t width = 0;
    end_of(s, i, width);
    const char open = s[i];
    if ((open != '{' && open != '[') || col + width <= k_width || end - i <= 2 || depth >= k_depth) {
        spaced(o, s.substr(i, end - i));
        return;
    }
    const char close = open == '{' ? '}' : ']';
    o.put(open);
    size_t j = i + 1;
    if (open == '[' && scalars(s, j, end - 1)) {
        size_t col2 = k_width;
        while (j < end - 1) {
            size_t w = 0;
            const size_t e = end_of(s, j, w);
            const bool more = e < end - 1;
            if (col2 + w + (more ? 1 : 0) > k_width) {
                o.put('\n');
                o.pad(indent + 2);
                col2 = indent + 2;
            } else {
                o.put(' ');
                col2++;
            }
            o.put(s.substr(j, e - j));
            col2 += w;
            j = e;
            if (more) {
                o.put(',');
                col2++;
                j++;
            }
        }
        o.put('\n');
        o.pad(indent);
        o.put(close);
        return;
    }
    while (j < end - 1) {
        o.put('\n');
        o.pad(indent + 2);
        size_t col2 = indent + 2;
        if (open == '{') {
            size_t kw = 0;
            const size_t k = end_of(s, j, kw);
            o.put(s.substr(j, k - j));
            o.put(": ");
            col2 += (k - j) + 2;
            j = k + 1;
        }
        size_t w = 0;
        const size_t e = end_of(s, j, w);
        value(o, s, j, e, indent + 2, col2, depth + 1);
        j = e;
        if (j < end - 1 && s[j] == ',') {
            o.put(',');
            j++;
        }
    }
    o.put('\n');
    o.pad(indent);
    o.put(close);
}

std::string_view print(Arena& a, std::string_view compact) noexcept {
    if (compact.size() < 2 || (compact[0] != '{' && compact[0] != '['))
        return compact;
    Out count;
    value(count, compact, 0, compact.size(), 0, 0, 0);
    char* p = static_cast<char*>(a.alloc(count.n, 1));
    if (!p)
        return compact;
    Out write{p, 0};
    value(write, compact, 0, compact.size(), 0, 0, 0);
    return {p, write.n};
}

}

Value m_console(Vm& vm, Value, const Value* args, uint32_t argc) noexcept {
    Impl* d = native_doc(vm);
    std::string_view level = vm.native ? str8(d, vm.native->name) : "log";
    std::string_view out;
    for (uint32_t i = 0; i < argc; i++) {
        std::string_view part;
        if (args[i].is(Kind::string))
            part = str8(d, args[i].as<Str>());
        else {
            part = d->json(args[i]);
            if (part == "undefined")
                part = "";
            part = pretty_json::print(d->tmp, d->tmp.copy(part));
        }
        out = i ? d->tcat({out, " ", part}) : part;
    }
    vm.rt.clear();
    d->sink.log(out, level);
    return Value::undefined();
}

struct GlobalDef {
    const char *name, *initial;
};
constexpr GlobalDef k_globals[] = {
    {"theme", R"({"background":"#000000","foreground":"#ffffff","dark":true})"},
    {"i18n", R"({"language":"en","locale":"en-GB","strings":{}})"},
    {"conf", R"({"values":{}})"},
    {"keys", R"({"list":[],"pending":{"modes":[],"keys":[]},"hints":false})"},
    {"panes",
     R"({"list":[],"focused":"","zoomed":"","busy":false,"arriving":"","fps":{},"previews":[],"area":{"width":0,"height":0}})"},
    {"pane", R"({"id":"","args":[],"width":0,"height":0})"},
    {"context", R"({"hasSelection":false,"block":{},"hoveredLink":""})"},
    {"notices", R"({"list":[],"badge":"","taking":false})"},
    {"activity", R"({"list":[],"blocks":{},"tabs":{},"urgent":null})"},
    {"diagnostics",
     R"({"binary":{},"server":{},"sync":{},"gpu":{},"calls":[],"events":[],"eventState":"inactive","eventError":"","following":false})"},
    {"shared", R"({"values":{}})"},
    {"clipboard", R"({})"},
    {"loading", R"({"active":false,"progress":0,"ready":false,"stage":"","elapsed":0})"},
    {"windows", R"({"held":[],"guarding":false})"},
    {"power", R"({"low":false,"battery":false,"thermal":"nominal","saving":false})"},
    {"rex", R"({"tab":0,"tabs":0,"titles":[],"session":"","sessionId":"","sessions":[],"fps":0})"},
    {"debug",
     R"({"enabled":false,"options":{},"docs":[],"selected":null,"hovered":null,"picking":false,"console":[],"revision":0,"revisions":{},"theme":{},"here":{},"paned":false,"agents":[],"agentsFinding":false,"agentRunning":false,"lastAgent":"","picked":0,"panedFiles":[],"selectedRevision":0})"},
};

}

bool Impl::install_globals() noexcept {
    rt.put(rt.globals, atom("globalThis"), val(rt.globals));
    for (const GlobalDef& gd : k_globals)
        if (!global(gd.name, gd.initial))
            return false;
    Obj* nat = rt.object();
    if (!nat)
        return false;
    for (const char* n : {"debug", "activity", "rexstate", "notices", "diagnostics", "windows", "loading", "files",
                          "rex", "shared", "clipboard"}) {
        Native* f = rt.native(n, m_native, 0);
        if (!f)
            return false;
        rt.put(nat, atom(n), val(f));
    }
    rt.put(rt.globals, atom("__native"), val(nat));
    Value object = rt.get_own(rt.globals, atom("Object"));
    Native* def = rt.native("defineProperty", m_define, 3);
    if (!object.is(Kind::object) || !def)
        return false;
    rt.put(object.as<Obj>(), atom("defineProperty"), val(def));
    if (!global("files", "{}"))
        return false;
    return globals::install(*this);
}

bool Impl::init() noexcept {
    rt.user = this;
    rt.hooks = &k_hooks;
    if (!lib::install(rt))
        return false;
    a_model = atom("model"), a_modelData = atom("modelData"), a_index = atom("index"), a_pane = atom("pane");
    a_active = atom("active"), a_source = atom("source"), a_ready = atom("ready"), a_loadNow = atom("loadNow"),
    a_loaderScope = atom("loaderScope"), a_open = atom("open"), a_lazy = atom("lazy"), a_modelKey = atom("modelKey");
    a_status = atom("status"), a_position = atom("position"), a_duration = atom("duration"),
    a_pressed = atom("pressed"), a_running = atom("running");
    a_cursorPosition = atom("cursorPosition"), a_selectionStart = atom("selectionStart"),
    a_selectionEnd = atom("selectionEnd");
    a_layoutWidth = atom("layoutWidth"), a_layoutHeight = atom("layoutHeight"), a_contentX = atom("contentX"),
    a_contentY = atom("contentY");
    a_state = atom("state"), a_text = atom("text"), a_visible = atom("visible"), a_delegate = atom("delegate");
    a_background = atom("background"), a_overlay = atom("overlay"), a_message = atom("message"), a_id = atom("id");
    a_key = atom("key"), a_preview = atom("preview"), a_list = atom("list"), a_previews = atom("previews");
    a_virtualized = atom("virtualized");
    a_follow = atom("follow");
    for (int p = 0; p < static_cast<int>(sch::Prop::count_); p++)
        prop_atom[p] = atom(sch::k_props[p].name);
    for (size_t k = 0; k + 1 < sizeof sch::k_prop_defs / sizeof sch::k_prop_defs[0]; k++) {
        bool ok = true;
        if (sch::k_prop_defs[k].def == sch::Def::literal)
            def_val[k] = json_parse(sch::k_prop_defs[k].json, ok);
        else
            def_val[k] = Value::undefined();
        if (!ok)
            return false;
    }
    method_table = rt.object();
    if (!method_table)
        return false;
    for (std::string_view m : sch::k_methods) {
        if (m.empty() || !rt.get_own(method_table, atom(m)).is_hole())
            continue;
        Native* n = rt.native("method", m_method, 0);
        if (!n)
            return false;
        n->name = atom(m);
        rt.put(method_table, atom(m), val(n));
    }
    Obj* console = rt.object();
    if (!console)
        return false;
    for (const char* lv : {"log", "warn", "error"}) {
        Native* n = rt.native(lv, m_console, 0);
        if (!n)
            return false;
        n->name = atom(lv);
        rt.put(console, atom(lv), val(n));
    }
    rt.put(rt.globals, atom("console"), val(console));
    return install_globals();
}

std::string_view Impl::load(std::string_view src0, std::string_view name, std::string_view path) noexcept {
    std::string_view src = copy(src0);
    if (src0.size() && src.empty())
        return "out of memory";
    name = copy(name);
    top_path = path.empty() ? std::string_view{} : normalize(copy(path));
    building = true;
    err = LoadError{};
    vm.budget = 100000000;
    auto result = [&]() -> std::string_view {
        if (!err.set)
            return cat({name, ": failed"});
        std::string_view m = cat({err.file.empty() ? name : err.file, ":", num8(err.line), ": ", err.msg});
        if (err.uses.size) {
            std::string_view u;
            for (uint32_t k = err.uses.size; k-- > 0;)
                u = u.empty() ? err.uses[k] : cat({u, " <- ", err.uses[k]});
            m = cat({m, " (used at ", u, ")"});
        }
        return m;
    };
    auto ast = rui::parse(src, arena);
    if (!ast) {
        building = false;
        return cat({name, ":", num8(ast.error().line), ": ", ast.error().msg});
    }
    rui::File* f = *ast;
    std::string_view top = f->root->type;
    if (top != "Dock" && top != "Panes") {
        building = false;
        sch::Elem e;
        std::string_view m = cat({"the top element must be a Dock (or Panes), not ", top});
        if (!sch::elem_of(top, &e))
            m = cat({m, " (a component, ", top, ".rui, is used from another file)"});
        return cat({name, ":", num8(f->root->line), ": ", m});
    }
    List<UseDir> uses;
    for (const rui::Use& u : f->uses)
        (void)uses.push(arena, UseDir{folder(top_path, u.path), u.as});
    Scope* sc = new_scope(name, top_path, uses, true, "");
    if (!sc)
        return "out of memory";
    sc->src = src;
    Pending p{};
    Elem* r;
    if (!create(f->root, nullptr, p, sc, nullptr, false, r)) {
        building = false;
        return result();
    }
    root = sc->root = r;
    top_sc = sc;
    if (top == "Panes" && !p.bindings.push(tmp, Pending::B{root, "model", nullptr, f->root->line, sc, nullptr, false}))
        return "out of memory";
    if (!bind_all(p)) {
        building = false;
        return result();
    }
    building = false;
    flush();
    for (const Handler& h : p.completed)
        call(h, nullptr, 0);
    end_job();
    return "";
}

Doc::Doc(Sink& sink) noexcept {
    void* p = ::operator new(sizeof(Impl), std::nothrow);
    impl_ = p ? new (p) Impl(sink) : nullptr;
    if (impl_) {
        impl_->self = this;
        if (!impl_->init()) {
            impl_->~Impl();
            ::operator delete(impl_);
            impl_ = nullptr;
        }
    }
}

Doc::~Doc() {
    if (impl_) {
        impl_->~Impl();
        ::operator delete(impl_);
    }
}

std::string_view Doc::load(std::string_view src, std::string_view name, std::string_view path) noexcept {
    return impl_ ? impl_->load(src, name, path) : "out of memory";
}

void Doc::emit(uint32_t uid, std::string_view signal, std::string_view json_args) noexcept {
    Impl& d = *impl_;
    d.vm.budget = 100000000;
    bool ok;
    Value a = json_args.empty() ? Value::undefined() : d.json_parse(json_args, ok);
    Value buf[16];
    uint32_t n = 0;
    if (a.is(Kind::array))
        for (uint32_t i = 0; i < a.as<Arr>()->length && n < 16; i++)
            buf[n++] = a.as<Arr>()->items[i];
    d.emit(uid, signal, buf, n);
    d.end_job();
}

void Doc::line(uint32_t uid, std::string_view text) noexcept {
    Impl& d = *impl_;
    d.vm.budget = 100000000;
    Elem* o = d.obj(uid);
    if (!o)
        return;
    Str* t = d.rt.str_utf8(text);
    Value msg = t ? val(t) : Value::undefined();
    bool ok;
    Value parsed = d.json_parse(text, ok);
    if (ok)
        msg = parsed;
    if (to_boolean(msg) && msg.is(Kind::object)) {
        Value st = get(d.rt, msg, d.a_state);
        d.rt.clear();
        bool objectish =
            to_boolean(st) && st.is_cell() && !st.is(Kind::string) && !st.is(Kind::function) && !st.is(Kind::native);
        int32_t si = d.find(o, d.a_state);
        Value cur = si >= 0 ? o->slots[si].value : Value::undefined();
        if (objectish && d.changes(cur, st)) {
            Obj* m = d.rt.object();
            for (Value src : {cur, st}) {
                if (!to_boolean(src) || !src.is_cell())
                    continue;
                Arr* keys = own_keys(d.rt, src);
                for (uint32_t i = 0; keys && i < keys->length; i++) {
                    Str* k = keys->items[i].as<Str>();
                    d.rt.put(m, k, get(d.rt, src, k));
                }
            }
            d.rt.clear();
            if (m)
                d.write_name(o, d.a_state, val(m), true);
        }
    }
    d.emit(uid, "message", &msg, 1);
    d.end_job();
}

void Doc::message(uint32_t uid, std::string_view text) noexcept {
    Impl& d = *impl_;
    d.vm.budget = 100000000;
    if (!d.obj(uid))
        return;
    Str* t = d.rt.str_utf8(text);
    Value msg = t ? val(t) : Value::undefined();
    bool ok;
    Value parsed = d.json_parse(text, ok);
    if (ok)
        msg = parsed;
    d.emit(uid, "message", &msg, 1);
    d.end_job();
}

void Doc::input(uint32_t uid, std::string_view text) noexcept {
    Impl& d = *impl_;
    d.vm.budget = 100000000;
    if (Elem* o = d.obj(uid)) {
        Str* t = d.rt.str_utf8(text);
        if (t)
            d.write_name(o, d.a_text, val(t), false);
    }
    d.end_job();
}

void Doc::window(uint32_t uid, uint32_t first, uint32_t count) noexcept {
    Impl& d = *impl_;
    d.vm.budget = 100000000;
    if (Elem* o = d.obj(uid); o && d.virtualized(o))
        o->v_asked = true;
    if (Elem* o = d.obj(uid); o && d.virtualized(o) && (first != o->v_first || count != o->v_count)) {
        o->v_first = first, o->v_count = count;
        d.sync_window(o, false);
        Value args[2] = {Value::num(first), Value::num(count)};
        d.emit(uid, "window", args, 2);
    }
    d.end_job();
}

void Doc::update(uint32_t uid, std::string_view json_values) noexcept {
    Impl& d = *impl_;
    d.vm.budget = 100000000;
    Elem* o = d.obj(uid);
    bool ok;
    Value v = d.json_parse(json_values, ok);
    if (o && ok && v.is(Kind::object)) {
        Arr* keys = own_keys(d.rt, v);
        for (uint32_t i = 0; keys && i < keys->length; i++) {
            Str* k = keys->items[i].as<Str>();
            int32_t s = d.find(o, k);
            if (s >= 0 && o->slots[s].named)
                d.write(o, static_cast<uint32_t>(s), get(d.rt, v, k), true);
        }
    }
    d.end_job();
}

void Doc::toggle(uint32_t uid) noexcept {
    Impl& d = *impl_;
    d.vm.budget = 100000000;
    if (Elem* o = d.obj(uid))
        d.elem_set(o, d.a_visible, Value::boolean(!to_boolean(d.elem_get(o, d.a_visible))));
    d.end_job();
}

bool Doc::set_global(std::string_view name, std::string_view json) noexcept {
    Impl& d = *impl_;
    d.vm.budget = 100000000;
    for (const Impl::Global& g : d.globals)
        if (g.name == name) {
            bool ok;
            Value t = d.json_parse(json, ok);
            if (ok)
                d.set_global(g.o, t);
            d.end_job();
            return ok;
        }
    return false;
}

bool Doc::wants(std::string_view global, std::string_view key) const noexcept {
    Impl& d = *impl_;
    for (const Impl::Global& g : d.globals)
        if (g.name == global) {
            int32_t i = d.find(g.o, d.atom(key));
            return i >= 0 && g.o->slots[i].deps.head;
        }
    return false;
}

bool Doc::replay(std::string_view method, std::string_view json_args, std::string_view& result) noexcept {
    Impl& d = *impl_;
    d.replays++;
    struct Out {
        Impl& d;
        ~Out() { d.replays--; }
    } out{d};
    result = "undefined";
    if (d.replays == 1)
        d.vm.budget = 100000000;
    bool ok;
    Value a = d.json_parse(json_args, ok);
    if (!ok || !a.is(Kind::array))
        return false;
    Arr* args = a.as<Arr>();
    auto at = [&](uint32_t i) {
        return i < args->length && !args->items[i].is_hole() ? args->items[i] : Value::undefined();
    };
    auto text = [&](uint32_t i) -> std::string_view {
        Value v = at(i);
        if (!v.is(Kind::string))
            return {};
        return d.tmp.copy(str8(&d, v.as<Str>()));
    };
    auto uid = [&](uint32_t i) { return at(i).is_num() ? static_cast<uint32_t>(at(i).as_num()) : 0u; };
    static constexpr std::pair<std::string_view, std::string_view> k_setters[] = {
        {"setTheme", "theme"},     {"setRex", "rex"},         {"setLang", "i18n"},
        {"setConf", "conf"},       {"setKeys", "keys"},       {"setContext", "context"},
        {"setPanes", "panes"},     {"setNotices", "notices"}, {"setDiagnostics", "diagnostics"},
        {"setWindows", "windows"}, {"setShared", "shared"},   {"setActivity", "activity"},
        {"setPane", "pane"},       {"setDebug", "debug"},     {"setLoading", "loading"},
        {"setPower", "power"}};
    for (auto [m, g] : k_setters)
        if (m == method) {
            for (const Impl::Global& gl : d.globals)
                if (gl.name == g)
                    d.set_global(gl.o, at(0));
            d.end_job();
            return true;
        }
    if (method == "load") {
        std::string_view src = text(0), name = text(1), path = text(2);
        std::string_view err = load(src, name, path);
        result = err.empty() ? std::string_view("\"\"") : d.copy(d.json(val(d.rt.str_utf8(err))));
        return true;
    }
    if (method == "emit") {
        Value sig = at(1), list = at(2);
        Value buf[16];
        uint32_t n = 0;
        if (list.is(Kind::array))
            for (uint32_t i = 0; i < list.as<Arr>()->length && n < 16; i++)
                buf[n++] = list.as<Arr>()->items[i];
        if (sig.is(Kind::string))
            d.emit(uid(0), d.tmp.copy(str8(&d, sig.as<Str>())), buf, n);
        d.end_job();
        return true;
    }
    if (method == "line")
        return line(uid(0), text(1)), true;
    if (method == "input")
        return input(uid(0), text(1)), true;
    if (method == "toggle")
        return toggle(uid(0)), true;
    if (method == "update") {
        std::string_view j = d.tmp.copy(d.json(at(1)));
        update(uid(0), j);
        return true;
    }
    if (method == "keyDelegate") {
        Value list = at(2);
        Value buf[8];
        uint32_t n = 0;
        if (list.is(Kind::array))
            for (uint32_t i = 0; i < list.as<Arr>()->length && n < 8; i++)
                buf[n++] = list.as<Arr>()->items[i];
        const bool taken = d.key_heard(uid(0), text(1), buf, n);
        result = taken ? "true" : "false";
        d.end_job();
        return true;
    }
    if (method == "noticeDelegate" || method == "windowDelegate" || method == "activityDelegate") {
        Value arg = at(0);
        globals::Delegate which = method == "noticeDelegate" ? globals::Delegate::notice
            : method == "windowDelegate"                     ? globals::Delegate::window
                                                             : globals::Delegate::activity;
        Value r = d.rt.failed ? Value::undefined() : globals::ask(d, which, arg);
        d.rt.clear();
        d.flush();
        result = d.copy(d.json(r));
        d.end_job();
        return true;
    }
    return false;
}

bool Doc::parse(std::string_view json, Value& out) noexcept {
    bool ok;
    out = impl_->json_parse(json, ok);
    return ok;
}

Value Doc::tree_rows(Doc& target, const TreeRow* rows, size_t count) noexcept {
    Impl& d = *impl_;
    Impl& t = *target.impl_;
    Rt& rt = d.rt;
    Str *k_uid = d.atom("uid"), *k_type = d.atom("type"), *k_depth = d.atom("depth"), *k_children = d.atom("children"),
        *k_id = d.atom("id"), *k_comp = d.atom("comp"), *k_file = d.atom("file"), *k_line = d.atom("line"),
        *k_visible = d.atom("visible"), *k_width = d.atom("width"), *k_height = d.atom("height");
    struct Kept {
        std::string_view text;
        Value v;
    };
    Kept kept[4] = {};
    auto str = [&](std::string_view text, int i) {
        Kept& k = kept[i];
        if (!k.v.is(Kind::string) || k.text.data() != text.data() || k.text.size() != text.size())
            k.text = text, k.v = val(rt.str_utf8(text));
        return k.v;
    };
    Arr* a = rt.array(static_cast<uint32_t>(count));
    for (size_t i = 0; i < count; i++) {
        TreeRow r;
        std::memcpy(&r, &rows[i], sizeof r);
        Elem* e = t.obj(r.uid);
        Obj* o = rt.object();
        rt.put(o, k_uid, Value::num(r.uid));
        rt.put(o, k_type, str(e ? e->type_name : std::string_view(), 0));
        rt.put(o, k_depth, Value::num(r.depth));
        rt.put(o, k_children, Value::num(r.children));
        rt.put(o, k_id, str(e ? e->id : std::string_view(), 1));
        rt.put(o, k_comp, str(e ? e->comp : std::string_view(), 2));
        rt.put(o, k_file, str(e ? e->file : std::string_view(), 3));
        rt.put(o, k_line, Value::num(e ? e->line : 0));
        rt.put(o, k_visible, Value::boolean(r.visible != 0));
        rt.put(o, k_width, Value::num(r.width));
        rt.put(o, k_height, Value::num(r.height));
        rt.push(a, val(o));
    }
    return val(a);
}

bool Doc::alive(uint32_t uid) const noexcept {
    return impl_->obj(uid) != nullptr;
}

std::string_view Doc::where(uint32_t uid) noexcept {
    Impl& d = *impl_;
    Elem* o = d.obj(uid);
    if (!o)
        return "";
    return d.tcat({o->file, ":", d.num8(o->line, &d.tmp)});
}

uint32_t Doc::promise(Value& out) noexcept {
    Impl& d = *impl_;
    out = lib::promise_new(d.rt);
    for (uint32_t i = 0; i < d.promises.size; i++)
        if (d.promises[i].is_undefined())
            return d.promises[i] = out, i + 1;
    if (!d.promises.push(d.arena, out))
        return 0;
    return d.promises.size;
}

void Doc::settle(uint32_t handle, std::string_view json, bool rejected) noexcept {
    Impl& d = *impl_;
    if (!handle || handle > d.promises.size || d.promises[handle - 1].is_undefined())
        return;
    Value p = d.promises[handle - 1];
    d.promises[handle - 1] = Value::undefined();
    d.vm.budget = 100000000;
    bool ok;
    Value v = json.empty() ? Value::undefined() : d.json_parse(json, ok);
    lib::promise_settle(d.vm, p, v, rejected);
    d.rt.clear();
    d.flush();
    d.end_job();
}

std::string_view Doc::used() noexcept {
    Impl& d = *impl_;
    Arr* a = d.rt.array(d.comps.size);
    for (Comp* c : d.comps)
        if (a)
            d.rt.push(a, val(d.rt.str_utf8(c->path)));
    return d.copy(d.json(a ? val(a) : Value::undefined()));
}

namespace {

Value describe(Impl& d, Value v, int indent = 0) {
    Rt& rt = d.rt;
    if (v.is(Kind::element)) {
        Elem* o = v.as<Elem>();
        return val(
            rt.str_utf8(d.tcat({o->type_name, o->id.empty() ? "" : "#", o->id, " (", d.num8(o->uid, &d.tmp), ")"})));
    }
    if (v.is(Kind::function) || v.is(Kind::native))
        return val(rt.str_utf8("ƒ"));
    if (v.is_undefined() || v.is_hole())
        return val(rt.str_ascii("undefined"));
    const bool nested = indent > 0 && (v.is(Kind::object) || v.is(Kind::array));
    std::string_view j = d.json(v);
    if (nested)
        j = pretty_json::print(d.tmp, d.tmp.copy(j));
    if (v.is(Kind::string) || j != "undefined") {
        Str* s = rt.str_utf8(j);
        if (s && s->length > 400 && !v.is(Kind::string) && !nested)
            s = rt.concat(rt.str({s->units, 400}), rt.str_utf8("…"));
        return s ? val(s) : Value::undefined();
    }
    Str* t = to_string(rt, v);
    rt.clear();
    return t ? val(t) : val(rt.str_ascii("?"));
}

bool literal(std::string_view e) {
    while (!e.empty() && (e.front() == ' ' || e.front() == '\t'))
        e.remove_prefix(1);
    while (!e.empty() && (e.back() == ' ' || e.back() == '\t'))
        e.remove_suffix(1);
    if (e == "true" || e == "false" || e == "null")
        return true;
    if (e.size() >= 2 && (e.front() == '"' || e.front() == '\'') && e.back() == e.front()) {
        for (size_t i = 1; i + 1 < e.size(); i++) {
            if (e[i] == '\\')
                i++;
            else if (e[i] == e.front())
                return false;
        }
        return true;
    }
    size_t i = 0;
    if (i < e.size() && e[i] == '-')
        i++;
    size_t digits = i;
    while (i < e.size() && e[i] >= '0' && e[i] <= '9')
        i++;
    if (i == digits)
        return false;
    if (i < e.size() && e[i] == '.') {
        size_t f = ++i;
        while (i < e.size() && e[i] >= '0' && e[i] <= '9')
            i++;
        if (i == f)
            return false;
    }
    return i == e.size();
}

}

std::string_view Doc::debug(std::string_view op, std::string_view json_args) noexcept {
    Impl& d = *impl_;
    Rt& rt = d.rt;
    d.vm.budget = 100000000;
    bool ok;
    Value a = json_args.empty() ? Value::undefined() : d.json_parse(json_args, ok);
    auto arg = [&](uint32_t i) {
        return a.is(Kind::array) && i < a.as<Arr>()->length ? a.as<Arr>()->items[i] : Value::undefined();
    };
    auto put = [&](Obj* o, const char* k, Value v) { rt.put(o, d.atom(k), v); };
    auto s8 = [&](std::string_view t) { return val(rt.str_utf8(t)); };
    std::string_view out = "null";
    auto done = [&](Value v) {
        out = d.copy(d.json(v));
        rt.clear();
        d.end_job();
        return out;
    };
    if (op == "outline") {
        Obj* o = rt.object();
        for (Elem* e : d.objs) {
            if (!e)
                continue;
            Arr* row = rt.array(4);
            rt.push(row, s8(e->id)), rt.push(row, s8(e->comp)), rt.push(row, s8(e->file)),
                rt.push(row, Value::num(e->line));
            rt.put(o, d.atom(d.num8(e->uid, &d.tmp)), val(row));
        }
        return done(val(o));
    }
    if (op == "inspect") {
        Elem* o = d.obj(arg(0).is_num() ? static_cast<uint32_t>(arg(0).as_num()) : 0);
        if (!o)
            return done(Value::null());
        Arr* props = rt.array(0);
        sch::Span sp = o->type >= 0 ? sch::k_elem_props[o->type] : sch::Span{0, 0};
        auto in_type = [&](Str* name) {
            for (uint32_t k = sp.first; k < sp.first + sp.count; k++)
                if (d.prop_atom[static_cast<int>(sch::k_prop_defs[k].prop)] == name)
                    return static_cast<int32_t>(k);
            return -1;
        };
        auto row = [&](const PSlot& sl, int32_t def) {
            Obj* r = rt.object();
            Binding* b = sl.binding;
            Value value = describe(d, sl.value);
            bool isdef = false;
            if (!b && def >= 0) {
                const sch::PropDef& pd = sch::k_prop_defs[def];
                Value dv = pd.def == sch::Def::fresh ? (pd.json == "[]" ? val(rt.array(0)) : val(rt.object()))
                                                     : d.def_val[def];
                isdef = strict_equals(describe(d, dv), value);
            }
            put(r, "name", s8(d.name_info(sl.name)->text));
            put(r, "value", value);
            std::string_view bx = b ? (b->m ? b->m->value : k_panes_model) : std::string_view{};
            put(r, "binding", s8(b && !literal(bx) ? bx : std::string_view{}));
            put(r, "native", Value::boolean(sl.native));
            put(r, "own", Value::boolean(def < 0));
            put(r, "isDefault", Value::boolean(isdef));
            rt.push(props, val(r));
        };
        for (uint32_t k = sp.first; k < sp.first + sp.count; k++) {
            Str* pa = d.prop_atom[static_cast<int>(sch::k_prop_defs[k].prop)];
            int32_t si = d.find_own(o, pa);
            if (si >= 0) {
                row(o->slots[si], static_cast<int32_t>(k));
                continue;
            }
            int32_t t = o->tt ? d.tpl_find(o->tt, pa) : -1;
            if (t < 0)
                continue;
            PSlot dflt{};
            dflt.name = pa, dflt.kind = SK::prop, dflt.native = o->tt->e[t].native, dflt.has_value = true;
            dflt.value = d.tpl_default(o->tt->e[t]);
            d.name_info(pa, sch::k_props[static_cast<int>(sch::k_prop_defs[k].prop)].name);
            row(dflt, static_cast<int32_t>(k));
        }
        for (uint32_t i = 0; i < o->n_slots; i++)
            if (o->slots[i].kind == SK::prop && o->slots[i].has_value && in_type(o->slots[i].name) < 0)
                row(o->slots[i], -1);
        Arr* hs = rt.array(0);
        for (uint32_t k = 0; k < o->handlers.size; k++) {
            bool seen = false;
            for (uint32_t j = 0; j < k; j++)
                seen = seen || o->handlers[j].name == o->handlers[k].name;
            if (!seen)
                rt.push(hs, val(o->handlers[k].name));
        }
        Obj* r = rt.object();
        put(r, "uid", Value::num(o->uid)), put(r, "type", s8(o->type_name)), put(r, "id", s8(o->id)),
            put(r, "comp", s8(o->comp));
        put(r, "file", s8(o->file)), put(r, "line", Value::num(o->line)), put(r, "props", val(props)),
            put(r, "handlers", val(hs));
        put(r, "children", Value::num(o->children.size));
        return done(val(r));
    }
    if (op == "edit") {
        Elem* o = d.obj(arg(0).is_num() ? static_cast<uint32_t>(arg(0).as_num()) : 0);
        Str* name = arg(1).is(Kind::string) ? rt.atom(arg(1).as<Str>()) : nullptr;
        int32_t i = o && name ? d.find(o, name) : -1;
        if (i < 0 || !o->slots[i].named)
            return done(val(rt.concat(rt.str_ascii("no property "), name ? name : rt.empty)));
        Value v = arg(2);
        if (v.is(Kind::string)) {
            bool parsed;
            Value j = d.json_parse(d.tmp.copy(str8(&d, v.as<Str>())), parsed);
            if (parsed)
                v = j;
        }
        if (o->slots[i].kind == SK::prop) {
            PSlot& sl = o->slots[i];
            if (d.n_undos == 64)
                std::memmove(d.undos, d.undos + 1, sizeof d.undos[0] * 63), d.n_undos = 63;
            d.undos[d.n_undos++] = {o->uid, static_cast<uint32_t>(i), sl.binding,
                                    sl.binding ? std::string_view{} : d.copy(d.json(sl.value)), sl.assigned};
            d.write(o, static_cast<uint32_t>(i), v, false);
        }
        return done(val(rt.empty));
    }
    if (op == "undo") {
        while (d.n_undos) {
            const Impl::Undo u = d.undos[--d.n_undos];
            Elem* o = d.obj(u.uid);
            if (!o || !o->alive || u.slot >= o->n_slots)
                continue;
            if (u.b) {
                PSlot& sl = o->slots[u.slot];
                if (sl.binding && sl.binding != u.b)
                    d.unhook(sl.binding);
                sl.binding = u.b;
                sl.assigned = u.assigned;
                d.evaluate(u.b);
            } else {
                bool parsed;
                Value v = d.json_parse(d.tmp.copy(u.text), parsed);
                if (!parsed)
                    v = val(rt.str_utf8(u.text));
                d.write(o, u.slot, v, false);
                o->slots[u.slot].assigned = u.assigned;
            }
            d.flush();
            return done(Value::num(u.uid));
        }
        return done(Value::num(0));
    }
    if (op == "eval") {
        Obj* r = rt.object();
        if (!d.root || !d.top_sc)
            return put(r, "ok", Value::boolean(false)), put(r, "text", s8("nothing loaded")), done(val(r));
        std::string_view code = arg(0).is(Kind::string) ? d.copy(str8(&d, arg(0).as<Str>())) : std::string_view{};
        Ctx* ctx = d.ctx_for(d.root, d.top_sc, nullptr, false);
        const Code* c = nullptr;
        for (js::Goal g : {js::Goal::value, js::Goal::handler}) {
            auto ast = js::parse(code, 0, static_cast<uint32_t>(code.size()), g, d.scratch);
            if (!ast)
                continue;
            auto k = compile(*ast, g, code, rt, nullptr, 0, &d.scratch);
            if (k) {
                c = *k;
                break;
            }
        }
        d.scratch.reset();
        if (!c || !ctx)
            return put(r, "ok", Value::boolean(false)), put(r, "text", s8("doesn't compile")), done(val(r));
        Binding* prev = d.current;
        d.current = nullptr;
        bool good;
        Value v = d.run(c, ctx, nullptr, 0, good);
        Value e = good ? Value::undefined() : d.thrown_value();
        rt.clear();
        d.current = prev;
        put(r, "ok", Value::boolean(good));
        if (good)
            put(r, "text", describe(d, v, 2));
        else {
            Value m = e.is_cell() && !e.is(Kind::string) ? get(rt, e, d.atom("message")) : e;
            rt.clear();
            Str* t = to_string(rt, m);
            rt.clear();
            put(r, "text", t ? val(t) : s8("error"));
        }
        d.flush();
        return done(val(r));
    }
    if (op == "complete") {
        std::string_view code = arg(0).is(Kind::string) ? d.tmp.copy(str8(&d, arg(0).as<Str>())) : std::string_view{};
        size_t t = code.size();
        auto word = [](char c) {
            return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '$'
                || c == '.';
        };
        while (t > 0 && word(code[t - 1]))
            t--;
        std::string_view tail = code.substr(t);
        size_t dot = tail.rfind('.');
        std::string_view base = dot == std::string_view::npos ? std::string_view{} : tail.substr(0, dot);
        std::string_view prefix = dot == std::string_view::npos ? tail : tail.substr(dot + 1);
        Obj* r = rt.object();
        Arr* items = rt.array(0);
        auto add = [&](std::string_view name, const char* kind, Value detail) {
            if (name.substr(0, 2) == "__")
                return;
            for (uint32_t k = 0; k < items->length; k++)
                if (str8(&d, get(rt, items->items[k], d.atom("name")).as<Str>()) == name)
                    return;
            Obj* it = rt.object();
            put(it, "name", s8(name)), put(it, "kind", s8(kind)), put(it, "detail", detail);
            rt.push(items, val(it));
        };
        auto names_of = [&](Elem* e, const char* prop_kind, const char* fn_kind) {
            d.each_slot(e, [&](const PSlot* sl, const TEntry* te) {
                if (!(sl ? sl->named : te->named))
                    return;
                SK kind = sl ? sl->kind : te->kind;
                bool fn = kind == SK::function || kind == SK::method;
                Str* name = sl ? sl->name : te->name;
                Value v = sl                 ? sl->value
                    : te->kind == SK::prop   ? d.tpl_default(*te)
                    : te->kind == SK::method ? rt.get_own(d.method_table, te->name)
                                             : Value::undefined();
                if (!sl && te->kind == SK::group) {
                    int32_t i = d.find(e, te->name);
                    if (i >= 0)
                        v = e->slots[i].value;
                }
                add(d.name_info(name)->text, fn ? fn_kind : prop_kind, fn ? s8("ƒ") : describe(d, v));
            });
        };
        if (d.root && base.empty()) {
            for (uint32_t k = 0; d.top_sc && k < d.top_sc->ids->keys.size; k++)
                add(str8(&d, d.top_sc->ids->keys[k]), "id", describe(d, Value::cell(&d.top_sc->ids->vals[k]->h)));
            names_of(d.root, "property", "function");
            for (const char* g :
                 {"debug", "rex",  "theme", "panes", "conf",   "keys",  "i18n",   "context", "console",  "qsTr",
                  "rgba",  "Math", "JSON",  "Date",  "Object", "Array", "String", "Number",  "parseInt", "parseFloat"})
                add(g, "global", s8("global"));
        } else if (d.root) {
            Ctx* ctx = d.ctx_for(d.root, d.top_sc, nullptr, false);
            auto ast = js::parse(base, 0, static_cast<uint32_t>(base.size()), js::Goal::value, d.scratch);
            auto k = ast ? compile(*ast, js::Goal::value, base, rt, nullptr, 0, &d.scratch)
                         : std::unexpected(CompileError{});
            d.scratch.reset();
            bool good = false;
            Value v = k && ctx ? d.run(*k, ctx, nullptr, 0, good) : Value::undefined();
            rt.clear();
            if (good && v.is(Kind::element)) {
                names_of(v.as<Elem>(), "property", "method");
                add("children", "property", s8("[…]"));
                add("parent", "property", s8("…"));
            } else if (good && !v.is_nullish()) {
                if (v.is_cell() && !v.is(Kind::string)) {
                    Arr* keys = own_keys(rt, v);
                    for (uint32_t i = 0; keys && i < keys->length; i++) {
                        Value x = get(rt, v, keys->items[i].as<Str>());
                        rt.clear();
                        bool fn = x.is(Kind::function) || x.is(Kind::native);
                        add(str8(&d, keys->items[i].as<Str>()), fn ? "method" : "property",
                            fn ? s8("ƒ") : describe(d, x));
                    }
                    if (v.is(Kind::array))
                        add("length", "property", describe(d, Value::num(v.as<Arr>()->length)));
                }
                Obj* proto = v.is(Kind::string)                  ? rt.string_proto
                    : v.is_num()                                 ? rt.number_proto
                    : v.is_bool()                                ? rt.boolean_proto
                    : v.is(Kind::array)                          ? rt.array_proto
                    : v.is(Kind::date)                           ? rt.date_proto
                    : v.is(Kind::set)                            ? rt.set_proto
                    : v.is(Kind::regexp)                         ? rt.regexp_proto
                    : v.is(Kind::promise)                        ? rt.promise_proto
                    : v.is(Kind::function) || v.is(Kind::native) ? rt.function_proto
                                                                 : nullptr;
                Arr* pk = proto ? own_keys(rt, val(proto)) : nullptr;
                for (uint32_t i = 0; pk && i < pk->length; i++) {
                    Str* n = pk->items[i].as<Str>();
                    Value x = rt.get_own(proto, n);
                    if ((x.is(Kind::function) || x.is(Kind::native)) && n->view() != u"constructor")
                        add(str8(&d, n), "method", s8("ƒ"));
                }
                rt.clear();
            }
        }
        Arr *starts = rt.array(0), *holds = rt.array(0);
        auto has = [&](std::string_view n, bool at_start) {
            if (prefix.empty())
                return at_start;
            for (size_t i = 0; i + prefix.size() <= n.size(); i++) {
                bool m = true;
                for (size_t j = 0; j < prefix.size() && m; j++)
                    m = (n[i + j] | 32) == (prefix[j] | 32);
                if (m)
                    return at_start ? i == 0 : i > 0;
                if (at_start)
                    return false;
            }
            return false;
        };
        for (bool first : {true, false})
            for (uint32_t i = 0; i < items->length; i++) {
                std::string_view n = str8(&d, get(rt, items->items[i], d.atom("name")).as<Str>());
                if (has(n, first))
                    rt.push(first ? starts : holds, items->items[i]);
            }
        for (uint32_t i = 1; i < starts->length; i++)
            for (uint32_t j = i; j > 0; j--) {
                std::string_view x = str8(&d, get(rt, starts->items[j - 1], d.atom("name")).as<Str>()),
                                 y = str8(&d, get(rt, starts->items[j], d.atom("name")).as<Str>());
                size_t k = 0;
                while (k < x.size() && k < y.size() && (x[k] | 32) == (y[k] | 32))
                    k++;
                bool after = k < x.size() && (k == y.size() || (x[k] | 32) > (y[k] | 32));
                if (!after)
                    break;
                Value tmpv = starts->items[j];
                starts->items[j] = starts->items[j - 1], starts->items[j - 1] = tmpv;
            }
        Arr* all = rt.array(0);
        for (Arr* src : {starts, holds})
            for (uint32_t i = 0; i < src->length && all->length < 40; i++)
                rt.push(all, src->items[i]);
        put(r, "prefix", s8(prefix)), put(r, "base", s8(base)), put(r, "items", val(all));
        return done(val(r));
    }
    return done(Value::null());
}

namespace {
std::string_view place_of(Impl& d, Elem* e) {
    std::string_view path;
    for (Elem* x = e; x; x = x->parent) {
        std::string_view seg;
        if (!x->id.empty())
            seg = d.tcat({x->type_name, "#", x->id});
        else {
            uint32_t k = 0;
            if (x->parent)
                for (Elem* c : x->parent->children) {
                    if (c == x)
                        break;
                    if (c->type_name == x->type_name)
                        k++;
                }
            seg = d.tcat({x->type_name, "@", d.num8(k, &d.tmp)});
        }
        path = path.empty() ? seg : d.tcat({seg, "/", path});
    }
    return path;
}
bool carried(Rt& rt, Value v, int depth = 0) {
    if (!v.is_cell())
        return true;
    if (v.is(Kind::string))
        return true;
    if (depth > 32)
        return false;
    if (v.is(Kind::array)) {
        Arr* a = v.as<Arr>();
        for (uint32_t i = 0; i < a->length; i++)
            if (!carried(rt, a->items[i], depth + 1))
                return false;
        return true;
    }
    if (!v.is(Kind::object))
        return false;
    Arr* keys = own_keys(rt, v);
    for (uint32_t k = 0; keys && k < keys->length; k++)
        if (keys->items[k].is(Kind::string) && !carried(rt, get(rt, v, keys->items[k].as<Str>()), depth + 1))
            return false;
    return true;
}
}

std::string_view Doc::snapshot() noexcept {
    Impl& d = *impl_;
    Rt& rt = d.rt;
    Obj* out = rt.object();
    for (Elem* e : d.objs) {
        if (!e || !out)
            continue;
        Obj* props = nullptr;
        for (uint32_t i = 0; i < e->n_slots; i++) {
            PSlot& sl = e->slots[i];
            if (sl.kind != SK::prop || !sl.named || !sl.assigned)
                continue;
            if (!carried(rt, sl.value) || d.json(sl.value) == "undefined")
                continue;
            if (!props && !(props = rt.object()))
                break;
            rt.put(props, d.atom(d.name_info(sl.name)->text), sl.value);
        }
        if (props)
            rt.put(out, rt.atom(rt.str_utf8(place_of(d, e))), val(props));
    }
    std::string_view j = out ? d.copy(d.json(val(out))) : std::string_view("{}");
    rt.clear();
    d.tmp.reset();
    return j;
}

std::string_view Doc::value(uint32_t uid, std::string_view name) noexcept {
    Impl& d = *impl_;
    Elem* o = d.obj(uid);
    Str* a = o ? d.atom(name) : nullptr;
    int32_t i = a ? d.find(o, a) : -1;
    if (i < 0 || !o->slots[i].named)
        return "undefined";
    std::string_view j = d.json(o->slots[i].value);
    d.rt.clear();
    d.tmp.reset();
    return j;
}

uint32_t Doc::restore(std::string_view json) noexcept {
    Impl& d = *impl_;
    Rt& rt = d.rt;
    d.vm.budget = 100000000;
    d.restoring = true;
    bool ok;
    Value all = d.json_parse(json, ok);
    uint32_t n = 0;
    if (ok && all.is(Kind::object)) {
        for (Elem* e : d.objs) {
            if (!e)
                continue;
            Value props = rt.get_own(all.as<Obj>(), rt.atom(rt.str_utf8(place_of(d, e))));
            if (!props.is(Kind::object))
                continue;
            Arr* keys = own_keys(rt, props);
            for (uint32_t k = 0; keys && k < keys->length; k++) {
                Str* name = keys->items[k].as<Str>();
                int32_t i = d.find(e, rt.atom(name));
                if (i < 0 || e->slots[i].kind != SK::prop || !e->slots[i].named)
                    continue;
                d.write(e, static_cast<uint32_t>(i), get(rt, props, name), false);
                n++;
            }
        }
    }
    d.restoring = false;
    rt.clear();
    d.end_job();
    return n;
}

std::string_view Doc::json(Value v) noexcept {
    return impl_->json(v);
}
void Doc::collect() noexcept {
    impl_->collect();
}
void Doc::collect_always(bool always) noexcept {
    impl_->gc_always = always;
}
vm::Rt& Doc::rt() noexcept {
    return impl_->rt;
}

Doc::Stats Doc::stats() const noexcept {
    Stats s = impl_->stat;
    s.heap = impl_->heap.used();
    s.perm = impl_->arena.used();
    s.collections = impl_->collections;
    return s;
}

namespace globals {
Impl& of(Vm& vm) noexcept {
    return *native_doc(vm);
}
Rt& rt(Impl& d) noexcept {
    return d.rt;
}
Vm& vm(Impl& d) noexcept {
    return d.vm;
}
Str* atom(Impl& d, std::string_view ascii) noexcept {
    return d.atom(ascii);
}
Value api(Impl& d, std::string_view name, const Value* args, uint32_t argc) noexcept {
    return d.sink.api(*d.self, "__native", name, args, argc);
}
void log(Impl& d, Str* text, std::string_view level) noexcept {
    d.sink.log(str8(&d, text), level);
}
bool define(Impl& d, Value o, Str* k, Value v) noexcept {
    if (o.is(Kind::element)) {
        Elem* e = o.as<Elem>();
        int32_t i = d.find(e, k);
        if (i < 0 && (i = d.add_slot(e, k)) < 0)
            return false;
        e->slots[i].kind = SK::method;
        e->slots[i].value = v;
        return true;
    }
    return o.is(Kind::object) && d.rt.put(o.as<Obj>(), k, v);
}
Value& delegate(Impl& d, Delegate which) noexcept {
    return d.delegates[static_cast<int>(which)];
}
}

}
