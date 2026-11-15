// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"

#include <CoreFoundation/CoreFoundation.h>
#include <os/lock.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <climits>

#include <algorithm>
#include <string>
#include <vector>

namespace rx::trace {

static const char* const k_names[k_cats] = {"key",    "pointer",      "frame", "flush",  "apply",
                                            "layout", "transparency", "panes", "shader", "ingest",
                                            "scan",   "load",         "spawn", "timer",  "gpu"};
static_assert(sizeof(k_names) / sizeof(k_names[0]) == k_cats);

const char* cat_name(Cat c) {
    return k_names[(int)c];
}

static os_unfair_lock g_reg_lock = OS_UNFAIR_LOCK_INIT;
static std::atomic<Counters*> g_head{nullptr};
static thread_local Counters* t_mine;
static Counters* g_main;

Counters* mine() {
    if (Counters* c = t_mine)
        return c;
    auto* c = new Counters();
    pthread_getname_np(pthread_self(), c->name, sizeof c->name);
    if (!c->name[0] && pthread_main_np())
        strlcpy(c->name, "main", sizeof c->name);
    pthread_threadid_np(nullptr, &c->tid);
    os_unfair_lock_lock(&g_reg_lock);
    c->next = g_head.load(std::memory_order_relaxed);
    g_head.store(c, std::memory_order_release);
    os_unfair_lock_unlock(&g_reg_lock);
    t_mine = c;
    if (pthread_main_np())
        g_main = c;
    return c;
}

int main_outer() {
    return g_main ? (int)g_main->outer - 1 : -1;
}

os_log_t log_of(Cat c) {
    static os_log_t logs[k_cats] = {};
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        os_log_t l = os_log_create("com.rexui", OS_LOG_CATEGORY_DYNAMIC_TRACING);
        for (int i = 0; i < k_cats; i++)
            logs[i] = l;
    });
    return logs[(int)c];
}

double ns_per_tick() {
    static double r = [] {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        return (double)tb.numer / tb.denom;
    }();
    return r;
}

template <class T>
static inline void bump(std::atomic<T>& a, T by) {
    a.store(a.load(std::memory_order_relaxed) + by, std::memory_order_relaxed);
}

static uint64_t long_ticks(int k) {
    static const uint64_t t[3] = {(uint64_t)(k_long_ms[0] * 1e6 / ns_per_tick()),
                                  (uint64_t)(k_long_ms[1] * 1e6 / ns_per_tick()),
                                  (uint64_t)(k_long_ms[2] * 1e6 / ns_per_tick())};
    return t[k];
}

static uint64_t now_us() {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000 + (uint64_t)ts.tv_nsec / 1000;
}

static void ring_put(Counters* c, Cat cat, const char* name, uint64_t ticks, const char* file, bool turn) {
    const uint64_t n = c->ring_n.load(std::memory_order_relaxed);
    Long& l = c->ring[n % k_ring];
    l.when_us.store(now_us(), std::memory_order_relaxed);
    l.name.store(name ? name : "", std::memory_order_relaxed);
    l.cat.store((uint8_t)cat, std::memory_order_relaxed);
    l.turn.store(turn, std::memory_order_relaxed);
    l.ticks.store(ticks, std::memory_order_relaxed);
    uint64_t words[3] = {};
    if (file)
        strlcpy(reinterpret_cast<char*>(words), file, sizeof words);
    for (int k = 0; k < 3; k++)
        l.file[k].store(words[k], std::memory_order_relaxed);
    c->ring_n.store(n + 1, std::memory_order_release);
}

static void record_long(Counters* c, Cat cat, uint64_t ticks, const char* name) {
    const int i = (int)cat;
    for (int k = 0; k < 3; k++)
        if (ticks >= long_ticks(k))
            bump(c->over[i][k], (uint64_t)1);
    if (name) {
        for (Named& d : c->named) {
            const char* had = d.name.load(std::memory_order_relaxed);
            if (had && (had != name || d.cat.load(std::memory_order_relaxed) != (uint8_t)cat))
                continue;
            if (!had)
                d.cat.store((uint8_t)cat, std::memory_order_relaxed), d.name.store(name, std::memory_order_release);
            for (int k = 0; k < 3; k++)
                if (ticks >= long_ticks(k))
                    bump(d.over[k], (uint64_t)1);
            if (ticks > d.max_ticks.load(std::memory_order_relaxed))
                d.max_ticks.store(ticks, std::memory_order_relaxed);
            break;
        }
    }
    if (ticks >= long_ticks(1) && c != g_main)
        ring_put(c, cat, name, ticks, c->file, false);
}

void record(Counters* c, Cat cat, uint64_t ticks, bool top, const char* name) {
    int i = (int)cat;
    if (top) {
        bump(c->top_ticks[i], ticks);
        if (ticks >= long_ticks(0))
            record_long(c, cat, ticks, name);
        if (c == g_main) {
            c->turn_ticks += ticks;
            if (ticks > c->turn_max_ticks)
                c->turn_max_ticks = ticks, c->turn_name = name, c->turn_cat = (uint8_t)cat, c->turn_file = c->file;
        }
    }
    bump(c->count[i], (uint64_t)1);
    bump(c->ticks[i], ticks);
    if (ticks > c->max_ticks[i].load(std::memory_order_relaxed))
        c->max_ticks[i].store(ticks, std::memory_order_relaxed);
    double ns = (double)ticks * ns_per_tick();
    int b = ns < 1 ? 0 : 63 - __builtin_clzll((uint64_t)ns);
    if (b >= k_buckets)
        b = k_buckets - 1;
    bump(c->hist[i][b], (uint32_t)1);
}

void record_ns(Cat cat, uint64_t ns) {
    record(mine(), cat, (uint64_t)((double)ns / ns_per_tick()));
}

void count(Cat cat, uint64_t n) {
    bump(mine()->count[(int)cat], n);
}

static uint64_t g_turn_phase_worst;

double turn_worst_take() {
    const double ms = (double)g_turn_phase_worst * ns_per_tick() / 1e6;
    g_turn_phase_worst = 0;
    return ms;
}

static void turn_end() {
    Counters* c = g_main;
    if (!c)
        return;
    const uint64_t t = c->turn_ticks;
    if (t > g_turn_phase_worst)
        g_turn_phase_worst = t;
    if (t) {
        bump(c->turns, (uint64_t)1);
        if (t > c->turn_max_ticks_all.load(std::memory_order_relaxed))
            c->turn_max_ticks_all.store(t, std::memory_order_relaxed);
        for (int k = 0; k < 3; k++)
            if (t >= long_ticks(k))
                bump(c->turn_over[k], (uint64_t)1);
        if (t >= long_ticks(1))
            ring_put(c, (Cat)c->turn_cat, c->turn_name, t, c->turn_file, true);
    }
    c->turn_ticks = 0, c->turn_max_ticks = 0, c->turn_name = nullptr, c->turn_file = nullptr;
}

void watch_turns() {
    static bool on;
    if (on || !pthread_main_np())
        return;
    on = true;
    (void)mine();
    CFRunLoopObserverRef o = CFRunLoopObserverCreateWithHandler(nullptr, kCFRunLoopBeforeWaiting | kCFRunLoopExit, true,
                                                                INT_MAX, ^(CFRunLoopObserverRef, CFRunLoopActivity) {
                                                                    turn_end();
                                                                });
    CFRunLoopAddObserver(CFRunLoopGetMain(), o, kCFRunLoopCommonModes);
    CFRelease(o);
}

void reset() {
    for (Counters* c = g_head.load(std::memory_order_acquire); c; c = c->next) {
        for (int i = 0; i < k_cats; i++) {
            c->count[i].store(0, std::memory_order_relaxed);
            c->ticks[i].store(0, std::memory_order_relaxed);
            c->max_ticks[i].store(0, std::memory_order_relaxed);
            c->top_ticks[i].store(0, std::memory_order_relaxed);
            for (int b = 0; b < k_buckets; b++)
                c->hist[i][b].store(0, std::memory_order_relaxed);
            for (int k = 0; k < 3; k++)
                c->over[i][k].store(0, std::memory_order_relaxed);
        }
        for (Named& d : c->named) {
            for (int k = 0; k < 3; k++)
                d.over[k].store(0, std::memory_order_relaxed);
            d.max_ticks.store(0, std::memory_order_relaxed);
        }
        c->ring_n.store(0, std::memory_order_relaxed);
        for (int k = 0; k < 3; k++)
            c->turn_over[k].store(0, std::memory_order_relaxed);
        c->turns.store(0, std::memory_order_relaxed);
        c->turn_max_ticks_all.store(0, std::memory_order_relaxed);
    }
}

void longs(LongCounts& out) {
    out = {};
    for (Counters* c = g_head.load(std::memory_order_acquire); c; c = c->next) {
        for (int i = 0; i < k_cats; i++)
            for (int k = 0; k < 3; k++)
                out.over[i][k] += c->over[i][k].load(std::memory_order_relaxed);
        for (int k = 0; k < 3; k++)
            out.turn_over[k] += c->turn_over[k].load(std::memory_order_relaxed);
        out.turns += c->turns.load(std::memory_order_relaxed);
        const double ms = (double)c->turn_max_ticks_all.load(std::memory_order_relaxed) * ns_per_tick() / 1e6;
        if (ms > out.worst_turn_ms)
            out.worst_turn_ms = ms;
    }
}

void totals(uint64_t* count_out, double* ns_out, double* top_ns_out) {
    for (int i = 0; i < k_cats; i++) {
        count_out[i] = 0, ns_out[i] = 0;
        if (top_ns_out)
            top_ns_out[i] = 0;
    }
    for (Counters* c = g_head.load(std::memory_order_acquire); c; c = c->next) {
        for (int i = 0; i < k_cats; i++) {
            count_out[i] += c->count[i].load(std::memory_order_relaxed);
            ns_out[i] += (double)c->ticks[i].load(std::memory_order_relaxed) * ns_per_tick();
            if (top_ns_out)
                top_ns_out[i] += (double)c->top_ticks[i].load(std::memory_order_relaxed) * ns_per_tick();
        }
    }
}

static double percentile(const uint64_t* hist, uint64_t n, double q) {
    if (!n)
        return 0;
    uint64_t want = (uint64_t)(q * (double)n), seen = 0;
    for (int b = 0; b < k_buckets; b++) {
        seen += hist[b];
        if (seen > want)
            return (double)(2ull << b);
    }
    return (double)(2ull << (k_buckets - 1));
}

static void cats_json(std::string& out, const uint64_t* count, const uint64_t* ticks, const uint64_t* max,
                      const uint64_t (*hist)[k_buckets], const uint64_t* top, const uint64_t (*over)[3]) {
    out += "{";
    bool first = true;
    char buf[320];
    for (int i = 0; i < k_cats; i++) {
        if (!count[i])
            continue;
        snprintf(buf, sizeof buf,
                 "%s\"%s\":{\"count\":%llu,\"ns\":%.0f,\"top_ns\":%.0f,\"max_ns\":%.0f,\"p50_ns\":%.0f,\"p99_ns\":%.0f,"
                 "\"over4\":%llu,\"over10\":%llu,\"over25\":%llu}",
                 first ? "" : ",", k_names[i], (unsigned long long)count[i], (double)ticks[i] * ns_per_tick(),
                 (double)top[i] * ns_per_tick(), (double)max[i] * ns_per_tick(), percentile(hist[i], count[i], 0.5),
                 percentile(hist[i], count[i], 0.99), (unsigned long long)over[i][0], (unsigned long long)over[i][1],
                 (unsigned long long)over[i][2]);
        out += buf;
        first = false;
    }
    out += "}";
}

static void json_str(std::string& out, const char* s) {
    out += '"';
    for (const char* p = s ? s : ""; *p; p++) {
        if (*p == '"' || *p == '\\')
            out += '\\';
        if ((unsigned char)*p < 0x20)
            continue;
        out += *p;
    }
    out += '"';
}

static void longs_json(std::string& out) {
    struct Row {
        const char* name;
        uint8_t cat;
        uint64_t over[3], max;
    };
    std::vector<Row> rows;
    struct Entry {
        uint64_t when;
        const char* name;
        uint8_t cat, turn;
        uint64_t ticks;
        char file[24];
        const char* thread;
    };
    std::vector<Entry> ring;
    uint64_t turns = 0, turn_over[3] = {}, worst = 0;
    for (Counters* c = g_head.load(std::memory_order_acquire); c; c = c->next) {
        for (Named& d : c->named) {
            const char* name = d.name.load(std::memory_order_acquire);
            if (!name)
                break;
            const uint8_t cat = d.cat.load(std::memory_order_relaxed);
            Row* r = nullptr;
            for (Row& x : rows)
                if (x.name == name && x.cat == cat)
                    r = &x;
            if (!r)
                rows.push_back({name, cat, {}, 0}), r = &rows.back();
            for (int k = 0; k < 3; k++)
                r->over[k] += d.over[k].load(std::memory_order_relaxed);
            const uint64_t m = d.max_ticks.load(std::memory_order_relaxed);
            if (m > r->max)
                r->max = m;
        }
        const uint64_t n = c->ring_n.load(std::memory_order_acquire);
        for (uint64_t j = n > k_ring ? n - k_ring : 0; j < n; j++) {
            Long& l = c->ring[j % k_ring];
            Entry e{l.when_us.load(std::memory_order_relaxed),
                    l.name.load(std::memory_order_relaxed),
                    l.cat.load(std::memory_order_relaxed),
                    l.turn.load(std::memory_order_relaxed),
                    l.ticks.load(std::memory_order_relaxed),
                    {},
                    c->name};
            uint64_t words[3];
            for (int k = 0; k < 3; k++)
                words[k] = l.file[k].load(std::memory_order_relaxed);
            memcpy(e.file, words, sizeof e.file - 1);
            ring.push_back(e);
        }
        turns += c->turns.load(std::memory_order_relaxed);
        for (int k = 0; k < 3; k++)
            turn_over[k] += c->turn_over[k].load(std::memory_order_relaxed);
        const uint64_t w = c->turn_max_ticks_all.load(std::memory_order_relaxed);
        if (w > worst)
            worst = w;
    }
    char buf[256];
    snprintf(buf, sizeof buf,
             ",\"turns\":{\"count\":%llu,\"worst_ms\":%.2f,\"over4\":%llu,\"over10\":%llu,\"over25\":%llu}",
             (unsigned long long)turns, (double)worst * ns_per_tick() / 1e6, (unsigned long long)turn_over[0],
             (unsigned long long)turn_over[1], (unsigned long long)turn_over[2]);
    out += buf;
    out += ",\"long\":[";
    bool any = false;
    for (size_t i = 0; i < rows.size(); i++) {
        const Row& r = rows[i];
        if (!r.over[0])
            continue;
        out += any ? ",{\"name\":" : "{\"name\":";
        any = true;
        json_str(out, r.name);
        snprintf(buf, sizeof buf, ",\"cat\":\"%s\",\"over4\":%llu,\"over10\":%llu,\"over25\":%llu,\"max_ms\":%.2f}",
                 r.cat < k_cats ? k_names[r.cat] : "?", (unsigned long long)r.over[0], (unsigned long long)r.over[1],
                 (unsigned long long)r.over[2], (double)r.max * ns_per_tick() / 1e6);
        out += buf;
    }
    out += "],\"recent\":[";
    std::sort(ring.begin(), ring.end(), [](const Entry& a, const Entry& b) { return a.when > b.when; });
    if (ring.size() > (size_t)k_ring)
        ring.resize(k_ring);
    for (size_t i = 0; i < ring.size(); i++) {
        const Entry& e = ring[i];
        snprintf(buf, sizeof buf, "%s{\"when_ms\":%.0f,\"ms\":%.2f,\"cat\":\"%s\",\"turn\":%s,\"name\":", i ? "," : "",
                 (double)e.when / 1000, (double)e.ticks * ns_per_tick() / 1e6, e.cat < k_cats ? k_names[e.cat] : "?",
                 e.turn ? "true" : "false");
        out += buf;
        json_str(out, e.name);
        out += ",\"file\":";
        json_str(out, e.file);
        out += ",\"thread\":";
        json_str(out, e.thread);
        out += "}";
    }
    out += "]";
}

std::string long_json() {
    std::string out;
    longs_json(out);
    out[0] = '{';
    return out + "}";
}

bool write_json(const char* path) {
    std::string out = "{\"threads\":[";
    uint64_t tc[k_cats] = {}, tt[k_cats] = {}, tm[k_cats] = {}, th[k_cats][k_buckets] = {}, tp[k_cats] = {},
             to[k_cats][3] = {};
    bool first = true;
    for (Counters* c = g_head.load(std::memory_order_acquire); c; c = c->next) {
        uint64_t cc[k_cats], ct[k_cats], cm[k_cats], ch[k_cats][k_buckets], cp[k_cats], co[k_cats][3];
        bool any = false;
        for (int i = 0; i < k_cats; i++) {
            for (int k = 0; k < 3; k++)
                co[i][k] = c->over[i][k].load(std::memory_order_relaxed), to[i][k] += co[i][k];
            cc[i] = c->count[i].load(std::memory_order_relaxed);
            ct[i] = c->ticks[i].load(std::memory_order_relaxed);
            cm[i] = c->max_ticks[i].load(std::memory_order_relaxed);
            cp[i] = c->top_ticks[i].load(std::memory_order_relaxed);
            tp[i] += cp[i];
            for (int b = 0; b < k_buckets; b++)
                ch[i][b] = c->hist[i][b].load(std::memory_order_relaxed);
            tc[i] += cc[i], tt[i] += ct[i], tm[i] = cm[i] > tm[i] ? cm[i] : tm[i];
            for (int b = 0; b < k_buckets; b++)
                th[i][b] += ch[i][b];
            any |= cc[i] != 0;
        }
        if (!any)
            continue;
        char head[128];
        std::string name;
        for (const char* p = c->name; *p; p++) {
            if (*p == '"' || *p == '\\' || (unsigned char)*p < 0x20)
                continue;
            name += *p;
        }
        snprintf(head, sizeof head, "%s{\"name\":\"%s\",\"tid\":%llu,\"cats\":", first ? "" : ",", name.c_str(),
                 (unsigned long long)c->tid);
        out += head;
        cats_json(out, cc, ct, cm, ch, cp, co);
        out += "}";
        first = false;
    }
    out += "],\"total\":";
    cats_json(out, tc, tt, tm, th, tp, to);
    longs_json(out);
    out += "}\n";
    FILE* f = fopen(path, "w");
    if (!f)
        return false;
    bool ok = fwrite(out.data(), 1, out.size(), f) == out.size();
    return fclose(f) == 0 && ok;
}

}
