// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include "core/text/highlight.h"
#include "core/text/rope.h"

#include <deque>
#include <memory>
#include <string>
#include <vector>

@interface RXRopeString : NSMutableString {
   @public
    std::unique_ptr<rx::text::Rope> _rope;
}
@end

@implementation RXRopeString
- (instancetype)init {
    if ((self = [super init]))
        _rope = std::make_unique<rx::text::Rope>();
    return self;
}
- (NSUInteger)length {
    return _rope->size();
}
- (unichar)characterAtIndex:(NSUInteger)i {
    return _rope->at(i);
}
- (void)getCharacters:(unichar*)out range:(NSRange)r {
    _rope->read(r.location, r.length, reinterpret_cast<char16_t*>(out));
}
- (void)replaceCharactersInRange:(NSRange)r withString:(NSString*)s {
    const NSUInteger n = s.length;
    const UniChar* direct = n ? CFStringGetCharactersPtr((__bridge CFStringRef)s) : nullptr;
    std::u16string buf;
    if (n && !direct) {
        buf.resize(n);
        [s getCharacters:reinterpret_cast<unichar*>(buf.data()) range:NSMakeRange(0, n)];
    }
    const char16_t* p = direct ? reinterpret_cast<const char16_t*>(direct) : buf.data();
    (void)_rope->replace(r.location, r.length, std::u16string_view(p, n));
}
- (id)copyWithZone:(NSZone*)z {
    const NSUInteger n = _rope->size();
    std::u16string buf(n, u'\0');
    _rope->read(0, n, buf.data());
    return (__bridge_transfer NSString*)CFStringCreateWithCharacters(
        nullptr, reinterpret_cast<const UniChar*>(buf.data()), (CFIndex)n);
}
@end

static constexpr NSUInteger k_big_text = 64 * 1024;
static constexpr double k_rebase = 1 << 20;

struct EditRow {
    CFRange range;
    CTLineRef line;
    CGFloat width;
};

@interface RXEditLines : RXLayer {
   @public
    NSArray* _rows;
    CGFloat _lh, _ascent, _x;
}
@end
@implementation RXEditLines
- (void)drawInContext:(CGContextRef)ctx {
    if (!self.contentsAreFlipped) {
        CGContextTranslateCTM(ctx, 0, self.bounds.size.height);
        CGContextScaleCTM(ctx, 1, -1);
    }
    CGContextSetTextMatrix(ctx, CGAffineTransformMakeScale(1, -1));
    const CGFloat px = self.contentsScale ?: 1;
    NSInteger k = 0;
    for (id line in _rows) {
        if (line != NSNull.null) {
            CGContextSetTextPosition(ctx, _x, round((k * _lh + _ascent) * px) / px);
            CTLineDraw((__bridge CTLineRef)line, ctx);
        }
        k++;
    }
}
@end

struct EditPara {
    NSUInteger start = 0, len = 0;
    std::vector<EditRow> rows;
    CGFloat y = 0;
    RXEditLines* layer = nil;
    uint64_t colors = 0;
};

@interface RXEditLayer : RXLayer
@end
@implementation RXEditLayer
@end

@interface RXEditor () {
   @public
    RXRopeString* _text;
    NSUInteger _anchor, _caret;
    NSRange _marked;
    NSUInteger _told_caret;
    NSRange _told_sel;
    NSString* _mark_was;
    std::deque<EditPara> _paras;
    RXLayer* _content;
    std::vector<CALayer*> _spare;
    std::vector<CALayer*> _sel_layers;
    bool _dirty;
    CGFloat _laid_w;
    CGFloat _goal_x;
    CGFloat _scroll_x, _view_y;
    NSUInteger _top_start;
    CGFloat _top_into;
    std::unique_ptr<rx::text::Highlighter> _hl;
    const void* _hl_lang;
    bool _hl_guessed;
    int _hl_scan;
    NSArray<NSColor*>* _token_cols;
    bool _token_plain[static_cast<int>(rx::text::Token::count_)];
    std::vector<rx::text::TokenList::Run> _runs;
    NSUInteger _runs_from, _runs_len;
    bool _runs_dirty;
    CALayer *_caret_layer, *_knob;
    int _knob_fade;
    bool _knob_drag;
    int _tell_gen;
    NSMutableArray<NSString*>* _sent;
    struct Step {
        NSRange range;
        NSString *was, *now;
        NSUInteger sel_from, sel_to;
        double at;
    };
    std::vector<Step> _undo, _redo;
}
@end

static void release_para(RXEditor* e, EditPara& p) {
    for (EditRow& r : p.rows)
        if (r.line)
            CFRelease(r.line);
    p.rows.clear();
    if (p.layer) {
        p.layer.hidden = YES;
        e->_spare.push_back(p.layer);
        p.layer = nil;
    }
}

static void release_paras(RXEditor* e) {
    for (EditPara& p : e->_paras)
        release_para(e, p);
    e->_paras.clear();
}

@interface RXEditor () {
    __weak RXNode* _w_node;
}
@end
@interface RXEditor () {
    __weak id _w_host;
}
@end
@implementation RXEditor

- (id)host {
    return _w_host;
}
- (void)setHost:(id)v {
    _w_host = v;
}
- (RXNode*)node {
    return _w_node;
}
- (void)setNode:(RXNode*)v {
    _w_node = v;
}
- (instancetype)initMultiline:(bool)multi {
    if (!(self = [super init]))
        return nil;
    _multiline = multi;
    _text = [RXRopeString new];
    _marked = NSMakeRange(NSNotFound, 0);
    _editable = YES;
    _goal_x = NAN;
    _dirty = true;
    _wrap = true;
    _font = [NSFont systemFontOfSize:13];
    _color = NSColor.whiteColor;
    _inset = multi ? NSMakeSize(7, 4) : NSMakeSize(2, 2);
    RXEditLayer* l = [RXEditLayer layer];
    l.masksToBounds = YES;
    _layer = l;
    _content = [RXLayer layer];
    [l addSublayer:_content];
    _caret_layer = [RXLayer layer];
    _caret_layer.hidden = YES;
    _caret_layer.zPosition = 2;
    [l addSublayer:_caret_layer];
    if (multi) {
        _knob = [RXLayer layer];
        _knob.opacity = 0;
        _knob.cornerRadius = 1.5;
        _knob.zPosition = 3;
        [l addSublayer:_knob];
    }
    _runs_dirty = true;
    return self;
}

- (void)dealloc {
    release_paras(self);
}

- (NSString*)text {
    return [_text copy];
}
- (NSRange)selection {
    NSUInteger a = MIN(_anchor, _caret), b = MAX(_anchor, _caret);
    return NSMakeRange(a, b - a);
}
- (NSRange)marked {
    return _marked;
}
- (NSString*)substring:(NSRange)r {
    if (r.location >= _text.length)
        return nil;
    r.length = MIN(r.length, _text.length - r.location);
    return [_text substringWithRange:r];
}

- (CGFloat)lineHeight {
    return line_height(_font);
}

- (NSUInteger)piece {
    return _wrap ? 4096 : 1024;
}

static NSUInteger piece_end(RXEditor* e, NSUInteger start) {
    if (!e->_multiline)
        return e->_text->_rope->size();
    auto& rope = *e->_text->_rope;
    const NSUInteger line_end = rope.next_line(start), piece = e.piece;
    if (line_end - start <= piece)
        return line_end;
    NSUInteger end = start + piece;
    if (CFStringIsSurrogateLowCharacter(rope.at(end)))
        end--;
    return end;
}

static NSUInteger para_start_of(RXEditor* e, NSUInteger i) {
    if (!e->_multiline)
        return 0;
    auto& rope = *e->_text->_rope;
    NSUInteger start = rope.line_start(rope.line_of(i));
    if (i - start < e.piece)
        return start;
    for (;;) {
        NSUInteger end = piece_end(e, start);
        if (i < end || end <= start)
            return start;
        start = end;
    }
}

static bool is_last(RXEditor* e, const EditPara& p) {
    const NSUInteger end = p.start + p.len, n = e->_text->_rope->size();
    if (end < n)
        return false;
    return !p.len || !e->_multiline || e->_text->_rope->at(n - 1) != u'\n';
}

- (void)syncLang {
    const void* lang = _lang ? _lang() : nullptr;
    if (lang == _hl_lang && (lang != nullptr) == (_hl != nullptr))
        return;
    _hl_lang = lang;
    _hl.reset();
    if (lang) {
        _hl = std::make_unique<rx::text::Highlighter>(*static_cast<const rx::text::Lang*>(lang), *_text->_rope);
        [self scheduleScan];
    }
    _runs_dirty = true;
}

static constexpr size_t k_scan_slice = 256 * 1024;
static constexpr size_t k_scan_jump = 16 * 1024 * 1024;
- (void)scheduleScan {
    if (!_hl || _hl->done())
        return;
    const int gen = ++_hl_scan;
    __weak RXEditor* weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        RXEditor* e = weak;
        if (e)
            [e scanSlice:gen];
    });
}
- (void)scanSlice:(int)gen {
    if (gen != _hl_scan || !_hl)
        return;
    if (_hl->step(k_scan_slice))
        return [self scheduleScan];
    if (_hl_guessed || _hl->take_changed()) {
        _hl_guessed = false;
        _runs_dirty = true;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [self recolor];
        [CATransaction commit];
    }
}

- (void)lexNear:(NSUInteger)at {
    if (!_hl)
        return;
    const NSUInteger n = _text.length;
    if (!_runs_dirty && at >= _runs_from && (at + 4096 <= _runs_from + _runs_len || _runs_from + _runs_len == n))
        return;
    const NSUInteger from = at > 16384 ? at - 16384 : 0, to = MIN(n, at + 65536);
    if (!_token_cols && _token_colors) {
        _token_cols = _token_colors();
        for (NSUInteger k = 0; k < static_cast<NSUInteger>(rx::text::Token::count_); k++)
            _token_plain[k] = k >= _token_cols.count || [_token_cols[k] isEqual:_color];
    }
    _runs.clear();
    const bool exact =
        _hl->tokens(from, to, k_scan_jump, &_runs, [](void* c, rx::text::Token kind, uint32_t a, uint32_t size) {
            static_cast<std::vector<rx::text::TokenList::Run>*>(c)->push_back({a, size, kind});
        });
    _hl_guessed = _hl_guessed || !exact;
    _runs_from = from, _runs_len = to - from;
    _runs_dirty = false;
}

- (uint64_t)colorInto:(NSMutableAttributedString*)a start:(NSUInteger)start len:(NSUInteger)len {
    uint64_t h = 14695981039346656037ull;
    if (!_hl || !len)
        return h;
    [self lexNear:start];
    size_t lo = 0, hi = _runs.size();
    while (lo < hi) {
        const size_t mid = (lo + hi) / 2;
        if (_runs[mid].at + _runs[mid].len + _runs_from <= start)
            lo = mid + 1;
        else
            hi = mid;
    }
    for (size_t k = lo; k < _runs.size(); k++) {
        const NSUInteger at = _runs[k].at + _runs_from;
        if (at >= start + len)
            break;
        const NSUInteger kind = static_cast<NSUInteger>(_runs[k].kind);
        if (_token_plain[kind])
            continue;
        const NSUInteger from = MAX(at, start), to = MIN(at + _runs[k].len, start + len);
        NSColor* c = _token_cols[kind];
        if (a)
            [a addAttribute:(id)kCTForegroundColorAttributeName
                      value:(id)c.CGColor
                      range:NSMakeRange(from - start, to - from)];
        h = (h ^ (from - start)) * 1099511628211ull;
        h = (h ^ (to - start)) * 1099511628211ull;
        h = (h ^ c.hash) * 1099511628211ull;
    }
    return h;
}

- (void)typeset:(EditPara&)p {
    for (EditRow& r : p.rows)
        if (r.line)
            CFRelease(r.line);
    p.rows.clear();
    const CGFloat w = _multiline && _wrap ? MAX(1, _layer.bounds.size.width - 2 * _inset.width) : 1e7;
    NSString* s = p.len ? [_text substringWithRange:NSMakeRange(p.start, p.len)] : @"";
    if (_secure && s.length)
        s = secure_dots(s, true);
    if (!s.length && !_text.length && _placeholder.length && !_marked.length) {
        NSAttributedString* a = [[NSAttributedString alloc]
            initWithString:_placeholder
                attributes:@{
                    (id)kCTFontAttributeName: _font,
                    (id)kCTForegroundColorAttributeName: (id)[_color colorWithAlphaComponent:0.4].CGColor
                }];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);
        p.rows.push_back({CFRangeMake(0, 0), line, CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr)});
    } else if (s.length) {
        NSMutableAttributedString* a = [[NSMutableAttributedString alloc]
            initWithString:s
                attributes:@{(id)kCTFontAttributeName: _font, (id)kCTForegroundColorAttributeName: (id)_color.CGColor}];
        p.colors = [self colorInto:a start:p.start len:p.len];
        if (_marked.location != NSNotFound && NSMaxRange(_marked) <= _text.length) {
            NSRange in = NSIntersectionRange(_marked, NSMakeRange(p.start, p.len));
            if (in.length)
                [a addAttribute:(id)kCTUnderlineStyleAttributeName
                          value:@(kCTUnderlineStyleSingle)
                          range:NSMakeRange(in.location - p.start, in.length)];
        }
        CTTypesetterRef setter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)a);
        CFIndex n = (CFIndex)s.length, at = 0;
        while (at < n) {
            CFIndex count = _multiline && _wrap ? CTTypesetterSuggestLineBreak(setter, at, w) : n - at;
            if (count <= 0)
                count = 1;
            CTLineRef line = CTTypesetterCreateLine(setter, CFRangeMake(at, count));
            p.rows.push_back(
                {CFRangeMake(at, count), line, CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr)});
            at += count;
        }
        CFRelease(setter);
    }
    if (p.rows.empty())
        p.rows.push_back({CFRangeMake(0, 0), nullptr, 0});
    [self showPara:p];
}

- (void)showPara:(EditPara&)p {
    RXEditLines* l = p.layer;
    if (!l)
        return;
    CTFontRef ct = (__bridge CTFontRef)_font;
    const CGFloat lh = self.lineHeight;
    NSMutableArray* rows = [NSMutableArray arrayWithCapacity:p.rows.size()];
    CGFloat most = 0;
    bool any = false;
    for (const EditRow& r : p.rows) {
        [rows addObject:r.line ? (__bridge id)r.line : (id)NSNull.null];
        most = MAX(most, r.width);
        any = any || r.line;
    }
    l->_rows = rows;
    l->_lh = lh;
    l->_ascent = CTFontGetAscent(ct) + CTFontGetLeading(ct) / 2;
    const bool field = !_multiline;
    l->_x = field ? _inset.width - _scroll_x : 0;
    CGRect f = field ? CGRectMake(-_inset.width, p.y, _layer.bounds.size.width, lh)
                     : CGRectMake(0, p.y, MIN(ceil(most) + 2, 8000), (CGFloat)p.rows.size() * lh);
    if (!CGRectEqualToRect(l.frame, f))
        l.frame = f;
    if (l.contentsScale != _layer.contentsScale)
        l.contentsScale = _layer.contentsScale;
    l.hidden = !any;
    [l setNeedsDisplay];
}

- (RXEditLines*)freshLayer {
    if (!_spare.empty()) {
        RXEditLines* l = (RXEditLines*)_spare.back();
        _spare.pop_back();
        return l;
    }
    RXEditLines* l = [RXEditLines layer];
    [_content addSublayer:l];
    return l;
}

- (EditPara)makePara:(NSUInteger)start y:(CGFloat)y {
    EditPara p;
    p.start = start;
    p.len = piece_end(self, start) - start;
    p.y = y;
    p.layer = [self freshLayer];
    [self typeset:p];
    return p;
}

- (CGFloat)bottomOf:(const EditPara&)p {
    return p.y + (CGFloat)p.rows.size() * self.lineHeight;
}

- (void)fill {
    const CGFloat h = MAX(_layer.bounds.size.height, 64), over = MAX(h, 200);
    if (_paras.empty())
        _paras.push_back([self makePara:para_start_of(self, MIN(_top_start, _text.length)) y:_view_y]);
    while ([self bottomOf:_paras.back()] < _view_y + h + over && !is_last(self, _paras.back())) {
        const EditPara& b = _paras.back();
        const NSUInteger next = b.start + b.len;
        const CGFloat y = [self bottomOf:b];
        _paras.push_back([self makePara:next y:y]);
    }
    while (_paras.front().y > _view_y - over && _paras.front().start > 0) {
        const NSUInteger first = _paras.front().start;
        EditPara p = [self makePara:para_start_of(self, first - 1) y:0];
        p.y = _paras.front().y - (CGFloat)p.rows.size() * self.lineHeight;
        [self showPara:p];
        _paras.push_front(std::move(p));
    }
    while (_paras.size() > 1 && [self bottomOf:_paras.front()] < _view_y - 2 * over)
        release_para(self, _paras.front()), _paras.pop_front();
    while (_paras.size() > 1 && _paras.back().y > _view_y + h + 2 * over)
        release_para(self, _paras.back()), _paras.pop_back();
}

- (void)clamp {
    if (_paras.empty())
        return;
    const CGFloat h = _layer.bounds.size.height;
    if (is_last(self, _paras.back()))
        _view_y = MIN(_view_y, [self bottomOf:_paras.back()] + 2 * _inset.height - h);
    if (_paras.front().start == 0)
        _view_y = MAX(_view_y, _paras.front().y);
    _view_y = round(_view_y);
}

- (void)moveContent {
    if (fabs(_view_y) > k_rebase) {
        const CGFloat by = _view_y;
        for (EditPara& p : _paras)
            p.y -= by;
        for (EditPara& p : _paras)
            p.layer.frame =
                CGRectMake(p.layer.frame.origin.x, p.y, p.layer.frame.size.width, p.layer.frame.size.height);
        _view_y = 0;
    }
    CGRect f = CGRectMake(_multiline ? _inset.width - _scroll_x : _inset.width, _inset.height - _view_y, 1, 1);
    if (!CGRectEqualToRect(_content.frame, f))
        _content.frame = f;
}

- (size_t)paraOf:(NSUInteger)i {
    [self layoutIfNeeded];
    i = MIN(i, _text.length);
    const NSUInteger n = _text.length;
    auto contains = [&](const EditPara& p) {
        return i >= p.start && (i < p.start + p.len || (i == p.start + p.len && i == n && is_last(self, p)));
    };
    if (_paras.empty() || i < _paras.front().start
        || (!contains(_paras.back()) && i >= _paras.back().start + _paras.back().len)) {
        if (!_paras.empty() && i >= _paras.back().start + _paras.back().len && i - _paras.back().start < 8192) {
            while (!contains(_paras.back()) && !is_last(self, _paras.back())) {
                const EditPara& b = _paras.back();
                const NSUInteger next = b.start + b.len;
                const CGFloat y = [self bottomOf:b];
                _paras.push_back([self makePara:next y:y]);
            }
        } else if (!_paras.empty() && i < _paras.front().start && _paras.front().start - i < 8192) {
            while (i < _paras.front().start) {
                EditPara p = [self makePara:para_start_of(self, _paras.front().start - 1) y:0];
                p.y = _paras.front().y - (CGFloat)p.rows.size() * self.lineHeight;
                [self showPara:p];
                _paras.push_front(std::move(p));
            }
        } else {
            release_paras(self);
            _top_start = para_start_of(self, i);
            _view_y = 0;
            _paras.push_back([self makePara:_top_start y:0]);
        }
    }
    size_t lo = 0, hi = _paras.size() - 1;
    while (lo < hi) {
        size_t mid = (lo + hi + 1) / 2;
        if (_paras[mid].start <= i)
            lo = mid;
        else
            hi = mid - 1;
    }
    return lo;
}

static size_t row_of(const EditPara& p, NSUInteger i) {
    const CFIndex at = (CFIndex)(i - p.start);
    for (size_t k = 0; k < p.rows.size(); k++) {
        const CFRange r = p.rows[k].range;
        if (at < r.location + r.length)
            return k;
    }
    return p.rows.size() - 1;
}

static CGFloat x_of(const EditPara& p, size_t row, NSUInteger i) {
    if (row >= p.rows.size() || !p.rows[row].line || p.rows[row].range.length == 0)
        return 0;
    return CTLineGetOffsetForStringIndex(p.rows[row].line, (CFIndex)(i - p.start), nullptr);
}

- (void)layoutIfNeeded {
    const CGFloat w = _multiline && _wrap ? MAX(1, _layer.bounds.size.width - 2 * _inset.width) : 1e7;
    if (!_dirty && w == _laid_w && !_paras.empty())
        return;
    if (!_paras.empty()) {
        const CGFloat lh = self.lineHeight;
        for (const EditPara& p : _paras) {
            if (p.y + (CGFloat)p.rows.size() * lh > _view_y) {
                _top_start = p.start;
                _top_into = _view_y - p.y;
                break;
            }
        }
    }
    _dirty = false;
    _laid_w = w;
    _runs_dirty = true;
    [self syncLang];
    release_paras(self);
    _view_y = _top_into;
    _paras.push_back([self makePara:para_start_of(self, MIN(_top_start, _text.length)) y:0]);
    [self fill];
    [self clamp];
    [self fill];
    [self moveContent];
}

- (bool)wholeAtHand {
    return !_paras.empty() && _paras.front().start == 0 && is_last(self, _paras.back());
}
- (CGFloat)contentHeight {
    [self layoutIfNeeded];
    const CGFloat lh = self.lineHeight;
    if ([self wholeAtHand])
        return [self bottomOf:_paras.back()] - _paras.front().y + 2 * _inset.height;
    size_t rows = 0;
    for (const EditPara& p : _paras)
        rows += p.rows.size();
    const double per = (double)rows / MAX((size_t)1, _paras.size());
    return (CGFloat)(per * (double)_text->_rope->lines()) * lh + 2 * _inset.height;
}
- (CGFloat)maxScroll {
    return _multiline ? MAX(0, self.contentHeight - _layer.bounds.size.height) : 0;
}

- (NSUInteger)indexAt:(CGPoint)p {
    [self layoutIfNeeded];
    if (_paras.empty())
        return 0;
    const CGFloat lh = self.lineHeight, y = p.y - _inset.height + _view_y;
    size_t lo = 0, hi = _paras.size() - 1;
    while (lo < hi) {
        size_t mid = (lo + hi + 1) / 2;
        if (_paras[mid].y <= y)
            lo = mid;
        else
            hi = mid - 1;
    }
    const EditPara& para = _paras[lo];
    const size_t k = y <= para.y ? 0 : MIN(para.rows.size() - 1, (size_t)((y - para.y) / lh));
    const EditRow& l = para.rows[k];
    if (!l.line || !para.len)
        return para.start + (NSUInteger)l.range.location;
    CFIndex i = CTLineGetStringIndexForPosition(l.line, CGPointMake(p.x - _inset.width + _scroll_x, 0));
    const CFIndex end = l.range.location + l.range.length;
    if (i >= end && l.range.length > 0 && [_text characterAtIndex:para.start + (NSUInteger)end - 1] == '\n')
        i = end - 1;
    return para.start + (NSUInteger)MAX(l.range.location, MIN(i, end));
}

- (CGRect)caretRect:(NSUInteger)i {
    const size_t pk = [self paraOf:i];
    const EditPara& p = _paras[pk];
    const size_t k = row_of(p, i);
    const CGFloat lh = self.lineHeight;
    const CGFloat top = p.y + (CGFloat)k * lh + _inset.height - _view_y;
    const CGFloat x = x_of(p, k, i) + _inset.width - _scroll_x;
    return CGRectMake(round(x), top, 1.5, lh);
}

- (void)reveal {
    [self layoutIfNeeded];
    const CGRect b = _layer.bounds;
    if (b.size.width <= 0 || b.size.height <= 0)
        return;
    const size_t pk = [self paraOf:_caret];
    const EditPara& p = _paras[pk];
    const size_t k = row_of(p, _caret);
    if (_multiline) {
        const CGFloat lh = self.lineHeight, top = p.y + (CGFloat)k * lh, view_h = b.size.height - 2 * _inset.height;
        if (top < _view_y)
            _view_y = top;
        else if (top + lh > _view_y + view_h)
            _view_y = top + lh - view_h;
        [self fill];
        [self clamp];
        [self fill];
    }
    if (!_multiline || !_wrap) {
        const EditPara& q = _paras[[self paraOf:_caret]];
        const size_t r = row_of(q, _caret);
        const CGFloat was = _scroll_x;
        const CGFloat x = x_of(q, r, _caret), view_w = b.size.width - 2 * _inset.width;
        const CGFloat total = r < q.rows.size() ? q.rows[r].width : 0;
        if (x < _scroll_x)
            _scroll_x = MAX(0, x - view_w / 3);
        else if (x > _scroll_x + view_w - 2)
            _scroll_x = x - view_w + 2;
        _scroll_x = MAX(0, MIN(_scroll_x, MAX(0, (_multiline ? MAX(total, x) : total) - view_w + 2)));
        if (!_multiline && was != _scroll_x)
            [self showPara:_paras.front()];
    }
    [self moveContent];
}

- (void)tellSelection {
    RXNode* n = _w_node;
    if (!n || !n.doc.ctx || !flag(n, @"wantsCursor", false))
        return;
    const NSRange sel = self.selection;
    if (_told_caret == _caret && NSEqualRanges(_told_sel, sel))
        return;
    _told_caret = _caret, _told_sel = sel;
    doc_call(n.doc, @"update", @[
        @(n.uid),
        @{@"cursorPosition": @(_caret), @"selectionStart": @(sel.location), @"selectionEnd": @(NSMaxRange(sel))}
    ]);
}
- (void)refresh {
    [self tellSelection];
    [self layoutIfNeeded];
    [self fill];
    if (_multiline) {
        [self clamp];
        [self fill];
    }
    [self moveContent];
    [self placeSelection];
    [self placeCaret];
}

- (void)positionCaret {
    bool show = _focused && _caret == _anchor && _editable;
    _caret_layer.hidden = !show;
    if (show) {
        const NSUInteger c = _caret;
        if (_paras.empty() || c < _paras.front().start || c > _paras.back().start + _paras.back().len)
            _caret_layer.hidden = YES;
        else
            _caret_layer.frame = [self caretRect:c];
        _caret_layer.backgroundColor = _color.CGColor;
    }
}

- (void)placeCaret {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self positionCaret];
    if (_focused && _caret == _anchor && _editable) {
        [_caret_layer removeAnimationForKey:@"blink"];
        CAKeyframeAnimation* a = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        a.values = @[@1, @1, @0, @0];
        a.keyTimes = @[@0, @0.5, @0.5, @1];
        a.calculationMode = kCAAnimationDiscrete;
        a.duration = 1.06;
        a.repeatCount = HUGE_VALF;
        a.beginTime = CACurrentMediaTime() + 0.5;
        a.fillMode = kCAFillModeBackwards;
        [_caret_layer addAnimation:a forKey:@"blink"];
    }
    [CATransaction commit];
}

- (void)placeSelection {
    size_t used = 0;
    NSRange sel = self.selection;
    if (sel.length) {
        NSColor* a = ui_accent() ?: NSColor.controlAccentColor;
        CGColorRef fill = [a colorWithAlphaComponent:_focused ? 0.35 : 0.2].CGColor;
        const CGFloat lh = self.lineHeight;
        for (const EditPara& p : _paras) {
            if (p.start + p.len < sel.location)
                continue;
            if (p.start > NSMaxRange(sel))
                break;
            for (size_t k = 0; k < p.rows.size(); k++) {
                const CFRange r = p.rows[k].range;
                NSUInteger ls = p.start + (NSUInteger)r.location, le = ls + (NSUInteger)r.length;
                if (le < sel.location || ls > NSMaxRange(sel) || (le == sel.location && r.length))
                    continue;
                NSUInteger from = MAX(ls, sel.location), to = MIN(le, NSMaxRange(sel));
                CGFloat x0 = x_of(p, k, from);
                bool through = NSMaxRange(sel) >= le && le > ls && [_text characterAtIndex:le - 1] == '\n';
                CGFloat x1 = through ? x_of(p, k, le - 1) + 6 : x_of(p, k, to);
                if (x1 <= x0 && !through)
                    continue;
                CALayer* l;
                if (used < _sel_layers.size()) {
                    l = _sel_layers[used];
                } else {
                    l = [RXLayer layer];
                    l.zPosition = -1;
                    [_content addSublayer:l];
                    _sel_layers.push_back(l);
                }
                used++;
                l.hidden = NO;
                l.backgroundColor = fill;
                l.frame = CGRectMake(x0 - (_multiline ? 0 : _scroll_x), p.y + (CGFloat)k * lh, MAX(1, x1 - x0), lh);
            }
        }
    }
    for (size_t k = used; k < _sel_layers.size(); k++)
        _sel_layers[k].hidden = YES;
}

- (void)recolor {
    if (!_hl)
        return;
    for (EditPara& p : _paras) {
        if (!p.len)
            continue;
        if ([self colorInto:nil start:p.start len:p.len] != p.colors)
            [self typeset:p];
    }
}

- (void)splice:(NSRange)r with:(NSString*)s {
    const NSUInteger at = r.location, removed = r.length, added = s.length;
    const NSUInteger n0 = _text.length;
    _runs_dirty = true;
    if (_hl)
        _hl->edited(at, removed, added);
    [self scheduleScan];
    if (_paras.empty() || _dirty) {
        [_text replaceCharactersInRange:r withString:s];
        return;
    }
    const long delta = (long)added - (long)removed;
    const EditPara& last = _paras.back();
    if (at + removed < _paras.front().start) {
        [_text replaceCharactersInRange:r withString:s];
        for (EditPara& p : _paras)
            p.start = (NSUInteger)((long)p.start + delta);
        return;
    }
    if (at > last.start + last.len || (at == last.start + last.len && at != n0)) {
        [_text replaceCharactersInRange:r withString:s];
        return;
    }
    if (at < _paras.front().start) {
        [_text replaceCharactersInRange:r withString:s];
        release_paras(self);
        _top_start = para_start_of(self, at);
        _top_into = 0;
        _view_y = 0;
        return;
    }
    size_t a = 0, b = 0;
    for (size_t k = 0; k < _paras.size(); k++)
        if (_paras[k].start <= at)
            a = k;
    b = a;
    const NSUInteger stop = at + removed;
    while (b + 1 < _paras.size() && _paras[b + 1].start <= stop)
        b++;
    if (a > 0 && at == _paras[a].start && _multiline) {
        if ([_text characterAtIndex:at - 1] != '\n')
            a--;
    }
    while (b + 1 < _paras.size()) {
        const EditPara& e = _paras[b];
        const bool ends_broken = e.len && [_text characterAtIndex:e.start + e.len - 1] == '\n';
        if (ends_broken && stop < e.start + e.len)
            break;
        b++;
    }
    const NSUInteger first_start = _paras[a].start;
    const NSUInteger old_end = _paras[b].start + _paras[b].len;
    const CGFloat y0 = _paras[a].y, old_bottom = [self bottomOf:_paras[b]];
    [_text replaceCharactersInRange:r withString:s];
    for (size_t k = a; k <= b; k++)
        release_para(self, _paras[k]);
    _paras.erase(_paras.begin() + (long)a, _paras.begin() + (long)b + 1);
    for (size_t k = a; k < _paras.size(); k++)
        _paras[k].start = (NSUInteger)((long)_paras[k].start + delta);
    const NSUInteger new_end = (NSUInteger)((long)old_end + delta);
    CGFloat y = y0;
    NSUInteger pos = first_start;
    size_t put = a;
    for (;;) {
        EditPara p = [self makePara:pos y:y];
        y += (CGFloat)p.rows.size() * self.lineHeight;
        const NSUInteger next = p.start + p.len;
        const bool last_one = is_last(self, p);
        _paras.insert(_paras.begin() + (long)put, std::move(p));
        put++;
        pos = next;
        if (pos >= new_end || last_one)
            break;
    }
    const CGFloat moved = y - old_bottom;
    if (moved != 0)
        for (size_t k = put; k < _paras.size(); k++) {
            _paras[k].y += moved;
            CGRect f = _paras[k].layer.frame;
            f.origin.y = _paras[k].y;
            _paras[k].layer.frame = f;
        }
    [self recolor];
}

- (void)setText:(NSString*)t {
    t = t ?: @"";
    if (!_multiline)
        t = [[t stringByReplacingOccurrencesOfString:@"\r" withString:@""] stringByReplacingOccurrencesOfString:@"\n"
                                                                                                     withString:@" "];
    if ([_text isEqualToString:t])
        return;
    release_paras(self);
    _top_start = 0, _top_into = 0, _view_y = 0;
    _runs_dirty = true;
    _hl.reset(), _hl_lang = nullptr;
    [_text setString:t];
    _anchor = _caret = t.length;
    _marked = NSMakeRange(NSNotFound, 0);
    _undo.clear(), _redo.clear();
    _dirty = true;
    [self reveal];
    [self refresh];
}

- (void)appendText:(NSString*)s {
    if (!s.length)
        return;
    const NSUInteger n = _text.length;
    bool at_end = false;
    if (!_paras.empty() && is_last(self, _paras.back()))
        at_end = _view_y >= [self bottomOf:_paras.back()] + 2 * _inset.height - _layer.bounds.size.height - 4;
    const bool caret_end = _caret == n && _anchor == n;
    [self splice:NSMakeRange(n, 0) with:s];
    if (caret_end)
        _anchor = _caret = _text.length;
    if (_follow && at_end) {
        (void)[self paraOf:_text.length];
        _view_y = [self bottomOf:_paras.back()] + 2 * _inset.height - _layer.bounds.size.height;
        [self fill];
        [self clamp];
    }
    [self refresh];
    if (_knob && _knob.opacity > 0)
        [self placeKnob];
    [self tellChanged];
}

- (void)adoptRope:(void*)rope highlighter:(void*)hl lang:(const void*)lang {
    release_paras(self);
    _hl.reset(), _hl_lang = nullptr;
    _text->_rope.reset(static_cast<rx::text::Rope*>(rope));
    _hl.reset(static_cast<rx::text::Highlighter*>(hl)), _hl_lang = hl ? lang : nullptr;
    _anchor = _caret = 0;
    _top_start = 0, _top_into = 0, _view_y = 0;
    _runs_dirty = true;
    _marked = NSMakeRange(NSNotFound, 0);
    _undo.clear(), _redo.clear();
    _dirty = true;
    [self refresh];
}

- (void)setWrap:(bool)w {
    if (w == _wrap)
        return;
    _wrap = w;
    _scroll_x = 0;
    _dirty = true;
    [self refresh];
}

- (void)styleChanged {
    _dirty = true;
    _token_cols = nil;
    [self syncLang];
    [self refresh];
}

- (void)setFocused:(bool)f {
    if (_focused == f)
        return;
    _focused = f;
    if (RXNode* n = _w_node)
        focus_changed(n, f);
    if (!f)
        [self unmark];
    [self refresh];
}

- (void)tellChanged {
    if (!_changed)
        return;
    if (!_from_file && _text.length < k_big_text)
        return _changed(self.text);
    int gen = ++_tell_gen;
    __weak RXEditor* weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        RXEditor* e = weak;
        if (e && e->_tell_gen == gen && e.changed)
            e.changed(e.from_file ? @"" : e.text);
    });
}

- (void)noteSent:(NSString*)t {
    if (!_sent)
        _sent = [NSMutableArray array];
    [_sent addObject:t];
    if (_sent.count > 64)
        [_sent removeObjectAtIndex:0];
}
- (bool)isEcho:(NSString*)t {
    for (NSUInteger k = 0; k < _sent.count; k++) {
        if (_sent[k].length == t.length && [_sent[k] isEqualToString:t]) {
            [_sent removeObjectsInRange:NSMakeRange(0, k + 1)];
            return true;
        }
    }
    return false;
}

- (void)replace:(NSRange)r with:(NSString*)s undoable:(bool)undo {
    if (!_editable)
        return;
    r.location = MIN(r.location, _text.length);
    r.length = MIN(r.length, _text.length - r.location);
    if (!_multiline)
        s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (_max_length) {
        const NSUInteger room = _text.length - r.length >= _max_length ? 0 : _max_length - (_text.length - r.length);
        if (s.length > room)
            s = room ? [s substringToIndex:[s rangeOfComposedCharacterSequenceAtIndex:room].location] : @"";
        if (!s.length && !r.length)
            return;
    }
    NSString* was = [_text substringWithRange:r];
    if ([was isEqualToString:s])
        return;
    if (undo) {
        double now = CACurrentMediaTime();
        NSRange sel = self.selection;
        bool typed = s.length == 1 && !r.length && !_undo.empty() && !_undo.back().was.length
            && NSMaxRange(_undo.back().range) == r.location && now - _undo.back().at < 1 && ![s isEqualToString:@"\n"];
        if (typed) {
            Step& st = _undo.back();
            st.now = [st.now stringByAppendingString:s];
            st.range.length += s.length;
            st.at = now;
        } else {
            _undo.push_back({NSMakeRange(r.location, s.length), was, s, sel.location, NSMaxRange(sel), now});
            if (_undo.size() > 500)
                _undo.erase(_undo.begin());
        }
        _redo.clear();
    }
    [self splice:r with:s];
    _anchor = _caret = r.location + s.length;
    _goal_x = NAN;
    [self reveal];
    [self refresh];
    [self tellChanged];
}

- (NSRange)takeBackMarked {
    NSRange m = _marked;
    NSString* was = _mark_was ?: @"";
    _marked = NSMakeRange(NSNotFound, 0);
    _mark_was = nil;
    m.location = MIN(m.location, _text.length);
    m.length = MIN(m.length, _text.length - m.location);
    [self splice:m with:was];
    return NSMakeRange(m.location, was.length);
}

- (void)insert:(NSString*)s {
    NSRange r = _marked.location != NSNotFound ? [self takeBackMarked] : self.selection;
    [self replace:r with:s undoable:true];
}

static unichar pair_closer(unichar c) {
    switch (c) {
    case '(':
        return ')';
    case '[':
        return ']';
    case '{':
        return '}';
    case '"':
    case '\'':
    case '`':
        return c;
    default:
        return 0;
    }
}

- (bool)typePair:(NSString*)s {
    if (s.length != 1 || _marked.location != NSNotFound || !_editable)
        return false;
    const unichar c = [s characterAtIndex:0], close = pair_closer(c);
    const bool quote = close == c;
    const NSRange sel = self.selection;
    if (sel.length) {
        if (!close)
            return false;
        NSString* inside = [_text substringWithRange:sel];
        [self replace:sel with:[NSString stringWithFormat:@"%C%@%C", c, inside, close] undoable:true];
        [self select:sel.location + 1 to:NSMaxRange(sel) + 1];
        return true;
    }
    const NSUInteger at = sel.location;
    const unichar prev = at ? [_text characterAtIndex:at - 1] : 0,
                  next = at < _text.length ? [_text characterAtIndex:at] : 0;
    if (prev == '\\')
        return false;
    if (c == next && (quote || c == ')' || c == ']' || c == '}')) {
        [self select:at + 1 to:at + 1];
        return true;
    }
    if (!close)
        return false;
    if (next && ![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:next]
        && !(next < 128 && strchr(")]},;:", next)))
        return false;
    if (quote) {
        if (prev == '_' || prev == '$' || [NSCharacterSet.alphanumericCharacterSet characterIsMember:prev])
            return false;
        unichar in = 0;
        for (NSUInteger i = [self lineStart:at]; i < at; i++) {
            const unichar x = [_text characterAtIndex:i];
            if (in && x == '\\')
                i++;
            else if (in)
                in = x == in ? 0 : in;
            else if (x == '"' || x == '\'' || x == '`')
                in = x;
        }
        if (in)
            return false;
    }
    [self replace:sel with:[NSString stringWithFormat:@"%C%C", c, close] undoable:true];
    [self select:at + 1 to:at + 1];
    return true;
}

- (void)unmark {
    if (_marked.location == NSNotFound)
        return;
    NSString* s =
        [_text substringWithRange:NSMakeRange(MIN(_marked.location, _text.length),
                                              MIN(_marked.length, _text.length - MIN(_marked.location, _text.length)))];
    NSRange r = [self takeBackMarked];
    if (s.length || r.length)
        [self replace:r with:s undoable:true];
    else
        [self refresh];
}

- (void)setMarked:(NSString*)s selected:(NSRange)sr replacing:(NSRange)rr {
    if (!_editable)
        return;
    if (!s.length && _marked.location != NSNotFound) {
        NSRange back = [self takeBackMarked];
        if (back.length)
            [self replace:back with:@"" undoable:true];
        else
            [self refresh];
        return;
    }
    NSRange r = _marked.location != NSNotFound ? _marked : rr.location != NSNotFound ? rr : self.selection;
    r.location = MIN(r.location, _text.length);
    r.length = MIN(r.length, _text.length - r.location);
    if (_marked.location == NSNotFound)
        _mark_was = [_text substringWithRange:r];
    _marked = s.length ? NSMakeRange(r.location, s.length) : NSMakeRange(NSNotFound, 0);
    [self splice:r with:s];
    if (!s.length)
        _mark_was = nil;
    _anchor = r.location + MIN(sr.location, s.length);
    _caret = _anchor + MIN(sr.length, s.length - MIN(sr.location, s.length));
    [self reveal];
    [self refresh];
}

- (void)select:(NSUInteger)anchor to:(NSUInteger)caret {
    _anchor = MIN(anchor, _text.length);
    _caret = MIN(caret, _text.length);
    [self reveal];
    [self refresh];
}

- (bool)findNext:(NSString*)s backwards:(bool)back {
    if (!s.length)
        return false;
    NSString* all = self.text;
    const NSRange sel = self.selection;
    NSRange r;
    if (back) {
        r = [all rangeOfString:s options:NSBackwardsSearch range:NSMakeRange(0, sel.location)];
        if (r.location == NSNotFound)
            r = [all rangeOfString:s options:NSBackwardsSearch];
    } else {
        const NSUInteger from = MIN(NSMaxRange(sel), all.length);
        r = [all rangeOfString:s options:0 range:NSMakeRange(from, all.length - from)];
        if (r.location == NSNotFound)
            r = [all rangeOfString:s];
    }
    if (r.location == NSNotFound)
        return false;
    [self select:r.location to:NSMaxRange(r)];
    return true;
}

- (void)undo:(bool)redo {
    auto& from = redo ? _redo : _undo;
    auto& to = redo ? _undo : _redo;
    if (from.empty())
        return;
    Step st = from.back();
    from.pop_back();
    NSRange r = redo ? NSMakeRange(st.range.location, st.was.length) : st.range;
    NSString* put = redo ? st.now : st.was;
    [self splice:r with:put];
    to.push_back(st);
    if (redo)
        _anchor = _caret = st.range.location + st.now.length;
    else
        _anchor = st.sel_from, _caret = st.sel_to;
    [self reveal];
    [self refresh];
    [self tellChanged];
}

static NSUInteger cluster_before(NSString* t, NSUInteger i) {
    if (i == 0)
        return 0;
    return [t rangeOfComposedCharacterSequenceAtIndex:i - 1].location;
}
static NSUInteger cluster_after(NSString* t, NSUInteger i) {
    if (i >= t.length)
        return t.length;
    return NSMaxRange([t rangeOfComposedCharacterSequenceAtIndex:i]);
}
static bool word_char(unichar c) {
    return [NSCharacterSet.alphanumericCharacterSet characterIsMember:c] || c == '_';
}
static NSUInteger word_before(NSString* t, NSUInteger i) {
    while (i > 0 && !word_char([t characterAtIndex:i - 1]))
        i--;
    while (i > 0 && word_char([t characterAtIndex:i - 1]))
        i--;
    return i;
}
static NSUInteger word_after(NSString* t, NSUInteger i) {
    NSUInteger n = t.length;
    while (i < n && !word_char([t characterAtIndex:i]))
        i++;
    while (i < n && word_char([t characterAtIndex:i]))
        i++;
    return i;
}
- (NSRange)wordAt:(NSUInteger)i {
    NSUInteger n = _text.length;
    if (!n)
        return NSMakeRange(0, 0);
    if (i >= n)
        i = n - 1;
    if (!word_char([_text characterAtIndex:i]))
        return [_text rangeOfComposedCharacterSequenceAtIndex:i];
    NSUInteger a = i, b = i;
    while (a > 0 && word_char([_text characterAtIndex:a - 1]))
        a--;
    while (b < n && word_char([_text characterAtIndex:b]))
        b++;
    return NSMakeRange(a, b - a);
}
- (NSRange)paragraphAt:(NSUInteger)i {
    return [_text paragraphRangeForRange:NSMakeRange(MIN(i, _text.length), 0)];
}
- (NSUInteger)lineStart:(NSUInteger)i {
    const EditPara& p = _paras[[self paraOf:i]];
    return p.start + (NSUInteger)p.rows[row_of(p, i)].range.location;
}
- (NSUInteger)lineEnd:(NSUInteger)i {
    const EditPara& p = _paras[[self paraOf:i]];
    const CFRange r = p.rows[row_of(p, i)].range;
    NSUInteger s = p.start + (NSUInteger)r.location, e = s + (NSUInteger)r.length;
    if (e > s && [_text characterAtIndex:e - 1] == '\n')
        e--;
    else if (e < _text.length)
        e = cluster_before(_text, e);
    return e;
}
- (NSUInteger)vertical:(int)d from:(NSUInteger)i {
    size_t pk = [self paraOf:i];
    size_t k = row_of(_paras[pk], i);
    if (isnan(_goal_x))
        _goal_x = x_of(_paras[pk], k, i);
    for (; d < 0; d++) {
        if (k > 0) {
            k--;
            continue;
        }
        if (_paras[pk].start == 0)
            return 0;
        const NSUInteger before = _paras[pk].start - 1;
        pk = [self paraOf:before];
        k = _paras[pk].rows.size() - 1;
    }
    for (; d > 0; d--) {
        if (k + 1 < _paras[pk].rows.size()) {
            k++;
            continue;
        }
        if (is_last(self, _paras[pk]))
            return _text.length;
        const NSUInteger next = _paras[pk].start + _paras[pk].len;
        pk = [self paraOf:next];
        k = 0;
    }
    const EditPara& p = _paras[pk];
    const EditRow& l = p.rows[k];
    if (!l.line || !p.len)
        return p.start + (NSUInteger)l.range.location;
    CFIndex j = CTLineGetStringIndexForPosition(l.line, CGPointMake(_goal_x, 0));
    const CFIndex end = l.range.location + l.range.length;
    if (j >= end && l.range.length && [_text characterAtIndex:p.start + (NSUInteger)end - 1] == '\n')
        j = end - 1;
    return p.start + (NSUInteger)MAX(l.range.location, MIN(j, end));
}

- (void)moveTo:(NSUInteger)i extend:(bool)extend keepGoal:(bool)keep {
    if (!keep)
        _goal_x = NAN;
    _caret = MIN(i, _text.length);
    if (!extend)
        _anchor = _caret;
    [self reveal];
    [self refresh];
}

- (bool)perform:(SEL)sel {
    if (_command && _command(sel))
        return true;
    NSString* s = NSStringFromSelector(sel);
    bool extend = [s hasSuffix:@"AndModifySelection:"];
    if (extend)
        s = [[s substringToIndex:s.length - @"AndModifySelection:".length] stringByAppendingString:@":"];
    NSRange sel_r = self.selection;
    NSUInteger c = _caret;
    auto move = [&](NSUInteger to, bool keep = false) { [self moveTo:to extend:extend keepGoal:keep]; };
    if ([s isEqualToString:@"moveLeft:"] || [s isEqualToString:@"moveBackward:"]) {
        if (!extend && sel_r.length)
            return move(sel_r.location), true;
        return move(cluster_before(_text, c)), true;
    }
    if ([s isEqualToString:@"moveRight:"] || [s isEqualToString:@"moveForward:"]) {
        if (!extend && sel_r.length)
            return move(NSMaxRange(sel_r)), true;
        return move(cluster_after(_text, c)), true;
    }
    if ([s isEqualToString:@"moveWordLeft:"] || [s isEqualToString:@"moveWordBackward:"])
        return move(word_before(_text, c)), true;
    if ([s isEqualToString:@"moveWordRight:"] || [s isEqualToString:@"moveWordForward:"])
        return move(word_after(_text, c)), true;
    if ([s isEqualToString:@"moveUp:"])
        return move(_multiline ? [self vertical:-1 from:c] : 0, _multiline), true;
    if ([s isEqualToString:@"moveDown:"])
        return move(_multiline ? [self vertical:1 from:c] : _text.length, _multiline), true;
    if ([s isEqualToString:@"moveToBeginningOfLine:"] || [s isEqualToString:@"moveToLeftEndOfLine:"])
        return move([self lineStart:c]), true;
    if ([s isEqualToString:@"moveToEndOfLine:"] || [s isEqualToString:@"moveToRightEndOfLine:"])
        return move([self lineEnd:c]), true;
    if ([s isEqualToString:@"moveToBeginningOfParagraph:"] || [s isEqualToString:@"moveParagraphBackward:"])
        return move([self paragraphAt:c].location), true;
    if ([s isEqualToString:@"moveToEndOfParagraph:"] || [s isEqualToString:@"moveParagraphForward:"]) {
        NSRange p = [self paragraphAt:c];
        NSUInteger e = NSMaxRange(p);
        if (e > p.location && [_text characterAtIndex:e - 1] == '\n')
            e--;
        return move(e), true;
    }
    if ([s isEqualToString:@"moveToBeginningOfDocument:"] || [s isEqualToString:@"scrollToBeginningOfDocument:"])
        return move(0), true;
    if ([s isEqualToString:@"moveToEndOfDocument:"] || [s isEqualToString:@"scrollToEndOfDocument:"])
        return move(_text.length), true;
    if ([s isEqualToString:@"pageUp:"] || [s isEqualToString:@"scrollPageUp:"]) {
        int rows = MAX(1, (int)(_layer.bounds.size.height / self.lineHeight) - 1);
        return move(_multiline ? [self vertical:-rows from:c] : 0, true), true;
    }
    if ([s isEqualToString:@"pageDown:"] || [s isEqualToString:@"scrollPageDown:"]) {
        int rows = MAX(1, (int)(_layer.bounds.size.height / self.lineHeight) - 1);
        return move(_multiline ? [self vertical:rows from:c] : _text.length, true), true;
    }
    if ([s isEqualToString:@"selectAll:"])
        return [self select:0 to:_text.length], true;
    if ([s isEqualToString:@"selectWord:"]) {
        NSRange w = [self wordAt:c];
        return [self select:w.location to:NSMaxRange(w)], true;
    }
    if ([s isEqualToString:@"selectLine:"] || [s isEqualToString:@"selectParagraph:"]) {
        NSRange p = [self paragraphAt:c];
        return [self select:p.location to:NSMaxRange(p)], true;
    }
    auto erase = [&](NSUInteger from, NSUInteger to) {
        if (sel_r.length)
            [self replace:sel_r with:@"" undoable:true];
        else if (to > from)
            [self replace:NSMakeRange(from, to - from) with:@"" undoable:true];
        return true;
    };
    if ([s isEqualToString:@"deleteBackward:"] ||
        [s isEqualToString:@"deleteBackwardByDecomposingPreviousCharacter:"]) {
        if (RXNode* n = _w_node; n && !sel_r.length && c && c < _text.length && flag(n, P::autoPairs, false)) {
            const unichar closer = pair_closer([_text characterAtIndex:c - 1]);
            if (closer && closer == [_text characterAtIndex:c])
                return erase(c - 1, c + 1);
        }
        return erase(cluster_before(_text, c), c);
    }
    if ([s isEqualToString:@"deleteForward:"])
        return erase(c, cluster_after(_text, c));
    if ([s isEqualToString:@"deleteWordBackward:"])
        return erase(word_before(_text, c), c);
    if ([s isEqualToString:@"deleteWordForward:"])
        return erase(c, word_after(_text, c));
    if ([s isEqualToString:@"deleteToBeginningOfLine:"] || [s isEqualToString:@"deleteToBeginningOfParagraph:"])
        return erase(c == [self lineStart:c] ? cluster_before(_text, c) : [self lineStart:c], c);
    if ([s isEqualToString:@"deleteToEndOfLine:"] || [s isEqualToString:@"deleteToEndOfParagraph:"]) {
        NSUInteger e = [self lineEnd:c];
        return erase(c, e == c ? cluster_after(_text, c) : e);
    }
    if ([s isEqualToString:@"insertNewline:"] || [s isEqualToString:@"insertNewlineIgnoringFieldEditor:"] ||
        [s isEqualToString:@"insertLineBreak:"] || [s isEqualToString:@"insertParagraphSeparator:"]) {
        if (!_multiline)
            return false;
        return [self insert:@"\n"], true;
    }
    if ([s isEqualToString:@"insertTab:"] || [s isEqualToString:@"insertTabIgnoringFieldEditor:"]) {
        if (!_multiline)
            return false;
        return [self insert:@"\t"], true;
    }
    if ([s isEqualToString:@"transpose:"]) {
        if (c == 0 || _text.length < 2)
            return true;
        NSUInteger at = c == _text.length ? c - 1 : c;
        NSRange a = [_text rangeOfComposedCharacterSequenceAtIndex:at - 1],
                b = [_text rangeOfComposedCharacterSequenceAtIndex:at];
        NSString* swapped = [[_text substringWithRange:b] stringByAppendingString:[_text substringWithRange:a]];
        [self replace:NSUnionRange(a, b) with:swapped undoable:true];
        return true;
    }
    if ([s isEqualToString:@"noop:"])
        return true;
    return false;
}

- (void)copySelection {
    if (_secure)
        return;
    NSRange r = self.selection;
    if (!r.length)
        return;
    NSPasteboard* pb = ui_pasteboard();
    [pb clearContents];
    [pb setString:[_text substringWithRange:r] forType:NSPasteboardTypeString];
}
- (void)cut {
    if (_secure)
        return;
    [self copySelection];
    if (self.selection.length)
        [self replace:self.selection with:@"" undoable:true];
}
- (void)paste {
    NSString* s = [ui_pasteboard() stringForType:NSPasteboardTypeString];
    if (s.length) {
        _marked = NSMakeRange(NSNotFound, 0);
        [self replace:self.selection with:s undoable:true];
    }
}

- (void)pressAt:(CGPoint)p clicks:(NSInteger)clicks extend:(bool)extend {
    _knob_drag = false;
    if ([self pressKnob:p])
        return;
    [self unmark];
    NSUInteger i = [self indexAt:p];
    _goal_x = NAN;
    if (clicks >= 3) {
        NSRange r = [self paragraphAt:i];
        _press_unit = 3;
        _press_from = r;
        return [self select:r.location to:NSMaxRange(r)];
    }
    if (clicks == 2) {
        NSRange r = [self wordAt:i];
        _press_unit = 2;
        _press_from = r;
        return [self select:r.location to:NSMaxRange(r)];
    }
    _press_unit = 1;
    if (extend)
        return [self select:_anchor to:i];
    [self select:i to:i];
}

- (void)dragTo:(CGPoint)p {
    if (_knob_drag)
        return [self dragKnob:p];
    NSUInteger i = [self indexAt:p];
    if (_press_unit >= 2) {
        NSRange r = _press_unit == 3 ? [self paragraphAt:i] : [self wordAt:i];
        NSRange u = NSUnionRange(r, _press_from);
        bool back = i < _press_from.location;
        return [self select:back ? NSMaxRange(u) : u.location to:back ? u.location : NSMaxRange(u)];
    }
    [self select:_anchor to:i];
}

- (bool)scrollBy:(NSEvent*)e {
    if (self.maxScroll <= 0 && (_wrap || !_multiline))
        return false;
    CGFloat d = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 12;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _view_y -= d;
    [self fill];
    [self clamp];
    [self fill];
    if (_multiline && !_wrap) {
        CGFloat most = 0;
        for (const EditPara& p : _paras)
            for (const EditRow& r : p.rows)
                most = MAX(most, r.width);
        CGFloat dx = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 12;
        _scroll_x = round(MAX(0, MIN(_scroll_x - dx, most - _layer.bounds.size.width + 2 * _inset.width)));
    }
    [self moveContent];
    [self placeSelection];
    [self positionCaret];
    [self placeKnob];
    [CATransaction commit];
    if (_knob) {
        int fade = ++_knob_fade;
        __weak RXEditor* weak = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            RXEditor* ed = weak;
            if (ed && fade == ed->_knob_fade)
                fade_layer(ed->_knob, 0, 300, nil);
        });
    }
    return true;
}

- (NSString*)checkLayout {
    [self layoutIfNeeded];
    const NSUInteger n = _text.length;
    if (_paras.empty())
        return @"nothing at hand";
    if (!_text->_rope->check())
        return @"the rope's counts";
    const CGFloat lh = self.lineHeight;
    for (size_t k = 0; k < _paras.size(); k++) {
        const EditPara& p = _paras[k];
        if (p.start + p.len > n)
            return [NSString stringWithFormat:@"para %zu past the end: %lu+%lu of %lu", k, (unsigned long)p.start,
                                              (unsigned long)p.len, (unsigned long)n];
        if (p.start != para_start_of(self, p.start))
            return [NSString stringWithFormat:@"para %zu at %lu isn't a paragraph's start", k, (unsigned long)p.start];
        if (p.start + p.len != piece_end(self, p.start))
            return [NSString stringWithFormat:@"para %zu at %lu: len %lu, should end at %lu", k, (unsigned long)p.start,
                                              (unsigned long)p.len, (unsigned long)piece_end(self, p.start)];
        if (k + 1 < _paras.size()) {
            if (_paras[k + 1].start != p.start + p.len)
                return [NSString stringWithFormat:@"para %zu ends at %lu, the next starts at %lu", k,
                                                  (unsigned long)(p.start + p.len), (unsigned long)_paras[k + 1].start];
            if (fabs(_paras[k + 1].y - (p.y + (CGFloat)p.rows.size() * lh)) > 0.01)
                return [NSString stringWithFormat:@"para %zu's y", k + 1];
        }
        CFIndex covered = 0;
        for (const EditRow& r : p.rows) {
            if (r.range.location != covered)
                return [NSString stringWithFormat:@"para %zu's rows don't follow", k];
            covered += r.range.length;
        }
        if (p.len && _text.length && (NSUInteger)covered != p.len)
            return
                [NSString stringWithFormat:@"para %zu's rows cover %ld of %lu", k, (long)covered, (unsigned long)p.len];
        if (p.layer.superlayer != _content)
            return [NSString stringWithFormat:@"para %zu has no layer", k];
    }
    return nil;
}

- (NSColor*)colorAt:(NSUInteger)i {
    _runs_dirty = true;
    [self lexNear:i];
    for (const auto& run : _runs) {
        const NSUInteger at = run.at + _runs_from;
        if (i < at || i >= at + run.len)
            continue;
        return _token_plain[static_cast<NSUInteger>(run.kind)] ? nil : _token_cols[static_cast<NSUInteger>(run.kind)];
    }
    return nil;
}
- (bool)scanDone {
    return !_hl || _hl->done();
}

- (double)knobShare {
    if (_paras.empty())
        return 0;
    if ([self wholeAtHand]) {
        const CGFloat max = self.maxScroll;
        return max > 0 ? MAX(0, MIN(1, (_view_y - _paras.front().y) / max)) : 0;
    }
    const CGFloat lh = self.lineHeight;
    const auto& rope = *_text->_rope;
    for (const EditPara& p : _paras) {
        const CGFloat h = (CGFloat)p.rows.size() * lh;
        if (p.y + h <= _view_y)
            continue;
        const double within = h > 0 ? MAX(0, (_view_y - p.y) / h) : 0;
        const double lines = MAX(1.0, (double)rope.lines() - _layer.bounds.size.height / lh);
        return MIN(1.0, ((double)rope.line_of(p.start) + within) / lines);
    }
    return 1;
}
- (void)placeKnob {
    if (!_knob)
        return;
    const CGFloat h = _layer.bounds.size.height, total = MAX(h, self.contentHeight);
    const CGFloat kh = MAX(20, h * h / total), ky = (h - kh) * [self knobShare];
    [_knob removeAllAnimations];
    _knob.frame = CGRectMake(_layer.bounds.size.width - 5, ky + 2, 3, kh - 4);
    _knob.backgroundColor = [_color colorWithAlphaComponent:0.3].CGColor;
    _knob.opacity = total > h ? 1 : 0;
}
- (bool)pressKnob:(CGPoint)p {
    if (!_knob || p.x < _layer.bounds.size.width - 12 || self.maxScroll <= 0)
        return false;
    _knob_drag = true;
    [self dragKnob:p];
    return true;
}
- (void)dragKnob:(CGPoint)p {
    const CGFloat h = _layer.bounds.size.height, total = MAX(h, self.contentHeight), kh = MAX(20, h * h / total);
    const double share = MAX(0, MIN(1, (p.y - kh / 2) / MAX(1, h - kh)));
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    const auto& rope = *_text->_rope;
    const double lines = MAX(1.0, (double)rope.lines() - h / self.lineHeight);
    const NSUInteger at = rope.line_start((size_t)(share * lines));
    release_paras(self);
    _top_start = para_start_of(self, at);
    _view_y = 0;
    [self fill];
    [self clamp];
    [self fill];
    [self moveContent];
    [self placeSelection];
    [self positionCaret];
    [self placeKnob];
    [CATransaction commit];
    int fade = ++_knob_fade;
    __weak RXEditor* weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        RXEditor* ed = weak;
        if (ed && fade == ed->_knob_fade)
            fade_layer(ed->_knob, 0, 300, nil);
    });
}

- (void)handleKey:(NSEvent*)ev {
    id h = _w_host;
    [[h respondsToSelector:@selector(rootView)] ? [h rootView] : nil interpretKeyEvents:@[ev]];
}
- (void)handleKeyUp:(NSEvent*)ev {
}
- (void)releaseAt:(CGPoint)p {
}
- (void)otherPress:(NSEvent*)e at:(CGPoint)p up:(bool)up {
}
- (NSRect)windowRectFor:(NSRange)r {
    id host = _w_host;
    if (!host)
        return NSZeroRect;
    NSUInteger from = MIN(r.location, _text.length);
    CGRect c = [self caretRect:from];
    if (r.length) {
        const EditPara& p = _paras[[self paraOf:from]];
        const size_t k = row_of(p, from);
        const CFRange lr = p.rows[k].range;
        NSUInteger to = MIN(NSMaxRange(r), p.start + (NSUInteger)(lr.location + lr.length));
        c.size.width = MAX(1, x_of(p, k, to) - x_of(p, k, from));
    }
    CALayer* hl = [host layer];
    CGRect in_host = [_layer convertRect:c toLayer:hl];
    return [host convertRect:NSRectFromCGRect(in_host) toView:nil];
}
- (NSUInteger)indexAtWindowPoint:(NSPoint)win {
    id host = _w_host;
    if (!host)
        return NSNotFound;
    NSPoint p = [host convertPoint:win fromView:nil];
    return [self indexAt:[_layer convertPoint:NSPointToCGPoint(p) fromLayer:[host layer]]];
}
@end

static RXRoot* root_for(RXEditor* e) {
    id h = e.host;
    return [h respondsToSelector:@selector(rootView)] ? [h rootView] : nil;
}

bool editor_focus(RXEditor* e) {
    RXRoot* root = root_for(e);
    NSWindow* w = root.window;
    if (!root || !w)
        return false;
    RXEditor* was = root.editor;
    if (was && was != e) {
        root.editor = nil;
        was.focused = false;
        if (was.ended)
            was.ended();
    }
    if (RXNode* f = root.focus)
        focus_changed(f, false), root.focus = nil;
    root.editor = e;
    e.focused = true;
    NSResponder* first = w.firstResponder;
    if (first != root) {
        [w makeFirstResponder:root];
        first = w.firstResponder;
    }
    return first == root;
}

void editor_blur(RXEditor* e) {
    RXRoot* root = root_for(e);
    if (root.editor != e) {
        e.focused = false;
        return;
    }
    root.editor = nil;
    e.focused = false;
    if (e.ended)
        e.ended();
    if (root.window.firstResponder == root)
        focus_terminal(root.window);
}

RXEditor* editor_in(NSWindow* w) {
    id r = w.firstResponder;
    return [r isKindOfClass:RXRoot.class] ? ((RXRoot*)r).editor : nil;
}

@interface RXRoot (Editing) <NSTextInputClient>
@end

@implementation RXRoot (Editing)
- (BOOL)acceptsFirstResponder {
    return self.editor != nil || self.focus != nil;
}
- (BOOL)becomeFirstResponder {
    return self.editor != nil || self.focus != nil;
}
- (BOOL)resignFirstResponder {
    if (RXNode* f = self.focus)
        focus_changed(f, false), self.focus = nil;
    RXEditor* e = self.editor;
    self.editor = nil;
    if (e) {
        e.focused = false;
        if (e.ended)
            dispatch_async(dispatch_get_main_queue(), e.ended);
    }
    return YES;
}
- (void)keyDown:(NSEvent*)ev {
    RXEditor* e = self.editor;
    if (!e) {
        if (RXNode* f = self.focus)
            return focus_key(f, ev);
        return [super keyDown:ev];
    }
    if (RXNode* en = e.node; en && !e.marked.length && focus_key_heard(en, ev))
        return;
    NSEventModifierFlags m = ev.modifierFlags
        & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption
           | NSEventModifierFlagControl);
    NSString* k = ev.charactersIgnoringModifiers.lowercaseString;
    if (m & NSEventModifierFlagCommand) {
        bool shift = m & NSEventModifierFlagShift;
        if ([k isEqualToString:@"c"])
            return [e copySelection];
        if ([k isEqualToString:@"x"])
            return [e cut];
        if ([k isEqualToString:@"v"])
            return [e paste];
        if ([k isEqualToString:@"a"])
            return (void)[e perform:@selector(selectAll:)];
        if ([k isEqualToString:@"z"])
            return [e undo:shift];
    }
    [e handleKey:ev];
}
- (void)keyUp:(NSEvent*)ev {
    if (RXEditor* e = self.editor) {
        if (RXNode* en = e.node)
            focus_key_up(en, ev);
        return [e handleKeyUp:ev];
    }
    if (RXNode* f = self.focus)
        return focus_key_up(f, ev);
    [super keyUp:ev];
}
- (void)copy:(id)sender {
    self.editor ? [self.editor copySelection] : (void)[self.nextResponder tryToPerform:_cmd with:sender];
}
- (void)cut:(id)sender {
    self.editor ? [self.editor cut] : (void)[self.nextResponder tryToPerform:_cmd with:sender];
}
- (void)paste:(id)sender {
    self.editor ? [self.editor paste] : (void)[self.nextResponder tryToPerform:_cmd with:sender];
}
- (void)selectAll:(id)sender {
    self.editor ? (void)[self.editor perform:_cmd] : (void)[self.nextResponder tryToPerform:_cmd with:sender];
}
- (void)undo:(id)sender {
    self.editor ? [self.editor undo:false] : (void)[self.nextResponder tryToPerform:_cmd with:sender];
}
- (void)redo:(id)sender {
    self.editor ? [self.editor undo:true] : (void)[self.nextResponder tryToPerform:_cmd with:sender];
}
- (BOOL)validateMenuItem:(NSMenuItem*)item {
    SEL a = item.action;
    if (a == @selector(copy:) || a == @selector(cut:))
        return self.editor.selection.length > 0;
    if (a == @selector(paste:))
        return self.editor != nil && [ui_pasteboard() stringForType:NSPasteboardTypeString] != nil;
    if (a == @selector(selectAll:) || a == @selector(undo:) || a == @selector(redo:))
        return self.editor != nil;
    return NO;
}

- (void)insertText:(id)string replacementRange:(NSRange)rr {
    engine_urgent();
    RXEditor* e = self.editor;
    NSString* s = [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString*)string string] : string;
    if (!e || ![s isKindOfClass:NSString.class])
        return;
    if (rr.location != NSNotFound && !e.marked.length)
        [e select:rr.location to:NSMaxRange(rr)];
    if (RXNode* n = e.node; n && flag(n, P::autoPairs, false) && [e typePair:s])
        return;
    [e insert:s];
}
- (void)doCommandBySelector:(SEL)sel {
    if (![self.editor perform:sel])
        [self.nextResponder tryToPerform:sel with:nil];
}
- (void)setMarkedText:(id)string selectedRange:(NSRange)sr replacementRange:(NSRange)rr {
    NSString* s = [string isKindOfClass:NSAttributedString.class] ? [(NSAttributedString*)string string] : string;
    if ([s isKindOfClass:NSString.class])
        [self.editor setMarked:s selected:sr replacing:rr];
}
- (void)unmarkText {
    [self.editor unmark];
}
- (NSRange)selectedRange {
    return self.editor ? self.editor.selection : NSMakeRange(NSNotFound, 0);
}
- (NSRange)markedRange {
    return self.editor ? self.editor.marked : NSMakeRange(NSNotFound, 0);
}
- (BOOL)hasMarkedText {
    return self.editor && self.editor.marked.location != NSNotFound;
}
- (NSAttributedString*)attributedSubstringForProposedRange:(NSRange)r actualRange:(NSRangePointer)actual {
    NSString* t = [self.editor substring:r];
    if (!t)
        return nil;
    r.length = t.length;
    if (actual)
        *actual = r;
    return [[NSAttributedString alloc] initWithString:t];
}
- (NSArray<NSAttributedStringKey>*)validAttributesForMarkedText {
    return @[];
}
- (NSRect)firstRectForCharacterRange:(NSRange)r actualRange:(NSRangePointer)actual {
    RXEditor* e = self.editor;
    if (!e || !self.window)
        return NSZeroRect;
    if (actual)
        *actual = r;
    return [self.window convertRectToScreen:[e windowRectFor:r]];
}
- (NSUInteger)characterIndexForPoint:(NSPoint)screen {
    RXEditor* e = self.editor;
    if (!e || !self.window)
        return NSNotFound;
    return [e indexAtWindowPoint:[self.window convertPointFromScreen:screen]];
}
@end

static void editor_style(RXNode* n, RXEditor* e) {
    NSColor* c = parse_color(obj_of(n, P::color)) ?: g_theme.fg;
    e.font = font_for(n);
    e.color = c;
    e.placeholder = is_elem(n, E::TextField) ? str(n, P::placeholder, @"") : @"";
    e.editable = is_elem(n, E::TextField) ? flag(n, P::enabled, true) && !flag(n, P::readOnly, false)
                                          : flag(n, P::editable, true);
    if (is_elem(n, E::TextField))
        e.secure = flag(n, P::secure, false), e.max_length = (NSUInteger)MAX(0, num(n, P::maxLength, 0));
    if (is_elem(n, E::TextArea))
        e.wrap = flag(n, P::wrap, true), e.follow = flag(n, P::follow, false);
    [e styleChanged];
}

RXEditor* node_editor(RXNode* n, bool make) {
    if (n.editor || !make || !n.layer)
        return n.editor;
    bool area = is_elem(n, E::TextArea);
    RXEditor* e = [[RXEditor alloc] initMultiline:area];
    e.node = n;
    __weak RXNode* wn = n;
    e.lang = ^const void*(void) {
        RXNode* n2 = wn;
        return n2 ? syntax_lang(n2) : nullptr;
    };
    e.token_colors = ^NSArray<NSColor*>*(void) {
        RXNode* n2 = wn;
        return n2 ? syntax_token_colors(n2, parse_color(obj_of(n2, P::color)) ?: g_theme.fg) : @[];
    };
    __weak RXEditor* we = e;
    e.changed = ^(NSString* t) {
        RXNode* n2 = wn;
        if (!n2.doc.ctx)
            return;
        RXEditor* held = we;
        if (held.from_file)
            return (void)doc_call(n2.doc, @"emit", @[@(n2.uid), @"edited", @[]]);
        [held noteSent:t];
        doc_call(n2.doc, @"input", @[@(n2.uid), t]);
    };
    if (area) {
        e.command = ^bool(SEL sel) {
            if (sel != @selector(insertBacktab:))
                return false;
            if (RXNode* n2 = wn)
                focus_move(n2, -1);
            return true;
        };
    } else {
        e.command = ^bool(SEL sel) {
            RXNode* n2 = wn;
            if (!n2.doc.ctx)
                return false;
            if (sel == @selector(insertTab:) || sel == @selector(insertBacktab:)) {
                focus_move(n2, sel == @selector(insertTab:) ? 1 : -1);
                return true;
            }
            if ((sel == @selector(moveUp:) || sel == @selector(moveDown:)) && flag(n2, P::arrows, false)) {
                doc_call(n2.doc, @"emit", @[@(n2.uid), @"arrow", @[sel == @selector(moveUp:) ? @"up" : @"down"]]);
                return true;
            }
            if (sel == @selector(insertNewline:)) {
                doc_call(n2.doc, @"emit", @[@(n2.uid), @"accepted", @[]]);
                return true;
            }
            return false;
        };
        e.ended = ^{
            if (RXNode* n2 = wn)
                field_done(n2);
        };
    }
    n.editor = e;
    [n.layer addSublayer:e.layer];
    editor_style(n, e);
    if (!str(n, P::source, @"").length)
        e.text = str(n, P::text, @"");
    editor_layout(n);
    return e;
}

void editor_layout(RXNode* n) {
    RXEditor* e = n.editor;
    if (!e || [e isKindOfClass:RXTermInput.class])
        return;
    e.host = host_of(n);
    CGRect b = n.layer.bounds;
    if (!CGRectEqualToRect(e.layer.frame, b)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        e.layer.frame = b;
        e.layer.contentsScale = [e.host window].backingScaleFactor ?: 2;
        [CATransaction commit];
        if (!e.multiline)
            e->_dirty = true;
        if (e.focused)
            [e reveal];
        [e refresh];
    }
}

void editor_call(RXNode* n, NSString* method, NSString* arg) {
    if (is_elem(n, E::TextField) && !n.editor)
        focus_node(n, false);
    RXEditor* e = node_editor(n, is_elem(n, E::TextArea));
    if (!e)
        return;
    if ([method isEqualToString:@"select"]) {
        NSArray<NSString*>* at = [arg componentsSeparatedByString:@","];
        [e select:(NSUInteger)MAX(0, at.firstObject.integerValue) to:(NSUInteger)MAX(0, at.lastObject.integerValue)];
    } else if ([method isEqualToString:@"selectAll"]) {
        [e perform:@selector(selectAll:)];
    } else if ([method isEqualToString:@"insert"]) {
        [e insert:arg];
    } else if ([method isEqualToString:@"find"] || [method isEqualToString:@"findBack"]) {
        const bool ok = [e findNext:arg backwards:[method isEqualToString:@"findBack"]];
        if (n.doc.ctx)
            doc_call(n.doc, @"emit", @[@(n.uid), @"found", @[@(ok)]]);
    }
}

void field_edit(RXNode* n) {
    if (!is_elem(n, E::TextField) || !n.doc || !flag(n, P::enabled, true))
        return;
    RXEditor* e = node_editor(n, true);
    ((RXTextLayer*)n.layer).hideText = YES;
    editor_layout(n);
    editor_focus(e);
}

void field_done(RXNode* n) {
    RXEditor* e = is_elem(n, E::TextField) ? n.editor : nil;
    if (!e)
        return;
    if (e.focused) {
        e.ended = nil;
        editor_blur(e);
    }
    [e.layer removeFromSuperlayer];
    n.editor = nil;
    ((RXTextLayer*)n.layer).hideText = NO;
    apply_color(n);
}

static NSString* source_path(RXNode* n) {
    NSString* path = str(n, P::source, @"").stringByExpandingTildeInPath;
    return path.isAbsolutePath ? path : [doc_dir(n) stringByAppendingPathComponent:path];
}
static void editor_load(RXNode* n, RXEditor* e) {
    if (!str(n, P::source, @"").length) {
        if (e.from_file) {
            e.from_file = false;
            e.text = str(n, P::text, @"");
        }
        return;
    }
    e.from_file = true;
    NSString* path = source_path(n);
    __weak RXEditor* we = e;
    __weak RXNode* wn = n;
    const void* lang = syntax_lang(n);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData* data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        auto* rope = new (std::nothrow) rx::text::Rope;
        if (rope
            && !(rope->ok()
                 && rope->append_utf8(std::string_view(static_cast<const char*>(data.bytes), data.length))
                        .has_value())) {
            delete rope;
            rope = nullptr;
        }
        rx::text::Highlighter* hl = nullptr;
        if (rope && lang) {
            hl = new (std::nothrow) rx::text::Highlighter(*static_cast<const rx::text::Lang*>(lang), *rope);
            while (hl && hl->step(1 << 24)) {
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            RXEditor* e2 = we;
            RXNode* n2 = wn;
            if (!data)
                rexui_log([NSString stringWithFormat:@"TextArea: couldn't read %@", path]);
            if (e2 && n2 && rope && [source_path(n2) isEqualToString:path]) {
                [e2 adoptRope:rope highlighter:hl lang:lang];
            } else {
                delete hl;
                delete rope;
            }
        });
    });
}

void editor_save(RXNode* n) {
    RXEditor* e = n.editor;
    if (!e || !str(n, P::source, @"").length)
        return;
    NSString *t = e.text, *path = source_path(n);
    __weak RXNode* wn = n;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError* error;
        const bool ok = [t writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (!ok)
            rexui_log([NSString stringWithFormat:@"TextArea: couldn't save %@: %@", path, error.localizedDescription]);
        dispatch_async(dispatch_get_main_queue(), ^{
            RXNode* n2 = wn;
            if (n2.doc.ctx)
                doc_call(n2.doc, @"emit", @[@(n2.uid), @"saved", @[@(ok)]]);
        });
    });
}

void apply_textarea(RXNode* n, NSString* name) {
    RXEditor* e = node_editor(n, is_elem(n, E::TextArea));
    if (!e)
        return;
    if ([name isEqualToString:@"source"])
        return editor_load(n, e);
    if ([name isEqualToString:@"text"]) {
        if (e.from_file)
            return;
        NSString* t = str(n, P::text, @"");
        if ([e isEcho:t])
            return;
        e.text = t;
        return;
    }
    editor_style(n, e);
}
