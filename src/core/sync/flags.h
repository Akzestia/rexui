// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <atomic>
#include <cstdint>

#include "core/sync/rmw.h"
#include "core/sync/spsc_ring.h"

namespace rx::sync {

class alignas(kCacheLine) SleepFlag {
  public:
    void prepare_sleep() noexcept {
        flag_.store(1, std::memory_order_relaxed);
        std::atomic_thread_fence(std::memory_order_seq_cst);
    }
    void awake() noexcept { flag_.store(0, std::memory_order_relaxed); }

    [[nodiscard]] auto needs_wake() const noexcept -> bool {
        std::atomic_thread_fence(std::memory_order_seq_cst);
        return flag_.load(std::memory_order_relaxed) != 0;
    }

  private:
    static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
    std::atomic<std::uint32_t> flag_{0};
};

}
