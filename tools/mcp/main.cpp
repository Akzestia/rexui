// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <unistd.h>

#include <atomic>
#include <cstdlib>
#include <filesystem>
#include <print>
#include <span>
#include <string>
#include <string_view>

#include "tools/mcp/link.hpp"
#include "tools/mcp/server.hpp"
#include "tools/mcp/tools.hpp"

namespace {

[[nodiscard]] auto socket_path() -> std::filesystem::path {
    const char* home = std::getenv("HOME");
    return std::filesystem::path{home ? home : "/tmp"} / "Library/Application Support/rexui/agent.sock";
}

}

auto main(int argc, char** argv) -> int {
    for (const std::string_view a : std::span{argv, static_cast<std::size_t>(argc)}.subspan(1)) {
        if (a == "--version" || a == "-v") {
            std::println(stderr, "{} {}", rexui::mcp::kServerName, rexui::mcp::kServerVersion);
            return 0;
        }
        if (a == "--help" || a == "-h") {
            std::println(stderr,
                         "rexui-mcp: rexui's dev tools for an agent (MCP over stdio). Started by Claude Code:\n"
                         "  claude mcp add -s user rexui -- {}\n"
                         "  claude --dangerously-load-development-channels server:rexui",
                         argv[0]);
            return 0;
        }
    }

    std::error_code ec;
    const auto cwd = std::filesystem::current_path(ec);
    const char* term = std::getenv("TERM_PROGRAM");
    const char* tty = ::ttyname(STDERR_FILENO);
    const rexui::mcp::Json hello{{"pid", static_cast<long>(::getppid())},
                                 {"cwd", ec ? std::string{} : cwd.string()},
                                 {"where", term ? term : ""},
                                 {"tty", tty ? tty : ""},
                                 {"title", ec ? std::string{} : cwd.filename().string()}};

    std::atomic<rexui::mcp::Server*> server{nullptr};
    rexui::mcp::Link link{socket_path(), hello, [&server](const rexui::mcp::Json& event) {
                              rexui::mcp::Server* s = server.load();
                              if (!s || event.value("event", std::string{}) != "ask")
                                  return;
                              s->notify("notifications/claude/channel",
                                        {{"content", event.value("text", std::string{})},
                                         {"meta", {{"kind", "ask"}, {"from", "rexui_devtools"}}}});
                          }};
    rexui::mcp::Server mcp{rexui::mcp::make_tools(link), std::string{rexui::mcp::kInstructions}};
    server.store(&mcp);
    const int code = mcp.run();
    server.store(nullptr);
    return code;
}
