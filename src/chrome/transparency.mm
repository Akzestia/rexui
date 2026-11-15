// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "chrome/chrome.h"

#include <pthread.h>
#include <unordered_set>
#include <vector>
#include "base/trace.h"

bool g_debug;

bool g_debug_clears;
NSMutableString* g_dump;
static NSMutableString* g_cleared;
NSHashTable<CALayer*>* g_backgrounds;
NSMapTable<CALayer*, id>* g_saved_bg;
NSMapTable<CALayer*, id>* g_saved_fill;
NSMutableSet<CALayer*>* g_dirty;
struct Watched {
    CALayer* layer;
    CGSize size;
};
static std::vector<Watched> g_watch;
static std::unordered_set<const void*> g_watching;
static uint64_t g_transforms, g_transforms_seen;

void transform_set(void) {
    if (pthread_main_np())
        g_transforms++;
}
size_t watched_count(void) {
    return g_watch.size();
}
static bool g_watch_sweep;
bool watched_due(void) {
    if (g_watch.empty())
        return false;
    static unsigned turns;
    if ((++turns & 255) == 0)
        g_watch_sweep = true;
    if (!g_watch_sweep && g_transforms == g_transforms_seen)
        return false;
    return !arm_commit();
}
static bool watched_has(CALayer* l) {
    return g_watching.count((__bridge const void*)l) != 0;
}
static void watch(CALayer* l) {
    if (!g_watching.insert((__bridge const void*)l).second)
        return;
    g_watch.push_back({l, l.bounds.size});
}
bool g_log_misses;
NSColor* g_window_bg;
double g_theme_rgb[3] = {-1, -1, -1};
NSMapTable<NSWindow*, NSValue*>* g_pane_area;

bool has_color(CGColorRef c) {
    return c && CGColorGetAlpha(c) > 0;
}
static bool ours(CALayer* layer) {
    static Class rx = NSClassFromString(@"RXLayer"), drag = NSClassFromString(@"RXPaneDragLayer"),
                 host = NSClassFromString(@"CALayerHost"), portal = NSClassFromString(@"CAPortalLayer"),
                 dock = NSClassFromString(@"RXRoot"), app = NSClassFromString(@"RXAppPaneLayer"),
                 mask = NSClassFromString(@"RXMaskLayer");
    static bool all = rx && drag && host && portal && dock && app && mask;
    if (!all)
        return ui_owns_layer(layer) || pane_drag_owns(layer) || panes_owns_layer(layer);
    for (CALayer* l = layer; l; l = l.superlayer) {
        if ([l isKindOfClass:rx] || [l isKindOfClass:drag] || [l isKindOfClass:host] || [l isKindOfClass:portal] ||
            [l isKindOfClass:mask])
            return true;
        id d = l.delegate;
        if ([l isKindOfClass:app] || (d && [d isKindOfClass:dock]))
            return true;
    }
    return false;
}

bool is_background(CALayer* layer) {
    return [g_backgrounds containsObject:layer];
}
bool transparent(void) {
    return g_config.transparency;
}

static bool g_armed;
static void process_shadows(void);
bool arm_commit(void) {
    if (g_armed)
        return true;
    static SEL sel = @selector(addCommitHandler:forPhase:);
    static bool has = [CATransaction respondsToSelector:sel];
    if (!has)
        return false;
    using Add = BOOL (*)(id, SEL, void (^)(void), int);
    constexpr int kPreCommit = 1;
    g_armed = ((Add)objc_msgSend)(
        [CATransaction class], sel,
        ^{
            g_armed = false;
            process_dirty(true);
            process_shadows();
        },
        kPreCommit);
    return g_armed;
}

static NSMapTable<CALayer*, NSNumber*>* g_shadows;
static NSHashTable<CALayer*>* g_shadow_check;

static bool floating_shadow(CALayer* l) {
    if (l.shadowOpacity <= 0 || l.shadowPath || l.contents || l.backgroundColor)
        return false;
    for (CALayer* s in l.superlayer.sublayers) {
        if (s != l && [s.compositingFilter isEqual:@"destOut"])
            return true;
    }
    return false;
}

static void fix_shadow(CALayer* l) {
    if (!transparent() || !floating_shadow(l))
        return;
    if (!g_shadows)
        g_shadows = [NSMapTable weakToStrongObjectsMapTable];
    [g_shadows setObject:@(l.shadowOpacity) forKey:l];
    orig_set_shadow_opacity(l, @selector(setShadowOpacity:), 0);
}

void hook_set_shadow_opacity(CALayer* self, SEL sel, float v) {
    orig_set_shadow_opacity(self, sel, v);
    if (v <= 0 || !transparent() || ![NSThread isMainThread])
        return;
    if (!g_shadow_check)
        g_shadow_check = [NSHashTable weakObjectsHashTable];
    [g_shadow_check addObject:self];
    arm_commit();
}

static void process_shadows(void) {
    if (!g_shadow_check.count)
        return;
    for (CALayer* l in g_shadow_check.allObjects)
        fix_shadow(l);
    [g_shadow_check removeAllObjects];
}

void restore_shadows(void) {
    for (CALayer* l in [[g_shadows keyEnumerator] allObjects]) {
        orig_set_shadow_opacity(l, @selector(setShadowOpacity:), [[g_shadows objectForKey:l] floatValue]);
    }
    [g_shadows removeAllObjects];
}

void mark_dirty(CALayer* layer) {
    if (layer && g_dirty && [NSThread isMainThread] && ![g_dirty containsObject:layer] && !ours(layer)) {
        [g_dirty addObject:layer];
        arm_commit();
    }
}

static void log_cleared(NSString* kind, CALayer* layer, CGRect r, CGColorRef c) {
    if (!g_debug)
        return;
    if (!g_cleared)
        g_cleared = [NSMutableString string];
    [g_cleared appendFormat:@"%@ %@ %@ %@\n", kind, NSStringFromClass([layer class]),
                            NSStringFromRect(NSRectFromCGRect(r)), CFBridgingRelease(CFCopyDescription(c))];
    [g_cleared writeToFile:debug_path(@"cleared.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSWindow* layer_window(CALayer* layer) {
    for (CALayer* l = layer; l; l = l.superlayer) {
        id d = l.delegate;
        if ([d isKindOfClass:[NSView class]])
            return ((NSView*)d).window;
    }
    return nil;
}

static bool is_terminal_layer(CALayer* layer) {
    static Class cls = NSClassFromString(RXNS(RXN_190));
    return cls && [layer isKindOfClass:cls];
}

static bool is_window_frame_layer(CALayer* layer) {
    static Class cls = NSClassFromString(@"CUIWindowFrameLayer");
    return cls && [layer isKindOfClass:cls];
}

static CALayer* pane_layer_of(CALayer* layer) {
    static NSMapTable<Class, NSNumber*>* seen = [NSMapTable strongToStrongObjectsMapTable];
    static NSString* pane = RXNS(RXN_193);
    for (CALayer* l = layer.superlayer; l; l = l.superlayer) {
        id d = l.delegate;
        if (![d isKindOfClass:NSView.class])
            continue;
        Class c = [d class];
        NSNumber* yes = [seen objectForKey:c];
        if (!yes)
            [seen setObject:(yes = @([NSStringFromClass(c) hasPrefix:pane])) forKey:c];
        if (yes.boolValue)
            return l;
    }
    return nil;
}

static void clear_if_background(CALayer* layer, CALayer* root, CGSize win) {
    if (is_terminal_layer(layer) || is_window_frame_layer(layer))
        return;
    if (layer.superlayer && layer.superlayer.mask == layer)
        return;
    CGColorRef bg = layer.backgroundColor;
    CAShapeLayer* shape = [layer isKindOfClass:[CAShapeLayer class]] ? (CAShapeLayer*)layer : nil;
    if (!has_color(bg) && !(shape && has_color(shape.fillColor)))
        return;
    CGRect r = [layer convertRect:layer.bounds toLayer:root];
    CGSize ref = win;
    NSWindow* w = layer_window(layer);
    if (NSValue* pane = w ? [g_pane_area objectForKey:w] : nil) {
        NSSize p = pane.sizeValue;
        if (p.width > 0 && p.height > 0)
            ref = CGSizeMake(MIN(win.width, p.width), MIN(win.height, p.height));
    }
    if (r.size.width < 0.3 * ref.width || r.size.height < 0.3 * ref.height) {
        CALayer* pl = pane_layer_of(layer);
        CGSize p = pl ? [pl convertRect:pl.bounds toLayer:root].size : CGSizeZero;
        if (p.width < 1 || p.height < 1 || r.size.width < 0.9 * p.width || r.size.height < 0.9 * p.height)
            return;
    }
    if (ours(layer))
        return;
    if (has_color(bg)) {
        log_cleared(@"bg  ", layer, r, bg);
        [g_saved_bg setObject:saved(bg) forKey:layer];
        orig_set_background(layer, @selector(setBackgroundColor:), NULL);
    }
    if (shape && has_color(shape.fillColor)) {
        log_cleared(@"fill", layer, r, shape.fillColor);
        [g_saved_fill setObject:saved(shape.fillColor) forKey:shape];
        orig_set_fill(shape, @selector(setFillColor:), NULL);
    }
    [g_backgrounds addObject:layer];
    [layer removeAnimationForKey:@"backgroundColor"];
    [layer removeAnimationForKey:@"fillColor"];
}

void restore_backgrounds(void) {
    for (CALayer* layer in g_backgrounds.allObjects) {
        if (id bg = [g_saved_bg objectForKey:layer]) {
            orig_set_background(layer, @selector(setBackgroundColor:), unsaved(bg));
        }
        if (id fill = [g_saved_fill objectForKey:layer]) {
            orig_set_fill(layer, @selector(setFillColor:), unsaved(fill));
        }
    }
    [g_backgrounds removeAllObjects];
    [g_saved_bg removeAllObjects];
    [g_saved_fill removeAllObjects];
}

static NSWindow* window_of(CALayer* layer, CALayer** root) {
    CALayer* top = layer;
    while (top.superlayer)
        top = top.superlayer;
    *root = top;
    return layer_window(layer);
}

static bool needs_fix(CALayer* layer) {
    if (layer.opaque || has_color(layer.backgroundColor))
        return true;
    return [layer isKindOfClass:[CAShapeLayer class]] && has_color(((CAShapeLayer*)layer).fillColor);
}

static bool small(CALayer* layer) {
    CGSize b = layer.bounds.size;
    if (b.width >= 64 && b.height >= 64)
        return false;
    return CATransform3DIsIdentity(layer.transform)
        && (!layer.superlayer || CATransform3DIsIdentity(layer.superlayer.sublayerTransform));
}

void process_dirty(bool watched) {
    RX_INTERVAL(transparency, "process_dirty");
    watched = watched && !g_watch.empty() && (g_watch_sweep || g_transforms != g_transforms_seen);
    if (g_dirty.count == 0 && !watched)
        return;
    NSMutableSet<CALayer*>* todo = g_dirty.count ? [g_dirty mutableCopy] : nil;
    [g_dirty removeAllObjects];
    if (!transparent()) {
        g_watch.clear();
        g_watching.clear();
        return;
    }
    if (watched) {
        bool transforms = g_transforms != g_transforms_seen;
        g_transforms_seen = g_transforms;
        bool sweep = g_watch_sweep;
        g_watch_sweep = false;
        size_t keep = 0;
        for (size_t i = 0; i < g_watch.size(); i++) {
            Watched w = g_watch[i];
            CGSize s = w.layer.bounds.size;
            bool still = !transforms && !sweep && CGSizeEqualToSize(s, w.size);
            if (!still) {
                w.size = s;
                if (!w.layer.superlayer) {
                    g_watching.erase((__bridge const void*)w.layer);
                    continue;
                }
                still = small(w.layer) && !w.layer.opaque;
            }
            if (still) {
                g_watch[keep++] = w;
                continue;
            }
            g_watching.erase((__bridge const void*)w.layer);
            if (!todo)
                todo = [NSMutableSet set];
            [todo addObject:w.layer];
        }
        g_watch.resize(keep);
    }
    for (CALayer* layer in todo) {
        if (!needs_fix(layer) || ours(layer))
            continue;
        if (small(layer) && !layer.opaque) {
            watch(layer);
            continue;
        }
        CALayer* root = nil;
        NSWindow* w = window_of(layer, &root);
        if (!w) {
            watch(layer);
            continue;
        }
        if (!is_rex_window(w))
            continue;
        if (layer.opaque)
            orig_set_opaque(layer, @selector(setOpaque:), NO);
        if (is_terminal_layer(layer))
            continue;
        clear_if_background(layer, root, root.bounds.size);
        if (!is_background(layer) && needs_fix(layer) && !is_window_frame_layer(layer) && !ours(layer)) {
            watch(layer);
        }
    }
}

static void log_miss(NSString* what, CALayer* layer, CALayer* root) {
    CGRect r = [layer convertRect:layer.bounds toLayer:root];
    id d = layer.delegate ?: layer.superlayer.delegate;
    rexui_log([NSString stringWithFormat:@"transparency: missed %@ %@ %@ (bounds %@%@)%@%@", what,
                                         NSStringFromClass([layer class]), NSStringFromRect(NSRectFromCGRect(r)),
                                         NSStringFromSize(NSSizeFromCGSize(layer.bounds.size)),
                                         CATransform3DIsIdentity(layer.transform) ? @"" : @", transformed",
                                         d ? [@" in " stringByAppendingString:NSStringFromClass([d class])] : @"",
                                         watched_has(layer) ? @" (watched)" : @""]);
}

static void walk_layer(CALayer* layer, CALayer* root, CGSize win, int depth) {
    if (g_dump) {
        NSString* bg = @"nil";
        if (CGColorRef c = layer.backgroundColor) {
            CGRect r = [layer convertRect:layer.bounds toLayer:root];
            const CGFloat* k = CGColorGetComponents(c);
            size_t nk = CGColorGetNumberOfComponents(c);
            bg =
                [NSString stringWithFormat:@"set %@ a=%.2f rgb=%.2f,%.2f,%.2f%@", NSStringFromRect(NSRectFromCGRect(r)),
                                           CGColorGetAlpha(c), nk > 2 ? k[0] : k[0], nk > 2 ? k[1] : k[0],
                                           nk > 2 ? k[2] : k[0], is_background(layer) ? @" (ours)" : @""];
        }
        NSString* fill = @"";
        if ([layer isKindOfClass:[CAShapeLayer class]]) {
            CGColorRef f = ((CAShapeLayer*)layer).fillColor;
            const CGFloat* k = f ? CGColorGetComponents(f) : nullptr;
            size_t nk = f ? CGColorGetNumberOfComponents(f) : 0;
            fill = [NSString
                stringWithFormat:@" fill=%@",
                                 f ? [NSString stringWithFormat:@"a=%.2f rgb=%.2f,%.2f,%.2f", CGColorGetAlpha(f), k[0],
                                                                nk > 2 ? k[1] : k[0], nk > 2 ? k[2] : k[0]]
                                   : @"nil"];
        }
        NSMutableString* more = [NSMutableString
            stringWithFormat:@" at %@",
                             NSStringFromRect(NSRectFromCGRect([layer convertRect:layer.bounds toLayer:root]))];
        if (layer.hidden)
            [more appendString:@" hidden"];
        if ([layer isKindOfClass:[CAShapeLayer class]]) {
            CAShapeLayer* sh = (CAShapeLayer*)layer;
            if (sh.strokeColor && sh.lineWidth > 0)
                [more appendFormat:@" stroke=a%.2f/w%.1f", CGColorGetAlpha(sh.strokeColor), sh.lineWidth];
        }
        if (layer.borderWidth > 0)
            [more appendFormat:@" border=a%.2f/w%.1f", layer.borderColor ? CGColorGetAlpha(layer.borderColor) : 0,
                               layer.borderWidth];
        if (layer.opacity < 1)
            [more appendFormat:@" opacity=%.2f", layer.opacity];
        if (layer.compositingFilter)
            [more appendFormat:@" compositing=%@", layer.compositingFilter];
        for (id f in layer.filters ?: @[])
            [more appendFormat:@" filter=%@", [f respondsToSelector:@selector(name)] ? [f name] : f];
        for (id f in layer.backgroundFilters ?: @[])
            [more appendFormat:@" bgfilter=%@", [f respondsToSelector:@selector(name)] ? [f name] : f];
        [g_dump appendFormat:@"%*s[layer %@ opaque=%d bg=%@%@%@]\n", depth * 2, "", NSStringFromClass([layer class]),
                             layer.opaque, bg, fill, more];
    }
    if (layer.opaque) {
        if (g_log_misses)
            log_miss(@"opaque", layer, root);
        orig_set_opaque(layer, @selector(setOpaque:), NO);
    }
    if (is_terminal_layer(layer))
        return;
    if (layer.shadowOpacity > 0)
        fix_shadow(layer);
    if (g_log_misses && !is_background(layer) && needs_fix(layer)) {
        clear_if_background(layer, root, win);
        if (is_background(layer))
            log_miss(@"solid", layer, root);
    } else {
        clear_if_background(layer, root, win);
    }
    for (CALayer* sub in layer.sublayers) {
        if (![sub.delegate isKindOfClass:NSView.class])
            walk_layer(sub, root, win, depth + 1);
    }
}

static void walk_view(NSView* view, CALayer* root, CGSize win, int depth) {
    if (g_dump) {
        [g_dump appendFormat:@"%*s%@ opaque=%d frame=%@ flipped=%d autoresize=%lu constraints=%lu%@%@\n", depth * 2, "",
                             NSStringFromClass([view class]), view.isOpaque, NSStringFromRect(view.frame),
                             view.isFlipped, (unsigned long)view.autoresizingMask,
                             (unsigned long)view.constraints.count, view.hidden ? @" hidden" : @"",
                             view.alphaValue < 1 ? [NSString stringWithFormat:@" alpha=%.2f", view.alphaValue] : @""];
    }
    if (ui_is_dock(view)) {
        if (g_dump)
            for (NSView* sub in view.subviews)
                dump_tabs(sub, depth + 1);
        return;
    }
    if (g_dump && [NSStringFromClass([view class]) hasSuffix:RXNS(RXN_184)])
        dump_tabs(view, depth + 1);
    if (backdrop_class() && [view isKindOfClass:backdrop_class()]) {
        BOOL hide = transparent() || wants_hidden(view);
        if (view.hidden != hide)
            orig_backdrop_set_hidden(view, @selector(setHidden:), hide);
        return;
    }
    if (tabbar_class() && [view isKindOfClass:tabbar_class()]) {
        if (g_dump)
            dump_tabs(view, depth + 1);
        BOOL hide = !g_config.tab_bar || wants_hidden(view);
        if (view.hidden != hide)
            orig_tabbar_set_hidden(view, @selector(setHidden:), hide);
        return;
    }
    if (actions_class() && [view isKindOfClass:actions_class()]) {
        BOOL hide = !g_config.pane_buttons || wants_hidden(view);
        if (view.hidden != hide)
            orig_actions_set_hidden(view, @selector(setHidden:), hide);
        return;
    }
    if (term_scroll_class() && [view isKindOfClass:term_scroll_class()])
        apply_scroller((NSScrollView*)view);
    if (transparent() && view.layer)
        walk_layer(view.layer, root, win, depth + 1);
    for (NSView* sub in view.subviews)
        walk_view(sub, root, win, depth + 1);
}

static char k_we_hid_button;

void apply_all(void) {
    for (NSWindow* w in NSApp.windows) {
        if (!is_rex_window(w))
            continue;
        if (g_dump)
            [g_dump appendFormat:@"=== %@ \"%@\"\n", NSStringFromClass([w class]), w.title];
        tint_window(w);
        for (NSWindowButton b : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
            NSButton* button = [w standardWindowButton:b];
            if (!button)
                continue;
            if (!g_config.traffic_lights && !button.hidden) {
                button.hidden = YES;
                objc_setAssociatedObject(button, &k_we_hid_button, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else if (g_config.traffic_lights && button.hidden && objc_getAssociatedObject(button, &k_we_hid_button)) {
                button.hidden = NO;
                objc_setAssociatedObject(button, &k_we_hid_button, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        NSView* frame = w.contentView.superview ?: w.contentView;
        bool off = !g_config.traffic_lights && !g_config.tab_bar;
        if (off && w.movable) {
            w.movable = NO;
            objc_setAssociatedObject(w, &k_we_hid_button, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (!off && !w.movable && objc_getAssociatedObject(w, &k_we_hid_button)) {
            w.movable = YES;
            objc_setAssociatedObject(w, &k_we_hid_button, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (NSView* bar = [w standardWindowButton:NSWindowCloseButton].superview.superview;
            bar && bar.superview == frame) {
            if (off && !bar.hidden) {
                bar.hidden = YES;
                objc_setAssociatedObject(bar, &k_we_hid_button, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else if (!off && bar.hidden && objc_getAssociatedObject(bar, &k_we_hid_button)) {
                bar.hidden = NO;
                objc_setAssociatedObject(bar, &k_we_hid_button, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        if (frame.layer)
            walk_view(frame, frame.layer, frame.bounds.size, 0);
    }
    if (g_dump) {
        [g_dump writeToFile:debug_path(@"tree.txt") atomically:YES encoding:NSUTF8StringEncoding error:nil];
        g_dump = nil;
    }
}
