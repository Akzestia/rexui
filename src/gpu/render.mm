// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "gpu/gpu.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#include <mach/mach.h>
#include <pthread.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "core/sync/flags.h"
#include "core/sync/spsc_ring.h"

@interface RXGpuTick : NSObject
- (void)tick:(CADisplayLink*)link;
@end

namespace rx::gpu {
namespace {

id<MTLDevice> g_device;
id<MTLCommandQueue> g_queue;

rx::sync::SpscRing<Job, 512> g_jobs;
rx::sync::SleepFlag g_sleep;
mach_port_t g_port = MACH_PORT_NULL;
std::atomic<bool> g_on;
std::uint32_t g_next_link = 1;

struct Ticker {
    std::uint32_t id;
    double fps;
    std::uint32_t wait;
    TickDraw draw;
    TickGone gone;
    void* ctx;
};
std::vector<Ticker> g_tickers;
CADisplayLink* g_link;
double g_link_rate;

enum class Ctl : std::uint8_t { add, rate, remove, attach };
struct Control {
    Ctl op;
    std::uint32_t id;
    double fps;
    void* link;
    TickDraw draw;
    TickGone gone;
    void* ctx;
};
static_assert(sizeof(Control) <= k_job_bytes);

double clamp_fps(double fps) {
    return fps > 0 && fps < 120 ? fps : 0;
}

void retune() {
    if (!g_link)
        return;
    double rate = 0;
    for (const Ticker& t : g_tickers)
        rate = std::max(rate, t.fps > 0 ? t.fps : 120.0);
    g_link.paused = g_tickers.empty();
    if (rate > 0 && rate != g_link_rate) {
        g_link_rate = rate;
        g_link.preferredFrameRateRange = CAFrameRateRangeMake((float)std::min(rate, 60.0), (float)rate, (float)rate);
    }
}

void control(Job& job, id<MTLCommandBuffer>) {
    Control c;
    memcpy(&c, job.data, sizeof c);
    if (c.op == Ctl::attach) {
        g_link = (__bridge_transfer CADisplayLink*)c.link;
        [g_link addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
        g_link_rate = 0;
        return retune();
    }
    if (c.op == Ctl::add) {
        g_tickers.push_back({c.id, clamp_fps(c.fps), UINT32_MAX - 1, c.draw, c.gone, c.ctx});
        return retune();
    }
    for (size_t i = 0; i < g_tickers.size(); i++) {
        if (g_tickers[i].id != c.id)
            continue;
        if (c.op == Ctl::rate) {
            g_tickers[i].fps = clamp_fps(c.fps);
            return retune();
        }
        Ticker gone = g_tickers[i];
        g_tickers.erase(g_tickers.begin() + static_cast<std::ptrdiff_t>(i));
        gone.gone(gone.ctx);
        return retune();
    }
}

void tick(CADisplayLink* link) {
    static double last;
    const double target = link.targetTimestamp;
    const double step = last > 0 && target > last && target - last < 0.1
        ? target - last
        : (link.duration > 0 ? link.duration : 1.0 / 60);
    last = target;
    const double now = CACurrentMediaTime();
    @autoreleasepool {
        id<MTLCommandBuffer> cb = nil;
        bool any = false;
        for (Ticker& t : g_tickers) {
            if (t.fps > 0) {
                const std::uint32_t k = (std::uint32_t)std::max(1.0, std::round(1 / (step * t.fps)));
                if (++t.wait < k)
                    continue;
                t.wait = 0;
            }
            if (!cb)
                cb = [g_queue commandBufferWithUnretainedReferences];
            any |= t.draw(t.ctx, now, cb);
        }
        if (any)
            [cb commit];
    }
}

void drain() {
    static Job jobs[64];
    for (;;) {
        size_t n = g_jobs.pop_batch(jobs, 64);
        if (!n)
            return;
        @autoreleasepool {
            id<MTLCommandBuffer> cb = nil;
            for (size_t i = 0; i < n; i++) {
                if (jobs[i].control) {
                    jobs[i].encode(jobs[i], nil);
                    continue;
                }
                if (!cb)
                    cb = [g_queue commandBufferWithUnretainedReferences];
                jobs[i].encode(jobs[i], cb);
            }
            [cb commit];
        }
    }
}

void woken(CFMachPortRef, void*, CFIndex, void*) {
    drain();
}

void before_sleep(CFRunLoopObserverRef, CFRunLoopActivity activity, void*) {
    if (activity == kCFRunLoopAfterWaiting)
        return g_sleep.awake();
    g_sleep.prepare_sleep();
    drain();
}

void* render_thread(void* arg) {
    pthread_setname_np("rexui render");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    dispatch_semaphore_t up = (__bridge dispatch_semaphore_t)arg;
    @autoreleasepool {
        CFMachPortRef port = CFMachPortCreate(nullptr, woken, nullptr, nullptr);
        if (port) {
            g_port = CFMachPortGetPort(port);
            mach_port_insert_right(mach_task_self(), g_port, g_port, MACH_MSG_TYPE_MAKE_SEND);
            CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(nullptr, port, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
            CFRelease(src);
            CFRunLoopObserverRef o = CFRunLoopObserverCreate(nullptr, kCFRunLoopBeforeWaiting | kCFRunLoopAfterWaiting,
                                                             true, 0, before_sleep, nullptr);
            CFRunLoopAddObserver(CFRunLoopGetCurrent(), o, kCFRunLoopCommonModes);
            CFRelease(o);
        }
    }
    dispatch_semaphore_signal(up);
    if (g_port == MACH_PORT_NULL)
        return nullptr;
    for (;;)
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1e9, false);
        }
    return nullptr;
}

bool push(const Job& job) {
    if (!g_on.load(std::memory_order_acquire))
        return false;
    if (g_jobs.push(job) != rx::sync::Push::Ok)
        return false;
    if (g_sleep.needs_wake()) {
        mach_msg_header_t m{};
        m.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
        m.msgh_size = sizeof m;
        m.msgh_remote_port = g_port;
        (void)mach_msg(&m, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof m, 0, MACH_PORT_NULL, 0, MACH_PORT_NULL);
    }
    return true;
}

bool push_control(const Control& c) {
    Job job;
    job.encode = control;
    job.control = true;
    memcpy(job.data, &c, sizeof c);
    return push(job);
}

}

id<MTLDevice> device() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_device = MTLCreateSystemDefaultDevice();
        g_queue = [g_device newCommandQueue];
    });
    return g_device;
}

id<MTLCommandQueue> queue() {
    (void)device();
    return g_queue;
}

bool render_start() {
    if (g_on.load(std::memory_order_acquire))
        return true;
    if (const char* e = getenv("REXUI_RENDER_THREAD"); e && e[0] == '0')
        return false;
    static bool failed;
    if (failed)
        return false;
    (void)queue();
    dispatch_semaphore_t up = dispatch_semaphore_create(0);
    pthread_t t;
    if (pthread_create(&t, nullptr, render_thread, (__bridge void*)up) != 0)
        return failed = true, false;
    pthread_detach(t);
    dispatch_semaphore_wait(up, DISPATCH_TIME_FOREVER);
    if (g_port == MACH_PORT_NULL)
        return failed = true, false;
    g_on.store(true, std::memory_order_release);
    return true;
}

bool render_push(const Job& job) {
    return push(job);
}

static bool g_attached;

id link_target() {
    static RXGpuTick* t = [RXGpuTick new];
    return t;
}

bool clock_attach(id display_link) {
    if (g_attached)
        return true;
    if (!render_start() || !display_link)
        return false;
    Control c{Ctl::attach, 0, 0, (__bridge_retained void*)display_link, nullptr, nullptr, nullptr};
    if (!push_control(c)) {
        (void)(__bridge_transfer id)c.link;
        return false;
    }
    return g_attached = true;
}

LinkId link_add(double fps, TickDraw draw, TickGone gone, void* ctx) {
    if (!g_attached || !render_start())
        return {};
    if (!push_control({Ctl::add, g_next_link, fps, nullptr, draw, gone, ctx}))
        return {};
    return {g_next_link++};
}

bool link_rate(LinkId id, double fps) {
    return id.v && push_control({Ctl::rate, id.v, fps, nullptr, nullptr, nullptr, nullptr});
}
bool link_remove(LinkId id) {
    return id.v && push_control({Ctl::remove, id.v, 0, nullptr, nullptr, nullptr, nullptr});
}

}

@implementation RXGpuTick
- (void)tick:(CADisplayLink*)link {
    rx::gpu::tick(link);
}
@end
