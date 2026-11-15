// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "engine/base/arena.h"

#include <cstdlib>

namespace rx::engine {

Arena::~Arena() {
    for (Block* b = head_; b;) {
        Block* p = b->prev;
        std::free(b);
        b = p;
    }
}

void* Arena::grow(size_t n, size_t align) noexcept {
    size_t need = n + align + sizeof(Block);
    size_t size = need > block_ ? need : block_;
    auto* b = static_cast<Block*>(std::malloc(size));
    if (!b)
        return nullptr;
    if (head_)
        used_ += cur_ - begin_;
    b->prev = head_;
    b->size = size;
    head_ = b;
    reserved_ += size;
    begin_ = reinterpret_cast<uintptr_t>(b + 1);
    end_ = reinterpret_cast<uintptr_t>(b) + size;
    cur_ = begin_;
    uintptr_t p = (cur_ + (align - 1)) & ~(uintptr_t)(align - 1);
    cur_ = p + n;
    return reinterpret_cast<void*>(p);
}

void Arena::swap(Arena& o) noexcept {
    auto sw = [](auto& a, auto& b) {
        auto t = a;
        a = b;
        b = t;
    };
    sw(block_, o.block_), sw(head_, o.head_), sw(begin_, o.begin_), sw(cur_, o.cur_), sw(end_, o.end_);
    sw(used_, o.used_), sw(reserved_, o.reserved_);
}

void Arena::reset() noexcept {
    if (!head_)
        return;
    while (head_->prev) {
        Block* p = head_->prev;
        reserved_ -= head_->size;
        std::free(head_);
        head_ = p;
    }
    begin_ = reinterpret_cast<uintptr_t>(head_ + 1);
    end_ = reinterpret_cast<uintptr_t>(head_) + head_->size;
    cur_ = begin_;
    used_ = 0;
}

}
