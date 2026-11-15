// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/core/globals.h"

#include <array>
#include <cmath>
#include <initializer_list>
#include <utility>

#include "engine/vm/lib.h"
#include "engine/vm/ops.h"

namespace rx::engine::core::globals {

using namespace vm;

namespace {

struct G {
    Impl& d;
    Rt& r;
    Vm& v;
    const Value* args;
    uint32_t argc;

    bool bad() const { return r.failed; }
    Value a(uint32_t i) const { return lib::arg(args, argc, i); }
    static Value undef() { return Value::undefined(); }
    static Value null() { return Value::null(); }
    static Value b(bool x) { return Value::boolean(x); }
    static Value n(double x) { return Value::num(x); }
    Value s(std::string_view ascii) { return val(atom(d, ascii)); }
    bool truthy(Value x) const { return to_boolean(x); }
    Value or_(Value x, Value otherwise) const { return truthy(x) ? x : otherwise; }
    Value orNull(Value x) const { return x.is_undefined() ? null() : x; }

    Value str(Value x) {
        if (bad())
            return undef();
        Str* t = to_string(r, x);
        return t ? val(t) : undef();
    }
    Value num(Value x) {
        if (bad())
            return undef();
        double k = to_number(r, x);
        return bad() ? undef() : n(k);
    }
    Value num0(Value x) {
        Value k = num(x);
        if (bad())
            return undef();
        double y = k.as_num();
        return n(std::isnan(y) || y == 0 ? 0.0 : y);
    }
    Value prop(Value o, std::string_view key) {
        if (bad())
            return undef();
        return get(r, o, atom(d, key));
    }
    Value obj(std::initializer_list<std::pair<std::string_view, Value>> kv) {
        if (bad())
            return undef();
        Obj* o = r.object();
        if (!o)
            return r.fail(ErrorKind::internal, "out of memory");
        for (auto& [k, x] : kv)
            if (!r.put(o, atom(d, k), x))
                return r.fail(ErrorKind::internal, "out of memory");
        return val(o);
    }
    Value arr() {
        if (bad())
            return undef();
        Arr* o = r.array(0);
        return o ? val(o) : r.fail(ErrorKind::internal, "out of memory");
    }
    Value lib_fn(Value holder, std::string_view name) {
        if (bad() || !holder.is(Kind::object))
            return undef();
        Value f = r.get_own(holder.as<Obj>(), atom(d, name));
        return f.is_hole() ? undef() : f;
    }
    Value global(std::string_view name) { return r.get_own(r.globals, atom(d, name)); }
    Value call_fn(Value f, Value self, std::initializer_list<Value> xs) {
        if (bad())
            return undef();
        if (!lib::callable(f))
            return r.fail(ErrorKind::internal, "the library has no such function");
        return v.call(f, self, xs.begin(), static_cast<uint32_t>(xs.size()));
    }
    Value array_method(Value self, std::string_view name, std::initializer_list<Value> xs) {
        return call_fn(lib_fn(val(r.array_proto), name), self, xs);
    }
    Value strs(Value x) {
        Value c = array_method(arr(), "concat", {x});
        return array_method(c, "map", {global("String")});
    }
    Value paths(Value x) {
        Value c = array_method(arr(), "concat", {x});
        if (bad())
            return undef();
        Native* keep = r.native(
            "",
            [](Vm&, Value, const Value* xs, uint32_t k) { return Value::boolean(!lib::arg(xs, k, 0).is_nullish()); },
            1);
        if (!keep)
            return r.fail(ErrorKind::internal, "out of memory");
        Value f = array_method(c, "filter", {val(keep)});
        return array_method(f, "map", {global("String")});
    }
    Value assign(Value target, Value source) {
        return call_fn(lib_fn(global("Object"), "assign"), global("Object"), {target, source});
    }
    Value json_copy(Value x) {
        Value json = global("JSON");
        Value text = call_fn(lib_fn(json, "stringify"), json, {x});
        return call_fn(lib_fn(json, "parse"), json, {text});
    }
    Value ask(std::string_view name, std::initializer_list<Value> xs) {
        if (bad())
            return undef();
        return api(d, name, xs.begin(), static_cast<uint32_t>(xs.size()));
    }
    Value dbg(std::string_view op, Value x) { return ask("debug", {s(op), orNull(x)}); }
    Value set_delegate(Delegate which, std::string_view native) {
        Value f = a(0);
        Value& slot = delegate(d, which);
        slot = type_of(r, f) == r.a_function ? f : null();
        ask(native, {s("delegate"), obj({{"on", b(truthy(slot))}})});
        return undef();
    }
};

using Method = Value (*)(G& g);

struct Def {
    const char *global, *name;
    uint32_t length;
    Method fn;
};

constexpr Def k_defs[] = {
    {"activity", "markSeen", 1,
     [](G& g) { return g.or_(g.ask("activity", {g.s("markSeen"), g.obj({{"ids", g.strs(g.a(0))}})}), G::n(0)); }},
    {"activity", "delegate", 1, [](G& g) { return g.set_delegate(Delegate::activity, "activity"); }},
    {"notices", "dismiss", 1,
     [](G& g) { return g.ask("notices", {g.s("dismiss"), g.obj({{"id", g.str(g.a(0))}})}), G::undef(); }},
    {"notices", "clear", 0, [](G& g) { return g.ask("notices", {g.s("clear"), g.obj({})}), G::undef(); }},
    {"notices", "reveal", 1,
     [](G& g) { return g.ask("notices", {g.s("reveal"), g.obj({{"id", g.str(g.a(0))}})}), G::undef(); }},
    {"notices", "play", 1,
     [](G& g) { return G::b(g.truthy(g.ask("notices", {g.s("play"), g.obj({{"sound", g.str(g.a(0))}})}))); }},
    {"notices", "setBadge", 1,
     [](G& g) {
         return g.ask("notices", {g.s("badge"), g.obj({{"text", g.a(0).is_nullish() ? G::null() : g.str(g.a(0))}})}),
                G::undef();
     }},
    {"notices", "post", 1,
     [](G& g) {
         Value target = g.obj({});
         return g.ask("notices", {g.s("post"), g.assign(target, g.truthy(g.a(0)) ? g.a(0) : g.obj({}))});
     }},
    {"notices", "delegate", 1, [](G& g) { return g.set_delegate(Delegate::notice, "notices"); }},
    {"diagnostics", "call", 2,
     [](G& g) {
         return g.ask(
             "diagnostics",
             {g.s("call"), g.obj({{"method", g.str(g.a(0))}, {"payload", g.a(1).is_undefined() ? g.s("") : g.a(1)}})});
     }},
    {"diagnostics", "clearCalls", 0,
     [](G& g) { return g.ask("diagnostics", {g.s("clearCalls"), g.obj({})}), G::undef(); }},
    {"diagnostics", "clearEvents", 0,
     [](G& g) { return g.ask("diagnostics", {g.s("clearEvents"), g.obj({})}), G::undef(); }},
    {"diagnostics", "follow", 2,
     [](G& g) {
         Value on = G::b(!strict_equals(g.a(0), G::b(false)));
         return g.ask("diagnostics",
                      {g.s("follow"), g.obj({{"on", on}, {"session", g.truthy(g.a(1)) ? g.str(g.a(1)) : g.s("")}})}),
                G::undef();
     }},
    {"diagnostics", "refresh", 0, [](G& g) { return g.ask("diagnostics", {g.s("refresh"), g.obj({})}), G::undef(); }},
    {"diagnostics", "reveal", 1,
     [](G& g) { return g.ask("diagnostics", {g.s("reveal"), g.obj({{"path", g.str(g.a(0))}})}), G::undef(); }},
    {"clipboard", "read", 0, [](G& g) { return g.or_(g.ask("clipboard", {g.s("read"), g.obj({})}), g.s("")); }},
    {"clipboard", "write", 1,
     [](G& g) { return g.ask("clipboard", {g.s("write"), g.obj({{"text", g.str(g.a(0))}})}), G::undef(); }},
    {"clipboard", "clear", 0, [](G& g) { return g.ask("clipboard", {g.s("clear"), g.obj({})}), G::undef(); }},
    {"clipboard", "files", 0, [](G& g) { return g.ask("clipboard", {g.s("files"), g.obj({})}); }},
    {"clipboard", "changeCount", 0,
     [](G& g) { return g.or_(g.ask("clipboard", {g.s("changeCount"), g.obj({})}), G::n(0)); }},
    {"shared", "set", 2, [](G& g) { return g.ask("shared", {g.str(g.a(0)), g.orNull(g.a(1))}), G::undef(); }},
    {"loading", "finish", 0, [](G& g) { return g.ask("loading", {g.s("finish")}), G::undef(); }},
    {"loading", "preview", 0, [](G& g) { return G::b(g.truthy(g.ask("loading", {g.s("preview")}))); }},
    {"windows", "delegate", 1, [](G& g) { return g.set_delegate(Delegate::window, "windows"); }},
    {"windows", "open", 1,
     [](G& g) { return G::b(g.truthy(g.ask("windows", {g.s("open"), g.obj({{"id", g.str(g.a(0))}})}))); }},
    {"windows", "clear", 0, [](G& g) { return g.ask("windows", {g.s("clear"), g.obj({})}), G::undef(); }},
    {"files", "list", 2,
     [](G& g) {
         Value path = g.str(g.a(0));
         Value hidden = G::b(g.truthy(g.a(1)) && g.truthy(g.prop(g.a(1), "hidden")));
         return g.ask("files", {g.s("list"), g.obj({{"path", path}, {"hidden", hidden}})});
     }},
    {"files", "stat", 1, [](G& g) { return g.ask("files", {g.s("stat"), g.obj({{"path", g.str(g.a(0))}})}); }},
    {"files", "places", 0, [](G& g) { return g.ask("files", {g.s("places"), g.obj({})}); }},
    {"files", "watch", 1,
     [](G& g) {
         return g.ask("files", {g.s("watch"), g.obj({{"paths", g.paths(g.truthy(g.a(0)) ? g.a(0) : g.arr())}})}),
                G::undef();
     }},
    {"files", "copy", 2,
     [](G& g) { return g.ask("files", {g.s("copy"), g.obj({{"paths", g.paths(g.a(0))}, {"dest", g.str(g.a(1))}})}); }},
    {"files", "move", 2,
     [](G& g) { return g.ask("files", {g.s("move"), g.obj({{"paths", g.paths(g.a(0))}, {"dest", g.str(g.a(1))}})}); }},
    {"files", "trash", 1, [](G& g) { return g.ask("files", {g.s("trash"), g.obj({{"paths", g.paths(g.a(0))}})}); }},
    {"files", "rename", 2,
     [](G& g) { return g.ask("files", {g.s("rename"), g.obj({{"path", g.str(g.a(0))}, {"name", g.str(g.a(1))}})}); }},
    {"files", "mkdir", 2,
     [](G& g) {
         return g.ask(
             "files",
             {g.s("mkdir"), g.obj({{"path", g.str(g.a(0))}, {"name", g.truthy(g.a(1)) ? g.str(g.a(1)) : g.s("")}})});
     }},
    {"files", "undo", 0, [](G& g) { return g.ask("files", {g.s("undo"), g.obj({})}); }},
    {"files", "open", 2,
     [](G& g) {
         return G::b(g.truthy(g.ask(
             "files",
             {g.s("open"), g.obj({{"paths", g.paths(g.a(0))}, {"app", g.truthy(g.a(1)) ? g.str(g.a(1)) : g.s("")}})})));
     }},
    {"files", "apps", 1,
     [](G& g) {
         Value x = g.ask("files", {g.s("apps"), g.obj({{"path", g.str(g.a(0))}})});
         return g.truthy(x) || g.bad() ? x : g.arr();
     }},
    {"files", "search", 2,
     [](G& g) {
         Value target = g.obj({{"query", g.str(g.a(0))}});
         return g.ask("files", {g.s("search"), g.assign(target, g.truthy(g.a(1)) ? g.a(1) : g.obj({}))});
     }},
    {"files", "read", 2,
     [](G& g) {
         return g.ask("files", {g.s("read"), g.obj({{"path", g.str(g.a(0))}, {"max", g.or_(g.a(1), G::n(65536))}})});
     }},
    {"files", "finder", 1,
     [](G& g) { return G::b(g.truthy(g.ask("files", {g.s("finder"), g.obj({{"path", g.str(g.a(0))}})}))); }},
    {"files", "routing", 0, [](G& g) { return G::b(g.truthy(g.ask("files", {g.s("routing"), g.obj({})}))); }},
    {"rex", "openPane", 2,
     [](G& g) {
         Value widget = g.str(g.a(0));
         Value o = g.truthy(g.a(1)) ? g.a(1) : g.obj({});
         Value list = g.prop(o, "args");
         Value args = g.strs(g.truthy(list) ? list : g.arr());
         Value cwd = G::b(g.truthy(g.prop(o, "cwd")));
         Value direction = g.or_(g.prop(o, "direction"), g.s("horizontal"));
         Value side = g.or_(g.prop(o, "side"), g.s("after"));
         Value floating = G::b(g.truthy(g.prop(o, "floating")));
         Value focus = G::b(!strict_equals(g.prop(o, "focus"), G::b(false)));
         Value in = g.prop(o, "in");
         if (g.truthy(in))
             return g.ask("rex",
                          {g.s("openPane"), widget,
                           g.obj({{"args", args},
                                  {"cwd", cwd},
                                  {"direction", direction},
                                  {"side", side},
                                  {"floating", floating},
                                  {"focus", focus},
                                  {"in", in.is_bool() ? G::b(true) : g.str(in)}})}),
                    G::undef();
         return g.ask("rex",
                      {g.s("openPane"), widget,
                       g.obj({{"args", args},
                              {"cwd", cwd},
                              {"direction", direction},
                              {"side", side},
                              {"floating", floating},
                              {"focus", focus}})}),
                G::undef();
     }},
    {"rex", "modifiers", 0,
     [](G& g) {
         Value x = g.ask("rexstate", {g.s("modifiers"), g.obj({})});
         if (g.truthy(x) || g.bad())
             return x;
         return g.obj({{"cmd", G::b(false)}, {"shift", G::b(false)}, {"alt", G::b(false)}, {"ctrl", G::b(false)}});
     }},
    {"rex", "dock", 1,
     [](G& g) {
         return g.ask("rex",
                      {g.s("dock"), g.str(g.a(0)), g.truthy(g.a(1)) ? g.obj({{"show", G::b(true)}}) : g.obj({})}),
                G::undef();
     }},
    {"rex", "run", 2,
     [](G& g) {
         Value name = g.str(g.a(0));
         return g.ask("rex", {g.s("run"), name, g.truthy(g.a(1)) ? g.a(1) : g.obj({})});
     }},
    {"rex", "original", 1, [](G& g) { return g.ask("rex", {g.s("original"), g.str(g.a(0)), g.obj({})}); }},
    {"rex", "set", 2,
     [](G& g) { return g.ask("rex", {g.s("set"), g.str(g.a(0)), g.obj({{"value", g.orNull(g.a(1))}})}); }},
    {"rex", "menu", 1,
     [](G& g) { return G::b(g.truthy(g.ask("rex", {g.s("menu"), g.s(""), g.obj({{"path", g.strs(g.a(0))}})}))); }},
    {"rex", "shortcuts", 0,
     [](G& g) {
         Value x = g.ask("rex", {g.s("shortcuts"), g.s(""), g.obj({})});
         return g.truthy(x) || g.bad() ? x : g.obj({});
     }},
    {"rex", "block", 0, [](G& g) { return g.or_(g.ask("rex", {g.s("block"), g.s(""), g.obj({})}), G::null()); }},
    {"rex", "closeTab", 1,
     [](G& g) { return g.ask("rex", {g.s("closeTab"), g.s(""), g.obj({{"index", g.num(g.a(0))}})}); }},
    {"rex", "closeSession", 1, [](G& g) { return g.ask("rex", {g.s("closeSession"), g.str(g.a(0)), g.obj({})}); }},
    {"rex", "terminal", 1, [](G& g) { return g.ask("rex", {g.s("terminal"), g.str(g.a(0)), g.obj({})}); }},
    {"rex", "paneData", 3,
     [](G& g) {
         Value id = g.str(g.a(0));
         return g.ask("rex", {g.s("paneData"), id, g.obj({{"key", g.str(g.a(1))}, {"value", g.orNull(g.a(2))}})});
     }},
    {"rex", "present", 1,
     [](G& g) { return G::b(g.truthy(g.ask("rex", {g.s("present"), g.str(g.a(0)), g.obj({})}))); }},
    {"rex", "find", 1,
     [](G& g) {
         return g.ask("rex", {g.s("find"), g.s(""), g.obj({{"text", g.a(0).is_nullish() ? g.s("") : g.str(g.a(0))}})}),
                G::undef();
     }},
    {"rex", "paneFullscreen", 0,
     [](G& g) {
         return g.ask("rexstate",
                      {g.s("paneFullscreen"),
                       g.obj({{"on", g.a(0).is_nullish() ? G::n(-1) : G::n(g.truthy(g.a(0)) ? 1 : 0)},
                              {"block", g.a(1).is_nullish() ? g.s("") : g.str(g.a(1))}})});
     }},
    {"rex", "timeScale", 1,
     [](G& g) {
         return g.ask("rexstate",
                      {g.s("timeScale"), g.obj({{"scale", g.a(0).is_nullish() ? G::n(0) : g.num(g.a(0))}})});
     }},
    {"rex", "keymap", 0,
     [](G& g) {
         Value x = g.ask("rexstate", {g.s("keymap"), g.obj({})});
         return g.truthy(x) || g.bad() ? x : g.arr();
     }},
    {"rex", "hosts", 0,
     [](G& g) {
         Value x = g.ask("rexstate", {g.s("hosts"), g.obj({})});
         return g.truthy(x) || g.bad() ? x : g.arr();
     }},
    {"rex", "themes", 0,
     [](G& g) {
         Value x = g.ask("rexstate", {g.s("themes"), g.obj({})});
         return g.truthy(x) || g.bad() ? x : g.obj({});
     }},
    {"rex", "keyLayout", 0,
     [](G& g) {
         Value x = g.ask("rexstate", {g.s("keyLayout"), g.obj({})});
         return g.truthy(x) || g.bad() ? x : g.obj({});
     }},
    {"rex", "openDirectory", 1,
     [](G& g) {
         return G::b(g.truthy(g.ask("rexstate", {g.s("openDirectory"), g.obj({{"paths", g.strs(g.a(0))}})})));
     }},
    {"rex", "back", 0, [](G& g) { return G::b(g.truthy(g.ask("rexstate", {g.s("back"), g.obj({})}))); }},
    {"rex", "findState", 0, [](G& g) { return g.or_(g.ask("rexstate", {g.s("findState"), g.obj({})}), G::null()); }},
    {"rex", "api", 2,
     [](G& g) {
         Value method = g.str(g.a(0));
         return g.ask("rexstate",
                      {g.s("api"), g.obj({{"method", method}, {"args", g.truthy(g.a(1)) ? g.a(1) : g.obj({})}})});
     }},
    {"rex", "takePaste", 1,
     [](G& g) {
         return g.ask("rex", {g.s("takePaste"), g.s(""), g.obj({{"on", G::b(!strict_equals(g.a(0), G::b(false)))}})}),
                G::undef();
     }},
    {"rex", "paste", 2,
     [](G& g) {
         Value text = g.str(g.a(0));
         return g.ask("rex",
                      {g.s("paste"), g.s(""),
                       g.obj({{"text", text}, {"block", g.truthy(g.a(1)) ? g.str(g.a(1)) : g.s("")}})}),
                G::undef();
     }},
    {"rex", "takeLinks", 1,
     [](G& g) {
         return g.ask("rex", {g.s("takeLinks"), g.s(""), g.obj({{"on", G::b(!strict_equals(g.a(0), G::b(false)))}})}),
                G::undef();
     }},
    {"rex", "setAppIcon", 1,
     [](G& g) {
         return g.ask("rex",
                      {g.s("appIcon"), g.s(""), g.obj({{"path", g.a(0).is_nullish() ? G::null() : g.str(g.a(0))}})}),
                G::undef();
     }},
    {"rex", "checked", 1,
     [](G& g) { return g.or_(g.ask("rex", {g.s("checked"), g.s(""), g.obj({{"path", g.strs(g.a(0))}})}), G::null()); }},
    {"debug", "toggle", 1,
     [](G& g) { return g.dbg("toggle", g.a(0).is_undefined() ? G::null() : G::b(g.truthy(g.a(0)))); }},
    {"debug", "option", 2,
     [](G& g) { return g.dbg("option", g.obj({{"key", g.str(g.a(0))}, {"value", g.orNull(g.a(1))}})); }},
    {"debug", "tree", 1,
     [](G& g) {
         Value x = g.dbg("tree", g.str(g.a(0)));
         return g.truthy(x) || g.bad() ? x : g.arr();
     }},
    {"debug", "inspect", 2,
     [](G& g) {
         Value file = g.str(g.a(0));
         return g.or_(g.dbg("inspect", g.obj({{"file", file}, {"uid", g.num(g.a(1))}})), G::null());
     }},
    {"debug", "edit", 4,
     [](G& g) {
         Value file = g.str(g.a(0));
         Value x =
             g.dbg("edit",
                   g.obj({{"file", file}, {"uid", g.num(g.a(1))}, {"name", g.str(g.a(2))}, {"value", g.str(g.a(3))}}));
         return g.truthy(x) || g.bad() ? x : g.s("");
     }},
    {"debug", "undo", 0, [](G& g) { return g.or_(g.dbg("undo", G::null()), G::null()); }},
    {"debug", "eval", 2,
     [](G& g) {
         Value file = g.str(g.a(0));
         return g.or_(g.dbg("eval", g.obj({{"file", file}, {"code", g.str(g.a(1))}})), G::null());
     }},
    {"debug", "highlight", 2,
     [](G& g) {
         Value file = g.str(g.or_(g.a(0), g.s("")));
         return g.dbg("highlight", g.obj({{"file", file}, {"uid", g.num0(g.a(1))}}));
     }},
    {"debug", "select", 2,
     [](G& g) {
         Value file = g.str(g.or_(g.a(0), g.s("")));
         return g.dbg("select", g.obj({{"file", file}, {"uid", g.num0(g.a(1))}}));
     }},
    {"debug", "pick", 1,
     [](G& g) { return g.dbg("pick", g.a(0).is_undefined() ? G::b(true) : G::b(g.truthy(g.a(0)))); }},
    {"debug", "clear", 0, [](G& g) { return g.dbg("clear", G::undef()); }},
    {"debug", "openInPane", 3,
     [](G& g) {
         Value file = g.str(g.a(0));
         return g.dbg("openInPane",
                      g.obj({{"file", file},
                             {"direction", g.or_(g.a(1), g.s("horizontal"))},
                             {"side", g.or_(g.a(2), g.s("after"))}}));
     }},
    {"debug", "complete", 2,
     [](G& g) {
         Value file = g.str(g.a(0));
         Value x = g.dbg("complete", g.obj({{"file", file}, {"code", g.str(g.a(1))}}));
         if (g.truthy(x) || g.bad())
             return x;
         return g.obj({{"prefix", g.s("")}, {"base", g.s("")}, {"items", g.arr()}});
     }},
    {"debug", "perf", 0,
     [](G& g) {
         Value x = g.dbg("perf", G::null());
         if (g.truthy(x) || g.bad())
             return x;
         Value rex = g.obj({});
         Value server = g.arr();
         Value docs = g.arr();
         return g.obj({{"rex", rex}, {"server", server}, {"docs", docs}, {"fps", G::n(0)}, {"cores", G::n(1)}});
     }},
    {"debug", "memory", 0,
     [](G& g) {
         Value x = g.dbg("memory", G::null());
         if (g.truthy(x) || g.bad())
             return x;
         return g.obj({{"files", g.arr()}, {"total", g.obj({})}, {"caches", g.obj({})}});
     }},
    {"debug", "findAgents", 0, [](G& g) { return g.dbg("findAgents", G::null()), G::undef(); }},
    {"debug", "agentSend", 1, [](G& g) { return g.dbg("agentSend", g.a(0)), G::undef(); }},
    {"debug", "agentNew", 1, [](G& g) { return g.dbg("agentNew", g.a(0)), G::undef(); }},
    {"debug", "agentRun", 1, [](G& g) { return g.dbg("agentRun", g.a(0)), G::undef(); }},
    {"debug", "agentStop", 0, [](G& g) { return g.dbg("agentStop", G::null()), G::undef(); }},
    {"debug", "openFloating", 2,
     [](G& g) {
         Value file = g.str(g.a(0));
         return g.dbg("openFloating", g.obj({{"file", file}, {"bounds", g.or_(g.a(1), G::null())}})), G::undef();
     }},
    {"debug", "spotlight", 1,
     [](G& g) { return g.dbg("spotlight", g.truthy(g.a(0)) ? g.str(g.a(0)) : g.s("")), G::undef(); }},
    {"debug", "openHere", 1, [](G& g) { return g.dbg("openHere", g.obj({{"file", g.str(g.a(0))}})); }},
    {"debug", "dragToPane", 2,
     [](G& g) {
         Value file = g.str(g.a(0));
         Value phase = g.str(g.or_(g.a(1), g.s("move")));
         return G::b(g.truthy(g.dbg("dragToPane", g.obj({{"file", file}, {"phase", phase}}))));
     }},
    {"debug", "dragFloating", 2,
     [](G& g) {
         Value file = g.str(g.a(0));
         Value phase = g.str(g.or_(g.a(1), g.s("move")));
         return G::b(g.truthy(g.dbg("dragFloating", g.obj({{"file", file}, {"phase", phase}}))));
     }},
    {"debug", "closePane", 1,
     [](G& g) {
         Value file;
         if (g.truthy(g.a(0)))
             file = g.str(g.a(0));
         else {
             Value dbg = g.global("debug");
             Value here = g.prop(dbg, "here");
             Value path = g.truthy(here) ? g.prop(g.prop(dbg, "here"), "path") : here;
             file = g.or_(path, g.s(""));
         }
         return g.dbg("closePane", g.obj({{"file", file}}));
     }},
    {"debug", "setTheme", 1,
     [](G& g) {
         Value t = g.a(0);
         bool plain = g.truthy(t) && type_of(g.r, t) == g.r.a_object;
         return g.dbg("theme", plain ? g.json_copy(t) : G::null());
     }},
};
constexpr uint32_t k_count = sizeof k_defs / sizeof k_defs[0];

template<uint32_t I>
Value method(Vm& v, Value, const Value* args, uint32_t argc) noexcept {
    Impl& d = of(v);
    G g{d, rt(d), v, args, argc};
    Value x = k_defs[I].fn(g);
    return g.bad() ? Value::undefined() : x;
}
template<uint32_t... I>
constexpr auto natives(std::integer_sequence<uint32_t, I...>) {
    return std::array<NativeFn, sizeof...(I)>{&method<I>...};
}
constexpr auto k_natives = natives(std::make_integer_sequence<uint32_t, k_count>{});

Str* thrown_message(G& g, std::string_view who, Value e) {
    Value m = add(g.r, g.s(who), e);
    if (g.bad())
        return nullptr;
    Value stack = g.truthy(e) ? g.prop(e, "stack") : e;
    if (g.bad())
        return nullptr;
    m = add(g.r, m, g.truthy(stack) ? add(g.r, g.s("\n"), stack) : g.s(""));
    return g.bad() || !m.is(Kind::string) ? nullptr : m.as<Str>();
}

}

uint32_t method_count() noexcept {
    return k_count;
}
void method_at(uint32_t i, const char*& global, const char*& name, uint32_t& length) noexcept {
    const Def& def = k_defs[i < k_count ? i : 0];
    global = def.global, name = def.name, length = def.length;
}

bool install(Impl& d) noexcept {
    Rt& r = rt(d);
    for (uint32_t i = 0; i < k_count; i++) {
        const Def& def = k_defs[i];
        Native* f = r.native(def.name, k_natives[i], def.length);
        if (!f)
            return false;
        f->name = atom(d, def.name);
        Value o = r.get_own(r.globals, atom(d, def.global));
        if (o.is_hole() || !define(d, o, atom(d, def.name), val(f)))
            return false;
    }
    for (uint32_t k = 0; k < static_cast<uint32_t>(Delegate::count_); k++)
        delegate(d, static_cast<Delegate>(k)) = Value::null();
    return true;
}

Value ask(Impl& d, Delegate which, Value arg) noexcept {
    Rt& r = rt(d);
    Vm& v = vm(d);
    G g{d, r, v, &arg, 1};
    Value fn = delegate(d, which);
    if (!g.truthy(fn))
        return Value::null();
    const std::string_view who = which == Delegate::notice ? "notices.delegate: "
        : which == Delegate::window                        ? "windows.delegate: "
                                                           : "activity.delegate: ";
    Value copy = g.assign(g.obj({}), arg);
    Value answer = g.bad() ? Value::undefined() : v.call(fn, Value::undefined(), &copy, 1);
    if (g.bad()) {
        Value e = r.thrown;
        r.clear();
        Str* m = thrown_message(g, who, e);
        if (!m)
            return Value::undefined();
        log(d, m, "error");
        answer = Value::null();
    }
    if (answer.is_bool())
        return g.s(answer.is_true() ? "rex" : "docks");
    if (which == Delegate::window)
        return strict_equals(answer, g.s("rex")) || strict_equals(answer, g.s("docks")) ? answer : Value::null();
    if (which == Delegate::activity) {
        if (strict_equals(answer, g.s("rex")) || strict_equals(answer, g.s("docks")))
            return answer;
        if (!answer.is_nullish()) {
            Value t = g.str(answer);
            if (g.bad())
                return Value::undefined();
            Value m = add(r, add(r, g.s("activity.delegate: \""), t), g.s("\" isn't a way (\"rex\" or \"docks\")"));
            if (g.bad() || !m.is(Kind::string))
                return Value::undefined();
            log(d, m.as<Str>(), "warn");
        }
        return Value::null();
    }
    if (answer.is(Kind::string)) {
        if (strict_equals(answer, g.s("rex")) || strict_equals(answer, g.s("docks"))
            || strict_equals(answer, g.s("drop")))
            return answer;
        Value m = add(r, add(r, g.s("notices.delegate: \""), answer),
                      g.s("\" isn't a way (\"rex\", \"docks\", \"drop\" or the changes)"));
        if (g.bad() || !m.is(Kind::string))
            return Value::undefined();
        log(d, m.as<Str>(), "warn");
        return Value::null();
    }
    if (!g.truthy(answer) || type_of(r, answer) != r.a_object || answer.is(Kind::array))
        return Value::null();
    static constexpr std::pair<const char*, bool> k_changes[] = {
        {"title", false}, {"subtitle", false}, {"body", false},  {"tone", false},      {"symbol", false},
        {"sound", false}, {"glass", true},     {"system", true}, {"dismissible", true}};
    Value out = g.obj({});
    for (auto [k, boolean] : k_changes) {
        Value x = g.prop(answer, k);
        if (g.bad())
            return Value::undefined();
        if (x.is_nullish())
            continue;
        Value y = boolean ? G::b(g.truthy(x)) : g.str(x);
        if (g.bad() || !r.put(out.as<Obj>(), atom(d, k), y))
            return Value::undefined();
    }
    return out;
}

}
