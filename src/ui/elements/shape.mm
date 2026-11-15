// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "ui/ui.h"

static int scallops(NSString* shape) {
    if (![shape hasPrefix:@"cookie"])
        return 0;
    return MAX(3, MIN(24, [shape substringFromIndex:6].intValue ?: 9));
}

int shape_scallops(NSString* shape) {
    return scallops(shape);
}

double shape_radius(NSString* shape, double r, double angle, double turn) {
    int n = scallops(shape);
    if (!n)
        return r;
    double depth = MIN(0.3, 1.2 / n);
    return r * (1 - depth * (1 - cos(n * (angle - turn + M_PI / 2))) / 2);
}

CGPathRef shape_path(NSString* shape, CGPoint c, double r, double turn, CGAffineTransform* t) {
    CGMutablePathRef p = CGPathCreateMutable();
    int n = scallops(shape);
    if (!n) {
        CGPathAddEllipseInRect(p, t, CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r));
        return p;
    }
    int steps = n * 24;
    for (int i = 0; i <= steps; i++) {
        double a = 2 * M_PI * i / steps, d = shape_radius(shape, r, a, turn);
        CGFloat x = c.x + d * cos(a), y = c.y + d * sin(a);
        if (i == 0)
            CGPathMoveToPoint(p, t, x, y);
        else
            CGPathAddLineToPoint(p, t, x, y);
    }
    CGPathCloseSubpath(p);
    return p;
}

CGAffineTransform layer_flip(CALayer* layer, CGFloat h) {
    return layer.contentsAreFlipped ? CGAffineTransformIdentity : CGAffineTransformMake(1, 0, 0, -1, 0, h);
}

CALayer* still(CALayer* layer) {
    static NSDictionary* none = [] {
        NSMutableDictionary* d = [NSMutableDictionary dictionary];
        for (NSString* k in @[
                 @"path", @"frame", @"bounds", @"position", @"strokeColor", @"fillColor", @"lineWidth", @"opacity",
                 @"lineCap", @"lineJoin", @"transform", @"contents", @"hidden"
             ]) {
            d[k] = NSNull.null;
        }
        return d;
    }();
    layer.actions = none;
    return layer;
}

double spin_angle(RXNode* n) {
    if (n.spin_period <= 0)
        return n.spin_base;
    return n.spin_base - 2 * M_PI * (CACurrentMediaTime() - n.spin_t0) / n.spin_period;
}

void spin_set(RXNode* n) {
    double now = CACurrentMediaTime();
    n.spin_base = fmod(spin_angle(n), 2 * M_PI);
    n.spin_t0 = now;
    n.spin_period = MAX(0, num(n, P::spin, 0) / 1000);
}

static bool moving(RXNode* n) {
    if (n.spin_period > 0 && str(n, P::shape, @"").length)
        return true;
    if (n.frames)
        return true;
    if (is_elem(n, E::Shapes))
        return shapes_moving(n);
    if (is_elem(n, E::Canvas))
        return canvas_el_moving(n);
    if (is_elem(n, E::Graph))
        return graph_moving(n);
    if (is_elem(n, E::Shader))
        return shader_moving(n);
    if (is_elem(n, E::Arc)) {
        if (flag(n, P::wavy, false) && flag(n, P::waving, true))
            return true;
        if (arc_clock_fps(n) < 120)
            return true;
        return fabs(n.shown_value - MAX(0, MIN(1, num(n, P::value, 0)))) > 1e-4;
    }
    return false;
}

static void node_tick(id owner, const RXFrame* f);
static __weak NSHashTable<RXNode*>* g_host_waiting;

void node_hosts_shown(id host) {
    NSHashTable<RXNode*>* w = g_host_waiting;
    if (!w.count)
        return;
    for (RXNode* n in w.allObjects) {
        if (host_of(n) != host && ![host_of(n) isDescendantOf:host])
            continue;
        [w removeObject:n];
        node_link(n, true);
    }
}

void node_link(RXNode* n, bool on) {
    id<RXHost> host = host_of(n);
    on = on && host && n.doc && moving(n);
    if (!on && is_elem(n, E::Shader))
        shader_unlink(n);
    if (!on && is_elem(n, E::Visualiser))
        visualiser_stop(n);
    if (!on && is_elem(n, E::Arc))
        arc_stop(n);
    if (!on && is_elem(n, E::Shapes))
        shapes_stop(n);
    if (!on && is_elem(n, E::Canvas))
        canvas_el_stop(n);
    if (!on && is_elem(n, E::Graph))
        graph_stop(n);
    if (on == (n.ticker != 0))
        return;
    if (!on) {
        ui_clock_remove(n.ticker);
        n.ticker = 0;
        return;
    }
    n.last_tick = CACurrentMediaTime();
    double fps = is_elem(n, E::Shader) ? shader_clock_fps(n)
        : is_elem(n, E::Visualiser)    ? visualiser_clock_fps(n)
        : is_elem(n, E::Arc)           ? arc_clock_fps(n)
        : is_elem(n, E::Shapes)        ? shapes_clock_fps(n)
        : is_elem(n, E::Canvas)        ? canvas_el_clock_fps(n)
        : is_elem(n, E::Graph)         ? graph_clock_fps(n)
                                       : 120;
    n.ticker = ui_clock_add(RX_TICK_NODE, fps, host, n, node_tick);
}
void node_link_rate(RXNode* n) {
    if (n.ticker)
        ui_clock_rate(n.ticker,
                      is_elem(n, E::Shader)           ? shader_clock_fps(n)
                          : is_elem(n, E::Visualiser) ? visualiser_clock_fps(n)
                          : is_elem(n, E::Arc)        ? arc_clock_fps(n)
                          : is_elem(n, E::Shapes)     ? shapes_clock_fps(n)
                          : is_elem(n, E::Canvas)     ? canvas_el_clock_fps(n)
                          : is_elem(n, E::Graph)      ? graph_clock_fps(n)
                                                      : 120);
    if (is_elem(n, E::Shader))
        shader_link_rate(n);
}

static void node_tick(id owner, const RXFrame* f) {
    RXNode* self = owner;
    if (!self.doc)
        return node_link(self, false);
    if (f->now - self.seen_at >= 0.1) {
        self.seen_at = f->now;
        id<RXHost> host = host_of(self);
        if (!host.window || host.hiddenOrHasHiddenAncestor) {
            static NSHashTable<RXNode*>* waiting;
            if (!waiting)
                waiting = [NSHashTable weakObjectsHashTable];
            [waiting addObject:self];
            g_host_waiting = waiting;
            return node_link(self, false);
        }
        if (!node_on_screen(self))
            return node_link(self, false);
    }
    double now = f->now, dt = MIN(0.1, now - self.last_tick);
    self.last_tick = now;
    if (is_elem(self, E::Arc)) {
        arc_watch(self);
        if (!self.ticker)
            return;
        node_link_rate(self);
    } else if (is_elem(self, E::Visualiser)) {
        if (visualiser_clock_fps(self) > 4)
            draw_visualiser(self), node_link_rate(self);
    } else if (is_elem(self, E::Image)) {
        apply_image_shape(self);
    } else if (is_elem(self, E::Shapes)) {
        shapes_tick(self, dt);
    } else if (is_elem(self, E::Graph)) {
        if (graph_clock_fps(self) > 4)
            graph_apply(self, nil);
    } else if (is_elem(self, E::Canvas)) {
        if (canvas_el_clock_fps(self) > 4)
            canvas_el_apply(self, nil);
    } else if (is_elem(self, E::Shader)) {
        shader_tick(self, dt);
    }
    node_link(self, true);
}
