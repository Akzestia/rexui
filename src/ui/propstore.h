// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once

#import <Foundation/Foundation.h>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>

#include "gen/rx_props.h"

namespace rx::ui {

using rx::schema::Elem;
using rx::schema::Prop;

inline constexpr int k_nprops = static_cast<int>(Prop::count_);
inline constexpr int k_nelems = static_cast<int>(Elem::count_);

struct SlotTable {
    std::array<std::array<int8_t, k_nprops>, k_nelems> at{};
    std::array<uint8_t, k_nelems> count{};
};
inline constexpr SlotTable k_slot_table = [] {
    SlotTable t{};
    for (int e = 0; e < k_nelems; e++) {
        int n = 0;
        for (int p = 0; p < k_nprops; p++)
            t.at[e][p] = rx::schema::has(Elem(e), Prop(p)) ? int8_t(n++) : int8_t(-1);
        t.count[e] = uint8_t(n);
    }
    return t;
}();
static_assert(
    [] {
        for (int e = 0; e < k_nelems; e++) {
            int n = 0;
            for (int p = 0; p < k_nprops; p++)
                n += rx::schema::has(Elem(e), Prop(p));
            if (n > 127)
                return false;
        }
        return true;
    }(),
    "a type's slots must fit an int8_t index");

inline int slot_of(Elem e, Prop p) {
    return k_slot_table.at[static_cast<int>(e)][static_cast<int>(p)];
}

enum class PK : uint8_t { none, num, yes, no, obj };

struct PVal {
    PK k = PK::none;
    double d = 0;
    __unsafe_unretained id o = nil;
};

class PropStore {
   public:
    PropStore() = default;
    PropStore(const PropStore&) = delete;
    PropStore& operator=(const PropStore&) = delete;
    ~PropStore() { reset(); }

    void init(Elem e) {
        reset();
        elem_ = e;
        n_ = static_cast<int>(e) < k_nelems ? k_slot_table.count[static_cast<int>(e)] : 0;
        if (!n_)
            return;
        size_t kb = (n_ + 7u) & ~7u;
        block_ = static_cast<uint8_t*>(calloc(1, kb + size_t(n_) * 8));
        if (!block_)
            n_ = 0;
        vals_ = block_ ? reinterpret_cast<uint64_t*>(block_ + kb) : nullptr;
    }
    Elem elem() const { return elem_; }
    int count() const { return n_; }

    int slot(Prop p) const { return n_ ? slot_of(elem_, p) : -1; }

    PK kind(int i) const { return static_cast<PK>(block_[i]); }
    double num(int i) const {
        double d;
        std::memcpy(&d, &vals_[i], sizeof d);
        return d;
    }
    id obj(int i) const { return (__bridge id) reinterpret_cast<void*>(vals_[i]); }
    PVal get(int i) const {
        PVal v;
        v.k = kind(i);
        if (v.k == PK::num)
            v.d = num(i);
        else if (v.k == PK::obj)
            v.o = obj(i);
        return v;
    }

    void put(int i, const PVal& v) {
        void* old = kind(i) == PK::obj ? reinterpret_cast<void*>(vals_[i]) : nullptr;
        block_[i] = static_cast<uint8_t>(v.k);
        if (v.k == PK::num)
            std::memcpy(&vals_[i], &v.d, sizeof v.d);
        else if (v.k == PK::obj && v.o)
            vals_[i] = reinterpret_cast<uint64_t>((__bridge_retained void*)v.o);
        else {
            if (v.k == PK::obj)
                block_[i] = static_cast<uint8_t>(PK::none);
            vals_[i] = 0;
        }
        if (old)
            CFRelease(old);
    }

   private:
    void reset() {
        for (int i = 0; i < n_; i++)
            if (kind(i) == PK::obj && vals_[i])
                CFRelease(reinterpret_cast<void*>(vals_[i]));
        free(block_);
        block_ = nullptr, vals_ = nullptr, n_ = 0;
    }
    uint8_t* block_ = nullptr;
    uint64_t* vals_ = nullptr;
    int n_ = 0;
    Elem elem_ = Elem::count_;
};

template <class T>
class UidMap {
   public:
    UidMap() = default;
    UidMap(const UidMap&) = delete;
    UidMap& operator=(const UidMap&) = delete;
    ~UidMap() { free(e_); }
    T find(uint32_t uid) const {
        if (!cap_ || !uid)
            return nullptr;
        for (uint32_t h = mix(uid) & (cap_ - 1);; h = (h + 1) & (cap_ - 1)) {
            if (e_[h].uid == uid)
                return e_[h].v;
            if (e_[h].uid == 0)
                return nullptr;
        }
    }
    void put(uint32_t uid, T v) {
        if (!uid)
            return;
        if ((used_ + 1) * 2 > cap_ && !grow())
            return;
        uint32_t h = mix(uid) & (cap_ - 1), tomb = UINT32_MAX;
        for (;; h = (h + 1) & (cap_ - 1)) {
            if (e_[h].uid == uid)
                return (void)(e_[h].v = v);
            if (e_[h].uid == k_tomb && tomb == UINT32_MAX)
                tomb = h;
            if (e_[h].uid == 0)
                break;
        }
        if (tomb != UINT32_MAX)
            h = tomb;
        else
            used_++;
        e_[h].uid = uid, e_[h].v = v;
    }
    void erase(uint32_t uid) {
        if (!cap_ || !uid)
            return;
        for (uint32_t h = mix(uid) & (cap_ - 1);; h = (h + 1) & (cap_ - 1)) {
            if (e_[h].uid == uid)
                return (void)(e_[h].uid = k_tomb, e_[h].v = nullptr);
            if (e_[h].uid == 0)
                return;
        }
    }
    void clear() {
        free(e_);
        e_ = nullptr, cap_ = used_ = 0;
    }

   private:
    static constexpr uint32_t k_tomb = UINT32_MAX;
    struct Entry {
        uint32_t uid;
        T v;
    };
    static uint32_t mix(uint32_t x) { return x * 2654435761u; }
    bool grow() {
        uint32_t cap = cap_ ? cap_ * 2 : 64;
        uint32_t live = 0;
        for (uint32_t i = 0; i < cap_; i++)
            live += e_[i].uid && e_[i].uid != k_tomb;
        while ((live + 1) * 4 > cap)
            cap *= 2;
        if (cap_ && (live + 1) * 4 <= cap_)
            cap = cap_;
        Entry* n = static_cast<Entry*>(calloc(cap, sizeof(Entry)));
        if (!n)
            return false;
        for (uint32_t i = 0; i < cap_; i++) {
            if (!e_[i].uid || e_[i].uid == k_tomb)
                continue;
            uint32_t h = mix(e_[i].uid) & (cap - 1);
            while (n[h].uid)
                h = (h + 1) & (cap - 1);
            n[h] = e_[i];
        }
        free(e_);
        e_ = n, cap_ = cap, used_ = live;
        return true;
    }
    Entry* e_ = nullptr;
    uint32_t cap_ = 0, used_ = 0;
};

inline PVal pval_of(__unsafe_unretained id v) {
    PVal p;
    if (!v || v == (id)kCFNull)
        return p;
    if ([v isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID())
            p.k = [v boolValue] ? PK::yes : PK::no;
        else
            p.k = PK::num, p.d = [v doubleValue];
        return p;
    }
    p.k = PK::obj, p.o = v;
    return p;
}

}
