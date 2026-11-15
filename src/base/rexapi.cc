// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "base/rexapi.h"

#include <pthread.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>

namespace rx::rexapi {

namespace {

std::mutex g_lock;
uint64_t g_next = 1;
Stats g_stats;

struct Conn {
    int fd = -1;
};
Conn g_calls;

bool write_all(int fd, const void* p, size_t n) {
    const char* c = static_cast<const char*>(p);
    while (n) {
        ssize_t w = ::write(fd, c, n);
        if (w < 0 && errno == EINTR)
            continue;
        if (w <= 0)
            return false;
        c += w, n -= static_cast<size_t>(w);
    }
    return true;
}

bool read_all(int fd, void* p, size_t n) {
    char* c = static_cast<char*>(p);
    while (n) {
        ssize_t r = ::read(fd, c, n);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0)
            return false;
        c += r, n -= static_cast<size_t>(r);
    }
    return true;
}

void drop(Conn& c) {
    if (c.fd >= 0)
        ::close(c.fd);
    c.fd = -1;
}

bool send_frame(Conn& c, uint8_t opcode, std::string_view data) {
    uint8_t head[14];
    size_t h = 0, n = data.size();
    head[h++] = static_cast<uint8_t>(0x80 | opcode);
    if (n < 126)
        head[h++] = static_cast<uint8_t>(0x80 | n);
    else if (n < 65536)
        head[h++] = 0x80 | 126, head[h++] = static_cast<uint8_t>(n >> 8), head[h++] = static_cast<uint8_t>(n);
    else {
        head[h++] = 0x80 | 127;
        for (int k = 7; k >= 0; k--)
            head[h++] = static_cast<uint8_t>(static_cast<uint64_t>(n) >> (8 * k));
    }
    uint32_t m = arc4random();
    uint8_t mask[4] = {static_cast<uint8_t>(m), static_cast<uint8_t>(m >> 8), static_cast<uint8_t>(m >> 16),
                       static_cast<uint8_t>(m >> 24)};
    std::memcpy(head + h, mask, 4), h += 4;
    std::string body(data);
    for (size_t i = 0; i < n; i++)
        body[i] = static_cast<char>(body[i] ^ mask[i & 3]);
    return write_all(c.fd, head, h) && write_all(c.fd, body.data(), n);
}

bool read_message(Conn& c, std::string& out) {
    out.clear();
    for (;;) {
        uint8_t h[2];
        if (!read_all(c.fd, h, 2))
            return false;
        bool fin = h[0] & 0x80;
        uint8_t op = h[0] & 0x0F;
        uint64_t n = h[1] & 0x7F;
        if (n == 126) {
            uint8_t e[2];
            if (!read_all(c.fd, e, 2))
                return false;
            n = static_cast<uint64_t>(e[0]) << 8 | e[1];
        } else if (n == 127) {
            uint8_t e[8];
            if (!read_all(c.fd, e, 8))
                return false;
            n = 0;
            for (uint8_t b : e)
                n = n << 8 | b;
        }
        uint8_t mask[4] = {};
        bool masked = h[1] & 0x80;
        if (masked && !read_all(c.fd, mask, 4))
            return false;
        if (n > (64u << 20))
            return false;
        std::string data(static_cast<size_t>(n), '\0');
        if (n && !read_all(c.fd, data.data(), static_cast<size_t>(n)))
            return false;
        if (masked)
            for (size_t i = 0; i < data.size(); i++)
                data[i] = static_cast<char>(data[i] ^ mask[i & 3]);
        if (op == 0x8)
            return false;
        if (op == 0x9) {
            if (!send_frame(c, 0xA, data))
                return false;
            continue;
        }
        if (op == 0xA)
            continue;
        out += data;
        if (fin)
            return true;
    }
}

size_t skip_value(std::string_view s, size_t i) {
    if (i >= s.size())
        return i;
    if (s[i] == '"') {
        for (i++; i < s.size(); i++) {
            if (s[i] == '\\')
                i++;
            else if (s[i] == '"')
                return i + 1;
        }
        return s.size();
    }
    if (s[i] == '{' || s[i] == '[') {
        int depth = 0;
        for (; i < s.size(); i++) {
            char c = s[i];
            if (c == '"') {
                i = skip_value(s, i) - 1;
                continue;
            }
            if (c == '{' || c == '[')
                depth++;
            else if ((c == '}' || c == ']') && --depth == 0)
                return i + 1;
        }
        return s.size();
    }
    while (i < s.size() && s[i] != ',' && s[i] != '}' && s[i] != ']' && s[i] != ' ' && s[i] != '\n')
        i++;
    return i;
}

std::string_view member(std::string_view s, std::string_view key) {
    size_t i = s.find('{');
    if (i == std::string_view::npos)
        return {};
    i++;
    while (i < s.size()) {
        while (i < s.size() && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t' || s[i] == ','))
            i++;
        if (i >= s.size() || s[i] != '"')
            return {};
        size_t k0 = i + 1, k1 = skip_value(s, i) - 1;
        i = k1 + 1;
        while (i < s.size() && (s[i] == ' ' || s[i] == ':'))
            i++;
        size_t v0 = i, v1 = skip_value(s, i);
        if (s.substr(k0, k1 - k0) == key)
            return s.substr(v0, v1 - v0);
        i = v1;
    }
    return {};
}

std::string unquote(std::string_view v) {
    if (v.size() < 2 || v.front() != '"')
        return std::string(v);
    std::string out;
    for (size_t i = 1; i + 1 < v.size(); i++) {
        if (v[i] == '\\' && i + 2 < v.size()) {
            char c = v[++i];
            out += c == 'n' ? '\n' : c == 't' ? '\t' : c;
        } else {
            out += v[i];
        }
    }
    return out;
}

bool upgrade(Conn& conn, std::string_view target, std::string_view subprotocol, std::string& why, bool timeouts) {
    std::string path = socket_path();
    int fd = ::socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return why = "socket: " + std::string(std::strerror(errno)), false;
    sockaddr_un a{};
    a.sun_family = AF_UNIX;
    if (path.size() >= sizeof a.sun_path)
        return ::close(fd), why = "the socket's path is too long", false;
    std::memcpy(a.sun_path, path.c_str(), path.size() + 1);
    if (::connect(fd, reinterpret_cast<sockaddr*>(&a), sizeof a) != 0) {
        why = "connect " + path + ": " + std::strerror(errno);
        ::close(fd);
        return false;
    }
    timeval tv{10, 0};
    if (timeouts)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    conn.fd = fd;
    uint8_t key[16];
    arc4random_buf(key, sizeof key);
    static const char b64[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string k;
    for (size_t i = 0; i < 16; i += 3) {
        uint32_t v = static_cast<uint32_t>(key[i]) << 16 | (i + 1 < 16 ? static_cast<uint32_t>(key[i + 1]) << 8 : 0)
            | (i + 2 < 16 ? key[i + 2] : 0);
        k += b64[v >> 18 & 63], k += b64[v >> 12 & 63];
        k += i + 1 < 16 ? b64[v >> 6 & 63] : '=';
        k += i + 2 < 16 ? b64[v & 63] : '=';
    }
    std::string req = "GET " + std::string(target)
        + " HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
          "Sec-WebSocket-Key: "
        + k + "\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: " + std::string(subprotocol) + "\r\n\r\n";
    if (!write_all(fd, req.data(), req.size()))
        return drop(conn), why = "the upgrade couldn't be sent", false;
    std::string head;
    char c;
    while (head.size() < 8192 && head.find("\r\n\r\n") == std::string::npos) {
        if (!read_all(fd, &c, 1))
            return drop(conn), why = "the server closed the upgrade", false;
        head += c;
    }
    if (head.compare(0, 12, "HTTP/1.1 101") != 0)
        return drop(conn), why = "the server said: " + head.substr(0, head.find('\r')), false;
    return true;
}

bool say_hello(Conn& conn, std::string_view name, std::string& why) {
    std::string hello = R"({"type":"hello","api_revision":7,"client":{"kind":"other","name":")" + std::string(name)
        + R"(","version":"1"}})";
    std::string welcome;
    if (!send_frame(conn, 0x1, hello) || !read_message(conn, welcome))
        return drop(conn), why = "no welcome", false;
    if (unquote(member(welcome, "type")) != "welcome" || unquote(member(welcome, "protocol")) != "rex.control.v1")
        return drop(conn), why = "not a welcome: " + welcome.substr(0, 200), false;
    return true;
}

bool connect_server(Conn& conn, std::string& why, bool timeouts = true) {
    return upgrade(conn, "/api/control", "rex.control.v1", why, timeouts) && say_hello(conn, "rexui", why);
}

}

int dial(std::string_view path, std::string_view subprotocol, std::string_view hello_name, std::string& why) {
    Conn c;
    if (!upgrade(c, path, subprotocol, why, true))
        return -1;
    if (!hello_name.empty() && !say_hello(c, hello_name, why))
        return -1;
    return c.fd;
}

bool send_message(int fd, uint8_t opcode, std::string_view data) {
    Conn c;
    c.fd = fd;
    return send_frame(c, opcode, data);
}

void Frames::add(const void* bytes, size_t n) {
    if (consumed_) {
        in_.erase(0, consumed_);
        consumed_ = 0;
    }
    in_.append(static_cast<const char*>(bytes), n);
}

bool Frames::next(uint8_t* opcode, std::string_view* data) {
    for (;;) {
        size_t have = in_.size() - consumed_;
        const auto* p = reinterpret_cast<const uint8_t*>(in_.data()) + consumed_;
        if (have < 2)
            return false;
        bool fin = p[0] & 0x80, masked = p[1] & 0x80;
        uint8_t op = p[0] & 0x0F;
        uint64_t n = p[1] & 0x7F;
        size_t head = 2;
        if (n == 126) {
            if (have < 4)
                return false;
            n = uint64_t(p[2]) << 8 | p[3];
            head = 4;
        } else if (n == 127) {
            if (have < 10)
                return false;
            n = 0;
            for (int i = 2; i < 10; i++)
                n = n << 8 | p[i];
            head = 10;
        }
        size_t mask_at = head;
        if (masked)
            head += 4;
        if (n > (64u << 20) || have < head + n)
            return false;
        char* d = in_.data() + consumed_ + head;
        if (masked)
            for (size_t i = 0; i < n; i++)
                d[i] = static_cast<char>(d[i] ^ p[mask_at + (i & 3)]);
        consumed_ += head + static_cast<size_t>(n);
        std::string_view payload(d, static_cast<size_t>(n));
        if (op >= 0x8) {
            *opcode = op, *data = payload;
            return true;
        }
        if (fin && joined_.empty()) {
            *opcode = op, *data = payload;
            return true;
        }
        if (op != 0)
            first_op_ = op;
        joined_.append(payload);
        if (fin) {
            std::swap(joined_, whole_);
            joined_.clear();
            *opcode = first_op_, *data = whole_;
            return true;
        }
    }
}

std::string socket_path() {
    if (const char* e = std::getenv("REX_SERVER"); e && e[0] == '/')
        return e;
    const char* home = std::getenv("HOME");
    return std::string(home ? home : "") + "/Library/Application Support/rex/server.sock";
}

namespace {

bool attach_all(Conn& c, std::string& why) {
    std::string id = "a" + std::to_string(g_next++);
    std::string req =
        R"({"type":"request","id":")" + id + R"(","method":"session.attach_all","payload":{"event_scope":"session"}})";
    if (!send_frame(c, 0x1, req))
        return drop(c), why = "the attach couldn't be sent", false;
    std::string in;
    while (read_message(c, in)) {
        if (unquote(member(in, "type")) != "response" || unquote(member(in, "id")) != id)
            continue;
        std::string_view err = member(in, "error");
        if (!err.empty() && err != "null")
            return drop(c), why = "session.attach_all: " + unquote(member(err, "message")), false;
        return true;
    }
    return drop(c), why = "no answer to session.attach_all", false;
}

}

Result call(std::string_view method, std::string_view payload) {
    std::lock_guard<std::mutex> hold(g_lock);
    Result r;
    for (int attempt = 0; attempt < 2; attempt++) {
        if (g_calls.fd < 0) {
            if (!connect_server(g_calls, r.error) || !attach_all(g_calls, r.error)) {
                g_stats.failures++;
                return r;
            }
            g_stats.connects++;
        }
        std::string id = std::to_string(g_next++);
        std::string msg = "{\"type\":\"request\",\"id\":\"" + id + "\",\"method\":\"" + std::string(method) + "\"";
        if (!payload.empty())
            msg += ",\"payload\":" + std::string(payload);
        msg += "}";
        if (!send_frame(g_calls, 0x1, msg)) {
            drop(g_calls);
            r.error = "the connection dropped";
            continue;
        }
        std::string in;
        bool got = false;
        while (read_message(g_calls, in)) {
            if (unquote(member(in, "type")) != "response" || unquote(member(in, "id")) != id)
                continue;
            got = true;
            break;
        }
        if (!got) {
            drop(g_calls);
            r.error = "the connection dropped";
            if (attempt == 0)
                continue;
            g_stats.failures++;
            return r;
        }
        g_stats.calls++;
        std::string_view err = member(in, "error");
        if (!err.empty() && err != "null") {
            r.code = unquote(member(err, "code"));
            r.error = unquote(member(err, "message"));
            return r;
        }
        std::string_view p = member(in, "payload");
        r.payload = p.empty() ? "{}" : std::string(p);
        r.ok = true;
        return r;
    }
    g_stats.failures++;
    return r;
}

namespace {

EventFn g_watch_fn;
void* g_watch_ctx;
std::atomic<uint64_t> g_watch_events, g_watch_connects;

void* watch_main(void*) {
    pthread_setname_np("rexui rex events");
    Conn c;
    std::string why, in;
    for (int backoff = 1;; backoff = backoff < 30 ? backoff * 2 : 30) {
        if (!connect_server(c, why, false)) {
            ::sleep(static_cast<unsigned>(backoff));
            continue;
        }
        std::string req =
            R"({"type":"request","id":"w1","method":"session.attach_all","payload":{"event_scope":"all"}})";
        if (!send_frame(c, 0x1, req)) {
            drop(c);
            continue;
        }
        bool attached = false;
        while (read_message(c, in)) {
            std::string type = unquote(member(in, "type"));
            if (!attached) {
                if (type != "response" || unquote(member(in, "id")) != "w1")
                    continue;
                std::string_view err = member(in, "error");
                if (!err.empty() && err != "null")
                    break;
                attached = true, backoff = 1;
                g_watch_connects.store(g_watch_connects.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
                g_watch_fn(g_watch_ctx, {}, {});
                continue;
            }
            if (type != "event")
                continue;
            std::string_view ev = member(in, "payload");
            std::string kind = unquote(member(ev, "type"));
            std::string name;
            if (kind == "session_event") {
                std::string_view inner = member(member(ev, "payload"), "event");
                kind = unquote(member(inner, "type"));
                if (kind == "block_event")
                    name = unquote(member(member(inner, "payload"), "name"));
            }
            g_watch_events.store(g_watch_events.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
            g_watch_fn(g_watch_ctx, kind, name);
        }
        drop(c);
        ::sleep(static_cast<unsigned>(backoff));
    }
    return nullptr;
}

}

bool watch(EventFn f, void* ctx) {
    static std::once_flag once;
    static bool ok;
    std::call_once(once, [&] {
        g_watch_fn = f, g_watch_ctx = ctx;
        pthread_t t;
        pthread_attr_t a;
        pthread_attr_init(&a);
        pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
        pthread_attr_set_qos_class_np(&a, QOS_CLASS_UTILITY, 0);
        ok = pthread_create(&t, &a, watch_main, nullptr) == 0;
        pthread_attr_destroy(&a);
    });
    return ok;
}

WatchStats watch_stats() {
    return {g_watch_events.load(std::memory_order_relaxed), g_watch_connects.load(std::memory_order_relaxed)};
}

Stats stats() {
    std::lock_guard<std::mutex> hold(g_lock);
    return g_stats;
}

void close_connection() {
    std::lock_guard<std::mutex> hold(g_lock);
    drop(g_calls);
}

}
