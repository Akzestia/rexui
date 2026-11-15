// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <atomic>
#include <cstdint>

#include "core/sync/spsc_ring.h"

namespace rx::sync {

class alignas(kCacheLine) Seq {
  public:
    void publish(std::uint64_t v) noexcept { v_.store(v, std::memory_order_release); }
    [[nodiscard]] auto read() const noexcept -> std::uint64_t { return v_.load(std::memory_order_acquire); }

  private:
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
    std::atomic<std::uint64_t> v_{0};
};

class alignas(kCacheLine) Flag {
  public:
    void set(bool on) noexcept { v_.store(on ? 1u : 0u, std::memory_order_release); }
    [[nodiscard]] auto get() const noexcept -> bool { return v_.load(std::memory_order_acquire) != 0; }

  private:
    static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
    std::atomic<std::uint32_t> v_{0};
};

class SharedTotals {
  public:
    SharedTotals() noexcept = default;
    explicit SharedTotals(std::uint8_t* at) noexcept
        : seq_(reinterpret_cast<std::uint64_t*>(at)),
          x_(reinterpret_cast<std::int64_t*>(at + 8)),
          y_(reinterpret_cast<std::int64_t*>(at + 16)) {}

    void store(std::int64_t x, std::int64_t y) noexcept {
        if (!seq_)
            return;
        std::atomic_ref<std::uint64_t>(*seq_).store(++s_, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_release);
        std::atomic_ref<std::int64_t>(*x_).store(x, std::memory_order_relaxed);
        std::atomic_ref<std::int64_t>(*y_).store(y, std::memory_order_relaxed);
        std::atomic_ref<std::uint64_t>(*seq_).store(++s_, std::memory_order_release);
    }

  private:
    static_assert(std::atomic_ref<std::uint64_t>::is_always_lock_free
                  && std::atomic_ref<std::int64_t>::is_always_lock_free);
    std::uint64_t* seq_ = nullptr;
    std::int64_t *x_ = nullptr, *y_ = nullptr;
    std::uint64_t s_ = 0;
};

}
