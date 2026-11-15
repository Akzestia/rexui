// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <expected>
#include <functional>
#include <mutex>
#include <nlohmann/json.hpp>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace rexui::mcp {

using Json = nlohmann::json;

struct Tool {
    std::string name;
    std::string description;
    Json input_schema;
    std::function<std::expected<std::string, std::string>(const Json& arguments)> run;
};

inline constexpr std::string_view kServerName = "rexui";
inline constexpr std::string_view kServerVersion = "0.1.0";
inline constexpr std::string_view kProtocolVersions[] = {"2025-11-25", "2025-06-18", "2025-03-26"};

struct Server {
    Server(std::vector<Tool> tools, std::string instructions);

    [[nodiscard]] auto handle(const Json& message) -> std::optional<Json>;
    auto run() -> int;
    auto notify(std::string_view method, Json params) -> void;

  private:
    auto write(const Json& message) -> void;
    [[nodiscard]] auto call_tool(const Json& params) -> Json;

    std::vector<Tool> tools_;
    std::string instructions_;
    std::mutex write_mutex_;
};

}
