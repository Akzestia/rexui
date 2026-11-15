// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
#pragma once

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define REXUI_PROTOCOL 2
#define REXUI_FRAME_HEADER 16u
#define REXUI_FRAME_MAX ((1u << 20) - 64u)
#define REXUI_KEY_MAX 1024u
#define REXUI_CREDIT_START 64u

enum { REXUI_MESSAGE = 1, REXUI_STATE_PATCH = 2, REXUI_CALL = 3, REXUI_REPLY = 4, REXUI_CREDIT = 5 };
enum { REXUI_REPLY_ERROR = 1 };
enum { REXUI_V_NULL = 0, REXUI_V_FALSE = 1, REXUI_V_TRUE = 2, REXUI_V_F64 = 3, REXUI_V_STR = 4, REXUI_V_JSON = 5 };

typedef struct {
    uint32_t len;
    uint16_t type;
    uint16_t flags;
    uint64_t seq;
} rexui_frame_header;

static inline void rexui_put_u16(uint8_t* p, uint16_t v) {
    p[0] = (uint8_t)v, p[1] = (uint8_t)(v >> 8);
}
static inline void rexui_put_u32(uint8_t* p, uint32_t v) {
    for (int i = 0; i < 4; i++)
        p[i] = (uint8_t)(v >> (8 * i));
}
static inline void rexui_put_u64(uint8_t* p, uint64_t v) {
    for (int i = 0; i < 8; i++)
        p[i] = (uint8_t)(v >> (8 * i));
}
static inline uint16_t rexui_get_u16(const uint8_t* p) {
    return (uint16_t)(p[0] | p[1] << 8);
}
static inline uint32_t rexui_get_u32(const uint8_t* p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static inline uint64_t rexui_get_u64(const uint8_t* p) {
    return (uint64_t)rexui_get_u32(p) | (uint64_t)rexui_get_u32(p + 4) << 32;
}

static inline void rexui_frame_put_header(uint8_t out[16], uint32_t len, uint16_t type, uint16_t flags, uint64_t seq) {
    rexui_put_u32(out, len);
    rexui_put_u16(out + 4, type);
    rexui_put_u16(out + 6, flags);
    rexui_put_u64(out + 8, seq);
}

static inline long rexui_frame_scan(const uint8_t* buf, size_t n, rexui_frame_header* h) {
    if (n < REXUI_FRAME_HEADER)
        return 0;
    h->len = rexui_get_u32(buf);
    h->type = rexui_get_u16(buf + 4);
    h->flags = rexui_get_u16(buf + 6);
    h->seq = rexui_get_u64(buf + 8);
    if (h->len > REXUI_FRAME_MAX || h->type == 0)
        return -1;
    size_t whole = REXUI_FRAME_HEADER + (size_t)h->len;
    return n < whole ? 0 : (long)whole;
}

typedef struct {
    uint8_t* buf;
    uint32_t cap, len;
    int full;
} rexui_patch;

static inline void rexui_patch_init(rexui_patch* p, uint8_t* buf, uint32_t cap) {
    p->buf = buf, p->cap = cap, p->len = 0, p->full = 0;
}
static inline int rexui_patch_entry(rexui_patch* p, const char* key, size_t key_len, uint8_t tag, const void* v,
                                    uint32_t v_len) {
    if (key_len == 0 || key_len > REXUI_KEY_MAX)
        return -1;
    size_t extra = tag == REXUI_V_F64 ? 8 : tag == REXUI_V_STR || tag == REXUI_V_JSON ? 4 + (size_t)v_len : 0;
    size_t need = 2 + key_len + 1 + extra;
    if (need > (size_t)(p->cap - p->len))
        return p->full = 1, -1;
    uint8_t* o = p->buf + p->len;
    rexui_put_u16(o, (uint16_t)key_len);
    memcpy(o + 2, key, key_len);
    o += 2 + key_len;
    *o++ = tag;
    if (tag == REXUI_V_F64)
        memcpy(o, v, 8);
    else if (tag == REXUI_V_STR || tag == REXUI_V_JSON)
        rexui_put_u32(o, v_len), memcpy(o + 4, v, v_len);
    p->len += (uint32_t)need;
    return 0;
}
static inline int rexui_patch_f64(rexui_patch* p, const char* key, double v) {
    return rexui_patch_entry(p, key, strlen(key), REXUI_V_F64, &v, 8);
}
static inline int rexui_patch_str(rexui_patch* p, const char* key, const char* s, size_t n) {
    return n > UINT32_MAX ? -1 : rexui_patch_entry(p, key, strlen(key), REXUI_V_STR, s, (uint32_t)n);
}
static inline int rexui_patch_bool(rexui_patch* p, const char* key, int v) {
    return rexui_patch_entry(p, key, strlen(key), v ? REXUI_V_TRUE : REXUI_V_FALSE, NULL, 0);
}
static inline int rexui_patch_null(rexui_patch* p, const char* key) {
    return rexui_patch_entry(p, key, strlen(key), REXUI_V_NULL, NULL, 0);
}
static inline int rexui_patch_json(rexui_patch* p, const char* key, const char* json, size_t n) {
    return n > UINT32_MAX ? -1 : rexui_patch_entry(p, key, strlen(key), REXUI_V_JSON, json, (uint32_t)n);
}

typedef struct {
    const char* key;
    uint32_t key_len;
    uint8_t tag;
    double f64;
    const char* str;
    uint32_t str_len;
} rexui_patch_entry_view;

static inline int rexui_patch_next(const uint8_t* payload, uint32_t n, uint32_t* at, rexui_patch_entry_view* e) {
    uint32_t i = *at;
    if (i == n)
        return 0;
    if (i > n || n - i < 3)
        return -1;
    uint32_t k = rexui_get_u16(payload + i);
    if (k == 0 || k > REXUI_KEY_MAX || n - i - 2 < k + 1)
        return -1;
    e->key = (const char*)payload + i + 2, e->key_len = k;
    i += 2 + k;
    e->tag = payload[i++];
    e->str = NULL, e->str_len = 0, e->f64 = 0;
    switch (e->tag) {
    case REXUI_V_NULL:
    case REXUI_V_FALSE:
    case REXUI_V_TRUE:
        break;
    case REXUI_V_F64:
        if (n - i < 8)
            return -1;
        memcpy(&e->f64, payload + i, 8);
        i += 8;
        break;
    case REXUI_V_STR:
    case REXUI_V_JSON: {
        if (n - i < 4)
            return -1;
        uint32_t l = rexui_get_u32(payload + i);
        if (n - i - 4 < l)
            return -1;
        e->str = (const char*)payload + i + 4, e->str_len = l;
        i += 4 + l;
        break;
    }
    default:
        return -1;
    }
    *at = i;
    return 1;
}
