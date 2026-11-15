// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "chrome/chrome.h"
#include "rex/rex.h"

#include <dlfcn.h>
#include <vector>

static void find_tab_items(NSView* view, NSMutableArray<NSView*>* out) {
    for (NSView* sub in view.subviews) {
        if ([sub isKindOfClass:tabitem_class()]) {
            if (!sub.hidden)
                [out addObject:sub];
        } else {
            find_tab_items(sub, out);
        }
    }
}

static NSArray<NSDictionary*>* g_sessions = @[];
static NSString *g_window_title, *g_last_session, *g_session_id_now;
static bool g_listing, g_stale = true, g_relist;
static double g_listed = -100;

static void poll_session(NSWindow* w);

static void list_sessions(void) {
    g_listing = true;
    g_stale = false;
    g_listed = CACurrentMediaTime();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData* data = rex_cli(@[@"session", @"ls", @"--json"], nil);
        NSDictionary* all = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSMutableArray* list = nil;
        if ([all isKindOfClass:NSDictionary.class] && [all[@"sessions"] isKindOfClass:NSArray.class]) {
            list = [NSMutableArray array];
            for (NSDictionary* s in all[@"sessions"]) {
                if (![s isKindOfClass:NSDictionary.class] || ![s[@"session_id"] isKindOfClass:NSString.class])
                    continue;
                NSString* label = [s[@"label"] isKindOfClass:NSString.class] ? s[@"label"] : @"";
                if ([label hasPrefix:@"rexui-"])
                    continue;
                [list addObject:@{@"id": s[@"session_id"], @"label": label}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            g_listing = false;
            if (g_relist) {
                g_relist = false;
                list_sessions();
            }
            if (!list || [list isEqualToArray:g_sessions])
                return;
            g_sessions = list;
            g_last_session = nil;
            poll_session(ui_dock_window());
        });
    });
}

extern "C" long rex_session_index(const char* description) {
    NSString* d = @(description);
    for (NSUInteger i = 0; i < g_sessions.count; i++) {
        if ([d rangeOfString:g_sessions[i][@"id"] options:NSCaseInsensitiveSearch].location != NSNotFound)
            return long(i);
    }
    return -1;
}

void sessions_changed(void) {
    if (g_listing)
        g_relist = true;
    else
        list_sessions();
}

static NSString* window_title(NSWindow* w) {
    NSString* t = w.title ?: @"";
    if ([t rangeOfString:@" - "].location != NSNotFound)
        return t;
    NSString* ax = w.accessibilityTitle;
    return [ax isKindOfClass:NSString.class] && ax.length ? ax : t;
}

static void poll_session(NSWindow* w) {
    NSString* title = window_title(w);
    if (![title isEqualToString:g_window_title]) {
        g_window_title = title;
        g_stale = true;
    }
    double now = CACurrentMediaTime();
    if (!g_listing && ((g_stale && now - g_listed > 0.25) || now - g_listed > 30))
        list_sessions();
    NSDictionary* found = nil;
    for (NSDictionary* s in g_sessions) {
        NSString* label = s[@"label"];
        if (!label.length || label.length <= [found[@"label"] length])
            continue;
        if ([title isEqualToString:label] || [title hasSuffix:[@" - " stringByAppendingString:label]])
            found = s;
    }
    NSString* label = found[@"label"];
    if (!found && !g_sessions.count) {
        NSRange r = [title rangeOfString:@" - " options:NSBackwardsSearch];
        label = r.location == NSNotFound ? @"" : [title substringFromIndex:NSMaxRange(r)];
    }
    NSString* key = [NSString stringWithFormat:@"%@\n%@", found[@"id"] ?: @"", label ?: @""];
    if ([key isEqualToString:g_last_session])
        return;
    g_last_session = key;
    g_session_id_now = found[@"id"];
    ui_session_changed(found[@"id"] ?: @"", label ?: @"", g_sessions);
}

static int g_last_tab = -1;
static NSArray<NSString*>* g_last_titles;
static int g_shown_tab;

static constexpr double k_predict_hold = 0.3;
static double g_predicted_at = -1;
enum class TabAct : uint8_t { go, next, previous };
struct TabKey {
    uint16_t code;
    unichar ch;
    uint8_t mods;
    TabAct act;
    int index;
};
static std::vector<TabKey> g_tab_keys;
static std::vector<TabKey> g_zoom_keys;
static bool g_tab_keys_read;
static bool g_rex_session_digit[10];

static bool rex_chord(NSString* spec, TabKey* out) {
    NSArray<NSString*>* parts = [spec componentsSeparatedByString:@"+"];
    NSString* key = parts.lastObject;
    if (!key.length && parts.count >= 2)
        key = @"+";
    NSEventModifierFlags m = 0;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        NSString* p = parts[i].lowercaseString;
        if ([p isEqual:@"cmd"] || [p isEqual:@"super"] || [p isEqual:@"command"])
            m |= NSEventModifierFlagCommand;
        else if ([p isEqual:@"ctrl"] || [p isEqual:@"control"])
            m |= NSEventModifierFlagControl;
        else if ([p isEqual:@"alt"] || [p isEqual:@"opt"] || [p isEqual:@"option"])
            m |= NSEventModifierFlagOption;
        else if ([p isEqual:@"shift"])
            m |= NSEventModifierFlagShift;
        else if (p.length)
            return false;
    }
    out->mods = (uint8_t)(m >> 16);
    out->code = 0xFFFF;
    out->ch = 0;
    static const uint16_t digits[10] = {29, 18, 19, 20, 21, 23, 22, 26, 28, 25};
    if (key.length == 8 && [key hasPrefix:@"[Digit"] && [key hasSuffix:@"]"]) {
        unichar d = [key characterAtIndex:6];
        if (d < '0' || d > '9')
            return false;
        out->code = digits[d - '0'];
        return true;
    }
    NSDictionary<NSString*, NSNumber*>* named = @{
        @"tab": @48,
        @"pageup": @116,
        @"pagedown": @121,
        @"left": @123,
        @"right": @124,
        @"down": @125,
        @"up": @126,
        @"space": @49,
        @"enter": @36,
        @"return": @36,
        @"escape": @53,
        @"esc": @53
    };
    if (NSNumber* c = named[key.lowercaseString]) {
        out->code = c.unsignedShortValue;
        return true;
    }
    if (key.length != 1)
        return false;
    out->ch = [key.lowercaseString characterAtIndex:0];
    return true;
}

void tabs_keys_changed(void) {
    g_tab_keys_read = false;
}
static void read_tab_keys(void) {
    g_tab_keys_read = true;
    g_tab_keys.clear();
    g_zoom_keys.clear();
    NSArray* bindings = (__bridge_transfer NSArray*)rex_keymap() ?: @[];
    std::fill(std::begin(g_rex_session_digit), std::end(g_rex_session_digit), false);
    static const uint16_t digit_codes[10] = {29, 18, 19, 20, 21, 23, 22, 26, 28, 25};
    const uint8_t cmd_shift = (uint8_t)((NSEventModifierFlagCommand | NSEventModifierFlagShift) >> 16);
    for (NSDictionary* b in bindings) {
        if ([b[@"mode"] length])
            continue;
        for (NSString* spec in [b[@"keys"] isKindOfClass:NSArray.class] ? b[@"keys"] : @[]) {
            TabKey any{};
            if (![spec isKindOfClass:NSString.class] || !rex_chord(spec, &any) || any.mods != cmd_shift)
                continue;
            for (int d = 0; d < 10; d++)
                if (any.code == digit_codes[d] || any.ch == '0' + d)
                    g_rex_session_digit[d] = true;
        }
        NSString* action = b[@"action"];
        TabKey k{};
        if ([action isEqual:@"pane.zoom"]) {
            for (NSString* spec in [b[@"keys"] isKindOfClass:NSArray.class] ? b[@"keys"] : @[])
                if ([spec isKindOfClass:NSString.class] && rex_chord(spec, &k))
                    g_zoom_keys.push_back(k);
            continue;
        }
        if ([action isEqual:@"client.tab.goto"]) {
            id i = [b[@"args"] isKindOfClass:NSDictionary.class] ? b[@"args"][@"index"] : nil;
            if (![i isKindOfClass:NSNumber.class] || [i intValue] == 0)
                continue;
            k.act = TabAct::go, k.index = [i intValue];
        } else if ([action isEqual:@"client.tab.next"]) {
            k.act = TabAct::next;
        } else if ([action isEqual:@"client.tab.previous"]) {
            k.act = TabAct::previous;
        } else {
            continue;
        }
        for (NSString* spec in b[@"keys"])
            if ([spec isKindOfClass:NSString.class] && rex_chord(spec, &k))
                g_tab_keys.push_back(k);
    }
    rexui_log_file([NSString stringWithFormat:@"tabs: %zu tab keys predicted", g_tab_keys.size()]);
}

static bool chord_is(const TabKey& k, NSEvent* e) {
    uint8_t mods = (uint8_t)((e.modifierFlags
                              & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption
                                 | NSEventModifierFlagShift))
                             >> 16);
    if (k.mods != mods)
        return false;
    if (k.code != 0xFFFF)
        return k.code == e.keyCode;
    NSString* s = [e charactersByApplyingModifiers:0].lowercaseString;
    return s.length == 1 && [s characterAtIndex:0] == k.ch;
}

bool tabs_zoom_key(NSEvent* e) {
    if (e.window != ui_dock_window())
        return false;
    if (!g_tab_keys_read)
        read_tab_keys();
    for (const TabKey& k : g_zoom_keys)
        if (chord_is(k, e))
            return true;
    return false;
}

static int tab_key_to(NSEvent* e, int* from) {
    if (e.window != ui_dock_window())
        return 0;
    if (!g_tab_keys_read)
        read_tab_keys();
    if (g_tab_keys.empty())
        return 0;
    uint8_t mods = (uint8_t)((e.modifierFlags
                              & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption
                                 | NSEventModifierFlagShift))
                             >> 16);
    unichar ch = 0;
    for (const TabKey& k : g_tab_keys) {
        if (k.mods != mods)
            continue;
        if (k.code != 0xFFFF) {
            if (k.code != e.keyCode)
                continue;
        } else {
            if (!ch) {
                NSString* s = [e charactersByApplyingModifiers:0].lowercaseString;
                ch = s.length == 1 ? [s characterAtIndex:0] : 0xFFFF;
            }
            if (k.ch != ch)
                continue;
        }
        int count = (int)g_last_titles.count;
        *from = g_shown_tab > 0 ? g_shown_tab : g_last_tab;
        if (count < 1 || *from < 1)
            return 0;
        int to = k.act == TabAct::go ? (k.index > 0 ? k.index : count + 1 + k.index)
            : k.act == TabAct::next  ? *from % count + 1
                                     : (*from + count - 2) % count + 1;
        return to < 1 || to > count ? 0 : to;
    }
    return 0;
}

bool tabs_key_switches(NSEvent* e) {
    int from = 0, to = tab_key_to(e, &from);
    return to > 0 && to != from;
}

void tabs_key(NSEvent* e) {
    int from = 0, to = tab_key_to(e, &from);
    if (to < 1)
        return;
    g_predicted_at = CACurrentMediaTime();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((k_predict_hold + 0.02) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       if (CACurrentMediaTime() - g_predicted_at >= k_predict_hold)
                           poll_tabs();
                   });
    if (to == g_shown_tab)
        return;
    g_shown_tab = to;
    ui_tabs_changed_shown(to, g_last_titles);
}

bool sessions_key(NSEvent* e) {
    if (!g_config.session_keys || e.type != NSEventTypeKeyDown || e.isARepeat || e.window != ui_dock_window())
        return false;
    NSEventModifierFlags mods = e.modifierFlags
        & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption
           | NSEventModifierFlagShift);
    if (mods != (NSEventModifierFlagCommand | NSEventModifierFlagShift))
        return false;
    static const uint16_t digit_codes[10] = {29, 18, 19, 20, 21, 23, 22, 26, 28, 25};
    int d = 0;
    while (d < 10 && digit_codes[d] != e.keyCode)
        d++;
    if (d < 1 || d > 9)
        return false;
    if (!g_tab_keys_read)
        read_tab_keys();
    if (g_rex_session_digit[d])
        return false;
    NSUInteger count = g_sessions.count;
    NSUInteger i = d == 9 ? count - 1 : NSUInteger(d - 1);
    if (!count || i >= count)
        return false;
    NSString* to = string_of(dict_of(g_sessions[i])[@"id"]);
    if (!to.length)
        return false;
    if (![to isEqualToString:g_session_id_now ?: @""])
        rex_run(@"session.select", @{@"session_id": to});
    return true;
}

namespace {
using HotKeyEnable = int (*)(int, bool);
using HotKeyEnabled = bool (*)(int);
using HotKeyValue = int (*)(int, unichar*, unichar*, uint64_t*);
HotKeyEnable g_hk_set;
HotKeyEnabled g_hk_on;
HotKeyValue g_hk_value;
bool g_shots_off;
NSString* const kShotsOff = @"screenshot keys off";

bool hot_keys_found() {
    static int found = -1;
    if (found < 0) {
        g_hk_set = (HotKeyEnable)dlsym(RTLD_DEFAULT, "CGSSetSymbolicHotKeyEnabled");
        g_hk_on = (HotKeyEnabled)dlsym(RTLD_DEFAULT, "CGSIsSymbolicHotKeyEnabled");
        g_hk_value = (HotKeyValue)dlsym(RTLD_DEFAULT, "CGSGetSymbolicHotKeyValue");
        found = g_hk_set && g_hk_on && g_hk_value;
        if (!found)
            rexui_log(
                @"session keys: no way to set macOS's screenshot keys aside here: cmd+shift+3, 4 and 5 stay macOS's");
    }
    return found;
}

void shots_restore() {
    NSArray* ids = [NSUserDefaults.standardUserDefaults arrayForKey:kShotsOff];
    if (!ids.count || !hot_keys_found())
        return;
    for (NSNumber* n in ids)
        if ([n isKindOfClass:NSNumber.class])
            g_hk_set(n.intValue, true);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kShotsOff];
}

void shots_set_off(bool off) {
    if (off == g_shots_off || !hot_keys_found())
        return;
    g_shots_off = off;
    if (!off)
        return shots_restore();
    static const struct {
        int id;
        unichar code;
    } keys[] = {{28, 20}, {30, 21}, {184, 23}};
    NSMutableArray<NSNumber*>* took = [NSMutableArray array];
    for (auto k : keys) {
        unichar ch = 0, code = 0;
        uint64_t mods = 0;
        if (g_hk_value(k.id, &ch, &code, &mods) != 0 || code != k.code || !g_hk_on(k.id))
            continue;
        if ((mods
             & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl
                | NSEventModifierFlagOption))
            != (NSEventModifierFlagCommand | NSEventModifierFlagShift))
            continue;
        if (g_hk_set(k.id, false) == 0)
            [took addObject:@(k.id)];
    }
    if (took.count)
        [NSUserDefaults.standardUserDefaults setObject:took forKey:kShotsOff];
    static bool told;
    if (!told && took.count) {
        told = true;
        rexui_log([NSString stringWithFormat:@"session keys: macOS's screenshot keys on cmd+shift+3, 4, 5 (%lu of "
                                             @"them) off while Rex UI is in front",
                                             (unsigned long)took.count]);
    }
}

void shots_sync() {
    shots_set_off(g_config.session_keys && NSApp.isActive);
}
}

static void shots_start(void) {
    static bool started;
    if (started)
        return;
    started = true;
    shots_restore();
    NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName n in @[NSApplicationDidBecomeActiveNotification, NSApplicationDidResignActiveNotification])
        [nc addObserverForName:n
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification*) {
                        shots_sync();
                    }];
    [nc addObserverForName:NSApplicationWillTerminateNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) {
                    shots_set_off(false);
                }];
    shots_sync();
}

static NSArray<NSView*>* tab_items(NSWindow* w) {
    NSView* chrome = w ? chrome_of(w) : nil;
    NSView* bar = nil;
    for (NSView* v in chrome.subviews) {
        if ([v isKindOfClass:tabbar_class()])
            bar = v;
    }
    NSMutableArray<NSView*>* items = [NSMutableArray array];
    if (bar)
        find_tab_items(bar, items);
    [items sortUsingComparator:^NSComparisonResult(NSView* a, NSView* b) {
        CGFloat xa = [a convertPoint:NSZeroPoint toView:bar].x, xb = [b convertPoint:NSZeroPoint toView:bar].x;
        return xa < xb ? NSOrderedAscending : xa > xb ? NSOrderedDescending : NSOrderedSame;
    }];
    return items;
}

static NSView* find_labelled(NSView* view, NSString* label) {
    for (NSView* sub in view.subviews) {
        if ([sub.accessibilityLabel isEqualToString:label])
            return sub;
        if (NSView* v = find_labelled(sub, label))
            return v;
    }
    return nil;
}

void rex_close_tab(int index) {
    if (!tabitem_class() || !tabbar_class())
        return;
    NSArray<NSView*>* items = tab_items(ui_dock_window());
    if (index < 1 || index > (int)items.count)
        return;
    NSView* b = find_labelled(items[index - 1], @"Close Tab");
    if ([b isKindOfClass:NSControl.class] && ((NSControl*)b).action) {
        NSControl* c = (NSControl*)b;
        [c sendAction:c.action to:c.target];
        poll_tabs();
        dispatch_async(dispatch_get_main_queue(), ^{
            poll_tabs();
        });
    } else if ([b respondsToSelector:@selector(accessibilityPerformPress)] && [b accessibilityPerformPress]) {
    } else {
        rexui_log([NSString stringWithFormat:@"tabs: tab %d has no close button (%@)", index,
                                             b ? NSStringFromClass(b.class) : @"none"]);
    }
}

NSString* current_session_id(void) {
    return g_session_id_now ?: @"";
}

static double g_rendered_at;
static bool g_render_due, g_render_again;
static void render_poll(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
        poll_tabs();
        if (!g_render_again) {
            g_render_due = false;
            return;
        }
        g_render_again = false;
        render_poll();
    });
}
extern "C" void rexui_tabs_rendered(void) {
    g_rendered_at = CACurrentMediaTime();
    pane_styles_wake();
    rexstate_layout_dirty();
    if (g_render_due) {
        g_render_again = true;
        return;
    }
    g_render_due = true;
    render_poll();
}

static bool g_events, g_event_due;
static double g_event_at;
static void event_poll(double after) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        poll_tabs();
        double since = CACurrentMediaTime() - g_event_at;
        if (since < 0.6)
            return event_poll(MAX(0.15, 0.6 - since));
        g_event_due = false;
    });
}
void tabs_rex_event(bool connected) {
    if (connected && !g_events) {
        g_events = true;
        tabs_poll_start();
    }
    g_event_at = CACurrentMediaTime();
    if (g_event_due)
        return;
    g_event_due = true;
    event_poll(0.15);
}

void tabs_poll_start(void) {
    shots_start();
    static NSTimer* t;
    double every = g_rendered_at <= 0 ? 0.15 : g_events ? 5.0 : 1.0;
    if (t && t.timeInterval == every)
        return;
    [t invalidate];
    t = [NSTimer timerWithTimeInterval:every
                               repeats:YES
                                 block:^(NSTimer*) {
                                     poll_tabs();
                                 }];
    t.tolerance = every / 10;
    [NSRunLoop.mainRunLoop addTimer:t forMode:NSDefaultRunLoopMode];
    if (every > 0.15)
        return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        tabs_poll_start();
    });
}

void poll_tabs(void) {
    RX_INTERVAL(timer, "poll_tabs");
    shots_sync();
    if (!tabitem_class() || !tabbar_class())
        return;
    NSWindow* w = ui_dock_window();
    if (w)
        poll_session(w);
    NSArray<NSView*>* items = tab_items(w);
    int active = 0;
    NSMutableArray<NSString*>* titles = [NSMutableArray arrayWithCapacity:items.count];
    for (NSView* item in items) {
        [titles addObject:item.accessibilityLabel ?: @""];
        if (item.isAccessibilitySelected)
            active = int(titles.count);
    }
    bool held = g_shown_tab > 0 && CACurrentMediaTime() - g_predicted_at < k_predict_hold;
    bool same_titles = [titles isEqualToArray:g_last_titles];
    if (active == g_last_tab && same_titles && (held || active == g_shown_tab))
        return;
    bool switched = g_last_tab >= 0 && active != g_last_tab;
    g_last_tab = active;
    g_last_titles = titles;
    if (!held || active == g_shown_tab || g_shown_tab > (int)titles.count) {
        g_shown_tab = active;
        ui_tabs_changed(active, titles);
    } else if (!same_titles) {
        ui_tabs_changed_shown(g_shown_tab, titles);
    }
    if (switched && transparent()) {
        apply_all();
        dispatch_async(dispatch_get_main_queue(), ^{
            apply_all();
        });
    }
}

void dump_tabs(NSView* view, int depth) {
    NSMutableString* extra = [NSMutableString string];
    if ([view isKindOfClass:NSTextField.class])
        [extra appendFormat:@" text=\"%@\"", ((NSTextField*)view).stringValue];
    if (view.hidden)
        [extra appendString:@" hidden"];
    if (view.isAccessibilitySelected)
        [extra appendString:@" ax-selected"];
    if (NSString* l = view.accessibilityLabel)
        [extra appendFormat:@" ax-label=\"%@\"", l];
    if (id v = view.accessibilityValue)
        [extra appendFormat:@" ax-value=\"%@\"", v];
    [g_dump appendFormat:@"%*s%@ frame=%@%@\n", depth * 2, "", NSStringFromClass([view class]),
                         NSStringFromRect(view.frame), extra];
    if ([NSStringFromClass([view class]) containsString:RXNS(RXN_182)]) {
        unsigned n = 0;
        Ivar* ivars = class_copyIvarList([view class], &n);
        for (unsigned i = 0; i < n; i++) {
            const uint8_t* p = (const uint8_t*)(__bridge void*)view + ivar_getOffset(ivars[i]);
            [g_dump appendFormat:@"%*s  ivar %s @%td: %02x %02x %02x %02x %02x %02x %02x %02x\n", depth * 2, "",
                                 ivar_getName(ivars[i]), ivar_getOffset(ivars[i]), p[0], p[1], p[2], p[3], p[4], p[5],
                                 p[6], p[7]];
        }
        free(ivars);
    }
    for (NSView* sub in view.subviews)
        dump_tabs(sub, depth + 1);
}
