// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import "base/rexui.h"

#include <atomic>
#include <string_view>

#include "base/rexapi.h"
#include "core/sync/rmw.h"

namespace {

enum Kind : unsigned { k_activity = 1, k_tabs = 2, k_layout = 4, k_panes = 8, k_sessions = 16, k_all = 31 };
constexpr int k_kinds = 5;

unsigned kinds_of(std::string_view type, std::string_view name) {
    if (type.empty())
        return k_all;
    if (type == "block_event") {
        if (name == "title_changed" || name == "pwd_changed" || name == "process_changed")
            return k_activity | k_tabs;
        if (name == "program_status_changed" || name == "program_status_removed" || name == "progress_report"
            || name == "child_exited")
            return k_activity;
        return 0;
    }
    if (type == "session_view_changed")
        return k_activity | k_tabs | k_layout | k_panes;
    if (type == "session_created" || type == "session_destroyed" || type == "session_moved")
        return k_activity | k_tabs | k_panes | k_sessions;
    if (type == "block_created" || type == "block_closed" || type == "window_created" || type == "window_closed")
        return k_activity | k_tabs | k_panes;
    if (type == "session_label_changed")
        return k_activity | k_tabs | k_sessions;
    if (type == "window_label_changed")
        return k_activity | k_tabs;
    if (type == "active_window_changed")
        return k_tabs | k_layout | k_panes;
    return 0;
}

std::atomic<uint64_t> g_count[k_kinds], g_bursts;
uint64_t g_seen[k_kinds];
std::atomic<uint64_t> g_taken;
std::atomic<bool> g_connected;

void take(void);

void on_event(void*, std::string_view type, std::string_view name) {
    unsigned k = kinds_of(type, name);
    if (!k)
        return;
    if (type.empty())
        g_connected.store(true, std::memory_order_relaxed);
    for (int i = 0; i < k_kinds; i++)
        if (k & (1u << i))
            g_count[i].store(g_count[i].load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
    uint64_t n = g_bursts.load(std::memory_order_relaxed) + 1;
    g_bursts.store(n, std::memory_order_release);
    std::atomic_thread_fence(std::memory_order_seq_cst);
    if (g_taken.load(std::memory_order_relaxed) == n - 1)
        dispatch_async(dispatch_get_main_queue(), ^{
            take();
        });
}

void take(void) {
    uint64_t b;
    do {
        b = g_bursts.load(std::memory_order_acquire);
        g_taken.store(b, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_seq_cst);
    } while (g_bursts.load(std::memory_order_relaxed) != b);
    unsigned changed = 0;
    for (int i = 0; i < k_kinds; i++) {
        uint64_t c = g_count[i].load(std::memory_order_relaxed);
        if (c != g_seen[i])
            g_seen[i] = c, changed |= 1u << i;
    }
    bool connected = rx::sync::exchange(g_connected, false, std::memory_order_relaxed);
    if (connected)
        rexui_log_file(@"rex events: watching Rex Server's events (activity, tabs, layout and panes follow them)");
    if (changed & k_activity)
        activity_rex_event(connected);
    if (changed & k_tabs)
        tabs_rex_event(connected);
    if (changed & k_layout)
        rexstate_rex_event(connected);
    if (changed & k_panes)
        pane_styles_rex_event(connected);
    if (changed & k_sessions)
        sessions_changed();
}

}

void rex_watch_start(void) {
    static bool started;
    if (started)
        return;
    started = true;
    if (!rx::rexapi::watch(on_event, nullptr))
        rexui_log(@"rex events: no thread for the watch: activity and tabs are polled");
}
