// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <expected>
#include <flat_map>
#include <string_view>
#include <vector>

namespace rx::keys {

enum : uint8_t { k_cmd = 1, k_ctrl = 2, k_alt = 4, k_shift = 8 };
inline constexpr uint16_t k_by_chars = 0xFFFF;
inline constexpr size_t k_max_chars = 16;

struct Chord {
    uint16_t code = k_by_chars;
    uint8_t mods = 0;
    uint8_t len = 0;
    char16_t chars[k_max_chars] = {};
    std::u16string_view key() const { return {chars, len}; }
};

enum class Error : uint8_t {
    empty,
    no_key,
    too_long,
};

std::expected<Chord, Error> parse(std::u16string_view spec);
uint16_t named_code(std::u16string_view key);

enum class Kind : uint8_t { drawer, shortcut, bar, search, group, dock };
struct Target {
    Kind kind;
    uint32_t order;
    const void* ref;
};

class Table {
  public:
    void clear();
    bool add(std::u16string_view spec, Target t);
    void seal();

    bool wants_chars(uint8_t mods) const { return (char_mods_ >> (mods & 15)) & 1; }
    size_t find(uint16_t code, uint8_t mods, std::u16string_view chars, Target* out, size_t cap) const;
    size_t size() const { return by_code_.size() + by_char_.size() + by_string_.size(); }

  private:
    static uint32_t code_key(uint8_t mods, uint16_t code) { return uint32_t(mods & 15) << 16 | code; }
    static uint32_t char_key(uint8_t mods, uint32_t cp) { return uint32_t(mods & 15) << 21 | cp; }

    std::flat_multimap<uint32_t, Target> by_code_;
    std::flat_multimap<uint32_t, Target> by_char_;
    struct Long {
        Chord chord;
        Target t;
    };
    std::vector<Long> by_string_;
    std::vector<std::pair<uint32_t, Target>> pending_code_, pending_char_;
    uint16_t char_mods_ = 0;
};

inline bool before(const Target& a, const Target& b) {
    return a.kind != b.kind ? a.kind < b.kind : a.order < b.order;
}

}
