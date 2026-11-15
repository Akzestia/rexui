// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#include <cstddef>
#include <cstdint>

#include "base/analyzer.h"
#include "engine/base/arena.h"
#include "engine/vm/runtime.h"

namespace rx::engine::vm {

class Gc {
  public:
    Gc(Rt& rt, Arena& from, Arena& to, Arena& tmp) noexcept;

    Value value(Value v) noexcept;
    Cell* cell(Cell* c) noexcept;
    template<class T>
    T* of(T* p) noexcept {
        return p ? reinterpret_cast<T*>(cell(&p->h)) : nullptr;
    }
    void* raw(const void* p, size_t n, size_t align = 16) noexcept;
    bool in_from(const void* p) const noexcept;
    void forward_values(Value* v, uint32_t n) noexcept {
        RX_ASSUME(v || !n);
        for (uint32_t i = 0; i < n; i++)
            v[i] = value(v[i]);
    }

    void finish() noexcept;

    Rt& rt;
    Arena& to;
    Arena& tmp;
    bool failed = false;
    uint64_t cells = 0, bytes = 0;

  private:
    struct Range {
        uintptr_t begin, end;
    };
    Range* ranges_ = nullptr;
    uint32_t n_ranges_ = 0;
    struct Fwd {
        const void* from;
        void* to;
    };
    Fwd* map_ = nullptr;
    uint32_t cap_ = 0, count_ = 0;
    List<Cell*> gray_;
    void* find(const void* p) const noexcept;
    bool put(const void* p, void* q) noexcept;
    void scan(Cell* c) noexcept;
};

namespace lib {
size_t gc_size(const Cell* c) noexcept;
void gc_trace(Cell* c, Gc& gc) noexcept;
size_t gc_date_size() noexcept;
size_t gc_set_size() noexcept;
void gc_set_trace(Cell* c, Gc& gc) noexcept;
size_t gc_regexp_size() noexcept;
void gc_regexp_trace(Cell* c, Gc& gc) noexcept;
size_t gc_promise_size(const Cell* c) noexcept;
void gc_promise_trace(Cell* c, Gc& gc) noexcept;
void gc_jobs(Rt& rt, Gc& gc) noexcept;
}

}
