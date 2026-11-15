// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

#include "rex/rex.h"

NSPoint g_context_at;
static __weak NSView* g_surface;
static bool g_swallow_up;

static NSArray<RXNode*>* takers(void) {
    NSMutableArray* out = [NSMutableArray array];
    for (RXNode* n in all_drawers()) {
        id c = obj(n, P::command);
        NSArray* names = [c isKindOfClass:NSArray.class] ? c : [c isKindOfClass:NSString.class] ? @[c] : @[];
        if ([names containsObject:@"context.menu"] && n.doc.ctx && !n.doc.pane)
            [out addObject:n];
    }
    return out;
}

static Class surface_cls(void) {
    static Class c = NSClassFromString(RXNS(RXN_165)) ?: NSClassFromString(RXNS(RXN_164));
    return c;
}

static bool agent_at(NSWindow* w, NSPoint at) {
    NSString* block = panes_block_at(w, at);
    void* raw = block ? rex_activity() : nullptr;
    if (!raw)
        return false;
    for (NSDictionary* a in (__bridge_transfer NSArray*)raw) {
        if ([a[@"block"] isEqual:block])
            return [a[@"app"] isKindOfClass:NSString.class] && [a[@"app"] length];
    }
    return false;
}

bool context_right_click(NSEvent* e) {
    NSWindow* ew = e.window;
    if (e.type == NSEventTypeRightMouseUp) {
        bool ours = g_swallow_up;
        g_swallow_up = false;
        return ours;
    }
    if (e.type != NSEventTypeRightMouseDown || !surface_cls())
        return false;
    if (panes_file_full_in(ew))
        return false;
    NSArray<RXNode*>* ns = takers();
    if (!ns.count)
        return false;
    NSView* frame = ew.contentView.superview ?: ew.contentView;
    NSView* v = frame ? [frame hitTest:e.locationInWindow] : nil;
    while (v && ![v isKindOfClass:surface_cls()])
        v = v.superview;
    if (v && panes_app_at(ew, e.locationInWindow, nil))
        return false;
    if (!v)
        return false;
    if (panes_file_in(v))
        return false;
    if (NSString* b = panes_block_at(ew, e.locationInWindow); b && panes_doc_of_block(b))
        return false;
    int state = rex_terminal_state((__bridge const void*)v);
    bool shift = e.modifierFlags & NSEventModifierFlagShift;
    if ((state & 1) && (state & 4) && !shift && !agent_at(ew, e.locationInWindow))
        return false;
    g_surface = v;
    g_context_at = e.locationInWindow;
    g_swallow_up = true;
    [v.window makeFirstResponder:v];
    NSDictionary* ctx = @{@"hasSelection": @((state & 2) != 0), @"block": panes_last_block() ?: @{}};
    for (RXNode* n in ns) {
        doc_call(n.doc, @"setContext", @[ctx]);
        n.commanded = @"context.menu";
        if (flag(n, P::open, false))
            chrome_relayout();
        drawer_open_again(n);
        doc_call(n.doc, @"emit", @[@(n.uid), @"commanded", @[@"context.menu"]]);
    }
    return true;
}

bool context_terminal(NSString* what) {
    NSView* v = g_surface;
    SEL s = [what isEqualToString:@"copy"] ? @selector(copy:)
        : [what isEqualToString:@"paste"]  ? @selector(paste:)
                                           : nullptr;
    if (!v || !s || ![v respondsToSelector:s])
        return false;
    ((void (*)(id, SEL, id))[v methodForSelector:s])(v, s, nil);
    return true;
}
