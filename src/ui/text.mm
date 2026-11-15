// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include <memory>
#include <vector>

#include <algorithm>
#include <unordered_map>
#include <vector>

static constexpr CGFloat kInset = 2;

@implementation RXLayer
- (id<CAAction>)actionForKey:(NSString*)key {
    return nil;
}
- (void)setBounds:(CGRect)b {
    bool resized = !CGSizeEqualToSize(b.size, self.bounds.size);
    [super setBounds:b];
    if (resized && self.modelLayer == self)
        [self setNeedsLayout];
}
@end

CGFloat line_height(NSFont* f) {
    CTFontRef ct = (__bridge CTFontRef)f;
    return ceil(CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct));
}

static uint64_t g_typesets;
uint64_t text_typesets(void) {
    return g_typesets;
}

struct RXTextCache {
    uint64_t rev = 1, srev = 1;
    std::vector<NSUInteger> starts;
    uint64_t starts_rev = 0;
    CGFloat starts_w = -1;
    NSDictionary* attrs[2];
    uint64_t attrs_srev[2] = {0, 0};
    NSAttributedString* a[2];
    uint64_t a_rev[2] = {0, 0};
    CTLineRef line[2] = {nullptr, nullptr};
    uint64_t line_rev[2] = {0, 0};
    NSArray* lines[2];
    CGFloat lines_w[2] = {0, 0};
    uint64_t lines_rev[2] = {0, 0};
    CTLineRef ellipsis = nullptr;
    uint64_t ellipsis_rev = 0;
    std::unordered_map<uint64_t, NSArray*> paras;
    uint64_t paras_srev = 0;
    CGFloat paras_w = 0;
    ~RXTextCache() {
        for (CTLineRef l : line)
            if (l)
                CFRelease(l);
        if (ellipsis)
            CFRelease(ellipsis);
    }
};

@interface RXTextLayer () {
   @public
    RXTextCache _cache;
}
- (void)placeSelection;
@end

static int drawn_kind(RXTextLayer* t, bool drawn) {
    return drawn && (t.shownText || t.outline > 0) ? 1 : 0;
}

static NSParagraphStyle* paragraph(NSTextAlignment align) {
    static NSParagraphStyle* styles[5];
    int i = align >= 0 && align < 5 ? (int)align : 0;
    if (!styles[i]) {
        NSMutableParagraphStyle* p = [NSMutableParagraphStyle new];
        p.alignment = align;
        styles[i] = [p copy];
    }
    return styles[i];
}

static NSDictionary* attrs_of(RXTextLayer* t, int k) {
    RXTextCache& c = t->_cache;
    if (c.attrs[k] && c.attrs_srev[k] == c.srev)
        return c.attrs[k];
    NSFont* font = t.font ?: [NSFont systemFontOfSize:13];
    NSColor* color = t.color ?: NSColor.whiteColor;
    NSMutableDictionary* attrs = [@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paragraph(t.align),
        NSKernAttributeName: @(t.kern),
    } mutableCopy];
    if (t.underline)
        attrs[(__bridge NSString*)kCTUnderlineStyleAttributeName] = @(kCTUnderlineStyleSingle);
    if (t.strikeout)
        attrs[@"NSStrikethrough"] = @1;
    if (k == 1 && t.outline > 0) {
        CGFloat pct = t.outline / MAX(1, font.pointSize) * 100;
        attrs[NSStrokeWidthAttributeName] = @(color.alphaComponent > 0 ? -pct : pct);
        attrs[NSStrokeColorAttributeName] = t.outlineColor ?: color;
    }
    c.attrs[k] = [attrs copy];
    c.attrs_srev[k] = c.srev;
    return c.attrs[k];
}

static NSAttributedString* attributed(RXTextLayer* t, bool drawn = false) {
    RXTextCache& c = t->_cache;
    int k = drawn_kind(t, drawn);
    if (c.a[k] && c.a_rev[k] == c.rev)
        return c.a[k];
    NSDictionary* attrs = attrs_of(t, k);
    NSString* text = (k == 1 ? t.shownText : nil) ?: t.text ?: @"";
    if (t.spans.count && !t.shownText) {
        NSMutableAttributedString* a = [[NSMutableAttributedString alloc] initWithString:text attributes:attrs];
        id base = attrs[NSFontAttributeName];
        NSUInteger at = 0;
        for (NSDictionary* sp in t.spans) {
            if (![sp isKindOfClass:NSDictionary.class])
                continue;
            NSString* piece = [sp[@"text"] isKindOfClass:NSString.class] ? sp[@"text"] : @"";
            if (!piece.length)
                continue;
            if (at + piece.length > a.length)
                break;
            NSRange r = NSMakeRange(at, piece.length);
            at += piece.length;
            if (id c2 = sp[@"color"]) {
                if (id col = parse_color(c2))
                    [a addAttribute:NSForegroundColorAttributeName value:col range:r];
            }
            const bool bold = truthy_of(sp[@"bold"]), italic = truthy_of(sp[@"italic"]);
            if (bold || italic) {
                CTFontSymbolicTraits tr = (bold ? kCTFontBoldTrait : 0) | (italic ? kCTFontItalicTrait : 0);
                CTFontRef f = CTFontCreateCopyWithSymbolicTraits((__bridge CTFontRef)base, 0, nullptr, tr, tr);
                if (f) {
                    [a addAttribute:NSFontAttributeName value:(__bridge_transfer id)f range:r];
                }
            }
            NSString* link = [sp[@"link"] isKindOfClass:NSString.class] ? sp[@"link"] : nil;
            if (link)
                [a addAttribute:@"RXLink" value:link range:r];
            if (truthy_of(sp[@"underline"]) || link)
                [a addAttribute:(__bridge NSString*)kCTUnderlineStyleAttributeName
                          value:@(kCTUnderlineStyleSingle)
                          range:r];
        }
        c.a[k] = a;
        c.a_rev[k] = c.rev;
        return a;
    }
    if (!t.runs) {
        c.a[k] = [[NSAttributedString alloc] initWithString:text attributes:attrs];
        c.a_rev[k] = c.rev;
        return c.a[k];
    }
    NSMutableAttributedString* a = [[NSMutableAttributedString alloc] initWithString:text attributes:attrs];
    syntax_paint(t.runs, a, 0, a.length);
    c.a[k] = a;
    c.a_rev[k] = c.rev;
    return a;
}

static CTLineRef line_of(RXTextLayer* t, bool drawn) {
    RXTextCache& c = t->_cache;
    int k = drawn_kind(t, drawn);
    if (c.line[k] && c.line_rev[k] == c.rev)
        return c.line[k];
    NSAttributedString* a = attributed(t, drawn);
    if (c.line[k])
        CFRelease(c.line[k]);
    g_typesets++;
    c.line[k] = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);
    c.line_rev[k] = c.rev;
    return c.line[k];
}

static NSArray* lines_at(NSAttributedString* a, CGFloat width, NSInteger max, CTFramesetterRef* setter) {
    g_typesets++;
    *setter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)a);
    CGPathRef path = CGPathCreateWithRect(CGRectMake(0, 0, MAX(1, width), 1e6), nullptr);
    CTFrameRef frame = CTFramesetterCreateFrame(*setter, CFRangeMake(0, 0), path, nullptr);
    NSArray* lines = (__bridge_transfer NSArray*)CFRetain(CTFrameGetLines(frame));
    CFRelease(frame);
    CGPathRelease(path);
    if (max > 0 && (NSInteger)lines.count > max)
        lines = [lines subarrayWithRange:NSMakeRange(0, max)];
    return lines;
}

static constexpr NSUInteger k_long_text = 16 * 1024;

static NSArray* long_wrapped(RXTextLayer* t, CGFloat width) {
    RXTextCache& c = t->_cache;
    if (c.paras_srev != c.srev || c.paras_w != width)
        c.paras.clear(), c.paras_srev = c.srev, c.paras_w = width;
    NSString* s = t.text;
    const NSUInteger n = s.length;
    std::vector<unichar> u(n);
    [s getCharacters:u.data() range:NSMakeRange(0, n)];
    RXRuns* runs = t.runs;
    NSAttributedString* a = runs ? nil : attributed(t, false);
    NSMutableArray* all = [NSMutableArray array];
    std::unordered_map<uint64_t, NSArray*> kept;
    size_t cursor = 0;
    for (NSUInteger start = 0; start < n;) {
        NSUInteger end = start;
        uint64_t h = 14695981039346656037ull;
        while (end < n) {
            h = (h ^ u[end]) * 1099511628211ull;
            if (u[end++] == '\n')
                break;
        }
        if (runs)
            h = syntax_hash(runs, start, end, &cursor, h);
        NSArray* lines;
        if (auto it = c.paras.find(h); it != c.paras.end()) {
            lines = it->second;
        } else {
            NSAttributedString* part;
            if (runs) {
                NSMutableAttributedString* m = [[NSMutableAttributedString alloc]
                    initWithString:[s substringWithRange:NSMakeRange(start, end - start)]
                        attributes:attrs_of(t, 0)];
                syntax_paint(runs, m, start, end);
                part = m;
            } else {
                part = [a attributedSubstringFromRange:NSMakeRange(start, end - start)];
            }
            g_typesets++;
            CTTypesetterRef setter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)part);
            NSMutableArray* made = [NSMutableArray array];
            for (CFIndex at = 0, len = (CFIndex)part.length; at < len;) {
                CFIndex count = CTTypesetterSuggestLineBreak(setter, at, MAX(1, width));
                if (count <= 0)
                    count = 1;
                [made addObject:(__bridge_transfer id)CTTypesetterCreateLine(setter, CFRangeMake(at, count))];
                at += count;
            }
            CFRelease(setter);
            lines = made;
        }
        kept[h] = lines;
        [all addObjectsFromArray:lines];
        start = end;
    }
    c.paras = std::move(kept);
    return all;
}

static NSArray* wrapped(RXTextLayer* t, bool drawn, CGFloat width) {
    RXTextCache& c = t->_cache;
    int k = drawn_kind(t, drawn);
    if (c.lines[k] && c.lines_rev[k] == c.rev && c.lines_w[k] == width)
        return c.lines[k];
    if (k == 0 && t.text.length >= k_long_text && t.maxLines <= 0) {
        c.lines[k] = long_wrapped(t, width);
        c.lines_rev[k] = c.rev, c.lines_w[k] = width;
        return c.lines[k];
    }
    CTFramesetterRef setter;
    c.lines[k] = lines_at(attributed(t, drawn), width, 0, &setter);
    CFRelease(setter);
    c.lines_rev[k] = c.rev, c.lines_w[k] = width;
    return c.lines[k];
}

NSColor* text_color_at(RXTextLayer* t, NSUInteger i, CGFloat width) {
    NSArray* lines = t.wrap ? wrapped(t, false, width - 2 * kInset) : @[(__bridge id)line_of(t, false)];
    NSUInteger at = 0;
    for (id l in lines) {
        CTLineRef line = (__bridge CTLineRef)l;
        const NSUInteger len = (NSUInteger)CTLineGetStringRange(line).length;
        if (i < at + len) {
            const CFIndex here = CTLineGetStringRange(line).location + (CFIndex)(i - at);
            for (id g in (__bridge NSArray*)CTLineGetGlyphRuns(line)) {
                CTRunRef run = (__bridge CTRunRef)g;
                const CFRange r = CTRunGetStringRange(run);
                if (here >= r.location && here < r.location + r.length)
                    return ((__bridge NSDictionary*)CTRunGetAttributes(run))[NSForegroundColorAttributeName];
            }
            return nil;
        }
        at += len;
    }
    return nil;
}

NSSize text_size(RXTextLayer* t, CGFloat width) {
    CGFloat lh = line_height(t.font ?: [NSFont systemFontOfSize:13]);
    if (t.lineHeight > 0)
        lh = ceil(lh * t.lineHeight);
    if (!t.wrap)
        return NSMakeSize(ceil(CTLineGetTypographicBounds(line_of(t, false), nullptr, nullptr, nullptr)) + 2 * kInset,
                          lh);
    NSArray* lines = wrapped(t, false, width - 2 * kInset);
    NSInteger n = t.maxLines > 0 ? MIN(t.maxLines, (NSInteger)lines.count) : (NSInteger)lines.count;
    CGFloat w = 0;
    for (NSInteger i = 0; i < n; i++)
        w = MAX(w, CTLineGetTypographicBounds((__bridge CTLineRef)lines[i], nullptr, nullptr, nullptr));
    return NSMakeSize(ceil(w) + 2 * kInset, MAX(1, (CGFloat)n) * lh);
}

@interface RXTextHalo : CALayer
@property(nonatomic, weak) RXTextLayer* owner;
@end

static void draw_lines(RXTextLayer* t, CGContextRef ctx, CGSize size);

static CGFloat halo_pad(RXTextLayer* t) {
    return ceil(t.glowRadius * 1.6) + 1;
}

@implementation RXTextHalo
- (id<CAAction>)actionForKey:(NSString*)key {
    return nil;
}
- (void)drawInContext:(CGContextRef)ctx {
    RXTextLayer* t = self.owner;
    if (!t.text.length || !t.glow)
        return;
    CGFloat pad = halo_pad(t);
    CGSize size = t.bounds.size;
    if (self.contentsAreFlipped) {
        CGContextTranslateCTM(ctx, 0, self.bounds.size.height);
        CGContextScaleCTM(ctx, 1, -1);
    }
    CGContextTranslateCTM(ctx, pad, pad);
    CGFloat px = self.contentsScale ?: 1;
    CGContextSetShadowWithColor(ctx, CGSizeZero, t.glowRadius * px, t.glow.CGColor);
    draw_lines(t, ctx, size);
}
@end

@interface RXTextTiles : CATiledLayer {
   @public
    NSArray* _lines;
    CGFloat _lh, _ascent, _inset_x, _width;
    NSTextAlignment _align;
}
@end

static NSArray* sel_lines(RXTextLayer* t) {
    if (!t.wrap)
        return @[(__bridge id)line_of(t, false)];
    NSArray* all = wrapped(t, false, t.bounds.size.width - 2 * kInset);
    return t.maxLines > 0 && (NSInteger)all.count > t.maxLines
        ? [all subarrayWithRange:NSMakeRange(0, (NSUInteger)t.maxLines)]
        : all;
}

static const std::vector<NSUInteger>& sel_starts(RXTextLayer* t, NSArray* lines) {
    RXTextCache& c = t->_cache;
    const CGFloat w = t.bounds.size.width;
    if (c.starts_rev != c.rev || c.starts_w != w) {
        c.starts.clear();
        c.starts.reserve(lines.count + 1);
        NSUInteger at = 0;
        for (id l in lines) {
            c.starts.push_back(at);
            at += (NSUInteger)CTLineGetStringRange((__bridge CTLineRef)l).length;
        }
        c.starts.push_back(at);
        c.starts_rev = c.rev, c.starts_w = w;
    }
    return c.starts;
}

static NSInteger sel_line_at(const std::vector<NSUInteger>& starts, NSUInteger i) {
    size_t lo = 0, hi = starts.size() >= 2 ? starts.size() - 2 : 0;
    while (lo < hi) {
        size_t mid = (lo + hi + 1) / 2;
        if (starts[mid] <= i)
            lo = mid;
        else
            hi = mid - 1;
    }
    return (NSInteger)lo;
}

static CGFloat sel_line_x(RXTextLayer* t, CTLineRef line) {
    const CGFloat width = t.bounds.size.width, lw = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
    const CGFloat inset = MAX(0, MIN(kInset, floor((width - lw) / 2))), w = width - 2 * inset;
    if (t.align == NSTextAlignmentCenter)
        return inset + round((w - lw) / 2);
    if (t.align == NSTextAlignmentRight)
        return inset + w - lw;
    return inset;
}

static CGFloat sel_x(RXTextLayer* t, NSArray* lines, const std::vector<NSUInteger>& starts, NSInteger k, NSUInteger i) {
    CTLineRef line = (__bridge CTLineRef)lines[(NSUInteger)k];
    const CFIndex rel = (CFIndex)(i - starts[(size_t)k]) + CTLineGetStringRange(line).location;
    return sel_line_x(t, line) + CTLineGetOffsetForStringIndex(line, rel, nullptr);
}

static NSUInteger sel_index_at(RXTextLayer* t, CGPoint q) {
    NSArray* lines = sel_lines(t);
    if (!lines.count)
        return 0;
    const std::vector<NSUInteger>& starts = sel_starts(t, lines);
    const CGFloat lh = line_height(t.font ?: [NSFont systemFontOfSize:13]);
    if (q.y < 0)
        return 0;
    const NSInteger k = (NSInteger)(q.y / lh);
    if (k >= (NSInteger)lines.count)
        return starts.back();
    CTLineRef line = (__bridge CTLineRef)lines[(NSUInteger)k];
    const CFRange r = CTLineGetStringRange(line);
    CFIndex i = CTLineGetStringIndexForPosition(line, CGPointMake(q.x - sel_line_x(t, line), 0));
    if (i == kCFNotFound)
        i = r.location;
    i = MAX(r.location, MIN(i, r.location + r.length));
    NSUInteger at = starts[(size_t)k] + (NSUInteger)(i - r.location);
    NSString* s = t.text;
    if (at > starts[(size_t)k] && at == starts[(size_t)k + 1] && at <= s.length && [s characterAtIndex:at - 1] == '\n')
        at--;
    return at;
}

@implementation RXTextTiles
+ (CFTimeInterval)fadeDuration {
    return 0;
}
- (id<CAAction>)actionForKey:(NSString*)key {
    return nil;
}
- (void)drawInContext:(CGContextRef)ctx {
    CGFloat height = self.bounds.size.height;
    if (self.contentsAreFlipped) {
        CGContextTranslateCTM(ctx, 0, height);
        CGContextScaleCTM(ctx, 1, -1);
    }
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    CGContextSetAllowsFontSmoothing(ctx, true);
    CGContextSetShouldSmoothFonts(ctx, true);
    const CGRect clip = CGContextGetClipBoundingBox(ctx);
    const NSInteger total = (NSInteger)_lines.count;
    NSInteger first = MAX(0, (NSInteger)floor((height - CGRectGetMaxY(clip)) / _lh) - 1);
    NSInteger last = MIN(total - 1, (NSInteger)ceil((height - CGRectGetMinY(clip)) / _lh) + 1);
    for (NSInteger i = first; i <= last; i++) {
        CTLineRef line = (__bridge CTLineRef)_lines[(NSUInteger)i];
        const CGFloat lw = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
        CGFloat x = _inset_x;
        if (_align == NSTextAlignmentCenter)
            x += round((_width - lw) / 2);
        else if (_align == NSTextAlignmentRight)
            x += _width - lw;
        CGContextSetTextPosition(ctx, x, round(height - i * _lh - _ascent));
        CTLineDraw(line, ctx);
    }
}
@end

static constexpr CGFloat k_tiled_px = 4096;

@implementation RXTextLayer {
    RXTextHalo* _halo;
    RXTextTiles* _tiles;
   @public
    NSRange _sel;
    NSUInteger _sel_anchor;
    NSRange _sel_unit;
    int _sel_units;
    CALayer* _sel_layers[3];
}
- (instancetype)init {
    if (!(self = [super init]))
        return nil;
    self.needsDisplayOnBoundsChange = YES;
    self.contentsScale = backing_scale();
    return self;
}
- (void)setNeedsDisplay {
    [super setNeedsDisplay];
    [_halo setNeedsDisplay];
}
- (void)changed {
    _cache.rev++;
    if (_sel.length) {
        _sel = NSMakeRange(0, 0);
        [self placeSelection];
    }
    [self setNeedsDisplay];
}
- (void)styled {
    _cache.srev++;
    [self changed];
}
- (void)setText:(NSString*)s {
    if (![s isEqualToString:_text])
        _text = [s copy], [self changed];
}
- (void)setFont:(NSFont*)f {
    if (![f isEqual:_font])
        _font = f, [self styled];
}
- (void)setColor:(NSColor*)c {
    if (![c isEqual:_color])
        _color = c, [self styled];
}
- (void)setWrap:(bool)w {
    if (w != _wrap)
        _wrap = w, [self changed];
}
- (void)setMaxLines:(NSInteger)m {
    if (m != _maxLines)
        _maxLines = m, [self changed];
}
- (void)setAlign:(NSTextAlignment)a {
    if (a != _align)
        _align = a, [self styled];
}
- (void)setHead:(bool)h {
    if (h != _head)
        _head = h, [self changed];
}
- (void)setKern:(CGFloat)k {
    if (k != _kern)
        _kern = k, [self styled];
}
- (void)setUnderline:(bool)on {
    if (on != _underline)
        _underline = on, [self styled];
}
- (void)setStrikeout:(bool)on {
    if (on != _strikeout)
        _strikeout = on, [self styled];
}
- (void)setLineHeight:(CGFloat)h {
    if (h != _lineHeight)
        _lineHeight = h, [self styled];
}
- (void)setSpans:(NSArray*)sp {
    _spans = [sp copy];
    [self styled];
}
- (NSString*)linkAt:(CGPoint)p {
    if (!_spans.count || !_font)
        return nil;
    NSAttributedString* a = attributed(self, false);
    CGFloat lh = line_height(_font);
    if (_lineHeight > 0)
        lh = ceil(lh * _lineHeight);
    CTLineRef line = nullptr;
    if (!_wrap) {
        line = line_of(self, false);
    } else {
        NSArray* lines = wrapped(self, false, self.bounds.size.width - 2 * kInset);
        const NSInteger i = (NSInteger)floor(p.y / lh);
        if (i < 0 || i >= (NSInteger)lines.count)
            return nil;
        line = (__bridge CTLineRef)lines[(NSUInteger)i];
    }
    const CFIndex at = CTLineGetStringIndexForPosition(line, CGPointMake(p.x - kInset, 0));
    if (at < 0 || at >= (CFIndex)a.length)
        return nil;
    return [a attribute:@"RXLink" atIndex:(NSUInteger)at effectiveRange:nullptr];
}
- (void)setRuns:(RXRuns*)r {
    if (r != _runs)
        _runs = r, [self changed];
}
- (void)syntaxChanged:(bool)style {
    if (style)
        [self styled];
    else
        [self changed];
}
- (void)setShownText:(NSString*)s {
    if (!(s == _shownText || [s isEqualToString:_shownText]))
        _shownText = [s copy], [self changed];
}
- (void)setHideText:(bool)h {
    if (h == _hideText)
        return;
    _hideText = h;
    [self setNeedsDisplay];
}
- (void)setOutline:(CGFloat)o {
    if (o != _outline)
        _outline = o, [self styled];
}
- (void)setOutlineColor:(NSColor*)c {
    if (!(c == _outlineColor || [c isEqual:_outlineColor]))
        _outlineColor = c, [self styled];
}
- (void)setGlowRadius:(CGFloat)r {
    if (r != _glowRadius)
        _glowRadius = r, [self updateHalo];
}
- (void)setGlow:(NSColor*)c {
    if (c == _glow || [c isEqual:_glow])
        return;
    _glow = c;
    [self updateHalo];
}
- (void)updateHalo {
    if (_glow && CGColorGetAlpha(_glow.CGColor) > 0 && _glowRadius > 0) {
        if (!_halo) {
            _halo = [RXTextHalo layer];
            _halo.owner = self;
            _halo.needsDisplayOnBoundsChange = YES;
            [self addSublayer:_halo];
        }
        [self layoutSublayers];
    } else {
        [_halo removeFromSuperlayer];
        _halo = nil;
    }
    [self setNeedsDisplay];
}
- (void)layoutSublayers {
    [super layoutSublayers];
    [self placeTiles];
    if (_sel.length)
        [self placeSelection];
    if (!_halo)
        return;
    CGFloat pad = halo_pad(self);
    CGRect f = CGRectInset(self.bounds, -pad, -pad);
    if (!CGRectEqualToRect(_halo.frame, f))
        _halo.frame = f;
    if (_halo.contentsScale != self.contentsScale)
        _halo.contentsScale = self.contentsScale;
}
- (void)placeSelection {
    size_t used = 0;
    if (_sel.length) {
        NSArray* lines = sel_lines(self);
        const std::vector<NSUInteger>& starts = sel_starts(self, lines);
        const CGFloat lh = line_height(_font ?: [NSFont systemFontOfSize:13]);
        const NSUInteger to = NSMaxRange(_sel);
        NSInteger a = sel_line_at(starts, _sel.location), b = sel_line_at(starts, to > 0 ? to - 1 : 0);
        auto rect = [&](CGRect r) {
            CALayer* l = _sel_layers[used];
            if (!l) {
                l = [RXLayer layer];
                l.zPosition = 5;
                [self addSublayer:l];
                _sel_layers[used] = l;
            }
            used++;
            l.hidden = NO;
            l.backgroundColor = [(ui_accent() ?: NSColor.controlAccentColor) colorWithAlphaComponent:0.35].CGColor;
            l.frame = r;
        };
        const CGFloat right = self.bounds.size.width;
        if (a == b) {
            const CGFloat x0 = sel_x(self, lines, starts, a, _sel.location), x1 = sel_x(self, lines, starts, a, to);
            rect(CGRectMake(x0, (CGFloat)a * lh, MAX(1, x1 - x0), lh));
        } else {
            const CGFloat x0 = sel_x(self, lines, starts, a, _sel.location);
            rect(CGRectMake(x0, (CGFloat)a * lh, MAX(1, right - x0), lh));
            if (b > a + 1)
                rect(CGRectMake(0, (CGFloat)(a + 1) * lh, right, (CGFloat)(b - a - 1) * lh));
            rect(CGRectMake(0, (CGFloat)b * lh, MAX(1, sel_x(self, lines, starts, b, to)), lh));
        }
    }
    for (size_t k = used; k < 3; k++)
        _sel_layers[k].hidden = YES;
}

- (void)placeTiles {
    const CGSize size = self.bounds.size;
    const CGFloat scale = backing_scale();
    const bool want = _wrap && !_halo && !_shownText && _outline <= 0 && _text.length
        && size.height * scale > k_tiled_px && size.width > 2 * kInset;
    if (!want) {
        if (_tiles)
            [_tiles removeFromSuperlayer], _tiles = nil, [super setNeedsDisplay];
        return;
    }
    const bool fresh = !_tiles;
    if (fresh) {
        _tiles = [RXTextTiles layer];
        _tiles.levelsOfDetail = 1;
        _tiles.tileSize = CGSizeMake(MIN(2048, ceil(size.width * scale)), 1024);
        [self addSublayer:_tiles];
        self.contents = nil;
    }
    NSFont* font = _font ?: [NSFont systemFontOfSize:13];
    NSArray* lines = wrapped(self, false, size.width - 2 * kInset);
    const bool changed = fresh || _tiles->_lines != lines || !CGRectEqualToRect(_tiles.frame, self.bounds);
    if (!changed)
        return;
    _tiles->_lines = lines;
    _tiles->_lh = line_height(font);
    _tiles->_ascent = CTFontGetAscent((__bridge CTFontRef)font);
    _tiles->_inset_x = kInset;
    _tiles->_width = size.width - 2 * kInset;
    _tiles->_align = _align;
    _tiles.contentsScale = scale;
    _tiles.frame = self.bounds;
    [_tiles setNeedsDisplay];
}
- (void)display {
    for (CALayer* x = self.superlayer; x; x = x.superlayer)
        if ([x isKindOfClass:RXScrollLayer.class]) {
            RXScrollLayer* s = (RXScrollLayer*)x;
            if (self.modelLayer == self && !is_vlist(s.node) && ![s shows:self]) {
                self.contents = nil;
                [_tiles removeFromSuperlayer], _tiles = nil;
                [s owe:self];
                return;
            }
            break;
        }
    _owed = false;
    [self placeTiles];
    CGFloat scale = backing_scale();
    if (self.contentsScale != scale)
        self.contentsScale = scale;
    if (_halo && _halo.contentsScale != scale)
        _halo.contentsScale = scale;
    [super display];
}
- (void)drawInContext:(CGContextRef)ctx {
    if (!_text.length || _halo || _hideText || _tiles)
        return;
    if (self.contentsAreFlipped) {
        CGContextTranslateCTM(ctx, 0, self.bounds.size.height);
        CGContextScaleCTM(ctx, 1, -1);
    }
    draw_lines(self, ctx, self.bounds.size);
}
@end

static void draw_lines(RXTextLayer* t, CGContextRef ctx, CGSize size) {
    CGFloat w = size.width - 2 * kInset;
    if (w <= 0)
        return;
    NSAttributedString* a = attributed(t, true);
    if (!a.length)
        return;
    RXTextCache& cache = t->_cache;
    bool decoding = t.shownText != nil;
    NSFont* font = t.font ?: [NSFont systemFontOfSize:13];
    CTFontRef ct = (__bridge CTFontRef)font;
    CGFloat lh = line_height(font), ascent = CTFontGetAscent(ct);
    if (t.lineHeight > 0)
        lh = ceil(lh * t.lineHeight);
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    CGContextSetAllowsFontSmoothing(ctx, true);
    CGContextSetShouldSmoothFonts(ctx, true);
    auto ellipsis = [&]() {
        if (!cache.ellipsis || cache.ellipsis_rev != cache.rev) {
            if (cache.ellipsis)
                CFRelease(cache.ellipsis);
            cache.ellipsis = CTLineCreateWithAttributedString(
                (__bridge CFAttributedStringRef)
                    [[NSAttributedString alloc] initWithString:@"…"
                                                    attributes:[a attributesAtIndex:0 effectiveRange:nullptr]]);
            cache.ellipsis_rev = cache.rev;
        }
        return cache.ellipsis;
    };
    bool head = t.head;
    NSTextAlignment align = t.align;
    CGFloat px = t.contentsScale ?: 1;
    auto draw = [&](CTLineRef line, NSInteger i, bool last_cut) {
        CTLineRef shown = line;
        bool made = false;
        CGFloat lw = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
        CGFloat inset = MAX(0, MIN(kInset, floor((size.width - lw) / 2))), w = size.width - 2 * inset;
        if (!decoding && (last_cut || lw > w + 0.5)) {
            CTLineTruncationType type = head ? kCTLineTruncationStart : kCTLineTruncationEnd;
            if (last_cut) {
                CFRange r = CTLineGetStringRange(line);
                const NSUInteger from = (NSUInteger)r.location,
                                 most = MIN(a.length - from, (NSUInteger)r.length * 2 + 64);
                NSAttributedString* m = [a attributedSubstringFromRange:NSMakeRange(from, most)];
                CTLineRef rest = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)m);
                if (CTLineRef cut = CTLineCreateTruncatedLine(rest, w, kCTLineTruncationEnd, ellipsis())) {
                    shown = cut;
                    CFRelease(rest);
                } else {
                    shown = rest;
                }
                made = true;
            } else {
                if (CTLineRef cut = CTLineCreateTruncatedLine(line, w, type, ellipsis()))
                    shown = cut, made = true;
            }
            lw = CTLineGetTypographicBounds(shown, nullptr, nullptr, nullptr);
        }
        CGFloat x = inset;
        if (align == NSTextAlignmentCenter)
            x = inset + round((w - lw) / 2);
        else if (align == NSTextAlignmentRight)
            x = inset + w - lw;
        CGContextSetTextPosition(ctx, round(x * px) / px, round((size.height - t.top - i * lh - ascent) * px) / px);
        CTLineDraw(shown, ctx);
        if (made)
            CFRelease(shown);
    };
    if (!t.wrap) {
        draw(line_of(t, true), 0, false);
    } else {
        NSInteger fit = MAX(1, (NSInteger)floor((size.height + 0.5) / lh));
        NSInteger max = t.maxLines > 0 ? MIN(t.maxLines, fit) : fit;
        NSArray* all = wrapped(t, true, w);
        NSInteger n = MIN((NSInteger)all.count, max);
        for (NSInteger i = 0; i < n; i++)
            draw((__bridge CTLineRef)all[i], i, i == n - 1 && (NSInteger)all.count > n);
    }
}

static NSRange word_at(NSString* s, NSUInteger i) {
    if (!s.length)
        return NSMakeRange(0, 0);
    i = MIN(i, s.length - 1);
    auto word = [](unichar c) { return [NSCharacterSet.alphanumericCharacterSet characterIsMember:c] || c == '_'; };
    if (!word([s characterAtIndex:i]))
        return [s rangeOfComposedCharacterSequenceAtIndex:i];
    NSUInteger a = i, b = i;
    while (a > 0 && word([s characterAtIndex:a - 1]))
        a--;
    while (b < s.length && word([s characterAtIndex:b]))
        b++;
    return NSMakeRange(a, b - a);
}

static __weak RXNode* g_selected;

static RXTextLayer* text_layer(RXNode* n) {
    return [n.layer isKindOfClass:RXTextLayer.class] ? (RXTextLayer*)n.layer : nil;
}

static void sel_tell(RXNode* n) {
    RXTextLayer* t = text_layer(n);
    if (t && n.doc.ctx)
        doc_call(n.doc, @"update",
                 @[@(n.uid), @{@"selectedText": t->_sel.length ? [t.text substringWithRange:t->_sel] : @""}]);
}

static void sel_set(RXTextLayer* t, NSUInteger a, NSUInteger b) {
    t->_sel = NSMakeRange(MIN(a, b), MAX(a, b) - MIN(a, b));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [t placeSelection];
    [CATransaction commit];
}

static NSHashTable<RXNode*>* g_spread;
static bool g_spreading, g_spread_ticking;
static CGPoint g_spread_at;

static NSString* group_of(RXNode* n) {
    return n ? str(n, P::selectionGroup, @"") : @"";
}

struct GroupText {
    __unsafe_unretained RXNode* n;
    CGRect r;
};
static NSMapTable<RXDoc*, NSHashTable<RXNode*>*>* g_grouped;
void text_selectable_changed(RXNode* n) {
    RXDoc* d = n.doc;
    if (!d || !is_elem(n, E::Text))
        return;
    const bool in = flag(n, P::selectable, false) && group_of(n).length;
    NSHashTable<RXNode*>* set = [g_grouped objectForKey:d];
    if (in && !set) {
        if (!g_grouped)
            g_grouped = [NSMapTable weakToStrongObjectsMapTable];
        set = [NSHashTable weakObjectsHashTable];
        [g_grouped setObject:set forKey:d];
    }
    if (in)
        [set addObject:n];
    else
        [set removeObject:n];
}
static NSArray<RXNode*>* g_order;
static NSString* g_order_group;
static __weak RXDoc* g_order_doc;
static uint64_t g_order_epoch;
static bool shown_in(RXTextLayer* t, CALayer* host) {
    CALayer* x = t;
    for (; x && x != host; x = x.superlayer)
        if (x.hidden)
            return false;
    return x && x == host;
}
static std::vector<GroupText> group_texts(RXNode* any) {
    std::vector<GroupText> out;
    NSString* g = group_of(any);
    CALayer* host = host_of(any).layer;
    if (!g.length || !host)
        return out;
    RXDoc* doc = any.doc;
    if (g_order && g_order_doc == doc && g_order_epoch == g_kids_epoch && [g_order_group isEqualToString:g]) {
        for (RXNode* x in g_order)
            if (x.doc == doc && text_layer(x) && !x.layer.hidden)
                out.push_back({x, [x.layer convertRect:x.layer.bounds toLayer:host]});
        bool sorted = true;
        for (size_t i = 1; i < out.size() && sorted; i++) {
            const CGRect &a = out[i - 1].r, &b = out[i].r;
            sorted = CGRectGetMinY(a) < CGRectGetMinY(b)
                || (CGRectGetMinY(a) == CGRectGetMinY(b) && CGRectGetMinX(a) <= CGRectGetMinX(b));
        }
        if (sorted)
            return out;
        out.clear();
    }
    for (RXNode* x in [g_grouped objectForKey:doc])
        if (is_elem(x, E::Text) && flag(x, P::selectable, false) && [group_of(x) isEqualToString:g]
            && shown_in(text_layer(x), host))
            out.push_back({x, [x.layer convertRect:x.layer.bounds toLayer:host]});
    std::sort(out.begin(), out.end(), [](const GroupText& a, const GroupText& b) {
        return CGRectGetMinY(a.r) != CGRectGetMinY(b.r) ? CGRectGetMinY(a.r) < CGRectGetMinY(b.r)
                                                        : CGRectGetMinX(a.r) < CGRectGetMinX(b.r);
    });
    NSMutableArray* order = [NSMutableArray arrayWithCapacity:out.size()];
    for (const GroupText& t : out)
        [order addObject:t.n];
    g_order = order, g_order_group = [g copy], g_order_doc = doc, g_order_epoch = g_kids_epoch;
    return out;
}

RXNode* text_selection_anchor(void) {
    return g_selected;
}

bool text_selection_rows(RXNode* list, uint32_t* lo, uint32_t* hi) {
    RXNode* began = g_selected;
    RXTextLayer* t = text_layer(began);
    if (!began || (!g_spreading && !g_spread.count && !(t && t->_sel.length)))
        return false;
    uint32_t a = UINT32_MAX, b = 0;
    auto take = [&](RXNode* x) {
        for (__unsafe_unretained RXNode* r = x; r; r = r->up)
            if (r->up == list) {
                if (r->_row)
                    a = MIN(a, r->_row - 1), b = MAX(b, r->_row - 1);
                return;
            }
    };
    take(began);
    for (RXNode* x in g_spread)
        take(x);
    if (a == UINT32_MAX)
        return false;
    *lo = a, *hi = b;
    return true;
}

static void sel_within(RXTextLayer* t, NSUInteger i) {
    NSString* s = t.text ?: @"";
    if (t->_sel_units > 1) {
        NSRange r = t->_sel_units == 3 ? [s paragraphRangeForRange:NSMakeRange(i, 0)] : word_at(s, i);
        NSRange u = NSUnionRange(r, t->_sel_unit);
        return sel_set(t, u.location, NSMaxRange(u));
    }
    sel_set(t, t->_sel_anchor, i);
}

static void spread_to(RXNode* anchor, CGPoint p) {
    const std::vector<GroupText> all = group_texts(anchor);
    if (all.empty())
        return;
    CALayer* host = host_of(anchor).layer;
    size_t from = all.size(), to = all.size() - 1;
    for (size_t i = 0; i < all.size(); i++) {
        if (all[i].n == anchor)
            from = i;
        if (to == all.size() - 1 && p.y < CGRectGetMaxY(all[i].r))
            to = i;
    }
    if (from == all.size() || !host)
        return;
    RXTextLayer *at = text_layer(anchor), *last = text_layer(all[to].n);
    if (!at || !last)
        return;
    if (!g_spread)
        g_spread = [NSHashTable weakObjectsHashTable];
    NSHashTable<RXNode*>* was = [g_spread copy];
    [g_spread removeAllObjects];
    const size_t lo = MIN(from, to), hi = MAX(from, to);
    const NSUInteger len = last.text.length;
    NSUInteger end = MIN(sel_index_at(last, [host convertPoint:p toLayer:last]), len);
    if (p.y < CGRectGetMinY(all[to].r))
        end = to > from ? 0 : end;
    if (p.y >= CGRectGetMaxY(all.back().r) && to == all.size() - 1)
        end = len;
    if (p.y < CGRectGetMinY(all[0].r))
        end = 0;
    for (size_t i = lo; i <= hi; i++) {
        RXNode* n = all[i].n;
        RXTextLayer* t = text_layer(n);
        if (!t)
            continue;
        const NSUInteger l = t.text.length;
        const NSUInteger began = at->_sel_units > 1 ? at->_sel_unit.location : at->_sel_anchor,
                         ended = at->_sel_units > 1 ? NSMaxRange(at->_sel_unit) : at->_sel_anchor;
        if (from == to)
            sel_within(t, end);
        else if (n == anchor)
            sel_set(t, to > from ? began : 0, to > from ? l : ended);
        else if (i == to)
            sel_set(t, to > from ? 0 : end, to > from ? end : l);
        else if (!NSEqualRanges(t->_sel, NSMakeRange(0, l)))
            sel_set(t, 0, l);
        if (t->_sel.length)
            [g_spread addObject:n];
    }
    for (RXNode* n in was) {
        if (n == anchor || [g_spread containsObject:n])
            continue;
        RXTextLayer* t = text_layer(n);
        if (t && t->_sel.length) {
            sel_set(t, 0, 0);
            sel_tell(n);
        }
    }
}

static uint32_t g_spread_tick;
static void spread_scroll(void);
static void spread_tick(id, const RXFrame*) {
    spread_scroll();
}
static void spread_scroll(void) {
    RXNode *a = g_selected, *list = a;
    while (list && !is_list(list))
        list = list.parent;
    CALayer* host = a ? host_of(a).layer : nil;
    CGFloat by = 0;
    if (g_spreading && list && host) {
        RXScrollLayer* sv = (RXScrollLayer*)list.layer;
        const CGRect b = [sv convertRect:sv.bounds toLayer:host];
        const CGFloat past = g_spread_at.y < CGRectGetMinY(b) ? g_spread_at.y - CGRectGetMinY(b)
            : g_spread_at.y > CGRectGetMaxY(b)                ? g_spread_at.y - CGRectGetMaxY(b)
                                                              : 0;
        by = MAX(-30, MIN(30, past / 3));
        const CGFloat to = MAX(0, MIN(sv.maxOffset, sv.offset + by));
        if (to == sv.offset)
            by = 0;
        else {
            sv.offset = to;
            spread_to(a, g_spread_at);
        }
    }
    if (!by) {
        g_spread_ticking = false;
        ui_clock_remove(g_spread_tick);
        g_spread_tick = 0;
        return;
    }
    if (!g_spread_tick)
        g_spread_tick = ui_clock_add(RX_TICK_SCROLL, 60, host_of(a), NSNull.null, spread_tick);
}

void text_select_clear(void) {
    RXNode* n = g_selected;
    g_selected = nil;
    g_spreading = false;
    for (RXNode* x in g_spread.allObjects) {
        RXTextLayer* t = text_layer(x);
        if (x == n || !t || !t->_sel.length)
            continue;
        t->_sel = NSMakeRange(0, 0);
        [t placeSelection];
        sel_tell(x);
    }
    [g_spread removeAllObjects];
    RXTextLayer* t = text_layer(n);
    if (!t || !t->_sel.length)
        return;
    t->_sel = NSMakeRange(0, 0);
    [t placeSelection];
    sel_tell(n);
}

void text_gone(RXNode* n) {
    [g_spread removeObject:n];
    if (RXDoc* d = n.doc)
        [[g_grouped objectForKey:d] removeObject:n];
    if (g_selected == n) {
        g_selected = g_spread.anyObject;
        g_spreading = false;
    }
}

void text_press(RXNode* n, CGPoint q, NSInteger clicks, bool extend) {
    RXTextLayer* t = text_layer(n);
    if (!t)
        return;
    RXNode* began = g_selected;
    const bool grouped = group_of(n).length > 0;
    if (extend && grouped && began && [group_of(began) isEqualToString:group_of(n)]) {
        CALayer* host = host_of(n).layer;
        if (!host)
            return;
        g_spreading = true;
        g_spread_at = [n.layer convertPoint:q toLayer:host];
        return spread_to(began, g_spread_at);
    }
    if (began != n)
        text_select_clear();
    g_selected = n;
    g_spreading = grouped;
    NSString* s = t.text ?: @"";
    const NSUInteger i = MIN(sel_index_at(t, q), s.length);
    t->_sel_units = clicks >= 3 ? 3 : clicks == 2 ? 2 : 1;
    if (t->_sel_units > 1) {
        t->_sel_unit = t->_sel_units == 3 ? [s paragraphRangeForRange:NSMakeRange(i, 0)] : word_at(s, i);
        t->_sel_anchor = t->_sel_unit.location;
        sel_set(t, t->_sel_unit.location, NSMaxRange(t->_sel_unit));
        return;
    }
    if (extend && t->_sel.length)
        return sel_set(t, t->_sel_anchor, i);
    t->_sel_anchor = i;
    sel_set(t, i, i);
}

void text_drag(RXNode* n, CGPoint q) {
    RXTextLayer* t = text_layer(n);
    RXNode* began = g_selected;
    if (!t || !began)
        return;
    if (group_of(began).length && [group_of(began) isEqualToString:group_of(n)]) {
        CALayer* host = host_of(n).layer;
        if (!host)
            return;
        g_spread_at = [n.layer convertPoint:q toLayer:host];
        spread_to(began, g_spread_at);
        if (g_spreading && !g_spread_ticking) {
            g_spread_ticking = true;
            spread_scroll();
        }
        return;
    }
    if (began != n)
        return;
    sel_within(t, MIN(sel_index_at(t, q), (t.text ?: @"").length));
}

void text_release(RXNode* n) {
    g_spreading = false;
    if (g_spread.count) {
        for (RXNode* x in g_spread.allObjects)
            sel_tell(x);
        return;
    }
    sel_tell(n);
}

NSString* text_selected_string(void) {
    RXNode* n = g_selected;
    RXTextLayer* t = text_layer(n);
    if (!g_spread.count)
        return t && t->_sel.length ? [t.text substringWithRange:t->_sel] : @"";
    NSMutableArray<NSString*>* out = [NSMutableArray array];
    for (const GroupText& g : group_texts(n)) {
        RXTextLayer* x = text_layer(g.n);
        if (x->_sel.length && [g_spread containsObject:g.n])
            [out addObject:[x.text substringWithRange:x->_sel]];
    }
    return [out componentsJoinedByString:@"\n"];
}

bool text_select_key(NSEvent* e) {
    RXNode* n = g_selected;
    RXTextLayer* t = text_layer(n);
    if (!t || e.type != NSEventTypeKeyDown)
        return false;
    if ((e.modifierFlags
         & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption
            | NSEventModifierFlagControl))
        != NSEventModifierFlagCommand)
        return false;
    NSString* key = e.charactersIgnoringModifiers.lowercaseString;
    if (![key isEqualToString:@"c"] && ![key isEqualToString:@"a"])
        return false;
    if (!text_selected_string().length)
        return false;
    bool seen = node_on_screen(n);
    for (RXNode* x in g_spread.allObjects)
        seen = seen || node_on_screen(x);
    if (!seen) {
        text_select_clear();
        return false;
    }
    const NSEventModifierFlags m = e.modifierFlags
        & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption
           | NSEventModifierFlagControl);
    if (m != NSEventModifierFlagCommand)
        return false;
    NSString* k = e.charactersIgnoringModifiers.lowercaseString;
    if ([k isEqualToString:@"c"]) {
        NSPasteboard* pb = ui_pasteboard();
        [pb clearContents];
        [pb setString:text_selected_string() forType:NSPasteboardTypeString];
        return true;
    }
    if ([k isEqualToString:@"a"]) {
        if (group_of(n).length) {
            if (!g_spread)
                g_spread = [NSHashTable weakObjectsHashTable];
            for (const GroupText& g : group_texts(n)) {
                RXTextLayer* x = text_layer(g.n);
                sel_set(x, 0, x.text.length);
                if (x->_sel.length)
                    [g_spread addObject:g.n];
                sel_tell(g.n);
            }
            return true;
        }
        sel_set(t, 0, t.text.length);
        sel_tell(n);
        return true;
    }
    return false;
}

void text_effects(RXNode* n) {
    RXTextLayer* t = [n.layer isKindOfClass:RXTextLayer.class] ? (RXTextLayer*)n.layer : nil;
    if (!t)
        return;
    t.outline = MAX(0, num(n, P::outline, 0));
    t.outlineColor = parse_color(obj_of(n, P::outlineColor));
    t.glowRadius = MAX(0, num(n, P::glowRadius, 6));
    t.glow = parse_color(obj_of(n, P::glow));
}

static char k_scramble;
void text_scramble(RXNode* n) {
    RXTextLayer* t = [n.layer isKindOfClass:RXTextLayer.class] ? (RXTextLayer*)n.layer : nil;
    double ms = num(n, P::scramble, 0);
    [(RXAnim*)objc_getAssociatedObject(n, &k_scramble) cancel];
    objc_setAssociatedObject(n, &k_scramble, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString* text = t.text;
    id<RXHost> host = host_of(n);
    if (!t || ms <= 0 || !text.length || !host.window || !node_on_screen(n)) {
        t.shownText = nil;
        return;
    }
    NSString* set = str(n, P::scrambleSet, @"");
    NSUInteger len = text.length;
    double step = MIN(38.0, ms / MAX(1.0, (double)len));
    static constexpr double kLinear[4] = {0, 0, 1, 1};
    __weak RXTextLayer* weak = t;
    NSUInteger set_len = set.length;
    auto chars = std::make_shared<std::vector<unichar>>(len + set_len);
    [text getCharacters:chars->data() range:NSMakeRange(0, len)];
    if (set_len)
        [set getCharacters:chars->data() + len range:NSMakeRange(0, set_len)];
    auto out = std::make_shared<std::vector<unichar>>(len);
    NSCharacterSet* space = NSCharacterSet.whitespaceCharacterSet;
    auto shown_at = [chars, out, set_len, len, step, space](double elapsed) {
        const unichar *src = chars->data(), *pool = chars->data() + len;
        unichar* dst = out->data();
        uint32_t bucket = (uint32_t)(elapsed / 40);
        for (NSUInteger i = 0; i < len; i++) {
            unichar c = src[i];
            dst[i] = c;
            if (elapsed >= (i + 1) * step)
                continue;
            uint32_t h = (uint32_t)i * 2654435761u ^ bucket * 40503u;
            h ^= h >> 13, h *= 0x5bd1e995u, h ^= h >> 15;
            if (set_len) {
                if (![space characterIsMember:c])
                    dst[i] = pool[h % set_len];
            } else if (c >= '0' && c <= '9')
                dst[i] = '0' + h % 10;
            else if (c >= 'A' && c <= 'Z')
                dst[i] = 'A' + h % 26;
            else if (c >= 'a' && c <= 'z')
                dst[i] = 'a' + h % 26;
        }
        return [[NSString alloc] initWithCharacters:dst length:len];
    };
    t.shownText = shown_at(0);
    RXAnim* a = animate(
        host, ms,
        ^(double e) {
            weak.shownText = shown_at(e * ms);
        },
        ^{
            weak.shownText = nil;
        });
    a.curve = kLinear;
    objc_setAssociatedObject(n, &k_scramble, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
