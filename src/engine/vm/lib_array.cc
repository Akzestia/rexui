// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <algorithm>
#include <cmath>

#include "engine/vm/lib.h"

namespace rx::engine::vm::lib {
namespace {

#define SELF(method)                                                                                         \
    Rt& rt = vm.rt;                                                                                          \
    if (!self.is(Kind::array))                                                                               \
        return rt.fail(ErrorKind::type, "Array.prototype.%s called on a value that isn't an array", method); \
    Arr* A = self.as<Arr>();                                                                                 \
    (void)A

#define CALLBACK(method)                                                                           \
    Value fn = arg(args, argc, 0), self_arg = arg(args, argc, 1);                                  \
    if (!callable(fn))                                                                             \
        return rt.fail(ErrorKind::type, "Array.prototype.%s callback must be a function", method); \
    (void)self_arg

bool present(Arr* a, uint32_t k) {
    return k < a->length && !a->items[k].is_hole();
}
Value at(Arr* a, uint32_t k) {
    return present(a, k) ? a->items[k] : Value::undefined();
}
Value call3(Vm& vm, Value fn, Value self, Value a, uint32_t k, Arr* arr) {
    Value args[3] = {a, Value::num(k), val(arr)};
    return vm.call(fn, self, args, 3);
}

Value a_map(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("map");
    CALLBACK("map");
    uint32_t len = A->length;
    Arr* out = rt.array(len);
    if (!out || !rt.set_length(out, len))
        return Value::undefined();
    for (uint32_t k = 0; k < len; k++) {
        if (!present(A, k))
            continue;
        Value v = call3(vm, fn, self_arg, A->items[k], k, A);
        if (rt.failed)
            return Value::undefined();
        out->items[k] = v;
    }
    return val(out);
}
Value a_filter(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("filter");
    CALLBACK("filter");
    uint32_t len = A->length;
    Arr* out = rt.array(0);
    if (!out)
        return Value::undefined();
    for (uint32_t k = 0; k < len; k++) {
        if (!present(A, k))
            continue;
        Value x = A->items[k];
        Value v = call3(vm, fn, self_arg, x, k, A);
        if (rt.failed)
            return Value::undefined();
        if (to_boolean(v) && !rt.push(out, x))
            return Value::undefined();
    }
    return val(out);
}
Value a_foreach(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("forEach");
    CALLBACK("forEach");
    uint32_t len = A->length;
    for (uint32_t k = 0; k < len; k++) {
        if (!present(A, k))
            continue;
        call3(vm, fn, self_arg, A->items[k], k, A);
        if (rt.failed)
            return Value::undefined();
    }
    return Value::undefined();
}
Value test_(Vm& vm, Value self, const Value* args, uint32_t argc, bool some, const char* method) {
    SELF(method);
    CALLBACK(method);
    uint32_t len = A->length;
    for (uint32_t k = 0; k < len; k++) {
        if (!present(A, k))
            continue;
        Value v = call3(vm, fn, self_arg, A->items[k], k, A);
        if (rt.failed)
            return Value::undefined();
        if (to_boolean(v) == some)
            return Value::boolean(some);
    }
    return Value::boolean(!some);
}
Value a_some(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return test_(vm, self, args, argc, true, "some");
}
Value a_every(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return test_(vm, self, args, argc, false, "every");
}
Value find_(Vm& vm, Value self, const Value* args, uint32_t argc, bool index, bool last, const char* method) {
    SELF(method);
    CALLBACK(method);
    uint32_t len = A->length;
    for (uint32_t i = 0; i < len; i++) {
        uint32_t k = last ? len - 1 - i : i;
        Value x = at(A, k);
        Value v = call3(vm, fn, self_arg, x, k, A);
        if (rt.failed)
            return Value::undefined();
        if (to_boolean(v))
            return index ? Value::num(k) : x;
    }
    return index ? Value::num(-1) : Value::undefined();
}
Value a_find(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return find_(vm, self, args, argc, false, false, "find");
}
Value a_findindex(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return find_(vm, self, args, argc, true, false, "findIndex");
}
Value a_findlast(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return find_(vm, self, args, argc, false, true, "findLast");
}
Value a_findlastindex(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return find_(vm, self, args, argc, true, true, "findLastIndex");
}
Value reduce_(Vm& vm, Value self, const Value* args, uint32_t argc, bool right, const char* method) {
    SELF(method);
    Value fn = arg(args, argc, 0);
    if (!callable(fn))
        return rt.fail(ErrorKind::type, "Array.prototype.%s callback must be a function", method);
    uint32_t len = A->length, i = 0;
    Value acc;
    auto index = [&](uint32_t n) { return right ? len - 1 - n : n; };
    if (argc >= 2)
        acc = args[1];
    else {
        while (i < len && !present(A, index(i)))
            i++;
        if (i >= len)
            return rt.fail(ErrorKind::type, "Reduce of empty array with no initial value");
        acc = A->items[index(i++)];
    }
    for (; i < len; i++) {
        uint32_t k = index(i);
        if (!present(A, k))
            continue;
        Value cargs[4] = {acc, A->items[k], Value::num(k), val(A)};
        acc = vm.call(fn, Value::undefined(), cargs, 4);
        if (rt.failed)
            return Value::undefined();
    }
    return acc;
}
Value a_reduce(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return reduce_(vm, self, args, argc, false, "reduce");
}
Value a_reduceright(Vm& vm, Value self, const Value* args, uint32_t argc) {
    return reduce_(vm, self, args, argc, true, "reduceRight");
}

Value a_includes(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("includes");
    uint32_t len = A->length;
    if (!len)
        return Value::boolean(false);
    double n = to_integer(rt, arg(args, argc, 1));
    if (rt.failed)
        return Value::undefined();
    uint32_t k =
        n >= 0 ? (n >= len ? len : static_cast<uint32_t>(n)) : (n + len < 0 ? 0 : static_cast<uint32_t>(n + len));
    Value x = arg(args, argc, 0);
    if (x.is_undefined() && k < len)
        for (uint32_t i = 0; i < len; i++)
            if (A->items[i].is_hole())
                return Value::boolean(true);
    for (; k < len; k++)
        if (same_value_zero(at(A, k), x))
            return Value::boolean(true);
    return Value::boolean(false);
}
Value a_indexof(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("indexOf");
    uint32_t len = A->length;
    if (!len)
        return Value::num(-1);
    double n = to_integer(rt, arg(args, argc, 1));
    if (rt.failed)
        return Value::undefined();
    if (n >= len)
        return Value::num(-1);
    uint32_t k = n >= 0 ? static_cast<uint32_t>(n) : (n + len < 0 ? 0 : static_cast<uint32_t>(n + len));
    Value x = arg(args, argc, 0);
    for (; k < len; k++)
        if (present(A, k) && strict_equals(A->items[k], x))
            return Value::num(k);
    return Value::num(-1);
}
Value a_lastindexof(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("lastIndexOf");
    uint32_t len = A->length;
    if (!len)
        return Value::num(-1);
    double n = argc > 1 ? to_integer(rt, args[1]) : static_cast<double>(len) - 1;
    if (rt.failed)
        return Value::undefined();
    double k = n >= 0 ? std::fmin(n, static_cast<double>(len) - 1) : n + len;
    Value x = arg(args, argc, 0);
    for (; k >= 0; k--) {
        uint32_t i = static_cast<uint32_t>(k);
        if (present(A, i) && strict_equals(A->items[i], x))
            return Value::num(i);
    }
    return Value::num(-1);
}

Value a_push(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("push");
    for (uint32_t i = 0; i < argc; i++)
        if (!rt.push(A, args[i]))
            return Value::undefined();
    return Value::num(A->length);
}
Value a_pop(Vm& vm, Value self, const Value*, uint32_t) {
    SELF("pop");
    if (!A->length)
        return Value::undefined();
    Value x = at(A, A->length - 1);
    A->length--;
    return x;
}
Value a_shift(Vm& vm, Value self, const Value*, uint32_t) {
    SELF("shift");
    if (!A->length)
        return Value::undefined();
    Value x = at(A, 0);
    for (uint32_t k = 1; k < A->length; k++)
        A->items[k - 1] = A->items[k];
    A->length--;
    return x;
}
Value a_unshift(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("unshift");
    uint32_t len = A->length;
    if (!rt.set_length(A, len + argc))
        return Value::undefined();
    for (uint32_t k = len; k-- > 0;)
        A->items[k + argc] = A->items[k];
    for (uint32_t i = 0; i < argc; i++)
        A->items[i] = args[i];
    return Value::num(A->length);
}
Value a_splice(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("splice");
    uint32_t len = A->length;
    uint32_t start = relative(to_integer(rt, arg(args, argc, 0)), len);
    uint32_t del;
    if (argc == 0)
        del = 0;
    else if (argc == 1)
        del = len - start;
    else {
        double d = to_integer(rt, args[1]);
        del = static_cast<uint32_t>(std::fmin(std::fmax(d, 0), len - start));
    }
    if (rt.failed)
        return Value::undefined();
    uint32_t items = argc > 2 ? argc - 2 : 0;
    Arr* removed = rt.array(del);
    if (!removed)
        return Value::undefined();
    for (uint32_t k = 0; k < del; k++)
        rt.push(removed, A->items[start + k]);
    uint32_t nlen = len - del + items;
    Value* tail = rt.arena.array<Value>(len - start - del + 1);
    if (!tail)
        return rt.fail(ErrorKind::internal, "out of memory");
    for (uint32_t k = start + del; k < len; k++)
        tail[k - start - del] = A->items[k];
    if (!rt.set_length(A, nlen > len ? nlen : len))
        return Value::undefined();
    for (uint32_t i = 0; i < items; i++)
        A->items[start + i] = args[2 + i];
    for (uint32_t k = 0; k < len - start - del; k++)
        A->items[start + items + k] = tail[k];
    A->length = nlen;
    return val(removed);
}
Value a_slice(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("slice");
    uint32_t len = A->length;
    uint32_t from = relative(to_integer(rt, arg(args, argc, 0)), len);
    Value e = arg(args, argc, 1);
    uint32_t to = e.is_undefined() ? len : relative(to_integer(rt, e), len);
    if (rt.failed)
        return Value::undefined();
    Arr* out = rt.array(to > from ? to - from : 0);
    if (!out)
        return Value::undefined();
    for (uint32_t k = from; k < to; k++)
        rt.push(out, A->items[k]);
    return val(out);
}
Value a_concat(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("concat");
    Arr* out = rt.array(A->length);
    if (!out)
        return Value::undefined();
    for (uint32_t k = 0; k < A->length; k++)
        rt.push(out, A->items[k]);
    for (uint32_t i = 0; i < argc; i++) {
        if (args[i].is(Kind::array)) {
            Arr* b = args[i].as<Arr>();
            for (uint32_t k = 0; k < b->length; k++)
                rt.push(out, b->items[k]);
        } else
            rt.push(out, args[i]);
    }
    return rt.failed ? Value::undefined() : val(out);
}
Value a_join(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("join");
    Value sep = arg(args, argc, 0);
    Str* s = sep.is_undefined() ? rt.a_comma : to_string(rt, sep);
    if (!s)
        return Value::undefined();
    Str* r = join(rt, A, s);
    return r ? val(r) : Value::undefined();
}
Value a_tostring(Vm& vm, Value self, const Value*, uint32_t) {
    if (!self.is(Kind::array)) {
        Str* s = to_string(vm.rt, self);
        return s ? val(s) : Value::undefined();
    }
    Str* r = join(vm.rt, self.as<Arr>(), vm.rt.a_comma);
    return r ? val(r) : Value::undefined();
}
Value a_reverse(Vm& vm, Value self, const Value*, uint32_t) {
    SELF("reverse");
    for (uint32_t i = 0, j = A->length; i + 1 < j; i++, j--) {
        Value t = A->items[i];
        A->items[i] = A->items[j - 1];
        A->items[j - 1] = t;
    }
    return self;
}

struct Sorter {
    Vm& vm;
    Value cmp;
    bool failed = false;
    bool right_first(Value right, Value left) {
        if (failed)
            return false;
        Rt& rt = vm.rt;
        if (cmp.is_undefined()) {
            Str *x = to_string(rt, right), *y = to_string(rt, left);
            if (!x || !y)
                return failed = true, false;
            return x->view() < y->view();
        }
        Value args[2] = {right, left};
        Value r = vm.call(cmp, Value::undefined(), args, 2);
        if (rt.failed)
            return failed = true, false;
        if (r.is_bool())
            return !r.is_true();
        Value lt = less_than(rt, r, Value::num(0), true);
        if (rt.failed)
            return failed = true, false;
        return lt.is_true();
    }
    void merge(Value* dst, const Value* src, uint32_t at, uint32_t end, uint32_t width) {
        uint32_t left = at, left_end = std::min(left + width, end), right = left_end,
                 right_end = std::min(right + width, end);
        for (uint32_t d = left; d < right_end; d++) {
            if (right < right_end) {
                if (left >= left_end) {
                    dst[d] = src[right++];
                    continue;
                }
                if (right_first(src[right], src[left])) {
                    dst[d] = src[right++];
                    continue;
                }
            }
            dst[d] = src[left++];
        }
    }
    void sort(Value* v, Value* tmp, uint32_t n) {
        Value *src = v, *dst = tmp;
        for (uint32_t width = 1; width < n && !failed; width *= 2) {
            for (uint32_t at = 0; at < n; at += 2 * width)
                merge(dst, src, at, n, width);
            Value* t = src;
            src = dst, dst = t;
        }
        if (src != v)
            for (uint32_t i = 0; i < n; i++)
                v[i] = src[i];
    }
};
Value a_sort(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("sort");
    Value cmp = arg(args, argc, 0);
    if (!cmp.is_undefined() && !callable(cmp))
        return rt.fail(ErrorKind::type, "The comparison function must be either a function or undefined");
    uint32_t len = A->length, n = 0, undefs = 0;
    Value *vals = rt.arena.array<Value>(len + 1), *tmp = rt.arena.array<Value>(len + 1);
    if (!vals || !tmp)
        return rt.fail(ErrorKind::internal, "out of memory");
    for (uint32_t k = 0; k < len; k++) {
        if (A->items[k].is_hole())
            continue;
        if (A->items[k].is_undefined())
            undefs++;
        else
            vals[n++] = A->items[k];
    }
    Sorter s{vm, cmp};
    s.sort(vals, tmp, n);
    if (rt.failed)
        return Value::undefined();
    uint32_t k = 0;
    for (uint32_t i = 0; i < n; i++)
        A->items[k++] = vals[i];
    for (uint32_t i = 0; i < undefs; i++)
        A->items[k++] = Value::undefined();
    while (k < len)
        A->items[k++] = Value::hole();
    return self;
}
Value a_at(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("at");
    double k = to_integer(rt, arg(args, argc, 0));
    if (rt.failed)
        return Value::undefined();
    if (k < 0)
        k += A->length;
    if (k < 0 || k >= A->length)
        return Value::undefined();
    return at(A, static_cast<uint32_t>(k));
}
Value a_fill(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("fill");
    uint32_t len = A->length;
    uint32_t from = relative(to_integer(rt, arg(args, argc, 1)), len);
    Value e = arg(args, argc, 2);
    uint32_t to = e.is_undefined() ? len : relative(to_integer(rt, e), len);
    if (rt.failed)
        return Value::undefined();
    for (uint32_t k = from; k < to; k++)
        A->items[k] = arg(args, argc, 0);
    return self;
}
bool flatten(Rt& rt, Arr* out, Arr* src, double depth) {
    for (uint32_t k = 0; k < src->length; k++) {
        Value x = src->items[k];
        if (x.is_hole())
            continue;
        if (depth > 0 && x.is(Kind::array)) {
            if (!flatten(rt, out, x.as<Arr>(), depth - 1))
                return false;
        } else if (!rt.push(out, x))
            return false;
    }
    return true;
}
Value a_flat(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("flat");
    Value d = arg(args, argc, 0);
    double depth = d.is_undefined() ? 1 : to_integer(rt, d);
    Arr* out = rt.array(A->length);
    if (!out || !flatten(rt, out, A, depth > 64 ? 64 : depth))
        return Value::undefined();
    return val(out);
}

Value a_flatmap(Vm& vm, Value self, const Value* args, uint32_t argc) {
    SELF("flatMap");
    Value fn = arg(args, argc, 0);
    if (!callable(fn))
        return rt.fail(ErrorKind::type, "Array.prototype.flatMap callback must be a function");
    Arr* out = rt.array(A->length);
    if (!out)
        return Value::undefined();
    for (uint32_t k = 0; k < A->length; k++) {
        if (A->items[k].is_hole())
            continue;
        Value a[3] = {A->items[k], Value::num(k), self};
        Value r = vm.call(fn, arg(args, argc, 1), a, 3);
        if (rt.failed)
            return Value::undefined();
        if (r.is(Kind::array)) {
            Arr* ra = r.as<Arr>();
            for (uint32_t j = 0; j < ra->length; j++)
                if (!ra->items[j].is_hole() && !rt.push(out, ra->items[j]))
                    return Value::undefined();
        } else if (!rt.push(out, r)) {
            return Value::undefined();
        }
    }
    return val(out);
}

Value a_from(Vm& vm, Value, const Value* args, uint32_t argc) {
    Rt& rt = vm.rt;
    Value src = arg(args, argc, 0), fn = arg(args, argc, 1);
    if (!fn.is_undefined() && !callable(fn))
        return rt.fail(ErrorKind::type, "Array.from requires that the second argument, when provided, be a function");
    Arr* out = rt.array(0);
    if (!out)
        return Value::undefined();
    auto add = [&](Value x, uint32_t k) {
        if (!fn.is_undefined()) {
            Value cargs[2] = {x, Value::num(k)};
            x = vm.call(fn, Value::undefined(), cargs, 2);
            if (rt.failed)
                return false;
        }
        return rt.push(out, x);
    };
    if (src.is(Kind::array)) {
        Arr* a = src.as<Arr>();
        for (uint32_t k = 0; k < a->length; k++)
            if (!add(at(a, k), k))
                return Value::undefined();
    } else if (src.is(Kind::string)) {
        Str* s = src.as<Str>();
        uint32_t k = 0;
        for (uint32_t i = 0; i < s->length; k++) {
            uint32_t n = s->units[i] >= 0xD800 && s->units[i] <= 0xDBFF && i + 1 < s->length
                    && s->units[i + 1] >= 0xDC00 && s->units[i + 1] <= 0xDFFF
                ? 2
                : 1;
            Str* one = rt.str({&s->units[i], n});
            if (!one || !add(val(one), k))
                return Value::undefined();
            i += n;
        }
    } else if (src.is(Kind::set)) {
        uint32_t at = 0, k = 0;
        Value x;
        while (set_step(rt, src, at, x))
            if (!add(x, k++))
                return Value::undefined();
    } else if (src.is_nullish() || src.is_hole()) {
        return rt.fail(ErrorKind::type, "Array.from requires an array-like object - not null or undefined");
    } else if (src.is(Kind::object)) {
        double len = to_integer(rt, get(rt, src, rt.a_length));
        if (rt.failed)
            return Value::undefined();
        for (uint32_t k = 0; k < len && k < 0x1000000; k++) {
            Value x = get(rt, src, Value::num(k));
            if (rt.failed || !add(x, k))
                return Value::undefined();
        }
    }
    return val(out);
}
Value a_of(Vm& vm, Value, const Value* args, uint32_t argc) {
    Arr* out = vm.rt.array(argc);
    for (uint32_t i = 0; out && i < argc; i++)
        vm.rt.push(out, args[i]);
    return out ? val(out) : Value::undefined();
}

}

void install_array(Rt& rt, Obj* p, Obj* ctor) noexcept {
    struct M {
        const char* name;
        NativeFn fn;
        uint32_t len;
    };
    static constexpr M k[] = {{"map", a_map, 1},
                              {"filter", a_filter, 1},
                              {"forEach", a_foreach, 1},
                              {"some", a_some, 1},
                              {"every", a_every, 1},
                              {"find", a_find, 1},
                              {"findIndex", a_findindex, 1},
                              {"findLast", a_findlast, 1},
                              {"findLastIndex", a_findlastindex, 1},
                              {"reduce", a_reduce, 1},
                              {"reduceRight", a_reduceright, 1},
                              {"includes", a_includes, 1},
                              {"indexOf", a_indexof, 1},
                              {"lastIndexOf", a_lastindexof, 1},
                              {"push", a_push, 1},
                              {"pop", a_pop, 0},
                              {"shift", a_shift, 0},
                              {"unshift", a_unshift, 1},
                              {"splice", a_splice, 2},
                              {"slice", a_slice, 2},
                              {"concat", a_concat, 1},
                              {"join", a_join, 1},
                              {"toString", a_tostring, 0},
                              {"reverse", a_reverse, 0},
                              {"sort", a_sort, 1},
                              {"at", a_at, 1},
                              {"fill", a_fill, 1},
                              {"flatMap", a_flatmap, 1},
                              {"flat", a_flat, 0}};
    for (const M& m : k)
        def(rt, p, m.name, m.fn, m.len);
    def(rt, ctor, "from", a_from, 1);
    def(rt, ctor, "of", a_of, 0);
}

}
