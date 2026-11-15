// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/gc.h"
#include "engine/vm/lib.h"

namespace rx::engine::vm {

enum class PState : uint8_t { pending, fulfilled, rejected };

struct Reaction {
    Value handler;
    Value derived;
    bool on_reject;
    Reaction* next;
};

struct PromiseObj {
    Cell h;
    PState state;
    bool resolving;
    Value result;
    Reaction *fulfill, *reject;
};

struct Job {
    enum Kind : uint8_t { reaction, follow } kind;
    Value handler, argument, derived;
    bool rejected;
    Value thenable, then_fn;
};

namespace lib {
namespace {

PromiseObj* as_promise(Value v) {
    return v.is(Kind::promise) ? v.as<PromiseObj>() : nullptr;
}

PromiseObj* make_raw(Rt& rt) {
    PromiseObj* p = rt.arena.make<PromiseObj>();
    if (!p)
        return rt.fail(ErrorKind::internal, "out of memory"), nullptr;
    p->h = Cell{0, Kind::promise, 0, 0};
    p->state = PState::pending;
    return p;
}

bool enqueue(Rt& rt, const Job& j) {
    Job* copy = rt.arena.make<Job>();
    if (!copy)
        return rt.fail(ErrorKind::internal, "out of memory"), false;
    *copy = j;
    return rt.jobs.push(rt.perm, copy) || (rt.fail(ErrorKind::internal, "out of memory"), false);
}

void trigger(Rt& rt, Reaction* r, Value result, bool rejected) {
    for (; r; r = r->next)
        enqueue(rt, Job{Job::reaction, r->handler, result, r->derived, rejected, {}, {}});
}

void settle(Rt& rt, PromiseObj* p, Value v, bool rejected) {
    if (p->state != PState::pending)
        return;
    p->state = rejected ? PState::rejected : PState::fulfilled;
    p->result = v;
    trigger(rt, rejected ? p->reject : p->fulfill, v, rejected);
    p->fulfill = p->reject = nullptr;
}

void resolve(Vm& vm, PromiseObj* p, Value x) {
    Rt& rt = vm.rt;
    if (x.same_bits(Value::cell(&p->h))) {
        rt.fail(ErrorKind::type, "Cannot resolve a promise with itself");
        Value e = rt.thrown;
        rt.clear();
        return settle(rt, p, e, true);
    }
    if (!x.is_cell() || x.is(Kind::string))
        return settle(rt, p, x, false);
    Value then = get(rt, x, rt.atom(rt.str_ascii("then")));
    if (rt.failed) {
        Value e = rt.thrown;
        rt.clear();
        return settle(rt, p, e, true);
    }
    if (!callable(then))
        return settle(rt, p, x, false);
    enqueue(rt, Job{Job::follow, {}, {}, Value::cell(&p->h), false, x, then});
}

struct Resolver {
    Native n;
    PromiseObj* p;
    bool reject;
    bool* done;
};
Value resolver_call(Vm& vm, Value self, const Value* args, uint32_t argc);
Value resolver_fn(Rt& rt, PromiseObj* p, bool reject, bool* done) {
    Resolver* r = rt.arena.make<Resolver>();
    if (!r)
        return rt.fail(ErrorKind::internal, "out of memory");
    r->n.h = Cell{0, Kind::native, 0, 0};
    r->n.fn = resolver_call;
    r->n.name = rt.empty;
    r->n.length = 1;
    r->p = p;
    r->reject = reject;
    r->done = done;
    return Value::cell(&r->n.h);
}
Value resolver_call(Vm&, Value, const Value*, uint32_t) {
    return Value::undefined();
}

}

Value then_(Vm& vm, PromiseObj* p, Value on_ok, Value on_err);

Value promise_resolver(Vm& vm, Native* n, const Value* args, uint32_t argc) noexcept {
    Resolver* r = reinterpret_cast<Resolver*>(n);
    if (*r->done)
        return Value::undefined();
    *r->done = true;
    Value v = arg(args, argc, 0);
    if (r->reject)
        settle(vm.rt, r->p, v, true);
    else
        resolve(vm, r->p, v);
    return Value::undefined();
}
bool is_promise_resolver(const Native* n) noexcept {
    return n->fn == resolver_call;
}

Value promise_new(Rt& rt) noexcept {
    PromiseObj* p = make_raw(rt);
    return p ? Value::cell(&p->h) : Value::undefined();
}
void promise_settle(Vm& vm, Value promise, Value v, bool rejected) noexcept {
    PromiseObj* p = as_promise(promise);
    if (!p || p->resolving)
        return;
    p->resolving = true;
    if (rejected)
        settle(vm.rt, p, v, true);
    else
        resolve(vm, p, v);
}

void drain_jobs(Vm& vm) noexcept {
    Rt& rt = vm.rt;
    for (uint32_t k = 0; k < rt.jobs.size; k++) {
        Job j = *rt.jobs[k];
        if (j.kind == Job::follow) {
            PromiseObj* p = j.derived.as<PromiseObj>();
            bool* done = rt.arena.make<bool>();
            if (!done)
                return;
            Value fns[2] = {resolver_fn(rt, p, false, done), resolver_fn(rt, p, true, done)};
            if (rt.failed)
                return;
            vm.call(j.then_fn, j.thenable, fns, 2);
            if (rt.failed) {
                if (rt.error == ErrorKind::internal)
                    return;
                Value e = rt.thrown;
                rt.clear();
                if (!*done) {
                    *done = true;
                    settle(rt, p, e, true);
                }
            }
            continue;
        }
        Value result;
        bool rejected = false;
        if (callable(j.handler)) {
            result = vm.call(j.handler, Value::undefined(), &j.argument, 1);
            if (rt.failed) {
                if (rt.error == ErrorKind::internal)
                    return;
                result = rt.thrown;
                rt.clear();
                rejected = true;
            }
        } else {
            result = j.argument, rejected = j.rejected;
        }
        if (PromiseObj* d = as_promise(j.derived)) {
            if (rejected)
                settle(rt, d, result, true);
            else
                resolve(vm, d, result);
        }
    }
    rt.jobs.size = 0;
}

Value then_(Vm& vm, PromiseObj* p, Value on_ok, Value on_err) {
    Rt& rt = vm.rt;
    PromiseObj* d = make_raw(rt);
    if (!d)
        return Value::undefined();
    Value dv = Value::cell(&d->h);
    Reaction *ok = rt.arena.make<Reaction>(), *err = rt.arena.make<Reaction>();
    if (!ok || !err)
        return rt.fail(ErrorKind::internal, "out of memory");
    *ok = Reaction{callable(on_ok) ? on_ok : Value::undefined(), dv, false, nullptr};
    *err = Reaction{callable(on_err) ? on_err : Value::undefined(), dv, true, nullptr};
    if (p->state == PState::pending) {
        Reaction** t = &p->fulfill;
        while (*t)
            t = &(*t)->next;
        *t = ok;
        t = &p->reject;
        while (*t)
            t = &(*t)->next;
        *t = err;
    } else {
        bool rej = p->state == PState::rejected;
        enqueue(rt, Job{Job::reaction, rej ? err->handler : ok->handler, p->result, dv, rej, {}, {}});
    }
    return dv;
}

namespace {

#define THIS_PROMISE(method)          \
    Rt& rt = vm.rt;                   \
    PromiseObj* P = as_promise(self); \
    if (!P)                           \
    return rt.fail(ErrorKind::type, "Promise.prototype.%s called on a value that isn't a promise", method)

Value p_then(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_PROMISE("then");
    (void)rt;
    return then_(vm, P, arg(args, argc, 0), arg(args, argc, 1));
}
Value p_catch(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_PROMISE("catch");
    (void)rt;
    return then_(vm, P, Value::undefined(), arg(args, argc, 0));
}
struct Finally {
    Native n;
    enum Mode : uint8_t { then_finally, catch_finally, value_thunk, thrower } mode;
    Value fn;
};
Value finally_call(Vm&, Value, const Value*, uint32_t) {
    return Value::undefined();
}
Finally* finally_fn(Rt& rt, Finally::Mode mode, Value v) {
    Finally* f = rt.arena.make<Finally>();
    if (!f)
        return rt.fail(ErrorKind::internal, "out of memory"), nullptr;
    f->n.h = Cell{0, Kind::native, 0, 0};
    f->n.fn = finally_call;
    f->n.name = rt.empty;
    f->mode = mode;
    f->fn = v;
    return f;
}
}
bool is_finally(const Native* n) noexcept {
    return n->fn == finally_call;
}
Value finally_run(Vm& vm, Native* n, const Value* args, uint32_t argc) noexcept {
    Finally* f = reinterpret_cast<Finally*>(n);
    Rt& rt = vm.rt;
    Value v = arg(args, argc, 0);
    switch (f->mode) {
    case Finally::value_thunk:
        return f->fn;
    case Finally::thrower:
        rt.fail(ErrorKind::type, "rethrown");
        rt.thrown = f->fn;
        return Value::undefined();
    default:
        break;
    }
    Value r = vm.call(f->fn, Value::undefined(), nullptr, 0);
    if (rt.failed)
        return Value::undefined();
    PromiseObj* p = as_promise(r);
    if (!p) {
        p = make_raw(rt);
        if (!p)
            return Value::undefined();
        resolve(vm, p, r);
    }
    Finally* thunk = finally_fn(rt, f->mode == Finally::then_finally ? Finally::value_thunk : Finally::thrower, v);
    if (!thunk)
        return Value::undefined();
    return then_(vm, p, Value::cell(&thunk->n.h), Value::undefined());
}
namespace {
Value p_finally(Vm& vm, Value self, const Value* args, uint32_t argc) {
    THIS_PROMISE("finally");
    Value fn = arg(args, argc, 0);
    if (!callable(fn))
        return then_(vm, P, fn, fn);
    Finally *a = finally_fn(rt, Finally::then_finally, fn), *b = finally_fn(rt, Finally::catch_finally, fn);
    if (!a || !b)
        return Value::undefined();
    return then_(vm, P, Value::cell(&a->n.h), Value::cell(&b->n.h));
}
Value s_resolve(Vm& vm, Value, const Value* args, uint32_t argc) {
    Value v = arg(args, argc, 0);
    if (as_promise(v))
        return v;
    Value p = promise_new(vm.rt);
    if (!p.is_cell())
        return Value::undefined();
    promise_settle(vm, p, v, false);
    return p;
}
Value s_reject(Vm& vm, Value, const Value* args, uint32_t argc) {
    Value p = promise_new(vm.rt);
    if (!p.is_cell())
        return Value::undefined();
    promise_settle(vm, p, arg(args, argc, 0), true);
    return p;
}

}

void install_promise(Rt& rt) noexcept {
    def(rt, rt.promise_proto, "then", p_then, 2);
    def(rt, rt.promise_proto, "catch", p_catch, 1);
    def(rt, rt.promise_proto, "finally", p_finally, 1);
    Obj* promise = rt.object();
    if (!promise)
        return;
    rt.put(rt.globals, rt.atom(rt.str_ascii("Promise")), val(promise));
    def(rt, promise, "resolve", s_resolve, 1);
    def(rt, promise, "reject", s_reject, 1);
}

bool is_promise(Value v) noexcept {
    return as_promise(v) != nullptr;
}

size_t gc_promise_size(const Cell* c) noexcept {
    if (c->kind == Kind::promise)
        return sizeof(PromiseObj);
    const Native* n = reinterpret_cast<const Native*>(c);
    if (is_promise_resolver(n))
        return sizeof(Resolver);
    if (is_finally(n))
        return sizeof(Finally);
    return 0;
}

namespace {
Reaction* gc_reactions(Reaction* r, Gc& gc) {
    Reaction *head = nullptr, **tail = &head;
    for (; r; r = r->next) {
        Reaction* q = static_cast<Reaction*>(gc.raw(r, sizeof(Reaction)));
        q->handler = gc.value(q->handler);
        q->derived = gc.value(q->derived);
        *tail = q;
        tail = &q->next;
    }
    *tail = nullptr;
    return head;
}
}

void gc_promise_trace(Cell* c, Gc& gc) noexcept {
    if (c->kind == Kind::promise) {
        PromiseObj* p = reinterpret_cast<PromiseObj*>(c);
        p->result = gc.value(p->result);
        p->fulfill = gc_reactions(p->fulfill, gc);
        p->reject = gc_reactions(p->reject, gc);
        return;
    }
    Native* n = reinterpret_cast<Native*>(c);
    if (is_promise_resolver(n)) {
        Resolver* r = reinterpret_cast<Resolver*>(c);
        r->p = gc.of(r->p);
        r->done = static_cast<bool*>(gc.raw(r->done, sizeof(bool), alignof(bool)));
    } else if (is_finally(n)) {
        Finally* f = reinterpret_cast<Finally*>(c);
        f->fn = gc.value(f->fn);
    }
}

void gc_jobs(Rt& rt, Gc& gc) noexcept {
    for (uint32_t k = 0; k < rt.jobs.size; k++) {
        Job* j = rt.jobs[k] = static_cast<Job*>(gc.raw(rt.jobs[k], sizeof(Job)));
        for (Value* v : {&j->handler, &j->argument, &j->derived, &j->thenable, &j->then_fn})
            *v = gc.value(*v);
    }
}

}
}
