// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "core/mem/pool.h"

#include <algorithm>
#include <cstdlib>

namespace rx::mem {

namespace {

constexpr std::size_t kAlign = 16;
constexpr std::size_t kHeader = kAlign;

}

FixedPool::FixedPool(std::size_t size, std::size_t slab_bytes) noexcept
    : size_((std::max(size, sizeof(Node)) + kAlign - 1) / kAlign * kAlign) {
    per_slab_ = std::max<std::size_t>(1, (slab_bytes - kHeader) / size_);
    slab_bytes_ = kHeader + per_slab_ * size_;
}

FixedPool::~FixedPool() {
    while (slab_list_ != nullptr) {
        Slab* next = slab_list_->next;
        std::free(slab_list_);
        slab_list_ = next;
    }
}

auto FixedPool::refill() noexcept -> void* {
    void* mem = std::aligned_alloc(kAlign, (slab_bytes_ + kAlign - 1) / kAlign * kAlign);
    if (mem == nullptr)
        return nullptr;
    auto* slab = static_cast<Slab*>(mem);
    slab->next = slab_list_;
    slab_list_ = slab;
    ++slabs_;
    auto* base = static_cast<char*>(mem) + kHeader;
    for (std::size_t i = per_slab_; i-- > 1;) {
        auto* n = reinterpret_cast<Node*>(base + i * size_);
        n->next = head_;
        head_ = n;
    }
    ++in_use_;
    return base;
}

}
