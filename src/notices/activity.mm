// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#import "base/rexui.h"
#import "rex/rex.h"
#import "ui/ui.h"

static NSArray<NSDictionary*>* g_last;

static int rank_of(NSString* s) {
    return [s isEqualToString:@"blocked"] ? 4
        : [s isEqualToString:@"error"]    ? 3
        : [s isEqualToString:@"working"]  ? 2
        : [s isEqualToString:@"done"]     ? 1
                                          : 0;
}

static NSDictionary* state_of(NSArray<NSDictionary*>* list) {
    NSMutableDictionary *blocks = [NSMutableDictionary dictionary], *tabs = [NSMutableDictionary dictionary];
    NSDictionary* urgent = nil;
    int rank = 1;
    for (NSDictionary* e in list) {
        blocks[e[@"block"]] = e;
        int r = rank_of(e[@"status"]);
        if (r > rank || (r == rank && r > 1 && [e[@"updatedAt"] doubleValue] > [urgent[@"updatedAt"] doubleValue]))
            rank = r, urgent = e;
        NSString* tab = e[@"tab"];
        if (![tab length])
            continue;
        NSMutableDictionary* t = tabs[tab];
        if (!t)
            tabs[tab] = t = [@{
                @"tab": tab,
                @"label": e[@"tabLabel"] ?: @"",
                @"session": e[@"session"] ?: @"",
                @"sessionLabel": e[@"sessionLabel"] ?: @"",
                @"panes": [NSMutableArray array],
                @"status": @"idle"
            } mutableCopy];
        [t[@"panes"] addObject:e];
        if (r > rank_of(t[@"status"]))
            t[@"status"] = e[@"status"];
    }
    return @{@"list": list, @"blocks": blocks, @"tabs": tabs, @"urgent": urgent ?: NSNull.null};
}

static NSArray<NSDictionary*>* read_now(void) {
    NSArray* list = (__bridge_transfer NSArray*)rex_activity();
    return [list sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        return [b[@"updatedAt"] ?: @0 compare:a[@"updatedAt"] ?: @0];
    }]
        ?: @[];
}

NSString* activity_status_of(NSString* block) {
    if (!block.length)
        return nil;
    for (NSDictionary* e in g_last ?: read_now())
        if ([e[@"block"] isEqualToString:block])
            return e[@"status"];
    return nil;
}

void activity_doc_loaded(id d) {
    RXDoc* doc = d;
    if (doc.ctx && doc.wants_activity)
        doc_call(doc, @"setActivity", @[state_of(g_last ?: read_now())]);
}

static int g_alike, g_skip;
static bool g_watched;
static double g_read_at;
static double g_due;
static bool g_confirm;
void activity_hurry(void) {
    g_alike = 0, g_skip = 0;
}

static void read_and_tell(bool event);
void activity_rex_event(bool connected) {
    if (connected)
        g_watched = true;
    double now = CACurrentMediaTime(), at = std::max(now + 0.15, g_read_at + 1.0);
    if (g_due && g_due <= at && !g_confirm)
        return;
    g_due = at, g_confirm = false;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((at - now) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_due != at)
            return;
        g_due = 0;
        read_and_tell(true);
    });
}

static NSArray<RXDoc*>* readers(void) {
    NSMutableArray<RXDoc*>* out = [NSMutableArray array];
    for (RXDoc* doc in g_docs)
        if (doc.ctx && doc.wants_activity && [doc_call(doc, @"wantsActivity", @[]) boolValue])
            [out addObject:doc];
    return out;
}

static bool read_now_and_tell(NSArray<RXDoc*>* docs) {
    g_read_at = CACurrentMediaTime();
    NSArray* now = read_now();
    if ([now isEqualToArray:g_last])
        return false;
    g_last = now;
    NSDictionary* s = state_of(now);
    for (RXDoc* doc in docs)
        doc_call(doc, @"setActivity", @[s]);
    return true;
}

static void read_and_tell(bool event) {
    NSArray<RXDoc*>* docs = readers();
    if (!docs.count) {
        g_last = nil;
        return;
    }
    bool was_confirm = g_confirm;
    g_confirm = false;
    if (read_now_and_tell(docs) || !event || was_confirm || g_due)
        return;
    double at = CACurrentMediaTime() + 1.0;
    g_due = at, g_confirm = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (g_due != at)
            return;
        g_due = 0;
        read_and_tell(true);
    });
}

void activity_update(void) {
    rex_watch_start();
    if (g_watched) {
        if (g_due || (g_last && CACurrentMediaTime() - g_read_at < 60))
            return;
        read_and_tell(false);
        return;
    }
    if (g_skip > 0) {
        g_skip--;
        return;
    }
    NSArray<RXDoc*>* docs = readers();
    if (!docs.count) {
        g_last = nil;
        return;
    }
    if (!read_now_and_tell(docs)) {
        if (++g_alike >= 3)
            g_skip = 2;
        return;
    }
    g_alike = 0;
}

static NSString* const kToggle = @"client.sidebar.activity.toggle";

extern "C" bool rex_activity_asked(void) {
    NSString *way = nil, *who = nil;
    for (RXDoc* d in [g_docs copy]) {
        if (!d.activity_delegate || !d.ctx)
            continue;
        id r = doc_call(d, @"activityDelegate", @[@{@"command": kToggle}]);
        if (![r isKindOfClass:NSString.class] || ![@[@"rex", @"docks"] containsObject:r])
            continue;
        way = r, who = d.path.lastPathComponent;
        break;
    }
    if ([way isEqualToString:@"rex"]) {
        rexui_log_file([NSString stringWithFormat:@"activity: the popover -> rex (%@)", who]);
        return false;
    }
    bool drawer = ui_command(kToggle);
    if (!way && !drawer)
        return false;
    rexui_log_file([NSString stringWithFormat:@"activity: the popover -> docks (%@)", who ?: @"a Drawer takes it"]);
    for (RXDoc* d in [g_docs copy])
        if (d.ctx && d.root)
            doc_call(d, @"emit", @[@(d.root.uid), @"activityToggle", @[]]);
    return true;
}

id activity_native(NSString* op, NSDictionary* a) {
    if ([op isEqualToString:@"markSeen"]) {
        NSMutableArray* blocks = [NSMutableArray array];
        NSDictionary* tabs = state_of(g_last ?: read_now())[@"tabs"];
        for (id x in [a[@"ids"] isKindOfClass:NSArray.class] ? a[@"ids"] : @[]) {
            if (![x isKindOfClass:NSString.class])
                continue;
            if ([x hasPrefix:@"window:"])
                for (NSDictionary* e in tabs[x][@"panes"])
                    [blocks addObject:e[@"block"]];
            else
                [blocks addObject:x];
        }
        long n = blocks.count ? rex_mark_seen((__bridge void*)blocks) : 0;
        rexui_log_file([NSString
            stringWithFormat:@"activity: %ld receipts marked seen for %lu panes", n, (unsigned long)blocks.count]);
        return @(n);
    }
    return nil;
}
