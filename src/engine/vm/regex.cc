// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/vm/regex.h"

#include <cstdlib>
#include <cstring>

namespace rx::engine::vm::re {

char16_t os_upper_unit(char16_t c) noexcept;

namespace {

using sv16 = std::u16string_view;

char16_t* g_canon = nullptr;

}

char16_t canonicalize(char16_t c) noexcept {
    if (c < 0x80)
        return c >= 'a' && c <= 'z' ? static_cast<char16_t>(c - 32) : c;
    if (!g_canon) {
        auto* t = static_cast<char16_t*>(std::malloc(sizeof(char16_t) * 65536));
        if (!t)
            return c;
        for (uint32_t u = 0; u < 65536; u++) {
            char16_t x = static_cast<char16_t>(u);
            if (u < 0x80)
                t[u] = u >= 'a' && u <= 'z' ? static_cast<char16_t>(u - 32) : x;
            else if (u >= 0xD800 && u <= 0xDFFF)
                t[u] = x;
            else {
                char16_t up = os_upper_unit(x);
                t[u] = up < 0x80 ? x : up;
            }
        }
        g_canon = t;
    }
    return g_canon[c];
}

namespace {

enum class N : uint8_t { empty, ch, any, cls, seq, alt, group, quant, bol, eol, wordb, nwordb, look, backref };

struct Range {
    char16_t lo, hi;
};
struct Class {
    Range* ranges;
    uint32_t n;
    bool negated;
};
struct Node {
    N kind;
    bool greedy, negative, behind, capture;
    char16_t ch;
    int32_t group;
    uint32_t min, max;
    Class* cls;
    Node* a;
    Node* first;
    Node* next;
};

constexpr uint32_t k_inf = 0xFFFFFFFFu;

struct Parser {
    Parser(sv16 pattern, uint8_t f, Arena& a) : p(pattern), flags(f), arena(a) {}
    sv16 p;
    size_t i = 0;
    uint8_t flags;
    Arena& arena;
    bool failed = false;
    std::string_view error;
    uint32_t groups = 0, total_groups = 0;
    bool named = false;
    List<sv16> names;
    int depth = 0;

    bool fail(const char* m) {
        if (!failed)
            failed = true, error = m;
        return false;
    }
    bool more() const { return i < p.size(); }
    char16_t peek(size_t k = 0) const { return i + k < p.size() ? p[i + k] : 0; }
    Node* node(N k) {
        Node* n = arena.make<Node>();
        if (!n)
            return fail("out of memory"), nullptr;
        n->kind = k;
        return n;
    }

    void count_groups() {
        bool in_class = false;
        (void)names.push(arena, sv16{});
        for (size_t k = 0; k < p.size(); k++) {
            char16_t c = p[k];
            if (c == '\\') {
                k++;
                continue;
            }
            if (in_class) {
                if (c == ']')
                    in_class = false;
                continue;
            }
            if (c == '[') {
                in_class = true;
                continue;
            }
            if (c != '(')
                continue;
            if (k + 1 < p.size() && p[k + 1] == '?') {
                if (k + 2 < p.size() && p[k + 2] == '<' && k + 3 < p.size() && p[k + 3] != '=' && p[k + 3] != '!') {
                    total_groups++, named = true;
                    size_t e = k + 3;
                    while (e < p.size() && p[e] != '>')
                        e++;
                    (void)names.push(arena, p.substr(k + 3, e - (k + 3)));
                }
                continue;
            }
            total_groups++;
            (void)names.push(arena, sv16{});
        }
    }

    Node* disjunction() {
        if (++depth > 200)
            return fail("regex nested too deeply"), nullptr;
        Node *alt = nullptr, **tail = nullptr;
        Node* seq = alternative();
        if (!seq)
            return nullptr;
        while (more() && peek() == '|') {
            i++;
            if (!alt) {
                alt = node(N::alt);
                if (!alt)
                    return nullptr;
                alt->first = seq;
                tail = &seq->next;
            }
            Node* s = alternative();
            if (!s)
                return nullptr;
            *tail = s;
            tail = &s->next;
        }
        depth--;
        return alt ? alt : seq;
    }
    Node* alternative() {
        Node* seq = node(N::seq);
        if (!seq)
            return nullptr;
        Node** tail = &seq->first;
        while (more() && peek() != '|' && peek() != ')') {
            Node* t = term();
            if (!t)
                return nullptr;
            *tail = t;
            tail = &t->next;
        }
        return seq;
    }
    bool braced(uint32_t& lo, uint32_t& hi, size_t& end) const {
        size_t k = i + 1;
        if (k >= p.size() || p[k] < '0' || p[k] > '9')
            return false;
        uint64_t a = 0, b;
        while (k < p.size() && p[k] >= '0' && p[k] <= '9')
            a = std::min<uint64_t>(a * 10 + (p[k++] - '0'), k_inf);
        if (k < p.size() && p[k] == ',') {
            k++;
            if (k < p.size() && p[k] >= '0' && p[k] <= '9') {
                b = 0;
                while (k < p.size() && p[k] >= '0' && p[k] <= '9')
                    b = std::min<uint64_t>(b * 10 + (p[k++] - '0'), k_inf);
            } else
                b = k_inf;
        } else
            b = a;
        if (k >= p.size() || p[k] != '}')
            return false;
        lo = static_cast<uint32_t>(a), hi = static_cast<uint32_t>(b), end = k + 1;
        return true;
    }
    Node* term() {
        char16_t c = peek();
        Node* atom = nullptr;
        bool quantifiable = true;
        if (c == '^') {
            i++;
            return node(N::bol);
        }
        if (c == '$') {
            i++;
            return node(N::eol);
        }
        if (c == '\\' && (peek(1) == 'b' || peek(1) == 'B')) {
            i += 2;
            return node(p[i - 1] == 'b' ? N::wordb : N::nwordb);
        }
        if (c == '(' && peek(1) == '?'
            && (peek(2) == '=' || peek(2) == '!' || (peek(2) == '<' && (peek(3) == '=' || peek(3) == '!')))) {
            bool behind = peek(2) == '<';
            bool neg = (behind ? peek(3) : peek(2)) == '!';
            i += behind ? 4 : 3;
            Node* d = disjunction();
            if (!d)
                return nullptr;
            if (peek() != ')')
                return fail("a regex's ( has no )"), nullptr;
            i++;
            atom = node(N::look);
            if (!atom)
                return nullptr;
            atom->a = d, atom->negative = neg, atom->behind = behind;
            quantifiable = !behind;
        } else {
            atom = this->atom();
            if (!atom)
                return nullptr;
        }
        uint32_t lo = 0, hi = 0;
        size_t end = 0;
        c = peek();
        if (c == '*')
            lo = 0, hi = k_inf, end = i + 1;
        else if (c == '+')
            lo = 1, hi = k_inf, end = i + 1;
        else if (c == '?')
            lo = 0, hi = 1, end = i + 1;
        else if (c == '{' && braced(lo, hi, end)) {
        } else
            return atom;
        if (!quantifiable)
            return fail("nothing to repeat"), nullptr;
        if (hi < lo)
            return fail("numbers out of order in {} quantifier"), nullptr;
        i = end;
        Node* q = node(N::quant);
        if (!q)
            return nullptr;
        q->a = atom, q->min = lo, q->max = hi, q->greedy = true;
        if (peek() == '?')
            q->greedy = false, i++;
        return q;
    }

    Node* chr(char16_t c) {
        Node* n = node(N::ch);
        if (n)
            n->ch = flags & f_ignore_case ? canonicalize(c) : c;
        return n;
    }
    Node* atom() {
        char16_t c = peek();
        switch (c) {
        case '.': {
            i++;
            return node(N::any);
        }
        case '(': {
            i++;
            Node* g = node(N::group);
            if (!g)
                return nullptr;
            if (peek() == '?') {
                if (peek(1) == ':') {
                    i += 2;
                    g->capture = false;
                } else if (peek(1) == '<') {
                    i += 2;
                    size_t s = i;
                    while (more() && peek() != '>') {
                        char16_t x = peek();
                        bool ok = (x >= 'a' && x <= 'z') || (x >= 'A' && x <= 'Z') || x == '_' || x == '$'
                            || (i > s && x >= '0' && x <= '9') || x >= 0x80;
                        if (!ok)
                            return fail("invalid group name"), nullptr;
                        i++;
                    }
                    if (!more() || i == s)
                        return fail("invalid group name"), nullptr;
                    sv16 name = p.substr(s, i - s);
                    for (uint32_t k = 1; k <= groups; k++)
                        if (names[k] == name)
                            return fail("duplicate group name"), nullptr;
                    i++;
                    g->capture = true;
                    g->group = static_cast<int32_t>(++groups);
                } else
                    return fail("invalid group"), nullptr;
            } else {
                g->capture = true;
                g->group = static_cast<int32_t>(++groups);
            }
            Node* d = disjunction();
            if (!d)
                return nullptr;
            if (peek() != ')')
                return fail("missing )"), nullptr;
            i++;
            g->a = d;
            return g;
        }
        case ')':
            return fail("unmatched )"), nullptr;
        case '[':
            return klass();
        case '*':
        case '+':
        case '?':
            return fail("nothing to repeat"), nullptr;
        case '{': {
            uint32_t lo, hi;
            size_t end;
            if (braced(lo, hi, end))
                return fail("nothing to repeat"), nullptr;
            i++;
            return chr('{');
        }
        case '\\':
            return escape();
        default:
            i++;
            return chr(c);
        }
    }
    Node* escape() {
        i++;
        if (!more())
            return fail("\\ at end of pattern"), nullptr;
        char16_t c = p[i];
        if (c >= '1' && c <= '9') {
            size_t s = i;
            uint64_t n = 0;
            while (more() && peek() >= '0' && peek() <= '9')
                n = std::min<uint64_t>(n * 10 + (p[i++] - '0'), k_inf);
            if (n <= total_groups) {
                Node* b = node(N::backref);
                if (b)
                    b->group = static_cast<int32_t>(n);
                return b;
            }
            i = s;
            if (c >= '8') {
                i++;
                return chr(c);
            }
            return chr(octal());
        }
        if (c == 'k' && named) {
            i++;
            if (peek() != '<')
                return fail("invalid named reference"), nullptr;
            i++;
            size_t s = i;
            while (more() && peek() != '>')
                i++;
            if (!more())
                return fail("invalid named reference"), nullptr;
            sv16 name = p.substr(s, i - s);
            i++;
            for (uint32_t k = 1; k <= total_groups; k++)
                if (names[k] == name) {
                    Node* b = node(N::backref);
                    if (b)
                        b->group = static_cast<int32_t>(k);
                    return b;
                }
            return fail("invalid named reference"), nullptr;
        }
        Class* k = class_escape(c);
        if (k) {
            i++;
            Node* n = node(N::cls);
            if (n)
                n->cls = k;
            return n;
        }
        if (failed)
            return nullptr;
        char16_t v;
        if (!char_escape(v, false))
            return nullptr;
        return chr(v);
    }
    char16_t octal() {
        uint32_t v = static_cast<uint32_t>(p[i++] - '0');
        if (more() && peek() >= '0' && peek() <= '7') {
            v = v * 8 + static_cast<uint32_t>(p[i++] - '0');
            if (v < 32 && more() && peek() >= '0' && peek() <= '7')
                v = v * 8 + static_cast<uint32_t>(p[i++] - '0');
        }
        return static_cast<char16_t>(v);
    }
    static int hexv(char16_t c) {
        if (c >= '0' && c <= '9')
            return c - '0';
        if ((c | 0x20) >= 'a' && (c | 0x20) <= 'f')
            return (c | 0x20) - 'a' + 10;
        return -1;
    }
    bool char_escape(char16_t& v, bool in_class) {
        char16_t c = p[i];
        switch (c) {
        case 'f':
            v = '\f';
            i++;
            return true;
        case 'n':
            v = '\n';
            i++;
            return true;
        case 'r':
            v = '\r';
            i++;
            return true;
        case 't':
            v = '\t';
            i++;
            return true;
        case 'v':
            v = '\v';
            i++;
            return true;
        case 'b':
            if (in_class) {
                v = '\b';
                i++;
                return true;
            }
            break;
        case 'c': {
            char16_t l = peek(1);
            if ((l | 0x20) >= 'a' && (l | 0x20) <= 'z') {
                v = static_cast<char16_t>(l % 32);
                i += 2;
                return true;
            }
            if (in_class && ((l >= '0' && l <= '9') || l == '_')) {
                v = static_cast<char16_t>(l % 32);
                i += 2;
                return true;
            }
            v = '\\';
            return true;
        }
        case '0':
            if (!(peek(1) >= '0' && peek(1) <= '9')) {
                v = 0;
                i++;
                return true;
            }
            v = octal();
            return true;
        case 'x':
            if (hexv(peek(1)) >= 0 && hexv(peek(2)) >= 0) {
                v = static_cast<char16_t>(hexv(peek(1)) * 16 + hexv(peek(2)));
                i += 3;
                return true;
            }
            v = 'x';
            i++;
            return true;
        case 'u':
            if (hexv(peek(1)) >= 0 && hexv(peek(2)) >= 0 && hexv(peek(3)) >= 0 && hexv(peek(4)) >= 0) {
                v = static_cast<char16_t>(((hexv(peek(1)) * 16 + hexv(peek(2))) * 16 + hexv(peek(3))) * 16
                                          + hexv(peek(4)));
                i += 5;
                return true;
            }
            v = 'u';
            i++;
            return true;
        default:
            if (in_class && c >= '1' && c <= '7') {
                v = octal();
                return true;
            }
            break;
        }
        v = c;
        i++;
        return true;
    }

    List<Range> buf;
    void add(char16_t lo, char16_t hi) { (void)buf.push(arena, Range{lo, hi}); }
    void add_escape(char16_t c) {
        static constexpr Range k_d[] = {{'0', '9'}};
        static constexpr Range k_w[] = {{'0', '9'}, {'A', 'Z'}, {'_', '_'}, {'a', 'z'}};
        static constexpr Range k_s[] = {{0x09, 0x0D},     {0x20, 0x20},     {0xA0, 0xA0},     {0x1680, 0x1680},
                                        {0x2000, 0x200A}, {0x2028, 0x2029}, {0x202F, 0x202F}, {0x205F, 0x205F},
                                        {0x3000, 0x3000}, {0xFEFF, 0xFEFF}};
        const Range* r;
        uint32_t n;
        char16_t lower = c | 0x20;
        if (lower == 'd')
            r = k_d, n = 1;
        else if (lower == 'w')
            r = k_w, n = 4;
        else
            r = k_s, n = 10;
        if (c == lower) {
            for (uint32_t k = 0; k < n; k++)
                add(r[k].lo, r[k].hi);
            return;
        }
        uint32_t lo = 0;
        for (uint32_t k = 0; k < n; k++) {
            if (r[k].lo > lo)
                add(static_cast<char16_t>(lo), static_cast<char16_t>(r[k].lo - 1));
            lo = r[k].hi + 1u;
        }
        if (lo <= 0xFFFF)
            add(static_cast<char16_t>(lo), 0xFFFF);
    }
    Class* finish(bool negated) {
        Class* k = arena.make<Class>();
        if (!k)
            return fail("out of memory"), nullptr;
        k->n = buf.size;
        k->ranges = arena.array<Range>(buf.size ? buf.size : 1);
        if (!k->ranges)
            return fail("out of memory"), nullptr;
        for (uint32_t q = 0; q < buf.size; q++)
            k->ranges[q] = buf[q];
        k->negated = negated;
        buf = {};
        return k;
    }
    Class* class_escape(char16_t c) {
        char16_t lower = c | 0x20;
        if (lower != 'd' && lower != 'w' && lower != 's')
            return nullptr;
        if (c != lower && c != (lower ^ 0x20))
            return nullptr;
        buf = {};
        add_escape(c);
        return finish(false);
    }
    Node* klass() {
        i++;
        bool negated = false;
        if (peek() == '^')
            negated = true, i++;
        buf = {};
        auto atom = [&](char16_t& v, bool& is_set) -> bool {
            is_set = false;
            char16_t c = p[i];
            if (c != '\\') {
                v = c;
                i++;
                return true;
            }
            i++;
            if (!more())
                return fail("\\ at end of pattern");
            char16_t e = p[i];
            char16_t lower = e | 0x20;
            if ((lower == 'd' || lower == 'w' || lower == 's') && (e == lower || e == (lower ^ 0x20))) {
                i++;
                add_escape(e);
                is_set = true;
                return true;
            }
            if (e == '-') {
                v = '-';
                i++;
                return true;
            }
            return char_escape(v, true);
        };
        while (more() && peek() != ']') {
            char16_t a, b;
            bool aset, bset;
            if (!atom(a, aset))
                return nullptr;
            if (peek() == '-' && peek(1) != ']' && i + 1 < p.size()) {
                i++;
                if (!atom(b, bset))
                    return nullptr;
                if (aset || bset) {
                    if (!aset)
                        add(a, a);
                    add('-', '-');
                    if (!bset)
                        add(b, b);
                    continue;
                }
                if (a > b)
                    return fail("range out of order in character class"), nullptr;
                add(a, b);
                continue;
            }
            if (!aset)
                add(a, a);
        }
        if (!more())
            return fail("missing terminating ] for character class"), nullptr;
        i++;
        Class* k = finish(negated);
        if (!k)
            return nullptr;
        Node* n = node(N::cls);
        if (n)
            n->cls = k;
        return n;
    }
};

enum class Op : uint8_t {
    ch,
    any,
    anyall,
    cls,
    bol,
    eol,
    wordb,
    nwordb,
    split,
    jmp,
    save,
    reset,
    mark,
    progress,
    backref,
    look,
    match
};
struct Ins {
    Op op;
    bool back;
    bool neg;
    uint32_t a, b;
    const Class* cls;
};

}

struct Program {
    Ins* ins;
    uint32_t n;
    uint32_t n_regs;
    uint8_t flags;
};

namespace {

struct Gen {
    Gen(Arena& a, uint8_t f) : arena(a), flags(f) {}
    Arena& arena;
    uint8_t flags;
    List<Ins> ins;
    uint32_t regs = 0;
    bool failed = false;

    uint32_t emit(Op op, uint32_t a = 0, uint32_t b = 0, bool back = false, const Class* cls = nullptr) {
        if (ins.size > 200000) {
            failed = true;
            return 0;
        }
        (void)ins.push(arena, Ins{op, back, false, a, b, cls});
        return ins.size - 1;
    }
    static void groups_in(const Node* n, int32_t& lo, int32_t& hi) {
        if (!n)
            return;
        if (n->kind == N::group && n->capture)
            lo = lo < 0 || n->group < lo ? n->group : lo, hi = n->group > hi ? n->group : hi;
        groups_in(n->a, lo, hi);
        for (const Node* c = n->first; c; c = c->next)
            groups_in(c, lo, hi);
    }
    void gen(const Node* n, bool back) {
        if (failed || !n)
            return;
        switch (n->kind) {
        case N::empty:
            return;
        case N::ch:
            emit(Op::ch, n->ch, 0, back);
            return;
        case N::any:
            emit(flags & f_dot_all ? Op::anyall : Op::any, 0, 0, back);
            return;
        case N::cls:
            emit(Op::cls, 0, 0, back, n->cls);
            return;
        case N::bol:
            emit(Op::bol);
            return;
        case N::eol:
            emit(Op::eol);
            return;
        case N::wordb:
            emit(Op::wordb);
            return;
        case N::nwordb:
            emit(Op::nwordb);
            return;
        case N::backref:
            emit(Op::backref, static_cast<uint32_t>(n->group), 0, back);
            return;
        case N::seq: {
            if (!back) {
                for (const Node* c = n->first; c; c = c->next)
                    gen(c, back);
                return;
            }
            List<const Node*> items;
            for (const Node* c = n->first; c; c = c->next)
                (void)items.push(arena, c);
            for (uint32_t q = items.size; q-- > 0;)
                gen(items[q], back);
            return;
        }
        case N::alt: {
            List<uint32_t> ends;
            for (const Node* c = n->first; c; c = c->next) {
                if (c->next) {
                    uint32_t s = emit(Op::split);
                    ins[s].a = ins.size;
                    gen(c, back);
                    (void)ends.push(arena, emit(Op::jmp));
                    ins[s].b = ins.size;
                } else
                    gen(c, back);
            }
            for (uint32_t e : ends)
                ins[e].a = ins.size;
            return;
        }
        case N::group:
            if (!n->capture)
                return gen(n->a, back);
            emit(Op::save, static_cast<uint32_t>(n->group) * 2 + (back ? 1 : 0));
            gen(n->a, back);
            emit(Op::save, static_cast<uint32_t>(n->group) * 2 + (back ? 0 : 1));
            return;
        case N::look: {
            uint32_t at = emit(Op::look);
            ins[at].neg = n->negative;
            ins[at].a = ins.size;
            gen(n->a, n->behind);
            emit(Op::match);
            ins[at].b = ins.size;
            return;
        }
        case N::quant: {
            int32_t lo = -1, hi = -1;
            groups_in(n->a, lo, hi);
            auto body = [&](bool check) {
                uint32_t r = 0;
                if (check)
                    r = regs++, emit(Op::mark, r);
                if (lo >= 0)
                    emit(Op::reset, static_cast<uint32_t>(lo) * 2, static_cast<uint32_t>(hi) * 2 + 1);
                gen(n->a, back);
                if (check)
                    emit(Op::progress, r);
            };
            uint32_t min = n->min, max = n->max;
            if (min > 1000 || (max != k_inf && max > 1000)) {
                failed = true;
                return;
            }
            for (uint32_t k = 0; k < min; k++)
                body(false);
            if (max == k_inf) {
                uint32_t top = emit(Op::split);
                if (n->greedy)
                    ins[top].a = ins.size;
                else
                    ins[top].b = ins.size;
                body(true);
                emit(Op::jmp, top);
                if (n->greedy)
                    ins[top].b = ins.size;
                else
                    ins[top].a = ins.size;
                return;
            }
            List<uint32_t> outs;
            for (uint32_t k = min; k < max; k++) {
                uint32_t s = emit(Op::split);
                if (n->greedy)
                    ins[s].a = ins.size;
                else
                    ins[s].b = ins.size;
                (void)outs.push(arena, s);
                body(true);
            }
            for (uint32_t s : outs) {
                if (n->greedy)
                    ins[s].b = ins.size;
                else
                    ins[s].a = ins.size;
            }
            return;
        }
        }
    }
};

bool line_terminator(char16_t c) {
    return c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029;
}
bool word(char16_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
}

bool in_class(const Class* k, char16_t c) {
    for (uint32_t q = 0; q < k->n; q++)
        if (c >= k->ranges[q].lo && c <= k->ranges[q].hi)
            return true;
    return false;
}
bool class_matches(const Class* k, char16_t c, bool icase) {
    bool hit = in_class(k, c);
    if (!hit && icase) {
        char16_t cc = canonicalize(c);
        if (cc != c && in_class(k, cc))
            hit = true;
        if (!hit) {
            for (uint32_t q = 0; q < k->n && !hit; q++) {
                const Range& r = k->ranges[q];
                if (r.hi - r.lo > 0x3000) {
                    if (cc < 0x80) {
                        char16_t lo = cc >= 'A' && cc <= 'Z' ? static_cast<char16_t>(cc + 32) : cc;
                        hit = (lo >= r.lo && lo <= r.hi);
                    } else
                        for (uint32_t u = r.lo; u <= r.hi && !hit; u++)
                            hit = canonicalize(static_cast<char16_t>(u)) == cc;
                    continue;
                }
                for (uint32_t u = r.lo; u <= r.hi && !hit; u++)
                    hit = canonicalize(static_cast<char16_t>(u)) == cc;
            }
        }
    }
    return hit != k->negated;
}

struct Entry {
    enum Kind : uint8_t { branch, cap, reg } kind;
    uint32_t pc;
    int32_t value;
};

struct Matcher {
    const Program& prog;
    sv16 s;
    int32_t* caps;
    uint32_t n_caps;
    int64_t& steps;
    bool budget_out = false;

    bool run(uint32_t pc, int32_t& pos_io, int depth) {
        if (depth > 64)
            return false;
        Entry local[256];
        Entry* stack = local;
        uint32_t sp = 0, cap = 256;
        int32_t regs_local[64];
        int32_t* regs =
            prog.n_regs <= 64 ? regs_local : static_cast<int32_t*>(std::malloc(sizeof(int32_t) * prog.n_regs));
        if (!regs)
            return false;
        for (uint32_t r = 0; r < prog.n_regs; r++)
            regs[r] = -1;
        bool icase = prog.flags & f_ignore_case, multiline = prog.flags & f_multiline;
        int32_t pos = pos_io;
        bool ok = false;
        auto push = [&](Entry e) -> bool {
            if (sp == cap) {
                uint32_t ncap = cap * 2;
                Entry* bigger = static_cast<Entry*>(std::malloc(sizeof(Entry) * ncap));
                if (!bigger)
                    return false;
                std::memcpy(bigger, stack, sizeof(Entry) * sp);
                if (stack != local)
                    std::free(stack);
                stack = bigger, cap = ncap;
            }
            stack[sp++] = e;
            return true;
        };
        auto backtrack = [&]() -> bool {
            while (sp) {
                Entry e = stack[--sp];
                if (e.kind == Entry::cap)
                    caps[e.pc] = e.value;
                else if (e.kind == Entry::reg)
                    regs[e.pc] = e.value;
                else {
                    pc = e.pc;
                    pos = e.value;
                    return true;
                }
            }
            return false;
        };
        int32_t len = static_cast<int32_t>(s.size());
        for (;;) {
            if (--steps <= 0) {
                budget_out = true;
                break;
            }
            const Ins& in = prog.ins[pc];
            bool good = true;
            switch (in.op) {
            case Op::ch:
            case Op::any:
            case Op::anyall:
            case Op::cls: {
                int32_t at = in.back ? pos - 1 : pos;
                if (at < 0 || at >= len) {
                    good = false;
                    break;
                }
                char16_t c = s[static_cast<size_t>(at)];
                if (in.op == Op::ch)
                    good = (icase ? canonicalize(c) : c) == in.a;
                else if (in.op == Op::any)
                    good = !line_terminator(c);
                else if (in.op == Op::cls)
                    good = class_matches(in.cls, c, icase);
                if (good)
                    pos += in.back ? -1 : 1, pc++;
                break;
            }
            case Op::bol:
                good = pos == 0 || (multiline && line_terminator(s[static_cast<size_t>(pos - 1)]));
                pc++;
                break;
            case Op::eol:
                good = pos == len || (multiline && line_terminator(s[static_cast<size_t>(pos)]));
                pc++;
                break;
            case Op::wordb:
            case Op::nwordb: {
                bool a = pos > 0 && word(s[static_cast<size_t>(pos - 1)]),
                     b = pos < len && word(s[static_cast<size_t>(pos)]);
                good = (a != b) == (in.op == Op::wordb);
                pc++;
                break;
            }
            case Op::split:
                if (!push({Entry::branch, in.b, pos})) {
                    good = false;
                    break;
                }
                pc = in.a;
                break;
            case Op::jmp:
                pc = in.a;
                break;
            case Op::save:
                if (in.a < n_caps) {
                    if (!push({Entry::cap, in.a, caps[in.a]})) {
                        good = false;
                        break;
                    }
                    caps[in.a] = pos;
                }
                pc++;
                break;
            case Op::reset:
                for (uint32_t q = in.a; q <= in.b && q < n_caps; q++) {
                    if (caps[q] != -1 && !push({Entry::cap, q, caps[q]})) {
                        good = false;
                        break;
                    }
                    caps[q] = -1;
                }
                pc++;
                break;
            case Op::mark:
                if (!push({Entry::reg, in.a, regs[in.a]})) {
                    good = false;
                    break;
                }
                regs[in.a] = pos;
                pc++;
                break;
            case Op::progress:
                good = regs[in.a] != pos;
                pc++;
                break;
            case Op::backref: {
                int32_t a = caps[in.a * 2], b = caps[in.a * 2 + 1];
                pc++;
                if (a < 0 || b < 0)
                    break;
                int32_t n = b - a;
                if (in.back) {
                    if (pos - n < 0) {
                        good = false;
                        break;
                    }
                    for (int32_t k = 0; k < n && good; k++) {
                        char16_t x = s[static_cast<size_t>(a + k)], y = s[static_cast<size_t>(pos - n + k)];
                        good = icase ? canonicalize(x) == canonicalize(y) : x == y;
                    }
                    if (good)
                        pos -= n;
                } else {
                    if (pos + n > len) {
                        good = false;
                        break;
                    }
                    for (int32_t k = 0; k < n && good; k++) {
                        char16_t x = s[static_cast<size_t>(a + k)], y = s[static_cast<size_t>(pos + k)];
                        good = icase ? canonicalize(x) == canonicalize(y) : x == y;
                    }
                    if (good)
                        pos += n;
                }
                break;
            }
            case Op::look: {
                int32_t saved[64];
                uint32_t keep = n_caps < 64 ? n_caps : 64;
                for (uint32_t q = 0; q < keep; q++)
                    saved[q] = caps[q];
                int32_t p = pos;
                bool hit = run(in.a, p, depth + 1);
                if (budget_out) {
                    good = false;
                    break;
                }
                if (in.neg) {
                    for (uint32_t q = 0; q < keep; q++)
                        caps[q] = saved[q];
                    good = !hit;
                } else if (hit) {
                    for (uint32_t q = 0; q < keep && good; q++)
                        if (caps[q] != saved[q])
                            good = push({Entry::cap, q, saved[q]});
                } else
                    good = false;
                pc = in.b;
                break;
            }
            case Op::match:
                ok = true;
                break;
            }
            if (ok || budget_out)
                break;
            if (!good && !backtrack())
                break;
        }
        if (stack != local)
            std::free(stack);
        if (regs != regs_local)
            std::free(regs);
        if (ok)
            pos_io = pos;
        return ok;
    }
};

}

bool parse_flags(std::u16string_view text, uint8_t& flags) noexcept {
    flags = 0;
    for (char16_t c : text) {
        uint8_t f = c == 'g' ? f_global
            : c == 'i'       ? f_ignore_case
            : c == 'm'       ? f_multiline
            : c == 's'       ? f_dot_all
            : c == 'y'       ? f_sticky
            : c == 'd'       ? f_indices
                             : 0;
        if (!f || (flags & f))
            return false;
        flags |= f;
    }
    return true;
}

bool compile(std::u16string_view pattern, uint8_t flags, Arena& arena, Compiled& out, Error& err) noexcept {
    Parser ps(pattern, flags, arena);
    ps.count_groups();
    Node* root = ps.disjunction();
    if (!ps.failed && ps.more())
        ps.fail(ps.peek() == ')' ? "unmatched )" : "unexpected character");
    if (ps.failed || !root) {
        err.msg = ps.error.empty() ? std::string_view("out of memory") : ps.error;
        return false;
    }
    Gen g(arena, flags);
    g.emit(Op::save, 0);
    g.gen(root, false);
    g.emit(Op::save, 1);
    g.emit(Op::match);
    if (g.failed) {
        err.msg = "regular expression too large";
        return false;
    }
    Program* p = arena.make<Program>();
    if (!p)
        return err.msg = "out of memory", false;
    p->ins = g.ins.data;
    p->n = g.ins.size;
    p->n_regs = g.regs;
    p->flags = flags;
    out.program = p;
    out.n_groups = ps.groups;
    std::u16string_view* names = arena.array<std::u16string_view>(ps.groups + 1);
    if (!names)
        return err.msg = "out of memory", false;
    for (uint32_t k = 1; k <= ps.groups && k < ps.names.size; k++)
        names[k] = ps.names[k];
    out.names = names;
    return true;
}

Result match(const Compiled& re, std::u16string_view subject, uint32_t start, int32_t* caps, int64_t& steps) noexcept {
    uint32_t n = (re.n_groups + 1) * 2;
    for (uint32_t k = 0; k < n; k++)
        caps[k] = -1;
    Matcher m{*re.program, subject, caps, n, steps};
    int32_t pos = static_cast<int32_t>(start);
    bool ok = m.run(0, pos, 0);
    if (m.budget_out)
        return Result::budget;
    return ok ? Result::match : Result::no_match;
}

}
