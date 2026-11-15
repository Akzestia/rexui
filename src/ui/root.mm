// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include <objc/runtime.h>

static bool is_model(CALayer* l) {
    return l.modelLayer == l;
}

static bool carried_key(NSString* k) {
    return [k hasPrefix:@"transform"] || [k isEqualToString:@"opacity"] || [k isEqualToString:@"hidden"];
}
static bool carried(CAAnimation* a) {
    if ([a isKindOfClass:CAAnimationGroup.class]) {
        for (CAAnimation* x in ((CAAnimationGroup*)a).animations)
            if (!carried(x))
                return false;
        return true;
    }
    return [a isKindOfClass:CAPropertyAnimation.class] && carried_key(((CAPropertyAnimation*)a).keyPath);
}

@implementation RXTwinShape
- (CAShapeLayer*)twin {
    if (!_twin) {
        _twin = [CAShapeLayer layer];
        _twin.actions = @{
            @"path": NSNull.null,
            @"bounds": NSNull.null,
            @"position": NSNull.null,
            @"transform": NSNull.null,
            @"hidden": NSNull.null,
            @"anchorPoint": NSNull.null
        };
        _twin.anchorPoint = self.anchorPoint;
        _twin.bounds = self.bounds;
        _twin.position = self.position;
        _twin.transform = self.transform;
        _twin.path = self.path;
        _twin.fillColor = self.fillColor;
        _twin.fillRule = self.fillRule;
        for (NSString* k in self.animationKeys)
            [_twin addAnimation:[self animationForKey:k] forKey:k];
    }
    return _twin;
}
- (void)setPath:(CGPathRef)p {
    [super setPath:p];
    if (is_model(self))
        _twin.path = p;
}
- (void)setBounds:(CGRect)b {
    [super setBounds:b];
    if (is_model(self))
        _twin.bounds = b;
}
- (void)setPosition:(CGPoint)p {
    [super setPosition:p];
    if (is_model(self))
        _twin.position = p;
}
- (void)setAnchorPoint:(CGPoint)a {
    [super setAnchorPoint:a];
    if (is_model(self))
        _twin.anchorPoint = a;
}
- (void)setTransform:(CATransform3D)t {
    [super setTransform:t];
    if (is_model(self))
        _twin.transform = t;
}
- (void)setAffineTransform:(CGAffineTransform)t {
    self.transform = CATransform3DMakeAffineTransform(t);
}
- (void)setFrame:(CGRect)f {
    [super setFrame:f];
    if (is_model(self))
        _twin.bounds = self.bounds, _twin.position = self.position;
}
- (void)setHidden:(BOOL)h {
    [super setHidden:h];
    if (is_model(self))
        _twin.hidden = h;
}
- (void)addAnimation:(CAAnimation*)a forKey:(NSString*)k {
    [super addAnimation:a forKey:k];
    if (is_model(self))
        [_twin addAnimation:a forKey:k];
}
- (void)removeAnimationForKey:(NSString*)k {
    [super removeAnimationForKey:k];
    if (is_model(self))
        [_twin removeAnimationForKey:k];
}
- (void)removeAllAnimations {
    [super removeAllAnimations];
    if (is_model(self))
        [_twin removeAllAnimations];
}
@end

@interface RXHostLayer : RXLayer
@property(nonatomic, weak) NSView* twin;
@end
@implementation RXHostLayer
- (void)setTransform:(CATransform3D)t {
    [super setTransform:t];
    if (NSView* v = is_model(self) ? _twin : nil)
        v.layer.transform = t;
}
- (void)setAffineTransform:(CGAffineTransform)t {
    self.transform = CATransform3DMakeAffineTransform(t);
}
- (void)setOpacity:(float)o {
    const bool was_clear = self.opacity <= 0;
    [super setOpacity:o];
    if (!is_model(self))
        return;
    if (NSView* v = _twin)
        v.layer.opacity = o;
    if (was_clear && o > 0 && !self.hidden)
        shaders_shown(self);
}
- (void)setHidden:(BOOL)h {
    const bool was = self.hidden;
    [super setHidden:h];
    if (!is_model(self))
        return;
    if (NSView* v = _twin) {
        if (v.hidden != h)
            v.hidden = h;
    }
    if (was && !h && self.opacity > 0)
        shaders_shown(self);
}
- (void)setMask:(CALayer*)m {
    [super setMask:m];
    if (NSView* v = is_model(self) ? _twin : nil)
        v.layer.mask = [m isKindOfClass:RXTwinShape.class] ? ((RXTwinShape*)m).twin : nil;
}
- (void)addAnimation:(CAAnimation*)a forKey:(NSString*)k {
    [super addAnimation:a forKey:k];
    if (NSView* v = is_model(self) ? _twin : nil) {
        if (carried(a))
            [v.layer addAnimation:a forKey:k];
    }
}
- (void)removeAnimationForKey:(NSString*)k {
    [super removeAnimationForKey:k];
    if (NSView* v = is_model(self) ? _twin : nil)
        [v.layer removeAnimationForKey:k];
}
- (void)removeAllAnimations {
    [super removeAllAnimations];
    if (NSView* v = is_model(self) ? _twin : nil) {
        for (NSString* k in v.layer.animationKeys)
            [v.layer removeAnimationForKey:k];
    }
}
- (void)handTo:(NSView*)v {
    v.hidden = self.hidden;
    v.layer.opacity = self.opacity;
    v.layer.transform = self.transform;
    v.layer.mask = [self.mask isKindOfClass:RXTwinShape.class] ? ((RXTwinShape*)self.mask).twin : nil;
    for (NSString* k in self.animationKeys) {
        CAAnimation* a = [self animationForKey:k];
        if (carried(a))
            [v.layer addAnimation:a forKey:k];
    }
}
@end

@interface RXLayerHost ()
- (void)movedToWindow;
@end

@interface RXCarrier () {
    __weak RXLayerHost* _w_host;
}
@end
@implementation RXCarrier
- (RXLayerHost*)host {
    return _w_host;
}
- (void)setHost:(RXLayerHost*)v {
    _w_host = v;
}
- (BOOL)isFlipped {
    return YES;
}
- (NSView*)hitTest:(NSPoint)p {
    NSView* hit = [super hitTest:p];
    return hit == self ? nil : hit;
}
- (void)layout {
}
- (void)cursorUpdate:(NSEvent*)e {
}
@end

@implementation RXLayerHost {
    NSMutableArray<RXLayerHost*>* _subhosts;
    __weak id _superview;
    RXCarrier* _carrier;
}

- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super init]))
        return nil;
    _layer = [RXHostLayer layer];
    _layer.anchorPoint = CGPointZero;
    _subhosts = [NSMutableArray array];
    self.frame = f;
    return self;
}

- (NSRect)frame {
    CGRect b = _layer.bounds;
    return NSMakeRect(_layer.position.x, _layer.position.y, b.size.width, b.size.height);
}
- (void)setFrame:(NSRect)f {
    CGRect b = CGRectMake(0, 0, f.size.width, f.size.height);
    if (!CGRectEqualToRect(_layer.bounds, b))
        _layer.bounds = b;
    if (!CGPointEqualToPoint(_layer.position, f.origin))
        _layer.position = f.origin;
    if (_carrier && !NSEqualRects(_carrier.frame, f))
        _carrier.frame = f;
}
- (NSRect)bounds {
    return NSMakeRect(0, 0, _layer.bounds.size.width, _layer.bounds.size.height);
}
- (NSRect)visibleRect {
    return self.bounds;
}
- (BOOL)isFlipped {
    return YES;
}

- (BOOL)isHidden {
    return _layer.hidden;
}
- (void)setHidden:(BOOL)h {
    if (_layer.hidden == h)
        return;
    _layer.hidden = h;
    [self tellHidden:h];
    ui_pointer_refresh();
}
- (void)tellHidden:(BOOL)h {
    if (h)
        [self viewDidHide];
    else
        [self viewDidUnhide];
    for (RXLayerHost* c in _subhosts)
        if (!c.layer.hidden)
            [c tellHidden:h];
}
- (CGFloat)alphaValue {
    return _layer.opacity;
}
- (void)setAlphaValue:(CGFloat)a {
    if (_layer.opacity != (float)a)
        _layer.opacity = (float)a;
}
- (BOOL)isHiddenOrHasHiddenAncestor {
    for (RXLayerHost* h = self; h; h = [h.superview isKindOfClass:RXLayerHost.class] ? h.superview : nil) {
        if (h.layer.hidden)
            return YES;
        if ([h.superview isKindOfClass:NSView.class])
            return [(NSView*)h.superview isHiddenOrHasHiddenAncestor];
    }
    return NO;
}

- (id)superview {
    return _superview;
}
- (NSArray<RXLayerHost*>*)subhosts {
    return _subhosts;
}
- (RXRoot*)rootView {
    id v = _superview;
    while ([v isKindOfClass:RXLayerHost.class])
        v = [v superview];
    return [v isKindOfClass:RXRoot.class] ? v : nil;
}
- (NSWindow*)window {
    return self.rootView.window;
}

- (NSView*)carrier {
    if (!_carrier) {
        if (!self.rootView)
            return nil;
        _carrier = [[RXCarrier alloc] initWithFrame:self.frame];
        _carrier.wantsLayer = YES;
        _carrier.host = self;
        ((RXHostLayer*)_layer).twin = _carrier;
        [(RXHostLayer*)_layer handTo:_carrier];
    }
    [self homeCarrier];
    return _carrier;
}
- (void)homeCarrier {
    if (!_carrier)
        return;
    id p = _superview;
    NSView* in = [p isKindOfClass:RXLayerHost.class] ? [(RXLayerHost*)p carrier]
        : [p isKindOfClass:RXRoot.class]             ? p
                                                     : nil;
    if (!in) {
        [_carrier removeFromSuperview];
        return;
    }
    if (_carrier.superview != in)
        [in addSubview:_carrier];
    if (!NSEqualRects(_carrier.frame, self.frame))
        _carrier.frame = self.frame;
    if (in == p) {
        CGFloat z = [(RXRoot*)p bandOf:self] + 0.5;
        if (_carrier.layer.zPosition != z)
            _carrier.layer.zPosition = z;
    }
}
- (BOOL)hasCarrier {
    return _carrier != nil;
}

- (void)attachTo:(id)parent {
    bool had = self.window != nil;
    _superview = parent;
    self.nextResponder = [parent isKindOfClass:RXLayerHost.class] ? parent : nil;
    [self homeCarrier];
    if (!had && self.window)
        [self movedToWindow];
}
- (void)movedToWindow {
    [self viewDidMoveToWindow];
    for (RXLayerHost* c in _subhosts)
        [c movedToWindow];
}
- (void)detach {
    id p = _superview;
    if (!p)
        return;
    if ([p isKindOfClass:RXLayerHost.class])
        [((RXLayerHost*)p)->_subhosts removeObjectIdenticalTo:self];
    else if ([p isKindOfClass:RXRoot.class])
        [(RXRoot*)p forgetHost:self];
    [_layer removeFromSuperlayer];
    _superview = nil;
    self.nextResponder = nil;
}
- (void)addSubhost:(RXLayerHost*)h {
    if (h.superview == self)
        return;
    [h detach];
    [_subhosts addObject:h];
    [_layer addSublayer:h.layer];
    [h attachTo:self];
}
- (void)removeFromSuperview {
    [self detach];
    [_carrier removeFromSuperview];
}
- (BOOL)isDescendantOf:(id)v {
    for (id x = self; x; x = [x isKindOfClass:RXLayerHost.class] ? [x superview] : [(NSView*)x superview])
        if (x == v)
            return YES;
    return NO;
}

- (NSPoint)windowPoint:(NSPoint)p {
    RXRoot* r = self.rootView;
    if (!r)
        return p;
    CGPoint q = [_layer convertPoint:p toLayer:r.layer];
    return [r convertPoint:NSPointFromCGPoint(q) toView:nil];
}
- (NSPoint)pointFromWindow:(NSPoint)win {
    RXRoot* r = self.rootView;
    if (!r)
        return win;
    NSPoint q = [r convertPoint:win fromView:nil];
    return NSPointFromCGPoint([_layer convertPoint:q fromLayer:r.layer]);
}
- (NSPoint)convertPoint:(NSPoint)p fromView:(id)v {
    NSPoint win = !v                          ? p
        : [v isKindOfClass:RXLayerHost.class] ? [(RXLayerHost*)v windowPoint:p]
                                              : [(NSView*)v convertPoint:p toView:nil];
    return [self pointFromWindow:win];
}
- (NSPoint)convertPoint:(NSPoint)p toView:(id)v {
    NSPoint win = [self windowPoint:p];
    return !v                                 ? win
        : [v isKindOfClass:RXLayerHost.class] ? [(RXLayerHost*)v pointFromWindow:win]
                                              : [(NSView*)v convertPoint:win fromView:nil];
}
- (NSRect)convertRect:(NSRect)r fromView:(id)v {
    NSPoint a = [self convertPoint:r.origin fromView:v],
            b = [self convertPoint:NSMakePoint(NSMaxX(r), NSMaxY(r)) fromView:v];
    return NSMakeRect(MIN(a.x, b.x), MIN(a.y, b.y), fabs(b.x - a.x), fabs(b.y - a.y));
}
- (NSRect)convertRect:(NSRect)r toView:(id)v {
    NSPoint a = [self convertPoint:r.origin toView:v],
            b = [self convertPoint:NSMakePoint(NSMaxX(r), NSMaxY(r)) toView:v];
    return NSMakeRect(MIN(a.x, b.x), MIN(a.y, b.y), fabs(b.x - a.x), fabs(b.y - a.y));
}
- (NSPoint)convertPointToLayer:(NSPoint)p {
    return p;
}
- (NSPoint)convertPointFromLayer:(NSPoint)p {
    return p;
}
- (NSRect)convertRectToLayer:(NSRect)r {
    return r;
}
- (NSRect)convertRectFromLayer:(NSRect)r {
    return r;
}

- (id)hitTest:(NSPoint)p {
    if (_layer.hidden)
        return nil;
    NSRect f = self.frame;
    NSPoint q = NSMakePoint(p.x - f.origin.x, p.y - f.origin.y);
    if (!NSPointInRect(q, self.bounds))
        return nil;
    for (NSUInteger i = _subhosts.count; i-- > 0;) {
        if (id hit = [_subhosts[i] hitTest:q])
            return hit;
    }
    return self;
}

- (void)viewDidMoveToWindow {
}
- (void)viewDidHide {
}
- (void)viewDidUnhide {
}
- (BOOL)acceptsFirstResponder {
    return NO;
}
@end

@interface RXRoot () {
    __weak RXNode* _w_focus;
}
@end
@implementation RXRoot {
    NSMutableArray<RXLayerHost*>* _hosts;
    NSMutableDictionary<NSNumber*, CALayer*>* _bands;
    __weak id _grab;
    bool _covered;
    NSUInteger _views;
}
- (void)didAddSubview:(NSView*)v {
    [super didAddSubview:v];
    _views++;
}
- (void)willRemoveSubview:(NSView*)v {
    [super willRemoveSubview:v];
    if (_views)
        _views--;
}
- (RXNode*)focus {
    return _w_focus;
}
- (void)setFocus:(RXNode*)v {
    _w_focus = v;
}
- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f]))
        return nil;
    _hosts = [NSMutableArray array];
    _bands = [NSMutableDictionary dictionary];
    return self;
}
- (BOOL)isFlipped {
    return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent*)e {
    return YES;
}
- (BOOL)mouseDownCanMoveWindow {
    return NO;
}
- (void)layout {
}
- (void)resizeSubviewsWithOldSize:(NSSize)old {
}
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window)
        for (RXLayerHost* h in [_hosts copy])
            [h movedToWindow];
}

- (CALayer*)band:(int)z {
    CALayer* b = _bands[@(z)];
    if (!b) {
        b = [RXLayer layer];
        b.zPosition = z;
        b.anchorPoint = CGPointZero;
        _bands[@(z)] = b;
    }
    if (b.superlayer != self.layer)
        [self.layer addSublayer:b];
    CGRect r = CGRectMake(0, 0, self.bounds.size.width, self.bounds.size.height);
    if (!CGRectEqualToRect(b.bounds, r))
        b.bounds = r;
    return b;
}
- (void)addHost:(RXLayerHost*)h band:(int)z {
    CALayer* b = [self band:z];
    if (h.superview == self && h.layer.superlayer == b)
        return;
    [h detach];
    [_hosts addObject:h];
    [b addSublayer:h.layer];
    [h attachTo:self];
}
- (void)forgetHost:(RXLayerHost*)h {
    [_hosts removeObjectIdenticalTo:h];
}
- (int)bandOf:(RXLayerHost*)h {
    while ([h.superview isKindOfClass:RXLayerHost.class])
        h = h.superview;
    return (int)h.layer.superlayer.zPosition;
}

static constexpr int kFullBand = -15;
static bool under_full(int z) {
    return z < kFullBand || z == kBandFloatBar || z == kBandDocksRaised;
}
static void band_hidden(CALayer* band, bool h) {
    const bool was = band.hidden;
    band.hidden = h;
    if (was && !h)
        shaders_shown(band);
}
- (CALayer*)cover:(bool)on {
    _covered = on;
    for (NSNumber* z in _bands) {
        if (under_full(z.intValue))
            band_hidden(_bands[z], on);
    }
    return on ? [self band:kFullBand] : nil;
}
- (bool)coversBand:(int)z {
    return _covered && under_full(z);
}
- (void)revealCovered:(bool)on {
    if (!_covered)
        return;
    for (NSNumber* z in _bands) {
        if (under_full(z.intValue))
            band_hidden(_bands[z], !on);
    }
}

- (id)topAt:(NSPoint)win owner:(RXLayerHost**)owner {
    if (owner)
        *owner = nil;
    NSPoint p = [self convertPoint:win fromView:nil];
    id best = nil;
    CGFloat best_z = -INFINITY;
    for (NSUInteger i = _hosts.count; i-- > 0;) {
        RXLayerHost* h = _hosts[i];
        CGFloat z = h.layer.superlayer.zPosition;
        if ((best && z <= best_z) || (_covered && [self coversBand:(int)floor(z)]))
            continue;
        if (id hit = [h hitTest:p])
            best = hit, best_z = z;
    }
    if (_views) {
        NSArray<NSView*>* subs = self.subviews;
        for (NSUInteger i = subs.count; i-- > 0;) {
            NSView* s = subs[i];
            CGFloat z = s.layer.zPosition;
            if (s.hidden || (best && z <= best_z) || (_covered && [self coversBand:(int)floor(z)]))
                continue;
            if (NSView* hit = [s hitTest:p])
                best = hit, best_z = z;
        }
    }
    if (owner && best) {
        if ([best isKindOfClass:RXLayerHost.class])
            *owner = best;
        else
            for (NSView* v = best; v && v != self; v = v.superview)
                if ([v isKindOfClass:RXCarrier.class]) {
                    *owner = ((RXCarrier*)v).host;
                    break;
                }
    }
    return best;
}
- (RXLayerHost*)hostAt:(NSPoint)win {
    RXLayerHost* o = nil;
    [self topAt:win owner:&o];
    return o;
}

- (NSView*)hitTest:(NSPoint)p {
    if (self.hidden)
        return nil;
    id top = [self topAt:[self.superview convertPoint:p toView:nil] owner:nil];
    return [top isKindOfClass:NSView.class] ? top : top ? self : nil;
}
- (void)cursorUpdate:(NSEvent*)e {
    static bool passing;
    if (passing)
        return;
    NSView* frame = self.window.contentView.superview ?: self.window.contentView;
    NSView* under = [frame hitTest:e.locationInWindow];
    if (!under || under == self)
        return;
    passing = true;
    [under cursorUpdate:e];
    passing = false;
}
- (void)mouseDown:(NSEvent*)e {
    id at = [self hostAt:e.locationInWindow];
    _grab = at;
    [at mouseDown:e];
}
- (void)mouseDragged:(NSEvent*)e {
    [_grab mouseDragged:e];
}
- (void)mouseUp:(NSEvent*)e {
    id g = _grab;
    _grab = nil;
    [g mouseUp:e];
}
- (void)rightMouseDown:(NSEvent*)e {
    [[self hostAt:e.locationInWindow] rightMouseDown:e];
}
- (void)rightMouseUp:(NSEvent*)e {
}
- (void)otherMouseDown:(NSEvent*)e {
    [self hostAt:e.locationInWindow] ? [[self hostAt:e.locationInWindow] otherMouseDown:e] : [super otherMouseDown:e];
}
- (void)otherMouseUp:(NSEvent*)e {
}
- (void)scrollWheel:(NSEvent*)e {
    [[self hostAt:e.locationInWindow] scrollWheel:e];
}
- (NSMenu*)menuForEvent:(NSEvent*)e {
    return nil;
}
@end

static NSMapTable<NSWindow*, RXRoot*>* g_roots;

RXRoot* ui_root(NSView* chrome) {
    RXRoot* root = nil;
    for (NSView* v in chrome.subviews) {
        if ([v isMemberOfClass:RXRoot.class])
            root = (RXRoot*)v;
    }
    if (!root) {
        root = [[RXRoot alloc] initWithFrame:chrome.bounds];
        root.translatesAutoresizingMaskIntoConstraints = NO;
        root.wantsLayer = YES;
    }
    NSView *top = nil, *cover = ui_loading_cover(chrome);
    for (NSView* v in chrome.subviews.reverseObjectEnumerator) {
        if (v != cover) {
            top = v;
            break;
        }
    }
    if (top != root) {
        [root removeFromSuperview];
        if (cover)
            [chrome addSubview:root positioned:NSWindowBelow relativeTo:cover];
        else
            [chrome addSubview:root positioned:NSWindowAbove relativeTo:nil];
    }
    if (!NSEqualRects(root.frame, chrome.bounds))
        root.frame = chrome.bounds;
    if (!g_roots)
        g_roots = [NSMapTable weakToWeakObjectsMapTable];
    if (NSWindow* w = chrome.window)
        [g_roots setObject:root forKey:w];
    return root;
}

RXRoot* root_of(NSWindow* w) {
    if (!w)
        return nil;
    RXRoot* r = [g_roots objectForKey:w];
    if (r.window == w)
        return r;
    NSView* chrome = chrome_of(w);
    for (NSView* v in chrome.subviews) {
        if ([v isMemberOfClass:RXRoot.class])
            r = (RXRoot*)v;
    }
    if (r)
        [g_roots setObject:r forKey:w];
    return r;
}

static NSHashTable<RXRoot*>* g_pane_roots;

RXRoot* pane_root(RXDoc* doc, bool make) {
    static char key;
    RXRoot* r = objc_getAssociatedObject(doc, &key);
    if (r && make && doc.root.host && doc.root.host.superview != r)
        [r addHost:doc.root.host band:0];
    if (r || !make || !doc.root.host)
        return r;
    r = [[RXRoot alloc] initWithFrame:NSZeroRect];
    r.wantsLayer = YES;
    [r addHost:doc.root.host band:0];
    objc_setAssociatedObject(doc, &key, r, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!g_pane_roots)
        g_pane_roots = [NSHashTable weakObjectsHashTable];
    [g_pane_roots addObject:r];
    return r;
}

static RXRoot* pane_root_at(NSWindow* w, NSPoint win) {
    for (RXRoot* r in g_pane_roots) {
        if (r.window != w || r.hiddenOrHasHiddenAncestor)
            continue;
        if (!NSPointInRect([r convertPoint:win fromView:nil], r.bounds))
            continue;
        NSView* frame = w.contentView.superview ?: w.contentView;
        NSView* hit = [frame hitTest:win];
        if (hit && [hit isDescendantOf:r])
            return r;
    }
    return nil;
}
RXLayerHost* pane_host_at(NSWindow* w, NSPoint win) {
    return [pane_root_at(w, win) hostAt:win];
}
id ui_top_at(NSWindow* w, NSPoint win) {
    return [root_of(w) topAt:win owner:nil] ?: [pane_root_at(w, win) topAt:win owner:nil];
}

CALayer* ui_full_cover(NSWindow* w, bool on) {
    return [root_of(w) cover:on];
}
NSView* ui_full_root(NSWindow* w) {
    return root_of(w);
}
bool node_covered(RXNode* n) {
    RXDockView* h = dock_host_of(n);
    RXRoot* r = h.window ? root_of(h.window) : nil;
    return r && h && [r coversBand:[r bandOf:h]];
}
bool ui_root_takes(NSWindow* w, NSPoint win) {
    return [root_of(w) topAt:win owner:nil] != nil;
}
void ui_full_reveal(NSWindow* w, bool on) {
    [root_of(w) revealCovered:on];
}
