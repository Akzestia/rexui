// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <atomic>
#include <cstdint>

#include "core/sync/rmw.h"
#include "core/sync/spsc_ring.h"

namespace rx::sync {

template<typename T>
class Triple {
  public:
    [[nodiscard]] auto back() noexcept -> T& { return slot_[back_]; }
    void publish() noexcept {
        const std::uint32_t was = exchange(middle_, back_ | k_fresh, std::memory_order_acq_rel);
        back_ = was & k_index;
    }
    auto take() noexcept -> bool {
        if (!(middle_.load(std::memory_order_relaxed) & k_fresh))
            return false;
        const std::uint32_t was = exchange(middle_, front_, std::memory_order_acq_rel);
        front_ = was & k_index;
        return true;
    }
    [[nodiscard]] auto front() const noexcept -> const T& { return slot_[front_]; }

  private:
    static constexpr std::uint32_t k_fresh = 4, k_index = 3;
    static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
    T slot_[3]{};
    alignas(kCacheLine) std::uint32_t back_ = 0;
    alignas(kCacheLine) std::atomic<std::uint32_t> middle_{1};
    alignas(kCacheLine) std::uint32_t front_ = 2;
};

}
