// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <chrono>
#include <cstdint>
#include <expected>
#include <filesystem>
#include <functional>
#include <future>
#include <mutex>
#include <nlohmann/json.hpp>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>

namespace rexui::mcp {

using Json = nlohmann::json;

struct Link {
    using EventHandler = std::function<void(const Json&)>;

    Link(std::filesystem::path socket, Json hello, EventHandler on_event);
    ~Link();
    Link(const Link&) = delete;
    auto operator=(const Link&) -> Link& = delete;

    [[nodiscard]] auto call(std::string_view op, Json arg, std::chrono::milliseconds timeout = std::chrono::seconds{5})
        -> std::expected<Json, std::string>;
    [[nodiscard]] auto connected() const -> bool;

  private:
    auto run(const std::stop_token& stop) -> void;
    auto send_line(int fd, const Json& message) -> bool;
    auto fail_pending(const std::string& why) -> void;

    std::filesystem::path socket_;
    Json hello_;
    EventHandler on_event_;

    mutable std::mutex mutex_;
    int fd_ = -1;
    std::int64_t next_id_ = 1;
    std::unordered_map<std::int64_t, std::promise<std::expected<Json, std::string>>> pending_;

    std::jthread thread_;
};

}
