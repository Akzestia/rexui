// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import "base/rexui.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/thread_act.h>
#include <pthread.h>
#include <ptrauth.h>
#include <time.h>
#include <unistd.h>

#include <atomic>
#include <cstdio>
#include <cstring>

#include "base/trace.h"
#include "core/log/log.h"
#include "core/sync/seq.h"

namespace {

rx::sync::Seq g_turn;
rx::sync::Seq g_turn_at;
uint64_t g_turn_n;
mach_port_t g_main = MACH_PORT_NULL;
uintptr_t g_stack_lo, g_stack_hi;
rx::trace::Counters* g_main_counters;
uint64_t g_threshold_ns = 250'000'000;
std::atomic<bool> g_exiting;

void observe(CFRunLoopObserverRef, CFRunLoopActivity activity, void*) {
    if (activity == kCFRunLoopAfterWaiting) {
        if (!(g_turn_n & 1)) {
            g_turn_at.publish(clock_gettime_nsec_np(CLOCK_UPTIME_RAW));
            g_turn.publish(++g_turn_n);
        }
    } else if (g_turn_n & 1) {
        g_turn.publish(++g_turn_n);
    }
}

constexpr int k_frames = 48;

int walk(uintptr_t* out) {
    if (thread_suspend(g_main) != KERN_SUCCESS)
        return 0;
    arm_thread_state64_t st;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    int n = 0;
    if (thread_get_state(g_main, ARM_THREAD_STATE64, (thread_state_t)&st, &count) == KERN_SUCCESS) {
        out[n++] = (uintptr_t)ptrauth_strip((void*)arm_thread_state64_get_pc(st), ptrauth_key_function_pointer);
        out[n++] = (uintptr_t)ptrauth_strip((void*)arm_thread_state64_get_lr(st), ptrauth_key_return_address);
        uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(st);
        while (n < k_frames && fp >= g_stack_lo && fp + 16 <= g_stack_hi && !(fp & 15)) {
            uintptr_t next = ((uintptr_t*)fp)[0], ret = ((uintptr_t*)fp)[1];
            if (!ret)
                break;
            out[n++] = (uintptr_t)ptrauth_strip((void*)ret, ptrauth_key_return_address);
            if (next <= fp)
                break;
            fp = next;
        }
    }
    thread_resume(g_main);
    return n;
}

void say(const char* s) {
    if (!g_exiting.load(std::memory_order_acquire))
        (void)rx::log::write(s, rx::log::warn);
}

void report(uint64_t ms, const uintptr_t* pcs, int n, int cat) {
    char line[320];
    std::snprintf(line, sizeof line, "watchdog: Rex's main thread busy %llu ms in one turn, %s%s",
                  (unsigned long long)ms, cat > 0 ? "inside rexui's " : "outside rexui",
                  cat > 0 ? rx::trace::cat_name((rx::trace::Cat)(cat - 1)) : "");
    say(line);
    for (int i = 0; i < n; i++) {
        Dl_info info{};
        const char *image = "?", *sym = "?";
        uintptr_t off = 0;
        if (dladdr((void*)pcs[i], &info)) {
            if (info.dli_fname)
                image = strrchr(info.dli_fname, '/') ? strrchr(info.dli_fname, '/') + 1 : info.dli_fname;
            if (info.dli_sname)
                sym = info.dli_sname, off = pcs[i] - (uintptr_t)info.dli_saddr;
            else
                off = pcs[i] - (uintptr_t)info.dli_fbase;
        }
        std::snprintf(line, sizeof line, "watchdog:   #%-2d %-24.24s %s + %lu", i, image, sym, (unsigned long)off);
        say(line);
    }
}

void* watch(void*) {
    pthread_setname_np("rexui watchdog");
    uintptr_t pcs[k_frames];
    uint64_t reported = 0, reported_at = 0;
    for (;;) {
        usleep(100'000);
        if (g_exiting.load(std::memory_order_acquire))
            return nullptr;
        uint64_t t = g_turn.read();
        if (reported && t != reported) {
            char line[96];
            std::snprintf(line, sizeof line, "watchdog: main answered after %llu ms",
                          (unsigned long long)((clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - reported_at) / 1'000'000));
            say(line);
            reported = 0;
        }
        if (!(t & 1) || t == reported)
            continue;
        uint64_t at = g_turn_at.read(), now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now < at || now - at < g_threshold_ns || g_turn.read() != t)
            continue;
        int cat =
            g_main_counters ? std::atomic_ref<uint8_t>(g_main_counters->outer).load(std::memory_order_relaxed) : 0;
        int n = walk(pcs);
        if (g_turn.read() != t)
            continue;
        reported = t, reported_at = at;
        report((now - at) / 1'000'000, pcs, n, cat);
    }
    return nullptr;
}

}

void rexui_watchdog_start(void) {
    if (const char* e = getenv("REXUI_WATCHDOG"); e && e[0] == '0')
        return;
    if (const char* e = getenv("REXUI_WATCHDOG_MS"); e && atoi(e) > 0)
        g_threshold_ns = (uint64_t)atoi(e) * 1'000'000;
    static bool started;
    if (started || !pthread_main_np())
        return;
    started = true;
    rexui_log_file(@"watchdog: on");
    atexit([] { g_exiting.store(true, std::memory_order_release); });
    g_main = pthread_mach_thread_np(pthread_self());
    g_stack_hi = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    g_stack_lo = g_stack_hi - pthread_get_stacksize_np(pthread_self());
    g_main_counters = rx::trace::mine();
    CFRunLoopObserverRef o = CFRunLoopObserverCreate(
        nullptr, kCFRunLoopAfterWaiting | kCFRunLoopBeforeWaiting | kCFRunLoopExit, true, LONG_MIN, observe, nullptr);
    CFRunLoopAddObserver(CFRunLoopGetMain(), o, kCFRunLoopCommonModes);
    CFRelease(o);
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
    pthread_t th;
    pthread_create(&th, &a, watch, nullptr);
    pthread_attr_destroy(&a);
}
