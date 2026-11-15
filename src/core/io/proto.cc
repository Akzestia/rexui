// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/io/proto.h"

#include <charconv>
#include <cmath>
#include <cstring>
#include <utility>

#include "rexui_proto.h"

namespace rx::io::proto {
namespace {

struct Out {
    char* p;
    std::size_t cap, n = 0;
    bool ok = true;
    void put(std::string_view s) noexcept {
        if (!ok || s.size() > cap - n) {
            ok = false;
            return;
        }
        std::memcpy(p + n, s.data(), s.size());
        n += s.size();
    }
    void put(char c) noexcept { put(std::string_view(&c, 1)); }
    void quoted(const char* s, std::size_t len) noexcept {
        static constexpr char hex[] = "0123456789abcdef";
        put('"');
        std::size_t run = 0;
        for (std::size_t i = 0; i < len && ok; i++) {
            auto c = static_cast<unsigned char>(s[i]);
            if (c >= 0x20 && c != '"' && c != '\\')
                continue;
            put({s + run, i - run});
            run = i + 1;
            if (c == '"' || c == '\\') {
                put('\\'), put(static_cast<char>(c));
            } else {
                const char u[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
                put({u, 6});
            }
        }
        put({s + run, len - run});
        put('"');
    }
};

struct Num {
    char b[40];
    std::size_t n;
    operator std::string_view() const noexcept { return {b, n}; }
};
Num number(double v) noexcept {
    Num r{};
    double a = std::fabs(v);
    if (v == 0) {
        r.b[0] = '0', r.n = 1;
        return r;
    }
    bool plain = a >= 1e-6 && a < 1e21;
    auto t = std::to_chars(r.b, r.b + sizeof r.b, v, plain ? std::chars_format::fixed : std::chars_format::scientific);
    r.n = static_cast<std::size_t>(t.ptr - r.b);
    if (plain)
        return r;
    char* e = static_cast<char*>(std::memchr(r.b, 'e', r.n));
    if (!e || e + 2 >= r.b + r.n)
        return r;
    char* d = e + 2;
    char* z = d;
    while (z < r.b + r.n - 1 && *z == '0')
        z++;
    std::memmove(d, z, static_cast<std::size_t>(r.b + r.n - z));
    r.n -= static_cast<std::size_t>(z - d);
    return r;
}

}

bool hello(std::string_view line, std::uint32_t* features) noexcept {
    while (!line.empty() && (line.front() == ' ' || line.front() == '\t'))
        line.remove_prefix(1);
    while (!line.empty() && (line.back() == ' ' || line.back() == '\t' || line.back() == '\r'))
        line.remove_suffix(1);
    constexpr std::string_view head = "{\"rexui\":";
    if (line.size() > 4096 || !line.starts_with(head) || line.back() != '}')
        return false;
    std::size_t at = line.find("\"protocol\":");
    if (at == std::string_view::npos)
        return false;
    at += 11;
    while (at < line.size() && line[at] == ' ')
        at++;
    unsigned v = 0;
    auto r = std::from_chars(line.data() + at, line.data() + line.size(), v);
    if (r.ec != std::errc() || v < 2)
        return false;
    std::uint32_t f = 0;
    std::size_t fs = line.find("\"features\":");
    if (fs != std::string_view::npos) {
        std::size_t end = line.find(']', fs);
        std::string_view list = line.substr(fs, end == std::string_view::npos ? std::string_view::npos : end - fs);
        if (list.find("\"patch\"") != std::string_view::npos)
            f |= k_patch;
        if (list.find("\"call\"") != std::string_view::npos)
            f |= k_call;
        if (list.find("\"credit\"") != std::string_view::npos)
            f |= k_credit;
    }
    *features = f;
    return true;
}

std::size_t answer(std::uint32_t features, std::uint32_t credit, std::span<char> out) noexcept {
    Out o{out.data(), out.size()};
    o.put("{\"rexui\":{\"protocol\":2,\"features\":[");
    bool first = true;
    for (auto [bit, name] :
         {std::pair{k_patch, "\"patch\""}, std::pair{k_call, "\"call\""}, std::pair{k_credit, "\"credit\""}}) {
        if (!(features & bit))
            continue;
        if (!first)
            o.put(',');
        o.put(name);
        first = false;
    }
    o.put("]");
    if (features & k_credit) {
        char b[16];
        auto r = std::to_chars(b, b + sizeof b, credit);
        o.put(",\"credit\":"), o.put({b, static_cast<std::size_t>(r.ptr - b)});
    }
    o.put("}}\n");
    return o.ok ? o.n : 0;
}

std::size_t patch_line(std::span<const std::uint8_t> payload, std::span<char> out) noexcept {
    if (payload.size() > REXUI_FRAME_MAX)
        return 0;
    Out o{out.data(), out.size()};
    o.put("{\"state\":{");
    std::uint32_t at = 0, n = static_cast<std::uint32_t>(payload.size());
    rexui_patch_entry_view e;
    bool first = true;
    for (;;) {
        int r = rexui_patch_next(payload.data(), n, &at, &e);
        if (r < 0)
            return 0;
        if (r == 0)
            break;
        if (!first)
            o.put(',');
        first = false;
        o.quoted(e.key, e.key_len);
        o.put(':');
        switch (e.tag) {
        case REXUI_V_NULL:
            o.put("null");
            break;
        case REXUI_V_FALSE:
            o.put("false");
            break;
        case REXUI_V_TRUE:
            o.put("true");
            break;
        case REXUI_V_F64: {
            if (!std::isfinite(e.f64)) {
                o.put("null");
                break;
            }
            o.put(number(e.f64));
            break;
        }
        case REXUI_V_STR:
            o.quoted(e.str, e.str_len);
            break;
        case REXUI_V_JSON:
            if (e.str_len == 0)
                return 0;
            o.put({e.str, e.str_len});
            break;
        default:
            return 0;
        }
        if (!o.ok)
            return 0;
    }
    o.put("}}");
    return o.ok ? o.n : 0;
}

}
