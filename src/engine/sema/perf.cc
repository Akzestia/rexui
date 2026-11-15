// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/sema/perf.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>

namespace rx::engine::sema {
namespace {

using sv = std::string_view;

struct Walk {
    sv path, name, src;
    Arena& arena;
    List<Diagnostic> out{};

    const rui::Member* prop(const rui::Element* e, sv n) const {
        for (const auto& m : e->props)
            if (m.name == n && m.has_value)
                return &m;
        return nullptr;
    }
    const rui::Member* handler(const rui::Element* e, sv n) const {
        for (const auto& m : e->handlers)
            if (m.name == n)
                return &m;
        return nullptr;
    }
    static bool is_true(const rui::Member* m) { return m && m->value == "true"; }
    static long number(const rui::Member* m) {
        if (!m || m->value.empty() || m->value.size() > 9)
            return -1;
        long v = 0;
        for (char c : m->value) {
            if (c < '0' || c > '9')
                return -1;
            v = v * 10 + (c - '0');
        }
        return v;
    }
    void warn(const rui::Element* e, uint32_t line, uint32_t pos, const char* f, ...)
        __attribute__((format(printf, 5, 6))) {
        char buf[512];
        va_list ap;
        va_start(ap, f);
        int n = std::vsnprintf(buf, sizeof buf, f, ap);
        va_end(ap);
        (void)e;
        Diagnostic d{};
        d.severity = Severity::warning;
        d.perf = true;
        d.file = name, d.path = path, d.line = line, d.pos = pos;
        d.msg = arena.copy({buf,
                            n < 0                                     ? 0
                                : static_cast<size_t>(n) < sizeof buf ? static_cast<size_t>(n)
                                                                      : sizeof buf - 1});
        (void)out.push(arena, d);
    }

    static uint32_t count(const rui::Element* e, bool& loader, uint32_t depth = 0) {
        if (!e || depth > rui::k_max_depth)
            return 0;
        if (e->type == "Loader")
            loader = true;
        uint32_t n = 1;
        for (const rui::Element* c : e->children)
            n += count(c, loader, depth + 1);
        for (const auto& o : e->objects)
            n += count(o.node, loader, depth + 1);
        return n;
    }

    void element(const rui::Element* e, uint32_t depth) {
        if (!e || depth > rui::k_max_depth)
            return;
        if (e->type == "Timer") {
            const rui::Member *iv = prop(e, "interval"), *tr = handler(e, "onTriggered");
            const long ms = number(iv);
            if ((ms == 1000 || ms == 60000) && !is_true(prop(e, "aligned")) && tr && tr->value.find("Date") != sv::npos)
                warn(e, iv->line, iv->value_pos,
                     "a clock's Timer (interval %ld, its handler reads the date) runs from when it started and skips a "
                     "%s now "
                     "and then: aligned: true fires on the wall clock",
                     ms, ms == 1000 ? "second" : "minute");
        }
        if (e->type == "List" || e->type == "Repeater" || e->type == "Grid") {
            const rui::Member* m = prop(e, "model");
            const long rows = number(m);
            const bool virt = e->type == "List" && is_true(prop(e, "virtualized"));
            if (rows >= static_cast<long>(k_perf_rows) && !virt) {
                if (e->type == "List")
                    warn(e, m->line, m->value_pos,
                         "a List of %ld rows makes every one at load: virtualized: true (with rowHeight) makes only "
                         "what shows",
                         rows);
                else
                    warn(e, m->line, m->value_pos,
                         "a %.*s of %ld makes every one at load: a List with virtualized: true makes only what shows",
                         static_cast<int>(e->type.size()), e->type.data(), rows);
            }
        }
        if (e->type == "Shader") {
            const rui::Member *run = prop(e, "running"), *fps = prop(e, "fps");
            const long f = fps ? number(fps) : 60;
            if ((!run || is_true(run)) && !prop(e, "visible") && f > k_perf_shader_fps)
                warn(e, run ? run->line : e->line, run ? run->value_pos : e->pos,
                     "a Shader running at %ld fps whenever it's shown: bind running (or visible) to when it's wanted, "
                     "or a lower fps",
                     f);
        }
        if (e->type == "Drawer" && !is_true(prop(e, "lazy"))) {
            bool loader = false;
            const uint32_t n = count(e, loader) - 1;
            if (n >= k_perf_drawer && !loader)
                warn(e, e->line, e->pos,
                     "a Drawer of %u elements made at load, closed: lazy: true makes them at its first open", n);
        }
        for (const rui::Element* c : e->children)
            element(c, depth + 1);
        for (const auto& o : e->objects)
            element(o.node, depth + 1);
    }
};

}

List<Diagnostic> perf(const rui::File& file, std::string_view path, std::string_view name, Arena& arena) noexcept {
    Walk w{path, name, file.src, arena};
    w.element(file.root, 0);
    return w.out;
}

}
