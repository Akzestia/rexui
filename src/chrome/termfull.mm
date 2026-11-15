// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "chrome/chrome.h"
#include "rex/rex.h"

static struct {
    __weak NSWindow* window;
    NSString *session, *tab;
    NSString* block;
    bool zoomed;
    bool seen;
    double since;
    NSArray<CALayer*>* hidden;
    bool asking;
} g_tf;

static id api(NSString* session, NSString* method, NSDictionary* args) {
    NSString* json = [[NSString alloc] initWithData:json_data(args ?: @{}, NSJSONWritingSortedKeys)
                                           encoding:NSUTF8StringEncoding];
    NSString* error = nil;
    NSData* out = rex_cli(@[@"api", @"call", @"-s", session, method, json], &error);
    if (!out) {
        rexui_log([NSString
            stringWithFormat:@"term full: %@ %@: %@", method, json,
                             [error stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]);
        return nil;
    }
    return [NSJSONSerialization JSONObjectWithData:out options:0 error:nil] ?: @{};
}

static dispatch_queue_t calls(void) {
    static dispatch_queue_t q = dispatch_queue_create("rexui.term-full", DISPATCH_QUEUE_SERIAL);
    return q;
}

bool term_full_in(NSWindow* w) {
    NSWindow* on = g_tf.window;
    return on && (!w || on == w);
}

bool term_full_frame(NSView* chrome, NSRect* to) {
    if (!term_full_in(chrome.window))
        return false;
    double i[4] = {0, 0, 0, 0};
    rex_pane_insets(i);
    NSRect b = chrome.bounds;
    *to = NSMakeRect(b.origin.x - i[1], b.origin.y - i[0], b.size.width + i[1] + i[3], b.size.height + i[0] + i[2]);
    return true;
}

static void hide_round(NSWindow* w) {
    NSView *chrome = chrome_of(w), *content = chrome ? chrome_content(chrome) : nil;
    if (!content)
        return;
    CALayer* frameLayer = (w.contentView.superview ?: w.contentView).layer;
    NSMutableSet* spare = [NSMutableSet set];
    for (CALayer* l = ui_full_root(w).layer; l && l != frameLayer; l = l.superlayer)
        [spare addObject:l];
    NSMutableArray* hid = [NSMutableArray array];
    for (CALayer* keep = content.layer; keep && keep != frameLayer; keep = keep.superlayer) {
        for (CALayer* l in keep.superlayer.sublayers) {
            if (l == keep || [spare containsObject:l] || l.hidden)
                continue;
            id d = l.delegate;
            if (![d isKindOfClass:NSView.class])
                continue;
            NSRect f = [(NSView*)d convertRect:((NSView*)d).bounds toView:nil], wb = {NSZeroPoint, w.frame.size};
            NSRect in = NSIntersectionRect(f, wb);
            double area = in.size.width * in.size.height;
            if (area < 1 || area >= 0.9 * wb.size.width * wb.size.height)
                continue;
            l.hidden = YES;
            [hid addObject:l];
        }
    }
    g_tf.hidden = hid;
    NSMutableArray* names = [NSMutableArray array];
    for (CALayer* l in hid) {
        id d = l.delegate;
        [names
            addObject:[NSString stringWithFormat:@"%@%@ %.0fx%.0f", NSStringFromClass(l.class),
                                                 d ? [@"/" stringByAppendingString:NSStringFromClass([d class])] : @"",
                                                 l.bounds.size.width, l.bounds.size.height]];
    }
    rexui_log_file([NSString stringWithFormat:@"term full: hid %@", [names componentsJoinedByString:@"; "]]);
}

static void apply(NSWindow* w, NSString* session, NSString* tab, NSString* block, bool zoomed) {
    if (!w || g_tf.window)
        return;
    g_tf.window = w;
    g_tf.session = session, g_tf.tab = tab, g_tf.block = block;
    g_tf.zoomed = zoomed, g_tf.seen = false;
    g_tf.since = CACurrentMediaTime();
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    ui_full_cover(w, true);
    hide_round(w);
    [CATransaction commit];
    chrome_relayout();
    if (NSView* chrome = chrome_of(w))
        [chrome layoutSubtreeIfNeeded];
    rexui_log([NSString stringWithFormat:@"term full: %@ over the whole window%@", block, zoomed ? @" (zoomed)" : @""]);
}

void term_full_leave(NSWindow* w, NSString* why, bool unzoom) {
    NSWindow* on = g_tf.window;
    if (!on || (w && w != on))
        return;
    pointer_still_hold();
    keys_trace(@"a terminal gives the window back");
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer* l in g_tf.hidden)
        l.hidden = NO;
    ui_full_cover(on, false);
    [CATransaction commit];
    g_tf.hidden = nil;
    g_tf.window = nil;
    NSString *session = g_tf.session, *tab = g_tf.tab;
    if (unzoom && g_tf.zoomed && session.length && tab.length) {
        dispatch_async(calls(), ^{
            api(session, @"session.zoom_block", @{@"window_id": tab, @"zoom": @NO});
        });
    }
    chrome_relayout();
    if (NSView* chrome = chrome_of(on))
        [chrome layoutSubtreeIfNeeded];
    rexui_log([NSString stringWithFormat:@"term full: %@ gives the window back (%@)", g_tf.block, why]);
}

bool term_full_toggle(NSWindow* w) {
    if (term_full_in(w)) {
        term_full_leave(w, @"the key", true);
        return true;
    }
    NSString* session = current_session_id();
    if (!w || !session.length || g_tf.asking || g_tf.window)
        return false;
    g_tf.asking = true;
    __weak NSWindow* ww = w;
    dispatch_async(calls(), ^{
        NSDictionary* view = api(session, @"session.view", nil);
        NSDictionary* shown = nil;
        for (NSDictionary* t in [view isKindOfClass:NSDictionary.class] ? view[@"windows"] : nil)
            if ([t isKindOfClass:NSDictionary.class] && [t[@"window_id"] isEqual:view[@"active_window_id"]])
                shown = t;
        NSString* tab = [shown[@"window_id"] isKindOfClass:NSString.class] ? shown[@"window_id"] : nil;
        NSString* block = [shown[@"focused_block_id"] isKindOfClass:NSString.class] ? shown[@"focused_block_id"] : nil;
        id z = shown[@"zoomed_block_id"];
        bool zoom = block && ![z isEqual:block];
        if (zoom && !api(session, @"session.zoom_block", @{@"block_id": block, @"zoom": @YES}))
            zoom = false, block = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            g_tf.asking = false;
            if (!block || !tab) {
                rexui_log(@"term full: no focused pane in the shown tab");
                return;
            }
            apply(ww, session, tab, block, zoom);
        });
    });
    return true;
}

void term_full_zoom(NSString* zoomed) {
    if (!g_tf.window)
        return;
    NSString* b = g_tf.block;
    NSString* uuid = [b hasPrefix:@"block:"] ? [b substringFromIndex:6] : b;
    bool on = zoomed.length && uuid.length && [zoomed containsString:uuid];
    if (on) {
        g_tf.seen = true;
        return;
    }
    if (g_tf.seen)
        term_full_leave(nil, @"Rex's zoom ended", false);
    else if (CACurrentMediaTime() - g_tf.since > 2)
        term_full_leave(nil, @"Rex's zoom never came", true);
}

extern "C" bool rexui_term_full_toggle(void) {
    return term_full_toggle(ui_dock_window());
}
extern "C" bool rexui_term_full_on(void) {
    return term_full_in(nil);
}

static NSView* pane_view(NSWindow* w) {
    NSView *chrome = chrome_of(w), *content = chrome ? chrome_content(chrome) : nil;
    void* raw = content ? rex_panes((__bridge const void*)content) : nullptr;
    NSDictionary* panes = raw ? (__bridge_transfer NSDictionary*)raw : nil;
    id v = panes[g_tf.block];
    return [v isKindOfClass:NSView.class] ? v : nil;
}

extern "C" int rexui_term_full_stray_hits(int* routed) {
    NSWindow* w = g_tf.window;
    NSView* pane = w ? pane_view(w) : nil;
    if (!pane)
        return -1;
    NSView* frame = w.contentView.superview ?: w.contentView;
    int stray = 0;
    *routed = 0;
    for (int i = 0; i < 9; i++)
        for (int j = 0; j < 9; j++) {
            NSPoint p = NSMakePoint(w.frame.size.width * (i + 0.5) / 9, w.frame.size.height * (j + 0.5) / 9);
            NSView* hit = [frame hitTest:frame.superview ? [frame.superview convertPoint:p fromView:nil] : p];
            if (hit && [hit isDescendantOf:pane])
                continue;
            stray++;
            if (!ui_root_takes(w, p))
                (*routed)++;
        }
    return stray;
}
