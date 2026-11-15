// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <memory>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace rx::text {

enum class Token : uint8_t { comment, string, keyword, number, key, call, type, meta, count_ };

struct BlockSpec {
    std::u16string_view open, close;
    bool nested = false;
};
struct StringSpec {
    std::u16string_view open, close;
    char16_t escape = 0;
    bool multiline = false;
    bool char_literal = false;
    std::u16string_view hole_open = {}, hole_close = {};
};
struct PairSpec {
    std::u16string_view open, close;
};
struct SigilSpec {
    char16_t sigil = 0;
    Token kind = Token::meta;
};
enum class Raw : uint8_t { none, cpp, rust };

struct Spec {
    std::span<const std::u16string_view> line_comments;
    std::span<const BlockSpec> block_comments;
    std::span<const StringSpec> strings;
    std::span<const std::u16string_view> line_strings;
    std::span<const PairSpec> attributes;
    std::span<const SigilSpec> sigils;
    std::span<const std::u16string_view> keywords, types;
    std::span<const std::u16string_view> values;
    std::span<const std::u16string_view> calls;
    std::span<const std::u16string_view> call_after;
    std::span<const std::u16string_view> key_before;
    std::u16string_view long_comment = {};
    std::u16string_view word_chars = {};
    std::u16string_view assign = {};
    char16_t preprocessor = 0;
    char16_t digit_sep = 0;
    bool type_case = false;
    bool bit_ints = false;
    bool bang_macros = false;
    bool long_brackets = false;
    bool regex = false;
    bool members = false;
    Raw raw = Raw::none;
};

class Lang {
  public:
    using Mark = void (*)(void* ctx, Token kind, uint32_t at, uint32_t len);

    static constexpr size_t k_lookahead = 2048;

    explicit Lang(const Spec& spec);

    void lex(std::u16string_view s, void* ctx, Mark mark) const noexcept;

    enum class Mode : uint8_t {
        code,
        block,
        string,
        raw_cpp,
        raw_rust,
        long_string,
        long_comment,
        attribute,
        preprocessor,
        line_comment,
        line_string,
        value,
        plain_line,
        plain_word
    };
    enum class Prev : uint8_t { none, value, dot, dots };
    static constexpr int k_holes = 8;
    struct Hole {
        uint16_t rule = 0, depth = 0;
        bool operator==(const Hole&) const = default;
    };
    struct Resume {
        size_t at = 0;
        bool line_start = true, names_a_call = false;
        Prev prev = Prev::none;
        Mode mode = Mode::code;
        uint16_t rule = 0;
        uint32_t depth = 0;
        char16_t delim[16] = {};
        uint8_t holes = 0;
        Hole hole[k_holes] = {};
        bool operator==(const Resume&) const = default;
    };
    void run(std::u16string_view s, Resume& r, size_t stop, void* ctx, Mark mark) const noexcept;

  private:
    struct Block {
        std::u16string open, close;
        bool nested;
    };
    struct Str {
        std::u16string open, close;
        char16_t escape;
        bool multiline, char_literal;
        std::u16string hole_open, hole_close;
    };
    struct Pair {
        std::u16string open, close;
    };
    struct Word {
        uint32_t at = 0, len = 0, hash = 0;
        Token kind = Token::keyword;
        bool value = false;
    };
    void add_word(std::u16string_view w, Token kind, bool value);
    const Word* word_of(std::u16string_view w) const noexcept;
    void can_start(char16_t c) noexcept;

    std::vector<std::u16string> line_comments_, line_strings_, calls_, call_after_, key_before_;
    std::vector<Block> blocks_;
    std::vector<Str> strings_;
    std::vector<Pair> attributes_;
    std::vector<SigilSpec> sigils_;
    std::u16string words_, long_comment_, assign_;
    std::vector<Word> table_;
    bool word_start_[128] = {}, word_char_[128] = {};
    bool starts_[128] = {};
    bool starts_high_ = false;
    char16_t preprocessor_, digit_sep_;
    bool type_case_, bit_ints_, bang_macros_, long_brackets_, regex_, members_;
    Raw raw_;
};

const Lang* builtin_lang(std::u16string_view name) noexcept;

}
