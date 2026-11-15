// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once
#import <AppKit/AppKit.h>

extern "C" {
void rex_tabs_start(void);
void rex_cache_prefetch(void);
void* rex_tab_id(long index);
void rex_slide_place(const void* chrome, const void* content);
bool rex_easing_move(const void* layer, CGRect frame, bool animated);
bool rex_easing_spring(double* out);
void* rex_panes(const void* content);
void rex_pane_insets(double* out);
void* rex_shown_tab(void);
bool rex_floating_pane(const void* content, const char* id, const void** pane, const void** layer);
bool rex_slide_busy(void);
void rex_slide_config_changed(void);
long rex_tab_count(void);
double rex_cell_height(const void* view);
int rex_terminal_state(const void* surface);
void* rex_all_panes(const void* content);
}

extern "C" {
void* rex_notice_presentation(void);
const void* rex_notice_host(void);
void rex_notice_set_wanted(bool (*wanted)(void));
void* rex_remote_notice(void);
void* rex_activity(void);
bool rex_present(const char* name);
void* rex_pending_keys(void);
void rex_wrap_closures(void);
}

extern "C" {
void* rex_layout_state(void);
void* rex_hovered_link(const void* surface);
long rex_hints_revealed(void);
double rex_time_scale(double set, bool write);
void* rex_keymap(void);
void* rex_hosts(void);
void* rex_themes(void);
bool rex_open_directory(const void* paths);
void* rex_key_layout(void);
}

extern "C" {
void* rex_glass_notice(const char* title, const char* body, const char* tone, const char* symbol, bool dismissible);
bool rex_notice_is_ours(const char* id);
long rex_mark_seen(const void* blocks);
void* rex_find_state(void);
}
