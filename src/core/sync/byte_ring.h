// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>

namespace rx::sync {

struct ByteRingCtl {
    alignas(128) std::uint64_t head;
    alignas(128) std::uint64_t tail;
    std::uint32_t fin;
    std::uint32_t want;
    std::uint32_t sleep;
    std::uint8_t pad[256 - 148];
};
static_assert(sizeof(ByteRingCtl) == 256);
static_assert(offsetof(ByteRingCtl, tail) == 128 && offsetof(ByteRingCtl, fin) == 136
              && offsetof(ByteRingCtl, want) == 140 && offsetof(ByteRingCtl, sleep) == 144);
static_assert(std::atomic_ref<std::uint64_t>::is_always_lock_free
              && std::atomic_ref<std::uint32_t>::is_always_lock_free);

namespace detail {
inline auto load64(const std::uint64_t& w, std::memory_order o) noexcept -> std::uint64_t {
    return std::atomic_ref<std::uint64_t>(const_cast<std::uint64_t&>(w)).load(o);
}
inline void store64(std::uint64_t& w, std::uint64_t v, std::memory_order o) noexcept {
    std::atomic_ref<std::uint64_t>(w).store(v, o);
}
inline auto load32(const std::uint32_t& w, std::memory_order o) noexcept -> std::uint32_t {
    return std::atomic_ref<std::uint32_t>(const_cast<std::uint32_t&>(w)).load(o);
}
inline void store32(std::uint32_t& w, std::uint32_t v, std::memory_order o) noexcept {
    std::atomic_ref<std::uint32_t>(w).store(v, o);
}
}

class ByteRingWriter {
  public:
    ByteRingWriter() noexcept = default;
    ByteRingWriter(ByteRingCtl* ctl, std::uint8_t* data, std::uint32_t capacity) noexcept
        : ctl_(ctl), data_(data), cap_(capacity) {}

    auto write(std::span<const std::uint8_t> bytes) noexcept -> std::size_t {
        if (fault_ || fin_ || bytes.empty())
            return 0;
        std::uint64_t free = cap_ - (tail_ - head_);
        if (free < bytes.size()) {
            refresh_head();
            if (fault_)
                return 0;
            free = cap_ - (tail_ - head_);
        }
        const std::size_t n = bytes.size() < free ? bytes.size() : static_cast<std::size_t>(free);
        const std::size_t at = static_cast<std::size_t>(tail_ & (cap_ - 1));
        const std::size_t first = n < cap_ - at ? n : cap_ - at;
        std::memcpy(data_ + at, bytes.data(), first);
        std::memcpy(data_, bytes.data() + first, n - first);
        tail_ += n;
        return n;
    }

    auto publish() noexcept -> bool {
        if (tail_ == published_)
            return false;
        detail::store64(ctl_->tail, tail_, std::memory_order_release);
        published_ = tail_;
        return true;
    }

    void finish() noexcept {
        if (fin_)
            return;
        (void)publish();
        detail::store32(ctl_->fin, 1, std::memory_order_release);
        fin_ = true;
    }

    auto block() noexcept -> std::uint64_t {
        if ((want_ & 1) == 0) {
            ++want_;
            detail::store32(ctl_->want, want_, std::memory_order_relaxed);
            std::atomic_thread_fence(std::memory_order_seq_cst);
        }
        refresh_head();
        return fault_ ? 0 : cap_ - (tail_ - head_);
    }
    void unblock() noexcept {
        if ((want_ & 1) != 0) {
            ++want_;
            detail::store32(ctl_->want, want_, std::memory_order_relaxed);
        }
    }
    [[nodiscard]] auto blocked() const noexcept -> bool { return (want_ & 1) != 0; }

    [[nodiscard]] auto head_moved() const noexcept -> bool {
        return ctl_ != nullptr && detail::load64(ctl_->head, std::memory_order_relaxed) != head_;
    }

    [[nodiscard]] auto fault() const noexcept -> bool { return fault_; }
    [[nodiscard]] auto finished() const noexcept -> bool { return fin_; }
    [[nodiscard]] auto capacity() const noexcept -> std::uint32_t { return static_cast<std::uint32_t>(cap_); }
    [[nodiscard]] auto written() const noexcept -> std::uint64_t { return tail_; }
    [[nodiscard]] auto valid() const noexcept -> bool { return ctl_ != nullptr; }
    [[nodiscard]] auto space(std::uint64_t want) noexcept -> std::uint64_t {
        if (fault_ || fin_)
            return 0;
        if (cap_ - (tail_ - head_) < want)
            refresh_head();
        return fault_ ? 0 : cap_ - (tail_ - head_);
    }

  private:
    void refresh_head() noexcept {
        const std::uint64_t h = detail::load64(ctl_->head, std::memory_order_acquire);
        if (h < head_ || h > published_) {
            fault_ = true;
            return;
        }
        head_ = h;
    }

    ByteRingCtl* ctl_ = nullptr;
    std::uint8_t* data_ = nullptr;
    std::uint64_t cap_ = 0;
    std::uint64_t tail_ = 0;
    std::uint64_t published_ = 0;
    std::uint64_t head_ = 0;
    std::uint32_t want_ = 0;
    bool fin_ = false;
    bool fault_ = false;
};

class ByteRingReader {
  public:
    ByteRingReader() noexcept = default;
    ByteRingReader(ByteRingCtl* ctl, const std::uint8_t* data, std::uint32_t capacity) noexcept
        : ctl_(ctl), data_(data), cap_(capacity) {}

    auto read(std::span<std::uint8_t> out) noexcept -> std::size_t {
        if (fault_ || out.empty())
            return 0;
        if (tail_ - head_ < out.size()) {
            refresh();
            if (fault_ || tail_ == head_)
                return 0;
        }
        const std::uint64_t avail = tail_ - head_;
        const std::size_t n = out.size() < avail ? out.size() : static_cast<std::size_t>(avail);
        const std::size_t at = static_cast<std::size_t>(head_ & (cap_ - 1));
        const std::size_t first = n < cap_ - at ? n : cap_ - at;
        std::memcpy(out.data(), data_ + at, first);
        std::memcpy(out.data() + first, data_, n - first);
        head_ += n;
        detail::store64(ctl_->head, head_, std::memory_order_release);
        freed_ = true;
        return n;
    }

    [[nodiscard]] auto producer_waiting() noexcept -> bool {
        if (!freed_)
            return false;
        freed_ = false;
        std::atomic_thread_fence(std::memory_order_seq_cst);
        return (detail::load32(ctl_->want, std::memory_order_relaxed) & 1) != 0;
    }

    [[nodiscard]] auto pending() const noexcept -> bool {
        if (ctl_ == nullptr || fault_ || at_end_)
            return false;
        return detail::load64(ctl_->tail, std::memory_order_relaxed) != head_
            || detail::load32(ctl_->fin, std::memory_order_relaxed) != 0;
    }

    [[nodiscard]] auto at_end() noexcept -> bool {
        if (at_end_ || fault_)
            return at_end_;
        if (tail_ == head_)
            refresh();
        at_end_ = !fault_ && fin_ && tail_ == head_;
        return at_end_;
    }

    [[nodiscard]] auto fault() const noexcept -> bool { return fault_; }
    [[nodiscard]] auto consumed() const noexcept -> std::uint64_t { return head_; }
    [[nodiscard]] auto valid() const noexcept -> bool { return ctl_ != nullptr; }

  private:
    void refresh() noexcept {
        const std::uint32_t f = detail::load32(ctl_->fin, std::memory_order_acquire);
        const std::uint64_t t = detail::load64(ctl_->tail, std::memory_order_acquire);
        if (f > 1 || t < tail_ || t - head_ > cap_ || (fin_ && t != tail_)) {
            fault_ = true;
            return;
        }
        tail_ = t;
        fin_ = fin_ || f == 1;
    }

    ByteRingCtl* ctl_ = nullptr;
    const std::uint8_t* data_ = nullptr;
    std::uint64_t cap_ = 0;
    std::uint64_t head_ = 0;
    std::uint64_t tail_ = 0;
    bool fin_ = false;
    bool at_end_ = false;
    bool freed_ = false;
    bool fault_ = false;
};

class SideSleep {
  public:
    SideSleep() noexcept = default;
    explicit SideSleep(std::uint32_t* word) noexcept : w_(word) {}

    void prepare_sleep() noexcept {
        mark();
        fence();
    }
    void mark() noexcept {
        if ((seq_ & 1) == 0) {
            ++seq_;
            detail::store32(*w_, seq_, std::memory_order_relaxed);
        }
    }
    static void fence() noexcept { std::atomic_thread_fence(std::memory_order_seq_cst); }
    void awake() noexcept {
        if ((seq_ & 1) != 0) {
            ++seq_;
            detail::store32(*w_, seq_, std::memory_order_relaxed);
        }
    }

  private:
    std::uint32_t* w_ = nullptr;
    std::uint32_t seq_ = 0;
};

class PeerSleep {
  public:
    PeerSleep() noexcept = default;
    explicit PeerSleep(const std::uint32_t* word) noexcept : w_(word) {}

    [[nodiscard]] auto needs_ring() noexcept -> bool {
        std::atomic_thread_fence(std::memory_order_seq_cst);
        const std::uint32_t v = detail::load32(*w_, std::memory_order_relaxed);
        if ((v & 1) == 0 || v == rung_)
            return false;
        rung_ = v;
        return true;
    }

  private:
    const std::uint32_t* w_ = nullptr;
    std::uint32_t rung_ = 0;
};

}
