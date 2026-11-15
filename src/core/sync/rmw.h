// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <atomic>
#include <cstdint>

namespace rx::sync {

namespace detail {
inline thread_local std::uint64_t t_rmw = 0;
}

[[nodiscard]] inline auto rmw_count() noexcept -> std::uint64_t {
    return detail::t_rmw;
}

template<typename T>
auto fetch_add(std::atomic<T>& a, T v, std::memory_order o) noexcept -> T {
    static_assert(std::atomic<T>::is_always_lock_free);
    ++detail::t_rmw;
    return a.fetch_add(v, o);
}

template<typename T>
auto fetch_sub(std::atomic<T>& a, T v, std::memory_order o) noexcept -> T {
    static_assert(std::atomic<T>::is_always_lock_free);
    ++detail::t_rmw;
    return a.fetch_sub(v, o);
}

template<typename T>
auto exchange(std::atomic<T>& a, T v, std::memory_order o) noexcept -> T {
    static_assert(std::atomic<T>::is_always_lock_free);
    ++detail::t_rmw;
    return a.exchange(v, o);
}

template<typename T>
auto compare_exchange(std::atomic<T>& a, T& expected, T desired, std::memory_order o) noexcept -> bool {
    static_assert(std::atomic<T>::is_always_lock_free);
    ++detail::t_rmw;
    return a.compare_exchange_strong(expected, desired, o);
}

}
