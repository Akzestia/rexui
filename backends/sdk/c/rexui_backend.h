// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
#pragma once

#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "rexui_proto.h"

#define REXUI_SDK_KEYS 512u

typedef struct {
    char* key;
    size_t key_len;
    char* sent;
    size_t sent_len;
    char* held;
    size_t held_len;
} rexui_sdk_key;

typedef struct {
    pthread_mutex_t lock;
    rexui_sdk_key keys[REXUI_SDK_KEYS];
    unsigned nkeys;
    long credit;
    uint8_t* in;
    size_t in_len, in_cap;
    char** early;
    size_t nearly, early_at;
    void (*on_call)(uint64_t seq, const char* json, size_t n);
} rexui_sdk;

static inline rexui_sdk* rexui_sdk_get(void) {
    static rexui_sdk s;
    static int ready;
    if (!ready) {
        pthread_mutex_init(&s.lock, NULL);
        s.credit = -1;
        ready = 1;
    }
    return &s;
}

static inline void rexui_sdk_write(const void* p, size_t n) {
    const uint8_t* b = (const uint8_t*)p;
    while (n) {
        ssize_t w = write(1, b, n);
        if (w <= 0)
            exit(0);
        b += w, n -= (size_t)w;
    }
}
static inline void rexui_sdk_frame(uint16_t type, uint16_t flags, uint64_t seq, const void* payload, uint32_t len) {
    uint8_t h[REXUI_FRAME_HEADER];
    rexui_frame_put_header(h, len, type, flags, seq);
    rexui_sdk_write(h, sizeof h);
    if (len)
        rexui_sdk_write(payload, len);
}
static inline int rexui_sdk_fill(rexui_sdk* s) {
    if (s->in_cap - s->in_len < 65536) {
        size_t cap = s->in_cap ? s->in_cap * 2 : 1 << 17;
        uint8_t* b = (uint8_t*)realloc(s->in, cap);
        if (!b)
            exit(1);
        s->in = b, s->in_cap = cap;
    }
    ssize_t n = read(0, s->in + s->in_len, s->in_cap - s->in_len);
    if (n <= 0)
        return 0;
    s->in_len += (size_t)n;
    return 1;
}
static inline void rexui_sdk_eat(rexui_sdk* s, size_t n) {
    memmove(s->in, s->in + n, s->in_len - n);
    s->in_len -= n;
}

static inline void rexui_begin(void) {
    rexui_sdk* s = rexui_sdk_get();
    const char* hello = "{\"rexui\":{\"protocol\":2,\"features\":[\"patch\",\"call\",\"credit\"]}}\n";
    rexui_sdk_write(hello, strlen(hello));
    for (;;) {
        uint8_t* nl;
        while (!(nl = (uint8_t*)memchr(s->in, '\n', s->in_len)))
            if (!rexui_sdk_fill(s))
                exit(0);
        size_t n = (size_t)(nl - s->in);
        if (n >= 9 && !memcmp(s->in, "{\"rexui\":", 9)) {
            const char* c = (const char*)memmem(s->in, n, "\"credit\":", 9);
            if (c)
                s->credit = strtol(c + 9, NULL, 10);
            rexui_sdk_eat(s, n + 1);
            return;
        }
        char** e = (char**)realloc(s->early, (s->nearly + 1) * sizeof *e);
        if (!e)
            exit(1);
        s->early = e;
        s->early[s->nearly] = (char*)malloc(n + 1);
        memcpy(s->early[s->nearly], s->in, n), s->early[s->nearly][n] = 0;
        s->nearly++;
        rexui_sdk_eat(s, n + 1);
    }
}

static inline void rexui_sdk_flush(rexui_sdk* s) {
    while (s->credit != 0) {
        size_t need = 0;
        for (unsigned i = 0; i < s->nkeys; i++) {
            rexui_sdk_key* k = &s->keys[i];
            if (!k->held)
                continue;
            size_t entry = 2 + k->key_len + 1 + 4 + k->held_len;
            if (entry > REXUI_FRAME_MAX) {
                fprintf(stderr, "rexui: state %.*s: %zu bytes, more than a frame holds (%u); not sent\n",
                        (int)(k->key_len < 64 ? k->key_len : 64), k->key, k->held_len, REXUI_FRAME_MAX);
                free(k->sent);
                k->sent = k->held, k->sent_len = k->held_len;
                k->held = NULL, k->held_len = 0;
                continue;
            }
            need += entry;
        }
        if (!need)
            return;
        if (need > REXUI_FRAME_MAX)
            need = REXUI_FRAME_MAX;
        uint8_t* buf = (uint8_t*)malloc(need);
        if (!buf)
            return;
        rexui_patch p;
        rexui_patch_init(&p, buf, (uint32_t)need);
        for (unsigned i = 0; i < s->nkeys; i++) {
            rexui_sdk_key* k = &s->keys[i];
            if (!k->held)
                continue;
            if (rexui_patch_entry(&p, k->key, k->key_len, REXUI_V_JSON, k->held, (uint32_t)k->held_len) != 0)
                continue;
            free(k->sent);
            k->sent = k->held, k->sent_len = k->held_len;
            k->held = NULL, k->held_len = 0;
        }
        if (p.len)
            rexui_sdk_frame(REXUI_STATE_PATCH, 0, 0, buf, p.len);
        free(buf);
        if (s->credit > 0)
            s->credit--;
    }
}

static inline size_t rexui_sdk_skip(const char* t, size_t i, size_t n) {
    int depth = 0;
    int in_str = 0;
    size_t start = i;
    for (; i < n; i++) {
        char c = t[i];
        if (in_str) {
            if (c == '\\')
                i++;
            else if (c == '"') {
                in_str = 0;
                if (!depth)
                    return i + 1;
            }
            continue;
        }
        if (c == '"')
            in_str = 1;
        else if (c == '{' || c == '[')
            depth++;
        else if (c == '}' || c == ']') {
            if (!depth)
                return i > start ? i : 0;
            if (--depth == 0)
                return i + 1;
        } else if (!depth && (c == ','))
            return i > start ? i : 0;
    }
    return depth || in_str ? 0 : n;
}

static inline int rexui_state_json(const char* t, size_t n) {
    rexui_sdk* s = rexui_sdk_get();
    size_t i = 0;
    while (i < n && (t[i] == ' ' || t[i] == '\n' || t[i] == '\t' || t[i] == '\r'))
        i++;
    if (i >= n || t[i] != '{')
        return -1;
    i++;
    pthread_mutex_lock(&s->lock);
    for (;;) {
        while (i < n && (t[i] == ' ' || t[i] == '\n' || t[i] == '\t' || t[i] == '\r' || t[i] == ','))
            i++;
        if (i >= n || t[i] == '}')
            break;
        if (t[i] != '"')
            break;
        size_t ks = ++i;
        while (i < n && t[i] != '"')
            i += t[i] == '\\' ? 2 : 1;
        if (i >= n)
            break;
        size_t kl = i - ks;
        i++;
        while (i < n && (t[i] == ' ' || t[i] == ':'))
            i++;
        size_t vs = i, ve = rexui_sdk_skip(t, i, n);
        if (!ve)
            break;
        while (ve > vs && (t[ve - 1] == ' ' || t[ve - 1] == '\n'))
            ve--;
        i = ve;
        rexui_sdk_key* k = NULL;
        for (unsigned j = 0; j < s->nkeys && !k; j++)
            if (s->keys[j].key_len == kl && !memcmp(s->keys[j].key, t + ks, kl))
                k = &s->keys[j];
        if (!k) {
            if (s->nkeys == REXUI_SDK_KEYS || kl == 0 || kl > REXUI_KEY_MAX)
                continue;
            k = &s->keys[s->nkeys++];
            memset(k, 0, sizeof *k);
            k->key = (char*)malloc(kl), memcpy(k->key, t + ks, kl), k->key_len = kl;
        }
        size_t vl = ve - vs;
        if (k->sent && k->sent_len == vl && !memcmp(k->sent, t + vs, vl)) {
            free(k->held), k->held = NULL, k->held_len = 0;
            continue;
        }
        if (k->held && k->held_len == vl && !memcmp(k->held, t + vs, vl))
            continue;
        free(k->held);
        k->held = (char*)malloc(vl ? vl : 1), memcpy(k->held, t + vs, vl), k->held_len = vl;
    }
    rexui_sdk_flush(s);
    pthread_mutex_unlock(&s->lock);
    return 0;
}

static inline int rexui_message(const char* json, size_t n) {
    if (n > REXUI_FRAME_MAX) {
        fprintf(stderr, "rexui: a message of %zu bytes, more than a frame holds (%u); not sent\n", n, REXUI_FRAME_MAX);
        return -1;
    }
    rexui_sdk* s = rexui_sdk_get();
    pthread_mutex_lock(&s->lock);
    rexui_sdk_frame(REXUI_MESSAGE, 0, 0, json, (uint32_t)n);
    pthread_mutex_unlock(&s->lock);
    return 0;
}

static inline void rexui_reply(uint64_t seq, int error, const char* json, size_t n) {
    static const char too_big[] = "\"the answer is more than a frame holds\"";
    if (n > REXUI_FRAME_MAX)
        error = 1, json = too_big, n = sizeof too_big - 1;
    rexui_sdk* s = rexui_sdk_get();
    pthread_mutex_lock(&s->lock);
    rexui_sdk_frame(REXUI_REPLY, error ? REXUI_REPLY_ERROR : 0, seq, json, (uint32_t)n);
    pthread_mutex_unlock(&s->lock);
}
static inline void rexui_on_call(void (*fn)(uint64_t seq, const char* json, size_t n)) {
    rexui_sdk_get()->on_call = fn;
}

static inline long rexui_read_for(const char** msg, int ms);
static inline long rexui_read(const char** msg) {
    return rexui_read_for(msg, -1);
}

static inline long rexui_read_for(const char** msg, int ms) {
    rexui_sdk* s = rexui_sdk_get();
    static char* last;
    if (s->early_at < s->nearly) {
        free(last);
        last = s->early[s->early_at++];
        *msg = last;
        return (long)strlen(last);
    }
    static size_t pending;
    if (pending)
        rexui_sdk_eat(s, pending), pending = 0;
    for (;;) {
        rexui_frame_header h;
        long whole;
        while ((whole = rexui_frame_scan(s->in, s->in_len, &h)) == 0) {
            if (ms >= 0) {
                struct pollfd fd = {0, POLLIN, 0};
                if (poll(&fd, 1, ms) == 0)
                    return -2;
            }
            if (!rexui_sdk_fill(s))
                return -1;
        }
        if (whole < 0)
            exit(1);
        const char* payload = (const char*)s->in + REXUI_FRAME_HEADER;
        if (h.type == REXUI_MESSAGE) {
            pending = (size_t)whole;
            *msg = payload;
            return (long)h.len;
        }
        if (h.type == REXUI_CREDIT && h.len == 4) {
            pthread_mutex_lock(&s->lock);
            if (s->credit >= 0)
                s->credit += rexui_get_u32((const uint8_t*)payload);
            rexui_sdk_flush(s);
            pthread_mutex_unlock(&s->lock);
        } else if (h.type == REXUI_CALL) {
            if (s->on_call)
                s->on_call(h.seq, payload, h.len);
            else
                rexui_reply(h.seq, 1, "\"this backend takes no calls\"", 29);
        }
        rexui_sdk_eat(s, (size_t)whole);
    }
}
