// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <string_view>
#include <vector>

#include "tools/mcp/link.hpp"
#include "tools/mcp/server.hpp"

namespace rexui::mcp {

extern const std::string_view kInstructions;

[[nodiscard]] auto make_tools(Link& link) -> std::vector<Tool>;

}
