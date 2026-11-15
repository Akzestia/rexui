// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/text/highlight.h"

#include <algorithm>
#include <cstddef>

namespace rx::text {

Highlighter::Highlighter(const Lang& lang, const Rope& rope) : lang_(lang), rope_(rope) {
    points_.push_back({});
}

void Highlighter::edited(size_t at, size_t removed, size_t added) {
    const size_t back = at > k_lookback ? at - k_lookback : 0;
    size_t first = 1;
    while (first < points_.size() && points_[first].r.at <= back)
        first++;
    size_t after = first;
    while (after < points_.size() && points_[after].r.at < at + removed)
        after++;
    points_.erase(points_.begin() + static_cast<long>(first), points_.begin() + static_cast<long>(after));
    for (size_t k = first; k < points_.size(); k++)
        points_[k].r.at = points_[k].r.at + added - removed;
    if (first < points_.size())
        points_[first].edit_before = true;
    known_ = std::min(known_, first);
    done_ = false;
}

void Highlighter::next() {
    const Lang::Resume base = points_[known_ - 1].r;
    const size_t size = rope_.size();
    const bool hoping = known_ < points_.size();
    size_t target = base.at + k_spacing;
    if (hoping && points_[known_].r.at <= base.at + 2 * k_spacing)
        target = points_[known_].r.at;
    size_t span = target - base.at + k_margin;
    Lang::Resume r;
    for (;;) {
        span = std::min(span, size - base.at);
        if (buf_.size() < span)
            buf_.resize(span);
        rope_.read(base.at, span, buf_.data());
        r = base;
        r.at = 0;
        lang_.run(std::u16string_view(buf_.data(), span), r, target - base.at, nullptr, nullptr);
        spent_ += r.at;
        if (r.at < span || base.at + span >= size)
            break;
        span *= 2;
    }
    r.at += base.at;
    while (known_ < points_.size() && points_[known_].r.at <= r.at) {
        if (points_[known_].r == r) {
            points_[known_].edit_before = false;
            known_++;
            while (known_ < points_.size() && !points_[known_].edit_before)
                known_++;
            spent_ += 1;
            if (known_ == points_.size())
                done_ = true;
            return;
        }
        const bool mark = points_[known_].edit_before;
        points_.erase(points_.begin() + static_cast<long>(known_));
        if (mark && known_ < points_.size())
            points_[known_].edit_before = true;
        changed_ = true;
    }
    if (r.at >= size) {
        done_ = known_ == points_.size();
        if (!done_) {
            points_.resize(known_);
            done_ = true;
        }
        return;
    }
    Point p;
    p.r = r;
    if (known_ < points_.size())
        changed_ = true;
    points_.insert(points_.begin() + static_cast<long>(known_), p);
    known_++;
}

bool Highlighter::step(size_t budget) {
    spent_ = 0;
    while (!done_ && spent_ < budget)
        next();
    return !done_;
}

size_t Highlighter::last_known(size_t at) const noexcept {
    size_t lo = 0, hi = known_ - 1;
    while (lo < hi) {
        const size_t mid = (lo + hi + 1) / 2;
        if (points_[mid].r.at <= at)
            lo = mid;
        else
            hi = mid - 1;
    }
    return lo;
}

bool Highlighter::tokens(size_t from, size_t to, size_t budget, void* ctx, Lang::Mark mark) {
    const size_t size = rope_.size();
    to = std::min(to, size);
    if (from >= to)
        return true;
    spent_ = 0;
    while (!done_ && points_[known_ - 1].r.at + k_spacing <= from && spent_ < budget)
        next();
    Lang::Resume start = points_[last_known(from)].r;
    const bool exact = done_ || points_[known_ - 1].r.at + k_spacing > from;
    if (!exact && from - start.at > 4 * k_spacing) {
        const size_t line = rope_.line_start(rope_.line_of(from - 2 * k_spacing));
        start = Lang::Resume{};
        start.at = line;
    }
    const size_t base = start.at;
    const size_t span = std::min(to + k_margin, size) - base;
    if (buf_.size() < span)
        buf_.resize(span);
    rope_.read(base, span, buf_.data());
    struct Cut {
        size_t base, from, to;
        void* ctx;
        Lang::Mark mark;
    } cut{base, from, to, ctx, mark};
    Lang::Resume r = start;
    r.at = 0;
    lang_.run(std::u16string_view(buf_.data(), span), r, span, &cut,
              [](void* c, Token kind, uint32_t at, uint32_t len) {
                  const auto* x = static_cast<const Cut*>(c);
                  const size_t a = std::max(x->base + at, x->from), b = std::min(x->base + at + len, x->to);
                  if (a < b)
                      x->mark(x->ctx, kind, static_cast<uint32_t>(a - x->from), static_cast<uint32_t>(b - a));
              });
    return exact;
}

bool TokenList::update(const Lang& lang, std::u16string_view now) {
    const bool same_lang = lang_ == &lang;
    if (!same_lang) {
        lang_ = &lang;
        text_.clear(), runs_.clear();
        places_.assign(1, {});
    }
    const std::u16string_view was(text_);
    const size_t common = std::min(was.size(), now.size());
    const size_t head = static_cast<size_t>(
        std::mismatch(was.begin(), was.begin() + static_cast<ptrdiff_t>(common), now.begin()).first - was.begin());
    if (head == was.size() && head == now.size())
        return !same_lang;
    size_t tail = 0;
    while (tail < common - head && was[was.size() - 1 - tail] == now[now.size() - 1 - tail])
        tail++;
    const size_t old_edit_end = was.size() - tail, new_edit_end = now.size() - tail;
    const ptrdiff_t delta = static_cast<ptrdiff_t>(now.size()) - static_cast<ptrdiff_t>(was.size());

    size_t keep = 1;
    while (keep < places_.size() && places_[keep].r.at + Lang::k_lookahead <= head)
        keep++;
    kept_.assign(places_.begin() + static_cast<ptrdiff_t>(keep), places_.end());
    places_.resize(keep);
    const size_t from_run = places_.back().run;
    fresh_.clear();

    Lang::Resume r = places_.back().r;
    size_t o = 0;
    while (o < kept_.size() && kept_[o].r.at < old_edit_end)
        o++;
    bool joined = false;
    while (r.at < now.size()) {
        size_t target = r.at + k_spacing;
        if (r.at >= new_edit_end && o < kept_.size()) {
            const size_t there = static_cast<size_t>(static_cast<ptrdiff_t>(kept_[o].r.at) + delta);
            if (there > r.at && there <= r.at + 2 * k_spacing)
                target = there;
        }
        lang.run(now, r, target, this, [](void* c, Token kind, uint32_t at, uint32_t len) {
            static_cast<TokenList*>(c)->fresh_.push_back({at, len, kind});
        });
        if (r.at >= now.size())
            break;
        places_.push_back({r, from_run + fresh_.size()});
        if (r.at < new_edit_end)
            continue;
        while (o < kept_.size() && static_cast<ptrdiff_t>(kept_[o].r.at) + delta < static_cast<ptrdiff_t>(r.at))
            o++;
        if (o < kept_.size() && static_cast<ptrdiff_t>(kept_[o].r.at) + delta == static_cast<ptrdiff_t>(r.at)) {
            Lang::Resume same = kept_[o].r;
            same.at = r.at;
            if (same == r) {
                joined = true;
                break;
            }
        }
    }
    const size_t new_count = from_run + fresh_.size();
    if (joined) {
        const size_t rejoin_run = kept_[o].run;
        const ptrdiff_t moved = static_cast<ptrdiff_t>(new_count) - static_cast<ptrdiff_t>(rejoin_run);
        for (size_t k = rejoin_run; k < runs_.size(); k++)
            runs_[k].at = static_cast<uint32_t>(static_cast<ptrdiff_t>(runs_[k].at) + delta);
        if (moved > 0)
            runs_.insert(runs_.begin() + static_cast<ptrdiff_t>(rejoin_run), static_cast<size_t>(moved),
                         Run{0, 0, Token::comment});
        else if (moved < 0)
            runs_.erase(runs_.begin() + static_cast<ptrdiff_t>(new_count),
                        runs_.begin() + static_cast<ptrdiff_t>(rejoin_run));
        for (size_t k = o + 1; k < kept_.size(); k++) {
            Place p = kept_[k];
            p.r.at = static_cast<size_t>(static_cast<ptrdiff_t>(p.r.at) + delta);
            p.run = static_cast<size_t>(static_cast<ptrdiff_t>(p.run) + moved);
            places_.push_back(p);
        }
    } else {
        runs_.resize(new_count);
    }
    std::copy(fresh_.begin(), fresh_.end(), runs_.begin() + static_cast<ptrdiff_t>(from_run));
    text_.replace(head, was.size() - head - tail, now.substr(head, new_edit_end - head));
    return true;
}

}
