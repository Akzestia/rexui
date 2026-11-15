// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#import "ui/ui.h"

#include <mach/mach.h>
#include <pthread.h>

#include <cmath>
#include <cstring>
#include <deque>
#include <list>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "core/io/io.h"
#include "core/sync/byte_ring.h"
#include "core/sync/flags.h"
#include "core/sync/seq.h"
#include "engine/core/defaults.h"
#include "engine/core/doc.h"
#include "engine/vm/value.h"

@interface RXTreeRows : NSObject
@property(nonatomic) NSData* bytes;
@end
@implementation RXTreeRows
@end

using rx::engine::core::Doc;
using rx::engine::core::Sink;
using rx::engine::vm::Kind;
using rx::engine::vm::Str;
using rx::engine::vm::Value;
using rx::sync::ByteRingCtl;
using rx::sync::ByteRingReader;
using rx::sync::ByteRingWriter;

extern "C" void* objc_autoreleasePoolPush(void);
extern "C" void objc_autoreleasePoolPop(void* pool);

namespace {

NSString* ns(std::string_view s) {
    return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}
struct NameHash {
    using is_transparent = void;
    size_t operator()(std::string_view s) const noexcept { return std::hash<std::string_view>{}(s); }
};
NSString* prop_name(std::string_view s) {
    static std::unordered_map<std::string, NSString*, NameHash, std::equal_to<>> names;
    if (auto it = names.find(s); it != names.end())
        return it->second;
    NSString* n = ns(s);
    if (names.size() < 4096)
        names.emplace(std::string(s), n);
    return n;
}

std::string_view view(NSData* d) {
    return d ? std::string_view(static_cast<const char*>(d.bytes), d.length) : std::string_view();
}

enum class Op : uint8_t {
    attach = 1,
    detach,
    load,
    trial,
    emit,
    line,
    message,
    input,
    update,
    toggle,
    global,
    replay,
    settle,
    debug,
    snapshot,
    value,
    restore,
    used,
    stats,
    io_start,
    route,
    big,
    window,
    scrolled,
    create = 64,
    set,
    call,
    send,
    log,
    api,
    wants,
    sources,
    bind,
    reply,
    io_event,
    rows,
    row,
    end,
    shift,
};

struct Rec {
    uint32_t doc;
    Op op;
    uint8_t tag;
    uint16_t pad;
    uint32_t uid;
    uint32_t la, lb, lc;
    uint64_t x;
};
static_assert(sizeof(Rec) == 32);

enum : uint8_t { k_nil = 0, k_false, k_true, k_num, k_utf16, k_json, k_rgba };

bool rgba_of(const char16_t* u, size_t n, uint64_t& x) {
    char c[48];
    size_t k = 0;
    for (size_t i = 0; i < n; i++) {
        const char16_t ch = u[i];
        if (ch == ' ' || ch == '\t')
            continue;
        if (ch > 127 || k + 1 >= sizeof c)
            return false;
        c[k++] = char(ch >= 'A' && ch <= 'Z' ? ch + 32 : ch);
    }
    c[k] = 0;
    auto hex = [](char h) { return h >= '0' && h <= '9' ? h - '0' : h >= 'a' && h <= 'f' ? h - 'a' + 10 : -1; };
    uint32_t r, g, b;
    float a = 1;
    if (k && c[0] == '#') {
        int d[8];
        const size_t m = k - 1;
        if (m != 3 && m != 6 && m != 8)
            return false;
        for (size_t i = 0; i < m; i++)
            if ((d[i] = hex(c[i + 1])) < 0)
                return false;
        if (m == 3)
            r = uint32_t(d[0] * 17), g = uint32_t(d[1] * 17), b = uint32_t(d[2] * 17);
        else {
            const int* e = m == 8 ? d + 2 : d;
            r = uint32_t(e[0] * 16 + e[1]), g = uint32_t(e[2] * 16 + e[3]), b = uint32_t(e[4] * 16 + e[5]);
            if (m == 8)
                a = float(d[0] * 16 + d[1]) / 255.0f;
        }
    } else if (std::strncmp(c, "rgb(", 4) == 0 || std::strncmp(c, "rgba(", 5) == 0) {
        double v[4] = {0, 0, 0, 1};
        const char* at = std::strchr(c, '(') + 1;
        int got = 0;
        for (; got < 4 && *at; got++) {
            char* end = nullptr;
            v[got] = std::strtod(at, &end);
            if (end == at)
                return false;
            at = end;
            if (*at == ',')
                at++;
            else
                break;
        }
        if (got < 2 || *at != ')')
            return false;
        for (int i = 0; i < 3; i++)
            if (!(v[i] >= 0 && v[i] <= 255) || v[i] != std::floor(v[i]))
                return false;
        r = uint32_t(v[0]), g = uint32_t(v[1]), b = uint32_t(v[2]);
        a = float(v[3]);
    } else {
        return false;
    }
    uint32_t abits;
    std::memcpy(&abits, &a, sizeof abits);
    x = uint64_t(r) << 56 | uint64_t(g) << 48 | uint64_t(b) << 40 | abits;
    return true;
}
constexpr uint8_t k_defaults_implied = 1;
const bool g_imply_defaults = [] {
    const char* e = getenv("REXUI_SEND_DEFAULTS");
    return !(e && e[0] == '1');
}();
constexpr uint8_t k_io_first_line = 0xff;
constexpr uint16_t k_by_name = 0xffff;
static_assert(static_cast<int>(rx::schema::Prop::count_) < k_by_name);
enum : uint32_t { k_wants_fps = 1, k_wants_console = 2, k_wants_activity = 4, k_wants_diagnostics = 8 };
enum : uint32_t {
    k_src_fps = 1,
    k_src_activity = 2,
    k_src_diagnostics = 4,
    k_src_rexstate = 8,
    k_src_hover = 16,
    k_src_fps_panes = 32,
    k_src_hints = 64,
    k_src_debug = 128,
    k_src_notices = 256
};

constexpr uint32_t k_ring = 1u << 23;

alignas(128) ByteRingCtl g_jobs_ctl{};
alignas(128) ByteRingCtl g_out_ctl{};
ByteRingWriter g_jobs_w;
ByteRingReader g_jobs_r;
ByteRingWriter g_out_w;
ByteRingReader g_out_r;

bool g_started = false;
bool g_inline = true;
rx::sync::SleepFlag g_engine_sleep;
rx::sync::SleepFlag g_main_sleep;
rx::sync::SleepFlag g_main_wait;
rx::sync::SleepFlag g_main_deferred;
CFRunLoopRef g_engine_rl = nullptr;
CFRunLoopSourceRef g_engine_src = nullptr;
mach_port_t g_engine_port = MACH_PORT_NULL;
CFRunLoopSourceRef g_main_src = nullptr;
dispatch_semaphore_t g_main_sem;
dispatch_semaphore_t g_ask_sem;
dispatch_semaphore_t g_room_sem;

struct Ask {
    uint32_t doc = 0;
    std::string fn, args;
} g_ask;
struct Answer {
    uint8_t kind = 0;
    uint64_t token = 0;
    std::string json;
} g_answer;
rx::sync::Seq g_ask_seq;
uint64_t g_ask_posted = 0;
uint64_t g_ask_served = 0;
int g_serving = 0;

bool on_main() {
    return pthread_main_np() != 0;
}

void wake_main() {
    CFRunLoopSourceSignal(g_main_src);
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

bool put(ByteRingWriter& w, const Rec& h, std::string_view a, std::string_view b, std::string_view c) {
    uint64_t need = sizeof(Rec) + a.size() + b.size() + c.size();
    if (w.space(need) < need)
        return false;
    (void)w.write({reinterpret_cast<const uint8_t*>(&h), sizeof h});
    if (!a.empty())
        (void)w.write({reinterpret_cast<const uint8_t*>(a.data()), a.size()});
    if (!b.empty())
        (void)w.write({reinterpret_cast<const uint8_t*>(b.data()), b.size()});
    if (!c.empty())
        (void)w.write({reinterpret_cast<const uint8_t*>(c.data()), c.size()});
    return true;
}

Rec big_rec(const Rec& h, std::string_view a, std::string_view b, std::string_view c) {
    auto* f = new (std::nothrow) std::string;
    if (!f)
        return Rec{h.doc, Op::big, 0, 0, 0, 0, 0, 0, 0};
    f->reserve(sizeof h + a.size() + b.size() + c.size());
    f->append(reinterpret_cast<const char*>(&h), sizeof h);
    f->append(a), f->append(b), f->append(c);
    return Rec{h.doc, Op::big, 0, 0, 0, 0, 0, 0, reinterpret_cast<uint64_t>(f)};
}

bool take(ByteRingReader& r, Rec& h, std::vector<uint8_t>& buf, std::string_view& a, std::string_view& b,
          std::string_view& c) {
    if (r.read({reinterpret_cast<uint8_t*>(&h), sizeof h}) != sizeof h)
        return false;
    uint64_t n = uint64_t(h.la) + h.lb + h.lc;
    if (n > k_ring)
        return false;
    if (h.op == Op::big) {
        auto* f = reinterpret_cast<std::string*>(h.x);
        std::memcpy(&h, f->data(), sizeof h);
        const size_t size = f->size() - sizeof h;
        buf.resize(size);
        std::memcpy(buf.data(), f->data() + sizeof h, size);
        delete f;
        const char* p = reinterpret_cast<const char*>(buf.data());
        a = {p, h.la}, b = {p + h.la, h.lb}, c = {p + h.la + h.lb, h.lc};
        return true;
    }
    if (buf.capacity() > 2 * k_ring)
        std::vector<uint8_t>().swap(buf);
    if (buf.size() < n)
        buf.resize(n);
    if (n && r.read({buf.data(), static_cast<size_t>(n)}) != n)
        return false;
    const char* p = reinterpret_cast<const char*>(buf.data());
    a = {p, h.la}, b = {p + h.la, h.lb}, c = {p + h.la + h.lb, h.lc};
    return true;
}

void drain_out();

void out(const Rec& h0, std::string_view a = {}, std::string_view b = {}, std::string_view c = {}) {
    Rec h = h0;
    h.la = static_cast<uint32_t>(a.size()), h.lb = static_cast<uint32_t>(b.size()),
    h.lc = static_cast<uint32_t>(c.size());
    uint64_t need = sizeof(Rec) + a.size() + b.size() + c.size();
    if (need > k_ring / 2)
        return out(big_rec(h, a, b, c));
    while (!put(g_out_w, h, a, b, c)) {
        (void)g_out_w.publish();
        if (on_main()) {
            drain_out();
            continue;
        }
        if (g_out_w.block() >= need)
            continue;
        wake_main();
        dispatch_semaphore_signal(g_main_sem);
        dispatch_semaphore_wait(g_room_sem, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC));
    }
    g_out_w.unblock();
}

struct Engine;
std::unordered_map<uint32_t, Engine*> g_engines;

uint32_t src_bits(std::string_view t) {
    auto has = [&](const char* s) { return t.find(s) != std::string_view::npos; };
    uint32_t b = 0;
    if (has("rex.fps"))
        b |= k_src_fps;
    if (has("activity."))
        b |= k_src_activity;
    if (has("diagnostics."))
        b |= k_src_diagnostics;
    if (has("panes.zoomed") || has("panes.busy") || has("panes.arriving"))
        b |= k_src_rexstate;
    if (has("hoveredLink"))
        b |= k_src_hover;
    if (has("panes.fps"))
        b |= k_src_fps_panes;
    if (has("keys.hints"))
        b |= k_src_hints;
    if (has("debug."))
        b |= k_src_debug;
    if (has("notices."))
        b |= k_src_notices;
    return b;
}

bool ascii_is(Value v, std::string_view s) {
    if (!v.is(Kind::string))
        return false;
    Str* t = v.as<Str>();
    if (t->length != s.size())
        return false;
    for (uint32_t i = 0; i < t->length; i++)
        if (t->units[i] != static_cast<char16_t>(s[i]))
            return false;
    return true;
}

bool only_acts(std::string_view fn, Value op) {
    auto any = [&](std::initializer_list<const char*> ops) {
        for (const char* o : ops)
            if (ascii_is(op, o))
                return true;
        return false;
    };
    if (fn == "rex")
        return any({"run", "set", "original", "closeTab", "closeSession", "paneData", "find", "openPane", "takePaste",
                    "paste", "takeLinks", "appIcon"});
    if (fn == "shared")
        return true;
    if (fn == "notices")
        return any({"dismiss", "clear", "reveal", "badge", "delegate"});
    if (fn == "activity")
        return any({"delegate"});
    if (fn == "windows")
        return any({"delegate", "clear"});
    if (fn == "diagnostics")
        return any({"clearCalls", "clearEvents", "follow", "refresh", "reveal"});
    if (fn == "loading")
        return any({"finish"});
    if (fn == "files")
        return any({"watch"});
    if (fn == "clipboard")
        return any({"write", "clear"});
    if (fn == "debug")
        return any({"agentSend", "agentNew", "agentRun", "agentStop", "spotlight"});
    return false;
}

struct Tick {
    Engine* e = nullptr;
    uint32_t uid = 0;
    double interval = 1000;
    bool running = true, repeat = true, dirty = true, aligned = false;
    CFRunLoopTimerRef t = nullptr;
};

double num_of(Value v, double def) {
    if (v.is_num())
        return v.as_num();
    if (v.is_bool())
        return v.is_true() ? 1 : 0;
    if (v.is(Kind::string)) {
        Str* s = v.as<Str>();
        char buf[64];
        uint32_t n = s->length < sizeof buf - 1 ? s->length : uint32_t(sizeof buf - 1);
        for (uint32_t i = 0; i < n; i++)
            buf[i] = s->units[i] < 128 ? char(s->units[i]) : ' ';
        buf[n] = 0;
        return strtod(buf, nullptr);
    }
    return def;
}
bool flag_of(Value v, bool def) {
    if (v.is_undefined() || v.is_null() || v.is_hole())
        return def;
    if (v.is_bool())
        return v.is_true();
    if (v.is(Kind::string)) {
        Str* s = v.as<Str>();
        uint32_t i = 0;
        while (i < s->length && (s->units[i] == ' ' || s->units[i] == '\t'))
            i++;
        if (i < s->length && (s->units[i] == '+' || s->units[i] == '-'))
            i++;
        while (i < s->length && s->units[i] == '0')
            i++;
        if (i >= s->length)
            return false;
        char16_t c = s->units[i];
        return c == 'Y' || c == 'y' || c == 'T' || c == 't' || (c >= '1' && c <= '9');
    }
    return num_of(v, def ? 1 : 0) != 0;
}

void tick_fire(CFRunLoopTimerRef, void* info);

struct NativeSink final : Sink {
    uint32_t doc_id = 0;
    Engine* engine = nullptr;
    std::list<std::string> texts;
    std::string scratch;
    std::unordered_map<uint32_t, Tick*> ticks;
    bool ticks_dirty = false;

    ~NativeSink() {
        for (auto& [uid, t] : ticks) {
            if (t->t)
                CFRunLoopTimerInvalidate(t->t), CFRelease(t->t);
            delete t;
        }
    }
    void schedule() {
        if (!ticks_dirty)
            return;
        ticks_dirty = false;
        for (auto& [uid, t] : ticks) {
            if (!t->dirty)
                continue;
            t->dirty = false;
            if (t->t)
                CFRunLoopTimerInvalidate(t->t), CFRelease(t->t), t->t = nullptr;
            if (!t->running)
                continue;
            double s = t->interval / 1000 > 0.01 ? t->interval / 1000 : 0.01;
            CFRunLoopTimerContext ctx{0, t, nullptr, nullptr, nullptr};
            CFAbsoluteTime first = CFAbsoluteTimeGetCurrent() + s;
            double slack = s * 0.1;
            if (t->aligned) {
                const double unix_now = CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970;
                first = (floor(unix_now / s) + 1) * s + 0.004 - kCFAbsoluteTimeIntervalSince1970;
                slack = MIN(slack, 0.016);
            }
            t->t = CFRunLoopTimerCreate(nullptr, first, t->repeat ? s : 0, 0, 0, tick_fire, &ctx);
            CFRunLoopTimerSetTolerance(t->t, slack);
            CFRunLoopAddTimer(g_inline ? CFRunLoopGetMain() : g_engine_rl, t->t,
                              g_inline ? kCFRunLoopCommonModes : kCFRunLoopDefaultMode);
        }
    }
    void drop_tick(uint32_t uid) {
        auto it = ticks.find(uid);
        if (it == ticks.end())
            return;
        Tick* t = it->second;
        if (t->t)
            CFRunLoopTimerInvalidate(t->t), CFRelease(t->t);
        ticks.erase(it);
        delete t;
    }

    void create(uint32_t uid, std::string_view type, uint32_t parent) override {
        if (type == "Timer") {
            if (Tick* t = new (std::nothrow) Tick())
                t->e = engine, t->uid = uid, drop_tick(uid), ticks[uid] = t, ticks_dirty = true;
        }
        out({doc_id, Op::create, g_imply_defaults ? k_defaults_implied : uint8_t(0), 0, uid, 0, 0, 0, parent}, type);
    }
    bool implies_defaults() const noexcept override { return g_imply_defaults; }
    void set(Doc& d, uint32_t uid, std::string_view prop, Value v) override {
        if (!ticks.empty()) {
            if (auto it = ticks.find(uid); it != ticks.end()
                && (prop == "interval" || prop == "running" || prop == "repeat" || prop == "aligned")) {
                Tick* t = it->second;
                if (prop == "interval")
                    t->interval = num_of(v, 1000);
                else if (prop == "running")
                    t->running = flag_of(v, true);
                else if (prop == "aligned")
                    t->aligned = flag_of(v, false);
                else
                    t->repeat = flag_of(v, true);
                t->dirty = ticks_dirty = true;
                return;
            }
        }
        Rec h{doc_id, Op::set, k_nil, k_by_name, uid, 0, 0, 0, 0};
        rx::schema::Prop p;
        if (rx::schema::prop_of(prop, &p))
            h.pad = static_cast<uint16_t>(p), prop = {};
        if (v.is_undefined() || v.is_null() || v.is_hole())
            return out(h, prop);
        if (v.is_bool())
            return h.tag = v.is_true() ? k_true : k_false, out(h, prop);
        if (v.is_num()) {
            double n = v.as_num();
            static_assert(sizeof n == sizeof h.x);
            std::memcpy(&h.x, &n, sizeof n);
            return h.tag = k_num, out(h, prop);
        }
        if (v.is(Kind::string)) {
            Str* s = v.as<Str>();
            if (h.pad != k_by_name && rx::schema::k_props[h.pad].type == rx::schema::Type::color
                && rgba_of(reinterpret_cast<const char16_t*>(s->units), s->length, h.x))
                return h.tag = k_rgba, out(h, prop);
            h.tag = k_utf16;
            return out(h, prop, {reinterpret_cast<const char*>(s->units), size_t(s->length) * 2});
        }
        std::string_view j = d.json(v);
        if (j == "undefined")
            return out(h, prop);
        h.tag = k_json;
        out(h, prop, j);
    }
    void call(uint32_t uid, std::string_view method, std::string_view arg) override {
        if (method == "destroy" && !ticks.empty())
            drop_tick(uid);
        out({doc_id, Op::call, 0, 0, uid, 0, 0, 0, 0}, method, arg);
    }
    void rows(uint32_t uid, uint32_t n) override { out({doc_id, Op::rows, 0, 0, uid, 0, 0, 0, n}); }
    void row(uint32_t uid, uint32_t i) override { out({doc_id, Op::row, 0, 0, uid, 0, 0, 0, i}); }
    void shift(uint32_t uid, int32_t d) override {
        out({doc_id, Op::shift, 0, 0, uid, 0, 0, 0, static_cast<uint64_t>(static_cast<int64_t>(d))});
    }
    void send(uint32_t uid, std::string_view line) override { out({doc_id, Op::send, 0, 0, uid, 0, 0, 0, 0}, line); }
    void log(std::string_view msg, std::string_view level) override {
        out({doc_id, Op::log, 0, 0, 0, 0, 0, 0, 0}, msg, level);
    }
    bool source(std::string_view path, std::string_view& text) override {
        @autoreleasepool {
            NSString* t = native_source(nil, ns(path));
            if (!t)
                return false;
            texts.emplace_back(t.UTF8String ?: "");
        }
        text = texts.back();
        if (uint32_t b = src_bits(text))
            out({doc_id, Op::sources, 0, 0, b, 0, 0, 0, 0});
        return true;
    }
    Value api(Doc& d, std::string_view, std::string_view method, const Value* args, uint32_t argc) override;
};

struct Engine {
    NativeSink sink;
    Doc doc{sink};
    char name[32] = {};
    uint32_t wants = 0;
    double ms = 0;
    uint64_t calls = 0;
    ~Engine() {
        for (auto& [uid, t] : sink.ticks)
            if (t->t)
                CFRunLoopTimerInvalidate(t->t);
    }
};

void args_json(Doc& d, const Value* args, uint32_t argc, std::string& s) {
    s.assign("[");
    for (uint32_t i = 0; i < argc; i++) {
        if (i)
            s.push_back(',');
        std::string_view j = d.json(args[i]);
        s.append(j == "undefined" ? std::string_view("null") : j);
    }
    s.push_back(']');
}

void serve_ask();
void post(const Rec& h, std::string_view a = {}, std::string_view b = {}, std::string_view c = {}, bool now = false);

void settle_later(uint32_t doc, uint32_t handle, RXPromise* p) {
    p.then = ^(id value, NSString* error) {
        id v = error ?: value ?: NSNull.null;
        NSData* j = [NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingFragmentsAllowed error:nil];
        Rec h{doc, Op::settle, uint8_t(error != nil), 0, 0, 0, 0, 0, handle};
        post(h, j ? view(j) : std::string_view("null"));
    };
}

Value answered(Doc& d, uint32_t doc, uint8_t kind, uint64_t token, std::string_view json, RXPromise* direct) {
    if (kind == 2) {
        Value p;
        uint32_t h = d.promise(p);
        if (!h)
            return Value::undefined();
        if (direct)
            settle_later(doc, h, direct);
        else
            out({doc, Op::bind, 0, 0, h, 0, 0, 0, token});
        return p;
    }
    Value v = Value::undefined();
    if (kind == 1)
        d.parse(json, v);
    if (kind == 3 && json.size() >= sizeof(uint32_t)) {
        uint32_t target;
        std::memcpy(&target, json.data(), sizeof target);
        auto it = g_engines.find(target);
        const auto* rows = reinterpret_cast<const rx::engine::core::TreeRow*>(json.data() + sizeof target);
        const size_t count = (json.size() - sizeof target) / sizeof(rx::engine::core::TreeRow);
        v = d.tree_rows(it != g_engines.end() ? it->second->doc : d, rows, it != g_engines.end() ? count : 0);
    }
    return v;
}

uint8_t answer_of(id r, std::string& json, RXPromise* __strong* promise) {
    if (!r)
        return 0;
    if ([r isKindOfClass:RXPromise.class])
        return *promise = r, 2;
    if ([r isKindOfClass:RXTreeRows.class]) {
        NSData* rows = ((RXTreeRows*)r).bytes;
        return json.assign(static_cast<const char*>(rows.bytes), rows.length), 3;
    }
    NSData* j = [NSJSONSerialization isValidJSONObject:@[r]]
        ? [NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingFragmentsAllowed error:nil]
        : nil;
    if (!j)
        return 0;
    json.assign(view(j));
    return 1;
}

RXDoc* doc_of(uint32_t id);

Value NativeSink::api(Doc& d, std::string_view, std::string_view method, const Value* args, uint32_t argc) {
    args_json(d, args, argc, scratch);
    if (only_acts(method, argc ? args[0] : Value::undefined())) {
        out({doc_id, Op::api, 0, 0, 0, 0, 0, 0, 0}, method, scratch);
        return Value::undefined();
    }
    if (on_main()) {
        (void)g_out_w.publish();
        drain_out();
        std::string json;
        RXPromise* p = nil;
        uint8_t kind;
        @autoreleasepool {
            RXDoc* doc = doc_of(doc_id);
            NSArray* a = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:scratch.data()
                                                                                length:scratch.size()]
                                                         options:0
                                                           error:nil];
            id r = doc && [a isKindOfClass:NSArray.class] ? native_api(doc, ns(method), a) : nil;
            kind = answer_of(r, json, &p);
        }
        return answered(d, doc_id, kind, 0, json, p);
    }
    g_ask.doc = doc_id, g_ask.fn.assign(method), g_ask.args.assign(scratch);
    (void)g_out_w.publish();
    g_ask_seq.publish(++g_ask_posted);
    wake_main();
    dispatch_semaphore_signal(g_main_sem);
    dispatch_semaphore_wait(g_ask_sem, DISPATCH_TIME_FOREVER);
    return answered(d, doc_id, g_answer.kind, g_answer.token, g_answer.json, nil);
}

struct Quiet final : Sink {
    std::list<std::string> texts;
    void create(uint32_t, std::string_view, uint32_t) override {}
    void set(Doc&, uint32_t, std::string_view, Value) override {}
    void call(uint32_t, std::string_view, std::string_view) override {}
    void send(uint32_t, std::string_view) override {}
    void log(std::string_view, std::string_view) override {}
    bool source(std::string_view path, std::string_view& text) override {
        @autoreleasepool {
            NSString* t = native_source(nil, ns(path));
            if (!t)
                return false;
            texts.emplace_back(t.UTF8String ?: "");
        }
        text = texts.back();
        return true;
    }
    Value api(Doc&, std::string_view, std::string_view, const Value*, uint32_t) override { return Value::undefined(); }
    bool implies_defaults() const noexcept override { return true; }
};

void reply(const Rec& job, std::string_view answer, bool none = false) {
    out({job.doc, Op::reply, uint8_t(none ? 1 : 0), 0, 0, 0, 0, 0, job.x}, answer);
}

uint32_t wants_of(Doc& d) {
    uint32_t w = 0;
    if (d.wants("rex", "fps"))
        w |= k_wants_fps;
    if (d.wants("debug", "console"))
        w |= k_wants_console;
    for (const char* k : {"list", "blocks", "tabs", "urgent"})
        if (d.wants("activity", k))
            w |= k_wants_activity;
    for (const char* k : {"binary", "server", "sync", "gpu", "calls", "events", "eventState", "following"})
        if (d.wants("diagnostics", k))
            w |= k_wants_diagnostics;
    return w;
}

void job_end(Engine* e, uint64_t t0) {
    static mach_timebase_info_data_t tb = [] {
        mach_timebase_info_data_t t;
        mach_timebase_info(&t);
        return t;
    }();
    e->ms += double(mach_absolute_time() - t0) * tb.numer / tb.denom / 1e6, e->calls++;
    e->sink.schedule();
    if (uint32_t w = wants_of(e->doc); w != e->wants)
        e->wants = w, out({e->sink.doc_id, Op::wants, 0, 0, w, 0, 0, 0, 0});
    out({e->sink.doc_id, Op::end, 0, 0, 0, 0, 0, 0, 0});
}

struct Route {
    uint32_t io = 0, doc = 0, uid = 0;
    bool told = false;
};
Route g_routes[rx::io::k_max];
bool g_io_on = false;
CFRunLoopSourceRef g_io_src = nullptr;

void published();

void io_event(void*, const rx::io::Event& ev) {
    Route& r = g_routes[ev.id % rx::io::k_max];
    if (ev.kind == rx::io::Kind::out && r.io == ev.id && r.doc) {
        auto it = g_engines.find(r.doc);
        Engine* e = it == g_engines.end() ? nullptr : it->second;
        if (e && e->doc.alive(r.uid)) {
            if (!r.told) {
                r.told = true;
                out({0, Op::io_event, k_io_first_line, 0, ev.id, 0, 0, 0, 0});
            }
            RX_INTERVAL(ingest, "line");
            uint64_t t0 = mach_absolute_time();
            @autoreleasepool {
                if (ev.code == 1)
                    e->doc.line(r.uid, ev.text);
                else
                    e->doc.message(r.uid, ev.text);
                job_end(e, t0);
            }
            published();
            return;
        }
    }
    if (ev.kind == rx::io::Kind::exit && r.io == ev.id)
        r = Route{};
    out({0, Op::io_event, static_cast<uint8_t>(ev.kind), 0, ev.id, 0, 0, 0,
         static_cast<uint64_t>(static_cast<uint32_t>(ev.code))},
        ev.text);
    published();
}

void io_drain(void*) {
    (void)rx::io::drain(io_event, nullptr);
}

void run_job(const Rec& h, std::string_view a, std::string_view b, std::string_view c) {
    RX_INTERVAL(flush, "job");
    if (h.op == Op::attach) {
        Engine* e = new (std::nothrow) Engine();
        if (e && !e->doc.ok())
            delete e, e = nullptr;
        if (e)
            e->sink.doc_id = h.doc, e->sink.engine = e, g_engines[h.doc] = e;
        return;
    }
    if (h.op == Op::io_start) {
        if (!g_io_on) {
            CFRunLoopSourceContext ctx{};
            ctx.perform = io_drain;
            g_io_src = CFRunLoopSourceCreate(nullptr, 0, &ctx);
            CFRunLoopAddSource(g_engine_rl, g_io_src, kCFRunLoopDefaultMode);
            g_io_on = rx::io::start(
                [](void*) {
                    CFRunLoopSourceSignal(g_io_src);
                    CFRunLoopWakeUp(g_engine_rl);
                },
                nullptr);
        }
        reply(h, g_io_on ? "1" : "0");
        return;
    }
    if (h.op == Op::route) {
        g_routes[h.x % rx::io::k_max] = Route{static_cast<uint32_t>(h.x), h.doc, h.uid};
        return;
    }
    if (h.op == Op::trial) {
        Quiet quiet;
        Doc d(quiet);
        reply(h, d.ok() ? d.load(a, b, c) : std::string_view());
        return;
    }
    auto it = g_engines.find(h.doc);
    Engine* e = it == g_engines.end() ? nullptr : it->second;
    if (h.op == Op::detach) {
        if (e)
            g_engines.erase(it), delete e;
        return;
    }
    if (!e) {
        if (h.op == Op::load)
            reply(h, "the engine couldn't start (out of memory)");
        else if (h.op >= Op::replay && h.op != Op::settle)
            reply(h, {}, true);
        return;
    }
    uint64_t t0 = mach_absolute_time();
    Doc& d = e->doc;
    if (h.op == Op::load)
        strlcpy(e->name, std::string(b).c_str(), sizeof e->name);
    rx::trace::set_file(e->name);
    switch (h.op) {
    case Op::load:
        reply(h, d.load(a, b, c));
        break;
    case Op::emit:
        d.emit(h.uid, a, b);
        break;
    case Op::line:
        d.line(h.uid, a);
        break;
    case Op::message:
        d.message(h.uid, a);
        break;
    case Op::input:
        d.input(h.uid, a);
        break;
    case Op::update:
        d.update(h.uid, a);
        break;
    case Op::toggle:
        d.toggle(h.uid);
        break;
    case Op::window:
        d.window(h.uid, static_cast<uint32_t>(h.x), static_cast<uint32_t>(h.x >> 32));
        break;
    case Op::scrolled: {
        double o;
        std::memcpy(&o, &h.x, sizeof o);
        char v[64], args[80];
        snprintf(v, sizeof v, h.tag ? "{\"contentX\":%.17g}" : "{\"contentY\":%.17g}", o);
        snprintf(args, sizeof args, h.tag ? "[%.17g,0]" : "[0,%.17g]", o);
        d.update(h.uid, v);
        d.emit(h.uid, "scrolled", args);
        break;
    }
    case Op::global:
        (void)d.set_global(a, b);
        break;
    case Op::settle:
        d.settle(static_cast<uint32_t>(h.x), a, h.tag != 0);
        break;
    case Op::replay: {
        std::string_view r;
        bool ok = d.replay(a, b, r);
        reply(h, ok ? r : std::string_view(), !ok);
        break;
    }
    case Op::debug:
        reply(h, d.debug(a, b));
        break;
    case Op::snapshot:
        reply(h, d.snapshot());
        break;
    case Op::value:
        reply(h, d.value(h.uid, a));
        break;
    case Op::restore: {
        char n[16];
        int len = snprintf(n, sizeof n, "%u", d.restore(a));
        reply(h, {n, size_t(len > 0 ? len : 0)});
        break;
    }
    case Op::used:
        reply(h, d.used());
        break;
    case Op::stats: {
        int once = 0;
        for (auto& [uid, t] : e->sink.ticks)
            if (t->t && !t->repeat && CFRunLoopTimerIsValid(t->t))
                once++;
        char s[192];
        int len = snprintf(s, sizeof s, "{\"ms\":%.3f,\"calls\":%llu,\"evals\":%llu,\"oneshots\":%d}", e->ms, e->calls,
                           d.stats().evals, once);
        reply(h, {s, size_t(len > 0 ? len : 0)});
        break;
    }
    default:
        break;
    }
    job_end(e, t0);
}

std::vector<uint8_t> g_job_buf;

void published() {
    if (g_out_w.publish() && g_main_sleep.needs_wake() && !g_main_deferred.needs_wake())
        wake_main();
    if (g_main_wait.needs_wake())
        dispatch_semaphore_signal(g_main_sem);
}

void tick_fire(CFRunLoopTimerRef, void* info) {
    Tick* t = static_cast<Tick*>(info);
    Engine* e = t->e;
    if (!e->doc.alive(t->uid))
        return e->sink.drop_tick(t->uid);
    RX_INTERVAL(flush, "Timer");
    rx::trace::set_file(e->name);
    uint64_t t0 = mach_absolute_time();
    @autoreleasepool {
        e->doc.emit(t->uid, "triggered", "[]");
        job_end(e, t0);
    }
    if (g_inline) {
        (void)g_out_w.publish();
        drain_out();
    } else {
        published();
    }
}

void run_jobs(void*) {
    Rec h;
    std::string_view a, b, c;
    while (take(g_jobs_r, h, g_job_buf, a, b, c)) {
        @autoreleasepool {
            run_job(h, a, b, c);
        }
        published();
    }
    if (g_jobs_r.producer_waiting())
        wake_main();
}

void* engine_thread(void* ready) {
    pthread_setname_np("rexui engine");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    g_engine_rl = CFRunLoopGetCurrent();
    CFRunLoopSourceContext ctx{};
    ctx.perform = run_jobs;
    g_engine_src = CFRunLoopSourceCreate(nullptr, 0, &ctx);
    CFRunLoopAddSource(g_engine_rl, g_engine_src, kCFRunLoopDefaultMode);
    CFMachPortContext pctx{};
    CFMachPortRef port =
        CFMachPortCreate(nullptr, [](CFMachPortRef, void*, CFIndex, void*) { run_jobs(nullptr); }, &pctx, nullptr);
    if (port) {
        mach_port_t p = CFMachPortGetPort(port);
        mach_port_limits_t lim{1};
        if (mach_port_insert_right(mach_task_self(), p, p, MACH_MSG_TYPE_MAKE_SEND) == KERN_SUCCESS
            && mach_port_set_attributes(mach_task_self(), p, MACH_PORT_LIMITS_INFO,
                                        reinterpret_cast<mach_port_info_t>(&lim), MACH_PORT_LIMITS_INFO_COUNT)
                == KERN_SUCCESS) {
            CFRunLoopSourceRef ps = CFMachPortCreateRunLoopSource(nullptr, port, 0);
            CFRunLoopAddSource(g_engine_rl, ps, kCFRunLoopDefaultMode);
            CFRelease(ps);
            g_engine_port = p;
        }
    }
    CFRunLoopObserverRef obs =
        CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting, true, 0,
                                           ^(CFRunLoopObserverRef, CFRunLoopActivity act) {
                                               if (act == kCFRunLoopAfterWaiting) {
                                                   if (g_io_on)
                                                       rx::io::main_awake();
                                                   return g_engine_sleep.awake();
                                               }
                                               if (g_io_on) {
                                                   rx::io::main_sleeping();
                                                   if (rx::io::pending()) {
                                                       rx::io::main_awake();
                                                       CFRunLoopSourceSignal(g_io_src);
                                                       CFRunLoopWakeUp(g_engine_rl);
                                                   }
                                               }
                                               g_engine_sleep.prepare_sleep();
                                               if (g_jobs_r.pending()) {
                                                   g_engine_sleep.awake();
                                                   CFRunLoopSourceSignal(g_engine_src);
                                                   CFRunLoopWakeUp(g_engine_rl);
                                               }
                                           });
    CFRunLoopAddObserver(g_engine_rl, obs, kCFRunLoopDefaultMode);
    CFRunLoopTimerRef keep = CFRunLoopTimerCreateWithHandler(nullptr, CFAbsoluteTimeGetCurrent() + 1e10, 1e10, 0, 0,
                                                             ^(CFRunLoopTimerRef){
                                                             });
    CFRunLoopAddTimer(g_engine_rl, keep, kCFRunLoopDefaultMode);
    dispatch_semaphore_signal((__bridge dispatch_semaphore_t)ready);
    for (;;)
        CFRunLoopRun();
    return nullptr;
}

struct Link {
    uint32_t id;
    __weak RXDoc* doc;
    uint32_t wants = 0;
    char name[32] = {};
    bool open = false;
};
constexpr uint32_t k_slots = 4096;
Link* g_links[k_slots];
uint32_t g_next_id = 1;

RXDoc* doc_of(uint32_t id) {
    Link* l = id ? g_links[id % k_slots] : nullptr;
    return l && l->id == id ? l->doc : nil;
}
const char* link_name(uint32_t id) {
    Link* l = id ? g_links[id % k_slots] : nullptr;
    return l && l->id == id ? l->name : nullptr;
}

std::deque<std::string> g_deferred;
std::vector<uint8_t> g_in_buf;
std::unordered_map<uint64_t, std::pair<bool, std::string>> g_replies;
std::unordered_set<uint64_t> g_abandoned;
struct LoadWait {
    uint64_t seq;
    void (^done)(NSString* error);
};
std::vector<LoadWait> g_load_waits;
int g_pace;
double g_drain_until, g_next_slice;
bool g_slice_queued;
constexpr double k_pace_slice = 0.003, k_pace_gap = 0.002;
double g_pace_slice = k_pace_slice;
std::unordered_map<uint64_t, RXPromise*> g_promises;
uint64_t g_token = 0;
uint64_t g_seq = 0;

void kick_engine() {
    if (!g_engine_sleep.needs_wake())
        return;
    if (g_engine_port == MACH_PORT_NULL) {
        CFRunLoopSourceSignal(g_engine_src);
        CFRunLoopWakeUp(g_engine_rl);
        return;
    }
    mach_msg_header_t m{};
    m.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    m.msgh_size = sizeof m;
    m.msgh_remote_port = g_engine_port;
    (void)mach_msg(&m, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
}

void retry_deferred() {
    if (g_deferred.empty())
        return;
    bool any = false;
    while (!g_deferred.empty()) {
        const std::string& f = g_deferred.front();
        if (g_jobs_w.space(f.size()) < f.size())
            break;
        (void)g_jobs_w.write({reinterpret_cast<const uint8_t*>(f.data()), f.size()});
        g_deferred.pop_front(), any = true;
    }
    if (g_deferred.empty())
        g_jobs_w.unblock();
    else
        (void)g_jobs_w.block();
    if (any && g_jobs_w.publish())
        kick_engine();
}

void post(const Rec& h0, std::string_view a, std::string_view b, std::string_view c, bool now) {
    Rec h = h0;
    h.la = static_cast<uint32_t>(a.size()), h.lb = static_cast<uint32_t>(b.size()),
    h.lc = static_cast<uint32_t>(c.size());
    if (g_inline || now) {
        run_job(h, a, b, c);
        (void)g_out_w.publish();
        if (g_inline && !g_serving)
            drain_out();
        return;
    }
    uint64_t need = sizeof(Rec) + a.size() + b.size() + c.size();
    if (need > k_ring / 2)
        return post(big_rec(h, a, b, c));
    if (g_deferred.empty() && put(g_jobs_w, h, a, b, c)) {
        if (g_jobs_w.publish())
            kick_engine();
        return;
    }
    std::string f(reinterpret_cast<const char*>(&h), sizeof h);
    f.append(a), f.append(b), f.append(c);
    g_deferred.push_back(std::move(f));
    (void)g_jobs_w.block();
}

NSString* str16(std::string_view b) {
    return [[NSString alloc] initWithCharacters:reinterpret_cast<const unichar*>(b.data()) length:b.size() / 2];
}

NSString* str16_kept(std::string_view b) {
    if (b.size() > 64)
        return str16(b);
    uint64_t h = 1469598103934665603ull;
    for (char c : b)
        h = (h ^ uint8_t(c)) * 1099511628211ull;
    struct Kept {
        uint64_t h;
        NSString* s;
    };
    static Kept kept[1024];
    Kept& k = kept[h & 1023];
    if (k.s && k.h == h && k.s.length == b.size() / 2) {
        unichar u[32];
        [k.s getCharacters:u range:NSMakeRange(0, k.s.length)];
        if (std::memcmp(u, b.data(), b.size()) == 0)
            return k.s;
    }
    k.h = h, k.s = str16(b);
    return k.s;
}

NSString* rgba_text(uint64_t x) {
    static std::unordered_map<uint64_t, NSString*> made;
    if (auto it = made.find(x); it != made.end())
        return it->second;
    const unsigned r = unsigned(x >> 56) & 255, g = unsigned(x >> 48) & 255, b = unsigned(x >> 40) & 255;
    float a;
    const uint32_t abits = uint32_t(x);
    std::memcpy(&a, &abits, sizeof a);
    NSString* s = a == 1 ? [NSString stringWithFormat:@"#%02x%02x%02x", r, g, b]
                         : [NSString stringWithFormat:@"rgba(%u,%u,%u,%.9g)", r, g, b, double(a)];
    if (made.size() >= 4096)
        made.clear();
    made.emplace(x, s);
    return s;
}
id json_obj(std::string_view j) {
    id o = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:j.data() length:j.size()]
                                           options:NSJSONReadingFragmentsAllowed
                                             error:nil];
    return o == NSNull.null ? nil : o;
}

void apply_set(__unsafe_unretained RXDoc* doc, const Rec& h, std::string_view a, std::string_view b) {
    rx::ui::PVal v;
    id held = nil;
    switch (h.tag) {
    case k_false:
        v.k = rx::ui::PK::no;
        break;
    case k_true:
        v.k = rx::ui::PK::yes;
        break;
    case k_num:
        std::memcpy(&v.d, &h.x, sizeof v.d), v.k = rx::ui::PK::num;
        break;
    case k_utf16:
        held = str16_kept(b), v.k = rx::ui::PK::obj, v.o = held;
        break;
    case k_rgba:
        held = rgba_text(h.x), v.k = rx::ui::PK::obj, v.o = held;
        break;
    case k_json:
        held = json_obj(b);
        v = rx::ui::pval_of(held);
        break;
    default:
        break;
    }
    P p = h.pad < rx::ui::k_nprops ? static_cast<P>(h.pad) : P::count_;
    native_set(doc, (int)h.uid, p, p == P::count_ ? prop_name(a) : prop_ns(p), v);
}

struct Dflt {
    P p;
    rx::ui::PVal v;
    __strong id held;
};
const std::vector<Dflt>& defaults_of(rx::schema::Elem et) {
    namespace sch = rx::schema;
    static std::vector<Dflt> made[std::size(sch::k_elems)];
    static bool done[std::size(sch::k_elems)];
    std::vector<Dflt>& list = made[static_cast<int>(et)];
    if (done[static_cast<int>(et)])
        return list;
    done[static_cast<int>(et)] = true;
    rx::engine::core::each_default(et, [&](const sch::PropDef& d) {
        if (et == sch::Elem::Timer
            && (d.prop == P::interval || d.prop == P::running || d.prop == P::repeat || d.prop == P::aligned))
            return;
        Dflt x{d.prop, {}, nil};
        id o = json_obj(d.json);
        if ([o isKindOfClass:NSString.class]) {
            NSString* str = o;
            unichar u[64];
            uint64_t rgba;
            const NSUInteger n = MIN(str.length, (NSUInteger)64);
            [str getCharacters:u range:NSMakeRange(0, n)];
            if (sch::k_props[static_cast<int>(d.prop)].type == sch::Type::color && str.length <= 64
                && rgba_of(reinterpret_cast<const char16_t*>(u), n, rgba))
                o = rgba_text(rgba);
            x.held = o, x.v.k = rx::ui::PK::obj, x.v.o = o;
        } else {
            x.held = o, x.v = rx::ui::pval_of(o);
        }
        list.push_back(x);
    });
    return list;
}

void apply_defaults(__unsafe_unretained RXDoc* doc, uint32_t uid, std::string_view type) {
    rx::schema::Elem et;
    if (!rx::schema::elem_of(type, &et))
        return;
    RXNode* n = doc->index.find(uid);
    if (!n)
        return;
    apply_fresh_begin(n);
    for (const Dflt& d : defaults_of(et))
        apply(n, d.p, prop_ns(d.p), d.v);
    apply_fresh_end(n);
}

uint64_t g_recs[3], g_rec_bytes[3];

void apply_rec(const Rec& h, std::string_view a, std::string_view b) {
    {
        const int k = h.op == Op::create ? 0 : h.op == Op::set ? 1 : 2;
        g_recs[k]++, g_rec_bytes[k] += sizeof(Rec) + a.size() + b.size();
    }
    if (h.op == Op::reply) {
        if (g_abandoned.erase(h.x))
            return;
        g_replies[h.x] = {h.tag == 1, std::string(a)};
        if (!g_load_waits.empty())
            wake_main();
        return;
    }
    if (h.op == Op::io_event)
        return process_io_event(h.uid, h.tag, static_cast<int>(static_cast<uint32_t>(h.x)), a);
    if (h.op == Op::end) {
        if (Link* l = h.doc ? g_links[h.doc % k_slots] : nullptr; l && l->id == h.doc)
            l->open = false;
        return;
    }
    if (h.doc && h.op != Op::bind)
        if (Link* l = g_links[h.doc % k_slots]; l && l->id == h.doc)
            l->open = true;
    if (h.op == Op::set) {
        if (__unsafe_unretained RXDoc* d = doc_of(h.doc))
            apply_set(d, h, a, b);
        return;
    }
    RXDoc* doc = doc_of(h.doc);
    if (!doc && h.op != Op::bind)
        return;
    switch (h.op) {
    case Op::create:
        native_create(doc, (int)h.uid, prop_name(a), (int)h.x);
        if (h.tag == k_defaults_implied)
            apply_defaults(doc, h.uid, a);
        break;
    case Op::rows:
        if (RXNode* n = doc->index.find(h.uid))
            vlist_rows(n, (uint32_t)h.x);
        break;
    case Op::row:
        if (RXNode* n = doc->index.find(h.uid))
            vlist_row(n, (uint32_t)h.x);
        break;
    case Op::shift:
        if (RXNode* n = doc->index.find(h.uid))
            vlist_shift(n, static_cast<int64_t>(h.x));
        break;
    case Op::call:
        native_call(doc, (int)h.uid, ns(a), ns(b));
        break;
    case Op::send:
        if (RXNode* n = doc->index.find(h.uid))
            send_line(n, ns(a));
        break;
    case Op::log:
        native_log(doc.path.lastPathComponent ?: @"", ns(a), ns(b));
        break;
    case Op::api: {
        NSArray* args = json_obj(b);
        if ([args isKindOfClass:NSArray.class])
            (void)native_api(doc, ns(a), args);
        break;
    }
    case Op::wants:
        if (Link* l = static_cast<Link*>(doc.engine))
            l->wants = h.uid;
        break;
    case Op::sources: {
        uint32_t s = h.uid;
        doc.wants_fps |= (s & k_src_fps) != 0;
        doc.wants_activity |= (s & k_src_activity) != 0;
        doc.wants_diagnostics |= (s & k_src_diagnostics) != 0;
        doc.wants_rexstate |= (s & k_src_rexstate) != 0;
        doc.wants_hover |= (s & k_src_hover) != 0;
        doc.wants_fps_panes |= (s & k_src_fps_panes) != 0;
        doc.wants_hints |= (s & k_src_hints) != 0;
        doc.wants_notices |= (s & k_src_notices) != 0;
        doc.wants_debug |= (s & k_src_debug) != 0;
        break;
    }
    case Op::bind: {
        auto it = g_promises.find(h.x);
        if (it == g_promises.end())
            break;
        RXPromise* p = it->second;
        g_promises.erase(it);
        settle_later(h.doc, h.uid, p);
        break;
    }
    default:
        break;
    }
}

int g_draining = 0;

bool g_drain_cut;
double g_last_drain;
void drain_out() {
    g_drain_cut = false;
    if (!g_started)
        return;
    if (!g_out_r.pending()) {
        if (g_draining == 0 && layouts_waiting())
            layouts_due();
        return;
    }
    RX_INTERVAL(apply, "batch");
    g_draining++;
    Rec h;
    std::string_view a, b, c;
    std::vector<uint8_t> mine;
    std::vector<uint8_t>& buf = g_draining == 1 ? g_in_buf : mine;
    void* pool = objc_autoreleasePoolPush();
    bool cut = false;
    for (uint32_t k = 1; take(g_out_r, h, buf, a, b, c); k++) {
        if (h.doc)
            rx::trace::set_file(link_name(h.doc));
        apply_rec(h, a, b);
        if (k % 32 == 0)
            objc_autoreleasePoolPop(pool), pool = objc_autoreleasePoolPush();
        if (g_out_r.producer_waiting())
            dispatch_semaphore_signal(g_room_sem);
        if (g_drain_until != 0 && g_draining == 1 && CACurrentMediaTime() >= g_drain_until) {
            cut = g_out_r.pending();
            break;
        }
    }
    objc_autoreleasePoolPop(pool);
    if (g_out_r.producer_waiting())
        dispatch_semaphore_signal(g_room_sem);
    if (g_draining == 1)
        layouts_due();
    if (g_draining == 1)
        g_drain_cut = cut, g_last_drain = CACurrentMediaTime();
    g_draining--;
}

void serve_ask() {
    if (g_inline || g_serving)
        return;
    uint64_t s = g_ask_seq.read();
    if (s == g_ask_served)
        return;
    drain_out();
    g_serving++;
    std::string json;
    RXPromise* p = nil;
    uint8_t kind;
    @autoreleasepool {
        RXDoc* doc = doc_of(g_ask.doc);
        NSArray* a = json_obj(g_ask.args);
        id r = doc && [a isKindOfClass:NSArray.class] ? native_api(doc, ns(g_ask.fn), a) : nil;
        kind = answer_of(r, json, &p);
    }
    (void)g_out_w.publish();
    g_serving--;
    g_answer.kind = kind, g_answer.json = std::move(json), g_answer.token = 0;
    if (kind == 2)
        g_answer.token = ++g_token, g_promises[g_token] = p;
    g_ask_served = s;
    dispatch_semaphore_signal(g_ask_sem);
}

void main_turn(void*);

void load_waits_answered() {
    for (size_t i = 0; i < g_load_waits.size();) {
        auto it = g_replies.find(g_load_waits[i].seq);
        if (it == g_replies.end()) {
            i++;
            continue;
        }
        NSString* error = it->second.second.empty() ? nil : ns(it->second.second);
        void (^done)(NSString*) = g_load_waits[i].done;
        g_replies.erase(it);
        g_load_waits.erase(g_load_waits.begin() + static_cast<std::ptrdiff_t>(i));
        done(error);
    }
}

constexpr double k_budget = 0.004;
void paced_turn() {
    const double now = CACurrentMediaTime();
    bool due = now >= g_next_slice;
    if (due) {
        g_drain_until = now + (g_pace > 0 ? g_pace_slice : k_budget);
        drain_out();
        g_drain_until = 0;
        g_next_slice = g_drain_cut ? CACurrentMediaTime() + k_pace_gap : 0;
    }
    if (g_out_r.pending() || !due) {
        if (g_slice_queued)
            return;
        g_slice_queued = true;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, int64_t(k_pace_gap * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{
                           g_slice_queued = false;
                           main_turn(nullptr);
                       });
        return;
    }
    serve_ask();
    retry_deferred();
    load_waits_answered();
}

constexpr double k_frame = 0.008;
double g_urgent_until;
uint32_t g_apply_tick;
void apply_tick(id, const RXFrame*) {
    if (g_out_r.pending())
        return paced_turn();
    ui_clock_remove(g_apply_tick);
    g_apply_tick = 0;
    g_main_deferred.awake();
    if (g_out_r.pending())
        wake_main();
}

void main_turn(void*) {
    if (!g_inline && g_pace == 0 && g_next_slice == 0 && g_out_r.pending()) {
        const double now = CACurrentMediaTime();
        if ((now - g_last_drain < k_frame || g_apply_tick) && now >= g_urgent_until && !ui_clock_occluded_now()) {
            if (!g_apply_tick)
                g_apply_tick = ui_clock_add(RX_TICK_APPLY, 0, nil, NSNull.null, apply_tick);
            g_main_deferred.prepare_sleep();
            serve_ask();
            retry_deferred();
            load_waits_answered();
            return;
        }
    }
    paced_turn();
}

bool call_sync(Rec h, std::string_view a, std::string_view b, std::string_view c, std::string& answer,
               double budget = 0) {
    h.x = ++g_seq;
    post(h, a, b, c, g_serving > 0);
    double until = budget > 0 ? CACurrentMediaTime() + budget : 0;
    for (;;) {
        drain_out();
        auto it = g_replies.find(h.x);
        if (it != g_replies.end()) {
            bool none = it->second.first;
            answer = std::move(it->second.second);
            g_replies.erase(it);
            return !none;
        }
        if (g_inline || g_serving)
            return false;
        serve_ask();
        retry_deferred();
        g_main_wait.prepare_sleep();
        if (g_out_r.pending() || g_ask_seq.read() != g_ask_served) {
            g_main_wait.awake();
            continue;
        }
        double now = CACurrentMediaTime();
        if (until && now >= until) {
            g_main_wait.awake();
            g_abandoned.insert(h.x);
            return false;
        }
        dispatch_time_t t =
            until ? dispatch_time(DISPATCH_TIME_NOW, int64_t((until - now) * NSEC_PER_SEC)) : DISPATCH_TIME_FOREVER;
        dispatch_semaphore_wait(g_main_sem, t);
        g_main_wait.awake();
    }
}

bool start() {
    if (g_started)
        return true;
    static uint8_t* jobs = static_cast<uint8_t*>(calloc(k_ring, 1));
    static uint8_t* outs = static_cast<uint8_t*>(calloc(k_ring, 1));
    if (!jobs || !outs)
        return false;
    g_jobs_w = ByteRingWriter(&g_jobs_ctl, jobs, k_ring), g_jobs_r = ByteRingReader(&g_jobs_ctl, jobs, k_ring);
    g_out_w = ByteRingWriter(&g_out_ctl, outs, k_ring), g_out_r = ByteRingReader(&g_out_ctl, outs, k_ring);
    g_main_sem = dispatch_semaphore_create(0), g_ask_sem = dispatch_semaphore_create(0),
    g_room_sem = dispatch_semaphore_create(0);
    const char* env = getenv("REXUI_ENGINE_THREAD");
    id pref = [NSUserDefaults.standardUserDefaults objectForKey:@"engineThread"];
    bool thread = env ? strcmp(env, "0") != 0 : pref ? [pref boolValue] : true;
    g_started = true;
    if (!thread) {
        g_inline = true;
        return true;
    }
    CFRunLoopSourceContext ctx{};
    ctx.perform = main_turn;
    g_main_src = CFRunLoopSourceCreate(nullptr, 0, &ctx);
    CFRunLoopAddSource(CFRunLoopGetMain(), g_main_src, kCFRunLoopCommonModes);
    CFRunLoopObserverRef obs = CFRunLoopObserverCreateWithHandler(
        nullptr, kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting, true, 1999500,
        ^(CFRunLoopObserverRef, CFRunLoopActivity act) {
            if (act == kCFRunLoopAfterWaiting)
                return g_main_sleep.awake();
            main_turn(nullptr);
            g_main_sleep.prepare_sleep();
            if (!g_slice_queued && ((g_out_r.pending() && !g_apply_tick) || g_ask_seq.read() != g_ask_served)) {
                g_main_sleep.awake();
                wake_main();
            }
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), obs, kCFRunLoopCommonModes);
    lang_misses_install();
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8u << 20);
    pthread_t t;
    bool ok = pthread_create(&t, &attr, engine_thread, (__bridge void*)ready) == 0;
    pthread_attr_destroy(&attr);
    if (!ok) {
        rexui_log(@"engine: its thread couldn't start: on main");
        g_inline = true;
        return true;
    }
    dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
    g_inline = false;
    rexui_log(@"engine: on its own thread");
    return true;
}

}

bool engine_draining(void) {
    return g_draining > 0;
}

void engine_list_window(RXDoc* doc, int uid, uint32_t first, uint32_t count) {
    if (Link* l = static_cast<Link*>(doc.engine))
        post({l->id, Op::window, 0, 0, uint32_t(uid), 0, 0, 0, uint64_t(count) << 32 | first});
}

bool engine_attach(RXDoc* doc) {
    if (!start())
        return false;
    uint32_t did = 0;
    for (uint32_t tries = 0; tries < k_slots; tries++) {
        uint32_t c = g_next_id++;
        if (!c)
            c = g_next_id++;
        if (!g_links[c % k_slots]) {
            did = c;
            break;
        }
    }
    if (!did)
        return false;
    Link* l = new (std::nothrow) Link{did, doc, 0, {}, false};
    if (!l)
        return false;
    strlcpy(l->name, doc.path.lastPathComponent.UTF8String ?: "", sizeof l->name);
    g_links[did % k_slots] = l;
    doc.engine = l;
    post({did, Op::attach, 0, 0, 0, 0, 0, 0, 0});
    doc.ctx = [NSObject new];
    return true;
}

void engine_detach(RXDoc* doc) {
    Link* l = static_cast<Link*>(doc.engine);
    if (!l)
        return;
    doc.engine = nullptr;
    post({l->id, Op::detach, 0, 0, 0, 0, 0, 0, 0});
    g_links[l->id % k_slots] = nullptr;
    delete l;
}

bool engine_take_io(void) {
    if (!start() || g_inline)
        return false;
    std::string r;
    return call_sync({0, Op::io_start, 0, 0, 0, 0, 0, 0, 0}, {}, {}, {}, r) && r == "1";
}

std::vector<double> engine_bench_sets(RXDoc* doc, NSArray<NSArray*>* sets, int count) {
    std::vector<double> out;
    Link* l = doc ? static_cast<Link*>(doc.engine) : nullptr;
    if (!l)
        return out;
    struct One {
        Rec h;
        std::string a, b;
    };
    auto encode = [&](int uid, NSString* name, id v) {
        One o{{l->id, Op::set, k_nil, k_by_name, uint32_t(uid), 0, 0, 0, 0}, name.UTF8String ?: "", {}};
        rx::schema::Prop p;
        if (rx::schema::prop_of(o.a, &p))
            o.h.pad = static_cast<uint16_t>(p), o.a.clear();
        if ([v isKindOfClass:NSNumber.class] && strcmp([v objCType], @encode(char)) == 0)
            o.h.tag = [v boolValue] ? k_true : k_false;
        else if ([v isKindOfClass:NSNumber.class]) {
            double n = [v doubleValue];
            std::memcpy(&o.h.x, &n, sizeof n);
            o.h.tag = k_num;
        } else if ([v isKindOfClass:NSString.class]) {
            NSString* s = v;
            o.b.resize(s.length * 2);
            [s getCharacters:reinterpret_cast<unichar*>(o.b.data()) range:NSMakeRange(0, s.length)];
            o.h.tag = k_utf16;
            if (o.h.pad != k_by_name && rx::schema::k_props[o.h.pad].type == rx::schema::Type::color
                && rgba_of(reinterpret_cast<const char16_t*>(o.b.data()), s.length, o.h.x))
                o.h.tag = k_rgba, o.b.clear();
        } else if (v) {
            NSData* j = [NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingFragmentsAllowed error:nil];
            o.b = std::string(static_cast<const char*>(j.bytes), j.length);
            o.h.tag = k_json;
        }
        return o;
    };
    double tick = rx::trace::ns_per_tick();
    for (NSArray* s in sets) {
        One r[2] = {encode([s[0] intValue], s[1], s[2]), encode([s[0] intValue], s[1], s[3])};
        g_draining++;
        uint64_t t0 = mach_absolute_time();
        void* pool = objc_autoreleasePoolPush();
        for (int i = 0; i < count; i++) {
            const One& o = r[i & 1];
            apply_rec(o.h, o.a, o.b);
            if ((i + 1) % 32 == 0)
                objc_autoreleasePoolPop(pool), pool = objc_autoreleasePoolPush();
        }
        objc_autoreleasePoolPop(pool);
        uint64_t t1 = mach_absolute_time();
        layouts_due();
        g_draining--;
        out.push_back(double(t1 - t0) * tick / count);
    }
    return out;
}

void engine_route(RXDoc* doc, int uid, uint32_t io_id) {
    if (!g_started || g_inline || !io_id)
        return;
    Link* l = doc ? static_cast<Link*>(doc.engine) : nullptr;
    post({l ? l->id : 0, Op::route, 0, 0, l ? uint32_t(uid) : 0, 0, 0, 0, io_id});
}

id engine_tree_rows(RXDoc* target, const rx::engine::core::TreeRow* rows, size_t count) {
    Link* l = static_cast<Link*>(target.engine);
    if (!l)
        return nil;
    NSMutableData* bytes = [NSMutableData dataWithLength:sizeof(uint32_t) + count * sizeof(rx::engine::core::TreeRow)];
    std::memcpy(bytes.mutableBytes, &l->id, sizeof(uint32_t));
    std::memcpy(static_cast<char*>(bytes.mutableBytes) + sizeof(uint32_t), rows,
                count * sizeof(rx::engine::core::TreeRow));
    RXTreeRows* r = [RXTreeRows new];
    r.bytes = bytes;
    return r;
}

void engine_pace(bool on) {
    g_pace += on ? 1 : -1;
    if (g_pace == 0 && g_started)
        wake_main();
}

void engine_clock_stopped(void) {
    if (!g_apply_tick)
        return;
    ui_clock_remove(g_apply_tick);
    g_apply_tick = 0;
    g_main_deferred.awake();
    wake_main();
}

NSString* engine_rgba_text(NSString* colour) {
    std::u16string u(colour.length, u'\0');
    [colour getCharacters:reinterpret_cast<unichar*>(u.data()) range:NSMakeRange(0, colour.length)];
    uint64_t x;
    return rgba_of(u.data(), u.size(), x) ? rgba_text(x) : nil;
}

void engine_record_counts(uint64_t n[3], uint64_t bytes[3]) {
    for (int i = 0; i < 3; i++)
        n[i] = g_recs[i], bytes[i] = g_rec_bytes[i];
}

bool engine_scrolled(RXDoc* doc, int uid, bool across, double offset) {
    Link* l = static_cast<Link*>(doc.engine);
    if (!l)
        return false;
    Rec h{l->id, Op::scrolled, uint8_t(across ? 1 : 0), 0, uint32_t(uid), 0, 0, 0, 0};
    std::memcpy(&h.x, &offset, sizeof offset);
    post(h);
    return true;
}

void engine_urgent(void) {
    g_urgent_until = CACurrentMediaTime() + 0.1;
}

bool engine_job_open(RXDoc* doc) {
    Link* l = static_cast<Link*>(doc.engine);
    return l && l->open;
}

const char* engine_file_name(RXDoc* doc) {
    Link* l = static_cast<Link*>(doc.engine);
    return l ? l->name : nullptr;
}

void engine_pace_slice(double seconds) {
    g_pace_slice = seconds >= 0 ? seconds : k_pace_slice;
}

void engine_load_async(RXDoc* doc, NSString* src, NSString* name, NSString* path, void (^done)(NSString* error)) {
    Link* l = static_cast<Link*>(doc.engine);
    if (!l)
        return done(nil);
    Rec h{l->id, Op::load, 0, 0, 0, 0, 0, 0, 0};
    h.x = ++g_seq;
    g_load_waits.push_back({h.x, [done copy]});
    post(h, src.UTF8String ?: "", name.UTF8String ?: "", path.UTF8String ?: "", g_serving > 0);
    if (g_inline)
        load_waits_answered();
}

id engine_call(RXDoc* doc, NSString* method, NSArray* args) {
    Link* l = static_cast<Link*>(doc.engine);
    if (!l)
        return nil;
    uint32_t did = l->id;
    auto json_of = [&](id o) -> NSData* {
        return o && [NSJSONSerialization isValidJSONObject:o]
            ? [NSJSONSerialization dataWithJSONObject:o options:0 error:nil]
            : nil;
    };
    auto json_args = [&]() -> NSData* {
        NSData* j = json_of(args ?: @[]);
        if (!j)
            rexui_log([NSString stringWithFormat:@"engine: %@'s arguments aren't JSON", method]);
        return j ?: [@"[]" dataUsingEncoding:NSUTF8StringEncoding];
    };
    auto answer = [&](const std::string& j) -> id { return j == "undefined" || j.empty() ? nil : json_obj(j); };
    std::string r;
    NSUInteger n = args.count;
    auto uid = [&](NSUInteger i) -> uint32_t {
        return i < n && [args[i] isKindOfClass:NSNumber.class] ? [args[i] unsignedIntValue] : 0;
    };
    auto text = [&](NSUInteger i) -> NSString* {
        return i < n && [args[i] isKindOfClass:NSString.class] ? args[i] : nil;
    };
    auto utf8 = [](NSString* s) { return std::string_view(s.UTF8String ?: ""); };

    if ([method isEqualToString:@"line"] && text(1))
        return post({did, Op::line, 0, 0, uid(0), 0, 0, 0, 0}, utf8(text(1))), nil;
    if ([method isEqualToString:@"message"] && text(1))
        return post({did, Op::message, 0, 0, uid(0), 0, 0, 0, 0}, utf8(text(1))), nil;
    if ([method isEqualToString:@"emit"] && text(1)) {
        id list = n > 2 ? args[2] : @[];
        bool empty = [list isKindOfClass:NSArray.class] && [list count] == 0;
        NSData* j = empty ? nil : json_of(list);
        if (j || empty)
            return post({did, Op::emit, 0, 0, uid(0), 0, 0, 0, 0}, utf8(text(1)), j ? view(j) : std::string_view("[]")),
                   nil;
    }
    if ([method isEqualToString:@"input"] && text(1))
        return post({did, Op::input, 0, 0, uid(0), 0, 0, 0, 0}, utf8(text(1))), nil;
    if ([method isEqualToString:@"toggle"])
        return post({did, Op::toggle, 0, 0, uid(0), 0, 0, 0, 0}), nil;
    static NSDictionary* globals = @{
        @"setTheme": @"theme",
        @"setRex": @"rex",
        @"setLang": @"i18n",
        @"setConf": @"conf",
        @"setKeys": @"keys",
        @"setContext": @"context",
        @"setPanes": @"panes",
        @"setNotices": @"notices",
        @"setDiagnostics": @"diagnostics",
        @"setWindows": @"windows",
        @"setShared": @"shared",
        @"setActivity": @"activity",
        @"setPane": @"pane",
        @"setDebug": @"debug",
        @"setLoading": @"loading",
        @"setPower": @"power"
    };
    if (NSString* g = globals[method]; g && n) {
        if (NSData* j = json_of(args[0]))
            return post({did, Op::global, 0, 0, 0, 0, 0, 0, 0}, utf8(g), view(j)), nil;
    }
    if ([method isEqualToString:@"update"] && n > 1) {
        if (NSData* j = json_of(args[1]))
            return post({did, Op::update, 0, 0, uid(0), 0, 0, 0, 0}, view(j)), nil;
    }

    if ([method isEqualToString:@"wantsFps"])
        return @((l->wants & k_wants_fps) != 0);
    if ([method isEqualToString:@"wantsConsole"])
        return @((l->wants & k_wants_console) != 0);
    if ([method isEqualToString:@"wantsActivity"])
        return @((l->wants & k_wants_activity) != 0);
    if ([method isEqualToString:@"wantsDiagnostics"])
        return @((l->wants & k_wants_diagnostics) != 0);
    if ([method isEqualToString:@"recover"])
        return nil;

    if ([method isEqualToString:@"load"] && n >= 3 && text(0) && text(1) && text(2)) {
        if (!call_sync({did, Op::load, 0, 0, 0, 0, 0, 0, 0}, utf8(text(0)), utf8(text(1)), utf8(text(2)), r))
            return nil;
        return r.empty() ? nil : ns(r);
    }
    if ([method isEqualToString:@"used"])
        return call_sync({did, Op::used, 0, 0, 0, 0, 0, 0, 0}, {}, {}, {}, r) ? answer(r) : nil;
    if ([method isEqualToString:@"stats"])
        return call_sync({did, Op::stats, 0, 0, 0, 0, 0, 0, 0}, {}, {}, {}, r) ? answer(r) : nil;
    static NSDictionary* debug = @{
        @"debugOutline": @"outline",
        @"debugInspect": @"inspect",
        @"debugEdit": @"edit",
        @"debugUndo": @"undo",
        @"debugEval": @"eval",
        @"debugComplete": @"complete"
    };
    if (NSString* op = debug[method]) {
        return call_sync({did, Op::debug, 0, 0, 0, 0, 0, 0, 0}, utf8(op), view(json_args()), {}, r) ? answer(r) : nil;
    }
    bool delegate = [method hasSuffix:@"Delegate"];
    if (!call_sync({did, Op::replay, 0, 0, 0, 0, 0, 0, 0}, utf8(method), view(json_args()), {}, r,
                   delegate ? 0.1 : 0)) {
        static NSMutableSet* told = [NSMutableSet set];
        NSString* key = delegate ? [method stringByAppendingString:@" late"] : method;
        if (![told containsObject:key]) {
            [told addObject:key];
            rexui_log(delegate ? [NSString stringWithFormat:@"engine: %@ didn't answer within 100 ms: native's default",
                                                            method]
                               : [NSString stringWithFormat:@"engine: no %@ yet", method]);
        }
        return nil;
    }
    return answer(r);
}

NSString* engine_snapshot(RXDoc* doc) {
    Link* l = static_cast<Link*>(doc.engine);
    std::string r;
    if (!l || !call_sync({l->id, Op::snapshot, 0, 0, 0, 0, 0, 0, 0}, {}, {}, {}, r))
        return nil;
    return r == "{}" ? nil : ns(r);
}

NSString* engine_value(RXDoc* doc, int uid, NSString* name) {
    Link* l = static_cast<Link*>(doc.engine);
    std::string r;
    if (!l || uid < 0
        || !call_sync({l->id, Op::value, 0, 0, uint32_t(uid), 0, 0, 0, 0}, name.UTF8String ?: "", {}, {}, r))
        return nil;
    return r == "undefined" ? nil : ns(r);
}

unsigned engine_restore(RXDoc* doc, NSString* state) {
    Link* l = static_cast<Link*>(doc.engine);
    std::string r;
    if (!l || !state || !call_sync({l->id, Op::restore, 0, 0, 0, 0, 0, 0, 0}, state.UTF8String ?: "{}", {}, {}, r))
        return 0;
    return static_cast<unsigned>(strtoul(r.c_str(), nullptr, 10));
}

void engine_trial_async(NSString* path, NSString* src, void (^done)(NSString* error)) {
    RX_INTERVAL(load, "reload trial");
    if (!start())
        return done(nil);
    Rec h{0, Op::trial, 0, 0, 0, 0, 0, 0, 0};
    h.x = ++g_seq;
    g_load_waits.push_back({h.x, [done copy]});
    post(h, src.UTF8String ?: "", path.lastPathComponent.UTF8String ?: "", path.UTF8String ?: "", g_serving > 0);
    if (g_inline)
        load_waits_answered();
}

@implementation RXPromise {
    bool _settled;
    id _value;
    NSString* _error;
}
- (void)setThen:(void (^)(id, NSString*))then {
    _then = [then copy];
    if (_settled && _then)
        _then(_value, _error);
}
- (void)resolve:(id)value {
    if (_settled)
        return;
    _settled = true, _value = value;
    if (_then)
        _then(value, nil);
}
- (void)reject:(NSString*)error {
    if (_settled)
        return;
    _settled = true, _error = error ?: @"failed";
    if (_then)
        _then(nil, _error);
}
@end

RXPromise* rx_promise(dispatch_queue_t q, id (^work)(NSString** error)) {
    RXPromise* p = [RXPromise new];
    dispatch_async(q ?: dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString* err = nil;
        id out = work(&err);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err && !out)
                [p reject:err];
            else
                [p resolve:out ?: NSNull.null];
        });
    });
    return p;
}
