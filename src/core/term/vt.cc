// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/term/vt.h"

#include <algorithm>

namespace rx::term {

namespace {
struct Range {
    char32_t lo, hi;
};
constexpr Range kZero[] = {
    {0x0300, 0x036F}, {0x0483, 0x0489},   {0x0591, 0x05BD},   {0x05BF, 0x05BF},   {0x05C1, 0x05C2}, {0x05C4, 0x05C5},
    {0x05C7, 0x05C7}, {0x0610, 0x061A},   {0x064B, 0x065F},   {0x0670, 0x0670},   {0x06D6, 0x06DC}, {0x06DF, 0x06E4},
    {0x06E7, 0x06E8}, {0x06EA, 0x06ED},   {0x0711, 0x0711},   {0x0730, 0x074A},   {0x0900, 0x0902}, {0x093A, 0x093A},
    {0x093C, 0x093C}, {0x0941, 0x0948},   {0x094D, 0x094D},   {0x0951, 0x0957},   {0x0962, 0x0963}, {0x0E31, 0x0E31},
    {0x0E34, 0x0E3A}, {0x0E47, 0x0E4E},   {0x1AB0, 0x1AFF},   {0x1DC0, 0x1DFF},   {0x200B, 0x200F}, {0x202A, 0x202E},
    {0x2060, 0x2064}, {0x20D0, 0x20FF},   {0x302A, 0x302D},   {0x3099, 0x309A},   {0xFE00, 0xFE0F}, {0xFE20, 0xFE2F},
    {0xFEFF, 0xFEFF}, {0x1F3FB, 0x1F3FF}, {0xE0001, 0xE007F}, {0xE0100, 0xE01EF},
};
constexpr Range kWide[] = {
    {0x1100, 0x115F},   {0x231A, 0x231B},   {0x2329, 0x232A},   {0x23E9, 0x23EC},   {0x23F0, 0x23F0},
    {0x23F3, 0x23F3},   {0x25FD, 0x25FE},   {0x2614, 0x2615},   {0x2648, 0x2653},   {0x267F, 0x267F},
    {0x2693, 0x2693},   {0x26A1, 0x26A1},   {0x26AA, 0x26AB},   {0x26BD, 0x26BE},   {0x26C4, 0x26C5},
    {0x26CE, 0x26CE},   {0x26D4, 0x26D4},   {0x26EA, 0x26EA},   {0x26F2, 0x26F3},   {0x26F5, 0x26F5},
    {0x26FA, 0x26FA},   {0x26FD, 0x26FD},   {0x2705, 0x2705},   {0x270A, 0x270B},   {0x2728, 0x2728},
    {0x274C, 0x274C},   {0x274E, 0x274E},   {0x2753, 0x2755},   {0x2757, 0x2757},   {0x2795, 0x2797},
    {0x27B0, 0x27B0},   {0x27BF, 0x27BF},   {0x2B1B, 0x2B1C},   {0x2B50, 0x2B50},   {0x2B55, 0x2B55},
    {0x2E80, 0x303E},   {0x3041, 0x33FF},   {0x3400, 0x4DBF},   {0x4E00, 0x9FFF},   {0xA000, 0xA4CF},
    {0xA960, 0xA97F},   {0xAC00, 0xD7A3},   {0xF900, 0xFAFF},   {0xFE10, 0xFE19},   {0xFE30, 0xFE6F},
    {0xFF00, 0xFF60},   {0xFFE0, 0xFFE6},   {0x16FE0, 0x16FE4}, {0x17000, 0x18CFF}, {0x1B000, 0x1B2FF},
    {0x1F004, 0x1F004}, {0x1F0CF, 0x1F0CF}, {0x1F18E, 0x1F18E}, {0x1F191, 0x1F19A}, {0x1F200, 0x1F251},
    {0x1F300, 0x1F320}, {0x1F32D, 0x1F335}, {0x1F337, 0x1F37C}, {0x1F37E, 0x1F393}, {0x1F3A0, 0x1F3CA},
    {0x1F3CF, 0x1F3D3}, {0x1F3E0, 0x1F3F0}, {0x1F3F4, 0x1F3F4}, {0x1F3F8, 0x1F43E}, {0x1F440, 0x1F440},
    {0x1F442, 0x1F4FC}, {0x1F4FF, 0x1F53D}, {0x1F54B, 0x1F54E}, {0x1F550, 0x1F567}, {0x1F57A, 0x1F57A},
    {0x1F595, 0x1F596}, {0x1F5A4, 0x1F5A4}, {0x1F5FB, 0x1F64F}, {0x1F680, 0x1F6C5}, {0x1F6CC, 0x1F6CC},
    {0x1F6D0, 0x1F6D2}, {0x1F6D5, 0x1F6D7}, {0x1F6DC, 0x1F6DF}, {0x1F6EB, 0x1F6EC}, {0x1F6F4, 0x1F6FC},
    {0x1F7E0, 0x1F7EB}, {0x1F7F0, 0x1F7F0}, {0x1F90C, 0x1F93A}, {0x1F93C, 0x1F945}, {0x1F947, 0x1F9FF},
    {0x1FA70, 0x1FAFF}, {0x20000, 0x2FFFD}, {0x30000, 0x3FFFD},
};
template<size_t N>
bool in(const Range (&r)[N], char32_t c) {
    size_t lo = 0, hi = N;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (c < r[mid].lo)
            hi = mid;
        else if (c > r[mid].hi)
            lo = mid + 1;
        else
            return true;
    }
    return false;
}

constexpr char32_t kLineDrawing[31] = {
    U'◆', U'▒', U'␉', U'␌', U'␍', U'␊', U'°', U'±', U'␤', U'␋', U'┘', U'┐', U'┌', U'└', U'┼', U'⎺',
    U'⎻', U'─', U'⎼', U'⎽', U'├', U'┤', U'┴', U'┬', U'│', U'≤', U'≥', U'π', U'≠', U'£', U'·',
};
}

int char_width(char32_t c) {
    if (c < 0x300)
        return 1;
    if (in(kZero, c))
        return 0;
    return in(kWide, c) ? 2 : 1;
}

std::expected<Terminal, Error> Terminal::make(int cols, int rows, int scrollback) {
    if (cols < 1 || rows < 1 || cols > 4096 || rows > 4096 || scrollback < 0)
        return std::unexpected(Error::bad_size);
    Terminal t;
    t.sb_cap_ = scrollback;
    t.osc_.reserve(kMaxOsc);
    t.title_.reserve(kMaxOsc);
    t.apc_.reserve(kMaxApc);
    t.reset_palette();
    if (auto r = t.resize(cols, rows); !r)
        return std::unexpected(r.error());
    return t;
}

std::expected<void, Error> Terminal::resize(int cols, int rows) {
    if (cols < 1 || rows < 1 || cols > 4096 || rows > 4096)
        return std::unexpected(Error::bad_size);
    auto remake = [&](std::vector<Cell>& cells, std::vector<uint8_t>& wrap) {
        std::vector<Cell> next(size_t(cols) * size_t(rows), Cell{});
        std::vector<uint8_t> nwrap(size_t(rows), 0);
        for (int y = 0; y < std::min(rows, rows_); y++) {
            for (int x = 0; x < std::min(cols, cols_); x++)
                next[size_t(y) * size_t(cols) + size_t(x)] = cells[size_t(y) * size_t(cols_) + size_t(x)];
            nwrap[size_t(y)] = wrap[size_t(y)];
        }
        cells.swap(next);
        wrap.swap(nwrap);
    };
    if (cols_ == 0) {
        main_.assign(size_t(cols) * size_t(rows), Cell{});
        alt_cells_.assign(size_t(cols) * size_t(rows), Cell{});
        main_wrap_.assign(size_t(rows), 0);
        alt_wrap_.assign(size_t(rows), 0);
    } else {
        remake(main_, main_wrap_);
        remake(alt_cells_, alt_wrap_);
    }
    if (cols != cols_) {
        const size_t chunks = size_t((sb_cap_ + kSbChunk - 1) / kSbChunk);
        std::vector<std::unique_ptr<Cell[]>> next(chunks);
        std::vector<uint8_t> nwrap(size_t(sb_cap_), 0);
        int kept = 0;
        for (int i = 0; i < sb_count_; i++) {
            const int c = i / kSbChunk;
            if (!next[size_t(c)])
                next[size_t(c)].reset(new (std::nothrow) Cell[size_t(kSbChunk) * size_t(cols)]());
            if (!next[size_t(c)])
                break;
            const Cell* from = scrollback_row(i);
            Cell* to = next[size_t(c)].get() + size_t(i % kSbChunk) * size_t(cols);
            for (int x = 0; x < std::min(cols, cols_); x++)
                to[x] = from[x];
            nwrap[size_t(i)] = scrollback_wrapped(i);
            kept++;
        }
        sb_chunks_.swap(next);
        sb_wrap_.swap(nwrap);
        sb_count_ = kept;
        sb_head_ = kept % std::max(1, sb_cap_);
    }
    tabs_.assign(size_t(cols), 0);
    for (int x = 0; x < cols; x += 8)
        tabs_[size_t(x)] = 1;
    cols_ = cols, rows_ = rows;
    top_ = 0, bottom_ = rows - 1;
    x_ = std::min(x_, cols - 1), y_ = std::min(y_, rows - 1);
    pending_wrap_ = false;
    return {};
}

std::expected<Terminal, Error> Terminal::reflowed(int cols, int rows) const {
    auto made = make(cols, rows, 0);
    if (!made)
        return made;
    Terminal& t = *made;
    std::copy(palette_, palette_ + 256, t.palette_);
    t.fg_rgb_ = fg_rgb_, t.bg_rgb_ = bg_rgb_, t.cursor_rgb_ = cursor_rgb_;
    t.cursor_on_ = cursor_on_, t.cursor_shape_ = cursor_shape_, t.mouse_ = mouse_, t.pen_ = pen_;
    t.scrolled_ = scrolled_, t.cleared_ = cleared_;
    if (alt_) {
        t.alt_ = true;
        for (int y = 0; y < std::min(rows, rows_); y++)
            for (int x = 0; x < std::min(cols, cols_); x++)
                t.alt_cells_[size_t(y) * size_t(cols) + size_t(x)] = alt_cells_[size_t(y) * size_t(cols_) + size_t(x)];
        t.x_ = std::min(x_, cols - 1), t.y_ = std::min(y_, rows - 1);
        return made;
    }
    const int total = sb_count_ + rows_;
    auto row_at = [&](int i) {
        return i < sb_count_ ? scrollback_row(i) : main_.data() + size_t(i - sb_count_) * size_t(cols_);
    };
    auto wrapped_at = [&](int i) {
        return i < sb_count_ ? scrollback_wrapped(i) : main_wrap_[size_t(i - sb_count_)] != 0;
    };
    auto empty = [](const Cell& c) {
        return c.cp == U' ' && !c.comb[0] && !c.attrs && c.bg == kDefault && !c.link && c.width == 1;
    };
    auto used = [&](int i) {
        const Cell* r = row_at(i);
        int n = cols_;
        while (n > 0 && empty(r[n - 1]))
            n--;
        return n;
    };
    const int cur = sb_count_ + y_;
    int last = cur;
    for (int i = total - 1; i > cur; i--)
        if (used(i)) {
            last = i;
            break;
        }
    while (last < total - 1 && wrapped_at(last))
        last++;
    struct Line {
        int first, last;
    };
    std::vector<Line> lines;
    for (int e = last, need = 0; e >= 0 && need < rows;) {
        int s = e;
        while (s > 0 && wrapped_at(s - 1))
            s--;
        int len = (e - s) * cols_ + used(e);
        if (cur >= s && cur <= e)
            len = std::max(len, (cur - s) * cols_ + x_ + 1);
        need += std::max(1, (len + cols - 1) / cols);
        lines.push_back({s, e});
        e = s - 1;
    }
    std::reverse(lines.begin(), lines.end());
    std::vector<Cell> out;
    std::vector<uint8_t> out_wrap;
    int col = 0, cursor_row = -1, cursor_col = 0;
    auto new_row = [&](bool wrapped) {
        if (!out_wrap.empty())
            out_wrap.back() = wrapped ? 1 : 0;
        out.resize(out.size() + size_t(cols), Cell{});
        out_wrap.push_back(0);
        col = 0;
    };
    for (const Line& l : lines) {
        new_row(false);
        const bool has_cursor = cur >= l.first && cur <= l.last;
        const int offset = has_cursor ? (cur - l.first) * cols_ + x_ : -1;
        const int len = (l.last - l.first) * cols_ + used(l.last);
        for (int k = 0; k < len; k++) {
            const Cell& c = row_at(l.first + k / cols_)[k % cols_];
            if (k == offset)
                cursor_row = int(out_wrap.size()) - 1, cursor_col = col;
            if (c.width == 0)
                continue;
            const int w = c.width == 2 ? 2 : 1;
            if (col + w > cols)
                new_row(true);
            Cell* to = out.data() + (out_wrap.size() - 1) * size_t(cols);
            to[col] = c;
            if (w == 2 && col + 1 < cols)
                to[col + 1] = Cell{U' ', {0, 0}, c.attrs, c.underline, 0, c.link, c.fg, c.bg};
            col += w;
        }
        if (has_cursor && cursor_row < 0) {
            int extra = offset - len;
            cursor_col = col + extra;
            cursor_row = int(out_wrap.size()) - 1;
            while (cursor_col >= cols) {
                new_row(true);
                cursor_col -= cols;
                cursor_row++;
            }
        }
    }
    const int laid = int(out_wrap.size()), shown = std::min(rows, laid), skip = laid - shown;
    std::copy(out.begin() + std::ptrdiff_t(size_t(skip) * size_t(cols)), out.end(), t.main_.begin());
    std::copy(out_wrap.begin() + skip, out_wrap.end(), t.main_wrap_.begin());
    if (cursor_row >= skip) {
        t.y_ = cursor_row - skip, t.x_ = std::min(cursor_col, cols - 1);
    } else {
        t.y_ = 0, t.x_ = 0, t.cursor_on_ = false;
    }
    return made;
}

const Cell* Terminal::scrollback_row(int i) const {
    int start = (sb_head_ - sb_count_ + sb_cap_) % std::max(1, sb_cap_);
    return sb_slot((start + i) % std::max(1, sb_cap_));
}

size_t Terminal::scrollback_bytes() const {
    size_t n = 0;
    for (const auto& c : sb_chunks_)
        n += c ? size_t(kSbChunk) * size_t(cols_) * sizeof(Cell) : 0;
    return n;
}

bool Terminal::sb_make(int slot) {
    std::unique_ptr<Cell[]>& c = sb_chunks_[size_t(slot / kSbChunk)];
    if (!c)
        c.reset(new (std::nothrow) Cell[size_t(kSbChunk) * size_t(cols_)]());
    return c != nullptr;
}
bool Terminal::scrollback_wrapped(int i) const {
    int start = (sb_head_ - sb_count_ + sb_cap_) % std::max(1, sb_cap_);
    return sb_wrap_[size_t((start + i) % std::max(1, sb_cap_))] != 0;
}

Cell Terminal::blank() const {
    Cell c;
    c.bg = pen_.bg;
    return c;
}
void Terminal::clear_cells(Cell* from, size_t n) {
    Cell b = blank();
    std::fill(from, from + n, b);
}

void Terminal::scroll_up(int top, int bottom, int n, bool keep) {
    n = std::min(n, bottom - top + 1);
    if (n <= 0)
        return;
    if (top == 0)
        scrolled_ += uint64_t(n);
    std::vector<uint8_t>& wrap = alt_ ? alt_wrap_ : main_wrap_;
    if (keep && !alt_ && top == 0 && sb_cap_ > 0) {
        for (int i = 0; i < n; i++) {
            if (!sb_make(sb_head_))
                break;
            std::copy(row(i), row(i) + cols_, sb_slot(sb_head_));
            sb_wrap_[size_t(sb_head_)] = wrap[size_t(i)];
            sb_head_ = (sb_head_ + 1) % sb_cap_;
            sb_count_ = std::min(sb_count_ + 1, sb_cap_);
        }
    }
    Cell* s = screen();
    size_t w = size_t(cols_);
    std::move(s + size_t(top + n) * w, s + size_t(bottom + 1) * w, s + size_t(top) * w);
    std::move(wrap.begin() + top + n, wrap.begin() + bottom + 1, wrap.begin() + top);
    clear_cells(s + size_t(bottom - n + 1) * w, size_t(n) * w);
    std::fill(wrap.begin() + bottom - n + 1, wrap.begin() + bottom + 1, 0);
}
void Terminal::scroll_down(int top, int bottom, int n) {
    n = std::min(n, bottom - top + 1);
    if (n <= 0)
        return;
    std::vector<uint8_t>& wrap = alt_ ? alt_wrap_ : main_wrap_;
    Cell* s = screen();
    size_t w = size_t(cols_);
    std::move_backward(s + size_t(top) * w, s + size_t(bottom - n + 1) * w, s + size_t(bottom + 1) * w);
    std::move_backward(wrap.begin() + top, wrap.begin() + bottom - n + 1, wrap.begin() + bottom + 1);
    clear_cells(s + size_t(top) * w, size_t(n) * w);
    std::fill(wrap.begin() + top, wrap.begin() + top + n, 0);
}
void Terminal::line_feed() {
    if (y_ == bottom_)
        scroll_up(top_, bottom_, 1, true);
    else if (y_ < rows_ - 1)
        y_++;
}
void Terminal::reverse_index() {
    if (y_ == top_)
        scroll_down(top_, bottom_, 1);
    else if (y_ > 0)
        y_--;
}
void Terminal::move_to(int x, int y) {
    int lo = origin_ ? top_ : 0, hi = origin_ ? bottom_ : rows_ - 1;
    x_ = std::clamp(x, 0, cols_ - 1);
    y_ = std::clamp(y + (origin_ ? top_ : 0), lo, hi);
    pending_wrap_ = false;
}

void Terminal::print(char32_t c) {
    if (gl_ >= 0 && g_[gl_] == '0' && c >= 0x60 && c <= 0x7E)
        c = kLineDrawing[c - 0x60];
    int w = char_width(c);
    if (w == 0) {
        int px = pending_wrap_ ? x_ : x_ - 1;
        if (px < 0)
            return;
        Cell* p = at(px, y_);
        if (p->width == 0 && px > 0)
            p--;
        if (!p->comb[0])
            p->comb[0] = c;
        else if (!p->comb[1])
            p->comb[1] = c;
        return;
    }
    if (pending_wrap_ && autowrap_) {
        (alt_ ? alt_wrap_ : main_wrap_)[size_t(y_)] = 1;
        x_ = 0;
        line_feed();
    }
    pending_wrap_ = false;
    if (w == 2 && x_ == cols_ - 1) {
        if (autowrap_) {
            clear_cells(at(x_, y_), 1);
            (alt_ ? alt_wrap_ : main_wrap_)[size_t(y_)] = 1;
            x_ = 0;
            line_feed();
        } else {
            return;
        }
    }
    if (insert_) {
        Cell* r = at(0, y_);
        std::move_backward(r + x_, r + cols_ - w, r + cols_);
    }
    Cell* cell = at(x_, y_);
    if (cell->width == 0 && x_ > 0)
        clear_cells(at(x_ - 1, y_), 1);
    if (cell->width == 2 && x_ + 1 < cols_)
        clear_cells(at(x_ + 1, y_), 1);
    *cell = Cell{c, {0, 0}, pen_.attrs, pen_.underline, uint16_t(w), link_, pen_.fg, pen_.bg};
    if (w == 2 && x_ + 1 < cols_) {
        Cell* spacer = at(x_ + 1, y_);
        if (spacer->width == 2 && x_ + 2 < cols_)
            clear_cells(at(x_ + 2, y_), 1);
        *spacer = Cell{U' ', {0, 0}, pen_.attrs, pen_.underline, 0, link_, pen_.fg, pen_.bg};
    }
    last_ = c;
    if (x_ + w >= cols_) {
        x_ = cols_ - 1;
        pending_wrap_ = true;
    } else {
        x_ += w;
    }
}

void Terminal::execute(uint8_t b) {
    switch (b) {
    case 0x08:
        if (x_ > 0)
            x_--;
        pending_wrap_ = false;
        break;
    case 0x09: {
        int x = x_ + 1;
        while (x < cols_ - 1 && !tabs_[size_t(x)])
            x++;
        x_ = std::min(x, cols_ - 1);
        pending_wrap_ = false;
        break;
    }
    case 0x0A:
    case 0x0B:
    case 0x0C:
        line_feed();
        pending_wrap_ = false;
        break;
    case 0x0D:
        x_ = 0;
        pending_wrap_ = false;
        break;
    case 0x0E:
        gl_ = 1;
        break;
    case 0x0F:
        gl_ = 0;
        break;
    default:
        break;
    }
}

void Terminal::erase_line(int how) {
    Cell* r = at(0, y_);
    if (how == 0)
        clear_cells(r + x_, size_t(cols_ - x_));
    else if (how == 1)
        clear_cells(r, size_t(x_ + 1));
    else
        clear_cells(r, size_t(cols_));
    pending_wrap_ = false;
}
void Terminal::erase_display(int how) {
    std::vector<uint8_t>& wrap = alt_ ? alt_wrap_ : main_wrap_;
    if (how == 0) {
        erase_line(0);
        if (y_ + 1 < rows_)
            clear_cells(at(0, y_ + 1), size_t(rows_ - y_ - 1) * size_t(cols_));
        std::fill(wrap.begin() + y_, wrap.end(), 0);
    } else if (how == 1) {
        if (y_ > 0)
            clear_cells(at(0, 0), size_t(y_) * size_t(cols_));
        erase_line(1);
        std::fill(wrap.begin(), wrap.begin() + y_ + 1, 0);
    } else if (how == 2) {
        cleared_++;
        clear_cells(screen(), size_t(rows_) * size_t(cols_));
        std::fill(wrap.begin(), wrap.end(), 0);
    } else if (how == 3 && !alt_) {
        sb_count_ = 0;
        sb_head_ = 0;
        for (auto& c : sb_chunks_)
            c.reset();
    }
}

void Terminal::save_cursor() {
    Saved& s = alt_ ? saved_alt_ : saved_main_;
    s = Saved{x_, y_, pen_, origin_, {g_[0], g_[1]}, gl_};
}
void Terminal::restore_cursor() {
    const Saved& s = alt_ ? saved_alt_ : saved_main_;
    x_ = std::min(s.x, cols_ - 1), y_ = std::min(s.y, rows_ - 1);
    pen_ = s.pen;
    origin_ = s.origin;
    g_[0] = s.g[0], g_[1] = s.g[1];
    gl_ = s.gl;
    pending_wrap_ = false;
}
void Terminal::switch_screen(bool alt, bool save, bool clear) {
    if (alt == alt_)
        return;
    if (alt && save)
        save_cursor();
    alt_ = alt;
    if (alt && clear) {
        clear_cells(screen(), size_t(rows_) * size_t(cols_));
        std::fill(alt_wrap_.begin(), alt_wrap_.end(), 0);
    }
    if (!alt && save)
        restore_cursor();
}
void Terminal::cursor_past_image(int cols, int rows) {
    for (int i = 1; i < rows; i++)
        line_feed();
    x_ = std::min(x_ + cols, cols_ - 1);
    pending_wrap_ = false;
}
void Terminal::reset() {
    cleared_++;
    alt_ = false;
    pen_ = Pen{};
    link_ = 0;
    clear_cells(main_.data(), main_.size());
    clear_cells(alt_cells_.data(), alt_cells_.size());
    std::fill(main_wrap_.begin(), main_wrap_.end(), 0);
    std::fill(alt_wrap_.begin(), alt_wrap_.end(), 0);
    sb_count_ = sb_head_ = 0;
    for (auto& c : sb_chunks_)
        c.reset();
    x_ = y_ = 0;
    top_ = 0, bottom_ = rows_ - 1;
    origin_ = insert_ = false;
    autowrap_ = cursor_on_ = true;
    cursor_shape_ = CursorShape::unset;
    mouse_ = MouseTracking::none;
    pending_wrap_ = false;
    g_[0] = g_[1] = 'B', gl_ = 0;
    std::fill(tabs_.begin(), tabs_.end(), 0);
    for (int x = 0; x < cols_; x += 8)
        tabs_[size_t(x)] = 1;
    title_.clear();
}

int Terminal::param(int i, int fallback) const {
    return i < nparams_ && params_[i] > 0 ? params_[i] : fallback;
}

void Terminal::esc_dispatch(uint8_t b) {
    if (inter_ == '(' || inter_ == ')') {
        g_[inter_ == '(' ? 0 : 1] = b;
        return;
    }
    if (inter_ == '#') {
        if (b == '8') {
            Cell e;
            e.cp = U'E';
            std::fill(screen(), screen() + size_t(rows_) * size_t(cols_), e);
        }
        return;
    }
    if (inter_)
        return;
    switch (b) {
    case '7':
        save_cursor();
        break;
    case '8':
        restore_cursor();
        break;
    case 'D':
        line_feed();
        break;
    case 'E':
        x_ = 0, line_feed();
        break;
    case 'M':
        reverse_index();
        break;
    case 'H':
        tabs_[size_t(x_)] = 1;
        break;
    case 'c':
        reset();
        break;
    default:
        break;
    }
    pending_wrap_ = false;
}

static Color basic(int i) {
    return palette(uint8_t(i));
}

void Terminal::sgr() {
    if (nparams_ == 0) {
        pen_ = Pen{};
        return;
    }
    for (int i = 0; i < nparams_; i++) {
        int p = params_[i];
        auto colour = [&](Color& into) {
            if (i + 1 >= nparams_)
                return;
            int kind = params_[i + 1];
            if (kind == 5 && i + 2 < nparams_) {
                into = palette(uint8_t(params_[i + 2]));
                i += 2;
            } else if (kind == 2) {
                int j = i + 2;
                if (sub_[i + 1]) {
                    int left = 0;
                    for (int k = i + 2; k < nparams_ && sub_[k]; k++)
                        left++;
                    if (left >= 4)
                        j++;
                }
                if (j + 2 < nparams_)
                    into = rgb(uint8_t(params_[j]), uint8_t(params_[j + 1]), uint8_t(params_[j + 2]));
                i = std::min(nparams_ - 1, j + 2);
            }
        };
        switch (p) {
        case 0:
            pen_ = Pen{};
            break;
        case 1:
            pen_.attrs |= kBold;
            break;
        case 2:
            pen_.attrs |= kDim;
            break;
        case 3:
            pen_.attrs |= kItalic;
            break;
        case 4: {
            int style = i + 1 < nparams_ && sub_[i + 1] ? params_[++i] : 1;
            if (style == 0)
                pen_.attrs &= uint16_t(~kUnderline), pen_.underline = 0;
            else
                pen_.attrs |= kUnderline, pen_.underline = uint8_t(std::min(style, 5));
            break;
        }
        case 5:
        case 6:
            pen_.attrs |= kBlink;
            break;
        case 7:
            pen_.attrs |= kInverse;
            break;
        case 8:
            pen_.attrs |= kHidden;
            break;
        case 9:
            pen_.attrs |= kStrike;
            break;
        case 21:
            pen_.attrs |= kUnderline, pen_.underline = 2;
            break;
        case 22:
            pen_.attrs &= uint16_t(~(kBold | kDim));
            break;
        case 23:
            pen_.attrs &= uint16_t(~kItalic);
            break;
        case 24:
            pen_.attrs &= uint16_t(~kUnderline), pen_.underline = 0;
            break;
        case 25:
            pen_.attrs &= uint16_t(~kBlink);
            break;
        case 27:
            pen_.attrs &= uint16_t(~kInverse);
            break;
        case 28:
            pen_.attrs &= uint16_t(~kHidden);
            break;
        case 29:
            pen_.attrs &= uint16_t(~kStrike);
            break;
        case 38:
            colour(pen_.fg);
            break;
        case 39:
            pen_.fg = kDefault;
            break;
        case 48:
            colour(pen_.bg);
            break;
        case 49:
            pen_.bg = kDefault;
            break;
        case 53:
            pen_.attrs |= kOverline;
            break;
        case 55:
            pen_.attrs &= uint16_t(~kOverline);
            break;
        case 58: {
            Color ignored;
            colour(ignored);
            break;
        }
        default:
            if (p >= 30 && p <= 37)
                pen_.fg = basic(p - 30);
            else if (p >= 40 && p <= 47)
                pen_.bg = basic(p - 40);
            else if (p >= 90 && p <= 97)
                pen_.fg = basic(p - 90 + 8);
            else if (p >= 100 && p <= 107)
                pen_.bg = basic(p - 100 + 8);
            break;
        }
    }
}

void Terminal::set_mode(bool on) {
    for (int i = 0; i < std::max(1, nparams_); i++) {
        int m = i < nparams_ ? params_[i] : 0;
        if (private_ == '?') {
            switch (m) {
            case 6:
                origin_ = on, move_to(0, 0);
                break;
            case 7:
                autowrap_ = on;
                break;
            case 25:
                cursor_on_ = on;
                break;
            case 47:
            case 1047:
                switch_screen(on, false, on && m == 1047);
                break;
            case 1048:
                on ? save_cursor() : restore_cursor();
                break;
            case 1049:
                switch_screen(on, true, true);
                break;
            case 1000:
                mouse_ = on ? MouseTracking::press : MouseTracking::none;
                break;
            case 1002:
                mouse_ = on ? MouseTracking::drag : MouseTracking::none;
                break;
            case 1003:
                mouse_ = on ? MouseTracking::any : MouseTracking::none;
                break;
            default:
                break;
            }
        } else if (!private_) {
            if (m == 4)
                insert_ = on;
        }
    }
}

void Terminal::csi_dispatch(uint8_t b) {
    if (private_ && b != 'h' && b != 'l' && b != 'J' && b != 'K') {
        return;
    }
    if (inter_) {
        if (inter_ == '!' && b == 'p') {
            pen_ = Pen{};
            origin_ = insert_ = false;
            autowrap_ = cursor_on_ = true;
            top_ = 0, bottom_ = rows_ - 1;
            saved_main_ = saved_alt_ = Saved{};
        } else if (inter_ == ' ' && b == 'q') {
            int s = param(0, 0);
            cursor_shape_ = s == 0 ? CursorShape::unset
                : s <= 2           ? CursorShape::block
                : s <= 4           ? CursorShape::underline
                : s <= 6           ? CursorShape::bar
                                   : cursor_shape_;
        }
        return;
    }
    int n = param(0, 1);
    switch (b) {
    case '@': {
        Cell* r = at(0, y_);
        int k = std::min(n, cols_ - x_);
        std::move_backward(r + x_, r + cols_ - k, r + cols_);
        clear_cells(r + x_, size_t(k));
        break;
    }
    case 'A':
        y_ = std::max(y_ >= top_ ? top_ : 0, y_ - n);
        pending_wrap_ = false;
        break;
    case 'B':
    case 'e':
        y_ = std::min(y_ <= bottom_ ? bottom_ : rows_ - 1, y_ + n);
        pending_wrap_ = false;
        break;
    case 'C':
    case 'a':
        x_ = std::min(cols_ - 1, x_ + n);
        pending_wrap_ = false;
        break;
    case 'D':
        x_ = std::max(0, x_ - n);
        pending_wrap_ = false;
        break;
    case 'E':
        x_ = 0, y_ = std::min(rows_ - 1, y_ + n);
        pending_wrap_ = false;
        break;
    case 'F':
        x_ = 0, y_ = std::max(0, y_ - n);
        pending_wrap_ = false;
        break;
    case 'G':
    case '`':
        x_ = std::clamp(n - 1, 0, cols_ - 1);
        pending_wrap_ = false;
        break;
    case 'H':
    case 'f':
        move_to(param(1, 1) - 1, param(0, 1) - 1);
        break;
    case 'I':
        for (int k = 0, m = std::min(n, cols_); k < m; k++)
            execute(0x09);
        break;
    case 'J':
        erase_display(nparams_ ? params_[0] : 0);
        break;
    case 'K':
        erase_line(nparams_ ? params_[0] : 0);
        break;
    case 'L':
        if (y_ >= top_ && y_ <= bottom_)
            scroll_down(y_, bottom_, n), x_ = 0;
        break;
    case 'M':
        if (y_ >= top_ && y_ <= bottom_)
            scroll_up(y_, bottom_, n, false), x_ = 0;
        break;
    case 'P': {
        Cell* r = at(0, y_);
        int k = std::min(n, cols_ - x_);
        std::move(r + x_ + k, r + cols_, r + x_);
        clear_cells(r + cols_ - k, size_t(k));
        break;
    }
    case 'S':
        scroll_up(top_, bottom_, n, false);
        break;
    case 'T':
        scroll_down(top_, bottom_, n);
        break;
    case 'X':
        clear_cells(at(x_, y_), size_t(std::min(n, cols_ - x_)));
        break;
    case 'Z':
        for (int k = 0; k < n && x_ > 0; k++) {
            x_--;
            while (x_ > 0 && !tabs_[size_t(x_)])
                x_--;
        }
        break;
    case 'b':
        for (int k = 0; k < std::min(n, 65535) && last_; k++)
            print(last_);
        break;
    case 'd':
        y_ = std::clamp(n - 1, 0, rows_ - 1);
        pending_wrap_ = false;
        break;
    case 'g':
        if (param(0, 0) == 3)
            std::fill(tabs_.begin(), tabs_.end(), 0);
        else
            tabs_[size_t(x_)] = 0;
        break;
    case 'h':
        set_mode(true);
        break;
    case 'l':
        set_mode(false);
        break;
    case 'm':
        sgr();
        break;
    case 'r': {
        int t = param(0, 1) - 1, bt = param(1, rows_) - 1;
        if (t < bt && bt < rows_)
            top_ = t, bottom_ = bt, move_to(0, 0);
        break;
    }
    case 's':
        save_cursor();
        break;
    case 'u':
        restore_cursor();
        break;
    default:
        break;
    }
}

void Terminal::reset_palette() {
    static constexpr uint32_t k16[16] = {0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd,
                                         0x00cdcd, 0xe5e5e5, 0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00,
                                         0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff};
    for (int i = 0; i < 16; i++)
        palette_[i] = k16[i];
    for (int i = 0; i < 216; i++) {
        auto v = [](int k) { return uint32_t(k ? 55 + k * 40 : 0); };
        palette_[16 + i] = v(i / 36) << 16 | v(i / 6 % 6) << 8 | v(i % 6);
    }
    for (int i = 0; i < 24; i++) {
        uint32_t g = uint32_t(8 + i * 10);
        palette_[232 + i] = g << 16 | g << 8 | g;
    }
}

static uint32_t parse_colour(std::string_view v) {
    auto hex = [](std::string_view h, uint32_t& out) {
        if (h.empty() || h.size() > 4)
            return false;
        uint32_t x = 0;
        for (char c : h) {
            int d = c >= '0' && c <= '9' ? c - '0'
                : c >= 'a' && c <= 'f'   ? c - 'a' + 10
                : c >= 'A' && c <= 'F'   ? c - 'A' + 10
                                         : -1;
            if (d < 0)
                return false;
            x = x * 16 + uint32_t(d);
        }
        uint32_t max = (1u << (4 * h.size())) - 1;
        out = (x * 255 + max / 2) / max;
        return true;
    };
    if (v.starts_with("rgb:")) {
        v.remove_prefix(4);
        size_t a = v.find('/'), b = a == std::string_view::npos ? a : v.find('/', a + 1);
        uint32_t r, g, bl;
        if (b == std::string_view::npos || !hex(v.substr(0, a), r) || !hex(v.substr(a + 1, b - a - 1), g)
            || !hex(v.substr(b + 1), bl))
            return Terminal::kUnset;
        return r << 16 | g << 8 | bl;
    }
    if (v.starts_with("#") && v.size() == 7) {
        uint32_t r, g, bl;
        if (!hex(v.substr(1, 2), r) || !hex(v.substr(3, 2), g) || !hex(v.substr(5, 2), bl))
            return Terminal::kUnset;
        return r << 16 | g << 8 | bl;
    }
    return Terminal::kUnset;
}

void Terminal::osc_dispatch() {
    size_t semi = osc_.find(';');
    std::string_view num(osc_.data(), semi == std::string::npos ? osc_.size() : semi);
    std::string_view rest = semi == std::string::npos ? std::string_view() : std::string_view(osc_).substr(semi + 1);
    if (num == "0" || num == "2") {
        title_.assign(rest.data(), std::min(rest.size(), kMaxOsc));
    } else if (num == "4") {
        while (!rest.empty()) {
            size_t a = rest.find(';');
            if (a == std::string_view::npos)
                break;
            size_t b = rest.find(';', a + 1);
            std::string_view idx = rest.substr(0, a),
                             col = rest.substr(a + 1, b == std::string_view::npos ? std::string_view::npos : b - a - 1);
            int i = 0;
            bool ok = !idx.empty() && idx.size() <= 3;
            for (char c : idx) {
                ok = ok && c >= '0' && c <= '9';
                if (!ok)
                    break;
                i = i * 10 + (c - '0');
            }
            uint32_t rgbv = parse_colour(col);
            if (ok && i < 256 && rgbv != kUnset)
                palette_[i] = rgbv;
            if (b == std::string_view::npos)
                break;
            rest.remove_prefix(b + 1);
        }
    } else if (num == "8") {
        size_t b = rest.find(';');
        if (b == std::string_view::npos)
            return;
        std::string_view params = rest.substr(0, b), uri = rest.substr(b + 1);
        link_ = uri.empty() || !link_fn_ || osc_cut_ ? 0 : link_fn_(link_ctx_, params, uri);
    } else if (num == "104") {
        reset_palette();
    } else if (num == "10" || num == "11" || num == "12") {
        uint32_t c = parse_colour(rest);
        if (c != kUnset)
            (num == "10" ? fg_rgb_ : num == "11" ? bg_rgb_ : cursor_rgb_) = c;
    } else if (num == "110") {
        fg_rgb_ = kUnset;
    } else if (num == "111") {
        bg_rgb_ = kUnset;
    } else if (num == "112") {
        cursor_rgb_ = kUnset;
    }
}

void Terminal::apc_dispatch() {
    std::string_view a(apc_);
    if (gfx_fn_ && a.starts_with('G'))
        return gfx_fn_(gfx_ctx_, a.substr(1));
    if (!rex_fn_ || !a.starts_with("rex1;"))
        return;
    a.remove_prefix(5);
    size_t semi = a.find(';');
    if (semi == std::string_view::npos)
        return;
    uint64_t n = 0;
    for (char c : a.substr(0, semi)) {
        if (c < '0' || c > '9')
            return;
        n = n * 10 + uint64_t(c - '0');
    }
    if (n != nonce_ || !nonce_)
        return;
    rex_fn_(rex_ctx_, a.substr(semi + 1));
}

void Terminal::feed(std::span<const uint8_t> bytes) {
    for (uint8_t b : bytes) {
        if (utf_left_ > 0) {
            if ((b & 0xC0) == 0x80) {
                utf_ = (utf_ << 6) | (b & 0x3F);
                if (--utf_left_ == 0) {
                    if (state_ == State::ground)
                        print(utf_);
                    else if (state_ == State::osc && osc_.size() + 4 >= kMaxOsc)
                        osc_cut_ = true;
                    else if (state_ == State::osc) {
                        char32_t c = utf_;
                        if (c < 0x800)
                            osc_ += char(0xC0 | (c >> 6)), osc_ += char(0x80 | (c & 0x3F));
                        else if (c < 0x10000)
                            osc_ += char(0xE0 | (c >> 12)), osc_ += char(0x80 | ((c >> 6) & 0x3F)),
                                osc_ += char(0x80 | (c & 0x3F));
                        else
                            osc_ += char(0xF0 | (c >> 18)), osc_ += char(0x80 | ((c >> 12) & 0x3F)),
                                osc_ += char(0x80 | ((c >> 6) & 0x3F)), osc_ += char(0x80 | (c & 0x3F));
                    }
                }
                continue;
            }
            utf_left_ = 0;
            if (state_ == State::ground)
                print(U'�');
        }
        if (b >= 0xC0 && (state_ == State::ground || state_ == State::osc)) {
            utf_left_ = b >= 0xF0 ? 3 : b >= 0xE0 ? 2 : 1;
            utf_ = b & (b >= 0xF0 ? 0x07 : b >= 0xE0 ? 0x0F : 0x1F);
            continue;
        }
        if (b >= 0x80 && state_ == State::ground) {
            print(U'�');
            continue;
        }
        if (b == 0x18 || b == 0x1A) {
            state_ = State::ground;
            continue;
        }
        if (b == 0x1B) {
            if (state_ == State::osc)
                osc_dispatch();
            else if (state_ == State::apc)
                apc_dispatch();
            state_ = State::escape;
            inter_ = 0;
            continue;
        }
        switch (state_) {
        case State::ground:
            if (b < 0x20 || b == 0x7F)
                execute(b);
            else
                print(b);
            break;
        case State::escape:
            if (b < 0x20)
                execute(b);
            else if (b == '[') {
                state_ = State::csi_entry;
                nparams_ = 0, param_started_ = false, private_ = 0, inter_ = 0;
                std::fill(params_, params_ + kMaxParams, 0);
                std::fill(sub_, sub_ + kMaxParams, 0);
            } else if (b == ']') {
                state_ = State::osc;
                osc_.clear();
                osc_cut_ = false;
            } else if (b == 'P') {
                state_ = State::dcs;
            } else if (b == '_') {
                state_ = State::apc;
                apc_.clear();
            } else if (b == 'X' || b == '^') {
                state_ = State::ignore_string;
            } else if (b >= 0x20 && b <= 0x2F) {
                inter_ = b;
                state_ = State::escape_inter;
            } else {
                if (b == '\\') {
                    state_ = State::ground;
                    break;
                }
                esc_dispatch(b);
                state_ = State::ground;
            }
            break;
        case State::escape_inter:
            if (b < 0x20)
                execute(b);
            else if (b <= 0x2F)
                inter_ = b;
            else
                esc_dispatch(b), state_ = State::ground;
            break;
        case State::csi_entry:
        case State::csi_param:
            if (b < 0x20)
                execute(b);
            else if (b >= '0' && b <= '9') {
                if (!param_started_) {
                    if (nparams_ < kMaxParams)
                        nparams_++;
                    param_started_ = true;
                }
                int& p = params_[nparams_ - 1];
                p = std::min(p * 10 + (b - '0'), 65535);
                state_ = State::csi_param;
            } else if (b == ';' || b == ':') {
                if (!param_started_ && nparams_ < kMaxParams)
                    nparams_++;
                param_started_ = false;
                if (nparams_ < kMaxParams) {
                    nparams_++;
                    params_[nparams_ - 1] = 0;
                    sub_[nparams_ - 1] = b == ':';
                    param_started_ = true;
                }
                state_ = State::csi_param;
            } else if (b >= 0x3C && b <= 0x3F) {
                if (state_ == State::csi_entry)
                    private_ = b;
                else
                    state_ = State::csi_ignore;
            } else if (b >= 0x20 && b <= 0x2F) {
                inter_ = b;
                state_ = State::csi_inter;
            } else if (b >= 0x40 && b <= 0x7E) {
                csi_dispatch(b);
                state_ = State::ground;
            }
            break;
        case State::csi_inter:
            if (b < 0x20)
                execute(b);
            else if (b <= 0x2F)
                inter_ = b;
            else if (b >= 0x40 && b <= 0x7E)
                csi_dispatch(b), state_ = State::ground;
            else
                state_ = State::csi_ignore;
            break;
        case State::csi_ignore:
            if (b >= 0x40 && b <= 0x7E)
                state_ = State::ground;
            break;
        case State::osc:
            if (b == 0x07) {
                osc_dispatch();
                state_ = State::ground;
            } else if (b >= 0x20) {
                if (osc_.size() < kMaxOsc)
                    osc_ += char(b);
                else
                    osc_cut_ = true;
            }
            break;
        case State::apc:
            if (b >= 0x20 && apc_.size() < kMaxApc)
                apc_ += char(b);
            break;
        case State::dcs:
        case State::ignore_string:
            break;
        }
    }
}

static void append_utf8(std::string& s, char32_t c) {
    if (c < 0x80)
        s += char(c);
    else if (c < 0x800)
        s += char(0xC0 | (c >> 6)), s += char(0x80 | (c & 0x3F));
    else if (c < 0x10000)
        s += char(0xE0 | (c >> 12)), s += char(0x80 | ((c >> 6) & 0x3F)), s += char(0x80 | (c & 0x3F));
    else
        s += char(0xF0 | (c >> 18)), s += char(0x80 | ((c >> 12) & 0x3F)), s += char(0x80 | ((c >> 6) & 0x3F)),
            s += char(0x80 | (c & 0x3F));
}

std::string Terminal::text() const {
    std::string out;
    auto line = [&](const Cell* r) {
        std::string l;
        for (int x = 0; x < cols_; x++) {
            if (r[x].width == 0)
                continue;
            append_utf8(l, r[x].cp);
            for (char32_t c : r[x].comb)
                if (c)
                    append_utf8(l, c);
        }
        while (!l.empty() && l.back() == ' ')
            l.pop_back();
        out += l;
        out += '\n';
    };
    for (int i = 0; i < sb_count_; i++)
        line(scrollback_row(i));
    for (int y = 0; y < rows_; y++)
        line(row(y));
    return out;
}

}
