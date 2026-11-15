// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstdint>
#include <string>
#include <string_view>

namespace rx::rexapi {

struct Result {
    bool ok = false;
    std::string payload;
    std::string error;
    std::string code;
};

std::string socket_path();

Result call(std::string_view method, std::string_view payload = {});

using EventFn = void (*)(void* ctx, std::string_view type, std::string_view name);
bool watch(EventFn f, void* ctx);
struct WatchStats {
    uint64_t events = 0, connects = 0;
};
WatchStats watch_stats();

int dial(std::string_view path, std::string_view subprotocol, std::string_view hello_name, std::string& why);
bool send_message(int fd, uint8_t opcode, std::string_view data);
class Frames {
  public:
    void add(const void* bytes, size_t n);
    bool next(uint8_t* opcode, std::string_view* data);

  private:
    std::string in_, joined_, whole_;
    size_t consumed_ = 0;
    uint8_t first_op_ = 0;
};

struct Stats {
    uint64_t calls = 0, connects = 0, failures = 0;
};
Stats stats();
void close_connection();

}
