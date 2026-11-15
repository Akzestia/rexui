// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/io/io.h"

#include <fcntl.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <signal.h>
#include <spawn.h>
#include <sys/event.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <span>
#include <thread>
#include <utility>

#include "core/io/proto.h"
#include "core/sync/byte_ring.h"
#include "core/sync/flags.h"
#include "core/sync/spsc_ring.h"
#include "rexui_proto.h"

extern char** environ;

namespace rx::io {
namespace {

using sync::ByteRingCtl;
using sync::ByteRingReader;
using sync::ByteRingWriter;

struct Stream {
    int fd = -1;
    std::uint8_t* buf = nullptr;
    std::uint32_t len = 0;
    bool skipping = false;
    bool stalled = false;
    std::uint64_t stalled_at = 0;
    bool first = true;
    bool frames = false;
};

struct Slot {
    std::uint32_t id = 0;
    std::int32_t pid = -1;
    int in_fd = -1;
    Stream out, err;
    alignas(128) ByteRingCtl in_ctl{};
    std::uint8_t* in_data = nullptr;
    ByteRingWriter in_w;
    ByteRingReader in_r;
    std::uint8_t* carry = nullptr;
    std::uint32_t carry_len = 0, carry_at = 0;
    bool want_write = false;
    bool v2 = false;
    std::uint32_t features = 0;
    std::uint32_t rec_left = 0;
    bool rec_v1 = false, rec_nl = false;
    char answer[160];
    std::uint32_t answer_len = 0;
    std::uint32_t delivered = 0;
    std::uint32_t credit_owed = 0;
    std::uint64_t flood_said = 0;
    bool live = false;
    bool exited = false;
    std::int32_t code = 0;
};

constexpr std::uint32_t k_carry = 1u << 16;

enum class Op : std::uint8_t { add, stop };
struct Cmd {
    Op op;
    std::uint32_t slot;
};

struct Header {
    std::uint32_t id;
    std::uint8_t kind;
    std::uint8_t pad[3];
    std::int32_t code;
    std::uint32_t len;
};
static_assert(sizeof(Header) == 16);

Slot g_slots[k_max];
bool g_used[k_max];
std::uint8_t g_gen[k_max];
int g_kq = -1;
void (*g_wake)(void*) = nullptr;
void* g_wake_ctx = nullptr;

sync::SpscRing<Cmd, 1024> g_cmds;
alignas(128) ByteRingCtl g_ev_ctl{};
std::uint8_t* g_ev_data = nullptr;
ByteRingWriter g_ev_w;
ByteRingReader g_ev_r;
std::uint8_t* g_line = nullptr;
sync::SleepFlag g_main_sleep;

void doorbell() noexcept {
    struct kevent ev;
    EV_SET(&ev, 1, EVFILT_USER, 0, NOTE_TRIGGER, 0, nullptr);
    (void)kevent(g_kq, &ev, 1, nullptr, 0, nullptr);
}

void watch(int fd, short filter, unsigned short flags, std::uint32_t slot, std::uint32_t which) noexcept {
    struct kevent ev;
    EV_SET(&ev, static_cast<uintptr_t>(fd), filter, flags, 0, 0,
           reinterpret_cast<void*>(static_cast<uintptr_t>(slot << 2 | which)));
    (void)kevent(g_kq, &ev, 1, nullptr, 0, nullptr);
}

bool g_published_any = false;

bool emit(std::uint32_t id, Kind kind, std::int32_t code, const std::uint8_t* text, std::uint32_t len,
          const std::uint8_t* pre = nullptr, std::uint32_t pre_len = 0) noexcept {
    std::uint64_t need = sizeof(Header) + pre_len + len;
    if (pre_len + len > k_line || need > g_ev_w.capacity())
        return true;
    if (g_ev_w.space(need) < need)
        return false;
    Header h{id, static_cast<std::uint8_t>(kind), {}, code, pre_len + len};
    (void)g_ev_w.write({reinterpret_cast<const std::uint8_t*>(&h), sizeof h});
    if (pre_len)
        (void)g_ev_w.write({pre, pre_len});
    if (len)
        (void)g_ev_w.write({text, len});
    g_published_any = true;
    return true;
}

char* g_patch = nullptr;

void protocol_error(Slot& s, Stream& st, std::string_view why) noexcept {
    char msg[200];
    int n = std::snprintf(msg, sizeof msg, "rexui: protocol 2: %.*s; the backend is stopped",
                          static_cast<int>(why.size()), why.data());
    (void)emit(s.id, Kind::err, 0, reinterpret_cast<const std::uint8_t*>(msg),
               static_cast<std::uint32_t>(n > 0 ? n : 0));
    st.len = 0;
    if (st.fd >= 0)
        close(st.fd), st.fd = -1;
    (void)kill(s.pid, SIGTERM);
}

bool frames(Slot& s, Stream& st) noexcept {
    std::uint32_t at = 0;
    bool ok = true;
    for (;;) {
        rexui_frame_header h;
        long whole = rexui_frame_scan(st.buf + at, st.len - at, &h);
        if (whole == 0)
            break;
        if (whole < 0) {
            protocol_error(s, st, "a frame header out of bounds");
            return true;
        }
        const std::uint8_t* payload = st.buf + at + REXUI_FRAME_HEADER;
        bool sent = true;
        if (h.type == REXUI_MESSAGE) {
            sent = emit(s.id, Kind::out, 0, payload, h.len);
        } else if (h.type == REXUI_STATE_PATCH) {
            std::size_t n = proto::patch_line({payload, h.len}, {g_patch, k_line});
            if (!n) {
                protocol_error(s, st, "a STATE_PATCH that doesn't parse");
                return true;
            }
            sent =
                emit(s.id, Kind::out, 1, reinterpret_cast<const std::uint8_t*>(g_patch), static_cast<std::uint32_t>(n));
        } else if (h.type == REXUI_REPLY) {
            std::uint8_t seq[8];
            rexui_put_u64(seq, h.seq);
            sent = emit(s.id, Kind::reply, h.flags, payload, h.len, seq, 8);
        }
        if (!sent) {
            ok = false;
            break;
        }
        at += static_cast<std::uint32_t>(whole);
        if (h.type == REXUI_MESSAGE || h.type == REXUI_STATE_PATCH)
            s.delivered++;
    }
    if (at)
        std::memmove(st.buf, st.buf + at, st.len - at), st.len -= at;
    if (s.delivered >= REXUI_CREDIT_START / 2 && (s.features & proto::k_credit))
        s.credit_owed += s.delivered, s.delivered = 0;
    return ok;
}

bool frame(Slot& s, Stream& st, Kind kind) noexcept {
    if (st.frames)
        return frames(s, st);
    std::uint32_t at = 0;
    while (at < st.len) {
        auto* nl = static_cast<std::uint8_t*>(std::memchr(st.buf + at, '\n', st.len - at));
        if (!nl)
            break;
        auto end = static_cast<std::uint32_t>(nl - st.buf);
        std::uint32_t features = 0;
        if (st.skipping) {
            st.skipping = false;
        } else if (st.first && kind == Kind::out
                   && proto::hello({reinterpret_cast<const char*>(st.buf + at), end - at}, &features)) {
            if (!emit(s.id, Kind::hello, static_cast<std::int32_t>(features & proto::k_supported), nullptr, 0)) {
                if (at)
                    std::memmove(st.buf, st.buf + at, st.len - at), st.len -= at;
                return false;
            }
            s.features = features & proto::k_supported;
            s.answer_len =
                static_cast<std::uint32_t>(proto::answer(s.features, REXUI_CREDIT_START, {s.answer, sizeof s.answer}));
            s.v2 = true;
            st.first = false;
            st.frames = true;
            at = end + 1;
            std::memmove(st.buf, st.buf + at, st.len - at), st.len -= at;
            return frames(s, st);
        } else if (!emit(s.id, kind, 0, st.buf + at, end - at)) {
            if (at)
                std::memmove(st.buf, st.buf + at, st.len - at), st.len -= at;
            return false;
        }
        st.first = false;
        at = end + 1;
    }
    if (at)
        std::memmove(st.buf, st.buf + at, st.len - at), st.len -= at;
    if (st.len == k_line)
        st.skipping = true, st.len = 0, st.first = false;
    return true;
}

void close_stream(Stream& st) noexcept {
    if (st.fd >= 0)
        close(st.fd);
    st.fd = -1;
}

bool pull(Slot& s, Stream& st, Kind kind, std::uint32_t slot, std::uint32_t which) noexcept {
    while (st.fd >= 0) {
        if (st.len == k_line && !frame(s, st, kind))
            break;
        ssize_t n = read(st.fd, st.buf + st.len, k_line - st.len);
        if (n > 0) {
            st.len += static_cast<std::uint32_t>(n);
            if (!frame(s, st, kind))
                break;
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EINTR))
            return true;
        close_stream(st);
        return true;
    }
    if (st.fd >= 0 && !st.stalled) {
        st.stalled = true;
        st.stalled_at = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        watch(st.fd, EVFILT_READ, EV_DISABLE, slot, which);
        (void)g_ev_w.block();
    }
    return st.fd < 0 || !st.stalled;
}

void finish(Slot& s) noexcept {
    if (!s.live || !s.exited || s.out.stalled || s.err.stalled)
        return;
    if (!emit(s.id, Kind::exit, s.code, nullptr, 0)) {
        (void)g_ev_w.block();
        return;
    }
    close_stream(s.out);
    close_stream(s.err);
    if (s.in_fd >= 0)
        close(s.in_fd), s.in_fd = -1;
    s.live = false;
}

std::uint32_t fill_carry(Slot& s) noexcept {
    std::uint32_t n = 0;
    auto put = [&](const void* p, std::uint32_t len) {
        std::memcpy(s.carry + n, p, len);
        n += len;
    };
    for (;;) {
        std::uint32_t room = k_carry - n;
        if (s.rec_left) {
            std::uint32_t take = std::min(room, s.rec_left);
            if (!take)
                break;
            take = static_cast<std::uint32_t>(s.in_r.read({s.carry + n, take}));
            if (!take)
                break;
            n += take, s.rec_left -= take;
            if (!s.rec_left && s.rec_v1)
                s.rec_nl = true;
            continue;
        }
        if (s.rec_nl) {
            if (!room)
                break;
            put("\n", 1);
            s.rec_nl = false;
            continue;
        }
        if (s.answer_len) {
            if (room < s.answer_len)
                break;
            put(s.answer, s.answer_len);
            s.answer_len = 0;
            continue;
        }
        if (s.v2 && s.credit_owed) {
            if (room < REXUI_FRAME_HEADER + 4)
                break;
            std::uint8_t f[REXUI_FRAME_HEADER + 4];
            rexui_frame_put_header(f, 4, REXUI_CREDIT, 0, 0);
            rexui_put_u32(f + REXUI_FRAME_HEADER, s.credit_owed);
            put(f, sizeof f);
            s.credit_owed = 0;
            continue;
        }
        if (room < REXUI_FRAME_HEADER)
            break;
        std::uint8_t h[REXUI_FRAME_HEADER];
        if (s.in_r.read({h, sizeof h}) != sizeof h)
            break;
        s.rec_left = rexui_get_u32(h);
        s.rec_v1 = !s.v2;
        if (s.v2)
            put(h, sizeof h);
        else if (!s.rec_left)
            s.rec_nl = true;
    }
    return n;
}

void flush_stdin(Slot& s, std::uint32_t slot) noexcept {
    for (;;) {
        if (s.carry_at == s.carry_len) {
            s.carry_at = s.carry_len = 0;
            if (s.in_fd < 0) {
                while (s.in_r.read({s.carry, k_carry})) {
                }
                s.rec_left = 0, s.rec_nl = false;
                return;
            }
            s.carry_len = fill_carry(s);
            if (!s.carry_len)
                break;
        }
        ssize_t n = write(s.in_fd, s.carry + s.carry_at, s.carry_len - s.carry_at);
        if (n > 0) {
            s.carry_at += static_cast<std::uint32_t>(n);
            continue;
        }
        if (n < 0 && errno == EAGAIN) {
            if (!s.want_write)
                watch(s.in_fd, EVFILT_WRITE, EV_ADD | EV_ONESHOT, slot, 3), s.want_write = true;
            return;
        }
        close(s.in_fd), s.in_fd = -1;
        s.carry_at = s.carry_len = 0;
    }
}

void answer_due(Slot& s, std::uint32_t slot) noexcept {
    if ((s.answer_len || s.credit_owed) && s.in_fd >= 0 && !s.want_write)
        flush_stdin(s, slot);
}

constexpr std::uint64_t k_flood_ns = 1'000'000'000;
void flooded(Slot& s, Stream& st) noexcept {
    std::uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), waited = now - st.stalled_at;
    if (waited < k_flood_ns || (s.flood_said && now - s.flood_said < 10 * k_flood_ns))
        return;
    s.flood_said = now;
    char msg[160];
    int n = std::snprintf(msg, sizeof msg,
                          "rexui: this backend's output waited %.1f s for its dock (it sends faster than the dock "
                          "takes it in); held back, nothing lost",
                          static_cast<double>(waited) / 1e9);
    (void)emit(s.id, Kind::err, 0, reinterpret_cast<const std::uint8_t*>(msg),
               static_cast<std::uint32_t>(n > 0 ? n : 0));
}

void retry_stalled() noexcept {
    for (std::uint32_t i = 0; i < k_max; i++) {
        Slot& s = g_slots[i];
        if (!s.live)
            continue;
        for (std::uint32_t w = 1; w <= 2; w++) {
            Stream& st = w == 1 ? s.out : s.err;
            if (!st.stalled)
                continue;
            if (!frame(s, st, w == 1 ? Kind::out : Kind::err))
                continue;
            st.stalled = false;
            flooded(s, st);
            if (st.fd >= 0)
                watch(st.fd, EVFILT_READ, EV_ENABLE, i, w);
            (void)pull(s, st, w == 1 ? Kind::out : Kind::err, i, w);
        }
        answer_due(s, i);
        finish(s);
    }
    bool any = false;
    for (std::uint32_t i = 0; i < k_max; i++) {
        Slot& s = g_slots[i];
        any = any || (s.live && (s.out.stalled || s.err.stalled || s.exited));
    }
    if (!any)
        g_ev_w.unblock();
}

void exited(Slot& s, std::uint32_t slot, int status) noexcept {
    s.exited = true;
    s.code = WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? WTERMSIG(status) : -1;
    (void)pull(s, s.out, Kind::out, slot, 1);
    (void)pull(s, s.err, Kind::err, slot, 2);
    finish(s);
}

void run() noexcept {
    struct kevent evs[64];
    for (;;) {
        int n = kevent(g_kq, nullptr, 0, evs, 64, nullptr);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            return;
        }
        for (int k = 0; k < n; k++) {
            const struct kevent& e = evs[k];
            if (e.filter == EVFILT_USER) {
                Cmd c;
                while (g_cmds.pop(c)) {
                    Slot& s = g_slots[c.slot];
                    if (c.op == Op::add) {
                        s.live = true, s.exited = false;
                        watch(s.out.fd, EVFILT_READ, EV_ADD, c.slot, 1);
                        watch(s.err.fd, EVFILT_READ, EV_ADD, c.slot, 2);
                        struct kevent pe;
                        EV_SET(&pe, static_cast<uintptr_t>(s.pid), EVFILT_PROC, EV_ADD | EV_ONESHOT,
                               NOTE_EXIT | NOTE_EXITSTATUS, 0,
                               reinterpret_cast<void*>(static_cast<uintptr_t>(c.slot << 2)));
                        if (kevent(g_kq, &pe, 1, nullptr, 0, nullptr) != 0) {
                            int st = 0;
                            (void)waitpid(s.pid, &st, 0);
                            exited(s, c.slot, st);
                        }
                    } else if (s.live) {
                        if (s.in_fd >= 0)
                            close(s.in_fd), s.in_fd = -1;
                        (void)kill(s.pid, SIGTERM);
                    }
                }
                for (std::uint32_t i = 0; i < k_max; i++)
                    if (g_slots[i].live && g_slots[i].in_fd >= 0 && !g_slots[i].want_write && g_slots[i].in_r.pending())
                        flush_stdin(g_slots[i], i);
                retry_stalled();
                continue;
            }
            auto slot = static_cast<std::uint32_t>(reinterpret_cast<uintptr_t>(e.udata) >> 2);
            std::uint32_t which = static_cast<std::uint32_t>(reinterpret_cast<uintptr_t>(e.udata) & 3);
            if (slot >= k_max)
                continue;
            Slot& s = g_slots[slot];
            if (!s.live)
                continue;
            if (e.filter == EVFILT_PROC) {
                int st = 0;
                (void)waitpid(s.pid, &st, WNOHANG);
                exited(s, slot, static_cast<int>(e.data));
            } else if (e.filter == EVFILT_READ) {
                if (which == 1 && !s.out.stalled)
                    (void)pull(s, s.out, Kind::out, slot, 1);
                if (which == 2 && !s.err.stalled)
                    (void)pull(s, s.err, Kind::err, slot, 2);
                answer_due(s, slot);
                finish(s);
            } else if (e.filter == EVFILT_WRITE) {
                s.want_write = false;
                flush_stdin(s, slot);
            }
        }
        if (g_published_any) {
            g_published_any = false;
            (void)g_ev_w.publish();
            if (g_main_sleep.needs_wake() && g_wake)
                g_wake(g_wake_ctx);
        }
    }
}

bool g_started = false;

bool prepare(Slot& s) noexcept {
    if (s.out.buf)
        return true;
    s.out.buf = static_cast<std::uint8_t*>(std::malloc(k_line));
    s.err.buf = static_cast<std::uint8_t*>(std::malloc(k_line));
    s.in_data = static_cast<std::uint8_t*>(std::malloc(k_stdin));
    s.carry = static_cast<std::uint8_t*>(std::malloc(k_carry));
    return s.out.buf && s.err.buf && s.in_data && s.carry;
}

}

bool start(void (*wake)(void*), void* ctx) noexcept {
    if (g_started)
        return true;
    g_kq = kqueue();
    if (g_kq < 0)
        return false;
    struct kevent ev;
    EV_SET(&ev, 1, EVFILT_USER, EV_ADD | EV_CLEAR, 0, 0, nullptr);
    if (kevent(g_kq, &ev, 1, nullptr, 0, nullptr) != 0)
        return false;
    g_ev_data = static_cast<std::uint8_t*>(std::malloc(k_events));
    g_line = static_cast<std::uint8_t*>(std::malloc(k_line));
    g_patch = static_cast<char*>(std::malloc(k_line));
    if (!g_ev_data || !g_line || !g_patch)
        return false;
    g_ev_w = ByteRingWriter(&g_ev_ctl, g_ev_data, k_events);
    g_ev_r = ByteRingReader(&g_ev_ctl, g_ev_data, k_events);
    g_wake = wake, g_wake_ctx = ctx;
    std::thread([] {
        pthread_setname_np("rexui io");
        (void)pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        run();
    }).detach();
    g_started = true;
    return true;
}

static int cloexec_pipe(int p[2]) noexcept {
    if (pipe(p))
        return -1;
    (void)fcntl(p[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(p[1], F_SETFD, FD_CLOEXEC);
    return 0;
}

std::expected<std::uint32_t, int> spawn(const Spawn& sp, std::int32_t* pid_out) noexcept {
    if (!g_started)
        return std::unexpected(EAGAIN);
    std::uint32_t i = 0;
    while (i < k_max && g_used[i])
        i++;
    if (i == k_max)
        return std::unexpected(EMFILE);
    Slot& s = g_slots[i];
    if (!prepare(s))
        return std::unexpected(ENOMEM);
    int in[2], out[2], err[2];
    if (cloexec_pipe(in))
        return std::unexpected(errno);
    if (cloexec_pipe(out)) {
        int e = errno;
        close(in[0]), close(in[1]);
        return std::unexpected(e);
    }
    if (cloexec_pipe(err)) {
        int e = errno;
        close(in[0]), close(in[1]), close(out[0]), close(out[1]);
        return std::unexpected(e);
    }
    posix_spawn_file_actions_t fa;
    posix_spawnattr_t at;
    posix_spawn_file_actions_init(&fa);
    posix_spawnattr_init(&at);
    for (auto [from, to] : {std::pair{in[0], 0}, std::pair{out[1], 1}, std::pair{err[1], 2}}) {
        if (from == to)
            posix_spawn_file_actions_addinherit_np(&fa, to);
        else
            posix_spawn_file_actions_adddup2(&fa, from, to);
    }
    if (sp.cwd)
        posix_spawn_file_actions_addchdir(&fa, sp.cwd);
    sigset_t none, all;
    sigemptyset(&none);
    sigfillset(&all);
    posix_spawnattr_setsigmask(&at, &none);
    posix_spawnattr_setsigdefault(&at, &all);
    posix_spawnattr_setpgroup(&at, 0);
    posix_spawnattr_setflags(
        &at, POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF);
    pid_t pid = -1;
    int rc = posix_spawn(&pid, sp.path, &fa, &at, sp.argv, sp.envp ? sp.envp : environ);
    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&at);
    close(in[0]), close(out[1]), close(err[1]);
    if (rc != 0) {
        close(in[1]), close(out[0]), close(err[0]);
        return std::unexpected(rc);
    }
    for (int fd : {in[1], out[0], err[0]})
        (void)fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
    (void)fcntl(in[1], F_SETNOSIGPIPE, 1);
    g_gen[i] = static_cast<std::uint8_t>(g_gen[i] + 1);
    s.id = i | static_cast<std::uint32_t>(g_gen[i]) << 8;
    s.pid = pid;
    s.in_fd = in[1];
    s.out = Stream{out[0], s.out.buf, 0, false, false};
    s.err = Stream{err[0], s.err.buf, 0, false, false};
    s.in_ctl = ByteRingCtl{};
    s.in_w = ByteRingWriter(&s.in_ctl, s.in_data, k_stdin);
    s.in_r = ByteRingReader(&s.in_ctl, s.in_data, k_stdin);
    s.carry_len = s.carry_at = 0;
    s.want_write = false;
    s.v2 = false, s.features = 0, s.rec_left = 0, s.rec_v1 = s.rec_nl = false, s.answer_len = 0, s.delivered = 0,
    s.credit_owed = 0;
    s.flood_said = 0;
    s.code = 0;
    g_used[i] = true;
    if (g_cmds.push(Cmd{Op::add, i}) != sync::Push::Ok) {
        (void)kill(pid, SIGKILL);
        (void)waitpid(pid, nullptr, 0);
        close(in[1]), close(out[0]), close(err[0]);
        g_used[i] = false;
        return std::unexpected(EAGAIN);
    }
    doorbell();
    *pid_out = pid;
    return s.id;
}

static Slot* slot_of(std::uint32_t id) noexcept {
    std::uint32_t i = id & 0xFF;
    return i < k_max && g_used[i] && g_slots[i].id == id ? &g_slots[i] : nullptr;
}

static bool record(std::uint32_t id, std::uint16_t type, std::uint64_t seq, std::string_view payload) noexcept {
    Slot* s = slot_of(id);
    if (!s || payload.size() > REXUI_FRAME_MAX)
        return false;
    std::uint64_t need = REXUI_FRAME_HEADER + payload.size();
    if (s->in_w.space(need) < need)
        return false;
    std::uint8_t h[REXUI_FRAME_HEADER];
    rexui_frame_put_header(h, static_cast<std::uint32_t>(payload.size()), type, 0, seq);
    (void)s->in_w.write({h, sizeof h});
    if (!payload.empty())
        (void)s->in_w.write({reinterpret_cast<const std::uint8_t*>(payload.data()), payload.size()});
    (void)s->in_w.publish();
    doorbell();
    return true;
}

bool send(std::uint32_t id, std::string_view line) noexcept {
    return record(id, REXUI_MESSAGE, 0, line);
}
bool call(std::uint32_t id, std::uint64_t seq, std::string_view json) noexcept {
    return record(id, REXUI_CALL, seq, json);
}

void stop(std::uint32_t id) noexcept {
    Slot* s = slot_of(id);
    if (!s)
        return;
    if (g_cmds.push(Cmd{Op::stop, id & 0xFF}) == sync::Push::Ok)
        doorbell();
}

std::size_t drain(void (*f)(void*, const Event&), void* ctx) noexcept {
    std::size_t n = 0;
    for (;;) {
        Header h;
        if (g_ev_r.read({reinterpret_cast<std::uint8_t*>(&h), sizeof h}) != sizeof h)
            break;
        std::uint32_t len = h.len <= k_line ? h.len : 0;
        if (len && g_ev_r.read({g_line, len}) != len)
            break;
        Event e{h.id, static_cast<Kind>(h.kind), h.code, {reinterpret_cast<const char*>(g_line), len}};
        f(ctx, e);
        n++;
    }
    if (g_ev_r.producer_waiting())
        doorbell();
    return n;
}

void release(std::uint32_t id) noexcept {
    std::uint32_t i = id & 0xFF;
    if (i < k_max && g_used[i] && g_slots[i].id == id)
        g_used[i] = false;
}

bool pending() noexcept {
    return g_started && g_ev_r.pending();
}
void main_sleeping() noexcept {
    g_main_sleep.prepare_sleep();
}
void main_awake() noexcept {
    g_main_sleep.awake();
}

void stop_all() noexcept {
    for (std::uint32_t i = 0; i < k_max; i++)
        if (g_used[i] && g_slots[i].pid > 0)
            (void)kill(g_slots[i].pid, SIGTERM);
}

}
