// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
#pragma once

#include <fcntl.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define REXUI_FRAMES_MAGIC 0x31465852u
#define REXUI_FRAMES_FRESH 4u
#define REXUI_FRAMES_MAX 65536u
#define REXUI_FRAMES_VERSION 1u

typedef struct {
    uint32_t magic;
    uint32_t capacity;
    uint32_t state;
    uint32_t front;
    uint32_t count[3];
    uint32_t version;
} rexui_frames;

static inline size_t rexui_frames_size(uint32_t capacity) {
    return sizeof(rexui_frames) + 3 * (size_t)capacity * sizeof(float);
}

static inline float* rexui_frames_buffer(rexui_frames* f, uint32_t i) {
    return (float*)(f + 1) + (size_t)i * f->capacity;
}

typedef struct {
    rexui_frames* f;
    uint32_t back;
    char name[32];
} rexui_frames_writer;

static inline int rexui_frames_create(rexui_frames_writer* w, const char* name, uint32_t capacity) {
    memset(w, 0, sizeof(*w));
    if (capacity == 0 || capacity > REXUI_FRAMES_MAX || strlen(name) >= sizeof(w->name))
        return -1;
    shm_unlink(name);
    int fd = shm_open(name, O_CREAT | O_EXCL | O_RDWR, 0600);
    if (fd < 0)
        return -1;
    size_t size = rexui_frames_size(capacity);
    if (ftruncate(fd, (off_t)size) != 0) {
        close(fd);
        shm_unlink(name);
        return -1;
    }
    void* p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        shm_unlink(name);
        return -1;
    }
    rexui_frames* f = (rexui_frames*)p;
    f->capacity = capacity;
    f->state = 1;
    f->front = 2;
    f->version = REXUI_FRAMES_VERSION;
    __atomic_store_n(&f->magic, REXUI_FRAMES_MAGIC, __ATOMIC_RELEASE);
    w->f = f;
    w->back = 0;
    strcpy(w->name, name);
    return 0;
}

static inline float* rexui_frames_back(rexui_frames_writer* w) {
    return rexui_frames_buffer(w->f, w->back);
}

static inline void rexui_frames_publish(rexui_frames_writer* w, uint32_t count) {
    w->f->count[w->back] = count < w->f->capacity ? count : w->f->capacity;
    uint32_t prev = __atomic_exchange_n(&w->f->state, w->back | REXUI_FRAMES_FRESH, __ATOMIC_ACQ_REL);
    w->back = prev & 3;
}

static inline void rexui_frames_close(rexui_frames_writer* w) {
    if (!w->f)
        return;
    munmap(w->f, rexui_frames_size(w->f->capacity));
    shm_unlink(w->name);
    w->f = NULL;
}

typedef struct {
    rexui_frames* f;
    uint32_t capacity;
    size_t size;
} rexui_frames_reader;

static inline int rexui_frames_attach(rexui_frames_reader* r, void* p, size_t size) {
    memset(r, 0, sizeof(*r));
    if (size < sizeof(rexui_frames))
        return -1;
    rexui_frames* f = (rexui_frames*)p;
    if (__atomic_load_n(&f->magic, __ATOMIC_ACQUIRE) != REXUI_FRAMES_MAGIC)
        return -1;
    uint32_t capacity = f->capacity;
    if (f->version > REXUI_FRAMES_VERSION || capacity == 0 || capacity > REXUI_FRAMES_MAX
        || rexui_frames_size(capacity) > size)
        return -1;
    r->f = f;
    r->capacity = capacity;
    r->size = size;
    return 0;
}

static inline int rexui_frames_open(rexui_frames_reader* r, const char* name) {
    memset(r, 0, sizeof(*r));
    int fd = shm_open(name, O_RDWR, 0);
    if (fd < 0)
        return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(rexui_frames)) {
        close(fd);
        return -1;
    }
    size_t size = (size_t)st.st_size;
    void* p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED)
        return -1;
    if (rexui_frames_attach(r, p, size) != 0) {
        munmap(p, size);
        return -1;
    }
    shm_unlink(name);
    return 0;
}

static inline const float* rexui_frames_take(rexui_frames_reader* r, uint32_t* count) {
    rexui_frames* f = r->f;
    if (!f || !(__atomic_load_n(&f->state, __ATOMIC_ACQUIRE) & REXUI_FRAMES_FRESH))
        return NULL;
    uint32_t front = __atomic_load_n(&f->front, __ATOMIC_RELAXED) & 3;
    if (front > 2)
        return NULL;
    uint32_t prev = __atomic_exchange_n(&f->state, front, __ATOMIC_ACQ_REL);
    front = prev & 3;
    if (front > 2)
        return NULL;
    __atomic_store_n(&f->front, front, __ATOMIC_RELAXED);
    uint32_t n = f->count[front];
    *count = n < r->capacity ? n : r->capacity;
    return (const float*)(f + 1) + (size_t)front * r->capacity;
}

static inline long rexui_frames_copy(rexui_frames_reader* r, float* out, uint32_t cap) {
    uint32_t count = 0;
    const float* p = rexui_frames_take(r, &count);
    if (!p)
        return -1;
    uint32_t n = count < cap ? count : cap;
    memcpy(out, p, (size_t)n * sizeof(float));
    for (uint32_t i = 0; i < n; i++)
        if (!(out[i] - out[i] == 0.0f))
            out[i] = 0;
    return (long)n;
}

static inline void rexui_frames_unmap(rexui_frames_reader* r) {
    if (r->f)
        munmap(r->f, r->size);
    r->f = NULL;
}
