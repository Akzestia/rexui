// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdio>

namespace rx::engine::rui {

template<class Out>
void json_string(std::string_view s, Out& out) {
    out.append("\"", 1);
    size_t run = 0;
    for (size_t i = 0; i < s.size(); i++) {
        unsigned char c = static_cast<unsigned char>(s[i]);
        const char* esc = nullptr;
        char buf[8];
        if (c == '"')
            esc = "\\\"";
        else if (c == '\\')
            esc = "\\\\";
        else if (c == '\b')
            esc = "\\b";
        else if (c == '\f')
            esc = "\\f";
        else if (c == '\n')
            esc = "\\n";
        else if (c == '\r')
            esc = "\\r";
        else if (c == '\t')
            esc = "\\t";
        else if (c < 0x20) {
            std::snprintf(buf, sizeof buf, "\\u%04x", c);
            esc = buf;
        }
        if (!esc)
            continue;
        out.append(s.data() + run, i - run);
        out.append(esc, __builtin_strlen(esc));
        run = i + 1;
    }
    out.append(s.data() + run, s.size() - run);
    out.append("\"", 1);
}

namespace detail {
template<class Out>
void lit(Out& out, const char* s) {
    out.append(s, __builtin_strlen(s));
}
template<class Out>
void num(Out& out, uint32_t v) {
    char b[16];
    int n = std::snprintf(b, sizeof b, "%u", v);
    out.append(b, static_cast<size_t>(n));
}
template<class Out>
void element(const Element& e, Out& out, const File* top);
template<class Out>
void members(const List<Member>& l, const char* value, Out& out, bool nullable) {
    lit(out, "[");
    for (uint32_t k = 0; k < l.size; k++) {
        const Member& m = l[k];
        lit(out, k ? ",{\"name\":" : "{\"name\":");
        json_string(m.name, out);
        lit(out, ",\"");
        lit(out, value);
        lit(out, "\":");
        if (nullable && !m.has_value)
            lit(out, "null");
        else
            json_string(m.value, out);
        lit(out, ",\"line\":");
        num(out, m.line);
        lit(out, "}");
    }
    lit(out, "]");
}
template<class Out>
void element(const Element& e, Out& out, const File* top) {
    lit(out, "{\"type\":");
    json_string(e.type, out);
    lit(out, ",\"line\":");
    num(out, e.line);
    lit(out, ",\"id\":");
    if (e.has_id)
        json_string(e.id, out);
    else
        lit(out, "null");
    lit(out, ",\"props\":");
    members(e.props, "expr", out, false);
    lit(out, ",\"handlers\":");
    members(e.handlers, "body", out, false);
    lit(out, ",\"children\":[");
    for (uint32_t k = 0; k < e.children.size; k++) {
        if (k)
            lit(out, ",");
        element(*e.children[k], out, nullptr);
    }
    lit(out, "],\"custom\":");
    members(e.custom, "expr", out, true);
    lit(out, ",\"functions\":[");
    for (uint32_t k = 0; k < e.functions.size; k++) {
        const Function& f = e.functions[k];
        lit(out, k ? ",{\"name\":" : "{\"name\":");
        json_string(f.name, out);
        lit(out, ",\"params\":");
        json_string(f.params, out);
        lit(out, ",\"body\":");
        json_string(f.body, out);
        lit(out, ",\"line\":");
        num(out, f.line);
        lit(out, "}");
    }
    lit(out, "],\"objects\":[");
    for (uint32_t k = 0; k < e.objects.size; k++) {
        const Object& o = e.objects[k];
        lit(out, k ? ",{\"name\":" : "{\"name\":");
        json_string(o.name, out);
        lit(out, ",\"node\":");
        element(*o.node, out, nullptr);
        lit(out, ",\"line\":");
        num(out, o.line);
        lit(out, "}");
    }
    lit(out, "]");
    if (top) {
        lit(out, ",\"uses\":[");
        for (uint32_t k = 0; k < top->uses.size; k++) {
            const Use& u = top->uses[k];
            lit(out, k ? ",{\"path\":" : "{\"path\":");
            json_string(u.path, out);
            lit(out, ",\"as\":");
            if (u.has_as)
                json_string(u.as, out);
            else
                lit(out, "null");
            lit(out, ",\"line\":");
            num(out, u.line);
            lit(out, "}");
        }
        lit(out, "]");
    }
    lit(out, "}");
}
}

template<class Out>
void dump(const File& f, Out& out) {
    detail::element(*f.root, out, &f);
}

}
