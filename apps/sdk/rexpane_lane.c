// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: MIT
#include "rexpane_lane.h"

#include <stdlib.h>

#define REXPANE_EXPORT __attribute__((visibility("default"), used))

REXPANE_EXPORT int rexpane_c_version(void) {
    return REXPANE_LANE_VERSION;
}

REXPANE_EXPORT void* rexpane_c_open(int fd) {
    rexpane_lane* l = (rexpane_lane*)calloc(1, sizeof *l);
    if (!l)
        return NULL;
    if (rexpane_lane_map(l, fd) != 0) {
        free(l);
        return NULL;
    }
    return l;
}

REXPANE_EXPORT long rexpane_c_next(void* l, uint8_t* out, uint32_t cap) {
    return rexpane_lane_next((rexpane_lane*)l, out, cap);
}
REXPANE_EXPORT int rexpane_c_idle(void* l) {
    return rexpane_lane_idle((rexpane_lane*)l);
}
REXPANE_EXPORT void rexpane_c_awake(void* l) {
    rexpane_lane_awake((rexpane_lane*)l);
}
REXPANE_EXPORT int rexpane_c_moves(void* l, double* dx, double* dy) {
    return rexpane_lane_moves((rexpane_lane*)l, dx, dy);
}

REXPANE_EXPORT void rexpane_c_close(void* l) {
    if (!l)
        return;
    rexpane_lane_unmap((rexpane_lane*)l);
    free(l);
}
