// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <vector>

#include "core/text/lexer.h"
#include "core/text/rope.h"

namespace rx::text {

class Highlighter {
  public:
    static constexpr size_t k_spacing = 8192;
    static constexpr size_t k_margin = Lang::k_lookahead;
    static constexpr size_t k_lookback = Lang::k_lookahead;

    Highlighter(const Lang& lang, const Rope& rope);

    void edited(size_t at, size_t removed, size_t added);

    bool step(size_t budget);
    bool done() const noexcept { return done_; }

    bool tokens(size_t from, size_t to, size_t budget, void* ctx, Lang::Mark mark);

    bool take_changed() noexcept {
        const bool c = changed_;
        changed_ = false;
        return c;
    }

  private:
    struct Point {
        Lang::Resume r;
        bool edit_before = false;
    };
    size_t last_known(size_t at) const noexcept;
    void next();

    const Lang& lang_;
    const Rope& rope_;
    std::vector<Point> points_;
    size_t known_ = 1;
    bool done_ = false, changed_ = false;
    size_t spent_ = 0;
    std::u16string buf_;
};

class TokenList {
  public:
    struct Run {
        uint32_t at, len;
        Token kind;
    };
    TokenList() { places_.push_back({}); }

    bool update(const Lang& lang, std::u16string_view text);
    std::span<const Run> runs() const noexcept { return runs_; }

  private:
    static constexpr size_t k_spacing = 8192;
    struct Place {
        Lang::Resume r;
        size_t run = 0;
    };
    const Lang* lang_ = nullptr;
    std::u16string text_;
    std::vector<Run> runs_, fresh_;
    std::vector<Place> places_, kept_;
};

}
