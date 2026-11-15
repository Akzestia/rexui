// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

#include "rex/rex.h"

static void swap_webview(RXNode* n) {
    WKWebView* old = (WKWebView*)n.view;
    NSView* parent = old.superview;
    NSRect frame = old.frame;
    BOOL hidden = old.hidden;
    close_web(n);
    WKWebView* w = make_webview(n);
    w.frame = frame;
    w.hidden = hidden;
    w.pageZoom = num(n, P::zoom, 1);
    if (parent)
        [parent replaceSubview:old with:w];
    n.view = w;
    if (g_ubol)
        [extensions() didOpenTab:n];
    else if (flag(n, P::adblock, true))
        apply_adblock(n, false);
}

static NSHashTable<RXNode*>* g_opened;
static void mark_opened(RXNode* n) {
    if (!g_opened)
        g_opened = [NSHashTable weakObjectsHashTable];
    [g_opened addObject:n];
}
static NSMapTable<RXNode*, NSNumber*>* g_opened_at;

static void suspend(RXNode* n) {
    WKWebView* w = (WKWebView*)n.view;
    if (!w.URL)
        return;
    __weak RXNode* weak = n;
    [w requestMediaPlaybackStateWithCompletionHandler:^(WKMediaPlaybackState state) {
        RXNode* n2 = weak;
        if (!n2 || state == WKMediaPlaybackStatePlaying || on_screen(n2))
            return;
        WKWebView* w2 = (WKWebView*)n2.view;
        NSString* url = w2.URL.absoluteString;
        n2.saved_state = w2.interactionState;
        n2.waiting = url;
        mark_opened(n2);
        session_save(n2);
        swap_webview(n2);
        rexui_log([NSString stringWithFormat:@"%@: suspended %@ (hidden %.0f s)", n2.doc.path.lastPathComponent,
                                             [NSURL URLWithString:url].host ?: url,
                                             -n2.hidden_since.timeIntervalSinceNow]);
    }];
}

static void open_waiting(RXNode* n) {
    NSString* url = n.waiting;
    id state = n.saved_state;
    n.waiting = nil;
    n.saved_state = nil;
    mark_opened(n);
    if (!g_opened_at)
        g_opened_at = [NSMapTable weakToStrongObjectsMapTable];
    [g_opened_at setObject:@(CACurrentMediaTime()) forKey:n];
    if (state) {
        WKWebView* w = (WKWebView*)n.view;
        w.interactionState = state;
        rexui_log([NSString
            stringWithFormat:@"%@: resumed %@", n.doc.path.lastPathComponent, [NSURL URLWithString:url].host ?: url]);
        __weak RXNode* weak = n;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
            RXNode* n2 = weak;
            WKWebView* w2 = (WKWebView*)n2.view;
            if (n2 && !w2.URL && !w2.loading) {
                rexui_log([NSString stringWithFormat:@"%@: its saved state was empty", n2.doc.path.lastPathComponent]);
                web_load(n2, url);
            }
        });
    } else {
        web_load(n, url);
    }
}

void web_visibility(void) {
    for (RXNode* n in g_webs.allObjects) {
        if (!n.doc)
            continue;
        if (!on_screen(n)) {
            if (!n.hidden_since)
                n.hidden_since = NSDate.date;
            if (n.closed == 1)
                n.closed = 2;
            continue;
        }
        n.hidden_since = nil;
        if (n.closed == 1)
            continue;
        if (n.closed == 2) {
            n.closed = 0;
            n.waiting = str(n, P::url, @"");
        }
        if (!n.waiting || n.preparing > 0)
            continue;
        open_waiting(n);
    }
}

void suspend_hidden(void) {
    for (RXNode* n in g_webs.allObjects) {
        double after = num(n, P::suspend, 300);
        if (!n.doc || after <= 0 || !n.hidden_since || n.waiting || n.preparing > 0 || web_kept_awake(n.doc))
            continue;
        if (-n.hidden_since.timeIntervalSinceNow >= after)
            suspend(n);
    }
}

bool web_kept_awake(RXDoc* doc) {
    return [[g_state arrayForKey:@"web awake"] containsObject:doc.path.lastPathComponent];
}

void web_keep_awake(RXDoc* doc, bool on) {
    NSMutableArray* all = [[g_state arrayForKey:@"web awake"] mutableCopy] ?: [NSMutableArray array];
    [all removeObject:doc.path.lastPathComponent];
    if (on)
        [all addObject:doc.path.lastPathComponent];
    [g_state setObject:all forKey:@"web awake"];
}

static NSArray<RXNode*>* pages_of(RXDoc* doc) {
    NSMutableArray* out = [NSMutableArray array];
    for (RXNode* n in doc.nodes.allValues) {
        if (is_elem(n, E::WebView) && n.observing)
            [out addObject:n];
    }
    return out;
}

bool web_can_suspend(RXDoc* doc) {
    for (RXNode* n in pages_of(doc)) {
        if (((WKWebView*)n.view).URL && !n.waiting && !on_screen(n))
            return true;
    }
    return false;
}

void web_suspend_doc(RXDoc* doc) {
    for (RXNode* n in pages_of(doc)) {
        if (((WKWebView*)n.view).URL && !n.waiting && !on_screen(n))
            suspend(n);
    }
}

void web_close_pages(RXDoc* doc) {
    for (RXNode* n in pages_of(doc)) {
        n.saved_state = nil;
        n.waiting = nil;
        n.deferred = nil;
        if (n.session)
            [NSFileManager.defaultManager removeItemAtPath:n.session error:nil];
        n.closed = 1;
        swap_webview(n);
        rexui_log([NSString stringWithFormat:@"%@: page closed", doc.path.lastPathComponent]);
    }
}

static NSMapTable<RXNode*, CALayer*>* g_pictures;
static NSMapTable<RXNode*, NSValue*>* g_parked;
static NSHashTable<RXNode*>* g_taking;
static NSView* g_park;
static uint32_t g_tick;

static bool lent(RXNode* n) {
    return n.clip && !n.clip.window;
}
bool web_lent_to_pane(RXNode* n) {
    return n.doc.pane_block && lent(n);
}

bool web_parked(RXNode* n) {
    return n && [g_parked objectForKey:n] != nil;
}

static void put_picture(RXNode* n, CGImageRef image) {
    WKWebView* w = (WKWebView*)n.view;
    NSView* clip = n.clip;
    if (!image || !w || !clip.layer || !lent(n))
        return;
    CALayer* pic = [g_pictures objectForKey:n];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!pic) {
        pic = [CALayer layer];
        pic.contentsGravity = kCAGravityResize;
        pic.zPosition = 1;
        if (!g_pictures)
            g_pictures = [NSMapTable weakToStrongObjectsMapTable];
        [g_pictures setObject:pic forKey:n];
    }
    if (pic.superlayer != clip.layer)
        [clip.layer addSublayer:pic];
    NSValue* at = [g_parked objectForKey:n];
    pic.frame = at ? NSRectToCGRect(at.rectValue) : w.layer.frame;
    pic.contentsScale = g_park.window.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor;
    pic.contents = (__bridge id)image;
    [CATransaction commit];
}

static void drop_picture(RXNode* n) {
    [[g_pictures objectForKey:n] removeFromSuperlayer];
    [g_pictures removeObjectForKey:n];
}

static bool one_colour(CGImageRef img) {
    if (!img)
        return true;
    uint8_t px[16 * 16 * 4] = {};
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(px, 16, 16, 8, 16 * 4, cs, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!c)
        return false;
    CGContextSetInterpolationQuality(c, kCGInterpolationNone);
    CGContextDrawImage(c, CGRectMake(0, 0, 16, 16), img);
    CGContextRelease(c);
    for (int i = 4; i < 16 * 16 * 4; i++)
        if (abs(int(px[i]) - int(px[i % 4])) > 3)
            return false;
    return true;
}

static void take_picture(RXNode* n) {
    WKWebView* w = (WKWebView*)n.view;
    if (n.closed)
        return drop_picture(n);
    if (!w || !w.URL || n.waiting || [g_taking containsObject:n])
        return;
    if (w.loading && ![g_pictures objectForKey:n]
        && CACurrentMediaTime() - [[g_opened_at objectForKey:n] doubleValue] < 3)
        return;
    if (!g_taking)
        g_taking = [NSHashTable weakObjectsHashTable];
    [g_taking addObject:n];
    __weak RXNode* weak = n;
    [w takeSnapshotWithConfiguration:nil
                   completionHandler:^(NSImage* image, NSError* error) {
                       RXNode* n2 = weak;
                       if (!n2)
                           return;
                       [g_taking removeObject:n2];
                       if (!image) {
                           rexui_log_file([NSString stringWithFormat:@"%@: no picture of its page: %@",
                                                                     n2.doc.path.lastPathComponent,
                                                                     error.localizedDescription]);
                           return;
                       }
                       CGImageRef cg = [image CGImageForProposedRect:nullptr context:nil hints:nil];
                       if (![g_pictures objectForKey:n2] && one_colour(cg)
                           && CACurrentMediaTime() - [[g_opened_at objectForKey:n2] doubleValue] < 5)
                           return;
                       put_picture(n2, cg);
                   }];
}

void web_unpark(RXNode* n);
static NSMapTable<RXNode*, NSNumber*>* g_taken_at;
static void park_tick(id, const RXFrame*) {
    const bool sliding = rex_slide_busy();
    const double now = CACurrentMediaTime();
    for (RXNode* n in g_parked.keyEnumerator.allObjects) {
        if (!n.doc || !lent(n)) {
            web_unpark(n);
            continue;
        }
        NSString* block = n.doc.pane_block;
        if (block && !term_block_hot(block))
            continue;
        if (!g_taken_at)
            g_taken_at = [NSMapTable weakToStrongObjectsMapTable];
        if (!sliding && now - [[g_taken_at objectForKey:n] doubleValue] < 1.0 / 60 - 0.002)
            continue;
        [g_taken_at setObject:@(now) forKey:n];
        take_picture(n);
    }
}

void web_parked_place(RXNode* n, NSRect inner) {
    NSValue* at = [g_parked objectForKey:n];
    if (!at || NSEqualRects(at.rectValue, inner))
        return;
    [g_parked setObject:[NSValue valueWithRect:inner] forKey:n];
    WKWebView* w = (WKWebView*)n.view;
    if (w && !NSEqualSizes(w.frame.size, inner.size))
        [w setFrameSize:inner.size];
    if (CALayer* pic = [g_pictures objectForKey:n]) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        pic.frame = NSRectToCGRect(inner);
        [CATransaction commit];
    }
}

void web_unpark(RXNode* n) {
    NSValue* at = [g_parked objectForKey:n];
    if (!at)
        return;
    [g_parked removeObjectForKey:n];
    WKWebView* w = (WKWebView*)n.view;
    if (w && n.clip && w.superview != n.clip) {
        [w removeFromSuperview];
        w.frame = at.rectValue;
        [n.clip addSubview:w];
    }
    if (!g_parked.count && g_tick)
        ui_clock_remove(g_tick), g_tick = 0;
}

static void park(RXNode* n) {
    WKWebView* w = (WKWebView*)n.view;
    NSView* root = ui_full_root(dock_window());
    if (!w || !root || !w.URL || n.waiting || n.closed)
        return web_unpark(n);
    if (!g_park || g_park.superview != root) {
        [g_park removeFromSuperview];
        g_park = [[NSView alloc] initWithFrame:NSMakeRect(-40000, -40000, 20000, 20000)];
        g_park.wantsLayer = YES;
        [root addSubview:g_park positioned:NSWindowBelow relativeTo:nil];
    }
    if (w.superview == g_park)
        return;
    if (!g_parked)
        g_parked = [NSMapTable weakToStrongObjectsMapTable];
    [g_parked setObject:[NSValue valueWithRect:w.frame] forKey:n];
    [w removeFromSuperview];
    [g_park addSubview:w];
    w.frameOrigin = NSZeroPoint;
    if (!g_tick)
        g_tick = ui_clock_add(RX_TICK_NODE, 60, root, g_park, park_tick);
}

void web_pane_pictures(id d, bool is_lent, bool drawn) {
    RXDoc* doc = d;
    for (RXNode* n in g_webs.allObjects) {
        if (n.doc != doc)
            continue;
        if (is_lent) {
            if (n.waiting && n.preparing <= 0 && !n.closed && (drawn || ![g_opened containsObject:n]))
                open_waiting(n);
            const bool pictured = [g_pictures objectForKey:n] != nil;
            if (drawn || !pictured)
                park(n);
            else
                web_unpark(n);
            if (!pictured)
                take_picture(n);
            continue;
        }
        web_unpark(n);
        if (![g_pictures objectForKey:n])
            continue;
        __weak RXNode* weak = n;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
            RXNode* n2 = weak;
            if (!n2 || lent(n2))
                return;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            drop_picture(n2);
            [CATransaction commit];
        });
    }
}

NSView* web_pane_page(id d) {
    WKWebView* best = nil;
    CGFloat area = 0;
    for (RXNode* n in g_webs.allObjects) {
        WKWebView* w = (WKWebView*)n.view;
        if (n.doc != d || !on_screen(n) || web_parked(n))
            continue;
        CGFloat a = w.bounds.size.width * w.bounds.size.height;
        if (a > area)
            best = w, area = a;
    }
    return best;
}
