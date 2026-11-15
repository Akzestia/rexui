// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <new>
#include <type_traits>

namespace rx::sync {

enum class Push : std::uint8_t { Ok, Full };

inline constexpr std::size_t kCacheLine = 64;

template<typename T, std::size_t N>
    requires(std::is_trivially_copyable_v<T> && N >= 2 && (N & (N - 1)) == 0)
class SpscRing {
  public:
    SpscRing() noexcept = default;
    SpscRing(const SpscRing&) = delete;

    [[nodiscard]] auto push(const T& v) noexcept -> Push {
        const std::uint64_t t = tail_.load(std::memory_order_relaxed);
        if (t - prod_.cached_head >= N) {
            prod_.cached_head = head_.load(std::memory_order_acquire);
            if (t - prod_.cached_head >= N)
                return Push::Full;
        }
        cells_[t & (N - 1)] = v;
        tail_.store(t + 1, std::memory_order_release);
        return Push::Ok;
    }

    [[nodiscard]] auto pop(T& out) noexcept -> bool {
        const std::uint64_t h = head_.load(std::memory_order_relaxed);
        if (h == cons_.cached_tail) {
            cons_.cached_tail = tail_.load(std::memory_order_acquire);
            if (h == cons_.cached_tail)
                return false;
        }
        out = cells_[h & (N - 1)];
        head_.store(h + 1, std::memory_order_release);
        return true;
    }

    auto pop_batch(T* out, std::size_t max) noexcept -> std::size_t {
        const std::uint64_t h = head_.load(std::memory_order_relaxed);
        if (cons_.cached_tail - h < max)
            cons_.cached_tail = tail_.load(std::memory_order_acquire);
        std::size_t n = static_cast<std::size_t>(cons_.cached_tail - h);
        if (n > max)
            n = max;
        for (std::size_t i = 0; i < n; ++i)
            out[i] = cells_[(h + i) & (N - 1)];
        if (n != 0)
            head_.store(h + n, std::memory_order_release);
        return n;
    }

    [[nodiscard]] auto size_approx() const noexcept -> std::size_t {
        return static_cast<std::size_t>(tail_.load(std::memory_order_relaxed) - head_.load(std::memory_order_relaxed));
    }

    static constexpr std::size_t capacity = N;

  private:
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free);

    alignas(kCacheLine) std::atomic<std::uint64_t> head_{0};
    alignas(kCacheLine) struct {
        std::uint64_t cached_tail = 0;
    } cons_;
    alignas(kCacheLine) std::atomic<std::uint64_t> tail_{0};
    alignas(kCacheLine) struct {
        std::uint64_t cached_head = 0;
    } prod_;
    alignas(kCacheLine) T cells_[N];
};

}
