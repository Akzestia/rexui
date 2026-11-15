// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "web/web.h"

#include <cstring>
#include <unordered_map>

CGFloat backing_scale(void) {
    NSWindow* w = dock_window();
    return w.backingScaleFactor ?: NSScreen.mainScreen.backingScaleFactor ?: 2;
}

@interface RXScrollLayer () {
    __weak RXNode* _w_node;
}
@end
static bool natives_in(RXNode* list);

static NSHashTable<RXScrollLayer*>* g_owing;
static void scroll_owes(RXScrollLayer* s) {
    if (!g_owing)
        g_owing = [NSHashTable weakObjectsHashTable];
    [g_owing addObject:s];
}
void scrolls_pay_owed(RXDoc* doc) {
    if (!g_owing.count)
        return;
    for (RXScrollLayer* s in g_owing.allObjects) {
        if (s.node.doc != doc)
            continue;
        [s payOwed];
        if (!s.owedCount)
            [g_owing removeObject:s];
    }
}

@implementation RXScrollLayer {
    CALayer* _knob;
    NSColor* _knob_fg;
    CGFloat _height;
    int _fade;
    double _fade_share;
    RXAnim* _glide;
    bool _ca_glide;
    bool _gliding;
    int _glides;
    std::vector<RXTextLayer*> _owed;
    CGFloat _was;
}
- (RXNode*)node {
    return _w_node;
}
- (void)setNode:(RXNode*)v {
    _w_node = v;
}
- (instancetype)init {
    if (!(self = [super init]))
        return nil;
    self.masksToBounds = YES;
    _doc = [RXLayer layer];
    [self addSublayer:_doc];
    _knob = [RXLayer layer];
    _knob.zPosition = 1;
    _knob.opacity = 0;
    _knob.cornerRadius = 1.5;
    [self addSublayer:_knob];
    return self;
}
- (CGFloat)extent {
    return _horizontal ? self.bounds.size.width : self.bounds.size.height;
}
- (void)setHorizontal:(bool)h {
    if (h == _horizontal)
        return;
    _horizontal = h;
    [self setContentHeight:_height];
}
- (CGFloat)maxOffset {
    return MAX(0, _height - self.extent);
}
- (void)setBase:(CGFloat)b {
    _base = b;
    [self setContentHeight:_height];
}
- (void)setContentHeight:(CGFloat)h {
    _height = h;
    CGRect f = _horizontal
        ? CGRectMake(_base - _offset, 0, MAX(h - _base, self.bounds.size.width), self.bounds.size.height)
        : CGRectMake(0, _base - _offset, self.bounds.size.width, MAX(h - _base, self.bounds.size.height));
    if (!CGRectEqualToRect(_doc.frame, f))
        _doc.frame = f;
    self.offset = _offset;
    [self payOwed];
}
- (void)setBounds:(CGRect)b {
    bool changed = !CGSizeEqualToSize(b.size, self.bounds.size);
    [super setBounds:b];
    if (self.modelLayer != self)
        return;
    if (changed)
        [self setContentHeight:_height];
    [self updateFade];
}
- (bool)shows:(CALayer*)l {
    const CGFloat ext = self.extent;
    if (ext <= 0)
        return false;
    const CGRect r = [l convertRect:l.bounds toLayer:_doc];
    const CGFloat from = _gliding || _ca_glide ? _was : _offset;
    const CGFloat lo = MIN(_offset, from) - _base - ext, hi = MAX(_offset, from) - _base + 2 * ext;
    return _horizontal ? CGRectGetMaxX(r) >= lo && r.origin.x <= hi : CGRectGetMaxY(r) >= lo && r.origin.y <= hi;
}
- (void)owe:(RXTextLayer*)l {
    if (l.owed)
        return;
    l.owed = true;
    _owed.push_back(l);
    scroll_owes(self);
}
- (void)payOwed {
    if (_owed.empty() || self.modelLayer != self)
        return;
    for (size_t i = 0; i < _owed.size();) {
        RXTextLayer* l = _owed[i];
        const bool done = !l.owed || !l.superlayer;
        const bool due = !done && [self shows:l];
        if (!done && !due) {
            i++;
            continue;
        }
        l.owed = false;
        if (due)
            [l setNeedsDisplay];
        _owed[i] = _owed.back();
        _owed.pop_back();
    }
}
- (NSUInteger)owedCount {
    return _owed.size();
}
- (void)setOffset:(CGFloat)y {
    y = round(MAX(0, MIN(y, self.maxOffset)));
    if (y == _offset && (_horizontal ? _doc.frame.origin.x : _doc.frame.origin.y) == _base - y)
        return;
    if (_ca_glide && !_gliding)
        [self stopGlide];
    const bool moved = y != _offset;
    _offset = y;
    CGRect f = _doc.frame;
    if (_horizontal)
        f.origin.x = _base - y;
    else
        f.origin.y = _base - y;
    _doc.frame = f;
    CGFloat h = self.extent;
    if (_height > h && h > 0) {
        CGFloat kh = MAX(20, h * h / _height), ky = (h - kh) * y / self.maxOffset;
        _knob.frame = _horizontal ? CGRectMake(ky + 2, self.bounds.size.height - 5, kh - 4, 3)
                                  : CGRectMake(self.bounds.size.width - 5, ky + 2, 3, kh - 4);
        if (_knob_fg != g_theme.fg)
            _knob_fg = g_theme.fg, _knob.backgroundColor = [g_theme.fg colorWithAlphaComponent:0.3].CGColor;
    }
    [self updateFade];
    if (moved)
        [self payOwed];
    if (RXNode* n = self.node) {
        if (natives_in(n))
            place_natives(n.doc);
        if (is_vlist(n))
            vlist_ask(n);
        if (moved && n.wants_scroll)
            list_scrolled(n, y);
    }
}
- (void)setFade:(double)f {
    _fade_share = MAX(0, MIN(0.5, f));
    [self updateFade];
}
- (double)fade {
    return _fade_share;
}
- (void)updateFade {
    double f = _fade_share;
    CAGradientLayer* mask = [self.mask isKindOfClass:CAGradientLayer.class] ? (CAGradientLayer*)self.mask : nil;
    CGFloat h = self.extent;
    if (f <= 0 || h <= 0) {
        if (mask)
            mask_set_own(self, nil);
        return;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!mask) {
        mask = (CAGradientLayer*)still([CAGradientLayer layer]);
        CGColorRef clear = NSColor.clearColor.CGColor, black = NSColor.blackColor.CGColor;
        mask.colors = @[(__bridge id)clear, (__bridge id)black, (__bridge id)black, (__bridge id)clear];
        mask_set_own(self, mask);
    }
    mask.startPoint = _horizontal ? CGPointMake(0, 0.5) : CGPointMake(0.5, 0);
    mask.endPoint = _horizontal ? CGPointMake(1, 0.5) : CGPointMake(0.5, 1);
    CGFloat span = f * h;
    double top = f * MIN(1.0, _offset / span), bottom = f * MIN(1.0, MAX(0, self.maxOffset - _offset) / span);
    NSArray<NSNumber*>* was = mask.locations;
    if (was.count != 4 || was[1].doubleValue != top || was[2].doubleValue != 1 - bottom)
        mask.locations = @[@0, @(top), @(1 - bottom), @1];
    if (!CGRectEqualToRect(mask.frame, self.bounds))
        mask.frame = self.bounds;
    [CATransaction commit];
}
- (void)reveal:(NSRect)r {
    CGFloat at = _offset, h = self.extent;
    const CGFloat lo = _horizontal ? NSMinX(r) : NSMinY(r), hi = _horizontal ? NSMaxX(r) : NSMaxY(r);
    if (lo < at)
        at = lo;
    else if (hi > at + h)
        at = hi - h;
    self.offset = at;
}
- (CGFloat)shownOffset {
    if (!_ca_glide)
        return _offset;
    CALayer* p = _doc.presentationLayer;
    return p ? _offset -
            [[p valueForKeyPath:_horizontal ? @"transform.translation.x" : @"transform.translation.y"] doubleValue]
             : _offset;
}
- (void)stopGlide {
    if (!_ca_glide)
        return;
    _ca_glide = false;
    [_doc removeAnimationForKey:@"rexui.glide"];
    [self.mask removeAnimationForKey:@"rexui.glide.fade"];
}
static bool natives_in(RXNode* list) {
    for (RXNode* x in list.doc.natives)
        for (__unsafe_unretained RXNode* y = x.parent; y; y = y->up)
            if (y == list)
                return true;
    return false;
}
- (void)glideTo:(CGFloat)y ms:(double)ms {
    [_glide cancel];
    _glide = nil;
    CGFloat shown = [self shownOffset];
    [self stopGlide];
    if (shown != _offset)
        self.offset = shown;
    y = round(MAX(0, MIN(y, self.maxOffset)));
    RXNode* n = self.node;
    if (ms <= 0 || !n || !node_on_screen(n) || y == _offset) {
        self.offset = y;
        return;
    }
    CGFloat from = _offset;
    if (!natives_in(n) && !is_vlist(n)) {
        NSArray* was = [self.mask isKindOfClass:CAGradientLayer.class] ? ((CAGradientLayer*)self.mask).locations : nil;
        _gliding = true;
        _was = from;
        self.offset = y;
        _gliding = false;
        CAMediaTimingFunction* f = [CAMediaTimingFunction functionWithControlPoints:kStandard[0]:kStandard[1
        ]:kStandard[2]:kStandard[3]];
        CABasicAnimation* a = [CABasicAnimation
            animationWithKeyPath:_horizontal ? @"transform.translation.x" : @"transform.translation.y"];
        a.fromValue = @(y - from);
        a.toValue = @0;
        a.duration = ms / 1000;
        a.timingFunction = f;
        [_doc addAnimation:a forKey:@"rexui.glide"];
        if (CAGradientLayer* m = [self.mask isKindOfClass:CAGradientLayer.class] ? (CAGradientLayer*)self.mask : nil;
            m && was && ![was isEqual:m.locations]) {
            CABasicAnimation* b = [CABasicAnimation animationWithKeyPath:@"locations"];
            b.fromValue = was;
            b.toValue = m.locations;
            b.duration = ms / 1000;
            b.timingFunction = f;
            [m addAnimation:b forKey:@"rexui.glide.fade"];
        }
        _ca_glide = true;
        __weak RXScrollLayer* weak = self;
        int gen = ++_glides;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ms * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            RXScrollLayer* l = weak;
            if (l && l->_glides == gen)
                l->_ca_glide = false;
        });
        return;
    }
    __weak RXScrollLayer* weak = self;
    _glide = animate(
        host_of(n), ms,
        ^(double e) {
            weak.offset = from + (y - from) * e;
        },
        nil);
    _glide.curve = kStandard;
}
- (void)showKnob {
    [_knob removeAllAnimations];
    _knob.opacity = 1;
    int fade = ++_fade;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (fade != self->_fade)
            return;
        fade_layer(self->_knob, 0, 300, nil);
    });
}
- (void)scrollWheel:(NSEvent*)e {
    [_glide cancel];
    _glide = nil;
    CGFloat shown = [self shownOffset];
    [self stopGlide];
    const CGFloat raw = _horizontal && e.scrollingDeltaX != 0 ? e.scrollingDeltaX : e.scrollingDeltaY;
    CGFloat d = e.hasPreciseScrollingDeltas ? raw : raw * 12;
    self.offset = shown - d;
    [self showKnob];
}
- (bool)onKnobStrip:(CGPoint)q {
    return self.maxOffset > 0
        && (_horizontal ? q.y >= self.bounds.size.height - 10 : q.x >= self.bounds.size.width - 10);
}
- (void)dragKnob:(CGPoint)q {
    [_glide cancel];
    _glide = nil;
    [self stopGlide];
    const CGFloat h = self.extent, kh = MAX(20, h * h / MAX(h, _height));
    self.offset = MAX(0, MIN(1, ((_horizontal ? q.x : q.y) - kh / 2) / MAX(1, h - kh))) * self.maxOffset;
    [self showKnob];
}
@end

@implementation RXSliderLayer {
    CALayer *_track, *_fill, *_knob;
}
static constexpr CGFloat kKnob = 14, kTrack = 4;
- (instancetype)init {
    if (!(self = [super init]))
        return nil;
    _maxValue = 1;
    _enabled = true;
    _track = [RXLayer layer], _fill = [RXLayer layer], _knob = [RXLayer layer];
    _track.cornerRadius = _fill.cornerRadius = kTrack / 2;
    _knob.cornerRadius = kKnob / 2;
    _knob.shadowOpacity = 0.3, _knob.shadowRadius = 1.5, _knob.shadowOffset = CGSizeMake(0, 0.5);
    for (CALayer* l in @[_track, _fill, _knob])
        [self addSublayer:l];
    return self;
}
- (void)setValue:(double)v {
    _value = v, [self setNeedsLayout];
}
- (void)setMinValue:(double)v {
    _minValue = v, [self setNeedsLayout];
}
- (void)setMaxValue:(double)v {
    _maxValue = v, [self setNeedsLayout];
}
- (void)setEnabled:(bool)on {
    _enabled = on;
    for (CALayer* l in @[_track, _fill, _knob])
        l.opacity = on ? 1 : 0.4;
}
- (CGFloat)fraction {
    double span = _maxValue - _minValue;
    return span > 0 ? MAX(0, MIN(1, (_value - _minValue) / span)) : 0;
}
- (void)layoutSublayers {
    CGRect b = self.bounds;
    CGFloat run = MAX(0, b.size.width - kKnob), x = kKnob / 2 + run * self.fraction, y = round(b.size.height / 2);
    _track.frame = CGRectMake(kKnob / 2, y - kTrack / 2, run, kTrack);
    _fill.frame = CGRectMake(kKnob / 2, y - kTrack / 2, x - kKnob / 2, kTrack);
    _knob.frame = CGRectMake(x - kKnob / 2, y - kKnob / 2, kKnob, kKnob);
    _track.backgroundColor =
        _trackColor ? (__bridge CGColorRef)_trackColor : [g_theme.fg colorWithAlphaComponent:0.18].CGColor;
    _fill.backgroundColor = _fillColor ? (__bridge CGColorRef)_fillColor : NSColor.controlAccentColor.CGColor;
    _knob.backgroundColor = _knobColor ? (__bridge CGColorRef)_knobColor : CGColorGetConstantColor(kCGColorWhite);
}
- (double)valueAt:(CGFloat)x {
    CGFloat run = MAX(1, self.bounds.size.width - kKnob);
    double f = MAX(0, MIN(1, (x - kKnob / 2) / run));
    double v = _minValue + f * (_maxValue - _minValue);
    if (_step > 0)
        v = MAX(_minValue, MIN(_maxValue, _minValue + round((v - _minValue) / _step) * _step));
    return v;
}
@end

namespace {
constexpr uint64_t k_fnv_prime = 1099511628211ull;
uint64_t fnv_name(uint64_t h, NSString* s, bool lower);
}

struct SymbolEntry {
    NSString* name;
    CGFloat size;
    NSFontWeight weight;
    CGColorRef color;
    NSImage* image;
};
static std::unordered_map<uint64_t, SymbolEntry>& symbols_made(void) {
    static auto* made = new std::unordered_map<uint64_t, SymbolEntry>();
    return *made;
}
size_t symbols_kept(void) {
    return symbols_made().size();
}
NSImage* symbol(NSString* name, CGFloat size, NSFontWeight weight, NSColor* color) {
    if (!name.length)
        return nil;
    auto& made = symbols_made();
    CGColorRef cg = color.CGColor;
    uint64_t key = fnv_name(1469598103934665603ull, name, false);
    double nums[2] = {size, weight};
    for (double d : nums) {
        uint64_t bits;
        memcpy(&bits, &d, sizeof bits);
        key = (key ^ bits) * k_fnv_prime;
    }
    if (cg) {
        const size_t k = CGColorGetNumberOfComponents(cg);
        const CGFloat* c = CGColorGetComponents(cg);
        for (size_t i = 0; i < k; i++) {
            uint64_t bits;
            double d = c[i];
            memcpy(&bits, &d, sizeof bits);
            key = (key ^ bits) * k_fnv_prime;
        }
        key = (key ^ (uint64_t)(uintptr_t)CGColorGetColorSpace(cg)) * k_fnv_prime;
    }
    if (auto it = made.find(key); it != made.end()) {
        const SymbolEntry& e = it->second;
        if (e.size == size && e.weight == weight && [e.name isEqualToString:name]
            && (e.color == cg || (e.color && cg && CGColorEqualToColor(e.color, cg))))
            return e.image;
    }
    if (color && !cg)
        return nil;
    NSImage* image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:name];
    if (!image)
        return nil;
    NSImageSymbolConfiguration* cfg = [NSImageSymbolConfiguration configurationWithPointSize:size weight:weight];
    if (color)
        cfg = [cfg
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[color]]];
    image = [image imageWithSymbolConfiguration:cfg];
    if (image) {
        if (made.size() >= 2048) {
            for (auto& [k, e] : made)
                if (e.color)
                    CGColorRelease(e.color);
            made.clear();
        }
        if (auto it = made.find(key); it != made.end() && it->second.color)
            CGColorRelease(it->second.color);
        made[key] = SymbolEntry{[name copy], size, weight, cg ? CGColorRetain(cg) : nullptr, image};
    }
    return image;
}

void put_symbol(CALayer* l, NSImage* image, NSRect box) {
    CGFloat scale = backing_scale();
    l.contents = image ? [image layerContentsForContentsScale:scale] : nil;
    l.contentsScale = scale;
    l.contentsGravity = kCAGravityResize;
    if (!image)
        return;
    NSSize s = image.size;
    NSRect a = image.alignmentRect;
    CGFloat dx = s.width / 2 - NSMidX(a), dy = NSMidY(a) - s.height / 2;
    l.frame =
        CGRectMake(round(NSMidX(box) + dx - s.width / 2), round(NSMidY(box) + dy - s.height / 2), s.width, s.height);
}

@interface RXButtonLayer () {
    __weak RXNode* _w_node;
}
@end
@implementation RXButtonLayer {
    CGFloat _gap;
}
- (RXNode*)node {
    return _w_node;
}
- (void)setNode:(RXNode*)v {
    _w_node = v;
}
- (instancetype)init {
    if (!(self = [super init]))
        return nil;
    _icon = [RXLayer layer];
    _title = [RXTextLayer layer];
    [self addSublayer:_icon];
    [self addSublayer:_title];
    return self;
}
- (NSSize)measure {
    bool titled = _title.text.length > 0, iconed = _iconImage != nil;
    NSSize t = titled ? text_size(_title, CGFLOAT_MAX) : NSZeroSize;
    if (_bezel)
        return NSMakeSize(ceil(t.width - 4) + 24 + (iconed ? _iconSize.width + 4 : 0), 24);
    if (!titled)
        return _iconSize;
    return NSMakeSize(t.width + (iconed ? _iconSize.width + 2 : 0), MAX(t.height, _iconSize.height));
}
- (void)layoutSublayers {
    CGRect b = self.bounds;
    bool titled = _title.text.length > 0, iconed = _iconImage != nil;
    NSSize t = titled ? text_size(_title, CGFLOAT_MAX) : NSZeroSize;
    CGFloat w = (iconed ? _iconSize.width : 0) + (iconed && titled ? (_bezel ? 4 : 2) : 0) + (titled ? t.width : 0);
    CGFloat x = round((b.size.width - w) / 2);
    if (_bezel)
        _bezel.frame = b;
    if (iconed) {
        NSRect box = NSMakeRect(x, round((b.size.height - _iconSize.height) / 2), _iconSize.width, _iconSize.height);
        put_symbol(_icon, _iconImage, box);
        x += _iconSize.width + (titled ? (_bezel ? 4 : 2) : 0);
    }
    _title.hidden = !titled;
    if (titled)
        _title.frame = CGRectMake(x, round((b.size.height - t.height) / 2), MIN(t.width, b.size.width - x), t.height);
    [self placeState];
}
- (void)placeState {
    RXNode* n = self.node;
    if (!_state || !n)
        return;
    CGSize size = self.bounds.size;
    CGFloat side = MIN(size.width, size.height);
    RXNode* under = nil;
    for (RXNode* c in n.parent.children) {
        if (c == n)
            break;
        if (is_elem(c, E::Rectangle) && flag(c, P::visible, true))
            under = c;
    }
    CGRect r = self.bounds;
    CGFloat radius = MIN(10, side / 2);
    if (num(n, P::stateRadius, -1) >= 0) {
        radius = MIN(num(n, P::stateRadius, 0), side / 2);
    } else if (under) {
        if (under.layer.superlayer == self.superlayer && !CGRectIsEmpty(under.layer.frame)) {
            r = [self convertRect:under.layer.bounds fromLayer:under.layer];
            side = MIN(r.size.width, r.size.height);
        }
        radius = MIN(num(under, P::radius, 0), side / 2);
    } else if (str(n, P::icon, @"").length && !str(n, P::text, @"").length) {
        CGFloat d = MAX(size.width, size.height) + 10;
        r = CGRectMake((size.width - d) / 2, (size.height - d) / 2, d, d);
        radius = d / 2;
    }
    _state.frame = r;
    _state.cornerRadius = radius;
    NSString* spec = str(n, P::shape, @"");
    if (!spec.length && under && num(n, P::stateRadius, -1) < 0)
        spec = str(under, P::shape, @"");
    CGPathRef path = spec.length ? box_path(spec, r.size) : NULL;
    if (path) {
        CAShapeLayer* m = [_state.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer*)_state.mask : nil;
        if (!m) {
            m = [CAShapeLayer layer];
            m.actions = @{@"path": NSNull.null, @"bounds": NSNull.null, @"position": NSNull.null};
            _state.mask = m;
        }
        m.frame = CGRectMake(0, 0, r.size.width, r.size.height);
        m.path = path;
        _state.cornerRadius = 0;
        CGPathRelease(path);
    } else if (_state.mask) {
        _state.mask = nil;
    }
}
- (void)refreshState {
    RXNode* n = self.node;
    bool wanted = n && flag(n, P::stateLayer, true) && flag(n, P::enabled, true) && !_bezel;
    float to = !wanted ? 0 : n.pressed ? 0.12 : n.hovered ? 0.08 : 0;
    if (_bezel) {
        _bezel.opacity = flag(n, P::enabled, true) ? 1 : 0.5;
        _bezel.backgroundColor = [g_theme.fg colorWithAlphaComponent:n.pressed ? 0.2 : 0.12].CGColor;
    }
    if (!_state) {
        if (to == 0)
            return;
        _state = [RXLayer layer];
        _state.cornerCurve = kCACornerCurveContinuous;
        _state.opacity = 0;
        [self insertSublayer:_state atIndex:0];
    }
    [self placeState];
    NSString* c = str(n, P::stateColor, @"");
    if (!c.length)
        c = str(n, P::color, @"");
    NSColor* colour = c.length ? parse_color(c) : nil;
    _state.backgroundColor = (colour ?: g_theme.fg).CGColor;
    if (_state.opacity == to)
        return;
    fade_layer(_state, to, n.pressed ? 60 : 150, nil);
}
@end

bool ui_is_dock(NSView* view) {
    return [view isKindOfClass:RXRoot.class];
}

bool ui_owns_layer(CALayer* layer) {
    for (CALayer* l = layer; l; l = l.superlayer) {
        if ([l isKindOfClass:RXLayer.class])
            return true;
        id d = l.delegate;
        if ([d isKindOfClass:NSView.class] && ui_is_dock(d))
            return true;
    }
    return false;
}

static NSFontDescriptorSystemDesign system_design(NSString* family) {
    if ([family isEqualToString:@"serif"])
        return NSFontDescriptorSystemDesignSerif;
    if ([family isEqualToString:@"rounded"])
        return NSFontDescriptorSystemDesignRounded;
    if ([family isEqualToString:@"mono"])
        return NSFontDescriptorSystemDesignMonospaced;
    return nil;
}

static bool font_width(NSString* w, NSFontWidth* width, double* axis) {
    w = w.lowercaseString;
    if ([w isEqualToString:@"compressed"])
        return *width = NSFontWidthCompressed, *axis = 62.5, true;
    if ([w isEqualToString:@"condensed"])
        return *width = NSFontWidthCondensed, *axis = 75, true;
    if ([w isEqualToString:@"expanded"])
        return *width = NSFontWidthExpanded, *axis = 125, true;
    *width = NSFontWidthStandard, *axis = 100;
    return [w isEqualToString:@"standard"];
}

static NSFont* with_axes(NSFont* f, NSDictionary<NSNumber*, NSNumber*>* want) {
    NSArray* axes = (__bridge_transfer NSArray*)CTFontCopyVariationAxes((__bridge CTFontRef)f);
    if (!axes.count)
        return f;
    NSMutableDictionary* set = [NSMutableDictionary dictionary];
    for (NSDictionary* a in axes) {
        NSNumber* tag = a[(__bridge NSString*)kCTFontVariationAxisIdentifierKey];
        NSNumber* v = tag ? want[tag] : nil;
        if (!v)
            continue;
        double lo = [a[(__bridge NSString*)kCTFontVariationAxisMinimumValueKey] doubleValue];
        double hi = [a[(__bridge NSString*)kCTFontVariationAxisMaximumValueKey] doubleValue];
        set[tag] = @(MAX(lo, MIN(hi, v.doubleValue)));
    }
    if (!set.count)
        return f;
    NSFontDescriptor* d =
        [f.fontDescriptor fontDescriptorByAddingAttributes:@{(__bridge NSString*)kCTFontVariationAttribute: set}];
    return [NSFont fontWithDescriptor:d size:f.pointSize] ?: f;
}

static NSFont* family_font(NSString* family, CGFloat size, NSFontWeight weight, double css_weight, NSFontWidth width,
                           double wdth, bool italic) {
    NSArray* members = [NSFontManager.sharedFontManager availableMembersOfFontFamily:family];
    if (!members.count)
        return nil;
    NSFontDescriptor* want = [NSFontDescriptor fontDescriptorWithFontAttributes:@{
        NSFontFamilyAttribute: family,
        NSFontTraitsAttribute: @{
            NSFontWeightTrait: @(weight),
            NSFontWidthTrait: @(width),
            NSFontSymbolicTrait: @(italic ? NSFontDescriptorTraitItalic : 0)
        },
    }];
    NSFontDescriptor* d = [want matchingFontDescriptorWithMandatoryKeys:[NSSet setWithObject:NSFontFamilyAttribute]];
    NSFont* f = d ? [NSFont fontWithDescriptor:d size:size] : nil;
    if (!f)
        f = [NSFont fontWithName:members.firstObject[0] size:size];
    if (!f)
        return nil;
    return with_axes(f, @{@(0x77676874): @(css_weight), @(0x77647468): @(wdth)});
}

namespace {
struct FontEntry {
    NSFont* font;
    double size;
    unsigned flags;
    NSString *wname, *family, *wstr;
};
std::unordered_map<uint64_t, FontEntry> g_fonts;

uint64_t fnv_name(uint64_t h, NSString* s, bool lower) {
    UniChar buf[64];
    NSUInteger len = s.length;
    for (NSUInteger at = 0; at < len;) {
        NSUInteger k = MIN((NSUInteger)64, len - at);
        [s getCharacters:buf range:NSMakeRange(at, k)];
        for (NSUInteger i = 0; i < k; i++) {
            UniChar c = buf[i];
            if (lower && c >= 'A' && c <= 'Z')
                c += 32;
            h = (h ^ c) * k_fnv_prime;
        }
        at += k;
    }
    return (h ^ 0x10000) * k_fnv_prime;
}

bool same_ascii_nocase(NSString* a, NSString* b) {
    NSUInteger len = a.length;
    if (len != b.length)
        return false;
    UniChar x[64], y[64];
    for (NSUInteger at = 0; at < len;) {
        NSUInteger k = MIN((NSUInteger)64, len - at);
        [a getCharacters:x range:NSMakeRange(at, k)];
        [b getCharacters:y range:NSMakeRange(at, k)];
        for (NSUInteger i = 0; i < k; i++) {
            UniChar c = x[i], d = y[i];
            if (c >= 'A' && c <= 'Z')
                c += 32;
            if (d >= 'A' && d <= 'Z')
                d += 32;
            if (c != d)
                return false;
        }
        at += k;
    }
    return true;
}
}

void font_cache_clear(void) {
    g_fonts.clear();
}
size_t fonts_kept(void) {
    return g_fonts.size();
}

NSFont* font_for(RXNode* n) {
    CGFloat size = num(n, P::font_size, 13);
    NSString* wname_given = str(n, P::font_weight, @"");
    bool bold = flag(n, P::font_bold, false), italic = flag(n, P::font_italic, false),
         mono = flag(n, P::font_mono, false);
    bool tabular = flag(n, P::font_tabular, false);
    NSString *family = str(n, P::font_family, @""), *wstr = str(n, P::font_width, @"");
    unsigned flags = (bold ? 1 : 0) | (italic ? 2 : 0) | (mono ? 4 : 0) | (tabular ? 8 : 0);
    double sz = size;
    uint64_t bits;
    memcpy(&bits, &sz, sizeof bits);
    uint64_t key = ((1469598103934665603ull ^ bits) * k_fnv_prime ^ flags) * k_fnv_prime;
    key = fnv_name(fnv_name(fnv_name(key, wname_given, true), family, false), wstr, false);
    if (auto it = g_fonts.find(key); it != g_fonts.end()) {
        const FontEntry& e = it->second;
        if (e.size == sz && e.flags == flags && [e.family isEqualToString:family] && [e.wstr isEqualToString:wstr]
            && same_ascii_nocase(e.wname, wname_given))
            return e.font;
    }
    NSString *wname = wname_given.lowercaseString, *family_given = family;
    NSFontWeight weight = bold ? NSFontWeightBold : NSFontWeightRegular;
    double css = bold ? 700 : 400;
    NSDictionary<NSString*, NSArray<NSNumber*>*>* weights = @{
        @"thin": @[@(NSFontWeightThin), @100],
        @"light": @[@(NSFontWeightLight), @300],
        @"regular": @[@(NSFontWeightRegular), @400],
        @"medium": @[@(NSFontWeightMedium), @500],
        @"semibold": @[@(NSFontWeightSemibold), @600],
        @"bold": @[@(NSFontWeightBold), @700],
        @"heavy": @[@(NSFontWeightHeavy), @800],
        @"black": @[@(NSFontWeightBlack), @900],
    };
    if (NSArray* w = weights[wname])
        weight = [w[0] doubleValue], css = [w[1] doubleValue];
    NSFontWidth width;
    double wdth;
    bool widened = font_width(wstr, &width, &wdth) && width != NSFontWidthStandard;
    NSFont* f = nil;
    if (NSFontDescriptorSystemDesign design = system_design(family)) {
        NSFont* base = widened ? [NSFont systemFontOfSize:size weight:weight width:width]
                               : [NSFont systemFontOfSize:size weight:weight];
        NSFontDescriptor* d = [base.fontDescriptor fontDescriptorWithDesign:design];
        if (d && italic)
            d = [d fontDescriptorWithSymbolicTraits:d.symbolicTraits | NSFontDescriptorTraitItalic] ?: d;
        if (d)
            f = [NSFont fontWithDescriptor:d size:size], family = @"", italic = false;
    }
    bool named = false;
    if (family.length) {
        f = family_font(family, size, weight, css, width, wdth, italic);
        if (f)
            italic = italic && !(f.fontDescriptor.symbolicTraits & NSFontDescriptorTraitItalic);
        else if ((f = [NSFont fontWithName:family size:size]))
            named = true;
    }
    if (!f && mono)
        f = [NSFont monospacedSystemFontOfSize:size weight:weight];
    if (!f)
        f = widened ? [NSFont systemFontOfSize:size weight:weight width:width]
                    : [NSFont systemFontOfSize:size weight:weight];
    if (named && weight >= NSFontWeightSemibold)
        f = [NSFontManager.sharedFontManager convertFont:f toHaveTrait:NSBoldFontMask];
    if (italic)
        f = [NSFontManager.sharedFontManager convertFont:f toHaveTrait:NSItalicFontMask];
    if (tabular) {
        NSFontDescriptor* d = [f.fontDescriptor fontDescriptorByAddingAttributes:@{
            NSFontFeatureSettingsAttribute: @[@{
                NSFontFeatureTypeIdentifierKey: @(kNumberSpacingType),
                NSFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector)
            }]
        }];
        f = [NSFont fontWithDescriptor:d size:size] ?: f;
    }
    if (g_fonts.size() > 512)
        g_fonts.clear();
    g_fonts[key] = FontEntry{f, sz, flags, [wname_given copy], [family_given copy], [wstr copy]};
    return f;
}

static RXDockView* make_host(RXNode* n) {
    RXDockView* v = [[RXDockView alloc] initWithFrame:NSZeroRect];
    v.node = n;
    return v;
}

static bool g_lazy_seen;
bool lazy_layers_wanted(void) {
    static const bool env = [] {
        const char* e = getenv("REXUI_LAZY_LAYERS");
        return e && e[0] == '1';
    }();
    if (env || g_config.lazy_layers)
        return g_lazy_seen = true;
    return false;
}
bool lazy_layers(void) {
    return g_lazy_seen;
}

static NSPointerArray* g_warm_due;
static NSUInteger g_warm_at;
static bool g_warm_on;

static void warm_step(void) {
    const double end = CACurrentMediaTime() + 0.001;
    while (CACurrentMediaTime() < end) {
        if (g_warm_at >= g_warm_due.count) {
            g_warm_due = nil, g_warm_at = 0, g_warm_on = false;
            return;
        }
        RXNode* n = (__bridge RXNode*)[g_warm_due pointerAtIndex:g_warm_at++];
        if (!n.dormant)
            continue;
        const E e = n->ps.elem();
        if (e == E::Text || e == E::Button || e == E::TextField || e == E::TextArea)
            (void)font_for(n);
        if (e == E::Icon || e == E::Button)
            symbol_warm(n);
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        warm_step();
    });
}

void lazy_warm(RXNode* n) {
    const E e = n->ps.elem();
    if (e != E::Text && e != E::Button && e != E::TextField && e != E::TextArea && e != E::Icon)
        return;
    if (!g_warm_due)
        g_warm_due = [NSPointerArray weakObjectsPointerArray];
    [g_warm_due addPointer:(__bridge void*)n];
    if (g_warm_on)
        return;
    g_warm_on = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        warm_step();
    });
}

bool lazy_layer_kind(RXNode* n) {
    if (is_elem(n.doc.root, E::Panes))
        return false;
    switch (elem(n)) {
    case E::Dock:
    case E::Drawer:
    case E::Panes:
    case E::WebView:
    case E::Video:
    case E::PanePreview:
    case E::TabPreview:
    case E::Image:
    case E::Shader:
    case E::Process:
    case E::Timer:
    case E::FileDialog:
    case E::Shortcut:
        return false;
    default:
        return true;
    }
}

void layer_wake(RXNode* n, CALayer* prev, CALayer* below) {
    if (!n.dormant)
        return;
    n.dormant = false;
    CALayer* l = make_layer(n);
    n.layer = l;
    if (!l)
        return;
    apply_replay(n);
    CALayer* home = n.parent ? content_layer(n.parent) : nil;
    if (!home)
        return;
    if (prev && prev.superlayer == home)
        [home insertSublayer:l above:prev];
    else if (below && below.superlayer == home)
        [home insertSublayer:l below:below];
    else
        [home addSublayer:l];
    CALayer* mine = content_layer(n);
    for (RXNode* c in n.children)
        if (CALayer* cl = c.layer; cl && !cl.superlayer && !is_drawer(c))
            [mine addSublayer:cl];
}

CALayer* ensure_layer(RXNode* n) {
    if (!n || !n.dormant)
        return n.layer;
    RXNode* p = n.parent;
    if (p.dormant)
        ensure_layer(p);
    CALayer *home = p ? content_layer(p) : nil, *prev = nil, *below = nil;
    bool past = false;
    for (RXNode* c in p.children) {
        if (c == n) {
            past = true;
            continue;
        }
        CALayer* cl = c.layer;
        if (!cl || cl.superlayer != home)
            continue;
        if (!past)
            prev = cl;
        else {
            below = cl;
            break;
        }
    }
    layer_wake(n, prev, below);
    return n.layer;
}

CALayer* make_layer(RXNode* n) {
    if (is_elem(n, E::Process) || is_elem(n, E::Timer) || is_elem(n, E::FileDialog) || is_elem(n, E::Shortcut))
        return nil;
    CALayer* l;
    if (is_elem(n, E::Panes)) {
        l = [RXLayer layer];
    } else if (is_elem(n, E::Dock)) {
        RXDockView* host = make_host(n);
        n.host = host;
        l = [RXLayer layer];
        [host.layer addSublayer:l];
    } else if (is_drawer(n)) {
        RXDrawerView* d = [[RXDrawerView alloc] initWithFrame:NSZeroRect];
        d.node = n;
        drawer_register(n);
        d.fill = (CAShapeLayer*)still([CAShapeLayer layer]);
        [d.layer addSublayer:d.fill];
        d.body = make_host(n);
        [d addSubhost:d.body];
        d.layer.mask = still([RXTwinShape layer]);
        d.hidden = YES;
        n.host = d;
        l = [RXLayer layer];
        [d.body.layer addSublayer:l];
    } else if (is_pages(n)) {
        l = [RXLayer layer];
        l.masksToBounds = YES;
        [l addSublayer:[RXLayer layer]];
    } else if (is_list(n)) {
        RXScrollLayer* s = [RXScrollLayer layer];
        s.node = n;
        l = s;
    } else if (is_box(n)) {
        l = [RXLayer layer];
    } else if (is_elem(n, E::Text)) {
        l = [RXTextLayer layer];
    } else if (is_elem(n, E::TextField)) {
        RXTextLayer* f = [RXTextLayer layer];
        f.head = true;
        l = f;
    } else if (is_elem(n, E::TextArea)) {
        l = [RXLayer layer];
    } else if (is_elem(n, E::WebView)) {
        n.view = make_webview(n);
        l = [RXLayer layer];
    } else if (is_elem(n, E::TabPreview)) {
        l = make_tabpreview(n);
    } else if (is_elem(n, E::Icon)) {
        l = [RXIconLayer layer];
    } else if (is_elem(n, E::Image)) {
        l = [RXLayer layer];
        l.contentsGravity = kCAGravityResizeAspectFill;
        l.masksToBounds = YES;
    } else if (is_elem(n, E::Shapes)) {
        l = make_shapes(n);
    } else if (is_elem(n, E::Shader)) {
        l = make_shader(n);
    } else if (is_elem(n, E::Video)) {
        l = make_video(n);
    } else if (is_elem(n, E::PanePreview)) {
        l = make_pane_preview(n);
    } else if (is_elem(n, E::Path)) {
        l = make_path(n);
    } else if (is_elem(n, E::Visualiser)) {
        l = make_visualiser(n);
    } else if (is_elem(n, E::Arc)) {
        l = make_arc(n);
    } else if (is_elem(n, E::Graph)) {
        l = make_graph(n);
    } else if (is_elem(n, E::Canvas)) {
        l = make_canvas(n);
    } else if (is_elem(n, E::Button)) {
        RXButtonLayer* b = [RXButtonLayer layer];
        b.node = n;
        l = b;
    } else if (is_elem(n, E::Slider)) {
        l = [RXSliderLayer layer];
    } else {
        return nil;
    }
    if (n.view && is_native(n))
        [n.doc.natives addObject:n];
    return l;
}

static void fade_color(RXNode* n, CALayer* layer, NSString* path, CGColorRef from, CGColorRef to) {
    double ms = num(n, P::colorAnimation, 0);
    if (ms <= 0)
        return;
    CGColorRef clear = CGColorGetConstantColor(kCGColorClear);
    from = from ?: clear, to = to ?: clear;
    if (CGColorEqualToColor(from, to))
        return;
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:path];
    a.fromValue = (__bridge id)from;
    a.toValue = (__bridge id)to;
    a.duration = ms / 1000;
    a.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2:0:0:1];
    [layer addAnimation:a forKey:[@"rexui." stringByAppendingString:path]];
}

void fade_contents(RXNode* n) {
    double ms = num(n, P::colorAnimation, 0);
    if (ms <= 0 || !n.layer || !node_on_screen(n))
        return;
    CATransition* t = [CATransition animation];
    t.type = kCATransitionFade;
    t.duration = ms / 1000;
    [n.layer addAnimation:t forKey:@"rexui.fade"];
}

void apply_color(RXNode* n) {
    NSColor* c = parse_color(obj_of(n, P::color));
    if (is_drawer(n)) {
        ((RXDrawerView*)n.host).fill.fillColor = (c ?: g_theme.bg).CGColor;
    } else if (is_box(n)) {
        CALayer* l = n.layer;
        if (num(n, P::colorAnimation, 0) <= 0) {
            l.backgroundColor = c.CGColor;
            return;
        }
        CGColorRef from = ((CALayer*)l.presentationLayer ?: l).backgroundColor;
        if (from)
            CGColorRetain(from);
        l.backgroundColor = c.CGColor;
        if (node_on_screen(n))
            fade_color(n, l, @"backgroundColor", from, c.CGColor);
        if (from)
            CGColorRelease(from);
    } else if (is_elem(n, E::Text)) {
        fade_contents(n);
        RXTextLayer* t = (RXTextLayer*)n.layer;
        t.color = c ?: g_theme.fg;
        syntax_text(n, t, t.text, t.color);
    } else if (is_elem(n, E::Button)) {
        apply_button(n);
    } else if (is_elem(n, E::Image)) {
        n.layer.backgroundColor = c.CGColor;
    } else if (is_elem(n, E::Icon)) {
        fade_contents(n);
        apply_icon(n);
    } else if (is_canvas(n)) {
        apply_canvas(n, @"color");
    } else if (is_elem(n, E::TextArea)) {
        apply_textarea(n, @"color");
    } else if (is_elem(n, E::TextField)) {
        RXTextLayer* t = (RXTextLayer*)n.layer;
        NSString* text = str(n, P::text, @"");
        t.font = font_for(n);
        if (CGFloat top = 2 + CTFontGetLeading((__bridge CTFontRef)t.font) / 2; t.top != top)
            t.top = top, [t setNeedsDisplay];
        t.text = !text.length           ? str(n, P::placeholder, @"")
            : flag(n, P::secure, false) ? secure_dots(text, false)
                                        : text;
        t.color = text.length ? (c ?: g_theme.fg) : [c ?: g_theme.fg colorWithAlphaComponent:0.4];
        syntax_text(n, t, text, c ?: g_theme.fg);
        if (n.editor)
            apply_textarea(n, @"color");
    }
}

NSString* secure_dots(NSString* text, bool keep_length) {
    NSMutableString* out = [NSMutableString stringWithCapacity:keep_length ? text.length : text.length / 2 + 1];
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                             | NSStringEnumerationSubstringNotRequired
                          usingBlock:^(NSString*, NSRange r, NSRange, BOOL*) {
                              [out appendString:@"•"];
                              if (keep_length)
                                  for (NSUInteger i = 1; i < r.length; i++)
                                      [out appendString:@"\u2060"];
                          }];
    return out;
}
