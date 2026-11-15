// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

static RXLayer* g_plate;
static RXTextLayer* g_text;
static NSMutableArray<CALayer*>* g_caps;
static __weak RXNode* g_node;
static __weak id g_other;
static __weak RXDockView* g_host;
static NSTimer* g_wait;

static NSString* cap_text(NSString* part) {
    NSDictionary* m = @{
        @"cmd": @"⌘",
        @"shift": @"⇧",
        @"alt": @"⌥",
        @"opt": @"⌥",
        @"ctrl": @"⌃",
        @"left": @"←",
        @"right": @"→",
        @"up": @"↑",
        @"down": @"↓",
        @"enter": @"↩",
        @"return": @"↩",
        @"tab": @"⇥",
        @"escape": @"⎋",
        @"esc": @"⎋",
        @"space": @"␣",
        @"backspace": @"⌫",
        @"delete": @"⌦"
    };
    return m[part.lowercaseString] ?: part.uppercaseString;
}

static void hide(void) {
    [g_wait invalidate];
    g_wait = nil;
    g_plate.hidden = YES;
}

static void show_at(NSString* tip, NSString* keys, NSWindow* window, NSRect in) {
    if (!tip.length && !keys.length)
        return hide();
    if (!g_plate) {
        g_plate = [RXLayer layer];
        g_plate.cornerRadius = 7;
        g_plate.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.94].CGColor;
        g_plate.borderColor = [NSColor colorWithWhite:1 alpha:0.12].CGColor;
        g_plate.borderWidth = 0.5;
        g_plate.shadowOpacity = 0.35, g_plate.shadowRadius = 8, g_plate.shadowOffset = CGSizeMake(0, 3);
        g_plate.zPosition = 100000;
        g_text = [RXTextLayer layer];
        g_text.font = [NSFont systemFontOfSize:12];
        g_text.color = [NSColor colorWithWhite:0.95 alpha:1];
        g_text.wrap = true;
        g_text.maxLines = 4;
        [g_plate addSublayer:g_text];
        g_caps = [NSMutableArray array];
    }
    CGFloat scale = window.backingScaleFactor ?: 2;
    for (CALayer* c in g_caps)
        [c removeFromSuperlayer];
    [g_caps removeAllObjects];
    g_text.text = tip;
    NSSize ts = tip.length ? text_size(g_text, 280) : NSZeroSize;
    CGFloat pad = 8, x = pad, h = MAX(ts.height, 16) + 10;
    g_text.frame = CGRectMake(pad, (h - ts.height) / 2, ceil(ts.width), ceil(ts.height));
    g_text.contentsScale = scale;
    x += ceil(ts.width) + (tip.length && keys.length ? 8 : 0);
    for (NSString* part in keys.length ? [keys componentsSeparatedByString:@"+"] : @[]) {
        RXTextLayer* t = [RXTextLayer layer];
        t.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
        t.color = [NSColor colorWithWhite:0.92 alpha:1];
        t.text = cap_text(part);
        t.contentsScale = scale;
        NSSize s = text_size(t, CGFLOAT_MAX);
        RXLayer* cap = [RXLayer layer];
        CGFloat w = MAX(18, ceil(s.width) + 8);
        cap.frame = CGRectMake(x, (h - 18) / 2, w, 18);
        cap.cornerRadius = 4;
        cap.backgroundColor = [NSColor colorWithWhite:1 alpha:0.14].CGColor;
        t.frame = CGRectMake((w - ceil(s.width)) / 2, (18 - ceil(s.height)) / 2, ceil(s.width), ceil(s.height));
        [cap addSublayer:t];
        [g_plate addSublayer:cap];
        [g_caps addObject:cap];
        x += w + 3;
    }
    CGFloat w = x - (keys.length ? 3 : 0) + pad;
    CALayer* top = (window.contentView.superview ?: window.contentView).layer;
    if (!top)
        return hide();
    CGSize win = top.bounds.size;
    CGFloat px = NSMidX(in) - w / 2, py = NSMinY(in) - h - 6;
    if (py < 4)
        py = NSMaxY(in) + 6;
    px = MIN(MAX(px, 4), win.width - w - 4);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (g_plate.superlayer != top)
        [top addSublayer:g_plate];
    g_plate.frame = CGRectMake(px, py, w, h);
    g_plate.hidden = NO;
    [CATransaction commit];
}

static void show(RXNode* n, RXDockView* host) {
    NSString* tip = [obj(n, P::tip) isKindOfClass:NSString.class] ? obj(n, P::tip) : @"";
    NSString* keys = [obj(n, P::tipKeys) isKindOfClass:NSString.class] ? obj(n, P::tipKeys) : @"";
    CGRect box = [host.layer convertRect:n.layer.bounds fromLayer:n.layer];
    show_at(tip, keys, host.window, [host convertRect:box toView:nil]);
}

static RXNode* with_tip(RXNode* n) {
    for (; n; n = n.parent)
        if ([obj(n, P::tip) length] || [obj(n, P::tipKeys) length])
            return n;
    return nil;
}

void tips_pointer(RXDockView* host, RXNode* under) {
    RXNode* n = with_tip(under);
    if (n == g_node && host == g_host)
        return;
    if (!n && g_other)
        return;
    hide();
    g_other = nil;
    g_node = n, g_host = host;
    if (!n)
        return;
    __weak RXNode* wn = n;
    __weak RXDockView* wh = host;
    g_wait = [NSTimer
        scheduledTimerWithTimeInterval:0.6
                               repeats:NO
                                 block:^(NSTimer*) {
                                     g_wait = nil;
                                     RXNode* nn = wn;
                                     RXDockView* hh = wh;
                                     if (nn && hh && nn == g_node && hh.window && !hh.hiddenOrHasHiddenAncestor)
                                         show(nn, hh);
                                 }];
}

void tips_hide(void) {
    g_node = nil;
    g_other = nil;
    hide();
}

void tips_at(id subject, NSString* tip, NSWindow* w, NSRect in) {
    id other = g_other;
    if (subject == other)
        return;
    if (!subject && !other)
        return;
    hide();
    g_node = nil;
    g_other = subject;
    if (!subject || !tip.length || !w)
        return;
    __weak id ws = subject;
    __weak NSWindow* ww = w;
    g_wait = [NSTimer scheduledTimerWithTimeInterval:0.6
                                             repeats:NO
                                               block:^(NSTimer*) {
                                                   g_wait = nil;
                                                   id held = ws;
                                                   NSWindow* held_w = ww;
                                                   if (held && held == g_other && held_w)
                                                       show_at(tip, @"", held_w, in);
                                               }];
}
