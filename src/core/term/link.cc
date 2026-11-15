// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/term/link.h"

#include <string_view>

namespace rx::term {

const Cell* line_cells(const Terminal& t, int line) {
    return line < t.scrollback() ? t.scrollback_row(line) : t.row(line - t.scrollback());
}
bool line_wraps(const Terminal& t, int line) {
    return line < t.scrollback() ? t.scrollback_wrapped(line) : t.wrapped(line - t.scrollback());
}

LinkSpan hyperlink_at(const Terminal& t, int line, int col) {
    const int total = t.scrollback() + t.rows(), cols = t.cols();
    if (line < 0 || line >= total || col < 0 || col >= cols)
        return {};
    if (line_cells(t, line)[col].width == 0 && col > 0)
        col--;
    const uint16_t id = line_cells(t, line)[col].link;
    if (!id)
        return {};
    int l0 = line, c0 = col, l1 = line, c1 = col;
    for (int n = 0; n < 50;) {
        if (c0 > 0 && line_cells(t, l0)[c0 - 1].link == id)
            c0--;
        else if (c0 == 0 && l0 > 0 && line_cells(t, l0 - 1)[cols - 1].link == id)
            l0--, c0 = cols - 1, n++;
        else
            break;
    }
    for (int n = 0; n < 50;) {
        if (c1 < cols - 1 && line_cells(t, l1)[c1 + 1].link == id)
            c1++;
        else if (c1 == cols - 1 && l1 + 1 < total && line_cells(t, l1 + 1)[0].link == id)
            l1++, c1 = 0, n++;
        else
            break;
    }
    return LinkSpan{true, l0, c0, l1, c1};
}

namespace {

bool url_char(char32_t c) {
    if (c >= 0x80)
        return c != 0x00A0 && !(c >= 0x2500 && c < 0x2600);
    return c > 0x20 && c < 0x7F && c != '<' && c != '>' && c != '"' && c != '\'' && c != '`' && c != '{' && c != '}'
        && c != '|' && c != '\\' && c != '^';
}
bool alnum(char32_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');
}
char32_t lower(char32_t c) {
    return c >= 'A' && c <= 'Z' ? c + 32 : c;
}

constexpr std::string_view kSchemes[] = {"https://", "http://", "file://", "ftp://",
                                         "sftp://",  "ssh://",  "git://",  "mailto:"};

struct Logical {
    const Terminal& t;
    int first, cols, n;
    const Cell& at(int p) const { return line_cells(t, first + p / cols)[p % cols]; }
    bool spacer(int p) const { return at(p).width == 0; }
    char32_t ch(int p) const { return at(p).comb[0] ? char32_t(U' ') : at(p).cp; }
    bool urlish(int p) const { return spacer(p) || url_char(ch(p)); }
};

bool put_utf8(std::span<char> out, size_t* at, char32_t c) {
    char b[4];
    size_t k = 0;
    if (c < 0x80)
        b[k++] = char(c);
    else if (c < 0x800)
        b[k++] = char(0xC0 | (c >> 6)), b[k++] = char(0x80 | (c & 0x3F));
    else if (c < 0x10000)
        b[k++] = char(0xE0 | (c >> 12)), b[k++] = char(0x80 | ((c >> 6) & 0x3F)), b[k++] = char(0x80 | (c & 0x3F));
    else
        b[k++] = char(0xF0 | (c >> 18)), b[k++] = char(0x80 | ((c >> 12) & 0x3F)),
        b[k++] = char(0x80 | ((c >> 6) & 0x3F)), b[k++] = char(0x80 | (c & 0x3F));
    if (*at + k > out.size())
        return false;
    for (size_t i = 0; i < k; i++)
        out[*at + i] = b[i];
    *at += k;
    return true;
}

}

LinkSpan url_at(const Terminal& t, int line, int col, std::span<char> uri, size_t* len) {
    *len = 0;
    const int total = t.scrollback() + t.rows(), cols = t.cols();
    if (line < 0 || line >= total || col < 0 || col >= cols)
        return {};
    int first = line, last = line;
    while (first > 0 && line - first < 20 && line_wraps(t, first - 1))
        first--;
    while (last + 1 < total && last - line < 20 && line_wraps(t, last))
        last++;
    const Logical L{t, first, cols, (last - first + 1) * cols};
    int here = (line - first) * cols + col;
    if (L.spacer(here) && here > 0)
        here--;
    if (L.spacer(here) || !url_char(L.ch(here)))
        return {};
    int a = here, b = here;
    while (a > 0 && L.urlish(a - 1))
        a--;
    while (b + 1 < L.n && L.urlish(b + 1))
        b++;
    for (int i = a; i <= here; i++) {
        if (L.spacer(i))
            continue;
        if (i > a) {
            int p = i - 1;
            while (p > a && L.spacer(p))
                p--;
            if (alnum(L.ch(p)))
                continue;
        }
        int len_s = 0;
        for (std::string_view w : kSchemes) {
            if (i + int(w.size()) > b + 1)
                continue;
            bool same = true;
            for (size_t k = 0; k < w.size() && same; k++)
                same = lower(L.ch(i + int(k))) == char32_t(w[k]);
            if (same) {
                len_s = int(w.size());
                break;
            }
        }
        if (!len_s)
            continue;
        int e = b;
        while (e >= i + len_s && !L.spacer(e)) {
            const char32_t c = L.ch(e);
            if (c == '.' || c == ',' || c == ':' || c == ';' || c == '!' || c == '?') {
                e--;
                continue;
            }
            if (c == ')' || c == ']') {
                const char32_t open = c == ')' ? U'(' : U'[';
                int depth = 0;
                for (int k = i; k <= e; k++)
                    depth += L.ch(k) == open ? 1 : L.ch(k) == c ? -1 : 0;
                if (depth < 0) {
                    e--;
                    continue;
                }
            }
            break;
        }
        if (e < i + len_s || here > e)
            continue;
        size_t at = 0;
        for (int k = i; k <= e; k++)
            if (!L.spacer(k) && !put_utf8(uri, &at, L.ch(k)))
                return {};
        if (e + 1 < L.n && L.spacer(e + 1))
            e++;
        *len = at;
        return LinkSpan{true, first + i / cols, i % cols, first + e / cols, e % cols};
    }
    return {};
}

}
