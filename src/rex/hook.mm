// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <objc/runtime.h>
#include <algorithm>
#include <cstdlib>
#import "base/rexui.h"
#include "rex/bridge.h"

void rex_log(const char* msg) {
    rexui_log([NSString stringWithUTF8String:msg]);
}

namespace {

struct ValueWitnesses {
    void *initializeBufferWithCopyOfBuffer, *destroy, *initializeWithCopy, *assignWithCopy, *initializeWithTake,
        *assignWithTake, *getEnumTagSinglePayload, *storeEnumTagSinglePayload;
    size_t size, stride;
    uint32_t flags, extraInhabitants;
};

const ValueWitnesses* vwt_of(const void* meta) {
    return ((const ValueWitnesses* const*)meta)[-1];
}

}

struct BodyHook {
    const void* meta;
    const void** slot;
    const void* original;
    void* copy;
};
extern "C" BodyHook* g_rex_body_hook;
BodyHook* g_rex_body_hook;

extern "C" void rex_tabs_rendered(void);
extern "C" void rexui_tabs_rendered(void);

extern "C" void rex_body_capture_self(void* self) {
    BodyHook* h = g_rex_body_hook;
    const ValueWitnesses* w = vwt_of(h->meta);
    void* buf = malloc(w->size ? w->size : 1);
    ((void* (*)(void*, void*, const void*))w->initializeWithCopy)(buf, self, h->meta);
    if (h->copy) {
        ((void (*)(void*, const void*))w->destroy)(h->copy, h->meta);
        free(h->copy);
    }
    h->copy = buf;
    rex_tabs_rendered();
    rexui_tabs_rendered();
}

__asm__(".text\n"
        ".p2align 2\n"
        "_rex_body_trampoline:\n"
        "    stp x29, x30, [sp, #-64]!\n"
        "    mov x29, sp\n"
        "    stp x0, x1, [sp, #16]\n"
        "    stp x2, x3, [sp, #32]\n"
        "    str x8, [sp, #48]\n"
        "    mov x0, x20\n"
        "    bl _rex_body_capture_self\n"
        "    ldp x0, x1, [sp, #16]\n"
        "    ldp x2, x3, [sp, #32]\n"
        "    ldr x8, [sp, #48]\n"
        "    ldp x29, x30, [sp], #64\n"
        "    adrp x16, _g_rex_body_hook@PAGE\n"
        "    ldr x16, [x16, _g_rex_body_hook@PAGEOFF]\n"
        "    ldr x16, [x16, #16]\n"
        "    br x16\n"
        "\n"
        ".globl _rx_call_self\n"
        ".p2align 2\n"
        "_rx_call_self:\n"
        "    stp x29, x30, [sp, #-32]!\n"
        "    mov x29, sp\n"
        "    str x20, [sp, #16]\n"
        "    mov x16, x0\n"
        "    mov x20, x1\n"
        "    mov x0, x2\n"
        "    mov x1, x3\n"
        "    blr x16\n"
        "    ldr x20, [sp, #16]\n"
        "    ldp x29, x30, [sp], #32\n"
        "    ret\n"
        "\n"
        ".globl _rx_call_self6\n"
        ".p2align 2\n"
        "_rx_call_self6:\n"
        "    stp x29, x30, [sp, #-32]!\n"
        "    mov x29, sp\n"
        "    stp x20, x19, [sp, #16]\n"
        "    mov x19, x0\n"
        "    ldp x16, x20, [x19]\n"
        "    ldp x0, x1, [x19, #16]\n"
        "    ldp x2, x3, [x19, #32]\n"
        "    ldp x4, x5, [x19, #48]\n"
        "    blr x16\n"
        "    stp x0, x1, [x19, #64]\n"
        "    str x2, [x19, #80]\n"
        "    str d0, [x19, #88]\n"
        "    ldp x20, x19, [sp, #16]\n"
        "    ldp x29, x30, [sp], #32\n"
        "    ret\n"
        "\n"
        ".globl _rx_wrap_trampoline\n"
        ".p2align 2\n"
        "_rx_wrap_trampoline:\n"
        "    stp x29, x30, [sp, #-112]!\n"
        "    mov x29, sp\n"
        "    stp x0, x1, [sp, #16]\n"
        "    stp x2, x3, [sp, #32]\n"
        "    stp x4, x5, [sp, #48]\n"
        "    stp x6, x7, [sp, #64]\n"
        "    stp x8, x20, [sp, #80]\n"
        "    ldr x16, [x20, #32]\n"
        "    mov x0, x20\n"
        "    blr x16\n"
        "    ldp x0, x1, [sp, #16]\n"
        "    ldp x2, x3, [sp, #32]\n"
        "    ldp x4, x5, [sp, #48]\n"
        "    ldp x6, x7, [sp, #64]\n"
        "    ldp x8, x20, [sp, #80]\n"
        "    ldr x16, [x20, #16]\n"
        "    ldr x20, [x20, #24]\n"
        "    blr x16\n"
        "    ldr x20, [sp, #88]\n"
        "    ldp x29, x30, [sp], #112\n"
        "    ret\n"
        "\n"
        ".globl _rx_gate_trampoline\n"
        ".p2align 2\n"
        "_rx_gate_trampoline:\n"
        "    stp x29, x30, [sp, #-112]!\n"
        "    mov x29, sp\n"
        "    stp x0, x1, [sp, #16]\n"
        "    stp x2, x3, [sp, #32]\n"
        "    stp x4, x5, [sp, #48]\n"
        "    stp x6, x7, [sp, #64]\n"
        "    stp x8, x20, [sp, #80]\n"
        "    ldr x16, [x20, #32]\n"
        "    mov x0, x20\n"
        "    blr x16\n"
        "    tst w0, #0xff\n"
        "    b.ne 1f\n"
        "    ldp x0, x1, [sp, #16]\n"
        "    ldp x2, x3, [sp, #32]\n"
        "    ldp x4, x5, [sp, #48]\n"
        "    ldp x6, x7, [sp, #64]\n"
        "    ldp x8, x20, [sp, #80]\n"
        "    ldr x16, [x20, #16]\n"
        "    ldr x20, [x20, #24]\n"
        "    blr x16\n"
        "1:\n"
        "    ldr x20, [sp, #88]\n"
        "    ldp x29, x30, [sp], #112\n"
        "    ret\n"
        "\n"
        ".globl _rx_alloc_box\n"
        ".p2align 2\n"
        "_rx_alloc_box:\n"
        "    stp x29, x30, [sp, #-32]!\n"
        "    mov x29, sp\n"
        "    str x19, [sp, #16]\n"
        "    mov x19, x1\n"
        "    bl _swift_allocBox\n"
        "    str x1, [x19]\n"
        "    ldr x19, [sp, #16]\n"
        "    ldp x29, x30, [sp], #32\n"
        "    ret\n");
extern "C" void rex_body_trampoline(void) __asm__("_rex_body_trampoline");

bool rex_body_hook(const void* meta, const void** wt, int slot) {
    if (g_rex_body_hook)
        return false;
    auto* h = (BodyHook*)calloc(1, sizeof(BodyHook));
    h->meta = meta;
    h->slot = &wt[slot];
    h->original = wt[slot];
    g_rex_body_hook = h;
    __atomic_store_n(h->slot, (const void*)rex_body_trampoline, __ATOMIC_SEQ_CST);
    return true;
}

const void* rex_body_capture(void) {
    return g_rex_body_hook ? g_rex_body_hook->copy : nullptr;
}

bool rex_slide_settings(double* ms, double* curve) {
    *ms = g_config.tab_slide_ms;
    std::copy(g_config.tab_slide_curve, g_config.tab_slide_curve + 4, curve);
    return g_config.tab_slide;
}

bool rex_slide_vertical(void) {
    return g_config.tab_slide_vertical;
}
