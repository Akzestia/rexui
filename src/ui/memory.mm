// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include "ui/ui.h"

#include <dispatch/dispatch.h>

void image_caches_clear(void);
void box_paths_clear(void);
void font_cache_clear(void);
int shaders_trim(void);

extern "C" void rexui_memory_pressure_now(int critical) {
    image_caches_clear();
    box_paths_clear();
    font_cache_clear();
    int shaders = shaders_trim();
    rexui_log(
        [NSString stringWithFormat:@"memory: pressure %@: images, paths and fonts let go, %d hidden Shaders' drawables",
                                   critical ? @"critical" : @"warning", shaders]);
}

void memory_pressure_init(void) {
    static dispatch_source_t src;
    if (src)
        return;
    src = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                 DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
                                 dispatch_get_main_queue());
    dispatch_source_set_event_handler(src, ^{
        unsigned long level = dispatch_source_get_data(src);
        if (!(level & (DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL)))
            return;
        rexui_memory_pressure_now((level & DISPATCH_MEMORYPRESSURE_CRITICAL) != 0);
    });
    dispatch_resume(src);
}
