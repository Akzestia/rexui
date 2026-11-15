// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <nlohmann/json.hpp>
#include <string>
#include <string_view>

namespace rexui::mcp {

using Json = nlohmann::json;

[[nodiscard]] auto element_context(const Json& info, const Json& rows, std::string_view doc_path, long uid,
                                   std::string_view readme, std::string_view request) -> std::string;

[[nodiscard]] auto format_tree(const Json& rows, std::size_t max_rows) -> std::string;

[[nodiscard]] auto basename_of(std::string_view path) -> std::string_view;
[[nodiscard]] auto dirname_of(std::string_view path) -> std::string_view;

}
