// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "web/web.h"

@implementation RXSlot
@end

NSMutableDictionary<NSString*, RXSlot*>* g_slots;

void save_slot(RXSlot* slot) {
    NSMutableDictionary* all = [[g_state dictionaryForKey:@"slots"] mutableCopy] ?: [NSMutableDictionary dictionary];
    all[slot.key] = @{
        @"active": slot.active.lastPathComponent ?: @"",
        @"shown": @(slot.shown),
        @"size": @(slot.dragged),
        @"across": @(slot.dragged_across),
        @"axis": @(slot.axis)
    };
    [g_state setObject:all forKey:@"slots"];
}

RXSlot* slot_named(NSString* key) {
    if (RXSlot* s = g_slots[key])
        return s;
    RXSlot* s = [RXSlot new];
    s.key = key;
    s.progress = -1;
    s.shown = true;
    s.view = [[RXDockView alloc] initWithFrame:NSZeroRect];
    s.view.slot = s;
    NSDictionary* saved = [g_state dictionaryForKey:@"slots"][key];
    if (saved) {
        s.shown = [saved[@"shown"] boolValue];
        s.dragged = [saved[@"size"] doubleValue];
        s.dragged_across = [saved[@"across"] doubleValue];
        s.axis = [saved[@"axis"] intValue];
        NSString* active = saved[@"active"];
        if (active.length) {
            NSFileManager* fm = NSFileManager.defaultManager;
            s.active = [ui_dir() stringByAppendingPathComponent:active];
            if (![fm fileExistsAtPath:s.active])
                s.active = [[ui_dir() stringByAppendingPathComponent:@"ui"] stringByAppendingPathComponent:active];
            if (![fm fileExistsAtPath:s.active])
                s.active = [tabs_dir() stringByAppendingPathComponent:active];
            for (RXDoc* d in g_docs) {
                if ([d.path.lastPathComponent isEqualToString:active])
                    s.active = d.path;
            }
        }
    }
    g_slots[key] = s;
    return s;
}

NSString* group_of(RXDoc* doc) {
    return str(doc.root, P::group, @"");
}
static bool is_group(RXSlot* slot) {
    return [slot.key hasPrefix:@"group:"];
}

RXDoc* active_member(RXSlot* slot) {
    for (RXDoc* d in slot.members) {
        if ([d.path isEqualToString:slot.active])
            return d;
    }
    return slot.members.firstObject;
}

static RXNode* lead(RXSlot* slot) {
    return (slot.lead ?: slot.members.firstObject).root;
}
RXNode* slot_lead(RXSlot* slot) {
    return lead(slot);
}

static NSString* order_key(RXSlot* slot) {
    return [@"bar order " stringByAppendingString:slot.key];
}

void save_bar_order(RXSlot* slot, NSArray<NSString*>* names) {
    [g_state setObject:names forKey:order_key(slot)];
    chrome_relayout();
}

static NSArray<RXDoc*>* in_bar_order(RXSlot* slot, NSArray<RXDoc*>* docs) {
    NSArray<NSString*>* saved = [g_state arrayForKey:order_key(slot)] ?: @[];
    return [docs sortedArrayWithOptions:NSSortStable
                        usingComparator:^NSComparisonResult(RXDoc* a, RXDoc* b) {
                            int pa = bar_part(a), pb = bar_part(b);
                            if (pa != pb)
                                return pa > pb ? NSOrderedDescending : NSOrderedAscending;
                            NSUInteger ia = [saved indexOfObject:a.path.lastPathComponent],
                                       ib = [saved indexOfObject:b.path.lastPathComponent];
                            return ia < ib ? NSOrderedAscending : ia > ib ? NSOrderedDescending : NSOrderedSame;
                        }];
}

NSString* side_of(RXSlot* slot) {
    return str(lead(slot), P::side, @"right");
}
bool vertical(NSString* side) {
    return [side isEqualToString:@"left"] || [side isEqualToString:@"right"];
}
static bool corner(NSString* side) {
    return [side containsString:@"-"];
}

CGFloat wanted_size(RXSlot* slot) {
    RXNode* r = active_member(slot).root;
    const bool v = vertical(side_of(slot));
    if (r) {
        const int axis = v ? 1 : 2;
        if (!slot.axis)
            slot.axis = axis;
        else if (slot.axis != axis) {
            const CGFloat d = slot.dragged;
            slot.dragged = slot.dragged_across;
            slot.dragged_across = d;
            slot.axis = axis;
            save_slot(slot);
        }
    }
    if (slot.dragged > 0)
        return slot.dragged;
    return v ? num(r, P::width, 320) : num(r, P::height, 200);
}

void slot_show(RXSlot* slot, NSString* path) {
    slot.active = path;
    slot.shown = true;
    if (RXNode* f = autofocus_field(active_member(slot).root)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            focus_node(f, false);
        });
    }
    save_slot(slot);
    chrome_relayout();
}

void slot_hide(RXSlot* slot) {
    slot.shown = false;
    if (focus_in(slot.view))
        focus_terminal(slot.view.window ?: dock_window());
    save_slot(slot);
    chrome_relayout();
}

void slot_switch(RXSlot* slot, NSString* path) {
    RXDoc* from = active_member(slot);
    if ([from.path isEqualToString:path])
        return;
    slot.active = path;
    save_slot(slot);
    RXDoc* to = active_member(slot);
    if (focus_in(from.root.host))
        focus_terminal(slot.view.window);
    double ms = num(lead(slot), P::animation, 220) * 0.8;
    RXDockView *old = from.root.host, *now = to.root.host;
    slot.fading = from.path;
    now.hidden = NO;
    now.layer.opacity = 0;
    fade_layer(now.layer, 1, ms, nil);
    if (RXNode* root = to.root)
        dispatch_async(dispatch_get_main_queue(), ^{
            tabpreview_shown(root);
        });
    fade_layer(old.layer, 0, ms, ^{
        if ([slot.fading isEqualToString:from.path]) {
            slot.fading = nil;
            if (![slot.active isEqualToString:from.path])
                old.hidden = YES;
            old.layer.opacity = 1;
        }
    });
    CGFloat a = slot.size, b = wanted_size(slot);
    if (a > 0 && a != b && ms > 0) {
        [slot.resize cancel];
        slot.resize = animate(
            slot.view, ms,
            ^(double t) {
                slot.size = a + (b - a) * t;
                chrome_relayout();
            },
            nil);
    }
    if (RXNode* f = autofocus_field(to.root))
        focus_node(f, false);
    chrome_relayout();
}

NSWindow* dock_window(void) {
    NSWindow* w = g_window;
    if (is_rex_window(w) && w.isVisible)
        return w;
    if (NSWindow* m = NSApp.mainWindow; is_rex_window(m))
        return g_window = m;
    for (NSWindow* c in NSApp.windows) {
        if (is_rex_window(c) && c.isVisible)
            return g_window = c;
    }
    return nil;
}

static NSArray<RXSlot*>* slots(void) {
    NSMutableDictionary<NSString*, NSMutableArray<RXDoc*>*>* members = [NSMutableDictionary dictionary];
    NSMutableArray<NSString*>* order = [NSMutableArray array];
    for (RXDoc* doc in g_docs) {
        if (!doc.root.host || doc.pane)
            continue;
        NSString* g = group_of(doc);
        NSString* key = g.length ? [@"group:" stringByAppendingString:g]
                                 : [@"file:" stringByAppendingString:doc.path.lastPathComponent];
        if (!members[key]) {
            members[key] = [NSMutableArray array];
            [order addObject:key];
        }
        [members[key] addObject:doc];
    }
    for (NSString* key in g_slots.allKeys) {
        if (members[key])
            continue;
        [g_slots[key].view removeFromSuperview];
        [g_slots[key].slide cancel];
        [g_slots[key].resize cancel];
        [g_slots removeObjectForKey:key];
    }
    static bool built;
    NSMutableArray* out = [NSMutableArray array];
    for (NSString* key in order) {
        bool fresh = !g_slots[key];
        RXSlot* slot = slot_named(key);
        if (fresh && built)
            slot.progress = 0;
        slot.lead = members[key].firstObject;
        slot.members = is_group(slot) ? in_bar_order(slot, members[key]) : members[key];
        if (!active_member(slot) || ![slot.active isEqualToString:active_member(slot).path]) {
            slot.active = active_member(slot).path;
        }
        [out addObject:slot];
    }
    if (!loading_staging())
        built = true;
    return out;
}

static CGAffineTransform slide_at(RXSlot* slot, double progress) {
    CGFloat off = round((1 - MIN(1, MAX(0, progress))) * slot.travel);
    NSString* side = side_of(slot);
    NSPoint d = [side isEqualToString:@"left"] ? NSMakePoint(-off, 0)
        : [side isEqualToString:@"right"]      ? NSMakePoint(off, 0)
        : [side isEqualToString:@"top"]        ? NSMakePoint(0, -off)
                                               : NSMakePoint(0, off);
    return CGAffineTransformMakeTranslation(d.x, d.y);
}
static void slide_to(RXSlot* slot) {
    RXDockView* v = slot.view;
    if (!v.superview)
        return;
    CGAffineTransform t = slide_at(slot, slot.progress);
    if (CGAffineTransformEqualToTransform(v.layer.affineTransform, t))
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    v.layer.affineTransform = t;
    [CATransaction commit];
}

static constexpr CGFloat kRexInset = 8;
static constexpr CGFloat kEdgeIn = 5, kGrab = 5;

static CGFloat place_slot(RXSlot* slot, NSView* chrome, NSRect area, CGFloat before) {
    RXNode* first = lead(slot);
    NSString* side = side_of(slot);
    bool group = is_group(slot);
    RXDockView* v = slot.view;
    RXRoot* root = ui_root(chrome);
    [root addHost:v band:slot.raised ? kBandDocksRaised : kBandDocks];
    RXDoc* active = active_member(slot);
    double target = (group ? slot.shown : shown(active.root)) ? 1 : 0;
    double ms = num(first, P::animation, 220);
    if (slot.size <= 0 || !slot.resize.tick)
        slot.size = wanted_size(slot);
    bool melts = [str(first, P::transition, @"slide") isEqualToString:@"melt"];
    if (slot.progress < 0 || ms <= 0) {
        slot.progress = target;
    } else if (melts && target != slot.target) {
        [slot.slide cancel];
        chrome_glide_panes(ms, nullptr);
        double melt_ms = MAX(ms * 2.5, 450);
        if (target <= 0 && !v.hidden && v.window) {
            melt([root band:kBandDocks], v.layer, v.frame, true, melt_ms, nil);
        } else if (target > 0) {
            v.layer.opacity = 0;
            __weak RXDockView* wv = v;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!wv)
                    return;
                void (^in)(void) = ^{
                    RXDockView* dv = wv;
                    if (RXRoot* r = dv.rootView)
                        melt([r band:kBandDocks], dv.layer, dv.frame, false, melt_ms, ^{
                            wv.layer.opacity = 1;
                        });
                };
                double wait = slot.flying_until - CACurrentMediaTime();
                if (wait > 0)
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), in);
                else
                    in();
            });
        }
        slot.progress = target;
    } else if (target != slot.target) {
        [slot.slide cancel];
        slot.slide = nil;
        double from = MAX(0, slot.progress);
        if (CACurrentMediaTime() < slot.slide_until && slot.travel > 0) {
            CGAffineTransform t = ((CALayer*)v.layer.presentationLayer ?: v.layer).affineTransform;
            from = MAX(0, MIN(1, 1 - MAX(fabs(t.tx), fabs(t.ty)) / slot.travel));
        }
        double slide_ms = ms * fabs(target - from);
        chrome_glide_panes(slide_ms, nullptr);
        slot.slide_from = from;
        slot.slide_ms = slide_ms;
        slot.slide_due = slide_ms > 0;
        slot.slide_until = CACurrentMediaTime() + slide_ms / 1000;
        slot.progress = target;
    }
    if (target > 0 && slot.target <= 0 && active.root)
        unplace(active.root), schedule_layout(active, false);
    slot.target = target;
    double p = slot.progress;
    if (p <= 0 && target <= 0 && CACurrentMediaTime() >= slot.slide_until) {
        v.hidden = YES;
        return 0;
    }
    v.hidden = NO;
    bool vert = vertical(side), window_wide = !vert && [str(first, P::span, @"panes") isEqualToString:@"window"];
    bool left = [side isEqualToString:@"left"], right = [side isEqualToString:@"right"],
         top = [side isEqualToString:@"top"];
    CGFloat full = MIN(slot.size, (vert ? area.size.width : area.size.height) * 0.7), used = target > 0 ? full : 0;
    const Config& c = g_config;
    CGFloat outer = 0;
    if (vert) {
        outer = (left ? c.left : c.right) + kRexInset;
        area.origin.y += c.top, area.size.height = MAX(0, area.size.height - c.top - c.bottom - kRexInset);
        if (target > 0)
            used += kRexInset;
    } else if (!window_wide) {
        outer = top ? c.top : c.bottom + kRexInset;
        area.origin.x += c.left + kRexInset,
            area.size.width = MAX(0, area.size.width - c.left - c.right - 2 * kRexInset);
        if (target > 0)
            used += kRexInset;
    }
    NSRect f;
    if (left)
        f = NSMakeRect(area.origin.x + outer + before, area.origin.y, full, area.size.height);
    else if (right)
        f = NSMakeRect(NSMaxX(area) - outer - before - full, area.origin.y, full, area.size.height);
    else if (top)
        f = NSMakeRect(area.origin.x, area.origin.y + outer + before, area.size.width, full);
    else
        f = NSMakeRect(area.origin.x, NSMaxY(area) - outer - before - full, area.size.width, full);
    f = NSIntegralRect(f);
    bool resizable = flag(first, P::resizable, true);
    CGFloat grab = resizable && !window_wide ? kGrab : 0;
    NSRect vf = f, inner = NSMakeRect(0, 0, f.size.width, f.size.height);
    if (left)
        vf.size.width += grab;
    else if (right)
        vf.origin.x -= grab, vf.size.width += grab, inner.origin.x = grab;
    else if (top)
        vf.size.height += grab;
    else
        vf.origin.y -= grab, vf.size.height += grab, inner.origin.y = grab;
    if (!NSEqualRects(v.frame, vf))
        v.frame = vf;
    slot.travel = full + outer + grab;
    slide_to(slot);
    if (slot.slide_due) {
        slot.slide_due = false;
        __weak RXSlot* weak = slot;
        ca_glide(v.layer, @"transform",
                 [NSValue valueWithCATransform3D:CATransform3DMakeAffineTransform(slide_at(slot, slot.slide_from))],
                 slot.slide_ms, nullptr, ^{
                     RXSlot* s = weak;
                     if (s && s.target <= 0 && s.progress <= 0 && CACurrentMediaTime() >= s.slide_until - 0.002)
                         s.view.hidden = YES;
                     ui_pointer_refresh();
                 });
    }
    NSString* where = str(first, P::bar, @"bottom");
    if (group && ![where isEqualToString:@"none"] && ![where isEqualToString:@"float"]) {
        build_bar(slot);
        if (slot.bar.layer.superlayer != v.layer)
            [v.layer addSublayer:slot.bar.layer];
        slot.bar.pill.hidden = NO;
        slot.bar.layer.affineTransform = CGAffineTransformIdentity;
        NSRect barf;
        NSDivideRect(inner, &barf, &inner, kBarHeight, [where isEqualToString:@"top"] ? NSMinYEdge : NSMaxYEdge);
        layout_bar(slot, v, barf);
    } else if (![where isEqualToString:@"float"]) {
        [slot.bar.layer removeFromSuperlayer];
        slot.bar.frame = NSZeroRect;
    }
    for (RXDoc* d in slot.members) {
        RXDockView* dv = d.root.host;
        [v addSubhost:dv];
        bool on = d == active, fading = [d.path isEqualToString:slot.fading];
        if (!on && !fading) {
            dv.hidden = YES;
            continue;
        }
        dv.hidden = NO;
        place(d.root, inner);
    }
    NSRect edge = NSZeroRect;
    if (resizable) {
        NSRect b = v.bounds;
        CGFloat e = kEdgeIn + grab;
        edge = right ? NSMakeRect(0, 0, e, b.size.height)
            : left   ? NSMakeRect(b.size.width - e, 0, e, b.size.height)
            : top    ? NSMakeRect(0, b.size.height - e, b.size.width, e)
                     : NSMakeRect(0, 0, b.size.width, e);
    }
    slot.edge = edge;
    for (RXDoc* d in slot.members)
        place_natives(d);
    return used;
}

static double reveal_of(RXSlot* slot) {
    return corner(side_of(slot)) ? num(lead(slot), P::reveal, 0) : 0;
}

static bool drawer_open_in(RXSlot* slot) {
    for (RXDoc* d in slot.members)
        if (drawer_open_of(d, false))
            return true;
    return false;
}

bool slot_reachable(RXSlot* slot) {
    return reveal_of(slot) <= 0 || slot.near;
}

static void set_near(RXSlot* slot, bool near) {
    if (slot.near == near)
        return;
    slot.near = near;
    fade_layer(slot.view.layer, near ? 1 : 0, near ? 160 : 320, nil);
}

void corner_pointer(NSEvent* e) {
    NSWindow* ew = e.window;
    if (e.type != NSEventTypeMouseMoved)
        return;
    bool tools = debug_pointer_near_devtools(e);
    for (RXSlot* slot in g_slots.allValues) {
        double R = reveal_of(slot);
        RXDockView* v = slot.view;
        if (R <= 0 || v.hidden || v.window != ew || !v.superview)
            continue;
        NSPoint p = [v.superview convertPoint:e.locationInWindow fromView:nil];
        NSRect f = v.frame;
        CGFloat dx = MAX(0, MAX(NSMinX(f) - p.x, p.x - NSMaxX(f))), dy = MAX(0, MAX(NSMinY(f) - p.y, p.y - NSMaxY(f)));
        set_near(slot, (!tools && hypot(dx, dy) <= R) || drawer_open_in(slot));
    }
}

static void place_corner(RXSlot* slot, NSView* chrome, NSRect panes) {
    RXNode* first = lead(slot);
    NSString* side = side_of(slot);
    RXDockView* v = slot.view;
    RXRoot* root = ui_root(chrome);
    [root addHost:v band:slot.raised ? kBandDocksRaised : kBandDocks];
    RXDoc* active = active_member(slot);
    bool on = shown(active.root);
    slot.progress = slot.target = on ? 1 : 0;
    if (!on) {
        v.hidden = YES;
        return;
    }
    const Config& c = g_config;
    CGFloat w = num(first, P::width, 48), h = num(first, P::height, 48), m = num(first, P::margin, 12);
    bool left = [side hasSuffix:@"left"], top = [side hasPrefix:@"top"];
    CGFloat x = left ? NSMinX(panes) + c.left + kRexInset + m : NSMaxX(panes) - c.right - kRexInset - m - w;
    CGFloat y = top ? NSMinY(panes) + c.top + m : NSMaxY(panes) - c.bottom - kRexInset - m - h;
    NSRect f = NSIntegralRect(NSMakeRect(x, y, w, h));
    if (!NSEqualRects(v.frame, f))
        v.frame = f;
    if (!CGAffineTransformIsIdentity(v.layer.affineTransform))
        v.layer.affineTransform = CGAffineTransformIdentity;
    float alpha = slot_reachable(slot) ? 1 : 0;
    if (v.layer.opacity != alpha && !v.layer.animationKeys.count)
        v.layer.opacity = alpha;
    v.hidden = NO;
    for (RXDoc* d in slot.members) {
        RXDockView* dv = d.root.host;
        [v addSubhost:dv];
        dv.hidden = d != active;
        if (d == active)
            place(d.root, v.bounds);
    }
    slot.edge = NSZeroRect;
    for (RXDoc* d in slot.members)
        place_natives(d);
}

NSRect g_pane_rect;

Insets ui_layout_docks(NSView* chrome, NSRect area) {
    RX_INTERVAL(layout, "docks");
    Insets in;
    NSArray<RXSlot*>* all = slots();
    if (chrome.window != dock_window()) {
        RXRoot* root = root_of(chrome.window);
        for (RXSlot* slot in all) {
            if (root && slot.view.superview == root)
                [slot.view removeFromSuperview];
        }
        for (RXNode* n in all_drawers()) {
            if (root && n.host.superview == root)
                [n.host removeFromSuperview];
        }
        loading_place(chrome);
        return in;
    }
    NSAppearance* look = [NSAppearance appearanceNamed:g_theme.dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    RXRoot* root = ui_root(chrome);
    if (![root.appearance.name isEqualToString:look.name])
        root.appearance = look;
    for (RXSlot* slot in all) {
        NSString* side = side_of(slot);
        if (vertical(side) || corner(side) || ![str(lead(slot), P::span, @"panes") isEqualToString:@"window"])
            continue;
        if ([side isEqualToString:@"top"])
            in.top += place_slot(slot, chrome, area, in.top);
        else
            in.bottom += place_slot(slot, chrome, area, in.bottom);
    }
    NSRect rest = NSMakeRect(area.origin.x, area.origin.y + in.top, area.size.width,
                             MAX(0, area.size.height - in.top - in.bottom));
    for (RXSlot* slot in all) {
        NSString* side = side_of(slot);
        if (!vertical(side))
            continue;
        if ([side isEqualToString:@"left"])
            in.left += place_slot(slot, chrome, rest, in.left);
        else
            in.right += place_slot(slot, chrome, rest, in.right);
    }
    NSRect mid = NSMakeRect(rest.origin.x + in.left, rest.origin.y, MAX(0, rest.size.width - in.left - in.right),
                            rest.size.height);
    CGFloat t = 0, b = 0;
    for (RXSlot* slot in all) {
        NSString* side = side_of(slot);
        if (vertical(side) || corner(side) || [str(lead(slot), P::span, @"panes") isEqualToString:@"window"])
            continue;
        if ([side isEqualToString:@"top"])
            t += place_slot(slot, chrome, mid, t);
        else
            b += place_slot(slot, chrome, mid, b);
    }
    in.top += t, in.bottom += b;
    g_pane_rect =
        NSMakeRect(area.origin.x + in.left, area.origin.y + in.top, MAX(0, area.size.width - in.left - in.right),
                   MAX(0, area.size.height - in.top - in.bottom));
    for (RXSlot* slot in all) {
        if (corner(side_of(slot)))
            place_corner(slot, chrome, g_pane_rect);
    }
    for (RXSlot* slot in all)
        place_float_bar(slot, chrome);
    place_drawers(chrome);
    loading_place(chrome);
    dispatch_async(dispatch_get_main_queue(), ^{
        web_visibility();
    });
    return in;
}
