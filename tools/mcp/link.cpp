// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "tools/mcp/link.hpp"

#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <utility>

namespace rexui::mcp {

Link::Link(std::filesystem::path socket, Json hello, EventHandler on_event)
    : socket_{std::move(socket)},
      hello_{std::move(hello)},
      on_event_{std::move(on_event)},
      thread_{[this](const std::stop_token& stop) { run(stop); }} {
}

Link::~Link() {
    thread_.request_stop();
    {
        const std::scoped_lock lock{mutex_};
        if (fd_ >= 0)
            ::shutdown(fd_, SHUT_RDWR);
    }
    if (thread_.joinable())
        thread_.join();
}

auto Link::connected() const -> bool {
    const std::scoped_lock lock{mutex_};
    return fd_ >= 0;
}

auto Link::send_line(int fd, const Json& message) -> bool {
    std::string line = message.dump(-1, ' ', false, Json::error_handler_t::replace);
    line.push_back('\n');
    const char* p = line.data();
    std::size_t left = line.size();
    while (left > 0) {
        const ssize_t n = ::send(fd, p, left, 0);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        p += n;
        left -= static_cast<std::size_t>(n);
    }
    return true;
}

auto Link::call(std::string_view op, Json arg, std::chrono::milliseconds timeout) -> std::expected<Json, std::string> {
    std::future<std::expected<Json, std::string>> answer;
    {
        const std::scoped_lock lock{mutex_};
        if (fd_ < 0)
            return std::unexpected{
                std::string{"Rex UI isn't running (or not yet connected): start it, then try again"}};
        const std::int64_t id = next_id_++;
        answer = pending_[id].get_future();
        if (!send_line(fd_, Json{{"id", id}, {"op", op}, {"arg", std::move(arg)}})) {
            pending_.erase(id);
            return std::unexpected{std::string{"Rex UI's socket closed"}};
        }
    }
    if (answer.wait_for(timeout) != std::future_status::ready)
        return std::unexpected{std::string{"Rex UI didn't answer in time"}};
    return answer.get();
}

auto Link::fail_pending(const std::string& why) -> void {
    for (auto& [id, promise] : pending_)
        promise.set_value(std::unexpected{why});
    pending_.clear();
}

auto Link::run(const std::stop_token& stop) -> void {
    while (!stop.stop_requested()) {
        const int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
        sockaddr_un addr{};
        addr.sun_family = AF_UNIX;
        const std::string path = socket_.string();
        std::strncpy(addr.sun_path, path.c_str(), sizeof addr.sun_path - 1);
        if (fd < 0 || ::connect(fd, reinterpret_cast<const sockaddr*>(&addr), sizeof addr) != 0) {
            if (fd >= 0)
                ::close(fd);
            for (int i = 0; i < 20 && !stop.stop_requested(); ++i)
                std::this_thread::sleep_for(std::chrono::milliseconds{100});
            continue;
        }
        int one = 1;
        ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
        {
            const std::scoped_lock lock{mutex_};
            fd_ = fd;
            send_line(fd, Json{{"id", nullptr}, {"op", "hello"}, {"arg", hello_}});
        }
        std::string buffer;
        char chunk[16384];
        while (!stop.stop_requested()) {
            const ssize_t n = ::read(fd, chunk, sizeof chunk);
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                break;
            buffer.append(chunk, static_cast<std::size_t>(n));
            for (std::size_t nl; (nl = buffer.find('\n')) != std::string::npos;) {
                Json message = Json::parse(std::string_view{buffer}.substr(0, nl), nullptr, false);
                buffer.erase(0, nl + 1);
                if (!message.is_object())
                    continue;
                if (message.contains("event")) {
                    if (on_event_)
                        on_event_(message);
                    continue;
                }
                if (!message.contains("id") || !message["id"].is_number_integer())
                    continue;
                const std::scoped_lock lock{mutex_};
                const auto it = pending_.find(message["id"].get<std::int64_t>());
                if (it == pending_.end())
                    continue;
                if (message.contains("error"))
                    it->second.set_value(std::unexpected{message["error"].dump()});
                else
                    it->second.set_value(message.value("result", Json{}));
                pending_.erase(it);
            }
        }
        {
            const std::scoped_lock lock{mutex_};
            fd_ = -1;
            fail_pending("Rex UI went away (relaunched?); try again in a moment");
        }
        ::close(fd);
    }
}

}
