// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/trace.h"
#include "ui/ui.h"

#include <vector>

static NSString* halign(RXNode* n) {
    return str(n, P::halign, is_row(n) ? @"left" : @"stretch");
}
static NSString* valign(RXNode* n) {
    return str(n, P::valign, is_row(n) ? @"center" : is_column(n) ? @"top" : @"stretch");
}

static bool folded_away(RXNode* c) {
    return flag(c, P::collapse, false) && !flag(c, P::expanded, true);
}
static CGFloat column_gaps(NSArray<RXNode*>* kids, CGFloat gap) {
    NSUInteger n = 0;
    for (RXNode* c in kids)
        n += !folded_away(c);
    return gap * MAX(0, (CGFloat)n - 1);
}

static constexpr CGFloat kNatural = 100000;

uint64_t g_kids_epoch = 1;

static NSArray<RXNode*>* laid_out_now(RXNode* n);
NSArray<RXNode*>* laid_out(RXNode* n) {
    if (n.kids_epoch == g_kids_epoch && n.kids_shown)
        return n.kids_shown;
    n.kids_shown = laid_out_now(n);
    n.kids_epoch = g_kids_epoch;
    return n.kids_shown;
}

static NSArray<RXNode*>* laid_out_now(RXNode* n) {
    NSMutableArray* kids = [NSMutableArray array];
    CALayer* home = flag(n, P::detachHidden, false) ? content_layer(n) : nil;
    CALayer *into = nil, *prev = nil, *below = nil;
    if (lazy_layers()) {
        bool any = false;
        for (RXNode* c in n.children)
            if (c.dormant) {
                any = true;
                break;
            }
        if (any) {
            into = content_layer(n);
            for (RXNode* k in n.children)
                if (CALayer* kl = k.layer; kl && kl.superlayer == into) {
                    below = kl;
                    break;
                }
        }
    }
    for (RXNode* c in n.children) {
        if (is_drawer(c))
            continue;
        if (into) {
            if (c.dormant && flag(c, P::visible, true))
                layer_wake(c, prev, prev ? nil : below);
            if (CALayer* cl = c.layer; cl && cl.superlayer == into)
                prev = cl;
        }
        if (CALayer* l = c.layer) {
            bool visible = flag(c, P::visible, true);
            if (l.hidden == visible && !c.leaving)
                l.hidden = !visible;
            if (home && !visible && l.superlayer)
                [l removeFromSuperlayer];
            else if (home && visible && l.superlayer != home)
                [home addSublayer:l];
        }
        if (shown(c))
            [kids addObject:c];
    }
    return in_order(n, kids);
}

void invalidate(RXNode* n) {
    for (__unsafe_unretained RXNode* x = n; x; x = x->up)
        x->_m_valid = x->_p_valid = false;
}

void unplace(RXNode* n) {
    n.p_valid = false;
    n.appear_due = true;
    for (RXNode* c in n.children)
        unplace(c);
}

static void replace_quiet(RXNode* n) {
    n.p_valid = false;
    for (RXNode* c in n.children)
        replace_quiet(c);
}

static NSSize measure_now(RXNode* n, CGFloat avail);

static bool has_limits(RXNode* n) {
    return has_num(n, P::minWidth) || has_num(n, P::maxWidth) || has_num(n, P::minHeight) || has_num(n, P::maxHeight);
}
static CGFloat limit_w(RXNode* n, CGFloat w) {
    if (CGFloat mx = num(n, P::maxWidth, 0); mx > 0)
        w = MIN(w, mx);
    return MAX(w, num(n, P::minWidth, 0));
}
static CGFloat limit_h(RXNode* n, CGFloat h) {
    if (CGFloat mx = num(n, P::maxHeight, 0); mx > 0)
        h = MIN(h, mx);
    return MAX(h, num(n, P::minHeight, 0));
}
static CGFloat limit_on(RXNode* n, bool row, CGFloat v) {
    return row ? limit_w(n, v) : limit_h(n, v);
}

static CGFloat shrink_of(RXNode* c, bool row) {
    return num(c, P::shrink, row && is_elem(c, E::Text) ? 1 : 0);
}

static std::vector<NSSize> g_sizes;
static std::vector<CGFloat> g_cells;
template <class T>
struct Frame {
    std::vector<T>& v;
    size_t base;
    explicit Frame(std::vector<T>& s) : v(s), base(s.size()) {}
    ~Frame() { v.resize(base); }
    T& operator[](size_t i) { return v[base + i]; }
};

static void share_room(NSArray<RXNode*>* kids, bool row, CGFloat room, CGFloat used, CGFloat grow,
                       Frame<CGFloat>& natural, Frame<CGFloat>& along) {
    const NSUInteger count = kids.count;
    CGFloat left = MAX(0, room - used);
    if (grow > 0) {
        auto away = [&](NSUInteger i) { return !row && folded_away(kids[i]); };
        bool limits = false;
        for (NSUInteger i = 0; i < count; i++)
            limits = limits || (!away(i) && num(kids[i], P::grow, 0) > 0 && has_limits(kids[i]));
        if (limits) {
            for (NSUInteger i = 0; i < count; i++)
                if (away(i))
                    natural[i] = -1;
            for (bool again = true; again;) {
                again = false;
                CGFloat g = 0;
                for (NSUInteger i = 0; i < count; i++)
                    if (num(kids[i], P::grow, 0) > 0 && natural[i] >= 0)
                        g += num(kids[i], P::grow, 0);
                if (g <= 0)
                    break;
                for (NSUInteger i = 0; i < count; i++) {
                    CGFloat gi = num(kids[i], P::grow, 0);
                    if (gi <= 0 || natural[i] < 0)
                        continue;
                    CGFloat want = left * gi / g, got = limit_on(kids[i], row, want);
                    if (got != want) {
                        along[i] = got;
                        natural[i] = -1;
                        left = MAX(0, left - got);
                        again = true;
                        break;
                    }
                }
            }
            CGFloat g = 0;
            for (NSUInteger i = 0; i < count; i++)
                if (num(kids[i], P::grow, 0) > 0 && natural[i] >= 0)
                    g += num(kids[i], P::grow, 0);
            for (NSUInteger i = 0; i < count; i++) {
                CGFloat gi = num(kids[i], P::grow, 0);
                if (away(i))
                    along[i] = 0, natural[i] = 0;
                else if (gi > 0 && natural[i] >= 0)
                    along[i] = g > 0 ? left * gi / g : 0;
                else if (gi <= 0)
                    along[i] = natural[i];
            }
        } else {
            for (NSUInteger i = 0; i < count; i++) {
                CGFloat gi = num(kids[i], P::grow, 0);
                along[i] = gi > 0 ? left * gi / grow : natural[i];
            }
        }
    } else {
        for (NSUInteger i = 0; i < count; i++)
            along[i] = natural[i];
    }
    if (used <= room)
        return;
    CGFloat over = used - room, weight = 0;
    for (NSUInteger i = 0; i < count; i++)
        if (num(kids[i], P::grow, 0) <= 0)
            weight += shrink_of(kids[i], row) * natural[i];
    if (weight <= 0)
        return;
    for (NSUInteger i = 0; i < count; i++) {
        if (num(kids[i], P::grow, 0) > 0)
            continue;
        CGFloat share = shrink_of(kids[i], row) * natural[i];
        if (share <= 0)
            continue;
        along[i] = MAX(limit_on(kids[i], row, 0), MAX(0, natural[i] - over * share / weight));
    }
}

static NSUInteger grid_columns(RXNode* n, NSUInteger count, CGFloat cw, CGFloat gap, Frame<CGFloat>& widths,
                               std::vector<CGFloat>& store) {
    id list = obj_of(n, P::columnWidths);
    if ([list isKindOfClass:NSArray.class] && [list count]) {
        NSArray* a = list;
        NSUInteger cols = a.count;
        store.resize(widths.base + cols, 0);
        CGFloat fixed = gap * (CGFloat)(cols - 1);
        NSUInteger share = 0;
        for (NSUInteger i = 0; i < cols; i++) {
            CGFloat w = [a[i] respondsToSelector:@selector(doubleValue)] ? [a[i] doubleValue] : 0;
            widths[i] = w;
            if (w > 0)
                fixed += w;
            else
                share++;
        }
        const CGFloat each = share ? MAX(0, cw - fixed) / (CGFloat)share : 0;
        for (NSUInteger i = 0; i < cols; i++)
            if (widths[i] <= 0)
                widths[i] = each;
        return cols;
    }
    NSUInteger cols;
    if (CGFloat mn = num(n, P::minColumnWidth, 0); mn > 0 && cw < kNatural)
        cols = MAX(1, (NSUInteger)floor((cw + gap) / (mn + gap)));
    else
        cols = MIN(MAX(1, (NSUInteger)num(n, P::columns, 2)), MAX((NSUInteger)1, count));
    store.resize(widths.base + cols, 0);
    const CGFloat cell = MAX(0, (cw - gap * (CGFloat)(cols - 1)) / (CGFloat)cols);
    for (NSUInteger i = 0; i < cols; i++)
        widths[i] = cell;
    return cols;
}

static CGFloat grid_cell(RXNode* c, NSUInteger cols, Frame<CGFloat>& widths, CGFloat gap, NSUInteger& col,
                         NSUInteger& row, NSUInteger& span) {
    span = (NSUInteger)MAX(1, MIN((CGFloat)cols, num(c, P::columnSpan, 1)));
    if (col + span > cols)
        col = 0, row++;
    CGFloat w = gap * (CGFloat)(span - 1);
    for (NSUInteger k = col; k < col + span; k++)
        w += widths[k];
    return w;
}
static bool grid_plain(RXNode* n, NSArray<RXNode*>* kids) {
    if (has_prop(n, P::columnWidths) || has_num(n, P::minColumnWidth))
        return false;
    for (RXNode* c in kids)
        if (has_num(c, P::columnSpan))
            return false;
    return true;
}
static NSSize measure_grid_cells(RXNode* n, NSArray<RXNode*>* kids, CGFloat cw, CGFloat gap, CGFloat px, CGFloat py) {
    Frame<CGFloat> widths(g_cells);
    const NSUInteger cols = grid_columns(n, kids.count, cw, gap, widths, g_cells);
    NSUInteger col = 0, row = 0, span = 1, rows = 0;
    CGFloat line = 0, h = 0;
    for (RXNode* c in kids) {
        const NSUInteger was = row;
        const CGFloat w = grid_cell(c, cols, widths, gap, col, row, span);
        if (row != was)
            h += line + gap, line = 0;
        line = MAX(line, measure(c, w).height);
        col += span;
        rows = row + 1;
    }
    h += line;
    CGFloat total = gap * (CGFloat)(cols - 1);
    for (NSUInteger i = 0; i < cols; i++)
        total += widths[i];
    (void)rows;
    return NSMakeSize(total + 2 * px, h + 2 * py);
}

static NSSize measure_flow(NSArray<RXNode*>* kids, CGFloat cw, CGFloat gap, CGFloat line_gap) {
    CGFloat x = 0, line = 0, h = 0, widest = 0;
    bool any = false;
    for (RXNode* c in kids) {
        NSSize k = measure(c, cw);
        if (any && x + k.width > cw)
            h += line + line_gap, x = 0, line = 0;
        x += k.width + gap;
        widest = MAX(widest, x - gap);
        line = MAX(line, k.height);
        any = true;
    }
    return NSMakeSize(widest, h + line);
}

static bool is_across(RXNode* n) {
    return is_list(n) && [str(n, P::orientation, @"") isEqualToString:@"horizontal"];
}

NSSize measure(RXNode* n, CGFloat avail) {
    if (n.m_valid && n.m_avail == avail)
        return n.m_size;
    NSSize s = measure_now(n, avail);
    n.m_avail = avail;
    n.m_size = s;
    n.m_valid = true;
    return s;
}

static NSSize measure_now(RXNode* n, CGFloat avail) {
    CGFloat px = pad_x(n), py = pad_y(n), gap = num(n, P::spacing, 0);
    bool fixed_w = has_num(n, P::width), fixed_h = has_num(n, P::height);
    CGFloat w0 = fixed_w ? num(n, P::width, 0) : avail;
    NSSize s = NSZeroSize;
    if (is_elem(n, E::Text)) {
        RXTextLayer* t = (RXTextLayer*)n.layer;
        if (t.wrap) {
            NSSize c = text_size(t, w0);
            s = NSMakeSize(MIN(ceil(c.width), w0), ceil(c.height));
        } else {
            NSSize c = text_size(t, CGFLOAT_MAX);
            s = NSMakeSize(MIN(ceil(c.width) + 1, w0), ceil(c.height));
        }
    } else if (is_elem(n, E::TextField)) {
        s = NSMakeSize(w0, ceil(line_height(font_for(n))) + 4);
    } else if (is_elem(n, E::TextArea)) {
        s = NSMakeSize(w0, 200);
    } else if (is_elem(n, E::WebView)) {
        s = NSMakeSize(w0, 300);
    } else if (is_elem(n, E::TabPreview)) {
        s = measure_tabpreview(n, w0);
    } else if (is_elem(n, E::Image)) {
        CGFloat w = w0;
        CGFloat aspect = n.image_size.width > 0 ? n.image_size.height / n.image_size.width : 1;
        if (fixed_h && !fixed_w)
            w = MIN(avail, num(n, P::height, 0) / aspect);
        s = NSMakeSize(w, round(w * aspect));
    } else if (is_elem(n, E::PanePreview)) {
        CGFloat aspect = pane_preview_aspect(n);
        CGFloat w = fixed_h && !fixed_w ? MIN(avail, num(n, P::height, 0) / aspect) : w0;
        s = NSMakeSize(w, fixed_h ? num(n, P::height, 0) : round(w * aspect));
    } else if (is_elem(n, E::Shapes) || is_elem(n, E::Shader)) {
        s = NSMakeSize(fixed_w ? w0 : 0, fixed_h ? num(n, P::height, 0) : 0);
    } else if (is_canvas(n)) {
        CGFloat w = fixed_h && !fixed_w ? MIN(avail, num(n, P::height, 0)) : w0;
        s = NSMakeSize(w, w);
    } else if (is_elem(n, E::Button) || is_elem(n, E::Icon)) {
        NSSize c = is_elem(n, E::Button) ? [(RXButtonLayer*)n.layer measure] : n.image_size;
        s = NSMakeSize(MIN(ceil(c.width), w0), ceil(c.height));
    } else if (is_elem(n, E::Slider)) {
        s = NSMakeSize(w0, 16);
    } else if (is_vlist(n)) {
        CGFloat cw = 0;
        if (w0 >= kNatural)
            for (RXNode* c in laid_out(n))
                cw = MAX(cw, measure(c, kNatural).width + 2 * px);
        s = NSMakeSize(w0 >= kNatural ? cw : w0, vlist_content_height(n));
    } else if (is_pages(n)) {
        NSArray<RXNode*>* kids = laid_out(n);
        NSInteger cur = MAX(0, MIN((NSInteger)kids.count - 1, (NSInteger)num(n, P::current, 0)));
        NSSize k = kids.count ? measure(kids[cur], kNatural) : NSZeroSize;
        s = NSMakeSize(k.width + 2 * px, k.height + 2 * py);
    } else if (is_grid(n) && !grid_plain(n, laid_out(n))) {
        s = measure_grid_cells(n, laid_out(n), MAX(0, w0 - 2 * px), gap, px, py);
    } else if (is_grid(n)) {
        CGFloat cw = MAX(0, w0 - 2 * px);
        NSArray<RXNode*>* kids = laid_out(n);
        NSUInteger cols = MIN(MAX(1, (NSUInteger)num(n, P::columns, 2)), MAX((NSUInteger)1, kids.count));
        CGFloat cell = MAX(0, (cw - gap * (cols - 1)) / cols);
        NSUInteger rows = (kids.count + cols - 1) / cols;
        Frame<CGFloat> cells(g_cells);
        g_cells.resize(cells.base + cols + rows, 0);
        for (NSUInteger i = 0; i < kids.count; i++) {
            NSSize k = measure(kids[i], cell);
            cells[i % cols] = MAX(cells[i % cols], k.width);
            cells[cols + i / cols] = MAX(cells[cols + i / cols], k.height);
        }
        CGFloat w = 0, h = 0;
        for (NSUInteger i = 0; i < cols; i++)
            w = MAX(w, cells[i]);
        for (NSUInteger i = 0; i < rows; i++)
            h += cells[cols + i];
        s = NSMakeSize(kids.count ? w * cols + gap * (cols - 1) + 2 * px : 2 * px,
                       h + gap * MAX(0, (CGFloat)rows - 1) + 2 * py);
    } else if (is_across(n)) {
        NSArray<RXNode*>* kids = laid_out(n);
        CGFloat tallest = 0;
        for (RXNode* c in kids)
            tallest = MAX(tallest, measure(c, kNatural).height);
        s = NSMakeSize(w0, tallest + 2 * py);
    } else if (is_list(n) && n.layer && ((RXScrollLayer*)n.layer).guttered) {
        const CGFloat g = num(n, P::gutter, 10), cw = MAX(0, w0 - 2 * px - g);
        CGFloat main = 0, cross = 0;
        NSArray<RXNode*>* kids = laid_out(n);
        for (RXNode* c in kids) {
            NSSize k = measure(c, cw);
            if (!folded_away(c))
                main += k.height;
            cross = MAX(cross, k.width);
        }
        main += column_gaps(kids, gap);
        s = NSMakeSize(cross + g + 2 * px, main + 2 * py);
    } else if (is_box(n)) {
        CGFloat cw = MAX(0, w0 - 2 * px);
        NSArray<RXNode*>* kids = laid_out(n);
        CGFloat main = 0, cross = 0;
        if (is_row(n) && flag(n, P::flow, false)) {
            NSSize f = measure_flow(kids, cw, gap, num(n, P::rowSpacing, gap));
            s = NSMakeSize(f.width + 2 * px, f.height + 2 * py);
        } else if (is_row(n)) {
            CGFloat used = gap * MAX(0, (CGFloat)kids.count - 1), grow = 0;
            Frame<CGFloat> natural(g_cells);
            g_cells.resize(natural.base + 2 * kids.count, 0);
            Frame<CGFloat> along(g_cells);
            along.base = natural.base + kids.count;
            for (NSUInteger i = 0; i < kids.count; i++) {
                RXNode* c = kids[i];
                if (num(c, P::grow, 0) > 0)
                    grow += num(c, P::grow, 0);
                else
                    used += (natural[i] = measure(c, cw).width);
            }
            share_room(kids, true, cw, used, grow, natural, along);
            for (NSUInteger i = 0; i < kids.count; i++) {
                RXNode* c = kids[i];
                const bool grows = num(c, P::grow, 0) > 0;
                NSSize k = measure(c, grows || along[i] < natural[i] ? along[i] : cw);
                cross = MAX(cross, k.height);
            }
            along.base = g_cells.size();
            main = grow > 0 ? cw : MIN(used, cw);
            s = NSMakeSize(main + 2 * px, cross + 2 * py);
        } else if (is_column(n)) {
            for (RXNode* c in kids) {
                NSSize k = measure(c, cw);
                if (!folded_away(c))
                    main += k.height;
                cross = MAX(cross, k.width);
            }
            main += column_gaps(kids, gap);
            s = NSMakeSize(cross + 2 * px, main + 2 * py);
        } else {
            for (RXNode* c in kids) {
                NSSize k = measure(c, cw);
                main = MAX(main, k.height);
                cross = MAX(cross, k.width);
            }
            s = NSMakeSize(cross + 2 * px, main + 2 * py);
        }
    }
    if (fixed_w)
        s.width = num(n, P::width, 0);
    if (fixed_h)
        s.height = num(n, P::height, 0);
    if (has_limits(n))
        s = NSMakeSize(limit_w(n, s.width), limit_h(n, s.height));
    return s;
}

enum class Align : uint8_t { start, center, end, stretch };
static Align align_of(NSString* a) {
    if (!a.length)
        return Align::start;
    switch ([a characterAtIndex:0]) {
    case 'c':
        return Align::center;
    case 'r':
    case 'b':
        return Align::end;
    case 's':
        return Align::stretch;
    default:
        return Align::start;
    }
}
static CGFloat offset(Align align, CGFloat room) {
    if (align == Align::center)
        return round(room / 2);
    if (align == Align::end)
        return room;
    return 0;
}

static void place_across(RXNode* n, NSRect frame) {
    RXScrollLayer* sv = (RXScrollLayer*)n.layer;
    sv.horizontal = true;
    const bool at_end = sv.offset >= sv.maxOffset - 4;
    CGFloat px = pad_x(n), py = pad_y(n), gap = num(n, P::spacing, 0), ch = MAX(0, frame.size.height - 2 * py), x = px;
    NSArray<RXNode*>* kids = laid_out(n);
    for (RXNode* c in kids) {
        NSSize k = measure(c, kNatural);
        const bool stretch = !has_num(c, P::height);
        place(c, NSMakeRect(x, py, k.width, stretch ? ch : MIN(k.height, ch)));
        x += k.width + gap;
    }
    if (kids.count)
        x -= gap;
    [sv setContentHeight:x + px];
    if (flag(n, P::follow, false) && at_end)
        sv.offset = sv.maxOffset;
    sv.fade = num(n, P::fade, 0);
}

static void place_list(RXNode* n, NSRect frame) {
    if (is_across(n))
        return place_across(n, frame);
    RXScrollLayer* sv = (RXScrollLayer*)n.layer;
    sv.horizontal = false;
    CGFloat h = frame.size.height;
    bool at_end = sv.offset >= sv.maxOffset - 4;
    CGFloat px = pad_x(n), py = pad_y(n), gap = num(n, P::spacing, 0);
    CGFloat w = frame.size.width, cw = MAX(0, w - 2 * px), y = py;
    NSArray<RXNode*>* kids = laid_out(n);
    const CGFloat full = cw, narrow = MAX(0, cw - num(n, P::gutter, 10));
    auto total_at = [&](CGFloat width) {
        CGFloat t = 2 * py + column_gaps(kids, gap);
        for (RXNode* c in kids)
            t += folded_away(c) ? 0 : measure(c, width).height;
        return t;
    };
    bool gutter = sv.guttered;
    bool over = total_at(gutter ? narrow : full) > h;
    if (over != gutter) {
        gutter = over;
        if (!gutter)
            over = total_at(full) > h, gutter = over;
    }
    sv.guttered = gutter;
    cw = gutter ? narrow : full;
    NSInteger reveal = (NSInteger)num(n, P::reveal, -1);
    CGFloat top = -1, bottom = 0;
    NSUInteger placed = 0;
    for (NSUInteger i = 0; i < kids.count; i++) {
        RXNode* c = kids[i];
        NSSize k = measure(c, cw);
        CGFloat kw = has_num(c, P::width) ? MIN(k.width, cw) : cw;
        place(c, NSMakeRect(px, y, kw, k.height));
        if ((NSInteger)i == reveal)
            top = y, bottom = y + k.height;
        if (!folded_away(c))
            y += k.height + gap, placed++;
    }
    if (placed)
        y -= gap;
    y += py;
    [sv setContentHeight:y];
    if (flag(n, P::follow, false) && at_end)
        sv.offset = sv.maxOffset;
    if ((n.reveal_pending || n.revealed_of != kids.count) && top >= 0) {
        if ([str(n, P::revealAlign, @"") isEqualToString:@"center"]) {
            [sv glideTo:(top + bottom - h) / 2 ms:n.revealed_of == kids.count ? num(n, P::revealAnimation, 0) : 0];
        } else {
            [sv reveal:NSMakeRect(0, top - py, w, bottom - top + 2 * py)];
        }
    }
    n.reveal_pending = false;
    n.revealed_of = kids.count;
    sv.fade = num(n, P::fade, 0);
}

static void place_grid(RXNode* n, NSRect frame) {
    CGFloat px = pad_x(n), py = pad_y(n), gap = num(n, P::spacing, 0);
    CGFloat cw = MAX(0, frame.size.width - 2 * px);
    NSArray<RXNode*>* kids = laid_out(n);
    if (!kids.count)
        return;
    if (!grid_plain(n, kids)) {
        Frame<CGFloat> widths(g_cells);
        const NSUInteger cols = grid_columns(n, kids.count, cw, gap, widths, g_cells);
        CGFloat y = py;
        for (NSUInteger i = 0; i < kids.count;) {
            NSUInteger col = 0, row = 0, span = 1, j = i;
            CGFloat h = 0;
            for (; j < kids.count; j++) {
                const CGFloat w = grid_cell(kids[j], cols, widths, gap, col, row, span);
                if (row)
                    break;
                h = MAX(h, measure(kids[j], w).height);
                col += span;
            }
            col = 0, row = 0;
            for (NSUInteger k = i; k < j; k++) {
                const CGFloat w = grid_cell(kids[k], cols, widths, gap, col, row, span);
                CGFloat x = px + gap * (CGFloat)col;
                for (NSUInteger q = 0; q < col; q++)
                    x += widths[q];
                NSSize m = measure(kids[k], w);
                const CGFloat kw = has_num(kids[k], P::width) ? MIN(m.width, w) : w;
                place(kids[k], NSMakeRect(x + round((w - kw) / 2), y + round((h - m.height) / 2), kw, m.height));
                col += span;
            }
            y += h + gap;
            i = j;
        }
        return;
    }
    NSUInteger cols = MIN(MAX(1, (NSUInteger)num(n, P::columns, 2)), kids.count);
    CGFloat cell = MAX(0, (cw - gap * (cols - 1)) / cols), y = py;
    for (NSUInteger row = 0; row * cols < kids.count; row++) {
        CGFloat h = 0;
        for (NSUInteger i = row * cols; i < MIN(kids.count, (row + 1) * cols); i++)
            h = MAX(h, measure(kids[i], cell).height);
        for (NSUInteger i = row * cols; i < MIN(kids.count, (row + 1) * cols); i++) {
            NSSize k = measure(kids[i], cell);
            CGFloat w = has_num(kids[i], P::width) ? MIN(k.width, cell) : cell;
            CGFloat x = px + (i % cols) * (cell + gap) + round((cell - w) / 2);
            place(kids[i], NSMakeRect(x, y + round((h - k.height) / 2), w, k.height));
        }
        y += h + gap;
    }
}

static void position_strip(RXNode* n, CGFloat total, CGFloat h) {
    CALayer* strip = content_layer(n);
    CGFloat px = pad_x(n), py = pad_y(n), cw = MAX(0, n.layer.bounds.size.width - 2 * px);
    CGRect f = CGRectMake(round(px - n.box_now.width + MAX(0, cw - n.box_now.height) / 2), py, total, h);
    if (!CGRectEqualToRect(strip.frame, f)) {
        strip.frame = f;
        if (n.doc.natives.count)
            place_natives(n.doc);
    }
}

static void slid_in(RXNode* n) {
    NSArray<RXNode*>* kids = laid_out(n);
    NSInteger cur = MAX(0, MIN((NSInteger)kids.count - 1, (NSInteger)num(n, P::current, 0)));
    if (kids.count)
        replace_quiet(kids[cur]);
}

static void place_pages(RXNode* n, NSRect frame) {
    CGFloat gap = num(n, P::spacing, 0);
    NSArray<RXNode*>* kids = laid_out(n);
    NSInteger cur = MAX(0, MIN((NSInteger)kids.count - 1, (NSInteger)num(n, P::current, 0)));
    CGFloat x = 0, h = 0, at = 0, cur_w = 0;
    for (NSInteger i = 0; i < (NSInteger)kids.count; i++) {
        NSSize k = measure(kids[i], kNatural);
        if (i == cur)
            at = x, cur_w = k.width;
        place(kids[i], NSMakeRect(x, 0, k.width, k.height));
        x += k.width + gap;
        h = MAX(h, k.height);
    }
    CGFloat total = MAX(0, x - gap);
    NSSize want = NSMakeSize(at, cur_w);
    double ms = num(n, P::animation, 500);
    bool placed_before = n.box_to.height > 0;
    if (!NSEqualSizes(want, n.box_to)) {
        [(RXAnim*)n.resize cancel];
        n.resize = nil;
        bool slide = ms > 0 && node_on_screen(n) && !CGRectIsEmpty(content_layer(n).frame) && n.box_to.height > 0;
        n.box_from = n.box_now;
        n.box_to = want;
        if (slide && !n.doc.natives.count) {
            CALayer* strip = content_layer(n);
            NSValue* from = [((CALayer*)strip.presentationLayer ?: strip) valueForKey:@"position"];
            n.box_now = want;
            position_strip(n, total, h);
            __weak RXNode* weak = n;
            ca_glide(strip, @"position", from, ms, kStandard, ^{
                RXNode* n2 = weak;
                if (!n2 || n2.resize)
                    return;
                slid_in(n2);
                schedule_layout(n2.doc, false);
            });
        } else if (slide) {
            __weak RXNode* weak = n;
            RXAnim* a = animate(
                host_of(n), ms,
                ^(double e) {
                    RXNode* n2 = weak;
                    if (!n2)
                        return;
                    n2.box_now = NSMakeSize(n2.box_from.width + (n2.box_to.width - n2.box_from.width) * e,
                                            n2.box_from.height + (n2.box_to.height - n2.box_from.height) * e);
                    CALayer* strip = content_layer(n2);
                    position_strip(n2, strip.frame.size.width, strip.frame.size.height);
                },
                ^{
                    RXNode* n2 = weak;
                    if (!n2)
                        return;
                    slid_in(n2);
                    schedule_layout(n2.doc, false);
                });
            a.curve = kStandard;
            n.resize = a;
        } else {
            n.box_now = want;
        }
    }
    position_strip(n, total, h);
    if (cur != n.page_shown && kids.count) {
        n.page_shown = cur;
        if (placed_before) {
            unplace(kids[cur]);
            place(kids[cur], kids[cur].p_frame);
        }
    }
}

static NSHashTable<RXNode*>* g_sizes_due;
static void tell_sizes(void) {
    NSHashTable<RXNode*>* due = g_sizes_due;
    g_sizes_due = nil;
    for (RXNode* n in due) {
        if (!n.doc || !n.layer)
            continue;
        NSSize s = n.p_frame.size;
        doc_call(n.doc, @"update", @[@(n.uid), @{@"layoutWidth": @(s.width), @"layoutHeight": @(s.height)}]);
    }
}
static void size_due(RXNode* n) {
    if (!g_sizes_due) {
        g_sizes_due = [NSHashTable weakObjectsHashTable];
        dispatch_async(dispatch_get_main_queue(), ^{
            tell_sizes();
        });
    }
    [g_sizes_due addObject:n];
}

void place(RXNode* n, NSRect frame) {
    if (has_limits(n))
        frame.size = NSMakeSize(limit_w(n, frame.size.width), limit_h(n, frame.size.height));
    frame = NSIntegralRectWithOptions(frame, NSAlignAllEdgesOutward);
    reorder_hold(n, &frame);
    if (n.p_valid && NSEqualRects(n.p_frame, frame))
        return;
    if (n.wants_layout && !NSEqualSizes(n.p_frame.size, frame.size))
        size_due(n);
    n.p_frame = frame;
    n.p_valid = true;
    bool moves = is_canvas(n) || is_elem(n, E::Image) || is_elem(n, E::Shapes) || is_elem(n, E::Shader)
        || is_elem(n, E::Canvas) || is_elem(n, E::Graph);
    if (!n.ticker && moves && node_on_screen(n))
        node_link(n, true);
    if (n.appear_due) {
        bool wants = str(n, P::appear, @"").length || (is_elem(n, E::Text) && num(n, P::scramble, 0) > 0);
        if (!wants)
            n.appear_due = false;
        else
            appear_when_shown(n);
    }
    RXDockView* host = is_drawer(n) ? drawer_body(n) : n == n.doc.root ? n.host : nil;
    if (host) {
        if (!NSEqualRects(host.frame, frame))
            host.frame = frame;
        CGRect b = CGRectMake(0, 0, frame.size.width, frame.size.height);
        if (n == n.doc.root && host.window) {
            CGFloat sc = host.window.backingScaleFactor ?: 1;
            NSPoint o = [host convertPoint:NSZeroPoint toView:nil];
            NSPoint snapped = NSMakePoint(round(o.x * sc) / sc, round(o.y * sc) / sc);
            if (!NSEqualPoints(o, snapped)) {
                NSPoint back = [host convertPoint:snapped fromView:nil];
                b.origin = CGPointMake(back.x, back.y);
            }
        }
        if (!CGRectEqualToRect(n.layer.frame, b))
            n.layer.frame = b;
    } else if (!CGRectEqualToRect(layer_frame(n, n.layer), frame)) {
        CGSize was = n.layer.bounds.size;
        set_frame(n, n.layer, frame);
        if (n.editor)
            editor_layout(n);
        if (!CGSizeEqualToSize(was, frame.size)) {
            apply_radius(n);
            apply_shape(n);
            if (is_elem(n, E::Image))
                apply_image_shape(n), image_resized(n);
            else if (is_elem(n, E::Visualiser))
                draw_visualiser(n);
            else if (is_elem(n, E::Arc))
                draw_arc(n);
            else if (is_elem(n, E::Shapes))
                shapes_apply(n, nil);
            else if (is_elem(n, E::Canvas))
                canvas_el_apply(n, nil);
            else if (is_elem(n, E::Graph))
                graph_apply(n, nil);
            else if (is_elem(n, E::Shader))
                shader_resized(n);
            else if (is_elem(n, E::Path))
                path_apply(n);
        }
        if (!flag(n, P::expanded, true))
            apply_expanded(n, false);
        if (is_elem(n, E::Video))
            video_placed(n);
        if (is_elem(n, E::PanePreview))
            pane_preview_update(n);
        if (is_elem(n, E::TabPreview))
            tabpreview_update(n);
    }
    if (is_vlist(n))
        return vlist_place(n, frame);
    if (is_list(n))
        return place_list(n, frame);
    if (is_grid(n))
        return place_grid(n, frame);
    if (is_pages(n))
        return place_pages(n, frame);
    if (!is_box(n))
        return;
    CGFloat px = pad_x(n), py = pad_y(n), gap = num(n, P::spacing, 0);
    CGFloat cw = MAX(0, frame.size.width - 2 * px), ch = MAX(0, frame.size.height - 2 * py);
    NSArray<RXNode*>* kids = laid_out(n);
    const Align ha = align_of(halign(n)), va = align_of(valign(n));
    if (is_row(n) && flag(n, P::flow, false)) {
        const CGFloat line_gap = num(n, P::rowSpacing, gap);
        CGFloat y = py;
        for (NSUInteger i = 0; i < kids.count;) {
            CGFloat used = 0, line = 0;
            NSUInteger j = i;
            for (; j < kids.count; j++) {
                NSSize k = measure(kids[j], cw);
                if (j > i && used + gap + k.width > cw)
                    break;
                used += (j > i ? gap : 0) + k.width;
                line = MAX(line, k.height);
            }
            CGFloat x = px + offset(ha, MAX(0, cw - used));
            for (NSUInteger k = i; k < j; k++) {
                NSSize m = measure(kids[k], cw);
                place(kids[k], NSMakeRect(x, y + offset(va, line - m.height), m.width, m.height));
                x += m.width + gap;
            }
            y += line + line_gap;
            i = j;
        }
    } else if (is_column(n) || is_row(n)) {
        bool row = is_row(n);
        CGFloat room = row ? cw : ch;
        Frame<NSSize> sizes(g_sizes);
        CGFloat used = row ? gap * MAX(0, (CGFloat)kids.count - 1) : column_gaps(kids, gap), grow = 0;
        Frame<CGFloat> natural(g_cells);
        g_cells.resize(natural.base + 2 * kids.count, 0);
        Frame<CGFloat> along(g_cells);
        along.base = natural.base + kids.count;
        for (NSUInteger i = 0; i < kids.count; i++) {
            RXNode* c = kids[i];
            CGFloat g = num(c, P::grow, 0);
            NSSize k = g > 0 && row ? NSZeroSize : measure(c, cw);
            g_sizes.push_back(k);
            if (!row && folded_away(c))
                continue;
            if (g > 0)
                grow += g;
            else
                used += (natural[i] = row ? k.width : k.height);
        }
        CGFloat left = MAX(0, room - used);
        share_room(kids, row, room, used, grow, natural, along);
        CGFloat pos = (row ? px : py) + (grow > 0 ? 0 : offset(row ? ha : va, left));
        for (NSUInteger i = 0; i < kids.count; i++) {
            RXNode* c = kids[i];
            CGFloat g = num(c, P::grow, 0);
            NSSize k = sizes[i];
            if (row) {
                CGFloat w = along[i];
                if (g > 0 || w < k.width)
                    k = measure(c, w);
                bool stretch = va == Align::stretch && !has_num(c, P::height);
                CGFloat h = stretch ? ch : MIN(k.height, ch);
                place(c, NSMakeRect(pos, py + offset(va, ch - h), w, h));
                pos += w + gap;
            } else {
                bool away = folded_away(c);
                CGFloat h = !away ? along[i] : k.height;
                bool stretch = ha == Align::stretch && !has_num(c, P::width);
                CGFloat w = stretch ? cw : MIN(k.width, cw);
                place(c, NSMakeRect(px + offset(ha, cw - w), pos, w, h));
                if (!away)
                    pos += h + gap;
            }
        }
        along.base = g_cells.size();
    } else {
        for (RXNode* c in kids) {
            NSSize k = measure(c, cw);
            CGFloat w = ha == Align::stretch && !has_num(c, P::width) ? cw : MIN(k.width, cw);
            CGFloat h = va == Align::stretch && !has_num(c, P::height) ? ch : MIN(k.height, ch);
            place(c, NSMakeRect(px + offset(ha, cw - w), py + offset(va, ch - h), w, h));
        }
    }
}

static void layout_doc(RXDoc* doc) {
    RXNode* root = doc.root;
    if (is_elem(root, E::Panes))
        return pane_styles_layout();
    if (root.host.superview && shown(root))
        place(root, root.host.frame);
    layout_drawers(doc);
    place_natives(doc);
}

void layout_now(RXDoc* doc) {
    layout_doc(doc);
}

uint64_t g_layout_runs;

static void run_layout(RXDoc* doc) {
    RX_INTERVAL(layout, "doc");
    rx::trace::set_file(engine_file_name(doc));
    doc.layout_pending = false;
    g_layout_runs++;
    if (doc.relayout_chrome) {
        doc.relayout_chrome = false;
        chrome_relayout();
    } else {
        layout_doc(doc);
    }
    scrolls_pay_owed(doc);
    moves_after_layout(doc);
}

static std::vector<RXDoc*> g_due;

void schedule_layout(RXDoc* doc, bool chrome) {
    doc.relayout_chrome |= chrome;
    if (doc.layout_pending)
        return;
    doc.layout_pending = true;
    if (engine_draining()) {
        if (g_due.capacity() == 0)
            g_due.reserve(64);
        g_due.push_back(doc);
        return;
    }
    __weak RXDoc* weak = doc;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (RXDoc* doc2 = weak)
            run_layout(doc2);
    });
}

bool layouts_waiting(void) {
    return !g_due.empty();
}

void layouts_due(void) {
    size_t kept = 0;
    for (size_t i = 0; i < g_due.size(); i++) {
        RXDoc* doc = g_due[i];
        g_due[i] = nil;
        if (doc.layout_pending && engine_job_open(doc))
            g_due[kept++] = doc;
        else if (doc.layout_pending)
            run_layout(doc);
    }
    g_due.resize(kept);
    vlists_due();
}
