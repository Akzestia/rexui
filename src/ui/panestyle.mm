// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <objc/message.h>
#include <pthread.h>
#include <unordered_set>
#include "base/trace.h"
#include "web/web.h"

#include "chrome/chrome.h"
#include "rex/rex.h"

#include <objc/runtime.h>

static bool g_link;
static uint32_t g_tick, g_glide;
static void pane_tick(id, const RXFrame*);
static void pane_tick_wake(void) {
    if (g_link && !g_tick)
        g_tick = ui_clock_add(RX_TICK_PANES, 4, pane_style_host(), nil, pane_tick);
}
static NSMapTable<NSString*, NSView*>* g_views;
static NSMapTable<CALayer*, RXNode*>* g_hosts;
static NSMapTable<RXNode*, CALayer*>* g_host_of;
static NSMutableSet<CALayer*>* g_all_hosts;
static NSMapTable<NSView*, NSArray<CAShapeLayer*>*>* g_rex_borders;
static NSMapTable<NSView*, NSNumber*>* g_borders_read;
static char k_border_mask;

static CALayer* host_for(RXNode* c) {
    CALayer* h = [g_host_of objectForKey:c];
    return h && [g_hosts objectForKey:h] == c ? h : nil;
}

static Class plane_class(void) {
    static Class c = NSClassFromString(RXNS(RXN_185));
    return c;
}
static bool rex_border_like(CAShapeLayer* s) {
    bool no_fill = !s.fillColor || CGColorGetAlpha(s.fillColor) == 0;
    CGSize b = s.bounds.size, p = s.superlayer.bounds.size;
    return no_fill && fabs(b.width - p.width) < 2 && fabs(b.height - p.height) < 2;
}
static void find_rex_borders(NSView* v, NSMutableArray* out, int depth) {
    static NSString* terminal = RXNS(RXN_189);
    if (depth > 12 || [NSStringFromClass(v.class) containsString:terminal])
        return;
    if (plane_class() && [v isKindOfClass:plane_class()]) {
        for (CALayer* l in v.layer.sublayers) {
            if ([l isKindOfClass:CAShapeLayer.class] && rex_border_like((CAShapeLayer*)l))
                [out addObject:l];
        }
    }
    for (NSView* s in v.subviews)
        find_rex_borders(s, out, depth + 1);
}

static char k_shape;
static char k_border_path;
static char k_border_style;
static bool g_border_busy;
static bool g_border_watch;
static char k_border_done;
static void style_rex_border(CAShapeLayer* l, bool hide, NSString* spec) {
    NSArray* done = objc_getAssociatedObject(l, &k_border_done);
    CGSize size = l.bounds.size;
    if (done && [done[0] isEqualToString:spec ?: @""] && CGSizeEqualToSize([done[1] sizeValue], size) &&
        [done[2] pointerValue] == (void*)l.path && [done[3] boolValue] == hide
        && (!hide || l.mask == objc_getAssociatedObject(l, &k_border_mask)))
        return;
    g_border_busy = true;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CALayer* mask = objc_getAssociatedObject(l, &k_border_mask);
    if (hide) {
        if (!mask) {
            mask = still([CALayer layer]);
            objc_setAssociatedObject(l, &k_border_mask, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (l.mask != mask)
            l.mask = mask;
    } else if (mask) {
        if (l.mask == mask)
            l.mask = nil;
        objc_setAssociatedObject(l, &k_border_mask, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNumber* inset = objc_getAssociatedObject(l, &k_border_path);
    CGPathRef path = nullptr;
    if (hide) {
    } else if (spec.length) {
        if (!inset) {
            CGRect box = l.path ? CGPathGetBoundingBox(l.path) : l.bounds;
            inset = @(MAX(0, box.origin.x - l.bounds.origin.x));
            objc_setAssociatedObject(l, &k_border_path, inset, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGFloat in = inset.doubleValue;
        if (CGPathRef shaped =
                box_path(spec, CGSizeMake(l.bounds.size.width - 2 * in, l.bounds.size.height - 2 * in))) {
            CGAffineTransform t = CGAffineTransformMakeTranslation(l.bounds.origin.x + in, l.bounds.origin.y + in);
            path = CGPathCreateCopyByTransformingPath(shaped, &t);
            CGPathRelease(shaped);
        }
    } else if (inset) {
        CGFloat in = inset.doubleValue;
        path = CGPathCreateWithRect(CGRectInset(l.bounds, in, in), nullptr);
        objc_setAssociatedObject(l, &k_border_path, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (path && (!l.path || !CGPathEqualToPath(l.path, path)))
        l.path = path;
    CGPathRelease(path);
    [CATransaction commit];
    objc_setAssociatedObject(l, &k_border_done,
                             @[spec ?: @"", [NSValue valueWithSize:size], [NSValue valueWithPointer:l.path], @(hide)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    g_border_busy = false;
}

static void sync_rex_borders(NSView* pv, bool hide, NSString* spec) {
    if (!g_rex_borders)
        g_rex_borders = [NSMapTable weakToStrongObjectsMapTable],
        g_borders_read = [NSMapTable weakToStrongObjectsMapTable];
    double now = CACurrentMediaTime();
    NSArray<CAShapeLayer*>* ls = [g_rex_borders objectForKey:pv];
    bool want = hide || spec.length;
    NSArray* style = want ? @[@(hide), spec ?: @""] : nil;
    if (!(style == objc_getAssociatedObject(pv, &k_border_style) ||
          [style isEqual:objc_getAssociatedObject(pv, &k_border_style)]))
        objc_setAssociatedObject(pv, &k_border_style, style, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (want && (!ls || now - [[g_borders_read objectForKey:pv] doubleValue] > 1)) {
        NSMutableArray* found = [NSMutableArray array];
        find_rex_borders(pv, found, 0);
        for (CAShapeLayer* l in ls) {
            if (![found containsObject:l])
                [found addObject:l];
        }
        ls = found;
        [g_rex_borders setObject:ls forKey:pv];
        [g_borders_read setObject:@(now) forKey:pv];
    }
    for (CAShapeLayer* l in ls)
        style_rex_border(l, hide, spec);
    if (!want)
        [g_rex_borders removeObjectForKey:pv];
}

static bool rex_border_of_styled(CAShapeLayer* l, bool* hide, NSString** spec) {
    if (!g_border_watch || g_border_busy || ![NSThread isMainThread])
        return false;
    id d = l.superlayer.delegate;
    if (!plane_class() || ![d isKindOfClass:plane_class()] || !rex_border_like(l))
        return false;
    NSArray* style = nil;
    NSView* pv = (NSView*)d;
    for (int i = 0; pv && i < 16 && !(style = objc_getAssociatedObject(pv, &k_border_style)); i++)
        pv = pv.superview;
    if (!style)
        return false;
    *hide = [style[0] boolValue], *spec = [style[1] length] ? style[1] : nil;
    NSArray* ls = [g_rex_borders objectForKey:pv] ?: @[];
    if (![ls containsObject:l])
        [g_rex_borders setObject:[ls arrayByAddingObject:l] forKey:pv];
    return true;
}

void pane_mask_changed(CALayer* l) {
    if (!g_border_watch || g_border_busy || ![NSThread isMainThread])
        return;
    id v = l.delegate;
    if (![v isKindOfClass:NSView.class])
        return;
    NSString* spec = objc_getAssociatedObject(v, &k_shape);
    if (!spec.length || shape_intact(l))
        return;
    g_border_busy = true;
    shape_layer(l, spec, 0, nullptr, 0, nullptr);
    g_border_busy = false;
}

static bool touches(CAAnimation* a, NSSet<NSString*>* keys) {
    if ([a isKindOfClass:CAPropertyAnimation.class])
        return [keys containsObject:((CAPropertyAnimation*)a).keyPath ?: @""];
    if ([a isKindOfClass:CAAnimationGroup.class]) {
        for (CAAnimation* x in ((CAAnimationGroup*)a).animations) {
            if (touches(x, keys))
                return true;
        }
    }
    return false;
}
bool rex_border_drops(CALayer* l, CAAnimation* anim) {
    if (!g_border_watch || g_border_busy)
        return false;
    if (!objc_getAssociatedObject(l, &k_border_path))
        return false;
    return touches(anim, [NSSet setWithObject:@"path"]);
}

void rex_border_changed(CAShapeLayer* l) {
    bool hide = false;
    NSString* spec = nil;
    if (rex_border_of_styled(l, &hide, &spec))
        style_rex_border(l, hide, spec);
}

static NSString* g_spotlight = @"";
static NSHashTable<NSView*>* g_rounded;
static NSArray* g_list;
static NSArray* g_previews = @[];
static NSMutableSet<NSString*>* g_seen;
static double g_previews_at;
static NSString* g_list_focused = @"";
NSString* panes_focused_block(void) {
    return g_list_focused;
}
static NSDictionary* g_area;
static double g_read_at;
static char k_radius, k_masks;
static NSHashTable<NSView*>* g_shaped;
static NSSet<NSString*>* g_covered;

static NSString* const kPaneDataKey = @"pane data by distro";
static NSMutableDictionary<NSString*, NSDictionary*>* g_pane_data_all;
static NSMutableDictionary<NSString*, NSDictionary*>* g_pane_data;
static NSString* g_pane_scope;
static __weak RXDoc* g_pane_scope_doc;
static bool g_pane_scope_read;

static NSString* pane_scope_now(void) {
    NSString* d = ui_dir();
    return [d isEqualToString:default_ui_dir()] ? @"default" : d.lastPathComponent;
}

static void pane_scope(RXDoc* panes_doc) {
    if (g_pane_scope_read && g_pane_scope_doc == panes_doc)
        return;
    g_pane_scope_read = true;
    g_pane_scope_doc = panes_doc;
    if (!g_pane_data_all) {
        g_pane_data_all = [([g_state dictionaryForKey:kPaneDataKey] ?: @{}) mutableCopy];
        if (NSDictionary* old = [g_state dictionaryForKey:@"pane data"]) {
            NSString* to = pane_scope_now();
            if (old.count && !g_pane_data_all[to])
                g_pane_data_all[to] = old;
            [g_state setObject:g_pane_data_all forKey:kPaneDataKey];
            [g_state removeObjectForKey:@"pane data"];
            rexui_log([NSString
                stringWithFormat:@"panes: pane data moved to %@'s (%lu panes)", to, (unsigned long)old.count]);
        }
    }
    NSString* now = pane_scope_now();
    if ([now isEqualToString:g_pane_scope])
        return;
    g_pane_scope = now;
    g_pane_data = [(g_pane_data_all[now] ?: @{}) mutableCopy];
    g_list = nil;
    g_read_at = 0;
    rexui_log([NSString stringWithFormat:@"panes: %@'s pane data (%lu panes)", now, (unsigned long)g_pane_data.count]);
}

static NSMutableDictionary<NSString*, NSDictionary*>* pane_data(void) {
    if (!g_pane_data)
        pane_scope(g_pane_scope_doc);
    return g_pane_data;
}

static void pane_data_save(void) {
    if (!g_pane_scope)
        return;
    if (g_pane_data.count)
        g_pane_data_all[g_pane_scope] = [g_pane_data copy];
    else
        [g_pane_data_all removeObjectForKey:g_pane_scope];
    [g_state setObject:g_pane_data_all forKey:kPaneDataKey];
}

static NSArray<RXDoc*>* style_docs(void);

void pane_data_set(NSString* bid, NSString* key, id value) {
    if (!bid.length || !key.length)
        return;
    pane_scope(style_docs().firstObject);
    NSMutableDictionary* mine = [(pane_data()[bid] ?: @{}) mutableCopy];
    if (!value || value == NSNull.null)
        [mine removeObjectForKey:key];
    else
        mine[key] = value;
    if (mine.count)
        pane_data()[bid] = mine;
    else
        [pane_data() removeObjectForKey:bid];
    pane_data_save();
    g_list = nil;
    g_read_at = 0;
    pane_styles_focus();
}

static NSArray<RXDoc*>* style_docs(void) {
    NSMutableArray* out = [NSMutableArray array];
    for (RXDoc* d in g_docs) {
        if (d.ctx && d.root && is_elem(d.root, E::Panes))
            [out addObject:d];
    }
    return out;
}

static NSString* pane_shape(NSString* bid, RXNode* root, NSView* pv = nil) {
    id own = bid ? pane_data()[bid][@"shape"] : nil;
    NSString* spec = [own isKindOfClass:NSString.class] && [own length] ? ([own isEqualToString:@"none"] ? @"" : own)
        : root                                                          ? str(root, P::shape, @"")
                                                                        : @"";
    NSDictionary* hole = root ? obj(root, P::hole) : nil;
    NSView* window = pane_style_host();
    if (![hole isKindOfClass:NSDictionary.class] || ![hole[@"r"] isKindOfClass:NSNumber.class] || !pv || !window)
        return spec;
    const double hx = num_of(hole[@"x"], 0.5), hy = num_of(hole[@"y"], 0.5);
    NSPoint c =
        NSMakePoint(hx * window.bounds.size.width, (window.isFlipped ? hy : 1 - hy) * window.bounds.size.height);
    NSPoint at = [pv convertPoint:c fromView:window];
    if (!pv.isFlipped)
        at.y = pv.bounds.size.height - at.y;
    at.x -= pv.bounds.origin.x, at.y -= pv.bounds.origin.y;
    bool tri = [hole[@"shape"] isKindOfClass:NSString.class] && [hole[@"shape"] isEqualToString:@"triangle"];
    return [NSString stringWithFormat:@"%@; hole %.1f %.1f %.1f%@", spec.length ? spec : @"square", at.x, at.y,
                                      MAX(0, [hole[@"r"] doubleValue]), tri ? @" tri" : @""];
}

static NSView* pane_content(void) {
    NSWindow* w = dock_window();
    NSView* chrome = w ? chrome_of(w) : nil;
    return chrome ? chrome_content(chrome) : nil;
}

NSDictionary<NSString*, NSView*>* pane_views_now(void) {
    NSMutableDictionary* out = [NSMutableDictionary dictionary];
    for (NSString* k in g_views)
        if (NSView* v = [g_views objectForKey:k])
            out[k] = v;
    return out;
}

NSView* pane_style_host(void) {
    NSWindow* w = dock_window();
    return w ? chrome_of(w) : nil;
}

static NSString* block_of(NSString* key) {
    NSRange r = [key rangeOfString:@"#"];
    return r.location == NSNotFound ? key : [key substringToIndex:r.location];
}
static NSView* view_for(NSString* key) {
    return [g_views objectForKey:key];
}
static NSMapTable<NSString*, CALayer*>* g_term_panes;

static NSArray* read_previews(NSArray<RXDoc*>* docs, NSString* focused) {
    g_previews_at = CACurrentMediaTime();
    pane_scope(docs.firstObject);
    {
        if (!g_term_panes)
            g_term_panes = [NSMapTable strongToWeakObjectsMapTable];
        [g_term_panes removeAllObjects];
        NSMutableArray* out = [NSMutableArray array];
        for (NSDictionary* p in term_preview_panes()) {
            NSString* bid = p[@"block"];
            if (!g_seen)
                g_seen = [NSMutableSet set];
            [g_seen addObject:bid];
            [g_term_panes setObject:p[@"layer"] forKey:p[@"key"]];
            RXDoc* shows = panes_doc_of_block(bid);
            [out addObject:@{
                @"id": bid,
                @"key": p[@"key"],
                @"preview": @YES,
                @"index": p[@"index"],
                @"focused": p[@"focused"],
                @"tabPanes": p[@"tabPanes"],
                @"floating": @NO,
                @"zoomed": p[@"zoomed"] ?: @NO,
                @"covered": p[@"covered"] ?: @NO,
                @"fullscreen": p[@"fullscreen"] ?: @NO,
                @"spotlight": @NO,
                @"data": pane_data()[bid] ?: @{},
                @"rui": shows.path ?: @"",
                @"devtools": @(shows.devtools),
                @"app": panes_app_of_block(bid) ?: @"",
                @"quitting": @(panes_app_quitting(bid)),
                @"appDrawn": @(panes_app_drawn(bid)),
                @"shape": pane_shape(bid, docs.firstObject.root),
                @"width": p[@"width"],
                @"height": p[@"height"]
            }];
        }
        return out;
    }
}

static std::unordered_set<const void*> g_pane_layers;
static uint64_t g_moved;
static uint64_t g_lists;
static int g_quiet;
static std::unordered_set<const void*> g_resized;
static bool g_place_armed;
static void place_resized(void);
static NSTimer* g_backstop;

void pane_styles_wake(void) {
    g_quiet = 0;
    pane_tick_wake();
}

extern "C" void rexui_layer_resized(CALayer* l) {
    if (!pthread_main_np() || g_pane_layers.empty() || !g_pane_layers.count((__bridge const void*)l))
        return;
    pane_styles_wake();
    g_resized.insert((__bridge const void*)l);
    if (g_place_armed)
        return;
    static SEL sel = @selector(addCommitHandler:forPhase:);
    static bool has = [CATransaction respondsToSelector:sel];
    using Add = BOOL (*)(id, SEL, void (^)(void), int);
    constexpr int kPreCommit = 1;
    g_place_armed = true;
    if (!has
        || !((Add)objc_msgSend)(
            [CATransaction class], sel,
            ^{
                place_resized();
            },
            kPreCommit))
        dispatch_async(dispatch_get_main_queue(), ^{
            place_resized();
        });
}

static void backstop(bool on);

static NSSet<NSString*>* g_last_ids;
static NSString* g_last_focus = @"";
static void inherit_looks(NSDictionary<NSString*, NSDictionary*>* all, NSString* focused) {
    if (!g_seen)
        g_seen = [NSMutableSet set];
    NSMutableSet<NSString*>* ids = [NSMutableSet set];
    for (NSString* bid in all)
        if ([all[bid][@"view"] window])
            [ids addObject:bid];
    NSString* from = g_last_focus;
    bool split_ok =
        g_config.pane_inherit.count && from.length && [g_last_ids containsObject:from] && [ids containsObject:from];
    NSDictionary* src = split_ok ? pane_data()[from] : nil;
    bool wrote = false;
    for (NSString* bid in ids) {
        if ([g_seen containsObject:bid])
            continue;
        [g_seen addObject:bid];
        RXDoc* shows = panes_doc_of_block(bid);
        if (!src.count || pane_data()[bid].count || shows.devtools)
            continue;
        NSMutableDictionary* mine = [NSMutableDictionary dictionary];
        for (NSString* k in g_config.pane_inherit)
            if (id v = src[k])
                mine[k] = v;
        if (!mine.count)
            continue;
        pane_data()[bid] = mine;
        wrote = true;
        rexui_log([NSString stringWithFormat:@"panes: %@ split from %@, its look kept (%@)", bid, from,
                                             [mine.allKeys componentsJoinedByString:@", "]]);
    }
    if (wrote)
        pane_data_save();
    g_last_ids = ids;
    if (focused.length)
        g_last_focus = focused;
}

static void read_panes(NSArray<RXDoc*>* docs) {
    pane_scope(docs.firstObject);
    g_read_at = CACurrentMediaTime();
    NSView* content = pane_content();
    if (!content)
        return;
    void* raw = rex_all_panes((__bridge const void*)content);
    if (!raw)
        return;
    NSDictionary<NSString*, NSDictionary*>* all = (__bridge_transfer NSDictionary*)raw;
    if (!g_views)
        g_views = [NSMapTable strongToWeakObjectsMapTable];
    [g_views removeAllObjects];
    NSResponder* r = content.window.firstResponder;
    NSView* focus = [r isKindOfClass:NSView.class] ? (NSView*)r : nil;
    NSString* arrived_focus = nil;
    if (NSDictionary* arrived = term_arrived_tab()) {
        NSSet* tab = arrived[@"blocks"];
        NSMutableDictionary* only = [NSMutableDictionary dictionary];
        bool focus_in = false;
        for (NSString* bid in all) {
            if (![tab containsObject:bid])
                continue;
            only[bid] = all[bid];
            NSView* v = all[bid][@"view"];
            focus_in |= focus && v.window && [focus isDescendantOf:v];
        }
        if (only.count) {
            all = only;
            if (!focus_in && [arrived[@"focused"] length] && only[arrived[@"focused"]])
                arrived_focus = arrived[@"focused"];
        }
    }
    NSMutableArray<NSDictionary*>* items = [NSMutableArray array];
    NSString* focused = @"";
    NSString* zoomed = rexstate_zoomed();
    NSMutableSet* covered = [NSMutableSet set];
    g_pane_layers.clear();
    {
        NSString* now = @"";
        for (NSString* bid in all) {
            NSView* v = all[bid][@"view"];
            if (arrived_focus ? [bid isEqualToString:arrived_focus] : v.window && focus && [focus isDescendantOf:v])
                now = bid;
        }
        inherit_looks(all, now);
    }
    for (NSString* bid in all) {
        NSView* v = all[bid][@"view"];
        if (!v.window)
            continue;
        [g_views setObject:v forKey:bid];
        if (v.layer)
            g_pane_layers.insert((__bridge const void*)v.layer);
        NSRect f = [v convertRect:v.bounds toView:content];
        if (!content.isFlipped)
            f.origin.y = content.bounds.size.height - NSMaxY(f);
        bool on = arrived_focus ? [bid isEqualToString:arrived_focus] : focus && [focus isDescendantOf:v];
        if (on)
            focused = bid;
        RXDoc* shows = panes_doc_of_block(bid);
        bool floating = [all[bid][@"floating"] boolValue];
        if (zoomed.length && !floating && ![bid isEqualToString:zoomed] && all[zoomed])
            [covered addObject:bid];
        [items addObject:@{
            @"id": bid,
            @"focused": @(on),
            @"floating": @(floating),
            @"data": pane_data()[bid] ?: @{},
            @"zoomed": @([bid isEqualToString:zoomed]),
            @"covered": @([covered containsObject:bid]),
            @"fullscreen": @(panes_app_full(bid)),
            @"rui": shows.path ?: @"",
            @"devtools": @(shows.devtools),
            @"app": panes_app_of_block(bid) ?: @"",
            @"quitting": @(panes_app_quitting(bid)),
            @"appDrawn": @(panes_app_drawn(bid)),
            @"shape": pane_shape(bid, docs.firstObject.root, v),
            @"spotlight": @([bid isEqualToString:g_spotlight]),
            @"width": @(round(f.size.width)),
            @"height": @(round(f.size.height)),
            @"x": @(round(f.origin.x)),
            @"y": @(round(f.origin.y))
        }];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        if ([a[@"floating"] boolValue] != [b[@"floating"] boolValue])
            return [a[@"floating"] boolValue] ? NSOrderedDescending : NSOrderedAscending;
        if (![a[@"y"] isEqual:b[@"y"]])
            return [a[@"y"] compare:b[@"y"]];
        return [a[@"x"] compare:b[@"x"]];
    }];
    NSUInteger tab_panes = 0;
    for (NSDictionary* it in items)
        if (![it[@"devtools"] boolValue])
            tab_panes++;
    NSMutableArray* list = [NSMutableArray array];
    for (NSUInteger i = 0; i < items.count; i++) {
        NSMutableDictionary* e = [items[i] mutableCopy];
        e[@"index"] = @(i);
        e[@"tabPanes"] = @(tab_panes);
        [list addObject:e];
    }
    g_covered = covered;
    debug_pane_focused(focused);
    NSDictionary* area =
        @{@"width": @(round(content.bounds.size.width)),
          @"height": @(round(content.bounds.size.height))};
    bool live_same =
        [list isEqualToArray:g_list] && [focused isEqualToString:g_list_focused] && [area isEqualToDictionary:g_area];
    g_area = area;
    NSArray* previews = g_previews;
    if (!live_same || !g_term_panes || CACurrentMediaTime() - g_previews_at > 1)
        previews = read_previews(docs, focused);
    if (live_same && [previews isEqualToArray:g_previews])
        return;
    g_lists++;
    g_list = list;
    if (![focused isEqualToString:g_list_focused])
        dispatch_async(dispatch_get_main_queue(), ^{
            shaders_panes_changed();
        });
    g_list_focused = focused;
    g_previews = previews;
    for (RXDoc* d in [g_docs copy]) {
        if (d.ctx)
            doc_call(d, @"setPanes", @[@{@"list": list, @"focused": focused, @"previews": previews, @"area": area}]);
    }
}

static void restore_corners(NSView* v) {
    NSNumber *r = objc_getAssociatedObject(v, &k_radius), *m = objc_getAssociatedObject(v, &k_masks);
    if (r)
        v.layer.cornerRadius = r.doubleValue;
    if (m)
        v.layer.masksToBounds = m.boolValue;
    objc_setAssociatedObject(v, &k_radius, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(v, &k_masks, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static bool sizing(CALayer* l) {
    for (NSString* k in l.animationKeys) {
        CAAnimation* a = [l animationForKey:k];
        NSArray* all = [a isKindOfClass:CAAnimationGroup.class] ? ((CAAnimationGroup*)a).animations : @[a];
        for (CAAnimation* x in all) {
            if ([x isKindOfClass:CAPropertyAnimation.class] && [((CAPropertyAnimation*)x).keyPath hasPrefix:@"bounds"])
                return true;
        }
    }
    return false;
}

static CGRect overlay_rect(NSView* pv, CGRect f) {
    CALayer *l = pv.layer, *p = l.presentationLayer;
    if (p && sizing(l)) {
        CGFloat mx = CGRectGetMinX(l.bounds) - CGRectGetMinX(f), my = CGRectGetMinY(l.bounds) - CGRectGetMinY(f);
        f.size = CGSizeMake(p.bounds.size.width + 2 * mx, p.bounds.size.height + 2 * my);
    }
    CGFloat s = pv.window.backingScaleFactor ?: backing_scale();
    if (s <= 0)
        return f;
    NSRect w = [pv convertRect:NSRectFromCGRect(f) toView:nil];
    CGFloat x0 = ceil(NSMinX(w) * s - 0.01) / s, x1 = floor(NSMaxX(w) * s + 0.01) / s;
    CGFloat y0 = ceil(NSMinY(w) * s - 0.01) / s, y1 = floor(NSMaxY(w) * s + 0.01) / s;
    if (x1 - x0 < 2 || y1 - y0 < 2)
        return f;
    NSRect back = [pv convertRect:NSMakeRect(x0, y0, x1 - x0, y1 - y0) fromView:nil];
    return NSRectToCGRect(back);
}

static void place_decoration(RXNode* c, RXNode* root, bool force, bool checks) {
    NSString* key = [obj(c, @"paneId") isKindOfClass:NSString.class] ? obj(c, @"paneId") : nil;
    NSString* bid = key ? block_of(key) : nil;
    bool over = [obj(c, @"paneSlot") isEqual:@"overlay"];
    NSView* pv = key ? view_for(key) : nil;
    CALayer* pl = pv ? pv.layer : key ? [g_term_panes objectForKey:key] : nil;
    CALayer* host = host_for(c);
    if (!host) {
        host = still([RXLayer layer]);
        [g_hosts setObject:c forKey:host];
        [g_host_of setObject:host forKey:c];
        [g_all_hosts addObject:host];
    }
    if (!pl || !c.layer) {
        host.hidden = YES;
        return;
    }
    CGFloat m = num(root, P::margin, 0);
    CGRect f = CGRectInset(pl.bounds, -m, -m);
    if (over && pv)
        f = overlay_rect(pv, f);
    bool hidden = !flag(c, P::visible, true) || ([key isEqualToString:bid] && [g_covered containsObject:bid]);
    if (!force && host.superlayer == pl && c.layer.superlayer == host && host.hidden == hidden
        && CGRectEqualToRect(host.frame, f))
        goto styled;
    g_moved++;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (host.superlayer != pl) {
        [host removeFromSuperlayer];
        if (over)
            [pl addSublayer:host];
        else
            [pl insertSublayer:host atIndex:0];
        host.zPosition = over ? 1000 : -1000;
        force = true;
    }
    if (c.layer.superlayer != host) {
        [host addSublayer:c.layer];
        force = true;
    }
    if (host.hidden != hidden) {
        host.hidden = hidden;
        if (!hidden)
            force = true;
    }
    if (!CGRectEqualToRect(host.frame, f)) {
        host.frame = f;
        force = true;
    }
    [CATransaction commit];
    if (force) {
        place(c, NSMakeRect(0, 0, f.size.width, f.size.height));
        shaders_moved(c.layer);
        shaders_shown(c.layer);
    }
styled:;
    if (!force && !checks)
        return;
    if (!pv) {
        NSString* spec = pane_shape(bid, root);
        if (force || ![objc_getAssociatedObject(pl, &k_shape) isEqual:spec]) {
            objc_setAssociatedObject(pl, &k_shape, spec, OBJC_ASSOCIATION_COPY_NONATOMIC);
            shape_layer(pl, spec, 0, nullptr, 0, nullptr);
        }
        return;
    }
    NSString* spec = pane_shape(bid, root, pv);
    if (!g_rounded)
        g_rounded = [NSHashTable weakObjectsHashTable];
    if (spec.length) {
        [g_rounded addObject:pv];
        [g_shaped addObject:pv];
        if (force || ![objc_getAssociatedObject(pv, &k_shape) isEqual:spec] || !shape_intact(pv.layer)) {
            bool changed = objc_getAssociatedObject(pv, &k_shape) != nil && shape_intact(pv.layer);
            objc_setAssociatedObject(pv, &k_shape, spec, OBJC_ASSOCIATION_COPY_NONATOMIC);
            shape_layer(pv.layer, spec, changed ? num(root, P::animation, 300) : 0, nullptr, 0, nullptr);
        }
    }
    sync_rex_borders(pv, !flag(root, P::rexBorder, false),
                     [g_shaped containsObject:pv] ? objc_getAssociatedObject(pv, &k_shape) : nil);
    double r = num(root, P::radius, -1);
    if (r >= 0) {
        if (!objc_getAssociatedObject(pv, &k_radius)) {
            objc_setAssociatedObject(pv, &k_radius, @(pv.layer.cornerRadius), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(pv, &k_masks, @(pv.layer.masksToBounds), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [g_rounded addObject:pv];
        }
        CGFloat want = [g_shaped containsObject:pv] ? 0 : r;
        if (pv.layer.cornerRadius != want)
            pv.layer.cornerRadius = want;
        if (pv.layer.cornerCurve != kCACornerCurveContinuous)
            pv.layer.cornerCurve = kCACornerCurveContinuous;
        if (!pv.layer.masksToBounds)
            pv.layer.masksToBounds = YES;
    }
}

static void place_all(NSArray<RXDoc*>* docs, bool force, bool checks = true) {
    if (!g_hosts)
        g_hosts = [NSMapTable strongToWeakObjectsMapTable], g_host_of = [NSMapTable weakToWeakObjectsMapTable],
        g_all_hosts = [NSMutableSet set];
    checks |= force;
    static NSArray<RXDoc*>* last_docs;
    bool sweep = checks || ![docs isEqualToArray:last_docs ?: @[]];
    last_docs = [docs copy];
    NSMutableSet* live = sweep ? [NSMutableSet set] : nil;
    bool radii = false;
    g_border_watch = docs.count > 0;
    if (checks)
        g_shaped = [NSHashTable weakObjectsHashTable];
    for (RXDoc* d in docs) {
        radii |= num(d.root, P::radius, -1) >= 0;
        for (RXNode* c in [d.root.children copy]) {
            [live addObject:c];
            if (!checks) {
                id key = obj(c, @"paneId");
                if ([key isKindOfClass:NSString.class] && [key containsString:@"#"])
                    continue;
            }
            place_decoration(c, d.root, force, checks);
        }
    }
    if (sweep) {
        for (CALayer* h in [g_all_hosts allObjects]) {
            RXNode* c = [g_hosts objectForKey:h];
            if (c && [live containsObject:c])
                continue;
            [h removeFromSuperlayer];
            [g_hosts removeObjectForKey:h];
            [g_all_hosts removeObject:h];
        }
    }
    {
        RXNode* root = docs.firstObject.root;
        NSDictionary* hole = root ? obj(root, P::hole) : nil;
        NSView* window = pane_style_host();
        NSString* spec = @"";
        if (window && [hole isKindOfClass:NSDictionary.class] && [hole[@"r"] isKindOfClass:NSNumber.class] &&
            [hole[@"r"] doubleValue] > 0) {
            NSSize s = window.bounds.size;
            bool tri = [hole[@"shape"] isKindOfClass:NSString.class] && [hole[@"shape"] isEqualToString:@"triangle"];
            spec = [NSString stringWithFormat:@"square; hole %.1f %.1f %.1f%@", num_of(hole[@"x"], 0.5) * s.width,
                                              num_of(hole[@"y"], 0.5) * s.height, [hole[@"r"] doubleValue],
                                              tri ? @" tri" : @""];
        }
        panes_full_hole(spec);
    }
    if (!checks)
        return;
    for (NSView* v in g_rounded.allObjects) {
        if (![g_shaped containsObject:v] && objc_getAssociatedObject(v, &k_shape)) {
            shape_layer(v.layer, @"", 0, nullptr, 0, nullptr);
            objc_setAssociatedObject(v, &k_shape, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        if (!radii)
            restore_corners(v);
    }
    if (!radii && !g_shaped.count)
        [g_rounded removeAllObjects];
    NSArray<NSView*>* styled = g_views.objectEnumerator.allObjects ?: @[];
    for (NSView* v in [[g_rex_borders keyEnumerator] allObjects]) {
        if (!docs.count || ![styled containsObject:v])
            sync_rex_borders(v, false, nil);
    }
}

static void backstop(bool on);

static bool any_sizing(void) {
    for (NSView* v in g_views.objectEnumerator)
        if (v.layer.animationKeys.count && sizing(v.layer))
            return true;
    return false;
}

static void glide_tick(id, const RXFrame*) {
    RX_INTERVAL(panes, "glide");
    NSArray<RXDoc*>* docs = style_docs();
    if (docs.count)
        place_all(docs, false, false);
    if (docs.count && any_sizing())
        return;
    ui_clock_remove(g_glide);
    g_glide = 0;
}

static void follow_sizing(void) {
    if (!g_glide && g_link && any_sizing())
        g_glide = ui_clock_add(RX_TICK_PANES, 60, pane_style_host(), nil, glide_tick);
}

static void place_resized(void) {
    RX_INTERVAL(panes, "resized");
    g_place_armed = false;
    if (g_resized.empty())
        return;
    for (RXDoc* d in style_docs()) {
        for (RXNode* c in [d.root.children copy]) {
            NSString* key = [obj(c, @"paneId") isKindOfClass:NSString.class] ? obj(c, @"paneId") : nil;
            NSView* pv = key ? view_for(key) : nil;
            if (pv.layer && g_resized.count((__bridge const void*)pv.layer))
                place_decoration(c, d.root, false, false);
        }
    }
    g_resized.clear();
    follow_sizing();
}

static void stop_link(void) {
    ui_clock_remove(g_tick);
    ui_clock_remove(g_glide);
    g_tick = g_glide = 0;
    g_link = false;
    g_resized.clear();
    g_pane_layers.clear();
    backstop(false);
}

static void pane_tick(id, const RXFrame*) {
    RX_INTERVAL(panes, "ticker");
    NSArray<RXDoc*>* docs = style_docs();
    if (!docs.count) {
        place_all(@[], false);
        g_list = nil;
        return stop_link();
    }
    if (CACurrentMediaTime() - g_read_at < 0.2)
        return;
    uint64_t was = g_moved + g_lists;
    read_panes(docs);
    place_all(docs, false, true);
    follow_sizing();
    if (g_moved + g_lists != was)
        g_quiet = 0;
    else if (++g_quiet >= 2 && g_tick) {
        ui_clock_remove(g_tick);
        g_tick = 0;
        backstop(true);
    }
}

static bool g_pane_events;
void pane_styles_rex_event(bool connected) {
    term_tabs_rex_event();
    if (connected && !g_pane_events) {
        g_pane_events = true;
        if (g_backstop)
            backstop(false), backstop(true);
    }
    pane_styles_wake();
}

static void backstop(bool on) {
    if (!on) {
        [g_backstop invalidate];
        g_backstop = nil;
        return;
    }
    if (g_backstop)
        return;
    g_backstop = [NSTimer timerWithTimeInterval:g_pane_events ? 30.0 : 3.0
                                        repeats:YES
                                          block:^(NSTimer*) {
                                              RX_INTERVAL(panes, "backstop");
                                              NSArray<RXDoc*>* docs = style_docs();
                                              if (!g_link || !docs.count)
                                                  return backstop(false);
                                              if (g_tick)
                                                  return;
                                              uint64_t was = g_moved + g_lists, lists = g_lists;
                                              read_panes(docs);
                                              static int n;
                                              if (g_lists != lists || ++n % 3 == 0)
                                                  place_all(docs, false, true);
                                              if (g_moved + g_lists != was)
                                                  pane_styles_wake();
                                          }];
    g_backstop.tolerance = 0.3;
    [NSRunLoop.mainRunLoop addTimer:g_backstop forMode:NSRunLoopCommonModes];
}

void pane_styles_changed(bool relayout) {
    pane_styles_wake();
    NSArray<RXDoc*>* docs = style_docs();
    NSView* host = pane_style_host();
    if (docs.count && host && !g_link) {
        g_link = true;
        pane_tick_wake();
        g_list = nil;
        g_read_at = 0;
    }
    if (!docs.count) {
        place_all(@[], false);
        stop_link();
        return;
    }
    if (relayout) {
        read_panes(docs);
        place_all(docs, true);
    }
}

void pane_styles_new_doc(void) {
    g_list = nil;
}

void pane_styles_focus(void) {
    pane_styles_wake();
    static bool queued;
    if (!g_link || queued)
        return;
    queued = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        queued = false;
        NSArray<RXDoc*>* docs = style_docs();
        if (!docs.count)
            return;
        read_panes(docs);
        place_all(docs, false, true);
    });
}

static void reshape_list(NSArray<RXDoc*>* docs) {
    if (!g_list.count || !docs.count)
        return;
    pane_scope(docs.firstObject);
    RXNode* root = docs.firstObject.root;
    NSMutableArray* list = nil;
    for (NSUInteger i = 0; i < g_list.count; i++) {
        NSDictionary* e = g_list[i];
        NSString* bid = [e[@"id"] isKindOfClass:NSString.class] ? e[@"id"] : nil;
        NSView* v = bid ? view_for(bid) : nil;
        if (!v.window)
            continue;
        NSString* shape = pane_shape(bid, root, v);
        if ([shape isEqual:e[@"shape"]])
            continue;
        if (!list)
            list = [g_list mutableCopy];
        NSMutableDictionary* m = [e mutableCopy];
        m[@"shape"] = shape;
        list[i] = m;
    }
    if (!list)
        return;
    g_lists++;
    g_list = list;
    NSDictionary* panes =
        @{@"list": list,
          @"focused": g_list_focused ?: @"",
          @"previews": g_previews ?: @[],
          @"area": g_area ?: @{}};
    for (RXDoc* d in [g_docs copy])
        if (d.ctx)
            doc_call(d, @"setPanes", @[panes]);
}

void pane_styles_layout(void) {
    pane_styles_wake();
    if (!g_list || !g_link || CACurrentMediaTime() - g_read_at > 0.25)
        return pane_styles_changed(true);
    NSArray<RXDoc*>* docs = style_docs();
    if (!docs.count)
        return;
    place_all(docs, true);
    reshape_list(docs);
}

extern "C" void rexui_panes_now(void) {
    pane_styles_wake();
    NSArray<RXDoc*>* docs = style_docs();
    if (!docs.count)
        return;
    g_previews_at = 0;
    g_term_panes = nil;
    read_panes(docs);
    place_all(docs, true);
}

static CAShapeLayer* g_spot;
static __weak NSView* g_spot_view;

static void spot_path(CAShapeLayer* l, NSView* v) {
    CGRect b = CGRectInset(v.layer.bounds, 1.25, 1.25);
    CGPathRef path = nullptr;
    if ([v.layer.mask isKindOfClass:CAShapeLayer.class] && ((CAShapeLayer*)v.layer.mask).path) {
        path = CGPathCreateCopy(((CAShapeLayer*)v.layer.mask).path);
    } else {
        CGFloat r = MAX(
            0, MIN(v.layer.cornerRadius > 0 ? v.layer.cornerRadius : 10, MIN(b.size.width, b.size.height) / 2) - 1.25);
        path = CGPathCreateWithRoundedRect(b, r, r, nullptr);
    }
    l.frame = v.layer.bounds;
    l.path = path;
    l.shadowPath = path;
    CGPathRelease(path);
}

static void spot_out(void) {
    CAShapeLayer* l = g_spot;
    g_spot = nil;
    g_spot_view = nil;
    if (!l)
        return;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        [l removeFromSuperlayer];
    }];
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
    a.fromValue = @(((CALayer*)l.presentationLayer ?: l).opacity), a.toValue = @0, a.duration = 0.18;
    l.opacity = 0;
    [l addAnimation:a forKey:@"out"];
    [CATransaction commit];
}

void pane_spotlight(NSString* block) {
    block = [block hasPrefix:@"block:"] ? block : @"";
    if ([block isEqualToString:g_spotlight] && (g_spot || !block.length))
        return;
    g_spotlight = block;
    g_read_at = 0;
    pane_styles_focus();
    spot_out();
    if (!block.length)
        return;
    for (RXDoc* d in style_docs()) {
        if (!flag(d.root, P::spotlight, true))
            return;
    }
    NSView* content = pane_content();
    void* raw = content ? rex_all_panes((__bridge const void*)content) : nullptr;
    NSDictionary<NSString*, NSDictionary*>* all = raw ? (__bridge_transfer NSDictionary*)raw : @{};
    NSView* v = all[block][@"view"];
    if (!v.window || !v.layer)
        return;
    NSColor* accent = ui_accent() ?: NSColor.controlAccentColor;
    CAShapeLayer* l = [CAShapeLayer layer];
    l.actions = @{@"path": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null, @"opacity": NSNull.null};
    l.zPosition = 1200;
    l.fillColor = [accent colorWithAlphaComponent:0.07].CGColor;
    l.strokeColor = accent.CGColor;
    l.lineWidth = 2.5;
    l.shadowColor = accent.CGColor;
    l.shadowRadius = 14;
    l.shadowOffset = CGSizeZero;
    l.shadowOpacity = 0.9;
    l.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    spot_path(l, v);
    [v.layer addSublayer:l];
    CABasicAnimation* in = [CABasicAnimation animationWithKeyPath:@"opacity"];
    in.fromValue = @0, in.toValue = @1, in.duration = 0.2;
    [l addAnimation:in forKey:@"in"];
    CABasicAnimation* breathe = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    breathe.fromValue = @0.35, breathe.toValue = @0.95, breathe.duration = 0.9;
    breathe.autoreverses = YES, breathe.repeatCount = HUGE_VALF;
    breathe.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [l addAnimation:breathe forKey:@"breathe"];
    CABasicAnimation* line = [CABasicAnimation animationWithKeyPath:@"lineWidth"];
    line.fromValue = @2.0, line.toValue = @3.0, line.duration = 0.9;
    line.autoreverses = YES, line.repeatCount = HUGE_VALF;
    [l addAnimation:line forKey:@"line"];
    g_spot = l;
    g_spot_view = v;
}

void panes_doc_loaded(RXDoc* doc) {
    if (doc.ctx && g_list)
        doc_call(
            doc, @"setPanes",
            @[@{@"list": g_list,
                @"focused": g_list_focused,
                @"previews": g_previews ?: @[],
                @"area": g_area ?: @{}}]);
}

NSString* panes_block_at(NSWindow* w, NSPoint win) {
    NSView* content = pane_content();
    void* raw = content && content.window == w ? rex_all_panes((__bridge const void*)content) : nullptr;
    if (!raw)
        return nil;
    NSDictionary<NSString*, NSDictionary*>* all = (__bridge_transfer NSDictionary*)raw;
    NSString* best = nil;
    bool floating = false;
    for (NSString* bid in all) {
        NSView* v = all[bid][@"view"];
        if (!v.window || v.hiddenOrHasHiddenAncestor || !NSPointInRect([v convertPoint:win fromView:nil], v.bounds))
            continue;
        bool f = [all[bid][@"floating"] boolValue];
        if (!best || (f && !floating))
            best = bid, floating = f;
    }
    return best;
}
