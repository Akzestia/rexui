// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import "base/rexui.h"
#import "ui/ui.h"

static NSMutableArray<NSDictionary*>* g_held;

static NSDictionary* state(void) {
    return @{@"held": [g_held copy] ?: @[], @"guarding": @([g_config.rex_windows isEqualToString:@"rexui"])};
}

static void push(void) {
    NSDictionary* s = state();
    for (RXDoc* d in [g_docs copy])
        if (d.ctx)
            doc_call(d, @"setWindows", @[s]);
}

void windows_doc_loaded(id d) {
    RXDoc* doc = d;
    if (doc.ctx)
        doc_call(doc, @"setWindows", @[state()]);
}

void windows_config_changed(void) {
    push();
}

bool windows_delegated(void) {
    for (RXDoc* d in g_docs)
        if (d.window_delegate && d.ctx)
            return true;
    return false;
}

NSString* windows_ask(NSDictionary* info) {
    for (RXDoc* d in [g_docs copy]) {
        if (!d.window_delegate || !d.ctx)
            continue;
        id r = doc_call(d, @"windowDelegate", @[info]);
        if (![r isKindOfClass:NSString.class] || ![@[@"rex", @"docks"] containsObject:r])
            continue;
        rexui_log_file([NSString stringWithFormat:@"windows: %@ -> %@ (%@)", info[@"id"], r, d.path.lastPathComponent]);
        return r;
    }
    return nil;
}

void windows_held(NSDictionary* info) {
    if (!g_held)
        g_held = [NSMutableArray array];
    NSMutableDictionary* w = [info mutableCopy];
    w[@"time"] = @(floor(NSDate.date.timeIntervalSince1970 * 1000));
    [g_held insertObject:w atIndex:0];
    while (g_held.count > 20)
        [g_held removeLastObject];
    push();
    for (RXDoc* d in [g_docs copy])
        if (d.ctx && d.root)
            doc_call(d, @"emit", @[@(d.root.uid), @"window", @[[w copy]]]);
}

id windows_native(NSString* op, NSDictionary* a) {
    if ([op isEqualToString:@"open"])
        return @(rex_window_open([a[@"id"] isKindOfClass:NSString.class] ? a[@"id"] : @""));
    if ([op isEqualToString:@"clear"]) {
        [g_held removeAllObjects];
        push();
    }
    return nil;
}
