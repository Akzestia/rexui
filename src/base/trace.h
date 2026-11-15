// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <mach/mach_time.h>
#include <os/signpost.h>
#include <stdint.h>

#include <atomic>
#include <string>

namespace rx::trace {

enum class Cat : uint8_t {
    key,
    pointer,
    frame,
    flush,
    apply,
    layout,
    transparency,
    panes,
    shader,
    ingest,
    scan,
    load,
    spawn,
    timer,
    gpu,
    count_
};
inline constexpr int k_cats = (int)Cat::count_;
inline constexpr int k_buckets = 32;

inline constexpr double k_long_ms[3] = {4, 10, 25};
inline constexpr int k_named = 48;
inline constexpr int k_ring = 64;

struct Named {
    std::atomic<const char*> name;
    std::atomic<uint8_t> cat;
    std::atomic<uint64_t> over[3];
    std::atomic<uint64_t> max_ticks;
};
struct Long {
    std::atomic<uint64_t> when_us;
    std::atomic<const char*> name;
    std::atomic<uint8_t> cat;
    std::atomic<uint8_t> turn;
    std::atomic<uint64_t> ticks;
    std::atomic<uint64_t> file[3];
};

struct Counters {
    std::atomic<uint64_t> count[k_cats];
    std::atomic<uint64_t> ticks[k_cats];
    std::atomic<uint64_t> max_ticks[k_cats];
    std::atomic<uint32_t> hist[k_cats][k_buckets];
    std::atomic<uint64_t> top_ticks[k_cats];
    std::atomic<uint64_t> over[k_cats][3];
    Named named[k_named];
    std::atomic<uint64_t> ring_n;
    Long ring[k_ring];
    std::atomic<uint64_t> turn_over[3];
    std::atomic<uint64_t> turns, turn_max_ticks_all;
    uint64_t turn_ticks, turn_max_ticks;
    const char *turn_name, *turn_file;
    uint8_t turn_cat;
    const char* file;
    int depth;
    uint8_t outer;
    char name[32];
    uint64_t tid;
    Counters* next;
};
static_assert(std::atomic<uint64_t>::is_always_lock_free && std::atomic<uint32_t>::is_always_lock_free);

Counters* mine();
os_log_t log_of(Cat c);
const char* cat_name(Cat c);
double ns_per_tick();
void record(Counters* c, Cat cat, uint64_t ticks, bool top = false, const char* name = nullptr);
inline void set_file(const char* name) {
    mine()->file = name;
}
void watch_turns();

class Interval {
  public:
    explicit Interval(Cat cat, const char* name) : cat_(cat), name_(name) {
        start_ = mach_ticks();
        Counters* c = mine();
        if (c->depth++ == 0)
            c->outer = (uint8_t)((int)cat + 1), c->file = nullptr;
        os_log_t log = log_of(cat);
        if (os_signpost_enabled(log)) {
            id_ = os_signpost_id_generate(log);
            os_signpost_interval_begin(log, id_, "rx", "%{public}s %{public}s", cat_name(cat), name);
        }
    }
    ~Interval() {
        uint64_t t = mach_ticks() - start_;
        Counters* c = mine();
        bool top = --c->depth == 0;
        if (top)
            c->outer = 0;
        record(c, cat_, t, top, name_);
        if (id_ != OS_SIGNPOST_ID_NULL)
            os_signpost_interval_end(log_of(cat_), id_, "rx");
    }
    Interval(const Interval&) = delete;
    Interval& operator=(const Interval&) = delete;

    static uint64_t mach_ticks() { return mach_absolute_time(); }

  private:
    Cat cat_;
    const char* name_;
    uint64_t start_;
    os_signpost_id_t id_ = OS_SIGNPOST_ID_NULL;
};

int main_outer();

void record_ns(Cat cat, uint64_t ns);

void count(Cat cat, uint64_t n = 1);

bool write_json(const char* path);
void totals(uint64_t* count_out, double* ns_out, double* top_ns_out = nullptr);
double turn_worst_take();
struct LongCounts {
    uint64_t over[k_cats][3];
    uint64_t turns, turn_over[3];
    double worst_turn_ms;
};
void longs(LongCounts& out);
std::string long_json();
void reset();
const char* cat_name(Cat c);

}

#define RX_TRACE_CAT2(a, b) a##b
#define RX_TRACE_CAT(a, b) RX_TRACE_CAT2(a, b)
#define RX_INTERVAL(cat, name) ::rx::trace::Interval RX_TRACE_CAT(rx_interval_, __LINE__)(::rx::trace::Cat::cat, name)
