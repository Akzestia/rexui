// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>
#include <new>
#include <utility>

namespace rx::mem {

class FixedPool {
  public:
    explicit FixedPool(std::size_t size, std::size_t slab_bytes = 64 * 1024) noexcept;
    ~FixedPool();
    FixedPool(const FixedPool&) = delete;
    FixedPool& operator=(const FixedPool&) = delete;

    [[nodiscard]] auto alloc() noexcept -> void* {
        Node* n = head_;
        if (n == nullptr) [[unlikely]]
            return refill();
        head_ = n->next;
        ++in_use_;
        return n;
    }

    void free(void* p) noexcept {
        auto* n = static_cast<Node*>(p);
        n->next = head_;
        head_ = n;
        --in_use_;
    }

    [[nodiscard]] auto block_size() const noexcept -> std::size_t { return size_; }
    [[nodiscard]] auto in_use() const noexcept -> std::size_t { return in_use_; }
    [[nodiscard]] auto slabs() const noexcept -> std::size_t { return slabs_; }

  private:
    struct Node {
        Node* next;
    };
    struct Slab {
        Slab* next;
    };
    auto refill() noexcept -> void*;

    Node* head_ = nullptr;
    std::size_t in_use_ = 0;
    std::size_t size_;
    std::size_t per_slab_;
    std::size_t slab_bytes_;
    std::size_t slabs_ = 0;
    Slab* slab_list_ = nullptr;
};

template<typename T>
class TypedPool {
  public:
    explicit TypedPool(std::size_t slab_bytes = 64 * 1024) noexcept : pool_(sizeof(T), slab_bytes) {
        static_assert(alignof(T) <= 16, "TypedPool blocks are 16-byte aligned");
    }

    template<typename... Args>
    [[nodiscard]] auto make(Args&&... args) noexcept -> T* {
        void* p = pool_.alloc();
        return p != nullptr ? new (p) T(std::forward<Args>(args)...) : nullptr;
    }

    void destroy(T* t) noexcept {
        t->~T();
        pool_.free(t);
    }

    [[nodiscard]] auto raw() noexcept -> FixedPool& { return pool_; }
    [[nodiscard]] auto in_use() const noexcept -> std::size_t { return pool_.in_use(); }

  private:
    FixedPool pool_;
};

}
