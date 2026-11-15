// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

static constexpr double kShiftMs = 200, kDropMs = 280;

static __weak RXNode *g_item, *g_box;
static __weak RXDockView* g_host;
static CGPoint g_press;
static NSRect g_from;
static NSRect g_home;
static bool g_moving;

static bool reorderable(RXNode* n) {
    return n && str(n, P::reorder, @"").length && !is_list(n) && (is_row(n) || is_column(n) || is_grid(n));
}

static NSString* state_key(RXNode* box) {
    return [NSString stringWithFormat:@"reorder %@ %@", box.doc.path.lastPathComponent, str(box, P::reorder, @"")];
}

NSArray<RXNode*>* in_order(RXNode* n, NSArray<RXNode*>* kids) {
    if (!reorderable(n))
        return kids;
    if (!n.order)
        n.order = [g_state arrayForKey:state_key(n)] ?: @[];
    if (!n.order.count)
        return kids;
    NSArray<RXNode*>* all = n.children;
    NSArray<NSNumber*>* order = n.order;
    return [kids sortedArrayWithOptions:NSSortStable
                        usingComparator:^NSComparisonResult(RXNode* a, RXNode* b) {
                            NSUInteger sa = [all indexOfObjectIdenticalTo:a], sb = [all indexOfObjectIdenticalTo:b];
                            NSUInteger ia = [order indexOfObject:@(sa)], ib = [order indexOfObject:@(sb)];
                            if (ia == ib)
                                ia = sa, ib = sb;
                            return ia < ib ? NSOrderedAscending : ia > ib ? NSOrderedDescending : NSOrderedSame;
                        }];
}

bool reorder_active(void) {
    return g_moving && g_item;
}

bool reorder_hold(RXNode* n, NSRect* frame) {
    if (!g_moving || n != g_item)
        return false;
    g_home = *frame;
    frame->origin = n.p_frame.origin;
    return true;
}

static CGPoint box_point(RXDockView* host, RXNode* box, NSPoint p) {
    return [content_layer(box) convertPoint:[host convertPointToLayer:p] fromLayer:host.layer];
}

static RXNode* item_at(RXNode* n, CALayer* top, CGPoint p) {
    CALayer* l = n.layer;
    if (!l || l.hidden || !l.superlayer)
        return nil;
    if (!CGRectContainsPoint(l.bounds, [l convertPoint:p fromLayer:top]))
        return nil;
    for (RXNode* c in n.children.reverseObjectEnumerator) {
        if (is_drawer(c))
            continue;
        if (RXNode* hit = item_at(c, top, p))
            return hit;
    }
    return reorderable(n.parent) && shown(n) ? n : nil;
}

RXNode* reorder_item(RXDockView* host, NSPoint p) {
    RXNode* root = host.node;
    if (!root.layer)
        return nil;
    return item_at(root, host.layer, [host convertPointToLayer:p]);
}

static NSArray<RXNode*>* shown_kids(RXNode* box) {
    NSMutableArray* kids = [NSMutableArray array];
    for (RXNode* c in box.children) {
        if (!is_drawer(c) && shown(c))
            [kids addObject:c];
    }
    return in_order(box, kids);
}

static void glide_from(CALayer* l, CGPoint from, double ms, const double curve[4]) {
    if (CGPointEqualToPoint(from, l.position))
        return;
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"position"];
    a.fromValue = [NSValue valueWithPoint:from];
    a.toValue = [NSValue valueWithPoint:l.position];
    a.duration = ms / 1000;
    a.timingFunction = [CAMediaTimingFunction functionWithControlPoints:curve[0]:curve[1]:curve[2]:curve[3]];
    [l addAnimation:a forKey:@"rexui.reorder"];
}

static void relayout(RXNode* box) {
    NSArray<RXNode*>* kids = shown_kids(box);
    std::vector<CGPoint> was;
    for (RXNode* c in kids)
        was.push_back((c.layer.presentationLayer ?: c.layer).position);
    invalidate(box);
    layout_now(box.doc);
    RXNode* held = g_item;
    for (NSUInteger i = 0; i < kids.count; i++) {
        RXNode* c = kids[i];
        const bool dragged = c == held;
        if (dragged && g_moving)
            continue;
        glide_from(c.layer, was[i], dragged ? kDropMs : kShiftMs, dragged ? kSpatial : kStandard);
    }
}

bool reorder_press(RXDockView* host, RXNode* item, NSPoint p) {
    g_moving = false;
    g_item = item;
    g_box = item.parent;
    g_host = host;
    if (!item)
        return false;
    g_press = box_point(host, item.parent, p);
    g_from = g_home = item.p_frame;
    return true;
}

static void move_to(RXNode* item, NSRect f) {
    item.p_frame = f;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    item.layer.frame = f;
    [CATransaction commit];
    if (item.doc.natives.count)
        place_natives(item.doc);
}

bool reorder_drag(RXDockView* host, NSPoint p) {
    RXNode *item = g_item, *box = g_box;
    if (!item || !box || host != g_host || item.parent != box)
        return false;
    CGPoint at = box_point(host, box, p);
    CGFloat dx = at.x - g_press.x, dy = at.y - g_press.y;
    if (!g_moving) {
        if (hypot(dx, dy) < 4)
            return false;
        g_moving = true;
        g_from = g_home = item.p_frame;
        item.layer.zPosition = 1;
        item.layer.opacity = 0.9 * num(item, P::opacity, 1);
        use_cursor(NSCursor.closedHandCursor);
    }
    CGRect bounds = content_layer(box).bounds;
    NSRect f = NSOffsetRect(g_from, round(dx), round(dy));
    f.origin.x = MAX(NSMinX(bounds), MIN(f.origin.x, NSMaxX(bounds) - f.size.width));
    f.origin.y = MAX(NSMinY(bounds), MIN(f.origin.y, NSMaxY(bounds) - f.size.height));
    if (is_row(box))
        f.origin.y = g_from.origin.y;
    else if (!is_grid(box))
        f.origin.x = g_from.origin.x;
    move_to(item, f);
    NSArray<RXNode*>* kids = shown_kids(box);
    NSMutableArray<RXNode*>* others = [kids mutableCopy];
    [others removeObjectIdenticalTo:item];
    NSUInteger to = 0;
    if (is_grid(box)) {
        CGFloat best = CGFLOAT_MAX;
        for (NSUInteger k = 0; k < kids.count; k++) {
            NSRect s = kids[k] == item ? g_home : kids[k].p_frame;
            CGFloat d = hypot(NSMidX(s) - NSMidX(f), NSMidY(s) - NSMidY(f));
            if (d < best)
                best = d, to = k;
        }
    } else {
        bool row = is_row(box);
        for (RXNode* o in others) {
            CGFloat mid = row ? NSMidX(o.p_frame) : NSMidY(o.p_frame), home = row ? NSMidX(g_home) : NSMidY(g_home);
            CGFloat lo = row ? NSMinX(f) : NSMinY(f), hi = row ? NSMaxX(f) : NSMaxY(f);
            to += mid < home ? lo > mid : hi > mid;
        }
    }
    if ([kids indexOfObjectIdenticalTo:item] == to)
        return true;
    [others insertObject:item atIndex:to];
    NSMutableArray<NSNumber*>* order = [NSMutableArray array];
    for (RXNode* c in others)
        [order addObject:@([box.children indexOfObjectIdenticalTo:c])];
    for (NSNumber* i in box.order) {
        if (![order containsObject:i])
            [order addObject:i];
    }
    box.order = order;
    kids_changed();
    relayout(box);
    return true;
}

bool reorder_release(void) {
    RXNode *item = g_item, *box = g_box;
    bool moving = g_moving;
    g_moving = false;
    g_item = g_box = nil;
    if (!moving || !item || !box)
        return false;
    item.layer.opacity = num(item, P::opacity, 1);
    __weak RXNode* weak = item;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDropMs * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        RXNode* held = weak;
        if (held != g_item)
            held.layer.zPosition = 0;
    });
    use_cursor(NSCursor.arrowCursor);
    g_item = item;
    relayout(box);
    g_item = nil;
    if (box.order.count)
        [g_state setObject:box.order forKey:state_key(box)];
    return true;
}
