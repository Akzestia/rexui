// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include "base/rexui.h"

#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <algorithm>
#include <initializer_list>
#include <vector>

extern bool g_debug;
extern bool g_debug_clears;
extern NSMutableString* g_dump;
extern NSHashTable<CALayer*>* g_backgrounds;
extern NSMapTable<CALayer*, id>* g_saved_bg;
extern NSMapTable<CALayer*, id>* g_saved_fill;
extern NSMutableSet<CALayer*>* g_dirty;
size_t watched_count(void);
bool watched_due(void);
void transform_set(void);
extern void (*orig_set_transform)(id, SEL, CATransform3D);
extern void (*orig_set_sublayer_transform)(id, SEL, CATransform3D);
extern void (*orig_set_affine_transform)(id, SEL, CGAffineTransform);
void hook_set_transform(CALayer* self, SEL sel, CATransform3D t);
void hook_set_sublayer_transform(CALayer* self, SEL sel, CATransform3D t);
void hook_set_affine_transform(CALayer* self, SEL sel, CGAffineTransform t);
extern bool g_log_misses;
extern NSColor* g_window_bg;
extern double g_theme_rgb[3];
extern NSMapTable<NSWindow*, NSValue*>* g_pane_area;
extern void (*orig_set_background)(id, SEL, CGColorRef);
extern void (*orig_set_fill)(id, SEL, CGColorRef);
extern void (*orig_set_bounds)(id, SEL, CGRect);
extern void (*orig_cursor_set)(id, SEL);
extern void (*orig_section_pending)(id, SEL);
void hook_section_pending(id self, SEL sel);
void hook_cursor_set(NSCursor* self, SEL sel);
extern bool g_cursor_direct;
NSCursor* cursor_themed(NSCursor* c);
void icon_init(void);
void icon_config_changed(void);
void sidebar_off(void);
void cursor_config_changed(void);
NSString* cursor_describe(void);
extern void (*orig_add_animation)(id, SEL, CAAnimation*, NSString*);
extern void (*orig_set_clear)(id, SEL, MTLClearColor);
extern void (*orig_window_set_background)(id, SEL, NSColor*);
extern void (*orig_set_frame)(id, SEL, CGRect);
extern void (*orig_set_path)(id, SEL, CGPathRef);
extern void (*orig_add_sublayer)(id, SEL, CALayer*);
extern void (*orig_insert_at)(id, SEL, CALayer*, unsigned);
extern void (*orig_insert_below)(id, SEL, CALayer*, CALayer*);
extern void (*orig_insert_above)(id, SEL, CALayer*, CALayer*);
extern void (*orig_replace_sublayer)(id, SEL, CALayer*, CALayer*);
extern void (*orig_set_opaque)(id, SEL, BOOL);
extern void (*orig_backdrop_set_hidden)(id, SEL, BOOL);
extern void (*orig_tabbar_set_hidden)(id, SEL, BOOL);
extern void (*orig_actions_set_hidden)(id, SEL, BOOL);
extern void (*orig_actions_did_move)(id, SEL);
extern void (*orig_chrome_layout)(id, SEL);
extern NSMutableArray<NSString*>* g_clears;

bool has_color(CGColorRef c);
bool is_background(CALayer* layer);
bool transparent(void);
bool arm_commit(void);
void mark_dirty(CALayer* layer);

NSString* debug_path(NSString* name);

void swizzle(Class cls, SEL sel, IMP hook, IMP* orig);

void install_command_hooks(void);
extern "C" void rexui_lend_settings(double seconds, void (^take)(NSWindow* w));
extern "C" void rexui_settings_back(void);
id saved(CGColorRef c);
CGColorRef unsaved(id v);
void hook_set_background(CALayer* self, SEL sel, CGColorRef c);
void hook_set_fill(CAShapeLayer* self, SEL sel, CGColorRef c);
void hook_set_bounds(CALayer* self, SEL sel, CGRect r);
extern void (*orig_set_shadow_opacity)(id, SEL, float);
void hook_set_shadow_opacity(CALayer* self, SEL sel, float v);
void restore_shadows(void);
void hook_set_frame(CALayer* self, SEL sel, CGRect r);
void hook_set_path(CAShapeLayer* self, SEL sel, CGPathRef p);
extern void (*orig_set_mask)(id, SEL, CALayer*);
void hook_set_mask(CALayer* self, SEL sel, CALayer* mask);
void hook_add_animation(CALayer* self, SEL sel, CAAnimation* anim, NSString* key);
void hook_add_sublayer(CALayer* self, SEL sel, CALayer* l);
void hook_insert_at(CALayer* self, SEL sel, CALayer* l, unsigned i);
void hook_insert_below(CALayer* self, SEL sel, CALayer* l, CALayer* sib);
void hook_insert_above(CALayer* self, SEL sel, CALayer* l, CALayer* sib);
void hook_replace_sublayer(CALayer* self, SEL sel, CALayer* old, CALayer* l);
void hook_set_opaque(CALayer* self, SEL sel, BOOL opaque);
bool wants_hidden(NSView* v);
void hook_backdrop_set_hidden(NSView* self, SEL sel, BOOL hidden);
void hook_tabbar_set_hidden(NSView* self, SEL sel, BOOL hidden);
void hook_actions_set_hidden(NSView* self, SEL sel, BOOL hidden);
void hook_actions_did_move(NSView* self, SEL sel);
extern void (*orig_set_has_scroller)(id, SEL, BOOL);
void hook_set_has_scroller(NSScrollView* self, SEL sel, BOOL has);
void apply_scroller(NSScrollView* view);
Class actions_class(void);
Class backdrop_class(void);
Class tabbar_class(void);
Class tabitem_class(void);
Class chrome_class(void);
Class divider_class(void);
Class term_scroll_class(void);

void update_gif(NSView* chrome, NSRect area);

void hook_chrome_layout(NSView* self, SEL sel);
NSView* chrome_content(NSView* chrome);

void poll_tabs(void);
void tabs_poll_start(void);
NSString* current_session_id(void);
void sessions_changed(void);

void hook_window_set_background(NSWindow* self, SEL sel, NSColor* c);
void update_window_bg(void);
void tint_window(NSWindow* w);
void hook_other_clear_classes(Class done);
void hook_set_clear(id self, SEL sel, MTLClearColor c);

void restore_backgrounds(void);
void process_dirty(bool watched);

void dump_tabs(NSView* view, int depth);

void apply_all(void);

void each_commit(bool (^f)(void));
void motion_config(void);
void glide_before(NSView* chrome, NSView* content, NSRect to);
void glide_panes_from_now(NSView* chrome, NSView* content, double wait_s, bool others, CGRect from,
                          NSView* (^arriving)(void), void (^unlift)(bool landed));
void glide_panes_abandon(void);
void motion_watch(NSView* content);
void motion_frame_filter(NSRect (^f)(NSView* v, NSRect asked));

void scroll_install(void);

bool pane_drag_event(NSEvent* e);
bool pane_drag_owns(CALayer* layer);
NSCursor* pane_drag_cursor(void);

bool term_full_frame(NSView* chrome, NSRect* to);

bool pane_resize_event(NSEvent* e);
void pane_lines(NSView* v, NSMutableArray<NSView*>* out);

void send_event_on(NSEvent* e);
