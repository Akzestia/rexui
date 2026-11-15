// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/compile.h"

#include <cmath>
#include <cstdarg>
#include <cstdio>

#include "engine/base/utf.h"

namespace rx::engine::vm {
namespace {

using js::K;
using js::Node;
using sv = std::string_view;

constexpr uint8_t f_tdz = 128;

struct Scope;
struct FnInfo;

enum class BKind : uint8_t { var, let, const_, param, func, catch_ };

struct Binding {
    sv name;
    BKind kind;
    Scope* scope;
    bool captured;
    uint16_t reg;
    uint16_t slot;
    uint32_t decl_end;
    const Node* func;
};

struct Scope {
    Scope* up;
    FnInfo* fn;
    bool is_fn;
    bool per_iteration;
    bool needs_env;
    uint16_t env_size;
    List<Binding*> names;
};

struct FnInfo {
    FnInfo* up;
    const Node* node;
    Scope* scope;
    List<const Node*> params;
    uint16_t n_regs;
    bool expr_body;
};

struct Compiler {
    Rt& rt;
    Arena& arena;
    sv file;
    bool failed = false;
    CompileError error{};

    bool fail(uint32_t pos, const char* fmt, ...) __attribute__((format(printf, 3, 4))) {
        if (failed)
            return false;
        char buf[300];
        va_list ap;
        va_start(ap, fmt);
        int n = std::vsnprintf(buf, sizeof buf, fmt, ap);
        va_end(ap);
        failed = true;
        error = {pos,
                 arena.copy({buf,
                             n < 0                                     ? 0
                                 : static_cast<size_t>(n) < sizeof buf ? static_cast<size_t>(n)
                                                                       : sizeof buf - 1})};
        return false;
    }

    Scope* scope_new(Scope* up, FnInfo* fn, bool is_fn) {
        Scope* s = arena.make<Scope>();
        if (!s)
            return fail(0, "out of memory"), nullptr;
        s->up = up;
        s->fn = fn;
        s->is_fn = is_fn;
        return s;
    }
    Binding* find_in(Scope* s, sv name) {
        for (Binding* b : s->names)
            if (b->name == name)
                return b;
        return nullptr;
    }
    Binding* declare(Scope* s, sv name, BKind kind, uint32_t decl_end, const Node* func = nullptr) {
        if (Binding* b = find_in(s, name)) {
            if (kind == BKind::func)
                b->func = func, b->kind = BKind::func;
            return b;
        }
        Binding* b = arena.make<Binding>();
        if (!b || !s->names.push(arena, b))
            return fail(0, "out of memory"), nullptr;
        b->name = name;
        b->kind = kind;
        b->scope = s;
        b->decl_end = decl_end;
        b->func = func;
        return b;
    }
    Scope* fn_scope(Scope* s) {
        while (!s->is_fn)
            s = s->up;
        return s;
    }
    void declare_pattern(const Node* p, Scope* s, BKind kind, uint32_t decl_end) {
        if (!p)
            return;
        switch (p->kind) {
        case K::ident: {
            Binding* b = declare(s, p->text, kind, decl_end);
            const_cast<Node*>(p)->ref = b;
            return;
        }
        case K::array_pat:
            for (const Node* e = p->a; e; e = e->next)
                declare_pattern(e, s, kind, decl_end);
            return;
        case K::object_pat:
            for (const Node* e = p->a; e; e = e->next)
                declare_pattern(e->kind == K::prop ? e->b : e, s, kind, decl_end);
            return;
        case K::rest:
            declare_pattern(p->a, s, kind, decl_end);
            return;
        case K::default_:
            declare_pattern(p->a, s, kind, decl_end);
            return;
        default:
            return;
        }
    }
    void hoist_vars(const Node* s, Scope* fn) {
        for (; s; s = s->next)
            hoist_one(s, fn);
    }
    void hoist_one(const Node* s, Scope* fn) {
        if (!s)
            return;
        switch (s->kind) {
        case K::var:
            if (s->op == js::Op::var_)
                for (const Node* d = s->a; d; d = d->next)
                    declare_pattern(d->a, fn, BKind::var, 0);
            return;
        case K::block:
            hoist_vars(s->a, fn);
            return;
        case K::if_:
            hoist_one(s->b, fn);
            hoist_one(s->c, fn);
            return;
        case K::switch_:
            hoist_one(s->b, fn);
            return;
        case K::for_:
        case K::for_in:
        case K::for_of:
        case K::while_:
        case K::do_while:
            if (s->a && s->a->kind == K::var)
                hoist_one(s->a, fn);
            hoist_one(s->d, fn);
            return;
        case K::try_:
            hoist_one(s->a, fn);
            hoist_one(s->c, fn);
            hoist_one(s->d, fn);
            return;
        default:
            return;
        }
    }
    void hoist_lexical(const Node* stmts, Scope* s) {
        for (const Node* x = stmts; x; x = x->next) {
            if (x->kind == K::var && x->op != js::Op::var_)
                for (const Node* d = x->a; d; d = d->next)
                    declare_pattern(d->a, s, x->op == js::Op::const_ ? BKind::const_ : BKind::let, d->end);
            if (x->kind == K::func_decl)
                declare(s, x->text, BKind::func, 0, x);
        }
    }

    FnInfo* resolve_fn(const Node* node, Scope* up, FnInfo* upfn, const Node* params, const Node* body,
                       bool expr_body) {
        FnInfo* f = arena.make<FnInfo>();
        if (!f)
            return fail(0, "out of memory"), nullptr;
        f->up = upfn;
        f->node = node;
        f->expr_body = expr_body;
        f->scope = scope_new(up, f, true);
        if (!f->scope)
            return nullptr;
        for (const Node* p = params; p; p = p->next) {
            (void)f->params.push(arena, p);
            declare_pattern(p, f->scope, BKind::param, 0);
        }
        for (const Node* p = params; p; p = p->next)
            resolve_pattern(p, f->scope);
        if (!expr_body && body) {
            hoist_vars(body->a, f->scope);
            hoist_lexical(body->a, f->scope);
        }
        if (node && node->kind == K::func && !node->text.empty() && !find_in(f->scope, node->text))
            declare(f->scope, node->text, BKind::var, 0);
        if (expr_body)
            resolve(body, f->scope);
        else if (body)
            resolve_list(body->a, f->scope);
        return f;
    }

    void resolve_list(const Node* n, Scope* s) {
        for (; n; n = n->next)
            resolve(n, s);
    }
    void resolve_pattern(const Node* p, Scope* s) {
        if (!p)
            return;
        switch (p->kind) {
        case K::ident:
            if (!p->ref)
                reference(p, s);
            return;
        case K::array_pat:
            for (const Node* e = p->a; e; e = e->next)
                resolve_pattern(e, s);
            return;
        case K::object_pat:
            for (const Node* e = p->a; e; e = e->next) {
                if (e->kind == K::prop) {
                    if (e->flags & js::f_computed)
                        resolve(e->a, s);
                    resolve_pattern(e->b, s);
                } else
                    resolve_pattern(e, s);
            }
            return;
        case K::rest:
            resolve_pattern(p->a, s);
            return;
        case K::default_:
            resolve_pattern(p->a, s);
            resolve(p->b, s);
            return;
        case K::hole:
            return;
        default:
            resolve(p, s);
            return;
        }
    }
    void reference(const Node* id, Scope* s) {
        Node* n = const_cast<Node*>(id);
        for (Scope* x = s; x; x = x->up) {
            if (Binding* b = find_in(x, id->text)) {
                n->ref = b;
                bool other_fn = b->scope->fn != s->fn;
                if (other_fn)
                    b->captured = true;
                if ((b->kind == BKind::let || b->kind == BKind::const_) && (other_fn || id->pos < b->decl_end))
                    n->flags |= f_tdz;
                return;
            }
        }
        n->ref = nullptr;
    }

    void resolve(const Node* n, Scope* s) {
        if (!n || failed)
            return;
        switch (n->kind) {
        case K::ident:
            reference(n, s);
            return;
        case K::member:
            resolve(n->a, s);
            return;
        case K::prop:
            if (n->flags & js::f_computed)
                resolve(n->a, s);
            resolve(n->b, s);
            return;
        case K::func:
        case K::func_decl:
        case K::arrow: {
            bool expr = n->kind == K::arrow && (n->flags & js::f_expr_body);
            FnInfo* f = resolve_fn(n, s, s->fn, n->a, n->b, expr);
            const_cast<Node*>(n)->ref = f;
            return;
        }
        case K::block: {
            Scope* b = scope_new(s, s->fn, false);
            if (!b)
                return;
            const_cast<Node*>(n)->ref = b;
            hoist_lexical(n->a, b);
            resolve_list(n->a, b);
            return;
        }
        case K::var:
            for (const Node* d = n->a; d; d = d->next) {
                if (n->op == js::Op::var_)
                    declare_pattern(d->a, fn_scope(s), BKind::var, 0);
                resolve_pattern(d->a, s);
                resolve(d->b, s);
            }
            return;
        case K::for_:
        case K::for_in:
        case K::for_of: {
            Scope* h = scope_new(s, s->fn, false);
            if (!h)
                return;
            const_cast<Node*>(n)->ref = h;
            if (n->a && n->a->kind == K::var && n->a->op != js::Op::var_) {
                for (const Node* d = n->a->a; d; d = d->next)
                    declare_pattern(d->a, h, n->a->op == js::Op::const_ ? BKind::const_ : BKind::let,
                                    n->kind == K::for_ ? d->end : 0);
                h->per_iteration = true;
            }
            if (n->kind == K::for_)
                resolve(n->a, h);
            else if (n->a && n->a->kind == K::var)
                resolve(n->a, h);
            else
                resolve_pattern(n->a, h);
            resolve(n->b, h);
            resolve(n->c, h);
            resolve(n->d, h);
            return;
        }
        case K::try_: {
            resolve(n->a, s);
            if (n->c) {
                Scope* c = scope_new(s, s->fn, false);
                if (!c)
                    return;
                const_cast<Node*>(n)->ref = c;
                if (n->b)
                    declare_pattern(n->b, c, BKind::catch_, 0);
                if (n->b)
                    resolve_pattern(n->b, c);
                hoist_lexical(n->c->a, c);
                resolve_list(n->c->a, c);
            }
            resolve(n->d, s);
            return;
        }
        case K::assign:
            resolve_pattern(n->a, s);
            resolve(n->b, s);
            return;
        case K::array_pat:
        case K::object_pat:
        case K::default_:
        case K::rest:
            resolve_pattern(n, s);
            return;
        default:
            for (const Node* k : {n->a, n->b, n->c, n->d})
                resolve_list(k, s);
            return;
        }
    }

    uint16_t layout(FnInfo* f) {
        uint16_t next = 0;
        uint32_t i = 0;
        for (const Node* p : f->params) {
            (void)p;
            i++;
        }
        next = static_cast<uint16_t>(i);
        uint32_t k = 0;
        for (const Node* p : f->params) {
            if (p->kind == K::ident && p->ref)
                static_cast<Binding*>(p->ref)->reg = static_cast<uint16_t>(k);
            k++;
        }
        layout_scope(f->scope, next, f, true);
        return next;
    }
    void layout_scope(Scope* s, uint16_t& next, FnInfo* f, bool top) {
        for (Binding* b : s->names) {
            if (b->captured) {
                s->needs_env = true;
                b->slot = s->env_size++;
            }
            bool simple_param = false;
            if (top && b->kind == BKind::param)
                for (const Node* p : f->params)
                    simple_param = simple_param || (p->kind == K::ident && p->ref == b);
            if (!simple_param)
                b->reg = next++;
        }
    }

    struct Loop {
        List<uint32_t> breaks, continues;
        Scope* scope;
        Scope* cont;
        uint32_t finally_depth;
        bool is_loop;
        bool is_switch;
    };

    struct Gen {
        Compiler& c;
        FnInfo* fn;
        List<Ins> ins;
        List<uint32_t> pos;
        List<Value> consts;
        List<const Code*> children;
        uint16_t next = 0, max = 0;
        Scope* scope = nullptr;
        List<Loop*> loops;
        List<const Node*> finallies;
        List<Scope*> finally_scopes;
        uint32_t cur_pos = 0;
        uint32_t cur_end = 0;
        List<uint32_t> ends;

        Gen(Compiler& cc, FnInfo* f) : c(cc), fn(f) {}

        uint16_t temp() {
            uint16_t r = next++;
            if (next > max)
                max = next;
            if (next == 0xFFFF)
                c.fail(cur_pos, "a function uses more than 65,000 registers");
            return r;
        }
        void free_to(uint16_t mark) { next = mark; }
        uint32_t emit(vm::Op op, uint32_t a = 0, uint32_t b = 0, uint32_t cc = 0) {
            if (a > 0xFFFF || b > 0xFFFF || cc > 0xFFFF)
                c.fail(cur_pos, "an operand past 65,535");
            (void)ins.push(c.arena,
                           Ins{op, 0, static_cast<uint16_t>(a), static_cast<uint16_t>(b), static_cast<uint16_t>(cc)});
            (void)pos.push(c.arena, cur_pos);
            (void)ends.push(c.arena, cur_end);
            cur_end = 0;
            return ins.size - 1;
        }
        uint32_t here() const { return ins.size; }
        void patch(uint32_t at, uint32_t target) {
            ins[at].b = static_cast<uint16_t>(target & 0xFFFF);
            ins[at].c = static_cast<uint16_t>(target >> 16);
        }
        uint32_t jump(vm::Op op, uint32_t reg = 0) { return emit(op, reg, 0, 0); }
        uint16_t konst(Value v) {
            for (uint32_t i = 0; i < consts.size; i++)
                if (consts[i].same_bits(v))
                    return static_cast<uint16_t>(i);
            (void)consts.push(c.arena, v);
            if (consts.size > 0xFFFF)
                c.fail(cur_pos, "more than 65,535 constants");
            return static_cast<uint16_t>(consts.size - 1);
        }
        uint16_t katom(sv name) {
            Str* s = c.rt.atom(c.rt.str_ascii(name));
            return konst(s ? val(s) : Value::undefined());
        }
        uint16_t kstr(Str* s) { return konst(s ? val(s) : Value::undefined()); }

        uint32_t depth_to(const Scope* target) {
            uint32_t d = 0;
            for (Scope* s = scope; s && s != target; s = s->up)
                if (s->needs_env)
                    d++;
            return d;
        }
        void load_name(const Node* id, uint16_t dst) {
            Binding* b = static_cast<Binding*>(id->ref);
            if (!b) {
                emit(vm::Op::getname, dst, katom(id->text));
                return;
            }
            if (b->captured) {
                emit((id->flags & f_tdz) ? vm::Op::getenvchk : vm::Op::getenv, dst, depth_to(b->scope), b->slot);
                if (id->flags & f_tdz)
                    emit(vm::Op::halt, katom(id->text));
                return;
            }
            if (id->flags & f_tdz)
                emit(vm::Op::chk, b->reg, katom(id->text));
            if (dst != b->reg)
                emit(vm::Op::mov, dst, b->reg);
        }
        uint16_t name_reg(const Node* id) {
            Binding* b = static_cast<Binding*>(id->ref);
            if (b && !b->captured) {
                if (id->flags & f_tdz)
                    emit(vm::Op::chk, b->reg, katom(id->text));
                return b->reg;
            }
            uint16_t t = temp();
            load_name(id, t);
            return t;
        }
        void store_name(const Node* id, uint16_t src, bool init = false) {
            Binding* b = static_cast<Binding*>(id->ref);
            if (!b) {
                emit(vm::Op::setname, src, katom(id->text));
                return;
            }
            if (b->kind == BKind::const_ && !init) {
                emit(vm::Op::fail_, katom("Attempted to assign to readonly property."));
                return;
            }
            if (!init && (id->flags & f_tdz)) {
                if (b->captured) {
                    uint16_t t = temp();
                    emit(vm::Op::getenvchk, t, depth_to(b->scope), b->slot);
                    emit(vm::Op::halt, katom(id->text));
                    free_to(static_cast<uint16_t>(t));
                } else {
                    emit(vm::Op::chk, b->reg, katom(id->text));
                }
            }
            if (b->captured)
                emit(vm::Op::setenv, src, depth_to(b->scope), b->slot);
            else if (src != b->reg)
                emit(vm::Op::mov, b->reg, src);
        }

        void enter(Scope* s) {
            scope = s;
            uint16_t n = next;
            c.layout_scope(s, n, fn, false);
            if (n > next) {
                next = n;
                if (next > max)
                    max = next;
            }
            if (s->needs_env)
                emit(vm::Op::newenv, 0, s->env_size);
            for (Binding* b : s->names) {
                if (b->kind == BKind::let || b->kind == BKind::const_) {
                    uint16_t h = temp();
                    emit(vm::Op::loadk, h, konst(Value::hole()));
                    if (b->captured)
                        emit(vm::Op::setenv, h, 0, b->slot);
                    else
                        emit(vm::Op::mov, b->reg, h);
                    free_to(h);
                }
            }
            declare_functions(s);
        }
        void leave(Scope* s) {
            if (s->needs_env)
                emit(vm::Op::popenv);
            scope = s->up;
        }
        void declare_functions(Scope* s) {
            for (Binding* b : s->names) {
                if (b->kind != BKind::func || !b->func)
                    continue;
                uint16_t t = temp();
                closure(b->func, t);
                if (b->captured)
                    emit(vm::Op::setenv, t, 0, b->slot);
                else
                    emit(vm::Op::mov, b->reg, t);
                free_to(t);
            }
        }
        void closure(const Node* f, uint16_t dst) {
            const Code* code = c.function(static_cast<FnInfo*>(f->ref));
            if (!code)
                return;
            (void)children.push(c.arena, code);
            emit(vm::Op::closure, dst, children.size - 1);
        }

        static constexpr uint16_t any = 0xFFFF;
        uint16_t expr(const Node* n, uint16_t dst = any) {
            if (c.failed || !n)
                return 0;
            cur_pos = n->pos;
            auto out = [&] { return dst == any ? temp() : dst; };
            switch (n->kind) {
            case K::num: {
                uint16_t r = out();
                emit(vm::Op::loadk, r, konst(Value::num(n->num)));
                return r;
            }
            case K::str: {
                uint16_t r = out();
                emit(vm::Op::loadk, r, kstr(c.cook(n->text, n->pos)));
                return r;
            }
            case K::true_:
            case K::false_:
            case K::null_: {
                uint16_t r = out();
                emit(vm::Op::loadk, r,
                     konst(n->kind == K::null_ ? Value::null() : Value::boolean(n->kind == K::true_)));
                return r;
            }
            case K::ident: {
                if (dst == any)
                    return name_reg(n);
                load_name(n, dst);
                return dst;
            }
            case K::paren:
                return expr(n->a, dst);
            case K::tmpl:
                return tmpl(n, out());
            case K::array:
                return array(n, out());
            case K::object:
                return object(n, out());
            case K::func:
            case K::arrow: {
                uint16_t r = out();
                closure(n, r);
                return r;
            }
            case K::unary:
                return unary(n, out());
            case K::update:
                return update(n, out());
            case K::binary: {
                uint16_t mark = next;
                uint16_t a = stable(n->a, n->b), b = expr(n->b);
                free_to(mark);
                uint16_t r = out();
                static constexpr vm::Op k[] = {vm::Op::halt, vm::Op::add, vm::Op::sub,  vm::Op::mul,  vm::Op::div,
                                               vm::Op::mod,  vm::Op::exp, vm::Op::eq,   vm::Op::ne,   vm::Op::seq,
                                               vm::Op::sne,  vm::Op::lt,  vm::Op::gt,   vm::Op::le,   vm::Op::ge,
                                               vm::Op::shl,  vm::Op::shr, vm::Op::ushr, vm::Op::band, vm::Op::bor,
                                               vm::Op::bxor, vm::Op::in};
                int op = static_cast<int>(n->op);
                if (n->op == js::Op::instanceof) {
                    emit(vm::Op::fail_, katom("instanceof is the library's (E3)"));
                    return r;
                }
                cur_pos = n->pos;
                emit(k[op], r, a, b);
                return r;
            }
            case K::logical: {
                uint16_t r = out();
                expr(n->a, r);
                uint32_t j = n->op == js::Op::and_ ? jump(vm::Op::jf, r)
                    : n->op == js::Op::or_         ? jump(vm::Op::jt, r)
                                                   : jump(vm::Op::jnotnullish, r);
                expr(n->b, r);
                patch(j, here());
                return r;
            }
            case K::cond: {
                uint16_t r = out();
                uint16_t mark = next;
                uint16_t t = expr(n->a);
                uint32_t jf = jump(vm::Op::jf, t);
                free_to(mark);
                expr(n->b, r);
                uint32_t je = jump(vm::Op::jmp);
                patch(jf, here());
                expr(n->c, r);
                patch(je, here());
                return r;
            }
            case K::seq: {
                uint16_t r = any;
                for (const Node* e = n->a; e; e = e->next) {
                    uint16_t mark = next;
                    if (e->next) {
                        expr(e);
                        free_to(mark);
                    } else
                        r = expr(e, dst == any ? temp() : dst);
                }
                return r;
            }
            case K::assign:
                return assign(n, dst);
            case K::member:
            case K::index:
            case K::call:
                if (n->flags & js::f_chain)
                    return chain(n, out());
                return access(n, out(), nullptr);
            case K::new_: {
                uint16_t r = out();
                uint16_t mark = next;
                uint16_t f = expr(n->a);
                uint16_t base = temp();
                uint32_t argc = 0;
                for (const Node* a = n->b; a; a = a->next, argc++) {
                    if (a->kind == K::spread) {
                        emit(vm::Op::fail_, katom("new with ... is the library's (E3)"));
                        break;
                    }
                    expr(a, temp());
                }
                emit(vm::Op::newcall, r, f, base);
                emit(vm::Op::halt, argc);
                free_to(mark);
                return r;
            }
            case K::regex: {
                uint16_t r = out();
                emit(vm::Op::regex, r, kstr(c.rt.str_utf8(n->text)), kstr(c.rt.str_utf8(n->flags_text)));
                return r;
            }
            case K::tagged: {
                uint16_t r = out();
                emit(vm::Op::fail_, katom("a tagged template is the library's (E3)"));
                return r;
            }
            default:
                c.fail(n->pos, "%s can't be compiled yet", js::kind_name(n->kind));
                return 0;
            }
        }

        uint16_t tmpl(const Node* n, uint16_t r) {
            bool first = true;
            uint16_t mark = next;
            for (const Node* p = n->a; p; p = p->next) {
                uint16_t t;
                if (p->kind == K::str) {
                    Str* s = c.cook(p->text, p->pos);
                    if (!first && s && !s->length)
                        continue;
                    t = temp();
                    emit(vm::Op::loadk, t, kstr(s));
                } else {
                    uint16_t e = expr(p);
                    t = temp();
                    emit(vm::Op::tostr, t, e);
                }
                if (first)
                    emit(vm::Op::mov, r, t), first = false;
                else
                    emit(vm::Op::add, r, r, t);
                free_to(mark);
            }
            return r;
        }
        uint16_t array(const Node* n, uint16_t r) {
            uint32_t count = 0;
            for (const Node* e = n->a; e; e = e->next)
                count++;
            emit(vm::Op::newarr, r, count);
            for (const Node* e = n->a; e; e = e->next) {
                uint16_t mark = next;
                if (e->kind == K::hole)
                    emit(vm::Op::ahole, r);
                else if (e->kind == K::spread)
                    emit(vm::Op::aspread, r, expr(e->a));
                else
                    emit(vm::Op::apush, r, expr(e));
                free_to(mark);
            }
            return r;
        }
        uint16_t object(const Node* n, uint16_t r) {
            emit(vm::Op::newobj, r);
            for (const Node* p = n->a; p; p = p->next) {
                uint16_t mark = next;
                if (p->kind == K::spread) {
                    emit(vm::Op::ospread, r, expr(p->a));
                } else if (p->flags & js::f_computed) {
                    uint16_t k = temp(), v = temp();
                    expr(p->a, k);
                    expr(p->b, v);
                    emit(vm::Op::oputk, r, k);
                } else {
                    Str* key = c.key_of(p->a);
                    uint16_t v = expr(p->b);
                    emit(vm::Op::oput, r, kstr(key), v);
                }
                free_to(mark);
            }
            return r;
        }
        uint16_t unary(const Node* n, uint16_t r) {
            if (n->op == js::Op::typeof_ && n->a->kind == K::ident && !n->a->ref) {
                uint16_t mark = next;
                uint16_t t = temp();
                emit(vm::Op::getname, t, katom(n->a->text), 1);
                emit(vm::Op::typeof_, r, t);
                free_to(mark);
                return r;
            }
            if (n->op == js::Op::delete_) {
                const Node* t = n->a;
                while (t->kind == K::paren)
                    t = t->a;
                uint16_t mark = next;
                if (t->kind == K::member || t->kind == K::index) {
                    uint16_t obj = expr(t->a), key = temp();
                    if (t->kind == K::member)
                        emit(vm::Op::loadk, key, katom(t->text));
                    else
                        expr(t->b, key);
                    cur_pos = n->pos;
                    emit(vm::Op::del, r, obj, key);
                } else if (t->kind == K::ident) {
                    emit(vm::Op::loadk, r, konst(Value::boolean(false)));
                } else {
                    expr(t);
                    emit(vm::Op::loadk, r, konst(Value::boolean(true)));
                }
                free_to(mark);
                return r;
            }
            uint16_t mark = next;
            uint16_t a = expr(n->a);
            free_to(mark);
            switch (n->op) {
            case js::Op::neg:
                emit(vm::Op::neg, r, a);
                break;
            case js::Op::plus:
                emit(vm::Op::plus, r, a);
                break;
            case js::Op::not_:
                emit(vm::Op::not_, r, a);
                break;
            case js::Op::bnot:
                emit(vm::Op::bnot, r, a);
                break;
            case js::Op::typeof_:
                emit(vm::Op::typeof_, r, a);
                break;
            case js::Op::void_:
                emit(vm::Op::undef, r);
                break;
            default:
                c.fail(n->pos, "unary %s", js::op_name(n->op));
            }
            return r;
        }
        uint16_t update(const Node* n, uint16_t r) {
            const Node* t = n->a;
            while (t->kind == K::paren)
                t = t->a;
            uint16_t mark = next;
            uint16_t obj = 0, key = 0;
            uint16_t old = temp();
            if (t->kind == K::ident)
                load_name(t, old);
            else if (t->kind == K::member) {
                obj = expr(t->a);
                emit(vm::Op::getprop, old, obj, katom(t->text));
            } else if (t->kind == K::index) {
                obj = expr(t->a);
                key = temp();
                expr(t->b, key);
                emit(vm::Op::getidx, old, obj, key);
            } else {
                emit(vm::Op::fail_, katom("Invalid left-hand side in postfix operation"));
                return r;
            }
            emit(vm::Op::tonum, old, old);
            uint16_t one = temp(), nw = temp();
            emit(vm::Op::loadk, one, konst(Value::num(1)));
            emit(n->op == js::Op::inc ? vm::Op::add : vm::Op::sub, nw, old, one);
            if (t->kind == K::ident)
                store_name(t, nw);
            else if (t->kind == K::member)
                emit(vm::Op::setprop, obj, katom(t->text), nw);
            else {
                uint16_t pair = temp();
                temp();
                emit(vm::Op::mov, pair, key);
                emit(vm::Op::mov, static_cast<uint16_t>(pair + 1), nw);
                emit(vm::Op::setidx, obj, pair);
            }
            emit(vm::Op::mov, r, (n->flags & js::f_prefix) ? nw : old);
            free_to(mark);
            if (r >= next)
                next = static_cast<uint16_t>(r + 1);
            return r;
        }

        uint16_t assign(const Node* n, uint16_t dst) {
            const Node* t = n->a;
            while (t->kind == K::paren)
                t = t->a;
            uint16_t r = dst == any ? temp() : dst;
            if (n->op == js::Op::assign) {
                if (t->kind == K::array_pat || t->kind == K::object_pat) {
                    expr(n->b, r);
                    pattern(t, r, false);
                    return r;
                }
                if (t->kind == K::ident) {
                    expr(n->b, r);
                    store_name(t, r);
                    return r;
                }
                uint16_t mark = next;
                uint16_t obj = expr(t->a);
                if (t->kind == K::member) {
                    expr(n->b, r);
                    emit(vm::Op::setprop, obj, katom(t->text), r);
                } else if (t->kind == K::index) {
                    uint16_t pair = temp();
                    temp();
                    expr(t->b, pair);
                    expr(n->b, static_cast<uint16_t>(pair + 1));
                    emit(vm::Op::setidx, obj, pair);
                    emit(vm::Op::mov, r, static_cast<uint16_t>(pair + 1));
                } else {
                    emit(vm::Op::fail_, katom("Left side of assignment is not a reference."));
                }
                free_to(mark);
                if (r >= next)
                    next = static_cast<uint16_t>(r + 1);
                return r;
            }
            bool logical = n->op == js::Op::and_a || n->op == js::Op::or_a || n->op == js::Op::nullish_a;
            uint16_t mark = next;
            uint16_t obj = 0, key = 0;
            if (t->kind == K::ident)
                load_name(t, r);
            else if (t->kind == K::member) {
                obj = expr(t->a);
                emit(vm::Op::getprop, r, obj, katom(t->text));
            } else if (t->kind == K::index) {
                obj = expr(t->a);
                key = temp();
                expr(t->b, key);
                emit(vm::Op::getidx, r, obj, key);
            } else {
                emit(vm::Op::fail_, katom("Left side of assignment is not a reference."));
                return r;
            }
            uint32_t skip = 0;
            if (logical) {
                skip = n->op == js::Op::and_a ? jump(vm::Op::jf, r)
                    : n->op == js::Op::or_a   ? jump(vm::Op::jt, r)
                                              : jump(vm::Op::jnotnullish, r);
                expr(n->b, r);
            } else {
                uint16_t v = expr(n->b);
                static constexpr vm::Op k[] = {vm::Op::add,  vm::Op::sub,  vm::Op::mul, vm::Op::div,
                                               vm::Op::mod,  vm::Op::exp,  vm::Op::shl, vm::Op::shr,
                                               vm::Op::ushr, vm::Op::band, vm::Op::bor, vm::Op::bxor};
                int op = static_cast<int>(n->op) - static_cast<int>(js::Op::add_a);
                cur_pos = n->pos;
                emit(k[op], r, r, v);
            }
            if (t->kind == K::ident)
                store_name(t, r);
            else if (t->kind == K::member)
                emit(vm::Op::setprop, obj, katom(t->text), r);
            else {
                uint16_t pair = temp();
                temp();
                emit(vm::Op::mov, pair, key);
                emit(vm::Op::mov, static_cast<uint16_t>(pair + 1), r);
                emit(vm::Op::setidx, obj, pair);
            }
            if (logical)
                patch(skip, here());
            free_to(mark);
            if (r >= next)
                next = static_cast<uint16_t>(r + 1);
            return r;
        }

        uint16_t access(const Node* n, uint16_t r, List<uint32_t>* nullish_exit) {
            uint16_t mark = next;
            if (n->kind == K::call) {
                const Node* callee = n->a;
                while (callee->kind == K::paren)
                    callee = callee->a;
                uint16_t f = temp(), recv = temp();
                if (callee->kind == K::member || callee->kind == K::index) {
                    uint16_t obj = sub(callee->a, nullish_exit);
                    if ((callee->flags & js::f_optional) && nullish_exit)
                        (void)nullish_exit->push(c.arena, jump(vm::Op::jnullish, obj));
                    emit(vm::Op::mov, recv, obj);
                    if (callee->kind == K::member) {
                        cur_pos = callee->pos, cur_end = callee->end;
                        emit(vm::Op::getprop, f, obj, katom(callee->text));
                    } else {
                        uint16_t k = expr(callee->b);
                        cur_pos = callee->pos, cur_end = callee->end;
                        emit(vm::Op::getidx, f, obj, k);
                    }
                } else if (callee->kind == K::ident && !callee->ref) {
                    expr(callee, f);
                    emit(vm::Op::getbase, recv, katom(callee->text));
                } else {
                    expr(callee, f);
                    emit(vm::Op::undef, recv);
                }
                if ((n->flags & js::f_optional) && nullish_exit)
                    (void)nullish_exit->push(c.arena, jump(vm::Op::jnullish, f));
                free_to(static_cast<uint16_t>(recv + 1));
                bool spread = false;
                for (const Node* a = n->b; a; a = a->next)
                    spread = spread || a->kind == K::spread;
                cur_pos = n->pos;
                if (spread) {
                    uint16_t arr = temp();
                    emit(vm::Op::newarr, arr, 0);
                    for (const Node* a = n->b; a; a = a->next) {
                        uint16_t m2 = next;
                        if (a->kind == K::spread)
                            emit(vm::Op::aspread, arr, expr(a->a));
                        else
                            emit(vm::Op::apush, arr, expr(a));
                        free_to(m2);
                    }
                    cur_pos = n->pos;
                    emit(vm::Op::callspread, r, f, recv);
                } else {
                    uint32_t argc = 0;
                    for (const Node* a = n->b; a; a = a->next, argc++) {
                        uint16_t slot = temp();
                        expr(a, slot);
                        next = static_cast<uint16_t>(slot + 1);
                    }
                    cur_pos = n->pos, cur_end = n->end;
                    emit(vm::Op::call, r, f, recv);
                    cur_end = n->a->end;
                    emit(vm::Op::halt, argc);
                }
                free_to(mark);
                if (r >= next)
                    next = static_cast<uint16_t>(r + 1);
                return r;
            }
            uint16_t obj =
                n->kind == K::index && !(exit_chain(n->a, nullish_exit)) ? stable(n->a, n->b) : sub(n->a, nullish_exit);
            if ((n->flags & js::f_optional) && nullish_exit)
                (void)nullish_exit->push(c.arena, jump(vm::Op::jnullish, obj));
            cur_pos = n->pos;
            cur_end = n->end;
            if (n->kind == K::member)
                emit(vm::Op::getprop, r, obj, katom(n->text));
            else {
                cur_end = 0;
                uint16_t k = expr(n->b);
                cur_pos = n->pos;
                cur_end = n->end;
                emit(vm::Op::getidx, r, obj, k);
            }
            free_to(mark);
            if (r >= next)
                next = static_cast<uint16_t>(r + 1);
            return r;
        }
        bool exit_chain(const Node* n, List<uint32_t>* exit) const {
            return exit && (n->flags & js::f_chain)
                && (n->kind == K::member || n->kind == K::index || n->kind == K::call);
        }
        static bool effects(const Node* n) {
            if (!n)
                return false;
            if (n->kind == K::assign || n->kind == K::update || n->kind == K::call || n->kind == K::new_
                || n->kind == K::tagged)
                return true;
            if (n->kind == K::func || n->kind == K::arrow)
                return false;
            for (const Node* k : {n->a, n->b, n->c, n->d})
                for (const Node* x = k; x; x = x->next)
                    if (effects(x))
                        return true;
            return false;
        }
        uint16_t stable(const Node* n, const Node* later) {
            uint16_t r = expr(n);
            Binding* b = n->kind == K::ident ? static_cast<Binding*>(n->ref) : nullptr;
            if (b && !b->captured && r == b->reg && effects(later)) {
                uint16_t t = temp();
                emit(vm::Op::mov, t, r);
                return t;
            }
            return r;
        }
        uint16_t sub(const Node* n, List<uint32_t>* exit) {
            if (exit && (n->flags & js::f_chain) && (n->kind == K::member || n->kind == K::index || n->kind == K::call))
                return access(n, temp(), exit);
            return expr(n);
        }
        uint16_t chain(const Node* n, uint16_t r) {
            List<uint32_t> exits;
            access(n, r, &exits);
            uint32_t done = jump(vm::Op::jmp);
            uint32_t undef_at = here();
            emit(vm::Op::undef, r);
            for (uint32_t j : exits)
                patch(j, undef_at);
            patch(done, here());
            return r;
        }

        void pattern(const Node* p, uint16_t src, bool init) {
            if (c.failed || !p)
                return;
            switch (p->kind) {
            case K::ident:
                store_name(p, src, init);
                return;
            case K::paren:
                pattern(p->a, src, init);
                return;
            case K::member: {
                uint16_t mark = next;
                emit(vm::Op::setprop, expr(p->a), katom(p->text), src);
                free_to(mark);
                return;
            }
            case K::index: {
                uint16_t mark = next;
                uint16_t obj = expr(p->a);
                uint16_t pair = temp();
                temp();
                expr(p->b, pair);
                emit(vm::Op::mov, static_cast<uint16_t>(pair + 1), src);
                emit(vm::Op::setidx, obj, pair);
                free_to(mark);
                return;
            }
            case K::default_: {
                uint16_t mark = next;
                uint16_t t = temp(), u = temp();
                emit(vm::Op::mov, t, src);
                emit(vm::Op::loadk, u, konst(Value::undefined()));
                emit(vm::Op::seq, u, t, u);
                uint32_t j = jump(vm::Op::jf, u);
                expr(p->b, t);
                patch(j, here());
                pattern(p->a, t, init);
                free_to(mark);
                return;
            }
            case K::array_pat: {
                uint16_t mark = next;
                uint16_t it = temp();
                emit(vm::Op::iter, it, src);
                for (const Node* e = p->a; e; e = e->next) {
                    uint16_t m2 = next;
                    uint16_t v = temp();
                    if (e->kind == K::rest) {
                        emit(vm::Op::newarr, v, 0);
                        uint32_t loop = here();
                        uint16_t x = temp();
                        emit(vm::Op::next, x, it);
                        uint32_t nx = emit(vm::Op::halt);
                        emit(vm::Op::apush, v, x);
                        uint32_t back = jump(vm::Op::jmp);
                        patch(back, loop);
                        patch(nx, here());
                        pattern(e->a, v, init);
                    } else {
                        emit(vm::Op::next, v, it);
                        uint32_t nx = emit(vm::Op::halt);
                        uint32_t over = jump(vm::Op::jmp);
                        patch(nx, here());
                        emit(vm::Op::undef, v);
                        patch(over, here());
                        if (e->kind != K::hole)
                            pattern(e, v, init);
                    }
                    free_to(m2);
                }
                free_to(mark);
                return;
            }
            case K::object_pat: {
                uint16_t mark = next;
                uint16_t probe = temp();
                emit(vm::Op::getprop, probe, src, katom("constructor"));
                List<uint16_t> taken;
                for (const Node* e = p->a; e; e = e->next) {
                    if (e->kind == K::rest) {
                        uint16_t rest = temp(), keys = temp();
                        emit(vm::Op::newarr, keys, taken.size);
                        for (uint16_t k : taken)
                            emit(vm::Op::apush, keys, k);
                        emit(vm::Op::newobj, rest);
                        emit(vm::Op::orest, rest, src, keys);
                        pattern(e->a, rest, init);
                        continue;
                    }
                    uint16_t v = temp();
                    if (e->flags & js::f_computed) {
                        uint16_t k = temp();
                        expr(e->a, k);
                        emit(vm::Op::getidx, v, src, k);
                        (void)taken.push(c.arena, k);
                    } else {
                        Str* key = c.key_of(e->a);
                        uint16_t k = temp();
                        emit(vm::Op::loadk, k, kstr(key));
                        emit(vm::Op::getidx, v, src, k);
                        (void)taken.push(c.arena, k);
                    }
                    pattern(e->b, v, init);
                }
                free_to(mark);
                return;
            }
            default:
                c.fail(p->pos, "%s isn't a target", js::kind_name(p->kind));
            }
        }

        void stmts(const Node* n) {
            for (; n && !c.failed; n = n->next)
                stmt(n);
        }
        void stmt(const Node* n) {
            if (c.failed || !n)
                return;
            cur_pos = n->pos;
            uint16_t mark = next;
            switch (n->kind) {
            case K::expr_stmt:
                expr(n->a);
                break;
            case K::empty:
                break;
            case K::func_decl:
                break;
            case K::block: {
                Scope* s = static_cast<Scope*>(n->ref);
                enter(s);
                stmts(n->a);
                leave(s);
                break;
            }
            case K::var:
                declaration(n);
                break;
            case K::if_: {
                uint16_t t = expr(n->a);
                uint32_t jf = jump(vm::Op::jf, t);
                free_to(mark);
                stmt(n->b);
                if (n->c) {
                    uint32_t je = jump(vm::Op::jmp);
                    patch(jf, here());
                    stmt(n->c);
                    patch(je, here());
                } else
                    patch(jf, here());
                break;
            }
            case K::while_: {
                Loop* l = loop_open(true);
                uint32_t top = here();
                uint16_t t = expr(n->a);
                uint32_t jf = jump(vm::Op::jf, t);
                free_to(mark);
                stmt(n->d);
                for (uint32_t j : l->continues)
                    patch(j, here());
                patch(jump(vm::Op::jmp), top);
                patch(jf, here());
                loop_close(l);
                break;
            }
            case K::do_while: {
                Loop* l = loop_open(true);
                uint32_t top = here();
                stmt(n->d);
                for (uint32_t j : l->continues)
                    patch(j, here());
                uint16_t t = expr(n->a);
                patch(jump(vm::Op::jt, t), top);
                loop_close(l);
                break;
            }
            case K::for_:
                for_loop(n);
                break;
            case K::for_in:
            case K::for_of:
                for_each(n);
                break;
            case K::switch_: {
                uint16_t d = temp();
                expr(n->a, d);
                Loop* l = loop_open(false);
                if (!l)
                    return;
                l->is_switch = true;
                Scope* s = static_cast<Scope*>(n->b->ref);
                enter(s);
                List<uint32_t> to;
                for (const Node* x = n->b->a; x; x = x->next) {
                    if (x->kind != K::case_ || !x->a)
                        continue;
                    uint16_t m2 = next;
                    uint16_t v = expr(x->a);
                    uint16_t r = temp();
                    emit(vm::Op::seq, r, d, v);
                    (void)to.push(c.arena, jump(vm::Op::jt, r));
                    free_to(m2);
                }
                uint32_t none = jump(vm::Op::jmp);
                bool had_default = false;
                uint32_t at = 0;
                for (const Node* x = n->b->a; x && !c.failed; x = x->next) {
                    if (x->kind != K::case_) {
                        stmt(x);
                        continue;
                    }
                    if (x->a)
                        patch(to[at++], here());
                    else
                        patch(none, here()), had_default = true;
                }
                if (!had_default)
                    patch(none, here());
                leave(s);
                loop_close(l);
                break;
            }
            case K::return_: {
                uint16_t r = temp();
                if (n->a)
                    expr(n->a, r);
                else
                    emit(vm::Op::undef, r);
                exit_finallies(0);
                emit(vm::Op::ret, r);
                break;
            }
            case K::break_:
            case K::continue_: {
                Loop* l = nullptr;
                for (uint32_t k = loops.size; k-- > 0;)
                    if (loops[k]->is_loop || (loops[k]->is_switch && n->kind == K::break_)) {
                        l = loops[k];
                        break;
                    }
                if (!l) {
                    c.fail(n->pos, "break outside a loop");
                    return;
                }
                exit_finallies(l->finally_depth);
                Scope* to = n->kind == K::break_ ? l->scope : l->cont;
                for (Scope* s = scope; s && s != to; s = s->up)
                    if (s->needs_env)
                        emit(vm::Op::popenv);
                (void)(n->kind == K::break_ ? l->breaks : l->continues).push(c.arena, jump(vm::Op::jmp));
                break;
            }
            case K::try_:
                try_stmt(n);
                break;
            default:
                c.fail(n->pos, "%s can't be compiled yet", js::kind_name(n->kind));
            }
            free_to(mark);
        }
        void exit_finallies(uint32_t depth) {
            for (uint32_t k = finallies.size; k-- > depth;) {
                emit(vm::Op::tryleave);
                const Node* f = finallies[k];
                uint32_t saved = finallies.size;
                finallies.size = k;
                Scope* was = scope;
                stmt(f);
                scope = was;
                finallies.size = saved;
            }
        }
        Loop* loop_open(bool is_loop) {
            Loop* l = c.arena.make<Loop>();
            if (!l) {
                c.fail(cur_pos, "out of memory");
                return nullptr;
            }
            l->scope = l->cont = scope;
            l->finally_depth = finallies.size;
            l->is_loop = is_loop;
            (void)loops.push(c.arena, l);
            return l;
        }
        void loop_close(Loop* l) {
            for (uint32_t j : l->breaks)
                patch(j, here());
            loops.size--;
        }
        void declaration(const Node* n) {
            for (const Node* d = n->a; d; d = d->next) {
                uint16_t mark = next;
                if (!d->b) {
                    if (n->op != js::Op::var_) {
                        uint16_t t = temp();
                        emit(vm::Op::undef, t);
                        pattern(d->a, t, true);
                    }
                    free_to(mark);
                    continue;
                }
                if (d->a->kind == K::ident) {
                    Binding* b = static_cast<Binding*>(d->a->ref);
                    if (b && !b->captured) {
                        expr(d->b, b->reg);
                        free_to(mark);
                        continue;
                    }
                }
                uint16_t t = temp();
                expr(d->b, t);
                pattern(d->a, t, true);
                free_to(mark);
            }
        }
        void for_loop(const Node* n) {
            Scope* h = static_cast<Scope*>(n->ref);
            enter(h);
            if (n->a) {
                if (n->a->kind == K::var)
                    declaration(n->a);
                else {
                    uint16_t m = next;
                    expr(n->a);
                    free_to(m);
                }
            }
            Loop* l = loop_open(true);
            l->scope = l->cont = h;
            uint32_t top = here();
            uint32_t jf = 0;
            bool has_test = n->b != nullptr;
            if (has_test) {
                uint16_t m = next;
                uint16_t t = expr(n->b);
                jf = jump(vm::Op::jf, t);
                free_to(m);
            }
            stmt(n->d);
            for (uint32_t j : l->continues)
                patch(j, here());
            if (h->per_iteration && h->needs_env)
                emit(vm::Op::copyenv);
            if (n->c) {
                uint16_t m = next;
                expr(n->c);
                free_to(m);
            }
            patch(jump(vm::Op::jmp), top);
            if (has_test)
                patch(jf, here());
            loop_close(l);
            leave(h);
        }
        void for_each(const Node* n) {
            Scope* h = static_cast<Scope*>(n->ref);
            uint16_t mark = next;
            uint16_t it = temp();
            uint16_t src = expr(n->b);
            if (n->kind == K::for_in) {
                uint16_t keys = temp();
                emit(vm::Op::keys, keys, src);
                emit(vm::Op::iter, it, keys);
            } else {
                emit(vm::Op::iter, it, src);
            }
            Loop* l = loop_open(true);
            uint32_t top = here();
            uint16_t x = temp();
            emit(vm::Op::next, x, it);
            uint32_t nx = emit(vm::Op::halt);
            enter(h);
            l->scope = h->up;
            l->cont = h;
            const Node* target = n->a;
            if (target->kind == K::var)
                pattern(target->a->a, x, true);
            else
                pattern(target, x, false);
            stmt(n->d);
            for (uint32_t j : l->continues)
                patch(j, here());
            leave(h);
            patch(jump(vm::Op::jmp), top);
            patch(nx, here());
            loop_close(l);
            free_to(mark);
        }
        void try_stmt(const Node* n) {
            if (n->d)
                (void)finallies.push(c.arena, n->d);
            uint16_t mark = next;
            uint16_t err = temp();
            uint32_t enter_at = emit(vm::Op::tryenter, err);
            Scope* was = scope;
            stmt(n->a);
            emit(vm::Op::tryleave);
            if (n->d) {
                finallies.size--;
                Scope* w2 = scope;
                stmt(n->d);
                scope = w2;
                (void)finallies.push(c.arena, n->d);
            }
            uint32_t over = jump(vm::Op::jmp);
            patch(enter_at, here());
            scope = was;
            if (n->c) {
                Scope* cs = static_cast<Scope*>(n->ref);
                if (n->d) {
                    uint16_t err2 = temp();
                    uint32_t e2 = emit(vm::Op::tryenter, err2);
                    enter(cs);
                    if (n->b)
                        pattern(n->b, err, true);
                    stmts(n->c->a);
                    leave(cs);
                    emit(vm::Op::tryleave);
                    finallies.size--;
                    stmt(n->d);
                    uint32_t over2 = jump(vm::Op::jmp);
                    patch(e2, here());
                    stmt(n->d);
                    emit(vm::Op::fail_, 0xFFFF);
                    ins[ins.size - 1].b = err2;
                    patch(over2, here());
                } else {
                    enter(cs);
                    if (n->b)
                        pattern(n->b, err, true);
                    stmts(n->c->a);
                    leave(cs);
                }
            } else {
                finallies.size--;
                stmt(n->d);
                emit(vm::Op::fail_, 0xFFFF);
                ins[ins.size - 1].b = err;
            }
            patch(over, here());
            free_to(mark);
        }

        const Code* finish(Scope* top) {
            (void)top;
            Code* code = c.arena.make<Code>();
            if (!code)
                return nullptr;
            code->ins = ins.data;
            code->n_ins = ins.size;
            code->consts = consts.data;
            code->n_consts = consts.size;
            code->children = children.data;
            code->n_children = children.size;
            code->n_regs = static_cast<uint16_t>(max + 1);
            code->n_params = static_cast<uint16_t>(fn->params.size);
            code->pos = pos.data;
            code->ends = ends.data;
            code->src = c.file;
            code->has_env = fn->scope->needs_env;
            code->env_size = fn->scope->env_size;
            if (fn->node && (fn->node->kind == K::func || fn->node->kind == K::func_decl) && !fn->node->text.empty())
                code->name = c.rt.atom(c.rt.str_ascii(fn->node->text));
            return code;
        }
    };

    const Code* function(FnInfo* f) {
        if (!f || failed)
            return nullptr;
        Gen g(*this, f);
        uint16_t n = layout(f);
        g.next = g.max = n;
        g.scope = f->scope;
        if (f->scope->needs_env)
            g.emit(vm::Op::newenv, 0, f->scope->env_size);
        uint32_t k = 0;
        for (const Node* p : f->params) {
            uint16_t reg = static_cast<uint16_t>(k++);
            g.cur_pos = p->pos;
            if (p->kind == K::ident) {
                Binding* b = static_cast<Binding*>(p->ref);
                if (b && b->captured)
                    g.emit(vm::Op::setenv, reg, 0, b->slot);
                continue;
            }
            if (p->kind == K::rest) {
                g.emit(vm::Op::rest, reg, k - 1);
                g.pattern(p->a, reg, true);
                continue;
            }
            g.pattern(p, reg, true);
        }
        for (Binding* b : f->scope->names) {
            if (b->kind == BKind::let || b->kind == BKind::const_) {
                uint16_t h = g.temp();
                g.emit(vm::Op::loadk, h, g.konst(Value::hole()));
                if (b->captured)
                    g.emit(vm::Op::setenv, h, 0, b->slot);
                else
                    g.emit(vm::Op::mov, b->reg, h);
                g.free_to(h);
            }
        }
        if (f->node && f->node->kind == K::func && !f->node->text.empty()) {
            Binding* b = find_in(f->scope, f->node->text);
            if (b && b->kind == BKind::var) {
                uint16_t t = g.temp();
                g.emit(vm::Op::arg, t, 0xFFFF);
                if (b->captured)
                    g.emit(vm::Op::setenv, t, 0, b->slot);
                else
                    g.emit(vm::Op::mov, b->reg, t);
                g.free_to(t);
            }
        }
        g.declare_functions(f->scope);
        uint16_t r = g.temp();
        if (f->expr_body) {
            const Node* body = f->node && f->node->kind == K::arrow ? f->node->b : f->node;
            if (!f->node || f->node->kind != K::arrow)
                body = unit_expr;
            g.expr(body, r);
            g.emit(vm::Op::ret, r);
        } else {
            const Node* body =
                f->node && (f->node->kind == K::func || f->node->kind == K::func_decl || f->node->kind == K::arrow)
                ? f->node->b
                : unit_body;
            g.stmts(body ? body->a : nullptr);
            g.emit(vm::Op::undef, r);
            g.emit(vm::Op::ret, r);
        }
        if (failed)
            return nullptr;
        return g.finish(f->scope);
    }
    const Node *unit_expr = nullptr, *unit_body = nullptr;

    Str* cook(sv raw, uint32_t pos) {
        (void)pos;
        char16_t* buf = arena.array<char16_t>(raw.size() + 1);
        if (!buf)
            return rt.empty;
        size_t n = 0;
        for (size_t i = 0; i < raw.size();) {
            unsigned char ch = static_cast<unsigned char>(raw[i]);
            if (ch != '\\') {
                if (ch < 0x80) {
                    buf[n++] = ch == '\r' ? u'\n' : ch;
                    if (ch == '\r' && i + 1 < raw.size() && raw[i + 1] == '\n')
                        i++;
                    i++;
                    continue;
                }
                utf::Cp cp = utf::decode(raw, i);
                char32_t x = cp.len ? cp.cp : 0xFFFD;
                i += cp.len ? cp.len : 1;
                if (x >= 0x10000) {
                    buf[n++] = static_cast<char16_t>(0xD800 + ((x - 0x10000) >> 10));
                    buf[n++] = static_cast<char16_t>(0xDC00 + ((x - 0x10000) & 0x3FF));
                } else
                    buf[n++] = static_cast<char16_t>(x);
                continue;
            }
            i++;
            if (i >= raw.size())
                break;
            char e = raw[i++];
            auto hex = [&](size_t at, int count) -> long {
                long v = 0;
                for (int k = 0; k < count; k++) {
                    if (at + static_cast<size_t>(k) >= raw.size())
                        return -1;
                    char h = raw[at + static_cast<size_t>(k)];
                    int d = h >= '0' && h <= '9'                 ? h - '0'
                        : (h | 0x20) >= 'a' && (h | 0x20) <= 'f' ? (h | 0x20) - 'a' + 10
                                                                 : -1;
                    if (d < 0)
                        return -1;
                    v = v * 16 + d;
                }
                return v;
            };
            switch (e) {
            case 'n':
                buf[n++] = '\n';
                break;
            case 't':
                buf[n++] = '\t';
                break;
            case 'r':
                buf[n++] = '\r';
                break;
            case 'b':
                buf[n++] = '\b';
                break;
            case 'f':
                buf[n++] = '\f';
                break;
            case 'v':
                buf[n++] = '\v';
                break;
            case '\r':
                if (i < raw.size() && raw[i] == '\n')
                    i++;
                break;
            case '\n':
                break;
            case 'x': {
                long v = hex(i, 2);
                if (v >= 0)
                    buf[n++] = static_cast<char16_t>(v), i += 2;
                break;
            }
            case 'u': {
                if (i < raw.size() && raw[i] == '{') {
                    size_t e2 = raw.find('}', i);
                    long v = 0;
                    for (size_t k = i + 1; k < e2; k++)
                        v = v * 16 + hex(k, 1);
                    i = e2 + 1;
                    if (v >= 0x10000) {
                        buf[n++] = static_cast<char16_t>(0xD800 + ((v - 0x10000) >> 10));
                        buf[n++] = static_cast<char16_t>(0xDC00 + ((v - 0x10000) & 0x3FF));
                    } else
                        buf[n++] = static_cast<char16_t>(v);
                } else {
                    long v = hex(i, 4);
                    if (v >= 0)
                        buf[n++] = static_cast<char16_t>(v), i += 4;
                }
                break;
            }
            default:
                if (e >= '0' && e <= '7') {
                    long v = e - '0';
                    if (i < raw.size() && raw[i] >= '0' && raw[i] <= '7') {
                        v = v * 8 + (raw[i++] - '0');
                        if (e <= '3' && i < raw.size() && raw[i] >= '0' && raw[i] <= '7')
                            v = v * 8 + (raw[i++] - '0');
                    }
                    buf[n++] = static_cast<char16_t>(v);
                } else if (static_cast<unsigned char>(e) >= 0x80) {
                    i--;
                    utf::Cp cp = utf::decode(raw, i);
                    char32_t x = cp.len ? cp.cp : 0xFFFD;
                    i += cp.len ? cp.len : 1;
                    if (x == 0x2028 || x == 0x2029)
                        break;
                    if (x >= 0x10000) {
                        buf[n++] = static_cast<char16_t>(0xD800 + ((x - 0x10000) >> 10));
                        buf[n++] = static_cast<char16_t>(0xDC00 + ((x - 0x10000) & 0x3FF));
                    } else
                        buf[n++] = static_cast<char16_t>(x);
                } else
                    buf[n++] = static_cast<char16_t>(e);
            }
        }
        Str* s = rt.str({buf, n});
        return s ? s : rt.empty;
    }
    Str* key_of(const Node* k) {
        if (k->kind == K::ident)
            return rt.atom(rt.str_ascii(k->text));
        if (k->kind == K::str)
            return rt.atom(cook(k->text, k->pos));
        if (k->kind == K::num) {
            char16_t buf[40];
            size_t n = num_text(k->num, buf);
            return rt.atom({buf, n});
        }
        return rt.empty;
    }
    static size_t num_text(double d, char16_t* buf);
};

}
}

#include "engine/vm/number.h"

namespace rx::engine::vm {
namespace {
size_t Compiler::num_text(double d, char16_t* buf) {
    return num::to_string(d, buf);
}
}

namespace {
const Code* keep(const Code* from, Arena& to) noexcept {
    if (!from)
        return nullptr;
    Code* c = to.make<Code>();
    if (!c)
        return nullptr;
    *c = *from;
    if (from->n_ins) {
        Ins* ins = to.array<Ins>(from->n_ins);
        uint32_t *pos = to.array<uint32_t>(from->n_ins), *ends = to.array<uint32_t>(from->n_ins);
        if (!ins || !pos || !ends)
            return nullptr;
        std::memcpy(static_cast<void*>(ins), from->ins, sizeof(Ins) * from->n_ins);
        std::memcpy(pos, from->pos, sizeof(uint32_t) * from->n_ins);
        if (from->ends)
            std::memcpy(ends, from->ends, sizeof(uint32_t) * from->n_ins);
        c->ins = ins, c->pos = pos, c->ends = from->ends ? ends : nullptr;
    }
    if (from->n_consts) {
        Value* k = to.array<Value>(from->n_consts);
        if (!k)
            return nullptr;
        std::memcpy(static_cast<void*>(k), from->consts, sizeof(Value) * from->n_consts);
        c->consts = k;
    }
    if (from->n_children) {
        const Code** kids = to.array<const Code*>(from->n_children);
        if (!kids)
            return nullptr;
        for (uint32_t i = 0; i < from->n_children; i++)
            if (!(kids[i] = keep(from->children[i], to)))
                return nullptr;
        c->children = kids;
    }
    return c;
}
}

std::expected<const Code*, CompileError> compile(const js::Node* unit, js::Goal goal, std::string_view file, Rt& rt,
                                                 const std::string_view* params, uint32_t n_params,
                                                 Arena* scratch) noexcept {
    Compiler c{rt, scratch ? *scratch : rt.arena, file};
    bool expr = goal == js::Goal::value && unit->kind != js::K::block_body;
    js::Node *plist = nullptr, **tail = &plist;
    for (uint32_t i = 0; i < n_params; i++) {
        js::Node* p = rt.arena.make<js::Node>();
        if (!p)
            return std::unexpected(CompileError{0, "out of memory"});
        p->kind = js::K::ident;
        p->text = params[i];
        *tail = p;
        tail = &p->next;
    }
    FnInfo* f = c.resolve_fn(nullptr, nullptr, nullptr, plist, expr ? unit : unit, expr);
    if (expr)
        c.unit_expr = unit;
    else
        c.unit_body = unit;
    if (!f || c.failed)
        return std::unexpected(c.error);
    const Code* code = c.function(f);
    if (!code)
        return std::unexpected(c.failed ? c.error : CompileError{0, "out of memory"});
    if (scratch && !(code = keep(code, rt.perm)))
        return std::unexpected(CompileError{0, "out of memory"});
    return code;
}

std::expected<const Code*, CompileError> compile_function(const js::Node* func, std::string_view file, Rt& rt,
                                                          Arena* scratch) noexcept {
    Compiler c{rt, scratch ? *scratch : rt.arena, file};
    FnInfo* f = c.resolve_fn(func, nullptr, nullptr, func->a, func->b, false);
    if (!f || c.failed)
        return std::unexpected(c.error);
    const Code* code = c.function(f);
    if (!code)
        return std::unexpected(c.failed ? c.error : CompileError{0, "out of memory"});
    if (scratch && !(code = keep(code, rt.perm)))
        return std::unexpected(CompileError{0, "out of memory"});
    return code;
}

}
