// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <string_view>

#include "core/mem/pool.h"

namespace rx::text {

enum class Err { out_of_memory, out_of_range };

class Rope {
  public:
    static constexpr uint32_t k_leaf = 1000;
    static constexpr uint32_t k_fan = 32;

    Rope() noexcept;
    ~Rope();
    Rope(const Rope&) = delete;
    Rope& operator=(const Rope&) = delete;

    bool ok() const noexcept { return root_ != nullptr; }
    size_t size() const noexcept { return units_; }
    size_t breaks() const noexcept { return breaks_; }
    size_t lines() const noexcept { return breaks_ + 1; }

    std::expected<void, Err> replace(size_t at, size_t removed, std::u16string_view text) noexcept;
    std::expected<void, Err> append_utf8(std::string_view bytes) noexcept;
    void clear() noexcept;

    char16_t at(size_t i) const noexcept;
    size_t read(size_t from, size_t n, char16_t* out) const noexcept;

    size_t line_of(size_t i) const noexcept;
    size_t line_start(size_t k) const noexcept;
    size_t next_line(size_t i) const noexcept { return line_start(line_of(i) + 1); }

    size_t nodes() const noexcept { return pool_.in_use(); }
    bool check() const noexcept;

  private:
    struct Leaf {
        uint32_t len;
        char16_t u[k_leaf];
    };
    struct Inner {
        uint32_t n;
        uint32_t units[k_fan], nls[k_fan];
        void* kid[k_fan];
    };
    struct Split {
        void* right = nullptr;
        uint32_t units = 0, nls = 0;
    };

    void* node() noexcept { return pool_.alloc(); }
    bool insert_at(void* n, uint32_t depth, size_t at, std::u16string_view t, Split& out) noexcept;
    void erase_at(void* n, uint32_t depth, size_t at, size_t count) noexcept;
    void free_tree(void* n, uint32_t depth) noexcept;
    bool insert_chunk(size_t at, std::u16string_view t) noexcept;
    bool check_node(const void* n, uint32_t depth, uint32_t& units, uint32_t& nls) const noexcept;

    mem::FixedPool pool_;
    void* root_ = nullptr;
    uint32_t depth_ = 0;
    size_t units_ = 0, breaks_ = 0;
    mutable const Leaf* last_ = nullptr;
    mutable size_t last_at_ = 0;
};

}
