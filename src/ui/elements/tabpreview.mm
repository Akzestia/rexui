// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "rex/rex.h"
#include "ui/ui.h"

@interface CAPortalLayer : CALayer
@property(weak) CALayer* sourceLayer;
@end

@interface RXTabPreviewLayer : RXLayer
@property(nonatomic, weak) RXNode* node;
@property(nonatomic) long tab;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, CALayer*>* portals;
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, CALayer*>* sources;
@property(nonatomic) NSUInteger closing;
@property(nonatomic, strong) RXTermInput* input;
@property(nonatomic) int looks;
@property(nonatomic) bool making;
@property(nonatomic) bool finding;
@property(nonatomic) int blank;
@end

static NSHashTable<RXNode*>* g_previews;

static CALayer* portal_layer(CALayer* source, Class portal) {
    CAPortalLayer* p = [portal layer];
    for (NSString* k in @[@"matchesPosition", @"matchesTransform", @"matchesOpacity"])
        if ([p respondsToSelector:NSSelectorFromString(k)])
            [p setValue:@NO forKey:k];
    p.actions = @{@"bounds": NSNull.null, @"position": NSNull.null, @"transform": NSNull.null, @"opacity": NSNull.null};
    p.anchorPoint = CGPointMake(0.5, 0.5);
    p.sourceLayer = source;
    return p;
}

static NSSize pane_size(RXNode* n) {
    NSSize s = g_pane_rect.size;
    CGSize b = n.layer.bounds.size;
    return s.width > 1 && s.height > 1 ? s : NSMakeSize(MAX(b.width, 1), MAX(b.height, 1));
}

static NSString* session_of(RXNode* n) {
    return str(n, P::session, @"");
}

@implementation RXTabPreviewLayer

- (void)drop:(NSNumber*)tab {
    CALayer* l = self.portals[tab];
    if (!l)
        return;
    [l removeFromSuperlayer];
    [self.portals removeObjectForKey:tab];
    term_tab_watch(self.sources[tab], false);
    [self.sources removeObjectForKey:tab];
}

- (void)dropInput {
    RXTermInput* i = self.input;
    if (!i)
        return;
    self.input = nil;
    if (RXNode* n = self.node)
        n.editor = nil;
    term_input_close(i);
}

- (void)closeAll {
    for (NSNumber* tab in self.portals.allKeys)
        [self drop:tab];
    [self dropInput];
}

- (void)makeSession {
    if (self.making)
        return;
    self.making = true;
    RXNode* n = self.node;
    NSString* label = session_of(n);
    id cmd = obj(n, P::command);
    NSArray* command = [cmd isKindOfClass:NSArray.class] ? cmd : [cmd isKindOfClass:NSString.class] ? @[cmd] : @[];
    NSString* cwd = [str(n, P::cwd, @"~") stringByExpandingTildeInPath];
    __weak RXTabPreviewLayer* weak = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData* data = rex_cli(@[@"session", @"inspect", label, @"--json"], nil);
        NSDictionary* info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        bool there = [info isKindOfClass:NSDictionary.class];
        bool empty = there && !([info[@"windows"] isKindOfClass:NSArray.class] && [info[@"windows"] count]);
        NSString* error = nil;
        if ((!there || empty) && command.count) {
            NSMutableArray* args = [(there ? @[@"run", @"-s", label, @"--focus=false", @"--cwd", cwd, @"--"]
                                           : @[@"new", label, @"--cwd", cwd, @"--"]) mutableCopy];
            [args addObjectsFromArray:command];
            NSString* what = there ? @"given a new tab" : @"made";
            if (!rex_cli(args, &error))
                rexui_log([NSString stringWithFormat:@"TabPreview: session %@ not %@: %@", label, what, error]);
            else
                rexui_log([NSString stringWithFormat:@"TabPreview: session %@ %@ (%@)", label, what,
                                                     [command componentsJoinedByString:@" "]]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            RXTabPreviewLayer* l = weak;
            if (!l)
                return;
            l.making = false;
            [l update];
        });
    });
}

- (void)opened:(RXTermInput*)i {
    self.input = i;
    self.node.editor = i;
    if (i)
        term_input_fit(i, self.bounds.size);
}

- (void)updateInput {
    RXNode* n = self.node;
    NSString* label = session_of(n);
    bool want = n && node_on_screen(n) && (label.length || (self.tab > 0 && self.tab <= rex_tab_count()));
    if (!want) {
        if (!self.input)
            return;
        NSUInteger gen = ++self.closing;
        __weak RXTabPreviewLayer* weak = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
            RXTabPreviewLayer* l = weak;
            if (l && l.closing == gen)
                [l dropInput];
        });
        return;
    }
    self.closing++;
    if (self.input && !label.length) {
        NSString* now = (__bridge_transfer NSString*)rex_tab_id(self.tab - 1);
        if (![term_input_window(self.input) isEqual:now])
            [self dropInput];
    }
    if (self.input)
        return term_input_fit(self.input, self.bounds.size);
    if (!label.length) {
        NSString* window = (__bridge_transfer NSString*)rex_tab_id(self.tab - 1);
        if (window)
            [self opened:term_input_open(n, window, nil)];
        return;
    }
    if (self.finding)
        return;
    self.finding = true;
    __weak RXTabPreviewLayer* weak = self;
    term_session_find(label, ^(NSString* session, NSString* window) {
        RXTabPreviewLayer* l = weak;
        if (!l)
            return;
        l.finding = false;
        RXNode* node = l.node;
        if (!node || !node_on_screen(node) || l.input)
            return;
        if (window) {
            l.looks = 0;
            [l opened:term_input_open(node, window, session)];
            return;
        }
        if (l.looks == 0)
            [l makeSession];
        if (++l.looks > 40) {
            rexui_log([NSString stringWithFormat:@"TabPreview: no session %@ after 10 s", label]);
            l.looks = 0;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
            [weak update];
        });
    });
}

- (void)update {
    RXNode* n = self.node;
    if (!n)
        return;
    if (session_of(n).length || flag(n, P::interactive, false))
        return [self updateInput];
    bool want = node_on_screen(n) && self.tab > 0 && self.tab <= rex_tab_count();
    if (!want) {
        for (NSNumber* t in self.portals.allKeys)
            [self drop:t];
        return;
    }
    NSNumber* tab = @(self.tab);
    CALayer* src = term_tab_layer((__bridge_transfer NSString*)rex_tab_id(self.tab - 1));
    if (self.portals[tab] && self.sources[tab] != src)
        [self drop:tab];
    Class portal = NSClassFromString(@"CAPortalLayer");
    if (!self.portals[tab] && portal && src)
        [self addPortal:src tab:tab class:portal];
    for (NSNumber* k in self.portals) {
        float o = [k isEqual:tab] ? 1 : 0;
        CALayer* l = self.portals[k];
        if (l.opacity != o)
            fade_layer(l, o, 180, nil);
    }
    [self placePortals];
}

- (void)addPortal:(CALayer*)source tab:(NSNumber*)tab class:(Class)portal {
    if (!self.portals)
        self.portals = [NSMutableDictionary dictionary], self.sources = [NSMutableDictionary dictionary];
    CALayer* l = portal_layer(source, portal);
    l.opacity = 0;
    [self addSublayer:l];
    self.portals[tab] = l;
    self.sources[tab] = source;
    term_tab_watch(source, true);
}

- (void)placePortals {
    if (!self.portals.count)
        return;
    CGSize b = self.bounds.size;
    CGFloat z = num(self.node, P::zoom, 0) ?: g_config.tab_preview_zoom;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (NSNumber* k in self.portals) {
        CALayer* l = self.portals[k];
        CGSize p = self.sources[k].bounds.size;
        if (p.width < 1 || p.height < 1 || b.width < 1 || b.height < 1)
            continue;
        CGFloat s = MIN(b.width / p.width, b.height / p.height) * MAX(1, z);
        CGSize f = CGSizeMake(p.width * s, p.height * s);
        l.bounds = CGRectMake(0, 0, p.width, p.height);
        l.position = CGPointMake(MAX(0, (b.width - f.width) / 2) + f.width / 2,
                                 MAX(0, (b.height - f.height) / 2) + f.height / 2);
        l.transform = CATransform3DMakeScale(s, s, 1);
    }
    [CATransaction commit];
}

- (void)lookBlank {
    RXNode* n = self.node;
    NSNumber* tab = @(self.tab);
    NSString* why = nil;
    if (n && node_on_screen(n) && !self.input && self.tab > 0) {
        CALayer* p = self.portals[tab];
        why = !p              ? (self.tab <= rex_tab_count()
                                     ? [NSString stringWithFormat:@"tab %ld has no portal (no tab of rexui's for it)", self.tab]
                                     : nil)
            : p.opacity > 0.5 ? term_tab_blank(self.sources[tab])
                              : nil;
    }
    if (!why) {
        if (self.blank >= 2)
            rexui_log_file([NSString stringWithFormat:@"TabPreview: tab %ld drawn again", self.tab]);
        self.blank = 0;
        return;
    }
    if (++self.blank == 2)
        rexui_log([NSString stringWithFormat:@"TabPreview: on screen and blank: %@", why]);
}

- (void)dealloc {
    for (NSNumber* tab in _portals.allKeys) {
        CALayer* src = _sources[tab];
        [_portals[tab] removeFromSuperlayer];
        dispatch_async(dispatch_get_main_queue(), ^{
            term_tab_watch(src, false);
        });
    }
    if (RXTermInput* i = _input)
        dispatch_async(dispatch_get_main_queue(), ^{
            term_input_close(i);
        });
}

@end

CALayer* make_tabpreview(RXNode* n) {
    RXTabPreviewLayer* l = [RXTabPreviewLayer layer];
    l.node = n;
    l.masksToBounds = YES;
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
                                                         [(RXTabPreviewLayer*)p.layer update],
                                                             [(RXTabPreviewLayer*)p.layer lookBlank];
                                                 }];
    [g_previews addObject:n];
    return l;
}

static RXTabPreviewLayer* preview_of(RXNode* n) {
    return [n.layer isKindOfClass:RXTabPreviewLayer.class] ? (RXTabPreviewLayer*)n.layer : nil;
}

void tabpreview_update(RXNode* n) {
    [preview_of(n) update];
}

void apply_tabpreview(RXNode* n, NSString* name) {
    RXTabPreviewLayer* l = preview_of(n);
    if ([name isEqualToString:@"tab"] || [name isEqualToString:@"session"] || [name isEqualToString:@"interactive"]) {
        l.tab = (long)num(n, P::tab, 0);
        [l closeAll];
        [l update];
    } else if ([name isEqualToString:@"zoom"]) {
        [l placePortals];
    } else if ([name isEqualToString:@"radius"]) {
        l.cornerRadius = num(n, P::radius, 0);
        l.cornerCurve = kCACornerCurveContinuous;
    }
}

NSSize measure_tabpreview(RXNode* n, CGFloat width) {
    if (has_num(n, P::width))
        width = num(n, P::width, width);
    if (session_of(n).length && has_num(n, P::height))
        return NSMakeSize(width, num(n, P::height, 300));
    NSSize p = pane_size(n);
    return NSMakeSize(width, round(width * p.height / p.width));
}

void tabpreview_shown(RXNode* n) {
    if (is_elem(n, E::TabPreview))
        tabpreview_update(n);
    if (is_elem(n, E::PanePreview))
        pane_preview_update(n);
    for (RXNode* c in n.children)
        tabpreview_shown(c);
}

void tabpreview_gone(RXNode* n) {
    RXTabPreviewLayer* l = preview_of(n);
    [l dropInput];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{
        [l update];
    });
}

void tabpreview_config_changed(void) {
    term_tabs_config_changed();
    rex_slide_config_changed();
    for (RXNode* n in g_previews.allObjects)
        [preview_of(n) placePortals];
}
