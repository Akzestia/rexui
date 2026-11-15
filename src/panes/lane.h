// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>

#include "../../apps/sdk/rexpane_lane.h"
#include "core/sync/byte_ring.h"
#include "core/sync/seq.h"

namespace rx::panes {

class Lane {
  public:
    static std::unique_ptr<Lane> make(int* seg, int* bell) noexcept {
        static unsigned n;
        char name[64];
        std::snprintf(name, sizeof name, "/rexui.lane.%d.%u", static_cast<int>(getpid()), ++n);
        shm_unlink(name);
        int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
        if (fd < 0)
            return nullptr;
        shm_unlink(name);
        int p[2] = {-1, -1};
        void* m = MAP_FAILED;
        if (ftruncate(fd, REXPANE_LANE_SIZE) != 0 || pipe(p) != 0
            || (m = mmap(nullptr, REXPANE_LANE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)) == MAP_FAILED) {
            int e = errno;
            close(fd);
            if (p[0] >= 0)
                close(p[0]), close(p[1]);
            errno = e;
            return nullptr;
        }
        for (int f : p)
            (void)fcntl(f, F_SETFD, FD_CLOEXEC);
        (void)fcntl(p[1], F_SETFL, fcntl(p[1], F_GETFL) | O_NONBLOCK);
        (void)fcntl(p[1], F_SETNOSIGPIPE, 1);
        auto l = std::unique_ptr<Lane>(new (std::nothrow) Lane(static_cast<std::uint8_t*>(m), p[1]));
        if (!l) {
            munmap(m, REXPANE_LANE_SIZE);
            close(fd), close(p[0]), close(p[1]);
            return nullptr;
        }
        *seg = fd, *bell = p[0];
        return l;
    }

    ~Lane() {
        munmap(base_, REXPANE_LANE_SIZE);
        if (bell_ >= 0)
            close(bell_);
    }
    Lane(const Lane&) = delete;
    Lane& operator=(const Lane&) = delete;

    bool mouse(const rexpane_mouse& m) noexcept { return put(REXPANE_MOUSE, &m, sizeof m, nullptr, 0); }
    bool event(double x, double y, const std::uint8_t* bytes, std::uint32_t n) noexcept {
        std::uint8_t pre[24];
        std::uint64_t sent = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        std::memcpy(pre, &x, 8), std::memcpy(pre + 8, &y, 8), std::memcpy(pre + 16, &sent, 8);
        return put(REXPANE_EVENT, pre, sizeof pre, bytes, n);
    }

    void move(double dx, double dy) noexcept {
        ax_ += dx, ay_ += dy;
        totals_.store(std::llround(ax_ * REXPANE_FIXED), std::llround(ay_ * REXPANE_FIXED));
    }

    [[nodiscard]] bool broken() const noexcept { return w_.fault(); }

  private:
    Lane(std::uint8_t* base, int bell) noexcept
        : base_(base),
          w_(reinterpret_cast<sync::ByteRingCtl*>(base), base + REXPANE_LANE_DATA, REXPANE_LANE_CAP),
          app_(&reinterpret_cast<sync::ByteRingCtl*>(base)->sleep),
          totals_(base + REXPANE_LANE_TOTALS),
          bell_(bell) {}

    bool put(std::uint16_t kind, const void* a, std::uint32_t an, const void* b, std::uint32_t bn) noexcept {
        std::uint32_t len = an + bn, whole = 8 + len;
        if (whole > REXPANE_LANE_RECORD_MAX || w_.space(whole) < whole)
            return false;
        std::uint8_t h[8] = {static_cast<std::uint8_t>(kind),
                             static_cast<std::uint8_t>(kind >> 8),
                             static_cast<std::uint8_t>(len),
                             static_cast<std::uint8_t>(len >> 8),
                             0,
                             0,
                             0,
                             0};
        (void)w_.write({h, 8});
        (void)w_.write({static_cast<const std::uint8_t*>(a), an});
        if (bn)
            (void)w_.write({static_cast<const std::uint8_t*>(b), bn});
        (void)w_.publish();
        if (app_.needs_ring()) {
            static const std::uint8_t one = 1;
            (void)write(bell_, &one, 1);
        }
        return true;
    }

    std::uint8_t* base_;
    sync::ByteRingWriter w_;
    sync::PeerSleep app_;
    sync::SharedTotals totals_;
    int bell_;
    double ax_ = 0, ay_ = 0;
};

inline bool send_lane(int sock, int seg, int bell) noexcept {
    static const char line[] = "{\"lane\":1}\n";
    struct iovec iov = {const_cast<char*>(line), sizeof line - 1};
    alignas(struct cmsghdr) char ctl[CMSG_SPACE(2 * sizeof(int))] = {};
    struct msghdr msg = {};
    msg.msg_iov = &iov, msg.msg_iovlen = 1, msg.msg_control = ctl, msg.msg_controllen = sizeof ctl;
    struct cmsghdr* c = CMSG_FIRSTHDR(&msg);
    c->cmsg_level = SOL_SOCKET, c->cmsg_type = SCM_RIGHTS, c->cmsg_len = CMSG_LEN(2 * sizeof(int));
    int fds[2] = {seg, bell};
    std::memcpy(CMSG_DATA(c), fds, sizeof fds);
    ssize_t n = sendmsg(sock, &msg, 0);
    if (n > 0 && static_cast<std::size_t>(n) < iov.iov_len)
        (void)write(sock, line + n, iov.iov_len - static_cast<std::size_t>(n));
    close(seg), close(bell);
    return n > 0;
}

}
