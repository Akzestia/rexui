// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "rex/stub/stub.h"
#include "chrome/chrome.h"
#include "rex/bridge.h"
#include "rex/rex.h"

#include <string.h>

static struct {
    const char* name;
    unsigned long count;
} g_calls[128];

static void note(const char* name) {
    for (auto& c : g_calls) {
        if (!c.name) {
            c.name = name;
            c.count = 1;
            return;
        }
        if (c.name == name || !strcmp(c.name, name)) {
            c.count++;
            return;
        }
    }
}

void stub_calls(void (*each)(const char* name, unsigned long count, void* ctx), void* ctx) {
    for (auto& c : g_calls)
        if (c.name)
            each(c.name, c.count, ctx);
}

#define NOTE() note(__func__)

@implementation RXHostChrome
- (BOOL)isFlipped {
    return YES;
}
- (void)layout {
    [super layout];
    NSRect area = self.bounds;
    Insets d = ui_layout_docks(self, area);
    const Config& c = g_config;
    CGFloat x = c.left + d.left, y = c.top + d.top;
    NSRect to =
        NSMakeRect(x, y, MAX(0, NSMaxX(area) - c.right - d.right - x), MAX(0, NSMaxY(area) - c.bottom - d.bottom - y));
    if (!NSEqualRects(self.panes.frame, to))
        self.panes.frame = to;
}
@end

bool is_rex_window(NSWindow* w) {
    return w && [w.identifier isEqualToString:@"rexui-host"];
}

NSView* chrome_of(NSWindow* w) {
    if (!is_rex_window(w))
        return nil;
    for (NSView* v in w.contentView.subviews)
        if ([v isKindOfClass:RXHostChrome.class])
            return v;
    return [w.contentView isKindOfClass:RXHostChrome.class] ? w.contentView : nil;
}

NSView* chrome_content(NSView* chrome) {
    return [chrome isKindOfClass:RXHostChrome.class] ? ((RXHostChrome*)chrome).panes : nil;
}

void chrome_relayout(void) {
    for (NSWindow* w in NSApp.windows)
        if (NSView* c = chrome_of(w))
            c.needsLayout = YES;
}

void chrome_glide_panes(double, const double*) {
}
void tabs_rex_event(bool) {
}
void sessions_changed(void) {
}
void tabs_key(NSEvent*) {
}
void tabs_keys_changed(void) {
}

bool chrome_theme(double rgb[3]) {
    rgb[0] = 0.11, rgb[1] = 0.11, rgb[2] = 0.13;
    return true;
}

void chrome_reload_config(void) {
    if (load_config())
        ui_config_changed();
}

void each_commit(bool (^f)(void)) {
    bool (^g)(void) = [f copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 120), dispatch_get_main_queue(), ^{
        if (g())
            each_commit(g);
    });
}

void swizzle(Class cls, SEL sel, IMP hook, IMP* orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (class_addMethod(cls, sel, hook, method_getTypeEncoding(m)))
        *orig = method_getImplementation(m);
    else
        *orig = method_setImplementation(m, hook);
}

void icon_set(NSString*) {
    NOTE();
}
bool pane_target_aim(NSPoint) {
    return false;
}
NSDictionary* pane_target_end(void) {
    return nil;
}
NSDictionary<NSString*, NSString*>* menu_shortcuts(void) {
    return @{};
}

void rex_original(NSString*) {
    NOTE();
}
NSData* rex_cli(NSArray<NSString*>* args, NSString** error) {
    NOTE();
    if (const char* f = getenv("REXUI_HOST_API");
        f && args.count >= 3 && [args[0] isEqual:@"api"] && [args[1] isEqual:@"call"]) {
        NSDictionary* replies =
            [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(f)] ?: NSData.data
                                            options:0
                                              error:nil];
        if (id r = [replies isKindOfClass:NSDictionary.class] ? replies[args[2]] : nil)
            return [NSJSONSerialization dataWithJSONObject:r options:NSJSONWritingFragmentsAllowed error:nil];
    }
    if (error)
        *error = @"no Rex in the harness";
    return nil;
}
void rex_run(NSString*, NSDictionary*) {
    NOTE();
}
void rex_close_tab(int) {
    NOTE();
}
bool rex_slide_busy(void) {
    return false;
}
void rex_close_session(NSString*) {
    NOTE();
}
bool rex_menu(NSArray*) {
    NOTE();
    return false;
}
NSArray<NSString*>* rex_menu_checked(NSArray*) {
    return nil;
}
bool rex_window_open(NSString*) {
    NOTE();
    return false;
}

static NSArray<NSDictionary*>* g_stub_bindings = @[];
NSArray<NSDictionary*>* panes_rex_bindings(void) {
    return g_stub_bindings;
}
void stub_set_bindings(NSArray<NSDictionary*>* b) {
    g_stub_bindings = b ?: @[];
}
bool panes_has_pointer(NSWindow*, NSPoint) {
    return false;
}
bool panes_full_in(NSWindow*) {
    return false;
}
bool panes_file_full_in(NSWindow*) {
    return false;
}
bool panes_rex_key(NSEvent*) {
    return false;
}
bool panes_ui_over(void) {
    return false;
}
void use_cursor(NSCursor* c) {
    if (NSCursor.currentCursor != c)
        [c set];
}
void panes_drawers_changed(bool) {
}
void panes_full_hole(NSString*) {
}
bool panes_set_full(NSString*, int) {
    return false;
}
bool panes_app_full(NSString*) {
    return false;
}
void term_full_zoom(NSString*) {
}
bool panes_app_at(NSWindow*, NSPoint, NSArray<NSString*>*) {
    return false;
}
NSDictionary* panes_last_block(void) {
    return nil;
}
void panes_attach_soon(void) {
}
void panes_keys_changed(void) {
}
NSString* panes_block_of_doc(id) {
    return nil;
}
id panes_doc_of_block(NSString*) {
    return nil;
}
bool panes_file_in(NSView*) {
    return false;
}
double panes_app_quitting(NSString*) {
    return 0;
}
bool panes_app_drawn(NSString*) {
    return false;
}
NSString* panes_app_of_block(NSString*) {
    return nil;
}
bool panes_app_covers(NSString*) {
    return false;
}

extern "C" {
void rex_slide_config_changed(void) {
}
void* rex_tab_id(long) {
    return NULL;
}
bool rex_easing_move(const void*, CGRect, bool) {
    return false;
}
bool rex_easing_spring(double*) {
    return false;
}
void* rex_shown_tab(void) {
    return NULL;
}
long rex_tab_count(void) {
    return 0;
}
int rex_terminal_state(const void*) {
    return 0;
}
void* rex_all_panes(const void*) {
    return NULL;
}
bool rex_floating_pane(const void*, const char*, const void**, const void**) {
    return false;
}

void* rex_notice_presentation(void) {
    return NULL;
}
const void* rex_notice_host(void) {
    return NULL;
}
void rex_notice_set_wanted(bool (*)(void)) {
}
void* rex_remote_notice(void) {
    return NULL;
}
void* rex_activity(void) {
    return NULL;
}
bool rex_present(const char*) {
    NOTE();
    return false;
}
void* rex_pending_keys(void) {
    return NULL;
}
void rex_wrap_closures(void) {
}

void* rex_layout_state(void) {
    return NULL;
}
void* rex_hovered_link(const void*) {
    return NULL;
}
long rex_hints_revealed(void) {
    return -1;
}
double rex_time_scale(double, bool) {
    return -1;
}
void* rex_keymap(void) {
    return NULL;
}
void* rex_hosts(void) {
    return NULL;
}
void* rex_themes(void) {
    return NULL;
}
bool rex_open_directory(const void*) {
    NOTE();
    return false;
}
void* rex_key_layout(void) {
    return NULL;
}

void* rex_glass_notice(const char*, const char*, const char*, const char*, bool) {
    NOTE();
    return NULL;
}
bool rex_notice_is_ours(const char*) {
    return false;
}
long rex_mark_seen(const void*) {
    NOTE();
    return 0;
}
void* rex_find_state(void) {
    return NULL;
}
}
