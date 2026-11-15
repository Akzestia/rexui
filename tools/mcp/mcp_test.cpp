// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <gtest/gtest.h>

#include "tools/mcp/context.hpp"
#include "tools/mcp/server.hpp"

namespace rexui::mcp {
namespace {

auto sample_info() -> Json {
    return Json::parse(R"({"type":"Rectangle","id":"card","comp":"Card","file":"Card.rui","line":12,
        "frame":{"x":10,"y":20,"width":300,"height":48},
        "props":[{"name":"radius","value":"8","isDefault":false,"binding":"r + 2"},{"name":"color","value":"\"#fff\"","isDefault":true}],
        "handlers":["onClicked"]})");
}

auto sample_rows() -> Json {
    return Json::parse(R"([{"uid":1,"depth":0,"type":"Dock"},{"uid":2,"depth":1,"type":"Column","id":"col"},
        {"uid":3,"depth":2,"type":"Rectangle","comp":"Card","id":"card","width":300,"height":48,"file":"bar.rui","line":5}])");
}

TEST(Context, SaysWhatAndWhere) {
    const std::string text =
        element_context(sample_info(), sample_rows(), "/d/ui/bar.rui", 3, "/r/README.md", "make it taller");
    EXPECT_NE(text.find("Element: Card (a Rectangle) #card"), std::string::npos) << text;
    EXPECT_NE(text.find("Written at: /d/ui/Card.rui:12  (used in /d/ui/bar.rui)"), std::string::npos) << text;
    EXPECT_NE(text.find("Inside: Dock > Column#col"), std::string::npos) << text;
    EXPECT_NE(text.find("radius: 8   (bound: r + 2)"), std::string::npos) << text;
    EXPECT_EQ(text.find("color:"), std::string::npos) << "a default property isn't listed";
    EXPECT_NE(text.find("Handlers: onClicked"), std::string::npos) << text;
    EXPECT_NE(text.find("/r/README.md documents"), std::string::npos) << text;
    EXPECT_NE(text.find("Request: make it taller"), std::string::npos) << text;
}

TEST(Context, TreeOutline) {
    const std::string tree = format_tree(sample_rows(), 2);
    EXPECT_NE(tree.find("Dock"), std::string::npos);
    EXPECT_NE(tree.find("  Column#col"), std::string::npos);
    EXPECT_NE(tree.find("1 more rows"), std::string::npos) << tree;
}

TEST(Server, InitializeDeclaresTheChannel) {
    Server server{{}, "hi"};
    const auto r = server.handle(
        Json::parse(R"({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}})"));
    ASSERT_TRUE(r.has_value());
    EXPECT_EQ((*r)["result"]["protocolVersion"], "2025-06-18");
    EXPECT_TRUE((*r)["result"]["capabilities"]["experimental"].contains("claude/channel"));
    EXPECT_EQ((*r)["result"]["instructions"], "hi");
}

TEST(Server, ToolsListAndCall) {
    Server server{{Tool{.name = "echo",
                        .description = "d",
                        .input_schema = Json::object(),
                        .run = [](const Json& a) -> std::expected<std::string, std::string> {
                            if (!a.contains("x"))
                                return std::unexpected{std::string{"no x"}};
                            return a["x"].get<std::string>();
                        }}},
                  ""};
    const auto list = server.handle(Json::parse(R"({"jsonrpc":"2.0","id":2,"method":"tools/list"})"));
    EXPECT_EQ((*list)["result"]["tools"][0]["name"], "echo");
    const auto ok = server.handle(Json::parse(
        R"({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"x":"hey"}}})"));
    EXPECT_EQ((*ok)["result"]["content"][0]["text"], "hey");
    EXPECT_FALSE((*ok)["result"]["isError"].get<bool>());
    const auto bad = server.handle(
        Json::parse(R"({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo","arguments":{}}})"));
    EXPECT_TRUE((*bad)["result"]["isError"].get<bool>());
    EXPECT_FALSE(server.handle(Json::parse(R"({"jsonrpc":"2.0","method":"notifications/initialized"})")).has_value());
    EXPECT_EQ((*server.handle(Json::parse(R"({"jsonrpc":"2.0","id":5,"method":"nope"})")))["error"]["code"], -32601);
}

}
}
