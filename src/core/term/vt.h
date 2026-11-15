// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <expected>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace rx::term {

using Color = uint32_t;
inline constexpr Color kDefault = 0;
inline constexpr Color palette(uint8_t i) {
    return 0x02000000u | i;
}
inline constexpr Color rgb(uint8_t r, uint8_t g, uint8_t b) {
    return 0x01000000u | (uint32_t(r) << 16) | (uint32_t(g) << 8) | b;
}
inline constexpr bool is_palette(Color c) {
    return (c >> 24) == 2;
}
inline constexpr bool is_rgb(Color c) {
    return (c >> 24) == 1;
}

enum Attr : uint16_t {
    kBold = 1 << 0,
    kDim = 1 << 1,
    kItalic = 1 << 2,
    kUnderline = 1 << 3,
    kBlink = 1 << 4,
    kInverse = 1 << 5,
    kHidden = 1 << 6,
    kStrike = 1 << 7,
    kOverline = 1 << 8,
};

struct Cell {
    char32_t cp = U' ';
    char32_t comb[2] = {0, 0};
    uint16_t attrs : 11 = 0;
    uint16_t underline : 3 = 0;
    uint16_t width : 2 = 1;
    uint16_t link = 0;
    Color fg = kDefault, bg = kDefault;
};
static_assert(sizeof(Cell) == 24);

enum class Error { bad_size };

class Terminal {
  public:
    static std::expected<Terminal, Error> make(int cols, int rows, int scrollback = 2000);

    void feed(std::span<const uint8_t> bytes);
    void feed(std::string_view s) {
        feed(std::span<const uint8_t>(reinterpret_cast<const uint8_t*>(s.data()), s.size()));
    }
    std::expected<void, Error> resize(int cols, int rows);
    std::expected<Terminal, Error> reflowed(int cols, int rows) const;

    int cols() const { return cols_; }
    int rows() const { return rows_; }
    const Cell* row(int y) const { return screen() + size_t(y) * size_t(cols_); }
    bool wrapped(int y) const { return (alt_ ? alt_wrap_ : main_wrap_)[size_t(y)] != 0; }
    int scrollback() const { return sb_count_; }
    size_t scrollback_bytes() const;
    const Cell* scrollback_row(int i) const;
    bool scrollback_wrapped(int i) const;
    int cursor_x() const { return x_; }
    int cursor_y() const { return y_; }
    bool cursor_visible() const { return cursor_on_; }
    enum class CursorShape : uint8_t { unset, block, underline, bar };
    CursorShape cursor_shape() const { return cursor_shape_; }
    void set_cursor_shape(CursorShape s) { cursor_shape_ = s; }
    bool alternate() const { return alt_; }
    enum class MouseTracking : uint8_t { none, press, drag, any };
    MouseTracking mouse_tracking() const { return mouse_; }
    std::string_view title() const { return title_; }
    static constexpr uint32_t kUnset = 0xFF000000u;
    uint32_t palette_rgb(uint8_t i) const { return palette_[i]; }
    uint32_t default_fg() const { return fg_rgb_; }
    uint32_t default_bg() const { return bg_rgb_; }
    uint32_t cursor_rgb() const { return cursor_rgb_; }

    using RexMessageFn = void (*)(void* ctx, std::string_view json);
    void on_rex_message(uint64_t nonce, RexMessageFn f, void* ctx) { nonce_ = nonce, rex_fn_ = f, rex_ctx_ = ctx; }

    using GraphicsFn = void (*)(void* ctx, std::string_view apc);
    void on_graphics(GraphicsFn f, void* ctx) { gfx_fn_ = f, gfx_ctx_ = ctx; }
    uint64_t scrolled() const { return scrolled_; }
    void set_scrolled(uint64_t n) { scrolled_ = n; }
    uint64_t cleared() const { return cleared_; }
    void cursor_past_image(int cols, int rows);

    using LinkFn = uint16_t (*)(void* ctx, std::string_view params, std::string_view uri);
    void on_link(LinkFn f, void* ctx) { link_fn_ = f, link_ctx_ = ctx; }
    uint16_t link() const { return link_; }

    std::string text() const;

  private:
    struct Pen {
        uint16_t attrs = 0;
        uint8_t underline = 0;
        Color fg = kDefault, bg = kDefault;
    };
    struct Saved {
        int x = 0, y = 0;
        Pen pen;
        bool origin = false;
        uint8_t g[2] = {'B', 'B'};
        int gl = 0;
    };
    enum class State : uint8_t {
        ground,
        escape,
        escape_inter,
        csi_entry,
        csi_param,
        csi_inter,
        csi_ignore,
        osc,
        dcs,
        ignore_string,
        apc
    };

    Cell* screen() { return (alt_ ? alt_cells_ : main_).data(); }
    const Cell* screen() const { return (alt_ ? alt_cells_ : main_).data(); }
    Cell* at(int x, int y) { return screen() + size_t(y) * size_t(cols_) + size_t(x); }
    Cell blank() const;
    void clear_cells(Cell* from, size_t n);
    void scroll_up(int top, int bottom, int n, bool keep);
    void scroll_down(int top, int bottom, int n);
    void line_feed();
    void reverse_index();
    void print(char32_t c);
    void execute(uint8_t b);
    void esc_dispatch(uint8_t b);
    void csi_dispatch(uint8_t b);
    void osc_dispatch();
    void apc_dispatch();
    void sgr();
    void set_mode(bool on);
    void erase_display(int how);
    void erase_line(int how);
    void move_to(int x, int y);
    void save_cursor();
    void restore_cursor();
    void switch_screen(bool alt, bool save, bool clear);
    void reset();
    int param(int i, int fallback) const;

    int cols_ = 0, rows_ = 0;
    std::vector<Cell> main_, alt_cells_;
    std::vector<uint8_t> main_wrap_, alt_wrap_;
    static constexpr int kSbChunk = 256;
    std::vector<std::unique_ptr<Cell[]>> sb_chunks_;
    std::vector<uint8_t> sb_wrap_;
    int sb_cap_ = 0, sb_head_ = 0, sb_count_ = 0;
    Cell* sb_slot(int slot) const {
        return sb_chunks_[size_t(slot / kSbChunk)].get() + size_t(slot % kSbChunk) * size_t(cols_);
    }
    bool sb_make(int slot);
    bool alt_ = false;
    int x_ = 0, y_ = 0;
    bool pending_wrap_ = false;
    Pen pen_;
    int top_ = 0, bottom_ = 0;
    bool origin_ = false, autowrap_ = true, insert_ = false, cursor_on_ = true;
    CursorShape cursor_shape_ = CursorShape::unset;
    MouseTracking mouse_ = MouseTracking::none;
    std::vector<uint8_t> tabs_;
    uint8_t g_[2] = {'B', 'B'};
    int gl_ = 0;
    Saved saved_main_, saved_alt_;
    State state_ = State::ground;
    uint32_t utf_ = 0;
    int utf_left_ = 0;
    static constexpr int kMaxParams = 32;
    int params_[kMaxParams] = {};
    uint8_t sub_[kMaxParams] = {};
    int nparams_ = 0;
    bool param_started_ = false;
    uint8_t private_ = 0;
    uint8_t inter_ = 0;
    std::string osc_;
    static constexpr size_t kMaxOsc = 4096;
    bool osc_cut_ = false;
    std::string title_;
    std::string apc_;
    static constexpr size_t kMaxApc = 65536;
    uint32_t palette_[256] = {};
    uint32_t fg_rgb_ = kUnset, bg_rgb_ = kUnset, cursor_rgb_ = kUnset;
    void reset_palette();
    uint64_t nonce_ = 0;
    GraphicsFn gfx_fn_ = nullptr;
    void* gfx_ctx_ = nullptr;
    uint64_t scrolled_ = 0, cleared_ = 0;
    RexMessageFn rex_fn_ = nullptr;
    void* rex_ctx_ = nullptr;
    LinkFn link_fn_ = nullptr;
    void* link_ctx_ = nullptr;
    uint16_t link_ = 0;
    char32_t last_ = 0;
};

int char_width(char32_t c);

}
