// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "tools/mcp/tools.hpp"

#include <chrono>
#include <ctime>
#include <format>
#include <string>
#include <thread>

#include "tools/mcp/context.hpp"

namespace rexui::mcp {

const std::string_view kInstructions =
    "rexui: the owner's docks for the Rex terminal, written as .rui files (QML-style: elements, properties, bindings; "
    "a "
    "file hot-reloads when saved). These tools see what rexui's dev tools see in the running Rex UI.\n"
    "When the user says \"this element\", \"the selected element\" or \"what I picked\", call selected_element: it is "
    "the "
    "element they chose in the dev tools (Elements, or picked with the mouse), with its file, line, ancestors, "
    "properties "
    "and bindings. Change it by editing its .rui file (the change shows at once); set_property only tries a value live "
    "and is lost on the next reload. element_tree and inspect_element find others; read_console shows errors after an "
    "edit; show_element selects one in the dev tools for the user to see.\n"
    "Requests sent from the dev tools' Ask arrive as <channel source=\"rexui\" ...> events, the element's context "
    "first, "
    "then the request: act on them as if the user had typed them.";

namespace {

[[nodiscard]] auto schema(Json properties, Json required = Json::array()) -> Json {
    return Json{{"type", "object"}, {"properties", std::move(properties)}, {"required", std::move(required)}};
}

[[nodiscard]] auto str(const Json& args, std::string_view key) -> std::string {
    return args.contains(key) && args.at(key).is_string() ? args.at(key).get<std::string>() : std::string{};
}

[[nodiscard]] auto uid_of(const Json& args) -> long {
    if (!args.contains("uid"))
        return 0;
    const Json& u = args.at("uid");
    if (u.is_number())
        return u.get<long>();
    if (u.is_string())
        return std::atol(u.get<std::string>().c_str());
    return 0;
}

[[nodiscard]] auto hhmmss(double ms) -> std::string {
    const std::time_t t = static_cast<std::time_t>(ms / 1000);
    std::tm tm{};
    localtime_r(&t, &tm);
    return std::format("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec);
}

}

auto make_tools(Link& link) -> std::vector<Tool> {
    std::vector<Tool> tools;

    tools.push_back(Tool{
        .name = "selected_element",
        .description =
            "The element the user selected in rexui's dev tools (Elements, or picked with the mouse): what it "
            "is, its file and line, its ancestors, frame, properties set with their bindings, its handlers. "
            "Call it whenever the user refers to \"this\" or \"the selected\" element.",
        .input_schema = schema(Json::object()),
        .run = [&link](const Json&) -> std::expected<std::string, std::string> {
            const auto state = link.call("state", nullptr);
            if (!state)
                return std::unexpected{state.error()};
            const Json sel = state->value("selected", Json{});
            if (!sel.is_object() || !sel.contains("file")) {
                return std::unexpected{
                    std::string{"Nothing is selected in rexui's dev tools: ask the user to pick an element "
                                "(debug mode, cmd+alt+i; then the scope in Elements, and a click), or find "
                                "one with list_files and element_tree."}};
            }
            const std::string file = sel.value("file", std::string{});
            const long uid = sel.value("uid", 0L);
            const auto info = link.call("inspect", {{"file", file}, {"uid", uid}});
            if (!info)
                return std::unexpected{info.error()};
            const auto rows = link.call("tree", file);
            const std::string repo = state->value("repo", std::string{});
            return element_context(*info, rows ? *rows : Json::array(), file, uid,
                                   repo.empty() ? "" : repo + "/README.md", "")
                + std::format("\n\n(file {} uid {}: for inspect_element, set_property, show_element)", file, uid);
        },
    });

    tools.push_back(Tool{
        .name = "list_files",
        .description = "Every .rui file Rex UI has loaded: its type and side, element count, path, any load error, and "
                       "whether it's the dev tools' own or shown in a pane.",
        .input_schema = schema(Json::object()),
        .run = [&link](const Json&) -> std::expected<std::string, std::string> {
            const auto state = link.call("state", nullptr);
            if (!state)
                return std::unexpected{state.error()};
            std::string out;
            for (const Json& d : state->value("docs", Json::array())) {
                out += std::format(
                    "{}  {}{}  {} elements{}{}  {}{}\n", d.value("file", ""), d.value("type", ""),
                    d.value("side", std::string{}).empty() ? "" : " · " + d.value("side", std::string{}),
                    d.value("nodes", 0), d.value("devtools", false) ? "  (dev tools)" : "",
                    d.value("pane", false) ? "  (in a pane)" : "", d.value("path", ""),
                    d.value("error", std::string{}).empty() ? "" : "\n    error: " + d.value("error", std::string{}));
            }
            return out.empty() ? std::string{"No files loaded."} : out;
        },
    });

    tools.push_back(Tool{
        .name = "element_tree",
        .description =
            "A file's elements as an indented outline: type, #id, component, size, uid (for inspect_element), "
            "where each is written.",
        .input_schema = schema({{"file", {{"type", "string"}, {"description", "a path or file name from list_files"}}},
                                {"max_rows", {{"type", "integer"}, {"description", "at most this many rows (300)"}}}},
                               Json::array({"file"})),
        .run = [&link](const Json& args) -> std::expected<std::string, std::string> {
            const auto rows = link.call("tree", str(args, "file"));
            if (!rows)
                return std::unexpected{rows.error()};
            if (!rows->is_array() || rows->empty())
                return std::unexpected{std::string{"no such file, or nothing in it"}};
            const long max =
                args.contains("max_rows") && args["max_rows"].is_number() ? args["max_rows"].get<long>() : 300;
            return format_tree(*rows, static_cast<std::size_t>(max > 0 ? max : 300));
        },
    });

    tools.push_back(Tool{
        .name = "inspect_element",
        .description =
            "One element in full: its properties (value, binding, whether set), handlers, frame, and what draws "
            "it, as JSON.",
        .input_schema =
            schema({{"file", {{"type", "string"}}}, {"uid", {{"type", "integer"}}}}, Json::array({"file", "uid"})),
        .run = [&link](const Json& args) -> std::expected<std::string, std::string> {
            const auto info = link.call("inspect", {{"file", str(args, "file")}, {"uid", uid_of(args)}});
            if (!info)
                return std::unexpected{info.error()};
            if (info->is_null())
                return std::unexpected{std::string{"no such element"}};
            return info->dump(1);
        },
    });

    tools.push_back(Tool{
        .name = "set_property",
        .description = "Set a property of an element live, to try a value (JSON when it reads as JSON, else text); its "
                       "binding goes. Not saved: the next reload undoes it. Edit the .rui file to keep a change.",
        .input_schema = schema({{"file", {{"type", "string"}}},
                                {"uid", {{"type", "integer"}}},
                                {"name", {{"type", "string"}}},
                                {"value", {{"type", "string"}}}},
                               Json::array({"file", "uid", "name", "value"})),
        .run = [&link](const Json& args) -> std::expected<std::string, std::string> {
            const auto r = link.call(
                "edit",
                {{"file", str(args, "file")},
                 {"uid", uid_of(args)},
                 {"name", str(args, "name")},
                 {"value",
                  args.contains("value") && !args["value"].is_string() ? args["value"].dump() : str(args, "value")}});
            if (!r)
                return std::unexpected{r.error()};
            if (r->is_string() && !r->get<std::string>().empty())
                return std::unexpected{r->get<std::string>()};
            return std::string{"set (live only)"};
        },
    });

    tools.push_back(Tool{
        .name = "eval_in_file",
        .description =
            "Run JavaScript in a .rui file's scope (its ids, its top element's properties): an expression, or "
            "statements with return. Shows in the dev tools' console too.",
        .input_schema =
            schema({{"file", {{"type", "string"}}}, {"code", {{"type", "string"}}}}, Json::array({"file", "code"})),
        .run = [&link](const Json& args) -> std::expected<std::string, std::string> {
            const auto r = link.call("eval", {{"file", str(args, "file")}, {"code", str(args, "code")}});
            if (!r)
                return std::unexpected{r.error()};
            const std::string text = r->value("text", std::string{});
            if (!r->value("ok", false))
                return std::unexpected{text.empty() ? std::string{"failed"} : text};
            return text;
        },
    });

    tools.push_back(Tool{
        .name = "read_console",
        .description =
            "The dev tools' console: every file's console.log/warn/error, exceptions and rexui's log, newest "
            "last. Read it after an edit to see load errors.",
        .input_schema =
            schema({{"lines", {{"type", "integer"}, {"description", "how many (80, at most 500)"}}},
                    {"level", {{"type", "string"}, {"description", "only this level: error, warn, log, info"}}}}),
        .run = [&link](const Json& args) -> std::expected<std::string, std::string> {
            const long lines = args.contains("lines") && args["lines"].is_number() ? args["lines"].get<long>() : 80;
            const auto r = link.call("console", {{"lines", lines}});
            if (!r)
                return std::unexpected{r.error()};
            const std::string level = str(args, "level");
            std::string out;
            for (const Json& l : r->is_array() ? *r : Json::array()) {
                if (!level.empty() && l.value("level", "") != level)
                    continue;
                out += std::format("{} {:6} {}: {}\n", hhmmss(l.value("t", 0.0)), l.value("level", ""),
                                   l.value("file", std::string{}).empty() ? "rexui" : l.value("file", ""),
                                   l.value("text", ""));
            }
            return out.empty() ? std::string{"(nothing)"} : out;
        },
    });

    tools.push_back(Tool{
        .name = "performance",
        .description = "What Rex and each .rui file cost over the next second: Rex UI's CPU, memory and threads, Rex "
                       "Server's, every file's JavaScript ms/s, calls and bindings run, and its backends.",
        .input_schema = schema(Json::object()),
        .run = [&link](const Json&) -> std::expected<std::string, std::string> {
            if (const auto first = link.call("perf", nullptr); !first)
                return std::unexpected{first.error()};
            std::this_thread::sleep_for(std::chrono::seconds{1});
            const auto p = link.call("perf", nullptr);
            if (!p)
                return std::unexpected{p.error()};
            const Json rex = p->value("rex", Json::object());
            std::string out =
                std::format("Rex UI: CPU {}% of one core, {} MB, {} threads ({} running), JavaScript {} ms/s\n",
                            rex.value("cpu", 0.0), rex.value("mem", 0.0), rex.value("threads", 0),
                            rex.value("running", 0), rex.value("js", 0.0));
            for (const Json& s : p->value("server", Json::array())) {
                out += std::format("Rex Server ({}): CPU {}%, {} MB, {} threads, {} children, up since {}\n",
                                   s.value("role", ""), s.value("cpu", 0.0), s.value("mem", 0.0), s.value("threads", 0),
                                   s.value("children", 0), s.value("started", 0L));
            }
            out += "Files (JavaScript ms/s, calls/s, bindings/s, elements):\n";
            for (const Json& d : p->value("docs", Json::array())) {
                out += std::format("  {:32} {:7} {:6} {:7} {:6}", d.value("file", ""), d.value("ms", 0.0),
                                   d.value("calls", 0), d.value("evals", 0), d.value("nodes", 0));
                for (const Json& b : d.value("backends", Json::array())) {
                    out +=
                        std::format("  [{} {}% {} MB]", b.value("name", ""), b.value("cpu", 0.0), b.value("mem", 0.0));
                }
                out += "\n";
            }
            const Json lg = p->value("long", Json::object());
            const Json turns = lg.value("turns", Json::object());
            out += std::format("Main's turns: {}, worst {} ms; {} of 4 ms or more, {} of 10, {} of 25\n",
                               turns.value("count", 0), turns.value("worst_ms", 0.0), turns.value("over4", 0),
                               turns.value("over10", 0), turns.value("over25", 0));
            for (const Json& n : lg.value("long", Json::array())) {
                out += std::format("  {:10} {:24} {:5} over 4 ms, {:5} over 10, {:5} over 25, worst {} ms\n",
                                   n.value("cat", ""), n.value("name", ""), n.value("over4", 0), n.value("over10", 0),
                                   n.value("over25", 0), n.value("max_ms", 0.0));
            }
            int shown = 0;
            for (const Json& e : lg.value("recent", Json::array())) {
                if (shown++ == 8)
                    break;
                out +=
                    std::format("  {} ms {} {} ({}{}{})\n", e.value("ms", 0.0), e.value("cat", ""), e.value("name", ""),
                                e.value("thread", ""), e.value("file", "").empty() ? "" : ", ", e.value("file", ""));
            }
            return out;
        },
    });

    tools.push_back(Tool{
        .name = "show_element",
        .description =
            "Select an element in rexui's dev tools, so the user sees it in Elements (its properties) and where "
            "it is on screen.",
        .input_schema =
            schema({{"file", {{"type", "string"}}}, {"uid", {{"type", "integer"}}}}, Json::array({"file", "uid"})),
        .run = [&link](const Json& args) -> std::expected<std::string, std::string> {
            const Json ref{{"file", str(args, "file")}, {"uid", uid_of(args)}};
            if (const auto r = link.call("select", ref); !r)
                return std::unexpected{r.error()};
            (void)link.call("highlight", ref);
            return std::string{"shown"};
        },
    });

    return tools;
}

}
