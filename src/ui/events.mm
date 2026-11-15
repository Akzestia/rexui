// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/clicks.h"
#include "base/trace.h"
#include "web/web.h"

static void emit(RXNode* n, NSString* signal, NSArray* args) {
    if (n.doc.ctx)
        doc_call(n.doc, @"emit", @[@(n.uid), signal, args]);
}

static NSHashTable<RXNode*>* g_outside;

void outside_watch(RXNode* n, bool on) {
    if (!g_outside)
        g_outside = [NSHashTable weakObjectsHashTable];
    if (on)
        [g_outside addObject:n];
    else
        [g_outside removeObject:n];
}

void outside_click(NSEvent* e) {
    NSWindow* ew = e.window;
    bool tools = debug_pointer_in_devtools(e);
    for (RXNode* n in g_outside.allObjects) {
        if (!n.doc || !node_on_screen(n) || (tools && !n.doc.devtools))
            continue;
        if (host_of(n).window == ew && NSPointInRect(e.locationInWindow, node_window_rect(n)))
            continue;
        __weak RXNode* weak = n;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (RXNode* n2 = weak)
                emit(n2, @"pressedOutside", @[]);
        });
    }
}

RXDockView* dock_host_of(RXNode* n) {
    id h = host_of(n);
    return [h isKindOfClass:RXLayerHost.class] ? h : nil;
}

id<RXHost> host_of(RXNode* n) {
    for (RXNode* x = n; x; x = x.parent) {
        if (is_drawer(x))
            return (id<RXHost>)((RXDrawerView*)x.host).body;
        if (x.doc && x == x.doc.root) {
            if (is_elem(x, E::Panes))
                return (id<RXHost>)pane_style_host();
            return (id<RXHost>)x.host;
        }
    }
    return nil;
}

static bool in_host(RXNode* n, id<RXHost> h, bool self_too, CGRect* full, CGRect* shown, CALayer** clipper) {
    CALayer* l = n.layer;
    if (!h || !l)
        return false;
    CALayer* x = self_too ? l : l.superlayer;
    for (; x && x != h.layer; x = x.superlayer) {
        if (x.hidden)
            return false;
    }
    if (!x)
        return false;
    *full = [l convertRect:l.bounds toLayer:h.layer];
    CGRect r = *full;
    if (clipper)
        *clipper = nil;
    for (CALayer* c = l.superlayer; c && c != h.layer; c = c.superlayer) {
        if (!c.masksToBounds)
            continue;
        CGRect cr = [c convertRect:c.bounds toLayer:h.layer];
        if (clipper && !*clipper && c.cornerRadius > 0)
            *clipper = c;
        r = CGRectIntersection(r, cr);
    }
    *shown = r;
    return true;
}

static NSRect visible_rect(RXNode* n) {
    id<RXHost> h = host_of(n);
    if (!h.window || h.hiddenOrHasHiddenAncestor)
        return NSZeroRect;
    CGRect full, shown;
    if (!in_host(n, h, true, &full, &shown, nullptr) || CGRectIsNull(shown))
        return NSZeroRect;
    return NSIntersectionRect([h convertRectFromLayer:shown], h.visibleRect);
}

bool node_on_screen(RXNode* n) {
    return !NSIsEmptyRect(visible_rect(n));
}

bool node_clipped_away(RXNode* n) {
    id<RXHost> h = host_of(n);
    if (!h.window || h.hiddenOrHasHiddenAncestor)
        return false;
    CGRect full, shown;
    if (!in_host(n, h, true, &full, &shown, nullptr) || CGRectIsEmpty(full))
        return false;
    return CGRectIsNull(shown) || CGRectIsEmpty(shown);
}

bool node_attached(RXNode* n) {
    id<RXHost> h = host_of(n);
    CGRect full, shown;
    return h.window && !h.hiddenOrHasHiddenAncestor && in_host(n, h, true, &full, &shown, nullptr);
}

NSRect node_window_rect(RXNode* n) {
    id<RXHost> h = host_of(n);
    if (!h || !n.layer)
        return NSZeroRect;
    return [h convertRect:[h convertRectFromLayer:[n.layer convertRect:n.layer.bounds toLayer:h.layer]] toView:nil];
}

@interface RXClip : NSView
@end
@implementation RXClip
- (BOOL)isFlipped {
    return YES;
}
@end

void place_natives(RXDoc* doc) {
    for (RXNode* n in doc.natives.allObjects) {
        NSView* v = n.view;
        id<RXHost> h = host_of(n);
        if (!v || !h || !n.doc)
            continue;
        const bool parked = web_parked(n);
        NSView* carrier = dock_host_of(n).carrier;
        if (!carrier)
            continue;
        if (!n.clip) {
            RXClip* c = [[RXClip alloc] initWithFrame:NSZeroRect];
            c.wantsLayer = YES;
            c.clipsToBounds = YES;
            n.clip = c;
        }
        NSView* clip = n.clip;
        if (clip.superview != carrier)
            [carrier addSubview:clip];
        if (!parked && v.superview != clip) {
            [v removeFromSuperview];
            [clip addSubview:v];
        }
        CGRect full, shown;
        CALayer* rounded = nil;
        bool on = in_host(n, h, true, &full, &shown, &rounded) && !CGRectIsNull(shown) && !CGRectIsEmpty(shown);
        if (!on) {
            if (!clip.hidden)
                clip.hidden = YES;
            continue;
        }
        NSRect f = [h convertRectFromLayer:full], c = [h convertRectFromLayer:shown];
        if (!NSEqualRects(clip.frame, c))
            clip.frame = c;
        NSRect inner = NSOffsetRect(f, -c.origin.x, -c.origin.y);
        if (parked)
            web_parked_place(n, inner);
        else if ([v isKindOfClass:WKWebView.class])
            web_place(n, (WKWebView*)v, clip, f, c);
        else if (!NSEqualRects(v.frame, inner))
            v.frame = inner;
        CGFloat r = 0;
        if (rounded) {
            NSRect rr = [h convertRectFromLayer:[rounded convertRect:rounded.bounds toLayer:h.layer]];
            CGFloat R = rounded.cornerRadius, e = 0.5;
            CGFloat l = MAX(0, NSMinX(c) - NSMinX(rr)), t = MAX(0, NSMinY(c) - NSMinY(rr));
            CGFloat rt = MAX(0, NSMaxX(rr) - NSMaxX(c)), b = MAX(0, NSMaxY(rr) - NSMaxY(c));
            CGFloat in = MIN(MIN(MAX(l, t), MAX(rt, t)), MIN(MAX(l, b), MAX(rt, b)));
            if (in < R - e)
                r = in < e ? R : R - in;
        }
        if (clip.layer.cornerRadius != r) {
            clip.layer.cornerRadius = r;
            clip.layer.cornerCurve = kCACornerCurveContinuous;
        }
        if (clip.hidden)
            clip.hidden = NO;
    }
}

enum Want { kClick, kHover, kArea, kWheel, kCursor, kDrop, kDropData, kAny, kPaint, kSeen };
static bool drop_takes(RXNode* n);

static bool in_shape(RXNode* n, CGPoint q) {
    NSString* spec = str(n, P::shape, @"");
    if (!spec.length)
        return true;
    CGRect b = n.layer.bounds;
    CGPathRef path = box_path(spec, b.size);
    if (!path)
        return true;
    bool in = CGPathContainsPoint(path, nullptr, CGPointMake(q.x - b.origin.x, q.y - b.origin.y), false);
    CGPathRelease(path);
    return in;
}

static bool paints(RXNode* n);
static bool wants(RXNode* n, CGPoint q, Want w) {
    switch (w) {
    case kAny:
        return true;
    case kPaint:
        return n.layer.opacity > 0 && paints(n);
    case kSeen:
        return n.layer.opacity > 0;
    case kHover:
        return is_elem(n, E::Button) && in_shape(n, q);
    case kArea:
        return is_elem(n, E::MouseArea) && flag(n, P::enabled, true) && in_shape(n, q);
    case kDrop:
        return flag(n, P::dropFiles, false);
    case kDropData:
        return drop_takes(n);
    case kWheel:
        return (is_elem(n, E::MouseArea) && flag(n, P::enabled, true) && flag(n, @"wantsWheel", false))
            || (is_list(n) && ((RXScrollLayer*)n.layer).maxOffset > 0)
            || (is_elem(n, E::TextArea) && n.editor.maxScroll > 0) || (is_elem(n, E::TabPreview) && n.editor);
    case kCursor:
        return (is_elem(n, E::Text) && flag(n, P::selectable, false))
            || (is_elem(n, E::TextField) && flag(n, P::enabled, true)) || is_elem(n, E::TextArea)
            || (is_elem(n, E::TabPreview) && n.editor);
    case kClick:
        if (is_elem(n, E::Button))
            return in_shape(n, q);
        if (is_elem(n, E::Slider) || is_elem(n, E::TextField) || is_elem(n, E::TextArea))
            return true;
        if (is_elem(n, E::MouseArea))
            return flag(n, P::enabled, true) && in_shape(n, q);
        if (is_elem(n, E::Text))
            return flag(n, P::selectable, false)
                || ([n.layer isKindOfClass:RXTextLayer.class] && [(RXTextLayer*)n.layer linkAt:q]);
        if (is_list(n))
            return [(RXScrollLayer*)n.layer onKnobStrip:q];
        if (is_elem(n, E::TabPreview))
            return n.editor != nil;
        return is_elem(n, E::Arc) && arc_hit(n, NSPointFromCGPoint(q));
    }
    return false;
}

static void button_pressed(RXNode* n, bool on) {
    if (flag(n, @"wantsPressed", false) && n.doc.ctx)
        doc_call(n.doc, @"update", @[@(n.uid), @{@"pressed": @(on)}]);
}

static uint64_t g_hit_visits;
uint64_t hit_visits(void) {
    return g_hit_visits;
}

static RXNode* node_at_in(RXNode* n, CALayer* from, CGPoint p, Want w) {
    g_hit_visits++;
    CALayer* l = n.layer;
    if (!l || l.hidden || !l.superlayer || !flag(n, P::expanded, true))
        return nil;
    if ((w == kPaint || w == kSeen) && l.opacity <= 0)
        return nil;
    CGPoint q = [l convertPoint:p fromLayer:from];
    if (!CGRectContainsPoint(l.bounds, q))
        return nil;
    NSArray<RXNode*>* kids = n.children;
    if (n.z_kids) {
        if (!n->_z_order || n->_z_epoch != g_kids_epoch) {
            n->_z_order =
                [kids sortedArrayWithOptions:NSSortStable
                             usingComparator:^NSComparisonResult(RXNode* a, RXNode* b) {
                                 const double za = num(a, P::z, 0), zb = num(b, P::z, 0);
                                 return za < zb ? NSOrderedAscending : za > zb ? NSOrderedDescending : NSOrderedSame;
                             }];
            n->_z_epoch = g_kids_epoch;
        }
        NSArray<RXNode*>* by_z = n->_z_order;
        for (NSUInteger i = by_z.count; i-- > 0;) {
            RXNode* c = by_z[i];
            if (is_drawer(c))
                continue;
            if (RXNode* hit = node_at_in(c, l, q, w))
                return hit;
        }
        return wants(n, q, w) ? n : nil;
    }
    if (is_list(n) && kids.count > 16 && num(n, P::spacing, 0) >= 0 && !is_vlist(n)
        && ![str(n, P::orientation, @"") isEqualToString:@"horizontal"]) {
        CALayer* doc = ((RXScrollLayer*)l).doc;
        const CGFloat y = [doc convertPoint:q fromLayer:l].y;
        NSUInteger lo = 0, hi = kids.count;
        while (lo < hi) {
            const NSUInteger mid = (lo + hi) / 2;
            CALayer* m = kids[mid].layer;
            if (m && !m.hidden && CGRectGetMinY(m.frame) > y)
                hi = mid;
            else
                lo = mid + 1;
        }
        for (NSUInteger i = lo; i-- > 0;) {
            RXNode* c = kids[i];
            CALayer* cl = c.layer;
            if (!cl || cl.hidden || is_drawer(c))
                continue;
            if (CGRectGetMaxY(cl.frame) <= y)
                break;
            if (RXNode* hit = node_at_in(c, l, q, w))
                return hit;
        }
        return wants(n, q, w) ? n : nil;
    }
    for (NSUInteger i = kids.count; i-- > 0;) {
        RXNode* c = kids[i];
        if (is_drawer(c))
            continue;
        if (RXNode* hit = node_at_in(c, l, q, w))
            return hit;
    }
    return wants(n, q, w) ? n : nil;
}
static RXNode* node_at(RXNode* n, CALayer* top, CGPoint p, Want w) {
    return node_at_in(n, top, p, w);
}

static NSCursor* button_cursor(RXNode* b) {
    NSString* c = b ? str(b, P::cursor, @"") : @"";
    if (!c.length && b && is_elem(b, E::Text))
        c = @"pointer";
    if (!c.length)
        return nil;
    if ([c isEqualToString:@"resizeLeftRight"])
        return NSCursor.resizeLeftRightCursor;
    if ([c isEqualToString:@"resizeUpDown"])
        return NSCursor.resizeUpDownCursor;
    if ([c isEqualToString:@"pointer"])
        return NSCursor.pointingHandCursor;
    if ([c isEqualToString:@"move"])
        return NSCursor.openHandCursor;
    if ([c isEqualToString:@"crosshair"])
        return NSCursor.crosshairCursor;
    return nil;
}

static void hits_at(RXNode* n, CALayer* top, CGPoint p, NSMutableArray<RXNode*>* out) {
    CALayer* l = n.layer;
    if (!l || l.hidden || !l.superlayer || !flag(n, P::expanded, true) || l.opacity <= 0)
        return;
    CGPoint q = [l convertPoint:p fromLayer:top];
    if (!CGRectContainsPoint(l.bounds, q))
        return;
    for (RXNode* c in n.children.reverseObjectEnumerator) {
        if (!is_drawer(c))
            hits_at(c, top, p, out);
    }
    [out addObject:n];
}

static bool paints(RXNode* n) {
    if (is_elem(n, E::Button))
        return str(n, P::text, @"").length || str(n, P::icon, @"").length;
    if (is_box(n) && !is_list(n)) {
        NSColor* c = parse_color(obj_of(n, P::color));
        return (c && c.alphaComponent > 0) || num(n, P::border_width, 0) > 0;
    }
    return !is_elem(n, E::Item);
}

static RXNode* pick_at(RXNode* root, CALayer* top, CGPoint p, bool smallest) {
    NSMutableArray<RXNode*>* hits = [NSMutableArray array];
    hits_at(root, top, p, hits);
    if (!hits.count)
        return nil;
    if (smallest) {
        RXNode* best = nil;
        CGFloat area = INFINITY;
        for (RXNode* h in hits) {
            CGSize s = h.layer.bounds.size;
            if (s.width * s.height < area)
                area = s.width * s.height, best = h;
        }
        return best;
    }
    for (RXNode* h in hits) {
        if (paints(h))
            return h;
    }
    return hits.firstObject;
}

static NSArray<NSString*>* g_fd_paths;
static CALayer* g_fd_ghost;
static __weak RXNode* g_fd_target;

static void fd_hover(RXNode* t) {
    RXNode* old = g_fd_target;
    if (old == t)
        return;
    if (old.doc.ctx)
        doc_call(old.doc, @"update", @[@(old.uid), @{@"dropHovered": @NO}]);
    g_fd_target = t;
    if (t.doc.ctx)
        doc_call(t.doc, @"update", @[@(t.uid), @{@"dropHovered": @YES}]);
}

static CALayer* fd_ghost(NSArray<NSString*>* paths) {
    RXLayer* g = [RXLayer layer];
    g.bounds = CGRectMake(0, 0, 40, 40);
    g.zPosition = 1e6;
    g.opacity = 0.9;
    NSImage* icon = [NSWorkspace.sharedWorkspace iconForFile:paths.firstObject];
    NSRect r = NSMakeRect(0, 0, 80, 80);
    g.contents = (__bridge id)[icon CGImageForProposedRect:&r context:nil hints:nil];
    g.contentsGravity = kCAGravityResizeAspect;
    if (paths.count > 1) {
        RXLayer* badge = [RXLayer layer];
        badge.frame = CGRectMake(26, -4, 20, 20);
        badge.cornerRadius = 10;
        badge.backgroundColor = [NSColor colorWithSRGBRed:0.85 green:0.47 blue:0.34 alpha:1].CGColor;
        CATextLayer* t = [CATextLayer layer];
        t.frame = CGRectMake(0, 3, 20, 14);
        t.string = paths.count > 99 ? @"99+" : [@(paths.count) stringValue];
        t.fontSize = 10;
        t.font = (__bridge CFTypeRef)[NSFont boldSystemFontOfSize:10];
        t.alignmentMode = kCAAlignmentCenter;
        t.foregroundColor = NSColor.whiteColor.CGColor;
        t.contentsScale = 2;
        t.actions = @{@"contents": NSNull.null, @"position": NSNull.null, @"bounds": NSNull.null};
        [badge addSublayer:t];
        [g addSublayer:badge];
    }
    return g;
}

static void fd_end(void) {
    fd_hover(nil);
    [g_fd_ghost removeFromSuperlayer];
    g_fd_ghost = nil;
    g_fd_paths = nil;
}

static Class fd_surface_cls(void) {
    static Class c = NSClassFromString(RXNS(RXN_165)) ?: NSClassFromString(RXNS(RXN_164));
    return c;
}
static bool fd_over_pane(NSWindow* w, NSPoint win) {
    NSView* frame = w.contentView.superview ?: w.contentView;
    if (!NSPointInRect(win, frame.frame))
        return false;
    if (panes_app_at(w, win, nil))
        return true;
    for (NSView* v = [frame hitTest:win]; v; v = v.superview)
        if (fd_surface_cls() && [v isKindOfClass:fd_surface_cls()])
            return true;
    return false;
}

static bool has_control(NSString* p) {
    for (NSUInteger i = 0; i < p.length; i++) {
        const unichar c = [p characterAtIndex:i];
        if (c < 0x20 || c == 0x7f || (c >= 0x80 && c < 0xa0) || c == 0x2028 || c == 0x2029)
            return true;
    }
    return false;
}
static NSString* ansi_c_word(NSString* p) {
    NSMutableString* w = [NSMutableString stringWithString:@"$'"];
    for (NSUInteger i = 0; i < p.length; i++) {
        const unichar c = [p characterAtIndex:i];
        if (c == '\\')
            [w appendString:@"\\\\"];
        else if (c == '\'')
            [w appendString:@"\\'"];
        else if (c == '\n')
            [w appendString:@"\\n"];
        else if (c == '\r')
            [w appendString:@"\\r"];
        else if (c == '\t')
            [w appendString:@"\\t"];
        else if (c < 0x20 || c == 0x7f)
            [w appendFormat:@"\\x%02x", c];
        else if ((c >= 0x80 && c < 0xa0) || c == 0x2028 || c == 0x2029) {
            char u8[4];
            const NSUInteger k = [[NSString stringWithCharacters:&c length:1] getCString:u8
                                                                               maxLength:sizeof u8
                                                                                encoding:NSUTF8StringEncoding]
                ? strlen(u8)
                : 0;
            for (NSUInteger b = 0; b < k; b++)
                [w appendFormat:@"\\x%02x", (unsigned char)u8[b]];
        } else
            [w appendFormat:@"%C", c];
    }
    [w appendString:@"'"];
    return w;
}
NSString* drop_shell_words(NSArray<NSString*>* paths) {
    NSCharacterSet* special = [NSCharacterSet characterSetWithCharactersInString:@" \t\\'\"()[]{}&;|<>*?$#!~`"];
    NSMutableArray* words = [NSMutableArray array];
    for (NSString* p in paths) {
        if (has_control(p)) {
            [words addObject:ansi_c_word(p)];
            continue;
        }
        NSMutableString* w = [NSMutableString string];
        for (NSUInteger i = 0; i < p.length; i++) {
            unichar c = [p characterAtIndex:i];
            if ([special characterIsMember:c])
                [w appendString:@"\\"];
            [w appendFormat:@"%C", c];
        }
        [words addObject:w];
    }
    return [[words componentsJoinedByString:@" "] stringByAppendingString:@" "];
}

static bool fd_drop_on_pane(NSWindow* w, NSPoint win, NSArray<NSString*>* paths) {
    if (panes_app_at(w, win, paths))
        return true;
    NSString* block = panes_block_at(w, win);
    if (!block)
        return false;
    agent_send(g_session_id, block, drop_shell_words(paths), false, false);
    rexui_log_file([NSString stringWithFormat:@"files: %lu paths dropped into %@", (unsigned long)paths.count, block]);
    return true;
}

static RXDockView* host_under(NSWindow* w, NSPoint win);

static RXDockView* fd_host_at(NSWindow* w, NSPoint win) {
    NSView* frame = w.contentView.superview ?: w.contentView;
    if (!NSPointInRect(win, frame.frame))
        return nil;
    return host_under(w, win);
}

@interface RXDockView ()
- (RXNode*)nodeAt:(NSPoint)p want:(Want)w;
- (void)pointer:(NSPoint)p;
@end

static RXNode* g_dd_source;
static CALayer* g_dd_ghost;
static __weak RXNode* g_dd_target;
static __weak RXNode* g_dd_external;

static id dd_data(RXNode* n) {
    return obj_of(n, P::dragData);
}
static NSString* dd_key(RXNode* n) {
    return str(n, P::dragKey, @"");
}
static NSString* dd_text(RXNode* n) {
    return str(n, P::dragText, @"");
}
static bool has_drag(RXNode* n) {
    return n && (is_elem(n, E::MouseArea) || is_elem(n, E::Button)) && (dd_data(n) != nil || dd_text(n).length);
}

static bool drop_takes(RXNode* n) {
    if (!g_dd_source || n == g_dd_source || !is_elem(n, E::MouseArea) || !flag(n, P::enabled, true)
        || !flag(n, @"wantsDrop", false))
        return false;
    id keys = obj_of(n, P::dropKeys);
    if (![keys isKindOfClass:NSArray.class] || ![keys count])
        return true;
    return [keys containsObject:dd_key(g_dd_source)];
}

static void dd_hover(RXNode* t) {
    RXNode* old = g_dd_target;
    if (old == t)
        return;
    if (old.doc.ctx) {
        doc_call(old.doc, @"update", @[@(old.uid), @{@"dropHovered": @NO}]);
        doc_call(old.doc, @"emit", @[@(old.uid), @"dragExited", @[]]);
    }
    g_dd_target = t;
    if (t.doc.ctx) {
        doc_call(t.doc, @"update", @[@(t.uid), @{@"dropHovered": @YES}]);
        doc_call(t.doc, @"emit",
                 @[@(t.uid), @"dragEntered", @[dd_data(g_dd_source) ?: dd_text(g_dd_source), dd_key(g_dd_source)]]);
    }
}

static CALayer* dd_ghost(RXNode* n) {
    CALayer* l = n.layer;
    const CGSize size = CGSizeMake(MIN(l.bounds.size.width, 480), MIN(l.bounds.size.height, 240));
    RXLayer* g = [RXLayer layer];
    g.bounds = CGRectMake(0, 0, size.width, size.height);
    g.zPosition = 1e6;
    g.opacity = 0.8;
    g.shadowOpacity = 0.3, g.shadowRadius = 8, g.shadowOffset = CGSizeZero;
    const CGFloat scale = l.contentsScale > 1 ? l.contentsScale : backing_scale();
    const size_t w = (size_t)ceil(size.width * scale), h = (size_t)ceil(size.height * scale);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx =
        w && h ? CGBitmapContextCreate(nullptr, w, h, 8, 0, space, kCGImageAlphaPremultipliedLast) : nullptr;
    CGColorSpaceRelease(space);
    if (ctx) {
        CGContextScaleCTM(ctx, scale, scale);
        if (l.contentsAreFlipped) {
            CGContextTranslateCTM(ctx, 0, size.height);
            CGContextScaleCTM(ctx, 1, -1);
        }
        [l renderInContext:ctx];
        CGImageRef image = CGBitmapContextCreateImage(ctx);
        g.contents = (__bridge id)image;
        g.contentsScale = scale;
        if (image)
            CGImageRelease(image);
        CGContextRelease(ctx);
    }
    return g;
}

static void dd_finish(bool accepted) {
    RXNode* source = g_dd_source;
    dd_hover(nil);
    [g_dd_ghost removeFromSuperlayer];
    g_dd_ghost = nil;
    g_dd_source = nil;
    if (source.doc.ctx) {
        doc_call(source.doc, @"update", @[@(source.uid), @{@"dragActive": @NO}]);
        doc_call(source.doc, @"emit", @[@(source.uid), @"dragEnded", @[@(accepted)]]);
    }
}

bool data_drag_cancel(void) {
    if (!g_dd_source)
        return false;
    dd_finish(false);
    return true;
}

@interface RXDockView (DataDrag)
- (void)dataDragBegin:(RXNode*)n event:(NSEvent*)e;
- (void)dataDragged:(NSEvent*)e at:(NSPoint)p;
- (void)dataDropped:(NSEvent*)e;
@end

static NSHashTable<RXDockView*>* g_hosts;
static __weak RXDockView* g_pointer_host;

@interface RXDockView () {
    __weak RXNode* _w_node;
}
@end
@interface RXDockView () {
    __weak RXSlot* _w_slot;
}
@end
@implementation RXDockView {
    __weak RXNode* _grab;
    RXNode* _other_grab;
    NSPoint _other_at;
    __weak RXNode* _area_top;
    NSString* _link_press;
    NSArray<RXNode*>* _areas;
    int _press_gen;
    __weak RXNode* _hover;
    NSCursor* _cursor;
    bool _entering;
    NSPoint _press_at;
    bool _dragging;
    int _slot_press;
}
- (RXSlot*)slot {
    return _w_slot;
}
- (void)setSlot:(RXSlot*)v {
    _w_slot = v;
}
- (RXNode*)node {
    return _w_node;
}
- (void)setNode:(RXNode*)v {
    _w_node = v;
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window && !self.hiddenOrHasHiddenAncestor)
        node_hosts_shown(self);
}
- (void)viewDidUnhide {
    [super viewDidUnhide];
    if (self.window)
        node_hosts_shown(self);
}
- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f]))
        return nil;
    if (!g_hosts)
        g_hosts = [NSHashTable weakObjectsHashTable];
    [g_hosts addObject:self];
    return self;
}

- (RXNode*)nodeAt:(NSPoint)p want:(Want)w {
    RXNode* root = self.node;
    if (!root.layer || !NSPointInRect(p, self.bounds))
        return nil;
    return node_at(root, self.layer, [self convertPointToLayer:p], w);
}

- (id)hitTest:(NSPoint)p {
    if (self.slot && !slot_reachable(self.slot))
        return nil;
    NSRect f = self.frame;
    if (self.slot && !self.isHidden && NSPointInRect(NSMakePoint(p.x - f.origin.x, p.y - f.origin.y), self.slot.edge))
        return self;
    return [super hitTest:p];
}

static NSCursor* slot_cursor(RXSlot* slot) {
    return vertical(side_of(slot)) ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor;
}

static RXSlot* edge_at(RXDockView* v, NSPoint p) {
    RXDockView* s = v.slot ? v : [v.superview isKindOfClass:RXDockView.class] ? (RXDockView*)v.superview : nil;
    RXSlot* slot = s.slot;
    if (!slot || NSIsEmptyRect(slot.edge) || !slot_reachable(slot))
        return nil;
    if (slot.resizing)
        return slot;
    return NSPointInRect(s == v ? p : [v convertPoint:p toView:s], slot.edge) ? slot : nil;
}

static NSString* button_name(NSEvent* e) {
    if (e.type == NSEventTypeRightMouseDown || e.type == NSEventTypeRightMouseUp)
        return @"right";
    switch (e.buttonNumber) {
    case 0:
        return @"left";
    case 1:
        return @"right";
    case 2:
        return @"middle";
    case 3:
        return @"back";
    case 4:
        return @"forward";
    default:
        return [NSString stringWithFormat:@"button%ld", (long)e.buttonNumber];
    }
}

static void set_area_pressed(RXNode* n, bool on, CGPoint q) {
    n.pressed = on;
    if (n.doc.ctx)
        doc_call(n.doc, @"update", @[@(n.uid), @{@"pressed": @(on), @"mouseX": @(q.x), @"mouseY": @(q.y)}]);
}

static void set_hovered(RXNode* n, bool on) {
    if (!n || n.hovered == on)
        return;
    n.hovered = on;
    [(RXButtonLayer*)n.layer refreshState];
    if (n.doc.ctx)
        doc_call(n.doc, @"update", @[@(n.uid), @{@"hovered": @(on)}]);
}

- (void)hoverAreas:(RXNode*)top at:(NSPoint)p {
    if (top != (RXNode*)_area_top) {
        NSMutableArray<RXNode*>* now = [NSMutableArray array];
        for (RXNode* x = top; x; x = x.parent)
            if (is_elem(x, E::MouseArea) && flag(x, P::enabled, true))
                [now addObject:x];
        for (RXNode* x in _areas) {
            if ([now containsObject:x])
                continue;
            x.hovered = false;
            if (x.doc.ctx) {
                doc_call(x.doc, @"update", @[@(x.uid), @{@"hovered": @NO}]);
                doc_call(x.doc, @"emit", @[@(x.uid), @"exited", @[]]);
            }
        }
        for (RXNode* x in now) {
            if ([_areas containsObject:x])
                continue;
            x.hovered = true;
            if (x.doc.ctx) {
                doc_call(x.doc, @"update", @[@(x.uid), @{@"hovered": @YES}]);
                doc_call(x.doc, @"emit", @[@(x.uid), @"entered", @[]]);
            }
        }
        _areas = now.count ? now : nil;
        _area_top = top;
    }
    for (RXNode* x in _areas) {
        const bool heard = flag(x, @"wantsMoved", false), tracked = flag(x, P::trackMouse, false);
        if ((!heard && !tracked) || !x.doc.ctx)
            continue;
        const CGPoint q = [self point:p inNode:x];
        if (tracked)
            doc_call(x.doc, @"update", @[@(x.uid), @{@"mouseX": @(q.x), @"mouseY": @(q.y)}]);
        if (heard)
            doc_call(x.doc, @"emit", @[@(x.uid), @"moved", @[@(q.x), @(q.y)]]);
    }
}

- (void)pointer:(NSPoint)p {
    bool inside = NSPointInRect(p, self.bounds) && !self.hiddenOrHasHiddenAncestor && self.window;
    if (debug_picking()) {
        bool ctrl = NSEvent.modifierFlags & NSEventModifierFlagControl;
        RXNode* root = self.node;
        RXNode* any = inside && root.layer && NSPointInRect(p, self.bounds)
            ? pick_at(root, self.layer, [self convertPointToLayer:p], ctrl)
            : nil;
        if (any)
            debug_pick_hover(any);
        debug_pick_host(self, p);
        return;
    }
    RXSlot* edge = edge_at(self, p);
    RXNode* b = inside && !edge ? [self nodeAt:p want:kHover] : nil;
    RXNode* under = nil;
    if (inside && !edge && self.node.layer && self.node.doc.has_tips) {
        const CGPoint q = [self convertPointToLayer:p];
        under = node_at(self.node, self.layer, q, kPaint) ?: node_at(self.node, self.layer, q, kSeen);
    }
    tips_pointer(self, under);
    RXNode* was_hover = _hover;
    if (b != was_hover) {
        set_hovered(was_hover, false);
        _hover = b;
        set_hovered(b, true);
    }
    RXNode* area = nil;
    if (self.node.doc.has_areas || _areas) {
        area = inside && !edge ? [self nodeAt:p want:kArea] : nil;
        [self hoverAreas:area at:p];
    }
    if (RXSlot* slot = self.slot; slot.bar && slot.bar.layer.superlayer == self.layer) {
        bar_moved(slot.bar, inside && NSPointInRect(p, slot.bar.frame) ? p : NSMakePoint(NAN, NAN));
    }
    id hit = inside ? [self.rootView topAt:[self convertPoint:p toView:nil] owner:nil] : nil;
    RXNode* fn = hit == self ? [self nodeAt:p want:kCursor] : nil;
    bool field = fn != nil;
    RXTermInput* term =
        is_elem(fn, E::TabPreview) && [fn.editor isKindOfClass:RXTermInput.class] ? (RXTermInput*)fn.editor : nil;
    term_input_hover(self, term, term ? [self point:p inNode:fn] : CGPointZero);
    NSCursor* c = edge ? slot_cursor(edge)
        : field        ? term_input_cursor(term) ?: NSCursor.IBeamCursor
        : hit == self  ? button_cursor(b) ?: button_cursor(area)
                       : nil;
    if (c != _cursor || (_entering && (edge || hit == self))) {
        _cursor = c;
        use_cursor(c ?: NSCursor.arrowCursor);
    }
    _entering = false;
}
- (void)pointerEntered {
    _entering = true;
}
- (NSCursor*)pointerCursor {
    return _cursor;
}
- (void)mouseMoved:(NSEvent*)e {
    RX_INTERVAL(pointer, "moved");
    [self pointer:[self convertPoint:e.locationInWindow fromView:nil]];
}
- (NSDragOperation)draggingSession:(NSDraggingSession*)s sourceOperationMaskForDraggingContext:(NSDraggingContext)c {
    return NSDragOperationCopy | NSDragOperationLink | NSDragOperationGeneric;
}
- (void)pointerLeft:(NSPoint)p {
    [self pointer:!NSPointInRect(p, self.bounds) && edge_at(self, p) ? p : NSMakePoint(-1e6, -1e6)];
}
- (void)viewDidHide {
    [super viewDidHide];
    [self pointer:NSMakePoint(-1e6, -1e6)];
}
- (CGPoint)point:(NSPoint)p inNode:(RXNode*)n {
    return [n.layer convertPoint:[self convertPointToLayer:p] fromLayer:self.layer];
}

- (void)mouseDown:(NSEvent*)e {
    engine_urgent();
    RX_INTERVAL(pointer, "down");
    (void)ui_clicks(e);
    tips_hide();
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    _slot_press = 0;
    if (debug_picking()) {
        bool ctrl = e.modifierFlags & NSEventModifierFlagControl;
        if (RXNode* any = self.node.layer ? pick_at(self.node, self.layer, [self convertPointToLayer:p], ctrl) : nil) {
            _grab = nil;
            debug_pick_click(any);
            return;
        }
    }
    if (RXSlot* slot = self.slot) {
        if (NSPointInRect(p, slot.edge)) {
            _slot_press = 2;
            if (ui_clicks(e) == 2) {
                slot.dragged = 0;
                slot.size = wanted_size(slot);
                save_slot(slot);
                chrome_relayout();
                _slot_press = 0;
                return;
            }
            [slot.resize cancel];
            slot.resizing = true;
            slot.resize_mouse = e.locationInWindow;
            slot.resize_from = slot.size;
            return;
        }
        if (slot.bar.layer.superlayer == self.layer && NSPointInRect(p, slot.bar.frame)) {
            _slot_press = 1;
            bar_down(slot.bar, p);
            return;
        }
    }
    RXNode* n = [self nodeAt:p want:kClick];
    _grab = n;
    _press_at = e.locationInWindow;
    _dragging = false;
    RXNode* item = (!n || is_elem(n, E::Button)) && !has_drag(n) ? reorder_item(self, p) : nil;
    reorder_press(self, item, p);
    if (!n) {
        if (!item)
            [super mouseDown:e];
        return;
    }
    CGPoint q = [self point:p inNode:n];
    if (is_elem(n, E::Text) && [(RXTextLayer*)n.layer linkAt:q] && !flag(n, P::selectable, false)) {
        _link_press = [(RXTextLayer*)n.layer linkAt:q];
        return;
    }
    if (is_elem(n, E::Button)) {
        if (!flag(n, P::enabled, true))
            return;
        n.pressed = true;
        button_pressed(n, true);
        [(RXButtonLayer*)n.layer refreshState];
        if (ui_clicks(e) == 2)
            emit(n, @"doubleClicked", @[]);
    } else if (is_elem(n, E::Slider)) {
        RXSliderLayer* s = (RXSliderLayer*)n.layer;
        if (!s.enabled)
            return;
        s.dragging = true;
        [self slide:n to:q.x];
    } else if (is_elem(n, E::Arc)) {
        arc_track(n, NSPointFromCGPoint(q), 0);
    } else if (is_elem(n, E::Text)) {
        text_press(n, q, ui_clicks(e), (e.modifierFlags & NSEventModifierFlagShift) != 0);
    } else if (is_elem(n, E::MouseArea)) {
        if (flag(n, P::focusable, false))
            focus_node(n, false);
        set_area_pressed(n, true, q);
        emit(n, @"press", @[@(q.x), @(q.y), @"left", key_mods(e.modifierFlags)]);
        int gen = ++_press_gen;
        __weak RXNode* weak = n;
        __weak RXDockView* host = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            RXNode* a = weak;
            RXDockView* h = host;
            if (!a || !h || h->_press_gen != gen || !a.pressed || h->_dragging)
                return;
            emit(a, @"longPressed", @[@(q.x), @(q.y)]);
        });
    } else if (is_list(n)) {
        [(RXScrollLayer*)n.layer dragKnob:q];
    } else if (is_elem(n, E::TextField) || is_elem(n, E::TextArea)) {
        if (is_elem(n, E::TextField)) {
            if (!flag(n, P::enabled, true))
                return (void)(_grab = nil);
            field_edit(n);
        } else if (RXEditor* ed = node_editor(n, true)) {
            editor_focus(ed);
        }
        [n.editor pressAt:q clicks:ui_clicks(e) extend:(e.modifierFlags & NSEventModifierFlagShift) != 0];
    } else if (is_elem(n, E::TabPreview) && n.editor) {
        editor_focus(n.editor);
        [n.editor pressAt:q clicks:ui_clicks(e) extend:(e.modifierFlags & NSEventModifierFlagShift) != 0];
    }
}
- (void)rightMouseDown:(NSEvent*)e {
    (void)ui_clicks(e);
    engine_urgent();
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (debug_picking())
        return;
    RXNode* n = [self nodeAt:p want:kClick];
    if (is_elem(n, E::TabPreview) && n.editor)
        return [n.editor otherPress:e at:[self point:p inNode:n] up:false];
    if (is_elem(n, E::MouseArea))
        return [self otherDown:n event:e at:p];
    if (!is_elem(n, E::Button) || !flag(n, P::enabled, true))
        return;
    g_context_at = e.locationInWindow;
    emit(n, @"rightClicked", @[]);
}
- (void)otherDown:(RXNode*)n event:(NSEvent*)e at:(NSPoint)p {
    const CGPoint q = [self point:p inNode:n];
    g_context_at = e.locationInWindow;
    _other_grab = n;
    set_area_pressed(n, true, q);
    emit(n, @"press", @[@(q.x), @(q.y), button_name(e), key_mods(e.modifierFlags)]);
}
- (bool)otherUp:(NSEvent*)e at:(NSPoint)p {
    RXNode* n = _other_grab;
    if (!n)
        return false;
    _other_grab = nil;
    const CGPoint q = [self point:p inNode:n];
    set_area_pressed(n, false, q);
    emit(n, @"release", @[@(q.x), @(q.y), button_name(e), key_mods(e.modifierFlags)]);
    if (CGRectContainsPoint(n.layer.bounds, q))
        emit(n, @"clicked", @[@(q.x), @(q.y), button_name(e), key_mods(e.modifierFlags)]);
    return true;
}
- (void)otherMouseDown:(NSEvent*)e {
    (void)ui_clicks(e);
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    RXNode* n = debug_picking() ? nil : [self nodeAt:p want:kClick];
    if (is_elem(n, E::MouseArea))
        return [self otherDown:n event:e at:p];
    [super otherMouseDown:e];
}
- (void)otherMouseUp:(NSEvent*)e {
    if (![self otherUp:e at:[self convertPoint:e.locationInWindow fromView:nil]])
        [super otherMouseUp:e];
}
- (void)rightMouseUp:(NSEvent*)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if ([self otherUp:e at:p])
        return;
    RXNode* n = [self nodeAt:p want:kClick];
    if (is_elem(n, E::TabPreview) && n.editor)
        [n.editor otherPress:e at:[self point:p inNode:n] up:true];
}
- (void)slide:(RXNode*)n to:(CGFloat)x {
    RXSliderLayer* s = (RXSliderLayer*)n.layer;
    double v = [s valueAt:x];
    if (v == s.value)
        return;
    s.value = v;
    emit(n, @"moved", @[@(v)]);
}
- (void)mouseDragged:(NSEvent*)e {
    RX_INTERVAL(pointer, "dragged");
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (RXSlot* slot = self.slot; slot && _slot_press == 2) {
        NSString* side = side_of(slot);
        NSView* chrome = self.superview;
        CGFloat dx = e.locationInWindow.x - slot.resize_mouse.x, dy = e.locationInWindow.y - slot.resize_mouse.y;
        CGFloat d = [side isEqualToString:@"right"] ? -dx
            : [side isEqualToString:@"left"]        ? dx
            : [side isEqualToString:@"top"]         ? -dy
                                                    : dy;
        CGFloat limit = (vertical(side) ? chrome.bounds.size.width : chrome.bounds.size.height) * 0.7;
        slot.dragged = slot.size = round(MAX(160, MIN(limit, slot.resize_from + d)));
        chrome_relayout();
        return;
    }
    if (_slot_press == 1)
        return bar_dragged(self.slot.bar, p);
    if (reorder_drag(self, p)) {
        if (RXNode* b = _grab; is_elem(b, E::Button) && b.pressed) {
            b.pressed = false;
            [(RXButtonLayer*)b.layer refreshState];
        }
        _grab = nil;
        return;
    }
    if (g_dd_source)
        return [self dataDragged:e at:p];
    RXNode* n = _grab;
    if (!n)
        return [super mouseDragged:e];
    CGPoint q = [self point:p inNode:n];
    if (is_elem(n, E::Text))
        return text_drag(n, q);
    if (has_drag(n) && flag(n, P::enabled, true)) {
        if (hypot(e.locationInWindow.x - _press_at.x, e.locationInWindow.y - _press_at.y) < 3)
            return;
        [self dataDragBegin:n event:e];
        _grab = nil;
        return [self dataDragged:e at:p];
    }
    if (is_elem(n, E::MouseArea) && !has_prop(n, P::dragFile)) {
        const CGFloat dx = e.locationInWindow.x - _press_at.x, dy = _press_at.y - e.locationInWindow.y;
        if (!_dragging && hypot(dx, dy) < 2)
            return;
        _dragging = true;
        emit(n, @"dragged", @[@(dx), @(dy), @(q.x), @(q.y)]);
        return;
    }
    id files = is_elem(n, E::Button) || is_elem(n, E::MouseArea) ? obj(n, P::dragFile) : nil;
    if ((is_elem(n, E::Button) || is_elem(n, E::MouseArea))
        && ([files isKindOfClass:NSString.class] ? [files length]
                                                 : [files isKindOfClass:NSArray.class] && [files count])) {
        if (!g_fd_paths) {
            if (hypot(e.locationInWindow.x - _press_at.x, e.locationInWindow.y - _press_at.y) < 3)
                return;
            NSMutableArray* paths = [NSMutableArray array];
            NSString* dir = n.doc.path.stringByDeletingLastPathComponent;
            for (id f in [files isKindOfClass:NSArray.class] ? files : @[files]) {
                if (![f isKindOfClass:NSString.class] || ![f length])
                    continue;
                NSString* path = [f stringByExpandingTildeInPath];
                [paths addObject:path.isAbsolutePath ? path : [dir stringByAppendingPathComponent:path]];
            }
            if (!paths.count)
                return;
            n.pressed = false;
            if (is_elem(n, E::Button))
                [(RXButtonLayer*)n.layer refreshState];
            g_fd_paths = paths;
            g_fd_ghost = fd_ghost(paths);
            [self.window.contentView.layer addSublayer:g_fd_ghost];
        }
        NSWindow* w = self.window;
        if (RXDockView* host = fd_host_at(w, e.locationInWindow)) {
            fd_hover([host nodeAt:[host convertPoint:e.locationInWindow fromView:nil] want:kDrop]);
            NSView* cv = w.contentView;
            CGPoint at = [cv convertPointToLayer:[cv convertPoint:e.locationInWindow fromView:nil]];
            g_fd_ghost.position = CGPointMake(at.x + 14, at.y + (cv.isFlipped ? 14 : -14));
            return;
        }
        if (fd_over_pane(w, e.locationInWindow)) {
            fd_hover(nil);
            NSView* cv = w.contentView;
            CGPoint at = [cv convertPointToLayer:[cv convertPoint:e.locationInWindow fromView:nil]];
            g_fd_ghost.position = CGPointMake(at.x + 14, at.y + (cv.isFlipped ? 14 : -14));
            return;
        }
        NSArray* paths = g_fd_paths;
        fd_end();
        NSMutableArray* items = [NSMutableArray array];
        CGFloat off = 0;
        for (NSString* path in paths) {
            NSDraggingItem* item = [[NSDraggingItem alloc] initWithPasteboardWriter:[NSURL fileURLWithPath:path]];
            [item setDraggingFrame:NSMakeRect(p.x - 16 + off, p.y - 16 + off, 32, 32)
                          contents:[NSWorkspace.sharedWorkspace iconForFile:path]];
            off += 4;
            [items addObject:item];
        }
        _grab = nil;
        RXRoot* root = self.rootView;
        NSPoint d = [root convertPoint:e.locationInWindow fromView:nil];
        for (NSDraggingItem* item in items) {
            NSRect f = item.draggingFrame;
            item.draggingFrame = NSOffsetRect(f, d.x - p.x, d.y - p.y);
        }
        if (root)
            [root beginDraggingSessionWithItems:items event:e source:(id<NSDraggingSource>)self];
        return;
    }
    if (is_elem(n, E::Button) && flag(n, P::drag, false)) {
        CGFloat dx = e.locationInWindow.x - _press_at.x, dy = _press_at.y - e.locationInWindow.y;
        if (!_dragging && hypot(dx, dy) < 2)
            return;
        _dragging = true;
        emit(n, @"dragged", @[@(dx), @(dy)]);
    } else if (is_elem(n, E::Button)) {
        bool in = CGRectContainsPoint(n.layer.bounds, q);
        if (in != n.pressed) {
            n.pressed = in;
            [(RXButtonLayer*)n.layer refreshState];
        }
    } else if (is_elem(n, E::Slider)) {
        if (((RXSliderLayer*)n.layer).dragging)
            [self slide:n to:q.x];
    } else if (is_elem(n, E::Arc)) {
        arc_track(n, NSPointFromCGPoint(q), 1);
    } else if (is_list(n)) {
        [(RXScrollLayer*)n.layer dragKnob:q];
    } else if (n.editor) {
        [n.editor dragTo:q];
    }
}
- (void)mouseUp:(NSEvent*)e {
    engine_urgent();
    RX_INTERVAL(pointer, "up");
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (RXSlot* slot = self.slot; slot && _slot_press == 2) {
        _slot_press = 0;
        slot.resizing = false;
        save_slot(slot);
        [self pointer:p];
        return;
    }
    if (_slot_press == 1) {
        _slot_press = 0;
        return bar_up(self.slot.bar, p);
    }
    if (reorder_release()) {
        _grab = nil;
        return;
    }
    if (g_fd_paths) {
        RXNode* t = g_fd_target;
        NSArray* paths = g_fd_paths;
        bool copy = (e.modifierFlags & NSEventModifierFlagOption) != 0;
        fd_end();
        if (RXNode* held = _grab; held && is_elem(held, E::MouseArea))
            set_area_pressed(held, false, CGPointZero);
        _grab = nil;
        if (t && flag(t, P::dropFiles, false))
            emit(t, @"filesDropped", @[paths, @(copy)]);
        else if (!t && !fd_host_at(self.window, e.locationInWindow))
            fd_drop_on_pane(self.window, e.locationInWindow, paths);
        return;
    }
    if (g_dd_source) {
        _grab = nil;
        return [self dataDropped:e];
    }
    RXNode* n = _grab;
    _grab = nil;
    if (!n)
        return [super mouseUp:e];
    CGPoint q = [self point:p inNode:n];
    if (is_elem(n, E::TabPreview))
        return (void)[n.editor releaseAt:q];
    if (is_elem(n, E::Text))
        return text_release(n);
    if (is_elem(n, E::MouseArea)) {
        const bool dragged = _dragging;
        _dragging = false;
        NSString* mods = key_mods(e.modifierFlags);
        set_area_pressed(n, false, q);
        emit(n, @"release", @[@(q.x), @(q.y), @"left", mods]);
        if (dragged)
            return emit(n, @"dropped", @[@(e.locationInWindow.x - _press_at.x), @(_press_at.y - e.locationInWindow.y)]);
        if (CGRectContainsPoint(n.layer.bounds, q)) {
            emit(n, @"clicked", @[@(q.x), @(q.y), @"left", mods]);
            if (ui_clicks(e) == 2)
                emit(n, @"doubleClicked", @[@(q.x), @(q.y), @"left", mods]);
        }
        return;
    }
    if (is_elem(n, E::Button) && _dragging) {
        _dragging = false;
        n.pressed = false;
        button_pressed(n, false);
        [(RXButtonLayer*)n.layer refreshState];
        emit(n, @"dropped", @[@(e.locationInWindow.x - _press_at.x), @(_press_at.y - e.locationInWindow.y)]);
    } else if (is_elem(n, E::Text) && _link_press) {
        NSString* link = _link_press;
        _link_press = nil;
        if ([link isEqualToString:[(RXTextLayer*)n.layer linkAt:q]])
            emit(n, @"linkActivated", @[link]);
    } else if (is_elem(n, E::Button)) {
        bool click = n.pressed && CGRectContainsPoint(n.layer.bounds, q);
        n.pressed = false;
        button_pressed(n, false);
        [(RXButtonLayer*)n.layer refreshState];
        if (click)
            [n clicked:nil];
    } else if (is_elem(n, E::Slider)) {
        RXSliderLayer* s = (RXSliderLayer*)n.layer;
        if (!s.dragging)
            return;
        s.dragging = false;
        emit(n, @"released", @[@(s.value)]);
        if (s.behind) {
            s.behind = false;
            s.minValue = num(n, P::from, 0);
            s.maxValue = num(n, P::to, 1);
            s.value = num(n, P::value, 0);
        }
    } else if (is_elem(n, E::Arc)) {
        arc_track(n, NSPointFromCGPoint(q), 2);
    }
}
- (void)scrollWheel:(NSEvent*)e {
    RX_INTERVAL(pointer, "scroll");
    RXNode* n = [self nodeAt:[self convertPoint:e.locationInWindow fromView:nil] want:kWheel];
    if (!n)
        return [super scrollWheel:e];
    if (n.editor)
        return (void)[n.editor scrollBy:e];
    if (is_elem(n, E::MouseArea)) {
        const CGFloat k = e.hasPreciseScrollingDeltas ? 1 : 12;
        return emit(n, @"wheel", @[@(e.scrollingDeltaX * k), @(e.scrollingDeltaY * k), key_mods(e.modifierFlags)]);
    }
    [(RXScrollLayer*)n.layer scrollWheel:e];
}
@end

@implementation RXDockView (DataDrag)
- (void)dataDragBegin:(RXNode*)n event:(NSEvent*)e {
    if (n.pressed) {
        n.pressed = false;
        if (is_elem(n, E::Button))
            [(RXButtonLayer*)n.layer refreshState];
        else
            set_area_pressed(n, false, CGPointZero);
    }
    g_dd_source = n;
    g_dd_ghost = dd_ghost(n);
    [self.window.contentView.layer addSublayer:g_dd_ghost];
    if (n.doc.ctx) {
        doc_call(n.doc, @"update", @[@(n.uid), @{@"dragActive": @YES}]);
        doc_call(n.doc, @"emit", @[@(n.uid), @"dragStarted", @[]]);
    }
}
- (void)dataDragged:(NSEvent*)e at:(NSPoint)p {
    NSWindow* w = self.window;
    const NSPoint win = e.locationInWindow;
    RXDockView* host = fd_host_at(w, win);
    RXNode* t = host ? [host nodeAt:[host convertPoint:win fromView:nil] want:kDropData] : nil;
    dd_hover(t);
    if (t && t.doc.ctx && flag(t, @"wantsDragMoved", false)) {
        const CGPoint q = [host point:[host convertPoint:win fromView:nil] inNode:t];
        doc_call(t.doc, @"emit", @[@(t.uid), @"dragMoved", @[@(q.x), @(q.y)]]);
    }
    NSView* frame = w.contentView.superview ?: w.contentView;
    NSString* text = dd_text(g_dd_source);
    if (!NSPointInRect(win, frame.frame) && text.length) {
        RXNode* source = g_dd_source;
        id picture = g_dd_ghost.contents;
        const CGSize s = g_dd_ghost.bounds.size;
        [g_dd_ghost removeFromSuperlayer];
        g_dd_ghost = nil;
        dd_hover(nil);
        g_dd_source = nil;
        g_dd_external = source;
        NSDraggingItem* item = [[NSDraggingItem alloc] initWithPasteboardWriter:text];
        RXRoot* root = self.rootView;
        const NSPoint d = [root convertPoint:win fromView:nil];
        [item setDraggingFrame:NSMakeRect(d.x - s.width / 2, d.y - s.height / 2, s.width, s.height) contents:picture];
        if (root)
            [root beginDraggingSessionWithItems:@[item] event:e source:(id<NSDraggingSource>)self];
        return;
    }
    if (g_dd_ghost) {
        NSView* cv = w.contentView;
        const CGPoint at = [cv convertPointToLayer:[cv convertPoint:win fromView:nil]];
        const CGSize s = g_dd_ghost.bounds.size;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        g_dd_ghost.position =
            CGPointMake(at.x + s.width / 2 + 8, at.y + (cv.isFlipped ? s.height / 2 + 8 : -s.height / 2 - 8));
        [CATransaction commit];
    }
}
- (void)dataDropped:(NSEvent*)e {
    NSWindow* w = self.window;
    const NSPoint win = e.locationInWindow;
    RXNode *t = g_dd_target, *source = g_dd_source;
    bool accepted = false;
    if (t && t.doc.ctx) {
        RXDockView* host = dock_host_of(t);
        const CGPoint q = [host point:[host convertPoint:win fromView:nil] inNode:t];
        doc_call(t.doc, @"emit",
                 @[@(t.uid), @"drop", @[dd_data(source) ?: dd_text(source), dd_key(source), @(q.x), @(q.y)]]);
        accepted = true;
    } else if (dd_text(source).length && !fd_host_at(w, win)) {
        if (NSString* block = panes_block_at(w, win)) {
            agent_send(g_session_id, block, dd_text(source), false, false);
            accepted = true;
        }
    }
    dd_finish(accepted);
}
- (void)draggingSession:(NSDraggingSession*)s endedAtPoint:(NSPoint)p operation:(NSDragOperation)op {
    RXNode* source = g_dd_external;
    g_dd_external = nil;
    if (source.doc.ctx) {
        doc_call(source.doc, @"update", @[@(source.uid), @{@"dragActive": @NO}]);
        doc_call(source.doc, @"emit", @[@(source.uid), @"dragEnded", @[@(op != NSDragOperationNone)]]);
    }
}
@end

RXNode* node_at_window_point(RXDockView* host, NSPoint p) {
    return [host nodeAt:[host convertPoint:p fromView:nil] want:kClick];
}

void host_pointer(RXDockView* host, NSPoint in_window) {
    [host pointer:[host convertPoint:in_window fromView:nil]];
}

static RXLayerHost* any_host_under(NSWindow* w, NSPoint win) {
    return [root_of(w) hostAt:win] ?: pane_host_at(w, win);
}
static RXDockView* host_under(NSWindow* w, NSPoint win) {
    RXLayerHost* h = any_host_under(w, win);
    return [h isKindOfClass:RXDockView.class] ? (RXDockView*)h : nil;
}

@interface RXPointerFeed : NSObject
@end
@implementation RXPointerFeed
- (void)mouseMoved:(NSEvent*)e {
}
- (void)mouseEntered:(NSEvent*)e {
}
- (void)mouseExited:(NSEvent*)e {
}
@end

void ui_pointer_feed(NSView* chrome) {
    static RXPointerFeed* feed = [RXPointerFeed new];
    static NSMapTable<NSView*, NSTrackingArea*>* fed = [NSMapTable weakToStrongObjectsMapTable];
    if (!chrome || [chrome.trackingAreas containsObject:[fed objectForKey:chrome]])
        return;
    NSTrackingArea* a = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited
                                                     | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                       owner:feed
                                                    userInfo:nil];
    [chrome addTrackingArea:a];
    [fed setObject:a forKey:chrome];
}

void ui_pointer_event(NSEvent* e) {
    NSEventType t = e.type;
    if (t != NSEventTypeMouseMoved && t != NSEventTypeMouseExited)
        return;
    NSWindow* w = e.window;
    if (w)
        shaders_pointer(w, e.locationInWindow,
                        t == NSEventTypeMouseExited && !NSPointInRect(e.locationInWindow, w.contentView.bounds));
    if (!w || !g_hosts.count)
        return;
    RX_INTERVAL(pointer, "route");
    NSPoint win = e.locationInWindow;
    bool out = t == NSEventTypeMouseExited && !NSPointInRect(win, w.contentView.bounds);
    RXLayerHost* any = out ? nil : any_host_under(w, win);
    RXDockView* h = [any isKindOfClass:RXDockView.class] ? (RXDockView*)any : nil;
    RXDockView* was = g_pointer_host;
    if (was && was != h)
        [was pointerLeft:[was convertPoint:win fromView:nil]];
    if (h && h != was)
        [h pointerEntered];
    g_pointer_host = h;
    if (h && t == NSEventTypeMouseMoved)
        [h pointer:[h convertPoint:win fromView:nil]];
    else if (any && !h && t == NSEventTypeMouseMoved)
        use_cursor(NSCursor.arrowCursor);
}

bool ui_host_under_pointer(void) {
    NSPoint at = NSEvent.mouseLocation;
    NSWindow* w = [NSApp windowWithWindowNumber:[NSWindow windowNumberAtPoint:at belowWindowWithWindowNumber:0]];
    if (!w)
        return false;
    id top = ui_top_at(w, [w convertPointFromScreen:at]);
    return top && ![top isKindOfClass:NSView.class];
}

void ui_pointer_again(NSWindow* w, NSPoint win) {
    NSEvent* e = [NSEvent mouseEventWithType:NSEventTypeMouseMoved
                                    location:win
                               modifierFlags:0
                                   timestamp:NSProcessInfo.processInfo.systemUptime
                                windowNumber:w.windowNumber
                                     context:nil
                                 eventNumber:0
                                  clickCount:0
                                    pressure:0];
    ui_pointer_event(e);
    drawer_pointer(e);
    if (ui_top_at(w, win))
        return;
    NSView* frame = w.contentView.superview ?: w.contentView;
    NSView* under = [frame hitTest:frame.superview ? [frame.superview convertPoint:win fromView:nil] : win];
    NSEvent* update = [NSEvent enterExitEventWithType:NSEventTypeCursorUpdate
                                             location:win
                                        modifierFlags:0
                                            timestamp:e.timestamp
                                         windowNumber:w.windowNumber
                                              context:nil
                                          eventNumber:0
                                       trackingNumber:0
                                             userData:nullptr];
    [under cursorUpdate:update];
}

void ui_pointer_refresh(void) {
    static bool queued;
    if (queued || !g_hosts.count)
        return;
    queued = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        queued = false;
        if (NSEvent.pressedMouseButtons)
            return;
        NSPoint at = NSEvent.mouseLocation;
        NSWindow* w = [NSApp windowWithWindowNumber:[NSWindow windowNumberAtPoint:at belowWindowWithWindowNumber:0]];
        if (!w || !root_of(w) || (panes_full_in(w) && !panes_ui_over()))
            return;
        ui_pointer_again(w, [w convertPointFromScreen:at]);
    });
}

static id press_host(id v, NSPoint win) {
    if ([v isKindOfClass:RXClip.class])
        v = [v superview];
    if ([v isKindOfClass:RXCarrier.class])
        return ((RXCarrier*)v).host;
    if ([v isKindOfClass:RXRoot.class])
        return [(RXRoot*)v hostAt:win];
    return [v isKindOfClass:RXLayerHost.class] ? v : nil;
}

static NSView* covering(NSView* v, NSPoint win) {
    for (; v.superview; v = v.superview) {
        NSView* sup = v.superview;
        NSArray<NSView*>* subs = sup.subviews;
        NSUInteger i = [subs indexOfObjectIdenticalTo:v];
        if (i == NSNotFound)
            return nil;
        NSPoint p = [sup convertPoint:win fromView:nil];
        for (NSUInteger j = i + 1; j < subs.count; j++) {
            NSView* s = subs[j];
            if (s.hidden)
                continue;
            if (NSView* hit = [s hitTest:p])
                return hit;
        }
    }
    return nil;
}

static id press_target(NSWindow* w, NSPoint win) {
    NSView* frame = w.contentView.superview ?: w.contentView;
    NSRect b = frame.bounds;
    CGFloat dx = MIN(win.x - NSMinX(b), NSMaxX(b) - win.x), dy = MIN(win.y - NSMinY(b), NSMaxY(b) - win.y);
    if (dx < 8 || dy < 8 || (dx < 24 && dy < 24))
        return press_host([frame hitTest:win], win);
    RXRoot* root = root_of(w);
    if (!root || root.hidden)
        return nil;
    if (NSView* c = covering(root, win))
        return press_host(c, win);
    return press_host([root topAt:win owner:nil], win);
}

static NSArray<NSDictionary*>* press_menu(id t, NSEvent* e) {
    if (![t isKindOfClass:RXDockView.class])
        return float_bar_menu(t, e.locationInWindow);
    RXSlot* slot = ((RXDockView*)t).slot;
    NSPoint p = [t convertPoint:e.locationInWindow fromView:nil];
    return slot.bar.layer.superlayer == [t layer] && NSPointInRect(p, slot.bar.frame) ? bar_menu(slot.bar, p) : nil;
}

static __weak id g_press_w[3];
static id press_get(int b) {
    return g_press_w[b];
}
static void press_set(int b, id t) {
    g_press_w[b] = t;
}
static bool g_pressed[3];
static __weak id g_wheel;
static __weak NSWindow* g_wheel_window;
static int g_wheel_latch;

static bool wheel_event(NSEvent* e) {
    NSWindow* w = e.window;
    bool gesture = e.phase != NSEventPhaseNone || e.momentumPhase != NSEventPhaseNone;
    bool begins = e.phase & (NSEventPhaseBegan | NSEventPhaseMayBegin);
    if (!gesture || begins || !g_wheel_latch || g_wheel_window != w) {
        id t = w ? press_target(w, e.locationInWindow) : nil;
        g_wheel = t;
        g_wheel_window = w;
        g_wheel_latch = t ? 1 : 2;
    }
    if (g_wheel_latch == 2)
        return false;
    id held = g_wheel;
    [held scrollWheel:e];
    return true;
}

static ClickCounter g_clicks;
static double g_clicks_seen = -1;
int ui_clicks(NSEvent* e) {
    NSEventType t = e.type;
    bool down = t == NSEventTypeLeftMouseDown || t == NSEventTypeRightMouseDown || t == NSEventTypeOtherMouseDown;
    bool up = t == NSEventTypeLeftMouseUp || t == NSEventTypeRightMouseUp || t == NSEventTypeOtherMouseUp;
    if (!down && !up)
        return 0;
    bool left = t == NSEventTypeLeftMouseDown || t == NSEventTypeLeftMouseUp,
         right = t == NSEventTypeRightMouseDown || t == NSEventTypeRightMouseUp;
    int b = left ? 0 : right ? 1 : MAX(2, (int)e.buttonNumber);
    if (up)
        return g_clicks.release(b);
    if (e.timestamp == g_clicks_seen && b == g_clicks.button)
        return g_clicks.count;
    g_clicks_seen = e.timestamp;
    NSWindow* w = e.window;
    NSPoint p = w ? [w convertPointToScreen:e.locationInWindow] : e.locationInWindow;
    return g_clicks.press(b, e.timestamp, p.x, p.y, NSEvent.doubleClickInterval);
}

bool ui_press_event(NSEvent* e) {
    int b;
    enum { kDown, kDrag, kUp } phase;
    switch (e.type) {
    case NSEventTypeScrollWheel:
        return wheel_event(e);
    case NSEventTypeLeftMouseDown:
        b = 0, phase = kDown;
        break;
    case NSEventTypeRightMouseDown:
        b = 1, phase = kDown;
        break;
    case NSEventTypeOtherMouseDown:
        b = 2, phase = kDown;
        break;
    case NSEventTypeLeftMouseDragged:
        b = 0, phase = kDrag;
        break;
    case NSEventTypeRightMouseDragged:
        b = 1, phase = kDrag;
        break;
    case NSEventTypeOtherMouseDragged:
        b = 2, phase = kDrag;
        break;
    case NSEventTypeLeftMouseUp:
        b = 0, phase = kUp;
        break;
    case NSEventTypeRightMouseUp:
        b = 1, phase = kUp;
        break;
    case NSEventTypeOtherMouseUp:
        b = 2, phase = kUp;
        break;
    default:
        return false;
    }
    if (phase != kDown) {
        if (!g_pressed[b])
            return false;
        id t = press_get(b);
        if (phase == kUp)
            g_pressed[b] = false, press_set(b, nil);
        if (!t)
            return true;
        switch (e.type) {
        case NSEventTypeLeftMouseDragged:
            [t mouseDragged:e];
            break;
        case NSEventTypeRightMouseDragged:
            [t rightMouseDragged:e];
            break;
        case NSEventTypeOtherMouseDragged:
            [t otherMouseDragged:e];
            break;
        case NSEventTypeLeftMouseUp:
            [t mouseUp:e];
            break;
        case NSEventTypeRightMouseUp:
            [t rightMouseUp:e];
            break;
        default:
            [t otherMouseUp:e];
            break;
        }
        return true;
    }
    g_pressed[b] = false, press_set(b, nil);
    NSWindow* w = e.window;
    if (!w)
        return false;
    RX_INTERVAL(pointer, "press");
    if (b == 0 && !(e.modifierFlags & NSEventModifierFlagShift))
        text_select_clear();
    id t = press_target(w, e.locationInWindow);
    if (!t)
        return false;
    bool ctrl = b == 0 && (e.modifierFlags & NSEventModifierFlagControl);
    if (b == 1 || ctrl) {
        if (NSArray<NSDictionary*>* items = press_menu(t, e)) {
            if (id m = menu_open(w, items, e.locationInWindow))
                press_set(b, m), g_pressed[b] = true;
            return true;
        }
    }
    if (b == 0 && !(NSApp.isActive && w.isKeyWindow))
        return false;
    press_set(b, t), g_pressed[b] = true;
    if (b == 0)
        [t mouseDown:e];
    else if (b == 1)
        [t rightMouseDown:e];
    else
        [t otherMouseDown:e];
    return true;
}

extern "C" id rexui_press_target(NSWindow* w, NSPoint win) {
    return w ? press_target(w, win) : nil;
}

extern "C" const char* rexui_host_at(double x, double y) {
    static std::string out;
    NSWindow* w = ui_dock_window();
    RXLayerHost* h = w ? any_host_under(w, NSMakePoint(x, y)) : nil;
    RXDockView* d = [h isKindOfClass:RXDockView.class] ? (RXDockView*)h : nil;
    RXNode* n = d.node;
    NSString* name = n.doc.path.lastPathComponent ?: (d.slot ? @"a slot" : NSStringFromClass(h.class));
    out = h ? std::string(name.UTF8String) + " z " + std::to_string((int)h.layer.superlayer.zPosition) : "";
    return out.c_str();
}
