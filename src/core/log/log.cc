// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/log/log.h"

#include <fcntl.h>
#include <pthread.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "core/sync/rmw.h"
#include "core/sync/spsc_ring.h"

namespace rx::log {

namespace {

enum : std::uint32_t { k_owned = 1, k_orphan = 2 };

struct Slot {
    sync::SpscRing<Record, k_ring> ring;
    std::atomic<std::uint32_t> state{k_owned};
    std::atomic<std::uint64_t> dropped{0};
    bool rang = false;
    std::string partial;
    Slot* next = nullptr;
};

static_assert(std::atomic<std::uint32_t>::is_always_lock_free && std::atomic<std::uint64_t>::is_always_lock_free
              && std::atomic<bool>::is_always_lock_free && std::atomic<Slot*>::is_always_lock_free);

std::mutex g_reg;
std::atomic<Slot*> g_slots{nullptr};
pthread_key_t g_key;
thread_local Slot* t_slot;
std::atomic<bool> g_running{false};
int g_kq = -1;
std::thread* g_writer = nullptr;
std::atomic<std::uint64_t> g_flush_asked{0}, g_flush_done{0};

std::string g_path;
std::uint64_t g_rotate = 4u << 20;

void orphan(void* p) {
    static_cast<Slot*>(p)->state.store(k_orphan, std::memory_order_release);
}

Slot* claim() {
    std::lock_guard lock(g_reg);
    static bool keyed = pthread_key_create(&g_key, orphan) == 0;
    Slot* s = nullptr;
    for (Slot* x = g_slots.load(std::memory_order_acquire); x; x = x->next) {
        if (x->state.load(std::memory_order_acquire) == k_orphan && x->ring.size_approx() == 0) {
            s = x;
            break;
        }
    }
    if (!s) {
        s = new Slot();
        s->next = g_slots.load(std::memory_order_relaxed);
        g_slots.store(s, std::memory_order_release);
    }
    s->state.store(k_owned, std::memory_order_relaxed);
    s->rang = false;
    if (keyed)
        pthread_setspecific(g_key, s);
    t_slot = s;
    return s;
}

void ring_doorbell() {
    struct kevent ev;
    EV_SET(&ev, 1, EVFILT_USER, 0, NOTE_TRIGGER, 0, nullptr);
    kevent(g_kq, &ev, 1, nullptr, 0, nullptr);
}

struct Line {
    std::uint64_t ns;
    std::uint32_t seq;
    Level level;
    std::string text;
};

struct Writer {
    int fd = -1;
    std::uint64_t size = 0;
    std::uint64_t dropped_seen = 0;
    std::vector<Line> lines;
    std::string out;
    std::int64_t prefix_sec = -1;
    char prefix[24] = {};

    void open_file() {
        fd = ::open(g_path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
        struct stat st;
        size = fd >= 0 && fstat(fd, &st) == 0 ? (std::uint64_t)st.st_size : 0;
    }
    void rotate() {
        if (fd >= 0)
            ::close(fd);
        std::string old = g_path + ".1";
        ::rename(g_path.c_str(), old.c_str());
        open_file();
    }

    const char* stamp(std::uint64_t ns) {
        auto sec = (std::int64_t)(ns / 1000000000u);
        if (sec != prefix_sec) {
            prefix_sec = sec;
            time_t t = (time_t)sec;
            struct tm tm;
            localtime_r(&t, &tm);
            snprintf(prefix, sizeof prefix, "%04d-%02d-%02d %02d:%02d:%02d ", tm.tm_year + 1900, tm.tm_mon + 1,
                     tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
        }
        return prefix;
    }

    void drain() {
        lines.clear();
        std::uint32_t seq = 0;
        std::uint64_t dropped = 0;
        Record batch[64];
        for (Slot* s = g_slots.load(std::memory_order_acquire); s; s = s->next) {
            dropped += s->dropped.load(std::memory_order_relaxed);
            for (;;) {
                std::size_t n = s->ring.pop_batch(batch, 64);
                for (std::size_t i = 0; i < n; i++) {
                    const Record& r = batch[i];
                    s->partial.append(r.text, std::min<std::size_t>(r.len, k_text));
                    if (r.flags & k_more)
                        continue;
                    lines.push_back({r.ns, seq++, (Level)r.level, std::move(s->partial)});
                    s->partial.clear();
                }
                if (n < 64)
                    break;
            }
        }
        std::stable_sort(lines.begin(), lines.end(), [](const Line& a, const Line& b) { return a.ns < b.ns; });
        out.clear();
        for (const Line& l : lines) {
            out += stamp(l.ns);
            if (l.level == warn)
                out += "warning: ";
            else if (l.level == error)
                out += "error: ";
            out += l.text;
            out += '\n';
        }
        if (dropped > dropped_seen) {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            char b[96];
            snprintf(b, sizeof b, "log: %llu lines dropped (a thread's log ring was full)\n",
                     (unsigned long long)(dropped - dropped_seen));
            out += stamp((std::uint64_t)ts.tv_sec * 1000000000u + (std::uint64_t)ts.tv_nsec);
            out += b;
            dropped_seen = dropped;
        }
        if (out.empty())
            return;
        if (fd < 0)
            open_file();
        for (std::size_t at = 0; fd >= 0 && at < out.size();) {
            ssize_t w = ::write(fd, out.data() + at, out.size() - at);
            if (w <= 0)
                break;
            at += (std::size_t)w;
            size += (std::uint64_t)w;
        }
        if (size >= g_rotate)
            rotate();
    }

    void run() {
        open_file();
        if (size >= g_rotate)
            rotate();
        for (;;) {
            struct kevent ev;
            struct timespec wait = {0, 100 * 1000 * 1000};
            kevent(g_kq, nullptr, 0, &ev, 1, &wait);
            std::uint64_t asked = g_flush_asked.load(std::memory_order_acquire);
            bool running = g_running.load(std::memory_order_acquire);
            drain();
            g_flush_done.store(asked, std::memory_order_release);
            if (!running)
                break;
        }
        if (fd >= 0)
            ::close(fd);
        fd = -1;
    }
};

Writer* g_w;

}

void start(const char* path, std::uint64_t rotate_bytes) {
    std::lock_guard lock(g_reg);
    if (g_running.load(std::memory_order_relaxed))
        return;
    g_path = path;
    g_rotate = rotate_bytes ? rotate_bytes : (4u << 20);
    if (g_kq < 0) {
        g_kq = kqueue();
        struct kevent ev;
        EV_SET(&ev, 1, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, nullptr);
        kevent(g_kq, &ev, 1, nullptr, 0, nullptr);
    }
    if (!g_w)
        g_w = new Writer();
    g_running.store(true, std::memory_order_release);
    g_writer = new std::thread([] {
        pthread_setname_np("rexui.log");
        g_w->run();
    });
}

bool write(std::string_view line, Level level) {
    if (!g_running.load(std::memory_order_acquire))
        return false;
    Slot* s = t_slot ? t_slot : claim();
    std::size_t need = line.empty() ? 1 : (line.size() + k_text - 1) / k_text;
    if (k_ring - s->ring.size_approx() < need) {
        s->dropped.store(s->dropped.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
        if (!s->rang)
            s->rang = true, ring_doorbell();
        return false;
    }
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    Record r;
    r.ns = (std::uint64_t)ts.tv_sec * 1000000000u + (std::uint64_t)ts.tv_nsec;
    r.level = level;
    r.pad = 0;
    for (std::size_t i = 0; i < need; i++) {
        std::size_t n = std::min(k_text, line.size() - std::min(line.size(), i * k_text));
        std::memcpy(r.text, line.data() + i * k_text, n);
        r.len = (std::uint16_t)n;
        r.flags = i + 1 < need ? k_more : 0;
        (void)s->ring.push(r);
    }
    std::size_t used = s->ring.size_approx();
    if (used >= k_ring / 2 && !s->rang) {
        s->rang = true;
        ring_doorbell();
    } else if (used < k_ring / 4) {
        s->rang = false;
    }
    return true;
}

void flush(int timeout_ms) {
    if (!g_running.load(std::memory_order_acquire))
        return;
    std::uint64_t want = sync::fetch_add(g_flush_asked, (std::uint64_t)1, std::memory_order_acq_rel) + 1;
    ring_doorbell();
    for (int i = 0; i < timeout_ms && g_flush_done.load(std::memory_order_acquire) < want; i++)
        usleep(1000);
}

std::uint64_t dropped() {
    std::uint64_t n = 0;
    for (Slot* s = g_slots.load(std::memory_order_acquire); s; s = s->next)
        n += s->dropped.load(std::memory_order_relaxed);
    return n;
}

void stop() {
    std::lock_guard lock(g_reg);
    if (!g_running.load(std::memory_order_relaxed))
        return;
    g_running.store(false, std::memory_order_release);
    ring_doorbell();
    if (g_writer && g_writer->joinable())
        g_writer->join();
    delete g_writer;
    g_writer = nullptr;
}

}
