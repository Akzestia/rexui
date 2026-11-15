// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#import <objc/message.h>
#include "web/web.h"

static const double kReady = 0.5;
static const double kLiveEnd = 0.3;

@interface RXWebCover : NSView
@end
@implementation RXWebCover
- (BOOL)isFlipped {
    return YES;
}
- (NSView*)hitTest:(NSPoint)p {
    return nil;
}
@end

@interface RXWebHold : NSObject
@property(nonatomic) NSRect laid;
@property(nonatomic) bool busy;
@property(nonatomic) uint64_t gen;
@property(nonatomic) NSSize shown;
@property(nonatomic) bool live;
@property(nonatomic) uint64_t live_gen;
@property(nonatomic, strong) RXWebCover* cover;
@end
@implementation RXWebHold
@end

static NSMapTable<RXNode*, RXWebHold*>* g_holds;

static void set_colour(CALayer* l, CGColorRef c) {
    if (l.backgroundColor == c || (l.backgroundColor && c && CGColorEqualToColor(l.backgroundColor, c)))
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.backgroundColor = c;
    [CATransaction commit];
}

static CGColorRef page_colour(WKWebView* w) {
    NSColor* c = w.underPageBackgroundColor;
    return c && c.alphaComponent > 0 ? c.CGColor : NSColor.whiteColor.CGColor;
}

static void uncover(RXWebHold* h) {
    [h.cover removeFromSuperview];
    h.cover = nil;
}

static void after_presentation(WKWebView* w, void (^then)(void)) {
    SEL after = NSSelectorFromString(@"_doAfterNextPresentationUpdate:");
    if ([w respondsToSelector:after])
        ((void (*)(id, SEL, void (^)(void)))objc_msgSend)(w, after, then);
    else
        then();
}

static void shown(RXNode* n, uint64_t gen) {
    RXWebHold* h = n ? [g_holds objectForKey:n] : nil;
    if (!h || h.gen != gen || !h.busy)
        return;
    h.busy = false;
    h.shown = n.view.frame.size;
    uncover(h);
    if (n.doc)
        place_natives(n.doc);
}

static void cover(RXWebHold* h, WKWebView* w, NSView* clip, NSRect inner) {
    const NSSize was = h.shown;
    if (inner.size.width <= was.width + 0.5 && inner.size.height <= was.height + 0.5) {
        uncover(h);
        return;
    }
    if (!h.cover) {
        h.cover = [[RXWebCover alloc] initWithFrame:NSZeroRect];
        h.cover.wantsLayer = YES;
    }
    RXWebCover* v = h.cover;
    if (v.superview != clip || clip.subviews.lastObject != v)
        [clip addSubview:v positioned:NSWindowAbove relativeTo:w];
    v.frame = inner;
    while (v.layer.sublayers.count < 2)
        [v.layer addSublayer:[CALayer layer]];
    NSArray<CALayer*>* ls = v.layer.sublayers;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    const CGFloat W = inner.size.width, H = inner.size.height, sw = MIN(was.width, W), sh = MIN(was.height, H);
    ls[0].frame = CGRectMake(sw, 0, W - sw, H);
    ls[1].frame = CGRectMake(0, sh, sw, H - sh);
    ls[0].backgroundColor = ls[1].backgroundColor = page_colour(w);
    [CATransaction commit];
}

static void live(RXNode* n, RXWebHold* h, WKWebView* w) {
    if (!h.live) {
        h.live = true;
        [w viewWillStartLiveResize];
    }
    const uint64_t gen = ++h.live_gen;
    __weak RXNode* wn = n;
    __weak WKWebView* ww = w;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLiveEnd * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RXNode* s = wn;
        RXWebHold* hh = s ? [g_holds objectForKey:s] : nil;
        WKWebView* sw = ww;
        if (!hh || hh.live_gen != gen || !hh.live)
            return;
        hh.live = false;
        [sw viewDidEndLiveResize];
    });
}

static void give(RXNode* n, RXWebHold* h, WKWebView* w, NSView* clip, NSRect f, NSRect inner) {
    h.laid = f;
    w.frame = inner;
    const uint64_t gen = ++h.gen;
    h.busy = true;
    if (g_config.web_resize != WebResize::stretch)
        cover(h, w, clip, inner);
    __weak RXNode* wn = n;
    if (g_config.web_resize == WebResize::live) {
        __weak WKWebView* ww = w;
        after_presentation(w, ^{
            WKWebView* s = ww;
            if (s)
                after_presentation(s, ^{
                    shown(wn, gen);
                });
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReady * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        shown(wn, gen);
    });
}

static void stretch(WKWebView* w, RXWebHold* h, NSSize room) {
    const NSSize had = w.frame.size;
    const CGFloat pw = MIN(h.shown.width, had.width), ph = MIN(h.shown.height, had.height);
    CATransform3D t = CATransform3DIdentity;
    if (g_config.web_resize == WebResize::stretch && pw >= 2 && ph >= 2) {
        const CGFloat sx = room.width / pw, sy = room.height / ph;
        if (fabs(sx - 1) > 0.001 || fabs(sy - 1) > 0.001)
            t = CATransform3DMakeScale(sx, sy, 1);
    }
    if (CATransform3DEqualToTransform(w.layer.transform, t))
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    w.layer.transform = t;
    [CATransaction commit];
}

void web_place(RXNode* n, WKWebView* w, NSView* clip, NSRect f, NSRect c) {
    if (!g_holds)
        g_holds = [NSMapTable weakToStrongObjectsMapTable];
    RXWebHold* h = [g_holds objectForKey:n];
    const NSRect inner = NSOffsetRect(f, -c.origin.x, -c.origin.y);
    const NSSize had = w.frame.size;
    if (!h || had.width < 2 || had.height < 2) {
        if (!h) {
            h = [RXWebHold new];
            [g_holds setObject:h forKey:n];
        }
        h.laid = f;
        h.shown = inner.size;
        h.busy = false;
        w.frame = inner;
        stretch(w, h, inner.size);
        return;
    }
    set_colour(clip.layer, page_colour(w));
    const bool resized = fabs(had.width - inner.size.width) > 0.5 || fabs(had.height - inner.size.height) > 0.5;
    if (resized)
        live(n, h, w);
    if (resized && (g_config.web_resize == WebResize::live || !h.busy)) {
        give(n, h, w, clip, f, inner);
    } else {
        NSRect at = NSMakeRect(inner.origin.x, inner.origin.y, had.width, had.height);
        if (resized && g_config.web_resize == WebResize::steps) {
            const NSRect was = h.laid;
            at.origin.x =
                (fabs(NSMaxX(f) - NSMaxX(was)) < fabs(NSMinX(f) - NSMinX(was)) ? NSMaxX(f) - had.width : NSMinX(f))
                - c.origin.x;
            at.origin.y =
                (fabs(NSMaxY(f) - NSMaxY(was)) < fabs(NSMinY(f) - NSMinY(was)) ? NSMaxY(f) - had.height : NSMinY(f))
                - c.origin.y;
        }
        if (!NSEqualRects(w.frame, at))
            w.frame = at;
        if (!resized)
            h.laid = f;
        if (h.cover)
            h.cover.frame = NSMakeRect(at.origin.x, at.origin.y, h.cover.frame.size.width, h.cover.frame.size.height);
    }
    stretch(w, h, inner.size);
}

@interface RXWebSizes : NSObject <WKScriptMessageHandler>
@end
@implementation RXWebSizes
- (void)userContentController:(WKUserContentController*)u didReceiveScriptMessage:(WKScriptMessage*)m {
    WKWebView* w = m.webView;
    if (!w || !m.frameInfo.isMainFrame)
        return;
    RXNode* n = nil;
    for (RXNode* x in g_webs)
        if (x.view == w)
            n = x;
    RXWebHold* h = n ? [g_holds objectForKey:n] : nil;
    if (!h || !h.busy)
        return;
    const uint64_t gen = h.gen;
    __weak RXNode* wn = n;
    after_presentation(w, ^{
        shown(wn, gen);
    });
}
@end

static NSString* const kSizeName = @"rexuiSize";

void web_sizes_watch(WKWebView* w) {
    static RXWebSizes* handler = [RXWebSizes new];
    [w.configuration.userContentController addScriptMessageHandler:handler
                                                      contentWorld:WKContentWorld.defaultClientWorld
                                                              name:kSizeName];
}

WKUserScript* web_sizes_script(void) {
    static NSString* const js = @(R"JS((() => {
  if (window.__rexuiSize) return;
  window.__rexuiSize = true;
  let last = '';
  addEventListener('resize', () => requestAnimationFrame(() => {
    const s = innerWidth + 'x' + innerHeight;
    if (s === last) return;
    last = s;
    webkit.messageHandlers.rexuiSize.postMessage(s);
  }));
})();)JS");
    return [[WKUserScript alloc] initWithSource:js
                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                               forMainFrameOnly:YES
                                 inContentWorld:WKContentWorld.defaultClientWorld];
}
