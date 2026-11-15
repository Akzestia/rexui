// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <new>
#include <string_view>
#include <type_traits>

namespace rx::engine {

class Arena {
  public:
    explicit Arena(size_t block = 64 * 1024) noexcept : block_(block) {}
    ~Arena();
    Arena(const Arena&) = delete;
    Arena& operator=(const Arena&) = delete;

    [[nodiscard]] void* alloc(size_t n, size_t align = 16) noexcept {
        uintptr_t p = (cur_ + (align - 1)) & ~(uintptr_t)(align - 1);
        if (p + n > end_) [[unlikely]]
            return grow(n, align);
        cur_ = p + n;
        return reinterpret_cast<void*>(p);
    }

    template<class T, class... A>
    [[nodiscard]] T* make(A&&... a) noexcept {
        static_assert(std::is_trivially_destructible_v<T>, "arena objects are never destroyed one by one");
        void* p = alloc(sizeof(T), alignof(T));
        return p ? new (p) T{static_cast<A&&>(a)...} : nullptr;
    }
    template<class T>
    [[nodiscard]] T* array(size_t n) noexcept {
        static_assert(std::is_trivially_destructible_v<T>);
        void* p = alloc(sizeof(T) * (n ? n : 1), alignof(T));
        return p ? new (p) T[n ? n : 1]{} : nullptr;
    }
    [[nodiscard]] std::string_view copy(std::string_view s) noexcept {
        if (s.empty())
            return {};
        char* p = static_cast<char*>(alloc(s.size(), 1));
        if (!p)
            return {};
        std::memcpy(p, s.data(), s.size());
        return {p, s.size()};
    }

    void reset() noexcept;
    void swap(Arena& o) noexcept;
    template<class F>
    void each_block(F&& f) const noexcept {
        for (const Block* b = head_; b; b = b->prev) {
            uintptr_t beg = reinterpret_cast<uintptr_t>(b + 1), end = reinterpret_cast<uintptr_t>(b) + b->size;
            f(beg, b == head_ ? cur_ : end);
        }
    }
    size_t used() const noexcept { return used_ + (cur_ - begin_); }
    size_t reserved() const noexcept { return reserved_; }

  private:
    struct Block {
        Block* prev;
        size_t size;
    };
    void* grow(size_t n, size_t align) noexcept;

    size_t block_;
    Block* head_ = nullptr;
    uintptr_t begin_ = 0, cur_ = 0, end_ = 0;
    size_t used_ = 0, reserved_ = 0;
};

template<class T>
struct List {
    static_assert(std::is_trivially_copyable_v<T> && std::is_trivially_destructible_v<T>);
    T* data = nullptr;
    uint32_t size = 0, cap = 0;

    [[nodiscard]] bool push(Arena& a, const T& v) noexcept {
        if (size == cap) {
            uint32_t n = cap ? cap * 2 : 4;
            T* d = static_cast<T*>(a.alloc(sizeof(T) * n, alignof(T)));
            if (!d)
                return false;
            if (size)
                std::memcpy(static_cast<void*>(d), data, sizeof(T) * size);
            data = d;
            cap = n;
        }
        data[size++] = v;
        return true;
    }
    T* begin() const noexcept { return data; }
    T* end() const noexcept { return data + size; }
    T& operator[](uint32_t i) const noexcept { return data[i]; }
    bool empty() const noexcept { return size == 0; }
};

}
