// Copyright (c) 2026-present アクゼスティア
// SPDX-License-Identifier: LicenseRef-rexui-1.0
#include <stdlib.h>

void rexui_embed_start(void);
void rexui_embed_wine_shims(void);

__attribute__((constructor)) static void init(void) {
    if (getenv("REXUI_EMBED_WINE"))
        rexui_embed_wine_shims();
    else
        unsetenv("DYLD_INSERT_LIBRARIES");
    rexui_embed_start();
}
