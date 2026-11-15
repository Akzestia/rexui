// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

void rex_log(const char* msg);

const void* rx_call_self(const void* fn, const void* self, const void* a0, const void* a1);

void rx_call_self6(void* frame);

void rx_wrap_trampoline(void);
void rex_focus_edge(void);
void rx_gate_trampoline(void);
bool rex_activity_asked(void);

void* rx_alloc_box(const void* meta, void** value);

bool rex_body_hook(const void* meta, const void** wt, int slot);
const void* rex_body_capture(void);
bool rex_slide_settings(double* ms, double* curve);
bool rex_slide_vertical(void);
void rexui_panes_now(void);
void rexui_term_arrived(const void* layer);
void panes_attach_now(void);
void panes_tab_switched(void);
void rexui_term_want(const char* ids, const void* parent);
bool rexui_term_fit(double w, double h, double top, double left, double bottom, double right, double gap);
const void* rexui_term_tab(const char* id);
void rexui_term_shown(const char* id);
void rexui_term_wake(const void* layer);
void rexui_shaders_wake(const void* layer);
long rex_session_index(const char* description);

#include "rex/names.h"

#ifdef __cplusplus
}
#endif
