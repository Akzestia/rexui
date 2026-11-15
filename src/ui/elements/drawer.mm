// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include <array>
#include <vector>

static void drawer_drag(RXNode* n, NSEvent* e, int phase);
static NSPoint moved(RXNode* n);
static NSSize sized(RXNode* n);
static int edges_at(RXNode* n, NSPoint p);
static NSCursor* edge_cursor(int e);

@implementation RXDrawerView
- (id)hitTest:(NSPoint)p {
    NSRect f = self.frame;
    NSPoint q = NSMakePoint(p.x - f.origin.x, p.y - f.origin.y);
    if (self.isHidden || !NSPointInRect(q, self.shown))
        return nil;
    id hit = [super hitTest:p];
    return hit && edges_at(self.node, q) ? self : hit;
}
- (void)mouseDown:(NSEvent*)e {
    drawer_drag(self.node, e, 0);
}
- (void)mouseDragged:(NSEvent*)e {
    drawer_drag(self.node, e, 1);
}
- (void)mouseUp:(NSEvent*)e {
    drawer_drag(self.node, e, 2);
}
- (void)rightMouseDown:(NSEvent*)e {
}
- (void)rightMouseUp:(NSEvent*)e {
}
- (void)otherMouseDown:(NSEvent*)e {
}
- (void)otherMouseUp:(NSEvent*)e {
}
- (void)scrollWheel:(NSEvent*)e {
}
@end

RXDockView* drawer_body(RXNode* n) {
    return ((RXDrawerView*)n.host).body;
}

static NSHashTable<RXNode*>* g_drawers;

void drawer_register(RXNode* n) {
    if (!g_drawers)
        g_drawers = [NSHashTable weakObjectsHashTable];
    [g_drawers addObject:n];
    keys_dirty();
}

NSArray<RXNode*>* all_drawers(void) {
    NSMutableArray* out = [NSMutableArray array];
    for (RXNode* n in g_drawers) {
        if (n.doc)
            [out addObject:n];
    }
    return out;
}

RXRoot* drawer_host(NSView* chrome) {
    return ui_root(chrome);
}

CGPathRef drawer_path(NSRect s, CGFloat r, bool up, CGFloat H) {
    return drawer_path_flared(s, r, up, H, @"round");
}

CGPathRef drawer_path_flared(NSRect s, CGFloat r, bool up, CGFloat H, NSString* flare) {
    constexpr CGFloat k = 0.5523;
    CGFloat w = s.size.width, h = s.size.height;
    CGFloat ry = MIN(r, h / 2);
    CGAffineTransform flip = up ? CGAffineTransformMake(1, 0, 0, -1, s.origin.x, H - s.origin.y)
                                : CGAffineTransformMakeTranslation(s.origin.x, s.origin.y);
    CGMutablePathRef p = CGPathCreateMutable();
    if ([flare isEqualToString:@"none"]) {
        CGPathAddRect(p, &flip, CGRectMake(r, 0, MAX(0, w - 2 * r), h));
        return p;
    }
    if ([flare isEqualToString:@"cut"]) {
        CGPathMoveToPoint(p, &flip, 0, 0);
        CGPathAddLineToPoint(p, &flip, r, ry);
        CGPathAddLineToPoint(p, &flip, r, h - ry);
        CGPathAddLineToPoint(p, &flip, 2 * r, h);
        CGPathAddLineToPoint(p, &flip, w - 2 * r, h);
        CGPathAddLineToPoint(p, &flip, w - r, h - ry);
        CGPathAddLineToPoint(p, &flip, w - r, ry);
        CGPathAddLineToPoint(p, &flip, w, 0);
        CGPathCloseSubpath(p);
        return p;
    }
    CGPathMoveToPoint(p, &flip, 0, 0);
    CGPathAddCurveToPoint(p, &flip, k * r, 0, r, ry - k * ry, r, ry);
    CGPathAddLineToPoint(p, &flip, r, h - ry);
    CGPathAddCurveToPoint(p, &flip, r, h - ry + k * ry, 2 * r - k * r, h, 2 * r, h);
    CGPathAddLineToPoint(p, &flip, w - 2 * r, h);
    CGPathAddCurveToPoint(p, &flip, w - 2 * r + k * r, h, w - r, h - ry + k * ry, w - r, h - ry);
    CGPathAddLineToPoint(p, &flip, w - r, ry);
    CGPathAddCurveToPoint(p, &flip, w - r, ry - k * ry, w - k * r, 0, w, 0);
    CGPathCloseSubpath(p);
    return p;
}

CF_RETURNS_RETAINED static CGPathRef panel_path(CGFloat w, CGFloat h, CGFloat r, NSString* shape, bool up) {
    if (shape.length) {
        if (CGPathRef p = box_path(shape, CGSizeMake(w, h))) {
            if (!up)
                return p;
            CGAffineTransform flip = CGAffineTransformMake(1, 0, 0, -1, 0, h);
            CGPathRef f = CGPathCreateCopyByTransformingPath(p, &flip);
            CGPathRelease(p);
            return f;
        }
    }
    r = MIN(r, MIN(w, h) / 2);
    return CGPathCreateWithRoundedRect(CGRectMake(0, 0, w, h), r, r, NULL);
}

static bool centred(RXNode* n) {
    NSString* p = str(n, P::placement, @"edge");
    return [p isEqualToString:@"center"] || [p isEqualToString:@"top"] || [p isEqualToString:@"pointer"] ||
        [p isEqualToString:@"pane"];
}
static bool on_pane(RXNode* n) {
    return [str(n, P::placement, @"edge") isEqualToString:@"pane"];
}
static NSRect focused_pane_rect(NSView* chrome) {
    NSString* b = string_of(panes_last_block()[@"block"]);
    NSView* v = b.length ? pane_views_now()[b] : nil;
    if (!v.window || v.window != chrome.window)
        return NSZeroRect;
    return [chrome convertRect:v.bounds fromView:v];
}
static bool at_pointer(RXNode* n) {
    return [str(n, P::placement, @"edge") isEqualToString:@"pointer"];
}
static bool at_top(RXNode* n) {
    return [str(n, P::placement, @"edge") isEqualToString:@"top"];
}
static bool grows(RXNode* n) {
    return [str(n, P::opening, @"drop") isEqualToString:@"grow"];
}
static const double* slide_curve(RXNode* n) {
    return grows(n) ? kStandard : kSpatial;
}
static bool beside(RXNode* n) {
    return [str(n, P::placement, @"edge") isEqualToString:@"side"];
}
static RXNode* owner_drawer(RXNode* n) {
    RXNode* o = n.parent;
    while (o && !is_drawer(o))
        o = o.parent;
    return o;
}

static void focus_opened(RXNode* n) {
    if (!flag(n, P::open, false))
        return;
    if (RXNode* f = autofocus_field(n))
        focus_node(f, false);
}

enum { kLeft = 1, kRight = 2, kTop = 4, kBottom = 8, kMove = 16 };
constexpr CGFloat kMinW = 560, kMinH = 360;

static void show_panel(RXNode* n, RXDrawerView* v, CGFloat W, CGFloat H, CGFloat r, double p) {
    v.alphaValue = MIN(1, p);
    bool appearing = v.hidden;
    if (v.hidden)
        unplace(n);
    v.hidden = NO;
    if (!CGRectEqualToRect(v.fill.frame, v.layer.bounds))
        v.fill.frame = v.layer.bounds;
    v.shown = v.bounds;
    if (appearing) {
        dispatch_async(dispatch_get_main_queue(), ^{
            focus_opened(n);
            tabpreview_shown(n);
            if (n.doc.natives.count)
                place_natives(n.doc);
        });
    }
    CALayer* layer = v.layer;
    if (layer.mask)
        layer.mask = nil;
    if (!CGAffineTransformIsIdentity(v.body.layer.affineTransform))
        v.body.layer.affineTransform = CGAffineTransformIdentity;
    NSString* shape = str(n, P::shape, @"");
    CGFloat radius = shape.length ? 0 : MIN(r, MIN(W, H) / 2);
    if (layer.cornerRadius != radius)
        layer.cornerRadius = radius;
    if (!layer.masksToBounds)
        layer.masksToBounds = YES;
    layer.cornerCurve = kCACornerCurveContinuous;
    CAShapeLayer* fill = v.fill;
    static char k_drawn;
    NSString* drawn = [NSString stringWithFormat:@"%gx%g %g %@", W, H, r, shape];
    if (!fill.path || ![objc_getAssociatedObject(fill, &k_drawn) isEqualToString:drawn]) {
        CGPathRef path = panel_path(W, H, r, shape, !fill.contentsAreFlipped);
        fill.path = path;
        CGPathRelease(path);
        objc_setAssociatedObject(fill, &k_drawn, drawn, OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    place(n, NSMakeRect(0, 0, W, H));
}

static void place_one(RXNode* n, NSView* chrome);
static void ca_slide_resized(RXNode* n);

static void place_drawer(RXNode* n, NSView* chrome) {
    place_one(n, chrome);
    for (RXNode* s in g_drawers) {
        if (s && s != n && s.doc && beside(s) && owner_drawer(s) == n)
            place_one(s, chrome);
    }
}

static void place_one(RXNode* n, NSView* chrome) {
    RXDrawerView* v = (RXDrawerView*)n.host;
    RXDockView* dock = n.doc.root.host;
    bool on = chrome && dock.superview && !dock.hiddenOrHasHiddenAncestor && host_of(n.parent).window == chrome.window
        && node_attached(n.parent) && flag(n, P::visible, true);
    RXRoot* host = [v.superview isKindOfClass:RXRoot.class] ? v.superview : nil;
    if (on) {
        static double looked;
        double now = CACurrentMediaTime();
        if (!host || host.superview != chrome || now - looked > 0.25)
            host = ui_root(chrome), looked = now;
        [host addHost:v band:kBandDrawers];
    }
    double p = n.progress;
    if (!on || p <= 0.001) {
        v.hidden = YES;
        n.held_h = 0;
        return;
    }
    CGFloat r = num(n, P::rounding, 25);
    NSRect a = [chrome convertRect:node_window_rect(n.parent) fromView:nil],
           d = [dock convertRect:dock.bounds toView:chrome];
    bool centre = centred(n);
    CGFloat floor_y = [str(n.doc.root, P::side, @"right") hasPrefix:@"top"] ? NSMaxY(d) : 0;
    NSRect below_dock = NSMakeRect(0, floor_y, chrome.bounds.size.width, MAX(0, chrome.bounds.size.height - floor_y));
    bool side = beside(n);
    NSString* dock_side = str(n.doc.root, P::side, @"right");
    bool railed = !centre && !side && ([dock_side isEqualToString:@"left"] || [dock_side isEqualToString:@"right"]);
    RXDrawerView* ov = side ? (RXDrawerView*)owner_drawer(n).host : nil;
    if (side && (!ov || ov.hidden || ov.superview != host)) {
        v.hidden = YES;
        return;
    }
    NSSize s = measure(n,
                       centre               ? MAX(0, below_dock.size.width - 48)
                           : side || railed ? MAX(0, chrome.bounds.size.width / 2)
                                            : MAX(0, d.size.width - 4 * r));
    if (centre && sized(n).width > 0)
        s = sized(n);
    NSSize want = NSMakeSize(MAX(s.width, 2 * r), s.height);
    if (!NSEqualSizes(want, n.box_to)) {
        [(RXAnim*)n.resize cancel];
        n.resize = nil;
        double ms = num(n, P::animation, 500);
        const bool sliding = n.slide_layers != nil;
        bool glide = n.box_now.width > 0 && p >= 0.999 && !sliding && !v.hidden && ms > 0 && !n.drag_mode;
        n.box_from = n.box_now;
        n.box_to = want;
        if (glide) {
            __weak RXNode* weak = n;
            RXAnim* anim = animate(
                chrome, ms,
                ^(double e) {
                    RXNode* n2 = weak;
                    NSWindow* w = dock_window();
                    if (!n2 || !w)
                        return;
                    n2.box_now = NSMakeSize(n2.box_from.width + (n2.box_to.width - n2.box_from.width) * e,
                                            n2.box_from.height + (n2.box_to.height - n2.box_from.height) * e);
                    place_drawer(n2, chrome_of(w));
                },
                ^{
                    RXNode* n2 = weak;
                    NSWindow* w = dock_window();
                    if (!n2)
                        return;
                    n2.resize = nil;
                    if (w)
                        place_drawer(n2, chrome_of(w));
                });
            anim.curve = kStandard;
            n.resize = anim;
        } else {
            n.box_now = want;
            if (sliding)
                ca_slide_resized(n);
        }
    }
    if (!n.resize)
        n.box_now = want;
    CGFloat W = MAX(2 * r, round(n.box_now.width)), H = MAX(1, round(n.box_now.height));
    if (centre) {
        H = MIN(H, MAX(1, below_dock.size.height - 48));
        if (sized(n).width > 0)
            H = MIN(n.box_now.height, MAX(1, below_dock.size.height - 16));
        below_dock = chrome.bounds;
        NSPoint off = flag(n, P::movable, true) ? moved(n) : NSZeroPoint;
        NSRect room = NSInsetRect(
            NSMakeRect(0, floor_y, chrome.bounds.size.width, MAX(0, chrome.bounds.size.height - floor_y)), 8, 8);
        if (at_top(n) && n.held_h <= 0)
            n.held_h = H;
        CGFloat y_rest = round(NSMidY(below_dock) - (at_top(n) ? n.held_h : H) / 2);
        CGFloat x = round(NSMidX(below_dock) - W / 2 + off.x), y = round(y_rest + off.y);
        if (at_pointer(n)) {
            NSPoint at = [chrome convertPoint:g_context_at fromView:nil];
            room = NSInsetRect(chrome.bounds, 8, 8);
            x = round(at.x + 2), y = round(at.y + 2);
            if (x + W > NSMaxX(room))
                x = round(at.x - 2 - W);
            if (y + H > NSMaxY(room))
                y = round(at.y - 2 - H);
            off = NSZeroPoint;
            x = MAX(NSMinX(room), MIN(x, NSMaxX(room) - W)), y = MAX(NSMinY(room), MIN(y, NSMaxY(room) - H));
            y_rest = y;
        }
        if (on_pane(n)) {
            NSRect pane = focused_pane_rect(chrome);
            if (!NSIsEmptyRect(pane)) {
                room = NSInsetRect(chrome.bounds, 8, 8);
                x = round(NSMidX(pane) - W / 2), y = round(NSMidY(pane) - H / 2);
                off = NSZeroPoint;
                y_rest = y;
            }
        }
        x = MAX(NSMinX(room), MIN(x, NSMaxX(room) - W));
        y = MAX(NSMinY(room), MIN(y, NSMaxY(room) - H));
        NSPoint at = NSMakePoint(x - round(NSMidX(below_dock) - W / 2), y - round(y_rest));
        if (n.drag_mode && !NSEqualPoints(at, off))
            n.moved = [NSValue valueWithPoint:at];
        NSRect f = NSMakeRect(x, y, W, H);
        if (n.drag_mode == kMove)
            f.origin = v.frame.origin;
        if (!NSEqualRects(v.frame, f))
            v.frame = f;
        CGFloat rise = at_pointer(n) ? 6 : 24;
        CGPoint from = [host convertPointToLayer:f.origin],
                to = [host convertPointToLayer:NSMakePoint(x, round(y + (1 - p) * rise))];
        CGAffineTransform t = CGAffineTransformMakeTranslation(to.x - from.x, to.y - from.y);
        if (!CGAffineTransformEqualToTransform(v.layer.affineTransform, t))
            v.layer.affineTransform = t;
        show_panel(n, v, W, H, r, p);
        return;
    }
    if (side) {
        NSRect o = [ov convertRect:ov.shown toView:host];
        RXNode* owner = owner_drawer(n);
        if (!centred(owner) && !beside(owner))
            o = NSInsetRect(o, num(owner, P::rounding, 25), 0);
        CGFloat gap = 8, dir = 1;
        NSRect f = NSMakeRect(round(NSMaxX(o) + gap), round(NSMinY(o) + 6), W, H);
        if (NSMaxX(f) > NSMaxX(host.bounds) - gap)
            f.origin.x = round(NSMinX(o) - gap - W), dir = -1;
        if (!NSEqualRects(v.frame, f))
            v.frame = f;
        CGAffineTransform t = CGAffineTransformMakeTranslation(round(-dir * (1 - p) * 16), 0);
        if (!CGAffineTransformEqualToTransform(v.layer.affineTransform, t))
            v.layer.affineTransform = t;
        show_panel(n, v, W, H, r, p);
        return;
    }
    if (railed) {
        bool left = [dock_side isEqualToString:@"left"];
        CGFloat gap = 6, shift = num(n, P::shift, 0);
        CGFloat y = round(NSMidY(a) + shift - H / 2);
        y = MAX(8, MIN(y, chrome.bounds.size.height - 8 - H));
        H = MIN(H, MAX(1, chrome.bounds.size.height - 16));
        NSRect f = NSMakeRect(left ? round(NSMaxX(d) + gap) : round(NSMinX(d) - gap - W), y, W, H);
        if (!NSEqualRects(v.frame, f))
            v.frame = f;
        CGAffineTransform t = CGAffineTransformMakeTranslation(round((left ? -1 : 1) * (1 - p) * 18), 0);
        if (!CGAffineTransformEqualToTransform(v.layer.affineTransform, t))
            v.layer.affineTransform = t;
        show_panel(n, v, W, H, r, p);
        return;
    }
    if (!v.layer.mask) {
        v.layer.affineTransform = CGAffineTransformIdentity;
        v.layer.masksToBounds = NO;
        v.layer.cornerRadius = 0;
        v.layer.mask = still([CAShapeLayer layer]);
    }
    CGFloat shift = num(n, P::shift, 0);
    if (shift != n.shift_to) {
        [(RXAnim*)n.shift_glide cancel];
        n.shift_glide = nil;
        double ms = num(n, P::animation, 500);
        n.shift_from = n.shift_now;
        n.shift_to = shift;
        if (!v.hidden && ms > 0) {
            __weak RXNode* weak = n;
            RXAnim* anim = animate(
                chrome, ms,
                ^(double e) {
                    RXNode* n2 = weak;
                    NSWindow* w = dock_window();
                    if (!n2 || !w)
                        return;
                    n2.shift_now = n2.shift_from + (n2.shift_to - n2.shift_from) * e;
                    place_drawer(n2, chrome_of(w));
                },
                ^{
                    RXNode* n2 = weak;
                    NSWindow* w = dock_window();
                    if (!n2)
                        return;
                    n2.shift_glide = nil;
                    if (w)
                        place_drawer(n2, chrome_of(w));
                });
            anim.curve = kStandard;
            n.shift_glide = anim;
        }
    }
    if (!n.shift_glide)
        n.shift_now = n.shift_to;
    CGFloat sf = n.shift_glide ? n.shift_from : n.shift_to;
    auto x_for = [&](CGFloat w, CGFloat s) {
        return MAX(NSMinX(d) + r, MIN(round(NSMidX(a) + s - w / 2), NSMaxX(d) - r - w));
    };
    CGFloat Wt = MAX(2 * r, round(n.box_to.width)), Ht = MAX(1, round(n.box_to.height));
    CGFloat Wf = n.resize ? MAX(2 * r, round(n.box_from.width)) : Wt,
            Hf = n.resize ? MAX(1, round(n.box_from.height)) : Ht;
    CGFloat x = x_for(W, n.shift_now), xt = x_for(Wt, n.shift_to), xf = x_for(Wf, sf), left = MIN(MIN(xt, xf), x) - r;
    NSRect f = NSMakeRect(left, NSMaxY(d), MAX(MAX(xt + Wt, xf + Wf), x + W) + r - left, MAX(Ht, Hf));
    if (!NSEqualRects(v.frame, f))
        v.frame = f;
    CGFloat vis = MAX(1, round(H * p));
    NSRect shown = NSMakeRect(x - r - left, 0, W + 2 * r, vis);
    const bool grow = grows(n) && p < 0.999;
    if (grow) {
        const CGFloat gw = MAX(2 * r, round(2 * r + (W - 2 * r) * p));
        shown = NSMakeRect(x_for(gw, n.shift_now) - r - left, 0, gw + 2 * r, vis);
    }
    v.shown = shown;
    const CGFloat alpha = grows(n) ? 1 : MIN(1, p);
    if (v.alphaValue != alpha)
        v.alphaValue = alpha;
    if (v.hidden) {
        unplace(n);
        dispatch_async(dispatch_get_main_queue(), ^{
            tabpreview_shown(n);
            if (n.doc.natives.count)
                place_natives(n.doc);
        });
    }
    v.hidden = NO;
    if (!CGRectEqualToRect(v.fill.frame, v.layer.bounds))
        v.fill.frame = v.layer.bounds;
    NSRect rest = NSMakeRect(xt - left, 0, Wt, Ht);
    place(n, rest);
    CGFloat mid = MAX(NSMinX(d) + r, MIN(NSMidX(a) + n.shift_now - W / 2, NSMaxX(d) - r - W)) + W / 2;
    NSPoint at = NSMakePoint(round(mid - Wt / 2) - left, p >= 0.999 || grow ? 0 : vis - Ht);
    CGPoint from = [v convertPointToLayer:rest.origin], to = [v convertPointToLayer:at];
    CGAffineTransform t = CGAffineTransformMakeTranslation(to.x - from.x, to.y - from.y);
    CAShapeLayer *fill = v.fill, *mask = (CAShapeLayer*)v.layer.mask;
    NSString* flare = str(n, P::flare, @"round");
    CGPathRef path = drawer_path_flared(shown, r, !fill.contentsAreFlipped, f.size.height, flare);
    fill.path = path;
    CGPathRelease(path);
    if (!CGRectEqualToRect(mask.frame, v.layer.bounds))
        mask.frame = v.layer.bounds;
    path = drawer_path_flared(shown, r, !v.layer.contentsAreFlipped, f.size.height, flare);
    mask.path = path;
    CGPathRelease(path);
    CALayer* body = v.body.layer;
    if (!CGAffineTransformEqualToTransform(body.affineTransform, t))
        body.affineTransform = t;
}

static NSMutableDictionary<NSString*, NSValue*>* g_moved;
static NSString* moved_key(RXNode* n) {
    return [NSString stringWithFormat:@"%@ %@", n.doc.path.lastPathComponent,
                                      str(n, @"id", [NSString stringWithFormat:@"%d", n.uid])];
}

static void read_moved(RXNode* n) {
    NSDictionary* d = [g_state dictionaryForKey:@"drawers"][moved_key(n)];
    NSArray* size = [d isKindOfClass:NSDictionary.class] ? d[@"size"] : nil;
    n.moved = g_moved[moved_key(n)] ?: [NSValue valueWithPoint:NSZeroPoint];
    n.sized = [NSValue valueWithSize:size.count == 2 ? NSMakeSize(num_of(size[0]), num_of(size[1])) : NSZeroSize];
}

static NSPoint moved(RXNode* n) {
    if (!n.moved)
        read_moved(n);
    return n.moved.pointValue;
}

static NSSize sized(RXNode* n) {
    if (!flag(n, P::resizable, true))
        return NSZeroSize;
    if (!n.sized)
        read_moved(n);
    return n.sized.sizeValue;
}

static void save_moved(RXNode* n) {
    if (!g_moved)
        g_moved = [NSMutableDictionary dictionary];
    g_moved[moved_key(n)] = [NSValue valueWithPoint:moved(n)];
    NSMutableDictionary* all = [[g_state dictionaryForKey:@"drawers"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSSize size = sized(n);
    NSMutableDictionary* d = [NSMutableDictionary dictionary];
    if (size.width > 0)
        d[@"size"] = @[@(size.width), @(size.height)];
    all[moved_key(n)] = d.count ? d : nil;
    [g_state setObject:all forKey:@"drawers"];
}

static int edges_at(RXNode* n, NSPoint p) {
    if (!n || !centred(n) || at_pointer(n) || on_pane(n) || n.progress < 0.999 || !flag(n, P::resizable, true))
        return 0;
    NSSize b = n.host.bounds.size;
    if (p.x < -2 || p.y < -2 || p.x > b.width + 2 || p.y > b.height + 2)
        return 0;
    CGFloat k = 6, c = 18;
    bool l = p.x<c, r = p.x> b.width - c, t = p.y<c, d = p.y> b.height - c;
    if ((l || r) && (t || d))
        return (l ? kLeft : kRight) | (t ? kTop : kBottom);
    return (p.x < k ? kLeft : 0) | (p.x > b.width - k ? kRight : 0) | (p.y < k ? kTop : 0)
        | (p.y > b.height - k ? kBottom : 0);
}

static NSCursor* edge_cursor(int e) {
    static NSMutableDictionary<NSNumber*, NSCursor*>* made = [NSMutableDictionary dictionary];
    if (NSCursor* c = made[@(e)])
        return c;
    NSCursor* c = nil;
    if (@available(macOS 15.0, *)) {
        NSCursorFrameResizePosition pos =
            (NSCursorFrameResizePosition)(((e & kTop) ? NSCursorFrameResizePositionTop : 0)
                                          | ((e & kBottom) ? NSCursorFrameResizePositionBottom : 0)
                                          | ((e & kLeft) ? NSCursorFrameResizePositionLeft : 0)
                                          | ((e & kRight) ? NSCursorFrameResizePositionRight : 0));
        c = [NSCursor frameResizeCursorFromPosition:pos inDirections:NSCursorFrameResizeDirectionsAll];
    }
    if (!c)
        c = (e & (kLeft | kRight)) ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor;
    made[@(e)] = c;
    return c;
}

static void drawer_drag(RXNode* n, NSEvent* e, int phase) {
    if (!n || !centred(n) || at_pointer(n) || on_pane(n) || n.progress < 0.999)
        return;
    NSWindow* w = dock_window();
    NSView* chrome = w ? chrome_of(w) : nil;
    if (!chrome)
        return;
    NSPoint m = NSEvent.mouseLocation;
    bool movable = flag(n, P::movable, true);
    if (phase == 0) {
        if (ui_clicks(e) == 2 && movable) {
            n.moved = [NSValue valueWithPoint:NSZeroPoint];
            n.sized = [NSValue valueWithSize:NSZeroSize];
            n.drag_mode = 0;
            place_drawer(n, chrome);
            save_moved(n);
            return;
        }
        int edges = edges_at(n, [n.host convertPoint:e.locationInWindow fromView:nil]);
        n.drag_mode = edges ?: movable ? kMove : 0;
        n.drag_mouse = m;
        n.drag_from = moved(n);
        n.drag_size = n.host.frame.size;
        if (edges)
            use_cursor(edge_cursor(edges));
        return;
    }
    int mode = n.drag_mode;
    if (!mode)
        return;
    CGFloat dx = m.x - n.drag_mouse.x, dy = -(m.y - n.drag_mouse.y);
    if (phase == 1 && mode == kMove) {
        NSPoint want = NSMakePoint(n.drag_from.x + dx, n.drag_from.y + dy);
        n.moved = [NSValue valueWithPoint:want];
        place_drawer(n, chrome);
        NSPoint got = moved(n);
        if (fabs(got.x - want.x) > 1)
            n.drag_from = NSMakePoint(got.x, n.drag_from.y), n.drag_mouse = NSMakePoint(m.x, n.drag_mouse.y);
        if (fabs(got.y - want.y) > 1)
            n.drag_from = NSMakePoint(n.drag_from.x, got.y), n.drag_mouse = NSMakePoint(n.drag_mouse.x, m.y);
        return;
    }
    if (phase == 1) {
        CGFloat W = n.drag_size.width, H = n.drag_size.height, ox = n.drag_from.x, oy = n.drag_from.y;
        if (mode & kRight)
            W += dx, ox += dx / 2;
        if (mode & kLeft)
            W -= dx, ox += dx / 2;
        if (mode & kBottom)
            H += dy, oy += dy / 2;
        if (mode & kTop)
            H -= dy, oy += dy / 2;
        CGFloat maxW = MAX(kMinW, chrome.bounds.size.width - 16), maxH = MAX(kMinH, chrome.bounds.size.height - 16);
        CGFloat W2 = MIN(maxW, MAX(kMinW, W)), H2 = MIN(maxH, MAX(kMinH, H));
        if (mode & kRight)
            ox -= (W - W2) / 2;
        if (mode & kLeft)
            ox += (W - W2) / 2;
        if (mode & kBottom)
            oy -= (H - H2) / 2;
        if (mode & kTop)
            oy += (H - H2) / 2;
        n.sized = [NSValue valueWithSize:NSMakeSize(round(W2), round(H2))];
        n.moved = [NSValue valueWithPoint:NSMakePoint(ox, oy)];
        use_cursor(edge_cursor(mode));
        if (n.drag_queued)
            return;
        n.drag_queued = true;
        __weak RXNode* weak = n;
        dispatch_async(dispatch_get_main_queue(), ^{
            RXNode* n2 = weak;
            if (!n2)
                return;
            n2.drag_queued = false;
            NSWindow* w2 = dock_window();
            if (w2)
                place_drawer(n2, chrome_of(w2));
        });
        return;
    }
    n.drag_mode = 0;
    place_drawer(n, chrome);
    save_moved(n);
}

void place_drawers(NSView* chrome) {
    for (RXNode* n in all_drawers())
        place_drawer(n, chrome);
}

bool drawers_open(RXDoc* doc) {
    for (RXNode* n in g_drawers)
        if (n.doc == doc && (flag(n, P::open, false) || n.progress > 0))
            return true;
    return false;
}

void layout_drawers(RXDoc* doc) {
    NSWindow* w = dock_window();
    NSView* chrome = w ? chrome_of(w) : nil;
    if (!chrome)
        return;
    for (RXNode* n in g_drawers) {
        if (n.doc == doc)
            place_drawer(n, chrome);
    }
}

static constexpr int k_samples = 20;

static constexpr double k_closed = 0.002;

static bool inside_drawer(RXNode* x, RXNode* d) {
    for (__unsafe_unretained RXNode* y = x; y; y = y->up)
        if (y == d)
            return true;
    return false;
}

static double ca_progress(RXNode* n) {
    if (!n.slide_layers)
        return n.progress;
    double t = n.slide_len > 0 ? MIN(1, MAX(0, (CACurrentMediaTime() - n.slide_t0) / n.slide_len)) : 1;
    return n.slide_from + (n.slide_to - n.slide_from) * curve_at(slide_curve(n), t);
}

static void ca_slide_stop(RXNode* n) {
    if (!n.slide_layers)
        return;
    double p = ca_progress(n);
    for (CALayer* l in n.slide_layers)
        [l removeAnimationForKey:@"rexui.slide"], [l removeAnimationForKey:@"rexui.slide.t"],
            [l removeAnimationForKey:@"rexui.slide.p"];
    n.slide_layers = nil;
    n.slide_gen++;
    n.progress = MIN(1, MAX(0, p));
}

static bool ca_drawer_slide(RXNode* n, NSView* chrome, double from, double target, double ms) {
    if (n.resize || n.shift_glide)
        return false;
    for (RXNode* x in n.doc.natives)
        if (inside_drawer(x, n))
            return false;
    const double to = target > 0 ? target : k_closed, start = MAX(from, k_closed);
    NSMutableArray<CALayer*>* layers = [NSMutableArray array];
    std::vector<std::array<NSMutableArray*, 3>> vals;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (int k = 0; k <= k_samples; k++) {
        double p = start + (to - start) * curve_at(slide_curve(n), (double)k / k_samples);
        n.progress = MAX(k_closed, p);
        place_drawer(n, chrome);
        if (k == 0) {
            NSMutableArray<RXNode*>* ds = [NSMutableArray arrayWithObject:n];
            for (RXNode* s in g_drawers)
                if (s && s != n && s.doc && beside(s) && owner_drawer(s) == n)
                    [ds addObject:s];
            for (RXNode* x in ds) {
                RXDrawerView* v = (RXDrawerView*)x.host;
                for (CALayer* l in @[
                         v.layer ?: NSNull.null, v.fill ?: NSNull.null, v.layer.mask ?: NSNull.null,
                         v.body.layer ?: NSNull.null
                     ])
                    if ([l isKindOfClass:CALayer.class])
                        [layers addObject:l];
            }
            vals.resize(layers.count);
            for (auto& v : vals)
                v = {[NSMutableArray array], [NSMutableArray array], [NSMutableArray array]};
        }
        for (NSUInteger i = 0; i < layers.count; i++) {
            CALayer* l = layers[i];
            [vals[i][0] addObject:@(l.opacity)];
            [vals[i][1] addObject:[NSValue valueWithCATransform3D:l.transform]];
            CGPathRef path = [l isKindOfClass:CAShapeLayer.class] ? ((CAShapeLayer*)l).path : nullptr;
            [vals[i][2] addObject:path ? (__bridge id)path : (id)NSNull.null];
        }
    }
    [CATransaction commit];
    NSMutableArray* keyTimes = [NSMutableArray array];
    for (int k = 0; k <= k_samples; k++)
        [keyTimes addObject:@((double)k / k_samples)];
    NSString* keys[3] = {@"opacity", @"transform", @"path"};
    for (NSUInteger i = 0; i < layers.count; i++) {
        for (int j = 0; j < 3; j++) {
            NSArray* v = vals[i][j];
            bool moved = false, missing = false;
            for (id x in v) {
                missing = missing || x == NSNull.null;
                if (j == 2 && x != NSNull.null && v.firstObject != NSNull.null)
                    moved = moved || !CGPathEqualToPath((__bridge CGPathRef)x, (__bridge CGPathRef)v.firstObject);
                else if (j != 2)
                    moved = moved || ![x isEqual:v.firstObject];
            }
            if (!moved || missing)
                continue;
            CAKeyframeAnimation* a = [CAKeyframeAnimation animationWithKeyPath:keys[j]];
            a.values = v;
            a.keyTimes = keyTimes;
            a.duration = ms / 1000;
            a.calculationMode = kCAAnimationLinear;
            [layers[i] addAnimation:a forKey:j == 0 ? @"rexui.slide" : j == 1 ? @"rexui.slide.t" : @"rexui.slide.p"];
        }
    }
    n.slide_layers = layers;
    n.slide_t0 = CACurrentMediaTime(), n.slide_from = start, n.slide_to = to, n.slide_len = ms / 1000;
    int gen = ++n.slide_gen;
    __weak RXNode* weak = n;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        RXNode* m = weak;
        if (!m || m.slide_gen != gen)
            return;
        m.slide_layers = nil;
        if (target == 0) {
            m.progress = 0;
            NSWindow* w = dock_window();
            if (w)
                place_drawer(m, chrome_of(w));
            if (m.doc.ctx)
                doc_call(m.doc, @"emit", @[@(m.uid), @"closed", @[]]);
        } else {
            m.progress = target;
            if (m.doc.ctx)
                doc_call(m.doc, @"emit", @[@(m.uid), @"opened", @[]]);
        }
        ui_pointer_refresh();
    });
    return true;
}

static void ca_slide_resized(RXNode* n) {
    static bool in;
    if (in || !n.slide_layers)
        return;
    NSWindow* w = dock_window();
    NSView* chrome = w ? chrome_of(w) : nil;
    if (!chrome)
        return;
    in = true;
    const double target = n.slide_to <= k_closed ? 0 : n.slide_to;
    const double left = MAX(0, n.slide_t0 + n.slide_len - CACurrentMediaTime()) * 1000;
    ca_slide_stop(n);
    if (left < 20 || !ca_drawer_slide(n, chrome, n.progress, target, left)) {
        in = false;
        drawer_slide(n);
        return;
    }
    in = false;
}

bool drawer_open_of(RXDoc* doc, bool pointer_too) {
    for (RXNode* n in g_drawers)
        if (n.doc == doc && flag(n, P::open, false)
            && (pointer_too || ![str(n, P::placement, @"") isEqualToString:@"pointer"]))
            return true;
    return false;
}

void drawer_slide(RXNode* n) {
    double target = flag(n, P::open, false) ? 1 : 0;
    bool any = false;
    for (RXNode* s in g_drawers)
        if (flag(s, P::open, false) && !s.doc.pane)
            any = true;
    panes_drawers_changed(any);
    NSString* only = str(n, P::exclusive, @"");
    if (target == 1 && only.length) {
        __weak RXNode* weak = n;
        dispatch_async(dispatch_get_main_queue(), ^{
            RXNode* me = weak;
            if (!me || !flag(me, P::open, false))
                return;
            for (RXNode* o in all_drawers())
                if (o != me && flag(o, P::open, false) && [str(o, P::exclusive, @"") isEqualToString:only])
                    drawer_set_open(o, false);
        });
    }
    if (target == 0 && n.host.window && focus_in(n.host))
        focus_back(n, n.host.window);
    else if (target == 0)
        n.focus_before = nil;
    [(RXAnim*)n.slide cancel];
    ca_slide_stop(n);
    double from = MIN(1, MAX(0, n.progress));
    if (from <= k_closed && target == 0)
        from = 0;
    NSWindow* w = dock_window();
    NSView* chrome = w ? chrome_of(w) : nil;
    double ms = num(n, P::animation, 500);
    if (target == 0 && num(n, P::closeAnimation, -1) >= 0)
        ms = num(n, P::closeAnimation, -1);
    if (from == target || !chrome || ms <= 0) {
        n.progress = target;
        if (chrome)
            place_drawer(n, chrome);
        return;
    }
    if (ca_drawer_slide(n, chrome, from, target, ms))
        return;
    __weak RXNode* weak = n;
    RXAnim* a = animate(
        chrome, ms,
        ^(double e) {
            RXNode* n2 = weak;
            NSWindow* w2 = dock_window();
            if (!n2 || !w2)
                return;
            n2.progress = from + (target - from) * e;
            place_drawer(n2, chrome_of(w2));
        },
        ^{
            RXNode* n2 = weak;
            if (n2.doc.natives.count)
                place_natives(n2.doc);
            if (n2 && n2.doc.ctx)
                doc_call(n2.doc, @"emit", @[@(n2.uid), target == 0 ? @"closed" : @"opened", @[]]);
            ui_pointer_refresh();
        });
    a.curve = slide_curve(n);
    n.slide = a;
}

bool ui_command(NSString* name) {
    bool any = false;
    for (RXNode* n in all_drawers()) {
        id c = obj(n, P::command);
        NSArray* names = [c isKindOfClass:NSArray.class] ? c : [c isKindOfClass:NSString.class] ? @[c] : @[];
        if (![names containsObject:name] || !n.doc.ctx)
            continue;
        any = true;
        if (flag(n, P::open, false) && [n.commanded isEqualToString:name]) {
            drawer_set_open(n, false);
            continue;
        }
        if ([n.commanded isEqualToString:name] && CACurrentMediaTime() - n.outside_closed < 0.8) {
            n.outside_closed = 0;
            continue;
        }
        n.commanded = name;
        drawer_set_open(n, true);
        doc_call(n.doc, @"emit", @[@(n.uid), @"commanded", @[name]]);
    }
    if (any)
        rexui_log([NSString stringWithFormat:@"commands: %@ taken over", name]);
    return any;
}

void drawer_set_open(RXNode* n, bool open) {
    if (flag(n, P::open, false) == open || !n.doc.ctx || beside(n))
        return;
    doc_call(n.doc, @"update", @[@(n.uid), @{@"open": @(open)}]);
}

void drawer_open_again(RXNode* n) {
    if (!n.doc.ctx || beside(n))
        return;
    doc_call(n.doc, @"update", @[@(n.uid), @{@"open": @YES}]);
}

static NSRect anchor_rect(RXNode* n, bool* across = nullptr) {
    NSRect a = node_window_rect(n.parent);
    if (across)
        *across = false;
    if (centred(n) || beside(n))
        return a;
    RXDockView* dock = n.doc.root.host;
    if (!dock.window || (id)host_of(n.parent) != (id)dock)
        return a;
    NSRect d = [dock convertRect:dock.bounds toView:nil];
    NSString* side = str(n.doc.root, P::side, @"right");
    bool top_bottom = [side isEqualToString:@"top"] || [side isEqualToString:@"bottom"];
    if (top_bottom && d.size.height <= 64)
        a.origin.y = d.origin.y, a.size.height = d.size.height;
    else if (([side isEqualToString:@"left"] || [side isEqualToString:@"right"]) && d.size.width <= 64)
        a.origin.x = d.origin.x, a.size.width = d.size.width;
    else
        return a;
    if (across)
        *across = true;
    return a;
}

static bool in_anchor(RXNode* n, NSPoint p) {
    return node_attached(n.parent) && !node_covered(n.parent) && NSPointInRect(p, anchor_rect(n));
}

static bool in_zone(RXNode* n, NSPoint p) {
    if (in_anchor(n, p))
        return true;
    RXDrawerView* v = (RXDrawerView*)n.host;
    if (!flag(n, P::open, false) || v.hidden || !v.window)
        return false;
    NSRect fill = NSInsetRect([v convertRect:v.shown toView:nil], -1, -1);
    if (NSMouseInRect(p, fill, NO))
        return true;
    for (RXNode* s in all_drawers()) {
        RXDrawerView* sv = (RXDrawerView*)s.host;
        if (beside(s) && owner_drawer(s) == n && !sv.hidden && sv.window == v.window
            && NSMouseInRect(p, NSInsetRect([sv convertRect:sv.shown toView:nil], -1, -1), NO))
            return true;
    }
    if (centred(n) || beside(n))
        return false;
    bool across = false;
    anchor_rect(n, &across);
    if (across)
        return false;
    RXDockView* dock = n.doc.root.host;
    NSRect bar = dock.window == v.window ? [dock convertRect:dock.bounds toView:nil] : NSZeroRect;
    NSRect bridge = NSMakeRect(NSMinX(fill), NSMaxY(fill), fill.size.width, MAX(0, NSMaxY(bar) - NSMaxY(fill)));
    return NSMouseInRect(p, bridge, NO);
}

static void hover_check(RXNode* n) {
    if (!n || !flag(n, P::hover, false))
        return;
    NSWindow* w = n.host.window ?: host_of(n.parent).window;
    if (!w)
        return;
    NSPoint p = [w convertPointFromScreen:NSEvent.mouseLocation];
    bool anchor = in_anchor(n, p), was = n.over_anchor;
    n.over_anchor = anchor;
    if (!flag(n, P::open, false)) {
        n.hover_armed = false;
        n.hover_out = 0;
        [n.hover_timer invalidate];
        n.hover_timer = nil;
        if (anchor && !was)
            drawer_set_open(n, true);
        if (!flag(n, P::open, false))
            return;
    }
    if (in_zone(n, p) || reorder_active()) {
        n.hover_armed = true;
        n.hover_out = 0;
    } else if (n.hover_armed) {
        if (n.hover_out == 0)
            n.hover_out = CACurrentMediaTime();
        else if (CACurrentMediaTime() - n.hover_out >= 0.15) {
            n.hover_armed = false;
            n.hover_out = 0;
            drawer_set_open(n, false);
            [n.hover_timer invalidate];
            n.hover_timer = nil;
            return;
        }
    }
    if (!n.hover_timer) {
        __weak RXNode* weak = n;
        n.hover_timer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                        repeats:YES
                                                          block:^(NSTimer* t) {
                                                              RXNode* n2 = weak;
                                                              if (!n2)
                                                                  return [t invalidate];
                                                              hover_check(n2);
                                                          }];
    }
}

static NSView* tracked_view(NSView* v) {
    for (; v && !v.trackingAreas.count; v = v.superview) {
    }
    return v;
}
static void page_pointer(NSView* hit, NSEvent* e) {
    static __weak NSView* in;
    NSView *was = in, *page = hit ? tracked_view(hit) : nil;
    auto told = [&](NSView* v, NSEventType type) {
        return [NSEvent enterExitEventWithType:type
                                      location:e.locationInWindow
                                 modifierFlags:e.modifierFlags
                                     timestamp:e.timestamp
                                  windowNumber:v.window.windowNumber
                                       context:nil
                                   eventNumber:0
                                trackingNumber:0
                                      userData:nullptr];
    };
    if (was && was != page) {
        NSEvent* left = told(was, NSEventTypeMouseExited);
        for (NSTrackingArea* a in was.trackingAreas)
            if (a.options & NSTrackingMouseEnteredAndExited)
                [a.owner mouseExited:left];
    }
    if (page && was != page) {
        NSEvent *came = told(page, NSEventTypeMouseEntered), *cursor = told(page, NSEventTypeCursorUpdate);
        for (NSTrackingArea* a in page.trackingAreas) {
            id owner = a.owner;
            if (a.options & NSTrackingMouseEnteredAndExited)
                [owner mouseEntered:came];
            if ((a.options & NSTrackingCursorUpdate) && [owner respondsToSelector:@selector(cursorUpdate:)])
                [owner cursorUpdate:cursor];
        }
    }
    in = page;
    for (NSTrackingArea* a in page.trackingAreas)
        if (a.options & NSTrackingMouseMoved)
            [a.owner mouseMoved:e];
}

NSEvent* drawer_pointer(NSEvent* e) {
    NSWindow* ew = e.window;
    static __weak RXDrawerView* hovered_in;
    RXNode* over = nil;
    for (RXNode* n in all_drawers()) {
        if (e.type == NSEventTypeMouseMoved && flag(n, P::hover, false)
            && (n.host.window ?: host_of(n.parent).window) == ew)
            hover_check(n);
        RXDrawerView* v = (RXDrawerView*)n.host;
        if (v.hidden || v.window != ew || !v.window)
            continue;
        if (NSPointInRect([v convertPoint:e.locationInWindow fromView:nil], v.shown))
            over = n;
    }
    if (over) {
        RXLayerHost* top = nil;
        [root_of(ew) topAt:e.locationInWindow owner:&top];
        if (top && is_float_bar_view(top))
            over = nil;
    }
    RXDrawerView* was_in = hovered_in;
    if (was_in && was_in != over.host && e.type == NSEventTypeMouseMoved) {
        host_pointer(was_in.body, NSMakePoint(-1e6, -1e6));
        hovered_in = nil;
    }
    if (!over) {
        if (e.type == NSEventTypeMouseMoved)
            page_pointer(nil, e);
        return e;
    }
    int edges = edges_at(over, [over.host convertPoint:e.locationInWindow fromView:nil]);
    if (e.type != NSEventTypeMouseMoved && !edges) {
        id owner = e.trackingArea.owner;
        NSView* carrier = over.host.hasCarrier ? over.host.carrier : nil;
        if (carrier && [owner isKindOfClass:NSView.class] && [(NSView*)owner isDescendantOf:carrier])
            return e;
    }
    if (e.type == NSEventTypeMouseMoved) {
        RXDrawerView* dv = (RXDrawerView*)over.host;
        host_pointer(dv.body, e.locationInWindow);
        hovered_in = dv;
    }
    RXLayerHost* owner = nil;
    id top = [root_of(ew) topAt:e.locationInWindow owner:&owner];
    bool native = [top isKindOfClass:NSView.class];
    if (e.type == NSEventTypeMouseMoved)
        page_pointer(native && !edges && [owner isDescendantOf:over.host] ? top : nil, e);
    if (edges)
        use_cursor(edge_cursor(edges));
    else if (!native)
        use_cursor(((RXDrawerView*)over.host).body.pointerCursor ?: NSCursor.arrowCursor);
    return nil;
}

void drawer_click(NSEvent* e) {
    NSWindow* ew = e.window;
    RXLayerHost* owner = nil;
    id top = [root_of(ew) topAt:e.locationInWindow owner:&owner];
    RXNode* node =
        [top isKindOfClass:RXDockView.class] ? node_at_window_point((RXDockView*)top, e.locationInWindow) : nil;
    if (!is_elem(node, E::TextField) && !is_elem(node, E::TextArea))
        node = nil;
    if (node) {
        for (RXNode* n in all_drawers()) {
            if (!flag(n, P::open, false) || ![owner isDescendantOf:n.host])
                continue;
            NSWindow* w = ew;
            __weak RXNode* wn = node;
            dispatch_async(dispatch_get_main_queue(), ^{
                RXNode* f = wn;
                RXEditor* ed = f.editor;
                if (ed && editor_in(w) != ed && [ed.host window] == w) {
                    rexui_log(@"drawer: a click on a field lost the keyboard; given back");
                    editor_focus(ed);
                }
            });
            break;
        }
    }
    bool tools = debug_pointer_in_devtools(e);
    for (RXNode* n in all_drawers()) {
        if (!flag(n, P::open, false) || n.host.window != ew)
            continue;
        if (tools && !n.doc.devtools)
            continue;
        bool on_anchor = !at_pointer(n) && node_attached(n.parent) && NSPointInRect(e.locationInWindow, anchor_rect(n));
        if ([owner isDescendantOf:n.host] || on_anchor)
            continue;
        n.outside_closed = CACurrentMediaTime();
        drawer_set_open(n, false);
    }
}
