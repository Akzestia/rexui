// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "tools/mcp/context.hpp"

#include <format>
#include <string>
#include <vector>

namespace rexui::mcp {

namespace {

[[nodiscard]] auto text_of(const Json& j, std::string_view key) -> std::string {
    if (!j.is_object() || !j.contains(key))
        return {};
    const Json& v = j.at(key);
    if (v.is_string())
        return v.get<std::string>();
    if (v.is_null())
        return {};
    return v.dump();
}

[[nodiscard]] auto number_of(const Json& j, std::string_view key) -> double {
    if (!j.is_object() || !j.contains(key) || !j.at(key).is_number())
        return 0;
    return j.at(key).get<double>();
}

[[nodiscard]] auto label_of(const Json& row) -> std::string {
    std::string comp = text_of(row, "comp"), id = text_of(row, "id");
    std::string out = comp.empty() ? text_of(row, "type") : comp;
    if (!id.empty())
        out += "#" + id;
    return out;
}

}

auto basename_of(std::string_view path) -> std::string_view {
    const auto slash = path.rfind('/');
    return slash == std::string_view::npos ? path : path.substr(slash + 1);
}

auto dirname_of(std::string_view path) -> std::string_view {
    const auto slash = path.rfind('/');
    return slash == std::string_view::npos ? std::string_view{} : path.substr(0, slash);
}

auto element_context(const Json& info, const Json& rows, std::string_view doc_path, long uid, std::string_view readme,
                     std::string_view request) -> std::string {
    if (!info.is_object())
        return {};
    std::vector<std::string> lines;
    lines.push_back(
        std::format("Change this element of a rexui dock (a .rui file: QML-style; it hot-reloads when "
                    "saved{}).",
                    readme.empty() ? std::string{} : std::format("; {} documents every element and property", readme)));

    const std::string type = text_of(info, "type"), comp = text_of(info, "comp"), id = text_of(info, "id");
    lines.push_back(std::format("Element: {}{}", comp.empty() ? type : std::format("{} (a {})", comp, type),
                                id.empty() ? std::string{} : " #" + id));

    const std::string file = text_of(info, "file");
    const std::string written = file.empty() || file == basename_of(doc_path)
        ? std::string{doc_path}
        : std::format("{}/{}", dirname_of(doc_path), file);
    lines.push_back(std::format("Written at: {}:{}{}", written, static_cast<long>(number_of(info, "line")),
                                written == doc_path ? std::string{} : std::format("  (used in {})", doc_path)));

    if (rows.is_array()) {
        std::size_t at = rows.size();
        for (std::size_t i = 0; i < rows.size(); ++i) {
            if (rows[i].is_object() && rows[i].value("uid", -1L) == uid) {
                at = i;
                break;
            }
        }
        if (at < rows.size()) {
            std::vector<std::string> chain;
            long depth = rows[at].value("depth", 0L);
            for (std::size_t j = at; j-- > 0 && depth > 0;) {
                const long d = rows[j].value("depth", 0L);
                if (d < depth) {
                    chain.insert(chain.begin(), label_of(rows[j]));
                    depth = d;
                }
            }
            if (!chain.empty()) {
                std::string joined;
                for (const auto& c : chain)
                    joined += (joined.empty() ? "" : " > ") + c;
                lines.push_back("Inside: " + joined);
            }
        }
    }

    if (info.contains("frame") && info["frame"].is_object()) {
        const Json& f = info["frame"];
        lines.push_back(std::format("Frame: x {}, y {}, {}×{} pt", number_of(f, "x"), number_of(f, "y"),
                                    number_of(f, "width"), number_of(f, "height")));
    }

    if (info.contains("props") && info["props"].is_array()) {
        std::string props;
        for (const Json& p : info["props"]) {
            if (!p.is_object() || p.value("isDefault", false))
                continue;
            props += std::format("\n  {}: {}", text_of(p, "name"), text_of(p, "value"));
            if (const std::string binding = text_of(p, "binding"); !binding.empty())
                props += "   (bound: " + binding + ")";
        }
        if (!props.empty())
            lines.push_back("Properties set:" + props);
    }

    if (info.contains("handlers") && info["handlers"].is_array() && !info["handlers"].empty()) {
        std::string handlers;
        for (const Json& h : info["handlers"])
            handlers += (handlers.empty() ? "" : ", ") + (h.is_string() ? h.get<std::string>() : h.dump());
        lines.push_back("Handlers: " + handlers);
    }

    if (!request.empty())
        lines.push_back(std::format("\nRequest: {}", request));

    std::string out;
    for (const auto& l : lines)
        out += (out.empty() ? "" : "\n") + l;
    return out;
}

auto format_tree(const Json& rows, std::size_t max_rows) -> std::string {
    if (!rows.is_array())
        return {};
    std::string out;
    std::size_t shown = 0;
    for (const Json& r : rows) {
        if (shown == max_rows) {
            out += std::format("… {} more rows (max_rows)\n", rows.size() - shown);
            break;
        }
        if (!r.is_object())
            continue;
        const long depth = r.value("depth", 0L);
        out += std::string(static_cast<std::size_t>(depth > 0 ? depth : 0) * 2, ' ');
        out += label_of(r);
        if (const std::string comp = text_of(r, "comp"); !comp.empty())
            out += " (" + text_of(r, "type") + ")";
        const double w = number_of(r, "width"), h = number_of(r, "height");
        if (w > 0 || h > 0)
            out += std::format("  {}×{}", w, h);
        if (!r.value("visible", true))
            out += "  hidden";
        out += std::format("  uid={}  {}:{}\n", r.value("uid", 0L), text_of(r, "file"), r.value("line", 0L));
        ++shown;
    }
    return out;
}

}
