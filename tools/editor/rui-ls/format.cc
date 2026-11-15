// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <cstring>
#include <regex>

#include "engine/base/arena.h"
#include "engine/syntax/rui.h"
#include "ls.h"

namespace rui_ls {

namespace {

struct Indent {
    int orig = 0, indent = 0;
};
struct Mode {
    bool tmpl = false;
    char ch = 0;
    bool element = false;
    int orig = 0, indent = 0;
    bool value = false;
    long value_start = -1;
    bool has_member = false;
    Indent member;
    bool cont = false;
    bool has_first = false;
    Indent first;
};

bool ws(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

std::vector<std::string> split_lines(const std::string& t) {
    std::vector<std::string> out;
    size_t a = 0;
    for (;;) {
        size_t nl = t.find('\n', a);
        out.push_back(t.substr(a, nl == std::string::npos ? std::string::npos : nl - a));
        if (nl == std::string::npos)
            break;
        a = nl + 1;
    }
    return out;
}

}

std::string format(const std::string& text, const J& options) {
    int width = std::max(1, options["tabSize"].truthy() ? static_cast<int>(options["tabSize"].num()) : 4);
    bool tabs = options["insertSpaces"] == false;
    std::string unit = tabs ? "\t" : std::string(static_cast<size_t>(width), ' ');
    auto pad = [&](int w) {
        return tabs
            ? std::string(static_cast<size_t>(w / width), '\t') + std::string(static_cast<size_t>(w % width), ' ')
            : std::string(static_cast<size_t>(w), ' ');
    };
    auto columns = [&](const std::string& s) {
        int w = 0;
        for (char c : s)
            w = c == '\t' ? w - (w % width) + width : w + 1;
        return w;
    };
    int unitW = columns(unit);
    auto closer = [](char c) -> char { return c == ')' ? '(' : c == ']' ? '[' : c == '}' ? '{' : 0; };

    std::vector<std::string> lines = split_lines(text), out;
    std::vector<Mode> modes;
    bool comment = false;
    char quote = 0;
    size_t offset = 0;
    auto top = [&]() -> Mode* { return modes.empty() ? nullptr : &modes.back(); };
    auto element_level = [&] {
        Mode* m = top();
        return !m || (!m->tmpl && m->element);
    };
    auto at = [&](size_t k) { return k < text.size() ? text[k] : '\0'; };
    auto continues = [&](size_t start, size_t i) {
        size_t b = i;
        while (b > start && ws(text[b - 1]))
            b--;
        if (b > start && std::strchr("+-*/%&|^!~?:=<>,.", text[b - 1]))
            return true;
        size_t j = i + 1;
        while (j < text.size() && ws(text[j]))
            j++;
        if (at(j) == '/' && (at(j + 1) == '/' || at(j + 1) == '*'))
            return false;
        return j < text.size() && std::strchr("?:.+-*/&|=<>", text[j]) && text[j];
    };
    static const std::regex key_colon(
        R"(^((?:readonly\s+)?(?:property\s+(?:[A-Za-z_$][\w$]*\s+)?)?[A-Za-z_$][\w$.]*)\s*:(?!:)\s*(?=\S))");
    static const std::regex element_open(R"((^|[^\w$.])[A-Z][\w$]*\s*$)");

    for (size_t L = 0; L < lines.size(); L++) {
        const std::string& line = lines[L];
        bool verbatim = comment || quote || (top() && top()->tmpl);
        size_t lead = 0;
        while (lead < line.size() && (line[lead] == ' ' || line[lead] == '\t'))
            lead++;
        std::string content = line.substr(lead);
        int orig = columns(line.substr(0, lead));
        int indent = orig;
        std::string shown = line;
        bool blank = true;
        for (char c : content)
            blank = blank && ws(c);
        if (!verbatim && blank) {
            shown = "";
        } else if (!verbatim) {
            size_t k = 0;
            while (k < content.size() && closer(content[k]) && modes.size() > k && !modes[modes.size() - 1 - k].tmpl
                   && modes[modes.size() - 1 - k].ch == closer(content[k]))
                k++;
            Mode* ctx = top();
            auto hang = [&](int from_orig, int from_indent) {
                return orig > from_orig ? orig + from_indent - from_orig : from_indent + unitW;
            };
            if (k > 0)
                indent = modes[modes.size() - k].indent;
            else if (!ctx)
                indent = 0;
            else if (ctx->element)
                indent = ctx->cont ? hang(ctx->member.orig, ctx->member.indent) : ctx->indent + unitW;
            else if (!ctx->has_first)
                indent = hang(ctx->orig, ctx->indent);
            else
                indent =
                    orig >= ctx->first.orig ? orig + ctx->first.indent - ctx->first.orig : hang(ctx->orig, ctx->indent);
            if (ctx && !ctx->element && k == 0 && !ctx->has_first)
                ctx->has_first = true, ctx->first = {orig, indent};
            std::string body = content;
            if (element_level() && k == 0 && !(ctx && ctx->value) && !(ctx && ctx->cont))
                body = std::regex_replace(body, key_colon, "$1: ", std::regex_constants::format_first_only);
            shown = pad(indent) + body;
        }
        if (top() && !top()->tmpl && top()->element)
            top()->cont = false;

        size_t start = offset, end = offset + line.size();
        for (size_t i = start; i < end; i++) {
            char c = text[i];
            if (comment) {
                if (c == '*' && at(i + 1) == '/')
                    comment = false, i++;
                continue;
            }
            if (quote) {
                if (c == '\\')
                    i++;
                else if (c == quote)
                    quote = 0;
                continue;
            }
            Mode* m = top();
            if (m && m->tmpl) {
                if (c == '\\')
                    i++;
                else if (c == '`')
                    modes.pop_back();
                else if (c == '$' && at(i + 1) == '{') {
                    Mode b;
                    b.ch = '{', b.orig = orig, b.indent = indent;
                    modes.push_back(b);
                    i++;
                }
                continue;
            }
            bool at_element = !m || m->element;
            if (c == '/' && at(i + 1) == '/') {
                if (at_element && m)
                    m->value = false;
                break;
            }
            if (c == '/' && at(i + 1) == '*') {
                comment = true;
                i++;
                continue;
            }
            if (c == '"' || c == '\'') {
                size_t j = i + 1;
                while (j < end && text[j] != c)
                    j += text[j] == '\\' ? 2 : 1;
                if (j >= end) {
                    if (end > start && text[end - 1] == '\\')
                        quote = c;
                    i = end;
                } else
                    i = j;
                if (at_element && m && m->value && m->value_start < 0)
                    m->value_start = static_cast<long>(i);
                continue;
            }
            if (c == '`') {
                Mode t;
                t.tmpl = true;
                modes.push_back(t);
                m = modes.size() > 1 ? &modes[modes.size() - 2] : nullptr;
                if (at_element && m && m->value && m->value_start < 0)
                    m->value_start = static_cast<long>(i);
                continue;
            }
            if (at_element && m && m->value && m->value_start < 0 && !ws(c))
                m->value_start = static_cast<long>(i);
            if (c == '(' || c == '[' || c == '{') {
                bool element = c == '{' && at_element && std::regex_search(text.substr(start, i - start), element_open);
                Mode b;
                b.ch = c, b.element = element, b.orig = orig, b.indent = indent;
                modes.push_back(b);
                continue;
            }
            if (c == ')' || c == ']' || c == '}') {
                if (m && !m->tmpl) {
                    Mode closed = modes.back();
                    modes.pop_back();
                    Mode* parent = top();
                    if (closed.element && parent && parent->element)
                        parent->value = false;
                }
                continue;
            }
            if (at_element && m) {
                if (c == ';') {
                    m->value = false;
                    continue;
                }
                if (c == ':' && !m->value) {
                    m->value = true, m->value_start = -1, m->has_member = true, m->member = {orig, indent};
                    continue;
                }
            }
        }
        Mode* m = top();
        if (L + 1 < lines.size() && m && !m->tmpl && m->element && m->value) {
            if (m->value_start < 0 || continues(static_cast<size_t>(m->value_start), end))
                m->cont = true;
            else
                m->value = false;
        }
        bool ends_inside = comment || quote || (top() && top()->tmpl);
        if (!ends_inside)
            while (!shown.empty() && (shown.back() == ' ' || shown.back() == '\t'))
                shown.pop_back();
        out.push_back(shown);
        offset += line.size() + 1;
    }
    while (out.size() > 1 && out.back().empty() && out[out.size() - 2].empty())
        out.pop_back();
    if (!out.back().empty())
        out.push_back("");
    std::string r;
    for (size_t k = 0; k < out.size(); k++)
        r += (k ? "\n" : "") + out[k];
    return r;
}

J format_edits(Doc* d, const J& options, long from, long to) {
    {
        rx::engine::Arena arena;
        if (!rx::engine::rui::parse(d->text, arena))
            return J::array();
    }
    std::vector<std::string> after = split_lines(format(d->text, options)), before = split_lines(d->text);
    J edits = J::array();
    size_t n = std::min(before.size(), after.size());
    auto p = [](size_t line, size_t ch) {
        return J::object(
            {{"line", J(static_cast<unsigned long>(line))}, {"character", J(static_cast<unsigned long>(ch))}});
    };
    for (size_t L = static_cast<size_t>(std::max(0L, from)); L < n && (to < 0 || static_cast<long>(L) <= to); L++)
        if (before[L] != after[L])
            edits.push(J::object({{"range", J::object({{"start", p(L, 0)}, {"end", p(L, u16len(before[L]))}})},
                                  {"newText", J(after[L])}}));
    if (to < 0 && after.size() != before.size()) {
        size_t last = before.size() - 1;
        if (after.size() < before.size()) {
            edits.push(J::object(
                {{"range",
                  J::object({{"start", p(n - 1, u16len(before[n - 1]))}, {"end", p(last, u16len(before[last]))}})},
                 {"newText", J("")}}));
        } else {
            std::string more;
            for (size_t k = before.size(); k < after.size(); k++)
                more += "\n" + after[k];
            edits.push(J::object(
                {{"range",
                  J::object({{"start", p(last, u16len(before[last]))}, {"end", p(last, u16len(before[last]))}})},
                 {"newText", J(more)}}));
        }
    }
    return edits;
}

}
