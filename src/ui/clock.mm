// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "ui/ui.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace {

struct Ticker {
    uint32_t key;
    uint8_t order;
    double fps;
    uint32_t wait;
    id owner;
    void (*fn)(id, const RXFrame*);
};

std::vector<Ticker> g_tickers;
std::vector<Ticker> g_added;
uint32_t g_next = 1;
bool g_in_frame;
bool g_dirty;
CADisplayLink* g_link;
__weak NSView* g_link_view;
double g_rate;
bool g_occluded;

}

@interface RXClockTarget : NSObject
- (void)tick:(CADisplayLink*)link;
@end

static void clock_retune(void);

@implementation RXClockTarget
- (void)tick:(CADisplayLink*)link {
    RX_INTERVAL(frame, "clock");
    RXFrame f{CACurrentMediaTime(), link.targetTimestamp, link.duration > 0 ? link.duration : 1.0 / 60};
    static double last;
    double step = last > 0 && f.target > last && f.target - last < 0.1 ? f.target - last : f.duration;
    last = f.target;
    g_in_frame = true;
    for (size_t i = 0; i < g_tickers.size(); i++) {
        Ticker& t = g_tickers[i];
        if (!t.fn)
            continue;
        if (t.fps > 0) {
            uint32_t k = (uint32_t)std::max(1.0, std::round(1 / (step * t.fps)));
            if (++t.wait < k)
                continue;
            t.wait = 0;
        }
        __unsafe_unretained id owner = t.owner;
        t.fn(owner, &f);
    }
    g_in_frame = false;
    if (g_dirty || !g_added.empty())
        clock_retune();
}
@end

static void clock_retune(void) {
    if (g_dirty) {
        std::erase_if(g_tickers, [](const Ticker& t) { return t.fn == nullptr; });
        g_dirty = false;
    }
    for (Ticker& t : g_added) {
        auto at = std::upper_bound(g_tickers.begin(), g_tickers.end(), t.order,
                                   [](uint8_t o, const Ticker& x) { return o < x.order; });
        g_tickers.insert(at, std::move(t));
    }
    g_added.clear();
    if (!g_link)
        return;
    double rate = 0;
    for (const Ticker& t : g_tickers)
        rate = std::max(rate, t.fps > 0 ? t.fps : 120.0);
    g_link.paused = g_tickers.empty() || g_occluded;
    if (rate > 0 && rate != g_rate) {
        g_rate = rate;
        g_link.preferredFrameRateRange = CAFrameRateRangeMake((float)std::min(rate, 60.0), (float)rate, (float)rate);
    }
}

static void clock_link(NSView* hint) {
    NSWindow* w = dock_window();
    NSView* want = w ? chrome_of(w) : nil;
    NSView* linked = g_link_view;
    if (!want)
        want = linked.window ? linked : hint;
    if (!want || (g_link && want == linked && want.window))
        return;
    [g_link invalidate];
    static RXClockTarget* target = [RXClockTarget new];
    g_link = [want displayLinkWithTarget:target selector:@selector(tick:)];
    g_link_view = want;
    g_rate = 0;
    [g_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

uint32_t ui_clock_add(RXTickOrder order, double fps, id view, id owner, void (*fn)(id, const RXFrame*)) {
    clock_link([view isKindOfClass:NSView.class]                   ? view
                   : [view respondsToSelector:@selector(rootView)] ? [view rootView]
                                                                   : nil);
    uint32_t key = g_next++;
    if (!g_next)
        g_next = 1;
    Ticker t{key, (uint8_t)order, fps > 0 && fps < 120 ? fps : 0, UINT32_MAX - 1, owner, fn};
    g_added.push_back(std::move(t));
    if (!g_in_frame)
        clock_retune();
    return key;
}

void ui_clock_remove(uint32_t tick) {
    if (!tick)
        return;
    for (auto* v : {&g_tickers, &g_added}) {
        for (size_t i = 0; i < v->size(); i++) {
            Ticker& t = (*v)[i];
            if (t.key != tick)
                continue;
            if (v == &g_added) {
                v->erase(v->begin() + (ptrdiff_t)i);
                return;
            }
            if (g_in_frame) {
                t.fn = nullptr;
                g_dirty = true;
            } else {
                v->erase(v->begin() + (ptrdiff_t)i);
                clock_retune();
            }
            return;
        }
    }
}

void ui_clock_occluded(bool occluded) {
    if (g_occluded == occluded)
        return;
    g_occluded = occluded;
    if (occluded)
        engine_clock_stopped(), shaders_unlink_all();
    rexui_log_file(occluded ? @"clock: the window can't be seen: no frames till it can"
                            : @"clock: the window is seen again");
    if (!g_in_frame)
        clock_retune();
}
bool ui_clock_paused(void) {
    return !g_link || g_link.paused;
}
int ui_clock_count(RXTickOrder order) {
    int n = 0;
    for (auto* v : {&g_tickers, &g_added})
        for (const Ticker& t : *v)
            n += t.fn && t.order == order;
    return n;
}
bool ui_clock_occluded_now(void) {
    return g_occluded;
}

void ui_clock_rate(uint32_t tick, double fps) {
    for (auto* v : {&g_tickers, &g_added})
        for (Ticker& t : *v)
            if (t.key == tick && t.fn)
                t.fps = fps > 0 && fps < 120 ? fps : 0;
    if (!g_in_frame)
        clock_retune();
    else
        g_dirty = true;
}
