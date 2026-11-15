// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/text/lexer.h"

namespace rx::text {

namespace {

constexpr bool is_ascii_digit(char16_t c) {
    return c >= u'0' && c <= u'9';
}
constexpr bool is_alpha(char16_t c) {
    return (c >= u'a' && c <= u'z') || (c >= u'A' && c <= u'Z');
}
constexpr bool blank(char16_t c) {
    return c == u' ' || c == u'\t' || c == u'\r' || c == 0x0C;
}

constexpr size_t k_word_most = 256, k_blanks_most = 64, k_regex_most = 1024, k_flags_most = 16, k_value_most = 1024;
constexpr size_t k_level_most = 255;
static_assert(k_word_most + k_blanks_most + 64 <= Lang::k_lookahead && k_regex_most + k_flags_most <= Lang::k_lookahead
              && k_word_most + k_blanks_most + k_value_most + 64 <= Lang::k_lookahead);

inline bool at(std::u16string_view s, size_t i, std::u16string_view what) noexcept {
    if (i + what.size() > s.size())
        return false;
    for (size_t k = 0; k < what.size(); k++)
        if (s[i + k] != what[k])
            return false;
    return true;
}

uint32_t hash_of(std::u16string_view w) noexcept {
    uint32_t h = 2166136261u;
    for (char16_t c : w)
        h = (h ^ c) * 16777619u;
    return h;
}

}

void Lang::can_start(char16_t c) noexcept {
    if (c < 128)
        starts_[c] = true;
    else
        starts_high_ = true;
}

Lang::Lang(const Spec& spec)
    : long_comment_(spec.long_comment),
      assign_(spec.assign),
      preprocessor_(spec.preprocessor),
      digit_sep_(spec.digit_sep),
      type_case_(spec.type_case),
      bit_ints_(spec.bit_ints),
      bang_macros_(spec.bang_macros),
      long_brackets_(spec.long_brackets),
      regex_(spec.regex),
      members_(spec.members),
      raw_(spec.raw) {
    auto copy = [](std::span<const std::u16string_view> from, std::vector<std::u16string>& to) {
        for (std::u16string_view v : from)
            if (!v.empty())
                to.emplace_back(v);
    };
    copy(spec.line_comments, line_comments_);
    copy(spec.line_strings, line_strings_);
    copy(spec.key_before, key_before_);
    copy(spec.calls, calls_);
    copy(spec.call_after, call_after_);
    if (spec.calls.empty())
        calls_.emplace_back(u"(");
    for (const BlockSpec& b : spec.block_comments)
        if (!b.open.empty() && !b.close.empty())
            blocks_.push_back({std::u16string(b.open), std::u16string(b.close), b.nested});
    for (const StringSpec& r : spec.strings)
        if (!r.open.empty() && !r.close.empty()) {
            const bool holes = !r.hole_open.empty() && !r.hole_close.empty();
            strings_.push_back({std::u16string(r.open), std::u16string(r.close), r.escape, r.multiline, r.char_literal,
                                std::u16string(holes ? r.hole_open : std::u16string_view()),
                                std::u16string(holes ? r.hole_close : std::u16string_view())});
        }
    if (strings_.size() > 0xFFFF)
        strings_.resize(0xFFFF);
    for (const PairSpec& p : spec.attributes)
        if (!p.open.empty() && !p.close.empty())
            attributes_.push_back({std::u16string(p.open), std::u16string(p.close)});
    if (blocks_.size() > 0xFFFF)
        blocks_.resize(0xFFFF);
    if (attributes_.size() > 0xFFFF)
        attributes_.resize(0xFFFF);
    for (const SigilSpec& g : spec.sigils)
        if (g.sigil)
            sigils_.push_back(g);
    for (char16_t c = 0; c < 128; c++) {
        word_start_[c] = is_alpha(c) || c == u'_';
        word_char_[c] = word_start_[c] || is_ascii_digit(c);
    }
    for (char16_t c : spec.word_chars)
        if (c < 128 && !blank(c) && c != u'\n')
            word_start_[c] = word_char_[c] = true;
    for (const auto& v : line_comments_)
        can_start(v[0]);
    for (const auto& v : line_strings_)
        can_start(v[0]);
    for (const Block& b : blocks_)
        can_start(b.open[0]);
    for (const Str& r : strings_)
        can_start(r.open[0]);
    for (const Pair& p : attributes_)
        can_start(p.open[0]);
    if (!long_comment_.empty())
        can_start(long_comment_[0]);
    size_t cap = 16;
    while (cap < (spec.keywords.size() + spec.types.size() + spec.values.size()) * 2 + 2)
        cap *= 2;
    table_.resize(cap);
    for (std::u16string_view w : spec.values)
        add_word(w, Token::keyword, true);
    for (std::u16string_view w : spec.keywords)
        add_word(w, Token::keyword, false);
    for (std::u16string_view w : spec.types)
        add_word(w, Token::type, false);
}

void Lang::add_word(std::u16string_view w, Token kind, bool value) {
    if (w.empty())
        return;
    const uint32_t h = hash_of(w), m = static_cast<uint32_t>(table_.size()) - 1;
    for (uint32_t k = h & m;; k = (k + 1) & m) {
        Word& slot = table_[k];
        if (slot.len == 0) {
            slot.at = static_cast<uint32_t>(words_.size());
            slot.len = static_cast<uint32_t>(w.size());
            slot.hash = h;
            slot.kind = kind;
            slot.value = value;
            words_ += w;
            return;
        }
        if (slot.hash == h && std::u16string_view(words_).substr(slot.at, slot.len) == w)
            return;
    }
}

const Lang::Word* Lang::word_of(std::u16string_view w) const noexcept {
    const uint32_t h = hash_of(w), m = static_cast<uint32_t>(table_.size()) - 1;
    for (uint32_t k = h & m;; k = (k + 1) & m) {
        const Word& slot = table_[k];
        if (slot.len == 0)
            return nullptr;
        if (slot.hash == h && std::u16string_view(words_).substr(slot.at, slot.len) == w)
            return &slot;
    }
}

void Lang::lex(std::u16string_view s, void* ctx, Mark mark) const noexcept {
    Resume r;
    run(s, r, s.size(), ctx, mark);
}

void Lang::run(std::u16string_view s, Resume& resume, size_t stop, void* ctx, Mark mark) const noexcept {
    const size_t n = s.size(), limit = stop < n ? stop : n;
    const char16_t* const u = s.data();
    Resume r = resume;
    size_t i = r.at;
    auto put = [&](Token kind, size_t from, size_t to) {
        if (to > from && mark)
            mark(ctx, kind, static_cast<uint32_t>(from), static_cast<uint32_t>(to - from));
    };
    auto is_word = [&](char16_t c) { return c < 128 ? word_char_[c] : true; };
    auto starts_word = [&](char16_t c) { return c < 128 ? word_start_[c] : true; };
    auto a_line_comment = [&](size_t e) {
        for (const std::u16string& lc : line_comments_)
            if (u[e] == lc[0] && at(s, e, lc))
                return true;
        return false;
    };

    auto stopped_in = [&](Mode m, size_t e) {
        i = e;
        r.mode = m;
        return true;
    };
    auto ended = [&](size_t e) {
        i = e;
        r.mode = Mode::code;
        r.rule = 0;
        r.depth = 0;
        return false;
    };
    auto in_block = [&](size_t from, size_t e) {
        const Block& b = blocks_[r.rule];
        const char16_t close = b.close[0], open = b.open[0];
        uint32_t depth = r.depth;
        for (;;) {
            if (e >= limit) {
                put(Token::comment, from, e);
                r.depth = depth;
                return stopped_in(Mode::block, e);
            }
            const char16_t c = u[e];
            if (c == close && at(s, e, b.close)) {
                e += b.close.size();
                if (--depth == 0) {
                    put(Token::comment, from, e);
                    return ended(e);
                }
            } else if (b.nested && c == open && at(s, e, b.open)) {
                e += b.open.size(), depth++;
            } else {
                e++;
            }
        }
    };
    auto in_string = [&](size_t from, size_t e) {
        const Str& q = strings_[r.rule];
        const char16_t close = q.close[0], hole = q.hole_open.empty() ? char16_t(0) : q.hole_open[0];
        for (;;) {
            if (e >= limit) {
                put(Token::string, from, e);
                return stopped_in(Mode::string, e);
            }
            const char16_t c = u[e];
            if (q.escape && c == q.escape && e + 1 < n) {
                e += 2;
            } else if (c == close && at(s, e, q.close)) {
                e += q.close.size();
                put(Token::string, from, e);
                r.prev = Prev::value;
                return ended(e);
            } else if (hole && c == hole && r.holes < k_holes && at(s, e, q.hole_open)) {
                put(Token::string, from, e);
                const size_t in = e + q.hole_open.size();
                put(Token::meta, e, in);
                r.hole[r.holes++] = {r.rule, 0};
                r.prev = Prev::none;
                return ended(in);
            } else if (c == u'\n' && !q.multiline) {
                put(Token::string, from, e);
                r.prev = Prev::value;
                return ended(e);
            } else {
                e++;
            }
        }
    };
    auto in_raw_cpp = [&](size_t from, size_t e) {
        const std::u16string_view delim(r.delim, r.depth);
        for (;;) {
            if (e >= limit) {
                put(Token::string, from, e);
                return stopped_in(Mode::raw_cpp, e);
            }
            if (u[e] == u')' && at(s, e + 1, delim) && e + 1 + delim.size() < n && u[e + 1 + delim.size()] == u'"') {
                e += delim.size() + 2;
                put(Token::string, from, e);
                for (char16_t& d : r.delim)
                    d = 0;
                r.prev = Prev::value;
                return ended(e);
            }
            e++;
        }
    };
    auto in_raw_rust = [&](size_t from, size_t e) {
        const size_t hashes = r.depth;
        for (;;) {
            if (e >= limit) {
                put(Token::string, from, e);
                return stopped_in(Mode::raw_rust, e);
            }
            if (u[e] == u'"') {
                size_t k = 0;
                while (k < hashes && e + 1 + k < n && u[e + 1 + k] == u'#')
                    k++;
                if (k == hashes) {
                    e += hashes + 1;
                    put(Token::string, from, e);
                    r.prev = Prev::value;
                    return ended(e);
                }
            }
            e++;
        }
    };
    auto in_long = [&](Token kind, Mode m, size_t from, size_t e) {
        const size_t level = r.depth;
        for (;;) {
            if (e >= limit) {
                put(kind, from, e);
                return stopped_in(m, e);
            }
            if (u[e] == u']') {
                size_t k = e + 1;
                while (k < n && u[k] == u'=' && k - e - 1 < level)
                    k++;
                if (k - e - 1 == level && k < n && u[k] == u']') {
                    e = k + 1;
                    put(kind, from, e);
                    if (kind == Token::string)
                        r.prev = Prev::value;
                    return ended(e);
                }
            }
            e++;
        }
    };
    auto in_attribute = [&](size_t from, size_t e) {
        const Pair& p = attributes_[r.rule];
        const char16_t inc = p.open.back(), close = p.close[0];
        uint32_t depth = r.depth;
        for (;;) {
            if (e >= limit) {
                put(Token::meta, from, e);
                r.depth = depth;
                return stopped_in(Mode::attribute, e);
            }
            const char16_t c = u[e];
            if (c == close && at(s, e, p.close)) {
                e += p.close.size();
                if (--depth == 0) {
                    put(Token::meta, from, e);
                    return ended(e);
                }
            } else {
                if (c == inc)
                    depth++;
                e++;
            }
        }
    };
    auto in_preprocessor = [&](size_t from, size_t e) {
        for (;;) {
            if (e >= n || (e >= limit && (e == 0 || u[e - 1] != u'\\'))) {
                put(Token::meta, from, e);
                return stopped_in(Mode::preprocessor, e);
            }
            const char16_t c = u[e];
            if (c == u'\n') {
                if (e == 0 || u[e - 1] != u'\\')
                    break;
                e++;
            } else if (a_line_comment(e)) {
                break;
            } else {
                e++;
            }
        }
        put(Token::meta, from, e);
        return ended(e);
    };
    auto in_line = [&](bool marked, Token kind, Mode m, size_t from, size_t e) {
        for (;;) {
            if (e >= limit) {
                if (marked)
                    put(kind, from, e);
                return stopped_in(m, e);
            }
            if (u[e] == u'\n') {
                if (marked)
                    put(kind, from, e);
                return ended(e);
            }
            e++;
        }
    };
    auto in_plain_word = [&](size_t e) {
        for (;;) {
            if (e >= limit)
                return stopped_in(Mode::plain_word, e);
            if (!is_word(u[e]))
                return ended(e);
            e++;
        }
    };
    auto long_level = [&](size_t j) -> int {
        if (j >= n || u[j] != u'[')
            return -1;
        size_t k = j + 1;
        while (k < n && u[k] == u'=' && k - j - 1 < k_level_most)
            k++;
        return k < n && u[k] == u'[' ? static_cast<int>(k - j - 1) : -1;
    };
    auto key_value = [&]() {
        const size_t cap = i + k_word_most < n ? i + k_word_most : n;
        size_t e = i;
        const char16_t eq = assign_[0];
        while (e < cap && u[e] != u'\n' && !(u[e] == eq && at(s, e, assign_)))
            e++;
        if (e >= n || u[e] == u'\n')
            return ended(e);
        if (e >= cap)
            return in_line(false, Token::key, Mode::plain_line, e, e);
        size_t key_end = e;
        while (key_end > i && blank(u[key_end - 1]))
            key_end--;
        put(Token::key, i, key_end);
        size_t v = e + assign_.size();
        for (size_t k = 0; k < k_blanks_most && v < n && blank(u[v]); k++)
            v++;
        const size_t value_cap = v + k_value_most < n ? v + k_value_most : n;
        size_t end = v;
        while (end < value_cap && u[end] != u'\n')
            end++;
        if (end < n && u[end] != u'\n')
            return in_line(true, Token::string, Mode::value, v, end);
        size_t trimmed = end;
        while (trimmed > v && blank(u[trimmed - 1]))
            trimmed--;
        if (trimmed > v) {
            char16_t folded[16];
            const size_t len = trimmed - v;
            bool word = false;
            if (len <= 16) {
                for (size_t k = 0; k < len; k++)
                    folded[k] = u[v + k] >= u'A' && u[v + k] <= u'Z' ? static_cast<char16_t>(u[v + k] + 32) : u[v + k];
                const Word* w = word_of(std::u16string_view(folded, len));
                word = w && w->kind == Token::keyword;
            }
            bool number = true;
            for (size_t k = v; k < trimmed && number; k++) {
                const char16_t c = u[k];
                number =
                    is_ascii_digit(c) || c == u'.' || c == u',' || c == u'-' || c == u'+' || c == u' ' || c == u'\t';
            }
            put(word ? Token::keyword : number ? Token::number : Token::string, v, trimmed);
        }
        return ended(end);
    };

    bool paused = false;
    switch (r.mode) {
    case Mode::code:
        break;
    case Mode::block:
        paused = in_block(i, i);
        break;
    case Mode::string:
        paused = in_string(i, i);
        break;
    case Mode::raw_cpp:
        paused = in_raw_cpp(i, i);
        break;
    case Mode::raw_rust:
        paused = in_raw_rust(i, i);
        break;
    case Mode::long_string:
        paused = in_long(Token::string, Mode::long_string, i, i);
        break;
    case Mode::long_comment:
        paused = in_long(Token::comment, Mode::long_comment, i, i);
        break;
    case Mode::attribute:
        paused = in_attribute(i, i);
        break;
    case Mode::preprocessor:
        paused = in_preprocessor(i, i);
        break;
    case Mode::line_comment:
        paused = in_line(true, Token::comment, Mode::line_comment, i, i);
        break;
    case Mode::line_string:
        paused = in_line(true, Token::string, Mode::line_string, i, i);
        break;
    case Mode::value:
        paused = in_line(true, Token::string, Mode::value, i, i);
        break;
    case Mode::plain_line:
        paused = in_line(false, Token::key, Mode::plain_line, i, i);
        break;
    case Mode::plain_word:
        paused = in_plain_word(i);
        break;
    }
    while (!paused && i < limit) {
        const char16_t c = u[i];
        if (c == u'\n') {
            r.line_start = true;
            i++;
            continue;
        }
        if (blank(c)) {
            i++;
            continue;
        }
        const bool first_on_line = r.line_start;
        r.line_start = false;

        if (first_on_line && !assign_.empty() && !a_line_comment(i)) {
            paused = key_value();
            continue;
        }
        if (first_on_line && preprocessor_ && c == preprocessor_) {
            paused = in_preprocessor(i, i + 1);
            continue;
        }

        if (c < 128 ? starts_[c] : starts_high_) {
            bool taken = false;
            if (!long_comment_.empty() && at(s, i, long_comment_)) {
                const int level = long_level(i + long_comment_.size());
                if (level >= 0) {
                    r.depth = static_cast<uint32_t>(level);
                    paused = in_long(Token::comment, Mode::long_comment, i,
                                     i + long_comment_.size() + static_cast<size_t>(level) + 2);
                    continue;
                }
            }
            for (const std::u16string& lc : line_comments_) {
                if (c != lc[0] || !at(s, i, lc))
                    continue;
                paused = in_line(true, Token::comment, Mode::line_comment, i, i + lc.size());
                taken = true;
                break;
            }
            if (taken)
                continue;
            for (size_t k = 0; k < blocks_.size(); k++) {
                if (c != blocks_[k].open[0] || !at(s, i, blocks_[k].open))
                    continue;
                r.rule = static_cast<uint16_t>(k), r.depth = 1;
                paused = in_block(i, i + blocks_[k].open.size());
                taken = true;
                break;
            }
            if (taken)
                continue;
            for (const std::u16string& ls : line_strings_) {
                if (c != ls[0] || !at(s, i, ls))
                    continue;
                r.prev = Prev::value;
                paused = in_line(true, Token::string, Mode::line_string, i, i + ls.size());
                taken = true;
                break;
            }
            if (taken)
                continue;
            for (size_t k = 0; k < attributes_.size(); k++) {
                if (c != attributes_[k].open[0] || !at(s, i, attributes_[k].open))
                    continue;
                r.rule = static_cast<uint16_t>(k), r.depth = 1;
                paused = in_attribute(i, i + attributes_[k].open.size());
                taken = true;
                break;
            }
            if (taken)
                continue;
        }

        if (raw_ == Raw::cpp && (c == u'R' || c == u'u' || c == u'U' || c == u'L')) {
            size_t q = i;
            if (at(s, q, u"u8"))
                q += 2;
            else if (u[q] != u'R')
                q++;
            if (q + 1 < n && u[q] == u'R' && u[q + 1] == u'"') {
                size_t d = q + 2;
                while (d < n && d - (q + 2) < 16 && u[d] != u'(' && u[d] != u'\n' && u[d] != u'"')
                    d++;
                if (d < n && u[d] == u'(') {
                    r.depth = static_cast<uint32_t>(d - (q + 2));
                    for (size_t k = 0; k < r.depth; k++)
                        r.delim[k] = u[q + 2 + k];
                    paused = in_raw_cpp(i, d + 1);
                    continue;
                }
            }
        }
        if (raw_ == Raw::rust && (c == u'r' || c == u'b' || c == u'c')) {
            size_t q = i;
            if (c != u'r' && q + 1 < n && u[q + 1] == u'r')
                q++;
            if (u[q] == u'r') {
                size_t h = q + 1;
                while (h < n && u[h] == u'#' && h - (q + 1) < k_level_most)
                    h++;
                if (h < n && u[h] == u'"') {
                    r.depth = static_cast<uint32_t>(h - (q + 1));
                    paused = in_raw_rust(i, h + 1);
                    continue;
                }
            }
        }
        if (long_brackets_ && c == u'[') {
            const int level = long_level(i);
            if (level >= 0) {
                r.depth = static_cast<uint32_t>(level);
                paused = in_long(Token::string, Mode::long_string, i, i + static_cast<size_t>(level) + 2);
                continue;
            }
        }

        if (c < 128 ? starts_[c] : starts_high_) {
            bool taken = false;
            for (size_t k = 0; k < strings_.size(); k++) {
                const Str& q = strings_[k];
                if (c != q.open[0] || !at(s, i, q.open))
                    continue;
                taken = true;
                if (!q.char_literal) {
                    r.rule = static_cast<uint16_t>(k);
                    paused = in_string(i, i + q.open.size());
                    break;
                }
                size_t e = i + q.open.size();
                bool closed = false;
                if (e < n && !(q.escape && u[e] == q.escape)) {
                    const size_t one = e + ((u[e] & 0xFC00) == 0xD800 && e + 1 < n ? 2 : 1);
                    if (at(s, one, q.close))
                        e = one + q.close.size(), closed = true;
                }
                const size_t most = !closed && e < n && q.escape && u[e] == q.escape ? e + 12 : e;
                while (!closed && e < n && e < most) {
                    if (u[e] == q.escape && e + 1 < n) {
                        e += 2;
                        continue;
                    }
                    if (at(s, e, q.close)) {
                        e += q.close.size();
                        closed = true;
                        break;
                    }
                    if (u[e] == u'\n' && !q.multiline)
                        break;
                    e++;
                }
                if (closed) {
                    put(Token::string, i, e);
                    r.prev = Prev::value;
                    i = e;
                    break;
                }
                size_t w = i + q.open.size();
                const size_t cap = w + k_word_most;
                while (w < n && w < cap && is_word(u[w]))
                    w++;
                if (w > i + q.open.size()) {
                    put(Token::meta, i, w);
                    i = w;
                } else {
                    i += q.open.size();
                }
                break;
            }
            if (taken)
                continue;
        }

        if (is_ascii_digit(c)
            || (c == u'.' && i + 1 < n && is_ascii_digit(u[i + 1]) && r.prev != Prev::dot && r.prev != Prev::dots)) {
            size_t e = i + 1;
            const size_t most = i + k_word_most;
            const bool hex = c == u'0' && e < n && (u[e] == u'x' || u[e] == u'X');
            while (e < n && e <= most) {
                const char16_t d = u[e];
                if (is_ascii_digit(d) || is_alpha(d) || d == u'_' || (digit_sep_ && d == digit_sep_)) {
                    e++;
                } else if (d == u'.' && e + 1 < n && is_ascii_digit(u[e + 1])) {
                    e++;
                } else if ((d == u'+' || d == u'-') && !hex && (u[e - 1] == u'e' || u[e - 1] == u'E')) {
                    e++;
                } else if ((d == u'+' || d == u'-') && (u[e - 1] == u'p' || u[e - 1] == u'P')) {
                    e++;
                } else {
                    break;
                }
            }
            r.prev = Prev::value;
            if (e > most) {
                paused = in_plain_word(e);
                continue;
            }
            put(Token::number, i, e);
            i = e;
            continue;
        }

        {
            bool taken = false;
            for (const SigilSpec& g : sigils_) {
                if (c != g.sigil || i + 1 >= n || !starts_word(u[i + 1]))
                    continue;
                size_t e = i + 2;
                const size_t cap = i + 2 + k_word_most;
                while (e < n && e < cap && is_word(u[e]))
                    e++;
                r.prev = Prev::value;
                put(g.kind, i, e);
                i = e;
                taken = true;
                break;
            }
            if (taken)
                continue;
        }

        if (starts_word(c)) {
            size_t e = i + 1;
            const size_t most = i + k_word_most;
            while (e < n && e <= most && is_word(u[e]))
                e++;
            if (e > most) {
                r.names_a_call = false;
                r.prev = Prev::value;
                paused = in_plain_word(e);
                continue;
            }
            const std::u16string_view w = s.substr(i, e - i);
            const bool member = members_ && r.prev == Prev::dot;
            Token kind = Token::keyword;
            bool have = false, a_value = true;
            if (!member) {
                if (const Word* found = word_of(w)) {
                    kind = found->kind, have = true;
                    a_value = found->kind != Token::keyword || found->value;
                }
            }
            r.prev = a_value ? Prev::value : Prev::none;
            if (!have && r.names_a_call)
                kind = Token::call, have = true;
            r.names_a_call = false;
            for (const std::u16string& d : call_after_)
                r.names_a_call = r.names_a_call || w == d;
            if (!have && bit_ints_ && w.size() >= 2 && (w[0] == u'i' || w[0] == u'u')) {
                bool digits = true;
                for (size_t k = 1; k < w.size() && digits; k++)
                    digits = is_ascii_digit(w[k]);
                if (digits)
                    kind = Token::type, have = true;
            }
            if (!have && bang_macros_ && e < n && u[e] == u'!' && !(e + 1 < n && u[e + 1] == u'=')) {
                put(Token::call, i, e + 1);
                i = e + 1;
                continue;
            }
            if (!have) {
                size_t f = e;
                for (size_t k = 0; k < k_blanks_most && f < n && blank(u[f]); k++)
                    f++;
                if (first_on_line)
                    for (const std::u16string& k : key_before_)
                        if (at(s, f, k))
                            kind = Token::key, have = true;
                if (!have)
                    for (const std::u16string& k : calls_)
                        if (at(s, f, k))
                            kind = Token::call, have = true;
            }
            if (!have && member)
                kind = Token::key, have = true;
            if (!have && type_case_ && w[0] >= u'A' && w[0] <= u'Z') {
                bool lower = false;
                for (char16_t l : w)
                    lower = lower || (l >= u'a' && l <= u'z');
                if (lower)
                    kind = Token::type, have = true;
            }
            if (have)
                put(kind, i, e);
            i = e;
            continue;
        }

        if (regex_ && c == u'/' && (r.prev == Prev::none || r.prev == Prev::dots)) {
            const size_t cap = i + k_regex_most < n ? i + k_regex_most : n;
            size_t e = i + 1;
            bool in_class = false, closed = false;
            while (e < cap && u[e] != u'\n') {
                const char16_t d = u[e];
                if (d == u'\\') {
                    if (e + 1 < n && u[e + 1] == u'\n')
                        break;
                    e += 2;
                    continue;
                }
                e++;
                if (in_class)
                    in_class = d != u']';
                else if (d == u'[')
                    in_class = true;
                else if (d == u'/') {
                    closed = true;
                    break;
                }
            }
            if (closed) {
                for (size_t k = 0; k < k_flags_most && e < n && is_word(u[e]); k++)
                    e++;
                put(Token::string, i, e);
                r.prev = Prev::value;
                i = e;
                continue;
            }
        }

        if (r.holes) {
            Hole& h = r.hole[r.holes - 1];
            const Str& q = strings_[h.rule];
            if (at(s, i, q.hole_close)) {
                if (h.depth == 0) {
                    const size_t back = i + q.hole_close.size();
                    put(Token::meta, i, back);
                    r.rule = h.rule;
                    h = {};
                    r.holes--;
                    paused = in_string(back, back);
                    continue;
                }
                h.depth--;
            } else if (c == q.hole_open.back() && h.depth != 0xFFFF) {
                h.depth++;
            }
        }
        if (c == u'.')
            r.prev = r.prev == Prev::dot || r.prev == Prev::dots ? Prev::dots : Prev::dot;
        else
            r.prev = c == u')' || c == u']' ? Prev::value : Prev::none;
        i++;
    }
    r.at = i;
    resume = r;
}

}
