// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include "base/rxname.h"

static inline NSDictionary* dict_of(id x) {
    return [x isKindOfClass:NSDictionary.class] ? x : nil;
}
static inline NSString* string_of(id x) {
    return [x isKindOfClass:NSString.class] ? x : nil;
}
static inline NSArray* array_of(id x) {
    return [x isKindOfClass:NSArray.class] ? x : nil;
}
static inline bool truthy_of(id x) {
    if ([x isKindOfClass:NSNumber.class]) {
        const double d = [x doubleValue];
        return d == d && d != 0;
    }
    if ([x isKindOfClass:NSString.class])
        return [x length] > 0;
    return x && x != NSNull.null;
}
static inline bool truthy_of(id x, bool otherwise) {
    return x && x != NSNull.null ? truthy_of(x) : otherwise;
}
static inline double num_of(id x, double otherwise = 0) {
    return [x isKindOfClass:NSNumber.class] || [x isKindOfClass:NSString.class] ? [x doubleValue] : otherwise;
}
static inline int int_of(id x, int otherwise = 0) {
    return [x isKindOfClass:NSNumber.class] || [x isKindOfClass:NSString.class] ? [x intValue] : otherwise;
}

enum class Corner { top_left, top_right, bottom_left, bottom_right, center };
enum class WebResize { steps, stretch, live };

struct Config {
    bool transparency = true;
    double opacity = 0.85;
    int blur = 0;
    bool traffic_lights = false;
    bool tab_bar = false;
    bool session_keys = true;
    bool pane_buttons = true;
    bool pane_scrollbars = true;
    bool pane_scroll_smooth = true;
    double pane_scroll_lines = 3;
    double pane_scroll_ms = 150;
    double pane_scroll_trackpad_ms = 40;
    double pane_scroll_speed = 1;
    bool pane_scroll_bounce = true;
    double pane_scroll_bounce_size = 80;
    double pane_scroll_bounce_spring[2] = {11, 0.72};
    bool ui = true;
    bool power_saving = true;
    bool lazy_layers = false;
    double budget_engine_ms = 20;
    double budget_layers = 4000;
    int shader_pacing = 0;
    double pane_shader_unfocused_fps = 0;
    CGFloat left = 0, right = 0, top = 10, bottom = 0;
    NSString* gif;
    bool gif_visible = true;
    CGFloat gif_height = 160, gif_margin = 16;
    double gif_opacity = 1;
    Corner gif_corner = Corner::bottom_right;
    bool tab_slide = true;
    double tab_slide_ms = 300;
    bool tab_slide_vertical = false;
    double tab_slide_curve[4] = {0.05, 0.9, 0.1, 1.05};
    int pane_motion = 1;
    bool focus_ring = true;
    bool link_in_pane = true;
    bool pane_web_focus = true;
    bool pane_resize = true;
    NSArray<NSString*>* pane_inherit = @[];
    bool pane_glide = true;
    double pane_glide_ms = 300;
    double pane_glide_curve[4] = {0.05, 0.9, 0.1, 1.05};
    bool pane_drag = true;
    NSEventModifierFlags pane_drag_modifier = NSEventModifierFlagCommand;
    bool pane_drag_dry_run = false;
    bool pane_lane = true;
    bool web_scrollbars = true;
    WebResize web_resize = WebResize::steps;
    bool pane_keep = false;
    bool pane_drop_links = false;
    bool rex_sidebar = false;
    NSString* quit_key = @"";
    NSString* pane_fullscreen_key = @"cmd+shift+f";
    bool pane_raw_mouse = true;
    double pane_raw_mouse_scale = 1;
    double tab_preview_zoom = 1.5;
    NSString* language = @"auto";
    NSArray<NSString*>* locales = @[];
    bool single_window = true;
    NSString* cursor = @"";
    double cursor_size = 32;
    double cursor_fps = 15;
    NSString* app_icon = @"";
    double app_icon_fps = 8;
    NSString* loading_screen = @"";
    double loading_max = 15;
    NSString* notifications = @"rex";
    NSString* rex_windows = @"rex";
    NSString* file_manager = @"finder";
    NSString* notifications_system = @"inactive";
    NSDictionary<NSString*, NSString*>* values = @{};
};
extern Config g_config;
extern uint64_t g_config_generation;

bool load_config(void);

NSString* rexui_suite(void);

NSString* ui_dir(void);

struct Insets {
    CGFloat left = 0, top = 0, right = 0, bottom = 0;
};

void chrome_relayout(void);
void chrome_glide_panes(double ms, const double* curve);
bool chrome_theme(double rgb[3]);
NSView* chrome_of(NSWindow* w);
bool is_rex_window(NSWindow* w);
void chrome_reload_config(void);
bool pane_target_aim(NSPoint screen);
NSDictionary* pane_target_end(void);

NSData* json_data(id obj, NSJSONWritingOptions options);
NSString* json_string(id obj, NSJSONWritingOptions options);

void rexui_log(NSString* msg);
void rexui_watchdog_start(void);
void rexui_log_file(NSString* msg);
extern void (*rexui_log_tap)(NSString* msg);

void panes_init(void);
void panes_config_changed(void);
NSArray<NSDictionary*>* panes_rex_bindings(void);
void ui_keys_changed(void);
bool panes_event(NSEvent* e);
CALayer* ui_full_cover(NSWindow* w, bool on);
NSView* ui_full_root(NSWindow* w);
bool ui_root_takes(NSWindow* w, NSPoint win);
void ui_full_reveal(NSWindow* w, bool on);
bool panes_full_opaque(NSWindow* w);
void panes_full_hole(NSString* spec);
bool panes_ui_over(void);
void panes_drawers_changed(bool any_open);
bool panes_full_input(NSEvent* e);
bool panes_full_in(NSWindow* w);
bool panes_file_full_in(NSWindow* w);
bool panes_rex_key(NSEvent* e);
bool panes_set_full(NSString* block, int on);
bool panes_app_full(NSString* block);
void panes_leave_full(NSWindow* w, NSString* why);
bool term_full_in(NSWindow* w);
bool term_full_toggle(NSWindow* w);
void term_full_leave(NSWindow* w, NSString* why, bool unzoom);
void term_full_zoom(NSString* zoomed);
bool panes_has_pointer(NSWindow* w, NSPoint p);
void panes_hold_pointer(bool hold);
void panes_pane_framed(NSView* pane);
NSCursor* panes_cursor_here(void);
void rex_border_changed(CAShapeLayer* l);
bool rex_border_drops(CALayer* l, CAAnimation* anim);
void pane_mask_changed(CALayer* l);
void pane_styles_wake(void);
bool panes_owns_layer(CALayer* layer);
void panes_attach_soon(void);
NSDictionary* panes_last_block(void);

void ui_init(void);

void windows_doc_loaded(id doc);
void windows_config_changed(void);
bool windows_delegated(void);
NSString* windows_ask(NSDictionary* info);
void windows_held(NSDictionary* info);
id windows_native(NSString* op, NSDictionary* args);
bool rex_window_open(NSString* id);
void diagnostics_update(void);
void files_init(void);
NSString* panes_block_at(NSWindow* w, NSPoint win);
bool panes_file_in(NSView* surface);
bool panes_app_at(NSWindow* w, NSPoint win, NSArray<NSString*>* drop);
bool files_image(NSString* source, void (^done)(NSData* png));
bool files_route_url(NSURL* url);
void diagnostics_doc_loaded(id doc);
void notices_init(void);
void notices_config_changed(void);
void notices_doc_loaded(id doc);
id notices_native(NSString* op, NSDictionary* args);
void notices_post(NSString* title, NSString* body);
void activity_update(void);
void activity_hurry(void);
void rex_watch_start(void);
void activity_rex_event(bool connected);
void tabs_rex_event(bool connected);
void sessions_changed(void);
void tabs_key(NSEvent* e);
bool tabs_key_switches(NSEvent* e);
bool tabs_zoom_key(NSEvent* e);
void pointer_still_hold(void);
void keys_trace(NSString* why);
id ui_keys_note(NSResponder* fr);
bool ui_keys_restore(id note, NSWindow* w);
bool web_takes_key(NSEvent* e);
bool sessions_key(NSEvent* e);
void tabs_keys_changed(void);
void panes_keys_changed(void);
void rexstate_rex_event(bool connected);
void rexstate_layout_dirty(void);
void pane_styles_rex_event(bool connected);
void term_tabs_rex_event(void);
CALayer* term_tab_layer(NSString* id);
CALayer* term_block_layer(NSString* block);
CALayer* term_block_clip(NSString* block);
bool term_block_drawn(NSString* block);
bool term_block_hot(NSString* block);
NSString* term_pane_blank(CALayer* pane);
NSString* term_tab_blank(CALayer* tab);
void term_full_block(NSString* block);
void term_tab_watch(CALayer* tab, bool on);
void term_tabs_config_changed(void);
NSArray<NSDictionary*>* term_preview_panes(void);
NSDictionary* term_arrived_tab(void);
void links_init(void);
NSEvent* links_event(NSEvent* e);
void activity_doc_loaded(id doc);
NSString* activity_status_of(NSString* block);
id activity_native(NSString* op, NSDictionary* args);
void icon_set(NSString* path);
bool ui_key(NSEvent* e);
void ui_pointer_event(NSEvent* e);
void ui_pointer_feed(NSView* chrome);
bool ui_event(NSEvent* e);
bool ui_press_event(NSEvent* e);
int ui_clicks(NSEvent* e);
void use_cursor(NSCursor* c);
id ui_top_at(NSWindow* w, NSPoint win);
void term_live_begin(NSString* session, NSMapTable<NSString*, NSView*>* panes);
void term_live_frame(void);
void term_live_end(double delay);
bool ui_host_under_pointer(void);
void ui_pointer_refresh(void);
extern bool g_panes_instant;
Insets ui_layout_docks(NSView* chrome, NSRect area);
NSView* ui_loading_cover(NSView* chrome);
bool ui_owns_layer(CALayer* layer);
bool ui_is_dock(NSView* view);
void ui_first_responder(NSWindow* w, NSResponder* r);
void ui_theme_changed(void);
NSWindow* ui_dock_window(void);
typedef struct {
    double now;
    double target;
    double duration;
} RXFrame;
typedef enum {
    RX_TICK_APPLY = 0,
    RX_TICK_ANIM,
    RX_TICK_NODE,
    RX_TICK_SCROLL,
    RX_TICK_PANES,
    RX_TICK_METER
} RXTickOrder;
uint32_t ui_clock_add(RXTickOrder order, double fps, id view, id owner, void (*fn)(id owner, const RXFrame* f));
void ui_clock_remove(uint32_t tick);
void ui_clock_rate(uint32_t tick, double fps);
NSColor* ui_accent(void);
void ui_tabs_changed(int active, NSArray<NSString*>* titles);
void ui_tabs_changed_shown(int active, NSArray<NSString*>* titles);
void ui_session_changed(NSString* session_id, NSString* label, NSArray<NSDictionary*>* sessions);
void ui_config_changed(void);
id ui_pane_open(NSString* path, NSString* block, NSArray<NSString*>* args, NSString* program);
NSString* ui_web_pane_file(void);
NSView* ui_pane_view(id doc);
void ui_pane_layout(id doc, NSRect bounds);
void ui_pane_close(id doc);
void web_pane_pictures(id doc, bool lent, bool drawn);
NSView* web_pane_page(id doc);
bool ui_command(NSString* name);

void rex_original(NSString* what);
NSData* rex_cli(NSArray<NSString*>* args, NSString** error);
bool ui_key_matches(NSString* spec, NSEvent* e);
bool rex_method_ok(id method);
NSString* panes_block_of_doc(id doc);
id panes_doc_of_block(NSString* block);
double panes_app_quitting(NSString* block);
bool panes_app_drawn(NSString* block);
NSString* panes_app_of_block(NSString* block);
bool panes_app_covers(NSString* block);
void rex_run(NSString* action, NSDictionary* args);
void rex_close_tab(int index);
void rex_close_session(NSString* session_id);
bool rex_menu(NSArray* path);
NSDictionary<NSString*, NSString*>* menu_shortcuts(void);
NSArray<NSString*>* rex_menu_checked(NSArray* path);
