// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/text/rope.h"

#include <algorithm>
#include <cstring>

namespace rx::text {

namespace {
constexpr size_t block_size() {
    return 2048 + 32;
}

uint32_t count_breaks(const char16_t* p, uint32_t n) noexcept {
    uint32_t c = 0;
    for (uint32_t i = 0; i < n; i++)
        c += p[i] == u'\n';
    return c;
}
}

Rope::Rope() noexcept : pool_(block_size(), 64 * 1024) {
    static_assert(sizeof(Leaf) <= block_size() && sizeof(Inner) <= block_size());
    if (void* p = node()) {
        static_cast<Leaf*>(p)->len = 0;
        root_ = p;
    }
}

Rope::~Rope() = default;

void Rope::free_tree(void* n, uint32_t depth) noexcept {
    if (depth) {
        auto* in = static_cast<Inner*>(n);
        for (uint32_t i = 0; i < in->n; i++)
            free_tree(in->kid[i], depth - 1);
    }
    pool_.free(n);
}

void Rope::clear() noexcept {
    last_ = nullptr;
    if (!root_)
        return;
    free_tree(root_, depth_);
    depth_ = 0, units_ = 0, breaks_ = 0;
    root_ = node();
    if (root_)
        static_cast<Leaf*>(root_)->len = 0;
}

bool Rope::insert_at(void* n, uint32_t depth, size_t at, std::u16string_view t, Split& out) noexcept {
    if (!depth) {
        auto* l = static_cast<Leaf*>(n);
        const uint32_t m = static_cast<uint32_t>(t.size()), pos = static_cast<uint32_t>(at);
        if (l->len + m <= k_leaf) {
            std::memmove(l->u + pos + m, l->u + pos, (l->len - pos) * sizeof(char16_t));
            std::memcpy(l->u + pos, t.data(), m * sizeof(char16_t));
            l->len += m;
            return true;
        }
        auto* r = static_cast<Leaf*>(node());
        if (!r)
            return false;
        if (pos == l->len) {
            std::memcpy(r->u, t.data(), m * sizeof(char16_t));
            r->len = m;
        } else {
            const uint32_t tail = l->len - pos;
            std::memcpy(r->u, l->u + pos, tail * sizeof(char16_t));
            r->len = tail;
            l->len = pos;
            if (pos + m <= k_leaf) {
                std::memcpy(l->u + pos, t.data(), m * sizeof(char16_t));
                l->len += m;
            } else if (tail + m <= k_leaf) {
                std::memmove(r->u + m, r->u, tail * sizeof(char16_t));
                std::memcpy(r->u, t.data(), m * sizeof(char16_t));
                r->len += m;
            } else {
                const uint32_t to_left = k_leaf - pos, to_right = m - to_left;
                std::memcpy(l->u + pos, t.data(), to_left * sizeof(char16_t));
                l->len = k_leaf;
                std::memmove(r->u + to_right, r->u, tail * sizeof(char16_t));
                std::memcpy(r->u, t.data() + to_left, to_right * sizeof(char16_t));
                r->len += to_right;
            }
        }
        out.right = r;
        out.units = r->len;
        out.nls = count_breaks(r->u, r->len);
        return true;
    }
    auto* in = static_cast<Inner*>(n);
    uint32_t i = 0;
    size_t into = at;
    while (i + 1 < in->n && into > in->units[i])
        into -= in->units[i], i++;
    Split sub;
    if (!insert_at(in->kid[i], depth - 1, into, t, sub))
        return false;
    uint32_t u = 0, b = 0;
    if (depth == 1) {
        const auto* l = static_cast<const Leaf*>(in->kid[i]);
        u = l->len, b = count_breaks(l->u, l->len);
    } else {
        const auto* k = static_cast<const Inner*>(in->kid[i]);
        for (uint32_t j = 0; j < k->n; j++)
            u += k->units[j], b += k->nls[j];
    }
    in->units[i] = u, in->nls[i] = b;
    if (!sub.right)
        return true;
    if (in->n < k_fan) {
        for (uint32_t j = in->n; j > i + 1; j--)
            in->units[j] = in->units[j - 1], in->nls[j] = in->nls[j - 1], in->kid[j] = in->kid[j - 1];
        in->units[i + 1] = sub.units, in->nls[i + 1] = sub.nls, in->kid[i + 1] = sub.right;
        in->n++;
        return true;
    }
    auto* r = static_cast<Inner*>(node());
    if (!r)
        return false;
    const uint32_t keep = k_fan / 2;
    r->n = in->n - keep;
    for (uint32_t j = 0; j < r->n; j++)
        r->units[j] = in->units[keep + j], r->nls[j] = in->nls[keep + j], r->kid[j] = in->kid[keep + j];
    in->n = keep;
    Inner* side = i + 1 <= keep ? in : r;
    const uint32_t pos = i + 1 <= keep ? i + 1 : i + 1 - keep;
    for (uint32_t j = side->n; j > pos; j--)
        side->units[j] = side->units[j - 1], side->nls[j] = side->nls[j - 1], side->kid[j] = side->kid[j - 1];
    side->units[pos] = sub.units, side->nls[pos] = sub.nls, side->kid[pos] = sub.right;
    side->n++;
    out.right = r;
    out.units = 0, out.nls = 0;
    for (uint32_t j = 0; j < r->n; j++)
        out.units += r->units[j], out.nls += r->nls[j];
    return true;
}

bool Rope::insert_chunk(size_t at, std::u16string_view t) noexcept {
    Split s;
    if (!insert_at(root_, depth_, at, t, s))
        return false;
    units_ += t.size();
    breaks_ += count_breaks(t.data(), static_cast<uint32_t>(t.size()));
    if (!s.right)
        return true;
    auto* top = static_cast<Inner*>(node());
    if (!top)
        return false;
    uint32_t u = 0, b = 0;
    if (!depth_) {
        const auto* l = static_cast<const Leaf*>(root_);
        u = l->len, b = count_breaks(l->u, l->len);
    } else {
        const auto* k = static_cast<const Inner*>(root_);
        for (uint32_t j = 0; j < k->n; j++)
            u += k->units[j], b += k->nls[j];
    }
    top->n = 2;
    top->units[0] = u, top->nls[0] = b, top->kid[0] = root_;
    top->units[1] = s.units, top->nls[1] = s.nls, top->kid[1] = s.right;
    root_ = top;
    depth_++;
    return true;
}

void Rope::erase_at(void* n, uint32_t depth, size_t at, size_t count) noexcept {
    if (!depth) {
        auto* l = static_cast<Leaf*>(n);
        const uint32_t pos = static_cast<uint32_t>(at), c = static_cast<uint32_t>(count);
        std::memmove(l->u + pos, l->u + pos + c, (l->len - pos - c) * sizeof(char16_t));
        l->len -= c;
        return;
    }
    auto* in = static_cast<Inner*>(n);
    uint32_t i = 0;
    while (i < in->n && at >= in->units[i] && in->units[i])
        at -= in->units[i], i++;
    while (count && i < in->n) {
        const size_t here = std::min<size_t>(count, in->units[i] - at);
        if (at == 0 && here == in->units[i]) {
            free_tree(in->kid[i], depth - 1);
            for (uint32_t j = i; j + 1 < in->n; j++)
                in->units[j] = in->units[j + 1], in->nls[j] = in->nls[j + 1], in->kid[j] = in->kid[j + 1];
            in->n--;
            count -= here;
            continue;
        }
        erase_at(in->kid[i], depth - 1, at, here);
        uint32_t u = 0, b = 0;
        if (depth == 1) {
            const auto* l = static_cast<const Leaf*>(in->kid[i]);
            u = l->len, b = count_breaks(l->u, l->len);
        } else {
            const auto* k = static_cast<const Inner*>(in->kid[i]);
            for (uint32_t j = 0; j < k->n; j++)
                u += k->units[j], b += k->nls[j];
        }
        in->units[i] = u, in->nls[i] = b;
        count -= here;
        at = 0;
        i++;
    }
    for (uint32_t j = i > 1 ? i - 2 : 0; j + 1 < in->n && j <= i; j++) {
        if (depth == 1) {
            auto* a = static_cast<Leaf*>(in->kid[j]);
            auto* c = static_cast<Leaf*>(in->kid[j + 1]);
            if (a->len + c->len > k_leaf * 3 / 4)
                continue;
            std::memcpy(a->u + a->len, c->u, c->len * sizeof(char16_t));
            a->len += c->len;
            in->units[j] += in->units[j + 1], in->nls[j] += in->nls[j + 1];
            pool_.free(c);
        } else {
            auto* a = static_cast<Inner*>(in->kid[j]);
            auto* c = static_cast<Inner*>(in->kid[j + 1]);
            if (a->n + c->n > k_fan * 3 / 4)
                continue;
            for (uint32_t k = 0; k < c->n; k++)
                a->units[a->n + k] = c->units[k], a->nls[a->n + k] = c->nls[k], a->kid[a->n + k] = c->kid[k];
            a->n += c->n;
            in->units[j] += in->units[j + 1], in->nls[j] += in->nls[j + 1];
            pool_.free(c);
        }
        for (uint32_t k = j + 1; k + 1 < in->n; k++)
            in->units[k] = in->units[k + 1], in->nls[k] = in->nls[k + 1], in->kid[k] = in->kid[k + 1];
        in->n--;
        j--;
    }
}

std::expected<void, Err> Rope::replace(size_t at, size_t removed, std::u16string_view text) noexcept {
    if (!root_)
        return std::unexpected(Err::out_of_memory);
    if (at > units_ || removed > units_ - at)
        return std::unexpected(Err::out_of_range);
    last_ = nullptr;
    if (removed) {
        size_t gone = 0;
        {
            char16_t buf[512];
            for (size_t p = at, left = removed; left;) {
                const size_t k = read(p, std::min<size_t>(left, 512), buf);
                gone += count_breaks(buf, static_cast<uint32_t>(k));
                p += k, left -= k;
            }
            last_ = nullptr;
        }
        erase_at(root_, depth_, at, removed);
        units_ -= removed;
        breaks_ -= gone;
        while (depth_) {
            auto* in = static_cast<Inner*>(root_);
            if (in->n > 1)
                break;
            if (in->n == 0) {
                pool_.free(in);
                auto* l = static_cast<Leaf*>(node());
                if (!l)
                    return root_ = nullptr, std::unexpected(Err::out_of_memory);
                l->len = 0;
                root_ = l;
                depth_ = 0;
                break;
            }
            root_ = in->kid[0];
            depth_--;
            pool_.free(in);
        }
    }
    for (size_t done = 0; done < text.size();) {
        const size_t n = std::min<size_t>(text.size() - done, k_leaf);
        if (!insert_chunk(at + done, text.substr(done, n)))
            return std::unexpected(Err::out_of_memory);
        done += n;
    }
    return {};
}

std::expected<void, Err> Rope::append_utf8(std::string_view bytes) noexcept {
    char16_t buf[k_leaf];
    uint32_t have = 0;
    const auto* p = reinterpret_cast<const uint8_t*>(bytes.data());
    const size_t n = bytes.size();
    auto flush = [&]() -> bool {
        auto r = replace(units_, 0, std::u16string_view(buf, have));
        have = 0;
        return r.has_value();
    };
    for (size_t i = 0; i < n;) {
        if (have + 2 > k_leaf && !flush())
            return std::unexpected(Err::out_of_memory);
        const uint8_t c = p[i];
        if (c < 0x80) {
            if (c == '\r' && i + 1 < n && p[i + 1] == '\n') {
                i++;
                continue;
            }
            buf[have++] = c;
            i++;
            continue;
        }
        const uint32_t len = c >= 0xF0 && c <= 0xF4 ? 4 : c >= 0xE0 && c < 0xF0 ? 3 : c >= 0xC2 && c < 0xE0 ? 2 : 0;
        uint32_t cp = len == 4 ? c & 0x07u : len == 3 ? c & 0x0Fu : c & 0x1Fu;
        bool ok = len != 0 && i + len <= n;
        for (uint32_t k = 1; ok && k < len; k++) {
            const uint8_t b = p[i + k];
            ok = (b & 0xC0) == 0x80;
            cp = cp << 6 | (b & 0x3Fu);
        }
        if (ok
            && ((len == 3 && cp < 0x800) || (len == 4 && (cp < 0x10000 || cp > 0x10FFFF))
                || (cp >= 0xD800 && cp <= 0xDFFF)))
            ok = false;
        if (!ok) {
            buf[have++] = 0xFFFD;
            i++;
            continue;
        }
        if (cp >= 0x10000) {
            cp -= 0x10000;
            buf[have++] = static_cast<char16_t>(0xD800 + (cp >> 10));
            buf[have++] = static_cast<char16_t>(0xDC00 + (cp & 0x3FF));
        } else {
            buf[have++] = static_cast<char16_t>(cp);
        }
        i += len;
    }
    if (have && !flush())
        return std::unexpected(Err::out_of_memory);
    return {};
}

char16_t Rope::at(size_t i) const noexcept {
    if (last_ && i >= last_at_ && i - last_at_ < last_->len)
        return last_->u[i - last_at_];
    const void* n = root_;
    size_t base = 0;
    for (uint32_t d = depth_; d; d--) {
        const auto* in = static_cast<const Inner*>(n);
        uint32_t k = 0;
        while (k + 1 < in->n && i - base >= in->units[k])
            base += in->units[k], k++;
        n = in->kid[k];
    }
    last_ = static_cast<const Leaf*>(n);
    last_at_ = base;
    return i - base < last_->len ? last_->u[i - base] : u'\0';
}

size_t Rope::read(size_t from, size_t n, char16_t* out) const noexcept {
    if (from >= units_)
        return 0;
    n = std::min(n, units_ - from);
    size_t done = 0;
    while (done < n) {
        (void)at(from + done);
        const size_t in = from + done - last_at_;
        const size_t k = std::min<size_t>(last_->len - in, n - done);
        std::memcpy(out + done, last_->u + in, k * sizeof(char16_t));
        done += k;
    }
    return n;
}

size_t Rope::line_of(size_t i) const noexcept {
    if (i >= units_)
        return breaks_;
    size_t line = 0, left = i;
    const void* n = root_;
    for (uint32_t d = depth_; d; d--) {
        const auto* in = static_cast<const Inner*>(n);
        uint32_t k = 0;
        while (k + 1 < in->n && left >= in->units[k])
            left -= in->units[k], line += in->nls[k], k++;
        n = in->kid[k];
    }
    const auto* l = static_cast<const Leaf*>(n);
    return line + count_breaks(l->u, static_cast<uint32_t>(std::min<size_t>(left, l->len)));
}

size_t Rope::line_start(size_t k) const noexcept {
    if (k == 0)
        return 0;
    if (k > breaks_)
        return units_;
    size_t want = k, base = 0;
    const void* n = root_;
    for (uint32_t d = depth_; d; d--) {
        const auto* in = static_cast<const Inner*>(n);
        uint32_t j = 0;
        while (j + 1 < in->n && want > in->nls[j])
            want -= in->nls[j], base += in->units[j], j++;
        n = in->kid[j];
    }
    const auto* l = static_cast<const Leaf*>(n);
    for (uint32_t i = 0; i < l->len; i++)
        if (l->u[i] == u'\n' && --want == 0)
            return base + i + 1;
    return units_;
}

bool Rope::check_node(const void* n, uint32_t depth, uint32_t& units, uint32_t& nls) const noexcept {
    if (!depth) {
        const auto* l = static_cast<const Leaf*>(n);
        if (l->len > k_leaf)
            return false;
        units = l->len, nls = count_breaks(l->u, l->len);
        return true;
    }
    const auto* in = static_cast<const Inner*>(n);
    if (in->n == 0 || in->n > k_fan)
        return false;
    units = 0, nls = 0;
    for (uint32_t i = 0; i < in->n; i++) {
        uint32_t u, b;
        if (!check_node(in->kid[i], depth - 1, u, b) || u != in->units[i] || b != in->nls[i])
            return false;
        units += u, nls += b;
    }
    return true;
}

bool Rope::check() const noexcept {
    if (!root_)
        return false;
    uint32_t u, b;
    return check_node(root_, depth_, u, b) && u == units_ && b == breaks_;
}

}
