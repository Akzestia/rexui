// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/keys/keys.h"

#include <algorithm>

namespace rx::keys {

namespace {

bool is_space(char16_t c) {
    return c == u' ' || c == u'\t' || c == 0x00A0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x202F
        || c == 0x205F || c == 0x3000;
}

std::u16string_view trim(std::u16string_view s) {
    while (!s.empty() && is_space(s.front()))
        s.remove_prefix(1);
    while (!s.empty() && is_space(s.back()))
        s.remove_suffix(1);
    return s;
}

bool eq(std::u16string_view a, const char* b) {
    size_t n = 0;
    for (; b[n]; n++)
        if (n >= a.size() || a[n] != (char16_t)(unsigned char)b[n])
            return false;
    return n == a.size();
}

struct Named {
    const char* name;
    uint16_t code;
};
constexpr Named k_named[] = {
    {"space", 49}, {"tab", 48},    {"return", 36}, {"enter", 36}, {"escape", 53}, {"esc", 53},
    {"left", 123}, {"right", 124}, {"down", 125},  {"up", 126},   {"f1", 122},    {"f2", 120},
    {"f3", 99},    {"f4", 118},    {"f5", 96},     {"f6", 97},    {"f7", 98},     {"f8", 100},
    {"f9", 101},   {"f10", 109},   {"f11", 103},   {"f12", 111},
};

int32_t single(std::u16string_view k) {
    if (k.size() == 1 && (k[0] < 0xD800 || k[0] > 0xDFFF))
        return k[0];
    if (k.size() == 2 && k[0] >= 0xD800 && k[0] <= 0xDBFF && k[1] >= 0xDC00 && k[1] <= 0xDFFF)
        return 0x10000 + ((k[0] - 0xD800) << 10) + (k[1] - 0xDC00);
    return -1;
}

}

uint16_t named_code(std::u16string_view key) {
    for (const Named& n : k_named)
        if (eq(key, n.name))
            return n.code;
    return k_by_chars;
}

std::expected<Chord, Error> parse(std::u16string_view spec) {
    if (spec.empty())
        return std::unexpected(Error::empty);
    Chord c;
    std::u16string_view key;
    bool have_key = false;
    while (true) {
        size_t plus = spec.find(u'+');
        std::u16string_view raw = spec.substr(0, plus);
        char16_t low[k_max_chars + 8];
        std::u16string_view p = trim(raw);
        bool fits = p.size() <= sizeof low / sizeof low[0];
        if (fits) {
            for (size_t i = 0; i < p.size(); i++)
                low[i] = p[i] >= u'A' && p[i] <= u'Z' ? char16_t(p[i] + 32) : p[i];
        }
        std::u16string_view lp = fits ? std::u16string_view(low, p.size()) : p;
        if (fits && (eq(lp, "cmd") || eq(lp, "command") || eq(lp, "super")))
            c.mods |= k_cmd;
        else if (fits && (eq(lp, "ctrl") || eq(lp, "control")))
            c.mods |= k_ctrl;
        else if (fits && (eq(lp, "alt") || eq(lp, "opt") || eq(lp, "option")))
            c.mods |= k_alt;
        else if (fits && eq(lp, "shift"))
            c.mods |= k_shift;
        else {
            have_key = true;
            if (lp.size() > k_max_chars) {
                key = {};
                c.len = 0xFF;
            } else {
                for (size_t i = 0; i < lp.size(); i++)
                    c.chars[i] = lp[i];
                c.len = (uint8_t)lp.size();
                key = c.key();
            }
        }
        if (plus == std::u16string_view::npos)
            break;
        spec.remove_prefix(plus + 1);
    }
    if (!have_key)
        return std::unexpected(Error::no_key);
    if (c.len == 0xFF)
        return std::unexpected(Error::too_long);
    if (c.len == 0)
        return std::unexpected(Error::no_key);
    c.code = named_code(key);
    if (c.code != k_by_chars)
        c.len = 0, std::fill(std::begin(c.chars), std::end(c.chars), u'\0');
    return c;
}

void Table::clear() {
    by_code_.clear();
    by_char_.clear();
    by_string_.clear();
    pending_code_.clear();
    pending_char_.clear();
    char_mods_ = 0;
}

bool Table::add(std::u16string_view spec, Target t) {
    auto c = parse(spec);
    if (!c)
        return false;
    if (c->code != k_by_chars) {
        pending_code_.push_back({code_key(c->mods, c->code), t});
        return true;
    }
    char_mods_ |= uint16_t(1u << (c->mods & 15));
    if (int32_t cp = single(c->key()); cp >= 0)
        pending_char_.push_back({char_key(c->mods, (uint32_t)cp), t});
    else
        by_string_.push_back({*c, t});
    return true;
}

void Table::seal() {
    auto by = [](const std::pair<uint32_t, Target>& a, const std::pair<uint32_t, Target>& b) {
        return a.first != b.first ? a.first < b.first : before(a.second, b.second);
    };
    for (auto* pend : {&pending_code_, &pending_char_})
        std::stable_sort(pend->begin(), pend->end(), by);
    std::vector<uint32_t> ks;
    std::vector<Target> ts;
    auto build = [&](std::vector<std::pair<uint32_t, Target>>& pend, std::flat_multimap<uint32_t, Target>& into) {
        ks.clear(), ts.clear();
        for (auto& [k, t] : pend)
            ks.push_back(k), ts.push_back(t);
        into = std::flat_multimap<uint32_t, Target>(std::sorted_equivalent, std::move(ks), std::move(ts));
        ks = {}, ts = {};
        pend.clear();
    };
    build(pending_code_, by_code_);
    build(pending_char_, by_char_);
    std::stable_sort(by_string_.begin(), by_string_.end(),
                     [](const Long& a, const Long& b) { return before(a.t, b.t); });
}

size_t Table::find(uint16_t code, uint8_t mods, std::u16string_view chars, Target* out, size_t cap) const {
    size_t n = 0;
    auto put = [&](const Target& t) {
        if (n < cap) {
            size_t i = n;
            while (i > 0 && before(t, out[i - 1]))
                out[i] = out[i - 1], i--;
            out[i] = t;
        }
        n++;
    };
    auto [b, e] = by_code_.equal_range(code_key(mods, code));
    for (auto it = b; it != e; ++it)
        put(it->second);
    if (wants_chars(mods) && !chars.empty()) {
        if (int32_t cp = single(chars); cp >= 0) {
            auto [cb, ce] = by_char_.equal_range(char_key(mods, (uint32_t)cp));
            for (auto it = cb; it != ce; ++it)
                put(it->second);
        }
        for (const Long& l : by_string_)
            if ((l.chord.mods & 15) == (mods & 15) && l.chord.key() == chars)
                put(l.t);
    }
    return n;
}

}
