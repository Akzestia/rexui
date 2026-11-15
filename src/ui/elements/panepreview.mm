// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "rex/rex.h"
#include "ui/ui.h"

@interface CAPortalLayer : CALayer
@property(weak) CALayer* sourceLayer;
@end

@interface RXPanePreviewLayer : RXLayer
@property(nonatomic, strong) CAPortalLayer* portal;
@property(nonatomic) NSView* source;
@property(nonatomic, weak) CALayer* termSource;
@property(nonatomic, strong) CALayer* watched;
@property(nonatomic) int blank;
@end
@interface RXPanePreviewLayer () {
    __weak NSView* _w_source;
}
@end
@implementation RXPanePreviewLayer
- (NSView*)source {
    return _w_source;
}
- (void)setSource:(NSView*)v {
    _w_source = v;
}
- (void)dealloc {
    if (CALayer* tab = _watched)
        dispatch_async(dispatch_get_main_queue(), ^{
            term_tab_watch(tab, false);
        });
}
@end

static NSHashTable<RXNode*>* g_previews;

static NSView* source_of(NSString* block) {
    if (!block.length)
        return nil;
    NSView* v = pane_views_now()[block];
    return v.window ? v : nil;
}

static void update(RXNode* n, bool still);
void pane_preview_update(RXNode* n) {
    update(n, false);
}

static void update(RXNode* n, bool still) {
    RXPanePreviewLayer* l = (RXPanePreviewLayer*)n.layer;
    if (![l isKindOfClass:RXPanePreviewLayer.class])
        return;
    NSString* block = [obj(n, P::block) isKindOfClass:NSString.class] ? obj(n, P::block) : @"";
    NSView* shown = block.length ? pane_views_now()[block] : nil;
    NSView* src = still && l.source.window && (!shown.window || shown == l.source) ? l.source : source_of(block);
    CALayer* term = !src ? term_block_layer(block) : nil;
    if (term) {
        if (l.source || l.termSource != term)
            invalidate(n);
        l.source = nil;
        l.termSource = term;
        if (CALayer* now = l.portal.sourceLayer; now != term)
            l.portal.sourceLayer = term;
        l.portal.hidden = NO;
    } else {
        l.termSource = nil;
    }
    if (CALayer* tab = term && node_on_screen(n) ? term.superlayer : nil; tab != l.watched) {
        term_tab_watch(l.watched, false);
        term_tab_watch(tab, true);
        l.watched = tab;
    }
    if (CALayer* showing = l.portal.sourceLayer; !term && (src != l.source || showing != src.layer)) {
        if (src != l.source
            && fabs(src.bounds.size.height * l.source.bounds.size.width
                    - src.bounds.size.width * l.source.bounds.size.height)
                > 1)
            invalidate(n);
        if (src != l.source)
            rexui_log_file(src ? [NSString stringWithFormat:@"PanePreview: %@ from a %@ (%.0fx%.0f)", block,
                                                            src.className, src.bounds.size.width,
                                                            src.bounds.size.height]
                               : [NSString stringWithFormat:@"PanePreview: %@ drawn nowhere now",
                                                            block.length ? block : @"(no block)"]);
        l.source = src;
        l.portal.sourceLayer = src.layer;
        l.portal.hidden = !src;
    }
    l.cornerRadius = [obj(n, P::radius) doubleValue];
    l.masksToBounds = YES;
    CGSize s = term ? term.bounds.size : src.layer.bounds.size, box = l.bounds.size;
    if ((!src && !term) || s.width < 1 || s.height < 1 || box.width < 1)
        return;
    bool cover = [obj(n, P::fit) isEqual:@"cover"];
    CGFloat k =
        cover ? MAX(box.width / s.width, box.height / s.height) : MIN(box.width / s.width, box.height / s.height);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    l.portal.bounds = CGRectMake(0, 0, s.width, s.height);
    l.portal.anchorPoint = CGPointMake(0.5, 0.5);
    l.portal.position = CGPointMake(box.width / 2, box.height / 2);
    l.portal.transform = CATransform3DMakeScale(k, k, 1);
    [CATransaction commit];
}

static void look_blank(RXNode* n) {
    RXPanePreviewLayer* l = (RXPanePreviewLayer*)n.layer;
    if (![l isKindOfClass:RXPanePreviewLayer.class])
        return;
    NSString* block = [obj(n, P::block) isKindOfClass:NSString.class] ? obj(n, P::block) : @"";
    CALayer* term = l.termSource;
    NSString* why = !node_on_screen(n) || !block.length ? nil
        : term                                          ? term_pane_blank(term)
        : !l.source ? [block stringByAppendingString:@" drawn nowhere (no view of Rex's, no tab of rexui's has it)"]
                    : nil;
    if (!why) {
        if (l.blank >= 2)
            rexui_log_file([NSString stringWithFormat:@"PanePreview: %@ drawn again", block]);
        l.blank = 0;
        return;
    }
    if (++l.blank == 2)
        rexui_log([NSString stringWithFormat:@"PanePreview: on screen and blank: %@", why]);
}

CGFloat pane_preview_aspect(RXNode* n) {
    RXPanePreviewLayer* l = (RXPanePreviewLayer*)n.layer;
    NSView* src = [l isKindOfClass:RXPanePreviewLayer.class] ? l.source : nil;
    if (!src)
        src = source_of([obj(n, P::block) isKindOfClass:NSString.class] ? obj(n, P::block) : @"");
    CGSize s = src ? src.bounds.size : l.termSource.bounds.size;
    return s.width > 1 && s.height > 1 ? s.height / s.width : 0.625;
}

CALayer* make_pane_preview(RXNode* n) {
    RXPanePreviewLayer* l = [RXPanePreviewLayer layer];
    l.portal = [CAPortalLayer layer];
    l.portal.hidden = YES;
    for (NSString* k in @[@"matchesPosition", @"matchesTransform", @"matchesOpacity"])
        if ([l.portal respondsToSelector:NSSelectorFromString(k)])
            [l.portal setValue:@NO forKey:k];
    [l addSublayer:l.portal];
    if (!g_previews)
        g_previews = [NSHashTable weakObjectsHashTable];
    static NSTimer* tick;
    if (!tick)
        tick = [NSTimer scheduledTimerWithTimeInterval:1
                                               repeats:YES
                                                 block:^(NSTimer* t) {
                                                     NSArray<RXNode*>* all = g_previews.allObjects;
                                                     if (!all.count) {
                                                         [t invalidate];
                                                         tick = nil;
                                                         return;
                                                     }
                                                     for (RXNode* p in all)
                                                         update(p, true), look_blank(p);
                                                 }];
    [g_previews addObject:n];
    return l;
}
