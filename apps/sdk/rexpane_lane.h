// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
#pragma once

#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define REXPANE_LANE_VERSION 1
#define REXPANE_LANE_CTL 256u
#define REXPANE_LANE_TOTALS 256u
#define REXPANE_LANE_DATA 384u
#define REXPANE_LANE_CAP 65536u
#define REXPANE_LANE_SIZE (REXPANE_LANE_DATA + REXPANE_LANE_CAP)
#define REXPANE_LANE_RECORD_MAX 4096u
#define REXPANE_FIXED 65536.0

enum { REXPANE_MOUSE = 1, REXPANE_EVENT = 2 };

typedef struct {
    uint32_t type;
    uint32_t button;
    uint64_t flags;
    double x, y;
    double dx, dy;
    int32_t clicks;
    uint32_t number;
    uint64_t sent;
} rexpane_mouse;
#ifdef __cplusplus
static_assert(sizeof(rexpane_mouse) == 64, "rexpane_mouse is 64 bytes");
#else
_Static_assert(sizeof(rexpane_mouse) == 64, "rexpane_mouse is 64 bytes");
#endif

typedef struct {
    uint8_t* base;
    uint64_t head, tail;
    uint32_t sleep_seq;
    int64_t read_dx, read_dy;
    int fault;
} rexpane_lane;

static inline uint64_t* rexpane_lane_u64_(uint8_t* b, uint32_t at) {
    return (uint64_t*)(b + at);
}
static inline uint32_t* rexpane_lane_sleep_(uint8_t* b) {
    return (uint32_t*)(b + 144);
}

static inline int rexpane_lane_map(rexpane_lane* l, int fd) {
    memset(l, 0, sizeof(*l));
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)REXPANE_LANE_SIZE)
        return -1;
    void* p = mmap(NULL, REXPANE_LANE_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED)
        return -1;
    l->base = (uint8_t*)p;
    return 0;
}

static inline long rexpane_lane_next(rexpane_lane* l, uint8_t* out, uint32_t cap) {
    if (!l->base || l->fault)
        return -1;
    if (l->tail - l->head < 8) {
        uint64_t t = __atomic_load_n(rexpane_lane_u64_(l->base, 128), __ATOMIC_ACQUIRE);
        if (t < l->tail || t - l->head > REXPANE_LANE_CAP)
            return l->fault = 1, -1;
        l->tail = t;
        if (t - l->head < 8)
            return 0;
    }
    const uint8_t* data = l->base + REXPANE_LANE_DATA;
    uint8_t h[8];
    for (uint32_t i = 0; i < 8; i++)
        h[i] = data[(l->head + i) & (REXPANE_LANE_CAP - 1)];
    uint32_t len = (uint32_t)h[2] | (uint32_t)h[3] << 8, whole = 8 + len;
    if (whole > REXPANE_LANE_RECORD_MAX || whole > cap || l->tail - l->head < whole)
        return l->fault = 1, -1;
    uint32_t at = (uint32_t)(l->head & (REXPANE_LANE_CAP - 1)),
             first = whole < REXPANE_LANE_CAP - at ? whole : REXPANE_LANE_CAP - at;
    memcpy(out, data + at, first);
    memcpy(out + first, data, whole - first);
    l->head += whole;
    __atomic_store_n(rexpane_lane_u64_(l->base, 0), l->head, __ATOMIC_RELEASE);
    return (long)whole;
}

static inline int rexpane_lane_idle(rexpane_lane* l) {
    if (!l->base)
        return 0;
    if (!(l->sleep_seq & 1)) {
        l->sleep_seq++;
        __atomic_store_n(rexpane_lane_sleep_(l->base), l->sleep_seq, __ATOMIC_RELAXED);
    }
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    return __atomic_load_n(rexpane_lane_u64_(l->base, 128), __ATOMIC_RELAXED) != l->head;
}
static inline void rexpane_lane_awake(rexpane_lane* l) {
    if (l->base && (l->sleep_seq & 1)) {
        l->sleep_seq++;
        __atomic_store_n(rexpane_lane_sleep_(l->base), l->sleep_seq, __ATOMIC_RELAXED);
    }
}

static inline int rexpane_lane_moves(rexpane_lane* l, double* dx, double* dy) {
    *dx = *dy = 0;
    if (!l->base)
        return 0;
    uint64_t* seq = rexpane_lane_u64_(l->base, REXPANE_LANE_TOTALS);
    int64_t *tx = (int64_t*)(l->base + REXPANE_LANE_TOTALS + 8), *ty = (int64_t*)(l->base + REXPANE_LANE_TOTALS + 16);
    for (int tries = 0; tries < 64; tries++) {
        uint64_t s1 = __atomic_load_n(seq, __ATOMIC_ACQUIRE);
        if (s1 & 1)
            continue;
        int64_t x = __atomic_load_n(tx, __ATOMIC_RELAXED), y = __atomic_load_n(ty, __ATOMIC_RELAXED);
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(seq, __ATOMIC_RELAXED) != s1)
            continue;
        if (x == l->read_dx && y == l->read_dy)
            return 0;
        *dx = (double)(x - l->read_dx) / REXPANE_FIXED, *dy = (double)(y - l->read_dy) / REXPANE_FIXED;
        l->read_dx = x, l->read_dy = y;
        return 1;
    }
    return 0;
}

static inline void rexpane_lane_unmap(rexpane_lane* l) {
    if (l->base)
        munmap(l->base, REXPANE_LANE_SIZE);
    l->base = NULL;
}
