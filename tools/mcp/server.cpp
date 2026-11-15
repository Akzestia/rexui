// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "tools/mcp/server.hpp"

#include <cstdio>
#include <iostream>
#include <utility>

namespace rexui::mcp {

namespace {

[[nodiscard]] auto error_response(const Json& id, int code, std::string message) -> Json {
    return Json{{"jsonrpc", "2.0"}, {"id", id}, {"error", {{"code", code}, {"message", std::move(message)}}}};
}

[[nodiscard]] auto result_response(const Json& id, Json result) -> Json {
    return Json{{"jsonrpc", "2.0"}, {"id", id}, {"result", std::move(result)}};
}

}

Server::Server(std::vector<Tool> tools, std::string instructions)
    : tools_{std::move(tools)}, instructions_{std::move(instructions)} {
}

auto Server::write(const Json& message) -> void {
    const std::string line = message.dump(-1, ' ', false, Json::error_handler_t::replace);
    const std::scoped_lock lock{write_mutex_};
    std::fwrite(line.data(), 1, line.size(), stdout);
    std::fputc('\n', stdout);
    std::fflush(stdout);
}

auto Server::notify(std::string_view method, Json params) -> void {
    write(Json{{"jsonrpc", "2.0"}, {"method", method}, {"params", std::move(params)}});
}

auto Server::call_tool(const Json& params) -> Json {
    const std::string name = params.value("name", std::string{});
    const Json arguments =
        params.contains("arguments") && params["arguments"].is_object() ? params["arguments"] : Json::object();
    for (const Tool& tool : tools_) {
        if (tool.name != name)
            continue;
        const auto out = tool.run(arguments);
        return Json{{"content", Json::array({{{"type", "text"}, {"text", out ? *out : out.error()}}})},
                    {"isError", !out.has_value()}};
    }
    return Json{{"content", Json::array({{{"type", "text"}, {"text", "no tool " + name}}})}, {"isError", true}};
}

auto Server::handle(const Json& message) -> std::optional<Json> {
    if (!message.is_object() || !message.contains("method") || !message["method"].is_string()) {
        if (message.is_object() && message.contains("id"))
            return error_response(message["id"], -32600, "not a request");
        return std::nullopt;
    }
    const std::string method = message["method"].get<std::string>();
    const bool request = message.contains("id") && !message["id"].is_null();
    const Json params =
        message.contains("params") && message["params"].is_object() ? message["params"] : Json::object();
    if (!request)
        return std::nullopt;
    const Json& id = message["id"];

    if (method == "initialize") {
        std::string version{kProtocolVersions[0]};
        const std::string asked = params.value("protocolVersion", std::string{});
        for (const auto v : kProtocolVersions) {
            if (asked == v)
                version = asked;
        }
        return result_response(
            id,
            Json{{"protocolVersion", version},
                 {"capabilities",
                  {{"tools", {{"listChanged", false}}}, {"experimental", {{"claude/channel", Json::object()}}}}},
                 {"serverInfo", {{"name", kServerName}, {"version", kServerVersion}, {"title", "rexui"}}},
                 {"instructions", instructions_}});
    }
    if (method == "ping")
        return result_response(id, Json::object());
    if (method == "tools/list") {
        Json list = Json::array();
        for (const Tool& tool : tools_)
            list.push_back(
                {{"name", tool.name}, {"description", tool.description}, {"inputSchema", tool.input_schema}});
        return result_response(id, Json{{"tools", list}});
    }
    if (method == "tools/call")
        return result_response(id, call_tool(params));
    if (method == "resources/list")
        return result_response(id, Json{{"resources", Json::array()}});
    if (method == "prompts/list")
        return result_response(id, Json{{"prompts", Json::array()}});
    return error_response(id, -32601, "no method " + method);
}

auto Server::run() -> int {
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.empty())
            continue;
        const Json message = Json::parse(line, nullptr, false);
        if (message.is_discarded()) {
            write(error_response(nullptr, -32700, "not JSON"));
            continue;
        }
        if (auto response = handle(message))
            write(*response);
    }
    return 0;
}

}
