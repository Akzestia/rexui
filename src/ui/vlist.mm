// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include "core/list/heights.h"

#include <vector>

@interface RXVList : NSObject {
   @public
    rx::list::Heights heights;
    uint32_t first, count;
    uint32_t told;
    bool asked, due, placing;
    bool anchored;
    int64_t anchor_row;
    double anchor_into;
}
@end
@implementation RXVList
@end

static RXVList* state_of(RXNode* n) {
    if (!n.vlist)
        n.vlist = [RXVList new];
    return n.vlist;
}

bool is_vlist(RXNode* n) {
    return is_list(n) && flag(n, P::virtualized, false);
}

CGFloat vlist_content_height(RXNode* n) {
    return state_of(n)->heights.total() + 2 * pad_y(n);
}

void vlist_due(RXNode* n);
void vlist_rows(RXNode* n, uint32_t count) {
    RXVList* s = state_of(n);
    const bool same = count == s->told && n.p_valid;
    s->told = count;
    s->heights.resize(count);
    if (same)
        return vlist_due(n);
    invalidate(n);
    if (n.doc)
        schedule_layout(n.doc, false);
}

void vlist_shift(RXNode* n, int64_t d) {
    RXVList* s = state_of(n);
    auto& hs = s->heights;
    RXScrollLayer* sv = [n.layer isKindOfClass:RXScrollLayer.class] ? (RXScrollLayer*)n.layer : nil;
    if (!s->anchored && sv && n.p_valid) {
        const double top = sv.offset - pad_y(n);
        const uint32_t a = hs.at(top);
        s->anchored = top > 0;
        s->anchor_row = a, s->anchor_into = top - hs.y(a);
    }
    if (s->anchored) {
        s->anchor_row -= d;
        if (s->anchor_row < 0)
            s->anchor_row = 0, s->anchor_into = 0;
    }
    hs.shift(d);
    vlist_due(n);
}

static std::vector<RXNode*> g_due;

void vlist_due(RXNode* n) {
    RXVList* s = state_of(n);
    if (s->due)
        return;
    s->due = true;
    g_due.push_back(n);
}

void vlist_row(RXNode* row, uint32_t index) {
    row->_row = index + 1;
    row->_p_valid = false;
    if (RXNode* list = row->up)
        vlist_due(list);
}

void vlists_due(void) {
    for (size_t i = 0; i < g_due.size(); i++) {
        RXNode* n = g_due[i];
        g_due[i] = nil;
        RXVList* s = n.vlist;
        if (!s)
            continue;
        s->due = false;
        if (n.p_valid && is_vlist(n))
            vlist_place(n, n.p_frame);
    }
    g_due.clear();
}

static constexpr CGFloat k_base_step = 1 << 20;
static CGFloat base_for(CGFloat offset) {
    return floor(offset / k_base_step) * k_base_step;
}

void vlist_ask(RXNode* n) {
    RXVList* s = state_of(n);
    auto& hs = s->heights;
    RXScrollLayer* sv = (RXScrollLayer*)n.layer;
    const CGFloat h = sv.bounds.size.height, py = pad_y(n);
    if (h <= 0 || !n.doc)
        return;
    if (!s->placing && sv.base != base_for(sv.offset) && n.p_valid)
        return vlist_place(n, n.p_frame);
    CGFloat over = num(n, P::overscan, -1);
    if (over < 0)
        over = MAX(h, 240);
    const uint32_t rows = hs.count();
    const double top = sv.offset - py;
    uint32_t in_a = hs.at(top - over / 2), in_b = hs.at(top + h + over / 2);
    uint32_t sel_lo = 0, sel_hi = 0;
    const bool sel = rows && text_selection_rows(n, &sel_lo, &sel_hi) && sel_hi < rows;
    if (sel)
        in_a = MIN(in_a, sel_lo), in_b = MAX(in_b, sel_hi);
    if (s->asked && rows && in_a >= s->first && in_b < s->first + s->count)
        return;
    uint32_t a = hs.at(top - over), b = hs.at(top + h + over) + 1;
    if (sel) {
        constexpr uint32_t k_most = 4000;
        const uint32_t sa = MIN(a, sel_lo), sb = MAX(b, sel_hi + 1);
        if (sb - sa <= (b - a) + k_most)
            a = sa, b = sb;
    }
    if (s->asked && a == s->first && b - a == s->count)
        return;
    s->asked = true, s->first = a, s->count = b - a;
    engine_list_window(n.doc, n.uid, a, b - a);
}

bool g_row_recycled;

void vlist_place(RXNode* n, NSRect frame) {
    RXVList* s = state_of(n);
    auto& hs = s->heights;
    RXScrollLayer* sv = (RXScrollLayer*)n.layer;
    const CGFloat h = frame.size.height, w = frame.size.width, px = pad_x(n), py = pad_y(n);
    const CGFloat fixed = num(n, P::rowHeight, 0);
    hs.set_gap(num(n, P::spacing, 0));
    hs.set_fixed(fixed);
    const bool at_end = sv.offset >= sv.maxOffset - 4;
    const double top = sv.offset - py;
    const bool anchored = s->anchored && hs.count();
    s->anchored = false;
    const uint32_t anchor = anchored ? (uint32_t)MIN(s->anchor_row, (int64_t)hs.count() - 1) : hs.at(top);
    const double anchor_y = anchored ? NAN : hs.y(anchor), into = anchored ? s->anchor_into : top - anchor_y;
    s->placing = true;
    if (const CGFloat b = base_for(sv.offset); b != sv.base)
        sv.base = b;
    const CGFloat base = sv.base;

    CGFloat cw = MAX(0, w - 2 * px);
    if (hs.total() + 2 * py > h)
        cw = MAX(0, cw - num(n, P::gutter, 10));
    NSArray<RXNode*>* kids = laid_out(n);
    if (!fixed)
        for (RXNode* c in kids)
            if (c->_row)
                hs.measure(c->_row - 1, measure(c, cw).height);
    for (RXNode* c in kids) {
        if (!c->_row || c->_row > hs.count())
            continue;
        const uint32_t i = c->_row - 1;
        const CGFloat kw = has_num(c, P::width) ? MIN(measure(c, cw).width, cw) : cw;
        g_row_recycled = c->_placed_row != c->_row;
        c->_placed_row = c->_row;
        place(c, NSMakeRect(px, py + hs.y(i) - base, kw, hs.height(i)));
        g_row_recycled = false;
    }
    [sv setContentHeight:hs.total() + 2 * py];
    if (flag(n, P::follow, false) && at_end)
        sv.offset = sv.maxOffset;
    else if (top > 0 && (anchored || hs.y(anchor) != anchor_y))
        sv.offset = py + hs.y(anchor) + into;
    const NSInteger reveal = (NSInteger)num(n, P::reveal, -1);
    const NSUInteger rows = hs.count();
    if ((n.reveal_pending || n.revealed_of != rows) && reveal >= 0 && (NSUInteger)reveal < rows) {
        const CGFloat ry = py + hs.y((uint32_t)reveal), rh = hs.height((uint32_t)reveal);
        if ([str(n, P::revealAlign, @"") isEqualToString:@"center"])
            [sv glideTo:(2 * ry + rh - h) / 2 ms:n.revealed_of == rows ? num(n, P::revealAnimation, 0) : 0];
        else
            [sv reveal:NSMakeRect(0, ry - py, w, rh + 2 * py)];
    }
    n.reveal_pending = false;
    n.revealed_of = rows;
    sv.fade = num(n, P::fade, 0);
    if (n.m_valid && !has_num(n, P::height) && num(n, P::grow, 0) <= 0) {
        CGFloat most = num(n, P::maxHeight, 0), want = hs.total() + 2 * py;
        if (most > 0)
            want = MIN(want, most);
        if (ceil(want) != ceil(n.m_size.height) && n.doc) {
            invalidate(n);
            schedule_layout(n.doc, false);
        }
    }
    s->placing = false;
    vlist_ask(n);
}
